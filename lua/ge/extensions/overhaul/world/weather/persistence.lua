-- Weather persistence: map profiles, global and freeroam settings, state defaults and normalization.
-- Weather and legacy clock saves keep their paths and formats so existing profiles remain readable.
local model = require("overhaul/world/weather/model")

local M = {}

local SAVE_RELATIVE_PATH = "/career/rls_career/weather.json"
local LEGACY_TIME_RELATIVE_PATH = "/career/rls_career/time.json"
local GLOBAL_SETTINGS_PATH = "settings/RLS/weather.json"
local FREEROAM_SETTINGS_PATH = "settings/RLS/freeroamWeather.json"

local function ensureDirectory(path, writer)
  if writer then
    if not writer.exists(path) then writer.mkdir(path, true) end
  elseif not FS:directoryExists(path) then
    FS:directoryCreate(path, true)
  end
end

local function writeJson(path, data)
  if overhaul_career_saveSystem and overhaul_career_saveSystem.jsonWriteFileSafe then
    return overhaul_career_saveSystem.jsonWriteFileSafe(path, data, true)
  end
  if jsonWriteFileSafe then return jsonWriteFileSafe(path, data, true) end
  return jsonWriteFile(path, data, true)
end

local function getMapId()
  return getCurrentLevelIdentifier() or "unknown"
end

local function readDayLengthMinutesFromLevels(mapId)
  mapId = mapId or getMapId()
  if mapId and mapId ~= "" then
    local mapProfile = jsonReadFile("/levels/" .. mapId .. "/rls_weather.json")
    local minutes = tonumber(mapProfile and mapProfile.dayLengthMinutes)
    if model.ALLOWED_DAY_LENGTH_MINUTES[minutes] then return minutes end
  end
  local defaultProfile = jsonReadFile("/gameplay/overhaul/weather/default.json")
  local minutes = tonumber(defaultProfile and defaultProfile.dayLengthMinutes)
  if model.ALLOWED_DAY_LENGTH_MINUTES[minutes] then return minutes end
  return 60
end

function M.new(inputs)
  local runtime = inputs.runtime
  local forecast = inputs.model
  local function getSavePath()
    if not runtime.careerActive then return nil end
    if not overhaul_career_saveSystem or not overhaul_career_saveSystem.getCurrentProfile then return nil end
    local _, path = overhaul_career_saveSystem.getCurrentProfile()
    return path
  end

  local function loadProfile()
    local defaultProfile = jsonReadFile("/gameplay/overhaul/weather/default.json") or {}
    local mapId = getMapId()
    local mapProfile = jsonReadFile("/levels/" .. mapId .. "/rls_weather.json")
    runtime.profile = model.deepMerge(defaultProfile, mapProfile or {})
    local profile = runtime.profile
    profile.displayName = profile.displayName or mapId
    profile.conditionWeights = profile.conditionWeights or {}
    profile.conditionDurationsMinutes = profile.conditionDurationsMinutes or {}
    profile.morningFog = profile.morningFog or {}
    profile.temperatureCurveC = profile.temperatureCurveC or {{0, 13}, {720, 23}, {1440, 13}}
    profile.dailyTemperatureVarianceC = tonumber(profile.dailyTemperatureVarianceC) or 2.5
    profile.transitionMinutes = tonumber(profile.transitionMinutes) or 20
    profile.wetness = profile.wetness or {}
    return profile
  end

  local function loadGlobalSettings()
    local raw = jsonReadFile(GLOBAL_SETTINGS_PATH)
    if type(raw) == "table" then
      local globalSettings = runtime.globalSettings
      globalSettings.temperatureUnit = raw.temperatureUnit == "C" and "C" or "F"
      -- Retired safe-mode value is ignored so old settings cannot disable rain particles or wet roads.
      globalSettings.vulkanSafeMode = false
      globalSettings.visualWindScale = model.clamp(tonumber(raw.visualWindScale) or 1, 0, 2)
    end
  end

  local function saveGlobalSettings()
    ensureDirectory("settings/RLS/")
    writeJson(GLOBAL_SETTINGS_PATH, runtime.globalSettings)
  end

  local function defaultState()
    local careerActive = runtime.careerActive
    local currentEngineTime = scenetree.tod and scenetree.tod.time or 0
    local profileName = careerActive and "career" or "freeroam"
    if careerActive and overhaul_career_saveSystem and overhaul_career_saveSystem.getCurrentProfile then
      profileName = select(1, overhaul_career_saveSystem.getCurrentProfile()) or profileName
    end
    return {
      version = model.schemaVersion,
      generatorVersion = model.generatorVersion,
      seed = (model.hashString(profileName) + (os.time and os.time() or 1)) % 4294967296,
      dayIndex = 0,
      minuteOfDay = model.engineTimeToMinute(currentEngineTime),
      forecastEpoch = 0,
      activeMap = getMapId(),
      horizon = {},
      wetness = 0,
      playCycle = true,
      settings = {
        dynamicWeather = careerActive,
        allowRainyDays = true,
        morningFog = true,
        dayLengthMinutes = readDayLengthMinutesFromLevels(),
        forecastNotifications = true,
      },
    }
  end

  local function normalizeState(raw)
    local out = type(raw) == "table" and raw or defaultState()
    out.version = model.schemaVersion
    out.generatorVersion = tonumber(out.generatorVersion) or model.generatorVersion
    out.seed = tonumber(out.seed) or defaultState().seed
    out.dayIndex = math.max(0, math.floor(tonumber(out.dayIndex) or 0))
    out.minuteOfDay = (tonumber(out.minuteOfDay) or 720) % 1440
    out.forecastEpoch = math.max(0, math.floor(tonumber(out.forecastEpoch) or 0))
    out.activeMap = type(out.activeMap) == "string" and out.activeMap or getMapId()
    out.horizon = type(out.horizon) == "table" and out.horizon or {}
    out.wetness = model.clamp(tonumber(out.wetness) or 0, 0, 1)
    out.playCycle = out.playCycle ~= false
    out.settings = type(out.settings) == "table" and out.settings or {}
    if out.settings.dynamicWeather == nil then out.settings.dynamicWeather = runtime.careerActive end
    if out.settings.allowRainyDays == nil then out.settings.allowRainyDays = true end
    if out.settings.morningFog == nil then out.settings.morningFog = true end
    out.settings.dayLengthMinutes = tonumber(out.settings.dayLengthMinutes) or readDayLengthMinutesFromLevels(out.activeMap)
    if not model.ALLOWED_DAY_LENGTH_MINUTES[out.settings.dayLengthMinutes] then
      out.settings.dayLengthMinutes = readDayLengthMinutesFromLevels(out.activeMap)
    end
    if out.settings.forecastNotifications == nil then out.settings.forecastNotifications = true end
    return out
  end

  local function saveState(currentSavePath, _, writer)
    local state = runtime.state
    if not state then return false end
    if not runtime.careerActive then
      ensureDirectory("settings/RLS/", writer)
      return writeJson(FREEROAM_SETTINGS_PATH, state)
    end
    if not currentSavePath then return false end
    local dir = currentSavePath .. "/career/rls_career"
    ensureDirectory(dir, writer)
    state.version = model.schemaVersion
    state.generatorVersion = model.generatorVersion
    local ok = writeJson(currentSavePath .. SAVE_RELATIVE_PATH, state)
    writeJson(currentSavePath .. LEGACY_TIME_RELATIVE_PATH, {time = model.minuteToEngineTime(state.minuteOfDay), play = state.playCycle})
    return ok
  end

  local function loadState()
    loadGlobalSettings()
    local careerActive = runtime.careerActive
    local path = getSavePath()
    local raw = careerActive and path and jsonReadFile(path .. SAVE_RELATIVE_PATH) or nil
    if not careerActive then raw = jsonReadFile(FREEROAM_SETTINGS_PATH) end
    if not raw and path then
      local legacy = jsonReadFile(path .. LEGACY_TIME_RELATIVE_PATH)
      if legacy then
        raw = defaultState()
        raw.minuteOfDay = model.engineTimeToMinute(legacy.time)
        raw.playCycle = legacy.play ~= false
      end
    end
    runtime.state = normalizeState(raw)
    local state = runtime.state
    runtime.notificationHistory = {}
    if state.activeMap ~= getMapId() then state.horizon = {}; state.wetness = 0 end
    state.activeMap = getMapId()
    if not careerActive then
      state.minuteOfDay = model.engineTimeToMinute(scenetree.tod and scenetree.tod.time)
    end
    loadProfile()
    forecast.ensureHorizon()
    runtime.loaded = true
  end

  return {
    getMapId = getMapId,
    readDayLengthMinutesFromLevels = readDayLengthMinutesFromLevels,
    saveGlobalSettings = saveGlobalSettings,
    saveState = saveState,
    loadState = loadState,
  }

end

M.getMapId = getMapId
M.readDayLengthMinutesFromLevels = readDayLengthMinutesFromLevels

return M
