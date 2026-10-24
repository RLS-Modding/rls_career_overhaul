-- Tuning shop tech state machine: each busy tech moves through drive, run, build, tune and payout steps.
-- Read the config, the job outcomes, then the steps in the order they chain; processTechs is the tick.
local installer = {}

-- Config ------------------------------------------------------------------------------------------


-- Seconds the completed or failed screen holds before the tech goes back to idle.
local FINISHED_STATE_SECONDS = 3
-- Baseline run length when the job has neither a base nor a target time.
local DEFAULT_BASELINE_EVENT_SECONDS = 60
-- Experience a tech earns for a finished job before the skill multiplier.
local BASE_XP_PER_JOB = 10
-- Share of the net job result the shop keeps back from the payout.
local PAYOUT_SHARE = 0.95

-- Job outcomes ------------------------------------------------------------------------------------


-- Ends a job for its tech: removes its car and leaderboard row, then records the outcome.
local function closeOutJob(deps, businessId, job, outcome, details)
  local shopParts = deps.runtimeState.shopParts
  shopParts.settlement.removeJobVehicle(businessId, job.jobId)
  shopParts.proof.jobCompletion.clearLeaderboardEntry(businessId, job.jobId)
  shopParts.settlement.moveJobToCompleted(businessId, job.jobId, outcome, details)
end

local function finalizeTechJobSuccess(deps, businessId, tech, job)
  local shopParts = deps.runtimeState.shopParts
  if not job then
    deps.parts.techs.resetTechToIdle(tech)
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
  local payout = math.max(0, math.floor(net * PAYOUT_SHARE))

  -- Build and tune spending was advanced before work began; only the net
  -- result takes the existing share, and the principal returns at settlement.
  shopParts.settlement.creditBusinessAccount(businessId, payout + totalSpent, "Automation Job Reward",
    string.format("Job #%s automation payout", tostring(job.jobId)))

  local xpReward = math.floor(BASE_XP_PER_JOB * (shopParts.garage.getXPGainMultiplier(businessId) or 1))
  shopParts.persist.addBusinessXP(businessId, xpReward)

  closeOutJob(deps, businessId, job, "completed", {
    result = "success",
    payout = payout,
    net = net,
    totalSpent = totalSpent,
    eventFunds = cappedEventFunds,
    attempts = tech.totalAttempts,
    predictedTime = tech.predictedEventTime
  })

  tech.finishedJobInfo = {
    label = job.raceLabel,
    payout = payout
  }
  tech.successfulJobs = (tech.successfulJobs or 0) + 1
  tech.jobId = nil
  tech.phase = "completed"
  deps.parts.techs.setTechState(tech, deps.TECH_STATE.COMPLETED, "completed", FINISHED_STATE_SECONDS, {
    jobLabel = job.raceLabel
  })
  deps.parts.techs.fireTechJobCompletedNotification(businessId, tech, job)
  deps.parts.techs.notifyTechsUpdated(businessId)
end

local function finalizeTechJobFailure(deps, businessId, tech, job, reason)
  local shopParts = deps.runtimeState.shopParts
  if not job then
    deps.parts.techs.resetTechToIdle(tech)
    return
  end

  job.locked = false
  job.techAssigned = nil

  local totalSpent = tonumber(tech.totalSpent) or 0
  local eventFunds = tonumber(tech.eventFunds) or 0
  local penaltyBase = shopParts.settlement.getAbandonPenalty(businessId, job.jobId) or 0
  local penalty = math.max(0, penaltyBase)

  if penalty > 0 then
    shopParts.settlement.debitBusinessAccount(businessId, penalty, "Automation Failure Penalty",
      string.format("Job #%s failure", tostring(job.jobId)), true)
  end

  closeOutJob(deps, businessId, job, "failed", {
    result = "failed",
    penalty = penalty,
    totalSpent = totalSpent,
    eventFunds = eventFunds,
    attempts = tech.totalAttempts,
    predictedTime = tech.predictedEventTime,
    reason = reason
  })

  tech.finishedJobInfo = {
    label = job.raceLabel,
    penalty = penalty
  }
  tech.failedJobs = (tech.failedJobs or 0) + 1
  tech.jobId = nil
  tech.phase = "failed"
  deps.parts.techs.setTechState(tech, deps.TECH_STATE.FAILED, "failed", FINISHED_STATE_SECONDS, {
    jobLabel = job.raceLabel
  })
  deps.parts.techs.fireTechJobFailedNotification(businessId, tech, job)
  deps.parts.techs.notifyTechsUpdated(businessId)
end

-- Drive and run steps -----------------------------------------------------------------------------

local function determineDriveStateCode(deps, tech)
  local TECH_STATE = deps.TECH_STATE
  if tech.phase == "validation" then
    return TECH_STATE.DRIVE_VALIDATION
  elseif tech.phase == "postUpdate" then
    return TECH_STATE.DRIVE_FINAL
  else
    return TECH_STATE.DRIVE_BASELINE
  end
end

local function commuteSeconds(deps, job)
  local shopParts = deps.runtimeState.shopParts
  return shopParts.settlement.getCommuteSeconds(job) or deps.BASE_COMMUTE_SECONDS
end

local function startCommute(deps, tech, job)
  if not job then
    deps.parts.techs.resetTechToIdle(tech)
    return
  end
  deps.parts.techs.setTechState(tech, determineDriveStateCode(deps, tech), "driveToEvent", commuteSeconds(deps, job), {
    jobId = job.jobId
  })
end

local function startDriveBack(deps, tech, job)
  if not job then
    deps.parts.techs.resetTechToIdle(tech)
    return
  end
  deps.parts.techs.setTechState(tech, deps.TECH_STATE.DRIVE_BACK, "driveBack", commuteSeconds(deps, job), {
    jobId = job.jobId
  })
end

-- One validation attempt: rolls its predicted time and counts it against the retry allowance.
local function startEventRun(deps, businessId, tech, job)
  if not job then
    deps.parts.techs.resetTechToIdle(tech)
    return
  end

  if tech.phase == "baseline" then
    local duration = math.max(1, tonumber(job.baseTime) or tonumber(job.targetTime) or DEFAULT_BASELINE_EVENT_SECONDS)
    deps.parts.techs.setTechState(tech, deps.TECH_STATE.RUN_EVENT, "runEvent", duration, {
      jobId = job.jobId,
      phase = tech.phase
    })
    return
  end

  tech.validationAttempts = (tech.validationAttempts or 0) + 1
  tech.totalAttempts = (tech.totalAttempts or 0) + 1
  tech.predictedEventTime = deps.parts.techs.generateValidationTime(businessId, job, tech.phase == "postUpdate")
  local duration = math.max(1, tech.predictedEventTime)
  deps.parts.techs.setTechState(tech, deps.TECH_STATE.RUN_EVENT, "runEvent", duration, {
    jobId = job.jobId,
    phase = tech.phase
  })
end

local function startCooldownPhase(deps, tech, job)
  if not job then
    deps.parts.techs.resetTechToIdle(tech)
    return
  end
  local duration = tech.cooldownDuration or deps.BASE_COOLDOWN_SECONDS
  deps.parts.techs.setTechState(tech, deps.TECH_STATE.COOLDOWN, "cooldown", duration, {
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

-- True once the tech has used every validation attempt its job allows.
local function attemptsExhausted(tech)
  local attemptsAllowed = tech.maxValidationAttempts or 1
  local attemptsUsed = tech.validationAttempts or 0
  return attemptsUsed >= attemptsAllowed
end

-- Shop work ---------------------------------------------------------------------------------------


-- The shop's build or tune time for this business, scaled by its skill tree.
local function scaledShopSeconds(deps, base, businessId)
  local shopParts = deps.runtimeState.shopParts
  return shopParts.settlement.getBuildTimeSeconds(base, businessId) or base
end

-- Debits a shop step before its timer starts; a refused debit fails the job and returns false.
local function chargeShopStep(deps, businessId, tech, job, cost, label, memo)
  if cost <= 0 then
    return true
  end
  local shopParts = deps.runtimeState.shopParts
  local paid = shopParts.settlement.debitBusinessAccount(businessId, cost, label, string.format(memo, tostring(job.jobId))) or false
  if not paid then
    finalizeTechJobFailure(deps, businessId, tech, job, "paymentFailed")
    return false
  end
  return true
end

local function startBuildPhase(deps, businessId, tech, job)
  local shopParts = deps.runtimeState.shopParts
  if not job then
    deps.parts.techs.resetTechToIdle(tech)
    return
  end

  local buildCost = shopParts.settlement.calculateBuildCost(businessId, job) or 0
  tech.buildCost = buildCost
  tech.totalSpent = buildCost

  if not chargeShopStep(deps, businessId, tech, job, buildCost, "Automation Build Cost", "Job #%s build") then
    return
  end
  deps.parts.techs.setTechState(tech, deps.TECH_STATE.BUILD, "build", scaledShopSeconds(deps, deps.BASE_BUILD_SECONDS, businessId), {
    jobId = job.jobId
  })
end

local function startUpdatePhase(deps, businessId, tech, job)
  if not job then
    deps.parts.techs.resetTechToIdle(tech)
    return
  end

  local updateCost = deps.parts.techs.calculateUpdateCost(tech)
  if updateCost > 0 then
    tech.totalSpent = (tech.totalSpent or 0) + updateCost
  end
  if not chargeShopStep(deps, businessId, tech, job, updateCost, "Automation Tune Update", "Job #%s update") then
    return
  end
  deps.parts.techs.setTechState(tech, deps.TECH_STATE.UPDATE, "update", scaledShopSeconds(deps, deps.BASE_UPDATE_SECONDS, businessId), {
    jobId = job.jobId
  })
end

-- Validation --------------------------------------------------------------------------------------

local function beginValidationCycle(deps, businessId, tech, job, phase)
  local shopParts = deps.runtimeState.shopParts
  tech.phase = phase or "validation"
  tech.validationAttempts = 0
  tech.maxValidationAttempts = 1 + (shopParts.settlement.getEventRetryAllowance(businessId) or 0)
  tech.predictedEventTime = nil
  startCommute(deps, tech, job)
end

local function handleValidationResult(deps, businessId, tech, job)
  if not job then
    deps.parts.techs.resetTechToIdle(tech)
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
    finalizeTechJobSuccess(deps, businessId, tech, job)
    return
  end

  if attemptsExhausted(tech) then
    if tech.phase == "validation" then
      startUpdatePhase(deps, businessId, tech, job)
      return
    end

    finalizeTechJobFailure(deps, businessId, tech, job, "validationFailed")
    return
  end

  deps.parts.techs.resetTechToIdle(tech)
end

-- Transitions -------------------------------------------------------------------------------------


-- A finished run pays the event funds, then the tech either drives back or runs again.
local function finishEventRun(deps, businessId, tech, job)
  local shopParts = deps.runtimeState.shopParts
  local predictedTime = tech.predictedEventTime
  if tech.phase == "baseline" then
    predictedTime = job.baseTime or job.targetTime or 0
  end
  local actualPayment = shopParts.settlement.calculateActualEventPayment(businessId, job, predictedTime) or 0
  tech.eventFunds = (tech.eventFunds or 0) + actualPayment

  if tech.phase == "baseline" then
    startDriveBack(deps, tech, job)
    return
  end

  local success = validationSucceeded(tech, job)
  tech.latestResult = {
    predictedTime = tech.predictedEventTime,
    targetTime = job.targetTime,
    success = success
  }
  if success or attemptsExhausted(tech) then
    startDriveBack(deps, tech, job)
  else
    startCooldownPhase(deps, tech, job)
  end
end

local function finishCooldown(deps, businessId, tech, job)
  if tech.phase == "baseline" or attemptsExhausted(tech) then
    startDriveBack(deps, tech, job)
  else
    startEventRun(deps, businessId, tech, job)
  end
end

local function finishDriveBack(deps, businessId, tech, job)
  if tech.phase == "baseline" then
    startBuildPhase(deps, businessId, tech, job)
  else
    handleValidationResult(deps, businessId, tech, job)
  end
end

-- Picks the next step from the tech's current action; false when the tech is at rest.
local function advanceTechState(deps, businessId, tech)
  local shopParts = deps.runtimeState.shopParts
  if not tech then
    return false
  end
  if not tech.jobId and tech.currentAction ~= "completed" and tech.currentAction ~= "failed" then
    deps.parts.techs.resetTechToIdle(tech)
    return false
  end

  local job = shopParts.persist.getJobById(businessId, tech.jobId) or nil
  if (not job) and tech.jobId then
    deps.parts.techs.resetTechToIdle(tech)
    return false
  end

  local action = tech.currentAction
  if action == "driveToEvent" then
    startEventRun(deps, businessId, tech, job)
  elseif action == "runEvent" then
    finishEventRun(deps, businessId, tech, job)
  elseif action == "cooldown" then
    finishCooldown(deps, businessId, tech, job)
  elseif action == "driveBack" then
    finishDriveBack(deps, businessId, tech, job)
  elseif action == "build" then
    beginValidationCycle(deps, businessId, tech, job, "validation")
  elseif action == "update" then
    beginValidationCycle(deps, businessId, tech, job, "postUpdate")
  elseif action == "completed" or action == "failed" then
    deps.parts.techs.resetTechToIdle(tech)
    deps.parts.techs.notifyTechsUpdated(businessId)
    return false
  else
    deps.parts.techs.resetTechToIdle(tech)
    return false
  end
  return true
end

-- Tick --------------------------------------------------------------------------------------------


-- Keep leftover simulation time so one tick can finish several technician steps.
local function tickOnce(deps, businessId, tech, timeRemaining)
  local duration = tech.stateDuration or 0
  if duration > 0 then
    local needed = duration - tech.stateElapsed
    if needed > 0 then
      local delta = math.min(needed, timeRemaining)
      tech.stateElapsed = tech.stateElapsed + delta
      timeRemaining = timeRemaining - delta
      if tech.stateElapsed < tech.stateDuration - 1e-6 then
        return timeRemaining, "waiting"
      end
    end
  end
  return timeRemaining, advanceTechState(deps, businessId, tech) and "advanced" or "stopped"
end

-- Runs one tech's steps for dtSim seconds (at most 16 steps). Returns true when any step changed it.
local function processOneTech(deps, businessId, tech, dtSim)
  local timeRemaining = dtSim
  local safety = 0
  local changed = false
  while timeRemaining > 0 and safety < 16 do
    safety = safety + 1
    local beforeState = tech.state
    local beforeAction = tech.currentAction
    local beforePhase = tech.phase

    local outcome
    timeRemaining, outcome = tickOnce(deps, businessId, tech, timeRemaining)
    if outcome == "stopped" then
      break
    end
    if outcome == "advanced" then
      if tech.state == beforeState and tech.currentAction == beforeAction and tech.phase == beforePhase then
        log("W", "tuningShopTechs",
          string.format("Tech #%d stuck in infinite loop (state: %s, action: %s). Breaking.", tech.id,
            tostring(tech.state), tostring(tech.currentAction)))
        break
      end
      changed = true
    end
  end
  return changed
end

local function processTechs(deps, businessId, dtSim)
  if not businessId or dtSim <= 0 then
    return
  end

  local anyChanged = false
  for _, tech in ipairs(deps.parts.techs.loadBusinessTechs(businessId)) do
    if tech.currentAction ~= "idle" and processOneTech(deps, businessId, tech, dtSim) then
      anyChanged = true
    end
  end

  if anyChanged then
    deps.parts.techs.notifyTechsUpdated(businessId)
  end
end

-- Bind each install separately so cached helper code never retains another career's state.
function installer.new(inputs)
  return {
    processTechs = function(businessId, dtSim)
      return processTechs(inputs, businessId, dtSim)
    end,
    startBuildPhase = function(businessId, tech, job)
      return startBuildPhase(inputs, businessId, tech, job)
    end,
  }
end

return installer
