-- Racing team goals: goal completion, stamina laps, sanctioned podiums and league advancement.
-- Read completion snapshots, race notifications and explicit advancement.
local part = {}
local capabilities = require('overhaul/lib/platform/capabilities')

function part.new(inputs)
  local helpers = inputs.helpers
  local M = inputs.M
  local rtState = inputs.rtState
  local normalizeBusinessId = inputs.normalizeBusinessId

  -- Goal completion -------------------------------------------------------------------------------
  function M.markGoalCompleted(businessId, goalId)
    local id = tostring(normalizeBusinessId(businessId))
    rtState.goalCompletionByBusiness[id] = rtState.goalCompletionByBusiness[id] or {}
    if rtState.goalCompletionByBusiness[id][goalId] == true then
      return
    end
    rtState.goalCompletionByBusiness[id][goalId] = true
    local dl = rtState.rtInternal.devLog
    dl.append(businessId, "info", "Goal completed: " .. tostring(goalId), "goals")
    helpers.snapshotCompletedGoalLeaderboardTimesAtCompletion(businessId, goalId)
    rtState.rtInternal.recordBaselinesAfterCompletedPrerequisite(businessId, goalId)
    local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
    if savePath then
      rtState.parts.persist.saveRacingTeamPersistedState(businessId, savePath)
    end
    rtState.parts.results.syncRacingTeamDriverUnlock(businessId)
    if goalId == rtState.K.GOAL_UNLOCK_SANCTIONED_RACE_OFFERS then
      local board = rtState.parts.raceOffers.getBoard(businessId)
      board.nextRefreshAt = 0
      rtState.raceUnlockSplashPendingByBusiness[id] = true
      rtState.raceUnlockSplashShownByBusiness[id] = false
    end
    rtState.rtInternal.refreshLeague2InviteOffer(businessId)
    if rtState.rtInternal.allGoalsCompleteForLeague(businessId, "league4")
        and rtState.careerFinaleSplashShownByBusiness[id] ~= true then
      rtState.careerFinaleSplashPendingByBusiness[id] = true
      rtState.careerFinaleSplashPendingByBusiness[id] = false
      rtState.rtInternal.scheduleCareerFinaleSplash(businessId)
    end
    rtState.rtInternal.notifyBusinessComputerRacingTeamGoalProgress(businessId, goalId)
    helpers.resetStaminaStreakIfStaminaGoalIsHead(businessId)
  end

  -- Short Track stamina lap handler ---------------------------------------------------------------
  local function resolveStaminaBusiness(payload)
    if type(payload) ~= "table" then
      log("I", "racingTeam", "stamina_lap skip payload_not_table")
      return
    end
    local pv = payload.playerVehicleId
    log("I", "racingTeam", string.format(
      "stamina_lap enter raceLabel=%s isAltRoute=%s invalidLap=%s dmgFactor=%s dmgPct=%s pv=%s",
      tostring(payload.raceLabel),
      tostring(payload.isAltRoute),
      tostring(payload.invalidLap),
      tostring(payload.damageFactor),
      tostring(payload.damagePercentage),
      tostring(pv)
    ))
    if not pv then
      log("I", "racingTeam", "stamina_lap skip no_playerVehicleId")
      return
    end
    local businessId, fleetVehicleId = capabilities.get('businessVehicles').getBusinessVehicleFromSpawnedId(pv)
    if not businessId or fleetVehicleId == nil then
      log("I", "racingTeam", string.format(
        "stamina_lap skip not_team_spawn pv=%s businessId=%s fleetVehicleId=%s",
        tostring(pv), tostring(businessId), tostring(fleetVehicleId)
      ))
      return
    end
    local pb = overhaul_career_business_manager.getPurchasedBusinesses(rtState.businessType) or {}
    local nb = normalizeBusinessId(businessId)
    if not pb[nb] and not pb[tostring(nb)] then
      log("I", "racingTeam", string.format(
        "stamina_lap skip business_not_purchased businessId=%s normalized=%s",
        tostring(businessId), tostring(nb)
      ))
      return
    end
    rtState.parts.helpers.getOfferState(businessId)
    local raceLabel = tostring(payload.raceLabel or "")
    if not string.find(raceLabel, "Short Track", 1, true) then
      log("I", "racingTeam", string.format(
        "stamina_lap skip raceLabel_no_Short_Track_substring got=%s businessId=%s",
        raceLabel, tostring(businessId)
      ))
      return
    end
    return businessId, raceLabel
  end

  local function findActiveStaminaGoal(businessId)
    local def = M.loadDefinition()
    local leagueId = rtState.rtInternal.getCurrentLeague(businessId)
    local staminaGoalId, targetLaps = nil, 5
    if def and type(def.goals) == "table" then
      for _, candidateGoal in ipairs(def.goals) do
        if candidateGoal and candidateGoal.kind == "stamina_run" and M.resolvedLeague(candidateGoal) == leagueId then
          staminaGoalId = candidateGoal.id
          targetLaps = tonumber(candidateGoal.targetLaps) or 5
          break
        end
      end
    end
    if not staminaGoalId or M.idCompleted(businessId, staminaGoalId) then
      log("I", "racingTeam", string.format(
        "stamina_lap skip no_stamina_goal_or_done businessId=%s league=%s staminaGoalId=%s goalDone=%s",
        tostring(businessId),
        tostring(leagueId),
        tostring(staminaGoalId),
        tostring(staminaGoalId and M.idCompleted(businessId, staminaGoalId))
      ))
      return
    end
    local headId = helpers.getLeagueHeadGoalId(businessId, def, leagueId)
    if headId ~= staminaGoalId then
      log("I", "racingTeam", string.format(
        "stamina_lap skip not_active_goal businessId=%s headId=%s staminaGoalId=%s",
        tostring(businessId), tostring(headId), tostring(staminaGoalId)
      ))
      return
    end
    return staminaGoalId, targetLaps
  end

  local function recordStaminaLap(businessId, raceLabel, staminaGoalId, targetLaps, payload)
    local prev = rtState.rtInternal.getStaminaStreak(businessId)
    if prev >= targetLaps then
      log("W", "racingTeam", string.format(
        "stamina_lap streak already at/above target before lap; attempting goal complete businessId=%s prev=%s targetLaps=%s goalId=%s",
        tostring(businessId), tostring(prev), tostring(targetLaps), tostring(staminaGoalId)
      ))
      if staminaGoalId and not M.idCompleted(businessId, staminaGoalId) then
        M.markGoalCompleted(businessId, staminaGoalId)
      end
      if not M.idCompleted(businessId, staminaGoalId) then
        rtState.rtInternal.setStaminaStreak(businessId, 0)
      end
      prev = rtState.rtInternal.getStaminaStreak(businessId)
    end
    local invalid = payload.invalidLap == true
    local dmgFactor = tonumber(payload.damageFactor) or 0
    local dmgPct = tonumber(payload.damagePercentage) or 0
    local critical = dmgFactor > 0 and dmgPct >= 0.22
    if invalid or critical then
      rtState.rtInternal.setStaminaStreak(businessId, 0)
      local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
      if savePath then
        rtState.parts.persist.saveRacingTeamPersistedState(businessId, savePath)
      end
      log("I", "racingTeam", string.format(
        "stamina lap reset business=%s invalid=%s criticalDmg=%s",
        tostring(businessId), tostring(invalid), tostring(critical)
      ))
      return
    end
    local nextStreak = prev + 1
    rtState.rtInternal.setStaminaStreak(businessId, nextStreak)
    local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
    if savePath then
      rtState.parts.persist.saveRacingTeamPersistedState(businessId, savePath)
    end
    if nextStreak >= targetLaps then
      M.markGoalCompleted(businessId, staminaGoalId)
    end
    log("I", "racingTeam", string.format(
      "stamina lap business=%s streak=%d/%d label=%s",
      tostring(businessId), nextStreak, targetLaps, raceLabel
    ))
  end

  function M.notifyShortTrackStaminaLap(payload)
    local businessId, raceLabel = resolveStaminaBusiness(payload)
    if not businessId then return end
    local staminaGoalId, targetLaps = findActiveStaminaGoal(businessId)
    if not staminaGoalId then return end
    recordStaminaLap(businessId, raceLabel, staminaGoalId, targetLaps, payload)
  end

  -- Official sanctioned podium handler ------------------------------------------------------------
  local function findSanctionedPodiumGoal(allGoals, leagueId)
    local targetId = nil
    if type(allGoals) == "table" then
      for _, goal in ipairs(allGoals) do
        if goal.id and (goal.kind or "") == "sanctioned_podium" and M.resolvedLeague(goal) == leagueId then
          targetId = goal.id
          break
        end
      end
    end
    if not targetId then
      targetId = rtState.K.GOAL_MAKE_YOUR_MARK
    end
    return targetId
  end

  local function recordSanctionedPodium(businessId, p, offer, allGoals)
    rtState.parts.helpers.getOfferState(businessId)
    local makeYourMarkDoneBefore = M.idCompleted(businessId, rtState.K.GOAL_MAKE_YOUR_MARK)
    local leagueId = rtState.rtInternal.getCurrentLeague(businessId)
    local targetId = findSanctionedPodiumGoal(allGoals, leagueId)
    local offerIsTeamBoard = type(offer) == "table" and offer.racingTeamBusinessOffer == true and offer.businessId ~= nil
    local goalKindForTarget = nil
    if type(allGoals) == "table" then
      for _, candidateGoal in ipairs(allGoals) do
        if candidateGoal and candidateGoal.id == targetId then
          goalKindForTarget = candidateGoal.kind
          break
        end
      end
    end
    local podiumTeamBoardOnly = (goalKindForTarget == "sanctioned_podium")
        or (goalKindForTarget == nil and targetId == rtState.K.GOAL_MAKE_YOUR_MARK)
    local skipMark = podiumTeamBoardOnly and not offerIsTeamBoard
    if not skipMark and not M.idCompleted(businessId, targetId) then
      M.markGoalCompleted(businessId, targetId)
    end
    local matches = helpers.racingTeamOfferMatchesBusiness(businessId, offer)
    local l1pr = type(offer) == "table" and offer.league1PlayerRace == true
    log("I", "racingTeam", string.format(
      "notifyOfficialSanctionedPodium bid=%s p=%s makeYourMarkDoneBefore=%s matches=%s league1PlayerRace=%s teamOffer=%s offerBid=%s",
      tostring(businessId),
      tostring(p),
      tostring(makeYourMarkDoneBefore),
      tostring(matches),
      tostring(l1pr),
      tostring(type(offer) == "table" and offer.racingTeamBusinessOffer == true),
      tostring(type(offer) == "table" and offer.businessId)
    ))
    if p == 1 and makeYourMarkDoneBefore and matches and l1pr then
      local idStr = tostring(normalizeBusinessId(businessId))
      local before = rtState.sanctionedOfficialFirstPlaceWinsByBusiness[idStr] or 0
      rtState.sanctionedOfficialFirstPlaceWinsByBusiness[idStr] = before + 1
      log("I", "racingTeam", string.format(
        "notifyOfficialSanctionedPodium INCREMENT bid=%s %d -> %d",
        idStr, before, before + 1
      ))
      local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
      if savePath then
        rtState.parts.persist.saveRacingTeamPersistedState(businessId, savePath)
      end
    end
  end

  function M.notifyOfficialSanctionedPodium(place, offer)
    local p = tonumber(place)
    if not p or p < 1 or p > 3 then
      return
    end
    if not overhaul_career_career or not overhaul_career_career.isActive() then
      return
    end
    if not overhaul_events_fre_state or not overhaul_events_fre_state.isCareerActive
        or not overhaul_events_fre_state.isCareerActive() then
      return
    end
    local def = M.loadDefinition()
    local allGoals = def and def.goals
    local purchased = overhaul_career_business_manager.getPurchasedBusinesses(rtState.businessType) or {}
    local businessList = {}
    if type(offer) == "table" and offer.racingTeamBusinessOffer == true and offer.businessId ~= nil then
      local bid = normalizeBusinessId(offer.businessId)
      if helpers.isPurchasedRacingTeamBusiness(purchased, bid) then
        businessList[1] = bid
      else
        return
      end
    else
      for businessId, _ in pairs(purchased) do
        table.insert(businessList, businessId)
      end
    end
    for _, businessId in ipairs(businessList) do
      recordSanctionedPodium(businessId, p, offer, allGoals)
    end
  end

  -- League advancement helpers (cross-module via rtInternal) -------------------------------------
  function rtState.rtInternal.advanceRacingTeamGoalsIfReady(businessId)
    rtState.parts.helpers.getOfferState(businessId)
    local def = M.loadDefinition()
    local leagueId = rtState.rtInternal.getCurrentLeague(businessId)
    local leagueGoals = M.getSortedForLeague(def, leagueId)
    local safety = 0
    local advancedAnyGoal = false
    while safety < 32 do
      safety = safety + 1
      local current = nil
      for _, goal in ipairs(leagueGoals) do
        if goal.id and not M.idCompleted(businessId, goal.id) then
          current = goal
          break
        end
      end
      if not current then
        break
      end
      local done = select(1, M.evaluateGoalProgress(businessId, current))
      if done then
        M.markGoalCompleted(businessId, current.id)
        advancedAnyGoal = true
      else
        break
      end
    end
    if advancedAnyGoal then
      overhaul_career_saveSystem.saveCurrent()
    end
  end

  function rtState.rtInternal.allGoalsCompleteForLeague(businessId, leagueId)
    local def = M.loadDefinition()
    if not def or type(def.goals) ~= "table" then
      return false
    end
    local sawAny = false
    for _, goal in ipairs(def.goals) do
      if goal and goal.id and M.resolvedLeague(goal) == leagueId then
        sawAny = true
        if not M.idCompleted(businessId, goal.id) then
          return false
        end
      end
    end
    return sawAny
  end

  function rtState.rtInternal.allTierOneGoalsComplete(businessId)
    return rtState.rtInternal.allGoalsCompleteForLeague(businessId, "league1")
  end

end

return part
