-- Weather forecast model: constants, a seeded LCG for forecast days (never math.random), conditions,
-- Read down: config, math/RNG helpers, fog rules, forecast/horizon services, temperatures and minute integration.
local M = {}

-- Config ------------------------------------------------------------------------------------------

M.schemaVersion = 1
-- Bumped when forecast generation rules change so retained horizon days rebuild.
M.generatorVersion = 2
M.travelArrivalMinute = 8 * 60
M.stateTickSeconds = 1
M.visualTickSeconds = 0.2
M.wetMaterialTickSeconds = 0.1
M.MINUTES_PER_DAY = 1440

local generatorVersion = M.generatorVersion
local MINUTES_PER_DAY = M.MINUTES_PER_DAY
local DAYLIGHT_START_MINUTE = 360
local DAYLIGHT_END_MINUTE = 1200

local CONDITION_ORDER = {"clear", "partlyCloudy", "overcast", "drizzle", "rain", "storm"}
local CONDITION_INDEX = {}
for i, name in ipairs(CONDITION_ORDER) do CONDITION_INDEX[name] = i end

local EFFECTS = {
  clear        = {fogAdd = 0,      sky = 1.00, sun = 1.00, ambient = 1.00, brightness = 1.00, rain = 0,    wetRough = 0,    wind = 0.04, tint = {1.00, 1.00, 1.00}},
  partlyCloudy = {fogAdd = 0.0004, sky = 0.86, sun = 0.76, ambient = 0.92, brightness = 0.84, rain = 0,    wetRough = 0,    wind = 0.16, tint = {0.91, 0.93, 0.97}},
  overcast     = {fogAdd = 0.0015, sky = 0.64, sun = 0.18, ambient = 0.79, brightness = 0.58, rain = 0,    wetRough = 0,    wind = 0.24, tint = {0.72, 0.75, 0.80}},
  drizzle      = {fogAdd = 0.0030, sky = 0.53, sun = 0.08, ambient = 0.69, brightness = 0.44, rain = 1200, wetRough = 0.28, wind = 0.32, tint = {0.63, 0.67, 0.73}},
  rain         = {fogAdd = 0.0045, sky = 0.43, sun = 0.03, ambient = 0.61, brightness = 0.32, rain = 2200, wetRough = 0.18, wind = 0.45, tint = {0.55, 0.59, 0.66}},
  storm        = {fogAdd = 0.0070, sky = 0.28, sun = 0.01, ambient = 0.49, brightness = 0.19, rain = 3400, wetRough = 0.10, wind = 0.70, tint = {0.41, 0.46, 0.56}},
}

local CLOUD_COVER = {
  clear = 0,
  partlyCloudy = 0.28,
  overcast = 0.70,
  drizzle = 0.78,
  rain = 0.88,
  storm = 0.95,
}

local CONDITION_META = {
  clear        = {humidity = 36, precipitation = 5,  windMph = 3,  tempOffsetC = 1.5},
  partlyCloudy = {humidity = 48, precipitation = 16, windMph = 7,  tempOffsetC = 0.5},
  overcast     = {humidity = 64, precipitation = 32, windMph = 10, tempOffsetC = -1.0},
  drizzle      = {humidity = 80, precipitation = 65, windMph = 12, tempOffsetC = -1.8},
  rain         = {humidity = 89, precipitation = 88, windMph = 16, tempOffsetC = -2.8},
  storm        = {humidity = 94, precipitation = 98, windMph = 24, tempOffsetC = -3.5},
}

local ALLOWED_DAY_LENGTH_MINUTES = {[30]=true,[45]=true,[60]=true,[90]=true,[120]=true}
local DEFAULT_MOISTURE_CONDITIONS = {overcast = true, drizzle = true, rain = true, storm = true}
local DEFAULT_CLEARING_MORNING = {clear = true, partlyCloudy = true, overcast = true, drizzle = true}

-- Math, time and random ---------------------------------------------------------------------------

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function lerp(a, b, t)
  return a + (b - a) * t
end

local function copyTable(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for k, v in pairs(value) do out[k] = copyTable(v) end
  return out
end

local function deepMerge(base, override)
  local out = copyTable(base or {})
  if type(override) ~= "table" then return out end
  if #override > 0 then return copyTable(override) end
  for k, v in pairs(override) do
    if type(v) == "table" and type(out[k]) == "table" and #v == 0 then
      out[k] = deepMerge(out[k], v)
    else
      out[k] = copyTable(v)
    end
  end
  return out
end

local function engineTimeToMinute(t)
  return math.floor((((tonumber(t) or 0) + 0.5) % 1) * MINUTES_PER_DAY + 0.5) % MINUTES_PER_DAY
end

local function minuteToEngineTime(minute)
  return (((tonumber(minute) or 0) / MINUTES_PER_DAY) + 0.5) % 1
end

local function hashString(value)
  local h = 2166136261
  value = tostring(value or "")
  for i = 1, #value do
    h = (h * 16777619 + value:byte(i)) % 4294967296
  end
  return h
end

local function makeRng(seed)
  local n = math.floor(tonumber(seed) or 1) % 4294967296
  if n == 0 then n = 1 end
  return function()
    n = (1664525 * n + 1013904223) % 4294967296
    return n / 4294967296
  end
end

local function daylightFactor(minute)
  if minute < DAYLIGHT_START_MINUTE or minute > DAYLIGHT_END_MINUTE then return 0 end
  return math.sin(math.pi * (minute - DAYLIGHT_START_MINUTE) / (DAYLIGHT_END_MINUTE - DAYLIGHT_START_MINUTE))
end

-- Morning fog rules -------------------------------------------------------------------------------

local function moistureConditionSet(fogCfg)
  local set = {}
  local list = fogCfg and fogCfg.moistureConditions
  if type(list) == "table" and #list > 0 then
    for _, name in ipairs(list) do set[name] = true end
    return set
  end
  return DEFAULT_MOISTURE_CONDITIONS
end

local function segmentConditionAt(segments, minute)
  for _, segment in ipairs(segments or {}) do
    if minute >= segment.startMinute and minute < segment.endMinute then
      return segment.condition
    end
  end
  local last = segments and segments[#segments]
  return last and last.condition or nil
end

-- Minutes of moist sky covering [0, windowEnd) on this day.
local function overnightMoistureMinutes(segments, windowEnd, moistureSet)
  local total = 0
  windowEnd = math.max(0, tonumber(windowEnd) or 360)
  for _, segment in ipairs(segments or {}) do
    if segment.startMinute < windowEnd and moistureSet[segment.condition] then
      local lo = math.max(segment.startMinute, 0)
      local hi = math.min(segment.endMinute, windowEnd)
      if hi > lo then total = total + (hi - lo) end
    end
  end
  return total
end

-- Fog needs moist overnight air; the clearing-morning bias is opt-in.
local function morningFogEligible(segments, previousCondition, fogCfg)
  if fogCfg.requireOvernightMoisture == false then return true end

  local moistureSet = moistureConditionSet(fogCfg)
  local windowEnd = tonumber(fogCfg.overnightWindowEndMinute) or 360
  local minMoisture = math.max(0, tonumber(fogCfg.minMoistureMinutes) or 90)
  local moistMinutes = overnightMoistureMinutes(segments, windowEnd, moistureSet)
  -- Previous day's last segment covers evening moisture that crossed midnight.
  if previousCondition and moistureSet[previousCondition] then
    moistMinutes = moistMinutes + math.min(120, minMoisture)
  end
  if moistMinutes < minMoisture then return false end

  if fogCfg.preferClearingMorning ~= true then return true end
  local startMinute = tonumber(fogCfg.startMinute) or 210
  local morning = segmentConditionAt(segments, startMinute)
  local clearing = fogCfg.clearingMorningConditions
  local clearingSet = DEFAULT_CLEARING_MORNING
  if type(clearing) == "table" and #clearing > 0 then
    clearingSet = {}
    for _, name in ipairs(clearing) do clearingSet[name] = true end
  end
  return morning ~= nil and clearingSet[morning] == true
end

-- Instance services ---------------------------------------------------------------------------------

function M.new(inputs)
  local runtime = inputs.runtime
  local function seededFor(dayIndex, epoch, mapId)
    return (runtime.state.seed + hashString(mapId) + (dayIndex or 0) * 2654435761 + (epoch or 0) * 2246822519 + generatorVersion * 3266489917) % 4294967296
  end

  local function pickWeighted(rng, previous)
    local profile = runtime.profile
    local previousIndex = CONDITION_INDEX[previous]
    local candidates = {}
    local total = 0
    for i, name in ipairs(CONDITION_ORDER) do
      local eligible = not previousIndex or math.abs(i - previousIndex) <= 1
      if name == "storm" and previous ~= "rain" and previous ~= "storm" then eligible = false end
      local weight = eligible and math.max(0, tonumber(profile.conditionWeights[name]) or 0) or 0
      if weight > 0 then
        total = total + weight
        candidates[#candidates + 1] = {name = name, cumulative = total}
      end
    end
    if total <= 0 then return previous or "clear" end
    local value = rng() * total
    for _, candidate in ipairs(candidates) do
      if value <= candidate.cumulative then return candidate.name end
    end
    return candidates[#candidates].name
  end

  local function durationFor(rng, condition)
    local range = runtime.profile.conditionDurationsMinutes[condition] or {120, 240}
    local lo = math.max(15, tonumber(range[1]) or 120)
    local hi = math.max(lo, tonumber(range[2]) or lo)
    return math.floor((lo + (hi - lo) * rng()) / 15 + 0.5) * 15
  end

  local function buildForecastDay(dayIndex, previousCondition)
    local state, profile = runtime.state, runtime.profile
    local rng = makeRng(seededFor(dayIndex, state.forecastEpoch, state.activeMap))
    local segments = {}
    local minute = 0
    local condition = previousCondition
    while minute < MINUTES_PER_DAY do
      condition = pickWeighted(rng, condition)
      local duration = math.min(durationFor(rng, condition), MINUTES_PER_DAY - minute)
      segments[#segments + 1] = {startMinute = minute, endMinute = minute + duration, condition = condition}
      minute = minute + duration
    end
    local fog
    local fogCfg = profile.morningFog or {}
    if morningFogEligible(segments, previousCondition, fogCfg)
        and rng() < clamp(tonumber(fogCfg.chance) or 0, 0, 1) then
      local endMin = math.floor(lerp(tonumber(fogCfg.endMinuteMin) or 510, tonumber(fogCfg.endMinuteMax) or 540, rng()) + 0.5)
      fog = {
        startMinute = tonumber(fogCfg.startMinute) or 180,
        peakMinute = tonumber(fogCfg.peakMinute) or 390,
        clearMinute = tonumber(fogCfg.clearMinute) or 480,
        endMinute = endMin,
        maxDensity = tonumber(fogCfg.maxDensity) or 0.01,
        atmosphereHeight = tonumber(fogCfg.atmosphereHeight) or 190,
        fadeInPower = tonumber(fogCfg.fadeInPower) or 2,
      }
    end
    local variance = profile.dailyTemperatureVarianceC
    return {
      dayIndex = dayIndex,
      segments = segments,
      fog = fog,
      temperatureOffsetC = (rng() * 2 - 1) * variance,
      profileVersion = tonumber(profile.version) or 1,
      generatorVersion = generatorVersion,
    }
  end

  local function findDay(dayIndex)
    for _, day in ipairs(runtime.state.horizon or {}) do
      if day.dayIndex == dayIndex then return day end
    end
  end

  local function ensureHorizon()
    local state = runtime.state
    local retained = {}
    for _, day in ipairs(state.horizon or {}) do
      local sameGen = (tonumber(day.generatorVersion) or 0) == generatorVersion
      if sameGen and day.dayIndex >= state.dayIndex and day.dayIndex <= state.dayIndex + 6 then
        retained[#retained + 1] = day
      end
    end
    table.sort(retained, function(a, b) return a.dayIndex < b.dayIndex end)
    state.horizon = retained
    local previous
    if #retained > 0 and retained[#retained].segments and #retained[#retained].segments > 0 then
      previous = retained[#retained].segments[#retained[#retained].segments].condition
    end
    for dayIndex = state.dayIndex, state.dayIndex + 6 do
      local existing = findDay(dayIndex)
      if not existing then
        existing = buildForecastDay(dayIndex, previous)
        state.horizon[#state.horizon + 1] = existing
      end
      if existing.segments and #existing.segments > 0 then previous = existing.segments[#existing.segments].condition end
    end
    table.sort(state.horizon, function(a, b) return a.dayIndex < b.dayIndex end)
  end

  local function conditionAt(dayIndex, minute)
    local day = findDay(dayIndex)
    if not day then ensureHorizon(); day = findDay(dayIndex) end
    if not day then return "clear", nil, nil end
    for index, segment in ipairs(day.segments or {}) do
      if minute >= segment.startMinute and minute < segment.endMinute then return segment.condition, segment, day, index end
    end
    local segment = day.segments and day.segments[#day.segments]
    return segment and segment.condition or "clear", segment, day, day.segments and #day.segments or 0
  end

  local function effectiveCondition(condition)
    local state = runtime.state
    if not state.settings.dynamicWeather then return "clear" end
    if not state.settings.allowRainyDays and (condition == "drizzle" or condition == "rain" or condition == "storm") then return "overcast" end
    return condition
  end

  local function fogFactorAt(day, minute)
    local state = runtime.state
    if not state.settings.dynamicWeather or not state.settings.morningFog or state.forceClearFog then return 0, nil end
    local fog = day and day.fog
    if not fog or minute < fog.startMinute or minute >= fog.endMinute then return 0, nil end
    if minute <= fog.peakMinute then
      local t = clamp((minute - fog.startMinute) / math.max(1, fog.peakMinute - fog.startMinute), 0, 1)
      local power = tonumber(fog.fadeInPower) or 2
      return t ^ power, fog
    end
    if minute <= fog.clearMinute then return 1, fog end
    return clamp(1 - (minute - fog.clearMinute) / math.max(1, fog.endMinute - fog.clearMinute), 0, 1), fog
  end

  local function temperatureAt(dayIndex, minute)
    local day = findDay(dayIndex)
    local curve = runtime.profile.temperatureCurveC
    local value = tonumber(curve[1] and curve[1][2]) or 15
    for i = 1, #curve - 1 do
      local a, b = curve[i], curve[i + 1]
      if minute >= a[1] and minute <= b[1] then
        local p = (minute - a[1]) / math.max(1, b[1] - a[1])
        value = lerp(a[2], b[2], p)
        break
      end
    end
    local condition = conditionAt(dayIndex, minute)
    local meta = CONDITION_META[effectiveCondition(condition)] or CONDITION_META.clear
    return value + (day and day.temperatureOffsetC or 0) + (meta.tempOffsetC or 0)
  end

  local function surfaceTemperatureAt(dayIndex, minute, condition)
    local ambient = temperatureAt(dayIndex, minute)
    local effect = EFFECTS[effectiveCondition(condition)] or EFFECTS.clear
    local cloud = clamp(1 - effect.sky, 0, 1)
    local rain = effect.rain > 0 and clamp(effect.rain / 3400, 0, 1) or 0
    local calculated = ambient + 12 * daylightFactor(minute) * (1 - 0.8 * cloud) - 4 * rain
    return clamp(calculated, ambient - 4, ambient + 15), ambient
  end

  local function gameMinutesPerRealSecond(minute)
    local segmentGameMinutes, allocation
    if minute < 240 then segmentGameMinutes, allocation = 240, 4
    elseif minute < 420 then segmentGameMinutes, allocation = 180, 10
    elseif minute < 1020 then segmentGameMinutes, allocation = 600, 28
    elseif minute < 1200 then segmentGameMinutes, allocation = 180, 12
    else segmentGameMinutes, allocation = 240, 6 end
    local scale = runtime.state.settings.dayLengthMinutes / 60
    return segmentGameMinutes / (allocation * 60 * scale)
  end

  local function wetnessRate(condition)
    local state, profile = runtime.state, runtime.profile
    if not state.settings.dynamicWeather then return -(tonumber(profile.wetness.dryPerMinute) or 0.004) end
    condition = effectiveCondition(condition)
    if condition == "drizzle" then return tonumber(profile.wetness.drizzlePerMinute) or 0.003 end
    if condition == "rain" then return tonumber(profile.wetness.rainPerMinute) or 0.008 end
    if condition == "storm" then return tonumber(profile.wetness.stormPerMinute) or 0.015 end
    local surfaceTemp = surfaceTemperatureAt(state.dayIndex, state.minuteOfDay, condition)
    local dry = tonumber(profile.wetness.dryPerMinute) or 0.004
    local tempFactor = clamp(1 + (surfaceTemp - 20) * 0.02, 0.5, 1.5)
    local windFactor = 1 + ((EFFECTS[condition] and EFFECTS[condition].wind) or 0) * 0.2
    return -dry * tempFactor * windFactor
  end

  local function advanceMinutes(amount)
    local state = runtime.state
    local remaining = math.max(0, tonumber(amount) or 0)
    while remaining > 0 do
      local step = math.min(1, remaining)
      local condition = conditionAt(state.dayIndex, state.minuteOfDay)
      state.wetness = clamp(state.wetness + wetnessRate(condition) * step, 0, 1)
      state.minuteOfDay = state.minuteOfDay + step
      if state.minuteOfDay >= MINUTES_PER_DAY then
        state.minuteOfDay = state.minuteOfDay - MINUTES_PER_DAY
        state.dayIndex = state.dayIndex + 1
        ensureHorizon()
      end
      remaining = remaining - step
    end
  end

  return {
    findDay = findDay,
    ensureHorizon = ensureHorizon,
    conditionAt = conditionAt,
    effectiveCondition = effectiveCondition,
    fogFactorAt = fogFactorAt,
    temperatureAt = temperatureAt,
    surfaceTemperatureAt = surfaceTemperatureAt,
    gameMinutesPerRealSecond = gameMinutesPerRealSecond,
    advanceMinutes = advanceMinutes,
  }

end

-- Public API --------------------------------------------------------------------------------------

M.CONDITION_ORDER = CONDITION_ORDER
M.CONDITION_INDEX = CONDITION_INDEX
M.EFFECTS = EFFECTS
M.CLOUD_COVER = CLOUD_COVER
M.CONDITION_META = CONDITION_META
M.ALLOWED_DAY_LENGTH_MINUTES = ALLOWED_DAY_LENGTH_MINUTES

M.clamp = clamp
M.lerp = lerp
M.copyTable = copyTable
M.deepMerge = deepMerge
M.engineTimeToMinute = engineTimeToMinute
M.minuteToEngineTime = minuteToEngineTime
M.hashString = hashString
M.makeRng = makeRng

return M
