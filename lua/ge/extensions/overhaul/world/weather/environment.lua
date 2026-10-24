-- Weather environment: baseline capture and restore, sky/fog/cloud/rain visuals, wet roads and weather audio,
-- Read down: config, scene/color helpers, baseline, rain/wet roads/audio, restoration, visuals, grip and tires.
local model = require("overhaul/world/weather/model")

local M = {}

-- Config ------------------------------------------------------------------------------------------

local ROAD_WORDS = {"road", "asphalt", "concrete", "pavement", "tarmac", "sidewalk", "curb", "kerb", "track", "blacktop", "macadam", "raceway", "speedway", "circuit", "racetrack", "cobble"}
local ROAD_EXCLUDE_WORDS = {"sky", "cloud", "glass", "window", "water", "tree", "foliage", "grass", "plant", "leaf", "wheel", "tire", "glow", "decal", "sign", "smoke", "fire", "emissive", "grid", "border", "crack", "crossing", "skidmark", "marking", "arrow", "paint"}
local SOUND_BASE_CANDIDATES = {"/sounds/rls_weather/", "/sounds/", "sounds/"}

-- Rain audio scales with effect.rain / RAIN_EFFECT_FOR_FULL_AUDIO and only starts above RAIN_AUDIO_MIN_LEVEL.
local RAIN_EFFECT_FOR_FULL_AUDIO = 3400
local RAIN_AUDIO_MIN_LEVEL = 0.02
-- The rain loop restarts before its end, so the next fade-in overlaps the tail.
local RAIN_LOOP_FADE_IN_SECONDS = 0.35
-- Only loops longer than this are timed from their own length.
local RAIN_LOOP_MIN_LENGTH_SECONDS = 1
-- Replay interval when the loop length is unknown or too short.
local RAIN_LOOP_FALLBACK_SECONDS = 7.5
-- Storm thunder: a strike is armed every 5 to 13 seconds and plays 0.4 to 2.6 seconds later.
local THUNDER_COOLDOWN_MIN_SECONDS = 5
local THUNDER_COOLDOWN_SPAN_SECONDS = 8
local THUNDER_DELAY_MIN_SECONDS = 0.4
local THUNDER_DELAY_SPAN_SECONDS = 2.2

-- Ground grip against surface temperature (degrees C), applied as a multiplier on normal grip.
local GRIP_AMPLITUDE_STANDARD = 0.025 -- grip swing as a fraction of normal grip
local GRIP_AMPLITUDE_HIGH_GRIP = 1 / 15 -- high-grip surfaces swing more
local GRIP_NORMAL_C = 20 -- grip is back to normal here
local GRIP_PEAK_C = 35 -- grip peaks here
local GRIP_HOT_C = 45 -- grip starts fading here
local GRIP_HOT_RETAINED_SHARE = 0.6 -- share of the peak swing still left at GRIP_HOT_C
local GRIP_HOT_FALLOFF_SPAN_C = 25 -- degrees over which grip drops one full amplitude past GRIP_HOT_C
local GRIP_HOT_MAX_LOSS_SHARE = 0.4 -- hot surfaces never lose more than this share of the amplitude below normal

-- Scene lookups -----------------------------------------------------------------------------------

local function toPoint4(value)
  if not value then return nil end
  local x = value.x or value.r
  local y = value.y or value.g
  local z = value.z or value.b
  local w = value.w or value.a or 1
  if x == nil then return nil end
  return {x, y, z, w}
end

local function clearRainObject(objectName)
  local object = scenetree.findObject(objectName)
  if object then object:delete() end
end

local function matchesAny(text, words)
  for _, word in ipairs(words) do
    if string.find(text, word, 1, true) then return true end
  end
  return false
end

-- Color and grip math -----------------------------------------------------------------------------

local function colorChannels(value)
  if not value or value == "" then return nil end
  return value:match("([%-%d%.eE]+)%s+([%-%d%.eE]+)%s+([%-%d%.eE]+)%s*([%-%d%.eE]*)")
end

local function darkenColorString(value, multiplier)
  local r, g, b, a = colorChannels(value)
  r, g, b, a = tonumber(r) or 1, tonumber(g) or 1, tonumber(b) or 1, tonumber(a) or 1
  return string.format("%g %g %g %g", r * multiplier, g * multiplier, b * multiplier, a)
end

local function temperatureMultiplier(surfaceTemp, highGrip)
  local amplitude = highGrip and GRIP_AMPLITUDE_HIGH_GRIP or GRIP_AMPLITUDE_STANDARD
  if surfaceTemp <= 0 then return 1 - amplitude end
  if surfaceTemp < GRIP_NORMAL_C then return model.lerp(1 - amplitude, 1, surfaceTemp / GRIP_NORMAL_C) end
  if surfaceTemp < GRIP_PEAK_C then
    return model.lerp(1, 1 + amplitude, (surfaceTemp - GRIP_NORMAL_C) / (GRIP_PEAK_C - GRIP_NORMAL_C))
  end
  if surfaceTemp < GRIP_HOT_C then
    return model.lerp(1 + amplitude, 1 + amplitude * GRIP_HOT_RETAINED_SHARE,
      (surfaceTemp - GRIP_PEAK_C) / (GRIP_HOT_C - GRIP_PEAK_C))
  end
  return math.max(1 - amplitude * GRIP_HOT_MAX_LOSS_SHARE,
    1 + amplitude * GRIP_HOT_RETAINED_SHARE - (surfaceTemp - GRIP_HOT_C) * amplitude / GRIP_HOT_FALLOFF_SPAN_C)
end

-- Services -----------------------------------------------------------------------------------------

function M.new(inputs)
  local runtime = inputs.runtime
  local forecast = inputs.model

  -- Resolve cached names on use: scene objects can be deleted or replaced without a level change.
  -- Numeric identities survive collected Lua handles without retaining engine userdata.
  local function sceneCache()
    if not runtime.sceneCache then
      runtime.sceneCache = {rows = {}, identities = setmetatable({}, {__mode = "v"})}
    end
    return runtime.sceneCache
  end

  local function rememberSceneObject(cache, key, row, object)
    local pass = runtime.scenePass
    local id = object.getID and object:getID()
    if (not row.resolvedId or type(id) == "number" and row.id ~= id) and object.getID then
      local resolved = type(id) == "number" and scenetree.findObject(id)
      if resolved and resolved:getID() == id then row.id = id end
      row.resolvedId = true
    end
    local objectId = type(row.id) == "number" and row.id == id and id or nil
    local sameObject = objectId and row.objectId == objectId
      or not objectId and cache.identities[key] == object
    if not sameObject then
      row.values = {}
      runtime.lastVisualStepValues = nil
    end
    row.objectId = objectId
    cache.identities[key], cache.rows[key] = object, row
    if pass then pass[key] = object end
    return object, row.values
  end

  local function sceneObject(key, names, className)
    local cache = sceneCache()
    local pass = runtime.scenePass
    local row = cache.rows[key]
    if pass and pass[key] and row then return pass[key], row.values end
    local object = row and scenetree.findObject(row.id)
    if not object then
      local candidates = names
      for _, name in ipairs(candidates) do
        object = scenetree.findObject(name)
        if object then row = {id = name, values = {}}; break end
      end
      if not object then
        for _, name in ipairs(scenetree.findClassObjects(className) or {}) do
          object = scenetree.findObject(name)
          if object then row = {id = name, values = {}}; break end
        end
      end
    end
    if not object then cache.rows[key] = nil; return end
    return rememberSceneObject(cache, key, row, object)
  end

  local function scatterSky()
    return sceneObject("sky", {"ScatterSky", "sunsky", "scattersky"}, "ScatterSky")
  end

  local function levelInfo()
    return sceneObject("info", {"theLevelInfo"}, "LevelInfo")
  end

  local function cloudNames()
    local cache = sceneCache()
    if runtime.scenePass and runtime.scenePass.clouds then return cache.clouds end
    if cache.clouds then
      for _, name in ipairs(cache.clouds) do
        local object = scenetree.findObject(name)
        if not object then cache.clouds = nil; break end
        local key = "cloud:" .. name
        local row = cache.rows[key] or {id = name, values = {}}
        rememberSceneObject(cache, key, row, object)
      end
    end
    -- A baseline can be requested while the level is still creating its clouds.
    if not cache.clouds or #cache.clouds == 0 then cache.clouds = scenetree.findClassObjects("CloudLayer") or {} end
    if runtime.scenePass then runtime.scenePass.clouds = true end
    return cache.clouds
  end

  local function environmentChanged(changes)
    if runtime.writingEnvironment or runtime.writingClock then return end
    -- Time-only clock notifications do not change authored weather fields or scene membership.
    for key in pairs(changes or {}) do
      if key ~= "time" and key ~= "play" then runtime.sceneCache = nil; runtime.lastVisualStepValues = nil; return end
    end
  end
  -- The preset environment may disappear before extension teardown finishes, so restoration retains its lifecycle guards.
  -- Baseline capture -------------------------------------------------------------------------------

  local function isPavedGroundModel(name, groundModel)
    local profile = runtime.profile
    local upper = string.upper(tostring(name or ""))
    for _, token in ipairs(profile.pavedCollisionTypes or {}) do
      if string.find(upper, string.upper(tostring(token)), 1, true) then return true end
    end
    local cdata = groundModel and groundModel.cdata
    local collision = string.upper(cdata and tostring(cdata.collisiontype or cdata.collisionType or "") or "")
    for _, token in ipairs(profile.pavedCollisionTypes or {}) do
      if collision == string.upper(tostring(token)) then return true end
    end
    return false
  end

  local function captureCloudLayers(baseline, names)
    for _, name in ipairs(names) do
      if baseline.cloudLayers[name] == nil then
        local layer = sceneObject("cloud:" .. name, {name}, "CloudLayer")
        local coverage = layer and tonumber(layer.coverage)
        if coverage ~= nil then
          baseline.cloudLayers[name] = coverage
          -- Use a live layer rather than freezing a missing native lookup as zero.
          if baseline.cloudCover == nil then baseline.cloudCover = coverage end
        end
      end
    end
  end

  local function captureBaseline()
    if runtime.baseline then return end
    local baseline = {groundModels = {}}
    runtime.baseline = baseline
    baseline.fogDensity = core_environment and core_environment.getFogDensity and core_environment.getFogDensity() or 0.001
    baseline.cloudLayers = {}
    -- Layers are captured before setCloudCover mutates them, including coverage above 1.
    captureCloudLayers(baseline, cloudNames())
    local info = levelInfo()
    if info then
      baseline.fogAtmosphereHeight = tonumber(info.fogAtmosphereHeight)
      baseline.temperatureCurveC = info:getField("temperatureCurveC", 0)
    end
    local sky = scatterSky()
    if sky then
      baseline.skyBrightness = tonumber(sky.skyBrightness) or 1
      baseline.sunScale = toPoint4(sky.sunScale)
      baseline.ambientScale = toPoint4(sky.ambientScale)
      baseline.colorize = toPoint4(sky.colorize)
      baseline.sunSize = tonumber(sky.sunSize)
      baseline.flareScale = tonumber(sky.flareScale)
      baseline.brightness = tonumber(sky.brightness)
    end
    if core_environment and core_environment.groundModels then
      for name, groundModel in pairs(core_environment.groundModels) do
        if groundModel and groundModel.cdata and isPavedGroundModel(name, groundModel) then
          baseline.groundModels[name] = {
            staticFrictionCoefficient = tonumber(groundModel.cdata.staticFrictionCoefficient),
            slidingFrictionCoefficient = tonumber(groundModel.cdata.slidingFrictionCoefficient),
            strength = tonumber(groundModel.cdata.strength),
          }
        end
      end
    end
  end

  -- Rain particles ---------------------------------------------------------------------------------

  local function setRain(count)
    count = math.max(0, math.floor(tonumber(count) or 0))
    if runtime.globalSettings.vulkanSafeMode then count = 0 end
    if count == 0 and runtime.rainShown == 0 then return end
    local object = scenetree.findObject("rlsDynamicWeatherRain")
    if count == runtime.rainShown and object then return end
    runtime.rainShown = count
    if count <= 0 then
      if object then object:delete() end
      return
    end
    -- The live emitter accepts drop-budget changes without losing its identity.
    if object then
      object:setField("numDrops", 0, tostring(count))
      object:postApply()
      return
    end
    if not scenetree.MissionGroup then return end
    object = createObject("Precipitation")
    if not object then return end
    object:setField("dataBlock", 0, "rain_drop")
    -- model.EFFECTS already holds the drop budget; scaling it up here rendered 10,200 alpha-blended drops, too costly on the GPU.
    object:setField("numDrops", 0, tostring(count))
    object:setField("doCollision", 0, "false")
    object:setField("reflect", 0, "false")
    object:setField("useLighting", 0, "false")
    object.canSave = false
    object:registerObject("rlsDynamicWeatherRain")
    scenetree.MissionGroup:addObject(object)
  end

  -- Wet road materials -----------------------------------------------------------------------------

  local function collectRoadMaterials()
    if runtime.roadMaterials then return runtime.roadMaterials end
    local profile = runtime.profile
    local targets = {}
    local count = 0
    local cap = math.max(1, math.floor(tonumber(profile and profile.visualWetMaterialCap) or 24))
    local function add(materialName)
      if not materialName or materialName == "" or targets[materialName] or count >= cap then return end
      if matchesAny(string.lower(materialName), ROAD_EXCLUDE_WORDS) then return end
      targets[materialName] = true
      count = count + 1
    end
    local function addFromRoadObjects(className, fieldName)
      for _, objectName in ipairs(scenetree.findClassObjects(className) or {}) do
        if count >= cap then return end
        local object = scenetree.findObject(objectName)
        if object then
          local materialName = object:getField(fieldName, 0)
          if not materialName or materialName == "" then materialName = object:getField(fieldName, "") end
          add(materialName)
        end
      end
    end
    addFromRoadObjects("DecalRoad", "Material")
    addFromRoadObjects("MeshRoad", "topMaterial")
    for _, materialName in ipairs(scenetree.findClassObjects("Material") or {}) do
      if count >= cap then break end
      if matchesAny(string.lower(materialName), ROAD_WORDS) then add(materialName) end
    end
    runtime.roadMaterials = targets
    return targets
  end

  local function wetMaterial(materialName, roughness)
    local material = scenetree.findObject(materialName)
    if not material then return end
    local savedRoughness, savedDiffuse = runtime.savedRoughness, runtime.savedDiffuse
    local layers = tonumber(material.activeLayers) or 1
    savedRoughness[materialName] = savedRoughness[materialName] or {}
    savedDiffuse[materialName] = savedDiffuse[materialName] or {}
    local darkness = 0.60 + 0.35 * model.clamp((roughness - 0.07) / 0.43, 0, 1)
    for layer = 0, layers - 1 do
      if savedRoughness[materialName][layer] == nil then savedRoughness[materialName][layer] = material:getField("roughnessFactor", layer) end
      if savedDiffuse[materialName][layer] == nil then savedDiffuse[materialName][layer] = material:getField("diffuseColor", layer) end
      material:setField("roughnessFactor", layer, tostring(roughness))
      material:setField("diffuseColor", layer, darkenColorString(savedDiffuse[materialName][layer], darkness))
    end
    material:reload()
    runtime.materialTargets[materialName] = roughness
  end

  local function dryMaterial(materialName)
    local material = scenetree.findObject(materialName)
    if not material then return end
    for layer, original in pairs(runtime.savedRoughness[materialName] or {}) do
      material:setField("roughnessFactor", layer, original ~= "" and tostring(original) or "1")
    end
    for layer, original in pairs(runtime.savedDiffuse[materialName] or {}) do
      material:setField("diffuseColor", layer, original ~= "" and original or "1 1 1 1")
    end
    material:reload()
    runtime.materialTargets[materialName] = 0
  end

  local function queueWetLook(roughness)
    roughness = tonumber(roughness) or 0
    if runtime.globalSettings.vulkanSafeMode then roughness = 0 end
    -- Wetness snaps to 0.10 steps: finer steps reload every road material for changes too small to notice.
    roughness = roughness > 0 and math.floor(roughness / 0.10 + 0.5) * 0.10 or 0
    if math.abs(roughness - runtime.wetTargetRoughness) < 0.001 then return end
    runtime.wetTargetRoughness = roughness
    runtime.wetMaterialQueue = {}
    local wetMaterialQueue = runtime.wetMaterialQueue
    local source = roughness > 0 and collectRoadMaterials() or runtime.savedRoughness
    runtime.materialTargets = runtime.materialTargets or {}
    for materialName in pairs(source) do
      if runtime.materialTargets[materialName] ~= roughness then
        wetMaterialQueue[#wetMaterialQueue + 1] = materialName
      end
    end
  end

  -- Real-time material pass: one material per timer tick, so the reloads spread across frames.
  local function tickWetLook(dt)
    if #runtime.wetMaterialQueue == 0 then return end
    local timer = runtime.wetMaterialTimer
    timer:add(math.max(0, tonumber(dt) or 0))
    if not timer:take() then return end
    local materialName = table.remove(runtime.wetMaterialQueue)
    if runtime.wetTargetRoughness > 0 then
      wetMaterial(materialName, runtime.wetTargetRoughness)
    else
      dryMaterial(materialName)
    end
    if #runtime.wetMaterialQueue == 0 then
      runtime.wetAppliedRoughness = runtime.wetTargetRoughness
      if runtime.wetTargetRoughness == 0 then runtime.savedRoughness, runtime.savedDiffuse = {}, {} end
    end
  end

  local function updateWetLook()
    local state = runtime.state
    if not state or not state.settings.dynamicWeather or runtime.externalOverride or state.wetness <= 0.02 then
      queueWetLook(0)
      return
    end
    queueWetLook(model.lerp(0.50, 0.10, model.clamp(state.wetness, 0, 1)))
  end

  -- Weather audio ----------------------------------------------------------------------------------

  local function resolveSoundBase()
    local soundBase = runtime.soundBase
    if soundBase ~= nil then return soundBase ~= false and soundBase or nil end
    for _, candidate in ipairs(SOUND_BASE_CANDIDATES) do
      if FS:fileExists(candidate .. "jbw_rain2.ogg") then
        runtime.soundBase = candidate
        return candidate
      end
    end
    runtime.soundBase = false
    return nil
  end

  local function playWeatherSound(filename, volume, fadeIn)
    local base = resolveSoundBase()
    if not base then return nil end
    return Engine.Audio.playOnce("AudioGui", base .. filename, {volume = volume, fadeInTime = fadeIn or 0})
  end

  local function updateRainLoop(dt, effect)
    local rainLevel = model.clamp((effect.rain or 0) / RAIN_EFFECT_FOR_FULL_AUDIO, 0, 1)
    if rainLevel > RAIN_AUDIO_MIN_LEVEL then
      runtime.audioRainTimer = runtime.audioRainTimer - dt
      if runtime.audioRainTimer <= 0 then
        local result = playWeatherSound("jbw_rain2.ogg", 0.35 + 0.20 * rainLevel, RAIN_LOOP_FADE_IN_SECONDS)
        runtime.audioRainTimer = result and result.len and result.len > RAIN_LOOP_MIN_LENGTH_SECONDS
          and (result.len - RAIN_LOOP_FADE_IN_SECONDS) or RAIN_LOOP_FALLBACK_SECONDS
      end
    else
      runtime.audioRainTimer = 0
    end
  end

  local function updateThunder(dt, condition)
    if condition == "storm" and not runtime.transitioning then
      runtime.thunderCooldown = runtime.thunderCooldown - dt
      if runtime.thunderCooldown <= 0 then
        runtime.thunderCooldown = THUNDER_COOLDOWN_MIN_SECONDS + math.random() * THUNDER_COOLDOWN_SPAN_SECONDS
        runtime.thunderTimer = THUNDER_DELAY_MIN_SECONDS + math.random() * THUNDER_DELAY_SPAN_SECONDS
      end
    else
      runtime.thunderCooldown = 0
      runtime.thunderTimer = -1
    end
    if runtime.thunderTimer >= 0 then
      runtime.thunderTimer = runtime.thunderTimer - dt
      if runtime.thunderTimer < 0 then
        playWeatherSound("jbw_thunder" .. tostring(math.random(1, 3)) .. ".ogg", 0.80)
      end
    end
  end

  local function updateWeatherAudio(dt, effect, condition)
    updateRainLoop(dt, effect)
    updateThunder(dt, condition)
  end

  -- Environment restoration ------------------------------------------------------------------------

  local function restoreGroundModels()
    local baseline = runtime.baseline
    if not baseline or not core_environment or not core_environment.groundModels then return end
    for name, original in pairs(baseline.groundModels or {}) do
      local groundModel = core_environment.groundModels[name]
      if groundModel and groundModel.cdata then
        if original.staticFrictionCoefficient then groundModel.cdata.staticFrictionCoefficient = original.staticFrictionCoefficient end
        if original.slidingFrictionCoefficient then groundModel.cdata.slidingFrictionCoefficient = original.slidingFrictionCoefficient end
        if original.strength then groundModel.cdata.strength = original.strength end
        be:setGroundModel(name, groundModel.cdata)
      end
    end
    runtime.lastGripBucket = nil
  end

  local function clearRainState()
    clearRainObject("rlsDynamicWeatherRain")
    runtime.rainShown = 0
  end

  local function restoreClouds(baseline)
    if core_environment and core_environment.setCloudCover and baseline.cloudCover ~= nil then
      core_environment.setCloudCover(baseline.cloudCover)
    end
    if baseline.cloudLayers then
      for name, coverage in pairs(baseline.cloudLayers) do
        local layer = scenetree.findObject(name)
        if layer and layer.coverage ~= nil and tonumber(layer.coverage) ~= coverage then
          layer.coverage = coverage
          layer:postApply()
        end
      end
    end
  end

  local function restoreFog(baseline)
    if core_environment and core_environment.setFogDensity and baseline.fogDensity then core_environment.setFogDensity(baseline.fogDensity) end
    local info = levelInfo()
    if info and baseline.fogAtmosphereHeight then info.fogAtmosphereHeight = baseline.fogAtmosphereHeight end
    if info and baseline.temperatureCurveC and baseline.temperatureCurveC ~= "" then info:setField("temperatureCurveC", 0, baseline.temperatureCurveC) end
    if info then info:postApply() end
  end

  local function restoreSky(baseline)
    local sky = scatterSky()
    if not sky then return end
    if baseline.skyBrightness then sky.skyBrightness = baseline.skyBrightness end
    if baseline.sunScale then sky.sunScale = Point4F(baseline.sunScale[1], baseline.sunScale[2], baseline.sunScale[3], baseline.sunScale[4]) end
    if baseline.ambientScale then sky.ambientScale = Point4F(baseline.ambientScale[1], baseline.ambientScale[2], baseline.ambientScale[3], baseline.ambientScale[4]) end
    if baseline.colorize then sky.colorize = Point4F(baseline.colorize[1], baseline.colorize[2], baseline.colorize[3], baseline.colorize[4]) end
    if baseline.sunSize then sky.sunSize = baseline.sunSize end
    if baseline.flareScale then sky.flareScale = baseline.flareScale end
    if baseline.brightness then sky.brightness = baseline.brightness end
    sky:postApply()
  end

  local function restoreEnvironment()
    runtime.sceneCache = nil
    runtime.lastVisualStepValues = nil
    runtime.visualStepValues = nil
    runtime.previousVisualCandidateValues = nil
    runtime.roadMaterials = nil
    runtime.materialTargets = runtime.materialTargets or {}
    local baseline = runtime.baseline
    if not runtime.environmentApplied or not baseline then
      clearRainState()
      return
    end
    setRain(0)
    restoreClouds(baseline)
    restoreFog(baseline)
    restoreSky(baseline)
    restoreGroundModels()
    -- Teardown and editor saves cannot depend on future onUpdate calls to dry the roads.
    for materialName in pairs(runtime.savedRoughness) do dryMaterial(materialName) end
    runtime.savedRoughness, runtime.savedDiffuse, runtime.wetMaterialQueue = {}, {}, {}
    runtime.materialTargets = {}
    runtime.wetTargetRoughness, runtime.wetAppliedRoughness = 0, 0
    runtime.currentEffect = model.copyTable(model.EFFECTS.clear)
    runtime.transitioning = false
    runtime.environmentApplied = false
    runtime.baseline = nil
    runtime.sceneCache = nil
  end

  -- Visual effects ---------------------------------------------------------------------------------

  local function applyCloudCover(cover)
    cover = model.clamp(tonumber(cover) or 0, 0, 1)
    local names = cloudNames()
    captureCloudLayers(runtime.baseline, names)
    local changed = false
    for _, name in ipairs(names) do
      local layer, values = sceneObject("cloud:" .. name, {name}, "CloudLayer")
      if layer and (values.cover ~= cover or values.observedCover ~= tonumber(layer.coverage)) then changed = true end
    end
    if not changed then return end
    if core_environment and core_environment.setCloudCover then core_environment.setCloudCover(cover) end
    -- Native float fields can read back a different number than the Lua request.
    local appliedCover = core_environment and core_environment.getCloudCover and core_environment.getCloudCover()
    appliedCover = tonumber(appliedCover) or cover
    for _, name in ipairs(names) do
      local layer, values = sceneObject("cloud:" .. name, {name}, "CloudLayer")
      if layer and layer.coverage ~= nil then
        -- The native setter already writes and applies its primary layer.
        if tonumber(layer.coverage) ~= appliedCover then layer.coverage = cover end
        values.cover = cover
        values.observedCover = tonumber(layer.coverage)
      end
    end
  end

  local function effectFor(condition, fogFactor, fog)
    local target = model.copyTable(model.EFFECTS[condition] or model.EFFECTS.clear)
    target.fogAdd = math.max(target.fogAdd or 0, fogFactor * (fog and fog.maxDensity or 0))
    return target
  end

  local function interpolateCurrentEffect()
    local p = model.clamp(runtime.transitionElapsed / math.max(0.01, runtime.transitionDuration), 0, 1)
    local current, source, target = runtime.currentEffect, runtime.effectFrom, runtime.effectTarget
    for _, key in ipairs(M.EFFECT_KEYS) do current[key] = p >= 1 and target[key] or model.lerp(source[key] or target[key], target[key], p) end
    current.rain = p >= 0.35 and target.rain or (source.rain or 0)
    current.wetRough = target.wetRough
    current.tint = current.tint or {1, 1, 1}
    for channel = 1, 3 do
      current.tint[channel] = p >= 1 and target.tint[channel] or model.lerp(source.tint and source.tint[channel] or 1, target.tint[channel], p)
    end
  end

  local function startTransition(condition, fogFactor, fog)
    local target = effectFor(condition, fogFactor, fog)
    -- A retarget can arrive between visual ticks; its source must be the exact current effect.
    if runtime.transitioning then interpolateCurrentEffect() end
    runtime.effectFrom = model.copyTable(runtime.currentEffect)
    if not runtime.effectFrom.sky then runtime.effectFrom = model.copyTable(model.EFFECTS.clear) end
    runtime.effectTarget = target
    runtime.transitionElapsed = 0
    runtime.transitionDuration = model.clamp(runtime.profile.transitionMinutes * 1.5, 8, 45)
    runtime.transitioning = true
    runtime.previousVisualCandidateValues = nil
  end

  local function applyFog(effect, fog, clearFog, baseline)
    local info, values = levelInfo()
    if not info then return end
    local density = clearFog and 0 or ((baseline.fogDensity or 0) + (effect.fogAdd or 0))
    if values.fogDensity ~= density or tonumber(info.fogDensity) ~= density then
      if core_environment and core_environment.setFogDensity then core_environment.setFogDensity(density) end
      values.fogDensity = tonumber(info.fogDensity) == density and density or nil
    end
    local height = clearFog and (baseline.fogAtmosphereHeight or 0) or (fog and fog.atmosphereHeight or baseline.fogAtmosphereHeight)
    local observedHeight = tonumber(info.fogAtmosphereHeight)
    if height and (values.fogHeight ~= height or values.observedFogHeight ~= observedHeight) then
      if core_environment and core_environment.setFogAtmosphereHeight then
        core_environment.setFogAtmosphereHeight(height)
      else
        info.fogAtmosphereHeight = height
      end
      values.fogHeight = height
      values.observedFogHeight = tonumber(info.fogAtmosphereHeight)
    end
  end

  local function applySky(effect, baseline)
    local sky, values = scatterSky()
    if not sky then return end
    local changed = false
    local function scalar(key, value)
      if value == nil then return end
      if values[key] ~= value or tonumber(sky[key]) ~= value then
        sky[key] = value; values[key] = value; changed = true
      end
    end
    local function color(key, original, r, g, b)
      if not original then return end
      local x, y, z, w = original[1] * r, original[2] * g, original[3] * b, original[4]
      local old = values[key]
      local actual = sky[key]
      if not old or old[1] ~= x or old[2] ~= y or old[3] ~= z or old[4] ~= w
        or not actual or (actual.x or actual.r) ~= x or (actual.y or actual.g) ~= y or (actual.z or actual.b) ~= z or (actual.w or actual.a or 1) ~= w then
        sky[key] = Point4F(x, y, z, w)
        values[key] = {x, y, z, w}; changed = true
      end
    end
    scalar("skyBrightness", (baseline.skyBrightness or 1) * (effect.sky or 1))
    color("sunScale", baseline.sunScale, effect.sun, effect.sun, effect.sun)
    color("ambientScale", baseline.ambientScale, effect.ambient, effect.ambient, effect.ambient)
    if effect.tint then color("colorize", baseline.colorize, effect.tint[1], effect.tint[2], effect.tint[3]) end
    scalar("sunSize", baseline.sunSize and baseline.sunSize * effect.sun)
    scalar("flareScale", baseline.flareScale and baseline.flareScale * effect.sun)
    scalar("brightness", baseline.brightness and baseline.brightness * effect.brightness)
    if changed then sky:postApply() end
  end

  local function transitionStepChanged(effect, fog, finalStep, progress)
    local source, target = runtime.effectFrom, runtime.effectTarget
    local function scalar(key, fallback)
      if progress then return model.lerp(source[key] or target[key], target[key], progress) end
      return effect[key] or fallback
    end
    local function tint(channel)
      if progress then return model.lerp(source.tint and source.tint[channel] or 1, target.tint[channel], progress) end
      return effect.tint[channel]
    end
    local baseline = runtime.baseline
    local clearFog = runtime.state and runtime.state.forceClearFog == true
    local values = runtime.visualStepValues or {}
    runtime.visualStepValues = values
    values.fogDensity = clearFog and 0 or (baseline.fogDensity or 0) + scalar("fogAdd", 0)
    values.fogHeight = clearFog and (baseline.fogAtmosphereHeight or 0) or (fog and fog.atmosphereHeight or baseline.fogAtmosphereHeight)
    values.skyBrightness = (baseline.skyBrightness or 1) * scalar("sky", 1)
    values.brightness = baseline.brightness and baseline.brightness * scalar("brightness")
    values.sunSize = baseline.sunSize and baseline.sunSize * scalar("sun")
    values.flareScale = baseline.flareScale and baseline.flareScale * scalar("sun")
    values.cloudCover = clearFog and 0 or model.CLOUD_COVER[runtime.currentConditionName] or model.CLOUD_COVER.clear
    if progress then values.rain = progress >= 0.35 and target.rain or (source.rain or 0)
    else values.rain = effect.rain or 0 end
    local function color(key, multiplier)
      local original = baseline[key]
      if not original then return end
      for channel = 1, 3 do
        local scale = key == "colorize" and tint(channel) or multiplier
        values[key .. channel] = original[channel] * scale
      end
    end
    color("sunScale", scalar("sun"))
    color("ambientScale", scalar("ambient"))
    color("colorize")
    local previous = runtime.lastVisualStepValues
    local scheduled = previous and runtime.previousVisualCandidateValues
    local changed = finalStep or not previous or not scheduled
    local threshold = tonumber(runtime.profile.transitionWriteThresholdRelative) or 0.005
    for key, value in pairs(values) do
      local old = previous and previous[key]
      local scheduledValue = scheduled and scheduled[key]
      if old == nil or scheduledValue == nil then
        changed = true
      elseif value ~= old then
        -- The next frame may use a full scheduled step. A conservative per-value
        -- budget keeps variable frame times and retargets from enlarging that step.
        -- Linear changing ticks keep their cadence; identical ticks can coalesce.
        local scheduledDelta = math.abs(value - scheduledValue)
        local limit = math.min(math.abs(old) * threshold, scheduledDelta)
        if math.abs(value - old) >= limit then changed = true end
      end
    end
    scheduled = scheduled or {}
    for key, value in pairs(values) do scheduled[key] = value end
    runtime.previousVisualCandidateValues = scheduled
    if not changed then return false end
    previous = previous or {}
    for key, value in pairs(values) do previous[key] = value end
    runtime.lastVisualStepValues = previous
    return true
  end

  local function writeVisualEffect(effect, fog)
    runtime.environmentApplied = true
    local baseline = runtime.baseline
    local state = runtime.state
    local clearFog = state and state.forceClearFog == true
    runtime.writingEnvironment = true
    applyFog(effect, fog, clearFog, baseline)
    applySky(effect, baseline)
    local cover = (clearFog and 0) or model.CLOUD_COVER[runtime.currentConditionName] or model.CLOUD_COVER.clear
    applyCloudCover(cover)
    setRain(effect.rain or 0)
    runtime.writingEnvironment = false
    runtime.scenePass = nil
  end

  local function refreshSceneObjects()
    levelInfo()
    scatterSky()
    for _, name in ipairs(cloudNames()) do sceneObject("cloud:" .. name, {name}, "CloudLayer") end
  end

  local function applyVisualEffect(effect, fog, transitionStep, finalStep)
    runtime.scenePass = {}
    captureBaseline()
    refreshSceneObjects()
    if transitionStep and not transitionStepChanged(effect, fog, finalStep) then runtime.scenePass = nil; return false end
    if not transitionStep then runtime.lastVisualStepValues = nil end
    writeVisualEffect(effect, fog)
    return true
  end

  local function applyTransitionEffect(fog)
    runtime.scenePass = {}
    captureBaseline()
    refreshSceneObjects()
    local progress = model.clamp(runtime.transitionElapsed / math.max(0.01, runtime.transitionDuration), 0, 1)
    if not transitionStepChanged(nil, fog, progress >= 1, progress) then runtime.scenePass = nil; return false end
    interpolateCurrentEffect()
    writeVisualEffect(runtime.currentEffect, fog)
    return true
  end

  -- Ground grip ------------------------------------------------------------------------------------

  local function wetnessBand()
    local state = runtime.state
    local bands = runtime.profile.wetness.bands or {0.25, 0.60, 0.85}
    if state.wetness < bands[1] then return 1 end
    if state.wetness < bands[2] then return 2 end
    if state.wetness < bands[3] then return 3 end
    return 4
  end

  local function applyGroundGrip(condition)
    local state = runtime.state
    if not state.settings.dynamicWeather or runtime.externalOverride then
      restoreGroundModels()
      return
    end
    captureBaseline()
    local surfaceTemp = forecast.surfaceTemperatureAt(state.dayIndex, state.minuteOfDay, condition)
    local tempBucket = math.floor(surfaceTemp / 5)
    local band = wetnessBand()
    local bucket = tostring(tempBucket) .. ":" .. tostring(band)
    if bucket == runtime.lastGripBucket then return end
    runtime.lastGripBucket = bucket
    runtime.environmentApplied = true
    local wetMultipliers = runtime.profile.wetness.gripMultipliers or {1, 0.98, 0.94, 0.90}
    local wetMultiplier = tonumber(wetMultipliers[band]) or 1
    for name, original in pairs(runtime.baseline.groundModels or {}) do
      local groundModel = core_environment.groundModels[name]
      if groundModel and groundModel.cdata and original.staticFrictionCoefficient and original.slidingFrictionCoefficient then
        local highGrip = original.staticFrictionCoefficient > 1.0
        local multiplier = wetMultiplier * temperatureMultiplier(surfaceTemp, highGrip)
        groundModel.cdata.staticFrictionCoefficient = original.staticFrictionCoefficient * multiplier
        groundModel.cdata.slidingFrictionCoefficient = original.slidingFrictionCoefficient * multiplier
        be:setGroundModel(name, groundModel.cdata)
      end
    end
  end

  -- Tire weather report ----------------------------------------------------------------------------

  local function getTireWeatherState()
    local state, profile = runtime.state, runtime.profile
    local result = {
      roadWetness = 0,
      wetGripMultipliers = {
        standard = 1.00,
        sport = 0.94,
        race = 0.80,
        drag = 0.72,
      },
      wetGroundModels = {},
    }

    local configured = profile and profile.wetness and profile.wetness.tireCompoundGripMultipliers
    for compound, fallback in pairs(result.wetGripMultipliers) do
      result.wetGripMultipliers[compound] = model.clamp(
        configured and tonumber(configured[compound]) or fallback, 0.10, 1)
    end

    if state and profile and runtime.worldReady and state.settings.dynamicWeather and not runtime.externalOverride and not runtime.editorSuspended and runtime.editorSaveDepth == 0 then
      captureBaseline()
      local baseline = runtime.baseline
      for name in pairs(baseline and baseline.groundModels or {}) do
        result.wetGroundModels[tostring(name)] = true
      end
    end

    if runtime.loaded and runtime.worldReady and state and state.settings and state.settings.dynamicWeather and not runtime.externalOverride and not runtime.editorSuspended and runtime.editorSaveDepth == 0 then
      result.roadWetness = model.clamp(state.wetness, 0, 1)
    end
    return result
  end

  -- Service API ------------------------------------------------------------------------------------

  return {
    environmentChanged = environmentChanged,
    captureBaseline = captureBaseline,
    setRain = setRain,
    tickWetLook = tickWetLook,
    updateWetLook = updateWetLook,
    updateWeatherAudio = updateWeatherAudio,
    restoreGroundModels = restoreGroundModels,
    restoreEnvironment = restoreEnvironment,
    effectFor = effectFor,
    applyTransitionEffect = applyTransitionEffect,
    interpolateCurrentEffect = interpolateCurrentEffect,
    startTransition = startTransition,
    applyVisualEffect = applyVisualEffect,
    applyGroundGrip = applyGroundGrip,
    getTireWeatherState = getTireWeatherState,
    clearRainObject = clearRainObject,
  }

end

-- Public API --------------------------------------------------------------------------------------

M.EFFECT_KEYS = {"fogAdd", "sky", "sun", "ambient", "brightness", "wind"}
M.clearRainObject = clearRainObject

return M
