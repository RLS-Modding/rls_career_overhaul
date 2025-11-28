local M = {}

M.dependencies = {'util_configListGenerator', 'career_career', 'career_saveSystem', 'freeroam_facilities'}

local raceData = nil
local raceDataLevel = nil
local factoryConfigs = nil
local businessJobs = {}
local businessXP = {}
local generationTimers = {}
local managerTimers = {}
local operatingCostTimers = {}
local jobIdCounter = 0

local UPDATE_INTERVAL_JOBS = 0.1
local UPDATE_INTERVAL_TECHS = 0.15
local UPDATE_INTERVAL_MANAGER = 0.2
local UPDATE_INTERVAL_COSTS = 0.5

local jobsAccumulator = 0
local techsAccumulator = 0.15
local managerAccumulator = 0.30
local costsAccumulator = 0.45

local freeroamUtils = require('gameplay/events/freeroam/utils')
local tuningShopTechs = require('ge/extensions/career/modules/business/tuningShopTechs')
-- local tuningShopKits = require('ge/extensions/career/modules/business/tuningShopKits')

local function getTuningShopKits()
  return career_modules_business_tuningShopKits or require('ge/extensions/career/modules/business/tuningShopKits')
end

local GEN_INTERVAL_SECONDS = 120
local EXPIRY_SECONDS = 300

local DAMAGE_LOCK_THRESHOLD = 1750

local cachedGarageZones = {}
local activePersonalVehicle = {}

local function getGarageZones(businessId)
  if cachedGarageZones[businessId] then
    return cachedGarageZones[businessId]
  end
  
  local businessType = "tuningShop"
  local garage = nil
  
  if career_modules_business_businessInventory and career_modules_business_businessInventory.getBusinessGarage then
    garage = career_modules_business_businessInventory.getBusinessGarage(businessType, businessId)
  end
  
  if not garage then
    local business = freeroam_facilities.getFacility(businessType, businessId)
    if not business then
      return nil
    end
    
    local businessGarages = freeroam_facilities.getFacilitiesByType("businessGarage")
    if businessGarages then
      for _, g in ipairs(businessGarages) do
        if g.id == business.businessGarageId then
          garage = g
          break
        end
      end
    end
  end
  
  if not garage then
    return nil
  end
  
  if not garage.sitesFile then
    return nil
  end
  
  local sites = gameplay_sites_sitesManager.loadSites(garage.sitesFile)
  if not sites or not sites.zones then
    return nil
  end
  
  cachedGarageZones[businessId] = sites.zones
  return sites.zones
end

local function isPositionInGarageZone(businessId, pos)
  if not businessId or not pos then
    return false
  end
  
  local zones = getGarageZones(businessId)
  if not zones then
    return false
  end
  
  for _, zone in ipairs(zones.sorted or {}) do
    if zone and zone.containsPoint2D and zone:containsPoint2D(pos) then
      return true
    end
  end
  
  return false
end

local function isSpawnedVehicleInGarageZone(businessId, vehicleId)
  if not businessId or not vehicleId then
    return false
  end
  
  local spawnedVehId = nil
  if isPersonalVehicleId(vehicleId) then
    spawnedVehId = getSpawnedIdFromPersonalVehicleId(vehicleId)
  elseif career_modules_business_businessInventory and career_modules_business_businessInventory.getSpawnedVehicleId then
    spawnedVehId = career_modules_business_businessInventory.getSpawnedVehicleId(businessId, vehicleId)
  end
  
  if not spawnedVehId then
    return false
  end
  
  local vehObj = be:getObjectByID(spawnedVehId)
  if not vehObj then
    return false
  end
  
  local vehPos = vehObj:getPosition()
  if not vehPos then
    return false
  end
  
  return isPositionInGarageZone(businessId, vehPos)
end

local function isPlayerInTuningShopZone(businessId)
  if not businessId then
    return false
  end
  
  local playerVeh = be:getPlayerVehicle(0)
  local playerPos = nil
  
  if playerVeh then
    playerPos = playerVeh:getPosition()
  else
    local cam = core_camera.getActiveCamName()
    if cam == "freeCam" or cam == "free" then
      playerPos = core_camera.getPosition()
    end
  end
  
  if not playerPos then
    return false
  end
  
  return isPositionInGarageZone(businessId, playerPos)
end

local blacklistedModels = {
  atv = true,
  citybus = true,
  lansdale = true,
  md_series = true,
  pigeon = true,
  racetruck = true,
  rockbouncer = true,
  us_semi = true,
  van = true,
  utv = true
}

local vehicleInfoCache = nil

local function normalizeBusinessId(businessId)
  return tonumber(businessId) or businessId
end

local function getGenerationIntervalSeconds(businessId)
  local baseInterval = GEN_INTERVAL_SECONDS
  if not businessId or not career_modules_business_businessSkillTree then
    return baseInterval
  end

  local treeId = "shop-upgrades"
  local marketingLevel = career_modules_business_businessSkillTree.getNodeProgress(businessId, treeId, "marketing") or 0

  return baseInterval / (1 + 0.25 * marketingLevel)
end

local function getXPGainMultiplier(businessId)
  if not businessId or not career_modules_business_businessSkillTree then
    return 1
  end

  local treeId = "shop-upgrades"
  local xpGainLevel = career_modules_business_businessSkillTree.getNodeProgress(businessId, treeId, "xp-gain") or 0

  return 1 + (0.25 * xpGainLevel)
end

local function getJobExpirySeconds(businessId)
  return EXPIRY_SECONDS
end

local function ensureJobLifetime(job, businessId)
  if not job then
    return
  end
  local lifetime = tonumber(job.remainingLifetime)
  if not lifetime or lifetime <= 0 then
    job.remainingLifetime = getJobExpirySeconds(businessId)
  else
    job.remainingLifetime = lifetime
  end
end

local function notifyJobsUpdated(businessId)
  if not businessId or not guihooks then
    return
  end

  guihooks.trigger('businessComputer:onJobsUpdated', {
    businessType = "tuningShop",
    businessId = tostring(businessId)
  })
end

local function getSkillTreeLevel(businessId, treeId, nodeId)
  if not businessId or not career_modules_business_businessSkillTree then
    return 0
  end
  local level = career_modules_business_businessSkillTree.getNodeProgress(businessId, treeId, nodeId)
  return tonumber(level) or 0
end

local function isPersonalUseUnlocked(businessId)
  if not businessId or not career_modules_business_businessSkillTree then
    return false
  end
  local level = career_modules_business_businessSkillTree.getNodeProgress(businessId, "quality-of-life", "personal-use")
  return (tonumber(level) or 0) >= 1
end

local function getInventoryVehiclesInGarageZone(businessId)
  if not businessId or not career_modules_inventory then
    return {}
  end
  local zones = getGarageZones(businessId)
  if not zones or not zones.sorted then
    return {}
  end
  local inventoryVehicles = career_modules_inventory.getVehicles()
  if not inventoryVehicles then
    return {}
  end
  local results = {}
  for inventoryId, vehInfo in pairs(inventoryVehicles) do
    if vehInfo.loanType then
      goto continue
    end
    if career_modules_testDrive and career_modules_testDrive.isActive and career_modules_testDrive.isActive() then
      goto continue
    end
    local spawnedId = career_modules_inventory.getVehicleIdFromInventoryId(inventoryId)
    if not spawnedId then
      goto continue
    end
    local vehObj = be:getObjectByID(spawnedId)
    if not vehObj then
      goto continue
    end
    local vehPos = vehObj:getPosition()
    if not vehPos then
      goto continue
    end
    local inZone = false
    for _, zone in ipairs(zones.sorted or {}) do
      if zone and zone.containsPoint2D and zone:containsPoint2D(vehPos) then
        inZone = true
        break
      end
    end
    if inZone then
      table.insert(results, {
        spawnedId = spawnedId,
        inventoryId = inventoryId,
        inventoryVehicleData = vehInfo
      })
    end
    ::continue::
  end
  return results
end

local function createPersonalVehicleEntry(businessId, inventoryId, inventoryVehicleData, spawnedId)
  if not inventoryId or not inventoryVehicleData or not spawnedId then
    return nil
  end
  local vehicleId = "personal_" .. tostring(spawnedId)
  local model = inventoryVehicleData.model
  local config = inventoryVehicleData.config or {}
  local configKey = config.partConfigFilename
  if configKey then
    local _, key = path.splitWithoutExt(configKey)
    configKey = key
  end
  local niceName = nil
  if model then
    local vehicleData = core_vehicles.getModel(model)
    if vehicleData and vehicleData.model then
      niceName = vehicleData.model.Brand .. " " .. vehicleData.model.Name
    end
  end
  return {
    vehicleId = vehicleId,
    jobId = nil,
    model = model,
    model_key = model,
    config = config,
    vehicleConfig = {
      model_key = model,
      key = configKey
    },
    vars = config.vars or {},
    partConditions = inventoryVehicleData.partConditions or {},
    mileage = inventoryVehicleData.mileage or 0,
    niceName = niceName or model or "Unknown Vehicle",
    isPersonal = true,
    inventoryId = inventoryId,
    spawnedVehicleId = spawnedId,
    owned = inventoryVehicleData.owned,
    storedTime = os.time()
  }
end

local function getBusinessJobsPath(businessId)
  if not career_career.isActive() then
    return nil
  end
  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  if not currentSavePath then
    return nil
  end
  return currentSavePath .. "/career/rls_career/businesses/" .. businessId .. "/jobs.json"
end

local function syncJobIdCounter()
  local maxJobId = 0
  local usedIds = {}
  local idMapping = {}

  for _, jobs in pairs(businessJobs) do
    for _, job in ipairs(jobs.active or {}) do
      if job.jobId then
        local jId = tonumber(job.jobId) or job.jobId
        if type(jId) == "number" then
          if jId > maxJobId then
            maxJobId = jId
          end
          usedIds[jId] = (usedIds[jId] or 0) + 1
        end
      end
    end
    for _, job in ipairs(jobs.new or {}) do
      if job.jobId then
        local jId = tonumber(job.jobId) or job.jobId
        if type(jId) == "number" then
          if jId > maxJobId then
            maxJobId = jId
          end
          usedIds[jId] = (usedIds[jId] or 0) + 1
        end
      end
    end
    for _, job in ipairs(jobs.completed or {}) do
      if job.jobId then
        local jId = tonumber(job.jobId) or job.jobId
        if type(jId) == "number" then
          if jId > maxJobId then
            maxJobId = jId
          end
          usedIds[jId] = (usedIds[jId] or 0) + 1
        end
      end
    end
  end

  local nextId = maxJobId + 1
  for businessId, jobs in pairs(businessJobs) do
    for _, job in ipairs(jobs.active or {}) do
      if job.jobId then
        local jId = tonumber(job.jobId) or job.jobId
        if type(jId) == "number" and usedIds[jId] and usedIds[jId] > 1 then
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
    for _, job in ipairs(jobs.new or {}) do
      if job.jobId then
        local jId = tonumber(job.jobId) or job.jobId
        if type(jId) == "number" and usedIds[jId] and usedIds[jId] > 1 then
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

  for businessId, mapping in pairs(idMapping) do
    if career_modules_business_businessInventory then
      local vehicles = career_modules_business_businessInventory.getBusinessVehicles(businessId)
      if vehicles then
        for _, vehicle in ipairs(vehicles) do
          if vehicle.jobId then
            local vJobId = tonumber(vehicle.jobId) or vehicle.jobId
            if mapping[vJobId] then
              vehicle.jobId = mapping[vJobId]
              career_modules_business_businessInventory.storeVehicle(businessId, vehicle)
            end
          end
        end
      end
    end
  end

  if maxJobId >= jobIdCounter or nextId > jobIdCounter then
    jobIdCounter = nextId
  end
end

local function loadBusinessJobs(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return {}
  end

  if businessJobs[businessId] then
    return businessJobs[businessId]
  end

  local filePath = getBusinessJobsPath(businessId)
  if not filePath then
    return {}
  end

  local data = jsonReadFile(filePath) or {}
  businessJobs[businessId] = {
    active = data.active or {},
    new = data.new or {},
    completed = data.completed or {}
  }

  for _, job in ipairs(businessJobs[businessId].active or {}) do
    if job.jobId then
      job.jobId = tonumber(job.jobId) or job.jobId
    end
    job.commuteSeconds = tonumber(job.commuteSeconds) or 120
    job.eventReward = tonumber(job.eventReward) or 0
  end
  for _, job in ipairs(businessJobs[businessId].new or {}) do
    if job.jobId then
      job.jobId = tonumber(job.jobId) or job.jobId
    end
    ensureJobLifetime(job, businessId)
    job.commuteSeconds = tonumber(job.commuteSeconds) or 120
    job.eventReward = tonumber(job.eventReward) or 0
  end
  for _, job in ipairs(businessJobs[businessId].completed or {}) do
    if job.jobId then
      job.jobId = tonumber(job.jobId) or job.jobId
    end
  end

  if not businessJobs[businessId].new then
    businessJobs[businessId].new = {}
  end

  syncJobIdCounter()

  return businessJobs[businessId]
end

local function getJobById(businessId, jobId)
  if not businessId or not jobId then
    return nil
  end

  jobId = tonumber(jobId) or jobId
  local jobs = loadBusinessJobs(businessId)

  for _, job in ipairs(jobs.active or {}) do
    local jId = tonumber(job.jobId) or job.jobId
    if jId == jobId then
      return job
    end
  end

  for _, job in ipairs(jobs.new or {}) do
    local jId = tonumber(job.jobId) or job.jobId
    if jId == jobId then
      return job
    end
  end

  for _, job in ipairs(jobs.completed or {}) do
    local jId = tonumber(job.jobId) or job.jobId
    if jId == jobId then
      return job
    end
  end

  return nil
end

local function invalidateVehicleInfoCache()
  vehicleInfoCache = nil
end

local function normalizeConfigKey(configKey)
  if not configKey then
    return nil
  end
  if configKey:find("/") then
    local parts = {}
    for part in configKey:gmatch("[^/]+") do
      table.insert(parts, part)
    end
    if #parts > 0 then
      local filename = parts[#parts]
      local name, ext = filename:match("^(.+)%.(.+)$")
      return name or filename
    end
  else
    local name, ext = configKey:match("^(.+)%.(.+)$")
    return name or configKey
  end
  return configKey
end

local function getVehicleInfo(modelKey, configKey)
  if not modelKey or not configKey then
    return nil
  end

  local normalizedConfigKey = normalizeConfigKey(configKey)

  if util_configListGenerator and util_configListGenerator.getEligibleVehicles then
    if not vehicleInfoCache then
      vehicleInfoCache = util_configListGenerator.getEligibleVehicles(false, false) or {}
    end

    for _, vehicleInfo in ipairs(vehicleInfoCache) do
      if vehicleInfo.model_key == modelKey then
        local vehicleKey = normalizeConfigKey(vehicleInfo.key)
        if vehicleInfo.key == configKey or vehicleKey == normalizedConfigKey or vehicleInfo.key == normalizedConfigKey then
          return vehicleInfo
        end
      end
    end
  end

  if core_vehicles and core_vehicles.getConfig then
    local model = core_vehicles.getModel(modelKey)
    if model and not tableIsEmpty(model) then
      local configName = normalizedConfigKey
      local configInfo = core_vehicles.getConfig(modelKey, configName)
      if configInfo then
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
    end
  end

  return nil
end

-- XP Management Logic

local function getBusinessXPPath(businessId)
  if not career_career.isActive() then
    return nil
  end
  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  if not currentSavePath then
    return nil
  end
  return currentSavePath .. "/career/rls_career/businesses/" .. businessId .. "/xp.json"
end

local function loadBusinessXP(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return 0
  end

  if businessXP[businessId] then
    return businessXP[businessId]
  end

  local filePath = getBusinessXPPath(businessId)
  if not filePath then
    return 0
  end

  local data = jsonReadFile(filePath) or {}
  local xp = data.xp or 0
  businessXP[businessId] = xp
  return xp
end

local function saveBusinessXP(businessId, currentSavePath)
  businessId = normalizeBusinessId(businessId)
  if not businessId or businessXP[businessId] == nil then
    return
  end
  if not currentSavePath then
    return
  end

  local filePath = currentSavePath .. "/career/rls_career/businesses/" .. businessId .. "/xp.json"

  local dirPath = string.match(filePath, "^(.*)/[^/]+$")
  if dirPath and not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end

  local data = {
    xp = businessXP[businessId]
  }

  jsonWriteFile(filePath, data, true)
end

local function getBusinessXP(businessId)
  return loadBusinessXP(businessId)
end

local function addBusinessXP(businessId, amount)
  businessId = normalizeBusinessId(businessId)
  if not businessId or not amount or amount <= 0 then
    return
  end

  local currentXP = loadBusinessXP(businessId)
  businessXP[businessId] = currentXP + amount
end

local function spendBusinessXP(businessId, amount)
  businessId = normalizeBusinessId(businessId)
  if not businessId or not amount or amount <= 0 then
    return false
  end

  local currentXP = loadBusinessXP(businessId)
  if currentXP >= amount then
    businessXP[businessId] = currentXP - amount
    return true
  end

  return false
end

-- Selection Storage Logic

local businessSelections = {}

local function getBusinessSelectionsPath(businessId)
  if not career_career.isActive() then
    return nil
  end
  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  if not currentSavePath then
    return nil
  end
  return currentSavePath .. "/career/rls_career/businesses/" .. businessId .. "/selections.json"
end

local function loadBusinessSelections(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return {}
  end

  if businessSelections[businessId] then
    return businessSelections[businessId]
  end

  local filePath = getBusinessSelectionsPath(businessId)
  if not filePath then
    return {}
  end

  local data = jsonReadFile(filePath) or {}
  businessSelections[businessId] = {
    brand = data.brand or nil,
    raceType = data.raceType or nil
  }
  return businessSelections[businessId]
end

local function saveBusinessSelections(businessId, currentSavePath)
  businessId = normalizeBusinessId(businessId)
  if not businessId or not businessSelections[businessId] then
    return
  end
  if not currentSavePath then
    return
  end

  local filePath = currentSavePath .. "/career/rls_career/businesses/" .. businessId .. "/selections.json"

  local dirPath = string.match(filePath, "^(.*)/[^/]+$")
  if dirPath and not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end

  local data = {
    brand = businessSelections[businessId].brand,
    raceType = businessSelections[businessId].raceType
  }

  jsonWriteFile(filePath, data, true)
end

local function getBrandSelection(businessId)
  local selections = loadBusinessSelections(businessId)
  return selections.brand
end

local function setBrandSelection(businessId, brand)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return false
  end

  if not businessSelections[businessId] then
    businessSelections[businessId] = {}
  end

  businessSelections[businessId].brand = brand
  return true
end

local function getRaceSelection(businessId)
  local selections = loadBusinessSelections(businessId)
  return selections.raceType
end

local function setRaceSelection(businessId, raceType)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return false
  end

  if not businessSelections[businessId] then
    businessSelections[businessId] = {}
  end

  businessSelections[businessId].raceType = raceType
  return true
end

-- Manager Timer Management Logic

local function getManagerTimerPath(businessId)
  if not career_career.isActive() then
    return nil
  end
  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  if not currentSavePath then
    return nil
  end
  return currentSavePath .. "/career/rls_career/businesses/" .. businessId .. "/manager.json"
end

local function loadManagerTimer(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return {
      elapsed = 0,
      flagActive = false
    }
  end

  if managerTimers[businessId] then
    return managerTimers[businessId]
  end

  local filePath = getManagerTimerPath(businessId)
  if not filePath then
    managerTimers[businessId] = {
      elapsed = 0,
      flagActive = false
    }
    return managerTimers[businessId]
  end

  local data = jsonReadFile(filePath) or {}
  managerTimers[businessId] = {
    elapsed = tonumber(data.elapsed) or 0,
    flagActive = data.flagActive == true
  }
  return managerTimers[businessId]
end

local function saveManagerTimer(businessId, currentSavePath)
  businessId = normalizeBusinessId(businessId)
  if not businessId or not managerTimers[businessId] then
    return
  end
  if not currentSavePath then
    return
  end

  local filePath = currentSavePath .. "/career/rls_career/businesses/" .. businessId .. "/manager.json"

  local dirPath = string.match(filePath, "^(.*)/[^/]+$")
  if dirPath and not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end

  local data = {
    elapsed = managerTimers[businessId].elapsed,
    flagActive = managerTimers[businessId].flagActive
  }

  jsonWriteFile(filePath, data, true)
end

local function hasManager(businessId)
  if not businessId or not career_modules_business_businessSkillTree then
    return false
  end
  local level = career_modules_business_businessSkillTree.getNodeProgress(businessId, "automation", "manager")
  return level and level > 0
end

local function hasGeneralManager(businessId)
  if not businessId or not career_modules_business_businessSkillTree then
    return false
  end
  local level = career_modules_business_businessSkillTree.getNodeProgress(businessId, "automation", "general-manager")
  return level and level > 0
end

local function getManagerAssignmentInterval(businessId)
  local baseInterval = 1800
  if not businessId or not career_modules_business_businessSkillTree then
    return baseInterval
  end

  local speedLevel =
    career_modules_business_businessSkillTree.getNodeProgress(businessId, "automation", "manager-speed") or 0
  local interval = baseInterval - (speedLevel * 120)
  return math.max(600, interval)
end

local function getManagerTimerState(businessId)
  if not businessId then
    return {
      elapsed = 0,
      flagActive = false
    }
  end
  return loadManagerTimer(businessId)
end

local function processManagerTimers(businessId, dtSim)
  if not businessId or dtSim <= 0 then
    return false
  end

  if not hasManager(businessId) then
    return false
  end

  if hasGeneralManager(businessId) then
    return false
  end

  local timerState = getManagerTimerState(businessId)
  local interval = getManagerAssignmentInterval(businessId)

  timerState.elapsed = timerState.elapsed + dtSim

  local changed = false
  if timerState.elapsed >= interval then
    timerState.flagActive = true
    timerState.elapsed = 0
    changed = true
  end

  managerTimers[businessId] = timerState
  return changed
end

local function getOperatingCostTimerPath(businessId)
  if not career_career.isActive() then
    return nil
  end
  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  if not currentSavePath then
    return nil
  end
  return currentSavePath .. "/career/rls_career/businesses/" .. businessId .. "/operatingCost.json"
end

local function loadOperatingCostTimer(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return {
      elapsed = 0,
      lastChargeTime = nil
    }
  end

  if operatingCostTimers[businessId] then
    return operatingCostTimers[businessId]
  end

  local filePath = getOperatingCostTimerPath(businessId)
  if not filePath then
    operatingCostTimers[businessId] = {
      elapsed = 0,
      lastChargeTime = nil
    }
    return operatingCostTimers[businessId]
  end

  local data = jsonReadFile(filePath) or {}
  operatingCostTimers[businessId] = {
    elapsed = tonumber(data.elapsed) or 0,
    lastChargeTime = tonumber(data.lastChargeTime) or nil
  }
  return operatingCostTimers[businessId]
end

local function saveOperatingCostTimer(businessId, currentSavePath)
  businessId = normalizeBusinessId(businessId)
  if not businessId or not operatingCostTimers[businessId] then
    return
  end
  if not currentSavePath then
    return
  end

  local filePath = currentSavePath .. "/career/rls_career/businesses/" .. businessId .. "/operatingCost.json"

  local dirPath = string.match(filePath, "^(.*)/[^/]+$")
  if dirPath and not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end

  local data = {
    elapsed = operatingCostTimers[businessId].elapsed,
    lastChargeTime = operatingCostTimers[businessId].lastChargeTime
  }

  jsonWriteFile(filePath, data, true)
end

local function getMaxActiveJobs(businessId)
  local baseLimit = 2
  if not businessId or not career_modules_business_businessSkillTree then
    return baseLimit
  end

  local treeId = "shop-upgrades"
  local biggerBooksLevel =
    career_modules_business_businessSkillTree.getNodeProgress(businessId, treeId, "bigger-books") or 0

  return baseLimit + biggerBooksLevel
end

-- Job Management Logic

local function getFasterTechReduction(businessId)
  local level1 = getSkillTreeLevel(businessId, "automation", "faster-techs")
  local level2 = getSkillTreeLevel(businessId, "automation", "faster-techs-ii")
  local total = math.max(0, level1 + level2)
  local reduction = math.min(0.65, total * 0.05)
  return reduction
end

local function getBuildTimeSeconds(baseSeconds, businessId)
  local reduction = getFasterTechReduction(businessId)
  return math.max(1, baseSeconds * (1 - reduction))
end

local function getBuildCostDiscount(businessId)
  local suppliers = math.min(0.25, getSkillTreeLevel(businessId, "shop-upgrades", "part-suppliers") * 0.05)
  local smart = math.min(0.25, getSkillTreeLevel(businessId, "automation", "smart-techs") * 0.05)
  return math.min(0.5, suppliers + smart)
end

local function getReliableFailureReduction(businessId)
  return math.min(0.25, getSkillTreeLevel(businessId, "automation", "reliable-techs") * 0.05)
end

local function hasPerfectTechs(businessId)
  return getSkillTreeLevel(businessId, "automation", "perfect-techs") > 0
end

local function hasMasterTechs(businessId)
  return getSkillTreeLevel(businessId, "automation", "master-techs") > 0
end

local function getEventRetryAllowance(businessId)
  return math.max(0, getSkillTreeLevel(businessId, "automation", "event-retries"))
end

local function getBusinessAccount(businessId)
  if not career_modules_bank then
    return nil
  end
  local account = career_modules_bank.getBusinessAccount("tuningShop", businessId)
  if not account then
    career_modules_bank.createBusinessAccount("tuningShop", businessId)
    account = career_modules_bank.getBusinessAccount("tuningShop", businessId)
  end
  return account
end

local function creditBusinessAccount(businessId, amount, reason, description)
  amount = math.floor(amount or 0)
  if amount <= 0 then
    return true
  end
  local account = getBusinessAccount(businessId)
  if not account then
    return false
  end
  return career_modules_bank.rewardToAccount({
    money = {
      amount = amount
    }
  }, account.id, reason or "Automation Payout", description or "")
end

local function debitBusinessAccount(businessId, amount, reason, description)
  amount = math.floor(amount or 0)
  if amount <= 0 then
    return true
  end
  local account = getBusinessAccount(businessId)
  if not account then
    return false
  end
  return career_modules_bank.removeFunds(account.id, amount, reason or "Automation Expense", "",
    description or "Expense", true)
end

local function getVehicleByJobId(businessId, jobId)
  if not career_modules_business_businessInventory or not businessId or not jobId then
    return nil
  end
  local vehicles = career_modules_business_businessInventory.getBusinessVehicles(businessId) or {}
  for _, vehicle in ipairs(vehicles) do
    local vJobId = tonumber(vehicle.jobId) or vehicle.jobId
    if vJobId == jobId then
      return vehicle
    end
  end
  return nil
end

local function removeJobVehicle(businessId, jobId)
  local vehicleToRemove = getVehicleByJobId(businessId, jobId)

  if not vehicleToRemove then
    return
  end

  local removeId = tonumber(vehicleToRemove.vehicleId) or vehicleToRemove.vehicleId
  local wasPulledOut = false

  if career_modules_business_businessInventory.getPulledOutVehicles then
    local pulledVehicles = career_modules_business_businessInventory.getPulledOutVehicles(businessId) or {}
    for _, pulled in ipairs(pulledVehicles) do
      local pulledId = tonumber(pulled.vehicleId) or pulled.vehicleId
      if pulledId == removeId then
        wasPulledOut = true
        if career_modules_business_businessComputer and career_modules_business_businessComputer.putAwayVehicle then
          career_modules_business_businessComputer.putAwayVehicle(businessId, removeId)
        else
          career_modules_business_businessInventory.putAwayVehicle(businessId, removeId)
        end
        break
      end
    end
  else
    local pulledOutVehicle = career_modules_business_businessInventory.getPulledOutVehicle(businessId)
    if pulledOutVehicle then
      local pulledId = tonumber(pulledOutVehicle.vehicleId) or pulledOutVehicle.vehicleId
      if pulledId == removeId then
        wasPulledOut = true
        if career_modules_business_businessComputer and career_modules_business_businessComputer.putAwayVehicle then
          career_modules_business_businessComputer.putAwayVehicle(businessId)
        else
          career_modules_business_businessInventory.putAwayVehicle(businessId)
        end
      end
    end
  end

  career_modules_business_businessInventory.removeVehicle(businessId, vehicleToRemove.vehicleId)

  if not wasPulledOut and guihooks and career_modules_business_businessComputer and
    career_modules_business_businessComputer.getVehiclesOnly then
    local vehiclesData = career_modules_business_businessComputer.getVehiclesOnly(businessId)
    local businessType = "tuningShop"
    guihooks.trigger('businessComputer:onVehiclePutAway', {
      businessType = businessType,
      businessId = tostring(businessId),
      vehicleId = removeId,
      vehicles = vehiclesData.vehicles,
      pulledOutVehicles = vehiclesData.pulledOutVehicles,
      maxPulledOutVehicles = vehiclesData.maxPulledOutVehicles
    })
  end
end

local function clearJobLeaderboardEntry(businessId, jobId)
  if not career_modules_business_businessInventory then
    return
  end
  local leaderboardManager = require('gameplay/events/freeroam/leaderboardManager')
  local businessJobId = career_modules_business_businessInventory.getBusinessJobIdentifier(businessId, jobId)
  leaderboardManager.clearLeaderboardForVehicle(businessJobId)
end

local TECH_STATE = {
  IDLE = 0,
  DRIVE_BASELINE = 1,
  RUN_EVENT = 2,
  DRIVE_BACK = 3,
  BUILD = 4,
  DRIVE_VALIDATION = 5,
  UPDATE = 6,
  DRIVE_FINAL = 7,
  FAILED = 8,
  COMPLETED = 9,
  COOLDOWN = 10
}

local function setTechState(tech, stateCode, action, duration, meta)
  tech.state = stateCode or TECH_STATE.IDLE
  tech.currentAction = action or "idle"
  tech.stateDuration = math.max(0, duration or 0)
  tech.stateElapsed = 0
  tech.stateMeta = meta or {}
end

local function resetTechToIdle(tech)
  tech.jobId = nil
  tech.phase = "idle"
  tech.validationAttempts = 0
  tech.maxValidationAttempts = 0
  tech.retriesUsed = 0
  tech.totalAttempts = 0
  tech.fundsHeld = 0
  tech.buildCost = 0
  tech.totalSpent = 0
  tech.eventFunds = 0
  tech.predictedEventTime = nil
  tech.latestResult = nil
  tech.finishedJobInfo = nil
  setTechState(tech, TECH_STATE.IDLE, "idle", 0, {})
end

local function getCommuteSeconds(job)
  if not job then
    return 120
  end
  return math.max(15, tonumber(job.commuteSeconds) or 120)
end

local function getEventReward(job)
  if not job then
    return 0
  end
  return tonumber(job.eventReward) or 0
end

local function loadRaceData()
  local currentLevel = getCurrentLevelIdentifier()
  if not currentLevel then
    return {}
  end

  if raceData and raceDataLevel == currentLevel then
    return raceData
  end

  local raceDataPath = "levels/" .. currentLevel .. "/race_data.json"
  raceData = jsonReadFile(raceDataPath) or {}
  raceDataLevel = currentLevel
  return raceData
end

local function calculateActualEventPayment(businessId, job, predictedTime)
  if not job or not predictedTime or predictedTime <= 0 then
    return 0
  end

  local races = loadRaceData()
  if not races or not races.races then
    return getEventReward(job)
  end

  local race = nil
  local raceType = job.raceType

  if raceType == "trackAlt" then
    race = races.races.track and races.races.track.altRoute
  elseif raceType == "track" then
    race = races.races.track
  elseif raceType == "drag" then
    race = races.races.drag
  end

  if not race then
    return getEventReward(job)
  end

  local time = race.bestTime
  local reward = race.reward
  local damageFactor = race.damageFactor or 0

  local actualTime = predictedTime
  local targetTime = job.targetTime or time
  local damagePercentage = 0

  if damageFactor > 0 then
    damagePercentage = 0
  end

  if race.topSpeed then
    local targetSpeed = race.topSpeedGoal or 0
    local estimatedSpeed = targetSpeed * 0.95
    reward = freeroamUtils.topSpeedReward(targetSpeed, reward, estimatedSpeed, race.type)
  elseif race.driftGoal then
    local targetDrift = race.driftGoal or 0
    local estimatedDrift = targetDrift * 0.95
    reward = freeroamUtils.driftReward(race, actualTime, estimatedDrift)
  elseif damageFactor > 0 then
    reward = freeroamUtils.hybridRaceReward(time, reward, actualTime, damageFactor, damagePercentage, race.type)
  else
    reward = freeroamUtils.raceReward(time, reward, actualTime, race.type)
  end

  if not career_career or not career_career.isActive() then
    return math.max(0, reward)
  end

  local isNewBest = actualTime <= targetTime
  if not isNewBest then
    reward = reward / 2
  end

  if isNewBest then
    reward = reward * 1.2
  end

  if career_modules_hardcore and career_modules_hardcore.isHardcoreMode() then
    reward = reward / 2
  end

  return math.max(0, math.floor(reward + 0.5))
end

local function calculateBuildCost(businessId, job)
  if not job then
    return 0
  end
  local reward = tonumber(job.reward) or 0
  local baseCost = reward * 0.3
  local variation = 0.95 + (math.random() * 0.1)
  local variedCost = baseCost * variation
  local discount = getBuildCostDiscount(businessId)
  local cost = variedCost * (1 - discount)
  local rounded = math.floor(cost * 100 + 0.5) / 100
  return math.max(0, rounded)
end

local function moveJobToCompleted(businessId, jobId, status, automationData)
  local jobs = loadBusinessJobs(businessId)
  local jobIndex = nil
  local job = nil

  for i, activeJob in ipairs(jobs.active or {}) do
    local jId = tonumber(activeJob.jobId) or activeJob.jobId
    if jId == jobId then
      jobIndex = i
      job = activeJob
      break
    end
  end

  if not jobIndex or not job then
    return nil
  end

  local removedJob = table.remove(jobs.active, jobIndex)
  removedJob.status = status or "completed"
  removedJob.completedTime = os.time()
  removedJob.automationResult = automationData or {}
  removedJob.techAssigned = nil

  jobs.completed = jobs.completed or {}
  table.insert(jobs.completed, removedJob)

  notifyJobsUpdated(businessId)
  career_saveSystem.saveCurrent()
  return removedJob
end

local function getAbandonPenalty(businessId, jobId)
  if not businessId or not jobId then
    return 0
  end

  local job = getJobById(businessId, jobId)
  if not job then
    return 0
  end

  if businessId and career_modules_business_businessSkillTree then
    local treeId = "quality-of-life"
    local iGiveUpLevel = career_modules_business_businessSkillTree.getNodeProgress(businessId, treeId, "i-give-up") or 0
    if iGiveUpLevel > 0 then
      return 0
    end
  end

  local reward = job.reward or 20000
  local basePenalty = reward * 0.5

  local reduction = 0
  if businessId and career_modules_business_businessSkillTree then
    local treeId = "quality-of-life"
    local noHardFeelingsLevel = career_modules_business_businessSkillTree.getNodeProgress(businessId, treeId,
      "no-hard-feelings") or 0
    reduction = noHardFeelingsLevel * 0.05
  end

  local penaltyMultiplier = math.max(0, 0.5 - reduction)
  local penalty = math.floor(reward * penaltyMultiplier)

  return penalty
end
local function saveBusinessJobs(businessId, currentSavePath)
  businessId = normalizeBusinessId(businessId)
  if not businessId or not businessJobs[businessId] then
    return
  end
  if not currentSavePath then
    return
  end

  local filePath = currentSavePath .. "/career/rls_career/businesses/" .. businessId .. "/jobs.json"

  local dirPath = string.match(filePath, "^(.*)/[^/]+$")
  if dirPath and not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end

  jsonWriteFile(filePath, businessJobs[businessId], true)
end

local function getFactoryConfigs()
  if factoryConfigs then
    return factoryConfigs
  end

  local eligibleVehicles = util_configListGenerator.getEligibleVehicles(false, false) or {}
  factoryConfigs = {}

  for _, vehicleInfo in ipairs(eligibleVehicles) do
    local configType = vehicleInfo["Config Type"]
    if not configType and vehicleInfo.aggregates and vehicleInfo.aggregates["Config Type"] then
      configType = next(vehicleInfo.aggregates["Config Type"])
    end
    if configType == "Factory" and not blacklistedModels[vehicleInfo.model_key] then
      table.insert(factoryConfigs, vehicleInfo)
    end
  end

  return factoryConfigs
end

local function getAvailableBrands()
  local configs = getFactoryConfigs()
  local brands = {}
  local brandSet = {}

  if not configs or #configs == 0 then
    log("W", "tuningShop", "getAvailableBrands: No factory configs found")
    return brands
  end

  for _, config in ipairs(configs) do
    if not config or not config.model_key or not config.key then
      goto continue
    end

    local brand = nil
    local vehicleInfo = getVehicleInfo(config.model_key, config.key)

    if vehicleInfo then
      if vehicleInfo.Brand and vehicleInfo.Brand ~= "" then
        brand = vehicleInfo.Brand
      elseif vehicleInfo.aggregates and vehicleInfo.aggregates.Brand then
        local brandAgg = vehicleInfo.aggregates.Brand
        if type(brandAgg) == "table" then
          brand = next(brandAgg)
        elseif type(brandAgg) == "string" then
          brand = brandAgg
        end
      end
    end

    if not brand or brand == "" then
      if config.Brand and config.Brand ~= "" then
        brand = config.Brand
      elseif config.aggregates and config.aggregates.Brand then
        local brandAgg = config.aggregates.Brand
        if type(brandAgg) == "table" then
          brand = next(brandAgg)
        elseif type(brandAgg) == "string" then
          brand = brandAgg
        end
      end
    end

    if brand and brand ~= "" and not brandSet[brand] then
      brandSet[brand] = true
      table.insert(brands, brand)
    end

    ::continue::
  end

  table.sort(brands)
  return brands
end

local function getAvailableRaceTypes()
  local races = loadRaceData()
  local raceTypes = {}

  if races and races.races then
    if races.races.track then
      table.insert(raceTypes, {
        id = "track",
        label = "Track"
      })
    end
    if races.races.track and races.races.track.altRoute then
      table.insert(raceTypes, {
        id = "trackAlt",
        label = "Short Track"
      })
    end
    if races.races.drag then
      table.insert(raceTypes, {
        id = "drag",
        label = "Drag Strip"
      })
    end
  end

  return raceTypes
end

local function getSkillTreeUpgradeCount(businessId)
  if not businessId or not career_modules_business_businessSkillTree then
    return 0
  end

  local treeId = "quality-of-life"
  local upgradeCount = 0

  local moreComplicatedLevel = career_modules_business_businessSkillTree.getNodeProgress(businessId, treeId,
    "more-complicated")
  if moreComplicatedLevel > 0 then
    upgradeCount = upgradeCount + 1
  end

  local moreComplicatedIILevel = career_modules_business_businessSkillTree.getNodeProgress(businessId, treeId,
    "more-complicated-ii")
  if moreComplicatedIILevel > 0 then
    upgradeCount = upgradeCount + 1
  end

  return upgradeCount
end

local function getMaxPulledOutVehicles(businessId)
  local limit = 1
  if not businessId or not career_modules_business_businessSkillTree then
    return limit
  end

  local treeId = "shop-upgrades"
  local upgrades = {"lift-2", "lift-3", "lift-4"}

  for _, nodeId in ipairs(upgrades) do
    local level = career_modules_business_businessSkillTree.getNodeProgress(businessId, treeId, nodeId) or 0
    if level > 0 then
      limit = limit + 1
    end
  end

  return limit
end

local function selectJobLevel(upgradeCount, maxLevels)
  if upgradeCount == 0 then
    return 1
  elseif upgradeCount == 1 then
    if math.random() < 0.5 then
      return 1
    else
      return math.min(2, maxLevels)
    end
  else
    local rand = math.random()
    if rand < 0.3333 then
      return 1
    elseif rand < 0.6666 then
      return math.min(2, maxLevels)
    else
      return math.min(3, maxLevels)
    end
  end
end

local function powerToWeightToTime(powerToWeight, raceId)
  local races = loadRaceData()
  if not races or not races.races then
    return nil
  end

  local race = nil
  if raceId == "trackAlt" then
    race = races.races.track and races.races.track.altRoute
  else
    race = races.races[raceId]
  end

  if not race or not race.predictCoef then
    return nil
  end

  local coef = race.predictCoef
  local a = coef.a
  local b = coef.b
  local c = coef.c

  local r = math.max(0.001, powerToWeight)
  local time = a + b / (r ^ c)

  return time
end

local function generateJob(businessId)
  syncJobIdCounter()
  local configs = getFactoryConfigs()
  if not configs or #configs == 0 then
    return nil
  end

  local selectedConfig = nil
  local brandSelection = getBrandSelection(businessId)
  local brandRecognitionUnlocked = getSkillTreeLevel(businessId, "quality-of-life", "brand-recognition") > 0

  if brandRecognitionUnlocked and brandSelection and brandSelection ~= "" then
    if math.random() < 0.75 then
      local brandConfigs = {}
      for _, config in ipairs(configs) do
        local vehicleInfo = getVehicleInfo(config.model_key, config.key)
        if vehicleInfo and vehicleInfo.Brand == brandSelection then
          table.insert(brandConfigs, config)
        end
      end
      if #brandConfigs > 0 then
        selectedConfig = brandConfigs[math.random(#brandConfigs)]
      end
    end
  end

  if not selectedConfig then
    selectedConfig = configs[math.random(#configs)]
  end

  local power = selectedConfig.Power
  if not power and selectedConfig.aggregates and selectedConfig.aggregates.Power then
    power = selectedConfig.aggregates.Power.min or selectedConfig.aggregates.Power.max
  end
  power = power or 0

  local weight = selectedConfig.Weight
  if not weight and selectedConfig.aggregates and selectedConfig.aggregates.Weight then
    weight = selectedConfig.aggregates.Weight.min or selectedConfig.aggregates.Weight.max
  end
  weight = weight or 0

  if power == 0 or weight == 0 then
    return nil
  end

  local powerToWeight = power / weight

  local races = loadRaceData()
  if not races or not races.races then
    return nil
  end

  local raceTypes = {"track", "trackAlt", "drag"}
  local raceType = nil
  local raceSelection = getRaceSelection(businessId)
  local raceRecognitionUnlocked = getSkillTreeLevel(businessId, "quality-of-life", "race-recognition") > 0

  if raceRecognitionUnlocked and raceSelection and raceSelection ~= "" then
    if math.random() < 0.75 then
      local isValidRaceType = false
      for _, rt in ipairs(raceTypes) do
        if rt == raceSelection then
          isValidRaceType = true
          break
        end
      end
      if isValidRaceType then
        raceType = raceSelection
      end
    end
  end

  if not raceType then
    raceType = raceTypes[math.random(#raceTypes)]
  end

  local race = nil
  local raceLabel = ""

  if raceType == "trackAlt" then
    race = races.races.track and races.races.track.altRoute
    raceLabel = race and race.label or "Short Track"
  elseif raceType == "track" then
    race = races.races.track
    raceLabel = race and race.label or "Track"
  elseif raceType == "drag" then
    race = races.races.drag
    raceLabel = race and race.label or "Drag Strip"
  end

  local baseTime = powerToWeightToTime(powerToWeight, raceType)
  if not baseTime then
    return nil
  end

  local tuningShopConfig = race and race.tuningShop or {}
  local levels = tuningShopConfig.levels or {}
  local decimalPlaces = tuningShopConfig.decimalPlaces or 0
  local commuteSeconds = tuningShopConfig.commute or tuningShopConfig.communte or 120

  if not levels or #levels == 0 then
    return nil
  end

  local upgradeCount = getSkillTreeUpgradeCount(businessId)
  local maxAvailableLevel = math.min(#levels, upgradeCount + 1)
  local selectedLevelIndex = selectJobLevel(upgradeCount, maxAvailableLevel)

  selectedLevelIndex = math.min(selectedLevelIndex, #levels)
  selectedLevelIndex = math.max(1, selectedLevelIndex)

  local levelData = levels[selectedLevelIndex]
  if not levelData then
    return nil
  end

  local minImprovement = levelData.minImprovement or 1.1
  local maxImprovement = levelData.maxImprovement or 1.2
  local minPayout = levelData.minPayout or 20000
  local maxPayout = levelData.maxPayout or 30000

  local divisor = minImprovement + math.random() * (maxImprovement - minImprovement)
  local targetTime = baseTime / divisor

  local multiplier = 10 ^ decimalPlaces
  baseTime = math.floor(baseTime * multiplier + 0.5) / multiplier
  targetTime = math.floor(targetTime * multiplier + 0.5) / multiplier

  local mileageMinMiles = 20000
  local mileageMaxMiles = 120000
  local mileageMiles = math.random(mileageMinMiles, mileageMaxMiles)
  local mileageMeters = mileageMiles * 1609.34

  local rewardRaw = minPayout + math.random() * (maxPayout - minPayout)
  local reward = math.floor(rewardRaw / 1000) * 1000

  jobIdCounter = jobIdCounter + 1

  local job = {
    jobId = jobIdCounter,
    vehicleConfig = {
      model_key = selectedConfig.model_key,
      key = selectedConfig.key
    },
    mileage = mileageMeters,
    raceType = raceType,
    raceLabel = raceLabel,
    baseTime = baseTime,
    targetTime = targetTime,
    powerToWeight = powerToWeight,
    reward = reward,
    decimalPlaces = decimalPlaces,
    commuteSeconds = commuteSeconds,
    eventReward = race and race.reward or 0,
    tier = selectedLevelIndex
  }

  return job
end

local function generateNewJobs(businessId, count)
  count = count or 5
  local newJobs = {}

  for i = 1, count do
    local job = generateJob(businessId)
    if job then
      job.businessId = businessId
      job.businessType = "tuningShop"
      job.status = "new"
      job.remainingLifetime = getJobExpirySeconds(businessId)
      table.insert(newJobs, job)
    end
  end

  return newJobs
end

local function processJobGeneration(businessId, jobs, dtSim)
  local interval = getGenerationIntervalSeconds(businessId)
  if interval <= 0 then
    return false
  end

  local timer = generationTimers[businessId] or 0
  timer = timer + dtSim

  if not jobs.new then
    jobs.new = {}
  end

  local changed = false
  while timer >= interval do
    local job = generateJob(businessId)
    if not job then
      break
    end
    job.businessId = businessId
    job.businessType = "tuningShop"
    job.status = "new"
    job.remainingLifetime = getJobExpirySeconds(businessId)
    table.insert(jobs.new, job)
    timer = timer - interval
    changed = true
  end

  generationTimers[businessId] = timer
  return changed
end

local function updateNewJobExpirations(businessId, jobs, dtSim)
  if not jobs.new or dtSim <= 0 then
    return false
  end

  local defaultLifetime = getJobExpirySeconds(businessId)
  local changed = false
  for i = #jobs.new, 1, -1 do
    local job = jobs.new[i]
    job.remainingLifetime = (tonumber(job.remainingLifetime) or defaultLifetime) - dtSim
    if job.remainingLifetime <= 0 then
      table.remove(jobs.new, i)
      changed = true
    end
  end

  return changed
end

local function getJobsForBusiness(businessId)
  local jobs = loadBusinessJobs(businessId)
  if not jobs.new then
    jobs.new = {}
  end

  return {
    active = jobs.active or {},
    new = jobs.new or {},
    completed = jobs.completed or {}
  }
end

local function acceptJob(businessId, jobId)
  if not businessId or not jobId then
    return false
  end

  jobId = tonumber(jobId) or jobId
  local jobs = loadBusinessJobs(businessId)

  local maxActiveJobs = getMaxActiveJobs(businessId)
  local currentActiveCount = #(jobs.active or {})

  if currentActiveCount >= maxActiveJobs then
    log("W", "tuningShop",
      "Cannot accept job: active job limit reached. Current: " .. tostring(currentActiveCount) .. ", Max: " ..
        tostring(maxActiveJobs))
    return false
  end

  local jobIndex = nil
  for i, job in ipairs(jobs.new or {}) do
    local jId = tonumber(job.jobId) or job.jobId
    if jId == jobId then
      jobIndex = i
      break
    end
  end

  if not jobIndex then
    return false
  end

  local job = table.remove(jobs.new, jobIndex)
  job.status = "active"
  job.acceptedTime = os.time()

  if not jobs.active then
    jobs.active = {}
  end
  table.insert(jobs.active, job)

  if job.vehicleConfig then
    local vehicleData = {
      vehicleConfig = job.vehicleConfig,
      jobId = job.jobId,
      mileage = job.mileage or 0,
      storedTime = os.time()
    }
    career_modules_business_businessInventory.storeVehicle(businessId, vehicleData)
  end

  return true
end

local function processManagerAssignments(businessId)
  if not businessId then
    return false
  end

  if not hasManager(businessId) then
    return false
  end

  local timerState = getManagerTimerState(businessId)
  local isGeneralManager = hasGeneralManager(businessId)
  local flagActive = isGeneralManager or timerState.flagActive

  if not flagActive then
    return false
  end

  local idleTechs = tuningShopTechs.getIdleTechs(businessId)
  if #idleTechs == 0 then
    return false
  end

  if not tuningShopTechs.canAssignTechToJob(businessId) then
    return false
  end

  local jobs = loadBusinessJobs(businessId)
  if not jobs.new or #jobs.new == 0 then
    return false
  end

  local maxActiveJobs = getMaxActiveJobs(businessId)
  local currentActiveCount = #(jobs.active or {})

  if currentActiveCount >= maxActiveJobs then
    return false
  end

  local techMaxTier = tuningShopTechs.getTechMaxTier(businessId)
  local suitableJob = nil
  local suitableJobIndex = nil

  for i, newJob in ipairs(jobs.new) do
    local jobTier = tonumber(newJob.tier) or 1
    if jobTier <= techMaxTier then
      suitableJob = newJob
      suitableJobIndex = i
      break
    end
  end

  if not suitableJob then
    return false
  end

  local jobId = tonumber(suitableJob.jobId) or suitableJob.jobId
  if not jobId then
    return false
  end

  local acceptSuccess = acceptJob(businessId, jobId)
  if not acceptSuccess then
    return false
  end

  local idleTech = idleTechs[1]
  if not idleTech then
    return false
  end

  local assignSuccess, assignError = tuningShopTechs.assignJobToTech(businessId, idleTech.id, jobId)
  if not assignSuccess then
    return false
  end

  if not isGeneralManager then
    timerState.flagActive = false
    managerTimers[businessId] = timerState
  end

  return true
end

local function declineJob(businessId, jobId)
  if not businessId or not jobId then
    return false
  end

  jobId = tonumber(jobId) or jobId
  local jobs = loadBusinessJobs(businessId)

  local jobIndex = nil
  for i, job in ipairs(jobs.new or {}) do
    local jId = tonumber(job.jobId) or job.jobId
    if jId == jobId then
      jobIndex = i
      break
    end
  end

  if jobIndex then
    table.remove(jobs.new, jobIndex)
    return true
  end

  return false
end

local function getJobCurrentTime(businessId, jobId)
  local job = getJobById(businessId, jobId)
  if not job or not job.raceLabel then
    return nil
  end

  local bestTime = career_modules_business_businessHelpers.getBestLeaderboardTime(businessId, jobId, job.raceType,
    job.raceLabel)

  local currentTime = bestTime or job.currentTime or job.baseTime
  if not currentTime then
    return nil
  end

  local decimalPlaces = job.decimalPlaces or 0
  local multiplier = 10 ^ decimalPlaces
  return math.floor(currentTime * multiplier + 0.5) / multiplier
end

local function canCompleteJob(businessId, jobId)
  if not businessId or not jobId then
    return false
  end

  jobId = tonumber(jobId) or jobId
  local job = getJobById(businessId, jobId)
  if not job or job.status ~= "active" then
    return false
  end

  if not job.raceType or not job.targetTime then
    return false
  end

  local currentTime = getJobCurrentTime(businessId, jobId)
  if not currentTime then
    return false
  end

  local targetTime = job.targetTime
  if (job.raceType == "track" or job.raceType == "trackAlt") and targetTime > 1000 then
    targetTime = targetTime * 60
  end

  if job.raceType == "drag" or job.raceType == "track" or job.raceType == "trackAlt" then
    return currentTime <= targetTime
  end

  return false
end

local function completeJob(businessId, jobId)
  if not businessId or not jobId then
    log("E", "tuningShop",
      "completeJob: Missing parameters. businessId=" .. tostring(businessId) .. ", jobId=" .. tostring(jobId))
    return false
  end

  jobId = tonumber(jobId) or jobId
  local jobs = loadBusinessJobs(businessId)

  local jobIndex = nil
  for i, job in ipairs(jobs.active or {}) do
    local jId = tonumber(job.jobId) or job.jobId
    if jId == jobId then
      jobIndex = i
      break
    end
  end

  if not jobIndex then
    log("E", "tuningShop", "completeJob: Job not found in active jobs. businessId=" .. tostring(businessId) ..
      ", jobId=" .. tostring(jobId))
    return false
  end

  local job = jobs.active[jobIndex]

  if not canCompleteJob(businessId, jobId) then
    log("E", "tuningShop",
      "completeJob: Job cannot be completed. businessId=" .. tostring(businessId) .. ", jobId=" .. tostring(jobId))
    return false
  end

  local reward = job.reward or 20000
  if career_modules_bank then
    local businessAccount = career_modules_bank.getBusinessAccount("tuningShop", businessId)
    if not businessAccount then
      career_modules_bank.createBusinessAccount("tuningShop", businessId)
      businessAccount = career_modules_bank.getBusinessAccount("tuningShop", businessId)
    end
    if businessAccount then
      local accountId = businessAccount.id
      local success = career_modules_bank.rewardToAccount({
        money = {
          amount = reward
        }
      }, accountId, "Job Reward", "Job #" .. tostring(jobId) .. " completed")
      if not success then
        log("E", "tuningShop",
          "completeJob: Failed to reward account. businessId=" .. tostring(businessId) .. ", jobId=" .. tostring(jobId) ..
            ", accountId=" .. tostring(accountId) .. ", reward=" .. tostring(reward))
        return false
      end
    else
      log("E", "tuningShop", "completeJob: Business account not found. businessId=" .. tostring(businessId) ..
        ", jobId=" .. tostring(jobId))
      return false
    end
  else
    log("E", "tuningShop", "completeJob: career_modules_bank not available. businessId=" .. tostring(businessId) ..
      ", jobId=" .. tostring(jobId))
    return false
  end

  -- Award XP
  local baseXP = 10
  local xpMultiplier = getXPGainMultiplier(businessId)
  local xpReward = math.floor(baseXP * xpMultiplier)

  addBusinessXP(businessId, xpReward)

  local vehicleToRemove = getVehicleByJobId(businessId, jobId)

  if vehicleToRemove then
    local removeId = tonumber(vehicleToRemove.vehicleId) or vehicleToRemove.vehicleId
    if career_modules_business_businessInventory.getPulledOutVehicles then
      local pulledVehicles = career_modules_business_businessInventory.getPulledOutVehicles(businessId) or {}
      for _, pulled in ipairs(pulledVehicles) do
        local pulledId = tonumber(pulled.vehicleId) or pulled.vehicleId
        if pulledId == removeId then
          career_modules_business_businessInventory.putAwayVehicle(businessId, removeId)
          break
        end
      end
    else
      local pulledOutVehicle = career_modules_business_businessInventory.getPulledOutVehicle(businessId)
      if pulledOutVehicle then
        local pulledId = tonumber(pulledOutVehicle.vehicleId) or pulledOutVehicle.vehicleId
        if pulledId == removeId then
          career_modules_business_businessInventory.putAwayVehicle(businessId)
        end
      end
    end
    career_modules_business_businessInventory.removeVehicle(businessId, vehicleToRemove.vehicleId)
  end

  local leaderboardManager = require('gameplay/events/freeroam/leaderboardManager')
  local businessJobId = career_modules_business_businessInventory.getBusinessJobIdentifier(businessId, jobId)
  leaderboardManager.clearLeaderboardForVehicle(businessJobId)

  job = table.remove(jobs.active, jobIndex)
  job.status = "completed"
  job.completedTime = os.time()

  if not jobs.completed then
    jobs.completed = {}
  end
  table.insert(jobs.completed, job)

  career_saveSystem.saveCurrent()

  return true
end

local function abandonJob(businessId, jobId)
  if not businessId or not jobId then
    return false
  end

  jobId = tonumber(jobId) or jobId
  local jobs = loadBusinessJobs(businessId)

  local jobIndex = nil
  local job = nil
  for i, activeJob in ipairs(jobs.active or {}) do
    local jId = tonumber(activeJob.jobId) or activeJob.jobId
    if jId == jobId then
      jobIndex = i
      job = activeJob
      break
    end
  end

  if not jobIndex or not job then
    return false
  end

  local vehicles = career_modules_business_businessInventory.getBusinessVehicles(businessId)
  local vehicleToRemove = nil
  for _, vehicle in ipairs(vehicles) do
    local vJobId = tonumber(vehicle.jobId) or vehicle.jobId
    if vJobId == jobId then
      vehicleToRemove = vehicle
      break
    end
  end

  if vehicleToRemove then
    local removeId = tonumber(vehicleToRemove.vehicleId) or vehicleToRemove.vehicleId
    if career_modules_business_businessInventory.getPulledOutVehicles then
      local pulledVehicles = career_modules_business_businessInventory.getPulledOutVehicles(businessId) or {}
      for _, pulled in ipairs(pulledVehicles) do
        local pulledId = tonumber(pulled.vehicleId) or pulled.vehicleId
        if pulledId == removeId then
          career_modules_business_businessInventory.putAwayVehicle(businessId, removeId)
          break
        end
      end
    else
      local pulledOutVehicle = career_modules_business_businessInventory.getPulledOutVehicle(businessId)
      if pulledOutVehicle then
        local pulledId = tonumber(pulledOutVehicle.vehicleId) or pulledOutVehicle.vehicleId
        if pulledId == removeId then
          career_modules_business_businessInventory.putAwayVehicle(businessId)
        end
      end
    end
    career_modules_business_businessInventory.removeVehicle(businessId, vehicleToRemove.vehicleId)
  end

  local leaderboardManager = require('gameplay/events/freeroam/leaderboardManager')
  local businessJobId = career_modules_business_businessInventory.getBusinessJobIdentifier(businessId, jobId)
  leaderboardManager.clearLeaderboardForVehicle(businessJobId)

  local penalty = getAbandonPenalty(businessId, jobId)

  if penalty > 0 then
    if career_modules_bank then
      local businessName = job.businessName or ("tuningShop " .. tostring(businessId))
      local businessAccount = career_modules_bank.getBusinessAccount("tuningShop", businessId)
      if not businessAccount then
        career_modules_bank.createBusinessAccount("tuningShop", businessId, businessName)
        businessAccount = career_modules_bank.getBusinessAccount("tuningShop", businessId)
      end

      if businessAccount then
        local success = career_modules_bank.removeFunds(businessAccount.id, penalty, "Job Penalty",
          "Abandoned Job #" .. tostring(jobId), "penalty", true)
        if not success then
          return false
        end
      else
        return false
      end
    else
      return false
    end
  end

  table.remove(jobs.active, jobIndex)

  return true
end

-- UI Data and Helpers

local function formatJobForUI(job, businessId)
  if not job then
    return nil
  end

  local vehicleConfig = job.vehicleConfig or {}
  local modelKey = vehicleConfig.model_key or "unknown"
  local configKey = vehicleConfig.key or "unknown"

  local vehicleInfo = getVehicleInfo(modelKey, configKey)
  local vehicleName = modelKey
  local vehicleYear = "Unknown"
  local vehicleType = "Unknown"
  local vehicleImage = "/ui/images/appDefault.png"

  if vehicleInfo then
    if vehicleInfo.Brand and vehicleInfo.Name then
      vehicleName = vehicleInfo.Brand .. " " .. vehicleInfo.Name
    elseif vehicleInfo.Name then
      vehicleName = vehicleInfo.Name
    end

    local years = vehicleInfo.Years or (vehicleInfo.aggregates and vehicleInfo.aggregates.Years)
    if years then
      if type(years) == "table" and years.min and years.max then
        vehicleYear = tostring(years.min)
      elseif type(years) == "number" then
        vehicleYear = tostring(years)
      end
    elseif vehicleInfo.Year then
      vehicleYear = tostring(vehicleInfo.Year)
    end

    if vehicleInfo["Body Style"] then
      vehicleType = vehicleInfo["Body Style"]
    elseif vehicleInfo.Type then
      vehicleType = vehicleInfo.Type
    end

    if vehicleInfo.preview then
      vehicleImage = vehicleInfo.preview
    end
  end

  local timeUnit = "s"
  if job.raceType == "track" or job.raceType == "trackAlt" then
    timeUnit = "min"
  end

  local goalTimeFormatted = ""
  local goalTimeSeconds = job.targetTime or 0
  local decimalPlaces = job.decimalPlaces or 0
  if goalTimeSeconds >= 60 then
    local minutes = math.floor(goalTimeSeconds / 60)
    local seconds = math.floor(goalTimeSeconds % 60 + 0.5)
    if seconds >= 1 then
      goalTimeFormatted = string.format("%d min %d s", minutes, seconds)
    else
      goalTimeFormatted = string.format("%d min", minutes)
    end
  else
    if decimalPlaces > 0 then
      goalTimeFormatted = string.format("%." .. decimalPlaces .. "f s", goalTimeSeconds)
    else
      goalTimeFormatted = string.format("%d s", math.floor(goalTimeSeconds + 0.5))
    end
  end

  local goal = goalTimeFormatted .. " " .. (job.raceLabel or "")

  local baselineTime = job.baseTime or 0
  local currentTime = job.currentTime or job.baseTime or 0
  local goalTime = job.targetTime or 0

  if job.raceLabel and businessId and job.jobId then
    local bestTime = career_modules_business_businessHelpers.getBestLeaderboardTime(businessId, job.jobId, job.raceType,
      job.raceLabel)
    if bestTime then
      currentTime = bestTime
    end
  end

  local decimalPlaces = job.decimalPlaces or 0
  local multiplier = 10 ^ decimalPlaces
  baselineTime = math.floor(baselineTime * multiplier + 0.5) / multiplier
  currentTime = math.floor(currentTime * multiplier + 0.5) / multiplier
  goalTime = math.floor(goalTime * multiplier + 0.5) / multiplier

  local penalty = getAbandonPenalty(businessId, job.jobId)
  local expiresInSeconds = nil
  if job.status == "new" then
    local lifetime = tonumber(job.remainingLifetime)
    if not lifetime or lifetime < 0 then
      lifetime = getJobExpirySeconds(businessId)
    end
    expiresInSeconds = math.max(0, math.floor(lifetime))
  end

  return {
    id = tostring(job.jobId),
    jobId = job.jobId,
    vehicleName = vehicleName,
    vehicleYear = vehicleYear or "Unknown",
    vehicleType = vehicleType,
    vehicleImage = vehicleImage,
    goal = goal,
    reward = job.reward or 20000,
    status = job.status or "new",
    baselineTime = baselineTime,
    currentTime = currentTime,
    goalTime = goalTime,
    timeUnit = timeUnit,
    raceType = job.raceType,
    raceLabel = job.raceLabel,
    decimalPlaces = job.decimalPlaces or 0,
    expiresInSeconds = expiresInSeconds,
    penalty = penalty,
    techAssigned = job.techAssigned,
    isLocked = job.locked or false,
    tier = tonumber(job.tier) or 1
  }
end

local function formatVehicleForUI(vehicle, businessId)
  if not vehicle then
    return nil
  end

  local vehicleConfig = vehicle.vehicleConfig or {}
  local modelKey = vehicleConfig.model_key or vehicle.model_key or "unknown"
  local configKey = vehicleConfig.key or vehicle.config_key or "unknown"

  local vehicleInfo = getVehicleInfo(modelKey, configKey)
  local vehicleName = modelKey
  local vehicleYear = "Unknown"
  local vehicleType = "Unknown"
  local vehicleImage = "/ui/images/appDefault.png"

  if vehicleInfo then
    if vehicleInfo.Brand and vehicleInfo.Name then
      vehicleName = vehicleInfo.Brand .. " " .. vehicleInfo.Name
    elseif vehicleInfo.Name then
      vehicleName = vehicleInfo.Name
    end

    local years = vehicleInfo.Years or (vehicleInfo.aggregates and vehicleInfo.aggregates.Years)
    if years then
      if type(years) == "table" and years.min and years.max then
        vehicleYear = tostring(years.min)
      elseif type(years) == "number" then
        vehicleYear = tostring(years)
      end
    elseif vehicleInfo.Year then
      vehicleYear = tostring(vehicleInfo.Year)
    end

    if vehicleInfo["Body Style"] then
      vehicleType = vehicleInfo["Body Style"]
    elseif vehicleInfo.Type then
      vehicleType = vehicleInfo.Type
    end

    if vehicleInfo.preview then
      vehicleImage = vehicleInfo.preview
    end
  end

  local spawnedVehicleId = vehicle.spawnedVehicleId
  if not spawnedVehicleId and career_modules_business_businessInventory and
    career_modules_business_businessInventory.getSpawnedVehicleId then
    spawnedVehicleId = career_modules_business_businessInventory.getSpawnedVehicleId(businessId, vehicle.vehicleId)
  end

  local result = {
    id = tostring(vehicle.vehicleId),
    vehicleId = vehicle.vehicleId,
    vehicleName = vehicleName,
    vehicleYear = vehicleYear,
    vehicleType = vehicleType,
    vehicleImage = vehicleImage,
    jobId = vehicle.jobId,
    storedTime = vehicle.storedTime,
    spawnedVehicleId = spawnedVehicleId,
    model_key = modelKey,
    config_key = configKey
  }

  if vehicle.isPersonal then
    result.isPersonal = true
    result.inventoryId = vehicle.inventoryId
    result.spawnedVehicleId = vehicle.spawnedVehicleId
    result.inGarageZone = true
  end

  return result
end

local function getBusinessVehicleObject(businessId, vehicleId)
  if not businessId or not vehicleId then
    return nil
  end

  if career_modules_business_businessInventory then
    local vehId = career_modules_business_businessInventory.getSpawnedVehicleId(businessId, vehicleId)
    if vehId then
      return getObjectByID(vehId)
    end
  end

  return nil
end

local function getVehicleDamageByVehId(vehId)
  if not vehId or not map or not map.objects then
    return 0
  end

  local objectData = map.objects[vehId]
  if not objectData then
    return 0
  end

  return objectData.damage or 0
end

local function isDamageLocked(businessId, vehicleId)
  local lockInfo = {
    locked = false,
    damage = 0,
    threshold = DAMAGE_LOCK_THRESHOLD
  }

  if not businessId or not vehicleId then
    return lockInfo
  end

  local vehObj = getBusinessVehicleObject(businessId, vehicleId)
  if not vehObj then
    return lockInfo
  end

  local vehId = vehObj:getID()
  if not vehId then
    return lockInfo
  end

  local damage = getVehicleDamageByVehId(vehId)
  lockInfo.damage = damage
  lockInfo.locked = damage >= DAMAGE_LOCK_THRESHOLD

  return lockInfo
end

local function getOperatingCosts(businessId)
  if not businessId then
    return {
      baseLift = 5000,
      additionalLifts = 0,
      techs = 0,
      manager = 0,
      generalManager = 0,
      total = 5000,
      maxCost = 55000,
      solarPowerActive = false
    }
  end

  local baseLift = 5000
  local additionalLifts = 0
  local techsCost = 0
  local managerCost = 0
  local generalManagerCost = 0
  local solarPowerActive = false

  if career_modules_business_businessSkillTree then
    local treeId = "shop-upgrades"

    local lift2Level = career_modules_business_businessSkillTree.getNodeProgress(businessId, treeId, "lift-2") or 0
    local lift3Level = career_modules_business_businessSkillTree.getNodeProgress(businessId, treeId, "lift-3") or 0
    local lift4Level = career_modules_business_businessSkillTree.getNodeProgress(businessId, treeId, "lift-4") or 0

    if lift2Level > 0 then
      additionalLifts = additionalLifts + 1
    end
    if lift3Level > 0 then
      additionalLifts = additionalLifts + 1
    end
    if lift4Level > 0 then
      additionalLifts = additionalLifts + 1
    end

    local solarLevel = career_modules_business_businessSkillTree.getNodeProgress(businessId, treeId, "solar-panels") or
                         0
    solarPowerActive = solarLevel > 0

    local automationTreeId = "automation"
    local managerLevel = career_modules_business_businessSkillTree.getNodeProgress(businessId, automationTreeId,
      "manager") or 0
    local generalManagerLevel = career_modules_business_businessSkillTree.getNodeProgress(businessId, automationTreeId,
      "general-manager") or 0

    if managerLevel > 0 then
      managerCost = 5000
    end
    if generalManagerLevel > 0 then
      generalManagerCost = 25000
    end
  end

  local techList = tuningShopTechs.getTechsForBusiness(businessId) or {}
  local techCount = #techList
  techsCost = techCount * 2500

  local additionalLiftsCost = additionalLifts * 5000
  local total = baseLift + additionalLiftsCost + techsCost + managerCost + generalManagerCost
  local maxCost = 55000

  if solarPowerActive then
    total = 0
  end

  return {
    baseLift = baseLift,
    additionalLifts = additionalLifts,
    additionalLiftsCost = additionalLiftsCost,
    techs = techCount,
    techsCost = techsCost,
    manager = managerCost > 0 and 1 or 0,
    managerCost = managerCost,
    generalManager = generalManagerCost > 0 and 1 or 0,
    generalManagerCost = generalManagerCost,
    total = total,
    maxCost = maxCost,
    solarPowerActive = solarPowerActive
  }
end

local function processOperatingCosts(businessId, dtSim)
  if not businessId or dtSim <= 0 then
    return false
  end

  local operatingCosts = getOperatingCosts(businessId)
  if operatingCosts.solarPowerActive or operatingCosts.total <= 0 then
    return false
  end

  local timerState = loadOperatingCostTimer(businessId)
  local paymentInterval = 1800

  timerState.elapsed = timerState.elapsed + dtSim

  local charged = false
  if timerState.elapsed >= paymentInterval then
    local currentTime = os.time()
    local success = debitBusinessAccount(businessId, operatingCosts.total, "Operating Costs",
      string.format("Operating costs: Base Lift $%d, Additional Lifts $%d, Techs $%d, Manager $%d, General Manager $%d",
        operatingCosts.baseLift, operatingCosts.additionalLiftsCost, operatingCosts.techsCost,
        operatingCosts.managerCost, operatingCosts.generalManagerCost))

    if success then
      timerState.elapsed = math.max(0, timerState.elapsed - paymentInterval)
      timerState.lastChargeTime = currentTime
      charged = true
    else
      timerState.elapsed = 0
    end
  end

  operatingCostTimers[businessId] = timerState
  return charged
end

local function getFinancesData(businessId)
  if not businessId then
    return nil
  end

  local operatingCosts = getOperatingCosts(businessId)

  local account = nil
  local accountBalance = 0
  local accountId = nil
  local transactions = {}
  local businessLoans = {}

  if career_modules_bank then
    account = career_modules_bank.getBusinessAccount("tuningShop", businessId)
    if account then
      accountId = account.id
      accountBalance = career_modules_bank.getAccountBalance(accountId) or 0
      transactions = career_modules_bank.getAccountTransactions(accountId, 100) or {}
    end
  end

  if career_modules_loans and accountId then
    local allLoans = career_modules_loans.getActiveLoans() or {}
    for _, loan in ipairs(allLoans) do
      if loan.businessAccountId == accountId then
        table.insert(businessLoans, loan)
      end
    end
  end

  local operatingCostTimer = nil
  if not operatingCosts.solarPowerActive and operatingCosts.total > 0 then
    local timerState = loadOperatingCostTimer(businessId)
    local paymentInterval = 1800
    local remainingTime = paymentInterval - (timerState.elapsed % paymentInterval)
    operatingCostTimer = {
      elapsed = timerState.elapsed,
      lastChargeTime = timerState.lastChargeTime,
      paymentInterval = paymentInterval,
      remainingTime = remainingTime
    }
  end

  return {
    operatingCosts = operatingCosts,
    account = {
      id = accountId,
      balance = accountBalance,
      name = account and account.name or nil
    },
    transactions = transactions,
    loans = businessLoans,
    operatingCostTimer = operatingCostTimer
  }
end

local function requestFinancesData(businessId)
  if not businessId then
    if guihooks then
      guihooks.trigger('businessComputer:onFinancesData', {
        success = false,
        error = "Missing businessId"
      })
    end
    return
  end

  local financesData = getFinancesData(businessId)
  if not financesData then
    if guihooks then
      guihooks.trigger('businessComputer:onFinancesData', {
        success = false,
        error = "Failed to get finances data",
        businessId = businessId
      })
    end
    return
  end

  local data = {
    success = true,
    businessId = businessId,
    finances = financesData,
    simulationTime = os.time()
  }

  if guihooks then
    guihooks.trigger('businessComputer:onFinancesData', data)
  end
end

local function requestSimulationTime()
  if guihooks then
    guihooks.trigger('businessComputer:onSimulationTime', {
      success = true,
      simulationTime = os.time()
    })
  end
end

local function ensureTabsRegistered()
  if not career_modules_business_businessTabRegistry then
    log("W", "TuningShop", "Tab registry not available")
    return false
  end

  local existingTabs = career_modules_business_businessTabRegistry.getTabs("tuningShop") or {}
  if #existingTabs > 0 then
    return true
  end

  log("I", "TuningShop", "Registering tabs for tuningShop")

  career_modules_business_businessTabRegistry.registerTab("tuningShop", {
    id = "home",
    label = "Home",
    icon = '<path d="M3 9l9-7 9 7v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/><polyline points="9 22 9 12 15 12 15 22"/>',
    component = "BusinessHomeView",
    section = "BASIC",
    order = 1
  })

  career_modules_business_businessTabRegistry.registerTab("tuningShop", {
    id = "jobs",
    label = "Jobs",
    icon = '<path d="M9 11l3 3L22 4M21 12v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11"/>',
    component = "BusinessJobsTab",
    section = "BASIC",
    order = 2
  })

  career_modules_business_businessTabRegistry.registerTab("tuningShop", {
    id = "kits",
    label = "Kits",
    icon = '<rect x="9" y="9" width="13" height="13" rx="2" ry="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/>',
    component = "BusinessKitsTab",
    section = "BASIC",
    order = 2.5
  })

  career_modules_business_businessTabRegistry.registerTab("tuningShop", {
    id = "inventory",
    label = "Inventory",
    icon = '<path d="M16.5 9.4l-9-5.19M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z"/><polyline points="3.27 6.96 12 12.01 20.73 6.96"/><line x1="12" y1="22.08" x2="12" y2="12"/>',
    component = "BusinessInventoryTab",
    section = "BASIC",
    order = 3
  })

  career_modules_business_businessTabRegistry.registerTab("tuningShop", {
    id = "techs",
    label = "Techs",
    icon = '<circle cx="12" cy="7" r="4"/><path d="M6 21v-2a4 4 0 0 1 4-4h4a4 4 0 0 1 4 4v2"/><circle cx="19" cy="7" r="3"/><path d="M22 21v-2a3 3 0 0 0-3-3h-2"/>',
    component = "BusinessTechsTab",
    section = "BASIC",
    order = 4
  })

  career_modules_business_businessTabRegistry.registerTab("tuningShop", {
    id = "finances",
    label = "Finances",
    icon = '<path d="M12 2v20M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6"/>',
    component = "BusinessFinancesTab",
    section = "BASIC",
    order = 5
  })

  return true
end

local function getUIData(businessId)
  if not businessId then
    return nil
  end

  local businessType = "tuningShop"
  local business = freeroam_facilities.getFacility(businessType, businessId)
  if not business then
    return nil
  end

  local playerInZone = isPlayerInTuningShopZone(businessId)

  local jobs = getJobsForBusiness(businessId)
  local vehicles = career_modules_business_businessInventory.getBusinessVehicles(businessId)
  local parts = {}
  local pulledOutVehiclesRaw = {}
  if career_modules_business_businessInventory.getPulledOutVehicles then
    pulledOutVehiclesRaw = career_modules_business_businessInventory.getPulledOutVehicles(businessId) or {}
  else
    local singleVehicle = career_modules_business_businessInventory.getPulledOutVehicle(businessId)
    if singleVehicle then
      pulledOutVehiclesRaw = {singleVehicle}
    end
  end

  local pulledOutVehiclesInZone = {}
  for _, vehicle in ipairs(pulledOutVehiclesRaw) do
    if isSpawnedVehicleInGarageZone(businessId, vehicle.vehicleId) then
      table.insert(pulledOutVehiclesInZone, vehicle)
    end
  end

  local personalVehiclesInZone = {}
  local personalUseUnlocked = isPersonalUseUnlocked(businessId)
  if personalUseUnlocked and playerInZone then
    local inventoryVehiclesInZone = getInventoryVehiclesInGarageZone(businessId)
    for _, invVeh in ipairs(inventoryVehiclesInZone) do
      local personalEntry = createPersonalVehicleEntry(businessId, invVeh.inventoryId, invVeh.inventoryVehicleData, invVeh.spawnedId)
      if personalEntry then
        table.insert(personalVehiclesInZone, personalEntry)
      end
    end
  end

  local activeVehicle = nil
  local selectedPersonalVehicle = false
  if career_modules_business_businessInventory.getActiveVehicle then
    local rawActive = career_modules_business_businessInventory.getActiveVehicle(businessId)
    if rawActive and isSpawnedVehicleInGarageZone(businessId, rawActive.vehicleId) then
      activeVehicle = rawActive
    elseif #pulledOutVehiclesInZone > 0 then
      activeVehicle = pulledOutVehiclesInZone[1]
    elseif #personalVehiclesInZone > 0 then
      activeVehicle = personalVehiclesInZone[1]
      selectedPersonalVehicle = true
    end
  else
    if #pulledOutVehiclesInZone > 0 then
      activeVehicle = pulledOutVehiclesInZone[1]
    elseif #personalVehiclesInZone > 0 then
      activeVehicle = personalVehiclesInZone[1]
      selectedPersonalVehicle = true
    end
  end

  -- Auto-store the active personal vehicle so enterShoppingVehicle can find it
  if selectedPersonalVehicle and activeVehicle and activeVehicle.isPersonal then
    activePersonalVehicle[businessId] = activeVehicle
  end

  local activeVehicleId = activeVehicle and (tonumber(activeVehicle.vehicleId) or activeVehicle.vehicleId)
  local pulledOutDamageInfo = {
    locked = false,
    damage = 0,
    threshold = DAMAGE_LOCK_THRESHOLD
  }
  local formattedPulledOutVehicles = {}
  local hasDamageLockedVehicle = false
  for _, vehicle in ipairs(pulledOutVehiclesInZone) do
    local formatted = formatVehicleForUI(vehicle, businessId)
    if formatted then
      local vehicleDamageInfo = isDamageLocked(businessId, vehicle.vehicleId)
      if vehicleDamageInfo.locked then
        hasDamageLockedVehicle = true
      end
      formatted.damage = vehicleDamageInfo.damage
      formatted.damageLocked = vehicleDamageInfo.locked
      formatted.damageThreshold = vehicleDamageInfo.threshold
      formatted.inGarageZone = true
      if activeVehicleId and (tonumber(formatted.vehicleId) or formatted.vehicleId) == activeVehicleId then
        formatted.isActive = true
        pulledOutDamageInfo = vehicleDamageInfo
      else
        formatted.isActive = false
      end
      table.insert(formattedPulledOutVehicles, formatted)
    end
  end

  for _, personalVehicle in ipairs(personalVehiclesInZone) do
    local formatted = formatVehicleForUI(personalVehicle, businessId)
    if formatted then
      formatted.damage = 0
      formatted.damageLocked = false
      formatted.damageThreshold = DAMAGE_LOCK_THRESHOLD
      formatted.inGarageZone = true
      formatted.isPersonal = true
      formatted.inventoryId = personalVehicle.inventoryId
      formatted.spawnedVehicleId = personalVehicle.spawnedVehicleId
      if activeVehicleId and formatted.vehicleId == activeVehicleId then
        formatted.isActive = true
      else
        formatted.isActive = false
      end
      table.insert(formattedPulledOutVehicles, formatted)
    end
  end

  local activeJobs = {}
  for _, job in ipairs(jobs.active or {}) do
    table.insert(activeJobs, formatJobForUI(job, businessId))
  end

  local newJobs = {}
  for _, job in ipairs(jobs.new or {}) do
    table.insert(newJobs, formatJobForUI(job, businessId))
  end

  local vehicleList = {}
  if playerInZone then
    for _, vehicle in ipairs(vehicles) do
      table.insert(vehicleList, formatVehicleForUI(vehicle, businessId))
    end
  end

  local pulledOutVehicleData = nil
  if activeVehicle then
    pulledOutVehicleData = formatVehicleForUI(activeVehicle, businessId)
    if pulledOutVehicleData then
      pulledOutVehicleData.inGarageZone = true
      pulledOutVehicleData.damage = pulledOutDamageInfo.damage
      pulledOutVehicleData.damageLocked = pulledOutDamageInfo.locked
      pulledOutVehicleData.damageThreshold = pulledOutDamageInfo.threshold
      if activeVehicle.isPersonal then
        pulledOutVehicleData.isPersonal = true
        pulledOutVehicleData.inventoryId = activeVehicle.inventoryId
        pulledOutVehicleData.spawnedVehicleId = activeVehicle.spawnedVehicleId
      end
    end
  end

  local totalPartsValue = 0
  for _, part in ipairs(parts) do
    totalPartsValue = totalPartsValue + (part.price or part.value or 0)
  end

  local tabs = {}
  if career_modules_business_businessTabRegistry then
    ensureTabsRegistered()
    if career_modules_business_businessSkillTree and career_modules_business_businessSkillTree.ensureTabsRegistered then
      pcall(function()
        career_modules_business_businessSkillTree.ensureTabsRegistered(businessType)
      end)
    end
    tabs = career_modules_business_businessTabRegistry.getTabs(businessType) or {}
    log("I", "tuningShop", "getUIData: Got " .. tostring(#tabs) .. " tabs from registry")

    if hasDamageLockedVehicle then
      local allowedTabs = {
        home = true,
        jobs = true,
        techs = true
      }

      local filteredTabs = {}
      for _, tab in ipairs(tabs) do
        if tab.id and allowedTabs[tab.id] then
          table.insert(filteredTabs, tab)
        end
      end
      tabs = filteredTabs
    end

    local tuningShopKits = getTuningShopKits()
    if tuningShopKits and not tuningShopKits.hasKitStorageUnlocked(businessId) then
      local filteredTabs = {}
      for _, tab in ipairs(tabs) do
        if tab.id ~= "kits" then
          table.insert(filteredTabs, tab)
        end
      end
      tabs = filteredTabs
    end
  else
    log('W', 'tuningShop', 'Tab registry not available')
  end

  local techEntries = {}
  local techList = tuningShopTechs.loadBusinessTechs(businessId)
  for _, tech in ipairs(techList) do
    local formattedTech = tuningShopTechs.formatTechForUIEntry(businessId, tech)
    if formattedTech then
      table.insert(techEntries, formattedTech)
    end
  end

  return {
    businessId = businessId,
    businessType = businessType,
    businessName = business.name or "Tuning Shop",
    activeJobs = activeJobs,
    newJobs = newJobs,
    vehicles = vehicleList,
    parts = parts,
    pulledOutVehicle = pulledOutVehicleData,
    pulledOutVehicles = formattedPulledOutVehicles,
    activeVehicleId = activeVehicleId,
    maxPulledOutVehicles = getMaxPulledOutVehicles(businessId),
    tabs = tabs,
    techs = techEntries,
    vehicleDamage = pulledOutDamageInfo.damage,
    vehicleDamageLocked = pulledOutDamageInfo.locked,
    vehicleDamageThreshold = pulledOutDamageInfo.threshold,
    maxActiveJobs = getMaxActiveJobs(businessId),
    playerInZone = playerInZone,
    stats = {
      totalVehicles = #vehicleList,
      totalParts = #parts,
      totalPartsValue = totalPartsValue,
      activeJobsCount = #activeJobs,
      newJobsCount = #newJobs,
      kits = getTuningShopKits().loadBusinessKits(businessId),
      maxKitStorage = getTuningShopKits().getMaxKitStorage(businessId),
      currentKitCount = #(getTuningShopKits().loadBusinessKits(businessId))
    },
    hasManager = hasManager(businessId),
    hasGeneralManager = hasGeneralManager(businessId),
    managerAssignmentInterval = hasManager(businessId) and getManagerAssignmentInterval(businessId) or nil,
    managerReadyToAssign = (function()
      if not hasManager(businessId) then
        return false
      end
      if hasGeneralManager(businessId) then
        return true
      end
      local timerState = getManagerTimerState(businessId)
      return timerState.flagActive == true
    end)(),
    managerTimeRemaining = (function()
      if not hasManager(businessId) or hasGeneralManager(businessId) then
        return nil
      end
      local timerState = getManagerTimerState(businessId)
      local interval = getManagerAssignmentInterval(businessId)
      return math.max(0, interval - timerState.elapsed)
    end)(),
    personalUseUnlocked = personalUseUnlocked
  }
end

local function getManagerData(businessId)
  if not businessId then
    return nil
  end

  return {
    hasManager = hasManager(businessId),
    hasGeneralManager = hasGeneralManager(businessId),
    managerAssignmentInterval = hasManager(businessId) and getManagerAssignmentInterval(businessId) or nil,
    managerReadyToAssign = (function()
      if not hasManager(businessId) then
        return false
      end
      if hasGeneralManager(businessId) then
        return true
      end
      local timerState = getManagerTimerState(businessId)
      return timerState.flagActive == true
    end)(),
    managerTimeRemaining = (function()
      if not hasManager(businessId) or hasGeneralManager(businessId) then
        return nil
      end
      local timerState = getManagerTimerState(businessId)
      local interval = getManagerAssignmentInterval(businessId)
      return math.max(0, interval - timerState.elapsed)
    end)()
  }
end

local function getActiveJobs(businessId)
  local jobs = getJobsForBusiness(businessId)
  local activeJobs = {}
  for _, job in ipairs(jobs.active or {}) do
    table.insert(activeJobs, formatJobForUI(job, businessId))
  end
  return activeJobs
end

local function getNewJobs(businessId)
  local jobs = getJobsForBusiness(businessId)
  local newJobs = {}
  for _, job in ipairs(jobs.new or {}) do
    table.insert(newJobs, formatJobForUI(job, businessId))
  end
  return newJobs
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if not career_career.isActive() then
    return
  end

  local deltaSim = math.max(dtSim or 0, 0)
  if deltaSim <= 0 then
    return
  end

  jobsAccumulator = jobsAccumulator + deltaSim
  techsAccumulator = techsAccumulator + deltaSim
  managerAccumulator = managerAccumulator + deltaSim
  costsAccumulator = costsAccumulator + deltaSim

  local shouldProcessJobs = jobsAccumulator >= UPDATE_INTERVAL_JOBS
  local shouldProcessTechs = techsAccumulator >= UPDATE_INTERVAL_TECHS
  local shouldProcessManager = managerAccumulator >= UPDATE_INTERVAL_MANAGER
  local shouldProcessCosts = costsAccumulator >= UPDATE_INTERVAL_COSTS

  if not (shouldProcessJobs or shouldProcessTechs or shouldProcessManager or shouldProcessCosts) then
    return
  end

  if not career_modules_business_businessManager or not career_modules_business_businessManager.getPurchasedBusinesses then
    return
  end

  local purchased = career_modules_business_businessManager.getPurchasedBusinesses("tuningShop") or {}
  local ownedBusinesses = {}

  local jobsTime = shouldProcessJobs and jobsAccumulator or 0
  local techsTime = shouldProcessTechs and techsAccumulator or 0
  local managerTime = shouldProcessManager and managerAccumulator or 0
  local costsTime = shouldProcessCosts and costsAccumulator or 0

  if shouldProcessJobs then
    jobsAccumulator = 0
  end
  if shouldProcessTechs then
    techsAccumulator = 0
  end
  if shouldProcessManager then
    managerAccumulator = 0
  end
  if shouldProcessCosts then
    costsAccumulator = 0
  end

  for businessId, owned in pairs(purchased) do
    if owned then
      local id = normalizeBusinessId(businessId)
      ownedBusinesses[id] = true

      local jobsChanged = false

      if shouldProcessJobs then
        local jobs = loadBusinessJobs(id)
        jobs.new = jobs.new or {}
        if processJobGeneration(id, jobs, jobsTime) then
          jobsChanged = true
        end
        if updateNewJobExpirations(id, jobs, jobsTime) then
          jobsChanged = true
        end
      end

      if shouldProcessTechs then
        tuningShopTechs.processTechs(id, techsTime)
      end

      if shouldProcessManager then
        if processManagerTimers(id, managerTime) then
          jobsChanged = true
        end
        if processManagerAssignments(id) then
          jobsChanged = true
        end
      end

      if shouldProcessCosts then
        processOperatingCosts(id, costsTime)
      end

      if jobsChanged then
        notifyJobsUpdated(id)
      end
    end
  end

  if shouldProcessJobs then
    for id in pairs(generationTimers) do
      if not ownedBusinesses[id] then
        generationTimers[id] = nil
      end
    end
  end

  if shouldProcessManager then
    for id in pairs(managerTimers) do
      if not ownedBusinesses[id] then
        managerTimers[id] = nil
      end
    end
  end

  if shouldProcessCosts then
    for id in pairs(operatingCostTimers) do
      if not ownedBusinesses[id] then
        operatingCostTimers[id] = nil
      end
    end
  end
end

local function openMenu(businessId)
  ensureTabsRegistered()
  guihooks.trigger('ChangeState', {
    state = 'business-computer',
    params = {
      businessType = 'tuningShop',
      businessId = tostring(businessId)
    }
  })
end

local function requestAvailableBrands()
  local brands = getAvailableBrands()
  if guihooks then
    guihooks.trigger('businessComputer:onAvailableBrandsReceived', {
      brands = brands
    })
  end
end

local function requestAvailableRaceTypes()
  local raceTypes = getAvailableRaceTypes()
  if guihooks then
    guihooks.trigger('businessComputer:onAvailableRaceTypesReceived', {
      raceTypes = raceTypes
    })
  end
end

local function onCareerActivated()
  career_modules_business_businessManager.registerBusinessCallback("tuningShop", {
    onPurchase = function(businessId)
      log("I", "TuningShop", "Tuning shop purchased: " .. tostring(businessId))

      ensureTabsRegistered()

      if career_modules_bank then
        local accountId = "business_tuningShop_" .. tostring(businessId)
        career_modules_bank.rewardToAccount({
          money = {
            amount = 25000
          }
        }, accountId, "Business Purchase Reward", "Initial operating capital")
      end

      local normalizedId = normalizeBusinessId(businessId)

      loadRaceData()
      getFactoryConfigs()

      if not businessJobs[normalizedId] then
        businessJobs[normalizedId] = {
          active = {},
          new = {},
          completed = {}
        }
      end

      local jobs = businessJobs[normalizedId]
      if not jobs.new then
        jobs.new = {}
      end

      local newJobs = generateNewJobs(normalizedId, 3)
      log("I", "TuningShop", "Generated " .. tostring(#newJobs) .. " initial jobs for business " .. tostring(normalizedId))

      for _, job in ipairs(newJobs) do
        table.insert(jobs.new, job)
      end

      local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
      if currentSavePath then
        saveBusinessJobs(normalizedId, currentSavePath)
        tuningShopTechs.saveBusinessTechs(normalizedId, currentSavePath)
      end

      tuningShopTechs.loadBusinessTechs(normalizedId)
      loadManagerTimer(normalizedId)
      loadOperatingCostTimer(normalizedId)

      notifyJobsUpdated(normalizedId)
    end,
    onMenuOpen = function(businessId)
      openMenu(businessId)
    end
  })

  ensureTabsRegistered()

  businessJobs = {}
  businessXP = {}
  generationTimers = {}
  businessSelections = {}

  tuningShopTechs.initialize({
    normalizeBusinessId = normalizeBusinessId,
    getSkillTreeLevel = getSkillTreeLevel,
    getJobById = getJobById,
    getCommuteSeconds = getCommuteSeconds,
    getEventReward = getEventReward,
    getBuildTimeSeconds = getBuildTimeSeconds,
    calculateBuildCost = calculateBuildCost,
    getEventRetryAllowance = getEventRetryAllowance,
    hasPerfectTechs = hasPerfectTechs,
    hasMasterTechs = hasMasterTechs,
    getReliableFailureReduction = getReliableFailureReduction,
    creditBusinessAccount = creditBusinessAccount,
    debitBusinessAccount = debitBusinessAccount,
    removeJobVehicle = removeJobVehicle,
    clearJobLeaderboardEntry = clearJobLeaderboardEntry,
    moveJobToCompleted = moveJobToCompleted,
    getXPGainMultiplier = getXPGainMultiplier,
    addBusinessXP = addBusinessXP,
    getAbandonPenalty = getAbandonPenalty,
    calculateActualEventPayment = calculateActualEventPayment,
    loadBusinessJobs = loadBusinessJobs,
    notifyJobsUpdated = notifyJobsUpdated,
    getMaxPulledOutVehicles = getMaxPulledOutVehicles,
    clearBusinessCachesForJob = function(businessId, jobId)
      if career_modules_business_businessComputer and career_modules_business_businessComputer.clearBusinessCachesForJob then
        career_modules_business_businessComputer.clearBusinessCachesForJob(businessId, jobId)
      end
    end
  })

  tuningShopTechs.resetTechs()
end

local function onSaveCurrentSaveSlot(currentSavePath)
  for businessId, _ in pairs(businessJobs) do
    saveBusinessJobs(businessId, currentSavePath)
  end
  for businessId, _ in pairs(businessXP) do
    saveBusinessXP(businessId, currentSavePath)
  end
  for businessId, _ in pairs(businessJobs) do
    tuningShopTechs.saveBusinessTechs(businessId, currentSavePath)
  end
  for businessId, _ in pairs(managerTimers) do
    saveManagerTimer(businessId, currentSavePath)
  end
  for businessId, _ in pairs(operatingCostTimers) do
    saveOperatingCostTimer(businessId, currentSavePath)
  end
  for businessId, _ in pairs(businessSelections) do
    saveBusinessSelections(businessId, currentSavePath)
  end
  local kitsModule = getTuningShopKits()
  if kitsModule and kitsModule.onSaveCurrentSaveSlot then
    kitsModule.onSaveCurrentSaveSlot(currentSavePath)
  end
end

local function isShopAppUnlocked(businessId)
  if not businessId or not career_modules_business_businessSkillTree then
    return false
  end

  local level = career_modules_business_businessSkillTree.getNodeProgress(businessId, "quality-of-life", "shop-app")
  return level and level > 0
end

local function getTechData(businessId)
  if not businessId then
    return nil
  end
  
  local techs = tuningShopTechs.getTechsForBusiness(businessId)
  local formattedTechs = {}
  for _, tech in ipairs(techs) do
    local formatted = tuningShopTechs.formatTechForUIEntry(businessId, tech)
    if formatted then
      table.insert(formattedTechs, formatted)
    end
  end
  
  return {
    businessId = tostring(businessId),
    techs = formattedTechs
  }
end

local function getManagerData(businessId)
  if not businessId or not hasManager(businessId) then
    return nil
  end
  
  local timerState = getManagerTimerState(businessId)
  local interval = getManagerAssignmentInterval(businessId)
  
  return {
    businessId = tostring(businessId),
    elapsed = timerState.elapsed,
    interval = interval,
    available = timerState.flagActive or (timerState.elapsed >= interval),
    nextAvailableIn = math.max(0, interval - timerState.elapsed),
    hasGeneralManager = hasGeneralManager(businessId)
  }
end

local function selectPersonalVehicle(businessId, inventoryId)
  if not businessId or not inventoryId then
    return { success = false, errorCode = "missingParams" }
  end
  if not isPersonalUseUnlocked(businessId) then
    return { success = false, errorCode = "personalUseNotUnlocked", message = "Personal Use upgrade is not unlocked" }
  end
  local inventoryVehiclesInZone = getInventoryVehiclesInGarageZone(businessId)
  local found = nil
  for _, invVeh in ipairs(inventoryVehiclesInZone) do
    if invVeh.inventoryId == inventoryId then
      found = invVeh
      break
    end
  end
  if not found then
    return { success = false, errorCode = "vehicleNotInZone", message = "Vehicle is not in the garage zone" }
  end
  local personalEntry = createPersonalVehicleEntry(businessId, found.inventoryId, found.inventoryVehicleData, found.spawnedId)
  if not personalEntry then
    return { success = false, errorCode = "failedToCreate", message = "Failed to create personal vehicle entry" }
  end
  activePersonalVehicle[businessId] = personalEntry
  if guihooks then
    local formatted = formatVehicleForUI(personalEntry, businessId)
    if formatted then
      formatted.damage = 0
      formatted.damageLocked = false
      formatted.damageThreshold = DAMAGE_LOCK_THRESHOLD
      formatted.inGarageZone = true
      formatted.isPersonal = true
      formatted.inventoryId = inventoryId
      formatted.spawnedVehicleId = personalEntry.spawnedVehicleId
      formatted.isActive = true
    end
    guihooks.trigger('businessComputer:onPersonalVehicleSelected', {
      businessType = "tuningShop",
      businessId = tostring(businessId),
      vehicle = formatted
    })
  end
  return { success = true, vehicle = personalEntry }
end

local function getActivePersonalVehicle(businessId)
  return activePersonalVehicle[businessId]
end

local function clearActivePersonalVehicle(businessId)
  activePersonalVehicle[businessId] = nil
end

M.onCareerActivated = onCareerActivated
M.onUpdate = onUpdate
M.powerToWeightToTime = powerToWeightToTime
M.generateJob = generateJob
M.loadRaceData = loadRaceData
M.openMenu = openMenu
M.getUIData = getUIData
M.getJobsForBusiness = getJobsForBusiness
M.getActiveJobs = getActiveJobs
M.getNewJobs = getNewJobs
M.acceptJob = acceptJob
M.declineJob = declineJob
M.abandonJob = abandonJob
M.completeJob = completeJob
M.canCompleteJob = canCompleteJob
M.getAbandonPenalty = getAbandonPenalty
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot
M.isShopAppUnlocked = isShopAppUnlocked
M.getBusinessXP = getBusinessXP
M.addBusinessXP = addBusinessXP
M.spendBusinessXP = spendBusinessXP
M.getMaxPulledOutVehicles = getMaxPulledOutVehicles
M.getTechsForBusiness = tuningShopTechs.getTechsForBusiness
M.updateTechName = tuningShopTechs.updateTechName
M.assignJobToTech = tuningShopTechs.assignJobToTech
M.isJobLockedByTech = tuningShopTechs.isJobLockedByTech
M.getTechData = getTechData
M.getManagerData = getManagerData
M.getBrandSelection = getBrandSelection
M.setBrandSelection = setBrandSelection
M.getRaceSelection = getRaceSelection
M.setRaceSelection = setRaceSelection
M.getAvailableBrands = getAvailableBrands
M.getAvailableRaceTypes = getAvailableRaceTypes
M.requestAvailableBrands = requestAvailableBrands
M.requestAvailableRaceTypes = requestAvailableRaceTypes
M.getOperatingCosts = getOperatingCosts
M.getFinancesData = getFinancesData
M.requestFinancesData = requestFinancesData
M.requestSimulationTime = requestSimulationTime
M.getJobById = getJobById
M.getVehicleByJobId = getVehicleByJobId

M.getTechsForBusiness = function(businessId)
  return tuningShopTechs.loadBusinessTechs(businessId)
end

M.isPlayerInTuningShopZone = isPlayerInTuningShopZone
M.isSpawnedVehicleInGarageZone = isSpawnedVehicleInGarageZone
M.isPositionInGarageZone = isPositionInGarageZone
M.isPersonalUseUnlocked = isPersonalUseUnlocked
M.getInventoryVehiclesInGarageZone = getInventoryVehiclesInGarageZone
M.selectPersonalVehicle = selectPersonalVehicle
M.getActivePersonalVehicle = getActivePersonalVehicle
M.clearActivePersonalVehicle = clearActivePersonalVehicle

return M
