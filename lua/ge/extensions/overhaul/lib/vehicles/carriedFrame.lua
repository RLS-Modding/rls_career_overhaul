-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
-- Copyright (C) RLS Modding
-- SPDX-License-Identifier: AGPL-3.0-only

-- Carried placement follows the supporting part, including articulated decks.
-- Map: live frames, footprint and connected support selection, capture, reconstruction; travel owns readiness.
local M = {}

local MIN_FRAME_AREA_SQUARED = 0.0001
local FOOTPRINT_MARGIN_METERS = 0.6
local SUPPORT_GAP_METERS = 0.5
local SUPPORT_ABOVE_FLOOR_METERS = 0.15
local MIN_FOOTPRINT_COVERAGE = 0.6

local function nodesOf(vehicle)
  local data = core_vehicle_manager.getVehicleData(vehicle:getID())
  return data and data.vdata and data.vdata.nodes or {}
end

local function worldPosition(vehicle, node)
  return vehicle:getPosition() + vehicle:getNodePosition(node.cid)
end

local function frameFromNodes(vehicle, nodes)
  local origin = worldPosition(vehicle, nodes[1])
  local along = worldPosition(vehicle, nodes[2]) - origin
  local normal = along:cross(worldPosition(vehicle, nodes[3]) - origin)
  if normal:squaredLength() < MIN_FRAME_AREA_SQUARED then return nil end
  along:normalize()
  normal:normalize()
  local frame = MatrixF(true)
  frame:setColumn(0, along)
  frame:setColumn(1, normal:cross(along))
  frame:setColumn(2, normal)
  frame:setPosition(origin)
  return frame
end

local function mainCluster(vehicle)
  local ok, cluster = pcall(function() return vehicle:getNodeClusterId(vehicle:getRefNodeId()) end)
  return ok and cluster or nil
end

local function connected(vehicle, node, cluster)
  if cluster == nil then return false end
  local ok, value = pcall(vehicle.getNodeClusterId, vehicle, node.cid)
  return ok and value == cluster
end

local function footprint(child)
  local box = child:getSpawnWorldOOBB()
  return {center=box:getCenter(),half=box:getHalfExtents(),x=box:getAxis(0),y=box:getAxis(1),z=box:getAxis(2)}
end

local function projected(position, footprint)
  local delta = position-footprint.center
  return vec3(delta:dot(footprint.x),delta:dot(footprint.y),delta:dot(footprint.z))
end

local function supportingPart(child, carrier, cluster)
  local bounds, parts = footprint(child), {}
  for _, node in pairs(nodesOf(carrier)) do
    local path = node.partPath or node.partOrigin
    if node.name and node.cid and path and connected(carrier,node,cluster) then
      local part = parts[path] or {floorNodes={},contacts=0,gap=0,minX=math.huge,maxX=-math.huge,minY=math.huge,maxY=-math.huge}
      parts[path] = part
      local position = projected(worldPosition(carrier,node),bounds)
      part.minX,part.maxX = math.min(part.minX,position.x),math.max(part.maxX,position.x)
      part.minY,part.maxY = math.min(part.minY,position.y),math.max(part.maxY,position.y)
      local height = position.z+bounds.half.z
      if height>=-SUPPORT_GAP_METERS and height<=SUPPORT_ABOVE_FLOOR_METERS then part.floorNodes[#part.floorNodes+1]=node end
      if math.abs(position.x)<=bounds.half.x+FOOTPRINT_MARGIN_METERS
          and math.abs(position.y)<=bounds.half.y+FOOTPRINT_MARGIN_METERS
          and height>=-SUPPORT_GAP_METERS and height<=SUPPORT_ABOVE_FLOOR_METERS then
        part.contacts,part.gap = part.contacts+1,part.gap+math.abs(height)
      end
    end
  end
  local best, bestPath
  -- A light bar cannot support a car's footprint even when it happens to lie beside its reference node.
  for path, part in pairs(parts) do
    local broad = part.maxX-part.minX>=2*bounds.half.x*MIN_FOOTPRINT_COVERAGE
      and part.maxY-part.minY>=2*bounds.half.y*MIN_FOOTPRINT_COVERAGE
    local gap = part.contacts>0 and part.gap/part.contacts or math.huge
    local bestGap = best and best.gap/best.contacts or math.huge
    if broad and part.contacts>=2 and #part.floorNodes>=3 and (not best or gap<bestGap
        or (gap==bestGap and (part.contacts>best.contacts or (part.contacts==best.contacts and path<bestPath)))) then
      best,bestPath=part,path
    end
  end
  return best and best.floorNodes
end

-- Anchors belong to one attached, load-bearing part, including when its deck is articulated.
local function supportingNodes(child, carrier)
  local candidates = supportingPart(child,carrier,mainCluster(carrier))
  if not candidates then return nil end
  local nearest, nearestDistance = nil, math.huge
  local position = child:getRefNodeMatrix():getPosition()
  for _, node in ipairs(candidates) do
    local amount = (worldPosition(carrier,node)-position):squaredLength()
    if amount<nearestDistance or (amount==nearestDistance and node.name<nearest.name) then nearest,nearestDistance=node,amount end
  end
  local second, distance = nil, 0
  local origin = worldPosition(carrier, nearest)
  for _, node in ipairs(candidates) do
    local amount = (worldPosition(carrier, node) - origin):squaredLength()
    if amount > distance then second, distance = node, amount end
  end
  if not second then return nil end
  local along = worldPosition(carrier, second) - origin
  local third, area = nil, MIN_FRAME_AREA_SQUARED
  for _, node in ipairs(candidates) do
    local amount = along:cross(worldPosition(carrier, node) - origin):squaredLength()
    if amount > area then third, area = node, amount end
  end
  return third and {nearest, second, third} or nil
end

function M.capture(child, carrier)
  local ok, support = pcall(function()
    local nodes = supportingNodes(child, carrier)
    if not nodes then return nil end
    local frame = frameFromNodes(carrier, nodes)
    if not frame then return nil end
    local offset = frame:inverse() * child:getRefNodeMatrix()
    local pos, rot = offset:getPosition(), offset:toEuler()
    return {nodes = {nodes[1].name, nodes[2].name, nodes[3].name},
      offset = {x = pos.x, y = pos.y, z = pos.z, rx = rot.x, ry = rot.y, rz = rot.z}}
  end)
  return ok and support or nil
end

function M.transform(carrier, relation)
  local support = relation.support
  local frame, offset = carrier:getRefNodeMatrix(), relation.offset
  if support then
    local byName, nodes = {}, {}
    for _, node in pairs(nodesOf(carrier)) do byName[node.name or ''] = node end
    for index, name in ipairs(support.nodes or {}) do nodes[index] = byName[name] end
    local cluster = mainCluster(carrier)
    local intact = nodes[1] and nodes[2] and nodes[3]
    for _, node in pairs(nodes) do intact = intact and connected(carrier,node,cluster) end
    local supported = intact and frameFromNodes(carrier,nodes)
    -- The chassis offset is captured alongside support data and stays valid when that part detaches.
    if supported then frame,offset=supported,support.offset end
  end
  if not frame or type(offset) ~= 'table' then return nil end
  local relative = MatrixF(true)
  relative:setFromEuler(vec3(tonumber(offset.rx) or 0, tonumber(offset.ry) or 0, tonumber(offset.rz) or 0))
  relative:setPosition(vec3(tonumber(offset.x) or 0, tonumber(offset.y) or 0, tonumber(offset.z) or 0))
  return frame * relative
end

return M
