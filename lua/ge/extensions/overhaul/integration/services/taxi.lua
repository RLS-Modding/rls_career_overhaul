-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Owns hired-cab state, public ride controls, destination previews and taxi billboards.
-- Fork of stock lua/ge/extensions/gameplay/taxi.lua (BeamNG 0.40).
local M = {}
local passengerSeats = require('overhaul/lib/vehicles/passengerSeats')

local function isOverhaulActive()
  return overhaul_shell_gameMode and overhaul_shell_gameMode.isActive() == true
end
local taxiJobs = {}

local function createTaxiJob(fn, ...)
  if not isOverhaulActive() then return end
  local handle
  handle = core_jobsystem.create(function(job)
    if isOverhaulActive() then fn(job) end
    if handle then taxiJobs[handle] = nil end
  end, ...)
  if handle then taxiJobs[handle] = true end
  return handle
end
M.dependencies = {"gameplay_util_vehicleSighting", "overhaul_vehicles_seatedDriver"}

-- The core owns driver lifetime through dispatch, the ride and departure.
local function setCabDriver(vehId, seated)
  local drivers = overhaul_vehicles_seatedDriver
  if not drivers then return end
  if seated then drivers.show(vehId) else drivers.clear(vehId) end
end

local sponsors = require("overhaul/lib/ledger/sponsors")
M.sponsorService = require("overhaul/integration/taxi/sponsorService")
local isTaxiFareSponsored = sponsors.isSponsored

local function getCallTaxiLabel()
  if isTaxiFareSponsored() then
    return ((_tr and _tr("ui.taxi.callTaxi")) or "Call a taxi") .. " (Company pays)"
  end
  return "ui.taxi.callTaxi"
end

-- taxi management
local taxis = {} -- vehId -> state key (string key into taxiStates)
local taxiRuntime = {}
taxiRuntime.hailingEnabled = true -- false during active missions
local availableTaxiRatio = 1 -- fraction of taxis that start available (rest are unavailable)

local playerSightParams = {
  maxDistDirectSight = 25,
  minDistPeriphSight = 5,
  periphSightAngle = 90,
  needDirectVisualContact = true,
}

local taxiSightParams = {
  maxDistDirectSight = 25,
  minDistPeriphSight = 20,
  periphSightAngle = 90,
  needDirectVisualContact = false,
}

-- a faster taxi needs to spot the player from further away to react in time
local taxiSightMaxDistanceMeters = 70
local taxiSightFullRangeSpeedMetersPerSecond = 100 / 3.6 -- m/s (100 km/h): speed at which direct sight reaches taxiSightMaxDist

local taxiSightParamsDynamic = {
  maxDistDirectSight = taxiSightParams.maxDistDirectSight,
  minDistPeriphSight = taxiSightParams.minDistPeriphSight,
  periphSightAngle = taxiSightParams.periphSightAngle,
  needDirectVisualContact = taxiSightParams.needDirectVisualContact,
}

local function getTaxiSightParams(vehId)
  local veh = getObjectByID(vehId)
  local speed = veh and veh:getVelocity():len() or 0
  local sightRangeProgress = clamp(speed / taxiSightFullRangeSpeedMetersPerSecond, 0, 1)
  taxiSightParamsDynamic.maxDistDirectSight = lerp(taxiSightParams.maxDistDirectSight, taxiSightMaxDistanceMeters, sightRangeProgress)
  return taxiSightParamsDynamic
end

-- Allow small changes in player distance without treating them as walking away.
local pickupDistanceSlackMeters = 6

-- Pulling over at the destination is phased
local arrivalApproachDistanceMeters = 70 -- begin shedding speed before committing to the stop
local arrivalApproachSpeedMetersPerSecond = 8
local approachCapResendStepMetersPerSecond = 0.5
local arrivalMinStopDistanceMeters = 10
local arrivalMaxCommitDistanceMeters = 20 -- ceiling on the commit estimate, which grows with speed squared
local arrivalAggression = 0.85
local arrivalStopToleranceMeters = 4 -- stop mode
local pickupSightArrivalDistanceMeters = 25 -- a sighted player only counts as arrival this close

local bigMapOpenDelaySeconds = 0.4

local minReactionTimeSeconds = 0.3
local maxReactionTimeSeconds = 0.6
local maxPullOverSpeedKph = 2 --km/h
local blinkersDurationSeconds = 6

local hailMessage = {
  ttl = 0.5,
  msg = "ui.taxi.hail",
  category = "taxiNearby",
  clear = false,
}

-- camera system
local taxiCameraMode = "orbit"

-- idle camera system
local idleCameraDelaySeconds = 15 -- seconds
local fadeToBlackDurationSeconds = 0.5
local rotationResetThresholdSeconds = 0.25 -- camera is considered actively moved if rotated within this many seconds

local skipTargetDistanceMeters = 150
local accelerationTimeSeconds = 1 -- seconds

local hurryUpLevels = {
  -- Restoring legal speed must retain the ride's car-avoidance setting.
  { apply = function(veh)
    local tv = gameplay_traffic.getTrafficData()[veh:getID()]
    local vars = tv and tv.getTrafficVars and tv.getTrafficVars()
    local aggression = vars and vars.baseAggression or 0.35
    veh:queueLuaCommand(string.format('ai.setAggression(%.3f)', aggression))
    veh:queueLuaCommand('ai.setSpeedMode("legal")')
  end },
  { apply = function(veh) veh:queueLuaCommand('ai.setAggression(0.6)') veh:queueLuaCommand('ai.setSpeedMode("off")') end },
  { apply = function(veh) veh:queueLuaCommand('ai.setAggression(0.9)') veh:queueLuaCommand('ai.setSpeedMode("off")') end },
  { apply = function(veh) veh:queueLuaCommand('ai.setAggression(1.0)') veh:queueLuaCommand('ai.setSpeedMode("off")') end },
}

-- player ride phases: tracks the player's current interaction with a taxi
local playerRidePhases = {
  none = "none",
  awaitingPickup = "awaitingPickup", -- one or more taxis are coming to / waiting at the pickup (called or hailed)
  choosingDestination = "choosingDestination",
  driving = "driving",
  arriving = "arriving",
}

local taxiRideFilterName = "overhaulTaxiRide"
local taxiRideBlockedActions = {
  -- driving
  "accelerate", "brake", "accelerate_brake", "steer_left", "steer_right", "steering",
  "clutch", "parkingbrake", "parkingbrake_temporary", "parkingbrake_toggle",
  -- shifting
  "shiftUp", "shiftDown", "toggleShifterMode",
  "gearR", "gear1", "gear2", "gear3", "gear4", "gear5", "gear6", "gear7", "gear8", "gearN",
  -- ignition
  "activateStarterMotor",
  "setIgnitionLevel0", "setIgnitionLevel1", "setIgnitionLevel2", "setIgnitionLevel3",
  "setIgnitionLevel1Momentary", "setIgnitionLevel2Momentary", "setIgnitionLevel3Momentary",
  -- electrics
  "toggle_headlights", "highbeam", "toggle_foglights",
  "toggle_left_signal", "toggle_right_signal", "toggle_hazard_signal", "toggle_lightbar_signal",
  "toggle_underglow", "horn",
  -- drivetrain
  "toggleESCMode", "nextESCMode", "previousESCMode",
  "toggleDiffMode", "toggle4WDStatus", "toggleRangeStatus",
  "toggleTransbrake", "toggleLineLock",
  "overrideNitrousOxide", "toggleNitrousOxide",
  "toggleTwoStep", "increaseTwoStepRPM", "decreaseTwoStepRPM",
  "toggleLightbarMode",
  -- cruise control
  "set_cc_speed", "reset_cc_speed", "increase_cc_speed", "decrease_cc_speed",
  "increase_cc_speed_large", "decrease_cc_speed_large", "disable_cc",
  -- couplers
  "couplersLock", "couplersToggle", "couplersUnlock",
  -- misc
  "reset_physics",
}

local slowSpeedThresholdMetersPerSecond = 3 -- below this we just stop instead of pulling over while moving (m/s)
local dropoffKickDelaySeconds = 10 -- seconds before the driver boots the player out after arriving

-- inService: the taxi is working a ride, so police and traffic rules leave it alone (see the fleet's
-- vehicle policy at the end of this file). An idle available taxi is ordinary traffic.
local taxiStates = {
  available             = { displayInfo = { label = "Available",       color = ColorF(0, 1, 0, 1) }, lightState = "available" },
  enRoute               = { displayInfo = { label = "En route",        color = ColorF(0, 0.6, 1, 1) }, lightState = "reserved", inService = true },
  pullingOverForPickup  = { displayInfo = { label = "Pulling Over",    color = ColorF(1, 0.65, 0, 1) }, blinkers = "pullOver", lightState = "reserved", inService = true },
  waitingForPickup      = { displayInfo = { label = "Waiting for you", color = ColorF(0, 0.6, 1, 1) }, blinkers = "hazard", lightState = "reserved", inService = true },
  occupied              = { lightState = "occupied", inService = true },
  pullingOverForDropoff = { blinkers = "pullOver", lightState = "occupied", inService = true },
  waitingForDropoff     = { blinkers = "hazard", lightState = "occupied", inService = true },
  unavailable           = { displayInfo = { label = "Unavailable",     color = ColorF(1, 0, 0, 1) }, lightState = "offDuty" },
}

local uiUpdateIntervalSeconds = 0.1

local player = {
  nearestTaxiId = nil,
  currentTaxiId = nil, -- the active ride taxi (only set once the player has climbed in)
  currentPhase = playerRidePhases.none,
  destinationPos = nil,
  cameraBeforeTaxi = nil,
  idleCameraActive = false,
  disableIdleCamera = false,
  idleCameraUserEnabled = true,
  idleCameraTimer = 0,
  idleCameraJobToken = 0, -- used to cancel a pending fade-in when the idle camera is turned off mid-fade
  skipPosition = nil,
  skipRotation = nil,
  totalRouteDistance = 0,
  hurryUpLevel = 1,
  -- if the big map is closed during choosingDestination without picking a destination,
  -- this decides what to do: "drive" resumes the existing route, nil does nothing
  chooseResumeMode = nil,
  taxiViewActive = false,
  uiUpdateTimer = 0,
  persistentMessage = nil,
  arrivalApproachActive = false,
  arrivalApproachSpeed0 = nil,
  arrivalApproachDist0 = nil,
  arrivalSpeedCap = nil,
  arrivalCommitted = false,
  disabledSwitchVehicles = nil, -- vehicles we temporarily made non-usable while riding, restored on exit
  dropoffKickTimer = 0,
  routePlanner = require('/lua/ge/extensions/gameplay/route/route')(),
  -- taxis coming to / waiting at the pickup, keyed by vehId. Each entry:
  --   { called = bool, targetPos = vec3|nil, waitTimer = 0, maxDist = math.huge }
  pickupTaxis = {},
  -- fare system (career only)
  fare = 0,
  fareCalculator = nil,
  fareData = nil,
  triggerMessingStrikes = 0,
}

local callTaxiSpawnMinDistanceMeters = 120
local callTaxiSpawnMaxDistanceMeters = 250
-- player must be within this distance of a road to call
local callTaxiMaxRoadDistanceMeters = 30
local pickupWaitTimeSeconds = 30 -- seconds a called taxi waits at the pickup before giving up
local pickupAbandonRadiusMeters = 12 -- after the wait, the taxi leaves if the player isn't within this many meters
local stuckTimeThresholdSeconds = 10
local stuckDistanceThresholdMeters = 3


local function defaultCalculateFare(data)
  local fare = data.fareConfig.fare
  local km = data.distanceTraveled / 1000
  local total = fare.initial + (fare.perKm * km)
  if data.isNight then
    total = total + fare.nightSurcharge
  end
  return total
end

local taxiConfigs = {
  {model = 'fullsize', config = 'taxi', fare = {initial = 1.5, perKm = 1.0, nightSurcharge = 0.5}},
  {model = 'bastion',  config = 'taxi', fare = {initial = 2.0, perKm = 1.5, nightSurcharge = 0.5}},
  {model = 'bluebuck', config = 'taxi', fare = {initial = 2.5, perKm = 1.8, nightSurcharge = 0.7},
    calculateFare = function(data)
      local miles = data.distanceTraveled / 1609.344
      local sixths = miles * 6
      local total = 0
      if sixths < 1 then
        total = 0.45 * sixths
      else
        total = 0.45 + (sixths - 1) * 0.10
      end
      total = total + data.stationaryTime / 120 * 0.10
      return total
    end,
  },
  {model = 'midsize',  config = 'taxi', fare = {initial = 1.5, perKm = 1.0, nightSurcharge = 0.5}},
  {model = 'legran',   config = 'taxi', fare = {initial = 1.8, perKm = 1.2, nightSurcharge = 0.5}},
}

local function getShouldSystemBeEnabled()
  if not isOverhaulActive() then return false end
  if gameplay_discover_freeroamTutorial_tutorial then return false end
  if overhaul_integration_services_missions_missionManager and overhaul_integration_services_missions_missionManager.getForegroundMissionId() then return false end
  if overhaul_career_career and overhaul_career_career.isActive() then return true end
  if not settings.getValue("enableTaxiInFreeroam") then return false end
  return true
end

local function onTrafficSpecialVehiclesProviders()
  if not isOverhaulActive() then return end
  if not getShouldSystemBeEnabled() then return end
  gameplay_traffic.registerSpecialVehicleProvider({
    name = 'taxi',
    priority = 5,
    guaranteed = 1,
    reserved = 1,
    buildGroup = function(count)
      -- Hailable and reserved cabs both need real doors and occupant parts before pickup.
      -- Keep the traffic provider's pooling/spawn path, but never its simplified models.
      local group = {}
      for i = 1, count do
        table.insert(group, taxiConfigs[math.random(#taxiConfigs)])
      end
      return group
    end,
  })
end

local taxiCore = require('overhaul/integration/services/taxi/core').create({
  isOverhaulActive = isOverhaulActive,
  createTaxiJob = createTaxiJob,
  isTaxiFareSponsored = isTaxiFareSponsored,
  setCabDriver = setCabDriver,
  taxis = taxis,
  taxiRuntime = taxiRuntime,
  availableTaxiRatio = availableTaxiRatio,
  playerSightParams = playerSightParams,
  getTaxiSightParams = getTaxiSightParams,
  pickupDistanceSlackMeters = pickupDistanceSlackMeters,
  arrivalApproachDistanceMeters = arrivalApproachDistanceMeters,
  arrivalApproachSpeedMetersPerSecond = arrivalApproachSpeedMetersPerSecond,
  approachCapResendStepMetersPerSecond = approachCapResendStepMetersPerSecond,
  arrivalMinStopDistanceMeters = arrivalMinStopDistanceMeters,
  arrivalMaxCommitDistanceMeters = arrivalMaxCommitDistanceMeters,
  arrivalAggression = arrivalAggression,
  arrivalStopToleranceMeters = arrivalStopToleranceMeters,
  pickupSightArrivalDistanceMeters = pickupSightArrivalDistanceMeters,
  minReactionTimeSeconds = minReactionTimeSeconds,
  maxReactionTimeSeconds = maxReactionTimeSeconds,
  maxPullOverSpeedKph = maxPullOverSpeedKph,
  blinkersDurationSeconds = blinkersDurationSeconds,
  hailMessage = hailMessage,
  taxiCameraMode = taxiCameraMode,
  passengerSeats = passengerSeats,
  idleCameraDelaySeconds = idleCameraDelaySeconds,
  fadeToBlackDurationSeconds = fadeToBlackDurationSeconds,
  rotationResetThresholdSeconds = rotationResetThresholdSeconds,
  skipTargetDistanceMeters = skipTargetDistanceMeters,
  hurryUpLevels = hurryUpLevels,
  playerRidePhases = playerRidePhases,
  taxiRideFilterName = taxiRideFilterName,
  taxiRideBlockedActions = taxiRideBlockedActions,
  dropoffKickDelaySeconds = dropoffKickDelaySeconds,
  taxiStates = taxiStates,
  uiUpdateIntervalSeconds = uiUpdateIntervalSeconds,
  player = player,
  callTaxiSpawnMinDistanceMeters = callTaxiSpawnMinDistanceMeters,
  callTaxiSpawnMaxDistanceMeters = callTaxiSpawnMaxDistanceMeters,
  callTaxiMaxRoadDistanceMeters = callTaxiMaxRoadDistanceMeters,
  pickupWaitTimeSeconds = pickupWaitTimeSeconds,
  pickupAbandonRadiusMeters = pickupAbandonRadiusMeters,
  stuckTimeThresholdSeconds = stuckTimeThresholdSeconds,
  stuckDistanceThresholdMeters = stuckDistanceThresholdMeters,
  getShouldSystemBeEnabled = getShouldSystemBeEnabled,
})

-- A delayed picker belongs to one request in one ride, even when a cab is re-entered.
local destinationRequest = 0
local function openDestinationAfterDelay(choosePhase)
  destinationRequest = destinationRequest + 1
  local request, taxiId = destinationRequest, player.currentTaxiId
  createTaxiJob(function(job)
    job.sleep(bigMapOpenDelaySeconds)
    if not isOverhaulActive() or request ~= destinationRequest or not taxiId
        or player.currentTaxiId ~= taxiId then return end
    if choosePhase then taxiCore.setPlayerPhase(playerRidePhases.choosingDestination) end
    if player.currentPhase == playerRidePhases.choosingDestination then
      freeroam_bigMapMode.enterBigMap({mode = "taxi"})
    end
  end, 1)
end

local function onVehicleSwitched(oldId, newId)
  if oldId == newId then return end
  if not isOverhaulActive() then return end
  -- player entered one of the pickup taxis: it becomes the active ride; dismiss all the others
  if player.pickupTaxis[newId] then
    player.pickupTaxis[newId] = nil
    taxiCore.dismissAllPickupTaxis(newId)
    player.currentTaxiId = newId
    if core_camera then player.cameraBeforeTaxi = core_camera.getActiveCamName() end
    player.rideCamera = passengerSeats.board(newId) or taxiCameraMode
    gameplay_traffic.protectNonReservedVehicle(newId, 'taxi')
    local trafficVeh = gameplay_traffic.getTrafficData()[newId]
    if trafficVeh then trafficVeh.ignoreForceTeleport = true end

    player.hurryUpLevel = 1
    player.hasSkipped = false
    player.triggerMessingStrikes = 0

    -- resolve fare calculator for this taxi (career only)
    if overhaul_career_career and overhaul_career_career.isActive() then
      local veh = getObjectByID(newId)
      local model = veh and veh:getJBeamFilename()
      local matchedConfig = nil
      if model then
        for _, cfg in ipairs(taxiConfigs) do
          if cfg.model == model then matchedConfig = cfg break end
        end
      end
      matchedConfig = matchedConfig or taxiConfigs[1]
      player.fareCalculator = matchedConfig.calculateFare or defaultCalculateFare
      player.fareData = {
        distanceTraveled = 0,
        stationaryTime = 0,
        elapsedTime = 0,
        isNight = core_environment and core_environment.getLightState().isNight or false,
        fareConfig = matchedConfig,
      }
      player.fare = 0
    end

    taxiCore.blockVehicleSwitching()
    if core_camera then
      core_camera.setByName(0, player.rideCamera)
    end

    -- close all doors/latches after the player climbs in
    local boardedId = newId
    taxiCore.closeDoorsOf(boardedId)

    -- initial destination choice: nothing to resume if the map is closed without picking
    player.chooseResumeMode = nil
    openDestinationAfterDelay(true)
  end

  -- player exited the taxi
  if oldId == player.currentTaxiId then
    destinationRequest = destinationRequest + 1
    local avatar = getObjectByID(newId)
    if avatar and avatar:getJBeamFilename() == 'unicycle' then
      local exitPos = passengerSeats.exitPosition(oldId)
      if exitPos then spawn.safeTeleport(avatar, exitPos, avatar:getRotation(), nil, nil, false) end
      if core_camera then core_camera.setByName(0, 'unicycle') end
    elseif core_camera and player.cameraBeforeTaxi then
      core_camera.setByName(0, player.cameraBeforeTaxi)
    end
    player.cameraBeforeTaxi = nil
    player.rideCamera = nil
    taxiCore.leaveTaxi()
  end
end

-- Seat switches and legacy driver-seat repairs must never grant cab controls.
local function onPlayerVehiclePresenceChanged(playerIndex, _, presence)
  if playerIndex ~= 0 then return end
  if not isOverhaulActive() or not presence or not player.currentTaxiId
      or presence.vehicleId ~= player.currentTaxiId then return end
  presence.permissionMode = 'passenger'
  presence.permissionOverride = 'passenger'
  -- Publish after coercion too, regardless of the walk owner's hook order.
  guihooks.trigger('OverhaulPassengerMode', true)
end

local function onChangeDestinationCalled()
  taxiCore.resetIdleCameraTimer()
  if player.currentPhase == playerRidePhases.driving then
    taxiCore.setIdleCamera(false)
    taxiCore.setPlayerPhase(playerRidePhases.choosingDestination)
    -- if no new destination, keep driving
    player.chooseResumeMode = "drive"
  elseif player.currentPhase == playerRidePhases.arriving then -- waiting for drop off
    taxiCore.setIdleCamera(false)
    local veh = getObjectByID(player.currentTaxiId)
    if veh then veh:queueLuaCommand('ai.setPullOver(false)') end
    taxiCore.setPlayerPhase(playerRidePhases.choosingDestination)
    -- if the map is closed without picking, go back to waiting for dropoff (don't strand the player)
    player.chooseResumeMode = "arrive"
  elseif player.currentPhase ~= playerRidePhases.choosingDestination then
    return
  end
  -- defer opening so the radial menu fully closes first
  openDestinationAfterDelay(false)
end

local function setHurryUpLevel(delta)
  taxiCore.resetIdleCameraTimer()
  if player.currentPhase ~= playerRidePhases.driving then return end
  local newLevel = player.hurryUpLevel + delta
  if newLevel < 1 or newLevel > #hurryUpLevels then return end
  local veh = getObjectByID(player.currentTaxiId)
  if not veh then return end
  player.hurryUpLevel = newLevel
  hurryUpLevels[newLevel].apply(veh)
  taxiCore.pushTaxiUIUpdate()
end

local function onHurryUpCalled() setHurryUpLevel(1) end
local function onSlowDownCalled() setHurryUpLevel(-1) end

local function onSkipCalled()
  taxiCore.resetIdleCameraTimer()
  if player.currentPhase ~= playerRidePhases.driving or player.hasSkipped then return end

  player.hasSkipped = true

  -- snapshot the targets so a route change can't turn them nil while the job runs
  local targetPos = player.skipPosition
  local targetRot = player.skipRotation

  createTaxiJob(function(job)
    -- guarantee physics returns to normal even if the job dies between the 2x and 0 calls
    job.setExitCallback(function() be:setPhysicsSpeedFactor(0) end)

    ui_fadeScreen.start(fadeToBlackDurationSeconds)
    job.sleep(fadeToBlackDurationSeconds + 0.1)

    taxiCore.setIdleCamera(false)
    job.sleep(0.1)

    player.disableIdleCamera = true
    -- destinationPos persists from the original pick, so the private planner rebuilds
    -- the route from the teleport spot without needing the shared ground-marker planner
    taxiCore.startTaxiWithCurrentRoute(true)

    local veh = getObjectByID(player.currentTaxiId)
    if veh then
      spawn.safeTeleport(veh, targetPos, targetRot, true, nil, false)
      be:setPhysicsSpeedFactor(2) --so that the taxi gets up to speed faster
      job.sleep(accelerationTimeSeconds)
      be:setPhysicsSpeedFactor(0)
    end

    player.disableIdleCamera = false
    ui_fadeScreen.stop(fadeToBlackDurationSeconds)
  end, 1)
end

local function setIdleCameraEnabled(enabled)
  player.idleCameraUserEnabled = enabled
  if not enabled then
    if player.idleCameraActive then
      taxiCore.setIdleCamera(false)
    end
    ui_fadeScreen.stop(fadeToBlackDurationSeconds)
  end
  taxiCore.resetIdleCameraTimer()
  taxiCore.pushTaxiUIUpdate()
end

local function onStopTaxiCalled()
  taxiCore.resetIdleCameraTimer()
  if not player.currentTaxiId then return end
  -- Let the passenger end a destination pull-over that cannot find a stopping place.
  if player.currentPhase == playerRidePhases.arriving and taxis[player.currentTaxiId] == "pullingOverForDropoff" then
    taxiCore.setTaxiState(player.currentTaxiId, "waitingForDropoff")
    taxiCore.pushTaxiUIUpdate(_tr("ui.taxi.canClimbOut"))
    return
  end
  if player.currentPhase ~= playerRidePhases.driving then return end
  local veh = getObjectByID(player.currentTaxiId)
  if not veh then return end

  local speed = veh:getVelocity():len()
  if speed > slowSpeedThresholdMetersPerSecond then
    taxiCore.makeTaxiPullOverWhileDriving(_tr("ui.taxi.stoppingHere"))
  else
    taxiCore.setPlayerPhase(playerRidePhases.arriving, _tr("ui.taxi.canClimbOut"))
  end
end

local function onAiRouteDone(vehId)
  if not isOverhaulActive() then return end
  if vehId ~= player.currentTaxiId then return end
  if player.currentPhase ~= playerRidePhases.driving then return end
  if not getObjectByID(player.currentTaxiId) then return end
  taxiCore.setPlayerPhase(playerRidePhases.arriving)
end

-- gameplay_interact also confirms an open marker prompt; that press belongs to the prompt.
local function isMarkerPromptOpen()
  local markers = overhaul_integration_services_markerInteraction
  if markers and markers.isActivityPromptOpen then
    return markers.isActivityPromptOpen() == true
  end
  return ui_missionInfo ~= nil and ui_missionInfo.openState == "opened"
end

local function onGameplayInteract()
  if not isOverhaulActive() then return end
  if isMarkerPromptOpen() then return end
  if player.currentPhase == playerRidePhases.driving then
    onStopTaxiCalled()
  elseif taxiCore.isTaxiAvailable() then
    taxiCore.callAndStopTaxi()
  end
end

local function onVehicleTriggersExecuteLink(lnk, actionValue, vehicleId)
  if not isOverhaulActive() then return end
  if actionValue ~= 1 then return end -- only react to press, not release
  if vehicleId ~= player.currentTaxiId then return end
  if player.currentPhase ~= playerRidePhases.driving then return end

  player.triggerMessingStrikes = player.triggerMessingStrikes + 1

  if player.triggerMessingStrikes == 1 then
    taxiCore.showMessage(_tr("ui.taxi.stopMessing"), false, 3)
  elseif player.triggerMessingStrikes == 2 then
    taxiCore.showMessage(_tr("ui.taxi.kickWarning"), false, 4)
  elseif player.triggerMessingStrikes >= 3 then
    player.triggerMessingStrikes = 0
    onStopTaxiCalled()
    createTaxiJob(function(job)
      -- wait for the taxi to stop, then boot the player
      local taxiId = player.currentTaxiId
      while taxiId and taxis[taxiId] ~= "waitingForDropoff" do
        if player.currentTaxiId ~= taxiId then return end
        job.sleep(0.25)
      end
      job.sleep(0.5)
      if player.currentTaxiId == taxiId then
        taxiCore.kickPlayerOut()
      end
    end, 1)
  end
end

local previewPlanner = require('/lua/ge/extensions/gameplay/route/route')()

local function getPreviewRouteLength(vehPos, destPos)
  previewPlanner:setupPathMulti({vehPos, destPos})
  local routeDistanceMeters = taxiCore.routeDistanceLeft(previewPlanner, vehPos)
  if not routeDistanceMeters or routeDistanceMeters <= 0 then return nil end
  local displayDistance, unit = translateDistance(routeDistanceMeters, "auto")
  return string.format("%.1f %s", displayDistance, unit)
end

local function onSetBigmapNavFocus(pos)
  if not isOverhaulActive() then return end
  if player.currentPhase ~= playerRidePhases.choosingDestination then return end
  if not pos then
    player.destinationPos = nil
    guihooks.trigger("TaxiDestinationPreviewed", { set = false })
    return
  end
  player.destinationPos = vec3(pos)
  local veh = player.currentTaxiId and getObjectByID(player.currentTaxiId)
  local routeLength = veh and getPreviewRouteLength(veh:getPosition(), player.destinationPos) or nil
  guihooks.trigger("TaxiDestinationPreviewed", { set = true, routeLength = routeLength })
end

local function confirmTaxiDestination()
  if player.currentPhase ~= playerRidePhases.choosingDestination or not player.destinationPos then return end
  player.chooseResumeMode = nil
  taxiCore.startTaxiWithCurrentRoute()
end

local function onDeactivateBigMapCallback()
  if not isOverhaulActive() then return end
  -- only react if the map closed while still choosing a destination (no pick happened)
  if player.currentPhase ~= playerRidePhases.choosingDestination then return end
  freeroam_bigMapMode.setNavFocus(nil)
  if player.chooseResumeMode == "drive" then
    -- player cancelled a "change destination"; the old route is still active, resume it
    taxiCore.setPlayerPhase(playerRidePhases.driving)
  elseif player.chooseResumeMode == "arrive" then
    -- player cancelled picking a new destination at the dropoff; go back to waiting for dropoff
    taxiCore.setPlayerPhase(playerRidePhases.arriving, _tr("ui.taxi.canClimbOut"))
  else
    -- initial pick cancelled; show the taxi view so the player can re-open the map
    player.taxiViewActive = true
    extensions.ui_menuManager.setGameplayRoute("taxi")
    extensions.ui_router.navigate("taxi")
    taxiCore.pushTaxiUIUpdate()
  end
  player.chooseResumeMode = nil
end

local function onVehicleResetted(id)
  if not isOverhaulActive() then return end
  -- never re-roll the active ride taxi or a taxi that's coming to / waiting for the player
  if taxis[id] and id ~= player.currentTaxiId and not player.pickupTaxis[id] then
    taxis[id] = nil -- clear so setTaxiState re-sends the lightState after vlua rebuild
    taxiCore.setTaxiState(id, taxiCore.rollAvailability(id))
  end
end

local function onTaxiViewEnter(context, toRoute, fromRoute, data)
  data.taxi = taxiCore.getTaxiViewData()
end


local function onTrafficVehicleCrashed(vehId)
  if not isOverhaulActive() then return end
  if not taxis[vehId] then return end

  if player.pickupTaxis[vehId] then
    -- a taxi coming to / waiting for the player crashed: drop it from the pickup set
    taxiCore.dismissPickupTaxi(vehId, _tr("ui.taxi.crashed"))
  elseif vehId == player.currentTaxiId then
    taxiCore.setIdleCamera(false)
    player.disableIdleCamera = true
  else
    -- any other traffic taxi: just mark it unavailable so it won't be hailed
    taxiCore.setTaxiState(vehId, "unavailable")
  end

  local veh = getObjectByID(vehId)
  if veh then
    veh:queueLuaCommand('local c = controller.getController("taxiLights") if c then c.setTaxiState("driverDistress") end')
  end
end

-- Same entries and ids as the career taxi: Other > Call Taxi and Career > Taxi > Call Taxi.
local function taxiEntry(entries, icon, uniqueID)
  if not isOverhaulActive() or not taxiCore.canCallTaxi() then return end
  if taxiCore.hasCalledATaxi() then
    table.insert(entries, {
      title = 'ui.taxi.cancelCall', icon = 'xmark', uniqueID = uniqueID,
      onSelect = function()
        if isOverhaulActive() then taxiCore.cancelTaxiCall() end
        return {'hide'}
      end,
    })
  else
    table.insert(entries, {
      title = getCallTaxiLabel(), icon = icon, uniqueID = uniqueID,
      onSelect = function()
        if isOverhaulActive() then taxiCore.callForTaxi() end
        return {'hide'}
      end,
    })
  end
end

local function onRegisterQuickAccessMenus()
  if not isOverhaulActive() or not core_quickAccess then return end
  core_quickAccess.addEntry({
    level = '/root/sandbox/other/',
    uniqueID = 'callTaxiActions',
    generator = function(entries) taxiEntry(entries, 'taxiCheckerLamp', 'callTaxi') end,
  })
  core_quickAccess.addEntry({
    level = '/root/sandbox/career/',
    uniqueID = 'taxiCategoryCareer',
    generator = function(entries)
      if not isOverhaulActive() then return end
      table.insert(entries, {title = 'Taxi', icon = 'taxiCheckerLamp', ["goto"] = '/root/sandbox/career/taxi/', uniqueID = 'taxiCategoryCareer'})
    end,
  })
  core_quickAccess.addEntry({
    level = '/root/sandbox/career/taxi/',
    uniqueID = 'callTaxiActionsCareer',
    generator = function(entries) taxiEntry(entries, 'smartphone1', 'callTaxiCareer') end,
  })
end
local function isTaxiRideActive() return player.currentPhase == playerRidePhases.driving or player.currentPhase == playerRidePhases.arriving end
local function isTaxiActive() return player.taxiViewActive end

M.startTaxiWithCurrentRoute = taxiCore.startTaxiWithCurrentRoute

M.getTaxiState = taxiCore.getTaxiState
M.isTaxiViewActive = isTaxiActive
M.isTaxiRideActive = isTaxiRideActive
M.getTaxiViewData = taxiCore.getTaxiViewData
M.onTaxiViewEnter = onTaxiViewEnter
M.onStopTaxiCalled = onStopTaxiCalled
M.onAiRouteDone = onAiRouteDone

M.onChangeDestinationCalled = onChangeDestinationCalled
M.onHurryUpCalled = onHurryUpCalled
M.onSlowDownCalled = onSlowDownCalled
M.onSkipCalled = onSkipCalled
M.setIdleCameraEnabled = setIdleCameraEnabled

M.onSetBigmapNavFocus = onSetBigmapNavFocus
M.confirmTaxiDestination = confirmTaxiDestination
M.onDeactivateBigMapCallback = onDeactivateBigMapCallback
M.onTrafficSpecialVehiclesProviders = onTrafficSpecialVehiclesProviders
M.onTrafficStarted = taxiCore.onTrafficStarted
M.onTrafficVehicleAdded = taxiCore.onTrafficVehicleAdded
M.onTrafficVehicleRemoved = taxiCore.onTrafficVehicleRemoved
M.onTrafficStopped = function(...)
  if isOverhaulActive() then return taxiCore.onTrafficStopped(...) end
end
M.onAnyMissionChanged = taxiCore.onAnyMissionChanged
M.taxiSettingChanged = taxiCore.taxiSettingChanged
M.onTrafficVehicleCrashed = onTrafficVehicleCrashed
M.onVehicleResetted = onVehicleResetted
M.onVehicleSwitched = onVehicleSwitched
M.onPlayerVehiclePresenceChanged = onPlayerVehiclePresenceChanged
M.onGameplayInteract = onGameplayInteract
M.onVehicleTriggersExecuteLink = onVehicleTriggersExecuteLink
M.onUpdate = taxiCore.onUpdate
M.onRegisterQuickAccessMenus = onRegisterQuickAccessMenus
M.callForTaxi = taxiCore.callForTaxi
M.cancelTaxiCall = taxiCore.cancelTaxiCall
M.setUseBillboards = function(enabled)
  taxiRuntime.useBillboards = enabled
  if not enabled then taxiRuntime.clearTaxiBillboards() end
  log("I", "taxi", "useBillboards = " .. tostring(enabled))
end

local taxiBillboards = {} -- vehId -> { bbId, stateKey, topZ }
local bbUpdatePos = vec3()
local bbHidePos = vec3(0, 0, 0)

local stateAccents = {
  available            = "#00ff2aff",
  enRoute              = "#00ccffff",
  pullingOverForPickup = "#ffbb00ff",
  waitingForPickup     = "#00ccffff",
  unavailable          = "#ff2222ff",
}

local function ensureBBRenderer()
  if taxiRuntime.bbRenderer and taxiRuntime.bbRenderer.create then return taxiRuntime.bbRenderer end
  if scenetree and scenetree.overhaulTaxiStateTags then taxiRuntime.bbRenderer = scenetree.overhaulTaxiStateTags; return taxiRuntime.bbRenderer end
  if not (WorldBillboardRenderer and scenetree and scenetree.MissionGroup) then return nil end
  local billboardRenderer = WorldBillboardRenderer()
  if not billboardRenderer then return nil end
  billboardRenderer:registerObject("overhaulTaxiStateTags")
  scenetree.MissionGroup:addObject(billboardRenderer)
  taxiRuntime.bbRenderer = billboardRenderer
  return billboardRenderer
end

local BILLBOARD_WIDTH_PIXELS, BILLBOARD_HEIGHT_PIXELS = 512, 240
local domePath = string.format("M 0 %d A %d %d 0 0 1 %d %d Z", BILLBOARD_HEIGHT_PIXELS, BILLBOARD_WIDTH_PIXELS / 2, BILLBOARD_HEIGHT_PIXELS, BILLBOARD_WIDTH_PIXELS, BILLBOARD_HEIGHT_PIXELS)

local function buildLabelTemplate(label, accent)
  return {
    size = {BILLBOARD_WIDTH_PIXELS, BILLBOARD_HEIGHT_PIXELS},
    root = {
      type = "group",
      style = {justifyContent = "center", alignItems = "center", paddingTop = 50, paddingBottom = 16},
      children = {
        {type = "path", path = domePath,
         color = "#000000aa", stroke = "#ffffffee", strokeWidth = 4,
         style = {position = "absolute", left = 0, top = 0, width = BILLBOARD_WIDTH_PIXELS, height = BILLBOARD_HEIGHT_PIXELS}},
        {type = "text", text = "TAXI", fontSize = 48, color = "#ffffffff",
         letterSpacing = 10, style = {height = 56}},
        {type = "text", text = label, fontSize = 72, color = accent, fit = "shrink",
          style = {width = "75%", height = 84}},
      },
    },
  }
end

local function destroyBillboard(vehId)
  local data = taxiBillboards[vehId]
  if data and taxiRuntime.bbRenderer then pcall(function() taxiRuntime.bbRenderer:destroy(data.bbId) end) end
  taxiBillboards[vehId] = nil
end

local function refreshBillboard(vehId, stateKey)
  local billboardRenderer = ensureBBRenderer()
  if not billboardRenderer then return end
  destroyBillboard(vehId)

  local stateDef = taxiStates[stateKey]
  local accent = stateAccents[stateKey]
  if not (stateDef and stateDef.displayInfo and accent) then return end

  local tmpl = buildLabelTemplate(stateDef.displayInfo.label, accent)
  local id = billboardRenderer:create(jsonEncode(tmpl), false)
  if id and id ~= 0 then
    billboardRenderer:render(id, "{}")
    local veh = getObjectByID(vehId)
    local topZOffset = 0
    if veh then
      local oobb = veh:getSpawnWorldOOBB()
      local he = oobb:getHalfExtents()
      topZOffset = math.abs(oobb:getAxis(0).z) * he.x
        + math.abs(oobb:getAxis(1).z) * he.y
        + math.abs(oobb:getAxis(2).z) * he.z
    end
    taxiBillboards[vehId] = {bbId = id, stateKey = stateKey, topZOffset = topZOffset}
  end
end

local bbBaseScale = 0.8
local billboardReferenceDistanceMeters   = 15
local billboardFadeStartMeters  = 40
local billboardFadeEndMeters   = 45
local bbAspect    = BILLBOARD_HEIGHT_PIXELS / BILLBOARD_WIDTH_PIXELS

local function updateTaxiBillboards()
  if not gameplay_walk.isWalking() then
    for vehId in pairs(taxiBillboards) do destroyBillboard(vehId) end
    return
  end

  local billboardRenderer = ensureBBRenderer()
  if not billboardRenderer then return end

  local camPos = core_camera and core_camera.getPosition() or nil

  for vehId, stateKey in pairs(taxis) do
    local veh = getObjectByID(vehId)
    if not veh or not be:getObjectActive(vehId) then
      destroyBillboard(vehId)
    else
      local data = taxiBillboards[vehId]
      if not data or data.stateKey ~= stateKey then
        refreshBillboard(vehId, stateKey)
        data = taxiBillboards[vehId]
      end
      if data and camPos then
        local center = veh:getSpawnWorldOOBB():getCenter()
        local topZ = center.z + data.topZOffset

        local dist = camPos:distance(center)

        if dist > billboardFadeEndMeters then
          billboardRenderer:update(data.bbId, bbHidePos, 0, false)
        else
          local fade = dist < billboardFadeStartMeters and 1 or (1 - (dist - billboardFadeStartMeters) / (billboardFadeEndMeters - billboardFadeStartMeters))
          local scale = bbBaseScale * (dist / billboardReferenceDistanceMeters) * fade
          bbUpdatePos.x = center.x
          bbUpdatePos.y = center.y
          bbUpdatePos.z = topZ + scale * 0.5
          billboardRenderer:update(data.bbId, bbUpdatePos, scale, true)
        end
      elseif data then
        billboardRenderer:update(data.bbId, bbHidePos, 0, false)
      end
    end
  end

  for vehId in pairs(taxiBillboards) do
    if not taxis[vehId] then destroyBillboard(vehId) end
  end
end

taxiRuntime.drawTaxiLabels = updateTaxiBillboards

local function nukeBillboards()
  local billboardRenderer = scenetree and scenetree.overhaulTaxiStateTags
  if billboardRenderer then billboardRenderer:deleteObject() end
  taxiRuntime.bbRenderer = nil
  table.clear(taxiBillboards)
end

taxiRuntime.clearTaxiBillboards = nukeBillboards

M.onClientEndMission = M.onTrafficStopped

function M.disable()
  for handle in pairs(taxiJobs) do
    core_jobsystem.cancelJob(handle)
    if handle.exitcbl then handle.exitcbl() end
  end
  table.clear(taxiJobs)
  taxiCore.restoreVehicleSwitching()
  taxiCore.onTrafficStopped()
  nukeBillboards()
  if gameplay_traffic and gameplay_traffic.unregisterSpecialVehicleProvider then
    gameplay_traffic.unregisterSpecialVehicleProvider('taxi')
  end
end

-- What the rest of the game leaves alone because of the cab service (lib/vehicles/policy). Two owners:
-- the fleet (taxis working a ride, whoever drives past) and the hired cab (the player's own ride).
-- Both register for as long as this extension is loaded, in freeroam as well as career: the checks they
-- replace ran whenever the service was loaded, and disable() above does not unload it.
local policy = require('overhaul/lib/vehicles/policy')

local function isPlayerVehicle(vehId)
  return vehId == nil or vehId == be:getPlayerVehicleID(0)
end

local disposeFleetPolicy = policy.register('taxiFleet', {
  offenseExempt = function(vehId)
    local state = vehId ~= nil and taxiStates[taxiCore.getTaxiState(vehId)]
    return state and state.inService == true or false
  end,
  roleLocked = function(vehId, vehicle)
    if not vehicle or not vehicle.isTaxi then return false end
    local state = taxiStates[taxiCore.getTaxiState(vehId)]
    return state and state.inService == true or false
  end,
}, 'loaded')

-- A ride in progress covers the player's vehicle for offense detection, the player's speed fines and the
-- pursuit events of the ride, but not the police's choice of target.
local disposeCabPolicy = policy.register('hiredCab', {
  offenseExempt = function(vehId) return isTaxiRideActive() and isPlayerVehicle(vehId) end,
  speedImmune = isTaxiRideActive,
  pursuitOutcomeIgnored = isTaxiRideActive,
}, 'loaded', {
  hiredPassenger = function(vehId)
    return vehId ~= nil and (player.pickupTaxis[vehId] ~= nil or player.currentTaxiId == vehId)
  end,
})

-- Dispose of both registrations with the extension; they belong to this load only.
function M.onExtensionUnloaded()
  disposeFleetPolicy()
  disposeCabPolicy()
  M.disable()
end

-- This load's activity definition, adopted by the activity host; it delegates to the
-- functions above (no projection).
M.activity = require('overhaul/integration/services/taxi/activity')(M)

return M
