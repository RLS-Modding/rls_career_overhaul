local M = {}

M.dependencies = {'career_career', 'core_vehicles', 'core_jobsystem', 'career_modules_bank'}

local jbeamIO = require('jbeam/io')

-- Cache for tuning data (keyed by businessId_vehicleId)
local tuningDataCache = {}

-- Pricing structure (from tuning.lua)
local prices = {
  Suspension = {
    Front = {
      price = 100
    },
    Rear = {
      price = 100
    }
  },
  Wheels = {
    Front = {
      price = 100
    },
    Rear = {
      price = 100
    }
  },
  Transmission = {
    price = 500,
    default = {
      default = true,
      variables = {
        ["$gear_1"] = { price = 100},
        ["$gear_2"] = { price = 100},
        ["$gear_3"] = { price = 100},
        ["$gear_4"] = { price = 100},
        ["$gear_5"] = { price = 100},
        ["$gear_6"] = { price = 100},
        ["$gear_R"] = { price = 100},
      }
    }
  },
  ["Wheel Alignment"] = {
    Front = {
      price = 100
    },
    Rear = {
      price = 100
    }
  },
  Chassis = {
    price = 100
  },
  default = {
    default = true,
    price = 200
  }
}

-- Shopping cart blacklist (items that are free)
local shoppingCartBlackList = {
  {name = "$$ffbstrength", category = "Chassis"},
  {name = "$tirepressure_F", category = "Wheels", subCategory = "Front"},
  {name = "$tirepressure_R", category = "Wheels", subCategory = "Rear"},
}

local function isOnBlackList(varData)
  for _, blackListItem in ipairs(shoppingCartBlackList) do
    if blackListItem.name ~= varData.name then goto continue end
    if blackListItem.category ~= varData.category then goto continue end
    if blackListItem.subCategory ~= varData.subCategory then goto continue end
    do return true end
    ::continue::
  end
  return false
end

local function getPrice(category, subCategory, varName)
  if prices[category] then
    if prices[category][subCategory] then
      if prices[category][subCategory].variables and prices[category][subCategory].variables[varName] then
        return prices[category][subCategory].variables[varName].price or 0
      end
    elseif prices[category].default then
      if prices[category].default.variables and prices[category].default.variables[varName] then
        return prices[category].default.variables[varName].price or 0
      end
    end
  elseif prices.default then
    if prices.default.variables and prices.default.variables[varName] then
      return prices.default.variables[varName].price or 0
    end
  end
  -- Use default price if price cannot be retrieved
  return prices.default and prices.default.price or 200
end

local function getPriceCategory(category)
  if prices[category] then return prices[category].price or 0 end
  return prices.default.price
end

local function getPriceSubCategory(category, subCategory)
  if prices[category] then
    if prices[category][subCategory] then
      return prices[category][subCategory].price or 0
    end
    return prices[category].default and prices[category].default.price or 0
  end
  return 0
end

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

-- Function to request tuning data for a business vehicle (triggers hook)
local function requestVehicleTuningData(businessId, vehicleId)
  if not businessId or not vehicleId then
    guihooks.trigger('businessComputer:onVehicleTuningData', {
      success = false,
      error = "Missing parameters"
    })
    return
  end

  local cacheKey = businessId .. "_" .. tostring(vehicleId)
  if tuningDataCache[cacheKey] then
    guihooks.trigger('businessComputer:onVehicleTuningData', {
      success = true,
      businessId = businessId,
      vehicleId = vehicleId,
      tuningData = tuningDataCache[cacheKey]
    })
    return
  end

  core_jobsystem.create(function(job)
    local vehicle = career_modules_business_businessInventory.getVehicleById(businessId, vehicleId)
    if not vehicle or not vehicle.vehicleConfig then
      guihooks.trigger('businessComputer:onVehicleTuningData', {
        success = false,
        error = "Vehicle not found"
      })
      return
    end

    local modelKey = vehicle.vehicleConfig.model_key or vehicle.model_key
    local configKey = vehicle.vehicleConfig.key or vehicle.config_key

    if not modelKey or not configKey then
      guihooks.trigger('businessComputer:onVehicleTuningData', {
        success = false,
        error = "Invalid vehicle config"
      })
      return
    end

    local vehicleObj = getBusinessVehicleObject(businessId, vehicleId)
    if not vehicleObj then
      guihooks.trigger('businessComputer:onVehicleTuningData', {
        success = false,
        error = "Preview vehicle not found"
      })
      return
    end

    local vehId = vehicleObj:getID()

    local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehId)
    if not vehicleData or not vehicleData.vdata or not vehicleData.vdata.variables then
      guihooks.trigger('businessComputer:onVehicleTuningData', {
        success = false,
        error = "No tuning variables found"
      })
      return
    end

    local baselineVars = {}
    if career_modules_business_businessPartCustomization then
      local initialVehicle = career_modules_business_businessPartCustomization.getInitialVehicleState(businessId)
      if initialVehicle and initialVehicle.vars then
        baselineVars = initialVehicle.vars
      end
    end
    
    local currentVars = vehicle.vars or {}
    local tuningVariables = deepcopy(vehicleData.vdata.variables)
    
    local requestId = "tuning_" .. businessId .. "_" .. tostring(vehicleId) .. "_" .. tostring(os.clock())
    
    local context = {
      businessId = businessId,
      vehicleId = vehicleId,
      vehicleData = vehicleData,
      currentVars = currentVars,
      baselineVars = baselineVars,
      tuningVariables = tuningVariables,
      cacheKey = cacheKey
    }
    
    vehicleObj:queueLuaCommand([[
      if v and v.config and v.config.partsTree then
        local partsTreeStr = nil
        if jsonEncode then
          partsTreeStr = jsonEncode(v.config.partsTree)
          partsTreeStr = string.gsub(partsTreeStr, "'", "\\'")
        elseif serialize then
          partsTreeStr = serialize(v.config.partsTree)
          partsTreeStr = string.gsub(partsTreeStr, "'", "\\'")
        end
        if partsTreeStr then
          obj:queueGameEngineLua("career_modules_business_businessVehicleTuning.onPartsTreeReceived(']] .. requestId .. [[', '" .. partsTreeStr .. "')")
        else
          obj:queueGameEngineLua("career_modules_business_businessVehicleTuning.onPartsTreeReceived(']] .. requestId .. [[', nil)")
        end
      else
        obj:queueGameEngineLua("career_modules_business_businessVehicleTuning.onPartsTreeReceived(']] .. requestId .. [[', nil)")
      end
    ]])
    
    if not M._tuningRequestContexts then
      M._tuningRequestContexts = {}
    end
    M._tuningRequestContexts[requestId] = context
    
    return
  end)
end

function M.onVehicleVarReceived(contextId, varName, value)
end

function M.onPartsTreeReceived(requestId, partsTreeStr)
  local context = M._tuningRequestContexts and M._tuningRequestContexts[requestId]
  if not context then
    return
  end
  
  M._tuningRequestContexts[requestId] = nil
  
  local businessId = context.businessId
  local vehicleId = context.vehicleId
  local vehicleData = context.vehicleData
  local currentVars = context.currentVars
  local baselineVars = context.baselineVars
  local tuningVariables = context.tuningVariables
  local cacheKey = context.cacheKey
  
  local partsTree = nil
  if partsTreeStr and partsTreeStr ~= "nil" and partsTreeStr ~= "" then
    local success, result = pcall(function()
      if jsonDecode then
        return jsonDecode(partsTreeStr)
      else
        return loadstring("return " .. partsTreeStr)()
      end
    end)
    if success and result then
      partsTree = result
    end
  end
  
  if not partsTree then
    guihooks.trigger('businessComputer:onVehicleTuningData', {
      success = false,
      businessId = businessId,
      vehicleId = vehicleId,
      error = "Could not get parts tree from vehicle"
    })
    return
  end
    
    -- Process tuning variables from parts tree
    if partsTree and vehicleData.ioCtx then
      -- Helper function to recursively traverse parts tree and extract tuning variables
      -- Now tracks which part each variable belongs to
      local function extractPartTuningVars(node, partTuningVars, slotPath)
        if not node then return end
        
        local currentSlotPath = slotPath or (node.path or "/")
        
        -- If this node has a chosen part, get its jbeam and extract tuning variables
        if node.chosenPartName and node.chosenPartName ~= "" then
          local jbeamData = jbeamIO.getPart(vehicleData.ioCtx, node.chosenPartName)
          if jbeamData and jbeamData.variables then
            for key, varData in pairs(jbeamData.variables) do
              local varName = nil
              if type(key) == "string" then
                varName = key
              elseif type(key) == "number" and type(varData) == "table" then
                if varData.name then
                  varName = varData.name
                else
                  goto continue
                end
              else
                goto continue
              end
              
              local isTuningVar = false
              if varData.min ~= nil or varData.max ~= nil then
                isTuningVar = true
              elseif type(varName) == "string" and varName:match("^%$") then
                isTuningVar = true
              end
              
              if isTuningVar then
                -- Create a unique key that includes part info: varName_partName_slotPath
                local varKey = varName .. "_" .. node.chosenPartName .. "_" .. currentSlotPath
                
                if partTuningVars[varKey] then
                  -- Variable already exists from another part - merge ranges
                  if varData.min ~= nil then
                    if partTuningVars[varKey].min == nil or varData.min > partTuningVars[varKey].min then
                      partTuningVars[varKey].min = varData.min
                    end
                  end
                  if varData.max ~= nil then
                    if partTuningVars[varKey].max == nil or varData.max < partTuningVars[varKey].max then
                      partTuningVars[varKey].max = varData.max
                    end
                  end
                  if varData.step and not partTuningVars[varKey].step then
                    partTuningVars[varKey].step = varData.step
                  end
                  if varData.title and not partTuningVars[varKey].title then
                    partTuningVars[varKey].title = varData.title
                  end
                  if varData.category and not partTuningVars[varKey].category then
                    partTuningVars[varKey].category = varData.category
                  end
                  if varData.subCategory and not partTuningVars[varKey].subCategory then
                    partTuningVars[varKey].subCategory = varData.subCategory
                  end
                  if varData.options and not partTuningVars[varKey].options then
                    partTuningVars[varKey].options = deepcopy(varData.options)
                  end
                else
                  -- Store variable with part information
                  partTuningVars[varKey] = deepcopy(varData)
                  partTuningVars[varKey]._partName = node.chosenPartName
                  partTuningVars[varKey]._slotPath = currentSlotPath
                  partTuningVars[varKey]._varName = varName
                end
              end
              ::continue::
            end
          end
        end
        
        if node.children then
          for _, childNode in pairs(node.children) do
            extractPartTuningVars(childNode, partTuningVars, childNode.path or currentSlotPath)
          end
        end
      end
      
      local partTuningVars = {}
      extractPartTuningVars(partsTree, partTuningVars)
      
      -- Build a map of varName -> array of variable entries (one per part)
      local varNameToParts = {}
      for varKey, varData in pairs(partTuningVars) do
        local varName = varData._varName
        if not varNameToParts[varName] then
          varNameToParts[varName] = {}
        end
        table.insert(varNameToParts[varName], varData)
      end
      
      -- For each variable name, store all parts that have it
      -- When multiple parts have the same variable, we'll need to check which part is installed
      for varName, partsList in pairs(varNameToParts) do
        if #partsList == 1 then
          -- Only one part has this variable - store it normally
          local varData = partsList[1]
          tuningVariables[varName] = {
            min = varData.min,
            max = varData.max,
            step = varData.step,
            title = varData.title,
            category = varData.category,
            subCategory = varData.subCategory,
            options = varData.options,
            _parts = {varData}
          }
        else
          -- Multiple parts have this variable - store all of them
          -- Merge min/max ranges from all parts
          local mergedMin = nil
          local mergedMax = nil
          for _, varData in ipairs(partsList) do
            if varData.min ~= nil then
              if mergedMin == nil or varData.min > mergedMin then
                mergedMin = varData.min
              end
            end
            if varData.max ~= nil then
              if mergedMax == nil or varData.max < mergedMax then
                mergedMax = varData.max
              end
            end
          end
          
          tuningVariables[varName] = {
            min = mergedMin,
            max = mergedMax,
            step = partsList[1].step,
            title = partsList[1].title,
            category = partsList[1].category,
            subCategory = partsList[1].subCategory,
            options = partsList[1].options,
            _parts = partsList
          }
        end
      end
    end

    tuningVariables["$fuel"] = nil
    tuningVariables["$fuel_R"] = nil
    tuningVariables["$fuel_L"] = nil
    
    for varName, varData in pairs(tuningVariables) do
      if varData.category == "Cargo" then
        tuningVariables[varName] = nil
      end
    end

    for varName, varData in pairs(tuningVariables) do
      if baselineVars[varName] ~= nil then
        varData.val = baselineVars[varName]
      elseif currentVars[varName] ~= nil then
        varData.val = currentVars[varName]
      elseif varData.val == nil then
        varData.val = varData.min or 0
      end

      -- Calculate display values (valDis, minDis, maxDis, stepDis)
      -- Check for options object first, then fall back to calculated values
      local rawMin = varData.min or 0
      local rawMax = varData.max or 100
      
      -- Handle inverted ranges (when min > max, swap them)
      local actualMin = rawMin
      local actualMax = rawMax
      if rawMin > rawMax then
        actualMin = rawMax
        actualMax = rawMin
        varData._rangeInverted = true
      else
        varData._rangeInverted = false
      end
      
      -- Check if options object provides display values
      local hasOptions = varData.options and type(varData.options) == "table"
      local optionsMinDis = hasOptions and varData.options.minDis
      local optionsMaxDis = hasOptions and varData.options.maxDis
      local optionsStepDis = hasOptions and varData.options.stepDis
      
      -- Special handling for Wheel Alignment percentage variables
      -- Set slider range to -100% to 100% but keep actual values unchanged
      if varData.category == "Wheel Alignment" and (varData.unit == '%' or varData.unit == 'percent') then
        varData.minDis = -1
        varData.maxDis = 1
        -- Default to 0 if val is not set or is at the original min
        if varData.val == nil or varData.val == actualMin then
          varData.valDis = 0
        else
          -- Map the actual value to the -1 to 1 range proportionally
          -- This keeps the slider centered at 0 but allows mapping existing values
          local range = actualMax - actualMin
          if range > 0 then
            -- Map from [actualMin, actualMax] to [-1, 1]
            varData.valDis = ((varData.val - actualMin) / range) * 2 - 1
          else
            varData.valDis = 0
          end
        end
      else
        -- Use options.minDis/maxDis if available, otherwise use calculated values
        if optionsMinDis ~= nil then
          varData.minDis = optionsMinDis
        else
          varData.minDis = actualMin
        end
        if optionsMaxDis ~= nil then
          varData.maxDis = optionsMaxDis
        else
          varData.maxDis = actualMax
        end
        
        -- Map actual value to display range if display range differs from actual range
        local actualVal = varData.val or actualMin
        if optionsMinDis ~= nil or optionsMaxDis ~= nil then
          -- Map from [actualMin, actualMax] to [minDis, maxDis]
          local actualRange = actualMax - actualMin
          local displayRange = varData.maxDis - varData.minDis
          if actualRange > 0 and displayRange > 0 then
            varData.valDis = ((actualVal - actualMin) / actualRange) * displayRange + varData.minDis
          else
            varData.valDis = varData.minDis
          end
        else
          varData.valDis = actualVal
        end
      end
      
      -- Use step if available, otherwise calculate a reasonable default based on range
      if optionsStepDis ~= nil then
        varData.stepDis = optionsStepDis
      elseif varData.step and varData.step > 0 then
        varData.stepDis = varData.step
      else
        -- For wheel alignment percentages, use 0.01 step (1% increments)
        if varData.category == "Wheel Alignment" and (varData.unit == '%' or varData.unit == 'percent') then
          varData.stepDis = 0.01
        else
          -- Calculate step as 1/1000th of the range, but ensure it's at least 0.001
          local range = math.abs(varData.maxDis - varData.minDis)
          varData.stepDis = math.max(0.001, math.min(1, range / 1000))
        end
      end

      -- Ensure valDis is within bounds
      if varData.valDis < varData.minDis then
        varData.valDis = varData.minDis
      elseif varData.valDis > varData.maxDis then
        varData.valDis = varData.maxDis
      end
      
    end

    -- Cache the data
    tuningDataCache[cacheKey] = tuningVariables

    -- Trigger hook with data (include baseline vars separately so Vue can use them for reset)
    guihooks.trigger('businessComputer:onVehicleTuningData', {
      success = true,
      businessId = businessId,
      vehicleId = vehicleId,
      tuningData = tuningVariables,
      baselineVars = baselineVars
    })
end

-- Legacy function for backward compatibility (now uses hook internally)
local function getVehicleTuningData(businessId, vehicleId)
  requestVehicleTuningData(businessId, vehicleId)
  return nil -- Return nil since data comes via hook
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

-- Function to apply tuning visually to preview vehicle
local function applyTuningToVehicle(businessId, vehicleId, tuningVars)
  if not businessId or not vehicleId or not tuningVars then
    return false
  end
  
  local vehObj = getBusinessVehicleObject(businessId, vehicleId)
  if not vehObj then return false end
  
  -- Get current preview vehicle config (includes parts from cart)
  if not career_modules_business_businessPartCustomization then
    return false
  end
  
  local currentConfig = career_modules_business_businessPartCustomization.getPreviewVehicleConfig(businessId)
  if not currentConfig then
    -- If no preview config exists, initialize it
    if not career_modules_business_businessPartCustomization.initializePreviewVehicle then
      return false
    end
    if not career_modules_business_businessPartCustomization.initializePreviewVehicle(businessId, vehicleId) then
      return false
    end
    currentConfig = career_modules_business_businessPartCustomization.getPreviewVehicleConfig(businessId)
    if not currentConfig then
      return false
    end
  end
  
  -- Get vehicle model
  local vehicle = career_modules_business_businessInventory.getVehicleById(businessId, vehicleId)
  if not vehicle or not vehicle.vehicleConfig then return false end
  local modelKey = vehicle.vehicleConfig.model_key or vehicle.model_key
  if not modelKey then return false end
  
  -- Get tuning data cache to check which parts variables belong to
  local cacheKey = businessId .. "_" .. tostring(vehicleId)
  local tuningData = tuningDataCache[cacheKey]
  
  -- Get parts tree to check which parts are installed
  local partsTree = currentConfig.partsTree
  
  -- Create updated config with new tuning vars
  local updatedConfig = deepcopy(currentConfig)
  if not updatedConfig.vars then
    updatedConfig.vars = {}
  end
  
  local varsToApply = {}
  
  for varName, value in pairs(tuningVars) do
    if tuningData and tuningData[varName] and tuningData[varName]._parts then
      local partsList = tuningData[varName]._parts
      local shouldApply = false
      
      for _, partVarData in ipairs(partsList) do
        local partName = partVarData._partName
        local slotPath = partVarData._slotPath
        
        if partName and slotPath and partsTree then
          local node = getNodeFromSlotPath(partsTree, slotPath)
          if node and node.chosenPartName == partName then
            shouldApply = true
            break
          end
        end
      end
      
      if shouldApply then
        varsToApply[varName] = value
      end
    else
      varsToApply[varName] = value
    end
  end
  
  updatedConfig.vars = tableMerge(deepcopy(updatedConfig.vars), varsToApply)
  
  local vehId = vehObj:getID()
  
  -- Store fuel levels before replacing vehicle (using same pattern as parts customization)
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
    
    local additionalVehicleData = {spawnWithEngineRunning = false}
    core_vehicle_manager.queueAdditionalVehicleData(additionalVehicleData, vehId)
    
    local spawnOptions = {}
    spawnOptions.config = updatedConfig
    spawnOptions.keepOtherVehRotation = true
    
    core_vehicles.replaceVehicle(modelKey, spawnOptions, vehObj)
    
    core_vehicleBridge.requestValue(vehObj, function(newData)
      
      if storedFuelLevels and next(storedFuelLevels) and newData and newData[1] then
        for _, tank in ipairs(newData[1]) do
          if tank.name and storedFuelLevels[tank.name] and tank.energyType ~= "n2o" then
            local stored = storedFuelLevels[tank.name]
            local targetEnergy = stored.relativeFuel * tank.maxEnergy
            core_vehicleBridge.executeAction(vehObj, 'setEnergyStorageEnergy', tank.name, targetEnergy)
          end
        end
      end
      
      -- Calculate and send power/weight after tuning is applied
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
      
      -- Reload wheel data extension after vehicle respawn
      if career_modules_business_businessComputer then
        core_jobsystem.create(function(job)
          job.sleep(0.1)
          career_modules_business_businessComputer.loadWheelDataExtension(businessId, vehicleId)
        end)
      end
    end, 'energyStorage')
  end, 'energyStorage')
  
  return true
end

-- Create shopping cart structure (similar to tuning.lua)
local function createShoppingCart(businessId, vehicleId, changedVars, originalVars)
  if not changedVars or not next(changedVars) then
    return {items = {}, total = 0, taxes = 0}
  end
  
  -- Get tuning data from cache
  local cacheKey = businessId .. "_" .. tostring(vehicleId)
  local tuningData = tuningDataCache[cacheKey]
  if not tuningData then return {items = {}, total = 0, taxes = 0} end
  
  local shoppingCart = {items = {}}
  local total = 0
  
  for varName, value in pairs(changedVars) do
    local varData = tuningData[varName]
    if not varData then goto continue end
    
    -- Check if value actually changed
    local originalValue = originalVars and originalVars[varName]
    if originalValue == nil then
      originalValue = varData.val or varData.min or 0
    end
    
    -- Handle valDis vs val
    if type(originalValue) == "table" and originalValue.valDis then
      originalValue = originalValue.valDis
    end
    
    if math.abs(value - originalValue) < 0.001 then goto continue end
    
    -- Construct the shopping cart and calculate prices for each item
    local varPrice
    if isOnBlackList(varData) then
      varPrice = 0
      -- Add directly to top level (like vanilla tuning.lua)
      -- Format title to include subcategory for clarity
      local displayTitle = varData.title or varName
      if varData.subCategory and varData.subCategory ~= "" and varData.subCategory ~= "Other" then
        displayTitle = varData.subCategory .. " - " .. displayTitle
      end
      
      shoppingCart.items[varName] = {
        name = varName,
        title = displayTitle,
        price = 0
      }
    elseif varData.category then
      -- Add the category to the shopping cart if it's not there yet
      if not shoppingCart.items[varData.category] then
        local price = getPriceCategory(varData.category)
        total = total + price
        shoppingCart.items[varData.category] = {
          type = "category",
          items = {},
          price = price,
          title = varData.category
        }
      end
      
      -- Add the subCategory to the shopping cart if it's not there yet
      if varData.subCategory and not shoppingCart.items[varData.category].items[varData.subCategory] then
        local price = getPriceSubCategory(varData.category, varData.subCategory)
        total = total + price
        shoppingCart.items[varData.category].items[varData.subCategory] = {
          type = "subCategory",
          items = {},
          price = price,
          title = varData.subCategory
        }
      end
      
      if varData.subCategory then
        varPrice = getPrice(varData.category, varData.subCategory, varName)
        shoppingCart.items[varData.category].items[varData.subCategory].items[varName] = {
          name = varName,
          title = varData.title or varName,
          price = varPrice
        }
      else
        varPrice = getPrice(varData.category, varData.subCategory, varName)
        shoppingCart.items[varData.category].items[varName] = {
          name = varName,
          title = varData.title or varName,
          price = varPrice
        }
      end
    else
      varPrice = getPrice(varData.category, varData.subCategory, varName)
      shoppingCart.items[varName] = {
        name = varName,
        title = varData.title or varName,
        price = varPrice
      }
    end
    
    total = total + varPrice
    ::continue::
  end
  
  shoppingCart.taxes = total * 0.07
  shoppingCart.total = total + shoppingCart.taxes
  
  return shoppingCart
end

-- Calculate tuning cost based on shopping cart structure
local function calculateTuningCost(businessId, vehicleId, tuningVars, originalVars)
  if not tuningVars then return 0 end
  
  local shoppingCart = createShoppingCart(businessId, vehicleId, tuningVars, originalVars)
  return math.floor(shoppingCart.total + 0.5)
end

-- Function to apply tuning settings to a business vehicle
local function applyVehicleTuning(businessId, vehicleId, tuningVars, accountId)
  if not businessId or not vehicleId or not tuningVars then
    return false
  end

  local vehicle = career_modules_business_businessInventory.getVehicleById(businessId, vehicleId)
  if not vehicle then
    return false
  end

  -- Get tuning data cache to check which parts variables belong to
  local cacheKey = businessId .. "_" .. tostring(vehicleId)
  local tuningData = tuningDataCache[cacheKey]
  
  -- Get parts tree from vehicle config to check which parts are installed
  local partsTree = nil
  if vehicle.config and vehicle.config.partsTree then
    partsTree = vehicle.config.partsTree
  end

  -- Charge from business account if accountId is provided
  if accountId and career_modules_bank then
    -- Get original vars for cost calculation
    local originalVars = vehicle.vars or {}
    
    local tuningCost = calculateTuningCost(businessId, vehicleId, tuningVars, originalVars)
    if tuningCost > 0 then
      local success = career_modules_bank.payFromAccount({
        money = {
          amount = tuningCost,
          canBeNegative = false
        }
      }, accountId)
      if not success then
        return false
      end
    end
  end

  -- Initialize vars if it doesn't exist
  if not vehicle.vars then
    vehicle.vars = {}
  end

  local varsToApply = {}
  for varName, value in pairs(tuningVars) do
    if tuningData and tuningData[varName] and tuningData[varName]._parts then
      local partsList = tuningData[varName]._parts
      local shouldApply = false
      
      for _, partVarData in ipairs(partsList) do
        local partName = partVarData._partName
        local slotPath = partVarData._slotPath
        
        if partName and slotPath and partsTree then
          local node = getNodeFromSlotPath(partsTree, slotPath)
          if node and node.chosenPartName == partName then
            shouldApply = true
            break
          end
        end
      end
      
      if shouldApply then
        varsToApply[varName] = value
      end
    else
      varsToApply[varName] = value
    end
  end

  local vehicleVarsCurrent = vehicle.vars or {}
  vehicle.vars = tableMerge(vehicleVarsCurrent, varsToApply)

  local pulledOutVehicle = career_modules_business_businessInventory.getPulledOutVehicle(businessId)
  if pulledOutVehicle and pulledOutVehicle.vehicleId == vehicleId then
    if not pulledOutVehicle.vars then
      pulledOutVehicle.vars = {}
    end
    pulledOutVehicle.vars = tableMerge(pulledOutVehicle.vars, vehicle.vars)
    
    if pulledOutVehicle.config then
      if not pulledOutVehicle.config.vars then
        pulledOutVehicle.config.vars = {}
      end
      pulledOutVehicle.config.vars = tableMerge(pulledOutVehicle.config.vars, vehicle.vars)
    end
  end

  local updateData = {
    vars = vehicle.vars
  }
  
  if vehicle.config then
    if not vehicle.config.vars then
      vehicle.config.vars = {}
    end
    vehicle.config.vars = tableMerge(vehicle.config.vars, vehicle.vars)
    updateData.config = vehicle.config
  end
  
  career_modules_business_businessInventory.updateVehicle(businessId, vehicleId, updateData)

  return true
end

-- Clear tuning data cache
local function clearTuningDataCache()
  tuningDataCache = {}
end

-- Get shopping cart structure for UI (flattened like tuning.lua)
local function getShoppingCart(businessId, vehicleId, tuningVars, originalVars)
  local shoppingCart = createShoppingCart(businessId, vehicleId, tuningVars, originalVars)
  
  -- Flatten the hierarchical structure for UI (similar to tuning.lua)
  local shoppingCartUI = {items = {}}
  for name, info in pairs(shoppingCart.items) do
    table.insert(shoppingCartUI.items, {
      varName = info.name or name,
      level = 1,
      title = info.title or name,
      price = info.price or 0,
      type = info.type or "variable"
    })
    for name2, info2 in pairs(info.items or {}) do
      table.insert(shoppingCartUI.items, {
        varName = info2.name or name2,
        level = 2,
        title = info2.title or name2,
        price = info2.price or 0,
        type = info2.type or "variable"
      })
      for name3, info3 in pairs(info2.items or {}) do
        table.insert(shoppingCartUI.items, {
          varName = info3.name or name3,
          level = 3,
          title = info3.title or name3,
          price = info3.price or 0,
          type = "variable"
        })
      end
    end
  end
  
  shoppingCartUI.taxes = shoppingCart.taxes
  shoppingCartUI.total = shoppingCart.total
  
  return shoppingCartUI
end

-- Add tuning changes to cart (similar to addPartToCart pattern)
-- Returns array of tuning cart items with only changed variables
local function addTuningToCart(businessId, vehicleId, currentTuningVars, baselineTuningVars)
  if not businessId or not vehicleId or not currentTuningVars then
    return {}
  end
  
  -- Get baseline vars from initial vehicle state if not provided
  if not baselineTuningVars and career_modules_business_businessPartCustomization then
    local initialVehicle = career_modules_business_businessPartCustomization.getInitialVehicleState(businessId)
    if initialVehicle and initialVehicle.vars then
      baselineTuningVars = initialVehicle.vars
    end
  end
  
  -- If still no baseline, use empty table (all changes from defaults)
  baselineTuningVars = baselineTuningVars or {}
  
  -- Filter to only changed variables (like vanilla tuning.lua does)
  local changedVars = {}
  for varName, currentValue in pairs(currentTuningVars) do
    if currentValue ~= nil then
      local baselineValue = baselineTuningVars[varName]
      -- Check if value actually changed (handle nil baseline as changed)
      if baselineValue == nil or math.abs(currentValue - baselineValue) >= 0.001 then
        changedVars[varName] = currentValue
      end
    end
  end
  
  -- If no changes, return empty array (ensure it's serialized as array, not object)
  if not next(changedVars) then
    return {}
  end
  
  -- Get shopping cart to calculate prices (only for changed variables)
  local shoppingCart = getShoppingCart(businessId, vehicleId, changedVars, baselineTuningVars)
  
  -- Build cart items array with all levels (categories, subcategories, and variables)
  -- Use table.insert to ensure sequential integer keys (serializes as array)
  local cartItems = {}
  for _, item in ipairs(shoppingCart.items or {}) do
    -- Include all items: categories (level 1), subcategories (level 2), and variables (level 1, 2, or 3)
    if item.type == "category" or item.type == "subCategory" then
      -- Add category or subcategory header
      table.insert(cartItems, {
        varName = item.varName or "",
        value = nil,
        originalValue = nil,
        price = item.price or 0,
        title = item.title or item.varName or "",
        level = item.level or 1,
        type = item.type
      })
    elseif item.type == "variable" then
      -- Add variable item
      local varName = item.varName
      local currentValue = changedVars[varName]
      
      if currentValue ~= nil then
        local baselineValue = baselineTuningVars[varName]
        
        -- Get variable title from tuning data cache
        local cacheKey = businessId .. "_" .. tostring(vehicleId)
        local tuningData = tuningDataCache[cacheKey]
        local varTitle = varName
        if tuningData and tuningData[varName] then
          local varData = tuningData[varName]
          if varData.title then
            varTitle = varData.title
          end
          -- Only add subcategory prefix for level 1 or 2 items (not nested under subcategory header)
          -- Level 3 items are already under subcategory headers, so no prefix needed
          local itemLevel = item.level or 1
          if itemLevel < 3 and varData.subCategory and varData.subCategory ~= "Other" and varData.subCategory ~= "" then
            varTitle = varData.subCategory .. " - " .. varTitle
          end
        end
        
        table.insert(cartItems, {
          varName = varName,
          value = currentValue,
          originalValue = baselineValue or 0,
          price = item.price or 0,
          title = varTitle,
          level = item.level or 1,
          type = "variable"
        })
      end
    end
  end
  
  -- Ensure we return an array (even if empty, use table.insert to maintain array structure)
  -- cartItems should already be an array due to table.insert, but return explicitly
  return cartItems
end

-- Exports
M.requestVehicleTuningData = requestVehicleTuningData
M.getVehicleTuningData = getVehicleTuningData
M.applyTuningToVehicle = applyTuningToVehicle
M.calculateTuningCost = calculateTuningCost
M.getShoppingCart = getShoppingCart
M.applyVehicleTuning = applyVehicleTuning
M.clearTuningDataCache = clearTuningDataCache
M.addTuningToCart = addTuningToCart

return M

