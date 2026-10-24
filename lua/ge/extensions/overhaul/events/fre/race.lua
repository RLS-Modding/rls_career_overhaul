-- Applies finished freeroam races to sponsor upkeep and contract progress, and prices the reward modifiers.
-- Other event files ask for reward multipliers; the race session reports results through onFreeroamRaceCompleted.
local recordRace = require("overhaul/lib/progression/logbookFeed").register("overhaul.raceCompleted", {
  title = "Event completed", label = "Events", icon = "flag"
}, "events/fre/race.lua")

local M = {}

local freConfig = require("overhaul/events/freConfig")

-- Sponsors ----------------------------------------------------------------------------------------

function M.getCurrentVehicleModel(vehId)
  return overhaul_events_fre_vehiclePool.getCurrentVehicleModel(vehId)
end

function M.getSponsorBonusesForDiscipline(disciplineId)
  local state = overhaul_events_fre_state.getState()
  local cap = tonumber((freConfig.getRewardScaling() or {}).sponsorBonusCap) or 2.0
  local disciplineState = state.disciplines[disciplineId]
  if not disciplineState then return { money = 0, xp = 0 } end
  local moneyBonus = 0
  local xpBonus = 0
  for _, sponsor in ipairs(disciplineState.sponsors.active or {}) do
    if sponsor.probation ~= true then
      local bonus = tonumber(sponsor.bonusPercent) or 0
      local bonusType = sponsor.bonusType
      if bonusType == "money" or bonusType == "both" then moneyBonus = moneyBonus + bonus end
      if bonusType == "disciplineXP" or bonusType == "both" then xpBonus = xpBonus + bonus end
    end
  end
  return { money = math.min(cap, math.max(0, moneyBonus)), xp = math.min(cap, math.max(0, xpBonus)) }
end

-- Reward modifiers --------------------------------------------------------------------------------

function M.getLaneLevelBonus(disciplineId, level)
  local discipline = freConfig.getDisciplineById(disciplineId)
  if not discipline or discipline.legacyOnly == true then return 0 end
  local parent = freConfig.getParentSkill(discipline.parentSkillId)
  local lanes = parent and parent.laneIds or {}
  local laneIndex = nil
  for i, laneId in ipairs(lanes) do
    if laneId == disciplineId then
      laneIndex = i
      break
    end
  end
  if not laneIndex or #lanes == 0 then return 0 end
  local effectiveLevel = math.max(1, math.min(50, math.floor(tonumber(level) or 1)))
  local bonus = 0
  local perOccurrence = 0.04 * #lanes
  for unlockedLevel = 2, math.min(49, effectiveLevel) do
    if ((unlockedLevel - 2) % #lanes) + 1 == laneIndex then bonus = bonus + perOccurrence end
  end
  if effectiveLevel >= 50 then
    bonus = bonus + (tonumber((freConfig.getRewardScaling() or {}).level50TopOff) or 0.08)
  end
  return math.min(tonumber((freConfig.getRewardScaling() or {}).normalLaneMaxBonus) or 2, bonus)
end

-- Helpers -----------------------------------------------------------------------------------------

local function disciplineRewardModifiers(disciplineId, maxLevel)
  local level = overhaul_events_fre_skills.getSkillLevel(disciplineId)
  local effectiveLevel = math.max(1, math.min(level, maxLevel))
  local levelBonus = M.getLaneLevelBonus(disciplineId, effectiveLevel)
  local skillMultiplier = 1.0 + levelBonus
  local sponsorBonus = M.getSponsorBonusesForDiscipline(disciplineId)
  return {
    level = level,
    effectiveLevel = effectiveLevel,
    levelBonus = levelBonus,
    skillMultiplier = skillMultiplier,
    sponsorMoneyBonus = sponsorBonus.money,
    sponsorXpBonus = sponsorBonus.xp,
    xpMultiplier = 1 + sponsorBonus.xp,
    moneyMultiplier = skillMultiplier * (1 + sponsorBonus.money),
  }
end

function M.calculateRewardModifiers(disciplineIds)
  local maxLevel = math.floor(tonumber((freConfig.getRewardScaling() or {}).maxLevel) or 50)
  if maxLevel < 1 then maxLevel = 50 end
  local result = { moneyMultiplier = 1.0, disciplineMultipliers = {} }
  if type(disciplineIds) ~= "table" or #disciplineIds == 0 then return result end

  local moneyTotal = 0
  local moneyCount = 0
  local seen = {}
  for _, rawDisciplineId in ipairs(disciplineIds) do
    local disciplineId = freConfig.getDisciplineIdFromType(rawDisciplineId) or rawDisciplineId
    if disciplineId and not seen[disciplineId] then
      seen[disciplineId] = true
      local modifiers = disciplineRewardModifiers(disciplineId, maxLevel)
      result.disciplineMultipliers[disciplineId] = modifiers
      moneyTotal = moneyTotal + modifiers.moneyMultiplier
      moneyCount = moneyCount + 1
    end
  end
  if moneyCount > 0 then result.moneyMultiplier = moneyTotal / moneyCount end
  return result
end

-- Targets -----------------------------------------------------------------------------------------

local function fraction(value)
  return math.max(0, math.min(1, value))
end

local function normalizeTargetType(targetType)
  if targetType == "driftScore" or targetType == "maxDamagePct" or targetType == "pullDistance" then
    return targetType
  end
  return "time"
end

-- `target` is a sponsor or contract; `outcome` is the finished race from buildRaceOutcome.
local function isTargetSatisfied(target, targetType, outcome)
  if targetType == "driftScore" then
    local targetScore = tonumber(target.targetDriftScore)
    if not targetScore or targetScore <= 0 then return false end
    return outcome.driftScore >= targetScore
  elseif targetType == "maxDamagePct" then
    local targetDamage = tonumber(target.targetDamagePctMax)
    if type(targetDamage) ~= "number" then return false end
    return fraction(outcome.damagePercentage) <= fraction(targetDamage)
  elseif targetType == "pullDistance" then
    local targetDistance = tonumber(target.targetDistanceMeters)
    if not targetDistance or targetDistance <= 0 then return false end
    local requiredSledId = target.requiredSledId
    local sledMatches = type(requiredSledId) ~= "string" or requiredSledId == "" or requiredSledId == outcome.sledId
    return sledMatches and outcome.distanceMeters >= targetDistance
  end
  local requiredTime = tonumber(target.targetTime)
  return type(requiredTime) == "number" and outcome.finishTime <= requiredTime
end

local function performanceRatio(target, targetType, outcome)
  if targetType == "driftScore" then
    local targetScore = tonumber(target.targetDriftScore)
    if not targetScore or targetScore <= 0 then return 0 end
    return math.max(0, outcome.driftScore / targetScore)
  elseif targetType == "maxDamagePct" then
    local targetDamage = tonumber(target.targetDamagePctMax)
    if type(targetDamage) ~= "number" then return 0 end
    targetDamage = fraction(targetDamage)
    local actualDamage = fraction(outcome.damagePercentage)
    local denominator = 1 - targetDamage
    if denominator <= 0 then return actualDamage <= targetDamage and 1 or 0 end
    return math.max(0, (1 - actualDamage) / denominator)
  elseif targetType == "pullDistance" then
    local targetDistance = tonumber(target.targetDistanceMeters)
    if not targetDistance or targetDistance <= 0 then return 0 end
    return math.max(0, outcome.distanceMeters / targetDistance)
  end
  return overhaul_events_fre_skills.normalizePerformanceRatioFromTargetTime(target.targetTime, outcome.finishTime)
end

-- Contract rewards --------------------------------------------------------------------------------

local function contractMoney(contract)
  return tonumber(contract.rewardMoney) or tonumber(contract.rewardMoneyBase) or 0
end

local function calculateContractAwardXp(contract, disciplineId)
  local contractConfig = freConfig.getContractConfig(disciplineId) or {}
  local money = contractMoney(contract)
  local percentOfMoney = tonumber(contractConfig.xpPercentOfMoney) or 0.5
  if money > 0 and percentOfMoney > 0 then return math.max(0, math.floor(money * percentOfMoney + 0.5)) end
  local tier = contract.tier or "easy"
  local curveConfig = (contractConfig.xpByTier or {})[tier] or {}
  local normalized = tonumber(contract.bestPerformanceRatio) or 0
  if normalized <= 0 then normalized = 1.0 end
  return overhaul_events_fre_skills.calculateXpFromTierCurve(curveConfig, normalized)
end

local function awardContract(contract, disciplineId)
  if not overhaul_events_fre_state.isCareerActive() then return false end
  local skillKey = freConfig.getSkillKey(disciplineId)
  if not skillKey then return false end

  local money = contractMoney(contract)
  local xp = tonumber(contract.rewardXp) or calculateContractAwardXp(contract, disciplineId)
  local requiredModel = contract.requiredModel
  local requiredModelLabel = contract.requiredModelLabel
    or overhaul_events_fre_vehiclePool.getModelDisplayName(requiredModel)
  local disciplineLabel = (freConfig.getDisciplineById(disciplineId) or {}).label or disciplineId
  local raceLabel = contract.raceLabel or contract.raceName or disciplineId
  local objectiveType = contract.objectiveType == "laps" and "laps" or "events"
  local requiredCount = math.max(1, math.floor(tonumber(contract.requiredCount) or 1))

  -- Edited contract data may carry a negative reward; it still posts as one signed wallet call.
  local paid = overhaul_career_economy_payment.payout(require("overhaul/lib/finance/metadata").tagPayout({
    amount = money,
    allowNetDebit = true,
    xp = { [skillKey] = xp },
    label = string.format("FRE Contract Complete: %s", raceLabel),
    tags = { "gameplay", "reward", "fre", "contract" },
    reason = { canBeNegative = false },
    fullReward = true,
  }, "activity:freContract", {vehicleRole = "player"}))
  if paid ~= true then return false end

  guihooks.trigger("OpenFreContractCelebration", {
    entry = {
      disciplineId = disciplineId,
      disciplineLabel = disciplineLabel,
      tier = contract.tier or "easy",
      raceName = contract.raceName,
      raceLabel = raceLabel,
      requiredModel = requiredModel,
      requiredModelLabel = requiredModelLabel,
      objectiveType = objectiveType,
      requiredCount = requiredCount,
      rewardMoney = math.floor(money + 0.5),
      rewardXp = math.floor(xp + 0.5),
    },
  })
  return true
end

-- Applying a finished race --------------------------------------------------------------------------

local function markSponsorQualified(sponsor, outcome, now)
  sponsor.probation = false
  sponsor.warningIssued = false
  sponsor.warningIssuedAt = nil
  sponsor.lastQualifiedAt = now
  sponsor.lastQualifiedRaceName = outcome.raceName
  sponsor.lastQualifiedRaceRouteType = outcome.isAltRoute and "alt" or "main"
  sponsor.lastQualifiedTime = outcome.finishTime
  sponsor.lastQualifiedDriftScore = outcome.driftScore
  sponsor.lastQualifiedDamagePct = fraction(outcome.damagePercentage)
  sponsor.lastQualifiedDistanceMeters = outcome.distanceMeters
  sponsor.lastQualifiedSledId = outcome.sledId
  sponsor.nextCheckAt = now + (tonumber(sponsor.upkeepMinutes) or 120)
end

local function processSponsorQualification(disciplineState, outcome, now)
  local raceCache = overhaul_events_fre_raceCache
  local changed = false
  for _, sponsor in ipairs(disciplineState.sponsors.active or {}) do
    local requiredRaceName = sponsor.requiredRaceName
    local routeOk = raceCache.routeTypeMatches(sponsor.requiredRaceRouteType, outcome.isAltRoute)
    local raceOk = type(requiredRaceName) == "string"
      and requiredRaceName ~= ""
      and outcome.raceName == requiredRaceName
      and routeOk
    local targetOk = isTargetSatisfied(sponsor, normalizeTargetType(sponsor.targetType), outcome)
    if raceOk and targetOk then
      markSponsorQualified(sponsor, outcome, now)
      changed = true
    end
  end
  return changed
end

-- Counts one qualifying run; returns whether anything changed and whether the objective is complete.
local function recordContractRun(contract, targetType, outcome)
  local changed = false
  local ratio = performanceRatio(contract, targetType, outcome)
  if ratio > (tonumber(contract.bestPerformanceRatio) or 0) then
    contract.bestPerformanceRatio = ratio
    changed = true
  end
  local requiredCount = math.max(1, math.floor(tonumber(contract.requiredCount) or 1))
  local before = tonumber(contract.progress) or 0
  contract.progress = math.min(requiredCount, before + 1)
  if contract.progress ~= before then changed = true end
  return changed, contract.progress >= requiredCount
end

local function contractMatchesRun(contract, targetType, outcome, now)
  local routeOk = overhaul_events_fre_raceCache.routeTypeMatches(contract.raceRouteType, outcome.isAltRoute)
  local raceOk = (contract.raceName == outcome.raceName) and routeOk
  local modelOk = overhaul_events_fre_vehiclePool.modelFamilyMatches(contract.requiredModel, outcome.vehicleModel)
  local targetOk = isTargetSatisfied(contract, targetType, outcome)
  local notExpired = now <= (tonumber(contract.expiresAt) or 0)
  return raceOk and modelOk and targetOk and notExpired
end

local function processContractProgress(disciplineState, disciplineId, outcome, now)
  local changed = false
  for i = #disciplineState.contracts.active, 1, -1 do
    local contract = disciplineState.contracts.active[i]
    local targetType = normalizeTargetType(contract.targetType)
    if contractMatchesRun(contract, targetType, outcome, now) then
      local runChanged, objectiveComplete = recordContractRun(contract, targetType, outcome)
      if runChanged then changed = true end
      if objectiveComplete and awardContract(contract, disciplineId) then
        disciplineState.contracts.completed = disciplineState.contracts.completed + 1
        table.remove(disciplineState.contracts.active, i)
        changed = true
      end
    end
  end
  return changed
end

local function buildRaceOutcome(payload)
  local resultMetrics = type(payload.resultMetrics) == "table" and payload.resultMetrics or {}
  return {
    raceName = payload.raceName,
    finishTime = tonumber(payload.finishTime) or math.huge,
    driftScore = tonumber(resultMetrics.driftScore or payload.driftScore) or 0,
    damagePercentage = fraction(tonumber(resultMetrics.damagePercentage or payload.damagePercentage) or 0),
    distanceMeters = tonumber(resultMetrics.distanceMeters or payload.distanceMeters) or 0,
    sledId = resultMetrics.sledId or payload.sledId,
    isAltRoute = payload.isAltRoute == true,
    vehicleModel = string.lower(payload.vehicleModel or M.getCurrentVehicleModel(payload.vehicleId) or ""),
  }
end

-- Public API: race results ------------------------------------------------------------------------

function M.onFreeroamRaceCompleted(payload)
  if type(payload) ~= "table" then return end
  local metrics = type(payload.resultMetrics) == "table" and payload.resultMetrics or {}
  local result = metrics.placement and ("Place " .. tostring(metrics.placement))
    or (payload.invalidLap and "Invalid result")
    or (payload.finishTime and string.format("%.2f s", payload.finishTime)) or "Finished"
  if not payload.skipHistory then recordRace({name = payload.raceLabel or payload.raceName or "Event",
    facts = {{label = "Event", value = payload.raceLabel or payload.raceName},
      {label = "Result", value = result},
      {label = "Prize account", value = payload.businessReward and "Business" or "Personal"}},
    money = payload.historyPrize, receipt = payload.resultId}) end
  local state = overhaul_events_fre_state.getState()
  local now = tonumber(state.simTime) or 0
  local outcome = buildRaceOutcome(payload)
  local disciplineIds = payload.disciplineIds or {}
  if type(disciplineIds) ~= "table" or payload.skipFreContractProgress == true then return end

  local invalidLap = payload.invalidLap == true
  local stateChanged = false
  local seen = {}
  for _, rawDisciplineId in ipairs(disciplineIds) do
    local disciplineId = freConfig.getDisciplineIdFromType(rawDisciplineId) or rawDisciplineId
    if disciplineId and not seen[disciplineId] then
      seen[disciplineId] = true
      local disciplineState = state.disciplines[disciplineId]
      if disciplineState and not invalidLap then
        if processSponsorQualification(disciplineState, outcome, now) then stateChanged = true end
        if processContractProgress(disciplineState, disciplineId, outcome, now) then stateChanged = true end
      end
    end
  end
  if stateChanged then
    overhaul_events_fre_state.refreshMaintenanceSchedule(now)
    overhaul_events_fre_ui.emitUiStateUpdate("race_result_applied")
  end
end

return M
