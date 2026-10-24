-- Business computer parts: supplier discounts, owned parts, removed parts and tree payloads.
-- Read discounts, owned-part lookups, removed parts, tree formatting, publishers, then request routing.
local installer = {}

-- Each construction shares state and helpers with that owner load.
function installer.new(inputs)
  local slotLabels = require("overhaul/lib/parts/slotLabels")
  local api = {}


  local METERS_PER_MILE = 1609.344

  -- Supplier discounts and owned parts ----------------------------------------------------------

  function api.getPartSupplierDiscountMultiplier(businessId)
    if not businessId then
      return 1.0
    end

    local _, businessType = inputs.resolveBusinessModule(businessId)
    if businessType then
      local businessObj = overhaul_career_business_manager.getBusinessObject(businessType)
      if businessObj and businessObj.getPartSupplierDiscountMultiplier then
        return businessObj.getPartSupplierDiscountMultiplier(businessId)
      end
    end

    return 1.0
  end

  -- A description is either a string or a table with a description string inside it.
  local function descriptionText(description)
    return type(description) == "table" and description.description or description
  end

  -- Groups the owned parts of one model by part name; each variant keeps its own condition and mileage.
  local function buildOwnedPartsLookup(inventoryParts, vehicleModel)
    if not inventoryParts then
      return nil
    end

    local lookup = {}
    for _, part in ipairs(inventoryParts) do
      if part and part.name then
        if not part.vehicleModel or part.vehicleModel == vehicleModel then
          local mileage = part.mileage
          if not mileage and part.partCondition and part.partCondition.odometer then
            mileage = part.partCondition.odometer / METERS_PER_MILE
          end
          local variant = {
            partId = part.partId,
            name = part.name,
            partCondition = part.partCondition,
            finalValue = part.finalValue,
            value = part.value,
            mileage = mileage
          }
          lookup[part.name] = lookup[part.name] or {}
          table.insert(lookup[part.name], variant)
        end
      end
    end
    return lookup
  end

  local function ownedPartsLookupFor(vehicleModel, businessId)
    if not vehicleModel then
      return nil
    end

    local inventoryParts = overhaul_career_business_partInventory.getPartsByModel(vehicleModel, businessId)
    return buildOwnedPartsLookup(inventoryParts, vehicleModel)
  end

  -- Removed parts from a cart ---------------------------------------------------------------------

  -- Keep live conditions with the live tree so the UI values the vehicle's current wear.
  local function readLivePartsTree(businessId, vehicleId, originalPartList, partConditions)
    local vehObj = inputs.parts.vehicles.getBusinessVehicleObject(businessId, vehicleId)
    if not vehObj then
      return partConditions
    end

    local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehObj:getID())
    if not (vehicleData and vehicleData.config and vehicleData.config.partsTree) then
      return partConditions
    end

    local function extractParts(tree, path)
      path = path or "/"
      if tree.chosenPartName and tree.path then
        originalPartList[tree.path] = tree.chosenPartName
      end
      if tree.children then
        for slotName, child in pairs(tree.children) do
          local childPath = path .. slotName .. "/"
          extractParts(child, childPath)
        end
      end
    end
    extractParts(vehicleData.config.partsTree)

    return vehicleData.partConditions or partConditions
  end

  local function cartPartsBySlot(cartParts)
    local bySlot = {}
    for _, part in ipairs(cartParts) do
      if part.slotPath and part.partName and part.partName ~= "" then
        bySlot[part.slotPath] = part.partName
      elseif part.slotPath and part.emptyPlaceholder then
        bySlot[part.slotPath] = ""
      end
    end
    return bySlot
  end

  local function removedPartData(vehicle, vehicleModel, slotPath, originalPartName, partConditions)
    local partCondition = partConditions[slotPath .. originalPartName]
    if not partCondition then
      partCondition = {
        integrityValue = 1,
        visualValue = 1,
        odometer = 0
      }
    end

    local partData = {
      name = originalPartName,
      containingSlot = slotPath,
      slot = slotPath:match("/([^/]+)/$") or slotPath:match("/([^/]+)$") or "",
      vehicleModel = vehicleModel,
      year = vehicle.year,
      partCondition = partCondition,
      partPath = slotPath .. originalPartName,
      rlsTireState = vehicle.rlsTireStateByPartPath and
                       deepcopy(vehicle.rlsTireStateByPartPath[slotPath .. originalPartName]) or nil,
    }

    partData.value = overhaul_career_market_valueCalculator.getPartValue(partData, true) or 0
    return partData
  end

  function api.findRemovedPartsFromCart(businessId, vehicleId, cartParts, baselinePartList, baselinePartConditions)
    if not businessId or not vehicleId or not cartParts then
      return {}
    end

    local vehicle = overhaul_career_business_fleet.getVehicleById(businessId, vehicleId)
    if not vehicle then
      return {}
    end

    local vehicleModel = vehicle.vehicleConfig and vehicle.vehicleConfig.model_key or vehicle.model_key
    local originalPartList = baselinePartList or vehicle.partList or {}
    local partConditions = baselinePartConditions or vehicle.partConditions or {}

    if next(originalPartList) == nil and not baselinePartList then
      partConditions = readLivePartsTree(businessId, vehicleId, originalPartList, partConditions)
    end

    local cartBySlot = cartPartsBySlot(cartParts)
    local removedParts = {}
    for slotPath, originalPartName in pairs(originalPartList) do
      if originalPartName and originalPartName ~= "" then
        local cartPartName = cartBySlot[slotPath]
        if cartPartName ~= nil and cartPartName ~= originalPartName then
          table.insert(removedParts, removedPartData(vehicle, vehicleModel, slotPath, originalPartName, partConditions))
        end
      end
    end

    return removedParts
  end

  -- Tree formatting -------------------------------------------------------------------------------

  local function getUIDescription(value, fallback)
    if type(value) == "table" then
      value = value.description
    end
    if value == nil or value == "" then
      return fallback or ""
    end
    return value
  end

  local function resolveSlotNiceName(node, slotName, slotInfo)
    if slotInfo then return descriptionText(slotLabels.getLabel(slotName, slotInfo)) end
    return getUIDescription(node.slotNiceName, slotName)
  end

  local function resolvePartNiceName(node, availableParts, partsNiceName)
    if node.chosenPartName and availableParts[node.chosenPartName] then
      local partNiceName = descriptionText(availableParts[node.chosenPartName].description) or node.chosenPartName
      partsNiceName[node.chosenPartName] = partNiceName
      return partNiceName
    elseif node.chosenPartName then
      return node.chosenPartName
    end
    return node.chosenPartNiceName or ""
  end

  -- The part's value for this slot: catalogue value, priced through the market, then the business discount.
  local function offeredPartValue(partName, partInfoData, options)
    local baseValue = 100
    if options.ioContext then
      local jbeamData = inputs.jbeamIO.getPart(options.ioContext, partName)
      if jbeamData and jbeamData.information and jbeamData.information.value then
        baseValue = jbeamData.information.value
      elseif partInfoData.information and partInfoData.information.value then
        baseValue = partInfoData.information.value
      end
    elseif partInfoData.information and partInfoData.information.value then
      baseValue = partInfoData.information.value
    end

    local value = baseValue
    if options.vehicleModel then
      local partForValueCalc = {
        name = partName,
        value = baseValue,
        partCondition = {
          integrityValue = 1,
          odometer = 0,
          visualValue = 1
        },
        vehicleModel = options.vehicleModel
      }
      value = math.max(roundNear(overhaul_career_market_valueCalculator.getPartValue(partForValueCalc), 5) - 0.01, 0)
    end

    if options.businessId and value > 0 then
      value = value * api.getPartSupplierDiscountMultiplier(options.businessId)
    end
    return value
  end

  local function buildAvailablePartsList(node, options)
    local availablePartsList = {}
    for _, partName in ipairs(node.suitablePartNames) do
      local partInfoData = options.availableParts[partName]
      if partInfoData then
        table.insert(availablePartsList, {
          name = partName,
          niceName = descriptionText(partInfoData.description) or partName,
          value = offeredPartValue(partName, partInfoData, options),
          installed = (node.chosenPartName == partName)
        })
      end
    end
    return availablePartsList
  end

  local function findEntryByName(entries, partName)
    for _, entry in ipairs(entries) do
      if entry.name == partName then
        return entry
      end
    end
    return nil
  end

  -- Adds the owned variants of each suitable part to the slot's offers; returns the variants for the slot.
  local function appendOwnedVariants(node, availablePartsList, options)
    local slotCompatibleVariants = {}
    if not options.ownedPartsByName then
      return slotCompatibleVariants
    end

    for _, partName in ipairs(node.suitablePartNames) do
      local variants = options.ownedPartsByName[partName]
      if variants and #variants > 0 then
        local existingEntry = findEntryByName(availablePartsList, partName)
        if not existingEntry then
          local partInfoData = options.availableParts[partName]
          local niceName = partName
          if partInfoData then
            niceName = descriptionText(partInfoData.description) or partName
          end
          existingEntry = {
            name = partName,
            niceName = niceName,
            value = 0,
            installed = false,
            fromInventory = true,
            isOwned = true
          }
          table.insert(availablePartsList, existingEntry)
        end
        existingEntry.hasOwnedVariants = true
        existingEntry.ownedVariants = variants
        for _, variant in ipairs(variants) do
          table.insert(slotCompatibleVariants, variant)
        end
      end
    end
    return slotCompatibleVariants
  end

  local function sortByNiceName(entries)
    table.sort(entries, function(a, b)
      local nameA = string.lower(a.niceName or a.name or "")
      local nameB = string.lower(b.niceName or b.name or "")
      return nameA < nameB
    end)
  end

  -- Only a part the slot is free to drop can be removed: core slots keep their part.
  local function canRemovePart(node, currentSlotInfo)
    if currentSlotInfo and not currentSlotInfo.coreSlot and node.chosenPartName and node.chosenPartName ~= "" then
      return true
    end
    return false
  end

  -- One slot's entry in the flat list, or nil when the slot offers no parts.
  local function formatSlotEntry(node, currentPath, slotName, slotNiceName, partNiceName, currentSlotInfo, parentSlotName, options)
    local availablePartsList = buildAvailablePartsList(node, options)
    local slotCompatibleVariants = appendOwnedVariants(node, availablePartsList, options)
    sortByNiceName(availablePartsList)
    if #availablePartsList == 0 then
      return nil
    end

    return {
      id = currentPath,
      path = currentPath,
      slotName = slotName or "",
      slotNiceName = slotNiceName,
      chosenPartName = node.chosenPartName or "",
      partNiceName = partNiceName,
      canRemove = canRemovePart(node, currentSlotInfo),
      availableParts = availablePartsList,
      compatibleInventoryParts = slotCompatibleVariants,
      parentSlotName = parentSlotName
    }
  end

  -- Flat list of the slot and every slot under it, in the order the tree's children are visited.
  local function formatPartsTreeForUI(node, slotName, slotInfo, pathPrefix, parentSlotName, options)
    if not node then
      return {}
    end

    local result = {}
    local currentPath = node.path or pathPrefix or "/"
    local isRootNode = (currentPath == "/" or currentPath == "" or slotName == "")

    options.slotInfoByPath[currentPath] = slotInfo
    local slotNiceName = resolveSlotNiceName(node, slotName, slotInfo)
    local partNiceName = resolvePartNiceName(node, options.availableParts, options.partsNiceName)

    local partInfo = nil
    if node.chosenPartName and options.availableParts[node.chosenPartName] then
      partInfo = options.availableParts[node.chosenPartName]
    end

    local currentSlotInfo = slotInfo
    if not currentSlotInfo and partInfo and partInfo.slotInfoUi and slotName then
      currentSlotInfo = partInfo.slotInfoUi[slotName]
    end

    if not isRootNode and node.suitablePartNames and #node.suitablePartNames > 0 then
      local entry = formatSlotEntry(node, currentPath, slotName, slotNiceName, partNiceName, currentSlotInfo, parentSlotName, options)
      if entry then
        table.insert(result, entry)
      end
    end

    if node.children and next(node.children) then
      local parentData = options.ioContext and node.chosenPartName and node.chosenPartName ~= "" and
        inputs.jbeamIO.getPart(options.ioContext, node.chosenPartName)
      for childSlotName, childNode in pairs(node.children) do
        local childPath = (currentPath == "/" and "" or currentPath) .. childSlotName .. "/"
        local childSlotInfo = slotLabels.getSlotInfo(parentData, childSlotName) or slotLabels.getSlotInfo(partInfo, childSlotName)
        local childResults = formatPartsTreeForUI(childNode, childSlotName, childSlotInfo, childPath, slotNiceName, options)
        for _, childResult in ipairs(childResults) do
          table.insert(result, childResult)
        end
      end
    end

    return result
  end

  -- Hierarchical slots retain parent relationships that the flat search list cannot represent.
  local function buildPartsTreeHierarchyForUI(node, slotName, slotsNiceName, partsNiceName, pathPrefix, slotInfoByPath)
    if not node then return nil end

    local treeNode = deepcopy(node)
    local currentPath = node.path or pathPrefix or "/"
    local slotFallback = resolveSlotNiceName(node, slotName, slotInfoByPath[currentPath])
    local partFallback = getUIDescription(partsNiceName[node.chosenPartName], node.chosenPartName)

    treeNode.path = currentPath
    treeNode.slotName = slotName or ""
    treeNode.slotNiceName = slotFallback
    slotsNiceName[currentPath] = treeNode.slotNiceName
    treeNode.chosenPartNiceName = getUIDescription(node.chosenPartNiceName, partFallback)
    treeNode.children = {}

    for childSlotName, childNode in pairs(node.children or {}) do
      local childPath = (currentPath == "/" and "" or currentPath) .. childSlotName .. "/"
      treeNode.children[childSlotName] = buildPartsTreeHierarchyForUI(
        childNode,
        childSlotName,
        slotsNiceName,
        partsNiceName,
        childPath,
        slotInfoByPath
      )
    end

    return treeNode
  end

  -- Publishing ------------------------------------------------------------------------------------

  local function triggerPartsTree(payload)
    guihooks.trigger('businessComputer:onVehiclePartsTree', payload)
  end

  local function publishPartsTreeError(message)
    triggerPartsTree({success = false, error = message})
  end

  local function hasPartsTree(vehicleData)
    return vehicleData and vehicleData.config and vehicleData.config.partsTree
  end

  -- The slot and part nice names of one vehicle's catalogue, keyed by slot and part name.
  local function readPartCatalog(ioContext)
    local availableParts = inputs.jbeamIO.getAvailableParts(ioContext)
    local slotsNiceName = {}
    local partsNiceName = {}

    for partName, partInfo in pairs(availableParts) do
      if partInfo.slotInfoUi then
        for slotName, slotInfo in pairs(partInfo.slotInfoUi) do
          slotsNiceName[slotName] = descriptionText(slotInfo.description)
        end
      end
      partsNiceName[partName] = descriptionText(partInfo.description)
    end

    return {availableParts = availableParts, slotsNiceName = slotsNiceName, partsNiceName = partsNiceName}
  end

  -- The flat list and the hierarchy the UI shows for one vehicle's parts tree.
  local function buildPartsTreeViews(vehicleData, businessId, catalog, vehicleModel, ownedPartsLookup)
    local options = {
      availableParts = catalog.availableParts,
      slotInfoByPath = {},
      slotsNiceName = catalog.slotsNiceName,
      partsNiceName = catalog.partsNiceName,
      ioContext = vehicleData.ioCtx,
      businessId = businessId,
      vehicleModel = vehicleModel,
      ownedPartsByName = ownedPartsLookup,
    }
    local flatTree = formatPartsTreeForUI(vehicleData.config.partsTree, "", nil, "/", nil, options)
    return {
      partsTree = flatTree,
      partTreeHierarchy = buildPartsTreeHierarchyForUI(vehicleData.config.partsTree, "", catalog.slotsNiceName, catalog.partsNiceName, "/", options.slotInfoByPath),
    }
  end

  local function publishPersonalVehiclePartsTree(businessId, vehicleId)
    local spawnedId = inputs.parts.vehicles.getSpawnedIdFromPersonalVehicleId(vehicleId)
    if not spawnedId then
      publishPartsTreeError("Invalid personal vehicle ID")
      return
    end

    local vehicleData = extensions.core_vehicle_manager.getVehicleData(spawnedId)
    if not hasPartsTree(vehicleData) then
      publishPartsTreeError("No parts tree found for personal vehicle")
      return
    end

    local catalog = readPartCatalog(vehicleData.ioCtx)
    local vehObj = be:getObjectByID(spawnedId)
    local personalVehicleModel = vehObj and vehObj:getJBeamFilename() or nil
    local tree = buildPartsTreeViews(vehicleData, businessId, catalog, personalVehicleModel, nil)

    triggerPartsTree({
      success = true,
      businessId = businessId,
      vehicleId = vehicleId,
      partsTree = tree.partsTree,
      partTreeHierarchy = tree.partTreeHierarchy,
      slotsNiceName = catalog.slotsNiceName,
      partsNiceName = catalog.partsNiceName,
      isPersonal = true
    })
  end

  -- A business vehicle that is already spawned: answer at once, without a cache write.
  local function publishSpawnedPartsTree(businessId, vehicleId, initialVehicle, spawnedVehicleId)
    local vehicleData = extensions.core_vehicle_manager.getVehicleData(spawnedVehicleId)
    if not hasPartsTree(vehicleData) then
      return false
    end

    local catalog = readPartCatalog(vehicleData.ioCtx)
    local vehicleModel = initialVehicle.vehicleConfig and initialVehicle.vehicleConfig.model_key or initialVehicle.model_key
    local tree = buildPartsTreeViews(vehicleData, businessId, catalog, vehicleModel, ownedPartsLookupFor(vehicleModel, businessId))

    triggerPartsTree({
      success = true,
      businessId = businessId,
      vehicleId = vehicleId,
      partsTree = tree.partsTree,
      partTreeHierarchy = tree.partTreeHierarchy,
      slotsNiceName = catalog.slotsNiceName,
      partsNiceName = catalog.partsNiceName
    })
    return true
  end

  -- Answers from the cache when the stored vehicle is unchanged and no preview config is pending.
  local function publishCachedPartsTree(businessId, vehicleId, initialVehicle, partsCacheKey, previewConfig)
    local cachedEntry = inputs.getCachedPartsTree(businessId, partsCacheKey)
    if not (cachedEntry and cachedEntry.vehicleId == initialVehicle.vehicleId and not previewConfig) then
      return false
    end

    triggerPartsTree({
      success = true,
      businessId = businessId,
      vehicleId = vehicleId,
      partsTree = cachedEntry.partsTree,
      partTreeHierarchy = cachedEntry.partTreeHierarchy,
      slotsNiceName = cachedEntry.slotsNiceName,
      partsNiceName = cachedEntry.partsNiceName
    })
    return true
  end

  -- Runs inside the pcall around a temporarily spawned vehicle, which the caller deletes afterwards.
  local function publishBuiltPartsTree(businessId, vehicleId, vehicle, vehicleObj)
    local vehId = vehicleObj:getID()
    local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehId)
    if not hasPartsTree(vehicleData) then
      log("W", "businessComputer", "requestVehiclePartsTree: No parts tree for business vehicle")
      publishPartsTreeError("No parts tree found")
      return
    end

    local catalog = readPartCatalog(vehicleData.ioCtx)
    local vehicleModel = vehicle.vehicleConfig.model_key or vehicle.model_key
    local tree = buildPartsTreeViews(vehicleData, businessId, catalog, vehicleModel, ownedPartsLookupFor(vehicleModel, businessId))

    local cacheKey = inputs.parts.vehicles.partsTreeCacheKeyForBusinessVehicle(businessId, vehicleId, vehicle, false)
    inputs.setCachedPartsTree(businessId, cacheKey, {
      vehicleId = vehicle.vehicleId,
      partsTree = tree.partsTree,
      partTreeHierarchy = tree.partTreeHierarchy,
      slotsNiceName = catalog.slotsNiceName,
      partsNiceName = catalog.partsNiceName
    })

    triggerPartsTree({
      success = true,
      businessId = businessId,
      vehicleId = vehicleId,
      partsTree = tree.partsTree,
      partTreeHierarchy = tree.partTreeHierarchy,
      slotsNiceName = catalog.slotsNiceName,
      partsNiceName = catalog.partsNiceName,
      isPersonal = false
    })
  end

  -- Spawns the stored vehicle off-screen as a job, builds its tree and always deletes it again.
  local function buildStoredVehiclePartsTree(businessId, vehicleId, normalizedVehicleId)
    core_jobsystem.create(function(job)
      local vehicle = overhaul_career_business_fleet.getVehicleById(businessId, normalizedVehicleId)
      if not vehicle or not vehicle.vehicleConfig then
        publishPartsTreeError("Vehicle not found")
        return
      end

      local modelKey = vehicle.vehicleConfig.model_key or vehicle.model_key
      local configKey = vehicle.vehicleConfig.key or vehicle.config_key
      if not modelKey or not configKey then
        publishPartsTreeError("Invalid vehicle config")
        return
      end

      local configToUse = configKey
      local previewConfig = overhaul_career_business_partCustomization.getPreviewVehicleConfig(businessId)
      if previewConfig then
        configToUse = previewConfig
      end

      local levelData = require("overhaul/lib/world/levelData")
      local levelId = getCurrentLevelIdentifier()
      local locations = levelId and jsonReadFile("/levels/" .. levelId .. "/careerLocations.json")
      local staging = locations and levelData.resolveSpawn(locations.inspectionStaging, levelId)
      if not staging then
        log("W", "businessComputer", "No inspection staging configured for " .. tostring(levelId))
        publishPartsTreeError("No local inspection staging configured")
        return
      end
      local vehicleObj = core_vehicles.spawnNewVehicle(modelKey, {
        config = configToUse,
        pos = staging.pos,
        rot = staging.rot,
        keepLoaded = true,
        autoEnterVehicle = false
      })
      if not vehicleObj then
        publishPartsTreeError("Failed to spawn vehicle")
        return
      end

      vehicleObj:setActive(0)
      local ok, err = pcall(publishBuiltPartsTree, businessId, vehicleId, vehicle, vehicleObj)
      vehicleObj:delete()
      if not ok then
        log("E", "businessComputer", "requestVehiclePartsTree: " .. tostring(err))
        publishPartsTreeError("Unable to build parts tree")
      end
    end)
  end

  -- Public ----------------------------------------------------------------------------------------

  function api.requestVehiclePartsTree(businessId, vehicleId)
    if not businessId or not vehicleId then
      publishPartsTreeError("Missing parameters")
      return
    end

    if inputs.parts.vehicles.isPersonalVehicleId(vehicleId) then
      return publishPersonalVehiclePartsTree(businessId, vehicleId)
    end

    local normalizedVehicleId = tonumber(vehicleId) or vehicleId
    local initialVehicle = overhaul_career_business_fleet.getVehicleById(businessId, normalizedVehicleId)
    if not initialVehicle then
      publishPartsTreeError("Vehicle not found")
      return
    end

    local partsCacheKey = inputs.parts.vehicles.partsTreeCacheKeyForBusinessVehicle(businessId, vehicleId, initialVehicle, false)

    local spawnedVehicleId = overhaul_career_business_fleet.getSpawnedVehicleId(businessId, normalizedVehicleId)
    if spawnedVehicleId and publishSpawnedPartsTree(businessId, vehicleId, initialVehicle, spawnedVehicleId) then
      return
    end

    local previewConfig = overhaul_career_business_partCustomization.getPreviewVehicleConfig(businessId)
    if publishCachedPartsTree(businessId, vehicleId, initialVehicle, partsCacheKey, previewConfig) then
      return
    end

    buildStoredVehiclePartsTree(businessId, vehicleId, normalizedVehicleId)
  end

  return api
end

return installer
