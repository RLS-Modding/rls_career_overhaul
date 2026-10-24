-- Auction vehicle motion: teleports, AI mode overrides, road-graph routes and the scripted lot drive.
-- Read in order: AI and placement, road graph, lot drive-out, drive-in; create() returns the public set.
local constants = require('overhaul/career/market/auction/constants')
local exactPath = require('common/overhaul/exactPath')

local motion = {}
local vehicleCommands = require("overhaul/lib/vehicles/vehicleCommands")

-- Retain the engine serializer's payload bytes while validating the owned VE callee.
local function serializedVehicleCall(functionName, ...)
  local call = vehicleCommands.call("overhaulDriver", functionName)
  local arguments = {}
  for index = 1, select('#', ...) do
    local value = select(index, ...)
    arguments[index] = serialize(value)
  end
  return call:sub(1, -2) .. table.concat(arguments, ', ') .. ')'
end

-- AI and placement --------------------------------------------------------------------------------

local function stopVehicleAI(veh)
  if not veh then return end
  -- "disabled", not "stop": stop keeps planAhead alive, so a freeze can nil plan.egoSeg in stock ai.lua.
  veh:queueLuaCommand('if overhaulDriver and overhaulDriver.cancelExactPathAssist then ' .. vehicleCommands.call("overhaulDriver", "cancelExactPathAssist") .. ' end')
  veh:queueLuaCommand('ai.setMode("disabled")')
  veh:queueLuaCommand('electrics.setIgnitionLevel(0)')
  veh:queueLuaCommand('electrics.setLightsState(1)')
end

local function teleportVehicleToSpot(veh, spot)
  if not veh or not spot then return false end

  local isPlayerVeh = veh:getID() == be:getPlayerVehicleID(0)
  if isPlayerVeh then extensions.hook("onOverhaulPlayerPositionReset", veh:getID()) end
  local function applyWalkingFacingFromQuat(rotQ)
    if not isPlayerVeh then return end
    if not gameplay_walk.isWalking() then
      return
    end
    local front = rotQ * vec3(0, 1, 0)
    gameplay_walk.setRot(front, vec3(0, 0, 1))
  end

  -- A sites placement can fail; use the explicit transform if it cannot reset this vehicle.
  if isPlayerVeh and spot.moveResetVehicleTo then
    local ok = pcall(function()
      local options = {skipVehicleIntersectionCheck = true}
      spot:moveResetVehicleTo(veh:getID(), nil, false, nil, nil, true, false, nil, options)
    end)
    if ok then
      core_camera.resetCamera(0)
      applyWalkingFacingFromQuat(quat(spot.rot))
      veh:queueLuaCommand('electrics.setIgnitionLevel(0)')
      return true
    end
  end

  local pos = vec3(spot.pos)
  local facing = spot.nativeRotation and quat(0, 0, 1, 0) * quat(spot.rot) or quat(spot.rot)
  local rot = spot.nativeRotation and quat(spot.rot) or facing * quat(0, 0, 1, 0)
  veh:setPosRot(pos.x, pos.y, pos.z + 0.5, rot.x, rot.y, rot.z, rot.w)
  applyWalkingFacingFromQuat(facing)
  veh:queueLuaCommand('electrics.setIgnitionLevel(0)')
  return true
end

-- Recovery uses the engine's ground and vehicle-intersection checks. Keep the
-- lot's damage/condition, and remove its old momentum before the bidding hold.
local function recoverLotVehicleToSpot(veh, spot)
  if not veh or not spot or not spot.pos then return false end
  stopVehicleAI(veh)
  local facing = spot.nativeRotation and quat(0, 0, 1, 0) * quat(spot.rot) or quat(spot.rot)
  spawn.safeTeleport(veh, vec3(spot.pos), facing, false, nil, false, false, false)
  veh:applyClusterVelocityScaleAdd(veh:getRefNodeId(), 0, 0, 0, 0)
  veh:queueLuaCommand('input.event("parkingbrake", 1, 1)')
  return true
end

local function ensureLotOverrideAI(veh)
  if not veh then return end
  veh:queueLuaCommand([[
    extensions.load('overhaulAi')
    if overhaulAi then
      local prevMode = ai and ai.mode
      ai = overhaulAi
      if prevMode and ai.setMode then
        ai.setMode(prevMode)
      end
    end
  ]])
end

local function closeVehicleOpenables(veh)
  if not veh then return end
  veh:queueLuaCommand([[
    for _, ctrl in pairs(controller.getControllersByType("advancedCouplerControl")) do
      ctrl.tryAttachGroupImpulse()
    end
  ]])
end

local function getRoadPathNodes(startPos, endPos)
  local startRoad = select(1, map.findClosestRoad(startPos))
  local endRoad = select(1, map.findClosestRoad(endPos))
  if not startRoad or not endRoad then
    return nil
  end

  local path = map.getPath(startRoad, endRoad)
  if type(path) ~= 'table' or #path < 2 then
    return nil
  end
  return path
end

-- Road graph --------------------------------------------------------------------------------------

-- Road-graph path between two spots; with skipUnlocatedSpots, a spot without a position is skipped.
local function segmentRoadPath(fromSpot, toSpot, skipUnlocatedSpots)
  if skipUnlocatedSpots then
    return fromSpot and fromSpot.pos and toSpot and toSpot.pos
      and getRoadPathNodes(vec3(fromSpot.pos), vec3(toSpot.pos)) or nil
  end
  return getRoadPathNodes(vec3(fromSpot.pos), vec3(toSpot.pos))
end

-- Joins the road-graph paths between consecutive spots, dropping a node repeated at a join.
local function combinedRoadPath(routeSpots, skipUnlocatedSpots)
  local combinedPath = {}
  for i = 1, #routeSpots - 1 do
    local segPath = segmentRoadPath(routeSpots[i], routeSpots[i + 1], skipUnlocatedSpots)
    if segPath and #segPath >= 2 then
      for j, nodeId in ipairs(segPath) do
        if not (j == 1 and #combinedPath > 0 and combinedPath[#combinedPath] == nodeId) then
          table.insert(combinedPath, nodeId)
        end
      end
    end
  end
  return combinedPath
end

-- Road-graph node positions along the path; a nil speed leaves out the speed field.
local function roadNodePoints(combinedPath, mapData, speed)
  local routePoints = {}
  for _, nodeId in ipairs(combinedPath) do
    local node = mapData and mapData.nodes and mapData.nodes[nodeId]
    local nodePos = node and node.pos or (mapData and mapData.positions and mapData.positions[nodeId])
    if nodePos then
      local point = vec3(nodePos)
      table.insert(routePoints, {x = point.x, y = point.y, z = point.z, v = speed})
    end
  end
  return routePoints
end

local function getRoadRoutePoints(routeSpots, speed)
  if type(routeSpots) ~= 'table' or #routeSpots < 2 then
    return nil
  end

  local combinedPath = combinedRoadPath(routeSpots, true)
  if #combinedPath < 2 then
    return nil
  end

  local routePoints = roadNodePoints(combinedPath, map.getMap(), speed)
  return #routePoints >= 2 and routePoints or nil
end

-- Lot drive-out -----------------------------------------------------------------------------------

-- Heading on the ground: the car's direction, or south when it is level.
local function groundForward(veh)
  local dir = veh:getDirectionVector()
  dir.z = 0
  if dir:length() > 0.01 then
    dir:normalize()
    return dir
  end
  return vec3(0, -1, 0)
end

-- Extensions register after extensions.load() returns, so one chunk that loads and calls skips the call.
local function queueDelayedExactPath(veh, command, isCurrent)
  veh:queueLuaCommand('if not overhaulDriver then extensions.load("overhaulDriver") end')
  local vehId = veh:getID()
  core_jobsystem.create(function(job)
    job.sleep(0.1)
    local routedVeh = getObjectByID(vehId)
    if routedVeh and (not isCurrent or isCurrent()) then
      routedVeh:queueLuaCommand(command)
    end
  end)
end

-- Exit spots that carry a position, led by the car itself.
local function exitScriptRouteSpots(vehPos, exitSpots)
  local routeSpots = {{pos = vehPos}}
  for _, spot in ipairs(exitSpots) do
    if spot and spot.pos then
      table.insert(routeSpots, spot)
    end
  end
  return routeSpots
end

-- Seeds the route ahead of the bumper, then keeps only the graph nodes that lead forward, so the car never reverses.
local function exitScriptRoutePoints(vehPos, vehDir, graphPoints, speed)
  local ahead = vehPos + vehDir * 6
  local routePoints = {{x = ahead.x, y = ahead.y, z = ahead.z, v = speed}}
  local joinedGraph = false
  for _, routePoint in ipairs(graphPoints) do
    local point = vec3(routePoint)
    local delta = (point - vehPos):z0()
    if joinedGraph or delta:dot(vehDir) > 0.1 then
      joinedGraph = true
      local lastPoint = vec3(routePoints[#routePoints])
      if point:distance(lastPoint) > 1.0 then
        table.insert(routePoints, routePoint)
      end
    end
  end
  if #routePoints < 3 then
    return nil
  end
  return routePoints
end

-- Final heading at the despawn spot; falls back to the way to it, then to the car's own heading.
local function exitScriptTargetDirection(targetSpot, targetPos, vehPos, vehDir)
  local targetRot = quat(0, 0, 1, 0) * quat(targetSpot.rot or quat(0, 0, 0, 1))
  local targetDir = targetRot * vec3(0, -1, 0)
  targetDir.z = 0
  if targetDir:length() < 0.01 then
    targetDir = (targetPos - vehPos):z0()
  end
  if targetDir:length() > 0.01 then
    targetDir:normalize()
    return targetDir
  end
  return vehDir
end

local function exitScriptOptions(speed)
  return {
    routeSpeed = speed,
    aggression = 0.3,
    pathRadius = 0.35,
    terminalStartDistance = 2,
    avoidCars = 'off',
    -- The lot is removed before stopping, so keep road speed through the final alignment.
    approach = {
      {distance = 2, speed = speed},
      {distance = 0, speed = 0.8}
    }
  }
end

local function exitScriptCommand(routePoints, targetPos, targetDir, options)
  return [[
    if not overhaulAi then
      extensions.load('overhaulAi')
      if overhaulAi then ai = overhaulAi end
    elseif ai ~= overhaulAi then
      ai = overhaulAi
    end
    if controller and controller.setFreeze then controller.setFreeze(0) end
    if electrics and electrics.setIgnitionLevel then electrics.setIgnitionLevel(3) end
    input.event("parkingbrake", 0, 1)
    input.event("brake", 0, 1)
    input.event("throttle", 0, 1)
    if not overhaulDriver then extensions.load("overhaulDriver") end
    if overhaulDriver and overhaulDriver.driveExactPath then ]] ..
    serializedVehicleCall("driveExactPath", routePoints, targetPos, targetDir, options) .. ' end'
end

-- Exit from the block, scripted along the decal-road graph: road AI often builds only a stub plan here.
local function driveLotVehicleExitScript(veh, exitSpots, isCurrent)
  if not veh or type(exitSpots) ~= 'table' or #exitSpots < 1 then
    return false
  end

  local speed = constants.AI_MAX_SPEED_MPS
  local vehPos = vec3(veh:getPosition())
  local vehDir = groundForward(veh)
  local graphPoints = getRoadRoutePoints(exitScriptRouteSpots(vehPos, exitSpots), speed)
  if not graphPoints then
    return false
  end

  local routePoints = exitScriptRoutePoints(vehPos, vehDir, graphPoints, speed)
  if not routePoints then
    return false
  end

  local targetSpot = exitSpots[#exitSpots]
  local targetPos = vec3(targetSpot.pos)
  local targetDir = exitScriptTargetDirection(targetSpot, targetPos, vehPos, vehDir)
  local options = exitScriptOptions(speed)
  queueDelayedExactPath(veh, exitScriptCommand(routePoints, targetPos, targetDir, options), isCurrent)
  return true, exactPath.points(routePoints, targetPos, targetDir, options)
end

-- Nearest road waypoints to the car and each route spot, without repeats; seeded ahead of the bumper.
local function exitRoadTargets(vehPos, vehDir, routeSpots)
  local targets = {}
  local function pushClosestRoad(pos)
    local wp = select(1, map.findClosestRoad(vec3(pos)))
    if wp and wp ~= targets[#targets] then
      table.insert(targets, wp)
    end
  end

  pushClosestRoad(vehPos + vehDir * 10)
  for _, spot in ipairs(routeSpots) do
    if spot and spot.pos then
      pushClosestRoad(spot.pos)
    end
  end
  if #targets < 2 then
    pushClosestRoad(vehPos)
  end
  return targets
end

-- Fallback road exit when a script cannot be built.
local function driveLotVehicleExit(veh, routeSpots, aggression)
  if not veh or type(routeSpots) ~= 'table' or #routeSpots < 1 then
    return false
  end
  local targets = exitRoadTargets(veh:getPosition(), groundForward(veh), routeSpots)
  if #targets < 2 then
    return false
  end

  local speed = constants.AI_MAX_SPEED_MPS
  local agg = aggression or 0.25
  local listStr = serialize(targets)
  veh:queueLuaCommand(string.format([[
    if not overhaulAi then
      extensions.load('overhaulAi')
      if overhaulAi then ai = overhaulAi end
    elseif ai ~= overhaulAi then
      ai = overhaulAi
    end
    if controller and controller.setFreeze then controller.setFreeze(0) end
    if electrics and electrics.setIgnitionLevel then electrics.setIgnitionLevel(3) end
    input.event("parkingbrake", 0, 1)
    input.event("brake", 0, 1)
    input.event("throttle", 0, 1)
    if ai.setMode then ai.setMode("manual") end
    ai.setRacing(false)
    ai.driveInLane("on")
    ai.setSpeedMode("set")
    ai.setSpeed(%.4f)
    if ai.setAggression then ai.setAggression(%.2f) end
    ai.driveUsingPath({
      wpTargetList = %s,
      noOfLaps = 1,
      aggression = %.2f,
      avoidCars = "off",
      driveInLane = "on",
      routeSpeed = %.4f,
      routeSpeedMode = "limit"
    })
    ai.setSpeedMode("set")
    ai.setSpeed(%.4f)
  ]], speed, agg, listStr, agg, speed, speed))
  return true
end

-- Drive-in ----------------------------------------------------------------------------------------
local function driveVehicleToSpot(veh, fromSpot, toSpot, aggression)
  if not veh or not fromSpot or not toSpot then return false end

  local path = getRoadPathNodes(vec3(fromSpot.pos), vec3(toSpot.pos))
  if not path or #path < 2 then
    return false
  end

  local pathStr = '{path = ' .. serialize(path)
  pathStr = pathStr .. string.format(', noOfLaps = 1, aggression = %.2f, avoidCars = "off", routeSpeed = %.4f, routeSpeedMode = "limit"}', aggression or 0.25, constants.AI_MAX_SPEED_MPS)
  veh:queueLuaCommand(string.format([[
    if not overhaulAi then
      extensions.load('overhaulAi')
      if overhaulAi then ai = overhaulAi end
    elseif ai ~= overhaulAi then
      ai = overhaulAi
    end
    if controller and controller.setFreeze then controller.setFreeze(0) end
    if electrics and electrics.setIgnitionLevel then electrics.setIgnitionLevel(3) end
    input.event("parkingbrake", 0, 1)
    input.event("brake", 0, 1)
    input.event("throttle", 0, 1)
    if ai.setMode then ai.setMode("manual") end
    ai.setRacing(false)
    ai.driveInLane("on")
    ai.setSpeedMode("set")
    ai.setSpeed(%.4f)
    ai.driveUsingPath(%s)
    ai.setSpeedMode("set")
    ai.setSpeed(%.4f)
  ]], constants.AI_MAX_SPEED_MPS, pathStr, constants.AI_MAX_SPEED_MPS))
  return true
end

local function driveVehicleAlongRouteSpots(veh, routeSpots, aggression)
  if not veh or type(routeSpots) ~= 'table' or #routeSpots < 2 then
    return false
  end

  local combinedPath = combinedRoadPath(routeSpots)
  if #combinedPath < 2 then
    return false
  end

  local pathStr = '{path = ' .. serialize(combinedPath)
  pathStr = pathStr .. string.format(', noOfLaps = 1, aggression = %.2f, avoidCars = "on"}', aggression or 0.4)
  veh:queueLuaCommand(string.format([[
    if not overhaulAi then
      extensions.load('overhaulAi')
      if overhaulAi then ai = overhaulAi end
    elseif ai ~= overhaulAi then
      ai = overhaulAi
    end
    if controller and controller.setFreeze then controller.setFreeze(0) end
    if electrics and electrics.setIgnitionLevel then electrics.setIgnitionLevel(3) end
    input.event("parkingbrake", 0, 1)
    input.event("brake", 0, 1)
    ai.driveUsingPath(%s)
    ai.setRacing(false)
    ai.driveInLane("on")
    ai.setSpeedMode("set")
    ai.setSpeed(%.4f)
  ]], pathStr, constants.AI_MAX_SPEED_MPS))
  return true
end

local function driveVehicleToExactSpot(veh, routeSpots, targetSpot, aggression, isCurrent)
  if not veh or type(routeSpots) ~= 'table' or #routeSpots < 2 or not targetSpot then
    return false
  end

  local combinedPath = combinedRoadPath(routeSpots)
  if #combinedPath < 2 then
    return false
  end

  local mapData = map.getMap()
  local targetPos = vec3(targetSpot.pos)
  local routePoints = roadNodePoints(combinedPath, mapData, nil)
  if #routePoints < 2 then
    return false
  end

  -- Parking-spot rotations use the opposite vehicle-forward convention.
  local targetRot = quat(0, 0, 1, 0) * quat(targetSpot.rot)
  local targetDir = targetRot * vec3(0, -1, 0)
  targetDir.z = 0
  targetDir:normalize()

  local options = {
    routeSpeed = constants.AI_MAX_SPEED_MPS,
    aggression = aggression or 0.35,
    pathRadius = constants.LOT_EXACT_PATH_RADIUS_M,
    terminalStartDistance = constants.LOT_EXACT_TERMINAL_DISTANCE_M,
    avoidCars = 'off',
    approach = {
      {distance = constants.LOT_EXACT_TERMINAL_DISTANCE_M, speed = 2.0},
      {distance = 9, speed = 1.5},
      {distance = 4, speed = 0.8},
      {distance = 1, speed = 0.35},
      {distance = 0, speed = 0}
    }
  }
  local command = [[
    if controller and controller.setFreeze then controller.setFreeze(0) end
    if electrics and electrics.setIgnitionLevel then electrics.setIgnitionLevel(3) end
    input.event("parkingbrake", 0, 1)
    input.event("brake", 0, 1)
    if overhaulDriver and overhaulDriver.driveExactPath then ]] ..
    serializedVehicleCall("driveExactPath", routePoints, targetPos, targetDir, options) .. ' end'
  queueDelayedExactPath(veh, command, isCurrent)
  return true, exactPath.points(routePoints, targetPos, targetDir, options)
end

-- Public API --------------------------------------------------------------------------------------

function motion.create()
  return {
    closeVehicleOpenables = closeVehicleOpenables,
    driveLotVehicleExit = driveLotVehicleExit,
    driveLotVehicleExitScript = driveLotVehicleExitScript,
    driveVehicleAlongRouteSpots = driveVehicleAlongRouteSpots,
    driveVehicleToExactSpot = driveVehicleToExactSpot,
    driveVehicleToSpot = driveVehicleToSpot,
    ensureLotOverrideAI = ensureLotOverrideAI,
    stopVehicleAI = stopVehicleAI,
    recoverLotVehicleToSpot = recoverLotVehicleToSpot,
    teleportVehicleToSpot = teleportVehicleToSpot,
  }
end

return motion
