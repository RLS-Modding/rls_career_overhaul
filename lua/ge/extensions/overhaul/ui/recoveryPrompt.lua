-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding
-- Fork of stock lua/ge/extensions/core/recoveryPrompt.lua (BeamNG 0.40).

-- Recovery, towing and quick travel while Overhaul owns the game's reset key.
-- Read config/state, validation, option builders, garage travel, fade handling, projections, then game hooks.
local M = {}
M.dependencies = {"overhaul_shell_patches", "core_recoveryPrompt"}

local capabilities = require('overhaul/lib/platform/capabilities')
local rigRecovery = require('overhaul/lib/logistics/rigRecovery')
local walkTarget = require('overhaul/lib/avatar/walkTarget')
local catalog = require("overhaul/lib/platform/catalog")
local optional = require("overhaul/lib/platform/optional")

-- Config ------------------------------------------------------------------------------------------

local PATCH_ID = "recoveryPrompt"
local MOVING_SLOWLY_MS = 10
local STOPPED_MS = 0.5
local FLIP_UPRIGHT_COST = 50
local TOW_TO_ROAD_COST = 75
local BASE_TOW_TO_GARAGE_COST = 250
local FADE_SECONDS = 0.3
local BRIDGE_REPLY_TIMEOUT_SECONDS = 5
local FEATURE_OPTIONS_DIR = "/gameplay/overhaul/recovery/options/"
local FEATURE_OPTIONS_LOG_TAG = "overhaul_recovery_options"
local BUTTON_FIELDS = {"type", "icon", "startSlot", "confirmationText", "fadeActive", "fadeStartSound", "path", "keepMenuOpen", "menuTag", "noUniqueID"}

-- State -------------------------------------------------------------------------------------------

local active = false
local buttonOptions = {}
local currentRecoveryOptionId = nil
local currentRecoveryOptionTarget = nil
local recoveryRequestSequence = 0
local pendingBridgeVehicle = nil
local bridgeReplyElapsed = 0
local recoveryFadeOwned = false
local recoveryActionRunning = false
local popupData = nil
local quickAccessInitialized = nil
local featureOptionRows = {}
local featureOptionsEnabled = false

-- Feature option manifests ------------------------------------------------------------------------

local function methodName(value)
  return catalog.string(value) and value:match("^[%a_][%w_]*$") ~= nil
end

local function providerPath(value)
  return catalog.string(value) and value:match("^[%a_][%w_/]*$") ~= nil
    and not value:find("//", 1, true) and value:sub(-1) ~= "/"
end

local function validate(data)
  if not methodName(data.owner) then return "owner must be an extension name" end
  if not methodName(data.available) or not methodName(data.run) then return "available and run must name owner functions" end
  if not catalog.string(data.label) or not catalog.number(data.order) then return "label and finite order are required" end
  if data.provider ~= nil and not providerPath(data.provider) then return "provider must be a plain require path" end
  if data.labelFunction ~= nil and not methodName(data.labelFunction) then return "labelFunction must name an owner function" end
  if data.type ~= nil and data.type ~= "vehicle" and data.type ~= "walk" and data.type ~= "none" then return "invalid target type" end
  for _, name in ipairs({"icon", "confirmationText", "fadeStartSound", "path", "menuTag"}) do
    if data[name] ~= nil and not catalog.string(data[name]) then return "invalid " .. name end
  end
  for _, name in ipairs({"fadeActive", "keepMenuOpen", "noUniqueID", "requiresLevel"}) do
    if data[name] ~= nil and type(data[name]) ~= "boolean" then return "invalid " .. name end
  end
  if data.startSlot ~= nil and (not catalog.number(data.startSlot) or data.startSlot < 1 or data.startSlot % 1 ~= 0) then
    return "startSlot must be a positive integer"
  end
end

local function optionApi(entry)
  if not entry.provider then return optional(entry.owner) end
  local ok, provider = pcall(require, entry.provider)
  if not ok then
    catalog.warn(FEATURE_OPTIONS_LOG_TAG, "Provider failed for " .. entry.id .. ": " .. tostring(provider))
    return nil
  end
  return provider
end

local function availableOwner(entry, target)
  local owner = optionApi(entry)
  if type(owner) ~= "table" or type(owner[entry.available]) ~= "function" or type(owner[entry.run]) ~= "function" then return nil end
  if entry.labelFunction and type(owner[entry.labelFunction]) ~= "function" then return nil end
  local ok, available
  if entry.provider then ok, available = pcall(owner[entry.available])
  else ok, available = pcall(owner[entry.available], target) end
  if not ok then
    catalog.warn(FEATURE_OPTIONS_LOG_TAG, "Availability failed for " .. entry.id .. ": " .. tostring(available))
    return nil
  end
  if available then return owner end
end

local function run(entry, target)
  local owner = availableOwner(entry, target)
  if not owner then return false end
  local ok, result
  if entry.provider then ok, result = pcall(owner[entry.run])
  else ok, result = pcall(owner[entry.run], target) end
  if not ok then
    catalog.warn(FEATURE_OPTIONS_LOG_TAG, "Recovery failed for " .. entry.id .. ": " .. tostring(result))
    return false
  end
  return result
end

local function liveLabel(entry, target)
  local owner = optionApi(entry)
  local label = owner and owner[entry.labelFunction]
  if type(label) ~= "function" then return entry.label end
  if entry.provider then return label() end
  return label(target)
end

local function buttonOption(entry)
  local option = {
    label = entry.label,
    order = entry.order,
    type = entry.type or "vehicle",
    active = true,
    enabled = true,
    includeConditions = {function(targetType, vehicleId)
      return availableOwner(entry, {type = targetType, vehId = vehicleId}) ~= nil
    end},
    enableConditions = {},
    atFadeFunction = function(target) return run(entry, target) end,
  }
  if entry.labelFunction then
    option.label = function(_, target) return liveLabel(entry, target) end
  end
  for _, name in ipairs(BUTTON_FIELDS) do
    if entry[name] ~= nil then option[name] = entry[name] end
  end
  return option
end

local function scanFeatureOptions()
  return catalog.scan(FEATURE_OPTIONS_DIR, validate, FEATURE_OPTIONS_LOG_TAG)
end

local function buildFeatureOptions(reservedIds)
  local options = {}
  local entries, rejected = scanFeatureOptions()
  for _, entry in ipairs(entries) do
    -- A row this registry installed earlier is not a collision with a built-in.
    if reservedIds[entry.id] and reservedIds[entry.id] ~= featureOptionRows[entry.id] then
      catalog.warn(FEATURE_OPTIONS_LOG_TAG, "Recovery id is reserved: " .. entry.id)
    elseif not entry.requiresLevel or getCurrentLevelIdentifier() then
      options[entry.id] = buttonOption(entry)
    end
  end
  return options, rejected
end

-- Shared helpers ----------------------------------------------------------------------------------

local function isOverhaulActive()
  return overhaul_shell_gameMode and overhaul_shell_gameMode.isActive() or false
end

local function slowerThan(speedMs)
  local vehicle = getPlayerVehicle(0)
  if vehicle then return vehicle:getVelocity():len() <= speedMs end
  return false
end

local function isOffroadRecoveryTarget(vehId)
  return overhaul_jobs_recovery
    and overhaul_jobs_recovery.isContractTarget
    and overhaul_jobs_recovery.isContractTarget(vehId) == true
end

local function getBusinessFleetVehicleContext(vehId)
  if not (vehId and overhaul_career_business_fleet) then return nil, nil end
  local businessId, vehicleId = overhaul_career_business_fleet.getBusinessVehicleFromSpawnedId(vehId)
  if not businessId or not vehicleId then return nil, nil end

  local vehicles = overhaul_career_business_fleet.getBusinessVehicles(businessId)
  if not vehicles then return businessId, nil end

  vehicleId = tonumber(vehicleId) or vehicleId
  for _, vehicle in ipairs(vehicles) do
    local storedId = tonumber(vehicle.vehicleId) or vehicle.vehicleId
    if storedId == vehicleId then
      return businessId, vehicle
    end
  end

  return businessId, nil
end

local function getTowDestinationBusinessContext(vehId)
  local businessId, vehicle = getBusinessFleetVehicleContext(vehId)
  if not businessId or not vehicle then return nil, nil, nil end
  if overhaul_career_business_manager and overhaul_career_business_manager.getPurchasedBusinesses then
    local manager = overhaul_career_business_manager
    local candidates = {}
    for kind in pairs(manager.getAllBusinessObjects()) do
      if manager.hasFeature(kind, "towDestination") then
        candidates[#candidates + 1] = {type = kind, priority = manager.getTypeData(kind).towPriority or 999}
      end
    end
    table.sort(candidates, function(a, b)
      if a.priority ~= b.priority then return a.priority < b.priority end
      return a.type < b.type
    end)
    for _, instance in ipairs(candidates) do
      local businesses = manager.getPurchasedBusinesses(instance.type) or {}
      if businesses[businessId] then return instance.type, businessId, vehicle end
    end
  end

  return nil, businessId, nil
end

-- Recovery conditions ------------------------------------------------------------------------------

local conditions
conditions = {
  outOfPursuit = function(type, vehId)
    if overhaul_career_police_playerDriving and overhaul_career_police_playerDriving.playerPursuitActive() then
      return false, "Disabled because of police chase."
    end
    return true
  end,
  vehicleSlow = function(type, vehId)
    local veh = scenetree.findObjectById(vehId)
    if veh then
      if veh:getVelocity():len() >= MOVING_SLOWLY_MS then
        return false, "Stop your vehicle."
      end
    end
    return true
  end,
  vehicleStopped = function(type, vehId)
    local veh = scenetree.findObjectById(vehId)
    if veh then
      if veh:getVelocity():len() >= STOPPED_MS then
        return false, "Stop your vehicle completely."
      end
    end
    return true
  end,
  vehicleInInventory = function(type, vehId)
    if isOffroadRecoveryTarget(vehId) then
      return false, "Contract targets must be recovered manually."
    end
    if not (overhaul_career_garage_inventory and overhaul_career_garage_inventory.getInventoryIdFromVehicleId(vehId)) then
      return false, "This vehicle is not in your inventory."
    end
    return true
  end,
  vehicleOwned = function(type, vehId)
    if overhaul_career_garage_inventory then
      local inventoryId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(vehId)
      if inventoryId then
        local vehInfo = overhaul_career_garage_inventory.getVehicles()[inventoryId]
        if vehInfo and vehInfo.owned then return true end
      end
    end
    return false, "You do not own this vehicle."
  end,
  recoverableVehicle = function(_, vehId)
    if isOffroadRecoveryTarget(vehId) then return false, 'Contract targets must be recovered manually.' end
    local inventory = overhaul_career_garage_inventory
    if inventory and inventory.getInventoryIdFromVehicleId(vehId) then return true end
    local tasks = overhaul_career_logistics_vehicleTasks
    if tasks and tasks.isVehicleDeliveryVehicle(vehId) then return true end
    return false, 'This vehicle is not owned, loaned, or part of an active delivery.'
  end,
  favouriteSet = function(type, vehId)
    local favoriteVehicleId = overhaul_career_garage_inventory.getFavoriteVehicle()
    if not favoriteVehicleId then return false, "No favourite vehicle set." end
    local vehInfo = overhaul_career_garage_inventory.getVehicles()[favoriteVehicleId]
    if not vehInfo then return false, "No favourite vehicle set." end
    if vehInfo.timeToAccess
    or not overhaul_career_garage_inventory.getVehicleIdFromInventoryId(favoriteVehicleId) and overhaul_career_repair_insurance.inventoryVehNeedsRepair(favoriteVehicleId) -- vehicle is not spawned and needs a repair
    then
      return false, "Favourite vehicle still in repair."
    end
    return true
  end,
  notTestdriving = function(type, vehId)
    if overhaul_career_market_testDrive and overhaul_career_market_testDrive.isActive() then
      return false, "Disabled during test drive."
    end
    return true
  end,
  duringTestdrive = function(type, vehId)
    if overhaul_career_market_testDrive and overhaul_career_market_testDrive.isActive() then
      return true
    end
    return false
  end,
  towToGarageAllowedByPermission = function(type, vehId)
    if not overhaul_career_permissions then return true end
    local inventoryId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(vehId)
    local reason = overhaul_career_permissions.getStatusForTag("recoveryTowToGarage", {inventoryId = inventoryId, vehId = vehId})
    return reason.allow, reason.label
  end,
  garageTowCanCancelJob = function(type, vehId)
    local allowed, reason = conditions.towToGarageAllowedByPermission(type, vehId)
    if allowed or reason ~= "Cancel current job to tow" then return allowed, reason end
    local general = overhaul_career_logistics_general
    if general and general.isDeliveryModeActive() then return true, reason end
    return false, "Job cargo is still loaded. Unload it before towing."
  end,
  vehicleIsDeliveryVehicle = function(type, vehId)
    if not overhaul_career_logistics_vehicleTasks then return false end
    if overhaul_career_logistics_vehicleTasks.isVehicleDeliveryVehicle(vehId) then
      return true
    end
    return false
  end,
  vehicleIsCarGoTransferVehicle = function(type, vehId)
    return overhaul_career_logistics_vehicleTransfer and overhaul_career_logistics_vehicleTransfer.isActiveTransferVehicle
      and overhaul_career_logistics_vehicleTransfer.isActiveTransferVehicle(vehId) or false
  end,
  vehicleIsNonCarGoDeliveryVehicle = function(type, vehId)
    if not overhaul_career_logistics_vehicleTasks then return false end
    return overhaul_career_logistics_vehicleTasks.isVehicleDeliveryVehicle(vehId)
      and not (overhaul_career_logistics_vehicleTransfer and overhaul_career_logistics_vehicleTransfer.isActiveTransferVehicle
        and overhaul_career_logistics_vehicleTransfer.isActiveTransferVehicle(vehId))
  end,
  vehicleIsTuningShopJobVehicle = function(type, vehId)
    local _, businessId, vehicle = getTowDestinationBusinessContext(vehId)
    if not businessId or not vehicle then return false end
    return true
  end,
  tuningShopTowingUnlocked = function(type, vehId)
    if not overhaul_career_business_skillTree then return false end
    local businessType, businessId = getTowDestinationBusinessContext(vehId)
    if not businessId then return false end
    if not businessType then return false end
    local businessServices = capabilities.get("businessServices")
    local level = businessServices and businessServices.towingLevel(vehId) or 0
    return level and level > 0
  end,
  companyShiftVehicle = function(_, vehId)
    local ok, result = pcall(function()
      local emp = overhaul_career_work_employment
      if not (emp and emp.isOnShift and emp.isOnShift()) then return false end
      if not (overhaul_career_garage_inventory and overhaul_career_garage_inventory.getInventoryIdFromVehicleId) then
        return false
      end
      local inventoryId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(vehId)
      local vehInfo = inventoryId and overhaul_career_garage_inventory.getVehicles()[inventoryId]
      return vehInfo and vehInfo.loanType == "company" or false
    end)
    return ok and result or false
  end
}

-- Recovery prices and settlement -------------------------------------------------------------------

local function getGlobalEconomyIndex()
  return overhaul_career_economy_globalEconomy and overhaul_career_economy_globalEconomy.getGlobalIndex() or 1.0
end

local function isRoadsideAssistanceCovered(vehId)
  if not (overhaul_career_career and overhaul_career_career.isActive() and overhaul_career_repair_insurance and overhaul_career_garage_inventory) then return false end
  local invVehId = vehId and overhaul_career_garage_inventory.getInventoryIdFromVehicleId(vehId)
  if not invVehId then return false end
  return overhaul_career_repair_insurance.isRoadSideAssistanceFree(invVehId) and true or false, invVehId
end

local function recoverRig(target, mode)
  local function validate(vehId)
    local checks = {conditions.outOfPursuit, conditions.notTestdriving, conditions.recoverableVehicle,
      mode == 'road' and conditions.vehicleSlow or conditions.vehicleStopped}
    for _, check in ipairs(checks) do
      local ok, why = check('vehicle', vehId)
      if not ok then return false, why end
    end
    return true
  end
  local covered, invVehId = isRoadsideAssistanceCovered(target.vehId)
  local settled = false
  local ok, reason = rigRecovery.recover(target.vehId, mode, validate, function(success, why, effectiveMode)
    if settled then return end
    settled = true
    if not success then ui_message(why, 8, 'warning'); return end
    effectiveMode = effectiveMode or mode
    local price = math.floor((effectiveMode == 'road' and TOW_TO_ROAD_COST or FLIP_UPRIGHT_COST) * getGlobalEconomyIndex())
    if covered then
      overhaul_career_repair_insurance.useRoadsideAssistance(invVehId)
    elseif overhaul_career_economy_payment then
      overhaul_career_economy_payment.pay({money = {amount = price, canBeNegative = true}}, require("overhaul/lib/finance/metadata").tag({label = effectiveMode == 'road' and 'Towed your vehicle and connected trailers to the road' or 'Flipped your vehicle and connected trailers upright'}, "service", {vehicleObjectId = target.vehId}))
    end
  end)
  if not ok then ui_message(reason, 8, 'warning'); return false end
  return true
end

local function getPriceFunction(basePrice)
  return function(target)
    if target and isRoadsideAssistanceCovered(target.vehId) then
      return {}
    end
    return {money = {amount = math.floor(basePrice * getGlobalEconomyIndex()), canBeNegative = true}}
  end
end

-- Built-in options ---------------------------------------------------------------------------------

local function buildTowToRoadOption()
  return {
    label = _tr("ui.career.towToRoad"),
    type = "vehicle",
    includeConditions = {},
    enableConditions = {conditions.outOfPursuit, conditions.vehicleSlow, conditions.notTestdriving, conditions.recoverableVehicle},
    atFadeFunction = function(target)
      return recoverRig(target, 'road')
    end,
    order = 5,
    startSlot = 7,
    active = true,
    enabled = true,
    fadeActive = true,
    fadeStartSound = "event:>UI>Missions>Vehicle_Recover",
    icon = "road",
    isRecoveryOption = true,
    confirmationText = "Tow this vehicle, its connected trailers, and recognized carried vehicles to the nearest road? Your deliveries stay active.",
    price = getPriceFunction(TOW_TO_ROAD_COST)
  }
end

local function buildFlipUprightOption()
  return {
    label = _tr("ui.radialmenu2.flipVehicleUpright"),
    type = "vehicle",
    includeConditions = {},
    enableConditions = {conditions.outOfPursuit, conditions.vehicleStopped, conditions.recoverableVehicle, conditions.notTestdriving},
    atFadeFunction = function(target)
      return recoverRig(target, 'upright')
    end,
    order = 15,
    startSlot = 3,
    active = true,
    enabled = true,
    fadeActive = true,
    isRecoveryOption = true,
    fadeStartSound = "event:>UI>Missions>Vehicle_Flip",
    icon = "carToWheels",
    confirmationText = "Flip this vehicle and its connected trailers upright, retaining recognized carried vehicles? Your deliveries stay active.",
    price = getPriceFunction(FLIP_UPRIGHT_COST)
  }
end

local function buildGetFavoriteVehicleOption()
  return {
    type = "walk",
    label = _tr("ui.career.getFavoriteVehicle"),
    includeConditions = {},
    enableConditions = {conditions.outOfPursuit, conditions.favouriteSet, conditions.notTestdriving},
    atFadeFunction = function() overhaul_career_police_playerDriving.retrieveFavoriteVehicle() end,

    order = 11,
    active = false,
    enabled = true,
    fadeActive = true,
    icon = "carStarred",
    confirmationText = "Do you want to retrieve your favorite vehicle?",
    price = function()
      return overhaul_career_police_playerDriving.getFavoriteVehicleRetrievalPrice()
    end
  }
end

local function buildFlipMissionOption()
  return {
    type = "vehicle",
    label = _tr("ui.radialmenu2.flipVehicleUpright"),
    includeConditions = {},
    enableConditions = {conditions.vehicleStopped},
    atFadeFunction = nop,
    order = 5,
    startSlot = 3,
    active = false,
    enabled = true,
    fadeActive = true,
    fadeStartSound = "event:>UI>Missions>Vehicle_Flip",
    icon = "carToWheels"
  }
end

local function buildRecoverMissionOption()
  return {
    type = "vehicle",
    label = _tr("ui.radialmenu2.recoverToLastRoad"),
    includeConditions = {},
    enableConditions = {conditions.vehicleSlow},
    atFadeFunction = nop,
    order = 7,
    startSlot = 7,
    active = false,
    enabled = true,
    fadeActive = true,
    fadeStartSound = "event:>UI>Missions>Vehicle_Recover",
    icon = "car"
  }
end

local function buildSubmitMissionOption()
  return {
    type = "none",
    label = _tr("missions.missions.recoveryPrompt.submitScore"),
    includeConditions = {},
    enableConditions = {},
    atFadeFunction = nop,
    order = 10,
    startSlot = 5,
    active = false,
    enabled = true,
    fadeActive = false,
    icon = "checkboxOn"
  }
end

local function buildRestartMissionOption()
  return {
    type = "none",
    label = _tr("missions.missions.recoveryPrompt.restartMission"),
    includeConditions = {},
    enableConditions = {},
    atFadeFunction = nop,
    order = 2,
    startSlot = 1,
    active = false,
    enabled = true,
    fadeActive = false,
    icon = "restart"
  }
end

local function buildRepairHereOption()
  return {
    type = "vehicle",
    label = _tr("ui.mission.panel.repair"),
    atFadeFunction = function()
      if overhaul_career_career.isActive() then return end
      local veh = getPlayerVehicle(0)
      if veh then
        spawn.safeTeleport(veh, veh:getPosition(), quatFromDir(veh:getDirectionVector()), nil, nil, nil, nil, true )
        extensions.hook("onRecoveryPromptRepairHereUsed")
      end
    end,
    includeConditions = {function() return not overhaul_career_career.isActive() end},
    enableConditions = {conditions.vehicleSlow, function(_, vehId)
      if isOffroadRecoveryTarget(vehId) then
        return false, "Contract targets cannot be repaired during recovery."
      end
      return true
    end},
    order = 10,
    active = true,
    isRecoveryOption = true,
    enabled = true,
    fadeActive = true,
    fadeStartSound = "event:>UI>Missions>Vehicle_Recover",
    icon = "wrench"
  }
end

local function buildResetVehicleOption()
  return {
    type = "vehicle",
    label = _tr("ui.common.resetVehicle"),
    includeConditions = {},
    enableConditions = {},
    atFadeFunction = function()
      if settings.getValue("enableSmartRecovery", true) and spawn and type(spawn.safeReset) == "function" then
        local vehicle = getPlayerVehicle(0)
        if vehicle then spawn.safeReset(vehicle) else be:resetVehicle(0) end
      else
        be:resetVehicle(0)
      end
    end,
    order = 20,
    active = false,
    enabled = true,
    fadeActive = true
  }
end

local function buildStopTestdriveOption()
  return {
    type = "none",
    label = _tr("ui.career.testDrive.stopTestDrive"),
    atFadeFunction = function()
      overhaul_career_market_testDrive.stop(true)
    end,
    includeConditions = {conditions.duringTestdrive},
    enableConditions = {},
    order = 10,
    active = true,
    enabled = true,
    fadeActive = true,
    icon = "restart"
  }
end

local function buildGiveBackDeliveryVehicleOption()
  return {
    type = "vehicle",
    label = "Discard Delivery Vehicle",
    atFadeFunction = function(target)
      overhaul_career_logistics_vehicleTasks.giveBackDeliveryVehicle(target.vehId)
    end,
    includeConditions = {conditions.outOfPursuit, conditions.vehicleIsNonCarGoDeliveryVehicle},
    enableConditions = {conditions.vehicleSlow},
    order = 10,
    active = true,
    enabled = true,
    fadeActive = true,
    icon = "restart"
  }
end

local function buildReportUndeliverableOption()
  return {
    type = "vehicle",
    label = "Report undeliverable",
    atFadeFunction = function(target)
      overhaul_career_logistics_vehicleTransfer.reportUndeliverable(target.vehId)
    end,
    includeConditions = {conditions.outOfPursuit, conditions.vehicleIsCarGoTransferVehicle},
    enableConditions = {conditions.vehicleSlow},
    order = 10,
    active = true,
    enabled = true,
    fadeActive = true,
    icon = "restart"
  }
end

local function buildReturnLoanedVehicleOption()
  return {
    label = "Return loaned vehicle",
    type = "vehicle",
    includeConditions = {function(_, vehId) return conditions.vehicleInInventory(_, vehId) and not conditions.vehicleOwned(_, vehId) end},
    enableConditions = {conditions.outOfPursuit, conditions.vehicleStopped, conditions.notTestdriving},
    atFadeFunction = function(target)
      if overhaul_career_garage_inventory then
        local inventoryId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(target.vehId)
        if inventoryId then
          overhaul_career_logistics_loanerVehicles.returnVehicle(inventoryId)
        end
      end
    end,
    order = 5,
    active = true,
    enabled = true,
    fadeActive = true,
    fadeStartSound = "event:>UI>Missions>Vehicle_Recover",
    icon = "car",
    confirmationText = "Do you want to return this loaned vehicle?"
  }
end

local function buildTowToTuningShopOption()
  return {
    label = function(options, target)
      local allowed, reason = conditions.towToGarageAllowedByPermission("vehicle", target.vehId)
      if not allowed and reason then return reason end
      local businessType, businessId = getTowDestinationBusinessContext(target.vehId)
      if businessType and businessId and overhaul_world_facilities then
        local facility = overhaul_world_facilities.getFacility(businessType, businessId)
        if facility and facility.name then
          local localizedName = translateLanguage and translateLanguage(facility.name, facility.name, true) or facility.name
          return string.format("Tow to %s", localizedName)
        end
        local manager = overhaul_career_business_manager
        if manager and manager.hasFeature(businessType, "towDestination") then
          local descriptor = manager.getTypeData(businessType)
          if descriptor and descriptor.towLabel then return descriptor.towLabel end
        end
      end
      return "Tow to Tuning Shop"
    end,
    type = "vehicle",
    includeConditions = {conditions.vehicleIsTuningShopJobVehicle, conditions.tuningShopTowingUnlocked},
    enableConditions = {conditions.outOfPursuit, conditions.vehicleSlow, conditions.notTestdriving, conditions.garageTowCanCancelJob},
    atFadeFunction = function(target)
      local businessType, businessId, vehicle = getTowDestinationBusinessContext(target.vehId)
      if not (businessType and businessId and vehicle and overhaul_career_business_fleet) then return end
      local allowed, reason = conditions.towToGarageAllowedByPermission("vehicle", target.vehId)
      if not allowed and reason == "Cancel current job to tow" then
        overhaul_career_logistics_cargoScreen.exitDeliveryMode()
        allowed = conditions.towToGarageAllowedByPermission("vehicle", target.vehId)
      end
      if not allowed then return end
      local veh = scenetree.findObjectById(target.vehId)
      if veh and overhaul_career_business_fleet.teleportToBusinessGarage(businessType, businessId, veh, true) then
        ui_message("ui.career.towed", 5, "recoveryPromptMessage")
      end
    end,
    order = 12,
    startSlot = 7,
    active = true,
    enabled = true,
    fadeActive = true,
    fadeStartSound = "event:>UI>Missions>Vehicle_Recover",
    icon = "tow",
    confirmationText = "Tow to the business facility? Any active delivery job will be cancelled with its normal money and reputation penalties.",
    menuTag = "towing",
    path = "towing/",
  }
end

local function setupButtonOptions()
  buttonOptions = {
    towToRoad = buildTowToRoadOption(),
    flipUpright = buildFlipUprightOption(),
    getFavoriteVehicle = buildGetFavoriteVehicleOption(),
    flipMission = buildFlipMissionOption(),
    recoverMission = buildRecoverMissionOption(),
    submitMission = buildSubmitMissionOption(),
    restartMission = buildRestartMissionOption(),
    repairHere = buildRepairHereOption(),
    resetVehicle = buildResetVehicleOption(),
    stopTestdrive = buildStopTestdriveOption(),
    giveBackDeliveryVehicle = buildGiveBackDeliveryVehicleOption(),
    reportUndeliverable = buildReportUndeliverableOption(),
    returnLoanedVehicle = buildReturnLoanedVehicleOption(),
    towToTuningShop = buildTowToTuningShopOption(),
  }
  -- Registry owner options retain the original default-row creation boundary.
  for id, option in pairs(buildFeatureOptions(buttonOptions)) do
    if option.menuTag ~= "quickTravel" then
      buttonOptions[id], featureOptionRows[id] = option, option
    end
  end
end

-- Garage towing and quick travel -------------------------------------------------------------------

local function updateTuningShopTowButton(newVehId)
  if not buttonOptions.towToTuningShop then return end
  local vehId = newVehId or be:getPlayerVehicleID(0)
  local businessType, businessId, vehicle = getTowDestinationBusinessContext(vehId)
  local activeState = false
  if businessType and businessId and vehicle and overhaul_career_business_skillTree then
    local businessServices = capabilities.get("businessServices")
    local level = businessServices and businessServices.towingLevel(vehId) or 0
    activeState = level and level > 0
  end
  buttonOptions.towToTuningShop.active = activeState and true or false
end

local function clearDynamicGarageButtons(prefix, keepIds)
  local toRemove = {}
  for id in pairs(buttonOptions) do
    if type(id) == "string" and id:sub(1, #prefix) == prefix and not (keepIds and keepIds[id])
        and featureOptionRows[id] ~= buttonOptions[id] then
      table.insert(toRemove, id)
    end
  end
  for _, id in ipairs(toRemove) do
    buttonOptions[id] = nil
  end
end

local function buildGarageTowOption(garage, discoveredGarages)
  local function getPrice(target)
    if overhaul_career_repair_insurance.isRoadSideAssistanceFree(overhaul_career_garage_inventory.getInventoryIdFromVehicleId(target.vehId)) then
      return {}
    end
    local price = overhaul_career_garage_quickTravel.getPriceForQuickTravelToGarage(garage)
    price = math.max(0, tonumber(price) or 0) +
      math.floor(BASE_TOW_TO_GARAGE_COST * getGlobalEconomyIndex() * 100 + 0.5) / 100
    return {money = {amount = price, canBeNegative = true}}
  end
  return {
    type = "vehicle",
    label = function(options, target)
      local allowed, reason = conditions.towToGarageAllowedByPermission("vehicle", target.vehId)
      if not allowed and reason then return reason end
      return string.format("%s", _tr(garage.name))
    end,
    includeConditions = {},
    menuTag = "towing",
    enableConditions = {conditions.outOfPursuit, conditions.vehicleSlow, conditions.vehicleInInventory, conditions.notTestdriving, conditions.garageTowCanCancelJob},
    atFadeFunction = function(target)
      local invVehId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(target.vehId)
      local allowed, reason = conditions.towToGarageAllowedByPermission("vehicle", target.vehId)
      if not allowed and reason == "Cancel current job to tow" then
        overhaul_career_logistics_cargoScreen.exitDeliveryMode()
        allowed = conditions.towToGarageAllowedByPermission("vehicle", target.vehId)
      end
      if not allowed then return end
      local coveredByInsurance = overhaul_career_repair_insurance.isRoadSideAssistanceFree(invVehId)
      local price = getPrice(target)
      overhaul_career_police_playerDriving.teleportToGarage(garage.id, scenetree.findObjectById(target.vehId), false, function(success)
        if not success then return end
        if coveredByInsurance then
          overhaul_career_repair_insurance.useRoadsideAssistance(invVehId)
        else
          overhaul_career_economy_payment.pay(price, require("overhaul/lib/finance/metadata").tag({label = "Towed your vehicle to your garage"}, "service", {vehicleObjectId = target.vehId}))
        end
        ui_message(_tr("ui.career.towed"), 5, "info")
      end)
    end,
    order = discoveredGarages,
    active = true,
    enabled = true,
    fadeActive = true,
    fadeStartSound = "event:>UI>Missions>Vehicle_Recover",
    icon = discoveredGarages <= 9 and ("garageNumber"..discoveredGarages) or "house",
    price = getPrice,
    confirmationText = "Tow to this garage? Any active delivery job will be cancelled with its normal money and reputation penalties.",
    path = "towing/",
    noUniqueID = true,
  }
end

local function addTowingButtons()
  if not getCurrentLevelIdentifier() then return end
  -- Sold garages must disappear from the next menu.
  clearDynamicGarageButtons("towTo", { towToRoad = true, towToTuningShop = true })
  local garages = overhaul_world_facilities.getFacilitiesByType("garage")
  local discoveredGarages = 0
  for _, garage in ipairs(garages) do
    if not garage.noQuickTravel then
      if overhaul_career_garage_garageManager and overhaul_career_garage_garageManager.isAccessibleGarage(garage.id) then
        discoveredGarages = discoveredGarages + 1
        buttonOptions[string.format("towTo%s", garage.id)] = buildGarageTowOption(garage, discoveredGarages)
      end
    end
  end
end

local function buildGarageTravelOption(garage, discoveredGarages)
  return {
    type = "walk",
    label = function(options)
      return string.format("%s", _tr(garage.name))
    end,
    includeConditions = {},
    menuTag = "quickTravel",
    enableConditions = {},
    atFadeFunction = function()
      overhaul_career_garage_quickTravel.quickTravelToGarage(garage)
    end,
    order = discoveredGarages,
    active = true,
    enabled = true,
    fadeActive = true,
    fadeStartSound = "event:>UI>Missions>Vehicle_Recover",
    icon = discoveredGarages <= 9 and ("garageNumber"..discoveredGarages) or "house",
    price = function() return {money = {amount = overhaul_career_garage_quickTravel.getPriceForQuickTravelToGarage(garage)}} end,
    confirmationText = "Do you want to quick travel?",
    path = "quickTravel/",
    noUniqueID = true,
  }
end

local function lastVehicleTravelPrice()
  local lastVehicleId = overhaul_career_garage_inventory.getLastVehicle()
  local vehObjId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(lastVehicleId)
  if vehObjId then
    local vehObj = getObjectByID(vehObjId)
    local pos = vehObj:getPosition()
    local price = overhaul_career_garage_quickTravel.getPriceForQuickTravel(pos)
    return {money = {amount = price}}
  end
  return {}
end

local function employerTarget()
  local employment = overhaul_career_work_employment
  return employment and employment.getEmployerQuickTravelTarget and employment.getEmployerQuickTravelTarget()
end

local function buildEmployerTravelOption()
  return {
    type = "walk",
    label = function(options)
      local target = employerTarget()
      return target and target.label or "Your employer"
    end,
    includeConditions = {},
    menuTag = "quickTravel",
    enableConditions = {},
    atFadeFunction = function()
      local target = employerTarget()
      if target then
        overhaul_career_garage_quickTravel.quickTravelToPos(target.pos, true, "Quick traveled to your employer", target.rot)
      end
    end,
    order = 20,
    active = true,
    enabled = function() return employerTarget() ~= nil end,
    fadeActive = true,
    fadeStartSound = "event:>UI>Missions>Vehicle_Recover",
    icon = "boxTruck",
    price = function()
      local target = employerTarget()
      if not target then return {} end
      return {money = {amount = overhaul_career_garage_quickTravel.getPriceForQuickTravel(target.pos)}}
    end,
    confirmationText = "Do you want to quick travel?",
    path = "quickTravel/",
    noUniqueID = true,
  }
end

local function buildLastVehicleTravelOption()
  return {
    type = "walk",
    label = function(options)
      return "Your last vehicle"
    end,
    includeConditions = {},
    menuTag = "quickTravel",
    enableConditions = {},
    atFadeFunction = function()
      local lastVehicleId = overhaul_career_garage_inventory.getLastVehicle()
      local vehObjId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(lastVehicleId)
      if vehObjId then
        local vehObj = getObjectByID(vehObjId)
        local vehPos = vehObj:getPosition()
        local spawnPos = vehPos
        local forward = vehObj:getDirectionVector()
        if forward then
          local right = forward:cross(vec3(0, 0, 1))
          if right:length() > 1e-4 then
            right:normalize()
            spawnPos = vehPos + right * 2.5
          end
        end
        overhaul_career_garage_quickTravel.quickTravelToPos(spawnPos, true, "Quick traveled to your vehicle", nil, vehPos)
      end
    end,
    order = 25,
    active = true,
    enabled = function()
      local lastVehicleId = overhaul_career_garage_inventory.getLastVehicle()
      return overhaul_career_garage_inventory.getVehicleIdFromInventoryId(lastVehicleId)
    end,
    fadeActive = true,
    fadeStartSound = "event:>UI>Missions>Vehicle_Recover",
    icon = "car",
    price = lastVehicleTravelPrice,
    confirmationText = "Do you want to quick travel?",
    path = "quickTravel/",
    noUniqueID = true,
  }
end

local function addQuickTravelButtons()
  if not getCurrentLevelIdentifier() then return end
  -- Sold garages must disappear from the next menu.
  clearDynamicGarageButtons("quickTravelTo", { quickTravelToVehicle = true })
  local garages = overhaul_world_facilities.getFacilitiesByType("garage")
  local discoveredGarages = 0
  for _, garage in ipairs(garages) do
    if not garage.noQuickTravel then
      if overhaul_career_garage_garageManager and overhaul_career_garage_garageManager.isAccessibleGarage(garage.id) then
        discoveredGarages = discoveredGarages + 1
        buttonOptions[string.format("quickTravelTo%s", garage.id)] = buildGarageTravelOption(garage, discoveredGarages)
      end
    end
  end
  if employerTarget() then buttonOptions.quickTravelToEmployer = buildEmployerTravelOption() end
  buttonOptions.quickTravelToVehicle = buildLastVehicleTravelOption()
  -- Public quick-travel rebuilds also create registry actions at the former built-in creation boundary.
  for id, option in pairs(featureOptionRows) do
    if option.menuTag == "quickTravel" then
      if buttonOptions[id] == option then buttonOptions[id] = nil end
      featureOptionRows[id] = nil
    end
  end
  for id, option in pairs(buildFeatureOptions(buttonOptions)) do
    if option.menuTag == "quickTravel" then
      buttonOptions[id], featureOptionRows[id] = option, option
    end
  end
end

-- Per-frame update --------------------------------------------------------------------------------

local function refreshFeatureOptions(resetActive)
  local previousActive = {}
  for id, previousOption in pairs(featureOptionRows) do
    previousActive[id] = previousOption.active
    if buttonOptions[id] == previousOption then buttonOptions[id] = nil end
  end
  featureOptionRows = {}
  local careerActive = active and overhaul_career_career.isActive()
  for id, option in pairs(buildFeatureOptions(buttonOptions)) do
    if careerActive or option.menuTag ~= "quickTravel" then
      if not resetActive and previousActive[id] ~= nil then
        option.active = previousActive[id]
      else
        option.active = featureOptionsEnabled
      end
      buttonOptions[id] = option
      featureOptionRows[id] = option
    end
  end
end

-- Career lifecycle --------------------------------------------------------------------------------

local function setDefaultsForFreeroam()
  active = false
  featureOptionsEnabled = false
  for _, option in pairs(buttonOptions) do option.active = false end
  updateTuningShopTowButton()
  refreshFeatureOptions()
end

local function setDefaultsForCareer()
  active = true
  featureOptionsEnabled = true
  for _, option in pairs(buttonOptions) do option.active = false end
  buttonOptions.towToRoad.active = true
  buttonOptions.flipUpright.active = true

  buttonOptions.getFavoriteVehicle.active = true
  buttonOptions.stopTestdrive.active = true
  buttonOptions.giveBackDeliveryVehicle.active = true
  buttonOptions.reportUndeliverable.active = true
  buttonOptions.returnLoanedVehicle.active = true
  if buttonOptions.reportCompanyAccident then
    buttonOptions.reportCompanyAccident.active = true
  end
  addTowingButtons()
  addQuickTravelButtons()
  updateTuningShopTowButton()
  refreshFeatureOptions(true)
end

local function deactivateAllButtons()
  featureOptionsEnabled = false
  for _, option in pairs(buttonOptions) do option.active = false end
end

local function setButtonActiveById(id, activeState)
  if not buttonOptions[id] then log("W","","Tried to set active for button, but the id couldnt be found: " .. dumps(id)) return end
  buttonOptions[id].active = activeState
end

-- Fade handling ------------------------------------------------------------------------------------

local function clearPendingRecovery()
  recoveryRequestSequence = recoveryRequestSequence + 1
  currentRecoveryOptionId = nil
  currentRecoveryOptionTarget = nil
  pendingBridgeVehicle = nil
  bridgeReplyElapsed = 0
end

local function stopRecoveryFade()
  if not recoveryFadeOwned then return end
  -- Relinquish ownership before calling out: stop can raise or emit fade hooks.
  recoveryFadeOwned = false
  ui_fadeScreen.stop(FADE_SECONDS)
end

local function recoveryFailed(optionId, err)
  clearPendingRecovery()
  popupData = nil
  local stopped, stopErr = pcall(stopRecoveryFade)
  log("E", "recoveryPrompt", "Recovery option " .. tostring(optionId) .. " failed: " .. tostring(err)
    .. (not stopped and ("; could not release fade: " .. tostring(stopErr)) or ""))
end

local function onUpdate(dtReal, dtSim)
  if pendingBridgeVehicle then
    bridgeReplyElapsed = bridgeReplyElapsed + (dtReal or 0)
    if getPlayerVehicle(0) ~= pendingBridgeVehicle then
      recoveryFailed(currentRecoveryOptionId, "Bridge vehicle was removed or replaced")
    elseif bridgeReplyElapsed >= BRIDGE_REPLY_TIMEOUT_SECONDS then
      recoveryFailed(currentRecoveryOptionId, "Vehicle bridge did not reply in time")
    end
  end
  if isOverhaulActive() then rigRecovery.update(dtSim) end
end

local function buttonPressed(buttonId, target)
  local option = buttonOptions[buttonId]
  if not option or currentRecoveryOptionId or recoveryActionRunning then return end
  local bridgeVehicle = option.fadeActive and getPlayerVehicle(0) or nil
  if option.fadeActive and not bridgeVehicle then
    log("W", "recoveryPrompt", "Recovery option " .. tostring(buttonId) .. " has no bridge vehicle")
    return
  end
  if overhaul_career_career and overhaul_career_career.isActive() and not gameplay_walk.isWalking() and not overhaul_integration_services_missions_missionManager.getForegroundMissionId() then
    core_vehicleBridge.executeAction(getPlayerVehicle(0), 'createPartConditionSnapshot', "beforeTeleport")
    core_vehicleBridge.executeAction(getPlayerVehicle(0), 'setPartConditionResetSnapshotKey', "beforeTeleport")
  end

  currentRecoveryOptionId = buttonId
  currentRecoveryOptionTarget = target
  recoveryRequestSequence = recoveryRequestSequence + 1
  local sequence = recoveryRequestSequence
  local function stillPending()
    return recoveryRequestSequence == sequence and currentRecoveryOptionId == buttonId
      and currentRecoveryOptionTarget == target
  end
  if option.fadeActive then
    pendingBridgeVehicle = bridgeVehicle
    bridgeReplyElapsed = 0
    local pingHandled = false
    local function onPing()
      if pingHandled or not stillPending() then return end
      pingHandled = true
      if getPlayerVehicle(0) ~= bridgeVehicle then recoveryFailed(buttonId, "Bridge vehicle was removed or replaced") return end
      pendingBridgeVehicle = nil
      bridgeReplyElapsed = 0
      if buttonOptions[buttonId] ~= option then recoveryFailed(buttonId, "Option is no longer available") return end
      local ok, err = xpcall(function()
        if option.fadeStartSound then Engine.Audio.playOnce('AudioGui', option.fadeStartSound) end
        -- Audio and extension callbacks may cancel or unload this request.
        if not stillPending() then return end
        if getPlayerVehicle(0) ~= bridgeVehicle then recoveryFailed(buttonId, "Bridge vehicle was removed or replaced") return end
        if buttonOptions[buttonId] ~= option then recoveryFailed(buttonId, "Option is no longer available") return end
        -- Own the start attempt too, so a partially-started throwing fade is released.
        recoveryFadeOwned = true
        ui_fadeScreen.start(FADE_SECONDS)
      end, debug.traceback)
      if not ok and stillPending() then recoveryFailed(buttonId, err) end
    end
    local ok, err = xpcall(function()
      core_vehicleBridge.requestValue(bridgeVehicle, onPing, 'ping')
    end, debug.traceback)
    if not ok and stillPending() then recoveryFailed(buttonId, err) end
  else
    M.handleCurrRecoveryOption()
  end
end

local function onPopupClosed()
  clearPendingRecovery()
  popupData = nil
  local stopped, err = pcall(stopRecoveryFade)
  if not stopped then log("E", "recoveryPrompt", "Could not release recovery fade: " .. tostring(err)) end
end

local function handleCurrRecoveryOption()
  -- Fade events are global; another system may fade while our ping is queued.
  if not currentRecoveryOptionId or pendingBridgeVehicle or recoveryActionRunning then return end
  local optionId = currentRecoveryOptionId
  local target = currentRecoveryOptionTarget
  local sequence = recoveryRequestSequence
  local function stillCurrent() return recoveryRequestSequence == sequence end
  local option = buttonOptions[optionId]
  if option and option.fadeActive and not recoveryFadeOwned then return end
  recoveryActionRunning = true
  -- Keep the pending ID during the callback so its reset cannot reopen the radial,
  -- but release it even when an action, hook or UI operation raises an error.
  local ok, err = xpcall(function()
    extensions.hook("onRecoveryPromptButtonPressed", optionId)
    if not stillCurrent() then return end
    if option then
      option.atFadeFunction(target)
      if not stillCurrent() then return end
      if option.count then
        option.count = option.count + 1
      end
      if option.message then
        ui_message(option.message, 5, "recoveryPromptMessage")
        if not stillCurrent() then return end
      end
      if option.fadeActive then
        stopRecoveryFade()
        if not stillCurrent() then return end
        ui_router.reload()
      end
    else
      log("E","","Couldnt use recovery option. none was found for ID " .. tostring(optionId))
    end
  end, debug.traceback)
  if not stillCurrent() then recoveryActionRunning = false return end
  clearPendingRecovery()
  if not ok or not option or not option.keepMenuOpen then
    onPopupClosed()
  end
  if not ok then
    recoveryFailed(optionId, err)
    recoveryActionRunning = false
    return
  end
  recoveryActionRunning = false
  if not option then return end
  overhaul_integration_services_markerInteraction.setForceReevaluateOpenPrompt()
end

local function onScreenFadeState(state)
  if state == 1 and recoveryFadeOwned then handleCurrRecoveryOption() end
end

-- Menu projections ---------------------------------------------------------------------------------

local function getRecoveryTargets()
  if not gameplay_walk.isWalking() then
    return {{type = "vehicle", vehId = be:getPlayerVehicleID(0)}}
  end
  walkTarget.dropDeletedVehicleInFront(gameplay_walk)
  local vehInFront = gameplay_walk.getVehicleInFront()
  if vehInFront then
    return {
      {type = "vehicle", vehId = vehInFront:getId()},
      {type = "walk"}
    }
  else
    return {{type = "walk"}}
  end
end

local function sortByOrder(a, b) return a.order < b.order end

local function optionIncludesTarget(option, target)
  for _, condition in ipairs(option.includeConditions or {}) do
    if not condition(target.type, target.vehId) then return false end
  end
  return true
end

local function targetOptionPresentation(option, target)
  local enabled = type(option.enabled) == "function" and option.enabled(option, target) or option.enabled
  local reason = nil
  for _, condition in ipairs(option.enableConditions or {}) do
    local allowed, detail = condition(target.type, target.vehId)
    enabled = allowed and enabled
    reason = reason or detail
  end
  local label = type(option.label) == "function" and option.label(option, target) or option.label
  if option.limit then
    label = {txt = 'missions.missions.recoveryPrompt.remainingUses', context = {label = label, count = option.limit - option.count}}
    enabled = enabled and option.count < option.limit
  end
  local price = nil
  if overhaul_career_career.isActive() then
    price = type(option.price) == "function" and option.price(target) or option.price
  end
  if price and overhaul_career_economy_payment and not overhaul_career_economy_payment.canPay(price) then
    enabled = false
    reason = "Insufficient funds"
  end
  return label, enabled, reason or (not enabled and "Disabled"), price
end

local function targetButton(id, option, target)
  local label, enabled, disableReason, price = targetOptionPresentation(option, target)
  local button = {
    id = id,
    targetType = target.type,
    targetVehId = target.vehId,
    label = label,
    luaCallback = function() overhaul_ui_recoveryPrompt.buttonPressed(id, target) end,
    order = option.order,
    startSlot = option.startSlot or 1,
    keepMenuOpen = option.keepMenuOpen,
    price = price,
    enabled = enabled,
    disableReason = disableReason,
    soundClass = (option.fadeStartSound and "bng_click_empty" or nil),
    icon = option.icon,
    confirmationText = option.confirmationText,
    ["goto"] = option["goto"],
    path = option.path,
    uniqueID = "recovery_" .. id .. "_" .. dumps(target),
  }
  if option.noUniqueID then button.uniqueID = nil end
  return button
end

local function getButtonsForTarget(target)
  local buttons = {}
  for id, option in pairs(buttonOptions) do
    if (option.type or "none") == target.type and option.active and optionIncludesTarget(option, target) then
      table.insert(buttons, targetButton(id, option, target))
    end
  end
  table.sort(buttons, sortByOrder)
  return buttons
end

local function getDemoDerbyController()
  local derby = rawget(_G, "overhaul_events_derby_derby")
  if type(derby) ~= "table" then
    return nil
  end
  return derby
end

local function isDemoDerbyRecoveryOverrideActive()
  local derby = getDemoDerbyController()
  if not derby or type(derby.isRecoveryRadialOverrideActive) ~= "function" then
    return false
  end
  local ok, activeState = pcall(derby.isRecoveryRadialOverrideActive)
  return ok and activeState == true
end

local function createPopupData()
  popupData = nil
  if not active then return false end

  if isDemoDerbyRecoveryOverrideActive() then
    return false
  end

  local buttons = {}
  local targets = getRecoveryTargets()
  for i, target in ipairs(targets) do
    for _, btn in ipairs(getButtonsForTarget(target)) do
      table.insert(buttons, btn)
    end
  end
  for _, btn in ipairs(getButtonsForTarget({type="none"})) do
    table.insert(buttons, btn)
  end
  if not next(buttons) then
    log("W","","Tried to open recovery prompt, but no buttons were active. Not opening prompt.")
    return false
  end

  if next(buttons) then
    buttons[1].default = true
  end

  popupData = {title = title or "Recovery Menu", buttons = buttons}
  return true
end

local careerPauseActionIds = {
  flipUpright = true,
  towToRoad = true,
}

local function makePauseRightRailButton(button)
  return {
    id = button.id,
    title = button.label,
    icon = button.icon,
    holdToClick = button.confirmationText,
    enabled = button.enabled,
    disableReason = button.disableReason,
    order = button.order,
    startSlot = button.startSlot,
    targetType = button.targetType,
    targetVehId = button.targetVehId,
  }
end

local function getPauseCareerRightRailButtons()
  local buttons = {}
  local playerVehId = be:getPlayerVehicleID(0)

  if playerVehId and playerVehId >= 0 then
    for _, button in ipairs(getButtonsForTarget({type = "vehicle", vehId = playerVehId})) do
      if careerPauseActionIds[button.id] then
        table.insert(buttons, makePauseRightRailButton(button))
      end
    end
  end

  table.sort(buttons, sortByOrder)
  return buttons
end

-- Radial menus -------------------------------------------------------------------------------------

local function onResetGameplay(playerID)
  if active and not currentRecoveryOptionId and not recoveryActionRunning then
    local root = "/root/sandbox/quick/"
    if overhaul_career_career.isActive() then
      root = "/root/sandbox/career/"
    end
    if overhaul_integration_services_missions_missionManager.getForegroundMissionId() then
      root = "/root/sandbox/mission/"
    end
    core_quickAccess.setEnabled(true, root)
  end
end

local function radialEntry(button)
  return {
    title = button.label,
    icon = button.icon,
    priority = 90,
    holdToClick = button.confirmationText,
    price = button.price,
    enabled = button.enabled,
    startSlot = button.startSlot,
    ["goto"] = button["goto"],
    disableReason = button.disableReason,
    uniqueID = button.uniqueID,
    ignoreAsRecentActionForCategory = "sandbox",
    onSelect = function()
      button.luaCallback()
      return button.keepMenuOpen and {"reload"} or {"hide"}
    end,
  }
end

local function registerRadialLevel(context, level)
  core_quickAccess.addEntry({
    level = context.root .. (level or ""),
    generator = function(entries)
      if not context.enabled() then return end
      if level and isDemoDerbyRecoveryOverrideActive() then return end
      createPopupData()
      if not popupData then return end
      for _, button in ipairs(popupData.buttons or {}) do
        if button.path == level then table.insert(entries, radialEntry(button)) end
      end
    end,
  })
end

local function registerRadialParent(root, level)
  local name, icon = nil, nil
  if level == "quickTravel/" then name, icon = "Quick Travel", "fastTravel" end
  if level == "towing/" then name, icon = "Towing", "tow" end
  -- This replaces a stock id, so its parent must remain available outside Overhaul.
  core_quickAccess.addEntry({
    level = root,
    uniqueID = name .. "unique",
    generator = function(entries)
      if isOverhaulActive() and isDemoDerbyRecoveryOverrideActive() then return end
      table.insert(entries, {title = name, icon = icon, ["goto"] = root .. level, uniqueID = name .. "unique"})
    end,
  })
end

local function addButtonsForLevel(level)
  for _, context in ipairs({
    {
      root = "/root/sandbox/career/",
      enabled = function() return isOverhaulActive() and overhaul_career_career.isActive() and not overhaul_integration_services_missions_missionManager.getForegroundMissionId() end,
    },
    {
      root = "/root/sandbox/mission/",
      enabled = function() return isOverhaulActive() and overhaul_integration_services_missions_missionManager.getForegroundMissionId() end,
    },
  }) do
    registerRadialLevel(context, level)
    if level then registerRadialParent(context.root, level) end
  end
end

-- Game lifecycle -----------------------------------------------------------------------------------

local function onExtensionLoaded()
  setupButtonOptions()
  overhaul_shell_patches.registerFields(PATCH_ID, function() return core_recoveryPrompt end, {
    onResetGameplay = function(original)
      return function(...)
        if isOverhaulActive() then return M.handleResetGameplay(...) end
        if type(original) == "function" then return original(...) end
      end
    end,
  })
end

local function onExtensionUnloaded()
  onPopupClosed()
  if overhaul_shell_patches then overhaul_shell_patches.unregister(PATCH_ID) end
end

local function isRebuiltButtonId(id)
  return type(id) == "string" and (id:sub(1, 5) == "towTo" or id:sub(1, 13) == "quickTravelTo" or id == "callTaxi")
end

local function rebuildGarageButtons()
  local prevActive = {}
  for id, option in pairs(buttonOptions) do
    if isRebuiltButtonId(id) then prevActive[id] = option.active and true or false end
  end
  addTowingButtons()
  addQuickTravelButtons()
  local restricted = overhaul_integration_services_missions_missionManager and overhaul_integration_services_missions_missionManager.getForegroundMissionId()
  for id, option in pairs(buttonOptions) do
    if isRebuiltButtonId(id) then
      if prevActive[id] ~= nil then
        option.active = prevActive[id]
      elseif restricted then
        option.active = false
      end
    end
  end
end

local function onBeforeRadialOpened()
  if not isOverhaulActive() then return end
  if not next(buttonOptions) then setupButtonOptions() end
  if overhaul_career_career and overhaul_career_career.isActive() then
    rebuildGarageButtons()
  end
  refreshFeatureOptions()
  if quickAccessInitialized then return end
  quickAccessInitialized = true
  addButtonsForLevel(nil)
  addButtonsForLevel("quickTravel/")
  addButtonsForLevel("towing/")
end

local function onHideRadialMenu()
  popupData = nil
end

local function onQuickAccessLoaded()
  quickAccessInitialized = nil
end

local function getCustomRecoveryOptionsActiveState()
  local recoveryOptions = {}
  for recoveryOptionId, recoveryOptionData in pairs(buttonOptions) do
    recoveryOptions[recoveryOptionId] = {
      active = recoveryOptionData.active,
      enabled = recoveryOptionData.enabled,
      label = recoveryOptionData.label,
      icon = recoveryOptionData.icon,
      isRecoveryOption = recoveryOptionData.isRecoveryOption,
    }
  end
  return recoveryOptions
end

local function onVehicleSwitched(oldId, newId, player)
  if not isOverhaulActive() then return end
  updateTuningShopTowButton(newId)
end

-- Public API --------------------------------------------------------------------------------------

M.setDefaultsForFreeroam = setDefaultsForFreeroam
M.setDefaultsForCareer = setDefaultsForCareer
M.deactivateAllButtons = deactivateAllButtons
M.setButtonActiveById = setButtonActiveById
M.addTowingButtons = addTowingButtons
M.addQuickTravelButtons = addQuickTravelButtons
M.addTaxiButtons = addQuickTravelButtons
M.buttonPressed = buttonPressed
M.onPopupClosed = onPopupClosed
M.handleResetGameplay = onResetGameplay
M.onScreenFadeState = onScreenFadeState
M.handleCurrRecoveryOption = handleCurrRecoveryOption
M.getCustomRecoveryOptionsActiveState = getCustomRecoveryOptionsActiveState
M.getPauseCareerRightRailButtons = getPauseCareerRightRailButtons

-- Game hooks --------------------------------------------------------------------------------------

M.onUpdate = onUpdate
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onBeforeRadialOpened = onBeforeRadialOpened
M.onHideRadialMenu = onHideRadialMenu
M.onQuickAccessLoaded = onQuickAccessLoaded
M.onVehicleSwitched = onVehicleSwitched

return M
