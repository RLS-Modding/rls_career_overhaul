local M = {}

local freConfig = require('gameplay/fre/config')

local function getCurrentVehicleModel(vehId)
  return gameplay_events_freContracts_vehiclePool.getCurrentVehicleModel(vehId)
end

local function getSponsorBonusesForDiscipline(disciplineId)
  local state = gameplay_events_freContracts_state.getState()
  local cap = tonumber((freConfig.getRewardScaling() or {}).sponsorBonusCap) or 2.0
  local dState = state.disciplines[disciplineId]
  if not dState then
    return { money = 0, xp = 0 }
  end

  local moneyBonus = 0
  local xpBonus = 0
  for _, sponsor in ipairs(dState.sponsors.active or {}) do
    local bonus = tonumber(sponsor.bonusPercent) or 0
    local bonusType = sponsor.bonusType
    if bonusType == "money" then
      moneyBonus = moneyBonus + bonus
    elseif bonusType == "disciplineXP" then
      xpBonus = xpBonus + bonus
    elseif bonusType == "both" then
      moneyBonus = moneyBonus + bonus
      xpBonus = xpBonus + bonus
    end
  end
  moneyBonus = math.min(cap, math.max(0, moneyBonus))
  xpBonus = math.min(cap, math.max(0, xpBonus))
  return { money = moneyBonus, xp = xpBonus }
end

local function calculateRewardModifiers(disciplineIds)
  local skills = gameplay_events_freContracts_skills
  local scaling = freConfig.getRewardScaling() or {}
  local levelPct = tonumber(scaling.levelPercentPerLevelUp) or 0.1
  local maxLevel = math.floor(tonumber(scaling.maxLevel) or 50)
  if maxLevel < 1 then
    maxLevel = 50
  end
  local result = {
    moneyMultiplier = 1.0,
    disciplineMultipliers = {}
  }

  if type(disciplineIds) ~= "table" or #disciplineIds == 0 then
    return result
  end

  local moneyTotal = 0
  local moneyCount = 0
  local seen = {}
  for _, rawDisciplineId in ipairs(disciplineIds) do
    local disciplineId = freConfig.getDisciplineIdFromType(rawDisciplineId) or rawDisciplineId
    if disciplineId and not seen[disciplineId] then
      seen[disciplineId] = true
      local level = skills.getSkillLevel(disciplineId)
      local effectiveLevel = math.max(1, math.min(level, maxLevel))
      local levelUps = math.max(0, effectiveLevel - 1)
      local skillMultiplier = 1.0 + levelUps * levelPct
      local sponsorBonus = getSponsorBonusesForDiscipline(disciplineId)
      local xpMultiplier = skillMultiplier * (1 + sponsorBonus.xp)
      local moneyMultiplier = skillMultiplier * (1 + sponsorBonus.money)

      result.disciplineMultipliers[disciplineId] = {
        level = level,
        effectiveLevel = effectiveLevel,
        levelBonus = levelUps * levelPct,
        skillMultiplier = skillMultiplier,
        sponsorMoneyBonus = sponsorBonus.money,
        sponsorXpBonus = sponsorBonus.xp,
        xpMultiplier = xpMultiplier,
        moneyMultiplier = moneyMultiplier
      }
      moneyTotal = moneyTotal + moneyMultiplier
      moneyCount = moneyCount + 1
    end
  end

  if moneyCount > 0 then
    result.moneyMultiplier = moneyTotal / moneyCount
  end
  return result
end

local function calculateContractAwardXp(contract, disciplineId)
  local tier = (type(contract) == "table" and contract.tier) or "easy"
  local contractCfg = freConfig.getContractConfig(disciplineId) or {}
  local curveCfg = ((contractCfg.xpByTier or {})[tier]) or {}
  local normalized = tonumber(contract and contract.bestPerformanceRatio) or 0
  if normalized <= 0 then
    normalized = 1.0
  end
  return gameplay_events_freContracts_skills.calculateXpFromTierCurve(curveCfg, normalized)
end

local function awardContract(contract, disciplineId)
  if not gameplay_events_freContracts_state.isCareerActive() then
    return
  end
  if not career_modules_payment or not career_modules_payment.reward then
    return
  end
  local skillKey = freConfig.getSkillKey(disciplineId)
  if not skillKey then
    return
  end

  local vPool = gameplay_events_freContracts_vehiclePool
  local money = tonumber(contract.rewardMoney) or 0
  local xp = calculateContractAwardXp(contract, disciplineId)
  local requiredModel = contract.requiredModel
  local requiredModelLabel = contract.requiredModelLabel or vPool.getModelDisplayName(requiredModel)
  local disciplineLabel = ((freConfig.getDisciplineById(disciplineId) or {}).label) or disciplineId
  local raceLabel = contract.raceLabel or contract.raceName or disciplineId
  local moneyRounded = math.floor(money + 0.5)
  local objectiveType = contract.objectiveType == "laps" and "laps" or "events"
  local requiredCount = math.max(1, math.floor(tonumber(contract.requiredCount) or 1))

  local rewardData = {
    money = { amount = money, canBeNegative = false }
  }
  rewardData[skillKey] = { amount = xp }
  career_modules_payment.reward(rewardData, {
    label = string.format("FRE Contract Complete: %s", raceLabel),
    tags = {"gameplay", "reward", "fre", "contract"}
  }, true)

  if guihooks and guihooks.trigger then
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
        rewardMoney = moneyRounded,
        rewardXp = xp
      }
    })
  end
end

local function processSponsorQualification(dState, raceName, finishTime, isAltRoute, now)
  local rCache = gameplay_events_freContracts_raceCache
  local changed = false
  for _, sponsor in ipairs(dState.sponsors.active or {}) do
    local requiredRaceName = sponsor.requiredRaceName
    local targetTime = tonumber(sponsor.targetTime)
    local routeOk = rCache.routeTypeMatches(sponsor.requiredRaceRouteType, isAltRoute)
    local raceOk = type(requiredRaceName) == "string" and requiredRaceName ~= "" and raceName == requiredRaceName and routeOk
    local timeOk = type(targetTime) == "number" and finishTime <= targetTime
    if raceOk and timeOk then
      sponsor.warningIssued = false
      sponsor.warningIssuedAt = nil
      sponsor.lastQualifiedAt = now
      sponsor.lastQualifiedRaceName = raceName
      sponsor.lastQualifiedRaceRouteType = isAltRoute and "alt" or "main"
      sponsor.lastQualifiedTime = finishTime
      sponsor.nextCheckAt = now + (tonumber(sponsor.upkeepMinutes) or 120)
      changed = true
    end
  end
  return changed
end

local function processContractProgress(dState, disciplineId, raceName, finishTime, lapCount, isAltRoute, vehicleModel, now)
  local rCache = gameplay_events_freContracts_raceCache
  local vPool = gameplay_events_freContracts_vehiclePool
  local skills = gameplay_events_freContracts_skills
  local changed = false

  for i = #dState.contracts.active, 1, -1 do
    local contract = dState.contracts.active[i]
    local routeOk = rCache.routeTypeMatches(contract.raceRouteType, isAltRoute)
    local raceOk = (contract.raceName == raceName) and routeOk
    local modelOk = vPool.modelFamilyMatches(contract.requiredModel, vehicleModel)
    local timeOk = finishTime <= (tonumber(contract.targetTime) or math.huge)
    local notExpired = now <= (tonumber(contract.expiresAt) or 0)

    if raceOk and modelOk and timeOk and notExpired then
      local performanceRatio = skills.normalizePerformanceRatioFromTargetTime(contract.targetTime, finishTime)
      if performanceRatio > (tonumber(contract.bestPerformanceRatio) or 0) then
        contract.bestPerformanceRatio = performanceRatio
        changed = true
      end
      local objectiveType = contract.objectiveType == "laps" and "laps" or "events"
      local requiredCount = math.max(1, math.floor(tonumber(contract.requiredCount) or 1))
      local objectiveComplete = false

      if objectiveType == "laps" then
        objectiveComplete = lapCount >= requiredCount
      else
        local before = tonumber(contract.progress) or 0
        contract.progress = math.min(requiredCount, (tonumber(contract.progress) or 0) + 1)
        if contract.progress ~= before then
          changed = true
        end
        objectiveComplete = contract.progress >= requiredCount
      end

      if objectiveComplete then
        awardContract(contract, disciplineId)
        dState.contracts.completed = dState.contracts.completed + 1
        table.remove(dState.contracts.active, i)
        changed = true
      end
    end
  end
  return changed
end

local function onFreeroamRaceCompleted(payload)
  if type(payload) ~= "table" then
    return
  end

  local state = gameplay_events_freContracts_state.getState()
  local now = tonumber(state.simTime) or 0
  local raceName = payload.raceName
  local finishTime = tonumber(payload.finishTime) or math.huge
  local lapCount = math.max(0, math.floor(tonumber(payload.lapCount) or 0))
  local invalidLap = payload.invalidLap == true
  local isAltRoute = payload.isAltRoute == true
  local vehicleModel = string.lower(payload.vehicleModel or getCurrentVehicleModel(payload.vehicleId) or "")
  local disciplineIds = payload.disciplineIds or {}

  if type(disciplineIds) ~= "table" then
    return
  end

  local stateChanged = false
  local seen = {}
  for _, rawDisciplineId in ipairs(disciplineIds) do
    local disciplineId = freConfig.getDisciplineIdFromType(rawDisciplineId) or rawDisciplineId
    if disciplineId and not seen[disciplineId] then
      seen[disciplineId] = true
      local dState = state.disciplines[disciplineId]
      if dState then
        if not invalidLap and processSponsorQualification(dState, raceName, finishTime, isAltRoute, now) then
          stateChanged = true
        end
        if not invalidLap and processContractProgress(dState, disciplineId, raceName, finishTime, lapCount, isAltRoute, vehicleModel, now) then
          stateChanged = true
        end
      end
    end
  end

  if stateChanged then
    gameplay_events_freContracts_state.refreshMaintenanceSchedule(now)
    gameplay_events_freContracts_ui.emitUiStateUpdate("race_result_applied")
  end
end

M.getCurrentVehicleModel = getCurrentVehicleModel
M.getSponsorBonusesForDiscipline = getSponsorBonusesForDiscipline
M.calculateRewardModifiers = calculateRewardModifiers
M.onFreeroamRaceCompleted = onFreeroamRaceCompleted

return M
