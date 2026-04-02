-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

M.dependencies = {'gameplay_events_freContracts'}

local processRoad, leaderboardManager, checkpointManager
local raceSession
local utils, pits, aiRacers, circuitRaceAi, competitiveTrackFlow
local Assets
local trackFlowState, TRACK_RACE_ID

local loadedExtensions = {}

local session

local function notifyFreContractsFreeroamUi()
  if gameplay_events_freContracts_ui and gameplay_events_freContracts_ui.emitUiStateUpdate then
    gameplay_events_freContracts_ui.emitUiStateUpdate("freeroam_session")
  end
end

local function getVehicleSpeedMph(vehId)
  local speedUnit = (session and session.speedUnit) or 2.2369362921
  if not vehId or not be or not be.getObjectVelocityXYZ then
    return 0
  end
  local a, b, c = be:getObjectVelocityXYZ(vehId)
  if type(a) == "number" and type(b) == "number" and type(c) == "number" then
    return math.sqrt(a * a + b * b + c * c) * speedUnit
  end
  if type(a) == "number" then
    return math.abs(a) * speedUnit
  end
  if a ~= nil and type(a.length) == "function" then
    return a:length() * speedUnit
  end
  return 0
end

local function getDisplayTotalLapsForRace(r)
  return competitiveTrackFlow.getDisplayTotalLapsForRace(r)
end

local function getGameplayAppContainers()
  if not extensions then
    return nil
  end
  local names = {"ui_gameplayAppContainers", "ge_extensions_ui_gameplayAppContainers"}
  for _, n in ipairs(names) do
    local gc = extensions[n]
    if gc and gc.showApp then
      return gc
    end
  end
  return nil
end

local function hideStagedFlashMessage()
  if guihooks and guihooks.trigger then
    guihooks.trigger("ScenarioFlashMessageClear")
  end
  local gc = getGameplayAppContainers()
  if gc and gc.hideApp then
    gc.hideApp("gameplayApps", "flashMessage")
    gc.hideApp("gameplayApps", "countdown")
  end
end

local function suppressVanillaDriftMissionUi()
  if gameplay_drift_general and gameplay_drift_general.setContext then
    gameplay_drift_general.setContext("inFreeroam")
  end
  if core_gamestate and core_gamestate.setGameState then
    core_gamestate.setGameState("freeroam", "freeroam", "freeroam")
  end
  local gc = getGameplayAppContainers()
  if gc and gc.hideApp then
    gc.hideApp("gameplayApps", "drift")
  end
end

local function triggerRaceCountdown()
  hideStagedFlashMessage()
end

local function getRaceLabel()
  local race = session.races[session.mActiveRace]
  local raceLabel = race.label
  if session.mAltRoute then
    raceLabel = race.altRoute.label
  end
  if session.mHotlap == session.mActiveRace then
    raceLabel = raceLabel .. " (Hotlap)"
  end
  return raceLabel
end

local function getDisplayRaceLabel()
  local race = session.races[session.mActiveRace]
  if not race then
    return ""
  end
  local raceLabel = race.label
  if session.mAltRoute and race.altRoute then
    raceLabel = race.altRoute.label
  end
  return raceLabel or ""
end

local function getDriftScore()
  local finalScore = 0
  if gameplay_drift_scoring then
    local scoreData = gameplay_drift_scoring.getScore()
    if scoreData then
      finalScore = scoreData.score or 0
      if scoreData.cachedScore then
        finalScore = finalScore + math.floor(scoreData.cachedScore * scoreData.combo)
      end
      gameplay_drift_general.reset()
    end
  end
  return finalScore
end

local function getRouteDisplayName(race, isAlt)
  if not race then
    return nil
  end
  if isAlt and race.altRoute and race.altRoute.label then
    return race.altRoute.label
  end
  return race.label
end

local function shouldUseAltRouteForNextLap(raceName)
  if not TRACK_RACE_ID or raceName ~= TRACK_RACE_ID then
    return false
  end
  local sr = gameplay_events_freContracts_sanctionedRacing
  local sanctionedCircuit = sr and sr.isSanctionedCircuitRaceActive and sr.isSanctionedCircuitRaceActive() and
    raceName == TRACK_RACE_ID
  local useAlt = (trackFlowState and trackFlowState.useAltRoute == true and trackFlowState.inTrackFlowContext) or false
  if sanctionedCircuit and sr and sr.isSanctionedCircuitRaceUseAltRoute then
    useAlt = sr.isSanctionedCircuitRaceUseAltRoute()
  end
  return useAlt
end

local function isAiSpawnedVehicle(subjectID)
  if not aiRacers or not aiRacers.getSpawnedVehicleIds then
    return false
  end
  for _, id in ipairs(aiRacers.getSpawnedVehicleIds()) do
    if id == subjectID then
      return true
    end
  end
  return false
end

local function buildAiResultsFromRaceState(isLapRace, playerLapsCompleted, playerTotalTime, playerBestLap, lapsTotalVal)
  if not (circuitRaceAi.hasAiLapState() and aiRacers and aiRacers.getSpawnedVehicleIds) then
    return nil
  end
  local MIN_LAP_SECONDS = 15
  local list = {}
  table.insert(list, {
    isPlayer = true,
    lapsCompleted = isLapRace and playerLapsCompleted or 1,
    lapsTotal = lapsTotalVal,
    totalTime = playerTotalTime,
    bestLap = playerBestLap
  })
  for i, vehId in ipairs(aiRacers.getSpawnedVehicleIds()) do
    local s = circuitRaceAi.getAiLapStateTable()[vehId]
    if s then
      local bestLap = nil
      if s.lapTimes and #s.lapTimes > 0 then
        for _, t in ipairs(s.lapTimes) do
          if type(t) == "number" and t >= MIN_LAP_SECONDS then
            bestLap = (bestLap == nil or t < bestLap) and t or bestLap
          end
        end
      end
      local aiTotal = nil
      if s.finished and s.lapTimes and #s.lapTimes >= (s.totalLaps or 1) then
        aiTotal = 0
        for _, t in ipairs(s.lapTimes) do
          aiTotal = aiTotal + (type(t) == "number" and t or 0)
        end
      end
      if not aiTotal then
        aiTotal = s.finishTime
      end
      if not aiTotal and s.lapTimes and #s.lapTimes > 0 then
        aiTotal = 0
        for _, t in ipairs(s.lapTimes) do
          aiTotal = aiTotal + (type(t) == "number" and t or 0)
        end
        aiTotal = aiTotal + (circuitRaceAi.getRaceSessionElapsed() - s.lapStartTime)
      end
      if aiTotal == nil then
        aiTotal = circuitRaceAi.getRaceSessionElapsed() - s.lapStartTime
      end
      table.insert(list, {
        isPlayer = false,
        index = i,
        lapsCompleted = s.lapCount,
        lapsTotal = s.totalLaps,
        totalTime = aiTotal,
        bestLap = bestLap
      })
    end
  end
  table.sort(list, function(a, b)
    return circuitRaceAi.compareRaceStanding({
      lapCount = a.lapsCompleted or 0,
      totalTime = a.totalTime
    }, {
      lapCount = b.lapsCompleted or 0,
      totalTime = b.totalTime
    })
  end)
  local leaderTime = (#list > 0 and list[1].totalTime) and list[1].totalTime or 0
  local aiResults = {}
  for place, row in ipairs(list) do
    local r = {
      place = place,
      isPlayer = row.isPlayer,
      lapsCompleted = row.lapsCompleted,
      lapsTotal = row.lapsTotal,
      totalTime = row.totalTime,
      bestLap = row.bestLap
    }
    if not row.isPlayer then
      r.index = row.index
    end
    r.diffFromLeader = (row.totalTime or 0) - leaderTime
    table.insert(aiResults, r)
  end
  return aiResults
end

local function beginFreeroamRace(raceNameArg, subjectID)
  if not session.races[raceNameArg] then
    return
  end
  local raceName = raceNameArg
  session.staged = nil
  raceSession.setStagingSubjectId(nil)
  if aiRacers and aiRacers.setPlayerFreeze then
    aiRacers.setPlayerFreeze(false)
  end
  if career_career.isActive() then
    career_modules_pauseTime.enablePauseCounter(true)
  end
  session.initialVehicleDamage = utils.getVehicleDamage()
  utils.saveAndSetTrafficAmount(0)
  checkpointManager.setRace(session.races[raceName], raceName)
  Assets:displayAssets({
    subjectID = subjectID,
    triggerName = "fre_start_" .. raceName
  })
  session.timerActive = true
  session.in_race_time = 0
  session.maxSpeed = 0
  session.mActiveRace = raceName
  if gameplay_events_freContracts_sanctionedRacing and gameplay_events_freContracts_sanctionedRacing.onRaceBegin then
    gameplay_events_freContracts_sanctionedRacing.onRaceBegin(raceName)
  end
  if raceName == TRACK_RACE_ID and competitiveTrackFlow then
    competitiveTrackFlow.clearSanctionedCareerGoToRaceActive()
  end
  raceSession.prepareNewRaceHudState(raceName)
  local useRaceHud = raceSession.raceHudApplies(session.races[raceName])
  if useRaceHud and not raceSession.isRaceHudShown() then
    raceSession.showFreeroamRaceHud()
  end
  session.lapCount = 0
  session.mCurrentRouteName = nil
  session.mTotalRaceTime = 0
  session.mBestLapThisRun = nil
  session.mSuppressOffRoadExitUntil = os.time() + 5
  if career_modules_business_businessInventory then
    local businessId, vehicleId = career_modules_business_businessInventory.getBusinessVehicleFromSpawnedId(subjectID)
    if businessId and vehicleId then
      local jobId = career_modules_business_businessInventory.getJobIdFromVehicle(businessId, vehicleId)
      if jobId then
        session.mInventoryId = career_modules_business_businessInventory.getBusinessJobIdentifier(businessId, jobId)
      else
        session.mInventoryId = career_modules_business_businessInventory.getBusinessVehicleIdentifier(businessId,
          vehicleId)
      end
    else
      session.mInventoryId = career_modules_inventory and
                               career_modules_inventory.getInventoryIdFromVehicleId(subjectID) or subjectID
    end
  else
    session.mInventoryId =
      career_modules_inventory and career_modules_inventory.getInventoryIdFromVehicleId(subjectID) or subjectID
  end
  session.invalidLap = false
  if useRaceHud then
    raceSession.setRaceHudBanner(utils.getRaceStartBannerText(raceName), "good", 5)
    raceSession.pushFreeroamRaceHudState(true)
  else
    utils.displayStartMessage(raceName)
  end
  utils.setActiveLight(raceName, "green")
  local rStart = session.races[raceName]
  local isFreDrift = rStart and ((rStart.type and utils.tableContains(rStart.type, "drift")) or rStart.driftGoal)
  if isFreDrift then
    if gameplay_drift_general and gameplay_drift_general.reset then
      gameplay_drift_general.reset()
    end
    if gameplay_drift_drift then
      gameplay_drift_drift.setVehId(subjectID)
    end
  end
  extensions.hook('onFreeroamSessionStarted', {
    raceName = raceName,
    subjectID = subjectID,
    race = session.races[raceName],
    checkpointRoad = session.races[raceName].checkpointRoad
  })
  notifyFreContractsFreeroamUi()
  if isFreDrift then
    suppressVanillaDriftMissionUi()
    if core_jobsystem and core_jobsystem.create then
      core_jobsystem.create(function(job)
        job.sleep(0.2)
        suppressVanillaDriftMissionUi()
      end)
    end
  end
end

local function applySavedStagingSpotNavigation()
  local spot = competitiveTrackFlow.loadPlayerStagingSpot()
  if not spot or not spot.pos then
    return
  end
  competitiveTrackFlow.setPlayerStagingSpot(spot)
  if core_groundMarkers and core_groundMarkers.setPath then
    core_groundMarkers.setPath(vec3(spot.pos[1], spot.pos[2], spot.pos[3]), {
      clearPathOnReachingTarget = false
    })
  end
  competitiveTrackFlow.showPlayerStagingCornerMarkers(spot)
end

local function exitRace(isCompletion, customMessage, raceData, subjectID)
  if isCompletion == false and session.mPendingTrackResult then
    return
  end
  competitiveTrackFlow.cancelCompetitiveGridFlow()
  if session.mActiveRace then
    local raceName = session.mActiveRace
    local cpRoad = session.races[raceName] and session.races[raceName].checkpointRoad
    local mainRace = session.races[raceName]
    local useRaceHud = mainRace and raceSession.raceHudApplies(mainRace)
    local effectiveRace = (mainRace and session.mAltRoute and mainRace.altRoute) and mainRace.altRoute or
                            (raceData or mainRace or {})
    local erSession = effectiveRace and effectiveRace.session
    local raceLabel = getRaceLabel()
    local displayLabel = getDisplayRaceLabel()
    local isLapRace = effectiveRace and
                        ((erSession and erSession.lapCount and erSession.lapCount > 0) or effectiveRace.hotlap)

    local finalResult = nil
    local hudCompletionPl = nil

    if isCompletion then
      if session.in_race_time and (session.mBestLapThisRun == nil or session.in_race_time < session.mBestLapThisRun) then
        session.mBestLapThisRun = session.in_race_time
      end
      local rewardData
      rewardData, hudCompletionPl = raceSession.payoutRace()
      local rewardAmt = 0
      if type(rewardData) == "number" then
        rewardAmt = rewardData
      end

      local totalTime = (session.mTotalRaceTime or 0) + session.in_race_time
      local lapsTotalVal = 1
      if isLapRace then
        lapsTotalVal = getDisplayTotalLapsForRace(effectiveRace)
        if lapsTotalVal < 1 then
          local lc = erSession and erSession.lapCount
          lapsTotalVal = (type(lc) == "number" and lc > 0) and lc or session.lapCount
        end
        if lapsTotalVal < 1 then
          lapsTotalVal = session.lapCount
        end
      end

      finalResult = {
        raceLabel = displayLabel,
        lapsCompleted = isLapRace and session.lapCount or 1,
        lapsTotal = lapsTotalVal,
        totalTime = totalTime,
        bestLap = session.mBestLapThisRun,
        newBest = session.newBestSession,
        invalidLap = session.invalidLap,
        reward = rewardAmt,
        xp = 0,
        leaderboard = {}
      }
      local aiResults = buildAiResultsFromRaceState(isLapRace, session.lapCount, totalTime, session.mBestLapThisRun, lapsTotalVal)
      if aiResults then
        finalResult.aiResults = aiResults
      end
      if hudCompletionPl and hudCompletionPl.rewards and hudCompletionPl.rewards.disciplineXp then
        finalResult.xp = math.floor(tonumber(hudCompletionPl.rewards.disciplineXp) or 0)
      end

      if raceName == "drag" and effectiveRace and subjectID and not useRaceHud then
        local side = "l"
        utils.updateDisplay(side, session.in_race_time, math.abs(be:getObjectVelocityXYZ(subjectID)) * session.speedUnit)
      end

      if effectiveRace and effectiveRace.type and utils.tableContains(effectiveRace.type, "drift") then
        local finalScore = getDriftScore()
        if gameplay_drift_general.getContext() == "inChallenge" then
          gameplay_drift_general.setContext("inFreeRoam")
        end
      end

      if customMessage then
        utils.displayMessage(customMessage, 10)
      end
    else
      local message = customMessage or "You exited the race zone, Race cancelled"
      utils.displayMessage(message, 3)
      if session.lapCount >= 1 and effectiveRace then
        local rd = effectiveRace
        local rdSession = rd and rd.session
        local isLap = rd and ((rdSession and rdSession.lapCount and rdSession.lapCount > 0) or rd.hotlap)
        local totalTimePartial = (session.mTotalRaceTime or 0) + session.in_race_time
        local lapsTotalVal = 1
        if isLap then
          lapsTotalVal = getDisplayTotalLapsForRace(rd)
          if lapsTotalVal < 1 then
            local lc = rdSession and rdSession.lapCount
            lapsTotalVal = (type(lc) == "number" and lc > 0) and lc or session.lapCount
          end
          if lapsTotalVal < 1 then
            lapsTotalVal = session.lapCount
          end
        end
        finalResult = {
          raceLabel = displayLabel,
          lapsCompleted = isLap and session.lapCount or 1,
          lapsTotal = lapsTotalVal,
          totalTime = totalTimePartial,
          bestLap = session.mBestLapThisRun,
          newBest = false,
          invalidLap = session.invalidLap,
          reward = 0,
          xp = 0,
          leaderboard = {}
        }
        local aiResultsAbort = buildAiResultsFromRaceState(isLap, session.lapCount, totalTimePartial, session.mBestLapThisRun, lapsTotalVal)
        if aiResultsAbort then
          finalResult.aiResults = aiResultsAbort
        end
      end
    end

    if gameplay_events_freContracts_sanctionedRacing then
      if isCompletion and finalResult and finalResult.aiResults then
        gameplay_events_freContracts_sanctionedRacing.settleFromAiResults(finalResult.aiResults, raceName)
      elseif not isCompletion then
        gameplay_events_freContracts_sanctionedRacing.onRaceAborted()
      elseif isCompletion then
        gameplay_events_freContracts_sanctionedRacing.settleFromAiResults(nil, raceName)
      end
    end

    local srCelebration = isCompletion and gameplay_events_freContracts_sanctionedRacing and
      gameplay_events_freContracts_sanctionedRacing.consumeSanctionedCelebrationRewards and
      gameplay_events_freContracts_sanctionedRacing.consumeSanctionedCelebrationRewards()
    if srCelebration and type(srCelebration.money) == "number" and finalResult then
      finalResult.reward = srCelebration.money
      if type(srCelebration.noRewardDetail) == "string" and srCelebration.noRewardDetail ~= "" then
        finalResult.sanctionedNoRewardDetail = srCelebration.noRewardDetail
      end
      if hudCompletionPl and type(hudCompletionPl) == "table" then
        if not hudCompletionPl.rewards then
          hudCompletionPl.rewards = {}
        end
        hudCompletionPl.rewards.money = srCelebration.money
        local sx = tonumber(srCelebration.disciplineXp)
        if sx ~= nil then
          hudCompletionPl.rewards.disciplineXp = math.max(0, math.floor(sx))
        elseif hudCompletionPl.rewards.disciplineXp == nil then
          hudCompletionPl.rewards.disciplineXp = 0
        end
        if type(srCelebration.noRewardDetail) == "string" and srCelebration.noRewardDetail ~= "" then
          hudCompletionPl.sanctionedNoRewardDetail = srCelebration.noRewardDetail
        end
      end
    end

    local hasSpawnedAi =
      (aiRacers and aiRacers.getSpawnedVehicleIds and (#(aiRacers.getSpawnedVehicleIds() or {}) > 0)) or
        circuitRaceAi.hasAiLapState()
    local deferResultScreen = isCompletion and hasSpawnedAi and finalResult
    local deferHudHide = isCompletion and useRaceHud and hudCompletionPl and not deferResultScreen

    if isCompletion and hudCompletionPl and not deferResultScreen then
      raceSession.pushRaceHudCompletion(hudCompletionPl, raceName, displayLabel, raceLabel, session.in_race_time, true)
    end

    if deferResultScreen and guihooks and guihooks.trigger then
      guihooks.trigger("OpenFreRaceCompletionCelebration", {
        entry = raceSession.buildFreRaceCompletionCelebrationEntry(finalResult, hudCompletionPl)
      })
      guihooks.trigger("ScenarioFlashMessageReset")
      hideStagedFlashMessage()
    end
    session.mPendingTrackResult = nil

    raceSession.maybeShowFreerunSummary(cpRoad, isCompletion, deferResultScreen)

    utils.setActiveLight(raceName, "red")
    session.lapCount = 0
    session.timerActive = false
    session.mHotlap = nil
    session.currCheckpoint = nil
    session.mSplitTimes = {}
    session.mAltRoute = false
    session.mCurrentRouteName = nil
    session.invalidLap = false
    session.mInventoryId = nil
    session.maxSpeed = 0
    session.mTotalRaceTime = 0
    session.mBestLapThisRun = nil
    session.mSuppressOffRoadExitUntil = 0

    session.mActiveRace = nil
    notifyFreContractsFreeroamUi()
    local hideHudNow = deferResultScreen or not deferHudHide
    extensions.hook('onFreeroamSessionExiting', {
      raceName = raceName,
      checkpointRoad = cpRoad,
      isCompletion = isCompletion
    })
    if hideHudNow then
      raceSession.hideFreeroamRaceHud()
    end
    Assets:hideAllAssets()

    if aiRacers and aiRacers.setDnfCallback then
      aiRacers.setDnfCallback(nil)
    end
    if deferResultScreen and aiRacers and aiRacers.scheduleDelayedDespawn then
      aiRacers.scheduleDelayedDespawn(50)
      core_jobsystem.create(function(job)
        job.sleep(15)
        if aiRacers and aiRacers.clearSpawned then
          aiRacers.clearSpawned()
        end
        core_jobsystem.create(function(innerJob)
          innerJob.sleep(10)
          if session.mActiveRace then
            return
          end
          utils.restoreTrafficAmount()
        end)
      end)
    else
      if aiRacers and aiRacers.clearSpawned then
        aiRacers.clearSpawned()
      end
      core_jobsystem.create(function(job)
        job.sleep(10)
        if session.mActiveRace then
          return
        end
        utils.restoreTrafficAmount()
      end)
    end

    pits.clearSpeedLimit()
    session.newBestSession = false
    trackFlowState.sanctionedRaceLapCount = nil
    if raceName == TRACK_RACE_ID and competitiveTrackFlow and competitiveTrackFlow.leaveTrackFlowAfterRace then
      competitiveTrackFlow.leaveTrackFlowAfterRace()
    end
    local exitedFreRace = session.races[raceName]
    if exitedFreRace and
        ((exitedFreRace.type and utils.tableContains(exitedFreRace.type, "drift")) or exitedFreRace.driftGoal) then
      gameplay_drift_general.setContext("inFreeroam")
      gameplay_drift_general.reset()
    end
    if career_career.isActive() then
      career_modules_pauseTime.enablePauseCounter()
    end
    if deferHudHide then
      core_jobsystem.create(function(job)
        job.sleep(18)
        raceSession.hideFreeroamRaceHud()
      end)
    end
    if session.previousGameState then
      core_gamestate.setGameState(session.previousGameState.state, session.previousGameState.appLayout,
        session.previousGameState.menuItems, session.previousGameState.options)
      session.previousGameState = nil
      session.saveGameState = false
    end
  end
end

local function tryCommitStagingEnter(raceName, spawnVehId)
  if not session.races or not session.races[raceName] then
    return false
  end
  if utils.isPlayerInPursuit() then
    utils.displayMessage("You cannot stage for an event while in a pursuit.", 2)
    return false
  end

  local srr = gameplay_events_freContracts_sanctionedRacing
  if srr and srr.isSanctionedRescheduleActionActive and srr.isSanctionedRescheduleActionActive() then
    utils.displayMessage("Reschedule or finish your sanctioned race from the phone before staging for practice.", 4)
    return false
  end

  if competitiveTrackFlow.shouldBlockFreeroamStagingPractice and
      competitiveTrackFlow.shouldBlockFreeroamStagingPractice(raceName) then
    utils.displayMessage("Finish or leave sanctioned grid staging before using practice staging.", 4)
    return false
  end

  session.saveGameState = true
  core_gamestate.requestGameState()

  local vehicleSpeed = getVehicleSpeedMph(spawnVehId)
  if vehicleSpeed > 5 and session.mActiveRace then
    return false
  end
  session.mHotlap = nil
  if vehicleSpeed > 5 then
    if session.races[raceName].runningStart then
      if raceSession.raceHudApplies(session.races[raceName]) then
        raceSession.setRaceHudBanner("Hotlap session.staged — roll to start", "info", 3)
      else
        utils.displayMessage("Hotlap Staged", 2)
      end
      if session.races[raceName].hotlap then
        session.mHotlap = raceName
      end
    else
      utils.displayMessage("You are too fast to stage.\nPlease back up and slow down to stage.", 2)
      session.staged = nil
      return false
    end
  end
  Assets:hideAllAssets()
  session.lapCount = 0

  local allTypesDisabled = false
  local disabledTypes = {}
  if career_economyAdjuster and session.races[raceName].type then
    local totalTypes = 0
    local disabledCount = 0
    for _, raceType in ipairs(session.races[raceName].type) do
      totalTypes = totalTypes + 1
      local multiplier = career_economyAdjuster.getEffectiveSectionMultiplier({raceType})
      if multiplier == 0 then
        disabledCount = disabledCount + 1
        table.insert(disabledTypes, raceType)
      end
    end
    allTypesDisabled = totalTypes > 0 and disabledCount == totalTypes
  end

  if allTypesDisabled then
    local typesString = table.concat(disabledTypes, ", ")
    utils.displayMessage(string.format("%s is disabled due to %s multiplier(s) being set to 0.",
      session.races[raceName].label, typesString), 5)
    return false
  end

  if raceName == "drag" then
    utils.initDisplays()
    utils.resetDisplays()
  end

  session.staged = raceName
  session.freeroamPracticeStaging = true
  local vehId = spawnVehId
  if career_career and career_career.isActive and career_career.isActive() then
    if career_modules_business_businessInventory and
      career_modules_business_businessInventory.getBusinessVehicleFromSpawnedId then
      local businessId, vehicleId =
        career_modules_business_businessInventory.getBusinessVehicleFromSpawnedId(spawnVehId)
      if businessId and vehicleId then
        vehId = career_modules_business_businessInventory.getBusinessVehicleIdentifier(businessId, vehicleId)
      elseif career_modules_inventory and career_modules_inventory.getInventoryIdFromVehicleId then
        vehId = career_modules_inventory.getInventoryIdFromVehicleId(vehId) or vehId
      end
    elseif career_modules_inventory and career_modules_inventory.getInventoryIdFromVehicleId then
      vehId = career_modules_inventory.getInventoryIdFromVehicleId(vehId) or vehId
    end
  end

  local race = session.races[raceName] or {}
  raceSession.setStagingSubjectId(vehId)
  if raceSession.raceHudApplies(race) then
    raceSession.showFreeroamRaceHud()
  else
    utils.displayStagedMessage(vehId, raceName)
  end
  utils.setActiveLight(raceName, "yellow")
  extensions.hook('onFreeroamStagingCommitted', {
    raceName = raceName,
    vehicleId = vehId
  })
  notifyFreContractsFreeroamUi()
  return true
end

local function beamngTrigger_staging(data, event, raceName)
  if event == "enter" and session.mActiveRace == nil then
    if raceName == TRACK_RACE_ID and competitiveTrackFlow.isSanctionedCareerGoToRaceActive() then
      local spot = competitiveTrackFlow.getPlayerStagingSpot()
      if spot and competitiveTrackFlow.isPlayerInTrackParkingCommitArea() then
        return
      end
    end
    tryCommitStagingEnter(raceName, data.subjectID)
  elseif event == "exit" then
    if session.mActiveRace ~= raceName then
      if raceName == TRACK_RACE_ID and competitiveTrackFlow.isSanctionedCareerGoToRaceActive() then
        return
      end
      if raceName == TRACK_RACE_ID then
        competitiveTrackFlow.cancelCompetitiveGridFlow()
      end
      local r = session.races[raceName]
      local useHud = r and raceSession.raceHudApplies(r)
      local showStagingExitMsg = session.mActiveRace == nil
      if useHud and showStagingExitMsg then
        raceSession.setRaceHudBanner("You exited the staging zone", "warn", 4)
        raceSession.pushFreeroamRaceHudState(true)
      end
      session.staged = nil
      raceSession.setStagingSubjectId(nil)
      hideStagedFlashMessage()
      notifyFreContractsFreeroamUi()
      if not useHud and showStagingExitMsg then
        utils.displayMessage("You exited the staging zone", 4)
      end
      utils.setActiveLight(raceName, "red")
      if useHud and showStagingExitMsg then
        core_jobsystem.create(function(job)
          job.sleep(2.5)
          if not session.mActiveRace then
            raceSession.hideFreeroamRaceHud()
          end
        end)
      end
    end
  end
end

local function beamngTrigger_startPlayer(data, event, raceName)
  if event == "enter" and session.mActiveRace == raceName and not utils.hasFinishTrigger(raceName) then
    if not session.currCheckpoint or session.checkpointsHit < session.totalCheckpoints then
      if not session.invalidLap then
        if raceSession.isRaceHudShown() then
          raceSession.setRaceHudBanner("Complete all checkpoints before crossing the line", "warn", 5)
          raceSession.pushFreeroamRaceHudState(true)
        else
          utils.displayMessage("You have not completed all checkpoints!", 5)
        end
        return
      end
    end
    local completedLapTime = session.in_race_time
    session.timerActive = false
    session.mSuppressOffRoadExitUntil = os.time() + 2
    if not session.invalidLap then
      session.mTotalRaceTime = (session.mTotalRaceTime or 0) + completedLapTime
      if session.mBestLapThisRun == nil or completedLapTime < session.mBestLapThisRun then
        session.mBestLapThisRun = completedLapTime
      end
    end
    session.initialVehicleDamage = utils.getVehicleDamage()
    processRoad.setStationaryTimeout(session.races[raceName].timeout)
    checkpointManager.setRace(session.races[raceName], raceName)
    if not data.triggerName then
      data.triggerName = "fre_start_" .. raceName
    end
    Assets:displayAssets(data)
    utils.playCheckpointSound()
    session.lapCount = session.lapCount + 1
    extensions.hook('onFreeroamLapCompleted', {
      raceName = raceName,
      lapCount = session.lapCount,
      lapTime = completedLapTime,
      invalid = session.invalidLap
    })
    local race = session.races[raceName]
    local effectiveRace = (session.mAltRoute and race.altRoute) and race.altRoute or race
    local lapTotalGoal = getDisplayTotalLapsForRace(effectiveRace)
    if lapTotalGoal < 1 then
      local erSessionLaps = effectiveRace and effectiveRace.session
      local lc = erSessionLaps and erSessionLaps.lapCount
      lapTotalGoal = (type(lc) == "number" and lc > 0) and lc or 0
    end
    local enforceSanctionedLapCap = raceName == TRACK_RACE_ID and gameplay_events_freContracts_sanctionedRacing and
      gameplay_events_freContracts_sanctionedRacing.shouldSuppressFrePayouts()
    if enforceSanctionedLapCap and lapTotalGoal > 0 and session.lapCount >= lapTotalGoal then
      exitRace(true, nil, effectiveRace, data.subjectID)
      return
    end
    local snapshotLabel = getDisplayRaceLabel()
    local snapshotRaceLabel = getRaceLabel()
    local reward, hudMsg = raceSession.payoutRace(completedLapTime)
    if not circuitRaceAi.isSanctionedTriggerOnlyLapRace() and type(reward) == "number" and reward > 0 and
      session.races[raceName].checkpointRoad then
      raceSession.setLastLapReward(reward)
    end
    session.currCheckpoint = nil
    session.mSplitTimes = {}
    session.mActiveRace = raceName
    checkpointManager.setAltRoute(false)
    session.mAltRoute = false
    session.in_race_time = 0
    session.maxSpeed = 0
    session.timerActive = true
    session.checkpointsHit = 0
    if shouldUseAltRouteForNextLap(raceName) then
      session.mAltRoute = true
      checkpointManager.setAltRoute(true)
    end
    session.totalCheckpoints = checkpointManager.calculateTotalCheckpoints()
    session.currentExpectedCheckpoint = 0
    if session.races[raceName].hotlap then
      session.mHotlap = raceName
      session.currentExpectedCheckpoint = checkpointManager.enableCheckpoint(0, session.mAltRoute)
    end
    session.invalidLap = false
    if hudMsg then
      raceSession.pushRaceHudCompletion(hudMsg, raceName, snapshotLabel, snapshotRaceLabel, 0, false)
    else
      raceSession.pushFreeroamRaceHudState(true)
    end
  elseif event == "enter" and session.staged == raceName and session.mActiveRace ~= raceName then
    if raceName == TRACK_RACE_ID and
      (competitiveTrackFlow.getCompetitiveCountdownJobActive() or competitiveTrackFlow.getCompetitiveAwaitingAiSpawn()) then
      return
    end
    beginFreeroamRace(raceName, data.subjectID)
  else
    utils.setActiveLight(raceName, "red")
  end
end

local function beamngTrigger_checkpointPlayer(data, event, raceName, checkpointIndex, isAlt)
  if event == "enter" and session.mActiveRace == raceName then
    if session.checkpointsHit >= session.totalCheckpoints then
      return
    end
    if (checkpointIndex == session.currentExpectedCheckpoint) or (checkpointIndex == 1 and isAlt) or
      (isAlt and (session.currentExpectedCheckpoint == session.races[raceName].altRoute.mergeCheckpoints[1])) then
      session.checkpointsHit = session.checkpointsHit + 1
      raceSession.clearHudCompletionPayload()
      session.currCheckpoint = checkpointIndex
      local mainRaceCp = session.races[raceName]
      local effectiveRaceCp = (session.mAltRoute and mainRaceCp.altRoute) and mainRaceCp.altRoute or mainRaceCp
      if effectiveRaceCp.driftGoal then
        session.mSplitTimes[session.checkpointsHit] = tonumber(raceSession.peekLiveDriftScore()) or 0
      else
        session.mSplitTimes[session.checkpointsHit] = session.in_race_time
      end
      if session.checkpointsHit == 1 then
        session.mCurrentRouteName = getRouteDisplayName(session.races[raceName], isAlt)
      end
      utils.playCheckpointSound()

      if isAlt then
        session.currentExpectedCheckpoint = checkpointIndex
      end

      session.currentExpectedCheckpoint = checkpointManager.enableCheckpoint(checkpointIndex, isAlt)
      if isAlt and not session.mAltRoute then
        session.mAltRoute = true
        checkpointManager.setAltRoute(true)
        session.totalCheckpoints = checkpointManager.calculateTotalCheckpoints()
      end
      checkpointManager.notifyCheckpointEntered({
        raceName = raceName,
        checkpointIndex = checkpointIndex,
        isAlt = isAlt,
        checkpointsHit = session.checkpointsHit,
        totalCheckpoints = session.totalCheckpoints,
        inRaceTime = session.in_race_time
      })

      local checkpointMessage = ""
      local driftSplits = effectiveRaceCp.driftGoal
      local splitDiff = raceSession.getDifference(raceName, session.checkpointsHit)
      if splitDiff then
        local raceLabel = getRaceLabel()
        local leaderboardEntry = leaderboardManager.getLeaderboardEntry(session.mInventoryId, raceLabel)
        local totalDiff
        if driftSplits then
          totalDiff = (leaderboardEntry.splitTimes[session.checkpointsHit] or 0) -
            (session.mSplitTimes[session.checkpointsHit] or 0)
        else
          totalDiff = session.in_race_time - (leaderboardEntry.splitTimes[session.checkpointsHit] or 0)
        end

        if driftSplits then
          checkpointMessage = string.format("Checkpoint %d/%d - Score: %d\nSplit: %s | Total: %s", session.checkpointsHit,
            session.totalCheckpoints, math.floor(session.mSplitTimes[session.checkpointsHit] or 0),
            raceSession.formatSplitDifference(splitDiff, true), raceSession.formatSplitDifference(totalDiff, true))
        else
          checkpointMessage = string.format("Checkpoint %d/%d - Time: %s\nSplit: %s | Total: %s", session.checkpointsHit,
            session.totalCheckpoints, utils.formatTime(session.in_race_time),
            raceSession.formatSplitDifference(splitDiff), raceSession.formatSplitDifference(totalDiff))
        end
      else
        if driftSplits then
          checkpointMessage = string.format("Checkpoint %d/%d - Score: %d", session.checkpointsHit,
            session.totalCheckpoints, math.floor(session.mSplitTimes[session.checkpointsHit] or 0))
        else
          checkpointMessage = string.format("Checkpoint %d/%d - Time: %s", session.checkpointsHit,
            session.totalCheckpoints, utils.formatTime(session.in_race_time))
        end
      end
      if not session.races[raceName].checkpointRoad then
        utils.displayMessage(checkpointMessage, 7)
      end
      raceSession.pushFreeroamRaceHudState(true)
      if not data.triggerName then
        data.triggerName = "fre_checkpoint_" .. raceName .. (isAlt and "_alt_" or "_") .. checkpointIndex
      end
      Assets:displayAssets(data)
    else
      local missedCheckpoints = checkpointIndex - session.currentExpectedCheckpoint
      if missedCheckpoints > 0 then
        session.invalidLap = true

        session.currCheckpoint = checkpointIndex
        session.currentExpectedCheckpoint = session.currentExpectedCheckpoint + missedCheckpoints
        session.checkpointsHit = math.min(session.checkpointsHit + missedCheckpoints + 1, session.totalCheckpoints)
        raceSession.clearHudCompletionPayload()

        session.currentExpectedCheckpoint = checkpointManager.enableCheckpoint(checkpointIndex, isAlt)

        local message = string.format("Missed a checkpoint\nLap Invalidated.", checkpointIndex)
        local mrX = session.races[raceName]
        local erX = (session.mAltRoute and mrX.altRoute) and mrX.altRoute or mrX
        local checkpointMessageMiss
        if erX.driftGoal then
          checkpointMessageMiss = string.format("Checkpoint %d/%d - Score: %d", session.checkpointsHit,
            session.totalCheckpoints, math.floor(session.mSplitTimes[session.checkpointsHit] or 0))
        else
          checkpointMessageMiss = string.format("Checkpoint %d/%d - Time: %s", session.checkpointsHit,
            session.totalCheckpoints, utils.formatTime(session.in_race_time))
        end
        message = message .. "\n" .. checkpointMessageMiss
        if session.races[raceName].checkpointRoad and raceSession.isRaceHudShown() then
          raceSession.setRaceHudBanner("Missed checkpoint — lap invalidated", "warn", 8)
        elseif not raceSession.isRaceHudShown() then
          utils.displayMessage(message, 10)
        end
        raceSession.pushFreeroamRaceHudState(true)
      else
        log("W", "freeroamEvents",
          string.format("Unexpected checkpoint trigger for race '%s': got %d, expected %s, alt=%s, hit=%d/%d.",
            tostring(raceName), tonumber(checkpointIndex) or -1, tostring(session.currentExpectedCheckpoint),
            tostring(isAlt), tonumber(session.checkpointsHit) or 0, tonumber(session.totalCheckpoints) or 0))
      end
    end
  end
end

local function beamngTrigger_finishPlayer(data, event, raceName)
  if event == "enter" and session.mActiveRace == raceName then
    local race = session.races[raceName]
    local effectiveRace = (race and session.mAltRoute and race.altRoute) and race.altRoute or race
    exitRace(true, nil, effectiveRace, data.subjectID)
  end
end

local function beamngTrigger_pits(data, event, raceName)
  if event == "enter" and session.mActiveRace == raceName then
    local obj = be:getPlayerVehicle(0)
    if obj then
      obj:queueLuaCommand("obj:setGhostEnabled(true)")
    end
    if session.races[raceName].pitSpeedLimit then
      pits.stopThenLimit(session.races[raceName].pitSpeedLimit, session.races[raceName].pitSpeedLimitUnit)
    else
      pits.stopThenLimit(37, "MPH")
    end
  elseif event == "exit" and session.mActiveRace == raceName then
    pits.toggleSpeedLimit()
    local obj = be:getPlayerVehicle(0)
    if obj then
      obj:queueLuaCommand("obj:setGhostEnabled(false)")
    end
  end
end

local function onBeamNGTrigger(data)
  if session.isReplay then
    return
  end
  local isPlayer = (be:getPlayerVehicleID(0) == data.subjectID)
  if not isPlayer and not isAiSpawnedVehicle(data.subjectID) then
    return
  end
  if gameplay_walk.isWalking() then
    return
  end

  local triggerName = data.triggerName
  local event = data.event

  if not triggerName:match("^fre_") then
    return
  end

  triggerName = triggerName:sub(5)

  local triggerType, raceName, rest = triggerName:match("^([^_]+)_([^_]+)(.*)$")

  if not triggerType or not raceName then
    return
  end

  local altFlag = nil
  local index = nil
  local isAiAlt = false

  if rest ~= "" then
    rest = rest:gsub("^_+", "")

    if rest:sub(1, 6) == "ai_alt" then
      isAiAlt = true
      rest = rest:sub(7):gsub("^_+", "")
    elseif rest:sub(1, 3) == "alt" then
      altFlag = "alt"
      rest = rest:sub(4)
      rest = rest:gsub("^_+", "")
    end

    if rest ~= "" then
      index = rest
    end
  end

  local checkpointIndex = index and tonumber(index) or nil

  local isAlt = altFlag == "alt"

  if circuitRaceAi.tryHandleAiTrigger(data, event, triggerType, raceName, checkpointIndex, isAiAlt, isAlt, isPlayer) then
    return
  end

  if not isPlayer then
    return
  end

  if triggerType == "hub" and raceName == TRACK_RACE_ID then
    competitiveTrackFlow.beamngTrigger_trackBuilding(data, event)
    return
  end

  if triggerType == "staging" then
    beamngTrigger_staging(data, event, raceName)
  elseif triggerType == "start" then
    beamngTrigger_startPlayer(data, event, raceName)
  elseif triggerType == "checkpoint" and checkpointIndex then
    beamngTrigger_checkpointPlayer(data, event, raceName, checkpointIndex, isAlt)
  elseif triggerType == "finish" then
    beamngTrigger_finishPlayer(data, event, raceName)
  elseif triggerType == "pits" then
    beamngTrigger_pits(data, event, raceName)
  end
end

local function preloadFreeroamAiPathsForTrack()
  competitiveTrackFlow.preloadAiPathsForTrack()
end

local function onWorldReadyState(state)
  if state ~= 2 or not session or not utils or not competitiveTrackFlow then
    return
  end
  session.races = utils.loadRaceData()
  preloadFreeroamAiPathsForTrack()
end

local function loadExtensions()
  local freeroamPath = "/lua/ge/extensions/gameplay/events/freeroam/"
  local files = FS:findFiles(freeroamPath, "*.lua", -1, true, false)

  if files then
    local names = {}
    for _, filePath in ipairs(files) do
      local filename = string.match(filePath, "([^/]+)%.lua$")
      if filename then
        table.insert(names, "gameplay_events_freeroam_" .. filename)
      end
    end
    table.sort(names, function(a, b)
      return a < b
    end)
    local sessionExt = "gameplay_events_freeroam_session"
    for _, extensionName in ipairs(names) do
      if extensionName ~= sessionExt then
        setExtensionUnloadMode(extensionName, "manual")
        extensions.unload(extensionName)
        table.insert(loadedExtensions, extensionName)
      end
    end
  end
  loadManualUnloadExtensions()
end

local function unloadExtensions()
  for _, extensionName in ipairs(loadedExtensions) do
    extensions.unload(extensionName)
  end
end

local function onExtensionLoaded()
  loadExtensions()
  session = gameplay_events_freeroam_session
  processRoad = gameplay_events_freeroam_processRoad
  leaderboardManager = gameplay_events_freeroam_leaderboardManager
  checkpointManager = gameplay_events_freeroam_checkpointManager
  utils = gameplay_events_freeroam_utils
  pits = gameplay_events_freeroam_pits
  aiRacers = gameplay_events_freeroam_aiRacers
  circuitRaceAi = gameplay_events_freeroam_circuitRaceAi
  competitiveTrackFlow = gameplay_events_freeroam_competitiveTrackFlow
  Assets = gameplay_events_freeroam_activeAssets.ActiveAssets.new()
  trackFlowState = competitiveTrackFlow.trackFlowState
  TRACK_RACE_ID = competitiveTrackFlow.TRACK_RACE_ID
  raceSession = gameplay_events_freeroam_raceSession
  if getCurrentLevelIdentifier() then
    session.races = utils.loadRaceData()
    preloadFreeroamAiPathsForTrack()
  end
end

local function onExtensionUnloaded()
  if raceSession then
    raceSession.hideFreeroamRaceHud(true)
  end
  unloadExtensions()
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if not session or not competitiveTrackFlow or not raceSession or not processRoad or not circuitRaceAi then
    return
  end
  if aiRacers and aiRacers.onUpdate then
    aiRacers.onUpdate(dtReal or 0)
  end

  competitiveTrackFlow.onUpdateParkingResolve()
  competitiveTrackFlow.onUpdateParkingLoop()

  if session.mActiveRace and raceSession.raceUsesProcessRoadExit(session.races[session.mActiveRace]) then
    if os.time() >= session.mSuppressOffRoadExitUntil and processRoad.checkPlayerOnRoad() == false then
      exitRace(false)
    end
  end
  if session.timerActive == true then
    if not (session.dragPracticeActive and session.mActiveRace == "drag") then
      session.in_race_time = session.in_race_time + dtSim
    end
    circuitRaceAi.onWaypointPollAccum(dtSim)
    local playerVehicleId = be:getPlayerVehicleID(0)
    if playerVehicleId then
      local currentSpeed = getVehicleSpeedMph(playerVehicleId)
      if currentSpeed > session.maxSpeed then
        session.maxSpeed = currentSpeed
      end
    end
    raceSession.pushFreeroamRaceHudState(false)
  else
    session.in_race_time = 0
    if raceSession.isRaceHudShown() and not session.timerActive then
      raceSession.pushFreeroamRaceHudState(false)
    end
  end
end

local function formatEventPoi(raceName, race)
  local startObj = scenetree.findObject("fre_start_" .. raceName)
  local pos = startObj and startObj:getPosition() or nil

  if not pos then
    return nil
  end

  local levelIdentifier = getCurrentLevelIdentifier()
  local preview = "/levels/" .. levelIdentifier .. "/facilities/freeroamEvents/" .. raceName .. ".jpg"

  local vehId = be:getPlayerVehicleID(0) or 0
  if career_career.isActive() then
    vehId = career_modules_inventory.getInventoryIdFromVehicleId(vehId) or vehId
  end

  return {
    id = raceName,
    data = {
      type = "events",
      facility = {}
    },
    markerInfo = {
      bigmapMarker = {
        pos = pos,
        icon = "mission_cup_triangle",
        name = race.label,
        description = utils.displayStagedMessage(vehId, raceName, true),
        previews = {preview},
        thumbnail = preview
      }
    }
  }
end

function M.onGetRawPoiListForLevel(levelIdentifier, elements)
  if not session.races then
    return
  end
  for raceName, race in pairs(session.races) do
    local poi = formatEventPoi(raceName, race)
    if poi then
      table.insert(elements, poi)
    end
  end
end

local function onReplayStateChanged(state)
  if not session.isReplay and state.state == "playback" then
    session.isReplay = true
  elseif session.isReplay and state.state == "inactive" then
    session.isReplay = false
  end
end

local function onGameStateUpdate(state)
  if session.saveGameState then
    session.saveGameState = false
    session.previousGameState = state
  end
end

M.onGameStateUpdate = onGameStateUpdate

M.onReplayStateChanged = onReplayStateChanged
M.onBeamNGTrigger = onBeamNGTrigger
M.onUpdate = onUpdate

M.payoutRace = function(completedLapTime)
  if raceSession then
    return raceSession.payoutRace(completedLapTime)
  end
  return 0
end
M.payoutDragRace = function(raceName, finishTime, finishSpeed, vehId)
  if raceSession then
    return raceSession.payoutDragRace(raceName, finishTime, finishSpeed, vehId)
  end
  return 0
end
M.onWorldReadyState = onWorldReadyState
M.getRace = function(raceName)
  if not session or not session.races then
    return nil
  end
  return session.races[raceName]
end
-- AI lap counting: returns { inRaceTime, vehicles = { { index, session.lapCount, totalLaps, lapTimes, lastLapTime, finished, finishTime, currentLapTime }, ... } } or nil. Use from console to gauge AI times.
M.getAiLapState = function()
  if circuitRaceAi then
    return circuitRaceAi.getAiLapStateForDisplay()
  end
  return nil
end

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded

M.clearFreSummarySession = function()
  if raceSession then
    raceSession.clearFreSummarySession()
  end
end

M.startSanctionedRaceDispatch = function(useAltRoute, poolReferenceHpOverride)
  if not session or not utils or not competitiveTrackFlow then
    return
  end
  if not session.races then
    session.races = utils.loadRaceData()
  end
  preloadFreeroamAiPathsForTrack()
  session.staged = nil
  notifyFreContractsFreeroamUi()
  competitiveTrackFlow.resetTrackGridFlowFlags()
  trackFlowState.sanctionedPoolRefHp = (type(poolReferenceHpOverride) == "number" and poolReferenceHpOverride > 0) and
                                         poolReferenceHpOverride or nil
  trackFlowState.sanctionedRaceLapCount = nil
  if gameplay_events_freContracts_sanctionedRacing and
    gameplay_events_freContracts_sanctionedRacing.getSanctionedOfferLapCount then
    local lc = gameplay_events_freContracts_sanctionedRacing.getSanctionedOfferLapCount()
    if lc then
      trackFlowState.sanctionedRaceLapCount = lc
    end
  end
  trackFlowState.inTrackFlowContext = true
  trackFlowState.useAltRoute = useAltRoute == true
  competitiveTrackFlow.setSanctionedCareerGoToRaceActive(true)
  hideStagedFlashMessage()
  if core_groundMarkers and core_groundMarkers.resetAll then
    core_groundMarkers.resetAll()
  end
  session.saveGameState = true
  core_gamestate.requestGameState()
  applySavedStagingSpotNavigation()
end

M.beginFreeroamRace = beginFreeroamRace
M.hideStagedFlashMessage = hideStagedFlashMessage
M.hideAllFreeroamAssets = function()
  if Assets then
    Assets:hideAllAssets()
  end
end

M.clearSanctionedDispatchStaging = function()
  if not session or session.mActiveRace then
    return
  end
  session.staged = nil
  if raceSession and raceSession.setStagingSubjectId then
    raceSession.setStagingSubjectId(nil)
  end
  if utils and utils.setActiveLight then
    utils.setActiveLight(TRACK_RACE_ID, "red")
  end
  if raceSession and raceSession.hideFreeroamRaceHud then
    raceSession.hideFreeroamRaceHud()
  end
  hideStagedFlashMessage()
  M.hideAllFreeroamAssets()
  if competitiveTrackFlow and competitiveTrackFlow.clearSanctionedNavigateVisuals then
    competitiveTrackFlow.clearSanctionedNavigateVisuals()
  end
  notifyFreContractsFreeroamUi()
end

M.getFreeroamRaceLabel = getRaceLabel
M.getFreeroamDisplayRaceLabel = getDisplayRaceLabel

return M
