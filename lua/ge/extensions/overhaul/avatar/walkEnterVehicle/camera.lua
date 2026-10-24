-- Walking and boarding camera movement, followed by driver-seat settling.
-- The owner shares inputs.boardingCamera so the entry steps use these same camera helpers.
local M = {}

function M.new(inputs)
  local runtimeState = inputs.state
  local parts = inputs.parts

  local function captureSpeedCoef(unicycle)
    -- Use a fixed brisk approach so sprint input cannot spoil precise doorway placement.
    return inputs.config.approachSpeedFraction
  end

  local function getCameraLookDir()
    local q = core_camera.getQuat()
    if not q then return nil end
    local dir = q * vec3(0, 1, 0)
    if dir:length() < 1e-4 then return nil end
    return dir:normalized()
  end

  local function getLookOrigin(fallbackPos)
    local camPos = core_camera.getPosition and core_camera.getPosition() or nil
    if camPos then return camPos end
    return (fallbackPos or vec3()) + vec3(0, 0, 1.6)
  end

  inputs.boardingCamera.getDriverWorldPos = function(veh, driverNodeId, passengerCameraName)
    if not veh then return nil end
    if passengerCameraName then
      local cameras = core_camera.getCameraDataById(veh:getId())
      local camera = cameras and cameras[passengerCameraName]
      local node = camera and camera.camNodeID ~= nil and veh:getNodePosition(camera.camNodeID)
      if not node then return nil end
      local target = veh:getPosition() + node
      local seat = camera.seatPosition
      local left, fwd, bodyUp = parts.doors.getVehicleBasis(veh)
      if seat and left then
        target = target + left * (seat.x or 0) + fwd * (seat.y or 0) + bodyUp * (seat.z or 0)
      end
      return target
    end
    local nodeId = driverNodeId
    if nodeId == nil then nodeId = core_camera.getDriverData(veh) end
    local nodePos = nodeId ~= nil and veh:getNodePosition(nodeId) or nil
    if not nodePos then return nil end

    local target = veh:getPosition() + nodePos
    local driverCam = inputs.getDriverCameraMode(veh)
    local seat = driverCam and driverCam.seatPosition
    if seat then
      local left, fwd, bodyUp = parts.doors.getVehicleBasis(veh)
      if left then
        target = target + left * (seat.x or 0)
          + fwd * (seat.y or 0) + bodyUp * (seat.z or 0)
      end
    end
    return target
  end

  inputs.boardingCamera.getWalkingBasePos = function(unicycle)
    if not unicycle then return nil end
    local nodeId = core_camera.getDriverData(unicycle)
    local nodePos = nodeId ~= nil and unicycle:getNodePosition(nodeId) or nil
    return nodePos and (unicycle:getPosition() + nodePos) or nil
  end

  inputs.boardingCamera.getForwardDir = function(veh)
    if not veh then return nil end
    local fwd = veh:getDirectionVector()
    if fwd:length() < 1e-4 then return nil end
    fwd:normalize()
    return fwd
  end

  local function setWalkingCameraTransition(unicycle, data)
    if not unicycle then return false end
    local camData = core_camera.getCameraDataById(unicycle:getId())
    local cam = camData and camData.unicycle
    if cam and cam.setScriptedTransition then
      cam:setScriptedTransition(data)
      return true
    end
    return false
  end

  local function prepareDriverSettle(veh, mode)
    if not veh then return nil end
    return {
      vehId = veh:getId(),
      t = 0,
      pendingT = 0,
      duration = inputs.config.driverSettleDurationS,
      mode = mode or "level"
    }
  end

  local function restoreDriverCamera(state)
    if not state or not state.cam then return end
    state.cam.seatPosition = vec3(state.basePos)
    state.cam.seatRotation = state.baseRotation
  end

  local function updateDriverSettle(dt)
    if not runtimeState.driverSettle then return end
    local state = runtimeState.driverSettle
    local veh = getObjectByID(state.vehId)
    if not veh then
      restoreDriverCamera(state)
      runtimeState.driverSettle = nil
      return
    end
    if not state.cam then
      state.pendingT = (state.pendingT or 0) + dt
      local cam = inputs.getDriverCameraMode(veh)
      if not cam or not cam.seatPosition then
        if state.pendingT >= 0.45 then runtimeState.driverSettle = nil end
        return
      end
      state.cam = cam
      state.basePos = vec3(cam.seatPosition)
      state.baseRotation = cam.seatRotation or 0
    end
    state.t = state.t + dt
    local p = clamp(state.t / state.duration, 0, 1)
    local cushion = math.sin(p * math.pi)
    cushion = cushion * cushion
    local cushionZ = state.mode == "low" and -0.008 * cushion
      or state.mode == "high" and 0.010 * cushion or 0
    state.cam.seatPosition = state.basePos + vec3(0, 0, cushionZ)
    state.cam.seatRotation = state.baseRotation
    if p >= 1 then
      restoreDriverCamera(state)
      runtimeState.driverSettle = nil
    end
  end

  local function dirToYawPitch(dir)
    local flatLen = math.sqrt(dir.x * dir.x + dir.y * dir.y)
    local yaw = math.atan2(dir.y, dir.x)
    local pitch = math.atan2(dir.z, math.max(flatLen, 1e-6))
    return yaw, clamp(pitch, -math.rad(89), math.rad(89))
  end

  local function yawPitchToDir(yaw, pitch)
    local cp = math.cos(pitch)
    return vec3(math.cos(yaw) * cp, math.sin(yaw) * cp, math.sin(pitch))
  end

  local function smoothLookDir(current, target, dt, rate, pitchRate, maxRate, maxPitchRate)
    if not target then return current end
    if not current then return target end
    rate = rate or inputs.config.lookResponseRatePerS
    pitchRate = pitchRate or inputs.config.lookPitchResponseRatePerS
    maxRate = maxRate or inputs.config.lookMaxRateRadPerS
    maxPitchRate = maxPitchRate or inputs.config.lookMaxPitchRateRadPerS
    local currentYaw, currentPitch = dirToYawPitch(current)
    local targetYaw, targetPitch = dirToYawPitch(target)
    local yawDelta = (targetYaw - currentYaw + math.pi) % (2 * math.pi) - math.pi
    local pitchDelta = targetPitch - currentPitch
    local yawStep = yawDelta * (1 - math.exp(-dt * rate))
    local pitchStep = pitchDelta * (1 - math.exp(-dt * pitchRate))
    yawStep = clamp(yawStep, -maxRate * dt, maxRate * dt)
    pitchStep = clamp(pitchStep, -maxPitchRate * dt, maxPitchRate * dt)
    return yawPitchToDir(currentYaw + yawStep, currentPitch + pitchStep)
  end

  inputs.boardingCamera.lookInDirection = function(targetDir, dt, boarding)
    if not runtimeState.approach or not targetDir or targetDir:length() < 1e-4 then return end
    targetDir = targetDir:normalized()
    runtimeState.approach.lookDir = smoothLookDir(
      runtimeState.approach.lookDir, targetDir, dt,
      boarding and inputs.config.boardLookResponseRatePerS or nil,
      boarding and 3.80 or nil,
      boarding and inputs.config.boardLookMaxRateRadPerS or nil,
      boarding and math.rad(70) or nil
    )
    gameplay_walk.setRot(runtimeState.approach.lookDir, inputs.up)
  end

  local function lookAtVehicle(pos, lookPos, dt)
    if not lookPos then return end
    local toLook = lookPos - getLookOrigin(pos)
    if toLook:length() < 1e-3 then return end
    toLook:normalize()
    runtimeState.approach.lookDir = smoothLookDir(runtimeState.approach.lookDir, toLook, dt)
    gameplay_walk.setRot(runtimeState.approach.lookDir, inputs.up)
  end

  return {
    captureSpeedCoef = captureSpeedCoef,
    getCameraLookDir = getCameraLookDir,
    getLookOrigin = getLookOrigin,
    lookAtVehicle = lookAtVehicle,
    prepareDriverSettle = prepareDriverSettle,
    restoreDriverCamera = restoreDriverCamera,
    setWalkingCameraTransition = setWalkingCameraTransition,
    smoothLookDir = smoothLookDir,
    updateDriverSettle = updateDriverSettle,
  }
end

return M
