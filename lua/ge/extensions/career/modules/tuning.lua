-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {"career_career"}

local inventoryId
local vehicleVarsBefore
local changedVars
local shoppingCart

local originComputerId

local tether

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

local function setupTether()
  local vehId = career_modules_inventory.getVehicleIdFromInventoryId(inventoryId)
  local veh = getObjectByID(vehId)

  -- calculate the size of the vehicle to use for tethering
  local oobb = veh:getSpawnWorldOOBB()
  local vehCenter = oobb:getCenter()
  local vehRadius = (oobb:getPoint(0) - oobb:getPoint(6)):length()
  -- calculate computer position
  local computerPos = freeroam_facilities.getAverageDoorPositionForFacility(freeroam_facilities.getFacility("computer", originComputerId))

  local distBetweenVehicleAndComputer = (computerPos-vehCenter):length()
  -- this smoothly scales the radius from 100% for 4m or less distance to 150% for 12m or more radius
  local radiusMultipler = ((clamp(distBetweenVehicleAndComputer,4,12)-4)/16 + 1)
  -- these radii are tuned for the wcusa garage!
  tether = career_modules_tether.startCapsuleTetherBetweenStatics(computerPos, 10*radiusMultipler, vehCenter, vehRadius + (9*radiusMultipler), M.cancelShopping)
end

local closeMenuAfterSaving
local function applyShopping()
  career_modules_vehiclePerformance.invalidateCertification(inventoryId)
  career_modules_inventory.setVehicleDirty(inventoryId)
  career_modules_playerAttributes.addAttributes({money=-shoppingCart.total}, {tags={"tuning", "buying"}, label="Tuned vehicle"})

  Engine.Audio.playOnce('AudioGui','event:>UI>Career>Buy_01')
  if career_career.isAutosaveEnabled() then
    closeMenuAfterSaving = true
    career_saveSystem.saveCurrent({inventoryId})
  else
    M.close()
  end
end

local function onVehicleSaveFinished()
  if closeMenuAfterSaving then
    M.close()
    closeMenuAfterSaving = nil
  end
end

local function getTuningData()
  local vehId = career_modules_inventory.getVehicleIdFromInventoryId(inventoryId)
  if not vehId then return end
  local vehData = core_vehicle_manager.getVehicleData(vehId)
  return deepcopy(vehData.vdata.variables)
end

local function sendShoppingCartToUI(shoppingCartUI)
  local shoppingData = {shoppingCart = shoppingCartUI}
  shoppingData.playerMoney = career_modules_playerAttributes.getAttributeValue("money")
  guihooks.trigger('sendTuningShoppingData', shoppingData)
end

local function createShoppingCart()
  local tuningData = getTuningData()
  shoppingCart = {items = {}}
  local total = 0
  for varName, value in pairs(changedVars) do
    local varData = tuningData[varName]

    -- Construct the shopping cart and calculate prices for each item
    local varPrice
    if isOnBlackList(varData) then
      shoppingCart.items[varName] = {name = varName, title = string.format("%s %s %s", varData.category, varData.subCategory, varData.title)}
      varPrice = 0
    elseif varData.category then
      -- Add the category to the shopping cart if it's not there yet
      if not shoppingCart.items[varData.category] then
        local price = getPriceCategory(varData.category)
        total = total + price
        shoppingCart.items[varData.category] = { type = "category", items = {}, price = price, title = varData.category}
      end

      -- Add the subCategory to the shopping cart if it's not there yet
      if varData.subCategory and not shoppingCart.items[varData.category].items[varData.subCategory] then
        local price = getPriceSubCategory(varData.category, varData.subCategory)
        total = total + price
        shoppingCart.items[varData.category].items[varData.subCategory] = { type = "subCategory", items = {}, price = price, title = varData.subCategory}
      end

      if varData.subCategory then
        varPrice = getPrice(varData.category, varData.subCategory, varName)
        shoppingCart.items[varData.category].items[varData.subCategory].items[varName] = {name = varName, title = varData.title, price = varPrice}
      else
        varPrice = getPrice(varData.category, varData.subCategory, varName)
        shoppingCart.items[varData.category].items[varName] = {name = varName, title = varData.title, price = varPrice}
      end

    else
      varPrice = getPrice(varData.category, varData.subCategory, varName)
      shoppingCart.items[varName] = {name = varName, title = varData.title, price = varPrice}
    end

    total = total + varPrice
  end

  local shoppingCartUI = {items = {}}
  for name, info in pairs(shoppingCart.items) do
    table.insert(shoppingCartUI.items, {varName = info.name, level = 1, title = info.title, price = info.price, type = info.type})
    for name, info in pairs(info.items or {}) do
      table.insert(shoppingCartUI.items, {varName = info.name, level = 2, title = info.title, price = info.price, type = info.type})
      for name, info in pairs(info.items or {}) do
        table.insert(shoppingCartUI.items, {varName = info.name, level = 3, title = info.title, price = info.price, type = info.type})
      end
    end
  end

  shoppingCart.taxes = total * 0.07
  shoppingCart.total = total + shoppingCart.taxes
  shoppingCartUI.taxes = shoppingCart.taxes
  shoppingCartUI.total = shoppingCart.total
  sendShoppingCartToUI(shoppingCartUI)
end

local function getChangedVars(vars1, vars2)
  local res = {}
  for varName1, value1 in pairs(vars1) do
    if vars2[varName1] ~= value1 then
      res[varName1] = value1
    end
  end
  return res
end

local function startActual(_originComputerId)
  originComputerId = _originComputerId
  shoppingCart = {}
  changedVars = {}
  if originComputerId then
    guihooks.trigger('ChangeState', {state = 'tuning', params = {}})
    extensions.hook("onCareerTuningStarted")
    createShoppingCart()
    local veh = getObjectByID(career_modules_inventory.getVehicleIdFromInventoryId(inventoryId))
    core_vehicleBridge.executeAction(veh, 'setFreeze', true)
    setupTether()
  end
end

local function start(_inventoryId, _originComputerId)
  inventoryId = _inventoryId or career_modules_inventory.getInventoryIdsInClosestGarage(true)
  if not inventoryId or not career_modules_inventory.getMapInventoryIdToVehId()[inventoryId] then return end
  local tuningData = getTuningData()
  vehicleVarsBefore = deepcopy(career_modules_inventory.getVehicles()[inventoryId].config.vars or {})

  -- fill the vehicleVarsBefore with the missing default values
  for varName, varTuningData in pairs(tuningData) do
    if not vehicleVarsBefore[varName] then
      vehicleVarsBefore[varName] = varTuningData.val
    end
  end

  local numberOfBrokenParts = career_modules_valueCalculator.getNumberOfBrokenParts(career_modules_inventory.getVehicles()[inventoryId].partConditions)
  if numberOfBrokenParts > 0 and numberOfBrokenParts < career_modules_valueCalculator.getBrokenPartsThreshold() then
    career_modules_insurance.startRepair(inventoryId, nil, function() startActual(_originComputerId) end)
  else
    career_modules_damageManager.saveDamageState(inventoryId)
    startActual(_originComputerId)
  end
end

local function apply(tuningValues, callback)
  local vehId = career_modules_inventory.getVehicleIdFromInventoryId(inventoryId)
  local oldVeh = getObjectByID(vehId)
  local vehicleTransform = {pos = oldVeh:getPosition(), rot = quat(0,0,1,0) * quat(oldVeh:getRefNodeRotation())}

  -- add the new tuning values to the existing vars and then reload the vehicle by entering again
  local vehicleVarsCurrent = career_modules_inventory.getVehicles()[inventoryId].config.vars or {}
  career_modules_inventory.getVehicles()[inventoryId].config.vars = tableMerge(vehicleVarsCurrent, tuningValues)

  career_modules_inventory.spawnVehicle(inventoryId, 2, callback)

  local veh = getObjectByID(vehId)
  spawn.safeTeleport(veh, vehicleTransform.pos, vehicleTransform.rot, nil, nil, nil, nil, false)
  core_vehicleBridge.executeAction(veh, 'setFreeze', true)

  extensions.hook("onCareerTuningApplied")

  tableMerge(changedVars, tuningValues)
  changedVars = getChangedVars(changedVars, vehicleVarsBefore)

  createShoppingCart()
end

local function removeVarFromShoppingCart(varName)
  local tuningData = getTuningData()
  local varTuningData = deepcopy(tuningData[varName])

  local vars = {}
  vars[varName] = vehicleVarsBefore[varName]
  apply(vars)

  -- send the updated tuning var to UI
  varTuningData.val = vars[varName]
  guihooks.trigger('updateTuningVariable', varTuningData)
end

local function cancelShopping()
  apply(vehicleVarsBefore, M.close)
end

local function close()
  if originComputerId then
    local computer = freeroam_facilities.getFacility("computer", originComputerId)
    career_modules_computer.openMenu(computer)
  else
    career_career.closeAllMenus()
  end
  core_vehicleBridge.executeAction(getObjectByID(career_modules_inventory.getVehicleIdFromInventoryId(inventoryId)), 'setFreeze', false)
  if tether then
    tether.remove = true
    tether = nil
  end
end

local function onComputerAddFunctions(menuData, computerFunctions)
  if not menuData.computerFacility.functions["tuning"] then return end

  for _, vehicleData in ipairs(menuData.vehiclesInGarage) do
    local computerFunctionData = {
      id = "tuning",
      label = "Tuning",
      callback = function() start(vehicleData.inventoryId, menuData.computerFacility.id) end,
      disabled = buttonDisabled,
      order = 10
    }
    -- vehicle broken
    if vehicleData.needsRepair then
      computerFunctionData.disabled = true
      computerFunctionData.reason = career_modules_computer.reasons.needsRepair
    end
    -- tutorial active
    if menuData.tutorialPartShoppingActive or menuData.tutorialTuningActive then
      computerFunctionData.disabled = true
      computerFunctionData.reason = career_modules_computer.reasons.tutorialActive
    end

    -- generic gameplay reason
    local inventoryId = vehicleData.inventoryId
    local reason = career_modules_permissions.getStatusForTag({"tuning", "vehicleModification"}, {inventoryId = inventoryId})
    if not reason.allow then
      computerFunctionData.disabled = true
    end
    if reason.permission ~= "allowed" then
      computerFunctionData.reason = reason
    end

    computerFunctions.vehicleSpecific[inventoryId][computerFunctionData.id] = computerFunctionData
  end
end

M.start = start
M.apply = apply
M.getTuningData = getTuningData
M.close = close
M.applyShopping = applyShopping
M.cancelShopping = cancelShopping
M.removeVarFromShoppingCart = removeVarFromShoppingCart

M.onComputerAddFunctions = onComputerAddFunctions
M.onVehicleSaveFinished = onVehicleSaveFinished

return M