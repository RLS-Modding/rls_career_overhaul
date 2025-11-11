local M = {}

M.dependencies = {'career_career', 'career_saveSystem', 'career_modules_business_businessInventory', 'career_modules_payment', 'career_modules_bank'}

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
  
  return businessJobs[businessId]
end

local function saveBusinessJobs(businessId)
  if not businessId or not businessJobs[businessId] then return end
  
  local filePath = getBusinessJobsPath(businessId)
  if not filePath then return end
  
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
    local job = generator()
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
    saveBusinessJobs(businessId)
  end
  
  return {
    active = jobs.active or {},
    new = jobs.new or {},
    completed = jobs.completed or {}
  }
end

local function acceptJob(businessId, jobId)
  local jobs = loadBusinessJobs(businessId)
  
  local jobIndex = nil
  for i, job in ipairs(jobs.new or {}) do
    if job.jobId == jobId then
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
    local success, vehicleId = career_modules_business_businessInventory.storeVehicle(businessId, vehicleData)
    if success then
      log("D", "businessJobManager", "acceptJob: Stored vehicle for job " .. tostring(jobId) .. " with vehicleId " .. tostring(vehicleId) .. " and mileage " .. tostring(vehicleData.mileage))
    else
      log("W", "businessJobManager", "acceptJob: Failed to store vehicle for job " .. tostring(jobId))
    end
  else
    log("W", "businessJobManager", "acceptJob: Job " .. tostring(jobId) .. " has no vehicleConfig")
  end
  
  saveBusinessJobs(businessId)
  return true
end

local function declineJob(businessId, jobId)
  local jobs = loadBusinessJobs(businessId)
  
  local jobIndex = nil
  for i, job in ipairs(jobs.new or {}) do
    if job.jobId == jobId then
      jobIndex = i
      break
    end
  end
  
  if jobIndex then
    table.remove(jobs.new, jobIndex)
    saveBusinessJobs(businessId)
    return true
  end
  
  return false
end

local function completeJob(businessId, jobId)
  local jobs = loadBusinessJobs(businessId)
  
  local jobIndex = nil
  for i, job in ipairs(jobs.active or {}) do
    if job.jobId == jobId then
      jobIndex = i
      break
    end
  end
  
  if not jobIndex then return false end
  
  local job = table.remove(jobs.active, jobIndex)
  job.status = "completed"
  job.completedTime = os.time()
  
  if not jobs.completed then jobs.completed = {} end
  table.insert(jobs.completed, job)
  
  saveBusinessJobs(businessId)
  return true
end

local function abandonJob(businessId, jobId)
  local jobs = loadBusinessJobs(businessId)
  
  local jobIndex = nil
  local job = nil
  for i, activeJob in ipairs(jobs.active or {}) do
    if activeJob.jobId == jobId then
      jobIndex = i
      job = activeJob
      break
    end
  end
  
  if not jobIndex or not job then return false end
  
  local vehicles = career_modules_business_businessInventory.getBusinessVehicles(businessId)
  local vehicleToRemove = nil
  for _, vehicle in ipairs(vehicles) do
    if vehicle.jobId == jobId then
      vehicleToRemove = vehicle
      break
    end
  end
  
  if vehicleToRemove then
    local pulledOutVehicle = career_modules_business_businessInventory.getPulledOutVehicle(businessId)
    if pulledOutVehicle and pulledOutVehicle.vehicleId == vehicleToRemove.vehicleId then
      career_modules_business_businessInventory.putAwayVehicle(businessId)
    end
    career_modules_business_businessInventory.removeVehicle(businessId, vehicleToRemove.vehicleId)
    log("D", "businessJobManager", "abandonJob: Removed vehicle " .. tostring(vehicleToRemove.vehicleId) .. " for abandoned job")
  end
  
  local reward = math.floor((job.budget or 5000) * 3)
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
    log("W", "businessJobManager", "abandonJob: Business account cannot afford penalty of " .. tostring(penalty))
    return false
  end
  
  local success = career_modules_payment.pay(price, { label = "Abandoned job penalty", tags = {"jobAbandonment", "penalty"} }, accountId)
  if not success then
    log("W", "businessJobManager", "abandonJob: Failed to charge penalty")
    return false
  end
  
  table.remove(jobs.active, jobIndex)
  saveBusinessJobs(businessId)
  
  log("D", "businessJobManager", "abandonJob: Abandoned job " .. tostring(jobId) .. " with penalty of " .. tostring(penalty))
  return true
end

local function getJobById(businessId, jobId)
  local jobs = loadBusinessJobs(businessId)
  
  for _, job in ipairs(jobs.active or {}) do
    if job.jobId == jobId then return job end
  end
  
  for _, job in ipairs(jobs.new or {}) do
    if job.jobId == jobId then return job end
  end
  
  for _, job in ipairs(jobs.completed or {}) do
    if job.jobId == jobId then return job end
  end
  
  return nil
end

function M.onCareerActivated()
  businessJobs = {}
end

M.registerJobGenerator = registerJobGenerator
M.getJobsForBusiness = getJobsForBusiness
M.acceptJob = acceptJob
M.declineJob = declineJob
M.completeJob = completeJob
M.abandonJob = abandonJob
M.getJobById = getJobById

return M

