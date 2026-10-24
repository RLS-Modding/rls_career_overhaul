-- Weather for one world: forecasts, effects, clock ownership and saved settings.
-- Read down: config/state, clock helpers, services, frame update, lifecycle, public API and game hooks.
local M = {}
-- The load hook registers its clock wrapper before any later refresh can run.
M.dependencies = {'overhaul_shell_patches'}

local scopeSubscriptions = require("overhaul/lib/ui/scopeSubscriptions")

local timerPolicies = require("overhaul/world/weather/scheduler/timerPolicies")
local model = require("overhaul/world/weather/model")
local environment = require("overhaul/world/weather/environment")
local persistence = require("overhaul/world/weather/persistence")
local clock = require("overhaul/world/weather/clock")
local ui = require("overhaul/world/weather/ui")

-- Config ------------------------------------------------------------------------------------------

local CYCLE_PATCH_ID = "weatherCycleTimeOfDay"

-- State -------------------------------------------------------------------------------------------

-- Cached part modules keep only functions; this load owns every mutable weather field.
local runtime = {
  state = nil,
  profile = nil,
  globalSettings = {temperatureUnit = "F", vulkanSafeMode = false, visualWindScale = 1},
  careerActive = false,
  worldReady = false,
  loaded = false,
  initializedMapId = nil,
  missionFrozen = false,
  travelJournalOverrideActive = false,
  externalOverride = false,
  externalWarningShown = false,
  -- Weather pauses with simulation time; queued material writes keep using real time.
  stateTimer = timerPolicies.timer("weather.state"),
  visualTimer = timerPolicies.timer("weather.visual"),
  wetMaterialTimer = timerPolicies.timer("weather.wetMaterial"),
  lastUiSignature = nil,
  uiScopes = {},
  lastConditionKey = nil,
  lastGripBucket = nil,
  currentConditionName = "clear",
  lastAppliedTimeOfDay = nil,
  notificationHistory = {},
  notificationPruneDay = nil,
  editorSuspended = false,
  editorSaveDepth = 0,
  clockBaseline = nil,
  writingClock = false,
  stockCycleTimeOfDay = nil,

  baseline = nil,
  currentEffect = {},
  effectFrom = {},
  effectTarget = {},
  transitionElapsed = 0,
  transitionDuration = 0,
  transitioning = false,
  rainShown = 0,
  audioRainTimer = 0,
  thunderTimer = -1,
  thunderCooldown = 0,
  environmentApplied = false,
  lastExternalMinute = nil,
  savedRoughness = {},
  savedDiffuse = {},
  roadMaterials = nil,
  materialTargets = {},
  wetMaterialQueue = {},
  wetTargetRoughness = 0,
  wetAppliedRoughness = 0,
  soundBase = nil,
}

local parts = {}

-- Clock helpers -------------------------------------------------------------------------------------

-- Let the stock shortcut pass through whenever weather does not own the clock.
local function registerCycleTimeOfDayPatch()
  overhaul_shell_patches.registerFields(CYCLE_PATCH_ID, function() return rawget(_G, "core_environment") end, {
    cycleTimeOfDay = function(original)
      if type(original) ~= "function" then return end
      runtime.stockCycleTimeOfDay = original
      return parts.clock.cycleTimeOfDay
    end,
  })
end

local function unregisterCycleTimeOfDayPatch()
  if overhaul_shell_patches then overhaul_shell_patches.unregister(CYCLE_PATCH_ID) end
  runtime.stockCycleTimeOfDay = nil
end

-- Parts -------------------------------------------------------------------------------------------

parts.model = model.new({runtime = runtime})
parts.environment = environment.new({runtime = runtime, model = parts.model})
parts.persistence = persistence.new({runtime = runtime, model = parts.model})
parts.clock = clock.new({
  runtime = runtime,
  model = parts.model,
  environment = parts.environment,
  persistence = parts.persistence,
  -- Clock changes refresh the UI only after all services have been constructed.
  callbacks = {
    updateCondition = function(force) return parts.ui.updateCondition(force) end,
    pushUiState = function(force) return parts.ui.pushUiState(force) end,
  },
})
parts.ui = ui.new({
  runtime = runtime,
  model = parts.model,
  environment = parts.environment,
  clock = parts.clock,
  persistence = parts.persistence,
})

-- Per-frame update --------------------------------------------------------------------------------

local function interpolateEffect(dt)
  runtime.transitionElapsed = runtime.transitionElapsed + dt
  local p = model.clamp(runtime.transitionElapsed / math.max(0.01, runtime.transitionDuration), 0, 1)
  local currentEffect = runtime.currentEffect
  -- Rain audio keeps its original per-frame switch even when no visual tick is due.
  currentEffect.rain = p >= 0.35 and runtime.effectTarget.rain or (runtime.effectFrom.rain or 0)
  local visualTimer = runtime.visualTimer
  if visualTimer:due() or p >= 1 then
    visualTimer:reset(0)
    parts.environment.applyTransitionEffect(parts.ui.currentSnapshot().fog)
  end
  if p >= 1 then runtime.transitioning = false end
end

local function updateEffects(state, dt)
  if not runtime.missionFrozen and not runtime.externalOverride and state.settings.dynamicWeather and runtime.transitioning then
    interpolateEffect(dt)
  elseif not state.settings.dynamicWeather and runtime.environmentApplied then
    parts.environment.restoreEnvironment()
  end
  if not runtime.missionFrozen and not runtime.externalOverride and state.settings.dynamicWeather then
    parts.environment.updateWeatherAudio(math.max(0, dt), runtime.currentEffect, runtime.currentConditionName)
  end
end

local function onUpdate(dtReal, dtSim)
  if not runtime.worldReady or not runtime.loaded or not runtime.state then return end
  if runtime.travelJournalOverrideActive or runtime.editorSuspended or runtime.editorSaveDepth > 0 then return end
  -- Simulated time keeps the weather timers frozen while the game is paused.
  local dt = tonumber(dtSim) or 0
  parts.environment.tickWetLook(dtReal)
  local stateTimer, visualTimer = runtime.stateTimer, runtime.visualTimer
  stateTimer:add(math.max(0, dt))
  visualTimer:add(math.max(0, dt))
  if stateTimer:take() then
    parts.clock.stateStep()
  end

  updateEffects(runtime.state, dt)
  if runtime.nativePlayRequested then parts.clock.applyTimeOfDay() end
end

-- Lifecycle ---------------------------------------------------------------------------------------

local function resetWorldRuntime()
  runtime.worldReady = true
  runtime.loaded = false
  runtime.dailyForecastCache = nil
  runtime.weatherSnapshot = nil
  runtime.initializedMapId = nil
  runtime.travelJournalOverrideActive = false
  runtime.externalWarningShown = false
  runtime.sceneCache = nil
  runtime.lastVisualStepValues = nil
  runtime.baseline = nil
  runtime.environmentApplied = false
  runtime.savedRoughness, runtime.savedDiffuse, runtime.wetMaterialQueue = {}, {}, {}
  runtime.roadMaterials, runtime.materialTargets = nil, {}
  runtime.wetTargetRoughness, runtime.wetAppliedRoughness = 0, 0
  runtime.wetMaterialTimer:reset(0)
  runtime.currentConditionName = "clear"
  runtime.lastAppliedTimeOfDay = nil
  runtime.nativePlayRequested = false
  runtime.soundBase = nil
  runtime.lastGripBucket = nil
  runtime.lastConditionKey = nil
  runtime.stateTimer:reset(0)
  runtime.visualTimer:reset(0)
  runtime.currentEffect = model.copyTable(model.EFFECTS.clear)
  runtime.transitioning = false
  runtime.externalOverride = false
  runtime.clockBaseline = nil
end

local function initializeCurrentWorld(forceReset)
  -- The cold-start career callback loads owners before the native mission hooks.
  -- Early weather would enter the native snapshot, then lose its own baseline at StartMission.
  if worldReadyState ~= nil and worldReadyState ~= 2 then return false end
  local mapId = getCurrentLevelIdentifier()
  if type(mapId) ~= "string" or mapId == "" then return false end

  if forceReset or not runtime.worldReady or (runtime.initializedMapId and runtime.initializedMapId ~= mapId) then
    if runtime.initializedMapId == mapId then parts.environment.restoreEnvironment(); parts.clock.restoreClock() end
    resetWorldRuntime()
  end
  runtime.worldReady = true

  if runtime.loaded and runtime.state and runtime.initializedMapId == mapId then
    parts.ui.pushUiState(true)
    return true
  end

  parts.persistence.loadState()
  runtime.initializedMapId = mapId
  parts.clock.checkExternalOverride()
  if not runtime.externalOverride and runtime.state.settings.dynamicWeather
    and not runtime.editorSuspended and runtime.editorSaveDepth == 0 then
    parts.environment.captureBaseline()
  end
  parts.clock.applyTimeOfDay()
  if not runtime.externalOverride then
    parts.ui.updateCondition(true)
    -- Apply the entry forecast immediately; later weather changes interpolate.
    parts.ui.applyCurrentConditionImmediately()
  end
  return true
end

local function onOverhaulActive(active)
  local nextActive = active == true
  if nextActive ~= runtime.careerActive then
    if runtime.loaded and not runtime.careerActive then parts.persistence.saveState() end
    parts.environment.restoreEnvironment()
    parts.clock.restoreClock()
    resetWorldRuntime()
  end
  runtime.careerActive = nextActive
  initializeCurrentWorld(false)
end

local function onWorldReadyState(value)
  if value ~= 2 then return end
  onOverhaulActive(overhaul_career_career and overhaul_career_career.isActive and overhaul_career_career.isActive() == true)
end

local function onClientStartMission()
  runtime.worldReady = false
  runtime.loaded = false
  runtime.initializedMapId = nil
  runtime.sceneCache = nil
  runtime.lastVisualStepValues = nil
  runtime.baseline = nil
  runtime.clockBaseline = nil
  runtime.dailyForecastCache = nil
  runtime.weatherSnapshot = nil
  runtime.state = nil
  runtime.editorSuspended = false
  runtime.editorSaveDepth = 0
  runtime.environmentApplied = false
  runtime.externalWarningShown = false
  runtime.missionFrozen = false
  runtime.travelJournalOverrideActive = false
  runtime.stateTimer:reset(0)
  runtime.visualTimer:reset(0)
  runtime.wetMaterialTimer:reset(0)
  runtime.currentConditionName = "clear"
  runtime.lastAppliedTimeOfDay = nil
  runtime.nativePlayRequested = false
  runtime.rainShown = 0
  runtime.currentEffect = model.copyTable(model.EFFECTS.clear)
  runtime.savedRoughness, runtime.savedDiffuse, runtime.wetMaterialQueue = {}, {}, {}
  runtime.roadMaterials, runtime.materialTargets = nil, {}
  runtime.wetTargetRoughness, runtime.wetAppliedRoughness = 0, 0
  parts.environment.clearRainObject("rlsDynamicWeatherRain")
end

local function onClientEndMission()
  if runtime.loaded and not runtime.careerActive then parts.persistence.saveState() end
  parts.environment.restoreEnvironment()
  parts.clock.restoreClock()
  runtime.travelJournalOverrideActive = false
  runtime.worldReady = false
  runtime.loaded = false
  runtime.initializedMapId = nil
  runtime.sceneCache = nil
  runtime.lastVisualStepValues = nil
  runtime.baseline = nil
  runtime.dailyForecastCache = nil
  runtime.weatherSnapshot = nil
  runtime.state = nil
end

local function onAnyMissionChanged(status, mission)
  if not mission then return end
  if status == "started" then runtime.missionFrozen = true
  elseif status == "stopped" then runtime.missionFrozen = false end
  parts.ui.pushUiState(true)
end

local function onExtensionUnloaded()
  if runtime.loaded and not runtime.careerActive then parts.persistence.saveState() end
  runtime.travelJournalOverrideActive = false
  runtime.uiScopes = {}
  unregisterCycleTimeOfDayPatch()
  parts.environment.restoreEnvironment()
  parts.clock.restoreClock()
end

-- Restore materials before editor serialization, then resume from the authored environment.
local function suspendForEditor()
  parts.environment.restoreEnvironment()
  parts.clock.restoreClock()
end

local function resumeAfterEditor()
  if runtime.editorSuspended or runtime.editorSaveDepth > 0 or not runtime.loaded then return end
  runtime.lastConditionKey = nil
  parts.ui.updateCondition(true)
  parts.ui.applyCurrentConditionImmediately()
  parts.clock.applyTimeOfDay()
end

-- Public clock API -------------------------------------------------------------------------------

local function getDayNightCycle()
  if not parts.clock.ownsClock() and scenetree.tod then return parts.clock.readClock() end
  local state = runtime.state
  if not state then return {play = false, time = 0} end
  return {play = state.playCycle, time = model.minuteToEngineTime(state.minuteOfDay)}
end

local function toggleDayNightCycle(value)
  local state = runtime.state
  if runtime.externalOverride or (not runtime.careerActive and state and not state.settings.dynamicWeather) then
    parts.clock.writeClock({play = value == true})
    if not runtime.externalOverride then state.playCycle = value == true; parts.persistence.saveState(); parts.ui.pushUiState(true) end
    return true
  end
  if not state then return false end
  state.playCycle = value == true
  parts.clock.applyTimeOfDay()
  parts.persistence.saveState()
  parts.ui.pushUiState(true)
  return true
end

local function requestUiState()
  if not runtime.loaded then
    runtime.uiRequestInProgress = true
    local ok, reason = pcall(onWorldReadyState, 2)
    runtime.uiRequestInProgress = false
    if not ok then error(reason) end
  end
  return parts.ui.getUiState()
end

local function setTravelJournalOverrideActive(active)
  runtime.travelJournalOverrideActive = active == true
  runtime.stateTimer:reset(0)
  runtime.visualTimer:reset(0)
  parts.ui.pushUiState(true)
  return true
end

-- Public state and settings ----------------------------------------------------------------------

M.getWorldMinutes = function()
  local state = runtime.state
  if not state then return nil end
  return math.max(0, math.floor(tonumber(state.dayIndex) or 0)) * 1440
    + math.max(0, math.min(1439, math.floor(tonumber(state.minuteOfDay) or 0)))
end

M.getDayLengthMinutes = function()
  local state = runtime.state
  local minutes = state and state.settings and tonumber(state.settings.dayLengthMinutes)
  if model.ALLOWED_DAY_LENGTH_MINUTES[minutes] then return minutes end
  return parts.persistence.readDayLengthMinutesFromLevels(state and state.activeMap)
end

M.getCalendarState = function()
  local state = runtime.state
  if not runtime.loaded or not runtime.worldReady or not state then return {ready = false} end
  return {ready = true, dayIndex = state.dayIndex, minuteOfDay = math.floor(state.minuteOfDay + 0.5),
    dayLengthMinutes = tonumber(state.settings.dayLengthMinutes) or 60}
end
M.onUiScopeChanged = function(id, active)
  return scopeSubscriptions.set(runtime.uiScopes, id, active)
end
M.getUiState = parts.ui.getUiState
M.requestUiState = requestUiState
M.getTireWeatherState = parts.environment.getTireWeatherState
M.setSetting = parts.ui.setSetting
M.getClockState = getDayNightCycle
M.getDayNightCycle = getDayNightCycle
M.toggleDayNightCycle = toggleDayNightCycle
M.sleepTo = parts.ui.sleepTo
M.forceCondition = parts.ui.forceCondition
M.setMinuteOfDay = parts.ui.setMinuteOfDay
M.cycleTimeOfDay = parts.clock.cycleTimeOfDay
M.isExternalOverrideActive = function() return runtime.externalOverride end
M.setTravelJournalOverrideActive = setTravelJournalOverrideActive

-- Game hooks --------------------------------------------------------------------------------------

M.onEditorActivated = function() runtime.editorSuspended = true; suspendForEditor() end
M.onEditorDeactivated = function() runtime.editorSuspended = false; resumeAfterEditor() end
M.onEditorBeforeSaveLevel = function() runtime.editorSaveDepth = runtime.editorSaveDepth + 1; suspendForEditor() end
M.onEditorAfterSaveLevel = function() runtime.editorSaveDepth = math.max(0, runtime.editorSaveDepth - 1); resumeAfterEditor() end
M.onEditorBeforeSaveLevelBackup = M.onEditorBeforeSaveLevel
M.onEditorAfterSaveLevelBackup = M.onEditorAfterSaveLevel
M.onExtensionLoaded = function()
  registerCycleTimeOfDayPatch()
  runtime.editorSuspended = editor and editor.isEditorActive and editor.isEditorActive() == true or false
  onWorldReadyState(2)
end

M.onOverhaulBeforeCareerLevelSwitch = parts.clock.beforeCareerLevelSwitch
M.onOverhaulActive = onOverhaulActive
M.onCareerActivated = function() onOverhaulActive(true) end
M.onWorldReadyState = onWorldReadyState
M.onClientStartMission = onClientStartMission
M.onClientEndMission = onClientEndMission
M.onAnyMissionChanged = onAnyMissionChanged
M.onOverhaulSaveCurrentProfile = parts.persistence.saveState
M.onEnvironmentChanged = function(changes)
  parts.environment.environmentChanged(changes)
  parts.clock.environmentChanged(changes)
end
M.onUpdate = onUpdate
M.onExtensionUnloaded = onExtensionUnloaded

return M
