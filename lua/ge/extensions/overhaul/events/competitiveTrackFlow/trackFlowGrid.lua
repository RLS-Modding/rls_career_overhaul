-- Competitive track flow, grid start: proxy pre-countdown wait, countdown and race start, AI preparation and staging commit.
-- Created by events/competitiveTrackFlow.lua once per load with that load's M and flow state, so a reload never shares state.

-- Reading order: configuration and state, lib.create, lib.create, lib.create, then public API and engine hooks.
-- Contract: create() binds the owning extension load; mutable event state belongs to that owner.
local lib = {}

-- Config ------------------------------------------------------------------------------------------

local LOG_TAG = "competitiveTrackFlow"
local PRE_COUNTDOWN_MAX_SEC = 3.0
local PRE_COUNTDOWN_STEP_SEC = 0.1
local PRE_COUNTDOWN_MIN_SEC = 0.4
local COUNTDOWN_SEC = 3
local GO_MESSAGE_SEC = 0.35

function lib.create(ownerServices)
  local M = ownerServices.M
  local trackFlow = ownerServices.tf
  local config = ownerServices
  local groundMarkers = ownerServices.core_groundMarkers
  local isPlayerInTrackParkingCommitSpot = ownerServices.isPlayerInTrackParkingCommitSpot

  local function currentSession()
    return ownerServices.sess()
  end

  local function clearFlashMessage()
    guihooks.trigger("ScenarioFlashMessage", { msg = "", ttl = 0, clearQueue = true })
  end

  -- Vehicle speed ---------------------------------------------------------------------------------

  local function getVehicleSpeedMph(vehicleId)
    local speedUnit = currentSession().speedUnit
    if not vehicleId then return 0 end
    local velocityX, velocityY, velocityZ = be:getObjectVelocityXYZ(vehicleId)
    if type(velocityX) == "number" and type(velocityY) == "number" and type(velocityZ) == "number" then
      return math.sqrt(velocityX * velocityX + velocityY * velocityY + velocityZ * velocityZ) * speedUnit
    end
    -- Without three components the engine hands back a speed or a vector in the first value.
    if type(velocityX) == "number" then return math.abs(velocityX) * speedUnit end
    if velocityX ~= nil and type(velocityX.length) == "function" then return velocityX:length() * speedUnit end
    return 0
  end

  -- Countdown -------------------------------------------------------------------------------------

  local function startPlayerEngine(playerVehicle)
    if playerVehicle and core_vehicleBridge then
      pcall(function()
        core_vehicleBridge.executeAction(playerVehicle, "setIgnitionLevel", 3)
      end)
    end
    if playerVehicle and playerVehicle.queueLuaCommand then
      pcall(function()
        playerVehicle:queueLuaCommand(
          "if electrics and electrics.setIgnitionLevel then electrics.setIgnitionLevel(3) end"
        )
      end)
    end
  end

  local function playerVehicleDataReady(aiRacers)
    local playerVehicleData = core_vehicle_manager.getPlayerVehicleData()
    local vehicleBundleReady = playerVehicleData and playerVehicleData.vdata ~= nil
    local powerReady = false
    if aiRacers then
      local playerPower = select(1, aiRacers.getPlayerVehiclePwForStagingUi())
      powerReady = type(playerPower) == "number" and playerPower > 0
    end
    return vehicleBundleReady and powerReady
  end

  -- Racing-team proxy only: start the engine and wait until the vehicle data looks ready before freeze and countdown.
  local function racingTeamProxyPreCountdownWait(job)
    if not M.isRacingTeamProxyRaceActive() then return end
    startPlayerEngine(be:getPlayerVehicle(0))
    local aiRacers = overhaul_events_aiRacers
    local elapsed = 0
    while elapsed < PRE_COUNTDOWN_MAX_SEC do
      if trackFlow.mCompetitiveCountdownCancel then return end
      local ready = playerVehicleDataReady(aiRacers)
      if elapsed >= PRE_COUNTDOWN_MIN_SEC and ready then
        job.sleep(0.2)
        return
      end
      job.sleep(PRE_COUNTDOWN_STEP_SEC)
      elapsed = elapsed + PRE_COUNTDOWN_STEP_SEC
    end
  end

  local function showCountdownSteps()
    clearFlashMessage()
    guihooks.trigger("ScenarioFlashMessage", {
      { 3, 1, "Engine.Audio.playOnce('AudioGui', 'event:UI_Countdown1')", true },
      { 2, 1, "Engine.Audio.playOnce('AudioGui', 'event:UI_Countdown2')", true },
      { 1, 1, "Engine.Audio.playOnce('AudioGui', 'event:UI_Countdown3')", true },
    })
  end

  local function showGoMessage()
    clearFlashMessage()
    guihooks.trigger(
      "ScenarioFlashMessage",
      { { "ui.scenarios.go", 1, "Engine.Audio.playOnce('AudioGui', 'event:UI_CountdownGo')", true } }
    )
  end

  local function stopCountdown(aiRacers)
    trackFlow.mCompetitiveCountdownJobActive = false
    if aiRacers then aiRacers.setPlayerFreeze(false) end
  end

  local function beginTrackRaceOrRelease(aiRacers)
    local vehicleId = be:getPlayerVehicleID(0)
    local races = currentSession().races
    if vehicleId and races and races[M.getCompetitiveRaceId()] then
      overhaul_events_host.beginFreeroamRace(M.getCompetitiveRaceId(), vehicleId)
    elseif aiRacers then
      aiRacers.setPlayerFreeze(false)
    end
  end

  -- A newer countdown (or a career change) bumps the generation, which silently retires this job.
  local function runCountdownJob(job, countdownGeneration, aiRacers)
    local function isStale()
      return countdownGeneration ~= trackFlow.mCompetitiveCountdownGeneration
    end
    if isStale() then return end
    if trackFlow.mCompetitiveCountdownCancel then return stopCountdown(aiRacers) end
    racingTeamProxyPreCountdownWait(job)
    if isStale() then return end
    if trackFlow.mCompetitiveCountdownCancel then return stopCountdown(aiRacers) end
    if aiRacers then aiRacers.setPlayerFreeze(true) end
    M.refreshRacingTeamProxySpectatorUiMinimalIfActive()
    showCountdownSteps()
    job.sleep(COUNTDOWN_SEC)
    if isStale() then return end
    if trackFlow.mCompetitiveCountdownCancel then
      stopCountdown(aiRacers)
      clearFlashMessage()
      return
    end
    showGoMessage()
    job.sleep(GO_MESSAGE_SEC)
    if isStale() then return end
    trackFlow.mCompetitiveCountdownJobActive = false
    if trackFlow.mCompetitiveCountdownCancel then
      if aiRacers then aiRacers.setPlayerFreeze(false) end
      return
    end
    M.refreshRacingTeamProxySpectatorUiMinimalIfActive()
    beginTrackRaceOrRelease(aiRacers)
  end

  function M.startCompetitiveTrackCountdownAndRace()
    local session = currentSession()
    if not M.getCompetitiveRaceId() then return false end
    if session.mActiveRace then return false end
    if trackFlow.mCompetitiveCountdownJobActive then return false end
    if session.staged ~= M.getCompetitiveRaceId() then return false end
    if not M.trackFlowState.inTrackFlowContext then return false end
    if not M.isTrackGridCareerStagingGateActive() then return false end
    M.setPlayerStagingSpotNil()
    M.clearPlayerStagingCornerMarkers()
    if groundMarkers then groundMarkers.resetAll() end
    trackFlow.mCompetitiveCountdownJobActive = true
    trackFlow.mCompetitiveCountdownCancel = false
    trackFlow.mCompetitiveCountdownGeneration = trackFlow.mCompetitiveCountdownGeneration + 1
    local countdownGeneration = trackFlow.mCompetitiveCountdownGeneration
    M.refreshRacingTeamProxySpectatorUiMinimalIfActive()
    local aiRacers = overhaul_events_aiRacers
    core_jobsystem.create(function(job)
      runCountdownJob(job, countdownGeneration, aiRacers)
    end)
    return true
  end

  -- AI preparation --------------------------------------------------------------------------------

  local function isPositiveNumber(value)
    return type(value) == "number" and value > 0
  end

  -- The pool reference is consumed: sanctioned values are cleared once read so the next grid starts fresh.
  local function takePoolReferenceHp(poolReferenceHpOverride)
    local flowState = M.trackFlowState
    local referenceHp = isPositiveNumber(poolReferenceHpOverride) and poolReferenceHpOverride or nil
    if not referenceHp and isPositiveNumber(flowState.sanctionedPoolRefPw) then
      referenceHp = flowState.sanctionedPoolRefPw
    end
    if not referenceHp and isPositiveNumber(flowState.sanctionedPoolRefHp) then
      referenceHp = flowState.sanctionedPoolRefHp
    end
    flowState.sanctionedPoolRefPw = nil
    flowState.sanctionedPoolRefHp = nil
    if not referenceHp and overhaul_events_fre_sanctionedRacing then
      referenceHp = overhaul_events_fre_sanctionedRacing.getAiPoolReferenceHp()
    end
    return referenceHp
  end

  local function takePoolMinimumHp()
    local flowState = M.trackFlowState
    local minimumHp = nil
    if isPositiveNumber(flowState.racingTeamProxyAiPoolMinHp) then minimumHp = flowState.racingTeamProxyAiPoolMinHp end
    flowState.racingTeamProxyAiPoolMinHp = nil
    if not minimumHp and overhaul_events_fre_sanctionedRacing then
      minimumHp = overhaul_events_fre_sanctionedRacing.getAiPoolReferenceHpMin()
    end
    return minimumHp
  end

  -- A racing-team proxy bracket replaces the sanctioned class limits with the request's own hp/kg range.
  local function buildSpawnContext(sanctionedSpawnContext, referenceHp, minimumHp)
    local flowState = M.trackFlowState
    if
      not (
        flowState.racingTeamProxyAiPoolBracketOnly == true
        and isPositiveNumber(referenceHp)
        and isPositiveNumber(minimumHp)
      )
    then
      return sanctionedSpawnContext
    end
    local spawnContext = {}
    if type(sanctionedSpawnContext) == "table" then
      for key, value in pairs(sanctionedSpawnContext) do
        spawnContext[key] = value
      end
    end
    spawnContext.racingTeamProxyBracketOnlyAi = true
    spawnContext.classPwMin = minimumHp
    spawnContext.classPwMax = referenceHp
    spawnContext.classHpMin = minimumHp
    spawnContext.classHpMax = referenceHp
    local difficulty = flowState.racingTeamProxyAiDifficultyT
    if difficulty ~= nil then spawnContext.racingTeamProxyAiDifficultyT = difficulty end
    return spawnContext
  end

  local function commitAiSpawn(deferCountdown)
    local session = currentSession()
    trackFlow.mCompetitiveAwaitingAiSpawn = false
    trackFlow.mTrackGridAiSpawnWaitDeadline = nil
    M.trackFlowState.racingTeamProxyAiPoolBracketOnly = false
    M.trackFlowState.racingTeamProxyAiDifficultyT = nil
    if deferCountdown then return end
    if session.staged ~= M.getCompetitiveRaceId() or session.mActiveRace then return end
    if M.trackFlowState.inTrackFlowContext and M.isTrackGridCareerStagingGateActive() then
      M.startCompetitiveTrackCountdownAndRace()
    end
  end

  -- Returns true when the rematch lineup spawned, so the normal sanctioned spawn is skipped.
  local function spawnRematchLineup(aiRacers, raceForAi, rematchLineup, deferCountdown)
    if type(rematchLineup) ~= "table" or #rematchLineup == 0 then return false end
    local spawned = tonumber(
      aiRacers.spawnForStagingWithExactLineup(M.getCompetitiveRaceId(), raceForAi, M.getCompetitiveRaceId(), rematchLineup)
    ) or 0
    if spawned <= 0 then
      log("W", LOG_TAG, "Rematch lineup spawn returned 0; falling back to normal sanctioned spawn.")
      return false
    end
    commitAiSpawn(deferCountdown)
    return true
  end

  -- poolReferenceHpOverride is the player's hp/kg when the live read is unavailable (never catalog crank HP).
  function M.prepareFreeroamAiForTrack(poolReferenceHpOverride, deferCountdown)
    local session = currentSession()
    if not session.races then session.races = overhaul_events_utils.loadRaceData() end
    local raceName = M.getCompetitiveRaceId()
    local raceForAi = M.trackRaceForAi(raceName)
    local selectionGeneration = trackFlow.mCompetitiveCountdownGeneration
    local aiRacers = overhaul_events_aiRacers
    if not aiRacers or not raceForAi or not M.raceAllowsAiSpawn(raceForAi) then return end
    if session.mActiveRace and session.timerActive then return end
    if trackFlow.mCompetitiveAwaitingAiSpawn then return end
    -- Always clear the previous grid first: reusing it left stale bookkeeping that skipped the fresh spawn
    -- on back-to-back racing-team proxy staging.
    aiRacers.clearSpawned()
    trackFlow.mTrackGridParkingAiSpawnStarted = true
    trackFlow.mCompetitiveAwaitingAiSpawn = true
    trackFlow.mTrackGridAiSpawnWaitDeadline = os.time() + config.TRACK_GRID_AI_SPAWN_WAIT_SEC
    local referenceHp = takePoolReferenceHp(poolReferenceHpOverride)
    local minimumHp = takePoolMinimumHp()
    local sanctionedRacing = overhaul_events_fre_sanctionedRacing
    local sanctionedSpawnContext = sanctionedRacing and sanctionedRacing.getAiSpawnSanctionedContext()
    local rematchLineup = sanctionedRacing and sanctionedRacing.getRematchAiLineupSnapshot()
    local spawnContext = buildSpawnContext(sanctionedSpawnContext, referenceHp, minimumHp)
    if spawnRematchLineup(aiRacers, raceForAi, rematchLineup, deferCountdown) then return end
    aiRacers.spawnForStagingWithPlayerHp(raceName, raceForAi, raceName, function(spawned)
      if M.getCompetitiveRaceId() ~= raceName or trackFlow.mCompetitiveCountdownGeneration ~= selectionGeneration then return end
      local count = tonumber(spawned) or 0
      if count <= 0 then
        log("W", LOG_TAG, string.format("Sanctioned AI spawn returned %d; no generic fallback applied.", count))
      end
      commitAiSpawn(deferCountdown)
    end, referenceHp, minimumHp, spawnContext)
  end

  -- Staging commit --------------------------------------------------------------------------------

  -- A stale countdown flag with nothing staged would block the next staging, so it is cleared first.
  local function clearStaleCountdownFlags()
    local session = currentSession()
    if not session.staged and not session.mActiveRace and trackFlow.mCompetitiveCountdownJobActive then
      trackFlow.mCompetitiveCountdownJobActive = false
      trackFlow.mCompetitiveCountdownCancel = false
    end
  end

  local function aiPrerequisitesMet()
    if trackFlow.mCompetitiveAwaitingAiSpawn then return false end
    if not trackFlow.mTrackGridParkingAiSpawnStarted and M.spawnedTrackAiCount() == 0 then return false end
    return true
  end

  -- Returns whether every race type is switched off by a zero economy multiplier, and the switched-off types.
  local function disabledRaceTypes(race)
    local disabledTypes = {}
    if not race.type then return false, disabledTypes end
    local totalTypes = 0
    for _, raceType in ipairs(race.type) do
      totalTypes = totalTypes + 1
      if overhaul_career_economyAdjuster.getEffectiveSectionMultiplier({ raceType }) == 0 then
        table.insert(disabledTypes, raceType)
      end
    end
    return totalTypes > 0 and #disabledTypes == totalTypes, disabledTypes
  end

  -- In career the staged subject is the inventory or business vehicle id, not the spawned object id.
  local function resolveStagedVehicleId(spawnedVehicleId)
    if not overhaul_career_career.isActive() then return spawnedVehicleId end
    local businessId, businessVehicleId =
      overhaul_career_business_fleet.getBusinessVehicleFromSpawnedId(spawnedVehicleId)
    if businessId and businessVehicleId then
      return overhaul_career_business_fleet.getBusinessVehicleIdentifier(businessId, businessVehicleId)
    end
    return overhaul_career_garage_inventory.getInventoryIdFromVehicleId(spawnedVehicleId) or spawnedVehicleId
  end

  local function exitProxyLoadingScreenIfArmed()
    if M.trackFlowState.racingTeamProxyRaceActive then M.exitRacingTeamProxyStagingLoadingScreen() end
  end

  local function showStagedState(race, raceName, stagedVehicleId)
    overhaul_events_raceSession.setStagingSubjectId(stagedVehicleId)
    if overhaul_events_raceSession.raceHudApplies(race) then
      overhaul_events_raceSession.showFreeroamRaceHud()
    else
      overhaul_events_utils.displayStagedMessage(stagedVehicleId, raceName)
    end
    overhaul_events_utils.setActiveLight(raceName, "yellow")
  end

  local function undoStaging(raceName)
    local session = currentSession()
    session.staged = nil
    overhaul_events_raceSession.setStagingSubjectId(nil)
    overhaul_events_utils.setActiveLight(raceName, "red")
    overhaul_events_raceSession.hideFreeroamRaceHud()
    overhaul_events_host.hideStagedFlashMessage()
    exitProxyLoadingScreenIfArmed()
  end

  function M.tryCommitTrackGridStaging(spawnVehicleId, options)
    options = type(options) == "table" and options or {}
    local skipAiPrereq = options.skipAiPrereq == true
    if not M.isTrackGridCareerStagingGateActive() then return false end
    local raceName = M.getCompetitiveRaceId()
    local session = currentSession()
    local races = session.races
    if not races or not races[raceName] then return false end
    clearStaleCountdownFlags()
    if not trackFlow.mPlayerStagingSpot or not isPlayerInTrackParkingCommitSpot(trackFlow.mPlayerStagingSpot) then
      return false
    end
    if overhaul_events_utils.isPlayerInPursuit() then
      overhaul_events_utils.displayMessage("You cannot stage for an event while in a pursuit.", 2)
      return false
    end
    if getVehicleSpeedMph(spawnVehicleId) > config.TRACK_GRID_STAGE_STOP_MPH then return false end
    local raceForAi = M.trackRaceForAi()
    if raceForAi and M.raceAllowsAiSpawn(raceForAi) and not skipAiPrereq and not aiPrerequisitesMet() then
      return false
    end

    -- requestGameState can paint the world before Vue composites, so proxy staging re-arms the loading overlay first.
    if M.trackFlowState.racingTeamProxyRaceActive then M.enterRacingTeamProxyStagingLoadingEarly() end
    session.saveGameState = true
    core_gamestate.requestGameState()
    session.mHotlap = nil
    overhaul_events_host.hideAllFreeroamAssets()
    session.lapCount = 0

    local allTypesDisabled, disabledTypes = disabledRaceTypes(races[raceName])
    if allTypesDisabled then
      overhaul_events_utils.displayMessage(
        string.format(
          "%s is disabled due to %s multiplier(s) being set to 0.",
          races[raceName].label,
          table.concat(disabledTypes, ", ")
        ),
        5
      )
      exitProxyLoadingScreenIfArmed()
      return false
    end

    session.staged = raceName
    session.freeroamPracticeStaging = false
    showStagedState(races[raceName], raceName, resolveStagedVehicleId(spawnVehicleId))
    if not M.startCompetitiveTrackCountdownAndRace() then
      undoStaging(raceName)
      return false
    end
    exitProxyLoadingScreenIfArmed()
    M.refreshRacingTeamProxySpectatorUiMinimalIfActive()
    return true
  end

  return {
    getVehicleSpeedMph = getVehicleSpeedMph,
  }
end

return lib
