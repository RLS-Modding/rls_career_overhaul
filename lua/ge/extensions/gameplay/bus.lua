local M = {}
M.dependencies = {'gameplay_sites_sitesManager', 'freeroam_facilities'}

local core_groundMarkers = require('core/groundMarkers')
local core_vehicles      = require('core/vehicles')

-- ================================
-- STATE
-- ================================
local currentStopIndex        = nil
local stopTriggers            = {}
local dwellTimer              = nil
local dwellDuration           = 10
local consecutiveStops        = 0
local currentRouteActive      = false
local accumulatedReward       = 0
local passengersOnboard       = 0
local activeBusID             = nil
local routeInitialized        = false
local totalStopsCompleted     = 0
local routeCooldown           = 0
local currentVehiclePartsTree = nil
local stopMonitorActive       = false
local stopSettleTimer         = 0
local stopSettleDelay         = 2.5
local currentTriggerName      = nil
local roughRide               = 0
local lastVelocity            = nil
local tipTotal                = 0
local trueBoarding            = 0
local trueDeboarding          = 0
local boardingCoroutine       = nil
local currentFinalStopName    = nil
local stopIndexWhereBoardingStarted = nil  -- Track which stop boarding was initiated at

-- Current route info (to prevent route changes mid-route)
local currentRouteName        = nil

-- Store display names by trigger name for reliable access
local stopDisplayNames        = {}

-- Waypoint tracking (waypoints are navigation points, not stops)
local routeItems             = {}  -- Combined array: {type="stop"/"waypoint", trigger=trigger/waypointName=name, position=vec3, stopIndex=stopIndex}

-- Bus stop perimeter markers
local stopMarkerObjects       = {}
local stopPerimeterTrigger    = nil

-- forward declaration 
local isBus

-- ================================
-- CAPACITY DETECTION
-- ================================
local function specificCapacityCases(partName)
  if partName:find("capsule") and partName:find("seats") then
    if partName:find("sd12m") then return 25
    elseif partName:find("sd18m") then return 41
    elseif partName:find("sd105") then return 21
    elseif partName:find("sd_seats") then return 33
    elseif partName:find("dd105") then return 29
    elseif partName:find("sd195") then return 43
    elseif partName:find("lhd_artic_seats_upper") then return 77
    elseif partName:find("lhd_artic_seats") then return 30
    elseif partName:find("lh_seats_upper") then return 53
    elseif partName:find("lh_seats") then return 17
    elseif partName:find("lhd_seats_upper") then return 53
    elseif partName:find("lhd_seats") then return 17
    elseif partName:find("rhd_artic_seats_upper") then return 77
    elseif partName:find("rhd_artic_seats") then return 30
    end
  end

  if partName:find("schoolbus_seats_R_c") then return 10 end
  if partName:find("schoolbus_seats_L_c") then return 10 end
  if partName:find("limo_seat") then return 8 end

  return nil
end

local function cyclePartsTree(partData, seatingCapacity)
  for _, part in pairs(partData) do
    local partName = part.chosenPartName or ""

    if partName:find("seat") and not partName:find("cargo") and not partName:find("captains") then
      local seatSize = 1
      if partName:find("seats") then
        seatSize = 3
      elseif partName:find("ext") then
        seatSize = 2
      elseif partName:find("skin") then
        seatSize = 0
      end

      seatSize = specificCapacityCases(partName) or seatSize
      seatingCapacity = seatingCapacity + seatSize
    end

    if part.children then
      seatingCapacity = cyclePartsTree(part.children, seatingCapacity)
    end

    if partName == "pickup" then
      seatingCapacity = math.max(seatingCapacity, 7)
    end
  end

  return seatingCapacity
end

local function calculateSeatingCapacity()
  if not currentVehiclePartsTree then return 20 end
  return math.max(1, cyclePartsTree({currentVehiclePartsTree}, 0))
end

local function retrievePartsTree()
  currentVehiclePartsTree = nil
  local vehicle = be:getPlayerVehicle(0)
  if vehicle then
    vehicle:queueLuaCommand([[
      local partsTree = v.config.partsTree
      obj:queueGameEngineLua('career_modules_bus.returnPartsTree(' .. serialize(partsTree) .. ')')
    ]])
  end
end

function M.returnPartsTree(partsTree)
  currentVehiclePartsTree = partsTree
  local seats = calculateSeatingCapacity()
  M.vehicleCapacity = math.max(1, seats)

  local capOverrides = {
    ["schoolbus_interior_b"] = 24,
    ["schoolbus_interior_c"] = 40,
    ["prisonbus"] = 20,
    ["citybus_seats"] = 44,
    ["citybus"] = 44,
    ["dm_vanbus"] = 24,
    ["vanbus"] = 24,
    ["van_bus"] = 24,
    ["vanbusframe"] = 24
  }

  local capOverride = nil
  local function checkPartTreeForKeywords(tree)
    for k, v in pairs(tree) do
      if type(k) == "string" then
        local name = string.lower(k)
        for pattern, capacity in pairs(capOverrides) do
          if name:find(pattern) then
            capOverride = capacity
            print(string.format("[bus] %s detected via partsTree → capacity %d", pattern, capacity))
            return
          end
        end
      end
      if type(v) == "table" then checkPartTreeForKeywords(v) end
    end
  end

  checkPartTreeForKeywords(partsTree)

  if capOverride then
    M.vehicleCapacity = capOverride
  elseif M.vehicleCapacity <= 12 then
    M.vehicleCapacity = 12
    print("[bus] Generic or van-based transport detected → fallback capacity 12")
  end

  print(string.format("[bus] Vehicle seating capacity detected: %d seats", M.vehicleCapacity))
  ui_message(string.format("Vehicle seating capacity detected: %d passengers.", M.vehicleCapacity), 5, "info", "info")
end

-- ================================
-- BUS STOP PERIMETER MARKERS
-- ================================
-- Create a single corner marker
local function createCornerMarker(markerName)
  local marker = createObject('TSStatic')
  marker:setField('shapeName', 0, "art/shapes/interface/position_marker.dae")
  marker:setPosition(vec3(0, 0, 0))
  marker.scale = vec3(1, 1, 1)
  marker:setField('rotation', 0, '1 0 0 0')
  marker.useInstanceRenderData = true
  marker:setField('instanceColor', 0, '1 1 1 1')
  marker:setField('collisionType', 0, "Collision Mesh")
  marker:setField('decalType', 0, "Collision Mesh")
  marker:setField('playAmbient', 0, "1")
  marker:setField('allowPlayerStep', 0, "1")
  marker:setField('canSave', 0, "0")
  marker:setField('canSaveDynamicFields', 0, "1")
  marker:setField('renderNormals', 0, "0")
  marker:setField('meshCulling', 0, "0")
  marker:setField('originSort', 0, "0")
  marker:setField('forceDetail', 0, "-1")
  marker.canSave = false
  marker:registerObject(markerName)
  if scenetree and scenetree.MissionGroup then
    scenetree.MissionGroup:addObject(marker)
  end
  return marker
end

-- Helper to safely delete an object
local function safeDelete(obj, objName)
  if not obj then return end
  local success, err = pcall(function()
    local name = obj:getName()
    if name then
      local found = scenetree.findObject(name)
      if found then
        if editor and editor.onRemoveSceneTreeObjects then
          editor.onRemoveSceneTreeObjects({found:getId()})
        end
        found:delete()
      end
    end
    if obj:isValid() then
      if editor and editor.onRemoveSceneTreeObjects then
        editor.onRemoveSceneTreeObjects({obj:getId()})
      end
      obj:delete()
    end
  end)
  if not success and objName then
    print(string.format("[bus] Error deleting %s: %s", objName, tostring(err)))
  end
end

-- Clear all stop markers
local function clearStopMarkers()
  for _, obj in ipairs(stopMarkerObjects) do
    safeDelete(obj, "marker")
  end
  table.clear(stopMarkerObjects)
  safeDelete(stopPerimeterTrigger, "perimeter trigger")
  stopPerimeterTrigger = nil
end

-- Create perimeter markers and box trigger for a stop
local function createStopPerimeter(trigger)
  if not trigger then return end
  
  -- Clear any existing markers first
  clearStopMarkers()
  
  -- Get trigger position, rotation, and scale
  local triggerPos = trigger:getPosition()
  local triggerRot = trigger:getRotation()
  local triggerScale = trigger:getScale()
  
  -- Use trigger's scale if available, otherwise use reasonable defaults
  local stopLength = triggerScale and triggerScale.x or 15  -- Length along road
  local stopWidth = triggerScale and triggerScale.y or 8    -- Width perpendicular to road
  local stopHeight = triggerScale and triggerScale.z or 5   -- Height for raycasting
  
  -- Convert rotation to quaternion for calculations
  local rot = quat(triggerRot)
  local vecX = rot * vec3(1, 0, 0)  -- Right vector
  local vecY = rot * vec3(0, 1, 0)   -- Forward vector
  local vecZ = rot * vec3(0, 0, 1)   -- Up vector
  
  -- Calculate corner positions
  local halfLength = stopLength * 0.5
  local halfWidth = stopWidth * 0.5
  
  local corners = {
    {pos = triggerPos - vecX * halfLength + vecY * halfWidth, name = "TL"}, -- Top Left
    {pos = triggerPos + vecX * halfLength + vecY * halfWidth, name = "TR"}, -- Top Right
    {pos = triggerPos + vecX * halfLength - vecY * halfWidth, name = "BR"}, -- Bottom Right
    {pos = triggerPos - vecX * halfLength - vecY * halfWidth, name = "BL"}  -- Bottom Left
  }
  
  -- Create corner markers
  local qOff = quatFromEuler(0, 0, math.pi/2) * quatFromEuler(0, math.pi/2, math.pi/2)
  local rotations = {
    quatFromEuler(0, 0, math.rad(90)),   -- TL
    quatFromEuler(0, 0, math.rad(180)),  -- TR
    quatFromEuler(0, 0, math.rad(270)),   -- BR
    quatFromEuler(0, 0, 0)                -- BL
  }
  
  -- Use timestamp to ensure unique marker names and avoid collisions
  local uniqueId = os.time() * 1000 + (os.clock() * 1000 % 1000)  -- milliseconds precision
  for i, corner in ipairs(corners) do
    local markerName = string.format("busStopMarker_%s_%d_%d", trigger:getName() or "unknown", i, uniqueId)
    
    -- Raycast to ground
    local hit = Engine.castRay(corner.pos + vecZ * 2, corner.pos - vecZ * 10, true, false)
    local groundPos = hit and vec3(hit.pt) or (corner.pos + vecZ * 0.05)
    groundPos = groundPos + vecZ * 0.05
    
    -- Calculate rotation
    local hitNorm = hit and vec3(hit.norm) or vecZ
    local finalRot = rotations[i] * qOff * quatFromDir(hitNorm, vecY)
    
    -- Create and position marker
    local marker = createCornerMarker(markerName)
    marker:setPosRot(groundPos.x, groundPos.y, groundPos.z, finalRot.x, finalRot.y, finalRot.z, finalRot.w)
    marker:setField('instanceColor', 0, "0.6 0.9 0.23 1")  -- Green color for bus stops
    table.insert(stopMarkerObjects, marker)
  end
  
  -- Create box trigger for perimeter detection (optional - if you want to use it for validation)
  local perimeterName = string.format("busStopPerimeter_%s_%d", trigger:getName() or "unknown", uniqueId)
  local perimeterTrigger = createObject('BeamNGTrigger')
  perimeterTrigger.loadMode = 1
  perimeterTrigger:setField("triggerType", 0, "Box")
  perimeterTrigger:setPosition(triggerPos)
  perimeterTrigger:setScale(vec3(stopLength, stopWidth, stopHeight))
  local rotTorque = rot:toTorqueQuat()
  perimeterTrigger:setField('rotation', 0, rotTorque.x .. ' ' .. rotTorque.y .. ' ' .. rotTorque.z .. ' ' .. rotTorque.w)
  perimeterTrigger:registerObject(perimeterName)
  stopPerimeterTrigger = perimeterTrigger
  
  print(string.format("[bus] Created perimeter markers for stop: %s (scale: %.1f x %.1f x %.1f)", 
    trigger:getName() or "unknown", stopLength, stopWidth, stopHeight))
end

-- Show markers for current stop (or specified stop index)
local function showCurrentStopMarkers(stopIndex)
  local targetStopIndex = stopIndex or currentStopIndex
  if not targetStopIndex or not stopTriggers or not stopTriggers[targetStopIndex] then 
    print("[bus] showCurrentStopMarkers: Invalid stop index or triggers")
    return 
  end
  
  local currentTrigger = stopTriggers[targetStopIndex]
  local triggerName = currentTrigger:getName() or "unknown"
  print(string.format("[bus] Showing markers for stop %d: %s", targetStopIndex, triggerName))
  createStopPerimeter(currentTrigger)
end

-- Hide markers (cleanup)
local function hideStopMarkers()
  clearStopMarkers()
end

-- ================================
-- UTILITIES
-- ================================
isBus = function(vehicle)
  return vehicle and core_vehicles.getVehicleLicenseText(vehicle) == "BUS"
end

local function getNextTrigger()
  if not currentStopIndex then return nil end
  return stopTriggers[currentStopIndex]
end

-- Helper to get position from route item
local function getItemPosition(item)
  return item.position or (item.trigger and item.trigger:getPosition())
end

-- Build path through waypoints to target stop
local function buildPathToStop(targetStopIndex, startPos, fromStopIndex)
  local pathPoints = {startPos}
  if not routeItems or #routeItems == 0 then
    return pathPoints
  end
  
  -- Find the stop we're currently at (not the target)
  -- Use fromStopIndex if provided, otherwise use currentStopIndex
  local currentStopIdx = fromStopIndex or currentStopIndex or 1
  local nextStopIndex = targetStopIndex
  if nextStopIndex > #stopTriggers then
    nextStopIndex = 1
  end
  
  -- Find current stop's position in routeItems
  local currentItemIndex = nil
  print(string.format("[bus] DEBUG: Searching for current stop with stopIndex=%d in routeItems (total items: %d)", currentStopIdx, #routeItems))
  for i, item in ipairs(routeItems) do
    local itemName = item.waypointName or (item.trigger and item.trigger:getName()) or "unknown"
    print(string.format("[bus] DEBUG: routeItems[%d]: type=%s, stopIndex=%s, name=%s", i, item.type, tostring(item.stopIndex), itemName))
    if item.type == "stop" and item.stopIndex == currentStopIdx then
      currentItemIndex = i
      print(string.format("[bus] DEBUG: Found current stop at routeItems index %d", i))
      break
    end
  end
  
  -- If we couldn't find current stop, try to find target stop directly
  if not currentItemIndex then
    for i, item in ipairs(routeItems) do
      if item.type == "stop" and item.stopIndex == nextStopIndex then
        -- Found target stop, add it and return
        local pos = getItemPosition(item)
        if pos then table.insert(pathPoints, pos) end
        return pathPoints
      end
    end
    return pathPoints -- No stops found
  end
  
  -- Add waypoints and target stop (iterate forward from current stop)
  local waypointCount = 0
  if currentItemIndex then
    print(string.format("[bus] DEBUG: Starting search from routeItems index %d, looking for waypoints before stop %d", currentItemIndex + 1, nextStopIndex))
    for i = currentItemIndex + 1, #routeItems do
      local item = routeItems[i]
      local itemName = item.waypointName or (item.trigger and item.trigger:getName()) or "unknown"
      print(string.format("[bus] DEBUG: Checking routeItems[%d]: type=%s, stopIndex=%s, name=%s", i, item.type, tostring(item.stopIndex), itemName))
      if item.type == "waypoint" then
        local pos = getItemPosition(item)
        if pos then 
          table.insert(pathPoints, pos)
          waypointCount = waypointCount + 1
          print(string.format("[bus] Added waypoint '%s' to path", item.waypointName or "unknown"))
        else
          print(string.format("[bus] DEBUG: Waypoint '%s' has no position!", item.waypointName or "unknown"))
        end
      elseif item.type == "stop" then
        print(string.format("[bus] DEBUG: Found stop with stopIndex=%d, looking for stopIndex=%d", item.stopIndex, nextStopIndex))
        if item.stopIndex == nextStopIndex then
          local pos = getItemPosition(item)
          if pos then table.insert(pathPoints, pos) end
          print(string.format("[bus] Path built: %d waypoints between stop %d and stop %d", waypointCount, currentStopIdx, nextStopIndex))
          break
        elseif item.stopIndex > nextStopIndex then
          print(string.format("[bus] DEBUG: Stop index %d > target %d, breaking search", item.stopIndex, nextStopIndex))
          break
        end
      end
    end
  else
    print(string.format("[bus] DEBUG: Could not find current stop (stopIndex=%d) in routeItems!", currentStopIdx))
  end
  
  if waypointCount == 0 then
    print(string.format("[bus] No waypoints found between stop %d and stop %d", currentStopIdx, nextStopIndex))
  end
  
  return pathPoints
end

local function showNextStopMarker(targetStopIndex)
  -- If targetStopIndex is provided, use it; otherwise calculate from currentStopIndex
  local nextStopIndex = targetStopIndex
  if not nextStopIndex then
    nextStopIndex = (currentStopIndex or 1) + 1
    if nextStopIndex > #stopTriggers then
      nextStopIndex = 1
    end
  end
  
  local trigger = stopTriggers[nextStopIndex]
  if not trigger then return end
  
  core_groundMarkers.resetAll()
  local vehicle = be:getPlayerVehicle(0)
  local targetPos = trigger:getPosition()
  
  if vehicle then
    -- Use the route planner that core_groundMarkers uses (shared instance)
    local routePlanner = core_groundMarkers.routePlanner or require('gameplay/route/route')()
    if not core_groundMarkers.routePlanner then
      core_groundMarkers.routePlanner = routePlanner
    end
    
    -- Calculate the stop we're coming FROM (target - 1, or wrap around)
    local fromStopIndex = nextStopIndex - 1
    if fromStopIndex < 1 then
      fromStopIndex = #stopTriggers
    end
    
    local pathPoints = buildPathToStop(nextStopIndex, vehicle:getPosition(), fromStopIndex)
    
    if #pathPoints == 1 then
      pathPoints[2] = targetPos
    end
    
    -- Set up multi-waypoint path on the shared route planner
    routePlanner:setupPathMulti(pathPoints)
    print(string.format("[bus] Route planner set up with %d path points (including waypoints)", #pathPoints))
    
    -- If we have waypoints, we need to activate ground markers but preserve the route planner's path
    if #pathPoints > 2 then
      print(string.format("[bus] Multi-waypoint path detected (%d waypoints)", #pathPoints - 2))
      -- Wait for route planner to calculate, then manually activate ground markers WITHOUT setPath
      if core_jobsystem and core_jobsystem.create then
        core_jobsystem.create(function(job)
          job.sleep(0.2)
          if routePlanner.path and #routePlanner.path > 0 then
            print(string.format("[bus] Route planner calculated path with %d segments", #routePlanner.path))
            -- Manually initialize ground markers without calling setPath
            if not core_groundMarkers.endWP then
              core_groundMarkers.endWP = {}
            end
            -- Set the target position to the final destination
            core_groundMarkers.endWP[1] = targetPos
            -- DON'T call setPath - it calculates a direct path that conflicts with waypoints
            -- The route planner's path should be used automatically by ground markers
            -- Ensure route planner is properly set up
            routePlanner:setupPathMulti(pathPoints)
          else
            print("[bus] Warning: Route planner path not ready, falling back to direct path")
            core_groundMarkers.setPath(targetPos)
          end
        end)
      end
    else
      -- No waypoints, use direct path
      print("[bus] No waypoints found, using direct path")
      core_groundMarkers.setPath(targetPos)
    end
  else
    -- No vehicle, fallback to direct path
    core_groundMarkers.setPath(targetPos)
  end
  
  -- Show markers for the NEXT stop (not current)
  showCurrentStopMarkers(nextStopIndex)
end

-- ================================
-- ROUTE END 
-- ================================
local function endRoute(reason, payout)
  currentRouteActive = false
  dwellTimer = nil
  routeInitialized = false
  currentFinalStopName = nil
  currentRouteName = nil
  core_groundMarkers.resetAll()
  -- Clear any markers
  hideStopMarkers()

  local msg = "Shift ended."
  if reason then msg = msg .. " (" .. reason .. ")" end

  local reputationGain = 0

  if payout and payout > 0 then
    local basePay = accumulatedReward
    local tipsEarned = tipTotal
    local bonusPay = math.max(0, payout - (basePay + tipsEarned))

    reputationGain = math.floor(payout / 500)

    msg = msg .. string.format(
      "\nStops completed: %d" ..
      "\nBase pay:   $%d" ..
      "\nTips:       $%d" ..
      "\nBonus:      $%d" ..
      "\n--------------------" ..
      "\nTotal payout: $%d" ..
      "\nReputation gained: +%d",
      totalStopsCompleted, basePay, tipsEarned, bonusPay, payout,
      reputationGain
    )
  else
    msg = msg .. "\nNo payout earned."
  end

  ui_message(msg, 8, "info", "info")
  print("[bus] " .. msg:gsub("\n", " "))

  -- Reset displays
  local vehicle = be:getPlayerVehicle(0)
  if vehicle then
    vehicle:queueLuaCommand([[
      if controller and controller.onGameplayEvent then
        controller.onGameplayEvent("bus_onRouteChange", {
          routeId="00", routeID="00", direction="Not in Service", tasklist={}
        })
      end
    ]])
  end

  -- Rewards
  if payout and payout > 0 and career_career and career_career.isActive()
     and career_modules_payment and career_modules_payment.reward then
    career_modules_payment.reward({
      money={amount=payout},
      beamXP={amount=math.floor(payout/10)},  -- XP unchanged
      busWorkReputation={amount=reputationGain}
    },{
      label=string.format("Bus Route Earnings: $%d", payout),
      tags={"transport","bus","gameplay"}
    },true)
  end

  accumulatedReward, passengersOnboard, totalStopsCompleted, tipTotal = 0,0,0,0
  roughRide, lastVelocity, activeBusID = 0,nil,nil
end

-- ================================
-- ROUTE INITIALIZATION
-- ================================
local function loadRoutesFromJSON()
  local currentMap = getCurrentLevelIdentifier()
  print(string.format("[bus] Current map identifier: %s", tostring(currentMap)))
  if not currentMap then 
    print("[bus] No current map identifier found")
    return nil 
  end

  local routeFiles = {
    ["west_coast_usa"] = "/levels/west_coast_usa/wcuBusRoutes.json",
    ["jungle_rock_island"] = "/levels/jungle_rock_island/jriBusRoutes.json"
  }

  local routeFile = routeFiles[currentMap]
  if not routeFile then 
    print(string.format("[bus] No route file configured for map: %s", currentMap))
    local availableMaps = {}
    for k, _ in pairs(routeFiles) do
      table.insert(availableMaps, k)
    end
    print(string.format("[bus] Available maps in routeFiles: %s", table.concat(availableMaps, ", ")))
    return nil 
  end

  print(string.format("[bus] Loading route file: %s", routeFile))
  local routeData = jsonReadFile(routeFile)
  if not routeData then
    print(string.format("[bus] Failed to read route file: %s", routeFile))
    return nil
  end
  if not routeData.routes then
    print(string.format("[bus] Route file %s does not contain 'routes' key", routeFile))
    return nil
  end

  print(string.format("[bus] Successfully loaded routes from %s", routeFile))
  return routeData.routes
end

-- Helper function to update bus controller display
local function updateBusControllerDisplay()
  if not currentRouteActive or not currentStopIndex or not stopTriggers or #stopTriggers == 0 then return end
  
  -- Build route data for the bus controller 
  local routeData = {routeId = "RLS", routeID = "RLS", direction = "", tasklist = {}}

  -- Get current stop's display name
  local currentStop = stopTriggers[currentStopIndex]
  local triggerName = currentStop:getName() or ""
  routeData.direction = stopDisplayNames[triggerName] or triggerName or string.format("Stop %02d", currentStopIndex)

  -- Build tasklist (only stops, waypoints excluded)
  local function addStopToList(i)
    local t = stopTriggers[i]
    local name = t:getName() or ""
    local label = stopDisplayNames[name] or string.format("Stop %02d", i)
    table.insert(routeData.tasklist, {name, label})
  end
  
  for i = currentStopIndex, #stopTriggers do
    addStopToList(i)
  end
  for i = 1, currentStopIndex - 1 do
    addStopToList(i)
  end

  -- Send to vehicle controller (for bus_setLineInfo)
  local vehicle = be:getPlayerVehicle(0)
  if vehicle then
    vehicle:queueLuaCommand(string.format([[
      if controller and controller.onGameplayEvent then
        controller.onGameplayEvent("bus_setLineInfo", %s)
      end
    ]], dumps(routeData)))
  end

  -- Also send BusDisplayUpdate for the UI
  guihooks.trigger('BusDisplayUpdate', routeData)
end

local function initRoute()
  -- Don't reinitialize if a route is already active
  if currentRouteActive and routeInitialized then
    print("[bus] Route already active, skipping reinitialization")
    return
  end


  -- Check if bus multiplier is 0 (if economy adjuster supports it)
  if career_economyAdjuster then
    local busMultiplier = career_economyAdjuster.getSectionMultiplier("bus") or 1.0
    if busMultiplier == 0 then
      ui_message("Bus routes are currently disabled.", 5, "error", "error")
      print("[bus] Bus multiplier is set to 0, route initialization cancelled")
      return
    end
  end


  stopTriggers = {}
  
  -- Load routes from JSON
  local routes = loadRoutesFromJSON()
  if not routes then
    ui_message("No route configuration found for this map.", 5, "error", "error")
    return
  end

  -- Collect all bus stop triggers and waypoints on the map
  local allTriggers = {}
  local allWaypoints = {}
  local function processObject(obj)
    local objRef = type(obj) == "string" and scenetree.findObject(obj) or obj
    if not objRef then return end
    local name = objRef:getName() or ""
    if name:match("_bs_%d+$") or name:match("_bs_%d+_b$") then
      allTriggers[name] = objRef
    elseif name:match("_wp_") or name:match("_waypoint_") then
      allWaypoints[name] = objRef
    end
  end
  
  -- Collect bus stops from triggers
  for _, obj in ipairs(scenetree.findClassObjects("BeamNGTrigger") or {}) do
    processObject(obj)
  end
  
  -- Collect waypoints from BeamNGWaypoint objects
  for _, obj in ipairs(scenetree.findClassObjects("BeamNGWaypoint") or {}) do
    processObject(obj)
  end
  
  -- Also check SimObject as fallback (in case waypoints are registered differently)
  for _, obj in ipairs(scenetree.findClassObjects("SimObject") or {}) do
    processObject(obj)
  end
  
  print(string.format("[bus] DEBUG: Found %d waypoints in scenetree", table.getn(allWaypoints) or 0))
  for name, _ in pairs(allWaypoints) do
    print(string.format("[bus] DEBUG:   - %s", name))
  end

  if not next(allTriggers) then
    ui_message("No bus stops found on this map.", 5, "error", "error")
    return
  end
  -- Select a random route
  local routeKeys = {}
  for k in pairs(routes) do
    table.insert(routeKeys, k)
  end
  if #routeKeys == 0 then
    ui_message("No routes available in configuration.", 5, "error", "error")
    return
  end

  local selectedRouteKey = routeKeys[math.random(#routeKeys)]
  local selectedRoute = routes[selectedRouteKey]
  local routeName = selectedRoute.name or selectedRouteKey
  currentRouteName = routeName

  print(string.format("[bus] Selected route: %s (%s) with %d stops", routeName, selectedRouteKey, #selectedRoute.stops))

  -- Build route from JSON stop names and waypoints
  stopTriggers = {}
  routeItems = {}
  stopDisplayNames = {}
  local missingStops = {}
  local stopIndex = 0  -- Track actual stop index (waypoints don't count)
  
  for _, stopData in ipairs(selectedRoute.stops) do
    local itemType = "stop"  -- Default to stop
    local stopName, displayName
    
    if type(stopData) == "table" then
      -- Check if first element is "waypoint" marker (explicit format)
      if stopData[1] == "wp" then
        itemType = "waypoint"
        stopName = stopData[2]
        displayName = stopData[3]  -- Optional display name
      else
        -- Format: ["triggerName", "Display Name"]
        stopName = stopData[1]
        displayName = stopData[2]
        -- Auto-detect waypoints by name pattern (consistent with bus stop detection)
        if stopName:match("_wp_") or stopName:match("_waypoint_") then
          itemType = "waypoint"
        end
      end
    end
    if itemType == "waypoint" then
      -- Use pre-collected waypoints instead of looking them up individually
      local waypointObj = allWaypoints[stopName]
      if waypointObj then
        local waypointPos = waypointObj:getPosition()
        table.insert(routeItems, {
          type="waypoint", 
          waypointName=stopName, 
          position=waypointPos, 
          stopIndex=stopIndex  -- Use current stopIndex (waypoint comes after this stop)
        })
        -- Display name stored but not used in UI (waypoints are hidden)
        if displayName then
          stopDisplayNames[stopName] = displayName
        end
        print(string.format("[bus] Found waypoint '%s' at %s", stopName, tostring(waypointPos)))
      else
        table.insert(missingStops, stopName)
        print(string.format("[bus] Warning: Waypoint '%s' not found in scenetree", stopName))
      end
    else
      -- Bus stop: must be a trigger
      local trigger = allTriggers[stopName]
      if trigger then
        stopIndex = stopIndex + 1
        table.insert(stopTriggers, trigger)
        table.insert(routeItems, {
          type="stop", 
          trigger=trigger, 
          position=trigger:getPosition(), 
          stopIndex=stopIndex
        })
        -- Store display name by trigger name for reliable access
        if displayName then
          stopDisplayNames[stopName] = displayName
        end
      else
        table.insert(missingStops, stopName)
      end
    end
  end
  if #stopTriggers == 0 then
    ui_message("No valid stops found for selected route.", 5, "error", "error")
    return
  end

  if #missingStops > 0 then
    print(string.format("[bus] Warning: %d stops not found: %s", #missingStops, table.concat(missingStops, ", ")))
  end

  -- The final stop is the last stop in the route
  currentFinalStopName = stopTriggers[#stopTriggers]:getName() or ""

  local vehicle = be:getPlayerVehicle(0)
  if not vehicle then return end

  -- Always start from the first stop of the route
  currentStopIndex = 1
  consecutiveStops, dwellTimer, accumulatedReward, totalStopsCompleted = 0, nil, 0, 0
  currentRouteActive, routeInitialized, passengersOnboard, routeCooldown = true, true, 0, 0
  tipTotal, roughRide, lastVelocity = 0, 0, nil

  local startStopName = stopTriggers[currentStopIndex]:getName() or "Unknown"
  local targetPos = stopTriggers[currentStopIndex]:getPosition()
  
  if vehicle then
    -- Use the route planner that core_groundMarkers uses (shared instance)
    local routePlanner = core_groundMarkers.routePlanner or require('gameplay/route/route')()
    if not core_groundMarkers.routePlanner then
      core_groundMarkers.routePlanner = routePlanner
    end
    
    local pathPoints = buildPathToStop(1, vehicle:getPosition())
    if #pathPoints == 1 then
      pathPoints[2] = targetPos
    end
    
    -- Set up multi-waypoint path on the shared route planner
    routePlanner:setupPathMulti(pathPoints)
    print(string.format("[bus] Route planner initialized with %d path points (including waypoints)", #pathPoints))
    
    -- If we have waypoints, we need to activate ground markers but preserve the route planner's path
    if #pathPoints > 2 then
      print(string.format("[bus] Multi-waypoint path detected (%d waypoints)", #pathPoints - 2))
      -- Wait for route planner to calculate, then manually activate ground markers WITHOUT setPath
      if core_jobsystem and core_jobsystem.create then
        core_jobsystem.create(function(job)
          job.sleep(0.2)
          if routePlanner.path and #routePlanner.path > 0 then
            print(string.format("[bus] Route planner calculated path with %d segments", #routePlanner.path))
            -- Manually initialize ground markers without calling setPath
            if not core_groundMarkers.endWP then
              core_groundMarkers.endWP = {}
            end
            -- Set the target position to the final destination
            core_groundMarkers.endWP[1] = targetPos
            -- DON'T call setPath - it calculates a direct path that conflicts with waypoints
            -- The route planner's path should be used automatically by ground markers
            -- Ensure route planner is properly set up
            routePlanner:setupPathMulti(pathPoints)
          else
            print("[bus] Warning: Route planner path not ready, falling back to direct path")
            core_groundMarkers.setPath(targetPos)
          end
        end)
      end
    else
      -- No waypoints, use direct path
      print("[bus] No waypoints found, using direct path")
      core_groundMarkers.setPath(targetPos)
    end
  else
    -- No vehicle, fallback to direct path
    core_groundMarkers.setPath(targetPos)
  end
  
  ui_message(
      string.format("Bus route '%s' started. Proceed to %s. Route has %d stops.", routeName, startStopName, #stopTriggers),
      6, "info", "info")

  -- Update bus controller display
  updateBusControllerDisplay()
  
  -- Show markers for first stop
  showCurrentStopMarkers()
end
-- ================================
-- PROCESS STOP 
-- ================================
local function processStop(vehicle, dtSim)
  if not currentRouteActive or not currentStopIndex then return end
  if routeCooldown > 0 then return end
  if not stopTriggers or #stopTriggers == 0 then return end
  if currentStopIndex < 1 or currentStopIndex > #stopTriggers then return end

  local trigger = getNextTrigger()
  if not trigger then return end

  -- Verify this is the correct stop
  local expectedStopName = stopTriggers[currentStopIndex]:getName()
  if expectedStopName and trigger:getName() ~= expectedStopName then
      return
  end

  -- Check if player is actually inside the correct trigger
  if currentTriggerName == trigger:getName() then
      -- Prevent re-boarding if player left and came back to the same stop
      -- Only allow boarding if this stop hasn't had boarding initiated yet, or if it's a different stop
      if stopIndexWhereBoardingStarted and stopIndexWhereBoardingStarted == currentStopIndex and dwellTimer == nil then
          -- Player already started boarding at this stop and left - don't allow re-boarding
          return
      end
      
      local velocity = vehicle:getVelocity():length()

      -- Must be fully stopped
      if velocity > 0.5 then
          ui_message("Come to a complete stop before passengers can board.", 2, "info", "info")
          dwellTimer = nil
          stopMonitorActive = false
          stopSettleTimer = 0
          return
      end

      -- Stop monitoring and settle
      if not stopMonitorActive then
          stopMonitorActive = true
          stopSettleTimer = 0
          ui_message("Please open doors to begin boarding", 2.5, "info", "bus")
      else
          stopSettleTimer = stopSettleTimer + (dtSim or 0.033)
      end

      -- Must remain still for settle delay
      if stopSettleTimer < stopSettleDelay then
          dwellTimer = nil
          return
      end
        ------------------------------------------------------------
        -- START DWELL (Initialize boarding + deboarding)
        ------------------------------------------------------------
        if not dwellTimer then
            dwellTimer = 0
            -- Track that boarding has started at this stop
            stopIndexWhereBoardingStarted = currentStopIndex
            -- Hide stop perimeter markers once boarding starts
            hideStopMarkers()
            consecutiveStops = consecutiveStops + 1
            totalStopsCompleted = totalStopsCompleted + 1

            -- Final stop? (Map-specific)
            local triggerName = trigger:getName() or ""
            local isFinalStop = (triggerName == currentFinalStopName)

            if isFinalStop then
                trueBoarding = 0
                trueDeboarding = passengersOnboard
                dwellDuration = math.max(6, trueDeboarding * 0.6)
            else
                local capacity = M.vehicleCapacity
                local availableSpace = math.max(0, capacity - passengersOnboard)
                trueBoarding = math.random(3, math.min(12, availableSpace))
                trueDeboarding = (passengersOnboard > 0)
                    and math.random(1, math.min(passengersOnboard, 6))
                    or 0

                dwellDuration =
                    math.random(8, 12)
                    + (trueBoarding * 0.8)
                    + (trueDeboarding * 0.5)
            end

            ------------------------------------------------------------
            -- Initialize animation coroutine (REALISTIC TIMING)
            ------------------------------------------------------------
            boardingCoroutine = coroutine.create(function()

                --------------------------------------------------------
                -- PHASE 1 — DEBOARDING 
                --------------------------------------------------------
                local function waitForAnimation(duration)
                    local t = 0
                    while t < duration do
                        coroutine.yield()
                        t = t + (dtSim or 0.033)
                    end
                end

                if trueDeboarding > 0 then
                    for i = trueDeboarding, 1, -1 do
                        ui_message(string.format("Stop %d\nDeboarding: %d\nBoarding: 0", currentStopIndex, i), 2, "bus", "bus_anim")
                        waitForAnimation(2)
                    end
                else
                    ui_message(string.format("Stop %d\nDeboarding: 0\nBoarding: 0", currentStopIndex), 1, "bus", "bus_anim")
                end

                --------------------------------------------------------
                -- PHASE 2 — BOARDING 
                --------------------------------------------------------
                if trueBoarding > 0 then
                    for i = 1, trueBoarding do
                        ui_message(string.format("Stop %d\nDeboarding: 0\nBoarding: %d", currentStopIndex, i), 2, "bus", "bus_anim")
                        waitForAnimation(2)
                    end
                else
                    ui_message(string.format("Stop %d\nDeboarding: 0\nBoarding: 0", currentStopIndex), 1, "bus", "bus_anim")
                end

			--------------------------------------------------------
			-- FINAL POST-BOARDING MESSAGE
			--------------------------------------------------------
				local newCount = math.min(
					math.max(0, passengersOnboard + trueBoarding - trueDeboarding),
					M.vehicleCapacity
				)

				ui_message(string.format(
					"Stop %d complete!\nPassengers onboard: %d",
					currentStopIndex, newCount
				), 4, "bus", "bus_done")

				--------------------------------------------------------
				-- SHOW EARNINGS / TIPS / REPUTATION 
				--------------------------------------------------------
				local base = 400
				local bonusMultiplier = 1 + (consecutiveStops / #stopTriggers) * 3
				local payout = math.floor(base * bonusMultiplier)
				local reputationGain = math.floor(payout / 500)

				ui_message(string.format(
					"Earnings this stop:\n" ..
					"Base pay: $%d\n" ..
					"Reputation gained: +%d\n" ..
					"Total tips so far: $%d",
					payout, reputationGain, tipTotal
				), 10, "info", "bus_payout")

            end)

        end -- dwell init

        ------------------------------------------------------------
        -- DWELL TIMER (controls WHEN boarding finishes)
        ------------------------------------------------------------
        dwellTimer = dwellTimer + (dtSim or 0.033)

        if dwellTimer >= dwellDuration and (not boardingCoroutine or coroutine.status(boardingCoroutine) == "dead") then
            print(string.format("[bus] Dwell complete at stop %d", currentStopIndex))

            --------------------------------------------------------
            -- FINALIZE passenger count
            --------------------------------------------------------
            passengersOnboard = math.min(
                math.max(0, passengersOnboard + trueBoarding - trueDeboarding),
                M.vehicleCapacity
            )

            --------------------------------------------------------
            -- PAYOUT CALCULATION
            --------------------------------------------------------
            local base = 400
            local bonusMultiplier = 1 + (consecutiveStops / #stopTriggers) * 3
            local payout = math.floor(base * bonusMultiplier)
            
            if career_economyAdjuster then
                local multiplier = career_economyAdjuster.getSectionMultiplier("bus") or 1.0
                payout = math.floor(payout * multiplier + 0.5)
            end
            
            accumulatedReward = accumulatedReward + payout

            --------------------------------------------------------
            -- TIP CALCULATION (ONLY if deboarders)
            --------------------------------------------------------
            local tipsEarned = 0
            if trueDeboarding > 0 then
                local avgRough = math.max(0, roughRide / math.max(1, dwellDuration))
                local tipPerPassenger = math.max(0, 8 - avgRough) * 2
                tipsEarned = math.floor(tipPerPassenger * trueDeboarding * 40)
                tipTotal = tipTotal + tipsEarned
            end
            print(string.format("[bus] Tips: +%d   TotalTips=%d", tipsEarned, tipTotal))

            roughRide = 0

            --------------------------------------------------------
            -- RESET STOP STATE
            --------------------------------------------------------
            dwellTimer = nil
            stopMonitorActive = false
            stopSettleTimer = 0
            stopIndexWhereBoardingStarted = nil  -- Clear the flag when stop is completed
            currentTriggerName = nil  -- Clear trigger name to prevent re-entry issues

            --------------------------------------------------------
            -- MOVE TO NEXT STOP
            --------------------------------------------------------
            local triggerName = trigger:getName() or ""
            if triggerName == currentFinalStopName then
                -- Loop bonus
                local loopBonus = math.floor(accumulatedReward * 0.5)
                accumulatedReward = accumulatedReward + loopBonus
                local totalPotential = accumulatedReward + tipTotal

                ui_message(string.format(
                    "All passengers unloaded.\nLoop complete! Bonus +$%d (+50%%)\nRoute earnings so far: $%d\nTips: $%d\nTotal potential payout: $%d",
                    loopBonus, accumulatedReward, tipTotal, totalPotential
                ), 6, "info", "info")

                passengersOnboard = 0
                trueBoarding = 0
                trueDeboarding = 0

                routeCooldown = 10
                -- Update currentStopIndex BEFORE setting navigation
                currentStopIndex = 1
                -- Explicitly route to stop 1 (not stop 2)
                showNextStopMarker(1)
                -- Update controller display after loop completion
                updateBusControllerDisplay()
                
                -- Save the game after completing the loop
                if career_saveSystem and career_saveSystem.saveCurrent then
                    career_saveSystem.saveCurrent()
                end

            else
                -- Calculate next stop index
                local nextStopIndex = math.min((currentStopIndex or 1) + 1, #stopTriggers)
                local nextStopName = stopTriggers[nextStopIndex]:getName() or "Unknown"
                print(string.format("[bus] Moving to next stop: index %d, name %s", nextStopIndex, nextStopName))
                -- Update currentStopIndex BEFORE setting navigation to prevent race conditions
                currentStopIndex = nextStopIndex
                -- Show path to next stop (from current stop to next stop)
                showNextStopMarker(nextStopIndex)
                ui_message(string.format("Proceed to Stop %02d.", currentStopIndex), 4, "info", "bus_next")
                updateBusControllerDisplay()
            end
        end

    ------------------------------------------------------------
    -- PLAYER MOVED AWAY FROM STOP → CANCEL DWELL
    ------------------------------------------------------------
    else
        dwellTimer = nil
        stopMonitorActive = false
        stopSettleTimer = 0
    end
end
-- ================================
-- VEHICLE SWITCH 
-- ================================
function M.onVehicleSwitched(oldId, newId)
    local newVeh = be:getObjectByID(newId)

    -- Leaving the active bus ends the route
    if currentRouteActive and activeBusID and oldId == activeBusID then
        local payout = accumulatedReward + tipTotal
        if payout > 100000 then payout = 100000 end
        endRoute("player exited the bus", payout)
    end

    if newVeh and isBus(newVeh) then
        -- Only initialize route if we're not already in an active route
        if not currentRouteActive or not routeInitialized then
            activeBusID = newId
            ui_message("Shift started. Welcome in! Drive careful out there.", 10, "info", "info")
            -- Initialize capacity to a reasonable default before async callback completes
            -- The async callback will update it to the correct value when it finishes
            M.vehicleCapacity = M.vehicleCapacity or 44
            retrievePartsTree()
            initRoute()
        else
            -- Route already active, just update the active bus ID
            activeBusID = newId
            print("[bus] Route already active, not reinitializing")
        end
    end
end

-- ================================
-- EXTENSION LOADED
-- ================================
local function onExtensionLoaded()
    ui_message("Bus module loaded. Enter a BUS vehicle to begin your route.", 3, "info", "info")
    print("[bus] Extension loaded.")
    extensions.load("career_modules_bus")
end

-- ================================
-- UPDATE LOOP
-- ================================
function M.onUpdate(dtReal, dtSim, dtRaw)
    -- Route cooldown between loops
    if routeCooldown > 0 then
        routeCooldown = math.max(0, routeCooldown - (dtSim or 0))
        return
    end

    local vehicle = be:getPlayerVehicle(0)
    if not vehicle or not isBus(vehicle) or not routeInitialized then return end

    ------------------------------------------------------------
    -- Advance the REALISTIC BOARDING ANIMATION coroutine
    ------------------------------------------------------------
    if boardingCoroutine
       and coroutine.status(boardingCoroutine) ~= "dead" then

        local ok, err = coroutine.resume(boardingCoroutine)
        if not ok then
            print("[bus] Boarding animation coroutine error: " .. tostring(err))
            boardingCoroutine = nil
        end
    end

    ------------------------------------------------------------
    -- Rough ride tracking
    ------------------------------------------------------------
    local velocity = vehicle:getVelocity()

    if lastVelocity then
        local deltaVel = velocity - lastVelocity
        local safeDt = (dtSim and dtSim > 0) and dtSim or 0.01
        local accel = deltaVel:length() / safeDt
        local accelThreshold = 3.5

        if accel > accelThreshold then
            roughRide = roughRide + (accel - accelThreshold) * safeDt * 10
        end
    end

    lastVelocity = velocity

    ------------------------------------------------------------
    -- Core stop logic
    ------------------------------------------------------------
    processStop(vehicle, dtSim)
end

local function onBeamNGTrigger(data)
  if be:getPlayerVehicleID(0) ~= data.subjectID then
    return
  end
  if gameplay_walk.isWalking() then return end
  
  if not data.triggerName:find("_bs_") then return end
  
  if data.event == "enter" then
    currentTriggerName = data.triggerName
  elseif data.event == "exit" then
    if currentTriggerName == data.triggerName then
      currentTriggerName = nil
      -- Cancel dwell if player exits the stop
      dwellTimer = nil
      stopMonitorActive = false
      stopSettleTimer = 0
    end
  end
end
M.onBeamNGTrigger = onBeamNGTrigger
M.onExtensionLoaded = onExtensionLoaded
return M
