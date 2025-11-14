local M = {}

M.dependencies = {'career_career', 'core_vehicles', 'core_jobsystem'}

local jbeamIO = require('jbeam/io')
local jbeamSlotSystem = require('jbeam/slotSystem')

-- Preview vehicle management per business (keyed by businessId)
local previewVehicles = {}
local initialVehicles = {}
local previewVehicleSlotData = {}

-- Cache for power/weight values (keyed by businessId_vehicleId)
local powerWeightCache = {}

-- Callback storage for power/weight requests
local powerWeightCallbacks = {}

-- Helper function to get vehicle object from business
local function getBusinessVehicleObject(businessId, vehicleId)
  if not businessId or not vehicleId then return nil end
  
  -- Get spawned vehicle ID from businessInventory
  if career_modules_business_businessInventory then
    local vehId = career_modules_business_businessInventory.getSpawnedVehicleId(businessId, vehicleId)
    if vehId then
      return getObjectByID(vehId)
    end
  end
  
  return nil
end

-- Helper function to flatten parts tree (from partShopping.lua)
local function flattenPartsTree(tree)
  local result = {}
  if not tree then return result end
  
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

-- Helper function to get node from slot path (from partShopping.lua)
local function getNodeFromSlotPath(tree, path)
  if not tree or not path then return nil end
  
  if path == "/" then return tree end
  
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

-- Helper function to store fuel levels (from partShopping.lua)
local function storeFuelLevels(vehObj, callback)
  if not vehObj then 
    if callback then callback() end
    return 
  end
  
  core_vehicleBridge.requestValue(vehObj, function(data)
    local storedFuelLevels = {}
    if data and data[1] then
      for _, tank in ipairs(data[1]) do
        -- Only store fuel levels for actual fuel tanks, not nitrous bottles
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
    if callback then callback(storedFuelLevels) end
  end, 'energyStorage')
end

-- Helper function to restore fuel levels (from partShopping.lua)
local function restoreFuelLevels(vehObj, storedFuelLevels)
  if not vehObj or not storedFuelLevels or not next(storedFuelLevels) then return end
  
  core_vehicleBridge.requestValue(vehObj, function(data)
    if not data or not data[1] then return end
    
    for _, tank in ipairs(data[1]) do
      local stored = storedFuelLevels[tank.name]
      if stored and stored.energyType == tank.energyType then
        local newFuelAmount = math.min(stored.currentEnergy, tank.maxEnergy)
        if tank.maxEnergy > stored.maxEnergy then
          newFuelAmount = tank.maxEnergy * stored.relativeFuel
        end
        
        -- Ensure minimum fuel level (5% of tank capacity)
        local minFuel = tank.maxEnergy * 0.05
        newFuelAmount = math.max(newFuelAmount, minFuel)
        
        core_vehicleBridge.executeAction(vehObj, 'setEnergyStorageEnergy', tank.name, newFuelAmount)
      end
    end
  end, 'energyStorage')
end

-- Helper function to request vehicle power/weight calculation
local function requestVehiclePowerWeight(vehObj, businessId, vehicleId)
  if not vehObj or not businessId or not vehicleId then return end
  
  local cacheKey = businessId .. "_" .. tostring(vehicleId)
  local requestId = cacheKey .. "_" .. tostring(os.clock())
  
  vehObj:queueLuaCommand([[
    local engine = powertrain.getDevicesByCategory("engine")[1]
    local stats = obj:calcBeamStats()
    if engine and stats then
      local power = engine.maxPower
      local weight = stats.total_weight
      if power and weight and weight > 0 then
        obj:queueGameEngineLua("career_modules_business_businessPartCustomization.onPowerWeightReceived(']] .. requestId .. [[', " .. power .. ", " .. weight .. ")")
      end
    end
  ]])
end

-- Helper function to create or update a parts tree node
local function createOrUpdatePartsTreeNode(partsTree, partName, slotPath)
  if not partsTree or not partName or not slotPath then return false end
  
  local node = getNodeFromSlotPath(partsTree, slotPath)
  if node then
    node.chosenPartName = partName
    return true
  end
  
  local parentPath = slotPath:match("(.+)/[^/]+/$") or "/"
  local parentNode = getNodeFromSlotPath(partsTree, parentPath)
  if parentNode then
    if not parentNode.children then parentNode.children = {} end
    local slotName = slotPath:match("/([^/]+)/$") or slotPath:match("/([^/]+)$") or ""
    if slotName and slotName ~= "" then
      parentNode.children[slotName] = {
        chosenPartName = partName,
        path = slotPath,
        children = {},
        suitablePartNames = {partName},
        unsuitablePartNames = {},
        decisionMethod = "user"
      }
      return true
    end
  end
  
  return false
end

-- Helper function to replace vehicle with fuel handling and optional callbacks
local function replaceVehicleWithFuelHandling(vehObj, modelKey, config, beforeRestoreCallback, afterRestoreCallback)
  if not vehObj or not modelKey or not config then
    if afterRestoreCallback then afterRestoreCallback() end
    return
  end
  
  local vehId = vehObj:getID()
  storeFuelLevels(vehObj, function(storedFuelLevels)
    local additionalVehicleData = {spawnWithEngineRunning = false}
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
      if afterRestoreCallback then afterRestoreCallback() end
    end, 'ping')
  end)
end

-- Initialize preview vehicle for a business (called when vehicle is pulled out)
local function initializePreviewVehicle(businessId, vehicleId)
  if not businessId or not vehicleId then return false end
  
  local vehicle = career_modules_business_businessInventory.getVehicleById(businessId, vehicleId)
  if not vehicle or not vehicle.vehicleConfig then return false end
  
  local vehObj = getBusinessVehicleObject(businessId, vehicleId)
  if not vehObj then return false end
  
  local vehId = vehObj:getID()
  local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehId)
  if not vehicleData or not vehicleData.config or not vehicleData.config.partsTree then
    return false
  end
  
  -- Store initial vehicle state from the stored vehicle config (baseline from inventory)
  -- Use vehicle.config if it exists (has custom parts), otherwise use vehicleData.config (base config)
  local originalConfig = vehicle.config or vehicleData.config
  local modelKey = vehicle.vehicleConfig.model_key or vehicle.model_key
  
  initialVehicles[businessId] = {
    config = deepcopy(originalConfig),
    partList = flattenPartsTree(originalConfig.partsTree or {}),
    partConditions = deepcopy(vehicle.partConditions or {}),
    vars = deepcopy(vehicle.vars or {}),
    model = modelKey
  }
  
  -- Initialize preview vehicle with the same original state
  previewVehicles[businessId] = {
    config = deepcopy(originalConfig),
    partList = flattenPartsTree(originalConfig.partsTree or {}),
    partConditions = deepcopy(vehicle.partConditions or {}),
    model = modelKey
  }
  
  -- Initialize slot data
  previewVehicleSlotData[businessId] = {}
  local availableParts = jbeamIO.getAvailableParts(vehicleData.ioCtx)
  for partName, partInfo in pairs(availableParts) do
    if partInfo.slotInfoUi then
      for slotName, slotInfo in pairs(partInfo.slotInfoUi) do
        local path = "/" .. slotName .. "/"
        previewVehicleSlotData[businessId][path] = slotInfo
      end
    end
  end
  
  return true
end

-- Reset vehicle to original state (baseline from inventory, before any modifications)
local function resetVehicleToOriginal(businessId, vehicleId)
  if not businessId or not vehicleId then return false end
  
  local vehObj = getBusinessVehicleObject(businessId, vehicleId)
  if not vehObj then return false end
  
  -- Use job system with delay to ensure inventory has been fully updated (prevents race conditions)
  core_jobsystem.create(function(job)
    job.sleep(0.5)
    
    -- Get current vehicle state from inventory (always use current state, not cached)
    local vehicle = career_modules_business_businessInventory.getVehicleById(businessId, vehicleId)
    if not vehicle or not vehicle.vehicleConfig then return end
    
    local modelKey = vehicle.vehicleConfig.model_key or vehicle.model_key
    if not modelKey then return end
    
    -- Always reload config from current inventory state (includes any purchased parts)
    -- Use vehicle.config if it exists (has custom parts), otherwise get from spawned vehicle
    local originalConfig = nil
    if vehicle.config then
      originalConfig = deepcopy(vehicle.config)
    else
      local vehId = vehObj:getID()
      local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehId)
      if vehicleData and vehicleData.config then
        originalConfig = deepcopy(vehicleData.config)
      else
        return
      end
    end
    
    -- Include variables in config (they should be part of config, not set separately)
    if vehicle.vars then
      originalConfig.vars = deepcopy(vehicle.vars)
    end
    
    -- Update initialVehicles cache with current inventory state
    initialVehicles[businessId] = {
      config = deepcopy(originalConfig),
      partList = flattenPartsTree(originalConfig.partsTree or {}),
      partConditions = deepcopy(vehicle.partConditions or {}),
      vars = deepcopy(vehicle.vars or {}),
      model = modelKey
    }
    
    local vehId = vehObj:getID()
    
    replaceVehicleWithFuelHandling(vehObj, modelKey, originalConfig, 
      function()
        if vehicle.partConditions then
          core_vehicleBridge.executeAction(vehObj, 'initPartConditions', vehicle.partConditions, nil, nil, nil, nil)
        end
      end,
      function()
        requestVehiclePowerWeight(vehObj, businessId, vehicleId)
      end
    )
    
    -- Reset preview vehicle to match current inventory state
    previewVehicles[businessId] = {
      config = deepcopy(originalConfig),
      partList = flattenPartsTree(originalConfig.partsTree or {}),
      partConditions = deepcopy(vehicle.partConditions or {}),
      model = modelKey
    }
  end)
  
  return true
end

-- Apply all parts from a list to vehicle - build complete config and replace vehicle
local function applyPartsToVehicle(businessId, vehicleId, parts)
  if not businessId or not vehicleId or not parts then return false end
  
  local vehObj = getBusinessVehicleObject(businessId, vehicleId)
  if not vehObj then return false end
  
  -- Get original vehicle state
  local vehicle = career_modules_business_businessInventory.getVehicleById(businessId, vehicleId)
  if not vehicle or not vehicle.vehicleConfig then return false end
  
  local modelKey = vehicle.vehicleConfig.model_key or vehicle.model_key
  if not modelKey then return false end
  
  -- Ensure initial vehicle state is stored
  if not initialVehicles[businessId] then
    if not initializePreviewVehicle(businessId, vehicleId) then
      return false
    end
  end
  
  -- Use the stored initial vehicle config (baseline from inventory)
  local initialVehicle = initialVehicles[businessId]
  if not initialVehicle or not initialVehicle.config then
    return false
  end
  
  -- Build complete config with all parts applied (start from baseline, not modified state)
  local completeConfig = deepcopy(initialVehicle.config)
  
  -- Update all parts in the parts tree
  for _, part in ipairs(parts) do
    if part.partName and part.slotPath then
      createOrUpdatePartsTreeNode(completeConfig.partsTree, part.partName, part.slotPath)
    end
  end
  
  -- Update preview vehicle with complete config
  previewVehicles[businessId] = {
    config = completeConfig,
    partList = flattenPartsTree(completeConfig.partsTree or {}),
    partConditions = deepcopy(vehicle.partConditions or {}),
    model = modelKey
  }
  
  replaceVehicleWithFuelHandling(vehObj, modelKey, completeConfig,
    function()
      core_vehicleBridge.executeAction(vehObj, 'initPartConditions', previewVehicles[businessId].partConditions or {}, nil, nil, nil, nil)
    end,
    function()
      if career_modules_business_businessComputer then
        career_modules_business_businessComputer.requestVehiclePartsTree(businessId, vehicleId)
      end
      requestVehiclePowerWeight(vehObj, businessId, vehicleId)
    end
  )
  
  return true
end

-- Build parts tree from baseline + cart parts (for required parts detection)
local function buildPartsTreeFromCart(businessId, parts)
    if not businessId or not initialVehicles[businessId] then
      return {}
    end
    
    local baselineConfig = initialVehicles[businessId].config
    if not baselineConfig or not baselineConfig.partsTree then
      return {}
    end
    
    -- Start with baseline parts tree
    local partsTree = deepcopy(baselineConfig.partsTree)
    
    -- Apply all parts from cart
    if parts and #parts > 0 then
      for _, part in ipairs(parts) do
        if part.partName and part.slotPath then
          createOrUpdatePartsTreeNode(partsTree, part.partName, part.slotPath)
        end
      end
    end
    
    return partsTree
  end
  
  -- Get required additional parts for a given part (similar to partShopping.lua)
  local function getRequiredPartsForPart(businessId, vehicleId, partName, slotPath, currentPartsTree)
    if not businessId or not vehicleId or not partName or not slotPath then
      return {}
    end
    
    local vehObj = getBusinessVehicleObject(businessId, vehicleId)
    if not vehObj then return {} end
    
    local vehId = vehObj:getID()
    local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehId)
    if not vehicleData or not vehicleData.ioCtx then return {} end
    
    local jbeamData = jbeamIO.getPart(vehicleData.ioCtx, partName)
    if not jbeamData or not jbeamData.slotInfoUi then return {} end
    
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
          local childTree = childNode or {path = childPath, children = {}}
          local nestedRequired = getRequiredPartsForPart(businessId, vehicleId, defaultPartName, childPath, childTree)
          for _, nestedPart in ipairs(nestedRequired) do
            table.insert(requiredParts, nestedPart)
          end
        end
      end
    end
    
    return requiredParts
  end

-- Get fitting part from business inventory (similar to vanilla getFittingPartFromInventory)
local function getFittingPartFromInventory(businessId, parentPart, slotName, currentVehicleData, currentCart)
  if not businessId or not parentPart or not slotName or not currentVehicleData then
    return nil
  end
  
  if not career_modules_business_businessPartInventory then
    return nil
  end
  
  local businessParts = career_modules_business_businessPartInventory.getBusinessParts(businessId)
  if not businessParts then return nil end
  
  -- Build set of slot paths already in cart to avoid duplicates
  local cartSlotPaths = {}
  if currentCart then
    for _, item in ipairs(currentCart) do
      if item.type == 'part' and item.slotPath then
        cartSlotPaths[item.slotPath] = true
      end
    end
  end
  
  local slotInfo = parentPart.description and parentPart.description.slotInfoUi and parentPart.description.slotInfoUi[slotName]
  if not slotInfo then return nil end
  
  -- Calculate target slot path
  local targetSlotPath = parentPart.containingSlot .. slotName .. "/"
  
  -- Skip if target slot is already in cart
  if cartSlotPaths[targetSlotPath] then
    return nil
  end
  
  -- Check each part in business inventory
  for _, inventoryPart in ipairs(businessParts) do
    -- Get jbeam data for the inventory part
    local partDescription = jbeamIO.getPart(currentVehicleData.ioCtx, inventoryPart.name)
    if partDescription and jbeamSlotSystem.partFitsSlot(partDescription, slotInfo) then
      -- Found a fitting part - create shop part object
      local shopPart = deepcopy(inventoryPart)
      shopPart.containingSlot = targetSlotPath
      shopPart.slot = slotName
      shopPart.vehicleModel = parentPart.vehicleModel
      shopPart.description = partDescription
      shopPart.finalValue = 0 -- Parts from inventory are free
      shopPart.fromInventory = true -- Mark as from inventory
      return shopPart
    end
  end
  
  return nil
end

-- Get needed additional parts (following vanilla pattern exactly)
-- Takes parts map (keyed by slotPath), returns updated parts map and boolean indicating if parts were added
local function getNeededAdditionalParts(businessId, vehicleId, parts, baselineTree, currentCart)
  if not businessId or not vehicleId or not parts then
    return parts, false
  end
  
  local vehObj = getBusinessVehicleObject(businessId, vehicleId)
  if not vehObj then return parts, false end
  
  local vehId = vehObj:getID()
  local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehId)
  if not vehicleData or not vehicleData.ioCtx then return parts, false end
  
  local availableParts = jbeamIO.getAvailableParts(vehicleData.ioCtx)
  
  -- Build combined slot map: baseline parts + current cart parts + new parts
  local combinedSlotToPartMap = {}
  
  -- Add baseline parts
  local function addBaselineParts(tree, parentPath)
    if not tree then return end
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
  
  -- Add current cart parts
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
  
  -- Get slotType for all parts (matching vanilla pattern)
  for path, part in pairs(combinedSlotToPartMap) do
    local jbeamData = jbeamIO.getPart(vehicleData.ioCtx, part.name)
    if jbeamData then
      part.slotType = jbeamData.slotType
    end
  end
  
  -- Check each part's child slots and add default parts if needed (matching vanilla pattern exactly)
  local addedParts = false
  local resultParts = deepcopy(parts)
  
  -- Helper to get default part name from jbeam data
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
        
        -- Check if slot is empty or part doesn't fit (matching vanilla pattern exactly - line 462)
        -- Vanilla passes the part object directly to partFitsSlot, which internally loads jbeam data
        local existingPart = combinedSlotToPartMap[childPath]
        local partFits = false
        if existingPart then
          partFits = jbeamSlotSystem.partFitsSlot(existingPart, slotInfo)
        end
        
        if not existingPart or not partFits then
          local jbeamData = jbeamIO.getPart(vehicleData.ioCtx, part.name)
          
          -- Look for a fitting part from business inventory first (matching vanilla pattern)
          local fittingPart = getFittingPartFromInventory(businessId, part, slotName, vehicleData, currentCart)
          
          -- If no fitting part from inventory, try default part
          if not fittingPart then
            local partNameToGenerate = getDefaultPartName(jbeamData, slotName)
            if partNameToGenerate then
              -- Generate default part (matching vanilla generatePart pattern)
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
          end
          
          if fittingPart then
            resultParts[childPath] = fittingPart
            addedParts = true
            
            -- Update combined map for next iteration (so nested children can be detected)
            combinedSlotToPartMap[childPath] = fittingPart
            
            -- Mark as sourcePart if not a core slot (matching vanilla pattern)
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

-- Get all required parts for a list of parts (recursively)
local function getAllRequiredParts(businessId, vehicleId, parts, cartParts)
    if not businessId or not vehicleId or not parts then return {} end
    
    -- Build current parts tree from baseline + cart parts
    local currentPartsTree = buildPartsTreeFromCart(businessId, cartParts)
    
    local allRequiredParts = {}
    local processedParts = {}
    
    -- Helper to process a part and its requirements
    local function processPart(partName, slotPath)
      local key = partName .. "_" .. slotPath
      if processedParts[key] then return end
      processedParts[key] = true
      
      local required = getRequiredPartsForPart(businessId, vehicleId, partName, slotPath, currentPartsTree)
      for _, reqPart in ipairs(required) do
        local reqKey = reqPart.partName .. "_" .. reqPart.slotPath
        if not processedParts[reqKey] then
          table.insert(allRequiredParts, reqPart)
          -- Update current parts tree to include this required part for nested checks
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

-- Apply all parts from cart to vehicle (baseline + cart parts)
local function applyCartPartsToVehicle(businessId, vehicleId, parts)
  if not businessId or not vehicleId then return false end
  
  local vehObj = getBusinessVehicleObject(businessId, vehicleId)
  if not vehObj then return false end
  
  -- Ensure initial vehicle state is stored
  if not initialVehicles[businessId] then
    if not initializePreviewVehicle(businessId, vehicleId) then
      return false
    end
  end
  
  -- Use the stored initial vehicle config (baseline from inventory)
  local initialVehicle = initialVehicles[businessId]
  if not initialVehicle or not initialVehicle.config then
    return false
  end
  
  -- Build complete config: baseline + all cart parts
  local completeConfig = deepcopy(initialVehicle.config)
  
  -- Apply all parts from cart to the config, and find all required parts (like vanilla updateInstalledParts)
  if parts and #parts > 0 then
    -- Use the same system as vanilla: find all required parts recursively
    local allPartsToApply = {}
    for _, part in ipairs(parts) do
      if part.partName and part.slotPath then
        table.insert(allPartsToApply, {partName = part.partName, slotPath = part.slotPath})
      end
    end
    
    -- Get all required parts for the parts in cart (same system as when adding to cart)
    local requiredParts = getAllRequiredParts(businessId, vehicleId, allPartsToApply, parts)
    
    -- Combine cart parts with required parts
    local allParts = {}
    for _, part in ipairs(parts) do
      if part.partName and part.slotPath then
        allParts[part.slotPath] = part
      end
    end
    
    -- Add required parts
    for _, reqPart in ipairs(requiredParts) do
      if not allParts[reqPart.slotPath] then
        allParts[reqPart.slotPath] = {
          partName = reqPart.partName,
          slotPath = reqPart.slotPath,
          partNiceName = reqPart.partNiceName or reqPart.partName,
          slotNiceName = reqPart.slotName or '',
          price = reqPart.value or 0
        }
      end
    end
    
    -- Apply all parts (cart + required) to the config
    for slotPath, part in pairs(allParts) do
      if part.partName and part.slotPath then
        createOrUpdatePartsTreeNode(completeConfig.partsTree, part.partName, part.slotPath)
      end
    end
  end
  
  -- Update preview vehicle with complete config
  local modelKey = initialVehicle.model
  previewVehicles[businessId] = {
    config = completeConfig,
    partList = flattenPartsTree(completeConfig.partsTree or {}),
    partConditions = deepcopy(initialVehicle.partConditions or {}),
    model = modelKey
  }
  
  replaceVehicleWithFuelHandling(vehObj, modelKey, completeConfig,
    function()
      core_vehicleBridge.executeAction(vehObj, 'initPartConditions', previewVehicles[businessId].partConditions or {}, nil, nil, nil, nil)
    end,
    function()
      if career_modules_business_businessComputer then
        career_modules_business_businessComputer.requestVehiclePartsTree(businessId, vehicleId)
      end
      if career_modules_business_businessVehicleTuning then
        career_modules_business_businessVehicleTuning.clearTuningDataCache()
      end
      requestVehiclePowerWeight(vehObj, businessId, vehicleId)
    end
  )
  
  return true
end

-- Install a part on the preview vehicle (visual update)
-- This now applies baseline + all cart parts (including the new one)
local function installPartOnVehicle(businessId, vehicleId, partName, slotPath)
  -- This function is called when a part is installed
  -- The actual vehicle update will be handled by applyCartPartsToVehicle
  -- which is called from Vue after the part is added to cart
  return true
end

-- Callback function to receive power from vehicle Lua context
function M.onPowerWeightReceived(requestId, power, weight)
  -- Extract businessId and vehicleId from requestId to cache the result
  local businessId, vehicleId = requestId:match("^(.+)_(.+)_")
  if businessId and vehicleId and power and weight and weight > 0 then
    local cacheKey = businessId .. "_" .. vehicleId
    local result = {
      power = power,
      weight = weight,
      powerToWeight = power / weight
    }
    powerWeightCache[cacheKey] = result
    
    -- Notify Vue via hook when data arrives
    guihooks.trigger('businessComputer:onVehiclePowerWeight', {
      success = true,
      businessId = businessId,
      vehicleId = tonumber(vehicleId),
      power = power,
      weight = weight,
      powerToWeight = result.powerToWeight
    })
  end
end

-- Get vehicle power and weight (must be requested from vehicle Lua context, no fallback)
local function getVehiclePowerWeight(businessId, vehicleId)
  if not businessId or not vehicleId then
    return nil
  end
  
  local vehObj = getBusinessVehicleObject(businessId, vehicleId)
  if not vehObj then
    return nil
  end
  
  local cacheKey = businessId .. "_" .. tostring(vehicleId)
  
  -- Check cache first
  if powerWeightCache[cacheKey] then
    return powerWeightCache[cacheKey]
  end
  
  requestVehiclePowerWeight(vehObj, businessId, vehicleId)
  
  -- Always return nil - data will come via async callback and hook
  return nil
end

-- Get preview vehicle config (for parts tree generation)
local function getPreviewVehicleConfig(businessId)
  if previewVehicles[businessId] then
    return previewVehicles[businessId].config
  end
  return nil
end

-- Get initial vehicle state (baseline from inventory)
local function getInitialVehicleState(businessId)
  if initialVehicles[businessId] then
    return initialVehicles[businessId]
  end
  return nil
end

-- Compare two parts trees and find all parts that differ
local function findChangedParts(baselineTree, newTree, changedParts, path)
  changedParts = changedParts or {}
  path = path or (baselineTree and baselineTree.path) or (newTree and newTree.path) or "/"
  
  -- Compare current node
  local baselinePart = baselineTree and baselineTree.chosenPartName or ""
  local newPart = newTree and newTree.chosenPartName or ""
  
  if baselinePart ~= newPart then
    -- Part changed - add to changed parts list
    if newPart and newPart ~= "" then
      changedParts[path] = {
        partName = newPart,
        slotPath = path
      }
    end
  end
  
  -- Recursively check children
  local baselineChildren = baselineTree and baselineTree.children or {}
  local newChildren = newTree and newTree.children or {}
  
  -- Check all children in new tree
  for slotName, newChild in pairs(newChildren) do
    local childPath = newChild.path or (path .. slotName .. "/")
    local baselineChild = baselineChildren[slotName]
    findChangedParts(baselineChild, newChild, changedParts, childPath)
  end
  
  -- Check for removed children (in baseline but not in new)
  for slotName, baselineChild in pairs(baselineChildren) do
    if not newChildren[slotName] then
      -- Child was removed, but we don't add removed parts to cart
      -- (they're handled by removing from cart)
    end
  end
  
  return changedParts
end

-- Add a part to the cart by spawning vehicle and comparing configs
-- Uses applyCartPartsToVehicle pattern to spawn vehicle, then compares actual config
-- Returns the updated cart with all required parts included
local function addPartToCart(businessId, vehicleId, currentCart, partToAdd)
  if not businessId or not vehicleId or not partToAdd or not partToAdd.partName or not partToAdd.slotPath then
    return currentCart or {}
  end
  
  -- Ensure initial vehicle state is stored
  if not initialVehicles[businessId] then
    if not initializePreviewVehicle(businessId, vehicleId) then
      return currentCart or {}
    end
  end
  
  local baselineTree = initialVehicles[businessId].config.partsTree
  if not baselineTree then
    return currentCart or {}
  end
  
  local cart = deepcopy(currentCart or {})
  
  -- Remove any existing part in the same slot (different part) and all its children
  for i = #cart, 1, -1 do
    local item = cart[i]
    if item.type == 'part' then
      -- If this is the same slot (replacement) or a child of the slot being changed
      if item.slotPath == partToAdd.slotPath or item.slotPath:match("^" .. partToAdd.slotPath:gsub("%-", "%%-") .. "[^/]+") then
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
  local initialConfig = deepcopy(initialVehicles[businessId].config)
  
  -- Build complete config from baseline + tempCart (same as applyCartPartsToVehicle does)
  local completeConfig = deepcopy(initialVehicles[businessId].config)
  
  -- Apply all parts from tempCart to the config
  for _, part in ipairs(tempCart) do
    if part.type == 'part' and part.partName and part.slotPath then
      createOrUpdatePartsTreeNode(completeConfig.partsTree, part.partName, part.slotPath)
    end
  end
  
  -- Store fuel levels before replacing vehicle
  storeFuelLevels(vehObj, function(storedFuelLevels)
    local additionalVehicleData = {spawnWithEngineRunning = false}
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
        core_vehicles.replaceVehicle(vehicleModel, {config = initialConfig, keepOtherVehRotation = true}, vehObj)
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
      
      -- Add all changed parts to cart with proper info
      for slotPath, partInfo in pairs(changedPartsMap) do
        local jbeamData = jbeamIO.getPart(vehicleData.ioCtx, partInfo.partName)
        
        -- Get part nice name from jbeamData.information.description (matching part customization menu)
        -- This matches how formatPartsTreeForUI gets part names (line 393-394 in businessComputer.lua)
        local partNiceName = partInfo.partName
        if jbeamData and jbeamData.information and jbeamData.information.description then
          local desc = jbeamData.information.description
          partNiceName = type(desc) == "table" and desc.description or desc or partInfo.partName
        else
          -- Fallback to availableParts if jbeamData doesn't have description
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
        
        -- Calculate part value (matching vanilla pattern)
        local partValue = 0
        if jbeamData then
          -- Get base value from jbeam (matching vanilla line 95)
          local baseValue = jbeamData.information and jbeamData.information.value or 100
          
          -- Use valueCalculator to get final value (matching vanilla line 108)
          if career_modules_valueCalculator then
            local partForValueCalc = {
              name = partInfo.partName,
              value = baseValue,
              partCondition = {integrityValue = 1, odometer = 0, visualValue = 1},
              vehicleModel = vehicleModel
            }
            partValue = math.max(roundNear(career_modules_valueCalculator.getPartValue(partForValueCalc), 5) - 0.01, 0)
          else
            partValue = baseValue
          end
        end
        
        -- Get slot nice name from slotInfoUi (matching part customization menu)
        local slotNiceName = ""
        local slotInfo = nil
        local slotName = slotPath:match("/([^/]+)/$") or ""
        
        -- Primary method: Get slot info from parent part's slotInfoUi in actual tree
        -- This is the most reliable method as it uses the actual installed parent part
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
        
        -- Fallback: Try previewVehicleSlotData (built from all available parts)
        -- This works for top-level slots or when parent lookup fails
        if slotNiceName == "" and previewVehicleSlotData[businessId] then
          -- Try exact path match first (for top-level slots)
          if previewVehicleSlotData[businessId][slotPath] then
            slotInfo = previewVehicleSlotData[businessId][slotPath]
            if slotInfo.description then
              local desc = slotInfo.description
              slotNiceName = type(desc) == "table" and desc.description or desc or slotName
            end
          end
          
          -- If still not found, try to find by slot name in any path
          if slotNiceName == "" then
            for path, info in pairs(previewVehicleSlotData[businessId]) do
              -- Extract slot name from path
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
        
        -- Final fallback to slot name
        if slotNiceName == "" then
          slotNiceName = slotName
        end
        
        -- Determine if part can be removed (matching vanilla sourcePart logic)
        -- A part can be removed if:
        -- 1. It's not a core slot, OR
        -- 2. The baseline vehicle had a part in that slot (we're replacing it)
        local canRemove = false
        local baselinePartName = initialVehicles[businessId].partList[slotPath]
        if slotInfo then
          -- If not a core slot, can remove
          if not slotInfo.coreSlot then
            canRemove = true
          -- If core slot but baseline had a part, can remove (replacing existing)
          elseif baselinePartName and baselinePartName ~= "" then
            canRemove = true
          end
        else
          -- If no slot info, allow removal if baseline had a part
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
        
        -- If this is the part being directly added, use its info
        if slotPath == partToAdd.slotPath then
          partData.partNiceName = partToAdd.partNiceName or partData.partNiceName
          partData.price = partToAdd.price or partData.price
          partData.slotNiceName = partToAdd.slotNiceName or partData.slotNiceName
          -- Directly added parts can always be removed
          partData.canRemove = true
          
          -- If part is from inventory, mark it
          if partToAdd.fromInventory then
            partData.fromInventory = true
            partData.partId = partToAdd.partId
            partData.price = 0
          end
        end
        
        table.insert(finalCart, partData)
      end
      
      -- Update preview vehicle with the actual config (vehicle is already spawned with correct parts)
      previewVehicles[businessId] = {
        config = deepcopy(actualVehicleData.config),
        partList = flattenPartsTree(actualVehicleData.config.partsTree or {}),
        partConditions = deepcopy(initialVehicles[businessId].partConditions or {}),
        model = vehicleModel
      }
      
      -- Restore fuel levels (vehicle config is already correct, just restore fuel)
      restoreFuelLevels(vehObj, storedFuelLevels)
      
      -- Send updated cart back to UI via event
      guihooks.trigger('businessComputer:onPartCartUpdated', {
        businessId = businessId,
        vehicleId = vehicleId,
        cart = finalCart
      })
      
      -- Request parts tree update so customization menu reflects the changes
      if career_modules_business_businessComputer then
        career_modules_business_businessComputer.requestVehiclePartsTree(businessId, vehicleId)
      end
      
      -- Invalidate tuning cache since parts changed (tuning options may have changed)
      if career_modules_business_businessVehicleTuning then
        career_modules_business_businessVehicleTuning.clearTuningDataCache()
      end
      
      requestVehiclePowerWeight(vehObj, businessId, vehicleId)
      
      -- Note: We keep the vehicle spawned with the test config (which includes all the parts)
      -- This way the vehicle preview matches the cart. We don't restore the original config
      -- because the user wants to see the parts they're adding.
    end, 'ping')
  end)
  
  -- Return temp cart immediately (will be updated via event)
  return cart
end

-- Find removed parts by comparing baseline vs final part lists
-- Returns array of part data objects ready for business inventory
local function findRemovedParts(businessId, vehicleId)
  if not businessId or not vehicleId then
    return {}
  end
  
  -- Ensure initial vehicle state is stored
  if not initialVehicles[businessId] then
    return {}
  end
  
  local initialVehicle = initialVehicles[businessId]
  local previewVehicle = previewVehicles[businessId]
  
  if not initialVehicle or not previewVehicle then
    return {}
  end
  
  local baselinePartList = initialVehicle.partList or {}
  local finalPartList = previewVehicle.partList or {}
  
  local removedParts = {}
  
  -- Get vehicle data for jbeam access and part value calculation
  local vehObj = getBusinessVehicleObject(businessId, vehicleId)
  if not vehObj then return {} end
  
  local vehId = vehObj:getID()
  local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehId)
  if not vehicleData then return {} end
  
  -- Get vehicle model
  local vehicle = career_modules_business_businessInventory.getVehicleById(businessId, vehicleId)
  if not vehicle or not vehicle.vehicleConfig then return {} end
  local vehicleModel = vehicle.vehicleConfig.model_key or vehicle.model_key
  
  -- Compare baseline vs final - find parts that were removed
  for slotPath, partName in pairs(baselinePartList) do
    if partName and partName ~= "" then
      -- Check if part is still in final config
      local finalPartName = finalPartList[slotPath]
      if not finalPartName or finalPartName == "" or finalPartName ~= partName then
        -- Part was removed - create part data object
        local partCondition = initialVehicle.partConditions and initialVehicle.partConditions[slotPath .. partName]
        if not partCondition then
          -- Default condition if not found
          partCondition = {
            integrityValue = 1,
            visualValue = 1,
            odometer = 0
          }
        end
        
        -- Create part data object
        local partData = {
          name = partName,
          containingSlot = slotPath,
          slot = slotPath:match("/([^/]+)/$") or slotPath:match("/([^/]+)$") or "",
          vehicleModel = vehicleModel,
          partCondition = partCondition
        }
        
        -- Calculate part value using valueCalculator (matching vanilla pattern)
        if career_modules_valueCalculator then
          partData.value = career_modules_valueCalculator.getPartValue(partData) or 0
        else
          -- Fallback if valueCalculator not available
          local jbeamData = jbeamIO.getPart(vehicleData.ioCtx, partName)
          partData.value = (jbeamData and jbeamData.information and jbeamData.information.value) or 100
        end
        
        table.insert(removedParts, partData)
      end
    end
  end
  
  return removedParts
end

-- Clear preview vehicle state (called when leaving part customization)
local function clearPreviewVehicle(businessId)
  if businessId then
    previewVehicles[businessId] = nil
    initialVehicles[businessId] = nil
    previewVehicleSlotData[businessId] = nil
    powerWeightCache = {}
  end
end

-- Exports
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



