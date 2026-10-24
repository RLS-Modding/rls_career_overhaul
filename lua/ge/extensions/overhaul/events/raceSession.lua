-- Freeroam race HUD, lap summary, drag payouts and the completion card for the event session.
-- Owns the race HUD and lap summary state, drag payouts and completion-card lifecycle.
local capabilities = require("overhaul/lib/platform/capabilities")
local eventHelpers = require("overhaul/lib/events/helpers")
local hudSnapshot = require("overhaul/lib/ui/hudSnapshot")
local statePush = require("overhaul/lib/ui/statePush")
local rulesSnapshot = require("overhaul/lib/career/rulesSnapshot")
local M = {}

M.dependencies = { "overhaul_events_session" }

local freConfig = require("overhaul/events/freConfig")
-- Drag results get their own run per payout (one run = one drag pass); in memory only.
local dragResultIds = require("overhaul/lib/events/resultIdentity").create("drag")

-- Config ------------------------------------------------------------------------------------------

local RACE_HUD_PUSH_INTERVAL_SECONDS = 0.1
local DRAG_RESULTS_SECONDS = 20
-- State ---------------------------------------------------------------------------------------------

-- HUD and lap summary state belong to this extension load.
local raceHud = {
  shown = false,
  opening = false,
  pushClock = nil,
  banner = nil,
  stagingSubjectId = nil,
  lastLapReward = nil,
  completionPayload = nil,
  completionSnapshot = nil,
  completionRemaining = nil,
  completionGeneration = 0,
  stagingProjection = nil,
  liveProjection = nil,
}
local raceSummary = {
  laps = {},
  raceName = nil,
  displayLabel = nil,
  mainLabel = nil,
  altLabel = nil,
  openLoop = false,
}
local vanillaDragHudSuppressed = false
local vanillaDragHudSuppressedAt = nil

-- Race collaborators and policy ---------------------------------------------------------------------

local function utils()
  return overhaul_events_utils
end

local function leaderboardManager()
  return overhaul_events_leaderboards
end

local function circuitRaceAi()
  return overhaul_events_circuitRaceAi
end

local function competitiveTrackFlow()
  return overhaul_events_competitiveTrackFlow
end

local function getDisplayTotalLapsForRace(race)
  return competitiveTrackFlow().getDisplayTotalLapsForRace(race)
end

local function isLapRaceConfig(race)
  if not race then return false end
  local raceSessionConfig = race.session
  return (race.lapCount and race.lapCount > 0)
    or race.hotlap
    or (raceSessionConfig and raceSessionConfig.lapCount and raceSessionConfig.lapCount > 0)
end

local function raceHasType(race, raceType)
  if not race or type(race.type) ~= "table" then return false end
  return eventHelpers.tableContains(race.type, raceType)
end

local function hudDisplayLap(completed, totalLaps)
  local completedLaps = completed or 0
  if type(totalLaps) == "number" and totalLaps > 0 then return math.min(completedLaps + 1, totalLaps) end
  return completedLaps + 1
end

local function getSession()
  return overhaul_events_session
end

local function resolveSessionInventoryFromSpawnId(subjectID)
  if not subjectID then return subjectID end
  local careerMode = overhaul_career_career.isActive()
  if careerMode then
    local businessId, vehicleId = overhaul_career_business_fleet.getBusinessVehicleFromSpawnedId(subjectID)
    if businessId and vehicleId then
      local jobId = overhaul_career_business_fleet.getJobIdFromVehicle(businessId, vehicleId)
      if jobId then return overhaul_career_business_fleet.getBusinessJobIdentifier(businessId, jobId) end
      return overhaul_career_business_fleet.getBusinessVehicleIdentifier(businessId, vehicleId)
    end
  end
  return careerMode and overhaul_career_garage_inventory.getInventoryIdFromVehicleId(subjectID) or subjectID
end

local function notifyFreContractsFreeroamUi()
  if overhaul_events_fre_ui and overhaul_events_fre_ui.emitUiStateUpdate then
    overhaul_events_fre_ui.emitUiStateUpdate("freeroam_session")
  end
end

-- HUD state and lap summary -------------------------------------------------------------------------

function M.setStagingSubjectId(subjectId)
  raceHud.stagingSubjectId = subjectId
end

function M.isRaceHudShown()
  return raceHud.shown == true
end

function M.setLastLapReward(reward)
  raceHud.lastLapReward = reward
end

function M.clearHudCompletionPayload()
  raceHud.completionRemaining = nil
  if raceHud.completionPayload then
    raceHud.completionPayload = nil
    raceHud.completionSnapshot = nil
  end
end

function M.clearFreSummarySession()
  raceSummary.laps = {}
  raceSummary.raceName = nil
end

function M.buildFreSummaryPayload()
  local mainLaps, altLaps = 0, 0
  local totalMoney, totalXp = 0, 0
  local bestMainLapTime, bestAltLapTime = nil, nil
  for _, row in ipairs(raceSummary.laps) do
    if row.isAlt then
      altLaps = altLaps + 1
    else
      mainLaps = mainLaps + 1
    end
    totalMoney = totalMoney + (tonumber(row.money) or 0)
    totalXp = totalXp + (tonumber(row.xp) or 0)
    if not row.invalid then
      local lapTimeSeconds = tonumber(row.time)
      if lapTimeSeconds then
        if row.isAlt then
          bestAltLapTime = (bestAltLapTime == nil or lapTimeSeconds < bestAltLapTime) and lapTimeSeconds
            or bestAltLapTime
        else
          bestMainLapTime = (bestMainLapTime == nil or lapTimeSeconds < bestMainLapTime) and lapTimeSeconds
            or bestMainLapTime
        end
      end
    end
  end
  local payload = {
    raceLabel = raceSummary.displayLabel or "",
    mainLabel = raceSummary.mainLabel or raceSummary.displayLabel or "",
    altLabel = raceSummary.altLabel,
    isLoop = raceSummary.openLoop == true,
    totals = {
      laps = #raceSummary.laps,
      mainLaps = mainLaps,
      altLaps = altLaps,
      money = totalMoney,
      xp = totalXp,
    },
    bests = {},
    laps = raceSummary.laps,
  }
  if mainLaps > 0 and bestMainLapTime ~= nil then payload.bests.mainTime = bestMainLapTime end
  if altLaps > 0 and bestAltLapTime ~= nil then payload.bests.altTime = bestAltLapTime end
  return payload
end

-- Parts -------------------------------------------------------------------------------------------

local raceRewards = require("overhaul/events/raceSession/raceRewards").create({
  M = M,
  freConfig = freConfig,
  raceHud = raceHud,
  raceSummary = raceSummary,
  utils = utils,
  leaderboardManager = leaderboardManager,
  circuitRaceAi = circuitRaceAi,
  raceHasType = raceHasType,
  sess = getSession,
  notifyFreContractsFreeroamUi = notifyFreContractsFreeroamUi,
})

-- Drag reward settlement ----------------------------------------------------------------------------

local function writeDragLeaderboard(leaderboards, races, raceName, finishTime, vehId)
  local inventoryIdToUse = vehId
  if overhaul_career_career.isActive() then
    inventoryIdToUse = overhaul_career_business_fleet.resolveFreeroamLeaderboardInventoryId(vehId)
  end

  local leaderboardEntry = leaderboards.getLeaderboardEntry(inventoryIdToUse, races[raceName].label)
  local oldTime = leaderboardEntry and leaderboardEntry.time or 0
  local newEntry = {
    raceLabel = races[raceName].label,
    raceName = raceName,
    time = finishTime,
    splitTimes = getSession().mSplitTimes,
    inventoryId = inventoryIdToUse,
  }
  local newBestTime = leaderboards.addLeaderboardEntry(newEntry)
  if newBestTime and inventoryIdToUse and overhaul_career_career.isActive() then
    capabilities.get("raceResultProof").onOverhaulRaceResult({
      phase = "proof", inventoryId = inventoryIdToUse, newBestTime = newBestTime,
    })
  end

  return oldTime, newBestTime
end

local function scaleDragDisciplineXp(disciplineXpRewards, disciplineXpBreakdown)
  overhaul_career_economy_difficultyMode.scalePaymentRewardData(disciplineXpRewards, { includeMoney = false })
  local totalDisciplineXp = 0
  for _, rewardInfo in pairs(disciplineXpRewards) do
    totalDisciplineXp = totalDisciplineXp + (tonumber(rewardInfo.amount) or 0)
  end
  for _, rewardInfo in pairs(disciplineXpRewards) do
    if type(rewardInfo) == "table" and rewardInfo.amount ~= nil then
      rewardInfo.amount = math.max(0, math.floor((tonumber(rewardInfo.amount) or 0) * 2))
    end
  end
  for _, info in pairs(disciplineXpBreakdown) do
    if type(info) == "table" and info.amount ~= nil then
      info.amount = math.max(0, math.floor((tonumber(info.amount) or 0) * 2))
    end
  end
  totalDisciplineXp = math.max(0, math.floor((tonumber(totalDisciplineXp) or 0) * 2))
  return totalDisciplineXp
end

local function calculateDragRewards(raceUtils, raceData, finishTime, newBestTime)
  local targetTime = raceData.bestTime
  local baseReward = raceData.reward
  local disciplineIds = raceRewards.getRaceDisciplineIds(raceData)
  local normalizedPerformance = raceRewards.calculateEventPerformanceRatio("time", {
    goalTime = targetTime,
    baseReward = baseReward,
    actualTime = finishTime,
    raceTypes = raceData.type,
  })
  local reward = raceUtils.raceReward(targetTime, baseReward, finishTime, raceData.type)
  if reward <= 0 then reward = baseReward / 2 end
  reward = newBestTime and reward or reward / 2
  local baseRewardBeforeFre = reward
  local freModifiers = raceRewards.getFreRewardModifiers(disciplineIds)
  reward = reward * (tonumber(freModifiers.moneyMultiplier) or 1)
  local disciplineXpRewards, disciplineXpBreakdown, totalDisciplineXp =
    raceRewards.buildDisciplineXpRewards(disciplineIds, normalizedPerformance, freModifiers)
  totalDisciplineXp = scaleDragDisciplineXp(disciplineXpRewards, disciplineXpBreakdown)
  local completionMeta = {
    disciplineIds = disciplineIds,
    invalidLap = false,
    normalizedPerformance = normalizedPerformance,
    driftScore = 0,
    damagePercentage = 0,
    rewardBreakdown = {
      money = {
        base = baseRewardBeforeFre,
        multiplier = tonumber(freModifiers.moneyMultiplier) or 1,
        final = reward,
      },
      normalizedPerformance = normalizedPerformance,
      disciplineXp = disciplineXpBreakdown,
    },
  }
  return reward, completionMeta, disciplineXpRewards, totalDisciplineXp
end

local function settleDragRewards(raceData, finishTime, finishSpeed, vehId, newBestTime, reward, disciplineXpRewards, totalDisciplineXp)
  local suppressRewardToast = raceHud.shown and M.raceHudApplies(raceData)
  local businessAccount = raceRewards.getBusinessAccountFromVehicle(vehId)
  if businessAccount then
    local businessReward = math.floor(reward * 0.5)
    local xpReward = {}
    raceRewards.mergeRewardTables(xpReward, disciplineXpRewards)
    local reason = {
      label = raceData.label .. (newBestTime and " - New Best Time!" or " - Completion"),
      tags = { "gameplay", "reward", "drag" },
    }
    if next(xpReward) ~= nil then raceRewards.payoutReward(xpReward, reason) end
    overhaul_career_economy_bank.rewardToAccount({
      money = { amount = businessReward },
    }, businessAccount.id, "Event Reward", raceData.label .. (newBestTime and " - New Best Time!" or " - Completion"), require("overhaul/lib/finance/metadata").tag(nil, "business"))
    local message = string.format(
      "%s\n%s\nTime: %s\nSpeed: %.2f mph\nDiscipline XP: %d | Business Reward: $%.2f (50%% to business account)",
      newBestTime and "Congratulations! New Best Time!" or "",
      raceData.label,
      eventHelpers.formatTime(finishTime),
      finishSpeed,
      totalDisciplineXp,
      businessReward
    )
    if not suppressRewardToast then ui_message(message, 20, "Reward") end
    return nil, businessReward
  else
    local totalReward = { money = { amount = reward } }
    raceRewards.mergeRewardTables(totalReward, disciplineXpRewards)
    local reason = {
      label = raceData.label .. (newBestTime and " - New Best Time!" or " - Completion"),
      tags = { "gameplay", "reward", "drag" },
    }
    -- Imported race rewards may net a debit, so this wallet leg is allowed to end negative.
    raceRewards.payoutReward(totalReward, reason, nil, true)
    local message = string.format(
      "%s\n%s\nTime: %s\nSpeed: %.2f mph\nDiscipline XP: %d | Reward: $%.2f",
      newBestTime and "Congratulations! New Best Time!" or "",
      raceData.label,
      eventHelpers.formatTime(finishTime),
      finishSpeed,
      totalDisciplineXp,
      reward
    )
    if not suppressRewardToast then ui_message(message, 20, "Reward") end
    return reward, nil
  end
end

local function pushDragCompletionHud(raceData, races, raceName, finishTime, finishSpeed, oldTime, newBestTime, totalDisciplineXp, hudMoney, hudBusinessMoney)
  getSession().mActiveRace = nil
  getSession().timerActive = false
  getSession().dragPracticeActive = false
  vanillaDragHudSuppressed = false
  vanillaDragHudSuppressedAt = nil
  notifyFreContractsFreeroamUi()
  if M.raceHudApplies(raceData) and raceHud.shown then
    getSession().maxSpeed = math.max(getSession().maxSpeed or 0, finishSpeed)
    local prevTimeShow = nil
    if type(oldTime) == "number" and oldTime > 0 and oldTime ~= math.huge then prevTimeShow = oldTime end
    local headline = getSession().invalidLap and "Disqualified" or (newBestTime and "New Best Time!" or "Lap complete")
    local hudCompletionPayload = {
      invalidLap = getSession().invalidLap == true,
      headline = headline,
      raceTitle = raceData.label,
      kind = "drag",
      result = {
        time = finishTime,
        topSpeed = getSession().maxSpeed,
      },
      previous = {
        time = prevTimeShow,
      },
      rewards = {
        disciplineXp = totalDisciplineXp,
        money = hudMoney,
        businessMoney = hudBusinessMoney,
      },
      bonuses = {},
    }
    M.pushRaceHudCompletion(hudCompletionPayload, raceName, raceData.label, races[raceName].label, finishTime, true)
  end
end

function M.payoutDragRace(raceName, finishTime, finishSpeed, vehId, disqualified)
  local raceUtils = utils()
  local leaderboards = leaderboardManager()
  local races = getSession().races
  if not raceHasType(races and races[raceName], "drag") then
    log("W", "raceSession", "Drag payout unavailable: missing drag event " .. tostring(raceName))
    return 0
  end
  local raceData = races[raceName]
  local dragData = gameplay_drag_core and gameplay_drag_core.getData and gameplay_drag_core.getData()
  local racer = dragData and dragData.racers and dragData.racers[vehId]
  if racer and dragData.strip and dragData.strip.id == raceData.dragStripId then
    disqualified = disqualified or racer.isDisqualified == true or racer.isDesqualified == true
  end
  getSession().invalidLap = disqualified == true
  if disqualified then
    -- The bridge already notified at the stock DQ hook; finishing only closes the result.
    pushDragCompletionHud(raceData, races, raceName, finishTime, finishSpeed, nil, false, 0, 0, nil)
    return 0
  end
  local oldTime, newBestTime = writeDragLeaderboard(leaderboards, races, raceName, finishTime, vehId)
  if not overhaul_career_career.isActive() then
    local message =
      string.format("%s\nTime: %s\nSpeed: %.2f mph", raceData.label, eventHelpers.formatTime(finishTime), finishSpeed)
    if not (raceHud.shown and M.raceHudApplies(raceData)) then raceUtils.displayMessage(message, 10) end
    pushDragCompletionHud(raceData, races, raceName, finishTime, finishSpeed, oldTime, newBestTime, 0, 0, nil)
    return 0
  end

  local reward, completionMeta, disciplineXpRewards, totalDisciplineXp =
    calculateDragRewards(raceUtils, raceData, finishTime, newBestTime)
  local hudMoney, hudBusinessMoney = settleDragRewards(
    raceData, finishTime, finishSpeed, vehId, newBestTime, reward, disciplineXpRewards, totalDisciplineXp
  )
  require("overhaul/lib/save/store").request("raceSession:payoutDragRace")
  raceRewards.notifyFreRaceCompleted(
    raceName,
    raceData,
    raceData.label,
    finishTime,
    vehId,
    completionMeta,
    dragResultIds.id(dragResultIds.beginRun(raceName), "final")
  )
  pushDragCompletionHud(raceData, races, raceName, finishTime, finishSpeed, oldTime, newBestTime,
    totalDisciplineXp, hudMoney, hudBusinessMoney)
  return reward
end

-- Splits and HUD banners ----------------------------------------------------------------------------

local function splitDifference(leaderboardEntry, currentCheckpointIndex)
  if not leaderboardEntry then return nil end
  local splitTimes = leaderboardEntry.splitTimes
  if not splitTimes or not splitTimes[currentCheckpointIndex] then return nil end
  local mSplitTimes = getSession().mSplitTimes
  if not mSplitTimes[currentCheckpointIndex] or not splitTimes[currentCheckpointIndex] then return nil end
  local currentSplitDiff
  if currentCheckpointIndex == 1 then
    currentSplitDiff = mSplitTimes[currentCheckpointIndex] - splitTimes[currentCheckpointIndex]
  else
    if not mSplitTimes[currentCheckpointIndex - 1] or not splitTimes[currentCheckpointIndex - 1] then return nil end
    local previousBestSplit = splitTimes[currentCheckpointIndex] - splitTimes[currentCheckpointIndex - 1]
    local currentSplit = mSplitTimes[currentCheckpointIndex] - mSplitTimes[currentCheckpointIndex - 1]
    currentSplitDiff = currentSplit - previousBestSplit
  end
  return currentSplitDiff
end

function M.getDifference(_raceName, currentCheckpointIndex)
  local raceLabel = overhaul_events_host.getFreeroamRaceLabel()
  local leaderboardEntry = leaderboardManager().getLeaderboardEntry(getSession().mInventoryId, raceLabel)
  return splitDifference(leaderboardEntry, currentCheckpointIndex)
end

local function roundSplitDifference(difference)
  if difference >= 0 then return math.floor(difference + 0.5) end
  return math.ceil(difference - 0.5)
end

function M.formatSplitDifference(diff, asScore)
  if asScore then
    local roundedDifference = roundSplitDifference(diff)
    if roundedDifference > 0 then return string.format("+%d", roundedDifference) end
    return string.format("%d", roundedDifference)
  end
  local sign = diff >= 0 and "+" or "-"
  return string.format("%s%s", sign, eventHelpers.formatTime(math.abs(diff)))
end

function M.setRaceHudBanner(text, kind, ttlSeconds)
  if not text or text == "" then
    raceHud.banner = nil
    return
  end
  local ttl = ttlSeconds or 3
  local expireAt = nil
  if ttl > 0 and os and os.clock then expireAt = os.clock() + ttl end
  raceHud.banner = { text = text, kind = kind or "info", expireAt = expireAt }
end

local function clearExpiredRaceHudBanner()
  if not raceHud.banner or not raceHud.banner.expireAt then return end
  if os and os.clock and os.clock() > raceHud.banner.expireAt then raceHud.banner = nil end
end

local function bannerPayloadForHud()
  clearExpiredRaceHudBanner()
  if not raceHud.banner then return nil end
  return { text = raceHud.banner.text, kind = raceHud.banner.kind }
end

function M.raceUsesProcessRoadExit(race)
  return race and race.checkpointRoad
end

function M.raceHudApplies(race)
  if not race then return false end
  if race.checkpointRoad then return true end
  if race.driftGoal then return true end
  if raceHasType(race, "drift") or raceHasType(race, "drag") then return true end
  return false
end

-- HUD projections -----------------------------------------------------------------------------------

local function canBuildRaceHudPayload()
  local races = getSession().races
  if not races then return false end
  if raceHud.completionSnapshot and raceHud.shown and not getSession().mActiveRace then return true end
  if
    getSession().mActiveRace
    and races[getSession().mActiveRace]
    and M.raceHudApplies(races[getSession().mActiveRace])
  then
    return true
  end
  if getSession().staged and races[getSession().staged] and M.raceHudApplies(races[getSession().staged]) then
    return true
  end
  return false
end

local function buildCompletedRaceHud(circuitAi, banner)
  local completionSnapshot = raceHud.completionSnapshot
  local lastLapReward = raceHud.lastLapReward
  raceHud.lastLapReward = nil
  local standingsSnap = (not raceHud.completionPayload) and circuitAi.buildSanctionedHudStandingsPayload() or nil
  return {
    phase = "racing",
    raceLabel = completionSnapshot.raceLabel,
    routeName = completionSnapshot.routeName,
    displayLap = completionSnapshot.displayLap,
    totalLaps = completionSnapshot.totalLaps,
    isLapRace = completionSnapshot.isLapRace,
    goalTime = completionSnapshot.goalTime,
    personalBestTime = completionSnapshot.personalBestTime,
    scoreMode = completionSnapshot.scoreMode,
    driftGoal = completionSnapshot.driftGoal,
    driftScoreLive = completionSnapshot.driftScoreLive,
    personalBestDriftScore = completionSnapshot.personalBestDriftScore,
    scoreLabel = completionSnapshot.scoreLabel,
    sectorSplitsUseScore = completionSnapshot.sectorSplitsUseScore,
    currentLapTime = completionSnapshot.currentLapTime,
    bestLapThisRun = completionSnapshot.bestLapThisRun,
    invalidLap = completionSnapshot.invalidLap,
    totalCheckpoints = completionSnapshot.totalCheckpoints,
    checkpointsHit = 0,
    sectors = {},
    standings = standingsSnap,
    completion = raceHud.completionPayload,
    completionGeneration = raceHud.completionGeneration,
    canDismissCompletion = raceHud.completionPayload and raceHud.completionPayload.kind == "drag" and not getSession().staged
      or false,
    banner = banner,
    lastLapReward = lastLapReward,
    isDragRace = (completionSnapshot.isDragRace == true)
      or (raceHud.completionPayload and raceHud.completionPayload.kind == "drag")
      or false,
  }
end

local function buildLiveRaceHudSectors(leaderboardEntry)
  local sectors = {}
  if not raceHud.completionPayload then
    for i = getSession().checkpointsHit, 1, -1 do
      local cumulativeSplitTime = getSession().mSplitTimes[i]
      if cumulativeSplitTime ~= nil then
        local previousSplitTime = (i > 1) and getSession().mSplitTimes[i - 1] or nil
        local sectorTime = (previousSplitTime ~= nil) and (cumulativeSplitTime - previousSplitTime)
          or cumulativeSplitTime
        local delta = splitDifference(leaderboardEntry, i)
        table.insert(sectors, {
          index = i,
          cumulativeTime = cumulativeSplitTime,
          sectorTime = sectorTime,
          deltaVsPb = delta,
        })
      end
    end
  end
  return sectors
end

local function liveRaceHudProjection(raceLabel)
  local session = getSession()
  local projection = raceHud.liveProjection
  -- Split rows and personal bests change at race boundaries, not with the live clock.
  if not projection or projection.raceName ~= session.mActiveRace or projection.raceLabel ~= raceLabel
    or projection.inventoryId ~= session.mInventoryId or projection.lapCount ~= session.lapCount
    or projection.checkpointsHit ~= session.checkpointsHit or projection.splitTimes ~= session.mSplitTimes
    or projection.completion ~= raceHud.completionPayload then
    local leaderboardEntry = session.mInventoryId
      and leaderboardManager().getLeaderboardEntry(session.mInventoryId, raceLabel) or {}
    projection = {
      raceName = session.mActiveRace,
      raceLabel = raceLabel,
      inventoryId = session.mInventoryId,
      lapCount = session.lapCount,
      checkpointsHit = session.checkpointsHit,
      splitTimes = session.mSplitTimes,
      completion = raceHud.completionPayload,
      leaderboardEntry = leaderboardEntry,
      sectors = buildLiveRaceHudSectors(leaderboardEntry),
    }
    raceHud.liveProjection = projection
  end
  return projection
end

local function projectLiveRaceHud(effectiveRace, displayLabel, displayLapNum, totalLapsVal, isLapRace, isDragRace, goalTimePb, personalBestTimePb, personalBestDriftScore, sectors, standingsLive, banner, lastLapReward, isDriftRace, driftScoreLive, driftComboLive, sectorSplitsUseScore)
  return {
    phase = "racing",
    raceLabel = displayLabel,
    routeName = getSession().mCurrentRouteName,
    displayLap = displayLapNum,
    totalLaps = totalLapsVal,
    isLapRace = isLapRace and true or false,
    goalTime = goalTimePb,
    personalBestTime = personalBestTimePb,
    personalBestDriftScore = personalBestDriftScore,
    scoreLabel = (effectiveRace and effectiveRace.burnoutComp) and "Score" or nil,
    currentLapTime = (effectiveRace and effectiveRace.burnoutComp and type(getSession().burnoutCompHud) == "table")
        and (tonumber(getSession().burnoutCompHud.elapsed) or getSession().in_race_time)
      or getSession().in_race_time,
    bestLapThisRun = getSession().mBestLapThisRun,
    invalidLap = getSession().invalidLap and true or false,
    totalCheckpoints = getSession().totalCheckpoints,
    checkpointsHit = getSession().checkpointsHit,
    sectors = sectors,
    standings = standingsLive,
    completion = raceHud.completionPayload,
    banner = banner,
    lastLapReward = lastLapReward,
    scoreMode = (effectiveRace and effectiveRace.burnoutComp) and true or false,
    driftGoal = (isDriftRace and not effectiveRace.burnoutComp) and effectiveRace.driftGoal or nil,
    driftScoreLive = driftScoreLive,
    driftComboLive = driftComboLive,
    dragSpeedLive = isDragRace and getSession().maxSpeed or nil,
    sectorSplitsUseScore = sectorSplitsUseScore and true or false,
    isDragRace = isDragRace and true or false,
  }
end

local function buildLiveRaceHud(trackFlow, circuitAi, banner, races)
  local race = races[getSession().mActiveRace]
  local effectiveRace = (getSession().mAltRoute and race.altRoute) and race.altRoute or race
  local raceLabelFull = overhaul_events_host.getFreeroamRaceLabel()
  local displayLabel = overhaul_events_host.getFreeroamDisplayRaceLabel()
  local projection = liveRaceHudProjection(raceLabelFull)
  local leaderboardEntry = projection.leaderboardEntry
  local isLapRace = isLapRaceConfig(effectiveRace)
  local isDragRace = raceHasType(effectiveRace, "drag")
  local totalLapsVal =
    trackFlow.resolveRacingHudTotalLaps(getSession().mActiveRace, getSession(), effectiveRace, isLapRace)
  local displayLapNum = isLapRace and hudDisplayLap(getSession().lapCount, totalLapsVal) or 1
  local sectors = projection.sectors
  local lastLapReward = raceHud.lastLapReward
  raceHud.lastLapReward = nil
  local standingsLive = (not raceHud.completionPayload) and circuitAi.buildSanctionedHudStandingsPayload() or nil
  local driftScoreLive, driftComboLive = nil, nil
  if effectiveRace and effectiveRace.driftGoal then
    if effectiveRace.burnoutComp and type(getSession().burnoutCompHud) == "table" then
      driftScoreLive = math.floor((tonumber(getSession().burnoutCompHud.score) or 0) + 0.5)
    else
      driftScoreLive, driftComboLive = raceRewards.peekDriftScore()
    end
  end
  local sectorSplitsUseScore = effectiveRace
    and effectiveRace.driftGoal
    and (tonumber(getSession().totalCheckpoints) or 0) > 0
  local isDriftRace = effectiveRace and (effectiveRace.driftGoal or effectiveRace.burnoutComp)
  local personalBestDriftScore = nil
  if isDriftRace and type(leaderboardEntry.driftScore) == "number" then
    personalBestDriftScore = (effectiveRace and effectiveRace.burnoutComp)
        and math.floor(leaderboardEntry.driftScore + 0.5)
      or leaderboardEntry.driftScore
  end
  local goalTimePb = not isDriftRace and effectiveRace.bestTime or nil
  local personalBestTimePb = not isDriftRace and leaderboardEntry.time or nil
  return projectLiveRaceHud(effectiveRace, displayLabel, displayLapNum, totalLapsVal, isLapRace, isDragRace, goalTimePb, personalBestTimePb, personalBestDriftScore, sectors, standingsLive, banner, lastLapReward, isDriftRace, driftScoreLive, driftComboLive, sectorSplitsUseScore)
end

local function buildStagingRaceHud(raceUtils, trackFlow, banner, races, staged)
  local raceName = staged
  local race = races[raceName]
  local effectiveStagingRace = trackFlow.resolveEffectiveStagingRace(raceName, race)
  local displayLabel = race.label or raceName
  local inventoryId = raceHud.stagingSubjectId
  local revision = rulesSnapshot.revision()
  local projection = raceHud.stagingProjection
  if not projection or projection.inventoryId ~= inventoryId or projection.raceName ~= raceName
    or projection.rulesRevision ~= revision or projection.race ~= race then
    projection = {
      inventoryId = inventoryId,
      raceName = raceName,
      race = race,
      rulesRevision = revision,
      leaderboardEntry = inventoryId and leaderboardManager().getLeaderboardEntry(inventoryId, displayLabel) or {},
      breakdown = inventoryId and raceUtils.getStagingHudBreakdown(inventoryId, raceName) or { blocks = {} },
    }
    raceHud.stagingProjection = projection
  end
  local leaderboardEntry = projection.leaderboardEntry
  local isLapRace = isLapRaceConfig(effectiveStagingRace)
  local totalLapsVal = trackFlow.resolveStagingHudTotalLaps(
    raceName,
    getSession(),
    getSession().mHotlap,
    effectiveStagingRace,
    isLapRace
  )
  local stagingUi = projection.breakdown or { blocks = {} }
  local stagingIsDriftRace = effectiveStagingRace
    and (effectiveStagingRace.driftGoal or effectiveStagingRace.burnoutComp)
  local stagingPersonalBestDriftScore = nil
  if stagingIsDriftRace and type(leaderboardEntry.driftScore) == "number" then
    stagingPersonalBestDriftScore = (effectiveStagingRace and effectiveStagingRace.burnoutComp)
        and math.floor(leaderboardEntry.driftScore + 0.5)
      or leaderboardEntry.driftScore
  end
  local stagedIsDrag = raceHasType(effectiveStagingRace, "drag")
  return {
    phase = "staging",
    raceLabel = displayLabel,
    routeName = nil,
    displayLap = 1,
    totalLaps = totalLapsVal,
    isLapRace = isLapRace and true or false,
    goalTime = not stagingIsDriftRace and effectiveStagingRace.bestTime or nil,
    personalBestTime = not stagingIsDriftRace and leaderboardEntry.time or nil,
    personalBestDriftScore = stagingPersonalBestDriftScore,
    scoreMode = (effectiveStagingRace and effectiveStagingRace.burnoutComp) and true or false,
    driftGoal = (stagingIsDriftRace and not effectiveStagingRace.burnoutComp) and effectiveStagingRace.driftGoal
      or nil,
    sectorSplitsUseScore = false,
    currentLapTime = 0,
    bestLapThisRun = nil,
    invalidLap = false,
    totalCheckpoints = 0,
    checkpointsHit = 0,
    sectors = {},
    staging = stagingUi,
    completion = nil,
    banner = banner,
    isDragRace = stagedIsDrag and true or false,
  }
end

function M.buildFreeroamRaceHudPayload()
  local raceUtils = utils()
  local trackFlow = competitiveTrackFlow()
  local circuitAi = circuitRaceAi()
  local banner = bannerPayloadForHud()
  local races = getSession().races
  if raceHud.completionSnapshot and raceHud.shown and not getSession().mActiveRace then
    return buildCompletedRaceHud(circuitAi, banner)
  end
  if getSession().mActiveRace and races[getSession().mActiveRace] and M.raceHudApplies(races[getSession().mActiveRace]) then
    return buildLiveRaceHud(trackFlow, circuitAi, banner, races)
  end
  local staged = getSession().staged
  if staged and races[staged] and M.raceHudApplies(races[staged]) then
    return buildStagingRaceHud(raceUtils, trackFlow, banner, races, staged)
  end
  return nil
end

-- HUD publication -----------------------------------------------------------------------------------

function M.pushFreeroamRaceHudState(force)
  local derby = rawget(_G, "overhaul_events_derby_derby")
  if derby and derby.ownsRaceHud and derby.ownsRaceHud() then return end
  if not raceHud.shown or not canBuildRaceHudPayload() then return end
  local now = (os and os.clock) and os.clock() or 0
  if not force and raceHud.pushClock and (now - raceHud.pushClock) < RACE_HUD_PUSH_INTERVAL_SECONDS then return end
  raceHud.pushClock = now
  local payload = M.buildFreeroamRaceHudPayload()
  if not payload then return end
  if raceHud.opening then
    raceHud.opening = false
    guihooks.trigger("FreeroamRaceHudShow", hudSnapshot.build(payload, "freeroamRaceHudLayout"))
  elseif force then
    statePush.send("FreeroamRaceHudState", payload)
  else
    statePush.refresh("FreeroamRaceHudState", payload)
  end
end

function M.showFreeroamRaceHud()
  raceHud.stagingProjection = nil
  raceHud.liveProjection = nil
  raceHud.shown = true
  raceHud.opening = true
  raceHud.pushClock = nil
  M.pushFreeroamRaceHudState(true)
end

function M.hideFreeroamRaceHud(force)
  if not force and getSession().mActiveRace then return end
  raceHud.shown = false
  raceHud.opening = false
  raceHud.pushClock = nil
  raceHud.banner = nil
  raceHud.stagingSubjectId = nil
  raceHud.stagingProjection = nil
  raceHud.liveProjection = nil
  raceHud.lastLapReward = nil
  raceHud.completionPayload = nil
  raceHud.completionSnapshot = nil
  guihooks.trigger("FreeroamRaceHudHide")
  raceHud.completionRemaining = nil
end

-- Stock drag UI (topCenter tree staging + topLeft dragInfo) is forced on by
-- gameplay_drag_core/display/dragBridge. Hide while FRE drag HUD owns the run.
function M.suppressVanillaDragHudApps(force)
  if not ui_appContainers then return end
  local now = os.clock()
  if
    force ~= true
    and vanillaDragHudSuppressed
    and vanillaDragHudSuppressedAt
    and (now - vanillaDragHudSuppressedAt) < 0.5
  then
    return
  end
  if ui_appContainers.getAppVisibility("topCenter", "drag") then
    ui_appContainers.hideApp("topCenter", "drag")
  end
  if ui_appContainers.getAppVisibility("topLeft", "dragInfo") then
    ui_appContainers.hideApp("topLeft", "dragInfo")
  end
  if ui_appContainers.getAppVisibility("topLeft", "dragDialControl") then
    ui_appContainers.hideApp("topLeft", "dragDialControl")
  end
  vanillaDragHudSuppressed = true
  vanillaDragHudSuppressedAt = now
end

-- Drag practice lifetime ----------------------------------------------------------------------------

function M.beginDragPracticeFreeroamHud(vehId, raceName)
  local races = getSession().races
  raceName = raceName or getSession().staged or getSession().mActiveRace
  if not raceHasType(races and races[raceName], "drag") or not vehId then
    log("W", "raceSession", "Drag practice unavailable: missing drag event " .. tostring(raceName))
    return
  end
  getSession().dragPracticeFlow = true
  getSession().staged = raceName
  M.prepareNewRaceHudState(raceName)
  M.setStagingSubjectId(resolveSessionInventoryFromSpawnId(vehId))
  M.suppressVanillaDragHudApps(true)
  M.showFreeroamRaceHud()
  notifyFreContractsFreeroamUi()
end

function M.beginDragPracticeFreeroamRace(vehId, raceName)
  local races = getSession().races
  raceName = raceName or getSession().staged or getSession().mActiveRace
  if not raceHasType(races and races[raceName], "drag") or not vehId then
    log("W", "raceSession", "Drag practice unavailable: missing drag event " .. tostring(raceName))
    return
  end
  getSession().staged = nil
  M.setStagingSubjectId(nil)
  if overhaul_career_career.isActive() then overhaul_career_economy_pauseTime.enablePauseCounter(true) end
  getSession().timerActive = true
  getSession().in_race_time = 0
  getSession().maxSpeed = 0
  getSession().mActiveRace = raceName
  getSession().dragPracticeActive = true
  getSession().mInventoryId = resolveSessionInventoryFromSpawnId(vehId)
  getSession().invalidLap = false
  local raceUtils = utils()
  M.setRaceHudBanner(raceUtils.getRaceStartBannerText(raceName), "good", 5)
  M.suppressVanillaDragHudApps(true)
  M.pushFreeroamRaceHudState(true)
  notifyFreContractsFreeroamUi()
end

function M.endDragPracticeFreeroamHud()
  if not getSession().dragPracticeFlow then return end
  getSession().dragPracticeFlow = false
  getSession().dragPracticeActive = false
  getSession().staged = nil
  getSession().mActiveRace = nil
  getSession().timerActive = false
  getSession().in_race_time = 0
  vanillaDragHudSuppressed = false
  vanillaDragHudSuppressedAt = nil
  M.setStagingSubjectId(nil)
  M.hideFreeroamRaceHud()
  notifyFreContractsFreeroamUi()
end

function M.dismissDragRaceHudCompletion(expectedGeneration)
  -- Bind deferred Close commands to the result displayed when they were sent.
  if
    expectedGeneration ~= raceHud.completionGeneration
    or not raceHud.shown
    or not raceHud.completionSnapshot
    or not raceHud.completionPayload
    or raceHud.completionPayload.kind ~= "drag"
    or getSession().mActiveRace
    or getSession().staged
  then
    return false
  end
  if getSession().dragPracticeFlow then
    M.endDragPracticeFreeroamHud()
  else
    M.hideFreeroamRaceHud()
  end
  return true
end

-- Completion cards ----------------------------------------------------------------------------------

function M.pushRaceHudCompletion(
  completionPayload,
  raceName,
  displayLabel,
  leaderboardLabel,
  currentLapTime,
  freezeCard
)
  local races = getSession().races
  if not completionPayload or type(completionPayload) ~= "table" or not raceHud.shown then return end
  if not raceName or not races[raceName] or not M.raceHudApplies(races[raceName]) then return end
  raceHud.completionGeneration = raceHud.completionGeneration + 1
  raceHud.completionPayload = completionPayload
  raceHud.completionRemaining = freezeCard and completionPayload.kind == "drag" and DRAG_RESULTS_SECONDS or nil
  if freezeCard then
    local race = races[raceName]
    local effectiveRace = (getSession().mAltRoute and race.altRoute) and race.altRoute or race
    local isLapRace = isLapRaceConfig(effectiveRace)
    local totalLapsSnap = isLapRace and getDisplayTotalLapsForRace(effectiveRace) or 0
    local leaderboardEntry = getSession().mInventoryId
        and leaderboardManager().getLeaderboardEntry(getSession().mInventoryId, leaderboardLabel or displayLabel)
      or {}
    local snapshotHasDriftGoal = effectiveRace and effectiveRace.driftGoal
    local snapshotUsesScore = effectiveRace and effectiveRace.burnoutComp
    local snapshotPersonalBestDriftScore = nil
    if (snapshotHasDriftGoal or snapshotUsesScore) and type(leaderboardEntry.driftScore) == "number" then
      snapshotPersonalBestDriftScore = snapshotUsesScore and math.floor(leaderboardEntry.driftScore + 0.5)
        or leaderboardEntry.driftScore
    end
    raceHud.completionSnapshot = {
      raceLabel = displayLabel,
      routeName = getSession().mCurrentRouteName,
      displayLap = isLapRace and hudDisplayLap(getSession().lapCount, totalLapsSnap) or 1,
      totalLaps = totalLapsSnap,
      isLapRace = isLapRace and true or false,
      goalTime = not snapshotHasDriftGoal and effectiveRace.bestTime or nil,
      personalBestTime = not snapshotHasDriftGoal and leaderboardEntry.time or nil,
      scoreMode = snapshotUsesScore and true or false,
      driftGoal = (snapshotHasDriftGoal and not snapshotUsesScore) and effectiveRace.driftGoal or nil,
      -- Payout already reset stock scoring; the result owns the finished run.
      driftScoreLive = completionPayload.result and completionPayload.result.driftScore or nil,
      personalBestDriftScore = snapshotPersonalBestDriftScore,
      scoreLabel = (effectiveRace and effectiveRace.burnoutComp) and "Score" or nil,
      sectorSplitsUseScore = snapshotHasDriftGoal and (tonumber(getSession().totalCheckpoints) or 0) > 0 or false,
      currentLapTime = currentLapTime,
      bestLapThisRun = getSession().mBestLapThisRun,
      invalidLap = getSession().invalidLap and true or false,
      totalCheckpoints = getSession().totalCheckpoints,
      checkpointsHit = 0,
      isDragRace = raceHasType(effectiveRace, "drag"),
    }
  else
    raceHud.completionSnapshot = nil
  end
  M.pushFreeroamRaceHudState(true)
end

function M.prepareNewRaceHudState(raceName)
  local races = getSession().races
  raceHud.stagingSubjectId = nil
  raceHud.stagingProjection = nil
  raceHud.liveProjection = nil
  raceHud.completionPayload = nil
  raceHud.completionSnapshot = nil
  raceHud.completionRemaining = nil
  raceSummary.laps = {}
  raceSummary.raceName = raceName
  raceSummary.displayLabel = races[raceName].label or raceName
  raceSummary.mainLabel = races[raceName].label or raceName
  raceSummary.altLabel = (races[raceName].altRoute and races[raceName].altRoute.label) or nil
  raceSummary.openLoop = races[raceName].checkpointRoad == true and not utils().hasFinishTrigger(raceName)
end

-- Completion celebration ----------------------------------------------------------------------------

local function buildCelebrationLapRows()
  local lapRows = {}
  for _, lap in ipairs(raceSummary.laps or {}) do
    table.insert(lapRows, {
      index = lap.index,
      time = eventHelpers.formatTime(lap.time),
      invalid = lap.invalid == true,
    })
  end
  local bestLapIndex = nil
  if #lapRows > 1 then
    local bestLapTimeSeconds = math.huge
    for _, lap in ipairs(raceSummary.laps or {}) do
      if not lap.invalid and lap.time < bestLapTimeSeconds then
        bestLapTimeSeconds = lap.time
        bestLapIndex = lap.index
      end
    end
  end
  for _, lapRow in ipairs(lapRows) do
    lapRow.isBest = (bestLapIndex ~= nil and lapRow.index == bestLapIndex)
  end
  return lapRows
end

function M.buildFreRaceCompletionCelebrationEntry(finalResult, hudCompletionPayload)
  utils()
  local place, fieldSize = 1, 1
  if finalResult.aiResults then
    fieldSize = #finalResult.aiResults
    for i, resultRow in ipairs(finalResult.aiResults) do
      if resultRow.isPlayer then
        place = i
        break
      end
    end
  end
  local money = tonumber(finalResult.reward) or 0
  local xp = tonumber(finalResult.xp) or 0
  if hudCompletionPayload and type(hudCompletionPayload) == "table" and hudCompletionPayload.rewards then
    local completionRewards = hudCompletionPayload.rewards
    if completionRewards.money ~= nil then money = math.floor(tonumber(completionRewards.money) or money) end
    if completionRewards.businessMoney ~= nil then
      money = money + math.floor(tonumber(completionRewards.businessMoney) or 0)
    end
    if completionRewards.disciplineXp ~= nil then xp = math.floor(tonumber(completionRewards.disciplineXp) or xp) end
  end
  fieldSize = math.max(fieldSize, place, 1)
  local lapRows = buildCelebrationLapRows()
  local sanctionedNoRewardDetail = nil
  if type(finalResult.sanctionedNoRewardDetail) == "string" and finalResult.sanctionedNoRewardDetail ~= "" then
    sanctionedNoRewardDetail = finalResult.sanctionedNoRewardDetail
  elseif
    hudCompletionPayload
    and type(hudCompletionPayload.sanctionedNoRewardDetail) == "string"
    and hudCompletionPayload.sanctionedNoRewardDetail ~= ""
  then
    sanctionedNoRewardDetail = hudCompletionPayload.sanctionedNoRewardDetail
  end
  return {
    raceLabel = finalResult.raceLabel or "Race",
    rewardMoney = money,
    rewardXp = xp,
    position = place,
    fieldSize = fieldSize,
    raceTime = eventHelpers.formatTime(finalResult.totalTime or 0),
    bestLap = finalResult.bestLap and eventHelpers.formatTime(finalResult.bestLap) or nil,
    lapsCompleted = finalResult.lapsCompleted,
    lapsTotal = finalResult.lapsTotal,
    lapRows = lapRows,
    summaryLines = {},
    sanctionedNoRewardDetail = sanctionedNoRewardDetail,
  }
end

function M.maybeShowFreerunSummary(cpRoad, isCompletion, deferResultScreen)
  if not (cpRoad and not isCompletion and not deferResultScreen) then return end
  if not getSession().freeroamPracticeStaging then return end
  if #raceSummary.laps <= 1 then return end
  guihooks.trigger("FreerunSummaryShow", M.buildFreSummaryPayload())
  raceSummary.laps = {}
  raceSummary.raceName = nil
end

-- Per-frame update ----------------------------------------------------------------------------------

function M.onUpdate(dtReal)
  if not raceHud.completionRemaining then return end
  raceHud.completionRemaining = raceHud.completionRemaining - math.max(0, tonumber(dtReal) or 0)
  if raceHud.completionRemaining <= 0 then
    raceHud.completionRemaining = nil
    M.dismissDragRaceHudCompletion(raceHud.completionGeneration)
  end
end

-- Lifecycle -----------------------------------------------------------------------------------------

local function onExtensionLoaded() end

-- Public API --------------------------------------------------------------------------------------

M.onExtensionLoaded = onExtensionLoaded

return M
