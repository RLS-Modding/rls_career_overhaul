-- Racing team goal definitions, leaderboard criteria and active/completed UI lists.
-- Read constants, definitions, criteria/baselines, counters, UI lists, progress and fleet notifications.
local M = {}
local businessHelpers = require('overhaul/lib/business/helpers')

local rtState = require('overhaul/career/business/racingTeam/racingTeam/runtimeState')
local racingTeamRaceOffers = require('overhaul/career/business/racingTeam/racingTeam/raceOffers')

-- Config ------------------------------------------------------------------------------------------

local HOME_MECHANIC_GOAL_ID = "rt_t1_g3"
local RT_T2_G4_TUNING_GOAL_ID = "rt_t2_g4"
local RT_T2_G6_TUNING_GOAL_ID = "rt_t2_g6"
local RT_T3_G3_TUNING_GOAL_ID = "rt_t3_g3"
local TIER3_DYNO_MIN_HP = 600
local BRACKET_NEAR_TOP_FRACTION = 0.25
local BRACKET_NEAR_TOP_MIN = 0.012


-- State -------------------------------------------------------------------------------------------

local helpers = {}

-- Shared helpers ----------------------------------------------------------------------------------

local function normalizeBusinessId(v)
  return tonumber(v) or v
end
-- Goal definitions and tuning milestones ------------------------------------------------------------

function M.loadDefinition()
  if rtState.rtInternal.goalsDefinitionLoaded then
    return rtState.rtInternal.goalsDefinition
  end
  rtState.rtInternal.goalsDefinitionLoaded = true
  if not FS:fileExists(rtState.K.RACING_TEAM_GOALS_PATH) then
    rtState.rtInternal.goalsDefinition = nil
    return nil
  end
  rtState.rtInternal.goalsDefinition = jsonReadFile(rtState.K.RACING_TEAM_GOALS_PATH)
  return rtState.rtInternal.goalsDefinition
end

function M.resolvedLeague(goal)
  if not goal then
    return "league1"
  end
  if type(goal.league) == "string" and goal.league ~= "" then
    return goal.league
  end
  local t = tonumber(goal.tier)
  if t and t >= 1 then
    return "league" .. tostring(math.floor(t))
  end
  return "league1"
end

local function leagueRankSortKey(leagueId)
  local n = tonumber(string.match(tostring(leagueId or ""), "^league(%d+)$"))
  return n or 99
end

local function leagueStuckCapProgressLabel(leagueId)
  local n = tonumber(string.match(tostring(leagueId or ""), "^league(%d+)$"))
  if n == 4 then
    return "Career complete"
  end
  if n then
    return string.format("League complete — League %d coming soon.", n + 1)
  end
  return "League complete"
end

function M.getSortedForLeague(def, leagueId)
  local out = {}
  if not def or type(def.goals) ~= "table" then
    return out
  end
  for _, goal in ipairs(def.goals) do
    if M.resolvedLeague(goal) == leagueId then
      table.insert(out, goal)
    end
  end
  table.sort(out, function(a, b)
    return (tonumber(a.order) or 0) < (tonumber(b.order) or 0)
  end)
  return out
end

function M.formatRaceTime(seconds)
  if not seconds or seconds <= 0 then
    return "--"
  end
  if utils and utils.formatTime then
    return utils.formatTime(seconds)
  end
  return string.format("%.2f s", seconds)
end

function M.idCompleted(businessId, goalId)
  local id = tostring(normalizeBusinessId(businessId))
  local completions = rtState.goalCompletionByBusiness[id]
  return completions and completions[goalId] == true
end

function M.tuningMilestonePreDoneForGoal(businessId, goalIdStr)
  local id = tostring(normalizeBusinessId(businessId))
  local completions = rtState.tuningMilestoneByGoalByBusiness[id]
  return completions and completions[goalIdStr] == true
end

function M.setTuningMilestoneGoalPreDone(businessId, goalIdStr)
  local bid = normalizeBusinessId(businessId)
  local id = tostring(bid)
  rtState.tuningMilestoneByGoalByBusiness[id] = rtState.tuningMilestoneByGoalByBusiness[id] or {}
  if rtState.tuningMilestoneByGoalByBusiness[id][goalIdStr] then
    return
  end
  rtState.tuningMilestoneByGoalByBusiness[id][goalIdStr] = true
  local completions = rtState.tuningMilestoneByGoalByBusiness[id]
  rtState.tuningMilestoneByBusiness[id] = next(completions) ~= nil
  local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
  if savePath then
    rtState.parts.persist.saveRacingTeamPersistedState(bid, savePath)
  end
  rtState.rtInternal.advanceRacingTeamGoalsIfReady(bid)
end

-- Leaderboard helpers -----------------------------------------------------------------------------
function M.getPrimaryLeaderboardVehicleId(businessId)
  local inv = overhaul_career_business_fleet
  local vehicles = inv.getBusinessVehicles(businessId) or {}
  for _, vehicle in ipairs(vehicles) do
    if vehicle and vehicle.vehicleId ~= nil then
      return tonumber(vehicle.vehicleId) or vehicle.vehicleId
    end
  end
  return nil
end

function helpers.hasBusinessVehicle(businessId)
  return M.getPrimaryLeaderboardVehicleId(businessId) ~= nil
end

local function getBestTimeForBusinessVehicle(businessId, vehicleId, raceType, raceLabel, labels)
  local levels = rtState.parts.board.resolveRacingTeamLeaderboardLevelIds()
  local best
  for _, label in ipairs(type(labels) == "table" and labels[1] and labels or {raceLabel}) do
    local time = businessHelpers.getBestLeaderboardTime(businessId, vehicleId, raceType, label, levels)
    if time and (not best or time < best) then best = time end
  end
  return best
end

function helpers.getBestTimeAcrossAllTeamJobs(businessId, raceType, raceLabel, labels)
  local inv = overhaul_career_business_fleet
  local best = nil
  local vehicles = inv.getBusinessVehicles(businessId) or {}
  for _, vehicle in ipairs(vehicles) do
    local vid = vehicle and (tonumber(vehicle.vehicleId) or vehicle.vehicleId)
    if vid ~= nil then
      local t = getBestTimeForBusinessVehicle(businessId, vid, raceType, raceLabel, labels)
      if t and t > 0 and (not best or t < best) then
          best = t
      end
    end
  end
  return best
end

function helpers.snapshotCompletedGoalLeaderboardTimesAtCompletion(businessId, goalId)
  if not goalId then
    return
  end
  local def = M.loadDefinition()
  if not def or type(def.goals) ~= "table" then
    return
  end
  local goal = nil
  for _, candidateGoal in ipairs(def.goals) do
    if candidateGoal and candidateGoal.id == goalId then
      goal = candidateGoal
      break
    end
  end
  if not goal then
    return
  end
  local kind = goal.kind or ""
  local id = tostring(normalizeBusinessId(businessId))
  rtState.completedGoalLeaderboardTimesByBusiness[id] = rtState.completedGoalLeaderboardTimesByBusiness[id] or {}
  if kind == "vehicle_and_leaderboard" then
    local raceType, raceLabel = goal.raceType, goal.raceLabel
    if raceType and raceLabel then
      local best = helpers.getBestTimeAcrossAllTeamJobs(businessId, raceType, raceLabel, goal.leaderboardLabels)
      rtState.completedGoalLeaderboardTimesByBusiness[id][goalId] = {
        kind = "single",
        bestSec = best,
      }
    end
  elseif kind == "all_leaderboards" and type(goal.tracks) == "table" then
    local rows = {}
    for _, track in ipairs(goal.tracks) do
      local raceType, raceLabel = track.raceType, track.raceLabel
      local t = nil
      if raceType and raceLabel then
        t = helpers.getBestTimeAcrossAllTeamJobs(businessId, raceType, raceLabel, track.leaderboardLabels)
      end
      table.insert(rows, { raceType = raceType, raceLabel = raceLabel, bestSec = t })
    end
    rtState.completedGoalLeaderboardTimesByBusiness[id][goalId] = {
      kind = "tracks",
      tracks = rows,
    }
  end
end

-- Baseline tracking for all_leaderboards goals ----------------------------------------------------
do
  local function findGoalInDefinition(goalId)
    local def = M.loadDefinition()
    if not def or type(def.goals) ~= "table" then
      return nil
    end
    for _, candidateGoal in ipairs(def.goals) do
      if candidateGoal and candidateGoal.id == goalId then
        return candidateGoal
      end
    end
    return nil
  end

  local function recordAllLeaderboardsBaselinesForGoal(businessId, goalIdWithAllLeaderboards)
    local goal = findGoalInDefinition(goalIdWithAllLeaderboards)
    if not goal or (goal.kind or "") ~= "all_leaderboards" or type(goal.tracks) ~= "table" then
      return
    end
    local id = tostring(normalizeBusinessId(businessId))
    local entries = {}
    for _, track in ipairs(goal.tracks) do
      local raceType, raceLabel = track.raceType, track.raceLabel
      local best = nil
      if raceType and raceLabel then
        best = helpers.getBestTimeAcrossAllTeamJobs(businessId, raceType, raceLabel, track.leaderboardLabels)
      end
      table.insert(entries, { raceType = raceType, raceLabel = raceLabel, baselineSec = best })
    end
    rtState.allLeaderboardsBaselineByBusiness[id] = rtState.allLeaderboardsBaselineByBusiness[id] or {}
    rtState.allLeaderboardsBaselineByBusiness[id][goalIdWithAllLeaderboards] = entries
  end

  function rtState.rtInternal.recordBaselinesAfterCompletedPrerequisite(businessId, completedGoalId)
    local def = M.loadDefinition()
    if not def or type(def.goals) ~= "table" then
      return
    end
    for _, candidateGoal in ipairs(def.goals) do
      if candidateGoal and (candidateGoal.kind or "") == "all_leaderboards" and type(candidateGoal.baselineAfterGoalId) == "string"
          and candidateGoal.baselineAfterGoalId == completedGoalId and type(candidateGoal.id) == "string" then
        recordAllLeaderboardsBaselinesForGoal(businessId, candidateGoal.id)
      end
    end
  end

  function rtState.rtInternal.ensureAllLeaderboardsBaselineForGoal(businessId, goal)
    local prereq = goal.baselineAfterGoalId
    if type(prereq) ~= "string" then
      return nil
    end
    if not M.idCompleted(businessId, prereq) then
      return nil
    end
    local id = tostring(normalizeBusinessId(businessId))
    rtState.allLeaderboardsBaselineByBusiness[id] = rtState.allLeaderboardsBaselineByBusiness[id] or {}
    local ent = rtState.allLeaderboardsBaselineByBusiness[id][goal.id]
    if not ent or #ent == 0 then
      recordAllLeaderboardsBaselinesForGoal(businessId, goal.id)
      local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
      if savePath then
        rtState.parts.persist.saveRacingTeamPersistedState(businessId, savePath)
      end
      ent = rtState.allLeaderboardsBaselineByBusiness[id][goal.id]
    end
    return ent
  end
end

-- Stamina / podium counters -----------------------------------------------------------------------
function rtState.rtInternal.getStaminaStreak(businessId)
  local id = tostring(normalizeBusinessId(businessId))
  return rtState.staminaShortTrackStreakByBusiness[id] or 0
end

function rtState.rtInternal.setStaminaStreak(businessId, n)
  local id = tostring(normalizeBusinessId(businessId))
  rtState.staminaShortTrackStreakByBusiness[id] = math.max(0, math.floor(n))
end

function helpers.getLeagueHeadGoalId(businessId, def, leagueId)
  if not def or type(def.goals) ~= "table" then
    return nil
  end
  local leagueGoals = M.getSortedForLeague(def, leagueId)
  if type(leagueGoals) ~= "table" then
    return nil
  end
  for _, goal in ipairs(leagueGoals) do
    if goal and goal.id and not M.idCompleted(businessId, goal.id) then
      return goal.id
    end
  end
  return nil
end

-- Stamina streak reset when head goal is rt_t1_g4 (GOAL_UNLOCK_SANCTIONED_RACE_OFFERS)
function helpers.resetStaminaStreakIfStaminaGoalIsHead(businessId)
  local def = M.loadDefinition()
  local leagueId = rtState.rtInternal.getCurrentLeague(businessId)
  local headId = helpers.getLeagueHeadGoalId(businessId, def, leagueId)
  if headId == rtState.K.GOAL_UNLOCK_SANCTIONED_RACE_OFFERS then
    rtState.rtInternal.setStaminaStreak(businessId, 0)
    local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
    if savePath then
      rtState.parts.persist.saveRacingTeamPersistedState(businessId, savePath)
    end
  end
end

function rtState.rtInternal.getSanctionedOfficialFirstPlaceWins(businessId)
  local id = tostring(normalizeBusinessId(businessId))
  return rtState.sanctionedOfficialFirstPlaceWinsByBusiness[id] or 0
end

-- Business / fleet helpers used by goal evaluation ------------------------------------------------
function helpers.racingTeamOfferMatchesBusiness(businessId, offer)
  if type(offer) ~= "table" or offer.racingTeamBusinessOffer ~= true then
    return false
  end
  local ob = offer.businessId
  if ob == nil then
    return false
  end
  return tostring(normalizeBusinessId(ob)) == tostring(normalizeBusinessId(businessId))
end

function helpers.isPurchasedRacingTeamBusiness(purchased, bid)
  if type(purchased) ~= "table" or bid == nil then
    return false
  end
  local want = tostring(normalizeBusinessId(bid))
  for k, _ in pairs(purchased) do
    if tostring(normalizeBusinessId(k)) == want then
      return true
    end
  end
  return false
end

function helpers.getBusinessOperatingEarningsTotal(businessId)
  local bank = overhaul_career_economy_bank
  local acct = bank.getBusinessAccount(rtState.businessType, businessId)
  if not acct or not acct.id then
    return nil
  end
  local t0 = tonumber(acct.createdAt) or 0
  local list = bank.getAccountTransactions(acct.id, nil) or {}
  local sum = 0
  for _, track in ipairs(list) do
    local amt = tonumber(track.amount) or 0
    if amt > 0 then
      local ts = tonumber(track.timestamp) or 0
      if ts >= t0 then
        local lab = tostring(track.label or "")
        if lab ~= "Capital Injection" and lab ~= "Transfer In" and lab ~= "Transfer Refund" then
          sum = sum + amt
        end
      end
    end
  end
  return math.floor(sum + 0.5)
end

function helpers.countFleetSanctionedBranch(businessId, wantBranch)
  local want = string.lower(tostring(wantBranch or ""))
  if want == "" then
    return 0
  end
  local n = 0
  for _, v in ipairs(overhaul_career_business_fleet.getBusinessVehicles(businessId) or {}) do
    local br = rtState.parts.fleet.resolveFleetVehicleSanctionedBranch(businessId, v)
    if type(br) == "string" and string.lower(br) == want then
      n = n + 1
    end
  end
  return n
end

function helpers.fleetHasSuperBranchVehicle(businessId)
  return helpers.countFleetSanctionedBranch(businessId, "super") > 0
end

function helpers.maxFleetDynoPeakHp(businessId)
  local id = tostring(normalizeBusinessId(businessId))
  local peaks = rtState.classOptimizationPeakHpByBusiness[id]
  if type(peaks) ~= "table" then
    return 0
  end
  local best = 0
  for _, e in pairs(peaks) do
    local hp = type(e) == "table" and tonumber(e.hp) or tonumber(e)
    if hp and hp > best then
      best = hp
    end
  end
  return best
end

function helpers.fleetHasVehicleInSanctionedBracket(businessId, bracketId)
  local sr = overhaul_events_fre_sanctionedRacing
  local b = sr and sr.getSanctionedPwBracketById and sr.getSanctionedPwBracketById(bracketId)
  if not b then
    return false
  end
  local lo = tonumber(b.classPwMin) or 0
  local hi = tonumber(b.classPwMax) or 0
  if hi < lo then
    lo, hi = hi, lo
  end
  for _, v in ipairs(overhaul_career_business_fleet.getBusinessVehicles(businessId) or {}) do
    local pw = rtState.parts.fleet.getEffectiveTeamJobVehiclePw(businessId, v)
    if pw and pw >= lo and pw <= hi + 1e-4 then
      return true
    end
  end
  return false
end

function helpers.fleetHasVehicleNearSanctionedBracketTop(businessId, bracketId)
  local sr = overhaul_events_fre_sanctionedRacing
  local b = sr and sr.getSanctionedPwBracketById and sr.getSanctionedPwBracketById(bracketId)
  if not b then
    return false
  end
  local lo = tonumber(b.classPwMin) or 0
  local hi = math.max(tonumber(b.classPwMax) or 0, lo)
  local span = hi - lo
  local margin = math.max(BRACKET_NEAR_TOP_MIN, span * BRACKET_NEAR_TOP_FRACTION)
  local floorPw = hi - margin
  for _, v in ipairs(overhaul_career_business_fleet.getBusinessVehicles(businessId) or {}) do
    local pw = rtState.parts.fleet.getEffectiveTeamJobVehiclePw(businessId, v)
    if pw and pw >= floorPw and pw <= hi + 1e-4 then
      return true
    end
  end
  return false
end

-- Goal UI lists -----------------------------------------------------------------------------------

local function goalRowToUi(goal, progressLabel, status, leagueLabel, targetLabelOverride)
  local lg = leagueLabel or M.resolvedLeague(goal)
  return {
    id = goal.id,
    title = goal.title or "",
    description = goal.description or "",
    targetLabel = targetLabelOverride or goal.targetLabel or "",
    progressLabel = progressLabel or goal.progressLabel or "Not Started",
    tier = goal.tier,
    order = goal.order,
    league = lg,
    status = status or goal.status or "active"
  }
end

function M.getActiveList(businessId)
  local def = M.loadDefinition()
  local leagueId = rtState.currentLeagueByBusiness[tostring(normalizeBusinessId(businessId))]
  if type(leagueId) ~= "string" or leagueId == "" then leagueId = "league1" end
  local leagueGoals = M.getSortedForLeague(def, leagueId)
  local rows = {}
  for _, goal in ipairs(leagueGoals) do
    if goal.id and not M.idCompleted(businessId, goal.id) then
      local _, progressLabel, targetLabelOverride = M.evaluateGoalProgress(businessId, goal, true)
      rows[1] = goalRowToUi(goal, progressLabel, "active", leagueId, targetLabelOverride)
      break
    end
  end
  return rows, leagueId, leagueGoals
end

function rtState.rtInternal.prepareActiveGoalData(businessId)
  local def = M.loadDefinition()
  local leagueId = rtState.currentLeagueByBusiness[tostring(normalizeBusinessId(businessId))]
  if type(leagueId) ~= "string" or leagueId == "" then leagueId = "league1" end
  for _, goal in ipairs(M.getSortedForLeague(def, leagueId)) do
    if goal.id and not M.idCompleted(businessId, goal.id) then
      M.prepareGoalProgress(businessId, goal)
      break
    end
  end
end

local function formatCompletedRaceTime(seconds)
  if not seconds or seconds <= 0 then
    return "--"
  end
  local s = tonumber(seconds) or 0
  local mi = math.floor(s / 60)
  local secPart = s - mi * 60
  return string.format("%d:%05.2f", mi, secPart)
end

local function buildCompletedBestTimesSummary(businessId, goal)

  if not goal or type(goal) ~= "table" or not goal.id then
    return nil
  end
  local id = tostring(normalizeBusinessId(businessId))
  local snap = (rtState.completedGoalLeaderboardTimesByBusiness[id] or {})[goal.id]
  local kind = goal.kind or ""
  if kind == "vehicle_and_leaderboard" then
    local raceType, raceLabel = goal.raceType, goal.raceLabel
    if not raceType or not raceLabel then
      return nil
    end
    local best = snap and snap.kind == "single" and tonumber(snap.bestSec) or nil
    if not best or best <= 0 then
      return "Best time: --"
    end
    return "Best time: " .. formatCompletedRaceTime(best)
  end
  if kind == "all_leaderboards" then
    local tracks = goal.tracks
    if type(tracks) ~= "table" or #tracks == 0 then
      return nil
    end
    local function historicalSecForTrack(raceType, raceLabel)
      if not snap or snap.kind ~= "tracks" or type(snap.tracks) ~= "table" then
        return nil
      end
      for _, row in ipairs(snap.tracks) do
        if row.raceType == raceType and row.raceLabel == raceLabel then
          return tonumber(row.bestSec)
        end
      end
      return nil
    end
    local parts = {}
    for _, track in ipairs(tracks) do
      local raceType, raceLabel = track.raceType, track.raceLabel
      local shortName = track.shortName or raceLabel or raceType or "?"
      if raceType and raceLabel then
        local t = historicalSecForTrack(raceType, raceLabel)
        table.insert(parts, shortName .. ": " .. ((t and t > 0) and formatCompletedRaceTime(t) or "--"))
      else
        table.insert(parts, shortName .. ": --")
      end
    end
    if #parts == 0 then
      return nil
    end
    return "Best times: " .. table.concat(parts, " | ")
  end
  return nil
end

function M.getCompletedList(businessId)
  rtState.parts.helpers.getOfferState(businessId)
  local def = M.loadDefinition()
  local goals = def and def.goals
  local byId = {}
  if type(goals) == "table" then
    for _, goal in ipairs(goals) do
      if goal.id then
        byId[goal.id] = goal
      end
    end
  end
  local id = tostring(normalizeBusinessId(businessId))
  local out = {}
  for gid, done in pairs(rtState.goalCompletionByBusiness[id] or {}) do
    if done and byId[gid] then
      local goal = byId[gid]
      local row = goalRowToUi(goal, goal.progressDone or goal.progressLabel or "Complete", "complete")
      local timesSummary = buildCompletedBestTimesSummary(businessId, goal)
      if timesSummary then
        row.completedBestTimesSummary = timesSummary
      end
      table.insert(out, row)
    end
  end
  table.sort(out, function(a, b)
    local la = leagueRankSortKey(a.league)
    local lb = leagueRankSortKey(b.league)
    if la ~= lb then
      return la < lb
    end
    return (tonumber(a.order) or 0) < (tonumber(b.order) or 0)
  end)
  return out
end

function M.buildDisplays(businessId)
  local def = M.loadDefinition()
  local goals = def and def.goals
  if not goals or #goals == 0 then
    local row = goalRowToUi({
      id = "rt_t1_g1",
      title = "First Outing",
      description = "Purchase a vehicle and complete 1 lap on the Short Track",
      targetLabel = "Complete one lap",
      progressLabel = "Not Started",
      tier = 1,
      order = 1,
      status = "active"
    }, "Not Started", "active", "league1")
    return row, {}, "league1"
  end

  local activeGoals, leagueId, leagueGoals = M.getActiveList(businessId)
  if #activeGoals > 0 then
    return activeGoals[1], activeGoals, leagueId
  end
  if leagueGoals and #leagueGoals > 0 then
    local allDone = true
    for _, goal in ipairs(leagueGoals) do
      if goal.id and not M.idCompleted(businessId, goal.id) then
        allDone = false
        break
      end
    end
    if allDone then
      local last = leagueGoals[#leagueGoals]
      local row = goalRowToUi(last, leagueStuckCapProgressLabel(leagueId), "completed", leagueId)
      return row, activeGoals, leagueId
    end
  end
  local fallback = (leagueGoals and leagueGoals[1]) or goals[1]
  if not fallback then
    local row = goalRowToUi({
      id = "none",
      title = "Goals",
      description = "No goals configured",
      order = 1,
    }, "Not configured", "active", leagueId or "league1")
    return row, activeGoals, leagueId or "league1"
  end
  local row = goalRowToUi(fallback, fallback.progressLabel or "Not Started", "active", leagueId or M.resolvedLeague(fallback))
  return row, activeGoals, leagueId or M.resolvedLeague(fallback)
end


-- Goal progress and fleet notifications ------------------------------------------------------------


local function maybeCompleteHomeMechanicFromFleetPw(businessId)
  local bid = normalizeBusinessId(businessId)
  if not bid then
    return
  end
  local id = tostring(bid)
  if M.tuningMilestonePreDoneForGoal(bid, HOME_MECHANIC_GOAL_ID) then
    return
  end
  if M.idCompleted(bid, HOME_MECHANIC_GOAL_ID) then
    return
  end
  if not helpers.hasBusinessVehicle(bid) then
    return
  end
  local cur = rtState.parts.fleet.getBestTeamJobVehiclePw(bid)
  if not cur or cur <= 0 then
    return
  end
  local base = rtState.homeMechanicBaselinePwByBusiness[id]
  if base == nil then
    rtState.homeMechanicBaselinePwByBusiness[id] = cur
    local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
    if savePath then
      rtState.parts.persist.saveRacingTeamPersistedState(bid, savePath)
    end
    return
  end
  if cur > base + 1e-5 then
    M.setTuningMilestoneGoalPreDone(bid, HOME_MECHANIC_GOAL_ID)
  end
end

local function scheduleHomeMechanicPwRecheckAfterParts(businessId)
  local bid = normalizeBusinessId(businessId)
  if not bid then
    return
  end
  rtState.pendingHomeMechanicPwRecheckByBusiness[tostring(bid)] = true
end

function M.tickHomeMechanicPwDeferredRechecks()
  local pend = rtState.pendingHomeMechanicPwRecheckByBusiness
  if not pend or not next(pend) then
    return
  end
  local bids = {}
  for idStr, _ in pairs(pend) do
    pend[idStr] = nil
    table.insert(bids, tonumber(idStr) or idStr)
  end
  for _, bid in ipairs(bids) do
    maybeCompleteHomeMechanicFromFleetPw(bid)
  end
end

-- Goal evaluators: account and driver progress ------------------------------------------------------
local function driversForProgress(businessId, readOnly)
  if readOnly then return rtState.businessDrivers[normalizeBusinessId(businessId)] or {} end
  return rtState.loadRacingTeamDrivers(businessId)
end

local function evaluatePlaceholder(businessId, goal)
  return false, goal.progressLabel or "Coming soon"
end

local function evaluateTierCap(businessId, goal)
  return true, goal.progressDone or goal.progressLabel or "Complete"
end

local function evaluateSanctionedPodium(businessId, goal)
  if M.idCompleted(businessId, goal.id) then
    return true, goal.progressDone or (goal.targetLabel or "Complete")
  end
  return false, goal.progressNoPodium or goal.progressLabel or "Place 1st–3rd in a sanctioned race"
end

local function evaluateFinancialMilestone(businessId, goal)
  local target = tonumber(goal.targetAmount) or 15000
  if target <= 0 then
    target = 15000
  end
  local earned = helpers.getBusinessOperatingEarningsTotal(businessId)
  if earned == nil then
    return false, goal.progressLabel or "Bank or business account unavailable"
  end
  if earned >= target then
    return true, goal.progressDone or (goal.targetLabel or "Complete")
  end
  return false, string.format("Earnings: $%d / $%d", earned, math.floor(target))
end

local function evaluateManagementAction(businessId, goal, readOnly)
  local target = tonumber(goal.targetDriverCount)
  if not target or target < 1 then
    target = 1
  end
  local count = 0
  for _, t in ipairs(driversForProgress(businessId, readOnly)) do
    if t and not t.fired then
      count = count + 1
    end
  end
  if count >= target then
    return true, goal.progressDone or (goal.targetLabel or "Complete")
  end
  if target <= 1 then
    return false, goal.progressLabel or "Driver not hired"
  end
  return false, string.format("Drivers: %d/%d", count, target)
end

local function evaluateFleetSize(businessId, goal)
  local target = tonumber(goal.targetFleetCount) or 2
  if target < 1 then
    target = 2
  end
  local bidStr = tostring(goal.hpBracketId or "")
  if bidStr == "" then
    return false, goal.progressLabel or "Not configured"
  end
  local sr = overhaul_events_fre_sanctionedRacing
  local bracket = sr and sr.getSanctionedPwBracketById and sr.getSanctionedPwBracketById(bidStr)
  if not bracket then
    return false, goal.progressLabel or "Unknown class bracket"
  end
  local fb = goal.fleetBranch
  if type(fb) == "string" and fb ~= "" then
    if string.lower(tostring(bracket.branch or "")) ~= string.lower(fb) then
      return false, goal.progressLabel or "Bracket mismatch"
    end
  end
  local lo = tonumber(bracket.classPwMin) or 0
  local hi = tonumber(bracket.classPwMax) or 0
  if hi < lo then
    lo, hi = hi, lo
  end
  local vehicles = overhaul_career_business_fleet.getBusinessVehicles(businessId) or {}
  local count = 0
  for _, v in ipairs(vehicles) do
    local pw = rtState.parts.fleet.getEffectiveTeamJobVehiclePw(businessId, v)
    if pw and pw >= lo and pw <= hi then
      count = count + 1
    end
  end
  if count >= target then
    return true, goal.progressDone or (goal.targetLabel or "Complete")
  end
  local label = bracket.label or bidStr
  return false, string.format("Vehicles: %d/%d (%s)", count, target, label)
end

local function evaluateAiRaceResults(businessId, goal, readOnly)
  local target = tonumber(goal.targetPodiums) or 5
  if target < 1 then
    target = 5
  end
  local total = 0
  for _, t in ipairs(driversForProgress(businessId, readOnly)) do
    if t and not t.fired then
      total = total + math.max(0, math.floor(tonumber(t.sanctionedPodiums) or 0))
    end
  end
  if total >= target then
    return true, goal.progressDone or (goal.targetLabel or "Complete")
  end
  return false, string.format("Podiums: %d/%d", total, target)
end

local function evaluateRaceParticipation(businessId, goal, readOnly)
  local target = tonumber(goal.targetRaces) or 10
  if target < 1 then
    target = 10
  end
  local total = 0
  for _, t in ipairs(driversForProgress(businessId, readOnly)) do
    if t and not t.fired then
      total = total + math.max(0, math.floor(tonumber(t.sanctionedRacesFinished) or 0))
    end
  end
  if total >= target then
    return true, goal.progressDone or (goal.targetLabel or "Complete")
  end
  return false, string.format("Races finished: %d/%d", total, target)
end

local function evaluateBusinessValue(businessId, goal)
  local target = tonumber(goal.targetAmount)
  if not target or target <= 0 then
    target = 50000
  end
  local cash = 0
  local account = overhaul_career_economy_bank.getBusinessAccount(rtState.businessType, businessId)
  local accountId = account and (account.id or account.accountId)
  if accountId then
    cash = math.floor(math.max(0, tonumber(overhaul_career_economy_bank.getAccountBalance(accountId)) or 0))
  end
  local fleetValue = 0
  local vehicles = overhaul_career_business_fleet.getBusinessVehicles(businessId) or {}
  for _, vehicle in ipairs(vehicles) do
    fleetValue = fleetValue + rtState.parts.fleet.getTeamVehicleBookValue(vehicle)
  end
  local teamValue = cash + fleetValue
  if teamValue >= target then
    return true, goal.progressDone or (goal.targetLabel or "Complete")
  end
  return false, string.format("Value: $%d / $%d", teamValue, math.floor(target))
end

local function evaluateAiRaceWins(businessId, goal, readOnly)
  local target = tonumber(goal.targetWins) or 10
  if target < 1 then
    target = 10
  end
  local total = 0
  for _, t in ipairs(driversForProgress(businessId, readOnly)) do
    if t and not t.fired then
      total = total + math.max(0, math.floor(tonumber(t.sanctionedRaceWins) or 0))
    end
  end
  if total >= target then
    return true, goal.progressDone or (goal.targetLabel or "Complete")
  end
  return false, string.format("Wins: %d/%d", total, target)
end

local function evaluateCashReserve(businessId, goal)
  local target = tonumber(goal.targetAmount)
  if not target or target <= 0 then
    target = 100000
  end
  local cash = 0
  local account = overhaul_career_economy_bank.getBusinessAccount(rtState.businessType, businessId)
  local accountId = account and (account.id or account.accountId)
  if accountId then
    cash = math.floor(math.max(0, tonumber(overhaul_career_economy_bank.getAccountBalance(accountId)) or 0))
  end
  if cash >= target then
    return true, goal.progressDone or (goal.targetLabel or "Complete")
  end
  return false, string.format("$%d / $%d", cash, math.floor(target))
end

-- Goal evaluators: fleet and leaderboard progress --------------------------------------------------

local function evaluateVehicleTierUp(businessId, goal)
  if helpers.fleetHasSuperBranchVehicle(businessId) then
    return true, goal.progressDone or (goal.targetLabel or "Complete")
  end
  return false, goal.progressLabel or "Super class not owned"
end

local function evaluateFleetDiversity(businessId, goal, readOnly)
  local modMin = tonumber(goal.fleetModifiedMin)
  local supMin = tonumber(goal.fleetSuperMin)
  if supMin and supMin > 0 and (not modMin or modMin <= 0) then
    local supN = helpers.countFleetSanctionedBranch(businessId, "super")
    if supN >= supMin then
      return true, goal.progressDone or (goal.targetLabel or "Complete")
    end
    return false, string.format("Fleet: Super %d/%d", supN, supMin)
  end
  if modMin and supMin and modMin > 0 and supMin > 0 then
    local modN = helpers.countFleetSanctionedBranch(businessId, "modified")
    local supN = helpers.countFleetSanctionedBranch(businessId, "super")
    if modN >= modMin and supN >= supMin then
      return true, goal.progressDone or (goal.targetLabel or "Complete")
    end
    return false, string.format("Fleet: Modified %d/%d, Super %d/%d", modN, modMin, supN, supMin)
  end
  local ms = tostring(goal.milestone or "")
  if ms == "grid_presence" then
    local vehCount = #(overhaul_career_business_fleet.getBusinessVehicles(businessId) or {})
    local drvCount = 0
    for _, t in ipairs(driversForProgress(businessId, readOnly)) do
      if t and not t.fired then
        drvCount = drvCount + 1
      end
    end
    if vehCount >= 2 and drvCount >= 2 then
      return true, goal.progressDone or (goal.targetLabel or "Complete")
    end
    return false, goal.progressLabel or "Requirements not met"
  end
  if ms == "scaled_operation" then
    local vehCount = #(overhaul_career_business_fleet.getBusinessVehicles(businessId) or {})
    if vehCount >= 4 then
      return true, goal.progressDone or (goal.targetLabel or "Complete")
    end
    return false, string.format("Cars: %d/4", vehCount)
  end
  return false, goal.progressLabel or "Requirements not met"
end

local function evaluateReliabilityStreak(businessId, goal, readOnly)
  local target = tonumber(goal.targetRaces) or 25
  if target < 1 then
    target = 25
  end
  local total = 0
  for _, t in ipairs(driversForProgress(businessId, readOnly)) do
    if t and not t.fired then
      total = total + math.max(0, math.floor(tonumber(t.sanctionedRacesFinished) or 0))
    end
  end
  if total >= target then
    return true, goal.progressDone or (goal.targetLabel or "Complete")
  end
  return false, string.format("Races finished: %d/%d", total, target)
end

local function evaluateVehicleAndLeaderboard(businessId, goal)
  local raceType, raceLabel = goal.raceType, goal.raceLabel
  if not raceType or not raceLabel then
    return false, goal.progressLabel or "Not configured"
  end
  local best = helpers.getBestTimeAcrossAllTeamJobs(businessId, raceType, raceLabel, goal.leaderboardLabels)
  if best and best > 0 then
    return true, goal.progressDone or (goal.targetLabel or "Complete")
  end
  return false, goal.progressNoTime or goal.progressLabel or "Complete a timed lap in your team car"
end

local function findBaselineSecForTrack(entries, raceType, raceLabel)
  if not entries then
    return nil
  end
  for _, e in ipairs(entries) do
    if e.raceType == raceType and e.raceLabel == raceLabel then
      local b = tonumber(e.baselineSec)
      if b and b > 0 then
        return b
      end
      return nil
    end
  end
  return nil
end
local function trackLeaderboardBeatsBaseline(current, baselineSec)
  if not current or current <= 0 then
    return false
  end
  if not baselineSec or baselineSec <= 0 then
    return true
  end
  return current + 1e-6 < baselineSec
end

local function evaluateAllLeaderboards(businessId, goal, readOnly)
  local tracks = goal.tracks
  if not tracks or #tracks == 0 then
    return false, goal.progressLabel or "Not configured"
  end
  local baselineEntries = nil
  if type(goal.baselineAfterGoalId) == "string" then
    if readOnly then
      local saved = M.idCompleted(businessId, goal.baselineAfterGoalId) and rtState.allLeaderboardsBaselineByBusiness[tostring(normalizeBusinessId(businessId))]
      baselineEntries = saved and saved[goal.id]
    else
      baselineEntries = rtState.rtInternal.ensureAllLeaderboardsBaselineForGoal(businessId, goal)
    end
  end
  local parts = {}
  local allOk = true
  for _, track in ipairs(tracks) do
    local raceType, raceLabel = track.raceType, track.raceLabel
    local shortName = track.shortName or raceLabel or raceType or "?"
    if not raceType or not raceLabel then
      allOk = false
      table.insert(parts, shortName .. ": ?")
    else
      local current = helpers.getBestTimeAcrossAllTeamJobs(businessId, raceType, raceLabel, track.leaderboardLabels)
      local base = baselineEntries and findBaselineSecForTrack(baselineEntries, raceType, raceLabel) or nil
      local trackOk = false
      if baselineEntries == nil then
        trackOk = current and current > 0
      else
        trackOk = trackLeaderboardBeatsBaseline(current, base)
      end
      if trackOk then
        table.insert(parts, shortName .. ": " .. M.formatRaceTime(current))
      else
        allOk = false
        if current and current > 0 then
          table.insert(parts, shortName .. ": " .. M.formatRaceTime(current))
        else
          table.insert(parts, shortName .. ": --")
        end
      end
    end
  end
  return allOk, table.concat(parts, " | ")
end

local function evaluateTuningMilestone(businessId, goal)
  local id = tostring(normalizeBusinessId(businessId))
  local gid = tostring(goal.id or "")
  if M.idCompleted(businessId, gid) then
    return true, goal.progressDone or (goal.targetLabel or "Complete")
  end
  if M.tuningMilestonePreDoneForGoal(businessId, gid) then
    return true, goal.progressDone or (goal.targetLabel or "Complete")
  end
  if gid == HOME_MECHANIC_GOAL_ID then
    local base = rtState.homeMechanicBaselinePwByBusiness[id]
    if base and base > 0 then
      return false, "Install upgrades or run the dyno to raise your car's power class"
    end
    return false, goal.progressLabel or "Install parts or dyno a team car to start"
  end
  if gid == RT_T2_G4_TUNING_GOAL_ID then
    if helpers.fleetHasVehicleNearSanctionedBracketTop(businessId, "modified_club_low") then
      return true, goal.progressDone or (goal.targetLabel or "Complete")
    end
  elseif gid == RT_T2_G6_TUNING_GOAL_ID then
    if helpers.fleetHasVehicleInSanctionedBracket(businessId, "modified_club_mid") then
      return true, goal.progressDone or (goal.targetLabel or "Complete")
    end
  elseif gid == RT_T3_G3_TUNING_GOAL_ID then
    local peak = helpers.maxFleetDynoPeakHp(businessId)
    if peak >= TIER3_DYNO_MIN_HP then
      return true, goal.progressDone or (goal.targetLabel or "Complete")
    end
    if peak > 0 then
      return false, string.format("Best dyno: %d hp — need %d hp", math.floor(peak), TIER3_DYNO_MIN_HP)
    end
  end
  return false, goal.progressLabel or "No upgrades detected"
end

local function evaluateStaminaRun(businessId, goal, readOnly)
  local target = tonumber(goal.targetLaps) or 5
  local streak = rtState.rtInternal.getStaminaStreak(businessId)
  local def = M.loadDefinition()
  local leagueId
  if readOnly then
    leagueId = rtState.currentLeagueByBusiness[tostring(normalizeBusinessId(businessId))] or "league1"
  else
    leagueId = rtState.rtInternal.getCurrentLeague(businessId)
  end
  local headId = helpers.getLeagueHeadGoalId(businessId, def, leagueId)
  if goal.id and headId ~= goal.id then
    return false, string.format("Short Track laps: %d/%d", streak, target)
  end
  if streak >= target then
    return true, goal.progressDone or (goal.targetLabel or "Complete")
  end
  return false, string.format("Short Track laps: %d/%d", streak, target)
end

local function evaluateRaceWins(businessId, goal)
  local target = tonumber(goal.targetWins) or 3
  local wins = rtState.rtInternal.getSanctionedOfficialFirstPlaceWins(businessId)
  if wins >= target then
    return true, goal.progressDone or (goal.targetLabel or "Complete")
  end
  return false, string.format("Wins: %d/%d", wins, target)
end

local function evaluateClassOptimization(businessId, goal)
  -- Resolve overlapping power classes the same way as race entry.
  local targetStr = "Tune a team car until it counts as Modified class or higher"
  local bestBranch = rtState.parts.fleet.getSanctionedBranchFilterForBusiness(businessId) or "stock"
  local branchRank = { stock = 1, modified = 2, super = 3, open = 4 }
  local r = branchRank[tostring(bestBranch)] or 1
  if r >= 2 then
    return true, goal.progressDone or (goal.targetLabel or "Complete"), targetStr
  end
  return false, "Your fastest team car is still in Stock class — add power or reduce weight", targetStr
end

-- Goal evaluator dispatch --------------------------------------------------------------------------

local function prepareDriverProgress(businessId)
  rtState.loadRacingTeamDrivers(businessId)
end

local function prepareFleetDiversityProgress(businessId, goal)
  local modifiedMinimum = tonumber(goal.fleetModifiedMin)
  local superMinimum = tonumber(goal.fleetSuperMin)
  if superMinimum and superMinimum > 0 and (not modifiedMinimum or modifiedMinimum <= 0) then return end
  if modifiedMinimum and superMinimum and modifiedMinimum > 0 and superMinimum > 0 then return end
  if tostring(goal.milestone or "") == "grid_presence" then prepareDriverProgress(businessId) end
end

local goalsWithoutVehicle = {
  placeholder = evaluatePlaceholder,
  tier_cap = evaluateTierCap,
  sanctioned_podium = evaluateSanctionedPodium,
  financial_milestone = evaluateFinancialMilestone,
  management_action = {evaluate = evaluateManagementAction, prepare = prepareDriverProgress},
  fleet_size = evaluateFleetSize,
  ai_race_results = {evaluate = evaluateAiRaceResults, prepare = prepareDriverProgress},
  race_participation = {evaluate = evaluateRaceParticipation, prepare = prepareDriverProgress},
  business_value = evaluateBusinessValue,
  ai_race_wins = {evaluate = evaluateAiRaceWins, prepare = prepareDriverProgress},
  cash_reserve = evaluateCashReserve,
}

local goalsWithVehicle = {
  vehicle_tier_up = evaluateVehicleTierUp,
  fleet_diversity = {evaluate = evaluateFleetDiversity, prepare = prepareFleetDiversityProgress},
  reliability_streak = {evaluate = evaluateReliabilityStreak, prepare = prepareDriverProgress},
  vehicle_and_leaderboard = evaluateVehicleAndLeaderboard,
  all_leaderboards = evaluateAllLeaderboards,
  tuning_milestone = evaluateTuningMilestone,
  stamina_run = evaluateStaminaRun,
  race_wins = evaluateRaceWins,
  class_optimization = evaluateClassOptimization,
}

function M.evaluateGoalProgress(businessId, goal, readOnly)
  local kind = goal.kind or "placeholder"
  local entry = goalsWithoutVehicle[kind]
  local evaluate = type(entry) == "table" and entry.evaluate or entry
  if evaluate then return evaluate(businessId, goal, readOnly) end

  -- Keep the vehicle gate before both vehicle goals and unknown kinds.
  if not helpers.hasBusinessVehicle(businessId) then
    return false, goal.progressNoVehicle or goal.progressLabel or "Purchase a team vehicle"
  end
  entry = goalsWithVehicle[kind]
  evaluate = type(entry) == "table" and entry.evaluate or entry
  if evaluate then return evaluate(businessId, goal, readOnly) end
  return false, goal.progressLabel or "Not Started"
end

-- Part/dyno notifications (called by businessComputer + businessPartCustomization) --------------
function M.notifyBusinessVehiclePartsPurchased(businessId, parts)
  local bid = normalizeBusinessId(businessId)
  if not bid or type(parts) ~= "table" then
    return
  end
  rtState.parts.helpers.getOfferState(bid)
  scheduleHomeMechanicPwRecheckAfterParts(bid)
end

local function ownsDynoVehicle(bid, vehicleId)
  local vehicles = overhaul_career_business_fleet.getBusinessVehicles(bid) or {}
  local ok = false
  for _, v in ipairs(vehicles) do
    if tostring(v.vehicleId) == tostring(vehicleId) then
      ok = true
      break
    end
  end
  if not ok then
    return false
  end
  return true
end

function M.notifyTeamVehicleDynoPeakHp(businessId, vehicleId, powerHp, weightKgOpt)
  local bid = normalizeBusinessId(businessId)
  if not bid or vehicleId == nil then
    return
  end
  local p = tonumber(powerHp)
  if not p or p <= 0 then
    return
  end
  local pb = overhaul_career_business_manager.getPurchasedBusinesses(rtState.businessType) or {}
  if not pb[bid] and not pb[tostring(bid)] then
    return
  end
  if not ownsDynoVehicle(bid, vehicleId) then return end
  rtState.parts.helpers.getOfferState(bid)
  local id = tostring(bid)
  rtState.classOptimizationPeakHpByBusiness[id] = rtState.classOptimizationPeakHpByBusiness[id] or {}
  local vidStr = tostring(vehicleId)
  local cur = rtState.classOptimizationPeakHpByBusiness[id][vidStr]
  local curHp, curW = nil, nil
  if type(cur) == "table" then
    curHp = tonumber(cur.hp)
    curW = tonumber(cur.weightKg)
  else
    curHp = tonumber(cur)
  end
  local wIn = tonumber(weightKgOpt)
  local newW = wIn
  if (not newW or newW <= 0) and curW and curW > 0 then
    newW = curW
  end
  local newEntry
  if newW and newW > 0 then
    newEntry = { hp = p, weightKg = newW }
  else
    newEntry = p
  end
  local hpChanged = (curHp == nil or math.abs(p - curHp) > 0.05)
  local wChanged = false
  if newW and newW > 0 then
    wChanged = (curW == nil or math.abs(newW - curW) > 0.5)
  end
  if hpChanged or wChanged then
    rtState.classOptimizationPeakHpByBusiness[id][vidStr] = newEntry
    local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
    if savePath then
      rtState.parts.persist.saveRacingTeamPersistedState(bid, savePath)
    end
    racingTeamRaceOffers.bumpRefresh(bid)
    rtState.rtInternal.advanceRacingTeamGoalsIfReady(bid)
    maybeCompleteHomeMechanicFromFleetPw(bid)
  end
end

function M.prepareGoalProgress(businessId, goal)
  local kind = goal.kind or "placeholder"
  local entry = goalsWithoutVehicle[kind]
  if not entry then
    entry = goalsWithVehicle[kind]
    if type(entry) ~= "table" or not entry.prepare or not helpers.hasBusinessVehicle(businessId) then return end
  end
  if type(entry) == "table" and entry.prepare then entry.prepare(businessId, goal) end
end

-- Parts -------------------------------------------------------------------------------------------

require("overhaul/career/business/racingTeam/racingTeam/goals/completion").new({
  M = M, helpers = helpers, rtState = rtState, normalizeBusinessId = normalizeBusinessId,
})

return M
