-- GE API: configure, setAmbientTemperature, resetThermalsAndGrip, applyFreshAndInflate, flushState, getRlsTireTelemetry.
-- Read provider state, rotator/contact helpers, thermal integration, provider selection, then public/lifecycle API.

-- Thermal/wear behavior derived from Tyre Wear and Thermals Redux by ZestyMaple98, distributed under AGPLv3.
-- See licenses/tyre-thermals-AGPL-3.0.txt.
-- RLS modifications: Copyright (C) RLS Modding.
-- Modified integration; changes and dates: licenses/tyre-thermals-NOTICE.md.

-- Keep calibrated gravity at 9.81; the exact standard conversion is 9.80665 m/s^2.
local calibratedGravityMS2 = 9.81
local M = {}
local geCallback = require('vehicle/overhaul/geCallback')

local tireModel = require("common/overhaul/tireModel")

local PROVIDER_VERSION = "1.3.5"
local REPORT_INTERVAL = 2
local TELEMETRY_INTERVAL = 0.2
local BASE_DISTANCE_WEAR_PER_METER = 1.4912e-9
local BASE_SLIP_WEAR_PER_JOULE = 1.6e-9
local context = {
  enabled = false,
  ambientTemperature = 21,
  initialState = {},
  groundModels = {},
  roadWetness = 0,
  wetGripMultipliers = {},
  wetGroundModels = {},
}
local wheelStates = {}
local wheelCache = {}
local vehicleMass = 1000
local reportTimer = 0
local telemetryTimer = TELEMETRY_INTERVAL
local providerCheckTimer = 0
local selectedProvider = "bundled"
local lastProviderKey
local configuredInventoryId
local configuredStateRevision
local configured = false
local contextRevision = 0
local gripApplied = false
local telemetrySequence = 0
-- An unattended car at rest skips the per-frame model; see canRest.
local REST_SPEED = 0.01
local REST_TEMPERATURE_MARGIN = 0.05
local REST_BRAKE_MARGIN = 1
local restBlocked = true
local framesSinceReport = 1
local telemetrySession = tostring(obj:getID()) .. ":" .. tostring(os.clock())

local function sendTelemetry(payload)
  telemetrySequence = telemetrySequence + 1
  payload.session = telemetrySession
  payload.sequence = telemetrySequence
  gui.send("RlsTireWearThermals", payload)
end

local function averageTemperature(state)
  local temperature = state and state.temperature or nil
  if type(temperature) ~= "table" then return context.ambientTemperature end
  local total, count = 0, 0
  for index = 1, 3 do
    local value = tonumber(temperature[index])
    if value then
      total = total + value
      count = count + 1
    end
  end
  return count > 0 and total / count or context.ambientTemperature
end

local function wheelConfig(index)
  return v and v.data and v.data.wheels and v.data.wheels[index] or {}
end

local function activeTirePartForWheel(wheelName)
  local wheelAxle = string.sub(string.upper(tostring(wheelName or "")), 1, 1)
  local bestPath, bestName, bestScore
  for path, partName in pairs(v and v.data and v.data.activeParts or {}) do
    local lowerPath = string.lower(tostring(path))
    local lowerName = string.lower(tostring(partName))
    if string.sub(lowerName, 1, 5) == "tire_" then
      local score = 1
      if wheelAxle == "F" and (string.find(lowerName, "tire_f", 1, true) or
                                string.find(lowerPath, "/wheel_f", 1, true)) then
        score = score + 10
      elseif wheelAxle ~= "F" and (string.find(lowerName, "tire_r", 1, true) or
                                    string.find(lowerPath, "/wheel_r", 1, true)) then
        score = score + 10
      end
      if not bestScore or score > bestScore then
        bestPath, bestName, bestScore = tostring(path), tostring(partName), score
      end
    end
  end
  return bestPath, bestName
end

-- Scale both thermal friction coefficients to preserve the curve shape.
local function thermalBaseline(index)
  local cfg = wheelConfig(index)
  local baseline = {
    peakTemp = 350,
    riseRange = 1e7,
    fallRange = 1e7,
    riseShape = 0,
    fallShape = 0,
    baseCoef = 1,
    peakCoef = 1,
  }
  if cfg.enableThermalFriction == true then
    baseline.peakTemp = tonumber(cfg.thermalFrictionPeakTemp) or baseline.peakTemp
    baseline.riseRange = tonumber(cfg.thermalFrictionRiseRange) or baseline.riseRange
    baseline.fallRange = tonumber(cfg.thermalFrictionFallRange) or baseline.fallRange
    baseline.riseShape = tonumber(cfg.thermalFrictionRiseShape) or baseline.riseShape
    baseline.fallShape = tonumber(cfg.thermalFrictionFallShape) or baseline.fallShape
    baseline.baseCoef = 0
    baseline.peakCoef = 1
  end
  return baseline
end

local GRIP_EPSILON = 1e-4

local function setWheelGrip(index, multiplier, force)
  local cached = wheelCache[index]
  if not force and cached and cached.appliedGrip and math.abs(cached.appliedGrip - multiplier) < GRIP_EPSILON then
    return
  end
  local wheel = obj:getWheel(index)
  if not wheel then return end
  local baseline = cached and cached.baseline or thermalBaseline(index)
  wheel:setFrictionThermalSensitivity(
    baseline.peakTemp,
    baseline.riseRange,
    baseline.fallRange,
    baseline.riseShape,
    baseline.fallShape,
    baseline.baseCoef * multiplier,
    baseline.peakCoef * multiplier,
    1
  )
  if cached then cached.appliedGrip = multiplier end
end

local function restoreGrip()
  for index in pairs(wheelCache) do setWheelGrip(index, 1, true) end
  gripApplied = false
  restBlocked = true
end

local function resetTemperatures()
  restBlocked = true
  for _, state in pairs(wheelStates) do
    state.temperature = {
      context.ambientTemperature,
      context.ambientTemperature,
      context.ambientTemperature,
      context.ambientTemperature,
    }
  end
end

local function restoreSoftDeflation(index, rotator)
  if not rotator or rotator.isTireDeflated ~= true or rotator.isBroken == true then return false end
  local wheel = rotator -- wheels.wheels uses rotator indexes, not cids.
  local cfg = wheelConfig(index)
  local pressureGroupId = wheel.pressureGroupId or
    (cfg.pressureGroup and v and v.data and v.data.pressureGroups and v.data.pressureGroups[cfg.pressureGroup])
  local startingPressure = tonumber(wheel.startingPressure)
  if pressureGroupId == nil or startingPressure == nil then return false end

  obj:setGroupPressure(pressureGroupId, startingPressure)
  wheel.isTireDeflated = false
  rotator.isTireDeflated = false
  return true
end

local function resetWheelBrokenBeams(wheelid)
  local fn = beamstate and beamstate.deflateTire
  if type(fn) ~= "function" or not debug or type(debug.getupvalue) ~= "function" then
    return
  end
  local i = 1
  while true do
    local name, value = debug.getupvalue(fn, i)
    if not name then
      break
    end
    if name == "wheelBrokenBeams" and type(value) == "table" then
      value[wheelid] = nil
      return
    end
    i = i + 1
  end
end

local function restoreBeamList(beamList)
  if type(beamList) ~= "table" or not v or not v.data or not v.data.beams then
    return
  end
  for _, beamcid in pairs(beamList) do
    local beam = v.data.beams[beamcid]
    if beam then
      obj:setBeamSpringDamp(beamcid, beam.beamSpring or 0, beam.beamDamp or 0, -1, -1)
    end
  end
end

local function restoreDeflatedTire(index, rotator)
  local dataWheel = v and v.data and v.data.wheels and v.data.wheels[index]
  local wheel = rotator -- wheels.wheels uses rotator indexes, not cids.
  if not dataWheel or not rotator then
    return false
  end

  restoreSoftDeflation(index, rotator)
  if dataWheel.pressureGroup and v.data.pressureGroups and v.data.pressureGroups[dataWheel.pressureGroup] then
    local startingPressure = tonumber(wheel.startingPressure) or 200000
    obj:setGroupPressure(v.data.pressureGroups[dataWheel.pressureGroup], startingPressure)
  end

  if wheel then
    wheel.isTireDeflated = false
    wheel.isPunctured = false
  end
  rotator.isTireDeflated = false
  rotator.isPunctured = false
  resetWheelBrokenBeams(index)

  if damageTracker and damageTracker.setDamage then
    pcall(damageTracker.setDamage, "wheels", "tire" .. tostring(dataWheel.name or rotator.name or ""), false)
  end

  if dataWheel.treadNodes then
    for _, nodecid in pairs(dataWheel.treadNodes) do
      local node = v.data.nodes and v.data.nodes[nodecid]
      if node and node.frictionCoef then
        obj:setNodeFrictionSlidingCoefs(nodecid, node.frictionCoef, node.slidingFrictionCoef or node.frictionCoef)
      end
    end
  end
  restoreBeamList(dataWheel.treadBeams)
  restoreBeamList(dataWheel.sideBeams)
  restoreBeamList(dataWheel.peripheryBeams)
  restoreBeamList(dataWheel.reinfBeams)
  if dataWheel.pressuredBeams and v.data.beams then
    for _, beamcid in pairs(dataWheel.pressuredBeams) do
      local beam = v.data.beams[beamcid]
      if beam then
        -- Stored pressures are absolute Pa; the setter takes relative pressure.
        local envPressure = tonumber(powertrain and powertrain.currentEnvPressure) or 101325
        local pressure = tonumber(beam.pressure) or tonumber(wheel.startingPressure) or 200000
        local maxPressure = tonumber(beam.maxPressure) or math.huge
        obj:setBeamPressureRel(beamcid, math.max(0, pressure - envPressure), math.max(0, maxPressure - envPressure), -1, -1)
      end
    end
  end
  return true
end

local function getVehicleMass()
  local mass = 0
  for _, node in pairs(v and v.data and v.data.nodes or {}) do
    mass = mass + (tonumber(node.nodeWeight) or 0)
  end
  return math.max(mass, 1)
end

local function externalExtension()
  if not extensions.isExtensionLoaded("luukstyrethermalsandwear") then
    return nil
  end
  return extensions.luukstyrethermalsandwear
end

local function externalApi(ext)
  if not ext then return nil end
  local getInfo = ext.getRlsTireProviderInfo or ext.getRlsProviderInfo
  local configure = ext.configureRlsTireProvider or ext.setRlsContext
  local getState = ext.getRlsTireState or ext.getRlsState
  if type(getInfo) == "function" and type(configure) == "function" and type(getState) == "function" then
    return {
      getInfo = getInfo,
      configure = configure,
      getState = getState,
      restore = ext.restoreRlsThermalsAndGrip or ext.resetRlsThermalsAndGrip,
      flush = ext.flushRlsTireState or ext.flushRlsState,
      handlePartChanges = ext.handleRlsTirePartChanges or ext.onRlsTirePartChanges,
    }
  end
end

local function providerInfo()
  local ext = externalExtension()
  local api = externalApi(ext)
  if ext and api then
    local ok, info = pcall(api.getInfo)
    info = ok and type(info) == "table" and info or {}
    return {
      id = info.id or "external-tyre-thermals",
      name = info.name or "Tyre Wear and Thermals Redux",
      version = info.version or "unknown",
      apiVersion = tonumber(info.apiVersion) or 1,
      source = "external",
      integrated = true,
      capabilities = info.capabilities or {
        gating = true, persistence = true, exclusions = true, telemetry = true, replacement = true,
      },
    }
  elseif ext then
    return {
      id = "external-tyre-thermals-legacy",
      name = "Tyre Wear and Thermals Redux",
      version = "legacy/unknown",
      apiVersion = 0,
      source = "external",
      integrated = false,
      capabilities = {},
    }
  end
  return {
    id = "rls-bundled",
    name = "RLS Tyre Wear and Thermals",
    version = PROVIDER_VERSION,
    apiVersion = 1,
    source = "bundled",
    integrated = true,
    capabilities = {
      gating = true, persistence = true, exclusions = true, telemetry = true, replacement = true,
      weatherGrip = true,
    },
  }
end

local function detectProvider(force)
  local info = providerInfo()
  local nextProvider = tireModel.selectProvider(info.source == "external", info.integrated == true)
  if force or nextProvider ~= selectedProvider then
    if selectedProvider == "bundled" then restoreGrip() end
    selectedProvider = nextProvider
    lastProviderKey = nil
    if nextProvider == "external" then
      local api = externalApi(externalExtension())
      if api then pcall(api.configure, deepcopy(context)) end
    end
  end
  return info
end

local function materialName(materialId)
  if not particles or not particles.getMaterialsParticlesTable then return "unknown" end
  local materials = particles.getMaterialsParticlesTable()
  local row = materials and materials[materialId] or nil
  return row and row.name or "unknown"
end

local surfaceTuningByName = {}
local defaultGroundModel = {staticFrictionCoefficient = 1, slidingFrictionCoefficient = 1}

local function groundModel(materialId)
  local name = materialName(materialId)
  return name, context.groundModels[name] or defaultGroundModel
end

local function makeState(index, rotator)
  local cfg = wheelConfig(index)
  local name = tostring(rotator.name or cfg.name or index)
  local saved = context.initialState and context.initialState[name] or nil
  local remaining = saved and tonumber(saved.remaining) or tonumber(context.defaultRemaining) or 1
  local working = 85 * tireModel.clamp(1.05 - (tonumber(rotator.treadCoef or cfg.treadCoef) or 0.7) * 0.1, 0.85, 1.05)
  local temperature = {
    context.ambientTemperature,
    context.ambientTemperature,
    context.ambientTemperature,
    context.ambientTemperature,
  }
  if saved and type(saved.temperature) == "table" then
    for ring = 1, 4 do
      temperature[ring] = tonumber(saved.temperature[ring]) or context.ambientTemperature
    end
  end
  return {
    name = name,
    remaining = tireModel.clamp(remaining, 0, 1),
    flat = saved and saved.flat == true or false,
    temperature = temperature,
    workingTemperature = working,
  }
end

local function cacheRotator(index, rotator)
  local cached = wheelCache[index]
  if cached and cached.staticResolved then
    wheelStates[index] = wheelStates[index] or makeState(index, rotator)
    return cached, wheelStates[index]
  end
  local cfg = wheelConfig(index)
  cached = cached or {baseline = thermalBaseline(index)}
  local tirePartPath, tirePartName = activeTirePartForWheel(rotator.name or cfg.name)
  cached.name = tostring(rotator.name or cfg.name or index)
  cached.width = tonumber(cfg.tireWidth or rotator.tireWidth) or 0.205
  cached.radius = tonumber(rotator.radius or cfg.radius) or 0.3
  cached.partOrigin = tirePartName or cfg.partOrigin or rotator.partOrigin
  cached.partPath = tirePartPath or cfg.partPath or rotator.partPath or cached.partOrigin
  cached.containingSlot = tirePartPath and tirePartPath:match("^(.*[/])[^/]+$") or
                            cfg.containingSlot or rotator.containingSlot
  cached.baseFriction = tonumber(cfg.frictionCoef or rotator.frictionCoef) or 1
  cached.slidingFriction = tonumber(cfg.slidingFrictionCoef or rotator.slidingFrictionCoef) or cached.baseFriction
  cached.treadCoef = tonumber(rotator.treadCoef or cfg.treadCoef) or 0.7
  cached.compound = tireModel.classifyTireCompound(cached)
  cached.staticCompound = cached.compound
  cached.widthWearMultiplier = tireModel.widthWearMultiplier(cached.width)
  cached.staticResolved = true
  wheelCache[index] = cached
  wheelStates[index] = wheelStates[index] or makeState(index, rotator)
  return cached, wheelStates[index]
end

local function updateTemperatures(state, cached, rotator, slipWork, speed, dt)
  local ambient = context.ambientTemperature
  local brakeTemp = tonumber(rotator.brakeSurfaceTemperature) or ambient
  -- With no heat source the ambient floor leaves all four rings unchanged.
  if slipWork == 0 and state.temperature[1] == ambient and state.temperature[2] == ambient
      and state.temperature[3] == ambient and state.temperature[4] == ambient and brakeTemp <= ambient then return end
  -- Empirical calibration; the heat divisor is not a measured material heat capacity.
  local minimumThermalWidthMeters = 0.150
  local thermalReferenceRadiusMeters = 0.3
  local slipHeatDivisor = 106250
  local centerRingHeatGain = 1.05
  local shoulderRingHeatGain = 0.975

  local skinBaseCoolingCoefficient = 0.0025
  local skinSpeedRootCoolingCoefficient = 0.0007

  local skinToCoreExchangeCoefficient = 0.035
  local brakeToCoreExchangeCoefficient = 0.0015

  local coreBaseCoolingCoefficient = 0.0015
  local coreSpeedCoolingCoefficient = 0.00015

  local width = math.max(cached.width, minimumThermalWidthMeters)
  -- Larger tires contain more rubber; width alone overheats loaded truck tires.
  local thermalMassScale = math.max(1, (cached.radius / thermalReferenceRadiusMeters) ^ 2)
  local heatGain = slipWork / (width * slipHeatDivisor * thermalMassScale)
  local skinAverage = averageTemperature(state)
  -- Water only scales cooling of heat above ambient; with none, skip the node scan.
  local waterCooling = 1
  if skinAverage - context.ambientTemperature ~= 0 or state.temperature[4] - context.ambientTemperature ~= 0 then
    waterCooling = tireModel.waterCoolingMultiplier(tireModel.wheelTouchesWater(rotator, obj))
  end
  local cooling = (skinAverage - context.ambientTemperature) *
                    (skinBaseCoolingCoefficient + math.sqrt(math.max(speed, 0)) * skinSpeedRootCoolingCoefficient) * waterCooling
  for ring = 1, 3 do
    local ringBias = ring == 2 and centerRingHeatGain or shoulderRingHeatGain
    state.temperature[ring] = tireModel.temperatureWithAmbientFloor(
      state.temperature[ring] + (heatGain * ringBias - cooling) * dt,
      context.ambientTemperature)
  end
  local coreExchange = (skinAverage - state.temperature[4]) * skinToCoreExchangeCoefficient
  local brakeExchange = (brakeTemp - state.temperature[4]) * brakeToCoreExchangeCoefficient
  local coreCooling = (state.temperature[4] - context.ambientTemperature) *
                        (coreBaseCoolingCoefficient + speed * coreSpeedCoolingCoefficient) * waterCooling
  state.temperature[4] = tireModel.temperatureWithAmbientFloor(
    state.temperature[4] + (coreExchange + brakeExchange - coreCooling) * dt,
    context.ambientTemperature)
end

local function applyTireWearAndGrip(
  dt, speed, referenceLoad, index, cached, state, abrasionWearMultiplier, load, hasLoadedContact,
  abrasionSlipSeverity, inherentGrip, effectiveGrip, abrasionSlipWork, conditionGrip
)
  -- Abrasion work already includes grip; unloaded wheels must not accumulate rolling wear.
  local distanceWear = hasLoadedContact and speed * BASE_DISTANCE_WEAR_PER_METER * effectiveGrip or 0
  local slipWear = abrasionSlipWork * BASE_SLIP_WEAR_PER_JOULE * abrasionWearMultiplier
  if context.readOnly ~= true and (distanceWear ~= 0 or slipWear ~= 0) then
    local loadMultiplier = tireModel.clamp(load / math.max(referenceLoad, 1), 0.25, 3)
    local overheatMultiplier = tireModel.overheatWearMultiplier(
      inherentGrip, averageTemperature(state), state.workingTemperature)
    local wear = tireModel.combineWearComponents(distanceWear, slipWear, loadMultiplier) *
      cached.widthWearMultiplier * overheatMultiplier * dt
    state.remaining = tireModel.clamp(state.remaining - wear, 0, 1)
  end

  if context.readOnly ~= true and not state.flat and state.remaining <= 0 then
    state.flat = true
    beamstate.deflateTire(index)
  elseif context.readOnly ~= true and not state.flat and state.remaining < 0.10 and load > 0 and
      abrasionSlipSeverity > 0.2 then
    local riskPerSecond = ((0.10 - state.remaining) / 0.10) *
                            tireModel.clamp(abrasionSlipSeverity, 0, 5) * 0.015
    if math.random() < riskPerSecond * dt then
      state.flat = true
      beamstate.deflateTire(index)
    end
  end

  local temperature = averageTemperature(state)
  if cached.gripRemaining ~= state.remaining or cached.gripTemperature ~= temperature then
    cached.conditionGrip = tireModel.gripMultiplier(state.remaining, temperature, state.workingTemperature)
    cached.gripRemaining, cached.gripTemperature = state.remaining, temperature
  end
  return cached.conditionGrip
end

local function updateTireSurfaceResponse(
  dt, speed, referenceLoad, index, rotator, cached, state, rawThermalSlipSeverity,
  rawAbrasionSlipSeverity, abrasionWearMultiplier, load, hasLoadedContact, groundName, ground
)
  local surfaceTuning = surfaceTuningByName[groundName]
  if not surfaceTuning then
    surfaceTuning = tireModel.surfaceTireTuning(groundName)
    surfaceTuningByName[groundName] = surfaceTuning
  end
  local thermalSlipSeverity = tireModel.smoothSlipCap(
    rawThermalSlipSeverity, surfaceTuning.thermalSlipCap)
  local abrasionSlipSeverity = tireModel.smoothSlipCap(
    rawAbrasionSlipSeverity, surfaceTuning.abrasionSlipCap)
  -- Surface response changes with contact material or GE context, not with the frame rate.
  if cached.surfaceRevision ~= contextRevision or cached.contactMaterial ~= groundName then
    cached.weatherWetness = tireModel.wetnessForSurface(context.roadWetness, groundName, context.wetGroundModels)
    cached.weatherGrip, cached.compound = tireModel.wetGripMultiplierForCompound(
      cached.weatherWetness, cached.staticCompound, context.wetGripMultipliers)
    local groundFriction = math.max(tonumber(ground.staticFrictionCoefficient) or 1, 0.1)
    local wheelFriction = (math.max(cached.baseFriction, 0.1) + math.max(cached.slidingFriction, 0.1)) * 0.5
    local tunedGrip = math.max(tonumber(cached.baseline and cached.baseline.middleCoef) or 1, 0.1)
    cached.inherentGrip = wheelFriction * tunedGrip
    cached.effectiveGrip = groundFriction * wheelFriction * tunedGrip * cached.weatherGrip
    cached.contactMaterial, cached.surfaceRevision = groundName, contextRevision
  end
  local weatherWetness, weatherGrip, compound = cached.weatherWetness, cached.weatherGrip, cached.compound
  cached.lastContactMaterialID = rotator.contactMaterialID1
  local inherentGrip, effectiveGrip = cached.inherentGrip, cached.effectiveGrip
  -- Native slip signals already include speed, so multiplying by speed again exaggerates abrasion.
  local thermalSlipWork = load * effectiveGrip * thermalSlipSeverity * surfaceTuning.thermalMultiplier
  local abrasionSlipWork = load * effectiveGrip * abrasionSlipSeverity * surfaceTuning.abrasionMultiplier
  local conditionGrip = 1
  if context.enabled then
    updateTemperatures(state, cached, rotator, thermalSlipWork, speed, dt)
    conditionGrip = applyTireWearAndGrip(
      dt, speed, referenceLoad, index, cached, state, abrasionWearMultiplier, load, hasLoadedContact,
      abrasionSlipSeverity, inherentGrip, effectiveGrip, abrasionSlipWork, conditionGrip
    )
  else
    -- Reuse the array to avoid allocating per wheel when maintenance is disabled.
    for ring = 1, 4 do
      state.temperature[ring] = context.ambientTemperature
    end
  end
  return weatherWetness, weatherGrip, compound, conditionGrip
end

local function updateBundledWheelStates(dt, speed, referenceLoad, stream)
  for index, rotator in pairs(wheels.wheelRotators) do
    local cached, state = cacheRotator(index, rotator)
    local wasFlat = state.flat == true
    local isPhysicallyFlat = rotator.isTireDeflated == true or rotator.isBroken == true
    if context.enabled then
      state.flat = state.flat or isPhysicallyFlat
      if state.flat and not isPhysicallyFlat then beamstate.deflateTire(index) end
    else
      restoreSoftDeflation(index, rotator)
      state.remaining = 1
      state.flat = false
    end

    local rawThermalSlipSeverity, rawAbrasionSlipSeverity, abrasionWearMultiplier = tireModel.slipSeverities(
      rotator.lastSlip, rotator.lastSideSlip)
    local load = math.max(math.abs(tonumber(rotator.downForceRaw or rotator.downForce) or 0), 0)
    local hasLoadedContact = load > 0 and
      ((tonumber(rotator.contactMaterialID1) or -1) >= 0 or
       (tonumber(rotator.contactMaterialID2) or -1) >= 0)
    local groundName, ground = groundModel(rotator.contactMaterialID1)
    local weatherWetness, weatherGrip, compound, conditionGrip = updateTireSurfaceResponse(
      dt, speed, referenceLoad, index, rotator, cached, state, rawThermalSlipSeverity,
      rawAbrasionSlipSeverity, abrasionWearMultiplier, load, hasLoadedContact, groundName, ground
    )
    local appliedGrip = conditionGrip * weatherGrip
    setWheelGrip(index, appliedGrip)
    gripApplied = true

    if not wasFlat and state.flat then reportTimer = REPORT_INTERVAL end

    if stream then
      table.insert(stream.data, {
        name = state.name,
        working_temp = state.workingTemperature,
        temp = deepcopy(state.temperature),
        avg_temp = averageTemperature(state),
        condition = state.remaining * 100,
        tyreGrip = appliedGrip,
        conditionGrip = conditionGrip,
        weatherGrip = weatherGrip,
        roadWetness = weatherWetness,
        compound = compound,
        camber = 0,
        contact_material = groundName,
        flat = state.flat,
      })
    end
  end
end

local function updateBundled(dt, emitTelemetry)
  if not wheels or not wheels.wheelRotators then return end
  local speed = obj:getVelocity():length()
  local wheelCount = math.max(#wheels.wheelRotators + 1, 1)
  local referenceLoad = vehicleMass * calibratedGravityMS2 / wheelCount
  local stream = emitTelemetry and {data = {}, provider = providerInfo(), enabled = context.enabled == true} or nil

  updateBundledWheelStates(dt, speed, referenceLoad, stream)
  if not context.enabled and beamstate then
    beamstate.lowpressure = false
    for _, wheel in pairs(wheels.wheels or {}) do
      if wheel.isTireDeflated == true or wheel.isBroken == true then
        beamstate.lowpressure = true
        break
      end
    end
  end
  if stream then
    sendTelemetry(stream)
  end
end

local function reportState(force)
  if not configured then return end
  framesSinceReport = 0
  local info = providerInfo()
  local providerKey = table.concat({tostring(info.id), tostring(info.version), tostring(info.apiVersion)}, ":")
  if selectedProvider ~= "bundled" then
    sendTelemetry({data = {}, provider = info, enabled = context.enabled == true})
  end
  if selectedProvider == "external" then
    local api = externalApi(externalExtension())
    local ok, state = false, nil
    if api then ok, state = pcall(api.getState) end
    local payload = type(state) == "table" and deepcopy(state) or {}
    payload.provider = info
    payload.wheels = payload.wheels or {}
    obj:queueGameEngineLua(geCallback.command("receiveVehicleState", tostring(obj:getID()) .. "," .. serialize(payload)))
    lastProviderKey = providerKey
    return
  end

  local payload = {provider = info, wheels = {}}
  if selectedProvider == "bundled" then
    for index, state in pairs(wheelStates) do
      local cached = wheelCache[index] or {}
      table.insert(payload.wheels, {
        name = state.name,
        remaining = state.remaining,
        flat = state.flat,
        temperature = deepcopy(state.temperature),
        width = cached.width,
        partOrigin = cached.partOrigin,
        partPath = cached.partPath,
        containingSlot = cached.containingSlot,
      })
    end
    table.sort(payload.wheels, function(a, b) return a.name < b.name end)
  end
  if force or #payload.wheels > 0 or lastProviderKey ~= providerKey then
    obj:queueGameEngineLua(geCallback.command("receiveVehicleState", tostring(obj:getID()) .. "," .. serialize(payload)))
  end
  lastProviderKey = providerKey
end

-- What configure does after the provider is detected again, whatever changed.
local function finishContextChange(info)
  if selectedProvider == "bundled" and context.enabled ~= true then
    resetTemperatures()
    sendTelemetry({data = {}, provider = info, enabled = false})
  end
  telemetryTimer = TELEMETRY_INTERVAL
  reportState(lastProviderKey == nil)
  return info
end

function M.configure(nextContext)
  if type(nextContext) ~= "table" then return false end
  configured = true
  local wasEnabled = context.enabled == true
  local enabledChanged = wasEnabled ~= (nextContext.enabled == true)
  local inventoryChanged = configuredInventoryId ~= tonumber(nextContext.inventoryId)
  local revisionChanged = configuredStateRevision ~= tonumber(nextContext.stateRevision)
  if wasEnabled and nextContext.enabled ~= true and selectedProvider == "bundled" then
    reportState(true)
  end
  context = deepcopy(nextContext)
  contextRevision = contextRevision + 1
  context.ambientTemperature = tonumber(context.ambientTemperature) or 21
  context.initialState = type(context.initialState) == "table" and context.initialState or {}
  context.groundModels = type(context.groundModels) == "table" and context.groundModels or {}
  context.roadWetness = tireModel.clamp(context.roadWetness, 0, 1)
  context.wetGripMultipliers = type(context.wetGripMultipliers) == "table" and context.wetGripMultipliers or {}
  context.wetGroundModels = type(context.wetGroundModels) == "table" and context.wetGroundModels or {}
  restBlocked = true
  configuredInventoryId = tonumber(context.inventoryId)
  configuredStateRevision = tonumber(context.stateRevision)
  if inventoryChanged or revisionChanged or enabledChanged then
    wheelStates = {}
    wheelCache = {}
  end
  local info = detectProvider(true)
  if revisionChanged and selectedProvider == "external" then
    local api = externalApi(externalExtension())
    if api and type(api.handlePartChanges) == "function" then
      pcall(api.handlePartChanges, deepcopy(context))
    end
  end
  return finishContextChange(info)
end

-- Ambient-only updates retain the current wheel state and ownership context.
function M.setAmbientTemperature(ambientTemperature, initialState)
  if not configured then return false end
  context.ambientTemperature = tonumber(ambientTemperature) or 21
  if initialState ~= nil then
    context.initialState = type(initialState) == "table" and initialState or {}
  end
  restBlocked = true
  finishContextChange(detectProvider(true))
  return true
end

function M.getRlsTireProviderInfo()
  return providerInfo()
end

function M.getRlsTireState()
  local result = {provider = providerInfo(), wheels = {}}
  for index, state in pairs(wheelStates) do
    local cached = wheelCache[index] or {}
    table.insert(result.wheels, {
      name = state.name, remaining = state.remaining, flat = state.flat,
      temperature = deepcopy(state.temperature),
      partOrigin = cached.partOrigin, partPath = cached.partPath, containingSlot = cached.containingSlot,
    })
  end
  return result
end

function M.getRlsTireTelemetry()
  local result = {
    provider = providerInfo(),
    enabled = context.enabled == true,
    roadWetness = context.roadWetness,
    data = {},
  }
  for index, state in pairs(wheelStates) do
    local cached = wheelCache[index] or {}
    table.insert(result.data, {
      name = state.name,
      remaining = state.remaining,
      condition = state.remaining * 100,
      flat = state.flat,
      temperature = deepcopy(state.temperature),
      averageTemperature = averageTemperature(state),
      workingTemperature = state.workingTemperature,
      width = cached.width,
      partOrigin = cached.partOrigin,
      partPath = cached.partPath,
      compound = cached.compound or tireModel.classifyTireCompound(cached),
      weatherGrip = cached.weatherGrip or 1,
      weatherWetness = cached.weatherWetness or 0,
      contactMaterial = cached.contactMaterial,
    })
  end
  table.sort(result.data, function(a, b) return a.name < b.name end)
  return result
end

function M.resetThermalsAndGrip()
  reportState(true)
  if selectedProvider == "external" then
    local api = externalApi(externalExtension())
    if api and type(api.restore) == "function" then pcall(api.restore) end
  end
  resetTemperatures()
  restoreGrip()
end

function M.applyFreshAndInflate(nextInitial)
  if type(nextInitial) == "table" then
    context.initialState = deepcopy(nextInitial)
  else
    context.initialState = {}
  end
  if not wheels or not wheels.wheelRotators then
    resetTemperatures()
    restoreGrip()
    reportState(true)
    return true
  end
  for index, rotator in pairs(wheels.wheelRotators) do
    local _, state = cacheRotator(index, rotator)
    local saved = context.initialState[state.name]
    if saved then
      state.remaining = tireModel.clamp(tonumber(saved.remaining) or 1, 0, 1)
      state.flat = saved.flat == true
    else
      state.remaining = 1
      state.flat = false
    end
    if not state.flat then
      restoreDeflatedTire(index, rotator)
    end
  end
  resetTemperatures()
  restoreGrip()
  reportState(true)
  return true
end

function M.flushState()
  if selectedProvider == "external" then
    local api = externalApi(externalExtension())
    if api and type(api.flush) == "function" then pcall(api.flush) end
  end
  reportState(true)
  return true
end

-- Thermally settled parked tires skip negligible work until motion, configuration or grip changes.
local function canRest()
  if restBlocked or context.enabled ~= true then return false end
  if playerInfo and playerInfo.anyPlayerSeated then return false end
  if ai and ai.mode ~= nil and ai.mode ~= "disabled" then return false end
  if streams and streams.willSend("RlsTireWearThermals") then return false end
  if not wheels or not wheels.wheelRotators then return false end
  local ambient = context.ambientTemperature
  local anyWheel = false
  for index, rotator in pairs(wheels.wheelRotators) do
    local cached, state = wheelCache[index], wheelStates[index]
    if not cached or not state or cached.lastContactMaterialID == nil then return false end
    if state.flat or not (state.remaining > 0) or rotator.isTireDeflated == true or rotator.isBroken == true then
      return false
    end
    if rotator.contactMaterialID1 ~= cached.lastContactMaterialID then return false end
    if math.abs(tonumber(rotator.lastSlip) or 0) > 0.15 or math.abs(tonumber(rotator.lastSideSlip) or 0) > 0.05 then
      return false
    end
    if not ((tonumber(rotator.brakeSurfaceTemperature) or ambient) <= ambient + REST_BRAKE_MARGIN) then return false end
    for ring = 1, 4 do
      if not (state.temperature[ring] - ambient <= REST_TEMPERATURE_MARGIN) then return false end
    end
    anyWheel = true
  end
  return anyWheel and obj:getVelocity():length() < REST_SPEED
end

function M.updateGFX(dt)
  -- Wait for GE configuration before applying grip or wear to a managed vehicle.
  if not configured then return end
  dt = math.min(math.max(tonumber(dt) or 0, 0), 0.1)
  providerCheckTimer = providerCheckTimer + dt
  reportTimer = reportTimer + dt
  telemetryTimer = telemetryTimer + dt
  if providerCheckTimer >= 1 then
    providerCheckTimer = 0
    detectProvider(false)
  end
  local emitTelemetry = telemetryTimer >= TELEMETRY_INTERVAL
  if emitTelemetry then telemetryTimer = 0 end
  -- Only the open tire app consumes the stream.
  emitTelemetry = emitTelemetry and streams ~= nil and streams.willSend("RlsTireWearThermals") and true or false
  if selectedProvider == "bundled" and not canRest() then
    updateBundled(dt, emitTelemetry)
    restBlocked = false
    framesSinceReport = framesSinceReport + 1
  end
  if reportTimer >= REPORT_INTERVAL then
    reportTimer = 0
    -- After only resting frames the report would repeat the last one word for word.
    if framesSinceReport > 0 or selectedProvider ~= "bundled" then reportState(false) end
  end
end

function M.onReset()
  reportState(true)
  vehicleMass = getVehicleMass()
  resetTemperatures()
  restoreGrip()
  obj:queueGameEngineLua(geCallback.command("sendContextForVehicle", tostring(obj:getID()) .. ",true"))
end

function M.onInit()
  vehicleMass = getVehicleMass()
  detectProvider(true)
  obj:queueGameEngineLua(geCallback.command("sendContextForVehicle", tostring(obj:getID()) .. ",true"))
end

function M.onVehicleSpawned()
  M.onInit()
end

-- GE loads this extension after vehicle init, so onInit never fires.
function M.onExtensionLoaded()
  local mass = getVehicleMass()
  if mass > 1 then vehicleMass = mass end
end

return M
