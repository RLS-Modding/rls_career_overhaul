-- Owns NPC driving between paddock and staging.
-- drag/parking.lua supplies vehicles; drag/runner.lua starts and updates the approach lifetime.
local M = {}

local function finite(value)
  return type(value) == 'number' and value == value and math.abs(value) < math.huge
end

local roadDefaults = {
  alignmentDistanceMeters = 8, mergeAdvanceMaxMeters = 8, mergeAdvanceFraction = .35,
  pullOutDistanceMeters = 7, forwardControlMaxMeters = 8, forwardControlFraction = .55,
  roadControlMaxMeters = 5, roadControlFraction = .4, leadInDistanceMeters = 3,
  mergeCurveStepsCount = 8, laneOverrunDistanceMeters = 2,
  minimumTimeoutSeconds = 30, timeoutSpeedMetersPerSecond = 2, timeoutPaddingSeconds = 15
}
local sharedRoadTuning
local function validTuning(name, value)
  if not finite(value) or value < 0 then return false end
  if name == 'mergeAdvanceFraction' then return value < 1 end
  if name == 'forwardControlFraction' or name == 'roadControlFraction' then return value <= 1 end
  if name == 'mergeCurveStepsCount' then return value % 1 == 0 and value >= 1 and value <= 64 end
  if name == 'minimumTimeoutSeconds' or name == 'timeoutSpeedMetersPerSecond' then return value > 0 end
  return true
end

local function roadTuning(settings)
  if not sharedRoadTuning then
    local ok, data = pcall(jsonReadFile, '/settings/motorsportEvents/approach.json')
    if not ok or type(data) ~= 'table' or data.version ~= 1 then data = {} end
    sharedRoadTuning = {}
    for name, fallback in pairs(roadDefaults) do
      sharedRoadTuning[name] = validTuning(name, data[name]) and data[name] or fallback
    end
  end
  local overrides = settings.approachRoadTuning
  if overrides == nil then return sharedRoadTuning end
  if type(overrides) ~= 'table' then
    log('W', 'motorsportApproach', 'Invalid approachRoadTuning; using shared tuning.')
    return sharedRoadTuning
  end
  local tuning = {}
  for name, fallback in pairs(sharedRoadTuning) do
    local value = overrides[name]
    if value ~= nil and not validTuning(name, value) then
      log('W', 'motorsportApproach', 'Invalid approachRoadTuning.' .. name .. '; using shared tuning.')
      value = nil
    end
    tuning[name] = value == nil and fallback or value
  end
  return tuning
end

local function nearestSegment(points, position)
  local best, fraction, projected, distance
  for index = 1, #points - 1 do
    local delta = points[index + 1] - points[index]
    local t = math.max(0, math.min(1, (position - points[index]):dot(delta) / delta:squaredLength()))
    local p = points[index] + delta * t
    local d = p:distance(position)
    if not distance or d < distance then best, fraction, projected, distance = index, t, p, d end
  end
  return best, fraction, projected
end

local function roadPath(vehicle, lane, settings, target, forward)
  local name = settings and settings.approachRoad
  if type(name) == 'table' then
    local label = tostring(lane.longName or lane.shortName or lane.name or ''):lower()
    local side = label:find('left', 1, true) and 'left' or label:find('right', 1, true) and 'right'
    name = name[lane.id] or name[side] or name.default
  end
  if name == nil then return end
  local road = type(name) == 'string' and scenetree.findObject(name)
  if not road or road:getClassName() ~= 'DecalRoad' then return nil, 'Approach road is not a named DecalRoad: ' .. tostring(name) end
  local tuning = roadTuning(settings)
  local nodes = {}
  for index = 0, road:getNodeCount() - 1 do
    local p = road:getNodePosition(index)
    if not p or not finite(p.x) or not finite(p.y) or not finite(p.z) then return nil, 'Approach road has invalid nodes: ' .. name end
    p = vec3(p)
    if #nodes == 0 or nodes[#nodes]:distance(p) > .05 then nodes[#nodes + 1] = p end
  end
  if #nodes < 2 then return nil, 'Approach road needs two distinct nodes: ' .. name end
  if settings.approachRoadReverse == true then
    for i = 1, math.floor(#nodes / 2) do nodes[i], nodes[#nodes + 1 - i] = nodes[#nodes + 1 - i], nodes[i] end
  end
  local position, heading = vehicle:getPosition(), vehicle:getDirectionVector():normalized()
  local alignment = target - forward * tuning.alignmentDistanceMeters
  local first, startFraction, join = nearestSegment(nodes, position)
  local last, endFraction, handoff = nearestSegment(nodes, alignment)
  if first + startFraction >= last + endFraction then return nil, 'Approach road runs away from staging; check its node order: ' .. name end
  local remaining = 0
  local previousJoin = join
  for index = first + 1, last do
    remaining = remaining + previousJoin:distance(nodes[index])
    previousJoin = nodes[index]
  end
  remaining = remaining + previousJoin:distance(handoff)
  local advance = math.min(tuning.mergeAdvanceMaxMeters, remaining * tuning.mergeAdvanceFraction)
  while advance > .001 do
    local nextNode = nodes[first + 1]
    local distance = join:distance(nextNode)
    if advance < distance then
      join = join + (nextNode - join) * (advance / distance)
      break
    end
    advance, join, first = advance - distance, nextNode, first + 1
  end
  local tangent = (nodes[first + 1] - nodes[first]):normalized()
  local exit = position + heading * tuning.pullOutDistanceMeters
  local mergeDistance = exit:distance(join)
  local controlA = exit + heading * math.min(tuning.forwardControlMaxMeters, mergeDistance * tuning.forwardControlFraction)
  local controlB = join - tangent * math.min(tuning.roadControlMaxMeters, mergeDistance * tuning.roadControlFraction)
  local points, length, previous = {}, 0, nil
  local function add(p)
    if previous and previous:distance(p) <= .05 then return end
    length = length + (previous and previous:distance(p) or 0)
    points[#points + 1], previous = {p.x, p.y, p.z}, p
  end
  add(position - heading * tuning.leadInDistanceMeters)
  add(position)
  add(exit)
  for index = 1, tuning.mergeCurveStepsCount do
    local t, u = index / tuning.mergeCurveStepsCount, 1 - index / tuning.mergeCurveStepsCount
    add(exit * (u * u * u) + controlA * (3 * u * u * t) + controlB * (3 * u * t * t) + join * (t * t * t))
  end
  for index = first + 1, last do add(nodes[index]) end
  add(handoff)
  add(alignment)
  add(target)
  add(target + forward * tuning.laneOverrunDistanceMeters)
  return points, nil, math.max(tuning.minimumTimeoutSeconds, length / tuning.timeoutSpeedMetersPerSecond + tuning.timeoutPaddingSeconds)
end

local function approachSettings()
  local level = getCurrentLevelIdentifier and getCurrentLevelIdentifier()
  if not level then return end
  local path = '/levels/' .. level .. '/overhaul/motorsport/motorsportPaddock.json'
  if FS and FS:fileExists(path) then
    local settings = jsonReadFile(path)
    return type(settings) == 'table' and settings or nil
  end
end

local function buildPath(vehicle, lane, settings)
  if not vehicle or not vehicle.getDirectionVector then return end
  local target, forward = lane.waypoints.spawn.transform.pos, lane.stageToEndNormalized
  if not forward or forward:squaredLength() < .01 then return end
  forward = forward:normalized()
  local authored, error, timeout = roadPath(vehicle, lane, settings, target, forward)
  if authored then return authored, forward, timeout end
  if error then log('W', 'motorsportApproach', error .. '; using the default approach.') end
  local position, heading = vehicle:getPosition(), vehicle:getDirectionVector():normalized()
  local exit = position + heading * 7
  local distance = exit:distance(target)
  local controlA, controlB = exit + heading * math.min(12, distance * .35), target - forward * math.min(16, distance * .4)
  local points = {}
  local function add(p) points[#points + 1] = {p.x, p.y, p.z} end
  add(position - heading * 3)
  add(position)
  add(exit)
  for index = 1, 16 do
    local t, u = index / 16, 1 - index / 16
    add(exit * (u * u * u) + controlA * (3 * u * u * t) + controlB * (3 * u * t * t) + target * (t * t * t))
  end
  add(target + forward * 2)
  return points, forward
end

function M.clear(rows)
  for _, row in ipairs(rows or {}) do
    local vehicle = be:getObjectByID(row.id)
    if row.controlledApproach then
      if vehicle then vehicle:queueLuaCommand("extensions.unload('overhaulMotorsportApproach')") end
      row.controlledApproach = nil
    end
    if row.approachHolding then
      if vehicle then vehicle:queueLuaCommand("controller.setFreeze(0)") end
      row.approachHolding = nil
    end
  end
end

local function hold(row, vehicle)
  M.clear({row})
  vehicle:queueLuaCommand("ai:scriptStop(true, false); ai.setMode('disabled'); input.event('parkingbrake', 0, 2); controller.setFreeze(1)")
  row.approachHolding = true
end

function M.start(rows, data)
  local settings = approachSettings()
  local playerPass = false
  for _, row in ipairs(rows) do if row.entrant.player then playerPass = true end end
  for _, row in ipairs(rows) do
    if not row.entrant.player and not row.arrived then
      row.approachElapsed = 0
      row.approachDrivingElapsed = nil
      row.approachTimeout = nil
      local spawn = data.strip.lanes[row.lane].waypoints.spawn
      row.approachTarget = spawn.transform.pos
      row.approachTransform = spawn.transform
      local points, direction, timeout = buildPath(be:getObjectByID(row.id), data.strip.lanes[row.lane], settings)
      row.approachTimeout = timeout
      if points then
        row.controlledApproach, row.approachDirection = true, direction
        row.approachCommand = "extensions.load('overhaulMotorsportApproach'); overhaulMotorsportApproach.start(" .. serialize(points) .. ")"
      end
      local route, node = {}, map.getMap().nodes[spawn.name]
      for name, link in pairs(node and node.links or {}) do
        if link.oneWay and link.inNode == name then route[#route + 1] = name; break end
      end
      route[#route + 1] = spawn.name
      row.approachDelay = not playerPass and row.lane == 2 and 7 or 0
      row.approachCommand = row.approachCommand or "if electrics.setIgnitionLevel then electrics.setIgnitionLevel(3) end; controller.setFreeze(0); input.event('parkingbrake', 0, 2); ai.setState({mode='manual'}); ai.driveUsingPath(" .. serialize({wpTargetList = route, routeSpeed = 4, routeSpeedMode = 'limit', aggression = .3, avoidCars = 'on', driveInLane = 'on'}) .. ")"
    end
  end
end

function M.update(rows, dtSim)
  local ready = true
  for _, row in ipairs(rows) do
    if not row.entrant.player and not row.arrived then
      local vehicle = be:getObjectByID(row.id)
      if not vehicle then return nil, 'A paddock driver left before staging.' end
      if be.getPlayerVehicleID and row.id == be:getPlayerVehicleID(0) then return nil, 'Leave the opponent vehicle before staging.' end
      row.approachElapsed = row.approachElapsed + dtSim
      if row.approachCommand and row.approachElapsed >= row.approachDelay then
        vehicle:queueLuaCommand(row.approachCommand)
        row.approachCommand = nil
        row.approachDrivingElapsed = 0
      elseif row.approachDrivingElapsed then
        row.approachDrivingElapsed = row.approachDrivingElapsed + dtSim
      end
      local aligned = not row.approachDirection or vehicle:getDirectionVector():dot(row.approachDirection) > .9
      if vehicle:getPosition():distance(row.approachTarget) < (row.controlledApproach and 4 or 6) and vehicle:getVelocity():length() < 2 and aligned then
        hold(row, vehicle)
        row.arrived = true
      elseif (row.approachDrivingElapsed or 0) >= (row.approachTimeout or 30) then
        M.clear({row})
        vehicle:reset()
        spawn.safeTeleport(vehicle, row.approachTransform.pos, row.approachTransform.rot, nil, nil, false, true, false)
        hold(row, vehicle)
        row.approachCommand, row.arrived = nil, true
      else ready = false end
    end
  end
  return ready
end

return M
