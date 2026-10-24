-- Sanctioned offers, class brackets and once-only podium settlement.
-- Read configuration/state, offer/dispatch services, race observation, settlement and lifecycle.
local recordPodium = require("overhaul/lib/progression/logbookFeed").register("overhaul.sanctionedRaceCompleted", {
  title = "Sanctioned race completed", label = "Events", icon = "flag"
}, "events/fre/sanctionedRacing.lua")

local M = {}

local freConfig = require("overhaul/events/freConfig")

-- Config ------------------------------------------------------------------------------------------

local CONFIG_DIR = "competitiveRace"
local CONFIG_RACE_FILENAME = "aiRacingConfig.json"
local DISCIPLINE_ROAD = "roadracing"

local DEFAULT_PODIUM_MULT = { first = 8, second = 4.5, third = 2.5 }
local DEFAULT_PODIUM_VARIANCE = { min = 0.84, max = 1.16 }
local PLACE_JITTER = { min = 0.92, max = 1.08 }

-- Loopable sanctioned offers: max laps ≈ how many target-time laps fit in 10 minutes; roll min..max; scale payouts vs design lapCount in race_data.
local SANCTIONED_MAX_WINDOW_SEC = 600
local SANCTIONED_LAP_ROLL_CAP = 60
local SANCTIONED_MIN_LAP_COUNT = 2
local SANCTIONED_PODIUM_XP_OF_MONEY = 0.1

--- Verbose trace for racing-team / sanctioned freeroam HUD mismatches. Set to false to silence.
local SR_TRACE_BEGIN = false

local DEFAULT_CLASS_PAYOUT_MULT = {
  stock = 1,
  modified = 1.35,
  super = 1.85,
  open = 2.35,
}

-- Sub-brackets: power-to-weight in hp/kg (engine hp ÷ curb weight kg). Player-facing labels: Branch · Low/Mid/High.
local OPEN_SANCTIONED_PW_MIN = 0.4741
local OPEN_SANCTIONED_PW_MAX = 99.0
local OPEN_SANCTIONED_BRACKET_LABEL = "Open"
local DEFAULT_SANCTIONED_PW_BRACKETS = {
  {
    branch = "stock",
    id = "stock_street_entry",
    label = "Stock · Low",
    classPwMin = 0.0882,
    classPwMax = 0.1940,
    pickWeight = 1,
  },
  {
    branch = "stock",
    id = "stock_street_mid",
    label = "Stock · Mid",
    classPwMin = 0.1653,
    classPwMax = 0.2425,
    pickWeight = 1,
  },
  {
    branch = "stock",
    id = "stock_street_upper",
    label = "Stock · High",
    classPwMin = 0.2205,
    classPwMax = 0.2822,
    pickWeight = 1,
  },
  {
    branch = "modified",
    id = "modified_club_low",
    label = "Modified · Low",
    classPwMin = 0.2425,
    classPwMax = 0.3042,
    pickWeight = 1,
  },
  {
    branch = "modified",
    id = "modified_club_mid",
    label = "Modified · Mid",
    classPwMin = 0.2756,
    classPwMax = 0.3417,
    pickWeight = 1,
  },
  {
    branch = "modified",
    id = "modified_club_high",
    label = "Modified · High",
    classPwMin = 0.3197,
    classPwMax = 0.3792,
    pickWeight = 1,
  },
  {
    branch = "super",
    id = "super_track_low",
    label = "Super · Low",
    classPwMin = 0.3638,
    classPwMax = 0.4079,
    pickWeight = 1,
  },
  {
    branch = "super",
    id = "super_track_mid",
    label = "Super · Mid",
    classPwMin = 0.3858,
    classPwMax = 0.4365,
    pickWeight = 1,
  },
  {
    branch = "super",
    id = "super_track_high",
    label = "Super · High",
    classPwMin = 0.4145,
    classPwMax = 0.4740,
    pickWeight = 1,
  },
  -- Above super_track_high: without this row, getSanctionedPwBracketLabelForPw / getSanctionedBranchForPw fall through and UI/offers stick to stale "stock" / stock branch.
  {
    branch = "open",
    id = "open_unlimited",
    label = OPEN_SANCTIONED_BRACKET_LABEL,
    classPwMin = OPEN_SANCTIONED_PW_MIN,
    classPwMax = OPEN_SANCTIONED_PW_MAX,
    pickWeight = 1,
  },
}

-- State ---------------------------------------------------------------------------------------------

local mCelebrationRewards = nil

local runtime = {
  suppressFrePayouts = false,
  podiumEligible = false,
  dispatchUiActive = false,
}

-- Podium XP policy ----------------------------------------------------------------------------------

local function moneyToSanctionedXp(m)
  return math.max(0, math.floor((tonumber(m) or 0) * SANCTIONED_PODIUM_XP_OF_MONEY + 1e-9))
end

-- Baseline money (race reward at target time) is multiplied by branch before podium place multipliers.
-- Trace and commit diagnostics ----------------------------------------------------------------------

local function srTrace(msg)
  if not SR_TRACE_BEGIN then return end
  log("I", "sanctionedRacing", msg)
end

local function commitExternalFail(err)
  if SR_TRACE_BEGIN then log("I", "sanctionedRacing", "commitAndNavigateExternalOffer FAIL: " .. tostring(err)) end
  return false, err
end

--- Called from freeroamEvents.beginFreeroamRace so logs show the bridge before onRaceBegin.
function M.traceBeginFromFreeroam(raceNameArg)
  srTrace("beginFreeroamRace -> onRaceBegin next, raceNameArg=" .. tostring(raceNameArg))
end

function M.traceBeginFromFreeroamEarlyExitNoRace(raceNameArg)
  srTrace("beginFreeroamRace early exit: no session.races entry for raceNameArg=" .. tostring(raceNameArg))
end

-- Parts ---------------------------------------------------------------------------------------------

local sanctionedOffers = require("overhaul/events/fre/sanctionedRacing/sanctionedOffers").create({
  M = M,
  freConfig = freConfig,
  CONFIG_DIR = CONFIG_DIR,
  CONFIG_RACE_FILENAME = CONFIG_RACE_FILENAME,
  DISCIPLINE_ROAD = DISCIPLINE_ROAD,
  DEFAULT_PODIUM_MULT = DEFAULT_PODIUM_MULT,
  DEFAULT_PODIUM_VARIANCE = DEFAULT_PODIUM_VARIANCE,
  PLACE_JITTER = PLACE_JITTER,
  SANCTIONED_MAX_WINDOW_SEC = SANCTIONED_MAX_WINDOW_SEC,
  SANCTIONED_LAP_ROLL_CAP = SANCTIONED_LAP_ROLL_CAP,
  SANCTIONED_MIN_LAP_COUNT = SANCTIONED_MIN_LAP_COUNT,
  moneyToSanctionedXp = moneyToSanctionedXp,
  DEFAULT_CLASS_PAYOUT_MULT = DEFAULT_CLASS_PAYOUT_MULT,
  DEFAULT_SANCTIONED_PW_BRACKETS = DEFAULT_SANCTIONED_PW_BRACKETS,
  srTrace = srTrace,
})

local sanctionedDispatch = require("overhaul/events/fre/sanctionedRacing/sanctionedDispatch").create({
  M = M,
  DISCIPLINE_ROAD = DISCIPLINE_ROAD,
  runtime = runtime,
  srTrace = srTrace,
  commitExternalFail = commitExternalFail,
  loadCfg = sanctionedOffers.loadCfg,
  isSanctionedRaceNameConfigured = sanctionedOffers.isSanctionedRaceNameConfigured,
  hasSanctionedForRoadRacing = sanctionedOffers.hasSanctionedForRoadRacing,
  ensureSrState = sanctionedOffers.ensureSrState,
  skillOk = sanctionedOffers.skillOk,
})

-- Race observation and eligibility ------------------------------------------------------------------

local function committedOfferForRace(raceName)
  local state = overhaul_events_fre_state.getState()
  local sr = sanctionedOffers.ensureSrState(state)
  local offer = sr.offer
  if not offer or (offer.phase ~= "committed" and offer.phase ~= "racing") then
    srTrace(
      string.format("onRaceBegin bail: no offer or bad phase (phase=%s)", offer and tostring(offer.phase) or "nil")
    )
    return
  end
  if offer.raceName ~= raceName then
    srTrace(
      string.format(
        'onRaceBegin bail: offer.raceName mismatch (offer.raceName=%s session=%s)',
        tostring(offer.raceName),
        tostring(raceName)
      )
    )
    return
  end
  local ctf = overhaul_events_competitiveTrackFlow
  -- Prefer the staging gate when present, but do not require it for a committed racing-team business offer.
  local gateActive = ctf and ctf.isTrackGridCareerStagingGateActive and ctf.isTrackGridCareerStagingGateActive()
  if not gateActive and offer.racingTeamBusinessOffer ~= true then
    srTrace(
      string.format(
        "onRaceBegin bail: staging gate inactive and not racingTeamBusinessOffer (gateActive=%s teamOffer=%s)",
        tostring(gateActive == true),
        tostring(offer.racingTeamBusinessOffer == true)
      )
    )
    return
  end
  return sr, offer
end

local function armSanctionedPodiumEligibility(offer)
  runtime.suppressFrePayouts = true
  runtime.podiumEligible = true
  -- Class cap / podium: trusted live hp/kg vs bracket max (fail open if no fresh sample).
  local pwMax = tonumber(offer.classPwMax)
  if
    pwMax
    and pwMax > 0
    and overhaul_events_aiRacers
    and overhaul_events_aiRacers.getPlayerVehiclePwForPodiumCapCheck
  then
    local pwLive = overhaul_events_aiRacers.getPlayerVehiclePwForPodiumCapCheck()
    if type(pwLive) == "number" and pwLive > pwMax then runtime.podiumEligible = false end
  end
  srTrace(
    string.format(
      "onRaceBegin ARMED suppressFrePayouts=true podiumEligible=%s offerId=%s classPwMax=%s pwLive=%s",
      tostring(runtime.podiumEligible == true),
      tostring(offer.id),
      tostring(offer.classPwMax),
      (overhaul_events_aiRacers and overhaul_events_aiRacers.getPlayerVehiclePwForPodiumCapCheck)
          and tostring(overhaul_events_aiRacers.getPlayerVehiclePwForPodiumCapCheck())
        or "n/a"
    )
  )
end

function M.onRaceBegin(raceName)
  srTrace(string.format("onRaceBegin enter sessionRaceName=%s", tostring(raceName)))
  if not sanctionedOffers.isSanctionedRaceNameConfigured(raceName) then
    srTrace("onRaceBegin bail: session raceName not in level sanctionedRaceNames (cfg whitelist)")
    return
  end
  local sr, offer = committedOfferForRace(raceName)
  if not offer then return end
  if
    offer.racingTeamBusinessOffer == true
    and overhaul_events_aiRacers
    and overhaul_events_aiRacers.getLastSpawnedLineupSnapshot
  then
    offer.rematchAiLineupSnapshot = overhaul_events_aiRacers.getLastSpawnedLineupSnapshot()
  end
  offer.phase = "racing"
  sr.nextGenAt = 0
  overhaul_events_fre_state.refreshMaintenanceSchedule(overhaul_events_fre_state.getSimTime())
  runtime.dispatchUiActive = false
  armSanctionedPodiumEligibility(offer)
end

local function notifyBusinessRematchOutcome(offer, place, reason)
  if
    type(offer) ~= "table"
    or offer.racingTeamBusinessOffer ~= true
    or not (overhaul_career_career and overhaul_career_career.isActive())
  then
    return
  end
  overhaul_career_business_racingTeam_racingTeam.onBusinessSanctionedRaceOutcome(offer, place, reason)
end

function M.shouldSuppressFrePayouts()
  if runtime.suppressFrePayouts == true then return true end
  local ctf = overhaul_events_competitiveTrackFlow
  if ctf then
    if ctf.isRacingTeamProxyRaceActive and ctf.isRacingTeamProxyRaceActive() then return true end
    if ctf.isRacingTeamProxyRaceSessionActive and ctf.isRacingTeamProxyRaceSessionActive() then return true end
  end
  return false
end

function M.isPodiumEligible()
  return runtime.podiumEligible == true
end

function M.resetRuntimeForCareerChange()
  runtime.suppressFrePayouts = false
  runtime.podiumEligible = false
  runtime.dispatchUiActive = false
  mCelebrationRewards = nil
end

function M.clearRuntime()
  srTrace("clearRuntime() resetting suppressFrePayouts / podiumEligible / dispatchUiActive")
  runtime.suppressFrePayouts = false
  runtime.podiumEligible = false
  runtime.dispatchUiActive = false
end

-- Podium settlement ---------------------------------------------------------------------------------

local function podiumRewardInputs(offer, place)
  local amount = 0
  local xpStored = nil
  if place == 1 then
    amount = tonumber(offer.payoutFirst) or 0
    xpStored = offer.xpFirst
  elseif place == 2 then
    amount = tonumber(offer.payoutSecond) or 0
    xpStored = offer.xpSecond
  elseif place == 3 then
    amount = tonumber(offer.payoutThird) or 0
    xpStored = offer.xpThird
  end
  return amount, xpStored
end

local function payBusinessPodium(offer, businessId, amount, place, grantedXp, skillKey)
  local businessAccount = overhaul_career_economy_bank.getBusinessAccount("racingTeam", businessId)
  local accountId = businessAccount and (businessAccount.id or businessAccount.accountId)
  if accountId then
    -- The team keeps its player share only when racing alongside the proxy.
    local playerCut = 1.0
    if offer.playerProxyAlongsideRace == true then
      local multiplier = overhaul_career_business_racingTeam_racingTeam.getPlayerRacePayoutMultiplier()
      if tonumber(multiplier) then playerCut = math.max(0, math.min(1, tonumber(multiplier))) end
    end
    local floored = math.floor(amount * playerCut)
    local ok = overhaul_career_economy_bank.rewardToAccount({
      money = { amount = floored, canBeNegative = false },
    }, accountId, string.format("Sanctioned team race - P%d", place), "Racing team circuit payout", require("overhaul/lib/finance/metadata").tag(nil, "business"))
    if ok then
      recordPodium({detail = "Place " .. tostring(place) .. " / Business account prize", money = floored})
      if grantedXp > 0 then overhaul_career_business_racingTeam_racingTeam.addBusinessXP(businessId, grantedXp) end
      mCelebrationRewards = { money = floored, disciplineXp = grantedXp }
      if skillKey and grantedXp > 0 then
        -- Podium settlement already completes on a refused player XP leg.
        local accepted = overhaul_career_economy_payment.payout({
          xp = { [skillKey] = grantedXp },
          label = string.format("Sanctioned race - P%d", place),
          tags = { "gameplay", "reward", "fre", "sanctioned_race" },
          fullReward = true,
        })
        if accepted ~= true then
          M.finishOfferClear()
          return true, true
        end
      end
    else
      return false, false
    end
  else
    return false, false
  end  return true, false
end

local function payWalletPodium(amount, place, grantedXp, skillKey)
  if not (overhaul_career_career and overhaul_career_career.isActive()) then
    mCelebrationRewards = { money = 0, noRewardDetail = "No payout configured for this podium position." }
    M.finishOfferClear()
    return true
  end
  mCelebrationRewards = { money = math.floor(amount), disciplineXp = grantedXp }
  -- History reports only an accepted prize; legacy completion still proceeds on refusal.
  local paid = overhaul_career_economy_payment.payout(require("overhaul/lib/finance/metadata").tagPayout({
    amount = amount,
    xp = grantedXp > 0 and { [skillKey] = grantedXp } or nil,
    label = string.format("Sanctioned race - P%d", place),
    tags = { "gameplay", "reward", "fre", "sanctioned_race" },
    reason = { canBeNegative = false },
    fullReward = true,
  }, "activity:racing", {vehicleRole = "player"}))
  recordPodium({detail = "Place " .. tostring(place) .. (paid == true and " / Prize paid" or " / Prize unavailable"), money = paid == true and amount or 0})
  return false
end

local function payPodium(place)
  local state = overhaul_events_fre_state.getState()
  local sanctionedState = sanctionedOffers.ensureSrState(state)
  local offer = sanctionedState.offer
  if not offer then return end
  local amount, xpStored = podiumRewardInputs(offer, place)
  local xpNum = tonumber(xpStored)
  local xpAmount = (xpNum ~= nil) and math.max(0, math.floor(xpNum)) or moneyToSanctionedXp(amount)
  if amount <= 0 then
    recordPodium({detail = "Place " .. tostring(place) .. " / No prize", money = 0})
    mCelebrationRewards = { money = 0, noRewardDetail = "No payout configured for this podium position." }
    M.finishOfferClear()
    return
  end
  local skillKey = freConfig.getSkillKey(DISCIPLINE_ROAD)
  local grantedXp = 0
  if skillKey and xpAmount > 0 then grantedXp = xpAmount end
  local useBusinessPayout = type(offer) == "table" and offer.racingTeamBusinessOffer == true and offer.businessId ~= nil
  local businessId = useBusinessPayout and (tonumber(offer.businessId) or offer.businessId) or nil

  if useBusinessPayout and businessId and (overhaul_career_career and overhaul_career_career.isActive()) then
    local alreadyCleared
    useBusinessPayout, alreadyCleared = payBusinessPodium(offer, businessId, amount, place, grantedXp, skillKey)
    if alreadyCleared then return end
  end
  if not useBusinessPayout or not businessId then
    if payWalletPodium(amount, place, grantedXp, skillKey) then return end
  end
  M.finishOfferClear()
end

-- Offer completion and cleanup ----------------------------------------------------------------------

function M.finishOfferClear()
  local state = overhaul_events_fre_state.getState()
  local sr = sanctionedOffers.ensureSrState(state)
  sr.offer = nil
  local now = state.simTime or 0
  local cfg = sanctionedOffers.loadCfg()
  sr.nextGenAt = now + math.max(0.5, tonumber(cfg.defaultOfferRefreshMinutes) or 12)
  M.clearRuntime()
  overhaul_events_fre_state.refreshMaintenanceSchedule(now)
  require("overhaul/lib/save/store").request("sanctionedRacing:finishOfferClear")
  overhaul_events_fre_ui.emitUiStateUpdate("sanctioned_race_end")
end

local function traceSanctionedSettlement(raceName, activeOffer)
  srTrace(
    string.format(
      "settleFromAiResults enter raceName=%s suppressFrePayouts=%s podiumEligible=%s offer=%s teamOffer=%s businessId=%s league1PlayerRace=%s phase=%s",
      tostring(raceName),
      tostring(runtime.suppressFrePayouts == true),
      tostring(runtime.podiumEligible == true),
      tostring(activeOffer ~= nil),
      tostring(activeOffer and activeOffer.racingTeamBusinessOffer == true),
      tostring(activeOffer and activeOffer.businessId),
      tostring(activeOffer and activeOffer.league1PlayerRace == true),
      tostring(activeOffer and activeOffer.phase)
    )
  )
end

local function clearUnarmedSanctionedOffer(raceName, activeOffer)
  local rn = raceName or (activeOffer and activeOffer.raceName)
  if
    rn
    and sanctionedOffers.isSanctionedRaceNameConfigured(rn)
    and activeOffer
    and type(activeOffer.raceName) == "string"
    and activeOffer.raceName == rn
    and (activeOffer.phase == "committed" or activeOffer.phase == "racing")
  then
    -- Always clear: a team/league1 offer that reached race end without arming HUD is dead weight;
    -- keeping it would block every subsequent commitAndNavigateExternalOffer ("already committed").
    M.finishOfferClear()
  end
end

local function armFleetIfTeamOffer(offer)
  if not offer then return end
  if not (overhaul_career_career and overhaul_career_career.isActive()) then return end
  overhaul_career_business_racingTeam_racingTeam.armFleetVehicleCooldownAfterSanctionedRaceSettled(offer)
end

local function settleSanctionedPodium(place, activeOffer)
  if not runtime.podiumEligible then
    srTrace(string.format("settleFromAiResults SKIP podium place=%d podiumEligible=false", place))
    mCelebrationRewards = { money = 0, noRewardDetail = "Over power limit — no podium rewards." }
    M.finishOfferClear()
    return
  end
  local rtMod = (overhaul_career_career and overhaul_career_career.isActive())
      and overhaul_career_business_racingTeam_racingTeam
    or nil
  srTrace(
    string.format(
      "settleFromAiResults CALLING notifyOfficialSanctionedPodium place=%d rtMod=%s fn=%s",
      place,
      tostring(rtMod ~= nil),
      tostring(rtMod and rtMod.notifyOfficialSanctionedPodium ~= nil)
    )
  )
  if rtMod then rtMod.notifyOfficialSanctionedPodium(place, activeOffer) end
  payPodium(place)
end

-- Race result settlement ----------------------------------------------------------------------------

function M.settleFromAiResults(aiResults, raceName)
  local state = overhaul_events_fre_state.getState()
  local sanctionedState = sanctionedOffers.ensureSrState(state)
  local activeOffer = sanctionedState.offer
  traceSanctionedSettlement(raceName, activeOffer)
  if not runtime.suppressFrePayouts then
    clearUnarmedSanctionedOffer(raceName, activeOffer)
    return
  end
  mCelebrationRewards = nil
  if not aiResults then
    notifyBusinessRematchOutcome(activeOffer, nil, "no_results")
    mCelebrationRewards = { money = 0, noRewardDetail = "No race results — no podium reward." }
    armFleetIfTeamOffer(activeOffer)
    M.finishOfferClear()
    return
  end
  local place = nil
  for _, row in ipairs(aiResults) do
    if row.isPlayer then
      place = tonumber(row.place)
      break
    end
  end
  if not place then
    notifyBusinessRematchOutcome(activeOffer, nil, "no_place")
    mCelebrationRewards = { money = 0, noRewardDetail = "Couldn't determine placement — no podium reward." }
    armFleetIfTeamOffer(activeOffer)
    M.finishOfferClear()
    return
  end
  if place ~= 1 then
    notifyBusinessRematchOutcome(activeOffer, place, "non_win")
  else
    notifyBusinessRematchOutcome(activeOffer, place, "win")
  end
  armFleetIfTeamOffer(activeOffer)
  if place >= 1 and place <= 3 then
    settleSanctionedPodium(place, activeOffer)
  else
    mCelebrationRewards = { money = 0, noRewardDetail = "Didn't place on the podium — no podium rewards." }
    M.finishOfferClear()
  end
end

-- Race lifecycle ------------------------------------------------------------------------------------

function M.onRaceAborted()
  mCelebrationRewards = nil
  if not (overhaul_career_career and overhaul_career_career.isActive()) then return end
  local state = overhaul_events_fre_state.getState()
  local sr = sanctionedOffers.ensureSrState(state)
  local offer = sr.offer
  if not offer and not runtime.suppressFrePayouts then return end
  if offer then notifyBusinessRematchOutcome(offer, nil, "aborted") end
  -- Also clear on abort of a committed offer (not just racing/suppressed): leaving it in place
  -- means commitAndNavigateExternalOffer rejects every next accept with "already committed".
  if runtime.suppressFrePayouts or (offer and (offer.phase == "racing" or offer.phase == "committed")) then
    M.finishOfferClear()
  end
end

-- Drop saved committed races after reload because their original race and AI grid no longer exist.
function M.evictStaleOfferOnCareerLoad()
  if not (overhaul_career_career and overhaul_career_career.isActive()) then return end
  local state = overhaul_events_fre_state.getState()
  local sr = sanctionedOffers.ensureSrState(state)
  local offer = sr.offer
  if not offer then return end
  if offer.phase ~= "committed" and offer.phase ~= "racing" then return end
  srTrace(
    string.format(
      "evictStaleOfferOnCareerLoad clearing phase=%s id=%s teamOffer=%s league1=%s",
      tostring(offer.phase),
      tostring(offer.id),
      tostring(offer.racingTeamBusinessOffer == true),
      tostring(offer.league1PlayerRace == true)
    )
  )
  sr.offer = nil
  local now = state.simTime or 0
  local cfg = sanctionedOffers.loadCfg()
  sr.nextGenAt = now + math.max(0.5, tonumber(cfg.defaultOfferRefreshMinutes) or 12)
  M.clearRuntime()
  overhaul_events_fre_state.refreshMaintenanceSchedule(now)
  require("overhaul/lib/save/store").request("sanctionedRacing:evictStaleOfferOnCareerLoad")
  overhaul_events_fre_ui.emitUiStateUpdate("sanctioned_evict_stale_on_load")
end

function M.onCareerTrackStagingExitAbandoned()
  if not (overhaul_career_career and overhaul_career_career.isActive()) then return end
  local state = overhaul_events_fre_state.getState()
  local sr = sanctionedOffers.ensureSrState(state)
  local offer = sr.offer
  if offer and type(offer.raceName) == "string" and sanctionedOffers.isSanctionedRaceNameConfigured(offer.raceName) then
    notifyBusinessRematchOutcome(offer, nil, "staging_exit")
    M.finishOfferClear()
  end
end

-- Race configuration queries ------------------------------------------------------------------------

function M.getRematchAiLineupSnapshot()
  if not (overhaul_career_career and overhaul_career_career.isActive()) then return nil end
  local state = overhaul_events_fre_state.getState()
  local sr = sanctionedOffers.ensureSrState(state)
  local offer = sr.offer
  if not offer or offer.phase ~= "committed" then return nil end
  if offer.racingTeamBusinessOffer ~= true then return nil end
  if type(offer.rematchAiLineupSnapshot) ~= "table" or #offer.rematchAiLineupSnapshot == 0 then return nil end
  return offer.rematchAiLineupSnapshot
end

function M.isRacingUnlocked(disciplineId)
  if string.lower(tostring(disciplineId or "")) ~= DISCIPLINE_ROAD then return false end
  return sanctionedOffers.skillOk(DISCIPLINE_ROAD)
end

function M.isSanctionedCircuitRaceActive()
  if not (overhaul_career_career and overhaul_career_career.isActive()) then return false end
  local state = overhaul_events_fre_state.getState()
  local sr = sanctionedOffers.ensureSrState(state)
  local offer = sr.offer
  return offer
    and offer.phase == "racing"
    and type(offer.raceName) == "string"
    and sanctionedOffers.isSanctionedRaceNameConfigured(offer.raceName)
end

function M.isSanctionedCircuitRaceUseAltRoute()
  if not M.isSanctionedCircuitRaceActive() then return false end
  local state = overhaul_events_fre_state.getState()
  local sr = sanctionedOffers.ensureSrState(state)
  local offer = sr.offer
  if not offer then return false end
  return string.lower(tostring(offer.raceRouteType or "main")) == "alt"
end

function M.getAiPoolReferencePw()
  if not (overhaul_career_career and overhaul_career_career.isActive()) then return nil end
  local state = overhaul_events_fre_state.getState()
  local sr = sanctionedOffers.ensureSrState(state)
  local offer = sr.offer
  if not offer or type(offer.raceName) ~= "string"
    or not sanctionedOffers.isSanctionedRaceNameConfigured(offer.raceName) then
    return nil
  end
  if offer.phase ~= "committed" and offer.phase ~= "racing" then return nil end
  local hi = tonumber(offer.classPwMax)
  if not hi or hi <= 0 then return nil end
  return hi
end

-- Public API --------------------------------------------------------------------------------------

M.getAiPoolReferenceHp = M.getAiPoolReferencePw

function M.getAiPoolReferencePwMin()
  if not (overhaul_career_career and overhaul_career_career.isActive()) then return nil end
  local state = overhaul_events_fre_state.getState()
  local sr = sanctionedOffers.ensureSrState(state)
  local offer = sr.offer
  if not offer or type(offer.raceName) ~= "string"
    or not sanctionedOffers.isSanctionedRaceNameConfigured(offer.raceName) then
    return nil
  end
  if offer.phase ~= "committed" and offer.phase ~= "racing" then return nil end
  local lo = tonumber(offer.classPwMin)
  if not lo or lo <= 0 then return nil end
  return lo
end

M.getAiPoolReferenceHpMin = M.getAiPoolReferencePwMin

-- For AI spawn when player hp/kg cannot be read: bracket limits (hp/kg) + branch.
function M.getAiSpawnSanctionedContext()
  if not (overhaul_career_career and overhaul_career_career.isActive()) then return nil end
  local state = overhaul_events_fre_state.getState()
  local sr = sanctionedOffers.ensureSrState(state)
  local offer = sr.offer
  if not offer or type(offer.raceName) ~= "string"
    or not sanctionedOffers.isSanctionedRaceNameConfigured(offer.raceName) then
    return nil
  end
  if offer.phase ~= "committed" and offer.phase ~= "racing" then return nil end
  local lo = tonumber(offer.classPwMin)
  local hi = tonumber(offer.classPwMax)
  if not hi or hi <= 0 then return nil end
  if not lo or lo < 0 then lo = 0 end
  local branch = offer.hpBracketBranch
  if type(branch) ~= "string" or branch == "" then branch = nil end
  return {
    classPwMin = lo,
    classPwMax = hi,
    hpBracketBranch = branch,
    racingTeamBusinessOffer = offer.racingTeamBusinessOffer == true,
  }
end

function M.getSanctionedOfferLapCount()
  if not (overhaul_career_career and overhaul_career_career.isActive()) then return nil end
  local state = overhaul_events_fre_state.getState()
  local sr = sanctionedOffers.ensureSrState(state)
  local offer = sr.offer
  if not offer or type(offer.raceName) ~= "string"
    or not sanctionedOffers.isSanctionedRaceNameConfigured(offer.raceName) then
    return nil
  end
  if offer.phase ~= "committed" and offer.phase ~= "racing" and offer.phase ~= "available" then return nil end
  local n = tonumber(offer.lapCount)
  if n and n > 0 then return math.floor(n) end
  return nil
end

--- Like getSanctionedOfferLapCount but only committed/racing and optional race id match (in-race HUD when suppression not yet armed).
function M.getCommittedRacingSanctionedOfferLapCount(raceName)
  if not (overhaul_career_career and overhaul_career_career.isActive()) then return nil end
  local state = overhaul_events_fre_state.getState()
  local sr = sanctionedOffers.ensureSrState(state)
  local offer = sr.offer
  if not offer or type(offer.raceName) ~= "string"
    or not sanctionedOffers.isSanctionedRaceNameConfigured(offer.raceName) then
    return nil
  end
  if offer.phase ~= "committed" and offer.phase ~= "racing" then return nil end
  if type(raceName) == "string" and raceName ~= "" and offer.raceName ~= raceName then return nil end
  local n = tonumber(offer.lapCount)
  if n and n > 0 then return math.floor(n) end
  return nil
end

M.loadCfg = sanctionedOffers.loadCfg
M.loadCfgForLevel = sanctionedOffers.loadCfgForLevel
M.isSanctionedRaceNameConfigured = sanctionedOffers.isSanctionedRaceNameConfigured

--- Highest classPwMax among Stock-branch hp/kg brackets.
function M.getStockClassPwCeiling()
  local maxStock = nil
  for _, b in ipairs(DEFAULT_SANCTIONED_PW_BRACKETS) do
    if string.lower(tostring(b.branch or "")) == "stock" then
      local m = tonumber(b.classPwMax)
      if m and m > 0 and (not maxStock or m > maxStock) then maxStock = m end
    end
  end
  return maxStock or 0.2822
end

M.getStockClassHpCeiling = M.getStockClassPwCeiling

--- Branch from player/fleet hp/kg (power ÷ weight in kg).
function M.getSanctionedBranchForPw(pw)
  local p = tonumber(pw)
  if not p or p <= 0 then return "stock" end
  local bestBranch = "stock"
  local bestRank = 0
  local rank = { stock = 1, modified = 2, super = 3, open = 4 }
  for _, b in ipairs(DEFAULT_SANCTIONED_PW_BRACKETS) do
    local lo = tonumber(b.classPwMin) or 0
    local hi = tonumber(b.classPwMax) or 0
    if p >= lo and p <= hi then
      local br = string.lower(tostring(b.branch or ""))
      local r = rank[br] or 0
      if r > bestRank then
        bestRank = r
        bestBranch = br ~= "" and br or "stock"
      end
    end
  end
  return bestBranch
end

M.getSanctionedBranchForHp = M.getSanctionedBranchForPw

--- Sub-bracket display label for fleet/staging: pw in [classPwMin, classPwMax]. On overlap, pick bracket with highest classPwMin.
function M.getSanctionedPwBracketLabelForPw(pw)
  local p = tonumber(pw)
  if not p or p <= 0 then return nil end
  local bestLabel = nil
  local bestLo = -1e9
  for _, b in ipairs(DEFAULT_SANCTIONED_PW_BRACKETS) do
    local lo = tonumber(b.classPwMin) or 0
    local hi = tonumber(b.classPwMax) or 0
    if p >= lo and p <= hi then
      if lo > bestLo then
        bestLo = lo
        bestLabel = b.label
      end
    end
  end
  return bestLabel
end

function M.getSanctionedPwBracketById(bracketId)
  if type(bracketId) ~= "string" or bracketId == "" then return nil end
  local want = string.lower(bracketId)
  for _, b in ipairs(DEFAULT_SANCTIONED_PW_BRACKETS) do
    if string.lower(tostring(b.id or "")) == want then
      return {
        branch = b.branch,
        id = b.id,
        label = b.label,
        classPwMin = tonumber(b.classPwMin) or 0,
        classPwMax = tonumber(b.classPwMax) or 0,
      }
    end
  end
  return nil
end

M.getSanctionedHpBracketById = M.getSanctionedPwBracketById

function M.consumeSanctionedCelebrationRewards()
  local r = mCelebrationRewards
  mCelebrationRewards = nil
  return r
end

function M.getOfferGenerationPeriodMinutes()
  local cfg = sanctionedOffers.loadCfg()
  if not cfg or type(cfg.variants) ~= "table" or #cfg.variants == 0 then return nil end
  return math.max(0.25, tonumber(cfg.defaultOfferRefreshMinutes) or 12)
end

return M
