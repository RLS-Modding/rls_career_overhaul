-- Vehicle tuning: adjustment previews, checkout and saved tunes.
-- The stock fork owns the active tuning session and restores the prior variables on cancellation.
-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Fork of stock lua/ge/extensions/career/modules/tuning.lua (BeamNG 0.40).

local capabilities = require("overhaul/lib/platform/capabilities")
local M = {}

local jbeamIO = require("jbeam/io")
local savedTunesLibrary = require("overhaul/career/parts/tuning/savedTunes")
-- SaveStore key over the file this module writes today (metadata only).
require("overhaul/lib/save/store").registerKeys({
  {key = "parts.savedTunes", owner = "overhaul_career_parts_tuning", files = {"settings/RLS/savedTunes.json"}, phase = "immediate", required = false, root = "user"},
})

local inventoryId
local vehicleVarsBefore
local changedVars
local shoppingCart

local originComputerId

local tether
local switchingVehicle = false
local savedTuneApplyInProgress = false
local returnRoute = nil
local sessionMode = nil

local SAVED_TUNES_ROOT = "settings/RLS/"
local SAVED_TUNES_FILE = SAVED_TUNES_ROOT .. "savedTunes.json"
local savedTunesState

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

local hiddenCareerCategories = {
  Cargo = true,
}

local hiddenCareerVarNames = {
  ["$fuel"] = true,
  ["$fuel_R"] = true,
  ["$fuel_L"] = true,
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
  local vehId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId)
  local veh = vehId and getObjectByID(vehId) or nil
  local computer = originComputerId and overhaul_world_facilities.getFacility("computer", originComputerId) or nil
  if not veh or not computer then return false end

  -- calculate the size of the vehicle to use for tethering
  local oobb = veh:getSpawnWorldOOBB()
  local vehCenter = oobb:getCenter()
  local vehRadius = (oobb:getPoint(0) - oobb:getPoint(6)):length()
  -- calculate computer position
  local computerPos = overhaul_world_facilities.getAverageDoorPositionForFacility(computer)
  if not computerPos then return false end

  local distBetweenVehicleAndComputer = (computerPos-vehCenter):length()
  -- this smoothly scales the radius from 100% for 4m or less distance to 150% for 12m or more radius
  local radiusMultipler = ((clamp(distBetweenVehicleAndComputer,4,12)-4)/16 + 1)
  -- These camera radii keep the workshop vehicle in view.
  tether = overhaul_career_maintenance_tether.startCapsuleTetherBetweenStatics(computerPos, 10*radiusMultipler, vehCenter, vehRadius + (9*radiusMultipler), M.cancelShopping)
  return tether ~= nil
end

local function applyShopping()
  if not shoppingCart or not inventoryId then
    return {success = false, reason = "no_active_tuning"}
  end
  if not overhaul_career_logistics_general.validateLogisticsContainers(inventoryId) then return {success = false, reason = 'loaded_cargo_incompatible'} end
  if switchingVehicle or savedTuneApplyInProgress then
    return {success = false, reason = "tuning_operation_in_progress"}
  end

  local total = tonumber(shoppingCart.total) or 0
  if total > 0 and not overhaul_career_economy_payment.canPay({money = {amount = total, canBeNegative = false}}) then
    guihooks.trigger('toastrMsg', {type = "error", title = "Not enough money", msg = "You cannot afford this tune."})
    return {success = false, reason = "insufficient_funds"}
  end

  overhaul_career_parts_vehiclePerformance.invalidateCertification(inventoryId)
  overhaul_career_garage_inventory.setVehicleDirty(inventoryId)
  -- The cart is paid once; a repeated or late apply finds no cart.
  shoppingCart = nil
  local checkout = require("overhaul/lib/checkout/operations")
  local operation = checkout.begin("tuning", {amount = total, target = {inventoryId = inventoryId}})
  checkout.settle(operation, function()
    checkout.money.execute(overhaul_career_economy_playerAttributes.addAttributes, {money=-total}, {category = "purchase", finance = {vehicleId = inventoryId}, tags={"tuning", "buying"}, label = "ui.career.tuning.tunedVehicle"})
  end)

  -- The live inventory config is also the dyno's temporary hub config. Mark
  -- the current variables as purchased before autosave starts so the dyno save
  -- view persists the paid tune, while unpaid previews continue to use the
  -- session baseline.
  local vehicleData = overhaul_career_garage_inventory.getVehicles()[inventoryId]
  local purchasedVars = vehicleData and vehicleData.config and deepcopy(vehicleData.config.vars or {}) or {}
  vehicleVarsBefore = deepcopy(purchasedVars)
  changedVars = {}
  local session = capabilities.peek("businessSession")
  if session then session.commitTuningPurchase(inventoryId, purchasedVars) end

  gameplay_achievement.unlockAchievement("VEHICLE_TUNED")

  Engine.Audio.playOnce('AudioGui','event:>UI>Career>Buy_01')
  if overhaul_career_career.isAutosaveEnabled() then
    require("overhaul/lib/save/store").request("tuning:apply", {inventoryId}, {force = true})
  end
  M.close()
end

local DYNO_ALLOWED_TERMS = {
  "engine", "transmission", "gearbox", "ecu", "engine management",
  "turbo", "supercharger", "supercharge", "boost", "rpm", "rev limiter",
  "revlimit", "rev limit"
}

local DYNO_DENIED_TERMS = {
  "suspension", "wheel alignment", "alignment", "wheel", "tire", "tyre",
  "brake", "chassis", "differential", "transfer case", "transfercase",
  "driveshaft", "axle", "steering"
}

-- JBeam tuning variables are substitutions, not typed engine properties.  Use
-- the section in which an installed part consumes the variable as the primary
-- signal, then retain the metadata classifier as a compatibility fallback for
-- stock and third-party parts whose processed JBeam no longer contains tokens.
local DYNO_EFFECT_ALLOWED_TERMS = {
  "mainengine", "combustionengine", "enginecontroller", "engine management",
  "injectionsystem", "injection", "fuelinject", "ignition", "intake",
  "turbocharger", "supercharger", "nitrousoxide", "n2o", "boost",
  "revlimiter", "rpm", "gearbox", "transmission"
}

local DYNO_EFFECT_DENIED_TERMS = {
  "variables", "suspension", "wheel", "tire", "tyre", "brake", "chassis",
  "differential", "transfercase", "transfer case", "driveshaft", "axle",
  "steering", "nodes", "beams", "hydros"
}

local function containsTerm(text, terms)
  text = string.lower(tostring(text or ""))
  for _, term in ipairs(terms) do
    if text:find(term, 1, true) then
      return true
    end
  end
  return false
end

local function pathContainsTerm(path, terms)
  return containsTerm(table.concat(path or {}, " "), terms)
end

local function recordDynoEffectToken(value, path, effects)
  if type(value) ~= "string" then return end
  local allowedPath = pathContainsTerm(path, DYNO_EFFECT_ALLOWED_TERMS)
  local deniedPath = pathContainsTerm(path, DYNO_EFFECT_DENIED_TERMS)
  if not allowedPath and not deniedPath then return end

  for varName in string.gmatch(value, "%$[%w_]+") do
    local effect = effects[varName] or {allowed = false, denied = false}
    effect.allowed = effect.allowed or (allowedPath and not deniedPath)
    effect.denied = effect.denied or deniedPath
    effects[varName] = effect
  end
end

local function collectDynoJBeamVariableEffects(value, effects, path, seen)
  effects = effects or {}
  path = path or {}
  seen = seen or {}
  if type(value) ~= "table" or seen[value] then return effects end
  seen[value] = true

  for key, child in pairs(value) do
    local keyText = type(key) == "string" and string.lower(key) or nil
    if keyText ~= "variables" then
      local childPath = path
      if keyText then
        childPath = {}
        for index, segment in ipairs(path) do childPath[index] = segment end
        childPath[#childPath + 1] = keyText
      end
      recordDynoEffectToken(key, childPath, effects)
      recordDynoEffectToken(child, childPath, effects)
      if type(child) == "table" then
        collectDynoJBeamVariableEffects(child, effects, childPath, seen)
      end
    end
  end
  return effects
end

local function buildDynoJBeamEffectMap(vehData)
  local effects = {}
  local config = vehData and vehData.config
  local ioCtx = vehData and vehData.ioCtx
  if type(config) ~= "table" or not ioCtx or not jbeamIO or not jbeamIO.getPart then
    return effects
  end

  local visitedParts = {}
  local function inspectPart(partName)
    if type(partName) ~= "string" or partName == "" or visitedParts[partName] then return end
    visitedParts[partName] = true
    local ok, partData = pcall(jbeamIO.getPart, ioCtx, partName)
    if ok and type(partData) == "table" then
      collectDynoJBeamVariableEffects(partData, effects)
    end
  end

  for _, partName in pairs(config.parts or {}) do inspectPart(partName) end
  local function visit(node)
    if type(node) ~= "table" then return end
    inspectPart(node.chosenPartName or node.partName or node.name)
    for _, child in pairs(node.children or {}) do visit(child) end
  end
  visit(config.partsTree)
  return effects
end

local function isDynoVariableAllowed(varName, varData, effectMap)
  if type(varData) ~= "table" then
    return false
  end

  local categoryText = table.concat({
    tostring(varData.category or ""),
    tostring(varData.subCategory or "")
  }, " ")
  if containsTerm(categoryText, DYNO_DENIED_TERMS) then
    return false
  end
  local effect = type(effectMap) == "table" and effectMap[varName] or nil
  if effect and effect.denied then return false end
  if effect and effect.allowed then return true end
  if containsTerm(categoryText, DYNO_ALLOWED_TERMS) then
    return true
  end

  local fullText = table.concat({
    tostring(varName or ""),
    tostring(varData.name or ""),
    tostring(varData.title or "")
  }, " ")
  if containsTerm(fullText, DYNO_DENIED_TERMS) then
    return false
  end
  return containsTerm(fullText, DYNO_ALLOWED_TERMS)
end

local function filterDynoTuningVars(variables, vehData)
  if sessionMode ~= "dyno" or type(variables) ~= "table" then
    return variables
  end
  local effectMap = buildDynoJBeamEffectMap(vehData)
  for varName, varData in pairs(variables) do
    if not isDynoVariableAllowed(varName, varData, effectMap) then
      variables[varName] = nil
    end
  end
  return variables
end

local function getVehicleTuningContext()
  local vehId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId)
  if not vehId then return end
  local vehData = core_vehicle_manager.getVehicleData(vehId)
  if not vehData then return end
  local variables = vehData.vdata and vehData.vdata.variables
  if type(variables) ~= "table" then return end
  return vehData, deepcopy(variables)
end

local function getRawTuningData()
  local vehData, variables = getVehicleTuningContext()
  if not vehData then return end
  return filterDynoTuningVars(variables, vehData)
end

-- Fuel/battery fill level is not a paid tune — hide all $fuel* vars from the career tuning menu.
local function stripFuelTuningVars(variables)
  if not variables then return variables end
  for varName in pairs(variables) do
    if type(varName) == "string" and varName:sub(1, 5) == "$fuel" then
      variables[varName] = nil
    end
  end
  return variables
end

local function getTuningData()
  local variables = getRawTuningData()
  if not variables then return end
  stripFuelTuningVars(variables)
  for varName, varData in pairs(variables) do
    if hiddenCareerVarNames[varName] or hiddenCareerCategories[varData.category] then
      variables[varName] = nil
    end
  end
  return core_vehicle_partmgmt.translateTuningData(variables)
end

local function isCareerVisibleVariable(varName, varData)
  if type(varName) ~= "string" or type(varData) ~= "table" then return false end
  if varName:sub(1, 5) == "$fuel" then return false end
  if varData.hideInUI or varData.category == "Cargo" then return false end
  return true
end

local function isValueInRawRange(value, varData)
  local endpointA, endpointB = tonumber(varData and varData.min), tonumber(varData and varData.max)
  if not endpointA or not endpointB then return false end
  local lower, upper = math.min(endpointA, endpointB), math.max(endpointA, endpointB)
  return value >= lower and value <= upper
end

local function getActiveModelKey()
  local vehicleInfo = inventoryId and overhaul_career_garage_inventory.getVehicles()[inventoryId] or nil
  if not vehicleInfo then return nil end
  local config = vehicleInfo.config or {}
  return savedTunesLibrary.normalizeModelKey(
    vehicleInfo.model or vehicleInfo.model_key or config.model or config.model_key)
end

local function getSavedTunesState()
  if savedTunesState then return savedTunesState end
  local exists = FS:fileExists(SAVED_TUNES_FILE) == true
  local decoded = exists and jsonReadFile(SAVED_TUNES_FILE) or nil
  savedTunesState = savedTunesLibrary.loadState(exists, decoded)
  if savedTunesState.readOnly then
    log("E", "career.tuning", string.format(
      "Saved tunes library is read-only (%s): %s",
      tostring(savedTunesState.error), SAVED_TUNES_FILE))
  end
  return savedTunesState
end

local function writeSavedTunes(candidate)
  if not FS:directoryExists(SAVED_TUNES_ROOT) then
    FS:directoryCreate(SAVED_TUNES_ROOT, true)
  end
  return require("overhaul/lib/save/store").writeNow(SAVED_TUNES_FILE, candidate, true) == true
end

local function commitSavedTunes(candidate)
  local state = getSavedTunesState()
  local committed, success = savedTunesLibrary.commit(state.data, candidate, writeSavedTunes)
  if not success then
    log("E", "career.tuning", "Failed to write saved tunes library: " .. SAVED_TUNES_FILE)
    return false
  end
  state.data = committed
  return true
end

local function getSavedTunes()
  local modelKey = getActiveModelKey()
  if not modelKey then return {success = false, reason = "no_active_tuning_session", tunes = {}} end
  local state = getSavedTunesState()
  return {
    success = true,
    modelKey = modelKey,
    tunes = state.data and savedTunesLibrary.listTunes(state.data, modelKey) or {},
    readOnly = state.readOnly == true,
    error = state.error,
  }
end

local function sanitizeTuneSnapshot(snapshot)
  local source = type(snapshot) == "table" and (snapshot.variables or snapshot) or nil
  if type(source) ~= "table" then return nil, "invalid_snapshot" end
  local tuningData = getTuningData() or {}
  local result = {}
  for varName, record in pairs(source) do
    local varData = tuningData[varName]
    local value = type(record) == "table" and record.value or nil
    if isCareerVisibleVariable(varName, varData) and savedTunesLibrary.isFiniteNumber(value) then
      if isValueInRawRange(value, varData) then
        result[varName] = {
          value = value,
          label = tostring(varData.title or (type(record) == "table" and record.label) or varName),
        }
      end
    end
  end
  if not next(result) then return nil, "empty_snapshot" end
  return result
end

local function saveTune(name, snapshot, replaceExisting)
  if savedTuneApplyInProgress or switchingVehicle then
    return {success = false, reason = "tuning_operation_in_progress"}
  end
  local modelKey = getActiveModelKey()
  if not modelKey then return {success = false, reason = "no_active_tuning_session"} end
  local state = getSavedTunesState()
  if state.readOnly then return {success = false, reason = state.error or "library_read_only", readOnly = true} end
  local variables, snapshotError = sanitizeTuneSnapshot(snapshot)
  if not variables then return {success = false, reason = snapshotError} end
  local candidate, result = savedTunesLibrary.upsertTune(
    state.data, modelKey, name, variables, replaceExisting == true, {
      now = os.time(),
      idFactory = function() return Engine.generateUUID() end,
    })
  if not candidate then return result end
  if not commitSavedTunes(candidate) then return {success = false, reason = "write_failed"} end
  result.tunes = savedTunesLibrary.listTunes(candidate, modelKey)
  return result
end

local function deleteSavedTune(tuneId)
  if savedTuneApplyInProgress or switchingVehicle then
    return {success = false, reason = "tuning_operation_in_progress"}
  end
  local modelKey = getActiveModelKey()
  if not modelKey then return {success = false, reason = "no_active_tuning_session"} end
  local state = getSavedTunesState()
  if state.readOnly then return {success = false, reason = state.error or "library_read_only", readOnly = true} end
  local candidate, result = savedTunesLibrary.deleteTune(state.data, modelKey, tostring(tuneId or ""))
  if not candidate then return result end
  if not commitSavedTunes(candidate) then return {success = false, reason = "write_failed"} end
  result.tunes = savedTunesLibrary.listTunes(candidate, modelKey)
  return result
end

local function getOriginComputer()
  if not originComputerId then return nil end
  return overhaul_world_facilities.getFacility("computer", originComputerId)
end

local function isTuningTentSession()
  local computer = getOriginComputer()
  return computer ~= nil and computer.openTuningDirectly == true
end

-- Why a vehicle can't be tuned: the short label in the vehicle list and the message when it is
-- the only vehicle there. Loaners are forbidden by the inventory permission, which has no label.
local BLOCKED = {
  needsRepair = {label = "Needs repair", message = "Repair your vehicle before tuning."},
  loaned = {label = "Loaned vehicle", message = "Loaned vehicles can't be tuned."},
}
local BLOCKED_MESSAGE_BY_LABEL = {}
for _, reason in pairs(BLOCKED) do BLOCKED_MESSAGE_BY_LABEL[reason.label] = reason.message end

-- start() refuses the same broken-part case.
local function getBlockedReason(candidateId, vehicleInfo)
  if overhaul_career_market_valueCalculator.getNumberOfBrokenParts(vehicleInfo.partConditions) > 0
      or overhaul_career_repair_insurance.inventoryVehNeedsRepair(candidateId) then
    return BLOCKED.needsRepair.label
  end
  if vehicleInfo.owned == false then return BLOCKED.loaned.label end
end

-- What the tent's vehicle list asks of the zone helper; the session switcher uses the same rule.
local function tuningVehicleRequest()
  return {permissionTags = {"tuning", "vehicleModification"}, blockedReason = getBlockedReason}
end

local function getTuneableVehicleIds()
  local computer = getOriginComputer()
  if not computer then return {} end
  local zoneVehicles = overhaul_career_garage_zoneVehicles
  return zoneVehicles.eligibleIds(zoneVehicles.list(computer.garageId, tuningVehicleRequest()))
end

local function getTuningSessionData()
  local data = {
    activeInventoryId = inventoryId and tostring(inventoryId) or nil,
    isTuningTent = isTuningTentSession(),
    switchingVehicle = switchingVehicle,
    savedTuneApplyInProgress = savedTuneApplyInProgress,
    vehicles = {},
    sessionMode = sessionMode,
  }

  if not data.isTuningTent then return data end

  for _, candidateId in ipairs(getTuneableVehicleIds()) do
    local vehicleInfo = overhaul_career_garage_inventory.getVehicles()[candidateId]
    if vehicleInfo then
      local niceName = vehicleInfo.niceName
      niceName = core_locales.translateWithOrWithoutContext(niceName)
      table.insert(data.vehicles, {
        inventoryId = tostring(candidateId),
        niceName = niceName or tostring(candidateId)
      })
    end
  end

  return data
end

local function getPurchasedVarsForInventory(targetInventoryId)
  if inventoryId == nil or vehicleVarsBefore == nil or
      tostring(targetInventoryId) ~= tostring(inventoryId) then
    return nil
  end
  return deepcopy(vehicleVarsBefore)
end

local function prepareVehicleSession(targetInventoryId)
  local previousInventoryId = inventoryId
  inventoryId = targetInventoryId
  local tuningData = getTuningData()
  local vehicleInfo = overhaul_career_garage_inventory.getVehicles()[inventoryId]
  if not tuningData or not vehicleInfo then
    inventoryId = previousInventoryId
    return false
  end

  local currentVehicleVars = deepcopy(vehicleInfo.config.vars or {})
  vehicleVarsBefore = sessionMode == "dyno" and {} or currentVehicleVars

  -- Fill the baseline with variables whose current value only exists in JBeam.
  for varName, varTuningData in pairs(tuningData) do
    vehicleVarsBefore[varName] = currentVehicleVars[varName] ~= nil and
                                   currentVehicleVars[varName] or varTuningData.val
  end

  shoppingCart = {}
  changedVars = {}
  return true
end

local function sendShoppingCartToUI(shoppingCartUI)
  local shoppingData = {shoppingCart = shoppingCartUI}
  shoppingData.playerMoney = overhaul_career_economy_playerAttributes.getAttributeValue("money")
  guihooks.trigger('sendTuningShoppingData', shoppingData)
end

local function createShoppingCart()
  local tuningData = getRawTuningData() or {}
  shoppingCart = {items = {}}
  local total = 0
  for varName, value in pairs(changedVars) do
    local varData = tuningData[varName]
    if not varData then goto continue end

    -- Construct the shopping cart and calculate prices for each item
    local varPrice
    if isOnBlackList(varData) then
      shoppingCart.items[varName] = {name = varName, title = string.format("%s %s %s",
        core_vehicle_partmgmt.getTranslation(varData.category, "ui.vehicleconfig.variables.category."),
        core_vehicle_partmgmt.getTranslation(varData.subCategory, "ui.vehicleconfig.variables.subCategory."),
        core_vehicle_partmgmt.getTranslation(varData.title, "ui.vehicleconfig.variables.title.")
      )}
      varPrice = 0
    elseif varData.category then
      -- Add the category to the shopping cart if it's not there yet
      if not shoppingCart.items[varData.category] then
        local price = getPriceCategory(varData.category)
        total = total + price
        shoppingCart.items[varData.category] = { type = "category", items = {}, price = price, title = core_vehicle_partmgmt.getTranslation(varData.category, "ui.vehicleconfig.variables.category.")}
      end

      -- Add the subCategory to the shopping cart if it's not there yet
      if varData.subCategory and not shoppingCart.items[varData.category].items[varData.subCategory] then
        local price = getPriceSubCategory(varData.category, varData.subCategory)
        total = total + price
        shoppingCart.items[varData.category].items[varData.subCategory] = { type = "subCategory", items = {}, price = price, title = core_vehicle_partmgmt.getTranslation(varData.subCategory, "ui.vehicleconfig.variables.subCategory.")}
      end

      if varData.subCategory then
        varPrice = getPrice(varData.category, varData.subCategory, varName)
        shoppingCart.items[varData.category].items[varData.subCategory].items[varName] = {name = varName, title = core_vehicle_partmgmt.getTranslation(varData.title, "ui.vehicleconfig.variables.title."), price = varPrice}
      else
        varPrice = getPrice(varData.category, varData.subCategory, varName)
        shoppingCart.items[varData.category].items[varName] = {name = varName, title = core_vehicle_partmgmt.getTranslation(varData.title, "ui.vehicleconfig.variables.title."), price = varPrice}
      end

    else
      varPrice = getPrice(varData.category, varData.subCategory, varName)
      shoppingCart.items[varName] = {name = varName, title = core_vehicle_partmgmt.getTranslation(varData.title, "ui.vehicleconfig.variables.title."), price = varPrice}
    end

    total = total + varPrice
    ::continue::
  end

  -- Scale all prices by vehicle market index before building UI
  local vehicleMarketIndex = overhaul_career_economy_globalEconomy.getVehicleMarketIndex() or 1.0
  if vehicleMarketIndex ~= 1.0 then
    total = 0
    for name, info in pairs(shoppingCart.items) do
      if info.price then
        info.price = math.floor(info.price * vehicleMarketIndex + 0.5)
      end
      for subName, subInfo in pairs(info.items or {}) do
        if subInfo.price then
          subInfo.price = math.floor(subInfo.price * vehicleMarketIndex + 0.5)
        end
        for itemName, itemInfo in pairs(subInfo.items or {}) do
          if itemInfo.price then
            itemInfo.price = math.floor(itemInfo.price * vehicleMarketIndex + 0.5)
          end
        end
      end
    end
    -- Recalculate total from scaled items
    for name, info in pairs(shoppingCart.items) do
      total = total + (info.price or 0)
      for subName, subInfo in pairs(info.items or {}) do
        total = total + (subInfo.price or 0)
        for itemName, itemInfo in pairs(subInfo.items or {}) do
          total = total + (itemInfo.price or 0)
        end
      end
    end
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

  shoppingCart.taxes = math.floor(total * 0.07 + 0.5)
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

local function buildSavedTuneApplication(savedTune, baseline, rawTuningData, dynoMode, dynoAllowed)
  local targetVars = savedTunesLibrary.deepCopy(baseline or {})
  local skipped = {}
  local acceptedCount = 0

  local function skip(varName, record, reason)
    skipped[#skipped + 1] = {
      name = tostring(varName),
      label = type(record) == "table" and tostring(record.label or varName) or tostring(varName),
      reason = reason,
    }
  end

  for varName, record in pairs(type(savedTune) == "table" and savedTune.variables or {}) do
    local value = type(record) == "table" and record.value or nil
    local varData = type(rawTuningData) == "table" and rawTuningData[varName] or nil
    if type(varName) ~= "string" or type(record) ~= "table" or
        not savedTunesLibrary.isFiniteNumber(value) then
      skip(varName, record, "corrupt")
    elseif not varData then
      skip(varName, record, "missing")
    elseif not isCareerVisibleVariable(varName, varData) then
      skip(varName, record, "hidden")
    elseif dynoMode and not dynoAllowed(varName, varData) then
      skip(varName, record, "session_blocked")
    else
      local minValue, maxValue = tonumber(varData.min), tonumber(varData.max)
      if not minValue or not maxValue then
        skip(varName, record, "corrupt")
      elseif not isValueInRawRange(value, varData) then
        skip(varName, record, "out_of_range")
      else
        targetVars[varName] = value
        acceptedCount = acceptedCount + 1
      end
    end
  end

  table.sort(skipped, function(a, b)
    local aLabel, bLabel = string.lower(a.label), string.lower(b.label)
    if aLabel == bLabel then return a.name < b.name end
    return aLabel < bLabel
  end)
  return {
    targetVars = targetVars,
    acceptedCount = acceptedCount,
    skippedCount = #skipped,
    skipped = skipped,
  }
end

local function triggerSavedTuneCompletion(payload)
  savedTuneApplyInProgress = false
  guihooks.trigger("careerSavedTuneApplyCompleted", payload)
end

local function applySavedTune(tuneId)
  if switchingVehicle or savedTuneApplyInProgress then
    return {success = false, reason = "tuning_operation_in_progress"}
  end
  local modelKey = getActiveModelKey()
  if not modelKey or not vehicleVarsBefore then
    return {success = false, reason = "no_active_tuning_session"}
  end
  local state = getSavedTunesState()
  if not state.data then return {success = false, reason = state.error or "library_unavailable"} end
  local tune = savedTunesLibrary.findTune(state.data, modelKey, tostring(tuneId or ""))
  if not tune then return {success = false, reason = "tune_not_found"} end

  local vehData, allRawTuningData = getVehicleTuningContext()
  if not vehData then return {success = false, reason = "vehicle_tuning_data_unavailable"} end
  local effectMap = sessionMode == "dyno" and buildDynoJBeamEffectMap(vehData) or nil
  local application = buildSavedTuneApplication(
    tune,
    vehicleVarsBefore,
    allRawTuningData,
    sessionMode == "dyno",
    function(varName, varData) return isDynoVariableAllowed(varName, varData, effectMap) end)

  local vehId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId)
  local oldVehicle = vehId and getObjectByID(vehId) or nil
  local vehicleInfo = overhaul_career_garage_inventory.getVehicles()[inventoryId]
  if not oldVehicle or not vehicleInfo or not vehicleInfo.config then
    return {success = false, reason = "vehicle_unavailable"}
  end

  local transform = {
    pos = oldVehicle:getPosition(),
    rot = quat(0, 0, 1, 0) * quat(oldVehicle:getRefNodeRotation()),
  }
  local previousConfigVars = deepcopy(vehicleInfo.config.vars or {})
  local previousChangedVars = deepcopy(changedVars or {})
  -- Dyno baselines intentionally contain only session-allowed variables. Merge
  -- the complete session target over the current config so unrelated/blocked
  -- variables survive while every allowed unpaid edit is reset to baseline.
  local targetConfigVars = deepcopy(previousConfigVars)
  tableMerge(targetConfigVars, application.targetVars)
  vehicleInfo.config.vars = targetConfigVars
  savedTuneApplyInProgress = true

  local completionSent = false
  local function finishSuccess(ok)
    if completionSent then return end
    completionSent = true
    if ok == false then
      vehicleInfo.config.vars = previousConfigVars
      changedVars = previousChangedVars
      createShoppingCart()
      triggerSavedTuneCompletion({success = false, tuneId = tune.id, reason = "vehicle_respawn_failed"})
      return
    end
    if sessionMode ~= "dyno" then overhaul_career_repair_damageManager.saveDamageState(inventoryId) end
    local currentVehicleId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId)
    local currentVehicle = currentVehicleId and getObjectByID(currentVehicleId) or nil
    if currentVehicle then
      spawn.safeTeleport(currentVehicle, transform.pos, transform.rot, nil, nil, nil, nil, false)
      core_vehicleBridge.executeAction(currentVehicle, "setFreeze", true)
    end
    changedVars = getChangedVars(application.targetVars, vehicleVarsBefore)
    createShoppingCart()
    extensions.hook("onOverhaulTuningApplied")
    triggerSavedTuneCompletion({
      success = true,
      tuneId = tune.id,
      name = tune.name,
      appliedCount = application.acceptedCount,
      skippedCount = application.skippedCount,
      skipped = application.skipped,
    })
  end

  local spawnOk, spawnedVehicle = pcall(
    overhaul_career_garage_inventory.spawnVehicle, inventoryId, 2, finishSuccess, nil, nil,
    {prepareReplacement = function()
      if sessionMode ~= "dyno" then overhaul_career_repair_damageManager.clearDamageState(inventoryId) end
      return true
    end})
  if not completionSent and (not spawnOk or not spawnedVehicle) then
    completionSent = true
    vehicleInfo.config.vars = previousConfigVars
    changedVars = previousChangedVars
    createShoppingCart()
    triggerSavedTuneCompletion({
      success = false,
      tuneId = tune.id,
      name = tune.name,
      reason = "vehicle_respawn_failed",
      appliedCount = 0,
      skippedCount = application.skippedCount,
      skipped = application.skipped,
    })
    return {success = false, reason = "vehicle_respawn_failed"}
  end

  spawn.safeTeleport(spawnedVehicle, transform.pos, transform.rot, nil, nil, nil, nil, false)
  core_vehicleBridge.executeAction(spawnedVehicle, "setFreeze", true)
  return {success = true, pending = true}
end

local function startActual(_originComputerId, _returnRoute)
  originComputerId = _originComputerId
  returnRoute = _returnRoute
  -- Garage computers need an origin id. Roadside / return-route sessions open
  -- without a facility and navigate directly.
  if not originComputerId and not returnRoute then
    return false
  end

  extensions.ui_router.navigate("overhaul.computer.tuning")
  extensions.hook("onOverhaulTuningStarted")
  createShoppingCart()
  local veh = getObjectByID(overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId))
  if veh then
    core_vehicleBridge.executeAction(veh, 'setFreeze', true)
  end
  if originComputerId then
    setupTether()
  end
  return true
end

local function start(_inventoryId, _originComputerId, _returnRoute, options)
  local requestedMode = type(options) == "table" and options.mode or nil
  sessionMode = requestedMode
  local targetInventoryId = _inventoryId or overhaul_career_garage_inventory.getInventoryIdsInClosestGarage(true)
  if not targetInventoryId or not overhaul_career_garage_inventory.getMapInventoryIdToVehId()[targetInventoryId] then
    sessionMode = nil
    return false
  end
  local target = overhaul_career_garage_inventory.getVehicles()[targetInventoryId]
  if not target or overhaul_career_market_valueCalculator.getNumberOfBrokenParts(target.partConditions) > 0 then
    sessionMode = nil
    return false
  end
  if not prepareVehicleSession(targetInventoryId) then
    sessionMode = nil
    return false
  end
  switchingVehicle = false
  savedTuneApplyInProgress = false

  local numberOfBrokenParts = overhaul_career_market_valueCalculator.getNumberOfBrokenParts(overhaul_career_garage_inventory.getVehicles()[inventoryId].partConditions)
  -- Every build-changing service requires repairs before entry.
  if numberOfBrokenParts > 0 then
    sessionMode = nil
    return false
  end
  core_jobsystem.create(function(job)
    overhaul_career_repair_damageManager.saveDamageState(inventoryId)
    job.sleep(0.1)
    startActual(_originComputerId, _returnRoute)
  end, 2)
  return true
end

local function apply(tuningValues, callback, allowDuringVehicleSwitch)
  if savedTuneApplyInProgress then
    return {success = false, reason = "tuning_operation_in_progress"}
  end
  if switchingVehicle and not allowDuringVehicleSwitch then
    return {success = false, reason = "vehicle_switch_in_progress"}
  end

  if type(tuningValues) ~= "table" then
    return {success = false, reason = "invalid_tuning_values"}
  end
  if sessionMode == "dyno" then
    local allowedData = getRawTuningData() or {}
    for varName in pairs(tuningValues) do
      if not allowedData[varName] then
        return {success = false, reason = "variable_not_allowed_on_dyno", variable = tostring(varName)}
      end
    end
  end

  local vehId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId)
  local oldVeh = vehId and getObjectByID(vehId)
  local invVehicle = overhaul_career_garage_inventory.getVehicles()[inventoryId]
  if not oldVeh or not (invVehicle and invVehicle.config) then
    return {success = false, reason = "vehicle_missing"}
  end
  local vehicleTransform = {pos = oldVeh:getPosition(), rot = quat(0,0,1,0) * quat(oldVeh:getRefNodeRotation())}

  local previousVars = deepcopy(invVehicle.config.vars or {})
  invVehicle.config.vars = tableMerge(deepcopy(previousVars), tuningValues)
  savedTuneApplyInProgress = true
  local result = {success = true, pending = true}
  local completed = false
  local function complete(ok)
    if completed then return end
    completed = true
    savedTuneApplyInProgress = false
    if ok == false then
      if allowDuringVehicleSwitch then switchingVehicle = false end
      invVehicle.config.vars = previousVars
      result = {success = false, reason = "vehicle_respawn_failed"}
      createShoppingCart()
      return
    end
    if sessionMode ~= "dyno" then overhaul_career_repair_damageManager.saveDamageState(inventoryId) end
    local currentId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId)
    local veh = currentId and getObjectByID(currentId)
    if veh then
      spawn.safeTeleport(veh, vehicleTransform.pos, vehicleTransform.rot, nil, nil, nil, nil, false)
      core_vehicleBridge.executeAction(veh, 'setFreeze', true)
    end
    extensions.hook("onOverhaulTuningApplied")
    tableMerge(changedVars, tuningValues)
    changedVars = getChangedVars(changedVars, vehicleVarsBefore)
    createShoppingCart()
    result = {success = true}
    if callback then callback() end
  end
  local ok = pcall(overhaul_career_garage_inventory.spawnVehicle, inventoryId, 2, complete, nil, nil,
    {prepareReplacement = function()
      if sessionMode ~= "dyno" then overhaul_career_repair_damageManager.clearDamageState(inventoryId) end
      return true
    end})
  if not ok then complete(false) end
  return result
end

local function removeVarFromShoppingCart(varName)
  if switchingVehicle or savedTuneApplyInProgress then
    return {success = false, reason = "tuning_operation_in_progress"}
  end

  local tuningData = getTuningData()
  local varTuningData = tuningData and deepcopy(tuningData[varName]) or nil
  if not varTuningData then
    return {success = false, reason = "variable_not_allowed"}
  end

  local vars = {}
  vars[varName] = vehicleVarsBefore[varName]
  apply(vars)

  -- send the updated tuning var to UI
  varTuningData.val = vars[varName]
  guihooks.trigger('updateTuningVariable', varTuningData)
end

local function cancelShopping()
  if savedTuneApplyInProgress then return {success = false, reason = "tuning_operation_in_progress"} end
  if changedVars and next(changedVars) then
    apply(vehicleVarsBefore, M.close)
  else
    M.close()
  end
end

-- Route-level BACK must be owned by the tuning UI so it can confirm/discard
-- changes before this module chooses the correct destination for the facility.
local function requestExit()
  if savedTuneApplyInProgress then return {success = false, reason = "tuning_operation_in_progress"} end
  guihooks.trigger("tuningRequestExit")
end

local function switchVehicle(targetInventoryId)
  targetInventoryId = tonumber(targetInventoryId)
  if switchingVehicle or savedTuneApplyInProgress then
    return {success = false, reason = "tuning_operation_in_progress"}
  end
  if not isTuningTentSession() then
    return {success = false, reason = "not_tuning_tent"}
  end
  if targetInventoryId == inventoryId then
    return {success = true, unchanged = true, data = getTuningSessionData()}
  end

  local validTarget = false
  for _, candidateId in ipairs(getTuneableVehicleIds()) do
    if candidateId == targetInventoryId then
      validTarget = true
      break
    end
  end
  if not validTarget then
    return {success = false, reason = "vehicle_unavailable"}
  end

  switchingVehicle = true
  local previousInventoryId = inventoryId

  local function finishSwitch()
    local previousVehicleId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(previousInventoryId)
    local previousVehicle = previousVehicleId and getObjectByID(previousVehicleId) or nil
    if previousVehicle then
      core_vehicleBridge.executeAction(previousVehicle, 'setFreeze', false)
    end
    if tether then
      tether.remove = true
      tether = nil
    end

    overhaul_career_repair_damageManager.saveDamageState(targetInventoryId)
    core_jobsystem.create(function(job)
      job.sleep(0.1)
      if not prepareVehicleSession(targetInventoryId) then
        prepareVehicleSession(previousInventoryId)
        local previousVehicleId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(previousInventoryId)
        local previousVehicle = previousVehicleId and getObjectByID(previousVehicleId) or nil
        if previousVehicle then
          core_vehicleBridge.executeAction(previousVehicle, 'setFreeze', true)
          setupTether()
        end
        switchingVehicle = false
        guihooks.trigger('careerTuningVehicleChanged', {
          success = false,
          reason = "vehicle_tuning_data_unavailable"
        })
        return
      end

      createShoppingCart()
      local targetVehicleId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId)
      local targetVehicle = targetVehicleId and getObjectByID(targetVehicleId) or nil
      if targetVehicle then
        core_vehicleBridge.executeAction(targetVehicle, 'setFreeze', true)
      end
      setupTether()
      switchingVehicle = false

      local sessionData = getTuningSessionData()
      sessionData.success = true
      guihooks.trigger('careerTuningVehicleChanged', sessionData)
    end, 2)
  end

  -- Applied previews live on the spawned vehicle. Restore that vehicle before
  -- moving the session/tether to another one. Pure UI edits need no respawn.
  if changedVars and next(changedVars) then
    apply(vehicleVarsBefore, finishSwitch, true)
  else
    finishSwitch()
  end

  return {success = true, pending = true}
end

local function close()
  if switchingVehicle or savedTuneApplyInProgress then return end

  local computer = getOriginComputer()
  local vehicleId = inventoryId and overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId) or nil
  local vehicle = vehicleId and getObjectByID(vehicleId) or nil
  if vehicle then
    core_vehicleBridge.executeAction(vehicle, 'setFreeze', false)
  end
  if tether then
    tether.remove = true
    tether = nil
  end

  local route = returnRoute
  returnRoute = nil
  originComputerId = nil
  local closingMode = sessionMode
  sessionMode = nil

  if route == "dynoSession" or closingMode == "dyno" then
    overhaul_career_career.closeAllMenus()
    capabilities.get("businessSession").resumeFromService()
    return
  end

  -- Roadside Service (and similar) ask to return to a specific route.
  if route then
    if type(route) == "table" then
      local routeName = route.name or route.route
      local params = route.params
      if not routeName and route.businessType then
        routeName = "business-computer"
        params = {businessType = route.businessType, businessId = route.businessId}
      end
      if routeName then
        if params and params.businessType then
          capabilities.get("businessComputer").setBusinessContext(params.businessType, params.businessId)
        end
        extensions.ui_router.navigate(routeName, params)
        return
      end
    end
    extensions.ui_router.navigate(route)
    return
  end

  -- Tuning tents are tuning-only spots; there is no computer menu to return to.
  if computer and not computer.openTuningDirectly then
    overhaul_career_garage_computer.openMenu(computer)
  else
    overhaul_career_career.closeAllMenus()
  end
end

local function tentToast(message)
  guihooks.trigger("toastrMsg", {type = "error", title = "Tuning", msg = message})
end

-- Tuning tents: with several vehicles in the tent the player picks one first; one starts at once.
local function startAtTent(computerFacility)
  if not overhaul_career_career.hasBoughtStarterVehicle() then
    return tentToast("You need to buy a starter vehicle first.")
  end
  local request = tuningVehicleRequest()
  request.garageId = computerFacility.garageId
  request.title = "Choose a vehicle to tune"
  request.placeName = computerFacility.name
  request.blockedCaption = "Can't tune"
  request.leftZoneNotice = "That vehicle is no longer in the tuning area."
  request.onChosen = function(chosenId)
    if not start(chosenId, computerFacility.id) then tentToast("That vehicle can't be tuned right now.") end
  end
  request.onNoneUsable = function(entries)
    local nearest = entries[1]
    if not nearest then return tentToast("Park your vehicle in the tent to tune it.") end
    tentToast(BLOCKED_MESSAGE_BY_LABEL[nearest.blockedReason] or nearest.blockedReason)
  end
  overhaul_career_garage_zoneVehicles.choose(request)
end

local function onOverhaulComputerAddFunctions(menuData, computerFunctions)
  if not menuData.computerFacility.functions["tuning"] then return end

  for _, vehicleData in ipairs(menuData.vehiclesInGarage) do
    local computerFunctionData = {
      id = "tuning",
      routeTarget = "overhaul.computer.tuning",
      label = _tr("ui.career.shared.pathTuning"),
      callback = function() start(vehicleData.inventoryId, menuData.computerFacility.id) end,
      order = 10
    }
    -- vehicle broken
    local vehicle = overhaul_career_garage_inventory.getVehicles()[vehicleData.inventoryId]
    if vehicle and overhaul_career_market_valueCalculator.getNumberOfBrokenParts(vehicle.partConditions) > 0 then
      computerFunctionData.disabled = true
      computerFunctionData.reason = overhaul_career_garage_computer.reasons.needsRepair
    end
    -- tutorial active
    if not menuData.hasBoughtStarterVehicle then
      computerFunctionData.disabled = true
      computerFunctionData.reason = overhaul_career_garage_computer.reasons.hasBoughtStarterVehicle
    end

    -- generic gameplay reason
    local inventoryId = vehicleData.inventoryId
    local reason = overhaul_career_permissions.getStatusForTag({"tuning", "vehicleModification"}, {inventoryId = inventoryId})
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
M.startAtTent = startAtTent
M.apply = apply
M.getTuningData = getTuningData
M.close = close
M.applyShopping = applyShopping
M.cancelShopping = cancelShopping
M.requestExit = requestExit
M.removeVarFromShoppingCart = removeVarFromShoppingCart
M.getTuningSessionData = getTuningSessionData
M.getPurchasedVarsForInventory = getPurchasedVarsForInventory
M.switchVehicle = switchVehicle
M.getSavedTunes = getSavedTunes
M.saveTune = saveTune
M.applySavedTune = applySavedTune
M.deleteSavedTune = deleteSavedTune
M.isVariableAllowedForDyno = isDynoVariableAllowed
M.collectDynoJBeamVariableEffects = collectDynoJBeamVariableEffects
M.buildSavedTuneApplication = buildSavedTuneApplication

M.onOverhaulComputerAddFunctions = onOverhaulComputerAddFunctions

return M
