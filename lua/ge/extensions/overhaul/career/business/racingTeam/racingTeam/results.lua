-- Racing team: proxy race settlement, League 1 outcomes, driver UI, proxy cleanup and staff operations.
-- Created by racingTeam.lua, which owns offer state access, lifecycle, saving, ticks and every M function.
local part = {}

local bindOperations = require("overhaul/career/business/racingTeam/racingTeam/bindOperations")

-- Config ------------------------------------------------------------------------------------------

local PODIUM_ANALYTICS_XP_PER_LEVEL = 0.1 -- each podium-analytics node level adds this share of podium XP
local REMATCH_DEFAULT_LAP_COUNT = 3
local REMATCH_DEFAULT_DEADLINE_MINUTES = 60

-- Shared helpers ----------------------------------------------------------------------------------

local function noReward(detail)
  return { money = 0, businessSkillXp = 0, noRewardDetail = detail }
end

local function hasDriverCapacity(parts, businessId)
  return parts.board.getRacingTeamDriverCapacity(businessId) >= 1
end

local function saveTeamState(parts, businessId)
  local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
  if savePath then
    parts.persist.saveRacingTeamPersistedState(businessId, savePath)
  end
end

local function racingTeamPersistDrivers(deps, businessId)
  local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
  if savePath then
    deps.parts.board.saveRacingTeamDrivers(businessId, savePath)
  end
end

local function notifyRaceOffersUpdated(deps, businessId)
  local uid = deps.rtState.rtInternal.getUIData(businessId)
  guihooks.trigger("businessComputer:onRaceOffersUpdated", {
    businessId = businessId,
    raceOffers = uid and uid.raceOffers or {},
    raceOffersLevelId = uid and uid.raceOffersLevelId,
    raceOffersNextRefreshAt = uid and uid.raceOffersNextRefreshAt,
    raceOffersMessage = uid and uid.raceOffersMessage,
    racingTeamProxyArmed = uid and uid.racingTeamProxyArmed,
  })
end

-- Lookup of an offer by id on the business's race board; returns its index and the offer.
local function findBoardOffer(board, offerId)
  local want = tostring(offerId)
  for index, offer in ipairs(board.offers or {}) do
    if offer and tostring(offer.id) == want then return index, offer end
  end
  return nil, nil
end

-- Proxy race settlement ---------------------------------------------------------------------------

-- The armed offer is the request's snapshot, or the driver's pending race when the snapshot is missing.
local function proxyOfferFor(parts, businessId, req)
  local offer = req and type(req.offerSnapshot) == "table" and req.offerSnapshot
  if not offer and req and tonumber(req.driverId) then
    local tech = parts.board.getRacingTeamDriverById(businessId, tonumber(req.driverId))
    offer = tech and tech.pendingRaceOffer
  end
  return offer
end

local function playerPlaceFrom(aiResults)
  for _, row in ipairs(aiResults) do
    if row.isPlayer then return tonumber(row.place) end
  end
  return nil
end

-- Arms the car the proxy driver raced, so it sits out its post-race cooldown.
local function armProxyFleetVehicle(parts, businessId, driverId, offer)
  local fleetVid = nil
  if driverId then
    local tech = parts.board.getRacingTeamDriverById(businessId, driverId)
    fleetVid = tech and tech.fleetVehicleId
  end
  if not fleetVid then
    fleetVid = tonumber(offer.requiredFleetVehicleId) or offer.requiredFleetVehicleId
      or tonumber(offer.fleetVehicleId) or offer.fleetVehicleId
  end
  if fleetVid then
    parts.fleet.armFleetVehiclePostRaceCooldown(businessId, fleetVid)
    saveTeamState(parts, businessId)
  end
end

-- The live car's power-to-weight must sit inside the offer's class; returns the reason it does not, or nil.
local function podiumClassBandReason(offer)
  local hMin = tonumber(offer.classPwMin) or tonumber(offer.classHpMin) or 0
  local hMax = tonumber(offer.classPwMax) or tonumber(offer.classHpMax) or hMin
  if hMax < hMin then
    hMin, hMax = hMax, hMin
  end
  local aiRacers = overhaul_events_aiRacers
  if not ((hMax > 0 or hMin > 0) and aiRacers and aiRacers.getPlayerVehiclePwForPodiumCapCheck) then
    return nil
  end
  local pwLive = aiRacers.getPlayerVehiclePwForPodiumCapCheck()
  if type(pwLive) ~= "number" then return nil end
  if pwLive > hMax then return "Over class hp/kg limit — no podium rewards." end
  if pwLive < hMin then return "Below class minimum hp/kg — no podium rewards." end
  return nil
end

local function recordProxyRace(parts, businessId, driverId, place, eligiblePodium, xpGain)
  parts.dispatch.applyProxySanctionedRaceDriverStats(businessId, driverId, place, { eligiblePodium = eligiblePodium, xpGain = xpGain })
end

-- Announces the podium with a copy of the offer, so the stored offer is left as it was.
local function notifyPodium(deps, businessId, place, offer)
  local offerForNotify = offer
  if type(offer) == "table" then
    offerForNotify = {}
    for key, value in pairs(offer) do
      offerForNotify[key] = value
    end
    offerForNotify.racingTeamBusinessOffer = true
    offerForNotify.businessId = offerForNotify.businessId or businessId
  end
  deps.M.notifyOfficialSanctionedPodium(place, offerForNotify)
end

local function podiumBaseReward(offer, place)
  if place == 1 then return tonumber(offer.payoutFirst) or 0, offer.xpFirst end
  if place == 2 then return tonumber(offer.payoutSecond) or 0, offer.xpSecond end
  if place == 3 then return tonumber(offer.payoutThird) or 0, offer.xpThird end
  return 0, nil
end

-- Money and XP for a podium place, after the sponsor and podium-analytics bonuses.
local function podiumRewardFor(parts, businessId, offer, place)
  local amount, xpStored = podiumBaseReward(offer, place)
  amount = math.floor(math.max(0, amount))
  local xpNum = tonumber(xpStored)
  local xpAmount = (xpNum ~= nil) and math.max(0, math.floor(xpNum)) or parts.helpers.proxyPodiumXpFromMoney(amount)
  local moneyBonus, xpBonus = parts.sponsors.bonusTotals(businessId)
  amount = math.floor(amount * (1 + moneyBonus) + 0.5)
  xpAmount = math.floor(xpAmount * (1 + xpBonus) + 0.5)
  local analyticsLevel = parts.helpers.getSkillTreeNodeLevel(businessId, "driver", "podium-analytics")
  if analyticsLevel > 0 then
    xpAmount = math.floor(xpAmount * (1 + PODIUM_ANALYTICS_XP_PER_LEVEL * analyticsLevel) + 0.5)
  end
  return amount, xpAmount
end

local function depositPodiumPayout(deps, businessId, place, amount)
  local businessAccount = overhaul_career_economy_bank.getBusinessAccount(deps.rtState.businessType, businessId)
  local accountId = businessAccount and (businessAccount.id or businessAccount.accountId)
  if not accountId then return nil, "No business account — reward not applied." end
  local ok = overhaul_career_economy_bank.rewardToAccount({
    money = { amount = amount, canBeNegative = false },
  }, accountId, string.format("Sanctioned team race — P%d", place), "Racing team circuit payout", {category = "business"})
  if not ok then return nil, "Could not deposit race payout." end
  return true, nil
end

local function applyDriverCut(deps, businessId, driverId, amount)
  local driver = driverId and deps.parts.board.getRacingTeamDriverById(businessId, driverId)
  deps.racingTeamFinances().applyDriverCutAfterPayout(businessId, amount, {
    racingSkillXp = driver and driver.racingSkillXp,
    driverName = driver and driver.name,
  })
end

-- Pays a podium place and credits its XP; each refusal still counts the race for the driver, without reward.
local function settlePodium(deps, businessId, driverId, offer, place)
  local parts = deps.parts
  notifyPodium(deps, businessId, place, offer)
  local amount, xpAmount = podiumRewardFor(parts, businessId, offer, place)
  if amount <= 0 then
    recordProxyRace(parts, businessId, driverId, place, true, 0)
    overhaul_career_saveSystem.saveCurrent()
    return noReward("No payout configured for this podium position.")
  end
  if not overhaul_career_career or not overhaul_career_career.isActive() then
    recordProxyRace(parts, businessId, driverId, place, true, 0)
    return noReward("Bank unavailable — reward not applied.")
  end
  local paid, refusal = depositPodiumPayout(deps, businessId, place, amount)
  if not paid then
    recordProxyRace(parts, businessId, driverId, place, true, 0)
    return noReward(refusal)
  end

  applyDriverCut(deps, businessId, driverId, amount)
  if xpAmount > 0 then
    parts.dispatch.addRacingTeamBusinessSkillXpValue(businessId, xpAmount)
  end
  recordProxyRace(parts, businessId, driverId, place, true, xpAmount)
  overhaul_career_saveSystem.saveCurrent()
  return { money = amount, businessSkillXp = xpAmount, noRewardDetail = nil }
end

local function settleProxySanctionedRaceFromAiResults(deps, businessId, aiResults)
  local parts = deps.parts
  businessId = parts.helpers.normalizeBusinessId(businessId)
  if not businessId then return noReward("Invalid business.") end
  parts.helpers.getOfferState(businessId)
  local req = parts.dispatch.getProxyDriverRaceRequest(businessId)
  local offer = proxyOfferFor(parts, businessId, req)
  if not offer then return noReward("No team race offer on file.") end
  if not aiResults then return noReward("No race results — no podium reward.") end
  local place = playerPlaceFrom(aiResults)
  if not place then return noReward("Couldn't determine placement — no podium reward.") end

  local driverId = req and tonumber(req.driverId)
  armProxyFleetVehicle(parts, businessId, driverId, offer)
  local bandReason = podiumClassBandReason(offer)
  if place >= 1 and place <= 3 then
    if bandReason then
      recordProxyRace(parts, businessId, driverId, place, false, 0)
      return noReward(bandReason)
    end
    return settlePodium(deps, businessId, driverId, offer, place)
  end
  recordProxyRace(parts, businessId, driverId, place, false, 0)
  return noReward("Didn't place on the podium — no podium rewards.")
end

-- League 1 outcomes -------------------------------------------------------------------------------

local function clearPendingRematch(parts, businessId)
  local old = parts.raceOffers.getPendingRematch(businessId)
  if type(old) == "table" and old.id then
    parts.raceOffers.removeOfferById(parts.raceOffers.getBoard(businessId), old.id)
  end
  parts.raceOffers.setPendingRematch(businessId, nil)
end

-- A rematch of a lost race, capped at the lineup's strongest car; returns the offer.
local function buildRematchOffer(parts, businessId, offer, reason)
  local lineup = parts.raceOffers.normalizeLineupSnapshot(offer.rematchAiLineupSnapshot)
  local capHp = parts.raceOffers.lineupMaxPw(lineup, offer.classPwMax or offer.classHpMax)
  local rematchId = string.format("rt-rematch-%s-%d", tostring(businessId), math.floor(parts.board.getCareerSimTime() * 1000))
  return {
    id = rematchId,
    disciplineId = offer.disciplineId or "roadracing",
    raceName = offer.raceName,
    raceLabel = (offer.raceLabel or offer.raceName or "Race") .. " - Rematch",
    stageNumber = tonumber(offer.stageNumber) or 1,
    raceRouteType = offer.raceRouteType,
    hpBracketId = offer.hpBracketId,
    hpBracketBranch = offer.hpBracketBranch,
    hpBracketLabel = offer.hpBracketLabel,
    hpBracketPayoutMult = offer.hpBracketPayoutMult,
    classPwMin = tonumber(offer.classPwMin) or tonumber(offer.classHpMin) or 0,
    classPwMax = tonumber(capHp) or tonumber(offer.classPwMax) or tonumber(offer.classHpMax),
    classHpMin = tonumber(offer.classPwMin) or tonumber(offer.classHpMin) or 0,
    classHpMax = tonumber(capHp) or tonumber(offer.classPwMax) or tonumber(offer.classHpMax),
    lapCount = tonumber(offer.lapCount) or REMATCH_DEFAULT_LAP_COUNT,
    payoutFirst = offer.payoutFirst,
    payoutSecond = offer.payoutSecond,
    payoutThird = offer.payoutThird,
    xpFirst = offer.xpFirst,
    xpSecond = offer.xpSecond,
    xpThird = offer.xpThird,
    startDeadlineMinutes = tonumber(offer.startDeadlineMinutes) or REMATCH_DEFAULT_DEADLINE_MINUTES,
    phase = "available",
    isRematch = true,
    rematchReason = type(reason) == "string" and reason or "non_win",
    rematchSourceOfferId = offer.id,
    requiredFleetVehicleId = tonumber(offer.requiredFleetVehicleId) or offer.requiredFleetVehicleId,
    rematchMaxAiPw = tonumber(capHp) or tonumber(offer.classPwMax) or tonumber(offer.classHpMax),
    rematchMaxAiHp = tonumber(capHp) or tonumber(offer.classPwMax) or tonumber(offer.classHpMax),
    rematchAiLineupSnapshot = lineup,
  }
end

-- Puts the rematch on the board in front, dropping the oldest offers over the board's limit.
local function placeRematchOnBoard(parts, businessId, rematch)
  local board = parts.raceOffers.getBoard(businessId)
  parts.raceOffers.removeOfferById(board, rematch.id)
  table.insert(board.offers, 1, rematch)
  while #board.offers > parts.helpers.getMaxRaceOffersOnBoard(businessId) do
    table.remove(board.offers, #board.offers)
  end
end

local function onBusinessSanctionedRaceOutcome(deps, offer, place, reason)
  if type(offer) ~= "table" or offer.racingTeamBusinessOffer ~= true then return end
  local parts = deps.parts
  local businessId = parts.helpers.normalizeBusinessId(offer.businessId)
  if not businessId then return end
  if deps.rtState.rtInternal.getCurrentLeague(businessId) ~= "league1" then return end
  parts.helpers.getOfferState(businessId)
  if tonumber(place) == 1 then
    clearPendingRematch(parts, businessId)
    return
  end

  local rematch = buildRematchOffer(parts, businessId, offer, reason)
  local srRem = overhaul_events_fre_sanctionedRacing
  if srRem and type(srRem.attachSanctionedOfferDisplayHp) == "function" then
    srRem.attachSanctionedOfferDisplayHp(rematch)
  end
  parts.raceOffers.setPendingRematch(businessId, rematch)
  placeRematchOnBoard(parts, businessId, rematch)
  overhaul_career_saveSystem.saveCurrent()
end

local function findProxyDriverRaceRequestForLevel(deps, levelId)
  local flow = deps.parts.helpers.raceFlowMod()
  if flow and flow.findProxyDriverRaceRequestForLevel then
    return flow.findProxyDriverRaceRequestForLevel(levelId)
  end
  return nil, nil
end

-- Driver UI rows ----------------------------------------------------------------------------------

local function driverStatusLabel(tech, job, postRaceCooldownSec)
  if tech.pendingRaceOffer then
    local pr = tech.pendingRaceOffer
    return string.format("Sanctioned race: %s", pr.raceLabel or pr.raceName or "Race")
  end
  if tech.jobId and job then
    return job.vehicleName and string.format("Assigned: %s", job.vehicleName) or "Assigned to job"
  end
  if tech.jobId then return "Assigned" end
  if postRaceCooldownSec > 0 then
    return string.format("Cooldown (~%dm)", math.max(1, math.ceil(postRaceCooldownSec / 60)))
  end
  return "Idle"
end

-- Seconds until a scheduled race can start, read from the sim clock and the wall clock, whichever are set.
local function scheduledRaceTiming(parts, pendingRace)
  local timing = { simTime = nil, wallEpoch = nil, secondsUntil = nil, ready = true }
  if not pendingRace then return timing end
  timing.simTime = tonumber(pendingRace.scheduledRaceSimTime)
  timing.wallEpoch = tonumber(pendingRace.scheduledRaceReadyWallEpoch)

  local nowSim = parts.board.getCareerSimTimeSeconds()
  local simRem = nil
  if timing.simTime then
    simRem = math.max(0, timing.simTime - nowSim)
    timing.ready = nowSim >= timing.simTime
  end
  local wallRem = nil
  if timing.wallEpoch then
    wallRem = math.max(0, timing.wallEpoch - os.time())
    if wallRem <= 0 then
      timing.ready = true
    end
  end

  if simRem and wallRem then
    timing.secondsUntil = math.min(simRem, wallRem)
  elseif wallRem then
    timing.secondsUntil = wallRem
    timing.ready = wallRem <= 0 or timing.ready
  elseif simRem then
    timing.secondsUntil = simRem
  end
  return timing
end

local function fleetVehicleNameFor(parts, businessId, fleetVehicleId)
  if not fleetVehicleId then return nil end
  local rawVehicle = parts.board.getBusinessVehicleRawByInventoryId(businessId, fleetVehicleId)
  if not rawVehicle then return "Unavailable" end
  local modelKey = rawVehicle.vehicleConfig and rawVehicle.vehicleConfig.model_key or nil
  return modelKey or ("Vehicle " .. tostring(tonumber(rawVehicle.vehicleId) or rawVehicle.vehicleId))
end

local function formatRacingTeamDriverForUI(deps, businessId, tech)
  if not tech then return nil end
  local parts = deps.parts
  parts.board.ensureRacingDriverIdentity(tech, tech.id)
  local postRaceCd = parts.fleet.getRacingTeamDriverPostRaceCooldownRemainingSec(businessId, tech)
  local job = nil
  if tech.jobId then
    job = parts.board.getRacingTeamActiveJobByJobId(businessId, tech.jobId)
  end
  local label = driverStatusLabel(tech, job, postRaceCd)
  local jobLabel = job and (job.raceLabel or job.vehicleName) or nil
  local jobReward = job and tonumber(job.reward) or nil
  local timing = scheduledRaceTiming(parts, tech.pendingRaceOffer)
  local fleetVehicleName = fleetVehicleNameFor(parts, businessId, tech.fleetVehicleId)

  return {
    id = tech.id,
    name = tech.name,
    state = tech.state or 0,
    action = tech.currentAction or "idle",
    label = label,
    progress = 0,
    elapsedSeconds = 0,
    totalSeconds = 0,
    serverTime = os.clock(),
    jobId = tech.jobId,
    jobLabel = jobLabel,
    jobReward = jobReward,
    fleetVehicleId = tech.fleetVehicleId,
    fleetVehicleName = fleetVehicleName,
    pendingRaceOffer = tech.pendingRaceOffer,
    scheduledRaceSimTime = timing.simTime,
    scheduledRaceReadyWallEpoch = timing.wallEpoch,
    secondsUntilScheduledRace = timing.secondsUntil,
    scheduledRaceReady = timing.ready,
    canAssign = not tech.fired
      and not tech.jobId
      and not tech.pendingRaceOffer
      and (tech.currentAction == "idle")
      and postRaceCd <= 0,
    postRaceCooldownRemainingSec = postRaceCd,
    racingCooldownUntilSimTime = tonumber(tech.racingCooldownUntilSimTime),
    postRaceCooldownReadyWallEpoch = tonumber(tech.postRaceCooldownReadyWallEpoch),
    fired = tech.fired or false,
    successfulJobs = tech.successfulJobs or 0,
    failedJobs = tech.failedJobs or 0,
    racingSkillXp = tech.racingSkillXp,
    driverSkillClass = parts.dispatch.racingDriverSkillClassLabel(tech.racingSkillXp),
    sanctionedRacesFinished = tech.sanctionedRacesFinished,
    sanctionedRaceWins = tech.sanctionedRaceWins,
    sanctionedPodiums = tech.sanctionedPodiums,
  }
end

local function notifyRacingTeamDriversUpdated(deps, businessId)
  if not businessId or not hasDriverCapacity(deps.parts, businessId) then return end
  local techEntries = {}
  for _, tech in ipairs(deps.rtState.loadRacingTeamDrivers(businessId)) do
    local formatted = formatRacingTeamDriverForUI(deps, businessId, tech)
    if formatted then
      table.insert(techEntries, formatted)
    end
  end
  do
    guihooks.trigger("businessComputer:onTechsUpdated", {
      businessType = deps.rtState.businessType,
      businessId = tostring(businessId),
      techs = techEntries,
    })
  end
end

-- Proxy cleanup and returning an offer to the board -----------------------------------------------

-- Returns the offer to the board unless an offer with the same id is already listed.
local function pushRaceOfferBackToBoardIfRoom(parts, businessId, offerTable)
  if type(offerTable) ~= "table" or offerTable.id == nil then return end
  local board = parts.raceOffers.getBoard(businessId)
  board.offers = board.offers or {}
  local index = findBoardOffer(board, offerTable.id)
  if index then return end

  local restored = {}
  for key, value in pairs(offerTable) do
    if key ~= "scheduledRaceSimTime" and key ~= "scheduledRaceReadyWallEpoch" then
      restored[key] = value
    end
  end
  restored.phase = restored.phase or "available"
  table.insert(board.offers, restored)
end

-- The driver whose proxy race is armed: the one the request names, else the first armed driver.
local function armedProxyDriver(deps, businessId, req)
  local driverId = req and tonumber(req.driverId)
  local tech = driverId and deps.parts.board.getRacingTeamDriverById(businessId, driverId)
  if tech and tech.fired then tech = nil end
  if not tech and driverId == nil then
    for _, candidate in ipairs(deps.rtState.loadRacingTeamDrivers(businessId)) do
      if candidate and not candidate.fired and candidate.pendingRaceOffer and candidate.currentAction == "race_pending" then
        return candidate, false
      end
    end
  end
  return tech, driverId ~= nil
end

-- Starts the post-race cooldown for the car and driver after an armed race was dropped without running.
local function startPostRaceCooldown(parts, businessId, tech)
  local cdSec = parts.fleet.getRacingTeamPostRaceCooldownSeconds(businessId)
  local nowSim = parts.board.getCareerSimTimeSeconds()
  tech.racingCooldownUntilSimTime = nowSim + cdSec
  tech.postRaceCooldownReadyWallEpoch = os.time() + cdSec
end

local function clearRacingTeamProxyDriverAssignment(deps, businessId, opts)
  opts = opts or {}
  local parts = deps.parts
  businessId = parts.helpers.normalizeBusinessId(businessId)
  if not businessId then return false end
  parts.helpers.getOfferState(businessId)

  local req = opts.proxyRequest
  if type(req) ~= "table" then
    req = parts.dispatch.getProxyDriverRaceRequest(businessId)
  end
  local tech, explicitDriver = armedProxyDriver(deps, businessId, req)
  if not tech or tech.fired then return false end
  if not tech.pendingRaceOffer then return explicitDriver end

  local pendingCopy = tech.pendingRaceOffer
  tech.pendingRaceOffer = nil
  tech.currentAction = "idle"
  if not opts.returnOfferToBoard then
    startPostRaceCooldown(parts, businessId, tech)
  end
  racingTeamPersistDrivers(deps, businessId)
  if opts.returnOfferToBoard then
    pushRaceOfferBackToBoardIfRoom(parts, businessId, pendingCopy)
    if opts.refundEntryFee then
      deps.racingTeamFinances().refundRaceEntranceFee(businessId, pendingCopy, deps.rtState.rtInternal.getCurrentLeague(businessId))
    end
  end
  parts.raceOffers.topUp(businessId)
  saveTeamState(parts, businessId)
  overhaul_career_saveSystem.saveCurrent()
  notifyRacingTeamDriversUpdated(deps, businessId)
  return true
end

-- Drops a scheduled race whose car never armed, refunding its entry fee and returning the offer.
local function cancelUnarmedScheduledRacingTeamProxyRace(deps, businessId, driverId)
  local parts = deps.parts
  businessId = parts.helpers.normalizeBusinessId(businessId)
  driverId = tonumber(driverId)
  if not businessId or not driverId then
    return { ok = false, err = "missing_business_or_driver" }
  end
  local tech = parts.board.getRacingTeamDriverById(businessId, driverId)
  if not tech or tech.fired or not tech.pendingRaceOffer then
    return { ok = false, err = "no_pending_race_offer" }
  end

  local pendingCopy = tech.pendingRaceOffer
  tech.pendingRaceOffer = nil
  tech.currentAction = "idle"
  racingTeamPersistDrivers(deps, businessId)
  pushRaceOfferBackToBoardIfRoom(parts, businessId, pendingCopy)
  deps.racingTeamFinances().refundRaceEntranceFee(businessId, pendingCopy, deps.rtState.rtInternal.getCurrentLeague(businessId))
  parts.raceOffers.topUp(businessId)
  saveTeamState(parts, businessId)
  overhaul_career_saveSystem.saveCurrent()
  notifyRacingTeamDriversUpdated(deps, businessId)
  notifyRaceOffersUpdated(deps, businessId)
  return { ok = true }
end

local function clearStuckRacingTeamProxyAfterTrackRaceCompletion(deps, raceName)
  if not overhaul_career_career or not overhaul_career_career.isActive() then return end
  local purchased = overhaul_career_business_manager.getPurchasedBusinesses(deps.rtState.businessType)
  if not purchased then return end
  for bid, _ in pairs(purchased) do
    local req = deps.parts.dispatch.getProxyDriverRaceRequest(bid)
    if req and req.racingTeamProxyRace and raceName and req.raceName == raceName then
      clearRacingTeamProxyDriverAssignment(deps, bid, {
        returnOfferToBoard = false,
        proxyRequest = req,
      })
      deps.parts.dispatch.clearProxyDriverRaceRequest(bid)
    end
  end
end

-- Staff assignment --------------------------------------------------------------------------------

local function clearRacingTeamDriverAssignmentForJob(deps, businessId, jobId)
  local parts = deps.parts
  for _, tech in ipairs(deps.rtState.loadRacingTeamDrivers(businessId)) do
    if tech.jobId and parts.board.jobIdsMatch(jobId, tech.jobId) then
      tech.jobId = nil
      tech.currentAction = "idle"
    end
  end
  local job = parts.board.getRacingTeamActiveJobByJobId(businessId, jobId)
  if job then
    job.techAssigned = nil
    job.locked = false
  end
end

local function syncRacingTeamDriverUnlock(deps, businessId)
  deps.rtState.loadRacingTeamDrivers(businessId)
  racingTeamPersistDrivers(deps, businessId)
end

local function assignJobToTech(deps, businessId, techId, jobId)
  local parts = deps.parts
  businessId = parts.helpers.normalizeBusinessId(businessId)
  techId = tonumber(techId)
  jobId = tonumber(jobId) or jobId
  if parts.board.getRacingTeamDriverCapacity(businessId) < 1 then return false end
  if not businessId or not techId or not jobId then return false end
  local tech = parts.board.getRacingTeamDriverById(businessId, techId)
  if not tech or tech.fired or tech.jobId or tech.pendingRaceOffer then return false end
  local job = parts.board.getRacingTeamActiveJobByJobId(businessId, jobId)
  if not job then return false end
  if job.techAssigned and job.techAssigned ~= techId then return false end

  for _, other in ipairs(deps.rtState.loadRacingTeamDrivers(businessId)) do
    if other.id ~= techId and other.jobId and parts.board.jobIdsMatch(other.jobId, jobId) then
      other.jobId = nil
      other.currentAction = "idle"
    end
  end
  tech.jobId = jobId
  tech.currentAction = "assigned"
  job.techAssigned = techId
  job.locked = true
  racingTeamPersistDrivers(deps, businessId)
  notifyRacingTeamDriversUpdated(deps, businessId)
  return true
end

local function assignFleetVehicleToDriver(deps, businessId, techId, vehicleId)
  local parts = deps.parts
  businessId = parts.helpers.normalizeBusinessId(businessId)
  techId = tonumber(techId)
  vehicleId = tonumber(vehicleId) or vehicleId
  if parts.board.getRacingTeamDriverCapacity(businessId) < 1 then return false end
  if not businessId or not techId or not vehicleId then return false end
  local tech = parts.board.getRacingTeamDriverById(businessId, techId)
  if not tech or tech.fired or tech.pendingRaceOffer then return false end
  if not parts.board.getBusinessVehicleRawByInventoryId(businessId, vehicleId) then return false end

  for _, other in ipairs(deps.rtState.loadRacingTeamDrivers(businessId)) do
    if other.id ~= techId and other.fleetVehicleId and parts.board.jobIdsMatch(other.fleetVehicleId, vehicleId) then
      other.fleetVehicleId = nil
    end
  end
  tech.fleetVehicleId = tonumber(vehicleId) or vehicleId
  racingTeamPersistDrivers(deps, businessId)
  notifyRacingTeamDriversUpdated(deps, businessId)
  return true
end

local function updateTechName(deps, businessId, techId, newName)
  local parts = deps.parts
  businessId = parts.helpers.normalizeBusinessId(businessId)
  techId = tonumber(techId)
  if not hasDriverCapacity(parts, businessId) or not businessId or not techId then return false end
  local tech = parts.board.getRacingTeamDriverById(businessId, techId)
  if not tech then return false end
  if type(newName) ~= "string" then return false end

  local trimmed = newName:match("^%s*(.-)%s*$")
  if trimmed == "" then
    trimmed = string.format("Driver #%d", techId)
  end
  tech.name = trimmed
  racingTeamPersistDrivers(deps, businessId)
  notifyRacingTeamDriversUpdated(deps, businessId)
  return true
end

local function fireTech(deps, businessId, techId)
  local parts = deps.parts
  businessId = parts.helpers.normalizeBusinessId(businessId)
  techId = tonumber(techId)
  if not hasDriverCapacity(parts, businessId) or not businessId or not techId then return false end
  local tech = parts.board.getRacingTeamDriverById(businessId, techId)
  if not tech or tech.fired then return false end
  if tech.jobId or tech.pendingRaceOffer then return false end

  tech.fired = true
  tech.fleetVehicleId = nil
  racingTeamPersistDrivers(deps, businessId)
  notifyRacingTeamDriversUpdated(deps, businessId)
  return true
end

local function countHiredDrivers(deps, businessId)
  local hiredCount = 0
  for _, tech in ipairs(deps.rtState.loadRacingTeamDrivers(businessId)) do
    if not tech.fired then
      hiredCount = hiredCount + 1
    end
  end
  return hiredCount
end

local function hireTech(deps, businessId, techId)
  local parts = deps.parts
  businessId = parts.helpers.normalizeBusinessId(businessId)
  techId = tonumber(techId)
  if not hasDriverCapacity(parts, businessId) or not businessId or not techId then return false end
  local tech = parts.board.getRacingTeamDriverById(businessId, techId)
  if not tech or not tech.fired then return false end
  if countHiredDrivers(deps, businessId) >= parts.board.getRacingTeamDriverCapacity(businessId) then return false end

  tech.fired = false
  parts.board.ensureRacingTeamDriverSlots(businessId)
  racingTeamPersistDrivers(deps, businessId)
  notifyRacingTeamDriversUpdated(deps, businessId)
  deps.rtState.rtInternal.advanceRacingTeamGoalsIfReady(businessId)
  return true
end

local function stopTechFromJob(deps, businessId, techId)
  local parts = deps.parts
  businessId = parts.helpers.normalizeBusinessId(businessId)
  techId = tonumber(techId)
  if not hasDriverCapacity(parts, businessId) or not businessId or not techId then return false end
  local tech = parts.board.getRacingTeamDriverById(businessId, techId)
  if not tech or tech.fired or not tech.jobId then return false end

  local jobId = tech.jobId
  tech.jobId = nil
  tech.currentAction = "idle"
  local job = parts.board.getRacingTeamActiveJobByJobId(businessId, jobId)
  if job then
    job.techAssigned = nil
    job.locked = false
  end
  racingTeamPersistDrivers(deps, businessId)
  notifyRacingTeamDriversUpdated(deps, businessId)
  return true
end

-- Pure lookup of the active job stored on a vehicle; used by the jobs part without the deps.
local function findActiveVehicleJobByVehicleId(state, vehicleId)
  local vid = tonumber(vehicleId) or vehicleId
  if vid == nil then return nil, nil end
  for index, activeJob in ipairs(state.active or {}) do
    if activeJob.storedVehicleId ~= nil and (tonumber(activeJob.storedVehicleId) or activeJob.storedVehicleId) == vid then
      return index, activeJob
    end
  end
  return nil, nil
end

-- Public API --------------------------------------------------------------------------------------

function part.new(inputs)
  local deps = {
    parts = inputs.parts,
    M = inputs.M,
    racingTeamFinances = inputs.racingTeamFinances,
    rtState = inputs.rtState,
  }

  local api = bindOperations(deps, {
    assignFleetVehicleToDriver = assignFleetVehicleToDriver,
    assignJobToTech = assignJobToTech,
    cancelUnarmedScheduledRacingTeamProxyRace = cancelUnarmedScheduledRacingTeamProxyRace,
    clearRacingTeamDriverAssignmentForJob = clearRacingTeamDriverAssignmentForJob,
    clearRacingTeamProxyDriverAssignment = clearRacingTeamProxyDriverAssignment,
    clearStuckRacingTeamProxyAfterTrackRaceCompletion = clearStuckRacingTeamProxyAfterTrackRaceCompletion,
    findProxyDriverRaceRequestForLevel = findProxyDriverRaceRequestForLevel,
    fireTech = fireTech,
    formatRacingTeamDriverForUI = formatRacingTeamDriverForUI,
    hireTech = hireTech,
    notifyRacingTeamDriversUpdated = notifyRacingTeamDriversUpdated,
    onBusinessSanctionedRaceOutcome = onBusinessSanctionedRaceOutcome,
    racingTeamPersistDrivers = racingTeamPersistDrivers,
    settleProxySanctionedRaceFromAiResults = settleProxySanctionedRaceFromAiResults,
    stopTechFromJob = stopTechFromJob,
    syncRacingTeamDriverUnlock = syncRacingTeamDriverUnlock,
    updateTechName = updateTechName,
  })
  -- Plain lookup: the jobs part calls it with (state, vehicleId), not through the deps.
  api.findActiveVehicleJobByVehicleId = findActiveVehicleJobByVehicleId
  return api
end

return part
