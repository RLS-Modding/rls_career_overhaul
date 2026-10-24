local deliveryText = require("overhaul/lib/logistics/resultTranslations")
local _tr = deliveryText.text
local core_locales = {contextTranslate = deliveryText.context}
-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Fork of stock lua/ge/extensions/career/modules/delivery/parcelManager.lua (BeamNG 0.40).

-- Owns parcel locations, transient moves, reward breakdowns and expired-offer cleanup.
-- Generators create cargo; the cargo screen stages moves and progress settles deliveries.
-- Start with location and cargo queries, then mutation and transient-move operations.
-- Reward calculation and cleanup follow the cargo-state helpers.

local M = {}

local ffi = require('ffi')

local cargoLocationsChangedThisFrame = false

local allCargo = {}
-- Only held freight participates in vehicle reconciliation. Keep owner order
-- when an older facility offer enters a vehicle after newer freight.
local persistenceCargo, cargoOrder, nextCargoOrder = {}, setmetatable({}, {__mode = 'k'}), 0
local function indexPersistenceCargo(cargo)
  if not (cargo.logisticsBinding or (cargo.location and cargo.location.type == 'vehicle')) then return end
  for i, existing in ipairs(persistenceCargo) do
    if existing == cargo then return end
    if cargoOrder[existing] > cargoOrder[cargo] then
      table.insert(persistenceCargo, i, cargo)
      return
    end
  end
  persistenceCargo[#persistenceCargo + 1] = cargo
end

local function getCargoForPersistence()
  local out, retained = {}, {}
  for _, cargo in ipairs(persistenceCargo) do
    if cargo.logisticsBinding or (cargo.location and cargo.location.type == 'vehicle') then
      out[#out + 1] = cargo
      retained[#retained + 1] = cargo
    end
  end
  persistenceCargo = retained
  return out
end
M.getCargoForPersistence = getCargoForPersistence
-- A generation adds many parcels before the next query. Build the facility
-- buckets once afterwards; location changes and cleanup invalidate them too.
local cargoByFacility
-- Extension references that exist only while the career is active; onCareerActivated fills them.
local dParcelManager, dCargoScreen, dGeneral, dGenerator, dProgress, dTasklist, dPrecisionParking
M.onCareerActivated = function()
  dParcelManager = overhaul_career_logistics_parcelManager
  dCargoScreen = overhaul_career_logistics_cargoScreen
  dGeneral = overhaul_career_logistics_general
  dGenerator = overhaul_career_logistics_generator
  dProgress = overhaul_career_logistics_progress
  dTasklist = overhaul_career_logistics_tasklist
  dPrecisionParking = overhaul_career_logistics_precisionParking
end

local allVehiclesWithCargo = {}

local transientMoves = {}
local uncommittedTransientMoves = false


-----------------------------------
-- Adding/Moving Cargo functions --
-----------------------------------

local function addCargo(cargo, silent)
  table.insert(allCargo, cargo)
  nextCargoOrder = nextCargoOrder + 1
  cargoOrder[cargo] = nextCargoOrder
  indexPersistenceCargo(cargo)
  cargoByFacility = nil
  if not silent then
    extensions.hook("onOverhaulCargoGenerated", cargo)
  end
end

local function changeCargoLocation(cargoId, newLocation)
  cargoByFacility = nil
  cargoLocationsChangedThisFrame = true
  if not newLocation or not next(newLocation) then
    log("E","","Trying to set location to nil or empty! " .. dumps(cargoId) .. " -> ".. dumps(newLocation))
  end
  for _, cargo in ipairs(allCargo) do
    if cargo.id == cargoId then
      -- A reservation restored from a save only holds the cargo at its spot.
      if cargo.logisticsReserved and not (cargo.location and newLocation and M.sameLocation(cargo.location, newLocation)) then
        cargo.logisticsReserved = nil
      end

      if cargo.materialType and cargo.location and cargo.location.type == "facilityParkingspot" then
        dGenerator.changeMaterialAmountInFacility(cargo.location.facId, cargo.materialType, -cargo.slots)
      end

      if newLocation.vehId and not cargo.loadedAtTimeStamp then
        cargo.loadedAtTimeStamp = cargo.loadedAtTimeStamp or dGeneral.time()
        log("I", "parcelManager", cargo.name .." loaded at ".. cargo.loadedAtTimeStamp)
      end
      cargo.location = newLocation
      indexPersistenceCargo(cargo)

      if cargo.materialType and cargo.location and cargo.location.type == "facilityParkingspot" then
        dGenerator.changeMaterialAmountInFacility(cargo.location.facId, cargo.materialType, cargo.slots)
      end

      if M.sameLocation(cargo.destination, newLocation) then
        cargo.data.delivered = true
      end
    end
  end
end

-- Material quantities share one cargo record. Removing part preserves its
-- delivery binding; removing the last part uses the normal location lifecycle.
function M.discardCargo(cargoId, amount)
  local cargo = M.getCargoById(cargoId)
  if not cargo or not cargo.location or cargo.location.type ~= "vehicle" or cargo._transientMove then return false end
  local available = cargo.materialType and cargo.slots or 1
  if type(amount) ~= "number" or amount ~= amount or amount <= 0 or amount > available then return false end
  if not cargo.materialType and amount ~= 1 then return false end
  if amount >= available then
    changeCargoLocation(cargoId, {type = "deleted"})
    return true
  end
  local retained = (available - amount) / available
  cargo.slots = available - amount
  cargo.weight = cargo.weight * retained
  for key, value in pairs(cargo.rewards or {}) do
    if type(value) == "number" and key ~= "economyMultiplier" then cargo.rewards[key] = value * retained end
  end
  cargoLocationsChangedThisFrame = true
  return true
end

local function addTransientMoveCargo(cargoId, targetLocation)
  local move = {
    cargoId = cargoId,
    targetLocation = targetLocation
  }
  local cargo = M.getCargoById(cargoId)
  if cargo._transientMove then
    log("E","",string.format("Cargo %d already has a transient move: %s!", cargoId, dumps(move)))
    return
  end
  cargo._transientMove = move
  table.insert(transientMoves, move)
  uncommittedTransientMoves = true
end
M.addTransientMoveCargo = addTransientMoveCargo
M.hasUncommittedTransientMoves = function() return uncommittedTransientMoves end

local function getTransientMoveCargo()
  local cargoWithPendingMoves = {}
  for _, cargo in ipairs(allCargo) do
    if cargo._transientMove then
      table.insert(cargoWithPendingMoves, cargo)
    end
  end
  return cargoWithPendingMoves
end
M.getTransientMoveCargo = getTransientMoveCargo

local function clearTransientMoveForCargo(cargoId)
  local moveIndex = -1
  for i, move in ipairs(transientMoves) do
    if move.cargoId == cargoId then
      moveIndex = i
    end
  end
  if moveIndex == -1 then
    return
  end
  local cargo = M.getCargoById(cargoId)
  cargo._transientMove = nil
  table.remove(transientMoves, moveIndex)
end
M.clearTransientMoveForCargo = clearTransientMoveForCargo

local function clearAllTransientMoves()
  table.clear(transientMoves)
  for _, cargo in ipairs(allCargo) do
    cargo._transientMove = nil
  end
  uncommittedTransientMoves = false
end
M.clearAllTransientMoves = clearAllTransientMoves

-- Owned material carries quote and delivery-proof data per load. Sharing a
-- physical tank must not discard any of those records, even for one contract.
local function hasMaterialOwner(cargo)
  local data = cargo.data or {}
  return data.materialContractId or data.brokerId or data.ownerOpSourceCargoId
    or data.frozenQuote or cargo.employmentAssigned or cargo.offerMode == "employment"
end

local function applyTransientMoves(currentLocation)
  cargoByFacility = nil
  local loanerVehicles = overhaul_career_logistics_loanerVehicles
  local pendingMoves = {}
  local movedCargoItems, remainingCargo = {}, {}
  local hasMergeableCargo = false
  for _, move in ipairs(transientMoves) do
    local cargo = M.getCargoById(move.cargoId)
    if not cargo then
      log("W","","Missing Cargo for transient move? " .. dumps(move))
    else
      if not currentLocation or M.sameLocation(currentLocation, cargo.location) then

        M.changeCargoLocation(move.cargoId, move.targetLocation)

        cargo._transientMove = nil

        cargo.loanerOrganisations = cargo.loanerOrganisations or {}
        if cargo.location.vehId then
          tableMerge(cargo.loanerOrganisations, loanerVehicles.getLoaningOrgsOfVehicle(cargo.location.vehId))
        end
        table.insert(movedCargoItems, cargo)
        hasMergeableCargo = hasMergeableCargo or cargo.merge
      else
        table.insert(pendingMoves, move)
        table.insert(remainingCargo, cargo)
      end
    end
  end
  transientMoves = pendingMoves
  uncommittedTransientMoves = false
  cargoLocationsChangedThisFrame = true

  if hasMergeableCargo then
    for _, movedCargo in ipairs(movedCargoItems) do
      for _, cargo in ipairs(allCargo) do
        if    cargo.merge and movedCargo.merge
          and cargo.id ~= movedCargo.id
          and cargo.materialType == movedCargo.materialType
          and not hasMaterialOwner(cargo) and not hasMaterialOwner(movedCargo)
          and M.sameLocation(cargo.location, movedCargo.location) then

          movedCargo.location = {type="delete"}
          local materialData = dGenerator.getMaterialsTemplatesById(cargo.materialType)
          cargo.slots = cargo.slots + movedCargo.slots
          cargo.weight = materialData.density * cargo.slots
          cargo.rewards.money = cargo.slots
          log("I","",string.format("Merged Cargo %d into %d.", movedCargo.id, cargo.id))
        end
      end
    end
  end


  return movedCargoItems, remainingCargo
end
M.applyTransientMoves = applyTransientMoves

local function getTransientMovesForTargetLocationWithCargo(targetLocation)
  local cargoWithPendingMoves = {}
  for _, cargo in ipairs(allCargo) do
    if cargo._transientMove and M.sameLocation(cargo._transientMove.targetLocation, targetLocation) then
      table.insert(cargoWithPendingMoves, cargo)
    end
  end
  return cargoWithPendingMoves
end
M.getTransientMovesForTargetLocationWithCargo = getTransientMovesForTargetLocationWithCargo

local function clearTransientFlags()
  log("E","","Clearing Transient flags no longer needed!")
end

local function onTrailerAttached(objId1, objId2)
  local loanerVehicles = overhaul_career_logistics_loanerVehicles
  if not loanerVehicles then return end
  for _, cargo in ipairs(allCargo) do
    if cargo.location and cargo.location.vehId then
      cargo.loanerOrganisations = cargo.loanerOrganisations or {}
      tableMerge(cargo.loanerOrganisations, loanerVehicles.getLoaningOrgsOfVehicle(cargo.location.vehId))
    end
  end
end

local function undoTransientCargo()
  log("E","","undoTransientCargo")
  -- TODO: undoing transient cargo cleanup
end

M.addCargo = addCargo
M.changeCargoLocation = changeCargoLocation
M.clearTransientFlags = clearTransientFlags
M.undoTransientCargo = undoTransientCargo

-----------------------------
-- Finding Cargo Functions --
-----------------------------

local function sameLocationCargo(cargo, otherLocation)
  return M.sameLocation(cargo.location, otherLocation)
end

local function sameLocation(location,otherLocation)
  local same = true
  for field, value in pairs(location) do
    same = same and location[field] == otherLocation[field]
  end
  return same
end

local function getAllCargoCustomFilter(filter, ...)
  overhaul_career_logistics_generator.triggerAllGenerators()
  local matchingCargo = {}
  for _, cargo in ipairs(allCargo) do
    if filter(cargo, ...) then
      table.insert(matchingCargo, cargo)
    end
  end
  return matchingCargo
end

local function getAllCargoForLocation(location)
  if location.type == "facilityParkingspot" then
    overhaul_career_logistics_generator.triggerAllGenerators()
  end
  local matchingCargo = {}
  for _, cargo in ipairs(allCargo) do
    if M.sameLocation(cargo.location, location) then
      table.insert(matchingCargo, cargo)
    end
  end
  return matchingCargo
end

local function getAllCargoForLocationUnexpired(location)
  if location.type == "facilityParkingspot" then
    overhaul_career_logistics_generator.triggerAllGenerators()
  end
  local matchingCargo = {}
  for _, cargo in ipairs(allCargo) do
    if M.sameLocation(cargo.location, location) and cargo.offerExpiresAt > dGeneral.time() then
      table.insert(matchingCargo, cargo)
    end
  end
  return matchingCargo
end

local function getAllCargoForLocationUnexpiredUndelivered(location, timeExpire, timeGenerated)
  if location.type == "facilityParkingspot" then
    overhaul_career_logistics_generator.triggerAllGenerators()
  end
  local matchingCargo = {}
  for _, cargo in ipairs(allCargo) do
    if    M.sameLocation(cargo.location, location)
      and not M.sameLocation(cargo.location, cargo.destination)
      and cargo.offerExpiresAt > (timeExpire or dGeneral.time())
      and cargo.generatedAtTimestamp <= (timeGenerated or math.huge) then
      table.insert(matchingCargo, cargo)
    end
  end
  return matchingCargo
end

local function getAllCargoForFacilityUnexpiredUndelivered(facId, timeExpire, timeGenerated)
  overhaul_career_logistics_generator.triggerAllGenerators()
  if not cargoByFacility then
    cargoByFacility = {}
    for _, cargo in ipairs(allCargo) do
      if cargo.location.type == 'facilityParkingspot' then
        local id = cargo.location.facId
        cargoByFacility[id] = cargoByFacility[id] or {}
        table.insert(cargoByFacility[id], cargo)
      end
    end
  end
  local matchingCargo = {}
  for _, cargo in ipairs(cargoByFacility[facId] or {}) do
    if cargo.location.type == "facilityParkingspot" and cargo.location.facId == facId
      and not M.sameLocation(cargo.location, cargo.destination)
      and cargo.offerExpiresAt > (timeExpire or dGeneral.time())
      and cargo.generatedAtTimestamp <= (timeGenerated or math.huge) then
      table.insert(matchingCargo, cargo)
    end
  end
  return matchingCargo
end
M.getAllCargoForFacilityUnexpiredUndelivered = getAllCargoForFacilityUnexpiredUndelivered

local function getAllCargoForDestinationFacilityStillAtOriginUnexpired(facId)
  overhaul_career_logistics_generator.triggerAllGenerators()
  local matchingCargo = {}
  for _, cargo in ipairs(allCargo) do
    if    cargo.destination.facId == facId
      and M.sameLocation(cargo.location, cargo.origin)
      and cargo.offerExpiresAt > dGeneral.time() then
      table.insert(matchingCargo, cargo)
    end
  end
  return matchingCargo
end

local function getAllCargoAtFacilityUnexpired(facId)
  overhaul_career_logistics_generator.triggerAllGenerators()
  local matchingCargo = {}
  for _, cargo in ipairs(allCargo) do
    if    M.sameLocation(cargo.location, cargo.origin)
      and cargo.location.facId == facId
      and cargo.offerExpiresAt > dGeneral.time() then
      table.insert(matchingCargo, cargo)
    end
  end
  return matchingCargo
end

local function getAllCargoInVehicles(includeTransient)
  local matchingCargo = {}
  for _, cargo in ipairs(allCargo) do
    if cargo.location.type == "vehicle" or (includeTransient and cargo._transientMove) then
      table.insert(matchingCargo, cargo)
    end
  end
  return matchingCargo
end

-- One pass for the world markers: the cargo aboard a vehicle, and the cargo waiting to be picked up.
-- Waiting cargo has a staged move, or was reserved by a move that a reload could not replay.
local function getCargoForStops()
  local loadedCargo, waitingCargo = {}, {}
  for _, cargo in ipairs(allCargo) do
    local atSpot = cargo.location.type == "facilityParkingspot"
    if cargo.location.type == "vehicle" then table.insert(loadedCargo, cargo) end
    if cargo._transientMove or (cargo.logisticsReserved and atSpot) then table.insert(waitingCargo, cargo) end
  end
  return loadedCargo, waitingCargo
end

M.sameLocationCargo = sameLocationCargo
M.sameLocation = sameLocation
M.getCargoForStops = getCargoForStops
M.getAllCargoCustomFilter = getAllCargoCustomFilter
M.getAllCargoForLocation = getAllCargoForLocation
M.getAllCargoForLocationUnexpired = getAllCargoForLocationUnexpired
M.getAllCargoForLocationUnexpiredUndelivered = getAllCargoForLocationUnexpiredUndelivered
M.getAllCargoForDestinationFacilityStillAtOriginUnexpired = getAllCargoForDestinationFacilityStillAtOriginUnexpired
M.getAllCargoAtFacilityUnexpired = getAllCargoAtFacilityUnexpired
M.getAllCargoInVehicles = getAllCargoInVehicles

local function getLocationLabelShort(location)
  if location.type == "facilityParkingspot" then
    return _tr(dGenerator.getFacilityById(location.facId).name)
  elseif location.type == "vehicle" then
    if be:getPlayerVehicleID(0) == location.vehId then
      return string.format("Current Vehicle (%d)", location.vehId)
    else
      return string.format("Other Vehicle (%d)", location.vehId)
    end
  elseif location.type == "playerAvatar" then
    return "Player Avatar"
  elseif location.type == "multi" then
    if #location.destinations == 1 then
      return M.getLocationLabelShort(location.destinations[1])
    end
    return string.format("%d possible locations",#location.destinations)
  else
    return "Unknown"
  end
end

local function getLocationLabelLong(location)
  if location.type == "facilityParkingspot" then
    local parkingSpot = dGenerator.getParkingSpotByPath(location.psPath)
    local facilityName = _tr(dGenerator.getFacilityById(location.facId).name)
    return parkingSpot.customFields:has("name") and string.format("%s - %s",
      facilityName,
      _tr(parkingSpot.customFields:get("name"))) or facilityName

  elseif location.type == "vehicle" then
    if be:getPlayerVehicleID(0) == location.vehId then
      return string.format("Current Vehicle (%d)", location.vehId)
    else
      return string.format("Other Vehicle (%d)", location.vehId)
    end
  elseif location.type == "multi" then
    if #location.destinations == 1 then
      return M.getLocationLabelShort(location.destinations[1])
    end
    return string.format("%d possible locations",#location.destinations)
  elseif location.type == "playerAvatar" then
    return "Player Avatar"
  else
    return "Unknown"
  end
end

local function getCargoById(cargoId)
  for _, cargo in ipairs(allCargo) do
    if cargo.id == cargoId then

      return cargo
    end
  end
end

local function getSkillRewardKey(cargo)
  return cargo.materialType and "logistics-materials" or "logistics-delivery"
end

local function getRewardsWithBreakdown(cargo)
  local originalRewards, breakdown, adjustedRewards = deepcopy(cargo.rewards), {} , deepcopy(cargo.rewards)
  local originalMoney = originalRewards.money or 0
  local skillRewardKey = getSkillRewardKey(cargo)

  for _,mod in ipairs(cargo.modifiers or {}) do
    if mod.type == "timed" then
      local timedStatus = nil
      local timedMultiplier = nil
      local elapsedSecondsSinceLoading = dGeneral.time() - (cargo.loadedAtTimeStamp or dGeneral.time())

      if elapsedSecondsSinceLoading <= mod.timeUntilDelayed then
        timedStatus = _tr("ui.career.delivery.breakdown.onTime")
        timedMultiplier = 1
        gameplay_achievement.unlockAchievement("ON_SCHEDULE")
      elseif elapsedSecondsSinceLoading <= mod.timeUntilLate then
        timedStatus = _tr("ui.career.delivery.breakdown.delayed")
        timedMultiplier = (0.2 + ((elapsedSecondsSinceLoading-mod.timeUntilDelayed) / (mod.timeUntilLate-mod.timeUntilDelayed)) *0.6)
      else
        timedMultiplier = 0.2
        timedStatus = _tr("ui.career.delivery.breakdown.late")
      end

      local timedElement = {
        label = timedStatus,
        rewards = {money = -(1-timedMultiplier) * originalMoney},
        simpleBreakdownType = "bonus",
      }
      if timedMultiplier == 1 then
        timedElement.rewards.money = math.ceil(originalMoney/10)
      end
      if cargo.organization then
        local reputation = originalRewards[cargo.organization.."Reputation"] or 0
        if timedMultiplier == 1 then
          timedElement.rewards[cargo.organization.."Reputation"] = math.ceil(reputation/2)
        elseif timedMultiplier > 0.2 then
          timedElement.rewards[cargo.organization.."Reputation"] = -(1-timedMultiplier) * reputation
        else
          timedElement.rewards[cargo.organization.."Reputation"] = -1.5 * reputation
        end
      end

      table.insert(breakdown, timedElement)
    end
  end

  for organizationId, _ in pairs(cargo.loanerOrganisations or {}) do
    local organization = overhaul_world_organizations.getOrganization(organizationId)
    local level = organization and organization.reputation and organization.reputation.level
    local levelInfo = level and organization.reputationLevels and organization.reputationLevels[level+2]
    local organizationCut = (levelInfo and levelInfo.loanerCut and levelInfo.loanerCut.value or 0.5)

    local organizationElement = {
      label = core_locales.contextTranslate("ui.career.delivery.breakdown.loanerOrganization", {cut = round(organizationCut * 100)}),
      rewards = {money = -organizationCut * originalMoney},
      simpleBreakdownType = "loaner",
    }
    organizationElement.rewards[organizationId.."Reputation"] = 5 + round((tonumber(cargo.data and cargo.data.originalDistance) or 0)/1000)

    table.insert(breakdown, organizationElement)
  end


  local branchMultiplier = tonumber(overhaul_career_progression_skills.getLevelRewardMultiplier("logistics")) or 1
  if branchMultiplier > 1 then
    local level = require("overhaul/lib/progression/skillLookup").branchLevel("logistics")
    table.insert(breakdown, {
      label = core_locales.contextTranslate("ui.career.delivery.breakdown.levelMultiplier", {level = level}),
      rewards = {money = originalMoney * branchMultiplier - originalMoney},
      simpleBreakdownType = "branch",
    })
  end

  -- Calculate precision parking from the delivery vehicle and destination spot.
  local destinationParkingSpot = nil
  local cargoVehicleId = be:getPlayerVehicleID(0)
  if cargo.destination and cargo.destination.psPath then
    destinationParkingSpot = dGenerator.getParkingSpotByPath(cargo.destination.psPath)
  end

  if cargo.location and cargo.location.type == "vehicle" then
    cargoVehicleId = cargo.location.vehId
  end

  if destinationParkingSpot and cargoVehicleId then
    local precisionData = dPrecisionParking.calculateVehiclePrecisionScore(cargoVehicleId, destinationParkingSpot)
    if precisionData then
      local precisionBonus = dPrecisionParking.getPrecisionParkingBonus(precisionData)

      local precisionBreakdown = {
        label = core_locales.contextTranslate("ui.career.delivery.breakdown.precisionParking", {
          precisionLevel = _tr("ui.career.delivery.precisionLevel." .. precisionBonus.precisionLevel)
        }),
        rewards = {},
        simpleBreakdownType = (precisionBonus.moneyFlat >= 0 and precisionBonus.logisticsFlat >= 0) and "bonus" or "penalty",
        precisionData = precisionData
      }

      local moneyReward = precisionBonus.moneyFlat + (originalMoney * precisionBonus.moneyPercent)
      if moneyReward ~= 0 then
        precisionBreakdown.rewards.money = math.ceil(moneyReward)
      end

      local logisticsReward = precisionBonus.logisticsFlat + (originalRewards["logistics"] or 0) * precisionBonus.logisticsPercent
      if logisticsReward ~= 0 then
        precisionBreakdown.rewards["logistics"] = math.ceil(logisticsReward)
      end

      local skillReward = precisionBonus.skillFlat + (originalRewards[skillRewardKey] or 0) * precisionBonus.skillPercent
      if skillReward ~= 0 then
        precisionBreakdown.rewards[skillRewardKey] = (precisionBreakdown.rewards[skillRewardKey] or 0) + math.ceil(skillReward)
      end

      if cargo.organization then
        local reputationReward = precisionBonus.reputationFlat + (originalRewards[cargo.organization.."Reputation"] or 0) * precisionBonus.reputationPercent
        if reputationReward ~= 0 then
          precisionBreakdown.rewards[cargo.organization.."Reputation"] = math.ceil(reputationReward)
        end
      end

      table.insert(breakdown, precisionBreakdown)
    end
  end

  for _, rewardBreakdown in ipairs(breakdown) do
    for key, amount in pairs(rewardBreakdown.rewards) do
      adjustedRewards[key] = (adjustedRewards[key] or 0) + amount
    end
  end

  return originalRewards, breakdown, adjustedRewards
end
M.getRewardsWithBreakdown = getRewardsWithBreakdown

local lowestIdSort = function(a,b) return a.ids[1] < b.ids[1] end

local function addParcelRewardsSummary(cargoItems)
  if not next(cargoItems) then return end
  local summaries = {}

  -- The caller groups only cargo at the same current location.
  local cargoByGroupId = {}
  for _, cargo in ipairs(cargoItems) do
    local groupKey = string.format("%d-%d", cargo.groupId, cargo.loadedAtTimeStamp or -1)
    cargoByGroupId[groupKey] = cargoByGroupId[groupKey] or {}

    table.insert(cargoByGroupId[groupKey], cargo)


    cargo.originalRewards, cargo.breakdown, cargo.adjustedRewards = getRewardsWithBreakdown(cargo)
  end

  for groupKey, group in pairs(cargoByGroupId) do

    local formatted = dCargoScreen.formatCargoGroup(group)
    formatted.summaryId = groupKey
    -- The UI multiplies this representative item's rewards by the group size.
    formatted.originalRewards, formatted.breakdown, formatted.adjustedRewards = group[1].originalRewards, group[1].breakdown, group[1].adjustedRewards
    table.insert(summaries, formatted)
  end
  table.sort(summaries, lowestIdSort)

  return summaries
end
M.addParcelRewardsSummary = addParcelRewardsSummary

local lastFrameTime = -1

local function updateModifiers(dtSim)
  -- Teardown can still run this callback after general unloads. The cached table outlives the
  -- extension, so the loaded check stops it from reporting a stale delivery mode.
  if not dGeneral or not extensions.isExtensionLoaded('overhaul_career_logistics_general') then return end
  if not dGeneral.isDeliveryModeActive() then return end

  local secondsChanged = math.floor(dGeneral.time()) ~= math.floor(lastFrameTime)
  for _,cargo in ipairs(allCargo) do
    if cargo.location.type == "vehicle" then
      for _,mod in ipairs(cargo.modifiers or {}) do
        if mod.type == "timed"then

          local elapsedSecondsSinceLoading = dGeneral.time() - (cargo.loadedAtTimeStamp or dGeneral.time())

          if not mod.delayedMessageFlag and elapsedSecondsSinceLoading > mod.timeUntilDelayed then
            guihooks.trigger('Message',{clear = nil, ttl = 10, msg = core_locales.contextTranslate("ui.career.delivery.notification.delayed", {
              cargoName = _tr(cargo.name),
              destination = M.getLocationLabelShort(cargo.destination)
            }), category = "delivery", icon = "warning"})
            mod.delayedMessageFlag = true
          elseif not mod.lateMessageFlag and elapsedSecondsSinceLoading > mod.timeUntilLate then
            guihooks.trigger('Message',{clear = nil, ttl = 10, msg = core_locales.contextTranslate("ui.career.delivery.notification.late", {
              cargoName = _tr(cargo.name),
              destination = M.getLocationLabelShort(cargo.destination)
            }), category = "delivery", icon = "warning"})
            mod.lateMessageFlag = true
          end
        end
      end
      if secondsChanged then
        dTasklist.updateTasklistForCargoId(cargo.id)
      end
    end
  end
  lastFrameTime = dGeneral.time()
end

local cleanUpIntervalSeconds, cleanUpTimer = 10, 0
local offerDeletionDelay = 120

local function onUpdate(dtReal, dtSim, dtRaw)
  if not dGeneral or not extensions.isExtensionLoaded('overhaul_career_logistics_general') then return end
  profilerPushEvent("Delivery CargoManager")

  updateModifiers(dtSim)

  if cargoLocationsChangedThisFrame then
    dTasklist.sendCargoToTasklist()
    M.cleanUpCargo()
  end
  cleanUpTimer = cleanUpTimer + dtSim
  if cleanUpTimer > cleanUpIntervalSeconds then
    M.cleanUpCargo()
  end
  cargoLocationsChangedThisFrame = false
  profilerPopEvent("Delivery CargoManager")
end

local function cleanUpCargo()
  cleanUpTimer = 0
  local retainedCargo = {}
  local deletedCount = 0
  for _, cargo in ipairs(allCargo) do
    if    cargo.location.type == "delete" or cargo.location.type == "deleted"
      or (M.sameLocation(cargo.location, cargo.origin) and cargo.offerExpiresAt < dGeneral.time() - offerDeletionDelay and not cargo._transientMove) then
      deletedCount = deletedCount + 1
      cargo._transientMove = nil
      cargoOrder[cargo] = nil
      extensions.hook("onOverhaulCargoRemoved", cargo)
    else
      table.insert(retainedCargo, cargo)
    end
  end
  if deletedCount > 0 then
    allCargo = retainedCargo
    cargoByFacility = nil
    local retained = {}
    for _, cargo in ipairs(retainedCargo) do retained[cargo] = true end
    for i = #persistenceCargo, 1, -1 do
      if not retained[persistenceCargo[i]] then table.remove(persistenceCargo, i) end
    end
    local liveIds = {}
    for _, cargo in ipairs(retainedCargo) do liveIds[cargo.id] = true end
    for i = #transientMoves, 1, -1 do
      if not liveIds[transientMoves[i].cargoId] then table.remove(transientMoves, i) end
    end
    if not next(transientMoves) then uncommittedTransientMoves = false end
  end
end


M.getLocationLabelShort = getLocationLabelShort
M.getLocationLabelLong = getLocationLabelLong
M.getCargoById = getCargoById
M.addParcelRewards = addParcelRewards
M.cleanUpCargo = cleanUpCargo
M.onUpdate = onUpdate
M.onTrailerAttached = onTrailerAttached
return M
