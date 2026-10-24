-- Tractor-pull sled setup, distance/timer tracking, rewards and result presentation.
-- Read configuration/state, reward/finish operations, sled setup, frame tracking and public hooks.
local pullingConfig = require("overhaul/lib/events/pullingConfig")
local jsonCatalog = require("overhaul/lib/platform/jsonCatalog")
local M = {}

-- Config --------------------------------------------------------------------------------------------

local LOG_TAG = "tractorPull"
local CONFIG_FILENAME = "overhaul/pulling.json"
local METERS_TO_FEET = 3.280839895

-- State -------------------------------------------------------------------------------------------

local phase = "idle"
local levelId
local config
local configValues
local sites
local stagingSpot
local spawnSpot
local venues = {}
local fullDistance = 0
local stationaryTime = 0
local spawnWaitTime = 0
local elapsedTime = 0
local noProgressTime = 0
local progressCheckpointDistance = 0
local selectedSled
local selectedHitch
local sledVehicleId
local playerVehicleId
local sledStartPos
local lastSledFlatPos
local maxDistance = 0
local hudAccumulator = 0
local resultData

-- Sled configuration and selector -------------------------------------------------------------------

local function logMessage(level, message)
  log(level, LOG_TAG, message)
end

local function clamp(value, low, high)
  return math.max(low, math.min(high, value))
end

local function arrayToVec(value)
  if type(value) ~= "table" then return nil end
  local x, y, z = tonumber(value[1]), tonumber(value[2]), tonumber(value[3])
  if not jsonCatalog.finite(x) or not jsonCatalog.finite(y) or not jsonCatalog.finite(z) then return nil end
  return vec3(x, y, z)
end

local function arrayToQuat(value)
  if type(value) ~= "table" then return nil end
  local x, y, z, w = tonumber(value[1]), tonumber(value[2]), tonumber(value[3]), tonumber(value[4])
  if not x or not y or not z or not w then return nil end
  return quat(x, y, z, w)
end

local function findParkingSpot(name, source)
  for _, spot in ipairs(type(source) == "table" and source.parkingSpots or {}) do
    if spot.name == name then return spot end
  end
  return nil
end

local function sledById(id)
  for _, sled in ipairs(type(config) == "table" and config.sleds or {}) do
    if sled.id == id then return sled end
  end
  return nil
end

local function hitchById(id)
  for _, hitch in ipairs(type(config) == "table" and config.hitches or {}) do
    if hitch.id == id then return hitch end
  end
  return nil
end

local levelDataFailedFor = nil

local function activateVenue(venue)
  config, configValues, sites = venue.config, venue.values, venue.sites
  stagingSpot, spawnSpot = venue.stagingSpot, venue.spawnSpot
  fullDistance = configValues.fullPullDistanceMeters
end

local function configuredVenue(definition)
  local values = pullingConfig.normalize(definition)
  if not values.eventId or not values.sitesFile or not values.stagingSpot or not values.spawnSpot then
    logMessage("W", "Pulling venue unavailable: eventId, sitesFile, stagingSpot and spawnSpot are required")
    return nil
  end
  local source = jsonReadFile("levels/" .. levelId .. "/" .. values.sitesFile)
  local staging, spawn = findParkingSpot(values.stagingSpot, source), findParkingSpot(values.spawnSpot, source)
  local stagingPos, spawnPos = staging and arrayToVec(staging.pos), spawn and arrayToVec(spawn.pos)
  if not stagingPos or not spawnPos or values.fullPullDistanceMeters <= 1 then
    logMessage("W", "Pulling venue unavailable: invalid sites roles or pull distance for " .. values.eventId)
    return nil
  end
  return {config=definition, values=values, sites=source, stagingSpot=staging, spawnSpot=spawn, stagingPos=stagingPos}
end

local function loadLevelData()
  local current = getCurrentLevelIdentifier()
  if not current and not levelId then return false end
  if current == levelId and config and sites then return true end
  if current ~= nil and current == levelDataFailedFor then return false end

  levelId = current
  config, configValues, sites = nil, nil, nil
  venues = {}
  stagingSpot, spawnSpot = nil, nil
  fullDistance = 0
  if not levelId then return false end

  local data = jsonReadFile("levels/" .. levelId .. "/" .. CONFIG_FILENAME)
  if type(data) ~= "table" then
    logMessage("W", "Pulling venue unavailable: no level configuration")
    levelDataFailedFor = levelId
    return false
  end
  local definitions = pullingConfig.events(data)
  local eventIds = {}
  for eventId in pairs(definitions) do eventIds[#eventIds+1] = eventId end
  table.sort(eventIds)
  for _, eventId in ipairs(eventIds) do
    local venue = configuredVenue(definitions[eventId])
    if venue then venues[#venues+1] = venue end
  end
  if #venues == 0 then
    logMessage("W", "Pulling unavailable: no valid configured venues")
    levelDataFailedFor = levelId
    return false
  end
  activateVenue(venues[1])
  return true
end

local function selectNearestIdleVenue()
  if phase ~= "idle" or #venues < 2 then return end
  local vehicle = be:getPlayerVehicle(0)
  if not vehicle then return end
  local position = vehicle:getPosition()
  local nearest, bestDistance
  for _, venue in ipairs(venues) do
    local stage = venue.stagingPos
    local dx, dy, dz = position.x-stage.x, position.y-stage.y, position.z-stage.z
    local distance = dx*dx + dy*dy + dz*dz
    if not bestDistance or distance < bestDistance then nearest, bestDistance = venue, distance end
  end
  if nearest.config ~= config then activateVenue(nearest) end
end

local function triggerUi(visible, mode, payload)
  local isVisible = visible == true
  guihooks.trigger("TractorPullUi", {
    visible = isVisible,
    mode = isVisible and mode or nil,
    payload = payload or {},
  })
end

local function buildSledChoices()
  local choices = {}
  for _, sled in ipairs(config.sleds or {}) do
    choices[#choices + 1] = {
      id = sled.id,
      label = sled.label,
      baseReward = tonumber(sled.baseReward) or 0,
    }
  end
  return choices
end

local function buildHitchChoices()
  local choices = {}
  for _, hitch in ipairs(config.hitches or {}) do
    choices[#choices + 1] = {
      id = hitch.id,
      label = hitch.label,
    }
  end
  return choices
end

local function showSelector()
  if phase ~= "idle" then return end
  phase = "selecting"
  triggerUi(true, "select", {
    title = configValues.label,
    trackDistanceFeet = fullDistance * METERS_TO_FEET,
    sleds = buildSledChoices(),
  })
end

-- Attempt cleanup -----------------------------------------------------------------------------------

local function deleteSled()
  local object = sledVehicleId and be:getObjectByID(sledVehicleId) or nil
  if object and object.delete then object:delete() end
  sledVehicleId = nil
end

local function resetRuntime(deleteSpawnedSled)
  if deleteSpawnedSled then deleteSled() end
  sledVehicleId = nil
  phase = "idle"
  stationaryTime, spawnWaitTime, elapsedTime = 0, 0, 0
  noProgressTime, progressCheckpointDistance, maxDistance = 0, 0, 0
  hudAccumulator = 0
  selectedSled, selectedHitch, playerVehicleId, sledStartPos, lastSledFlatPos, resultData = nil, nil, nil, nil, nil, nil
  triggerUi(false)
end

local function isActiveAttempt()
  return phase == "spawning" or phase == "waiting" or phase == "pulling"
end

local function vehicleIdFrom(veh)
  if type(veh) == "number" then return veh end
  if veh and veh.getID then return veh:getID() end
  return nil
end

local function getInventoryId(vehicleId)
  if overhaul_career_business_fleet then
    local resolved = overhaul_career_business_fleet.resolveFreeroamLeaderboardInventoryId(vehicleId)
    if resolved then return resolved end
  end
  if overhaul_career_garage_inventory then
    return overhaul_career_garage_inventory.getInventoryIdFromVehicleId(vehicleId) or vehicleId
  end
  return vehicleId
end

local function getVehicleModel(vehicleId)
  if overhaul_events_fre_vehiclePool then return overhaul_events_fre_vehiclePool.getCurrentVehicleModel(vehicleId) end
  local object = vehicleId and be:getObjectByID(vehicleId) or nil
  return object and object.JBeam or nil
end

-- Rewards and pull settlement -----------------------------------------------------------------------

local function calculateReward(distance, fullPull, pullTime)
  local ratio = clamp(distance / fullDistance, 0, 1)
  local base = tonumber(selectedSled and selectedSled.baseReward) or 0
  local timeBonus = 0
  if fullPull then
    local par = tonumber(selectedSled and selectedSled.parTimeSeconds) or 0
    if par > 0 and pullTime < par then timeBonus = clamp((par - pullTime) / (par * 0.5), 0, 1) * 0.2 end
  end
  local money = base * ratio * (1 + timeBonus)
  local xp = base * 0.25 * ratio
  if overhaul_events_fre_race then
    local modifiers = overhaul_events_fre_race.calculateRewardModifiers({ "pulling" }) or {}
    local discipline = modifiers.disciplineMultipliers and modifiers.disciplineMultipliers.pulling or {}
    money = money * (tonumber(discipline.moneyMultiplier) or 1)
    xp = xp * (tonumber(discipline.xpMultiplier) or 1)
  end
  return math.max(0, math.floor(money + 0.5)), math.max(0, math.floor(xp + 0.5)), timeBonus
end

local function awardCareer(money, xp, label)
  if not overhaul_career_career.isActive() then return end
  return overhaul_career_economy_payment.payout(require("overhaul/lib/finance/metadata").tagPayout({
    amount = money,
    xp = { ["careerSkills-speed"] = xp },
    label = label .. " - Completion",
    tags = { "gameplay", "reward", "fre", "pulling" },
    reason = { canBeNegative = false },
    fullReward = true,
  }, "activity:tractorPull", {vehicleRole = "player"}))
end

local function recordPullLeaderboard(raceLabel, inventoryId, completedDistance, fullPull, money, invalid)
  local newBest = false
  if not invalid and inventoryId and overhaul_events_leaderboards then
    newBest = overhaul_events_leaderboards.addLeaderboardEntry({
      raceName = configValues.eventId,
      raceLabel = raceLabel,
      inventoryId = inventoryId,
      time = elapsedTime,
      pullDistance = completedDistance,
      fullPull = fullPull,
      sledId = selectedSled.id,
      hitchId = selectedHitch and selectedHitch.id or nil,
      reward = money,
    }) == true
  end

  return newBest
end

local function notifyPullResult(raceLabel, completedDistance, fullPull, reason, invalid, historyPrize)
  local payload = {
    historyPrize = historyPrize or 0,
    raceId = configValues.eventId,
    raceName = configValues.eventId,
    raceLabel = raceLabel,
    finishTime = elapsedTime,
    vehicleId = playerVehicleId,
    vehicleModel = getVehicleModel(playerVehicleId),
    disciplineIds = { "pulling" },
    invalidLap = invalid == true,
    resultMetrics = {
      sledId = selectedSled.id,
      distanceMeters = completedDistance,
      fullPullDistanceMeters = fullDistance,
      distanceRatio = fullDistance > 0 and completedDistance / fullDistance or 0,
      fullPull = fullPull,
      elapsedTime = elapsedTime,
      timeRecorded = fullPull,
      hitchId = selectedHitch and selectedHitch.id or nil,
      finishReason = reason,
    },
  }
  if overhaul_events_fre_race then overhaul_events_fre_race.onFreeroamRaceCompleted(payload) end
  extensions.hook("onRlsFreeroamRaceResultFinalized", payload)
end

local function showPullResult(completedDistance, fullPull, reason, invalid, money, xp, timeBonus, newBest)
  resultData = {
    title = invalid and "Pull Invalid" or (fullPull and "Full Pull!" or "Pull Complete"),
    sledLabel = selectedSled.label,
    distanceMeters = completedDistance,
    distanceFeet = completedDistance * METERS_TO_FEET,
    fullDistanceMeters = fullDistance,
    fullDistanceFeet = fullDistance * METERS_TO_FEET,
    fullPull = fullPull,
    elapsedTime = elapsedTime,
    timeRecorded = fullPull,
    finishReason = reason,
    rewardMoney = money,
    rewardXp = xp,
    timeBonusPercent = math.floor(timeBonus * 100 + 0.5),
    newBest = newBest,
    invalid = invalid == true,
  }
  phase = "results"
  triggerUi(true, "results", resultData)
end

local function finishPull(reason, invalid)
  if phase ~= "pulling" then return end
  local completedDistance = clamp(maxDistance, 0, fullDistance)
  local fullPull = not invalid
    and (reason == "full_pull" or maxDistance >= fullDistance - configValues.finishToleranceMeters)
  if fullPull then completedDistance = fullDistance end
  local money, xp, timeBonus = calculateReward(completedDistance, fullPull, elapsedTime)
  if invalid then
    money, xp = 0, 0
  end

  local raceLabel = string.format("%s - %s", configValues.label, selectedSled.label or selectedSled.id)
  local inventoryId = getInventoryId(playerVehicleId)
  local newBest = recordPullLeaderboard(raceLabel, inventoryId, completedDistance, fullPull, money, invalid)
  local accepted = not invalid and awardCareer(money, xp, raceLabel)
  notifyPullResult(raceLabel, completedDistance, fullPull, reason, invalid, accepted == true and money or 0)
  showPullResult(completedDistance, fullPull, reason, invalid, money, xp, timeBonus, newBest)
end

local function abortAttempt(reason)
  if phase == "pulling" then
    finishPull(reason, true)
  elseif isActiveAttempt() then
    resetRuntime(true)
  end
end

-- Sled spawning -------------------------------------------------------------------------------------

local function prepareSledPreset(sled, hitch)
  local vehicleConfig = jsonReadFile(sled.config)
  if type(vehicleConfig) ~= "table" or type(vehicleConfig.parts) ~= "table" then
    logMessage("E", "Could not load pulling sled preset " .. tostring(sled.config))
    ui_message("The selected pulling sled preset could not be loaded.", 6, "tractorPull", "warning")
    resetRuntime(true)
    return nil
  end
  vehicleConfig.parts.YB_PPS_chain = hitch.part
  vehicleConfig.partConfigFilename = sled.config

  return vehicleConfig
end

local function spawnSelectedSled(sled, hitch)
  playerVehicleId = be:getPlayerVehicleID(0)
  if not playerVehicleId or playerVehicleId == -1 then
    ui_message("Enter a vehicle before starting the tractor pull.", 4, "tractorPull")
    resetRuntime(true)
    return false
  end
  local pos = arrayToVec(spawnSpot.pos)
  local rot = arrayToQuat(spawnSpot.rot)
  if not pos or not rot then
    resetRuntime(true)
    return false
  end
  pos = pos + vec3(0, 0, tonumber(sled.spawnHeightMeters) or configValues.sledSpawnHeightMeters)

  local vehicleConfig = prepareSledPreset(sled, hitch)
  if not vehicleConfig then return false end

  local ok, object = pcall(function()
    return core_vehicles.spawnNewVehicle(sled.model, {
      config = vehicleConfig,
      pos = pos,
      rot = rot,
      cling = false,
      autoEnterVehicle = false,
    })
  end)
  if not ok or not object or not object.getID then
    logMessage("E", "Could not spawn pulling sled " .. tostring(sled.id) .. ": " .. tostring(object))
    ui_message(
      "The selected pulling sled could not be spawned. Check that Youngblood Pulling Sled v2 is enabled.",
      7,
      "tractorPull",
      "warning"
    )
    resetRuntime(true)
    return false
  end

  sledVehicleId = object:getID()
  selectedSled = sled
  selectedHitch = hitch
  spawnWaitTime = 0
  elapsedTime = 0
  noProgressTime = 0
  progressCheckpointDistance = 0
  sledStartPos = nil
  lastSledFlatPos = nil
  maxDistance = 0
  phase = "spawning"
  triggerUi(false)
  return true
end

-- Selection and public state ------------------------------------------------------------------------

function M.selectSled(id)
  if phase ~= "selecting" or not loadLevelData() then return false end
  local sled = sledById(id)
  if not sled then return false end
  selectedSled = sled
  phase = "choosingHitch"
  triggerUi(true, "hitch", {
    sledLabel = sled.label,
    baseReward = tonumber(sled.baseReward) or 0,
    hitches = buildHitchChoices(),
  })
  return true
end

function M.selectHitch(id)
  if phase ~= "choosingHitch" or not selectedSled or not loadLevelData() then return false end
  local hitch = hitchById(id)
  if not hitch or type(hitch.part) ~= "string" or hitch.part == "" then return false end
  return spawnSelectedSled(selectedSled, hitch)
end

function M.backToSleds()
  if phase ~= "choosingHitch" then return end
  selectedSled = nil
  phase = "idle"
  showSelector()
end

function M.cancel()
  resetRuntime(true)
end

function M.dismissResults()
  if phase ~= "results" then return end
  resetRuntime(true)
end

function M.getState()
  return {
    phase = phase,
    levelId = levelId,
    eventId = configValues and configValues.eventId or nil,
    sledVehicleId = sledVehicleId,
    playerVehicleId = playerVehicleId,
    selectedSledId = selectedSled and selectedSled.id or nil,
    selectedHitchId = selectedHitch and selectedHitch.id or nil,
    distanceMeters = maxDistance,
    fullDistanceMeters = fullDistance,
    elapsedTime = elapsedTime,
    result = resultData,
  }
end

-- Per-frame tracking --------------------------------------------------------------------------------

local function isOtherActivityActive()
  local session = overhaul_events_session
  if session and (session.mActiveRace or session.staged) then return true end
  local derby = overhaul_events_derby_derby
  if derby and derby.isRecoveryRadialOverrideActive() then return true end
  return false
end

local stagingPosSpot, stagingPosCache
local function updateIdle(dt)
  if isOtherActivityActive() then
    stationaryTime = 0
    if phase == "selecting" or phase == "choosingHitch" then resetRuntime(false) end
    return
  end
  local vehicle = be:getPlayerVehicle(0)
  if stagingSpot and stagingPosSpot ~= stagingSpot then
    stagingPosSpot, stagingPosCache = stagingSpot, arrayToVec(stagingSpot.pos)
  end
  local stagingPos = stagingSpot and stagingPosCache
  if not vehicle or not stagingPos then return end
  local distance = vehicle:getPosition():distance(stagingPos)
  local enterRadius = configValues.stagingRadiusMeters
  local exitRadius = configValues.stagingExitRadiusMeters
  if phase == "selecting" or phase == "choosingHitch" then
    if distance > exitRadius then resetRuntime(false) end
    return
  end
  if distance > enterRadius then
    stationaryTime = 0
    return
  end
  local speed = vehicle:getVelocity():length()
  if speed <= configValues.stagingStopSpeedMps then
    stationaryTime = stationaryTime + dt
    if stationaryTime >= configValues.stagingStopSeconds then showSelector() end
  else
    stationaryTime = 0
  end
end

local function pushHud(status)
  triggerUi(true, "hud", {
    sledLabel = selectedSled.label,
    distanceMeters = clamp(maxDistance, 0, fullDistance),
    distanceFeet = clamp(maxDistance, 0, fullDistance) * METERS_TO_FEET,
    fullDistanceMeters = fullDistance,
    fullDistanceFeet = fullDistance * METERS_TO_FEET,
    elapsedTime = elapsedTime,
    status = status,
    canAbandon = phase == "waiting",
  })
end

local function updateSpawning(dt)
  spawnWaitTime = spawnWaitTime + dt
  if spawnWaitTime < configValues.sledLoadDelaySeconds then return end

  local sled = sledVehicleId and be:getObjectByID(sledVehicleId) or nil
  if not sled then
    ui_message("The pulling sled did not finish spawning.", 5, "tractorPull", "warning")
    resetRuntime(false)
    return
  end

  local settledPos = sled:getPosition()
  sledStartPos = vec3(settledPos.x, settledPos.y, 0)
  lastSledFlatPos = vec3(settledPos.x, settledPos.y, 0)
  spawnWaitTime = 0
  phase = "waiting"
  pushHud("Waiting for sled movement")
end

local function finishTrackedPullIfNeeded(dt)
  if maxDistance >= fullDistance - configValues.finishToleranceMeters then
    finishPull("full_pull", false)
    return true
  end

  if phase == "pulling" then
    local progressStep = configValues.progressIncrementFeet / METERS_TO_FEET
    if maxDistance >= progressCheckpointDistance + progressStep then
      progressCheckpointDistance = maxDistance
      noProgressTime = 0
    else
      noProgressTime = noProgressTime + dt
      if noProgressTime >= configValues.noProgressFinishSeconds then
        finishPull("no_progress", false)
        return true
      end
    end

    if elapsedTime >= configValues.maximumPullSeconds then
      finishPull("time_limit", false)
      return true
    end
  end

  return false
end

local function updateTracking(dt)
  local sled = sledVehicleId and be:getObjectByID(sledVehicleId) or nil
  if not sled or not sledStartPos then
    if phase == "pulling" then
      finishPull("vehicle_missing", true)
    else
      resetRuntime(false)
    end
    return
  end

  local position = sled:getPosition()
  local flatPos = vec3(position.x, position.y, 0)
  if lastSledFlatPos then
    local jump = (flatPos - lastSledFlatPos):length()
    local baseJump = configValues.maxSledTeleportJumpMeters
    local maxRate = configValues.maxSledTeleportSpeedMps
    local maxJump = math.max(baseJump, maxRate * math.max(tonumber(dt) or 0, 0))
    if jump > maxJump then
      abortAttempt("teleported")
      return
    end
  end
  lastSledFlatPos = flatPos

  local dx = flatPos.x - sledStartPos.x
  local dy = flatPos.y - sledStartPos.y
  local distance = math.sqrt(dx * dx + dy * dy)
  maxDistance = math.max(maxDistance, distance)

  local startMovement = configValues.startMovementFeet / METERS_TO_FEET
  if phase == "waiting" and maxDistance > startMovement then
    phase = "pulling"
    elapsedTime = 0
    noProgressTime = 0
    progressCheckpointDistance = maxDistance
  end

  if phase == "pulling" then elapsedTime = elapsedTime + dt end

  if finishTrackedPullIfNeeded(dt) then return end

  hudAccumulator = hudAccumulator + dt
  if hudAccumulator >= 0.1 then
    hudAccumulator = hudAccumulator % 0.1
    pushHud(phase == "waiting" and "Waiting for sled movement" or "Pulling")
  end
end

-- Ticked by freeroamEvents once per frame with the sim delta; not an engine hook.
function M.update(dtSim)
  local dt = math.max(0, tonumber(dtSim) or 0)
  if not loadLevelData() then
    if phase ~= "idle" then resetRuntime(true) end
    return
  end
  selectNearestIdleVenue()
  if phase == "idle" or phase == "selecting" or phase == "choosingHitch" then
    updateIdle(dt)
  elseif phase == "spawning" then
    updateSpawning(dt)
  elseif phase == "waiting" or phase == "pulling" then
    updateTracking(dt)
  end
end

-- Lifecycle and vehicle hooks -----------------------------------------------------------------------

function M.onVehicleDestroyed(vehicleId)
  if vehicleId == sledVehicleId then
    if phase == "pulling" then
      finishPull("vehicle_destroyed", true)
    else
      resetRuntime(false)
    end
  elseif vehicleId == playerVehicleId and isActiveAttempt() then
    abortAttempt("player_vehicle_destroyed")
  end
end

function M.onTeleportedToGarage(_, veh)
  local vehId = vehicleIdFrom(veh)
  if not isActiveAttempt() then return end
  if vehId == playerVehicleId or vehId == sledVehicleId then abortAttempt("towed_to_garage") end
end

function M.onClientEndMission()
  if phase ~= "idle" then resetRuntime(true) end
  levelId, config, configValues, sites = nil, nil, nil, nil
  venues = {}
  levelDataFailedFor = nil
end

function M.onWorldReadyState(state)
  if state == 2 then
    levelId, config, configValues, sites = nil, nil, nil, nil
    venues = {}
    levelDataFailedFor = nil
    loadLevelData()
  end
end

function M.onExtensionUnloaded()
  resetRuntime(true)
end

-- The sled must be gone before a Lua reload serializes stock checkpoints.
require("overhaul/lib/vehicles/temporary").declare("tractorPull", function()
  resetRuntime(true)
end)

return M
