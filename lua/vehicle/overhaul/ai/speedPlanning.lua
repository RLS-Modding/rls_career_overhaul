-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this file,
-- You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Traction-constrained speed profiles and traffic-aware plan geometry.
-- create binds this extension instance; require caches only the factory.

-- Map, in reading order:
--   speed profiles: forward and backward solvers over the traction model
--   setters: setRacing, setTractionModel, and the traffic and debug switches
--   plan geometry: calculateTrafficTargetSpeed, offsetPlan, copyNode, copyPlan
--   lateral avoidance and densifyPlan
--   the returned table is the exported surface

local lib = {}

function lib.create(ctx)
  -- Locals for speed: this file runs every AI frame.
  local max, min, abs, sqrt = math.max, math.min, math.abs, math.sqrt
  local tableInsert, tableRemove = ctx.tableInsert, ctx.tableRemove
  local square, getTmpVec3 = ctx.square, ctx.getTmpVec3
  local gravity = ctx.g
  local ego = ctx.ego
  local opt = ctx.opt
  local traffic = ctx.traffic
  -- Functions from the other AI parts that this part calls, read from ctx once when it is created.
  local parts = {
    setGetObjectBoundingBox = ctx.setGetObjectBoundingBox,
    calculateTarget = ctx.calculateTarget,
    updatePlanLen = ctx.updatePlanLen,
    openLaneToLaneRange = ctx.openLaneToLaneRange,
    getNewNode = ctx.getNewNode,
  }

  local function setSpeedProfileMode(mode)
    if mode == 'Back' then
      ctx.aiState.speedProfileMode = 'Back'
    elseif mode == 'ForwBack' then
      ctx.aiState.speedProfileMode = 'ForwBack'
    else
      ctx.aiState.speedProfileMode = nil
    end
  end

  -- Both tyre axes share one cap; each model allocates the remaining grip differently.
  local function evaluateDiamondTraction(speedSq, maxAccelerationMps2, curvature)
    local maxLongitudinalAccelerationMps2 = maxAccelerationMps2
    local maxLateralAccelerationMps2 = maxAccelerationMps2
    local lateralAccelerationMps2 = speedSq * curvature
    return maxLongitudinalAccelerationMps2 * max(0, 1 - lateralAccelerationMps2 / maxLateralAccelerationMps2)
  end

  local function evaluateEllipticTraction(speedSq, maxAccelerationMps2, curvature)
    local maxLongitudinalAccelerationMps2 = maxAccelerationMps2
    local maxLateralAccelerationMps2 = maxAccelerationMps2
    local lateralAccelerationMps2 = speedSq * curvature
    if lateralAccelerationMps2 < maxLateralAccelerationMps2 then
      return maxLongitudinalAccelerationMps2 * sqrt(1 - square(lateralAccelerationMps2/maxLateralAccelerationMps2))
    else
      return 0
    end
  end

  local evaluateTraction = evaluateEllipticTraction -- Default adherence constraint
  -- set the index for adherence constraint, useful only for Back or ForwBack mode
  local function setTractionModel(tractionModelIndex)
    if tractionModelIndex == 1 then
      evaluateTraction = evaluateDiamondTraction
    else
      evaluateTraction = evaluateEllipticTraction
    end
  end

  local function solveForwardSpeedProfile(plan, speed0)
    -- The preceding turn-speed calculation already supplies squared speeds.

    plan[1].speed = speed0 or plan[1].speed

    -- The last node speed value was not calculated from the limiting turn speed (due to absence of curvature value), so square it.
    plan[plan.planCount].speed = square(plan[plan.planCount].speed)

    for i = 1, plan.planCount-1 do
      local n1, n2 = plan[i], plan[i+1]

      local vx_possible_next
      if plan.stopSeg <= i+1 then
        vx_possible_next = 0
      else
        if min(n2.speed, n2.trafficSqVel) < n1.speed then -- max velocity at i-1 is less than velocity at i (not a deceleration phase)
          vx_possible_next = min(n2.speed, n2.trafficSqVel)
        else
          local ax_final = evaluateTraction(n1.speed, n1.acc_max, abs(n1.curvature))
          vx_possible_next = n1.speed + 2 * ax_final * n1.length -- speed squared
          vx_possible_next = min(n2.speed, min(n2.trafficSqVel, vx_possible_next))
        end
      end

      n2.speed = vx_possible_next
    end

    -- Backwards aceel integrator expects the last node speed value to not be squared
    plan[plan.planCount].speed = sqrt(plan[plan.planCount].speed)
  end

  local function solveBackwardSpeedProfile(plan)
    for i = plan.planCount, 2, -1 do
      local n1, n2 = plan[i-1], plan[i]
      local vx_possible_next
      if plan.stopSeg <= i-1 then
        vx_possible_next = 0
      else
        local n2SpeedSq = n2.speed * n2.speed
        if min(n1.speed, n1.trafficSqVel) < n2SpeedSq then -- max velocity at i-1 is less than velocity at i (not a deceleration phase)
          vx_possible_next = sqrt(min(n1.speed, n1.trafficSqVel))
        else
          -- available longitudinal acceleration at node i
          local ax_possible_current = evaluateTraction(n2SpeedSq, n2.acc_max, abs(n2.curvature))
          -- possible velocity at node i-1 given available longitudinal acceleration at node i
          vx_possible_next = n2SpeedSq + 2 * n1.length * ax_possible_current

          -- available longitudinal acceleration at node i-1 given velocity estimate at node i-1
          local ax_possible_next = evaluateTraction(vx_possible_next, n1.acc_max, abs(n1.curvature))
          -- possible velocity at i-1 given available longitudinal acceleration at node i-1
          local vx_tmp = n2SpeedSq + 2 * n1.length * ax_possible_next

          if vx_possible_next > vx_tmp then
            -- available longitudinal acceleration at node i-1 given new velocity estimate at node i-1
            ax_possible_next = evaluateTraction(vx_tmp, n1.acc_max, abs(n1.curvature))
            -- improve velocity estimate at i-1 given available longitudinal acceleration at node i-1
            vx_tmp = n2SpeedSq + 2 * n1.length * ax_possible_next
            -- keep the velocity that satisfies longitudinal acceleration constraints at node i-1 and node i
            vx_possible_next = min(vx_possible_next, vx_tmp)
          end

          vx_possible_next = sqrt(min(n1.speed, min(n1.trafficSqVel, vx_possible_next))) -- respect traffic speed
        end
      end

      n1.speed = n1.manSpeed or
                 (ctx.M.speedMode == 'limit' and ctx.M.routeSpeed and min(ctx.M.routeSpeed, vx_possible_next)) or
                 (ctx.M.speedMode == 'set' and ctx.M.routeSpeed) or
                 (ctx.M.speedMode == 'legal' and min(n1.roadSpeedLimit or math.huge, vx_possible_next)) or
                 vx_possible_next


      n1.trafficSqVel = math.huge
    end
  end

  local function setRacing(enabled)
    if enabled == true then
      opt.racing = true
    else
      opt.racing = false
    end
  end
  ctx.M.setRacing = setRacing

  ctx.M.setTrafficFilter = function(enabled) traffic.filtered = enabled == true end
  ctx.M.setVdraw = function(enabled) traffic.vdraw = enabled == true end

  local function setEnableFastPhysicsforTraffic(enabled)
    if enabled == true then
      opt.enableFastPhysicsforTraffic = true
    else
      opt.enableFastPhysicsforTraffic = false
    end
  end
  ctx.M.setEnableFastPhysicsforTraffic = setEnableFastPhysicsforTraffic

  local function updatePlanBestRange(plan)
    for i = 1, plan.planCount do
      local n = plan[i]
      local roadHalfWidth = n.halfWidth
      local laneWidth = 2 * roadHalfWidth * (n.rangeRight - n.rangeLeft) / n.rangeLaneCount
      plan[i].rangeBestLane = clamp((n.laneLimLeft - ((2 * n.rangeLeft - 1) * roadHalfWidth)) / laneWidth, 0, n.rangeLaneCount-1)
    end
  end

  local function applyTrafficSpeedConstraint(plan, distOnPlan, segDirVec, stopFlag, i, n1, n2, trafficObject)
    stopFlag = true
    local vRearXnorm, vFrontXnorm = trafficObject.posRear:xnormOnLine(n1.pos, n2.pos), trafficObject.posFront:xnormOnLine(n1.pos, n2.pos)
    -- if the vehicle overlaps the first segment check if its xnorm is greater than the xnorm of the ego vehicle
    if i > 1 or max(vRearXnorm, vFrontXnorm) > plan.egoXnormOnSeg then
      local vXnorm = clamp(min(vRearXnorm, vFrontXnorm), 0, 1)

      -- Reduce speed feedback gain to limit its low-target-speed control loop.
      local ego2PlDist_0 = max(0, distOnPlan - (1 - vXnorm) * n1.length) --max(2.5, opt.racing and ego.speed*0.5 or ego.speed * 1)
      plan.distances = min(ego2PlDist_0, plan.distances)

      ego.race_d = 0.5 * ego.length
      local ego2PlDist = ego2PlDist_0 - ego.speed * ego.race_time_gap --max(2.5, ego.speed * 1)
      local velProjOnSeg = trafficObject.vel:dot(segDirVec)
      local gain = (ego2PlDist > 0 and ego.race_catchAgg or ego.race_brakeAgg) * abs(ego2PlDist) + 1 -- gain factor to try to catch the vehicle ahead by boosting acceleration (ego2PlDist > 0) or brake at maximum acceleration (ego2PlDist < 0)
      local targetSpeed = max(0, abs(velProjOnSeg) * velProjOnSeg + 2 * gravity * min(ctx.aiState.aggression, ego.staticFrictionCoef) * ego2PlDist * gain)

      -- might help improve the throttle/brake input stability caused by the feedback loop of the ego.speed term in ego2PlDist

      plan.trafficTargetSpeed = min(targetSpeed, plan.trafficTargetSpeed)
      plan.trafficMinProjSpeed = min(velProjOnSeg, plan.trafficMinProjSpeed)
    end
    return stopFlag
  end

  local function calculateTrafficTargetSpeed(plan, trafficObjects)
    plan.distances = math.huge
    plan.distancesV = math.huge
    plan.trafficTargetSpeed = math.huge
    local trafficObjCount = #trafficObjects
    if trafficObjCount > 0 and plan.targetSpeed > 0 then
      local distOnPlan = - plan[1].length * plan.egoXnormOnSeg
      local segDirVec, segVx, segC, segVz, segVy = getTmpVec3(ego), getTmpVec3(ego), getTmpVec3(ego), getTmpVec3(ego), getTmpVec3(ego)
      local stopFlag = false
      -- update traffic objects bounding boxes

      for j = 1, trafficObjCount do
        local trafficObject = trafficObjects[j]
        trafficObject.vx = trafficObject.vx or vec3()
        trafficObject.vy = trafficObject.vy or vec3()
        trafficObject.vz = trafficObject.vz or vec3()
        parts.setGetObjectBoundingBox(trafficObject.posMiddle, trafficObject.vx, trafficObject.vy, trafficObject.vz,trafficObject.id)
        trafficObject.vx:setScaled(1.1)
        trafficObject.posFront:setAdd2(trafficObject.posMiddle, trafficObject.vx)
        trafficObject.posRear:setSub2(trafficObject.posMiddle, trafficObject.vx)
        trafficObject.length = trafficObject.vx:length() * 2
        trafficObject.width = trafficObject.vy:length() * 2
      end
      for i = 1, plan.planCount - 1 do
        local n1, n2 = plan[i], plan[i+1]
        distOnPlan = distOnPlan + n1.length -- distance from the ego vehicle front position to the end of the ith segment along the plan
        segDirVec:setSub2(n2.pos, n1.pos); segDirVec:setScaled(1 / (n1.length + 1e-30))

        -- Bounding box of segment [n1, n2]
        segVx:setScaled2(segDirVec, 0.5 * n1.length)
        segC:setAdd2(n1.pos, segVx)
        mapmgr.setSurfaceNormalBelow(segVz, segC, (n1.radiusOrig + n2.radiusOrig) * 0.25); segVz:setScaled(-1)
        segVy:setCross(segVz, segVx); segVy:setScaled(0.5 * ego.width / (segVy:length() +  1e-30)) -- 0.5 * (ego.width + 1)
        for j = trafficObjCount, 1, -1 do
          local trafficObject = trafficObjects[j]
          local check_ahead = (ego.length * push3(ego.dirVec) - ego.pos + trafficObject.posFront):dot(ego.dirVec) > 0
          plan.distancesV = check_ahead and min(ego.pos:squaredDistance(trafficObject.posMiddle), plan.distancesV) or plan.distancesV

          if overlapsOBB_OBB(trafficObject.posMiddle, trafficObject.vx, trafficObject.vy, trafficObject.vz, segC, segVx, segVy, segVz) then
            stopFlag = applyTrafficSpeedConstraint(plan, distOnPlan, segDirVec, stopFlag, i, n1, n2, trafficObject)

            tableRemove(trafficObjects, j)
            trafficObjCount = trafficObjCount - 1
          end

        end


        --  break
        if stopFlag then break end
      end
    end
    local dv = ego.speed - plan.trafficMinProjSpeed
    local TTC = plan.distances / max(dv, 1e-3)
    if TTC < 3 and abs(plan.trafficMinProjSpeed) < 5 then
      plan.trafficTargetSpeed = 0
    end
    plan.trafficTargetSpeed = sqrt(plan.trafficTargetSpeed)
  end

  local function offsetPlan(plan, altPlan, side)
    local sideSign = side == 'right' and 1 or side == 'left' and -1 or 0
    local latdisp = (1.2 * ego.width) or 3
    local margin = ego.width * 0.5
    altPlan.offset = latdisp * sideSign
    local dist = 0
    -- apply offset and update other geometrical quantities
    for i = 1, plan.planCount do
      local n = altPlan[i]
      dist = dist + (n.length or 0)
      local offset = clamp(altPlan.offset, -(plan[i].halfWidth - margin) - plan[i].lateralXnorm, (plan[i].halfWidth - margin) - plan[i].lateralXnorm)
      n.pos:setAddScaled(n.pos, plan[i].normal, offset)
      n.lateralXnorm = n.lateralXnorm + offset

      if i > 1 then
        local n_1 = altPlan[i-1]
        n.vec:setSub2(n_1.pos, n.pos); n.vec.z = 0
        n.dirVec:setScaled2(n.vec, 1 / n.vec:lengthGuarded())
        n_1.turnDir:setSub2(n_1.dirVec, n.dirVec); n_1.turnDir:normalize()
      end
    end

    parts.updatePlanLen(altPlan, 1, altPlan.planCount)
  end

  local function copyNode(tab2copy)
    return {
      pos = tab2copy.pos:copy(),
      length = tab2copy.length,
      radiusOrig = tab2copy.radiusOrig,
      normal = tab2copy.normal:copy(),
      halfWidth = tab2copy.halfWidth,
      lateralXnorm = tab2copy.lateralXnorm,
      ---
      speed = tab2copy.speed,
      posOrig = tab2copy.posOrig:copy(),
      biNormal = tab2copy.biNormal:copy(),
      dirVec = tab2copy.dirVec:copy(),
      vec = tab2copy.vec:copy(),
      rangeLeft = tab2copy.rangeLeft,
      rangeRight = tab2copy.rangeRight,
      rangeLaneCount = tab2copy.rangeLaneCount,
      rangeBestLane = tab2copy.rangeBestLane, -- Avoid ?
      pathidx = tab2copy.pathidx,
      curvature = tab2copy.curvature,
      turnDir = tab2copy.turnDir,   -- Avoid ?
      dispDir = tab2copy.dispDir, -- Avoid ?
      laneLimLeft = tab2copy.laneLimLeft,
      laneLimRight = tab2copy.laneLimRight,
      curvatureZ = 0,
      trafficSqVel = math.huge,
      manSpeed = tab2copy.manSpeed,
      roadSpeedLimit = tab2copy.roadSpeedLimit,
      nextNodeInPath = tab2copy.nextNodeInPath,
      awCache = tab2copy.awCache or {}
    }
  end

  local function copyPlan(tab2copy, tab2fill)
    local newPlan = tab2fill or {}
    local keysNum = 32
    for i = 1, max(#newPlan, #tab2copy) do
      if not tab2copy[i] then
        newPlan[i] = nil -- Do we need to nil this?
      else
        local tabentry = tab2copy[i]
        if newPlan[i] then
          newPlan[i].pos:set(tabentry.pos)
          newPlan[i].normal:set(tabentry.normal)
          newPlan[i].posOrig:set(tabentry.posOrig)
          newPlan[i].biNormal:set(tabentry.biNormal)
          newPlan[i].dirVec:set(tabentry.dirVec)
          newPlan[i].vec:set(tabentry.vec)
        else
          newPlan[i] = table.new(0, keysNum)
          newPlan[i].pos = tabentry.pos:copy()
          newPlan[i].normal = tabentry.normal:copy()
          newPlan[i].posOrig = tabentry.posOrig:copy()
          newPlan[i].biNormal = tabentry.biNormal:copy()
          newPlan[i].dirVec = tabentry.dirVec:copy()
          newPlan[i].vec = tabentry.vec:copy()
        end
        newPlan[i].length = tabentry.length
        newPlan[i].radiusOrig = tabentry.radiusOrig
        newPlan[i].halfWidth = tabentry.halfWidth
        newPlan[i].lateralXnorm = tabentry.lateralXnorm
        newPlan[i].speed = tabentry.speed
        newPlan[i].rangeLeft = tabentry.rangeLeft
        newPlan[i].rangeRight = tabentry.rangeRight
        newPlan[i].rangeLaneCount = tabentry.rangeLaneCount
        newPlan[i].rangeBestLane = tabentry.rangeBestLane -- Avoid ?
        newPlan[i].pathidx = tabentry.pathidx
        newPlan[i].curvature = tabentry.curvature
        newPlan[i].turnDir = tabentry.turnDir   -- Avoid ?
        newPlan[i].dispDir = tabentry.dispDir -- Avoid ?
        newPlan[i].laneLimLeft = tabentry.laneLimLeft
        newPlan[i].laneLimRight = tabentry.laneLimRight
        newPlan[i].curvatureZ = 0
        newPlan[i].trafficSqVel = math.huge
        newPlan[i].manSpeed = tabentry.manSpeed
        newPlan[i].roadSpeedLimit = tabentry.roadSpeedLimit
        newPlan[i].nextNodeInPath = tabentry.nextNodeInPath
        newPlan[i].awCache = tabentry.awCache or {}
      end
    end
    newPlan.planLen = tab2copy.planLen
    newPlan.planCount = tab2copy.planCount
    newPlan.egoXnormOnSeg = tab2copy.egoXnormOnSeg
    newPlan.egoSeg = tab2copy.egoSeg
    newPlan.stopSeg = math.huge
    newPlan.trafficMinProjSpeed = math.huge
    newPlan.trafficMinDir = tab2copy.trafficMinDir
    newPlan.targetSpeed = tab2copy.targetSpeed
    newPlan.trafficTargetSpeed = tab2copy.trafficTargetSpeed
    newPlan.targetSeg = tab2copy.targetSeg
    newPlan.targetPos = vec3(tab2copy.targetPos)
    newPlan.egoDeviation = tab2copy.egoDeviation

    return newPlan
  end

  local function updateLateralAvoidance(plan)
    plan.dispLat = 0
    if traffic.objects[1] then
      local dispLeft, dispRight = 0, 0
      local egoLengthInv = 1 / ego.length
      local baseClearanceMeters, closingTimeSeconds, recedingClearanceMeters, staticMarginMeters = 0.3, 0.8, 0.3, 0.2
      local egoPosDOTegoDirVec = ego.pos:dot(ego.dirVec)
      local egoPosDOTegoRightVec = ego.pos:dot(ego.rightVec)
      local egoVelDOTegoRightVec = ego.vel:dot(ego.rightVec)
      local effectiveMarginMeters = (plan.clearanceScale and (staticMarginMeters * plan.clearanceScale)) or staticMarginMeters

      for i = 1, #traffic.objects do
        local otherVehicle = traffic.objects[i]
        local longitudinalDistanceMeters = otherVehicle.posFront:dot(ego.dirVec) - egoPosDOTegoDirVec
        if longitudinalDistanceMeters >= - ego.length then
          local proximityWeight = math.exp(-square(longitudinalDistanceMeters * egoLengthInv)) -- Intensity factor
          if proximityWeight > 0.05 then
            local lateralDistanceMeters = otherVehicle.posFront:dot(ego.rightVec) - egoPosDOTegoRightVec
            local relativeLateralSpeedMps = otherVehicle.vel:dot(ego.rightVec) - egoVelDOTegoRightVec
            local closingSpeedMps = max(0, -sign(lateralDistanceMeters) * relativeLateralSpeedMps) -- Approaching speed, positive if approaching, zero otherwise
            local requiredGapMeters = closingSpeedMps > 0 and baseClearanceMeters + closingTimeSeconds * closingSpeedMps or recedingClearanceMeters
            local combinedHalfWidthMeters = 0.5 * (ego.width + (otherVehicle.effectiveWidth or otherVehicle.width)) + effectiveMarginMeters
            local freeGapMeters = max(0, abs(lateralDistanceMeters) - combinedHalfWidthMeters)
            local gapDeficitMeters = max(0, requiredGapMeters - freeGapMeters)
            local avoidanceDisplacementMeters = proximityWeight * gapDeficitMeters
            if avoidanceDisplacementMeters > 0 then
              if lateralDistanceMeters <= 0 then
                dispLeft = avoidanceDisplacementMeters > 0.05 and max(avoidanceDisplacementMeters, dispLeft) or 0
              else
                dispRight = avoidanceDisplacementMeters > 0.05 and max(avoidanceDisplacementMeters, dispRight) or 0
              end
            end
          end
        end
      end
      plan.dispLat = dispLeft - dispRight -- store displacement. dispLat > 0 -> I want to move targetPos to the right, hence on tragetSeg.normal direction
    end
  end

  local function interpolatePlanNodeGeometry(plan, i, n1, n2)
    local newNode = parts.getNewNode()

    newNode.posOrig:setAdd2(n1.posOrig, n2.posOrig); newNode.posOrig:setScaled(0.5)

    local radiusOrig = (n1.radiusOrig + n2.radiusOrig) * 0.5 -- TODO: this might be inacurate since posOrig might not be halfway between n1.posOrig and n2.posOrig

    mapmgr.setSurfaceNormalBelow(newNode.biNormal, newNode.posOrig, radiusOrig * 0.5)
    newNode.biNormal:setScaled(-1)

    -- Interpolated normals
    local segLenSq = plan[i].posOrig:squaredDistance(plan[i+1].posOrig)
    if segLenSq > square(2 * radiusOrig + n1.radiusOrig + n2.radiusOrig) then
      -- calculate normal from the direction vector of edge (i, i+1)
      newNode.normal:setSub2(plan[i+1].pos, plan[i].pos) -- should't this be posOrig instead of pos?
      newNode.normal:setCross(newNode.biNormal, newNode.normal)
      newNode.normal:normalize()
    else
      -- calculate from adjacent normals
      newNode.normal:set(
        ((push3(newNode.biNormal):cross(plan[i].normal)):cross(newNode.biNormal):normalized() +
        (push3(newNode.biNormal):cross(plan[i+1].normal)):cross(newNode.biNormal):normalized()):normalized()
      )
    end

    newNode.pos:setAdd2(n1.pos, n2.pos); newNode.pos:setScaled(0.5)
    newNode.vec:setSub2(n1.pos, newNode.pos); newNode.vec.z = 0
    newNode.dirVec:setScaled2(newNode.vec, 1 / newNode.vec:lengthGuarded())

    local vTmp1 = getTmpVec3(ego)
    vTmp1:setSub2(n2.posOrig, n1.posOrig)
    local t = closestLinePointsPointVec(n1.posOrig, vTmp1, newNode.pos, newNode.normal)
    newNode.posOrig:setAddScaled(n1.posOrig, vTmp1, t)

    local edgeNormal = getTmpVec3(ego)
    edgeNormal:set(push3(newNode.biNormal):cross(vTmp1):normalized())

    local vTmp3 = getTmpVec3(ego)
    vTmp3:setAddScaled(plan[i].posOrig, edgeNormal, plan[i].radiusOrig)

    local vTmp4 = getTmpVec3(ego)
    vTmp4:setSub2(plan[i+1].radiusOrig * push3(edgeNormal) + plan[i+1].posOrig, vTmp3)

    local t2 = closestLinePointsPointVec(vTmp3, vTmp4, newNode.posOrig, newNode.normal)

    local limPos = getTmpVec3(ego)
    limPos:setAddScaled(vTmp3, vTmp4, max(0, min(1, t2)))

    local roadHalfWidth = newNode.posOrig:distance(limPos)
    return newNode, radiusOrig, limPos, roadHalfWidth
  end

  local function insertInterpolatedPlanNode(plan, path, i)
    local n1, n2 = plan[i], plan[i+1]

    local newNode, radiusOrig, limPos, roadHalfWidth = interpolatePlanNodeGeometry(plan, i, n1, n2)
    local lateralXnorm = newNode.pos:xnormOnLine(newNode.posOrig, limPos) * roadHalfWidth -- [-r, r]

    n1.length = n1.length * 0.5

    n2.vec:set(newNode.vec)
    n2.dirVec:set(newNode.dirVec)


    local rangeLeft = (n1.rangeLeft + n2.rangeLeft) * 0.5 -- lane range left boundary lateral coordinate in [0, 1]. 0 is left road boundary: always 0 when driveInLane is off
    local rangeRight = (n1.rangeRight + n2.rangeRight) * 0.5 -- lane range right boundary lateral coordinate in [0, 1]. 1 is right road boundary: always 1 when driveInLane is off
    local rangeLaneCount = (n1.rangeLaneCount + n2.rangeLaneCount) * 0.5 -- number of lanes in the range: always 1 when driveInLane is off

    local laneWidth = (rangeRight - rangeLeft) / rangeLaneCount -- self explanatory: entire width of the road when driveInLane is off i.e. 1
    local rangeBestLane = (n1.rangeBestLane + n2.rangeBestLane) * 0.5 -- best lane in the range: only one lane to pick from when driveInLane is off

    local laneLimLeft = linearScale(rangeLeft + rangeBestLane * laneWidth, 0, 1, -roadHalfWidth, roadHalfWidth) -- lateral coordinate of left boundary of lane rescaled to the road half width
    local laneLimRight = linearScale(rangeLeft + (rangeBestLane + 1) * laneWidth, 0, 1, -roadHalfWidth, roadHalfWidth) -- lateral coordinate of right boundary of lane rescaled to the road half width

    local roadSpeedLimit
    if n2.pathidx > 1 then
      roadSpeedLimit = ctx.aiState.mapData.graph[path[n2.pathidx]][path[n2.pathidx-1]].speedLimit
    else
      roadSpeedLimit = n2.roadSpeedLimit
    end

    if plan.stopSeg >= i + 1 then
      plan.stopSeg = plan.stopSeg + 1
    end

    newNode.radiusOrig = radiusOrig
    newNode.manSpeed = n1.manSpeed and n2.manSpeed and (n1.manSpeed + n2.manSpeed) * 0.5
    newNode.roadSpeedLimit = roadSpeedLimit
    newNode.pathidx = n2.pathidx
    newNode.halfWidth = roadHalfWidth
    newNode.laneLimLeft = laneLimLeft
    newNode.laneLimRight = laneLimRight
    newNode.rangeLeft = rangeLeft
    newNode.rangeRight = rangeRight
    newNode.rangeLaneCount = rangeLaneCount
    newNode.rangeBestLane = rangeBestLane -- 0 Indexed
    newNode.length = n1.length
    newNode.curvature = (n1.curvature + n2.curvature) * 0.5
    newNode.curvatureZ = 0
    newNode.lateralXnorm = lateralXnorm
    newNode.speed = nil
    return n1, n2, newNode
  end

  local function densifyPlan(plan, path)
    -- Subdivide at most one segment per call, using distance-dependent thresholds.

    local distOnPlan = - ((plan.egoXnormOnSeg or 0) * plan[1].length)
    for i = 1, plan.planCount-1 do
      if plan[i].length > max(0, 0.5 * (max(distOnPlan, 0) - max(ego.speed * ctx.aiState.parameters.str, 20))) + max(ego.speed * ctx.aiState.parameters.stt, 6) or
          -- relative fitting error: max distance of arc from chord (plan segment) as a ratio of the radius
          distOnPlan < 20 and plan[i].length > 4 and (1 - sqrt(max(0, 1 - square(0.5 * plan[i].length * max(plan[i].curvature, plan[i+1].curvature))))) > 0.045 then -- or plan[i].length > 4.5 and distOnPlan < 30 and plan[i].fE > 0.3

        local n1, n2, newNode = insertInterpolatedPlanNode(plan, path, i)
        newNode.trafficSqVel = math.huge
        newNode.dispDir = 0
        newNode.nextNodeInPath = nil
        newNode.turnDir:set(0, 0, 0)

        for id, awCacheEntry in pairs(n1.awCache) do
          newNode.awCache[id] = awCacheEntry
        end

        tableInsert(plan, i+1, newNode)

        if n1.lanesOpen and n2.lanesOpen then
          parts.openLaneToLaneRange(plan[i+1])
        end

        plan.planCount = plan.planCount + 1
        -- call calculateTarget to update ego pos on the plan when first segment is split
        if i == 1 then parts.calculateTarget(plan) end
        break
      end
      distOnPlan = distOnPlan + plan[i].length

      if distOnPlan > 400 then break end
    end
  end

  return {
    setSpeedProfileMode = setSpeedProfileMode,
    setTractionModel = setTractionModel,
    solveForwardSpeedProfile = solveForwardSpeedProfile,
    solveBackwardSpeedProfile = solveBackwardSpeedProfile,
    updatePlanBestRange = updatePlanBestRange,
    calculateTrafficTargetSpeed = calculateTrafficTargetSpeed,
    offsetPlan = offsetPlan,
    copyNode = copyNode,
    copyPlan = copyPlan,
    updateLateralAvoidance = updateLateralAvoidance,
    densifyPlan = densifyPlan,
  }
end

return lib
