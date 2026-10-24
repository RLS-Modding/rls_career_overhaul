-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Fork of stock lua/ge/extensions/career/modules/delivery/vehicleOfferManager.lua (BeamNG 0.40).

-- Owns vehicle-delivery offers, unlock information and offer reward preparation.
-- The generator creates offers; vehicleTasks accepts and completes their physical delivery.
-- Start with task labels and unlock helpers, then offer storage and location queries.
-- Read reward formatting and public offer operations before the career and update hooks.

local M = {}

-- State -------------------------------------------------------------------------------------------
local dependencies = {"overhaul_shell_stepHandler"}
-- Sibling extensions bound in onCareerActivated; they are not loaded yet when this file runs.
local dParcelManager, dCargoScreen, dGeneral, dGenerator, dProgress, dVehicleTasks
local step

-- Binding -----------------------------------------------------------------------------------------
local function onCareerActivated()
  dParcelManager = overhaul_career_logistics_parcelManager
  dCargoScreen = overhaul_career_logistics_cargoScreen
  dGeneral = overhaul_career_logistics_general
  dGenerator = overhaul_career_logistics_generator
  dProgress = overhaul_career_logistics_progress
  dVehicleTasks = overhaul_career_logistics_vehicleTasks
  step = overhaul_shell_stepHandler
end

-- Task labels and unlock helpers ------------------------------------------------------------------
local function makeTaskLabel(task)
  if task.type == "vehicleDropOff" then
    if task.lookupType == "vehNeedsRepair" or task.lookupType == "vehLargeTruckNeedsRepair" then
      return core_locales.contextTranslate("ui.career.delivery.vehicleTasks.bringToRepairs", {destination = dParcelManager.getLocationLabelShort(task.destination)})
    end
    if task.lookupType == "vehForPrivate" then
      return core_locales.contextTranslate("ui.career.delivery.vehicleTasks.bringToPrivateHome", {destination = dParcelManager.getLocationLabelShort(task.destination)})
    end
    if task.lookupType == "vehRepairFinished" then
      return core_locales.contextTranslate("ui.career.delivery.vehicleTasks.returnAfterRepair", {destination = dParcelManager.getLocationLabelShort(task.destination)})
    end
    if task.lookupType == "vehLargeTruck" then
      return core_locales.contextTranslate("ui.career.delivery.vehicleTasks.bringTo", {destination = dParcelManager.getLocationLabelShort(task.destination)})
    end
    return core_locales.contextTranslate("ui.career.delivery.vehicleTasks.bringTo", {destination = dParcelManager.getLocationLabelShort(task.destination)})
  elseif task.type == "trailerDropOff" then
    return core_locales.contextTranslate("ui.career.delivery.vehicleTasks.towTo", {destination = dParcelManager.getLocationLabelShort(task.destination)})
  elseif task.destination then
    return core_locales.contextTranslate("ui.career.delivery.vehicleTasks.dropOffAt", {destination = dParcelManager.getLocationLabelShort(task.destination)})
  else
    return _tr("ui.career.delivery.vehicleTasks.unknown")
  end
end

local vehicleTags = {
  junkerVeh = {
    unlockFlag = "junkerVeh",
    labelPlural = "Cheap Cars",
    labelSingular = "Cheap Car",
  },
  smallVeh = {
    unlockFlag = "smallVeh",
    labelPlural = "Budget Cars",
    labelSingular = "Budget Car",
  },
  highEndVeh = {
    unlockFlag = "highEndVeh",
    labelPlural = "High-End Cars",
    labelSingular = "High-End Car",
  },
  -- Legacy tag alias kept for compatibility with old offers/saves.
  largeVeh = {
    unlockFlag = "highEndVeh",
    labelPlural = "High-End Cars",
    labelSingular = "High-End Car",
  },
  fleetVeh = {
    unlockFlag = "fleetVeh",
    labelPlural = "Medium Cars",
    labelSingular = "Medium Car",
  },
  exoticVeh = {
    unlockFlag = "exoticVeh",
    labelPlural = "ui.career.delivery.vehicleTags.exoticVeh.plural",
    labelSingular = "ui.career.delivery.vehicleTags.exoticVeh.singular",
  },
  heavyVeh = {
    unlockFlag = "heavyVeh",
    labelPlural = "Heavy Vehicles",
    labelSingular = "Heavy Vehicle",
  },


  emptySmallTrailers = {
    unlockFlag = "smallTrailersDelivery",
    labelPlural = "ui.career.delivery.vehicleTags.emptySmallTrailers.plural",
    labelSingular = "ui.career.delivery.vehicleTags.emptySmallTrailers.singular",
  },
  loadedSmallTrailers = {
    unlockFlag = "smallTrailersDelivery",
    labelPlural = "ui.career.delivery.vehicleTags.loadedSmallTrailers.plural",
    labelSingular = "ui.career.delivery.vehicleTags.loadedSmallTrailers.singular",
  },
  emptyMediumTrailers = {
    unlockFlag = "logisticsTrailerMedium",
    labelPlural = "ui.career.delivery.vehicleTags.emptyMediumTrailers.plural",
    labelSingular = "ui.career.delivery.vehicleTags.emptyMediumTrailers.singular",
  },
  loadedMediumTrailers = {
    unlockFlag = "logisticsTrailerMedium",
    labelPlural = "ui.career.delivery.vehicleTags.loadedMediumTrailers.plural",
    labelSingular = "ui.career.delivery.vehicleTags.loadedMediumTrailers.singular",
  },
  emptyLargeTrailer = {
    unlockFlag = "logisticsTrailerFlatbed",
    labelPlural = "ui.career.delivery.vehicleTags.emptyLargeTrailer.plural",
    labelSingular = "ui.career.delivery.vehicleTags.emptyLargeTrailer.singular",
  },
  loadedLargeTrailers = {
    unlockFlag = "logisticsTrailerFlatbed",
    labelPlural = "ui.career.delivery.vehicleTags.loadedLargeTrailers.plural",
    labelSingular = "ui.career.delivery.vehicleTags.loadedLargeTrailers.singular",
  },

  trailerBoxutility = {
    unlockFlag = "smallTrailersDelivery",
    labelPlural = "Box Utility Trailers",
    labelSingular = "Box Utility Trailer",
  },
  trailerBoxutilityLarge = {
    unlockFlag = "smallTrailersDelivery",
    labelPlural = "Large Box Utility Trailers",
    labelSingular = "Large Box Utility Trailer",
  },
  trailerTsfb = {
    unlockFlag = "smallTrailersDelivery",
    labelPlural = "Small Flatbed Trailers",
    labelSingular = "Small Flatbed Trailer",
  },
  trailerCaravan = {
    unlockFlag = "smallTrailersDelivery",
    labelPlural = "Caravans",
    labelSingular = "Caravan",
  },
  trailerDolly = {
    unlockFlag = "logisticsTrailerDolly",
    labelPlural = "Dollies",
    labelSingular = "Dolly",
  },
  trailerCargotrailer = {
    unlockFlag = "logisticsTrailerMedium",
    labelPlural = "Cargo Trailers",
    labelSingular = "Cargo Trailer",
  },
  trailerTiltdeck = {
    unlockFlag = "logisticsTrailerMedium",
    labelPlural = "Bumper-Pull Tiltdeck Trailers",
    labelSingular = "Bumper-Pull Tiltdeck Trailer",
  },
  trailerHeavyHitch = {
    unlockFlag = "logisticsTrailerHeavyHitch",
    labelPlural = "Gooseneck and Pintle Trailers",
    labelSingular = "Gooseneck or Pintle Trailer",
  },
  trailerFlatbed = {
    unlockFlag = "logisticsTrailerFlatbed",
    labelPlural = "Flatbed Trailers",
    labelSingular = "Flatbed Trailer",
  },
  trailerContainer = {
    unlockFlag = "logisticsTrailerContainer",
    labelPlural = "Container Trailers",
    labelSingular = "Container Trailer",
  },
  trailerDryvan = {
    unlockFlag = "logisticsTrailerDryvan",
    labelPlural = "Dry Van Trailers",
    labelSingular = "Dry Van Trailer",
  },
  trailerTanker = {
    unlockFlag = "logisticsTrailerTanker",
    labelPlural = "Tanker Trailers",
    labelSingular = "Tanker Trailer",
  },
  trailerLogTrailer = {
    unlockFlag = "logisticsTrailerLog",
    labelPlural = "Log Trailers",
    labelSingular = "Log Trailer",
  },
  trailerFramelessDump = {
    unlockFlag = "logisticsTrailerFramelessDump",
    labelPlural = "Frameless Dump Trailers",
    labelSingular = "Frameless Dump Trailer",
  }
}

local skillIcons = {
  delivery = "boxPickUp03",
  vehicleDelivery = "keys1"
}
local function isVehicleTagUnlocked(tag)
  if not vehicleTags[tag] then return true end
  if not vehicleTags[tag].unlockFlag then return true end

  local unlocked = overhaul_career_progression_unlockFlags.getFlag(vehicleTags[tag].unlockFlag)
  local flagDefinition = overhaul_career_progression_unlockFlags.getFlagDefinition(vehicleTags[tag].unlockFlag)

  return unlocked, flagDefinition
end

local function getVehicleTagUnlockFlag(tag)
  return vehicleTags[tag] and vehicleTags[tag].unlockFlag or nil
end
local function getVehicleTagUnlockedSimple()
  local status = {}
  for tag, info in pairs(vehicleTags) do
    status[tag] = isVehicleTagUnlocked(tag)
  end
  return status
end

local function getVehicleTagLabelSingular(tag)
  if not vehicleTags[tag] then return _tr("ui.career.delivery.vehicleTags.noCategory") end
  return _tr(vehicleTags[tag].labelSingular)
end
local function getVehicleTagLabelPlural(tag)
  if not vehicleTags[tag] then return _tr("ui.career.delivery.vehicleTags.noCategory") end
  return _tr(vehicleTags[tag].labelPlural)
end

local function getDefaultVehicleModifiersForUI()
  return {
    {type = "route", icon = "routeSimple", active = true, label = _tr("ui.career.delivery.vehicleModifiers.route.label"), description = _tr("ui.career.delivery.vehicleModifiers.route.description"), important = true},
    {type = "damage", icon = "cogsDamaged", active = true, label = _tr("ui.career.delivery.vehicleModifiers.damage.label"), description = _tr("ui.career.delivery.vehicleModifiers.damage.description"), important = true}
  }
end


--[[
local function onGetSkillUnlockInfoForUi(skill, unlocks)
  -- vehicles
  if skill.id == "vehicleDelivery" then
    local tagsByTier = {}
    for key, info in pairs(vehicleTags) do
      local tier = 1
      if info.requirements then
        tier = info.requirements.vehicleDelivery
      end
      if info.requirements.vehicleDelivery then
        tagsByTier[tier] = tagsByTier[tier] or {}
        table.insert(tagsByTier[tier], info.labelPlural)
      end
    end
    for tier, list in pairs(tagsByTier) do
      table.sort(list)
      unlocks[tier] = unlocks[tier] or {}
      for _, value in ipairs(list) do
        table.insert(unlocks[tier], {type="text", label = value})
      end
    end
  end

  -- trailers
  if skill.id == "delivery" then
    local tagsByTier = {}
    for key, info in pairs(vehicleTags) do
      local tier = 1
      if info.requirements then
        tier = info.requirements.delivery
      end
      if info.requirements.delivery then
        tagsByTier[tier] = tagsByTier[tier] or {}
        table.insert(tagsByTier[tier], info.labelPlural)
      end
    end
    for tier, list in pairs(tagsByTier) do
      table.sort(list)
      unlocks[tier] = unlocks[tier] or {}
      for _, value in ipairs(list) do
        table.insert(unlocks[tier], {type="text", label = value})
      end
    end
  end
end

M.onGetSkillUnlockInfoForUi = onGetSkillUnlockInfoForUi
]]

-- Offer storage -----------------------------------------------------------------------------------
local allOffers = {}
local spawnQueue = {}
local cleanUpElapsed = 0
local CLEAN_UP_INTERVAL_S = 10
local EXPIRED_OFFER_GRACE_S = 120
-- Generator IDs restart when a career snapshot loads. Retained offers would
-- otherwise shadow the new records, including their restored scene IDs.
function M.resetOffersForLoad()
  allOffers = {}
  cleanUpElapsed = 0
end

local function onUpdate(dtReal, dtSim)
  if not dGeneral or not extensions.isExtensionLoaded('overhaul_career_logistics_general') then return end
  cleanUpElapsed = cleanUpElapsed + dtSim
  if cleanUpElapsed < CLEAN_UP_INTERVAL_S then return end
  cleanUpElapsed = 0
  local cutoff = dGeneral.time() - EXPIRED_OFFER_GRACE_S
  local queuedIds = {}
  for _, request in ipairs(spawnQueue) do queuedIds[request.offerId] = true end
  local persistence = require('overhaul/career/logistics/general/persistence')
  local retained = 0
  for _, offer in ipairs(allOffers) do
    -- Expiry ends only untouched generator output. Accepted work and queued
    -- spawns may still need their native ID long after the board timer ends.
    local expired = offer.offerExpiresAt and offer.offerExpiresAt < cutoff
      and not queuedIds[offer.id] and persistence.isRegenerableOffer(offer)
    if not expired then
      retained = retained + 1
      allOffers[retained] = offer
    end
  end
  for index = #allOffers, retained + 1, -1 do allOffers[index] = nil end
end

local function addOffer(offer)
  table.insert(allOffers, offer)
  extensions.hook('onOverhaulLogisticsOffersChanged')
end

local function sameLocation(a,b)
  local same = true
  for k, v in pairs(a) do
    same = same and a[k] == b[k]
  end
  return same
end

local function sameLocationOffer(offer, otherLoc)
  return sameLocation(offer.origin, otherLoc)
end

local function getAllOfferCustomFilter(filter, ...)
  overhaul_career_logistics_generator.triggerAllGenerators()
  local ret = {}
  for _, offer in ipairs(allOffers) do
    if dGeneral.isOfferAvailable(offer) and filter(offer, ...) then
      table.insert(ret, offer)
    end
  end
  return ret
end

local function getAllOfferForLocation(loc)
  return getAllOfferCustomFilter(sameLocationOffer, loc)
end

local function getAllOfferUnexpired()
  overhaul_career_logistics_generator.triggerAllGenerators()
  local ret = {}
  local now = dGeneral and dGeneral.time() or 0
  for _, offer in ipairs(allOffers) do
    if offer and dGeneral.isOfferAvailable(offer) and not offer.spawned
      and (not offer.offerExpiresAt or offer.offerExpiresAt > now) then
      table.insert(ret, offer)
    end
  end
  return ret
end

-- No generator trigger — for economy rebakes on existing board offers.
local function getOpenBoardOffers()
  local ret = {}
  local now = dGeneral and dGeneral.time() or 0
  for _, offer in ipairs(allOffers) do
    if offer and dGeneral.isOfferAvailable(offer) and offer.rewards and not offer.spawned
      and (not offer.offerExpiresAt or offer.offerExpiresAt > now) then
      table.insert(ret, offer)
    end
  end
  return ret
end

local function getAllOfferAtFacilityUnexpired(facId, psPath, audience)
  overhaul_career_logistics_generator.triggerAllGenerators()
  local ret = {}
  local now = dGeneral and dGeneral.time() or 0
  for _, offer in ipairs(allOffers) do
    if offer and dGeneral.isOfferAvailable(offer, audience) and offer.origin and offer.origin.facId == facId
      and not offer.spawned
      and (not offer.offerExpiresAt or offer.offerExpiresAt > now)
      --and dProgress.isFacilityVisible(offer.task.destination.facId)
      --and dProgress.isFacilityUnlocked(offer.task.destination.facId)
       then
      table.insert(ret, offer)
    end
  end
  return ret
end

-- Offer spawning ----------------------------------------------------------------------------------
local function getOfferById(id)
  for _, offer in ipairs(allOffers) do
    if offer.id == id then
      return offer
    end
  end
  return nil
end

local spawnOfferInProgress = false
local SPAWN_SEQUENCE_STALL_CHECKS = 5
local BRIDGE_WAIT_SEC = 8

-- Offers are generated with only a filterId; model/config are picked when the
-- cargo board or phone previews them. Employment spawns directly, so finalize here.
local function ensureOfferSpawnReady(offer, context)
  if not offer or not offer.vehicle then
    return false, "offer missing vehicle data"
  end
  if dGenerator and dGenerator.finalizeVehicleOffer then
    dGenerator.finalizeVehicleOffer(offer)
  end
  local model = offer.vehicle.model
  local config = offer.vehicle.config
  if not model or model == "" then
    return false, string.format(
      "no model after finalize (filterId=%s, context=%s)",
      tostring(offer.vehicle.filterId),
      tostring(context))
  end
  if not config or config == "" then
    return false, string.format(
      "no config after finalize (filterId=%s, model=%s, context=%s)",
      tostring(offer.vehicle.filterId),
      tostring(model),
      tostring(context))
  end
  local modelData = core_vehicles.getModel(model)
  if not modelData then
    return false, string.format("unknown model '%s' (context=%s)", tostring(model), tostring(context))
  end
  if not modelData.configs or not modelData.configs[config] then
    return false, string.format(
      "unknown config '%s' for model '%s' (context=%s)",
      tostring(config),
      tostring(model),
      tostring(context))
  end
  if not offer.spawnLocation or not offer.spawnLocation.psPath then
    return false, string.format("missing spawn parking spot (context=%s)", tostring(context))
  end
  local ps = dGenerator and dGenerator.getParkingSpotByPath(offer.spawnLocation.psPath)
  if not ps then
    return false, string.format(
      "spawn parking spot not found: %s (context=%s)",
      tostring(offer.spawnLocation.psPath),
      tostring(context))
  end
  return true
end

local function isOfferSpawnReady(offer)
  return ensureOfferSpawnReady(offer, "isOfferSpawnReady")
end

local function getSpawnParkingSpot(offer, vehId)
  local defaultPath = offer and offer.spawnLocation and offer.spawnLocation.psPath
  local defaultSpot = defaultPath and dGenerator.getParkingSpotByPath(defaultPath)
  if not offer or not offer.data or offer.data.type ~= "trailer" then
    if defaultSpot and not require('overhaul/lib/parking/reservation').clearParkedOccupants(defaultSpot, vehId) then
      return nil, "occupied"
    end
    return defaultSpot
  end

  -- Trailer offers can share one provider facility but originate from several
  -- compatible spots. Pick an open one when the offer is actually spawned;
  -- otherwise every accepted offer uses the randomly selected spot recorded
  -- at generation time and they stack on top of one another.
  local facility = offer.origin and dGenerator.getFacilityById(offer.origin.facId)
  local logisticType = offer.task and offer.task.lookupType
  local returnTrailer = offer._employmentReturnTrailer == true
  if (not facility or not logisticType) and not returnTrailer then
    if defaultSpot and not require('overhaul/lib/parking/reservation').clearParkedOccupants(defaultSpot, vehId) then return nil, "occupied" end
    return defaultSpot
  end

  local candidates, seen = {}, {}
  local function addSpot(spot)
    if not spot then return end
    local path = spot.getPath and spot:getPath()
    if path and not seen[path] then
      seen[path] = true
      candidates[#candidates + 1] = spot
    end
  end

  addSpot(defaultSpot)
  local extra = {}
  for _, accessPoint in pairs(facility and facility.accessPointsByName or {}) do
    local compatible = logisticType and accessPoint.logisticTypesProvidedLookup and accessPoint.logisticTypesProvidedLookup[logisticType]
    local trailerSpot = returnTrailer and tostring(accessPoint.psPath or accessPoint.name or ""):lower():find("trailer", 1, true)
    local trailerLoaner = returnTrailer and tonumber(accessPoint.loanerTrailerPriority) ~= nil
    if compatible or trailerSpot or trailerLoaner then
      extra[#extra + 1] = accessPoint
    end
  end
  table.sort(extra, function(a, b) return tostring(a.psPath or a.name) < tostring(b.psPath or b.name) end)
  for _, accessPoint in ipairs(extra) do addSpot(accessPoint.ps) end

  local emptyFallback
  local sawOccupied = false
  for _, spot in ipairs(candidates) do
    local fits = not vehId or not spot.vehicleFits or spot:vehicleFits(vehId)
    local occupied = not require('overhaul/lib/parking/reservation').clearParkedOccupants(spot, vehId)
    if occupied and (fits or not returnTrailer) then
      sawOccupied = true
    elseif not occupied then
      if fits then return spot end
      emptyFallback = emptyFallback or spot
    end
  end
  if emptyFallback and not returnTrailer then return emptyFallback end
  if sawOccupied or (not returnTrailer and candidates[1]) then return nil, "occupied" end
  return nil, "noSpot"
end

local PICKUP_BLOCKED_MSG = "Pickup spot is blocked. Move the existing vehicle out of the pickup bay, then accept this load again."
local function makeSpawnOfferSteps(offerId, fadeToBlack, postDelay, audience)
  local offer = getOfferById(offerId)
  if not offer or not dGeneral.canAcceptOffer(offer, audience) or offer.spawned or offer._spawning then return {} end

  local spawnReady, spawnErr = ensureOfferSpawnReady(offer, string.format("offer %s", tostring(offerId)))
  if not spawnReady then
    log("E", "vehicleOfferManager", string.format("Cannot spawn offer %s: %s", tostring(offerId), spawnErr))
    offer._lastSpawnFailReason = spawnErr or "spawnNotReady"
    if not offer._employmentReturnTrailer then
      ui_message("Could not spawn the assigned vehicle. Try again or pick a different job.", 8, "warning")
    end
    return {}
  end

  local _, spotFail = getSpawnParkingSpot(offer)
  if spotFail == "occupied" then
    offer._lastSpawnFailReason = "occupied"
    -- Broker and cargo screen pickups tell the player; employment and other callers handle it themselves.
    if audience ~= "employment" and (offer.brokerId or offer.spawnWhenCommitingCargo) then
      ui_message(PICKUP_BLOCKED_MSG, 8, "warning")
    end
    return {}
  end
  offer._spawning = true
  offer._lastSpawnFailReason = nil
  local startedAt = dGeneral.time()
  local startedAtReal = os.clock()
  if fadeToBlack == nil then fadeToBlack = true end
  local vehId = nil
  local cancelled = false
  local keepPlayerVehId = be and be.getPlayerVehicleID and tonumber(be:getPlayerVehicleID(0))
  local keepWalking = gameplay_walk and gameplay_walk.isWalking() or false

  local function restorePlayerSeat()
    if keepWalking then
      if gameplay_walk and gameplay_walk.isWalking() then return end
      if gameplay_walk then gameplay_walk.setWalkingMode(true, nil, nil, true) end
      return
    end
    if not keepPlayerVehId or keepPlayerVehId < 0 then return end
    local currentId = tonumber(be:getPlayerVehicleID(0))
    if currentId == keepPlayerVehId then return end
    local prev = getObjectByID(keepPlayerVehId)
    if not prev then return end
    pcall(function()
      be:enterVehicle(0, prev)
    end)
  end

  local function abortSpawn(reason)
    if cancelled or offer.spawned then return true end
    cancelled = true
    if vehId then
      restorePlayerSeat()
      local veh = getObjectByID(vehId)
      if veh then veh:delete() end
      vehId = nil
    end
    restorePlayerSeat()
    if offer.vehicle then
      offer.vehicle.vehId = nil
    end
    offer._spawning = nil
    offer.spawned = false
    offer._lastSpawnFailReason = reason or "aborted"
    return true
  end

  local spawnPs = offer.spawnLocation and offer.spawnLocation.psPath
    and dGenerator and dGenerator.getParkingSpotByPath(offer.spawnLocation.psPath)
  local options = {
    model = offer.vehicle.model,
    config = offer.vehicle.config,
    autoEnterVehicle = false,
  }
  if spawnPs and spawnPs.pos and spawnPs.rot then
    options.pos = spawnPs.pos
    options.rot = spawnPs.rot
  end

  local steps = {
    step.makeStepSpawnVehicle(options, function(_, id)
      if cancelled then
        if tonumber(be:getPlayerVehicleID(0)) == id then
          restorePlayerSeat()
        end
        local veh = getObjectByID(id)
        if veh then veh:delete() end
        return
      end
      vehId = id
      restorePlayerSeat()
    end),
    step.makeStepReturnTrueFunction(function()
      if cancelled then return true end
      if not vehId then
        if (dGeneral.time() - startedAt) > 15 or (os.clock() - startedAtReal) > 15 then
          return abortSpawn("spawnTimeout")
        end
        return false
      end
      restorePlayerSeat()
      local ps, spotFail = getSpawnParkingSpot(offer, vehId)
      if not ps then
        local reason = spotFail or "noSpot"
        if spotFail == "occupied" then
          -- Employment enters its spawn-blocked state, which posts the one waiting notice.
          if audience ~= "employment" then
            ui_message(PICKUP_BLOCKED_MSG, 8, "warning")
          end
        elseif not offer._employmentReturnTrailer then
          ui_message("Could not spawn the assigned vehicle: no free pickup spot. Clear the pickup area and try again.", 8, "warning")
        end
        return abortSpawn(reason)
      end
      local ok = pcall(function()
      ps:moveResetVehicleTo(vehId, nil, false, nil, nil, true)
      end)
      if not ok then
        return abortSpawn("placement")
      end
      restorePlayerSeat()
      local veh = getObjectByID(vehId)
      if not veh then
        return abortSpawn("missingVehicle")
      end
      local mileage = offer.vehicle.mileage or 0
      offer.vehicle.vehId = vehId
      veh:queueLuaCommand(string.format("partCondition.initConditions(nil, %d, nil, %f)", mileage, overhaul_career_market_vehicleShopping.getVisualValueFromMileage(mileage)))
      core_vehicleBridge.executeAction(veh,'setIgnitionLevel', 0)
      return true
    end),
    step.makeStepReturnTrueFunction(function(stepState)
      if not vehId then return true end
      if not stepState.sentCommand then
        stepState.sentCommand = true
        stepState.sentAtReal = os.clock()
        local veh = getObjectByID(vehId)
        if not veh then return abortSpawn("missingVehicle") end
        core_vehicleBridge.requestValue(veh, function()
          if not cancelled then stepState.pingComplete = true end
        end, 'ping')
      end
      if stepState.pingComplete then return true end
      if stepState.sentAtReal and (os.clock() - stepState.sentAtReal) > BRIDGE_WAIT_SEC then
        return abortSpawn("pingTimeout")
      end
      return false
    end),
    step.makeStepReturnTrueFunction(function(stepState)
      if not vehId then return true end
      if not stepState.sentCommand then
        stepState.sentCommand = true
        stepState.sentAtReal = os.clock()
        local vehData = core_vehicle_manager.getVehicleData(vehId)
        if not vehData or not vehData.config or not vehData.config.mainPartName then
          stepState.odometerComplete = true
          offer.startingOdometer = -1
          return true
        end
        local veh = getObjectByID(vehId)
        if not veh then
          return abortSpawn("missingVehicle")
        end
        core_vehicleBridge.requestValue(veh, function(res)
          if cancelled then return end
          stepState.odometerComplete = true
          local mainPartName = "/" .. vehData.config.mainPartName
          local part = res.result[mainPartName]
          offer.startingOdometer = part and part.odometer or -1
        end, 'getPartConditions')
      end
      if stepState.odometerComplete then return true end
      if stepState.sentAtReal and (os.clock() - stepState.sentAtReal) > BRIDGE_WAIT_SEC then
        return abortSpawn("conditionsTimeout")
      end
      return false
    end),
    step.makeStepReturnTrueFunction(function()
      if not vehId or offer._lastSpawnFailReason then
        offer._spawning = nil
        return true
      end
      if gameplay_walk.isWalking() then
        local veh = getObjectByID(vehId)
        if veh then
        gameplay_walk.setRot(veh:getPosition() - getPlayerVehicle(0):getPosition())
      end
      end
      restorePlayerSeat()
      dVehicleTasks.addVehicleTask(vehId, offer)
      dGeneral.startDeliveryMode()
      if overhaul_integration_services_markerInteraction then
        overhaul_integration_services_markerInteraction.setForceReevaluateOpenPrompt()
      end
      offer.spawned = true
      offer._spawning = nil
      offer.spawnWhenCommitingCargo = nil
      return true
    end),
    step.makeStepReturnTrueFunction(function()
      guihooks.trigger("updateCargoData")
      return true
    end),
    step.makeStepReturnTrueFunction(function()
      if not vehId then return true end
      local veh = getObjectByID(vehId)
      if not veh then return true end
      local camDir = veh:getPosition() - getPlayerVehicle(0):getPosition()
      if gameplay_walk.isWalking() then
        gameplay_walk.setRot(camDir)
      end
      return true
    end)
   }

   if fadeToBlack then
    table.insert(steps, 1, step.makeStepFadeToBlack(0.4))
    table.insert(steps, 1, step.makeStepWait(0.15))
    table.insert(steps, step.makeStepFadeFromBlack(0.4))
   end

  if postDelay and postDelay > 0 then
    table.insert(steps, step.makeStepWait(postDelay))
  end

  return steps, abortSpawn
end

local function spawnOfferInternal(offerId, fadeToBlack, callback, postDelay, audience)
  local offer = getOfferById(offerId)
  if not offer then
    log("E","","Could not find offer with id "..dumps(offerId))
    if callback then callback(false, "missingOffer") end
    return
  end
  if offer.spawned then
    if callback then callback(true) end
    return
  end
  if offer._spawning then
    if callback then callback(false, "busy") end
    return
  end

  log("I","","Spawning offer " .. offerId)
  local sequence, cancelSpawn = makeSpawnOfferSteps(offerId, fadeToBlack, postDelay, audience)
  if not sequence[1] then
    local failReason = offer._lastSpawnFailReason or "emptySpawnSteps"
    offer._lastSpawnFailReason = nil
    if callback then callback(false, failReason) end
    return
  end
  local function startSpawnSequence()
    local finished = false
    local tick = 0
    local function finish(okOverride, reasonOverride)
      if finished then return end
      finished = true
      local spawnedOffer = getOfferById(offerId)
      local ok = spawnedOffer and spawnedOffer.spawned and true or false
      if okOverride == false then ok = false end
      local failReason = not ok and (reasonOverride or (spawnedOffer and spawnedOffer._lastSpawnFailReason)) or nil
      if not ok and cancelSpawn then cancelSpawn(failReason) end
      if spawnedOffer then
        spawnedOffer._lastSpawnFailReason = nil
        if not ok then spawnedOffer._spawning = nil end
      end
      if callback then callback(ok, failReason) end
    end
    for _, s in ipairs(sequence) do
      local process = s.processTask
      if type(process) == "function" then
        s.processTask = function(...)
          tick = tick + 1
          return process(...)
        end
      end
    end
    step.startStepSequence(sequence, function() finish() end)
    core_jobsystem.create(function(job)
      local lastTick, idleChecks = -1, 0
      while not finished do
        job.sleep(1)
        if finished then return end
        if tick == lastTick then idleChecks = idleChecks + 1 else idleChecks = 0 end
        lastTick = tick
        if idleChecks >= SPAWN_SEQUENCE_STALL_CHECKS then
          local spawnedOffer = getOfferById(offerId)
          if spawnedOffer and spawnedOffer.spawned then
            finish()
          else
            log("W", "vehicleOfferManager", "Spawn sequence for offer " .. tostring(offerId) .. " stopped advancing; releasing the spawn queue")
            finish(false, "sequenceDropped")
          end
          return
        end
      end
    end)
  end
  core_jobsystem.create(function(job)
    job.sleep(0)
    startSpawnSequence()
  end)
end

local function tryStartNextSpawn()
  if spawnOfferInProgress then return end
  local req = table.remove(spawnQueue, 1)
  if not req then return end

  spawnOfferInProgress = true
  spawnOfferInternal(req.offerId, req.fadeToBlack, function(success, failReason)
    if req.callback then
      local ok, err = pcall(req.callback, success, failReason)
      if not ok then log("E", "vehicleOfferManager", "Offer spawn callback failed: " .. tostring(err)) end
    end
    spawnOfferInProgress = false
    tryStartNextSpawn()
  end, req.postDelay, req.audience)
end

local function spawnOffer(offerId, fadeToBlack, callback, audience)
  local offer = getOfferById(offerId)
  if not offer then
    if callback then callback(false, "missingOffer") end
    return
  end
  if not dGeneral.canAcceptOffer(offer, audience) then
    if callback then callback(false, "audience") end
    return
  end
  if offer.spawned then
    if callback then callback(true) end
    return
  end
  if offer._spawning then
    if callback then callback(false, "busy") end
    return
  end
  for _, queued in ipairs(spawnQueue) do
    if queued.offerId == offerId then
      if callback then callback(false, "queued") end
      return
    end
  end
  local isQueued = spawnOfferInProgress or (#spawnQueue > 0)
  if isQueued and fadeToBlack == nil then
    fadeToBlack = false
  end
  table.insert(spawnQueue, {
    offerId = offerId,
    fadeToBlack = fadeToBlack,
    callback = callback,
    audience = audience,
    postDelay = 0.35
  })
  tryStartNextSpawn()
end


--[[
local function onOverhaulBranchTierReached(skill, tier)
  if skill == "vehicleDelivery" then
    local prevMult, nextMult = dProgress.getMoneyMultiplerForSkill('vehicleDelivery', tier-1), dProgress.getMoneyMultiplerForSkill('vehicleDelivery', tier)
    log("I","",string.format("Reached tier %d of vehicle delivery. Increasing money rewards from %0.2f to %0.2f", tier, prevMult, nextMult))
    for _, offer in ipairs(allOffers) do
      if offer.data.type == "vehicle" and  offer.rewards and offer.rewards.money then
        offer.rewards.money = offer.rewards.money / prevMult * nextMult
      end
    end
  end
  if skill == "delivery" then
    local prevMult, nextMult = dProgress.getMoneyMultiplerForSkill('delivery', tier-1), dProgress.getMoneyMultiplerForSkill('delivery', tier)
    log("I","",string.format("Reached tier %d of delivery. Increasing money rewards from %0.2f to %0.2f", tier, prevMult, nextMult))
    for _, offer in ipairs(allOffers) do
      if offer.data.type == "trailer" and  offer.rewards and offer.rewards.money then
        offer.rewards.money = offer.rewards.money / prevMult * nextMult
      end
    end
  end
end
M.onOverhaulBranchTierReached = onOverhaulBranchTierReached
--]]

-- Public API --------------------------------------------------------------------------------------
M.addOffer = addOffer
M.getOfferById = getOfferById
M.sameLocationOffer = sameLocationOffer
M.sameLocation = sameLocation
M.getAllOfferCustomFilter = getAllOfferCustomFilter
M.getAllOfferUnexpired = getAllOfferUnexpired
M.getOpenBoardOffers = getOpenBoardOffers
M.getAllOfferForLocation = getAllOfferForLocation
M.getAllOfferAtFacilityUnexpired = getAllOfferAtFacilityUnexpired
M.getAllSaveableOffers = function()
  local out={};local now=dGeneral and dGeneral.time() or 0
  local employment=overhaul_career_work_employment
  for _,offer in ipairs(allOffers) do
    if not offer.spawned and (not offer.offerExpiresAt or offer.offerExpiresAt>now)
      and not (employment and employment.isAssignedVehicleOffer(offer)) then out[#out+1]=offer end
  end
  return out
end
M.spawnAssignedOffer = function(id,fade,callback) return spawnOffer(id,fade,callback,"employment") end
M.makeAssignedSpawnOfferSteps = function(id,fade,delay) return makeSpawnOfferSteps(id,fade,delay,"employment") end
M.getAvailableTrailerSpawnSpot = getSpawnParkingSpot
M.spawnOffer = spawnOffer
M.makeSpawnOfferSteps = makeSpawnOfferSteps
M.isOfferSpawnReady = isOfferSpawnReady
M.ensureOfferSpawnReady = ensureOfferSpawnReady
M.dependencies = dependencies
M.onCareerActivated = onCareerActivated
M.onUpdate = onUpdate
M.makeTaskLabel = makeTaskLabel
M.isVehicleTagUnlocked = isVehicleTagUnlocked
M.getVehicleTagUnlockFlag = getVehicleTagUnlockFlag
M.getVehicleTagUnlockedSimple = getVehicleTagUnlockedSimple
M.getVehicleTagLabelSingular = getVehicleTagLabelSingular
M.getVehicleTagLabelPlural = getVehicleTagLabelPlural
M.getDefaultVehicleModifiersForUI = getDefaultVehicleModifiersForUI

return M
