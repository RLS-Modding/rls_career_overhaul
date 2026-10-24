-- Engine capture: package trees, powertrain paths and compatible vehicle slots.
-- Named installers build helpers for one package-store load; callers keep the same capture API.

local capture = {}

-- Config -------------------------------------------------------------------------------------------

-- Config vars also contain alignment, tires, suspension, and controls. A recursive JBeam ownership scan is too costly for cold dealership stock, so only authored variables with powertrain names are kept.
local POWERTRAIN_VARIABLE_TOKENS = {"engine", "boost", "turbo", "supercharger", "wastegate", "rev", "rpm", "limiter",
  "fuel", "nitro", "ignition", "timing", "compression", "cam", "idle", "torque", "power", "throttle"}
local CHASSIS_VARIABLE_TOKENS = {"camber", "differential", "difftorque", "brake", "suspension", "spring", "damp",
  "caster", "toe", "steering", "lsd"}

-- Vehicle runtime ----------------------------------------------------------------------------------

local function installVehicleRuntime(helpers)
  function helpers.getSpawnedVehicleObject(inventoryId)
    local vehId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId)
    return vehId and getObjectByID(vehId), vehId
  end

  function helpers.getRuntimeVehicleData(inventoryId)
    local vehObj, vehId = helpers.getSpawnedVehicleObject(inventoryId)
    if not vehObj or not vehId then return nil, nil, nil end
    return extensions.core_vehicle_manager.getVehicleData(vehId), vehObj, vehId
  end

  function helpers.pathDepth(path)
    local depth = 0
    for _ in string.gmatch(path or "", "[^/]+") do depth = depth + 1 end
    return depth
  end
end

-- Powertrain detection ------------------------------------------------------------------------------

local function installPowertrainDetection(helpers, inputs)
  function helpers.jbeamHasDeviceType(partData, deviceType)
    if type(partData) ~= "table" then return false end
    local target = string.lower(deviceType)
    local function walk(value)
      if type(value) == "string" then
        -- Substring match so "classic_combustionEngine" matches "combustionEngine".
        return string.find(string.lower(value), target, 1, true) ~= nil
      end
      if type(value) ~= "table" then return false end
      for _, child in pairs(value) do
        if walk(child) then return true end
      end
      return false
    end
    return walk(partData.powertrain)
  end

  function helpers.partIsCombustionEngine(ioCtx, partName)
    if not partName or partName == "" or not ioCtx then return false end
    return helpers.jbeamHasDeviceType(inputs.jbeamIO.getPart(ioCtx, partName), "combustionEngine")
  end

  function helpers.partIsElectricMotor(ioCtx, partName)
    if not partName or partName == "" or not ioCtx then return false end
    return helpers.jbeamHasDeviceType(inputs.jbeamIO.getPart(ioCtx, partName), "electricMotor")
  end

  -- Unlike helpers.nodePartName below, this keeps an empty chosenPartName as "" (callers guard for it).
  function helpers.rawNodePartName(node)
    return node and (node.chosenPartName or node.name) or nil
  end

  function helpers.subtreeContainsCombustionEngine(node, ioCtx)
    if not node then return false end
    if helpers.partIsCombustionEngine(ioCtx, helpers.rawNodePartName(node)) then return true end
    for _, child in pairs(node.children or {}) do
      if helpers.subtreeContainsCombustionEngine(child, ioCtx) then return true end
    end
    return false
  end

  function helpers.findCombustionEnginePartName(node, ioCtx)
    if not node then return nil end
    local partName = helpers.rawNodePartName(node)
    if helpers.partIsCombustionEngine(ioCtx, partName) then return partName end
    for _, child in pairs(node.children or {}) do
      local found = helpers.findCombustionEnginePartName(child, ioCtx)
      if found then return found end
    end
  end

  function helpers.collectPowertrainFlags(tree, ioCtx)
    local hasCombustion, hasElectric = false, false
    local function visit(node)
      if not node then return end
      local name = node.chosenPartName
      if name and name ~= "" then
        if helpers.partIsCombustionEngine(ioCtx, name) then hasCombustion = true end
        if helpers.partIsElectricMotor(ioCtx, name) then hasElectric = true end
      end
      for _, child in pairs(node.children or {}) do visit(child) end
    end
    visit(tree)
    return hasCombustion, hasElectric
  end

  function helpers.vehicleIsElectric(inventoryId)
    local vehicle = inventoryId and overhaul_career_garage_inventory.getVehicles()[inventoryId]
    local fuel = vehicle and vehicle.certificationData and vehicle.certificationData.fuelType
    if type(fuel) == "string" and string.find(string.lower(fuel), "electric", 1, true) then
      return true
    end
    if type(fuel) == "table" then
      local hasLiquid = fuel["fuelTank:gasoline"] or fuel["fuelTank:diesel"]
      if fuel["fuelTank:electric"] and not hasLiquid then return true end
    end

    local runtimeData = helpers.getRuntimeVehicleData(inventoryId)
    if not runtimeData or not runtimeData.config then return false end
    local hasCombustion, hasElectric = helpers.collectPowertrainFlags(runtimeData.config.partsTree, runtimeData.ioCtx)
    if hasCombustion then return false end
    return hasElectric
  end
end

-- Engine slots and candidates -----------------------------------------------------------------------

local function installEngineSlotsAndCandidates(helpers)
  function helpers.sortByPathDepth(candidates)
    table.sort(candidates, function(a, b)
      local depthA, depthB = helpers.pathDepth(a.path), helpers.pathDepth(b.path)
      if depthA ~= depthB then return depthA < depthB end
      return tostring(a.path) < tostring(b.path)
    end)
    return candidates
  end

  function helpers.isEngineSlotName(slotName)
    local lowerSlot = string.lower(slotName)
    return string.find(lowerSlot, "engine", 1, true) and not string.find(lowerSlot, "electric", 1, true)
  end

  -- Engine assembly roots: the outer slot a combustion engine (or CEEP wrapper) hangs from.
  function helpers.findEngineCandidates(tree, includeEmpty, ioCtx)
    local candidates = {}

    local function visit(node, parentPartName)
      if not node then return end
      for slotName, child in pairs(node.children or {}) do
        local hasInstalledPart = child and child.chosenPartName and child.chosenPartName ~= ""
        local looksLikeEngineSlot = child and helpers.isEngineSlotName(slotName)
        -- Adapter packs such as CEEP attach a wrapper to the vehicle's real engine slot, then put the combustion engine one or more slots below it. The package root must remain at that outer attachment surface or standard and wrapped engines can never replace one another.
        local containsCombustion = hasInstalledPart and helpers.subtreeContainsCombustionEngine(child, ioCtx)
        local include = looksLikeEngineSlot and (containsCombustion or (includeEmpty and not hasInstalledPart))
        if include then
          table.insert(candidates, {
            node = child,
            slotName = slotName,
            path = child.path or ((node.path or "/") .. slotName .. "/"),
            parentPartName = node.chosenPartName,
            combustionPartName = containsCombustion and helpers.findCombustionEnginePartName(child, ioCtx) or nil
          })
        else
          -- Once an engine assembly root is found, do not expose any nested adapter slots as independent vehicle compatibility surfaces.
          visit(child, child.chosenPartName or parentPartName)
        end
      end
    end

    visit(tree, tree and tree.chosenPartName)
    return helpers.sortByPathDepth(candidates)
  end

  -- Part name of a tree node with empty names normalised to nil.
  function helpers.nodePartName(node)
    if not node then return nil end
    local name = node.chosenPartName
    if name and name ~= "" then return name end
    name = node.name
    if name and name ~= "" then return name end
    return nil
  end

  function helpers.isCeepHubNode(node, ioCtx)
    local partName = helpers.nodePartName(node)
    if not partName then return false end
    if helpers.partIsCombustionEngine(ioCtx, partName) then return false end
    local function hasCombustionDescendant(partNode)
      for _, child in pairs(partNode.children or {}) do
        local childName = helpers.nodePartName(child)
        if childName and helpers.partIsCombustionEngine(ioCtx, childName) then
          return true
        end
        if hasCombustionDescendant(child) then return true end
      end
      return false
    end
    return hasCombustionDescendant(node)
  end

  -- Every engine-named slot in the tree, whether or not it holds a part.
  function helpers.findEngineBaySlots(tree, ioCtx)
    local bays = {}

    local function visit(node)
      if not node then return end
      for slotName, child in pairs(node.children or {}) do
        if child and helpers.isEngineSlotName(slotName) then
          table.insert(bays, {
            node = child,
            slotName = slotName,
            path = child.path or ((node.path or "/") .. slotName .. "/"),
            parentPartName = node.chosenPartName,
            isBay = true
          })
        else
          visit(child)
        end
      end
    end

    visit(tree)
    return helpers.sortByPathDepth(bays)
  end

  function helpers.getPrimaryEngine(tree, ioCtx)
    return helpers.findEngineCandidates(tree, false, ioCtx)[1]
  end

  -- The CEEP hub bay above the primary engine when there is one, otherwise the primary engine itself.
  function helpers.resolveEngineCaptureAnchor(tree, ioCtx)
    local primary = helpers.getPrimaryEngine(tree, ioCtx)
    if not primary then return nil end
    for _, bay in ipairs(helpers.findEngineBaySlots(tree, ioCtx)) do
      if string.find(primary.path, bay.path, 1, true) == 1 and helpers.isCeepHubNode(bay.node, ioCtx) then
        return bay
      end
    end
    return primary
  end
end

-- CEEP hub detection -----------------------------------------------------------------------------------

local function installCeepHubDetection(helpers, inputs)
  function helpers.partNameLooksLikeCeepHub(partName)
    if not partName or partName == "" then return false end
    return string.find(string.lower(partName), "^classic_.-_engines$") ~= nil
  end

  function helpers.slotsMentionEngine(slots)
    for _, slot in ipairs(slots) do
      local slotType = type(slot[1]) == "string" and string.lower(slot[1]) or ""
      if string.find(slotType, "engine", 1, true) then return true end
    end
    return false
  end

  -- Whether a part declares an engine mount, in either the older slots or the newer slots2 layout.
  function helpers.partProvidesEngineMount(partData)
    if type(partData) ~= "table" then return false end
    if type(partData.slots) == "table" and helpers.slotsMentionEngine(partData.slots) then return true end
    if type(partData.slots2) == "table" then
      for _, slot in ipairs(partData.slots2) do
        if type(slot) == "table" then
          local slotType = slot.type or slot[1]
          if type(slotType) == "string" and string.find(string.lower(slotType), "engine", 1, true) then
            return true
          end
          local allowTypes = slot.allowTypes or slot[2]
          if type(allowTypes) == "table" then
            for _, allowType in ipairs(allowTypes) do
              if type(allowType) == "string" and string.find(string.lower(allowType), "engine", 1, true) then
                return true
              end
            end
          end
        end
      end
    end
    return false
  end

  function helpers.parentIsCeepHub(parentPartName, ioCtx)
    if not parentPartName or parentPartName == "" or not ioCtx then return false end
    if helpers.partIsCombustionEngine(ioCtx, parentPartName) then return false end
    if helpers.partNameLooksLikeCeepHub(parentPartName) then return true end
    local partData = inputs.jbeamIO.getPart(ioCtx, parentPartName)
    if not partData then return false end
    local slotType = string.lower(partData.slotType or "")
    if string.find(slotType, "classic_", 1, true) and string.find(slotType, "engines", 1, true) then
      return true
    end
    return string.find(slotType, "engine", 1, true) ~= nil and helpers.partProvidesEngineMount(partData)
  end

  function helpers.packageUsesCeepMount(package, ioCtx)
    if not ioCtx or not package.tree then return false end
    if package.tree.name and helpers.partIsCombustionEngine(ioCtx, package.tree.name) then
      return false
    end
    if package.tree.name and helpers.partNameLooksLikeCeepHub(package.tree.name) then
      return true
    end
    return helpers.isCeepHubNode({name = package.tree.name, children = package.tree.children or {}}, ioCtx)
  end
end

-- Tree comparison ------------------------------------------------------------------------------------

local function installTreeComparison(helpers)
  function helpers.packageTreesStructurallyMatch(expected, actual)
    if not expected or not actual then return false end
    if tostring(expected.partId) ~= tostring(actual.partId) then return false end
    for slotName, expectedChild in pairs(expected.children or {}) do
      local actualChild = (actual.children or {})[slotName]
      if not actualChild or not helpers.packageTreesStructurallyMatch(expectedChild, actualChild) then
        return false
      end
    end
    return true
  end

  function helpers.packageTreesFullyMatch(expected, actual)
    if not expected or not actual then return false end
    if tostring(expected.partId) ~= tostring(actual.partId) then return false end
    if tostring(expected.name or "") ~= tostring(actual.name or "") then return false end
    local expectedChildren = expected.children or {}
    local actualChildren = actual.children or {}
    local expectedCount, actualCount = 0, 0
    for slotName, expectedChild in pairs(expectedChildren) do
      expectedCount = expectedCount + 1
      local actualChild = actualChildren[slotName]
      if not actualChild or not helpers.packageTreesFullyMatch(expectedChild, actualChild) then
        return false
      end
    end
    for _ in pairs(actualChildren) do
      actualCount = actualCount + 1
    end
    return expectedCount == actualCount
  end

  -- An installed package matches when its tree is found anywhere under the captured vehicle tree.
  function helpers.installedPackageTreeMatches(packageTree, captureTree)
    if not packageTree or not captureTree then return false end
    if helpers.packageTreesStructurallyMatch(packageTree, captureTree) then return true end
    local function walk(node)
      if helpers.packageTreesStructurallyMatch(packageTree, node) then return true end
      for _, child in pairs(node.children or {}) do
        if walk(child) then return true end
      end
      return false
    end
    return walk(captureTree)
  end
end

-- Names and values -----------------------------------------------------------------------------------

local function installNamesAndValues(helpers, inputs)
  function helpers.getDescriptionText(description, fallback)
    if type(description) == "string" then return description end
    if type(description) == "table" then
      if type(description.description) == "string" then return description.description end
      if type(description.description) == "table" then
        return helpers.getDescriptionText(description.description, fallback)
      end
      if type(description.name) == "string" then return description.name end
    end
    return fallback
  end

  function helpers.getPartNiceName(ioCtx, partName)
    local availableParts = ioCtx and inputs.jbeamIO.getAvailableParts(ioCtx) or {}
    local description = availableParts and availableParts[partName]
    return helpers.getDescriptionText(description, partName or "Engine")
  end

  -- Authored value of a part on a vehicle model, cached per model (the cache holds only the last few models).
  function helpers.loadModelPartCache(vehicleModel)
    local cacheEntry = inputs.authoredPartValueCache[vehicleModel]
    if cacheEntry then return cacheEntry end
    local vehicleDir = string.format("/vehicles/%s/", vehicleModel)
    local ioCtx = FS:directoryExists(vehicleDir) and inputs.jbeamIO.startLoading({vehicleDir, "/vehicles/common/"}) or nil
    cacheEntry = {ioCtx = ioCtx, available = ioCtx and (inputs.jbeamIO.getAvailableParts(ioCtx) or {}) or {}, values = {}}
    if tableSize(inputs.authoredPartValueCache) >= 8 then table.clear(inputs.authoredPartValueCache) end
    inputs.authoredPartValueCache[vehicleModel] = cacheEntry
    return cacheEntry
  end

  function helpers.getAuthoredPartValue(vehicleModel, partName)
    vehicleModel = tostring(vehicleModel or "")
    partName = tostring(partName or "")
    if vehicleModel == "" or partName == "" then return 0 end
    local modelCache = helpers.loadModelPartCache(vehicleModel)
    if modelCache.values[partName] ~= nil then return modelCache.values[partName] end
    local info = modelCache.available[partName] or {}
    local data = modelCache.ioCtx and (inputs.jbeamIO.getPart(modelCache.ioCtx, partName) or {}) or {}
    local value = math.max(0, tonumber(info.value)
      or tonumber(info.information and info.information.value)
      or tonumber(data.information and data.information.value) or 0)
    modelCache.values[partName] = value
    return value
  end

  function helpers.collectVariableNamesFromValue(value, result, seen)
    if type(value) ~= "table" or seen[value] then return end
    seen[value] = true

    if type(value.name) == "string" and value.name:sub(1, 1) == "$" then
      result[value.name] = true
    end
    if type(value[1]) == "string" and value[1]:sub(1, 1) == "$" then
      result[value[1]] = true
    end

    for key, child in pairs(value) do
      if type(key) == "string" and key:sub(1, 1) == "$" then
        result[key] = true
      end
      if type(child) == "table" then
        helpers.collectVariableNamesFromValue(child, result, seen)
      end
    end
  end

  function helpers.collectEngineVariableNames(packageTree, ioCtx)
    local result = {}
    local function visit(node)
      if not node then return end
      local partData = node.name and inputs.jbeamIO.getPart(ioCtx, node.name)
      if partData and partData.variables then
        helpers.collectVariableNamesFromValue(partData.variables, result, {})
      end
      for _, child in pairs(node.children or {}) do visit(child) end
    end
    visit(packageTree)
    return result
  end
end

-- Tuning ---------------------------------------------------------------------------------------------

local function installTuning(helpers)

  function helpers.isPowertrainVariable(variableName)
    local lower = string.lower(tostring(variableName))
    if lower == "fuel" or lower == "$fuel" then return false end
    for _, token in ipairs(CHASSIS_VARIABLE_TOKENS) do
      if string.find(lower, token, 1, true) then return false end
    end
    for _, token in ipairs(POWERTRAIN_VARIABLE_TOKENS) do
      if string.find(lower, token, 1, true) then return true end
    end
    return false
  end

  function helpers.filterRecipeTuning(packageTree, vehicleModel, values, existingIoCtx)
    if type(packageTree) ~= "table" or type(values) ~= "table" then return {} end
    local filtered = {}
    for variableName, value in pairs(values) do
      if helpers.isPowertrainVariable(variableName) then filtered[variableName] = deepcopy(value) end
    end
    return filtered
  end

  -- Current values of the engine's variables: the vehicle's live value, else its config value, else the default.
  function helpers.captureTuning(packageTree, runtimeData, vehicleConfig)
    local tuning = {}
    local definitions = runtimeData and runtimeData.vdata and runtimeData.vdata.variables or {}
    local names = helpers.collectEngineVariableNames(packageTree, runtimeData and runtimeData.ioCtx)
    for variableName in pairs(names) do
      local definition = definitions and definitions[variableName]
      local value = definition and definition.val
      if value == nil and vehicleConfig and vehicleConfig.vars then value = vehicleConfig.vars[variableName] end
      if value == nil and definition then value = definition.default end
      if value ~= nil then tuning[variableName] = value end
    end
    return tuning
  end
end

-- Package trees -------------------------------------------------------------------------------------

local function installPackageTrees(helpers, inputs)
  -- The owned part installed at a given slot path in this vehicle, if any.
  function helpers.findOwnedPartIdAtSlot(inventory, inventoryId, path)
    for partId, part in pairs(inventory) do
      if tonumber(part.location) == tonumber(inventoryId) and part.containingSlot == path then
        return partId
      end
    end
  end

  -- Copies a vehicle engine subtree into a package tree of owned part ids; nil plus the reason on failure.
  function helpers.makePackageTree(node, inventoryId)
    local inventory = inputs.getPartInventory()
    local function copyNode(source, relativeSlot)
      local partId = helpers.findOwnedPartIdAtSlot(inventory, inventoryId, source.path)
      if not partId then return nil, "Could not locate owned part for " .. tostring(source.chosenPartName) end
      local result = {
        name = source.chosenPartName,
        partId = partId,
        relativeSlot = relativeSlot,
        children = {}
      }
      for slotName, child in pairs(source.children or {}) do
        if child.chosenPartName and child.chosenPartName ~= "" then
          local copied, err = copyNode(child, slotName)
          if not copied then return nil, err end
          result.children[slotName] = copied
        end
      end
      return result
    end

    return copyNode(node)
  end

  function helpers.collectTreePartEntries(node, basePath, result)
    result = result or {}
    if not node then return result end
    table.insert(result, {
      partId = tonumber(node.partId) or node.partId,
      name = node.name,
      containingSlot = basePath,
      partPath = basePath .. tostring(node.name or "")
    })
    for slotName, child in pairs(node.children or {}) do
      helpers.collectTreePartEntries(child, basePath .. slotName .. "/", result)
    end
    return result
  end

  function helpers.makeConfigTree(node, basePath, slotId)
    local result = {
      id = slotId or node.relativeSlot,
      chosenPartName = node.name,
      path = basePath,
      partPath = basePath .. tostring(node.name or ""),
      decisionMethod = "user",
      children = {}
    }
    for slotName, child in pairs(node.children or {}) do
      result.children[slotName] = helpers.makeConfigTree(child, basePath .. slotName .. "/", slotName)
    end
    return result
  end
end

-- Package lookup and naming -----------------------------------------------------------------------------

local function installPackageLookupAndNaming(helpers, inputs)
  function helpers.findPackageForInventory(inventoryId)
    inventoryId = tonumber(inventoryId)
    -- Temporary job ids cannot identify an installed personal engine.
    if not inventoryId then return end
    for _, package in ipairs(inputs.packageStore.packages) do
      if tonumber(package.installedInventoryId) == inventoryId then
        return package
      end
    end
  end

  function helpers.uniquePackageName(baseName, exceptPackageId)
    baseName = inputs.trim(baseName)
    if baseName == "" then baseName = "Engine Package" end
    local used = {}
    for _, package in ipairs(inputs.packageStore.packages) do
      if tostring(package.id) ~= tostring(exceptPackageId or "") then
        used[string.lower(package.name or "")] = true
      end
    end
    if not used[string.lower(baseName)] then return baseName end
    local suffix = 2
    while used[string.lower(baseName .. " " .. suffix)] do suffix = suffix + 1 end
    return baseName .. " " .. suffix
  end
end

-- Capture ------------------------------------------------------------------------------------------

local function installCapture(helpers, inputs)
  local parts = inputs.parts
  -- Parts the package no longer uses keep their old package id cleared, unless they are still in the package.
  function helpers.releaseDroppedParts(package, packageTree)
    local newIds = {}
    for _, id in ipairs(inputs.getPartIdsFromPackageTree(packageTree)) do newIds[id] = true end
    local inventory = inputs.getPartInventory()
    for _, oldId in ipairs(inputs.getPartIdsFromPackageTree(package.tree)) do
      if not newIds[oldId] then
        local oldPart = inventory[oldId]
        if oldPart and tostring(oldPart.enginePackageId or "") == tostring(package.id) then
          oldPart.enginePackageId = nil
          oldPart.mainPart = oldPart.containingSlot == "/"
        end
      end
    end
  end

  -- Returns the package to write into: the existing one (its dropped parts released), or a new record.
  function helpers.packageForCapture(existingPackage, packageTree)
    if existingPackage then
      helpers.releaseDroppedParts(existingPackage, packageTree)
      return existingPackage
    end
    local package = {id = tostring(inputs.packageStore.nextPackageId), ownerType = "personal"}
    inputs.packageStore.nextPackageId = inputs.packageStore.nextPackageId + 1
    table.insert(inputs.packageStore.packages, package)
    return package
  end

  function helpers.engineNameFor(engine, runtimeData, packageTree)
    return engine.combustionPartName or helpers.findCombustionEnginePartName(engine.node, runtimeData.ioCtx) or packageTree.name
  end

  -- Copies the captured engine's identity, tree and tuning onto the package record.
  function helpers.writeCapturedPackage(package, engine, packageTree, runtimeData, vehicle, inventoryId, requestedName)
    local enginePartName = helpers.engineNameFor(engine, runtimeData, packageTree)
    local engineNiceName = helpers.getPartNiceName(runtimeData.ioCtx, enginePartName)
    local desiredName = inputs.trim(requestedName)
    if desiredName == "" then desiredName = package.name or (engineNiceName .. " Package") end
    package.name = helpers.uniquePackageName(desiredName, package.id)
    package.rootSlotName = engine.slotName
    package.rootPath = engine.path
    package.rootEngineName = enginePartName
    package.rootEngineNiceName = engineNiceName
    package.tree = packageTree
    package.tuning = helpers.captureTuning(packageTree, runtimeData, vehicle.config)
    package.createdModel = package.createdModel or vehicle.model
    package.lastInstalledModel = vehicle.model
    package.installedInventoryId = inventoryId
    package.installedViaCeep = helpers.isCeepHubNode(engine.node, runtimeData.ioCtx)
    package.updatedAt = os.time()
    package.createdAt = package.createdAt or package.updatedAt
  end

  -- Marks the captured parts as belonging to this package and mounted in the main slot.
  function helpers.claimPackageParts(package)
    local inventory = inputs.getPartInventory()
    for _, partId in ipairs(inputs.getPartIdsFromPackageTree(package.tree)) do
      local part = inventory[partId]
      if part then
        part.enginePackageId = tostring(package.id)
        part.mainPart = true
      end
    end
  end

  -- Reads the engine at `captureAnchor` (or the primary engine) from the spawned vehicle into a package. Returns the package, or nil plus the reason when the vehicle is not spawned or has no engine.
  function helpers.captureCurrentEngineActual(inventoryId, requestedName, existingPackage, captureAnchor)
    local vehicles = overhaul_career_garage_inventory.getVehicles()
    local vehicle = vehicles and vehicles[inventoryId]
    local runtimeData, vehObj = helpers.getRuntimeVehicleData(inventoryId)
    if not vehicle or not runtimeData or not runtimeData.config or not runtimeData.config.partsTree or not vehObj then
      return nil, "The selected vehicle is not spawned."
    end

    local engine = captureAnchor or helpers.resolveEngineCaptureAnchor(runtimeData.config.partsTree, runtimeData.ioCtx)
    if not engine then return nil, "No installed engine slot was found." end

    local packageTree, treeError = helpers.makePackageTree(engine.node, inventoryId)
    if not packageTree then return nil, treeError end

    local package = helpers.packageForCapture(existingPackage, packageTree)
    helpers.writeCapturedPackage(package, engine, packageTree, runtimeData, vehicle, inventoryId, requestedName)
    helpers.claimPackageParts(package)
    parts.recipes.refreshCertificationValidity(package)
    return package
  end
end

-- Status ----------------------------------------------------------------------------------------------

local function installStatus(helpers, inputs)
  -- "stored" when every part is in storage, "installed" when every part sits in one vehicle, else "incomplete".
  function helpers.getPackageStatus(package)
    local inventory = inputs.getInventoryForPackage(package)
    local location
    local missing = 0
    local mixed = false
    local ids = inputs.getPartIdsFromPackageTree(package.tree)
    for _, partId in ipairs(ids) do
      local part = inventory[partId]
      if not part then
        missing = missing + 1
      elseif location == nil then
        location = tonumber(part.location) or part.location
      elseif tostring(location) ~= tostring(part.location) then
        mixed = true
      end
    end

    if missing > 0 then return "incomplete", nil, missing end
    if mixed or location == nil then return "incomplete", nil, missing end
    if tonumber(location) == 0 or tostring(location) == "stored" then return "stored", nil, 0 end
    return "installed", tonumber(location) or location, 0
  end
end

-- Compatibility --------------------------------------------------------------------------------------

local function installSlotCompatibility(helpers, inputs)
  function helpers.getSlotInfo(availableParts, parentPartName, slotName, ioCtx)
    local parentInfo = availableParts and availableParts[parentPartName]
    local slotInfo = parentInfo and parentInfo.slotInfoUi and parentInfo.slotInfoUi[slotName]
    if slotInfo then return slotInfo end
    local parentJbeam = ioCtx and inputs.jbeamIO.getPart(ioCtx, parentPartName) or nil
    return parentJbeam and parentJbeam.slotInfoUi and parentJbeam.slotInfoUi[slotName] or nil
  end

  -- The default part a parent declares for a slot, from either slot layout.
  function helpers.declaredDefaultForSlot(parentJbeam, slotName)
    local defaultName
    if type(parentJbeam.slots2) == "table" then
      for _, slot in ipairs(parentJbeam.slots2) do
        if type(slot) == "table" and (slot.name or slot[1]) == slotName then
          defaultName = slot.default or slot[4]
          break
        end
      end
    end
    if type(parentJbeam.slots) == "table" then
      for _, slot in ipairs(parentJbeam.slots) do
        if type(slot) == "table" and slot.type == slotName then
          defaultName = slot.default
          break
        end
      end
    end
    return defaultName
  end

  function helpers.partFitsSlotOrDeclaredDefault(parentPartName, slotName, partData, partName, slotInfo, ioCtx)
    if slotInfo and inputs.jbeamSlotSystem.partFitsSlot(partData, slotInfo) then return true end
    local parentJbeam = ioCtx and inputs.jbeamIO.getPart(ioCtx, parentPartName) or nil
    if not parentJbeam then return false end
    local defaultName = helpers.declaredDefaultForSlot(parentJbeam, slotName)
    return defaultName ~= nil and tostring(defaultName) == tostring(partName)
  end

  function helpers.validatePackageTreeFits(node, parentPartName, slotName, ioCtx, availableParts)
    if not node or not node.name then return false, "Package tree is incomplete." end
    local partData = inputs.jbeamIO.getPart(ioCtx, node.name)
    if not partData then return false, "Missing part: " .. tostring(node.name) end
    local slotInfo = helpers.getSlotInfo(availableParts, parentPartName, slotName, ioCtx)
    if not helpers.partFitsSlotOrDeclaredDefault(parentPartName, slotName, partData, node.name, slotInfo, ioCtx) then
      return false, tostring(node.name) .. " does not fit " .. tostring(slotName)
    end
    for childSlot, child in pairs(node.children or {}) do
      local ok, err = helpers.validatePackageTreeFits(child, node.name, childSlot, ioCtx, availableParts)
      if not ok then return false, err end
    end
    return true
  end

end

local function installTreePaths(helpers)
  function helpers.findNodeByPath(tree, path)
    if not tree or not path then return nil end
    if path == "/" or path == tree.path then return tree end
    local current = tree
    for segment in string.gmatch(path, "[^/]+") do
      if not current.children or not current.children[segment] then return nil end
      current = current.children[segment]
    end
    return current
  end

  function helpers.parentPathFromSlotPath(slotPath)
    if type(slotPath) ~= "string" or slotPath == "" or slotPath == "/" then return nil end
    local trimmed = slotPath:gsub("/+$", "")
    local parent = trimmed:match("^(.*)/[^/]+$")
    if not parent or parent == "" then return "/" end
    if parent:sub(-1) ~= "/" then parent = parent .. "/" end
    return parent
  end

  -- Returns the child slot node, creating it when the slot is empty.
  function helpers.ensureChildSlotNode(parentNode, slotName, path)
    if not parentNode or not slotName then return nil end
    parentNode.children = parentNode.children or {}
    local child = parentNode.children[slotName]
    if not child then
      child = {id = slotName, path = path, chosenPartName = ""}
      parentNode.children[slotName] = child
    else
      if not child.id then child.id = slotName end
      if path and (not child.path or child.path == "") then child.path = path end
    end
    return child
  end

  -- The child slot node if it exists; otherwise a detached placeholder that is not added to the tree.
  function helpers.peekChildSlotNode(parentNode, slotName, path)
    local existing = parentNode and parentNode.children and parentNode.children[slotName]
    if existing then return existing, true end
    return {id = slotName, path = path, chosenPartName = ""}, false
  end

end

local function installAttachmentCandidates(helpers, inputs)
  -- Engine bays declared by a part's slot UI data, including bays with no part installed yet.
  function helpers.collectDeclaredEngineBayCandidates(tree, availableParts, ioCtx)
    local bays = {}
    local function visit(node)
      if not node then return end
      local parentName = helpers.nodePartName(node)
      local parentInfo = parentName and availableParts and availableParts[parentName]
      local slotInfoUi = parentInfo and parentInfo.slotInfoUi
      if not slotInfoUi and parentName and ioCtx then
        local parentJbeam = inputs.jbeamIO.getPart(ioCtx, parentName)
        slotInfoUi = parentJbeam and parentJbeam.slotInfoUi
      end
      if slotInfoUi then
        for slotName, _ in pairs(slotInfoUi) do
          if helpers.isEngineSlotName(tostring(slotName)) then
            local path = ((node.path or "/") .. slotName .. "/")
            local child, existed = helpers.peekChildSlotNode(node, slotName, path)
            table.insert(bays, {
              node = child,
              parentNode = node,
              slotName = slotName,
              path = child.path or path,
              parentPartName = parentName,
              isBay = true,
              synthesized = not existed
            })
          end
        end
      end
      for _, child in pairs(node.children or {}) do
        visit(child)
      end
    end
    visit(tree)
    return bays
  end

  -- The slot the package was captured from, when it can still be reached in this vehicle's tree.
  function helpers.rememberedAttachmentCandidate(package, tree)
    if not package or not tree then return nil end
    local slotName = package.rootSlotName
    local path = package.rootPath
    if (not slotName or slotName == "") and type(path) == "string" then
      slotName = path:match("/([^/]+)/?$")
    end
    if not slotName or slotName == "" then return nil end
    local parentPath = helpers.parentPathFromSlotPath(path)
    local parentNode = parentPath and helpers.findNodeByPath(tree, parentPath) or nil
    if not parentNode then
      parentNode = tree
    end
    local parentName = helpers.nodePartName(parentNode)
    if not parentName or parentName == "" then return nil end
    local synthesizedPath = ((parentNode.path or "/") .. slotName .. "/")
    local child, existed = helpers.peekChildSlotNode(parentNode, slotName, synthesizedPath)
    local childPath = (existed and type(child.path) == "string" and child.path ~= "") and child.path or synthesizedPath
    if not child.path or child.path == "" then child.path = childPath end
    return {
      node = child,
      parentNode = parentNode,
      slotName = slotName,
      path = childPath,
      parentPartName = parentName,
      isBay = true,
      remembered = true
    }
  end

end

local function installCompatibility(helpers, inputs)
  -- Gathers every slot the package's tree validates against, in priority order, without duplicates.
  function helpers.collectCompatibleMatches(package, runtimeData, availableParts)
    local matches = {}
    local seenPaths = {}
    local function tryCandidate(candidate)
      local path = tostring(candidate.path or "")
      if seenPaths[path] then return end
      seenPaths[path] = true
      local ok = helpers.validatePackageTreeFits(package.tree, candidate.parentPartName, candidate.slotName, runtimeData.ioCtx, availableParts)
      if ok then table.insert(matches, candidate) end
    end

    local remembered = helpers.rememberedAttachmentCandidate(package, runtimeData.config.partsTree)
    if remembered then tryCandidate(remembered) end

    if helpers.packageUsesCeepMount(package, runtimeData.ioCtx) then
      for _, candidate in ipairs(helpers.findEngineBaySlots(runtimeData.config.partsTree, runtimeData.ioCtx)) do
        tryCandidate(candidate)
      end
    else
      for _, candidate in ipairs(helpers.findEngineBaySlots(runtimeData.config.partsTree, runtimeData.ioCtx)) do
        tryCandidate(candidate)
      end
      local engineCandidates = helpers.findEngineCandidates(runtimeData.config.partsTree, true, runtimeData.ioCtx)
      for _, candidate in ipairs(engineCandidates) do
        if not helpers.parentIsCeepHub(candidate.parentPartName, runtimeData.ioCtx) then
          tryCandidate(candidate)
        end
      end
      for _, candidate in ipairs(engineCandidates) do
        if helpers.parentIsCeepHub(candidate.parentPartName, runtimeData.ioCtx) then
          tryCandidate(candidate)
        end
      end
    end

    if #matches == 0 then
      for _, candidate in ipairs(helpers.collectDeclaredEngineBayCandidates(runtimeData.config.partsTree, availableParts, runtimeData.ioCtx)) do
        tryCandidate(candidate)
      end
    end
    return matches
  end

  -- The single slot to use: the package's own slot if it matches, otherwise the shallowest match when it is unique.
  function helpers.chooseCompatibleMatch(package, matches)
    for _, candidate in ipairs(matches) do
      if candidate.slotName == package.rootSlotName then return candidate end
    end
    helpers.sortByPathDepth(matches)
    if #matches > 1 and helpers.pathDepth(matches[1].path) == helpers.pathDepth(matches[2].path) then
      return nil, "More than one compatible engine slot was found."
    end
    return matches[1]
  end

  function helpers.findCompatibleTarget(package, inventoryId)
    if helpers.vehicleIsElectric(inventoryId) then
      return nil, "Electric vehicles cannot swap engines."
    end
    local runtimeData = helpers.getRuntimeVehicleData(inventoryId)
    if not runtimeData or not runtimeData.config or not runtimeData.config.partsTree or not runtimeData.ioCtx then
      return nil, "The selected vehicle is not spawned."
    end

    local inventory = inputs.getPartInventory()
    for _, partId in ipairs(inputs.getPartIdsFromPackageTree(package.tree)) do
      if not inventory[partId] then return nil, "The package is missing one or more parts." end
    end

    local availableParts = inputs.jbeamIO.getAvailableParts(runtimeData.ioCtx)
    local matches = helpers.collectCompatibleMatches(package, runtimeData, availableParts)
    if #matches == 0 then return nil, "This engine package does not fit the selected vehicle." end
    return helpers.chooseCompatibleMatch(package, matches)
  end
end

-- Public API -----------------------------------------------------------------------------------------

function capture.create(inputs)
  local helpers = {}
  installVehicleRuntime(helpers)
  installPowertrainDetection(helpers, inputs)
  installEngineSlotsAndCandidates(helpers)
  installCeepHubDetection(helpers, inputs)
  installTreeComparison(helpers)
  installNamesAndValues(helpers, inputs)
  installTuning(helpers)
  installPackageTrees(helpers, inputs)
  installPackageLookupAndNaming(helpers, inputs)
  installCapture(helpers, inputs)
  installStatus(helpers, inputs)
  installSlotCompatibility(helpers, inputs)
  installTreePaths(helpers)
  installAttachmentCandidates(helpers, inputs)
  installCompatibility(helpers, inputs)

  return helpers
end

return capture
