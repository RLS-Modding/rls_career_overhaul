-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this file,
-- You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding

-- Manual and scripted paths, fleeing and pursuit route selection.
-- create binds this extension instance; require caches only the factory.

-- Map, in reading order:
--   map and manual paths: resetMapAndRoute, getMapEdges, newManualPath, setScriptedPath
--   flee: fleePlan
--   chase: updateExistingChaseRoute and chasePlan
--   pull-over state: setPullOver

local lib = {}

function lib.create(ctx)
  -- Locals for speed: this file runs every AI frame.
  local max, min = math.max, math.min
  local tableInsert, tableRemove = ctx.tableInsert, ctx.tableRemove
  local square = ctx.square
  local gravity = ctx.g
  local ego = ctx.ego
  local internalState = ctx.internalState
  local opt = ctx.opt
  local routeLoop = ctx.routeLoop
  -- Functions from the other AI parts that this part calls, read from ctx once when it is created.
  local parts = {
    stateChanged = ctx.stateChanged,
    setSpeed = ctx.setSpeed,
    setSpeedMode = ctx.setSpeedMode,
    setAggressionInternal = ctx.setAggressionInternal,
    setAggressionExternal = ctx.setAggressionExternal,
    resetAggression = ctx.resetAggression,
    resetInternalStates = ctx.resetInternalStates,
    resetParameters = ctx.resetParameters,
    setParameters = ctx.setParameters,
    targetsCompatible = ctx.targetsCompatible,
    getMinPlanLen = ctx.getMinPlanLen,
    pickAiWp = ctx.pickAiWp,
    pathExtend = ctx.pathExtend,
    getPathLen = ctx.getPathLen,
    waypointInPath = ctx.waypointInPath,
    createNewRoute = ctx.createNewRoute,
    planAhead = ctx.planAhead,
  }

  local function resetMapAndRoute()
    ctx.aiState.mapData = nil
    ctx.aiState.signalsData = nil
    -- Keep the active route through mode setup while a replacement is pending.
    -- createPendingRoute owns accepting the replacement or restoring this route.
    if not (ctx.aiState.manualPath or ctx.aiState.wpList) then
      ctx.aiState.currentRoute = nil
    end
    routeLoop.loopPath = nil
    routeLoop.noOfLaps = nil
    internalState.road = 'onroad'
    internalState.changePlanTimer = 0
    parts.resetAggression()
    parts.resetInternalStates()
    parts.resetParameters()
  end

  local function getMapEdges(cutOffDrivability, node)
    -- creates a table (edgeDict) with map edges with drivability > cutOffDrivability
    if ctx.aiState.mapData ~= nil then
      local allSCC = ctx.aiState.mapData:scc(node) -- An array of dicts containing all strongly connected components reachable from 'node'.
      local maxSccLen = 0
      local sccIdx
      for i, scc in ipairs(allSCC) do
        -- finds the scc with the most nodes
        local sccLen = scc[0] -- position at which the number of nodes in currentSCC is stored
        if sccLen > maxSccLen then
          sccIdx = i
          maxSccLen = sccLen
        end
        scc[0] = nil
      end
      local currentSCC = allSCC[sccIdx]
      local keySet = {}
      local keySetLen = 0

      ctx.aiState.edgeDict = {}
      for nid, n in pairs(ctx.aiState.mapData.graph) do
        if currentSCC[nid] or not opt.driveInLaneFlag then
          for lid, data in pairs(n) do
            if (currentSCC[lid] or not opt.driveInLaneFlag) and (data.drivability > cutOffDrivability) then
              local inNode = data.inNode or nid
              local outNode = inNode == nid and lid or nid
              keySetLen = keySetLen + 1
              keySet[keySetLen] = {inNode, outNode}
              ctx.aiState.edgeDict[inNode..'\0'..outNode] = 1
              if not data.inNode or not opt.driveInLaneFlag then
                ctx.aiState.edgeDict[outNode..'\0'..inNode] = 1
              end
            end
          end
        end
      end

      if keySetLen == 0 then return end
      local edge = keySet[math.random(keySetLen)]

      return edge[1], edge[2]
    end
  end

  local function newManualPath()
    local newRoute

    if ctx.aiState.manualPath then
      if ctx.aiState.currentRoute and ctx.aiState.currentRoute.path then
        parts.pathExtend(ctx.aiState.currentRoute.path, ctx.aiState.manualPath)
      else
        newRoute = parts.createNewRoute(ctx.aiState.manualPath)
        ctx.aiState.currentRoute = newRoute
      end
      ctx.aiState.manualPath = nil
    elseif ctx.aiState.wpList then
      if ctx.aiState.currentRoute and ctx.aiState.currentRoute.path then
        newRoute = {
          path = ctx.aiState.currentRoute.path,
          plan = ctx.aiState.currentRoute.plan,
          laneChanges = ctx.aiState.currentRoute.laneChanges,
          lastLaneChangeIdx = ctx.aiState.currentRoute.lastLaneChangeIdx,
          pathLength = ctx.aiState.currentRoute.pathLength
        }
      else
        local path = ctx.aiState.mapData:getPointNodePath(ego.pos, ctx.aiState.wpList[1], nil, nil, nil, nil, 1)

        ego.currentSegment[1] = path[1]
        ego.currentSegment[2] = path[2]

        if not path[1] then
          guihooks.message("Could not find a road network, or closest road is too far", 5, "AI debug")
          log('D', "AI", "Could not find a road network, or closest road is too far")
          return
        end

        if path[2] then
          local xnorm = ego.pos:xnormOnLine(ctx.aiState.mapData.positions[path[1]],
            ctx.aiState.mapData.positions[path[2]])

          if xnorm > 0 and xnorm < 1 then
            tableRemove(path, 1)
          end
        end

        newRoute = parts.createNewRoute(path)
      end

      for i = 1, #ctx.aiState.wpList-1 do
        local wp1 = ctx.aiState.wpList[i] or newRoute.path[#newRoute.path]
        local wp2 = ctx.aiState.wpList[i+1]
        local route = ctx.aiState.mapData:getPath(wp1, wp2, opt.driveInLaneFlag and 1e4 or 1)
        local routeLen = #route
        if routeLen == 0 or (routeLen == 1 and wp2 ~= wp1) then
          guihooks.message("Path between waypoints '".. wp1 .."' - '".. wp2 .."' Not Found", 7, "AI debug")
          log('D', "AI", "Path between waypoints '".. wp1 .."' - '".. wp2 .."' Not Found")
          return
        end

        for j = 2, routeLen do
          tableInsert(newRoute.path, route[j])
        end
      end

      ctx.aiState.wpList = nil

      ctx.aiState.currentRoute = newRoute
    end
  end

  -- Finish a requested replacement before its caller releases vehicle controls.
  -- Never extend/mutate the previous route while trying a new destination.
  local function createPendingRoute()
    local requested = ctx.aiState.wpList or ctx.aiState.manualPath
    local target
    local previous = ctx.aiState.currentRoute
    ctx.aiState.currentRoute = nil
    -- validateInput is the validator installed by setPath/driveUsingPath.
    if requested and requested[1] and ctx.aiState.mapData and ctx.aiState.validateInput(requested) then
      target = requested[#requested]
      newManualPath()
    end
    local route = ctx.aiState.currentRoute
    local accepted = route ~= nil and route ~= previous and route.path ~= nil
      and route.path[#route.path] == target
    if not accepted then ctx.aiState.currentRoute = previous end
    ctx.aiState.wpList, ctx.aiState.manualPath = nil, nil
    ctx.aiState.validateInput = nop
    return accepted
  end

  local function setScriptedPath(arg)
    mapmgr.setCustomMap(arg.mapData)
    ctx.aiState.mapData = mapmgr.mapData

    parts.setParameters({
      driveStyle = arg.driveStyle or 'default',
      staticFrictionCoefMult = max(0.95, arg.staticFrictionCoefMult or 0.95),
      lookAheadKv = max(0.1, arg.lookAheadKv or ctx.aiState.parameters.lookAheadKv),
      planErrorSmoothing = false,
      avoidCars = arg.avoidCars,
      understeerThrottleControl = arg.understeerThrottleControl,
      oversteerThrottleControl = arg.oversteerThrottleControl,
      throttleTcs = arg.throttleTcs,
      abBrakeControl = arg.abBrakeControl,
      underSteerBrakeControl = arg.underSteerBrakeControl,
      throttleKp = arg.throttleKp,
      targetSpeedSmootherRate = arg.targetSpeedSmootherRate,
      springForceIntegratorDispLim = arg.springForceIntegratorDispLim,
      turnForceCoef = arg.turnForceCoef})
    if type(arg.racingParameters) == 'table' then parts.setParameters(arg.racingParameters) end

    opt.avoidCars = arg.avoidCars or 'off'
    routeLoop.noOfLaps = arg.noOfLaps
    routeLoop.loopPath = arg.loopPath
    parts.setSpeed(arg.routeSpeed)
    parts.setSpeedMode(arg.routeSpeedMode)
    parts.setAggressionExternal(arg.aggression)

    if arg.speedProfile and next(arg.speedProfile) then
      ctx.aiState.speedProfile = arg.speedProfile
    end

    ctx.aiState.currentRoute = parts.createNewRoute(arg.path) -- {path = arg.path, plan = {}}

    parts.stateChanged()
  end

  local function validateUserInput(list)
    ctx.aiState.validateInput = nop
    list = list or ctx.aiState.wpList
    if not list then return end
    local isValid = list[1] and true or false
    for i = 1, #list do -- #wpList
      local nodeAlias = mapmgr.nodeAliases[list[i]]
      if nodeAlias then
        if ctx.aiState.mapData.graph[nodeAlias] then
          list[i] = nodeAlias
        else
          if isValid then
            guihooks.message("One or more of the waypoints were not found on the map. Check the game console for more info.", 6, "AI debug")
            log('D', "AI", "The waypoints with the following names could not be found on the Map")
            isValid = false
          end
        end
      end
    end

    return isValid
  end

  local function fleePlan()
    if opt.aggressionMode == 'rubberBand' then
      parts.setAggressionInternal(max(0.3, 0.95 - 0.0015 * ctx.aiState.player.pos:distance(ego.pos)))
    end

    -- extend the plan if possible and desirable
    if ctx.aiState.currentRoute and not ctx.aiState.currentRoute.plan.reRoute then
      local plan = ctx.aiState.currentRoute.plan
      if ego.pos:dot(ego.dirVec) >= ctx.aiState.player.pos:dot(ego.dirVec) and not ctx.aiState.targetWPName and internalState.road ~= 'offroad' and plan.trafficMinProjSpeed > 3 then
        local path = ctx.aiState.currentRoute.path
        local pathCount = #path
        if pathCount >= 3 and plan[2].pathidx > pathCount * 0.7 then
          local cr1 = path[pathCount-1]
          local cr2 = path[pathCount]
          local dirVec = (push3(ctx.aiState.mapData.positions[cr2]) - ctx.aiState.mapData.positions[cr1]):normalized():copy()
          parts.pathExtend(path, ctx.aiState.mapData:getFleePath(cr2, dirVec, ctx.aiState.player.pos, parts.getMinPlanLen(), 0.01, 0.01))
          parts.planAhead(ctx.aiState.currentRoute)
          return
        end
      end
    end

    if not ctx.aiState.currentRoute or internalState.changePlanTimer == 0 or ctx.aiState.currentRoute.plan.reRoute then
      local wp1, wp2 = mapmgr.findClosestRoad(ego.pos)
      if wp1 == nil or wp2 == nil then
        internalState.road = 'offroad'
        return
      else
        internalState.road = 'onroad'
      end

      ego.currentSegment[1] = wp1
      ego.currentSegment[2] = wp2

      local dirVec
      if ctx.aiState.currentRoute and ctx.aiState.currentRoute.plan.trafficMinProjSpeed < 3 then
        internalState.changePlanTimer = 5
        dirVec = -ego.dirVec
      else
        dirVec = ego.dirVec
      end

      local startnode = parts.pickAiWp(wp1, wp2, dirVec)
      local path
      if not ctx.aiState.targetWPName then
        path = ctx.aiState.mapData:getFleePath(startnode, dirVec, ctx.aiState.player.pos, parts.getMinPlanLen(), 0.01,
          0.01)
      else -- flee to destination
        path = ctx.aiState.mapData:getPathAwayFrom(startnode, ctx.aiState.targetWPName, ego.pos, ctx.aiState.player.pos)
        if next(path) == nil then
          ctx.aiState.targetWPName = nil
        end
      end

      if not path[1] then
        internalState.road = 'offroad'
        return
      else
        internalState.road = 'onroad'
      end

      local route = parts.planAhead(path, ctx.aiState.currentRoute)
      if route and route.plan then
        local tempPlan = route.plan
        if not ctx.aiState.currentRoute or internalState.changePlanTimer > 0 or tempPlan.targetSpeed >= min(ego.speed, ctx.aiState.currentRoute.plan.targetSpeed) and parts.targetsCompatible(ctx.aiState.currentRoute, route) then
          ctx.aiState.currentRoute = route
          internalState.changePlanTimer = max(1, internalState.changePlanTimer)
          return
        elseif ctx.aiState.currentRoute.plan.reRoute then
          ctx.aiState.currentRoute = route
          internalState.changePlanTimer = max(1, internalState.changePlanTimer)
          return
        end
      end
    end

    parts.planAhead(ctx.aiState.currentRoute)
  end

  local function adjustChaseTargetSpeed(wp1, wp2, plwp1, plwp2, playerSpeed, playerVel, playerNodeInPath)
    local route
    if not playerNodeInPath and not internalState.chaseData.driveAhead and (ego.speed < 3 or ego.dirVec:dot(ctx.aiState.player.pos - ego.pos) > 0) then -- prevents ego from cancelling its current route if it should slow down to turn around
      local path = ctx.aiState.mapData:getChasePath(wp1, wp2, plwp1, plwp2, ego.pos, ego.vel, ctx.aiState.player.pos, ctx.aiState.player.vel, opt.driveInLaneFlag and 1e4 or 1)

      route = parts.planAhead(path, ctx.aiState.currentRoute) -- ignore current route if path should go other way
      if route and route.plan then --and tempPlan.targetSpeed >= min(ego.speed, curPlan.targetSpeed) and (tempPlan.targetPos-curPlan.targetPos):dot(ego.dirVec) >= 0 then
        ctx.aiState.currentRoute = route
      end
    end

    local pathLen = parts.getPathLen(ctx.aiState.currentRoute.path, playerNodeInPath or math.huge) -- curPlan[2].pathidx
    local playerMinPlanLen = parts.getMinPlanLen(0, playerSpeed)
    if ctx.M.mode == 'chase' and pathLen < playerMinPlanLen then -- chase path should be extended
      local pathCount = #ctx.aiState.currentRoute.path
      local fleePath = ctx.aiState.mapData:getFleePath(ctx.aiState.currentRoute.path[pathCount], playerVel, ctx.aiState.player.pos, playerMinPlanLen, 0, 0)
      if fleePath[2] ~= wp1 and fleePath[2] ~= wp2 and fleePath[2] ~= ctx.aiState.currentRoute.path[pathCount - 1] then -- only extend the path if it does not do a u-turn
        parts.pathExtend(ctx.aiState.currentRoute.path, fleePath)
      end
    end

    if not route then
      parts.planAhead(ctx.aiState.currentRoute)
    end

    local targetSpeed
    return targetSpeed
  end

  local function extendChaseRoute(positions, radii, plwp1, plwp2, playerSpeed, curPlan, playerIncoming, playerBehind)
    if not playerIncoming and (plwp2 == ctx.aiState.currentRoute.path[curPlan[2].pathidx] or plwp2 == ctx.aiState.currentRoute.path[curPlan[2].pathidx + 1]) then -- player is matching ego target node
      local playerNodePos1 = positions[plwp2]
      local segDir = playerNodePos1 - positions[plwp1]
      local targetLineDir = vec3(-segDir.y, segDir.x, 0); targetLineDir:normalize()
      local xnorm1 = closestLinePointsPointVec(playerNodePos1, targetLineDir, ctx.aiState.player.pos,
        ctx.aiState.player.dirVec)
      local xnorm2 = closestLinePointsPointVec(playerNodePos1, targetLineDir, ego.pos, ego.dirVec)
      -- player xnorm and ego xnorm get interpolated here
      local tarPos = playerNodePos1 + targetLineDir * clamp(lerp(xnorm1, xnorm2, 0.5), -radii[plwp2], radii[plwp2])

      local p2Target = tarPos - ctx.aiState.player.pos; p2Target:normalize()
      local plVel2Target = playerSpeed > 0.1 and ctx.aiState.player.vel:dot(p2Target) or 0
      local plTimeToTarget = tarPos:distance(ctx.aiState.player.pos) / (plVel2Target + 1e-30)

      local egoVel2Target = ego.speed > 0.1 and ego.vel:dot((tarPos - ego.pos):normalized()) or 0
      local egoTimeToTarget = tarPos:distance(ego.pos) / (egoVel2Target + 1e-30)

      if egoTimeToTarget < plTimeToTarget and not playerBehind then
        internalState.road = 'tail'
      end
    end
  end

  local function updateExistingChaseRoute(positions, radii, wp1, wp2, plwp1, plwp2, playerNode, playerSpeed, playerVel, egoPlDist, egoPosRear, nearDist, isAtPlayerSeg)
    local FOLLOW_SPEED_DISTANCE_M = 120
    local DIRECT_CHASE_DISTANCE_M = 25
    local curPlan = ctx.aiState.currentRoute.plan
    local playerNodeInPath = parts.waypointInPath(ctx.aiState.currentRoute.path, playerNode,
      curPlan[2].pathidx) or false

    local planVec = curPlan[2].pos - curPlan[1].pos
    local playerIncoming = playerSpeed >= 3 and playerNode == wp1 and egoPlDist < max(ego.speed, playerSpeed) and playerVel:dot(planVec) < 0 -- player is driving towards or past ego on the segment
    local playerBehind = playerSpeed >= 3 and planVec:dot(playerVel) > 0 and ego.dirVec:dot(egoPosRear - ctx.aiState.player.pos) > 0 -- player got passed by ego
    local playerOtherWay = not playerNodeInPath and planVec:dot(positions[playerNode] - ego.pos) < 0 and (playerSpeed < 3 or playerVel:dot(ctx.aiState.player.pos - ego.pos) > 0) -- player is driving other way from ego

    local targetSpeed = adjustChaseTargetSpeed(wp1, wp2, plwp1, plwp2, playerSpeed, playerVel, playerNodeInPath)

    if ctx.M.mode == 'chase' then
      local brakeDist = square(ego.speed) / (2 * gravity * ctx.aiState.aggression)
      local relSpeed = playerVel:dot(ego.dirVec)
      local crashSpeed = (type(ctx.aiState.parameters.chaseCrashSpeed) == 'number' and ctx.aiState.parameters.chaseCrashSpeed) or 10
      if egoPlDist < max(brakeDist, nearDist) and ego.dirVec:dot(egoPosRear - ctx.aiState.player.pos) < 0 then
        targetSpeed = max(crashSpeed, relSpeed + crashSpeed)
        internalState.chaseData.targetSpeed = targetSpeed
      end
    end

    if not internalState.chaseData.driveAhead then
      if playerIncoming or playerOtherWay then -- come to a stop, then plan to turn around
        targetSpeed = 0
      elseif playerBehind then -- match the player speed based on distance
        targetSpeed = clamp(playerSpeed * (1 - egoPlDist / FOLLOW_SPEED_DISTANCE_M), 5, max(5, curPlan[2].speed))
      end
    end
    curPlan.targetSpeed = targetSpeed or curPlan.targetSpeed

    if ctx.M.mode == 'chase' then
      internalState.road = 'onroad'

      if playerIncoming then -- player is head on versus ego
        internalState.road = 'tail'
      elseif egoPlDist < DIRECT_CHASE_DISTANCE_M and ego.dirVec:dot((ego.pos - ego.dirVec * ego.length) - ctx.aiState.player.pos) < 0 then -- player is near ego, but ego path does a u-turn
        local uTurn = false
        for i, pathNode in ipairs(ctx.aiState.currentRoute.path) do -- detect path u-turn
          if pathNode == playerNode then break end
          if i > 2 and ego.dirVec:dot(positions[pathNode] - positions[ctx.aiState.currentRoute.path[i - 1]]) < 0 then
            uTurn = true
            break
          end
        end
        if uTurn then
          -- cast a ray to see if ego can directly attack player without hitting a barrier
          if obj:castRayStatic(ego.pos + ego.upVec * 0.5, (ego.pos - ctx.aiState.player.pos) / (egoPlDist + 1e-30), egoPlDist) >= egoPlDist then
            internalState.road = 'tail'
            if isAtPlayerSeg then -- important to reset the route here
              ctx.aiState.currentRoute = nil
              return
            end
          end
        end
      end
      extendChaseRoute(positions, radii, plwp1, plwp2, playerSpeed, curPlan, playerIncoming, playerBehind)
    end

    if not (internalState.chaseData.playerState == 'stopped') then return end
    ctx.aiState.currentRoute.plan.targetSpeed = 0
  end

  local function observeChaseProximity(NEAR_PLAYER_PADDING_M, wp1, wp2, playerSpeed, playerNode)
    local egoPlDist = ego.pos:distance(ctx.aiState.player.pos) -- should this be a signed distance?
    local egoPosRear = ego.pos - ego.dirVec * ego.length
    local nearDist = max(ego.length + NEAR_PLAYER_PADDING_M, internalState.chaseData.playerStoppedTimer) -- larger if player stopped for longer (anti softlock)
    local isAtPlayerSeg = (wp1 == playerNode or wp2 == playerNode)

    if opt.aggressionMode == 'rubberBand' then
      if ctx.M.mode == 'follow' then
        parts.setAggressionInternal(min(0.75, 0.3 + 0.0025 * egoPlDist))
      else
        parts.setAggressionInternal(min(0.95, 0.8 + 0.0015 * egoPlDist))
      end
    end

    -- consider calculating the aggression value but then passing it through a smoother so that transitions between chase mode and follow mode are smooth

    if playerSpeed < 1 then
      internalState.chaseData.playerStoppedTimer = internalState.chaseData.playerStoppedTimer + ctx.aiState.dt
    else
      internalState.chaseData.playerStoppedTimer = 0
    end
    return egoPlDist, egoPosRear, nearDist, isAtPlayerSeg
  end

  local function chasePlan()
    local STILL_PLAYER_SPEED_MPS = 1
    local NEAR_PLAYER_PADDING_M = 8
    local STOPPED_PLAYER_DELAY_S = 5
    local DRIVE_AHEAD_RELEASE_SPEED_MPS = 10
    local positions = ctx.aiState.mapData.positions
    local radii = ctx.aiState.mapData.radius

    internalState.chaseData.targetSpeed = nil

    local wp1, wp2, dist1 = mapmgr.findBestRoad(ego.pos, ego.dirVec)
    if wp1 == nil or wp2 == nil then
      internalState.road = 'offroad'
      return
    end

    local playerSpeed = ctx.aiState.player.vel:length()
    local playerVel = playerSpeed > STILL_PLAYER_SPEED_MPS and ctx.aiState.player.vel or ctx.aiState.player.dirVec -- uses dirVec for very low speeds

    local plwp1, plwp2, dist2 = mapmgr.findBestRoad(ctx.aiState.player.pos, playerVel)
    if plwp1 == nil or plwp2 == nil then
      internalState.road = 'offroad'
      return
    end

    if positions[wp2]:dot(ego.dirVec) < positions[wp1]:dot(ego.dirVec) then wp1, wp2 = wp2, wp1 end
    -- wp2 is next node for ego to drive to

    ego.currentSegment[1] = wp1
    ego.currentSegment[2] = wp2

    if (playerVel / (playerSpeed + 1e-30)):dot(positions[plwp2] - positions[plwp1]) < 0 then plwp1, plwp2 = plwp2, plwp1 end
    -- plwp2 is next node that player is driving to

    if dist1 > max(radii[wp1], radii[wp2]) + ego.width and dist2 > max(radii[plwp1], radii[plwp2]) + obj:getObjectInitialWidth(ctx.aiState.player.id) then
      internalState.road = 'offroad'
      return
    end

    local playerNode = plwp2
    local egoPlDist, egoPosRear, nearDist, isAtPlayerSeg = observeChaseProximity(
      NEAR_PLAYER_PADDING_M, wp1, wp2, playerSpeed, playerNode
    )

    if internalState.chaseData.playerStoppedTimer > STOPPED_PLAYER_DELAY_S and egoPlDist < max(nearDist, square(ego.speed) / (2 * gravity * ctx.aiState.aggression)) then -- within braking distance to player
      internalState.chaseData.playerState = 'stopped'

      if ego.speed < 0.3 and egoPlDist < nearDist then
        -- do not plan new route if stopped near player
        ctx.aiState.currentRoute = nil
        internalState.road = 'onroad'
        return
      end
    else
      internalState.chaseData.playerState = nil
    end

    if internalState.chaseData.driveAhead and ego.speed >= DRIVE_AHEAD_RELEASE_SPEED_MPS then -- unset this flag if the ego reached a minimum speed
      internalState.chaseData.driveAhead = false
    end

    if ctx.M.mode == 'follow' and ego.speed < 0.3 and isAtPlayerSeg and egoPlDist < nearDist then
      -- do not plan new route if ego reached player
      ctx.aiState.currentRoute = nil
      internalState.road = 'onroad'
      return
    end

    if ctx.aiState.currentRoute then
      updateExistingChaseRoute(positions, radii, wp1, wp2, plwp1, plwp2, playerNode, playerSpeed, playerVel, egoPlDist, egoPosRear, nearDist, isAtPlayerSeg)
    else
      local path
      if ctx.M.mode == 'chase' and ego.dirVec:dot(playerVel) > 0 and ego.dirVec:dot(egoPosRear - ctx.aiState.player.pos) > 0 then
        path = ctx.aiState.mapData:getFleePath(wp2, playerVel, ctx.aiState.player.pos, parts.getMinPlanLen(100, ego.speed), 0, 0)
        internalState.chaseData.driveAhead = true
      else
        path = ctx.aiState.mapData:getChasePath(wp1, wp2, plwp1, plwp2, ego.pos, ego.vel, ctx.aiState.player.pos, ctx.aiState.player.vel, opt.driveInLaneFlag and 1e4 or 1)
        internalState.chaseData.driveAhead = false
      end

      local route = parts.planAhead(path)
      if route and route.plan then
        ctx.aiState.currentRoute = route
      end
    end
  end

  ctx.M.pullOver = false
  local function setPullOver(val)
    ctx.M.pullOver = val
  end

  return {
    resetMapAndRoute = resetMapAndRoute,
    getMapEdges = getMapEdges,
    newManualPath = newManualPath,
    createPendingRoute = createPendingRoute,
    setScriptedPath = setScriptedPath,
    validateUserInput = validateUserInput,
    fleePlan = fleePlan,
    chasePlan = chasePlan,
    setPullOver = setPullOver,
  }
end

return lib
