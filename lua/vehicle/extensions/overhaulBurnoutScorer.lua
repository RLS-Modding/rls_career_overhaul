-- GE API: startSession(newOptions), stopSession(); summaries reply through onBurnoutTireWearUpdate.
-- Read session state, wheel scoring, summaries, frame updates and lifecycle hooks.
local calibratedGravityMS2 = 9.81
local M = {}
local geCallback = require('vehicle/overhaul/geCallback')

local abs = math.abs
local acos = math.acos
local max = math.max
local min = math.min
local sqrt = math.sqrt

local active = false
local runState = "idle"
local readyToStart = false
local stoppedTimer = 0
local options = {}
local wheelState = {}
local summaryTimer = 0
local warningTimer = 0
local sessionStartedAt = 0
local sessionStats = {}
local frameStats = {}
local previousForward = nil
local previousRightVelocity = 0
local previousDamage = 0

local SUMMARY_INTERVAL = 0.5
local WARNING_INTERVAL = 2.5
local STOPPED_SPEED_MPS = 0.35
local READY_STOP_SECONDS = 0.75
local START_SPEED_MPS = 0.85
local MAX_RUN_SECONDS = 60
local TIP_IN_WINDOW_SECONDS = 7
local DAMAGE_NOISE_THRESHOLD = 8
local DAMAGE_PENALTY_SCALE = 0.35
local TIRE_POP_BONUS = 1000

local function clamp(value, minValue, maxValue)
  value = tonumber(value) or 0
  if value < minValue then
    return minValue
  end
  if value > maxValue then
    return maxValue
  end
  return value
end

local function smoothstep(edge0, edge1, value)
  if edge0 == edge1 then
    return value >= edge1 and 1 or 0
  end
  local t = clamp((value - edge0) / (edge1 - edge0), 0, 1)
  return t * t * (3 - 2 * t)
end

local function getNumericValue(value, fallback)
  value = tonumber(value)
  if value == nil then
    return fallback or 0
  end
  return value
end

local function length3(x, y, z)
  return sqrt(x * x + y * y + z * z)
end

local function xyzFromVec(value)
  if not value then
    return nil
  end
  if type(value.x) == "number" then
    return value.x, value.y or 0, value.z or 0
  end
  if type(value) == "table" then
    return tonumber(value[1]) or 0, tonumber(value[2]) or 0, tonumber(value[3]) or 0
  end
  return nil
end

local function dot3(ax, ay, az, bx, by, bz)
  return ax * bx + ay * by + az * bz
end

local function getVehicleVelocity()
  local ok, velocity = pcall(function()
    return obj:getVelocity()
  end)
  if ok and velocity then
    return velocity
  end
  return nil
end

local function getVehicleSpeed()
  local velocity = getVehicleVelocity()
  if velocity and type(velocity.length) == "function" then
    return velocity:length()
  end

  local speed = tonumber(electrics and electrics.values and electrics.values.airspeed) or nil
  if speed and speed >= 0 then
    return speed
  end

  return 0
end

local function startActiveRun()
  runState = "active"
  sessionStartedAt = 0
  sessionStats.elapsed = 0
  sessionStats.score = 0
  sessionStats.abuseSeconds = 0
  sessionStats.scoreBreakdown = nil
  previousForward = nil
  previousRightVelocity = 0
  previousDamage = getNumericValue(beamstate and beamstate.damage)
  summaryTimer = SUMMARY_INTERVAL
end

local function getDirectionVector(methodName)
  local ok, value = pcall(function()
    return obj[methodName](obj)
  end)
  if ok then
    return value
  end
  return nil
end

local function getRpmFactor()
  local values = electrics and electrics.values or {}
  local rpm = tonumber(values.rpm or values.rpmTacho or values.rpmspin)
  local maxRpm = tonumber(values.maxrpm or values.maxRPM or values.redlineRPM)
  if rpm and maxRpm and maxRpm > 0 then
    return clamp((rpm / maxRpm - 0.35) / 0.5, 0, 1.35)
  end

  if powertrain and powertrain.getDevicesByCategory then
    local engines = powertrain.getDevicesByCategory("engine") or {}
    local engine = powertrain.getDevice and powertrain.getDevice("mainEngine") or engines[1] -- [1] is pairs()-ordered on hybrids
    if engine then
      local currentAV = max(abs(getNumericValue(engine.outputAV1 or engine.inputAV or engine.outputAV2)), 0)
      local redlineAV = max(getNumericValue(engine.maxAV, 1), 1)
      return clamp((currentAV / redlineAV - 0.35) / 0.5, 0, 1.35)
    end
  end

  return 0
end

local function getWheelCollection()
  if wheels and wheels.wheels then
    return wheels.wheels, tableSizeC(wheels.wheels)
  end
  if v and v.data and v.data.wheels then
    return v.data.wheels, tableSize(v.data.wheels)
  end
  return nil, 0
end

local function getWheelName(index, wheel)
  if wheel and wheel.name then
    return wheel.name
  end
  if v and v.data and v.data.wheels then
    local dataWheel = v.data.wheels[index] or v.data.wheels[index + 1]
    if dataWheel and dataWheel.name then
      return dataWheel.name
    end
  end
  return "wheel_" .. tostring(index)
end

local function isWheelCurrentlyPopped(wheel)
  return wheel ~= nil and (wheel.isBroken == true or wheel.isTireDeflated == true)
end

local function ensureWheelState(index, wheel)
  local state = wheelState[index]
  if not state then
    local initiallyPopped = wheel and (wheel.isBroken == true or wheel.isTireDeflated == true) or false
    state = {
      index = index,
      name = getWheelName(index, wheel),
      popped = initiallyPopped,
      -- A tire that was already gone when staging began is not a competition pop
      popBonusAwarded = initiallyPopped,
      driven = wheel and wheel.isPropulsed == true,
    }
    wheelState[index] = state
  elseif wheel and wheel.isPropulsed == true then
    -- Keep the wheel's driven identity after it deflates or breaks. 
    state.driven = true
  end
  return state
end

local function resetFrameStats()
  frameStats = {
    activeWheelCount = 0,
    currentAbuse = 0,
    totalSlipSeverity = 0,
    maxSlipSeverity = 0,
    smoke = 0,
    wheelSpeed = 0,
    wheelSpeedFactor = 0
  }
end

local function getWheelByIndex(wheelCollection, index)
  return wheelCollection[index] or wheelCollection[index + 1]
end

local function isWheelContacting(wheel)
  if not wheel then
    return false
  end
  -- No contact is reported as -1, and the previous contact node stays cached.
  if (tonumber(wheel.contactMaterialID1) or -1) >= 0 or (tonumber(wheel.contactMaterialID2) or -1) >= 0 then
    return true
  end
  if (tonumber(wheel.downForce) or 0) > 50 then
    return true
  end
  return false
end

local function getThrottle()
  return clamp((electrics and electrics.values and electrics.values.throttle) or 0, 0, 1)
end

local function getSlipSeverity(wheel)
  local lastSlip = abs(tonumber(wheel and wheel.lastSlip) or 0)
  return clamp((lastSlip - 1.8) / 8.0, 0, 1.5)
end

local function getLoadFactor(wheel)
  local downForce = tonumber(wheel and wheel.downForce) or 3500
  return clamp(downForce / 4500, 0.35, 1.8)
end

local function getPressureFactor(wheel)
  local pressure = tonumber(wheel and (wheel.pressure or wheel.pressurePSI))
  if not pressure or pressure <= 0 then
    return 1
  end
  return clamp(30 / pressure, 0.85, 1.45)
end

local function getMovingScoreFactor(speedMps)
  return smoothstep(1.5, 8, speedMps)
end

local function getFlowSpeedFactor(speedMps)
  return smoothstep(0.9, 24, speedMps)
end

local function getWheelSpeedFactor(wheel, slipSeverity, speedMps)
  local wheelAV = abs(tonumber(wheel and (wheel.angularVelocity or wheel.wheelAngularVelocity or wheel.wheelSpeed or wheel.speed)) or 0)
  if wheelAV > 0 then
    return clamp(wheelAV / 85, 0, 1.5)
  end

  local slipWheelProxy = slipSeverity * 0.65 + clamp(speedMps / 28, 0, 0.85)
  return clamp(slipWheelProxy, 0, 1.5)
end

local function shouldUpdateWheel(wheel, speedMps, throttle, slipSeverity)
  if not active then
    return false
  end
  if runState ~= "active" then
    return false
  end
  if not playerInfo or playerInfo.firstPlayerSeated ~= true then
    return false
  end
  if not wheel or wheel.isBroken then
    return false
  end
  if not isWheelContacting(wheel) then
    return false
  end
  if throttle <= 0.35 then
    return false
  end
  if slipSeverity <= 0 then
    return false
  end
  return true
end

local function hasStartAbuse(wheelCollection, wheelCount, throttle)
  if throttle <= 0.35 then
    return false
  end

  for index = 0, wheelCount - 1 do
    local wheel = getWheelByIndex(wheelCollection, index)
    if wheel and not wheel.isBroken and isWheelContacting(wheel) and getSlipSeverity(wheel) > 0.1 then
      return true
    end
  end

  return false
end

local function calculateMotionMetrics(dt, speedMps)
  local yawRate = 0
  local lateralG = 0
  local forward = getDirectionVector("getDirectionVector")
  local right = getDirectionVector("getDirectionVectorRight")
  local velocity = getVehicleVelocity()
  local fx, fy, fz = xyzFromVec(forward)
  local rx, ry, rz = xyzFromVec(right)
  local vx, vy, vz = xyzFromVec(velocity)

  if fx and previousForward then
    local pfx, pfy, pfz = previousForward[1], previousForward[2], previousForward[3]
    local denom = max(length3(fx, fy, fz) * length3(pfx, pfy, pfz), 0.0001)
    local angle = acos(clamp(dot3(fx, fy, fz, pfx, pfy, pfz) / denom, -1, 1))
    yawRate = clamp(angle / max(dt, 0.001), 0, 6)
  end

  if fx then
    previousForward = {fx, fy, fz}
  end

  if rx and vx then
    local rightVelocity = dot3(vx, vy, vz, rx, ry, rz)
    lateralG = clamp(abs(rightVelocity - previousRightVelocity) / max(dt, 0.001) / calibratedGravityMS2, 0, 3)
    previousRightVelocity = rightVelocity
  elseif speedMps <= 0.2 then
    previousRightVelocity = 0
  end

  return yawRate, lateralG
end

local function getScoreBreakdown()
  sessionStats.scoreBreakdown = sessionStats.scoreBreakdown or {
    smoke = 0,
    wheelSpeed = 0,
    rpm = 0,
    aggression = 0,
    tipIn = 0,
    control = 0,
    movement = 0,
    popBonus = 0,
    penalties = 0
  }
  return sessionStats.scoreBreakdown
end

local function updateTotalScore()
  local breakdown = getScoreBreakdown()
  sessionStats.score = max(0,
    (breakdown.aggression or 0) +
    (breakdown.tipIn or 0) +
    (breakdown.movement or 0) +
    (breakdown.popBonus or 0) -
    (breakdown.penalties or 0))
end

local function stepWheel(index, wheel, dt, speedMps, throttle)
  local state = ensureWheelState(index, wheel)
  -- Latch pops only during an active run so a repaired tire can stage again.
  if runState == "active" then
    state.popped = isWheelCurrentlyPopped(wheel) or state.popped
  else
    state.popped = isWheelCurrentlyPopped(wheel)
  end
  if state.popped then
    return
  end

  local slipSeverity = getSlipSeverity(wheel)
  if shouldUpdateWheel(wheel, speedMps, throttle, slipSeverity) then
    local loadFactor = getLoadFactor(wheel)
    local speedFactor = clamp(1 - speedMps / 16, 0.15, 1)
    local pressureFactor = getPressureFactor(wheel)
    local drivenFactor = wheel.isPropulsed == true and 1 or 0.65
    local abuse = slipSeverity * loadFactor * throttle * speedFactor * pressureFactor * drivenFactor
    local wheelSpeedFactor = getWheelSpeedFactor(wheel, slipSeverity, speedMps)
    local smoke = abuse

    frameStats.activeWheelCount = frameStats.activeWheelCount + 1
    frameStats.currentAbuse = frameStats.currentAbuse + abuse
    frameStats.totalSlipSeverity = frameStats.totalSlipSeverity + slipSeverity
    frameStats.maxSlipSeverity = max(frameStats.maxSlipSeverity or 0, slipSeverity)
    frameStats.smoke = frameStats.smoke + smoke
    frameStats.wheelSpeed = frameStats.wheelSpeed + wheelSpeedFactor * throttle * drivenFactor * slipSeverity
    frameStats.wheelSpeedFactor = max(frameStats.wheelSpeedFactor or 0, wheelSpeedFactor)

  end
end

local function summarizeBurnoutWheels()
  local wheelsOut = {}
  local maxHeatValue = 0
  local maxWearValue = 0
  local poppedCount = 0
  local drivenWheelCount = 0
  local poppedDrivenCount = 0

  for index, state in pairs(wheelState) do
    if state.popped then
      poppedCount = poppedCount + 1
    end
    if state.driven == true then
      drivenWheelCount = drivenWheelCount + 1
      if state.popped then
        poppedDrivenCount = poppedDrivenCount + 1
      end
    end
    table.insert(wheelsOut, {
      index = index,
      name = state.name,
      heat = 0,
      wear = 0,
      integrity = state.popped and 0 or 1,
      popped = state.popped,
      driven = state.driven == true
    })
  end
  return wheelsOut, maxHeatValue, maxWearValue, poppedCount, drivenWheelCount, poppedDrivenCount
end

local function buildSummary()
  local wheelsOut, maxHeatValue, maxWearValue, poppedCount, drivenWheelCount, poppedDrivenCount = summarizeBurnoutWheels(
  )

  table.sort(wheelsOut, function(a, b)
    return (a.index or 0) < (b.index or 0)
  end)

  return {
    active = active,
    zoneId = options.zoneId,
    mode = options.mode,
    wheels = wheelsOut,
    runState = runState,
    readyToStart = readyToStart,
    speedMps = sessionStats.speedMps or 0,
    throttle = sessionStats.throttle or 0,
    elapsed = sessionStats.elapsed or 0,
    score = sessionStats.score or 0,
    scoreBreakdown = sessionStats.scoreBreakdown or {},
    abuseSeconds = sessionStats.abuseSeconds or 0,
    currentAbuse = sessionStats.currentAbuse or 0,
    activeWheelCount = sessionStats.activeWheelCount or 0,
    averageSlipSeverity = sessionStats.averageSlipSeverity or 0,
    maxSlipSeverity = sessionStats.maxSlipSeverity or 0,
    peakSlipSeverity = sessionStats.peakSlipSeverity or 0,
    rpmFactor = sessionStats.rpmFactor or 0,
    wheelSpeedFactor = sessionStats.wheelSpeedFactor or 0,
    yawRate = sessionStats.yawRate or 0,
    lateralG = sessionStats.lateralG or 0,
    damageDelta = sessionStats.damageDelta or 0,
    impactPenaltyCount = sessionStats.impactPenaltyCount or 0,
    maxHeat = maxHeatValue,
    maxWear = maxWearValue,
    poppedCount = poppedCount,
    drivenWheelCount = drivenWheelCount,
    poppedDrivenCount = poppedDrivenCount
  }
end

local function sendSummary()
  local vehId = obj:getID()
  if not vehId then
    return
  end

  local encoded = jsonEncode(buildSummary()):gsub("\\", "\\\\"):gsub("'", "\\'")
  obj:queueGameEngineLua(geCallback.command("onBurnoutTireWearUpdate", tostring(vehId) .. ", '" .. encoded .. "'"))
end

local function scoreWheelRotation(dt, wheelCollection, wheelCount, speedMps, throttle)
  for index = 0, wheelCount - 1 do
    local wheel = getWheelByIndex(wheelCollection, index)
    ensureWheelState(index, wheel)
    stepWheel(index, wheel, dt, speedMps, throttle)
  end

  sessionStats.currentAbuse = frameStats.currentAbuse or 0
  sessionStats.activeWheelCount = frameStats.activeWheelCount or 0
  sessionStats.maxSlipSeverity = frameStats.maxSlipSeverity or 0
  sessionStats.averageSlipSeverity = frameStats.activeWheelCount > 0 and
    (frameStats.totalSlipSeverity / frameStats.activeWheelCount) or 0
  sessionStats.peakSlipSeverity = max(sessionStats.peakSlipSeverity or 0, sessionStats.maxSlipSeverity or 0)
  sessionStats.wheelSpeedFactor = frameStats.wheelSpeedFactor or 0
  sessionStats.rpmFactor = getRpmFactor()
  sessionStats.yawRate, sessionStats.lateralG = calculateMotionMetrics(dt, speedMps)
  local maxRunSeconds = tonumber(options.maxRunSeconds)
  if not maxRunSeconds or maxRunSeconds <= 0 then
    maxRunSeconds = MAX_RUN_SECONDS
  end
  local previousElapsed = sessionStats.elapsed or 0
  sessionStats.elapsed = min(previousElapsed + dt, maxRunSeconds)
  local reachedRunLimit = previousElapsed < maxRunSeconds and sessionStats.elapsed >= maxRunSeconds

  if sessionStats.currentAbuse > 0 then
    sessionStats.abuseSeconds = (sessionStats.abuseSeconds or 0) + dt
    local multiWheelBonus = sessionStats.activeWheelCount >= 2 and 1.18 or 1
    local breakdown = getScoreBreakdown()
    local movingScoreFactor = getMovingScoreFactor(speedMps)
    local flowSpeedFactor = getFlowSpeedFactor(speedMps)
    local smokeRate = (frameStats.smoke or 0) * 5 * multiWheelBonus
    local wheelRate = (frameStats.wheelSpeed or 0) * 84 * multiWheelBonus * movingScoreFactor
    local rpmRate = sessionStats.rpmFactor * sessionStats.currentAbuse * 42 * movingScoreFactor
    local motionFactor = clamp(sessionStats.yawRate / 0.58 + sessionStats.lateralG / 0.28, 0, 3.4)
    local speedIntent = clamp(speedMps / 9, 0, 1.65)
    local tipInFactor = smoothstep(TIP_IN_WINDOW_SECONDS, 0, sessionStats.elapsed)
    local tipInRate = motionFactor * speedIntent * sessionStats.currentAbuse * throttle * 220 * tipInFactor
    local controlRate = sessionStats.currentAbuse > 0.12 and 16 * multiWheelBonus * movingScoreFactor or 0
    local aggressionRate = smokeRate + wheelRate + rpmRate + controlRate
    local movementRate = flowSpeedFactor * sessionStats.currentAbuse * throttle * 300

    breakdown.smoke = (breakdown.smoke or 0) + smokeRate * dt
    breakdown.wheelSpeed = (breakdown.wheelSpeed or 0) + wheelRate * dt
    breakdown.rpm = (breakdown.rpm or 0) + rpmRate * dt
    breakdown.aggression = (breakdown.aggression or 0) + aggressionRate * dt
    breakdown.tipIn = (breakdown.tipIn or 0) + tipInRate * dt
    breakdown.control = (breakdown.control or 0) + controlRate * dt
    breakdown.movement = (breakdown.movement or 0) + movementRate * dt
  end
  return reachedRunLimit
end

local function updateWheelGroundContact(dt, wheelCollection, wheelCount, speedMps, throttle)
  local reachedRunLimit = scoreWheelRotation(dt, wheelCollection, wheelCount, speedMps, throttle)

  local breakdown = getScoreBreakdown()
  for _, state in pairs(wheelState) do
    if state.popped == true and state.popBonusAwarded ~= true then
      state.popBonusAwarded = true
      breakdown.popBonus = (breakdown.popBonus or 0) + TIRE_POP_BONUS
    end
  end

  local currentDamage = getNumericValue(beamstate and beamstate.damage)
  local damageDelta = max(0, currentDamage - previousDamage)
  sessionStats.damageDelta = damageDelta
  if damageDelta > DAMAGE_NOISE_THRESHOLD then
    breakdown.penalties = (breakdown.penalties or 0) + damageDelta * DAMAGE_PENALTY_SCALE
    sessionStats.impactPenaltyCount = (sessionStats.impactPenaltyCount or 0) + 1
  end
  previousDamage = currentDamage
  updateTotalScore()

  summaryTimer = summaryTimer + dt
  warningTimer = warningTimer + dt
  if reachedRunLimit or summaryTimer >= SUMMARY_INTERVAL then
    summaryTimer = 0
    sendSummary()
  end
  if warningTimer >= WARNING_INTERVAL then
    warningTimer = 0
  end
end

local function updateGFX(dt)
  if not active then
    return
  end

  dt = min(max(tonumber(dt) or 0, 0), 0.1)
  local wheelCollection, wheelCount = getWheelCollection()
  if not wheelCollection or wheelCount <= 0 then
    return
  end

  local speedMps = getVehicleSpeed()
  local throttle = getThrottle()
  resetFrameStats()
  sessionStats.speedMps = speedMps
  sessionStats.throttle = throttle

  if runState == "staging" then
    if speedMps <= STOPPED_SPEED_MPS then
      stoppedTimer = stoppedTimer + dt
      if stoppedTimer >= READY_STOP_SECONDS then
        readyToStart = true
      end
      if readyToStart and hasStartAbuse(wheelCollection, wheelCount, throttle) then
        startActiveRun()
      end
    else
      if readyToStart and (speedMps >= START_SPEED_MPS or hasStartAbuse(wheelCollection, wheelCount, throttle)) then
        startActiveRun()
      else
        stoppedTimer = 0
      end
    end

    for index = 0, wheelCount - 1 do
      local wheel = getWheelByIndex(wheelCollection, index)
      local state = ensureWheelState(index, wheel)
      state.popped = isWheelCurrentlyPopped(wheel)
    end

    summaryTimer = summaryTimer + dt
    if summaryTimer >= SUMMARY_INTERVAL then
      summaryTimer = 0
      sendSummary()
    end
    return
  end

  updateWheelGroundContact(dt, wheelCollection, wheelCount, speedMps, throttle)
end

local function resetSession()
  active = false
  runState = "idle"
  readyToStart = false
  stoppedTimer = 0
  options = {}
  wheelState = {}
  summaryTimer = 0
  warningTimer = 0
  sessionStartedAt = 0
  sessionStats = {
    elapsed = 0,
    score = 0,
    scoreBreakdown = {
      smoke = 0,
      wheelSpeed = 0,
      rpm = 0,
      aggression = 0,
      tipIn = 0,
      control = 0,
      movement = 0,
      popBonus = 0,
      penalties = 0
    },
    abuseSeconds = 0,
    currentAbuse = 0,
    activeWheelCount = 0,
    averageSlipSeverity = 0,
    maxSlipSeverity = 0,
    peakSlipSeverity = 0,
    speedMps = 0,
    throttle = 0,
    rpmFactor = 0,
    wheelSpeedFactor = 0,
    yawRate = 0,
    lateralG = 0,
    damageDelta = 0,
    impactPenaltyCount = 0
  }
  previousForward = nil
  previousRightVelocity = 0
  previousDamage = getNumericValue(beamstate and beamstate.damage)
  resetFrameStats()
end

local function startSession(newOptions)
  resetSession()
  options = type(newOptions) == "table" and newOptions or {}
  options.mode = options.mode or "burnoutTest"
  active = true
  runState = options.runState or "staging"
  readyToStart = false
  stoppedTimer = 0
  sessionStartedAt = 0

  local wheelCollection, wheelCount = getWheelCollection()
  if wheelCollection then
    for index = 0, wheelCount - 1 do
      ensureWheelState(index, getWheelByIndex(wheelCollection, index))
    end
  end
  sendSummary()
end

local function stopSession()
  if not active then
    return
  end
  if runState == "active" then
    sessionStats.elapsed = sessionStats.elapsed or 0
  end
  active = false
  runState = "finished"
  sendSummary()
end

local function getSessionSummary()
  return buildSummary()
end

-- A reset repairs the tires: drop the run's pop latch (bonuses stay awarded) and the motion baselines.
local function onReset()
  for _, state in pairs(wheelState) do
    state.popped = false
  end
  previousForward = nil
  previousRightVelocity = 0
  previousDamage = getNumericValue(beamstate and beamstate.damage)
end

M.updateGFX = updateGFX
M.startSession = startSession
M.stopSession = stopSession
M.getSessionSummary = getSessionSummary
M.resetSession = resetSession
M.onReset = onReset

return M
