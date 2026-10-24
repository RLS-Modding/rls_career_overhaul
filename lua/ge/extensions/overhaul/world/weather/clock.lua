-- Weather clock: native time-of-day reads and writes, jbWeather override detection, clock ownership,
-- the stock time-cycle replacement, the once-per-second state step and the travel advance to 08:00.
local model = require("overhaul/world/weather/model")

local M = {}

-- The clock also runs before a level's environment preset loads and while it tears down.
local function readClock()
  if core_environment and core_environment.getTimeOfDay then
    local tod = core_environment.getTimeOfDay()
    if tod then return {time = tod.time, play = tod.play == true} end
  end
  local tod = scenetree.tod
  return {time = tod and tod.time or 0, play = tod and tod.play == true or false}
end

-- Native play may live in dynamic fields; use the same direct/dynamic/field order as the environment.
local function boolean(value)
  if type(value) == "boolean" then return value end
  if type(value) == "number" then return value ~= 0 end
  value = tostring(value or ""):lower()
  if value == "1" or value == "true" or value == "yes" or value == "on" then return true end
  if value == "0" or value == "false" or value == "no" or value == "off" then return false end
end

local function nativePlay()
  local object = scenetree.tod
  if not object then return false end
  for _, field in ipairs({"play", "animate"}) do
    local value = boolean(object[field])
    if value == nil and object.getDynDataFieldbyName then value = boolean(object:getDynDataFieldbyName(field, 0)) end
    if value == nil and object.getField then value = boolean(object:getField(field, 0)) end
    if value ~= nil then return value end
  end
  return false
end

-- Keep the shortcut aligned with the game's night, sunrise and day steps.
local function nextCycleTime(timeOfDay)
  if timeOfDay < 0.2 then return 0.23 end
  if timeOfDay >= 0.5 then return 0.05 end
  return 0.5
end

function M.new(inputs)
  local runtime = inputs.runtime
  local forecast = inputs.model
  local environment = inputs.environment
  local persistence = inputs.persistence
  local callbacks = inputs.callbacks

  local function writeClock(values)
    -- Writes go through the environment API: BeamNG 0.39 exposes play through dynamic fields.
    runtime.writingClock = true
    if core_environment and core_environment.setTimeOfDay then
      core_environment.setTimeOfDay(values)
    elseif scenetree.tod then
      if values.time ~= nil then scenetree.tod.time = values.time end
      if values.play ~= nil then scenetree.tod.play = values.play end
    end
    runtime.writingClock = false
  end

  local function showExternalWarning()
    if runtime.externalWarningShown then return end
    runtime.externalWarningShown = true
    guihooks.trigger("toastrMsg", {
      type = "error",
      title = "External Weather Control",
      msg = "JayBeam Dynamic Weather has priority. RLS Weather is paused.",
    })
  end

  local function checkExternalOverride()
    local loadedNow = extensions.isExtensionLoaded("jbWeather") or false
    if loadedNow == runtime.externalOverride then
      if loadedNow then showExternalWarning() end
      return
    end
    runtime.externalOverride = loadedNow
    if runtime.externalOverride then
      environment.restoreEnvironment()
      runtime.lastExternalMinute = scenetree.tod and model.engineTimeToMinute(scenetree.tod.time) or runtime.state.minuteOfDay
      showExternalWarning()
    else
      local orphan = scenetree.findObject("jbWeatherRain")
      if orphan then orphan:delete() end
      environment.restoreGroundModels()
      runtime.lastExternalMinute = nil
      runtime.lastConditionKey = nil
      callbacks.updateCondition(true)
    end
    callbacks.pushUiState(true)
  end

  local function syncExternalClock()
    if not runtime.externalOverride or not scenetree.tod then return end
    local state = runtime.state
    local minute = model.engineTimeToMinute(scenetree.tod.time)
    if runtime.lastExternalMinute and minute + 720 < runtime.lastExternalMinute then
      state.dayIndex = state.dayIndex + 1
      forecast.ensureHorizon()
    end
    state.minuteOfDay = minute
    runtime.lastExternalMinute = minute
  end

  local function restoreClock()
    if runtime.clockBaseline then writeClock(runtime.clockBaseline) end
    runtime.clockBaseline = nil
    runtime.lastAppliedTimeOfDay = nil
    runtime.nativePlayRequested = false
  end

  local function ownsClock()
    local state = runtime.state
    return runtime.loaded and state and (runtime.careerActive or state.settings.dynamicWeather)
      and not runtime.externalOverride and not runtime.editorSuspended and runtime.editorSaveDepth == 0
  end

  local function applyTimeOfDay()
    if not ownsClock() or not scenetree.tod then return end
    if not runtime.clockBaseline then runtime.clockBaseline = readClock() end
    local playing = nativePlay()
    runtime.nativePlayRequested = false
    local engineTime = model.minuteToEngineTime(runtime.state.minuteOfDay)
    if runtime.lastAppliedTimeOfDay ~= engineTime or playing then
      local values = {time = engineTime}
      if playing then values.play = false end
      writeClock(values)
      runtime.lastAppliedTimeOfDay = engineTime
    end
  end

  -- Only cheat mode or a valid devkey may cycle during career; the weather clock owns the sky otherwise.
  local function canCycleTimeOfDay()
    if not runtime.careerActive then return true end
    if overhaul_career_economy_cheats and overhaul_career_economy_cheats.isCheatsMode and overhaul_career_economy_cheats.isCheatsMode() then
      return true
    end
    if overhaul_shell_extensionManager and overhaul_shell_extensionManager.isDevKeyValid and overhaul_shell_extensionManager.isDevKeyValid() then
      return true
    end
    return false
  end

  local function syncCycledTime(timeOfDay)
    runtime.state.minuteOfDay = model.engineTimeToMinute(timeOfDay)
    forecast.ensureHorizon()
    runtime.lastConditionKey = nil
    applyTimeOfDay()
    callbacks.updateCondition(true)
    persistence.saveState()
    callbacks.pushUiState(true)
  end

  local function cycleTimeOfDay(...)
    if not ownsClock() then
      if runtime.stockCycleTimeOfDay then
        return runtime.stockCycleTimeOfDay(...)
      end
      return
    end

    if not canCycleTimeOfDay() then
      return
    end

    syncCycledTime(nextCycleTime(model.minuteToEngineTime(runtime.state.minuteOfDay)))
  end

  -- Outside Overhaul, follow the game's own Ctrl+Shift+D step rather than snapping back to the clock.
  local function environmentChanged(changes)
    if runtime.writingClock or type(changes) ~= "table" then return end
    if boolean(changes.play) == true and ownsClock() then runtime.nativePlayRequested = true end
    if type(changes.time) ~= "number" then return end
    if not runtime.lastAppliedTimeOfDay or not ownsClock() or not canCycleTimeOfDay() then return end
    if math.abs(changes.time - nextCycleTime(runtime.lastAppliedTimeOfDay)) > 1e-4 then return end
    syncCycledTime(changes.time)
    -- Native notifications precede their write; the incoming play flag can overwrite our cycle correction.
    if boolean(changes.play) == true then runtime.nativePlayRequested = true end
  end

  -- The caller's timer decides when this runs.
  local function stateStep()
    checkExternalOverride()
    local state = runtime.state
    if runtime.externalOverride then
      restoreClock()
      syncExternalClock()
    elseif not runtime.careerActive and not state.settings.dynamicWeather then
      state.minuteOfDay = model.engineTimeToMinute(scenetree.tod and scenetree.tod.time)
    elseif state.playCycle and not runtime.missionFrozen then
      forecast.advanceMinutes(model.stateTickSeconds * forecast.gameMinutesPerRealSecond(state.minuteOfDay))
    end
    applyTimeOfDay()
    callbacks.updateCondition(false)
  end

  local function beforeCareerLevelSwitch(currentMap, nextMap)
    local state = runtime.state
    if not state or not nextMap or nextMap == currentMap then return end
    -- Arrival is the next 08:00, advancing the forecast day across midnight when necessary.
    local elapsedMinutes = model.travelArrivalMinute - state.minuteOfDay
    if elapsedMinutes <= 0 then elapsedMinutes = elapsedMinutes + 1440 end
    forecast.advanceMinutes(elapsedMinutes)
    state.minuteOfDay = model.travelArrivalMinute
    state.forecastEpoch = state.forecastEpoch + 1
    state.activeMap = nextMap
    state.horizon = {}
    local previousProfile = runtime.profile
    local override = jsonReadFile("/levels/" .. nextMap .. "/rls_weather.json")
    local defaultProfile = jsonReadFile("/gameplay/overhaul/weather/default.json") or {}
    runtime.profile = model.deepMerge(defaultProfile, override or {})
    local profile = runtime.profile
    profile.displayName = profile.displayName or nextMap
    profile.conditionWeights = profile.conditionWeights or {}
    profile.conditionDurationsMinutes = profile.conditionDurationsMinutes or {}
    profile.morningFog = profile.morningFog or {}
    profile.temperatureCurveC = profile.temperatureCurveC or {{0, 13}, {720, 23}, {1440, 13}}
    profile.dailyTemperatureVarianceC = tonumber(profile.dailyTemperatureVarianceC) or 2.5
    profile.wetness = profile.wetness or {}
    forecast.ensureHorizon()
    state.wetness = 0
    local elapsed = state.minuteOfDay
    state.minuteOfDay = 0
    forecast.advanceMinutes(elapsed)
    runtime.profile = runtime.profile or previousProfile
    persistence.saveState()
  end

  return {
    readClock = readClock,
    writeClock = writeClock,
    checkExternalOverride = checkExternalOverride,
    restoreClock = restoreClock,
    ownsClock = ownsClock,
    applyTimeOfDay = applyTimeOfDay,
    cycleTimeOfDay = cycleTimeOfDay,
    environmentChanged = environmentChanged,
    stateStep = stateStep,
    beforeCareerLevelSwitch = beforeCareerLevelSwitch,
  }

end

M.readClock = readClock

return M
