-- Race start, standings, exit settlement and proxy-fleet cleanup for one host load.
-- Read bindings/identity, result/start operations, ordered settlement, cleanup, exit and returned services.
local capabilities = require("overhaul/lib/platform/capabilities")
local eventHelpers = require("overhaul/lib/events/helpers")
local driftScoreReader = require("overhaul/lib/events/driftScore")

local M = {}

function M.create(ownerServices)

  -- Child modules and track-flow state: host.lua fills one table in place each time it binds its children.
  local hostRefs = {}

  local instance = {}

  -- Give each run/lap/finish/abort its existing id so consumers can reject repeated notifications.
  local resultIds = require("overhaul/lib/events/resultIdentity").create("freeroam")
  local resultRun = nil

  function instance.bind(refs)
    hostRefs = refs
  end

  local function getRaceLabel()
    local race = hostRefs.session.races[hostRefs.session.mActiveRace]
    local raceLabel = race.label
    if hostRefs.session.mAltRoute then raceLabel = race.altRoute.label end
    if hostRefs.session.mHotlap == hostRefs.session.mActiveRace then raceLabel = raceLabel .. " (Hotlap)" end
    return raceLabel
  end

  local function getDisplayRaceLabel()
    local race = hostRefs.session.races[hostRefs.session.mActiveRace]
    if not race then return "" end
    local raceLabel = race.label
    if hostRefs.session.mAltRoute and race.altRoute then raceLabel = race.altRoute.label end
    return raceLabel or ""
  end

  local function getDriftScore()
    return driftScoreReader.take(gameplay_drift_scoring, gameplay_drift_general)
  end

  local function getRouteDisplayName(race, isAlt)
    if not race then return nil end
    if isAlt and race.altRoute and race.altRoute.label then return race.altRoute.label end
    return race.label
  end

  local function shouldUseAltRouteForNextLap(raceName)
    if not hostRefs.competitiveTrackFlow.raceUsesSanctionedParkingStaging(raceName) then return false end
    local sanctionedRacing = overhaul_events_fre_sanctionedRacing
    local sanctionedCircuit = sanctionedRacing
      and sanctionedRacing.isSanctionedCircuitRaceActive
      and sanctionedRacing.isSanctionedCircuitRaceActive()
    local useAlt = (hostRefs.trackFlowState and hostRefs.trackFlowState.useAltRoute == true and hostRefs.trackFlowState.inTrackFlowContext)
      or false
    if sanctionedCircuit and sanctionedRacing and sanctionedRacing.isSanctionedCircuitRaceUseAltRoute then
      useAlt = sanctionedRacing.isSanctionedCircuitRaceUseAltRoute()
    end
    return useAlt
  end

  local function isAiSpawnedVehicle(subjectID)
    if not hostRefs.aiRacers or not hostRefs.aiRacers.getSpawnedVehicleIds then return false end
    for _, id in ipairs(hostRefs.aiRacers.getSpawnedVehicleIds()) do
      if id == subjectID then return true end
    end
    return false
  end

  local function hasAiStandingRows(rows)
    local hasAiRows = false
    if type(rows) == "table" then
      for _, row in ipairs(rows) do
        if row and row.isPlayer ~= true then
          hasAiRows = true
          break
        end
      end
    end
    return hasAiRows
  end

  local function fallbackRaceStandingRows(lapState, isLapRace, playerLapsCompleted, playerTotalTime, totalLaps)
    local rows = {}
    table.insert(rows, {
      isPlayer = true,
      lapCount = isLapRace and playerLapsCompleted or 1,
      lapsCompleted = isLapRace and playerLapsCompleted or 1,
      lapsTotal = totalLaps,
      totalTime = playerTotalTime,
      diffFromLeader = 0,
    })
    for vehId, vehicleLapState in pairs(lapState) do
      if type(vehicleLapState) == "table" then
        local aiTotalTimeSeconds = tonumber(vehicleLapState.finishTime)
        if not aiTotalTimeSeconds then
          local summedLapTimeSeconds = 0
          if type(vehicleLapState.lapTimes) == "table" and #vehicleLapState.lapTimes > 0 then
            for _, lapTimeSeconds in ipairs(vehicleLapState.lapTimes) do
              if type(lapTimeSeconds) == "number" and lapTimeSeconds > 0 then
                summedLapTimeSeconds = summedLapTimeSeconds + lapTimeSeconds
              end
            end
          end
          aiTotalTimeSeconds = (summedLapTimeSeconds > 0) and summedLapTimeSeconds or (playerTotalTime + 60)
        end
        table.insert(rows, {
          isPlayer = false,
          index = #rows,
          vehId = vehId,
          lapCount = tonumber(vehicleLapState.lapCount) or 0,
          lapsCompleted = tonumber(vehicleLapState.lapCount) or 0,
          lapsTotal = tonumber(vehicleLapState.totalLaps) or totalLaps,
          checkpointsHit = tonumber(vehicleLapState.checkpointsHit) or 0,
          finished = vehicleLapState.finished == true,
          totalTime = aiTotalTimeSeconds,
        })
      end
    end
    table.sort(rows, function(leftRow, rightRow)
      if (leftRow.finished == true) ~= (rightRow.finished == true) then return leftRow.finished == true end
      local leftLaps, rightLaps = tonumber(leftRow.lapCount) or 0, tonumber(rightRow.lapCount) or 0
      if leftLaps ~= rightLaps then return leftLaps > rightLaps end
      local leftCheckpoints, rightCheckpoints =
        tonumber(leftRow.checkpointsHit) or 0, tonumber(rightRow.checkpointsHit) or 0
      if leftCheckpoints ~= rightCheckpoints then return leftCheckpoints > rightCheckpoints end
      return (tonumber(leftRow.totalTime) or math.huge) < (tonumber(rightRow.totalTime) or math.huge)
    end)      return rows
  end

  local function buildAiRaceResultRow(place, row, lapState, isLapRace, playerLapsCompleted, playerBestLap, totalLaps, leaderTime, MIN_LAP_SECONDS)
    local bestLap = nil
    if not row.isPlayer then
      local spawnedVehicleIndex = tonumber(row.index)
      local vehId = row.vehId
        or (
          (
            spawnedVehicleIndex
            and hostRefs.aiRacers.getSpawnedVehicleIds
            and hostRefs.aiRacers.getSpawnedVehicleIds()[spawnedVehicleIndex]
          ) or nil
        )
      local vehicleLapState = vehId and lapState[vehId] or nil
      if vehicleLapState and vehicleLapState.lapTimes and #vehicleLapState.lapTimes > 0 then
        for _, lapTimeSeconds in ipairs(vehicleLapState.lapTimes) do
          if type(lapTimeSeconds) == "number" and lapTimeSeconds >= MIN_LAP_SECONDS then
            bestLap = (bestLap == nil or lapTimeSeconds < bestLap) and lapTimeSeconds or bestLap
          end
        end
      end
    else
      bestLap = playerBestLap
    end
    local resultRow = {
      place = place,
      isPlayer = row.isPlayer,
      lapsCompleted = row.lapsCompleted
        or row.lapCount
        or (row.isPlayer and (isLapRace and playerLapsCompleted or 1) or 0),
      lapsTotal = row.lapsTotal or totalLaps,
      totalTime = row.totalTime,
      bestLap = bestLap,
    }
    if not row.isPlayer then resultRow.index = row.index end
    resultRow.diffFromLeader = type(row.diffFromLeader) == "number" and row.diffFromLeader
      or ((row.totalTime or 0) - leaderTime)
    return resultRow
  end

  local function buildAiResultsFromRaceState(isLapRace, playerLapsCompleted, playerTotalTime, playerBestLap, totalLaps)
    if not (hostRefs.circuitRaceAi.hasAiLapState() and hostRefs.aiRacers and hostRefs.aiRacers.getSpawnedVehicleIds) then return nil end
    local MIN_LAP_SECONDS = 15
    local lapState = hostRefs.circuitRaceAi.getAiLapStateTable() or {}
    local standings = hostRefs.circuitRaceAi.getAiLapStateForDisplay and hostRefs.circuitRaceAi.getAiLapStateForDisplay() or nil
    local rows = (standings and standings.vehicles) or {}
    if not hasAiStandingRows(rows) then
      rows = fallbackRaceStandingRows(lapState, isLapRace, playerLapsCompleted, playerTotalTime, totalLaps)
    end
    local leaderTime = (rows[1] and rows[1].totalTime) and rows[1].totalTime or 0
    local aiResults = {}
    for place, row in ipairs(rows) do
      table.insert(aiResults, buildAiRaceResultRow(place, row, lapState, isLapRace, playerLapsCompleted,
        playerBestLap, totalLaps, leaderTime, MIN_LAP_SECONDS))
    end
    return aiResults
  end

  local function initializeFreeroamRace(raceNameArg, raceName, subjectID)
    hostRefs.session.staged = nil
    hostRefs.raceSession.setStagingSubjectId(nil)
    if hostRefs.aiRacers and hostRefs.aiRacers.setPlayerFreeze then hostRefs.aiRacers.setPlayerFreeze(false) end
    if overhaul_career_career.isActive() then overhaul_career_economy_pauseTime.enablePauseCounter(true) end
    hostRefs.session.initialVehicleDamage = hostRefs.utils.getVehicleDamage()
    hostRefs.utils.saveAndSetTrafficAmount(0)
    hostRefs.checkpointManager.setRace(hostRefs.session.races[raceName], raceName)
    hostRefs.Assets:displayAssets({
      subjectID = subjectID,
      assets = hostRefs.session.races[raceName].assets,
      triggerName = "fre_start_" .. raceName,
    })
    hostRefs.session.timerActive = true
    hostRefs.session.in_race_time = 0
    hostRefs.session.maxSpeed = 0
    hostRefs.session.mActiveRace = raceName
    resultRun = resultIds.beginRun(raceName)
    if overhaul_events_fre_sanctionedRacing then
      if overhaul_events_fre_sanctionedRacing.traceBeginFromFreeroam then
        overhaul_events_fre_sanctionedRacing.traceBeginFromFreeroam(raceNameArg)
      end
      if overhaul_events_fre_sanctionedRacing.onRaceBegin then
        overhaul_events_fre_sanctionedRacing.onRaceBegin(raceName)
      end
    end
    if hostRefs.competitiveTrackFlow.raceUsesSanctionedParkingStaging(raceName) then
      hostRefs.competitiveTrackFlow.clearSanctionedCareerGoToRaceActive()
      hostRefs.competitiveTrackFlow.onTrackRaceBeganFromRacingTeamProxy()
    end
  end

  local function prepareFreeroamRacePresentation(raceName, subjectID)
    hostRefs.raceSession.prepareNewRaceHudState(raceName)
    local useRaceHud = hostRefs.raceSession.raceHudApplies(hostRefs.session.races[raceName])
    if useRaceHud and not hostRefs.raceSession.isRaceHudShown() then hostRefs.raceSession.showFreeroamRaceHud() end
    hostRefs.session.lapCount = 0
    hostRefs.session.mCurrentRouteName = nil
    hostRefs.session.mTotalRaceTime = 0
    hostRefs.session.mBestLapThisRun = nil
    hostRefs.session.mSuppressOffRoadExitUntil = os.time() + 5
    if overhaul_career_career.isActive() then
      hostRefs.session.mInventoryId = overhaul_career_business_fleet.resolveFreeroamLeaderboardInventoryId(subjectID)
    else
      hostRefs.session.mInventoryId = subjectID
    end
    hostRefs.session.invalidLap = false
    if useRaceHud then
      hostRefs.raceSession.setRaceHudBanner(hostRefs.utils.getRaceStartBannerText(raceName), "good", 5)
      hostRefs.raceSession.pushFreeroamRaceHudState(true)
    else
      hostRefs.utils.displayStartMessage(raceName)
    end
  end

  local function startRaceDriftScoring(raceName, subjectID)
    hostRefs.utils.setActiveLight(raceName, "green")
    local startingRace = hostRefs.session.races[raceName]
    local isFreDrift = startingRace
      and ((startingRace.type and eventHelpers.tableContains(startingRace.type, "drift")) or startingRace.driftGoal)
    if isFreDrift then
      if gameplay_drift_general and gameplay_drift_general.reset then gameplay_drift_general.reset() end
      if gameplay_drift_drift then gameplay_drift_drift.setVehId(subjectID) end
    end
    return isFreDrift
  end

  local function notifyAndRefreshRaceStart(raceName, subjectID, isFreDrift)
    extensions.hook("onFreeroamSessionStarted", {
      raceName = raceName,
      subjectID = subjectID,
      race = hostRefs.session.races[raceName],
      checkpointRoad = hostRefs.session.races[raceName].checkpointRoad,
    })
    ownerServices.notifyFreContractsFreeroamUi()
    if
      hostRefs.competitiveTrackFlow
      and hostRefs.competitiveTrackFlow.isRacingTeamProxyRaceSessionActive
      and hostRefs.competitiveTrackFlow.isRacingTeamProxyRaceSessionActive()
      and hostRefs.competitiveTrackFlow.refreshRacingTeamProxySpectatorUiMinimalIfActive
    then
      hostRefs.competitiveTrackFlow.refreshRacingTeamProxySpectatorUiMinimalIfActive()
      core_jobsystem.create(function(job)
        job.sleep(0.12)
        if hostRefs.competitiveTrackFlow and hostRefs.competitiveTrackFlow.refreshRacingTeamProxySpectatorUiMinimalIfActive then
          hostRefs.competitiveTrackFlow.refreshRacingTeamProxySpectatorUiMinimalIfActive()
        end
        job.sleep(0.35)
        if hostRefs.competitiveTrackFlow and hostRefs.competitiveTrackFlow.refreshRacingTeamProxySpectatorUiMinimalIfActive then
          hostRefs.competitiveTrackFlow.refreshRacingTeamProxySpectatorUiMinimalIfActive()
        end
      end)
    end
    if isFreDrift then
      ownerServices.suppressVanillaDriftMissionUi()
      core_jobsystem.create(function(job)
        job.sleep(0.2)
        ownerServices.suppressVanillaDriftMissionUi()
      end)
    end
  end

  local function beginFreeroamRace(raceNameArg, subjectID)
    if hostRefs.utils.isExternalActivityBlockingFreeroam() then return end
    if hostRefs.session.mActiveRace ~= nil and hostRefs.session.mActiveRace == raceNameArg then return end
    if not hostRefs.session.races[raceNameArg] then
      if
        overhaul_events_fre_sanctionedRacing
        and overhaul_events_fre_sanctionedRacing.traceBeginFromFreeroamEarlyExitNoRace
      then
        overhaul_events_fre_sanctionedRacing.traceBeginFromFreeroamEarlyExitNoRace(raceNameArg)
      end
      return
    end
    local raceName = raceNameArg
    if hostRefs.competitiveTrackFlow.raceUsesSanctionedParkingStaging(raceName)
      and hostRefs.competitiveTrackFlow.getCompetitiveRaceId() ~= raceName then
      local ok, reason = hostRefs.competitiveTrackFlow.setCompetitiveRace(raceName, shouldUseAltRouteForNextLap(raceName))
      if not ok then hostRefs.utils.displayMessage(reason, 5); return false end
    end
    initializeFreeroamRace(raceNameArg, raceName, subjectID)
    prepareFreeroamRacePresentation(raceName, subjectID)
    local isFreDrift = startRaceDriftScoring(raceName, subjectID)
    notifyAndRefreshRaceStart(raceName, subjectID, isFreDrift)
  end

  local function applySavedStagingSpotNavigation()
    local spot = hostRefs.competitiveTrackFlow.loadPlayerStagingSpot()
    if not spot or not spot.pos then return end
    hostRefs.competitiveTrackFlow.setPlayerStagingSpot(spot)
    if core_groundMarkers and core_groundMarkers.setPath then
      core_groundMarkers.setPath(vec3(spot.pos[1], spot.pos[2], spot.pos[3]), {
        clearPathOnReachingTarget = false,
      })
    end
    hostRefs.competitiveTrackFlow.showPlayerStagingCornerMarkers(spot)
  end

  --- Legacy hook from celebrationPopUp; no-op. Proxy track completion uses settle + celebration, then optional cinematic fade.
  local function runDeferredProxyRaceCompletion() end

  local function resolveRaceExitLapCount(isLapRace, effectiveRace, erSession)
    local totalLaps = 1
    if isLapRace then
      totalLaps = ownerServices.getDisplayTotalLapsForRace(effectiveRace)
      if totalLaps < 1 then
        local lc = erSession and erSession.lapCount
        totalLaps = (type(lc) == "number" and lc > 0) and lc or hostRefs.session.lapCount
      end
      if totalLaps < 1 then totalLaps = hostRefs.session.lapCount end
    end

    return totalLaps
  end

  local function displayCompletedRaceExit(effectiveRace, subjectID, raceName, useRaceHud, customMessage)
    if eventHelpers.raceHasType(effectiveRace, "drag") and subjectID and not useRaceHud and hostRefs.utils.updateDisplay then
      local side = "l"
      hostRefs.utils.updateDisplay(
        side,
        hostRefs.session.in_race_time,
        math.abs(be:getObjectVelocityXYZ(subjectID)) * hostRefs.session.speedUnit
      )
    end

    if effectiveRace and effectiveRace.type and eventHelpers.tableContains(effectiveRace.type, "drift") then
      local finalScore = getDriftScore()
      if gameplay_drift_general.getContext() == "inChallenge" then gameplay_drift_general.setContext("inFreeroam") end
    end

    if customMessage then hostRefs.utils.displayMessage(customMessage, 10) end
  end

  local function completedRaceExitResult(effectiveRace, subjectID, raceName, useRaceHud, displayLabel, isLapRace, erSession, resultId, customMessage)
    local finalResult, hudCompletionPl
    if
      hostRefs.session.in_race_time and (hostRefs.session.mBestLapThisRun == nil or hostRefs.session.in_race_time < hostRefs.session.mBestLapThisRun)
    then
      hostRefs.session.mBestLapThisRun = hostRefs.session.in_race_time
    end
    local rewardData
    rewardData, hudCompletionPl = hostRefs.raceSession.payoutRace(nil, resultId)
    local rewardAmt = 0
    if type(rewardData) == "number" then rewardAmt = rewardData end

    local totalTime = (hostRefs.session.mTotalRaceTime or 0) + hostRefs.session.in_race_time
    local totalLaps = resolveRaceExitLapCount(isLapRace, effectiveRace, erSession)

    finalResult = {
      raceLabel = displayLabel,
      lapsCompleted = isLapRace and hostRefs.session.lapCount or 1,
      lapsTotal = totalLaps,
      totalTime = totalTime,
      bestLap = hostRefs.session.mBestLapThisRun,
      newBest = hostRefs.session.newBestSession,
      invalidLap = hostRefs.session.invalidLap,
      reward = rewardAmt,
      xp = 0,
      leaderboard = {},
    }
    local aiResults =
      buildAiResultsFromRaceState(isLapRace, hostRefs.session.lapCount, totalTime, hostRefs.session.mBestLapThisRun, totalLaps)
    if aiResults then finalResult.aiResults = aiResults end
    if hudCompletionPl and hudCompletionPl.rewards and hudCompletionPl.rewards.disciplineXp then
      finalResult.xp = math.floor(tonumber(hudCompletionPl.rewards.disciplineXp) or 0)
    end

    displayCompletedRaceExit(effectiveRace, subjectID, raceName, useRaceHud, customMessage)
    return finalResult, hudCompletionPl
  end

  local function abortedRaceExitResult(customMessage, effectiveRace, displayLabel)
    local finalResult
    local message = customMessage or "You exited the race zone, Race cancelled"
    hostRefs.utils.displayMessage(message, 3)
    if hostRefs.session.lapCount >= 1 and effectiveRace then
      local rd = effectiveRace
      local rdSession = rd and rd.session
      local isLap = rd and ((rdSession and rdSession.lapCount and rdSession.lapCount > 0) or rd.hotlap)
      local totalTimePartial = (hostRefs.session.mTotalRaceTime or 0) + hostRefs.session.in_race_time
      local totalLaps = 1
      if isLap then
        totalLaps = ownerServices.getDisplayTotalLapsForRace(rd)
        if totalLaps < 1 then
          local lc = rdSession and rdSession.lapCount
          totalLaps = (type(lc) == "number" and lc > 0) and lc or hostRefs.session.lapCount
        end
        if totalLaps < 1 then totalLaps = hostRefs.session.lapCount end
      end
      finalResult = {
        raceLabel = displayLabel,
        lapsCompleted = isLap and hostRefs.session.lapCount or 1,
        lapsTotal = totalLaps,
        totalTime = totalTimePartial,
        bestLap = hostRefs.session.mBestLapThisRun,
        newBest = false,
        invalidLap = hostRefs.session.invalidLap,
        reward = 0,
        xp = 0,
        leaderboard = {},
      }
      local aiResultsAbort =
        buildAiResultsFromRaceState(isLap, hostRefs.session.lapCount, totalTimePartial, hostRefs.session.mBestLapThisRun, totalLaps)
      if aiResultsAbort then finalResult.aiResults = aiResultsAbort end
    end
    return finalResult
  end

  local function resolveRaceExitResult(
    isCompletion, customMessage, effectiveRace, subjectID, raceName,
    useRaceHud, displayLabel, isLapRace, erSession, resultId
  )
    if isCompletion then
      return completedRaceExitResult(effectiveRace, subjectID, raceName, useRaceHud, displayLabel,
        isLapRace, erSession, resultId, customMessage)
    end
    return abortedRaceExitResult(customMessage, effectiveRace, displayLabel), nil
  end

  local function prepareProxyRaceExit(raceName, isCompletion, deferResultScreen)
    local proxyCleanup = nil
    local useProxyCinematicEnd = false
    --- Read before takeRacingTeamProxyRaceSessionCleanup() clears session (leave/cancel/finish all need fleet ids for part save).
    local racingTeamFleetSnapshot = nil
    if
      hostRefs.competitiveTrackFlow.raceUsesSanctionedParkingStaging(raceName)
      and hostRefs.competitiveTrackFlow.getRacingTeamProxyRaceSessionSnapshot
    then
      racingTeamFleetSnapshot = hostRefs.competitiveTrackFlow.getRacingTeamProxyRaceSessionSnapshot()
    end
    if hostRefs.competitiveTrackFlow.raceUsesSanctionedParkingStaging(raceName) then
      if isCompletion and deferResultScreen and hostRefs.competitiveTrackFlow.getRacingTeamProxyRaceSessionSnapshot then
        local snap = racingTeamFleetSnapshot or hostRefs.competitiveTrackFlow.getRacingTeamProxyRaceSessionSnapshot()
        if snap and snap.businessId and ui_fadeScreen and ui_fadeScreen.start and ui_fadeScreen.stop then
          useProxyCinematicEnd = true
          proxyCleanup = snap
        end
      end
      if not useProxyCinematicEnd and hostRefs.competitiveTrackFlow.takeRacingTeamProxyRaceSessionCleanup then
        proxyCleanup = hostRefs.competitiveTrackFlow.takeRacingTeamProxyRaceSessionCleanup()
      end
    end
    if
      not (proxyCleanup and proxyCleanup.businessId and proxyCleanup.fleetVehicleId)
      and racingTeamFleetSnapshot
      and racingTeamFleetSnapshot.businessId
      and racingTeamFleetSnapshot.fleetVehicleId
    then
      proxyCleanup = {
        businessId = racingTeamFleetSnapshot.businessId,
        fleetVehicleId = racingTeamFleetSnapshot.fleetVehicleId,
      }
    end
    -- Use the saved proxy snapshot because AI finishes can borrow the player vehicle id.

    local useProxyFinishLoadingOverlay = not useProxyCinematicEnd
      and proxyCleanup
      and proxyCleanup.businessId
      and isCompletion

    if useProxyFinishLoadingOverlay then core_gamestate.requestEnterLoadingScreen("rlsProxyRaceFinish") end

    return proxyCleanup, useProxyCinematicEnd, racingTeamFleetSnapshot, useProxyFinishLoadingOverlay
  end

  local function settleProxyExitRewards(proxyCleanup, isCompletion, resultId, finalResult, hudCompletionPl)
    local settlement = proxyCleanup and proxyCleanup.businessId and isCompletion
      and capabilities.get("raceProxySettlement")
    if settlement and settlement.settleProxySanctionedRaceFromAiResults then
      local pr = settlement.settleProxySanctionedRaceFromAiResults(
        proxyCleanup.businessId,
        finalResult and finalResult.aiResults,
        resultId
      )
      if pr and type(pr) == "table" and finalResult then
        finalResult.reward = math.floor(tonumber(pr.money) or 0)
        finalResult.xp = math.floor(tonumber(pr.businessSkillXp) or 0)
        if type(pr.noRewardDetail) == "string" and pr.noRewardDetail ~= "" then
          finalResult.sanctionedNoRewardDetail = pr.noRewardDetail
        end
        if not hudCompletionPl or type(hudCompletionPl) ~= "table" then hudCompletionPl = {} end
        if not hudCompletionPl.rewards then hudCompletionPl.rewards = {} end
        hudCompletionPl.rewards.money = math.floor(tonumber(pr.money) or 0)
        hudCompletionPl.rewards.disciplineXp = math.max(0, math.floor(tonumber(pr.businessSkillXp) or 0))
        if type(pr.noRewardDetail) == "string" and pr.noRewardDetail ~= "" then
          hudCompletionPl.sanctionedNoRewardDetail = pr.noRewardDetail
        end
      end
    end

    return hudCompletionPl
  end

  local function clearProxyExitAssignments(raceName, isCompletion, proxyCleanup, useProxyCinematicEnd, useProxyFinishLoadingOverlay)
    if not useProxyCinematicEnd then
      if proxyCleanup and proxyCleanup.businessId then
        local racingTeam = overhaul_career_business_racingTeam_racingTeam
        if racingTeam and racingTeam.getProxyDriverRaceRequest and racingTeam.clearRacingTeamProxyDriverAssignment then
          local bid = proxyCleanup.businessId
          local proxyReq = racingTeam.getProxyDriverRaceRequest(bid)
          racingTeam.clearRacingTeamProxyDriverAssignment(bid, {
            returnOfferToBoard = not isCompletion,
            proxyRequest = proxyReq,
          })
        end
      elseif isCompletion and hostRefs.competitiveTrackFlow.raceUsesSanctionedParkingStaging(raceName)
        and not (proxyCleanup and proxyCleanup.businessId) then
        local racingTeam = overhaul_career_business_racingTeam_racingTeam
        if racingTeam and racingTeam.clearStuckRacingTeamProxyAfterTrackRaceCompletion then
          racingTeam.clearStuckRacingTeamProxyAfterTrackRaceCompletion(raceName)
        end
      end

      local proxyFlow = overhaul_career_business_racingTeam_raceFlow
      if proxyCleanup and proxyCleanup.businessId and proxyFlow and proxyFlow.clearProxyDriverRaceRequest then
        proxyFlow.clearProxyDriverRaceRequest(proxyCleanup.businessId)
      end

      if useProxyFinishLoadingOverlay and core_gamestate.getLoadingStatus("rlsProxyRaceFinish") then
        core_gamestate.requestExitLoadingScreen("rlsProxyRaceFinish")
      end
    end
  end

  local function traceRaceExitSettlement(raceName, isCompletion, proxyCleanup, finalResult)
    do
      local srMod = overhaul_events_fre_sanctionedRacing
      local suppressNow = srMod and srMod.shouldSuppressFrePayouts and srMod.shouldSuppressFrePayouts()
      log(
        "I",
        "freeroamEvents",
        string.format(
          "race finish settle-route raceName=%s isCompletion=%s proxyCleanup=%s proxyBid=%s suppressFrePayouts=%s aiResults=%s",
          tostring(raceName),
          tostring(isCompletion == true),
          tostring(proxyCleanup ~= nil),
          tostring(proxyCleanup and proxyCleanup.businessId),
          tostring(suppressNow == true),
          tostring(finalResult and finalResult.aiResults ~= nil)
        )
      )
    end
  end

  local function settleSanctionedExitRewards(raceName, isCompletion, resultId, proxyCleanup, finalResult)
    if overhaul_events_fre_sanctionedRacing and not proxyCleanup then
      if isCompletion and finalResult and finalResult.aiResults then
        overhaul_events_fre_sanctionedRacing.settleFromAiResults(finalResult.aiResults, raceName, resultId)
      elseif not isCompletion then
        overhaul_events_fre_sanctionedRacing.onRaceAborted()
      elseif isCompletion then
        overhaul_events_fre_sanctionedRacing.settleFromAiResults(nil, raceName, resultId)
      end
    elseif overhaul_events_fre_sanctionedRacing and proxyCleanup and not isCompletion then
      overhaul_events_fre_sanctionedRacing.onRaceAborted()
    end
  end

  local function applySanctionedExitCelebration(proxyCleanup, isCompletion, finalResult, hudCompletionPl)
    local srCelebration = not proxyCleanup
      and isCompletion
      and overhaul_events_fre_sanctionedRacing
      and overhaul_events_fre_sanctionedRacing.consumeSanctionedCelebrationRewards
      and overhaul_events_fre_sanctionedRacing.consumeSanctionedCelebrationRewards()
    if srCelebration and type(srCelebration.money) == "number" and finalResult then
      finalResult.reward = srCelebration.money
      if type(srCelebration.noRewardDetail) == "string" and srCelebration.noRewardDetail ~= "" then
        finalResult.sanctionedNoRewardDetail = srCelebration.noRewardDetail
      end
      if hudCompletionPl and type(hudCompletionPl) == "table" then
        if not hudCompletionPl.rewards then hudCompletionPl.rewards = {} end
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

    return hudCompletionPl
  end

  local function settleExitRaceRewards(
    raceName, isCompletion, resultId, proxyCleanup, useProxyCinematicEnd, useProxyFinishLoadingOverlay,
    finalResult, hudCompletionPl
  )
    hudCompletionPl = settleProxyExitRewards(proxyCleanup, isCompletion, resultId, finalResult, hudCompletionPl)
    clearProxyExitAssignments(raceName, isCompletion, proxyCleanup, useProxyCinematicEnd, useProxyFinishLoadingOverlay)
    traceRaceExitSettlement(raceName, isCompletion, proxyCleanup, finalResult)
    settleSanctionedExitRewards(raceName, isCompletion, resultId, proxyCleanup, finalResult)
    return applySanctionedExitCelebration(proxyCleanup, isCompletion, finalResult, hudCompletionPl)
  end

  local function prepareRaceExitState(raceName, cpRoad, isCompletion, resultId, deferResultScreen, deferHudHide)
    hostRefs.utils.setActiveLight(raceName, "red")
    hostRefs.session.lapCount = 0
    hostRefs.session.timerActive = false
    hostRefs.session.mHotlap = nil
    hostRefs.session.currCheckpoint = nil
    hostRefs.session.mSplitTimes = {}
    hostRefs.session.mAltRoute = false
    hostRefs.session.mCurrentRouteName = nil
    hostRefs.session.invalidLap = false
    hostRefs.session.mInventoryId = nil
    hostRefs.session.maxSpeed = 0
    hostRefs.session.mTotalRaceTime = 0
    hostRefs.session.mBestLapThisRun = nil
    hostRefs.session.mSuppressOffRoadExitUntil = 0

    hostRefs.session.mActiveRace = nil
    ownerServices.notifyFreContractsFreeroamUi()
    local hideHudNow = deferResultScreen or not deferHudHide
    local exitingPayload = {
      raceName = raceName,
      checkpointRoad = cpRoad,
      isCompletion = isCompletion,
      resultId = resultId,
    }

    return hideHudNow, exitingPayload
  end

  local function scheduleRaceAiAndTrafficCleanup(trafficStamp, deferResultScreen)
    if hostRefs.aiRacers and hostRefs.aiRacers.setDnfCallback then hostRefs.aiRacers.setDnfCallback(nil) end
    if deferResultScreen and hostRefs.aiRacers and hostRefs.aiRacers.scheduleDelayedDespawn then
      hostRefs.aiRacers.scheduleDelayedDespawn(50)
      local spawnGeneration = hostRefs.aiRacers.getSpawnGeneration and hostRefs.aiRacers.getSpawnGeneration() or nil
      core_jobsystem.create(function(job)
        job.sleep(15)
        local sameGrid = not (hostRefs.aiRacers and hostRefs.aiRacers.getSpawnGeneration)
          or hostRefs.aiRacers.getSpawnGeneration() == spawnGeneration
        if sameGrid and hostRefs.aiRacers and hostRefs.aiRacers.clearSpawned then hostRefs.aiRacers.clearSpawned() end
        core_jobsystem.create(function(innerJob)
          innerJob.sleep(10)
          ownerServices.restoreTrafficIfCurrent(trafficStamp)
        end)
      end)
    else
      if hostRefs.aiRacers and hostRefs.aiRacers.clearSpawned then hostRefs.aiRacers.clearSpawned() end
      core_jobsystem.create(function(job)
        job.sleep(10)
        ownerServices.restoreTrafficIfCurrent(trafficStamp)
      end)
    end
  end

  local function restoreRaceExitAfterFleet(raceName, hideHudNow, deferResultScreen, deferHudHide)
    local trafficStamp = ownerServices.trafficRestoreStamp()
    if hideHudNow then hostRefs.raceSession.hideFreeroamRaceHud() end
    hostRefs.Assets:hideAllAssets()

    scheduleRaceAiAndTrafficCleanup(trafficStamp, deferResultScreen)

    hostRefs.pits.clearSpeedLimit()
    hostRefs.session.newBestSession = false
    hostRefs.trackFlowState.sanctionedRaceLapCount = nil
    if hostRefs.competitiveTrackFlow.raceUsesSanctionedParkingStaging(raceName) and hostRefs.competitiveTrackFlow.leaveTrackFlowAfterRace then
      hostRefs.competitiveTrackFlow.leaveTrackFlowAfterRace()
    end
    local exitedFreRace = hostRefs.session.races[raceName]
    if
      exitedFreRace
      and (
        (exitedFreRace.type and eventHelpers.tableContains(exitedFreRace.type, "drift")) or exitedFreRace.driftGoal
      )
    then
      gameplay_drift_general.setContext("inFreeroam")
      gameplay_drift_general.reset()
    end
    if overhaul_career_career.isActive() then overhaul_career_economy_pauseTime.enablePauseCounter() end
    if deferHudHide then
      core_jobsystem.create(function(job)
        job.sleep(18)
        if hostRefs.session.mActiveRace or hostRefs.session.staged then return end
        hostRefs.raceSession.hideFreeroamRaceHud()
      end)
    end
    if hostRefs.session.previousGameState then
      core_gamestate.setGameState(
        hostRefs.session.previousGameState.state,
        hostRefs.session.previousGameState.appLayout,
        hostRefs.session.previousGameState.menuItems,
        hostRefs.session.previousGameState.options
      )
      hostRefs.session.previousGameState = nil
      hostRefs.session.saveGameState = false
    end
  end

  local function createRaceExitCleanup(raceName, cpRoad, isCompletion, resultId, deferResultScreen, deferHudHide)
    local function runRaceExitCleanup(pcProxy)
      local hideHudNow, exitingPayload = prepareRaceExitState(
        raceName, cpRoad, isCompletion, resultId, deferResultScreen, deferHudHide
      )
      local function runRaceExitCleanupAfterFleet()
        restoreRaceExitAfterFleet(raceName, hideHudNow, deferResultScreen, deferHudHide)
      end
      -- Snapshot part conditions before session-exit hooks, then put away without a second getPartConditions save.
      if pcProxy and pcProxy.businessId and pcProxy.fleetVehicleId and overhaul_career_business_fleet then
        local inv = overhaul_career_business_fleet
        if inv.putAwayVehicle and inv.persistSpawnedFleetVehiclePartConditions then
          inv.persistSpawnedFleetVehiclePartConditions(pcProxy.businessId, pcProxy.fleetVehicleId, function()
            -- Restore player pre-race vehicle/transform before despawning the proxy fleet vehicle.
            extensions.hook("onFreeroamSessionExiting", exitingPayload)
            inv.putAwayVehicle(pcProxy.businessId, pcProxy.fleetVehicleId, nil, { skipPartConditionPersist = true })
            runRaceExitCleanupAfterFleet()
          end)
          return
        end
        if inv.putAwayVehicle then
          -- Keep the proxy car alive until exit hooks restore the player's pre-race state.
          extensions.hook("onFreeroamSessionExiting", exitingPayload)
          inv.putAwayVehicle(pcProxy.businessId, pcProxy.fleetVehicleId)
          runRaceExitCleanupAfterFleet()
          return
        end
      end

      extensions.hook("onFreeroamSessionExiting", exitingPayload)
      runRaceExitCleanupAfterFleet()
    end
    return runRaceExitCleanup
  end

  local function scheduleProxyCinematicExit(racingTeamFleetSnapshot, proxyCleanup, runRaceExitCleanup)
    core_jobsystem.create(function(job)
      job.sleep(4)
      if ui_fadeScreen and ui_fadeScreen.start then ui_fadeScreen.start(3) end
      job.sleep(3)
      local pc = nil
      if hostRefs.competitiveTrackFlow and hostRefs.competitiveTrackFlow.takeRacingTeamProxyRaceSessionCleanup then
        pc = hostRefs.competitiveTrackFlow.takeRacingTeamProxyRaceSessionCleanup()
      end
      if
        not (pc and pc.businessId and pc.fleetVehicleId)
        and racingTeamFleetSnapshot
        and racingTeamFleetSnapshot.businessId
        and racingTeamFleetSnapshot.fleetVehicleId
      then
        pc = {
          businessId = racingTeamFleetSnapshot.businessId,
          fleetVehicleId = racingTeamFleetSnapshot.fleetVehicleId,
        }
      end
      if pc and pc.businessId then
        local racingTeam = overhaul_career_business_racingTeam_racingTeam
        if racingTeam and racingTeam.getProxyDriverRaceRequest and racingTeam.clearRacingTeamProxyDriverAssignment then
          local proxyReq = racingTeam.getProxyDriverRaceRequest(pc.businessId)
          racingTeam.clearRacingTeamProxyDriverAssignment(pc.businessId, {
            returnOfferToBoard = false,
            proxyRequest = proxyReq,
          })
        end
      end
      local proxyFlow = overhaul_career_business_racingTeam_raceFlow
      if pc and pc.businessId and proxyFlow and proxyFlow.clearProxyDriverRaceRequest then
        proxyFlow.clearProxyDriverRaceRequest(pc.businessId)
      end
      local pcForTail = pc
      if
        not (pcForTail and pcForTail.businessId and pcForTail.fleetVehicleId)
        and proxyCleanup
        and proxyCleanup.businessId
        and proxyCleanup.fleetVehicleId
      then
        pcForTail = proxyCleanup
      end
      runRaceExitCleanup(pcForTail)
      if ui_fadeScreen and ui_fadeScreen.stop then ui_fadeScreen.stop(0) end
    end)
  end

  local function presentRaceExitResult(isCompletion, hudCompletionPl, deferResultScreen, raceName, displayLabel, raceLabel, finalResult)
    if isCompletion and hudCompletionPl and not deferResultScreen then
      hostRefs.raceSession.pushRaceHudCompletion(hudCompletionPl, raceName, displayLabel, raceLabel, hostRefs.session.in_race_time, true)
    end

    if deferResultScreen then
      guihooks.trigger("OpenFreRaceCompletionCelebration", {
        entry = hostRefs.raceSession.buildFreRaceCompletionCelebrationEntry(finalResult, hudCompletionPl),
      })
      guihooks.trigger("ScenarioFlashMessage", { msg = "", ttl = 0, clearQueue = true })
      ownerServices.hideStagedFlashMessage()
    end
    hostRefs.session.mPendingTrackResult = nil
  end

  local function exitRace(isCompletion, customMessage, raceData, subjectID)
    hostRefs.competitiveTrackFlow.cancelCompetitiveGridFlow()
    if not hostRefs.session.mActiveRace then return end
    local raceName = hostRefs.session.mActiveRace
    local resultId = resultIds.id(resultRun, isCompletion and "final" or "abort")
    resultRun = nil
    local cpRoad = hostRefs.session.races[raceName] and hostRefs.session.races[raceName].checkpointRoad
    local mainRace = hostRefs.session.races[raceName]
    local useRaceHud = mainRace and hostRefs.raceSession.raceHudApplies(mainRace)
    local effectiveRace = (mainRace and hostRefs.session.mAltRoute and mainRace.altRoute) and mainRace.altRoute
      or (raceData or mainRace or {})
    local erSession = effectiveRace and effectiveRace.session
    local raceLabel = getRaceLabel()
    local displayLabel = getDisplayRaceLabel()
    local isLapRace = effectiveRace
      and ((erSession and erSession.lapCount and erSession.lapCount > 0) or effectiveRace.hotlap)

    local finalResult, hudCompletionPl = resolveRaceExitResult(
      isCompletion, customMessage, effectiveRace, subjectID, raceName,
      useRaceHud, displayLabel, isLapRace, erSession, resultId
    )

    local hasSpawnedAi = (hostRefs.aiRacers and hostRefs.aiRacers.getSpawnedVehicleIds and (#(hostRefs.aiRacers.getSpawnedVehicleIds() or {}) > 0))
      or hostRefs.circuitRaceAi.hasAiLapState()
    local deferResultScreen = isCompletion and hasSpawnedAi and finalResult

    local proxyCleanup, useProxyCinematicEnd, racingTeamFleetSnapshot, useProxyFinishLoadingOverlay =
      prepareProxyRaceExit(raceName, isCompletion, deferResultScreen)

    hudCompletionPl = settleExitRaceRewards(
      raceName, isCompletion, resultId, proxyCleanup, useProxyCinematicEnd,
      useProxyFinishLoadingOverlay, finalResult, hudCompletionPl
    )

    local deferHudHide = isCompletion and useRaceHud and hudCompletionPl and not deferResultScreen

    local runRaceExitCleanup =
      createRaceExitCleanup(raceName, cpRoad, isCompletion, resultId, deferResultScreen, deferHudHide)

    presentRaceExitResult(isCompletion, hudCompletionPl, deferResultScreen, raceName, displayLabel, raceLabel, finalResult)
    hostRefs.raceSession.maybeShowFreerunSummary(cpRoad, isCompletion, deferResultScreen)

    if useProxyCinematicEnd then
      scheduleProxyCinematicExit(racingTeamFleetSnapshot, proxyCleanup, runRaceExitCleanup)
      return
    end

    runRaceExitCleanup(proxyCleanup)
  end

  instance.getRaceLabel = getRaceLabel
  instance.getDisplayRaceLabel = getDisplayRaceLabel
  instance.getDriftScore = getDriftScore
  instance.getRouteDisplayName = getRouteDisplayName
  instance.shouldUseAltRouteForNextLap = shouldUseAltRouteForNextLap
  instance.isAiSpawnedVehicle = isAiSpawnedVehicle
  instance.buildAiResultsFromRaceState = buildAiResultsFromRaceState
  instance.beginFreeroamRace = beginFreeroamRace
  instance.applySavedStagingSpotNavigation = applySavedStagingSpotNavigation
  instance.runDeferredProxyRaceCompletion = runDeferredProxyRaceCompletion
  instance.exitRace = exitRace
  -- Result id of the running race for `part` ("lap<N>"), nil when no race run is open.
  function instance.resultId(part)
    return resultIds.id(resultRun, part)
  end
  return instance
end

return M
