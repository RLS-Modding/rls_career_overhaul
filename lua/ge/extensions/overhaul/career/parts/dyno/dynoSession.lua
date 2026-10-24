-- Dyno sessions: offers, inspections, pulls, saved results and vehicle restoration.
-- Each load owns its session, parts, pending vehicle replies and activity API.

local M = {}
local vehicleCommands = require("overhaul/lib/vehicles/vehicleCommands")

M.dependencies = {
  "core_vehicle_partmgmt",
  "gameplay_sites_sitesManager"
}

local bundles = require("overhaul/lib/business/bundles")
local levelData = require("overhaul/lib/world/levelData")
local jbeamIO = require("jbeam/io")

-- Config -------------------------------------------------------------------------------------------

local SESSION_FEE = 1000
local SESSION_PULL_LIMIT = 3
local DEFAULT_DYNO_HUB_ID = "rls"
local HISTORY_SAVE_FILE = "/career/rls_career/dynoPullHistory.json"
local HISTORY_VERSION = 1
local HISTORY_LIMIT_PER_VEHICLE = 25
local STEERING_SETUP_TIMEOUT_SECONDS = 5

local DYNO_HUB_ORDER = {
  "rls",
  "drowsysam"
}

local DYNO_HUB_OPTIONS = {
  drowsysam = {
    id = "drowsysam",
    label = "DrowsySam Hub Dyno",
    description = "Original D300S hub dyno hardware.",
    requiredFile = "/vehicles/common/dshub_dyno/dshub_dyno_F_5.jbeam",
    frontPartPrefix = "dshub_dyno_F_",
    rearPartPrefix = "dshub_dyno_R_"
  },
  rls = {
    id = "rls",
    label = "RLS Hub Dyno",
    description = "RLS hub dyno hardware.",
    partsBySlot = {
      wheel_F_4 = "wheel_dyno_rls_F5",
      wheel_F_5 = "wheel_dyno_rls_F5",
      wheel_F_6 = "wheel_dyno_rls_F5",
      wheel_F_8 = "wheel_dyno_rls_F5",
      wheel_F_centerlug = "wheel_dyno_rls_F5",
      wheel_R_4 = "wheel_dyno_rls_R5",
      wheel_R_5 = "wheel_dyno_rls_R5",
      wheel_R_6 = "wheel_dyno_rls_R5",
      wheel_R_8 = "wheel_dyno_rls_R5",
      wheel_R_centerlug = "wheel_dyno_rls_R5"
    }
  }
}

local SUPPORTED_FRONT_SUFFIXES = {
  ["4"] = true,
  ["5"] = true,
  ["6"] = true,
  ["8"] = true,
  ["C"] = true
}

local SUPPORTED_REAR_SUFFIXES = {
  ["3"] = true,
  ["4"] = true,
  ["5"] = true,
  ["6"] = true,
  ["8"] = true,
  ["10"] = true,
  ["C"] = true
}

-- State --------------------------------------------------------------------------------------------

-- Runtime flags and caches for this load: steering guard, condition and ownership waits, pull history.
local dynoState = {
  playerInsideTrigger = false,
  steeringSetupTimer = 0,
  steeringSetupToken = 0,
  pullHistoryByVehicle = {},
  nextPullHistoryId = 1,
  pullHistoryLoaded = false,
  savedPullsRevision = 0,
  conditionRefreshPending = false,
  conditionRefreshToken = 0,
  conditionRefreshCallbacks = {},
  ownershipWaitCallbacks = {},
  station = nil,
}

-- The session the player is in. Saved with the car's inventory while it runs.
local dynoSession = {
  active = false,
  inventoryId = nil,
  sourceVehicleId = nil,
  originalTransform = nil,
  originalConfig = nil,
  originalPartConditions = nil,
  originalLiveConfig = nil,
  sessionVehicleId = nil,
  parkingSpotName = nil,
  selectedHubId = DEFAULT_DYNO_HUB_ID,
  hubConfigApplied = false,
  pullState = nil,
  result = nil,
  pullsUsed = 0,
  policy = nil,
  feePaid = 0,
  setupFeeRefundable = false,
  serviceOpen = nil,
  resumePhase = nil,
  retryArmDelay = nil,
  phase = "offer",
  error = nil,
  statusText = nil
}

-- Vehicle config snapshots still waiting for the vehicle's reply, keyed by callback id.
local pendingConfigSnapshots = {}
local protectedSteeringVehicles = {}

-- Parts ---------------------------------------------------------------------------------------------

local parts = {}
local recoveryConfig
local function getRecoveryConfig()
  if not recoveryConfig then
    recoveryConfig = assert(jsonReadFile('/gameplay/overhaul/activities/dyno.json').recovery)
  end
  return recoveryConfig
end
local inputs = {
  getRecoveryConfig = getRecoveryConfig,
  parts = parts,
  bundles = bundles,
  SESSION_FEE = SESSION_FEE,
  levelData = levelData,
  HISTORY_SAVE_FILE = HISTORY_SAVE_FILE,
  HISTORY_VERSION = HISTORY_VERSION,
  HISTORY_LIMIT_PER_VEHICLE = HISTORY_LIMIT_PER_VEHICLE,
  dynoState = dynoState,
  dynoSession = dynoSession,
  jbeamIO = jbeamIO,
  DEFAULT_DYNO_HUB_ID = DEFAULT_DYNO_HUB_ID,
  DYNO_HUB_ORDER = DYNO_HUB_ORDER,
  DYNO_HUB_OPTIONS = DYNO_HUB_OPTIONS,
  SUPPORTED_FRONT_SUFFIXES = SUPPORTED_FRONT_SUFFIXES,
  SUPPORTED_REAR_SUFFIXES = SUPPORTED_REAR_SUFFIXES,
  pendingConfigSnapshots = pendingConfigSnapshots,
  protectedSteeringVehicles = protectedSteeringVehicles,
  SESSION_PULL_LIMIT = SESSION_PULL_LIMIT,
}

local stationsByMap = {}
local function stationForTrigger(triggerName)
  local mapId = getCurrentLevelIdentifier()
  if not mapId then return nil end
  if not stationsByMap[mapId] then
    local stations = {}
    for _, definition in ipairs(overhaul_world_facilities.getFacilitiesByType("dyno", mapId) or {}) do
      if type(definition.id) == "string" and type(definition.triggerName) == "string"
        and type(definition.sitesFile) == "string" and type(definition.parkingSpotName) == "string"
        and not stations[definition.triggerName] then
        local station = deepcopy(definition)
        station.mapId = mapId
        stations[station.triggerName] = station
      else
        log("W", "dynoSession", "Ignoring dyno without trigger/sites/spot: " .. tostring(definition.id))
      end
    end
    stationsByMap[mapId] = stations
  end
  return stationsByMap[mapId][triggerName]
end

-- Asks the vehicle for its config and tire state; the reply comes back through onVehicleConfigSnapshotReceived.
local function requestVehicleConfigSnapshot(veh, requestType, extraData)
  if not veh then
    return nil
  end

  local callbackId = string.format("%d_%d_%d", veh:getID(), os.time(), math.random(1000, 9999))
  pendingConfigSnapshots[callbackId] = {
    type = requestType,
    extraData = extraData or {}
  }

  veh:queueLuaCommand([[
    local configData = serialize(v.config)
    local tireState = overhaulTires and overhaulTires.getRlsTireTelemetry and
                        ]] .. vehicleCommands.call("overhaulTires", "getRlsTireTelemetry") .. [[ or nil
    obj:queueGameEngineLua(require('vehicle/overhaul/geCallback').reply(]] .. require('overhaul/lib/vehicles/callbacks').open('dynoConfigSnapshot', {owner = 'dynoSession', vehId = veh:getID(), onFail = function() M.onVehicleConfigSnapshotReceived(callbackId, nil) end}) .. [[, 'dynoConfigSnapshot', "']] .. callbackId .. [[', " ..
      configData .. ", " .. serialize(tireState)))
  ]])

  return callbackId
end

inputs.requestVehicleConfigSnapshot = requestVehicleConfigSnapshot

for _, name in ipairs({'history', 'hubs', 'vehicle', 'setup', 'pulls', 'recovery'}) do
  parts[name] = require('overhaul/career/parts/dyno/dynoSession/' .. name).create(inputs)
end

-- Bay and vehicle events -----------------------------------------------------------------------------

local function leaveDynoBay()
  dynoState.playerInsideTrigger = false
  dynoState.conditionRefreshToken = dynoState.conditionRefreshToken + 1
  dynoState.conditionRefreshPending = false
  dynoState.conditionRefreshCallbacks = {}
  if not dynoSession.active then
    parts.vehicle.closeDynoUi()
  end
end

-- Entering the bay starts an inspection of the car's damage before the offer opens.
local function openOfferAfterInspection(context)
  local station = dynoState.station
  local queued = parts.vehicle.refreshLiveVehicleConditions(context, function()
    if dynoState.playerInsideTrigger and dynoState.station == station and not dynoSession.active then
      dynoSession.phase = "offer"
      dynoSession.error = nil
      dynoSession.statusText = nil
      parts.vehicle.openDynoUi()
    end
  end)
  if not queued then
    parts.vehicle.setDynoError("The vehicle damage inspection is already in progress.", "inspecting")
    parts.vehicle.openDynoUi()
  end
end

local function onBeamNGTrigger(data)
  if data.subjectID ~= be:getPlayerVehicleID(0) then
    return
  end

  if gameplay_walk.isWalking() then
    return
  end

  local station = stationForTrigger(data.triggerName)
  if not station then return end
  if dynoSession.active and (not dynoState.station or station.id ~= dynoState.station.id
    or station.mapId ~= dynoState.station.mapId) then return end

  if data.event == "enter" then
    dynoState.station = station
    dynoSession.stationId = station.id
    dynoSession.mapId = station.mapId
    dynoSession.parkingSpotName = station.parkingSpotName
    dynoState.playerInsideTrigger = true
    if not dynoSession.active then
      dynoSession.phase = "inspecting"
      dynoSession.error = nil
      dynoSession.statusText = "Inspecting current vehicle damage."
      local context, contextError = parts.vehicle.getCurrentVehicleContext()
      if not context then
        parts.vehicle.setDynoError(contextError or "The vehicle could not be inspected.", "offer")
        parts.vehicle.openDynoUi()
      else
        openOfferAfterInspection(context)
      end
    end
  elseif data.event == "exit" then
    if dynoState.station and dynoState.station.id == station.id then leaveDynoBay() end
  end
end

-- The trigger only reports the player's car, so getting out or switching cars leaves the bay.
local function onVehicleSwitched(_, newId)
  if not dynoSession.active then
    if dynoState.playerInsideTrigger then leaveDynoBay() end
    return
  end

  if dynoSession.phase == "starting" or dynoSession.phase == "leaving" then
    return
  end

  if dynoSession.sessionVehicleId and newId ~= dynoSession.sessionVehicleId then
    local newInventoryId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(newId) or nil
    local mappedVehicleId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(dynoSession.inventoryId) or nil
    if tonumber(newInventoryId) == tonumber(dynoSession.inventoryId) or tonumber(mappedVehicleId) == tonumber(newId) or
        (dynoSession.serviceOpen and newInventoryId == nil) then
      dynoSession.sessionVehicleId = newId
      parts.setup.beginTireProtection(dynoSession.inventoryId)
      return
    end
    parts.vehicle.setDynoError("The dyno session ended because you changed vehicles.", dynoSession.phase)
    parts.setup.finishSessionRestore()
  end
end

-- Frame updates ------------------------------------------------------------------------------------

-- A steering guard that never acknowledges cancels the session after five seconds.
local function tickSteeringSetupTimeout(dtReal)
  if not dynoState.pendingSteeringSetup then return end
  dynoState.steeringSetupTimer = dynoState.steeringSetupTimer + (dtReal or 0)
  if dynoState.steeringSetupTimer > STEERING_SETUP_TIMEOUT_SECONDS then
    dynoState.pendingSteeringSetup = nil
    parts.vehicle.setDynoError("The dyno could not mute steering feedback. Session cancelled.", "offer")
    parts.setup.finishSessionRestore()
  end
end

-- Retries the next pull once the reset delay has passed, so the vehicle has settled.
local function tickPullReset(dtReal)
  if not dynoSession.active or dynoSession.phase ~= "resetting" then
    return
  end

  dynoSession.retryArmDelay = (dynoSession.retryArmDelay or 0) - math.max(tonumber(dtReal) or 0, 0)
  if dynoSession.retryArmDelay > 0 then
    return
  end

  dynoSession.retryArmDelay = nil
  dynoSession.phase = "ready"
  dynoSession.statusText = "Vehicle reset. Arming another dyno pull."
  dynoState.startPull()
end

local function onUpdate(dtReal, dtSim)
  if #dynoState.ownershipWaitCallbacks > 0 and not parts.history.shopNeedsOwnershipResolution() then
    parts.history.flushOwnershipWaitCallbacks()
  end

  tickSteeringSetupTimeout(dtReal)
  parts.recovery.onUpdate(dtReal, dtSim)
  parts.vehicle.updateDynoCameras()
  parts.pulls.cleanupIfSessionVehicleMissing()
  tickPullReset(dtReal)
end

-- Career and level hooks -----------------------------------------------------------------------------

local function onCareerDeactivatedWhileLevelLoaded()
  if not dynoSession.active then
    parts.vehicle.resetDynoSessionState()
    return
  end

  parts.setup.finishSessionForTeardown(true)
end

local function onCareerActivated()
  parts.history.loadPullHistory()
end

local function onExtensionLoaded()
  if overhaul_career_career and overhaul_career_career.isActive() then
    parts.history.loadPullHistory()
  end
end

local function onOverhaulSaveCurrentProfile(currentSavePath, _, writer)
  writer = writer or overhaul_career_saveSystem.getSaveWriter()
  parts.history.savePullHistory(currentSavePath, writer)
end

local function onClientEndMission()
  stationsByMap = {}
  parts.setup.finishSessionForTeardown(false)
  dynoState.playerInsideTrigger = false
end

local function onExtensionUnloaded()
  parts.vehicle.hideDynoHud()
  if dynoSession.active then
    parts.setup.finishSessionForTeardown(true)
  else
    parts.vehicle.releaseAllDynoSteering()
    parts.vehicle.resetDynoSessionState()
  end
end
-- Public API ---------------------------------------------------------------------------------------

M.requestSessionData = dynoState.requestSessionData
M.requestResultData = parts.pulls.requestResultData
M.saveCurrentPull = parts.pulls.saveCurrentPull
M.deleteSavedPull = parts.pulls.deleteSavedPull
M.getPullHistoryForVehicle = parts.history.getPullHistoryForVehicle
M.startSession = dynoState.startSession
M.repairAndStart = dynoState.repairAndStart
M.leaveSession = parts.setup.leaveSession
M.beginGarageTow = parts.setup.beginGarageTow
M.cancelGarageTow = parts.setup.cancelGarageTow
M.startPull = dynoState.startPull
M.retryPull = dynoState.retryPull
M.openTuning = parts.pulls.openTuning
M.openMaintenance = parts.pulls.openMaintenance
M.resumeFromService = parts.pulls.resumeFromService
M.isTransientConfigActive = parts.setup.isTransientConfigActive
M.getInventorySaveOverride = parts.setup.getInventorySaveOverride
M.applyInventorySpawnOverrides = parts.setup.applyInventorySpawnOverrides
M.commitTuningPurchase = parts.setup.commitTuningPurchase
M.buildInventorySaveOverride = parts.setup.buildInventorySaveOverride

M.onVehicleConfigSnapshotReceived = parts.pulls.onVehicleConfigSnapshotReceived
M.onPullSample = parts.pulls.onPullSample
M.onPullFinished = parts.pulls.onPullFinished

-- Include asynchronous inspection/setup, not just an active pull.
M.isBusinessSessionBusy = function(businessId)
  local policy = parts.history.currentPolicy()
  return policy.businessId == businessId and (dynoSession.active or dynoState.conditionRefreshPending
    or #dynoState.ownershipWaitCallbacks > 0
    or next(pendingConfigSnapshots) ~= nil or dynoState.pendingSteeringSetup ~= nil
    or dynoSession.phase == "starting" or dynoSession.phase == "inspecting")
end

M.activity = require('overhaul/career/parts/dyno/dynoSession/activity')(M)

-- Hooks --------------------------------------------------------------------------------------------

M.onExtensionUnloaded = onExtensionUnloaded
M.onSteeringProtectionReady = parts.vehicle.onSteeringProtectionReady
M.onVehicleSpawned = parts.vehicle.onVehicleSpawned
M.onFFBConfigChanged = parts.vehicle.onFFBConfigChanged
M.onBeamNGTrigger = onBeamNGTrigger
M.onVehicleSwitched = onVehicleSwitched
M.onUpdate = onUpdate
M.onTeleportedToGarage = parts.recovery.onTeleportedToGarage
M.onUiChangedState = parts.recovery.onUiChangedState
M.onCareerActivated = onCareerActivated
M.onExtensionLoaded = onExtensionLoaded
M.onOverhaulSaveCurrentProfile = onOverhaulSaveCurrentProfile
M.onCareerDeactivatedWhileLevelLoaded = onCareerDeactivatedWhileLevelLoaded
M.onClientEndMission = onClientEndMission

return M
