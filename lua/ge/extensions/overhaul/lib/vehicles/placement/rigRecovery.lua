-- Recovery placement for vehicles and coupled rigs.
-- Map: terrain, collision bounds, native teleport projection, rig destinations and road search.
local recovery = {}

-- Config --------------------------------------------------------------------------------------------

local DOWN = vec3(0, 0, -1)
local ROAD_SEARCH_RADIUS = 600

-- Terrain -------------------------------------------------------------------------------------------

local function terrainZ(pos)
  local origin = vec3(pos.x, pos.y, (pos.z or 0) + 80)
  local hit = castRayStatic(origin, DOWN, 160)
  if hit and hit < 160 then
    return origin.z - hit
  end
  origin = vec3(pos.x, pos.y, (pos.z or 0) + 250)
  hit = castRayStatic(origin, DOWN, 500)
  if hit and hit < 500 then
    return origin.z - hit
  end
  return nil
end

local function onTerrain(pos)
  local z = terrainZ(pos)
  if not z then return false end
  return pos.z >= z - 4 and pos.z <= z + 16
end

-- Whether a destination's centre and both ends along its axis (8 m out) sit on terrain.
local function destinationSupported(transform)
  local p = transform:getColumn(3)
  local axis = transform:getColumn(1)
  local points = {p}
  if axis then
    points[#points + 1] = p + axis * 8
    points[#points + 1] = p - axis * 8
  end
  for _, point in ipairs(points) do
    if not onTerrain(point) then return false end
  end
  return true
end

-- Whether every member of the group is upright and on terrain.
local function groupUprightOnTerrain(group)
  for _, id in ipairs(group.ids) do
    local obj = getObjectByID(id)
    if not obj then return false end
    if obj:getDirectionVectorUp().z < 0.5 then return false end
    if not onTerrain(obj:getPosition()) then return false end
  end
  return true
end

-- Roads ---------------------------------------------------------------------------------------------

-- The closest point on the nearest road to pos, and the road's direction (flipped to match dir).
local function roadTarget(pos, dir)
  local a, b = map.findClosestRoad(pos)
  local nodes = map.getMap() and map.getMap().nodes
  if not a or not b or not nodes or not nodes[a] or not nodes[b] then
    return nil, nil, 'No nearby road is available.'
  end
  local start, finish = nodes[a].pos, nodes[b].pos
  local delta = finish - start
  local lengthSq = delta:squaredLength()
  if lengthSq < 0.01 then return nil, nil, 'The nearby road has no usable direction.' end
  local t = math.max(0, math.min(1, (pos - start):dot(delta) / lengthSq))
  local roadPos = start + delta * t
  if delta:dot(dir) < 0 then delta = -delta end
  return roadPos, delta
end

-- Whether a point lies on a road segment's radius, and within 4 m of its level.
local function destinationOnRoad(position, segments)
  local closest, distance, radius = nil, nil, nil
  for _, segment in ipairs(segments) do
    local t = math.max(0, math.min(1, (position - segment.start):dot(segment.delta) / segment.lengthSq))
    local projected = segment.start + segment.delta * t
    local squaredDistance = (position - projected):squaredLength()
    if not distance or squaredDistance < distance then
      closest, distance = projected, squaredDistance
      radius = segment.startRadius + (segment.endRadius - segment.startRadius) * t
    end
  end
  if not closest or radius <= 0 then return false end
  local offset = position - closest
  -- The reference node can sit above the road; do not accept another level or the roadside.
  return offset.x * offset.x + offset.y * offset.y <= radius * radius and math.abs(offset.z) <= 4
end

-- Vehicles and rigs ---------------------------------------------------------------------------------

local function moveVehicle(obj, transform)
  local p, rotation = transform:getColumn(3), quat(transform:toQuatF())
  local current = quat(obj:getClusterRotationSlow(obj:getRefNodeId()))
  local delta = current:inversed() * rotation
  obj:setClusterPosRelRot(obj:getRefNodeId(), p.x, p.y, p.z, delta.x, delta.y, delta.z, delta.w)
  obj:applyClusterVelocityScaleAdd(obj:getRefNodeId(), 0, 0, 0, 0)
end

-- The destination of every member: the root's transform, then hinged members and carried members relative to their parents.
local function relativeDestinations(group, hinges, rootTransform)
  local destinations = {[group.root] = rootTransform}
  for _, hinge in ipairs(hinges) do
    destinations[hinge.id] = spawn.calculateRelativeVehiclePlacement(
      destinations[hinge.parent], hinge.a, hinge.b, hinge.rotation)
  end
  for _, relation in ipairs(group.carried) do
    destinations[relation.id] = destinations[relation.parent] * relation.offset
  end
  return destinations
end

-- The box of a vehicle's collision nodes, in its own frame, or its spawn box when it has no collision nodes.
local function collisionBounds(obj)
  local clusters = obj:getNodeClusters()
  local cluster = clusters[obj:getRefNodeId() + 1]
  local rotation = quat(obj:getClusterRotationSlow(obj:getRefNodeId()))
  local inverse = rotation:inversed()
  local localBounds, count = Box3F(), 0
  for index, nodeCluster in ipairs(clusters) do
    if nodeCluster == cluster and obj:getInitialNodeCollision(index - 1) == 3 then
      localBounds:extend(inverse * obj:getNodePosition(index - 1))
      count = count + 1
    end
  end
  if count == 0 then return obj:getSpawnWorldOOBB() end
  local transform = QuatF(rotation.x, rotation.y, rotation.z, rotation.w):getMatrix()
  transform:setColumn(3, obj:getPosition() + rotation * localBounds:getCenter())
  local bounds = OrientedBox3F()
  bounds:set2(transform, localBounds:getExtents())
  return bounds
end

-- Each member's box at its destination, keyed by member id.
local function placementBoxes(group, destinations)
  local boxes = {}
  group.bounds = group.bounds or {}
  for _, id in ipairs(group.ids) do
    local bounds = group.bounds[id] or collisionBounds(group.objects[id])
    group.bounds[id] = bounds
    local transform = destinations[id] * (group.original[id] * MatrixF(true)):inverse()
    local rotation = quat(transform:toQuatF())
    local half = bounds:getHalfExtents()
    boxes[id] = {center = transform:mulP3F(bounds:getCenter()),
      x = rotation * vec3(bounds:getAxis(0)) * half.x,
      y = rotation * vec3(bounds:getAxis(1)) * half.y,
      z = rotation * vec3(bounds:getAxis(2)) * half.z}
  end
  return boxes
end

-- Clearance -----------------------------------------------------------------------------------------

-- Whether any vehicle outside the rig overlaps one of the boxes. With ignoreTraffic, traffic counts as part of the rig.
local function overlapsForeignVehicle(group, boxes, ignoreTraffic)
  local members = {}
  for _, id in ipairs(group.ids) do members[id] = true end
  if ignoreTraffic and gameplay_traffic and gameplay_traffic.getTrafficList then
    for _, id in ipairs(gameplay_traffic.getTrafficList()) do members[id] = true end
  end
  for id, other in activeVehiclesIterator() do
    if not members[id] then
      local bounds = other:getSpawnWorldOOBB()
      local half = bounds:getHalfExtents()
      for _, box in pairs(boxes) do
        if overlapsOBB_OBB(box.center, box.x, box.y, box.z, bounds:getCenter(),
            vec3(bounds:getAxis(0)) * half.x, vec3(bounds:getAxis(1)) * half.y, vec3(bounds:getAxis(2)) * half.z) then
          return true
        end
      end
    end
  end
  return false
end

-- Whether the box's bottom corners sit on terrain, within half a metre below to one metre above it.
local function groundedCorners(box)
  for _, x in ipairs({-0.8, 0, 0.8}) do
    for _, y in ipairs({-0.8, 0, 0.8}) do
      local bottom = box.center + box.x * x + box.y * y - box.z
      local z = terrainZ(bottom)
      if not z or bottom.z - z < -0.5 or bottom.z - z > 1 then return false end
    end
  end
  return true
end

-- Whether no static geometry is hit by rays crossing the box at three heights and three sides.
local function staticRaysClear(box)
  for _, height in ipairs({-0.7, 0, 0.8}) do
    local center = box.center + box.z * height
    for _, side in ipairs({-0.8, 0, 0.8}) do
      for _, ray in ipairs({{center + box.x * side - box.y, box.y * 2},
          {center + box.y * side - box.x, box.x * 2}}) do
        local length = ray[2]:length()
        if length > 0.01 and castRayStatic(ray[1], ray[2] / length, length) < length then return false end
      end
    end
  end
  return true
end

-- Whether the rig fits at its destinations: no foreign vehicle, members grounded (carried ones excepted), no static in the way.
local function placementClear(group, destinations, ignoreTraffic)
  local boxes = placementBoxes(group, destinations)
  if overlapsForeignVehicle(group, boxes, ignoreTraffic) then return false end
  local carried = {}
  for _, relation in ipairs(group.carried) do carried[relation.id] = true end
  for id, box in pairs(boxes) do
    if not carried[id] and not groundedCorners(box) then return false end
    if not staticRaysClear(box) then return false end
  end
  return true
end

-- Traffic cars that overlap the rig at its destinations.
local function blockingTraffic(group, destinations)
  if not gameplay_traffic or not gameplay_traffic.getTrafficList then return {} end
  local boxes, members = placementBoxes(group, destinations), {}
  for _, id in ipairs(group.ids) do members[id] = true end
  local blocked = {}
  for _, id in ipairs(gameplay_traffic.getTrafficList()) do
    local other = not members[id] and getObjectByID(id)
    if other then
      local bounds = other:getSpawnWorldOOBB()
      local half = bounds:getHalfExtents()
      for _, box in pairs(boxes) do
        if overlapsOBB_OBB(box.center, box.x, box.y, box.z, bounds:getCenter(),
            vec3(bounds:getAxis(0)) * half.x, vec3(bounds:getAxis(1)) * half.y, vec3(bounds:getAxis(2)) * half.z) then
          blocked[#blocked + 1] = other
          break
        end
      end
    end
  end
  return blocked
end

-- Planning ------------------------------------------------------------------------------------------

-- Moves the rig's node model so the native placement lands the rotated box centre on pos; returns the adjusted pos.
local function alignWholeRig(group, hinges, pos, rotation, overrides)
  local root = group.objects[group.root]
  local boxes = placementBoxes(group, relativeDestinations(group, hinges, group.original[group.root]))
  local nodes, clusters = {}, {}
  local origin = root:getPosition()
  for _, id in ipairs(group.ids) do
    local box = boxes[id]
    for _, x in ipairs({-1, 1}) do
      for _, y in ipairs({-1, 1}) do
        for _, z in ipairs({-1, 1}) do
          nodes[#nodes + 1] = box.center + box.x * x + box.y * y + box.z * z - origin
          clusters[#clusters + 1] = 0
        end
      end
    end
  end
  overrides.getNodeClusters = function() return clusters end
  overrides.getRefNodeId = function() return 0 end
  overrides.getClusterRotationSlow = function() return root:getClusterRotationSlow(root:getRefNodeId()) end
  overrides.getInitialNodeCollision = function() return 3 end
  overrides.getNodePosition = function(_, id) return nodes[id + 1] end
  -- Rotate the reference-node offset after positioning the collision box to match native teleport.
  local current = quat(root:getClusterRotationSlow(root:getRefNodeId()))
  local inverse, bounds = current:inversed(), Box3F()
  for _, node in ipairs(nodes) do bounds:extend(inverse * node) end
  local offset = current * bounds:getCenter()
  local desired = quat(0, 0, 1, 0) * rotation
  return pos + (inverse * desired) * offset
end

-- Forwards every engine call the overrides do not handle to the root vehicle.
local function rootProxy(root, overrides)
  return setmetatable(overrides, {__index = function(_, name)
    local member = root[name]
    if type(member) == 'function' then return function(_, ...) return member(root, ...) end end
    return member
  end})
end

-- The destinations of every member for a root transform, or the reason they cannot be used.
local function checkRigDestinations(group, hinges, rootTransform, wholeGroup)
  local destinations = relativeDestinations(group, hinges, rootTransform)
  for _, id in ipairs(group.ids) do
    if not destinations[id] then
      return nil, 'The connected vehicle placement is incomplete.'
    end
    if not destinationSupported(destinations[id]) then
      return nil, 'The recovered rig would not land on solid ground.'
    end
  end
  if wholeGroup and not placementClear(group, destinations, true) then
    return nil, 'No clear road position large enough for the whole rig was found.'
  end
  return destinations
end

-- Plans the destinations for placing the group at pos, facing dir, through a native placement on a proxy root.
local function planDestinations(group, hinges, pos, dir, wholeGroup)
  local target = nil
  local rotation = quatFromDir(dir)
  local overrides = {
    setClusterPosRelRot = function() end,
    applyClusterVelocityScaleAdd = function() end,
    setOriginalTransform = function(_, x, y, z, qx, qy, qz, qw)
      local transform = QuatF(qx, qy, qz, qw):getMatrix()
      transform:setColumn(3, vec3(x, y, z))
      target = transform
    end,
  }
  if wholeGroup then
    pos = alignWholeRig(group, hinges, pos, rotation, overrides)
  end
  local proxy = rootProxy(group.objects[group.root], overrides)
  -- Ignore the whole rig because native vehicle checks otherwise collide with its own coupled members.
  local ok, reason = pcall(spawn.safeTeleport, proxy, pos, rotation, wholeGroup or false, nil, not wholeGroup, wholeGroup or nil, false)
  if not ok then error(reason) end
  if not target then
    return nil, 'No safe recovery position was found.'
  end
  return checkRigDestinations(group, hinges, target, wholeGroup)
end

-- Road search ---------------------------------------------------------------------------------------

-- Candidates for the road search: one per 10 m cell and heading (the nearer one wins), and the road segments.
local function newRoadScan(origin, dir)
  return {origin = origin, dir = dir, candidates = {}, cells = {}, segments = {}}
end

local function addRoadCandidate(scan, position, direction)
  local key = math.floor(position.x / 10 + 0.5) .. ':' .. math.floor(position.y / 10 + 0.5)
    .. ':' .. math.floor(position.z / 10 + 0.5)
  local distance = (position - scan.origin):squaredLength()
  local directions = scan.cells[key]
  if not directions then directions = {}; scan.cells[key] = directions end
  for _, candidate in ipairs(directions) do
    if candidate.dir:dot(direction) > 0.996 * math.sqrt(candidate.dir:squaredLength() * direction:squaredLength()) then
      if distance < candidate.distance then
        candidate.pos, candidate.dir, candidate.distance = position, direction, distance
      end
      return
    end
  end
  local candidate = {pos = position, dir = direction, distance = distance}
  scan.candidates[#scan.candidates + 1], directions[#directions + 1] = candidate, candidate
end

-- Candidates along one link: its nearest point to the origin, then every step within the search radius.
local function addLinkCandidates(scan, node, delta, lengthSq)
  local origin = scan.origin
  local t = math.max(0, math.min(1, (origin - node.pos):dot(delta) / lengthSq))
  local closest = node.pos + delta * t
  if (closest - origin):squaredLength() > ROAD_SEARCH_RADIUS * ROAD_SEARCH_RADIUS then return end
  local steps = math.ceil(math.sqrt(lengthSq) / 20)
  local range = ROAD_SEARCH_RADIUS / math.sqrt(lengthSq)
  local first = math.max(0, math.floor((t - range) * steps))
  local last = math.min(steps, math.ceil((t + range) * steps))
  addRoadCandidate(scan, closest, delta:dot(scan.dir) < 0 and -delta or delta)
  for step = first, last do
    local candidate = node.pos + delta * (step / steps)
    local distance = (candidate - origin):squaredLength()
    if distance <= ROAD_SEARCH_RADIUS * ROAD_SEARCH_RADIUS then
      addRoadCandidate(scan, candidate, delta:dot(scan.dir) < 0 and -delta or delta)
    end
  end
end

-- Every map link gives a segment for destinationOnRoad and candidates near the origin.
local function collectRoadLinks(scan, nodes)
  for a, node in pairs(nodes) do
    for b, link in pairs(node.links or {}) do
      local other = nodes[b]
      if other and tostring(a) < tostring(b) and (link.drivability or 1) > 0 then
        local delta = other.pos - node.pos
        local lengthSq = delta:squaredLength()
        if lengthSq > 0.01 then
          scan.segments[#scan.segments + 1] = {start = node.pos, delta = delta, lengthSq = lengthSq,
            startRadius = node.radius or 0, endRadius = other.radius or 0}
        end
        if lengthSq > 1 then
          addLinkCandidates(scan, node, delta, lengthSq)
        end
      end
    end
  end
end

-- Search nearest candidates first and yield at the original cadence before accepting a clear destination.
local function planRoadDestinations(group, hinges, pos, dir)
  local scan = newRoadScan(group.objects[group.root]:getPosition(), dir)
  addRoadCandidate(scan, pos, dir)
  local nodes = map.getMap() and map.getMap().nodes or {}
  collectRoadLinks(scan, nodes)
  table.sort(scan.candidates, function(a, b) return a.distance < b.distance end)
  return coroutine.create(function()
    for index, candidate in ipairs(scan.candidates) do
      if index > 1 and (index - 1) % 40 == 0 then coroutine.yield() end
      local destinations = planDestinations(group, hinges, candidate.pos, candidate.dir, true)
      if destinations and (destinations[group.root]:getColumn(3) - scan.origin):squaredLength() <= ROAD_SEARCH_RADIUS * ROAD_SEARCH_RADIUS
          and destinationOnRoad(destinations[group.root]:getColumn(3), scan.segments) then
        return destinations
      end
    end
    return nil, 'No clear road position large enough for the whole rig was found nearby. Nothing was moved.'
  end)
end

-- Public API ----------------------------------------------------------------------------------------

recovery.terrainZ = terrainZ
recovery.onTerrain = onTerrain
recovery.destinationSupported = destinationSupported
recovery.groupUprightOnTerrain = groupUprightOnTerrain
recovery.roadTarget = roadTarget
recovery.moveVehicle = moveVehicle
recovery.relativeDestinations = relativeDestinations
recovery.collisionBounds = collisionBounds
recovery.placementBoxes = placementBoxes
recovery.placementClear = placementClear
recovery.blockingTraffic = blockingTraffic
recovery.planDestinations = planDestinations
recovery.destinationOnRoad = destinationOnRoad
recovery.planRoadDestinations = planRoadDestinations

return recovery
