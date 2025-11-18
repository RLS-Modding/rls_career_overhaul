local M = {}

M.dependencies = {'util_configListGenerator', 'career_career', 'career_modules_business_businessSkillTree'}

local raceData = nil
local raceDataLevel = nil
local factoryConfigs = nil
local jobs = {}
local jobIdCounter = 0

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
  
  table.insert(jobs, job)
  return job
end

local function getJobs()
  return jobs
end

local function clearJobs()
  jobs = {}
  jobIdCounter = 0
end

local function openMenu(businessId)
  log("D", "TuningShop", "Opening menu for business: " .. tostring(businessId))
  guihooks.trigger('ChangeState', {state = 'business-computer', params = {businessType = 'tuningShop', businessId = tostring(businessId)}})
end

local function generateTuningJob(businessId)
  return generateJob(businessId)
end

local function onCareerActivated()
  career_modules_business_businessManager.registerBusinessCallback("tuningShop", {
    onPurchase = function(businessId)
      log("D", "TuningShop", "Tuning shop purchased: " .. tostring(businessId))
      if career_modules_bank then
        local accountId = "business_tuningShop_" .. tostring(businessId)
        career_modules_bank.rewardToAccount({money = {amount = 25000}}, accountId)
      end
    end,
    onMenuOpen = function(businessId)
      openMenu(businessId)
    end
  })
  
  career_modules_business_businessJobManager.registerJobGenerator("tuningShop", generateTuningJob)
  
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
      id = "active-jobs",
      label = "Active Jobs",
      icon = '<path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/><polyline points="22 4 12 14.01 9 11.01"/>',
      component = "BusinessActiveJobsTab",
      section = "BASIC",
      order = 2
    })

    career_modules_business_businessTabRegistry.registerTab("tuningShop", {
      id = "new-jobs",
      label = "New Jobs",
      icon = '<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/><line x1="16" y1="13" x2="8" y2="13"/><line x1="16" y1="17" x2="8" y2="17"/><polyline points="10 9 9 9 8 9"/>',
      component = "BusinessNewJobsTab",
      section = "BASIC",
      order = 3
    })

    career_modules_business_businessTabRegistry.registerTab("tuningShop", {
      id = "inventory",
      label = "Inventory",
      icon = '<path d="M16.5 9.4l-9-5.19M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z"/><polyline points="3.27 6.96 12 12.01 20.73 6.96"/><line x1="12" y1="22.08" x2="12" y2="12"/>',
      component = "BusinessInventoryTab",
      section = "BASIC",
      order = 4
    })
  end
end

M.onCareerActivated = onCareerActivated
M.powerToWeightToTime = powerToWeightToTime
M.generateJob = generateJob
M.getJobs = getJobs
M.clearJobs = clearJobs
M.getFactoryConfigs = getFactoryConfigs
M.loadRaceData = loadRaceData
M.openMenu = openMenu

return M

