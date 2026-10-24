-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding

-- Race staging and trigger routing for player and AI start/checkpoint/finish events.
-- Read per-load bindings, staging operations, player/AI trigger handlers and the dispatcher.
local eventHelpers = require("overhaul/lib/events/helpers")

local capabilities = require("overhaul/lib/platform/capabilities")
local M = {}

function M.create(ownerServices)

  -- Child modules and track-flow state: host.lua fills one table in place each time it binds its children.
  local hostRefs = {}

  local instance = {}

  function instance.bind(refs)
    hostRefs = refs
  end

  local function canEnterFreeroamStaging(raceName, spawnVehId)
    if not hostRefs.session.races or not hostRefs.session.races[raceName] then return false end
    if hostRefs.utils.isPlayerInPursuit() then
      hostRefs.utils.displayMessage("You cannot stage for an event while in a pursuit.", 2)
      return false
    end
    local playerVehId = be:getPlayerVehicleID(0)
    if not spawnVehId or spawnVehId ~= playerVehId then return false end
    if hostRefs.utils.isCarJockeyVehicle(spawnVehId) then
      hostRefs.utils.displayMessage("Car Jockey vehicles cannot be used for events.", 3)
      return false
    end
    if hostRefs.utils.isExternalActivityBlockingFreeroam() then return false end

    local sanctionedRacing = overhaul_events_fre_sanctionedRacing
    if
      sanctionedRacing
      and sanctionedRacing.isSanctionedRescheduleActionActive
      and sanctionedRacing.isSanctionedRescheduleActionActive()
    then
      hostRefs.utils.displayMessage("Reschedule or finish your sanctioned race from the phone before staging for practice.", 4)
      return false
    end

    if
      hostRefs.competitiveTrackFlow.shouldBlockFreeroamStagingPractice
      and hostRefs.competitiveTrackFlow.shouldBlockFreeroamStagingPractice(raceName)
    then
      hostRefs.utils.displayMessage("Finish or leave sanctioned grid staging before using practice staging.", 4)
      return false
    end

    return true
  end

  local function prepareStagingVehicleSpeed(raceName, spawnVehId)
    hostRefs.session.saveGameState = true
    core_gamestate.requestGameState()

    local vehicleSpeed = ownerServices.getVehicleSpeedMph(spawnVehId)
    if vehicleSpeed > 5 and hostRefs.session.mActiveRace then return false end
    hostRefs.session.mHotlap = nil
    if vehicleSpeed > 5 then
      if hostRefs.session.races[raceName].runningStart then
        if hostRefs.raceSession.raceHudApplies(hostRefs.session.races[raceName]) then
          hostRefs.raceSession.setRaceHudBanner("Hotlap session.staged — roll to start", "info", 3)
        else
          hostRefs.utils.displayMessage("Hotlap Staged", 2)
        end
        if hostRefs.session.races[raceName].hotlap then hostRefs.session.mHotlap = raceName end
      else
        hostRefs.utils.displayMessage("You are too fast to stage.\nPlease back up and slow down to stage.", 2)
        hostRefs.session.staged = nil
        return false
      end
    end
    return true
  end

  local function stagingRaceIsEnabled(raceName)
    local allTypesDisabled = false
    local disabledTypes = {}
    if hostRefs.session.races[raceName].type then
      local totalTypes = 0
      local disabledCount = 0
      for _, raceType in ipairs(hostRefs.session.races[raceName].type) do
        totalTypes = totalTypes + 1
        local multiplier = overhaul_career_economyAdjuster.getEffectiveSectionMultiplier({ raceType })
        if multiplier == 0 then
          disabledCount = disabledCount + 1
          table.insert(disabledTypes, raceType)
        end
      end
      allTypesDisabled = totalTypes > 0 and disabledCount == totalTypes
    end

    if allTypesDisabled then
      local typesString = table.concat(disabledTypes, ", ")
      hostRefs.utils.displayMessage(
        string.format(
          "%s is disabled due to %s multiplier(s) being set to 0.",
          hostRefs.session.races[raceName].label,
          typesString
        ),
        5
      )
      return false
    end

    return true
  end

  local function commitStagingVehicle(raceName, spawnVehId)
      hostRefs.session.staged = raceName
      hostRefs.session.freeroamPracticeStaging = true
      local vehId = spawnVehId
      if overhaul_career_career.isActive() then
        local businessVehicles = capabilities.get("businessVehicles")
        local businessId, vehicleId = businessVehicles.getBusinessVehicleFromSpawnedId(spawnVehId)
        if businessId and vehicleId then
          vehId = businessVehicles.getBusinessVehicleIdentifier(businessId, vehicleId)
        else
          vehId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(vehId) or vehId
        end
      end

      local race = hostRefs.session.races[raceName] or {}
      hostRefs.raceSession.setStagingSubjectId(vehId)
      if hostRefs.raceSession.raceHudApplies(race) then
        hostRefs.raceSession.showFreeroamRaceHud()
      else
        hostRefs.utils.displayStagedMessage(vehId, raceName)
      end
      hostRefs.utils.setActiveLight(raceName, "yellow")
      extensions.hook("onFreeroamStagingCommitted", {
        raceName = raceName,
        vehicleId = vehId,
      })
      ownerServices.notifyFreContractsFreeroamUi()
      return true
    end

    local function freeroamStagingExit(eventSession, hudSession, raceName, message)
      local race = eventSession.races and eventSession.races[raceName]
      local useHud = race and hudSession.raceHudApplies(race)
      local showStagingExitMsg = eventSession.mActiveRace == nil
      if useHud and showStagingExitMsg then
        hudSession.setRaceHudBanner(message, "warn", 4)
        hudSession.pushFreeroamRaceHudState(true)
      end
      eventSession.staged = nil
      hudSession.setStagingSubjectId(nil)
      ownerServices.hideStagedFlashMessage()
      ownerServices.notifyFreContractsFreeroamUi()
      if not useHud and showStagingExitMsg then hostRefs.utils.displayMessage(message, 4) end
      hostRefs.utils.setActiveLight(raceName, "red")
      if useHud and showStagingExitMsg then
        core_jobsystem.create(function(job)
          job.sleep(2.5)
          if not eventSession.mActiveRace then hudSession.hideFreeroamRaceHud() end
        end)
      end
  end

  local function tryCommitStagingEnter(raceName, spawnVehId)
    if not canEnterFreeroamStaging(raceName, spawnVehId) then return false end
    local flow = hostRefs.competitiveTrackFlow
    if flow.raceUsesSanctionedParkingStaging(raceName) then
      local useAltRoute = flow.getCompetitiveRaceId() == raceName and hostRefs.trackFlowState.useAltRoute == true
      local ok, reason = flow.setCompetitiveRace(raceName, useAltRoute)
      if not ok then hostRefs.utils.displayMessage(reason, 5); return false end
    end
    if not prepareStagingVehicleSpeed(raceName, spawnVehId) then return false end
    hostRefs.Assets:hideAllAssets()
    hostRefs.session.lapCount = 0
    if not stagingRaceIsEnabled(raceName) then return false end
    return commitStagingVehicle(raceName, spawnVehId)
  end

  local function beamngTrigger_staging(data, event, raceName)
    if event == "enter" and hostRefs.session.mActiveRace == nil then
      if hostRefs.competitiveTrackFlow.raceUsesSanctionedParkingStaging(raceName) and hostRefs.competitiveTrackFlow.isSanctionedCareerGoToRaceActive() then
        local spot = hostRefs.competitiveTrackFlow.getPlayerStagingSpot()
        if spot and hostRefs.competitiveTrackFlow.isPlayerInTrackParkingCommitArea() then return end
      end
      tryCommitStagingEnter(raceName, data.subjectID)
    elseif event == "exit" then
      if hostRefs.session.mActiveRace ~= raceName then
        if hostRefs.competitiveTrackFlow.raceUsesSanctionedParkingStaging(raceName) and hostRefs.competitiveTrackFlow.isSanctionedCareerGoToRaceActive() then return end
        if hostRefs.competitiveTrackFlow.raceUsesSanctionedParkingStaging(raceName) then hostRefs.competitiveTrackFlow.cancelCompetitiveGridFlow() end
        freeroamStagingExit(hostRefs.session, hostRefs.raceSession, raceName, "You exited the staging zone")
      end
    end
  end

  local function canCompletePlayerLap()
    if not hostRefs.session.currCheckpoint or hostRefs.session.checkpointsHit < hostRefs.session.totalCheckpoints then
      if not hostRefs.session.invalidLap then
        if hostRefs.raceSession.isRaceHudShown() then
          hostRefs.raceSession.setRaceHudBanner("Complete all checkpoints before crossing the line", "warn", 5)
          hostRefs.raceSession.pushFreeroamRaceHudState(true)
        else
          hostRefs.utils.displayMessage("You have not completed all checkpoints!", 5)
        end
        return false
      end
    end
    return true
  end

  local function recordCompletedPlayerLap(data, raceName)
    local completedLapTime = hostRefs.session.in_race_time
    hostRefs.session.timerActive = false
    hostRefs.session.mSuppressOffRoadExitUntil = os.time() + 2
    if not hostRefs.session.invalidLap then
      if hostRefs.session.mBestLapThisRun == nil or completedLapTime < hostRefs.session.mBestLapThisRun then
        hostRefs.session.mBestLapThisRun = completedLapTime
      end
    end
    hostRefs.session.initialVehicleDamage = hostRefs.utils.getVehicleDamage()
    hostRefs.processRoad.setStationaryTimeout(hostRefs.session.races[raceName].timeout)
    hostRefs.checkpointManager.setRace(hostRefs.session.races[raceName], raceName)
    if not data.triggerName then data.triggerName = "fre_start_" .. raceName end
    data.assets = hostRefs.session.races[raceName].assets
    hostRefs.Assets:displayAssets(data)
    hostRefs.utils.playCheckpointSound()
    hostRefs.session.lapCount = hostRefs.session.lapCount + 1
    local lapResultId = ownerServices.sessionFlow.resultId("lap" .. hostRefs.session.lapCount)
    extensions.hook("onFreeroamLapCompleted", {
      raceName = raceName,
      lapCount = hostRefs.session.lapCount,
      lapTime = completedLapTime,
      invalid = hostRefs.session.invalidLap,
      resultId = lapResultId,
    })
    return completedLapTime, lapResultId
  end

  local function finishSanctionedLapCap(data, raceName)
    local race = hostRefs.session.races[raceName]
    local effectiveRace = (hostRefs.session.mAltRoute and race.altRoute) and race.altRoute or race
    local lapTotalGoal = ownerServices.getDisplayTotalLapsForRace(effectiveRace)
    if lapTotalGoal < 1 then
      local raceSessionConfig = effectiveRace and effectiveRace.session
      local sessionLapCount = raceSessionConfig and raceSessionConfig.lapCount
      lapTotalGoal = (type(sessionLapCount) == "number" and sessionLapCount > 0) and sessionLapCount or 0
    end
    local enforceSanctionedLapCap = hostRefs.competitiveTrackFlow.raceUsesSanctionedParkingStaging(raceName)
      and overhaul_events_fre_sanctionedRacing
      and overhaul_events_fre_sanctionedRacing.shouldSuppressFrePayouts()
    if enforceSanctionedLapCap and lapTotalGoal > 0 and hostRefs.session.lapCount >= lapTotalGoal then
      ownerServices.sessionFlow.exitRace(true, nil, effectiveRace, data.subjectID)
      return true
    end
    return false
  end

  local function startFollowingPlayerLap(raceName, completedLapTime, reward, hudCompletionPayload, snapshotLabel, snapshotRaceLabel)
    if
      not hostRefs.circuitRaceAi.isSanctionedTriggerOnlyLapRace()
      and type(reward) == "number"
      and reward > 0
      and hostRefs.session.races[raceName].checkpointRoad
    then
      hostRefs.raceSession.setLastLapReward(reward)
    end
    hostRefs.session.currCheckpoint = nil
    hostRefs.session.mSplitTimes = {}
    hostRefs.session.mActiveRace = raceName
    hostRefs.checkpointManager.setAltRoute(false)
    hostRefs.session.mAltRoute = false
    hostRefs.session.mTotalRaceTime = (hostRefs.session.mTotalRaceTime or 0) + completedLapTime
    hostRefs.session.in_race_time = 0
    hostRefs.session.maxSpeed = 0
    hostRefs.session.timerActive = true
    hostRefs.session.checkpointsHit = 0
    if ownerServices.sessionFlow.shouldUseAltRouteForNextLap(raceName) then
      hostRefs.session.mAltRoute = true
      hostRefs.checkpointManager.setAltRoute(true)
    end
    hostRefs.session.totalCheckpoints = hostRefs.checkpointManager.calculateTotalCheckpoints()
    hostRefs.session.currentExpectedCheckpoint = 0
    if hostRefs.session.races[raceName].hotlap then
      hostRefs.session.mHotlap = raceName
      hostRefs.session.currentExpectedCheckpoint = hostRefs.checkpointManager.enableCheckpoint(0, hostRefs.session.mAltRoute)
    end
    hostRefs.session.invalidLap = false
    if hudCompletionPayload then
      hostRefs.raceSession.pushRaceHudCompletion(hudCompletionPayload, raceName, snapshotLabel, snapshotRaceLabel, 0, false)
    else
      hostRefs.raceSession.pushFreeroamRaceHudState(true)
    end
  end

  local function beamngTrigger_startPlayer(data, event, raceName)
    if event == "enter" and hostRefs.session.mActiveRace == raceName and not hostRefs.utils.hasFinishTrigger(raceName) then
      if not canCompletePlayerLap() then return end
      local completedLapTime, lapResultId = recordCompletedPlayerLap(data, raceName)
      if finishSanctionedLapCap(data, raceName) then return end
      local snapshotLabel = ownerServices.sessionFlow.getDisplayRaceLabel()
      local snapshotRaceLabel = ownerServices.sessionFlow.getRaceLabel()
      local reward, hudCompletionPayload = hostRefs.raceSession.payoutRace(completedLapTime, lapResultId)
      startFollowingPlayerLap(raceName, completedLapTime, reward, hudCompletionPayload, snapshotLabel, snapshotRaceLabel)

    elseif event == "enter" and hostRefs.session.staged == raceName and hostRefs.session.mActiveRace ~= raceName then
      if
        hostRefs.competitiveTrackFlow.raceUsesSanctionedParkingStaging(raceName)
        and (
          hostRefs.competitiveTrackFlow.getCompetitiveCountdownJobActive()
          or hostRefs.competitiveTrackFlow.getCompetitiveAwaitingAiSpawn()
        )
      then
        return
      end
      ownerServices.sessionFlow.beginFreeroamRace(raceName, data.subjectID)
    else
      hostRefs.utils.setActiveLight(raceName, "red")
    end
  end

  local function recordEnteredCheckpoint(raceName, checkpointIndex, isAlt)
    hostRefs.session.checkpointsHit = hostRefs.session.checkpointsHit + 1
    hostRefs.raceSession.clearHudCompletionPayload()
    hostRefs.session.currCheckpoint = checkpointIndex
    local checkpointRace = hostRefs.session.races[raceName]
    local effectiveCheckpointRace = (hostRefs.session.mAltRoute and checkpointRace.altRoute) and checkpointRace.altRoute
      or checkpointRace
    if effectiveCheckpointRace.driftGoal then
      hostRefs.session.mSplitTimes[hostRefs.session.checkpointsHit] = tonumber(hostRefs.raceSession.peekLiveDriftScore()) or 0
    else
      hostRefs.session.mSplitTimes[hostRefs.session.checkpointsHit] = hostRefs.session.in_race_time
    end
    if hostRefs.session.checkpointsHit == 1 then
      hostRefs.session.mCurrentRouteName = ownerServices.sessionFlow.getRouteDisplayName(hostRefs.session.races[raceName], isAlt)
    end
    hostRefs.utils.playCheckpointSound()

    if isAlt then hostRefs.session.currentExpectedCheckpoint = checkpointIndex end

    hostRefs.session.currentExpectedCheckpoint = hostRefs.checkpointManager.enableCheckpoint(checkpointIndex, isAlt)
    if isAlt and not hostRefs.session.mAltRoute then
      hostRefs.session.mAltRoute = true
      hostRefs.checkpointManager.setAltRoute(true)
      hostRefs.session.totalCheckpoints = hostRefs.checkpointManager.calculateTotalCheckpoints()
    end
    hostRefs.checkpointManager.notifyCheckpointEntered({
      raceName = raceName,
      checkpointIndex = checkpointIndex,
      isAlt = isAlt,
      checkpointsHit = hostRefs.session.checkpointsHit,
      totalCheckpoints = hostRefs.session.totalCheckpoints,
      inRaceTime = hostRefs.session.in_race_time,
    })

    return effectiveCheckpointRace
  end

  local function enteredCheckpointMessage(raceName, effectiveCheckpointRace)
    local checkpointMessage = ""
    local driftSplits = effectiveCheckpointRace.driftGoal
    local splitDiff = hostRefs.raceSession.getDifference(raceName, hostRefs.session.checkpointsHit)
    if splitDiff then
      local raceLabel = ownerServices.sessionFlow.getRaceLabel()
      local leaderboardEntry = hostRefs.leaderboardManager.getLeaderboardEntry(hostRefs.session.mInventoryId, raceLabel)
      local totalDiff
      if driftSplits then
        totalDiff = (hostRefs.session.mSplitTimes[hostRefs.session.checkpointsHit] or 0)
          - (leaderboardEntry.splitTimes[hostRefs.session.checkpointsHit] or 0)
      else
        totalDiff = hostRefs.session.in_race_time - (leaderboardEntry.splitTimes[hostRefs.session.checkpointsHit] or 0)
      end

      if driftSplits then
        checkpointMessage = string.format(
          "Checkpoint %d/%d - Score: %d\nSplit: %s | Total: %s",
          hostRefs.session.checkpointsHit,
          hostRefs.session.totalCheckpoints,
          math.floor(hostRefs.session.mSplitTimes[hostRefs.session.checkpointsHit] or 0),
          hostRefs.raceSession.formatSplitDifference(splitDiff, true),
          hostRefs.raceSession.formatSplitDifference(totalDiff, true)
        )
      else
        checkpointMessage = string.format(
          "Checkpoint %d/%d - Time: %s\nSplit: %s | Total: %s",
          hostRefs.session.checkpointsHit,
          hostRefs.session.totalCheckpoints,
          eventHelpers.formatTime(hostRefs.session.in_race_time),
          hostRefs.raceSession.formatSplitDifference(splitDiff),
          hostRefs.raceSession.formatSplitDifference(totalDiff)
        )
      end
    else
      if driftSplits then
        checkpointMessage = string.format(
          "Checkpoint %d/%d - Score: %d",
          hostRefs.session.checkpointsHit,
          hostRefs.session.totalCheckpoints,
          math.floor(hostRefs.session.mSplitTimes[hostRefs.session.checkpointsHit] or 0)
        )
      else
        checkpointMessage = string.format(
          "Checkpoint %d/%d - Time: %s",
          hostRefs.session.checkpointsHit,
          hostRefs.session.totalCheckpoints,
          eventHelpers.formatTime(hostRefs.session.in_race_time)
        )
      end
    end
    return checkpointMessage
  end

  local function presentEnteredCheckpoint(data, raceName, checkpointIndex, isAlt, checkpointMessage)
    if not hostRefs.session.races[raceName].checkpointRoad then hostRefs.utils.displayMessage(checkpointMessage, 7) end
    hostRefs.raceSession.pushFreeroamRaceHudState(true)
    if not data.triggerName then
      data.triggerName = "fre_checkpoint_" .. raceName .. (isAlt and "_alt_" or "_") .. checkpointIndex
    end
    hostRefs.Assets:displayAssets(data)
  end

  local function invalidateMissedCheckpoint(raceName, checkpointIndex, isAlt, missedCheckpoints)
    hostRefs.session.invalidLap = true

    hostRefs.session.currCheckpoint = checkpointIndex
    hostRefs.session.currentExpectedCheckpoint = hostRefs.session.currentExpectedCheckpoint + missedCheckpoints
    hostRefs.session.checkpointsHit = math.min(hostRefs.session.checkpointsHit + missedCheckpoints + 1, hostRefs.session.totalCheckpoints)
    hostRefs.raceSession.clearHudCompletionPayload()

    hostRefs.session.currentExpectedCheckpoint = hostRefs.checkpointManager.enableCheckpoint(checkpointIndex, isAlt)

    local message = string.format("Missed a checkpoint\nLap Invalidated.", checkpointIndex)
    local missedCheckpointRace = hostRefs.session.races[raceName]
    local effectiveMissedCheckpointRace = (hostRefs.session.mAltRoute and missedCheckpointRace.altRoute)
        and missedCheckpointRace.altRoute
      or missedCheckpointRace
    local checkpointMessageMiss
    if effectiveMissedCheckpointRace.driftGoal then
      checkpointMessageMiss = string.format(
        "Checkpoint %d/%d - Score: %d",
        hostRefs.session.checkpointsHit,
        hostRefs.session.totalCheckpoints,
        math.floor(hostRefs.session.mSplitTimes[hostRefs.session.checkpointsHit] or 0)
      )
    else
      checkpointMessageMiss = string.format(
        "Checkpoint %d/%d - Time: %s",
        hostRefs.session.checkpointsHit,
        hostRefs.session.totalCheckpoints,
        eventHelpers.formatTime(hostRefs.session.in_race_time)
      )
    end
    message = message .. "\n" .. checkpointMessageMiss
    if hostRefs.session.races[raceName].checkpointRoad and hostRefs.raceSession.isRaceHudShown() then
      hostRefs.raceSession.setRaceHudBanner("Missed checkpoint — lap invalidated", "warn", 8)
    elseif not hostRefs.raceSession.isRaceHudShown() then
      hostRefs.utils.displayMessage(message, 10)
    end
    hostRefs.raceSession.pushFreeroamRaceHudState(true)
  end

  local function warnUnexpectedCheckpoint(raceName, checkpointIndex, isAlt)
    log(
      "W",
      "freeroamEvents",
      string.format(
        "Unexpected checkpoint trigger for race '%s': got %d, expected %s, alt=%s, hit=%d/%d.",
        tostring(raceName),
        tonumber(checkpointIndex) or -1,
        tostring(hostRefs.session.currentExpectedCheckpoint),
        tostring(isAlt),
        tonumber(hostRefs.session.checkpointsHit) or 0,
        tonumber(hostRefs.session.totalCheckpoints) or 0
      )
    )
  end

  local function beamngTrigger_checkpointPlayer(data, event, raceName, checkpointIndex, isAlt)
    if event ~= "enter" or hostRefs.session.mActiveRace ~= raceName then return end
    if hostRefs.session.checkpointsHit >= hostRefs.session.totalCheckpoints then return end
    if (checkpointIndex == hostRefs.session.currentExpectedCheckpoint) or (checkpointIndex == 1 and isAlt)
      or (isAlt and (hostRefs.session.currentExpectedCheckpoint == hostRefs.session.races[raceName].altRoute.mergeCheckpoints[1])) then
      local effectiveCheckpointRace = recordEnteredCheckpoint(raceName, checkpointIndex, isAlt)
      local checkpointMessage = enteredCheckpointMessage(raceName, effectiveCheckpointRace)
      presentEnteredCheckpoint(data, raceName, checkpointIndex, isAlt, checkpointMessage)
    else
      local missedCheckpoints = checkpointIndex - hostRefs.session.currentExpectedCheckpoint
      if missedCheckpoints > 0 then
        invalidateMissedCheckpoint(raceName, checkpointIndex, isAlt, missedCheckpoints)
      else
        warnUnexpectedCheckpoint(raceName, checkpointIndex, isAlt)
      end
    end
  end

  local function beamngTrigger_finishPlayer(data, event, raceName)
    if event == "enter" and hostRefs.session.mActiveRace == raceName then
      local race = hostRefs.session.races[raceName]
      local effectiveRace = (race and hostRefs.session.mAltRoute and race.altRoute) and race.altRoute or race
      ownerServices.sessionFlow.exitRace(true, nil, effectiveRace, data.subjectID)
    end
  end

  local function beamngTrigger_pits(data, event, raceName)
    if event == "enter" and hostRefs.session.mActiveRace == raceName then
      local obj = be:getPlayerVehicle(0)
      if obj then obj:queueLuaCommand("obj:setGhostEnabled(true)") end
      if hostRefs.session.races[raceName].pitSpeedLimit then
        hostRefs.pits.stopThenLimit(hostRefs.session.races[raceName].pitSpeedLimit, hostRefs.session.races[raceName].pitSpeedLimitUnit)
      else
        hostRefs.pits.stopThenLimit(37, "MPH")
      end
    elseif event == "exit" and hostRefs.session.mActiveRace == raceName then
      -- Leaving the pit lane only turns the limit off; toggling an inactive limit turned it on.
      if hostRefs.pits.isSpeedLimitActive() then hostRefs.pits.toggleSpeedLimit() end
      local obj = be:getPlayerVehicle(0)
      if obj then obj:queueLuaCommand("obj:setGhostEnabled(false)") end
    end
  end

  local function parseFreeroamTriggerName(triggerName)
    local binding, reason = eventHelpers.resolveTrigger(hostRefs.session.races, triggerName)
    if reason then log("W", "freeroamHost", reason) end
    if not binding then return end
    return binding.eventType, binding.raceId, nil, binding.checkpointIndex, binding.aiAlt, binding.altRoute
  end

  local function routePlayerFreeroamTrigger(data, event, triggerType, raceName, rest, checkpointIndex, isAlt)
    if hostRefs.utils.isExternalActivityBlockingFreeroam() and hostRefs.session.mActiveRace ~= raceName then return end
    -- The stock strip owns staging, checkpoints and finish; FRE triggers can overlap it.
    if hostRefs.session.races[raceName].dragStripId then return end

    if triggerType == "hub" and hostRefs.competitiveTrackFlow.raceUsesSanctionedParkingStaging(raceName) then
      hostRefs.competitiveTrackFlow.beamngTrigger_competitiveHub(data, event, raceName)
      return
    end

    if triggerType == "staging" and eventHelpers.raceHasType(hostRefs.session.races[raceName], "demo") then
      if hostRefs.demolitionDerby then hostRefs.demolitionDerby.onStagingTrigger(data, event, raceName) end
    elseif triggerType == "staging" then
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

  local function onBeamNGTrigger(data)
    if not hostRefs.session or not hostRefs.utils then return end
    ownerServices.syncReplayFlagFromCore()
    if hostRefs.session.isReplay then return end
    local isPlayer = (be:getPlayerVehicleID(0) == data.subjectID)
    if not isPlayer and not ownerServices.sessionFlow.isAiSpawnedVehicle(data.subjectID) then return end
    if gameplay_walk and gameplay_walk.isWalking() then return end

    local triggerName = data.triggerName
    local event = data.event

    local demoMarkerKey = triggerName and triggerName:match("^rls_demo_derby_marker_area_(.+)$")
    if demoMarkerKey and demoMarkerKey ~= "" and isPlayer then
      if not hostRefs.utils.isExternalActivityBlockingFreeroam() then
        if hostRefs.demolitionDerby and hostRefs.demolitionDerby.onStagingTrigger then
          hostRefs.demolitionDerby.onStagingTrigger(data, event, demoMarkerKey)
        end
      end
      return
    end

    local triggerType, raceName, rest, checkpointIndex, isAiAlt, isAlt = parseFreeroamTriggerName(triggerName)
    if not triggerType or not raceName then
      -- Derby stages use their own configured event catalog and authored scene-name grammar.
      local derbyKey = type(triggerName) == "string" and triggerName:match("^fre_staging_(demo_.+)$")
      if derbyKey and isPlayer and not hostRefs.utils.isExternalActivityBlockingFreeroam() and hostRefs.demolitionDerby then
        hostRefs.demolitionDerby.onStagingTrigger(data, event, derbyKey)
      end
      return
    end
    if hostRefs.circuitRaceAi and hostRefs.circuitRaceAi.tryHandleAiTrigger and hostRefs.circuitRaceAi.tryHandleAiTrigger(
      data, event, triggerType, raceName, checkpointIndex, isAiAlt, isAlt, isPlayer
    ) then return end
    if not isPlayer then return end
    routePlayerFreeroamTrigger(data, event, triggerType, raceName, rest, checkpointIndex, isAlt)
  end

  local function onVehicleSwitched(oldId, newId, player)
    if player and player ~= 0 then return end
    if not hostRefs.session then return end
    if oldId == newId then return end
    ownerServices.syncReplayFlagFromCore()
    if hostRefs.session.isReplay then return end

    if hostRefs.session.mActiveRace then
      ownerServices.sessionFlow.exitRace(false, "Race cancelled due to vehicle switch", nil, newId)
      return
    end

    if not hostRefs.session.staged then return end

    local raceName = hostRefs.session.staged
    if
      hostRefs.competitiveTrackFlow.raceUsesSanctionedParkingStaging(raceName)
      and hostRefs.competitiveTrackFlow.isSanctionedCareerGoToRaceActive
      and hostRefs.competitiveTrackFlow.isSanctionedCareerGoToRaceActive()
    then
      return
    end
    if hostRefs.competitiveTrackFlow.raceUsesSanctionedParkingStaging(raceName) then hostRefs.competitiveTrackFlow.cancelCompetitiveGridFlow() end

    freeroamStagingExit(hostRefs.session, hostRefs.raceSession, raceName, "Staging cancelled due to vehicle switch")
  end

  instance.tryCommitStagingEnter = tryCommitStagingEnter
  instance.freeroamStagingExit = freeroamStagingExit
  instance.beamngTrigger_staging = beamngTrigger_staging
  instance.beamngTrigger_startPlayer = beamngTrigger_startPlayer
  instance.beamngTrigger_checkpointPlayer = beamngTrigger_checkpointPlayer
  instance.beamngTrigger_finishPlayer = beamngTrigger_finishPlayer
  instance.beamngTrigger_pits = beamngTrigger_pits
  instance.onBeamNGTrigger = onBeamNGTrigger
  instance.onVehicleSwitched = onVehicleSwitched
  return instance
end

return M
