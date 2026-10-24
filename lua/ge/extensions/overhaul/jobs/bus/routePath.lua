-- Bus guidance: ordered stop waypoints and the direction-aware ground-marker path.
-- readState reads the bus owner on each public call; this part never changes route progress.
local FORWARD_GUIDANCE_M = 25
local START_POINT_SKIP_M = 10
local MIN_PATH_SPACING_M = 5
local ROUTE_PENALTY = 1e6

return function(core_groundMarkers, readState)
  -- Owner locals read (never written) below; readState() returns their current values.
  local currentStopIndex, routeItems, stopTriggers
  local function getItemPosition(item)
    return item.position or (item.trigger and item.trigger:getPosition())
  end

  local function buildPathToStop(targetStopIndex, startPos, fromStopIndex)
    local pathPoints = {startPos}
    if not routeItems or #routeItems == 0 then
      return pathPoints
    end

    if not stopTriggers or #stopTriggers == 0 then
      return pathPoints
    end

    local currentStopIdx = fromStopIndex or currentStopIndex or 1
    local nextStopIndex = targetStopIndex
    if nextStopIndex > #stopTriggers then
      nextStopIndex = 1
    end

    local currentItemIndex = nil
    for i, item in ipairs(routeItems) do

      if item.type == "stop" and item.precedingStopIndex == currentStopIdx then
        currentItemIndex = i
        break
      end
        end
    if not currentItemIndex then
      for i, item in ipairs(routeItems) do
        if item.type == "stop" and item.precedingStopIndex == nextStopIndex then
          local pos = getItemPosition(item)
          if pos then
            table.insert(pathPoints, pos)
          end
          return pathPoints
        end
      end
      return pathPoints
    end

    for i = currentItemIndex + 1, #routeItems do
      local item = routeItems[i]
      if item.type == "waypoint" then
        local pos = getItemPosition(item)
        if pos then table.insert(pathPoints, pos) end
      elseif item.type == "stop" then
        if item.precedingStopIndex == nextStopIndex then
          local pos = getItemPosition(item)
          if pos then table.insert(pathPoints, pos) end
          break
        elseif item.precedingStopIndex > nextStopIndex then
          break
        end
      end
    end

    return pathPoints
  end

  local function setupRoutePlannerWithWaypoints(pathPoints, targetPos)
    if not pathPoints or #pathPoints == 0 then
      log('W', 'bus', "Warning: No path points provided, using direct path to target")
      core_groundMarkers.setPath(targetPos, {clearPathOnReachingTarget = false})
      return
    end

    local vehicle = be:getPlayerVehicle(0)
    if not vehicle then
      core_groundMarkers.setPath(targetPos, {clearPathOnReachingTarget = false})
      return
    end

    local vehPos = vehicle:getPosition()
    local vehDir = vehicle:getDirectionVector()

    local adjustedPathPoints = {}

    local forwardPoint = vehPos + vehDir * FORWARD_GUIDANCE_M
    table.insert(adjustedPathPoints, forwardPoint)

    for i, point in ipairs(pathPoints) do
      -- The forward lead replaces a nearby start point, avoiding an immediate turn behind the bus.
      if not (i == 1 and vehPos:distance(point) < START_POINT_SKIP_M) then
        local lastPoint = adjustedPathPoints[#adjustedPathPoints]
        if lastPoint:distance(point) > MIN_PATH_SPACING_M then
          table.insert(adjustedPathPoints, point)
        end
      end
    end

    local lastPoint = adjustedPathPoints[#adjustedPathPoints]
    if lastPoint:distance(targetPos) > MIN_PATH_SPACING_M then
      table.insert(adjustedPathPoints, targetPos)
    end

    core_groundMarkers.setPath(targetPos, {clearPathOnReachingTarget = false})

    if core_groundMarkers.routePlanner then
      core_groundMarkers.routePlanner:setRouteParams(nil, ROUTE_PENALTY, nil, nil, nil, nil)
      core_groundMarkers.routePlanner:setupPathMulti(adjustedPathPoints)
      if core_groundMarkers.sendToApp then
        core_groundMarkers.sendToApp()
      end
    end
  end

  return {
    buildPathToStop = function(...)
      currentStopIndex, routeItems, stopTriggers = readState()
      return buildPathToStop(...)
    end,
    setupRoutePlannerWithWaypoints = function(...)
      currentStopIndex, routeItems, stopTriggers = readState()
      return setupRoutePlannerWithWaypoints(...)
    end,
  }
end
