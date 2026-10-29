-- Competitive track flow, racing-team proxy: spectator UI, team loading overlay, proxy AI spawn and staging tail.
-- Created by events/competitiveTrackFlow.lua once per load with that load's M and flow state, so a reload never shares state.

local lib = {}
local optional = require("overhaul/lib/platform/optional")

local LOG_TAG = "competitiveTrackFlow"

function lib.create(ownerServices)
  local M = ownerServices.M
  local trackFlow = ownerServices.tf
  local config = ownerServices

  local function findAppContainer(extensionNames)
    for _, name in ipairs(extensionNames) do
      local container = optional(name)
      if container and container.hideAllApps then return container end
    end
    return nil
  end

  local function hideAllAppContainers()
    local gameplayApps =
      findAppContainer({ "ui_gameplayAppContainers", "ge_extensions_ui_gameplayAppContainers" })
    if gameplayApps then pcall(function()
      gameplayApps.hideAllApps("gameplayApps")
    end) end
    local messagesTasksApps =
      findAppContainer({ "ui_messagesTasksAppContainers", "ge_extensions_ui_messagesTasksAppContainers" })
    if messagesTasksApps then pcall(function()
      messagesTasksApps.hideAllApps("messagesTasksApps")
    end) end
    guihooks.trigger("ShowApps", false)
    guihooks.trigger("appContainer:clear")
  end

  local function applySpectatorUiMinimal()
    if trackFlow.mRacingTeamProxySpectatorUiMinimalActive then return end
    trackFlow.mRacingTeamProxySpectatorUiMinimalActive = true
    hideAllAppContainers()
  end

  -- Re-applies the hiding while minimal mode is active, e.g. when CEF restored the chrome after an alt-tab.
  function M.refreshRacingTeamProxySpectatorUiMinimalIfActive()
    if not trackFlow.mRacingTeamProxySpectatorUiMinimalActive then return end
    hideAllAppContainers()
  end

  local function restoreRacingTeamProxySpectatorUiAfterMinimal()
    if not trackFlow.mRacingTeamProxySpectatorUiMinimalActive then return end
    trackFlow.mRacingTeamProxySpectatorUiMinimalActive = false
    guihooks.trigger("ShowApps", true)
    local appLayout = core_gamestate.state and core_gamestate.state.appLayout
    if type(appLayout) == "string" and appLayout ~= "" then
      if appLayout == "blank" then
        guihooks.trigger("appContainer:clear")
      else
        guihooks.trigger("appContainer:loadLayoutByType", appLayout)
      end
    elseif type(appLayout) == "table" then
      guihooks.trigger("appContainer:loadLayoutByObject", appLayout)
    else
      guihooks.trigger("appContainer:loadLayoutByType", "freeroam")
    end
  end

  local function racingTeamProxyUseTeamLoadingOverlay()
    return M.trackFlowState.racingTeamProxyStagingLoadingOverlay ~= false
  end

  -- A mod-owned fullscreen Vue overlay, not core_gamestate's careerLoading.
  local function relayRacingTeamProxyTeamLoading(visible, message)
    if visible == true and not racingTeamProxyUseTeamLoadingOverlay() then return end
    local payload = { visible = visible == true }
    if visible == true and type(message) == "string" and message ~= "" then payload.message = message end
    guihooks.trigger("racingTeamProxyTeamLoading", payload)
  end

  -- While the proxy is in the world only RacingTeamProxyOverlay and freeroamRaceHud stay up; `spectateStaging`
  -- starts that suppression before the teleport.
  function M.relayRacingTeamProxyOverlay(payload)
    guihooks.trigger("racingTeamProxyOverlay", payload)
    if type(payload) ~= "table" then return end
    if payload.visible == false then
      relayRacingTeamProxyTeamLoading(false)
      restoreRacingTeamProxySpectatorUiAfterMinimal()
    elseif
      payload.visible == true
      and (payload.inRace == true or payload.playerTeleportedToTeamCar == true or payload.spectateStaging == true)
    then
      applySpectatorUiMinimal()
    end
  end

  function M.enterRacingTeamProxyStagingLoadingEarly()
    relayRacingTeamProxyTeamLoading(true)
  end

  -- Called by the UI on Spectate before the teleport, so nothing flashes under the business computer.
  function M.preflightRacingTeamProxySpectateUi(businessId)
    if businessId == nil or businessId == "" then return end
    M.relayRacingTeamProxyOverlay({
      visible = true,
      businessId = tostring(businessId),
      inRace = false,
      spectateStaging = true,
    })
    relayRacingTeamProxyTeamLoading(true)
  end

  function M.exitRacingTeamProxyStagingLoadingScreen()
    relayRacingTeamProxyTeamLoading(false)
  end

  local function racingTeamRaceFlowMod()
    return rawget(_G, "overhaul_career_business_racingTeam_raceFlow")
  end

  local function syncRacingTeamProxyBracketFromRequest(request)
    local flowState = M.trackFlowState
    flowState.racingTeamProxyAiPoolRefHp = nil
    flowState.racingTeamProxyAiPoolMinHp = nil
    flowState.racingTeamProxyAiPoolBracketOnly = false
    flowState.racingTeamProxyAiDifficultyT = nil
    if not request or type(request.offerSnapshot) ~= "table" then return end
    local bracketMax = tonumber(request.offerSnapshot.classPwMax) or tonumber(request.offerSnapshot.classHpMax)
    local bracketMin = tonumber(request.offerSnapshot.classPwMin) or tonumber(request.offerSnapshot.classHpMin)
    if bracketMax and bracketMax > 0 then flowState.racingTeamProxyAiPoolRefHp = bracketMax end
    if bracketMin and bracketMin > 0 then flowState.racingTeamProxyAiPoolMinHp = bracketMin end
    if bracketMax and bracketMax > 0 and bracketMin and bracketMin > 0 and bracketMax >= bracketMin then
      flowState.racingTeamProxyAiPoolBracketOnly = true
      local businessId = request.businessId
      local driverId = tonumber(request.driverId)
      local raceFlow = racingTeamRaceFlowMod()
      if raceFlow and raceFlow.getProxyDriverAiDifficultyBlendT and businessId and driverId then
        flowState.racingTeamProxyAiDifficultyT = raceFlow.getProxyDriverAiDifficultyBlendT(businessId, driverId)
      else
        flowState.racingTeamProxyAiDifficultyT = 1
      end
    end
  end

  -- prepareFreeroamAiForTrack consumes the bracket and difficulty fields, so a retry pulls them again.
  local function resyncAiBracketFromArmedRequest()
    local businessId = M.trackFlowState.racingTeamProxyBusinessId
    local raceFlow = racingTeamRaceFlowMod()
    if not businessId or not raceFlow or not raceFlow.getProxyDriverRaceRequest then return end
    local request = raceFlow.getProxyDriverRaceRequest(businessId)
    if request then syncRacingTeamProxyBracketFromRequest(request) end
  end

  -- prepareFreeroamAiForTrack returns early while awaiting, so a retry must reset these first.
  local function racingTeamProxyResetAiSpawnBookkeeping()
    trackFlow.mCompetitiveAwaitingAiSpawn = false
    trackFlow.mTrackGridAiSpawnWaitDeadline = nil
    trackFlow.mTrackGridParkingAiSpawnStarted = false
    local aiRacers = overhaul_events_aiRacers
    if aiRacers then pcall(function()
      aiRacers.clearSpawned()
    end) end
  end

  -- Player hp/kg, never catalog crank HP.
  local function racingTeamProxyPoolReferencePower()
    local armedReference = M.trackFlowState.racingTeamProxyAiPoolRefHp
    if type(armedReference) == "number" and armedReference > 0 then return armedReference end
    if overhaul_events_aiRacers then return select(1, overhaul_events_aiRacers.getPlayerVehiclePwForStagingUi()) end
    return nil
  end

  -- One spawn pass, then a bounded wait for the async spawn callback.
  local function spawnAiAndWait(job)
    M.prepareFreeroamAiForTrack(racingTeamProxyPoolReferencePower(), true)
    local deadline = os.time() + config.TRACK_GRID_AI_SPAWN_WAIT_SEC + 2
    while trackFlow.mCompetitiveAwaitingAiSpawn do
      if os.time() >= deadline then
        log("W", LOG_TAG, "racing team proxy staging: AI spawn wait deadline reached.")
        break
      end
      job.sleep(0.08)
    end
    job.sleep(0.12)
  end

  -- Returns false when the proxy was disarmed during a retry, so the caller stops without further work.
  local function spawnAiUntilGridFilled(job)
    local attempt = 1
    spawnAiAndWait(job)
    while M.spawnedTrackAiCount() == 0 and attempt < config.MAX_PROXY_STAGING_AI_ATTEMPTS do
      if not M.trackFlowState.racingTeamProxyRaceActive then return false end
      attempt = attempt + 1
      log("W", LOG_TAG, string.format("racing team proxy staging: 0 AI on grid; retry attempt %d.", attempt))
      relayRacingTeamProxyTeamLoading(true, "Loading opponents…")
      racingTeamProxyResetAiSpawnBookkeeping()
      resyncAiBracketFromArmedRequest()
      spawnAiAndWait(job)
    end
    return true
  end

  -- The team car waits for green with its rivals' setup: their racing AI installed and held stopped.
  local function prepareTeamCarOnGrid(raceForAi)
    local fleet = overhaul_career_business_fleet
    local aiRacers = overhaul_events_aiRacers
    if not fleet or not aiRacers or not aiRacers.prepareTeamCarOnGrid then return end
    local teamCarId = fleet.getSpawnedVehicleId(
      M.trackFlowState.racingTeamProxyBusinessId,
      M.trackFlowState.racingTeamProxyFleetVehicleId
    )
    if teamCarId then aiRacers.prepareTeamCarOnGrid(teamCarId, raceForAi) end
  end

  -- Runs in the jobsystem once the player sits in the team car at the staging spot.
  local function racingTeamProxyRunStagingTailAfterPlayerInTeamCar(job)
    local raceForAi = M.trackRaceForAi()
    if raceForAi and M.raceAllowsAiSpawn(raceForAi) then
      if not spawnAiUntilGridFilled(job) then return end
      if M.spawnedTrackAiCount() == 0 then
        log("E", LOG_TAG, "racing team proxy staging: failed to spawn AI after retries; aborting load-in.")
        M.abortRacingTeamProxyStagingLoadIn("ai_spawn_failed")
        return
      end
      prepareTeamCarOnGrid(raceForAi)
    else
      job.sleep(0.05)
    end
    M.refreshRacingTeamProxySpectatorUiMinimalIfActive()
  end

  return {
    restoreRacingTeamProxySpectatorUiAfterMinimal = restoreRacingTeamProxySpectatorUiAfterMinimal,
    refreshProxySpectatorUiIfMinimal = function() M.refreshRacingTeamProxySpectatorUiMinimalIfActive() end,
    racingTeamProxyUseTeamLoadingOverlay = racingTeamProxyUseTeamLoadingOverlay,
    racingTeamProxyResetAiSpawnBookkeeping = racingTeamProxyResetAiSpawnBookkeeping,
    racingTeamProxyPoolReferencePower = racingTeamProxyPoolReferencePower,
    racingTeamProxyRunStagingTailAfterPlayerInTeamCar = racingTeamProxyRunStagingTailAfterPlayerInTeamCar,
    racingTeamRaceFlowMod = racingTeamRaceFlowMod,
    syncRacingTeamProxyBracketFromRequest = syncRacingTeamProxyBracketFromRequest,
  }
end

return lib
