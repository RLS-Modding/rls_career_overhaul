-- Door and seat geometry, door state and walking input.
-- Read geometry, door selection, door state, then the part API.
local M = {}
local policy = require('overhaul/lib/vehicles/policy')
local passengerSeats = require('overhaul/lib/vehicles/passengerSeats')
local sideClearanceMeters = 0.04

-- Walking input -----------------------------------------------------------------------------------

local function canAnimateWalkTransition(enabled)
  if gameplay_walk.canSetWalkingMode then
    return gameplay_walk.canSetWalkingMode(enabled, false, 0) == true
  end
  if gameplay_walk.canToggleWalkingMode then
    return gameplay_walk.canToggleWalkingMode(false, 0) == true
  end
  return true
end

local function vecToTable(v)
  return v and {x = v.x, y = v.y, z = v.z} or nil
end

local function angleDeg(a, b)
  if not a or not b then return nil end
  return math.deg(math.acos(clamp(a:dot(b), -1, 1)))
end

local function smoothstep01(t)
  t = clamp(t or 0, 0, 1)
  return t * t * (3 - 2 * t)
end

-- Door geometry -----------------------------------------------------------------------------------

local function getVehicleData(veh)
  return veh and core_vehicle_manager.getVehicleData(veh:getId()) or nil
end

-- Rebuild from live reference nodes because trigger centers can retain a replaced vehicle position.
local function getTriggerNodeGeometry(veh, triggerData)
  if not veh or not triggerData or triggerData.idRef == nil then return nil end
  local refNode = veh:getNodePosition(triggerData.idRef)
  if not refNode then return nil end
  local ref = veh:getPosition() + refNode
  local center = vec3(ref)
  local hingeNodeId = triggerData.idX
  local hinge, hingeLongSign, doorSpan

  local xNode = hingeNodeId ~= nil and veh:getNodePosition(hingeNodeId) or nil
  local yNode = triggerData.idY ~= nil and veh:getNodePosition(triggerData.idY) or nil
  if xNode then
    hinge = veh:getPosition() + xNode
    local xAxis = hinge - ref
    doorSpan = xAxis:length()
    if doorSpan > 1e-4 then
      xAxis:setScaled(1 / doorSpan)
      local fwd = veh:getDirectionVector():z0()
      if fwd:length() > 1e-4 then
        fwd:normalize()
        local along = (hinge - ref):z0():dot(fwd)
        if math.abs(along) > 0.05 then hingeLongSign = along > 0 and 1 or -1 end
      end

      if yNode then
        local yRaw = (veh:getPosition() + yNode) - ref
        if yRaw:length() > 1e-4 then
          yRaw:normalize()
          local zAxis = xAxis:cross(yRaw)
          if zAxis:length() > 1e-4 then
            zAxis:normalize()
            local yAxis = zAxis:cross(xAxis)
            yAxis:normalize()
            local base = triggerData.baseTranslation or {}
            local translation = triggerData.translation or {}
            center = ref
              + xAxis * ((tonumber(base.x) or 0) + (tonumber(translation.x) or 0))
              + yAxis * ((tonumber(base.y) or 0) + (tonumber(translation.y) or 0))
              + zAxis * ((tonumber(base.z) or 0) + (tonumber(translation.z) or 0))
          end
        end
      end
    end
  end
  return center, hingeLongSign, doorSpan, hingeNodeId, ref
end

local function getUsableTriggerCenter(veh, triggerObj)
  if not veh or not triggerObj then return nil end
  local center = triggerObj:getCenter()
  if not center then return nil end
  local vehId = veh:getId()
  if be:getObjectOOBBIsInitialized(vehId) then
    local obbCenter = vec3(be:getObjectOOBBCenterXYZ(vehId))
    local extent = 0
    for i = 0, 2 do
      extent = extent + vec3(be:getObjectOOBBHalfAxisXYZ(vehId, i)):length()
    end
    if center:distance(obbCenter) > extent * 1.8 + 2 then
      return nil
    end
  end
  return center
end

local function getDoorTriggerInfo(veh, doorName)
  local vData = getVehicleData(veh)
  local triggers = vData and vData.vdata and vData.vdata.triggers
  if type(triggers) ~= "table" then return nil end
  for _, trg in pairs(triggers) do
    if trg.name == doorName then
      local cid = trg.cid or trg.abid
      local obj = cid ~= nil and veh:getTrigger(cid) or nil
      local center = getTriggerNodeGeometry(veh, trg)
      if not center and obj then center = getUsableTriggerCenter(veh, obj) end
      if center then return center, cid, vData, trg end
    end
  end
  return nil
end

local function getDoorTriggerCenter(veh, doorName)
  local center = getDoorTriggerInfo(veh, doorName)
  return center
end

local function getVehicleLeft2D(veh)
  if not veh then return nil end
  local fwd = veh:getDirectionVector():z0()
  if fwd:length() < 1e-4 then return nil end
  fwd:normalize()
  local left = veh:getDirectionVectorUp():cross(fwd):z0()
  if left:length() < 1e-4 then return nil end
  left:normalize()
  return left
end

local function getLateralOffset(veh, point)
  local left = getVehicleLeft2D(veh)
  if not left or not point then return nil end
  return (point - veh:getPosition()):z0():dot(left)
end

local function getLongitudinalOffset(veh, point)
  if not veh or not point then return nil end
  local fwd = veh:getDirectionVector():z0()
  if fwd:length() < 1e-4 then return nil end
  fwd:normalize()
  return (point - veh:getPosition()):z0():dot(fwd)
end

local function getVehicleHalfWidth2D(veh)
  local left = getVehicleLeft2D(veh)
  if not left then return nil end
  local vehId = veh:getId()
  if not be:getObjectOOBBIsInitialized(vehId) then return nil end
  local extent = 0
  for i = 0, 2 do
    extent = extent + math.abs(vec3(be:getObjectOOBBHalfAxisXYZ(vehId, i)):dot(left))
  end
  return extent
end

local function getVehicleBasis(veh)
  if not veh then return nil end
  local fwd = veh:getDirectionVector()
  local bodyUp = veh:getDirectionVectorUp()
  if fwd:length() < 1e-4 or bodyUp:length() < 1e-4 then return nil end
  fwd:normalize()
  bodyUp:normalize()
  local left = bodyUp:cross(fwd)
  if left:length() < 1e-4 then return nil end
  left:normalize()
  local correctedUp = fwd:cross(left)
  correctedUp:normalize()
  return left, fwd, correctedUp
end

local function worldPointToVehicleLocal(veh, point)
  local left, fwd, bodyUp = getVehicleBasis(veh)
  if not left or not point then return nil end
  local offset = point - veh:getPosition()
  return vec3(offset:dot(left), offset:dot(fwd), offset:dot(bodyUp))
end

local function vehicleLocalPointToWorld(veh, point)
  local left, fwd, bodyUp = getVehicleBasis(veh)
  if not left or not point then return nil end
  return veh:getPosition() + left * point.x + fwd * point.y + bodyUp * point.z
end

local function getDoorSideSign(side)
  return side == "R" and -1 or 1
end

local function isDoorCenterOnSide(veh, center, side)
  local lateral = getLateralOffset(veh, center)
  if lateral == nil then return false, lateral end
  return lateral * getDoorSideSign(side) > 0.04, lateral
end

-- Use driver-node geometry when a stale or wrong-side trigger would route the walker through the body.
local function synthesizeDriverDoorCenter(veh, side, driverWorldPos, driverLateral)
  local left, fwd, bodyUp = getVehicleBasis(veh)
  if not left then return nil end

  local vehPos = veh:getPosition()
  local sign = getDoorSideSign(side)
  local driverLocal = driverWorldPos and worldPointToVehicleLocal(veh, driverWorldPos) or nil
  local targetLong = driverLocal and driverLocal.y or 0
  local targetUp = driverLocal and (driverLocal.z - 0.35) or 0.65
  local targetLateral = math.abs(driverLateral or 0) + 0.30

  local vehId = veh:getId()
  if be:getObjectOOBBIsInitialized(vehId) then
    local obbCenter = vec3(be:getObjectOOBBCenterXYZ(vehId))
    local centerLocal = worldPointToVehicleLocal(veh, obbCenter)
    local sideExtent = 0
    for i = 0, 2 do
      sideExtent = sideExtent + math.abs(vec3(be:getObjectOOBBHalfAxisXYZ(vehId, i)):dot(left))
    end
    local sideBoundary = math.abs((centerLocal and centerLocal.x or 0) + sign * sideExtent)
    -- Cap OBB width relative to the seat so mirrors cannot move the doorway away from the body.
    local driverBase = math.abs(driverLateral or 0)
    targetLateral = math.max(targetLateral, math.min(sideBoundary, driverBase + 0.55))
  end

  targetLateral = math.max(targetLateral, 0.45)
  return vehPos + left * (sign * targetLateral) + fwd * targetLong + bodyUp * targetUp
end

local function isDoorReferenceGeometryValid(veh, center, side, driverWorldPos, driverLateral)
  local onSide, lateral = isDoorCenterOnSide(veh, center, side)
  if not onSide then return false, lateral end

  local fallback = synthesizeDriverDoorCenter(veh, side, driverWorldPos, driverLateral)
  local rawLocal = worldPointToVehicleLocal(veh, center)
  local fallbackLocal = fallback and worldPointToVehicleLocal(veh, fallback) or nil
  if rawLocal and fallbackLocal then
    -- Reject swung-panel centers that have the right sign but lie far outside the closed body.
    if math.abs(rawLocal.x) > math.abs(fallbackLocal.x) + 0.28 then
      return false, lateral
    end
    if math.abs(rawLocal.y - fallbackLocal.y) > 1.25 then
      return false, lateral
    end
  end
  return true, lateral
end

local function scoreFrontDoorName(rawName, side, isController)
  local n = tostring(rawName or ""):lower()
  if n == "" or n:find("_int", 1, true) or n:find("rear", 1, true)
    or n:find("sleeper", 1, true) or n:find("barndoor", 1, true)
    or n:find("tailgate", 1, true) or n:find("engine", 1, true) then
    return nil
  end
  if isController and not n:find("coupler", 1, true) then return nil end

  local compact = n:gsub("[^a-z0-9]", "")
  local wanted = side == "R" and "r" or "l"
  local other = side == "R" and "l" or "r"
  local score
  if compact:find("doorf" .. wanted, 1, true) == 1 then
    score = 140
  elseif compact:find("doorfront" .. wanted, 1, true) == 1 then
    score = 135
  elseif compact:find("door" .. wanted .. "f", 1, true) == 1 then
    score = 130
  elseif compact:find("door" .. wanted, 1, true) == 1 then
    score = 110
  end
  if not score or compact:find("doorf" .. other, 1, true) == 1
    or compact:find("doorfront" .. other, 1, true) == 1 then
    return nil
  end
  if compact:find("doorrr", 1, true) == 1 or compact:find("doorrl", 1, true) == 1 then
    return nil
  end
  if isController and n:find("advanced", 1, true) then score = score + 2 end
  return score
end

-- Driver doorway ----------------------------------------------------------------------------------

local function findDriverDoorControls(veh, side)
  local vData = getVehicleData(veh)
  local vdata = vData and vData.vdata or nil

  local triggerName, triggerCenter, triggerScore = nil, nil, -math.huge
  local hingeLongSign, doorSpan, hingeNodeId, triggerReferencePoint
  for _, trg in pairs(vdata and vdata.triggers or {}) do
    local score = scoreFrontDoorName(trg.name, side, false)
    if score and score > triggerScore then
      local cid = trg.cid or trg.abid
      local obj = cid ~= nil and veh:getTrigger(cid) or nil
      local nodeCenter, nodeHingeLongSign, nodeDoorSpan, nodeHingeId, nodeRef =
        getTriggerNodeGeometry(veh, trg)
      if nodeCenter or obj then
        triggerName = trg.name
        triggerCenter = nodeCenter or getUsableTriggerCenter(veh, obj)
        hingeLongSign = nodeHingeLongSign
        doorSpan = nodeDoorSpan
        hingeNodeId = nodeHingeId
        triggerReferencePoint = nodeRef
        triggerScore = score
      end
    end
  end

  local controllerName, controllerScore = nil, -math.huge
  for _, ctrl in pairs(vdata and vdata.controller or {}) do
    if ctrl.fileName == "advancedCouplerControl" then
      local score = scoreFrontDoorName(ctrl.name, side, true)
      if score and score > controllerScore then
        controllerName = ctrl.name
        controllerScore = score
      end
    end
  end
  return triggerName, triggerCenter, hingeLongSign, doorSpan, hingeNodeId, triggerReferencePoint, controllerName
end

local function readDriverDoorSide(veh, driverNodeId, rightHandDoor)
  local driverWorldPos
  local driverLateral
  if driverNodeId ~= nil then
    local nodePos = veh:getNodePosition(driverNodeId)
    if nodePos then
      driverWorldPos = veh:getPosition() + nodePos
      driverLateral = getLateralOffset(veh, driverWorldPos)
    end
  end
  -- Scale confidence by body width so narrow center-seat and right-hand-drive vehicles keep the correct side.
  local halfWidth = getVehicleHalfWidth2D(veh)
  local driverSideThreshold = math.max(0.04, (halfWidth or 0.45) * 0.18)
  local driverNodeDefinesSide = driverLateral
    and math.abs(driverLateral) > driverSideThreshold
  local side = driverNodeDefinesSide
    and (driverLateral < 0 and "R" or "L")
    or (rightHandDoor and "R" or "L")
  return driverWorldPos, driverLateral, halfWidth, driverSideThreshold, driverNodeDefinesSide, side
end

local function findDriverDoorInfo(veh)
  if not veh then return nil end
  local driverNodeId, rightHandDrive, rightHandDoor = core_camera.getDriverData(veh)
  local driverWorldPos, driverLateral, halfWidth, driverSideThreshold, driverNodeDefinesSide, side = readDriverDoorSide(
    veh, driverNodeId, rightHandDoor
  )
  local canonicalName = "door_" .. side
  local triggerName, triggerCenter, hingeLongSign, doorSpan, hingeNodeId, triggerReferencePoint, controllerName = findDriverDoorControls(
    veh, side
  )

  local triggerCenterValid, triggerLateral = isDoorReferenceGeometryValid(
    veh, triggerCenter, side, driverWorldPos, driverLateral
  )
  local referenceCenter = triggerCenterValid and vec3(triggerCenter)
    or synthesizeDriverDoorCenter(veh, side, driverWorldPos, driverLateral)
  if not referenceCenter and triggerCenter then referenceCenter = vec3(triggerCenter) end
  local referenceLocal = referenceCenter and worldPointToVehicleLocal(veh, referenceCenter) or nil
  local safeStandLongSign = hingeLongSign and -hingeLongSign or -1
  -- The Nine reverses the trigger axis relative to its usable standing pocket.
  if veh:getJBeamFilename() == "nine" and triggerName == "door_FL" then
    safeStandLongSign = -1
  end

  return {
    side = side,
    driverNodeId = driverNodeId,
    driverWorldPos = driverWorldPos,
    driverLateral = driverLateral,
    driverHalfWidth = halfWidth,
    driverSideThreshold = driverSideThreshold,
    sideSource = driverNodeDefinesSide and "driverNode" or "cameraMetadata",
    rightHandDrive = rightHandDrive == true,
    rightHandDoor = rightHandDoor == true,
    canonicalName = canonicalName,
    triggerName = triggerName,
    controllerName = controllerName,
    triggerCenter = triggerCenter,
    triggerCenterValid = triggerCenterValid == true,
    triggerLateral = triggerLateral,
    triggerReferencePoint = triggerReferencePoint,
    hingeLongSign = hingeLongSign,
    safeStandLongSign = safeStandLongSign,
    doorSpan = doorSpan,
    hingeNodeId = hingeNodeId,
    center = referenceCenter,
    referenceLocal = referenceLocal,
    referenceSource = triggerCenterValid and "triggerNodes" or "driverNodeFallback"
  }
end

local function findEntryDoorInfo(veh, fromPos)
  local driver = findDriverDoorInfo(veh)
  if not driver or not policy.hasRole('hiredPassenger', veh:getId()) then return driver end
  local data = getVehicleData(veh)
  local vdata = data and data.vdata or {}
  local driverLong = getLongitudinalOffset(veh, driver.driverWorldPos or driver.center)
  local best, bestRank, bestDistance
  for _, trigger in pairs(vdata.triggers or {}) do
    local name = tostring(trigger.name or ''):lower()
    -- Only cabin doors; internal handles and cargo/engine closures are not entry points.
    if name:find('door', 1, true) and not name:find('_int', 1, true)
        and not name:find('tailgate', 1, true) and not name:find('barndoor', 1, true)
        and not name:find('engine', 1, true) and not name:find('sleeper', 1, true) then
      local center, hinge, span, hingeId, ref = getTriggerNodeGeometry(veh, trigger)
      if not center then center = getDoorTriggerCenter(veh, trigger.name) end
      local lateral = getLateralOffset(veh, center)
      local along = getLongitudinalOffset(veh, center)
      if lateral and math.abs(lateral) > sideClearanceMeters and along and driverLong then
        local side = lateral > 0 and 'L' or 'R'
        local compact = name:gsub('[^a-z0-9]', '')
        local rear = compact:match('^doorr[lr]') or compact:find('rear', 1, true)
          or (not scoreFrontDoorName(trigger.name, side, false) and along < driverLong - passengerSeats.rearRowSeparationMeters)
        local rank = rear and 1 or (side ~= driver.side and 2 or nil)
        local distance = center:distance(fromPos or veh:getPosition())
        if rank and (not best or rank < bestRank or (rank == bestRank
            and (distance < bestDistance or (distance == bestDistance and trigger.name < best.triggerName)))) then
          local controllerName
          local actions = {[compact] = true}
          -- Trigger labels and controls need not share a name (e.g. split side doors).
          local links = vdata.triggerEventLinksDict and vdata.triggerEventLinksDict[trigger.cid or trigger.abid]
          for _, group in pairs(links or {}) do
            for _, link in pairs(group) do
              if type(link.inputAction) == 'string' then
                actions[link.inputAction:lower():gsub('[^a-z0-9]', '')] = true
              end
            end
          end
          for _, ctrl in pairs(vdata.controller or {}) do
            local ctrlName = tostring(ctrl.name or ''):lower():gsub('[^a-z0-9]', '')
            if ctrl.fileName == 'advancedCouplerControl' and actions[ctrlName:gsub('coupler$', '')] then
              controllerName = ctrl.name; break
            end
          end
          best = {side = side, canonicalName = trigger.name, triggerName = trigger.name,
            controllerName = controllerName, center = vec3(center), triggerCenter = center,
            triggerCenterValid = true, triggerLateral = lateral, triggerReferencePoint = ref,
            referenceLocal = worldPointToVehicleLocal(veh, center), referenceSource = 'passengerDoorNodes',
            sideSource = 'passengerDoor', hingeLongSign = hinge, safeStandLongSign = hinge and -hinge or -1,
            doorSpan = span, hingeNodeId = hingeId, passenger = true}
          bestRank, bestDistance = rank, distance
        end
      end
    end
  end
  -- A service without usable doors keeps the existing doorway, but still boards as a passenger.
  best = best or driver
  best.passenger = true
  best.passengerSeat = passengerSeats.forDoor(veh:getId(), best.side)
  return best
end

local function getClosestDoorName(veh, fromPos)
  local info = findEntryDoorInfo(veh, fromPos)
  if not info then return nil end
  return info.triggerName or info.canonicalName, info.center, info
end

local function getDriverDoorSideAlignment(veh, playerPos, doorInfo, doorCenter)
  if not veh or not playerPos then return nil end
  local playerLateral = getLateralOffset(veh, playerPos)
  local driverLateral = doorInfo and doorInfo.sideSource == "driverNode"
    and doorInfo.driverLateral or nil
  local doorLateral = getLateralOffset(veh, doorCenter)
  local expectedLateral = driverLateral
  if not expectedLateral or math.abs(expectedLateral) <= 0.08 then
    expectedLateral = doorLateral
  end
  if (not expectedLateral or math.abs(expectedLateral) <= 0.08) and doorInfo then
    expectedLateral = doorInfo.side == "R" and -1 or 1
  end
  if playerLateral == nil or expectedLateral == nil then
    return nil, playerLateral, expectedLateral, doorLateral
  end
  -- Compare clearance in metres; the reference offset only selects a side.
  local expectedSide = expectedLateral < 0 and -1 or 1
  local playerAligned = playerLateral * expectedSide > sideClearanceMeters
  local doorAligned = doorLateral ~= nil and doorLateral * expectedSide > sideClearanceMeters
  return playerAligned and doorAligned,
    playerLateral, expectedLateral, doorLateral
end

-- Door state --------------------------------------------------------------------------------------

local function copyStateFields(target, source, keys, mode)
  for key in string.gmatch(keys, "%S+") do
    local value = source[key]
    if mode == "bool" then value = value == true end
    if mode == "zero" then value = value or 0 end
    target[key] = value
  end
end

local function copyDoorStats(stats, state)
  if not stats or not state then return end
  copyStateFields(stats, state, [[doorStateAfter doorOpenStateAfter doorCloseStateAfter
  doorGap doorOpenForceDuration doorCloseForceDuration doorFullEvidence]])
  copyStateFields(stats, state, [[doorControllerFound doorOpened doorClosed
  doorPhysicalMeasured doorFullyOpened doorOpenTimedOut]], "bool")
  copyStateFields(stats, state, "maxDoorGap doorStableProbes", "zero")
  stats.doorOpenWait = state.doorOpenWait or state.doorOpenElapsed or 0
  stats.doorCloseAttempts = (state.closeRetryCount or 0) + (state.closeCommanded and 1 or 0)
end

local function markDoorFullyOpen(state, evidence)
  if not state or state.doorFullyOpened then return end
  state.doorFullyOpened = true
  state.doorOpenReady = true
  state.doorFullEvidence = evidence
  state.doorOpenWait = state.doorOpenElapsed or 0
  state.doorFullyOpenT = state.t or 0
end

local DOOR_STATE_COMMAND = [[
    local c = controller.getControllerSafe(%s)
    local wantOpen = %s
    local probeOnly = %s
    local cfg = v.data and v.data[%s] or nil
    if not cfg and v.data and v.data.controller then
      for _, row in pairs(v.data.controller) do
        if type(row) == "table" and row.name == %s then cfg = row break end
      end
    end
    local closeForce = cfg and tonumber(cfg.closeForceMagnitude) or 0
    local closeDuration = cfg and tonumber(cfg.closeForceDuration) or 0
    local gentleClose = closeForce > 0 and closeForce <= 60 and closeDuration >= 0.6
    local found = c ~= nil and c.getGroupState ~= nil
    local before = found and c.getGroupState() or nil
    if found and not probeOnly then
      local closed = (before == "attached" or before == "desyncedAttached")
      if wantOpen then
        if closed and c.detachGroup then c.detachGroup() end
      else
        if not closed and not gentleClose and c.tryAttachGroupImpulse then c.tryAttachGroupImpulse() end
      end
    end
    local after = found and c.getGroupState() or nil
    local duration = cfg and tonumber(cfg.openForceDuration) or -1
    local maxGap = -1
    if cfg and type(cfg.couplerNodes) == "table" and beamstate and beamstate.nodeNameMap then
      local rows = tableFromHeaderTable(cfg.couplerNodes)
      for _, row in ipairs(rows or {}) do
        local cid1 = beamstate.nodeNameMap[row.cid1] or tonumber(row.cid1)
        local cid2 = beamstate.nodeNameMap[row.cid2] or tonumber(row.cid2)
        if cid1 and cid2 then
          local nodeGap = obj:nodeLength(cid1, cid2)
          if nodeGap and nodeGap > maxGap then maxGap = nodeGap end
          if not wantOpen and found and after ~= "broken" and gentleClose then
            -- Register the stock latch, then taper closing force near it to avoid damaging light doors.
            if not probeOnly then
              obj:attachLocalCoupler(
                cid1, cid2,
                tonumber(row.autoCouplingStrength) or 35000,
                tonumber(row.autoCouplingRadius) or 0.01,
                tonumber(row.autoCouplingLockRadius) or 0.005,
                tonumber(row.autoCouplingSpeed) or 0.2,
                true
              )
            end
            local maxScale = closeDuration >= 1.0 and 0.80 or 0.55
            local gapRatio = math.min(math.max((nodeGap - 0.01) / 0.40, 0), 1)
            local forceScale = 0.16 + (maxScale - 0.16) * gapRatio
            obj:applyForceTime(cid2, cid1, closeForce * forceScale, 0.10)
          elseif not wantOpen and not probeOnly and found and after ~= "broken"
            and nodeGap and nodeGap <= 0.025 and closeForce >= 75 then
            -- Let heavy panels catch at 2.5 cm when they stop just outside the stock latch radius.
            obj:attachLocalCoupler(
              cid1, cid2,
              tonumber(row.autoCouplingStrength) or 35000,
              math.max(tonumber(row.autoCouplingRadius) or 0.01, 0.025),
              tonumber(row.autoCouplingLockRadius) or 0.005,
              tonumber(row.autoCouplingSpeed) or 0.2,
              true
            )
          end
        end
      end
    end
    obj:queueGameEngineLua(require('vehicle/overhaul/geCallback').reply(%d, 'walkInDoorState', string.format(%s, tostring(found), serialize(before), serialize(after), tostring(maxGap), tostring(duration), tostring(closeDuration))))
  ]]

local function ensureDoorState(veh, controllerName, wantOpen, transitionType, probeOnly)
  if not veh or not controllerName then return false end
  local callback = string.format(
    "%d,%s,%s,%s,%%s,%%s,%%s,%%s,%%s,%%s",
    veh:getId(), serialize(transitionType or "entry"), serialize(controllerName), wantOpen and "true" or "false"
  )
  veh:queueLuaCommand(string.format(DOOR_STATE_COMMAND, serialize(controllerName), wantOpen and "true" or "false", probeOnly and "true" or "false", serialize(controllerName), serialize(controllerName),
    require('overhaul/lib/vehicles/callbacks').open('walkInDoorState', {owner = 'walkEnterVehicle', vehId = veh:getId()}), serialize(callback)))
  return true
end

-- Boarding geometry -------------------------------------------------------------------------------

local function getVehicleOBB(vehId)
  if not be:getObjectOOBBIsInitialized(vehId) then return nil end
  local center = vec3()
  local axis0 = vec3()
  local axis1 = vec3()
  local axis2 = vec3()
  center:set(be:getObjectOOBBCenterXYZ(vehId))
  axis0:set(be:getObjectOOBBHalfAxisXYZ(vehId, 0))
  axis1:set(be:getObjectOOBBHalfAxisXYZ(vehId, 1))
  axis2:set(be:getObjectOOBBHalfAxisXYZ(vehId, 2))
  return center, axis0, axis1, axis2
end

local function getVehicleRefPos(veh)
  return veh:getPosition()
end

local function getVehicleLookPos(veh)
  local ref = getVehicleRefPos(veh)
  local center = getVehicleOBB(veh:getId())
  if center then
    return vec3(ref.x, ref.y, center.z)
  end
  return ref + vec3(0, 0, 1.0)
end

local function getBoardTarget(veh, doorRef, aftFactor)
  local vehRef = getVehicleRefPos(veh)
  if not vehRef then return nil end
  if not doorRef then return vec3(vehRef) end
  local t = 0.5 + 0.25 * clamp(aftFactor or 0, 0, 1)
  return doorRef + (vehRef - doorRef) * t
end

local function getBoardLookPos(veh, doorRef, aftFactor)
  local mid = getBoardTarget(veh, doorRef, aftFactor)
  if not mid then return nil end
  local center = getVehicleOBB(veh:getId())
  if center then
    return vec3(mid.x, mid.y, center.z)
  end
  return mid + vec3(0, 0, 1.0)
end

local function getDoorLookPos(veh, doorCenter)
  if not doorCenter then return nil end
  local center = getVehicleOBB(veh:getId())
  if center then
    -- Aim above a low latch so the panel and cabin stay in frame at walking eye height.
    return vec3(doorCenter.x, doorCenter.y, center.z + 0.55)
  end
  return doorCenter + vec3(0, 0, 1.0)
end

-- Blend in the body to make the exit direction readable without losing the open door.
local function getExitDoorLookPos(veh, doorCenter)
  local doorLook = getDoorLookPos(veh, doorCenter)
  local vehLook = getVehicleLookPos(veh)
  if doorLook and vehLook then
    local target = doorLook * 0.45 + vehLook * 0.55
    target.z = doorLook.z
    return target
  end
  return doorLook or vehLook
end

-- Part API ----------------------------------------------------------------------------------------

function M.new(inputs)
  local config, lastExternal = inputs.config, inputs.lastExternal
  local runtimeState = inputs.state

  local function clearExternalMove(unicycle)
    if not unicycle then return end
    lastExternal.x, lastExternal.y, lastExternal.speed = nil, nil, nil
    unicycle:queueLuaCommand("controller.getControllerSafe('overhaulPlayerController').setExternalWorldMove(nil)")
  end

  local function setExternalMove(unicycle, x, y, speedCoef)
    if not unicycle then return end
    if lastExternal.x == x and lastExternal.y == y and lastExternal.speed == speedCoef then
      return
    end
    lastExternal.x, lastExternal.y, lastExternal.speed = x, y, speedCoef
    unicycle:queueLuaCommand(string.format(
      "controller.getControllerSafe('overhaulPlayerController').setExternalWorldMove(%s,%s,%s)",
      tostring(x), tostring(y), tostring(speedCoef)
    ))
  end

  local function notePlayerMove(speedCoef, walkLen)
    runtimeState.lastSpeedCoef = tonumber(speedCoef) or 0
    runtimeState.lastWalkLen = tonumber(walkLen) or 0
  end

  local function isDoorOpenReady(state)
    if not state then return true end
    if state.doorOpenReady or state.doorFullyOpened then return true end
    local elapsed = state.doorOpenElapsed or 0
    local controllerName = state.doorControllerName or state.controllerName
    if not controllerName then
      if elapsed >= config.doorFallbackOpenS then
        state.doorOpenReady = true
        state.doorFullEvidence = "noController"
        state.doorOpenWait = elapsed
      end
      return state.doorOpenReady == true
    end
    if state.doorControllerFound == false and (state.doorProbeCount or 0) > 0 then
      if elapsed >= config.doorFallbackOpenS then
        state.doorOpenReady = true
        state.doorFullEvidence = "controllerUnavailable"
        state.doorOpenWait = elapsed
      end
      return state.doorOpenReady == true
    end

    local forceDuration = math.max(state.doorOpenForceDuration or 0.20, 0.08)
    if state.doorPhysicalMeasured then
      local gap = state.doorGap or 0
      local stable = state.doorStableProbes or 0
      if gap >= 0.08 and elapsed >= math.max(0.36, forceDuration + 0.08) and stable >= 2 then
        markDoorFullyOpen(state, "physicalSettle")
      elseif math.max(gap, state.maxDoorGap or 0) >= 0.08
        and elapsed >= math.max(0.72, forceDuration + 0.30) then
        -- Long-settled motion is stronger evidence than latch separation for narrow scissor-door couplers.
        markDoorFullyOpen(state, "physicalGapAndLongSettle")
      end
    elseif state.doorControllerFound == true then
      -- Legacy controllers without node pairs still provide a force duration that gates full opening.
      if elapsed >= math.max(0.52, forceDuration + config.doorSwingSettleS) then
        markDoorFullyOpen(state, "configuredDuration")
      end
    end

    local hardLimit = math.max(config.doorOpenTimeoutS, forceDuration + 1.0)
    if not state.doorOpenReady and elapsed >= hardLimit then
      state.doorOpenTimedOut = true
      state.doorOpenReady = true
      state.doorOpenWait = elapsed
      state.doorFullEvidence = "hardLimit"
    end
    return state.doorOpenReady == true
  end

  local function getDoorCloseRetryInterval(state)
    return math.max(
      config.doorCloseRetryS,
      (state and state.doorCloseForceDuration or 0.6) + 0.25
    )
  end

  local function noteDoorState(vehId, transitionType, controllerName, wantOpen, found, beforeState, afterState, gap, openForceDuration, closeForceDuration)
    local state = transitionType == "exit" and (runtimeState.exitTransition or runtimeState.postExit) or (runtimeState.approach or runtimeState.postEnter)
    if not state or state.vehId ~= vehId then return end
    state.doorControllerFound = found == true
    state.doorStateBefore = state.doorStateBefore or beforeState
    state.doorStateAfter = afterState
    local duration = tonumber(openForceDuration)
    if duration and duration >= 0 then state.doorOpenForceDuration = duration end
    local closeDuration = tonumber(closeForceDuration)
    if closeDuration and closeDuration >= 0 then state.doorCloseForceDuration = closeDuration end
    local physicalGap = tonumber(gap)
    if physicalGap and physicalGap >= 0 then
      state.doorPhysicalMeasured = true
      state.doorGap = physicalGap
      state.maxDoorGap = math.max(state.maxDoorGap or 0, physicalGap)
      if wantOpen then
        local previous = state.previousDoorGap
        local tolerance = math.max(0.018, physicalGap * 0.018)
        if previous and math.abs(physicalGap - previous) <= tolerance then
          state.doorStableProbes = (state.doorStableProbes or 0) + 1
        else
          state.doorStableProbes = 0
        end
        state.previousDoorGap = physicalGap
      end
    end
    if wantOpen then
      state.doorOpenStateAfter = afterState
    else
      state.doorCloseStateAfter = afterState
    end
    state.doorOpened = wantOpen and found == true
      and afterState ~= "attached" and afterState ~= "desyncedAttached"
      or state.doorOpened
    state.doorClosed = (not wantOpen) and found == true
      and (afterState == "attached" or afterState == "desyncedAttached")
      or state.doorClosed
    if wantOpen then isDoorOpenReady(state) end
    if state == runtimeState.postEnter and runtimeState.lastApproachStats then
      copyDoorStats(runtimeState.lastApproachStats, state)
    end
    if state == runtimeState.postExit and runtimeState.lastExitStats then
      copyDoorStats(runtimeState.lastExitStats, state)
    end
  end

  local function holdEntryDoorOpen(veh, dt)
    runtimeState.approach.entryDoorHoldT = (runtimeState.approach.entryDoorHoldT or 0) + dt
    if runtimeState.approach.doorControllerName
      and runtimeState.approach.entryDoorHoldT >= config.doorProbeIntervalS then
      runtimeState.approach.entryDoorHoldT = 0
      ensureDoorState(veh, runtimeState.approach.doorControllerName, true, "entry")
      runtimeState.approach.doorProbeCount = (runtimeState.approach.doorProbeCount or 0) + 1
    end
  end

  return {
    angleDeg = angleDeg,
    canAnimateWalkTransition = canAnimateWalkTransition,
    clearExternalMove = clearExternalMove,
    copyDoorStats = copyDoorStats,
    copyStateFields = copyStateFields,
    ensureDoorState = ensureDoorState,
    findDriverDoorInfo = findDriverDoorInfo,
    findEntryDoorInfo = findEntryDoorInfo,
    getBoardLookPos = getBoardLookPos,
    getBoardTarget = getBoardTarget,
    getClosestDoorName = getClosestDoorName,
    getDoorCloseRetryInterval = getDoorCloseRetryInterval,
    getDoorLookPos = getDoorLookPos,
    getDoorTriggerCenter = getDoorTriggerCenter,
    getDriverDoorSideAlignment = getDriverDoorSideAlignment,
    getExitDoorLookPos = getExitDoorLookPos,
    getLateralOffset = getLateralOffset,
    getLongitudinalOffset = getLongitudinalOffset,
    getVehicleBasis = getVehicleBasis,
    getVehicleLeft2D = getVehicleLeft2D,
    getVehicleLookPos = getVehicleLookPos,
    getVehicleOBB = getVehicleOBB,
    getVehicleRefPos = getVehicleRefPos,
    holdEntryDoorOpen = holdEntryDoorOpen,
    isDoorCenterOnSide = isDoorCenterOnSide,
    isDoorOpenReady = isDoorOpenReady,
    noteDoorState = noteDoorState,
    notePlayerMove = notePlayerMove,
    setExternalMove = setExternalMove,
    smoothstep01 = smoothstep01,
    vecToTable = vecToTable,
    vehicleLocalPointToWorld = vehicleLocalPointToWorld,
    worldPointToVehicleLocal = worldPointToVehicleLocal,
  }
end

return M
