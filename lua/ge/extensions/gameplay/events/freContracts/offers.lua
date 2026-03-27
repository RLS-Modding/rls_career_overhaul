local M = {}

local freConfig = require('gameplay/fre/config')

local sponsorNamePrefixes = {"Torque", "Summit", "Grid", "Rustline", "Blacktop", "Apex", "Ridge", "Mudline",
                             "Trackside", "Overdrive"}
local sponsorNameSuffixes = {"Motors", "Performance", "Motorsport", "Industries", "Dynamics", "Works", "Racing",
                             "Garage", "Labs", "Partners"}

local function randomSponsorName()
  local pickRandom = gameplay_events_freContracts_helpers.pickRandomFromList
  local prefix = pickRandom(sponsorNamePrefixes) or "Apex"
  local suffix = pickRandom(sponsorNameSuffixes) or "Performance"
  return prefix .. " " .. suffix
end

local function readRaceRow(levelId, raceName, routeType)
  if type(levelId) ~= "string" or levelId == "" or type(raceName) ~= "string" or raceName == "" then
    return nil
  end
  local data = jsonReadFile("levels/" .. levelId .. "/race_data.json")
  if type(data) ~= "table" then return nil end
  local race = (data.races or {})[raceName]
  if type(race) ~= "table" then return nil end
  local rt = type(routeType) == "string" and string.lower(routeType) or "main"
  if rt == "alt" and type(race.altRoute) == "table" then
    local ar = race.altRoute
    return {
      bestTime = tonumber(ar.bestTime) or tonumber(race.bestTime),
      reward = tonumber(ar.reward) or tonumber(race.reward),
      driftGoal = tonumber(ar.driftGoal) or tonumber(race.driftGoal),
      damageFactor = tonumber(ar.damageFactor) or tonumber(race.damageFactor) or 0,
      type = race.type
    }
  end
  return {
    bestTime = tonumber(race.bestTime),
    reward = tonumber(race.reward),
    driftGoal = tonumber(race.driftGoal),
    damageFactor = tonumber(race.damageFactor) or 0,
    type = race.type
  }
end

local function computeBaseMoneyAtTarget(targetData, raceRow)
  if not raceRow or not raceRow.bestTime or not raceRow.reward then return nil end
  local u = gameplay_events_freeroam_utils
  if not u then return nil end
  local tt = targetData and targetData.targetType or "time"
  if tt == "driftScore" then
    local driftGoal = raceRow.driftGoal
    local targetScore = targetData.targetDriftScore
    if not driftGoal or driftGoal <= 0 or not targetScore or targetScore <= 0 then return nil end
    if u.driftReward then
      return u.driftReward(raceRow, raceRow.bestTime, targetScore)
    end
    return nil
  end
  if tt == "maxDamagePct" then
    local df = raceRow.damageFactor or 0
    local dmgPct = targetData.targetDamagePctMax or 0
    if df > 0 and u.hybridRaceReward then
      return u.hybridRaceReward(raceRow.bestTime, raceRow.reward, raceRow.bestTime, df, dmgPct, raceRow.type)
    end
    if u.raceReward then
      return u.raceReward(raceRow.bestTime, raceRow.reward, raceRow.bestTime, raceRow.type)
    end
    return nil
  end
  local targetTime = targetData and targetData.targetTime or raceRow.bestTime
  if not targetTime or targetTime <= 0 then return nil end
  if u.raceReward then
    return u.raceReward(raceRow.bestTime, raceRow.reward, targetTime, raceRow.type)
  end
  return nil
end

local function contractRaceUsesTimeTarget(disciplineId, raceEntry)
  local id = type(disciplineId) == "string" and string.lower(disciplineId) or ""
  if id == "drift" and (tonumber(raceEntry and raceEntry.driftGoal) or 0) > 0 then
    return false
  end
  if id == "crawling" or id == "trail" then
    return false
  end
  return true
end

local function buildContractTargetFromPlayerPb(tier, pbSeconds, contractCfg, helpers)
  local defaults = {
    easy = {min = 1.025, max = 1.1},
    medium = {min = 0.975, max = 1.025},
    hard = {min = 0.925, max = 0.975}
  }
  local cfgTbl = type(contractCfg) == "table" and contractCfg.contractPbTimeMultipliersByTier or nil
  local tbl = type(cfgTbl) == "table" and cfgTbl[tier] or nil
  if type(tbl) ~= "table" then
    tbl = defaults[tier] or defaults.easy
  end
  local multMin = tonumber(tbl.min)
  local multMax = tonumber(tbl.max)
  local d = defaults[tier] or defaults.easy
  if multMin == nil or multMax == nil then
    multMin, multMax = d.min, d.max
  end
  if multMax < multMin then
    multMin, multMax = multMax, multMin
  end
  local mult = helpers.randomFloat(multMin, multMax)
  local targetTime = helpers.roundTo(pbSeconds * mult, 3)
  return {
    targetType = "time",
    targetTime = targetTime,
    targetLabel = helpers.formatTimeForRequirement(targetTime)
  }
end

local function isDisciplineCountOverride(disciplineId, targetType, contractCfg)
  local overrideList = contractCfg.disciplinesUsingEventCountOverride
  if type(overrideList) == "table" then
    local id = string.lower(tostring(disciplineId or ""))
    for _, v in ipairs(overrideList) do
      if string.lower(tostring(v)) == id then return true end
    end
  end
  return targetType == "maxDamagePct"
end

local function pickContractObjective(disciplineId, tier, raceEntry, targetData, contractCfg)
  local helpers = gameplay_events_freContracts_helpers
  local cfg = contractCfg or freConfig.getContractConfig(disciplineId) or {}
  local tt = targetData and targetData.targetType or "time"

  if isDisciplineCountOverride(disciplineId, tt, cfg) then
    local overrideTbl = (cfg.eventCountOverrideByTier or {})[tier] or {}
    local eMin = math.max(1, math.floor(tonumber(overrideTbl.eventsMin) or 2))
    local eMax = math.max(eMin, math.floor(tonumber(overrideTbl.eventsMax) or eMin))
    return "events", helpers.randomInt(eMin, eMax), nil
  end

  local isLoopable = raceEntry and raceEntry.isLapEvent == true
  local objectiveType = isLoopable and "laps" or "events"

  local perUnitSec
  if tt == "driftScore" then
    perUnitSec = raceEntry and tonumber(raceEntry.bestTime)
  else
    perUnitSec = targetData and tonumber(targetData.targetTime)
    if not perUnitSec or perUnitSec <= 0 then
      perUnitSec = raceEntry and tonumber(raceEntry.bestTime)
    end
  end
  if not perUnitSec or perUnitSec <= 0 then
    return objectiveType, 1, nil
  end

  local effectiveSecPerUnit = perUnitSec
  if not isLoopable then
    local mult = tonumber(cfg.nonLoopEventTimeMultiplier) or 1.66
    local driveBackSec = math.max(60, mult * perUnitSec)
    effectiveSecPerUnit = perUnitSec + driveBackSec
  end

  local windowTbl = (cfg.timeWindowMinutesByTier or {})[tier] or {}
  local winMin = (tonumber(windowTbl.min) or 3) * 60
  local winMax = (tonumber(windowTbl.max) or 9) * 60

  local minCount = math.max(1, math.ceil(winMin / effectiveSecPerUnit))
  local maxCount = math.max(1, math.floor(winMax / effectiveSecPerUnit))
  if minCount > maxCount then
    return nil, nil, nil
  end
  local count = helpers.randomInt(minCount, maxCount)
  local impliedTotalSec = count * effectiveSecPerUnit
  return objectiveType, count, impliedTotalSec
end

local function contractBasePayoutMultiplier(contractCfg, tier)
  local t = type(tier) == "string" and string.lower(tier) or "easy"
  local byTier = contractCfg and contractCfg.basePayoutMultiplierByTier
  if type(byTier) == "table" then
    local m = tonumber(byTier[t])
    if m and m > 0 then
      return m
    end
  end
  local legacy = contractCfg and tonumber(contractCfg.basePayoutMultiplier)
  if legacy and legacy > 0 then
    return legacy
  end
  return 10
end

local function scaleContractRewardPreview(disciplineId, baseMoney, baseXp)
  local money = math.max(0, math.floor(tonumber(baseMoney) or 0))
  local xp = math.max(0, math.floor(tonumber(baseXp) or 0))
  local skillKey = freConfig.getSkillKey(disciplineId)
  if not skillKey then
    return money, xp
  end
  if not (career_modules_difficultyMode and career_modules_difficultyMode.scalePaymentRewardData) then
    return money, xp
  end

  local rewardData = {
    money = { amount = money, canBeNegative = false },
    [skillKey] = { amount = xp }
  }

  local scaledMoney = math.max(0, math.floor((rewardData.money and rewardData.money.amount or money) + 0.5))
  local scaledXp = math.max(0, math.floor((rewardData[skillKey] and rewardData[skillKey].amount or xp) + 0.5))
  return scaledMoney, scaledXp
end

local function isValidTargetType(targetType)
  return targetType == "time" or targetType == "driftScore" or targetType == "maxDamagePct"
end

local function applyTargetData(entry, targetData)
  if type(entry) ~= "table" then
    return
  end
  local data = type(targetData) == "table" and targetData or {}
  entry.targetType = isValidTargetType(data.targetType) and data.targetType or "time"
  entry.targetTime = tonumber(data.targetTime)
  entry.targetDriftScore = tonumber(data.targetDriftScore)
  entry.targetDamagePctMax = tonumber(data.targetDamagePctMax)
end

local function hasValidTargetForEntry(entry)
  local targetType = entry and entry.targetType or "time"
  if targetType == "driftScore" then
    return type(entry.targetDriftScore) == "number" and entry.targetDriftScore > 0
  end
  if targetType == "maxDamagePct" then
    return type(entry.targetDamagePctMax) == "number" and entry.targetDamagePctMax >= 0 and entry.targetDamagePctMax <= 1
  end
  return type(entry.targetTime) == "number" and entry.targetTime > 0
end

local function normalizeContractEntry(disciplineId, entry)
  if type(entry) ~= "table" then
    return
  end
  local rCache = gameplay_events_freContracts_raceCache
  local vPool = gameplay_events_freContracts_vehiclePool

  if not entry.requiredModel and entry.requiredModelFamily then
    entry.requiredModel = entry.requiredModelFamily
  end

  local objectiveType = entry.objectiveType
  if objectiveType ~= "laps" and objectiveType ~= "events" then
    objectiveType = "events"
  end
  entry.objectiveType = objectiveType
  entry.requiredCount = math.max(1, math.floor(tonumber(entry.requiredCount) or 1))
  entry.progress = math.max(0, math.floor(tonumber(entry.progress) or 0))
  entry.bestPerformanceRatio = math.max(0, tonumber(entry.bestPerformanceRatio) or 0)
  local normalizedMoney = tonumber(entry.rewardMoney)
  local normalizedXp = tonumber(entry.rewardXp)
  entry.rewardMoney = math.max(0, math.floor(normalizedMoney or 0))
  entry.rewardXp = math.max(0, math.floor(normalizedXp or 0))
  entry.targetTime = tonumber(entry.targetTime)
  entry.targetDriftScore = tonumber(entry.targetDriftScore)
  entry.targetDamagePctMax = tonumber(entry.targetDamagePctMax)
  entry.raceRouteType = rCache.normalizeRaceRouteType(entry.raceRouteType) or
                          rCache.inferRouteTypeFromRaceLabel(disciplineId, entry.raceName, entry.raceLabel)
  local targetType = isValidTargetType(entry.targetType) and entry.targetType or nil
  entry.targetType = targetType
  local raceEntry = rCache.findRaceEntry(disciplineId, entry.raceName, entry.raceRouteType, entry.raceLabel)

  if not targetType then
    local contractCfg = freConfig.getContractConfig(disciplineId) or {}
    local inferredTarget = raceEntry and rCache.buildTargetForTier(disciplineId, entry.tier or "easy", raceEntry, contractCfg, nil, {
      min = 1.0,
      max = 1.1
    }, "contract") or nil
    if inferredTarget and inferredTarget.targetType ~= "time" then
      applyTargetData(entry, inferredTarget)
    else
      entry.targetType = "time"
    end
  end

  if not hasValidTargetForEntry(entry) then
    local fallbackTarget = nil
    local contractCfg = freConfig.getContractConfig(disciplineId) or {}
    if raceEntry then
      fallbackTarget = rCache.buildTargetForTier(disciplineId, entry.tier or "easy", raceEntry, contractCfg, nil, {
        min = 1.0,
        max = 1.1
      }, "contract")
    end
    if not fallbackTarget then
      fallbackTarget = {
        targetType = "time",
        targetTime = tonumber(entry.targetTime) or 60
      }
    end
    applyTargetData(entry, fallbackTarget)
  end

  if (not entry.requiredModelLabel or entry.requiredModelLabel == "") and type(entry.requiredModel) == "string" and entry.requiredModel ~= "" then
    entry.requiredModelLabel = vPool.getModelDisplayName(entry.requiredModel)
  end
end

local function normalizeContractEntryAndDetectChanges(disciplineId, entry)
  if type(entry) ~= "table" then
    return false
  end
  local prevMoney = entry.rewardMoney
  local prevXp = entry.rewardXp
  normalizeContractEntry(disciplineId, entry)
  return prevMoney ~= entry.rewardMoney or prevXp ~= entry.rewardXp
end

local function normalizeSponsorEntry(disciplineId, entry)
  if type(entry) ~= "table" then
    return
  end
  local rCache = gameplay_events_freContracts_raceCache

  entry.upkeepMinutes = math.max(1, tonumber(entry.upkeepMinutes) or 120)
  entry.targetTime = tonumber(entry.targetTime)
  entry.targetDriftScore = tonumber(entry.targetDriftScore)
  entry.targetDamagePctMax = tonumber(entry.targetDamagePctMax)
  entry.targetType = isValidTargetType(entry.targetType) and entry.targetType or nil
  entry.requiredRaceRouteType = rCache.normalizeRaceRouteType(entry.requiredRaceRouteType) or
                                  rCache.inferRouteTypeFromRaceLabel(disciplineId, entry.requiredRaceName, entry.requiredRaceLabel)

  local hasRaceName = type(entry.requiredRaceName) == "string" and entry.requiredRaceName ~= ""
  local raceEntry = hasRaceName and rCache.findRaceEntry(disciplineId, entry.requiredRaceName, entry.requiredRaceRouteType,
      entry.requiredRaceLabel) or nil
  if not entry.targetType then
    local sponsorCfg = freConfig.getSponsorConfig(disciplineId) or {}
    local contractCfg = freConfig.getContractConfig(disciplineId) or {}
    local inferredTarget = raceEntry and rCache.buildTargetForTier(disciplineId, entry.tier or "easy", raceEntry, sponsorCfg,
      contractCfg, {
        min = 1.25,
        max = 1.5
      }, "sponsor") or nil
    if inferredTarget and inferredTarget.targetType ~= "time" then
      applyTargetData(entry, inferredTarget)
    else
      entry.targetType = "time"
    end
  end

  local hasValidTarget = hasValidTargetForEntry(entry)
  if not hasRaceName or not hasValidTarget then
    local requirementData = rCache.buildSponsorRequirement(disciplineId, entry.tier or "easy")
    if requirementData then
      entry.requiredRaceName = requirementData.requiredRaceName
      entry.requiredRaceLabel = requirementData.requiredRaceLabel
      entry.requiredRaceRouteType = requirementData.requiredRaceRouteType
      entry.targetType = requirementData.targetType
      entry.targetTime = requirementData.targetTime
      entry.targetDriftScore = requirementData.targetDriftScore
      entry.targetDamagePctMax = requirementData.targetDamagePctMax
      entry.requirement = requirementData.requirement
    end
  else
    entry.requiredRaceLabel = entry.requiredRaceLabel or entry.requiredRaceName
    if type(entry.requirement) ~= "string" or entry.requirement == "" then
      entry.requirement = rCache.formatRequirementForTarget({
        targetType = entry.targetType,
        targetTime = entry.targetTime,
        targetDriftScore = entry.targetDriftScore,
        targetDamagePctMax = entry.targetDamagePctMax
      }, entry.requiredRaceLabel)
    end
  end
end

local function purgeExpiredEntries(now)
  local state = gameplay_events_freContracts_state.getState()
  local sponsorCfg = freConfig.getSponsorConfig()
  local graceMinutes = tonumber(sponsorCfg.graceMinutes) or 20
  local changed = false

  for _, discipline in ipairs(freConfig.getDisciplines()) do
    local dState = state.disciplines[discipline.id]
    if dState then
      for i = #dState.contracts.available, 1, -1 do
        if (tonumber(dState.contracts.available[i].expiresAt) or 0) <= now then
          table.remove(dState.contracts.available, i)
          changed = true
        end
      end
      for i = #dState.contracts.active, 1, -1 do
        if (tonumber(dState.contracts.active[i].expiresAt) or 0) <= now then
          dState.contracts.failed = dState.contracts.failed + 1
          table.remove(dState.contracts.active, i)
          changed = true
        end
      end

      for i = #dState.sponsors.available, 1, -1 do
        if (tonumber(dState.sponsors.available[i].expiresAt) or 0) <= now then
          table.remove(dState.sponsors.available, i)
          changed = true
        end
      end
      for i = #dState.sponsors.active, 1, -1 do
        local sponsor = dState.sponsors.active[i]
        local nextCheckAt = tonumber(sponsor.nextCheckAt) or 0
        if now > nextCheckAt then
          if not sponsor.warningIssued then
            sponsor.warningIssued = true
            sponsor.warningIssuedAt = now
            sponsor.nextCheckAt = now + graceMinutes
            changed = true
          else
            dState.sponsors.dropped = dState.sponsors.dropped + 1
            table.remove(dState.sponsors.active, i)
            changed = true
          end
        end
      end
    end
  end

  return changed
end

local function generateContractOffer(disciplineId, level, now)
  local helpers = gameplay_events_freContracts_helpers
  local skills = gameplay_events_freContracts_skills
  local rCache = gameplay_events_freContracts_raceCache
  local vPool = gameplay_events_freContracts_vehiclePool
  local contractCfg = freConfig.getContractConfig(disciplineId)
  local unlockedTiers = skills.getUnlockedContractTiers(disciplineId, level)
  if #unlockedTiers == 0 then
    return nil
  end

  local raceData = rCache.refreshRaceCache().byDiscipline[disciplineId] or {}
  if #raceData == 0 then
    return nil
  end

  local tier = unlockedTiers[helpers.randomInt(1, #unlockedTiers)]
  local raceEntry = helpers.pickRandomFromList(raceData)
  if not raceEntry then
    return nil
  end

  local model, modelSource, vehicleRewardMult = vPool.pickContractModel(disciplineId, contractCfg)
  if not model or model == "" then
    return nil
  end

  local targetData
  local pbSeconds = vPool.getBestEventPbTimeSeconds(model, raceEntry)
  if pbSeconds and pbSeconds > 0 and contractRaceUsesTimeTarget(disciplineId, raceEntry) then
    targetData = buildContractTargetFromPlayerPb(tier, pbSeconds, contractCfg, helpers)
  else
    targetData = rCache.buildTargetForTier(disciplineId, tier, raceEntry, contractCfg, nil, {
      min = 1.0,
      max = 1.1
    }, "contract")
  end

  local objectiveType, requiredCount, impliedTotalSec = pickContractObjective(disciplineId, tier, raceEntry, targetData, contractCfg)
  if not objectiveType or not requiredCount then
    return nil
  end

  local levelId = gameplay_events_freContracts_state.getCurrentLevelId() or ""
  local raceRow = readRaceRow(levelId, raceEntry.raceName, raceEntry.routeType)
  local baseMoney = raceRow and computeBaseMoneyAtTarget(targetData, raceRow) or nil
  if not baseMoney or baseMoney <= 0 then
    return nil
  end

  local payoutMult = contractBasePayoutMultiplier(contractCfg, tier)
  local bonusPerUnit = tonumber(contractCfg.extraLapEventBonusPerUnit) or 0.33
  local lapEventMult = math.max(1, requiredCount) * bonusPerUnit
  local varCfg = contractCfg.payoutVariance or {}
  local varMin = tonumber(varCfg.min) or 0.95
  local varMax = tonumber(varCfg.max) or 1.05
  local variance = helpers.randomFloat(varMin, varMax)
  local xpPct = tonumber(contractCfg.xpPercentOfMoney) or 0.5

  local rawMoney = baseMoney * payoutMult * lapEventMult * variance * (tonumber(vehicleRewardMult) or 1)
  local rawXp = rawMoney * xpPct
  local raceMods = gameplay_events_freContracts_race
  if raceMods and raceMods.calculateRewardModifiers then
    local computed = raceMods.calculateRewardModifiers({disciplineId})
    local dm = computed and computed.disciplineMultipliers and computed.disciplineMultipliers[disciplineId] or {}
    local moneyMult = tonumber(dm.moneyMultiplier) or 1
    local xpMult = tonumber(dm.xpMultiplier) or 1
    rawMoney = rawMoney * moneyMult
    rawXp = rawXp * xpMult
  end
  local rewardMoney, rewardXp = scaleContractRewardPreview(disciplineId, rawMoney, rawXp)

  local expiryMinutes = tonumber(contractCfg.offerExpiryMinutes) or 5

  return {
    id = gameplay_events_freContracts_state.nextId("fre-contract"),
    disciplineId = disciplineId,
    tier = tier,
    raceName = raceEntry.raceName,
    raceLabel = raceEntry.raceLabel,
    raceRouteType = raceEntry.routeType,
    targetType = targetData and targetData.targetType or "time",
    targetTime = targetData and targetData.targetTime or nil,
    targetDriftScore = targetData and targetData.targetDriftScore or nil,
    targetDamagePctMax = targetData and targetData.targetDamagePctMax or nil,
    requiredModel = model,
    requiredModelLabel = vPool.getModelDisplayName(model),
    modelSource = modelSource,
    objectiveType = objectiveType,
    requiredCount = requiredCount,
    impliedTotalSec = impliedTotalSec,
    progress = 0,
    bestPerformanceRatio = 0,
    rewardMoney = rewardMoney,
    rewardXp = rewardXp,
    expiresAt = now + expiryMinutes,
    createdAt = now
  }
end

local function generateSponsorOffer(disciplineId, level, now)
  local helpers = gameplay_events_freContracts_helpers
  local skills = gameplay_events_freContracts_skills
  local rCache = gameplay_events_freContracts_raceCache
  local sponsorCfg = freConfig.getSponsorConfig(disciplineId)
  local unlockedTiers = skills.getUnlockedSponsorTiers(disciplineId, level)
  if #unlockedTiers == 0 then
    return nil
  end

  local tier = unlockedTiers[helpers.randomInt(1, #unlockedTiers)]
  local requirementData = rCache.buildSponsorRequirement(disciplineId, tier)
  if not requirementData then
    return nil
  end
  local bonusRange = ((sponsorCfg.bonusRangeByTier or {})[tier]) or {
    min = 0.01,
    max = 0.05
  }
  local bonusPercent = helpers.roundTo(helpers.randomFloat(bonusRange.min or 0.01, bonusRange.max or 0.05), 3)
  local bonusType = helpers.pickWeightedBonusType(sponsorCfg.bonusTypeWeights or {})
  local upkeepMinutes = tonumber((sponsorCfg.upkeepMinutesByTier or {})[tier]) or 120

  local offerExpiry = tonumber(sponsorCfg.offerExpiryMinutes) or 5
  if offerExpiry <= 0 then
    offerExpiry = 5
  end

  return {
    id = gameplay_events_freContracts_state.nextId("fre-sponsor"),
    disciplineId = disciplineId,
    tier = tier,
    name = randomSponsorName(),
    bonusType = bonusType,
    bonusPercent = bonusPercent,
    upkeepMinutes = upkeepMinutes,
    requiredRaceName = requirementData.requiredRaceName,
    requiredRaceLabel = requirementData.requiredRaceLabel,
    requiredRaceRouteType = requirementData.requiredRaceRouteType,
    targetType = requirementData.targetType,
    targetTime = requirementData.targetTime,
    targetDriftScore = requirementData.targetDriftScore,
    targetDamagePctMax = requirementData.targetDamagePctMax,
    requirement = requirementData.requirement,
    expiresAt = now + offerExpiry,
    createdAt = now
  }
end

local function syncOffersForDiscipline(disciplineId, now)
  local state = gameplay_events_freContracts_state.getState()
  local skills = gameplay_events_freContracts_skills
  local vPool = gameplay_events_freContracts_vehiclePool
  local dState = state.disciplines[disciplineId]
  if not dState then
    return false
  end
  local changed = false

  for i = #dState.contracts.available, 1, -1 do
    local offer = dState.contracts.available[i]
    if normalizeContractEntryAndDetectChanges(disciplineId, offer) then
      changed = true
    end
    local requiredModel = offer.requiredModel
    if requiredModel and requiredModel ~= "" and
      (not vPool.isModelAllowedForDiscipline(disciplineId, requiredModel) or not vPool.isValidVehicleModelKey(requiredModel)) then
      table.remove(dState.contracts.available, i)
      changed = true
    end
  end
  for _, offer in ipairs(dState.contracts.active or {}) do
    if normalizeContractEntryAndDetectChanges(disciplineId, offer) then
      changed = true
    end
  end

  local level = skills.getSkillLevel(disciplineId)
  local contractCfg = freConfig.getContractConfig(disciplineId)
  local sponsorCfg = freConfig.getSponsorConfig(disciplineId)
  local offerExpiryMinutes = tonumber(contractCfg.offerExpiryMinutes) or 5
  if offerExpiryMinutes <= 0 then
    offerExpiryMinutes = 5
  end
  local sponsorOfferExpiryMinutes = tonumber(sponsorCfg.offerExpiryMinutes) or 5
  if sponsorOfferExpiryMinutes <= 0 then
    sponsorOfferExpiryMinutes = 5
  end

  local contractTierUnlock = (contractCfg.tierUnlockLevels or {}).easy or math.huge
  local sponsorTierUnlock = (sponsorCfg.tierUnlockLevels or {}).easy or math.huge

  if level < contractTierUnlock then
    if #dState.contracts.available > 0 then
      changed = true
    end
    dState.contracts.available = {}
    dState.contracts.seeded = false
    dState.contracts.nextOfferAt = now
  else
    local contractCap = skills.countOfferCap(level, contractCfg)

    for _, offer in ipairs(dState.contracts.available or {}) do
      local createdAt = tonumber(offer.createdAt) or now
      local maxExpiry = createdAt + offerExpiryMinutes
      local currentExpiry = tonumber(offer.expiresAt) or maxExpiry
      if currentExpiry > maxExpiry then
        offer.expiresAt = maxExpiry
      end
    end

    while #dState.contracts.available > contractCap do
      table.remove(dState.contracts.available, #dState.contracts.available)
      changed = true
    end

    local offerRefreshMinutes = tonumber(contractCfg.offerRefreshMinutes) or 2
    offerRefreshMinutes = math.max(0.25, offerRefreshMinutes)

    if not dState.contracts.seeded then
      while #dState.contracts.available < contractCap do
        local offer = generateContractOffer(disciplineId, level, now)
        if not offer then
          break
        end
        table.insert(dState.contracts.available, offer)
        changed = true
      end
      dState.contracts.seeded = true
      dState.contracts.nextOfferAt = now + offerRefreshMinutes
    else
      local nextOfferAt = tonumber(dState.contracts.nextOfferAt) or now
      if nextOfferAt < now - (offerRefreshMinutes * 20) then
        nextOfferAt = now
      end
      if #dState.contracts.available < contractCap and now >= nextOfferAt then
        local offer = generateContractOffer(disciplineId, level, now)
        dState.contracts.nextOfferAt = now + offerRefreshMinutes
        if offer then
          table.insert(dState.contracts.available, offer)
          changed = true
        end
      elseif #dState.contracts.available >= contractCap then
        dState.contracts.nextOfferAt = now + offerRefreshMinutes
      end
    end
  end

  if level < sponsorTierUnlock then
    if #dState.sponsors.available > 0 then
      changed = true
    end
    dState.sponsors.available = {}
    dState.sponsors.seeded = false
    dState.sponsors.nextOfferAt = now
  else
    local sponsorCap = skills.countOfferCap(level, sponsorCfg)

    for _, offer in ipairs(dState.sponsors.available or {}) do
      normalizeSponsorEntry(disciplineId, offer)
      local createdAt = tonumber(offer.createdAt) or now
      local maxExpiry = createdAt + sponsorOfferExpiryMinutes
      local currentExpiry = tonumber(offer.expiresAt) or maxExpiry
      if currentExpiry > maxExpiry then
        offer.expiresAt = maxExpiry
      end
    end

    for _, activeSponsor in ipairs(dState.sponsors.active or {}) do
      normalizeSponsorEntry(disciplineId, activeSponsor)
    end

    while #dState.sponsors.available > sponsorCap do
      table.remove(dState.sponsors.available, #dState.sponsors.available)
      changed = true
    end

    local sponsorOfferRefreshMinutes = tonumber(sponsorCfg.offerRefreshMinutes) or 2
    sponsorOfferRefreshMinutes = math.max(0.25, sponsorOfferRefreshMinutes)

    if not dState.sponsors.seeded then
      while #dState.sponsors.available < sponsorCap do
        local offer = generateSponsorOffer(disciplineId, level, now)
        if not offer then
          break
        end
        table.insert(dState.sponsors.available, offer)
        changed = true
      end
      dState.sponsors.seeded = true
      dState.sponsors.nextOfferAt = now + sponsorOfferRefreshMinutes
    else
      local nextOfferAt = tonumber(dState.sponsors.nextOfferAt) or now
      if nextOfferAt < now - (sponsorOfferRefreshMinutes * 20) then
        nextOfferAt = now
      end
      if #dState.sponsors.available < sponsorCap and now >= nextOfferAt then
        local offer = generateSponsorOffer(disciplineId, level, now)
        dState.sponsors.nextOfferAt = now + sponsorOfferRefreshMinutes
        if offer then
          table.insert(dState.sponsors.available, offer)
          changed = true
        end
      elseif #dState.sponsors.available >= sponsorCap then
        dState.sponsors.nextOfferAt = now + sponsorOfferRefreshMinutes
      end
    end
  end

  return changed
end

local function syncAllOffers(now)
  local rCache = gameplay_events_freContracts_raceCache
  rCache.refreshRaceCache()
  local changed = false
  for _, discipline in ipairs(freConfig.getDisciplines()) do
    if syncOffersForDiscipline(discipline.id, now) then
      changed = true
    end
  end
  return changed
end

M.normalizeContractEntry = normalizeContractEntry
M.normalizeSponsorEntry = normalizeSponsorEntry
M.purgeExpiredEntries = purgeExpiredEntries
M.syncAllOffers = syncAllOffers

return M
