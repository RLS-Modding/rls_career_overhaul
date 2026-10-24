-- Demolition derby staging, elimination, recovery and completion for one event load.
-- Read configuration/state, owned services, ordered staging/update phases, lifecycle and public hooks.
local vehicleCommands = require("overhaul/lib/vehicles/vehicleCommands")
local eventConfig = require("overhaul/events/derby/config")
local freConfig = require("overhaul/events/freConfig")
local capabilities = require("overhaul/lib/platform/capabilities")
local derbyUi = require("overhaul/events/derby/ui")
local freeroamUtils = require("overhaul/events/utils")
local stockOverrides = require("overhaul/lib/vehicles/stockVehicleOverrides")
local M = {}

-- Config ------------------------------------------------------------------------------------------

local constants = { CONFIG_FILENAME = "overhaul/demo.json" }
constants.MAX_DAMAGE_FOR_DISPLAY = 50000
constants.MAX_SELECTABLE_AI_OPPONENTS = 9
constants.DEFAULT_XP_OF_MONEY = 0.25

local DEFAULT_AI_PERSONALITIES = {
  aggressor = {
    weight = 0.40,
    playerTargetWeightBonus = 0.22,
    aggressionMultiplier = 1.20,
    retargetIntervalMultiplier = 0.80,
    dangerMargin = 8,
    safeMargin = 12,
    preferReverseChance = 0.20,
  },
  opportunist = {
    weight = 0.35,
    playerTargetWeightBonus = 0.00,
    aggressionMultiplier = 1.00,
    retargetIntervalMultiplier = 1.00,
    dangerMargin = 10,
    safeMargin = 14,
    preferReverseChance = 0.35,
  },
  survivor = {
    weight = 0.25,
    playerTargetWeightBonus = -0.18,
    aggressionMultiplier = 0.82,
    retargetIntervalMultiplier = 1.35,
    dangerMargin = 13,
    safeMargin = 18,
    preferReverseChance = 0.70,
  },
}

-- Elimination, no-contact and AI recovery tuning (seconds, metres, metres per second and weights).
local tuning = {
  STATIONARY_ELIMINATION_SECONDS = 30.0,
  STATIONARY_SPEED_THRESHOLD_MPS = 1.0,
  DEFAULT_NO_CONTACT_TIMEOUT_SECONDS = 30.0,
  DEFAULT_NO_CONTACT_WARNING_SECONDS = 10.0,
  NO_CONTACT_DAMAGE_THRESHOLD = 1.0,
  NO_CONTACT_DISTANCE_METERS = 8.0,
  NO_CONTACT_TOUCH_DISTANCE_METERS = 3.5,
  NO_CONTACT_TOUCH_REL_SPEED_MPS = 1.5,
  DERBY_DAMAGE_ATTRIBUTION_RADIUS_METERS = 10.0,
  DERBY_TIMEOUT_HEALTH_WEIGHT = 0.5,
  DERBY_TIMEOUT_DAMAGE_DEALT_WEIGHT = 0.5,
  AI_STATIONARY_RECOVERY_SECONDS = 2.5,
  AI_IMPACT_MAX_SPEED_MPS = 1.5,
  AI_IMPACT_MAX_DISTANCE_METERS = 8.0,
  AI_IMPACT_RETARGET_DELAY_SECONDS = 0.8,
  AI_DEADLOCK_CHECK_INTERVAL_SECONDS = 4.0,
  AI_DEADLOCK_MOVEMENT_METERS = 3.0,
}

local HUD_PUSH_INTERVAL = 0.25 -- push HUD state 4x/sec, not every frame

-- State -------------------------------------------------------------------------------------------

local derbyState = {}
derbyState.configData = nil
derbyState.sitesData = nil
derbyState.activeEvent = nil
derbyState.activeEventCfg = nil
derbyState.eventActive = false
derbyState.eventPhase = "idle"
derbyState.activeEntryModeKey = "loaner"
derbyState.activeEntryModeCfg = nil
derbyState.activeWinnerRepairInsurance = false
derbyState.stagedAiCount = 0
derbyState.spawnedAiIds = {}
derbyState.spawnedAiInfo = {} -- { [vehId] = { model = "moonhawk", index = 1 } }
derbyState.eliminatedIds = {} -- { [vehId] = { placement = N } }
derbyState.playerEliminated = false
derbyState.playerPlacement = nil
derbyState.totalParticipants = 0 -- AI + player
derbyState.nextPlacement = 0 -- counts down from totalParticipants
derbyState.eventElapsedTime = 0
derbyState.rewardsSettled = false
derbyState.lastRewardSummary = nil
derbyState.playerInventoryId = nil
derbyState.playerDerbyVehicleId = nil
derbyState.originalPlayerVehicleId = nil
derbyState.playerLoanerVehicleId = nil
derbyState.stagedPlayerTransform = nil -- captured when starting event from staging
derbyState.firstAiEliminationElapsed = nil
derbyState.eventFinishReason = nil
derbyState.noContactTimer = 0
derbyState.lastPlayerRawDamage = nil
derbyState.lastAiRawDamageById = {}
derbyState.stationaryTimers = {} -- { [vehId] = timeSpentStationary }

local derbyDamageScoring = {
  damageDealtById = {},
  lastRawDamageById = {},
  scoreDataById = {},
}

-- Resolved spatial data
derbyState.resolvedSpots = nil
derbyState.resolvedPlayZone = nil
derbyState.resolvedElimZones = nil

-- Zone debug drawing state
derbyState.drawZonesActive = false
derbyState.forceZoneDebugDraw = false
derbyState.forceZoneDebugEventKey = nil
derbyState.forceZoneDebugResolvedKey = nil
-- AI behavior state
derbyState.aiActivated = false -- whether AI chase behavior has been activated
derbyState.aiActivationDelay = 2.0 -- seconds after spawn before AI starts chasing
derbyState.aiActivationTimer = 0 -- countdown for activation
derbyState.trafficSuppressedForEvent = false
derbyState.countdownGeneration = 0
derbyState.derbyConfigTypePoolCache = nil
derbyState.derbyLevelId = nil
derbyState.derbyLevelReady = false
derbyState.derbyAvailable = false
derbyState.derbyArenaBarriersVisible = nil
derbyState.derbyArenaBarriersGroupName = nil

local hudPushAccum = 0

-- Helpers -----------------------------------------------------------------------------------------

local function _log(level, msg)
  log(level, "demolitionDerby", msg)
end

local function ordinal(n)
  if n % 100 >= 11 and n % 100 <= 13 then return n .. "th" end
  local d = n % 10
  if d == 1 then
    return n .. "st"
  elseif d == 2 then
    return n .. "nd"
  elseif d == 3 then
    return n .. "rd"
  else
    return n .. "th"
  end
end

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function parseConsoleBool(v)
  if type(v) == "boolean" then return v end
  if type(v) == "number" then return v ~= 0 end
  if type(v) == "string" then
    local s = tostring(v):lower()
    if s == "1" or s == "true" or s == "on" or s == "yes" then return true end
    if s == "0" or s == "false" or s == "off" or s == "no" then return false end
  end
  return nil
end

local function pushRewardMessage(msg, icon)
  if type(msg) == "string" and msg ~= "" then ui_message(msg, 8, "demoReward", icon or "check") end
end

local function saveCareerProgress(reason)
  if not overhaul_career_saveSystem then return end
  local ok, err = pcall(function()
    require("overhaul/lib/save/store").request("derby:saveCareerProgress")
  end)
  if not ok then
    _log(
      "W",
      "Failed to save derby career progress"
        .. (reason and (" after " .. tostring(reason)) or "")
        .. ": "
        .. tostring(err)
    )
  end
end

local function getElapsedEventTime()
  return derbyState.eventElapsedTime
end

local function resolveSessionInventoryFromSpawnId(subjectID)
  if not subjectID then return subjectID end
  local careerMode = overhaul_career_career.isActive()
  if careerMode then
    local businessVehicles = capabilities.get("businessVehicles")
    local businessId, vehicleId = businessVehicles.getBusinessVehicleFromSpawnedId(subjectID)
    if businessId and vehicleId then
      local jobId = businessVehicles.getJobIdFromVehicle(businessId, vehicleId)
      if jobId then return businessVehicles.getBusinessJobIdentifier(businessId, jobId) end
      return businessVehicles.getBusinessVehicleIdentifier(businessId, vehicleId)
    end
  end
  return careerMode and overhaul_career_garage_inventory.getInventoryIdFromVehicleId(subjectID) or subjectID
end

-- Parts -------------------------------------------------------------------------------------------

local derbyRewards = require("overhaul/events/derby/derby/derbyRewards").create({
  freConfig = freConfig,
  freeroamUtils = freeroamUtils,
  constants = constants,
  DEFAULT_AI_PERSONALITIES = DEFAULT_AI_PERSONALITIES,
  derbyState = derbyState,
  ordinal = ordinal,
  clamp = clamp,
  pushRewardMessage = pushRewardMessage,
  getElapsedEventTime = getElapsedEventTime,
})

local function resetAiRetargetTimer(info, vehicleId)
  info.retargetTimer = 0
  info.retargetInterval = derbyRewards.getAiRetargetInterval(vehicleId)
end

local derbyArena = require("overhaul/events/derby/derby/derbyArena").create({
  freeroamUtils = freeroamUtils,
  constants = constants,
  derbyState = derbyState,
  _log = _log,
})

local derbyParticipants = require("overhaul/events/derby/derby/derbyParticipants").create({
  derbyUi = derbyUi,
  freeroamUtils = freeroamUtils,
  stockOverrides = stockOverrides,
  constants = constants,
  derbyState = derbyState,
  derbyDamageScoring = derbyDamageScoring,
  tuning = tuning,
  _log = _log,
  derbyRewards = derbyRewards,
  derbyArena = derbyArena,
})

derbyUi.setDeps({
  derbyRewards = derbyRewards,
  derbyParticipants = derbyParticipants,
  derbyArena = derbyArena,
  getResolvedSpots = function()
    return derbyState.resolvedSpots
  end,
  setActiveEntryModeKey = function(modeKey)
    derbyState.activeEntryModeKey = modeKey
  end,
  getActiveEntryModeKey = function()
    return derbyState.activeEntryModeKey
  end,
  getFlowState = function()
    return derbyState.eventActive, derbyState.eventPhase, derbyParticipants.isAnotherActivityActive()
  end,
  getLoadedData = function()
    return derbyState.configData, derbyState.sitesData
  end,
  onStagingTeardownSpatial = function()
    derbyState.drawZonesActive = false
    derbyArena.clearSpatialData()
  end,
  ordinal = ordinal,
  getDerbyDamageScoring = function()
    return derbyDamageScoring
  end,
  getElapsedEventTime = getElapsedEventTime,
})

local derbyAi = require("overhaul/events/derby/derby/derbyAi").create({
  DEFAULT_AI_PERSONALITIES = DEFAULT_AI_PERSONALITIES,
  derbyState = derbyState,
  _log = _log,
  clamp = clamp,
  derbyRewards = derbyRewards,
  derbyArena = derbyArena,
  derbyParticipants = derbyParticipants,
})

local derbySession = require("overhaul/events/derby/derby/derbySession").create({
  derbyUi = derbyUi,
  derbyState = derbyState,
  derbyDamageScoring = derbyDamageScoring,
  _log = _log,
  saveCareerProgress = saveCareerProgress,
  getElapsedEventTime = getElapsedEventTime,
  resolveSessionInventoryFromSpawnId = resolveSessionInventoryFromSpawnId,
  derbyRewards = derbyRewards,
  derbyParticipants = derbyParticipants,
  derbyAi = derbyAi,
})

-- Event staging -----------------------------------------------------------------------------------

local function finishDerbyStaging(key, maxAi, spawned)
  saveCareerProgress("entry fee payment")
  _log("I", "Demo derby '" .. tostring(key) .. "' staged with " .. tostring(spawned) .. " AI.")

  derbyState.eventActive = false
  derbyState.eventPhase = "gridStaged"
  derbyArena.showDerbyArenaBarriers()
  derbyState.playerEliminated = false
  derbyState.playerPlacement = nil
  derbyState.totalParticipants = spawned + 1 -- AI + player
  derbyState.nextPlacement = derbyState.totalParticipants
  derbyState.eventElapsedTime = 0
  derbyState.rewardsSettled = false
  derbyState.stationaryTimers = {}
  derbyState.firstAiEliminationElapsed = nil
  derbyState.stagedAiCount = spawned
  derbyParticipants.resetNoContactState()
  derbyDamageScoring.reset()

  -- Start AI activation countdown
  derbyState.aiActivated = false
  derbyState.aiActivationDelay = eventConfig.value(derbyState.activeEventCfg, "aiActivationDelay")
  derbyState.aiActivationTimer = 0

  derbyAi.setPlayerFreeze(true)
  derbyUi.emitDemoStagingUi({
    visible = true,
    phase = "ready",
    maxAi = maxAi,
    aiCount = spawned,
    eventKey = key,
    label = derbyState.activeEventCfg.label or "Demolition Derby",
    selectedMode = derbyState.activeEntryModeKey,
    modeOptions = derbyRewards.buildModeOptions(derbyState.activeEventCfg, spawned),
    startEnabled = true,
    startDisabledReason = nil,
  })
end

local function prepareDerbyEventConfiguration(eventKey, modeKey, winnerRepairInsurance)
  derbyState.configData = derbyArena.loadConfigData()
  if not derbyState.configData then
    _log("W", "Cannot start demo event – no config data.")
    return
  end

  local key = eventKey
  if not key or not derbyState.configData.events or not derbyState.configData.events[key] then
    local keys = derbyArena.getAvailableEventKeys()
    key = keys[1]
  end
  if not key then
    _log("W", "No demo events defined in config.")
    return
  end

  derbyState.activeEvent = key
  derbyState.activeEventCfg = derbyArena.getEventConfig(key)
  if not derbyState.activeEventCfg then
    _log("W", "Could not resolve config for event: " .. tostring(key))
    return
  end
  derbyState.activeEntryModeKey, derbyState.activeEntryModeCfg =
    derbyRewards.getEntryModeConfig(derbyState.activeEventCfg, modeKey or "loaner")
  derbyState.activeWinnerRepairInsurance = winnerRepairInsurance == true
    and derbyRewards.isWinnerRepairInsuranceAvailable(derbyState.activeEventCfg, derbyState.activeEntryModeKey)

  derbyState.sitesData = derbyArena.loadSitesData(derbyState.activeEventCfg.sitesFile or derbyState.configData.sitesFile)
  if not derbyState.sitesData then
    _log("W", "Cannot start demo event – no sites data.")
    return
  end

  if derbyArena.resolveAllSpatialData(derbyState.activeEventCfg) == false then return end

  if not derbyState.resolvedSpots or #derbyState.resolvedSpots < 2 then
    _log("W", "Need at least 2 parking spots (player + AI).")
    return
  end
  if not derbyState.resolvedElimZones or #derbyState.resolvedElimZones == 0 then
    _log("W", "No elimination zones resolved for event: " .. tostring(key))
  end

  return key
end

local function resolveDerbyStartCount(requestedAiCount, key)
  local playerVehId = be:getPlayerVehicleID(0)
  local playerVehObj = playerVehId and be:getObjectByID(playerVehId) or nil
  if not (derbyState.activeEntryModeCfg and derbyState.activeEntryModeCfg.loaner == true) and not playerVehObj then
    _log("W", "Cannot start demo event – no player vehicle.")
    return
  end

  local availableAiSpots = math.max(0, #derbyState.resolvedSpots - 1)
  local maxAi = math.min(
    eventConfig.value(derbyState.activeEventCfg, "maxOpponents"),
    constants.MAX_SELECTABLE_AI_OPPONENTS,
    availableAiSpots
  )
  if maxAi < 1 then
    _log("W", "No parking spots available for AI opponents.")
    return
  end
  local count = tonumber(requestedAiCount) or 6
  count = math.max(1, math.min(count, maxAi))

  local canStart, startDisabledReason =
    derbyParticipants.getStagingStartAvailability(maxAi, derbyState.activeEntryModeKey)
  if not canStart then
    _log("I", "Demo derby start blocked: " .. tostring(startDisabledReason))
    derbyUi.emitDemoStagingUi({
      visible = true,
      phase = "configure",
      maxAi = maxAi,
      eventKey = key,
      label = derbyState.activeEventCfg.label or "Demolition Derby",
      selectedMode = derbyState.activeEntryModeKey,
      modeOptions = derbyRewards.buildModeOptions(derbyState.activeEventCfg, count),
      startEnabled = false,
      startDisabledReason = startDisabledReason,
    })
    return
  end

  return playerVehId, playerVehObj, count, maxAi
end

local function stageDerbyPlayerVehicle(key, playerVehId, playerVehObj)
  derbyState.originalPlayerVehicleId = playerVehObj and playerVehId or nil
  derbyState.playerInventoryId = derbyParticipants.getCurrentInventoryVehicleId()
  if playerVehObj then
    derbyAi.capturePlayerStagingTransform(playerVehObj)
  else
    derbyState.stagedPlayerTransform = nil
  end

  local playerSpotIndex = math.random(1, #derbyState.resolvedSpots)
  local playerSpot = derbyState.resolvedSpots[playerSpotIndex]
  if not (playerSpot and playerSpot.pos and playerSpot.rot) then
    _log("W", "Invalid player spawn parking spot for event: " .. tostring(key))
    derbyState.stagedPlayerTransform = nil
    return
  end

  derbyUi.hideStagingPopup()

  local playerSpawnPos = vec3(playerSpot.pos[1], playerSpot.pos[2], playerSpot.pos[3])
  local playerSpawnRot = quat(playerSpot.rot[1], playerSpot.rot[2], playerSpot.rot[3], playerSpot.rot[4])

  if derbyState.activeEntryModeCfg and derbyState.activeEntryModeCfg.loaner == true then
    if not derbySession.spawnPlayerLoaner(playerSpawnPos, playerSpawnRot) then
      derbyAi.restoreOriginalPlayerVehicle()
      derbyArena.clearSpatialData()
      derbyState.activeEvent = nil
      derbyState.activeEventCfg = nil
      derbyState.activeEntryModeCfg = nil
      derbyState.eventPhase = "idle"
      return
    end
  else
    derbyAi.teleportVehicleSafe(playerVehObj, playerSpawnPos, playerSpawnRot)
    derbyState.playerDerbyVehicleId = playerVehId
    derbyAi.setVehicleStopped(derbyState.playerDerbyVehicleId, false)
  end

  return playerSpotIndex
end

local function stageDerbyAiGridAndEntryFee(key, count, maxAi, playerSpotIndex)
  if derbyState.activeEventCfg.removeTraffic ~= false and gameplay_traffic then
    freeroamUtils.saveAndSetTrafficAmount(0)
    derbyState.trafficSuppressedForEvent = true
  else
    derbyState.trafficSuppressedForEvent = false
  end

  local spawned = derbyAi.spawnAi(count, playerSpotIndex)
  if spawned < 1 then
    _log("W", "Demo derby start aborted: failed to spawn AI.")
    derbyAi.restoreOriginalPlayerVehicle()
    derbyArena.restoreTrafficAfterEvent()
    derbyArena.clearSpatialData()
    derbyState.activeEvent = nil
    derbyState.activeEventCfg = nil
    derbyState.drawZonesActive = false
    return
  end

  if not derbySession.payEntryFee(derbyState.activeEntryModeCfg) then
    _log("I", "Demo derby start blocked: entry fee payment failed.")
    local failedLabel = derbyState.activeEventCfg and derbyState.activeEventCfg.label or "Demolition Derby"
    local failedOptions = derbyRewards.buildModeOptions(derbyState.activeEventCfg, count)
    derbyAi.restoreOriginalPlayerVehicle()
    derbySession.clearAllAi()
    derbyArena.restoreTrafficAfterEvent()
    derbyArena.clearSpatialData()
    derbyState.activeEvent = nil
    derbyState.activeEventCfg = nil
    derbyState.activeEntryModeCfg = nil
    derbyState.activeEntryModeKey = "loaner"
    derbyState.eventPhase = "idle"
    derbyUi.emitDemoStagingUi({
      visible = true,
      phase = "configure",
      maxAi = maxAi,
      eventKey = key,
      label = failedLabel,
      selectedMode = derbyState.activeEntryModeKey,
      modeOptions = failedOptions,
      startEnabled = false,
      startDisabledReason = "Not enough money for the entry fee.",
    })
    return
  end
  finishDerbyStaging(key, maxAi, spawned)
end

-- Zone debug draw ---------------------------------------------------------------------------------

local function setZoneDebugDrawOverride(enabled, eventKey)
  derbyState.forceZoneDebugDraw = enabled == true
  derbyState.forceZoneDebugResolvedKey = nil

  if derbyState.forceZoneDebugDraw then
    if type(eventKey) == "string" and eventKey ~= "" then derbyState.forceZoneDebugEventKey = eventKey end
  else
    derbyState.forceZoneDebugEventKey = nil
    if not derbyState.drawZonesActive and not derbyState.eventActive and not derbyUi.isStagingShown() then
      derbyArena.clearSpatialData()
    end
  end

  _log(
    "I",
    "Zone debug draw "
      .. (derbyState.forceZoneDebugDraw and "enabled" or "disabled")
      .. (derbyState.forceZoneDebugEventKey and (" for " .. derbyState.forceZoneDebugEventKey) or "")
  )

  return derbyState.forceZoneDebugDraw
end

-- Per-frame update --------------------------------------------------------------------------------

local function finishDerbyAtTimeLimit()
  local timeLimit = eventConfig.value(derbyState.activeEventCfg, "timeLimitSeconds")
  if timeLimit > 0 and getElapsedEventTime() >= timeLimit then
    local survivors = {}
    if not derbyState.playerEliminated then
      table.insert(survivors, derbyDamageScoring.buildTimeoutSurvivorRow(derbyState.playerDerbyVehicleId, true))
    end
    for _, vehId in ipairs(derbyState.spawnedAiIds) do
      if not derbyState.eliminatedIds[vehId] then
        table.insert(survivors, derbyDamageScoring.buildTimeoutSurvivorRow(vehId, false))
      end
    end
    derbyDamageScoring.scoreTimeoutSurvivors(survivors)
    table.sort(survivors, function(left, right)
      if left.derbyScore ~= right.derbyScore then return left.derbyScore > right.derbyScore end
      if left.damageDealt ~= right.damageDealt then return left.damageDealt > right.damageDealt end
      if left.damagePct ~= right.damagePct then return left.damagePct < right.damagePct end
      return tostring(left.id) < tostring(right.id)
    end)
    for i, row in ipairs(survivors) do
      if row.isPlayer then
        derbyState.playerPlacement = i
      else
        derbyState.eliminatedIds[row.id] = {
          placement = i,
          timedOutSurvivor = true,
          damagePct = row.damagePct,
          derbyScore = row.derbyScore,
          healthScore = row.healthScore,
          damageDealt = row.damageDealt,
          damageDealtScore = row.damageDealtScore,
        }
      end
    end
    local playerWasEliminated = derbyState.playerEliminated == true
    M.endEvent(playerWasEliminated, derbyState.playerPlacement or derbyState.totalParticipants, "time_limit")
    return true
  end
end

local function updateDerbyAiEliminations(dtSim)
  local anyEliminated = false
  for _, vehId in ipairs(derbyState.spawnedAiIds) do
    if not derbyState.eliminatedIds[vehId] then
      local pos = derbyParticipants.getVehiclePos(vehId)
      local isEliminated = false
      local damagePct = derbyParticipants.getVehicleDamageNormalized(vehId, false)

      if damagePct >= 100 then
        isEliminated = true
        _log("I", "AI " .. tostring(vehId) .. " eliminated due to 100% damage.")
      elseif pos then
        if derbyArena.isInsideAnyEliminationZone(pos) then
          isEliminated = true
        else
          local vehObj = be:getObjectByID(vehId)
          if vehObj then
            local speed = vehObj:getVelocity():length()
            if speed < tuning.STATIONARY_SPEED_THRESHOLD_MPS then
              derbyState.stationaryTimers[vehId] = (derbyState.stationaryTimers[vehId] or 0) + dtSim
              if derbyState.stationaryTimers[vehId] >= tuning.STATIONARY_ELIMINATION_SECONDS then
                isEliminated = true
                _log("I", "AI " .. tostring(vehId) .. " eliminated due to being stationary.")
              end
            else
              derbyState.stationaryTimers[vehId] = 0
            end
          end
        end
      end

      if isEliminated then
        local placement = derbyState.nextPlacement
        derbyState.nextPlacement = derbyState.nextPlacement - 1
        if not derbyState.firstAiEliminationElapsed then
          derbyState.firstAiEliminationElapsed = getElapsedEventTime()
        end
        derbyState.eliminatedIds[vehId] = { placement = placement }
        anyEliminated = true
        local info = derbyState.spawnedAiInfo[vehId] or {}
        local elimLabel = "AI #" .. tostring(info.index or "?") .. " (" .. tostring(info.model or "?") .. ")"
        _log("I", elimLabel .. " eliminated! Placed " .. ordinal(placement))
        -- Send toast notification to UI
        derbyUi.showEliminationToast({
          label = elimLabel,
          placement = placement,
          placementStr = ordinal(placement),
        })
        derbyAi.setVehicleStopped(vehId, true)
      end
    end
  end
  return anyEliminated
end

local function eliminateDerbyPlayerForExitOrNoContact(dtSim, currentPlayerVehId, isWalking)
  local exitedEventVehicle = not currentPlayerVehId
    or isWalking
    or (derbyState.playerDerbyVehicleId and currentPlayerVehId ~= derbyState.playerDerbyVehicleId)
  if exitedEventVehicle then
    derbyState.playerEliminated = true
    local placement = derbyState.nextPlacement
    derbyState.nextPlacement = derbyState.nextPlacement - 1
    derbyState.playerPlacement = placement
    derbyUi.clearDerbyCountdownWarnings()
    _log(
      "I",
      "Player eliminated from demo derby for exiting vehicle mid-event. startVeh="
        .. tostring(derbyState.playerDerbyVehicleId)
        .. " currentVeh="
        .. tostring(currentPlayerVehId)
        .. " walking="
        .. tostring(isWalking)
    )
    derbyAi.setVehicleStopped(derbyState.playerDerbyVehicleId, true)
    M.endEvent(true, placement, "exited_vehicle")
    return true
  end

  local playerVehId = currentPlayerVehId

  if derbyParticipants.updateNoContactTimer(dtSim) then
    derbyState.playerEliminated = true
    local placement = derbyState.nextPlacement
    derbyState.nextPlacement = derbyState.nextPlacement - 1
    derbyState.playerPlacement = placement
    derbyUi.clearDerbyCountdownWarnings()
    ui_message("No contact! You have been eliminated.", 3, "demoNoContact", "warning")
    _log("I", "Player eliminated from demo derby due to no contact timeout.")
    derbyAi.setVehicleStopped(playerVehId, true)
    M.endEvent(true, placement, "no_contact")
    return true
  end
end

local function derbyPlayerEliminationReason(playerVehId, dtSim)
  local ppos = derbyParticipants.getVehiclePos(playerVehId)
  local isEliminated = false
  local elimReason = "out_of_bounds"
  local damagePct = derbyParticipants.getVehicleDamageNormalized(playerVehId, true)

  if damagePct >= 100 then
    isEliminated = true
    elimReason = "destroyed"
    derbyUi.clearStationaryWarning()
    _log("I", "Player eliminated due to 100% damage.")
  elseif ppos then
    if derbyArena.isInsideAnyEliminationZone(ppos) then
      isEliminated = true
    else
      local vehObj = be:getObjectByID(playerVehId)
      if vehObj then
        local speed = vehObj:getVelocity():length()
        if speed < tuning.STATIONARY_SPEED_THRESHOLD_MPS then
          derbyState.stationaryTimers[playerVehId] = (derbyState.stationaryTimers[playerVehId] or 0) + dtSim
          if derbyState.stationaryTimers[playerVehId] >= tuning.STATIONARY_ELIMINATION_SECONDS then
            isEliminated = true
            elimReason = "stationary"
            derbyUi.clearStationaryWarning()
            _log("I", "Player eliminated due to being stationary.")
          else
            local timeLeft = tuning.STATIONARY_ELIMINATION_SECONDS - derbyState.stationaryTimers[playerVehId]
            if timeLeft <= 10 and timeLeft > 0 then derbyUi.showStationaryWarning(timeLeft) end
          end
        else
          derbyUi.clearStationaryWarning()
          derbyState.stationaryTimers[playerVehId] = 0
        end
      end
    end
  end

  return isEliminated, elimReason
end

local function updateDerbyPlayerElimination(dtSim)
  local canElimPlayer = not derbyState.activeEventCfg or derbyState.activeEventCfg.playerCanBeEliminated ~= false
  if not canElimPlayer or derbyState.playerEliminated then return end
  local currentPlayerVehId = be:getPlayerVehicleID(0)
  local isWalking = gameplay_walk and gameplay_walk.isWalking() or false
  if eliminateDerbyPlayerForExitOrNoContact(dtSim, currentPlayerVehId, isWalking) then return true end
  local playerVehId = currentPlayerVehId
  local isEliminated, elimReason = derbyPlayerEliminationReason(playerVehId, dtSim)
  if isEliminated then
    derbyState.playerEliminated = true
    local placement = derbyState.nextPlacement
    derbyState.nextPlacement = derbyState.nextPlacement - 1
    derbyState.playerPlacement = placement
    _log("I", "Player eliminated from demo derby! Placed " .. ordinal(placement))
    derbyAi.setVehicleStopped(playerVehId, true)
    M.endEvent(true, placement, elimReason)
    return true
  end
end

local function reacquireDerbyAiTarget(vehId, info)
  if not derbyAi.isValidTargetForAi(vehId, info.targetId) then
    info.targetId = derbyAi.pickTargetForAi(vehId, false)
    if info.targetId then
      derbyAi.setAiChaseTarget(vehId, info.targetId)
      resetAiRetargetTimer(info, vehId)
    end
  end
end

local function recoverStationaryDerbyAi(vehId, vehObj, info, pos, speed, dtSim)
  if speed < tuning.STATIONARY_SPEED_THRESHOLD_MPS then
    info.stationaryTimer = (info.stationaryTimer or 0) + dtSim
    if info.stationaryTimer >= tuning.AI_STATIONARY_RECOVERY_SECONDS then
      local previousTargetId = info.targetId
      local forcedTarget = derbyAi.pickNearestTargetForAi(vehId, previousTargetId)
        or derbyAi.pickTargetForAi(vehId, false, previousTargetId)
        or derbyAi.getSafestTargetId(vehId)
      info.targetId = forcedTarget
      if forcedTarget then
        vehObj:queueLuaCommand("input.event('parkingbrake', 0, 1)")
        vehicleCommands.queue(vehObj, "ai", "setTargetObjectID", tonumber(tostring(forcedTarget)))
        vehObj:queueLuaCommand("if ai.beginDerbyRecovery then ai.beginDerbyRecovery('stationary') end")
        resetAiRetargetTimer(info, vehId)
        info.stuckTimer = 0
        info.impactTimer = 0
        info.lastPos = vec3(pos.x, pos.y, pos.z)
      end
      info.stationaryTimer = 0
    end
  else
    info.stationaryTimer = 0
  end
end

local function retargetTimedDerbyAi(vehId, info, dtSim)
  info.retargetTimer = (info.retargetTimer or 0) + dtSim
  if
    info.retargetTimer >= (info.retargetInterval or derbyRewards.getAiRetargetInterval(vehId))
    and info.combatState ~= "recovery"
  then
    resetAiRetargetTimer(info, vehId)
    local previousTargetId = info.targetId
    info.targetId = derbyAi.pickNearestTargetForAi(vehId, previousTargetId)
      or derbyAi.pickTargetForAi(vehId, false, previousTargetId)
      or derbyAi.pickTargetForAi(vehId, false)
    derbyAi.setAiChaseTarget(vehId, info.targetId)
  end
end

local function recoverBoundaryDerbyAi(vehId, vehObj, info, personality, inPlayZone, distToEdge)
  local dangerMargin = tonumber(personality and personality.dangerMargin) or 10.0
  local safeMargin = tonumber(personality and personality.safeMargin) or 14.0

  local inDangerZone = (not inPlayZone) or (distToEdge < dangerMargin)
  local isSafe = inPlayZone and (distToEdge >= safeMargin)

  if inDangerZone and info.combatState ~= "recovery" then
    info.combatState = "recovery"
    local safeId = derbyAi.getSafestTargetId(vehId)
    if safeId then
      info.targetId = safeId
      if info.activeMode ~= "demoderby" then
        vehObj:queueLuaCommand("ai.setMode('demoderby')")
        info.activeMode = "demoderby"
      end
      vehicleCommands.queue(vehObj, "ai", "setTargetObjectID", tonumber(tostring(safeId)))
      _log(
        "I",
        "AI "
          .. tostring(vehId)
          .. " entered prohibited boundary zone, recovering by chasing target "
          .. tostring(safeId)
      )
    end
  elseif isSafe and info.combatState == "recovery" then
    info.combatState = info.driveMode
    info.stuckTimer = 0
    info.targetId = derbyAi.pickNearestTargetForAi(vehId) or derbyAi.pickTargetForAi(vehId, false)
    derbyAi.setAiChaseTarget(vehId, info.targetId)
    resetAiRetargetTimer(info, vehId)
  end
end

local function retargetAfterDerbyImpact(vehId, vehObj, info, pos, speed, distToTarget, dtSim)
  if speed < tuning.AI_IMPACT_MAX_SPEED_MPS and distToTarget < tuning.AI_IMPACT_MAX_DISTANCE_METERS then
    info.impactTimer = (info.impactTimer or 0) + dtSim
    if info.impactTimer >= tuning.AI_IMPACT_RETARGET_DELAY_SECONDS then
      info.impactTimer = 0
      local newTargetId = derbyAi.pickNearestTargetForAi(vehId, info.targetId)
        or derbyAi.pickTargetForAi(vehId, false, info.targetId)
        or derbyAi.pickTargetForAi(vehId, false)
      info.stuckTimer = 0
      resetAiRetargetTimer(info, vehId)
      info.lastPos = vec3(pos.x, pos.y, pos.z)
      if newTargetId then
        info.targetId = newTargetId
        vehicleCommands.queue(vehObj, "ai", "setTargetObjectID", tonumber(tostring(newTargetId)))
      end
    end
  else
    info.impactTimer = 0
  end
end

local function recoverDeadlockedDerbyAi(vehId, vehObj, info, pos, dtSim)
  info.stuckTimer = info.stuckTimer + dtSim
  if not info.lastPos then info.lastPos = vec3(pos.x, pos.y, pos.z) end

  if info.stuckTimer >= tuning.AI_DEADLOCK_CHECK_INTERVAL_SECONDS then
    local distTraveled = (pos - info.lastPos):length()
    if distTraveled < tuning.AI_DEADLOCK_MOVEMENT_METERS then
      local newTargetId = derbyAi.pickNearestTargetForAi(vehId, info.targetId)
        or derbyAi.pickTargetForAi(vehId, false, info.targetId)
        or derbyAi.pickTargetForAi(vehId, false)
      if newTargetId then
        info.targetId = newTargetId
        vehObj:queueLuaCommand("input.event('parkingbrake', 0, 1)")
        vehicleCommands.queue(vehObj, "ai", "setTargetObjectID", tonumber(tostring(newTargetId)))
        vehObj:queueLuaCommand("if ai.beginDerbyRecovery then ai.beginDerbyRecovery('deadlock') end")
        resetAiRetargetTimer(info, vehId)
      end
    elseif info.targetId then
      vehicleCommands.queue(vehObj, "ai", "setTargetObjectID", tonumber(tostring(info.targetId)))
    end
    info.stuckTimer = 0
    info.lastPos = vec3(pos.x, pos.y, pos.z)
  end
end

local function updateDerbyRecoveryVehicle(vehId, dtSim)
  if derbyState.eliminatedIds[vehId] then return end
  local vehObj = be:getObjectByID(vehId)
  local info = derbyState.spawnedAiInfo[vehId]
  if not vehObj or not info then return end
  reacquireDerbyAiTarget(vehId, info)

  local pos = vehObj:getPosition()
  local speed = vehObj:getVelocity():length()
  local personality = derbyRewards.getAiPersonality(vehId)
  local inPlayZone = derbyArena.isInsidePlayZone(pos)
  local distToEdge = derbyArena.getDistanceToPlayZoneEdge(pos)
  recoverStationaryDerbyAi(vehId, vehObj, info, pos, speed, dtSim)
  if not info.targetId then return end

  retargetTimedDerbyAi(vehId, info, dtSim)
  recoverBoundaryDerbyAi(vehId, vehObj, info, personality, inPlayZone, distToEdge)
  local isAttacking = info.combatState == "demoderby" or info.combatState == "demoderby_reverse"
  if not isAttacking then return end
  local targetObj = be:getObjectByID(info.targetId)
  local distToTarget = math.huge
  if targetObj then distToTarget = (pos - targetObj:getPosition()):length() end
  retargetAfterDerbyImpact(vehId, vehObj, info, pos, speed, distToTarget, dtSim)
  recoverDeadlockedDerbyAi(vehId, vehObj, info, pos, dtSim)
end

local function updateDerbyAiRecovery(dtSim)
  if not derbyState.aiActivated then return end
  for _, vehId in ipairs(derbyState.spawnedAiIds) do updateDerbyRecoveryVehicle(vehId, dtSim) end
end

-- Ticked by freeroamEvents once per frame with the sim delta; not an engine hook.
function M.update(dt)
  local dtSim = tonumber(dt) or 0

  -- Always draw debug zones when active (immediate mode, must draw every frame)
  derbyParticipants.drawDebugZones()

  if derbyState.eventPhase ~= "running" then
    if not derbyArena.refreshDerbyForCurrentLevel() then return end
    if derbyState.eventPhase == "idle" or derbyState.eventPhase == "configure" then
      derbyUi.updateStagingPopupFromStartSpots()
    end
    return
  end

  derbyDamageScoring.update()

  derbyState.eventElapsedTime = derbyState.eventElapsedTime + dtSim

  if finishDerbyAtTimeLimit() then return end

  local anyEliminated = updateDerbyAiEliminations(dtSim)

  if updateDerbyPlayerElimination(dtSim) then return end

  local allGone = true
  for _, vehId in ipairs(derbyState.spawnedAiIds) do
    if not derbyState.eliminatedIds[vehId] then
      allGone = false
      break
    end
  end
  if allGone and #derbyState.spawnedAiIds > 0 then
    derbyState.playerPlacement = 1
    M.endEvent(false, 1)
    return
  end

  -- AI activation (delayed start)
  if not derbyState.aiActivated then
    derbyState.aiActivationTimer = derbyState.aiActivationTimer - dtSim
    if derbyState.aiActivationTimer <= 0 then derbySession.activateAllAi() end
  end

  updateDerbyAiRecovery(dtSim)

  -- Throttled HUD update
  hudPushAccum = hudPushAccum + dtSim
  if anyEliminated or hudPushAccum >= HUD_PUSH_INTERVAL then
    hudPushAccum = 0
    derbyUi.pushDemoHudState()
  end
end

-- Public API --------------------------------------------------------------------------------------

function M.startEvent(requestedAiCount, eventKey, modeKey, winnerRepairInsurance)
  if derbyState.eventPhase ~= "idle" and derbyState.eventPhase ~= "configure" then return end
  local key = prepareDerbyEventConfiguration(eventKey, modeKey, winnerRepairInsurance)
  if not key then return end
  local playerVehId, playerVehObj, count, maxAi = resolveDerbyStartCount(requestedAiCount, key)
  if not count then return end
  local playerSpotIndex = stageDerbyPlayerVehicle(key, playerVehId, playerVehObj)
  if not playerSpotIndex then return end
  stageDerbyAiGridAndEntryFee(key, count, maxAi, playerSpotIndex)
end

function M.beginCountdown()
  if derbyState.eventPhase ~= "gridStaged" then return false end
  derbyState.eventPhase = "countdown"
  derbyUi.hideStagingPopup()
  derbyAi.setPlayerFreeze(true)
  derbyUi.resetScenarioFlash()
  derbyState.countdownGeneration = derbyState.countdownGeneration + 1
  local myCountdownGeneration = derbyState.countdownGeneration

  core_jobsystem.create(function(job)
    derbyUi.triggerScenarioFlash({
      { 3, 1, "Engine.Audio.playOnce('AudioGui', 'event:UI_Countdown1')", true },
      { 2, 1, "Engine.Audio.playOnce('AudioGui', 'event:UI_Countdown2')", true },
      { 1, 1, "Engine.Audio.playOnce('AudioGui', 'event:UI_Countdown3')", true },
    })
    job.sleep(3)
    if myCountdownGeneration ~= derbyState.countdownGeneration then return end
    if derbyState.eventPhase ~= "countdown" then
      derbyAi.setPlayerFreeze(false)
      return
    end
    derbyUi.resetScenarioFlash()
    derbyUi.triggerScenarioFlash({
      { "ui.scenarios.go", 1, "Engine.Audio.playOnce('AudioGui', 'event:UI_CountdownGo')", true },
    })
    derbyAi.setPlayerFreeze(false)
    if derbyState.playerDerbyVehicleId then
      local playerObj = be:getObjectByID(derbyState.playerDerbyVehicleId)
      if playerObj then
        playerObj:queueLuaCommand("input.event('parkingbrake', 0, 1)")
        playerObj:queueLuaCommand("input.event('brake', 0, 1)")
        playerObj:queueLuaCommand(
          "if electrics and electrics.setIgnitionLevel then electrics.setIgnitionLevel(3) end; if controller.mainController then controller.mainController.setStarter(true) end"
        )
      end
    end
    derbyState.eventElapsedTime = 0
    derbyParticipants.resetNoContactState()
    derbyDamageScoring.reset()
    derbyState.eventActive = true
    derbyState.eventPhase = "running"
    derbyState.aiActivationTimer = 0
    derbySession.activateAllAi()
    derbyUi.showDemoHud()
  end)
  return true
end

function M.endEvent(playerWasEliminated, playerPlace, eliminationReason)
  if derbyState.eventPhase ~= "running" then return end
  derbyState.eventActive = false
  derbyState.eventPhase = "results"
  derbyState.drawZonesActive = false
  derbyState.eventFinishReason = eliminationReason or "completed"
  derbyUi.clearDerbyCountdownWarnings()

  derbySession.recordDerbyStats(playerWasEliminated, playerPlace)

  local rewardSummary = derbyRewards.settleCareerRewards(playerWasEliminated, playerPlace, eliminationReason)

  local playerWon = tonumber(playerPlace) == 1 and playerWasEliminated ~= true
  local repairQueued = false
  if playerWon then
    repairQueued = derbySession.repairWinningOwnCar()
    if not repairQueued then derbySession.persistOwnCarDamage() end
  else
    derbySession.persistOwnCarDamage()
  end
  if not repairQueued then saveCareerProgress("event finish") end

  derbyUi.hideDemoHud()
  derbyUi.showCongratulations(playerWasEliminated, playerPlace, eliminationReason, rewardSummary)
end

function M.cancelStaging()
  derbyUi.markStagingDismissed(derbyUi.getActiveStagingEventKey())
  derbyUi.hideStagingPopup()
  derbyUi.clearDerbyCountdownWarnings()
  derbyUi.hideDemoHud()
  if derbyState.eventPhase == "gridStaged" or derbyState.eventPhase == "countdown" then
    derbyState.eventPhase = "cleanup"
    derbyAi.setPlayerFreeze(false)
    derbyUi.resetScenarioFlash()
    derbyAi.restoreOriginalPlayerVehicle()
    derbySession.clearAllAi()
    derbyArena.restoreTrafficAfterEvent()
    derbyState.activeEvent = nil
    derbyState.activeEventCfg = nil
    derbyState.activeEntryModeCfg = nil
    derbyState.activeEntryModeKey = "loaner"
    derbyState.activeWinnerRepairInsurance = false
    derbyState.eventPhase = "idle"
  end
  derbyState.drawZonesActive = false
  derbyArena.clearSpatialData()
  derbyState.stagedPlayerTransform = nil
  derbyState.activeWinnerRepairInsurance = false
  derbyArena.hideDerbyArenaBarriers()
end

function M.dismissCongratulations()
  derbyUi.hideCongratulations()
  if derbyState.eventPhase == "results" then
    derbyState.eventPhase = "cleanup"
    derbyAi.setPlayerFreeze(false)
    if derbyState.activeEntryModeCfg and derbyState.activeEntryModeCfg.loaner == true then
      derbyAi.restoreOriginalPlayerVehicle()
    else
      derbyAi.restorePlayerToStagingTransform()
    end
    derbySession.clearAllAi()
    derbyArena.restoreTrafficAfterEvent()
    derbyArena.clearSpatialData()
    derbyState.activeEvent = nil
    derbyState.activeEventCfg = nil
    derbyState.activeEntryModeCfg = nil
    derbyState.activeEntryModeKey = "loaner"
    derbyState.activeWinnerRepairInsurance = false
    derbyState.eventPhase = "idle"
    saveCareerProgress("post-event cleanup")
  end
  derbyArena.hideDerbyArenaBarriers()
end

function M.refreshStagingAvailability(modeKey, aiCount, winnerRepairInsurance)
  derbyUi.refreshStagingAvailability(modeKey, aiCount, winnerRepairInsurance)
end

function M.setZoneDebugDrawEnabled(enabled, eventKey)
  local parsed = parseConsoleBool(enabled)
  if parsed == nil then
    _log("W", "setZoneDebugDrawEnabled expects true/false, on/off, or 1/0")
    return derbyState.forceZoneDebugDraw
  end
  return setZoneDebugDrawOverride(parsed, eventKey)
end

function M.toggleZoneDebugDraw(eventKey)
  return setZoneDebugDrawOverride(not derbyState.forceZoneDebugDraw, eventKey)
end

function M.getZoneDebugDrawState()
  return {
    enabled = derbyState.forceZoneDebugDraw,
    eventKey = derbyState.forceZoneDebugEventKey,
    activeEvent = derbyState.activeEvent,
    stagingEventKey = derbyUi.getActiveStagingEventKey(),
  }
end

M.setDebugZonesEnabled = M.setZoneDebugDrawEnabled
M.toggleDebugZones = M.toggleZoneDebugDraw

function M.isRecoveryRadialOverrideActive()
  return derbyState.eventPhase == "gridStaged"
    or derbyState.eventPhase == "countdown"
    or derbyState.eventPhase == "running"
    or derbyState.eventPhase == "results"
end

function M.ownsRaceHud()
  return derbyState.eventActive == true and derbyState.eventPhase == "running"
end

function M.dismissDemoIntro(dontShowAgain, eventKey)
  eventKey = eventKey or derbyUi.getActiveStagingEventKey()
  if not eventKey then return end
  derbyUi.dismissIntroAndShowConfigure(dontShowAgain, eventKey)
end

function M.getAvailableEventKeys()
  if not derbyArena.refreshDerbyForCurrentLevel() then return {} end
  return derbyArena.getAvailableEventKeys()
end

function M.getEventLocation(eventKey)
  if not derbyArena.refreshDerbyForCurrentLevel() then return nil end
  return derbyArena.getEventLocation(eventKey)
end

function M.refreshDerbyVehiclePools()
  derbyState.derbyConfigTypePoolCache = nil
  return true
end

function M.hardResetForCareerChange()
  derbyState.countdownGeneration = derbyState.countdownGeneration + 1
  derbyArena.restoreTrafficAfterEvent()
  derbyArena.clearSpatialData()
  derbyState.activeEvent = nil
  derbyState.activeEventCfg = nil
  derbyState.activeEntryModeCfg = nil
  derbySession.clearAllAi()
  derbyState.drawZonesActive = false
  derbyUi.shutdownAll()
  derbyState.eventActive = false
  derbyState.eventPhase = "idle"
  derbyState.playerEliminated = false
  derbyArena.hideDerbyArenaBarriers()
end

-- Game hooks --------------------------------------------------------------------------------------

-- Retarget when vehicle-side recovery starts so it does not resume chasing the same blocker.
function M.onAiRecoveryRequest(aiVehId)
  if not derbyState.eventActive or not derbyState.aiActivated or derbyState.eliminatedIds[aiVehId] then return end
  local info = derbyState.spawnedAiInfo[aiVehId]
  local vehObj = be:getObjectByID(aiVehId)
  if not info or not vehObj then return end

  local previousTargetId = info.targetId
  local newTargetId = derbyAi.pickNearestTargetForAi(aiVehId, previousTargetId)
    or derbyAi.pickTargetForAi(aiVehId, false, previousTargetId)
    or derbyAi.pickTargetForAi(aiVehId, false)
  if newTargetId then
    info.targetId = newTargetId
    resetAiRetargetTimer(info, aiVehId)
    info.stuckTimer = 0
    info.impactTimer = 0
    info.lastPos = vec3(vehObj:getPosition())
    vehicleCommands.queue(vehObj, "ai", "setTargetObjectID", tonumber(tostring(newTargetId)))
  end
end

function M.onStagingTrigger(_, event, demoEventKey)
  if not demoEventKey or demoEventKey == "" then return end
  if event == "enter" then
    derbyUi.handleMarkerStagingEnter(demoEventKey, {
      eventActive = derbyState.eventActive,
      isAnotherActivityActive = derbyParticipants.isAnotherActivityActive(),
      ensureConfigLoaded = function()
        return derbyParticipants.ensureConfigAndSites()
      end,
    })
  elseif event == "exit" then
    derbyUi.onMarkerStagingExit(demoEventKey)
  end
end

function M.onOverhaulModulesActivated()
  derbyUi.onOverhaulModulesActivated()
end

function M.onExtensionLoaded()
  derbyState.derbyConfigTypePoolCache = nil
  derbyState.derbyLevelId = nil
  derbyState.derbyLevelReady = false
  derbyArena.refreshDerbyForCurrentLevel()
end

function M.onWorldReadyState(state)
  if state ~= 2 then return end
  derbyState.derbyLevelId = nil
  derbyState.derbyLevelReady = false
  derbyState.derbyArenaBarriersVisible = nil
  if derbyState.eventPhase == "idle" or derbyState.eventPhase == "configure" then
    derbyState.configData = nil
    derbyState.sitesData = nil
  end
  derbyArena.refreshDerbyForCurrentLevel()
end

function M.onExtensionUnloaded()
  if derbyState.activeEntryModeCfg and derbyState.activeEntryModeCfg.loaner == true then
    derbyAi.restoreOriginalPlayerVehicle()
  else
    derbyAi.restorePlayerToStagingTransform()
  end
  derbyArena.restoreTrafficAfterEvent()
  derbyArena.clearSpatialData()
  derbyState.activeEvent = nil
  derbyState.activeEventCfg = nil
  derbySession.clearAllAi()

  derbyState.drawZonesActive = false
  derbyUi.shutdownAll()
  derbyState.eventActive = false
  derbyState.eventPhase = "idle"
  derbyArena.hideDerbyArenaBarriers()
end

-- AI cars and the loaner must be gone before a Lua reload serializes stock checkpoints and traffic.
require("overhaul/lib/vehicles/temporary").declare("derby", M.onExtensionUnloaded)

M.activity = require("overhaul/events/derby/derby/derbyActivity")(M)

return M
