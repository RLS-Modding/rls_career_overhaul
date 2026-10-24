-- Tuning shop save files: business info, customer jobs and vehicle metadata.
-- Read: config, paths, vehicle and race lookups, info file, initialization, XP, jobs file, then the exports.
local businessSaveState = require("overhaul/lib/business/saveState")
local raceDataCatalog = require('overhaul/lib/events/raceDataCatalog')
local levelData = require('overhaul/lib/world/levelData')

local config = {
  defaultCommuteSeconds = 120,
  defaultDecimalPlaces = 1,
  defaultEventReward = 0,
  defaultYear = 2000,
  defaultMinImprovement = 1.1,
  defaultMaxImprovement = 1.2,
  defaultMinPayout = 20000,
  defaultMaxPayout = 30000,
  rewardRounding = 1000,
  mileageMinMiles = 20000,
  mileageMaxMiles = 120000,
  metersPerMile = 1609.34,
}

-- Paths -------------------------------------------------------------------------------------------

-- Business files live under the current save slot; no path exists outside an active career.
local function getBusinessFilePath(businessId, fileName)
  if not overhaul_career_career.isActive() then
    return nil
  end
  local _, currentSavePath = overhaul_career_saveSystem.getCurrentProfile()
  if not currentSavePath then
    return nil
  end
  return businessSaveState.businessFilePath(businessId .. "", fileName, currentSavePath .. "")
end

-- Vehicle lookup helpers --------------------------------------------------------------------------

-- Config keys may carry a folder and extension ("pickup/d15.json"); the catalog uses the bare name.
local function normalizeConfigKey(configKey)
  if not configKey then
    return nil
  end
  if configKey:find("/") then
    local segments = {}
    for segment in configKey:gmatch("[^/]+") do
      table.insert(segments, segment)
    end
    if #segments > 0 then
      local filename = segments[#segments]
      local name = filename:match("^(.+)%.(.+)$")
      return name or filename
    end
  else
    local name = configKey:match("^(.+)%.(.+)$")
    return name or configKey
  end
  return configKey
end

-- Builds the same row shape as the eligible list from the core model and config when that list has no match.
local function coreVehicleInfo(modelKey, configKey, normalizedConfigKey)
  local model = core_vehicles.getModel(modelKey)
  if not model or tableIsEmpty(model) then
    return nil
  end
  local configInfo = core_vehicles.getConfig(modelKey, normalizedConfigKey)
  if not configInfo then
    return nil
  end
  return {
    model_key = modelKey,
    key = configKey,
    Name = configInfo.Name or modelKey,
    Brand = configInfo.Brand or "",
    Years = configInfo.Years or {
      min = 1990,
      max = 2025
    },
    preview = configInfo.preview
  }
end

local function getModelInfo(modelKey)
  if not modelKey then
    return nil
  end

  local modelData = core_vehicles.getModel(modelKey)
  if modelData and modelData.model then
    return {
      name = modelData.model.Name or modelKey,
      brand = modelData.model.Brand or ""
    }
  end

  return {
    name = modelKey,
    brand = ""
  }
end

-- Race identifiers --------------------------------------------------------------------------------

-- New jobs keep the exact data id. Historical type aliases live on the race proof record.
local function convertRaceIdentifierToType(raceIdentifier) return raceIdentifier end
local function convertRaceTypeToIdentifier(raceType) return raceType end

local function extractRaceData(raceIdentifier, raceData)
  if not raceIdentifier or not raceData or not raceData.races then return nil end
  if raceData.races[raceIdentifier] then return raceData.races[raceIdentifier] end
  for _, race in pairs(raceData.races) do
    local route = race.altRoute
    if type(route) == "table" and type(route.businessProof) == "table" and route.businessProof.eventId == raceIdentifier then return route end
  end
end

local TIME_SECONDS = {s = 1, min = 60, ms = 0.001}

local function businessProof(race)
  local proof = race and race.businessProof
  if type(proof) ~= "table" or proof.supported ~= true then return nil end
  local valid = TIME_SECONDS[proof.timeUnit] and TIME_SECONDS[proof.legacyTargetTimeUnit]
  for _, key in ipairs({"eventId", "legacyRaceType"}) do
    if proof[key] ~= nil and (type(proof[key]) ~= "string" or proof[key] == "") then valid = false end
  end
  if proof.leaderboardLabels ~= nil then
    if type(proof.leaderboardLabels) ~= "table" or #proof.leaderboardLabels == 0 then valid = false else
      for _, label in ipairs(proof.leaderboardLabels) do
        if type(label) ~= "string" or label == "" then valid = false end
      end
    end
  end
  if not valid then
    log("W", "tuningShop", "Ignoring invalid businessProof data")
    return nil
  end
  return proof
end

local function getSkillTreeUpgradeCount(businessId)
  if not businessId then
    return 0
  end

  local upgradeCount = 0
  for _, nodeId in ipairs({"more-complicated", "more-complicated-ii"}) do
    if overhaul_career_business_skillTree.getNodeProgress(businessId, "quality-of-life", nodeId) > 0 then
      upgradeCount = upgradeCount + 1
    end
  end
  return upgradeCount
end

-- Legacy import helpers ---------------------------------------------------------------------------

-- An old xp.json wins over the info file's xp, unless the business was sold and reset.
local function restoreLegacyXP(businessId, soldReset, info)
  local xpPath = not soldReset and getBusinessFilePath(businessId, "xp.json") or nil
  if xpPath and FS:fileExists(xpPath) then
    local xpData = jsonReadFile(xpPath) or {}
    info.xp = tonumber(xpData.xp) or info.xp or 0
    return true
  end
  if not info.xp then
    info.xp = 0
  end
  return false
end

local function restoreLegacySelections(businessId, soldReset, info)
  local needsSave = false
  local selectionsPath = not soldReset and getBusinessFilePath(businessId, "selections.json") or nil
  if selectionsPath and FS:fileExists(selectionsPath) then
    local selectionsData = jsonReadFile(selectionsPath) or {}
    info.selections = {
      brand = selectionsData.brand,
      raceType = selectionsData.raceType,
      blacklist = selectionsData.blacklist,
      notificationList = selectionsData.notificationList,
      managerBlacklist = selectionsData.managerBlacklist
    }
    needsSave = true
  elseif not info.selections then
    info.selections = {}
  end

  for _, listKey in ipairs({"blacklist", "notificationList", "managerBlacklist"}) do
    info.selections[listKey] = info.selections[listKey] or {}
  end
  return needsSave
end

local function restoreLegacyOperatingCost(businessId, soldReset, info)
  local operatingCostPath = not soldReset and getBusinessFilePath(businessId, "operatingCost.json") or nil
  if operatingCostPath and FS:fileExists(operatingCostPath) then
    local costData = jsonReadFile(operatingCostPath) or {}
    info.operatingCost = {
      elapsed = tonumber(costData.elapsed) or 0,
      lastChargeTime = tonumber(costData.lastChargeTime) or nil
    }
    return true
  end
  if not info.operatingCost then
    info.operatingCost = { elapsed = 0, lastChargeTime = nil }
  end
  return false
end

-- Facility race info ------------------------------------------------------------------------------

local function restoreFacilityMapId(info, currentMap, facility)
  if info.mapId then info.mapId = levelData.resolveAlias("map", info.mapId) end
  if currentMap and facility and (not info.mapId or info.mapId == "") then
    log("I", "initializeBusinessData: setting mapId from " .. tostring(info.mapId) .. " to " .. tostring(currentMap))
    info.mapId = currentMap
    return true
  end
  log("I", "initializeBusinessData: NOT setting mapId - currentMap=" .. tostring(currentMap) .. ", facility=" .. tostring(facility ~= nil) .. ", info.mapId=" .. tostring(info.mapId))
  return false
end

local function restoreFacilityRaces(info, facility)
  if facility and type(facility.races) == "table" then
    info.races = deepcopy(facility.races)
    return true
  end
  return false
end

-- Fills race data for the facility's races from the level's race_data.json.
local function restoreFacilityRaceData(info, currentMap, facility)
  local isEmptyRaceData = not info.raceData or not next(info.raceData)
  if not (currentMap and facility and isEmptyRaceData) then
    return false
  end
  if not (facility.races and #facility.races > 0) then
    return false
  end

  local raceDataPath = "levels/" .. currentMap .. "/race_data.json"
  local raceData = raceDataCatalog.read(raceDataPath) or {}
  if not (raceData and raceData.races) then
    return false
  end

  info.raceData = {}
  for _, raceIdentifier in ipairs(facility.races) do
    local fullRace = extractRaceData(raceIdentifier, raceData)
    if fullRace then
      info.raceData[raceIdentifier] = fullRace
    end
  end
  return true
end

local function restoreFacilityRaceInfo(info, currentMap, facility)
  local needsSave = restoreFacilityMapId(info, currentMap, facility)
  needsSave = restoreFacilityRaces(info, facility) or needsSave
  needsSave = restoreFacilityRaceData(info, currentMap, facility) or needsSave
  return needsSave
end

-- Job ID helpers ----------------------------------------------------------------------------------

-- Saved IDs may be strings; only numeric IDs take part in the counter and the duplicate repair.
local function numericJobId(job)
  if not job.jobId then
    return nil
  end
  local jId = tonumber(job.jobId) or job.jobId
  if type(jId) == "number" then
    return jId
  end
  return nil
end

-- Active jobs come before new jobs, the order the save file uses.
local function jobListsOf(businessJobs)
  return { businessJobs.active or {}, businessJobs.new or {} }
end

-- Largest numeric job ID across all businesses, and how many jobs use each ID.
local function scanJobIds(businessJobs)
  local maxJobId = 0
  local usedIds = {}
  for _, jobs in pairs(businessJobs) do
    for _, list in ipairs(jobListsOf(jobs)) do
      for _, job in ipairs(list) do
        local jId = numericJobId(job)
        if jId then
          if jId > maxJobId then
            maxJobId = jId
          end
          usedIds[jId] = (usedIds[jId] or 0) + 1
        end
      end
    end
  end
  return maxJobId, usedIds
end

-- Gives every extra copy of a duplicated ID the next free ID; returns the next free ID and the renumbering.
local function repairDuplicateJobIds(businessJobs, usedIds, firstFreeId)
  local nextId = firstFreeId
  local idMapping = {}
  for businessId, jobs in pairs(businessJobs) do
    for _, list in ipairs(jobListsOf(jobs)) do
      for _, job in ipairs(list) do
        local jId = numericJobId(job)
        if jId and usedIds[jId] and usedIds[jId] > 1 then
          local oldId = jId
          job.jobId = nextId
          idMapping[businessId] = idMapping[businessId] or {}
          idMapping[businessId][oldId] = nextId
          usedIds[nextId] = 1
          nextId = nextId + 1
          usedIds[jId] = usedIds[jId] - 1
        end
      end
    end
  end
  return nextId, idMapping
end

-- Vehicles tagged with a renumbered job follow the new ID.
local function renumberFleetJobs(idMapping)
  for businessId, mapping in pairs(idMapping) do
    local vehicles = overhaul_career_business_fleet.getBusinessVehicles(businessId)
    if vehicles then
      for _, vehicle in ipairs(vehicles) do
        if vehicle.jobId then
          local vJobId = tonumber(vehicle.jobId) or vehicle.jobId
          if mapping[vJobId] then
            -- getBusinessVehicles returns live rows; storeVehicle would duplicate them.
            vehicle.jobId = mapping[vJobId]
          end
        end
      end
    end
  end
end

-- Field regeneration helpers ----------------------------------------------------------------------

-- Power and weight from the catalog row, falling back to its aggregate ranges; missing values read as 0.
local function vehicleStats(vehicleInfo)
  local power = vehicleInfo.Power
  if not power and vehicleInfo.aggregates and vehicleInfo.aggregates.Power then
    power = vehicleInfo.aggregates.Power.min or vehicleInfo.aggregates.Power.max
  end
  local weight = vehicleInfo.Weight
  if not weight and vehicleInfo.aggregates and vehicleInfo.aggregates.Weight then
    weight = vehicleInfo.aggregates.Weight.min or vehicleInfo.aggregates.Weight.max
  end
  return power or 0, weight or 0
end

local function modelYear(modelKey)
  if overhaul_dev_raceDataCollection and overhaul_dev_raceDataCollection.getYearFromModel then
    return overhaul_dev_raceDataCollection.getYearFromModel(modelKey)
  end
  return config.defaultYear
end

-- Tier from the shop's skill upgrades, capped by the job's own tier and the race's level count.
local function levelTier(job, levelCount, businessId)
  local upgradeCount = getSkillTreeUpgradeCount(businessId)
  local maxAvailableLevel = math.min(levelCount, upgradeCount + 1)
  local tier = math.min(maxAvailableLevel, job.tier or 1)
  return math.max(1, tier)
end

-- Saves from before the terms were stored get mid-range terms.
local function fillMissingTerms(job, levelData, baseTime)
  if job.targetTime and job.reward then
    return
  end
  local minImprovement = levelData.minImprovement or config.defaultMinImprovement
  local maxImprovement = levelData.maxImprovement or config.defaultMaxImprovement
  local divisor = minImprovement + (maxImprovement - minImprovement) / 2
  job.targetTime = baseTime / divisor
  job.reward = math.floor(((levelData.minPayout or config.defaultMinPayout)
    + (levelData.maxPayout or config.defaultMaxPayout)) / 2 / config.rewardRounding) * config.rewardRounding
end

-- Sets the tier and its terms when the race defines tuning levels.
local function applyRaceLevel(job, raceObj, baseTime, businessId)
  if not raceObj then
    return
  end
  local tuningShopConfig = raceObj.tuningShop or {}
  local levels = tuningShopConfig.levels or {}
  if #levels == 0 then
    return
  end
  local tier = levelTier(job, #levels, businessId)
  local levelData = levels[tier]
  if not levelData then
    return
  end
  fillMissingTerms(job, levelData, baseTime)
  job.tier = tier
  job.decimalPlaces = tuningShopConfig.decimalPlaces or config.defaultDecimalPlaces
  job.commuteSeconds = tuningShopConfig.commute or tuningShopConfig.communte or config.defaultCommuteSeconds
  job.eventReward = raceObj.reward or 0
end

local function fillCommuteAndReward(job)
  if not job.commuteSeconds then
    job.commuteSeconds = config.defaultCommuteSeconds
  end
  if not job.eventReward then
    job.eventReward = config.defaultEventReward
  end
end

-- Saves without a mileage get a random one, drawn after the other fields are set.
local function assignMileage(job)
  if job.mileage then
    return
  end
  local mileageMiles = math.random(config.mileageMinMiles, config.mileageMaxMiles)
  job.mileage = mileageMiles * config.metersPerMile
end

-- Job reading helpers -----------------------------------------------------------------------------

local function restoreJobId(job)
  if job.jobId then
    job.jobId = tonumber(job.jobId) or job.jobId
  end
end

local function findJobIn(list, jobId)
  for _, job in ipairs(list or {}) do
    local jId = tonumber(job.jobId) or job.jobId
    if jId == jobId then
      return job
    end
  end
  return nil
end

-- Job writing helpers -----------------------------------------------------------------------------

local function minimizeOptionalFields(job, minimal)
  for _, field in ipairs({"remainingLifetime", "vehicleConfig", "raceType", "raceId", "proofVersion", "targetTimeUnit", "timeUnit", "tier"}) do
    if job[field] then
      minimal[field] = job[field]
    end
  end
  if tonumber(job.reward) then
    minimal.reward = tonumber(job.reward)
  end
  if tonumber(job.targetTime) then
    minimal.targetTime = tonumber(job.targetTime)
  end
  if tonumber(job.mileage) then
    minimal.mileage = tonumber(job.mileage)
  end
end

-- Only an active job keeps its acceptance, tech, lock and build state.
local function minimizeActiveFields(job, minimal)
  for _, field in ipairs({"acceptedTime", "techAssigned", "locked"}) do
    if job[field] then
      minimal[field] = job[field]
    end
  end
  if job.completionPartHash and job.completionPartHash ~= "" then
    minimal.completionPartHash = job.completionPartHash
  end
  if job.buildInvalidated then
    minimal.buildInvalidated = true
  end
end

local function minimizeJob(job)
  local minimal = {
    jobId = job.jobId,
    status = job.status
  }
  minimizeOptionalFields(job, minimal)
  if job.status == "active" then
    minimizeActiveFields(job, minimal)
  end
  return minimal
end

local function minimizeJobList(list)
  local minimized = {}
  for _, job in ipairs(list or {}) do
    table.insert(minimized, minimizeJob(job))
  end
  return minimized
end

local installer = {}

function installer.new(inputs)
  -- Inputs --------------------------------------------------------------------------------------
  local shop = inputs.shop
  local parts = inputs.parts

  -- Vehicle lookup ------------------------------------------------------------------------------

  -- The eligible list is expensive to build, so the first lookup fills it and later ones reuse it.
  local function eligibleVehicleCache()
    if not shop.vehicleInfoCache then
      shop.vehicleInfoCache = util_configListGenerator.getEligibleVehicles(false, false) or {}
    end
    return shop.vehicleInfoCache
  end

  local function findEligibleVehicle(modelKey, configKey, normalizedConfigKey)
    for _, vehicleInfo in ipairs(eligibleVehicleCache()) do
      if vehicleInfo.model_key == modelKey then
        local vehicleKey = normalizeConfigKey(vehicleInfo.key)
        if vehicleInfo.key == configKey or vehicleKey == normalizedConfigKey or vehicleInfo.key == normalizedConfigKey then
          return vehicleInfo
        end
      end
    end
    return nil
  end

  local function getVehicleInfo(modelKey, configKey)
    if not modelKey or not configKey then
      return nil
    end

    local normalizedConfigKey = normalizeConfigKey(configKey)

    local vehicleInfo = findEligibleVehicle(modelKey, configKey, normalizedConfigKey)
    if vehicleInfo then
      return vehicleInfo
    end

    return coreVehicleInfo(modelKey, configKey, normalizedConfigKey)
  end

  -- Info file -----------------------------------------------------------------------------------

  local function loadBusinessInfo(businessId)
    businessId = parts.garage.normalizeBusinessId(businessId)
    if not businessId then
      return nil
    end

    local filePath = getBusinessFilePath(businessId, "info.json")
    if not filePath then
      return nil
    end

    local data = jsonReadFile(filePath) or {}
    return {
      mapId = data.mapId,
      xp = tonumber(data.xp) or 0,
      races = data.races or {},
      raceData = data.raceData or {},
      selections = data.selections or {},
      kitInstallLocks = data.kitInstallLocks,
      operatingCost = data.operatingCost or { elapsed = 0, lastChargeTime = nil }
    }
  end

  local function saveBusinessInfo(businessId, currentSavePath, infoData, writer)
    businessId = parts.garage.normalizeBusinessId(businessId)
    if not businessId or not infoData or not currentSavePath then
      log("E", "saveBusinessInfo: invalid params - businessId=" .. tostring(businessId) .. ", infoData=" .. tostring(infoData ~= nil) .. ", currentSavePath=" .. tostring(currentSavePath))
      return
    end

    log("I", "saveBusinessInfo: saving businessId=" .. tostring(businessId) .. ", mapId=" .. tostring(infoData.mapId) .. ", xp=" .. tostring(infoData.xp))

    local filePath = businessSaveState.businessFilePath(businessId .. "", "info.json", currentSavePath .. "")

    writer = writer or overhaul_career_saveSystem.getSaveWriter()
    local dirPath = string.match(filePath, "^(.*)/[^/]+$")
    if dirPath and not writer.exists(dirPath) then
      writer.mkdir(dirPath)
    end

    overhaul_career_saveSystem.jsonWriteFileSafe(filePath, infoData, true)
    log("I", "saveBusinessInfo: wrote to " .. filePath)
  end

  -- Legacy imports ------------------------------------------------------------------------------

  -- Canonical locks already in the info file win; the legacy kit-lock file only fills an empty slot.
  local function restoreKitInstallLocks(businessId, soldReset, info)
    local needsSave = false
    local kitsModule = inputs.getTuningShopKits()
    if not info.kitInstallLocks then
      local oldLocksPath = not soldReset and kitsModule.getKitInstallLocksPath(businessId) or nil
      if oldLocksPath and FS:fileExists(oldLocksPath) then
        local locksData = jsonReadFile(oldLocksPath) or {}
        info.kitInstallLocks = locksData.locks or {}
        needsSave = true
      elseif not info.kitInstallLocks then
        info.kitInstallLocks = {}
      end
    elseif not info.kitInstallLocks then
      info.kitInstallLocks = {}
    end
    return needsSave
  end

  local function restoreLegacyInfoFiles(businessId, soldReset, info)
    local needsSave = restoreLegacyXP(businessId, soldReset, info)
    needsSave = restoreLegacySelections(businessId, soldReset, info) or needsSave
    needsSave = restoreLegacyOperatingCost(businessId, soldReset, info) or needsSave
    needsSave = restoreKitInstallLocks(businessId, soldReset, info) or needsSave
    return needsSave
  end

  -- Initialization ------------------------------------------------------------------------------

  -- A business set up earlier this session only needs its map info cache rebuilt if it is missing.
  local function reuseInitializedBusiness(businessId)
    log("I", "initializeBusinessData: already initialized, loading cache")
    if shop.cachedBusinessMapInfo[businessId] then
      log("I", "initializeBusinessData: cache already exists, mapId=" .. tostring(shop.cachedBusinessMapInfo[businessId].mapId))
      return
    end

    local existingInfo = loadBusinessInfo(businessId)
    if not existingInfo then
      log("W", "initializeBusinessData: existingInfo is nil")
      return
    end
    log("I", "initializeBusinessData: loaded existing info, mapId=" .. tostring(existingInfo.mapId))
    shop.cachedBusinessMapInfo[businessId] = {
      mapId = existingInfo.mapId,
      races = existingInfo.races,
      raceData = existingInfo.raceData
    }
  end

  -- Publishes the restored info to the shop caches and marks the business initialized.
  local function publishBusinessInfo(businessId, info)
    shop.businessXP[businessId] = info.xp
    shop.businessSelections[businessId] = info.selections
    shop.operatingCostTimers[businessId] = info.operatingCost

    local kitsModule = inputs.getTuningShopKits()
    kitsModule.setKitInstallLocksFromData(businessId, info.kitInstallLocks)

    shop.cachedRaceDataByBusiness[businessId] = nil

    shop.cachedBusinessMapInfo[businessId] = {
      mapId = info.mapId,
      races = info.races,
      raceData = info.raceData
    }
    log("I", "initializeBusinessData: cached mapInfo, mapId=" .. tostring(info.mapId))

    shop.initializedBusinesses[businessId] = true
    shop.soldResetBusinesses[businessId] = nil
  end

  local function initializeBusinessData(businessId)
    businessId = parts.garage.normalizeBusinessId(businessId)
    if not businessId then
      log("E", "initializeBusinessData: businessId is nil after normalize")
      return
    end

    log("I", "initializeBusinessData: called for businessId=" .. tostring(businessId))

    if shop.initializedBusinesses[businessId] then
      reuseInitializedBusiness(businessId)
      return
    end

    local soldReset = shop.soldResetBusinesses[businessId] == true
    local info = (not soldReset and loadBusinessInfo(businessId)) or {}
    log("I", "initializeBusinessData: loaded info, mapId=" .. tostring(info.mapId) .. ", xp=" .. tostring(info.xp))

    local currentMap = getCurrentLevelIdentifier()
    log("I", "initializeBusinessData: currentMap=" .. tostring(currentMap))

    local facility = overhaul_world_facilities.getFacility("tuningShop", businessId)
    log("I", "initializeBusinessData: facility=" .. tostring(facility ~= nil) .. ", facility.races=" .. tostring(facility and facility.races))

    local needsSave = restoreLegacyInfoFiles(businessId, soldReset, info)
    needsSave = restoreFacilityRaceInfo(info, currentMap, facility) or needsSave
    if needsSave then
      log("I", "initializeBusinessData: info migrated in memory, mapId=" .. tostring(info.mapId))
    end

    publishBusinessInfo(businessId, info)
  end

  -- Race prediction -----------------------------------------------------------------------------

  local function loadRaceData(businessId)
    local normalizedBusinessId = businessId and parts.garage.normalizeBusinessId(businessId) or nil
    if not normalizedBusinessId then
      return {}
    end

    initializeBusinessData(normalizedBusinessId)

    if shop.cachedRaceDataByBusiness[normalizedBusinessId] then
      return shop.cachedRaceDataByBusiness[normalizedBusinessId]
    end

    local info = shop.cachedBusinessMapInfo[normalizedBusinessId] or loadBusinessInfo(normalizedBusinessId)
    if info and info.mapId and type(info.races) == "table" then
      local current = raceDataCatalog.read("levels/" .. info.mapId .. "/race_data.json")
      if not current then log("W", "tuningShop", "Local race proof data unavailable on " .. info.mapId) end
      local races = {}
      for _, id in ipairs(info.races or {}) do
        local race = extractRaceData(id, current)
        if race then
          races[id] = race
          if not race.businessProof then log("W", "tuningShop", "Race proof unavailable for " .. id .. " on " .. info.mapId) end
        elseif info.raceData and info.raceData[id] then
          races[id] = deepcopy(info.raceData[id])
          races[id].businessProof = nil
        end
      end
      shop.cachedRaceDataByBusiness[normalizedBusinessId] = {races = races}
      return shop.cachedRaceDataByBusiness[normalizedBusinessId]
    end

    return {}
  end

  -- Predicted time from the race's fitted curve, time = a + b / (power-to-weight ^ c).
  local function powerToWeightToTime(powerToWeight, raceType, businessId)
    local races = loadRaceData(businessId)
    if not races or not races.races then
      return nil
    end

    local raceIdentifier = convertRaceTypeToIdentifier(raceType)
    local race = races.races[raceIdentifier]
    if not race or not race.predictCoef then
      return nil
    end

    local coef = race.predictCoef
    local clampedPowerToWeight = math.max(0.001, powerToWeight)
    return coef.a + coef.b / (clampedPowerToWeight ^ coef.c)
  end

  -- XP and selections ---------------------------------------------------------------------------

  local function loadBusinessXP(businessId)
    businessId = parts.garage.normalizeBusinessId(businessId)
    if not businessId then
      return 0
    end

    if shop.businessXP[businessId] == nil then
      initializeBusinessData(businessId)
    end

    return shop.businessXP[businessId] or 0
  end

  local function addBusinessXP(businessId, amount)
    businessId = parts.garage.normalizeBusinessId(businessId)
    if not businessId or not amount or amount <= 0 then
      return
    end

    local currentXP = loadBusinessXP(businessId)
    shop.businessXP[businessId] = currentXP + amount
  end

  local function spendBusinessXP(businessId, amount)
    businessId = parts.garage.normalizeBusinessId(businessId)
    if not businessId or not amount or amount <= 0 then
      return false
    end

    local currentXP = loadBusinessXP(businessId)
    if currentXP >= amount then
      shop.businessXP[businessId] = currentXP - amount
      return true
    end

    return false
  end

  local function loadBusinessSelections(businessId)
    businessId = parts.garage.normalizeBusinessId(businessId)
    if not businessId then
      return {}
    end

    if shop.businessSelections[businessId] == nil then
      initializeBusinessData(businessId)
    end

    return shop.businessSelections[businessId] or {}
  end

  local function getBrandSelection(businessId)
    local selections = loadBusinessSelections(businessId)
    return selections.brand
  end

  -- Job IDs -------------------------------------------------------------------------------------

  local function syncJobIdCounter()
    local maxJobId, usedIds = scanJobIds(shop.businessJobs)
    local nextId, idMapping = repairDuplicateJobIds(shop.businessJobs, usedIds, maxJobId + 1)
    renumberFleetJobs(idMapping)
    if maxJobId >= shop.jobIdCounter or nextId > shop.jobIdCounter then
      shop.jobIdCounter = nextId
    end
  end

  -- Field regeneration --------------------------------------------------------------------------

  -- Keeps a saved race type; otherwise draws one of the shop's races, or uses the default.
  local function chooseRaceType(job, businessId)
    local raceType = job.raceType
    if raceType then
      return raceType
    end
    local info = loadBusinessInfo(businessId)
    if info and info.races and #info.races > 0 then
      local availableRaceTypes = {}
      for _, raceIdentifier in ipairs(info.races) do
        table.insert(availableRaceTypes, convertRaceIdentifierToType(raceIdentifier))
      end
      if #availableRaceTypes > 0 then
        raceType = availableRaceTypes[math.random(#availableRaceTypes)]
      end
    end
    return raceType
  end

  -- Reads race data again, as the regeneration always has, before looking up the race.
  local function raceDefinition(businessId, raceType)
    local races = loadRaceData(businessId)
    local raceIdentifier = convertRaceTypeToIdentifier(raceType)
    if races and races.races and races.races[raceIdentifier] then
      return races.races[raceIdentifier]
    end
    return nil
  end

  local function restoreJobRaceProof(job, businessId, races)
    local raceType = job.raceId or chooseRaceType(job, businessId)
    if not job.raceId then
      for id, race in pairs(races.races) do
        local proof = businessProof(race)
        if proof and proof.legacyRaceType == raceType then raceType = id break end
      end
    end
    local raceObj = raceDefinition(businessId, raceType)
    local proof = businessProof(raceObj)
    if proof then
      if not job.proofVersion then
        if job.targetTime then job.targetTime = job.targetTime * TIME_SECONDS[proof.legacyTargetTimeUnit] end
        job.proofVersion = 1
      end
      job.raceId, job.raceType, job.targetTimeUnit, job.timeUnit = raceType, raceType, "s", proof.timeUnit
    end
    return raceType, raceObj
  end

  local function regenerateJobFields(job, businessId)
    if not job or not job.vehicleConfig then return end
    local races = loadRaceData(businessId)
    if not races or not races.races then return end
    local raceType, raceObj = restoreJobRaceProof(job, businessId, races)
    local vehicleConfig = job.vehicleConfig
    local vehicleInfo = getVehicleInfo(vehicleConfig.model_key, vehicleConfig.key)
    if not vehicleInfo then
      return
    end

    local power, weight = vehicleStats(vehicleInfo)
    if power == 0 or weight == 0 then
      return
    end

    local year = modelYear(vehicleConfig.model_key)
    local powerToWeight = power / weight

    local baseTime = powerToWeightToTime(powerToWeight, raceType, businessId)
    if not baseTime then
      return
    end

    job.power = power
    job.weight = weight
    job.year = year
    job.powerToWeight = powerToWeight
    job.raceType = raceType
    job.raceLabel = raceObj and raceObj.label or ""
    job.baseTime = baseTime
    job.businessId = businessId
    job.businessType = "tuningShop"

    applyRaceLevel(job, raceObj, baseTime, businessId)
    fillCommuteAndReward(job)
    if not job.decimalPlaces then
      job.decimalPlaces = config.defaultDecimalPlaces
    end
    assignMileage(job)
  end

  -- Loading jobs --------------------------------------------------------------------------------

  -- Reads the file into the shop's cache and reconciles the techs against it before any job is restored.
  local function cacheBusinessJobsFile(businessId, filePath)
    local data = jsonReadFile(filePath) or {}
    shop.businessJobs[businessId] = {
      active = data.active or {},
      new = data.new or {}
    }
    inputs.tuningShopTechs.reconcileAssignments(businessId, shop.businessJobs[businessId])
  end

  -- Active jobs are restored first; new jobs also get their lifetime before the defaults.
  local function restoreJobs(businessId)
    for _, job in ipairs(shop.businessJobs[businessId].active or {}) do
      restoreJobId(job)
      regenerateJobFields(job, businessId)
      fillCommuteAndReward(job)
    end
    for _, job in ipairs(shop.businessJobs[businessId].new or {}) do
      restoreJobId(job)
      regenerateJobFields(job, businessId)
      parts.garage.ensureJobLifetime(job, businessId)
      fillCommuteAndReward(job)
    end
    if not shop.businessJobs[businessId].new then
      shop.businessJobs[businessId].new = {}
    end
  end

  local function loadBusinessJobs(businessId)
    businessId = parts.garage.normalizeBusinessId(businessId)
    if not businessId then
      return {}
    end

    if shop.businessJobs[businessId] then
      inputs.tuningShopTechs.reconcileAssignments(businessId, shop.businessJobs[businessId])
      return shop.businessJobs[businessId]
    end

    local filePath = getBusinessFilePath(businessId, "jobs.json")
    if not filePath then
      return {}
    end

    cacheBusinessJobsFile(businessId, filePath)
    restoreJobs(businessId)
    syncJobIdCounter()
    return shop.businessJobs[businessId]
  end

  local function getJobById(businessId, jobId)
    if not businessId or not jobId then
      return nil
    end

    jobId = tonumber(jobId) or jobId
    local jobs = loadBusinessJobs(businessId)
    return findJobIn(jobs.active, jobId) or findJobIn(jobs.new, jobId)
  end

  -- Saving jobs ---------------------------------------------------------------------------------

  local function saveBusinessJobs(businessId, currentSavePath, writer)
    businessId = parts.garage.normalizeBusinessId(businessId)
    if not businessId or not shop.businessJobs[businessId] then
      return
    end
    if not currentSavePath then
      return
    end

    local filePath = businessSaveState.businessFilePath(businessId .. "", "jobs.json", currentSavePath .. "")
    local dirPath = string.match(filePath, "^(.*)/[^/]+$")
    if dirPath and not writer.exists(dirPath) then
      writer.mkdir(dirPath)
    end

    local saveData = {
      active = minimizeJobList(shop.businessJobs[businessId].active),
      new = minimizeJobList(shop.businessJobs[businessId].new)
    }
    overhaul_career_saveSystem.jsonWriteFileSafe(filePath, saveData, true)
  end

  -- Public API ----------------------------------------------------------------------------------
  return {
    addBusinessXP = addBusinessXP,
    convertRaceIdentifierToType = convertRaceIdentifierToType,
    convertRaceTypeToIdentifier = convertRaceTypeToIdentifier,
    getBrandSelection = getBrandSelection,
    getBusinessXP = loadBusinessXP,
    getJobById = getJobById,
    getModelInfo = getModelInfo,
    getSkillTreeUpgradeCount = getSkillTreeUpgradeCount,
    getVehicleInfo = getVehicleInfo,
    initializeBusinessData = initializeBusinessData,
    loadBusinessInfo = loadBusinessInfo,
    loadBusinessJobs = loadBusinessJobs,
    loadBusinessSelections = loadBusinessSelections,
    loadBusinessXP = loadBusinessXP,
    loadRaceData = loadRaceData,
    getBusinessProof = function(businessId, raceId)
      local data = loadRaceData(businessId)
      local info = shop.cachedBusinessMapInfo[parts.garage.normalizeBusinessId(businessId)]
      return businessProof(data.races and data.races[raceId]), info and info.mapId
    end,
    powerToWeightToTime = powerToWeightToTime,
    saveBusinessInfo = saveBusinessInfo,
    saveBusinessJobs = saveBusinessJobs,
    spendBusinessXP = spendBusinessXP,
    syncJobIdCounter = syncJobIdCounter,
  }
end

return installer
