-- Customer-job pricing, account postings and once-only settlement.
-- Read terms, account helpers, accepting/declining and completing/abandoning jobs.
local recordJob = require("overhaul/lib/progression/logbookFeed").register("overhaul.businessJobCompleted", {
  title = "Customer job completed", label = "Business", icon = "checkmark"
}, "career/business/tuningShop/shop/settlement.lua")

local capabilities = require("overhaul/lib/platform/capabilities")
local installer = {}

function installer.new(inputs)
  -- State and callbacks -------------------------------------------------------------------------
  local parts = inputs.parts
  local operations = {}
  local freeroamUtils = inputs.freeroamUtils

  -- Capacity and technician upgrades --------------------------------------------------------------

  local function getMaxActiveJobs(businessId)
    local baseLimit = 2
    if not businessId then return baseLimit end

    local treeId = "shop-upgrades"
    local biggerBooksLevel =
      overhaul_career_business_skillTree.getNodeProgress(businessId, treeId, "bigger-books") or 0

    return baseLimit + biggerBooksLevel
  end

  local function getFasterTechReduction(businessId)
    local level1 = parts.garage.getSkillTreeLevel(businessId, "automation", "faster-techs")
    local level2 = parts.garage.getSkillTreeLevel(businessId, "automation", "faster-techs-ii")
    local total = math.max(0, level1 + level2)
    local reduction = math.min(0.65, total * 0.05)
    return reduction
  end

  local function getBuildTimeSeconds(baseSeconds, businessId)
    local reduction = getFasterTechReduction(businessId)
    return math.max(1, baseSeconds * (1 - reduction))
  end

  local function getBuildCostDiscount(businessId)
    local suppliers = math.min(0.25, parts.garage.getSkillTreeLevel(businessId, "shop-upgrades", "part-suppliers") * 0.05)
    local smart = math.min(0.25, parts.garage.getSkillTreeLevel(businessId, "automation", "smart-techs") * 0.05)
    return math.min(0.5, suppliers + smart)
  end

  local function getReliableFailureReduction(businessId)
    return math.min(0.25, parts.garage.getSkillTreeLevel(businessId, "automation", "reliable-techs") * 0.05)
  end

  local function hasPerfectTechs(businessId)
    return parts.garage.getSkillTreeLevel(businessId, "automation", "perfect-techs") > 0
  end

  local function hasMasterTechs(businessId)
    return parts.garage.getSkillTreeLevel(businessId, "automation", "master-techs") > 0
  end

  local function getEventRetryAllowance(businessId)
    return math.max(0, parts.garage.getSkillTreeLevel(businessId, "automation", "event-retries"))
  end

  -- Account postings ------------------------------------------------------------------------------

  local function getBusinessAccount(businessId)
    local account = overhaul_career_economy_bank.getBusinessAccount("tuningShop", businessId)
    if not account then
      overhaul_career_economy_bank.createBusinessAccount("tuningShop", businessId)
      account = overhaul_career_economy_bank.getBusinessAccount("tuningShop", businessId)
    end
    return account
  end

  local function creditBusinessAccount(businessId, amount, reason, description)
    amount = math.floor(amount or 0)
    if amount <= 0 then return true end
    local account = getBusinessAccount(businessId)
    if not account then return false end
    return overhaul_career_economy_bank.rewardToAccount({
      money = {
        amount = amount
      }
    }, account.id, reason or "Automation Payout", description or "", {category = "business"})
  end

  local function debitBusinessAccount(businessId, amount, reason, description, allowNegativeBalance)
    amount = math.floor(amount or 0)
    if amount <= 0 then return true end
    local account = getBusinessAccount(businessId)
    if not account then return false end
    return overhaul_career_economy_bank.removeFunds(account.id, amount, reason or "Automation Expense",
      description or "Expense", allowNegativeBalance == true, {category = "business"})
  end

  -- Job vehicles ----------------------------------------------------------------------------------

  local function getVehicleByJobId(businessId, jobId)
    if not businessId or not jobId then return nil end
    local vehicles = overhaul_career_business_fleet.getBusinessVehicles(businessId) or {}
    for _, vehicle in ipairs(vehicles) do
      local vJobId = tonumber(vehicle.jobId) or vehicle.jobId
      if vJobId == jobId then return vehicle end
    end
    return nil
  end

  -- Keep the stored row alive until the live conditions and world cleanup finish.
  local function removeFleetVehicle(businessId, vehicle, onComplete)
    local inv = overhaul_career_business_fleet
    local removeId = tonumber(vehicle.vehicleId) or vehicle.vehicleId
    local finished = false
    local function finish(ok)
      if finished then return false end
      finished = true
      local removed = ok ~= false and inv.getVehicleById(businessId, removeId) == vehicle
        and inv.removeVehicle(businessId, removeId) and true or false
      if onComplete then onComplete(removed) end
      return removed
    end
    for _, pulled in ipairs(inv.getPulledOutVehicles(businessId) or {}) do
      if (tonumber(pulled.vehicleId) or pulled.vehicleId) == removeId then
        inv.putAwayVehicle(businessId, removeId, finish)
        return
      end
    end
    finish()
  end

  local function removeJobVehicle(businessId, jobId)
    local vehicleToRemove = getVehicleByJobId(businessId, jobId)

    if not vehicleToRemove then return end

    local removeId = tonumber(vehicleToRemove.vehicleId) or vehicleToRemove.vehicleId
    removeFleetVehicle(businessId, vehicleToRemove, function(ok)
      if not ok then return end
      local vehiclesData = capabilities.get("businessComputer").getVehiclesOnly(businessId)
      local businessType = "tuningShop"
      guihooks.trigger('businessComputer:onVehiclePutAway', {
        businessType = businessType,
        businessId = tostring(businessId),
        vehicleId = removeId,
        vehicles = vehiclesData.vehicles,
        pulledOutVehicles = vehiclesData.pulledOutVehicles,
        maxPulledOutVehicles = vehiclesData.maxPulledOutVehicles
      })
      overhaul_career_saveSystem.saveCurrent()
    end)
  end

  -- Saved job terms and reward policy -------------------------------------------------------------

  local function getCommuteSeconds(job)
    if not job then return 120 end
    return math.max(15, tonumber(job.commuteSeconds) or 120)
  end

  local function getEventReward(job)
    if not job then return 0 end
    return tonumber(job.eventReward) or 0
  end

  local function calculateActualEventPayment(businessId, job, predictedTime)
    if not job or not predictedTime or predictedTime <= 0 then return 0 end

    local races = parts.persist.loadRaceData(businessId)
    if not races or not races.races then return getEventReward(job) end

    local raceIdentifier = parts.persist.convertRaceTypeToIdentifier(job.raceType)
    local race = races.races[raceIdentifier]

    if not race then return getEventReward(job) end

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

    if not overhaul_career_career.isActive() then return math.max(0, reward) end

    local isNewBest = actualTime <= targetTime
    if not isNewBest then
      reward = reward / 2
    end

    if isNewBest then
      reward = reward * 1.2
    end

    reward = reward * (tonumber(overhaul_career_economy_difficultyMode.getRewardMultiplier()) or 1)

    return math.max(0, math.floor(reward + 0.5))
  end

  local function calculateBuildCost(businessId, job)
    if not job then return 0 end
    local reward = tonumber(job.reward) or 0
    local baseCost = reward * 0.3
    local variation = 0.95 + (math.random() * 0.1)
    local variedCost = baseCost * variation
    local discount = getBuildCostDiscount(businessId)
    local cost = variedCost * (1 - discount)
    local rounded = math.floor(cost * 100 + 0.5) / 100
    return math.max(0, rounded)
  end

  -- Job retirement --------------------------------------------------------------------------------

  local function moveJobToCompleted(businessId, jobId, status, automationData)
    local jobs = parts.persist.loadBusinessJobs(businessId)
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

    if not jobIndex or not job then return nil end

    local removedJob = table.remove(jobs.active, jobIndex)
    removedJob.status = status or "completed"
    removedJob.completedTime = os.time()
    removedJob.automationResult = automationData or {}
    removedJob.techAssigned = nil

    parts.views.notifyJobsUpdated(businessId)
    overhaul_career_saveSystem.saveCurrent()
    return removedJob
  end

  -- Customer acceptance and refusal ---------------------------------------------------------------

  local function getAbandonPenalty(businessId, jobId)
    if not businessId or not jobId then return 0 end

    local job = parts.persist.getJobById(businessId, jobId)
    if not job then return 0 end

    if businessId then
      local treeId = "quality-of-life"
      local iGiveUpLevel = overhaul_career_business_skillTree.getNodeProgress(businessId, treeId, "i-give-up") or 0
      if iGiveUpLevel > 0 then return 0 end
    end

    local reward = job.reward or 20000

    local reduction = 0
    if businessId then
      local treeId = "quality-of-life"
      local noHardFeelingsLevel = overhaul_career_business_skillTree.getNodeProgress(businessId, treeId,
        "no-hard-feelings") or 0
      reduction = noHardFeelingsLevel * 0.05
    end

    local penaltyMultiplier = math.max(0, 0.5 - reduction)
    local penalty = math.floor(reward * penaltyMultiplier)

    return penalty
  end
  operations.acceptJob = function(businessId, jobId)
    if not businessId or not jobId then return false end

    jobId = tonumber(jobId) or jobId
    local jobs = parts.persist.loadBusinessJobs(businessId)

    local maxActiveJobs = getMaxActiveJobs(businessId)
    local currentActiveCount = #(jobs.active or {})

    if currentActiveCount >= maxActiveJobs then return false end

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
      local okStore, storedVehicleId = overhaul_career_business_fleet.storeVehicle(businessId, vehicleData)
      if okStore and storedVehicleId ~= nil then
        job.storedVehicleId = storedVehicleId
        -- New fleet rows can reuse vehicle ids; wipe any leftover race times.
        parts.proof.jobCompletion.clearLeaderboardEntry(businessId, job.jobId, storedVehicleId)
      end
    end

    overhaul_career_saveSystem.saveCurrent()

    return true
  end

  local function declineJob(businessId, jobId)
    if not businessId or not jobId then return false end

    jobId = tonumber(jobId) or jobId
    local jobs = parts.persist.loadBusinessJobs(businessId)

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

  -- Once-only completion and abandonment ----------------------------------------------------------

  local function findActiveJob(jobs, jobId)
    for index, job in ipairs(jobs.active or {}) do
      local normalizedId = tonumber(job.jobId) or job.jobId
      if normalizedId == jobId then return index, job end
    end
  end

  local function creditCustomerJob(businessId, jobId, reward)
    local paid = false
    local businessAccount = overhaul_career_economy_bank.getBusinessAccount("tuningShop", businessId)
    if not businessAccount then
      overhaul_career_economy_bank.createBusinessAccount("tuningShop", businessId)
      businessAccount = overhaul_career_economy_bank.getBusinessAccount("tuningShop", businessId)
    end
    if businessAccount then
      local accountId = businessAccount.id
      paid = overhaul_career_economy_bank.rewardToAccount({
        money = {
          amount = reward
        }
      }, accountId, "Job Reward", "Job #" .. tostring(jobId) .. " completed", {category = "business"}) and true or false
    end
    return paid
  end

  local function chargeAbandonedJob(businessId, jobId, job, penalty)
    local charged = false
    local businessName = job.businessName or ("tuningShop " .. tostring(businessId))
    local businessAccount = overhaul_career_economy_bank.getBusinessAccount("tuningShop", businessId)
    if not businessAccount then
      overhaul_career_economy_bank.createBusinessAccount("tuningShop", businessId, businessName)
      businessAccount = overhaul_career_economy_bank.getBusinessAccount("tuningShop", businessId)
    end

    if businessAccount then
      charged = overhaul_career_economy_bank.removeFunds(businessAccount.id, penalty, "Job Penalty",
        "Abandoned Job #" .. tostring(jobId), true, {category = "business"}) and true or false
    end
    return charged
  end

  local pendingCustomerJobs = {}

  local function retireCustomerVehicle(businessId, jobId, job, vehicleToRemove, onComplete)
    if vehicleToRemove then
      removeFleetVehicle(businessId, vehicleToRemove, onComplete)
    else
      onComplete(true)
    end
  end

  -- Returns nil while put-away is pending; the callback reports the final outcome.
  local function settleCustomerJob(businessId, jobId, abandoned, onComplete)
    local result
    local function finish(success)
      result = success
      if onComplete then onComplete(success) end
      return success
    end
    if not businessId or not jobId then return finish(false) end
    jobId = tonumber(jobId) or jobId
    local jobs = parts.persist.loadBusinessJobs(businessId)
    local jobIndex, job = findActiveJob(jobs, jobId)
    if not jobIndex or pendingCustomerJobs[job] then return finish(false) end
    if not abandoned and not parts.proof.jobCompletion.canComplete(businessId, jobId) then return finish(false) end
    local reward = job.reward or 20000
    local penalty = abandoned and getAbandonPenalty(businessId, jobId) or 0
    local vehicle = getVehicleByJobId(businessId, jobId)
    local fleetVehicleId = vehicle and (tonumber(vehicle.vehicleId) or vehicle.vehicleId) or job.storedVehicleId
    local finished = false
    pendingCustomerJobs[job] = true
    retireCustomerVehicle(businessId, jobId, job, vehicle, function(ok)
      if finished then return end
      finished = true
      pendingCustomerJobs[job] = nil
      if not ok then
        ui_message("Could not put away the customer vehicle. The job has not been settled. Please try again.",
          10, "business")
        return finish(false)
      end
      -- Other jobs may have moved while the live-condition reply was pending.
      jobs = parts.persist.loadBusinessJobs(businessId)
      local currentIndex, currentJob = findActiveJob(jobs, jobId)
      if currentJob ~= job then return finish(false) end
      -- Consume before posting money so reentrant requests cannot pay twice.
      table.remove(jobs.active, currentIndex)
      local posted
      if abandoned then
        posted = penalty <= 0 or chargeAbandonedJob(businessId, jobId, job, penalty)
      else
        posted = creditCustomerJob(businessId, jobId, reward)
      end
      if not posted then
        table.insert(jobs.active, math.min(currentIndex, #jobs.active + 1), job)
        ui_message("Could not post the job payment or penalty. The job has not been settled. Please try again.",
          10, "business")
        return finish(false)
      end
      if not abandoned then
        local xpReward = math.floor(10 * parts.garage.getXPGainMultiplier(businessId))
        parts.persist.addBusinessXP(businessId, xpReward)
      end
      parts.proof.jobCompletion.clearLeaderboardEntry(businessId, jobId, fleetVehicleId)
      job.status = abandoned and "abandoned" or "completed"
      job.completedTime = os.time()
      if not abandoned then
        recordJob({detail = "Business account / Customer job " .. tostring(jobId), money = reward})
      end
      overhaul_career_saveSystem.saveCurrent()
      finish(true)
    end)
    return result
  end

  local function completeJob(businessId, jobId, onComplete)
    return settleCustomerJob(businessId, jobId, false, onComplete)
  end

  local function abandonJob(businessId, jobId, onComplete)
    return settleCustomerJob(businessId, jobId, true, onComplete)
  end

  -- Public services -----------------------------------------------------------------------------
  return {
    abandonJob = abandonJob,
    acceptJob = operations.acceptJob,
    calculateActualEventPayment = calculateActualEventPayment,
    calculateBuildCost = calculateBuildCost,
    completeJob = completeJob,
    creditBusinessAccount = creditBusinessAccount,
    debitBusinessAccount = debitBusinessAccount,
    declineJob = declineJob,
    getAbandonPenalty = getAbandonPenalty,
    getBuildTimeSeconds = getBuildTimeSeconds,
    getCommuteSeconds = getCommuteSeconds,
    getEventRetryAllowance = getEventRetryAllowance,
    getEventReward = getEventReward,
    getMaxActiveJobs = getMaxActiveJobs,
    getReliableFailureReduction = getReliableFailureReduction,
    getVehicleByJobId = getVehicleByJobId,
    hasMasterTechs = hasMasterTechs,
    hasPerfectTechs = hasPerfectTechs,
    moveJobToCompleted = moveJobToCompleted,
    removeJobVehicle = removeJobVehicle,
  }
end

return installer
