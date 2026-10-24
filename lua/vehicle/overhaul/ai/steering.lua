-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this file,
-- You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding

-- Vehicle controls, obstacle raycasts and derby recovery steering.
-- create binds this extension instance; require caches only the factory.

-- Map, in reading order:
--   driveCar: wheel and pedal output
--   raycasts: populateOBBinRange and castRay (exported)
--   grip control: understeer, oversteer, wheel-slip and combined coefficients
--   turnaround: scanTurnaroundClearance and driveTurnaround
--   driveAlongTarget and driveToTarget (exported)

local lib = {}

function lib.create(ctx)
  -- Locals for speed: this file runs every AI frame.
  local max, min, abs, sqrt, floor, asin = math.max, math.min, math.abs, math.sqrt, math.floor, math.asin
  local square, getTmpVec3 = ctx.square, ctx.getTmpVec3
  local gravity = ctx.g

  local function driveCar(steering, throttle, brake, parkingbrake)
    input.event("steering", steering, "FILTER_AI", nil, nil, nil, "ai")
    input.event("throttle", throttle, "FILTER_AI", nil, nil, nil, "ai")
    input.event("brake", brake, "FILTER_AI", nil, nil, nil, "ai")
    input.event("parkingbrake", parkingbrake, "FILTER_AI", nil, nil, nil, "ai")

    ctx.lastCommand.steering = steering
    ctx.lastCommand.throttle = throttle
    ctx.lastCommand.brake = brake
    ctx.lastCommand.parkingbrake = parkingbrake
  end

  -- Derby escape state survives regular route resets and event retargets.
  ctx.internalState.derby.beginRecovery = function(reason)
    if ctx.internalState.derby.recoveryTimer > 0 or ctx.internalState.derby.recoveryCooldown > 0 then return false end

    local previousDirection = ctx.internalState.derby.recoveryDirection
    ctx.internalState.derby.recoveryAttempts = min((ctx.internalState.derby.recoveryAttempts or 0) + 1, 4)
    ctx.internalState.derby.recoveryDuration = 1.35 + ctx.internalState.derby.recoveryAttempts * 0.3
    ctx.internalState.derby.recoveryTimer = ctx.internalState.derby.recoveryDuration
    ctx.internalState.derby.reason = reason or 'stuck'

    -- Alternate escape steering to avoid repeating the same attempt against a wall.
    local preferredDirection = (ctx.M.mode == 'demoderby_reverse'
      or ctx.lastCommand.brake > ctx.lastCommand.throttle) and 1 or -1
    ctx.internalState.derby.recoveryDirection = ctx.internalState.derby.recoveryAttempts > 1 and -previousDirection or preferredDirection
    local targetSide = 0
    if ctx.aiState.player and ctx.aiState.player.pos then
      local awayFromTarget = ctx.ego.pos - ctx.aiState.player.pos
      if awayFromTarget:squaredLength() > 1e-6 then
        awayFromTarget:normalize()
        targetSide = ctx.ego.rightVec:dot(awayFromTarget)
      end
    end
    local alternateSide = ctx.internalState.derby.recoveryAttempts % 2 == 0 and -1 or 1
    ctx.internalState.derby.recoverySteer = clamp(targetSide * 1.5 + alternateSide * 0.45, -1, 1)

    ctx.internalState.egoCannotMoveTime = 0
    ctx.internalState.egoForceGoFrontTime = 0
    ctx.internalState.crash.time = 0
    ctx.internalState.crash.maneuver = 0
    ctx.internalState.crash.pos:set(0, 0, 0)
    ctx.internalState.crash.dir:set(0, 0, 0)
    ctx.internalState.derby.crashObjID = -1

    obj:queueGameEngineLua(ctx.geCallback.command("onAiRecoveryRequest", objectId))
    return true
  end

  ctx.internalState.derby.checkCollision = function()
    if ctx.internalState.derby.recoveryTimer > 0 or ctx.internalState.derby.recoveryCooldown > 0 then return end
    mapmgr.getObjects()
    local selfObj = mapmgr.objects[objectId]
    if not selfObj or not selfObj.objectCollisions then return end

    for id, collisionState in pairs(selfObj.objectCollisions) do
      local candidate = mapmgr.objects[id]
      if collisionState == 1 and id ~= objectId and candidate and candidate.active == true then
        ctx.internalState.derby.crashObjID = id
        ctx.internalState.derby.beginRecovery('impact')
        return
      end
    end
  end

  local function populateOBBinRange(range)
    range = range * range
    local i = 0
    for id in pairs(mapmgr.getObjects()) do
      if id ~= objectId then
        local pos = obj:getObjectCenterPosition(id)
        if pos:squaredDistance(ctx.ego.pos) < range then
          ctx.twt.OBBinRange[i+1] = pos

          -- Get bounding box direction vectors
          ctx.twt.OBBinRange[i+2] = obj:getObjectDirectionVector(id) -- x
          ctx.twt.OBBinRange[i+4] = obj:getObjectDirectionVectorUp(id) -- z
          ctx.twt.OBBinRange[i+3] = ctx.twt.OBBinRange[i+3] or vec3()
          ctx.twt.OBBinRange[i+3]:setCross(ctx.twt.OBBinRange[i+4], ctx.twt.OBBinRange[i+2]); ctx.twt.OBBinRange[i+3]:normalize() -- y (left)

          -- Scale bounding box direction vectors to vehicle diamensions
          ctx.twt.OBBinRange[i+3]:setScaled(obj:getObjectInitialWidth(id) * 0.5)
          ctx.twt.OBBinRange[i+2]:setScaled(obj:getObjectInitialLength(id) * 0.5)
          ctx.twt.OBBinRange[i+4]:setScaled(obj:getObjectInitialHeight(id) * 0.5)
          i = i + 4
        end
      end
    end
    ctx.twt.OBBinRange.n = i
  end

  local function castRay(rpos, rdir, rayDist)
    for i = 1, ctx.twt.OBBinRange.n, 4 do
      local minHit, maxHit = intersectsRay_OBB(rpos, rdir, ctx.twt.OBBinRange[i], ctx.twt.OBBinRange[i+1], ctx.twt.OBBinRange[i+2], ctx.twt.OBBinRange[i+3])
      if maxHit > 0 then
        rayDist = min(rayDist, max(minHit, 0))
      end
    end
    return obj:castRayStatic(rpos, rdir, rayDist)
  end

  local function applyDerbyRecoveryControls(throttle, brake, derbyState, pbrake, coef, dirTarget, dirDiff, crash)
    ctx.internalState.egoForceGoFrontTime = max(0, ctx.internalState.egoForceGoFrontTime - ctx.aiState.dt)

    if not derbyState.crashes then derbyState.crashes = 1 end
    if derbyState.crashes > 3 then
      derbyState.crashes = 1
    end

    if ctx.internalState.egoCannotMoveTime > derbyState.crashes and ctx.internalState.egoForceGoFrontTime == 0 or crash.time > 8 then
      ctx.internalState.egoForceGoFrontTime = 5
      derbyState.crashes = derbyState.crashes + 1
    end

    if ctx.internalState.egoForceGoFrontTime > 0 then
      if dirTarget > 0 then
        dirTarget = -dirTarget
      else
        dirTarget = abs(dirTarget)
      end
      crash.time = 0
      ctx.internalState.egoCannotMoveTime = 0
    end

    if dirTarget < -.75 or ctx.ego.speed < 3 and dirTarget <= 0 then
        brake = throttle
        throttle = 0
    elseif dirTarget > .85 or ctx.ego.speed < 3 and dirTarget >= 0 then
        throttle = throttle
        brake = 0
    else
        if ctx.ego.speed < 3 then
          if dirTarget > 0 then
            throttle = 0.4
            brake = 0
          else
            throttle = 0
            brake = 0.35
          end
        elseif dirTarget > 0 then
          throttle = 0
          brake = 0
        else
          brake = 0
          throttle = 0
        end
    end

    driveCar(-dirDiff, throttle * coef, brake * coef, pbrake)
    return throttle, brake, dirTarget
  end

  local function applyDerbySteeringAndSlipControls(throttle, brake, coef, absAiSpeed)
    if absAiSpeed > 0.2 then
      local avgWheelSpeed = 0
      local wheelCount = 0
      local minAbsWheelSpeed = math.huge
      local maxAbsWheelSpeed = 0
      local lwheels = wheels.wheels
      if lwheels then
        for i = 0, tableSizeC(lwheels) - 1 do
          local wheel = lwheels[i]
          if not wheel.isBroken then
            wheelCount = wheelCount + wheel.isSpeedo
            local absWheelVel = abs(wheel.angularVelocity * wheel.radius)
            avgWheelSpeed = avgWheelSpeed + absWheelVel * wheel.isSpeedo
            if wheel.brakeTorque > 0 then
              minAbsWheelSpeed = min(minAbsWheelSpeed, absWheelVel)
            end
            if wheel.isPropulsed then
              maxAbsWheelSpeed = max(maxAbsWheelSpeed, absWheelVel)
            end
          end
        end
      end

      -- manual abs and tcs
      if wheelCount > 0 then
        local latVgrad = 0.5 * ctx.ego.width * abs(sensors.gx2) / (ctx.ego.speed + 1e-30)
        avgWheelSpeed = avgWheelSpeed / wheelCount

        -- abs
        local minGradSpeed = absAiSpeed - latVgrad
        if avgWheelSpeed < minGradSpeed and brake > 0 then
          coef = coef * minAbsWheelSpeed / (minGradSpeed + 1e-30)
        end

        -- tcs
        local maxGradSpeed = max(3, absAiSpeed + latVgrad)
        if maxAbsWheelSpeed > maxGradSpeed and throttle > 0 then
          local redcoef = maxGradSpeed / maxAbsWheelSpeed
          coef = coef * redcoef * redcoef
        end
      end
    end
    return coef
  end

  local function chooseDerbyDriveDirection(throttle, brake, derbyState, ahead, pbrake, coef, ahead2)
    ahead = ctx.ego.dirVec * (-ctx.ego.length) + ctx.ego.pos
    local targetVec = ahead - ahead2; targetVec:normalize()
    local dirTarget = ctx.ego.dirVec:dot(targetVec)
    targetVec = -targetVec
    dirTarget = -dirTarget

    local aheadTarget = ctx.ego.dirVec:dot(targetVec)
    local dirDiff = -asin(ctx.ego.dirVec:cross(ctx.ego.upVec):normalized():dot(targetVec))
    local dirAngle = asin(ctx.ego.rightVec:dot(targetVec))
    local dirVel = ctx.ego.vel:dot(ctx.ego.dirVec)
    local absAiSpeed = abs(dirVel)

    local crash = ctx.internalState.crash
    if crash.maneuver > 0 then
      local distFromCrash = ctx.ego.pos:distance(crash.pos)
      if distFromCrash > 8 then
        crash.maneuver = 0
        crash.pos:set(0, 0, 0)
        crash.time = 0
        derbyState.crashes = nil
        derbyState.crashObjID = -1
      else
        local crashTargetVec = (crash.pos - ahead):normalized()
        local crashTarget = crash.dir:dot(crashTargetVec)
        dirTarget = -crashTarget
        dirDiff = -asin(ctx.ego.dirVec:cross(vec3(obj:getDirectionVectorUp())):dot(crashTargetVec))
        throttle = min(max(0.2 + distFromCrash * 0.005, 0.3), 0.4)
      end
    else
      coef = applyDerbySteeringAndSlipControls(throttle, brake, coef, absAiSpeed)

      if ctx.ego.speed > 1 then
        local rightVel = ctx.ego.rightVec:dot(ctx.ego.vel)
        local rotVel = min(1, (ctx.ego.prevDirVec:projectToOriginPlane(ctx.ego.upVec):normalized() - ctx.ego.dirVec):length() * ctx.aiState.dt * 10000)
        coef = coef * max(0, 1 - abs(rightVel * ctx.ego.speed * 0.05) * min(1, dirAngle * dirAngle * ctx.ego.speed * 6) * rotVel)
        local dirPer = abs(dirDiff) / 1.55
        if dirPer > .70 then
          local temp = 1 - dirPer
          coef = min(max(temp, coef),1)
        end
      end
    end

    throttle, brake, dirTarget = applyDerbyRecoveryControls(
      throttle, brake, derbyState, pbrake, coef, dirTarget, dirDiff, crash
    )
    return throttle, brake, ahead, coef
  end

  ctx.internalState.derby.driveToTarget = function(targetPos, throttle, brake)
    if not targetPos then return end

    local derbyState = ctx.internalState.derby
    if derbyState.recoveryTimer > 0 then
      derbyState.recoveryTimer = max(0, derbyState.recoveryTimer - ctx.aiState.dt)
      local progress = derbyState.recoveryDuration > 0 and derbyState.recoveryTimer / derbyState.recoveryDuration or 0
      local effort = 0.50 + 0.20 * progress
      local steering = derbyState.recoverySteer

      if derbyState.recoveryDirection < 0 then
        driveCar(steering, 0, effort, 0)
      else
        driveCar(-steering, effort, 0, 0)
      end

      if derbyState.recoveryTimer <= 0 then
        derbyState.recoveryCooldown = 0.9
        derbyState.reason = nil
        ctx.internalState.egoCannotMoveTime = 0
      end
      return
    end

    local ahead
    local pbrake = 0
    local brakeCoef = 1
    local throttleCoef = 1
    local coef = 1
    local ahead2

    if ctx.aiState.player then
      ahead2 = ctx.aiState.player.pos + ctx.aiState.player.vel * ctx.aiState.dt
    else
      ahead2 = targetPos
    end

    throttle, brake, ahead, coef = chooseDerbyDriveDirection(throttle, brake, derbyState, ahead, pbrake, coef, ahead2)
  end

  local function oversteerThrottleCoefficient(egoRightTarget, dirAngle)
    local OVERSTEER_MIN_SPEED_MPS = 1
    -- oversteer
    local throttleOverCoef = 1
    if not (ctx.ego.speed > OVERSTEER_MIN_SPEED_MPS) then return throttleOverCoef end
    local rightVel = ctx.ego.rightVec:dot(ctx.ego.vel)
    if not (rightVel * egoRightTarget > 0) then return throttleOverCoef end
    local egoRotV = getTmpVec3(ctx.ego)
    egoRotV:setProjectToOriginPlane(ctx.ego.upVec, ctx.ego.prevDirVec); egoRotV:normalize()
    local rotVel = min(1, egoRotV:distance(ctx.ego.dirVec) * ctx.aiState.dt * 10000)
    throttleOverCoef = max(0, 1 - abs(rightVel * ctx.ego.speed * 0.05) * min(1, dirAngle * dirAngle * ctx.ego.speed * 6) * rotVel)
    return throttleOverCoef
  end

  local function understeerControlCoefficients(plan, dirVel, targetPos, absegoSpeed, dirAngle)
    local throttleUnderCoef = 1
    local brakeUnderCoef = 1

    if plan and plan[3] and dirVel > 3 then
      local p1, p2 = plan[1].pos, plan[2].pos
      local p2p1DirVec = getTmpVec3(ctx.ego); p2p1DirVec:setSub2(p2, p1); p2p1DirVec:normalize()

      local tp2 = (plan.targetSeg or 0) > 1 and targetPos or plan[3].pos
      local targetSide = (push3(tp2) - p2):dot(push3(p2p1DirVec):cross(ctx.ego.upVec))

      local outDeviation = ctx.egoDeviationSmoother:value() - plan.egoDeviation * sign(targetSide)
      outDeviation = sign(outDeviation) * min(1, abs(outDeviation))
      ctx.egoDeviationSmoother:set(outDeviation)
      ctx.egoDeviationSmoother:getUncapped(0, ctx.aiState.dt)

      if outDeviation > 0 and absegoSpeed > 3 then
        local steerCoef = outDeviation * absegoSpeed * absegoSpeed * min(1, dirAngle * dirAngle * 4)
        local understeerCoef = max(0, steerCoef) * min(1, abs(ctx.ego.vel:dot(p2p1DirVec) * 3))
        if ctx.opt.racing and ctx.aiState.parameters.raceCommitCorners ~= false then
          local slipMin = (type(ctx.aiState.parameters.raceUndersteerSlipMin) == 'number' and ctx.aiState.parameters.raceUndersteerSlipMin) or 1.05
          if ctx.aiState.raceCommit.maxPropWheelSlip() < slipMin then
            understeerCoef = 0
          end
        end
        local noUndersteerCoef = max(0, 1 - understeerCoef)
        -- Racing: when wide of centerline, do not lift as hard for "understeer" — keeps pace on alternate lines.
        if ctx.opt.racing and type(ctx.aiState.parameters.raceWideLineUndersteerRelax) == 'number' and ctx.aiState.parameters.raceWideLineUndersteerRelax > 0 and plan[plan.egoSeg or 1] and plan[(plan.egoSeg or 1) + 1] then
          local egoSegIdx = plan.egoSeg or 1
          local segStartPos, segEndPos = plan[egoSegIdx].pos, plan[egoSegIdx + 1].pos
          local egoXnorm = ctx.ego.pos:xnormOnLine(segStartPos, segEndPos)
          if egoXnorm < 0 then egoXnorm = 0 elseif egoXnorm > 1 then egoXnorm = 1 end
          local onL = segStartPos + (segEndPos - segStartPos) * egoXnorm
          local latMag = abs((ctx.ego.pos - onL):dot(plan[egoSegIdx].normal))
          local lat0 = (type(ctx.aiState.parameters.raceWideLineLateralStartM) == 'number' and ctx.aiState.parameters.raceWideLineLateralStartM) or 0.85
          local lat1 = (type(ctx.aiState.parameters.raceWideLineLateralEndM) == 'number' and ctx.aiState.parameters.raceWideLineLateralEndM) or 2.5
          if lat1 <= lat0 then lat1 = lat0 + 0.01 end
          local tWide = clamp((latMag - lat0) / (lat1 - lat0), 0, 1)
          local relax = tWide * clamp(ctx.aiState.parameters.raceWideLineUndersteerRelax, 0, 1)
          noUndersteerCoef = noUndersteerCoef + (1 - noUndersteerCoef) * relax
        end
        throttleUnderCoef = noUndersteerCoef
        if not (ctx.opt.racing and ctx.aiState.parameters.raceCommitCorners ~= false and understeerCoef == 0) then
          brakeUnderCoef = min(brakeUnderCoef, max(0, 1 - understeerCoef * understeerCoef))
        end
      end
    else
      ctx.egoDeviationSmoother:set(0)
    end
    return throttleUnderCoef, brakeUnderCoef
  end

  local function accumulateWheelSlipControl(
    absegoSpeed, throttleTcsCoef, brakeABSCoef, totalSlip, propSlip, totalDownForce
  )
    totalSlip = totalSlip / (totalDownForce + 1e-25)

    -- abs
    brakeABSCoef = min(1, 1.5 * square(square(square(max(0,
      absegoSpeed - totalSlip) / absegoSpeed))))

    -- tcs
    propSlip = propSlip * (ctx.aiState.parameters.driveStyle == 'offRoad' and 0.8 or 1)
    local tcsCoef
    if ctx.opt.racing then
      local stateBased = ctx.aiState.parameters.raceStateBasedTcs ~= false
      if stateBased then
        local slipTarget = (type(ctx.aiState.parameters.raceSlipTarget) == 'number' and ctx.aiState.parameters.raceSlipTarget) or 1.14
        local slipGain = (type(ctx.aiState.parameters.raceSlipGain) == 'number'
          and ctx.aiState.parameters.raceSlipGain) or 0.26
        if propSlip <= slipTarget then
          tcsCoef = 1
          ctx.smoothTcs:set(1)
          throttleTcsCoef = 1
        else
          local reduction = slipGain * (propSlip - slipTarget)
          tcsCoef = max(0, 1 - reduction)
          throttleTcsCoef = min(tcsCoef, ctx.smoothTcs:get(tcsCoef, ctx.aiState.dt))
        end
      else
        local slipThreshold = (type(ctx.aiState.parameters.raceSlipThreshold) == 'number' and ctx.aiState.parameters.raceSlipThreshold) or 1.0
        local slipGain = (type(ctx.aiState.parameters.raceSlipGain) == 'number'
          and ctx.aiState.parameters.raceSlipGain) or 0.2
        local maxReduction = (type(ctx.aiState.parameters.raceSlipMaxReduction) == 'number' and ctx.aiState.parameters.raceSlipMaxReduction) or 0.55
        if propSlip <= slipThreshold then
          tcsCoef = 1
          ctx.smoothTcs:set(1)
          throttleTcsCoef = 1
        else
          local reduction = min(maxReduction, slipGain * (propSlip - slipThreshold))
          tcsCoef = max(0, 1 - reduction)
          throttleTcsCoef = min(tcsCoef, ctx.smoothTcs:get(tcsCoef, ctx.aiState.dt))
        end
      end
    else
      tcsCoef = max(0.05, absegoSpeed - propSlip * propSlip) / absegoSpeed
      throttleTcsCoef = ctx.smoothTcs:get(tcsCoef, ctx.aiState.dt)
    end
    return throttleTcsCoef, brakeABSCoef, totalSlip, propSlip
  end

  local function wheelSlipControlCoefficients(absegoSpeed)
    local MIN_WHEEL_CONTROL_SPEED_MPS = 0.05
    local MIN_ABS_CONTROL_SPEED_MPS = 3
    -- wheel speed
    local throttleTcsCoef = 1
    local brakeABSCoef = 1
    if not (absegoSpeed > MIN_WHEEL_CONTROL_SPEED_MPS) then return throttleTcsCoef, brakeABSCoef end
    if sensors.gz <= 0.1 then
      local totalSlip = 0
      local propSlip = 0
      local totalDownForce = 0
      local lwheels = wheels.wheels
      for i = 0, tableSizeC(lwheels) - 1 do
        local wheel = lwheels[i]
        if not (not wheel.isBroken) then goto nextWheel end
        local lastSlip = wheel.lastSlip
        local downForce = wheel.downForceRaw
        totalSlip = totalSlip + lastSlip * downForce
        totalDownForce = totalDownForce + downForce
        if wheel.isPropulsed then
          propSlip = max(propSlip, lastSlip)
        end
        ::nextWheel::
      end

      absegoSpeed = max(absegoSpeed, MIN_ABS_CONTROL_SPEED_MPS)

      throttleTcsCoef, brakeABSCoef, totalSlip, propSlip = accumulateWheelSlipControl(
        absegoSpeed, throttleTcsCoef, brakeABSCoef, totalSlip, propSlip, totalDownForce
      )
    else
      brakeABSCoef = 0
      throttleTcsCoef = 0
    end
    return throttleTcsCoef, brakeABSCoef
  end

  local function combineGripControlCoefficients(brakeUnderCoef, brakeABSCoef, throttleOverCoef, throttleUnderCoef, throttleTcsCoef)
    local brakeCoef = 1
    if ctx.aiState.parameters.underSteerBrakeControl ~= 'off' then
      brakeCoef = min(brakeCoef, brakeUnderCoef)
    end
    if ctx.aiState.parameters.abBrakeControl ~= 'off' then
      brakeCoef = min(brakeCoef, brakeABSCoef)
    end

    local throttleCoef = 1
    if ctx.aiState.parameters.oversteerThrottleControl ~= 'off' then
      throttleCoef = min(throttleCoef, throttleOverCoef)
    end
    if ctx.aiState.parameters.understeerThrottleControl ~= 'off' then
      throttleCoef = min(throttleCoef, throttleUnderCoef)
    end
    if ctx.aiState.parameters.throttleTcs ~= 'off' then
      throttleCoef = min(throttleCoef, throttleTcsCoef)
    end
    -- Race: optional throttle floor from config only; state-based mode has no floor (throttle purely from slip/path).
    if not (ctx.opt.racing and type(ctx.aiState.parameters.raceThrottleFloor) == "number") then return brakeCoef, throttleCoef end
    local throttleFloor = ctx.aiState.parameters.raceThrottleFloor
    local hiSpd = ctx.aiState.parameters.raceHighSpeedThreshold
    if type(hiSpd) == "number" and ctx.ego.speed > hiSpd then
      throttleFloor = ctx.aiState.parameters.raceHighSpeedThrottleFloor or 0.7
    end
    if not (throttleTcsCoef >= throttleFloor) then return brakeCoef, throttleCoef end
    throttleCoef = max(throttleCoef, throttleFloor)
    return brakeCoef, throttleCoef
  end

  local function scanTurnaroundClearance()
    local CLEARANCE_RAYS_PER_SECOND = 150
    local MAX_CLEARANCE_RAYS_PER_FRAME = 8
    -- front right corner pos
    ctx.twt.posTable[2]:setAddScaled(ctx.ego.pos, ctx.ego.upVec, 0.35)
    ctx.twt.posTable[2]:setAddScaled(ctx.twt.posTable[2], ctx.ego.dirVec, -0.05 * ctx.ego.length)
    ctx.twt.posTable[2]:setAddScaled(ctx.twt.posTable[2], ctx.ego.rightVec, 0.5 * (0.7 * ctx.ego.width))

    -- front left corner pos
    ctx.twt.posTable[1]:setAddScaled(ctx.twt.posTable[2], ctx.ego.rightVec, -2 * 0.5 * (0.7 * ctx.ego.width))

    -- back right corner pos
    ctx.twt.posTable[3]:setAddScaled(ctx.twt.posTable[2], ctx.ego.dirVec, -0.9 * ctx.ego.length)

    -- back left corner pos
    ctx.twt.posTable[4]:setAddScaled(ctx.twt.posTable[1], ctx.ego.dirVec, -0.9 * ctx.ego.length)

    ctx.twt.dirTable[1]:setScaled2(ctx.ego.rightVec, -1)
    ctx.twt.dirTable[2]:set(ctx.ego.dirVec)
    ctx.twt.dirTable[3]:set(ctx.ego.rightVec)
    ctx.twt.dirTable[4]:setScaled2(ctx.ego.dirVec, -1)

    local rayDist = 4 * ctx.ego.wheelBase -- TODO: Optimize rayDist. Higher is better for more open spaces but w performance hit
    populateOBBinRange(rayDist)

    local sizeRatio = ctx.ego.length / ctx.ego.width
    local blueNoiseRange = 6 + 2 * sizeRatio

    local rayPoint = getTmpVec3(ctx.ego)
    local rayDir = getTmpVec3(ctx.ego)

    --the ray cast loop: each iteration scans one area and casts on the minimum
    local RRPicks = max(1, min(floor(CLEARANCE_RAYS_PER_SECOND * ctx.aiState.dt + 0.5), MAX_CLEARANCE_RAYS_PER_FRAME)) -- x * dt where x/fps is the numer of samples
    for k = 1, RRPicks do
      local i = 0
      local blueIndex = ctx.twt.blueNoiseRR * blueNoiseRange
      if blueIndex < 3 then
        i = floor(1 + blueIndex)
      elseif blueIndex < 6 then
        i = floor(1 + blueIndex) + 1
      elseif blueIndex < 6 + sizeRatio then
        i = 4
      else
        i = 8
      end

      local j = i * 4
      rayPoint:setLerp(ctx.twt.posTable[ctx.twt.RRT[j-3]], ctx.twt.posTable[ctx.twt.RRT[j-2]], ctx.twt.biasedCoefs[i])
      rayDir:setLerp(ctx.twt.dirTable[ctx.twt.RRT[j-1]], ctx.twt.dirTable[ctx.twt.RRT[j]], ctx.twt.biasedCoefs[i]) -- LERP corner direction
      rayDir:normalize()

      local rayLen = castRay(rayPoint, rayDir, min(ctx.twt.rayMins[i], rayDist))

      if ctx.twt.rayMins[i] > rayLen or rayLen == rayDist then
        ctx.twt.minRayCoefs[i] = ctx.twt.biasedCoefs[i]
        ctx.twt.rayMins[i] = rayLen
      else
        rayPoint:setLerp(ctx.twt.posTable[ctx.twt.RRT[j-3]], ctx.twt.posTable[ctx.twt.RRT[j-2]], ctx.twt.minRayCoefs[i])
        rayDir:setLerp(ctx.twt.dirTable[ctx.twt.RRT[j-1]], ctx.twt.dirTable[ctx.twt.RRT[j]], ctx.twt.minRayCoefs[i]) -- LERP corner direction
        rayDir:normalize()
        ctx.twt.rayMins[i] = castRay(rayPoint, rayDir, min(max(2 * ctx.twt.rayMins[i], 0.02), rayDist))
      end

      ctx.twt.blueNoiseRR = getBlueNoise1d(ctx.twt.blueNoiseRR)
      ctx.twt.blueNoiseCoefs[i] = getBlueNoise1d(ctx.twt.blueNoiseCoefs[i])
      local criticality = 2 * ctx.twt.rayMins[i] / (ctx.twt.rayMins[i] + rayDist) + 0.25
      ctx.twt.biasedCoefs[i] = biasGainFun(ctx.twt.blueNoiseCoefs[i], ctx.twt.minRayCoefs[i], criticality)
    end
  end

  local function advanceTurnaroundSampling(dirVel)
    local MIN_CLEARANCE_WAIT_S = 0.5
    local MAX_CLEARANCE_WAIT_FRAMES = 50
    local MAX_CLEARANCE_WAIT_S = 2.5
    ctx.twt.sampleCounter = ctx.twt.sampleCounter + 1
    if not (ctx.twt.state == 0) then return end
    if ctx.twt.sampleCounter * ctx.aiState.dt > max(MIN_CLEARANCE_WAIT_S, min(MAX_CLEARANCE_WAIT_FRAMES * ctx.aiState.dt, MAX_CLEARANCE_WAIT_S)) and ctx.ego.speed <= 0.5 then -- TODO: Optimize sample count condition
      ctx.twt.state = 1
    else
      local speed = max(0, ctx.ego.speed - 0.25)
      local throttle = max(0, -sign(speed * dirVel)) * 0.3
      local brake = max(0, sign(speed * dirVel)) * 0.3
      driveCar(0, throttle, brake, 0)
    end
  end

  local function applyTurnaroundClearanceControls(dirTarget, dirTargetAxis, minRayDist)
    if minRayDist == ctx.twt.rayMins[7] then
      ctx.twt.dirState[1] = 1
      ctx.twt.dirState[2] = sign2(dirTargetAxis)
      ctx.twt.minRay = "BL"
    elseif minRayDist == ctx.twt.rayMins[5] then
      ctx.twt.dirState[1] = 1
      ctx.twt.dirState[2] = sign2(dirTargetAxis)
      ctx.twt.minRay = "BR"
    elseif minRayDist == ctx.twt.rayMins[1] then
      ctx.twt.dirState[1] = -1
      ctx.twt.dirState[2] = -sign2(dirTargetAxis)
      ctx.twt.minRay = "FL"
      if ctx.twt.dirState[2] == 1 and ctx.twt.rayMins[8] < 0.4 and ctx.twt.targetSpeed < 0.6 then ctx.twt.dirState[2] = 0 end
    elseif minRayDist == ctx.twt.rayMins[3] then
      ctx.twt.dirState[1] = -1
      ctx.twt.dirState[2] = -sign2(dirTargetAxis)
      if ctx.twt.dirState[2] == -1 and ctx.twt.rayMins[4] < 0.4 and ctx.twt.targetSpeed < 0.6 then ctx.twt.dirState[2] = 0 end
      ctx.twt.minRay = "FR"
    elseif minRayDist == ctx.twt.rayMins[6] then
      ctx.twt.dirState[1] = 1
      ctx.twt.dirState[2] = sign2(dirTargetAxis)
      ctx.twt.minRay = "B"
    elseif minRayDist == min(ctx.twt.rayMins[4], ctx.twt.rayMins[8]) then
      local sideRuler = 0
      local minSide = minRayDist == ctx.twt.rayMins[8] and "L" or "R"
      if minSide == "L" then
        sideRuler = ctx.ego.length * (1 - ctx.twt.minRayCoefs[8])
      else
        sideRuler = ctx.ego.length * ctx.twt.minRayCoefs[4]
      end
      ctx.twt.dirState[2] = 0
      if sideRuler < ctx.twt.rayMins[6] and dirTarget < 0 then --TODO : test this
        ctx.twt.dirState[1] = -1
      elseif (ctx.ego.length - sideRuler) < ctx.twt.rayMins[2] then
        ctx.twt.dirState[1] = 1
        if minSide == "L" then
          ctx.twt.dirState[2] = 1
        else
          ctx.twt.dirState[2] = -1
        end
      end
      ctx.twt.minRay = "S"
    else
      ctx.twt.dirState[1] = -1
      ctx.twt.dirState[2] = -sign2(dirTargetAxis)
      ctx.twt.minRay = "F"
    end
  end

  local function driveTurnaround(dirTarget, dirTargetAxis, dirVel)
    if not (ctx.twt.state == 1) then return end
    if ctx.twt.targetSpeed < 0.66 or ctx.twt.minRay == "S" then -- TODO: Some branches may be consolidated
      local minRayDist = min(ctx.twt.rayMins[1], ctx.twt.rayMins[2], ctx.twt.rayMins[3], ctx.twt.rayMins[4], ctx.twt.rayMins[5], ctx.twt.rayMins[6], ctx.twt.rayMins[7], ctx.twt.rayMins[8])

      applyTurnaroundClearanceControls(dirTarget, dirTargetAxis, minRayDist)
    end

    local threshold = min(ctx.ego.speed - 0.1, 0.66)
    local dirCoef, minDist = 1, nil --TODO: what if car is trapped/sandwiched?
    if ctx.twt.dirState[1] == -1 then -- reverse
      dirCoef = min(1.2 - dirTarget, 1) -- dirTarget -> targetSpeed modulation
      if ctx.twt.dirState[2] == -1 then -- steer left
        minDist = min(ctx.twt.rayMins[4], ctx.twt.rayMins[6], ctx.twt.rayMins[7])
      elseif ctx.twt.dirState[2] == 1 then -- steer right
        minDist = min(ctx.twt.rayMins[5], ctx.twt.rayMins[6], ctx.twt.rayMins[8])
      else -- no steering
        minDist = ctx.twt.rayMins[6]
        if ctx.twt.minRay ~= "S" then
          threshold = ctx.twt.rayMins[2] -- possibly max(threshold, twt.rayMins[2])
        end
      end
    else -- forward
      if ctx.twt.dirState[2] == -1 then
        minDist = min(ctx.twt.rayMins[1], ctx.twt.rayMins[2], ctx.twt.rayMins[8])
      elseif ctx.twt.dirState[2] == 1 then
        minDist = min(ctx.twt.rayMins[2], ctx.twt.rayMins[3], ctx.twt.rayMins[4])
      else
        minDist = ctx.twt.rayMins[2]
      end
    end

    local targetSpeed = sqrt(2 * gravity * min(ctx.aiState.aggression, ctx.ego.staticFrictionCoef) * max(0, minDist - threshold) * dirCoef)
    local stateBasedRacing = ctx.opt.racing and ctx.aiState.parameters.raceStateBasedTcs ~= false
    local capMax = stateBasedRacing and 80 or (ctx.opt.racing and (ctx.aiState.parameters.raceObstacleSpeedCap or 12)
      or 6)
    local capAgg = stateBasedRacing and 80 or (ctx.opt.racing and (ctx.aiState.parameters.raceObstacleSpeedCapAgg
      or 10) or 6)
    local speedCap = ctx.opt.racing and min(capMax, ctx.aiState.aggression * capAgg) or min(6,
      ctx.aiState.aggression * 6)
    ctx.twt.targetSpeed = max(min(ctx.twt.speedSmoother:get(targetSpeed, ctx.aiState.dt), speedCap), 0.3)
    local speedDif = ctx.twt.targetSpeed - ctx.twt.dirState[1] * sign2(dirVel) * ctx.ego.speed
    local steering = ctx.twt.steerSmoother:get(ctx.twt.dirState[2], ctx.aiState.dt)
    local pbrake = 0 -- * clamp(sign2(0.83 + ego.upVec:dot(gravityDir)), 0, 1) -- >= 10 deg
    local throttle, brake = 0, 0
    if ctx.twt.dirState[1] == -1 then
      throttle = clamp(-speedDif * 0.4, 0, 0.4)
      brake = clamp(speedDif * 0.2, 0, 1)
    elseif ctx.twt.dirState[1] == 1 then
      throttle = clamp(speedDif * 0.2, 0, 1)
      brake = clamp(-speedDif * 0.4, 0, 0.4)
    end
    driveCar(steering, throttle, brake, pbrake)
  end

  local function driveAlongTarget(throttle, brake, targetSpeed, throttleCoef, brakeCoef, dirAngle)
    ctx.twt.reset()

    local pbrake
    if ctx.ego.vel:dot(ctx.ego.dirVec) < 0 and ctx.ego.speed > 0.1 then
      -- Use braking or the parking brake when reversing near a zero target speed.
      if ctx.ego.speed < 0.15 and targetSpeed <= 0.25 then
        pbrake = 1
      else
        pbrake = 0
      end
      throttle = throttle * throttleCoef
      brake = 0
    else
      if ctx.ego.speed < 0.15 and targetSpeed <= 0.25 then
        -- The stop handbrake condition can be unstable.
        pbrake = 1
      else
        pbrake = 0
      end
      throttle = throttle * throttleCoef
      brake = brake * brakeCoef
    end

    local aggSq = square(ctx.aiState.aggression + max(0, -(ctx.ego.dirVec:dot(ctx.gravityDir))))
    local stateBasedRacing = ctx.opt.racing and ctx.aiState.parameters.raceStateBasedThrottle ~= false
    local rateMult = ctx.opt.racing and ((type(ctx.aiState.parameters.raceThrottleRateMult) == 'number' and ctx.aiState.parameters.raceThrottleRateMult) or (stateBasedRacing and 4 or 2)) or 1
    if ctx.opt.racing and ctx.ego.speed < 1.5 and throttle > 0.8 then
      ctx.throttleSmoother:set(throttle)
    end
    local recoveryMult = 1
    if ctx.opt.racing and throttle > ctx.throttleSmoother:value() then
      recoveryMult = (type(ctx.aiState.parameters.raceThrottleRecoveryMult) == 'number' and ctx.aiState.parameters.raceThrottleRecoveryMult) or (stateBasedRacing and 2 or 1.45)
    end
    local rate = max(ctx.throttleSmoother[ctx.throttleSmoother:value() < throttle], 10 * aggSq * aggSq * rateMult * recoveryMult)
    throttle = ctx.throttleSmoother:getWithRateUncapped(throttle, ctx.aiState.dt, rate)

    driveCar(dirAngle, throttle, brake, pbrake)
  end

  local function driveToTarget(targetPos, throttle, brake, targetSpeed)
    if not targetPos then return end

    local plan = ctx.aiState.currentRoute and ctx.aiState.currentRoute.plan
    targetSpeed = targetSpeed or plan and plan.targetSpeed
    if not targetSpeed then return end
    local targetVec = getTmpVec3(ctx.ego); targetVec:setSub2(targetPos, ctx.ego.pos); targetVec:normalize()
    local egoRightTarget = ctx.ego.rightVec:dot(targetVec)
    local dirAngle = asin(egoRightTarget)

    local throttleOverCoef = oversteerThrottleCoefficient(egoRightTarget, dirAngle)

    local dirVel = ctx.ego.vel:dot(ctx.ego.dirVec)
    local absegoSpeed = abs(dirVel)
    local throttleUnderCoef, brakeUnderCoef = understeerControlCoefficients(plan, dirVel, targetPos, absegoSpeed, dirAngle)

    local throttleTcsCoef, brakeABSCoef = wheelSlipControlCoefficients(absegoSpeed)

    local brakeCoef, throttleCoef = combineGripControlCoefficients(brakeUnderCoef, brakeABSCoef, throttleOverCoef, throttleUnderCoef, throttleTcsCoef)

    local dirTarget = ctx.ego.dirVec:dot(targetVec)
    local dirTargetAxis = ctx.ego.rightVec:dot(targetVec)

    if ctx.internalState.crash.maneuver == 1 and dirTarget < ctx.ego.dirVec:dot(ctx.internalState.crash.dir) then
      driveCar(-sign(dirAngle), brake * brakeCoef, throttle * throttleCoef, 0)
      return
    else
      ctx.internalState.crash.maneuver = 0
    end

    if ctx.aiState.parameters.driveStyle == 'offRoad' then
      brakeCoef = 1
      throttleCoef = sqrt(throttleCoef)
    end

    ctx.internalState.egoForceGoFrontTime = max(0, ctx.internalState.egoForceGoFrontTime - ctx.aiState.dt)
    if ctx.twt.state == 1 and ctx.internalState.egoCannotMoveTime > 1 and ctx.internalState.egoForceGoFrontTime == 0 then
      ctx.twt.state = 0
      ctx.internalState.egoCannotMoveTime = 0
      ctx.internalState.egoForceGoFrontTime = 2
    end

    if ctx.internalState.egoForceGoFrontTime > 0 and dirTarget < 0 then
      dirTarget = -dirTarget
      dirAngle = -dirAngle
    end

    if ctx.aiState.currentRoute and (dirTarget < 0 or (ctx.twt.state == 1 and dirTarget < 0.866)) then   -- TODO: Improve entry condition when twt.state == 1
      scanTurnaroundClearance()
      advanceTurnaroundSampling(dirVel)
      driveTurnaround(dirTarget, dirTargetAxis, dirVel)
    else
      driveAlongTarget(throttle, brake, targetSpeed, throttleCoef, brakeCoef, dirAngle)
    end
  end

  return {
    driveCar = driveCar,
    populateOBBinRange = populateOBBinRange,
    castRay = castRay,
    driveToTarget = driveToTarget,
  }
end

return lib
