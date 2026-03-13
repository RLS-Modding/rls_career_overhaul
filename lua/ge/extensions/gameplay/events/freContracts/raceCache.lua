local M = {}

local freConfig = require('gameplay/fre/config')

local raceCache = {
  levelId = nil,
  byDiscipline = {}
}

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
    for _, rawType in ipairs(types) do
      local disciplineId = freConfig.getDisciplineIdFromType(rawType)
      if disciplineId and not seen[disciplineId] then
        seen[disciplineId] = true
        byDiscipline[disciplineId] = byDiscipline[disciplineId] or {}
        local raceLabel = race.label or raceName
        local bestTime = tonumber(race.bestTime) or tonumber(race.hotlap) or 60
        local isLapEvent = race.hotlap ~= nil
        table.insert(byDiscipline[disciplineId], {
          raceName = raceName,
          raceLabel = raceLabel,
          bestTime = bestTime,
          isLapEvent = isLapEvent,
          routeType = "main"
        })

        if type(race.altRoute) == "table" then
          local altRoute = race.altRoute
          local altLabel = altRoute.label or (raceLabel .. " (Alt Route)")
          local altBestTime = tonumber(altRoute.bestTime) or tonumber(altRoute.hotlap) or bestTime
          local altLapEvent = altRoute.hotlap ~= nil or isLapEvent
          table.insert(byDiscipline[disciplineId], {
            raceName = raceName,
            raceLabel = altLabel,
            bestTime = altBestTime,
            isLapEvent = altLapEvent,
            routeType = "alt"
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

  local raceData = refreshRaceCache().byDiscipline[disciplineId] or {}
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

local function resolveTargetTimeForTier(disciplineId, tier, bestTime, cfg, fallbackCfg, defaultRange)
  local helpers = gameplay_events_freContracts_helpers
  local multMin, multMax = resolveTargetMultiplierRangeForTier(tier, cfg, fallbackCfg, defaultRange)
  local baseBest = tonumber(bestTime) or 60
  return helpers.roundTo(baseBest * helpers.randomFloat(multMin, multMax), 3)
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
  local targetTime = resolveTargetTimeForTier(disciplineId, tier, raceEntry.bestTime, sponsorCfg, contractCfg, {
    min = 1.25,
    max = 1.5
  })
  local raceLabel = raceEntry.raceLabel or raceEntry.raceName or disciplineId
  local targetLabel = helpers.formatTimeForRequirement(targetTime)
  local requirement = string.format("Beat %s on %s once per upkeep window (no XP minimum).", targetLabel, raceLabel)

  return {
    requiredRaceName = raceEntry.raceName,
    requiredRaceLabel = raceLabel,
    requiredRaceRouteType = raceEntry.routeType,
    targetTime = targetTime,
    requirement = requirement
  }
end

M.refreshRaceCache = refreshRaceCache
M.getRaceCache = getRaceCache
M.normalizeRaceRouteType = normalizeRaceRouteType
M.routeTypeMatches = routeTypeMatches
M.inferRouteTypeFromRaceLabel = inferRouteTypeFromRaceLabel
M.resolveTargetTimeForTier = resolveTargetTimeForTier
M.buildSponsorRequirement = buildSponsorRequirement

return M
