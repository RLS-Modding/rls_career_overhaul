-- Business vehicle baselines, fuel, power requests and parts-tree edits.
-- Read owner inputs, vehicle lookup, baselines, fuel, then the shared power gate and returned API.
local installer = {}

function installer.new(inputs)
  local runtime = inputs.runtime
  local capabilities = require('overhaul/lib/platform/capabilities')
  local sharedParts = inputs.parts

  -- Part tree helpers -----------------------------------------------------------------------------

  local function flattenPartsTree(tree)
    local result = {}
    if not tree then
      return result
    end

    if tree.chosenPartName then
      result[tree.path] = tree.chosenPartName
    end

    if tree.children then
      for _, childNode in pairs(tree.children) do
        tableMerge(result, flattenPartsTree(childNode))
      end
    end

    return result
  end

  local function partListFingerprint(partList)
    if not partList or not next(partList) then
      return ""
    end
    local keys = {}
    for slotPath in pairs(partList) do
      keys[#keys + 1] = slotPath
    end
    table.sort(keys)
    local entries = {}
    for _, slotPath in ipairs(keys) do
      entries[#entries + 1] = slotPath .. "=" .. tostring(partList[slotPath])
    end
    return table.concat(entries, "|")
  end

  local function getNodeFromSlotPath(tree, path)
    if not tree or not path then
      return nil
    end

    if path == "/" then
      return tree
    end

    local segments = {}
    for segment in string.gmatch(path, "[^/]+") do
      table.insert(segments, segment)
    end

    local currentNode = tree
    for _, segment in ipairs(segments) do
      if currentNode.children and currentNode.children[segment] then
        currentNode = currentNode.children[segment]
      else
        return nil
      end
    end

    return currentNode
  end

  local function getSlotPathDepth(slotPath)
    if not slotPath then
      return 0
    end
    local depth = 0
    for _ in string.gmatch(slotPath, "[^/]+") do
      depth = depth + 1
    end
    return depth
  end

  local function createOrUpdatePartsTreeNode(partsTree, partName, slotPath)
    if not partsTree or not slotPath then
      return false
    end

    local node = getNodeFromSlotPath(partsTree, slotPath)
    if node then
      if partName == "" or not partName then
        node.chosenPartName = ""
        node.emptyPlaceholder = true
      else
        node.chosenPartName = partName
        node.emptyPlaceholder = nil
      end
      return true
    end

    local parentPath = slotPath:match("(.+)/[^/]+/$") or "/"
    local parentNode = getNodeFromSlotPath(partsTree, parentPath)
    if parentNode then
      if not parentNode.children then
        parentNode.children = {}
      end
      local slotName = slotPath:match("/([^/]+)/$") or slotPath:match("/([^/]+)$") or ""
      if slotName and slotName ~= "" then
        local chosenPartName = (partName == "" or not partName) and "" or partName
        parentNode.children[slotName] = {
          chosenPartName = chosenPartName,
          path = slotPath,
          children = {},
          suitablePartNames = chosenPartName ~= "" and {chosenPartName} or {},
          unsuitablePartNames = {},
          decisionMethod = "user",
          emptyPlaceholder = (partName == "" or not partName) and true or nil
        }
        return true
      end
    end

    return false
  end

  -- Parts are placed shallowest first; a part whose parent slot is not in the tree yet waits for a later pass.
  local function applyPartsBySlotPath(partsTree, partsBySlotPath)
    if not partsTree or not partsBySlotPath then
      return
    end

    local orderedPaths = {}
    for slotPath, part in pairs(partsBySlotPath) do
      if slotPath and part and part.partName and part.partName ~= "" then
        table.insert(orderedPaths, slotPath)
      end
    end

    table.sort(orderedPaths, function(a, b)
      local depthA = getSlotPathDepth(a)
      local depthB = getSlotPathDepth(b)
      if depthA ~= depthB then
        return depthA < depthB
      end
      return a < b
    end)

    local pending = {}
    for _, slotPath in ipairs(orderedPaths) do
      local part = partsBySlotPath[slotPath]
      local applied = createOrUpdatePartsTreeNode(partsTree, part.partName, part.slotPath or slotPath)
      if not applied then
        pending[slotPath] = part
      end
    end

    if next(pending) then
      local progressed = true
      while progressed and next(pending) do
        progressed = false
        for slotPath, part in pairs(pending) do
          if createOrUpdatePartsTreeNode(partsTree, part.partName, part.slotPath or slotPath) then
            pending[slotPath] = nil
            progressed = true
          end
        end
      end
    end
  end

  -- Vehicle lookup ----------------------------------------------------------------------------------

  local function isPersonalVehicleId(vehicleId)
    if not vehicleId then
      return false
    end
    return tostring(vehicleId):sub(1, 9) == "personal_"
  end

  local function getSpawnedIdFromPersonalVehicleId(vehicleId)
    if not isPersonalVehicleId(vehicleId) then
      return nil
    end
    return tonumber(tostring(vehicleId):sub(10))
  end

  local function getBusinessVehicleObject(businessId, vehicleId)
    if not businessId or not vehicleId then
      return nil
    end

    if isPersonalVehicleId(vehicleId) then
      local spawnedId = getSpawnedIdFromPersonalVehicleId(vehicleId)
      if spawnedId then
        return getObjectByID(spawnedId)
      end
      return nil
    end

    local vehId = overhaul_career_business_fleet.getSpawnedVehicleId(businessId, vehicleId)
    if vehId then
      return getObjectByID(vehId)
    end

    return nil
  end

  local function getPartSupplierDiscountMultiplier(businessId)
    local businessComputer = capabilities.get("businessComputer")
    if businessComputer and businessComputer.getPartSupplierDiscountMultiplier then
      return businessComputer.getPartSupplierDiscountMultiplier(businessId)
    end
    return 1.0
  end

  -- Baselines ---------------------------------------------------------------------------------------

  local function firstWithPartsTree(first, second)
    if first and first.partsTree then
      return first
    end
    if second and second.partsTree then
      return second
    end
    return nil
  end

  -- Stored config for a fleet vehicle; without inventoryOnly, the live config wins when it is loadable and differs.
  local function fleetBaselineConfig(vehicle, vehicleData, inventoryOnly)
    local invConfig = vehicle.config
    local liveConfig = vehicleData and vehicleData.config or nil
    if inventoryOnly then
      return firstWithPartsTree(invConfig, liveConfig)
    end

    local invParts = (invConfig and invConfig.partsTree) and flattenPartsTree(invConfig.partsTree) or {}
    local liveParts = (liveConfig and liveConfig.partsTree) and flattenPartsTree(liveConfig.partsTree) or {}
    local liveLoadable = liveConfig and liveConfig.partsTree and liveConfig.partsTree.chosenPartName and
      liveConfig.partsTree.chosenPartName ~= ""
    if liveLoadable and partListFingerprint(liveParts) ~= partListFingerprint(invParts) then
      return liveConfig
    end
    return firstWithPartsTree(invConfig, liveConfig)
  end

  local function resolveBaselineVehicleConfig(vehicle, vehicleData, isPersonal, inventoryOnly)
    if not vehicle then
      return nil
    end
    if isPersonal then
      if inventoryOnly then return firstWithPartsTree(vehicle.config, vehicleData and vehicleData.config) end
      return firstWithPartsTree(vehicleData and vehicleData.config, vehicle.config)
    end
    return fleetBaselineConfig(vehicle, vehicleData, inventoryOnly)
  end

  local function resolveRestoreBaseline(businessId, vehicleId, session)
    if session and session.initial and session.initial.config then
      return deepcopy(session.initial.config), deepcopy(session.initial.partConditions or {})
    end
    local vehicle = nil
    if isPersonalVehicleId(vehicleId) then
      vehicle = sharedParts.preview.getPersonalVehicleData(vehicleId, businessId)
    else
      vehicle = overhaul_career_business_fleet and
        overhaul_career_business_fleet.getVehicleById(businessId, vehicleId) or nil
    end

    if vehicle and vehicle.config and vehicle.config.partsTree then
      return deepcopy(vehicle.config), deepcopy(vehicle.partConditions or {})
    end
    if session and session.initial and session.initial.config then
      return deepcopy(session.initial.config), deepcopy(session.initial.partConditions or {})
    end
    return nil, nil
  end

  local function refreshSessionInitialFromSavedVehicle(businessId, vehicleId, inventoryOnly)
    if not businessId or not vehicleId then
      return false
    end

    local isPersonal = isPersonalVehicleId(vehicleId)
    local vehicle = nil
    if isPersonal then
      vehicle = sharedParts.preview.getPersonalVehicleData(vehicleId, businessId)
    else
      vehicle = overhaul_career_business_fleet.getVehicleById(businessId, vehicleId)
    end

    if not vehicle or not vehicle.vehicleConfig then
      return false
    end

    local vehObj = getBusinessVehicleObject(businessId, vehicleId)
    local vehicleData = nil
    if vehObj and not inventoryOnly then
      vehicleData = extensions.core_vehicle_manager.getVehicleData(vehObj:getID())
    end

    local originalConfig = resolveBaselineVehicleConfig(vehicle, vehicleData, isPersonal, inventoryOnly == true)
    if not originalConfig then
      return false
    end

    local modelKey = vehicle.vehicleConfig.model_key or vehicle.model_key
    local session = sharedParts.preview.ensureActiveSession(businessId, vehicleId)
    if not session then
      return false
    end

    session.initial.config = deepcopy(originalConfig)
    session.initial.partList = flattenPartsTree(originalConfig.partsTree or {})
    session.initial.partConditions = deepcopy(vehicle.partConditions or {})
    session.initial.vars = deepcopy(vehicle.vars or {})
    session.initial.model = modelKey
    return true
  end

  local function sessionPreviewDiffersFromInitial(session)
    if not session or not session.initial or not session.preview then
      return false
    end

    local initialParts = session.initial.partList or flattenPartsTree(session.initial.config.partsTree or {})
    local previewParts = session.preview.partList or flattenPartsTree(session.preview.config.partsTree or {})
    if partListFingerprint(initialParts) ~= partListFingerprint(previewParts) then return true end
    local originalVars = session.initial.vars or session.initial.config.vars or {}
    local previewVars = session.preview.config.vars or {}
    for name, value in pairs(originalVars) do if previewVars[name] ~= value then return true end end
    for name, value in pairs(previewVars) do if originalVars[name] ~= value then return true end end
    return false
  end

  local function liveVehicleMatchesBaseline(vehObj, baselineParts, baselineVars)
    if not vehObj or not baselineParts then
      return false
    end

    local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehObj:getID())
    if not vehicleData or not vehicleData.config or not vehicleData.config.partsTree then
      return false
    end

    local liveParts = flattenPartsTree(vehicleData.config.partsTree or {})
    for name, value in pairs(baselineVars or {}) do
      local liveValue = vehicleData.config.vars and vehicleData.config.vars[name]
      if liveValue == nil then
        local variable = vehicleData.vdata and vehicleData.vdata.variables and vehicleData.vdata.variables[name]
        liveValue = variable and variable.val
      end
      if liveValue ~= value then return false end
    end
    return partListFingerprint(liveParts) == partListFingerprint(baselineParts)
  end

  -- Fuel ----------------------------------------------------------------------------------------------

  local function storeFuelLevels(vehObj, callback)
    if not vehObj then
      if callback then
        callback()
      end
      return
    end

    core_vehicleBridge.requestValue(vehObj, function(data)
      local storedFuelLevels = {}
      if data and data[1] then
        for _, tank in ipairs(data[1]) do
          if tank.energyType ~= "n2o" then
            storedFuelLevels[tank.name] = {
              currentEnergy = tank.currentEnergy,
              maxEnergy = tank.maxEnergy,
              energyType = tank.energyType,
              relativeFuel = tank.maxEnergy > 0 and (tank.currentEnergy / tank.maxEnergy) or 0
            }
          end
        end
      end
      if callback then
        callback(storedFuelLevels)
      end
    end, 'energyStorage')
  end

  local function restoreFuelLevels(vehObj, storedFuelLevels, canContinue)
    if not vehObj or not storedFuelLevels or not next(storedFuelLevels) then
      return
    end
    if canContinue and not canContinue() then return end

    core_vehicleBridge.requestValue(vehObj, function(data)
      if canContinue and not canContinue() then return end
      if not data or not data[1] then
        return
      end

      for _, tank in ipairs(data[1]) do
        local stored = storedFuelLevels[tank.name]
        if stored and stored.energyType == tank.energyType then
          local newFuelAmount = math.min(stored.currentEnergy, tank.maxEnergy)
          if tank.maxEnergy > stored.maxEnergy then
            newFuelAmount = tank.maxEnergy * stored.relativeFuel
          end

          local minFuel = tank.maxEnergy * 0.05
          newFuelAmount = math.max(newFuelAmount, minFuel)

          if canContinue and not canContinue() then return end
          core_vehicleBridge.executeAction(vehObj, 'setEnergyStorageEnergy', tank.name, newFuelAmount)
        end
      end
    end, 'energyStorage')
  end

  -- Power and weight --------------------------------------------------------------------------------

  -- One live owner applies the type policy so both callers keep the same dyno decision.
  local function powerReadAllowed(businessId)
    local businessServices = capabilities.get("businessServices")
    if not businessServices then
      return false
    end
    return businessServices.dynoPowerReadAllowed(businessId) == true
  end

  -- ignoreDynoGate skips the dyno-skill check (used right after a purchase).
  local function requestVehiclePowerWeight(vehObj, businessId, vehicleId, ignoreDynoGate)
    if not vehObj or not businessId or not vehicleId then
      return
    end

    if not ignoreDynoGate and not powerReadAllowed(businessId) then
      return
    end

    -- Request ids cannot be split back into ids: vehicle ids contain underscores.
    local cacheKey = businessId .. "_" .. tostring(vehicleId)
    local requestId = cacheKey .. "_" .. tostring(os.clock())
    if runtime.pendingPowerRequestCount >= 64 then
      runtime.pendingPowerRequests = {}
      runtime.pendingPowerRequestCount = 0
    end
    runtime.pendingPowerRequests[requestId] = { businessId = tostring(businessId), vehicleId = tostring(vehicleId) }
    runtime.pendingPowerRequestCount = runtime.pendingPowerRequestCount + 1

    vehObj:queueLuaCommand([[
    local engine = powertrain.getDevicesByCategory("engine")[1]
    local stats = obj:calcBeamStats()
    if engine and stats then
      local power = engine.maxPower
      local weight = stats.total_weight
      local torque = nil
      if v and v.data and v.data.mainEngine and v.data.mainEngine.torque then
         torque = serialize(v.data.mainEngine.torque)
      end
      if power and weight and weight > 0 then
        obj:queueGameEngineLua(require('vehicle/overhaul/geCallback').command('partCustomizationPowerWeight', "']] .. requestId ..
                             [[', " .. power .. ", " .. weight .. ", " .. (torque or "nil")))
      end
    end
  ]])
  end

  return {
    applyPartsBySlotPath = applyPartsBySlotPath,
    flattenPartsTree = flattenPartsTree,
    getBusinessVehicleObject = getBusinessVehicleObject,
    getNodeFromSlotPath = getNodeFromSlotPath,
    getPartSupplierDiscountMultiplier = getPartSupplierDiscountMultiplier,
    isPersonalVehicleId = isPersonalVehicleId,
    powerReadAllowed = powerReadAllowed,
    liveVehicleMatchesBaseline = liveVehicleMatchesBaseline,
    refreshSessionInitialFromSavedVehicle = refreshSessionInitialFromSavedVehicle,
    requestVehiclePowerWeight = requestVehiclePowerWeight,
    resolveBaselineVehicleConfig = resolveBaselineVehicleConfig,
    resolveRestoreBaseline = resolveRestoreBaseline,
    restoreFuelLevels = restoreFuelLevels,
    sessionPreviewDiffersFromInitial = sessionPreviewDiffersFromInitial,
    storeFuelLevels = storeFuelLevels,
  }
end

return installer
