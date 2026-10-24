-- Business vehicle tuning, cart pricing and charges for customer and personal vehicles.
-- Read prices, vehicle lookup, cart pricing, tuning payloads, applying a tune, cart rows, then the public API.
local capabilities = require("overhaul/lib/platform/capabilities")
local M = {}
local customizationAccess = require('overhaul/lib/business/customizationAccess')

-- Prices and blacklist ----------------------------------------------------------------------------

local prices = {
  Suspension = {Front = {price = 100}, Rear = {price = 100}},
  Wheels = {Front = {price = 100}, Rear = {price = 100}},
  Transmission = {
    price = 500,
    default = {
      default = true,
      variables = {
        ["$gear_1"] = {price = 100},
        ["$gear_2"] = {price = 100},
        ["$gear_3"] = {price = 100},
        ["$gear_4"] = {price = 100},
        ["$gear_5"] = {price = 100},
        ["$gear_6"] = {price = 100},
        ["$gear_R"] = {price = 100},
      },
    },
  },
  ["Wheel Alignment"] = {Front = {price = 100}, Rear = {price = 100}},
  Chassis = {price = 100},
  default = {default = true, price = 200},
}

-- Tunes that are shown but never charged.
local shoppingCartBlackList = {
  {name = "$$ffbstrength", category = "Chassis"},
  {name = "$tirepressure_F", category = "Wheels", subCategory = "Front"},
  {name = "$tirepressure_R", category = "Wheels", subCategory = "Rear"},
}

local function isOnBlackList(varData)
  for _, blackListItem in ipairs(shoppingCartBlackList) do
    if blackListItem.name == varData.name
      and blackListItem.category == varData.category
      and blackListItem.subCategory == varData.subCategory then
      return true
    end
  end
  return false
end

local function getPriceCategory(category)
  if prices[category] then
    return prices[category].price or prices.default.price
  end
  return prices.default.price
end

-- Each owned cheap-tunes level takes 20% off the cart.
local function getCheapTunesDiscountMultiplier(businessId)
  if not businessId then return 1.0 end
  local level = overhaul_career_business_skillTree.getNodeProgress(businessId, "shop-upgrades", "cheap-tunes") or 0
  return math.max(0.0, 1.0 - (0.2 * level))
end

-- Vehicle lookup ----------------------------------------------------------------------------------

-- Personal vehicles are named "personal_<spawnedId>" by the computer.
local function isPersonalVehicleId(vehicleId)
  if not vehicleId then return false end
  return tostring(vehicleId):sub(1, 9) == "personal_"
end

local function getSpawnedIdFromPersonalVehicleId(vehicleId)
  if not isPersonalVehicleId(vehicleId) then return nil end
  return tonumber(tostring(vehicleId):sub(10))
end

-- Searches purchased businesses for their active personal vehicle with this id; `accepts` filters the match.
local function findActivePersonalVehicle(vehicleId, businessId, accepts)
  local allBusinessObjects = overhaul_career_business_manager and overhaul_career_business_manager.getAllBusinessObjects
    and overhaul_career_business_manager.getAllBusinessObjects() or {}
  for businessType, businessObj in pairs(allBusinessObjects) do
    if businessObj.getActivePersonalVehicle then
      local purchased = overhaul_career_business_manager.getPurchasedBusinesses(businessType) or {}
      if purchased[businessId] then
        local activePersonal = businessObj.getActivePersonalVehicle(businessId)
        if activePersonal and tostring(activePersonal.vehicleId) == tostring(vehicleId) and accepts(activePersonal) then
          return activePersonal
        end
      end
    end
  end
  return nil
end

local function hasInventoryId(activePersonal)
  return activePersonal.inventoryId
end

local function acceptAnyPersonal()
  return true
end

local function getInventoryIdFromPersonalVehicleId(vehicleId, businessId)
  if not isPersonalVehicleId(vehicleId) or not businessId then return nil end
  local activePersonal = findActivePersonalVehicle(vehicleId, businessId, hasInventoryId)
  return activePersonal and activePersonal.inventoryId or nil
end

local function getPersonalVehicleData(vehicleId, businessId)
  if not isPersonalVehicleId(vehicleId) or not businessId then return nil end
  return findActivePersonalVehicle(vehicleId, businessId, acceptAnyPersonal)
end

local function getBusinessVehicleObject(businessId, vehicleId)
  if not businessId or not vehicleId then return nil end

  if isPersonalVehicleId(vehicleId) then
    local spawnedId = getSpawnedIdFromPersonalVehicleId(vehicleId)
    if spawnedId then return getObjectByID(spawnedId) end
    return nil
  end

  if overhaul_career_business_fleet then
    local vehId = overhaul_career_business_fleet.getSpawnedVehicleId(businessId, vehicleId)
    if vehId then return getObjectByID(vehId) end
  end
  return nil
end

-- The stored record for a fleet or personal vehicle.
local function findVehicleRecord(businessId, vehicleId)
  if isPersonalVehicleId(vehicleId) then
    return getPersonalVehicleData(vehicleId, businessId)
  end
  return overhaul_career_business_fleet.getVehicleById(businessId, vehicleId)
end

local function fetchVehicleTuningVariables(businessId, vehicleId)
  local vehObj = getBusinessVehicleObject(businessId, vehicleId)
  if not vehObj then return nil end

  local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehObj:getID())
  if not vehicleData or not vehicleData.vdata or not vehicleData.vdata.variables then return nil end
  return deepcopy(vehicleData.vdata.variables)
end

-- Cart pricing ------------------------------------------------------------------------------------

-- The value a change is measured against: the saved original, else the variable's own value, default or minimum.
local function originalValueOf(varName, varData, originalVars)
  local originalValue = originalVars and originalVars[varName]
  if originalValue == nil then
    originalValue = varData.val or varData.default or varData.min or 0
  end
  if type(originalValue) == "table" then originalValue = originalValue.val end
  return tonumber(originalValue) or 0
end

local function isValueChanged(varName, varData, value, originalVars)
  local originalValue = originalValueOf(varName, varData, originalVars)
  if math.abs(value - originalValue) < 0.000001 then return false end
  return true
end

local function blacklistedCartItem(varName, varData)
  local displayTitle = string.format("%s %s %s", varData.category or "", varData.subCategory or "", varData.title or varName)
  return {name = varName, title = displayTitle, price = 0}
end

-- Adds the category row the first time it is seen; returns the price that adds to the total.
local function ensureCategoryRow(cartItems, category)
  if cartItems[category] then return 0 end
  local price = getPriceCategory(category)
  cartItems[category] = {type = "category", items = {}, price = price, visualPrice = price, title = category}
  return price
end

-- Files a variable under its category (and subcategory when it has one); returns the price its category adds.
local function addVariableUnderCategory(cartItems, categoryName, subCategoryName, varName, varData)
  local addedPrice = ensureCategoryRow(cartItems, categoryName)
  local categoryRow = cartItems[categoryName]
  local leaf = {name = varName, title = varData.title or varName, price = 0}
  if not subCategoryName then
    categoryRow.items[varName] = leaf
    return addedPrice
  end
  if not categoryRow.items[subCategoryName] then
    categoryRow.items[subCategoryName] = {type = "subCategory", items = {}, price = 0, title = subCategoryName}
  end
  categoryRow.items[subCategoryName].items[varName] = leaf
  return addedPrice
end

-- Adds one changed variable to the cart and returns the price it added.
local function addVariableToCart(cartItems, varName, varData)
  if isOnBlackList(varData) then
    cartItems[varName] = blacklistedCartItem(varName, varData)
    return 0
  end
  if varData.category then
    return addVariableUnderCategory(cartItems, varData.category, varData.subCategory, varName, varData)
  end
  return addVariableUnderCategory(cartItems, "Other", nil, varName, varData)
end

local function createShoppingCart(businessId, vehicleId, changedVars, originalVars)
  if not changedVars or not next(changedVars) then
    return {items = {}, total = 0, taxes = 0}
  end

  -- without tuning data (car not spawned) the change cannot be priced
  local tuningData = fetchVehicleTuningVariables(businessId, vehicleId)
  if not tuningData then return nil end

  local shoppingCart = {items = {}}
  local total = 0
  for varName, value in pairs(changedVars) do
    local varData = tuningData[varName]
    if varData then
      value = tonumber(value)
      if not value then return nil end
      if isValueChanged(varName, varData, value, originalVars) then
        total = total + addVariableToCart(shoppingCart.items, varName, varData)
      end
    end
  end

  shoppingCart.taxes = total * 0.07
  shoppingCart.total = total + shoppingCart.taxes
  return shoppingCart
end

local function calculateTuningCost(businessId, vehicleId, tuningVars, originalVars)
  if not tuningVars then return 0 end

  local shoppingCart = createShoppingCart(businessId, vehicleId, tuningVars, originalVars)
  if not shoppingCart then return nil end
  local discountedTotal = shoppingCart.total * getCheapTunesDiscountMultiplier(businessId)
  return math.floor(discountedTotal + 0.5)
end

-- One row for the computer's cart list; `level` is the tree depth (1 category, 2 subcategory or variable, 3 variable under a subcategory).
local function cartUiRow(name, entry, level, rowType)
  return {
    varName = entry.name or name,
    level = level,
    title = entry.title or name,
    price = entry.price or 0,
    type = rowType or entry.type or "variable",
  }
end

local function getShoppingCart(businessId, vehicleId, tuningVars, originalVars)
  local shoppingCart = createShoppingCart(businessId, vehicleId, tuningVars, originalVars) or {items = {}, total = 0, taxes = 0}

  local rows = {}
  for name, info in pairs(shoppingCart.items) do
    table.insert(rows, cartUiRow(name, info, 1))
    for name2, info2 in pairs(info.items or {}) do
      table.insert(rows, cartUiRow(name2, info2, 2))
      for name3, info3 in pairs(info2.items or {}) do
        table.insert(rows, cartUiRow(name3, info3, 3, "variable"))
      end
    end
  end

  return {items = rows, taxes = shoppingCart.taxes, total = shoppingCart.total}
end

-- Tuning data for the computer --------------------------------------------------------------------

local function sendTuningDataError(message)
  guihooks.trigger('businessComputer:onVehicleTuningData', {success = false, error = message})
end

-- Fuel fill is not a paid tune, and cargo is not a tune at all: neither is shown.
local function isHiddenTuningVariable(varName, varData)
  if type(varName) == "string" and varName:sub(1, 5) == "$fuel" then return true end
  return varData.category == "Cargo"
end

local function readBaselineVars(businessId)
  local initialVehicle = overhaul_career_business_partCustomization.getInitialVehicleState(businessId)
  if initialVehicle and initialVehicle.vars then return initialVehicle.vars end
  return {}
end

-- A personal vehicle's garage config wins over its own vars when it has one.
local function readCurrentVars(vehicle, isPersonal)
  local currentVars = vehicle.vars or {}
  if isPersonal and vehicle.inventoryId then
    local inventoryVehicles = overhaul_career_garage_inventory.getVehicles()
    local invVeh = inventoryVehicles and inventoryVehicles[vehicle.inventoryId]
    if invVeh and invVeh.config and invVeh.config.vars then currentVars = invVeh.config.vars end
  end
  return currentVars
end

local function fillMissingBaselines(baselineVars, tuningVariables)
  for varName, varData in pairs(tuningVariables) do
    if not baselineVars[varName] then
      baselineVars[varName] = varData.val
    end
  end
end

local function removeHiddenTuningVariables(tuningVariables)
  for varName, varData in pairs(tuningVariables) do
    if isHiddenTuningVariable(varName, varData) then
      tuningVariables[varName] = nil
    end
  end
end

-- Shows the saved baseline, else the vehicle's current value, else the variable's default.
local function settleDisplayValues(tuningVariables, baselineVars, currentVars)
  for varName, varData in pairs(tuningVariables) do
    if baselineVars[varName] ~= nil then
      varData.val = baselineVars[varName]
    elseif currentVars[varName] ~= nil then
      varData.val = currentVars[varName]
    elseif varData.val == nil then
      varData.val = varData.default or varData.min or 0
    end

    if varData.valDis == nil and varData.val ~= nil then
      varData.valDis = varData.val
    end
  end
end

-- The payload for the computer, or nil and the reason the vehicle cannot be tuned.
local function buildTuningPayload(businessId, vehicleId, isPersonal)
  local vehicle = findVehicleRecord(businessId, vehicleId)
  if not vehicle or not vehicle.vehicleConfig then return nil, "Vehicle not found" end

  local modelKey = vehicle.vehicleConfig.model_key or vehicle.model_key
  local configKey = vehicle.vehicleConfig.key or vehicle.config_key
  if not modelKey or not configKey then return nil, "Invalid vehicle config" end

  local vehicleObj = getBusinessVehicleObject(businessId, vehicleId)
  if not vehicleObj then return nil, "Preview vehicle not found" end

  local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehicleObj:getID())
  if not vehicleData or not vehicleData.vdata or not vehicleData.vdata.variables then
    return nil, "No tuning variables found"
  end

  local baselineVars = readBaselineVars(businessId)
  local currentVars = readCurrentVars(vehicle, isPersonal)
  local tuningVariables = deepcopy(vehicleData.vdata.variables)
  fillMissingBaselines(baselineVars, tuningVariables)
  removeHiddenTuningVariables(tuningVariables)
  settleDisplayValues(tuningVariables, baselineVars, currentVars)

  return {
    success = true,
    businessId = businessId,
    vehicleId = vehicleId,
    tuningData = tuningVariables,
    baselineVars = baselineVars,
  }
end

local function requestVehicleTuningData(businessId, vehicleId)
  if not businessId or not vehicleId then
    sendTuningDataError("Missing parameters")
    return
  end

  local repairReason = customizationAccess.getRepairReason(businessId, vehicleId)
  if repairReason then sendTuningDataError(repairReason.label); return false end

  local isPersonal = isPersonalVehicleId(vehicleId)
  if not findVehicleRecord(businessId, vehicleId) then
    sendTuningDataError("Vehicle not found")
    return
  end

  core_jobsystem.create(function()
    local payload, errorMessage = buildTuningPayload(businessId, vehicleId, isPersonal)
    if not payload then
      sendTuningDataError(errorMessage)
      return
    end
    guihooks.trigger('businessComputer:onVehicleTuningData', payload)
  end)
end

local function getVehicleTuningData(businessId, vehicleId)
  requestVehicleTuningData(businessId, vehicleId)
  return nil
end

-- Applying a tune --------------------------------------------------------------------------------

-- The preview config, starting a preview vehicle first when there is none yet.
local function ensurePreviewConfig(businessId, vehicleId)
  local currentConfig = overhaul_career_business_partCustomization.getPreviewVehicleConfig(businessId)
  if currentConfig then return currentConfig end
  if not overhaul_career_business_partCustomization.initializePreviewVehicle(businessId, vehicleId) then return nil end
  return overhaul_career_business_partCustomization.getPreviewVehicleConfig(businessId)
end

-- Remembers each tank's fill as a fraction, so the respawned vehicle is topped up to the same level.
local function captureFuelLevels(tankData)
  local storedFuelLevels = {}
  if tankData and tankData[1] then
    for _, tank in ipairs(tankData[1]) do
      if tank.energyType ~= "n2o" then
        storedFuelLevels[tank.name] = {
          currentEnergy = tank.currentEnergy,
          maxEnergy = tank.maxEnergy,
          energyType = tank.energyType,
          relativeFuel = tank.maxEnergy > 0 and (tank.currentEnergy / tank.maxEnergy) or 0,
        }
      end
    end
  end
  return storedFuelLevels
end

local function restoreFuelLevels(vehObj, storedFuelLevels, newData)
  if not (storedFuelLevels and next(storedFuelLevels) and newData and newData[1]) then return end
  for _, tank in ipairs(newData[1]) do
    if tank.name and storedFuelLevels[tank.name] and tank.energyType ~= "n2o" then
      local targetEnergy = storedFuelLevels[tank.name].relativeFuel * tank.maxEnergy
      core_vehicleBridge.executeAction(vehObj, 'setEnergyStorageEnergy', tank.name, targetEnergy)
    end
  end
end

-- Respawns the vehicle with the tuned config in place, starting with the engine off.
local function respawnWithConfig(vehObj, vehId, modelKey, config)
  core_vehicle_manager.queueAdditionalVehicleData({spawnWithEngineRunning = false}, vehId)
  core_vehicles.replaceVehicle(modelKey, {config = config, keepOtherVehRotation = true}, vehObj)
end

-- Refreshes the torque and power-to-weight readouts once the respawned vehicle has settled.
local function refreshTuningReadouts(businessId, vehicleId, vehObj, canContinue)
  if canContinue and not canContinue() then return end
  vehObj:queueLuaCommand("controller.mainController.sendTorqueData()")
  core_jobsystem.create(function(job)
    job.sleep(0.1)
    if canContinue and not canContinue() then return end
    capabilities.get("businessComputer").loadWheelDataExtension(businessId, vehicleId)
    job.sleep(0.05)
    if canContinue and not canContinue() then return end
    overhaul_career_business_partCustomization.invalidateAndRequestVehiclePowerWeight(businessId, vehicleId)
  end)
end

local function applyTuningToVehicle(businessId, vehicleId, tuningVars, onComplete, transaction)
  if not businessId or not vehicleId or not tuningVars then return false end
  if not customizationAccess.allow(businessId, vehicleId) then return false end

  local vehObj = getBusinessVehicleObject(businessId, vehicleId)
  if not vehObj then return false end

  local currentConfig = ensurePreviewConfig(businessId, vehicleId)
  if not currentConfig then return false end

  local vehicle = findVehicleRecord(businessId, vehicleId)
  if not vehicle or not vehicle.vehicleConfig then return false end
  local modelKey = vehicle.vehicleConfig.model_key or vehicle.model_key
  if not modelKey then return false end

  local updatedConfig = deepcopy(currentConfig)
  updatedConfig.vars = tableMerge(deepcopy(updatedConfig.vars or {}), tuningVars)
  overhaul_career_business_partCustomization.updatePreviewVehicleConfig(businessId, updatedConfig)

  if transaction and transaction.ownedBuild then
    transaction.captureState()
    transaction.replaceTuning(vehObj, modelKey, updatedConfig, transaction.guard(function()
      local data = extensions.core_vehicle_manager.getVehicleData(vehObj:getID())
      for name, value in pairs(tuningVars) do
        assert(data and data.config and data.config.vars and data.config.vars[name] == value, 'Tuning value did not apply: ' .. name)
      end
      transaction.vehicleCommand(vehObj, 'assert(controller.mainController.sendTorqueData() ~= false,"Torque readout refused")', transaction.guard(function()
        core_jobsystem.create(transaction.guard(function(job)
          job.sleep(0.1)
          if not transaction.isCurrent() then return end
          capabilities.get("businessComputer").loadWheelDataExtension(businessId, vehicleId)
          job.sleep(0.05)
          if not transaction.isCurrent() then return end
          overhaul_career_business_partCustomization.invalidateAndRequestVehiclePowerWeight(businessId, vehicleId)
          onComplete(true)
        end))
      end))
    end))
    return true
  end

  local vehId = vehObj:getID()
  local previewOwner = overhaul_career_business_partCustomization
  local function canContinue()
    return overhaul_career_business_partCustomization == previewOwner
      and previewOwner.getPreviewVehicleConfig(businessId) == updatedConfig
  end
  previewOwner.capturePreviewConditions(businessId, vehicleId, function(ready)
    if not ready or not canContinue() then return end
  core_vehicleBridge.requestValue(vehObj, function(data)
    if not canContinue() then return end
    local storedFuelLevels = captureFuelLevels(data)
    respawnWithConfig(vehObj, vehId, modelKey, updatedConfig)
    previewOwner.applyPreviewConditions(businessId, vehicleId, vehObj, updatedConfig)
    core_vehicleBridge.requestValue(vehObj, function(newData)
      if not canContinue() then return end
      restoreFuelLevels(vehObj, storedFuelLevels, newData)
      refreshTuningReadouts(businessId, vehicleId, vehObj, canContinue)
    end, 'energyStorage')
  end, 'energyStorage')
  end)

  return true
end

-- Charges the bank account for the tune; returns false when the charge is refused.
local function chargeForTuning(businessId, vehicleId, tuningVars, accountId, vehicle)
  local initial = overhaul_career_business_partCustomization.getInitialVehicleState(businessId)
  if not initial or tostring(initial.vehicleId) ~= tostring(vehicleId) then return false end
  local tuningCost = calculateTuningCost(businessId, vehicleId, tuningVars, initial.vars)
  if not tuningCost then return false end
  if tuningCost <= 0 then return true end

  local checkout = require("overhaul/lib/checkout/operations")
  local operation = checkout.begin("businessTuning", {
    amount = tuningCost,
    payer = checkout.business(businessId, accountId),
    target = {vehicleId = vehicleId},
  })
  return checkout.settle(operation, function()
    return checkout.money.execute(overhaul_career_economy_bank.payFromAccount, {
      money = {amount = tuningCost, canBeNegative = false},
    }, accountId, "Tuning Service", "Parts and labor", {category = "purchase"})
  end) and true or false
end

-- A personal vehicle's tune is also written to its garage inventory record.
local function storeTuneOnInventoryVehicle(vehicleId, businessId, tuningVars)
  local inventoryId = getInventoryIdFromPersonalVehicleId(vehicleId, businessId)
  if not inventoryId then return end
  local inventoryVehicles = overhaul_career_garage_inventory.getVehicles()
  local inventoryVehicle = inventoryVehicles and inventoryVehicles[inventoryId]
  if not inventoryVehicle then return end
  inventoryVehicle.config = inventoryVehicle.config or {}
  inventoryVehicle.config.vars = tableMerge(inventoryVehicle.config.vars or {}, tuningVars)
  overhaul_career_garage_inventory.setVehicleDirty(inventoryId)
end

-- A fleet vehicle's tune is written to its record, to the copy out on the lot, and to the record's config.
local function storeTuneOnFleetVehicle(businessId, vehicleId, vehicle)
  local pulledOutVehicle = overhaul_career_business_fleet.getActiveVehicle(businessId)
  if pulledOutVehicle and tostring(pulledOutVehicle.vehicleId) == tostring(vehicleId) then
    pulledOutVehicle.vars = tableMerge(pulledOutVehicle.vars or {}, vehicle.vars)
    if pulledOutVehicle.config then
      pulledOutVehicle.config.vars = tableMerge(pulledOutVehicle.config.vars or {}, vehicle.vars)
    end
  end

  local updateData = {vars = vehicle.vars}
  if vehicle.config then
    vehicle.config.vars = tableMerge(vehicle.config.vars or {}, vehicle.vars)
    updateData.config = vehicle.config
  end
  overhaul_career_business_fleet.updateVehicle(businessId, vehicleId, updateData)
end

local function applyVehicleTuning(businessId, vehicleId, tuningVars, accountId)
  if not businessId or not vehicleId or not tuningVars then return false end
  if not customizationAccess.allow(businessId, vehicleId) then return false end

  local isPersonal = isPersonalVehicleId(vehicleId)
  local vehicle = findVehicleRecord(businessId, vehicleId)
  if not vehicle then return false end

  if accountId and not chargeForTuning(businessId, vehicleId, tuningVars, accountId, vehicle) then
    return false
  end

  vehicle.vars = tableMerge(vehicle.vars or {}, tuningVars)
  if isPersonal then
    storeTuneOnInventoryVehicle(vehicleId, businessId, tuningVars)
  else
    storeTuneOnFleetVehicle(businessId, vehicleId, vehicle)
  end
  overhaul_career_business_partCustomization.commitSessionTuning(businessId, vehicleId, tuningVars)

  extensions.hook("onOverhaulBusinessVehicleConfigurationChanged", businessId, vehicleId, "tuning")
  return true
end

-- Cart rows for the computer ----------------------------------------------------------------------

-- The baseline the cart compares against: the caller's, else the initial vehicle's saved vars.
local function resolveBaselineVars(businessId, baselineTuningVars)
  if baselineTuningVars then return baselineTuningVars end
  local initialVehicle = overhaul_career_business_partCustomization.getInitialVehicleState(businessId)
  if initialVehicle and initialVehicle.vars then return initialVehicle.vars end
  return {}
end

-- Keeps the variables that moved by at least 0.001 from their baseline (or have none).
local function changedTuningVars(currentTuningVars, baselineTuningVars)
  local changedVars = {}
  for varName, currentValue in pairs(currentTuningVars) do
    if currentValue ~= nil then
      local baselineValue = baselineTuningVars[varName]
      if baselineValue == nil or math.abs(currentValue - baselineValue) >= 0.001 then
        changedVars[varName] = currentValue
      end
    end
  end
  return changedVars
end

-- Category and subcategory rows carry the priced service; variables are informational.
local function categoryCartRow(item)
  return {
    varName = item.varName or "",
    price = item.price or 0,
    visualPrice = item.visualPrice,
    title = item.title or item.varName or "",
    level = item.level or 1,
    type = item.type,
  }
end

local function variableCartTitle(varName, level, tuningData)
  local varTitle = varName
  local varData = tuningData and tuningData[varName]
  if varData then
    if varData.title then varTitle = varData.title end
    if level < 3 and varData.subCategory and varData.subCategory ~= "Other" and varData.subCategory ~= "" then
      varTitle = varData.subCategory .. " - " .. varTitle
    end
  end
  return varTitle
end

local function variableCartRow(item, changedVars, baselineTuningVars, tuningData)
  local varName = item.varName
  local currentValue = changedVars[varName]
  if currentValue == nil then return nil end
  local level = item.level or 1
  return {
    varName = varName,
    value = currentValue,
    originalValue = baselineTuningVars[varName] or 0,
    price = item.price or 0,
    title = variableCartTitle(varName, level, tuningData),
    level = level,
    type = "variable",
  }
end

local function cartRowsFor(shoppingItems, changedVars, baselineTuningVars, tuningData)
  local cartItems = {}
  for _, item in ipairs(shoppingItems or {}) do
    if item.type == "category" or item.type == "subCategory" then
      table.insert(cartItems, categoryCartRow(item))
    elseif item.type == "variable" then
      local row = variableCartRow(item, changedVars, baselineTuningVars, tuningData)
      if row then table.insert(cartItems, row) end
    end
  end
  return cartItems
end

-- Shows the cheap-tunes discount on the rows the way checkout will charge it.
local function applyCartDiscount(cartItems, businessId)
  local discountMultiplier = getCheapTunesDiscountMultiplier(businessId)
  if discountMultiplier == 1 then return end
  for _, item in ipairs(cartItems) do
    if item.price and item.price > 0 then
      item.price = math.floor(item.price * discountMultiplier + 0.5)
    end
    if item.visualPrice and item.visualPrice > 0 then
      item.visualPrice = math.floor(item.visualPrice * discountMultiplier + 0.5)
    end
  end
end

local function addTuningToCart(businessId, vehicleId, currentTuningVars, baselineTuningVars)
  if not businessId or not vehicleId or not currentTuningVars then return {} end

  baselineTuningVars = resolveBaselineVars(businessId, baselineTuningVars)
  local changedVars = changedTuningVars(currentTuningVars, baselineTuningVars)
  if not next(changedVars) then return {} end

  local shoppingCart = getShoppingCart(businessId, vehicleId, changedVars, baselineTuningVars)
  local tuningData = fetchVehicleTuningVariables(businessId, vehicleId)
  local cartItems = cartRowsFor(shoppingCart.items, changedVars, baselineTuningVars, tuningData)
  applyCartDiscount(cartItems, businessId)
  return cartItems
end

-- Cache hooks -------------------------------------------------------------------------------------

-- Tuning data is read live, so there is no cache to clear; the functions stay for callers.
local function clearTuningDataCacheForVehicle(businessId, cacheKey) end

local function clearTuningDataCache() end

-- Public API --------------------------------------------------------------------------------------

M.requestVehicleTuningData = requestVehicleTuningData
M.getVehicleTuningData = getVehicleTuningData
M.applyTuningToVehicle = applyTuningToVehicle
M.calculateTuningCost = calculateTuningCost
M.getShoppingCart = getShoppingCart
M.applyVehicleTuning = applyVehicleTuning
M.clearTuningDataCache = clearTuningDataCache
M.clearTuningDataCacheForVehicle = clearTuningDataCacheForVehicle
M.addTuningToCart = addTuningToCart

return M
