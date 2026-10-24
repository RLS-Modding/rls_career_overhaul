-- Runs drag strips through the stock freeroam core with event rewards, save holds and traffic suppression.
-- Reading order: geometry, tree lights, strip setup, activity, traffic, racer HUD, hooks and lifecycle.
local eventHelpers = require("overhaul/lib/events/helpers")
local saveStore = require("overhaul/lib/save/store")
local M = {}

-- Only an active RLS race keeps the drag modules loaded; otherwise they are the level's presets.
M.dependencies = {}

local logTag = "dragFreeroamBridge"

-- Config ------------------------------------------------------------------------------------------

-- BeamNG 0.39 removed dragPracticeRace and headsUpDrag; map packs still ship them.
local LEGACY_DRAG_TYPES = {
  dragPracticeRace = true,
  headsUpDrag = true,
}

-- Each tree light the lane tree owns, and its authored lane-light key.
local STAGE_LIGHT_SLOTS = {
  {group = "stageLights", key = "prestageLight", binding = "prestage"},
  {group = "stageLights", key = "stageLight", binding = "stage"},
  {group = "stageLights", key = "winnerLight", binding = "winTimeboard"},
  {group = "stageLights", key = "driverLight", binding = "winDriver"},
  {group = "countDownLights", key = "amberLight1", binding = "amber1"},
  {group = "countDownLights", key = "amberLight2", binding = "amber2"},
  {group = "countDownLights", key = "amberLight3", binding = "amber3"},
  {group = "countDownLights", key = "greenLight", binding = "green"},
  {group = "countDownLights", key = "redLight", binding = "red"},
}

local MPH_PER_MPS = 2.2369362921
local TRAFFIC_OFF = 0

-- Drag modules that exist only while an RLS freeroam race retains them.
local LAZY_DRAG_DEPENDENCIES = {"gameplay_drag_dragTypes_headsUpRace", "gameplay_drag_phaseHandlers", "gameplay_drag_times", "gameplay_drag_display"}

-- State -------------------------------------------------------------------------------------------

local state = {
  startedDragData = nil,
  startedDragExtension = nil,
  retainedDragData = nil,
  levelEnded = false,
  trafficSuppressed = false,
  flashHidePending = false,
  suppressSystemResetOnce = false,
  saveHold = nil,
  runFinished = false,
  disqualifiedRacers = {},
  settledRacers = {},
  unavailableStrips = {},
}

-- Geometry helpers --------------------------------------------------------------------------------

local function asVec3(value)
  if not value then return nil end
  if value.squaredLength then return value end
  if value.x ~= nil and value.y ~= nil and value.z ~= nil then
    return vec3(value.x, value.y, value.z)
  end
  return nil
end

-- A live quat is returned as is; plain JSON tables need wrapping.
local function asQuat(value)
  if not value or value.w == nil or value.x == nil or value.y == nil or value.z == nil then
    return nil
  end
  if type(value) ~= "table" or getmetatable(value) ~= nil then
    return value
  end
  return quat(value.x, value.y, value.z, value.w)
end

-- Match 0.38 drag utils: OBB half-axes are rot * scale components.
local function boundaryCorners(position, rotation, scale)
  local x = rotation * vec3(scale.x, 0, 0)
  local y = rotation * vec3(0, scale.y, 0)
  return {
    position - x - y,
    position + x - y,
    position + x + y,
    position - x + y,
  }
end

local function zoneFromBoundaryTransform(boundary, name)
  local transform = boundary and boundary.transform
  if not transform then return nil end

  local position = asVec3(transform.position)
  local rotation = asQuat(transform.rotation)
  local scale = asVec3(transform.scale)
  if not position or not rotation or not scale then
    return nil
  end

  local ZoneClass = require("/lua/ge/extensions/gameplay/sites/zone")
  local zone = ZoneClass(nil, name or "legacyLaneBoundary")
  for _, corner in ipairs(boundaryCorners(position, rotation, scale)) do
    zone:addVertex(corner)
  end
  return zone
end

-- Lane zones: a legacy lane with only a boundary transform gets a zone built from that transform.
local function ensureLegacyLaneZones(dragData)
  if not dragData or not dragData.strip or not dragData.strip.lanes then
    return false
  end

  local built = false
  for _, lane in ipairs(dragData.strip.lanes) do
    if (not lane.zone or not lane.zone.containsPoint2D) and lane.boundary then
      local zone = zoneFromBoundaryTransform(lane.boundary, (lane.id or "lane") .. "_zone")
      if zone then
        lane.zone = zone
        built = true
      end
    end
  end
  return built
end

-- Tree lights -------------------------------------------------------------------------------------

local function newLaneTree()
  return {
    stageLights = {
      prestageLight = {anim = "prestage", isOn = false},
      stageLight = {anim = "prestage", isOn = false},
      winnerLight = {anim = "prestage", isOn = false},
      driverLight = {anim = "prestage", isOn = false},
    },
    countDownLights = {
      amberLight1 = {anim = "tree", isOn = false},
      amberLight2 = {anim = "tree", isOn = false},
      amberLight3 = {anim = "tree", isOn = false},
      greenLight = {anim = "tree", isOn = false},
      redLight = {anim = "tree", isOn = false},
    },
    globalLights = {},
    timers = {dialOffset = 0, laneTimer = 0, laneTimerFlag = false},
  }
end

local function bindLaneLights(laneTree, lights)
  if type(lights) ~= "table" then return false end
  for _, slot in ipairs(STAGE_LIGHT_SLOTS) do
    local name = lights[slot.binding]
    if name ~= nil then
      local light = laneTree[slot.group][slot.key]
      light.obj = scenetree.findObject(name)
      if not light.obj then log("W", logTag, "Drag light unavailable: " .. tostring(name)) end
    end
  end
  return true
end

local function bindBlueLight(firstLaneTree, treeConfig)
  local name = treeConfig and treeConfig.blueLight
  if not name then return false end
  firstLaneTree.globalLights = firstLaneTree.globalLights or {}
  firstLaneTree.globalLights.blueLight = {
    obj = scenetree.findObject(name), anim = "prestage", isOn = false,
  }
  if not firstLaneTree.globalLights.blueLight.obj then
    log("W", logTag, "Drag light unavailable: " .. tostring(name))
  end
  return true
end

local function bindTreeLights(dragData)
  if not dragData or not dragData.strip or not dragData.strip.lanes then
    return false
  end

  local treeLights = dragData.strip.treeLights
  if not treeLights then
    treeLights = {}
    dragData.strip.treeLights = treeLights
  end

  local rebound = false
  for laneIndex = 1, #dragData.strip.lanes do
    local laneTree = treeLights[laneIndex]
    if not laneTree then
      laneTree = newLaneTree()
      treeLights[laneIndex] = laneTree
      if type(dragData.strip.lanes[laneIndex].lights) ~= "table" then
        log("W", logTag, "Drag lane lights unavailable: no bindings for lane " .. tostring(laneIndex))
      end
    end
    if bindLaneLights(laneTree, dragData.strip.lanes[laneIndex].lights) then rebound = true end
  end

  if treeLights[1] and bindBlueLight(treeLights[1], dragData.prefabs and dragData.prefabs.christmasTree) then rebound = true end
  return rebound
end

-- Gates: which strips and sessions Overhaul owns --------------------------------------------------

local function overhaulRunning()
  return overhaul_shell_gameMode ~= nil and overhaul_shell_gameMode.isActive() == true
end

local function dragEvent(data, reportMissing)
  local session = overhaul_events_session
  local id, raceOrReason = eventHelpers.resolveDragRace(session and session.races, data,
    session and (session.mActiveRace or session.staged))
  local stripId = data and data.strip and data.strip.id
  if not id and reportMissing and stripId and not state.unavailableStrips[stripId] then
    state.unavailableStrips[stripId] = true
    log("W", logTag, "Overhaul drag event unavailable for " .. stripId .. ": " .. tostring(raceOrReason))
  end
  return id, id and raceOrReason or nil
end

-- Leave stock freeroam strips alone unless they are legacy strips or the level supplies an RLS drag event.
local function isRlsStrip(data)
  if type(data) ~= "table" or data.context ~= "freeroam" then return false end
  return overhaulRunning() or data.rlsLegacyStrip == true or dragEvent(data) ~= nil
end

local function isFreeroamDrag()
  if not gameplay_drag_core or not gameplay_drag_core.getGameplayContext then
    return false
  end
  return gameplay_drag_core.getGameplayContext() == "freeroam"
end

local function isRlsDrag()
  return isFreeroamDrag() and gameplay_drag_core.getData ~= nil and isRlsStrip(gameplay_drag_core.getData())
end

-- Strip setup -------------------------------------------------------------------------------------

-- The level's strip list is what the game's stage POIs start races from, so legacy types are remapped there.
local function adoptLegacyStrips(levelIdentifier)
  local core = gameplay_drag_core
  if not core or not core.getDragDataForLevel or not core.isDragEnabled or not core.isDragEnabled() then return end
  for _, data in ipairs(core.getDragDataForLevel(levelIdentifier) or {}) do
    if LEGACY_DRAG_TYPES[data.dragType] then
      log("I", logTag, string.format('Remapping legacy dragType "%s" -> headsUpRace', tostring(data.dragType)))
      data.dragType = "headsUpRace"
      data.rlsLegacyStrip = true
    end
  end
end

-- The strip's tree remains authoritative unless this event explicitly requests another policy.
local function applyEventTreePolicy(dragData)
  local _, race = dragEvent(dragData)
  local treeType = race and race.dragTreeType
  if not treeType then return end
  dragData.prefabs = dragData.prefabs or {}
  dragData.prefabs.christmasTree = dragData.prefabs.christmasTree or {}
  dragData.prefabs.christmasTree.treeType = treeType
end

local function prepareRlsStrip(dragData)
  applyEventTreePolicy(dragData)
  if ensureLegacyLaneZones(dragData) then
    log("I", logTag, "Synthesized lane zones from legacy boundary transforms")
  end
end

-- stage() re-measures the wheels on its first frame but keeps the old distance; measure before staging.
local function settleRacerGeometry(racer)
  local core = gameplay_drag_core
  local phase = racer.phases and racer.phases[racer.currentPhase]
  if phase and phase.name == "stage" and not phase.wheelGeometryUpdated
    and racer.isLocalRacer ~= false and not racer.vehicleRemoved and racer.vehId then
    local vehicle = scenetree.findObjectById and scenetree.findObjectById(racer.vehId)
    if vehicle then
      core.setRacerWheelGeometry(racer, vehicle)
      phase.wheelGeometryUpdated = true
      racer.currentDistanceFromOrigin = nil
    end
  end
end

-- Otherwise core's runaway check measures from the origin and clears the session.
local function settleStageGeometry(dragData)
  local core = gameplay_drag_core
  if not dragData or not dragData.racers or not core or not core.setRacerWheelGeometry then return end
  for _, racer in pairs(dragData.racers) do
    settleRacerGeometry(racer)
  end
end

-- Lazy drag dependencies --------------------------------------------------------------------------

local function removeLazyDependencies()
  for i = #M.dependencies, 1, -1 do
    for _, name in ipairs(LAZY_DRAG_DEPENDENCIES) do
      if M.dependencies[i] == name then table.remove(M.dependencies, i); break end
    end
  end
end

local function releaseDragDependencies()
  if not state.retainedDragData then return end
  state.retainedDragData = nil
  removeLazyDependencies()
end

local function retainDragDependencies(data)
  if state.retainedDragData == data then return end
  releaseDragDependencies()
  state.retainedDragData = data
  local missing = {}
  for _, name in ipairs(LAZY_DRAG_DEPENDENCIES) do
    M.dependencies[#M.dependencies + 1] = name
    local loaded = extensions.isExtensionLoaded and extensions.isExtensionLoaded(name) or rawget(_G, name) ~= nil
    if not loaded then missing[#missing + 1] = name end
  end
  if #missing > 0 then extensions.load(missing) end
end

-- Activity ----------------------------------------------------------------------------------------

local function releaseSaveHold()
  if not state.saveHold then return end
  state.saveHold.release()
  state.saveHold = nil
end

local function holdRun(data)
  if data.isCompleted or state.runFinished then releaseSaveHold(); return end
  if state.saveHold then return end
  -- Staging can sit stationary long enough to trigger autosave before the tree starts.
  state.saveHold = saveStore.hold(M, "drag run", {stage = "beforeRoute"})
end

-- Multiplayer sessions keep the game's save and activity ownership.
local function getFreeroamRunData()
  if not isRlsDrag() then return end
  local core = gameplay_drag_core
  local gamemode = core.getDragGamemode and core.getDragGamemode()
  if gamemode and gamemode.isMultiplayer and gamemode.isMultiplayer() then return end
  local data = core.getData()
  if not data or not data.racers or not next(data.racers) then return end
  return data
end

local function startLiveActivity(data, live)
  live.startActivity()
  state.startedDragData, state.startedDragExtension = data, live
end

local function syncFreeroamDragActivity()
  -- A race the level ended with must not keep the drag modules into the next level.
  local data = not state.levelEnded and getFreeroamRunData()
  if not data then releaseSaveHold(); releaseDragDependencies(); return end
  holdRun(data)
  if data.dragType ~= "headsUpRace" then releaseDragDependencies(); return end
  retainDragDependencies(data)
  local core = gameplay_drag_core
  local live = gameplay_drag_dragTypes_headsUpRace
  if not live or not live.startActivity then return end
  if core.setExtension then core.setExtension(live) end
  -- Lazy drag extensions can be replaced while core still owns an active race.
  if data.isStarted and not data.isCompleted and (state.startedDragData ~= data or state.startedDragExtension ~= live) then
    startLiveActivity(data, live)
  end
end

-- Traffic and flash -------------------------------------------------------------------------------

local function suppressTrafficIfNeeded()
  if state.trafficSuppressed then return end
  if not overhaul_events_utils or not overhaul_events_utils.saveAndSetTrafficAmount then
    return
  end
  overhaul_events_utils.saveAndSetTrafficAmount(TRAFFIC_OFF)
  state.trafficSuppressed = true
end

local function restoreTrafficIfNeeded()
  if not state.trafficSuppressed then return end
  if overhaul_events_utils and overhaul_events_utils.restoreTrafficAmount then
    overhaul_events_utils.restoreTrafficAmount()
  end
  state.trafficSuppressed = false
end

local function gameplayAppContainers()
  return (rawget(extensions, "ui_gameplayAppContainers") or rawget(extensions, "ge_extensions_ui_gameplayAppContainers"))
end

local function hideDragFlash()
  guihooks.trigger("ScenarioFlashMessage", {msg = "", ttl = 0, clearQueue = true})
  guihooks.trigger("TopCenterAppsFlashMessage", {msg = "", ttl = 0, clearQueue = true})
  if ui_appContainers and ui_appContainers.hideApp then
    ui_appContainers.hideApp("topCenter", "flashMessage")
  end
  local containers = gameplayAppContainers()
  if containers and containers.hideApp then
    containers.hideApp("gameplayApps", "flashMessage")
  end
end

-- The game's drag flashes come from its own hook handlers, which may run after this one; clear again next frame.
local function clearDragFlash()
  hideDragFlash()
  state.flashHidePending = true
end

-- Racer HUD ---------------------------------------------------------------------------------------

local function getPlayableRacer(vehId)
  local dragData = gameplay_drag_core and gameplay_drag_core.getData and gameplay_drag_core.getData()
  if not dragData or not dragData.racers then return nil end
  local racer = dragData.racers[vehId]
  if racer and racer.isPlayable then return racer end
  return nil
end

local function firstPlayableRacer(dragData)
  for _, racer in pairs(dragData.racers) do
    if racer.isPlayable then return racer end
  end
  return nil
end

-- Stock emits this hook for every DQ reason. Retain it until the next pass even if
-- another drag handler changes the racer's fields before settlement.
local function onDisqualified(vehId)
  if not isRlsDrag() then return end
  local racer = getPlayableRacer(vehId)
  if not racer then return end
  clearDragFlash()
  if state.disqualifiedRacers[vehId] == racer then return end
  state.disqualifiedRacers[vehId] = racer
  local reason = racer.disqualifiedReason or racer.desqualifiedReason
  if not reason or reason == "None" then reason = "Disqualified" end
  ui_message({txt = reason}, 5, "dragDisqualified", "warning")
end

local function suppressVanillaDragHud(force)
  local raceSession = overhaul_events_raceSession
  if not raceSession or not raceSession.suppressVanillaDragHudApps then return end
  raceSession.suppressVanillaDragHudApps(force)
end

local function endHud()
  local raceSession = overhaul_events_raceSession
  if raceSession and raceSession.endDragPracticeFreeroamHud then
    raceSession.endDragPracticeFreeroamHud()
  end
end

local function showCountdownHud(raceSession, vehId)
  local raceId = dragEvent(gameplay_drag_core.getData())
  if not raceId then return end
  if not raceSession or not raceSession.isRaceHudShown or not raceSession.isRaceHudShown() then
    if raceSession and raceSession.beginDragPracticeFreeroamHud then
      raceSession.beginDragPracticeFreeroamHud(vehId, raceId)
    end
  end
end

local function startRaceHud(raceSession, vehId)
  local raceId = dragEvent(gameplay_drag_core.getData())
  if raceId and raceSession and raceSession.isRaceHudShown and not raceSession.isRaceHudShown() and raceSession.beginDragPracticeFreeroamHud then
    raceSession.beginDragPracticeFreeroamHud(vehId, raceId)
  end
  if raceId and raceSession and raceSession.isRaceHudShown and raceSession.isRaceHudShown() then
    raceSession.beginDragPracticeFreeroamRace(vehId, raceId)
  end
end

-- Pays on race-phase completion (end line), not after the stop phase.
local function payOutDragRace(racer, vehId)
  if state.settledRacers[vehId] == racer then return end
  local raceId = dragEvent(gameplay_drag_core.getData(), true)
  if not raceId then return end
  local elapsed = racer.timers and racer.timers.time_1_4 and racer.timers.time_1_4.value
  if not elapsed or elapsed <= 0 then return end
  if overhaul_events_host and overhaul_events_host.payoutDragRace then
    local disqualified = state.disqualifiedRacers[vehId] == racer
      or racer.isDisqualified == true or racer.isDesqualified == true
    state.settledRacers[vehId] = racer
    overhaul_events_host.payoutDragRace(raceId, elapsed, racer.vehSpeed * MPH_PER_MPS, vehId, disqualified)
  end
end

-- Drag hooks --------------------------------------------------------------------------------------

local function onDragDataSet(dragData)
  releaseSaveHold()
  state.runFinished = false
  state.disqualifiedRacers, state.settledRacers = {}, {}
  if not isRlsStrip(dragData) then return end
  if not state.levelEnded and getFreeroamRunData() == dragData then holdRun(dragData) end
  dragEvent(dragData, true)
  prepareRlsStrip(dragData)
  if bindTreeLights(dragData) then
    log("I", logTag, "Bound configured christmas-tree light scene objects")
  end
  -- dragBridge.onDragDataSet re-shows topLeft dragInfo; hide again for FRE practice.
  if isFreeroamDrag() then
    suppressVanillaDragHud()
  end
end

local function onDragRacersSetup(dragData)
  if state.levelEnded or not dragData or getFreeroamRunData() ~= dragData then return end
  state.runFinished = false
  holdRun(dragData)
  suppressTrafficIfNeeded()
  settleStageGeometry(dragData)
  bindTreeLights(dragData)
  syncFreeroamDragActivity()

  local raceSession = overhaul_events_raceSession
  if not raceSession then return end
  local playable = firstPlayableRacer(dragData)
  local raceId = dragEvent(dragData, true)
  if playable and raceId then raceSession.beginDragPracticeFreeroamHud(playable.vehId, raceId) end
  suppressVanillaDragHud(true)
end

local function onRacerPhaseTransition(vehId, oldPhase, newPhase, newPhaseName)
  if not isRlsDrag() then return end
  local racer = getPlayableRacer(vehId)
  if not racer then return end

  local raceSession = overhaul_events_raceSession
  if newPhaseName == "countdown" then
    showCountdownHud(raceSession, vehId)
  elseif newPhaseName == "race" then
    startRaceHud(raceSession, vehId)
  elseif newPhaseName == "stop" then
    payOutDragRace(racer, vehId)
  elseif newPhaseName == "finished" then
    state.runFinished = true
    releaseSaveHold()
  end
end

local function onDragReset()
  releaseSaveHold()
  state.runFinished = false
  state.disqualifiedRacers, state.settledRacers = {}, {}
  state.startedDragData, state.startedDragExtension = nil, nil
  if not isRlsDrag() then return end
  settleStageGeometry(gameplay_drag_core.getData())
  endHud()
end

local function onDragClear()
  local wasRlsDrag = isRlsDrag()
  releaseSaveHold()
  restoreTrafficIfNeeded()
  state.runFinished = false
  state.disqualifiedRacers, state.settledRacers = {}, {}
  releaseDragDependencies()
  state.startedDragData, state.startedDragExtension = nil, nil
  endHud()
  if wasRlsDrag then
    state.suppressSystemResetOnce = true
    clearDragFlash()
  end
end

-- The game flashes SYSTEM RESET from its own onDragClear; this hook runs after every onDragClear handler.
local function onDragClearComplete()
  if not state.suppressSystemResetOnce then return end
  state.suppressSystemResetOnce = false
  clearDragFlash()
end

local function onStoppingVehicleDrag()
  if isRlsDrag() then clearDragFlash() end
end

-- Per-frame update --------------------------------------------------------------------------------

local function recordRaceStats(dragData, session)
  for _, racer in pairs(dragData.racers) do
    if racer.isPlayable and racer.phases and racer.currentPhase then
      local phase = racer.phases[racer.currentPhase]
      if phase and phase.name == "race" and racer.timersStarted then
        session.in_race_time = (racer.timers and racer.timers.timer and racer.timers.timer.value) or 0
        local speed = (racer.vehSpeed or 0) * (session.speedUnit or MPH_PER_MPS)
        if speed > (session.maxSpeed or 0) then
          session.maxSpeed = speed
        end
      end
    end
  end
end

local function onUpdate()
  if state.flashHidePending then
    state.flashHidePending = false
    hideDragFlash()
  end
  syncFreeroamDragActivity()
  if not isRlsDrag() then return end
  local dragData = gameplay_drag_core.getData()
  settleStageGeometry(dragData)
  local freeroamSession = overhaul_events_session
  if not freeroamSession then return end

  if freeroamSession.dragPracticeFlow or freeroamSession.dragPracticeActive then
    suppressVanillaDragHud()
  end

  if not freeroamSession.dragPracticeActive then return end
  if not dragData or not dragData.racers then return end
  recordRaceStats(dragData, freeroamSession)
end

-- Lifecycle ---------------------------------------------------------------------------------------

-- Shared by unload and mode stop: drop the lazy modules, the traffic cut, the HUD and the started race.
local function resetDragActivity()
  state.levelEnded = true
  releaseSaveHold()
  releaseDragDependencies()
  restoreTrafficIfNeeded()
  endHud()
  state.startedDragData, state.startedDragExtension = nil, nil
  state.runFinished = false
  state.disqualifiedRacers, state.settledRacers = {}, {}
end

-- Game hooks --------------------------------------------------------------------------------------

M.onExtensionUnloaded = resetDragActivity
M.onGetRawPoiListForLevel = adoptLegacyStrips
M.onDragDataSet = onDragDataSet
M.onDragRacersSetup = onDragRacersSetup
M.onRacerPhaseTransition = onRacerPhaseTransition
M.setDisqualifiedLights = onDisqualified
M.onDragReset = onDragReset
M.onDragClear = onDragClear
M.onDragClearComplete = onDragClearComplete
M.stoppingVehicleDrag = onStoppingVehicleDrag
M.onBeforeDragUnloadAllExtensions = function()
  releaseSaveHold()
  releaseDragDependencies()
end
M.onClientEndMission = function()
  state.levelEnded = true
  resetDragActivity()
  state.unavailableStrips = {}
end
M.onClientPreStartMission = function()
  state.levelEnded = false
  state.unavailableStrips = {}
end
M.onOverhaulModeStopped = resetDragActivity
M.onOverhaulActive = function(active) if active then state.levelEnded = false end end
M.onUpdate = onUpdate

return M
