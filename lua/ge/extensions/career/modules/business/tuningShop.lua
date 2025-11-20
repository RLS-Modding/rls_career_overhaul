local M = {}

M.dependencies = {
  'util_configListGenerator',
  'career_career',
  'career_saveSystem',
  'freeroam_facilities'
}

local raceData = nil
local raceDataLevel = nil
local factoryConfigs = nil
local businessJobs = {}
local generationTimers = {}
local jobIdCounter = 0

local GEN_INTERVAL_SECONDS = 120
local EXPIRY_SECONDS = 300

local DAMAGE_LOCK_THRESHOLD = 1750

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

local function getJobExpirySeconds(businessId)
  return EXPIRY_SECONDS
end

local function ensureJobLifetime(job, businessId)
  if not job then return end
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

-- Job Management Logic

local function getBusinessJobsPath(businessId)
  if not career_career.isActive() then return nil end
  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  if not currentSavePath then return nil end
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
  if not businessId then return {} end
  
  if businessJobs[businessId] then
    return businessJobs[businessId]
  end
  
  local filePath = getBusinessJobsPath(businessId)
  if not filePath then return {} end
  
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
  end
  for _, job in ipairs(businessJobs[businessId].new or {}) do
    if job.jobId then
      job.jobId = tonumber(job.jobId) or job.jobId
    end
    ensureJobLifetime(job, businessId)
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

local function saveBusinessJobs(businessId, currentSavePath)
  businessId = normalizeBusinessId(businessId)
  if not businessId or not businessJobs[businessId] then return end
  if not currentSavePath then return end
  
  local filePath = currentSavePath .. "/career/rls_career/businesses/" .. businessId .. "/jobs.json"
  
  local dirPath = string.match(filePath, "^(.*)/[^/]+$")
  if dirPath and not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end
  
  jsonWriteFile(filePath, businessJobs[businessId], true)
end

local function loadRaceData()
  local currentLevel = getCurrentLevelIdentifier()
  if not currentLevel then return {} end
  
  if raceData and raceDataLevel == currentLevel then return raceData end
  
  local raceDataPath = "levels/" .. currentLevel .. "/race_data.json"
  raceData = jsonReadFile(raceDataPath) or {}
  raceDataLevel = currentLevel
  return raceData
end

local function getFactoryConfigs()
  if factoryConfigs then return factoryConfigs end
  
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

local function getSkillTreeUpgradeCount(businessId)
  if not businessId or not career_modules_business_businessSkillTree then
    return 0
  end
  
  local treeId = "quality-of-life"
  local upgradeCount = 0
  
  local moreComplicatedLevel = career_modules_business_businessSkillTree.getNodeProgress(businessId, treeId, "more-complicated")
  if moreComplicatedLevel > 0 then
    upgradeCount = upgradeCount + 1
  end
  
  local moreComplicatedIILevel = career_modules_business_businessSkillTree.getNodeProgress(businessId, treeId, "more-complicated-ii")
  if moreComplicatedIILevel > 0 then
    upgradeCount = upgradeCount + 1
  end
  
  return upgradeCount
end

local function getMaxActiveJobs(businessId)
  local baseLimit = 2
  if not businessId or not career_modules_business_businessSkillTree then
    return baseLimit
  end
  
  local treeId = "shop-upgrades"
  local biggerBooksLevel = career_modules_business_businessSkillTree.getNodeProgress(businessId, treeId, "bigger-books") or 0
  
  return baseLimit + biggerBooksLevel
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
  if not races or not races.races then return nil end
  
  local race = nil
  if raceId == "trackAlt" then
    race = races.races.track and races.races.track.altRoute
  else
    race = races.races[raceId]
  end
  
  if not race or not race.predictCoef then return nil end
  
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
  if not configs or #configs == 0 then return nil end
  
  local selectedConfig = configs[math.random(#configs)]
  
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
  
  if power == 0 or weight == 0 then return nil end
  
  local powerToWeight = power / weight
  
  local races = loadRaceData()
  if not races or not races.races then return nil end
  
  local raceTypes = {"track", "trackAlt", "drag"}
  local raceType = raceTypes[math.random(#raceTypes)]
  
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
  if not baseTime then return nil end
  
  local tuningShopConfig = race and race.tuningShop or {}
  local levels = tuningShopConfig.levels or {}
  local decimalPlaces = tuningShopConfig.decimalPlaces or 0
  
  if not levels or #levels == 0 then return nil end
  
  local upgradeCount = getSkillTreeUpgradeCount(businessId)
  local maxAvailableLevel = math.min(#levels, upgradeCount + 1)
  local selectedLevelIndex = selectJobLevel(upgradeCount, maxAvailableLevel)
  
  selectedLevelIndex = math.min(selectedLevelIndex, #levels)
  selectedLevelIndex = math.max(1, selectedLevelIndex)
  
  local levelData = levels[selectedLevelIndex]
  if not levelData then return nil end
  
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
    decimalPlaces = decimalPlaces
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
  if interval <= 0 then return false end

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
  if not businessId or not jobId then return false end
  
  jobId = tonumber(jobId) or jobId
  local jobs = loadBusinessJobs(businessId)
  
  local maxActiveJobs = getMaxActiveJobs(businessId)
  local currentActiveCount = #(jobs.active or {})
  
  if currentActiveCount >= maxActiveJobs then
    log("W", "tuningShop", "Cannot accept job: active job limit reached. Current: " .. tostring(currentActiveCount) .. ", Max: " .. tostring(maxActiveJobs))
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
  
  if not jobIndex then return false end
  
  local job = table.remove(jobs.new, jobIndex)
  job.status = "active"
  job.acceptedTime = os.time()
  
  if not jobs.active then jobs.active = {} end
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

local function declineJob(businessId, jobId)
  if not businessId or not jobId then return false end
  
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

local function getJobById(businessId, jobId)
  if not businessId or not jobId then return nil end
  
  jobId = tonumber(jobId) or jobId
  local jobs = loadBusinessJobs(businessId)
  
  for _, job in ipairs(jobs.active or {}) do
    local jId = tonumber(job.jobId) or job.jobId
    if jId == jobId then return job end
  end
  
  for _, job in ipairs(jobs.new or {}) do
    local jId = tonumber(job.jobId) or job.jobId
    if jId == jobId then return job end
  end
  
  for _, job in ipairs(jobs.completed or {}) do
    local jId = tonumber(job.jobId) or job.jobId
    if jId == jobId then return job end
  end
  
  return nil
end

local function getJobCurrentTime(businessId, jobId)
  local job = getJobById(businessId, jobId)
  if not job or not job.raceLabel then
    return nil
  end
  
  local bestTime = career_modules_business_businessHelpers.getBestLeaderboardTime(businessId, jobId, job.raceType, job.raceLabel)
  
  if bestTime then
    return bestTime
  end
  
  return job.currentTime or job.baseTime
end

local function canCompleteJob(businessId, jobId)
  if not businessId or not jobId then return false end
  
  jobId = tonumber(jobId) or jobId
  local job = getJobById(businessId, jobId)
  if not job then 
    log("D", "tuningShop", "canCompleteJob: Job not found. businessId=" .. tostring(businessId) .. ", jobId=" .. tostring(jobId))
    return false 
  end
  
  if job.status ~= "active" then 
    log("D", "tuningShop", "canCompleteJob: Job not active. businessId=" .. tostring(businessId) .. ", jobId=" .. tostring(jobId) .. ", status=" .. tostring(job.status))
    return false 
  end
  
  if not job.raceType or not job.targetTime then 
    log("D", "tuningShop", "canCompleteJob: Job missing raceType or targetTime. businessId=" .. tostring(businessId) .. ", jobId=" .. tostring(jobId))
    return false 
  end
  
  local currentTime = getJobCurrentTime(businessId, jobId)
  if not currentTime then 
    log("D", "tuningShop", "canCompleteJob: Could not get current time. businessId=" .. tostring(businessId) .. ", jobId=" .. tostring(jobId))
    return false 
  end
  
  local targetTime = job.targetTime
  if (job.raceType == "track" or job.raceType == "trackAlt") and targetTime > 1000 then
    targetTime = targetTime * 60
  end
  
  if job.raceType == "drag" or job.raceType == "track" or job.raceType == "trackAlt" then
    local canComplete = currentTime <= targetTime
    if not canComplete then
      log("D", "tuningShop", "canCompleteJob: Time not met. businessId=" .. tostring(businessId) .. ", jobId=" .. tostring(jobId) .. ", currentTime=" .. tostring(currentTime) .. ", targetTime=" .. tostring(targetTime))
    end
    return canComplete
  end
  
  return false
end

local function completeJob(businessId, jobId)
  if not businessId or not jobId then 
    log("E", "tuningShop", "completeJob: Missing parameters. businessId=" .. tostring(businessId) .. ", jobId=" .. tostring(jobId))
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
    log("E", "tuningShop", "completeJob: Job not found in active jobs. businessId=" .. tostring(businessId) .. ", jobId=" .. tostring(jobId))
    return false 
  end
  
  local job = jobs.active[jobIndex]
  
  if not canCompleteJob(businessId, jobId) then
    log("E", "tuningShop", "completeJob: Job cannot be completed. businessId=" .. tostring(businessId) .. ", jobId=" .. tostring(jobId))
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
        log("E", "tuningShop", "completeJob: Failed to reward account. businessId=" .. tostring(businessId) .. ", jobId=" .. tostring(jobId) .. ", accountId=" .. tostring(accountId) .. ", reward=" .. tostring(reward))
        return false
      end
    else
      log("E", "tuningShop", "completeJob: Business account not found. businessId=" .. tostring(businessId) .. ", jobId=" .. tostring(jobId))
      return false
    end
  else
    log("E", "tuningShop", "completeJob: career_modules_bank not available. businessId=" .. tostring(businessId) .. ", jobId=" .. tostring(jobId))
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
    local pulledOutVehicle = career_modules_business_businessInventory.getPulledOutVehicle(businessId)
    if pulledOutVehicle then
      local pulledId = tonumber(pulledOutVehicle.vehicleId) or pulledOutVehicle.vehicleId
      local removeId = tonumber(vehicleToRemove.vehicleId) or vehicleToRemove.vehicleId
      if pulledId == removeId then
        career_modules_business_businessInventory.putAwayVehicle(businessId)
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
  
  if not jobs.completed then jobs.completed = {} end
  table.insert(jobs.completed, job)
  
  career_saveSystem.saveCurrent()
  
  log("D", "tuningShop", "completeJob: Successfully completed job. businessId=" .. tostring(businessId) .. ", jobId=" .. tostring(jobId))
  return true
end

local function getAbandonPenalty(businessId, jobId)
  if not businessId or not jobId then return 0 end
  
  local job = getJobById(businessId, jobId)
  if not job then return 0 end
  
  local reward = job.reward or 20000
  local penalty = math.floor(reward * 0.5)
  
  return penalty
end

local function abandonJob(businessId, jobId)
  if not businessId or not jobId then return false end
  
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
  
  if not jobIndex or not job then return false end
  
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
    local pulledOutVehicle = career_modules_business_businessInventory.getPulledOutVehicle(businessId)
    if pulledOutVehicle then
      local pulledId = tonumber(pulledOutVehicle.vehicleId) or pulledOutVehicle.vehicleId
      local removeId = tonumber(vehicleToRemove.vehicleId) or vehicleToRemove.vehicleId
      if pulledId == removeId then
        career_modules_business_businessInventory.putAwayVehicle(businessId)
      end
    end
    career_modules_business_businessInventory.removeVehicle(businessId, vehicleToRemove.vehicleId)
  end
  
  local leaderboardManager = require('gameplay/events/freeroam/leaderboardManager')
  local businessJobId = career_modules_business_businessInventory.getBusinessJobIdentifier(businessId, jobId)
  leaderboardManager.clearLeaderboardForVehicle(businessJobId)
  
  local penalty = getAbandonPenalty(businessId, jobId)

  if career_modules_bank then
    local businessName = job.businessName or ("tuningShop " .. tostring(businessId))
    local businessAccount = career_modules_bank.getBusinessAccount("tuningShop", businessId)
    if not businessAccount then
      career_modules_bank.createBusinessAccount("tuningShop", businessId, businessName)
      businessAccount = career_modules_bank.getBusinessAccount("tuningShop", businessId)
    end
    
    if businessAccount then
      local success = career_modules_bank.removeFunds(businessAccount.id, penalty, "Job Penalty", "Abandoned Job #" .. tostring(jobId), "penalty", true)
      if not success then
        return false
      end
    else
      return false
    end
  else
    return false
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
    local bestTime = career_modules_business_businessHelpers.getBestLeaderboardTime(businessId, job.jobId, job.raceType, job.raceLabel)
    if bestTime then
      currentTime = bestTime
    end
  end

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
    baselineTime = tonumber(string.format("%.1f", baselineTime)),
    currentTime = tonumber(string.format("%.1f", currentTime)),
    goalTime = tonumber(string.format("%.1f", goalTime)),
    timeUnit = timeUnit,
    raceType = job.raceType,
    raceLabel = job.raceLabel,
    decimalPlaces = job.decimalPlaces or 0,
    expiresInSeconds = expiresInSeconds,
    penalty = penalty
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

  return {
    id = tostring(vehicle.vehicleId),
    vehicleId = vehicle.vehicleId,
    vehicleName = vehicleName,
    vehicleYear = vehicleYear,
    vehicleType = vehicleType,
    vehicleImage = vehicleImage,
    jobId = vehicle.jobId,
    storedTime = vehicle.storedTime
  }
end

local function getBusinessVehicleObject(businessId, vehicleId)
  if not businessId or not vehicleId then return nil end
  
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

local function getUIData(businessId)
  if not businessId then
    return nil
  end

  local businessType = "tuningShop"
  local business = freeroam_facilities.getFacility(businessType, businessId)
  if not business then
    return nil
  end

  local jobs = getJobsForBusiness(businessId)
  local vehicles = career_modules_business_businessInventory.getBusinessVehicles(businessId)
  local parts = {}
  local pulledOutVehicle = career_modules_business_businessInventory.getPulledOutVehicle(businessId)
  local pulledOutDamageInfo = {
    locked = false,
    damage = 0,
    threshold = DAMAGE_LOCK_THRESHOLD
  }

  local activeJobs = {}
  for _, job in ipairs(jobs.active or {}) do
    table.insert(activeJobs, formatJobForUI(job, businessId))
  end

  local newJobs = {}
  for _, job in ipairs(jobs.new or {}) do
    table.insert(newJobs, formatJobForUI(job, businessId))
  end

  local vehicleList = {}
  for _, vehicle in ipairs(vehicles) do
    table.insert(vehicleList, formatVehicleForUI(vehicle, businessId))
  end

  local pulledOutVehicleData = nil
  if pulledOutVehicle then
    pulledOutVehicleData = formatVehicleForUI(pulledOutVehicle, businessId)
    pulledOutDamageInfo = isDamageLocked(businessId, pulledOutVehicle.vehicleId)
    if pulledOutVehicleData then
      pulledOutVehicleData.damage = pulledOutDamageInfo.damage
      pulledOutVehicleData.damageLocked = pulledOutDamageInfo.locked
      pulledOutVehicleData.damageThreshold = pulledOutDamageInfo.threshold
    end
  end

  local totalPartsValue = 0
  for _, part in ipairs(parts) do
    totalPartsValue = totalPartsValue + (part.price or part.value or 0)
  end

  local tabs = {}
  if career_modules_business_businessTabRegistry then
    if career_modules_business_businessSkillTree and career_modules_business_businessSkillTree.ensureTabsRegistered then
      pcall(function()
        career_modules_business_businessSkillTree.ensureTabsRegistered(businessType)
      end)
    end
    tabs = career_modules_business_businessTabRegistry.getTabs(businessType) or {}

    if pulledOutDamageInfo.locked then
      local allowedTabs = {
        home = true,
        jobs = true
      }

      local filteredTabs = {}
      for _, tab in ipairs(tabs) do
        if tab.id and allowedTabs[tab.id] then
          table.insert(filteredTabs, tab)
        end
      end
      tabs = filteredTabs
    end
  else
    log('W', 'tuningShop', 'Tab registry not available')
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
    tabs = tabs,
    vehicleDamage = pulledOutDamageInfo.damage,
    vehicleDamageLocked = pulledOutDamageInfo.locked,
    vehicleDamageThreshold = pulledOutDamageInfo.threshold,
    maxActiveJobs = getMaxActiveJobs(businessId),
    stats = {
      totalVehicles = #vehicleList,
      totalParts = #parts,
      totalPartsValue = totalPartsValue,
      activeJobsCount = #activeJobs,
      newJobsCount = #newJobs
    }
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

  if not career_modules_business_businessManager or not career_modules_business_businessManager.getPurchasedBusinesses then
    return
  end

  local purchased = career_modules_business_businessManager.getPurchasedBusinesses("tuningShop") or {}
  local ownedBusinesses = {}
  local deltaSim = math.max(dtSim or 0, 0)

  for businessId, owned in pairs(purchased) do
    if owned then
      local id = normalizeBusinessId(businessId)
      ownedBusinesses[id] = true
      local jobs = loadBusinessJobs(id)
      jobs.new = jobs.new or {}

      local jobsChanged = false
      if deltaSim > 0 then
        if processJobGeneration(id, jobs, deltaSim) then
          jobsChanged = true
        end
        if updateNewJobExpirations(id, jobs, deltaSim) then
          jobsChanged = true
        end
      end

      if jobsChanged then
        notifyJobsUpdated(id)
      end
    end
  end

  for id in pairs(generationTimers) do
    if not ownedBusinesses[id] then
      generationTimers[id] = nil
    end
  end
end

local function openMenu(businessId)
  log("D", "TuningShop", "Opening menu for business: " .. tostring(businessId))
  guihooks.trigger('ChangeState', {state = 'business-computer', params = {businessType = 'tuningShop', businessId = tostring(businessId)}})
end

local function onCareerActivated()
  career_modules_business_businessManager.registerBusinessCallback("tuningShop", {
    onPurchase = function(businessId)
      log("D", "TuningShop", "Tuning shop purchased: " .. tostring(businessId))
      if career_modules_bank then
        local accountId = "business_tuningShop_" .. tostring(businessId)
        career_modules_bank.rewardToAccount({money = {amount = 25000}}, accountId, "Business Purchase Reward", "Initial operating capital")
      end
      
      local normalizedId = normalizeBusinessId(businessId)
      local jobs = loadBusinessJobs(normalizedId)
      if not jobs.new then
        jobs.new = {}
      end
      
      local newJobs = generateNewJobs(normalizedId, 3)
      for _, job in ipairs(newJobs) do
        table.insert(jobs.new, job)
      end
      
      local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
      if currentSavePath then
        saveBusinessJobs(normalizedId, currentSavePath)
      end
      
      notifyJobsUpdated(normalizedId)
    end,
    onMenuOpen = function(businessId)
      openMenu(businessId)
    end
  })
  
  -- No longer registering job generator
  
  if career_modules_business_businessTabRegistry then
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
      id = "inventory",
      label = "Inventory",
      icon = '<path d="M16.5 9.4l-9-5.19M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z"/><polyline points="3.27 6.96 12 12.01 20.73 6.96"/><line x1="12" y1="22.08" x2="12" y2="12"/>',
      component = "BusinessInventoryTab",
      section = "BASIC",
      order = 3
    })
  end
  
  businessJobs = {}
  generationTimers = {}
end

local function onSaveCurrentSaveSlot(currentSavePath)
  for businessId, _ in pairs(businessJobs) do
    saveBusinessJobs(businessId, currentSavePath)
  end
end

local function isShopAppUnlocked(businessId)
  if not businessId or not career_modules_business_businessSkillTree then
    return false
  end
  
  local level = career_modules_business_businessSkillTree.getNodeProgress(businessId, "quality-of-life", "shop-app")
  return level and level > 0
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

return M
