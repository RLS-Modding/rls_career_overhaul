-- Doorway entry: opening, approaching the pocket, settling and crossing the doorway.
-- Doorway phases read the shared runtime and sibling parts.
local M = {}

function M.new(inputs)
  local runtimeState = inputs.state
  local parts = inputs.parts

  -- Door opening ----------------------------------------------------------------------------------

  local function advanceDoorOpening(veh, unicycle, pos, standPos, doorCenter, liveDoorCenter, boardLook, dt)
    runtimeState.approach.arriveT = (runtimeState.approach.arriveT or 0) + dt
    runtimeState.approach.doorOpenElapsed = (runtimeState.approach.doorOpenElapsed or 0) + dt
    if not runtimeState.approach.doorCommanded then
      if not runtimeState.approach.doorCommandT then
        runtimeState.approach.doorCommandT = runtimeState.approach.t
        runtimeState.approach.doorCommandStandDistance = pos:distance(runtimeState.approach.standPos or standPos)
        runtimeState.approach.doorCommandDoorDistance = (doorCenter or runtimeState.approach.doorCenter)
          and pos:distance(doorCenter or runtimeState.approach.doorCenter) or nil
        runtimeState.approach.doorCommandClearance = parts.paths.vehicleClearance2D(pos, runtimeState.approach.vehId, 0)
        local sideAligned, playerLateral, expectedLateral, selectedDoorLateral =
          parts.doors.getDriverDoorSideAlignment(
            veh, pos, runtimeState.approach.doorInfo, runtimeState.approach.boardDoorRef or doorCenter or runtimeState.approach.doorCenter
          )
        runtimeState.approach.doorCommandPlayerLateral = playerLateral
        runtimeState.approach.doorCommandExpectedLateral = expectedLateral
        runtimeState.approach.doorCommandSelectedDoorLateral = selectedDoorLateral
        runtimeState.approach.doorCommandSideAligned = sideAligned == true
        local lockedDoorCenter = runtimeState.approach.boardDoorRef or doorCenter or runtimeState.approach.doorCenter
        local playerLongitudinal = parts.doors.getLongitudinalOffset(veh, pos)
        local doorLongitudinal = parts.doors.getLongitudinalOffset(veh, lockedDoorCenter)
        runtimeState.approach.doorCommandPlayerLongitudinal = playerLongitudinal
        runtimeState.approach.doorCommandDoorLongitudinal = doorLongitudinal
        runtimeState.approach.doorCommandSwingClearance = playerLongitudinal and doorLongitudinal
          and (playerLongitudinal - doorLongitudinal) * (runtimeState.approach.safeStandLongSign or -1)
          or nil
      end
      runtimeState.approach.doorCommanded = parts.doors.ensureDoorState(
        veh, runtimeState.approach.doorControllerName, true, "entry"
      )
      if not runtimeState.approach.doorCommanded then runtimeState.approach.doorControllerFound = false end
      if runtimeState.approach.doorCommanded then
        runtimeState.approach.doorProbeCount = (runtimeState.approach.doorProbeCount or 0) + 1
        runtimeState.approach.nextDoorProbeT = runtimeState.approach.doorOpenElapsed + inputs.config.doorProbeIntervalS
      end
    end
    if runtimeState.approach.doorCommanded and runtimeState.approach.doorControllerName
      and runtimeState.approach.doorOpenElapsed >= (runtimeState.approach.nextDoorProbeT or 0) then
      parts.doors.ensureDoorState(veh, runtimeState.approach.doorControllerName, true, "entry")
      runtimeState.approach.doorProbeCount = (runtimeState.approach.doorProbeCount or 0) + 1
      runtimeState.approach.nextDoorProbeT = runtimeState.approach.doorOpenElapsed + inputs.config.doorProbeIntervalS
    end
    parts.doors.clearExternalMove(unicycle)
    local doorLook = parts.doors.getDoorLookPos(veh, liveDoorCenter or doorCenter or runtimeState.approach.doorCenter) or boardLook
    parts.camera.lookAtVehicle(pos, doorLook, dt)
    local forceDuration = math.max(runtimeState.approach.doorOpenForceDuration or 0.20, 0.08)
    local visualOpenTime = runtimeState.approach.doorControllerName
      and math.max(0.52, forceDuration + inputs.config.doorSwingSettleS)
      or inputs.config.doorFallbackOpenS
    return visualOpenTime
  end

  local function holdAtOpenDoor(veh, unicycle, pos, standPos, doorCenter, liveDoorCenter, boardLook, dt)
    local visualOpenTime = advanceDoorOpening(veh, unicycle, pos, standPos, doorCenter, liveDoorCenter, boardLook, dt)
    local openP = clamp(runtimeState.approach.doorOpenElapsed / visualOpenTime, 0, 1)
    if runtimeState.approach.useDriverTransition then
      local reach = math.sin(math.pi * parts.doors.smoothstep01(openP))
      local sideSign = runtimeState.approach.doorSide == "R" and -1 or 1
      parts.camera.setWalkingCameraTransition(unicycle, {
        forward = 0.052 * reach,
        side = sideSign * 0.016 * reach,
        z = -0.020 * reach,
        pitch = 0.012 * reach,
        roll = sideSign * 0.010 * reach
      })
    end
    if parts.doors.isDoorOpenReady(runtimeState.approach) then
      runtimeState.approach.phase = "stepCloser"
      runtimeState.approach.entryCloseT = 0
      runtimeState.approach.entryCloseTravel = 0
      runtimeState.approach.entryClosePrevPos = vec3(pos)
      runtimeState.approach.entryClosePos = parts.paths.getDoorPocketPos(
        veh,
        runtimeState.approach.boardDoorRef or doorCenter or runtimeState.approach.doorCenter,
        runtimeState.approach.safeStandLongSign,
        runtimeState.approach.doorSpan,
        pos.z
      )
      runtimeState.approach.entryCloseStartDistance = runtimeState.approach.entryClosePos
        and pos:distance(runtimeState.approach.entryClosePos) or 0
      runtimeState.approach.entryCloseStartClearance = parts.paths.vehicleClearance2D(pos, runtimeState.approach.vehId, 0)
      runtimeState.approach.entryDoorHoldT = 0
      runtimeState.approach.route = nil
      runtimeState.approach.routeIndex = 1
      runtimeState.approach.waypoint = nil
      runtimeState.approach.prevBoardClearance = nil
      runtimeState.approach.prevRefDist = nil
    end
  end

  local function waitForDoor(
    veh, unicycle, pos, standPos, doorCenter,
    liveDoorCenter, boardLook, boardGoal, requiredSwingClearance, dt
  )
    if not runtimeState.approach.doorCommanded and runtimeState.approach.doorControllerName then
      local lockedDoorCenter = runtimeState.approach.boardDoorRef or doorCenter or runtimeState.approach.doorCenter
      local sideAligned, playerLateral, expectedLateral, selectedDoorLateral =
        parts.doors.getDriverDoorSideAlignment(veh, pos, runtimeState.approach.doorInfo, lockedDoorCenter)
      runtimeState.approach.doorCommandPlayerLateral = playerLateral
      runtimeState.approach.doorCommandExpectedLateral = expectedLateral
      runtimeState.approach.doorCommandSelectedDoorLateral = selectedDoorLateral
      runtimeState.approach.doorCommandSideAligned = sideAligned == true
      local playerLongitudinal = parts.doors.getLongitudinalOffset(veh, pos)
      local doorLongitudinal = parts.doors.getLongitudinalOffset(veh, lockedDoorCenter)
      runtimeState.approach.doorCommandPlayerLongitudinal = playerLongitudinal
      runtimeState.approach.doorCommandDoorLongitudinal = doorLongitudinal
      runtimeState.approach.doorCommandSwingClearance = playerLongitudinal and doorLongitudinal
        and (playerLongitudinal - doorLongitudinal) * (runtimeState.approach.safeStandLongSign or -1)
        or nil
      local swingAligned = not requiredSwingClearance
        or not runtimeState.approach.doorCommandSwingClearance
        or runtimeState.approach.doorCommandSwingClearance >= requiredSwingClearance
      if sideAligned == false or not swingAligned then
        runtimeState.approach.wrongSideCorrections = (runtimeState.approach.wrongSideCorrections or 0) + 1
        if not swingAligned then
          runtimeState.approach.swingClearanceCorrections = (runtimeState.approach.swingClearanceCorrections or 0) + 1
        end
        runtimeState.approach.phase = "approach"
        runtimeState.approach.arrived = false
        runtimeState.approach.reachAssist = false
        runtimeState.approach.reachAssistDistance = nil
        runtimeState.approach.reachAssistReason = nil
        runtimeState.approach.route = nil
        runtimeState.approach.routeIndex = 1
        runtimeState.approach.waypoint = nil
        runtimeState.approach.stallWindowT = 0
        runtimeState.approach.stallWindowPath = runtimeState.approach.pathLength
        runtimeState.approach.t = math.min(runtimeState.approach.t, inputs.config.approachTimeoutS - 3)
        parts.doors.clearExternalMove(unicycle)
        return
      end
    end
    runtimeState.approach.boardTarget = boardGoal and vec3(boardGoal) or runtimeState.approach.boardTarget
    holdAtOpenDoor(veh, unicycle, pos, standPos, doorCenter, liveDoorCenter, boardLook, dt)
    return
  end

  -- Door pocket -----------------------------------------------------------------------------------

  local function advanceDoorwayClosingMotion(veh, unicycle, pos, doorCenter, liveDoorCenter, boardLook, dt, closeGoal)
    if runtimeState.approach.entryClosePrevPos then
      runtimeState.approach.entryCloseTravel = (runtimeState.approach.entryCloseTravel or 0)
        + runtimeState.approach.entryClosePrevPos:distance(pos)
      runtimeState.approach.entryClosePrevPos:set(pos)
    end
    local closeDistance = pos:distance(closeGoal)
    runtimeState.approach.entryCloseFinalDistance = closeDistance
    local closeClearance, envelopeSource, collisionHull, collisionEnvelope = parts.paths.vehicleClearance2D(
      pos, runtimeState.approach.vehId, 0
    )
    parts.paths.noteCollisionEnvelope(runtimeState.approach, envelopeSource, collisionHull, collisionEnvelope)
    runtimeState.approach.entryCloseTargetClearance = parts.paths.vehicleClearance2D(closeGoal, runtimeState.approach.vehId, 0)
    local closeP = parts.doors.smoothstep01(clamp(
      1 - closeDistance / math.max(runtimeState.approach.entryCloseStartDistance or closeDistance, 0.1), 0, 1
    ))
    local closeLook = parts.doors.getDoorLookPos(veh, liveDoorCenter or doorCenter or runtimeState.approach.doorCenter)
      or boardLook
    local closeForward = inputs.boardingCamera.getForwardDir(veh)
    if runtimeState.approach.useDriverTransition and closeP >= 0.50 and closeForward then
      inputs.boardingCamera.lookInDirection(closeForward, dt, true)
    else
      parts.camera.lookAtVehicle(pos, closeLook, dt)
    end
    if runtimeState.approach.useDriverTransition then
      local sideSign = runtimeState.approach.doorSide == "R" and -1 or 1
      parts.camera.setWalkingCameraTransition(unicycle, {
        forward = 0.020 * closeP,
        side = sideSign * 0.008 * closeP,
        z = -0.012 * closeP,
        pitch = 0.008 * closeP,
        roll = sideSign * 0.005 * closeP
      })
    end
    local reached = closeDistance <= 0.10
    local timedOut = runtimeState.approach.entryCloseT >= 1.80
    return reached, timedOut
  end

  -- The player stopped at the door pocket: plan the step across the sill and let the body settle first.
  local function beginStepSettle(veh, unicycle, pos, doorCenter, closeCompleted)
    runtimeState.approach.entryCloseCompleted = closeCompleted
    runtimeState.approach.phase = "stepSettle"
    runtimeState.approach.entrySettleT = 0
    runtimeState.approach.entryStepT = 0
    runtimeState.approach.entryStepTravel = 0
    runtimeState.approach.entryStepPrevPos = vec3(pos)
    runtimeState.approach.entryStepPos = parts.paths.getDoorEntryPos(
      veh, runtimeState.approach.boardDoorRef or doorCenter or runtimeState.approach.doorCenter, pos.z
    )
    runtimeState.approach.entryStepStartDistance = runtimeState.approach.entryStepPos
      and pos:distance(runtimeState.approach.entryStepPos) or 0
    if runtimeState.approach.entryStepPos then
      local plannedDelta = (runtimeState.approach.entryStepPos - (runtimeState.approach.entryClosePos or pos)):z0()
      local plannedFwd = veh:getDirectionVector():z0()
      if plannedFwd:length() > 1e-4 then plannedFwd:normalize() end
      local plannedLeft = veh:getDirectionVectorUp():cross(plannedFwd):z0()
      if plannedLeft:length() > 1e-4 then plannedLeft:normalize() end
      runtimeState.approach.entryStepPlannedLongitudinal = math.abs(plannedDelta:dot(plannedFwd))
      runtimeState.approach.entryStepPlannedLateral = math.abs(plannedDelta:dot(plannedLeft))
    end
    parts.doors.clearExternalMove(unicycle)
  end

  local function stepCloser(veh, unicycle, pos, doorCenter, liveDoorCenter, boardLook, dt)
    runtimeState.approach.entryCloseT = (runtimeState.approach.entryCloseT or 0) + dt
    parts.doors.holdEntryDoorOpen(veh, dt)
    local closeGoal = parts.paths.getDoorPocketPos(
      veh,
      runtimeState.approach.boardDoorRef or doorCenter or runtimeState.approach.doorCenter,
      runtimeState.approach.safeStandLongSign,
      runtimeState.approach.doorSpan,
      pos.z
    ) or runtimeState.approach.entryClosePos
    runtimeState.approach.entryClosePos = closeGoal
    if not closeGoal then
      runtimeState.approach.entryCloseCompleted = false
      runtimeState.approach.phase = "stepIn"
      runtimeState.approach.entryStepT = 0
      runtimeState.approach.entryStepTravel = 0
      runtimeState.approach.entryStepPrevPos = vec3(pos)
      return
    end

    local reached, timedOut = advanceDoorwayClosingMotion(
      veh, unicycle, pos, doorCenter, liveDoorCenter, boardLook, dt, closeGoal
    )
    if reached or timedOut then
      beginStepSettle(veh, unicycle, pos, doorCenter, reached)
      return
    end

    local toClose = (closeGoal - pos):z0()
    if toClose:length() > 1e-4 then
      local closeMoveScale = clamp((toClose:length() / 0.30) ^ 2, 0.10, 1)
      toClose:normalize()
      parts.doors.setExternalMove(
        unicycle, toClose.x * closeMoveScale, toClose.y * closeMoveScale, 0
      )
    else
      parts.doors.clearExternalMove(unicycle)
    end
    return
  end

  -- Planted settling ------------------------------------------------------------------------------

  local function settleAtDoor(veh, unicycle, pos, doorCenter, liveDoorCenter, boardLook, dt)
    runtimeState.approach.entrySettleT = (runtimeState.approach.entrySettleT or 0) + dt
    parts.doors.holdEntryDoorOpen(veh, dt)
    parts.doors.clearExternalMove(unicycle)
    local settleLook = parts.doors.getDoorLookPos(veh, liveDoorCenter or doorCenter or runtimeState.approach.doorCenter)
      or boardLook
    local settleForward = inputs.boardingCamera.getForwardDir(veh)
    if runtimeState.approach.useDriverTransition and settleForward then
      -- Look toward the road before crossing so a high seat cannot pull the gaze upward during step-in.
      inputs.boardingCamera.lookInDirection(settleForward, dt, true)
    else
      parts.camera.lookAtVehicle(pos, settleLook, dt)
    end
    if runtimeState.approach.entrySettleT >= 0.18 then
      runtimeState.approach.phase = "stepIn"
      runtimeState.approach.route = nil
      runtimeState.approach.routeIndex = 1
      runtimeState.approach.waypoint = nil
    end
    return
  end

  -- Doorway crossing ------------------------------------------------------------------------------

  local function advanceDoorwayEntryMotion(veh, unicycle, pos, doorCenter, boardLook, aftFactor, dt, stepGoal)
    if runtimeState.approach.entryStepPrevPos then
      runtimeState.approach.entryStepTravel = (runtimeState.approach.entryStepTravel or 0)
        + runtimeState.approach.entryStepPrevPos:distance(pos)
      runtimeState.approach.entryStepPrevPos:set(pos)
    end
    local stepDistance = pos:distance(stepGoal)
    runtimeState.approach.entryStepFinalDistance = stepDistance
    local stepClearance, envelopeSource, collisionHull, collisionEnvelope = parts.paths.vehicleClearance2D(
      pos, runtimeState.approach.vehId, 0
    )
    parts.paths.noteCollisionEnvelope(runtimeState.approach, envelopeSource, collisionHull, collisionEnvelope)
    runtimeState.approach.entryStepTargetClearance = parts.paths.vehicleClearance2D(stepGoal, runtimeState.approach.vehId, 0)
    local stepP = parts.doors.smoothstep01(clamp(
      1 - stepDistance / math.max(runtimeState.approach.entryStepStartDistance or stepDistance, 0.1), 0, 1
    ))
    local stepLook = parts.doors.getBoardLookPos(veh, doorCenter or runtimeState.approach.doorCenter, aftFactor)
      or boardLook
    local forwardDir = inputs.boardingCamera.getForwardDir(veh)
    if runtimeState.approach.useDriverTransition and forwardDir then
      inputs.boardingCamera.lookInDirection(forwardDir, dt, true)
    else
      parts.camera.lookAtVehicle(pos, stepLook, dt)
    end
    if runtimeState.approach.useDriverTransition then
      local sideSign = runtimeState.approach.doorSide == "R" and -1 or 1
      parts.camera.setWalkingCameraTransition(unicycle, {
        forward = 0.045 * stepP,
        side = sideSign * 0.012 * stepP,
        z = -0.010 * stepP,
        pitch = 0,
        roll = sideSign * 0.008 * stepP
      })
    end
    local reached = stepDistance <= inputs.config.entryStepArriveM
    local stepTimeout = runtimeState.approach.model == "nine" and 2.30 or inputs.config.entryStepTimeoutS
    local timedOut = runtimeState.approach.entryStepT >= stepTimeout
    return stepDistance, reached, timedOut
  end

  local function stepIn(veh, unicycle, pos, doorCenter, boardLook, aftFactor, dt)
    runtimeState.approach.entryStepT = (runtimeState.approach.entryStepT or 0) + dt
    parts.doors.holdEntryDoorOpen(veh, dt)
    -- Use the locked closed-door reference so the target stays between the swung panel and body.
    local stepGoal = parts.paths.getDoorEntryPos(
      veh, runtimeState.approach.boardDoorRef or doorCenter or runtimeState.approach.doorCenter, pos.z
    )
      or runtimeState.approach.entryStepPos
    runtimeState.approach.entryStepPos = stepGoal
    if not stepGoal then
      runtimeState.approach.entryStepCompleted = false
      runtimeState.approach.phase = "board"
      runtimeState.approach.boardT = 0
      return
    end

    local stepDistance, reached, timedOut = advanceDoorwayEntryMotion(
      veh, unicycle, pos, doorCenter, boardLook, aftFactor, dt, stepGoal
    )
    if reached or timedOut then
      runtimeState.approach.entryStepCompleted = reached
      runtimeState.approach.doorwayBoard = reached or stepDistance <= 0.24
      runtimeState.approach.phase = "board"
      runtimeState.approach.boardT = 0
      runtimeState.approach.prevBoardClearance = nil
      runtimeState.approach.prevRefDist = nil
      parts.doors.clearExternalMove(unicycle)
      return
    end

    local stepMoveGoal = stepGoal
    if runtimeState.approach.model == "nine" then
      stepMoveGoal = parts.paths.getSteerTarget(
        pos, stepGoal, runtimeState.approach.vehId, 0.42, 0.04
      ) or stepGoal
    end
    local toStep = (stepMoveGoal - pos):z0()
    if toStep:length() > 1e-4 then
      local moveScale = runtimeState.approach.model == "nine"
        and clamp(stepDistance / 0.52, 0.32, 1) or 1
      toStep:normalize()
      parts.doors.setExternalMove(unicycle, toStep.x * moveScale, toStep.y * moveScale, 0)
    else
      parts.doors.clearExternalMove(unicycle)
    end
    return
  end

  -- Part API --------------------------------------------------------------------------------------

  return {
    waitForDoor = waitForDoor,
    stepCloser = stepCloser,
    settleAtDoor = settleAtDoor,
    stepIn = stepIn,
  }
end

return M
