-- GE API: startPull(pullId), abortPull(); samples/completion reply through onPullSample/onPullFinished.
-- Read config/state, overrides, readings, samples/curves, completion, stage updates, physics, then exports.
local M = {}
local geCallback = require('vehicle/overhaul/geCallback')
local units = require('common/overhaul/units')

-- Config ------------------------------------------------------------------------------------------
local abs = math.abs
local floor = math.floor
local max = math.max
local min = math.min

local avToRPM = units.AV_TO_RPM
-- Results use metric horsepower internally; the UI converts to the chosen units.
local wattsToUiPower = 1 / 735.49875

-- State -----------------------------------------------------------------------------
local pullState = nil
local unloading = false

-- Helpers -----------------------------------------------------------------------------------------

local function clearOverrides()
  if overhaulDynoLoad then overhaulDynoLoad.stopPull() end
  electrics.values.throttleOverride = nil
  electrics.values.brakeOverride = nil
end

local function addFlag(flag)
  if pullState then
    pullState.qualityFlags[flag] = true
  end
end

-- Per-step sums that makeSample averages into one sample.
local function emptyPhysicsAccumulator()
  return {duration=0, count=0, rpm=0, power=0, torque=0, flywheelPower=0, flywheelTorque=0, hubTorque=0}
end

-- Engine and gear readings ------------------------------------------------------------------------
-- Device category arrays are pairs-ordered on hybrids.
local function getEngine()
  if pullState and pullState.engine then
    return pullState.engine
  end
  local engine = powertrain.getDevice and powertrain.getDevice("mainEngine") or nil
  if not engine then
    local engines = powertrain.getDevicesByCategory("engine")
    engine = engines and engines[1] or nil
  end
  if pullState then
    pullState.engine = engine
  end
  return engine
end

local function getRPM(engine)
  if not engine then return 0 end
  -- engineInfo is a UI cache that refreshes only when streams.willSend; read live powertrain state.
  local av = tonumber(engine.outputAV1)
  return av and av * avToRPM or tonumber(engine.outputRPM) or 0
end

local function parseGearValue(value)
  local numeric = tonumber(value)
  if numeric then
    return floor(numeric)
  end

  if type(value) == "string" then
    local lower = string.lower(value)
    local embeddedGear = lower:match("^m(%d+)$") or lower:match("^(%d+)$")
    if embeddedGear then
      return floor(tonumber(embeddedGear))
    end
    if lower == "d" or lower == "s" or lower == "m" then
      return 1
    end
    if lower == "n" or lower == "p" then
      return 0
    end
    if lower == "r" then
      return -1
    end
  end

  return nil
end

local function getActualGearIndex()
  if powertrain and powertrain.getDevice then
    local gearbox = powertrain.getDevice("gearbox")
    local gearIndex = gearbox and tonumber(gearbox.gearIndex)
    if gearIndex then
      return floor(gearIndex)
    end
  end

  local values = electrics.values or {}
  local gear = parseGearValue(values.gearIndex)
    or parseGearValue(values.gear_M)
    or parseGearValue(values.visualGear)
    or parseGearValue(values.gear)

  return gear and floor(gear) or 0
end

local function getDisplayGear()
  local values = electrics.values or {}
  local indexedGear = parseGearValue(values.gearIndex)
    or parseGearValue(values.gear_M)
    or parseGearValue(values.visualGear)

  if indexedGear and indexedGear > 0 then
    return floor(indexedGear)
  end

  local gear = parseGearValue(values.gear) or indexedGear or parseGearValue(values.gear_A)
  return gear and floor(gear) or 0
end

local function getGear()
  local actual = getActualGearIndex()
  if actual ~= 0 then
    return actual
  end
  return getDisplayGear()
end

-- Pedal inputs ------------------------------------------------------------------------------------
local function getThrottle()
  local inputThrottle = input and tonumber(input.throttle) or nil
  return max(0, min(1,
    tonumber(electrics.values.throttleOverride)
      or inputThrottle
      or tonumber(electrics.values.throttle)
      or tonumber(electrics.values.throttle_input)
      or 0))
end

local function getBrake()
  local inputBrake = input and tonumber(input.brake) or nil
  return max(0, min(1,
    tonumber(electrics.values.brakeOverride)
      or inputBrake
      or tonumber(electrics.values.brake)
      or tonumber(electrics.values.brake_input)
      or 0))
end

-- Power and torque --------------------------------------------------------------------------------
local function getPowerTorque(engine, rpm)
  local flywheelTorque = engine and (tonumber(engine.outputTorque1) or tonumber(engine.outputTorque)) or 0
  -- wheels.wheelPower is a graphics-frame cache, so sum live wheel devices after the physics step.
  local wheelPowerWatts, rawWheelTorque = 0, 0
  for _, wheel in pairs(wheels.wheels or {}) do
    if not wheel.isBroken then
      local torque = wheel.propulsionTorque or 0
      wheelPowerWatts = wheelPowerWatts + torque * (wheel.angularVelocity or 0)
      rawWheelTorque = rawWheelTorque + torque * (wheel.wheelDir or 1)
    end
  end
  local wheelPower = wheelPowerWatts * wattsToUiPower
  local angularVelocity = rpm / avToRPM
  -- Refer wheel power back to engine speed; raw hub torque includes gear ratios.
  local wheelTorque = angularVelocity > 0 and wheelPowerWatts / angularVelocity or 0
  local flywheelPower = flywheelTorque * angularVelocity * wattsToUiPower
  return wheelPower, wheelTorque, flywheelPower, flywheelTorque,
    "wheelDevices.physics", "derivedWheelPowerRpm", "engine.outputTorque", "physicsAverage", rawWheelTorque
end

-- Samples -----------------------------------------------------------------------------------------
local function getRawGearData()
  local values = electrics.values or {}
  local gearbox = powertrain and powertrain.getDevice and powertrain.getDevice("gearbox") or nil
  return {
    gear = values.gear,
    gearIndex = values.gearIndex,
    gearA = values.gear_A,
    gearM = values.gear_M,
    deviceGearIndex = gearbox and gearbox.gearIndex or nil,
    deviceMaxGearIndex = gearbox and gearbox.maxGearIndex or nil,
    gearboxMode = values.gearboxMode
  }
end

local function makeSample()
  local engine = getEngine()
  local ramp = controller and controller.getController and controller.getController("overhaulDynoRamp")
  local rampState = ramp and ramp.getState()
  local rpm = getRPM(engine)
  local wheelPower, wheelTorque, flywheelPower, flywheelTorque, wheelPowerSource, wheelTorqueSource, flywheelTorqueSource, telemetrySource, rawWheelTorque = getPowerTorque(engine, rpm)
  local accumulator = pullState.physicsAccumulator
  local physicsCount = accumulator.count
  if accumulator.duration > 0 then
    rpm = accumulator.rpm / accumulator.duration
    wheelPower = accumulator.power / accumulator.duration
    wheelTorque = accumulator.torque / accumulator.duration
    flywheelPower = accumulator.flywheelPower / accumulator.duration
    flywheelTorque = accumulator.flywheelTorque / accumulator.duration
    rawWheelTorque = accumulator.hubTorque / accumulator.duration
  end
  pullState.physicsAccumulator = emptyPhysicsAccumulator()

  return {
    pullId = pullState.pullId,
    dynoSweepControlled = not rampState or rampState.controlled ~= false,
    physicsSampleCount = physicsCount,
    time = pullState.timer,
    stage = pullState.stage,
    rpm = rpm,
    gear = getGear(),
    throttle = getThrottle(),
    brake = getBrake(),
    wheelPower = max(0, wheelPower),
    wheelTorque = max(0, wheelTorque),
    rawWheelTorque = rawWheelTorque,
    flywheelPower = max(0, flywheelPower),
    flywheelTorque = max(0, flywheelTorque),
    rawWheelPowerSource = wheelPowerSource,
    rawWheelTorqueSource = wheelTorqueSource,
    rawFlywheelTorqueSource = flywheelTorqueSource,
    telemetrySource = telemetrySource,
    revLimiterActive = engine and engine.revLimiterActive == true or false,
    rawGear = getRawGearData(),
    valid = false,
    invalidReason = nil
  }
end

local function sendSample(sample)
  pullState.lastSample = sample
  if pullState.timer < pullState.nextUiTime then return end
  pullState.nextUiTime = pullState.timer + 0.1
  sample.acceptedSampleCount = pullState.acceptedSampleCount
  sample.rejectedSampleCount = pullState.rejectedSampleCount
  obj:queueGameEngineLua(geCallback.command("onPullSample", serialize(sample)))
end

-- Curve and peaks ---------------------------------------------------------------------------------
local function getFlagList()
  local flags = {}
  for flag, enabled in pairs(pullState.qualityFlags or {}) do
    if enabled then
      table.insert(flags, flag)
    end
  end
  table.sort(flags)
  return flags
end

local function buildCurve()
  local curve = {}
  for _, bin in pairs(pullState.bins or {}) do
    if bin.count and bin.count > 0 then
      local power = bin.power / bin.count
      local torque = 0
      if bin.torqueValues and #bin.torqueValues > 0 then
        table.sort(bin.torqueValues)
        local startIndex = 1
        local endIndex = #bin.torqueValues
        if #bin.torqueValues >= 5 then
          startIndex = 2
          endIndex = #bin.torqueValues - 1
        end

        local torqueSum = 0
        local torqueCount = 0
        for i = startIndex, endIndex do
          torqueSum = torqueSum + bin.torqueValues[i]
          torqueCount = torqueCount + 1
        end
        torque = torqueCount > 0 and (torqueSum / torqueCount) or (bin.torque / bin.count)
      else
        torque = bin.torque / bin.count
      end

      table.insert(curve, {
        rpm = bin.rpm,
        power = power,
        torque = torque,
        count = bin.count
      })
    end
  end
  table.sort(curve, function(a, b) return a.rpm < b.rpm end)
  return curve
end

local function buildPeaksFromCurve(curve)
  local peakPower = 0
  local peakTorque = 0
  local peakPowerRpm = 0
  local peakTorqueRpm = 0

  for _, point in ipairs(curve or {}) do
    if point.power and point.power > peakPower then
      peakPower = point.power
      peakPowerRpm = point.rpm or 0
    end
    if point.torque and point.torque > peakTorque then
      peakTorque = point.torque
      peakTorqueRpm = point.rpm or 0
    end
  end

  return peakPower, peakTorque, peakPowerRpm, peakTorqueRpm
end

-- Recording ---------------------------------------------------------------------------------------
local function setStage(stage)
  pullState.stage = stage
  pullState.stageTimer = 0
end

local function rejectSample(sample, reason)
  sample.valid = false
  sample.invalidReason = reason
  pullState.rejectedSampleCount = pullState.rejectedSampleCount + 1
end

local function discardTail(reason)
  for _, sample in ipairs(pullState.pendingSamples) do
    rejectSample(sample, reason)
  end
  pullState.pendingSamples = {}
end

local function discardWindow()
  for _, sample in ipairs(pullState.windowSamples) do
    rejectSample(sample, "incompleteWindow")
  end
  pullState.windowSamples = {}
end

local function endRecording(reason)
  pullState.endReason = reason
  pullState.cutoffTime = pullState.timer
  discardTail(reason == "revLimiter" and "limiterBuffer" or "endBuffer")
  discardWindow()
  setStage("finishing")
end

local function checkRawSample(sample)
  if sample.dynoSweepControlled == false then addFlag("dynoSweepUnregulated") end
  if sample.gear <= 0 then
    addFlag("neutralGear")
  end

  if pullState.recordingGear and sample.gear ~= pullState.recordingGear then
    addFlag("gearChanged")
    pullState.recordingGear = sample.gear
  end

  if sample.brake > pullState.maxBrake then
    addFlag("brakeInput")
  end

  if sample.throttle < pullState.highThrottle then
    addFlag("throttleBelowTarget")
  end

  if sample.wheelPower <= pullState.minPower then
    addFlag("noUsablePower")
  end

  if pullState.lastAcceptedRpm and sample.rpm < pullState.lastAcceptedRpm - 175 then
    addFlag("unstableRpm")
  end

  if pullState.acceptedSampleCount >= 3 and pullState.lastAcceptedPower and sample.wheelPower > (pullState.lastAcceptedPower * 2.25 + 150) then
    addFlag("powerSpike")
  end

  if pullState.acceptedSampleCount >= 3 and pullState.lastAcceptedTorque and sample.wheelTorque > (pullState.lastAcceptedTorque * 2.25 + 500) then
    addFlag("torqueSpike")
  end

  pullState.lastAcceptedPower = sample.wheelPower
  pullState.lastAcceptedTorque = sample.wheelTorque
  pullState.lastAcceptedRpm = sample.rpm
end

local function commitWindow()
  local samples = pullState.windowSamples
  if #samples == 0 then return end
  local sample = {rawCount = #samples, windowStart = pullState.windowStart,
    windowEnd = pullState.windowStart + pullState.averageWindow}
  for _, key in ipairs({"time", "rpm", "wheelPower", "wheelTorque", "flywheelPower", "flywheelTorque"}) do
    local sum = 0
    for _, raw in ipairs(samples) do sum = sum + raw[key] end
    sample[key] = sum / #samples
  end
  -- RMS torque residual around a fitted trend; needs three samples, since two always fit a line.
  local xx, xy = 0, 0
  for _, raw in ipairs(samples) do
    local x = raw.time - sample.time
    xx = xx + x*x
    xy = xy + x*(raw.wheelTorque - sample.wheelTorque)
    checkRawSample(raw)
    raw.valid = true
    raw.invalidReason = nil
  end
  local slope = xx > 0 and xy / xx or 0
  local residual = 0
  for _, raw in ipairs(samples) do
    local deviation = raw.wheelTorque - sample.wheelTorque - slope*(raw.time-sample.time)
    residual = residual + deviation*deviation
  end
  sample.torqueRoughness = #samples >= 3 and math.sqrt(residual/#samples) / max(abs(sample.wheelTorque), 1) or 0
  pullState.roughWindows = sample.torqueRoughness > 0.10 and (pullState.roughWindows + 1) or 0
  if pullState.roughWindows >= 3 then addFlag("sustainedTorqueRoughness") end
  table.insert(pullState.averagedSamples, sample)
  sample.valid = true
  sample.invalidReason = nil
  pullState.acceptedSampleCount = pullState.acceptedSampleCount + 1

  local binRpm = floor((sample.rpm + 50) / 100) * 100
  local bin = pullState.bins[binRpm]
  if not bin then
    bin = {rpm = binRpm, power = 0, torque = 0, torqueValues = {}, count = 0}
    pullState.bins[binRpm] = bin
  end

  bin.power = bin.power + sample.wheelPower
  bin.torque = bin.torque + sample.wheelTorque
  table.insert(bin.torqueValues, sample.wheelTorque)
  bin.count = bin.count + 1
  pullState.firstAcceptedRpm = pullState.firstAcceptedRpm or sample.rpm
  if sample.rpm > pullState.firstAcceptedRpm + 150 then pullState.sawRpmClimb = true end
  pullState.windowSamples = {}
end

local function acceptSample(sample)
  local index = floor((sample.time - pullState.recordingStartTime - pullState.startBuffer + 1e-8) / pullState.averageWindow)
  if pullState.windowIndex ~= index then
    commitWindow()
    pullState.windowIndex = index
    pullState.windowStart = pullState.recordingStartTime + pullState.startBuffer + index * pullState.averageWindow
  end
  table.insert(pullState.windowSamples, sample)
end

local function recordSample(sample)
  table.insert(pullState.rawSamples, sample)
  if sample.throttle >= pullState.highThrottle then
    pullState.sawHighThrottle = true
  end

  if pullState.sawHighThrottle and sample.throttle < pullState.finishThrottle then
    rejectSample(sample, "endBuffer")
    endRecording("throttleLift")
    sendSample(sample)
    return
  end

  if sample.time - pullState.recordingStartTime < pullState.startBuffer then
    rejectSample(sample, "startBuffer")
    sendSample(sample)
    return
  end

  sample.invalidReason = "pendingBuffer"
  table.insert(pullState.pendingSamples, sample)
  while pullState.pendingSamples[1]
    and sample.time - pullState.pendingSamples[1].time >= pullState.tailBuffer do
    acceptSample(table.remove(pullState.pendingSamples, 1))
  end
  sendSample(sample)
end

-- Pull completion ---------------------------------------------------------------------------------
local function buildCompletedPullResult(
  aborted, curve, peakPower, peakTorque, peakPowerRpm, peakTorqueRpm, measurementComplete,
  qualityFlags
)
  local result = {
    pullId = pullState.pullId,
    peakPower = peakPower,
    peakTorque = peakTorque,
    peakPowerRpm = peakPowerRpm,
    peakTorqueRpm = peakTorqueRpm,
    duration = pullState.timer or 0,
    aborted = aborted and true or false,
    -- A paid pull is always retained. Measurement problems are warnings.
    valid = true,
    measurementComplete = measurementComplete,
    pullStage = pullState.stage,
    pullQuality = measurementComplete and #qualityFlags == 0 and "clean" or "warning",
    qualityFlags = qualityFlags,
    acceptedSampleCount = pullState.acceptedSampleCount,
    rejectedSampleCount = pullState.rejectedSampleCount,
    curve = curve,
    rawSamples = pullState.rawSamples,
    averagedSamples = pullState.averagedSamples,
    averageWindow = pullState.averageWindow,
    endReason = pullState.endReason,
    cutoffTime = pullState.cutoffTime,
    startBuffer = pullState.startBuffer,
    tailBuffer = pullState.tailBuffer,
    liveSample = pullState.lastSample
  }
  return result
end

local function finishPull(aborted)
  if not pullState then
    return
  end

  pullState.stage = "complete"
  clearOverrides()
  discardTail("endBuffer")
  discardWindow()

  local curve = buildCurve()
  local peakPower, peakTorque, peakPowerRpm, peakTorqueRpm = buildPeaksFromCurve(curve)
  local hasCurve = #curve > 0

  if pullState.acceptedSampleCount < pullState.minAcceptedSamples then
    addFlag("insufficientData")
  end
  if peakPower <= 0 then
    addFlag("noUsablePower")
  end
  if not pullState.sawRpmClimb then
    addFlag("noRpmClimb")
  end

  local measurementComplete = not aborted and hasCurve and peakPower > 0
    and pullState.acceptedSampleCount >= pullState.minAcceptedSamples
    and pullState.sawRpmClimb
  if aborted then addFlag("pullInterrupted") end
  local qualityFlags = getFlagList()

  local result = buildCompletedPullResult(
    aborted, curve, peakPower, peakTorque, peakPowerRpm, peakTorqueRpm, measurementComplete,
    qualityFlags
  )

  obj:queueGameEngineLua(geCallback.command("onPullFinished", serialize(result)))
  pullState = nil
  -- The physics-step hook cannot be disabled; unloading drops this module from it.
  if not unloading then extensions.unload("overhaulDynoSession") end
end

local function abortPull()
  finishPull(true)
end

-- Stage machine -----------------------------------------------------------------------------------
local function updateStableGear(sample, dt)
  if sample.gear <= 0 then
    pullState.stableGear = nil
    pullState.stableGearTimer = 0
    return
  end

  if pullState.stableGear == sample.gear then
    pullState.stableGearTimer = pullState.stableGearTimer + dt
  else
    pullState.stableGear = sample.gear
    pullState.stableGearTimer = 0
  end
end

local function updateArmed(sample, dt)
  updateStableGear(sample, dt)

  if pullState.stableGear and pullState.stableGearTimer >= pullState.stableGearTime then
    setStage("ready")
  end
end

local function updateReady(sample, dt)
  updateStableGear(sample, dt)

  if sample.gear <= 0 then
    setStage("armed")
    return
  end

  if sample.throttle >= pullState.highThrottle
    and pullState.stableGear
    and pullState.stableGearTimer >= pullState.stableGearTime then
    pullState.recordingGear = sample.gear
    pullState.recordingStartRpm = sample.rpm
    pullState.recordingStartTime = sample.time
    setStage("recording")
    recordSample(sample)
  end
end

local function updateFinishing()
  if pullState.stageTimer >= pullState.finishDelay then
    finishPull(false)
  end
end

-- Physics step ------------------------------------------------------------------------------------
local function accumulatePullPhysics(dt)
  local engine = getEngine()
  local rpm = getRPM(engine)
  local power, torque, flywheelPower, flywheelTorque, _, _, _, _, hubTorque = getPowerTorque(engine, rpm)
  local accumulator = pullState.physicsAccumulator
  accumulator.duration = accumulator.duration + dt
  accumulator.count = accumulator.count + 1
  accumulator.rpm = accumulator.rpm + rpm * dt
  accumulator.power = accumulator.power + power * dt
  accumulator.torque = accumulator.torque + torque * dt
  accumulator.flywheelPower = accumulator.flywheelPower + flywheelPower * dt
  accumulator.flywheelTorque = accumulator.flywheelTorque + flywheelTorque * dt
  accumulator.hubTorque = accumulator.hubTorque + hubTorque * dt
end

local function onPhysicsStep(dt)
  if not pullState then
    return
  end

  accumulatePullPhysics(dt)

  pullState.timer = pullState.timer + dt
  pullState.stageTimer = pullState.stageTimer + dt
  pullState.sampleTimer = pullState.sampleTimer + dt

  -- Limiter pulses and lifts fall between samples, so latch the first boundary every frame.
  if pullState.stage == "recording" then
    local engine = getEngine()
    if engine and engine.revLimiterActive == true then
      endRecording("revLimiter")
    elseif getThrottle() < pullState.finishThrottle then
      endRecording("throttleLift")
    end
  end

  if pullState.timer >= pullState.maxPullTime then
    addFlag("timeout")
    finishPull(false)
    return
  end

  if pullState.sampleTimer < pullState.sampleInterval then
    return
  end
  local sampleDt = pullState.timer - pullState.lastSampleTime
  pullState.lastSampleTime = pullState.timer
  pullState.sampleTimer = pullState.sampleTimer % pullState.sampleInterval

  local sample = makeSample()

  if pullState.stage == "armed" then
    sample.invalidReason = "waitingForStableGear"
    sendSample(sample)
    updateArmed(sample, sampleDt)
  elseif pullState.stage == "ready" then
    sample.invalidReason = "waitingForThrottle"
    sendSample(sample)
    updateReady(sample, sampleDt)
  elseif pullState.stage == "recording" then
    recordSample(sample)
  elseif pullState.stage == "finishing" then
    sample.invalidReason = "finishing"
    table.insert(pullState.rawSamples, sample)
    sendSample(sample)
    updateFinishing()
  end
end

-- Lifecycle --------------------------------------------------------------------------------------
local function startPull(pullId)
  clearOverrides()
  extensions.load("overhaulDynoLoad")
  overhaulDynoLoad.startPull()
  enablePhysicsStepHook()

  pullState = {
    pullId = pullId,
    timer = 0,
    stageTimer = 0,
    sampleTimer = 0,
    stage = "armed",
    highThrottle = 0.9,
    finishThrottle = 0.75,
    maxBrake = 0.01,
    minPower = 1,
    stableGearTime = 0.5,
    stableGear = nil,
    stableGearTimer = 0,
    recordingGear = nil,
    recordingStartRpm = nil,
    sawRpmClimb = false,
    sawHighThrottle = false,
    physicsAccumulator = emptyPhysicsAccumulator(),
    sampleInterval = 0.02,
    lastSampleTime = 0,
    nextUiTime = 0,
    averageWindow = 0.1,
    windowSamples = {},
    averagedSamples = {},
    roughWindows = 0,
    maxPullTime = 45,
    finishDelay = 0.4,
    minAcceptedSamples = 8,
    startBuffer = 0.2,
    tailBuffer = 0.15,
    pendingSamples = {},
    rawSamples = {},
    lastAcceptedRpm = nil,
    lastAcceptedPower = nil,
    lastAcceptedTorque = nil,
    acceptedSampleCount = 0,
    rejectedSampleCount = 0,
    bins = {},
    qualityFlags = {},
    lastSample = nil
  }

  controller.setFreeze(0)
end

-- Public API -----------------------------------------------------------------------------------------
M.startPull = startPull
M.abortPull = abortPull

-- Game hooks --------------------------------------------------------------------------------------

M.onPhysicsStep = onPhysicsStep
M.onReset = abortPull
M.onExtensionUnloaded = function()
  unloading = true
  abortPull()
end

return M
