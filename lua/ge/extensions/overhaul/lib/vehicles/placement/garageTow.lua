-- Garage-tow placement: where a towed vehicle or rig lands in a garage, reached as strategy "garageTow".
-- Spot planning, rig footprint, blocked checks and group placement through spawn.safeTeleport on a proxy; no state.
local M = {}

local function spotArea(spot)
  local scl = spot and spot.scl
  if not scl then return 0 end
  return math.abs(scl.x or 0) * math.abs(scl.y or 0)
end

-- All members of the groups as one group, rooted at the first group's root.
local function combinedGroup(groups)
  local all = {root = groups[1].root, ids = {}}
  for _, group in ipairs(groups) do
    for _, id in ipairs(group.ids) do all.ids[#all.ids + 1] = id end
  end
  return all
end

-- Clear spots that fit the whole group (largest first), and the largest clear spot that does not fit.
local function rankSpots(all, spots, groupFits, spotClear)
  local fitted, fallback, fallbackArea = {}, nil, nil
  for _, spot in ipairs(spots) do
    if spotClear(spot, all) then
      if groupFits(all, spot) then
        fitted[#fitted + 1] = {spot = spot, area = spotArea(spot)}
      else
        local area = spotArea(spot)
        if not fallback or area > fallbackArea then
          fallback, fallbackArea = spot, area
        end
      end
    end
  end
  table.sort(fitted, function(a, b) return a.area > b.area end)
  return fitted, fallback
end

-- Up to three whole-group candidates from the best fitting spots, plus the fallback spot when it is not listed yet.
local function coupledEntries(all, fitted, fallback)
  local coupled = {}
  for i = 1, math.min(#fitted, 3) do
    coupled[#coupled + 1] = {group = all, spot = fitted[i].spot}
  end
  if fallback then
    local listed = false
    for _, entry in ipairs(coupled) do
      if entry.spot == fallback then listed = true; break end
    end
    if not listed then coupled[#coupled + 1] = {group = all, spot = fallback} end
  end
  return coupled
end

-- One spot per group, in group order; nil as soon as a group has no clear spot.
local function assignSplitSpots(groups, spots, groupFits, spotClear)
  local used = {}
  local function assignSpot(group, requireFit)
    for i, spot in ipairs(spots) do
      if not used[i] and spotClear(spot, group) and (not requireFit or groupFits(group, spot)) then
        used[i] = true
        return spot
      end
    end
  end
  local split = {}
  for _, group in ipairs(groups) do
    local spot = assignSpot(group, true)
    if not spot then
      spot = assignSpot(group, false)
      if spot then groupFits(group, spot) end
    end
    if not spot then return nil end
    split[#split + 1] = {group = group, spot = spot}
  end
  return split
end

-- Plans spots for the groups: coupled candidates for the whole rig, and a split with one spot per group when possible.
function M.plan(groups, spots, groupFits, spotClear)
  if #groups == 0 or not spots or #spots == 0 then return nil, nil end
  local all = combinedGroup(groups)
  local fitted, fallback = rankSpots(all, spots, groupFits, spotClear)
  local coupled = coupledEntries(all, fitted, fallback)
  local split = assignSplitSpots(groups, spots, groupFits, spotClear)
  return #coupled > 0 and coupled or nil, split
end

-- The rig's box size along its own axes, and the offset that centres it on the root.
local function footprint(group, objects)
  local box = objects[group.root]:getSpawnWorldOOBB()
  local origin = box:getCenter()
  local x = (box:getPoint(3) - box:getPoint(0)):normalized()
  local y = (box:getPoint(0) - box:getPoint(4)):normalized()
  local z = (box:getPoint(1) - box:getPoint(0)):normalized()
  local lo, hi = {math.huge, math.huge, math.huge}, {-math.huge, -math.huge, -math.huge}
  for _, id in ipairs(group.ids) do
    local bounds = objects[id]:getSpawnWorldOOBB()
    for corner = 0, 7 do
      local delta = bounds:getPoint(corner) - origin
      local values = {delta:dot(x), delta:dot(y), delta:dot(z)}
      for axis = 1, 3 do
        lo[axis], hi[axis] = math.min(lo[axis], values[axis]), math.max(hi[axis], values[axis])
      end
    end
  end
  return {x = hi[1] - lo[1], y = hi[2] - lo[2], z = hi[3] - lo[3]},
    vec3(-(lo[1] + hi[1]) / 2, -(lo[2] + hi[2]) / 2, 0)
end

local function boxOf(veh)
  local bb = veh and veh.getSpawnWorldOOBB and veh:getSpawnWorldOOBB()
  if not bb then return nil end
  local half = bb:getHalfExtents()
  return {
    center = vec3(bb:getCenter()),
    x = vec3(bb:getAxis(0)) * half.x,
    y = vec3(bb:getAxis(1)) * half.y,
    z = vec3(bb:getAxis(2)) * half.z,
    halfZ = half.z,
  }
end

-- Whether a point lies inside a box; a degenerate axis counts as inside.
local function centerInside(box, point)
  local d = point - box.center
  local ax2, ay2, az2 = box.x:squaredLength(), box.y:squaredLength(), box.z:squaredLength()
  if ax2 < 1e-4 or ay2 < 1e-4 or az2 < 1e-4 then return true end
  return math.abs(d:dot(box.x)) < ax2 and math.abs(d:dot(box.y)) < ay2 and math.abs(d:dot(box.z)) < az2
end

local function rayClear(from, to)
  local delta = to - from
  local length = delta:length()
  return length < 0.01 or castRayStatic(from, delta / length, length) >= length
end

local function horiz(v)
  local flat = vec3(v.x, v.y, 0)
  local len = flat:length()
  if len < 0.05 then return nil, 0 end
  return flat / len, len
end

-- Boxes of the moving members, or nil when one of them has no box.
local function movingBoxes(ids, objects)
  local boxes = {}
  for _, id in ipairs(ids) do
    local box = boxOf(objects[id])
    if not box then return nil end
    boxes[#boxes + 1] = box
  end
  return boxes
end

-- Whether two members of the rig overlap or sit in each other's centre.
local function membersOverlap(boxes)
  for i = 1, #boxes do
    for j = i + 1, #boxes do
      if boxes[i].center:squaredDistance(boxes[j].center) < 0.56
          or centerInside(boxes[i], boxes[j].center)
          or centerInside(boxes[j], boxes[i].center) then
        return true
      end
    end
  end
  return false
end

-- Whether a foreign vehicle overlaps any member box.
local function overlapsForeignVehicle(ids, boxes)
  local moving = {}
  for _, id in ipairs(ids) do moving[id] = true end
  for id, other in activeVehiclesIterator() do
    if not moving[id] then
      local otherBox = boxOf(other)
      if otherBox then
        for _, box in ipairs(boxes) do
          if overlapsOBB_OBB(box.center, box.x, box.y, box.z, otherBox.center, otherBox.x, otherBox.y, otherBox.z) then
            return true
          end
        end
      end
    end
  end
  return false
end

-- Whether static geometry blocks a member: a ray at two heights from each side, along both horizontal axes.
local function staticsBlock(boxes)
  for _, box in ipairs(boxes) do
    local xDir, xLen = horiz(box.x)
    local yDir, yLen = horiz(box.y)
    if xDir and yDir then
      local hx, hy = xDir * xLen, yDir * yLen
      for _, height in ipairs({0.55, 1.15}) do
        local rayOrigin = vec3(box.center.x, box.center.y, box.center.z + height - box.halfZ)
        for _, side in ipairs({-1, 0, 1}) do
          if not rayClear(rayOrigin + hx * side - hy, rayOrigin + hx * side + hy)
              or not rayClear(rayOrigin + hy * side - hx, rayOrigin + hy * side + hx) then
            return true
          end
        end
      end
    end
  end
  return false
end

-- Whether the rig cannot be placed here: members overlap, a foreign vehicle is in the way, or statics block it.
local function placementBlocked(ids, objects)
  local boxes = movingBoxes(ids, objects)
  if not boxes then return true end
  return membersOverlap(boxes) or overlapsForeignVehicle(ids, boxes) or staticsBlock(boxes)
end

local function moveCluster(object, pos, delta)
  local refNode = object:getRefNodeId()
  object:setClusterPosRelRot(refNode, pos.x, pos.y, pos.z, delta.x, delta.y, delta.z, delta.w)
  object:applyClusterVelocityScaleAdd(refNode, 0, 0, 0, 0)
end

-- Places the group's root through spawn.safeTeleport on a proxy, then moves every member to its offset.
local function placeGroup(entry, objects)
  local group = entry.group
  local root = objects[group.root]
  local spot = entry.spot
  if not spot then error("Garage placement refused") end
  local target = nil
  local proxy = setmetatable({
    setClusterPosRelRot = function(_, _, x, y, z, qx, qy, qz, qw)
      target = {pos = vec3(x, y, z), rot = quat(qx, qy, qz, qw)}
    end,
    applyClusterVelocityScaleAdd = function() end,
    setOriginalTransform = function() end,
  }, {__index = function(_, name)
    local member = root[name]
    if type(member) == 'function' then return function(_, ...) return member(root, ...) end end
    return member
  end})
  local offset = group.offset or vec3()
  local shift = vec3()
  shift:setRotate(spot.rot, vec3(offset.x, offset.y, 0))
  spawn.safeTeleport(proxy, spot.pos + shift, spot.rot, true, nil, nil, true, false)
  if not target then error("Garage placement refused") end
  local rootPos = vec3(root:getPosition())
  for _, id in ipairs(group.ids) do
    local object = objects[id]
    local pos = target.pos
    if id ~= group.root then pos = target.pos + target.rot * (vec3(object:getPosition()) - rootPos) end
    moveCluster(object, pos, target.rot)
  end
end

M.footprint = footprint
M.placementBlocked = placementBlocked
M.moveCluster = moveCluster
M.placeGroup = placeGroup

return M
