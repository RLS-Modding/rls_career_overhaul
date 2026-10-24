-- Weather UI and operations: condition and forecast snapshots, the phone app state, forecast notifications,
-- condition updates, and the setting, force and time operations the UI and other modules call.
local model = require("overhaul/world/weather/model")
local scopeSubscriptions = require("overhaul/lib/ui/scopeSubscriptions")
local phoneLayout = require("overhaul/lib/phone/layoutOwner")

local M = {}

-- Labels ------------------------------------------------------------------------------------------

local CONDITION_LABELS = {clear = "Clear", partlyCloudy = "Partly Cloudy", overcast = "Overcast", drizzle = "Drizzle", rain = "Rain", storm = "Storm"}

-- Morning fog outranks the condition's own label while it is present.
local function formatCondition(condition, fogFactor)
  if fogFactor and fogFactor > 0 then return "Morning Fog" end
  return CONDITION_LABELS[condition] or condition
end

-- Services -----------------------------------------------------------------------------------------

function M.new(inputs)
  local runtime = inputs.runtime
  local forecast = inputs.model
  local environment = inputs.environment
  local persistence = inputs.persistence
  local clock = inputs.clock
  -- Snapshots and forecast ------------------------------------------------------------------------

  local function currentSnapshot()
    local state = runtime.state
    local cached = runtime.weatherSnapshot
    if cached and cached.state == state and cached.dayIndex == state.dayIndex and cached.minute == state.minuteOfDay
      and cached.profile == runtime.profile and cached.revision == runtime.dailyForecastRevision then return cached.value end
    local rawCondition, segment, day, segmentIndex = forecast.conditionAt(state.dayIndex, state.minuteOfDay)
    local condition = forecast.effectiveCondition(rawCondition)
    local fogFactor, fog = forecast.fogFactorAt(day, state.minuteOfDay)
    local surfaceTemp, ambientTemp = forecast.surfaceTemperatureAt(state.dayIndex, state.minuteOfDay, condition)
    local meta = model.CONDITION_META[condition] or model.CONDITION_META.clear
    local snapshot = {
      rawCondition = rawCondition,
      condition = condition,
      segment = segment,
      segmentIndex = segmentIndex,
      day = day,
      fogFactor = fogFactor,
      fog = fog,
      ambientTempC = ambientTemp,
      surfaceTempC = surfaceTemp,
      humidity = fogFactor > 0.05 and math.max(meta.humidity, 92) or meta.humidity,
      precipitationChance = meta.precipitation,
      windMph = math.floor(meta.windMph * runtime.globalSettings.visualWindScale + 0.5),
    }
    runtime.weatherSnapshot = {state = state, dayIndex = state.dayIndex, minute = state.minuteOfDay,
      profile = runtime.profile, revision = runtime.dailyForecastRevision, value = snapshot}
    return snapshot
  end

  local function daySummary(dayIndex)
    local state = runtime.state
    local day = forecast.findDay(dayIndex)
    if not day then return nil end
    local counts = {}
    for _, segment in ipairs(day.segments or {}) do
      local name = forecast.effectiveCondition(segment.condition)
      counts[name] = (counts[name] or 0) + (segment.endMinute - segment.startMinute)
    end
    local dominant, best = "clear", -1
    for name, minutes in pairs(counts) do if minutes > best then dominant, best = name, minutes end end
    local low, high = 1000, -1000
    for minute = 0, 1380, 60 do
      local temperatureC = forecast.temperatureAt(dayIndex, minute)
      low, high = math.min(low, temperatureC), math.max(high, temperatureC)
    end
    return {
      dayIndex = dayIndex,
      condition = dominant,
      label = formatCondition(dominant),
      lowC = low,
      highC = high,
      fog = state.settings.dynamicWeather and state.settings.morningFog and day.fog ~= nil and not state.forceClearFog,
    }
  end

  local function hourlyForecast(state)
    local hours = {}
    for i = 0, 11 do
      local absolute = state.minuteOfDay + i * 60
      local dayOffset = math.floor(absolute / 1440)
      local minute = absolute % 1440
      local rawCondition, _, day = forecast.conditionAt(state.dayIndex + dayOffset, minute)
      local condition = forecast.effectiveCondition(rawCondition)
      local fogFactor = forecast.fogFactorAt(day, minute)
      hours[#hours + 1] = {
        dayOffset = dayOffset,
        minute = minute,
        condition = condition,
        label = formatCondition(condition, fogFactor),
        temperatureC = forecast.temperatureAt(state.dayIndex + dayOffset, minute),
        precipitationChance = (model.CONDITION_META[condition] or model.CONDITION_META.clear).precipitation,
      }
    end
    return hours
  end

  local function dailyForecast(state)
    local cache = runtime.dailyForecastCache
    if not cache or cache.state ~= state or cache.profile ~= runtime.profile or cache.dayIndex ~= state.dayIndex
      or cache.revision ~= runtime.dailyForecastRevision then
      local days = {}
      for i = 0, 6 do days[#days + 1] = daySummary(state.dayIndex + i) end
      cache = {state = state, profile = runtime.profile, dayIndex = state.dayIndex, revision = runtime.dailyForecastRevision, days = days}
      runtime.dailyForecastCache = cache
    end
    -- Public callers may edit payloads; cached summaries remain private to the weather owner.
    return model.copyTable(cache.days)
  end

  local function getUiState()
    local state = runtime.state
    if not runtime.loaded or not runtime.worldReady or not state then return {ready = false} end
    forecast.ensureHorizon()
    local snapshot = currentSnapshot()
    local hourly = hourlyForecast(state)
    local daily = dailyForecast(state)
    local playCycle = state.playCycle
    if not runtime.careerActive and not state.settings.dynamicWeather and scenetree.tod then
      playCycle = clock.readClock().play
    end
    return {
      ready = true,
      careerActive = runtime.careerActive,
      weatherEnabled = state.settings.dynamicWeather,
      mapId = persistence.getMapId(),
      location = runtime.profile.displayName,
      dayIndex = state.dayIndex,
      minuteOfDay = math.floor(state.minuteOfDay + 0.5),
      playCycle = playCycle,
      condition = snapshot.condition,
      conditionLabel = formatCondition(snapshot.condition, snapshot.fogFactor),
      fogFactor = snapshot.fogFactor,
      temperatureC = snapshot.ambientTempC,
      surfaceTemperatureC = snapshot.surfaceTempC,
      humidity = snapshot.humidity,
      precipitationChance = snapshot.precipitationChance,
      windMph = snapshot.windMph,
      wetness = math.floor(state.wetness * 100 + 0.5),
      externalOverride = runtime.externalOverride,
      missionFrozen = runtime.missionFrozen,
      travelJournalOverrideActive = runtime.travelJournalOverrideActive,
      settings = model.copyTable(state.settings),
      globalSettings = model.copyTable(runtime.globalSettings),
      hourly = hourly,
      daily = daily,
    }
  end

  local function pushUiState(force)
    local state = runtime.state
    if not state or runtime.uiRequestInProgress or not scopeSubscriptions.listening(runtime.uiScopes) then return end
    if not runtime.loaded or not runtime.worldReady then return end
    forecast.ensureHorizon()
    local current = currentSnapshot()
    local signature = table.concat({tostring(state.dayIndex), math.floor(state.minuteOfDay + 0.5), tostring(current and current.condition),
      math.floor((tonumber(state.wetness) or 0) * 100 + 0.5), tostring(runtime.externalOverride), tostring(runtime.missionFrozen)}, ":")
    if force or signature ~= runtime.lastUiSignature then
      runtime.lastUiSignature = signature
      guihooks.trigger("RLSWeatherState", getUiState())
    end
  end

  -- Notifications and condition updates -----------------------------------------------------------

  -- Keeps the dedupe history to today and yesterday.
  local function pruneNotificationHistory()
    local state = runtime.state
    if runtime.notificationPruneDay == state.dayIndex then return end
    runtime.notificationPruneDay = state.dayIndex
    local minDay = (tonumber(state.dayIndex) or 0) - 1
    local notificationHistory = runtime.notificationHistory
    for key in pairs(notificationHistory) do
      local day = tonumber(tostring(key):match("^(-?%d+):"))
      if day and day < minDay then
        notificationHistory[key] = nil
      end
    end
  end

  local function fireForecastNotification(snapshot)
    local state = runtime.state
    if not state.settings.dynamicWeather or not state.settings.forecastNotifications or runtime.externalOverride then return end
    pruneNotificationHistory()
    local layout = phoneLayout.get()
    if not layout then return end
    local segment = snapshot.segment
    if not segment then return end
    local remaining = segment.endMinute - state.minuteOfDay
    if remaining > 60 or remaining < 0 then return end
    local nextSegment = snapshot.day.segments[snapshot.segmentIndex + 1]
    if not nextSegment then
      local tomorrow = forecast.findDay(state.dayIndex + 1)
      nextSegment = tomorrow and tomorrow.segments and tomorrow.segments[1]
    end
    if not nextSegment then return end
    local nextEffective = forecast.effectiveCondition(nextSegment.condition)
    local channel, title, message
    if nextEffective == "rain" or nextEffective == "drizzle" then
      channel, title, message = "weather.rainSoon", "Rain approaching", "Wet weather is expected within the next hour."
    elseif nextEffective == "storm" then
      channel, title, message = "weather.stormSoon", "Storm approaching", "A storm is expected within the next hour."
    end
    local notificationHistory = runtime.notificationHistory
    local key = channel and table.concat({state.dayIndex, snapshot.segmentIndex, channel}, ":")
    if key and not notificationHistory[key] then
      notificationHistory[key] = true
      layout.fireNotification(channel, {title = title, message = message, kind = "warning", ttl = 8, source = "Weather"})
    end
    local fog = state.settings.morningFog and not state.forceClearFog and snapshot.day.fog
    if fog and state.minuteOfDay < fog.startMinute and fog.startMinute - state.minuteOfDay <= 60 then
      key = table.concat({state.dayIndex, "fog"}, ":")
      if not notificationHistory[key] then
        notificationHistory[key] = true
        layout.fireNotification("weather.fogSoon", {title = "Fog forming", message = "Dense morning fog is expected within the next hour.", kind = "warning", ttl = 8, source = "Weather"})
      end
    end
  end

  local function updateCondition(force)
    if not runtime.state then return end
    if runtime.externalOverride or runtime.editorSuspended or runtime.editorSaveDepth > 0 then
      pushUiState(force)
      return
    end
    local snapshot = currentSnapshot()
    runtime.currentConditionName = snapshot.condition
    local conditionKey = table.concat({snapshot.condition, math.floor(snapshot.fogFactor * 10), tostring(runtime.globalSettings.vulkanSafeMode)}, ":")
    if force or conditionKey ~= runtime.lastConditionKey then
      runtime.lastConditionKey = conditionKey
      environment.startTransition(snapshot.condition, snapshot.fogFactor, snapshot.fog)
    end
    environment.applyGroundGrip(snapshot.condition)
    environment.updateWetLook()
    fireForecastNotification(snapshot)
    pushUiState(force)
  end

  local function applyCurrentConditionImmediately()
    local state = runtime.state
    if not state or runtime.externalOverride or runtime.editorSuspended or runtime.editorSaveDepth > 0 or not state.settings.dynamicWeather then return end
    local snapshot = currentSnapshot()
    runtime.currentConditionName = snapshot.condition
    runtime.currentEffect = environment.effectFor(snapshot.condition, snapshot.fogFactor, snapshot.fog)
    runtime.effectFrom = model.copyTable(runtime.currentEffect)
    runtime.effectTarget = model.copyTable(runtime.currentEffect)
    runtime.transitionElapsed = 0
    runtime.transitionDuration = 0
    runtime.transitioning = false
    environment.applyVisualEffect(runtime.currentEffect, snapshot.fog)
  end

  -- Settings and operations -----------------------------------------------------------------------

  local function setSetting(key, value)
    local state = runtime.state
    if not runtime.loaded or not runtime.worldReady or not state or runtime.externalOverride or runtime.editorSuspended or runtime.editorSaveDepth > 0 then return false end
    local globalSettings = runtime.globalSettings
    if key == "temperatureUnit" then
      globalSettings.temperatureUnit = value == "C" and "C" or "F"
      persistence.saveGlobalSettings()
    elseif key == "visualWindScale" then
      globalSettings.visualWindScale = model.clamp(tonumber(value) or 1, 0, 2)
      persistence.saveGlobalSettings()
    elseif key == "dynamicWeather" then
      if value == true and not state.settings.dynamicWeather and not runtime.careerActive then
        state.minuteOfDay = model.engineTimeToMinute(scenetree.tod and scenetree.tod.time)
      end
      state.settings.dynamicWeather = value == true
      state.forceClearFog = nil
      if not state.settings.dynamicWeather then
        state.wetness = 0
        environment.restoreEnvironment()
        if not runtime.careerActive then clock.restoreClock() end
      end
      runtime.lastConditionKey = nil
    elseif key == "morningFog" then
      state.settings.morningFog = value == true
      runtime.lastConditionKey = nil
    elseif key == "playCycle" then
      state.playCycle = value == true
      if not runtime.careerActive and not state.settings.dynamicWeather and scenetree.tod then
        clock.writeClock({play = state.playCycle})
      end
    elseif key == "allowRainyDays" then
      state.settings.allowRainyDays = value == true
      runtime.lastConditionKey = nil
    elseif key == "dayLengthMinutes" then
      local number = tonumber(value)
      if not model.ALLOWED_DAY_LENGTH_MINUTES[number] then return false end
      state.settings.dayLengthMinutes = number
    elseif key == "forecastNotifications" then
      state.settings.forecastNotifications = value == true
    else
      return false
    end
    runtime.dailyForecastRevision = (runtime.dailyForecastRevision or 0) + 1
    clock.applyTimeOfDay()
    updateCondition(true)
    persistence.saveState()
    return true
  end

  local function forceCondition(condition)
    local state = runtime.state
    if not state or runtime.externalOverride then return false end
    if not model.CONDITION_INDEX[condition] then return false end
    state.settings.dynamicWeather = true
    if condition == "drizzle" or condition == "rain" or condition == "storm" then
      state.settings.allowRainyDays = true
    end
    local _, segment, day = forecast.conditionAt(state.dayIndex, state.minuteOfDay)
    if segment then
      segment.condition = condition
    elseif day then
      day.segments = {{startMinute = 0, endMinute = 1440, condition = condition}}
    else
      return false
    end
    if condition == "clear" or condition == "partlyCloudy" then
      state.wetness = 0
    elseif condition == "rain" or condition == "storm" then
      state.wetness = 1
    end
    if condition == "clear" then
      if day then day.fog = nil end
      state.forceClearFog = true
      state.minuteOfDay = 12 * 60
      state.playCycle = false
      runtime.lastAppliedTimeOfDay = nil
      clock.applyTimeOfDay()
    else
      state.forceClearFog = nil
    end
    runtime.dailyForecastRevision = (runtime.dailyForecastRevision or 0) + 1
    runtime.lastConditionKey = nil
    updateCondition(true)
    applyCurrentConditionImmediately()
    persistence.saveState()
    return true
  end

  local function setMinuteOfDay(minute, freezeCycle)
    local state = runtime.state
    if not state or runtime.externalOverride then return false end
    state.minuteOfDay = math.floor((tonumber(minute) or 0) + 0.5) % 1440
    if freezeCycle ~= false then
      state.playCycle = false
    end
    runtime.lastConditionKey = nil
    clock.applyTimeOfDay()
    updateCondition(true)
    persistence.saveState()
    return true
  end

  local function sleepTo(engineTime)
    local state = runtime.state
    if not state or runtime.externalOverride then return false end
    local target = model.engineTimeToMinute(engineTime)
    local delta = target - state.minuteOfDay
    if delta <= 0 then delta = delta + 1440 end
    forecast.advanceMinutes(delta)
    state.minuteOfDay = target
    forecast.ensureHorizon()
    runtime.lastConditionKey = nil
    clock.applyTimeOfDay()
    updateCondition(true)
    persistence.saveState()
    return true
  end

  -- Service API --------------------------------------------------------------------------------------

  return {
    currentSnapshot = currentSnapshot,
    getUiState = getUiState,
    pushUiState = pushUiState,
    updateCondition = updateCondition,
    applyCurrentConditionImmediately = applyCurrentConditionImmediately,
    setSetting = setSetting,
    forceCondition = forceCondition,
    setMinuteOfDay = setMinuteOfDay,
    sleepTo = sleepTo,
  }

end

return M
