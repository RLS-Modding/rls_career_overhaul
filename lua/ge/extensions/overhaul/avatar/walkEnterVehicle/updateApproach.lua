-- Walking approach: collision escape, arrival, route movement and look statistics.
-- The entry steps read the same geometry and camera parts.
local M = {}

function M.new(inputs)
  local runtimeState = inputs.state
  local parts = inputs.parts

  local function advanceArrival(
    veh, unicycle, pos, standPos, vehLook,
    aftFactor, dist, liveSwingClearance, requiredSwingClearance, dt
  )
    if runtimeState.approach.phase == "approach" and runtimeState.approach.collisionEscapeTarget then
      local escape = (runtimeState.approach.collisionEscapeTarget - pos):z0()
      local escapeDistance = escape:length()
      runtimeState.approach.collisionEscapeT = (runtimeState.approach.collisionEscapeT or 0) + dt
      if escapeDistance <= 0.10 or runtimeState.approach.t > inputs.config.approachTimeoutS then
        runtimeState.approach.collisionEscapeTarget = nil
        runtimeState.approach.collisionEscapeT = 0
        runtimeState.approach.route = nil
        runtimeState.approach.routeIndex = 1
        runtimeState.approach.waypoint = nil
        runtimeState.approach.stallWindowT = 0
        runtimeState.approach.stallWindowPath = runtimeState.approach.pathLength
        parts.doors.clearExternalMove(unicycle)
      else
        escape:normalize()
        parts.camera.lookAtVehicle(pos, vehLook, dt)
        parts.doors.setExternalMove(unicycle, escape.x, escape.y, 0)
        return true
      end
    end

    -- Stop grinding against deformed or oversized collision meshes once a full stall window shows no progress.
    if runtimeState.approach.phase == "approach" then
      runtimeState.approach.stallWindowT = (runtimeState.approach.stallWindowT or 0) + dt
      if runtimeState.approach.stallWindowT >= inputs.config.stallWindowS then
        local walked = runtimeState.approach.pathLength - (runtimeState.approach.stallWindowPath or 0)
        runtimeState.approach.stallWindowT = 0
        runtimeState.approach.stallWindowPath = runtimeState.approach.pathLength
        if runtimeState.approach.t >= inputs.config.stallWindowS
          and walked < inputs.config.stallPathM
          and dist <= math.max(8, (runtimeState.approach.startDistance or dist) + 1) then
          runtimeState.approach.phase = "waitDoor"
          runtimeState.approach.arrived = true
          runtimeState.approach.reachAssist = true
          runtimeState.approach.reachAssistDistance = dist
          runtimeState.approach.reachAssistReason = "stalled"
          runtimeState.approach.arriveT = 0
          runtimeState.approach.standPos = vec3(pos)
          runtimeState.approach.boardTarget = parts.doors.getBoardTarget(veh, runtimeState.approach.boardDoorRef, aftFactor)
          parts.doors.clearExternalMove(unicycle)
        end
      end
    end

    if runtimeState.approach.phase == "approach" and dist <= inputs.config.arriveM
      and (not requiredSwingClearance or not liveSwingClearance
        or liveSwingClearance >= requiredSwingClearance) then
      runtimeState.approach.phase = "waitDoor"
      runtimeState.approach.arrived = true
      runtimeState.approach.arriveT = 0
      runtimeState.approach.standPos = standPos
      runtimeState.approach.boardTarget = parts.doors.getBoardTarget(veh, runtimeState.approach.boardDoorRef, aftFactor)
    end
  end

  local function applyApproachMotionAndTelemetry(unicycle, dist, dt, moveDir, actualLook, toVeh, clr, envelopeSource)
    local nearFactor = clamp(1 - dist / 7, 0, 1)
    nearFactor = nearFactor * nearFactor
    local vehBias = 0.55 + 0.35 * nearFactor
    local lookTarget = moveDir * (1 - vehBias) + toVeh * vehBias
    if lookTarget:length() < 1e-3 then lookTarget = toVeh else lookTarget:normalize() end
    runtimeState.approach.lookDir = parts.camera.smoothLookDir(runtimeState.approach.lookDir, lookTarget, dt)
    gameplay_walk.setRot(runtimeState.approach.lookDir, inputs.up)

    local approachSpeedCoef = runtimeState.approach.speedCoef or 0
    if dist < 1.6 then
      approachSpeedCoef = approachSpeedCoef * clamp((dist - inputs.config.arriveM) / (1.6 - inputs.config.arriveM), 0, 1)
    end
    parts.doors.setExternalMove(unicycle, moveDir.x, moveDir.y, approachSpeedCoef)

    if envelopeSource ~= "none" then
      runtimeState.approach.minClearance = math.min(runtimeState.approach.minClearance or math.huge, clr)
      runtimeState.approach.maxClearance = math.max(runtimeState.approach.maxClearance or -math.huge, clr)
      runtimeState.approach.insideHits = (runtimeState.approach.insideHits or 0) + (clr < 0 and 1 or 0)
    end

    local lookFlat = actualLook:z0()
    if lookFlat:length() > 1e-4 then lookFlat:normalize() else lookFlat = moveDir end
    local lookMoveDot = clamp(lookFlat:dot(moveDir), -1, 1)
    local lookVehDot = clamp(actualLook:dot(toVeh), -1, 1)
    if runtimeState.approach.t >= 0.3 then
      runtimeState.approach.lookMoveDotSum = runtimeState.approach.lookMoveDotSum + lookMoveDot
      runtimeState.approach.lookCarDotSum = runtimeState.approach.lookCarDotSum + lookVehDot
      runtimeState.approach.lookSamples = runtimeState.approach.lookSamples + 1
      runtimeState.approach.minLookMoveDot = math.min(runtimeState.approach.minLookMoveDot, lookMoveDot)
      local lookTurn = parts.doors.angleDeg(runtimeState.approach.prevActualLook, actualLook) or 0
      runtimeState.approach.totalLookTurnDeg = runtimeState.approach.totalLookTurnDeg + lookTurn
      runtimeState.approach.maxLookRateDeg = math.max(runtimeState.approach.maxLookRateDeg, lookTurn / math.max(dt, 1e-4))
      runtimeState.approach.maxCameraTargetErrorDeg = math.max(
        runtimeState.approach.maxCameraTargetErrorDeg,
        parts.doors.angleDeg(actualLook, runtimeState.approach.lookDir) or 0
      )
    end
    runtimeState.approach.prevActualLook = vec3(actualLook)
  end

  local function observeApproachMotionAndClearance(veh, unicycle, pos, vehLook, doorCenter, dist, moveDir)
    local vel = unicycle:getVelocity()
    local speed = math.sqrt(vel.x * vel.x + vel.y * vel.y)
    if speed < 15 then
      runtimeState.approach.speedSum = runtimeState.approach.speedSum + speed
      runtimeState.approach.speedSamples = runtimeState.approach.speedSamples + 1
      runtimeState.approach.maxSpeed = math.max(runtimeState.approach.maxSpeed, speed)
    end

    local lookOrigin = parts.camera.getLookOrigin(pos)
    local focusPos = vehLook
    local liveDoorLook = parts.doors.getDoorLookPos(veh, doorCenter or runtimeState.approach.doorCenter)
    if focusPos and liveDoorLook then
      local doorFocus = parts.doors.smoothstep01(clamp(1 - dist / 8, 0, 1))
      focusPos = focusPos * (1 - doorFocus) + liveDoorLook * doorFocus
    end
    local toVeh = focusPos and (focusPos - lookOrigin) or nil
    if toVeh and toVeh:length() > 1e-3 then
      toVeh:normalize()
    else
      toVeh = moveDir
    end
    local clr, envelopeSource, collisionHull, collisionEnvelope = parts.paths.vehicleClearance2D(
      pos, runtimeState.approach.vehId, 0
    )
    parts.paths.noteCollisionEnvelope(runtimeState.approach, envelopeSource, collisionHull, collisionEnvelope)
    return liveDoorLook, toVeh, clr, envelopeSource
  end

  local function moveToDoor(veh, unicycle, pos, standPos, vehLook, doorCenter, aftFactor, dist, dt)
    if runtimeState.approach.t > inputs.config.approachTimeoutS then
      runtimeState.approach.phase = "waitDoor"
      runtimeState.approach.arrived = true
      runtimeState.approach.reachAssist = true
      runtimeState.approach.reachAssistDistance = dist
      runtimeState.approach.reachAssistReason = "timeoutGuarantee"
      runtimeState.approach.arriveT = 0
      runtimeState.approach.doorOpenElapsed = 0
      runtimeState.approach.standPos = vec3(pos)
      runtimeState.approach.boardTarget = parts.doors.getBoardTarget(veh, runtimeState.approach.boardDoorRef, aftFactor)
      parts.doors.clearExternalMove(unicycle)
      return
    end

    local target = parts.paths.getSteerTarget(pos, runtimeState.approach.standPos or standPos, runtimeState.approach.vehId)
    local toTarget = (target - pos):z0()
    if toTarget:length() < 1e-3 then
      toTarget = ((runtimeState.approach.standPos or standPos) - pos):z0()
    end
    if toTarget:length() < 1e-3 then
      runtimeState.approach.phase = "waitDoor"
      runtimeState.approach.arrived = true
      runtimeState.approach.arriveT = 0
      parts.doors.clearExternalMove(unicycle)
      parts.camera.lookAtVehicle(pos, vehLook, dt)
      return
    end
    local moveDir = toTarget:normalized()
    local actualLook = parts.camera.getCameraLookDir() or runtimeState.approach.lookDir or moveDir
    local liveDoorLook, toVeh, clr, envelopeSource = observeApproachMotionAndClearance(
      veh, unicycle, pos, vehLook, doorCenter, dist, moveDir
    )
    if envelopeSource ~= "none" and clr <= inputs.config.boardCollisionM and dist > inputs.config.arriveM then
      -- Escape a corner collision before opening the door; contact is not permission to board.
      local corrected = parts.paths.pushOutsideVehicle2D(
        pos, runtimeState.approach.vehId, inputs.config.routeMarginM + 0.16
      )
      runtimeState.approach.collisionRecoveryCount = (runtimeState.approach.collisionRecoveryCount or 0) + 1
      runtimeState.approach.collisionEscapeTarget = corrected
      runtimeState.approach.collisionEscapeT = 0
      runtimeState.approach.route = nil
      runtimeState.approach.routeIndex = 1
      runtimeState.approach.waypoint = corrected
      local escape = (corrected - pos):z0()
      if escape:length() > 1e-4 then
        escape:normalize()
        parts.doors.setExternalMove(unicycle, escape.x, escape.y, 0)
      else
        parts.doors.clearExternalMove(unicycle)
      end
      parts.camera.lookAtVehicle(pos, liveDoorLook or vehLook, dt)
      return
    end
    applyApproachMotionAndTelemetry(unicycle, dist, dt, moveDir, actualLook, toVeh, clr, envelopeSource)
  end

  return {
    advanceArrival = advanceArrival,
    moveToDoor = moveToDoor,
  }
end

return M
