local M = {}

M.dependencies = {'career_career', 'core_vehicles', 'core_jobsystem', 'career_modules_bank'}

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
  return 0
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

  -- Check cache first
  local cacheKey = businessId .. "_" .. tostring(vehicleId)
  if tuningDataCache[cacheKey] then
    -- Return cached data immediately
    guihooks.trigger('businessComputer:onVehicleTuningData', {
      success = true,
      businessId = businessId,
      vehicleId = vehicleId,
      tuningData = tuningDataCache[cacheKey]
    })
    return
  end

  -- Run async to avoid blocking
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

    -- Spawn vehicle temporarily to get tuning data
    local vehicleObj = core_vehicles.spawnNewVehicle(modelKey, {
      config = configKey,
      pos = vec3(0, 0, -1000), -- Spawn far away
      rot = quat(0, 0, 0, 1),
      keepLoaded = true,
      autoEnterVehicle = false
    })

    if not vehicleObj then
      guihooks.trigger('businessComputer:onVehicleTuningData', {
        success = false,
        error = "Failed to spawn vehicle"
      })
      return
    end

    local vehId = vehicleObj:getID()

    -- Get vehicle data and tuning variables
    local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehId)
    if not vehicleData or not vehicleData.vdata or not vehicleData.vdata.variables then
      -- Clean up spawned vehicle
      if vehicleObj then
        vehicleObj:delete()
      end
      guihooks.trigger('businessComputer:onVehicleTuningData', {
        success = false,
        error = "No tuning variables found"
      })
      return
    end

    -- Get current vars from vehicle config (if any)
    local currentVars = vehicle.vars or {}

    -- Get all available tuning variables
    local tuningVariables = deepcopy(vehicleData.vdata.variables)

    -- Merge current vars with defaults and calculate display values
    for varName, varData in pairs(tuningVariables) do
      -- Use current var value if it exists, otherwise use the default val from the variable definition
      if currentVars[varName] ~= nil then
        varData.val = currentVars[varName]
      elseif varData.val == nil then
        -- If no val is set, use min as baseline (or 0 if min is nil)
        varData.val = varData.min or 0
      end

      -- Calculate display values (valDis, minDis, maxDis, stepDis)
      -- These are typically the same as val/min/max/step unless there's a conversion factor
      varData.valDis = varData.val or (varData.min or 0)
      varData.minDis = varData.min or 0
      varData.maxDis = varData.max or 100
      -- Use step if available, otherwise calculate a reasonable default based on range
      if varData.step and varData.step > 0 then
        varData.stepDis = varData.step
      else
        -- Calculate step as 1/1000th of the range, but ensure it's at least 0.001
        local range = math.abs((varData.max or 100) - (varData.min or 0))
        varData.stepDis = math.max(0.001, math.min(1, range / 1000))
      end

      -- Ensure valDis is within bounds
      if varData.valDis < varData.minDis then
        varData.valDis = varData.minDis
      elseif varData.valDis > varData.maxDis then
        varData.valDis = varData.maxDis
      end
    end

    -- Clean up spawned vehicle
    if vehicleObj then
      vehicleObj:delete()
    end

    -- Cache the data
    tuningDataCache[cacheKey] = tuningVariables

    -- Trigger hook with data
    guihooks.trigger('businessComputer:onVehicleTuningData', {
      success = true,
      businessId = businessId,
      vehicleId = vehicleId,
      tuningData = tuningVariables
    })
  end)
end

-- Legacy function for backward compatibility (now uses hook internally)
local function getVehicleTuningData(businessId, vehicleId)
  requestVehicleTuningData(businessId, vehicleId)
  return nil -- Return nil since data comes via hook
end

-- Function to apply tuning visually to preview vehicle
local function applyTuningToVehicle(businessId, vehicleId, tuningVars)
  if not businessId or not vehicleId or not tuningVars then
    return false
  end
  
  local vehObj = getBusinessVehicleObject(businessId, vehicleId)
  if not vehObj then return false end
  
  local vehId = vehObj:getID()
  
  -- Apply tuning variables to vehicle
  for varName, value in pairs(tuningVars) do
    core_vehicleBridge.executeAction(vehObj, 'setVar', varName, value)
  end
  
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
      shoppingCart.items[varName] = {
        name = varName,
        title = string.format("%s %s %s", varData.category or "", varData.subCategory or "", varData.title or varName),
        price = 0
      }
      varPrice = 0
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

  -- Merge new tuning vars with existing ones
  for varName, value in pairs(tuningVars) do
    vehicle.vars[varName] = value
  end

  -- Update pulled out vehicle if it's the same one
  local pulledOutVehicle = career_modules_business_businessInventory.getPulledOutVehicle(businessId)
  if pulledOutVehicle and pulledOutVehicle.vehicleId == vehicleId then
    pulledOutVehicle.vars = vehicle.vars
  end

  -- Save the updated vehicle data
  career_modules_business_businessInventory.updateVehicle(businessId, vehicleId, {
    vars = vehicle.vars
  })

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

-- Exports
M.requestVehicleTuningData = requestVehicleTuningData
M.getVehicleTuningData = getVehicleTuningData
M.applyTuningToVehicle = applyTuningToVehicle
M.calculateTuningCost = calculateTuningCost
M.getShoppingCart = getShoppingCart
M.applyVehicleTuning = applyVehicleTuning
M.clearTuningDataCache = clearTuningDataCache

return M

