-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- The hired-cab facade owns instance state, Overhaul guards and public bindings.
-- Each factory call creates fresh runtime functions and scratch values.
-- Part of the Overhaul fork of stock lua/ge/extensions/gameplay/taxi.lua (BeamNG 0.40).

local recordRide = require("overhaul/lib/progression/logbookFeed").register("overhaul.taxiRideTaken", {
  title = "Taxi ride taken", label = "Travel", icon = "carCoins"
}, "integration/services/taxi/core.lua")

local lib = {}

-- Keep the figure through departure; 150 m puts the small occupant beyond a clear kerbside view.
local DRIVER_RELEASE_DISTANCE_METERS = 150
local DRIVER_CHECK_INTERVAL_SECONDS = 1

function lib.create(ctx)
  local departingDrivers = {}
  local driverCheckTimer = 0

  local function updateDepartingDrivers(dtReal)
    if not next(departingDrivers) then return end
    driverCheckTimer = driverCheckTimer + dtReal
    if driverCheckTimer < DRIVER_CHECK_INTERVAL_SECONDS then return end
    driverCheckTimer = 0
    local playerVeh = be:getPlayerVehicle(0)
    if not playerVeh and gameplay_walk and gameplay_walk.getCurrentUnicycle then
      playerVeh = gameplay_walk.getCurrentUnicycle()
    end
    local playerPos = playerVeh and playerVeh:getPosition()
    for id in pairs(departingDrivers) do
      local veh = getObjectByID(id)
      if not veh or (playerPos and veh:getPosition():distance(playerPos) > DRIVER_RELEASE_DISTANCE_METERS) then
        departingDrivers[id] = nil
        ctx.setCabDriver(id, false)
      end
    end
  end

  local function resetPlayerData()
    ctx.player.nearestTaxiId = nil
    ctx.player.currentTaxiId = nil
    ctx.player.currentPhase = ctx.playerRidePhases.none
    ctx.player.destinationPos = nil
    ctx.player.cameraBeforeTaxi = nil
    ctx.player.rideCamera = nil
    ctx.player.idleCameraTimer = 0
    ctx.player.disableIdleCamera = false
    ctx.player.chooseResumeMode = nil
    ctx.player.dropoffKickTimer = 0
    ctx.player.skipPosition = nil
    ctx.player.skipRotation = nil
    ctx.player.hasSkipped = false
    ctx.player.totalRouteDistance = 0
    ctx.player.hurryUpLevel = 1
    ctx.player.taxiViewActive = false
    ctx.player.uiUpdateTimer = 0
    ctx.player.persistentMessage = nil
    ctx.player.arrivalApproachActive = false
    ctx.player.arrivalApproachSpeed0 = nil
    ctx.player.arrivalApproachDist0 = nil
    ctx.player.arrivalSpeedCap = nil
    ctx.player.arrivalCommitted = false
    ctx.player.routePlanner:clear()
    table.clear(ctx.player.pickupTaxis)
    ctx.player.fare = 0
    ctx.player.fareCalculator = nil
    ctx.player.fareData = nil
    ctx.player.triggerMessingStrikes = 0
  end

  -- remaining route distance from vehPos: straight-line to the first path node plus that node's
  -- distance to the target. Returns nil if the planner has no path or vehPos is missing.
  local function routeDistanceLeft(planner, vehPos)
    local routeNodes = planner and planner.path
    if not (routeNodes and routeNodes[1] and vehPos) then return nil end
    return vehPos:distance(routeNodes[1].pos) + routeNodes[1].distToTarget
  end

  local function getDistanceLeft()
    local veh = ctx.player.currentTaxiId and getObjectByID(ctx.player.currentTaxiId)
    if not veh then return 0 end
    return routeDistanceLeft(ctx.player.routePlanner, veh:getPosition()) or 0
  end

  -- Cap the commit distance so a fast cab still sheds speed during its approach.
  local function getCommitStopDist(veh)
    local speed = veh:getVelocity():len()
    return clamp(speed * speed / (2 * 9.81 * ctx.arrivalAggression),
      ctx.arrivalMinStopDistanceMeters, ctx.arrivalMaxCommitDistanceMeters)
  end

  -- Speed ceiling partway through the approach, easing from the speed the taxi was doing when the
  -- approach began down to the arrival speed at the commit point.
  local function getApproachSpeedCap(initialSpeedMetersPerSecond, initialDistanceMeters, distanceLeftMeters)
    local approachSpanMeters = (initialDistanceMeters or 0) - ctx.arrivalMinStopDistanceMeters
    if approachSpanMeters <= 0 then return ctx.arrivalApproachSpeedMetersPerSecond end
    local approachProgress = clamp((distanceLeftMeters - ctx.arrivalMinStopDistanceMeters) / approachSpanMeters, 0, 1)
    local approachStartSpeedMetersPerSecond =
      math.max(initialSpeedMetersPerSecond or 0, ctx.arrivalApproachSpeedMetersPerSecond)
    local arrivalSpeedSquared = ctx.arrivalApproachSpeedMetersPerSecond * ctx.arrivalApproachSpeedMetersPerSecond
    return math.sqrt(arrivalSpeedSquared + (approachStartSpeedMetersPerSecond * approachStartSpeedMetersPerSecond - arrivalSpeedSquared) * approachProgress)
  end

  local function applyApproachSpeedCap(veh, cap)
    veh:queueLuaCommand(string.format('ai.setSpeed(%.2f) ai.setSpeedMode("limit")', cap))
  end

  local function clearApproachSpeedCap(veh)
    veh:queueLuaCommand('ai.setSpeedMode("off")')
  end

  local function isTaxiCrashed(vehId)
    local trafficVeh = gameplay_traffic.getTrafficData()[vehId]
    return trafficVeh and trafficVeh.activeData and trafficVeh.activeData.tCrash ~= nil or false
  end

  local function getTaxiViewData()
    local distLeft = getDistanceLeft()
    local isDriving = ctx.player.currentPhase == ctx.playerRidePhases.driving
    local isChoosing = ctx.player.currentPhase == ctx.playerRidePhases.choosingDestination
    local isArriving = ctx.player.currentPhase == ctx.playerRidePhases.arriving
    return {
      playerCurrentPhase = ctx.player.currentPhase,
      hasDestination = isDriving,
      canHurryUp = isDriving and ctx.player.hurryUpLevel < #ctx.hurryUpLevels,
      canSlowDown = isDriving and ctx.player.hurryUpLevel > 1,
      hurryUpLevel = ctx.player.hurryUpLevel - 1,
      hurryUpMax = #ctx.hurryUpLevels - 1,
      canSkip = isDriving and ctx.player.skipPosition ~= nil and not ctx.player.hasSkipped
        and not isTaxiCrashed(ctx.player.currentTaxiId),
      canChangeDestination = isDriving or isChoosing or isArriving,
      canStop = isDriving or (isArriving and ctx.taxis[ctx.player.currentTaxiId] == "pullingOverForDropoff"),
      distanceLeft = distLeft,
      totalDistance = ctx.player.totalRouteDistance,
      message = ctx.player.persistentMessage,
      idleCameraEnabled = ctx.player.idleCameraUserEnabled,
      currentFare = ctx.player.fareData and ctx.player.fare or nil,
    }
  end

  local function pushTaxiUIUpdate(message)
    if not ctx.player.taxiViewActive then return end
    if message then ctx.player.persistentMessage = message end
    local data = getTaxiViewData()
    guihooks.queueStream("taxi", data)
  end

  local function showMessage(message, clear, ttl)
    if clear == nil then clear = true end
    local helper = {
      ttl = ttl or 2,
      msg = message,
      category = "taxiNearby",
      clear = clear
    }
    guihooks.trigger('Message',helper)
  end

  local function activateSignal(veh, rightForRightHand)
    local isRightHand = map.getRoadRules().rightHandDrive
    local useRight = (isRightHand and rightForRightHand) or (not isRightHand and not rightForRightHand)
    -- autoCancel = false so the AI's steering during the maneuver doesn't self-cancel the signal
    veh:queueLuaCommand('electrics.set_' .. (useRight and 'left' or 'right') .. '_signal(true, false)')
  end

  local function activatePullOverBlinkers(veh)
    activateSignal(veh, true)
  end

  local function activateMergeBlinkers(vehId)
    ctx.createTaxiJob(function(job)
      -- wait a frame so any signal-off commands from a preceding state change run first
      job.yield()
      local v = getObjectByID(vehId)
      if not v then return end
      activateSignal(v, false)
      job.sleep(ctx.blinkersDurationSeconds)
      v = getObjectByID(vehId)
      if v then v:queueLuaCommand('electrics.stop_turn_signal()') end
    end, 1)
  end


  local function setIdleCamera(value)
    if value == ctx.player.idleCameraActive then return end
    ctx.player.idleCameraActive = value
    ctx.player.idleCameraJobToken = ctx.player.idleCameraJobToken + 1
    local myToken = ctx.player.idleCameraJobToken
    if value then
      ctx.createTaxiJob(function(job)
        ui_fadeScreen.start(ctx.fadeToBlackDurationSeconds)
        job.sleep(ctx.fadeToBlackDurationSeconds+0.1)
        if myToken ~= ctx.player.idleCameraJobToken then
          ui_fadeScreen.stop(ctx.fadeToBlackDurationSeconds)
          return
        end
        core_camera.setByName(0, "external")
        ui_fadeScreen.stop(ctx.fadeToBlackDurationSeconds)
      end, 1)
    else
      core_camera.setByName(0, ctx.player.rideCamera or ctx.taxiCameraMode)
    end
  end

  local function setTaxiState(vehId, stateKey)
    if not vehId then return end
    local prev = ctx.taxis[vehId]
    if prev == stateKey then return end
    --log("I", "taxi", "setTaxiState: " .. tostring(vehId) .. " " .. tostring(prev) .. " -> " .. tostring(stateKey))
    ctx.taxis[vehId] = stateKey
    local meta = ctx.taxiStates[stateKey]
    if meta and meta.inService then
      departingDrivers[vehId] = nil
      ctx.setCabDriver(vehId, true)
    elseif prev and ctx.taxiStates[prev] and ctx.taxiStates[prev].inService then
      departingDrivers[vehId] = true
    end

    if stateKey == "unavailable" then
      local trafficData = gameplay_traffic.getTrafficData()
      local td = trafficData[vehId]
      if td then td.ignoreForceTeleport = nil end
      if td and td.reserved then
        gameplay_traffic.returnReservedVehicle(vehId)
      else
        gameplay_traffic.unprotectNonReservedVehicle(vehId)
      end
    end

    local veh = getObjectByID(vehId)
    if not veh then return end

    -- AI commands
    if stateKey == "pullingOverForPickup" or stateKey == "pullingOverForDropoff" then
      if veh:getVelocity():len() * 3.6 < ctx.maxPullOverSpeedKph then
        local stopped = stateKey == "pullingOverForPickup" and "waitingForPickup" or "waitingForDropoff"
        setTaxiState(vehId, stopped)
        return
      end
      veh:queueLuaCommand('ai.setPullOver(true)')
    elseif stateKey == "waitingForPickup" or stateKey == "waitingForDropoff" then
      veh:queueLuaCommand('ai.setMode("stop")')
    end

    -- Blinkers
    if meta and meta.blinkers == "hazard" then
      ctx.createTaxiJob(function(job)
        job.sleep(0.2)
        veh:queueLuaCommand('electrics.set_warn_signal(1)')
      end, 1)
    elseif meta and meta.blinkers == "pullOver" then
      veh:queueLuaCommand('electrics.set_warn_signal(false)')
      activatePullOverBlinkers(veh)
    elseif prev and ctx.taxiStates[prev] and ctx.taxiStates[prev].blinkers then
      veh:queueLuaCommand('electrics.set_warn_signal(false)')
      veh:queueLuaCommand('electrics.stop_turn_signal()')
    end

    -- Taxi sign lights
    if meta and meta.lightState then
      veh:queueLuaCommand(string.format('local c = controller.getController("taxiLights") if c then c.setTaxiState("%s") end', meta.lightState))
    end
  end

  local function getTaxiState(vehId)
    return ctx.taxis[vehId] or "available"
  end

  -- registers a taxi that is coming to / waiting at the pickup. called = summoned via phone (vs hailed). target pos can be nil for hailed taxis that pull over in place.
  local function addPickupTaxi(vehId, called, targetPos)
    ctx.player.pickupTaxis[vehId] = {
      called = called, targetPos = targetPos, waitTimer = 0, maxDist = math.huge, approachActive = false,
    }
    if ctx.player.currentPhase == ctx.playerRidePhases.none then
      ctx.player.currentPhase = ctx.playerRidePhases.awaitingPickup
    end
  end

  -- a pickup taxi is no longer serving the player (boarded another, crashed, walked away, waited too long, call cancelled): mark it unavailable
  local function dismissPickupTaxi(vehId, message)
    ctx.player.pickupTaxis[vehId] = nil

    setTaxiState(vehId, "unavailable")
    local veh = getObjectByID(vehId)
    if veh then
      veh:queueLuaCommand('ai.setPullOver(false)')
      clearApproachSpeedCap(veh)
      veh:queueLuaCommand('ai.setState({mode = "traffic"})')
      veh.playerUsable = false
    end
    gameplay_walk.addVehicleToBlacklist(vehId)
    activateMergeBlinkers(vehId)

    if message then showMessage(message, false, 3) end

    if ctx.player.currentPhase == ctx.playerRidePhases.awaitingPickup and not next(ctx.player.pickupTaxis) then
      ctx.player.currentPhase = ctx.playerRidePhases.none
    end
  end

  local function dismissAllPickupTaxis(exceptId)
    local ids = {}
    for vehId in pairs(ctx.player.pickupTaxis) do
      if vehId ~= exceptId then ids[#ids + 1] = vehId end
    end
    for _, vehId in ipairs(ids) do
      dismissPickupTaxi(vehId)
    end
  end

  -- drops a taxi from the pickup set WITHOUT marking it unavailable, so it stays a normal hailable taxi
  -- (used when a hailed driver never noticed the player, or the vehicle vanished before engaging).
  local function forgetPickupTaxi(vehId)
    ctx.player.pickupTaxis[vehId] = nil
    if ctx.player.currentPhase == ctx.playerRidePhases.awaitingPickup and not next(ctx.player.pickupTaxis) then
      ctx.player.currentPhase = ctx.playerRidePhases.none
    end
  end

  -- true if any pickup taxi was summoned via phone (so the radial menu offers "cancel call")
  local function hasCalledATaxi()
    for _, entry in pairs(ctx.player.pickupTaxis) do
      if entry.called then return true end
    end
    return false
  end

  local function rollAvailability(vehId)
    if vehId and isTaxiCrashed(vehId) then return "unavailable" end
    return math.random() < ctx.availableTaxiRatio and "available" or "unavailable"
  end

  ctx.taxiRuntime.useBillboards = true

  local function setPlayerPhase(phase, message)
    ctx.player.currentPhase = phase

    -- sync the active ride taxi's state to match the ride phase
    if ctx.player.currentTaxiId then
      if phase == ctx.playerRidePhases.choosingDestination or phase == ctx.playerRidePhases.driving then
        setTaxiState(ctx.player.currentTaxiId, "occupied")
      elseif phase == ctx.playerRidePhases.arriving then
        setTaxiState(ctx.player.currentTaxiId, "pullingOverForDropoff")
      end
    end

    if ctx.player.currentPhase == ctx.playerRidePhases.driving then
      -- start the idle timer fresh so it doesn't trigger from time spent in the big map
      ctx.player.idleCameraTimer = 0
      ctx.player.persistentMessage = ctx.isTaxiFareSponsored() and "Company pays this fare." or nil
      -- navigate to the taxi view when entering the driving phase
      -- (done here rather than on vehicle-enter so the BigMap can close normally first)
      ctx.player.taxiViewActive = true
      extensions.ui_menuManager.setGameplayRoute("taxi")
      local current = extensions.ui_router.getCurrent()
      if not current or not current.request or current.request.name ~= "taxi" then
        extensions.ui_router.navigate("taxi")
      end
    end
    if ctx.player.currentPhase == ctx.playerRidePhases.arriving then
      setIdleCamera(false)
      ctx.player.disableIdleCamera = true
    end
    pushTaxiUIUpdate(message)
  end


  local function updateTaxiPullOver()
    -- pickup taxis: once stopped, switch from pulling over to waiting
    for vehId in pairs(ctx.player.pickupTaxis) do
      if ctx.taxis[vehId] == "pullingOverForPickup" then
        local veh = getObjectByID(vehId)
        if veh and veh:getVelocity():len() * 3.6 < ctx.maxPullOverSpeedKph then
          setTaxiState(vehId, "waitingForPickup")
        end
      end
    end

    -- active ride taxi: dropoff pull over
    if ctx.player.currentTaxiId and ctx.taxis[ctx.player.currentTaxiId] == "pullingOverForDropoff" then
      local veh = getObjectByID(ctx.player.currentTaxiId)
      if veh then
        -- only a destination arrival may steer toward destinationPos; on a "stop here" the destination
        -- is still far away and the taxi must stop wherever it is
        local distLeft = ctx.player.arrivalCommitted and ctx.player.destinationPos
          and routeDistanceLeft(ctx.player.routePlanner, veh:getPosition()) or nil

        if veh:getVelocity():len() * 3.6 < ctx.maxPullOverSpeedKph
          or (distLeft and distLeft <= ctx.arrivalStopToleranceMeters) then
          setTaxiState(ctx.player.currentTaxiId, "waitingForDropoff")
          pushTaxiUIUpdate(_tr("ui.taxi.canClimbOut"))
        elseif distLeft then
          veh:queueLuaCommand(string.format('ai.setStopPoint(nil, %.2f)', math.max(0, distLeft)))
        end
      end
    end
  end

  local function resetIdleCameraTimer()
    ctx.player.idleCameraTimer = 0
  end

  local function checkIdleCamera(dt)
    -- treat the quick access menu like camera activity and hold the timer.
    if core_quickAccess and core_quickAccess.isEnabled() then
      ctx.player.idleCameraTimer = 0
      return
    end

    local timeSinceRotation = core_camera.timeSinceLastRotation() / 1000

    -- player is actively moving the camera: reset our timer and leave idle mode
    if timeSinceRotation < ctx.rotationResetThresholdSeconds then
      ctx.player.idleCameraTimer = 0
      if ctx.player.idleCameraActive then
        setIdleCamera(false)
      end
      return
    end

    if ctx.player.idleCameraActive or ctx.player.disableIdleCamera
      or not ctx.player.idleCameraUserEnabled then return end

    ctx.player.idleCameraTimer = ctx.player.idleCameraTimer + dt
    if ctx.player.idleCameraTimer > ctx.idleCameraDelaySeconds then
      setIdleCamera(true)
    end
  end

  local function getAiPath(path, veh)
    local aiPath = {}
    if not veh then return nil end
    local firstWpAdded = false
    local vehPos = veh:getPosition()
    local vehFwd = veh:getDirectionVector()
    local bestDist = math.huge
    local prevDot = nil
    local prevWp = nil
    local startDist = path[1].distToTarget
    -- find the first valid waypoint
    for i, marker in ipairs(path) do
      if marker.wp then
        if (marker.distToTarget < ctx.skipTargetDistanceMeters) and not ctx.player.skipPosition then
          ctx.player.skipPosition = marker.pos
          if path[i+1] and path[i+1].pos then
            local direction = (path[i+1].pos - marker.pos):normalized()
            ctx.player.skipRotation = quatFromDir(direction, vec3(0, 0, 1))
          end
        end
        if not firstWpAdded then
          local toWp = (marker.pos - vehPos):normalized()
          local dot = toWp:dot(vehFwd)
          if prevDot and dot < prevDot and prevDot > 0 then
            table.insert(aiPath, prevWp)
            firstWpAdded = true
          end
          prevDot = dot
          prevWp = marker.wp
        else
          table.insert(aiPath, marker.wp)
        end
      end
    end
    -- If we haven't found a local maximum but have a positive dot product, use the last one
    if not firstWpAdded and prevDot and prevDot > 0 then
      table.insert(aiPath, prevWp)
      firstWpAdded = true
    end
    -- fallback: if no waypoint is in front of vehicle, use the first waypoint that's 25m away and all other waypoints
    if not firstWpAdded then
      for _, marker in ipairs(path) do
        if marker.wp and startDist - marker.distToTarget > 25 then
          table.insert(aiPath, marker.wp)
        end
      end
    end
    return aiPath
  end

  -- Ensures a drive path ends by passing through targetPos's road segment. Appends the approach node then the node just past the target, ordered by the route's final travel direction.
  local function appendTargetApproach(aiPath, routePlanner, veh, targetPos)
    if not aiPath or not targetPos then return aiPath end
    local n1, n2 = map.findClosestRoad(targetPos)
    local nodes = map.getMap().nodes
    if not (n1 and n2 and nodes[n1] and nodes[n2]) then return aiPath end

    -- travel direction near the target: from the route's last named node (robust on curves),
    -- falling back to the vehicle position if the route has no usable named node
    local approachFrom
    for i = #routePlanner.path, 1, -1 do
      local m = routePlanner.path[i]
      if m.wp and nodes[m.wp] then approachFrom = nodes[m.wp].pos break end
    end
    approachFrom = approachFrom or (veh and veh:getPosition())
    if not approachFrom then return aiPath end
    local travelDir = targetPos - approachFrom
    if travelDir:length() < 1e-3 and veh then travelDir = targetPos - veh:getPosition() end
    travelDir = travelDir:normalized()

    -- approach node is on the near side of the target, overshoot node on the far side
    local approachWp, overshootWp = n1, n2
    if (nodes[n1].pos - targetPos):dot(travelDir) > (nodes[n2].pos - targetPos):dot(travelDir) then
      approachWp, overshootWp = n2, n1
    end

    if aiPath[#aiPath] ~= approachWp then table.insert(aiPath, approachWp) end
    if aiPath[#aiPath] ~= overshootWp then table.insert(aiPath, overshootWp) end
    return aiPath
  end

  local function getCurrentRoute(veh)
    local rp = ctx.player.routePlanner
    if not rp or not rp.path or not rp.path[1] then
      return
    end

    -- reset so getAiPath recomputes a fresh skip target for this route (otherwise the
    -- "not skipPosition" guard keeps a stale point from a previous ride/route forever)
    ctx.player.skipPosition = nil
    ctx.player.skipRotation = nil
    local aiPath = getAiPath(rp.path, veh)
    -- always anchor on the destination's road segment so the list is non-empty on short routes
    -- and the AI drives through the stop point (the actual stop is handled by proximity pull-over)
    appendTargetApproach(aiPath, rp, veh, ctx.player.destinationPos)

    local str = '{wpTargetList = '..serialize(aiPath)
    str = str..', noOfLaps = 1, avoidCars = "on", driveInLane = "on"}'
    return str
  end


  local function startTaxiWithCurrentRoute(skipWait)
    if skipWait == nil then skipWait = false end
    ctx.createTaxiJob(function(job)
      freeroam_bigMapMode.exitBigMap(false, true, true)
      local plVeh = be:getPlayerVehicle(0)
      if not plVeh then
        return
      end

      if not ctx.player.destinationPos then
        return
      end

      local vehPos = plVeh:getPosition()
      ctx.player.routePlanner:setupPathMulti({vehPos, ctx.player.destinationPos})
      if not (ctx.player.routePlanner.path and ctx.player.routePlanner.path[1]) then
        return
      end

      local routeStr = getCurrentRoute(plVeh)
      if not routeStr then
        return
      end

      ctx.player.routePlanner:trackVehicle(plVeh)
      ctx.player.totalRouteDistance = routeDistanceLeft(ctx.player.routePlanner, vehPos) or 0

      if not skipWait then
        job.sleep(2)
      end

      -- driveUsingPath resets the AI's speed mode, so the approach cap only needs clearing here
      ctx.player.arrivalApproachActive = false
      ctx.player.arrivalApproachSpeed0 = nil
      ctx.player.arrivalApproachDist0 = nil
      ctx.player.arrivalSpeedCap = nil
      ctx.player.arrivalCommitted = false

      plVeh:queueLuaCommand('ai.setPullOver(false)') -- in case we're resuming from a pulled-over dropoff
      plVeh:queueLuaCommand('ai.driveUsingPath('..routeStr..')')
      ctx.hurryUpLevels[ctx.player.hurryUpLevel].apply(plVeh)

      setPlayerPhase(ctx.playerRidePhases.driving)
      -- signal merging back into traffic as the taxi pulls away from the curb
      activateMergeBlinkers(ctx.player.currentTaxiId)
      -- clear ground markers after phase change so the hook doesn't clear destinationPos
      freeroam_bigMapMode.setNavFocus(nil)
    end, 1)
  end


  -- Registry cleanup also ends departures, even while the cab is still nearby.
  local function forgetAllTaxis()
    for vehId in pairs(ctx.taxis) do ctx.setCabDriver(vehId, false) end
    table.clear(ctx.taxis)
    table.clear(departingDrivers)
    driverCheckTimer = 0
  end

  local function refreshHailingEnabled()
    local wasEnabled = ctx.taxiRuntime.hailingEnabled
    ctx.taxiRuntime.hailingEnabled = ctx.getShouldSystemBeEnabled()

    if ctx.taxiRuntime.hailingEnabled == wasEnabled then return end

    if ctx.taxiRuntime.hailingEnabled then
      for id, veh in pairs(gameplay_traffic.getTrafficData()) do
        if veh.isTaxi and not veh.reserved and veh.isAi and not ctx.taxis[id] then
          setTaxiState(id, rollAvailability(id))
        end
      end
    else
      forgetAllTaxis()
      ctx.taxiRuntime.clearTaxiBillboards()
    end
  end

  local function taxiSettingChanged()
    if not ctx.isOverhaulActive() then return end
    refreshHailingEnabled()
  end

  local function onTrafficStarted()
    if not ctx.isOverhaulActive() then return end
    refreshHailingEnabled()
  end

  local function onAnyMissionChanged()
    if not ctx.isOverhaulActive() then return end
    refreshHailingEnabled()
  end

  local function onTrafficVehicleAdded(id)
    if not ctx.isOverhaulActive() then return end
    if not ctx.taxiRuntime.hailingEnabled then return end
    local trafficData = gameplay_traffic.getTrafficData()
    local vehData = trafficData[id]
    if vehData and vehData.isTaxi and not vehData.reserved and vehData.isAi then
      setTaxiState(id, rollAvailability(id))
    end
  end

  local function onTrafficVehicleRemoved(id)
    if not ctx.isOverhaulActive() then return end
    if ctx.taxis[id] then
      ctx.taxis[id] = nil
      departingDrivers[id] = nil
      ctx.setCabDriver(id, false)
    end
    if ctx.player.pickupTaxis[id] then
      ctx.player.pickupTaxis[id] = nil
      if ctx.player.currentPhase == ctx.playerRidePhases.awaitingPickup and not next(ctx.player.pickupTaxis) then
        ctx.player.currentPhase = ctx.playerRidePhases.none
      end
    end
  end

  local function onTrafficStopped()
    forgetAllTaxis()
    ctx.taxiRuntime.clearTaxiBillboards()
    if ctx.player.idleCameraActive then setIdleCamera(false) end
    if ctx.player.taxiViewActive then
      extensions.ui_menuManager.setGameplayRoute(nil)
      local current = extensions.ui_router.getCurrent()
      if current and current.request and current.request.name == "taxi" then
        extensions.ui_router.navigate("play")
      end
    end
    resetPlayerData()
  end

  local sightCamPos, sightCamFwd = vec3(), vec3()
  local function checkAndFindNearestTaxi()
    local phase = ctx.player.currentPhase
    if phase ~= ctx.playerRidePhases.none and phase ~= ctx.playerRidePhases.awaitingPickup then return end
    if not gameplay_walk.isWalking() then return end

    local playerVehId = be:getPlayerVehicleID(0)
    local playerObj = map.objects[playerVehId]
    if not playerObj then return end
    local playerPos = playerObj.pos
    local cameraRead = false
    local nearestDistanceMeters = math.huge
    local found = false
    for vehId, state in pairs(ctx.taxis) do
      if state == "available" and vehId ~= playerVehId and not ctx.player.pickupTaxis[vehId]
        and vehId ~= ctx.player.currentTaxiId then
        local veh = map.objects[vehId]
        if veh then
          if not cameraRead then
            sightCamPos:set(core_camera.getPositionXYZ())
            sightCamFwd:set(core_camera.getForwardXYZ())
            cameraRead = true
          end
          if gameplay_util_vehicleSighting.checkSighting(sightCamPos, sightCamFwd, veh.pos, ctx.playerSightParams) then
            local dist = playerPos:distance(veh.pos)
            if dist < nearestDistanceMeters then
              nearestDistanceMeters = dist
              ctx.player.nearestTaxiId = vehId
              found = true
            end
          end
        end
      end
    end

    if not found then
      ctx.player.nearestTaxiId = nil
    end
  end


  local function applyTaxiRideFilter()
    core_input_actionFilter.setGroup(ctx.taxiRideFilterName, ctx.taxiRideBlockedActions)
    core_input_actionFilter.addAction(0, ctx.taxiRideFilterName, true)
  end

  local function clearTaxiRideFilter()
    core_input_actionFilter.addAction(0, ctx.taxiRideFilterName, false)
  end

  local function blockVehicleSwitching() -- while riding the taxi, stop the player from switching into any other car
    ctx.player.disabledSwitchVehicles = {}
    for i = 0, be:getObjectCount() - 1 do
      local veh = be:getObject(i)
      if veh then
        local vid = veh:getId()
        if vid ~= ctx.player.currentTaxiId and veh.playerUsable ~= false and veh:getJBeamFilename() ~= "unicycle" then
          veh.playerUsable = false
          table.insert(ctx.player.disabledSwitchVehicles, vid)
        end
      end
    end
    applyTaxiRideFilter()
  end

  local function restoreVehicleSwitching() -- re-enable the cars we disabled when entering the taxi
    clearTaxiRideFilter()
    if not ctx.player.disabledSwitchVehicles then return end
    for _, vid in ipairs(ctx.player.disabledSwitchVehicles) do
      local veh = getObjectByID(vid)
      if veh then
        veh.playerUsable = true
      end
    end
    ctx.player.disabledSwitchVehicles = nil
  end

  local function callAndStopTaxi()
    if not ctx.player.nearestTaxiId then return end
    local taxiId = ctx.player.nearestTaxiId
    if ctx.player.pickupTaxis[taxiId] then return end -- already engaged with the player

    -- reserve it right away (hailed: no drive-to target) so it isn't offered again while the driver reacts
    addPickupTaxi(taxiId, false, nil)

    ctx.createTaxiJob(function(job)
      local reactionTime = lerp(ctx.minReactionTimeSeconds, ctx.maxReactionTimeSeconds, math.random())
      job.sleep(reactionTime)

      if not ctx.player.pickupTaxis[taxiId] then return end -- dismissed/cancelled while the driver reacted

      local veh = getObjectByID(taxiId)
      if not veh then
        forgetPickupTaxi(taxiId)
        return
      end

      local playerVehId = be:getPlayerVehicleID(0)
      if not gameplay_util_vehicleSighting.canVehicleSeeVehicle(
        taxiId, playerVehId, ctx.getTaxiSightParams(taxiId)) then
        forgetPickupTaxi(taxiId) -- stays available so the player can try again
        showMessage(_tr("ui.taxi.didntNotice"), false, 3)
        return
      end

      gameplay_walk.removeVehicleFromBlacklist(taxiId)
      veh.playerUsable = true
      setTaxiState(taxiId, "pullingOverForPickup")
      local message = _tr("ui.taxi.pullingOver")
      if ctx.isTaxiFareSponsored() then
        message = message .. " Company pays this fare."
      end
      showMessage(message, false)
    end, 1)
  end


  local function getPlayerRoadPos()
    local playerVehId = be:getPlayerVehicleID(0)
    local playerObj = map.objects[playerVehId]
    if not playerObj then return nil end
    local playerPos = playerObj.pos
    local n1, n2 = map.findClosestRoad(playerPos)
    if not n1 or not n2 then return nil end
    local nodes = map.getMap().nodes
    local p1, p2 = nodes[n1].pos, nodes[n2].pos
    local roadPos = linePointFromXnorm(p1, p2, clamp(playerPos:xnormOnLine(p1, p2), 0, 1))
    if playerPos:distance(roadPos) > ctx.callTaxiMaxRoadDistanceMeters then return nil end
    return roadPos, n1, n2
  end

  local callTaxiRoutePlanner = require('/lua/ge/extensions/gameplay/route/route')()

  local function driveTaxiToPlayerRoad(vehId)
    local roadPos = getPlayerRoadPos()
    if not roadPos then
      log("W", "taxi", "driveTaxiToPlayerRoad: getPlayerRoadPos returned nil (player too far from road?)")
      return nil
    end

    local veh = getObjectByID(vehId)
    if not veh then
      log("W", "taxi", "driveTaxiToPlayerRoad: vehicle " .. tostring(vehId) .. " not found")
      return nil
    end

    local vehPos = veh:getPosition()
    log("I", "taxi", string.format("driveTaxiToPlayerRoad: veh %d at (%.1f, %.1f, %.1f) -> roadPos (%.1f, %.1f, %.1f), straight dist %.1f",
      vehId, vehPos.x, vehPos.y, vehPos.z, roadPos.x, roadPos.y, roadPos.z, vehPos:distance(roadPos)))

    callTaxiRoutePlanner:setupPathMulti({vehPos, roadPos})
    if not (callTaxiRoutePlanner.path and callTaxiRoutePlanner.path[1]) then
      log("W", "taxi", "driveTaxiToPlayerRoad: route planner produced no path between veh and player road")
      return nil
    end
    log("I", "taxi", string.format("driveTaxiToPlayerRoad: route planner path has %d nodes", #callTaxiRoutePlanner.path))

    -- getAiPath has a side effect on player.skipPosition/skipRotation; preserve them
    local savedSkipPos, savedSkipRot = ctx.player.skipPosition, ctx.player.skipRotation
    local aiPath = getAiPath(callTaxiRoutePlanner.path, veh)
    ctx.player.skipPosition, ctx.player.skipRotation = savedSkipPos, savedSkipRot

    -- always anchor on the pickup road segment so short routes don't collapse to an empty list
    appendTargetApproach(aiPath, callTaxiRoutePlanner, veh, roadPos)

    if not aiPath or #aiPath == 0 then
      log("W", "taxi", string.format("driveTaxiToPlayerRoad: getAiPath returned empty (path nodes %d) - veh likely has no nav waypoint near it",
        #callTaxiRoutePlanner.path))
      return nil
    end
    log("I", "taxi", string.format("driveTaxiToPlayerRoad: issuing ai.driveUsingPath with %d waypoints to veh %d", #aiPath, vehId))

    local routeStr = '{wpTargetList = ' .. serialize(aiPath) .. ', noOfLaps = 1, avoidCars = "on", driveInLane = "on"}'
    veh:queueLuaCommand('ai.driveUsingPath(' .. routeStr .. ')')
    ctx.hurryUpLevels[1].apply(veh)
    return roadPos
  end

  local function findCallTaxiSpawnPoint(playerPos)
    local camPos = core_camera.getPosition()
    local camFwd = camPos and core_camera.getForward()
    if not camFwd then return nil end

    -- search behind the camera for an out-of-sight position
    local behindDir = -camFwd
    local spawnData = gameplay_traffic_trafficUtils.findSafeSpawnPoint(
      playerPos, behindDir, ctx.callTaxiSpawnMinDistanceMeters, ctx.callTaxiSpawnMaxDistanceMeters,
      ctx.callTaxiSpawnMinDistanceMeters, {minDrivability = 0.5}
    )
    if not spawnData then return nil end

    -- pick the lane whose legal travel direction heads back toward the player, so the taxi spawns facing
    -- the pickup instead of having to U-turn. finalizeSpawnPoint offsets to the matching lane from roadDir.
    local nodes = map.getMap().nodes
    local roadDir = 1
    if spawnData.n1 and spawnData.n2 and nodes[spawnData.n1] and nodes[spawnData.n2] then
      local segDir = nodes[spawnData.n2].pos - nodes[spawnData.n1].pos
      roadDir = segDir:dot(playerPos - spawnData.pos) >= 0 and 1 or -1
    end

    local pos, dir = gameplay_traffic_trafficUtils.finalizeSpawnPoint(spawnData.pos, spawnData.dir, spawnData.n1, spawnData.n2, {legalDirection = true, roadDir = roadDir})
    local normal = map.surfaceNormal(pos, 1)
    local rot = quatFromDir(vec3(0, 1, 0):rotated(quatFromDir(dir, normal)), normal)
    return pos, rot
  end

  -- all hailable taxis sorted nearest-first, so the caller can try each in turn before falling back
  local function findNearbyAvailableTaxis(playerPos)
    local playerVehId = be:getPlayerVehicleID(0)
    local candidates = {}
    for vehId, state in pairs(ctx.taxis) do
      if state == "available" and vehId ~= playerVehId and not ctx.player.pickupTaxis[vehId]
        and vehId ~= ctx.player.currentTaxiId then
        local veh = getObjectByID(vehId)
        if veh then
          candidates[#candidates + 1] = { id = vehId, dist = playerPos:distance(veh:getPosition()) }
        end
      end
    end
    table.sort(candidates, function(a, b) return a.dist < b.dist end)
    return candidates
  end

  local function cancelTaxiCall()
    if not hasCalledATaxi() then return end
    for vehId in pairs(ctx.player.pickupTaxis) do
      if ctx.player.pickupTaxis[vehId].called then
        dismissPickupTaxi(vehId)
      end
    end
    showMessage(_tr("ui.taxi.callCancelled"), false, 3)
  end

  local function canCallTaxi()
    if not ctx.getShouldSystemBeEnabled() then return false end
    if gameplay_traffic.getState() ~= 'on' then return false end
    if not next(ctx.taxis) then return false end
    local phase = ctx.player.currentPhase
    return phase == ctx.playerRidePhases.none or phase == ctx.playerRidePhases.awaitingPickup
  end

  -- Claims a reserved taxi from the traffic pool and dispatches it to the player. Returns true if
  -- dispatch started, false on a synchronous failure (no reserved taxi / no spawn point);
  local function dispatchReservedTaxi(playerPos)
    local claimed = gameplay_traffic.useReservedVehicle('taxi', 1)
    if not claimed[1] then
      return false
    end

    local taxiId = claimed[1]
    local spawnPos, spawnRot = findCallTaxiSpawnPoint(playerPos)
    if not spawnPos then
      gameplay_traffic.returnReservedVehicle(taxiId)
      return false
    end

    -- mark it as ours (en route) BEFORE respawning, so the reset triggered by the teleport
    -- doesn't roll its state back to available/unavailable. targetPos is filled in once routed (below)
    addPickupTaxi(taxiId, true, nil)
    setTaxiState(taxiId, "enRoute")

    gameplay_traffic.respawnVehicle(taxiId, spawnPos, spawnRot)

    -- wait for the traffic refresh cycle (reset -> onRefresh -> active) to finish,
    -- then issue our path command so it isn't overridden by traffic AI reset
    ctx.createTaxiJob(function(job)
      local trafficData = gameplay_traffic.getTrafficData()
      local trafficVeh = trafficData[taxiId]

      -- wait until the vehicle reaches 'active' state (onRefresh completed)
      for _ = 1, 10 do
        job.yield()
        if trafficVeh and trafficVeh.state == 'active' then break end
      end

      if not ctx.player.pickupTaxis[taxiId] then return end -- cancelled / dismissed while spawning

      local targetPos = driveTaxiToPlayerRoad(taxiId)
      if not targetPos then
        dismissPickupTaxi(taxiId, _tr("ui.taxi.noTaxiAvailable"))
        return
      end
      if ctx.player.pickupTaxis[taxiId] then
        ctx.player.pickupTaxis[taxiId].targetPos = targetPos
      end
    end, 1)

    showMessage(_tr("ui.taxi.onTheWay"), false, 4)
    return true
  end

  local function callForTaxi()
    if not canCallTaxi() then return end

    local playerVehId = be:getPlayerVehicleID(0)
    local playerObj = map.objects[playerVehId]
    if not playerObj then return end
    local playerPos = playerObj.pos

    local roadPos = getPlayerRoadPos()
    if not roadPos then
      showMessage(_tr("ui.taxi.tooFarFromRoad"), false, 4)
      return
    end

    -- prefer an already-active available taxi; try them nearest-first before claiming a reserved one
    local candidates = findNearbyAvailableTaxis(playerPos)
    for _, candidate in ipairs(candidates) do
      local nearbyId = candidate.id
      setTaxiState(nearbyId, "enRoute")
      gameplay_traffic.protectNonReservedVehicle(nearbyId, 'taxi') -- in-service: don't let traffic pool/swap it while en route
      local targetPos = driveTaxiToPlayerRoad(nearbyId)
      if targetPos then
        addPickupTaxi(nearbyId, true, targetPos)
        showMessage(_tr("ui.taxi.onTheWay"), false, 4)
        return
      end
      -- this taxi couldn't be routed; release it and try the next nearest
      gameplay_traffic.unprotectNonReservedVehicle(nearbyId)
      setTaxiState(nearbyId, "available")
    end

    -- no active taxi could reach the player; fall back to a reserved one
    if not dispatchReservedTaxi(playerPos) then
      showMessage(_tr("ui.taxi.noTaxiAvailable"), false, 4)
    end
  end

  local function kickPlayerOut(message)
    showMessage(message or _tr("ui.taxi.kickedOut"), false, 4)
    local exitPos = ctx.passengerSeats.exitPosition(ctx.player.currentTaxiId)
    gameplay_walk.setWalkingMode(true, exitPos, nil, true)
  end

  local function closeDoorsOf(vehId)
    ctx.createTaxiJob(function(job)
      job.sleep(1.5)
      local v = getObjectByID(vehId)
      if v then
        v:queueLuaCommand('for _, c in pairs(controller.getControllersByType("advancedCouplerControl")) do c.tryAttachGroupImpulse() end')
      end
    end, 1)
  end

  local function leaveTaxi(message)
    -- charge the fare (career only)
    if ctx.player.fare and ctx.player.fare > 0 and overhaul_career_career.isActive() then
      local label = _tr("ui.taxi.fareLabel")
      local sponsored = ctx.isTaxiFareSponsored()
      local paid = overhaul_career_economy_payment.pay(
        {money = {amount = ctx.player.fare, canBeNegative = true}}, {category = "service", label = label})
      if paid then recordRide({detail = ctx.player.arrivalCommitted and "Arrived at destination" or "Ride ended",
        money = sponsored and 0 or -ctx.player.fare}) end
      if not sponsored then
        Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Buy_01')
      end
    end

    restoreVehicleSwitching() -- always restore, even if the taxi vehicle is already gone, so the player isn't locked out of their car
    local veh = getObjectByID(ctx.player.currentTaxiId)
    -- Vehicle cleanup is optional; route and passenger ownership must always end.
    if veh then
      closeDoorsOf(ctx.player.currentTaxiId)
      veh:queueLuaCommand('ai.setPullOver(false)')
      clearApproachSpeedCap(veh)
      ctx.hurryUpLevels[1].apply(veh)
      veh:queueLuaCommand('ai.setState({mode = "traffic"})')
      setTaxiState(ctx.player.currentTaxiId, "unavailable")
      activateMergeBlinkers(ctx.player.currentTaxiId)
      gameplay_walk.addVehicleToBlacklist(ctx.player.currentTaxiId)
      veh.playerUsable = false
    end

    if message then
      showMessage(message, false)
    end

    setPlayerPhase(ctx.playerRidePhases.none)
    ctx.player.disableIdleCamera = false
    ctx.player.currentTaxiId = nil
    -- The next ride must pick its own destination.
    ctx.player.destinationPos = nil
    ctx.player.chooseResumeMode = nil
    ctx.player.routePlanner:clear()

    if ctx.player.taxiViewActive then
      ctx.player.taxiViewActive = false
      extensions.ui_menuManager.setGameplayRoute(nil)
      local current = extensions.ui_router.getCurrent()
      if current and current.request and current.request.name == "taxi" then
        extensions.ui_router.navigate("play")
      end
    end
  end

  -- a taxi waiting at the pickup leaves if the player walks up to it then walks away (ratchet) OR the
  -- wait timer elapses while the player is out of range. Each waiting pickup taxi is tracked independently.
  local function updatePickupWait(dtReal)
    if not next(ctx.player.pickupTaxis) then return end
    local playerVeh = be:getPlayerVehicle(0)
    if not playerVeh then return end
    local playerPos = playerVeh:getPosition()
    local walking = gameplay_walk.isWalking()

    local toDismiss = nil
    for vehId, entry in pairs(ctx.player.pickupTaxis) do
      if ctx.taxis[vehId] == "waitingForPickup" then -- only once stopped and waiting
        local taxiVeh = getObjectByID(vehId)
        if taxiVeh then
          local dist = playerPos:distance(taxiVeh:getPosition())

          -- walked-away: track the closest approach, then bail if the player backs off past it
          if walking then
            entry.maxDist = math.min(entry.maxDist, dist + ctx.pickupDistanceSlackMeters)
          end

          if walking and dist > entry.maxDist then
            toDismiss = toDismiss or {}
            toDismiss[vehId] = _tr("ui.taxi.walkedAway")
          else
            -- waited-too-long: bail once the timer elapses and the player still isn't within pickup range
            entry.waitTimer = entry.waitTimer + dtReal
            if entry.waitTimer >= ctx.pickupWaitTimeSeconds and dist > ctx.pickupAbandonRadiusMeters then
              toDismiss = toDismiss or {}
              toDismiss[vehId] = _tr("ui.taxi.waitedTooLong")
            end
          end
        end
      end
    end

    if toDismiss then
      for vehId, message in pairs(toDismiss) do
        dismissPickupTaxi(vehId, message)
      end
    end
  end

  -- atDestination distinguishes reaching the chosen destination and player asking to stop right here
  local function makeTaxiPullOverWhileDriving(message, atDestination)
    if not ctx.player.currentTaxiId then return end
    local veh = getObjectByID(ctx.player.currentTaxiId)
    if not veh then return end
    local trafficVeh = gameplay_traffic.getTrafficData()[ctx.player.currentTaxiId]
    if trafficVeh and trafficVeh.role then
      ctx.player.arrivalCommitted = atDestination or false
      -- At the destination keep following the planned route until the pull-over stops the cab.
      if not atDestination then
        veh:queueLuaCommand('ai.setPullOver(false)')
        veh:queueLuaCommand('ai.setState({mode = "traffic"})')
      end
      setPlayerPhase(ctx.playerRidePhases.arriving)

      if message then
        showMessage(message, false)
      end
    end
  end

  -- phase 1 sheds speed, phase 2 commits the pull-over at the distance the AI actually needs to stop
  local function updateArrivalApproach(veh)
    if not (veh and ctx.player.destinationPos) then return end
    local distLeft = routeDistanceLeft(ctx.player.routePlanner, veh:getPosition())
    if not distLeft then return end

    if not ctx.player.arrivalApproachActive and distLeft <= ctx.arrivalApproachDistanceMeters then
      ctx.player.arrivalApproachActive = true
      ctx.player.arrivalApproachSpeed0 = veh:getVelocity():len()
      ctx.player.arrivalApproachDist0 = distLeft
      ctx.player.arrivalSpeedCap = nil
    end

    if ctx.player.arrivalApproachActive then
      local cap = getApproachSpeedCap(ctx.player.arrivalApproachSpeed0, ctx.player.arrivalApproachDist0, distLeft)
      if not ctx.player.arrivalSpeedCap
        or math.abs(ctx.player.arrivalSpeedCap - cap) >= ctx.approachCapResendStepMetersPerSecond then
        ctx.player.arrivalSpeedCap = cap
        applyApproachSpeedCap(veh, cap)
      end
    end

    if distLeft <= getCommitStopDist(veh) then
      makeTaxiPullOverWhileDriving(_tr("ui.taxi.arrived"), true)
    end
  end

  local function isTaxiAvailable()
    local phase = ctx.player.currentPhase
    return ctx.taxiRuntime.hailingEnabled
      and (phase == ctx.playerRidePhases.none or phase == ctx.playerRidePhases.awaitingPickup)
      and gameplay_walk.isWalking() and ctx.player.nearestTaxiId
  end

  -- detects called pickup taxis reaching their drive-to point (or ceased to exist en route). On arrival the taxi
  -- starts pulling over and becomes enterable; the player boards it like any other waiting taxi.
  local function updatePickupArrivals()
    if not next(ctx.player.pickupTaxis) then return end

    local playerVehId = be:getPlayerVehicleID(0)
    local playerVeh = be:getPlayerVehicle(0)
    local playerPos = playerVeh and playerVeh:getPosition()

    local arrived, lost = nil, nil
    for vehId, entry in pairs(ctx.player.pickupTaxis) do
      local taxiVeh = getObjectByID(vehId)
      if not taxiVeh then
        lost = lost or {}
        lost[#lost + 1] = vehId
      elseif entry.targetPos then -- en route to the pickup
        -- mimic a real cab: if the driver spots the player along the way, pull over early; otherwise
        -- carry on to the agreed road spot and wait there.
        local sawPlayer = playerVehId and playerPos
          and gameplay_util_vehicleSighting.canVehicleSeeVehicle(vehId, playerVehId, ctx.getTaxiSightParams(vehId))
          and taxiVeh:getPosition():distance(playerPos) <= ctx.pickupSightArrivalDistanceMeters
        local dist = taxiVeh:getPosition():distance(entry.targetPos)

        if not entry.approachActive and dist <= ctx.arrivalApproachDistanceMeters then
          entry.approachActive = true
          entry.approachSpeed0 = taxiVeh:getVelocity():len()
          entry.approachDist0 = dist
          entry.speedCap = nil
        end

        if entry.approachActive then
          local cap = getApproachSpeedCap(entry.approachSpeed0, entry.approachDist0, dist)
          if not entry.speedCap or math.abs(entry.speedCap - cap) >= ctx.approachCapResendStepMetersPerSecond then
            entry.speedCap = cap
            applyApproachSpeedCap(taxiVeh, cap)
          end
        end

        if sawPlayer or dist <= getCommitStopDist(taxiVeh) then
          arrived = arrived or {}
          arrived[#arrived + 1] = vehId
        end
      end
    end

    if lost then
      for _, vehId in ipairs(lost) do
        ctx.player.pickupTaxis[vehId] = nil
      end
      if ctx.player.currentPhase == ctx.playerRidePhases.awaitingPickup and not next(ctx.player.pickupTaxis) then
        ctx.player.currentPhase = ctx.playerRidePhases.none
        showMessage(_tr("ui.taxi.noTaxiAvailable"), false, 4)
      end
    end

    if arrived then
      for _, vehId in ipairs(arrived) do
        local entry = ctx.player.pickupTaxis[vehId]
        if entry then
          entry.targetPos = nil
          gameplay_walk.removeVehicleFromBlacklist(vehId)
          local veh = getObjectByID(vehId)
          if veh then veh.playerUsable = true end
          setTaxiState(vehId, "pullingOverForPickup")
          showMessage(_tr("ui.taxi.taxiArrived"), false, 4)
        end
      end
    end
  end

  local function updatePickupStuck(dtReal)
    if not next(ctx.player.pickupTaxis) then return end

    local toDismiss = nil
    for vehId, entry in pairs(ctx.player.pickupTaxis) do
      if entry.called and entry.targetPos and ctx.taxis[vehId] == "enRoute" then
        local veh = getObjectByID(vehId)
        if veh then
          local pos = veh:getPosition()
          if not entry.stuckCheckPos then
            entry.stuckCheckPos = vec3(pos)
            entry.stuckTimer = 0
          elseif pos:distance(entry.stuckCheckPos) >= ctx.stuckDistanceThresholdMeters then
            entry.stuckCheckPos = vec3(pos)
            entry.stuckTimer = 0
          else
            entry.stuckTimer = entry.stuckTimer + dtReal
            if entry.stuckTimer >= ctx.stuckTimeThresholdSeconds then
              toDismiss = toDismiss or {}
              toDismiss[vehId] = true
            end
          end
        end
      end
    end

    if toDismiss then
      for vehId in pairs(toDismiss) do
        dismissPickupTaxi(vehId, _tr("ui.taxi.stuck"))
      end
    end
  end

  local function updateFare(veh, dtSim)
    if not (veh and ctx.player.fareData and ctx.player.fareCalculator) then return end
    local speed = veh:getVelocity():len()
    ctx.player.fareData.distanceTraveled = ctx.player.fareData.distanceTraveled + speed * dtSim
    ctx.player.fareData.elapsedTime = ctx.player.fareData.elapsedTime + dtSim
    if speed < 0.5 then
      ctx.player.fareData.stationaryTime = ctx.player.fareData.stationaryTime + dtSim
    end
    ctx.player.fare = ctx.player.fareCalculator(ctx.player.fareData) * 75
  end

  local function onUpdate(dtReal, dtSim, dtRaw)
    if not ctx.isOverhaulActive() then return end
    updateDepartingDrivers(dtReal)
    if not next(ctx.taxis) and not next(ctx.player.pickupTaxis) then return end
    if not be:getPlayerVehicle(0) then return end

    checkAndFindNearestTaxi()
    updateTaxiPullOver()
    if ctx.taxiRuntime.useBillboards then ctx.taxiRuntime.drawTaxiLabels() end

    if isTaxiAvailable() then
      guihooks.trigger('Message', ctx.hailMessage)
    end

    updatePickupArrivals()
    updatePickupStuck(dtReal)
    updatePickupWait(dtReal)

    if ctx.player.currentTaxiId and (ctx.player.currentPhase == ctx.playerRidePhases.driving
      or ctx.player.currentPhase == ctx.playerRidePhases.arriving) then
      local veh = getObjectByID(ctx.player.currentTaxiId)
      if veh then
        ctx.player.routePlanner:trackVehicle(veh)
      end

      if ctx.player.currentPhase == ctx.playerRidePhases.driving then
        checkIdleCamera(dtSim)
        updateArrivalApproach(veh)
      end

      if ctx.player.currentPhase == ctx.playerRidePhases.arriving
        or ctx.player.currentPhase == ctx.playerRidePhases.choosingDestination
        or ctx.player.currentPhase == ctx.playerRidePhases.driving then
        updateFare(veh, dtSim)
      end

      if ctx.player.currentPhase == ctx.playerRidePhases.arriving
        and ctx.taxis[ctx.player.currentTaxiId] == "waitingForDropoff" then
        ctx.player.dropoffKickTimer = ctx.player.dropoffKickTimer + dtReal
        if ctx.player.dropoffKickTimer >= ctx.dropoffKickDelaySeconds then
          ctx.player.dropoffKickTimer = 0
          kickPlayerOut()
        end
      else
        ctx.player.dropoffKickTimer = 0
      end

      ctx.player.uiUpdateTimer = ctx.player.uiUpdateTimer + dtReal
      if ctx.player.uiUpdateTimer >= ctx.uiUpdateIntervalSeconds then
        ctx.player.uiUpdateTimer = 0
        pushTaxiUIUpdate()
      end
    end
  end

  return {
    routeDistanceLeft = routeDistanceLeft,
    getTaxiViewData = getTaxiViewData,
    pushTaxiUIUpdate = pushTaxiUIUpdate,
    showMessage = showMessage,
    setIdleCamera = setIdleCamera,
    setTaxiState = setTaxiState,
    getTaxiState = getTaxiState,
    dismissPickupTaxi = dismissPickupTaxi,
    dismissAllPickupTaxis = dismissAllPickupTaxis,
    hasCalledATaxi = hasCalledATaxi,
    rollAvailability = rollAvailability,
    setPlayerPhase = setPlayerPhase,
    resetIdleCameraTimer = resetIdleCameraTimer,
    startTaxiWithCurrentRoute = startTaxiWithCurrentRoute,
    taxiSettingChanged = taxiSettingChanged,
    onTrafficStarted = onTrafficStarted,
    onAnyMissionChanged = onAnyMissionChanged,
    onTrafficVehicleAdded = onTrafficVehicleAdded,
    onTrafficVehicleRemoved = onTrafficVehicleRemoved,
    onTrafficStopped = onTrafficStopped,
    blockVehicleSwitching = blockVehicleSwitching,
    restoreVehicleSwitching = restoreVehicleSwitching,
    callAndStopTaxi = callAndStopTaxi,
    cancelTaxiCall = cancelTaxiCall,
    canCallTaxi = canCallTaxi,
    callForTaxi = callForTaxi,
    kickPlayerOut = kickPlayerOut,
    closeDoorsOf = closeDoorsOf,
    leaveTaxi = leaveTaxi,
    makeTaxiPullOverWhileDriving = makeTaxiPullOverWhileDriving,
    isTaxiAvailable = isTaxiAvailable,
    onUpdate = onUpdate,
    updateDepartingDrivers = updateDepartingDrivers,
  }
end

return lib
