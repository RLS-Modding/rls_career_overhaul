-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this file,
-- You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Route targeting, lane geometry and lane-change requests.
-- create binds this extension instance; require caches only the factory.

-- Map, in reading order:
--   plan geometry: egoPosOnPlan, calculateTarget, path helpers
--   lane changes: laneChange, openLaneToLaneRange, setStopPoint
--   lane configuration: parsing, counts and ranges of lane strings
--   node lane selection: processNodeIncomingLanes and getBestLane

local lib = {}

function lib.create(ctx)
  -- Locals for speed: this file runs every AI frame.
  local max, min, abs, floor = math.max, math.min, math.abs, math.floor
  local tableInsert = ctx.tableInsert
  local square, getTmpVec3 = ctx.square, ctx.getTmpVec3
  local gravity = ctx.g
  local ego = ctx.ego
  local planNodeStack = ctx.planNodeStack

  local function egoPosOnPlan(plan)
    local planCount = plan.planCount
    local egoSeg = 1
    local egoXnormOnSeg = 0
    for i = 1, planCount-1 do
      local p0Pos, p1Pos = plan[i].pos, plan[i+1].pos
      local xnorm = ego.pos:xnormOnLine(p0Pos, p1Pos)
      if xnorm < 1 then
        if i < planCount - 2 then
          local nextXnorm = ego.pos:xnormOnLine(p1Pos, plan[i+2].pos)
          if nextXnorm >= 0 then
            local p1Radius = plan[i+1].radiusOrig
            if ego.pos:squaredDistance(linePointFromXnorm(p1Pos, plan[i+2].pos, nextXnorm)) <
                square(ego.width + lerp(p1Radius, plan[i+2].radiusOrig, min(1, nextXnorm))) then
              egoXnormOnSeg = nextXnorm
              egoSeg = i + 1
              break
            end
          end
        end
        egoXnormOnSeg = xnorm
        egoSeg = i
        break
      end
    end

    local disp = 0
    if egoSeg > 1 then
      local sumLen = 0
      disp = egoSeg - 1
      for i = 1, disp do
        sumLen = sumLen + plan[i].length
      end

      if not planNodeStack[25] then
        tableInsert(planNodeStack, plan[1])
      end

      for i = 1, plan.planCount do
        plan[i] = plan[i+disp]
      end

      plan.planCount = plan.planCount - disp
      plan.planLen = max(0, plan.planLen - sumLen)
      plan.stopSeg = max(1, plan.stopSeg - disp)
    end

    plan.egoXnormOnSeg = egoXnormOnSeg
    plan.egoSeg = egoSeg - disp
  end

  -- returns the node index
  local function getLastNodeWithinDistance(plan, dist)
    dist = dist - plan[1].length * (1 - plan.egoXnormOnSeg)
    if dist < 0 then
      return 1
    end

    local planSeg = plan.planCount
    for i = 2, plan.planCount-1 do
      dist = dist - plan[i].length
      if dist < 0 then
        planSeg = i
        break
      end
    end

    return planSeg
  end

  local function calculateTarget(plan)
    egoPosOnPlan(plan)
    local targetLength = max(ego.speed * ctx.aiState.parameters.lookAheadKv, ctx.aiState.parameters.minStTargetDist)

    if plan.planCount >= 3 then
      local xnorm = clamp(plan.egoXnormOnSeg, 0, 1)
      targetLength = max(targetLength, plan[1].length * (1 - xnorm), plan[2].length * xnorm)
    end

    local remainder = targetLength

    local targetPos = plan.targetPos or vec3()
    targetPos:set(plan[plan.planCount].pos)
    local targetSeg = max(1, plan.planCount-1)
    local prevPos = getTmpVec3(ego)
    prevPos:setLinePointFromXnorm(plan[1].pos, plan[2].pos, plan.egoXnormOnSeg) -- ego.pos

    local segVec, segLen = getTmpVec3(ego), nil
    local lp_n1n2 = getTmpVec3(ego)
    local tmpVecC = getTmpVec3(ego)
    for i = 2, plan.planCount do
      local pos = plan[i].pos

      segVec:setSub2(pos, prevPos)
      segLen = segLen or segVec:length()

      if remainder <= segLen then
        targetSeg = i - 1
        targetPos:setAddScaled(prevPos, segVec, remainder / (segLen + 1e-30))

        -- smooth target
        local xnorm = clamp(targetPos:xnormOnLine(prevPos, pos), 0, 1)
        lp_n1n2:setLinePointFromXnorm(prevPos, pos, xnorm * 0.5 + 0.25)
        if xnorm <= 0.5 then
          if i >= 3 then
            tmpVecC:setLinePointFromXnorm(plan[i-2].pos, prevPos, xnorm * 0.5 + 0.75)
            targetPos:setLinePointFromXnorm(tmpVecC, lp_n1n2, xnorm + 0.5)
          end
        else
          if i <= plan.planCount - 2 then
            tmpVecC:setLinePointFromXnorm(pos, plan[i+1].pos, xnorm * 0.5 - 0.25)
            targetPos:setLinePointFromXnorm(lp_n1n2, tmpVecC, xnorm - 0.5)
          end
        end
        break
      end

      prevPos = pos
      remainder = remainder - segLen
      segLen = plan[i].length
    end

    plan.targetPos = targetPos
    plan.targetSeg = targetSeg
  end

  local function targetsCompatible(baseRoute, newRoute)
    local baseTvec = baseRoute.plan.targetPos - ego.pos
    local newTvec = newRoute.plan.targetPos - ego.pos
    if ego.speed < 2 then return true end
    if newTvec:dot(ego.dirVec) * baseTvec:dot(ego.dirVec) <= 0 then return false end
    local baseTargetRight = baseTvec:cross(ego.upVec); baseTargetRight:normalize()
    return abs(newTvec:normalized():dot(baseTargetRight)) * ego.speed < 2
  end

  local function getMinPlanLen(limLow, speed, accelg)
    -- given current speed, distance required to come to a stop if I can decelerate at 0.2g
    limLow = limLow or 150
    speed = speed or ego.speed
    accelg = max(0.2, accelg or 0.2)
    return min(550, max(limLow, 0.5 * speed * speed / (accelg * gravity)))
  end

  local function pickAiWp(wp1, wp2, dirVec)
    dirVec = dirVec or ego.dirVec
    local vec1 = ctx.aiState.mapData.positions[wp1] - ego.pos
    local vec2 = ctx.aiState.mapData.positions[wp2] - ego.pos
    local dot1 = vec1:dot(dirVec)
    local dot2 = vec2:dot(dirVec)
    if (dot1 * dot2) <= 0 then
      if dot1 < 0 then
        return wp2, wp1
      end
    else
      if vec2:squaredLength() < vec1:squaredLength() then
        return wp2, wp1
      end
    end
    return wp1, wp2
  end

  local function pathExtend(path, newPath)
    if newPath == nil then return end
    local pathCount = #path
    if path[pathCount] ~= newPath[1] then return end
    pathCount = pathCount - 1
    for i = 2, #newPath do
      path[pathCount+i] = newPath[i]
    end
  end

  local function getPathLen(path, startIdx, stopIdx)
    if not path then return end
    startIdx = startIdx or 1
    stopIdx = stopIdx or #path
    local positions = ctx.aiState.mapData.positions
    local pathLen = 0
    for i = startIdx+1, stopIdx do
      pathLen = pathLen + positions[path[i-1]]:distance(positions[path[i]])
    end

    return pathLen
  end

  local function waypointInPath(path, waypoint, startIdx, stopIdx)
    if not path or not waypoint then return end
    startIdx = startIdx or 1
    stopIdx = stopIdx or #path
    for i = startIdx, stopIdx do
      if path[i] == waypoint then
        return i
      end
    end
  end


  local function updatePlanLen(plan, j, k)
    j = max((j or 1) - 1, 1)
    k = min(k or plan.planCount, plan.planCount-1)

    local planLen = plan.planLen
    for i = j, k do
      local edgeLen = plan[i+1].pos:distance(plan[i].pos)
      planLen = planLen - plan[i].length + edgeLen
      plan[i].length = edgeLen
    end
    plan.planLen = planLen
  end

  -- expand lane lateral limits of this plan node to the lane range limits
  local function openLaneToLaneRange(planNode)
    local roadHalfWidth = planNode.halfWidth
    planNode.laneLimLeft = linearScale(planNode.rangeLeft, 0, 1, -roadHalfWidth, roadHalfWidth)
    planNode.laneLimRight = linearScale(planNode.rangeRight, 0, 1, -roadHalfWidth, roadHalfWidth)
    planNode.lanesOpen = true
  end

  -- expand lane lateral limits to the lane range for all nodes up to and including idx
  local function openPlanLanesToLaneRange(plan, idx)
    plan = plan or (ctx.aiState.currentRoute and ctx.aiState.currentRoute.plan)
    if not plan then return end
    for i = 1, min(plan.planCount, idx) do
      openLaneToLaneRange(plan[i])
    end
  end

  local function laneChange(plan, dist, signedDisp)
    if not plan and ctx.aiState.currentRoute then plan = ctx.aiState.currentRoute.plan end
    if not plan then return end

    -- Apply node displacement
    local invDist = 1 / (dist + 1e-30)
    local curDist = 0
    for i = 2, plan.planCount do
      openLaneToLaneRange(plan[i])
      curDist = curDist + plan[i-1].length
      plan[i].lateralXnorm = clamp(plan[i].lateralXnorm + signedDisp * min(curDist * invDist, 1), plan[i].laneLimLeft, plan[i].laneLimRight)
      plan[i].pos:setAddScaled(plan[i].posOrig, plan[i].normal, plan[i].lateralXnorm)

      -- Recalculate vec and dirVec
      plan[i].vec:setSub2(plan[i-1].pos, plan[i].pos); plan[i].vec.z = 0
      plan[i].dirVec:setScaled2(plan[i].vec, 1 / plan[i].vec:lengthGuarded())
    end

    updatePlanLen(plan)

  end

  local function setStopPoint(plan, dist, args)
    if not (plan or (ctx.aiState.currentRoute and ctx.aiState.currentRoute.plan)) then
      return
    end

    plan = plan or ctx.aiState.currentRoute.plan

    if not dist then -- reset stop segment
      plan.stopSeg = math.huge
      return
    end

    -- Avoid stopping directly in junctions.
    if args and args.avoidJunction and ctx.aiState.currentRoute.path then -- prevents stopping directly in junctions
      -- this code is temporary, and inefficient...
      local seg
      while true do
        seg = getLastNodeWithinDistance(plan, dist)
        local nid = ctx.aiState.currentRoute.path[plan[seg].pathidx]
        if seg < plan.planCount - 1 and tableSize(ctx.aiState.mapData.graph[nid]) > 2 and plan[seg].pos:squaredDistance(ctx.aiState.mapData.positions[nid]) <= square(ctx.aiState.mapData.radius[nid]) then
          dist = dist + 20
        else
          break
        end
      end
      plan.stopSeg = seg
    else
      plan.stopSeg = getLastNodeWithinDistance(plan, dist)
    end
  end

  local function numOfLanesFromRadius(rad1, rad2)
    return max(1, floor(min(rad1, rad2 or math.huge) * 2 / 3.61 + 0.5)) -- floor(min(rad1, rad2) / 2.7) + 1
  end

  local laneStringBuffer = ctx.buffer.new()
  local function flipLanes(lanes)
    -- ex. '--+++' becomes '---++'
    for i = #lanes, 1, -1 do
      laneStringBuffer:put(lanes:byte(i) == 43 and '-' or lanes:byte(i) == 45 and '+' or '0')
    end
    return laneStringBuffer:get()
  end

  -- returns the number of lanes in a given direction
  local function numOfLanesInDirection(lanes, dir)
    dir = dir == '+' and 43 or dir == '-' and 45
    local lanesN = 0
    for i = 1, #lanes, 1 do
      if lanes:byte(i) == dir then
        lanesN = lanesN + 1
      end
    end
    return lanesN
  end

  -- Infer missing lane data from node radii.
  local function getEdgeLaneConfig(fromNode, toNode)
    local lanes
    local edge = ctx.aiState.mapData.graph[fromNode][toNode]
    if edge.lanes then
      lanes = edge.lanes
    else -- make up some lane data in case they don't exist
      if edge.oneWay then
        local numOfLanes = numOfLanesFromRadius(ctx.aiState.mapData.radius[fromNode],
          ctx.aiState.mapData.radius[toNode])
        lanes = string.rep("+", numOfLanes)
      else
        local numOfLanes = max(1, floor(numOfLanesFromRadius(ctx.aiState.mapData.radius[fromNode], ctx.aiState.mapData.radius[toNode]) * 0.5))
        if mapmgr.rules.rightHandDrive then
          lanes = string.rep("+", numOfLanes)..string.rep("-", numOfLanes)
        else
          lanes = string.rep("-", numOfLanes)..string.rep("+", numOfLanes)
        end
      end
    end

    return edge.inNode == fromNode and lanes or flipLanes(lanes) -- flip lanes string based on inNode data
  end

  -- Calculate the edge incident on wp2 which is most similar to the edge wp1->wp2
  local function roadNaturalContinuation(wp1, wp2)
    local inLaneConfig = getEdgeLaneConfig(wp1, wp2)
    local inRadiuswp2, inRadiuswp1 = ctx.aiState.mapData:getEdgeRadii(wp2, wp1)
    local inEdgeDir = vec3(); inEdgeDir:setSub2(ctx.aiState.mapData:getEdgePositions(wp2, wp1)); inEdgeDir:normalize()
    local laneFlow = ctx.aiState.mapData.graph[wp1][wp2].drivability * 4 * min(inRadiuswp2,
      inRadiuswp1) / #inLaneConfig
    local inLaneCount = numOfLanesInDirection(inLaneConfig, '+')
    local inFwdFlow = inLaneCount * laneFlow
    local inLaneCountOpposite = (#inLaneConfig - inLaneCount)
    local inBackFlow = inLaneCountOpposite * laneFlow
    local outEdgeDir, maxOutflow, minNode = vec3(), 0, nil
    for k in pairs(ctx.aiState.mapData.graph[wp2]) do
      if k ~= wp1 then
        local outLaneConfig = getEdgeLaneConfig(wp2, k)
        local numOfOutLanes = numOfLanesInDirection(outLaneConfig, '+')
        outEdgeDir:setSub2(ctx.aiState.mapData:getEdgePositions(k, wp2)); outEdgeDir:normalize()
        local dirCoef = 0.5 * max(0, 1 + outEdgeDir:dot(inEdgeDir))
        local outLaneCountOpposite = (#outLaneConfig - numOfOutLanes)
        local outRadiuswp2, outRadiusk = ctx.aiState.mapData:getEdgeRadii(wp2, k)
        if numOfOutLanes == inLaneCount and  outLaneCountOpposite == inLaneCountOpposite then
          laneFlow = ctx.aiState.mapData.graph[wp2][k].drivability * 4 * 0.5 * (inRadiuswp2 + outRadiuswp2) / #outLaneConfig
        else
          laneFlow = ctx.aiState.mapData.graph[wp2][k].drivability * 4 * min(outRadiuswp2,
            outRadiusk)/ #outLaneConfig
        end
        local outFwdFlow = min(inFwdFlow, numOfOutLanes * laneFlow)
        local outBackFlow = min(inBackFlow, outLaneCountOpposite * laneFlow)
        local outflow = outFwdFlow * (1 + outBackFlow) * dirCoef

        if outflow > maxOutflow then
          maxOutflow = outflow
          minNode = k
        end
      end
    end

    return minNode
  end


  -- returns the lane indices of the left most and right most lanes in the direction of travel
  local function laneRangeIdx(laneConfig)
    local numOfLanes = #laneConfig
    local leftIdx, rightIdx = 1, numOfLanes
    for i = 1, numOfLanes do
      if laneConfig:byte(i) == 43 then -- "+"
        leftIdx = i
        break
      end
    end

    for i = numOfLanes, 1, -1 do
      if laneConfig:byte(i) == 43 then -- "+"
        rightIdx = i
        break
      end
    end

    return leftIdx, rightIdx, numOfLanes
  end

  -- Interleaved opposing lanes remain inside the outer bounds of lanes in our direction.
  local function laneRange(laneConfig)
    local leftLim, rightLim, numOfLanes = laneRangeIdx(laneConfig)
    return (leftLim - 1) / numOfLanes, rightLim / numOfLanes, rightLim - leftLim + 1
  end

  local function splitLaneRange(laneConfig)
    local leftIdx, rightIdx, numOfLanes = laneRangeIdx(laneConfig)

    return laneConfig:sub(1, leftIdx-1), laneConfig:sub(leftIdx, rightIdx), laneConfig:sub(rightIdx+1, numOfLanes)
  end

  -- Lateral xnorm limits ([0, 1]) of the left most and right most lanes from "lane" in the direction of "lane"
  local function getLaneRangeFromLane(laneConfig, lane)
    local numOfLanes = #laneConfig
    local leftIdx, rightIdx = lane, lane
    -- search left
    for i = lane-1, 1, -1 do
      if laneConfig:byte(i) == 43 then -- "+"
        leftIdx = i
      else
        break
      end
    end

    -- search right
    for i = lane+1, numOfLanes do
      if laneConfig:byte(i) == 43 then -- "+"
        rightIdx = i
      else
        break
      end
    end

    return (leftIdx-1) / numOfLanes, rightIdx / numOfLanes, leftIdx, rightIdx
  end

  local function processNodeIncomingLanes(newNode, planNode)
    local leftRange, centerRange, rightRange = splitLaneRange(newNode.inEdgeLanes)
    local latXnorm = planNode.lateralXnorm
    local laneLimLeft = planNode.laneLimLeft
    local laneLimRight = planNode.laneLimRight
    local halfWidth = planNode.halfWidth
    local numOfOutLanes = numOfLanesInDirection(newNode.outEdgeLanes, "+")
    local numOfInLanes = numOfLanesInDirection(newNode.inEdgeLanes, "+")
    local defaultLaneWidth = min(2 * halfWidth / (#newNode.inEdgeLanes), 3.45)
    local graph = ctx.aiState.mapData.graph
    local prevNodeInPath = newNode.prevNodeInPath
    local inEdgeDrivabilityInv = 1 / ((graph[prevNodeInPath] and graph[prevNodeInPath][newNode.id] and graph[prevNodeInPath][newNode.id].drivability or 1) + 1e-30)
    if not planNode.rangeLeft then planNode.rangeLeft, planNode.rangeRight = laneRange(newNode.inEdgeLanes) end
    local rangeLeft = linearScale(planNode.rangeLeft or 0, 0, 1, -halfWidth, halfWidth)
    local rangeRight = linearScale(planNode.rangeRight or 1, 0, 1, -halfWidth, halfWidth)

    for nodeId, edgeData in pairs(graph[newNode.id]) do
      if nodeId ~= newNode.nextNodeInPath and nodeId ~= prevNodeInPath then -- and not mapmgr.signalsData.nodes[newNode.id]
        local lanes = getEdgeLaneConfig(nodeId, newNode.id)
        local thisEdgeInLanes = numOfLanesInDirection(lanes, '+')
        if thisEdgeInLanes > 0 then -- TODO: Should also possibly include traffic light data
          local nodePos = ctx.aiState.mapData.positions[nodeId]
          local dirRatio = max(0, (push3(ctx.aiState.mapData.positions[newNode.nextNodeInPath or newNode.id]) - newNode.posOrig):normalized():dot((push3(newNode.posOrig) - nodePos):normalized()))
          local drivabilityRatio = min(1, edgeData.drivability * inEdgeDrivabilityInv)
          thisEdgeInLanes = floor(thisEdgeInLanes * dirRatio * drivabilityRatio + 0.5)

          if thisEdgeInLanes > 0 then
            if newNode.inEdgeNormal:dot(nodePos) < newNode.inEdgeNormal:dot(newNode.posOrig) then -- coming into newNode from the left
              numOfInLanes = numOfInLanes + thisEdgeInLanes
              centerRange = string.rep("+", thisEdgeInLanes)..centerRange
              local radius = thisEdgeInLanes * defaultLaneWidth * 0.5
              latXnorm = latXnorm + radius
              laneLimLeft = laneLimLeft + radius
              laneLimRight = laneLimRight + radius
              halfWidth = halfWidth + radius
              rangeLeft = rangeLeft - radius
              rangeRight = rangeRight + radius -- TODO: is this correct?
            elseif numOfInLanes < numOfOutLanes then
              local capInLanes = min(numOfInLanes + thisEdgeInLanes, numOfOutLanes)
              thisEdgeInLanes = capInLanes - numOfInLanes
              numOfInLanes = capInLanes
              local radius = thisEdgeInLanes * defaultLaneWidth * 0.5
              centerRange = centerRange..string.rep("+", thisEdgeInLanes)
              latXnorm = latXnorm - radius
              laneLimLeft = laneLimLeft - radius
              laneLimRight = laneLimRight - radius
              halfWidth = halfWidth + radius
              rangeLeft = rangeLeft - radius
              rangeRight = rangeRight + radius
            end
          end
        end
      end
    end

    return leftRange..centerRange..rightRange, latXnorm, laneLimLeft, laneLimRight, rangeLeft, rangeRight, halfWidth
  end

  -- Calculate the most appropriate lane of laneConfig
  local function getBestLane(laneConfig, nodeLatPos, laneLeftLimLatPos, laneRightLimLatPos, plan, newNode)
    -- nodeLatPos, laneLeftLimLatPos, laneRightLimLatPos are in the [0, 1] interval

    local isRightHandDrive = mapmgr.rules.rightHandDrive -- driving side parameter of the map for more exterior lane selection
    local laneWidth = laneRightLimLatPos - laneLeftLimLatPos
    local numOfLanes = max(1, #laneConfig)

    local newEdgeVec, newNodeWidthVec, dirVec = vec3(), vec3(), vec3()
    if plan then
      dirVec:setSub2(plan[plan.planCount].pos, plan[max(1, plan.planCount-1)].pos); dirVec:normalize()

      if newNode then
        newEdgeVec:setSub2(newNode.posOrig, plan[plan.planCount].pos)
        newNodeWidthVec:setScaled2(newNode.normal, newNode.halfWidth)
        if #newNode.outEdgeLanes == #laneConfig then -- TODO: this might not be correct
          dirVec:set(0, 0, 0)
        end
      end
    end

    local bestError, bestLane, newLaneLimLeft, newLaneLimRight = math.huge, nil, nil, nil
    for i = 1, numOfLanes do -- traverse lanes in laneConfig
      local thisLaneLimLeft, thisLaneLimRight = (i - 1) / numOfLanes, i / numOfLanes
      local thisLaneLatPos = (thisLaneLimRight + thisLaneLimLeft) * 0.5
      local laneColinearity = ((thisLaneLatPos * 2 - 1) * push3(newNodeWidthVec) + newEdgeVec):normalized():dot(dirVec)
      local colinearityError = 1 - max(0, laneColinearity)
      local distError = abs(thisLaneLatPos - nodeLatPos)
      local overlapError = laneWidth - max(0, min(thisLaneLimRight, laneRightLimLatPos) - max(thisLaneLimLeft, laneLeftLimLatPos))
      local directionError = laneConfig:byte(i) == 43 and 0 or 1

      -- lane bias, as driving-side aware, for right-hand drive: prefer leftmost lanes, for left-hand drive: prefer rightmost lanes
      local laneBias = isRightHandDrive and i - 1 or numOfLanes - i
      local totalError = distError + overlapError * 10 + directionError * 100 + laneBias * 0.1 + colinearityError * 3

      if totalError < bestError then
        bestError = totalError
        bestLane = i
        newLaneLimLeft = thisLaneLimLeft
        newLaneLimRight = thisLaneLimRight
      end
    end

    return bestLane, newLaneLimLeft, newLaneLimRight -- lateral positions are in the [0, 1] interval
  end

  return {
    getLastNodeWithinDistance = getLastNodeWithinDistance,
    calculateTarget = calculateTarget,
    targetsCompatible = targetsCompatible,
    getMinPlanLen = getMinPlanLen,
    pickAiWp = pickAiWp,
    pathExtend = pathExtend,
    getPathLen = getPathLen,
    waypointInPath = waypointInPath,
    updatePlanLen = updatePlanLen,
    openLaneToLaneRange = openLaneToLaneRange,
    openPlanLanesToLaneRange = openPlanLanesToLaneRange,
    laneChange = laneChange,
    setStopPoint = setStopPoint,
    numOfLanesInDirection = numOfLanesInDirection,
    getEdgeLaneConfig = getEdgeLaneConfig,
    roadNaturalContinuation = roadNaturalContinuation,
    laneRange = laneRange,
    getLaneRangeFromLane = getLaneRangeFromLane,
    processNodeIncomingLanes = processNodeIncomingLanes,
    getBestLane = getBestLane,
  }
end

return lib
