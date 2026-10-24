-- Freeroam event lifecycles, child modules, HUD updates and map markers.
-- Owns the bound child modules, replay/traffic guards, frame updates, lifecycle and public hooks.
local eventHelpers = require("overhaul/lib/events/helpers")
local eventArtwork = require("overhaul/lib/events/artwork")
local M = {}

M.dependencies = { "overhaul_events_fre_host", "overhaul_events_session" }

-- Config ------------------------------------------------------------------------------------------

local ROAD_CHECK_INTERVAL = 0.1 -- simulation seconds

-- State -------------------------------------------------------------------------------------------

local loadedExtensions = {}
local roadCheckAccumulator = 0

-- The bound child modules and track-flow state. Filled in place each time the children load, and shared
-- with the session and trigger parts, which read it as `hostRefs.session`, `hostRefs.utils` and so on.
local hostRefs = {}

-- Replay and traffic guards -----------------------------------------------------------------------

-- Read core replay state synchronously because replay hooks can lag after a Lua reload.
local function syncReplayFlagFromCore()
  if not hostRefs.session then return end
  hostRefs.session.isReplay = core_replay.getState() == "playback"
end

-- Delayed race-exit traffic restores carry a stamp; cleanup or a later traffic cut makes them stale.
local trafficRestoreGeneration = 0
local function trafficRestoreStamp()
  return {
    generation = trafficRestoreGeneration,
    cuts = hostRefs.utils and hostRefs.utils.getTrafficCutCount and hostRefs.utils.getTrafficCutCount(),
  }
end

local function invalidateTrafficRestores()
  trafficRestoreGeneration = trafficRestoreGeneration + 1
end

local function restoreTrafficIfCurrent(stamp)
  if hostRefs.session and hostRefs.session.mActiveRace then return end
  if stamp.generation ~= trafficRestoreGeneration then return end
  if hostRefs.utils.getTrafficCutCount and stamp.cuts ~= hostRefs.utils.getTrafficCutCount() then return end
  hostRefs.utils.restoreTrafficAmount()
end

-- HUD and UI helpers ------------------------------------------------------------------------------

local function notifyFreContractsFreeroamUi()
  if overhaul_events_fre_ui and overhaul_events_fre_ui.emitUiStateUpdate then
    overhaul_events_fre_ui.emitUiStateUpdate("freeroam_session")
  end
end

local function getVehicleSpeedMph(vehicleId)
  local metersPerSecondToMph = (hostRefs.session and hostRefs.session.speedUnit) or 2.2369362921
  if not vehicleId then return 0 end
  local velocityX, velocityY, velocityZ = be:getObjectVelocityXYZ(vehicleId)
  if type(velocityX) == "number" and type(velocityY) == "number" and type(velocityZ) == "number" then
    return math.sqrt(velocityX * velocityX + velocityY * velocityY + velocityZ * velocityZ) * metersPerSecondToMph
  end
  if type(velocityX) == "number" then return math.abs(velocityX) * metersPerSecondToMph end
  if velocityX ~= nil and type(velocityX.length) == "function" then return velocityX:length() * metersPerSecondToMph end
  return 0
end

local function getDisplayTotalLapsForRace(race)
  return hostRefs.competitiveTrackFlow.getDisplayTotalLapsForRace(race)
end

local function getGameplayAppContainers()
  local names = { "ui_gameplayAppContainers", "ge_extensions_ui_gameplayAppContainers" }
  for _, extensionName in ipairs(names) do
    local appContainers = rawget(extensions, extensionName) -- rawget: a plain index would make the loader log "extension unavailable"
    if appContainers and appContainers.showApp then return appContainers end
  end
  return nil
end

local function hideStagedFlashMessage()
  guihooks.trigger("ScenarioFlashMessage", { msg = "", ttl = 0, clearQueue = true })
  local appContainers = getGameplayAppContainers()
  if appContainers and appContainers.hideApp then
    appContainers.hideApp("gameplayApps", "flashMessage")
    appContainers.hideApp("gameplayApps", "countdown")
  end
end

local function suppressVanillaDriftMissionUi()
  if gameplay_drift_general and gameplay_drift_general.setContext then
    gameplay_drift_general.setContext("inFreeroam")
  end
  core_gamestate.setGameState("freeroam", "freeroam", "freeroam")
  local appContainers = getGameplayAppContainers()
  if appContainers and appContainers.hideApp then appContainers.hideApp("gameplayApps", "drift") end
end

local function preloadFreeroamAiPathsForTrack()
  if hostRefs.competitiveTrackFlow and hostRefs.competitiveTrackFlow.preloadAiPathsForTrack then
    hostRefs.competitiveTrackFlow.preloadAiPathsForTrack()
  end
end

-- Map markers -------------------------------------------------------------------------------------

local function findByName(entries, name)
  if type(name) ~= "string" or name == "" or type(entries) ~= "table" then return nil end
  for _, entry in ipairs(entries) do
    if type(entry) == "table" and entry.name == name then return entry end
  end
  return nil
end

local function getZoneByName(sitesData, zoneName)
  return findByName(type(sitesData) == "table" and sitesData.zones, zoneName)
end

local function getParkingSpotByName(sitesData, spotName)
  return findByName(type(sitesData) == "table" and sitesData.parkingSpots, spotName)
end

local function getZoneCentroid(zone)
  if type(zone) ~= "table" or type(zone.vertices) ~= "table" or #zone.vertices < 3 then return nil end
  local sumX, sumY, sumZ = 0, 0, 0
  local count = 0
  for _, vertex in ipairs(zone.vertices) do
    if type(vertex) == "table" then
      sumX = sumX + (tonumber(vertex[1]) or 0)
      sumY = sumY + (tonumber(vertex[2]) or 0)
      sumZ = sumZ + (tonumber(vertex[3]) or 0)
      count = count + 1
    end
  end
  if count <= 0 then return nil end
  return vec3(sumX / count, sumY / count, sumZ / count)
end

local function getEventPoiPos(raceName)
  local race = hostRefs.session and hostRefs.session.races and hostRefs.session.races[raceName]
  for _, role in ipairs({ "start", "staging" }) do
    for _, name in ipairs(eventHelpers.sceneTriggerNames(raceName, race, role)) do
      local marker = scenetree.findObject(name)
      if marker then return marker:getPosition() end
    end
  end
  return nil
end

local function getDemoPoiPos(eventKey, eventConfig, demoSites)
  local spotName = type(eventConfig) == "table" and eventConfig.startSpotName or nil
  if type(spotName) ~= "string" or spotName == "" then spotName = "start_" .. tostring(eventKey or "") end
  local startSpot = getParkingSpotByName(demoSites, spotName)
  if type(startSpot) == "table" and type(startSpot.pos) == "table" then
    local x, y, z = tonumber(startSpot.pos[1]), tonumber(startSpot.pos[2]), tonumber(startSpot.pos[3])
    if x and y and z then return vec3(x, y, z) end
  end
  local markerPos = getEventPoiPos(eventKey)
  if markerPos then return markerPos end
  local zoneName = type(eventConfig) == "table" and eventConfig.playZone or nil
  return getZoneCentroid(getZoneByName(demoSites, zoneName))
end

local function formatEventPoi(raceName, race, posOverride)
  local pos = posOverride or getEventPoiPos(raceName)

  if not pos then return nil end

  local levelIdentifier = getCurrentLevelIdentifier()
  local preview = eventArtwork.resolve(levelIdentifier, raceName, race.thumbnail)

  local vehId = be:getPlayerVehicleID(0) or 0
  if overhaul_career_career.isActive() then
    vehId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(vehId) or vehId
  end

  local description = nil
  if hostRefs.session and hostRefs.session.races and hostRefs.session.races[raceName] then
    description = hostRefs.utils.displayStagedMessage(vehId, raceName, true)
  elseif type(race) == "table" then
    local reward = math.floor(tonumber(race.reward) or 0)
    if reward > 0 then
      description = string.format("%s\nReward: $%d", tostring(race.label or raceName), reward)
    else
      description = tostring(race.label or raceName)
    end
  end

  return {
    id = raceName,
    data = {
      type = "events",
      facility = {},
    },
    markerInfo = {
      bigmapMarker = {
        pos = pos,
        icon = "mission_cup_triangle",
        name = race.label,
        description = description,
        previews = preview and { preview } or {},
        thumbnail = preview,
        cardIcon = "raceFlag",
      },
    },
  }
end

-- Parts -------------------------------------------------------------------------------------------

local sessionFlow = require("overhaul/events/host/hostSession").create({
  notifyFreContractsFreeroamUi = notifyFreContractsFreeroamUi,
  getDisplayTotalLapsForRace = getDisplayTotalLapsForRace,
  hideStagedFlashMessage = hideStagedFlashMessage,
  suppressVanillaDriftMissionUi = suppressVanillaDriftMissionUi,
  trafficRestoreStamp = trafficRestoreStamp,
  restoreTrafficIfCurrent = restoreTrafficIfCurrent,
})

local triggers = require("overhaul/events/host/hostTriggers").create({
  syncReplayFlagFromCore = syncReplayFlagFromCore,
  notifyFreContractsFreeroamUi = notifyFreContractsFreeroamUi,
  getVehicleSpeedMph = getVehicleSpeedMph,
  getDisplayTotalLapsForRace = getDisplayTotalLapsForRace,
  hideStagedFlashMessage = hideStagedFlashMessage,
  sessionFlow = sessionFlow,
})

local function bindChildModules()
  hostRefs.session = overhaul_events_session
  hostRefs.processRoad = overhaul_events_roadCheckpoints
  hostRefs.leaderboardManager = overhaul_events_leaderboards
  hostRefs.checkpointManager = overhaul_events_checkpointManager
  hostRefs.utils = overhaul_events_utils
  hostRefs.pits = overhaul_events_pits
  hostRefs.aiRacers = overhaul_events_aiRacers
  hostRefs.circuitRaceAi = overhaul_events_circuitRaceAi
  hostRefs.competitiveTrackFlow = overhaul_events_competitiveTrackFlow
  hostRefs.demolitionDerby = overhaul_events_derby_derby
  hostRefs.tractorPull = overhaul_events_tractorPull
  hostRefs.raceSession = overhaul_events_raceSession
  if overhaul_events_activeAssets and overhaul_events_activeAssets.ActiveAssets then
    hostRefs.Assets = overhaul_events_activeAssets.ActiveAssets.new()
  end
  if hostRefs.competitiveTrackFlow then
    hostRefs.trackFlowState = hostRefs.competitiveTrackFlow.trackFlowState
  end
  sessionFlow.bind(hostRefs)
  triggers.bind(hostRefs)
end

-- Per-frame update --------------------------------------------------------------------------------

local function onUpdate(dtReal, dtSim, dtRaw)
  -- Runs every frame: read the bound child modules once, and skip the frame until all of them are bound.
  local session, raceSession, processRoad = hostRefs.session, hostRefs.raceSession, hostRefs.processRoad
  local competitiveTrackFlow, circuitRaceAi = hostRefs.competitiveTrackFlow, hostRefs.circuitRaceAi
  local demolitionDerby, tractorPull = hostRefs.demolitionDerby, hostRefs.tractorPull

  if not session or not competitiveTrackFlow or not raceSession or not processRoad or not circuitRaceAi then return end

  if demolitionDerby and demolitionDerby.update then demolitionDerby.update(dtSim) end

  if tractorPull and tractorPull.update then tractorPull.update(dtSim) end

  competitiveTrackFlow.onUpdateParkingResolve()
  competitiveTrackFlow.onUpdateParkingLoop()
  competitiveTrackFlow.onUpdateRacingTeamProxyParkingLoop()

  if session.mActiveRace and raceSession.raceUsesProcessRoadExit(session.races[session.mActiveRace]) then
    if os.time() >= session.mSuppressOffRoadExitUntil then
      roadCheckAccumulator = roadCheckAccumulator + math.max(0, tonumber(dtSim) or 0)
      if roadCheckAccumulator >= ROAD_CHECK_INTERVAL then
        local elapsed = roadCheckAccumulator
        roadCheckAccumulator = 0
        if processRoad.checkPlayerOnRoad(elapsed) == false then sessionFlow.exitRace(false) end
      end
    else
      roadCheckAccumulator = 0
    end
  else
    roadCheckAccumulator = 0
  end
  if session.timerActive == true then
    if not (session.dragPracticeActive and eventHelpers.raceHasType(session.races[session.mActiveRace], "drag")) then
      session.in_race_time = session.in_race_time + dtSim
    end
    circuitRaceAi.onWaypointPollAccum(dtSim)
    local playerVehicleId = be:getPlayerVehicleID(0)
    if playerVehicleId then
      local currentSpeed = getVehicleSpeedMph(playerVehicleId)
      if currentSpeed > session.maxSpeed then session.maxSpeed = currentSpeed end
    end
    raceSession.pushFreeroamRaceHudState(false)
  else
    session.in_race_time = 0
    if raceSession.isRaceHudShown() and not session.timerActive then raceSession.pushFreeroamRaceHudState(false) end
  end
end

-- Lifecycle ---------------------------------------------------------------------------------------

local function resetTrackFlowForLevel()
  local competitiveTrackFlow = hostRefs.competitiveTrackFlow
  if not competitiveTrackFlow then return end
  if competitiveTrackFlow.resetTrackGridFlowFlags then competitiveTrackFlow.resetTrackGridFlowFlags() end
  if competitiveTrackFlow.trackFlowState then competitiveTrackFlow.trackFlowState.inTrackFlowContext = false end
  if competitiveTrackFlow.clearSanctionedCareerGoToRaceActive then
    competitiveTrackFlow.clearSanctionedCareerGoToRaceActive()
  end
end

local function reloadForCurrentLevel()
  local sessionExt = "overhaul_events_session"
  setExtensionUnloadMode(sessionExt, "manual")
  if not extensions.isExtensionLoaded(sessionExt) then extensions.load(sessionExt) end
  bindChildModules()
  if not hostRefs.session or not hostRefs.utils then return end
  if hostRefs.session.resetState then hostRefs.session.resetState() end
  if hostRefs.raceSession and hostRefs.raceSession.hideFreeroamRaceHud then
    hostRefs.raceSession.hideFreeroamRaceHud(true)
  end
  resetTrackFlowForLevel()
  if hostRefs.processRoad and hostRefs.processRoad.reset then hostRefs.processRoad.reset() end
  if hostRefs.checkpointManager and hostRefs.checkpointManager.removeCheckpoints then
    hostRefs.checkpointManager.removeCheckpoints()
  end
  if hostRefs.circuitRaceAi and hostRefs.circuitRaceAi.clearAll then hostRefs.circuitRaceAi.clearAll() end
  if hostRefs.utils.resetSceneBoundCaches then hostRefs.utils.resetSceneBoundCaches() end
  hostRefs.session.races = hostRefs.utils.loadRaceData()
  syncReplayFlagFromCore()
  preloadFreeroamAiPathsForTrack()
  if gameplay_rawPois and gameplay_rawPois.clear then gameplay_rawPois.clear() end
  if overhaul_events_fre_raceCache and overhaul_events_fre_raceCache.refreshRaceCache then
    overhaul_events_fre_raceCache.refreshRaceCache()
  end
end

local function resetEventStateForCareerChange()
  bindChildModules()
  invalidateTrafficRestores()
  local session = hostRefs.session
  if not session then return end
  local hadRace = session.mActiveRace ~= nil or session.staged ~= nil
  if hostRefs.demolitionDerby and hostRefs.demolitionDerby.hardResetForCareerChange then
    hostRefs.demolitionDerby.hardResetForCareerChange()
  end
  if hostRefs.competitiveTrackFlow and hostRefs.competitiveTrackFlow.resetForCareerChange then
    hostRefs.competitiveTrackFlow.resetForCareerChange()
  end
  if overhaul_events_fre_sanctionedRacing and overhaul_events_fre_sanctionedRacing.resetRuntimeForCareerChange then
    overhaul_events_fre_sanctionedRacing.resetRuntimeForCareerChange()
  end
  if hostRefs.aiRacers then
    if hostRefs.aiRacers.setDnfCallback then hostRefs.aiRacers.setDnfCallback(nil) end
    if hostRefs.aiRacers.clearSpawned then hostRefs.aiRacers.clearSpawned() end
  end
  if hostRefs.circuitRaceAi and hostRefs.circuitRaceAi.clearAll then hostRefs.circuitRaceAi.clearAll() end
  if hadRace and hostRefs.pits and hostRefs.pits.clearSpeedLimit then hostRefs.pits.clearSpeedLimit() end
  if hostRefs.checkpointManager and hostRefs.checkpointManager.removeCheckpoints then
    hostRefs.checkpointManager.removeCheckpoints()
  end
  if hostRefs.processRoad and hostRefs.processRoad.reset then hostRefs.processRoad.reset() end
  if hostRefs.raceSession and hostRefs.raceSession.hideFreeroamRaceHud then
    hostRefs.raceSession.hideFreeroamRaceHud(true)
  end
  if session.resetState then
    local races = session.races
    session.resetState()
    session.races = races
  end
  if hadRace and hostRefs.utils and hostRefs.utils.restoreTrafficAmount then hostRefs.utils.restoreTrafficAmount() end
end

local function onWorldReadyState(state)
  if state ~= 2 then return end
  reloadForCurrentLevel()
end

local function onClientStartMission()
  reloadForCurrentLevel()
end

local function onOverhaulActive(active)
  if active then return end
  resetEventStateForCareerChange()
end

local function onClientEndMission()
  resetEventStateForCareerChange()
end

local function onExtensionLoaded()
  local names, preserved = overhaul_shell_extensionManager.childrenOf("overhaul_events_host")
  loadedExtensions = require("overhaul/lib/shell/childExtensions").load(names, preserved) or loadedExtensions
  reloadForCurrentLevel()
end

local function onExtensionUnloaded()
  if hostRefs.raceSession then hostRefs.raceSession.hideFreeroamRaceHud(true) end
  if require("overhaul/lib/shell/childExtensions").unload(loadedExtensions) == false then return false end
  loadedExtensions = {}
end

local function onReplayStateChanged(state)
  if not hostRefs.session or not state then return end
  if state.state == "playback" then
    hostRefs.session.isReplay = true
  elseif state.state == "inactive" then
    hostRefs.session.isReplay = false
  end
end

local function onGameStateUpdate(state)
  if hostRefs.session.saveGameState then
    hostRefs.session.saveGameState = false
    hostRefs.session.previousGameState = state
  end
end

-- Public API --------------------------------------------------------------------------------------

--- Abandon the active competitive track race (same as player leaving the race zone). Used by racing-team proxy cancel UI.
function M.forceAbandonActiveTrackRace(customMessage)
  if not hostRefs.session or not hostRefs.competitiveTrackFlow then return false end
  if not hostRefs.competitiveTrackFlow.raceUsesSanctionedParkingStaging(hostRefs.session.mActiveRace) then return false end
  local playerVid = be:getPlayerVehicleID(0)
  sessionFlow.exitRace(false, customMessage or "Team race cancelled", nil, playerVid)
  return true
end

M.payoutRace = function(completedLapTime)
  if hostRefs.raceSession then return hostRefs.raceSession.payoutRace(completedLapTime) end
  return 0
end
M.payoutDragRace = function(raceName, finishTime, finishSpeed, vehId, disqualified)
  if hostRefs.raceSession then
    return hostRefs.raceSession.payoutDragRace(raceName, finishTime, finishSpeed, vehId, disqualified)
  end
  return 0
end
M.reloadForCurrentLevel = reloadForCurrentLevel
M.getRace = function(raceName)
  if not hostRefs.session or not hostRefs.session.races then return nil end
  return hostRefs.session.races[raceName]
end
-- AI lap counting: returns { inRaceTime, vehicles = { { index, session.lapCount, totalLaps, lapTimes, lastLapTime, finished, finishTime, currentLapTime }, ... } } or nil. Use from console to gauge AI times.
M.getAiLapState = function()
  if hostRefs.circuitRaceAi then return hostRefs.circuitRaceAi.getAiLapStateForDisplay() end
  return nil
end

M.clearFreSummarySession = function()
  if hostRefs.raceSession then hostRefs.raceSession.clearFreSummarySession() end
end

M.startSanctionedRaceDispatch = function(useAltRoute, poolReferenceHpOverride, raceName)
  local session, trackFlowState = hostRefs.session, hostRefs.trackFlowState
  if not session or not hostRefs.utils or not hostRefs.competitiveTrackFlow then return end
  if not session.races then session.races = hostRefs.utils.loadRaceData() end
  raceName = raceName or hostRefs.competitiveTrackFlow.getCompetitiveRaceId()
  local ok, reason = hostRefs.competitiveTrackFlow.setCompetitiveRace(raceName, useAltRoute)
  if not ok then hostRefs.utils.displayMessage(reason, 5); return false, reason end
  preloadFreeroamAiPathsForTrack()
  session.staged = nil
  notifyFreContractsFreeroamUi()
  hostRefs.competitiveTrackFlow.resetTrackGridFlowFlags()
  trackFlowState.sanctionedPoolRefPw = (type(poolReferenceHpOverride) == "number" and poolReferenceHpOverride > 0)
      and poolReferenceHpOverride
    or nil
  trackFlowState.sanctionedPoolRefHp = nil
  trackFlowState.sanctionedRaceLapCount = nil
  if overhaul_events_fre_sanctionedRacing and overhaul_events_fre_sanctionedRacing.getSanctionedOfferLapCount then
    local lc = overhaul_events_fre_sanctionedRacing.getSanctionedOfferLapCount()
    if lc then trackFlowState.sanctionedRaceLapCount = lc end
  end
  trackFlowState.inTrackFlowContext = true
  trackFlowState.useAltRoute = useAltRoute == true
  hostRefs.competitiveTrackFlow.setSanctionedCareerGoToRaceActive(true)
  hideStagedFlashMessage()
  if core_groundMarkers and core_groundMarkers.resetAll then core_groundMarkers.resetAll() end
  session.saveGameState = true
  core_gamestate.requestGameState()
  sessionFlow.applySavedStagingSpotNavigation()
  return true
end

M.beginFreeroamRace = sessionFlow.beginFreeroamRace
M.hideStagedFlashMessage = hideStagedFlashMessage
M.hideAllFreeroamAssets = function()
  if hostRefs.Assets then hostRefs.Assets:hideAllAssets() end
end

M.clearSanctionedDispatchStaging = function()
  if not hostRefs.session or hostRefs.session.mActiveRace then return end
  local raceName = hostRefs.competitiveTrackFlow and hostRefs.competitiveTrackFlow.getCompetitiveRaceId()
  hostRefs.session.staged = nil
  if hostRefs.raceSession and hostRefs.raceSession.setStagingSubjectId then
    hostRefs.raceSession.setStagingSubjectId(nil)
  end
  if raceName and hostRefs.utils and hostRefs.utils.setActiveLight then hostRefs.utils.setActiveLight(raceName, "red") end
  if hostRefs.raceSession and hostRefs.raceSession.hideFreeroamRaceHud then hostRefs.raceSession.hideFreeroamRaceHud() end
  hideStagedFlashMessage()
  M.hideAllFreeroamAssets()
  if hostRefs.competitiveTrackFlow and hostRefs.competitiveTrackFlow.clearSanctionedNavigateVisuals then
    hostRefs.competitiveTrackFlow.clearSanctionedNavigateVisuals()
  end
  notifyFreContractsFreeroamUi()
end

M.getFreeroamRaceLabel = sessionFlow.getRaceLabel
M.getFreeroamDisplayRaceLabel = sessionFlow.getDisplayRaceLabel
M.runDeferredProxyRaceCompletion = sessionFlow.runDeferredProxyRaceCompletion

-- Game hooks --------------------------------------------------------------------------------------

function M.onGetRawPoiListForLevel(_, elements)
  local seen = {}

  if hostRefs.session and hostRefs.session.races then
    for raceName, race in pairs(hostRefs.session.races) do
      local poi = formatEventPoi(raceName, race)
      if poi then
        table.insert(elements, poi)
        seen[raceName] = true
      end
    end
  end

  local derby = hostRefs.demolitionDerby
  if not derby then return end
  for _, eventKey in ipairs(derby.getAvailableEventKeys()) do
    if not seen[eventKey] then
      local merged, demoSites = derby.getEventLocation(eventKey)
      if merged then
        merged.label = merged.label or eventKey
        merged.type = type(merged.type) == "table" and merged.type or { "demo" }
        local demoPos = getDemoPoiPos(eventKey, merged, demoSites)
        local poi = formatEventPoi(eventKey, merged, demoPos)
        if poi then
          table.insert(elements, poi)
          seen[eventKey] = true
        end
      end
    end
  end
end

M.onGameStateUpdate = onGameStateUpdate
M.onReplayStateChanged = onReplayStateChanged
M.onBeamNGTrigger = triggers.onBeamNGTrigger
M.onUpdate = onUpdate
M.onVehicleSwitched = triggers.onVehicleSwitched
M.onWorldReadyState = onWorldReadyState
M.onClientStartMission = onClientStartMission
M.onClientEndMission = onClientEndMission
M.onOverhaulActive = onOverhaulActive
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded

-- The four event owners this host runs, published as one activity.
M.activity = require("overhaul/events/host/hostActivity")(M)

return M
