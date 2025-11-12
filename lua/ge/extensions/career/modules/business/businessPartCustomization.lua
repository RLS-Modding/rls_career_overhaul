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
  
  -- Get original vehicle state from inventory
  local vehicle = career_modules_business_businessInventory.getVehicleById(businessId, vehicleId)
  if not vehicle or not vehicle.vehicleConfig then return false end
  
  local modelKey = vehicle.vehicleConfig.model_key or vehicle.model_key
  if not modelKey then return false end
  
  -- Ensure initial vehicle state is stored (from when vehicle was first pulled out)
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
  
  local originalConfig = initialVehicle.config
  local vehId = vehObj:getID()
  
  -- Store fuel levels before replacing vehicle
  storeFuelLevels(vehObj, function(storedFuelLevels)
    local additionalVehicleData = {spawnWithEngineRunning = false}
    core_vehicle_manager.queueAdditionalVehicleData(additionalVehicleData, vehId)
    
    local spawnOptions = {}
    spawnOptions.config = originalConfig
    spawnOptions.keepOtherVehRotation = true
    
    -- Replace vehicle with original config
    core_vehicles.replaceVehicle(modelKey, spawnOptions, vehObj)
    
    -- Apply original part conditions and tuning from initial state
    if initialVehicle.partConditions then
      core_vehicleBridge.executeAction(vehObj, 'initPartConditions', initialVehicle.partConditions, nil, nil, nil, nil)
    end
    
    if initialVehicle.vars then
      for varName, value in pairs(initialVehicle.vars) do
        core_vehicleBridge.executeAction(vehObj, 'setVar', varName, value)
      end
    end
    
    -- Restore fuel levels after vehicle replacement
    core_vehicleBridge.requestValue(vehObj, function()
      restoreFuelLevels(vehObj, storedFuelLevels)
      
      -- Automatically calculate and send power/weight after vehicle replacement
      local cacheKey = businessId .. "_" .. tostring(vehicleId)
      local requestId = cacheKey .. "_" .. tostring(os.clock())
      
      -- Execute Lua command in vehicle context to get both power and weight
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
    end, 'ping')
  end)
  
  -- Reset preview vehicle to match initial state
  previewVehicles[businessId] = {
    config = deepcopy(originalConfig),
    partList = flattenPartsTree(originalConfig.partsTree or {}),
    partConditions = deepcopy(initialVehicle.partConditions or {}),
    model = modelKey
  }
  
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
      local node = getNodeFromSlotPath(completeConfig.partsTree, part.slotPath)
      if node then
        node.chosenPartName = part.partName
      else
        -- Create node if it doesn't exist
        local parentPath = part.slotPath:match("(.+)/[^/]+/$") or "/"
        local parentNode = getNodeFromSlotPath(completeConfig.partsTree, parentPath)
        if parentNode then
          if not parentNode.children then parentNode.children = {} end
          local slotName = part.slotPath:match("/([^/]+)/$") or part.slotPath:match("/([^/]+)$") or ""
          if slotName and slotName ~= "" then
            parentNode.children[slotName] = {
              chosenPartName = part.partName,
              path = part.slotPath,
              children = {},
              suitablePartNames = {part.partName},
              unsuitablePartNames = {},
              decisionMethod = "user"
            }
          end
        end
      end
    end
  end
  
  -- Update preview vehicle with complete config
  previewVehicles[businessId] = {
    config = completeConfig,
    partList = flattenPartsTree(completeConfig.partsTree or {}),
    partConditions = deepcopy(vehicle.partConditions or {}),
    model = modelKey
  }
  
  -- Store fuel levels before replacing vehicle
  local vehId = vehObj:getID()
  storeFuelLevels(vehObj, function(storedFuelLevels)
    local additionalVehicleData = {spawnWithEngineRunning = false}
    core_vehicle_manager.queueAdditionalVehicleData(additionalVehicleData, vehId)
    
    local spawnOptions = {}
    spawnOptions.config = completeConfig  -- Use the complete config with all parts
    spawnOptions.keepOtherVehRotation = true
    
    -- Replace vehicle with complete config
    core_vehicles.replaceVehicle(modelKey, spawnOptions, vehObj)
    
    -- Initialize part conditions
    core_vehicleBridge.executeAction(vehObj, 'initPartConditions', previewVehicles[businessId].partConditions or {}, nil, nil, nil, nil)
    
    -- Restore fuel levels after vehicle replacement
    core_vehicleBridge.requestValue(vehObj, function()
      restoreFuelLevels(vehObj, storedFuelLevels)
      
      -- Notify businessComputer to regenerate parts tree
      if career_modules_business_businessComputer then
        career_modules_business_businessComputer.requestVehiclePartsTree(businessId, vehicleId)
      end
      
      -- Automatically calculate and send power/weight after vehicle replacement
      local cacheKey = businessId .. "_" .. tostring(vehicleId)
      local requestId = cacheKey .. "_" .. tostring(os.clock())
      
      -- Execute Lua command in vehicle context to get both power and weight
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
    end, 'ping')
  end)
  
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
          local node = getNodeFromSlotPath(partsTree, part.slotPath)
          if node then
            node.chosenPartName = part.partName
          else
            -- Create node if it doesn't exist
            local parentPath = part.slotPath:match("(.+)/[^/]+/$") or "/"
            local parentNode = getNodeFromSlotPath(partsTree, parentPath)
            if parentNode then
              if not parentNode.children then parentNode.children = {} end
              local slotName = part.slotPath:match("/([^/]+)/$") or part.slotPath:match("/([^/]+)$") or ""
              if slotName and slotName ~= "" then
                parentNode.children[slotName] = {
                  chosenPartName = part.partName,
                  path = part.slotPath,
                  children = {},
                  suitablePartNames = {part.partName},
                  unsuitablePartNames = {},
                  decisionMethod = "user"
                }
              end
            end
          end
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
  
  -- Get slotType for all parts
  for path, part in pairs(combinedSlotToPartMap) do
    local jbeamData = jbeamIO.getPart(vehicleData.ioCtx, part.name)
    if jbeamData then
      part.slotType = jbeamData.slotType
      part.description = jbeamData
    end
  end
  
  -- Check each part's child slots and add default parts if needed
  local addedParts = false
  local resultParts = deepcopy(parts)
  
  for slotPath, part in pairs(parts) do
    if part.description and part.description.slotInfoUi then
      for slotName, slotInfo in pairs(part.description.slotInfoUi) do
        local childPath = slotPath .. slotName .. "/"
        
        -- Check if slot is empty or part doesn't fit
        local childPart = combinedSlotToPartMap[childPath]
        local needsPart = true
        if childPart then
          local childJbeamData = jbeamIO.getPart(vehicleData.ioCtx, childPart.name)
          if childJbeamData and jbeamSlotSystem.partFitsSlot(childJbeamData, slotInfo) then
            needsPart = false
          end
        end
        
        if needsPart then
          -- Get default part name
          local defaultPartName = nil
          if part.description.slots2 then
            for _, slot in ipairs(part.description.slots2) do
              if slot.name == slotName and slot.default and slot.default ~= "" then
                defaultPartName = slot.default
                break
              end
            end
          end
          
          if defaultPartName then
            -- Create part entry for default part
            local defaultPart = {
              name = defaultPartName,
              containingSlot = childPath,
              slot = slotName,
              description = jbeamIO.getPart(vehicleData.ioCtx, defaultPartName)
            }
            
            resultParts[childPath] = defaultPart
            addedParts = true
            
            -- Update combined map for next iteration
            combinedSlotToPartMap[childPath] = defaultPart
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
          local reqNode = getNodeFromSlotPath(currentPartsTree, reqPart.slotPath)
          if not reqNode then
            local parentPath = reqPart.slotPath:match("(.+)/[^/]+/$") or "/"
            local parentNode = getNodeFromSlotPath(currentPartsTree, parentPath)
            if parentNode then
              if not parentNode.children then parentNode.children = {} end
              local slotName = reqPart.slotPath:match("/([^/]+)/$") or reqPart.slotPath:match("/([^/]+)$") or ""
              if slotName and slotName ~= "" then
                parentNode.children[slotName] = {
                  chosenPartName = reqPart.partName,
                  path = reqPart.slotPath,
                  children = {},
                  suitablePartNames = {reqPart.partName},
                  unsuitablePartNames = {},
                  decisionMethod = "user"
                }
              end
            end
          else
            reqNode.chosenPartName = reqPart.partName
          end
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
        local node = getNodeFromSlotPath(completeConfig.partsTree, part.slotPath)
        if node then
          node.chosenPartName = part.partName
        else
          -- Create node if it doesn't exist
          local parentPath = part.slotPath:match("(.+)/[^/]+/$") or "/"
          local parentNode = getNodeFromSlotPath(completeConfig.partsTree, parentPath)
          if parentNode then
            if not parentNode.children then parentNode.children = {} end
            local slotName = part.slotPath:match("/([^/]+)/$") or part.slotPath:match("/([^/]+)$") or ""
            if slotName and slotName ~= "" then
              parentNode.children[slotName] = {
                chosenPartName = part.partName,
                path = part.slotPath,
                children = {},
                suitablePartNames = {part.partName},
                unsuitablePartNames = {},
                decisionMethod = "user"
              }
            end
          end
        end
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
  
  -- Store fuel levels before replacing vehicle
  local vehId = vehObj:getID()
  storeFuelLevels(vehObj, function(storedFuelLevels)
    local additionalVehicleData = {spawnWithEngineRunning = false}
    core_vehicle_manager.queueAdditionalVehicleData(additionalVehicleData, vehId)
    
    local spawnOptions = {}
    spawnOptions.config = completeConfig
    spawnOptions.keepOtherVehRotation = true
    
    -- Replace vehicle with complete config (baseline + cart parts)
    core_vehicles.replaceVehicle(modelKey, spawnOptions, vehObj)
    
    -- Initialize part conditions
    core_vehicleBridge.executeAction(vehObj, 'initPartConditions', previewVehicles[businessId].partConditions or {}, nil, nil, nil, nil)
    
    -- Restore fuel levels after vehicle replacement
    core_vehicleBridge.requestValue(vehObj, function()
      restoreFuelLevels(vehObj, storedFuelLevels)
      
      -- Notify businessComputer to regenerate parts tree
      if career_modules_business_businessComputer then
        career_modules_business_businessComputer.requestVehiclePartsTree(businessId, vehicleId)
      end
      
      -- Automatically calculate and send power/weight after vehicle replacement
      local cacheKey = businessId .. "_" .. tostring(vehicleId)
      local requestId = cacheKey .. "_" .. tostring(os.clock())
      
      -- Execute Lua command in vehicle context to get both power and weight
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
    end, 'ping')
  end)
  
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
  
  -- Generate unique request ID
  local requestId = cacheKey .. "_" .. tostring(os.clock())
  
  -- Execute Lua command in vehicle context to get both power and weight
  -- calcBeamStats() is only available in vehicle Lua context, not game engine Lua
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

-- Add a part to the cart and automatically include required parts
-- Returns the updated cart with all required parts included
-- Follows vanilla pattern exactly: loop until no more required parts are found
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
  local partsToRemove = {}
  for i = #cart, 1, -1 do
    local item = cart[i]
    if item.type == 'part' then
      -- If this is the same slot (replacement) or a child of the slot being changed
      if item.slotPath == partToAdd.slotPath or item.slotPath:match("^" .. partToAdd.slotPath:gsub("%-", "%%-") .. "[^/]+") then
        table.insert(partsToRemove, i)
      end
    end
  end
  
  for _, index in ipairs(partsToRemove) do
    table.remove(cart, index)
  end
  
  -- Get vehicle data for jbeam access
  local vehObj = getBusinessVehicleObject(businessId, vehicleId)
  if not vehObj then return currentCart or {} end
  
  local vehId = vehObj:getID()
  local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehId)
  if not vehicleData or not vehicleData.ioCtx then return currentCart or {} end
  
  local availableParts = jbeamIO.getAvailableParts(vehicleData.ioCtx)
  
  -- Start with new part in parts map (like vanilla uses)
  local addedParts = {}
  local jbeamData = jbeamIO.getPart(vehicleData.ioCtx, partToAdd.partName)
  if jbeamData then
    addedParts[partToAdd.slotPath] = {
      name = partToAdd.partName,
      containingSlot = partToAdd.slotPath,
      slot = partToAdd.slotPath:match("/([^/]+)/$") or "",
      description = jbeamData
    }
  end
  
  -- Loop until no more parts added (EXACTLY like vanilla lines 589-605)
  local werePartsAdded = true
  while werePartsAdded do
    addedParts, werePartsAdded = getNeededAdditionalParts(businessId, vehicleId, addedParts, baselineTree, cart)
  end
  
  -- After loop completes, convert parts map to cart format and build final tree
  local tempCart = deepcopy(cart)
  for slotPath, part in pairs(addedParts) do
    -- Check if part already exists in cart
    local exists = false
    for _, item in ipairs(tempCart) do
      if item.type == 'part' and item.slotPath == slotPath then
        exists = true
        break
      end
    end
    
    if not exists then
      -- Get part nice name and price from jbeam data
      local partNiceName = availableParts[part.name] or part.name
      local partValue = 0
      if part.description and part.description.value then
        partValue = part.description.value
      end
      
      -- Get slot nice name
      local slotNiceName = ""
      local parentPath = slotPath:match("(.+)/[^/]+/$") or "/"
      local parentNode = getNodeFromSlotPath(baselineTree, parentPath)
      if parentNode and parentNode.children then
        local slotName = slotPath:match("/([^/]+)/$") or ""
        for childSlotName, _ in pairs(parentNode.children) do
          if childSlotName == slotName then
            slotNiceName = childSlotName
            break
          end
        end
      end
      
      table.insert(tempCart, {
        type = 'part',
        partName = part.name,
        partNiceName = partNiceName,
        slotPath = slotPath,
        slotNiceName = slotNiceName,
        price = partValue
      })
    end
  end
  
  -- Build final tree with ALL parts (baseline + cart + new + required)
  local finalTree = buildPartsTreeFromCart(businessId, tempCart)
  
  -- Compare baseline vs final tree to find ALL changed parts (including children)
  local changedPartsMap = findChangedParts(baselineTree, finalTree, {})
  
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
    -- Get part info from tempCart if available (has nice name and price)
    local partData = nil
    for _, item in ipairs(tempCart) do
      if item.type == 'part' and item.slotPath == slotPath then
        partData = item
        break
      end
    end
    
    -- If not found in tempCart, get from jbeam
    if not partData then
      local jbeamData = jbeamIO.getPart(vehicleData.ioCtx, partInfo.partName)
      local partNiceName = availableParts[partInfo.partName] or partInfo.partName
      local partValue = 0
      if jbeamData and jbeamData.value then
        partValue = jbeamData.value
      end
      
      -- Get slot nice name
      local slotNiceName = ""
      local parentPath = slotPath:match("(.+)/[^/]+/$") or "/"
      local parentNode = getNodeFromSlotPath(baselineTree, parentPath)
      if parentNode and parentNode.children then
        local slotName = slotPath:match("/([^/]+)/$") or ""
        for childSlotName, _ in pairs(parentNode.children) do
          if childSlotName == slotName then
            slotNiceName = childSlotName
            break
          end
        end
      end
      
      partData = {
        type = 'part',
        partName = partInfo.partName,
        partNiceName = partNiceName,
        slotPath = slotPath,
        slotNiceName = slotNiceName,
        price = partValue
      }
    end
    
    -- If this is the part being directly added, use its info
    if slotPath == partToAdd.slotPath then
      partData.partNiceName = partToAdd.partNiceName or partData.partNiceName
      partData.price = partToAdd.price or partData.price
      partData.slotNiceName = partToAdd.slotNiceName or partData.slotNiceName
    end
    
    table.insert(finalCart, partData)
  end
  
  return finalCart
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
M.clearPreviewVehicle = clearPreviewVehicle
M.getAllRequiredParts = getAllRequiredParts
M.addPartToCart = addPartToCart

return M

