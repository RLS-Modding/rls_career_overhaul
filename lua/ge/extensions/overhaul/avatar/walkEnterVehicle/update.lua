-- Walking frame update: geometry and statistics before arrival, doorway and boarding steps.
-- The entry steps read the shared parts table; exit and settling run first.
local M = {}

function M.new(inputs)
  local runtimeState = inputs.state
  local parts = inputs.parts
  local approach = require('overhaul/avatar/walkEnterVehicle/updateApproach').new({
    state = runtimeState, config = inputs.config, up = inputs.up, parts = parts,
  })
  local doorway = require('overhaul/avatar/walkEnterVehicle/updateDoorway').new({
    state = runtimeState, boardingCamera = inputs.boardingCamera, config = inputs.config, up = inputs.up, parts = parts,
  })
  local function updateBoardingCamera(unicycle, dt, boardP, assistP, lookOrigin, forwardDir)
    local desiredCameraPos
    if runtimeState.approach.useDriverTransition and runtimeState.approach.boardStartCameraPos
      and runtimeState.approach.boardTargetCameraPos then
      local startCamera = runtimeState.approach.boardStartCameraPos
      local targetCamera = runtimeState.approach.boardTargetCameraPos
      desiredCameraPos = startCamera + (targetCamera - startCamera) * assistP

      -- Crest or dip before settling onto the real driver viewpoint; both curves keep the same endpoint.
      local verticalSettleStart = 0.72
      if boardP <= verticalSettleStart then
        local verticalP = parts.doors.smoothstep01(boardP / verticalSettleStart)
        desiredCameraPos.z = startCamera.z
          + (targetCamera.z - startCamera.z) * verticalP
      else
        local settleP = clamp(
          (boardP - verticalSettleStart) / (1 - verticalSettleStart), 0, 1
        )
        local settleArc = math.sin(math.pi * settleP)
        settleArc = settleArc * settleArc
        if runtimeState.approach.boardingVerticalMode == "low" then
          desiredCameraPos.z = targetCamera.z - 0.045 * settleArc
        elseif runtimeState.approach.boardingVerticalMode == "high" then
          desiredCameraPos.z = targetCamera.z + 0.055 * settleArc
        else
          desiredCameraPos.z = targetCamera.z
        end
      end

      local baseCameraPos = inputs.boardingCamera.getWalkingBasePos(unicycle) or lookOrigin
      local worldOffset = desiredCameraPos - baseCameraPos
      parts.camera.setWalkingCameraTransition(unicycle, {
        worldX = worldOffset.x,
        worldY = worldOffset.y,
        worldZ = worldOffset.z,
        pitch = 0,
        roll = 0,
        yaw = 0
      })
    end

    if runtimeState.approach.useDriverTransition and forwardDir then
      inputs.boardingCamera.lookInDirection(forwardDir, dt, true)
    end
    if runtimeState.approach.useDriverTransition and runtimeState.approach.boardTargetCameraPos then
      runtimeState.approach.boardCameraEndpointError = lookOrigin:distance(runtimeState.approach.boardTargetCameraPos)
    end
  end

  local function advanceBoardingProgress(veh, unicycle, pos, boardLook, dt, refDist)
    local refProgress = (runtimeState.approach.prevRefDist or refDist) - refDist
    runtimeState.approach.prevRefDist = refDist

    local boardP = clamp(runtimeState.approach.boardT / inputs.config.boardDurationS, 0, 1)
    local cameraOnlyBoard = runtimeState.approach.reachAssist or runtimeState.approach.doorwayBoard
    local assistP = cameraOnlyBoard and parts.doors.smoothstep01(boardP) or 0
    local lookOrigin = parts.camera.getLookOrigin(pos)
    local forwardDir = inputs.boardingCamera.getForwardDir(veh)
    local doorInfo = runtimeState.approach.doorInfo
    local passengerSeat = doorInfo and doorInfo.passengerSeat
    local driverCameraPos = inputs.boardingCamera.getDriverWorldPos(veh, runtimeState.approach.driverNodeId,
      passengerSeat and passengerSeat.cameraName)
    if runtimeState.approach.useDriverTransition and not runtimeState.approach.boardStartCameraPos then
      runtimeState.approach.boardStartCameraPos = vec3(lookOrigin)
      runtimeState.approach.boardTargetCameraPos = driverCameraPos and vec3(driverCameraPos)
        or vec3(boardLook)
      runtimeState.approach.seatHeightDelta = runtimeState.approach.boardTargetCameraPos.z
        - runtimeState.approach.boardStartCameraPos.z
      runtimeState.approach.boardingVerticalMode = runtimeState.approach.seatHeightDelta > inputs.boardingCamera.highSeatThreshold
        and "high" or runtimeState.approach.seatHeightDelta < inputs.boardingCamera.lowSeatThreshold
        and "low" or "level"
    elseif driverCameraPos then
      runtimeState.approach.boardTargetCameraPos = vec3(driverCameraPos)
    end

    updateBoardingCamera(unicycle, dt, boardP, assistP, lookOrigin, forwardDir)

    local endpointReached = not runtimeState.approach.useDriverTransition
      or not cameraOnlyBoard
      or (boardP >= 1 and (runtimeState.approach.boardCameraEndpointError or math.huge) <= 0.075)
    runtimeState.approach.boardCameraEndpointReached = endpointReached
    return refProgress, boardP, cameraOnlyBoard, endpointReached
  end

  local function board(veh, unicycle, pos, boardGoal, boardLook, dt)
    runtimeState.approach.boardT = (runtimeState.approach.boardT or 0) + dt
    runtimeState.approach.boardTarget = boardGoal and vec3(boardGoal) or runtimeState.approach.boardTarget
    if not boardGoal then
      parts.approach.finishEnter(veh)
      return
    end
    local clr, envelopeSource, collisionHull, collisionEnvelope = parts.paths.vehicleClearance2D(
      pos, runtimeState.approach.vehId, 0
    )
    parts.paths.noteCollisionEnvelope(runtimeState.approach, envelopeSource, collisionHull, collisionEnvelope)
    if envelopeSource ~= "none" then
      runtimeState.approach.minClearance = math.min(runtimeState.approach.minClearance or math.huge, clr)
      runtimeState.approach.maxClearance = math.max(runtimeState.approach.maxClearance or -math.huge, clr)
      runtimeState.approach.insideHits = (runtimeState.approach.insideHits or 0) + (clr < 0 and 1 or 0)
    end

    local refDist = pos:distance(boardGoal)
    local vel = unicycle:getVelocity()
    local speed = math.sqrt(vel.x * vel.x + vel.y * vel.y)
    local refProgress, boardP, cameraOnlyBoard, endpointReached = advanceBoardingProgress(
      veh, unicycle, pos, boardLook, dt, refDist
    )
    local collided = clr <= inputs.config.boardCollisionM
    local stalled = runtimeState.approach.boardT > 0.4
      and refDist < inputs.config.boardStallM
      and refProgress < 0.025
      and speed < 0.55
    if runtimeState.approach.boardT >= inputs.config.boardTimeoutS
      or (boardP >= 1 and endpointReached)
      or (not cameraOnlyBoard and (collided or stalled)) then
      parts.approach.finishEnter(veh)
      return
    end
    if cameraOnlyBoard then
      -- Finish camera travel at the driver viewpoint while the walking capsule stays safely outside.
      parts.doors.clearExternalMove(unicycle)
      return
    end
    local toBoard = (boardGoal - pos):z0()
    if toBoard:length() < 1e-3 then
      parts.approach.finishEnter(veh)
      return
    end
    local moveDir = toBoard:normalized()
    parts.camera.lookAtVehicle(pos, boardLook, dt)
    parts.doors.setExternalMove(unicycle, moveDir.x, moveDir.y, 0)
    return
  end


  local function updateBoardingGeometryAndStatistics(dt, veh, pos, standPos, doorCenter, vehRef, aftFactor)
    local boardGoal = parts.doors.getBoardTarget(veh, runtimeState.approach.boardDoorRef, aftFactor) or vehRef

    local goalPos = runtimeState.approach.standPos or standPos
    if runtimeState.approach.phase == "board" then
      goalPos = boardGoal or runtimeState.approach.boardTarget or vehRef or standPos
    end

    local dist = pos:distance(goalPos)
    local livePlayerLong = parts.doors.getLongitudinalOffset(veh, pos)
    local liveDoorLong = parts.doors.getLongitudinalOffset(
      veh, runtimeState.approach.boardDoorRef or doorCenter or runtimeState.approach.doorCenter
    )
    local liveSwingClearance = livePlayerLong and liveDoorLong
      and (livePlayerLong - liveDoorLong) * (runtimeState.approach.safeStandLongSign or -1)
      or nil
    local requiredSwingClearance = runtimeState.approach.doorControllerName
      and math.max(0.18, (runtimeState.approach.doorSpan or 0.60) * 0.25) or nil
    runtimeState.approach.finalDistance = dist
    runtimeState.approach.minDistance = math.min(runtimeState.approach.minDistance, dist)
    runtimeState.approach.maxDistance = math.max(runtimeState.approach.maxDistance, dist)
    runtimeState.approach.pathLength = runtimeState.approach.pathLength + runtimeState.approach.prevPos:distance(pos)
    runtimeState.approach.prevPos:set(pos)
    runtimeState.approach.t = runtimeState.approach.t + dt
    return boardGoal, dist, liveSwingClearance, requiredSwingClearance
  end

  local function dispatchEntryMovement(
    dt, veh, unicycle, pos, standPos, doorCenter, liveDoorCenter, vehLook, aftFactor, boardLook,
    boardGoal, dist, liveSwingClearance, requiredSwingClearance
  )
    if approach.advanceArrival(
      veh, unicycle, pos, standPos, vehLook, aftFactor, dist,
      liveSwingClearance, requiredSwingClearance, dt
    ) then return end

    if runtimeState.approach.phase == "waitDoor" then
      doorway.waitForDoor(veh, unicycle, pos, standPos, doorCenter, liveDoorCenter, boardLook, boardGoal, requiredSwingClearance, dt)
      return
    end

    if runtimeState.approach.phase == "stepCloser" then
      doorway.stepCloser(veh, unicycle, pos, doorCenter, liveDoorCenter, boardLook, dt)
      return
    end

    if runtimeState.approach.phase == "stepSettle" then
      doorway.settleAtDoor(veh, unicycle, pos, doorCenter, liveDoorCenter, boardLook, dt)
      return
    end

    if runtimeState.approach.phase == "stepIn" then
      doorway.stepIn(veh, unicycle, pos, doorCenter, boardLook, aftFactor, dt)
      return
    end

    if runtimeState.approach.phase == "board" then
      board(veh, unicycle, pos, boardGoal, boardLook, dt)
      return
    end

    approach.moveToDoor(veh, unicycle, pos, standPos, vehLook, doorCenter, aftFactor, dist, dt)
  end

  local function refreshBoardingReference(veh, standPos, front, doorCenter)
    if runtimeState.approach.phase == "approach" then
      runtimeState.approach.standPos = standPos
    end
    runtimeState.approach.doorCenter = doorCenter or runtimeState.approach.doorCenter
    runtimeState.approach.vehRef = parts.doors.getVehicleRefPos(veh)
    runtimeState.approach.front = front
    local vehRef = runtimeState.approach.vehRef
    local vehLook = parts.doors.getVehicleLookPos(veh)
    local aftFactor = runtimeState.approach.aftFactor or 0
    if runtimeState.approach.boardDoorLocal then
      runtimeState.approach.boardDoorRef = parts.doors.vehicleLocalPointToWorld(veh, runtimeState.approach.boardDoorLocal)
    elseif doorCenter or runtimeState.approach.doorCenter then
      runtimeState.approach.boardDoorRef = vec3(doorCenter or runtimeState.approach.doorCenter)
      runtimeState.approach.boardDoorLocal = parts.doors.worldPointToVehicleLocal(veh, runtimeState.approach.boardDoorRef)
    end
    local boardLook = parts.doors.getBoardLookPos(veh, runtimeState.approach.boardDoorRef, aftFactor) or vehLook
    return vehRef, vehLook, aftFactor, boardLook
  end

  local function onUpdate(dtReal, dtSim)
    local playerVeh = getPlayerVehicle(0)
    if playerVeh then
      if runtimeState.lastPlayerPos then
        runtimeState.lastPlayerPos:set(playerVeh:getPosition())
      else
        runtimeState.lastPlayerPos = vec3(playerVeh:getPosition())
      end
    end
    local dt = dtSim or dtReal
    if not dt or dt <= 0 then return end
    parts.camera.updateDriverSettle(dt)
    parts.exit.updatePostEnter(dt)
    parts.exit.updatePostExit(dt)
    if runtimeState.exitTransition then
      if not inputs.isRealisticEntryEnabled() then
        parts.exit.cancelExit("disabled")
        return
      end
      parts.exit.updateExit(dt)
      return
    end
    if not runtimeState.approach then return end
    if not inputs.isRealisticEntryEnabled() then
      parts.approach.cancelApproach()
      return
    end
    local veh = getObjectByID(runtimeState.approach.vehId)
    local unicycle = gameplay_walk.getCurrentUnicycle and gameplay_walk.getCurrentUnicycle() or nil
    local vehicleEnterable = inputs.isEnterableVehicle(veh)
    if not vehicleEnterable or not unicycle or not gameplay_walk.isWalking() then
      parts.approach.cancelApproach(not vehicleEnterable and "vehicleUnavailable" or "walkingInterrupted")
      return
    end

    local pos = unicycle:getPosition()
    local standPos, front, doorCenter = parts.paths.getStandPos(
      veh, pos, runtimeState.approach.doorName, runtimeState.approach.aftFactor, runtimeState.approach.doorInfo
    )
    local liveDoorCenter = runtimeState.approach.doorTriggerName
      and parts.doors.getDoorTriggerCenter(veh, runtimeState.approach.doorTriggerName) or nil
    local liveDoorCenterValid = liveDoorCenter
      and parts.doors.isDoorCenterOnSide(veh, liveDoorCenter, runtimeState.approach.doorSide)
    if not liveDoorCenterValid then liveDoorCenter = nil end
    if not standPos then
      parts.approach.finishEnter(veh)
      return
    end
    local vehRef, vehLook, aftFactor, boardLook = refreshBoardingReference(veh, standPos, front, doorCenter)
    local boardGoal, dist, liveSwingClearance, requiredSwingClearance = updateBoardingGeometryAndStatistics(
      dt, veh, pos, standPos, doorCenter, vehRef, aftFactor
    )

    return dispatchEntryMovement(
      dt, veh, unicycle, pos, standPos, doorCenter, liveDoorCenter, vehLook, aftFactor, boardLook,
      boardGoal, dist, liveSwingClearance, requiredSwingClearance
    )
  end

  return {
    onUpdate = onUpdate,
  }
end

return M
