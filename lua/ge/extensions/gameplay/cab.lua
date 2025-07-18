local M = {}

local activeCab = nil
local cabState = "none" -- none, coming, waiting, driving, finished, waitingForWaypoint
local playerInCab = false
local destination = nil
local waypointCheckTimer = 0

-- Helper function to calculate position and rotation for taxi
local function calculateTaxiTransform(position, direction)
  local normal = map.surfaceNormal(position, 1)
  local vecY = vec3(0, 1, 0)
  local rotation = quatFromDir(vecY:rotated(quatFromDir(direction, normal)), normal)
  return position, rotation
end

-- Simple spawn - just find any road position, we'll optimize placement via path later
local function findBasicSpawnPosition(playerPos, minDistance)
  if not gameplay_traffic_trafficUtils then
    extensions.load('gameplay_traffic_trafficUtils')
  end

  local options = {
    gap = 20,
    usePrivateRoads = false, -- Allow any roads
    minDrivability = 0.5,   -- Lower requirements since we'll reposition
    minRadius = 1.0,
    pathRandomization = 0.1
  }

  -- Try a few random directions
  for i = 1, 3 do
    local randomAngle = math.random() * math.pi * 2
    local searchDir = vec3(math.cos(randomAngle), math.sin(randomAngle), 0)
    
    local spawnData, isValid = gameplay_traffic_trafficUtils.findSpawnPointRadial(
      playerPos, searchDir, minDistance, minDistance * 3, minDistance * 1.5, options)
    
    if isValid and spawnData.pos then
      local finalPos, finalDir = gameplay_traffic_trafficUtils.finalizeSpawnPoint(
        spawnData.pos, spawnData.dir, spawnData.n1, spawnData.n2, 
        {legalDirection = true, dirRandomization = 0.5})
      return finalPos, finalDir
    end
  end

  -- Simple fallback - just offset from player
  local fallbackDistance = math.max(minDistance, 50)
  local randomAngle = math.random() * math.pi * 2
  local offsetPos = playerPos + vec3(
    math.cos(randomAngle) * fallbackDistance,
    math.sin(randomAngle) * fallbackDistance, 0)
  offsetPos.z = core_terrain.getTerrainHeight(offsetPos)
  return offsetPos, (playerPos - offsetPos):normalized()
end

function M.isTaxiInPlayerView(taxiId, playerPos)
  local taxi = getObjectByID(taxiId)
  if not taxi then return false end
  
  local taxiPos = taxi:getPosition()
  local playerCameraPos = core_camera.getPosition()
  local playerViewDir = core_camera.getForward()
  local dirToTaxi = (taxiPos - playerCameraPos):normalized()
  
  local isInViewCone = dirToTaxi:dot(playerViewDir) > 0.3
  if not isInViewCone then return false end
  
  local distanceToTaxi = playerCameraPos:distance(taxiPos)
  local rayDistance = castRayStatic(playerCameraPos, dirToTaxi, distanceToTaxi)
  return rayDistance >= distanceToTaxi - 2
end

function M.isPositionInPlayerView(position, playerPos)
  local playerCameraPos = core_camera.getPosition()
  local playerViewDir = core_camera.getForward()
  local dirToPos = (position - playerCameraPos):normalized()
  
  local isInViewCone = dirToPos:dot(playerViewDir) > 0.3
  if not isInViewCone then return false end
  
  local distanceToPos = playerCameraPos:distance(position)
  local rayDistance = castRayStatic(playerCameraPos, dirToPos, distanceToPos)
  return rayDistance >= distanceToPos - 2
end

function M.calculateLanePosition(roadCenterPos, drivingDirection, playerPos)
  local isRightHandTraffic = true
  if map and map.getMap and map.getMap().rules then
    isRightHandTraffic = map.getMap().rules.rightHandDrive or true
  end
  
  local rightVector = vec3(-drivingDirection.y, drivingDirection.x, 0):normalized()
  local laneOffset = isRightHandTraffic and rightVector or -rightVector
  local laneWidth = 3.5
  
  -- Try to get actual road width from map
  if map and map.getMap then
    local mapData = map.getMap()
    if mapData.nodes then
      local closestRadius = nil
      local minDistance = math.huge
      
      for nodeId, nodeData in pairs(mapData.nodes) do
        if nodeData.pos and nodeData.radius then
          local distance = roadCenterPos:distance(nodeData.pos)
          if distance < minDistance and distance < 20 then
            minDistance = distance
            closestRadius = nodeData.radius
          end
        end
      end
      
      if closestRadius then
        laneWidth = math.min(closestRadius * 0.4, 4.0)
      end
    end
  end
  
  local lanePosition = roadCenterPos + laneOffset * laneWidth
  lanePosition.z = core_terrain.getTerrainHeight(lanePosition)
  return lanePosition, drivingDirection
end

-- Helper function to interpolate position on path segment
local function interpolatePathPosition(currentSeg, nextSeg, distanceFromStart, playerPos)
  local segmentLength = nextSeg.distance - currentSeg.distance
  if segmentLength <= 0 then return nil, nil end
  
  local segmentProgress = (distanceFromStart - currentSeg.distance) / segmentLength
  local roadCenterPos = vec3(
    currentSeg.pos.x + (nextSeg.pos.x - currentSeg.pos.x) * segmentProgress,
    currentSeg.pos.y + (nextSeg.pos.y - currentSeg.pos.y) * segmentProgress,
    currentSeg.pos.z + (nextSeg.pos.z - currentSeg.pos.z) * segmentProgress
  )
  local drivingDirection = (currentSeg.pos - nextSeg.pos):normalized()
  return M.calculateLanePosition(roadCenterPos, drivingDirection, playerPos)
end

function M.findOptimalPositionOnPath(pathSegments, targetDistance, playerPos)
  if not pathSegments or #pathSegments < 2 then return nil, nil end
  
  local totalPathLength = pathSegments[#pathSegments].distance
  local distanceFromStart = math.max(0, totalPathLength - targetDistance)
  local fallbackPos, fallbackDir = nil, nil
  
  -- Find the segment containing our target distance
  for i = 1, #pathSegments - 1 do
    local currentSeg = pathSegments[i]
    local nextSeg = pathSegments[i + 1]
    
    if distanceFromStart >= currentSeg.distance and distanceFromStart <= nextSeg.distance then
      local lanePos, finalDirection = interpolatePathPosition(currentSeg, nextSeg, distanceFromStart, playerPos)
      if lanePos then
        -- Prefer positions out of player view, but return any valid position
        if not M.isPositionInPlayerView(lanePos, playerPos) then
          return lanePos, finalDirection
        end
        -- Store as fallback if no out-of-view position found
        if not fallbackPos then
          fallbackPos, fallbackDir = lanePos, finalDirection
        end
      end
    end
  end
  
  return fallbackPos, fallbackDir
end

local function finalizeTaxiPosition(taxiId, playerPos)
  local taxi = getObjectByID(taxiId)
  if taxi then
    print("Cab: Taxi properly positioned, making visible and proceeding to player")
    core_jobsystem.create(function(job)
      job.sleep(0.5)
      taxi:setMeshAlpha(1, '')
    end)
    taxi:queueLuaCommand('driver.returnTargetPosition(' .. serialize(playerPos) .. ')')
  end
end

function M.teleportTaxiToPosition(taxiId, position, direction, playerPos)
  local taxi = getObjectByID(taxiId)
  if not taxi then
    print("Cab: Taxi no longer exists, cannot teleport to position")
    activeCab = nil
    cabState = "none"
    return
  end

  taxi:setMeshAlpha(0, '')
  local pos, rotation = calculateTaxiTransform(position, direction)
  taxi:setPosRot(pos.x, pos.y, pos.z, rotation.x, rotation.y, rotation.z, rotation.w)
  
  print("Cab: Teleported taxi to optimal path position: " .. tostring(position))
  
  core_jobsystem.create(function(job)
    job.sleep(0.2)
    finalizeTaxiPosition(taxiId, playerPos)
  end)
end

-- Main function to position taxi optimally using path-finding
local function positionTaxiOnPath(taxiId, playerPos)
  local taxi = getObjectByID(taxiId)
  if not taxi then return end

  local taxiPos = taxi:getPosition()
  local path = map.getPointToPointPath(taxiPos, playerPos, 0, 1000, 200, 10000, 1)
  
  if not path or #path == 0 then
    print("Cab: No path found, keeping taxi at spawn position")
    finalizeTaxiPosition(taxiId, playerPos)
    return
  end

  -- Build path segments
  local pathSegments = {{pos = taxiPos, distance = 0}}
  local totalDistance = 0
  local prevNodePos = taxiPos
  
  for i = 1, #path do
    local nodePos = map.getMap().nodes[path[i]].pos
    if nodePos then
      totalDistance = totalDistance + prevNodePos:distance(nodePos)
      table.insert(pathSegments, {pos = nodePos, distance = totalDistance})
      prevNodePos = nodePos
    end
  end
  
  totalDistance = totalDistance + prevNodePos:distance(playerPos)
  table.insert(pathSegments, {pos = playerPos, distance = totalDistance})
  
  print("Cab: Total path length: " .. math.floor(totalDistance) .. "m")
  
  -- Find all possible positions and test for visibility
  local maxTargetDistance = math.min(100, totalDistance * 0.9) -- Don't go past 90% of path
  local minTargetDistance = 30 -- Minimum distance from player
  local bestPosition = nil
  local bestDirection = nil
  local bestDistance = 0
  
  -- Test positions from far to near, pick the first out-of-view one
  for targetDistance = maxTargetDistance, minTargetDistance, -5 do -- Try every 5m back
    local optimalPos, optimalDir = M.findOptimalPositionOnPath(pathSegments, targetDistance, playerPos)
    
    if optimalPos then
      -- Test if this position would be out of view (without moving taxi yet)
      if not M.isPositionInPlayerView(optimalPos, playerPos) then
        print("Cab: Found out-of-view position " .. math.floor(targetDistance) .. "m from player")
        M.teleportTaxiToPosition(taxiId, optimalPos, optimalDir, playerPos)
        return
      else
        -- Store as backup - prefer furthest position even if visible
        if not bestPosition or targetDistance > bestDistance then
          bestPosition = optimalPos
          bestDirection = optimalDir
          bestDistance = targetDistance
        end
        print("Cab: Position " .. math.floor(targetDistance) .. "m still visible, trying further back...")
      end
    end
  end
  
  -- If no out-of-view position found, use the furthest back position we found
  if bestPosition then
    print("Cab: No out-of-view position found, using furthest position " .. math.floor(bestDistance) .. "m from player")
    M.teleportTaxiToPosition(taxiId, bestPosition, bestDirection, playerPos)
  else
    print("Cab: Could not find any position on path, using spawn position")
    finalizeTaxiPosition(taxiId, playerPos)
  end
end

local function spawnTaxiCab(playerPos)
  -- Simple spawn - we'll position optimally via path
  local spawnPos, roadDirection = findBasicSpawnPosition(playerPos, 30)
  
  if not spawnPos then
    print("Cab: Could not find spawn position!")
    return nil
  end

  local direction = roadDirection or (playerPos - spawnPos):normalized()
  direction.z = 0

  local pos, rotation = calculateTaxiTransform(spawnPos, direction)
  
  local spawnOptions = {
    pos = pos,
    rot = rotation,
    config = 'vehicles/midsize/taxi.pc',
    autoEnterVehicle = false
  }

  local taxi = core_vehicles.spawnNewVehicle("midsize", spawnOptions)
  if not taxi then
    print("Cab: Failed to spawn taxi vehicle!")
    return nil
  end

  local taxiId = taxi:getID()
  activeCab = taxiId

  taxi:queueLuaCommand('extensions.load("driver")')
  taxi:queueLuaCommand('ai.setMode("manual")')
  taxi:setMeshAlpha(0, '') -- Keep hidden until positioned

  print("Cab: Taxi spawned at " .. tostring(spawnPos) .. ", positioning optimally...")
  return taxiId
end

local function callCab()
  if activeCab then
    print("Cab: A cab is already active!")
    return
  end

  local player = getPlayerVehicle(0)
  if not player then
    print("Cab: No player vehicle found!")
    return
  end

  local playerPos = player:getPosition()
  local taxiId = spawnTaxiCab(playerPos)
  
  if taxiId then
    print("Cab: Taxi spawned, positioning on optimal path...")
    cabState = "coming"

    core_jobsystem.create(function(job)
      job.sleep(0.5) -- Wait for taxi to be ready
      positionTaxiOnPath(taxiId, playerPos)
    end)
  else
    print("Cab: Failed to spawn taxi")
    ui_message("Taxi service is currently unavailable.", 5, "cab", "cab")
  end
end

local function resetCabSystem()
  activeCab = nil
  cabState = "none"
  playerInCab = false
  destination = nil
  waypointCheckTimer = 0
end

local function onVehicleSwitched(oldId, newId)
  if not activeCab then return end

  if newId == activeCab and not playerInCab then
    -- Player entered taxi
    playerInCab = true
    print("Cab: Player entered taxi")

    local taxi = getObjectByID(activeCab)
    if taxi then
      taxi:queueLuaCommand('input.setEnabled(false)')
      taxi:queueLuaCommand('ai.setMode("manual")')
    end

    -- Handle destination
    if core_groundMarkers then
      destination = core_groundMarkers.getTargetPos()
    end
    
    if destination then
      print("Cab: Driving to destination: " .. tostring(destination))
      cabState = "driving"
      if taxi then
        taxi:queueLuaCommand('driver.returnTargetPosition(' .. serialize(destination) .. ')')
      end
    else
      print("Cab: No destination set, waiting for waypoint")
      cabState = "waitingForWaypoint"
      waypointCheckTimer = 0
      ui_message("Please set a waypoint on the map for your destination", 5, "cab", "cab")
    end
    
  elseif playerInCab and oldId == activeCab then
    -- Player exited taxi
    playerInCab = false
    print("Cab: Player exited taxi")

    local taxi = getObjectByID(activeCab)
    if taxi then
      taxi:queueLuaCommand('ai.setMode("traffic")')
      print("Cab: Taxi set to traffic mode")
      cabState = "cleanup"
    else
      resetCabSystem()
    end
  end
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if not activeCab then return end

  local taxi = getObjectByID(activeCab)
  if not taxi then
    resetCabSystem()
    return
  end

  -- Check if arrived at destination
  if cabState == "driving" and destination then
    local taxiPos = taxi:getPosition()
    if taxiPos:distance(destination) < 5 then
      cabState = "finished"
      print("Cab: Arrived at destination")
    end
  end

  -- Check for waypoint periodically
  if cabState == "waitingForWaypoint" then
    waypointCheckTimer = waypointCheckTimer + dtReal
    
    if waypointCheckTimer >= 5.0 then
      waypointCheckTimer = 0
      
      if core_groundMarkers then
        destination = core_groundMarkers.getTargetPos()
        if destination then
          print("Cab: Waypoint found! Driving to destination: " .. tostring(destination))
          cabState = "driving"
          ui_message("Destination set! Driving to waypoint.", 3, "cab", "cab")
          taxi:queueLuaCommand('driver.returnTargetPosition(' .. serialize(destination) .. ')')
        else
          ui_message("Still waiting for waypoint. Please set a destination on the map.", 3, "cab", "cab")
        end
      end
    end
  end

  -- Cleanup when appropriate
  if cabState == "cleanup" then
    local player = getPlayerVehicle(0)
    if player then
      local playerPos = player:getPosition()
      local taxiPos = taxi:getPosition()
      local distance = playerPos:distance(taxiPos)

      if distance > 100 then
        local playerCameraPos = core_camera.getPosition()
        local dirToTaxi = (taxiPos - playerCameraPos):normalized()
        local rayDistance = castRayStatic(playerCameraPos, dirToTaxi, distance)
        local isOutOfSight = rayDistance < distance - 5
        local playerViewDir = core_camera.getForward()
        local isBehindPlayer = dirToTaxi:dot(playerViewDir) < 0.3

        if isOutOfSight or isBehindPlayer then
          print("Cab: Deleting taxi - distance: " .. math.floor(distance) .. "m, out of sight: " ..
                  tostring(isOutOfSight) .. ", behind player: " .. tostring(isBehindPlayer))
          taxi:delete()
          resetCabSystem()
        end
      end
    end
  end
end

-- Public API
M.callCab = callCab
M.onVehicleSwitched = onVehicleSwitched
M.inCab = function() return cabState == "driving" end
M.cabState = function() return cabState end
M.onUpdate = onUpdate

return M
