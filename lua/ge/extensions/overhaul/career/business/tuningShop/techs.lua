-- Tuning shop technicians: hiring and firing, tech slots, job assignment and the per-tech state machine.
-- Read the config and the runtime install, then the sections in order; the M exports sit at the bottom.
local capabilities = require("overhaul/lib/platform/capabilities")
local businessSaveState = require("overhaul/lib/business/saveState")
local M = {}
local phoneLayout = require("overhaul/lib/phone/layoutOwner")

-- Config ------------------------------------------------------------------------------------------


-- Base durations in simulated seconds; the runtime scales them with the skill-tree helpers.
local BASE_BUILD_SECONDS = 900
local BASE_UPDATE_SECONDS = 300
local BASE_COOLDOWN_SECONDS = 150
local BASE_COMMUTE_SECONDS = 120
-- Active jobs one shop runs at once when the skill-tree helper does not answer.
local DEFAULT_MAX_ACTIVE_JOBS = 2
-- Job outcome notices stay on screen this many seconds.
local OUTCOME_TOAST_SECONDS = 8
-- Validation runs finish between these fractions of the job's target time (1.0 is exactly on target).
local PERFECT_TECH_MIN_RATIO = 0.975
local PERFECT_TECH_MAX_RATIO = 0.999
local STANDARD_MIN_RATIO = 0.9875
local STANDARD_MAX_RATIO = 1.0375
local MASTER_BUILD_MAX_RATIO = 1.07083
local UPDATE_MAX_RATIO_WITHOUT_MASTER = 1.023214
-- Each 25% of reliable-tech reduction lowers the ceiling by 0.025, and the ceiling never drops below 1.0125.
local RELIABLE_REDUCTION_UNIT = 0.25
local RELIABLE_REDUCTION_RATIO_STEP = 0.025
local RELIABLE_REDUCTION_MIN_MAX_RATIO = 1.0125
-- An update costs a quarter of the build price, rounded down to whole money.
local UPDATE_COST_SHARE_OF_BUILD = 0.25

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
  idle = function()
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

-- State -------------------------------------------------------------------------------------------

-- Runtime state belongs to this facade load, shared by the installed helpers.
local runtime = {
  businessTechs = {},
  shopParts = {},
}

-- Shared helpers ----------------------------------------------------------------------------------

local function initialize(shopParts)
  runtime.shopParts = shopParts
end

local function normalizeBusinessId(businessId)
  return runtime.shopParts.garage.normalizeBusinessId(businessId) or (tonumber(businessId) or businessId)
end

-- Parts -------------------------------------------------------------------------------------------


-- The runtime part shares this load's tech helpers and keeps reload state isolated.
local parts = {techs = {}}
parts.runtime = require("overhaul/career/business/tuningShop/techsParts/runtime").new({
  runtimeState = runtime,
  parts = parts,
  BASE_BUILD_SECONDS = BASE_BUILD_SECONDS,
  BASE_UPDATE_SECONDS = BASE_UPDATE_SECONDS,
  BASE_COOLDOWN_SECONDS = BASE_COOLDOWN_SECONDS,
  BASE_COMMUTE_SECONDS = BASE_COMMUTE_SECONDS,
  TECH_STATE = TECH_STATE,
})

-- Tech slots --------------------------------------------------------------------------------------

local function getTechCapacity(businessId)
  local techsHired = 0
  local level = runtime.shopParts.garage.getSkillTreeLevel(businessId, "automation", "shop-techs") or 0
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
  tech.cooldownDuration = tech.cooldownDuration or BASE_COOLDOWN_SECONDS
  tech.successfulJobs = tech.successfulJobs or 0
  tech.failedJobs = tech.failedJobs or 0
  tech.fired = tech.fired or false
end

-- Adds empty techs up to the skill-tree capacity; fired techs keep their slot.
local function ensureTechSlots(businessId)
  if not businessId then
    return
  end
  local capacity = math.max(0, getTechCapacity(businessId))

  local techs = runtime.businessTechs[businessId] or {}

  for _, tech in ipairs(techs) do
    ensureTechIdentity(tech, tech.id)
  end

  local totalCount = #techs
  local maxId = 0
  for _, tech in ipairs(techs) do
    if tech.id and tech.id > maxId then
      maxId = tech.id
    end
  end

  local nextId = maxId + 1

  while totalCount < capacity do
    local newTech = {
      id = nextId,
      name = string.format("Tech #%d", nextId),
      state = 0,
      stateElapsed = 0,
      stateDuration = 0,
      jobId = nil,
      retriesUsed = 0,
      totalAttempts = 0,
      fundsHeld = 0,
      buildCost = 0,
      eventFunds = 0,
      fired = false
    }
    ensureTechIdentity(newTech, nextId)
    table.insert(techs, newTech)
    totalCount = totalCount + 1
    nextId = nextId + 1
  end

  runtime.businessTechs[businessId] = techs
  return techs
end

-- Saved tech file ---------------------------------------------------------------------------------

local function getBusinessTechsPath(businessId)
  if not overhaul_career_career.isActive() then
    return nil
  end
  local _, currentSavePath = overhaul_career_saveSystem.getCurrentProfile()
  if not currentSavePath then
    return nil
  end
  return businessSaveState.businessFilePath(businessId .. "", "techs.json", currentSavePath .. "")
end

function parts.techs.loadBusinessTechs(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return {}
  end

  if runtime.businessTechs[businessId] then
    ensureTechSlots(businessId)
    return runtime.businessTechs[businessId]
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

  runtime.businessTechs[businessId] = techs
  ensureTechSlots(businessId)
  return runtime.businessTechs[businessId]
end

local function saveBusinessTechs(businessId, currentSavePath, writer)
  businessId = normalizeBusinessId(businessId)
  if not businessId or not runtime.businessTechs[businessId] then
    return
  end
  if not currentSavePath then
    return
  end

  local filePath = businessSaveState.businessFilePath(businessId .. "", "techs.json", currentSavePath .. "")
  writer = writer or overhaul_career_saveSystem.getSaveWriter()
  local dirPath = string.match(filePath, "^(.*)/[^/]+$")
  if dirPath and not writer.exists(dirPath) then
    writer.mkdir(dirPath)
  end

  local data = {
    techs = runtime.businessTechs[businessId]
  }

  overhaul_career_saveSystem.jsonWriteFileSafe(filePath, data, true)
end

-- Technician transitions -------------------------------------------------------------------------


-- Every state change goes through parts.techs.setTechState, so the timer and action always move together.
function parts.techs.setTechState(tech, stateCode, action, duration, meta)
  tech.state = stateCode or TECH_STATE.IDLE
  tech.currentAction = action or "idle"
  tech.stateDuration = math.max(0, duration or 0)
  tech.stateElapsed = 0
  tech.stateMeta = meta or {}
end

function parts.techs.resetTechToIdle(tech)
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
  tech.jobVehicle = nil
  parts.techs.setTechState(tech, TECH_STATE.IDLE, "idle", 0, {})
end

-- Reconciliation ----------------------------------------------------------------------------------

local function indexActiveJobs(jobs)
  local activeJobsById = {}
  for _, job in ipairs(jobs.active or {}) do
    local jobId = tonumber(job.jobId) or job.jobId
    if jobId ~= nil then
      activeJobsById[jobId] = job
    end
  end
  return activeJobsById
end

-- Clears techs that point at a job which ended, or at a tech that was fired.
local function resetOrphanTechs(techs, activeJobsById)
  local techsChanged = false
  for _, tech in ipairs(techs) do
    if tech.jobId then
      local jobId = tonumber(tech.jobId) or tech.jobId
      local job = activeJobsById[jobId]
      if tech.fired or not job then
        parts.techs.resetTechToIdle(tech)
        techsChanged = true
      end
    end
  end
  return techsChanged
end

-- Groups the hired techs by the active job they are working on.
local function collectClaimants(techs, activeJobsById)
  local claimantsByJobId = {}
  for _, tech in ipairs(techs) do
    if not tech.fired and tech.jobId then
      local jobId = tonumber(tech.jobId) or tech.jobId
      if activeJobsById[jobId] then
        claimantsByJobId[jobId] = claimantsByJobId[jobId] or {}
        table.insert(claimantsByJobId[jobId], tech)
      end
    end
  end
  return claimantsByJobId
end

-- Two techs on one job both go idle and the job is unlocked; returns jobsChanged and techsChanged.
local function resolveContestedJobs(claimantsByJobId, activeJobsById)
  local jobsChanged = false
  local techsChanged = false
  for jobId, claimants in pairs(claimantsByJobId) do
    if #claimants > 1 then
      for _, tech in ipairs(claimants) do
        parts.techs.resetTechToIdle(tech)
      end

      local job = activeJobsById[jobId]
      if job then
        if job.techAssigned ~= nil then
          job.techAssigned = nil
          jobsChanged = true
        end
        if job.locked then
          job.locked = false
          jobsChanged = true
        end
      end

      claimantsByJobId[jobId] = nil
      techsChanged = true
    end
  end
  return jobsChanged, techsChanged
end

-- Each active job points at its single claimant, or at nobody; returns jobsChanged.
local function syncJobClaims(jobs, claimantsByJobId)
  local jobsChanged = false
  for _, job in ipairs(jobs.active or {}) do
    local jobId = tonumber(job.jobId) or job.jobId
    local claimants = claimantsByJobId[jobId]

    if claimants and #claimants == 1 then
      local claimant = claimants[1]
      if job.techAssigned ~= claimant.id then
        job.techAssigned = claimant.id
        jobsChanged = true
      end
      if not job.locked then
        job.locked = true
        jobsChanged = true
      end
    else
      if job.techAssigned ~= nil then
        job.techAssigned = nil
        jobsChanged = true
      end
      if job.locked then
        job.locked = false
        jobsChanged = true
      end
    end
  end
  return jobsChanged
end

-- Techs whose job no longer names them go idle; returns techsChanged.
local function resetUnclaimedTechs(techs, activeJobsById)
  local techsChanged = false
  for _, tech in ipairs(techs) do
    if not tech.fired and tech.jobId then
      local jobId = tonumber(tech.jobId) or tech.jobId
      local job = activeJobsById[jobId]
      if not job or job.techAssigned ~= tech.id then
        parts.techs.resetTechToIdle(tech)
        techsChanged = true
      end
    end
  end
  return techsChanged
end

local function reconcileAssignments(businessId, jobs)
  businessId = normalizeBusinessId(businessId)
  if not businessId or not jobs or not jobs.active then
    return {
      jobsChanged = false,
      techsChanged = false
    }
  end

  local techs = parts.techs.loadBusinessTechs(businessId)
  local activeJobsById = indexActiveJobs(jobs)
  local orphansChanged = resetOrphanTechs(techs, activeJobsById)
  local claimantsByJobId = collectClaimants(techs, activeJobsById)
  local contestedJobsChanged, contestedTechsChanged = resolveContestedJobs(claimantsByJobId, activeJobsById)
  local claimsChanged = syncJobClaims(jobs, claimantsByJobId)
  local unclaimedChanged = resetUnclaimedTechs(techs, activeJobsById)

  return {
    jobsChanged = contestedJobsChanged or claimsChanged,
    techsChanged = orphansChanged or contestedTechsChanged or unclaimedChanged
  }
end

-- Index of the first job in list whose id matches jobId, or nil.
local function indexOfJob(list, jobId)
  for index, entry in ipairs(list or {}) do
    if (tonumber(entry.jobId) or entry.jobId) == jobId then
      return index
    end
  end
  return nil
end

-- UI and notices ----------------------------------------------------------------------------------

local function getTechDisplayLabel(action, job)
  local fn = TECH_ACTION_LABELS[action]
  if fn then
    return fn(job)
  end
  return "Working"
end

local function getTechMaxTier(businessId)
  local baseTier = 1
  local skilledTechsLevel = runtime.shopParts.garage.getSkillTreeLevel(businessId, "automation", "skilled-techs") or 0
  return baseTier + skilledTechsLevel
end

-- Progress of the tech's current step: elapsed and total seconds, and the fraction done.
local function techTimer(tech)
  local totalSeconds = math.max(0, tonumber(tech.stateDuration) or 0)
  local elapsedSeconds = math.max(0, tonumber(tech.stateElapsed) or 0)
  local progress = 0
  if totalSeconds > 0 then
    progress = math.min(1, math.max(0, elapsedSeconds / totalSeconds))
  end
  return {elapsedSeconds = elapsedSeconds, totalSeconds = totalSeconds, progress = progress}
end

-- Finished-job counts and the success rate as a whole percent.
local function techRecord(tech)
  local successfulJobs = tech.successfulJobs or 0
  local failedJobs = tech.failedJobs or 0
  local totalJobs = successfulJobs + failedJobs
  local successRate = 0
  if totalJobs > 0 then
    successRate = math.floor((successfulJobs / totalJobs) * 100 + 0.5)
  end
  return {successfulJobs = successfulJobs, failedJobs = failedJobs, successRate = successRate}
end

local function formatTechForUIEntry(businessId, tech)
  if not tech then
    return nil
  end

  local job = nil
  if tech.jobId then
    job = runtime.shopParts.persist.getJobById(businessId, tech.jobId) or nil
  end

  local label = getTechDisplayLabel(tech.currentAction, job)
  local timer = techTimer(tech)
  local record = techRecord(tech)

  local jobLabel = nil
  if job and job.raceLabel then
    jobLabel = job.raceLabel
  elseif tech.finishedJobInfo and tech.finishedJobInfo.label then
    jobLabel = tech.finishedJobInfo.label
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
    progress = timer.progress,
    elapsedSeconds = timer.elapsedSeconds,
    totalSeconds = timer.totalSeconds,
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
    canAssign = not tech.fired and not tech.jobId and (tech.currentAction == "idle"),
    fundsHeld = tech.fundsHeld,
    successRate = record.successRate,
    successfulJobs = record.successfulJobs,
    failedJobs = record.failedJobs,
    maxTier = getTechMaxTier(businessId),
    fired = tech.fired or false
  }
end

function parts.techs.notifyTechsUpdated(businessId)
  if not businessId then
    return
  end

  local techEntries = {}
  local techList = parts.techs.loadBusinessTechs(businessId)
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

-- Job vehicles ------------------------------------------------------------------------------------

local function getJobVehicleRow(businessId, jobId)
  local inventory = overhaul_career_business_fleet
  for _, vehicle in ipairs(inventory.getBusinessVehicles(businessId) or {}) do
    if (tonumber(vehicle.jobId) or vehicle.jobId) == jobId then
      return vehicle
    end
  end
  return nil
end

-- Puts the car the tech took back into the fleet in place of the stock car rebuilt for the job.
local function restoreJobVehicle(businessId, job, jobVehicle)
  local inventory = overhaul_career_business_fleet
  if not jobVehicle then
    return false
  end
  if getJobVehicleRow(businessId, job.jobId) then
    runtime.shopParts.settlement.removeJobVehicle(businessId, job.jobId)
  end
  local row = deepcopy(jobVehicle)
  row.vehicleId = nil
  row.jobId = job.jobId
  local stored, vehicleId = inventory.storeVehicle(businessId, row)
  if not stored then
    return false
  end
  job.storedVehicleId = vehicleId
  runtime.shopParts.proof.jobCompletion.clearLeaderboardEntry(businessId, job.jobId, vehicleId)
  return true
end

-- Validation and pricing --------------------------------------------------------------------------


-- Ceiling on the validation ratio: master techs build tighter, updates loosen it, reliable techs tighten it.
local function validationMaxRatio(businessId, updateTune)
  local maxRatio = STANDARD_MAX_RATIO
  local hasMasterTechs = runtime.shopParts.settlement.hasMasterTechs(businessId) or false

  if hasMasterTechs and not updateTune then
    maxRatio = MASTER_BUILD_MAX_RATIO
  elseif not hasMasterTechs and updateTune then
    maxRatio = UPDATE_MAX_RATIO_WITHOUT_MASTER
  end

  local reliableFailureReduction = runtime.shopParts.settlement.getReliableFailureReduction(businessId) or 0
  if reliableFailureReduction > 0 then
    local reductionUnits = reliableFailureReduction / RELIABLE_REDUCTION_UNIT
    maxRatio = math.max(RELIABLE_REDUCTION_MIN_MAX_RATIO, maxRatio - (RELIABLE_REDUCTION_RATIO_STEP * reductionUnits))
  end
  return maxRatio
end

-- The simulated run time of one validation attempt, as a ratio of the job's target time.
function parts.techs.generateValidationTime(businessId, job, updateTune)
  if not job then
    return 0
  end
  local target = tonumber(job.targetTime) or 0
  if target <= 0 then
    return math.max(1, target)
  end

  if runtime.shopParts.settlement.hasPerfectTechs(businessId) then
    local ratio = PERFECT_TECH_MIN_RATIO + math.random() * (PERFECT_TECH_MAX_RATIO - PERFECT_TECH_MIN_RATIO)
    return target * ratio
  end

  local maxRatio = validationMaxRatio(businessId, updateTune)
  local ratio = STANDARD_MIN_RATIO + math.random() * (maxRatio - STANDARD_MIN_RATIO)
  return target * ratio
end

function parts.techs.calculateUpdateCost(tech)
  local buildCost = tonumber(tech and tech.buildCost) or 0
  if buildCost <= 0 then
    return 0
  end
  return math.floor(buildCost * UPDATE_COST_SHARE_OF_BUILD)
end

-- Job outcome notices -----------------------------------------------------------------------------

local function isShopAppUnlocked(businessId)
  return overhaul_career_business_tuningShop_tuningShop.isShopAppUnlocked(businessId)
end

local function getWorkerName(tech)
  ensureTechName(tech, tech and tech.id)
  return tech.name or string.format("Tech #%s", tostring(tech and tech.id or ""))
end

-- Sends a phone notice, or a toast when the phone layout is missing; each job outcome is sent once.
local function fireTechJobOutcomeNotification(businessId, tech, jobLabel, succeeded)
  if not tech or not businessId then
    return false
  end
  if tech.jobOutcomePhoneNotifySent then
    return false
  end
  if not isShopAppUnlocked(businessId) then
    return false
  end

  local channelKey = succeeded and "tuningShop.jobCompleted" or "tuningShop.jobFailed"
  local workerName = getWorkerName(tech)
  local jobMeta = jobLabel or (tech.finishedJobInfo and tech.finishedJobInfo.label) or ""
  local layout = phoneLayout.get()

  if layout and layout.fireNotification then
    layout.fireNotification(channelKey, {
      title = succeeded and "Job Complete" or "Job Failed",
      message = string.format("%s %s their job", workerName, succeeded and "completed" or "failed"),
      meta = jobMeta,
      kind = succeeded and "info" or "warning",
      ttl = OUTCOME_TOAST_SECONDS,
      source = "Tuning Shop",
      sound = { soundClass = "AudioGui", type = "event:>UI>Missions>Info_Open" },
    })
    tech.jobOutcomePhoneNotifySent = true
    return true
  else
    ui_message(
      string.format("%s %s their job: %s.", workerName, succeeded and "completed" or "failed", jobMeta),
      OUTCOME_TOAST_SECONDS, "Tuning Shop", succeeded and "info" or "warning")
    tech.jobOutcomePhoneNotifySent = true
    return true
  end
end

function parts.techs.fireTechJobCompletedNotification(businessId, tech, job)
  return fireTechJobOutcomeNotification(businessId, tech, job and job.raceLabel, true)
end

function parts.techs.fireTechJobFailedNotification(businessId, tech, job)
  return fireTechJobOutcomeNotification(businessId, tech, job and job.raceLabel, false)
end

-- Queries -----------------------------------------------------------------------------------------

local function getTechById(businessId, techId)
  if not businessId or not techId then
    return nil
  end
  local techs = parts.techs.loadBusinessTechs(businessId)
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
    parts.techs.notifyTechsUpdated(businessId)
    return true
  end

  return false
end

-- Copies of the techs, so the UI cannot edit the live list.
local function getTechsForBusiness(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return {}
  end

  local techs = parts.techs.loadBusinessTechs(businessId)
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

  local techs = parts.techs.loadBusinessTechs(businessId)
  for _, tech in ipairs(techs) do
    local tJobId = tonumber(tech.jobId) or tech.jobId
    if tJobId == jobId then
      return true
    end
  end
  return false
end

local function getWorkingTechsCount(businessId)
  local techs = parts.techs.loadBusinessTechs(businessId)
  local count = 0
  for _, tech in ipairs(techs) do
    if tech.jobId then
      count = count + 1
    end
  end
  return count
end

local function getIdleTechs(businessId)
  local techs = parts.techs.loadBusinessTechs(businessId)
  local idleTechs = {}
  for _, tech in ipairs(techs) do
    if not tech.fired and not tech.jobId and (tech.currentAction == "idle" or not tech.currentAction) then
      table.insert(idleTechs, tech)
    end
  end
  return idleTechs
end

-- Lifts are the shop's limit on cars pulled out at once; each working tech holds one.
local function canAssignTechToJob(businessId)
  local liftsAvailable = 1
  liftsAvailable = runtime.shopParts.generation.getMaxPulledOutVehicles(businessId) or 1

  local workingTechs = getWorkingTechsCount(businessId)
  return workingTechs < liftsAvailable
end

-- Assignment --------------------------------------------------------------------------------------


-- The job's id matches a live active job; returns the job or nil.
local function findActiveJob(businessId, jobId)
  local jobs = runtime.shopParts.persist.loadBusinessJobs(businessId)
  local index = indexOfJob(jobs.active, jobId)
  return index and jobs.active[index] or nil
end

-- Returns the refusal reason for a tech that cannot take a job, or nil.
local function techRefusal(tech)
  if tech.fired then
    return "techFired"
  end
  if tech.jobId then
    return "techBusy"
  end
  return nil
end

-- Returns the refusal reason for a job that cannot take this tech, or nil.
local function jobRefusal(businessId, job, techId)
  if not job then
    return "jobNotActive"
  end
  if job.techAssigned and job.techAssigned ~= techId then
    return "jobLocked"
  end
  if (tonumber(job.tier) or 1) > getTechMaxTier(businessId) then
    return "tierTooHigh"
  end
  if not canAssignTechToJob(businessId) then
    return "noLiftAvailable"
  end
  return nil
end

-- Clears the fleet caches for the job's car, then takes the car off the fleet for the tech.
local function attachJobVehicle(businessId, tech, jobId)
  local vehicleId = overhaul_career_business_fleet.getInventoryVehicleIdForJobId(businessId, jobId)
  if vehicleId ~= nil then
    local computer = capabilities.peek("businessComputer")
    if computer then computer.clearBusinessCachesForVehicle(businessId, vehicleId) end
  end

  tech.jobVehicle = getJobVehicleRow(businessId, jobId)
  runtime.shopParts.settlement.removeJobVehicle(businessId, jobId)
end

-- Master techs go straight to the build; everyone else drives to the event first.
local function startAssignedWork(businessId, tech, job, jobId)
  local hasMasterTechs = runtime.shopParts.settlement.hasMasterTechs(businessId) or false

  if hasMasterTechs then
    tech.phase = "build"
    parts.runtime.startBuildPhase(businessId, tech, job)
  else
    tech.phase = "baseline"
    local commuteSeconds = runtime.shopParts.settlement.getCommuteSeconds(job) or BASE_COMMUTE_SECONDS
    parts.techs.setTechState(tech, TECH_STATE.DRIVE_BASELINE, "driveToEvent", commuteSeconds, {
      jobId = jobId,
      phase = "baseline"
    })
  end
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

  local refusal = techRefusal(tech)
  if refusal then
    return false, refusal
  end

  local job = findActiveJob(businessId, jobId)
  refusal = jobRefusal(businessId, job, techId)
  if refusal then
    return false, refusal
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

  attachJobVehicle(businessId, tech, jobId)
  startAssignedWork(businessId, tech, job, jobId)

  parts.techs.notifyTechsUpdated(businessId)
  runtime.shopParts.views.notifyJobsUpdated(businessId)
  return true
end

local function fireTech(businessId, techId)
  businessId = normalizeBusinessId(businessId)
  techId = tonumber(techId)
  if not businessId or not techId then
    return false, "invalidParameters"
  end

  local tech = getTechById(businessId, techId)
  if not tech then
    return false, "techNotFound"
  end

  if tech.fired then
    return false, "alreadyFired"
  end

  if tech.jobId then
    return false, "techHasJob"
  end

  tech.fired = true
  parts.techs.notifyTechsUpdated(businessId)
  runtime.shopParts.views.notifyJobsUpdated(businessId)
  return true
end

local function hireTech(businessId, techId)
  businessId = normalizeBusinessId(businessId)
  techId = tonumber(techId)
  if not businessId or not techId then
    return false, "invalidParameters"
  end

  local tech = getTechById(businessId, techId)
  if not tech then
    return false, "techNotFound"
  end

  if not tech.fired then
    return false, "alreadyHired"
  end

  local capacity = getTechCapacity(businessId)
  local hiredCount = 0
  local techs = parts.techs.loadBusinessTechs(businessId)
  for _, t in ipairs(techs) do
    if not t.fired then
      hiredCount = hiredCount + 1
    end
  end

  if hiredCount >= capacity then
    return false, "capacityFull"
  end

  tech.fired = false
  ensureTechSlots(businessId)
  parts.techs.notifyTechsUpdated(businessId)
  return true
end

-- Puts a stopped job back on the active list when there is room, else drops it from the queues.
local function returnStoppedJob(businessId, jobs, jobId, job, jobVehicle)
  local maxActiveJobs = runtime.shopParts.settlement.getMaxActiveJobs(businessId) or DEFAULT_MAX_ACTIVE_JOBS
  local currentActiveCount = #(jobs.active or {})

  if currentActiveCount < maxActiveJobs then
    if not jobs.active then
      jobs.active = {}
    end
    table.insert(jobs.active, job)
    restoreJobVehicle(businessId, job, jobVehicle)
    return
  end

  runtime.shopParts.settlement.removeJobVehicle(businessId, jobId)
  runtime.shopParts.proof.jobCompletion.clearLeaderboardEntry(businessId, jobId)

  local activeIndex = indexOfJob(jobs.active, jobId)
  if activeIndex then
    table.remove(jobs.active, activeIndex)
  end
  local newIndex = indexOfJob(jobs.new, jobId)
  if newIndex then
    table.remove(jobs.new, newIndex)
  end
end

-- Keeps the job on the active list after its tech stops; restores the car it had.
local function reinstateStoppedJob(businessId, jobId, job, jobVehicle)
  local jobs = runtime.shopParts.persist.loadBusinessJobs(businessId)
  if indexOfJob(jobs.active, jobId) then
    restoreJobVehicle(businessId, job, jobVehicle)
  else
    returnStoppedJob(businessId, jobs, jobId, job, jobVehicle)
  end
end

local function stopTechFromJob(businessId, techId)
  businessId = normalizeBusinessId(businessId)
  techId = tonumber(techId)
  if not businessId or not techId then
    return false, "invalidParameters"
  end

  local tech = getTechById(businessId, techId)
  if not tech then
    return false, "techNotFound"
  end

  if tech.fired then
    return false, "techFired"
  end

  if not tech.jobId then
    return false, "noJobAssigned"
  end

  local jobId = tech.jobId
  local job = runtime.shopParts.persist.getJobById(businessId, jobId) or nil
  if not job then
    parts.techs.resetTechToIdle(tech)
    parts.techs.notifyTechsUpdated(businessId)
    return false, "jobNotFound"
  end

  local spent = math.floor(tonumber(tech.totalSpent) or 0)
  local jobVehicle = tech.jobVehicle
  parts.techs.resetTechToIdle(tech)
  job.locked = false
  job.techAssigned = nil

  -- the tech's build is discarded, so the build and tune money goes back to the shop
  if spent > 0 then
    runtime.shopParts.settlement.creditBusinessAccount(businessId, spent, "Automation Build Refund",
      string.format("Job #%s tech stopped", tostring(jobId)))
  end

  reinstateStoppedJob(businessId, jobId, job, jobVehicle)

  parts.techs.notifyTechsUpdated(businessId)
  runtime.shopParts.views.notifyJobsUpdated(businessId)

  return true
end

-- Lifecycle ---------------------------------------------------------------------------------------

local function resetTechs()
  runtime.businessTechs = {}
end

local function clearBusinessTechs(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId then return false end
  runtime.businessTechs[businessId] = {}
  return true
end

-- Re-sends the outcome notice for finished techs once the tuning shop app is installed.
local function notifyOnPhoneAppInstalled()
  if not overhaul_career_career.isActive() then
    return
  end

  local purchased = overhaul_career_business_manager.getPurchasedBusinesses("tuningShop")
  if not purchased then
    return
  end

  for bid, owned in pairs(purchased) do
    if owned then
      local businessId = normalizeBusinessId(bid)
      if isShopAppUnlocked(businessId) then
        local techs = parts.techs.loadBusinessTechs(businessId)
        for _, tech in ipairs(techs) do
          local action = tech.currentAction
          if tech.finishedJobInfo and (action == "completed" or action == "failed") then
            if tech.jobOutcomePhoneNotifySent then
              tech.jobOutcomePhoneNotifySent = false
            end
            fireTechJobOutcomeNotification(businessId, tech, tech.finishedJobInfo.label, action == "completed")
          end
        end
      end
    end
  end
end

-- Public API ---------------------------------------------------------------------------------------

M.initialize = initialize
M.processTechs = parts.runtime.processTechs
M.saveBusinessTechs = saveBusinessTechs
M.loadBusinessTechs = parts.techs.loadBusinessTechs
M.getTechById = getTechById
M.updateTechName = updateTechName
M.getTechsForBusiness = getTechsForBusiness
M.isJobLockedByTech = isJobLockedByTech
M.assignJobToTech = assignJobToTech
M.formatTechForUIEntry = formatTechForUIEntry
M.notifyTechsUpdated = parts.techs.notifyTechsUpdated
M.reconcileAssignments = reconcileAssignments
M.resetTechs = resetTechs
M.clearBusinessTechs = clearBusinessTechs
M.getIdleTechs = getIdleTechs
M.getTechMaxTier = getTechMaxTier
M.canAssignTechToJob = canAssignTechToJob
M.fireTech = fireTech
M.hireTech = hireTech
M.stopTechFromJob = stopTechFromJob
M.notifyOnPhoneAppInstalled = notifyOnPhoneAppInstalled


return M
