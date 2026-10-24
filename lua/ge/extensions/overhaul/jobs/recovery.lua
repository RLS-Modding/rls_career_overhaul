-- Off-road recovery offers, saved targets and completion rewards.
-- Read config and state, named parts, saving and target phases, public operations, lifecycle and update.
local recordJob = require("overhaul/lib/progression/logbookFeed").register("overhaul.recoveryCompleted", {
  title = "Recovery completed", label = "Jobs", icon = "carCoins"
}, "jobs/recovery.lua")
local M = {}
local vehicleCommands = require('overhaul/lib/vehicles/vehicleCommands')
local scopeSubscriptions = require('overhaul/lib/ui/scopeSubscriptions')
local shared = {}
local parts = {}
M.dependencies = {
  "util_configListGenerator"
}
local units = require('common/overhaul/units')
local configListGenerator = require("util/configListGenerator")
local sitesManager = require('overhaul/lib/world/sitesManager').sitesManager
local routeFactory = require("/lua/ge/extensions/gameplay/route/route")
-- Config ----------------------------------------------------------------------------------------

local LOG_TAG = "offroadRecovery"
local constants = {SKILL_ATTRIBUTE = "careerSkills-recovery"}
constants.SKILL_PATHS = {"careerSkills-recovery", "recovery"}
constants.FILTERS_FILE = "gameplay/overhaul/offroadRecovery/offroadRecoveryVehicleFilters.json"
constants.SITES_NAME = "offroadRecovery"
constants.SAVE_DIR = "/career/rls_career"
constants.SAVE_FILE = constants.SAVE_DIR .. "/offroadRecovery.json"
constants.DAMAGE_DIR = constants.SAVE_DIR .. "/offroadRecoveryDamage"
constants.SESSION_DAMAGE_DIR = "/temp/rls_career/offroadRecoveryDamage"
constants.OFFER_INTERVAL_MIN = 5
constants.OFFER_TTL_MIN = 15
constants.MAX_OFFERS = 3
constants.MAX_ACTIVE_PER_MAP = 3
constants.DELIVERY_RADIUS_M = 5
constants.DELIVERY_MAX_SPEED_MPS = 1
constants.SAVE_TIMEOUT_S = 15
constants.ASYNC_SAVE_EXTENSION = "offroadRecovery"
constants.METERS_PER_MILE = units.METERS_PER_MILE
constants.MIN_TARGET_MILEAGE_MI = 100000
constants.MAX_TARGET_MILEAGE_MI = 300000

-- State -----------------------------------------------------------------------------------------

local state = {version = 1, maps = {}, nextId = 1}
local completionGeneration = 0
local currentMap
local availableOffers = {}
local pendingOfferId
local nextOfferAt
local simMinutes = 0
local boardEligible = false
local sitesCache
local sitesCacheMap
local facilitySitesCache
local facilitySitesCacheMap
local routeDistanceCache = {}
local boardTimer = 0
local BOARD_REFRESH_SECONDS = 1

parts.vehiclePool = require('overhaul/jobs/recovery/vehiclePool')(LOG_TAG, constants)

local vehiclePoolCache
local vehiclePoolSkillLevel
local runtimeByVehicleId = {}
local lastCompletion
local updateTimer = 0
local uiTimer = 0
local uiScopes = {}
local hadUiContent = false
local clearTasklistTimer = nil
local TASKLIST_CLEAR_SECONDS = 10
local initialized = false
local returnToOfferBoardAfterMap = false
local pendingCareerSave
local saveRegistered = false
local saveGenerationToken
local nextSaveToken = 0
local stateLoaded = false
local loadedProfileName
local trackedRouteKey
local trackedRouteActive = false
local trackedRoute = require('overhaul/lib/activity/routeLease').new()
local dropoffZonesByYardId = {}
local spawnAdvanceDepth = 0
local MAX_SPAWN_ADVANCE = 5
local recoverySave

parts.persistence = require('overhaul/jobs/recovery/persistence')(constants, function() return recoverySave end)

local function buildVehiclePool()
  local level = parts.vehiclePool.getSkillLevel()
  if vehiclePoolCache and vehiclePoolSkillLevel == level then return vehiclePoolCache end
  vehiclePoolSkillLevel = level
  vehiclePoolCache = {}
  local filters = parts.vehiclePool.loadFilters()
  local allVehicles = configListGenerator.getEligibleVehicles(false, false) or {}
  for _, vehicleInfo in ipairs(allVehicles) do
    if not parts.vehiclePool.isElectricOrHybrid(vehicleInfo) and not parts.vehiclePool.configTypeStartsMissions(vehicleInfo) then
      for _, filter in ipairs(filters) do
        if parts.vehiclePool.filterUnlocked(filter, level) and parts.vehiclePool.matchesFilterConfig(vehicleInfo, filter) then
          local candidate = deepcopy(vehicleInfo)
          candidate.recoveryTag = filter.unlockTag
          candidate.recoveryTierLabel = filter.tierLabel
          candidate.recoveryPayMultiplier = filter.payMultiplier
          candidate.recoveryBaseXp = filter.baseXp
          vehiclePoolCache[#vehiclePoolCache + 1] = candidate
          break
        end
      end
    end
  end
  return vehiclePoolCache
end

local function loadRecoverySites(force)
  local mapId = getCurrentLevelIdentifier()
  if not mapId then return nil end
  if not force and sitesCache and sitesCacheMap == mapId then return sitesCache end
  sitesCache, sitesCacheMap = nil, mapId
  local sitePath = sitesManager().getCurrentLevelSitesFileByName(constants.SITES_NAME)
  if not sitePath then return nil end
  sitesCache = sitesManager().loadSites(sitePath, force == true, true)
  return sitesCache
end

-- Owned yards -----------------------------------------------------------------------------------

local function getOwnedRecoveryYards()
  local result = {}
  local mapId = getCurrentLevelIdentifier()
  if not mapId or not overhaul_world_facilities then return result end
  local facilities = overhaul_world_facilities.getFacilities(mapId)
  for _, garage in ipairs(facilities and facilities.garages or {}) do
    if garage.isRecoveryYard == true and garage.recoveryDropoffSpotName
        and overhaul_career_career and overhaul_career_career.isActive()
        and overhaul_career_garage_garageManager.isPurchasedGarage(garage.id) then
      local chosen
      for _, spot in ipairs(overhaul_world_facilities.getParkingSpotsForFacility(garage) or {}) do
        if spot.name == garage.recoveryDropoffSpotName then
          chosen = spot
          break
        end
      end
      if not chosen then
        if facilitySitesCacheMap ~= mapId then
          local facilitySitesPath = sitesManager().getCurrentLevelSitesFileByName("facilities")
          facilitySitesCache = facilitySitesPath and sitesManager().loadSites(facilitySitesPath, false, true) or false
          facilitySitesCacheMap = mapId
        end
        local facilitySites = facilitySitesCache
        chosen = facilitySites and facilitySites.parkingSpots and facilitySites.parkingSpots.byName
          and facilitySites.parkingSpots.byName[garage.recoveryDropoffSpotName]
      end
      if chosen and chosen.pos then
        result[#result + 1] = {
          id = garage.id,
          name = translateLanguage and translateLanguage(garage.name, garage.name, true) or garage.name,
          spotName = garage.recoveryDropoffSpotName,
          spot = chosen
        }
      end
    end
  end
  table.sort(result, function(a, b) return tostring(a.name) < tostring(b.name) end)
  return result
end

local function getYardDropoffZones(yardId)
  if not yardId then return nil end
  if dropoffZonesByYardId[yardId] ~= nil then return dropoffZonesByYardId[yardId] end
  local garage = overhaul_world_facilities.getFacilityIfExists("garage", yardId)
  dropoffZonesByYardId[yardId] = (garage and overhaul_world_facilities.getZonesForFacility(garage)) or {}
  return dropoffZonesByYardId[yardId]
end

-- Recovery spots and yards ----------------------------------------------------------------------

local function getSpotMinLevel(spot)
  local custom = spot and spot.customFields
  local value = custom and custom.values and tonumber(custom.values.minLevel)
  return value and math.max(1, math.floor(value)) or 1
end

local function spotHasTag(spot, tag)
  local tags = spot and spot.customFields and spot.customFields.tags
  if type(tags) ~= "table" then return false end
  local wanted = string.lower(tostring(tag))
  for key, value in pairs(tags) do
    if type(key) == "string" and string.lower(key) == wanted and value ~= false then return true end
    if type(value) == "string" and string.lower(value) == wanted then return true end
  end
  return false
end

local function spotAllowsRewardType(spot, rewardType)
  -- Map authors can reserve special finds for vehicle-reward contracts without changing the behavior of existing, untagged recovery spots.
  return rewardType == "vehicle" or not spotHasTag(spot, "keepItOnly")
end

-- Site names are internal persistence keys only. Map authors can leave the editor-generated name alone (or leave it blank); contracts never expose it.
local function getSpotKey(spot)
  local name = spot and type(spot.name) == "string" and spot.name:match("^%s*(.-)%s*$") or ""
  if name ~= "" then return name end
  local pos = spot and spot.pos
  if not pos then return nil end
  return string.format("recovery@%.3f,%.3f,%.3f", pos.x or pos[1] or 0, pos.y or pos[2] or 0, pos.z or pos[3] or 0)
end

local function getPlayerPosition()
  local player = be:getPlayerVehicle(0)
  return player and player:getPosition() or nil
end

local function findOwnedYard(yardId)
  if not yardId then return nil end
  for _, yard in ipairs(getOwnedRecoveryYards()) do
    if yard.id == yardId then return yard end
  end
end

local function isInYardDropoff(job, vehiclePos)
  -- A target cannot be delivered until it has actually been extracted. This prevents returning the recovery truck alone from completing a contract whose target is still at its original location.
  if not job or job.phase ~= "delivery" or not vehiclePos then return false end
  local zones = getYardDropoffZones(job.yardId)
  if zones and #zones > 0 then
    for _, zone in ipairs(zones) do
      if zone.containsPoint2D and zone:containsPoint2D(vehiclePos) then
        return true
      end
    end
    return false
  end
  local destination = parts.persistence.arrayToVec3(job.deliveryPos)
  return destination and vehiclePos:distance(destination) <= constants.DELIVERY_RADIUS_M
end

local function objectivePosition(job)
  if not job then return nil end
  if job.phase == "delivery" then return parts.persistence.arrayToVec3(job.deliveryPos) end
  local vehicle = job.vehicleId and getObjectByID(job.vehicleId)
  return vehicle and vehicle:getPosition() or parts.persistence.arrayToVec3(job.targetPos)
end

-- Reward helpers --------------------------------------------------------------------------------

local function economyMultiplier()
  return tonumber((overhaul_career_economyAdjuster.getSectionMultiplier("offroadRecovery"))) or 1
end

local function routeDistance(fromPos, toPos)
  if not fromPos or not toPos then return 0 end
  local cacheKey = string.format("%.1f,%.1f,%.1f>%.1f,%.1f,%.1f", fromPos.x, fromPos.y, fromPos.z, toPos.x, toPos.y, toPos.z)
  local cachedDistanceMeters = routeDistanceCache[cacheKey]
  if cachedDistanceMeters then return cachedDistanceMeters end
  local straightDistanceMeters = fromPos:distance(toPos)
  local ok, result = pcall(function()
    local planner = routeFactory()
    planner:setRouteParams(nil, 1e3)
    planner:setupPath(fromPos, toPos)
    local distance = planner.path and planner.path[1] and planner.path[1].distToTarget or planner.distance
    planner:clear()
    return tonumber(distance)
  end)
  local resolvedDistanceMeters = ok and result and result > 0 and result or straightDistanceMeters
  routeDistanceCache[cacheKey] = resolvedDistanceMeters
  return resolvedDistanceMeters
end

parts.rewards = require('overhaul/jobs/recovery/rewards')(parts.persistence.arrayToVec3, economyMultiplier,
      parts.vehiclePool.getPayoutBonus, parts.vehiclePool.getSkillLevel, routeDistance)

local function showCompletionTasklist(breakdown, header)
  guihooks.trigger("ClearTasklist")
  guihooks.trigger("SetTasklistHeader", {label = header or "Recovery Complete"})
  for index, line in ipairs(breakdown or {}) do
    guihooks.trigger("SetTasklistTask", {
      id = "offroadRecovery_complete_" .. index,
      label = parts.rewards.formatBreakdownLine(line),
      done = line.isTotal == true,
      active = true,
      type = "message",
      clear = false
    })
  end
  clearTasklistTimer = TASKLIST_CLEAR_SECONDS
end

parts.offers = require('overhaul/jobs/recovery/offers')(parts.persistence.arrayToVec3, buildVehiclePool,
      parts.vehiclePool.candidateCanSpawn, parts.vehiclePool.chooseWeighted, constants, economyMultiplier, parts.rewards.fixedCashQuote,
      getOwnedRecoveryYards, getPlayerPosition, parts.vehiclePool.getSkillLevel, getSpotKey, getSpotMinLevel,
      parts.vehiclePool.isRememberedUnspawnable, loadRecoverySites, objectivePosition, parts.vehiclePool.offerVehicleValue,
      parts.vehiclePool.randomMileageMeters, parts.vehiclePool.rememberUnspawnable, parts.vehiclePool.removeVehicleCandidate, parts.vehiclePool.rollCondition,
      spotAllowsRewardType, parts.persistence.toQuatArray, parts.persistence.toVec3Array, parts.vehiclePool.vehicleFitsSpot, function()
        return availableOffers, currentMap, simMinutes, state
      end)

-- Save snapshots --------------------------------------------------------------------------------

local function serializableState()
  local result = deepcopy(state)
  for _, mapState in pairs(result.maps or {}) do
    for _, job in ipairs(mapState.jobs or {}) do
      job.vehicleId = nil
      job.completing = nil
      job.spawnPending = nil
      if job.status == "active" or job.status == "spawning" then job.status = "paused" end
    end
  end
  return result
end

-- Save features -----------------------------------------------------------------------------------


-- Features register on this owner's load, or at the first save boundary, so an old load cannot reclaim a replacement's keys.
local saveFeatures = {disposed = false}

local function registerSaveFeatures()
  assert(not saveFeatures.disposed, 'Recovery persistence owner unloaded')
  if saveFeatures.saved then return end
  local saveStore = require('overhaul/lib/save/store')
  local stateFile = constants.SAVE_FILE:sub(2)
  local damageFamily = constants.DAMAGE_DIR:sub(2) .. '/*.json'
  local sessionFamily = constants.SESSION_DAMAGE_DIR:sub(2) .. '/*.json'
  saveFeatures.saved = assert(saveStore.feature('jobs.offroadRecovery', {
    owner = 'overhaul_jobs_recovery', files = {stateFile}, root = 'slot',
    phase = 'profile', required = true, async = constants.ASYNC_SAVE_EXTENSION,
    writer = {pretty = true},
    capture = function(context, serializableStateFn, writer)
      parts.persistence.ensureSaveDirectories(context.base, writer)
      return context.write(serializableStateFn())
    end,
    restore = function(context) return context.read() end,
  }))
  local function dispatch(context, operation, ...) return operation(context, ...) end
  saveFeatures.damage = assert(saveStore.feature('jobs.offroadRecoveryDamage', {
    owner = 'overhaul_jobs_recovery', files = {damageFamily}, root = 'slot',
    phase = 'vehicleSave', required = true, async = constants.ASYNC_SAVE_EXTENSION,
    writer = {pretty = false}, capture = dispatch,
  }))
  saveFeatures.session = assert(saveStore.feature('jobs.offroadRecoverySession', {
    owner = 'overhaul_jobs_recovery', files = {sessionFamily},
    root = 'user', phase = 'immediate', required = true,
    writer = {pretty = false}, capture = dispatch,
  }))
end

if type(overhaul_career_saveSystem) == 'table' then registerSaveFeatures() end

recoverySave = {
  capture = function(base, serializableStateFn, writer)
    registerSaveFeatures()
    return saveFeatures.saved.capture(base, serializableStateFn, writer)
  end,
  restore = function(base) registerSaveFeatures(); return saveFeatures.saved.restore(base) end,
  damage = function(base, operation, ...) registerSaveFeatures(); return saveFeatures.damage.capture(base, operation, ...) end,
  session = function(operation, ...) registerSaveFeatures(); return saveFeatures.session.capture('/', operation, ...) end,
  dispose = function()
    if saveFeatures.disposed then return end
    saveFeatures.disposed = true
    if saveFeatures.saved then
      saveFeatures.saved.dispose()
      saveFeatures.damage.dispose()
      saveFeatures.session.dispose()
    end
  end,
}

local function saveStateToPath(savePath, writer)
  if not savePath then return end
  recoverySave.capture(savePath, serializableState, writer)
end

local function loadState(writer)
  local savePath = parts.persistence.currentSavePath()
  local profileName = parts.persistence.currentProfileName()
  if stateLoaded and loadedProfileName == profileName then return false end
  local loaded = savePath and recoverySave.restore(savePath)
  if type(loaded) == "table" and type(loaded.maps) == "table" then
    state = loaded
    state.version = 1
    state.nextId = tonumber(state.nextId) or 1
  else
    state = {version = 1, maps = {}, nextId = 1}
  end
  stateLoaded = true
  loadedProfileName = profileName
  parts.persistence.clearSessionDamage(writer)
  return true
end

local function hasSpawnedCurrentMapJob()
  if not currentMap then return false end
  for _, job in ipairs(parts.offers.getMapState(currentMap).jobs or {}) do
    if job.status == "active" and job.vehicleId and getObjectByID(job.vehicleId) then return true end
  end
  return false
end

local function captureDamageSnapshots(context, oldSavePath, newSavePath, writer)
  writer = writer or context.writer
  if not newSavePath then return end
  parts.persistence.ensureSaveDirectories(newSavePath, writer)
  if oldSavePath == newSavePath then return end

  local destinationDir = newSavePath .. constants.DAMAGE_DIR
  for _, filePath in ipairs(writer.findFiles(destinationDir, "*.json", 0, false, false) or {}) do
    local ok, err = pcall(writer.remove, filePath)
    if not ok then log("W", LOG_TAG, "Could not remove stale recovery snapshot: " .. tostring(err)) end
  end

  for _, mapState in pairs(state.maps or {}) do
    for _, job in ipairs(mapState.jobs or {}) do
      local source = parts.persistence.sessionDamageFilePath(job.id)
      if not FS:fileExists(source) then source = parts.persistence.damageFilePath(job.id, oldSavePath) end
      local destination = parts.persistence.damageFilePath(job.id, newSavePath)
      if source and destination and FS:fileExists(source) then
        local ok, result = pcall(writer.copy, source, destination)
        if not ok or result == false then
          log("W", LOG_TAG, "Could not carry recovery snapshot forward for " .. tostring(job.id))
        end
      end
    end
  end
end

local function stageDamageSnapshots(oldSavePath, newSavePath, writer)
  if newSavePath then recoverySave.damage(newSavePath, captureDamageSnapshots, oldSavePath, newSavePath, writer) end
end

local function finishCareerSave(timedOut)
  local pending = pendingCareerSave
  if not pending then return end
  if not timedOut then
    if not pending.inventoryReady then return end
    for _, entry in pairs(pending.jobs) do
      if not entry.energyDone or not entry.damageDone then return end
    end
  end

  if timedOut then
    local incomplete = {}
    if not pending.inventoryReady then incomplete[#incomplete + 1] = "inventory" end
    for _, entry in pairs(pending.jobs) do
      if not entry.energyDone then incomplete[#incomplete + 1] = tostring(entry.job.id) .. ":energy" end
      if not entry.damageDone then incomplete[#incomplete + 1] = tostring(entry.job.id) .. ":damage" end
    end
    log("W", LOG_TAG, "Recovery save timed out; retaining the last complete data for " .. table.concat(incomplete, ", "))
  end

  saveStateToPath(pending.savePath)
  pendingCareerSave = nil
  saveRegistered = false
  local generation = saveGenerationToken
  saveGenerationToken = nil
  if overhaul_career_saveSystem and overhaul_career_saveSystem.asyncSaveExtensionFinished then
    overhaul_career_saveSystem.asyncSaveExtensionFinished(constants.ASYNC_SAVE_EXTENSION, generation)
  end
end

local function markCareerSaveEnergyDone(token, jobId)
  local pending = pendingCareerSave
  if not pending or pending.token ~= token then return end
  local entry = pending.jobs[tostring(jobId)]
  if not entry then return end
  entry.energyDone = true
  finishCareerSave(false)
end

local function beginCareerSave(savePath, writer)
  nextSaveToken = nextSaveToken + 1
  local token = "save-" .. tostring(nextSaveToken)
  local oldSavePath = parts.persistence.currentSavePath()
  stageDamageSnapshots(oldSavePath, savePath, writer)
  pendingCareerSave = {
    token = token,
    savePath = savePath,
    oldSavePath = oldSavePath,
    elapsed = 0,
    inventoryReady = false,
    jobs = {}
  }

  for _, job in ipairs(currentMap and parts.offers.getMapState(currentMap).jobs or {}) do
    local vehicle = job.status == "active" and job.vehicleId and getObjectByID(job.vehicleId)
    if vehicle then
      parts.persistence.capturePose(job)
      local entry = {job = job, energyDone = false, damageDone = false}
      pendingCareerSave.jobs[tostring(job.id)] = entry
      parts.persistence.captureEnergy(job, function() markCareerSaveEnergyDone(token, job.id) end)
      local callbackCode = string.format("%q, %q", token, tostring(job.id))
      if not parts.persistence.saveDamageSnapshot(job, savePath, callbackCode) then entry.damageDone = true end
    end
  end

  if parts.persistence.tableCount(pendingCareerSave.jobs) == 0 then
    pendingCareerSave.inventoryReady = true
    finishCareerSave(false)
  end
end

function M.onDamageSnapshotSaved(token, jobId)
  local pending = pendingCareerSave
  if not pending or pending.token ~= token then return end
  local entry = pending.jobs[tostring(jobId)]
  if not entry then return end
  entry.damageDone = true
  finishCareerSave(false)
end

-- Target vehicles -------------------------------------------------------------------------------

parts.targetVehicle = require('overhaul/jobs/recovery/targetVehicle')(LOG_TAG, parts.vehiclePool.resolveConfigPath,
      parts.persistence.sessionDamageFilePath)

local function attachTemporaryInventory(job, vehicle, callback)
  if not vehicle or not overhaul_career_garage_inventory then
    if callback then callback(false) end
    return
  end
  job.inventoryId = job.inventoryId or ("offroadRecovery:" .. job.id)
  local inventoryId = overhaul_career_garage_inventory.addVehicle(vehicle:getID(), job.inventoryId, {
    owned = false,
    skipPartConditionInit = true
  })
  if not inventoryId then
    if callback then callback(false) end
    return
  end
  local record = overhaul_career_garage_inventory.getVehicles()[inventoryId]
  if record then
    record.offroadRecoveryContract = true
    record.offroadRecoveryJobId = job.id
    record.loanType = nil
    record.year = job.year
    record.mileage = tonumber(job.mileage) or record.mileage or 0
    if job.vehicleSnapshot and job.vehicleSnapshot.partConditions then
      record.partConditions = deepcopy(job.vehicleSnapshot.partConditions)
    end
  end
  job.inventoryId = inventoryId
  runtimeByVehicleId[vehicle:getID()] = job.id
  if callback then callback(true) end
end

local function finishNewTarget(job)
  local vehicle = job.vehicleId and getObjectByID(job.vehicleId)
  if not vehicle then
    job.spawnPending = nil
    shared.onTargetSpawnFailed(job, "spawnVanished")
    return
  end
  parts.targetVehicle.setOneLiter(job, vehicle, function()
    attachTemporaryInventory(job, vehicle, function(ok)
      job.spawnPending = nil
      if not ok then
        shared.onTargetSpawnFailed(job, "inventoryAttachFailed")
        return
      end
      overhaul_career_garage_inventory.updatePartConditions(job.vehicleId, job.inventoryId, function()
        local record = overhaul_career_garage_inventory.getVehicles()[job.inventoryId]
        if record then
          job.baselineConditions = deepcopy(record.partConditions or {})
          job.vehicleSnapshot = {
            model = record.model,
            config = deepcopy(record.config),
            partConditions = deepcopy(record.partConditions)
          }
        end
        job.replaceOnSpawnFail = nil
        job.status = "active"
        parts.persistence.capturePose(job)
        M.requestState()
      end)
    end)
  end)
end

local function finishRestoredTarget(job)
  local vehicle = job.vehicleId and getObjectByID(job.vehicleId)
  if not vehicle then
    job.spawnPending = nil
    shared.onTargetSpawnFailed(job, "spawnVanished")
    return
  end
  attachTemporaryInventory(job, vehicle, function(ok)
    job.spawnPending = nil
    if not ok then
      shared.onTargetSpawnFailed(job, "inventoryAttachFailed")
      return
    end
    parts.targetVehicle.setStoredEnergy(job, vehicle, function()
      local pathName = parts.persistence.loadableDamageFilePath(job.id)
      if pathName then
        vehicle:queueLuaCommand("extensions.load('overhaulDamageState'); if overhaulDamageState then "
          .. vehicleCommands.call('overhaulDamageState', 'loadDamageData', (pathName:gsub("\\", "/"))) .. " end")
      end
      job.replaceOnSpawnFail = nil
      job.status = "active"
      M.requestState()
    end)
  end)
end

local function spawnJobTarget(job, restored)
  if not job or job.spawnPending or job.skippingUnspawnable or currentMap ~= job.mapId then return end
  if job.vehicleId and getObjectByID(job.vehicleId) then return true end
  local config = restored and job.vehicleSnapshot and job.vehicleSnapshot.config or job.configKey
  if not parts.vehiclePool.targetContentAvailable(job.model, config) then
    job.vehicleId = nil
    job.spawnPending = nil
    shared.onTargetSpawnFailed(job, "contentUnavailable")
    return false
  end
  if not restored then config = parts.targetVehicle.configWithMissingWheelSlots(job, config) end
  config = parts.targetVehicle.withRecoverySpawnFlag(job, config)
  job.spawnPending = true
  job.status = "spawning"
  local vehicle = core_vehicles.spawnNewVehicle(job.model, {
    config = config,
    autoEnterVehicle = false,
    pos = parts.persistence.arrayToVec3(job.targetPos),
    rot = parts.persistence.arrayToQuat(job.targetRot),
    cling = false,
    paint = {baseColor = {math.random(), math.random(), math.random(), 1}, metallic = false},
    electrics = {parkingbrake = 0}
  })
  if not vehicle then
    job.spawnPending = nil
    shared.onTargetSpawnFailed(job, "spawnFailed")
    return false
  end
  job.vehicleId = vehicle:getID()
  runtimeByVehicleId[job.vehicleId] = job.id
  if restored and job.vehicleSnapshot and job.vehicleSnapshot.partConditions then
    core_vehicleBridge.executeAction(vehicle, "initPartConditions", job.vehicleSnapshot.partConditions, 0, 1, 1)
    core_vehicleBridge.requestValue(vehicle, function()
      finishRestoredTarget(job)
    end, "ping")
  else
    vehicle:queueLuaCommand(parts.targetVehicle.initialConditionCommand(job, vehicle:getID()))
  end
  return true
end

function M.onInitialConditionApplied(jobId, vehicleId)
  local job = parts.offers.findJob(jobId)
  if not job or job.vehicleId ~= vehicleId then return end
  core_jobsystem.create(function(jobHandle)
    jobHandle.sleep(0.35)
    finishNewTarget(job)
  end)
end

local function removeOfferAt(index)
  table.remove(availableOffers, index)
  if pendingOfferId and not parts.offers.findOffer(pendingOfferId) then pendingOfferId = nil end
end

-- Soft cleanup: temp-lock hauler couplers, clear deck contact, settle, delete, settle, unlock. Avoids gooseneck/pintle snap when cash payout deletes cargo.
-- Completion and target cleanup -----------------------------------------------------------------

local function cleanupTemporaryTarget(job, callback)
  local vehicleId = job and job.vehicleId
  local inventoryId = job and job.inventoryId
  if vehicleId then runtimeByVehicleId[vehicleId] = nil end

  local vehicle = vehicleId and getObjectByID(vehicleId)
  local haulerIds = vehicle and parts.targetVehicle.collectHaulerIdsNearTarget(vehicleId) or {}

  if job then
    job.vehicleId = nil
    job.inventoryId = nil
  end

  if not vehicleId and not inventoryId then
    if callback then callback() end
    return
  end

  parts.targetVehicle.setHaulerCouplerLock(haulerIds, true)
  parts.targetVehicle.clearTargetFromHaulerDeck(vehicle)

  core_jobsystem.create(function(jobHandle)
    jobHandle.sleep(0.2)
    parts.targetVehicle.deleteTemporaryTargetObject(job, vehicleId, inventoryId)
    jobHandle.sleep(0.15)
    parts.targetVehicle.setHaulerCouplerLock(haulerIds, false)
    if callback then callback() end
  end)
end

local promoteKeptVehicle = require('overhaul/jobs/recovery/handoff')(parts.targetVehicle, parts.persistence,
  function(vehicleId) runtimeByVehicleId[vehicleId] = nil end)

local function presentRecoveryCompletion(job, finalCash, finalXp, penalty, damageValue, keptInventoryId)
      shared.refreshTrackedRoute()
      local breakdown = parts.rewards.buildCompletionBreakdown(job, finalCash, finalXp, penalty)
      lastCompletion = {
        jobId = job.id,
        brand = job.brand,
        name = job.name,
        year = job.year,
        rewardType = job.rewardType,
        money = finalCash,
        xp = finalXp,
        penaltyPercent = math.floor(penalty * 100 + 0.5),
        damageValue = math.floor(damageValue + 0.5),
        keptInventoryId = keptInventoryId,
        breakdown = breakdown
      }
      showCompletionTasklist(breakdown, "Recovery Complete")
      parts.rewards.openRecoveryApp()
      ui_message(
        string.format("%s %s recovered.\nDamage penalty: %d%%%s",
          job.brand, job.name, lastCompletion.penaltyPercent,
          job.rewardType == "vehicle" and "\nThe vehicle is now yours." or string.format("\nPaid $%d", finalCash)),
        12, "Recovery Complete", "info")
      if overhaul_career_saveSystem then overhaul_career_saveSystem.saveCurrent() end
      M.requestState()
end

local function finishCompletion(job, finalConditions, isCurrent)
  if not isCurrent() then return end
  local generation = completionGeneration
  local penalty, damageValue = parts.rewards.damagePenalty(job, finalConditions)
  local multiplier = 1 - penalty
  local finalXp = math.max(0, math.floor((tonumber(job.baseSkillXp) or 0) * multiplier + 0.5))
  local finalCash = job.rewardType == "cash" and math.max(0, math.floor((tonumber(job.cashReward) or 0) * multiplier + 0.5)) or 0
  local rewardData = {[constants.SKILL_ATTRIBUTE] = {amount = finalXp}}
  if finalCash > 0 then rewardData.money = {amount = finalCash} end
  overhaul_career_economy_difficultyMode.scalePaymentRewardData(rewardData, {includeMoney = false})
  finalXp = rewardData[constants.SKILL_ATTRIBUTE] and rewardData[constants.SKILL_ATTRIBUTE].amount or finalXp
  local payoutVehicleId = be:getPlayerVehicleID(0)
  local payoutInventoryId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId
    and overhaul_career_garage_inventory.getInventoryIdFromVehicleId(payoutVehicleId)
  if payoutVehicleId == job.vehicleId or (payoutInventoryId and tostring(payoutInventoryId) == tostring(job.inventoryId)) then
    payoutVehicleId = nil
  end
  local function finalize(keptInventoryId)
    if not isCurrent() then return end
    if job.rewardType == "vehicle" and not keptInventoryId then
      job.completing = nil
      job.status = "active"
      ui_message("The recovered vehicle could not be transferred to your inventory.", 10, "Recovery", "warning")
      return
    end
    local paid, problem = overhaul_career_economy_payment.payout(require("overhaul/lib/finance/metadata").tagPayout({
      amount = rewardData.money and rewardData.money.amount,
      xp = {[constants.SKILL_ATTRIBUTE] = rewardData[constants.SKILL_ATTRIBUTE].amount},
      label = job.rewardType == "vehicle"
        and string.format("Recovered %s %s - vehicle awarded", job.brand, job.name)
        or string.format("Recovered %s %s - paid $%d", job.brand, job.name, finalCash),
      tags = {"gameplay", "reward", "offroadRecovery"},
      fullReward = true
    }, "activity:recovery", {vehicleObjectId = payoutVehicleId}))
    -- Refusal historically completed the contract; changing that needs a separate behavior fix.
    if paid ~= true then log("W", LOG_TAG, "Recovery payout refused: " .. tostring(problem))
    else recordJob({detail = tostring(job.brand or "") .. " " .. tostring(job.name or "Vehicle")
      .. (job.rewardType == "vehicle" and " / Vehicle awarded" or ""), money = finalCash}) end
    -- Settlement must retire the contract before coupler cleanup yields or a save runs.
    parts.offers.removeJobFromState(job)
    local function afterCleanup()
      if generation ~= completionGeneration then return end
      presentRecoveryCompletion(job, finalCash, finalXp, penalty, damageValue, keptInventoryId)
    end
    if job.rewardType == "cash" then
      cleanupTemporaryTarget(job, afterCleanup)
    else
      afterCleanup()
    end
  end
  if job.rewardType == "vehicle" then
    promoteKeptVehicle(job, finalConditions, isCurrent, finalize)
  else
    finalize(nil)
  end
end

local function completeJob(job)
  if not job or job.completing or job.status ~= "active" then return end
  job.completing = true
  local generation, vehicleId, inventoryId = completionGeneration, job.vehicleId, job.inventoryId
  local vehicle = vehicleId and getObjectByID(vehicleId)
  local stale = false
  local function isCurrent()
    if stale then return false end
    local current = completionGeneration == generation and currentMap == job.mapId
      and parts.offers.findJob(job.id) == job and job.completing == true
      and job.vehicleId == vehicleId and job.inventoryId == inventoryId
      and vehicle ~= nil and getObjectByID(vehicleId) == vehicle
    if not current then
      stale = true -- A rejected callback must not unlock a later completion attempt.
      if completionGeneration == generation and parts.offers.findJob(job.id) == job then
        job.completing = nil
      end
    end
    return current
  end
  overhaul_career_garage_inventory.updatePartConditions(vehicleId, inventoryId, function()
    if not isCurrent() then return end
    local record = overhaul_career_garage_inventory.getVehicles()[inventoryId]
    local finalConditions = deepcopy(record and record.partConditions or {})
    finishCompletion(job, finalConditions, isCurrent)
  end)
end

shared.refreshTrackedRoute = function(force)
  local mapState = currentMap and parts.offers.getMapState(currentMap)
  local job = mapState and parts.offers.findJob(mapState.trackedJobId)
  if not job or job.mapId ~= currentMap or job.status == "missing" then
    trackedRoute.clear()
    trackedRouteKey = nil
    trackedRouteActive = false
    return
  end
  local routeKey = tostring(job.id) .. ":" .. tostring(job.phase)
  if not force and trackedRouteActive and trackedRouteKey == routeKey and trackedRoute.isCurrent() then return end
  local pos = objectivePosition(job)
  if pos and core_groundMarkers then
    trackedRoute.set(pos, {clearPathOnReachingTarget = false})
    trackedRouteKey = routeKey
    trackedRouteActive = true
  end
end

local function updateJob(job)
  if job.mapId ~= currentMap or job.status ~= "active" then return end
  -- Completing jobs clear vehicleId before payout cleanup finishes.
  if job.completing then return end
  local vehicle = job.vehicleId and getObjectByID(job.vehicleId)
  if not vehicle then
    if job.vehicleId then runtimeByVehicleId[job.vehicleId] = nil end
    job.vehicleId = nil
    job.completing = nil
    shared.onTargetSpawnFailed(job, "despawned")
    return
  end
  local vehiclePos = vehicle:getPosition()
  -- Do not mark a contract ready for delivery just because the player walked up to its target. The target itself must be moved a meaningful distance from its spawn point first.
  if job.phase ~= "delivery" and job.status == "active" then
    local originalTargetPosition = parts.persistence.arrayToVec3(job.originalTargetPos or job.targetPos)
    local deltaX = vehiclePos.x - originalTargetPosition.x
    local deltaY = vehiclePos.y - originalTargetPosition.y
    local extracted = (deltaX * deltaX + deltaY * deltaY) >= (25 * 25)
    if extracted then
      job.phase = "delivery"
      shared.refreshTrackedRoute()
    end
  end
  if isInYardDropoff(job, vehiclePos) and vehicle:getVelocity():length() <= constants.DELIVERY_MAX_SPEED_MPS then
    completeJob(job)
  end
end

local function expireOffers()
  for index = #availableOffers, 1, -1 do
    if simMinutes >= (availableOffers[index].expiresAt or 0) then removeOfferAt(index) end
  end
end

-- Offer board and player actions ----------------------------------------------------------------

local function initializeBoard()
  local eligible = parts.offers.offersAvailableReason()
  if eligible and not boardEligible then
    boardEligible = true
    availableOffers = {}
    pendingOfferId = nil
    parts.offers.generateOffer()
    nextOfferAt = simMinutes + constants.OFFER_INTERVAL_MIN
  elseif not eligible and boardEligible then
    boardEligible = false
    availableOffers = {}
    pendingOfferId = nil
    nextOfferAt = nil
  end
end

local function yardChoicesForPending()
  local offer = pendingOfferId and parts.offers.findOffer(pendingOfferId)
  if not offer then return {} end
  local choices = {}
  for _, yard in ipairs(getOwnedRecoveryYards()) do
    local cash, distance = parts.rewards.fixedCashQuote(offer, yard)
    choices[#choices + 1] = {
      id = yard.id,
      name = yard.name,
      rewardType = offer.rewardType,
      cashReward = offer.rewardType == "cash" and cash or nil,
      distance = distance
    }
  end
  return choices
end

function M.getState()
  local eligible, reason, yards = parts.offers.offersAvailableReason()
  local mapState = currentMap and parts.offers.getMapState(currentMap)
  local offers, activeJobs, otherMapJobs = {}, {}, {}
  local showCashReward = yards and #yards == 1
  for _, offer in ipairs(availableOffers) do offers[#offers + 1] = parts.offers.offerUiData(offer, showCashReward) end
  table.sort(offers, function(a, b) return a.expiresIn < b.expiresIn end)
  for _, job in ipairs(mapState and mapState.jobs or {}) do activeJobs[#activeJobs + 1] = parts.offers.jobUiData(job) end
  for mapId, otherState in pairs(state.maps or {}) do
    if mapId ~= currentMap then
      for _, job in ipairs(otherState.jobs or {}) do otherMapJobs[#otherMapJobs + 1] = parts.offers.jobUiData(job) end
    end
  end
  return {
    mapId = currentMap,
    locked = not eligible,
    lockedReason = reason,
    skillLevel = parts.vehiclePool.getSkillLevel(),
    payoutBonusPercent = parts.vehiclePool.getPayoutBonus(parts.vehiclePool.getSkillLevel()),
    offers = offers,
    activeJobs = activeJobs,
    otherMapJobs = otherMapJobs,
    activeCount = #(mapState and mapState.jobs or {}),
    maxActive = constants.MAX_ACTIVE_PER_MAP,
    pendingOfferId = pendingOfferId,
    yardChoices = yardChoicesForPending(),
    lastCompletion = lastCompletion
  }
end

local function hasBoardContent()
  if next(availableOffers) then return true end
  for _, mapState in pairs(state.maps or {}) do
    if next(mapState.jobs or {}) then return true end
  end
  return false
end

function M.onUiScopeChanged(id, active)
  return scopeSubscriptions.set(uiScopes, id, active)
end

function M.requestState()
  if not scopeSubscriptions.listening(uiScopes) then return end
  hadUiContent = hasBoardContent()
  require("overhaul/lib/ui/statePush").send("updateOffroadRecoveryState", M.getState())
end

local function commitOffer(offer, yard)
  local cashReward, distance, payBreakdown, outboundDistance = parts.rewards.fixedCashQuote(offer, yard)
  local job = {
    id = parts.offers.nextContractId("job"),
    mapId = currentMap,
    spotName = offer.spotName,
    originalTargetPos = deepcopy(offer.targetPos),
    targetPos = deepcopy(offer.targetPos),
    targetRot = deepcopy(offer.targetRot),
    model = offer.model,
    configKey = offer.configKey,
    brand = offer.brand,
    name = offer.name,
    year = offer.year,
    mileage = offer.mileage,
    vehicleType = offer.vehicleType,
    recoveryTag = offer.recoveryTag,
    tierLabel = offer.tierLabel,
    payMultiplier = offer.payMultiplier,
    baseXp = offer.baseXp,
    vehicleValue = offer.vehicleValue,
    rewardType = offer.rewardType,
    cashReward = offer.rewardType == "cash" and cashReward or 0,
    payBreakdown = offer.rewardType == "cash" and payBreakdown or nil,
    routeDistance = distance,
    outboundRouteDistance = outboundDistance,
    difficultyFee = parts.rewards.recoveryDifficultyFee(offer),
    baseSkillXp = parts.rewards.fixedSkillXp(offer, distance),
    condition = offer.condition,
    missingWheelCount = offer.missingWheelCount,
    wheelSeed = offer.wheelSeed,
    yardId = yard.id,
    yardName = yard.name,
    deliverySpotName = yard.spotName,
    deliveryPos = parts.persistence.toVec3Array(yard.spot.pos),
    deliveryRot = parts.persistence.toQuatArray(yard.spot.rot or quat(0, 0, 0, 1)),
    phase = "pickup",
    status = "spawning",
    replaceOnSpawnFail = true
  }
  local mapState = parts.offers.getMapState(currentMap)
  mapState.jobs[#mapState.jobs + 1] = job
  mapState.trackedJobId = job.id
  local _, offerIndex = parts.offers.findOffer(offer.id)
  if offerIndex then removeOfferAt(offerIndex) end
  pendingOfferId = nil
  local started = spawnJobTarget(job, false)
  if started == false then return true end
  shared.refreshTrackedRoute()
  M.requestState()
  return true
end

function M.beginAcceptOffer(offerId)
  local offer = parts.offers.findOffer(offerId)
  if not offer or simMinutes >= (offer.expiresAt or 0) then
    M.requestState()
    return {accepted = false, reason = "Offer expired"}
  end
  if parts.offers.activeCount(currentMap) >= constants.MAX_ACTIVE_PER_MAP then
    return {accepted = false, reason = "This map already has three active recoveries"}
  end
  local eligible, reason = parts.offers.offersAvailableReason()
  if not eligible then return {accepted = false, reason = reason} end
  local yards = getOwnedRecoveryYards()
  if #yards == 1 then
    commitOffer(offer, yards[1])
    return {accepted = true}
  end
  pendingOfferId = offerId
  M.requestState()
  return {accepted = false, needsYard = true}
end

function M.selectRecoveryYard(yardId)
  local offer = pendingOfferId and parts.offers.findOffer(pendingOfferId)
  if not offer then return {accepted = false, reason = "Offer is no longer available"} end
  for _, yard in ipairs(getOwnedRecoveryYards()) do
    if yard.id == yardId then
      commitOffer(offer, yard)
      return {accepted = true}
    end
  end
  return {accepted = false, reason = "Recovery Yard is no longer owned"}
end

function M.cancelYardSelection()
  pendingOfferId = nil
  M.requestState()
end

function M.previewOffer(offerId)
  local offer = parts.offers.findOffer(offerId)
  if not offer then return false end
  local poiId = "offroadRecoveryOffer-" .. offer.id
  if freeroam_bigMapMode and freeroam_bigMapMode.enterBigMap then
    returnToOfferBoardAfterMap = true
    if gameplay_rawPois then gameplay_rawPois.clear() end
    freeroam_bigMapMode.enterBigMap({
      instant = true,
      autoSelectPoiId = poiId
    })
    return true
  end
  return false
end

local function onDeactivateBigMapCallback()
  if not returnToOfferBoardAfterMap then return end
  returnToOfferBoardAfterMap = false
  if extensions.ui_router then
    extensions.ui_router.navigate("phone-offroad-recovery")
  end
end

function M.trackJob(jobId)
  local job = parts.offers.findJob(jobId)
  if not job or job.mapId ~= currentMap then return false end
  parts.offers.getMapState(currentMap).trackedJobId = job.id
  shared.refreshTrackedRoute(true)
  M.requestState()
  return true
end

function M.abandonJob(jobId)
  local job = parts.offers.findJob(jobId)
  if not job then return false end
  -- Drop the contract from state immediately; soft-delete the world object async so hauler coupler locks can settle without blocking abandon.
  parts.offers.removeJobFromState(job)
  local function afterCleanup()
    shared.refreshTrackedRoute()
    M.requestState()
  end
  local cleanupOk, cleanupError = pcall(cleanupTemporaryTarget, job, afterCleanup)
  if not cleanupOk then
    -- A removed or broken vehicle mod must never prevent the contract itself from being abandoned and removed from the career save.
    log("W", LOG_TAG, "Recovery target cleanup failed during abandon: " .. tostring(cleanupError))
    afterCleanup()
  end
  return true
end

local function pruneUnspawnableOffers()
  for index = #availableOffers, 1, -1 do
    local offer = availableOffers[index]
    if parts.vehiclePool.isRememberedUnspawnable(offer.model, offer.configKey) then
      removeOfferAt(index)
    end
  end
end

local function refillOfferBoard()
  local eligible = parts.offers.offersAvailableReason()
  if eligible and parts.offers.offerCount() < constants.MAX_OFFERS then
    parts.offers.generateOffer()
  end
end

shared.onTargetSpawnFailed = function(job, reason, opts)
  opts = opts or {}
  if not job or job.skippingUnspawnable then return end
  job.skippingUnspawnable = true
  local lostAfterSpawn = reason == "destroyed" or reason == "despawned"
  if not lostAfterSpawn then
    local config = (job.vehicleSnapshot and job.vehicleSnapshot.config) or job.configKey
    parts.vehiclePool.rememberUnspawnable(job.model, config)
    pruneUnspawnableOffers()
  end
  log("W", LOG_TAG, string.format(
    "Recovery target %s for %s (%s): %s",
    lostAfterSpawn and "was lost" or "could not spawn",
    tostring(job.id), tostring(job.model), tostring(reason or "unknown")))

  local autoAdvance = job.replaceOnSpawnFail == true or opts.advance == true
  local yardId = job.yardId
  M.abandonJob(job.id)

  if autoAdvance and spawnAdvanceDepth < MAX_SPAWN_ADVANCE then
    spawnAdvanceDepth = spawnAdvanceDepth + 1
    local offer = parts.offers.generateOffer()
    local yard = findOwnedYard(yardId)
    if offer and yard then
      commitOffer(offer, yard)
    elseif not offer then
      refillOfferBoard()
    end
    spawnAdvanceDepth = spawnAdvanceDepth - 1
  else
    refillOfferBoard()
  end

  if spawnAdvanceDepth == 0 and not opts.silent then
    local hasReplacement = false
    for _, candidate in ipairs(parts.offers.getMapState(currentMap).jobs or {}) do
      if candidate.status == "spawning" or candidate.status == "active" or candidate.status == "paused" then
        hasReplacement = true
        break
      end
    end
    local lead = lostAfterSpawn and "Recovery target was lost." or "Recovery target couldn't spawn."
    if hasReplacement then
      ui_message(lead .. " Started the next contract.", 6, "Recovery", "warning")
    else
      ui_message(lead .. " The contract was cleared.", 6, "Recovery", "warning")
    end
    M.requestState()
  end
end

function M.clearCompletion()
  lastCompletion = nil
  clearTasklistTimer = nil
  guihooks.trigger("ClearTasklist")
  M.requestState()
end

function M.isContractTarget(vehicleId)
  return runtimeByVehicleId[tonumber(vehicleId)] ~= nil
end

function M.onOverhaulIsRecoveryCargo(vehicleId, answer)
  if not answer.isCargo then answer.isCargo = M.isContractTarget(vehicleId) end
end

function M.isContractInventoryId(inventoryId)
  if not inventoryId or not (overhaul_career_career and overhaul_career_career.isActive()) then return false end
  local record = overhaul_career_garage_inventory.getVehicles()[inventoryId]
  return record and record.offroadRecoveryContract == true
end

function M.blocksJobShifts(vehicleId)
  if M.isContractTarget(vehicleId) then return true end
  if not vehicleId or not (overhaul_career_career and overhaul_career_career.isActive()) then
    return false
  end
  return M.isContractInventoryId(overhaul_career_garage_inventory.getInventoryIdFromVehicleId(vehicleId))
end

local blockedPermissionTags = {
  interactRefuel = true,
  vehicleRepair = true,
  vehicleModification = true,
  partBuying = true,
  partSwapping = true,
  painting = true,
  tuning = true,
  vehicleStoring = true,
  vehicleSelling = true,
  vehicleLicensePlate = true,
  vehicleFavorite = true,
  returnLoanedVehicle = true,
  recoveryTowToGarage = true,
  recoveryTowToRoad = true
}

function M.onOverhaulCheckPermission(tags, permissions, additionalData)
  if not additionalData or not M.isContractInventoryId(additionalData.inventoryId) then return end
  for _, tag in ipairs(tags or {}) do
    if blockedPermissionTags[tag] then
      table.insert(permissions, {permission = "forbidden", label = "Contract targets must be recovered manually."})
      return
    end
  end
end

function M.onGetRawPoiListForLevel(levelIdentifier, elements)
  if levelIdentifier ~= currentMap then return end
  for _, offer in ipairs(availableOffers) do
    table.insert(elements, {
      id = "offroadRecoveryOffer-" .. offer.id,
      data = {type = "events", offroadRecoveryType = "offer", id = offer.id},
      markerInfo = {bigmapMarker = {
        pos = parts.persistence.arrayToVec3(offer.targetPos),
        icon = "tow",
        name = "Off-Road Recovery Offer",
        description = string.format("%s %s - %.1f km away", offer.brand, offer.name,
          (getPlayerPosition() and getPlayerPosition():distance(parts.persistence.arrayToVec3(offer.targetPos)) or 0) / 1000),
        cluster = false
      }}
    })
  end
  for _, job in ipairs(parts.offers.getMapState(currentMap).jobs or {}) do
    local pos = objectivePosition(job)
    if pos then
      table.insert(elements, {
        id = "offroadRecoveryJob-" .. job.id,
        data = {type = "events", offroadRecoveryType = "job", id = job.id},
        markerInfo = {bigmapMarker = {
          pos = pos,
          icon = "tow",
          name = string.format("Recovery: %s %s", job.brand, job.name),
          description = job.phase == "delivery" and ("Return to " .. job.yardName) or "Recover the stranded target",
          cluster = false
        }}
      })
    end
  end
end

-- Restore helpers -------------------------------------------------------------------------------

local function restoreCurrentMapJobs()
  local mapState = currentMap and parts.offers.getMapState(currentMap)
  local previousRuntime = runtimeByVehicleId
  runtimeByVehicleId = {}
  local jobs = {}
  for _, job in ipairs(mapState and mapState.jobs or {}) do
    jobs[#jobs + 1] = job
  end
  for _, job in ipairs(jobs) do
    job.mapId = currentMap
    -- Older builds cleared the inventory identity after paying, but saved the
    -- delivery contract during delayed cleanup. It cannot be paid a second time.
    if job.rewardType == "cash" and job.phase == "delivery"
        and job.status == "paused" and not job.inventoryId then
      parts.offers.removeJobFromState(job)
    else
      local existingVehicleId = job.inventoryId and overhaul_career_garage_inventory.getVehicleIdFromInventoryId(job.inventoryId)
      local inFlightVehicleId = job.status == "spawning" and job.vehicleId
        and previousRuntime[job.vehicleId] == job.id and getObjectByID(job.vehicleId) and job.vehicleId
      if not inFlightVehicleId then
        job.spawnPending = nil
        job.completing = nil
        job.skippingUnspawnable = nil
      end
      if inFlightVehicleId and not (existingVehicleId and getObjectByID(existingVehicleId)) then
        runtimeByVehicleId[inFlightVehicleId] = job.id
      elseif existingVehicleId and getObjectByID(existingVehicleId) then
        job.vehicleId = existingVehicleId
        runtimeByVehicleId[existingVehicleId] = job.id
        job.replaceOnSpawnFail = nil
        job.status = "active"
        parts.persistence.updateJobSnapshotFromInventory(job)
      else
        job.vehicleId = nil
      end
      if job.status == "missing" then
        shared.onTargetSpawnFailed(job, "savedMissing", {silent = true})
      elseif not job.vehicleId then
        job.status = "paused"
        spawnJobTarget(job, job.vehicleSnapshot ~= nil)
      end
    end
  end
  shared.refreshTrackedRoute(true)
end

local function worldReady()
  completionGeneration = completionGeneration + 1
  local newMap = getCurrentLevelIdentifier()
  if not newMap then return end
  if currentMap and currentMap ~= newMap then
    availableOffers = {}
    pendingOfferId = nil
  end
  currentMap = newMap
  sitesCache, sitesCacheMap = nil, nil
  facilitySitesCache, facilitySitesCacheMap = nil, nil
  routeDistanceCache = {}
  boardTimer = BOARD_REFRESH_SECONDS
  dropoffZonesByYardId = {}
  vehiclePoolCache, vehiclePoolSkillLevel = nil, nil
  availableOffers = {}
  pendingOfferId = nil
  boardEligible = false
  nextOfferAt = nil
  restoreCurrentMapJobs()
  M.requestState()
end

-- Per-frame update ------------------------------------------------------------------------------

local function onUpdate(dtReal, dtSim)
  if not initialized or not (overhaul_career_career and overhaul_career_career.isActive()) then return end
  simMinutes = simMinutes + math.max(tonumber(dtSim) or 0, 0) / 60
  updateTimer = updateTimer + (tonumber(dtSim) or 0)
  uiTimer = uiTimer + (tonumber(dtReal) or 0)
  if clearTasklistTimer then
    clearTasklistTimer = clearTasklistTimer - math.max(tonumber(dtReal) or 0, 0)
    if clearTasklistTimer <= 0 then
      clearTasklistTimer = nil
      guihooks.trigger("ClearTasklist")
    end
  end
  if pendingCareerSave then
    pendingCareerSave.elapsed = pendingCareerSave.elapsed + math.max(tonumber(dtReal) or 0, 0)
    if pendingCareerSave.elapsed >= constants.SAVE_TIMEOUT_S then finishCareerSave(true) end
  end
  boardTimer = boardTimer + math.max(tonumber(dtReal) or 0, 0)
  if boardTimer >= BOARD_REFRESH_SECONDS then
    boardTimer = 0
    initializeBoard()
  end
  expireOffers()
  if boardEligible and parts.offers.offerCount() < constants.MAX_OFFERS and nextOfferAt and simMinutes >= nextOfferAt then
    parts.offers.generateOffer()
    nextOfferAt = simMinutes + constants.OFFER_INTERVAL_MIN
  end
  if updateTimer >= 0.5 then
    updateTimer = 0
    local jobs = {}
    for _, job in ipairs(currentMap and parts.offers.getMapState(currentMap).jobs or {}) do
      jobs[#jobs + 1] = job
    end
    for _, job in ipairs(jobs) do
      if job.status == "missing" then
        shared.onTargetSpawnFailed(job, "missing", {advance = true})
      else
        updateJob(job)
      end
    end
    if trackedRouteActive and core_groundMarkers
        and not core_groundMarkers.currentlyHasTarget() then shared.refreshTrackedRoute() end
  end
  if uiTimer >= 1 then
    uiTimer = 0
    if scopeSubscriptions.listening(uiScopes) then
      local hasContent = hasBoardContent()
      -- The last populated board needs one empty update before idle work stops.
      if hasContent or hadUiContent then
        require("overhaul/lib/ui/statePush").refresh("updateOffroadRecoveryState", M.getState())
      end
      hadUiContent = hasContent
    end
  end
end

-- Lifecycle -------------------------------------------------------------------------------------

local function onWorldReadyState(worldReadyState)
  if worldReadyState == 2 and overhaul_career_career and overhaul_career_career.isActive() then worldReady() end
end

local function onExtensionLoaded()
  math.randomseed(os.time())
  parts.vehiclePool.loadFilters()
  if overhaul_career_career and overhaul_career_career.isActive() then
    if loadState() then
      currentMap = getCurrentLevelIdentifier()
      if currentMap then worldReady() end
    end
  end
  initialized = true
end

local function onOverhaulModulesActivated()
  if loadState() then
    currentMap = getCurrentLevelIdentifier()
    if currentMap then worldReady() end
  end
  initialized = true
end

local function onOverhaulActive(active)
  if active == false then
    completionGeneration = completionGeneration + 1
    if currentMap then
      for _, job in ipairs(parts.offers.getMapState(currentMap).jobs or {}) do
        job.completing = nil
      end
    end
    uiScopes = {}
    hadUiContent = false
    stateLoaded = false
    loadedProfileName = nil
    parts.persistence.clearSessionDamage()
    lastCompletion = nil
    clearTasklistTimer = nil
  end
end

local function onClientEndMission()
  completionGeneration = completionGeneration + 1
  uiScopes = {}
  hadUiContent = false
  if currentMap then
    for _, job in ipairs(parts.offers.getMapState(currentMap).jobs or {}) do
      if job.status ~= "missing" then
        parts.persistence.captureExitState(job)
        job.status = "paused"
      end
      job.vehicleId = nil
      job.spawnPending = nil
      job.completing = nil
    end
  end
  runtimeByVehicleId = {}
  availableOffers = {}
  pendingOfferId = nil
  boardEligible = false
  trackedRoute.clear()
  trackedRouteKey = nil
  trackedRouteActive = false
end

local function onOverhaulSaveCurrentProfileAsyncStart()
  saveRegistered = false
  saveGenerationToken = nil
  if hasSpawnedCurrentMapJob() then
    saveGenerationToken = overhaul_career_saveSystem.registerAsyncSaveExtension(constants.ASYNC_SAVE_EXTENSION)
    saveRegistered = true
  end
end

local function onOverhaulSaveCurrentProfile(savePath, _, writer)
  writer = writer or overhaul_career_saveSystem.getSaveWriter()
  if not stateLoaded then loadState(writer) end
  if saveRegistered then
    beginCareerSave(savePath, writer)
  else
    stageDamageSnapshots(parts.persistence.currentSavePath(), savePath, writer)
    saveStateToPath(savePath, writer)
  end
end

local function onOverhaulVehicleSaveFinished(savePath)
  local pending = pendingCareerSave
  if not pending or pending.savePath ~= savePath then return end
  for _, entry in pairs(pending.jobs) do parts.persistence.updateJobSnapshotFromInventory(entry.job) end
  pending.inventoryReady = true
  finishCareerSave(false)
end

local function onExtensionUnloaded()
  completionGeneration = completionGeneration + 1
  uiScopes = {}
  hadUiContent = false
  if pendingCareerSave then finishCareerSave(true) end
  recoverySave.dispose()
  stateLoaded = false
  loadedProfileName = nil
  parts.persistence.clearSessionDamage()
  trackedRoute.clear()
  trackedRouteKey = nil
  trackedRouteActive = false
end

local function onVehicleDestroyed(vehicleId)
  local jobId = runtimeByVehicleId[vehicleId]
  if not jobId then return end
  local job = parts.offers.findJob(jobId)
  runtimeByVehicleId[vehicleId] = nil
  if job and not job.completing and not job.skippingUnspawnable then
    job.vehicleId = nil
    shared.onTargetSpawnFailed(job, "destroyed")
  end
end

-- Game hooks ------------------------------------------------------------------------------------

M.onWorldReadyState = onWorldReadyState
M.onExtensionLoaded = onExtensionLoaded
M.onOverhaulModulesActivated = onOverhaulModulesActivated
M.onOverhaulActive = onOverhaulActive
M.onClientEndMission = onClientEndMission
M.onOverhaulSaveCurrentProfileAsyncStart = onOverhaulSaveCurrentProfileAsyncStart
M.onOverhaulSaveCurrentProfile = onOverhaulSaveCurrentProfile
M.onOverhaulBeforeSetProfile = function()
  completionGeneration = completionGeneration + 1
  uiScopes = {}
  hadUiContent = false
  stateLoaded = false
  loadedProfileName = nil
end
M.onOverhaulVehicleSaveFinished = onOverhaulVehicleSaveFinished
M.onExtensionUnloaded = onExtensionUnloaded
M.onVehicleDestroyed = onVehicleDestroyed
M.onDeactivateBigMapCallback = onDeactivateBigMapCallback
M.onUpdate = onUpdate

M.activity = require('overhaul/jobs/recovery/activity')(M)

return M
