-- Vehicle performance tests: acceleration, braking and result capture.
-- The stock fork owns the test vehicle, cameras and completion lifecycle.
-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Fork of stock lua/ge/extensions/career/modules/vehiclePerformance.lua (BeamNG 0.40).
local M = {}

M.dependencies = { "ui_vehicleSelector_vehicleSpecifications", "overhaul_integration_services_dragScores" }

local testInProgress
local cancelTestRequested
local activeVenueId
local testLocation
local levelData = require("overhaul/lib/world/levelData")
local catalog = require("overhaul/lib/platform/jsonCatalog")
local activeInventoryId
local zoomingCamera = false
local targetFOV = 19 -- default FOV
local zoomSpeed = 5 -- default zoom speed
local vehicleBreakCancelDelay = 3
local activatedBrakingCamera = false
local vehId
local blockedActions = core_input_actionFilter.createActionTemplate({"radialMenuActivate", "bigMap", "walkingMode", "resetPhysics", "nodegrabber", "vehicleTriggers", "setShifterMode"}, actionWhitelist)

local function refuelCar(veh)
  core_vehicleBridge.requestValue(veh,
    function(ret)
      for _, tank in ipairs(ret[1]) do
        core_vehicleBridge.executeAction(veh, 'setEnergyStorageEnergy', tank.name, tank.maxEnergy)
      end
    end,
    'energyStorage'
  )
end

local function enableOtherVehicles(inventoryId, enabled)
  gameplay_traffic.scatterTraffic()
  local vehicles = overhaul_career_garage_inventory.getVehicles()
  for id, vehicle in pairs(vehicles) do
    if id ~= inventoryId then
      local otherVehId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(id)
      if otherVehId then
        local otherVeh = getObjectByID(otherVehId)
        otherVeh:setActive(enabled and 1 or 0)
      end
    end
  end
end

local function checkAndAddPerformanceDataToHistory(inventoryId)
  local vehicle = overhaul_career_garage_inventory.getVehicles()[inventoryId]
  local oldPerformanceData = vehicle.certificationData
  if oldPerformanceData then
    vehicle.performanceHistory = vehicle.performanceHistory or {}
    table.insert(vehicle.performanceHistory, 1, oldPerformanceData)
    if #vehicle.performanceHistory > 10 then
      table.remove(vehicle.performanceHistory)
    end
  end
end

local function invalidateCertification(inventoryId)
  local vehicle = overhaul_career_garage_inventory.getVehicles()[inventoryId]
  checkAndAddPerformanceDataToHistory(inventoryId)
  vehicle.certificationData = nil
end

local maxVelocity
local function updateCameraZoom(dtReal)
  if not zoomingCamera then return end

  local vehVelocity = getObjectByID(vehId):getVelocity():length()
  local fov = linearScale(vehVelocity, 2, maxVelocity, 20, 65)
  core_camera.setFOV(vehId, fov)

  if fov == targetFOV then
    zoomingCamera = false -- stop camera zooming
  end
end

local function onUpdate(dtReal)
  updateCameraZoom(dtReal)
end

local function setRelativeCamera(offsetVec3, rotationVec3)
  core_camera.setByName(0, 'relative', false)
  core_camera.setOffset(vehId, offsetVec3)
  core_camera.setRotation(vehId, rotationVec3)
end

local function switchToEndCamera()
  zoomingCamera = false
  log('I', 'vehiclePerformance', 'Out of bounds! Switching to external camera')
  core_camera.setByName(0, 'external', false)
end

local function switchToLaunchCamera()
  local bbHalfAxis0 = vec3(be:getObjectOOBBHalfAxisXYZ(vehId, 0))
  local backOffsetDist = bbHalfAxis0:length() * -3.5
  local offsetX = -2.0 -- move camera left (negative)
  local offsetY = backOffsetDist -- behind vehicle
  local offsetZ = 0.6 -- lower camera height, adjust as needed
  setRelativeCamera(vec3(offsetX, offsetY, offsetZ), vec3(15, 180, 10))
  core_camera.setFOV(vehId, 80)
end

local function switchToBrakingCamera()
  local bbHalfAxis1 = vec3(be:getObjectOOBBHalfAxisXYZ(vehId, 1))
  local offsetDist = bbHalfAxis1:length() * 3
  setRelativeCamera(vec3(-offsetDist, offsetDist, 1), vec3(135, 180, 0))
  targetFOV = 18
  zoomSpeed = 5
  zoomingCamera = true
  maxVelocity = getObjectByID(vehId):getVelocity():length()
  core_camera.setFOV(vehId, 65)
end

local function navigateToOverview()
  extensions.ui_router.navigate("overhaul.computer.vehiclePerformance")
end

-- Resolve and validate the course before changing vehicles, input or the test lifecycle.
local function certificationLocation(venueId, computerId)
  local level = getCurrentLevelIdentifier()
  local config = level and jsonReadFile("/levels/" .. level .. "/overhaul/vehiclePerformance.json")
  if type(config) ~= "table" or config.version ~= 1 or type(config.venues) ~= "table" then
    return nil, "Performance certification is not configured on this level."
  end
  local venue
  for _, candidate in ipairs(config.venues) do
    if type(candidate) ~= "table" or type(candidate.id) ~= "string" then return nil, "Invalid certification venue." end
    if candidate.id == (venueId or config.defaultVenue) then venue = candidate end
    if not venueId and computerId then
      for _, id in ipairs(candidate.computerIds or {}) do
        if id == computerId then venue = candidate; venueId = candidate.id end
      end
    end
  end
  if not venue or type(venue.drag) ~= "table" or type(venue.skidpad) ~= "table" then return nil, "No certification venue selected." end
  local drag, skidpad = venue.drag, venue.skidpad
  local settingsFile = levelData.assetPath(level, drag.settingsFile)
  local dragData = settingsFile and overhaul_integration_services_dragScores.loadDragStripData(settingsFile, true)
  local lane = catalog.finite(drag.lane) and drag.lane >= 1 and drag.lane % 1 == 0
    and dragData and dragData.strip.lanes[drag.lane]
  if not lane or not lane.waypoints.spawn then
    return nil, "Certification drag course has no valid lane and spawn geometry."
  end
  local skidpadSpawn = levelData.resolveSpawn(skidpad.spawn, level)
  if not skidpadSpawn or type(skidpad.waypoints) ~= "table" or #skidpad.waypoints < 2
    or not catalog.finite(skidpad.laps) or skidpad.laps < 1 or skidpad.laps % 1 ~= 0 then
    return nil, "Certification skidpad is unavailable."
  end
  for _, name in ipairs(skidpad.waypoints) do
    local nodes = map.getMap() and map.getMap().nodes
    local object = type(name) == "string" and scenetree.findObject(name)
    local waypoint = object and object:getClassName() == "BeamNGWaypoint"
    if type(name) ~= "string" or not (waypoint or nodes and nodes[name]) then
      return nil, "Certification skidpad waypoint is unavailable: " .. tostring(name)
    end
  end
  return {id = venue.id, level = level, settingsFile = settingsFile, lane = drag.lane,
    skidpad = skidpad, skidpadSpawn = skidpadSpawn, cameras = venue.cameras or {}}
end

local function playCertificationCamera(path)
  local file = path and levelData.assetPath(testLocation.level, path)
  if file and FS:fileExists(file) then
    core_paths.playPath(core_paths.loadPath(file), 0)
  else
    core_camera.setByName(0, "external", false)
  end
end

local function startDragTest(venueId)
  if testInProgress then return false end
  local location, reason = certificationLocation(venueId or activeVenueId)
  if not location then
    log("W", "vehiclePerformance", reason)
    ui_message(reason, 8, "warning")
    return false, reason
  end
  testLocation = location
  local inventoryId = activeInventoryId
  extensions.load('util_stepHandler')
  testInProgress = true
  vehId = nil
  local sequence = {}
  local spawnStarted
  local spawnComplete
  local staticVehicleDataRetrieved
  local recordingDataRetrieved
  local recordingDataRequested
  local closestGarage = overhaul_career_garage_inventory.getClosestGarage().id
  local playerInitialPos = getPlayerVehicle(0):getPosition()
  local vehicleInitialPos = nil
  local certificationData = {}
  local courseLoadFailed = false
  activatedBrakingCamera = false

  core_input_actionFilter.setGroup('certificationBlockedActions', blockedActions)
  core_input_actionFilter.addAction(0, 'certificationBlockedActions', true)

  -- fade to black at start
  table.insert(sequence, util_stepHandler.makeStepFadeToBlack())
  table.insert(sequence, util_stepHandler.makeStepWait(0.2))

  table.insert(sequence, util_stepHandler.makeStepReturnTrueFunction(
    function()
      if not spawnStarted then
        enableOtherVehicles(inventoryId, false)
        if overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId) then
          vehId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId)
          vehicleInitialPos = getObjectByID(vehId):getPosition()
          return true
        end
        local vehObj = overhaul_career_garage_inventory.spawnVehicle(inventoryId, nil, function()
          spawnComplete = true
        end)
        vehId = vehObj:getID()
        spawnStarted = true
      end
      return spawnComplete
    end
  ))

  table.insert(sequence, util_stepHandler.makeStepReturnTrueFunction(
    function()
      overhaul_career_garage_inventory.enterVehicle(inventoryId)
      refuelCar(getObjectByID(vehId))
      return true
    end
  ))

  table.insert(sequence, util_stepHandler.makeStepReturnTrueFunction(
    function()
      core_vehicleBridge.requestValue(getObjectByID(vehId), function(ret)
        certificationData = ret
        staticVehicleDataRetrieved = true
      end, "getStaticData")
      return staticVehicleDataRetrieved
    end
  ))

  -- =====================================
  -- Drag Test
  -- =====================================
  table.insert(sequence, util_stepHandler.makeStepReturnTrueFunction(
    function()
      local loaded = gameplay_drag_dragBridge.loadDragDataForMission(testLocation.settingsFile)
      local racers = { {id = vehId, isPlayable = false, canBeReseted = false, lane = testLocation.lane}}
      local dragData = loaded and gameplay_drag_dragBridge.getData()
      local lane = dragData and dragData.strip and dragData.strip.lanes[testLocation.lane]
      if not lane or not lane.waypoints.spawn then
        courseLoadFailed = true
        log("W", "vehiclePerformance", "Certification drag course failed to load; restoring the vehicle.")
        ui_message("The certification course could not be loaded. Your vehicle is being restored.", 8, "warning")
        testInProgress, cancelTestRequested, zoomingCamera = nil, nil, false
        gameplay_drag_dragBridge.unloadRace()
        core_input_actionFilter.addAction(0, 'certificationBlockedActions', false)
        util_stepHandler.skipToLastStepOrCallback()
        return true
      end

      -- Override settings for performance test
      dragData.canBeReseted = false
      dragData.dragType = "headsUpRace"

      -- Disable the drag core's auto-clear-when-player-leaves-strip check; we manage the lifecycle here.
      if dragData.strip then
        dragData.strip.stripZone = nil
      end

      -- Load the extension for headsUpRace
      extensions.load('gameplay_drag_dragTypes_headsUpRace')
      gameplay_drag_core.setExtension(gameplay_drag_dragTypes_headsUpRace)

      if dragData.racers[vehId] then
        dragData.racers[vehId].canBeReseted = false
      end

      spawn.safeTeleport(getObjectByID(vehId), dragData.strip.lanes[testLocation.lane].waypoints.spawn.transform.pos, dragData.strip.lanes[testLocation.lane].waypoints.spawn.transform.rot, nil, nil, nil, true, false)

      getObjectByID(vehId):queueLuaCommand('damageTracker.registerDamageUpdateCallback(function(damageData, damageDataDelta) obj:queueGameEngineLua(require("vehicle/overhaul/geCallback").reply(' .. require('overhaul/lib/vehicles/callbacks').open('dragTestDamage', {owner = 'vehiclePerformance', vehId = vehId, repeats = true}) .. ', "dragTestDamage", serialize(damageData) .. ", " .. serialize(damageDataDelta))) end)')

      gameplay_drag_dragBridge.setVehicles(racers)
      -- put vehicle (or both vehicles) on the drag strip
      gameplay_drag_dragBridge.reset()
      -- start activity
      gameplay_drag_dragBridge.startDragRaceActivity()
      playCertificationCamera(testLocation.cameras.start)
      extensions.ui_router.navigate("overhaul.computer.vehiclePerformance.certificationTest")
      return true
    end))

  table.insert(sequence, util_stepHandler.makeStepFadeFromBlack())

  table.insert(sequence, util_stepHandler.makeStepReturnTrueFunction(
    function()
      core_vehicleBridge.executeAction(getObjectByID(vehId), 'startRecording', "power")
      return true
    end
  ))

  local initialCheckPos
  local lastCheckTime
  local STUCK_THRESHOLD = 0.1 -- meters of movement required to not be considered stuck
  local CHECK_INTERVAL = 7 -- seconds between position checks
  local SIXTY_MPH_MS = 26.8224 -- 60 mph in m/s
  local time_0_60 = nil
  table.insert(sequence, util_stepHandler.makeStepReturnTrueFunction(
    function(step, dtTable)
      if cancelTestRequested then
        gameplay_drag_dragBridge.unloadRace()
        return true
      end

      -- Initialize first position check
      if not initialCheckPos then
        local vehicle = getObjectByID(vehId)
        initialCheckPos = vehicle:getPosition()
        lastCheckTime = 0
      end

      -- Check position difference after interval
      if lastCheckTime >= CHECK_INTERVAL then
        local vehicle = getObjectByID(vehId)
        local movement = (vehicle:getPosition() - initialCheckPos):length()
        if movement < STUCK_THRESHOLD then
          log('I', 'vehiclePerformance', 'Vehicle stuck - cancelling test')
          M.cancelTest(nil, false)
        end
        -- Reset for next check interval
        initialCheckPos = vehicle:getPosition()
        lastCheckTime = 0
      else
        lastCheckTime = lastCheckTime + dtTable.dtSim
      end
      local data = gameplay_drag_core.getData()
      local racer = data and data.racers and data.racers[vehId]
      local phases = racer and racer.phases
      local lastPhase = phases and phases[#phases]
      if lastPhase and lastPhase.started and not activatedBrakingCamera then
        activatedBrakingCamera = true
        switchToBrakingCamera()
      end

      -- Capture 0-60 mph: race-elapsed time at 60 mph crossing, minus reaction time.
      if not time_0_60 and racer and racer.timersStarted and (racer.vehSpeed or 0) >= SIXTY_MPH_MS then
        local timers = racer.timers or {}
        local elapsed = timers.timer and timers.timer.value or 0
        local reactionTime = timers.reactionTime and timers.reactionTime.isSet and timers.reactionTime.value or 0
        time_0_60 = math.max(0, elapsed - reactionTime)
      end

      --wait for drag to be finished
      return data and data.isCompleted
    end)
  )

  table.insert(sequence, util_stepHandler.makeStepReturnTrueFunction(
    function()
      if cancelTestRequested then
        return true
      end
      if not recordingDataRequested then
        recordingDataRequested = true
        core_vehicleBridge.executeAction(getObjectByID(vehId),'stopRecording', "power")
        core_vehicleBridge.requestValue(getObjectByID(vehId), function(ret)
          recordingDataRetrieved = true
          tableMerge(certificationData, ret)
        end, "getRecordingData", "power")
      end

      return recordingDataRetrieved
    end
  ))

  local cancelTestTimer = 0
  table.insert(sequence, util_stepHandler.makeStepReturnTrueFunction(
    function(step, dtTable)
      recordingDataRetrieved = nil
      recordingDataRequested = nil
      if not cancelTestRequested then
        return true
      end
      cancelTestTimer = cancelTestTimer + dtTable.dtReal
      if cancelTestTimer >= cancelTestRequested then
        util_stepHandler.skipToLastStepOrCallback()
        return true
      end
    end
  ))

  local timerKeys = {"time_60", "time_330", "time_1_8", "time_1000", "time_1_4", "velAt_1_4", "velAt_1_8", "time_0_60", "brakingG" }
  table.insert(sequence, util_stepHandler.makeStepReturnTrueFunction(
    function()
      local performanceData = {}
      local data = gameplay_drag_core.getData()
      local racer = data and data.racers and data.racers[vehId]
      local timers = racer and racer.timers or {}
      for _, key in ipairs(timerKeys) do
        local timer = timers[key]
        if timer then
          performanceData[key] = timer.value
        end
      end
      if time_0_60 then
        performanceData.time_0_60 = time_0_60
      end

      -- Add current date in milliseconds
      performanceData.timeStamp = os.time() * 1000
      performanceData.mileage = overhaul_career_market_valueCalculator.getVehicleMileageById(inventoryId)
      tableMerge(certificationData, performanceData)
      return true
    end)
  )

  -- Fully unload the drag system (clears data, unloads extensions, hides UI) before moving on.
  table.insert(sequence, util_stepHandler.makeStepReturnTrueFunction(
    function()
      gameplay_drag_dragBridge.unloadRace()
      return true
    end
  ))

  -- =====================================
  -- Skidpad Test
  -- =====================================

  table.insert(sequence, util_stepHandler.makeStepFadeToBlack())
  table.insert(sequence, util_stepHandler.makeStepReturnTrueFunction(
    function()
      local vehicle = getObjectByID(vehId)
      local spawnPoint = testLocation.skidpadSpawn
      spawn.safeTeleport(vehicle, spawnPoint.pos, spawnPoint.rot, nil, nil, nil, true, false)
      return true
    end
  ))

  table.insert(sequence, util_stepHandler.makeStepWait(0.2))

  table.insert(sequence, util_stepHandler.makeStepReturnTrueFunction(
    function()
      local vehicle = getObjectByID(vehId)

      local config = {
        wpTargetList = testLocation.skidpad.waypoints,
        noOfLaps = testLocation.skidpad.laps,
        aggression = 1
      }

      -- Make the AI drive the route
      vehicle:queueLuaCommand('ai.driveUsingPath(' .. serialize(config) .. ')')
      core_camera.setByName(0, 'orbit')
      core_camera.resetCamera(0)
      core_vehicleBridge.executeAction(vehicle, 'startRecording', "lateralAcceleration")
      return true
    end
  ))

  table.insert(sequence, util_stepHandler.makeStepFadeFromBlack())

  -- Wait for skidpad test to finish
  local timer = 0
  table.insert(sequence, util_stepHandler.makeStepReturnTrueFunction(
    function(step, dtTable)
      if cancelTestRequested then
        core_vehicleBridge.executeAction(getObjectByID(vehId),'stopRecording', "lateralAcceleration")
        util_stepHandler.skipToLastStepOrCallback()
        return true
      end

      timer = timer + dtTable.dtSim
      if timer >= 10 then
        if not recordingDataRequested then
          recordingDataRequested = true
          core_vehicleBridge.executeAction(getObjectByID(vehId),'stopRecording', "lateralAcceleration")
          core_vehicleBridge.requestValue(getObjectByID(vehId), function(ret)
            recordingDataRetrieved = true
            tableMerge(certificationData, ret)
          end, "getRecordingData", "lateralAcceleration")
        end
        return recordingDataRetrieved
      end
      return false
    end
  ))

  table.insert(sequence, util_stepHandler.makeStepReturnTrueFunction(
    function()
      testInProgress = nil
      if courseLoadFailed then return true end

      checkAndAddPerformanceDataToHistory(inventoryId)
      gameplay_achievement.unlockAchievement("PERFORMANCE_INDEXED")
      overhaul_career_garage_inventory.getVehicles()[inventoryId].certificationData = certificationData
      overhaul_career_garage_inventory.setVehicleDirty(inventoryId)
      return true
    end
  ))

  -- =====================================
  -- Reset everything back to how it was before the test
  -- =====================================

  local resetSequence = {}
  table.insert(resetSequence, util_stepHandler.makeStepFadeToBlack())

  -- remove vehicle
  table.insert(resetSequence, util_stepHandler.makeStepReturnTrueFunction(
    function()
      testInProgress = nil
      overhaul_career_garage_inventory.removeVehicleObject(inventoryId, true)
      zoomingCamera = false
      return true
    end)
  )
  table.insert(resetSequence, util_stepHandler.makeStepWait(0.1))

  -- enable other vehicles
  table.insert(resetSequence, util_stepHandler.makeStepReturnTrueFunction(
    function()
      spawnStarted = false
      spawnComplete = false
      enableOtherVehicles(inventoryId, true)
      return true
    end)
  )

  -- spawn vehicle again
  table.insert(resetSequence, util_stepHandler.makeStepReturnTrueFunction(
    function()
      if vehicleInitialPos then
        if not spawnStarted then
          local vehObj = overhaul_career_garage_inventory.spawnVehicle(inventoryId, nil, function()
            spawnComplete = true
          end)
          spawnStarted = true
          vehId = vehObj:getID()
        end
        return spawnComplete
      end
      return true
    end)
  )

  -- teleport vehicle to garage if vehicleInitialPos is set
  table.insert(resetSequence, util_stepHandler.makeStepReturnTrueFunction(
    function()
      if vehicleInitialPos then
        local vehObj = getObjectByID(vehId)
        if vehObj then
          overhaul_world_facilities.teleportToGarage(closestGarage, vehObj, false)
        end
      end
      return true
    end)
  )

  -- teleport player back to the initial position
  table.insert(resetSequence, util_stepHandler.makeStepReturnTrueFunction(
    function()
      spawn.safeTeleport(getPlayerVehicle(0), playerInitialPos)
      core_camera.setGlobalCameraByName(nil)
      return true
    end
  ))

  -- fade from black
  table.insert(resetSequence, util_stepHandler.makeStepFadeFromBlack())

  util_stepHandler.startStepSequence(sequence, function()
    cancelTestRequested = nil
    core_jobsystem.create(function(job)
      util_stepHandler.startStepSequence(resetSequence, function()
        core_input_actionFilter.setGroup('certificationBlockedActions', blockedActions)
        core_input_actionFilter.addAction(0, 'certificationBlockedActions', false)
        if not courseLoadFailed and overhaul_career_career.isAutosaveEnabled() then
          overhaul_career_saveSystem.saveCurrent()
        end
        navigateToOverview()
      end)
    end, "resetDelay")
  end)
end

local function getAggregateScoresFromVehId(inventoryId)
  local vehicle = overhaul_career_garage_inventory.getVehicles()[inventoryId]
  local certificationData = vehicle.certificationData
  if not certificationData then return end
  return extensions.gameplay_vehiclePerformance.getAggregateScores(certificationData)
end

local function getVehicleClass(inventoryId)
  local vehicle = overhaul_career_garage_inventory.getVehicles()[inventoryId]
  local certificationData = vehicle.certificationData
  if not certificationData then return end
  return extensions.gameplay_vehiclePerformance.getClassFromData(certificationData)
end

local function translatePerformanceDataForUi(performanceData)
  if not performanceData then return end
  local propValue = ui_vehicleSelector_vehicleSpecifications.propValue
  if performanceData.drivetrain then
    performanceData.drivetrain = propValue("Drivetrain", performanceData.drivetrain)
  end
  if performanceData.fuelType then
    performanceData.fuelType = propValue("Fuel Type", performanceData.fuelType)
  end
  if performanceData.inductionType then
    performanceData.inductionType = propValue("Induction Type", performanceData.inductionType)
  end
end

local function addScoresToPerformanceData(performanceData)
  performanceData.performanceAggregateScores = extensions.gameplay_vehiclePerformance.getAggregateScores(performanceData)
  performanceData.vehicleClass = extensions.gameplay_vehiclePerformance.getClassFromData(performanceData)
  gameplay_achievement.unlockAchievement("PERFOMANCE_INDEX")
  if performanceData.vehicleClass.class and performanceData.vehicleClass.class.name == "X" then
    gameplay_achievement.unlockAchievement("HIGH_END_PERFORMANCE")
  end
end

local function cancelTest(delay, userAborted)
  if userAborted ~= false and testInProgress then
    extensions.hook("onGameplayActivityAborted")
  end
  cancelTestRequested = delay or 0
  zoomingCamera = false
  extensions.gameplay_skidpadTest.cancelTest()
end

local function onBeamNGTrigger(data)
  if not testInProgress or not data or not data.triggerName or not data.event then return end
  if vehId ~= data.subjectID then return end
  -- Handle enter events
  if data.event == "enter" then
    local path = testLocation.cameras.onEnter and testLocation.cameras.onEnter[data.triggerName]
    if path then playCertificationCamera(path) end
  -- Handle exit events
  elseif data.event == "exit" then -- vehicle has gone out of bounds, switch to external camera
    if data.triggerName == testLocation.cameras.endTrigger then
      core_jobsystem.create(function(job)
        job.sleep(0.1)
        switchToEndCamera()
      end, "dragEndCamDelay")
    end
  end
end

local function onDragCountdownStarted(vehId, dial)
  if not testInProgress then return end
  core_jobsystem.create(function(job)
    job.sleep(1) -- let staging lights appear for one second before switching to launch camera
    switchToLaunchCamera()
  end, "dragCamDelay")
end

local function onOverhaulComputerAddFunctions(menuData, computerFunctions)
  local location = certificationLocation(nil, menuData.computerFacility and menuData.computerFacility.id)
  if not location then
    log("W", "vehiclePerformance", "No valid certification course on this level; menu entry omitted.")
    return
  end
  for _, vehicleData in ipairs(menuData.vehiclesInGarage) do
    local inventoryId = vehicleData.inventoryId
    local computerFunctionData = {
      id = "performanceIndex",
      routeTarget = "overhaul.computer.vehiclePerformance",
      label = _tr("ui.career.shared.pathPerformanceIndex"),
      callback = function()
        M.openMenu({inventoryId = inventoryId, venueId = location.id})
      end,
      order = 40
    }

    -- tutorial active
    if not menuData.hasBoughtStarterVehicle then
      computerFunctionData.disabled = true
      computerFunctionData.reason = overhaul_career_garage_computer.reasons.hasBoughtStarterVehicle
    end

    computerFunctions.vehicleSpecific[inventoryId][computerFunctionData.id] = computerFunctionData
  end
end

local function openMenu(options)
  activeInventoryId = options.inventoryId
  activeVenueId = options.venueId
  extensions.ui_router.navigate("overhaul.computer.vehiclePerformance")
end

local function getActiveVehicleUiData()
  if not activeInventoryId then return nil end
  return overhaul_career_garage_inventory.getVehicleDetailsUiData(activeInventoryId)
end

-- Router lifecycle: attach the active vehicle data into routeData so the UI
-- reads it from the routeData store instead of fetching it on mount.
local function onRouteMount(context, toRoute, fromRoute, data)
  data.vehicleData = getActiveVehicleUiData()
end

local function onVehicleDamaged(damageData, damageDataDelta)
  if not testInProgress then return end
  local engineData = damageDataDelta.engine
  if engineData and (engineData.catastrophicOverTorqueDamage or engineData.engineLockedUp) then
    cancelTest(vehicleBreakCancelDelay, false)
  end
end

M.getCertificationLocation = certificationLocation
M.startDragTest = startDragTest
M.invalidateCertification = invalidateCertification
M.isTestInProgress = function() return testInProgress end
M.cancelTest = cancelTest
M.getAggregateScoresFromVehId = getAggregateScoresFromVehId
M.getVehicleClass = getVehicleClass
M.addScoresToPerformanceData = addScoresToPerformanceData
M.translatePerformanceDataForUi = translatePerformanceDataForUi
M.openMenu = openMenu
M.getActiveVehicleUiData = getActiveVehicleUiData
M.onRouteMount = onRouteMount

M.onDragCountdownStarted = onDragCountdownStarted
M.onBeamNGTrigger = onBeamNGTrigger
M.onUpdate = onUpdate
M.onOverhaulComputerAddFunctions = onOverhaulComputerAddFunctions
M.onVehicleDamaged = onVehicleDamaged

return M
