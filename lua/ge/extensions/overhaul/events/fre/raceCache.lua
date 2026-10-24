-- Level race discovery and discipline/route entries for freeroam offer generation.
-- Read race metadata helpers, ordered cache projection, target construction and public cache services.
local raceDataCatalog = require("overhaul/lib/events/raceDataCatalog")
local M = {}
local freHelpers = require("overhaul/events/fre/helpers")

local freConfig = require("overhaul/events/freConfig")
local pullingConfig = require("overhaul/lib/events/pullingConfig")
local jsonCatalog = require("overhaul/lib/platform/jsonCatalog")

-- Config ------------------------------------------------------------------------------------------

local TARGET_TYPE_TIME = "time"
local TARGET_TYPE_DRIFT_SCORE = "driftScore"
local TARGET_TYPE_MAX_DAMAGE_PCT = "maxDamagePct"
local TARGET_TYPE_PULL_DISTANCE = "pullDistance"

local DAMAGE_TARGETS_BY_CONTEXT = {
  contract = {
    easy = 0.10,
    medium = 0.06,
    hard = 0.03,
  },
  sponsor = {
    easy = 0.14,
    medium = 0.10,
    hard = 0.06,
  },
}

-- State ---------------------------------------------------------------------------------------------

local raceCache = {
  levelId = nil,
  byDiscipline = {},
  races = {},
}

local rawRaceDataByLevel = {}

-- Race discovery and route entries ------------------------------------------------------------------

local function getPullDistanceFromSites(levelId, pullingCfg)
  local configured = pullingConfig.normalize(pullingCfg)
  if not configured.sitesFile or not configured.spawnSpot or not configured.finishSpot then return nil end
  local pullingSites = jsonReadFile("levels/" .. tostring(levelId) .. "/" .. configured.sitesFile)
  local spawnName, finishName = configured.spawnSpot, configured.finishSpot
  local spawnPos, finishPos
  for _, spot in ipairs(type(pullingSites) == "table" and pullingSites.parkingSpots or {}) do
    if spot.name == spawnName then spawnPos = spot.pos end
    if spot.name == finishName then finishPos = spot.pos end
  end
  if type(spawnPos) ~= "table" or type(finishPos) ~= "table" then return nil end
  for index = 1, 3 do
    if not jsonCatalog.finite(spawnPos[index]) or not jsonCatalog.finite(finishPos[index]) then return nil end
  end
  local dx = finishPos[1] - spawnPos[1]
  local dy = finishPos[2] - spawnPos[2]
  local dz = finishPos[3] - spawnPos[3]
  local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
  return distance > 1 and distance or nil
end

local function getRawRaceData(levelId)
  if type(levelId) ~= "string" or levelId == "" then return nil end
  local cached = rawRaceDataByLevel[levelId]
  if cached ~= nil then return cached ~= false and cached or nil end
  local data = raceDataCatalog.read("levels/" .. levelId .. "/race_data.json")
  if type(data) == "table" then
    rawRaceDataByLevel[levelId] = data
    return data
  end
  rawRaceDataByLevel[levelId] = false
  return nil
end

local function getRaceDataRow(levelId, raceName)
  if type(raceName) ~= "string" or raceName == "" then return nil end
  local data = getRawRaceData(levelId)
  if type(data) ~= "table" then return nil end
  local race = (data.races or {})[raceName]
  return type(race) == "table" and race or nil
end

local function isDamageMetricDiscipline(disciplineId)
  local id = type(disciplineId) == "string" and string.lower(disciplineId) or ""
  return id == "crawling" or id == "trail"
end

local function normalizeRaceRouteType(routeType)
  if type(routeType) ~= "string" then return nil end
  local normalized = string.lower(routeType)
  if normalized == "main" or normalized == "alt" then return normalized end
  return nil
end

local function routeTypeMatches(requiredRouteType, isAltRoute)
  local required = normalizeRaceRouteType(requiredRouteType)
  if not required then return true end
  return required == (isAltRoute and "alt" or "main")
end

local function appendAlternativeRaceCacheEntry(entries, raceName, raceLabel, altRoute, baseBestTime, baseIsLapEvent, baseDriftGoal, baseDamageFactor)
  local altLabel = altRoute.label or (raceLabel .. " (Alt Route)")
  local altBestTime = tonumber(altRoute.bestTime) or tonumber(altRoute.hotlap) or baseBestTime
  local altLapEvent = altRoute.hotlap ~= nil or baseIsLapEvent
  local altDriftGoal = tonumber(altRoute.driftGoal)
  if not altDriftGoal then altDriftGoal = baseDriftGoal end
  local altDamageFactor = tonumber(altRoute.damageFactor)
  if altDamageFactor == nil then altDamageFactor = baseDamageFactor end
  table.insert(entries, {
    raceName = raceName,
    raceLabel = altLabel,
    bestTime = altBestTime,
    isLapEvent = altLapEvent,
    routeType = "alt",
    driftGoal = altDriftGoal,
    damageFactor = altDamageFactor or 0,
  })
end

local function cacheRaceDisciplineRows(raceName, race, byDiscipline, pullDistanceFromSites, pullingDefinition)
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
      if disciplineId == "pulling" and type(race.sledPresets) == "table" then
        for _, sled in ipairs(race.sledPresets) do
          if type(sled) == "table" and type(sled.id) == "string" and sled.id ~= "" then
            table.insert(byDiscipline[disciplineId], {
              raceName = raceName,
              raceLabel = raceLabel .. " - " .. tostring(sled.label or sled.id),
              bestTime = tonumber(sled.parTimeSeconds) or baseBestTime,
              isLapEvent = false,
              routeType = "main",
              pullDistanceMeters = pullDistanceFromSites or tonumber(race.pullDistanceMeters),
              fullPullDistanceMeters = pullingConfig.normalize(pullingDefinition).fullPullDistanceMeters,
              requiredSledId = sled.id,
              requiredSledLabel = sled.label or sled.id,
              baseReward = tonumber(sled.baseReward) or tonumber(race.reward),
            })
          end
        end
      else
        table.insert(byDiscipline[disciplineId], {
          raceName = raceName,
          raceLabel = raceLabel,
          bestTime = baseBestTime,
          isLapEvent = baseIsLapEvent,
          routeType = "main",
          driftGoal = baseDriftGoal,
          damageFactor = baseDamageFactor,
        })
      end

      if disciplineId ~= "pulling" and type(race.altRoute) == "table" then
        appendAlternativeRaceCacheEntry(byDiscipline[disciplineId], raceName, raceLabel, race.altRoute,
          baseBestTime, baseIsLapEvent, baseDriftGoal, baseDamageFactor)
      end
    end
  end
end

-- Cache refresh and lookup --------------------------------------------------------------------------

local function refreshRaceCache()
  local levelId = overhaul_events_fre_state.getCurrentLevelId()
  if not levelId or levelId == "" then
    raceCache = {
      levelId = nil,
      byDiscipline = {},
      races = {},
    }
    return raceCache
  end
  if raceCache.levelId == levelId then return raceCache end

  local raceData = getRawRaceData(levelId) or {}
  local races = raceData.races or {}
  local pullDistances = {}
  local pullingData = jsonReadFile("levels/" .. levelId .. "/overhaul/pulling.json")
  local pullingEvents = pullingConfig.events(pullingData)
  for eventId, definition in pairs(pullingEvents) do
    pullDistances[eventId] = getPullDistanceFromSites(levelId, definition)
  end
  local byDiscipline = {}
  for _, discipline in ipairs(freConfig.getDisciplines()) do
    byDiscipline[discipline.id] = {}
  end

  for raceName, race in pairs(races) do
    cacheRaceDisciplineRows(raceName, race, byDiscipline, pullDistances[raceName], pullingEvents[raceName])
  end

  raceCache = {
    levelId = levelId,
    byDiscipline = byDiscipline,
    races = races,
  }
  return raceCache
end

local function getRaceCache()
  return raceCache
end

local function findRaceEntry(disciplineId, raceName, raceRouteType, raceLabel)
  local normalizedDisciplineId = type(disciplineId) == "string" and string.lower(disciplineId) or nil
  if not normalizedDisciplineId or normalizedDisciplineId == "" then return nil end
  if type(raceName) ~= "string" or raceName == "" then return nil end

  local routeType = normalizeRaceRouteType(raceRouteType)
  local raceData = refreshRaceCache().byDiscipline[normalizedDisciplineId] or {}
  local byRouteCandidate = nil
  local fallbackCandidate = nil
  for _, raceEntry in ipairs(raceData) do
    if raceEntry.raceName == raceName then
      if not fallbackCandidate then fallbackCandidate = raceEntry end
      if type(raceLabel) == "string" and raceLabel ~= "" and raceEntry.raceLabel == raceLabel then return raceEntry end
      if routeType and normalizeRaceRouteType(raceEntry.routeType) == routeType and not byRouteCandidate then
        byRouteCandidate = raceEntry
      end
    end
  end

  return byRouteCandidate or fallbackCandidate
end

local function inferRouteTypeFromRaceLabel(disciplineId, raceName, raceLabel)
  if type(disciplineId) ~= "string" or disciplineId == "" then return nil end
  if type(raceName) ~= "string" or raceName == "" then return nil end
  if type(raceLabel) ~= "string" or raceLabel == "" then return nil end

  local raceData = refreshRaceCache().byDiscipline[string.lower(disciplineId)] or {}
  local matchedRouteType = nil
  for _, raceEntry in ipairs(raceData) do
    if raceEntry.raceName == raceName and raceEntry.raceLabel == raceLabel then
      local routeType = normalizeRaceRouteType(raceEntry.routeType)
      if routeType then
        if matchedRouteType and matchedRouteType ~= routeType then return nil end
        matchedRouteType = routeType
      end
    end
  end

  return matchedRouteType
end

-- Contract and sponsor targets ----------------------------------------------------------------------

local function resolveTargetMultiplierRangeForTier(tier, cfg, fallbackCfg, defaultRange)
  local multiplierRange = (cfg and cfg.targetMultiplierByTier or {})[tier] or {}
  if type(multiplierRange) ~= "table" or (multiplierRange.min == nil and multiplierRange.max == nil) then
    multiplierRange = (fallbackCfg and fallbackCfg.targetMultiplierByTier or {})[tier] or {}
  end
  if type(multiplierRange) ~= "table" then multiplierRange = {} end

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
  local helpers = freHelpers
  local multMin, multMax = resolveTargetMultiplierRangeForTier(tier, cfg, fallbackCfg, defaultRange)
  local baseBest = tonumber(bestTime) or 60
  return helpers.roundTo(baseBest * helpers.randomFloat(multMin, multMax), 3)
end

local function resolveTargetDriftScoreForTier(tier, driftGoal, cfg, fallbackCfg, defaultRange)
  local helpers = freHelpers
  local multMin, multMax = resolveTargetMultiplierRangeForTier(tier, cfg, fallbackCfg, defaultRange)
  local sampledMultiplier = helpers.randomFloat(multMin, multMax)
  if sampledMultiplier <= 0 then sampledMultiplier = 1.0 end
  local baseGoal = tonumber(driftGoal) or 0
  if baseGoal <= 0 then return nil end
  return math.max(1, math.floor((baseGoal / sampledMultiplier) + 0.5))
end

local function resolveDamageTargetThresholdByTier(tier, contextKey)
  local context = DAMAGE_TARGETS_BY_CONTEXT[contextKey] or DAMAGE_TARGETS_BY_CONTEXT.contract
  local value = tonumber(context[tier]) or tonumber(context.easy) or 0.10
  return math.max(0, math.min(1, value))
end

local function buildPullDistanceTargetForTier(tier, raceEntry, cfg, playerBestMeters)
  local helpers = freHelpers
  local entry = type(raceEntry) == "table" and raceEntry or {}
  local fullDistance = tonumber(entry.pullDistanceMeters) or 0
  if fullDistance <= 0 then return nil end
  local targetDistance
  local pb = tonumber(playerBestMeters)
  if pb and pb > 0 then
    local defaults = {
      easy = { min = 0.9, max = 1.0 },
      medium = { min = 1.0, max = 1.1 },
      hard = { min = 1.1, max = 1.25 },
    }
    local ranges = type(cfg) == "table" and cfg.pullPbDistanceMultipliersByTier or nil
    local range = type(ranges) == "table" and ranges[tier] or nil
    range = type(range) == "table" and range or defaults[tier] or defaults.easy
    local low = tonumber(range.min) or 1
    local high = tonumber(range.max) or low
    if high < low then
      low, high = high, low
    end
    targetDistance = pb * helpers.randomFloat(low, high)
  else
    local defaults = { easy = 0.6, medium = 0.8, hard = 0.95 }
    local ratios = type(cfg) == "table" and cfg.pullFallbackRatioByTier or nil
    local ratio = type(ratios) == "table" and tonumber(ratios[tier]) or nil
    targetDistance = fullDistance * (ratio or defaults[tier] or defaults.easy)
  end
  targetDistance = math.min(fullDistance, math.max(0.5, targetDistance))
  -- Keep the original targeting baseline, but never ask beyond the runtime finish.
  local finishDistance = tonumber(entry.fullPullDistanceMeters) or fullDistance
  targetDistance = math.min(finishDistance, helpers.roundTo(targetDistance, 2))
  return {
    targetType = TARGET_TYPE_PULL_DISTANCE,
    targetDistanceMeters = targetDistance,
    requiredSledId = entry.requiredSledId,
    requiredSledLabel = entry.requiredSledLabel,
    targetLabel = string.format("%.1f ft", targetDistance * 3.280839895),
  }
end

local function buildTargetForTier(disciplineId, tier, raceEntry, cfg, fallbackCfg, defaultRange, contextKey)
  local helpers = freHelpers
  local entry = type(raceEntry) == "table" and raceEntry or {}
  local normalizedDisciplineId = type(disciplineId) == "string" and string.lower(disciplineId) or ""

  if normalizedDisciplineId == "pulling" then return buildPullDistanceTargetForTier(tier, entry, cfg, nil) end

  if normalizedDisciplineId == "drift" and (tonumber(entry.driftGoal) or 0) > 0 then
    local targetDriftScore = resolveTargetDriftScoreForTier(tier, entry.driftGoal, cfg, fallbackCfg, defaultRange)
    if targetDriftScore then
      return {
        targetType = TARGET_TYPE_DRIFT_SCORE,
        targetDriftScore = targetDriftScore,
        targetLabel = string.format("%d score", targetDriftScore),
      }
    end
  end

  if isDamageMetricDiscipline(normalizedDisciplineId) then
    local targetDamagePctMax = resolveDamageTargetThresholdByTier(tier, contextKey)
    return {
      targetType = TARGET_TYPE_MAX_DAMAGE_PCT,
      targetDamagePctMax = targetDamagePctMax,
      targetLabel = string.format("%d%% damage", math.floor(targetDamagePctMax * 100 + 0.5)),
    }
  end

  local targetTime = resolveTargetTimeForTier(tier, entry.bestTime, cfg, fallbackCfg, defaultRange)
  return {
    targetType = TARGET_TYPE_TIME,
    targetTime = targetTime,
    targetLabel = helpers.formatTimeForRequirement(targetTime),
  }
end

-- Sponsor requirement display -----------------------------------------------------------------------

local function formatRequirementForTarget(targetData, raceLabel)
  local label = raceLabel or "this event"
  local targetType = targetData and targetData.targetType or TARGET_TYPE_TIME
  if targetType == TARGET_TYPE_DRIFT_SCORE then
    return string.format(
      "Score at least %d on %s once per upkeep window (no XP minimum).",
      math.max(1, math.floor(tonumber(targetData.targetDriftScore) or 0)),
      label
    )
  end
  if targetType == TARGET_TYPE_MAX_DAMAGE_PCT then
    local pct = math.max(0, math.min(1, tonumber(targetData.targetDamagePctMax) or 0))
    return string.format(
      "Finish %s with at most %d%% damage once per upkeep window (no XP minimum).",
      label,
      math.floor(pct * 100 + 0.5)
    )
  end
  if targetType == TARGET_TYPE_PULL_DISTANCE then
    local distance = math.max(0, tonumber(targetData.targetDistanceMeters) or 0)
    return string.format(
      "Pull at least %.1f ft with %s on %s once per upkeep window (no XP minimum).",
      distance * 3.280839895,
      tostring(targetData.requiredSledLabel or targetData.requiredSledId or "the required sled"),
      label
    )
  end

  local targetTime = tonumber(targetData and targetData.targetTime) or 0
  local formattedTime = freHelpers.formatTimeForRequirement(targetTime)
  return string.format("Beat %s on %s once per upkeep window (no XP minimum).", formattedTime, label)
end

local function buildSponsorRequirement(disciplineId, tier)
  local helpers = freHelpers
  local raceData = refreshRaceCache().byDiscipline[disciplineId] or {}
  if #raceData == 0 then return nil end

  local raceEntry = helpers.pickRandomFromList(raceData)
  if not raceEntry then return nil end

  local sponsorCfg = freConfig.getSponsorConfig(disciplineId) or {}
  local contractCfg = freConfig.getContractConfig(disciplineId) or {}
  local targetData = buildTargetForTier(disciplineId, tier, raceEntry, sponsorCfg, contractCfg, {
    min = 1.25,
    max = 1.5,
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
    targetDistanceMeters = targetData and targetData.targetDistanceMeters or nil,
    requiredSledId = targetData and targetData.requiredSledId or raceEntry.requiredSledId,
    requiredSledLabel = targetData and targetData.requiredSledLabel or raceEntry.requiredSledLabel,
    requirement = formatRequirementForTarget(targetData, raceLabel),
  }
end

-- Public API --------------------------------------------------------------------------------------

M.refreshRaceCache = refreshRaceCache
M.getRaceCache = getRaceCache
M.getRawRaceData = getRawRaceData
M.getRaceDataRow = getRaceDataRow
M.findRaceEntry = findRaceEntry
M.normalizeRaceRouteType = normalizeRaceRouteType
M.routeTypeMatches = routeTypeMatches
M.inferRouteTypeFromRaceLabel = inferRouteTypeFromRaceLabel
M.resolveTargetTimeForTier = resolveTargetTimeForTier
M.buildPullDistanceTargetForTier = buildPullDistanceTargetForTier
M.buildTargetForTier = buildTargetForTier
M.formatRequirementForTarget = formatRequirementForTarget
M.buildSponsorRequirement = buildSponsorRequirement

return M
