local M = {}

M.dependencies = {'career_career', 'core_vehicles', 'core_jobsystem', 'career_modules_bank'}

local tuningDataCache = {}

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

local function getBusinessVehicleObject(businessId, vehicleId)
  if not businessId or not vehicleId then return nil end
  
  if career_modules_business_businessInventory then
    local vehId = career_modules_business_businessInventory.getSpawnedVehicleId(businessId, vehicleId)
    if vehId then
      return getObjectByID(vehId)
    end
  end
  
  return nil
end

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
    
    for varName, varData in pairs(tuningVariables) do
      if not baselineVars[varName] then
        baselineVars[varName] = varData.val
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
        varData.val = varData.default or varData.min or 0
      end
      
      if varData.valDis == nil and varData.val ~= nil then
        if varData.category == "Wheel Alignment" and (varData.unit == '%' or varData.unit == 'percent') then
          local actualMin = varData.min or 0
          local actualMax = varData.max or 100
          local range = actualMax - actualMin
          if range > 0 then
            varData.valDis = ((varData.val - actualMin) / range) * 2 - 1
          else
            varData.valDis = 0
          end
        else
          varData.valDis = varData.val
        end
      end
    end

    tuningDataCache[cacheKey] = tuningVariables

    guihooks.trigger('businessComputer:onVehicleTuningData', {
      success = true,
      businessId = businessId,
      vehicleId = vehicleId,
      tuningData = tuningVariables,
      baselineVars = baselineVars
    })
    
    return
  end)
end


local function getVehicleTuningData(businessId, vehicleId)
  requestVehicleTuningData(businessId, vehicleId)
  return nil
end

local function applyTuningToVehicle(businessId, vehicleId, tuningVars)
  if not businessId or not vehicleId or not tuningVars then
    return false
  end
  
  local vehObj = getBusinessVehicleObject(businessId, vehicleId)
  if not vehObj then return false end
  
  if not career_modules_business_businessPartCustomization then
    return false
  end
  
  local currentConfig = career_modules_business_businessPartCustomization.getPreviewVehicleConfig(businessId)
  if not currentConfig then
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
  
  local vehicle = career_modules_business_businessInventory.getVehicleById(businessId, vehicleId)
  if not vehicle or not vehicle.vehicleConfig then return false end
  local modelKey = vehicle.vehicleConfig.model_key or vehicle.model_key
  if not modelKey then return false end
  
  local updatedConfig = deepcopy(currentConfig)
  if not updatedConfig.vars then
    updatedConfig.vars = {}
  end
  
  updatedConfig.vars = tableMerge(deepcopy(updatedConfig.vars), tuningVars)
  
  local vehId = vehObj:getID()
  
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

local function createShoppingCart(businessId, vehicleId, changedVars, originalVars)
  if not changedVars or not next(changedVars) then
    return {items = {}, total = 0, taxes = 0}
  end
  
  local cacheKey = businessId .. "_" .. tostring(vehicleId)
  local tuningData = tuningDataCache[cacheKey]
  if not tuningData then return {items = {}, total = 0, taxes = 0} end
  
  local shoppingCart = {items = {}}
  local total = 0
  
  for varName, value in pairs(changedVars) do
    local varData = tuningData[varName]
    if not varData then goto continue end
    
    local originalValue = originalVars and originalVars[varName]
    if originalValue == nil then
      originalValue = varData.val or varData.default or varData.min or 0
    end
    
    if type(originalValue) == "table" and originalValue.valDis then
      originalValue = originalValue.valDis
    end
    
    if math.abs(value - originalValue) < 0.001 then goto continue end
    
    local varPrice
    if isOnBlackList(varData) then
      varPrice = 0
      local displayTitle = string.format("%s %s %s", varData.category or "", varData.subCategory or "", varData.title or varName)
      shoppingCart.items[varName] = {
        name = varName,
        title = displayTitle,
        price = 0
      }
    elseif varData.category then
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

local function calculateTuningCost(businessId, vehicleId, tuningVars, originalVars)
  if not tuningVars then return 0 end
  
  local shoppingCart = createShoppingCart(businessId, vehicleId, tuningVars, originalVars)
  return math.floor(shoppingCart.total + 0.5)
end

local function applyVehicleTuning(businessId, vehicleId, tuningVars, accountId)
  if not businessId or not vehicleId or not tuningVars then
    return false
  end

  local vehicle = career_modules_business_businessInventory.getVehicleById(businessId, vehicleId)
  if not vehicle then
    return false
  end

  if accountId and career_modules_bank then
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

  if not vehicle.vars then
    vehicle.vars = {}
  end

  local vehicleVarsCurrent = vehicle.vars or {}
  vehicle.vars = tableMerge(vehicleVarsCurrent, tuningVars)

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

local function clearTuningDataCache()
  tuningDataCache = {}
end

local function getShoppingCart(businessId, vehicleId, tuningVars, originalVars)
  local shoppingCart = createShoppingCart(businessId, vehicleId, tuningVars, originalVars)
  
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

local function addTuningToCart(businessId, vehicleId, currentTuningVars, baselineTuningVars)
  if not businessId or not vehicleId or not currentTuningVars then
    return {}
  end
  
  if not baselineTuningVars and career_modules_business_businessPartCustomization then
    local initialVehicle = career_modules_business_businessPartCustomization.getInitialVehicleState(businessId)
    if initialVehicle and initialVehicle.vars then
      baselineTuningVars = initialVehicle.vars
    end
  end
  
  baselineTuningVars = baselineTuningVars or {}
  
  local changedVars = {}
  for varName, currentValue in pairs(currentTuningVars) do
    if currentValue ~= nil then
      local baselineValue = baselineTuningVars[varName]
      if baselineValue == nil or math.abs(currentValue - baselineValue) >= 0.001 then
        changedVars[varName] = currentValue
      end
    end
  end
  
  if not next(changedVars) then
    return {}
  end
  
  local shoppingCart = getShoppingCart(businessId, vehicleId, changedVars, baselineTuningVars)
  
  local cartItems = {}
  for _, item in ipairs(shoppingCart.items or {}) do
    if item.type == "category" or item.type == "subCategory" then
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
      local varName = item.varName
      local currentValue = changedVars[varName]
      
      if currentValue ~= nil then
        local baselineValue = baselineTuningVars[varName]
        
        local cacheKey = businessId .. "_" .. tostring(vehicleId)
        local tuningData = tuningDataCache[cacheKey]
        local varTitle = varName
        if tuningData and tuningData[varName] then
          local varData = tuningData[varName]
          if varData.title then
            varTitle = varData.title
          end
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
  
  return cartItems
end

M.requestVehicleTuningData = requestVehicleTuningData
M.getVehicleTuningData = getVehicleTuningData
M.applyTuningToVehicle = applyTuningToVehicle
M.calculateTuningCost = calculateTuningCost
M.getShoppingCart = getShoppingCart
M.applyVehicleTuning = applyVehicleTuning
M.clearTuningDataCache = clearTuningDataCache
M.addTuningToCart = addTuningToCart

return M


