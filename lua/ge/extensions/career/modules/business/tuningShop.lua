local M = {}

M.dependencies = {'util_configListGenerator', 'career_career', 'career_modules_business_businessManager', 'career_modules_business_businessJobManager', 'career_modules_bank'}

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

local function generateJob()
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
  local minImprovement = tuningShopConfig.minImprovement or 1.1
  local maxImprovement = tuningShopConfig.maxImprovement or 1.2
  local decimalPlaces = tuningShopConfig.decimalPlaces or 0
  
  local divisor = minImprovement + math.random() * (maxImprovement - minImprovement)
  local targetTime = baseTime / divisor
  
  local mileageMinMiles = 20000
  local mileageMaxMiles = 120000
  local mileageMiles = math.random(mileageMinMiles, mileageMaxMiles)
  local mileageMeters = mileageMiles * 1609.34
  
  local rewardRaw = 20000 + (divisor - minImprovement) * 10000 / (maxImprovement - minImprovement)
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

local function generateTuningJob()
  return generateJob()
end

-- Register tuning shop callbacks with business manager
function M.onCareerActivated()
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
end

M.powerToWeightToTime = powerToWeightToTime
M.generateJob = generateJob
M.getJobs = getJobs
M.clearJobs = clearJobs
M.getFactoryConfigs = getFactoryConfigs
M.loadRaceData = loadRaceData
M.openMenu = openMenu

return M

