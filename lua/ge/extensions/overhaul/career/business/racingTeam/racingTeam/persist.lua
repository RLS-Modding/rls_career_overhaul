-- Racing team save file: restore and write team state, offers, cooldowns, sponsors, milestones and leaderboard times.
-- Read map: save path, offer counter, restore by section, save fields by section, the no-op save, part.new.
local businessSaveState = require("overhaul/lib/business/saveState")
local part = {}

-- Save path and offer counter ---------------------------------------------------------------------

local function getRacingTeamSavePath(businessId, currentSavePath)
  if not currentSavePath or not businessId then
    return nil
  end
  return businessSaveState.businessFilePath(businessId, "racingTeam.json", currentSavePath .. "")
end

-- Job ids are never reused, so the counter starts above every id still in the offer state.
local function bumpOfferJobCounterFromState(rtState, businessIdStr, state)
  local maxId = rtState.offerJobIdCounters[businessIdStr] or 0
  local function considerJob(job)
    if job and job.jobId ~= nil then
      local n = tonumber(job.jobId)
      if n and n > maxId then
        maxId = n
      end
    end
  end
  for _, job in ipairs(state.new or {}) do
    considerJob(job)
  end
  for _, job in ipairs(state.active or {}) do
    considerJob(job)
  end
  rtState.offerJobIdCounters[businessIdStr] = maxId
end

-- Restore sections --------------------------------------------------------------------------------


-- Restores one cooldown record when it still has a sim or wall deadline in the future or unset.
local function restoreCooldownRecord(rec)
  local untilSim = tonumber(rec.untilSim)
  local wallEpoch = tonumber(rec.wallEpoch)
  if (untilSim and untilSim > 0) or (wallEpoch and wallEpoch > 0) then
    return { untilSim = untilSim, wallEpoch = wallEpoch }
  end
  return nil
end

local function restoreVehicleCooldowns(rtState, id, data)
  rtState.vehicleCooldownByBusiness[id] = {}
  if data.vehicleCooldowns and type(data.vehicleCooldowns) == "table" then
    for vidKey, rec in pairs(data.vehicleCooldowns) do
      if type(rec) == "table" then
        rtState.vehicleCooldownByBusiness[id][tostring(vidKey)] = restoreCooldownRecord(rec)
      end
    end
  end
end

local function restorePlayerCooldown(rtState, id, data)
  rtState.playerCooldownByBusiness[id] = nil
  if data.playerCooldown and type(data.playerCooldown) == "table" then
    rtState.playerCooldownByBusiness[id] = restoreCooldownRecord(data.playerCooldown)
  end
end

local function restoreSponsors(rtState, id, data)
  if data.racingTeamSponsors and type(data.racingTeamSponsors) == "table" then
    rtState.rtInternal.sponsors[id] = {
      available = type(data.racingTeamSponsors.available) == "table" and data.racingTeamSponsors.available or {},
      active = type(data.racingTeamSponsors.active) == "table" and data.racingTeamSponsors.active or {},
      nextOfferAt = tonumber(data.racingTeamSponsors.nextOfferAt) or 0,
    }
  else
    rtState.rtInternal.sponsors[id] = {
      available = {},
      active = {},
      nextOfferAt = 0,
    }
  end
end

-- Keeps only the rows that name a race type and label.
local function cleanBaselineRows(arr)
  local clean = {}
  for _, row in ipairs(arr) do
    if type(row) == "table" and row.raceType and row.raceLabel then
      table.insert(clean, {
        raceType = row.raceType,
        raceLabel = row.raceLabel,
        baselineSec = tonumber(row.baselineSec),
      })
    end
  end
  return clean
end

local function restoreLeaderboardBaselines(rtState, id, data)
  rtState.allLeaderboardsBaselineByBusiness[id] = rtState.allLeaderboardsBaselineByBusiness[id] or {}
  if data.allLeaderboardsBaselines and type(data.allLeaderboardsBaselines) == "table" then
    for gid, arr in pairs(data.allLeaderboardsBaselines) do
      if type(gid) == "string" and type(arr) == "table" then
        rtState.allLeaderboardsBaselineByBusiness[id][gid] = cleanBaselineRows(arr)
      end
    end
  end
end

local function restoreCompletedGoalTimes(rtState, id, data)
  rtState.completedGoalLeaderboardTimesByBusiness[id] = {}
  if data.completedGoalLeaderboardTimes and type(data.completedGoalLeaderboardTimes) == "table" then
    for gid, snap in pairs(data.completedGoalLeaderboardTimes) do
      if type(gid) == "string" and type(snap) == "table" then
        if snap.kind == "single" then
          rtState.completedGoalLeaderboardTimesByBusiness[id][gid] = {
            kind = "single",
            bestSec = tonumber(snap.bestSec),
          }
        elseif snap.kind == "tracks" and type(snap.tracks) == "table" then
          local rows = {}
          for _, row in ipairs(snap.tracks) do
            if type(row) == "table" and row.raceType and row.raceLabel then
              table.insert(rows, {
                raceType = row.raceType,
                raceLabel = row.raceLabel,
                bestSec = tonumber(row.bestSec),
              })
            end
          end
          rtState.completedGoalLeaderboardTimesByBusiness[id][gid] = { kind = "tracks", tracks = rows }
        end
      end
    end
  end
end

local function restoreRacingTeamCooldownsSponsorsAndTimes(rtState, id, data)
  restoreVehicleCooldowns(rtState, id, data)
  restorePlayerCooldown(rtState, id, data)
  restoreSponsors(rtState, id, data)
  restoreLeaderboardBaselines(rtState, id, data)
  restoreCompletedGoalTimes(rtState, id, data)
end

local function restoreRaceOfferBoard(rtState, id, data)
  if data.raceOfferBoard and type(data.raceOfferBoard) == "table" then
    local rb = data.raceOfferBoard
    local offers = {}
    if type(rb.offers) == "table" then
      for _, offer in ipairs(rb.offers) do
        table.insert(offers, offer)
      end
    end
    rtState.raceOfferBoardByBusiness[id] = {
      levelId = type(rb.levelId) == "string" and rb.levelId or "",
      nextRefreshAt = tonumber(rb.nextRefreshAt) or 0,
      offers = offers,
    }
  end
end

local function restoreOfferJobCounter(rtState, id, state, data)
  local savedCounter = tonumber(data.offerJobIdCounter)
  if savedCounter then
    rtState.offerJobIdCounters[id] = math.max(rtState.offerJobIdCounters[id] or 0, savedCounter)
  end
  bumpOfferJobCounterFromState(rtState, id, state)
end

local function restorePendingRematch(rtState, id, data)
  if data.pendingRematchOffer and type(data.pendingRematchOffer) == "table" then
    rtState.pendingRematchOfferByBusiness[id] = data.pendingRematchOffer
  else
    rtState.pendingRematchOfferByBusiness[id] = nil
  end
end

local function restoreGoalCompletion(rtState, id, data)
  rtState.goalCompletionByBusiness[id] = rtState.goalCompletionByBusiness[id] or {}
  if data.completedGoalIds and type(data.completedGoalIds) == "table" then
    for _, gid in ipairs(data.completedGoalIds) do
      if type(gid) == "string" then
        rtState.goalCompletionByBusiness[id][gid] = true
      end
    end
  end
  if type(data.currentLeague) == "string" and data.currentLeague ~= "" then
    rtState.currentLeagueByBusiness[id] = data.currentLeague
  else
    rtState.currentLeagueByBusiness[id] = "league1"
  end
end

-- The first tuning milestone is also set from its older flag when the list is missing.
local function restoreTuningMilestones(rtState, id, data)
  rtState.tuningMilestoneByGoalByBusiness[id] = rtState.tuningMilestoneByGoalByBusiness[id] or {}
  local tmg = rtState.tuningMilestoneByGoalByBusiness[id]
  if data.tuningMilestonesCompleted and type(data.tuningMilestonesCompleted) == "table" then
    for _, gid in ipairs(data.tuningMilestonesCompleted) do
      if type(gid) == "string" then
        tmg[gid] = true
      end
    end
  end
  if data.tuningMilestoneAchieved == true and next(tmg) == nil then
    tmg["rt_t1_g3"] = true
  end
  rtState.tuningMilestoneByBusiness[id] = next(tmg) ~= nil
end

-- Peak horsepower is kept as a plain number, or as hp and weight when the dyno recorded weight.
local function restorePeakHpEntry(v)
  local hp = tonumber(v.hp)
  local wkg = tonumber(v.weightKg)
  if wkg and wkg > 0 then
    if hp and hp > 0 then
      return { hp = hp, weightKg = wkg }
    end
    return { weightKg = wkg }
  elseif hp and hp > 0 then
    return hp
  end
  return nil
end

local function restoreClassOptimizationPeakHp(rtState, id, data)
  rtState.classOptimizationPeakHpByBusiness[id] = {}
  if data.classOptimizationPeakHp and type(data.classOptimizationPeakHp) == "table" then
    for k, v in pairs(data.classOptimizationPeakHp) do
      local keyStr = tostring(k)
      if type(v) == "table" then
        rtState.classOptimizationPeakHpByBusiness[id][keyStr] = restorePeakHpEntry(v)
      else
        local hp = tonumber(v)
        if hp and hp > 0 then
          rtState.classOptimizationPeakHpByBusiness[id][keyStr] = hp
        end
      end
    end
  end
end

-- League 2 invites keep their old save names so existing saves still load.
local function restoreLeagueInvite(rtState, id, data)
  local l2Offered = tonumber(data.league2InviteOfferedAt) or tonumber(data.wcaraInviteOfferedAt)
  local l2Declined = (data.league2InviteDeclined == true) or (data.wcaraInviteDeclined == true)
  local invTarget = data.league2InviteTargetLeague
  if type(invTarget) ~= "string" or (invTarget ~= "league2" and invTarget ~= "league3" and invTarget ~= "league4") then
    invTarget = nil
  end
  if invTarget == nil and l2Offered then
    invTarget = "league2"
  end
  rtState.league2InviteByBusiness[id] = {
    offeredAt = l2Offered,
    declined = l2Declined,
    targetLeague = invTarget,
  }
  local promoUi = data.league2InvitePromoUi or data.wcaraPromoUiState
  if type(promoUi) == "string" and (promoUi == "splash" or promoUi == "jobs") then
    rtState.league2InvitePromoUiByBusiness[id] = promoUi
  elseif l2Offered then
    rtState.league2InvitePromoUiByBusiness[id] = "splash"
  else
    rtState.league2InvitePromoUiByBusiness[id] = nil
  end
end

local function restoreSplashFlags(rtState, id, data)
  rtState.purchaseMilestoneSplashShownByBusiness[id] = data.purchaseMilestoneSplashShown == true
  rtState.raceUnlockSplashPendingByBusiness[id] = data.raceUnlockSplashPending == true
  rtState.raceUnlockSplashShownByBusiness[id] = data.raceUnlockSplashShown == true
  rtState.careerFinaleSplashPendingByBusiness[id] = data.careerFinaleSplashPending == true
  rtState.careerFinaleSplashShownByBusiness[id] = data.careerFinaleSplashShown == true
end

local function restoreTeamScalars(rtState, id, data)
  rtState.homeMechanicBaselinePwByBusiness[id] = tonumber(data.homeMechanicBaselinePw)
  rtState.businessSkillXpByBusiness[id] = math.max(0, math.floor(tonumber(data.businessSkillXp) or 0))
  if data.shortTrackCleanStreak ~= nil then
    rtState.staminaShortTrackStreakByBusiness[id] = math.max(0, math.floor(tonumber(data.shortTrackCleanStreak) or 0))
  end
  rtState.sanctionedOfficialFirstPlaceWinsByBusiness[id] =
    math.max(0, math.floor(tonumber(data.sanctionedOfficialFirstPlaceWins) or 0))
end

-- The saved file is read here and sections restore in order; a missing section keeps its default.
local function restoreTeamData(rtState, parts, id, state, data)
  state.new = {}
  if data.active and type(data.active) == "table" then
    state.active = data.active
  end
  restoreRaceOfferBoard(rtState, id, data)
  restoreOfferJobCounter(rtState, id, state, data)
  local proxyFlow = parts.helpers.raceFlowMod()
  if proxyFlow and proxyFlow.loadPersistedProxyDriverRaceRequest then
    proxyFlow.loadPersistedProxyDriverRaceRequest(id, data.proxyDriverRaceRequest)
  end
  restorePendingRematch(rtState, id, data)
  restoreGoalCompletion(rtState, id, data)
  restoreTuningMilestones(rtState, id, data)
  restoreTeamScalars(rtState, id, data)
  restoreClassOptimizationPeakHp(rtState, id, data)
  restoreLeagueInvite(rtState, id, data)
  restoreSplashFlags(rtState, id, data)
  restoreRacingTeamCooldownsSponsorsAndTimes(rtState, id, data)
end

local function loadRacingTeamPersistedState(rtState, parts, businessId, state)
  local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
  if not savePath then
    return
  end
  local bid = parts.helpers.normalizeBusinessId(businessId)
  local id = tostring(bid)
  local filePath = getRacingTeamSavePath(bid, savePath)
  if not filePath then
    return
  end
  if not FS:fileExists(filePath) then
    return
  end
  local data = jsonReadFile(filePath)
  if not data or type(data) ~= "table" then
    return
  end
  restoreTeamData(rtState, parts, id, state, data)
end

-- Save sections -----------------------------------------------------------------------------------

local function completedGoalIdList(rtState, id)
  local completedList = {}
  local gMap = rtState.goalCompletionByBusiness[id] or {}
  for gid, done in pairs(gMap) do
    if done then
      table.insert(completedList, gid)
    end
  end
  return completedList
end

local function tuningMilestoneAchievedForSave(rtState, id)
  local m = rtState.tuningMilestoneByGoalByBusiness[id] or {}
  return m["rt_t1_g3"] == true
end

local function tuningMilestonesCompletedForSave(rtState, id)
  local m = rtState.tuningMilestoneByGoalByBusiness[id] or {}
  local out = {}
  for gid, v in pairs(m) do
    if v and type(gid) == "string" then
      table.insert(out, gid)
    end
  end
  table.sort(out)
  return out
end

local function proxyDriverRaceRequestForSave(parts, id)
  local proxyFlow = parts.helpers.raceFlowMod()
  if proxyFlow and proxyFlow.getPersistedProxyDriverRaceRequestForSave then
    return proxyFlow.getPersistedProxyDriverRaceRequestForSave(id)
  end
  return nil
end

local function raceOfferBoardForSave(rb)
  return rb and {
    levelId = rb.levelId or "",
    nextRefreshAt = tonumber(rb.nextRefreshAt) or 0,
    offers = rb.offers or {},
  } or nil
end

-- Vehicle cooldowns still running on the wall clock are saved; expired ones are dropped.
local function vehicleCooldownsForSave(rtState, id)
  local out = {}
  local now = os.time()
  for vidKey, rec in pairs(rtState.vehicleCooldownByBusiness[id] or {}) do
    if type(rec) == "table" and ((tonumber(rec.wallEpoch) or 0) > now) then
      out[tostring(vidKey)] = { untilSim = rec.untilSim, wallEpoch = rec.wallEpoch }
    end
  end
  return out
end

local function playerCooldownForSave(rtState, id)
  local rec = rtState.playerCooldownByBusiness[id]
  if type(rec) ~= "table" then
    return nil
  end
  if (tonumber(rec.wallEpoch) or 0) <= os.time() then
    return nil
  end
  return { untilSim = rec.untilSim, wallEpoch = rec.wallEpoch }
end

local function leaderboardBaselinesForSave(rtState, id)
  local out = {}
  for gid, arr in pairs(rtState.allLeaderboardsBaselineByBusiness[id] or {}) do
    if type(arr) == "table" and #arr > 0 then
      local rows = {}
      for _, e in ipairs(arr) do
        table.insert(rows, {
          raceType = e.raceType,
          raceLabel = e.raceLabel,
          baselineSec = e.baselineSec,
        })
      end
      out[gid] = rows
    end
  end
  return out
end

local function completedGoalTimesForSave(rtState, id)
  local out = {}
  for gid, snap in pairs(rtState.completedGoalLeaderboardTimesByBusiness[id] or {}) do
    if type(snap) == "table" and snap.kind == "single" then
      out[gid] = { kind = "single", bestSec = snap.bestSec }
    elseif type(snap) == "table" and snap.kind == "tracks" and type(snap.tracks) == "table" and #snap.tracks > 0 then
      local rows = {}
      for _, e in ipairs(snap.tracks) do
        table.insert(rows, {
          raceType = e.raceType,
          raceLabel = e.raceLabel,
          bestSec = e.bestSec,
        })
      end
      out[gid] = { kind = "tracks", tracks = rows }
    end
  end
  return out
end

local function writeRacingTeamPersistedState(rtState, parts, businessId, currentSavePath, writer)
  if not businessId or not currentSavePath then
    return
  end
  local bid = parts.helpers.normalizeBusinessId(businessId)
  local id = tostring(bid)
  local state = rtState.offerStateByBusiness[id]
  if not state then
    return
  end
  rtState.tuningMilestoneByGoalByBusiness[id] = rtState.tuningMilestoneByGoalByBusiness[id] or {}
  local filePath = getRacingTeamSavePath(bid, currentSavePath)
  if not filePath then
    return
  end
  local dirPath = string.match(filePath, "^(.*)/[^/]+$")
  if dirPath and not writer.exists(dirPath) then
    writer.mkdir(dirPath)
  end
  local completedList = completedGoalIdList(rtState, id)
  local data = {
    completedGoalIds = completedList,
    currentLeague = rtState.currentLeagueByBusiness[id] or "league1",
    tuningMilestoneAchieved = tuningMilestoneAchievedForSave(rtState, id),
    tuningMilestonesCompleted = tuningMilestonesCompletedForSave(rtState, id),
    homeMechanicBaselinePw = rtState.homeMechanicBaselinePwByBusiness[id],
    offerJobIdCounter = rtState.offerJobIdCounters[id] or 0,
    new = state.new or {},
    active = state.active or {},
    raceOfferBoard = raceOfferBoardForSave(rtState.raceOfferBoardByBusiness[id]),
    proxyDriverRaceRequest = proxyDriverRaceRequestForSave(parts, id),
    pendingRematchOffer = rtState.pendingRematchOfferByBusiness[id],
    businessSkillXp = math.max(0, math.floor(tonumber(rtState.businessSkillXpByBusiness[id]) or 0)),
    shortTrackCleanStreak = rtState.staminaShortTrackStreakByBusiness[id] or 0,
    sanctionedOfficialFirstPlaceWins = rtState.sanctionedOfficialFirstPlaceWinsByBusiness[id] or 0,
    classOptimizationPeakHp = rtState.classOptimizationPeakHpByBusiness[id] or {},
    league2InviteOfferedAt = (rtState.league2InviteByBusiness[id] or {}).offeredAt,
    league2InviteDeclined = (rtState.league2InviteByBusiness[id] or {}).declined == true,
    league2InviteTargetLeague = (rtState.league2InviteByBusiness[id] or {}).targetLeague,
    racingTeamSponsors = rtState.rtInternal.sponsors[id],
    league2InvitePromoUi = rtState.league2InvitePromoUiByBusiness[id],
    purchaseMilestoneSplashShown = rtState.purchaseMilestoneSplashShownByBusiness[id] == true,
    raceUnlockSplashPending = rtState.raceUnlockSplashPendingByBusiness[id] == true,
    raceUnlockSplashShown = rtState.raceUnlockSplashShownByBusiness[id] == true,
    careerFinaleSplashPending = rtState.careerFinaleSplashPendingByBusiness[id] == true,
    careerFinaleSplashShown = rtState.careerFinaleSplashShownByBusiness[id] == true,
    vehicleCooldowns = vehicleCooldownsForSave(rtState, id),
    playerCooldown = playerCooldownForSave(rtState, id),
    allLeaderboardsBaselines = leaderboardBaselinesForSave(rtState, id),
    completedGoalLeaderboardTimes = completedGoalTimesForSave(rtState, id),
  }
  overhaul_career_saveSystem.jsonWriteFileSafe(filePath, data, true)
end

-- The save file is written by writeRacingTeamPersistedState when the team saves, so this has nothing to do here.
local function saveRacingTeamPersistedState(businessId, currentSavePath)
end

-- Public API: instance construction ---------------------------------------------------------------

function part.new(inputs)
  local parts = inputs.parts
  local rtState = inputs.rtState
  return {
    loadRacingTeamPersistedState = function(businessId, state)
      return loadRacingTeamPersistedState(rtState, parts, businessId, state)
    end,
    saveRacingTeamPersistedState = saveRacingTeamPersistedState,
    writeRacingTeamPersistedState = function(businessId, currentSavePath, writer)
      return writeRacingTeamPersistedState(rtState, parts, businessId, currentSavePath, writer)
    end,
  }
end

return part
