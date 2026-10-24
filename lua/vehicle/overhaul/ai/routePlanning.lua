-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this file,
-- You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding

-- Road route planning, obstacle avoidance and traffic speed limits.
-- create binds this extension instance; require caches only the factory.

-- Map, in reading order:
--   plan setup: mergeBaseRoutePlan, initializeRoutePlan, extendRoutePlan, advanceRouteLaneChanges
--   traffic: collectRouteTraffic and the side, forward and route avoidance passes
--   forces: spring forces, lane-change forces, smoothing and curvature
--   speeds: planRouteSpeeds, then planAhead, the only export

local lib = {}

function lib.create(ctx)
  -- Locals for speed: this file runs every AI frame.
  local max, min, abs, sqrt, floor, asin, sin, pi = math.max, math.min, math.abs, math.sqrt, math.floor, math.asin, math.sin, math.pi
  local tableInsert, tableRemove = ctx.tableInsert, ctx.tableRemove
  local square, getTmpVec3 = ctx.square, ctx.getTmpVec3
  local gravity = ctx.g
  -- Functions from the other AI parts that this part calls, read from ctx once when it is created.
  local parts = {
    calculateTarget = ctx.calculateTarget,
    getMinPlanLen = ctx.getMinPlanLen,
    updatePlanLen = ctx.updatePlanLen,
    openLaneToLaneRange = ctx.openLaneToLaneRange,
    openPlanLanesToLaneRange = ctx.openPlanLanesToLaneRange,
    numOfLanesInDirection = ctx.numOfLanesInDirection,
    getEdgeLaneConfig = ctx.getEdgeLaneConfig,
    roadNaturalContinuation = ctx.roadNaturalContinuation,
    laneRange = ctx.laneRange,
    getLaneRangeFromLane = ctx.getLaneRangeFromLane,
    getBestLane = ctx.getBestLane,
    buildNextRoute = ctx.buildNextRoute,
    mergePathPrefix = ctx.mergePathPrefix,
    createNewRoute = ctx.createNewRoute,
    isVehicleStopped = ctx.isVehicleStopped,
    inCurvature = ctx.inCurvature,
    solveForwardSpeedProfile = ctx.solveForwardSpeedProfile,
    solveBackwardSpeedProfile = ctx.solveBackwardSpeedProfile,
    updatePlanBestRange = ctx.updatePlanBestRange,
    densifyPlan = ctx.densifyPlan,
  }

  local function mergeBaseRoutePlan(route, plan, baseRoute)
    if not baseRoute or plan[1] then return end
    local bsrPlan = baseRoute.plan
    if not bsrPlan[2] then return end
    local commonPathEnd
    route.path, commonPathEnd = parts.mergePathPrefix(baseRoute.path, route.path, bsrPlan[2].pathidx)
    route.lastLaneChangeIdx = 2
    table.clear(route.laneChanges)
    route.pathLength = {0}
    if not (commonPathEnd >= 1) then return end
    local refpathidx = bsrPlan[2].pathidx - 1
    local planLen, planCount = 0, 0
    for i = 1, #bsrPlan do
      local n = bsrPlan[i]
      if n.pathidx > commonPathEnd then break end
      planLen = planLen + (n.length or 0)
      planCount = i

      plan[i] = {
        posOrig = vec3(n.posOrig),
        pos = vec3(n.pos),
        vec = vec3(n.vec),
        dirVec = vec3(n.dirVec),
        turnDir = vec3(n.turnDir),
        biNormal = vec3(n.biNormal),
        normal = vec3(n.normal),
        radiusOrig = n.radiusOrig,
        pathidx = max(1, n.pathidx-refpathidx),
        roadSpeedLimit = n.roadSpeedLimit,
        halfWidth = n.halfWidth,
        nextNodeInPath = n.nextNodeInPath,
        length = n.length,
        curvature = n.curvature,
        curvatureZ = n.curvatureZ,
        lateralXnorm = n.lateralXnorm,
        laneLimLeft = n.laneLimLeft,
        laneLimRight = n.laneLimRight,
        speed = nil,
        rangeLeft = n.rangeLeft,
        rangeRight = n.rangeRight,
        rangeLaneCount = n.rangeLaneCount,
        rangeBestLane = n.rangeBestLane,
        trafficSqVel = math.huge,
        dispDir = n.dispDir,
        awCache = {}
      }
    end
    plan.planLen = planLen
    plan.planCount = planCount
    plan.egoDeviation = 0
    if not plan[bsrPlan.targetSeg+1] then return end
    plan.targetSeg = bsrPlan.targetSeg
    plan.targetPos = vec3(bsrPlan.targetPos)
    plan.egoSeg = bsrPlan.egoSeg
    plan.egoXnormOnSeg = bsrPlan.egoXnormOnSeg
  end

  local function appendInitialRoutePlanNodes(
    plan, posOrig, radiusOrig, normal, latXnorm, rangeLeft, rangeRight, rangeBestLane, laneLimLeft,
    laneLimRight, biNormal, wp, lanes, roadSpeedLimit
  )
    local rangeLaneCount = lanes and parts.numOfLanesInDirection(lanes, "+") or 1 -- numOfLanesFromRadius(radiusOrig)
    local vec = vec3(-8 * ctx.ego.dirVec.x, -8 * ctx.ego.dirVec.y, 0)

    plan[1] = {
      posOrig = posOrig,
      pos = ctx.ego.pos:copy(),
      vec = vec,
      dirVec = vec:normalized(),
      turnDir = vec3(0, 0, 0),
      biNormal = biNormal,
      normal = normal,
      radiusOrig = radiusOrig,
      length = 0,
      curvature = 0,
      curvatureZ = 0,
      halfWidth = radiusOrig,
      lateralXnorm = latXnorm,
      laneLimLeft = laneLimLeft,
      laneLimRight = laneLimRight,
      rangeLeft = rangeLeft,
      rangeRight = rangeRight,
      rangeLaneCount = rangeLaneCount,
      rangeBestLane = rangeBestLane,
      pathidx = nil,
      roadSpeedLimit = roadSpeedLimit,
      speed = nil,
      wp = wp,
      trafficSqVel = math.huge,
      dispDir = 0,
      awCache = {}
    }

    plan.planCount = 1
    plan.planLen = 0
    plan.egoXnormOnSeg = 0
    plan.egoDeviation = 0
  end

  local function initializeRoutePlan(route, plan)
    if plan[1] then return end
    local posOrig = vec3(ctx.ego.pos)
    local radiusOrig = 2
    local normal = vec3(0, 0, 0)
    local latXnorm = 0
    local rangeLeft, rangeRight, rangeBestLane = 0, 1, 0
    local laneLimLeft, laneLimRight = -ctx.ego.width * 0.5, ctx.ego.width * 0.5
    local biNormal = mapmgr.surfaceNormalBelow(ctx.ego.pos, ctx.ego.width * 0.5); biNormal:setScaled(-1)
    local wp, lanes, roadSpeedLimit
    if ctx.ego.currentSegment[1] and ctx.ego.currentSegment[2] then
      local wp1 = route.path[1]
      local wp2
      if wp1 == ctx.ego.currentSegment[1] then
        wp2 = ctx.ego.currentSegment[2]
      elseif wp1 == ctx.ego.currentSegment[2] then
        wp2 = ctx.ego.currentSegment[1]
      end
      if wp2 and route.path[2] ~= wp2 then
        local pos1, pos2 = ctx.aiState.mapData:getEdgePositions(wp1, wp2)
        local xnorm = ctx.ego.pos:xnormOnLine(pos2, pos1)
        if xnorm >= 0 and xnorm <= 1 then
          local rad1, rad2 = ctx.aiState.mapData:getEdgeRadii(wp1, wp2)
          local rad = lerp(rad2, rad1, xnorm)
          local newPosOrig = linePointFromXnorm(pos2, pos1, xnorm)
          if ctx.ego.pos:squaredDistance(newPosOrig) <= rad * rad then
            posOrig = newPosOrig
            normal:setCross(biNormal, pos1 - pos2); normal:normalize()
            radiusOrig = rad
            wp = wp2
            roadSpeedLimit = ctx.aiState.mapData.graph[wp1][wp2].speedLimit
            latXnorm = ctx.ego.pos:xnormOnLinePointVec(posOrig, normal)
            laneLimLeft = latXnorm - ctx.ego.width * 0.5 -- TODO: rethink the limits here
            laneLimRight = latXnorm + ctx.ego.width * 0.5
            if ctx.opt.driveInLaneFlag then
              lanes = parts.getEdgeLaneConfig(wp2, wp1)
              rangeLeft, rangeRight = parts.laneRange(lanes)

              local normalizedLatXnorm = (latXnorm / radiusOrig + 1) * 0.5
              local normalizedLaneLimLeft = (laneLimLeft / radiusOrig + 1) * 0.5
              local normalizedLaneLimRight = (laneLimRight / radiusOrig + 1) * 0.5

              local bestLane
              bestLane, normalizedLaneLimLeft, normalizedLaneLimRight = parts.getBestLane(lanes, normalizedLatXnorm, normalizedLaneLimLeft, normalizedLaneLimRight)

              local _, _, rangeLeftIdx, rangeRightIdx = parts.getLaneRangeFromLane(lanes, bestLane)
              rangeBestLane = bestLane - rangeLeftIdx -- bestLane - rangeRightIdx

              laneLimLeft = (normalizedLaneLimLeft * 2 - 1) * radiusOrig
              laneLimRight = (normalizedLaneLimRight * 2 - 1) * radiusOrig
              latXnorm = (laneLimLeft + laneLimRight) * 0.5
            end
          end
        end
      end
    end

    appendInitialRoutePlanNodes(
      plan, posOrig, radiusOrig, normal, latXnorm, rangeLeft, rangeRight, rangeBestLane, laneLimLeft,
      laneLimRight, biNormal, wp, lanes, roadSpeedLimit
    )
  end

  local function extendRoutePlan(route, plan)
    local TRAFFIC_MIN_PLAN_LENGTH_M = 20
    local MIN_PLAN_LENGTH_M = 40
    local minPlanLen
    if ctx.M.mode == 'traffic' then
      minPlanLen = parts.getMinPlanLen(TRAFFIC_MIN_PLAN_LENGTH_M, ctx.ego.speed, 0.2 * ctx.ego.staticFrictionCoef) -- 0.25 * min(aggression, ego.staticFrictionCoef)
    else
      minPlanLen = parts.getMinPlanLen(MIN_PLAN_LENGTH_M)
    end

    while not plan[ctx.MIN_PLAN_COUNT] or (plan.planLen - (plan.egoXnormOnSeg or 0) * plan[1].length) < minPlanLen do -- TODO: (plan.planLen < minPlanLen and plan.stopSeg + 1 == plan.planCount)
      local n = parts.buildNextRoute(route)
      if not n then break end
      plan.planCount = plan.planCount + 1
      plan[plan.planCount] = n
      plan[plan.planCount-1].length = n.pos:distance(plan[plan.planCount-1].pos)
      plan.planLen = plan.planLen + plan[plan.planCount-1].length
    end
  end

  local function advanceRouteLaneChanges(route, plan)
    -- Calculate the length of the path at each path node one segment per call of planAhead
    if not route.pathLength[#route.path] then
      local n = #route.pathLength
      tableInsert(
        route.pathLength,
        ctx.aiState.mapData.positions[route.path[n+1]]:distance(ctx.aiState.mapData.positions[route.path[max(1, n)]]) + route.pathLength[n]
      )
    end

    -- check path node at lastLaneChangeIdx for a possible lane change
    if not (route.lastLaneChangeIdx < #route.path) then return end
    local wp1, wp2
    if route.lastLaneChangeIdx == 1 then
      wp2 = route.path[route.lastLaneChangeIdx]
      if plan[1].wp and (plan[1].wp ~= wp2) then
        wp1 = plan[1].wp
      else
        --wp1 not found: safeguard
        route.lastLaneChangeIdx = 2
        wp1, wp2 = route.path[route.lastLaneChangeIdx-1], route.path[route.lastLaneChangeIdx]
      end
    else
      wp1, wp2 = route.path[route.lastLaneChangeIdx-1], route.path[route.lastLaneChangeIdx]
    end
    if not (route.lastLaneChangeIdx < #route.path) then return end
    if parts.numOfLanesInDirection(parts.getEdgeLaneConfig(wp1, wp2), '+') > 1 then
      local minNode = parts.roadNaturalContinuation(wp1, wp2)
      local wp3 = route.path[route.lastLaneChangeIdx+1]
      if minNode and minNode ~= wp3 then -- road natural continuation at wp2 is not in our path
        local minNodePos, wp2Pos_2 = ctx.aiState.mapData:getEdgePositions(minNode, wp2)
        local minNodeEdgeVec = minNodePos - wp2Pos_2
        local wp1Pos, wp2Pos_1 = ctx.aiState.mapData:getEdgePositions(wp1, wp2)
        local wp1TOwp2EdgeVec = wp2Pos_1 - wp1Pos
        if minNodeEdgeVec:dot(wp1TOwp2EdgeVec) > 0 then -- road natural continuation is up to 90 deg
          local edgeNormal = ctx.gravityDir:cross(wp1TOwp2EdgeVec):normalized()
          local wp3Pos = ctx.aiState.mapData:getEdgePositions(wp3, wp2)
          local side = sign2(edgeNormal:dot(wp3Pos) - edgeNormal:dot(wp2Pos_1))
          tableInsert(route.laneChanges, {pathIdx = route.lastLaneChangeIdx, side = side, alternate = minNode})
        end
      end
    end
    route.lastLaneChangeIdx = route.lastLaneChangeIdx + 1
  end

  local function calculateRouteSpringForces(plan)
    -- calculate spring forces
    for i = 0, plan.planCount do
      if ctx.forces[i] then
        ctx.forces[i]:set(0, 0, 0)
      else
        ctx.forces[i] = vec3()
      end
    end

    for i = 1, plan.planCount-1 do
      local n1 = plan[i]
      local v1 = n1.dirVec
      local v2 = plan[i+1].dirVec

      n1.turnDir:setSub2(v1, v2); n1.turnDir:normalize()

      local forceCoef = (1-ctx.twt.state) * max(1 - v1:dot(v2), 0) * ctx.aiState.parameters.turnForceCoef

      ctx.forces[i-1]:setAddScaled(ctx.forces[i-1], n1.turnDir, -forceCoef)
      ctx.forces[i]:setAddScaled(ctx.forces[i], n1.turnDir, 2 * forceCoef)
      ctx.forces[i+1]:setAddScaled(ctx.forces[i+1], n1.turnDir, -forceCoef)
    end
  end

  local function collectRouteTraffic()
    -- other vehicle awareness --
    table.clear(ctx.traffic.objects)
    local trafficObjCount = 0
    local awarenessRadius = ctx.traffic.Rfl_fun(ctx.ego.speed)
    -- Populate traffic.objects with all the visible vehicles in the map
    for plID, mapObject in pairs(mapmgr.getObjects()) do
      if not (plID ~= objectId and (ctx.M.mode ~= 'chase' or plID ~= ctx.aiState.player.id or ctx.internalState.chaseData.playerState == 'stopped')) then goto nextTrafficVehicle end
      mapObject.targetType = (ctx.aiState.player and plID == ctx.aiState.player.id) and ctx.M.mode

      if ctx.opt.racing or ctx.opt.avoidCars == 'on' or mapObject.targetType == 'follow' then
        local trafficVehicle = ctx.traffic.cache[plID] or {} --initialize v from cache or create new
        trafficVehicle.active = mapObject.active
        trafficVehicle.damage = mapObject.damage
        trafficVehicle.dirVec = mapObject.dirVec
        trafficVehicle.dirVecUp = mapObject.dirVecUp
        trafficVehicle.id = mapObject.id
        trafficVehicle.licensePlate = mapObject.licensePlate
        trafficVehicle.name = mapObject.name
        trafficVehicle.objectCollisions = mapObject.objectCollisions
        trafficVehicle.pos = mapObject.pos
        trafficVehicle.states = mapObject.states
        trafficVehicle.vel = mapObject.vel
        trafficVehicle.view = mapObject.view
        trafficVehicle.targetType = mapObject.targetType
        ctx.traffic.cache[plID] = trafficVehicle

        trafficVehicle.length = obj:getObjectInitialLength(plID) + 0.3
        trafficVehicle.width = obj:getObjectInitialWidth(plID)

        trafficVehicle.posFront = trafficVehicle.posFront or vec3()
        trafficVehicle.posFront:set(obj:getObjectFrontPositionXYZ(plID))

        trafficVehicle.posRear = trafficVehicle.posRear or vec3()
        trafficVehicle.posRear:setAddScaled(trafficVehicle.posFront, trafficVehicle.dirVec, -trafficVehicle.length)

        trafficVehicle.posFront:setAddScaled(trafficVehicle.posFront, trafficVehicle.dirVec, 0.3)

        trafficVehicle.posMiddle = trafficVehicle.posMiddle or vec3()
        trafficVehicle.posMiddle:set(trafficVehicle.posFront)
        trafficVehicle.posMiddle:setAdd(trafficVehicle.posRear)
        trafficVehicle.posMiddle:setScaled(0.5)

        tableInsert(ctx.traffic.objects, trafficVehicle)
        trafficObjCount = trafficObjCount + 1
      end
      ::nextTrafficVehicle::
    end
    return trafficObjCount, awarenessRadius
  end

  local function projectSideTrafficClearance(plan, randomV, midPos, egoMidL, egoMidR)
    local vRightVec = getTmpVec3(ctx.ego)
    local dispLeft, dispRight = 0, 0
    -- add the new cached vehicles to the cache
    for id in pairs(ctx.traffic.newCachedV) do
      ctx.traffic.sideCache[id] = ctx.traffic.cache[id]
    end
    -- Add the random vehicle to the side-cache
    local randomNotInCache
    if randomV then
      randomNotInCache = ctx.traffic.sideCache[randomV.id] == nil
      ctx.traffic.sideCache[randomV.id] = randomV
    end
    for id, trafficVehicle in pairs(ctx.traffic.sideCache) do
      -- if the vehicle is not in the map or outside the cache radius, remove it from the cache
      if not mapmgr.objects[id] or trafficVehicle.posMiddle:squaredDistance(ctx.ego.pos) > 400 then
        ctx.traffic.sideCache[id] = nil
      else
        ctx.traffic.totalCachedVehicles = ctx.traffic.totalCachedVehicles + 1

        if ctx.ego.speed > 1 and trafficVehicle.vel:dot(ctx.ego.dirVec) > 0 and abs(trafficVehicle.posFront.z - ctx.ego.pos.z) < 4 then
          local xnorm = trafficVehicle.posFront:xnormOnLinePointVec(midPos, ctx.ego.dirVec)
          if xnorm > -ctx.ego.length and xnorm < ctx.ego.length then
            vRightVec:setCross(trafficVehicle.dirVec, trafficVehicle.dirVecUp)

            egoMidL:setAddScaled(midPos, ctx.ego.rightVec, - ctx.ego.width * 0.5)
            local xnorm1, xnorm2 = closestLinePointsPointVec(trafficVehicle.posFront, vRightVec, egoMidL,
              ctx.ego.dirVec)

            egoMidR:setAddScaled(midPos, ctx.ego.rightVec, ctx.ego.width * 0.5)
            local xnorm3, xnorm4 = closestLinePointsPointVec(trafficVehicle.posFront, vRightVec, egoMidR,
              ctx.ego.dirVec)

            local vHalfWidthAug = trafficVehicle.width * 0.5 + 0.1 -- augmented half width of the other vehicle

            if xnorm1 > 0 and xnorm1 < vHalfWidthAug and xnorm2 > -ctx.ego.length and xnorm2 < ctx.ego.length then -- the other vehicle is on our left side
              dispLeft = max(dispLeft, vHalfWidthAug - xnorm1)
            elseif xnorm3 < 0 and xnorm3 > -vHalfWidthAug and xnorm4 > -ctx.ego.length and xnorm4 < ctx.ego.length then -- the other vehicle is on our right side
              dispRight = max(dispRight, vHalfWidthAug + xnorm3)
            end
          end
        end
      end
    end

    if randomV and randomNotInCache and ctx.traffic.sideCache[randomV.id] ~= nil then
      ctx.traffic.newCachedVNext[randomV.id] = true
    end


    plan.sideDisp = nil
    return dispLeft, dispRight, randomNotInCache
  end

  local function applySideTrafficAvoidance(plan, randomV)
    -- Side avoidance
    local midPos = getTmpVec3(ctx.ego); midPos:setAddScaled(ctx.ego.pos, ctx.ego.dirVec, -0.5 * ctx.ego.length)
    local egoMidL, egoMidR = getTmpVec3(ctx.ego), getTmpVec3(ctx.ego)
    local dispLeft, dispRight, randomNotInCache = projectSideTrafficClearance(plan, randomV, midPos, egoMidL, egoMidR)
    if not (dispLeft > 0 or dispRight > 0) then return randomNotInCache end
    local sideDisp = dispLeft - dispRight -- (sideDisp > 0) means the other vehicle is on our left side and ego should move right
    sideDisp = min(ctx.aiState.dt * ctx.aiState.parameters.awarenessForceCoef * 10, abs(sideDisp)) * sign2(sideDisp) -- limited displacement per frame
    plan.sideDisp = true
    -- maybe needs some smoother to prevent left / right "bouncing"
    local curDist = 0
    local lastPlanIdx = 2
    local targetDist = square(ctx.ego.speed) / (2 * gravity * ctx.aiState.aggression) + max(30, ctx.ego.speed * 3) -- longer adjustment at higher speeds

    for i = 2, plan.planCount - 1 do
      parts.openLaneToLaneRange(plan[i])
      plan[i].lateralXnorm = clamp(plan[i].lateralXnorm + sideDisp * (targetDist - curDist) / targetDist, plan[i].laneLimLeft, plan[i].laneLimRight)
      plan[i].pos:setAddScaled(plan[i].posOrig, plan[i].normal, plan[i].lateralXnorm)
      curDist = curDist + plan[i - 1].length
      lastPlanIdx = i

      plan[i].vec:setSub2(plan[i-1].pos, plan[i].pos); plan[i].vec.z = 0
      plan[i].dirVec:setScaled2(plan[i].vec, 1 / plan[i].vec:lengthGuarded())
      if curDist > targetDist then break end
    end

    parts.updatePlanLen(plan, 2, lastPlanIdx + 1)
    return randomNotInCache
  end

  local function applyForwardTrafficSideForces(
    plan, PARKED_LANE_OPEN_DISTANCE_M, openPlanLanesIdx, distanceT, nDir, egoPathVel,
    inMultipleLanes, i, n1, n2, trafficVehicle, minSqDist
  )
    local velProjOnSeg = max(0, trafficVehicle.vel:dot(nDir))

    local vehicleIsStopped = parts.isVehicleStopped(trafficVehicle)

    if vehicleIsStopped then
      local distToParked = distanceT + n1.length
      if distToParked < PARKED_LANE_OPEN_DISTANCE_M then
        openPlanLanesIdx = max(openPlanLanesIdx, i)
      end
    end

    if plan.stopSeg == math.huge and trafficVehicle.targetType ~= 'follow' then -- apply side forces to avoid vehicles
      if inMultipleLanes or ctx.trafficStates.side.passMargin > 0 then -- calculate force coef only if the avoidance side matches the initial value
        local forceCoef = ctx.trafficStates.side.side *
          ctx.aiState.parameters.awarenessForceCoef *
          max(0, ctx.ego.speed - velProjOnSeg,
            -sign(nDir:dot(trafficVehicle.dirVec)) * ctx.trafficStates.side.cTimer) /
          ((1 + minSqDist) * (1 + distanceT * min(0.1, 1 / (2 * max(0, egoPathVel - trafficVehicle.vel:dot(nDir)) + 1e-30))))

        local side1 = sign(n1.normal:dot(trafficVehicle.posMiddle) - n1.normal:dot(n1.pos))
        ctx.forces[i]:setAddScaled(ctx.forces[i], n1.normal, -side1 * forceCoef)

        local side2 = sign(n2.normal:dot(trafficVehicle.posMiddle) - n2.normal:dot(n2.pos))
        ctx.forces[i+1]:setAddScaled(ctx.forces[i+1], n1.normal, -side2 * forceCoef) -- shouldn't this be n2.normal instead of n1.normal?
      end
    end
    return openPlanLanesIdx, velProjOnSeg, vehicleIsStopped
  end

  local function applyForwardTrafficSpeedLimits(
    plan, distanceT, nDir, ego2PlVec, i, n1, id, trafficVehicle, ego2PlDir, rnorm, minSqDist,
    egoPlWidth, velProjOnSeg, vehicleIsStopped
  )
    if minSqDist < square(egoPlWidth * 0.505) then -- average of ego vehicle width and target width

      -- pass margin calculation, to enable traffic passing on narrow roads
      local minPassLen = max(n1.roadSpeedLimit or 16.667, ctx.ego.speed) * 2
      if distanceT < minPassLen and velProjOnSeg < 1 and trafficVehicle.dirVec:dot(ctx.ego.dirVec) < 0 and n1.halfWidth < egoPlWidth * 0.55 then
        ctx.trafficStates.side.passLen = max(ctx.trafficStates.side.passLen, distanceT + trafficVehicle.length + minPassLen) -- accounts for space ahead and behind the target vehicle
      end

      if not vehicleIsStopped and ctx.trafficStates.side.passLen == 0 then
        ctx.traffic.collision[id] = true
      end

      plan.trafficMinProjSpeed = min(plan.trafficMinProjSpeed, velProjOnSeg)
      plan.trafficMinDir = min(plan.trafficMinDir, trafficVehicle.dirVec:dot(nDir))

      n1.trafficSqVel = min(n1.trafficSqVel, velProjOnSeg * velProjOnSeg)
    end

    -- sets a minimum speed if second plan node is blocked
    if i == 2 and minSqDist < square(egoPlWidth * 0.6) and (rnorm < 1) and ego2PlDir > 0 and trafficVehicle.vel:dot(ctx.ego.rightVec) * ego2PlVec:dot(ctx.ego.rightVec) < 0 and trafficVehicle.vel:squaredLength() > 0.01 then
      n1.trafficSqVel = max(0, min(n1.trafficSqVel, velProjOnSeg * velProjOnSeg) - (trafficVehicle.vel:dot(ctx.ego.dirVec) * ctx.ego.dirVec):squaredLength())
    end
  end

  local function applyForwardTrafficAvoidance(plan, trafficObjCount, awarenessRadius, randomVIndex, randomV, randomNotInCache)
    local LANE_WIDTH_M = 3.45
    local ARRIVAL_HORIZON_S = 5
    local CACHE_RADIUS_SQUARED_M2 = 400
    local HEIGHT_CLEARANCE_SQUARED_M2 = 16
    local PARKED_LANE_OPEN_DISTANCE_M = 25
    local openPlanLanesIdx = 0
    local distanceT = plan[1].length * (1 - (plan.egoXnormOnSeg or 0))
    local nDir = getTmpVec3(ctx.ego)
    nDir:setSub2(plan[2].pos, plan[1].pos); nDir:setScaled(1 / (plan[1].length + 1e-30))
    local egoPathVel = max(1e-30, ctx.ego.vel:dot(nDir))
    local egoPathVelInv = min(abs(egoPathVel) * 0.5, 1) / egoPathVel
    local inMultipleLanes = plan[2].laneLimRight - plan[2].laneLimLeft > LANE_WIDTH_M * 1.5 -- one and a half lanes
    local plPosFront = getTmpVec3(ctx.ego)
    local plPosRear = getTmpVec3(ctx.ego)
    local ego2PlVec = getTmpVec3(ctx.ego)
    local n1ext = getTmpVec3(ctx.ego)
    local n2ext = getTmpVec3(ctx.ego)
    local planClosest = getTmpVec3(ctx.ego)
    local vClosest = getTmpVec3(ctx.ego)
    table.clear(ctx.traffic.collision)

    for i = 2, plan.planCount-1 do
      if distanceT > awarenessRadius then -- stop checking for vehicles if we are out of awareness radius
        break
      end

      local n1, n2 = plan[i], plan[i+1]
      local arrivalTIn = min(distanceT * egoPathVelInv, ARRIVAL_HORIZON_S)  -- arrival time of the vehicle to the plan segment (clamped to 5 seconds)
      local arrivalTOut = min((distanceT + n1.length) * egoPathVelInv, ARRIVAL_HORIZON_S)
      local n1pos, n2pos = n1.pos, n2.pos
      nDir:setSub2(n2pos, n1pos); nDir:setScaled(1 / (n1.length + 1e-30))
      n1.trafficSqVel = math.huge

      -- add the new cached vehicles to the cache
      local segAwCache = n1.awCache
      for id in pairs(ctx.traffic.newCachedV) do
        segAwCache[id] = ctx.traffic.cache[id]
      end

      -- pick a different random vehicle for each segment
      randomVIndex = (randomVIndex) % trafficObjCount + 1
      randomV = ctx.traffic.objects[randomVIndex]

      -- check if the randomV is already in the cache and then add it to the cache
      randomNotInCache = nil
      if randomV then
        randomNotInCache = segAwCache[randomV.id] == nil
        segAwCache[randomV.id] = randomV
      end

      -- iterate over segment i cached vehicles
      for id, trafficVehicle in pairs(segAwCache) do
        ctx.traffic.totalCachedVehicles = ctx.traffic.totalCachedVehicles + 1

        if not mapmgr.objects[id] then -- if the vehicle is not in the map, remove it from the cache
          segAwCache[id] = nil
          ctx.traffic.totalCachedVehicles = ctx.traffic.totalCachedVehicles - 1
          goto continue
        elseif ctx.traffic.collision[id] then -- if the vehicle is colliding with a previous segment, maintain it in the cache but avoid checking it for collisions
          goto continue
        end

        plPosFront:set(trafficVehicle.posFront)
        plPosRear:set(trafficVehicle.posRear)
        ego2PlVec:setSub2(plPosFront, ctx.ego.pos)
        local ego2PlDir = ego2PlVec:dot(ctx.ego.dirVec)
        if ego2PlDir > 0 then
          local scalingProjection = 1 - abs(n2.dirVec:dot(trafficVehicle.dirVec))
          plPosRear:setAddScaled(plPosRear, trafficVehicle.vel, arrivalTIn * scalingProjection)
          plPosFront:setAddScaled(plPosFront, trafficVehicle.vel, arrivalTOut * scalingProjection)
        end

        local plWidth = trafficVehicle.width
        n1ext:set(n1pos)
        n2ext:setAddScaled(n2pos, nDir, 0.5 * max(ctx.ego.width, plWidth))
        local rnorm, vnorm = closestLineSegmentPoints(n1ext, n2ext, plPosFront, plPosRear)
        planClosest:setLinePointFromXnorm(n1ext, n2ext, rnorm)
        vClosest:setLinePointFromXnorm(plPosFront, plPosRear, vnorm)

        local minSqDist = planClosest:squaredDistance(vClosest)
        if minSqDist > CACHE_RADIUS_SQUARED_M2 then -- if the vehicle is too far from the plan segment, remove it from the cache
          segAwCache[id] = nil
          ctx.traffic.totalCachedVehicles = ctx.traffic.totalCachedVehicles - 1
          goto continue
        end

        local minSqDistZ = square(planClosest.z - vClosest.z)
        if not (minSqDistZ < HEIGHT_CLEARANCE_SQUARED_M2) then goto continue end
        plWidth = plWidth * abs(nDir:dot(trafficVehicle.dirVec))
        local limWidth = trafficVehicle.targetType == 'follow' and 2 * max(n1.radiusOrig, n2.radiusOrig) or plWidth
        local egoPlWidth = ctx.ego.width + limWidth
        -- reduce the distance by the z-distance squared to avoid make awereness resilient to navigraph adhesion errors
        minSqDist = minSqDist - minSqDistZ
        if not (minSqDist < square(egoPlWidth * 0.8)) then goto continue end
        local velProjOnSeg, vehicleIsStopped
        openPlanLanesIdx, velProjOnSeg, vehicleIsStopped = applyForwardTrafficSideForces(
          plan, PARKED_LANE_OPEN_DISTANCE_M, openPlanLanesIdx, distanceT, nDir, egoPathVel,
          inMultipleLanes, i, n1, n2, trafficVehicle, minSqDist
        )

        if not (ctx.M.mode ~= 'flee' and ctx.M.mode ~= 'random') then goto continue end
        applyForwardTrafficSpeedLimits(
          plan, distanceT, nDir, ego2PlVec, i, n1, id, trafficVehicle, ego2PlDir, rnorm, minSqDist,
          egoPlWidth, velProjOnSeg, vehicleIsStopped
        )

        ::continue::
      end

      if randomV and randomNotInCache and segAwCache[randomV.id] ~= nil then
        ctx.traffic.newCachedVNext[randomV.id] = true
      end

      distanceT = distanceT + n1.length
    end
    return openPlanLanesIdx
  end

  local function applyRouteTrafficAvoidance(plan, trafficObjCount, awarenessRadius)
    plan.trafficMinProjSpeed = math.huge
    plan.trafficMinDir = 1
    local openPlanLanesIdx = 0
    if not (ctx.traffic.totalCachedVehicles > 0 or trafficObjCount > 0) then return end
    ctx.traffic.totalCachedVehicles = 0
    ctx.traffic.newCachedV, ctx.traffic.newCachedVNext = ctx.traffic.newCachedVNext, ctx.traffic.newCachedV
    table.clear(ctx.traffic.newCachedVNext)
    -- Pick a random vehicle to add to the cache
    local randomVIndex = min(floor(linearScale(ctx.traffic.blueNoiseRR, 0, 1, 1, trafficObjCount + 1)),
      trafficObjCount)
    ctx.traffic.blueNoiseRR = getBlueNoise1d(ctx.traffic.blueNoiseRR)
    local randomV = ctx.traffic.objects[randomVIndex]

    local randomNotInCache = applySideTrafficAvoidance(plan, randomV)

    openPlanLanesIdx = applyForwardTrafficAvoidance(plan, trafficObjCount, awarenessRadius, randomVIndex, randomV, randomNotInCache)

    ctx.trafficStates.block.block = max(plan.trafficMinProjSpeed, ctx.ego.speed * ctx.ego.speed) < 1 and (plan.trafficMinDir < -0.7 or ctx.trafficStates.intersection.block)
    plan[1].trafficSqVel = plan[2].trafficSqVel

    if openPlanLanesIdx > 0 and plan[openPlanLanesIdx].length < ctx.ego.length * 1.5 then openPlanLanesIdx = openPlanLanesIdx + 1 end

    parts.openPlanLanesToLaneRange(plan, openPlanLanesIdx)
  end

  local function applyCommittedLaneChangeForces(plan, lastNodeLatXnorm, exitNodeIdx, distToExit, side)
    local planExitIdx = plan.planCount
    if plan[plan.planCount].pathidx >= exitNodeIdx then -- if last plan node is at or past the path exit node
      planExitIdx = 1
      for i = plan.planCount, 3, -1 do
        if plan[i].pathidx == exitNodeIdx then -- if this plan node is at the exit node
          if i == plan.planCount then -- if it is also the last plan node
            lastNodeLatXnorm = nil
          end
          planExitIdx = i
          break
        end
      end
    else
      lastNodeLatXnorm = nil
    end

    -- Add lane change forces to all nodes up to the exit node
    local planDist = 0
    local sideForceCoeff = 2.5 * side * ctx.aiState.dt / distToExit
    for i = 3, planExitIdx do
      planDist = planDist + plan[i-1].length
      local n = plan[i]
      local roadHalfWidth = n.halfWidth
      local laneHalfWidth = roadHalfWidth * (n.rangeRight - n.rangeLeft) / n.rangeLaneCount
      if side < 0 then
        n.laneLimLeft = (2 * n.rangeLeft - 1) * roadHalfWidth -- open left lane limit to left range limit
        n.laneLimRight = max(n.laneLimLeft + ctx.ego.width, min(n.laneLimRight, n.lateralXnorm + laneHalfWidth))
        ctx.forces[i]:setAddScaled(ctx.forces[i], n.normal, planDist * sideForceCoeff * square(min(1, 0.25 * abs(n.lateralXnorm - n.laneLimLeft))))
      else
        n.laneLimRight = (2 * n.rangeRight - 1) * roadHalfWidth -- open right lane limit to right range limit
        n.laneLimLeft = min(n.laneLimRight - ctx.ego.width, max(n.laneLimLeft, n.lateralXnorm - laneHalfWidth))
        ctx.forces[i]:setAddScaled(ctx.forces[i], n.normal, planDist * sideForceCoeff * square(min(1, 0.25 * abs(n.laneLimRight - n.lateralXnorm))))
      end
    end
    for i = planExitIdx + 1, plan.planCount do
      planDist = max(0, planDist - plan[i-1].length)
      if planDist == 0 then break end
      local n = plan[i]
      if side < 0 then
        ctx.forces[i]:setAddScaled(ctx.forces[i], n.normal, planDist * sideForceCoeff * square(min(1, 0.25 * abs(n.lateralXnorm - n.laneLimLeft))))
      else
        ctx.forces[i]:setAddScaled(ctx.forces[i], n.normal, planDist * sideForceCoeff * square(min(1, 0.25 * abs(n.laneLimRight - n.lateralXnorm))))
      end
    end
    parts.updatePlanBestRange(plan)
    return lastNodeLatXnorm
  end

  local function applyRouteLaneChange(route, plan)
    -- remove lane change if vehicle has gone past it
    while route.laneChanges[1] and plan[2].pathidx > route.laneChanges[1].pathIdx do
      electrics.stop_turn_signal()
      tableRemove(route.laneChanges, 1)
    end

    local skipLast = 1
    local lastNodeLatXnorm, lastNodeLimLeft, lastNodeLimRight

    if not (route.laneChanges[1] and floor(plan[2].rangeLaneCount + 0.5) > 1 and route.laneChanges[1].side ~= 0) then return skipLast, lastNodeLatXnorm, lastNodeLimLeft, lastNodeLimRight end
    local exitNodeIdx = route.laneChanges[1].pathIdx
    local distToExit
    if plan[plan.planCount].pathidx > exitNodeIdx then
      distToExit = plan.planLen - plan[1].length * plan.egoXnormOnSeg
      for i = plan.planCount, 2, -1 do
        if plan[i].pathidx == exitNodeIdx then
          break
        else
          distToExit = distToExit - plan[i-1].length
        end
      end
    else
      distToExit = plan.planLen + max(0, route.pathLength[route.laneChanges[1].pathIdx] - route.pathLength[plan[plan.planCount].pathidx])
    end
    if not ((distToExit < min(600, max(15, ctx.ego.speed * ctx.ego.speed * 0.7))) or route.laneChanges[1].commit) then return skipLast, lastNodeLatXnorm, lastNodeLimLeft, lastNodeLimRight end
    route.laneChanges[1].commit = true
    local side = route.laneChanges[1].side
    local blocked = false
    if ctx.M.mode == 'traffic' then
      for _, trafficVehicle in pairs(ctx.traffic.sideCache) do
        if not (trafficVehicle.dirVec:dot(ctx.ego.dirVec) > 0.7) then goto nextLaneChangeVehicle end
        local longXnorm = trafficVehicle.posFront:xnormOnLinePointVec(ctx.ego.pos, ctx.ego.dirVec)
        if longXnorm > -1.2 * ctx.ego.length and longXnorm < 1.5 * (ctx.ego.length + trafficVehicle.length) then
          local latXnorm = trafficVehicle.posFront:xnormOnLinePointVec(ctx.ego.pos, ctx.ego.rightVec)
          if latXnorm > side * ctx.ego.width and latXnorm < 2.5 * side * ctx.ego.width then
            blocked = distToExit < 100
          end
        end
        ::nextLaneChangeVehicle::
      end
    end
    -- if the exit is not blocked, do a lane change
    if not blocked then
      if side < 0 then
        if (electrics.values.turnsignal or -1) >= 0 then electrics.toggle_left_signal() end
      else
        if (electrics.values.turnsignal or 1) <= 0 then electrics.toggle_right_signal() end
      end

      skipLast = 0

      lastNodeLatXnorm = plan[plan.planCount].lateralXnorm
      lastNodeLimLeft = plan[plan.planCount].laneLimLeft
      lastNodeLimRight = plan[plan.planCount].laneLimRight

      lastNodeLatXnorm = applyCommittedLaneChangeForces(plan, lastNodeLatXnorm, exitNodeIdx, distToExit, side)
    else -- if the exit is blocked, avoid lane change by changing path & plan
      electrics.stop_turn_signal()
      ----------- Save the new path in trafficPathState for the next pathfinding -------------
      table.clear(ctx.aiState.trafficPathState)
      for i = plan[2].pathidx, exitNodeIdx do
        tableInsert(ctx.aiState.trafficPathState, route.path[i])
      end
      tableInsert(ctx.aiState.trafficPathState, route.laneChanges[1].alternate)
      -- Set the aborting flag to true to prevent the next pathfinding from randomly selecting the same path
      ctx.aiState.trafficPathState.aborting = true
      -- Reset the current route to nil and return
      ctx.aiState.currentRoute = nil
      return nil, nil, nil, nil, true

    end
    return skipLast, lastNodeLatXnorm, lastNodeLimLeft, lastNodeLimRight
  end

  local function integrateRouteSpringForces(plan, skipLast, lastNodeLatXnorm, lastNodeLimLeft, lastNodeLimRight)
    local roadWidthMargin = ctx.ego.width * 0.5
    local laneWidthMargin = ctx.ego.width * 0.4
    local forceMagLim = ctx.aiState.parameters.springForceIntegratorDispLim
    local passMargin = ctx.trafficStates.side.passMargin * (mapmgr.rules.rightHandDrive and -1 or 1) -- road side pass margin
    for i = 2, plan.planCount-skipLast do
      local n = plan[i]
      local roadHalfWidth = n.halfWidth

      -- Apply a force towards the center of the lane when driving in lane
      local forceToLaneCenter = 0
      if ctx.opt.driveInLaneFlag and not n.lanesOpen then
        local rangeLeft = (2 * n.rangeLeft - 1) * roadHalfWidth
        local rangeRight = (2 * n.rangeRight - 1) * roadHalfWidth
        local laneLimHalfSpan = 0.5 * (n.laneLimRight - n.laneLimLeft) + 1e-30
        local dispToLeftRange = min(1, max(0, laneLimHalfSpan - (n.lateralXnorm - rangeLeft)) / laneLimHalfSpan)
        local dispToRightRange = min(1, max(0,
          laneLimHalfSpan - (rangeRight - n.lateralXnorm)) / laneLimHalfSpan)
        forceToLaneCenter = 0.15 * (dispToLeftRange - dispToRightRange)
      end

      -- Calculate node displacement: avoids switching displacement direction (sign) in concecutive frames
      local displacement = forceToLaneCenter + max(min(n.normal:dot(ctx.forces[i]), forceMagLim), -forceMagLim)
      displacement = displacement * max(min((displacement * n.dispDir) * math.huge, 1), 0) -- second term returns 0 if (displacement * n.dispDir) is negative, 1 otherwise.
      n.dispDir = sign(displacement)

      local roadLimRight = max(0, roadHalfWidth - roadWidthMargin) -- should be non-negative (zero or positive)
      local limLow = max(n.laneLimLeft + laneWidthMargin, -roadLimRight) + min(0, passMargin)
      local limHigh = min(n.laneLimRight - laneWidthMargin, roadLimRight) + max(0, passMargin)
      local limAvg = (limLow + limHigh) * 0.5 -- guard against clamp limit crossing

      local newLateralXnorm = clamp(n.lateralXnorm + displacement, min(limLow, limAvg), max(limHigh, limAvg))

      n.pos:setAddScaled(n.pos, n.normal, newLateralXnorm - n.lateralXnorm) -- remember that posOrig and pos are not alligned along the normal
      n.vec:setSub2(plan[i-1].pos, n.pos); n.vec.z = 0
      n.dirVec:setScaled2(n.vec, 1 / n.vec:lengthGuarded())

      n.lateralXnorm = newLateralXnorm
    end

    if lastNodeLatXnorm then
      local roadHalfWidth = plan[plan.planCount].halfWidth
      local rangeLeft, rangeRight = (2 * plan[plan.planCount].rangeLeft - 1) * roadHalfWidth, (2 * plan[plan.planCount].rangeRight - 1) * roadHalfWidth
      local latXnorm = clamp(plan[plan.planCount].lateralXnorm, rangeLeft, rangeRight)
      local disp = latXnorm - lastNodeLatXnorm
      plan[plan.planCount].laneLimLeft = max(rangeLeft, min(latXnorm, lastNodeLimLeft + disp))
      plan[plan.planCount].laneLimRight = min(rangeRight, max(latXnorm, lastNodeLimRight + disp))
    end

    parts.updatePlanLen(plan, 2, plan.planCount)
  end

  local function smoothRoutePlanError(plan)
    -- smoothly distribute error from planline onto the front segments
    if not (ctx.aiState.parameters.planErrorSmoothing and plan.targetPos and plan.targetSeg and plan.planCount > plan.targetSeg and ctx.twt.state == 0) then return end
    local dTotal = 0
    local sumLen = 0
    for i = 2, plan.targetSeg - 1  do
      dTotal = dTotal + plan[i].length
    end
    sumLen = dTotal
    dTotal = max(1, dTotal + plan.targetPos:distance(plan[plan.targetSeg].pos))

    local p1, p2 = plan[1].pos, plan[2].pos
    local dispVec = getTmpVec3(ctx.ego)
    dispVec:setLinePointFromXnorm(p1, p2, ctx.ego.pos:xnormOnLine(p1, p2))
    dispVec:setSub(ctx.ego.pos); dispVec:setScaled(-0.5 * ctx.aiState.dt)
    -- TODO: check if deviation is large enough to trigger error smoother
    local tmpVec = getTmpVec3(ctx.ego)
    tmpVec:setSub2(p2, p1); tmpVec:setCross(tmpVec, ctx.ego.upVec); tmpVec:normalize()
    plan.egoDeviation = dispVec:dot(tmpVec)

    local invdTotal = 1 / dTotal
    for i = plan.targetSeg - 1, 1, -1 do
      local n = plan[i]
      sumLen = max(0, sumLen - plan[i].length)
      dispVec:setScaled2(dispVec, (dTotal - sumLen) * invdTotal)

      dispVec:setAddScaled(dispVec, n.biNormal, -dispVec:dot(n.biNormal))
      n.pos:setAdd(dispVec)

      local halfWidth = n.halfWidth
      n.lateralXnorm = clamp(n.pos:xnormOnLinePointVec(n.posOrig, n.normal), -halfWidth, halfWidth)

      plan[i+1].vec:setSub2(plan[i].pos, plan[i+1].pos); plan[i+1].vec.z = 0
      plan[i+1].dirVec:setScaled2(plan[i+1].vec, 1 / plan[i+1].vec:lengthGuarded())
    end

    parts.updatePlanLen(plan, 1, plan.targetSeg-1)
  end

  local function calculateRouteCurvature(plan)
    -- calculate node horizontal curvature
    local len, n3vec = 0, getTmpVec3(ctx.ego)
    plan[1].curvature = plan[1].curvature or parts.inCurvature(plan[1].vec, plan[2].vec)
    for i = 2, plan.planCount - 1 do
      local n1, n2 = plan[i], plan[i+1]

      n3vec:setSub2(n1.pos, plan[min(plan.planCount, i+2)].pos); n3vec.z = 0

      local c1 = parts.inCurvature(n1.vec, n2.vec)
      local c2 = parts.inCurvature(n1.vec, n3vec)

      local curvature
      if c1 <= c2 then
        curvature = sign2(n1.turnDir:dot(n1.normal)) * c1
      else
        curvature = sign2((n1.vec):dot(n1.normal) - n3vec:dot(n1.normal)) * c2
      end

      -- calculate curvature temporal smoothing parameter as a function of the trajectory length distance
      local curvatureRateDt = min(5 + 0.005 * len * len, 100) * ctx.aiState.dt
      n1.curvature = n1.curvature + (curvature - n1.curvature) * curvatureRateDt / (1 + curvatureRateDt)

      len = len + n1.length
    end

    -- calculate node vertical curvature
    len = 0
    local v1z, v2z, v3z = getTmpVec3(ctx.ego), getTmpVec3(ctx.ego), getTmpVec3(ctx.ego)
    for i = 2, plan.planCount - 1 do
      local n1, n2 = plan[i], plan[i+1]

      v1z:set(plan[i-1].length, 0, n1.posOrig.z - plan[i-1].posOrig.z)
      v2z:set(n1.length, 0, n2.posOrig.z - n1.posOrig.z)
      v3z:set(n1.length + (n2.length or 0), 0, plan[min(plan.planCount, i + 2)].posOrig.z - n1.posOrig.z)

      local curvatureZ = min(parts.inCurvature(v1z, v2z), parts.inCurvature(v1z, v3z))

      -- calculate curvature temporal smoothing parameter (fast reacting, time dependent)
      local curvatureRateDt = min(25 + 0.000045 * len * len * len * len, 1000) * ctx.aiState.dt
      n1.curvatureZ = curvatureZ + (curvatureRateDt / (1 + curvatureRateDt)) * (n1.curvatureZ - curvatureZ)

      len = len + n1.length
    end
  end

  local function planRouteSpeeds(route, plan)
    local SPEED_HORIZON_M = 550
    -- Speed Planning --
    local totalAccel = min(ctx.aiState.aggression,
      ctx.ego.staticFrictionCoef) * gravity * ctx.aiState.raceCommit.plannerAccelMult()

    local lastNode = plan[plan.planCount]
    if route.path[lastNode.pathidx+1] or (ctx.routeLoop.loopPath and ctx.routeLoop.noOfLaps
      and ctx.routeLoop.noOfLaps > 1) then
      if plan.stopSeg <= plan.planCount then
        lastNode.speed = 0
      else
        lastNode.speed = lastNode.manSpeed or sqrt(2 * SPEED_HORIZON_M * totalAccel) -- shouldn't this be calculated based on the path length remaining?
      end
    else
      lastNode.speed = lastNode.manSpeed or 0
    end
    if ctx.M.speedMode == 'legal' then
      lastNode.speed = min(lastNode.roadSpeedLimit or math.huge, lastNode.speed)
    end
    -- Use Backward or Forward + Backward algorithm
    local gravityAlongRoad = getTmpVec3(ctx.ego)
    if ctx.aiState.speedProfileMode then
      for i = 1, plan.planCount-1 do -- curvature is not defined on the last plan node
        local n1, n2 = plan[i], plan[i+1]
        -- consider inclination
        gravityAlongRoad:setSub2(n2.pos, n1.pos); gravityAlongRoad:setScaled(ctx.gravityDir:dot(gravityAlongRoad) / max(square(n1.length), 1e-30)) -- gravity vec parallel to road segment: positive when downhill
        local gravityNormal = ctx.gravityDir:distance(gravityAlongRoad) -- gravity component normal to road segment
        n1.acc_max = totalAccel * gravityNormal
        n1.speed = min(n1.acc_max / max(abs(n1.curvature), 1e-30), gravityNormal * gravity / max(n1.curvatureZ, 1e-30)) -- available centripetal acceleration * radius
      end
      plan[plan.planCount].acc_max = plan[plan.planCount-1].acc_max

      if ctx.aiState.speedProfileMode == 'ForwBack' then
        parts.solveForwardSpeedProfile(plan)
      end

      parts.solveBackwardSpeedProfile(plan)
    else -- Use standard algotihm with curvature
      for i = plan.planCount-1, 1, -1 do
        local n1, n2 = plan[i], plan[i+1]

        -- consider inclination
        gravityAlongRoad:setSub2(n2.pos, n1.pos); gravityAlongRoad:setScaled(ctx.gravityDir:dot(gravityAlongRoad) / max(square(n1.length), 1e-30)) -- gravity vec parallel to road segment: positive when downhill
        local gravityNormal = ctx.gravityDir:distance(gravityAlongRoad) -- gravity component normal to road segment

        local curvature = max(abs(n1.curvature), 1e-5)
        local turnSpeedSq = totalAccel * gravityNormal / curvature -- available centripetal acceleration * radius

        local n1SpeedSq
        if plan.stopSeg <= i then
          n1SpeedSq = 0
        -- Traffic and trajectory geometry both constrain speed; https://physics.stackexchange.com/questions/312569/
        else -- speed limit imposed by other traffic vehicles and speed limit imposed by trajectory geometry (curvature and path length)
          -- https://physics.stackexchange.com/questions/312569/non-uniform-circular-motion-velocity-optimization
          n1SpeedSq = min(n1.trafficSqVel, turnSpeedSq * sin(min(asin(min(1, square(n2.speed) / turnSpeedSq)) + 2 * curvature * n1.length, pi * 0.5)))
        end

        n1.speed = n1.manSpeed or
                    (ctx.M.speedMode == 'limit' and ctx.M.routeSpeed and min(ctx.M.routeSpeed,
                      sqrt(n1SpeedSq))) or
                    (ctx.M.speedMode == 'set' and ctx.M.routeSpeed) or
                    (ctx.M.speedMode == 'legal' and min(n1.roadSpeedLimit or math.huge, sqrt(n1SpeedSq))) or
                    sqrt(n1SpeedSq)


        n1.trafficSqVel = math.huge
      end
    end

    plan.targetSpeed = ctx.aiState.raceCommit.smoothPlanTargetSpeed(plan[1].speed + max(0, plan.egoXnormOnSeg) * (plan[2].speed - plan[1].speed), ctx.aiState.dt)
    plan.targetAcc = nil
  end

  local function planAhead(route, baseRoute)
    if not route then return end

    if not route.path then
      route = parts.createNewRoute(route)
    end

    local plan = route.plan

    mergeBaseRoutePlan(route, plan, baseRoute)

    initializeRoutePlan(route, plan)

    extendRoutePlan(route, plan)

    if not plan[2] then return end
    if not plan[1].pathidx then
      plan[1].pathidx = plan[2].pathidx
      plan[1].roadSpeedLimit = plan[2].roadSpeedLimit
    end

    advanceRouteLaneChanges(route, plan)

    parts.densifyPlan(plan, route.path)

    if plan.targetSeg == nil then
      parts.calculateTarget(plan)
    end

    calculateRouteSpringForces(plan)

    local trafficObjCount, awarenessRadius = collectRouteTraffic()

    applyRouteTrafficAvoidance(plan, trafficObjCount, awarenessRadius)

    local skipLast, lastNodeLatXnorm, lastNodeLimLeft, lastNodeLimRight, aborted = applyRouteLaneChange(route, plan)
    if aborted then return end

    integrateRouteSpringForces(plan, skipLast, lastNodeLatXnorm, lastNodeLimLeft, lastNodeLimRight)

    smoothRoutePlanError(plan)

    -- TODO: This error smoother looks to behave better for race driving. It could replace the above.

    parts.calculateTarget(plan)

    calculateRouteCurvature(plan)

    planRouteSpeeds(route, plan)
    -- TODO: WIP

    return route
  end

  return {
    planAhead = planAhead,
  }
end

return lib
