-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this file,
-- You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Mode dispatch, throttle and braking, and guarded per-frame updates.
-- create binds this extension instance; require caches only the factory.

-- Map, in reading order:
--   race alternatives: scoreClearancePass to prepareRaceAlternatives, and updateManualRacePlans
--   mode adjusters: adjustManualMode to adjustManualTrafficMode, dispatched by modeAdjustments
--   throttle and brake: throttleBrakeController, shared by every mode
--   per-frame state: sampleEgoPhysicsState, derby and side-passing updates, followCurrentRoutePlan
--   updateGFX is the only export

local lib = {}

function lib.create(ctx)
  -- Locals for speed: this file runs every AI frame.
  local max, min, abs, sqrt, asin = math.max, math.min, math.abs, math.sqrt, math.asin
  local tableConcat = ctx.tableConcat
  local square, getTmpVec3, resetTmpVec3 = ctx.square, ctx.getTmpVec3, ctx.resetTmpVec3
  local gravity = ctx.g
  -- Functions from the other AI parts that this part calls, read from ctx once when it is created.
  local parts = {
    restoreSavedGearboxMode = ctx.restoreSavedGearboxMode,
    startStopDataLog = ctx.startStopDataLog,
    getObjectBoundingBox = ctx.getObjectBoundingBox,
    aistatus = ctx.aistatus,
    stateChanged = ctx.stateChanged,
    setAggressionInternal = ctx.setAggressionInternal,
    updatePlayerData = ctx.updatePlayerData,
    driveCar = ctx.driveCar,
    driveToTarget = ctx.driveToTarget,
    targetsCompatible = ctx.targetsCompatible,
    getMinPlanLen = ctx.getMinPlanLen,
    getPathLen = ctx.getPathLen,
    offsetPlan = ctx.offsetPlan,
    copyPlan = ctx.copyPlan,
    planRaceRouteAhead = ctx.planRaceRouteAhead,
    planAhead = ctx.planAhead,
    resetMapAndRoute = ctx.resetMapAndRoute,
    getMapEdges = ctx.getMapEdges,
    newManualPath = ctx.newManualPath,
    setScriptedPath = ctx.setScriptedPath,
    fleePlan = ctx.fleePlan,
    chasePlan = ctx.chasePlan,
    trafficActions = ctx.trafficActions,
    trafficPlan = ctx.trafficPlan,
  }
  local gfxGuard = ctx.gfxGuard
  local dataLogger = ctx.dataLogger

  local function warningAIDisabled(message)
    guihooks.message(message, 5, "AI debug")
    ctx.M.mode = 'disabled'
    ctx.M.updateGFX = nop
    parts.resetMapAndRoute()
    parts.stateChanged()
  end

  local function targetFollowControl(targetSpeed, distLim) -- throttle and brake control for when driving directly to player
    -- distLim: Minimum distance allowed

    if not targetSpeed then
      if not ctx.aiState.player or not ctx.aiState.player.pos then return 0, 0, 0 end
      local plC, plX, plY, plZ = parts.getObjectBoundingBox(ctx.aiState.player.id)
      local ego2PlDirVec = plC - ctx.ego.pos; ego2PlDirVec:normalize()
      local minHit = intersectsRay_OBB(ctx.ego.pos, ego2PlDirVec, plC, plX, plY, plZ)
      local plSpeedFromego = ctx.aiState.player.vel:dot(ego2PlDirVec)
      local ego2PlDist = minHit - (distLim or 3)
      targetSpeed = sqrt(max(0, abs(plSpeedFromego) * plSpeedFromego + 2 * gravity * min(ctx.aiState.aggression, ctx.ego.staticFrictionCoef) * ego2PlDist))


    end

    local speedDif = targetSpeed - ctx.ego.speed
    return clamp(speedDif, 0, 1), clamp(-speedDif, 0, 1), targetSpeed

  end

  local function drivabilityChangeReroute()
    -- A drivability drop on the current path must trigger a re-route; the planner acts on the reRoute flag.

    if ctx.aiState.currentRoute ~= nil then
      -- changeSet format: {nodeA1, nodeB1, driv1, nodeA2, nodeB2, driv2, ...}
      local changeSet = mapmgr.changeSet
      local changeSetCount = #changeSet
      local changeSetDict = table.new(0, 2 * (changeSetCount / 3))

      -- populate the changeSetDict with the changeSet nodes
      for i = 1, changeSetCount, 3 do
        if changeSet[i+2] < 0 then
          changeSetDict[changeSet[i]] = true
          changeSetDict[changeSet[i+1]] = true
        end
      end

      local path = ctx.aiState.currentRoute.path
      local nodeCollisionIdx
      for i = ctx.aiState.currentRoute.plan[2].pathidx, #path do
        if changeSetDict[path[i]] then
          -- if there is a collision continue with a thorough check (edges against edges)
          nodeCollisionIdx = i
          break
        end
      end

      if nodeCollisionIdx then
        table.clear(changeSetDict)
        local edgeTab = {'','\0',''}
        -- populate the changeSetDict with changeSet edges
        for i = 1, changeSetCount, 3 do
          if changeSet[i+2] < 0 then
            local nodeA, nodeB = changeSet[i], changeSet[i+1]
            edgeTab[1] = nodeA < nodeB and nodeA or nodeB
            edgeTab[3] = nodeA == edgeTab[1] and nodeB or nodeA
            changeSetDict[tableConcat(edgeTab)] = true
          end
        end

        local edgeCollisionIdx
        -- compare path edges with changeSetDict edges starting with the earliest edge containing the initialy detected node collision
        for i = max(ctx.aiState.currentRoute.plan[2].pathidx, nodeCollisionIdx - 1), #path-1 do
          local nodeA, nodeB = path[i], path[i+1]
          edgeTab[1] = nodeA < nodeB and nodeA or nodeB
          edgeTab[3] = nodeA == edgeTab[1] and nodeB or nodeA
          if changeSetDict[tableConcat(edgeTab)] then
            edgeCollisionIdx = i
            ctx.aiState.currentRoute.plan.reRoute = edgeCollisionIdx
            break
          end
        end


      end
    end
  end

  local function getSafeTeleportPosRot()
    if ctx.aiState.currentRoute and ctx.aiState.currentRoute.path and ctx.aiState.currentRoute.path[2] then
      local pathIdx = #ctx.aiState.currentRoute.path
      local node = ctx.aiState.currentRoute.path[pathIdx]
      local pos = ctx.aiState.mapData.positions[node]

      local node2 = ctx.aiState.currentRoute.path[pathIdx-1]
      local pos2 = ctx.aiState.mapData.positions[node2]

      local dir = (pos - pos2):normalized()
      local surfaceNormal = mapmgr.surfaceNormalBelow(pos)
      local rot = quatFromDir(-dir:cross(surfaceNormal):cross(surfaceNormal), surfaceNormal) -- minus sign is due to convention used by safeTeleport

      if not ctx.aiState.mapData.graph[node][node2].oneway then
        -- if not a one way road shift the position to the right by half the road radius (ie. 1/4 of the width)
        pos = pos + dir:cross(surfaceNormal):normalized() * (ctx.aiState.mapData.radius[node] * 0.5)
      end

      return pos, rot
    end
  end

  local function scoreClearancePass(sideIdx, kplan, sideGate, mainPlan, minGain, trEps, offsetToTarget, rearEgoPos2TargetPos, lateralDir, egoSqspeed, bestIdx, bestScore)
    if not kplan or not kplan[2] then return bestIdx, bestScore end
    if sideGate <= 0 then return bestIdx, bestScore end
    local dGain = kplan.distances - mainPlan.distances
    local tGain = kplan.trafficTargetSpeed - mainPlan.trafficTargetSpeed
    if dGain < minGain and tGain < trEps then return bestIdx, bestScore end
    offsetToTarget:set((sideIdx == 1 and -0.1 or 0.1) * push3(mainPlan[mainPlan.targetSeg].normal) + rearEgoPos2TargetPos)
    local dSqLengthInv = 1 / (offsetToTarget:squaredLength() + 1e-30)
    local kcurvature = 2 * abs(offsetToTarget:dot(lateralDir)) * dSqLengthInv
    local axSq = square(0.5 * max(egoSqspeed - square(kplan[kplan.targetSeg].speed), 0)) * dSqLengthInv
    if square(mainPlan[1].acc_max) - axSq <= square(egoSqspeed * kcurvature) then return bestIdx, bestScore end
    local score = dGain * 2.2 + tGain * 1.1 + kplan.targetSpeed * 0.08
    if not (score > bestScore) then return bestIdx, bestScore end
    bestScore = score
    bestIdx = sideIdx
    return bestIdx, bestScore
  end

  local function considerRightRaceAlternative(
    mainPlan, plan_index, current_cost, current_trafficSpeed, current_throttle, delta_throttle,
    cost_time, speed_margin, time_margin, egoSqspeed, lateralDir, rearEgoPos2TargetPos,
    offsetToTarget
  )
    do
      local kplan = ctx.aiState.currentRoute.planR
      -- speed_check
      if kplan.targetSpeed < current_cost + speed_margin then goto continue end
      -- time_check: check if alternative plan is faster (minor time)
      if kplan.planLen > (cost_time - time_margin) * kplan.targetSpeed then goto continue end
      -- traffic_check: check if trafficTargetSpeed of alternative plan is greater than current one
      if kplan.trafficTargetSpeed < current_trafficSpeed + speed_margin then goto continue end
      -- throttle_check: check if alternative plan is rising the throttle value (only when I'm not braking or I'm braking for traffic conditions)
      local throttle_check = (ctx.lastCommand.throttle > 0 or mainPlan.targetSpeed == mainPlan.trafficTargetSpeed) and clamp((kplan.targetSpeed - ctx.ego.speed) * ctx.aiState.parameters.throttleKp, 0, 1) > min(current_throttle + delta_throttle, 1)
      if not throttle_check then goto continue end
      -- side_check: avoid overtake if it is against side avoidance manouver
      if ((mainPlan.dispLat and mainPlan.dispLat ~= 0) and mainPlan.dispLat or 1) <= 0 then goto continue end
      -- acc_check: check if overtake respects grip limit
      offsetToTarget:setAddScaled(rearEgoPos2TargetPos, mainPlan[mainPlan.targetSeg].normal, 0.1) -- (targetPos + dispLim) - (ego.pos - ego.length * ego.dirVec)
      local dSqLengthInv = 1 / (offsetToTarget:squaredLength() + 1e-30)
      local kcurvature = 2 * abs(offsetToTarget:dot(lateralDir)) * dSqLengthInv
      local axSq = square(0.5 * max(egoSqspeed - square(kplan[kplan.targetSeg].speed), 0)) * dSqLengthInv
      local acc_check = square(mainPlan[1].acc_max) - axSq <= square(egoSqspeed * kcurvature)
      if acc_check then goto continue end
      -- commit plan
      current_cost = kplan.targetSpeed
      plan_index = 2

      ::continue::
    end
    return plan_index, current_cost
  end

  local function considerLeftRaceAlternative(
    mainPlan, plan_index, current_cost, current_trafficSpeed, current_throttle, delta_throttle,
    cost_time, speed_margin, time_margin, egoSqspeed, lateralDir, rearEgoPos2TargetPos,
    offsetToTarget
  )
    do
      local kplan = ctx.aiState.currentRoute.planL
      -- speed_check
      if kplan.targetSpeed <= current_cost + speed_margin then goto continue end
      -- time_check: check if alternative plan is faster (minor time)
      if kplan.planLen >= (cost_time - time_margin) * kplan.targetSpeed then goto continue end
      -- traffic_check: check if trafficTargetSpeed of alternative plan is greater than current one
      if kplan.trafficTargetSpeed <= current_trafficSpeed + speed_margin then goto continue end
      -- throttle_check: check if alternative plan is rising the throttle value (only when I'm not braking or I'm braking for traffic conditions)
      local throttle_check = (ctx.lastCommand.throttle > 0 or mainPlan.targetSpeed == mainPlan.trafficTargetSpeed) and clamp((kplan.targetSpeed - ctx.ego.speed) * ctx.aiState.parameters.throttleKp, 0, 1) > min(current_throttle + delta_throttle, 1)
      if not throttle_check then goto continue end
      -- side_check: avoid overtake if it is against side avoidance manouver
      if ((mainPlan.dispLat and mainPlan.dispLat ~= 0) and -mainPlan.dispLat or 1) <= 0 then goto continue end
      -- acc_check: check if overtake respects grip limit
      offsetToTarget:setAddScaled(rearEgoPos2TargetPos, mainPlan[mainPlan.targetSeg].normal, -0.1) -- (targetPos + dispLim) - (ego.pos - ego.length * ego.dirVec)
      local dSqLengthInv = 1 / (offsetToTarget:squaredLength() + 1e-30)
      local kcurvature = 2 * abs(offsetToTarget:dot(lateralDir)) * dSqLengthInv
      local axSq = square(0.5 * max(egoSqspeed - square(kplan[kplan.targetSeg].speed), 0)) * dSqLengthInv
      local acc_check = square(mainPlan[1].acc_max) - axSq <= square(egoSqspeed * kcurvature)
      if acc_check then goto continue end
      -- commit plan
      current_cost = kplan.targetSpeed
      plan_index = 1

      ::continue::
    end
    return plan_index, current_cost
  end

  local function selectRaceAlternative(mainPlan)
    -- Search the best plan
    local plan_index
    local current_cost = mainPlan.targetSpeed
    local current_trafficSpeed = mainPlan.trafficTargetSpeed
    local current_throttle = clamp((mainPlan.targetSpeed - ctx.ego.speed) * ctx.aiState.parameters.throttleKp, 0, 1)
    local delta_throttle = linearScale(mainPlan.distances, ctx.ego.length, 3 * ctx.ego.length, ctx.ego.race_dT_min,
      ctx.ego.race_dT_max)
    local cost_time = mainPlan.planLen/max(mainPlan.targetSpeed, 0.1)
    local speed_margin = (type(ctx.aiState.parameters.raceAltPlanSpeedMargin) == 'number' and ctx.aiState.parameters.raceAltPlanSpeedMargin) or 2
    local time_margin = (type(ctx.aiState.parameters.raceAltPlanTimeMargin) == 'number' and ctx.aiState.parameters.raceAltPlanTimeMargin) or 1
    local egoSqspeed = ctx.ego.speed * ctx.ego.speed
    local lateralDir, rearEgoPos2TargetPos, offsetToTarget = getTmpVec3(ctx.ego), getTmpVec3(ctx.ego), getTmpVec3(ctx.ego)
    lateralDir:set(-ctx.ego.dirVec.y, ctx.ego.dirVec.x, 0); lateralDir:normalize()
    rearEgoPos2TargetPos:set(ctx.ego.length * push3(ctx.ego.dirVec) + mainPlan.targetPos - ctx.ego.pos)

    -- check left plan
    plan_index, current_cost = considerLeftRaceAlternative(
      mainPlan, plan_index, current_cost, current_trafficSpeed, current_throttle, delta_throttle,
      cost_time, speed_margin, time_margin, egoSqspeed, lateralDir, rearEgoPos2TargetPos,
      offsetToTarget
    )

    --check right plan
    plan_index, current_cost = considerRightRaceAlternative(
      mainPlan, plan_index, current_cost, current_trafficSpeed, current_throttle, delta_throttle,
      cost_time, speed_margin, time_margin, egoSqspeed, lateralDir, rearEgoPos2TargetPos,
      offsetToTarget
    )

    -- Main line blocked: prefer offset plan with more corridor (distance along plan / traffic cap), even if not faster.
    if plan_index then return plan_index end
    local distMax = (type(ctx.aiState.parameters.raceBlockedAheadDistMax) == 'number' and ctx.aiState.parameters.raceBlockedAheadDistMax) or 28
    local minGain = (type(ctx.aiState.parameters.raceClearancePassMinGainM) == 'number' and ctx.aiState.parameters.raceClearancePassMinGainM) or 0.85
    local trEps = (type(ctx.aiState.parameters.raceClearancePassTrafficEps) == 'number' and ctx.aiState.parameters.raceClearancePassTrafficEps) or 0.65
    local blockedMain = mainPlan.distances < math.huge and mainPlan.distances < distMax
    if not blockedMain then return plan_index end
    local bestIdx, bestScore = nil, -math.huge

    bestIdx, bestScore = scoreClearancePass(1, ctx.aiState.currentRoute.planL, ((mainPlan.dispLat and mainPlan.dispLat ~= 0) and -mainPlan.dispLat or 1), mainPlan, minGain, trEps, offsetToTarget, rearEgoPos2TargetPos, lateralDir, egoSqspeed, bestIdx, bestScore)
    bestIdx, bestScore = scoreClearancePass(2, ctx.aiState.currentRoute.planR, ((mainPlan.dispLat and mainPlan.dispLat ~= 0) and mainPlan.dispLat or 1), mainPlan, minGain, trEps, offsetToTarget, rearEgoPos2TargetPos, lateralDir, egoSqspeed, bestIdx, bestScore)
    plan_index = bestIdx
    return plan_index
  end

  local function holdRaceAlternative(plan_index)
    do
      local candidatePlanIndex = ctx.raceAltPlan.normIdx(plan_index)
      local appliedPlanIndex = ctx.raceAltPlan.normIdx(ctx.aiState.currentRoute.plan_index)
      local elapsedSeconds = ctx.aiState.dt or 0
      local pendingPlanIndex = ctx.aiState.currentRoute._raceAltPlanHystPending

      if candidatePlanIndex == appliedPlanIndex and appliedPlanIndex ~= 0 then
        ctx.aiState.currentRoute._raceAltPlanHystPending = nil
        ctx.aiState.currentRoute._raceAltPlanHystTime = 0
      elseif candidatePlanIndex == 0 and appliedPlanIndex == 0 then
        ctx.aiState.currentRoute._raceAltPlanHystPending = nil
        ctx.aiState.currentRoute._raceAltPlanHystTime = 0
      elseif pendingPlanIndex and candidatePlanIndex ~= 0 and candidatePlanIndex ~= pendingPlanIndex then
        ctx.aiState.currentRoute._raceAltPlanHystPending = candidatePlanIndex
        ctx.aiState.currentRoute._raceAltPlanHystTime = elapsedSeconds
      elseif candidatePlanIndex ~= 0 and candidatePlanIndex == pendingPlanIndex then
        ctx.aiState.currentRoute._raceAltPlanHystTime = (ctx.aiState.currentRoute._raceAltPlanHystTime
          or 0) + elapsedSeconds
      elseif candidatePlanIndex == 0 and appliedPlanIndex ~= 0 then
        ctx.aiState.currentRoute._raceAltPlanHystPending = nil
        ctx.aiState.currentRoute._raceAltPlanHystTime = (ctx.aiState.currentRoute._raceAltPlanHystTime
          or 0) + elapsedSeconds
      elseif candidatePlanIndex ~= 0 and candidatePlanIndex ~= appliedPlanIndex then
        ctx.aiState.currentRoute._raceAltPlanHystPending = candidatePlanIndex
        ctx.aiState.currentRoute._raceAltPlanHystTime = elapsedSeconds
      end

      pendingPlanIndex = ctx.aiState.currentRoute._raceAltPlanHystPending
      local pendingDurationSeconds = ctx.aiState.currentRoute._raceAltPlanHystTime or 0
      if pendingPlanIndex and pendingDurationSeconds >= ctx.raceAltPlan.hystTime and appliedPlanIndex == 0 then
        plan_index = pendingPlanIndex
        candidatePlanIndex = ctx.raceAltPlan.normIdx(plan_index)
      end

      if candidatePlanIndex ~= appliedPlanIndex and pendingDurationSeconds < ctx.raceAltPlan.hystTime then
        if appliedPlanIndex == 0 then
          plan_index = nil
        elseif appliedPlanIndex == 1 then
          plan_index = 1
        else
          plan_index = 2
        end
      end
    end
    return plan_index
  end

  local function commitRaceAlternative(mainPlan, plan_index)
    -- Committ the best plan
    ctx.aiState.currentRoute.reAltplan = false
    mainPlan.prevdistances = mainPlan.distances
    if plan_index then
      ctx.aiState.currentRoute.plan_index = plan_index
      ctx.aiState.currentRoute.offset = plan_index == 1 and ctx.aiState.currentRoute.planL.offset or ctx.aiState.currentRoute.planR.offset
      -- If distance to the vehicle ahead is less than catching distance, I'll push the overtake using targetSpeed from geometry only
      if mainPlan.distances > ctx.ego.race_d then
        mainPlan.targetSpeed = mainPlan.originaltargetSpeed
      end
      -- Monitor distance between targetPos of current plan and desidered plan, do a full switch if my targetPos is too close or goes beyond the desired one
      local targetPos = plan_index == 1 and ctx.aiState.currentRoute.planL.targetPos or ctx.aiState.currentRoute.planR.targetPos
      local targetError = (push3(mainPlan.targetPos) - targetPos):dot(mainPlan[mainPlan.targetSeg].normal)
      if square(targetError) < 0.8 or (plan_index == 1 and targetError < 0) or (plan_index == 2 and targetError > 0) then
        ctx.aiState.currentRoute.reAltplan = true
      end
    else
      ctx.aiState.currentRoute.plan_index = nil
      ctx.aiState.currentRoute.offset = nil
      -- Center hold building a side candidate: keep pending/time. Otherwise clear (lateral→center timer is not stored on nil commit; hold keeps plan_index non-nil until release).
      if not (ctx.aiState.currentRoute._raceAltPlanHystPending and (ctx.aiState.currentRoute._raceAltPlanHystTime or 0) < ctx.raceAltPlan.hystTime) then
        ctx.aiState.currentRoute._raceAltPlanHystPending = nil
        ctx.aiState.currentRoute._raceAltPlanHystTime = 0
      end
    end
  end

  local function prepareRaceAlternatives(mainPlan)
    -- Initialize Left plan
    mainPlan.buildN = true
    if not ctx.aiState.currentRoute.planL then
      ctx.aiState.currentRoute.planL = {}
    end
    -- Initialize Right plan
    if not ctx.aiState.currentRoute.planR then
      ctx.aiState.currentRoute.planR = {}
    end
    if #ctx.aiState.currentRoute.planL == 0 or ctx.aiState.currentRoute.reAltplan then
      parts.copyPlan(ctx.aiState.currentRoute.plan, ctx.aiState.currentRoute.planL)
      parts.offsetPlan(mainPlan, ctx.aiState.currentRoute.planL, 'left')
    end
    parts.planRaceRouteAhead(ctx.aiState.currentRoute, nil, 'left')
    -- create Right plan
    if #ctx.aiState.currentRoute.planR == 0 or ctx.aiState.currentRoute.reAltplan then
      parts.copyPlan(ctx.aiState.currentRoute.plan, ctx.aiState.currentRoute.planR)
      parts.offsetPlan(mainPlan, ctx.aiState.currentRoute.planR, 'right')
    end
    parts.planRaceRouteAhead(ctx.aiState.currentRoute, nil, 'right')
  end

  local function updateManualRacePlans()
    local ALT_PLAN_RADIUS_SQUARED_M2 = 10000
    if not ctx.aiState.currentRoute then return end
    parts.planRaceRouteAhead(ctx.aiState.currentRoute)
    local mainPlan = ctx.aiState.currentRoute.plan
    if not (mainPlan.distancesV < ALT_PLAN_RADIUS_SQUARED_M2) then
      ctx.aiState.currentRoute.offset = nil
      ctx.aiState.currentRoute.plan_index = nil
      ctx.aiState.currentRoute._raceAltPlanHystPending = nil
      ctx.aiState.currentRoute._raceAltPlanHystTime = 0
      mainPlan.buildN = false
      ctx.aiState.currentRoute.reAltplan = true
      return
    end
    if not ctx.raceAltPlan.runAltPlans then return end
    prepareRaceAlternatives(mainPlan)
    local plan_index = selectRaceAlternative(mainPlan)
    plan_index = holdRaceAlternative(plan_index)
    commitRaceAlternative(mainPlan, plan_index)
  end

  local function adjustManualMode()
    if ctx.aiState.validateInput(ctx.aiState.wpList or ctx.aiState.manualPath) then
      parts.newManualPath()
    elseif ctx.aiState.scriptData then
      parts.setScriptedPath(ctx.aiState.scriptData)
      ctx.aiState.scriptData = nil
    end

    if ctx.opt.aggressionMode == 'rubberBand' then
      parts.updatePlayerData()
      if ctx.aiState.player ~= nil then
        if (ctx.ego.pos - ctx.aiState.player.pos):dot(ctx.ego.dirVec) > 0 then
          parts.setAggressionInternal(max(min(0.1 + max((150 - ctx.aiState.player.pos:distance(ctx.ego.pos)) / 150, 0), ctx.M.extAggression), 0.5))
        else
          parts.setAggressionInternal()
        end
      end
    end

    if ctx.opt.racing then


      updateManualRacePlans()
    else
      parts.planAhead(ctx.aiState.currentRoute)
    end
    return false
  end

  local function adjustRandomMode()
    local route
    if not ctx.aiState.currentRoute or ctx.aiState.currentRoute.plan.reRoute or ctx.aiState.currentRoute.plan.planLen + parts.getPathLen(ctx.aiState.currentRoute.path, ctx.aiState.currentRoute.plan[ctx.aiState.currentRoute.plan.planCount].pathidx) < parts.getMinPlanLen() then
      local wp1, wp2 = mapmgr.findClosestRoad(ctx.ego.pos)
      if wp1 == nil or wp2 == nil then
        warningAIDisabled("Could not find a road network, or closest road is too far")
        return true
      end
      ctx.ego.currentSegment[1] = wp1
      ctx.ego.currentSegment[2] = wp2

      if ctx.internalState.road == 'offroad' then
        local vec1 = ctx.aiState.mapData.positions[wp1] - ctx.ego.pos
        local vec2 = ctx.aiState.mapData.positions[wp2] - ctx.ego.pos
        if ctx.ego.dirVec:dot(vec1) > 0 and ctx.ego.dirVec:dot(vec2) > 0 then
          if vec1:squaredLength() > vec2:squaredLength() then
            wp1, wp2 = wp2, wp1
          end
        elseif ctx.ego.dirVec:dot(ctx.aiState.mapData.positions[wp2] - ctx.aiState.mapData.positions[wp1]) > 0 then
          wp1, wp2 = wp2, wp1
        end
      elseif ctx.ego.dirVec:dot(ctx.aiState.mapData.positions[wp2] - ctx.aiState.mapData.positions[wp1]) > 0 then
        wp1, wp2 = wp2, wp1
      end

      local path = ctx.aiState.mapData:getRandomPath(wp1, wp2, ctx.opt.driveInLaneFlag and 1e4 or 1)

      if path and path[1] then
        route = parts.planAhead(path, ctx.aiState.currentRoute)
        if route and route.plan then
          if not ctx.aiState.currentRoute then
            ctx.aiState.currentRoute = route
          else
            local curPlanIdx = ctx.aiState.currentRoute.plan[2].pathidx
            local curPathCount = #ctx.aiState.currentRoute.path
            if curPlanIdx >= curPathCount * 0.9 or (parts.targetsCompatible(ctx.aiState.currentRoute, route) and route.plan.targetSpeed >= ctx.ego.speed) then
              ctx.aiState.currentRoute = route
            end
          end
        end
      end
    end

    if not (ctx.aiState.currentRoute ~= route) then return false end
    parts.planAhead(ctx.aiState.currentRoute)
    return false
  end

  local function findSpanRoutePath(positions, wpFore, wpAft, target, targetLink)
    local path = {}
    while true do
      if not target then
        local maxDist = -math.huge
        local lim = 1
        repeat
          -- get most distant non walked edge
          for k, edgeValue in pairs(ctx.aiState.edgeDict) do
            if not (edgeValue <= lim) then goto nextWalkedEdge end
            if lim > 1 then ctx.aiState.edgeDict[k] = 1 end
            local i = string.find(k, '\0')
            local n1id = string.sub(k, 1, i-1)
            local sqDist = positions[n1id]:squaredDistance(ctx.ego.pos)
            if sqDist > maxDist then
              maxDist = sqDist
              target = n1id
              targetLink = string.sub(k, i+1, #k)
            end
            ::nextWalkedEdge::
          end
          lim = math.huge -- if the first iteration does not produce a target
        until target
      end

      local nodeDegree = 1
      for lid, _ in pairs(ctx.aiState.mapData.graph[target]) do
        -- we're looking for neighboring nodes other than the targetLink
        if lid == targetLink then goto nextNeighbor end
        nodeDegree = nodeDegree + 1
        ::nextNeighbor::
      end
      if nodeDegree == 1 then
        local key = target..'\0'..targetLink
        ctx.aiState.edgeDict[key] = ctx.aiState.edgeDict[key] + 1
      end

      path = ctx.aiState.mapData:spanMap(wpFore, wpAft, target, ctx.aiState.edgeDict, ctx.opt.driveInLaneFlag and 1e7
        or 1)

      if not path[2] and wpFore ~= target then
        -- remove edge from edgeDict list and get a new target (while loop will iterate again)
        ctx.aiState.edgeDict[target..'\0'..targetLink] = nil
        ctx.aiState.edgeDict[targetLink..'\0'..target] = nil
        target = nil
        if next(ctx.aiState.edgeDict) == nil then
          warningAIDisabled("Could not find a path to any of the possible targets")
          return nil, true
        end
      elseif not path[1] then
        warningAIDisabled("No Route Found")
        return nil, true
      else
        -- insert the second edge node in newRoute if it is not already contained
        local pathCount = #path
        if path[pathCount-1] ~= targetLink then path[pathCount+1] = targetLink end
        break
      end
    end
    return path, false
  end

  local function adjustSpanMode()
    if ctx.aiState.currentRoute == nil then
      local positions = ctx.aiState.mapData.positions
      local wpAft, wpFore = mapmgr.findClosestRoad(ctx.ego.pos)
      if not (wpAft and wpFore) then
        warningAIDisabled("Could not find a road network, or closest road is too far")
        return true
      end
      if ctx.ego.dirVec:dot(positions[wpFore] - positions[wpAft]) < 0 then wpAft, wpFore = wpFore, wpAft end

      ctx.ego.currentSegment[1] = wpFore
      ctx.ego.currentSegment[2] = wpAft

      local target, targetLink

      if not (ctx.aiState.edgeDict and ctx.aiState.edgeDict[1]) then
        -- creates the edgeDict and returns a random edge
        target, targetLink = parts.getMapEdges(ctx.M.cutOffDrivability or 0, wpFore)
        if not target then
          warningAIDisabled("No available target with selected characteristics")
          return true
        end
      end

      local path, failed = findSpanRoutePath(positions, wpFore, wpAft, target, targetLink)
      if failed then return true end

      local route = parts.planAhead(path)
      if not route then
        return true
      end
      ctx.aiState.currentRoute = route
    else
      parts.planAhead(ctx.aiState.currentRoute)
    end
    return false
  end

  local function adjustFleeMode()
    parts.updatePlayerData()
    if ctx.aiState.player then
      if ctx.aiState.validateInput() then
        ctx.aiState.targetWPName = ctx.aiState.wpList[1]
        ctx.aiState.wpList = nil
      end

      parts.fleePlan()

      if ctx.internalState.road == 'offroad' then
        local targetPos = ctx.ego.pos + (ctx.ego.pos - ctx.aiState.player.pos) * 100
        local targetSpeed = math.huge
        parts.driveToTarget(targetPos, 1, 0, targetSpeed)
        return true
      end
    else
      return true
    end
    return false
  end

  local function adjustChaseMode()
    parts.updatePlayerData()
    if ctx.aiState.player then
      parts.chasePlan()

      if ctx.internalState.road == 'tail' then
        local plego = ctx.aiState.player.pos - ctx.ego.pos
        local relvel = ctx.ego.vel:dot(plego) - ctx.aiState.player.vel:dot(plego)

        local throttle, brake, targetSpeed = targetFollowControl(ctx.internalState.chaseData.targetSpeed or math.huge)
        if relvel > 0 then
          parts.driveToTarget(ctx.aiState.player.pos + (plego:length() / (relvel + 1e-30)) * ctx.aiState.player.vel, throttle, brake, targetSpeed)
        else
          parts.driveToTarget(ctx.aiState.player.pos, throttle, brake, targetSpeed)
        end
        return true
      elseif ctx.internalState.road == 'offroad' then
        local throttle, brake, targetSpeed = targetFollowControl(ctx.M.mode == 'chase' and math.huge)
        parts.driveToTarget(ctx.aiState.player.pos, throttle, brake, targetSpeed)
        return true
      elseif ctx.aiState.currentRoute == nil then
        parts.driveCar(0, 0, 0, 1)
        return true
      end

    else
      return true
    end
    return false
  end

  local function adjustDerbyMode()
    parts.updatePlayerData()
    if ctx.aiState.player then
      ctx.internalState.road = 'offroad'
      ctx.opt.avoidCars = 'off'

      -- Active contact starts a persistent escape manoeuvre and requests a new target.
      ctx.internalState.derby.checkCollision()

      local throttle, brake = targetFollowControl(math.huge)

      -- Executing the core physics and driving logic replicated from demo_green_derby
      ctx.internalState.derby.driveToTarget(ctx.aiState.player.pos, throttle, brake)
      return true
    else
      parts.driveCar(0, 0, 0, 1)
      return true
    end
    return false
  end

  local function adjustDerbyRecoveryMode()
    parts.updatePlayerData()
    if ctx.aiState.player then
      ctx.internalState.road = 'offroad'
      ctx.opt.avoidCars = 'on' -- Avoid crashing so they don't get stuck out of bounds!
      local throttle, brake = targetFollowControl(math.huge)
      ctx.internalState.derby.driveToTarget(ctx.aiState.player.pos, throttle, brake)
      return true
    else
      parts.driveCar(0, 0, 0, 1)
      return true
    end
    return false
  end

  local function adjustDerbyReverseMode()
    parts.updatePlayerData()
    if ctx.aiState.player then
      ctx.internalState.road = 'offroad'
      ctx.opt.avoidCars = 'off'

      ctx.internalState.derby.checkCollision()
      if ctx.internalState.derby.recoveryTimer > 0 then
        ctx.internalState.derby.driveToTarget(ctx.aiState.player.pos, 1, 0)
        return true
      end

      local plego = ctx.aiState.player.pos - ctx.ego.pos
      local dist = plego:length()
      local targetPos = ctx.aiState.player.pos

      local closingSpd = (ctx.ego.vel - ctx.aiState.player.vel):dot(plego / (dist + 1e-30))

      if ctx.aiState.player.vel:length() > 2 and dist > 10 and dist < 100 then
        local timeToImpact = dist / max(1, closingSpd + ctx.ego.speed)
        timeToImpact = min(timeToImpact, 2.5)
        targetPos = ctx.aiState.player.pos + ctx.aiState.player.vel * timeToImpact
      end

      local targetVec = targetPos - ctx.ego.pos
      targetVec:normalize()
      local dirAngle = asin(ctx.ego.rightVec:dot(targetVec))
      local dirTarget = ctx.ego.dirVec:dot(targetVec)

      local steering = 0
      local brakeAmt = 1  -- brake maps to reverse in arcade mode
      local throttleAmt = 0

      if dirTarget < -0.2 then
        -- Target is behind us! Steer towards it.
        steering = dirAngle * 2
      else
        -- Target is in front, swing the rear around!
        steering = (dirAngle > 0 and -1 or 1)
      end

      -- ensure arcade mode so brake does reverse automatically
      if controller.mainController then
        controller.mainController.setGearboxMode('arcade')
      end

      -- If we are going forward too fast, we brake. If we are stopped or going backwards, we reverse.
      parts.driveCar(max(-1, min(1, steering)), throttleAmt, brakeAmt, 0)
      return true
    else
      parts.driveCar(0, 0, 0, 1)
      return true
    end
    return false
  end

  local function adjustStopMode()
    if ctx.aiState.currentRoute then
      parts.planAhead(ctx.aiState.currentRoute)
      local targetSpeed = max(0, ctx.ego.speed - sqrt(max(0, square(ctx.ego.staticFrictionCoef * gravity) - square(sensors.gx2))) * ctx.aiState.dt) -- TODO: check this calculation, i don't think it does what you think it does
      ctx.aiState.currentRoute.plan.targetSpeed = min(ctx.aiState.currentRoute.plan.targetSpeed, targetSpeed)
      ctx.aiState.currentRoute.plan.targetAcc = - ctx.ego.staticFrictionCoef * gravity
    elseif ctx.ego.vel:dot(ctx.ego.dirVec) > 0 then
      parts.driveCar(0, 0, 0.5, 0)
    else
      parts.driveCar(0, 1, 0, 0)
    end
    if ctx.ego.speed < 0.08 then
      parts.driveCar(0, 0, 0, 1)
      ctx.M.mode = 'disabled'
      ctx.M.manualTargetName = nil
      ctx.M.updateGFX = nop
      parts.resetMapAndRoute()
      parts.stateChanged()
      parts.restoreSavedGearboxMode()
      return true
    end
    return false
  end

  local function adjustManualTrafficMode()
    if ctx.aiState.validateInput(ctx.aiState.wpList or ctx.aiState.manualPath) then
      parts.newManualPath()

    elseif ctx.aiState.scriptData then
      parts.setScriptedPath(ctx.aiState.scriptData)
      ctx.aiState.scriptData = nil
    end

    if ctx.opt.aggressionMode == 'rubberBand' then
      parts.updatePlayerData()
      if ctx.aiState.player ~= nil then
        if (ctx.ego.pos - ctx.aiState.player.pos):dot(ctx.ego.dirVec) > 0 then
          parts.setAggressionInternal(max(min(0.1 + max((150 - ctx.aiState.player.pos:distance(ctx.ego.pos)) / 150, 0), ctx.M.extAggression), 0.5))
        else
          parts.setAggressionInternal()
        end
      end
    end

    -- Manual traffic: use manual planning but add traffic rule enforcement
    parts.planAhead(ctx.aiState.currentRoute)

    -- Initialize traffic states for stop lights and intersections
    if ctx.trafficStates.block.block then
      ctx.trafficStates.block.timer = ctx.trafficStates.block.timer + ctx.aiState.dt
    else
      ctx.trafficStates.block.timer = ctx.trafficStates.block.timer * 0.8
      ctx.trafficStates.block.hornFlag = false
    end

    -- Add traffic actions for stop lights, stop signs, and intersections
    if not ctx.aiState.currentRoute then return false end
    parts.trafficActions()
    return false
  end

  local function modeAdjustments()
    ------------------ RANDOM MODE ----------------
    if ctx.M.mode == 'random' then
      return adjustRandomMode()

    ------------------ TRAFFIC MODE ----------------
    elseif ctx.M.mode == 'traffic' then
      parts.trafficPlan()

    ------------------ MANUAL MODE ----------------
    elseif ctx.M.mode == 'manual' then
      return adjustManualMode()

    ------------------ SPAN MODE ------------------
    elseif ctx.M.mode == 'span' then
      return adjustSpanMode()

    ------------------ FLEE MODE ------------------
    elseif ctx.M.mode == 'flee' then
      return adjustFleeMode()

    ------------------ CHASE MODE ------------------
    elseif ctx.M.mode == 'chase' or ctx.M.mode == 'follow' then
      return adjustChaseMode()
    ------------------ DEMO DERBY MODE ------------------
    elseif ctx.M.mode == 'demoderby' then
      return adjustDerbyMode()

    ------------------ DEMO DERBY RECOVERY MODE ------------------
    elseif ctx.M.mode == 'demoderby_recovery' then
      return adjustDerbyRecoveryMode()

    ------------------ DEMO DERBY REVERSE MODE ------------------
    elseif ctx.M.mode == 'demoderby_reverse' then
      return adjustDerbyReverseMode()

    ------------------ STOP MODE ------------------
    elseif ctx.M.mode == 'stop' then
      return adjustStopMode()
      ------------------ MANUAL TRAFFIC MODE ------------------
    elseif ctx.M.mode == 'manualTraffic' then
      return adjustManualTrafficMode()
    end
    return false
  end

  local function throttleBrakeController(plan)
    local lowTargetSpeedVal = ctx.ego.lowTargetSpeedVal
    local targetSpeedControl = plan.targetSpeed
    -- Compute smoothed speed difference
    local speedDif = targetSpeedControl - ctx.ego.speed
    local rate = ctx.targetSpeedDifSmoother[speedDif > 0 and ctx.targetSpeedDifSmoother.state >= 0 and speedDif >= ctx.targetSpeedDifSmoother.state]
    speedDif = ctx.targetSpeedDifSmoother:getWithRate(speedDif, ctx.aiState.dt, rate)

    -- Learning throttle vs acceleration model
    if ctx.lastCommand.throttle >= 0 and ctx.lastCommand.brake <= 0 and (electrics.values.clutch <= 0 or ctx.ego.speed < 0.5) and ctx.lastCommand.parkingbrake <= 0 then
      ctx.throttleAccModel.biasMax = ctx.ego.dirVec:dot(ctx.gravityDir) * gravity
      ctx.throttleAccModel:get(ctx.lastCommand.throttle, -sensors.gy, ctx.aiState.dt)
    end

    -- Coefficient to scale the acceleration target while approaching targetSpeed
    local decelerationCoef = 0.25 -- strong deceleration for stop mode
    -- Distance to target speed at which we reduce the acceleration target
    local distT = 0.25 * targetSpeedControl
    if ctx.opt.racing then
      local raceKp = type(ctx.aiState.parameters.raceThrottleKp) == 'number' and ctx.aiState.parameters.raceThrottleKp or 1
      local baseKp = type(ctx.aiState.parameters.throttleKp) == 'number' and ctx.aiState.parameters.throttleKp or 0.5
      if raceKp > 0 and baseKp > 0 then
        distT = distT * clamp(baseKp / raceKp, 0.1, 2)
      end
    end
    local accelCoef = speedDif > 0 and linearScale(speedDif, 0, distT, 0, 1) or decelerationCoef * speedDif

    -- target acceleration for throttle vs acceleration model
    local acc_target = plan.targetAcc or min(ctx.aiState.aggression,
      ctx.ego.staticFrictionCoef) * gravity * accelCoef

    -- throttle target
    local throttle_target = ctx.throttleAccModel:getX(acc_target)

    -- Smooth throttle command
    local rateTAM = throttle_target >= ctx.throttleAccModelSmoother.state and linearScale(ctx.aiState.aggression, 0.3, 1, 0.8, 5) or 1e30
    local throttle = ctx.throttleAccModelSmoother:getWithRate(throttle_target, ctx.aiState.dt, rateTAM)

    -- Brake control
    local brake
    if throttle >= 0 and targetSpeedControl >= lowTargetSpeedVal then -- apply constant brake below some targetSpeed
      throttle = min(throttle, 1)
      brake = 0
    else
      throttle = 0
      local brakeLimLow = sign(max(0, lowTargetSpeedVal - targetSpeedControl)) * 0.5
      local arcadeAutoBrakeSwitch = sign(max(0, (electrics.values.smoothShiftLogicAV or 0) - 3)) -- arcade autobrake comes in at |smoothShiftLogicAV| < 5
      brake = clamp(-(acc_target - ctx.throttleAccModel.bias), brakeLimLow, 1) * arcadeAutoBrakeSwitch
    end

    if ctx.opt.racing then
      if speedDif > 0.15 and throttle > 0 then throttle = 1 end
      if brake > 0 then
        local brakeGain = (type(ctx.aiState.parameters.raceBrakeGain) == 'number' and ctx.aiState.parameters.raceBrakeGain) or 0.78
        brake = min(1, brake * clamp(brakeGain, 0.35, 1.25))
      end
    end
    return throttle, brake
  end

  ctx.M.updateGFX = nop
  local function sampleEgoPhysicsState()
    local FRONT_POSITION_DROP_M = 1
    local MIN_RACING_FRICTION_MULTIPLIER = 1.06
    resetTmpVec3(ctx.ego)

    ctx.ego.pos:set(obj:getFrontPositionXYZ())
    ctx.ego.pos.z = max(ctx.ego.pos.z - FRONT_POSITION_DROP_M, obj:getSurfaceHeightBelow(ctx.ego.pos))
    ctx.ego.prevDirVec:set(ctx.ego.dirVec)
    ctx.ego.dirVec:set(obj:getDirectionVectorXYZ())
    ctx.ego.upVec:set(obj:getDirectionVectorUpXYZ())
    ctx.ego.rightVec:setCross(ctx.ego.dirVec, ctx.ego.upVec); ctx.ego.rightVec:normalize()
    ctx.ego.vel:set(obj:getSmoothRefVelocityXYZ())
    ctx.ego.speed = ctx.ego.vel:length()
    ctx.ego.width = ctx.ego.width or obj:getInitialWidth()
    ctx.ego.length = ctx.ego.length or obj:getInitialLength()
    local frictionMult = ctx.aiState.parameters.staticFrictionCoefMult
    if ctx.opt.racing and ctx.aiState.parameters.raceCommitCorners ~= false then
      local rfm = ctx.aiState.parameters.raceFrictionMult
      frictionMult = (type(rfm) == 'number' and rfm > 0) and rfm or max(frictionMult or 1, MIN_RACING_FRICTION_MULTIPLIER)
    end
    ctx.ego.staticFrictionCoef = frictionMult * obj:getStaticFrictionCoef() -- depends on ground model, tire and tire load

    dataLogger.logData()
  end

  local function updateDerbyRecoveryState()
    local derbyMode = ctx.M.mode == 'demoderby' or ctx.M.mode == 'demoderby_reverse' or ctx.M.mode == 'demoderby_recovery'
    if derbyMode then
      ctx.internalState.derby.recoveryCooldown = max(0, ctx.internalState.derby.recoveryCooldown - ctx.aiState.dt)
    end
    local commandedEffort = derbyMode and max(ctx.lastCommand.throttle,
      ctx.lastCommand.brake) or ctx.lastCommand.throttle
    local effortThreshold = derbyMode and 0.25 or 0.5
    if commandedEffort > effortThreshold and ctx.ego.speed < 1 then
      ctx.internalState.egoCannotMoveTime = ctx.internalState.egoCannotMoveTime + ctx.aiState.dt
    else
      ctx.internalState.egoCannotMoveTime = 0
    end

    if derbyMode and ctx.internalState.egoCannotMoveTime > 1.1 then
      ctx.internalState.derby.beginRecovery('stuck')
    elseif derbyMode and ctx.ego.speed > 3 and ctx.internalState.derby.recoveryTimer <= 0 and ctx.internalState.derby.recoveryCooldown <= 0 then
      ctx.internalState.derby.recoveryAttempts = 0
    end
  end

  local function updateTrafficSidePassing()
    local PASS_RAY_HEIGHT_M = 0.5
    if ctx.ego.speed < 3 then
      ctx.trafficStates.side.cTimer = ctx.trafficStates.side.cTimer + ctx.aiState.dt
      ctx.trafficStates.side.timer = (ctx.trafficStates.side.timer + ctx.aiState.dt) % (2 * ctx.trafficStates.side.timerLimit)
      ctx.trafficStates.side.side = sign2(ctx.trafficStates.side.timerLimit - ctx.trafficStates.side.timer)
    else
      ctx.trafficStates.side.cTimer = max(0, ctx.trafficStates.side.cTimer - ctx.aiState.dt)
      ctx.trafficStates.side.timer = 0
      ctx.trafficStates.side.side = 1
    end

    if ctx.trafficStates.side.passLen > 0 and ctx.aiState.currentRoute then
      ctx.trafficStates.side.passLen = max(0, ctx.trafficStates.side.passLen - ctx.ego.speed * ctx.aiState.dt)
      local plan = ctx.aiState.currentRoute.plan
      if not plan[1].tmpPassFlag then
        plan[1].tmpPassFlag = true -- triggers whenever plan node updates
        ctx.trafficStates.side.passMargin = ctx.ego.width * 0.5 -- default pass margin
        local passLen = ctx.trafficStates.side.passLen
        local side = mapmgr.rules.rightHandDrive and -1 or 1
        local rayPoint = getTmpVec3(ctx.ego)
        local rayDir = getTmpVec3(ctx.ego)

        for i = 1, plan.planCount - 1 do
          local n = plan[i]
          if i > 1 then
            rayPoint:setAddScaled(n.posOrig, n.normal, n.halfWidth * side)
            rayPoint.z = rayPoint.z + PASS_RAY_HEIGHT_M
            rayDir:set(n.normal * side)

            local rayDist = obj:castRayStatic(rayPoint, rayDir, ctx.trafficStates.side.passMargin) -- basic static raycast (TODO: offset or noise)
            ctx.trafficStates.side.passMargin = min(ctx.trafficStates.side.passMargin, rayDist) -- actual pass margin due to side obstacles
          end
          passLen = passLen - n.length
          if passLen < 0 then break end
        end
      end
    else
      ctx.trafficStates.side.passMargin = 0
    end
  end

  local function recoverStoppedVehicle()
    local RECOVERY_TIMEOUT_S = 60
    if not (ctx.recover.recoverOnCrash) then return false end
    if ctx.ego.speed < 3 then
      ctx.recover.recoverTimer = ctx.recover.recoverTimer + ctx.aiState.dt
    else
      ctx.recover.recoverTimer = max(0, ctx.recover.recoverTimer - 5 * ctx.aiState.dt)
    end
    if not (ctx.recover._recoverOnCrash or ctx.recover.recoverTimer > RECOVERY_TIMEOUT_S) then return false end
    ctx.recover._recoverOnCrash = false
    ctx.recover.recoverTimer = 0
    local pos, rot = getSafeTeleportPosRot()
    if pos then
      obj:queueGameEngineLua(
        "map.safeTeleport(" .. obj:getId() .. ", " .. pos.x .. ", " .. pos.y .. ", " .. pos.z .. ", " .. rot.x .. ", " .. rot.y .. ", " .. rot.z .. ", " .. rot.w .. ", nil, nil, true, true, true)"
      )
      return true
    end
    return false
  end

  local function updateRouteSteeringAndCrashRecovery(CRASH_DETECTION_DELAY_S, plan, targetPos)
    if ctx.ego.speed < 0.1 and plan.targetSpeed > 0.5 and (ctx.lastCommand.throttle ~= 0 or ctx.lastCommand.brake ~= 0) and ctx.twt.state == 0 and
    not (controller.isFrozen or electrics.values['transbrake'] or (ctx.trafficStates.intersection.action == 3 or ctx.trafficStates.intersection.action == 2)) then

      if ctx.internalState.crash.time == 0 then
        ctx.internalState.crash.pos:set(ctx.ego.pos)
      end
      ctx.internalState.crash.time = ctx.internalState.crash.time + ctx.aiState.dt
      if ctx.internalState.crash.time > CRASH_DETECTION_DELAY_S then
        local diffSq = ctx.ego.pos:squaredDistance(ctx.internalState.crash.pos)
        if diffSq < 0.01 then
          if ctx.recover.recoverOnCrash then
            ctx.recover._recoverOnCrash = true
            ctx.internalState.crash.time = 0
          else
            ctx.internalState.crash.dir:set(ctx.ego.dirVec)
            ctx.internalState.crash.maneuver = 1
          end
        else
          ctx.internalState.crash.time = 0
        end
      end
    end

    -- Throttle and Brake control
    local throttle, brake = throttleBrakeController(plan)

    parts.driveToTarget(targetPos, throttle, brake)
  end

  local function refreshRouteDamageAndChasePosition(plan, egoSeg)
    if not ctx.opt.racing and not ctx.routeLoop.loopPath and plan[egoSeg].pathidx >= 10 and ctx.aiState.currentRoute.path[20]  then
      local path = ctx.aiState.currentRoute.path
      local k = plan[egoSeg].pathidx - 2
      for i = 1, #path do
        path[i] = path[k+i]
      end
      for i = 1, plan.planCount do
        plan[i].pathidx = plan[i].pathidx - k
      end
      -- sync lane change indices
      ctx.aiState.currentRoute.lastLaneChangeIdx = ctx.aiState.currentRoute.lastLaneChangeIdx - k
      for _, laneChange in ipairs(ctx.aiState.currentRoute.laneChanges) do
        laneChange.pathIdx = laneChange.pathIdx - k
      end
      local pathDistK = ctx.aiState.currentRoute.pathLength[k+1]
      for i = 1, #ctx.aiState.currentRoute.pathLength do
        ctx.aiState.currentRoute.pathLength[i] = ctx.aiState.currentRoute.pathLength[k+i] and ctx.aiState.currentRoute.pathLength[k+i] - pathDistK or nil
      end
      -- sync trafficState intersection search index
      if ctx.trafficStates and ctx.trafficStates.intersection and ctx.trafficStates.intersection.startIdx then
        ctx.trafficStates.intersection.startIdx = ctx.trafficStates.intersection.startIdx - k
      end
    end

    ctx.aiState.raceCommit.applyCornerExitPush(plan.targetSpeed, plan, ctx.aiState.dt)
  end

  local function followCurrentRoutePlan()
    local CRASH_DETECTION_DELAY_S = 5
    if not (ctx.aiState.currentRoute) then return end
    local plan = ctx.aiState.currentRoute.plan
    local targetPos = plan and plan.targetPos
    local egoSeg = plan and plan.egoSeg

    -- Discard off-graph one-node plans before stock indexing can fail or hold the brakes indefinitely.
    if not plan or not egoSeg or not plan[egoSeg] then
      ctx.aiState.currentRoute = nil
      return
    end

    -- cleanup path if it has gotten too long
    refreshRouteDamageAndChasePosition(plan, egoSeg)

    if ctx.ego.upVec:dot(ctx.gravityDir) >= -0.2588 then -- vehicle upside down
      parts.driveCar(0, 0, 0, 0)
      return
    end

    if not plan[egoSeg+2] and ((plan.targetSpeed < ctx.ego.lowTargetSpeedVal and ctx.ego.speed < 0.15) or (targetPos - ctx.ego.pos):dot(ctx.ego.dirVec) < 0) then
      if ctx.M.mode == 'span' then
        local path = ctx.aiState.currentRoute.path
        for i = 1, #path - 1 do
          local key = path[i]..'\0'..path[i+1]
          -- in case we have gone over an edge that is not in the edgeDict list
          ctx.aiState.edgeDict[key] = ctx.aiState.edgeDict[key] and (ctx.aiState.edgeDict[key] * 20)
        end
      end

      if ctx.ego.speed < 0.15 then
        parts.driveCar(0, 0, 0, 1)
        parts.aistatus('route done', 'route')
        if dataLogger.logData ~= nop then
          parts.startStopDataLog()
        end
        guihooks.message("Route done", 5, "AI debug")
        obj:queueGameEngineLua('onAiRouteDone('..objectId..')')
        ctx.aiState.currentRoute = nil
      else
        parts.driveCar(0, 0, max(0.3, ctx.lastCommand.brake), 0)
      end
      return
    end

    if electrics.values.ignitionLevel == 3 then
      if ctx.ego.speed < 1.5 then
        parts.driveCar(0, 0, 0, 1)
      end
      return
    end

    updateRouteSteeringAndCrashRecovery(CRASH_DETECTION_DELAY_S, plan, targetPos)
  end

  local function updateGFX(dtGFX)
    if ctx.M.updateGFX ~= updateGFX or gfxGuard.isRepeatCall() then return end
    ctx.aiState.dt = dtGFX

    if ctx.aiState.mapData ~= mapmgr.mapData then
      ctx.aiState.currentRoute = nil
    end

    if mapmgr.changeSet then
      drivabilityChangeReroute()
      mapmgr.changeSet = nil
    end

    ctx.aiState.mapData = mapmgr.mapData
    ctx.aiState.signalsData = mapmgr.signalsData

    if ctx.aiState.mapData == nil and ctx.M.mode ~= 'slotTraffic' then return end

    sampleEgoPhysicsState()

    if ctx.M.mode == 'slotTraffic' then
      ctx.slotTrafficTarget.age = ctx.slotTrafficTarget.age + ctx.aiState.dt
      local targetSpeed = ctx.slotTrafficTarget.age <= 0.5 and ctx.slotTrafficTarget.speed or 0
      local throttle, brake = targetFollowControl(targetSpeed)
      parts.driveToTarget(ctx.slotTrafficTarget.pos, throttle, brake, targetSpeed)
      if ctx.M.debugMode == 'target' or ctx.M.debugMode == 'all' then
        obj.debugDrawProxy:drawSphere(0.25, ctx.slotTrafficTarget.pos, color(255, 0, 0, 255))
      end
      return
    end

    updateDerbyRecoveryState()

    updateTrafficSidePassing()

    if recoverStoppedVehicle() then return end

    ctx.internalState.changePlanTimer = max(0, ctx.internalState.changePlanTimer - ctx.aiState.dt)

    ctx.ego.currentSegment[1] = nil
    ctx.ego.currentSegment[2] = nil

    -- Split out to stay below LuaJIT's 60-upvalue limit.
    if modeAdjustments() then
      return
    end
    -----------------------------------------------

    followCurrentRoutePlan()
  end

  return {
    updateGFX = updateGFX,
  }
end

return lib
