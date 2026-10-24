-- Walking paths: collision hulls, stand and doorway positions, routes and statistics.
-- Read hull geometry, routing, collision requests, doorway positions, then statistics and the part API.
local M = {}

function M.new(inputs)
  local runtimeState = inputs.state
  local parts = inputs.parts

  -- Hull geometry ---------------------------------------------------------------------------------

  local function getOBBBasis2D(center, axis0, axis1, margin)
    local c2 = center:z0()
    local u0 = axis0:z0()
    local u1 = axis1:z0()
    local len0 = u0:length()
    local len1 = u1:length()
    if len0 < 1e-4 or len1 < 1e-4 then return nil end
    u0:setScaled(1 / len0)
    u1:setScaled(1 / len1)
    return c2, u0, u1, len0 + (margin or 0), len1 + (margin or 0)
  end

  local function localOBBCoords(point, c2, u0, u1)
    local d = point:z0() - c2
    return d:dot(u0), d:dot(u1)
  end

  local function obbClearance2D(point, center, axis0, axis1, margin)
    local c2, u0, u1, e0, e1 = getOBBBasis2D(center, axis0, axis1, margin)
    if not c2 then return math.huge end
    local x, y = localOBBCoords(point, c2, u0, u1)
    local dx = math.abs(x) - e0
    local dy = math.abs(y) - e1
    if dx > 0 or dy > 0 then
      local outsideX = math.max(dx, 0)
      local outsideY = math.max(dy, 0)
      return math.sqrt(outsideX * outsideX + outsideY * outsideY)
    end
    return math.max(dx, dy)
  end

  local function pushOutsideOBB2D(point, center, axis0, axis1, margin)
    local c2, u0, u1, e0, e1 = getOBBBasis2D(center, axis0, axis1, margin)
    if not c2 then return point:z0() end
    local x, y = localOBBCoords(point, c2, u0, u1)
    if math.abs(x) > e0 or math.abs(y) > e1 then
      return vec3(point.x, point.y, point.z)
    end
    local pushX = (e0 - math.abs(x)) + 0.05
    local pushY = (e1 - math.abs(y)) + 0.05
    local out
    if pushX < pushY then
      out = c2 + u0 * ((x >= 0 and 1 or -1) * e0) + u1 * y
    else
      out = c2 + u0 * x + u1 * ((y >= 0 and 1 or -1) * e1)
    end
    return vec3(out.x, out.y, point.z)
  end

  local function cross2D(a, b, c)
    return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
  end

  local function convexHull2D(points)
    if #points < 3 then return nil end
    table.sort(points, function(a, b)
      return a.x < b.x or (a.x == b.x and a.y < b.y)
    end)

    local unique = {}
    local lastX, lastY
    for _, point in ipairs(points) do
      if not lastX or math.abs(point.x - lastX) > 0.005 or math.abs(point.y - lastY) > 0.005 then
        unique[#unique + 1] = point
        lastX, lastY = point.x, point.y
      end
    end
    if #unique < 3 then return nil end

    local lower = {}
    for _, point in ipairs(unique) do
      while #lower >= 2 and cross2D(lower[#lower - 1], lower[#lower], point) <= 1e-7 do
        lower[#lower] = nil
      end
      lower[#lower + 1] = point
    end

    local upper = {}
    for i = #unique, 1, -1 do
      local point = unique[i]
      while #upper >= 2 and cross2D(upper[#upper - 1], upper[#upper], point) <= 1e-7 do
        upper[#upper] = nil
      end
      upper[#upper + 1] = point
    end

    lower[#lower] = nil
    upper[#upper] = nil
    for _, point in ipairs(upper) do lower[#lower + 1] = point end
    return #lower >= 3 and lower or nil
  end

  local function getCollisionHull(vehId, pathZ)
    local envelope = runtimeState.collisionEnvelopes[vehId]
    if not envelope or type(envelope.nodeIds) ~= "table" or #envelope.nodeIds < 3 then
      return nil, envelope
    end
    pathZ = tonumber(pathZ) or 0
    local now = os.clock()
    if envelope.hull and envelope.hullZ
      and math.abs(envelope.hullZ - pathZ) < 0.2
      and now - (envelope.hullClock or 0) <= inputs.config.hullCacheTimeS then
      return envelope.hull, envelope
    end

    local veh = getObjectByID(vehId)
    if not veh then return nil, envelope end
    local ref = veh:getPosition()
    local points, allPoints = {}, {}
    for _, nodeId in ipairs(envelope.nodeIds) do
      local nodePos = veh:getNodePosition(nodeId)
      if nodePos then
        local world = ref + nodePos
        local flat = vec3(world.x, world.y, pathZ)
        allPoints[#allPoints + 1] = flat
        if world.z >= pathZ - inputs.config.collisionHeightBelowM
          and world.z <= pathZ + inputs.config.collisionHeightAboveM then
          points[#points + 1] = flat
        end
      end
    end
    if #points < 3 then points = allPoints end
    local hull = convexHull2D(points)
    if hull then
      envelope.hull = hull
      envelope.hullZ = pathZ
      envelope.hullClock = now
      envelope.hullVertexCount = #hull
    end
    return hull, envelope
  end

  local function closestPointOnSegment2D(point, a, b)
    local ab = b - a
    ab.z = 0
    local lenSq = ab:squaredLength()
    if lenSq < 1e-9 then return vec3(a) end
    local t = clamp(((point - a):z0()):dot(ab) / lenSq, 0, 1)
    local result = a + ab * t
    result.z = point.z
    return result
  end

  local function hullSignedClearance2D(point, hull)
    if not hull or #hull < 3 then return math.huge end
    local inside = true
    local closest, minDistance = nil, math.huge
    for i = 1, #hull do
      local a = hull[i]
      local b = hull[i % #hull + 1]
      if cross2D(a, b, point) < -1e-6 then inside = false end
      local candidate = closestPointOnSegment2D(point, a, b)
      local distance = candidate:distance(point)
      if distance < minDistance then
        minDistance, closest = distance, candidate
      end
    end
    return inside and -minDistance or minDistance, closest, inside
  end

  local function hullCenter2D(hull, z)
    local center = vec3(0, 0, z or 0)
    for _, point in ipairs(hull or {}) do
      center.x = center.x + point.x
      center.y = center.y + point.y
    end
    if hull and #hull > 0 then
      center.x = center.x / #hull
      center.y = center.y / #hull
    end
    return center
  end

  local function pushOutsideHull2D(point, hull, margin)
    margin = margin or 0
    local clearance, closest, inside = hullSignedClearance2D(point, hull)
    if not closest or clearance >= margin then return vec3(point) end
    local outward
    if inside then
      outward = (closest - point):z0()
    else
      outward = (point - closest):z0()
    end
    if outward:length() < 1e-4 then
      outward = (closest - hullCenter2D(hull, point.z)):z0()
    end
    if outward:length() < 1e-4 then outward = vec3(1, 0, 0) else outward:normalize() end
    local result = closest + outward * (margin + 0.05)
    result.z = point.z
    return result
  end

  local function vehicleClearance2D(point, vehId, margin)
    local hull, envelope = getCollisionHull(vehId, point.z)
    if hull then
      local clearance = hullSignedClearance2D(point, hull)
      return clearance - (margin or 0), "collisionHull", hull, envelope
    end
    local center, axis0, axis1 = parts.doors.getVehicleOBB(vehId)
    if center then
      return obbClearance2D(point, center, axis0, axis1, margin), "obbFallback", nil, envelope
    end
    return math.huge, "none", nil, envelope
  end

  local function pushOutsideVehicle2D(point, vehId, margin)
    local hull = getCollisionHull(vehId, point.z)
    if hull then return pushOutsideHull2D(point, hull, margin), "collisionHull" end
    local center, axis0, axis1 = parts.doors.getVehicleOBB(vehId)
    if center then
      return pushOutsideOBB2D(point, center, axis0, axis1, margin), "obbFallback"
    end
    return vec3(point), "none"
  end

  local function segmentsIntersect2D(a, b, c, d)
    local abC, abD = cross2D(a, b, c), cross2D(a, b, d)
    local cdA, cdB = cross2D(c, d, a), cross2D(c, d, b)
    if abC * abD > 1e-8 or cdA * cdB > 1e-8 then return false end
    return math.max(math.min(a.x, b.x), math.min(c.x, d.x))
        <= math.min(math.max(a.x, b.x), math.max(c.x, d.x)) + 1e-6
      and math.max(math.min(a.y, b.y), math.min(c.y, d.y))
        <= math.min(math.max(a.y, b.y), math.max(c.y, d.y)) + 1e-6
  end

  local function segmentDistance2D(a, b, c, d)
    if segmentsIntersect2D(a, b, c, d) then return 0 end
    return math.min(
      a:distance(closestPointOnSegment2D(a, c, d)),
      b:distance(closestPointOnSegment2D(b, c, d)),
      c:distance(closestPointOnSegment2D(c, a, b)),
      d:distance(closestPointOnSegment2D(d, a, b))
    )
  end

  local function segmentHitsHull2D(a, b, hull, margin)
    margin = margin or 0
    if hullSignedClearance2D(a, hull) < margin - 0.01
      or hullSignedClearance2D(b, hull) < margin - 0.01 then
      return true
    end
    for i = 1, #hull do
      local c = hull[i]
      local d = hull[i % #hull + 1]
      if segmentDistance2D(a, b, c, d) < margin - 0.01 then return true end
    end
    return false
  end

  local function expandHullVertices(hull, margin, z)
    local expanded = {}
    local amount = (margin or 0) + 0.10
    for i = 1, #hull do
      local prev = hull[(i - 2) % #hull + 1]
      local current = hull[i]
      local nextPoint = hull[i % #hull + 1]
      local prevEdge = (current - prev):z0()
      local nextEdge = (nextPoint - current):z0()
      if prevEdge:length() > 1e-5 then prevEdge:normalize() end
      if nextEdge:length() > 1e-5 then nextEdge:normalize() end
      local prevNormal = vec3(prevEdge.y, -prevEdge.x, 0)
      local nextNormal = vec3(nextEdge.y, -nextEdge.x, 0)
      local bisector = prevNormal + nextNormal
      if bisector:length() < 1e-4 then bisector = prevNormal else bisector:normalize() end
      local denominator = math.max(0.18, math.min(
        math.abs(bisector:dot(prevNormal)),
        math.abs(bisector:dot(nextNormal))
      ))
      local point = current + bisector * (amount / denominator)
      point.z = z
      expanded[#expanded + 1] = point
    end
    return expanded
  end

  -- Hull routes -----------------------------------------------------------------------------------

  local function findHullRoutePredecessors(hull, margin, nodes)
    local goalIndex = #nodes
    local distances, previous, visited = {}, {}, {}
    for i = 1, #nodes do distances[i] = math.huge end
    distances[1] = 0

    for _ = 1, #nodes do
      local current, best = nil, math.huge
      for i = 1, #nodes do
        if not visited[i] and distances[i] < best then current, best = i, distances[i] end
      end
      if not current then break end
      if current == goalIndex then break end
      visited[current] = true
      for nextIndex = 1, #nodes do
        if nextIndex ~= current and not visited[nextIndex]
          and not segmentHitsHull2D(nodes[current], nodes[nextIndex], hull, margin) then
          local candidate = distances[current] + nodes[current]:distance(nodes[nextIndex])
          if candidate < distances[nextIndex] then
            distances[nextIndex] = candidate
            previous[nextIndex] = current
          end
        end
      end
    end
    return goalIndex, distances, previous
  end

  local function buildCollisionHullRoute(pos, goal, hull, requestedMargin)
    local margin = requestedMargin or inputs.config.routeMarginM
    local start = vec3(pos)
    local prefix = {}
    if hullSignedClearance2D(start, hull) < margin + 0.04 then
      local recoveryPad = requestedMargin and 0.06 or 0.24
      local safeStart = pushOutsideHull2D(start, hull, margin + recoveryPad)
      if safeStart:distance(start) > 0.04 then
        prefix[#prefix + 1] = vec3(safeStart)
        start = safeStart
      end
    end
    goal = pushOutsideHull2D(goal, hull, margin)
    if requestedMargin then
      -- Dense projected samples avoid cutting through rounded running boards between otherwise clear endpoints.
      local sampleCount = math.max(2, math.ceil(start:distance(goal) / 0.07))
      local route = prefix
      for i = 1, sampleCount do
        local t = i / sampleCount
        local sample = start * (1 - t) + goal * t
        sample = pushOutsideHull2D(sample, hull, margin)
        if #route == 0 or route[#route]:distance(sample) > 0.025 then
          route[#route + 1] = sample
        end
      end
      return #route > 0 and route or {vec3(goal)}
    end
    if not segmentHitsHull2D(start, goal, hull, margin) then
      prefix[#prefix + 1] = vec3(goal)
      return prefix
    end

    local expanded = expandHullVertices(hull, margin, pos.z)
    local nodes = {vec3(start)}
    for _, point in ipairs(expanded) do nodes[#nodes + 1] = point end
    nodes[#nodes + 1] = vec3(goal)
    local goalIndex, distances, previous = findHullRoutePredecessors(hull, margin, nodes)

    if distances[goalIndex] == math.huge then
      prefix[#prefix + 1] = vec3(goal)
      return prefix
    end
    local reverse, cursor = {}, goalIndex
    while cursor and cursor ~= 1 do
      reverse[#reverse + 1] = vec3(nodes[cursor])
      cursor = previous[cursor]
    end
    local route = prefix
    for i = #reverse, 1, -1 do route[#route + 1] = reverse[i] end
    return #route > 0 and route or {vec3(goal)}
  end

  -- Collision requests ----------------------------------------------------------------------------

  local function requestCollisionEnvelope(veh, force)
    if not veh or veh:getJBeamFilename() == "unicycle" then return nil end
    local vehId = veh:getId()
    local existing = runtimeState.collisionEnvelopes[vehId]
    if existing and not force and (existing.pending or existing.nodeIds) then return existing end

    runtimeState.collisionEnvelopeRequestId = runtimeState.collisionEnvelopeRequestId + 1
    local requestId = runtimeState.collisionEnvelopeRequestId
    runtimeState.collisionEnvelopes[vehId] = {
      vehicleId = vehId,
      requestId = requestId,
      pending = true,
      requestedAt = os.clock(),
      model = veh:getJBeamFilename(),
      -- Retain usable topology while refreshed live triangles arrive from the vehicle VM.
      nodeIds = existing and existing.nodeIds or nil,
      nodeCount = existing and existing.nodeCount or nil,
      triangleCount = existing and existing.triangleCount or nil,
      bodyTriangleCount = existing and existing.bodyTriangleCount or nil,
      doorTriangleCount = existing and existing.doorTriangleCount or nil,
      hull = existing and existing.hull or nil,
      hullZ = existing and existing.hullZ or nil,
      hullClock = existing and existing.hullClock or nil,
      hullVertexCount = existing and existing.hullVertexCount or nil,
    }
    veh:queueLuaCommand(string.format(
      "extensions.load('overhaulCollisionEnvelope'); if overhaulCollisionEnvelope then overhaulCollisionEnvelope.requestCollisionEnvelope(%d) end",
      requestId
    ))
    return runtimeState.collisionEnvelopes[vehId]
  end

  local function receiveCollisionEnvelope(data)
    if type(data) ~= "table" then return false end
    local vehId = tonumber(data.vehicleId)
    local requestId = tonumber(data.requestId)
    if not vehId or type(data.nodeIds) ~= "table" then return false end
    local existing = runtimeState.collisionEnvelopes[vehId]
    if existing and requestId and requestId < (existing.requestId or 0) then return false end

    runtimeState.collisionEnvelopes[vehId] = {
      vehicleId = vehId,
      requestId = requestId or 0,
      pending = false,
      receivedAt = os.clock(),
      model = existing and existing.model or nil,
      nodeIds = data.nodeIds,
      nodeCount = #data.nodeIds,
      triangleCount = tonumber(data.triangleCount) or 0,
      bodyTriangleCount = tonumber(data.bodyTriangleCount) or 0,
      doorTriangleCount = tonumber(data.doorTriangleCount) or 0,
    }
    if runtimeState.approach and runtimeState.approach.vehId == vehId then
      runtimeState.approach.collisionEnvelopeReceived = true
      runtimeState.approach.collisionEnvelopePending = false
      runtimeState.approach.collisionNodeCount = #data.nodeIds
      runtimeState.approach.collisionTriangleCount = tonumber(data.triangleCount) or 0
      runtimeState.approach.collisionBodyTriangleCount = tonumber(data.bodyTriangleCount) or 0
      runtimeState.approach.collisionDoorTriangleCount = tonumber(data.doorTriangleCount) or 0
      if runtimeState.approach.phase == "approach" then
        runtimeState.approach.route = nil
        runtimeState.approach.routeIndex = 1
        runtimeState.approach.waypoint = nil
      end
    end
    return true
  end

  -- Doorway positions -----------------------------------------------------------------------------

  local function getApproachAftFactor(fromPos, doorCenter, fwd, halfLength)
    if not fromPos or not doorCenter or not fwd then return 0 end
    local along = (fromPos - doorCenter):z0():dot(fwd)
    return clamp(-along / math.max(halfLength * 0.75, 0.5), 0, 1)
  end

  -- Controller-backed doors need extra standing clearance so their opening swing misses the walking capsule.
  local function keepStandingPositionOutsideBody(
    veh, doorInfo, doorCenter, fwd, center, halfWidth, aftFactor, standMargin, standBack,
    safeStandLongSign, stand
  )
    do
      stand = pushOutsideVehicle2D(stand, veh:getId(), standMargin)
      local hull = getCollisionHull(veh:getId(), stand.z)
      local envelopeCenter = hull and hullCenter2D(hull, stand.z) or center or veh:getPosition()
      local guard = 0
      local clearance = vehicleClearance2D(stand, veh:getId(), 0)
      while clearance < standMargin and guard < 12 do
        local away = (stand - envelopeCenter):z0()
        if away:length() < 1e-4 then break end
        away:normalize()
        -- prefer pushing sideways over further aft when approaching from behind
        if aftFactor > 0.25 then
          local side = away - fwd * away:dot(fwd)
          if side:length() > 0.2 then
            away = side:normalized()
          end
        end
        stand = stand + away * 0.25
        guard = guard + 1
        clearance = vehicleClearance2D(stand, veh:getId(), 0)
      end
    end
    if doorCenter and doorInfo then
      local left = parts.doors.getVehicleLeft2D(veh)
      local desiredSign = doorInfo.side == "R" and -1 or 1
      local lateral = parts.doors.getLateralOffset(veh, stand)
      if left and lateral and lateral * desiredSign <= 0.08 then
        local sideDir = left * desiredSign
        stand = doorCenter + sideDir * (halfWidth + standMargin + 0.05)
          + fwd * (standBack * safeStandLongSign)
        stand = pushOutsideVehicle2D(stand, veh:getId(), standMargin)
      end
    end
    return stand
  end

  local function resolveStandingDoorReference(veh, fromPos, lockedDoorName, lockedDoorInfo)
    local doorName = lockedDoorName
    local doorCenter
    if lockedDoorInfo and lockedDoorInfo.referenceLocal then
      doorCenter = parts.doors.vehicleLocalPointToWorld(veh, lockedDoorInfo.referenceLocal)
    elseif lockedDoorInfo and lockedDoorInfo.center then
      doorCenter = vec3(lockedDoorInfo.center)
    elseif doorName then
      doorCenter = parts.doors.getDoorTriggerCenter(veh, doorName)
    else
      doorName, doorCenter = parts.doors.getClosestDoorName(veh, fromPos)
    end
    return doorName, doorCenter
  end

  local function readStandingBodyAxes(veh)
    local fwd = veh:getDirectionVector():z0()
    if fwd:length() > 1e-4 then fwd:normalize() else fwd = vec3(0, 1, 0) end
    local center, axis0, axis1 = parts.doors.getVehicleOBB(veh:getId())
    local halfLength, halfWidth = 2.2, 0.95
    if axis0 and axis1 then
      local len0 = axis0:z0():length()
      local len1 = axis1:z0():length()
      halfLength = math.max(len0, len1)
      halfWidth = math.min(len0, len1)
    end
    return fwd, center, halfLength, halfWidth
  end

  local function getStandPos(veh, fromPos, lockedDoorName, lockedAftFactor, lockedDoorInfo)
    fromPos = fromPos or veh:getPosition()
    local doorInfo = lockedDoorInfo or parts.doors.findDriverDoorInfo(veh)
    local doorName, doorCenter = resolveStandingDoorReference(veh, fromPos, lockedDoorName, lockedDoorInfo)

    local fwd, center, halfLength, halfWidth = readStandingBodyAxes(veh)
    local aftFactor = lockedAftFactor
    if aftFactor == nil then
      aftFactor = getApproachAftFactor(fromPos, doorCenter or veh:getPosition(), fwd, halfLength)
    end
    local hasSwingingDoor = doorInfo and doorInfo.controllerName ~= nil
    local standMargin = hasSwingingDoor and inputs.config.doorWaitClearanceM or inputs.config.bodyClearanceM
    -- Stand behind the panel to leave the swing arc empty without backing away from the whole vehicle.
    local standOut = halfWidth * inputs.config.standOutFraction * (1 - 0.2 * aftFactor)
    local backReduction = hasSwingingDoor and 0.55 or 0.9
    local standBack = halfLength * inputs.config.standBackFraction * (1 - backReduction * aftFactor)
    local safeStandLongSign = doorInfo and doorInfo.safeStandLongSign or -1

    local stand, front
    if doorCenter then
      local outward = (doorCenter - veh:getPosition()):z0()
      if outward:length() < 1e-3 then
        local left = veh:getDirectionVectorUp():cross(fwd)
        if left:length() > 1e-4 then
          left:normalize()
          outward = (doorName == "door_R") and -left or left
        else
          outward = vec3(1, 0, 0)
        end
      else
        outward:normalize()
      end
      stand = doorCenter + outward * standOut + fwd * (standBack * safeStandLongSign)
      -- from behind, nudge slightly forward along the door so board starts closer
      if aftFactor > 0.15 then
        local forwardNudge = hasSwingingDoor and 0.025 or 0.08
        stand = stand + fwd * (halfLength * forwardNudge * aftFactor)
      end
      front = -outward
    else
      local doorside, dFront = gameplay_walk.getDoorsidePosRot(veh)
      if not doorside then
        return nil, nil, nil, doorName, aftFactor
      end
      stand = doorside - fwd * standBack
      front = dFront
      doorCenter = doorside
    end

    stand = keepStandingPositionOutsideBody(
      veh, doorInfo, doorCenter, fwd, center, halfWidth, aftFactor, standMargin, standBack,
      safeStandLongSign, stand
    )
    -- Keep navigation on the walking plane because truck driver nodes can sit several metres above ground.
    stand.z = fromPos.z
    return stand, front, doorCenter, doorName, aftFactor, standMargin
  end

  local function getDoorEntryPos(veh, doorCenter, pathZ)
    if not veh or not doorCenter then return nil end
    local outward = (doorCenter - veh:getPosition()):z0()
    if outward:length() < 1e-4 then
      local fwd = veh:getDirectionVector():z0()
      if fwd:length() > 1e-4 then fwd:normalize() else fwd = vec3(0, 1, 0) end
      outward = veh:getDirectionVectorUp():cross(fwd)
    end
    if outward:length() > 1e-4 then outward:normalize() else outward = vec3(1, 0, 0) end

    local entry = vec3(doorCenter.x, doorCenter.y, pathZ or doorCenter.z)
    entry = entry + outward * 0.08
    -- The Nine needs extra doorway clearance to avoid its wide running-board triangles.
    local entryClearance = veh:getJBeamFilename() == "nine" and 0.42 or inputs.config.entryStepClearanceM
    entry = pushOutsideVehicle2D(entry, veh:getId(), entryClearance)
    entry.z = pathZ or entry.z
    return entry
  end

  -- Two hinge-safe legs avoid cutting diagonally through the open panel swept volume.
  local function getDoorPocketPos(veh, doorCenter, safeStandLongSign, doorSpan, pathZ)
    if not veh or not doorCenter then return nil end
    local fwd = veh:getDirectionVector():z0()
    if fwd:length() > 1e-4 then fwd:normalize() else fwd = vec3(0, 1, 0) end
    local safeSign = safeStandLongSign == 1 and 1 or -1
    local longOffset = math.max((tonumber(doorSpan) or 0.60) * 0.82, inputs.config.entryPocketLengthM)
    local pocket = vec3(doorCenter.x, doorCenter.y, pathZ or doorCenter.z)
      + fwd * (longOffset * safeSign)
    local pocketClearance = veh:getJBeamFilename() == "nine" and 0.42 or inputs.config.entryCloseClearanceM
    pocket = pushOutsideVehicle2D(pocket, veh:getId(), pocketClearance)
    pocket.z = pathZ or pocket.z
    return pocket
  end

  -- OBB routes ------------------------------------------------------------------------------------

  local function segmentHitsOBB2D(a, b, center, axis0, axis1, margin)
    local c2, u0, u1, e0, e1 = getOBBBasis2D(center, axis0, axis1, margin)
    if not c2 then return false end

    local function toLocal(point)
      return localOBBCoords(point, c2, u0, u1)
    end

    local x1, y1 = toLocal(a)
    local x2, y2 = toLocal(b)
    local dx, dy = x2 - x1, y2 - y1
    local t0, t1 = 0, 1

    local function clip(point, q)
      if math.abs(point) < 1e-9 then
        return q >= 0
      end
      local r = q / point
      if point < 0 then
        if r > t1 then return false end
        if r > t0 then t0 = r end
      else
        if r < t0 then return false end
        if r < t1 then t1 = r end
      end
      return true
    end

    if not clip(-dx, x1 + e0) then return false end
    if not clip(dx, e0 - x1) then return false end
    if not clip(-dy, y1 + e1) then return false end
    if not clip(dy, e1 - y1) then return false end
    return t0 <= t1
  end

  local function buildRoute(pos, goal, vehId, margin)
    local hull, envelope = getCollisionHull(vehId, pos.z)
    if hull then
      return buildCollisionHullRoute(pos, goal, hull, margin), "collisionHull", hull, envelope
    end
    local center, axis0, axis1 = parts.doors.getVehicleOBB(vehId)
    if not center then return {vec3(goal)}, "none", nil, envelope end

    goal = pushOutsideOBB2D(goal, center, axis0, axis1, inputs.config.obbMarginM)
    if not segmentHitsOBB2D(pos, goal, center, axis0, axis1, inputs.config.obbMarginM) then
      return {vec3(goal)}, "obbFallback", nil, envelope
    end

    local c2, u0, u1, e0, e1 = getOBBBasis2D(center, axis0, axis1, inputs.config.obbMarginM + 0.25)
    if not c2 then return {vec3(goal)}, "obbFallback", nil, envelope end
    local x0, y0 = u0 * e0, u1 * e1
    local corners = {
      c2 + x0 + y0,
      c2 + x0 - y0,
      c2 - x0 + y0,
      c2 - x0 - y0
    }
    for _, corner in ipairs(corners) do
      corner.z = pos.z
    end

    local function clear(a, b)
      return not segmentHitsOBB2D(a, b, center, axis0, axis1, inputs.config.obbMarginM)
    end

    local bestRoute, bestCost = nil, math.huge
    for i, first in ipairs(corners) do
      if clear(pos, first) then
        if clear(first, goal) then
          local cost = pos:distance(first) + first:distance(goal)
          if cost < bestCost then
            bestCost = cost
            bestRoute = {vec3(first), vec3(goal)}
          end
        end
        for j, second in ipairs(corners) do
          if i ~= j and clear(first, second) and clear(second, goal) then
            local cost = pos:distance(first) + first:distance(second) + second:distance(goal)
            if cost < bestCost then
              bestCost = cost
              bestRoute = {vec3(first), vec3(second), vec3(goal)}
            end
          end
        end
      end
    end

    return bestRoute or {vec3(goal)}, "obbFallback", nil, envelope
  end

  -- Approach statistics ---------------------------------------------------------------------------

  local function noteCollisionEnvelope(state, source, hull, envelope)
    if not state then return end
    if source then state.pathEnvelopeSource = source end
    if hull then state.collisionHullVertexCount = #hull end
    envelope = envelope or runtimeState.collisionEnvelopes[state.vehId]
    if envelope then
      state.collisionEnvelopePending = envelope.pending == true
      state.collisionNodeCount = envelope.nodeCount
        or (envelope.nodeIds and #envelope.nodeIds)
        or state.collisionNodeCount
      state.collisionTriangleCount = envelope.triangleCount or state.collisionTriangleCount
      state.collisionBodyTriangleCount = envelope.bodyTriangleCount or state.collisionBodyTriangleCount
      state.collisionDoorTriangleCount = envelope.doorTriangleCount or state.collisionDoorTriangleCount
      state.collisionHullVertexCount = envelope.hullVertexCount or state.collisionHullVertexCount
    end
  end

  local function getSteerTarget(pos, goal, vehId, margin, waypointDistance)
    if runtimeState.approach.route then
      while runtimeState.approach.routeIndex <= #runtimeState.approach.route
        and pos:distance(runtimeState.approach.route[runtimeState.approach.routeIndex])
          < (waypointDistance or inputs.config.waypointDistanceM) do
        runtimeState.approach.routeIndex = runtimeState.approach.routeIndex + 1
      end
      if runtimeState.approach.routeIndex <= #runtimeState.approach.route then
        local target = runtimeState.approach.route[runtimeState.approach.routeIndex]
        runtimeState.approach.waypoint = runtimeState.approach.routeIndex < #runtimeState.approach.route and target or nil
        return target
      end
      runtimeState.approach.route = nil
    end

    local route, source, hull, envelope = buildRoute(pos, goal, vehId, margin)
    runtimeState.approach.route = route
    runtimeState.approach.routeIndex = 1
    runtimeState.approach.waypointCount = runtimeState.approach.waypointCount + math.max(#runtimeState.approach.route - 1, 0)
    noteCollisionEnvelope(runtimeState.approach, source, hull, envelope)
    local target = runtimeState.approach.route[1]
    runtimeState.approach.waypoint = #runtimeState.approach.route > 1 and target or nil
    return target
  end

  local function storeApproachStats(reason)
    if not runtimeState.approach then return end
    local stats = {reason = reason}
    parts.doors.copyStateFields(stats, runtimeState.approach, [[model minClearance maxClearance doorName doorSide
    driverNodeId driverLateral driverSideSource driverHalfWidth driverSideThreshold
    doorTriggerName doorControllerName doorReferenceSource doorTriggerLateral
    doorReferenceLateral hingeLongSign safeStandLongSign doorSpan doorStateBefore
    doorStateAfter doorOpenStateAfter doorCloseStateAfter speedCoef t phase doorGap
    doorOpenForceDuration doorCloseForceDuration doorCommandT doorCommandStandDistance
    doorCommandDoorDistance doorCommandClearance doorCommandPlayerLateral
    doorCommandExpectedLateral doorCommandSelectedDoorLateral
    doorCommandPlayerLongitudinal doorCommandDoorLongitudinal doorCommandSwingClearance
    doorFullEvidence standClearance standMargin skipReason skipAtT entrySwitchT
    entryCloseStartDistance entryCloseFinalDistance entryCloseStartClearance
    entryCloseTargetClearance entryStepStartDistance entryStepFinalDistance
    entryStepPlannedLongitudinal entryStepPlannedLateral entryStepTargetClearance
    reachAssistReason targetCameraName boardingVerticalMode seatHeightDelta
    boardCameraEndpointError startDistance minDistance maxDistance finalDistance
    minLookMoveDot pathEnvelopeSource]])
    parts.doors.copyStateFields(stats, runtimeState.approach, [[doorTriggerCenterValid doorControllerFound
    doorOpened doorClosed doorPhysicalMeasured doorCommandSideAligned doorFullyOpened
    doorOpenTimedOut skipped entryCloseCompleted entryStepCompleted doorwayBoard
    reachAssist boardCameraEndpointReached collisionEnvelopePending]], "bool")
    parts.doors.copyStateFields(stats, runtimeState.approach, [[insideHits arriveT boardT maxDoorGap
    wrongSideCorrections swingClearanceCorrections doorStableProbes entryCloseT
    entryCloseTravel entrySettleT entryStepT entryStepTravel collisionRecoveryCount
    reachAssistDistance pathLength maxSpeed maxLookRateDeg totalLookTurnDeg
    maxCameraTargetErrorDeg waypointCount collisionNodeCount collisionTriangleCount
    collisionBodyTriangleCount collisionDoorTriangleCount collisionHullVertexCount]], "zero")
    stats.doorOpenWait = runtimeState.approach.doorOpenWait or runtimeState.approach.doorOpenElapsed or 0
    stats.doorCloseAttempts =
      (runtimeState.approach.closeRetryCount or 0) + (runtimeState.approach.closeCommanded and 1 or 0)
    stats.driverTransition = runtimeState.approach.useDriverTransition == true
    stats.collisionEnvelopeFallback = runtimeState.approach.pathEnvelopeSource ~= "collisionHull"
    stats.pathEfficiency = stats.pathLength > 0
      and (runtimeState.approach.startDistance or 0) / stats.pathLength or 0
    stats.avgSpeed = (runtimeState.approach.speedSum or 0) / math.max(runtimeState.approach.speedSamples or 0, 1)
    stats.avgLookMoveDot =
      (runtimeState.approach.lookMoveDotSum or 0) / math.max(runtimeState.approach.lookSamples or 0, 1)
    stats.avgLookCarDot =
      (runtimeState.approach.lookCarDotSum or 0) / math.max(runtimeState.approach.lookSamples or 0, 1)
    stats.boardStartCameraPos = parts.doors.vecToTable(runtimeState.approach.boardStartCameraPos)
    stats.boardTargetCameraPos = parts.doors.vecToTable(runtimeState.approach.boardTargetCameraPos)
    runtimeState.lastApproachStats = stats
  end

  -- Part API --------------------------------------------------------------------------------------

  return {
    buildRoute = buildRoute,
    getDoorEntryPos = getDoorEntryPos,
    getDoorPocketPos = getDoorPocketPos,
    getStandPos = getStandPos,
    getSteerTarget = getSteerTarget,
    hullCenter2D = hullCenter2D,
    noteCollisionEnvelope = noteCollisionEnvelope,
    pushOutsideVehicle2D = pushOutsideVehicle2D,
    receiveCollisionEnvelope = receiveCollisionEnvelope,
    requestCollisionEnvelope = requestCollisionEnvelope,
    storeApproachStats = storeApproachStats,
    vehicleClearance2D = vehicleClearance2D,
  }
end

return M
