local M = {}

M.dependencies = {'career_career', 'career_saveSystem', 'career_modules_business_businessInventory', 'career_modules_payment', 'career_modules_bank', 'career_modules_business_businessHelpers'}

local jobGenerators = {}
local businessJobs = {}
local currentBusinessId = nil

local function getBusinessJobsPath(businessId)
  if not career_career.isActive() then return nil end
  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  if not currentSavePath then return nil end
  return currentSavePath .. "/career/rls_career/businesses/" .. businessId .. "/jobs.json"
end

local function loadBusinessJobs(businessId)
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
  end
  for _, job in ipairs(businessJobs[businessId].completed or {}) do
    if job.jobId then
      job.jobId = tonumber(job.jobId) or job.jobId
    end
  end
  
  return businessJobs[businessId]
end

local function saveBusinessJobs(businessId, currentSavePath)
  if not businessId or not businessJobs[businessId] then return end
  if not currentSavePath then return end
  
  local filePath = currentSavePath .. "/career/rls_career/businesses/" .. businessId .. "/jobs.json"
  
  local dirPath = string.match(filePath, "^(.*)/[^/]+$")
  if dirPath and not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end
  
  jsonWriteFile(filePath, businessJobs[businessId], true)
end

local function registerJobGenerator(businessType, generatorFunction)
  jobGenerators[businessType] = generatorFunction
end

local function generateNewJobs(businessId, businessType, count)
  count = count or 5
  local generator = jobGenerators[businessType]
  if not generator then return {} end
  
  local jobs = loadBusinessJobs(businessId)
  local newJobs = {}
  
  for i = 1, count do
    local job = generator(businessId)
    if job then
      job.businessId = businessId
      job.businessType = businessType
      job.status = "new"
      table.insert(newJobs, job)
    end
  end
  
  return newJobs
end

local function getJobsForBusiness(businessId, businessType)
  local jobs = loadBusinessJobs(businessId)
  
  if not jobs.new or #jobs.new == 0 then
    local newJobs = generateNewJobs(businessId, businessType, 5)
    jobs.new = newJobs
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
    log("D", "businessJobManager", "canCompleteJob: Job not found. businessId=" .. tostring(businessId) .. ", jobId=" .. tostring(jobId))
    return false 
  end
  
  if job.status ~= "active" then 
    log("D", "businessJobManager", "canCompleteJob: Job not active. businessId=" .. tostring(businessId) .. ", jobId=" .. tostring(jobId) .. ", status=" .. tostring(job.status))
    return false 
  end
  
  if not job.raceType or not job.targetTime then 
    log("D", "businessJobManager", "canCompleteJob: Job missing raceType or targetTime. businessId=" .. tostring(businessId) .. ", jobId=" .. tostring(jobId))
    return false 
  end
  
  local currentTime = getJobCurrentTime(businessId, jobId)
  if not currentTime then 
    log("D", "businessJobManager", "canCompleteJob: Could not get current time. businessId=" .. tostring(businessId) .. ", jobId=" .. tostring(jobId))
    return false 
  end
  
  local targetTime = job.targetTime
  if (job.raceType == "track" or job.raceType == "trackAlt") and targetTime > 1000 then
    targetTime = targetTime * 60
  end
  
  if job.raceType == "drag" or job.raceType == "track" or job.raceType == "trackAlt" then
    local canComplete = currentTime <= targetTime
    if not canComplete then
      log("D", "businessJobManager", "canCompleteJob: Time not met. businessId=" .. tostring(businessId) .. ", jobId=" .. tostring(jobId) .. ", currentTime=" .. tostring(currentTime) .. ", targetTime=" .. tostring(targetTime))
    end
    return canComplete
  end
  
  return false
end

local function completeJob(businessId, jobId)
  if not businessId or not jobId then 
    log("E", "businessJobManager", "completeJob: Missing parameters. businessId=" .. tostring(businessId) .. ", jobId=" .. tostring(jobId))
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
    log("E", "businessJobManager", "completeJob: Job not found in active jobs. businessId=" .. tostring(businessId) .. ", jobId=" .. tostring(jobId))
    local activeJobs = jobs.active or {}
    log("D", "businessJobManager", "completeJob: Available active jobs: " .. tostring(#activeJobs))
    for i, job in ipairs(activeJobs) do
      log("D", "businessJobManager", "completeJob: Active job[" .. tostring(i) .. "] jobId=" .. tostring(job.jobId) .. " (type: " .. type(job.jobId) .. ")")
    end
    return false 
  end
  
  local job = jobs.active[jobIndex]
  
  if not canCompleteJob(businessId, jobId) then
    log("E", "businessJobManager", "completeJob: Job cannot be completed. businessId=" .. tostring(businessId) .. ", jobId=" .. tostring(jobId))
    return false
  end
  
  local reward = job.reward or 20000
  if career_modules_bank then
    local businessType = job.businessType or "tuningShop"
    local businessAccount = career_modules_bank.getBusinessAccount(businessType, businessId)
    if businessAccount then
      local accountId = businessAccount.id
      local success = career_modules_bank.rewardToAccount({
        money = {
          amount = reward
        }
      }, accountId)
      if not success then
        log("E", "businessJobManager", "completeJob: Failed to reward account. businessId=" .. tostring(businessId) .. ", jobId=" .. tostring(jobId) .. ", accountId=" .. tostring(accountId) .. ", reward=" .. tostring(reward))
        return false
      end
    else
      log("E", "businessJobManager", "completeJob: Business account not found. businessId=" .. tostring(businessId) .. ", jobId=" .. tostring(jobId) .. ", businessType=" .. tostring(businessType))
      return false
    end
  else
    log("E", "businessJobManager", "completeJob: career_modules_bank not available. businessId=" .. tostring(businessId) .. ", jobId=" .. tostring(jobId))
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
  
  log("D", "businessJobManager", "completeJob: Successfully completed job. businessId=" .. tostring(businessId) .. ", jobId=" .. tostring(jobId))
  return true
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
  
  local reward = job.reward or 20000
  local penalty = math.floor(reward * 0.5)
  
  local price = { money = { amount = penalty, canBeNegative = false } }
  
  local businessAccount = nil
  if career_modules_bank then
    local businessType = job.businessType or "tuningShop"
    businessAccount = career_modules_bank.getBusinessAccount(businessType, businessId)
  end
  
  local accountId = businessAccount and businessAccount.id or nil
  local canPay = career_modules_payment.canPay(price, accountId)
  
  if not canPay then
    return false
  end
  
  local success = career_modules_payment.pay(price, { label = "Abandoned job penalty", tags = {"jobAbandonment", "penalty"} }, accountId)
  if not success then
    return false
  end
  
  table.remove(jobs.active, jobIndex)
  
  return true
end

local function onSaveCurrentSaveSlot(currentSavePath)
  for businessId, _ in pairs(businessJobs) do
    saveBusinessJobs(businessId, currentSavePath)
  end
end

local function onCareerActivated()
  businessJobs = {}
end

M.onCareerActivated = onCareerActivated
M.registerJobGenerator = registerJobGenerator
M.getJobsForBusiness = getJobsForBusiness
M.acceptJob = acceptJob
M.declineJob = declineJob
M.completeJob = completeJob
M.abandonJob = abandonJob
M.getJobById = getJobById
M.canCompleteJob = canCompleteJob
M.getJobCurrentTime = getJobCurrentTime
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot

return M


