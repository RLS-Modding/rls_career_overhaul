-- Road geometry, curvature checkpoints and stationary/off-road race monitoring.
-- Read geometry and named segmentation/joining steps, monitoring timers, route loading and public services.
local factory = {}

function factory.create(inputs)
  inputs = inputs or {}
  local instance = inputs.exports or {}

  -- State -------------------------------------------------------------------------------------------

  local roadNodes = {}
  local altRoadNodes = {}

  -- Constants for road nodes
  local checkpoints = {}
  local altCheckpoints = {}

  -- Config ------------------------------------------------------------------------------------------

  local STRAIGHT_THRESHOLD = math.rad(10) -- Angle threshold for straight segments
  local HAIRPIN_THRESHOLD = math.rad(120) -- Angle threshold for hairpin turns
  local MIN_SEGMENT_LENGTH = 20 -- Minimum length for a segment in meters
  local MAX_TURN_MERGE_ANGLE = math.rad(20) -- Maximum angle difference to merge turns
  local MIN_CHECKPOINT_DISTANCE = 90 -- Minimum distance between checkpoints
  local CURVATURE_WINDOW = 3 -- Number of nodes to consider on each side for curvature calculation

  local MAX_MERGE_DISTANCE = 50
  local END_SEARCH_RANGE = 0.2

  -- Player off road constants
  local MAX_DISTANCE_FROM_PATH = 10 -- meters
  local ALERT_COOLDOWN = 3 -- seconds
  local WRONG_DIRECTION_THRESHOLD = 0.5 -- cosine of angle
  local lastAlertTime = 0
  local raceTime = 0
  local nextNodeIndex = 2
  local exitCountdown = 0
  local exitCountdownStart = 5
  local lastCountdownTime = 0

  local STATIONARY_TIMEOUT = 10
  local stationaryTimeout = STATIONARY_TIMEOUT -- Race-specific timeout (defaults to constant)
  local lastMovementTime = nil
  local lastCountdownUpdate = nil
  local remainingTime = stationaryTimeout

  local activeRace = nil

  -- Helpers -----------------------------------------------------------------------------------------

  local function freeroamRaceHudCriticalWarning(text)
    if inputs.preview then
      if inputs.onCriticalWarning then inputs.onCriticalWarning(text) end
      return
    end
    if text and text ~= "" then
      guihooks.trigger("FreeroamRaceHudCriticalWarning", { text = text })
    else
      guihooks.trigger("FreeroamRaceHudCriticalWarning", {})
    end
  end

  local function calculateDistance(node1, node2)
    if not node1 or not node2 then return 0 end
    local dx, dy = node2.x - node1.x, node2.y - node1.y
    return math.sqrt(dx * dx + dy * dy)
  end

  local function calculateAngle(node1, node2, node3)
    if not node1 or not node2 or not node3 then return 0, "straight" end
    local vec1 = {
      x = node2.x - node1.x,
      y = node2.y - node1.y,
    }
    local vec2 = {
      x = node3.x - node2.x,
      y = node3.y - node2.y,
    }
    local angle = math.atan2(vec2.y, vec2.x) - math.atan2(vec1.y, vec1.x)

    if angle > math.pi then
      angle = angle - 2 * math.pi
    elseif angle < -math.pi then
      angle = angle + 2 * math.pi
    end

    local degrees = math.deg(angle)
    local direction = "straight"
    if degrees > 1 then
      direction = "left"
    elseif degrees < -1 then
      direction = "right"
    end

    return angle, direction, degrees
  end

  local function calculateCurvature(nodes, index)
    local sum = 0
    local count = 0
    for i = math.max(1, index - CURVATURE_WINDOW), math.min(#nodes - 2, index + CURVATURE_WINDOW) do
      sum = sum + math.abs(calculateAngle(nodes[i], nodes[i + 1], nodes[i + 2]))
      count = count + 1
    end
    return sum / count
  end

  local function findApex(nodes, startIndex, endIndex)
    local maxCurvature = 0
    local apexIndex = startIndex
    for i = startIndex, endIndex do
      local prevNode = nodes[math.max(1, i - 1)]
      local currNode = nodes[i]
      local nextNode = nodes[math.min(#nodes, i + 1)]
      local angle, _, _ = calculateAngle(prevNode, currNode, nextNode)
      local curvature = math.abs(angle)
      if curvature > maxCurvature then
        maxCurvature = curvature
        apexIndex = i
      end
    end
    local apexOffset = activeRace.apexOffset or 0
    apexOffset = activeRace.reverse and -apexOffset or apexOffset
    apexIndex = nodes[apexIndex + apexOffset] and apexIndex + apexOffset or #nodes
    return apexIndex
  end

  local function hasCheckpointAtPosition(checkpoints, newPos)
    for _, checkpoint in ipairs(checkpoints) do
      if checkpoint.node.x == newPos.x and checkpoint.node.y == newPos.y and checkpoint.node.z == newPos.z then
        return true
      end
    end
    return false
  end

  local function addRouteCheckpoint(nodes, checkpoints, startIndex, endIndex, type, direction)
    local apexIndex = findApex(nodes, startIndex, endIndex)
    local roadWidth = 20

    if #checkpoints > 0 then
      local lastCheckpoint = checkpoints[#checkpoints]
      if lastCheckpoint.direction == direction then
        local distance = calculateDistance(nodes[lastCheckpoint.index], nodes[apexIndex])
        if distance < MIN_CHECKPOINT_DISTANCE then
          if calculateCurvature(nodes, apexIndex) > calculateCurvature(nodes, lastCheckpoint.index) then
            if not hasCheckpointAtPosition(checkpoints, nodes[apexIndex]) then
              checkpoints[#checkpoints] = {
                node = nodes[apexIndex],
                type = type,
                index = apexIndex,
                direction = direction,
              }
            end
          end
          return
        end
      end
    end

    if not hasCheckpointAtPosition(checkpoints, nodes[apexIndex]) then
      table.insert(checkpoints, {
        node = nodes[apexIndex],
        type = type,
        index = apexIndex,
        direction = direction,
      })
    end
  end

  local function finishRouteSegment(nodes, segments, checkpoints, currentSegment, endIndex)
    if currentSegment.length >= MIN_SEGMENT_LENGTH then
      table.insert(segments, currentSegment)
      if currentSegment.type == "turn" or currentSegment.type == "hairpin" then
        addRouteCheckpoint(nodes, checkpoints, currentSegment.startIndex, endIndex, currentSegment.type, currentSegment.direction)
      end
    end
  end

  local function advanceRouteSegment(nodes, segments, checkpoints, currentSegment, i)
    local angle = calculateAngle(nodes[i - 1], nodes[i], nodes[i + 1])
    currentSegment.totalAngle = currentSegment.totalAngle + angle
    currentSegment.length = currentSegment.length + calculateDistance(nodes[i - 1], nodes[i])

    if math.abs(angle) > STRAIGHT_THRESHOLD then
      local newDirection = angle > 0 and "left" or "right"
      if currentSegment.type == "straight" then
        finishRouteSegment(nodes, segments, checkpoints, currentSegment, i - 1)
        currentSegment = {
          startIndex = i - 1,
          type = "turn",
          direction = newDirection,
          totalAngle = angle,
          length = 0,
        }
      elseif currentSegment.type == "turn" then
        if currentSegment.direction ~= newDirection then
          finishRouteSegment(nodes, segments, checkpoints, currentSegment, i - 1)
          currentSegment = {
            startIndex = i - 1,
            type = "turn",
            direction = newDirection,
            totalAngle = angle,
            length = 0,
          }
        elseif math.abs(currentSegment.totalAngle - angle) > MAX_TURN_MERGE_ANGLE then
          addRouteCheckpoint(nodes, checkpoints, currentSegment.startIndex, i, "turn", newDirection)
          currentSegment.totalAngle = angle
          currentSegment.startIndex = i
        end
      end
    elseif currentSegment.type == "turn" and currentSegment.length >= MIN_SEGMENT_LENGTH then
      finishRouteSegment(nodes, segments, checkpoints, currentSegment, i - 1)
      currentSegment = {
        startIndex = i - 1,
        type = "straight",
        totalAngle = 0,
        length = 0,
        direction = nil,
      }
    end

    if math.abs(currentSegment.totalAngle) > HAIRPIN_THRESHOLD then
      currentSegment.type = "hairpin"
      finishRouteSegment(nodes, segments, checkpoints, currentSegment, i)
      currentSegment = {
        startIndex = i,
        type = "straight",
        totalAngle = 0,
        length = 0,
        direction = nil,
      }
    end
    return currentSegment
  end

  local function processRoute(nodes, isAlt)
    local segments = {}
    local checkpoints = {}
    local currentSegment = {
      startIndex = 1,
      type = "straight",
      totalAngle = 0,
      length = 0,
      direction = nil,
    }
    local startIndex = isAlt and 3 or 1 -- Start from the 3rd node for alternative route

    for i = startIndex + 1, #nodes - 1 do
      currentSegment = advanceRouteSegment(nodes, segments, checkpoints, currentSegment, i)
    end
    finishRouteSegment(nodes, segments, checkpoints, currentSegment, #nodes)
    return checkpoints
  end

  local function adjustLastCheckpoint(checkpoints, nodes)
    if #checkpoints >= 2 then
      local firstCheckpoint = checkpoints[1]
      local lastCheckpoint = checkpoints[#checkpoints]
      local distance = calculateDistance(firstCheckpoint.node, lastCheckpoint.node)

      if distance < MIN_CHECKPOINT_DISTANCE then
        local newLastIndex = lastCheckpoint.index
        while
          newLastIndex > 1
          and calculateDistance(nodes[newLastIndex], firstCheckpoint.node) < MIN_CHECKPOINT_DISTANCE
        do
          newLastIndex = newLastIndex - 1
        end

        if newLastIndex > 1 and newLastIndex ~= lastCheckpoint.index then
          lastCheckpoint.node = nodes[newLastIndex]
          lastCheckpoint.index = newLastIndex
        else
        end
      end
    end
  end

  local function processRoadNodes(mainNodes, altNodes)
    mainNodes = mainNodes or {}
    if not altNodes then altNodes = {} end

    local mainCheckpoints = processRoute(mainNodes, false)
    local altCheckpoints = altNodes and processRoute(altNodes, true) or nil

    -- Adjust the last checkpoint if it's too close to the first one (for both routes)
    adjustLastCheckpoint(mainCheckpoints, mainNodes)
    if altCheckpoints then adjustLastCheckpoint(altCheckpoints, altNodes) end

    return mainCheckpoints, altCheckpoints
  end

  local function getRoad(roadName)
    local road = scenetree.findObject(roadName)
    if road and road:getClassName() == "DecalRoad" then
      return road
    else
      return nil
    end
  end

  local function getRoadNodes(roadName)
    local road = scenetree.findObject(roadName)
    if not road or road:getClassName() ~= "DecalRoad" then return end
    local nodeTable = road:getNodesTable()

    local nodeCount = road:getNodeCount()

    local roadNodes = {}
    for i = 0, nodeCount - 1 do
      local pos = road:getNodePosition(i)
      table.insert(roadNodes, {
        x = pos.x,
        y = pos.y,
        z = pos.z,
        width = nodeTable[i + 1][2],
      })
    end
    return roadNodes
  end

  local function findClosestEndPoints(nodes1, nodes2)
    local connections = {}
    local searchRange1 = math.floor(#nodes1 * END_SEARCH_RANGE)
    local searchRange2 = math.floor(#nodes2 * END_SEARCH_RANGE)

    local function checkConnection(start1, end1, start2, end2, isStart1, isStart2)
      local minDist = math.huge
      local bestIndex1, bestIndex2

      for i = start1, end1, start1 < end1 and 1 or -1 do
        for j = start2, end2, start2 < end2 and 1 or -1 do
          local dist = calculateDistance(nodes1[i], nodes2[j])
          if dist < minDist then
            minDist = dist
            bestIndex1, bestIndex2 = i, j
          end
        end
      end

      if minDist <= MAX_MERGE_DISTANCE then
        table.insert(connections, {
          index1 = bestIndex1,
          index2 = bestIndex2,
          distance = minDist,
          isStart1 = isStart1,
          isStart2 = isStart2,
        })
      end
    end

    checkConnection(1, searchRange1, 1, searchRange2, true, true)
    checkConnection(1, searchRange1, #nodes2, #nodes2 - searchRange2 + 1, true, false)
    checkConnection(#nodes1, #nodes1 - searchRange1 + 1, 1, searchRange2, false, true)
    checkConnection(#nodes1, #nodes1 - searchRange1 + 1, #nodes2, #nodes2 - searchRange2 + 1, false, false)

    table.sort(connections, function(a, b)
      return a.distance < b.distance
    end)
    return connections
  end

  -- Modify the mergeTwoRoads function to preserve first road direction
  local function createRoadJunction(node1, node2)
    return {
      x = (node1.x + node2.x) / 2,
      y = (node1.y + node2.y) / 2,
      z = (node1.z + node2.z) / 2,
      width = (node1.width + node2.width) / 2,
      isJunction = true,
    }
  end

  local function mergeSingleConnectedRoads(nodes1, nodes2, connections, mergedNodes)
    local conn = connections[1]
    local connectionIndex = conn.index1
    local isEnd1 = not conn.isStart1 -- Is the connection at the end of the first road?
    local isStart2 = conn.isStart2 -- Is the connection at the start of the second road?

    -- Add junction at the connection point
    -- Replace the original node with a junction
    mergedNodes[connectionIndex] = createRoadJunction(nodes1[connectionIndex], nodes2[conn.index2])

    -- Now add nodes from second road (all except the connection node)
    -- Direction depends on whether we connected to start or end of road2
    if isStart2 then
      -- Start with second node (skip the junction), go to end
      for i = 2, #nodes2 do
        table.insert(mergedNodes, nodes2[i])
      end
    else
      -- Start with second-to-last node, go to beginning
      for i = #nodes2 - 1, 1, -1 do
        table.insert(mergedNodes, nodes2[i])
      end
    end
    return mergedNodes
  end

  local function mergeDoubleConnectedRoads(nodes1, nodes2, connections)
    -- Rebuild the joined route in the first road direction when both ends connect.
    local mergedNodes = {}

    local conn1, conn2 = connections[1], connections[2]

    -- We always want to preserve the first road's direction
    -- So we need to determine if we need to reverse the second road
    local reverseRoad2 = false

    -- If the connection points are at the same end of both roads (both start or both end)
    -- then we need to reverse one of them - always reverse the second road
    if conn1.isStart1 == conn1.isStart2 then reverseRoad2 = true end

    -- Add nodes from the first road normally
    for i = 1, #nodes1 do
      table.insert(mergedNodes, nodes1[i])
    end

    -- Add junction at the connection point
    -- The junction replaces the connection node from road1
    local junctionIndex = conn1.isStart1 and 1 or #mergedNodes
    mergedNodes[junctionIndex] = createRoadJunction(nodes1[conn1.index1], nodes2[conn1.index2])

    -- Add nodes from road2 based on needed direction
    -- Skip the connection node that's now a junction
    if reverseRoad2 then
      for i = #nodes2, 1, -1 do
        if i ~= conn1.index2 then -- Skip the junction node
          table.insert(mergedNodes, nodes2[i])
        end
      end
    else
      for i = 1, #nodes2 do
        if i ~= conn1.index2 then -- Skip the junction node
          table.insert(mergedNodes, nodes2[i])
        end
      end
    end

    return mergedNodes
  end

  local function mergeTwoRoads(nodes1, nodes2)
    local connections = findClosestEndPoints(nodes1, nodes2)
    if #connections == 0 then return nil end
    local mergedNodes = {}
    local junctions = {}
    for i = 1, #nodes1 do table.insert(mergedNodes, nodes1[i]) end
    if #connections == 1 then
      return mergeSingleConnectedRoads(nodes1, nodes2, connections, mergedNodes, junctions)
    end
    return mergeDoubleConnectedRoads(nodes1, nodes2, connections)
  end

  -- New wrapper function that handles multiple roads
  local function mergeRoads(roads)
    if type(roads) ~= "table" or #roads < 1 then return nil end

    -- If only one road provided, just return its nodes
    if #roads == 1 then return getRoadNodes(roads[1]) end

    -- Start with the first road's nodes
    local result = getRoadNodes(roads[1])
    if not result then
      log("W", "roadCheckpoints", "First road not found or invalid: " .. roads[1])
      return nil
    end

    -- Iteratively merge each additional road
    for i = 2, #roads do
      local nextRoadNodes = getRoadNodes(roads[i])
      if not nextRoadNodes then
        log("W", "roadCheckpoints", "Road not found or invalid: " .. roads[i])
        goto continue
      end

      -- Merge the accumulated result with the next road
      local mergedResult = mergeTwoRoads(result, nextRoadNodes)
      if mergedResult then
        result = mergedResult
      else
        log("W", "roadCheckpoints", "Failed to merge road " .. roads[i])
      end

      ::continue::
    end

    return result
  end

  local function distanceToLineSegment(point, lineStart, lineEnd)
    local ax, ay, az = lineStart.x, lineStart.y, lineStart.z
    local abx = lineEnd.x - ax
    local aby = lineEnd.y - ay
    local abz = lineEnd.z - az
    local apx = point.x - ax
    local apy = point.y - ay
    local apz = point.z - az
    local lineLengthSq = abx * abx + aby * aby + abz * abz

    if lineLengthSq < 0.000001 then -- Check if line segment is too short
      return math.sqrt(apx * apx + apy * apy + apz * apz), 0
    end

    local t = (apx * abx + apy * aby + apz * abz) / lineLengthSq
    t = math.max(0, math.min(1, t))

    local dx = apx - abx * t
    local dy = apy - aby * t
    local dz = apz - abz * t
    return math.sqrt(dx * dx + dy * dy + dz * dz), t
  end

  local function findNearestNode(vehiclePos, nodes)
    if not nodes or #nodes == 0 then return nil, nil end
    local nearestIndex = 1
    local minDistanceSq = math.huge
    local px, py, pz = vehiclePos.x, vehiclePos.y, vehiclePos.z
    for i, node in ipairs(nodes) do
      local dx = px - node.x
      local dy = py - node.y
      local dz = pz - node.z
      local distanceSq = dx * dx + dy * dy + dz * dz
      if distanceSq < minDistanceSq then
        minDistanceSq = distanceSq
        nearestIndex = i
      end
    end
    return nearestIndex, minDistanceSq
  end

  local function updateRoadStationaryTimeout(speedSq, currentTime)
    if speedSq < 0.25 then -- Very low speed threshold
      if not lastMovementTime then
        lastMovementTime = currentTime
        lastCountdownUpdate = currentTime
        remainingTime = stationaryTimeout
      else
        local timeStopped = currentTime - lastMovementTime

        if currentTime - lastCountdownUpdate >= 1 then
          remainingTime = math.ceil(stationaryTimeout - timeStopped)
          lastCountdownUpdate = currentTime

          if remainingTime > 0 then
            freeroamRaceHudCriticalWarning("Warning: Move your vehicle! Race ends in " .. remainingTime .. " seconds!")
          end
        end

        -- End race when time runs out
        if timeStopped >= stationaryTimeout then return false end
      end
    else
      if lastMovementTime ~= nil then freeroamRaceHudCriticalWarning() end
      lastMovementTime = nil
      lastCountdownUpdate = nil
      remainingTime = stationaryTimeout
    end
  end

  local function nearestRouteForVehicle(vehiclePos)
    local mainNearestIndex, mainDistance = findNearestNode(vehiclePos, roadNodes)
    local altNearestIndex, altDistance = findNearestNode(vehiclePos, altRoadNodes)

    if not mainNearestIndex and not mainDistance then return nil end
    if not altNearestIndex and not altDistance then altDistance = 1000000 end

    local useAltRoute = altDistance < mainDistance
    local currentNodes = useAltRoute and altRoadNodes or roadNodes
    local nearestNodeIndex = useAltRoute and altNearestIndex or mainNearestIndex

    return currentNodes, nearestNodeIndex
  end

  local function distanceFromRaceRoute(vehiclePos, currentNodes, nearestNodeIndex)
    local currentNode = currentNodes[nearestNodeIndex]
    local nextNodeIndex = (nearestNodeIndex % #currentNodes) + 1
    local prevNodeIndex = ((nearestNodeIndex - 2) % #currentNodes) + 1
    local nextNode = currentNodes[nextNodeIndex]
    local prevNode = currentNodes[prevNodeIndex]

    local distanceFromPath, t = distanceToLineSegment(vehiclePos, currentNode, nextNode)
    if t < 0.1 then
      local prevDistance, prevT = distanceToLineSegment(vehiclePos, prevNode, currentNode)
      if prevDistance < distanceFromPath then
        distanceFromPath = prevDistance
        t = prevT
      end
    elseif t > 0.9 then
      local nextNextNode = currentNodes[(nextNodeIndex % #currentNodes) + 1]
      local nextDistance, nextT = distanceToLineSegment(vehiclePos, nextNode, nextNextNode)
      if nextDistance < distanceFromPath then
        distanceFromPath = nextDistance
        t = nextT
      end
    end

    return distanceFromPath, currentNode, nextNode, prevNode
  end

  local function movingAgainstRaceRoute(speedSq, vx, vy, vz, currentNode, nextNode, prevNode)
    -- Improved wrong direction detection
    local isWrongDirection = false
    if speedSq > 1 then -- Only check direction if the vehicle is moving
      local speed = math.sqrt(speedSq)
      local fdx = nextNode.x - currentNode.x
      local fdy = nextNode.y - currentNode.y
      local fdz = nextNode.z - currentNode.z
      local bdx = prevNode.x - currentNode.x
      local bdy = prevNode.y - currentNode.y
      local bdz = prevNode.z - currentNode.z
      local forwardLength = math.sqrt(fdx * fdx + fdy * fdy + fdz * fdz)
      local backwardLength = math.sqrt(bdx * bdx + bdy * bdy + bdz * bdz)
      local forwardDot = forwardLength > 0.000001 and (vx * fdx + vy * fdy + vz * fdz) / (speed * forwardLength) or 0
      local backwardDot = backwardLength > 0.000001 and (vx * bdx + vy * bdy + vz * bdz) / (speed * backwardLength) or 0
      isWrongDirection = forwardDot < WRONG_DIRECTION_THRESHOLD and backwardDot < WRONG_DIRECTION_THRESHOLD
    end

    return isWrongDirection
  end

  local function updateRoadExitCountdown(distanceFromPath, isWrongDirection, currentTime)
    if distanceFromPath > (MAX_DISTANCE_FROM_PATH + 25) then
        if exitCountdown == 0 then
          exitCountdown = exitCountdownStart
          freeroamRaceHudCriticalWarning("Warning: You are exiting the event! " .. exitCountdown .. " seconds to return!")
          lastCountdownTime = currentTime
        elseif math.ceil(exitCountdownStart - (currentTime - lastCountdownTime)) < exitCountdown then
          exitCountdown = math.max(0, math.ceil(exitCountdownStart - (currentTime - lastCountdownTime)))
          if exitCountdown > 0 then
            freeroamRaceHudCriticalWarning("Exiting event in " .. exitCountdown .. " seconds!")
          else
            freeroamRaceHudCriticalWarning("Event exited!")
            return false
          end
        end
      elseif isWrongDirection then
        if currentTime - lastAlertTime > ALERT_COOLDOWN then
          --ui_message("Warning: You're going the wrong way!", 3, "info")
          lastAlertTime = currentTime
        end
        -- Note: We're not returning false here, allowing the player to continue even if going the wrong way
      else
        if exitCountdown > 0 then
          exitCountdown = 0
          freeroamRaceHudCriticalWarning()
          ui_message("Back on track!", 2, "info")
        end
      end

      return true
    end

    local function isLoop()
      if not roadNodes or #roadNodes < 3 then return false end

      local firstNode = roadNodes[1]
      local lastNode = roadNodes[#roadNodes]

      -- Define a small threshold for floating-point comparisons
      local threshold = MAX_MERGE_DISTANCE

      local isLoop = math.abs(firstNode.x - lastNode.x) < threshold
        and math.abs(firstNode.y - lastNode.y) < threshold
        and math.abs(firstNode.z - lastNode.z) < threshold
      return isLoop
  end

  local function checkPlayerOnRoad(dtSim)
    local elapsed = math.max(0, tonumber(dtSim) or 0)
    if elapsed == 0 then return true end
    raceTime = raceTime + elapsed
    local playerVehicle = be:getPlayerVehicle(0)
    if not playerVehicle then return false end

    local vehiclePos = playerVehicle:getPosition()
    local vehicleVel = playerVehicle:getVelocity()
    local vx, vy, vz = vehicleVel.x, vehicleVel.y, vehicleVel.z
    local speedSq = vx * vx + vy * vy + vz * vz
    local currentTime = raceTime

    if updateRoadStationaryTimeout(speedSq, currentTime) == false then return false end
    local currentNodes, nearestNodeIndex = nearestRouteForVehicle(vehiclePos)
    if not currentNodes then return true end
    local distanceFromPath, currentNode, nextNode, prevNode =
      distanceFromRaceRoute(vehiclePos, currentNodes, nearestNodeIndex)
    local isWrongDirection = movingAgainstRaceRoute(speedSq, vx, vy, vz, currentNode, nextNode, prevNode)
    return updateRoadExitCountdown(distanceFromPath, isWrongDirection, currentTime)
  end

  local function setStationaryTimeout(timeout)
    stationaryTimeout = timeout or STATIONARY_TIMEOUT
    remainingTime = stationaryTimeout -- Reset remaining time when timeout changes
  end

  local function flipCheckpoints(originalCheckpoints)
    if not originalCheckpoints or #originalCheckpoints == 0 then return nil end

    local flipped = {}
    for i = #originalCheckpoints, 1, -1 do
      local checkpoint = originalCheckpoints[i]
      local newDirection = "straight"

      -- Invert turn directions
      if checkpoint.direction == "left" then
        newDirection = "right"
      elseif checkpoint.direction == "right" then
        newDirection = "left"
      end

      table.insert(flipped, {
        node = checkpoint.node,
        type = checkpoint.type,
        index = checkpoint.index,
        direction = newDirection,
      })
    end
    return flipped
  end

  local function getNodeIndexCheckpoints(indexs, roadNodes)
    local checkpoints = {}
    if not indexs or not roadNodes then return checkpoints end
    for i = 1, #indexs do
      if not roadNodes[indexs[i]] then goto continue end
      local angle = calculateAngle(roadNodes[indexs[i] - 1], roadNodes[indexs[i]], roadNodes[indexs[i] + 1])
      table.insert(checkpoints, {
        node = roadNodes[indexs[i]],
        type = "manual",
        index = indexs[i],
        direction = angle > 0 and "left" or "right",
      })
      ::continue::
    end
    return checkpoints
  end

  local function getRoadNodesFromRace(race)
    if type(race.checkpointRoad) == "table" then
      if not race.checkpointRoad[2] then
        return getRoadNodes(race.checkpointRoad[1])
      else
        return mergeRoads(race.checkpointRoad)
      end
    else
      return getRoadNodes(race.checkpointRoad)
    end
  end

  -- Build checkpoint list for a single road (e.g. AI pathRoad). Used when alt route has a separate AI road in config; no race/alt state changed.
  local function getCheckpointsFromRoad(roadName, minDistance)
    if not roadName or type(roadName) ~= "string" or roadName == "" then return nil end
    local saved = MIN_CHECKPOINT_DISTANCE
    MIN_CHECKPOINT_DISTANCE = (type(minDistance) == "number" and minDistance > 0) and minDistance or 90
    local nodes = getRoadNodes(roadName)
    if not nodes or #nodes == 0 then
      MIN_CHECKPOINT_DISTANCE = saved
      return nil
    end
    local mainCp = processRoadNodes(nodes, {})
    MIN_CHECKPOINT_DISTANCE = saved
    return mainCp
  end

  local function getCheckpoints(race)
    if inputs.preview and inputs.isCurrent and not inputs.isCurrent() then error("Preview instance is closed", 0) end
    MIN_CHECKPOINT_DISTANCE = race.minCheckpointDistance or 90
    if race.checkpointRoad then
      -- Clear existing nodes and checkpoints
      roadNodes = nil
      altRoadNodes = nil
      checkpoints = nil
      altCheckpoints = nil
      activeRace = race
      roadNodes = getRoadNodesFromRace(race)

      if race.altRoute and race.altRoute.checkpointRoad then
        altRoadNodes = getRoadNodesFromRace(race.altRoute)
        if race.altRoute.checkpointIndexs then
          checkpoints = race.checkpointIndexs and getNodeIndexCheckpoints(race.checkpointIndexs, roadNodes)
            or processRoadNodes(roadNodes)
          altCheckpoints = getNodeIndexCheckpoints(race.altRoute.checkpointIndexs, altRoadNodes)
        else
          checkpoints, altCheckpoints = processRoadNodes(roadNodes, altRoadNodes)
        end
      else
        if race.checkpointIndexs then
          checkpoints = getNodeIndexCheckpoints(race.checkpointIndexs, roadNodes)
        else
          checkpoints = processRoadNodes(roadNodes)
        end
        altCheckpoints = nil
      end

      -- Add direction flip logic
      if race.reverse then
        checkpoints = flipCheckpoints(checkpoints)
        if altCheckpoints then altCheckpoints = flipCheckpoints(altCheckpoints) end
      end

      return checkpoints, altCheckpoints
    end
    return nil, nil
  end

  local function reset()
    roadNodes = nil
    altRoadNodes = nil
    checkpoints = nil
    altCheckpoints = nil
    activeRace = nil
    exitCountdown = 0
    raceTime = 0
    lastAlertTime = 0
    lastCountdownTime = 0
    lastMovementTime = nil
    lastCountdownUpdate = nil
    remainingTime = stationaryTimeout
    freeroamRaceHudCriticalWarning()
  end


  -- Public API --------------------------------------------------------------------------------------

  instance.getCheckpoints = getCheckpoints
  instance.getCheckpointsFromRoad = getCheckpointsFromRoad
  instance.getRoadNodesFromRace = getRoadNodesFromRace
  instance.isLoop = isLoop
  instance.reset = reset
  instance.checkPlayerOnRoad = checkPlayerOnRoad
  instance.setStationaryTimeout = setStationaryTimeout

  return instance
end

return factory
