-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this file,
-- You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding

-- Route-node construction, path extension and plan error distribution.
-- create binds this extension instance; require caches only the factory.

-- Map, in reading order:
--   node construction: getNewNode, initializeNextRouteNode
--   node edges, normals and lane position: resolveRouteNodeEdges to finishNextRouteNode
--   route assembly: buildNextRoute, mergePathPrefix, createNewRoute
--   error distribution, and isVehicleStopped (exported)

local lib = {}

function lib.create(ctx)
  -- Locals for speed: this file runs every AI frame.
  local max, min, abs = math.max, math.min, math.abs
  local tableRemove = ctx.tableRemove
  local square, getTmpVec3 = ctx.square, ctx.getTmpVec3
  -- Functions from the other AI parts that this part calls, read from ctx once when it is created.
  local parts = {
    updatePlanLen = ctx.updatePlanLen,
    numOfLanesInDirection = ctx.numOfLanesInDirection,
    getEdgeLaneConfig = ctx.getEdgeLaneConfig,
    laneRange = ctx.laneRange,
    getLaneRangeFromLane = ctx.getLaneRangeFromLane,
    processNodeIncomingLanes = ctx.processNodeIncomingLanes,
    getBestLane = ctx.getBestLane,
  }

  local function setGetPathNodePosition(outPos, route, i)
    local path = route.path
    local wp1 = path[i-1] or route.plan[1].wp
    local wp2 = path[i]
    local wp3 = path[i+1]

    if not wp1 and not wp3 then
      outPos:set(ctx.aiState.mapData.positions[wp2])
      return
    elseif not wp1 then
      local wp2Pos = ctx.aiState.mapData:getEdgePositions(wp2, wp3)
      outPos:set(wp2Pos)
      return
    elseif not wp3 then
      local _, wp2Pos = ctx.aiState.mapData:getEdgePositions(wp1, wp2)
      outPos:set(wp2Pos)
      return
    end

    local e1P1, e1P2 = ctx.aiState.mapData:getEdgePositions(wp1, wp2)
    local e2P1, e2P2 = ctx.aiState.mapData:getEdgePositions(wp2, wp3)

    if e1P2:squaredDistance(e2P1) < 0.005 then
      outPos:set((push3(e1P2) + e2P1) * 0.5)
      return
    end

    local e1Vec = getTmpVec3(ctx.ego); e1Vec:setSub2(e1P2, e1P1)
    local e2Vec = getTmpVec3(ctx.ego); e2Vec:setSub2(e2P2, e2P1)
    local e1Xnorm, e2Xnorm = closestLinePointsPointVec(e1P1, e1Vec, e2P1, e2Vec)

    if square(e1Vec:dot(e2Vec)) > e1Vec:squaredLength() * e2Vec:squaredLength() * square(0.9999) or (e1Xnorm < 0 or e2Xnorm > 1) then
      -- segments are parallel or intersection is over segment 2 end or before segment 1 start (particular case)
      outPos:set((push3(e1P2) + e2P1) * 0.5)
      return
    end

    local _, e1R2 = ctx.aiState.mapData:getEdgeRadii(wp1, wp2)
    local e2R1 = ctx.aiState.mapData:getEdgeRadii(wp2, wp3)

    if e1Xnorm >= 0 and e2Xnorm <= 1 then
      local e1Len, e2Len = e1Vec:length(), e2Vec:length()
      local inE1 = (e1Xnorm - 1) * e1Len <= e1R2  -- within e1 radius extended at P2 towards positive
      local inE2 = e2Xnorm * e2Len >= -e2R1       -- within e2 radius extended at P2 towards negative
      if inE1 and inE2 then
        outPos:setLinePointFromXnorm(e1P1, e1P2, e1Xnorm)
        local p2 = getTmpVec3(ctx.ego); p2:setLinePointFromXnorm(e2P1, e2P2, e2Xnorm)
        outPos:setAdd(p2); outPos:setScaled(0.5)
        return
      elseif inE1 then
        outPos:setLinePointFromXnorm(e1P1, e1P2, max(e1Xnorm, 1 - e1R2 / e1Len))
        return
      elseif inE2 then
        outPos:setLinePointFromXnorm(e2P1, e2P2, min(e2Xnorm, e2R1 / e2Len))
        return
      end
    end

    -- intersection is between segments 1 and 2 but outside of radii extensions
    outPos:setLinePointFromXnorm(e1P1, e1P2, e1Xnorm)
    local p2 = getTmpVec3(ctx.ego); p2:setLinePointFromXnorm(e2P1, e2P2, e2Xnorm)
    outPos:setAdd(p2); outPos:setScaled(0.5)
    local avgPoint = getTmpVec3(ctx.ego); avgPoint:set((push3(e1P2) + e2P1) * 0.5)
    outPos:setSub(avgPoint) --avgPointToP1Line
    outPos:setAddScaled(avgPoint, outPos, max(0, min(1, 0.5 * (e1R2 + e2R1) / outPos:length())))
  end


  local function getPathNodeRadius(path, i)
    if not path[i-1] and not path[i+1] then
      return ctx.aiState.mapData.radius[path[i]]
    elseif not path[i-1] then
      local wp1Rad = ctx.aiState.mapData:getEdgeRadii(path[i], path[i+1])
      return wp1Rad
    elseif not path[i+1] then
      local _, wp2Rad = ctx.aiState.mapData:getEdgeRadii(path[i-1], path[i])
      return wp2Rad
    else
      local wp1Pos, wp2Pos = ctx.aiState.mapData:getEdgePositions(path[i-1], path[i])
      local wp3Pos, wp4Pos = ctx.aiState.mapData:getEdgePositions(path[i], path[i+1])
      local e1Xnorm, e2Xnorm = closestLineSegmentPoints(wp1Pos, wp2Pos, wp3Pos, wp4Pos)
      local wp1Rad, wp2Rad = ctx.aiState.mapData:getEdgeRadii(path[i-1], path[i])
      local wp3Rad, wp4Rad = ctx.aiState.mapData:getEdgeRadii(path[i], path[i+1])
      local r1 = wp1Rad + (wp2Rad - wp1Rad) * e1Xnorm
      local r2 = wp3Rad + (wp4Rad - wp3Rad) * e2Xnorm
      return (r1 + r2) * 0.5
    end
  end

  local function getNewNode()
    local node = tableRemove(ctx.planNodeStack)
    if node then
      node.wp = nil
      node.lanesOpen = nil
      table.clear(node.awCache)
    else
      node = table.new(0, 30)
      node.posOrig = vec3()
      node.pos = vec3()
      node.vec = vec3()
      node.dirVec = vec3()
      node.turnDir = vec3()
      node.biNormal = vec3()
      node.normal = vec3()
      node.awCache = {}
    end
    return node
  end

  local function advanceLoopPathIndex(path, nextPathIdx)
    if not (ctx.routeLoop.loopPath == true and ctx.routeLoop.noOfLaps and ctx.routeLoop.noOfLaps > 1 and not path[nextPathIdx]) then return nextPathIdx end
    local loopPathId
    local pathCount = #path
    local lastWayPoint = path[pathCount]
    for i = 1, pathCount do
      if lastWayPoint == path[i] then
        loopPathId = i
        break
      end
    end
    nextPathIdx = 1 + loopPathId -- nextPathIdx % #path
    ctx.routeLoop.noOfLaps = ctx.routeLoop.noOfLaps - 1
    return nextPathIdx
  end

  local function initializeNextRouteNode(newNode, route, path, nextPathIdx, newNodeId, plan, planCount)
    setGetPathNodePosition(newNode.posOrig, route, nextPathIdx)

    newNode.pos:set(newNode.posOrig)
    newNode.vec:set(0, 0, 0)
    newNode.dirVec:set(0, 0, 0)
    newNode.turnDir:set(0, 0, 0)
    mapmgr.setSurfaceNormalBelow(newNode.biNormal, ctx.aiState.mapData.positions[newNodeId], ctx.aiState.mapData.radius[newNodeId] * 0.5)
    newNode.biNormal:setScaled(-1)
    newNode.normal:set(0, 0, 0)
    newNode.radiusOrig = getPathNodeRadius(path, nextPathIdx)
    newNode.manSpeed = ctx.aiState.speedProfile and ctx.aiState.speedProfile[newNodeId]
    newNode.pathidx = nextPathIdx
    newNode.laneLimLeft = 0 -- lateral coordinate of current lane left limit [-hW, hW]
    newNode.laneLimRight = 1 -- lateral coordinate of current lane right limit [-hW, hW]
    newNode.rangeLeft = 0 -- lateral coordinate [0, 1] of the left hand side limit of the left most lane in the direction of travel
    newNode.rangeRight = 1 -- lateral coordinate [0, 1] of the right hand side limit of the right most lane in the direction of travel
    newNode.rangeLaneCount = 1 -- number of contiguous lanes in the direction of travel counting from the current lane
    newNode.rangeBestLane = 0
    newNode.length = 0
    newNode.curvature = 0
    newNode.curvatureZ = 0
    newNode.lateralXnorm = 0 -- lateral coordinate of pos [-hW, hW]
    newNode.trafficSqVel = math.huge
    newNode.roadSpeedLimit = nil
    newNode.halfWidth = nil
    newNode.speed = nil -- TODO: why not initialize the speed here?
    newNode.dispDir = 0
    newNode.nextNodeInPath = path[nextPathIdx+1]
    for id, awCacheEntry in pairs(plan[planCount].awCache) do
      newNode.awCache[id] = awCacheEntry
    end
    -- auxiliary data. These should be cleared before returning newNode
    newNode.id = newNodeId
    newNode.prevNodeInPath = path[nextPathIdx-1]
    newNode.inEdgeLanes = nil -- lanes going into the newNode along the path
    newNode.inEdgeNormal = nil
    newNode.outEdgeLanes = nil -- lanes coming out of the newNode along the path
    newNode.outEdgeNormal = nil
  end

  local function resolveRouteNodeEdges(newNode, graph, plan, planCount)
    if newNode.prevNodeInPath then
      local link = graph[newNode.prevNodeInPath][newNode.id]
      if link then
        newNode.inEdgeLanes = parts.getEdgeLaneConfig(newNode.prevNodeInPath, newNode.id)
      end
    else -- if previous plan node is the ego.pos then
      if planCount == 1 and plan[1].wp then -- check whether information is available
        newNode.prevNodeInPath = plan[1].wp
        newNode.inEdgeLanes = parts.getEdgeLaneConfig(newNode.prevNodeInPath, newNode.id)
      end
    end

    -- Infer a missing next node only when exactly one lawful continuation exists.
    if not newNode.nextNodeInPath then
      local nextPosibleNode = nil
      for k in pairs(graph[newNode.id]) do
        if not (k ~= newNode.prevNodeInPath) then goto nextIncidentEdge end
        if parts.numOfLanesInDirection(parts.getEdgeLaneConfig(newNode.id, k), '+') > 0 then
          if nextPosibleNode then
            nextPosibleNode = nil
            break
          else
            nextPosibleNode = k
          end
        end
        ::nextIncidentEdge::
      end
      newNode.nextNodeInPath = nextPosibleNode
    end

    if newNode.nextNodeInPath then
      local link = graph[newNode.id][newNode.nextNodeInPath]
      if link then
        newNode.outEdgeLanes = parts.getEdgeLaneConfig(newNode.id, newNode.nextNodeInPath)
      end
    else
      if ctx.M.mode ~= 'traffic' then
        newNode.outEdgeLanes = newNode.inEdgeLanes
      else
        return true
      end
    end

    if not (newNode.outEdgeLanes and not newNode.inEdgeLanes) then return end
    newNode.inEdgeLanes = newNode.outEdgeLanes
  end

  local function calculateRouteNodeNormals(newNode, plan, path, nextPathIdx, planCount)
    -- Extending or replacing a path can change the previous final node normal.
    if planCount > 1 then
      if plan[planCount].nextNodeInPath ~= path[nextPathIdx] then
        local norm1 = (push3(plan[planCount-1].posOrig) - plan[planCount].posOrig):cross(plan[planCount].biNormal):normalized():copy()
        local norm2 = (push3(plan[planCount].posOrig) - newNode.posOrig):cross(plan[planCount].biNormal):normalized():copy()
        plan[planCount].normal:setAdd2(norm1, norm2)
        local tmp = plan[planCount].normal:length()
        plan[planCount].normal:setScaled(1 / (tmp + 1e-30))
        local chordLength = min(2 / tmp, (1 - norm1:dot(norm2) * 0.5) * tmp) -- 2 / tmp == cos(x/2) : x is angle between norm1, norm2
        plan[planCount].halfWidth = plan[planCount].radiusOrig * chordLength
      end
    else
      plan[planCount].normal:set((push3(plan[planCount].posOrig) - newNode.posOrig):cross(plan[planCount].biNormal):normalized())
    end

    -- Blend incident edge normals for the inserted node.

    if newNode.prevNodeInPath then
      local wp1Pos, wp2Pos = ctx.aiState.mapData:getEdgePositions(newNode.prevNodeInPath, newNode.id)
      newNode.inEdgeNormal = (push3(wp1Pos) - wp2Pos):cross(newNode.biNormal):normalized():copy()
    else
      newNode.inEdgeNormal = vec3(0, 0, 0)
    end

    if newNode.nextNodeInPath then
      local wp1Pos, wp2Pos = ctx.aiState.mapData:getEdgePositions(newNode.id, newNode.nextNodeInPath)
      newNode.outEdgeNormal = (push3(wp1Pos) - wp2Pos):cross(newNode.biNormal):normalized():copy()
    else
      newNode.outEdgeNormal = vec3(0, 0, 0)
    end

    newNode.normal:setAdd2(newNode.inEdgeNormal, newNode.outEdgeNormal)
    local tmp = newNode.normal:length()
    newNode.normal:setScaled(1 / (tmp + 1e-30))
    local newNodeChordLength = min(2 / tmp, (1 - newNode.inEdgeNormal:dot(newNode.outEdgeNormal) * 0.5) * tmp) -- new node road width multiplier
    newNode.halfWidth = newNode.radiusOrig * newNodeChordLength
    return newNodeChordLength
  end

  local function continueRouteLaneConfiguration(
    newNode, plan, planCount, bestLane, newNodeLaneConfig, newNodeRangeLeftIdx, newNodeRangeRightIdx
  )
    local inLaneConfig, planNodeLatPos, planNodelaneLimLeft, planNodelaneLimRight, planNodeRangeLeft, planNodeRangeRight, planNodeHalfWidth = parts.processNodeIncomingLanes(newNode, plan[planCount]) -- lateral coordinates in [-r, r]

    -- Calculate lateral xnorm ranges of lanes in the direction of travel (in [0, 1])
    local outRangeLeft, outRangeRight, outRangeLaneCount = parts.laneRange(newNode.outEdgeLanes)
    local inRangeLeft, inRangeRight, inRangeLaneCount = parts.laneRange(inLaneConfig)

    -- Decide on the lane configuration of newNode: --> Retain the narrowest range
    local newNodeLaneConfigOrig
    if (inRangeRight - inRangeLeft) * outRangeLaneCount < (outRangeRight - outRangeLeft) * inRangeLaneCount then
      newNodeLaneConfig, newNode.rangeLeft, newNode.rangeRight, newNode.rangeLaneCount = inLaneConfig, inRangeLeft, inRangeRight, inRangeLaneCount
      newNodeLaneConfigOrig = newNode.inEdgeLanes
    else
      newNodeLaneConfig, newNode.rangeLeft, newNode.rangeRight, newNode.rangeLaneCount = newNode.outEdgeLanes, outRangeLeft, outRangeRight, outRangeLaneCount
      newNodeLaneConfigOrig = newNode.outEdgeLanes
    end

    local planNodeLatPosNrmd = linearScale(planNodeLatPos, planNodeRangeLeft, planNodeRangeRight, newNode.rangeLeft, newNode.rangeRight) -- TODO: lateralXnorm might be outside [inRangeLeft, inRangeRight]
    local planNodeLaneLimLeftNrmd = linearScale(planNodelaneLimLeft, planNodeRangeLeft, planNodeRangeRight, newNode.rangeLeft, newNode.rangeRight)
    local planNodeLaneLimRightNrmd = linearScale(planNodelaneLimRight, planNodeRangeLeft, planNodeRangeRight, newNode.rangeLeft, newNode.rangeRight)
    -- Calculate the most appropriate lane out of newNodeLaneConfig. This will be where to position the new node lateraly along the normal of newNode.
    bestLane, newNode.laneLimLeft, newNode.laneLimRight = parts.getBestLane(newNodeLaneConfig, planNodeLatPosNrmd, planNodeLaneLimLeftNrmd, planNodeLaneLimRightNrmd, plan, newNode) -- lateral coordinates in [0, 1]

    -- Calculate the lane range (i.e. lateral limits of left most and right most lanes traveling in the same direction as bestLane, starting from bestLane)
    local rangeLeft, rangeRight = newNode.rangeLeft, newNode.rangeRight
    newNode.rangeLeft, newNode.rangeRight, newNodeRangeLeftIdx, newNodeRangeRightIdx = parts.getLaneRangeFromLane(newNodeLaneConfig, bestLane) -- lateral coordinates in [0, 1]

    local rangeLeftOrig, rangeRightOrig = parts.laneRange(newNodeLaneConfigOrig) -- Will this work when the lane config is not monotonic?
    newNode.rangeLeft = linearScale(newNode.rangeLeft, rangeLeft, rangeRight, rangeLeftOrig, rangeRightOrig)
    newNode.rangeRight = linearScale(newNode.rangeRight, rangeLeft, rangeRight, rangeLeftOrig, rangeRightOrig)
    newNode.laneLimLeft = linearScale(newNode.laneLimLeft, rangeLeft, rangeRight, rangeLeftOrig, rangeRightOrig)
    newNode.laneLimRight = linearScale(newNode.laneLimRight, rangeLeft, rangeRight, rangeLeftOrig, rangeRightOrig)

    newNode.pos:setAddScaled(newNode.pos, newNode.normal, ((newNode.laneLimLeft + newNode.laneLimRight) - 1) * newNode.halfWidth)

    newNode.inEdgeNormal:set((push3(plan[planCount].pos) - newNode.pos):cross(newNode.biNormal):normalized())

    newNode.normal:setAdd2(newNode.inEdgeNormal, newNode.outEdgeNormal)
    return bestLane, newNodeLaneConfig, newNodeRangeLeftIdx, newNodeRangeRightIdx
  end

  local function positionNextRouteNodeInLane(newNode, plan, planCount, newNodeChordLength)
    local bestLane, newNodeLaneConfig
    local newNodeRangeLeftIdx -- index of left most lane in range
    local newNodeRangeRightIdx -- index of right most lane in range

    if ctx.opt.driveInLaneFlag and newNode.inEdgeLanes then
      -- Consider lanes comming into newNode, scale/translate planNode lateral position and lane limits and add them to the in lane configuration as appropriate
      bestLane, newNodeLaneConfig, newNodeRangeLeftIdx, newNodeRangeRightIdx = continueRouteLaneConfiguration(
        newNode, plan, planCount, bestLane, newNodeLaneConfig, newNodeRangeLeftIdx, newNodeRangeRightIdx
      )
      local tmp = newNode.normal:length()
      newNode.normal:setScaled(1 / (tmp + 1e-30))
      newNodeChordLength = min(2 / tmp, (1 - newNode.inEdgeNormal:dot(newNode.outEdgeNormal) * 0.5) * tmp)
      newNode.halfWidth = newNode.radiusOrig * newNodeChordLength
    end

    if newNodeLaneConfig and #newNodeLaneConfig > 1 and newNode.nextNodeInPath and newNode.prevNodeInPath then -- TODO: error hits if the nextNode/prevNode conditions are not here
      -- Keep narrower lane limits inside the road width.
      local laneWidth = 2 * newNode.radiusOrig * (newNode.rangeRight - newNode.rangeLeft) / newNode.rangeLaneCount -- lane width not including chordLength
      -- keep inside lanes narrower
      if (push3(ctx.aiState.mapData.positions[newNode.nextNodeInPath]) - newNode.posOrig + ctx.aiState.mapData.positions[newNode.prevNodeInPath] - newNode.posOrig):dot(newNode.normal) < 0 then -- = turnDir * normal
        newNode.laneLimLeft = linearScale(newNode.rangeLeft, 0, 1, -newNode.halfWidth, newNode.halfWidth) + (bestLane - newNodeRangeLeftIdx) * laneWidth
        newNode.laneLimRight = newNode.laneLimLeft + laneWidth
        newNode.lateralXnorm = (newNode.laneLimLeft + newNode.laneLimRight) * 0.5
        if bestLane == #newNodeLaneConfig then newNode.laneLimRight = newNode.halfWidth end -- give remaining space on the right to the right most lane
      else
        newNode.laneLimRight = linearScale(newNode.rangeRight, 0, 1, -newNode.halfWidth, newNode.halfWidth) - (newNodeRangeRightIdx - bestLane) * laneWidth
        newNode.laneLimLeft = newNode.laneLimRight - laneWidth
        newNode.lateralXnorm = (newNode.laneLimLeft + newNode.laneLimRight) * 0.5
        if bestLane == 1 then newNode.laneLimLeft = -newNode.halfWidth end -- give remaining space on the left to left most lane
      end
    else
      -- Transform newNode lateral position and lane limits from [0, 1] to [-r, r] using the recalculated newNodeHalfWidth
      newNode.laneLimLeft = linearScale(newNode.laneLimLeft, 0, 1, -newNode.halfWidth, newNode.halfWidth)
      newNode.laneLimRight = linearScale(newNode.laneLimRight, 0, 1, -newNode.halfWidth, newNode.halfWidth)
      newNode.lateralXnorm = (newNode.laneLimLeft + newNode.laneLimRight) * 0.5
    end
    return bestLane, newNodeRangeLeftIdx
  end

  local function finishNextRouteNode(newNode, plan, planCount, graph, bestLane, newNodeRangeLeftIdx)
    local CENTERLINE_BLEND_DISTANCE_M = 100
    -- plan converges gradually towards the center of the road
    if not ctx.opt.driveInLaneFlag then
      -- normalized lateral xnorm of the last node on the plan
      local normalizedPrevLatXnorm = plan[plan.planCount].lateralXnorm / (plan[plan.planCount].halfWidth)

      -- last plan node lateral xnorm scaled to the width of the new node
      local lateralXnorm = max(min(normalizedPrevLatXnorm * newNode.halfWidth, newNode.halfWidth),
        -newNode.halfWidth)

      -- calculate smoothing parameter
      local t = min(1, max(0, plan.planLen / CENTERLINE_BLEND_DISTANCE_M)) -- currently converges to the center of the road at 100m

      -- calculate desired lateral xnorm for the new plan node
      newNode.lateralXnorm = lateralXnorm * (1 - t) + newNode.lateralXnorm * t
    end

    newNode.pos:setAddScaled(newNode.posOrig, newNode.normal, newNode.lateralXnorm)

    local lastPlanPos = plan[planCount] and plan[planCount].pos or ctx.ego.pos
    newNode.vec:setSub2(lastPlanPos, newNode.pos); newNode.vec.z = 0
    newNode.dirVec:setScaled2(newNode.vec, 1 / newNode.vec:lengthGuarded())

    local prevSpeedLimit = newNode.prevNodeInPath and graph[newNode.prevNodeInPath][newNode.id].speedLimit or math.huge
    local nextSpeedLimit = newNode.nextNodeInPath and graph[newNode.id][newNode.nextNodeInPath].speedLimit or math.huge
    newNode.roadSpeedLimit = min(prevSpeedLimit, nextSpeedLimit)
    newNode.rangeBestLane = bestLane and newNodeRangeLeftIdx and (bestLane - newNodeRangeLeftIdx) or newNode.rangeBestLane -- 0 indexed

    -- clear auxiliary data
    newNode.id = nil
    newNode.prevNodeInPath = nil
    newNode.inEdgeLanes = nil -- lanes going into the newNode along the path
    newNode.inEdgeNormal = nil
    newNode.outEdgeLanes = nil -- lanes coming out of the newNode along the path
    newNode.outEdgeNormal = nil
  end

  local function buildNextRoute(route)
    local plan, path = route.plan, route.path
    local planCount = plan.planCount
    local nextPathIdx = (plan[planCount].pathidx or 0) + 1

    nextPathIdx = advanceLoopPathIndex(path, nextPathIdx)

    local newNodeId = path[nextPathIdx]
    if not newNodeId then return end
    local graph = ctx.aiState.mapData.graph
    if not graph[newNodeId] then return end

    local newNode = getNewNode()

    initializeNextRouteNode(newNode, route, path, nextPathIdx, newNodeId, plan, planCount)

    if resolveRouteNodeEdges(newNode, graph, plan, planCount) then return end

    local newNodeChordLength = calculateRouteNodeNormals(newNode, plan, path, nextPathIdx, planCount)

    local bestLane, newNodeRangeLeftIdx = positionNextRouteNodeInLane(newNode, plan, planCount, newNodeChordLength)

    finishNextRouteNode(newNode, plan, planCount, graph, bestLane, newNodeRangeLeftIdx)

    return newNode
  end

  local function mergePathPrefix(source, dest, srcStart)
    srcStart = srcStart or 1
    local sourceCount = #source
    local dict = table.new(0, max(0, sourceCount-(srcStart-1)))
    for i = srcStart, sourceCount do
      dict[source[i]] = i
    end

    local destCount = #dest
    for i = destCount, 1, -1 do
      local srci = dict[dest[i]]
      if srci ~= nil then
        local res = table.new(destCount, 0)
        local resi = 1
        for i1 = srcStart, srci - 1 do
          res[resi] = source[i1]
          resi = resi + 1
        end
        for i1 = i, destCount do
          res[resi] = dest[i1]
          resi = resi + 1
        end

        return res, srci
      end
    end

    return dest, 0
  end

  local function uniformPlanErrorDistribution(plan)
    if ctx.twt.state == 0 then
      local p1, p2 = plan[1].pos, plan[2].pos
      local dispVec = getTmpVec3(ctx.ego)
      dispVec:setLinePointFromXnorm(p1, p2, ctx.ego.pos:xnormOnLine(p1, p2))
      dispVec:setSub2(ctx.ego.pos, dispVec)
      dispVec:setScaled(min(1, 2 * ctx.aiState.dt))
      local dispVecLenInv = 1 / dispVec:lengthGuarded()


      local j = 0
      local dTotal = 0
      for i = 1, plan.planCount-1 do
        if abs(plan[i+1].pos:dot(dispVec) - plan[i].pos:dot(dispVec)) * dispVecLenInv > 0.5 * plan[i].length then
          break
        end
        j = i
        dTotal = dTotal + plan[i].length
      end
      local laneWidthMargin = ctx.ego.width * 0.6
      local sumLen = 0
      for i = j, 1, -1 do
        local n = plan[i]
        sumLen = sumLen + plan[i].length

        local lateralXnorm = n.lateralXnorm or 0
        local newLateralXnorm = clamp(lateralXnorm + (dispVec):dot(n.normal) * sumLen / dTotal, n.laneLimLeft + laneWidthMargin, n.laneLimRight - laneWidthMargin)
        n.pos:setAddScaled(n.pos, n.normal, newLateralXnorm - lateralXnorm)
        n.lateralXnorm = newLateralXnorm

        plan[i+1].vec:setSub2(plan[i].pos, plan[i+1].pos); plan[i+1].vec.z = 0
        plan[i+1].dirVec:setScaled2(plan[i+1].vec, 1 / plan[i+1].vec:lengthGuarded())
      end

      parts.updatePlanLen(plan, 1, j)
    end
  end

  local function createNewRoute(path)
    local newRoute = {
      path = path,
      plan = table.new(15, 10),
      laneChanges = {}, -- array: in the array each lane change is a dict with an idx key (path index at which lane change occurs) and a side key (direction of lane change)
      lastLaneChangeIdx = 1, -- path node up to which we have checked for a posible lane change
      pathLength = {0} -- distance from beggining of path to node at index i
    }
    newRoute.plan.stopSeg = math.huge

    return newRoute
  end

  local function isVehicleStopped(trafficVehicle)
    if trafficVehicle.isParked then
      return true
    elseif trafficVehicle.states.ignitionLevel == 0 or trafficVehicle.states.ignitionLevel == 1 then
      return true
    elseif trafficVehicle.states.hazard_enabled == 1 and trafficVehicle.vel:squaredLength() < 9 then
      return true
    end
    return false
  end

  return {
    getNewNode = getNewNode,
    buildNextRoute = buildNextRoute,
    mergePathPrefix = mergePathPrefix,
    uniformPlanErrorDistribution = uniformPlanErrorDistribution,
    createNewRoute = createNewRoute,
    isVehicleStopped = isVehicleStopped,
  }
end

return lib
