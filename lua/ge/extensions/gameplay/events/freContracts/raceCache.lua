local M = {}

local freConfig = require('gameplay/fre/config')

local TARGET_TYPE_TIME = "time"
local TARGET_TYPE_DRIFT_SCORE = "driftScore"
local TARGET_TYPE_MAX_DAMAGE_PCT = "maxDamagePct"

local DAMAGE_TARGETS_BY_CONTEXT = {
  contract = {
    easy = 0.10,
    medium = 0.06,
    hard = 0.03
  },
  sponsor = {
    easy = 0.14,
    medium = 0.10,
    hard = 0.06
  }
}

local raceCache = {
  levelId = nil,
  byDiscipline = {}
}

local function isDamageMetricDiscipline(disciplineId)
  local id = type(disciplineId) == "string" and string.lower(disciplineId) or ""
  return id == "crawling" or id == "trail"
end

local function normalizeRaceRouteType(routeType)
  if type(routeType) ~= "string" then
    return nil
  end
  local normalized = string.lower(routeType)
  if normalized == "main" or normalized == "alt" then
    return normalized
  end
  return nil
end

local function routeTypeMatches(requiredRouteType, isAltRoute)
  local required = normalizeRaceRouteType(requiredRouteType)
  if not required then
    return true
  end
  return required == (isAltRoute and "alt" or "main")
end

local function refreshRaceCache()
  local levelId = gameplay_events_freContracts_state.getCurrentLevelId()
  if not levelId or levelId == "" then
    raceCache = {
      levelId = nil,
      byDiscipline = {}
    }
    return raceCache
  end
  if raceCache.levelId == levelId then
    return raceCache
  end

  local raceData = jsonReadFile("levels/" .. levelId .. "/race_data.json") or {}
  local races = raceData.races or {}
  local byDiscipline = {}
  for _, discipline in ipairs(freConfig.getDisciplines()) do
    byDiscipline[discipline.id] = {}
  end

  for raceName, race in pairs(races) do
    local types = race.type or {}
    local seen = {}
    local baseBestTime = tonumber(race.bestTime) or tonumber(race.hotlap) or 60
    local baseIsLapEvent = race.hotlap ~= nil
    local baseDriftGoal = tonumber(race.driftGoal)
    local baseDamageFactor = tonumber(race.damageFactor) or 0
    for _, rawType in ipairs(types) do
      local disciplineId = freConfig.getDisciplineIdFromType(rawType)
      if disciplineId and not seen[disciplineId] then
        seen[disciplineId] = true
        byDiscipline[disciplineId] = byDiscipline[disciplineId] or {}
        local raceLabel = race.label or raceName
        table.insert(byDiscipline[disciplineId], {
          raceName = raceName,
          raceLabel = raceLabel,
          bestTime = baseBestTime,
          isLapEvent = baseIsLapEvent,
          routeType = "main",
          driftGoal = baseDriftGoal,
          damageFactor = baseDamageFactor
        })

        if type(race.altRoute) == "table" then
          local altRoute = race.altRoute
          local altLabel = altRoute.label or (raceLabel .. " (Alt Route)")
          local altBestTime = tonumber(altRoute.bestTime) or tonumber(altRoute.hotlap) or baseBestTime
          local altLapEvent = altRoute.hotlap ~= nil or baseIsLapEvent
          local altDriftGoal = tonumber(altRoute.driftGoal)
          if not altDriftGoal then
            altDriftGoal = baseDriftGoal
          end
          local altDamageFactor = tonumber(altRoute.damageFactor)
          if altDamageFactor == nil then
            altDamageFactor = baseDamageFactor
          end
          table.insert(byDiscipline[disciplineId], {
            raceName = raceName,
            raceLabel = altLabel,
            bestTime = altBestTime,
            isLapEvent = altLapEvent,
            routeType = "alt",
            driftGoal = altDriftGoal,
            damageFactor = altDamageFactor or 0
          })
        end
      end
    end
  end

  raceCache = {
    levelId = levelId,
    byDiscipline = byDiscipline
  }
  return raceCache
end

local function getRaceCache()
  return raceCache
end

local function findRaceEntry(disciplineId, raceName, raceRouteType, raceLabel)
  local normalizedDisciplineId = type(disciplineId) == "string" and string.lower(disciplineId) or nil
  if not normalizedDisciplineId or normalizedDisciplineId == "" then
    return nil
  end
  if type(raceName) ~= "string" or raceName == "" then
    return nil
  end

  local routeType = normalizeRaceRouteType(raceRouteType)
  local raceData = refreshRaceCache().byDiscipline[normalizedDisciplineId] or {}
  local byLabelCandidate = nil
  local fallbackCandidate = nil
  for _, raceEntry in ipairs(raceData) do
    if raceEntry.raceName == raceName then
      if not fallbackCandidate then
        fallbackCandidate = raceEntry
      end
      if routeType and normalizeRaceRouteType(raceEntry.routeType) == routeType then
        return raceEntry
      end
      if type(raceLabel) == "string" and raceLabel ~= "" and raceEntry.raceLabel == raceLabel then
        byLabelCandidate = raceEntry
      end
    end
  end

  return byLabelCandidate or fallbackCandidate
end

local function inferRouteTypeFromRaceLabel(disciplineId, raceName, raceLabel)
  if type(disciplineId) ~= "string" or disciplineId == "" then
    return nil
  end
  if type(raceName) ~= "string" or raceName == "" then
    return nil
  end
  if type(raceLabel) ~= "string" or raceLabel == "" then
    return nil
  end

  local raceData = refreshRaceCache().byDiscipline[string.lower(disciplineId)] or {}
  local matchedRouteType = nil
  for _, raceEntry in ipairs(raceData) do
    if raceEntry.raceName == raceName and raceEntry.raceLabel == raceLabel then
      local routeType = normalizeRaceRouteType(raceEntry.routeType)
      if routeType then
        if matchedRouteType and matchedRouteType ~= routeType then
          return nil
        end
        matchedRouteType = routeType
      end
    end
  end

  return matchedRouteType
end

local function resolveTargetMultiplierRangeForTier(tier, cfg, fallbackCfg, defaultRange)
  local multiplierRange = ((cfg and cfg.targetMultiplierByTier or {})[tier]) or {}
  if type(multiplierRange) ~= "table" or (multiplierRange.min == nil and multiplierRange.max == nil) then
    multiplierRange = ((fallbackCfg and fallbackCfg.targetMultiplierByTier or {})[tier]) or {}
  end
  if type(multiplierRange) ~= "table" then
    multiplierRange = {}
  end

  local defaultMin = tonumber((defaultRange or {}).min) or 1.0
  local defaultMax = tonumber((defaultRange or {}).max) or 1.1
  local multMin = tonumber(multiplierRange.min) or defaultMin
  local multMax = tonumber(multiplierRange.max) or defaultMax
  if multMax < multMin then
    multMin, multMax = multMax, multMin
  end
  return multMin, multMax
end

local function resolveTargetTimeForTier(tier, bestTime, cfg, fallbackCfg, defaultRange)
  local helpers = gameplay_events_freContracts_helpers
  local multMin, multMax = resolveTargetMultiplierRangeForTier(tier, cfg, fallbackCfg, defaultRange)
  local baseBest = tonumber(bestTime) or 60
  return helpers.roundTo(baseBest * helpers.randomFloat(multMin, multMax), 3)
end

local function resolveTargetDriftScoreForTier(tier, driftGoal, cfg, fallbackCfg, defaultRange)
  local helpers = gameplay_events_freContracts_helpers
  local multMin, multMax = resolveTargetMultiplierRangeForTier(tier, cfg, fallbackCfg, defaultRange)
  local sampledMultiplier = helpers.randomFloat(multMin, multMax)
  if sampledMultiplier <= 0 then
    sampledMultiplier = 1.0
  end
  local baseGoal = tonumber(driftGoal) or 0
  if baseGoal <= 0 then
    return nil
  end
  return math.max(1, math.floor((baseGoal / sampledMultiplier) + 0.5))
end

local function resolveDamageTargetThresholdByTier(tier, contextKey)
  local context = DAMAGE_TARGETS_BY_CONTEXT[contextKey] or DAMAGE_TARGETS_BY_CONTEXT.contract
  local value = tonumber(context[tier]) or tonumber(context.easy) or 0.10
  return math.max(0, math.min(1, value))
end

local function buildTargetForTier(disciplineId, tier, raceEntry, cfg, fallbackCfg, defaultRange, contextKey)
  local helpers = gameplay_events_freContracts_helpers
  local entry = type(raceEntry) == "table" and raceEntry or {}
  local normalizedDisciplineId = type(disciplineId) == "string" and string.lower(disciplineId) or ""

  if normalizedDisciplineId == "drift" and (tonumber(entry.driftGoal) or 0) > 0 then
    local targetDriftScore = resolveTargetDriftScoreForTier(tier, entry.driftGoal, cfg, fallbackCfg, defaultRange)
    if targetDriftScore then
      return {
        targetType = TARGET_TYPE_DRIFT_SCORE,
        targetDriftScore = targetDriftScore,
        targetLabel = string.format("%d score", targetDriftScore)
      }
    end
  end

  if isDamageMetricDiscipline(normalizedDisciplineId) then
    local targetDamagePctMax = resolveDamageTargetThresholdByTier(tier, contextKey)
    return {
      targetType = TARGET_TYPE_MAX_DAMAGE_PCT,
      targetDamagePctMax = targetDamagePctMax,
      targetLabel = string.format("%d%% damage", math.floor(targetDamagePctMax * 100 + 0.5))
    }
  end

  local targetTime = resolveTargetTimeForTier(tier, entry.bestTime, cfg, fallbackCfg, defaultRange)
  return {
    targetType = TARGET_TYPE_TIME,
    targetTime = targetTime,
    targetLabel = helpers.formatTimeForRequirement(targetTime)
  }
end

local function formatRequirementForTarget(targetData, raceLabel)
  local label = raceLabel or "this event"
  local targetType = targetData and targetData.targetType or TARGET_TYPE_TIME
  if targetType == TARGET_TYPE_DRIFT_SCORE then
    return string.format("Score at least %d on %s once per upkeep window (no XP minimum).",
      math.max(1, math.floor(tonumber(targetData.targetDriftScore) or 0)), label)
  end
  if targetType == TARGET_TYPE_MAX_DAMAGE_PCT then
    local pct = math.max(0, math.min(1, tonumber(targetData.targetDamagePctMax) or 0))
    return string.format("Finish %s with at most %d%% damage once per upkeep window (no XP minimum).",
      label, math.floor(pct * 100 + 0.5))
  end

  local targetTime = tonumber(targetData and targetData.targetTime) or 0
  local formattedTime = gameplay_events_freContracts_helpers.formatTimeForRequirement(targetTime)
  return string.format("Beat %s on %s once per upkeep window (no XP minimum).", formattedTime, label)
end

local function buildSponsorRequirement(disciplineId, tier)
  local helpers = gameplay_events_freContracts_helpers
  local raceData = refreshRaceCache().byDiscipline[disciplineId] or {}
  if #raceData == 0 then
    return nil
  end

  local raceEntry = helpers.pickRandomFromList(raceData)
  if not raceEntry then
    return nil
  end

  local sponsorCfg = freConfig.getSponsorConfig(disciplineId) or {}
  local contractCfg = freConfig.getContractConfig(disciplineId) or {}
  local targetData = buildTargetForTier(disciplineId, tier, raceEntry, sponsorCfg, contractCfg, {
    min = 1.25,
    max = 1.5
  }, "sponsor")
  local raceLabel = raceEntry.raceLabel or raceEntry.raceName or disciplineId

  return {
    requiredRaceName = raceEntry.raceName,
    requiredRaceLabel = raceLabel,
    requiredRaceRouteType = raceEntry.routeType,
    targetType = targetData and targetData.targetType or TARGET_TYPE_TIME,
    targetTime = targetData and targetData.targetTime or nil,
    targetDriftScore = targetData and targetData.targetDriftScore or nil,
    targetDamagePctMax = targetData and targetData.targetDamagePctMax or nil,
    requirement = formatRequirementForTarget(targetData, raceLabel)
  }
end

M.refreshRaceCache = refreshRaceCache
M.getRaceCache = getRaceCache
M.findRaceEntry = findRaceEntry
M.normalizeRaceRouteType = normalizeRaceRouteType
M.routeTypeMatches = routeTypeMatches
M.inferRouteTypeFromRaceLabel = inferRouteTypeFromRaceLabel
M.resolveTargetTimeForTier = resolveTargetTimeForTier
M.buildTargetForTier = buildTargetForTier
M.formatRequirementForTarget = formatRequirementForTarget
M.buildSponsorRequirement = buildSponsorRequirement

return M
