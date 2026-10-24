-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this file,
-- You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Intersection decisions, traffic actions and route selection.
-- create binds this extension instance; require caches only the factory.

-- Map, in reading order:
--   controlled branches, horn and pull-over detection
--   intersection recording and lookup: recordControlled/Uncontrolled, findTrafficIntersection
--   stop decisions: yieldAtFourWayStop, deadlock resolution, stop-sign and stopped-intersection waits
--   manageTrafficIntersection, then the trafficActions and trafficPlan exports

local lib = {}

function lib.create(ctx)
  -- Locals for speed: this file runs every AI frame.
  local max, min, abs, sqrt = math.max, math.min, math.abs, math.sqrt
  local tableInsert, tableRemove = ctx.tableInsert, ctx.tableRemove
  local square, getTmpVec3 = ctx.square, ctx.getTmpVec3
  local gravity = ctx.g
  local gravityDir = ctx.gravityDir
  local ego = ctx.ego
  local internalState = ctx.internalState
  local trafficStates = ctx.trafficStates
  local recover = ctx.recover
  -- Functions from the other AI parts that this part calls, read from ctx once when it is created.
  local parts = {
    getObjectBoundingBox = ctx.getObjectBoundingBox,
    driveCar = ctx.driveCar,
    getLastNodeWithinDistance = ctx.getLastNodeWithinDistance,
    targetsCompatible = ctx.targetsCompatible,
    getMinPlanLen = ctx.getMinPlanLen,
    pickAiWp = ctx.pickAiWp,
    pathExtend = ctx.pathExtend,
    getPathLen = ctx.getPathLen,
    laneChange = ctx.laneChange,
    setStopPoint = ctx.setStopPoint,
    numOfLanesInDirection = ctx.numOfLanesInDirection,
    getEdgeLaneConfig = ctx.getEdgeLaneConfig,
    roadNaturalContinuation = ctx.roadNaturalContinuation,
    isVehicleStopped = ctx.isVehicleStopped,
    planAhead = ctx.planAhead,
  }

  local controlledEdges = {}
  local stopPositions = {}
  local function getControlledBranches(nid1, nid2)
    table.clear(controlledEdges)
    table.clear(stopPositions)
    stopPositions[1] = ctx.aiState.signalsData[nid1][nid2][1].pos
    local legs = 1
    local searchDist = 20

    local intersectionNode
    local prevNode, node, dist = nid1, nid2, 0
    repeat
      local nodeLinkCount = tableSize(ctx.aiState.mapData.graph[node])
      if nodeLinkCount > 2 then
        intersectionNode = node
        break
      elseif nodeLinkCount == 1 then
        break
      end
      local nextNode = next(ctx.aiState.mapData.graph[node]) ~= prevNode and next(ctx.aiState.mapData.graph[node]) or next(ctx.aiState.mapData.graph[node], prevNode)
      prevNode, node = node, nextNode
      dist = dist + ctx.aiState.mapData.positions[node]:distance(ctx.aiState.mapData.positions[prevNode])
    until dist > searchDist

    if intersectionNode then
      -- add the nodes including the STOP on the edge where AI is driving to the controlled edges
      tableInsert(controlledEdges, nid1)
      tableInsert(controlledEdges, nid2)
      -- search the graph starting from the intersection node to find any other controlled edges leading to it
      for nodeId in pairs(ctx.aiState.mapData.graph[intersectionNode]) do
        -- Do not search controlled branches in the direction we came from.
        if nodeId ~= prevNode then -- avoid searching in the direction we are coming from
          -- walk the graph in the direction of nodeId, looking for edges that are controlled
          local edgeNode1, edgeNode2, dist = nodeId, intersectionNode, 0
          -- check if the edge is drivable and count the intersection's legs
          if parts.numOfLanesInDirection(parts.getEdgeLaneConfig(edgeNode1, edgeNode2), '+') > 0 and ctx.aiState.mapData.graph[edgeNode1][edgeNode2].drivability > 0.2 then
            legs = legs + 1
            repeat
              if ctx.aiState.signalsData[edgeNode1] and ctx.aiState.signalsData[edgeNode1][edgeNode2] and ctx.aiState.signalsData[edgeNode1][edgeNode2][1].action == 3 then
                -- Each controlled edge needs an entry for both incident nodes.
                tableInsert(controlledEdges, edgeNode1)
                tableInsert(controlledEdges, edgeNode2)
                -- insert the stop signal's position to the stopPositions table
                tableInsert(stopPositions, ctx.aiState.signalsData[edgeNode1][edgeNode2][1].pos)
                break
              end
              dist = dist + ctx.aiState.mapData.positions[edgeNode2]:distance(ctx.aiState.mapData.positions[edgeNode1])
              -- if the edgeNode1 is an "intersection" or if it is far enough, break the search in this direction
              local linkCount = tableSize(ctx.aiState.mapData.graph[edgeNode1])
              if linkCount > 2 or linkCount == 1 or dist > searchDist then break end
              local nextNode = next(ctx.aiState.mapData.graph[edgeNode1]) ~= edgeNode2 and next(ctx.aiState.mapData.graph[edgeNode1]) or next(ctx.aiState.mapData.graph[edgeNode1], edgeNode2)
              edgeNode1, edgeNode2 = nextNode, edgeNode1
            until false
          end
        end
      end

      -- sort the stop positions clockwise around the intersection node
      if stopPositions[1] then
        local center = ctx.aiState.mapData.positions[intersectionNode]
        table.sort(stopPositions, function(stopA, stopB) return math.atan2(stopA.y - center.y, stopA.x - center.x) > math.atan2(stopB.y - center.y, stopB.x - center.x) end)
      end
    end

    return #stopPositions, legs, intersectionNode, stopPositions, controlledEdges
  end

  local function updateTrafficHorn()
    local MIN_HORN_DURATION_S = 0.1
    -- horn
    if ctx.aiState.parameters.enableElectrics and trafficStates.action.hornTimer == 0 then
      electrics.horn(true)
      trafficStates.action.hornTimerLimit = max(MIN_HORN_DURATION_S, math.random())
    end
    if trafficStates.action.hornTimer >= trafficStates.action.hornTimerLimit then
      electrics.horn(false)
      trafficStates.action.hornTimer = -1
    end

    if not (trafficStates.action.hornTimer >= 0) then return end
    trafficStates.action.hornTimer = trafficStates.action.hornTimer + ctx.aiState.dt
  end

  local function detectTrafficPullOver()
    local CRASH_DAMAGE_THRESHOLD = 1000
    local SIREN_RADIUS_SQUARED_M2 = 10000
    local POLICE_HOLD_RADIUS_SQUARED_M2 = 400
    local ONCOMING_RADIUS_SQUARED_M2 = 225
    local pullOver = false
    pullOver = ctx.M.pullOver

    -- hazard lights
    if beamstate.damage >= CRASH_DAMAGE_THRESHOLD then
      if recover.recoverOnCrash then
        recover._recoverOnCrash = true
      else
        if electrics.values.signal_left_input == 0 and electrics.values.signal_right_input == 0 then
          electrics.set_warn_signal(1)
        end
        pullOver = true
      end
    end

    -- pull over
    local minSirenSqDist = math.huge
    local nearestPoliceId
    local posFront = getTmpVec3(ego)

    for plID, mapObject in pairs(mapmgr.getObjects()) do
      if not (plID ~= objectId and mapObject.states) then goto nextSirenVehicle end
      if mapObject.states.lightbar == 2 or (mapObject.states.lightbar == 1 and mapObject.vel:squaredLength() >= 100) then
        posFront:set(obj:getObjectFrontPositionXYZ(plID))
        minSirenSqDist = min(minSirenSqDist, posFront:squaredDistance(ego.pos))
        nearestPoliceId = plID
      end
      ::nextSirenVehicle::
    end
    if minSirenSqDist <= SIREN_RADIUS_SQUARED_M2 then
      pullOver = true
      trafficStates.action.nearestPoliceId = nearestPoliceId
    end

    if not trafficStates.action.nearestPoliceId then return pullOver end
    local police = mapmgr.objects[trafficStates.action.nearestPoliceId]
    if not (police and police.states and police.states.lightbar) then return pullOver end
    local egoToPoliceSqDist = ego.pos:squaredDistance(police.pos)
    -- Check if ego vehicle is in front of the police vehicle
    if not (ego.pos:dot(police.dirVec) - police.pos:dot(police.dirVec) > 0.94 * sqrt(egoToPoliceSqDist)) then return pullOver end
    if ego.speed < 10 and egoToPoliceSqDist < POLICE_HOLD_RADIUS_SQUARED_M2 then
      pullOver = true -- vehicle stays pulled over in this case, and other traffic may keep driving
    end

    if not (ego.dirVec:dot(police.dirVec) > 0.5) then return pullOver end
    for otherID, mapObject in pairs(mapmgr.getObjects()) do
      if not (otherID ~= objectId and mapObject.pos and otherID ~= trafficStates.action.nearestPoliceId and mapObject.dirVec and mapObject.dirVec:dot(ego.dirVec) < 0) then goto nextOncomingVehicle end
      -- Alongside vehicles need both longitudinal and lateral proximity.
      if ego.pos:squaredDistance(mapObject.pos) < ONCOMING_RADIUS_SQUARED_M2 then -- within 15 meters
        -- Check if the vehicle is alongside us
        -- First Condition: x-component -> forward/back distance
        -- Second Condition: y-component -> lateral distance
        local lateralDist = mapObject.pos:dot(ego.rightVec) - ego.pos:dot(ego.rightVec)
        if abs(mapObject.pos:dot(ego.dirVec) - ego.pos:dot(ego.dirVec)) < 10 and abs(lateralDist) < 6 then
          -- Driving side determines which opposite-lane vehicles can trigger avoidance.
          if mapmgr.rules.rightHandDrive and lateralDist > 0 or not mapmgr.rules.rightHandDrive and lateralDist < 0 then
            pullOver = false
            break
          end
        end
      end
      ::nextOncomingVehicle::
    end
    return pullOver
  end

  local function applyTrafficPullOver(plan, pullOver)
    if pullOver and not trafficStates.action.forcedStop and ego.speed >= 3 then
      local brakeDist = square(ego.speed) / (2 * gravity * ctx.aiState.aggression)
      local dist = max(10, brakeDist)
      local idx = parts.getLastNodeWithinDistance(plan, dist)
      local n = plan[idx]
      local side = mapmgr.rules.rightHandDrive and -1 or 1
      local disp = n.pos:distance(n.posOrig + n.normal * side * (n.halfWidth - ego.width * 0.5))
      trafficStates.side.displacement = disp

      parts.laneChange(plan, max(10, dist - 20), disp * side)
      parts.setStopPoint(plan, dist, {avoidJunction = true})
      trafficStates.action.forcedStop = true
      trafficStates.side.side = mapmgr.rules.rightHandDrive and -1 or 1
    end

    if not pullOver and trafficStates.action.forcedStop then
      parts.setStopPoint()
      trafficStates.action.forcedStop = false
      trafficStates.action.nearestPoliceId = nil
    end

    if not (trafficStates.action.forcedStop and ego.speed < min(plan.targetSpeed or 0, 1)) then return end
    parts.setStopPoint(plan, 0)
  end

  local function recordControlledIntersection(path, i, nid1, nid2, intersectionState)
    -- TODO: check the array for the ideal signal to use (lane check as well, if applicable)
    local bestSignal = ctx.aiState.signalsData[nid1][nid2][1]
    local n1Pos, n2Pos = ctx.aiState.mapData.positions[nid1], ctx.aiState.mapData.positions[nid2]

    table.clear(intersectionState)
    intersectionState.node = nid1
    intersectionState.nextNode = nid2
    intersectionState.nodeIdx = 1
    intersectionState.pos = bestSignal.pos
    intersectionState.dir = (push3(n2Pos) - n1Pos):z0():normalized():copy()
    intersectionState.action = bestSignal.action
    intersectionState.block = false
    intersectionState.controlled = true

    -- adding turnDir
    if path[i + 2] then
      local n3Pos = ctx.aiState.mapData.positions[path[i + 2]]
      if tableSize(ctx.aiState.mapData.graph[nid2]) > 2 then -- if next path node is not in the middle of the junction
        intersectionState.turnDir = (push3(n3Pos) - n2Pos):z0():normalized():copy()
        intersectionState.turnNode = nid2
      elseif path[i + 3] then
        intersectionState.turnDir = (push3(ctx.aiState.mapData.positions[path[i + 3]]) - n3Pos):z0():normalized():copy()
        intersectionState.turnNode = path[i + 2]
      end
    end
    -- if a stop sign is detected, get the controlled branches and the stop positions
    if not (intersectionState.action == 3) then return end
    intersectionState.legsStop, intersectionState.legs, intersectionState.interNode, intersectionState.stopPos = getControlledBranches(nid1, nid2)
    intersectionState.is4stops4legs = (intersectionState.legs == 4 and intersectionState.legsStop == 4)
  end

  local function resolveIntersectionYieldDirections(
    nid1, nid2, intersectionState, linkDir, nDir, fourthNode, nContinuation, dotDir
  )
    table.clear(intersectionState)
    intersectionState.node = nid1
    intersectionState.nextNode = nid2
    intersectionState.turnNode = nid1
    intersectionState.turnDir = linkDir
    intersectionState.pos = (push3(ctx.aiState.mapData.positions[nid1]) - push3(nDir) * (max(3, ctx.aiState.mapData.radius[nid1]) + 2)):copy() -- needs at least + 3
    intersectionState.dir = nDir
    intersectionState.action = 3
    intersectionState.block = false
    if fourthNode then
      intersectionState.fullGiveWay = nContinuation == nid2
      if not intersectionState.fullGiveWay then
        intersectionState.oneGiveWay = dotDir < 0
      else
        if dotDir > 0 then
          intersectionState.fullGiveWay = false
          intersectionState.otherGiveWay = true
        end
      end
    else
      intersectionState.oneGiveWay = true
    end
  end

  local function recordUncontrolledIntersection(path, plan, i, nid1, nid2, intersectionState)
    -- Get Direction Vector of edge exiting nid1
    local tmpPos2, tmpPos1 = ctx.aiState.mapData:getEdgePositions(nid2, nid1)
    local linkDir = (push3(tmpPos2) - tmpPos1):z0():normalized():copy()

    -- Get path Direction Vector to nid1
    local prevNode = path[i-1] or plan[1].wp
    local nDir
    local drivability = 1
    if ctx.aiState.mapData.graph[nid1][prevNode] then
      local n1Pos, prevNodePos = ctx.aiState.mapData:getEdgePositions(nid1, prevNode)
      nDir = (push3(n1Pos) - prevNodePos):z0():normalized():copy()
      drivability = ctx.aiState.mapData.graph[nid1][prevNode].drivability
    else
      prevNode = nil
      nDir = ego.dirVec:copy()
    end

    -- Yield across substantial turns or when the current edge is less drivable than another approach.
    local giveWay = abs(nDir:dot(linkDir)) < 0.707

    if not giveWay and drivability < 1 then
      for _, edgeData in pairs(ctx.aiState.mapData.graph[nid1]) do
        if edgeData.drivability > drivability then
          giveWay = true
          break
        end
      end
    end

    if not (giveWay) then return end
    -- The preceding node must belong to the three roads of a T-junction.
    local fourthNode -- the fourth node in a T-junction (the other three nodes being prevNode, nid1, nid2)
    -- the prevNode check is to make sure one of the three roads of the T-Junction is the one the vehicle is comming from
    if prevNode and tableSize(ctx.aiState.mapData.graph[nid1]) == 3 then
      for k in pairs(ctx.aiState.mapData.graph[nid1]) do
        if not (k ~= prevNode and k ~= nid2) then goto nextIntersectionBranch end
        fourthNode = k
        ::nextIntersectionBranch::
      end
    end

    -- Checks if the vehicle has right of way in this T-junction
    local side = mapmgr.rules.rightHandDrive and -1 or 1
    local nContinuation = fourthNode and parts.roadNaturalContinuation(fourthNode, nid1)
    local dotDir = side * push3(gravityDir):cross(nDir):dot(linkDir) -- turn right 1/ turn left -1 (for right hand drive, italy)
    if not (not (fourthNode and nContinuation ~= nid2 and dotDir > 0)) then return end
    resolveIntersectionYieldDirections(nid1, nid2, intersectionState, linkDir, nDir, fourthNode, nContinuation, dotDir)
  end

  local function findTrafficIntersection(path, plan, intersectionState)
    if not (not intersectionState.node) then return end
    intersectionState.block = false
    intersectionState.is4stops4legs = false
    intersectionState.isEmpty = true

    intersectionState.startIdx = intersectionState.startIdx or (plan[1].wp and plan[1].pathidx-1 or plan[1].pathidx)
    for i = intersectionState.startIdx, #path - 1 do -- TODO: would searching up to min(#path-1, plan[plan.planCount].pathIdx) work to distribute the load over more frames work?
      local nid1, nid2 = path[i] or plan[1].wp, path[i + 1]

      if nid1 and nid2 then
        -- Controlled intersection (traffic light or stop sign) (nid1 can be behind ego if ego, e.g. ego is in the intersection edge)
        if ctx.aiState.signalsData and ctx.aiState.signalsData[nid1] and ctx.aiState.signalsData[nid1][nid2] then -- nodes from current path match the signals dict
          recordControlledIntersection(path, i, nid1, nid2, intersectionState)

        elseif intersectionState.startIdx > 0 and tableSize(ctx.aiState.mapData.graph[nid1]) > 2 and intersectionState.startIdx >= plan[2].pathidx then -- uncontrolled intersection (last check is to make sure the intersection is not behind ego)
          recordUncontrolledIntersection(path, plan, i, nid1, nid2, intersectionState)
        end
      end
      intersectionState.startIdx = i + 1

      if intersectionState.node then
        intersectionState.turn = 0
        intersectionState.timer = 0
        intersectionState.randomDelayFactor = 0.05 + math.random() * 0.95
        if intersectionState.turnDir and abs(intersectionState.dir:dot(intersectionState.turnDir)) < 0.707 then
          intersectionState.turn = -sign2(push3(intersectionState.dir):cross(gravityDir):dot(intersectionState.turnDir))
        end
        break
      end
    end
  end

  local function yieldAtFourWayStop(intersectionState, vId, mapObject, vPosF, populationInRadius, egoCenterPos, yield)
    local YIELD_RADIUS_SQUARED_M2 = 1600
    if intersectionState.is4stops4legs ~= true then return yield end
    if intersectionState.isEmpty == false then return true end
    if intersectionState.isEmpty ~= true then return yield end
    local center = ctx.aiState.mapData.positions[intersectionState.interNode]
    local center2vehicle = getTmpVec3(ego)
    center2vehicle:setSub2(vPosF, center)
    center2vehicle.z = 0
    local center2vehicleSq = center2vehicle:squaredLength()
    -- if the vehicle is near the intersection, yield
    if center2vehicleSq < 1.5 then
      yield = true
    else
      local alongDirSq = square(center2vehicle:dot(intersectionState.dir))
      local lateralFromIn = (gravityDir):cross(intersectionState.dir):z0()
      local sideOffset = lateralFromIn:dot(center2vehicle)
      -- Distinguish vehicles on opposite intersection legs.
      if (alongDirSq > 0.7 * center2vehicleSq and mapObject.dirVec:dot(intersectionState.dir) < -0.866) and populationInRadius == 2 then
        -- blinker + turn: avoid conflict turn (wrt driving side of the map)
        local turnSignal = mapObject.states and mapObject.states.turnsignal
        local egoTurnSide = intersectionState.turn * (mapmgr.rules.rightHandDrive and -1 or 1)
        local otherTurnSide = turnSignal and turnSignal * (mapmgr.rules.rightHandDrive and -1 or 1)

        if otherTurnSide and otherTurnSide >= 0 then
          yield = egoTurnSide < 0
        elseif egoTurnSide < 0 then
          if otherTurnSide and otherTurnSide < 0 then
            local vPosMiddle = parts.getObjectBoundingBox(vId)
            yield = vPosMiddle:squaredDistance(center) < egoCenterPos:squaredDistance(center)
          else
            yield = true
          end
        else
          yield = false
        end
      else
        -- yield to right/ or left wrt driving rules, within 40m, vehicle approaching the intersection, not behind ego vehicle
        yield = mapObject.posFront:squaredDistance(center) < mapObject.posRear:squaredDistance(center) + square(mapObject.length) and
          center2vehicleSq < YIELD_RADIUS_SQUARED_M2 and
          (mapObject.pos:squaredDistance(intersectionState.pos) > ego.pos:squaredDistance(intersectionState.pos) and mapObject.dirVec:dot(ego.dirVec) < 0.707)
          and sideOffset * (mapmgr.rules.rightHandDrive and -1 or 1) > 0 -- if the vehicle is on the lateral side of the ego approach into junction
      end
    end
    return yield
  end

  local function resolveTrafficStopDeadlock(intersectionState, egoCenterPos, vPosF, yield)
    if not (yield and intersectionState.is4stops4legs == true and intersectionState.isEmpty == true) then return yield end
    local nbGoes = 0
    if not (ego.vel:squaredLength() < 1 and (egoCenterPos:squaredDistance(intersectionState.stopPos[1]) < 1.2 * square(ego.length))) then return yield end
    for vId, mapObject in pairs(mapmgr.getObjects()) do
      if vId == objectId then goto nextDeadlockVehicle end
      mapObject.length = obj:getObjectInitialLength(vId)
      local vCenter, vXAxis = parts.getObjectBoundingBox(vId)
      vPosF:setAdd2(vCenter, vXAxis)
      local otherDist = vPosF:squaredDistance(ctx.aiState.mapData.positions[intersectionState.interNode])
      if (mapObject.vel:squaredLength() < 1) then
        -- the vehicle is stopped out of the intersection, and also very close to a stop position
        for t=2, #intersectionState.stopPos do
          if intersectionState.stopPos[t] and vPosF:squaredDistance(intersectionState.stopPos[t]) < square(mapObject.length) then
            nbGoes = nbGoes + 1
            break
          end
        end
      end
      ::nextDeadlockVehicle::
    end

    if not (nbGoes > 2) then return yield end
    yield = false
    return yield
  end

  local function observeStopSignCrossTraffic(
    intersectionState, vehicleInRange, vPosF, egoCenterPos, junctionCenterPos, vId, mapObject
  )
    mapObject.length = obj:getObjectInitialLength(vId)
    vPosF:set(obj:getObjectFrontPositionXYZ(vId))
    local xnorm1 = closestLinePointsPointVec(ego.pos, ego.dirVec, vPosF, mapObject.dirVec)
    if not intersectionState.is4stops4legs and not parts.isVehicleStopped(mapObject) and
      (xnorm1 > 0 or vPosF:dot(ego.dirVec) > ego.pos:dot(ego.dirVec)) and -- the other vehicle's projected trajectory passes in front of ego, or the other vehicle is in front of ego
      junctionCenterPos:dot(mapObject.dirVec) > vPosF:dot(mapObject.dirVec) - mapObject.length and -- center of the junction in front of the other vehicle's rear position
      mapObject.dirVec:dot(intersectionState.dir) < 0.707 and
      egoCenterPos:squaredDistance(vPosF) < square(max(min(60, max(40, mapObject.vel:squaredLength() / (gravity * ego.staticFrictionCoef))), 4 * mapObject.vel:length())) -- vehicle is within some range
    then
      -- Different tests for each kind of stop (controlled or fullGiveway/oneGiveWay/otherGiveWay)
      if intersectionState.oneGiveWay then
        local vFxnorm = 0
        if intersectionState.turnDir then
          vFxnorm = closestLinePointsPointVec(intersectionState.pos, intersectionState.turnDir, vPosF, mapObject.dirVec)
        end
        if vFxnorm > 0 and vFxnorm < 1.5 * ctx.aiState.mapData.radius[intersectionState.turnNode or intersectionState.node] and mapObject.dirVec:dot(intersectionState.dir) < -0.707 then
          vehicleInRange = true
        end
      elseif intersectionState.otherGiveWay or intersectionState.turn == (mapmgr.rules.rightHandDrive and -1 or 1) then -- other or stop but turning to right
        if intersectionState.turnDir and mapObject.dirVec:dot(intersectionState.turnDir) > 0.707 then
          vehicleInRange = true
        end
      else
        vehicleInRange = true
      end
    end
    return vehicleInRange
  end

  local function waitAtTrafficStopSign(intersectionState)
    local POPULATION_RADIUS_SQUARED_M2 = 2025
    local vehicleInRange = false
    local yield = true
    local vPosF = getTmpVec3(ego)
    local egoCenterPos = parts.getObjectBoundingBox(objectId)
    local distToJcenter = intersectionState.turnNode and ego.pos:distance(ctx.aiState.mapData.positions[intersectionState.turnNode]) or 1
    local junctionCenterPos = getTmpVec3(ego)
    junctionCenterPos:setAddScaled(ego.pos, ego.dirVec, distToJcenter)
    -- to count the number of vehicles in the radius of the intersection
    local populationInRadius = 1
    -- check if this intersection is empty, i.e. no vehicle is in the polygon formed by the STOP signs spots
    if intersectionState.is4stops4legs == true then
      local center = ctx.aiState.mapData.positions[intersectionState.interNode]
      for vId, mapObject in pairs(mapmgr.getObjects()) do
        if vId == objectId then goto nextPopulationVehicle end
        intersectionState.isEmpty = true
        mapObject.posMiddle, mapObject.vx, mapObject.vy, mapObject.vz = parts.getObjectBoundingBox(mapObject.id)
        mapObject.posFront = mapObject.posMiddle + mapObject.vx
        mapObject.posRear = mapObject.posMiddle - mapObject.vx
        mapObject.length = obj:getObjectInitialLength(vId)
        if mapObject.pos and mapObject.pos:squaredDistance(center) < POPULATION_RADIUS_SQUARED_M2 and mapObject.posFront:squaredDistance(center) < mapObject.posRear:squaredDistance(center) + square(mapObject.length) then
          populationInRadius = populationInRadius + 1
        end
        if intersectionState.stopPos and mapObject.posRear:inPolygon(intersectionState.stopPos) then
          intersectionState.isEmpty = false
          break
        end
        ::nextPopulationVehicle::
      end
      -- unique vehicle so no need to check later for other vehicles
      if populationInRadius == 1 then
        yield = false
      end
    end

    for vId, mapObject in pairs(mapmgr.getObjects()) do
      if vId == objectId then goto nextYieldVehicle end
      vehicleInRange = observeStopSignCrossTraffic(
        intersectionState, vehicleInRange, vPosF, egoCenterPos, junctionCenterPos, vId, mapObject
      )

      -- Opposing straight vehicles can proceed together; turns obey blinkers and driving-side priority.
      yield = yieldAtFourWayStop(intersectionState, vId, mapObject, vPosF, populationInRadius, egoCenterPos, yield)

      -- decreasing the timer means vehicles wait longer at intersection
      if vehicleInRange or (yield and intersectionState.is4stops4legs) then
        local scaling = linearScale(mapObject.vel:squaredLength(), 0, 1, intersectionState.randomDelayFactor, 1)
        intersectionState.timer = intersectionState.timer - scaling * 0.9 * ctx.aiState.dt
        break
      end
      ::nextYieldVehicle::
    end

    -- Break all-way-stop deadlocks by allowing the vehicle nearest its stop point to proceed.
    yield = resolveTrafficStopDeadlock(intersectionState, egoCenterPos, vPosF, yield)
    if (not vehicleInRange and not intersectionState.is4stops4legs) or (not yield and intersectionState.isEmpty) then
      intersectionState.timer = ctx.aiState.parameters.trafficWaitTime
    elseif intersectionState.is4stops4legs and (intersectionState.isEmpty == false or yield == true) then
      intersectionState.timer = 0.9 * ctx.aiState.parameters.trafficWaitTime
    end
  end

  local function waitAtStoppedIntersection(intersectionState)
    intersectionState.timer = intersectionState.timer + ctx.aiState.dt
    intersectionState.waiting = true
    -- if at a stop sign, or uncontroled intersection, check if there are any vehicles around. if not then continue.
    if not (intersectionState.action == 3) then return end
    waitAtTrafficStopSign(intersectionState)
  end

  local function advanceIntersectionStopPoint(plan, intersectionState, CLEAR_RADIUS_SQUARED_M2, distSq)
    if intersectionState.proximity then
      intersectionState.nodeIdx = nil
      intersectionState.action = 0
      -- Resync the search index after clearing an intersection.
      if distSq > CLEAR_RADIUS_SQUARED_M2 then -- assumes that vehicle has cleared the intersection (20 m away from the signal point)
        -- temp data until next intersection search
        -- resync startIdx if it has fallen behind by the time the intersection is cleared.
        local startIdx = intersectionState.startIdx
        -- Skip a path node that has fallen behind the vehicle.
        if plan[1].pathidx < plan[2].pathidx then -- plan[1] node is on a different path index than the node ahead of it
          -- skip path node if it is behind vehicle
          startIdx = max(startIdx, plan[1].pathidx)
        else
          startIdx = max(startIdx, plan[1].pathidx-1)
        end
        if electrics.values.turnsignal ~= 0 and intersectionState.turn ~= 0 then
          electrics.stop_turn_signal()
        end
        table.clear(intersectionState)
        intersectionState.timer = 0
        intersectionState.turn = 0
        intersectionState.block = false
        intersectionState.startIdx = startIdx
      end
    end
  end

  local function manageTrafficIntersection(plan, intersectionState)
    local PROXIMITY_RADIUS_SQUARED_M2 = 400
    local CLEAR_RADIUS_SQUARED_M2 = 400
    if not (intersectionState.node and not trafficStates.action.forcedStop) then return end
    intersectionState.waiting = false
    local signalsRef = intersectionState.nodeIdx and ctx.aiState.signalsData[intersectionState.node][intersectionState.nextNode][intersectionState.nodeIdx]
    if signalsRef then
      intersectionState.action = signalsRef.action or 0 -- get action from referenced table
    else
      intersectionState.action = intersectionState.action or 0 -- default action ("go")
    end

    local stopSeg = math.huge
    local brakeDist = square(ego.speed) / (2 * gravity * ego.staticFrictionCoef * min(1,
      ctx.aiState.aggression * 1.3))
    local distSq = ego.pos:squaredDistance(intersectionState.pos)

    if not intersectionState.proximity then -- checks if intersection was reached (needs improvement)
      intersectionState.proximity = distSq <= PROXIMITY_RADIUS_SQUARED_M2
    end

    if (intersectionState.pos:dot(intersectionState.dir) >= ego.pos:dot(intersectionState.dir)) or distSq < square(max(4, ego.length or 4)) then  -- vehicle position is at the stop pos (with extra distance, to be safe)
      if intersectionState.action == 3 or intersectionState.action == 2 or (intersectionState.action == 1 and (square(brakeDist) < distSq or intersectionState.commitStopOnYellow)) then -- action = 3 -> stop sign, action = 2 -> red light, action = 1 -> yellow light
        local bestDist = 100
        -- Use position to choose the stop node because path indices can disagree in complex intersections.
        for i = 1, plan.planCount - 1 do -- get best plan node to set as a stopping point
          -- currently checks every frame due to plan segment updates
          -- positional check is used due to issues with using plan.pathidx or complex intersections
          -- it would be great to improve this in the future
          local dist = plan[i].pos:squaredDistance(intersectionState.pos)
          if not (dist < bestDist) then goto nextStopPlanNode end
          bestDist = dist
          stopSeg = i
          ::nextStopPlanNode::
        end
        if stopSeg < math.huge and intersectionState.action == 1 then
          intersectionState.commitStopOnYellow = true
        end
      end

      if intersectionState.action == 3 or intersectionState.action == 2 then
        if stopSeg <= 2 and ego.speed <= 1 then waitAtStoppedIntersection(intersectionState) end

        if intersectionState.timer >= ctx.aiState.parameters.trafficWaitTime then
          if intersectionState.action == 2 then
            -- Turn on red allowed (right turn for RHT (LHD) and left turn for LHT (RHD) allowed after stopping and intersection is clear)
            if mapmgr.rules.turnOnRed and intersectionState.turn == (mapmgr.rules.rightHandDrive and -1 or 1) then
              intersectionState.nodeIdx = nil
              intersectionState.action = 0
              intersectionState.waiting = false
            end
          else
            intersectionState.nodeIdx = nil
            intersectionState.action = 0
            intersectionState.waiting = false
          end
        end
      end
    else
      advanceIntersectionStopPoint(plan, intersectionState, CLEAR_RADIUS_SQUARED_M2, distSq)
    end

    plan.stopSeg = stopSeg
    if not (ctx.aiState.parameters.enableElectrics and intersectionState.turnNode and ego.pos:squaredDistance(ctx.aiState.mapData.positions[intersectionState.turnNode]) < square(max(50, brakeDist * 1.2))) then return end
    if intersectionState.turn < 0 and electrics.values.turnsignal >= 0 then
      electrics.toggle_left_signal()
    elseif intersectionState.turn > 0 and electrics.values.turnsignal <= 0 then
      electrics.toggle_right_signal()
    end
  end

  local function trafficActions()
    if not ctx.aiState.currentRoute then return end
    local path, plan = ctx.aiState.currentRoute.path, ctx.aiState.currentRoute.plan

    updateTrafficHorn()

    local pullOver = detectTrafficPullOver()

    applyTrafficPullOver(plan, pullOver)

    -- Search for controlled (traffic light or stop sign) or uncontrolled (right of way) intersections along the path
    local intersectionState = trafficStates.intersection
    findTrafficIntersection(path, plan, intersectionState)

    -- Manage stopping at found intersections
    manageTrafficIntersection(plan, intersectionState)
  end

  local function buildTrafficWaypointPath(wp1, wp2)
    local radius = ctx.aiState.mapData.radius
    local position = ctx.aiState.mapData.positions
    local graph = ctx.aiState.mapData.graph

    local dirVec
    if trafficStates.block.timer > trafficStates.block.timerLimit and not graph[wp1][wp2].oneWay and (radius[wp1] + radius[wp2]) * 0.5 > ego.length then
      dirVec = -ego.dirVec -- tries to plan reverse direction
    else
      dirVec = ego.dirVec
    end

    wp1, wp2 = parts.pickAiWp(wp1, wp2, dirVec)

    local path
    path = ctx.aiState.mapData:getPathTWithState(wp1, ego.pos, parts.getMinPlanLen(80), dirVec)
    table.clear(ctx.aiState.trafficPathState)
    for i, pathNodeId in ipairs(path) do ctx.aiState.trafficPathState[i] = pathNodeId end

    if path[2] == wp2 and path[3] then
      local xnorm = ego.pos:xnormOnLine(position[wp1], position[wp2])
      if xnorm >= 0 and xnorm <= 1 and position[wp2]:dot(ego.dirVec) < position[wp1]:dot(ego.dirVec) then
        -- vehicle is within the first path segment but facing the wrong way
        tableRemove(path, 1)
      end
    end
    ego.currentSegment[1] = wp1
    ego.currentSegment[2] = wp2
    return wp1, wp2, path
  end

  local function activateTrafficPath()
    local path = {}
    for i, pathNodeId in ipairs(ctx.aiState.trafficPathState) do path[i] = pathNodeId end
    local pathCount = #path
    local Bestscore = - math.huge
    local BestNode = nil
    for k in pairs(ctx.aiState.mapData.graph[path[1]]) do
      local p1, p2 = ctx.aiState.mapData:getEdgePositions(path[1], k)
      local score = (p1:dot(ego.dirVec) - p2:dot(ego.dirVec))/(p2:distance(p1))
      if score > Bestscore then
        Bestscore = score
        BestNode = k
      end
    end
    ego.currentSegment[1] = path[1]
    ego.currentSegment[2] = BestNode

    local newPath
    newPath = ctx.aiState.mapData:getPathTWithState(path[pathCount], ctx.aiState.mapData.positions[path[pathCount]], parts.getMinPlanLen(100), ctx.aiState.trafficPathState[1] and ctx.aiState.trafficPathState or ego.dirVec)
    table.clear(ctx.aiState.trafficPathState)
    for i, pathNodeId in ipairs(newPath) do ctx.aiState.trafficPathState[i] = pathNodeId end
    parts.pathExtend(path, newPath)
    ctx.aiState.currentRoute = parts.planAhead(path)
  end

  local function trafficPlan()
    if trafficStates.block.block and not trafficStates.intersection.waiting then
      trafficStates.block.timer = trafficStates.block.timer + ctx.aiState.dt
    else
      trafficStates.block.timer = trafficStates.block.timer * 0.8
      trafficStates.block.hornFlag = false
    end

    if ctx.aiState.currentRoute and ctx.aiState.currentRoute.path[1] and not ctx.aiState.currentRoute.plan.reRoute and trafficStates.block.timer <= trafficStates.block.timerLimit then
      local plan = ctx.aiState.currentRoute.plan
      local path = ctx.aiState.currentRoute.path
      if (internalState.road ~= 'offroad' and plan.planLen + parts.getPathLen(path, plan[plan.planCount].pathidx) < parts.getMinPlanLen()) or not path[plan[plan.planCount].pathidx+2] then
        local pathCount = #path

        local newPath
        newPath = ctx.aiState.mapData:getPathTWithState(path[pathCount], ctx.aiState.mapData.positions[path[pathCount]], parts.getMinPlanLen(100), ctx.aiState.trafficPathState[1] and ctx.aiState.trafficPathState or ego.dirVec)
        table.clear(ctx.aiState.trafficPathState)
        for i, pathNodeId in ipairs(newPath) do ctx.aiState.trafficPathState[i] = pathNodeId end

        parts.pathExtend(path, newPath)
      end
    elseif ctx.aiState.trafficPathState.aborting then
      activateTrafficPath()
    else
      local wp1, wp2 = mapmgr.findBestRoad(ego.pos, ego.dirVec)

      if wp1 == nil or wp2 == nil then
        guihooks.message("Could not find a road network, or closest road is too far", 5, "AI debug")
        ctx.aiState.currentRoute = nil
        internalState.road = 'offroad'
        internalState.changePlanTimer = 0
        parts.driveCar(0, 0, 0, 1)
        return
      end

      local path
      wp1, wp2, path = buildTrafficWaypointPath(wp1, wp2)

      if path and path[1] then
        local route = parts.planAhead(path, ctx.aiState.currentRoute)

        if route and route.plan then
          trafficStates.block.timerLimit = max(1, ctx.aiState.parameters.trafficWaitTime * 2)

          table.clear(trafficStates.intersection)
          trafficStates.intersection.timer = 0
          trafficStates.intersection.turn = 0
          trafficStates.intersection.block = false

          if trafficStates.block.timer > trafficStates.block.timerLimit and trafficStates.action.hornTimer == -1 then
            trafficStates.block.timer = 0
            if not trafficStates.block.hornFlag then
              trafficStates.action.hornTimer = 0 -- activates horn
              trafficStates.block.hornFlag = true -- prevents horn from triggering again while stopped
            end

            ctx.aiState.currentRoute = route
            return
          elseif not ctx.aiState.currentRoute then
            ctx.aiState.currentRoute = route
            return
          elseif route.plan.targetSpeed >= min(ctx.aiState.currentRoute.plan.targetSpeed, ego.speed) and parts.targetsCompatible(ctx.aiState.currentRoute, route) then
            ctx.aiState.currentRoute = route
            return
          end
        end
      end
    end

    trafficActions()

    parts.planAhead(ctx.aiState.currentRoute)
  end

  return {
    trafficActions = trafficActions,
    trafficPlan = trafficPlan,
  }
end

return lib
