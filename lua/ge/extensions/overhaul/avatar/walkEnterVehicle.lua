-- Walking entry and exit; private geometry, camera and movement parts live in walkEnterVehicle/.
-- Read tuning, runtime state, shared helpers, parts, frame update, lifecycle, public API, then game hooks.
local M = {}
local passengerSeats = require('overhaul/lib/vehicles/passengerSeats')
M.dependencies = {"overhaul_shell_patches", "overhaul_vehicles_legacyDriverSeat"}

-- Config

local config = {
  arriveM = 0.42, approachTimeoutS = 14, stallWindowS = 2, stallPathM = 0.75,
  approachSpeedFraction = 0.45,
  boardDurationS = 0.58, boardTimeoutS = 1.05,
  boardCollisionM = 0.35, boardStallM = 1.05,
  entryCloseClearanceM = 0.28, entryPocketLengthM = 0.46,
  entryStepClearanceM = 0.31, entryStepArriveM = 0.10, entryStepTimeoutS = 1.80,
  doorWaitClearanceM = 0.52, doorProbeIntervalS = 0.08,
  doorFallbackOpenS = 0.16, doorSwingSettleS = 0.28, doorOpenTimeoutS = 2.2,
  doorCloseDelayS = 0.10, doorCloseFinishS = 0.18,
  doorCloseTimeoutS = 1.65, doorCloseRetryS = 0.90,
  driverSettleDurationS = 0.68, boardLookResponseRatePerS = 4.25,
  boardLookMaxRateRadPerS = math.rad(72), bodyClearanceM = 0.55,
  routeMarginM = 0.58, waypointDistanceM = 0.24, obbMarginM = 1,
  collisionHeightBelowM = 0.55, collisionHeightAboveM = 2.10, hullCacheTimeS = 0.08,
  standOutFraction = 0.32, standBackFraction = 0.38,
  lookResponseRatePerS = 2.15, lookPitchResponseRatePerS = 1.7,
  lookMaxRateRadPerS = math.rad(48), lookMaxPitchRateRadPerS = math.rad(28)
}
local up = vec3(0, 0, 1)

local WALK_PATCH_ID = "walkEntryWalking"
local SWITCH_PATCH_ID = "walkEntryVehicleSwitch"
local boardingCamera = {
  highSeatThreshold = 0.12,
  lowSeatThreshold = -0.12
}

-- State

local runtimeState = {}
runtimeState.approach = nil
runtimeState.exitTransition = nil
runtimeState.postEnter = nil
runtimeState.postExit = nil
runtimeState.driverSettle = nil
runtimeState.lastApproachStats = nil
runtimeState.lastExitStats = nil
runtimeState.originalToggle = nil
runtimeState.originalSetWalkingMode = nil
runtimeState.originalSwitchCycle = nil
runtimeState.collisionEnvelopes = {}
runtimeState.collisionEnvelopeRequestId = 0
runtimeState.lastPlayerPos = nil

runtimeState.lastSpeedCoef = 0
runtimeState.lastWalkLen = 0
local lastExternal = {x = nil, y = nil, speed = nil}

-- Shared helpers

local function isRealisticEntryEnabled()
  local settingsExtension = rawget(_G, "overhaul_shell_settings")
  if settingsExtension and settingsExtension.getSetting then
    return settingsExtension.getSetting("realisticVehicleEntry") ~= false
  end
  return true
end

-- Seat cameras use occupant.<seatId>; legacy vehicles use overhaulDriver.
local function getDriverCameraName(vehicle)
  if vehicle then
    local name = core_camera.getDriverCameraNameById(vehicle:getId())
    if name then return name end
  end
  return "driver"
end

local function isDriverCameraName(vehicle, cameraName)
  if type(cameraName) ~= "string" then return false end
  if cameraName == "driver" then return true end
  return cameraName == getDriverCameraName(vehicle)
end

local function getDriverCameraMode(vehicle)
  local cameraData = vehicle and core_camera.getCameraDataById(vehicle:getId())
  if not cameraData then return nil end
  return cameraData[getDriverCameraName(vehicle)] or cameraData.driver
end

-- Fire the entry hook before seating so occupant state is recorded.
local function enterVehicleFromWalk(vehicle, doorInfo)
  local player = 0
  extensions.hook("onBeforeWalkingModeToggled", false, vehicle:getId(), player)
  if doorInfo and doorInfo.passenger then
    local handled, seat = passengerSeats.enter(vehicle:getId(), doorInfo.passengerSeat)
    if seat then doorInfo.passengerSeat = seat end
    if handled ~= nil then return handled ~= false end
    gameplay_walk.getInVehicle(vehicle, player)
    return true
  end
  local handled
  if gameplay_seatOccupants and gameplay_seatOccupants.requestEnterBestSeat then
    if overhaul_vehicles_legacyDriverSeat then overhaul_vehicles_legacyDriverSeat.refresh(vehicle:getId()) end
    local unicycle = gameplay_walk.getCurrentUnicycle and gameplay_walk.getCurrentUnicycle(player) or nil
    local walkingPosition = unicycle and vec3(unicycle:getPosition()) or nil
    handled = gameplay_seatOccupants.requestEnterBestSeat(vehicle:getId(), player, walkingPosition)
  end
  if handled == nil then
    gameplay_walk.getInVehicle(vehicle, player)
    return true
  end
  return handled ~= false
end

local function isEnterableVehicle(vehicle)
  if not vehicle or vehicle.playerUsable == false or vehicle:getJBeamFilename() == "unicycle" then
    return false
  end
  if gameplay_walk.isVehicleBlacklisted and gameplay_walk.isVehicleBlacklisted(vehicle:getId()) then
    return false
  end
  return vehicle:getActive() == true or vehicle:getActive() == 1
end

-- Parts

local parts = {}
parts.doors = require('overhaul/avatar/walkEnterVehicle/doors').new({
  state = runtimeState, config = config, lastExternal = lastExternal,
})
parts.paths = require('overhaul/avatar/walkEnterVehicle/paths').new({
  parts = parts,
  state = runtimeState, config = config,
})
parts.camera = require('overhaul/avatar/walkEnterVehicle/camera').new({
  parts = parts,
  state = runtimeState, boardingCamera = boardingCamera, config = config,
  getDriverCameraMode = getDriverCameraMode, up = up,
})
parts.approach = require('overhaul/avatar/walkEnterVehicle/approach').new({
  parts = parts,
  state = runtimeState, config = config, enterVehicleFromWalk = enterVehicleFromWalk,
  isDriverCameraName = isDriverCameraName, isEnterableVehicle = isEnterableVehicle,
  isRealisticEntryEnabled = isRealisticEntryEnabled,
})
parts.exit = require('overhaul/avatar/walkEnterVehicle/exit').new({
  parts = parts,
  state = runtimeState, config = config, getDriverCameraMode = getDriverCameraMode,
  isDriverCameraName = isDriverCameraName, isRealisticEntryEnabled = isRealisticEntryEnabled,
  up = up,
})
parts.update = require('overhaul/avatar/walkEnterVehicle/update').new({
  parts = parts,
  state = runtimeState, config = config, up = up, boardingCamera = boardingCamera,
  isEnterableVehicle = isEnterableVehicle, isRealisticEntryEnabled = isRealisticEntryEnabled,
})

-- Stock passenger permissions block driving, but do not publish presence to the HUD.
local function onPlayerVehiclePresenceChanged(player, _, presence)
  if player == 0 then
    guihooks.trigger('OverhaulPassengerMode', presence and presence.permissionMode == 'passenger' or false)
  end
end

-- Per-frame update

M.onUpdate = parts.update.onUpdate

-- Lifecycle

local function registerPatches()
  overhaul_shell_patches.registerFields(WALK_PATCH_ID, function() return rawget(_G, "gameplay_walk") end, {
    toggleWalkingMode = function(original)
      if type(original) ~= "function" then return end
      runtimeState.originalToggle = original
      return parts.exit.wrappedToggleWalkingMode
    end,
    setWalkingMode = function(original)
      if type(original) ~= "function" then return end
      runtimeState.originalSetWalkingMode = original
      return parts.exit.wrappedSetWalkingMode
    end,
  })
  overhaul_shell_patches.registerFields(SWITCH_PATCH_ID, function() return rawget(_G, "core_input_vehicleSwitching") end, {
    switchCycleVehicle = function(original)
      if type(original) ~= "function" then return end
      runtimeState.originalSwitchCycle = original
      return parts.exit.wrappedSwitchCycleVehicle
    end,
  })
end

local function onExtensionLoaded()
  registerPatches()
  if gameplay_walk and gameplay_walk.getCurrentUnicycle then
    local unicycle = gameplay_walk.getCurrentUnicycle()
    if unicycle then
      unicycle:queueLuaCommand("local c = controller.getControllerSafe('overhaulPlayerController') if c and c.setExternalWorldMove then c.setExternalWorldMove(nil) end")
    end
  end
end

local function onExtensionUnloaded()
  parts.approach.cancelApproach()
  parts.exit.cancelExit("extensionUnload")
  runtimeState.postEnter = nil
  runtimeState.postExit = nil
  runtimeState.collisionEnvelopes = {}
  if runtimeState.driverSettle then
    parts.camera.restoreDriverCamera(runtimeState.driverSettle)
    runtimeState.driverSettle = nil
  end
  overhaul_shell_patches.unregister(WALK_PATCH_ID)
  overhaul_shell_patches.unregister(SWITCH_PATCH_ID)
  runtimeState.originalToggle, runtimeState.originalSetWalkingMode, runtimeState.originalSwitchCycle = nil, nil, nil
end

-- Entry and exit

M.startApproach = parts.approach.startApproach
M.startExit = parts.exit.startExit
M.cancelApproach = parts.approach.cancelApproach
M.getLastApproachStats = function() return runtimeState.lastApproachStats end
M.getLastExitStats = function() return runtimeState.lastExitStats end

-- Doorway geometry

M.getClosestDoorName = parts.doors.getClosestDoorName
M.getEntryDoorInfo = parts.doors.findEntryDoorInfo
M.getDriverDoorInfo = parts.doors.findDriverDoorInfo
M.getDoorTriggerCenter = parts.doors.getDoorTriggerCenter
M.getVehicleRefPos = parts.doors.getVehicleRefPos
M.getStandPos = parts.paths.getStandPos
M.getDoorEntryPos = parts.paths.getDoorEntryPos
M.getDoorPocketPos = parts.paths.getDoorPocketPos

-- Vehicle replies

M.notePlayerMove = parts.doors.notePlayerMove
M.noteDoorState = parts.doors.noteDoorState
M.receiveCollisionEnvelope = parts.paths.receiveCollisionEnvelope

-- Game hooks

-- Vanilla lets a player in without a free seat only in freeroam; career gets the same rule.
local function onResolveVehiclePresenceMode(query)
  if query.mode or not (overhaul_career_career and overhaul_career_career.isActive()) then return end
  local multiplayer = multiplayer_sessionManager and multiplayer_sessionManager.getCurrentSession
    and multiplayer_sessionManager.getCurrentSession() ~= nil
  local multiseat = core_multiseat.isMultiseatActive()
  if not multiplayer and not multiseat then query.mode = "unrestricted" end
end

local function onVehicleSwitched(oldId, newId, player)
  if player == 0 and runtimeState.approach then
    parts.approach.cancelApproach()
  end
  if (player == nil or player == 0) and runtimeState.exitTransition and runtimeState.exitTransition.phase == "openDoor"
    and not runtimeState.exitTransition.switchingToWalk and newId ~= runtimeState.exitTransition.vehId then
    parts.exit.cancelExit("vehicleSwitched")
  end
  -- Entry requests envelopes on demand; tuning previews can switch vehicles on every click.
end

local function onVehicleSpawned(vehId)
  runtimeState.collisionEnvelopes[vehId] = nil
end

local function onVehicleDestroyed(vehId)
  runtimeState.collisionEnvelopes[vehId] = nil
end

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onVehicleSwitched = onVehicleSwitched
M.onVehicleSpawned = onVehicleSpawned
M.onVehicleDestroyed = onVehicleDestroyed
M.onResolveVehiclePresenceMode = onResolveVehiclePresenceMode

M.onPlayerVehiclePresenceChanged = onPlayerVehiclePresenceChanged

return M
