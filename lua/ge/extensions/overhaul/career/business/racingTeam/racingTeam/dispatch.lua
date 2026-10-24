-- Racing team: accepting sanctioned offers for drivers, the player and alongside proxies; scheduled-race toasts; XP and driver stats.
-- Created by racingTeam.lua, which owns offer state access, lifecycle, saving, ticks and every M function.
local part = {}

local bindOperations = require("overhaul/career/business/racingTeam/racingTeam/bindOperations")
local phoneLayout = require("overhaul/lib/phone/layoutOwner")

-- Shared helpers ----------------------------------------------------------------------------------

local function racingMessage(message, seconds, kind)
  ui_message(message, seconds, "Racing Team", kind)
end

local function saveTeamState(parts, businessId)
  local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
  if savePath then
    parts.persist.saveRacingTeamPersistedState(businessId, savePath)
  end
end

-- A driver can take an offer only when hired and free of a job, a pending race and a sanctioned race.
local function driverFreeForRace(tech)
  return tech ~= nil and not tech.fired and not tech.jobId and not tech.pendingRaceOffer
end

-- Finds the offer on the business's race board; returns its index, the offer and the board.
local function findBoardOffer(parts, businessId, offerId)
  local board = parts.raceOffers.getBoard(businessId)
  local want = tostring(offerId)
  for index, offer in ipairs(board.offers or {}) do
    if offer and tostring(offer.id) == want then
      return index, offer, board
    end
  end
  return nil, nil, board
end

-- Fleet car ids may arrive as strings from the UI; the stored id is the number when it reads as one.
local function normalizedVehicleId(vehicleId)
  return tonumber(vehicleId) or vehicleId
end

-- The race's entry fee is held as a pending race; its readiness delay is a random pick from the configured range.
local function buildPendingDriverRace(deps, picked)
  local pending = {}
  for key, value in pairs(picked) do
    pending[key] = value
  end
  local constants = deps.rtState.K
  local schedDelaySec = math.random(constants.SCHEDULED_RACE_MIN_SEC, constants.SCHEDULED_RACE_MAX_SEC)
  pending.scheduledRaceSimTime = deps.parts.board.getCareerSimTimeSeconds() + schedDelaySec
  pending.scheduledRaceReadyWallEpoch = os.time() + schedDelaySec
  pending.raceReadyToastSent = false
  return pending
end

local function setDriverPendingRace(deps, businessId, tech, pending)
  tech.pendingRaceOffer = pending
  tech.currentAction = "race_pending"
  tech.racingCooldownUntilSimTime = nil
  tech.postRaceCooldownReadyWallEpoch = nil
  deps.parts.results.racingTeamPersistDrivers(businessId)
end

local function attachDisplayHp(offer)
  local sanctioned = overhaul_events_fre_sanctionedRacing
  if sanctioned and type(sanctioned.attachSanctionedOfferDisplayHp) == "function" then
    sanctioned.attachSanctionedOfferDisplayHp(offer)
  end
end

local function debitEntryFee(deps, businessId, picked)
  return deps.racingTeamFinances().tryDebitRaceEntranceFee(businessId, picked, deps.rtState.rtInternal.getCurrentLeague(businessId))
end

-- Returns the offer to the board at its old index after a refused or failed commit.
local function restoreBoardOffer(deps, businessId, board, idx, picked)
  deps.racingTeamFinances().refundRaceEntranceFee(businessId, picked, deps.rtState.rtInternal.getCurrentLeague(businessId))
  table.insert(board.offers, idx, picked)
end

-- A fleet car that cannot race the offer is refused with a reason; nil means it may race.
local function playerFleetRefusal(deps, businessId, fleetVehicleId, picked)
  local parts = deps.parts
  if parts.board.fleetVehicleOverpoweredForOffer(businessId, fleetVehicleId, picked) then
    do
      guihooks.trigger("racingTeam:vehicleOutOfClass", { businessId = tostring(businessId) })
    end
    return "out_of_class"
  end
  if not parts.board.fleetVehicleEligibleForOffer(businessId, fleetVehicleId, picked) then
    local rawEl = parts.board.getBusinessVehicleRawByInventoryId(businessId, fleetVehicleId)
    local pwEl = rawEl and parts.fleet.getEffectiveTeamJobVehiclePw(businessId, rawEl)
    if not pwEl then
      racingMessage("Cannot read this fleet car's power-to-weight (dyno HP or curb weight missing). Try a dyno pull or another car.", 10, "warning")
      return "fleet_power_weight_unknown"
    end
    racingMessage("This fleet car is outside the race's power-to-weight bracket.", 8, "warning")
    return "not_eligible_pw"
  end
  if parts.fleet.getFleetVehiclePostRaceCooldownRemainingSec(businessId, fleetVehicleId) > 0 then
    do
      guihooks.trigger("racingTeam:vehicleOnCooldown", {
        businessId = tostring(businessId),
        vehicleId = tostring(fleetVehicleId),
        remainingSec = parts.fleet.getFleetVehiclePostRaceCooldownRemainingSec(businessId, fleetVehicleId),
      })
    end
    return "vehicle_cooldown"
  end
  return nil
end

-- Driver race offers ------------------------------------------------------------------------------


-- Same refusals as the player's car check, reported to the dev log for the driver's car.
local function driverFleetRefusal(deps, businessId, fleetVehicleId, picked)
  local parts = deps.parts
  if parts.board.fleetVehicleOverpoweredForOffer(businessId, fleetVehicleId, picked) then
    do
      guihooks.trigger("racingTeam:vehicleOutOfClass", { businessId = tostring(businessId) })
    end
    parts.helpers.rtDevLog(businessId, "warn", "Fleet vehicle out of class for offer", "race", { vehicleId = fleetVehicleId })
    return "out_of_class"
  end
  if not parts.board.fleetVehicleEligibleForOffer(businessId, fleetVehicleId, picked) then
    local rawEl = parts.board.getBusinessVehicleRawByInventoryId(businessId, fleetVehicleId)
    local pwEl = rawEl and parts.fleet.getEffectiveTeamJobVehiclePw(businessId, rawEl)
    if not pwEl then
      racingMessage("Cannot read this fleet car's power-to-weight (dyno or curb weight missing). Try a dyno pull or another car.", 10, "warning")
      parts.helpers.rtDevLog(businessId, "warn", "Fleet power/weight unknown for offer", "race", { vehicleId = fleetVehicleId })
      return "fleet_power_weight_unknown"
    end
    racingMessage("This fleet car is outside the race's power-to-weight bracket.", 8, "warning")
    parts.helpers.rtDevLog(businessId, "warn", "Fleet vehicle outside P/W bracket", "race", { vehicleId = fleetVehicleId })
    return "not_eligible_pw"
  end
  local rem = parts.fleet.getFleetVehiclePostRaceCooldownRemainingSec(businessId, fleetVehicleId)
  if rem > 0 then
    do
      guihooks.trigger("racingTeam:vehicleOnCooldown", {
        businessId = tostring(businessId),
        vehicleId = tostring(fleetVehicleId),
        remainingSec = rem,
      })
    end
    parts.helpers.rtDevLog(businessId, "warn", "Fleet vehicle on cooldown (" .. tostring(math.ceil(rem)) .. "s)", "race", { vehicleId = fleetVehicleId })
    return "vehicle_cooldown"
  end
  return nil
end

-- A hired driver with a free fleet car takes a League 1 offer; the race is scheduled for the driver.
local function acceptRacingTeamRaceOffer(deps, businessId, offerId, techId)
  local parts = deps.parts
  businessId = parts.helpers.normalizeBusinessId(businessId)
  techId = tonumber(techId)
  if not businessId or offerId == nil or not techId then return false end
  if deps.rtState.rtInternal.getCurrentLeague(businessId) == "league1" then return false end

  local tech = parts.board.getRacingTeamDriverById(businessId, techId)
  if not driverFreeForRace(tech) then return false end
  local fleetVehicleId = tech.fleetVehicleId
  if not fleetVehicleId or not parts.board.getBusinessVehicleRawByInventoryId(businessId, fleetVehicleId) then return false end
  if parts.fleet.getRacingTeamDriverPostRaceCooldownRemainingSec(businessId, tech) > 0 then
    racingMessage(string.format("%s is still recovering from their last race.", tech.name or "Driver"), 6, "warning")
    return false
  end

  local idx, picked, board = findBoardOffer(parts, businessId, offerId)
  if not idx then return false end
  local refusal = driverFleetRefusal(deps, businessId, fleetVehicleId, picked)
  if refusal then return refusal end
  if not debitEntryFee(deps, businessId, picked) then
    racingMessage("Not enough funds in the team account for the race entry fee.", 6, "warning")
    parts.helpers.rtDevLog(businessId, "warn", "Race entry fee debit failed", "race")
    return false
  end

  attachDisplayHp(picked)
  table.remove(board.offers, idx)
  setDriverPendingRace(deps, businessId, tech, buildPendingDriverRace(deps, picked))
  parts.raceOffers.topUp(businessId)
  overhaul_career_saveSystem.saveCurrent()
  racingMessage(
    string.format("Race scheduled for %s. On the offer map, use Scheduled races → Arm & go to jump to the grid.", tech.name or "driver"),
    7,
    "info"
  )
  parts.results.notifyRacingTeamDriversUpdated(businessId)
  return true
end

-- Rolls a proxy race for a driver in League 2 or higher, when the team has a level to race on.
local function assignRolledProxyRaceToDriver(deps, businessId, techId)
  local parts = deps.parts
  businessId = parts.helpers.normalizeBusinessId(businessId)
  techId = tonumber(techId)
  if not businessId or not techId then return false end
  if not deps.rtState.rtInternal.isCurrentLeagueAtLeast(businessId, 2) then return false end

  local tech = parts.board.getRacingTeamDriverById(businessId, techId)
  if not driverFreeForRace(tech) then return false end
  local fleetVehicleId = tech.fleetVehicleId
  if not fleetVehicleId or not parts.board.getBusinessVehicleRawByInventoryId(businessId, fleetVehicleId) then return false end
  if parts.fleet.getRacingTeamDriverPostRaceCooldownRemainingSec(businessId, tech) > 0 then
    racingMessage(string.format("%s is still recovering from their last race.", tech.name or "Driver"), 6, "warning")
    return false
  end

  local levelId = parts.board.getRacingTeamLevelId()
  if levelId == "" then return false end
  local now = parts.board.getCareerSimTime()
  local fv = fleetVehicleId and parts.board.getBusinessVehicleRawByInventoryId(businessId, fleetVehicleId)
  local branchFilter = fv and parts.fleet.resolveFleetVehicleSanctionedBranch(businessId, fv)
    or parts.fleet.getSanctionedBranchFilterForBusiness(businessId)
  local picked = parts.raceOffers.rollOneOffer(levelId, now, { branchFilter = branchFilter })
  if not picked then
    picked = parts.raceOffers.rollOneOffer(levelId, now)
  end
  if not picked then return false end
  if not parts.board.sanctionedOfferMatchesFleetVehicle(businessId, fleetVehicleId, picked) then
    racingMessage("This fleet car's hp/kg is outside this race's sanctioned class. Auto-assign skipped this offer.", 8, "warning")
    return false
  end
  if not debitEntryFee(deps, businessId, picked) then
    racingMessage("Not enough funds in the team account for the race entry fee.", 6, "warning")
    return false
  end

  attachDisplayHp(picked)
  setDriverPendingRace(deps, businessId, tech, buildPendingDriverRace(deps, picked))
  overhaul_career_saveSystem.saveCurrent()
  local levelInfo = parts.board.getRacingTeamLevelInfo(levelId)
  ui_message(
    string.format("Proxy race scheduled for %s. Use Scheduled races, then Arm & go.", tech.name or "driver"),
    7,
    levelInfo.msgProxyRaceScheduledToastTitle,
    "info"
  )
  parts.results.notifyRacingTeamDriversUpdated(businessId)
  return true
end

-- Fleet picker rows -------------------------------------------------------------------------------


-- One picker row for a team car; the car's formatted card supplies the name and power when it has one.
local function fleetPickerRow(deps, businessId, picked, vehicle, vid)
  local parts = deps.parts
  local overpowered = parts.board.fleetVehicleOverpoweredForOffer(businessId, vid, picked)
  local cooldownSec = parts.fleet.getFleetVehiclePostRaceCooldownRemainingSec(businessId, vid) or 0
  local row = {
    overpowered = overpowered,
    onCooldown = cooldownSec > 0,
    cooldownSec = cooldownSec,
  }
  local formatted = deps.rtState.formatVehicleForUI(vehicle, businessId)
  if formatted then
    row.vehicleId = formatted.vehicleId
    row.vehicleName = formatted.vehicleName
    row.fleetEffectiveHp = formatted.fleetEffectiveHp
    row.fleetEffectivePw = formatted.fleetEffectivePw
    row.fleetSanctionedClassLabel = formatted.fleetSanctionedClassLabel
    row.fleetClassStatusMessage = formatted.fleetClassStatusMessage
  else
    row.vehicleId = vid
    row.vehicleName = "Vehicle " .. tostring(vid)
  end
  return row
end

-- The business's team cars for an offer on the board, as picker rows; `extraFields` adds per-row values.
local function fleetPickerRows(deps, businessId, offerId, leagueAllowed, extraFields)
  local parts = deps.parts
  businessId = parts.helpers.normalizeBusinessId(businessId)
  if not businessId or offerId == nil then return {} end
  if not leagueAllowed(deps.rtState.rtInternal.getCurrentLeague(businessId)) then return {} end
  local _, picked = findBoardOffer(parts, businessId, offerId)
  if not picked then return {} end
  local inv = overhaul_career_business_fleet

  local vehicles = inv.getBusinessVehicles(businessId) or {}
  local extra = extraFields and extraFields(businessId) or {}
  local out = {}
  for _, vehicle in ipairs(vehicles) do
    local vid = vehicle and (tonumber(vehicle.vehicleId) or vehicle.vehicleId)
    if vid ~= nil then
      local row = fleetPickerRow(deps, businessId, picked, vehicle, vid)
      for key, value in pairs(extra) do row[key] = value end
      table.insert(out, row)
    end
  end
  return out
end

local function isLeague1(league) return league == "league1" end
local function isNotLeague1(league) return league ~= "league1" end

local function listLeague1FleetVehiclesForSanctionedOffer(deps, businessId, offerId)
  return fleetPickerRows(deps, businessId, offerId, isLeague1)
end

local function listLeague2FleetVehiclesForSanctionedOffer(deps, businessId, offerId)
  return fleetPickerRows(deps, businessId, offerId, isNotLeague1, function(id)
    local playerCooldownSec = deps.parts.fleet.getPlayerPostRaceCooldownRemainingSec(id) or 0
    return { playerOnCooldown = playerCooldownSec > 0, playerCooldownSec = playerCooldownSec }
  end)
end

-- Player races ------------------------------------------------------------------------------------


-- The car the player races: the one picked on the screen, else the league leaderboard's primary car.
local function playerFleetVehicleId(deps, businessId, fleetVehicleIdOpt)
  local fleetVehicleId = nil
  if fleetVehicleIdOpt ~= nil and fleetVehicleIdOpt ~= "" then
    fleetVehicleId = normalizedVehicleId(fleetVehicleIdOpt)
  else
    fleetVehicleId = deps.racingTeamGoals.getPrimaryLeaderboardVehicleId(businessId)
  end
  if not fleetVehicleId or not deps.parts.board.getBusinessVehicleRawByInventoryId(businessId, fleetVehicleId) then
    racingMessage("No valid fleet vehicle selected (inventory id missing or not found).", 8, "warning")
    return nil
  end
  return fleetVehicleId
end

-- Hands the player's race to the sanctioned flow; a refused start puts the offer back on the board.
local function commitPlayerRace(deps, businessId, board, idx, picked, want, pendingRace)
  local sanctioned = overhaul_events_fre_sanctionedRacing
  if not sanctioned or not sanctioned.commitAndNavigateExternalOffer then
    restoreBoardOffer(deps, businessId, board, idx, picked)
    log("W", "racingTeam", "commitAndNavigateExternalOffer missing; restored offer " .. tostring(want))
    racingMessage("Sanctioned racing module is not loaded. Restart or check the mod install.", 9, "error")
    return "sanctioned_module_missing"
  end

  local started, failMsg = sanctioned.commitAndNavigateExternalOffer(pendingRace, { bypassSkillGate = true })
  if started ~= true then
    log("W", "racingTeam", "commitAndNavigateExternalOffer returned false for offer " .. tostring(want) .. " err=" .. tostring(failMsg))
    restoreBoardOffer(deps, businessId, board, idx, picked)
    if type(failMsg) == "string" and failMsg ~= "" then
      racingMessage(failMsg, 10, "warning")
    else
      racingMessage("Could not start sanctioned race (see beamng.log). Offer was restored.", 9, "warning")
    end
    return type(failMsg) == "string" and failMsg ~= "" and failMsg or "sanctioned_commit_failed"
  end
  return true
end

-- The player's pending race: the offer as it stands, marked with the flag that names its kind.
local function buildPlayerRace(businessId, picked, fleetVehicleId, kindFlag)
  local pendingRace = {}
  for key, value in pairs(picked) do
    pendingRace[key] = value
  end
  pendingRace.scheduledRaceSimTime = nil
  pendingRace.scheduledRaceReadyWallEpoch = nil
  pendingRace.disciplineId = pendingRace.disciplineId or "roadracing"
  pendingRace[kindFlag] = true
  pendingRace.racingTeamBusinessOffer = true
  pendingRace.businessId = tostring(businessId)
  pendingRace.fleetVehicleId = normalizedVehicleId(fleetVehicleId)
  pendingRace.requiredFleetVehicleId = normalizedVehicleId(fleetVehicleId)
  return pendingRace
end

local function finishPlayerRace(deps, businessId, board, idx, picked, want, fleetVehicleId, kindFlag)
  table.remove(board.offers, idx)
  local pendingRace = buildPlayerRace(businessId, picked, fleetVehicleId, kindFlag)
  local committed = commitPlayerRace(deps, businessId, board, idx, picked, want, pendingRace)
  if committed ~= true then return committed end
  saveTeamState(deps.parts, businessId)
  deps.parts.raceOffers.topUp(businessId)
  overhaul_career_saveSystem.saveCurrent()
  return true
end

-- The player races a League 1 board offer in their own car.
local function acceptRacingTeamRaceOfferAsPlayer(deps, businessId, offerId, fleetVehicleIdOpt)
  local parts = deps.parts
  businessId = parts.helpers.normalizeBusinessId(businessId)
  if not businessId or offerId == nil then return "missing_args" end
  if deps.rtState.rtInternal.getCurrentLeague(businessId) ~= "league1" then
    racingMessage("League 1 (sanctioned board) is required to race from this screen.", 8, "warning")
    return "wrong_league"
  end
  local fleetVehicleId = playerFleetVehicleId(deps, businessId, fleetVehicleIdOpt)
  if not fleetVehicleId then return "bad_fleet_vehicle" end

  local idx, picked, board = findBoardOffer(parts, businessId, offerId)
  if not idx then
    racingMessage("That race offer is no longer on the board (refresh or pick another offer).", 8, "warning")
    return "offer_not_on_board"
  end
  local refusal = playerFleetRefusal(deps, businessId, fleetVehicleId, picked)
  if refusal then return refusal end
  if not debitEntryFee(deps, businessId, picked) then
    racingMessage("Not enough funds in the team account for the race entry fee.", 6, "warning")
    return "insufficient_funds"
  end
  return finishPlayerRace(deps, businessId, board, idx, picked, tostring(offerId), fleetVehicleId, "league1PlayerRace")
end

-- The player's race alongside a proxy: the player's own cooldown also applies, and the payout is reduced later.
local function acceptRacingTeamRaceOfferAsPlayerAlongsideProxy(deps, businessId, offerId, fleetVehicleIdOpt)
  local parts = deps.parts
  businessId = parts.helpers.normalizeBusinessId(businessId)
  if not businessId or offerId == nil then return "missing_args" end
  if deps.rtState.rtInternal.getCurrentLeague(businessId) == "league1" then
    racingMessage("Use the league 1 board for player races at this level.", 8, "warning")
    return "wrong_league"
  end
  local fleetVehicleId = playerFleetVehicleId(deps, businessId, fleetVehicleIdOpt)
  if not fleetVehicleId then return "bad_fleet_vehicle" end

  local idx, picked, board = findBoardOffer(parts, businessId, offerId)
  if not idx then
    racingMessage("That race offer is no longer on the board (refresh or pick another offer).", 8, "warning")
    return "offer_not_on_board"
  end
  local refusal = playerFleetRefusal(deps, businessId, fleetVehicleId, picked)
  if refusal then return refusal end
  local playerCdRem = parts.fleet.getPlayerPostRaceCooldownRemainingSec(businessId) or 0
  if playerCdRem > 0 then
    do
      guihooks.trigger("racingTeam:playerOnCooldown", {
        businessId = tostring(businessId),
        remainingSec = playerCdRem,
      })
    end
    racingMessage(string.format("You're still recovering from your last race (%d min left).", math.ceil(playerCdRem / 60)), 7, "warning")
    return "player_cooldown"
  end
  if not debitEntryFee(deps, businessId, picked) then
    racingMessage("Not enough funds in the team account for the race entry fee.", 6, "warning")
    return "insufficient_funds"
  end
  return finishPlayerRace(deps, businessId, board, idx, picked, tostring(offerId), fleetVehicleId, "playerProxyAlongsideRace")
end

local function declineRacingTeamRaceOffer(deps, businessId, offerId)
  local parts = deps.parts
  businessId = parts.helpers.normalizeBusinessId(businessId)
  if not businessId or offerId == nil then return false end
  parts.raceOffers.ensureBoard(businessId)
  local idx, _, board = findBoardOffer(parts, businessId, offerId)
  if not idx then return false end
  table.remove(board.offers, idx)
  parts.raceOffers.topUp(businessId)
  overhaul_career_saveSystem.saveCurrent()
  return true
end

-- Scheduled race readiness ------------------------------------------------------------------------

local function isScheduledRaceReadyForDriver(deps, businessId, techId)
  local parts = deps.parts
  local tech = parts.board.getRacingTeamDriverById(businessId, techId)
  if not tech or not tech.pendingRaceOffer then return true end
  local pendingRace = tech.pendingRaceOffer
  local wallDue = tonumber(pendingRace.scheduledRaceReadyWallEpoch)
  if wallDue and os.time() >= wallDue then return true end
  local simDue = tonumber(pendingRace.scheduledRaceSimTime)
  if not simDue then return true end
  return parts.board.getCareerSimTimeSeconds() >= simDue
end

local function raceReadyNotificationShown(businessId, driverName, raceLabel)
  local shopAppLevel = 0
  do
    shopAppLevel = math.floor(tonumber(overhaul_career_business_skillTree.getNodeProgress(businessId, "team-operations", "shop-app")) or 0)
  end
  local layout = phoneLayout.get()
  if shopAppLevel > 0 and layout and layout.fireNotification then
    layout.fireNotification("racingTeam.raceReady", {
      title = "Race Ready",
      message = raceLabel,
      kind = "racing",
      ttl = 10,
      meta = driverName,
      source = "Racing Team",
      sound = { soundClass = "AudioGui", type = "event:>UI>Missions>Info_Open" },
    })
  else
    ui_message(string.format("Team race ready for %s: %s.", driverName, raceLabel), 8, "Racing Team", "info")
  end
end

-- Announces a driver's race once it is due; the flag keeps it to one announcement.
local function notifyScheduledRaceReadyIfDue(deps, businessId, tech)
  if not tech then return false end
  local pending = tech.pendingRaceOffer
  if not pending or pending.raceReadyToastSent then return false end
  local simDue = tonumber(pending.scheduledRaceSimTime)
  local wallDue = tonumber(pending.scheduledRaceReadyWallEpoch)
  local simReady = not simDue or deps.parts.board.getCareerSimTimeSeconds() >= simDue
  local wallReady = wallDue and os.time() >= wallDue
  if not simReady and not wallReady then return false end

  pending.raceReadyToastSent = true
  local driverName = tech.name or string.format("Driver %s", tostring(tech.id or ""))
  local raceLabel = pending.raceLabel or pending.raceName or "the scheduled race"
  raceReadyNotificationShown(businessId, driverName, raceLabel)
  return true
end

local function processScheduledRaceReadyToastQueue(deps)
  local parts = deps.parts
  local purchased = overhaul_career_business_manager.getPurchasedBusinesses(deps.rtState.businessType)
  if not purchased then return end
  for bid, _ in pairs(purchased) do
    local businessId = parts.helpers.normalizeBusinessId(bid)
    local changed = false
    for _, tech in ipairs(deps.rtState.loadRacingTeamDrivers(businessId)) do
      if notifyScheduledRaceReadyIfDue(deps, businessId, tech) then
        changed = true
      end
    end
    if changed then
      parts.results.racingTeamPersistDrivers(businessId)
      parts.results.notifyRacingTeamDriversUpdated(businessId)
    end
  end
end

-- Proxy request store -----------------------------------------------------------------------------

local function clearProxyDriverRaceRequest(deps, businessId)
  local flow = deps.parts.helpers.raceFlowMod()
  if flow and flow.clearProxyDriverRaceRequest then
    flow.clearProxyDriverRaceRequest(businessId)
  end
end

local function getProxyDriverRaceRequest(deps, businessId)
  local flow = deps.parts.helpers.raceFlowMod()
  return flow and flow.getProxyDriverRaceRequest and flow.getProxyDriverRaceRequest(businessId)
end

-- Team XP -----------------------------------------------------------------------------------------

local function getRacingTeamBusinessSkillXpValue(deps, businessId)
  deps.parts.helpers.getOfferState(businessId)
  local id = tostring(deps.parts.helpers.normalizeBusinessId(businessId))
  return math.max(0, math.floor(tonumber(deps.rtState.businessSkillXpByBusiness[id]) or 0))
end

local function addRacingTeamBusinessSkillXpValue(deps, businessId, amount)
  local parts = deps.parts
  businessId = parts.helpers.normalizeBusinessId(businessId)
  if not businessId or not amount or amount <= 0 then return end
  parts.helpers.getOfferState(businessId)
  local id = tostring(businessId)
  local current = math.max(0, math.floor(tonumber(deps.rtState.businessSkillXpByBusiness[id]) or 0))
  deps.rtState.businessSkillXpByBusiness[id] = current + math.floor(amount)
  saveTeamState(parts, businessId)
end

local function spendRacingTeamBusinessSkillXpValue(deps, businessId, amount)
  local parts = deps.parts
  businessId = parts.helpers.normalizeBusinessId(businessId)
  if not businessId or not amount or amount <= 0 then return false end
  parts.helpers.getOfferState(businessId)
  local id = tostring(businessId)
  local current = math.max(0, math.floor(tonumber(deps.rtState.businessSkillXpByBusiness[id]) or 0))
  local need = math.floor(amount)
  if current < need then return false end
  deps.rtState.businessSkillXpByBusiness[id] = current - need
  saveTeamState(parts, businessId)
  return true
end

-- Driver class and proxy AI -----------------------------------------------------------------------

local function racingDriverSkillClassLabel(xp)
  local x = math.max(0, math.floor(tonumber(xp) or 0))
  if x >= 8000 then return "Elite" end
  if x >= 4000 then return "Veteran" end
  if x >= 1500 then return "Established" end
  if x >= 400 then return "Developing" end
  return "Rookie"
end

local function proxyDriverAiDifficultyBlendTFromXp(xp)
  local x = math.max(0, math.floor(tonumber(xp) or 0))
  if x >= 8000 then return 1 end
  if x >= 4000 then return 0.75 end
  if x >= 1500 then return 0.5 end
  if x >= 400 then return 0.25 end
  return 0
end

-- Stats for a driver after a sanctioned race; podiums count only when the race allows them.
local function applyProxySanctionedRaceDriverStats(deps, businessId, driverId, place, options)
  local parts = deps.parts
  businessId = parts.helpers.normalizeBusinessId(businessId)
  driverId = tonumber(driverId)
  place = tonumber(place)
  if not businessId or not driverId or not place then return end
  options = options or {}
  local eligiblePodium = options.eligiblePodium == true
  local xpGain = math.max(0, math.floor(tonumber(options.xpGain) or 0))
  local tech = parts.board.getRacingTeamDriverById(businessId, driverId)
  if not tech or tech.fired then return end

  parts.board.ensureRacingDriverIdentity(tech, tech.id)
  tech.sanctionedRacesFinished = tech.sanctionedRacesFinished + 1
  if eligiblePodium and place >= 1 and place <= 3 then
    tech.sanctionedPodiums = tech.sanctionedPodiums + 1
    if place == 1 then
      tech.sanctionedRaceWins = tech.sanctionedRaceWins + 1
    end
  end
  if xpGain > 0 then
    tech.racingSkillXp = tech.racingSkillXp + xpGain
  end
  parts.results.racingTeamPersistDrivers(businessId)
  parts.results.notifyRacingTeamDriversUpdated(businessId)
  deps.rtState.rtInternal.advanceRacingTeamGoalsIfReady(businessId)
end

-- Public API --------------------------------------------------------------------------------------


function part.new(inputs)
  local deps = {
    parts = inputs.parts,
    racingTeamFinances = inputs.racingTeamFinances,
    racingTeamGoals = inputs.racingTeamGoals,
    rtState = inputs.rtState,
  }

  local api = bindOperations(deps, {
    acceptRacingTeamRaceOffer = acceptRacingTeamRaceOffer,
    acceptRacingTeamRaceOfferAsPlayer = acceptRacingTeamRaceOfferAsPlayer,
    acceptRacingTeamRaceOfferAsPlayerAlongsideProxy = acceptRacingTeamRaceOfferAsPlayerAlongsideProxy,
    addRacingTeamBusinessSkillXpValue = addRacingTeamBusinessSkillXpValue,
    applyProxySanctionedRaceDriverStats = applyProxySanctionedRaceDriverStats,
    assignRolledProxyRaceToDriver = assignRolledProxyRaceToDriver,
    clearProxyDriverRaceRequest = clearProxyDriverRaceRequest,
    declineRacingTeamRaceOffer = declineRacingTeamRaceOffer,
    getProxyDriverRaceRequest = getProxyDriverRaceRequest,
    getRacingTeamBusinessSkillXpValue = getRacingTeamBusinessSkillXpValue,
    isScheduledRaceReadyForDriver = isScheduledRaceReadyForDriver,
    listLeague1FleetVehiclesForSanctionedOffer = listLeague1FleetVehiclesForSanctionedOffer,
    listLeague2FleetVehiclesForSanctionedOffer = listLeague2FleetVehiclesForSanctionedOffer,
    processScheduledRaceReadyToastQueue = processScheduledRaceReadyToastQueue,
    spendRacingTeamBusinessSkillXpValue = spendRacingTeamBusinessSkillXpValue,
  })
  -- Pure helpers take no instance state, so they are returned as they are.
  api.proxyDriverAiDifficultyBlendTFromXp = proxyDriverAiDifficultyBlendTFromXp
  api.racingDriverSkillClassLabel = racingDriverSkillClassLabel
  return api
end

return part
