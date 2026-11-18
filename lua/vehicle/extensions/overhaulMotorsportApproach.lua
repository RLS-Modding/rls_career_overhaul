local M = {}
local active, pending, corridor, savedSetMap, mapGuard, savedParameters

local function finite(value) return type(value) == 'number' and value == value and math.abs(value) < math.huge end

function M.clear()
  if not active then return end
  active, pending = false, nil
  if mapmgr.setMap == mapGuard then mapmgr.setMap = savedSetMap end
  if corridor and mapmgr.mapData == corridor then
    ai.setMode('disabled')
    mapmgr.clearCustomMap()
    savedSetMap()
    mapmgr.requestMap()
  end
  if savedParameters then ai.setParameters(savedParameters) end
  corridor, savedSetMap, mapGuard, savedParameters = nil, nil, nil, nil
end

local function drive(points)
  local graph, path, speeds = require('graphpath').newGraphpath(), {}, {}
  for index, point in ipairs(points) do
    local name, position = 'motorsportApproach_' .. index, vec3(point)
    graph:setPointPositionRadius(name, position, .8)
    path[index] = name
    speeds[name] = index <= 3 and 2.5 or index >= #points - 2 and 1.4 or 3.5
    if index > 1 then graph:uniEdge(path[index - 1], name, position:distance(vec3(points[index - 1])), 1, 0, '+', true) end
  end
  savedSetMap = mapmgr.setMap
  local nativeSetMap = savedSetMap
  mapGuard = function(...)
    if active and mapmgr.mapData == corridor then return end
    return nativeSetMap(...)
  end
  mapmgr.setMap = mapGuard
  savedParameters = deepcopy(ai.getParameters())
  ai.driveUsingPath({path = path, wpSpeeds = speeds, routeSpeed = 3.5, routeSpeedMode = 'limit',
    aggression = .3, avoidCars = 'on', driveInLane = 'off', lookAheadKv = .1,
    throttleTcs = 'on', oversteerThrottleControl = 'on', understeerThrottleControl = 'on'})
  corridor = graph
  mapmgr.setCustomMap(graph)
end

function M.start(points)
  if active or playerInfo and playerInfo.anyPlayerSeated or type(points) ~= 'table' or #points < 3 then return false end
  for index, point in ipairs(points) do
    if type(point) ~= 'table' then return false end
    for axis = 1, 3 do if not finite(point[axis]) then return false end end
    if index > 1 and vec3(point):distance(vec3(points[index - 1])) < .01 then return false end
  end
  active = true
  ai:scriptStop(true, false)
  ai.setMode('disabled')
  controller.setFreeze(0)
  if electrics.setIgnitionLevel and electrics.values.engineRunning == 0 and electrics.values.ignitionLevel ~= 3 then electrics.setIgnitionLevel(3) end
  input.event('brake', 0, 2)
  input.event('parkingbrake', 0, 2)
  if not mapmgr.nodeAliases or not mapmgr.rules then
    pending = points
    mapmgr.requestMap()
    return true
  end
  local ok, err = pcall(drive, points)
  if not ok then M.clear(); log('E', 'motorsportApproach', tostring(err)); return false end
  return true
end

function M.onPlayersChanged(seated)
  if seated then M.clear(); extensions.unload('overhaulMotorsportApproach') end
end

function M.updateGFX()
  if not active then return end
  if playerInfo and playerInfo.anyPlayerSeated then M.onPlayersChanged(true); return end
  if pending and mapmgr.nodeAliases and mapmgr.rules then
    local points = pending
    pending = nil
    local ok, err = pcall(drive, points)
    if not ok then M.clear(); log('E', 'motorsportApproach', tostring(err)) end
  end
end

M.onReset = M.clear
M.onExtensionUnloaded = M.clear
return M
