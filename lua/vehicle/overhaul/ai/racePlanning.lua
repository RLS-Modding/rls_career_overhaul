-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this file,
-- You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding

-- Competitive route planning and overtaking alternatives.
-- create binds this extension instance; require caches only the factory.

-- Map, in reading order:
--   plan setup: mergeBaseRacePlan, initializeRacePlan, extendRacePlan, advanceRacePlanTarget
--   traffic and side avoidance: collectRaceTraffic, applyRaceSideAvoidance
--   spring forces and corner lines: calculateRaceSpringForces, integrateRaceSpringForces, liftRaceCornerLines
--   curvature and speed: calculateRaceCurvature, planRaceGeometrySpeed, mergeRaceTrafficSpeed
--   planRaceRouteAhead is the only export

local lib = {}

function lib.create(ctx)
  -- Locals for speed: this file runs every AI frame.
  local max, min, abs, sqrt = math.max, math.min, math.abs, math.sqrt
  local tableInsert = ctx.tableInsert
  local square, getTmpVec3 = ctx.square, ctx.getTmpVec3
  local gravity = ctx.g
  -- Functions from the other AI parts that this part calls, read from ctx once when it is created.
  local parts = {
    calculateTarget = ctx.calculateTarget,
    updatePlanLen = ctx.updatePlanLen,
    openLaneToLaneRange = ctx.openLaneToLaneRange,
    numOfLanesInDirection = ctx.numOfLanesInDirection,
    getEdgeLaneConfig = ctx.getEdgeLaneConfig,
    laneRange = ctx.laneRange,
    getLaneRangeFromLane = ctx.getLaneRangeFromLane,
    getBestLane = ctx.getBestLane,
    buildNextRoute = ctx.buildNextRoute,
    mergePathPrefix = ctx.mergePathPrefix,
    uniformPlanErrorDistribution = ctx.uniformPlanErrorDistribution,
    createNewRoute = ctx.createNewRoute,
    inCurvature = ctx.inCurvature,
    solveForwardSpeedProfile = ctx.solveForwardSpeedProfile,
    solveBackwardSpeedProfile = ctx.solveBackwardSpeedProfile,
    calculateTrafficTargetSpeed = ctx.calculateTrafficTargetSpeed,
    copyNode = ctx.copyNode,
    updateLateralAvoidance = ctx.updateLateralAvoidance,
    densifyPlan = ctx.densifyPlan,
  }

  local function mergeBaseRacePlan(route, plan, baseRoute)
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

  local function appendInitialRacePlanNodes(
    plan, posOrig, radiusOrig, normal, latXnorm, rangeLeft, rangeRight, rangeBestLane, laneLimLeft,
    laneLimRight, biNormal, wp, lanes, roadSpeedLimit
  )
    local rangeLaneCount = lanes and parts.numOfLanesInDirection(lanes, "+") or 1 -- numOfLanesFromRadius(radiusOrig)
    local vec = vec3(-8 * ctx.ego.dirVec.x, -8 * ctx.ego.dirVec.y, 0)

    plan[1] = {
      posOrig = posOrig,
      pos = vec3(ctx.ego.pos),
      vec = vec,
      dirVec = vec:normalized(),
      turnDir = vec3(0,0,0),
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

  local function initializeRacePlan(route, plan)
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
        local xnorm, sqDist = ctx.ego.pos:xnormSquaredDistanceToLineSegment(pos2, pos1)
        local rad1, rad2 = ctx.aiState.mapData:getEdgeRadii(wp1, wp2)
        local rad = lerp(rad2, rad1, xnorm)
        if xnorm >= 0 and xnorm <= 1 and sqDist <= square(2 * rad) then
          posOrig = linePointFromXnorm(pos2, pos1, xnorm)
          normal:setCross(biNormal, pos1 - pos2); normal:normalize()
          radiusOrig = rad
          wp = wp2
          roadSpeedLimit = ctx.aiState.mapData.graph[wp1][wp2].speedLimit
          latXnorm = ctx.ego.pos:xnormOnLinePointVec(posOrig, normal)
          laneLimLeft = -rad
          laneLimRight = rad
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

    appendInitialRacePlanNodes(
      plan, posOrig, radiusOrig, normal, latXnorm, rangeLeft, rangeRight, rangeBestLane, laneLimLeft,
      laneLimRight, biNormal, wp, lanes, roadSpeedLimit
    )
  end

  local function extendRacePlan(route, plan, pmode)
    local STOPPING_ACCEL_G = 0.2
    local MIN_PLAN_LENGTH_M = 30
    local MAX_PLAN_LENGTH_M = 300
    -- estimate of the stopping distance assuming 0.2 g longitudinal acceleration
    local minPlanLen = clamp(0.5 * ctx.ego.speed * ctx.ego.speed / (STOPPING_ACCEL_G * gravity), MIN_PLAN_LENGTH_M, MAX_PLAN_LENGTH_M)

    if pmode then return end
    while not plan[ctx.MIN_PLAN_COUNT] or (plan.planLen - plan.egoXnormOnSeg * plan[1].length) < minPlanLen do -- TODO: (plan.planLen < minPlanLen and plan.stopSeg + 1 == plan.planCount)
      local n = parts.buildNextRoute(route)
      if not n then break end
      plan.planCount = plan.planCount + 1
      plan[plan.planCount] = n
      plan[plan.planCount-1].length = n.pos:distance(plan[plan.planCount-1].pos)
      plan.planLen = plan.planLen + plan[plan.planCount-1].length
      if route.planL and plan.buildN then -- if left plan exists add last new point to it
        local planL = route.planL
        planL.planCount = planL.planCount + 1
        planL[planL.planCount] = parts.copyNode(n)
        planL[planL.planCount].lateralXnorm = planL[planL.planCount].lateralXnorm + (planL.offset or 0)
        planL[planL.planCount].pos:setAddScaled(planL[planL.planCount].posOrig, planL[planL.planCount].normal, planL[planL.planCount].lateralXnorm)
        planL[planL.planCount].vec:setSub2(planL[planL.planCount-1].pos, planL[planL.planCount].pos); planL[planL.planCount].vec.z = 0
        planL[planL.planCount-1].length = planL[planL.planCount].pos:distance(planL[planL.planCount-1].pos)
        planL.planLen = planL.planLen + planL[planL.planCount-1].length
      end
      if not (route.planR and plan.buildN) then goto nextRacePlanNode end
      local planR = route.planR
      planR.planCount = planR.planCount + 1
      planR[planR.planCount] = parts.copyNode(n)
      planR[planR.planCount].lateralXnorm = planR[planR.planCount].lateralXnorm + (planR.offset or 0)
      planR[planR.planCount].pos:setAddScaled(planR[planR.planCount].posOrig, planR[planR.planCount].normal, planR[planR.planCount].lateralXnorm)
      planR[planR.planCount].vec:setSub2(planR[planR.planCount-1].pos, planR[planR.planCount].pos); planR[planR.planCount].vec.z = 0
      planR[planR.planCount-1].length = planR[planR.planCount].pos:distance(planR[planR.planCount-1].pos)
      planR.planLen = planR.planLen + planR[planR.planCount-1].length
      ::nextRacePlanNode::
    end
  end

  local function advanceRacePlanTarget(route, plan, pmode)
    -- Calculate the length of the path at each path node one segment per call of planAhead (only for main plan)
    if not route.pathLength[#route.path] and not pmode then
      local n = #route.pathLength
      route.pathLength[n+1] = ctx.aiState.mapData.positions[route.path[n+1]]:distance(ctx.aiState.mapData.positions[route.path[max(1, n)]]) + route.pathLength[n]
    end

    parts.densifyPlan(plan, route.path)

    if not (plan.targetSeg == nil) then return end
    parts.calculateTarget(plan)
  end

  local function collectRaceTraffic(plan)
    ----#### Populate Traffic Table ####----
    -- Racing: always consider other vehicles; clearance scale (aggression) makes avoidance variable. No binary avoidCars for racing.
    plan.clearanceScale = nil
    if ctx.opt.racing then
      local cmin = (type(ctx.aiState.parameters.raceClearanceScaleMin) == 'number' and ctx.aiState.parameters.raceClearanceScaleMin) or 0.5
      cmin = clamp(cmin, 0.22, 0.95)
      plan.clearanceScale = min(max(1 - 0.5 * ctx.aiState.aggression, cmin), 1)
    end
    table.clear(ctx.traffic.objects)
    -- Populate traffic.objects with all the visible vehicles in the map
    for plID, mapObject in pairs(mapmgr.getObjects()) do
      if not (plID ~= objectId and (ctx.M.mode ~= 'chase' or plID ~= ctx.aiState.player.id or ctx.internalState.chaseData.playerState == 'stopped')) then goto nextRaceTrafficVehicle end
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

        if ctx.opt.racing and plan.clearanceScale then
          trafficVehicle.effectiveLength = trafficVehicle.length * plan.clearanceScale
          trafficVehicle.effectiveWidth = trafficVehicle.width * plan.clearanceScale
        else
          trafficVehicle.effectiveLength = nil
          trafficVehicle.effectiveWidth = nil
        end

        tableInsert(ctx.traffic.objects, trafficVehicle)
      end
      ::nextRaceTrafficVehicle::
    end
    plan.trafficMinProjSpeed = math.huge
    plan.trafficMinDir = 1
  end

  local function applyRaceSideAvoidance(plan, pmode)
    ----#### Side avoidance pt. 1####----
    plan.sideDisp = nil
    if not pmode then
      -- Limited lateral displacement lets touching race vehicles separate.
      parts.updateLateralAvoidance(plan) -- compute displacement
      -- apply limited displacement by modifying the current plan (useful to avoid cars being stuck side by side when touching)
      if plan.dispLat ~= 0 then
        plan.sideDisp = true
        local sideDisp = plan.dispLat -- (sideDisp > 0) means the other vehicle is on our left side and ego should move right
        local awarenessCoef = ctx.aiState.parameters.awarenessForceCoef * (ctx.opt.racing and (type(ctx.aiState.parameters.raceAwarenessCoefScale) == 'number' and ctx.aiState.parameters.raceAwarenessCoefScale or 1.0) or 1)
        sideDisp = min(ctx.aiState.dt * awarenessCoef * 10, abs(sideDisp)) * sign2(sideDisp) -- limited displacement per frame
        if ctx.opt.racing and plan.clearanceScale then
          sideDisp = sideDisp * plan.clearanceScale
        end
        local curDist = 0
        local lastPlanIdx = 2
        local targetDist = square(ctx.ego.speed) / (2 * gravity * ctx.aiState.aggression) + max(30, ctx.ego.speed * 3) -- longer adjustment at higher speeds
        for i = 2, plan.planCount - 1 do
          parts.openLaneToLaneRange(plan[i])
          plan[i].lateralXnorm = clamp(plan[i].lateralXnorm + sideDisp * (targetDist - curDist) / targetDist, plan[i].laneLimLeft + ctx.ego.width * 0.6, plan[i].laneLimRight - ctx.ego.width * 0.6)
          plan[i].pos:setAddScaled(plan[i].posOrig, plan[i].normal, plan[i].lateralXnorm)
          curDist = curDist + plan[i-1].length
          lastPlanIdx = i

          plan[i].vec:setSub2(plan[i-1].pos, plan[i].pos); plan[i].vec.z = 0
          plan[i].dirVec:setScaled2(plan[i].vec, 1 / plan[i].vec:lengthGuarded())

          if curDist > targetDist then break end
        end

        parts.updatePlanLen(plan, 2, lastPlanIdx + 1)
      end
    end

    -- detect if plan is moved to close to road limit
    if pmode then return end
    plan.hitLimit = ((plan[2].halfWidth - plan[2].lateralXnorm) < ctx.ego.width * 0.5 and 1) or ((plan[2].halfWidth + plan[2].lateralXnorm) < ctx.ego.width * 0.5 and -1) or 0
  end

  local function calculateRaceSpringForces(route, plan, pmode)
    -- calculate spring forces
    for i = 0, plan.planCount do
      if ctx.forces[i] then
        if not pmode and route.plan_index and i > 0 and ctx.aiState.currentRoute.offset then
          ctx.forces[i]:setScaled2(plan[i].normal, ctx.aiState.currentRoute.offset)
        else
          ctx.forces[i]:set(0,0,0)
        end
      else
        ctx.forces[i] = vec3()
      end
    end

    for i = 1, plan.planCount-1 do
      local n1 = plan[i]
      local v1 = n1.dirVec
      local v2 = plan[i+1].dirVec

      n1.turnDir:setSub2(v1, v2); n1.turnDir:normalize()
      local turnCoef = ctx.aiState.parameters.turnForceCoef * (ctx.opt.racing and (type(ctx.aiState.parameters.raceTurnCoefScale) == 'number' and ctx.aiState.parameters.raceTurnCoefScale or 1.0) or 1)

      local forceCoef = (1-ctx.twt.state) * max(1 - v1:dot(v2), 0) * turnCoef

      ctx.forces[i-1]:setAddScaled(ctx.forces[i-1], n1.turnDir, -forceCoef)
      ctx.forces[i]:setAddScaled(ctx.forces[i], n1.turnDir, 2 * forceCoef)
      ctx.forces[i+1]:setAddScaled(ctx.forces[i+1], n1.turnDir, -forceCoef)
    end
  end

  local function integrateRaceSpringForces(plan)
    local roadWidthMargin = ctx.ego.width * 0.8
    local laneWidthMargin = ctx.ego.width * 0.8
    local forceMagLim = ctx.aiState.parameters.springForceIntegratorDispLim
    local skipLast = 1
    for i = 2, plan.planCount-skipLast do
      local n = plan[i]
      local roadHalfWidth = n.halfWidth

      -- Calculate node displacement: avoids switching displacement direction (sign) in concecutive frames
      local displacement = max(min(n.normal:dot(ctx.forces[i]), forceMagLim), -forceMagLim)
      displacement = displacement * max(min(displacement * n.dispDir * math.huge, 1), 0) -- second term returns 0 if (displacement * n.dispDir) is negative, 1 otherwise.
      n.dispDir = sign(displacement)

      local roadLimRight = max(0, roadHalfWidth - roadWidthMargin) -- should be non-negative (zero or positive)
      local newLateralXnorm = clamp(n.lateralXnorm + displacement,
        max(n.laneLimLeft + laneWidthMargin, -roadLimRight) + max(0, plan.offset or 0) ,
        min(n.laneLimRight - laneWidthMargin, roadLimRight) + min(0, plan.offset or 0))

      n.pos:setAddScaled(n.pos, n.normal, newLateralXnorm - n.lateralXnorm) -- remember that posOrig and pos are not alligned along the normal
      n.vec:setSub2(plan[i-1].pos, n.pos); n.vec.z = 0
      n.dirVec:setScaled2(n.vec, 1 / n.vec:lengthGuarded())

      n.lateralXnorm = newLateralXnorm
    end

    parts.updatePlanLen(plan, 2, plan.planCount)
    return roadWidthMargin, laneWidthMargin
  end

  local function applyRaceCornerLineLift(liftPlan, liftMax, k0, k1, roadWidthMargin, laneWidthMargin, tmpVec)
    if not liftPlan or not liftPlan[2] or (liftPlan.planCount or 0) < 2 then return end
    for i = 2, liftPlan.planCount - 1 do
      local n = liftPlan[i]
      local np = liftPlan[i + 1]
      if not (np and n.vec and np.vec) then goto nextCornerLiftNode end
      local cInst = abs(parts.inCurvature(n.vec, np.vec))
      local kRef = max(cInst, abs(n.curvature or 0))
      local t = clamp((kRef - k0) / (k1 - k0), 0, 1)
      if t > 0 then
        tmpVec:setSub2(n.dirVec, np.dirVec)
        local tl = tmpVec:length()
        if tl > 1e-5 then
          tmpVec:setScaled(1 / tl)
          local widenSign = -sign2(tmpVec:dot(n.normal))
          local delta = t * liftMax * widenSign
          local roadHalfWidth = n.halfWidth
          local roadLimRight = max(0, roadHalfWidth - roadWidthMargin)
          local limL = max(n.laneLimLeft + laneWidthMargin, -roadLimRight) + max(0, liftPlan.offset or 0)
          local limR = min(n.laneLimRight - laneWidthMargin, roadLimRight) + min(0, liftPlan.offset or 0)
          local newLat = clamp(n.lateralXnorm + delta, limL, limR)
          if newLat ~= n.lateralXnorm then
            n.lateralXnorm = newLat
            n.pos:setScaled2(n.normal, newLat)
            n.pos:setAdd(n.posOrig)
          end
        end
      end
      ::nextCornerLiftNode::
    end
    for i = 2, liftPlan.planCount do
      liftPlan[i].vec:setSub2(liftPlan[i - 1].pos, liftPlan[i].pos)
      liftPlan[i].vec.z = 0
      liftPlan[i].dirVec:set(liftPlan[i].vec)
      liftPlan[i].dirVec:normalize()
    end
    parts.updatePlanLen(liftPlan, 2, liftPlan.planCount)
  end

  local function liftRaceCornerLines(route, plan, pmode)
    -- Use the outside of tight corners for a wider racing arc while retaining lane limits.
    if not (ctx.opt.racing and not pmode and type(ctx.aiState.parameters.raceCornerLineLiftMaxM) == 'number' and ctx.aiState.parameters.raceCornerLineLiftMaxM > 0) then return end
    local liftMax = ctx.aiState.parameters.raceCornerLineLiftMaxM * clamp((type(ctx.aiState.parameters.raceCornerLineLiftScale) == 'number' and ctx.aiState.parameters.raceCornerLineLiftScale) or 1, 0, 1.5)
    local k0 = (type(ctx.aiState.parameters.raceCornerCurvStart) == 'number' and ctx.aiState.parameters.raceCornerCurvStart) or 0.022
    local k1 = (type(ctx.aiState.parameters.raceCornerCurvEnd) == 'number'
      and ctx.aiState.parameters.raceCornerCurvEnd) or 0.10
    if k1 <= k0 then k1 = k0 + 1e-4 end
    local roadWidthMargin = ctx.ego.width * 0.8
    local laneWidthMargin = ctx.ego.width * 0.8
    local tmpVec = getTmpVec3(ctx.ego)

    applyRaceCornerLineLift(plan, liftMax, k0, k1, roadWidthMargin, laneWidthMargin, tmpVec)
    if route.planL then applyRaceCornerLineLift(route.planL, liftMax, k0, k1, roadWidthMargin, laneWidthMargin, tmpVec) end
    if not route.planR then return end
    applyRaceCornerLineLift(route.planR, liftMax, k0, k1, roadWidthMargin, laneWidthMargin, tmpVec)
  end

  local function adjustRaceAvoidanceTarget(plan, roadWidthMargin, laneWidthMargin)
    -- ######side avoidance pt. 2####### --
    if not (plan.sideDisp and plan.hitLimit and not (plan.hitLimit * plan.dispLat > 0)) then return end
    local targetNode = plan[plan.targetSeg]
    local newdisp = clamp(targetNode.lateralXnorm + plan.dispLat,
      max(targetNode.laneLimLeft + laneWidthMargin, -max(0, targetNode.halfWidth - roadWidthMargin)),
      min(targetNode.laneLimRight - laneWidthMargin, max(0, targetNode.halfWidth - roadWidthMargin)))
    local dispLat = newdisp - targetNode.lateralXnorm
    plan.targetPos:setAddScaled(plan.targetPos, plan[plan.targetSeg].normal, dispLat)
  end

  local function calculateRaceCurvature(plan)
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
  end

  local function planRaceGeometrySpeed(route, plan)
    local SPEED_HORIZON_M = 550
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
    ctx.aiState.raceCommit.boostPlanSpeeds(plan)


    plan.targetSpeed = ctx.aiState.raceCommit.smoothPlanTargetSpeed(ctx.aiState.raceCommit.applySpeedFloor(plan[1].speed + max(0, plan.egoXnormOnSeg) * (plan[2].speed - plan[1].speed)), ctx.aiState.dt)

    parts.calculateTrafficTargetSpeed(plan, ctx.traffic.objects)
  end

  local function mergeRaceTrafficSpeed(route, plan, pmode)
    plan.originaltargetSpeed = plan.targetSpeed -- save target speed computed by geometry only
    local geoTS = plan.targetSpeed
    local mergedTS = min(geoTS, plan.trafficTargetSpeed)
    -- Racing: recover part of geometric target when traffic overlap caps speed (reduces follow-the-leader in packs).
    if ctx.opt.racing then
      local passBlend = (type(ctx.aiState.parameters.raceTrafficPassBlend) == 'number' and ctx.aiState.parameters.raceTrafficPassBlend) or 0
      passBlend = clamp(passBlend, 0, 0.88)
      -- Only on clearance-evaluated alt (pmode) or committed alt; keep main plan traffic-safe.
      local evaluatingAlt = pmode == 'left' or pmode == 'right'
      local committedAlt = route and ctx.raceAltPlan.normIdx(route.plan_index) ~= 0
      if (evaluatingAlt or committedAlt) and passBlend > 0 and geoTS > mergedTS then
        mergedTS = mergedTS + passBlend * (geoTS - mergedTS)
      end
    end
    -- Measure lateral error against the main path so alternatives share the same intended trajectory.
    if ctx.opt.racing and type(ctx.aiState.parameters.raceWideLineTrafficBlend) == 'number' and ctx.aiState.parameters.raceWideLineTrafficBlend > 0 then
      local refPlan = route.plan
      local egoSegIdx = (refPlan and type(refPlan.egoSeg) == 'number' and refPlan.egoSeg) or plan.egoSeg or 1
      if refPlan and refPlan.planCount and egoSegIdx > refPlan.planCount - 1 then
        egoSegIdx = max(1, refPlan.planCount - 1)
      end
      local refNode = refPlan and refPlan[egoSegIdx]
      local refNextNode = refPlan and refPlan[egoSegIdx + 1]
      if refNode and refNextNode then
        local p1, p2 = refNode.pos, refNextNode.pos
        local egoXnorm = ctx.ego.pos:xnormOnLine(p1, p2)
        if egoXnorm < 0 then egoXnorm = 0 elseif egoXnorm > 1 then egoXnorm = 1 end
        local onL = p1 + (p2 - p1) * egoXnorm
        local latMag = abs((ctx.ego.pos - onL):dot(refNode.normal))
        local lat0 = (type(ctx.aiState.parameters.raceWideLineLateralStartM) == 'number' and ctx.aiState.parameters.raceWideLineLateralStartM) or 0.85
        local lat1 = (type(ctx.aiState.parameters.raceWideLineLateralEndM) == 'number' and ctx.aiState.parameters.raceWideLineLateralEndM) or 2.5
        if lat1 <= lat0 then lat1 = lat0 + 0.01 end
        local tWide = clamp((latMag - lat0) / (lat1 - lat0), 0, 1)
        local relief = tWide * clamp(ctx.aiState.parameters.raceWideLineTrafficBlend, 0, 1)
        mergedTS = mergedTS + relief * (geoTS - mergedTS)
      end
    end
    plan.targetSpeed = mergedTS
  end

  local function planRaceRouteAhead(route, baseRoute, pmode)
    if not route then return end

    if not route.path then
      route = parts.createNewRoute(route)
    end

    -- load the plan that has to be updated ()
    local plan = pmode == 'left' and route.planL or pmode == 'right' and route.planR or route.plan

    mergeBaseRacePlan(route, plan, baseRoute)

    initializeRacePlan(route, plan)

    extendRacePlan(route, plan, pmode)

    if not plan[2] then return end
    if not plan[1].pathidx then
      plan[1].pathidx = plan[2].pathidx
      plan[1].roadSpeedLimit = plan[2].roadSpeedLimit
    end

    advanceRacePlanTarget(route, plan, pmode)

    collectRaceTraffic(plan)

    applyRaceSideAvoidance(plan, pmode)
    calculateRaceSpringForces(route, plan, pmode)


    local roadWidthMargin, laneWidthMargin = integrateRaceSpringForces(plan)

    liftRaceCornerLines(route, plan, pmode)

    if not pmode then -- adjust plan error for main plan
      parts.uniformPlanErrorDistribution(plan)
    end

    parts.calculateTarget(plan)

    adjustRaceAvoidanceTarget(plan, roadWidthMargin, laneWidthMargin)

    calculateRaceCurvature(plan)

    planRaceGeometrySpeed(route, plan)

    mergeRaceTrafficSpeed(route, plan, pmode)

    return route
  end

  return {
    planRaceRouteAhead = planRaceRouteAhead,
  }
end

return lib
