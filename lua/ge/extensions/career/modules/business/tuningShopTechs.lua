local M = {}

M.dependencies = {'career_career', 'career_saveSystem'}

local businessTechs = {}
local helpers = {}

local BASE_BUILD_SECONDS = 900
local BASE_UPDATE_SECONDS = 300
local BASE_COOLDOWN_SECONDS = 150

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

local TECH_ACTION_LABELS = {
  idle = function(job)
    return "Idle"
  end,
  driveToEvent = function(job)
    return string.format("Driving to %s", job and job.raceLabel or "Event")
  end,
  runEvent = function(job)
    return string.format("Running %s Event", job and job.raceLabel or "Event")
  end,
  driveBack = function()
    return "Driving back to the shop"
  end,
  build = function(job)
    return string.format("Building Vehicle for %s Event", job and job.raceLabel or "Event")
  end,
  update = function(job)
    return string.format("Updating Vehicle tune for %s Event", job and job.raceLabel or "Event")
  end,
  cooldown = function()
    return "Cooling down between runs"
  end,
  completed = function()
    return "Job Complete"
  end,
  failed = function()
    return "Job Failed"
  end
}

local function initialize(helperFunctions)
  helpers = helperFunctions or {}
end

local function normalizeBusinessId(businessId)
  return helpers.normalizeBusinessId and helpers.normalizeBusinessId(businessId) or (tonumber(businessId) or businessId)
end

local function getTechCapacity(businessId)
  local techsHired = 0
  local level = helpers.getSkillTreeLevel and helpers.getSkillTreeLevel(businessId, "automation", "shop-techs") or 0
  techsHired = techsHired + level
  return techsHired
end

local function ensureTechName(tech, index)
  if tech and (not tech.name or tech.name == "") then
    tech.name = string.format("Tech #%d", index or tech.id or 1)
  end
end

local function ensureTechIdentity(tech, index)
  if not tech.id then
    tech.id = index
  end
  ensureTechName(tech, index)
  tech.state = tech.state or 0
  tech.stateElapsed = tech.stateElapsed or 0
  tech.stateDuration = tech.stateDuration or 0
  tech.currentAction = tech.currentAction or "idle"
  tech.phase = tech.phase or "idle"
  tech.retriesUsed = tech.retriesUsed or 0
  tech.totalAttempts = tech.totalAttempts or 0
  tech.fundsHeld = tech.fundsHeld or 0
  tech.buildCost = tech.buildCost or 0
  tech.totalSpent = tech.totalSpent or 0
  tech.eventFunds = tech.eventFunds or 0
  tech.maxValidationAttempts = tech.maxValidationAttempts or 0
  tech.validationAttempts = tech.validationAttempts or 0
  tech.cooldownDuration = tech.cooldownDuration or 150
  tech.successfulJobs = tech.successfulJobs or 0
  tech.failedJobs = tech.failedJobs or 0
end

local function ensureTechSlots(businessId)
  if not businessId then
    return
  end
  local capacity = math.max(0, getTechCapacity(businessId))
  if capacity <= 0 then
    businessTechs[businessId] = {}
    return
  end

  local techs = businessTechs[businessId] or {}
  for index = 1, capacity do
    techs[index] = techs[index] or {
      id = index,
      name = string.format("Tech #%d", index),
      state = 0,
      stateElapsed = 0,
      stateDuration = 0,
      jobId = nil,
      retriesUsed = 0,
      totalAttempts = 0,
      fundsHeld = 0,
      buildCost = 0,
      eventFunds = 0
    }
    ensureTechIdentity(techs[index], index)
  end

  for i = capacity + 1, #techs do
    techs[i] = nil
  end

  businessTechs[businessId] = techs
  return techs
end

local function getBusinessTechsPath(businessId)
  if not career_career.isActive() then
    return nil
  end
  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  if not currentSavePath then
    return nil
  end
  return currentSavePath .. "/career/rls_career/businesses/" .. businessId .. "/techs.json"
end

local function loadBusinessTechs(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return {}
  end

  if businessTechs[businessId] then
    ensureTechSlots(businessId)
    return businessTechs[businessId]
  end

  local filePath = getBusinessTechsPath(businessId)
  local techs = {}
  if filePath then
    local data = jsonReadFile(filePath) or {}
    if data and data.techs then
      for index, tech in ipairs(data.techs) do
        ensureTechIdentity(tech, index)
        techs[index] = tech
      end
    end
  end

  businessTechs[businessId] = techs
  ensureTechSlots(businessId)
  return businessTechs[businessId]
end

local function getTechDisplayLabel(action, job)
  local fn = TECH_ACTION_LABELS[action]
  if fn then
    return fn(job)
  end
  return "Working"
end

local function formatTechForUIEntry(businessId, tech)
  if not tech then
    return nil
  end

  local job = nil
  if tech.jobId then
    job = helpers.getJobById and helpers.getJobById(businessId, tech.jobId) or nil
  end

  local label = getTechDisplayLabel(tech.currentAction, job)
  local totalSeconds = math.max(0, tonumber(tech.stateDuration) or 0)
  local elapsedSeconds = math.max(0, tonumber(tech.stateElapsed) or 0)
  local progress = 0
  if totalSeconds > 0 then
    progress = math.min(1, math.max(0, elapsedSeconds / totalSeconds))
  end

  local jobLabel = nil
  if job and job.raceLabel then
    jobLabel = job.raceLabel
  elseif tech.finishedJobInfo and tech.finishedJobInfo.label then
    jobLabel = tech.finishedJobInfo.label
  end

  local successfulJobs = tech.successfulJobs or 0
  local failedJobs = tech.failedJobs or 0
  local totalJobs = successfulJobs + failedJobs
  local successRate = 0
  if totalJobs > 0 then
    successRate = math.floor((successfulJobs / totalJobs) * 100 + 0.5)
  end

  local jobReward = nil
  if job and job.reward then
    jobReward = tonumber(job.reward) or 0
  end

  return {
    id = tech.id,
    name = tech.name,
    state = tech.state or 0,
    action = tech.currentAction or "idle",
    label = label,
    progress = progress,
    elapsedSeconds = elapsedSeconds,
    totalSeconds = totalSeconds,
    serverTime = os.clock(),
    jobId = tech.jobId,
    jobLabel = jobLabel,
    jobReward = jobReward,
    phase = tech.phase,
    validationAttempts = tech.validationAttempts or 0,
    maxValidationAttempts = tech.maxValidationAttempts or 0,
    eventFunds = math.floor(tech.eventFunds or 0),
    totalSpent = math.floor(tech.totalSpent or 0),
    latestResult = tech.latestResult,
    finishedJobInfo = tech.finishedJobInfo,
    canAssign = not tech.jobId and (tech.currentAction == "idle"),
    fundsHeld = tech.fundsHeld,
    successRate = successRate,
    successfulJobs = successfulJobs,
    failedJobs = failedJobs,
    maxTier = M.getTechMaxTier(businessId)
  }
end

local function notifyTechsUpdated(businessId)
  if not businessId then
    return
  end

  local techEntries = {}
  local techList = loadBusinessTechs(businessId)
  for _, tech in ipairs(techList) do
    local formattedTech = formatTechForUIEntry(businessId, tech)
    if formattedTech then
      table.insert(techEntries, formattedTech)
    end
  end

  guihooks.trigger('businessComputer:onTechsUpdated', {
    businessType = "tuningShop",
    businessId = tostring(businessId),
    techs = techEntries
  })
end

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

local function generateValidationTime(businessId, job, updateTune)
  if not job then
    return 0
  end
  local target = tonumber(job.targetTime) or 0
  if target <= 0 then
    return math.max(1, target)
  end

  if helpers.hasPerfectTechs and helpers.hasPerfectTechs(businessId) then
    local minRatio = 0.975
    local maxRatio = 0.999
    local ratio = minRatio + math.random() * (maxRatio - minRatio)
    return target * ratio
  end

  local minRatio = 0.9875
  local maxRatio = 1.0375

  local hasMasterTechs = helpers.hasMasterTechs and helpers.hasMasterTechs(businessId) or false

  if hasMasterTechs then
    if updateTune then
      maxRatio = 1.0375
    else
      maxRatio = 1.07083
    end
  else
    if updateTune then
      maxRatio = 1.023214
    end
  end

  local reductionPercent = helpers.getReliableFailureReduction and helpers.getReliableFailureReduction(businessId) or 0
  if reductionPercent > 0 then
    local normalized = reductionPercent / 0.25
    maxRatio = maxRatio - (0.025 * normalized)
    maxRatio = math.max(1.0125, maxRatio)
  end

  local ratio = minRatio + math.random() * (maxRatio - minRatio)
  return target * ratio
end

local function calculateUpdateCost(tech)
  local buildCost = tonumber(tech and tech.buildCost) or 0
  if buildCost <= 0 then
    return 0
  end
  return math.floor(buildCost * 0.25)
end

local function finalizeTechJobSuccess(businessId, tech, job)
  if not job then
    resetTechToIdle(tech)
    return
  end

  job.locked = false
  job.techAssigned = nil

  local totalSpent = tonumber(tech.totalSpent) or 0
  local buildCost = tonumber(tech.buildCost) or 0
  local eventFunds = tonumber(tech.eventFunds) or 0
  local cappedEventFunds = math.min(eventFunds, buildCost)
  local reward = tonumber(job.reward) or 0
  local net = reward - totalSpent + cappedEventFunds
  local payout = math.max(0, math.floor(net * 0.95))

  if helpers.creditBusinessAccount then
    helpers.creditBusinessAccount(businessId, payout, "Automation Job Reward",
      string.format("Job #%s automation payout", tostring(job.jobId)))
  end

  local baseXP = 10
  local xpReward = math.floor(baseXP * (helpers.getXPGainMultiplier and helpers.getXPGainMultiplier(businessId) or 1))
  if helpers.addBusinessXP then
    helpers.addBusinessXP(businessId, xpReward)
  end

  if helpers.removeJobVehicle then
    helpers.removeJobVehicle(businessId, job.jobId)
  end
  if helpers.clearJobLeaderboardEntry then
    helpers.clearJobLeaderboardEntry(businessId, job.jobId)
  end

  if helpers.moveJobToCompleted then
    helpers.moveJobToCompleted(businessId, job.jobId, "completed", {
      result = "success",
      payout = payout,
      net = net,
      totalSpent = totalSpent,
      eventFunds = cappedEventFunds,
      attempts = tech.totalAttempts,
      predictedTime = tech.predictedEventTime
    })
  end

  tech.finishedJobInfo = {
    label = job.raceLabel,
    payout = payout
  }
  tech.successfulJobs = (tech.successfulJobs or 0) + 1
  tech.jobId = nil
  tech.phase = "completed"
  setTechState(tech, TECH_STATE.COMPLETED, "completed", 3, {
    jobLabel = job.raceLabel
  })
  notifyTechsUpdated(businessId)
end

local function finalizeTechJobFailure(businessId, tech, job, reason)
  if not job then
    resetTechToIdle(tech)
    return
  end

  job.locked = false
  job.techAssigned = nil

  local totalSpent = tonumber(tech.totalSpent) or 0
  local eventFunds = tonumber(tech.eventFunds) or 0
  local penaltyBase = helpers.getAbandonPenalty and helpers.getAbandonPenalty(businessId, job.jobId) or 0
  local penalty = math.max(0, penaltyBase)

  if penalty > 0 and helpers.debitBusinessAccount then
    helpers.debitBusinessAccount(businessId, penalty, "Automation Failure Penalty",
      string.format("Job #%s failure", tostring(job.jobId)))
  end

  if helpers.removeJobVehicle then
    helpers.removeJobVehicle(businessId, job.jobId)
  end
  if helpers.clearJobLeaderboardEntry then
    helpers.clearJobLeaderboardEntry(businessId, job.jobId)
  end

  if helpers.moveJobToCompleted then
    helpers.moveJobToCompleted(businessId, job.jobId, "failed", {
      result = "failed",
      penalty = penalty,
      totalSpent = totalSpent,
      eventFunds = eventFunds,
      attempts = tech.totalAttempts,
      predictedTime = tech.predictedEventTime,
      reason = reason
    })
  end

  tech.finishedJobInfo = {
    label = job.raceLabel,
    penalty = penalty
  }
  tech.failedJobs = (tech.failedJobs or 0) + 1
  tech.jobId = nil
  tech.phase = "failed"
  setTechState(tech, TECH_STATE.FAILED, "failed", 3, {
    jobLabel = job.raceLabel
  })
  notifyTechsUpdated(businessId)
end

local function determineDriveStateCode(tech)
  if tech.phase == "validation" then
    return TECH_STATE.DRIVE_VALIDATION
  elseif tech.phase == "postUpdate" then
    return TECH_STATE.DRIVE_FINAL
  else
    return TECH_STATE.DRIVE_BASELINE
  end
end

local function startCommute(businessId, tech, job)
  if not job then
    resetTechToIdle(tech)
    return
  end
  local duration = helpers.getCommuteSeconds and helpers.getCommuteSeconds(job) or 120
  local stateCode = determineDriveStateCode(tech)
  setTechState(tech, stateCode, "driveToEvent", duration, {
    jobId = job.jobId
  })
end

local function startEventRun(businessId, tech, job)
  if not job then
    resetTechToIdle(tech)
    return
  end

  if tech.phase == "baseline" then
    local duration = math.max(1, tonumber(job.baseTime) or tonumber(job.targetTime) or 60)
    setTechState(tech, TECH_STATE.RUN_EVENT, "runEvent", duration, {
      jobId = job.jobId,
      phase = tech.phase
    })
    return
  end

  tech.validationAttempts = (tech.validationAttempts or 0) + 1
  tech.totalAttempts = (tech.totalAttempts or 0) + 1
  tech.predictedEventTime = generateValidationTime(businessId, job, tech.phase == "postUpdate")
  local duration = math.max(1, tech.predictedEventTime)
  setTechState(tech, TECH_STATE.RUN_EVENT, "runEvent", duration, {
    jobId = job.jobId,
    phase = tech.phase
  })
end

local function startDriveBack(tech, job)
  if not job then
    resetTechToIdle(tech)
    return
  end
  local duration = helpers.getCommuteSeconds and helpers.getCommuteSeconds(job) or 120
  setTechState(tech, TECH_STATE.DRIVE_BACK, "driveBack", duration, {
    jobId = job.jobId
  })
end

local function startBuildPhase(businessId, tech, job)
  if not job then
    resetTechToIdle(tech)
    return
  end

  local buildCost = helpers.calculateBuildCost and helpers.calculateBuildCost(businessId, job) or 0
  tech.buildCost = buildCost
  tech.totalSpent = buildCost

  if buildCost > 0 then
    local success = helpers.debitBusinessAccount and
                      helpers.debitBusinessAccount(businessId, buildCost, "Automation Build Cost",
        string.format("Job #%s build", tostring(job.jobId))) or false
    if not success then
      finalizeTechJobFailure(businessId, tech, job, "paymentFailed")
      return
    end
  end

  local duration = helpers.getBuildTimeSeconds and helpers.getBuildTimeSeconds(BASE_BUILD_SECONDS, businessId) or
                     BASE_BUILD_SECONDS
  setTechState(tech, TECH_STATE.BUILD, "build", duration, {
    jobId = job.jobId
  })
end

local function startUpdatePhase(businessId, tech, job)
  if not job then
    resetTechToIdle(tech)
    return
  end

  local updateCost = calculateUpdateCost(tech)
  if updateCost > 0 then
    tech.totalSpent = (tech.totalSpent or 0) + updateCost
    local success = helpers.debitBusinessAccount and
                      helpers.debitBusinessAccount(businessId, updateCost, "Automation Tune Update",
        string.format("Job #%s update", tostring(job.jobId))) or false
    if not success then
      finalizeTechJobFailure(businessId, tech, job, "paymentFailed")
      return
    end
  end

  local duration = helpers.getBuildTimeSeconds and helpers.getBuildTimeSeconds(BASE_UPDATE_SECONDS, businessId) or
                     BASE_UPDATE_SECONDS
  setTechState(tech, TECH_STATE.UPDATE, "update", duration, {
    jobId = job.jobId
  })
end

local function beginValidationCycle(businessId, tech, job, phase)
  tech.phase = phase or "validation"
  tech.validationAttempts = 0
  tech.maxValidationAttempts = 1 + (helpers.getEventRetryAllowance and helpers.getEventRetryAllowance(businessId) or 0)
  tech.predictedEventTime = nil
  startCommute(businessId, tech, job)
end

local function startCooldownPhase(tech, job)
  if not job then
    resetTechToIdle(tech)
    return
  end
  local duration = tech.cooldownDuration or BASE_COOLDOWN_SECONDS
  setTechState(tech, TECH_STATE.COOLDOWN, "cooldown", duration, {
    jobId = job.jobId
  })
end

local function validationSucceeded(tech, job)
  local target = tonumber(job and job.targetTime) or 0
  if target <= 0 then
    return true
  end
  local predicted = tonumber(tech and tech.predictedEventTime) or target
  return predicted <= target
end

local function handleValidationResult(businessId, tech, job)
  if not job then
    resetTechToIdle(tech)
    return
  end

  local success = tech.latestResult and tech.latestResult.success
  if success == nil then
    success = validationSucceeded(tech, job)
    tech.latestResult = {
      predictedTime = tech.predictedEventTime,
      targetTime = job.targetTime,
      success = success
    }
  end

  if success then
    finalizeTechJobSuccess(businessId, tech, job)
    return
  end

  local attemptsAllowed = tech.maxValidationAttempts or 1
  local attemptsUsed = tech.validationAttempts or 0
  if attemptsUsed >= attemptsAllowed then
    if tech.phase == "validation" then
      startUpdatePhase(businessId, tech, job)
      return
    end

    finalizeTechJobFailure(businessId, tech, job, "validationFailed")
    return
  end

  resetTechToIdle(tech)
end

local function advanceTechState(businessId, tech)
  if not tech then
    return false
  end
  if not tech.jobId and tech.currentAction ~= "completed" and tech.currentAction ~= "failed" then
    resetTechToIdle(tech)
    return false
  end

  local job = helpers.getJobById and helpers.getJobById(businessId, tech.jobId) or nil
  if (not job) and tech.jobId then
    resetTechToIdle(tech)
    return false
  end

  local action = tech.currentAction

  if action == "driveToEvent" then
    startEventRun(businessId, tech, job)
    return true
  elseif action == "runEvent" then
    local predictedTime = tech.predictedEventTime
    if tech.phase == "baseline" then
      predictedTime = job.baseTime or job.targetTime or 0
    end
    local actualPayment = helpers.calculateActualEventPayment and
                            helpers.calculateActualEventPayment(businessId, job, predictedTime) or 0
    tech.eventFunds = (tech.eventFunds or 0) + actualPayment
    if tech.phase == "baseline" then
      startDriveBack(tech, job)
    else
      local success = validationSucceeded(tech, job)
      tech.latestResult = {
        predictedTime = tech.predictedEventTime,
        targetTime = job.targetTime,
        success = success
      }

      if success then
        startDriveBack(tech, job)
      else
        local attemptsAllowed = tech.maxValidationAttempts or 1
        local attemptsUsed = tech.validationAttempts or 0

        if attemptsUsed >= attemptsAllowed then
          startDriveBack(tech, job)
        else
          startCooldownPhase(tech, job)
        end
      end
    end
    return true
  elseif action == "cooldown" then
    if tech.phase == "baseline" then
      startDriveBack(tech, job)
    else
      local attemptsAllowed = tech.maxValidationAttempts or 1
      local attemptsUsed = tech.validationAttempts or 0

      if attemptsUsed >= attemptsAllowed then
        startDriveBack(tech, job)
      else
        startEventRun(businessId, tech, job)
      end
    end
    return true
  elseif action == "driveBack" then
    if tech.phase == "baseline" then
      startBuildPhase(businessId, tech, job)
    else
      handleValidationResult(businessId, tech, job)
    end
    return true
  elseif action == "build" then
    beginValidationCycle(businessId, tech, job, "validation")
    return true
  elseif action == "update" then
    beginValidationCycle(businessId, tech, job, "postUpdate")
    return true
  elseif action == "completed" or action == "failed" then
    resetTechToIdle(tech)
    notifyTechsUpdated(businessId)
    return false
  else
    resetTechToIdle(tech)
    return false
  end
end

local function processTechs(businessId, dtSim)
  if not businessId or dtSim <= 0 then
    return
  end

  local techs = loadBusinessTechs(businessId)
  local anyChanged = false

  for _, tech in ipairs(techs) do
    if tech.currentAction ~= "idle" then
      local timeRemaining = dtSim
      local safety = 0
      while timeRemaining > 0 and safety < 16 do
        safety = safety + 1
        local duration = tech.stateDuration or 0

        -- Capture state before attempting advance
        local beforeState = tech.state
        local beforeAction = tech.currentAction
        local beforePhase = tech.phase

        local advanced = false

        if duration <= 0 then
          if not advanceTechState(businessId, tech) then
            break
          else
            advanced = true
          end
        else
          local needed = duration - tech.stateElapsed
          if needed <= 0 then
            if not advanceTechState(businessId, tech) then
              break
            else
              advanced = true
            end
          else
            local delta = math.min(needed, timeRemaining)
            tech.stateElapsed = tech.stateElapsed + delta
            timeRemaining = timeRemaining - delta
            if tech.stateElapsed >= tech.stateDuration - 1e-6 then
              if not advanceTechState(businessId, tech) then
                break
              else
                advanced = true
              end
            end
          end
        end

        if advanced then
          -- Check if state actually changed
          if tech.state == beforeState and tech.currentAction == beforeAction and tech.phase == beforePhase then
            log("W", "tuningShopTechs",
              string.format("Tech #%d stuck in infinite loop (state: %s, action: %s). Breaking.", tech.id,
                tostring(tech.state), tostring(tech.currentAction)))
            break
          end
          anyChanged = true
          goto continue_inner
        end

        ::continue_inner::
      end
    end
  end

  if anyChanged then
    notifyTechsUpdated(businessId)
  end
end

local function saveBusinessTechs(businessId, currentSavePath)
  businessId = normalizeBusinessId(businessId)
  if not businessId or not businessTechs[businessId] then
    return
  end
  if not currentSavePath then
    return
  end

  local filePath = currentSavePath .. "/career/rls_career/businesses/" .. businessId .. "/techs.json"
  local dirPath = string.match(filePath, "^(.*)/[^/]+$")
  if dirPath and not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end

  local data = {
    techs = businessTechs[businessId]
  }

  jsonWriteFile(filePath, data, true)
end

local function getTechById(businessId, techId)
  if not businessId or not techId then
    return nil
  end
  local techs = loadBusinessTechs(businessId)
  for _, tech in ipairs(techs) do
    if tech.id == techId then
      return tech
    end
  end
  return nil
end

local function updateTechName(businessId, techId, newName)
  businessId = normalizeBusinessId(businessId)
  techId = tonumber(techId)
  if not businessId or not techId then
    return false
  end

  local tech = getTechById(businessId, techId)
  if not tech then
    return false
  end

  if type(newName) == "string" then
    local trimmed = newName:match("^%s*(.-)%s*$")
    if trimmed == "" then
      trimmed = string.format("Tech #%d", techId)
    end
    tech.name = trimmed
    notifyTechsUpdated(businessId)
    return true
  end

  return false
end

local function getTechsForBusiness(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return {}
  end

  local techs = loadBusinessTechs(businessId)
  local result = {}
  for _, tech in ipairs(techs) do
    table.insert(result, deepcopy(tech))
  end
  return result
end

local function isJobLockedByTech(businessId, jobId)
  businessId = normalizeBusinessId(businessId)
  jobId = tonumber(jobId) or jobId
  if not businessId or not jobId then
    return false
  end

  local techs = loadBusinessTechs(businessId)
  for _, tech in ipairs(techs) do
    local tJobId = tonumber(tech.jobId) or tech.jobId
    if tJobId == jobId then
      return true
    end
  end
  return false
end

local function getWorkingTechsCount(businessId)
  local techs = loadBusinessTechs(businessId)
  local count = 0
  for _, tech in ipairs(techs) do
    if tech.jobId then
      count = count + 1
    end
  end
  return count
end

local function getIdleTechs(businessId)
  local techs = loadBusinessTechs(businessId)
  local idleTechs = {}
  for _, tech in ipairs(techs) do
    if not tech.jobId and (tech.currentAction == "idle" or not tech.currentAction) then
      table.insert(idleTechs, tech)
    end
  end
  return idleTechs
end

local function canAssignTechToJob(businessId)
  local liftsAvailable = 1
  if helpers.getMaxPulledOutVehicles then
    liftsAvailable = helpers.getMaxPulledOutVehicles(businessId) or 1
  end

  local workingTechs = getWorkingTechsCount(businessId)
  return workingTechs < liftsAvailable
end

local function getTechMaxTier(businessId)
  local baseTier = 1
  local skilledTechsLevel = helpers.getSkillTreeLevel and
                              helpers.getSkillTreeLevel(businessId, "automation", "skilled-techs") or 0
  return baseTier + skilledTechsLevel
end

local function assignJobToTech(businessId, techId, jobId)
  businessId = normalizeBusinessId(businessId)
  techId = tonumber(techId)
  jobId = tonumber(jobId) or jobId

  if not businessId or not techId or not jobId then
    return false, "invalidParameters"
  end

  local tech = getTechById(businessId, techId)
  if not tech then
    return false, "techNotFound"
  end

  if tech.jobId then
    return false, "techBusy"
  end

  local job = nil
  if helpers.loadBusinessJobs then
    local jobs = helpers.loadBusinessJobs(businessId)
    for _, activeJob in ipairs(jobs.active or {}) do
      local jId = tonumber(activeJob.jobId) or activeJob.jobId
      if jId == jobId then
        job = activeJob
        break
      end
    end
  end

  if not job then
    return false, "jobNotActive"
  end

  if job.techAssigned and job.techAssigned ~= techId then
    return false, "jobLocked"
  end

  local jobTier = tonumber(job.tier) or 1
  local techMaxTier = getTechMaxTier(businessId)
  if jobTier > techMaxTier then
    return false, "tierTooHigh"
  end

  if not canAssignTechToJob(businessId) then
    return false, "noLiftAvailable"
  end

  tech.jobId = jobId
  tech.validationAttempts = 0
  tech.maxValidationAttempts = 0
  tech.totalAttempts = 0
  tech.totalSpent = 0
  tech.eventFunds = 0
  tech.retriesUsed = 0
  tech.predictedEventTime = nil
  tech.latestResult = nil
  job.techAssigned = techId
  job.locked = true

  if helpers.clearBusinessCachesForJob then
    helpers.clearBusinessCachesForJob(businessId, jobId)
  end

  if helpers.removeJobVehicle then
    helpers.removeJobVehicle(businessId, jobId)
  end

  local hasMasterTechs = helpers.hasMasterTechs and helpers.hasMasterTechs(businessId) or false

  if hasMasterTechs then
    tech.phase = "build"
    startBuildPhase(businessId, tech, job)
  else
    tech.phase = "baseline"
    local commuteSeconds = helpers.getCommuteSeconds and helpers.getCommuteSeconds(job) or 120
    setTechState(tech, TECH_STATE.DRIVE_BASELINE, "driveToEvent", commuteSeconds, {
      jobId = jobId,
      phase = "baseline"
    })
  end

  notifyTechsUpdated(businessId)
  if helpers.notifyJobsUpdated then
    helpers.notifyJobsUpdated(businessId)
  end
  return true
end

local function resetTechs()
  businessTechs = {}
end

M.initialize = initialize
M.processTechs = processTechs
M.saveBusinessTechs = saveBusinessTechs
M.loadBusinessTechs = loadBusinessTechs
M.getTechById = getTechById
M.updateTechName = updateTechName
M.getTechsForBusiness = getTechsForBusiness
M.isJobLockedByTech = isJobLockedByTech
M.assignJobToTech = assignJobToTech
M.formatTechForUIEntry = formatTechForUIEntry
M.notifyTechsUpdated = notifyTechsUpdated
M.resetTechs = resetTechs
M.getIdleTechs = getIdleTechs
M.getTechMaxTier = getTechMaxTier
M.canAssignTechToJob = canAssignTechToJob

return M

