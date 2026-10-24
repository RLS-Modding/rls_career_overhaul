-- Vehicle entry: door close scheduling, cancellation, seating and approach setup.
-- Geometry and camera operations are read through the shared parts table.
local M = {}

function M.new(inputs)
  local runtimeState = inputs.state
  local parts = inputs.parts

  -- Door close ------------------------------------------------------------------------------------

  local function scheduleDoorClose(vehId, controllerName)
    local veh = vehId and getObjectByID(vehId)
    if not veh or not controllerName then return end
    if not parts.doors.ensureDoorState(veh, controllerName, false, "exit") then return end
    runtimeState.postExit = {
      vehId = vehId,
      controllerName = controllerName,
      doorControllerName = controllerName,
      t = 0,
      probeCount = 0,
      closeCommanded = true,
      closeRetryCount = 0,
      nextCloseRetryT = parts.doors.getDoorCloseRetryInterval(nil)
    }
  end

  -- Cancel and finish -----------------------------------------------------------------------------

  local function clearApproachWalk(unicycle)
    parts.doors.clearExternalMove(unicycle)
    parts.camera.setWalkingCameraTransition(unicycle, nil)
    runtimeState.approach = nil
  end

  local function cancelApproach(reason)
    if not runtimeState.approach then return end
    parts.paths.storeApproachStats(reason or "cancel")
    local cancelled = runtimeState.approach
    local unicycle = gameplay_walk.getCurrentUnicycle and gameplay_walk.getCurrentUnicycle() or getPlayerVehicle(0)
    clearApproachWalk(unicycle)
    if cancelled.doorCommanded and cancelled.doorControllerName then
      scheduleDoorClose(cancelled.vehId, cancelled.doorControllerName)
    end
  end

  -- The walk can end before the door opened, so the entry still has to open it.
  local function settleFinishedApproach(veh, finished, options)
    finished.skipped = options.skipped == true or finished.skipped == true
    finished.skipReason = options.skipReason or finished.skipReason
    finished.skipAtT = finished.skipped and (finished.skipAtT or finished.t or 0) or nil
    finished.entrySwitchT = finished.t or 0
    if finished.doorControllerName and not finished.doorCommanded then
      finished.doorOpenElapsed = finished.doorOpenElapsed or 0
      finished.doorProbeCount = finished.doorProbeCount or 0
      finished.doorCommanded = parts.doors.ensureDoorState(veh, finished.doorControllerName, true, "entry")
    end
  end

  local function postEnterState(veh, finished)
    return {
      vehId = veh:getId(),
      t = 0,
      controllerName = finished and finished.doorControllerName,
      doorControllerName = finished and finished.doorControllerName,
      doorControllerFound = finished and finished.doorControllerFound,
      doorStateBefore = finished and finished.doorStateBefore,
      doorStateAfter = finished and finished.doorStateAfter,
      doorOpenStateAfter = finished and finished.doorOpenStateAfter,
      doorOpened = finished and finished.doorOpened,
      doorGap = finished and finished.doorGap,
      maxDoorGap = finished and finished.maxDoorGap or 0,
      doorPhysicalMeasured = finished and finished.doorPhysicalMeasured,
      doorOpenForceDuration = finished and finished.doorOpenForceDuration,
      doorCloseForceDuration = finished and finished.doorCloseForceDuration,
      doorOpenElapsed = finished and finished.doorOpenElapsed or 0,
      doorOpenWait = finished and finished.doorOpenWait,
      doorFullyOpened = finished and finished.doorFullyOpened,
      doorOpenReady = finished and finished.doorOpenReady,
      doorFullEvidence = finished and finished.doorFullEvidence,
      doorOpenTimedOut = finished and finished.doorOpenTimedOut,
      doorStableProbes = finished and finished.doorStableProbes or 0,
      previousDoorGap = finished and finished.previousDoorGap,
      doorProbeCount = finished and finished.doorProbeCount or 0,
      nextDoorProbeT = finished and finished.nextDoorProbeT or 0,
      skipped = finished and finished.skipped,
      closeCommanded = false
    }
  end

  local function finishEnter(veh, options)
    options = options or {}
    if not inputs.isEnterableVehicle(veh) then
      cancelApproach("vehicleUnavailable")
      return false
    end
    local unicycle = gameplay_walk.getCurrentUnicycle and gameplay_walk.getCurrentUnicycle() or nil
    local finished = runtimeState.approach
    if finished then settleFinishedApproach(veh, finished, options) end
    parts.paths.storeApproachStats("enter")
    clearApproachWalk(unicycle)
    if finished and finished.useDriverTransition and not (finished.doorInfo and finished.doorInfo.passenger) then
      runtimeState.driverSettle = parts.camera.prepareDriverSettle(veh, finished.boardingVerticalMode)
    end
    -- Match stock walk.lua so career inventory records the seated vehicle.
    if not inputs.enterVehicleFromWalk(veh, finished and finished.doorInfo) then
      runtimeState.driverSettle = nil
      if finished and finished.doorCommanded and finished.doorControllerName then
        parts.doors.ensureDoorState(veh, finished.doorControllerName, false, "entry")
      end
      return false
    end
    runtimeState.postEnter = postEnterState(veh, finished)
    return true
  end

  local function skipApproach(skipReason)
    if not runtimeState.approach then return false end
    local veh = getObjectByID(runtimeState.approach.vehId)
    if not veh then
      cancelApproach("vehicleMissing")
      return false
    end
    finishEnter(veh, {skipped = true, skipReason = skipReason or "repeatInput"})
    guihooks.trigger("Message", {category = "walkingmode", clear = true})
    return true
  end

  -- Start approach --------------------------------------------------------------------------------

  -- The envelope request is async: cached topology serves until the new one arrives.
  local function findApproachStand(veh, unicycle)
    local collisionEnvelope = parts.paths.requestCollisionEnvelope(veh, true)
    local fromPos = unicycle:getPosition()
    local doorInfo = parts.doors.findEntryDoorInfo(veh, fromPos)
    local lockedDoorName = doorInfo and (doorInfo.triggerName or doorInfo.canonicalName) or nil
    local standPos, front, doorCenter, doorName, aftFactor, standMargin = parts.paths.getStandPos(
      veh, fromPos, lockedDoorName, nil, doorInfo
    )
    return {
      fromPos = fromPos, collisionEnvelope = collisionEnvelope, doorInfo = doorInfo,
      standPos = standPos, front = front, doorCenter = doorCenter, doorName = doorName,
      aftFactor = aftFactor or 0, standMargin = standMargin,
    }
  end

  local function prepareApproachCamera(veh, unicycle, doorInfo)
    local targetCameraName = core_camera.getActiveCamNameByVehId(veh:getId())
    local passengerSeat = doorInfo and doorInfo.passengerSeat
    if passengerSeat then targetCameraName = passengerSeat.cameraName end
    local useDriverTransition = passengerSeat ~= nil or inputs.isDriverCameraName(veh, targetCameraName)
    if doorInfo and doorInfo.passenger and not passengerSeat then useDriverTransition = false end
    if useDriverTransition then
      core_camera.setVehicleCameraByNameWithId(unicycle:getId(), "unicycle", false, {})
    end
    return {targetCameraName = targetCameraName, useDriverTransition = useDriverTransition}
  end

  local function approachAim(veh, stand)
    local fromPos = stand.fromPos
    local vehRef = parts.doors.getVehicleRefPos(veh)
    local vehLook = parts.doors.getVehicleLookPos(veh)
    local dist = fromPos:distance(stand.standPos)
    local lookStart = parts.camera.getCameraLookDir()
    local toVehLook = vehLook and (vehLook - parts.camera.getLookOrigin(fromPos)) or nil
    if toVehLook and toVehLook:length() > 1e-4 then
      toVehLook:normalize()
    else
      toVehLook = nil
    end
    local toStand = (stand.standPos - fromPos):z0()
    if toStand:length() > 1e-4 then toStand:normalize() else toStand = lookStart or vec3(0, 1, 0) end
    return {vehRef = vehRef, dist = dist, lookStart = lookStart, toVehLook = toVehLook, toStand = toStand}
  end

  local function clearStartWaypoint(veh, fromPos, standHull)
    local waypoint = parts.paths.pushOutsideVehicle2D(
      fromPos, veh:getId(), math.max(inputs.config.routeMarginM, inputs.config.bodyClearanceM) + 0.2
    )
    local center = standHull and parts.paths.hullCenter2D(standHull, fromPos.z) or parts.doors.getVehicleOBB(veh:getId())
    local away = center and (waypoint - center):z0() or vec3()
    if away:length() > 1e-4 then
      away:normalize()
      waypoint = waypoint + away * 0.4
    end
    return waypoint
  end

  local function planApproachPath(veh, stand, aim)
    local fromPos, doorInfo, doorCenter = stand.fromPos, stand.doorInfo, stand.doorCenter
    local startPlayerLong = parts.doors.getLongitudinalOffset(veh, fromPos)
    local startDoorLong = parts.doors.getLongitudinalOffset(veh, doorCenter)
    local startSwingClearance = startPlayerLong and startDoorLong
      and (startPlayerLong - startDoorLong) * (doorInfo and doorInfo.safeStandLongSign or -1)
      or nil
    local requiredSwingClearance = doorInfo and doorInfo.controllerName
      and math.max(0.18, (doorInfo.doorSpan or 0.60) * 0.25) or nil
    local alreadyThere = aim.dist <= inputs.config.arriveM
      and (not requiredSwingClearance or not startSwingClearance
        or startSwingClearance >= requiredSwingClearance)
    local standClearance, standEnvelopeSource, standHull, standEnvelope = parts.paths.vehicleClearance2D(
      stand.standPos, veh:getId(), 0
    )
    local startWaypoint = nil
    local startClearance = parts.paths.vehicleClearance2D(fromPos, veh:getId(), 0)
    if not alreadyThere and startClearance < inputs.config.bodyClearanceM then
      startWaypoint = clearStartWaypoint(veh, fromPos, standHull)
    end

    local path = {
      alreadyThere = alreadyThere, standClearance = standClearance, points = {},
      envelopeSource = standEnvelopeSource, hull = standHull, envelope = standEnvelope,
    }
    if alreadyThere then
      path.points[1] = stand.standPos
      return path
    end
    if startWaypoint then
      path.points[#path.points + 1] = startWaypoint
    end
    local builtRoute, builtSource, builtHull, builtEnvelope = parts.paths.buildRoute(
      startWaypoint or fromPos, stand.standPos, veh:getId()
    )
    path.envelopeSource = builtSource or path.envelopeSource
    path.hull = builtHull or path.hull
    path.envelope = builtEnvelope or path.envelope
    for _, point in ipairs(builtRoute) do
      path.points[#path.points + 1] = point
    end
    return path
  end

  local function writeApproachEntryState(result, veh, stand, aim, path, doorCenter, aftFactor, boardDoorLocal)
    result.vehId = veh:getId()
    result.model = veh:getJBeamFilename()
    result.t = 0
    result.arriveT = 0
    result.boardT = 0
    result.phase = path.alreadyThere and "waitDoor" or "approach"
    result.arrived = path.alreadyThere
    result.standPos = stand.standPos
    result.doorCenter = doorCenter
    result.vehRef = aim.vehRef
    result.aftFactor = aftFactor
    result.boardDoorRef = doorCenter and vec3(doorCenter) or nil
    result.boardDoorLocal = boardDoorLocal
    result.boardTarget = path.alreadyThere and parts.doors.getBoardTarget(veh, doorCenter, aftFactor) or nil
  end

  local function writeApproachDoorState(result, stand, doorInfo, doorReferenceLateral)
    result.doorName = stand.doorName
    result.doorSide = doorInfo and doorInfo.side
    result.driverNodeId = doorInfo and doorInfo.driverNodeId
    result.driverLateral = doorInfo and doorInfo.driverLateral
    result.driverHalfWidth = doorInfo and doorInfo.driverHalfWidth
    result.driverSideThreshold = doorInfo and doorInfo.driverSideThreshold
    result.driverSideSource = doorInfo and doorInfo.sideSource
    result.doorTriggerName = doorInfo and doorInfo.triggerName
    result.doorControllerName = doorInfo and doorInfo.controllerName
    result.doorReferenceSource = doorInfo and doorInfo.referenceSource
    result.doorTriggerCenterValid = doorInfo and doorInfo.triggerCenterValid == true
    result.doorTriggerLateral = doorInfo and doorInfo.triggerLateral
    result.doorReferenceLateral = doorReferenceLateral
    result.hingeLongSign = doorInfo and doorInfo.hingeLongSign
    result.safeStandLongSign = doorInfo and doorInfo.safeStandLongSign
    result.doorSpan = doorInfo and doorInfo.doorSpan
    result.doorInfo = doorInfo
  end

  local function writeApproachRouteState(result, unicycle, stand, camera, aim, path, route)
    result.maxDoorGap = 0
    result.doorOpenElapsed = 0
    result.doorProbeCount = 0
    result.nextDoorProbeT = 0
    result.standMargin = stand.standMargin
    result.standClearance = path.standClearance
    result.targetCameraName = camera.targetCameraName
    result.useDriverTransition = camera.useDriverTransition
    result.front = stand.front
    result.speedCoef = parts.camera.captureSpeedCoef(unicycle)
    result.route = route
    result.routeIndex = 1
    result.waypoint = #route > 1 and route[1] or nil
    result.lookDir = aim.lookStart or aim.toVehLook or aim.toStand
  end

  local function writeApproachMeasurements(result, aim, fromPos)
    result.minClearance = math.huge
    result.maxClearance = -math.huge
    result.insideHits = 0
    result.pathLength = 0
    result.stallWindowT = 0
    result.stallWindowPath = 0
    result.collisionRecoveryCount = 0
    result.prevPos = vec3(fromPos)
    result.startDistance = aim.dist
    result.minDistance = aim.dist
    result.maxDistance = aim.dist
    result.speedSum = 0
    result.speedSamples = 0
    result.maxSpeed = 0
    result.lookMoveDotSum = 0
    result.lookCarDotSum = 0
    result.lookSamples = 0
    result.minLookMoveDot = 1
    result.maxLookRateDeg = 0
    result.totalLookTurnDeg = 0
    result.maxCameraTargetErrorDeg = 0
    result.prevActualLook = aim.lookStart and vec3(aim.lookStart) or nil
  end

  local function writeApproachCollisionState(result, path, route, pathEnvelope, pathHull, collisionEnvelope)
    result.waypointCount = math.max(#route - 1, 0)
    result.pathEnvelopeSource = path.envelopeSource
    result.collisionEnvelopePending = collisionEnvelope and collisionEnvelope.pending == true
    result.collisionNodeCount = (pathEnvelope and pathEnvelope.nodeCount)
      or (collisionEnvelope and collisionEnvelope.nodeCount)
    result.collisionTriangleCount = (pathEnvelope and pathEnvelope.triangleCount)
      or (collisionEnvelope and collisionEnvelope.triangleCount)
    result.collisionBodyTriangleCount = (pathEnvelope and pathEnvelope.bodyTriangleCount)
      or (collisionEnvelope and collisionEnvelope.bodyTriangleCount)
    result.collisionDoorTriangleCount = (pathEnvelope and pathEnvelope.doorTriangleCount)
      or (collisionEnvelope and collisionEnvelope.doorTriangleCount)
    result.collisionHullVertexCount = pathHull and #pathHull
      or (pathEnvelope and pathEnvelope.hullVertexCount)
  end

  local function newApproachState(veh, unicycle, stand, camera, aim, path)
    local fromPos, doorInfo, doorCenter, aftFactor = stand.fromPos, stand.doorInfo, stand.doorCenter, stand.aftFactor
    local route, pathEnvelope, pathHull = path.points, path.envelope, path.hull
    local collisionEnvelope = stand.collisionEnvelope
    local boardDoorLocal = doorCenter and parts.doors.worldPointToVehicleLocal(veh, doorCenter) or nil
    local doorReferenceLateral = parts.doors.getLateralOffset(veh, doorCenter)
    local result = {}
    writeApproachEntryState(result, veh, stand, aim, path, doorCenter, aftFactor, boardDoorLocal)
    writeApproachDoorState(result, stand, doorInfo, doorReferenceLateral)
    writeApproachRouteState(result, unicycle, stand, camera, aim, path, route)
    writeApproachMeasurements(result, aim, fromPos)
    writeApproachCollisionState(result, path, route, pathEnvelope, pathHull, collisionEnvelope)
    return result
  end

  local function approachReady(veh)
    if not inputs.isRealisticEntryEnabled() then return false end
    if not inputs.isEnterableVehicle(veh) or not gameplay_walk.isWalking() then return false end
    if not gameplay_walk.isAtParkingSpeed or not gameplay_walk.isAtParkingSpeed() then return false end
    return parts.doors.canAnimateWalkTransition(false)
  end

  -- handled prevents vanilla from repeating a refused entry.
  local function startApproach(veh)
    if not approachReady(veh) then return false end
    runtimeState.lastApproachStats = nil
    local unicycle = gameplay_walk.getCurrentUnicycle()
    if not unicycle then return false end
    local stand = findApproachStand(veh, unicycle)
    if not stand.standPos then return true, inputs.enterVehicleFromWalk(veh, stand.doorInfo) end
    local camera = prepareApproachCamera(veh, unicycle, stand.doorInfo)
    local aim = approachAim(veh, stand)
    local path = planApproachPath(veh, stand, aim)
    runtimeState.approach = newApproachState(veh, unicycle, stand, camera, aim, path)
    guihooks.trigger("Message", {
      ttl = 8,
      msg = "Entering vehicle...",
      category = "walkingmode",
      icon = "seatArrowInLeft"
    })
    return true
  end

  -- Nearest enterable vehicle ---------------------------------------------------------------------

  local NEAREST_ENTERABLE_MAX_DIST = 15

  local function getNearestEnterableVehicle()
    local unicycle = gameplay_walk.getCurrentUnicycle()
    if not unicycle then return nil end
    local pos = unicycle:getPosition()
    local best, bestDist = nil, NEAREST_ENTERABLE_MAX_DIST
    local roughLimit = NEAREST_ENTERABLE_MAX_DIST + 10
    for _, veh in ipairs(getAllVehicles()) do
      if veh:getId() ~= unicycle:getId() and pos:distance(veh:getPosition()) <= roughLimit
        and inputs.isEnterableVehicle(veh) then
        local standPos = parts.paths.getStandPos(veh, pos)
        if standPos then
          local d = pos:distance(standPos)
          if d < bestDist then
            bestDist = d
            best = veh
          end
        end
      end
    end
    return best, bestDist
  end

  -- Part API --------------------------------------------------------------------------------------

  return {
    cancelApproach = cancelApproach,
    finishEnter = finishEnter,
    getNearestEnterableVehicle = getNearestEnterableVehicle,
    scheduleDoorClose = scheduleDoorClose,
    skipApproach = skipApproach,
    startApproach = startApproach,
  }
end

return M
