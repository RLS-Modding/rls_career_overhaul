-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this file,
-- You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Public settings, default parameters, racing corner commitment, telemetry and target selection.
-- create binds this extension instance; require caches only the factory.

local lib = {}

-- Racing corner commitment: speed floors, smoothing and corner-exit acceleration. The AI owner supplies live policy and telemetry.
local function buildRaceCommit(inputs)
  local raceCommit = {}

  raceCommit.boostPlanSpeeds = function(plan)
    if not (inputs.opt.racing and inputs.parameters.raceCommitCorners ~= false) or not plan then return end
    local mult = (type(inputs.parameters.raceCornerPlanBoost) == 'number' and inputs.parameters.raceCornerPlanBoost) or 1.06
    if mult <= 1.001 then return end
    for i = 1, plan.planCount do
      local n = plan[i]
      if n and type(n.speed) == 'number' and n.speed > 0 and n.speed < 500 then
        n.speed = n.speed * mult
      end
    end
  end

  raceCommit.applySpeedFloor = function(rawTS)
    if not (inputs.opt.racing and inputs.parameters.raceCommitCorners ~= false) then
      return rawTS
    end
    if inputs.ego.speed > 6 and inputs.maxPropWheelSlip() < 0.92 then
      local floorPct = (type(inputs.parameters.raceCommitSpeedFloorPct) == 'number' and inputs.parameters.raceCommitSpeedFloorPct) or 0.98
      rawTS = math.max(rawTS, inputs.ego.speed * floorPct)
    end
    return rawTS
  end

  raceCommit.smoothPlanTargetSpeed = function(rawTS, dt)
    if not (inputs.opt.racing and inputs.parameters.raceCommitCorners ~= false) then
      return inputs.targetSpeedSmoother:get(rawTS, dt)
    end
    local prev = inputs.targetSpeedSmoother:value()
    local baseRate = (type(inputs.parameters.targetSpeedSmootherRate) == 'number' and inputs.parameters.targetSpeedSmootherRate) or 14
    local rate = rawTS > prev and (baseRate * 0.3) or (baseRate * 4.2)
    return inputs.targetSpeedSmoother:getWithRate(rawTS, dt, rate)
  end

  raceCommit.applyCornerExitPush = function(targetSpeed, plan, dt)
    if not (inputs.opt.racing and inputs.parameters.raceCornerExitPush ~= false and plan and plan.originaltargetSpeed and plan[1] and plan[2]) then return targetSpeed end
    if type(targetSpeed) ~= 'number' or type(plan.originaltargetSpeed) ~= 'number' then return targetSpeed end
    if type(plan.trafficTargetSpeed) == 'number' and plan.trafficTargetSpeed < plan.originaltargetSpeed then return targetSpeed end
    local s1, s2 = plan[1].speed, plan[2].speed
    if type(s1) ~= 'number' or type(s2) ~= 'number' then return targetSpeed end
    local minGain = (type(inputs.parameters.raceCornerExitPushMinGain) == 'number' and inputs.parameters.raceCornerExitPushMinGain) or 0.8
    if s2 <= s1 + minGain then return targetSpeed end
    local slipMax = (type(inputs.parameters.raceCornerExitPushSlipMax) == 'number' and inputs.parameters.raceCornerExitPushSlipMax > 0) and inputs.parameters.raceCornerExitPushSlipMax or 0.92
    if inputs.maxPropWheelSlip() >= slipMax or sensors.gz > 0.15 then return targetSpeed end
    local overshoot = (type(inputs.parameters.raceCornerExitPushOvershoot) == 'number' and inputs.parameters.raceCornerExitPushOvershoot > 0) and inputs.parameters.raceCornerExitPushOvershoot or 1.03
    local capTS = math.min(s2, plan.originaltargetSpeed * overshoot)
    if inputs.ego.speed >= capTS - 0.4 or targetSpeed >= capTS - 0.2 then return targetSpeed end
    local rise = (type(inputs.parameters.raceCornerExitPushRiseRate) == 'number' and inputs.parameters.raceCornerExitPushRiseRate > 0) and inputs.parameters.raceCornerExitPushRiseRate or 18
    targetSpeed = math.min(capTS, targetSpeed + rise * dt)
    plan.targetSpeed = targetSpeed
    return targetSpeed
  end

  local function maxPropWheelSlip()
    local propSlip = 0
    local lwheels = wheels.wheels
    for i = 0, tableSizeC(lwheels) - 1 do
      local wheel = lwheels[i]
      if wheel and not wheel.isBroken and wheel.isPropulsed then
        propSlip = math.max(propSlip, wheel.lastSlip or 0)
      end
    end
    return propSlip
  end
  inputs.maxPropWheelSlip = maxPropWheelSlip

  local function racingPlannerAccelMult()
    if not inputs.opt.racing then return 1 end
    if inputs.parameters.raceCommitCorners == false then
      local accelScale = inputs.parameters.raceAccelScale
      return (type(accelScale) == 'number' and accelScale > 0) and accelScale or 1
    end
    local util = (type(inputs.parameters.raceCornerGripUtil) == 'number' and inputs.parameters.raceCornerGripUtil) or 1.32
    local extra = inputs.parameters.raceAccelScale
    if type(extra) == 'number' and extra > 0 then
      return util * extra
    end
    return util
  end

  return raceCommit, racingPlannerAccelMult, maxPropWheelSlip
end

function lib.create(ctx)
  -- Locals for speed: this file runs every AI frame.
  local max = math.max

  local dataLogger = {logData = nop}
  local function logDataTocsv()
    if not dataLogger.csvFile then
      log('I', 'overhaulAi', 'Started Logging Data')
      dataLogger.csvFile = require('csvlib').newCSV("time", "posX", "posY", "posZ", "speed", "targetSpeed", "ax", "ay", "az", "vx", "vy", "vz", "throttle", "brake", "steering", "staticFrictionCoef", "rpm")
      dataLogger.time = 0
    else
      dataLogger.time = dataLogger.time + ctx.aiState.dt
    end
    dataLogger.csvFile:add(
      dataLogger.time,
      ctx.ego.pos.x,
      ctx.ego.pos.y,
      ctx.ego.pos.z,
      ctx.ego.speed,
      ctx.aiState.currentRoute and ctx.aiState.currentRoute.plan and ctx.aiState.currentRoute.plan.targetSpeed,
      -sensors.gy,
      sensors.gx,
      sensors.gz,
      ctx.ego.vel:dot(ctx.ego.dirVec),
      -(ctx.ego.vel:dot(ctx.ego.rightVec)),
      ctx.ego.vel:dot(ctx.ego.upVec),
      ctx.lastCommand.throttle * 100,
      ctx.lastCommand.brake * 100,
      ctx.lastCommand.steering * 100,
      ctx.ego.staticFrictionCoef,
      electrics.values.rpm)
  end

  local function writeCsvFile(name)
    if dataLogger.csvFile then
      log('I', 'overhaulAi', 'Writing Data to CSV.')
      dataLogger.csvFile:write(name)
      dataLogger.csvFile = nil
      dataLogger.time = nil
      log('I', 'overhaulAi', 'Done')
    else
      log('I', 'overhaulAi', 'No data to write')
    end
  end

  local function startStopDataLog(name)
    if dataLogger.logData == nop then
      log('I', 'overhaulAi', 'Initialized Data Log')
      dataLogger.logData = logDataTocsv
      dataLogger.name = name
    else
      log('I', 'overhaulAi', 'Stopped Logging Data')
      dataLogger.logData = nop
      writeCsvFile(dataLogger.name or name)
      dataLogger.name = nil
    end
  end

  local function setGetObjectBoundingBox(center, x, y, z, id)
    center:set(obj:getObjectCenterPositionXYZ(id))
    x:set(obj:getObjectDirectionVectorXYZ(id))
    z:set(obj:getObjectDirectionVectorUpXYZ(id))
    y:setCross(z, x)
    y:setScaled(obj:getObjectInitialWidth(id) * 0.5 / max(y:length(), 1e-30))
    x:setScaled(obj:getObjectInitialLength(id) * 0.5)
    z:setScaled(obj:getObjectInitialHeight(id) * 0.5)
  end

  local function getObjectBoundingBox(id)
    local x = vec3()
    local y = vec3()
    local z = vec3()
    local center = vec3()
    setGetObjectBoundingBox(center, x, y, z, id)
    return center, x, y, z
  end

  local function aistatus(status, category)
    guihooks.trigger("AIStatusChange", {status=status, category=category})
  end

  local function getState()
    return ctx.M
  end

  local function stateChanged()
    if playerInfo.anyPlayerSeated then
      guihooks.trigger("AIStateChange", getState())
    end
  end

  local function setSpeed(speed)
    if type(speed) ~= 'number' then ctx.M.routeSpeed = nil else ctx.M.routeSpeed = speed end
  end

  local function setSpeedMode(speedMode)
    if speedMode == 'set' or speedMode == 'limit' or speedMode == 'legal' or speedMode == 'off' then
      ctx.M.speedMode = speedMode
    else
      ctx.M.speedMode = nil
    end
  end


  local function setAggressionInternal(aggression)
    ctx.aiState.aggression = aggression or ctx.M.extAggression
  end

  local function setAggressionExternal(aggression)
    ctx.M.extAggression = aggression or ctx.M.extAggression
    setAggressionInternal()
    stateChanged()
  end

  local function setAggressionMode(aggrmode)
    if aggrmode == 'rubberBand' then
      ctx.opt.aggressionMode = aggrmode
    else
      ctx.opt.aggressionMode = nil
      setAggressionInternal()
    end
  end

  local function resetAggression()
    setAggressionInternal()
  end

  local function resetInternalStates()
    ctx.trafficStates.block = {timer = 0, coef = 0, timerLimit = 6, block = false}
    ctx.trafficStates.side = {timer = 0, cTimer = 0, side = 1, displacement = 0, timerLimit = 6, passLen = 0, passMargin = 0}
    ctx.trafficStates.action = {hornTimer = -1, hornTimerLimit = 1, forcedStop = false}
    ctx.trafficStates.intersection = {timer = 0, turn = 0, block = false, legsStop = 0, legs = 0, interNode = nil}

    ctx.internalState.chaseData.playerState = nil
    ctx.internalState.chaseData.playerStoppedTimer = 0
    ctx.internalState.chaseData.playerRoad = nil
    ctx.internalState.chaseData.driveAhead = false
    ctx.internalState.chaseData.targetSpeed = nil

    ctx.internalState.crash.time = 0
    ctx.internalState.crash.maneuver = 0
    ctx.internalState.crash.dir:set(0, 0, 0)
    ctx.internalState.crash.pos:set(0, 0, 0)
    ctx.internalState.derby.crashObjID = -1

    ctx.internalState.derby.recoveryTimer = 0
    ctx.internalState.derby.recoveryDuration = 0
    ctx.internalState.derby.recoveryDirection = -1
    ctx.internalState.derby.recoverySteer = 0
    ctx.internalState.derby.recoveryCooldown = 0
    ctx.internalState.derby.recoveryAttempts = 0
    ctx.internalState.derby.reason = nil
    ctx.internalState.derby.crashes = nil

    if electrics.values.horn == 1 then electrics.horn(false) end
    if electrics.values.signal_left_input or electrics.values.signal_right_input then electrics.set_warn_signal(false) end

    ctx.aiState.trafficPathState = {}
  end
  resetInternalStates()

  local function resetParameters()
    -- parameters are used for finer AI control
    ctx.aiState.parameters = {
      turnForceCoef = 2, -- coefficient for curve spring forces
      awarenessForceCoef = 0.25, -- coefficient for vehicle awareness displacement
      edgeDist = 0, -- minimum distance from the edge of the road
      trafficWaitTime = 2, -- traffic delay after stopping at intersection
      enableElectrics = true, -- use electrics such as hazard lights (especially for traffic)
      driveStyle = 'default',
      staticFrictionCoefMult = 0.95,
      lookAheadKv = 0.6,
      minStTargetDist = 4.5,
      applyWidthMarginOffset = true,
      planErrorSmoothing = true,
      springForceIntegratorDispLim = 0.1, -- node displacement force magnitude limit
      understeerThrottleControl = 'on', -- anything other than an 'off' value will keep this active
      oversteerThrottleControl = 'on', -- anything other than an 'off' value will keep this active
      throttleTcs = 'on', -- anything other than an 'off' value will keep this active
      abBrakeControl = 'on',
      underSteerBrakeControl = 'on',
      throttleKp = 0.5,
      targetSpeedSmootherRate = 10,
      str = 1, -- time to reach segment given current speed
      -- Race parameters remain overridable when the event starts.
      stt = 0.5, -- time to traverse segment given current speed
      -- Racing / competitive: aggressive overtaking (see planRaceRouteAhead + alt plan selection).
      -- Defaults aligned with aiRacers post-.39 pass tuning (setParameters still wins at race GO).
      raceTrafficPassBlend = 0.78, -- 0..~0.85: recover this fraction of geometric vs traffic-capped target speed
      raceClearanceScaleMin = 0.26, -- lower = smaller effective rival OBB in racing (more overlap tolerance)
      raceAltPlanSpeedMargin = 6.5, -- larger = easier to commit to L/R offset plan on targetSpeed / traffic checks
      raceAltPlanTimeMargin = 3.8, -- larger = more path-length tolerance when choosing offset plan
      -- A blocked main plan permits an alternative with better lateral clearance or target speed.
      raceAwarenessCoefScale = 0.95, -- multiplies side displacement from rivals on racing line (lower = stay closer)
      -- When main plan has a blocker this far along (m), allow L/R if that side has more room or traffic target.
      raceBlockedAheadDistMax = 42,
      raceClearancePassMinGainM = 0.4, -- alt plan.distances must exceed main by at least this (m)
      raceClearancePassTrafficEps = 0.3, -- or alt trafficTargetSpeed exceeds main by this (m/s)
      -- Multiplies AI brake from speed error in racing (< 1 = softer corner / straight braking).
      raceBrakeGain = 0.82,
      raceCommitCorners = false,
      raceCornerGripUtil = 1.32,
      raceCornerPlanBoost = 1.06,
      raceStateBasedTcs = true,
      raceStateBasedThrottle = true,
      raceCornerExitPush = true,
      raceCornerExitPushMinGain = 0.8,
      raceCornerExitPushOvershoot = 1.03,
      raceCornerExitPushRiseRate = 18,
      raceCornerExitPushSlipMax = 0.92,
      raceUndersteerSlipMin = 1.05,
      raceSlipTarget = 1.14,
      raceSlipGain = 0.26,
      raceGripLiveRiseRate = 28,
      raceCommitSpeedFloorPct = 0.98,
      raceCommitTargetOvershoot = 1.08,
      raceFrictionMult = 1.06,
      -- Chase closing contact: minimum relative crash speed (m/s). Police sets this from wanted heat.
      chaseCrashSpeed = 10,
    }
    if ctx.aiState.raceCommit then ctx.aiState.raceCommit.ctx.parameters = ctx.aiState.parameters end
  end
  resetParameters()

  do
    local policyInputs = {
      opt = ctx.opt,
      parameters = ctx.aiState.parameters,
      ego = ctx.ego,
      targetSpeedSmoother = ctx.targetSpeedSmoother,
    }
    local raceCommit, plannerAccelMult, propWheelSlip = buildRaceCommit(policyInputs)
    ctx.aiState.raceCommit = raceCommit
    ctx.aiState.raceCommit.ctx = policyInputs
    ctx.aiState.raceCommit.plannerAccelMult = plannerAccelMult
    ctx.aiState.raceCommit.maxPropWheelSlip = propWheelSlip
  end

  local function setParameters(data)
    tableMerge(ctx.aiState.parameters, data)
  end

  local function dumpParameters()
    dump(ctx.aiState.parameters)
    dump('aggression = ', ctx.aiState.aggression)
  end
  ctx.M.dumpParameters = dumpParameters

  local function setTargetObjectID(id)
    ctx.M.targetObjectID = ctx.M.targetObjectID ~= objectId and id or -1
    if ctx.M.targetObjectID ~= -1 then ctx.aiState.targetObjectSelectionMode = 'manual' end
  end

  local function calculateWheelBase()
    local avgWheelNodePos, numOfWheels = vec3(), 0
    for _, wheel in pairs(wheels.wheels) do
      -- obj:getNodePosition is the pos vector of query node (wheel.node1) relative to ref node in world coordinates
      avgWheelNodePos:setAdd(obj:getNodePosition(wheel.node1))
      numOfWheels = numOfWheels + 1
    end
    if numOfWheels == 0 then return 0 end

    avgWheelNodePos:setScaled(1 / numOfWheels)

    local dirVec = obj:getDirectionVector()
    local avgFrontWheelPos, frontWheelCount = vec3(), 0
    local avgBackWheelPos, backWheelCount = vec3(), 0
    for _, wheel in pairs(wheels.wheels) do
      local wheelPos = obj:getNodePosition(wheel.node1)
      if wheelPos:dot(dirVec) > avgWheelNodePos:dot(dirVec) then
        avgFrontWheelPos:setAdd(wheelPos)
        frontWheelCount = frontWheelCount + 1
      else
        avgBackWheelPos:setAdd(wheelPos)
        backWheelCount = backWheelCount + 1
      end
    end

    avgFrontWheelPos:setScaled(1 / frontWheelCount)
    avgBackWheelPos:setScaled(1 / backWheelCount)

    return avgFrontWheelPos:distance(avgBackWheelPos)
  end

  local function updatePlayerData()
    mapmgr.getObjects()
    if not next(mapmgr.objects) then return end -- prevents changes if table is empty

    if mapmgr.objects[ctx.M.targetObjectID] and ctx.aiState.targetObjectSelectionMode == 'manual' then
      ctx.aiState.player = mapmgr.objects[ctx.M.targetObjectID]
    elseif tableSize(mapmgr.objects) == 2 then
      if ctx.aiState.player ~= nil then
        ctx.aiState.player = mapmgr.objects[ctx.aiState.player.id]
      else
        for k, mapObject in pairs(mapmgr.objects) do
          if k ~= objectId then
            ctx.M.targetObjectID = k
            ctx.aiState.player = mapObject
            break
          end
        end
        ctx.aiState.targetObjectSelectionMode = 'auto'
      end
    else
      if ctx.aiState.player ~= nil and ctx.aiState.player.active == true then
        ctx.aiState.player = mapmgr.objects[ctx.aiState.player.id]
      else
        for k, mapObject in pairs(mapmgr.objects) do
          if k ~= objectId and mapObject.active == true then
            ctx.M.targetObjectID = k
            ctx.aiState.player = mapObject
            break
          end
        end
        ctx.aiState.targetObjectSelectionMode = 'targetActive'
      end
    end
  end

  return {
    dataLogger = dataLogger,
    startStopDataLog = startStopDataLog,
    setGetObjectBoundingBox = setGetObjectBoundingBox,
    getObjectBoundingBox = getObjectBoundingBox,
    aistatus = aistatus,
    getState = getState,
    stateChanged = stateChanged,
    setSpeed = setSpeed,
    setSpeedMode = setSpeedMode,
    setAggressionInternal = setAggressionInternal,
    setAggressionExternal = setAggressionExternal,
    setAggressionMode = setAggressionMode,
    resetAggression = resetAggression,
    resetInternalStates = resetInternalStates,
    resetParameters = resetParameters,
    setParameters = setParameters,
    setTargetObjectID = setTargetObjectID,
    calculateWheelBase = calculateWheelBase,
    updatePlayerData = updatePlayerData,
  }
end

return lib
