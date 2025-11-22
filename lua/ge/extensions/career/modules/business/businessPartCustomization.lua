local M = {}

M.dependencies = {'career_career', 'core_vehicles', 'core_jobsystem'}

local jbeamIO = require('jbeam/io')
local jbeamSlotSystem = require('jbeam/slotSystem')

local currentSession = nil

local function resetCurrentSession()
  currentSession = nil
end

local function sessionMatches(businessId, vehicleId)
  if not currentSession then
    return false
  end
  if currentSession.businessId ~= businessId then
    return false
  end
  if vehicleId and currentSession.vehicleId ~= vehicleId then
    return false
  end
  return true
end

local function getActiveSession(businessId)
  if sessionMatches(businessId) then
    return currentSession
  end
  return nil
end

local function getPartSupplierDiscountMultiplier(businessId)
  if not businessId or not career_modules_business_businessSkillTree then
    return 1.0
  end

  local businessType = "tuningShop"
  local treeId = "shop-upgrades"
  local nodeId = "part-suppliers"

  local level = career_modules_business_businessSkillTree.getNodeProgress(businessId, treeId, nodeId) or 0
  return 1.0 - (0.05 * level)
end

local function getBusinessVehicleObject(businessId, vehicleId)
  if not businessId or not vehicleId then
    return nil
  end

  if career_modules_business_businessInventory then
    local vehId = career_modules_business_businessInventory.getSpawnedVehicleId(businessId, vehicleId)
    if vehId then
      return getObjectByID(vehId)
    end
  end

  return nil
end

local function flattenPartsTree(tree)
  local result = {}
  if not tree then
    return result
  end

  if tree.chosenPartName then
    result[tree.path] = tree.chosenPartName
  end

  if tree.children then
    for slotName, childNode in pairs(tree.children) do
      tableMerge(result, flattenPartsTree(childNode))
    end
  end

  return result
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

local function restoreFuelLevels(vehObj, storedFuelLevels)
  if not vehObj or not storedFuelLevels or not next(storedFuelLevels) then
    return
  end

  core_vehicleBridge.requestValue(vehObj, function(data)
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

        core_vehicleBridge.executeAction(vehObj, 'setEnergyStorageEnergy', tank.name, newFuelAmount)
      end
    end
  end, 'energyStorage')
end

local function requestVehiclePowerWeight(vehObj, businessId, vehicleId)
  if not vehObj or not businessId or not vehicleId then
    return
  end

  if career_modules_business_businessSkillTree then
    local dynoLevel = career_modules_business_businessSkillTree.getNodeProgress(businessId, "shop-upgrades", "dyno") or
                        0
    if dynoLevel == 0 then
      return
    end
  end

  local cacheKey = businessId .. "_" .. tostring(vehicleId)
  local requestId = cacheKey .. "_" .. tostring(os.clock())

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
        obj:queueGameEngineLua("career_modules_business_businessPartCustomization.onPowerWeightReceived(']] .. requestId ..
                           [[', " .. power .. ", " .. weight .. ", " .. (torque or "nil") .. ")")
      end
    end
  ]])
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

local function replaceVehicleWithFuelHandling(vehObj, modelKey, config, beforeRestoreCallback, afterRestoreCallback)
  if not vehObj or not modelKey or not config then
    if afterRestoreCallback then
      afterRestoreCallback()
    end
    return
  end

  local vehId = vehObj:getID()
  storeFuelLevels(vehObj, function(storedFuelLevels)
    local additionalVehicleData = {
      spawnWithEngineRunning = false
    }
    core_vehicle_manager.queueAdditionalVehicleData(additionalVehicleData, vehId)

    local spawnOptions = {}
    spawnOptions.config = config
    spawnOptions.keepOtherVehRotation = true

    core_vehicles.replaceVehicle(modelKey, spawnOptions, vehObj)

    if beforeRestoreCallback then
      beforeRestoreCallback()
    end

    core_vehicleBridge.requestValue(vehObj, function()
      restoreFuelLevels(vehObj, storedFuelLevels)
      if afterRestoreCallback then
        afterRestoreCallback()
      end
    end, 'ping')
  end)
end

local function initializePreviewVehicle(businessId, vehicleId)
  if not businessId or not vehicleId then
    return false
  end

  local vehicle = career_modules_business_businessInventory.getVehicleById(businessId, vehicleId)
  if not vehicle or not vehicle.vehicleConfig then
    return false
  end

  local vehObj = getBusinessVehicleObject(businessId, vehicleId)
  if not vehObj then
    return false
  end

  local vehId = vehObj:getID()
  local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehId)

  -- We need vehicleData for ioCtx later, but config should come from storage if possible
  if not vehicleData then
    return false
  end

  -- Store initial vehicle state from the stored vehicle config (baseline from inventory)
  -- PRIORITIZE vehicle.config from storage as it contains the purchase result
  local originalConfig = nil

  if vehicle.config and vehicle.config.partsTree then
    originalConfig = vehicle.config
  elseif vehicleData.config and vehicleData.config.partsTree then
    originalConfig = vehicleData.config
  else
    return false
  end

  local modelKey = vehicle.vehicleConfig.model_key or vehicle.model_key

  local initialState = {
    config = deepcopy(originalConfig),
    partList = flattenPartsTree(originalConfig.partsTree or {}),
    partConditions = deepcopy(vehicle.partConditions or {}),
    vars = deepcopy(vehicle.vars or {}),
    model = modelKey,
    vehicleId = vehicleId,
    partsNiceName = {}
  }

  local previewState = {
    config = deepcopy(originalConfig),
    partList = flattenPartsTree(originalConfig.partsTree or {}),
    partConditions = deepcopy(vehicle.partConditions or {}),
    model = modelKey
  }

  local slotData = {}
  local availableParts = jbeamIO.getAvailableParts(vehicleData.ioCtx)
  local partsNiceName = {}
  for partName, partInfo in pairs(availableParts) do
    local desc = partInfo.description
    partsNiceName[partName] = type(desc) == "table" and desc.description or desc
    if partInfo.slotInfoUi then
      for slotName, slotInfo in pairs(partInfo.slotInfoUi) do
        local path = "/" .. slotName .. "/"
        slotData[path] = slotInfo
      end
    end
  end
  initialState.partsNiceName = partsNiceName

  currentSession = {
    businessId = businessId,
    vehicleId = vehicleId,
    initial = initialState,
    preview = previewState,
    slotData = slotData,
    powerWeight = nil,
    operationInProgress = false
  }

  return true
end

local function ensureActiveSession(businessId, vehicleId)
  local session = getActiveSession(businessId)
  if session and (not vehicleId or session.vehicleId == vehicleId) then
    return session
  end
  if vehicleId and initializePreviewVehicle(businessId, vehicleId) then
    return currentSession
  end
  return nil
end

local function resetVehicleToOriginal(businessId, vehicleId)
  if not businessId or not vehicleId then
    return false
  end

  local vehObj = getBusinessVehicleObject(businessId, vehicleId)
  if not vehObj then
    return false
  end

  local session = ensureActiveSession(businessId, vehicleId)
  if not session or not session.initial then
    return false
  end

  core_jobsystem.create(function(job)
    job.sleep(0.5)

    local vehicle = career_modules_business_businessInventory.getVehicleById(businessId, vehicleId)
    if not vehicle or not vehicle.vehicleConfig then
      return
    end

    local modelKey = vehicle.vehicleConfig.model_key or vehicle.model_key
    if not modelKey then
      return
    end

    local originalConfig = nil
    local baselineExists = session.initial ~= nil

    if baselineExists then
      originalConfig = deepcopy(session.initial.config)
    else
      return
    end

    local vehId = vehObj:getID()

    replaceVehicleWithFuelHandling(vehObj, modelKey, originalConfig, function()
      local partConditions = baselineExists and session.initial.partConditions or vehicle.partConditions
      if partConditions then
        core_vehicleBridge.executeAction(vehObj, 'initPartConditions', partConditions, nil, nil, nil, nil)
      end
    end, function()
      requestVehiclePowerWeight(vehObj, businessId, vehicleId)
    end)

    session.preview = {
      config = deepcopy(originalConfig),
      partList = flattenPartsTree(originalConfig.partsTree or {}),
      partConditions = deepcopy(baselineExists and session.initial.partConditions or vehicle.partConditions or {}),
      model = modelKey
    }
  end)

  return true
end

local function applyPartsToVehicle(businessId, vehicleId, parts)
  if not businessId or not vehicleId or not parts then
    return false
  end

  local vehObj = getBusinessVehicleObject(businessId, vehicleId)
  if not vehObj then
    return false
  end

  local vehicle = career_modules_business_businessInventory.getVehicleById(businessId, vehicleId)
  if not vehicle or not vehicle.vehicleConfig then
    return false
  end

  local modelKey = vehicle.vehicleConfig.model_key or vehicle.model_key
  if not modelKey then
    return false
  end

  local session = ensureActiveSession(businessId, vehicleId)
  if not session then
    return false
  end

  local initialVehicle = session.initial
  if not initialVehicle or not initialVehicle.config then
    return false
  end

  local completeConfig = deepcopy(initialVehicle.config)

  for _, part in ipairs(parts) do
    if part.partName and part.slotPath then
      createOrUpdatePartsTreeNode(completeConfig.partsTree, part.partName, part.slotPath)
    end
  end

  session.preview = {
    config = completeConfig,
    partList = flattenPartsTree(completeConfig.partsTree or {}),
    partConditions = deepcopy(vehicle.partConditions or {}),
    model = modelKey
  }

  replaceVehicleWithFuelHandling(vehObj, modelKey, completeConfig, function()
    core_vehicleBridge.executeAction(vehObj, 'initPartConditions', session.preview.partConditions or {}, nil, nil, nil,
      nil)
  end, function()
    if career_modules_business_businessComputer then
      career_modules_business_businessComputer.requestVehiclePartsTree(businessId, vehicleId)
    end
    requestVehiclePowerWeight(vehObj, businessId, vehicleId)
  end)

  return true
end

local function buildPartsTreeFromCart(businessId, parts)
  local session = getActiveSession(businessId)
  if not session or not session.initial or not session.initial.config then
    return {}
  end

  local baselineConfig = session.initial.config
  if not baselineConfig or not baselineConfig.partsTree then
    return {}
  end

  local partsTree = deepcopy(baselineConfig.partsTree)

  if parts and #parts > 0 then
    for _, part in ipairs(parts) do
      if part.partName and part.slotPath then
        createOrUpdatePartsTreeNode(partsTree, part.partName, part.slotPath)
      end
    end
  end

  return partsTree
end

local function getRequiredPartsForPart(businessId, vehicleId, partName, slotPath, currentPartsTree)
  if not businessId or not vehicleId or not partName or not slotPath then
    return {}
  end

  local vehObj = getBusinessVehicleObject(businessId, vehicleId)
  if not vehObj then
    return {}
  end

  local vehId = vehObj:getID()
  local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehId)
  if not vehicleData or not vehicleData.ioCtx then
    return {}
  end

  local jbeamData = jbeamIO.getPart(vehicleData.ioCtx, partName)
  if not jbeamData or not jbeamData.slotInfoUi then
    return {}
  end

  local requiredParts = {}
  local availableParts = jbeamIO.getAvailableParts(vehicleData.ioCtx)

  -- Helper to get default part name from jbeam data
  local function getDefaultPartName(jbeamData, slotName)
    if jbeamData.slots2 then
      for _, slot in ipairs(jbeamData.slots2) do
        if slot.name == slotName and slot.default and slot.default ~= "" then
          return slot.default
        end
      end
    end
    return nil
  end

  -- Check each child slot
  for slotName, slotInfo in pairs(jbeamData.slotInfoUi) do
    local childPath = slotPath .. slotName .. "/"

    -- Check if slot is already filled in the current parts tree
    local childNode = getNodeFromSlotPath(currentPartsTree, childPath)
    local hasPart = childNode and childNode.chosenPartName and childNode.chosenPartName ~= ""

    -- Check if the existing part fits the slot
    local partFits = false
    if hasPart then
      local existingPartData = jbeamIO.getPart(vehicleData.ioCtx, childNode.chosenPartName)
      if existingPartData and jbeamSlotSystem.partFitsSlot(existingPartData, slotInfo) then
        partFits = true
      end
    end

    -- If slot is empty or part doesn't fit, we need a default part
    if not hasPart or not partFits then
      local defaultPartName = getDefaultPartName(jbeamData, slotName)
      if defaultPartName then
        -- Generate part info for the required part
        local requiredPart = {
          partName = defaultPartName,
          slotPath = childPath,
          slotName = slotName,
          partNiceName = availableParts[defaultPartName] or defaultPartName,
          value = 0 -- Default parts are usually free
        }
        table.insert(requiredParts, requiredPart)

        -- Recursively get required parts for this required part
        local childTree = childNode or {
          path = childPath,
          children = {}
        }
        local nestedRequired = getRequiredPartsForPart(businessId, vehicleId, defaultPartName, childPath, childTree)
        for _, nestedPart in ipairs(nestedRequired) do
          table.insert(requiredParts, nestedPart)
        end
      end
    end
  end

  return requiredParts
end

local function getNeededAdditionalParts(businessId, vehicleId, parts, baselineTree, currentCart)
  if not businessId or not vehicleId or not parts then
    return parts, false
  end

  local vehObj = getBusinessVehicleObject(businessId, vehicleId)
  if not vehObj then
    return parts, false
  end

  local vehId = vehObj:getID()
  local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehId)
  if not vehicleData or not vehicleData.ioCtx then
    return parts, false
  end

  local availableParts = jbeamIO.getAvailableParts(vehicleData.ioCtx)

  local combinedSlotToPartMap = {}

  local function addBaselineParts(tree, parentPath)
    if not tree then
      return
    end
    if tree.chosenPartName and tree.path then
      combinedSlotToPartMap[tree.path] = {
        name = tree.chosenPartName,
        containingSlot = tree.path,
        slot = tree.path:match("/([^/]+)/$") or ""
      }
    end
    if tree.children then
      for slotName, childNode in pairs(tree.children) do
        addBaselineParts(childNode, childNode.path or (parentPath .. slotName .. "/"))
      end
    end
  end
  addBaselineParts(baselineTree, "/")

  if currentCart then
    for _, item in ipairs(currentCart) do
      if item.type == 'part' and item.partName and item.slotPath then
        combinedSlotToPartMap[item.slotPath] = {
          name = item.partName,
          containingSlot = item.slotPath,
          slot = item.slotPath:match("/([^/]+)/$") or ""
        }
      end
    end
  end

  -- Add new parts (overrides baseline/cart)
  for slotPath, part in pairs(parts) do
    combinedSlotToPartMap[slotPath] = deepcopy(part)
  end

  for path, part in pairs(combinedSlotToPartMap) do
    local jbeamData = jbeamIO.getPart(vehicleData.ioCtx, part.name)
    if jbeamData then
      part.slotType = jbeamData.slotType
    end
  end

  local addedParts = false
  local resultParts = deepcopy(parts)

  local function getDefaultPartName(jbeamData, slotName)
    if jbeamData and jbeamData.slots2 then
      for _, slot in ipairs(jbeamData.slots2) do
        if slot.name == slotName and slot.default and slot.default ~= "" then
          return slot.default
        end
      end
    end
    return nil
  end

  for slotPath, part in pairs(parts) do
    if part.description and part.description.slotInfoUi then
      for slotName, slotInfo in pairs(part.description.slotInfoUi) do
        local childPath = slotPath .. slotName .. "/"

        local existingPart = combinedSlotToPartMap[childPath]
        local partFits = false
        if existingPart then
          partFits = jbeamSlotSystem.partFitsSlot(existingPart, slotInfo)
        end

        if not existingPart or not partFits then
          local jbeamData = jbeamIO.getPart(vehicleData.ioCtx, part.name)

          local fittingPart = nil
          local partNameToGenerate = getDefaultPartName(jbeamData, slotName)
          if partNameToGenerate then
            local defaultJbeamData = jbeamIO.getPart(vehicleData.ioCtx, partNameToGenerate)
            if defaultJbeamData then
              fittingPart = {
                name = partNameToGenerate,
                containingSlot = childPath,
                slot = slotName,
                description = defaultJbeamData,
                vehicleModel = part.vehicleModel
              }
            end
          end

          if fittingPart then
            resultParts[childPath] = fittingPart
            addedParts = true

            combinedSlotToPartMap[childPath] = fittingPart

            if slotInfo and not slotInfo.coreSlot then
              fittingPart.sourcePart = true
            end
          end
        end
      end
    end
  end

  return resultParts, addedParts
end

local function getAllRequiredParts(businessId, vehicleId, parts, cartParts)
  if not businessId or not vehicleId or not parts then
    return {}
  end

  -- Build current parts tree from baseline + cart parts
  local currentPartsTree = buildPartsTreeFromCart(businessId, cartParts)

  local allRequiredParts = {}
  local processedParts = {}

  -- Helper to process a part and its requirements
  local function processPart(partName, slotPath)
    local key = partName .. "_" .. slotPath
    if processedParts[key] then
      return
    end
    processedParts[key] = true

    local required = getRequiredPartsForPart(businessId, vehicleId, partName, slotPath, currentPartsTree)
    for _, reqPart in ipairs(required) do
      local reqKey = reqPart.partName .. "_" .. reqPart.slotPath
      if not processedParts[reqKey] then
        table.insert(allRequiredParts, reqPart)
        createOrUpdatePartsTreeNode(currentPartsTree, reqPart.partName, reqPart.slotPath)
        processPart(reqPart.partName, reqPart.slotPath)
      end
    end
  end

  -- Process all input parts
  for _, part in ipairs(parts) do
    if part.partName and part.slotPath then
      processPart(part.partName, part.slotPath)
    end
  end

  return allRequiredParts
end

local function applyCartPartsToVehicle(businessId, vehicleId, parts)
  if not businessId or not vehicleId then
    return false
  end

  local session = ensureActiveSession(businessId, vehicleId)
  if not session then
    return false
  end
  if session.operationInProgress then
    return false
  end

  session.operationInProgress = true

  local vehObj = getBusinessVehicleObject(businessId, vehicleId)
  if not vehObj then
    session.operationInProgress = false
    return false
  end

  local initialVehicle = session.initial
  if not initialVehicle or not initialVehicle.config then
    session.operationInProgress = false
    return false
  end

  -- Build complete config: baseline + all cart parts
  local completeConfig = deepcopy(initialVehicle.config)

  -- Helper function to recursively clear child parts
  local function clearChildParts(node, path)
    if not node or not node.children then
      return
    end
    for slotName, childNode in pairs(node.children) do
      local childPath = path .. slotName .. "/"
      childNode.chosenPartName = ""
      if childNode.children then
        clearChildParts(childNode, childPath)
      end
    end
  end

  -- Apply all parts from cart to the config, and find all required parts (like vanilla updateInstalledParts)
  if parts and #parts > 0 then
    -- First, handle removal markers (emptyPlaceholder)
    local removalMarkers = {}
    local partsToApply = {}

    for _, part in ipairs(parts) do
      if part.emptyPlaceholder or (part.partName == "" or not part.partName) then
        removalMarkers[part.slotPath] = part
      elseif part.partName and part.slotPath then
        table.insert(partsToApply, {
          partName = part.partName,
          slotPath = part.slotPath
        })
      end
    end

    -- Apply removal markers first (clear parts from config)
    for slotPath, removalMarker in pairs(removalMarkers) do
      local node = getNodeFromSlotPath(completeConfig.partsTree, slotPath)
      if node then
        node.chosenPartName = ""
        node.emptyPlaceholder = true
        clearChildParts(node, slotPath)
      end
    end

    -- Use the same system as vanilla: find all required parts recursively
    local requiredParts = getAllRequiredParts(businessId, vehicleId, partsToApply, parts)

    local allParts = {}
    for _, part in ipairs(parts) do
      if part.partName and part.slotPath and part.partName ~= "" then
        allParts[part.slotPath] = part
      end
    end

    local discountMultiplier = getPartSupplierDiscountMultiplier(businessId)
    local vehicleModel = nil
    if vehObj then
      vehicleModel = vehObj:getJBeamFilename()
    end

    for _, reqPart in ipairs(requiredParts) do
      if not allParts[reqPart.slotPath] then
        local reqPartPrice = reqPart.value or 0

        if reqPartPrice > 0 and vehObj then
          local vehId = vehObj:getID()
          local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehId)
          if vehicleData and vehicleData.ioCtx then
            local jbeamData = jbeamIO.getPart(vehicleData.ioCtx, reqPart.partName)
            if jbeamData then
              local baseValue = jbeamData.information and jbeamData.information.value or 100

              if career_modules_valueCalculator then
                local partForValueCalc = {
                  name = reqPart.partName,
                  value = baseValue,
                  partCondition = {
                    integrityValue = 1,
                    odometer = 0,
                    visualValue = 1
                  },
                  vehicleModel = vehicleModel
                }
                reqPartPrice = math.max(roundNear(career_modules_valueCalculator.getPartValue(partForValueCalc), 5) -
                                          0.01, 0)
              else
                reqPartPrice = baseValue
              end

              reqPartPrice = reqPartPrice * discountMultiplier
            end
          end
        end

        allParts[reqPart.slotPath] = {
          partName = reqPart.partName,
          slotPath = reqPart.slotPath,
          partNiceName = reqPart.partNiceName or reqPart.partName,
          slotNiceName = reqPart.slotName or '',
          price = reqPartPrice
        }
      end
    end

    for slotPath, part in pairs(allParts) do
      if part.partName and part.slotPath and part.partName ~= "" then
        createOrUpdatePartsTreeNode(completeConfig.partsTree, part.partName, part.slotPath)
      end
    end
  end

  local modelKey = initialVehicle.model
  session.preview = {
    config = completeConfig,
    partList = flattenPartsTree(completeConfig.partsTree or {}),
    partConditions = deepcopy(initialVehicle.partConditions or {}),
    model = modelKey
  }

  replaceVehicleWithFuelHandling(vehObj, modelKey, completeConfig, function()
    core_vehicleBridge.executeAction(vehObj, 'initPartConditions', session.preview.partConditions or {}, nil, nil, nil,
      nil)
  end, function()
    session.operationInProgress = false
    if career_modules_business_businessComputer then
      career_modules_business_businessComputer.requestVehiclePartsTree(businessId, vehicleId)
    end
    if career_modules_business_businessVehicleTuning then
      career_modules_business_businessVehicleTuning.clearTuningDataCache()
    end
    requestVehiclePowerWeight(vehObj, businessId, vehicleId)
  end)

  return true
end

local function installPartOnVehicle(businessId, vehicleId, partName, slotPath)
  return true
end

local function onPowerWeightReceived(requestId, power, weight, torqueData)
  local businessId, vehicleId = requestId:match("^(.+)_(.+)_")
  if businessId and vehicleId and power and weight and weight > 0 then
    local numericVehicleId = tonumber(vehicleId)
    local result = {
      power = power,
      weight = weight,
      powerToWeight = power / weight,
      torque = torqueData
    }
    if sessionMatches(businessId, numericVehicleId) then
      currentSession.powerWeight = result
    end

    -- Notify Vue via hook when data arrives
    guihooks.trigger('businessComputer:onVehiclePowerWeight', {
      success = true,
      businessId = businessId,
      vehicleId = numericVehicleId or vehicleId,
      power = power,
      weight = weight,
      powerToWeight = result.powerToWeight,
      torque = torqueData
    })
  end
end

local function getVehiclePowerWeight(businessId, vehicleId)
  if not businessId or not vehicleId then
    return nil
  end

  if career_modules_business_businessSkillTree then
    local dynoLevel = career_modules_business_businessSkillTree.getNodeProgress(businessId, "shop-upgrades", "dyno") or
                        0
    if dynoLevel == 0 then
      return nil
    end
  end

  local vehObj = getBusinessVehicleObject(businessId, vehicleId)
  if not vehObj then
    return nil
  end

  local session = getActiveSession(businessId)
  if session and session.vehicleId == vehicleId and session.powerWeight then
    return session.powerWeight
  end

  requestVehiclePowerWeight(vehObj, businessId, vehicleId)

  return nil
end

local function getPreviewVehicleConfig(businessId)
  local session = getActiveSession(businessId)
  if session and session.preview then
    return session.preview.config
  end
  return nil
end

local function getInitialVehicleState(businessId)
  local session = getActiveSession(businessId)
  if session and session.initial then
    return deepcopy(session.initial)
  end
  return nil
end

local function findChangedParts(baselineTree, newTree, changedParts, path)
  changedParts = changedParts or {}
  path = path or (baselineTree and baselineTree.path) or (newTree and newTree.path) or "/"

  local baselinePart = baselineTree and baselineTree.chosenPartName or ""
  local newPart = newTree and newTree.chosenPartName or ""

  if baselinePart ~= newPart then
    if newPart and newPart ~= "" then
      changedParts[path] = {
        partName = newPart,
        slotPath = path
      }
    end
  end

  local baselineChildren = baselineTree and baselineTree.children or {}
  local newChildren = newTree and newTree.children or {}

  for slotName, newChild in pairs(newChildren) do
    local childPath = newChild.path or (path .. slotName .. "/")
    local baselineChild = baselineChildren[slotName]
    findChangedParts(baselineChild, newChild, changedParts, childPath)
  end

  for slotName, baselineChild in pairs(baselineChildren) do
    if not newChildren[slotName] then
    end
  end

  return changedParts
end

local function addPartToCart(businessId, vehicleId, currentCart, partToAdd)
  if not businessId or not vehicleId or not partToAdd or not partToAdd.partName or not partToAdd.slotPath then
    return currentCart or {}
  end

  local session = ensureActiveSession(businessId, vehicleId)
  if not session or not session.initial or not session.initial.config then
    return currentCart or {}
  end

  local baselineTree = session.initial.config.partsTree
  if not baselineTree then
    return currentCart or {}
  end

  local cart = deepcopy(currentCart or {})
  local slotData = session.slotData or {}

  for i = #cart, 1, -1 do
    local item = cart[i]
    if item.type == 'part' then
      if item.slotPath == partToAdd.slotPath or
        item.slotPath:match("^" .. partToAdd.slotPath:gsub("%-", "%%-") .. "[^/]+") then
        table.remove(cart, i)
      end
    end
  end

  -- Get vehicle object
  local vehObj = getBusinessVehicleObject(businessId, vehicleId)
  if not vehObj then
    return currentCart or {}
  end

  local vehId = vehObj:getID()
  local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehId)
  if not vehicleData or not vehicleData.ioCtx then
    return currentCart or {}
  end

  local availableParts = jbeamIO.getAvailableParts(vehicleData.ioCtx)
  local vehicleModel = vehObj:getJBeamFilename()

  -- Build temp cart with baseline + cart + new part
  local tempCart = deepcopy(cart)
  local newPartItem = {
    type = 'part',
    partName = partToAdd.partName,
    partNiceName = partToAdd.partNiceName or partToAdd.partName,
    slotPath = partToAdd.slotPath,
    slotNiceName = partToAdd.slotNiceName or "",
    price = partToAdd.price or 0
  }

  -- If part is from inventory, mark it and set price to 0
  if partToAdd.fromInventory then
    newPartItem.fromInventory = true
    newPartItem.partId = partToAdd.partId
    newPartItem.price = 0
  end

  table.insert(tempCart, newPartItem)

  -- Use applyCartPartsToVehicle pattern to spawn vehicle with tempCart
  -- This will automatically add default parts for empty slots
  local initialConfig = deepcopy(session.initial.config)

  -- Build complete config from baseline + tempCart (same as applyCartPartsToVehicle does)
  local completeConfig = deepcopy(session.initial.config)

  -- Apply all parts from tempCart to the config
  for _, part in ipairs(tempCart) do
    if part.type == 'part' and part.partName and part.slotPath then
      createOrUpdatePartsTreeNode(completeConfig.partsTree, part.partName, part.slotPath)
    end
  end

  -- Store fuel levels before replacing vehicle
  storeFuelLevels(vehObj, function(storedFuelLevels)
    local additionalVehicleData = {
      spawnWithEngineRunning = false
    }
    core_vehicle_manager.queueAdditionalVehicleData(additionalVehicleData, vehId)

    local spawnOptions = {}
    spawnOptions.config = completeConfig
    spawnOptions.keepOtherVehRotation = true

    -- Replace vehicle with complete config (game will auto-add default parts)
    core_vehicles.replaceVehicle(vehicleModel, spawnOptions, vehObj)

    -- Wait for vehicle to spawn and get actual config
    core_vehicleBridge.requestValue(vehObj, function()
      -- Get actual config from spawned vehicle (includes auto-added default parts)
      local actualVehicleData = extensions.core_vehicle_manager.getVehicleData(vehId)
      if not actualVehicleData or not actualVehicleData.config or not actualVehicleData.config.partsTree then
        -- Restore original config
        core_vehicles.replaceVehicle(vehicleModel, {
          config = initialConfig,
          keepOtherVehRotation = true
        }, vehObj)
        restoreFuelLevels(vehObj, storedFuelLevels)
        return
      end

      local actualTree = actualVehicleData.config.partsTree

      -- Compare baseline vs actual config to find ALL changed parts (including auto-added defaults)
      local changedPartsMap = findChangedParts(baselineTree, actualTree, {})

      -- Build final cart: keep unchanged items + add all changed parts
      local finalCart = {}

      -- First, add all items from current cart that aren't being changed
      for _, item in ipairs(cart) do
        if item.type == 'part' then
          local isBeingChanged = false
          for slotPath, _ in pairs(changedPartsMap) do
            if item.slotPath == slotPath then
              isBeingChanged = true
              break
            end
          end
          if not isBeingChanged then
            table.insert(finalCart, item)
          end
        else
          -- Keep non-part items (tuning, etc.)
          table.insert(finalCart, item)
        end
      end

      for slotPath, partInfo in pairs(changedPartsMap) do
        local jbeamData = jbeamIO.getPart(vehicleData.ioCtx, partInfo.partName)

        local partNiceName = partInfo.partName
        if jbeamData and jbeamData.information and jbeamData.information.description then
          local desc = jbeamData.information.description
          partNiceName = type(desc) == "table" and desc.description or desc or partInfo.partName
        else
          local partDescription = availableParts[partInfo.partName]
          if partDescription then
            if type(partDescription) == "string" then
              partNiceName = partDescription
            elseif partDescription.description then
              local desc = partDescription.description
              partNiceName = type(desc) == "table" and desc.description or desc or partInfo.partName
            end
          end
        end

        local partValue = 0
        if jbeamData then
          local baseValue = jbeamData.information and jbeamData.information.value or 100

          if career_modules_valueCalculator then
            local partForValueCalc = {
              name = partInfo.partName,
              value = baseValue,
              partCondition = {
                integrityValue = 1,
                odometer = 0,
                visualValue = 1
              },
              vehicleModel = vehicleModel
            }
            partValue = math.max(roundNear(career_modules_valueCalculator.getPartValue(partForValueCalc), 5) - 0.01, 0)
          else
            partValue = baseValue
          end

          local discountMultiplier = getPartSupplierDiscountMultiplier(businessId)
          partValue = partValue * discountMultiplier
        end

        local slotNiceName = ""
        local slotInfo = nil
        local slotName = slotPath:match("/([^/]+)/$") or ""

        local parentPath = slotPath:match("(.+)/[^/]+/$") or "/"
        local actualParentNode = getNodeFromSlotPath(actualTree, parentPath)
        if actualParentNode and actualParentNode.chosenPartName then
          local parentJbeamData = jbeamIO.getPart(vehicleData.ioCtx, actualParentNode.chosenPartName)
          if parentJbeamData and parentJbeamData.slotInfoUi and parentJbeamData.slotInfoUi[slotName] then
            slotInfo = parentJbeamData.slotInfoUi[slotName]
            local desc = slotInfo.description
            slotNiceName = type(desc) == "table" and desc.description or desc or slotName
          end
        end

        if slotNiceName == "" and slotData then
          if slotData[slotPath] then
            slotInfo = slotData[slotPath]
            if slotInfo.description then
              local desc = slotInfo.description
              slotNiceName = type(desc) == "table" and desc.description or desc or slotName
            end
          end

          if slotNiceName == "" then
            for path, info in pairs(slotData) do
              local pathSlotName = path:match("/([^/]+)/$") or ""
              if pathSlotName == slotName then
                slotInfo = info
                if info.description then
                  local desc = info.description
                  slotNiceName = type(desc) == "table" and desc.description or desc or slotName
                  break
                end
              end
            end
          end
        end

        if slotNiceName == "" then
          slotNiceName = slotName
        end

        local canRemove = false
        local baselinePartName = session.initial.partList[slotPath]
        if slotInfo then
          if not slotInfo.coreSlot then
            canRemove = true
          elseif baselinePartName and baselinePartName ~= "" then
            canRemove = true
          end
        else
          if baselinePartName and baselinePartName ~= "" then
            canRemove = true
          end
        end

        local partData = {
          type = 'part',
          partName = partInfo.partName,
          partNiceName = partNiceName,
          slotPath = slotPath,
          slotNiceName = slotNiceName,
          price = partValue,
          canRemove = canRemove
        }

        if slotPath == partToAdd.slotPath then
          partData.partNiceName = partToAdd.partNiceName or partData.partNiceName
          partData.slotNiceName = partToAdd.slotNiceName or partData.slotNiceName
          partData.canRemove = true

          if partToAdd.fromInventory then
            partData.fromInventory = true
            partData.partId = partToAdd.partId
            partData.price = 0
          else
            partData.price = partValue
          end
        end

        table.insert(finalCart, partData)
      end

      session.preview = {
        config = deepcopy(actualVehicleData.config),
        partList = flattenPartsTree(actualVehicleData.config.partsTree or {}),
        partConditions = deepcopy(session.initial.partConditions or {}),
        model = vehicleModel
      }

      restoreFuelLevels(vehObj, storedFuelLevels)

      guihooks.trigger('businessComputer:onPartCartUpdated', {
        businessId = businessId,
        vehicleId = vehicleId,
        cart = finalCart
      })

      if career_modules_business_businessComputer then
        career_modules_business_businessComputer.requestVehiclePartsTree(businessId, vehicleId)
      end

      if career_modules_business_businessVehicleTuning then
        career_modules_business_businessVehicleTuning.clearTuningDataCache()
      end

      requestVehiclePowerWeight(vehObj, businessId, vehicleId)
    end, 'ping')
  end)

  return cart
end

local function findRemovedParts(businessId, vehicleId)
  if not businessId or not vehicleId then
    return {}
  end

  local session = getActiveSession(businessId)
  if not session or not session.initial or not session.preview then
    return {}
  end

  local initialVehicle = session.initial
  local previewVehicle = session.preview

  if not initialVehicle or not previewVehicle then
    return {}
  end

  local baselinePartList = initialVehicle.partList or {}
  local finalPartList = previewVehicle.partList or {}

  local removedParts = {}

  -- Get vehicle data for jbeam access and part value calculation
  local vehObj = getBusinessVehicleObject(businessId, vehicleId)
  if not vehObj then
    return {}
  end

  local vehId = vehObj:getID()
  local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehId)
  if not vehicleData then
    return {}
  end

  local vehicle = career_modules_business_businessInventory.getVehicleById(businessId, vehicleId)
  if not vehicle or not vehicle.vehicleConfig then
    return {}
  end
  local vehicleModel = vehicle.vehicleConfig.model_key or vehicle.model_key

  for slotPath, partName in pairs(baselinePartList) do
    if partName and partName ~= "" then
      local finalPartName = finalPartList[slotPath]
      if not finalPartName or finalPartName == "" or finalPartName ~= partName then
        local partCondition = initialVehicle.partConditions and initialVehicle.partConditions[slotPath .. partName]
        if not partCondition then
          partCondition = {
            integrityValue = 1,
            visualValue = 1,
            odometer = 0
          }
        end

        local partData = {
          name = partName,
          containingSlot = slotPath,
          slot = slotPath:match("/([^/]+)/$") or slotPath:match("/([^/]+)$") or "",
          vehicleModel = vehicleModel,
          partCondition = partCondition
        }

        if career_modules_valueCalculator then
          partData.value = career_modules_valueCalculator.getPartValue(partData) or 0
        else
          local jbeamData = jbeamIO.getPart(vehicleData.ioCtx, partName)
          partData.value = (jbeamData and jbeamData.information and jbeamData.information.value) or 100
        end

        table.insert(removedParts, partData)
      end
    end
  end

  return removedParts
end

local function clearPreviewVehicle(businessId)
  if businessId and sessionMatches(businessId) then
    resetCurrentSession()
  end
end

M.onPowerWeightReceived = onPowerWeightReceived
M.initializePreviewVehicle = initializePreviewVehicle
M.resetVehicleToOriginal = resetVehicleToOriginal
M.applyPartsToVehicle = applyPartsToVehicle
M.applyCartPartsToVehicle = applyCartPartsToVehicle
M.installPartOnVehicle = installPartOnVehicle
M.getVehiclePowerWeight = getVehiclePowerWeight
M.getPreviewVehicleConfig = getPreviewVehicleConfig
M.getInitialVehicleState = getInitialVehicleState
M.clearPreviewVehicle = clearPreviewVehicle
M.getAllRequiredParts = getAllRequiredParts
M.addPartToCart = addPartToCart
M.findRemovedParts = findRemovedParts

return M

