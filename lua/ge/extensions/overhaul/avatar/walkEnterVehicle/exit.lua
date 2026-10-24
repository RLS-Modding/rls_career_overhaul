-- Vehicle exit, post-transition settling and walking input wrappers.
-- Read camera restoration, exit phases, post-transition updates, then walking wrappers and the part API.
local M = {}
local policy = require('overhaul/lib/vehicles/policy')
local walkTarget = require('overhaul/lib/avatar/walkTarget')

function M.new(inputs)
  local runtimeState = inputs.state
  local parts = inputs.parts

  -- Stats and cancel ------------------------------------------------------------------------------

  local function restoreExitDriverCamera(state)
    if not state or not state.driverCam then return end
    state.driverCam.relativeYaw = state.driverYaw or 0
    state.driverCam.relativePitch = state.driverPitch or 0
  end

  local function storeExitStats(reason)
    if not runtimeState.exitTransition then return end
    local state = runtimeState.exitTransition
    local stats = {reason = reason}
    parts.doors.copyStateFields(stats, state, [[vehId model phase doorSide doorTriggerName
    doorControllerName doorReferenceSource doorTriggerLateral doorReferenceLateral
    doorStateBefore doorStateAfter doorOpenStateAfter doorCloseStateAfter doorGap
    doorOpenForceDuration doorCloseForceDuration doorFullEvidence standClearance
    standMargin exitSwitchT doorFullyOpenT targetCameraName startCameraPos]])
    parts.doors.copyStateFields(stats, state, [[doorTriggerCenterValid doorControllerFound
    doorOpened doorClosed doorPhysicalMeasured doorFullyOpened doorOpenTimedOut]], "bool")
    parts.doors.copyStateFields(stats, state, "t maxDoorGap doorStableProbes", "zero")
    stats.doorOpenWait = state.doorOpenWait or state.doorOpenElapsed or 0
    stats.doorCloseAttempts =
      (state.closeRetryCount or 0) + (state.closeCommanded and 1 or 0)
    stats.switchAfterDoorReady = state.exitSwitchT and state.doorFullyOpenT
      and state.exitSwitchT - state.doorFullyOpenT or nil
    stats.driverTransition = state.useDriverTransition == true
    stats.finalCameraPos =
      parts.doors.vecToTable(core_camera.getPosition and core_camera.getPosition() or nil)
    runtimeState.lastExitStats = stats
  end

  local function cancelExit(reason)
    if not runtimeState.exitTransition then return end
    local state = runtimeState.exitTransition
    restoreExitDriverCamera(state)
    local unicycle = gameplay_walk.getCurrentUnicycle and gameplay_walk.getCurrentUnicycle() or nil
    parts.camera.setWalkingCameraTransition(unicycle, nil)
    storeExitStats(reason or "cancel")
    runtimeState.exitTransition = nil
    if state.doorCommanded and state.doorControllerName and not state.doorClosed then
      parts.approach.scheduleDoorClose(state.vehId, state.doorControllerName)
    end
  end

  -- Start -----------------------------------------------------------------------------------------

  local function exitStand(veh)
    local doorInfo = parts.doors.findDriverDoorInfo(veh)
    local lockedDoorName = doorInfo and (doorInfo.triggerName or doorInfo.canonicalName) or nil
    local standPos, front, doorCenter, _, _, standMargin = parts.paths.getStandPos(
      veh, veh:getPosition(), lockedDoorName, 0, doorInfo
    )
    if not standPos then return nil end
    parts.paths.requestCollisionEnvelope(veh, false)
    return {
      doorInfo = doorInfo, standPos = standPos, front = front, doorCenter = doorCenter,
      standMargin = standMargin, standClearance = parts.paths.vehicleClearance2D(standPos, veh:getId(), 0),
    }
  end

  local function exitCamera(veh)
    local targetCameraName = core_camera.getActiveCamNameByVehId(veh:getId()) or core_camera.getActiveCamName()
    local useDriverTransition = inputs.isDriverCameraName(veh, targetCameraName)
    local driverCam
    if useDriverTransition then
      driverCam = inputs.getDriverCameraMode(veh)
    end
    return {targetCameraName = targetCameraName, useDriverTransition = useDriverTransition, driverCam = driverCam}
  end

  local function newExitState(veh, stand, camera)
    local doorInfo, doorCenter, driverCam = stand.doorInfo, stand.doorCenter, camera.driverCam
    return {
      vehId = veh:getId(),
      model = veh:getJBeamFilename(),
      t = 0,
      phaseT = 0,
      phase = "openDoor",
      standPos = vec3(stand.standPos),
      -- The car may move while its door opens; retain vehicle-local coordinates.
      standLocal = parts.doors.worldPointToVehicleLocal(veh, stand.standPos),
      front = stand.front and vec3(stand.front) or nil,
      doorSide = doorInfo and doorInfo.side,
      doorTriggerName = doorInfo and doorInfo.triggerName,
      doorControllerName = doorInfo and doorInfo.controllerName,
      doorReferenceSource = doorInfo and doorInfo.referenceSource,
      doorTriggerCenterValid = doorInfo and doorInfo.triggerCenterValid == true,
      doorTriggerLateral = doorInfo and doorInfo.triggerLateral,
      doorReferenceLateral = parts.doors.getLateralOffset(veh, doorCenter),
      doorReferenceLocal = doorCenter and parts.doors.worldPointToVehicleLocal(veh, doorCenter) or nil,
      doorInfo = doorInfo,
      doorCenter = doorCenter and vec3(doorCenter) or nil,
      maxDoorGap = 0,
      doorOpenElapsed = 0,
      doorProbeCount = 0,
      nextDoorProbeT = 0,
      standMargin = stand.standMargin,
      standClearance = stand.standClearance,
      targetCameraName = camera.targetCameraName,
      useDriverTransition = camera.useDriverTransition,
      driverCam = driverCam,
      driverYaw = driverCam and driverCam.relativeYaw or nil,
      driverPitch = driverCam and driverCam.relativePitch or nil,
      startCameraPos = parts.doors.vecToTable(core_camera.getPosition and core_camera.getPosition() or nil),
      lookDir = parts.camera.getCameraLookDir()
    }
  end

  local function startExit(veh)
    -- Hired services supply their kerb-side seat exit; do not animate back through the driver's door.
    if veh and policy.hasRole('hiredPassenger', veh:getId()) then return false end
    if not inputs.isRealisticEntryEnabled() or not veh or gameplay_walk.isWalking() then return false end
    if not gameplay_walk.isAtParkingSpeed or not gameplay_walk.isAtParkingSpeed() then return false end
    if runtimeState.exitTransition or runtimeState.approach then return false end
    if not parts.doors.canAnimateWalkTransition(true) then return false end

    runtimeState.lastExitStats = nil
    runtimeState.postEnter = nil
    runtimeState.postExit = nil
    local stand = exitStand(veh)
    if not stand then return false end
    runtimeState.exitTransition = newExitState(veh, stand, exitCamera(veh))
    local state = runtimeState.exitTransition
    state.doorCommanded = parts.doors.ensureDoorState(veh, state.doorControllerName, true, "exit")
    if not state.doorCommanded then
      state.doorControllerFound = false
    end
    guihooks.trigger("Message", {
      ttl = 3,
      msg = "Exiting vehicle...",
      category = "walkingmode",
      icon = "seatArrowOutRight"
    })
    return true
  end

  -- Door close helpers ----------------------------------------------------------------------------

  -- Sends the first close command; a refused command leaves the door to the retry schedule.
  local function commandDoorClose(veh, record, controllerName, reason, now)
    record.closeCommanded = parts.doors.ensureDoorState(veh, controllerName, false, reason)
    if not record.closeCommanded then record.doorClosed = controllerName == nil end
    record.closeCommandT = now
    record.closeRetryCount = 0
    record.nextCloseRetryT = now + parts.doors.getDoorCloseRetryInterval(record)
  end

  local function retryDoorClose(veh, record, controllerName, reason, now)
    parts.doors.ensureDoorState(veh, controllerName, false, reason)
    record.closeRetryCount = (record.closeRetryCount or 0) + 1
    record.nextCloseRetryT = now + parts.doors.getDoorCloseRetryInterval(record)
  end

  -- Open door -------------------------------------------------------------------------------------

  local function driveExitDoorOpen(veh, state, dt)
    state.doorOpenElapsed = (state.doorOpenElapsed or 0) + dt
    state.nextDoorProbeT = state.nextDoorProbeT or 0
    if state.doorControllerName and state.doorOpenElapsed >= state.nextDoorProbeT then
      parts.doors.ensureDoorState(veh, state.doorControllerName, true, "exit")
      state.doorProbeCount = (state.doorProbeCount or 0) + 1
      state.nextDoorProbeT = state.doorOpenElapsed + inputs.config.doorProbeIntervalS
    end
    local forceDuration = math.max(state.doorOpenForceDuration or 0.20, 0.08)
    local visualOpenTime = math.max(0.52, forceDuration + inputs.config.doorSwingSettleS)
    local p = parts.doors.smoothstep01(state.doorOpenElapsed / visualOpenTime)
    if state.driverCam then
      local sideSign = state.doorSide == "R" and 1 or -1
      state.driverCam.relativeYaw = (state.driverYaw or 0) + sideSign * 0.38 * p
      state.driverCam.relativePitch = (state.driverPitch or 0) + 0.045 * p
    end
  end

  local function aimExitAtDoor(veh, state, unicycle, doorCenter)
    local target = parts.doors.getExitDoorLookPos(veh, doorCenter) or veh:getPosition()
    local toTarget = target - parts.camera.getLookOrigin(unicycle:getPosition())
    if toTarget:length() > 1e-3 then
      toTarget:normalize()
      state.lookDir = toTarget
      gameplay_walk.setRot(toTarget, inputs.up)
    end
  end

  local function updateExitOpenDoor(veh, state, dt, doorCenter)
    local playerVeh = getPlayerVehicle(0)
    if not playerVeh or playerVeh:getId() ~= state.vehId then
      cancelExit("playerVehicleChanged")
      return
    end
    driveExitDoorOpen(veh, state, dt)
    if not parts.doors.isDoorOpenReady(state) then return end

    state.exitSwitchT = state.t
    restoreExitDriverCamera(state)
    local rot = state.front and quatFromDir(state.front, inputs.up) or nil
    local standPos = state.standLocal and parts.doors.vehicleLocalPointToWorld(veh, state.standLocal) or state.standPos
    state.switchingToWalk = true
    runtimeState.originalSetWalkingMode(true, standPos, rot, true)
    state.switchingToWalk = nil
    local unicycle = gameplay_walk.getCurrentUnicycle and gameplay_walk.getCurrentUnicycle() or nil
    if not unicycle then
      cancelExit("unicycleMissing")
      return
    end
    if state.useDriverTransition then
      core_camera.setVehicleCameraByNameWithId(unicycle:getId(), "unicycle", false, {})
    end
    aimExitAtDoor(veh, state, unicycle, doorCenter)
    state.phase = "closeDoor"
    state.phaseT = 0
  end

  -- Close door ------------------------------------------------------------------------------------

  local function probeExitDoorClose(veh, state)
    state.closeProbeCount = state.closeProbeCount or 0
    if state.closeCommanded and state.doorControllerName
      and state.closeProbeCount < 40
      and state.phaseT >= inputs.config.doorCloseDelayS + inputs.config.doorProbeIntervalS * (state.closeProbeCount + 1) then
      parts.doors.ensureDoorState(veh, state.doorControllerName, false, "exit", true)
      state.closeProbeCount = state.closeProbeCount + 1
    end
  end

  -- Ends the exit; a door still open is handed to post-exit settling.
  local function finishExitClose(unicycle, state)
    parts.camera.setWalkingCameraTransition(unicycle, nil)
    storeExitStats("exit")
    if state.doorControllerName and not state.doorClosed then
      runtimeState.postExit = {
        vehId = state.vehId,
        controllerName = state.doorControllerName,
        doorControllerName = state.doorControllerName,
        doorControllerFound = state.doorControllerFound,
        doorClosed = state.doorClosed,
        doorOpened = state.doorOpened,
        doorGap = state.doorGap,
        maxDoorGap = state.maxDoorGap,
        doorPhysicalMeasured = state.doorPhysicalMeasured,
        doorOpenForceDuration = state.doorOpenForceDuration,
        doorCloseForceDuration = state.doorCloseForceDuration,
        doorOpenWait = state.doorOpenWait,
        doorFullyOpened = state.doorFullyOpened,
        doorFullEvidence = state.doorFullEvidence,
        doorOpenTimedOut = state.doorOpenTimedOut,
        t = 0,
        probeCount = 0,
        closeCommanded = true,
        closeRetryCount = state.closeRetryCount or 0,
        nextCloseRetryT = parts.doors.getDoorCloseRetryInterval(state)
      }
    end
    runtimeState.exitTransition = nil
  end

  local function updateExitCloseDoor(veh, state, dt, doorCenter)
    local unicycle = gameplay_walk.getCurrentUnicycle and gameplay_walk.getCurrentUnicycle() or nil
    if not unicycle then
      cancelExit("walkingInterrupted")
      return
    end
    local pos = unicycle:getPosition()
    local target = parts.doors.getExitDoorLookPos(veh, doorCenter) or veh:getPosition()
    local toTarget = target - parts.camera.getLookOrigin(pos)
    if toTarget:length() > 1e-3 then
      toTarget:normalize()
      state.lookDir = parts.camera.smoothLookDir(state.lookDir, toTarget, dt)
      gameplay_walk.setRot(state.lookDir, inputs.up)
    end
    if state.useDriverTransition then
      local settle = math.sin(math.pi * clamp(state.phaseT / 0.42, 0, 1))
      parts.camera.setWalkingCameraTransition(unicycle, {
        forward = 0.018 * settle,
        z = -0.012 * settle,
        pitch = 0.008 * settle
      })
    end
    if not state.closeCommanded and state.phaseT >= inputs.config.doorCloseDelayS then
      commandDoorClose(veh, state, state.doorControllerName, "exit", state.phaseT)
    end
    probeExitDoorClose(veh, state)
    if state.closeCommanded and state.doorControllerName and not state.doorClosed
      and state.doorStateAfter ~= "broken"
      and state.phaseT >= (state.nextCloseRetryT or math.huge) then
      retryDoorClose(veh, state, state.doorControllerName, "exit", state.phaseT)
    end
    local closeFinished = state.doorClosed == true and state.phaseT >= inputs.config.doorCloseFinishS
    local closeHardLimit = math.max(
      inputs.config.doorCloseTimeoutS,
      (state.doorCloseForceDuration or 0.6) + 0.35
    )
    local closeTimedOut = state.phaseT >= closeHardLimit
    if closeFinished or closeTimedOut then
      finishExitClose(unicycle, state)
    end
  end

  local function currentDoorCenter(veh, state, referenceCenter)
    local liveDoorCenter = state.doorTriggerName and parts.doors.getDoorTriggerCenter(veh, state.doorTriggerName) or nil
    if liveDoorCenter and parts.doors.isDoorCenterOnSide(veh, liveDoorCenter, state.doorSide) then
      return liveDoorCenter
    end
    return referenceCenter
  end

  local function updateExit(dt)
    if not runtimeState.exitTransition then return end
    local state = runtimeState.exitTransition
    state.t = state.t + dt
    state.phaseT = state.phaseT + dt
    local veh = getObjectByID(state.vehId)
    if not veh then
      cancelExit("vehicleMissing")
      return
    end
    local referenceCenter = state.doorReferenceLocal
      and parts.doors.vehicleLocalPointToWorld(veh, state.doorReferenceLocal) or state.doorCenter
    if referenceCenter then state.doorCenter = vec3(referenceCenter) end
    local doorCenter = currentDoorCenter(veh, state, referenceCenter)
    if state.phase == "openDoor" then
      updateExitOpenDoor(veh, state, dt, doorCenter)
    elseif state.phase == "closeDoor" then
      updateExitCloseDoor(veh, state, dt, doorCenter)
    end
  end

  -- Post transition -------------------------------------------------------------------------------

  local function updatePostExit(dt)
    local record = runtimeState.postExit
    if not record then return end
    record.t = record.t + dt
    local veh = getObjectByID(record.vehId)
    if not veh or record.doorClosed then
      runtimeState.postExit = nil
      return
    end
    if record.probeCount < 70 and record.t >= 0.10 * (record.probeCount + 1) then
      parts.doors.ensureDoorState(veh, record.controllerName, false, "exit", true)
      record.probeCount = record.probeCount + 1
    end
    if record.doorStateAfter ~= "broken" and record.t >= (record.nextCloseRetryT or 0) then
      retryDoorClose(veh, record, record.controllerName, "exit", record.t)
    end
    if record.t >= 7.0 then runtimeState.postExit = nil end
  end

  local function waitPostEnterDoorOpen(veh, record, dt)
    if parts.doors.isDoorOpenReady(record) then return true end
    record.doorOpenElapsed = (record.doorOpenElapsed or 0) + dt
    record.nextDoorProbeT = record.nextDoorProbeT or 0
    if record.controllerName and record.doorOpenElapsed >= record.nextDoorProbeT then
      parts.doors.ensureDoorState(veh, record.controllerName, true, "entry")
      record.doorProbeCount = (record.doorProbeCount or 0) + 1
      record.nextDoorProbeT = record.doorOpenElapsed + inputs.config.doorProbeIntervalS
    end
    parts.doors.isDoorOpenReady(record)
    parts.doors.copyDoorStats(runtimeState.lastApproachStats, record)
    return record.doorOpenReady
  end

  local function probePostEnterClose(veh, record)
    record.closeProbeCount = record.closeProbeCount or 0
    if record.closeCommanded and record.controllerName
      and record.closeProbeCount < 60
      and record.t >= (record.closeCommandT or 0) + inputs.config.doorProbeIntervalS * (record.closeProbeCount + 1) then
      parts.doors.ensureDoorState(veh, record.controllerName, false, "entry", true)
      record.closeProbeCount = record.closeProbeCount + 1
    end
  end

  local function updatePostEnter(dt)
    local record = runtimeState.postEnter
    if not record then return end
    record.t = record.t + dt
    local veh = getObjectByID(record.vehId)
    if not veh then
      runtimeState.postEnter = nil
      return
    end
    if not waitPostEnterDoorOpen(veh, record, dt) then return end
    record.openReadyPostT = record.openReadyPostT or record.t

    if not record.closeCommanded and record.t >= record.openReadyPostT + inputs.config.doorCloseDelayS then
      commandDoorClose(veh, record, record.controllerName, "entry", record.t)
    end
    probePostEnterClose(veh, record)
    if record.closeCommanded and record.controllerName and not record.doorClosed
      and record.doorStateAfter ~= "broken"
      and record.t >= (record.nextCloseRetryT or math.huge) then
      retryDoorClose(veh, record, record.controllerName, "entry", record.t)
    end
    parts.doors.copyDoorStats(runtimeState.lastApproachStats, record)
    local closedLongEnough = record.doorClosed == true
      and record.t >= (record.closeCommandT or record.t) + 0.10
    if closedLongEnough or record.t >= 7.0 then runtimeState.postEnter = nil end
  end

  -- Walking wrappers ------------------------------------------------------------------------------

  local function restoreWalkingWithoutPlayer(rot, requestName)
    local recoveryPos = runtimeState.lastPlayerPos or (core_camera.getPosition and core_camera.getPosition())
    if recoveryPos then
      log("W", "walkEnterVehicle", string.format(
        "%s had no player vehicle; restoring the unicycle at the last valid player position",
        requestName
      ))
      return runtimeState.originalSetWalkingMode(true, vec3(recoveryPos), rot, true)
    end
    log("E", "walkEnterVehicle", requestName .. " ignored because no player vehicle or recovery position exists")
    return false, nil
  end

  local function wrappedToggleWalkingMode(player)
    -- Every toggle path below may read walk's vehicle in front, stock's included.
    walkTarget.dropDeletedVehicleInFront(gameplay_walk, player)
    if player ~= nil and player ~= 0 then
      return runtimeState.originalToggle(player)
    end
    if runtimeState.exitTransition then
      cancelExit("cancel")
      guihooks.trigger("Message", {category = "walkingmode", clear = true})
      return
    end
    if runtimeState.approach then
      parts.approach.skipApproach("repeatToggle")
      return
    end

    if gameplay_walk.canToggleWalkingMode and not gameplay_walk.canToggleWalkingMode(false, 0) then
      return runtimeState.originalToggle(player)
    end

    if inputs.isRealisticEntryEnabled() and gameplay_walk.isWalking() then
      local veh = gameplay_walk.getVehicleInFront()
      if veh and parts.approach.startApproach(veh) then
        return
      end
    end

    if inputs.isRealisticEntryEnabled() and not gameplay_walk.isWalking() then
      local veh = getPlayerVehicle(0)
      if veh and startExit(veh) then return end
      if not veh then
        return restoreWalkingWithoutPlayer(nil, "Walking toggle")
      end
    end

    return runtimeState.originalToggle(player)
  end

  local function wrappedSetWalkingMode(enabled, pos, rot, force, player)
    -- Leaving walking mode reads walk's vehicle in front, here and in stock.
    if not enabled then walkTarget.dropDeletedVehicleInFront(gameplay_walk, player) end
    if player ~= nil and player ~= 0 then
      return runtimeState.originalSetWalkingMode(enabled, pos, rot, force, player)
    end
    if runtimeState.approach and not enabled and not force then
      local vehId = runtimeState.approach.vehId
      parts.approach.skipApproach("repeatSetWalkingMode")
      return true, vehId
    elseif runtimeState.approach and enabled then
      parts.approach.cancelApproach()
    end

    if runtimeState.exitTransition and not enabled then
      cancelExit("interrupted")
    end

    -- Scripted walking switches must finish before callers move or delete the car.
    if inputs.isRealisticEntryEnabled() and enabled and not force and not pos and not gameplay_walk.isWalking()
      and not getPlayerVehicle(0) then
      return restoreWalkingWithoutPlayer(rot, "Walking mode request")
    end

    if inputs.isRealisticEntryEnabled() and not enabled and not force and gameplay_walk.isWalking() then
      local veh = gameplay_walk.getVehicleInFront()
      local handled, entered = false, nil
      if veh then
        handled, entered = parts.approach.startApproach(veh)
      end
      if handled then
        local unicycle = gameplay_walk.getCurrentUnicycle()
        if entered == false then
          return false, unicycle and unicycle:getId()
        end
        return true, unicycle and unicycle:getId()
      end
    end

    return runtimeState.originalSetWalkingMode(enabled, pos, rot, force, player)
  end

  local function wrappedSwitchCycleVehicle(player, dir)
    if gameplay_walk and gameplay_walk.isWalking() then
      if runtimeState.approach then
        parts.approach.skipApproach("repeatVehicleSwitch")
        return
      end
      if inputs.isRealisticEntryEnabled() then
        local veh = parts.approach.getNearestEnterableVehicle()
        if veh and gameplay_walk.isAtParkingSpeed() and parts.approach.startApproach(veh) then
          return
        end
      end
    elseif runtimeState.exitTransition then
      cancelExit("vehicleSwitch")
      return
    end
    return runtimeState.originalSwitchCycle(player, dir)
  end

  -- Part API --------------------------------------------------------------------------------------

  return {
    cancelExit = cancelExit,
    startExit = startExit,
    updateExit = updateExit,
    updatePostEnter = updatePostEnter,
    updatePostExit = updatePostExit,
    wrappedSetWalkingMode = wrappedSetWalkingMode,
    wrappedSwitchCycleVehicle = wrappedSwitchCycleVehicle,
    wrappedToggleWalkingMode = wrappedToggleWalkingMode,
  }
end

return M
