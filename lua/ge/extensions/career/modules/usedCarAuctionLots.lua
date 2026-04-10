local M = {}

M.dependencies = {
  'util_configListGenerator'
}

local fallbackPool = {
  { model = 'covet', config = '/vehicles/covet/covet_tutorial.pc', title = 'Ibishu Covet', basePrice = 2600 },
  { model = 'hopper', config = '/vehicles/hopper/classic.pc', title = 'Ibishu Hopper', basePrice = 4200 },
  { model = 'wendover', config = '/vehicles/wendover/se_v6_A.pc', title = 'Gavril Wendover', basePrice = 6400 }
}

local MILES_TO_METERS = 1609.344
local CATALOG_MILEAGE_AS_METERS_THRESHOLD = 2000000

local defaultWeightedSubFilterMileage = { min = 4800, max = 16093 }

local defaultAuctionFilters = {
  filter = {
    whiteList = {
      Mileage = { min = 25000000, max = 380000000 }
    },
    blackList = {
      Type = { 'Trailer', 'Semi Truck' },
      ['Config Type'] = { 'Roller', 'Race', 'Police', 'Service' }
    }
  },
  subFilters = {
    { probability = 7, whiteList = { Mileage = defaultWeightedSubFilterMileage, Years = { min = 2010, max = 2025 } } },
    { probability = 6, whiteList = { Mileage = defaultWeightedSubFilterMileage, Years = { min = 2000, max = 2009 } } },
    { probability = 5, whiteList = { Mileage = defaultWeightedSubFilterMileage, Years = { min = 1990, max = 1999 } } },
    { probability = 4, whiteList = { Mileage = defaultWeightedSubFilterMileage, Years = { min = 1980, max = 1989 } } },
    { probability = 3, whiteList = { Mileage = defaultWeightedSubFilterMileage, Years = { min = 1970, max = 1979 } } },
    { probability = 2, whiteList = { Mileage = defaultWeightedSubFilterMileage, Years = { min = 1950, max = 1969 } } },
    { probability = 1, whiteList = { Mileage = defaultWeightedSubFilterMileage, Years = { min = 1900, max = 1949 } } }
  }
}

local auctionTypes = {
  anything_goes = {
    whiteList = {
      Years = { min = 1950 },
      Mileage = { min = 5000, max = 180000 }
    }
  },
  budget = {
    whiteList = {
      Value = { min = 1, max = 50000 },
      Mileage = { min = 100000, max = 250000 },
      Years = { min = 1980, max = 2015 }
    }
  },
  vintage = {
    whiteList = {
      Years = { min = 1900, max = 1980 },
      Mileage = { min = 500, max = 25000 }
    }
  },
  truck_night = {
    whiteList = {
      ['Body Style'] = { 'Van', 'SUV', 'Pickup' },
      Years = { min = 1985 },
      Mileage = { min = 20000, max = 180000 }
    }
  },
  rare_finds = {
    whiteList = {
      Population = { min = 1, max = 500 },
      Years = { min = 1990 },
      Mileage = { min = 3000, max = 90000 }
    }
  },
  high_rollers = {
    whiteList = {
      Value = { min = 100000, max = 10000000 },
      Years = { min = 2000 },
      Mileage = { min = 2000, max = 20000 }
    }
  }
}

local usedConfigKeys = {}

local function clearTable(target)
  for key in pairs(target) do
    target[key] = nil
  end
end

local function deepCopy(src)
  if type(src) ~= 'table' then
    return src
  end

  local out = {}
  for key, value in pairs(src) do
    out[key] = deepCopy(value)
  end
  return out
end

local function getCurrentYear()
  return tonumber(os.date('%Y')) or 2025
end

local function getFallbackMileage()
  return math.random(5000, 180000)
end

local function roundToNearestStep(value, step)
  local safeStep = math.max(1, tonumber(step) or 1)
  local normalized = math.max(0, tonumber(value) or 0) / safeStep
  return math.floor(normalized + 0.5) * safeStep
end

local function getFilterLists(filter)
  if type(filter) ~= 'table' then
    return {}, {}
  end

  local whiteList = filter.whiteList or filter.whitelist or filter.white_list or {}
  local blackList = filter.blackList or filter.blacklist or filter.black_list or {}
  return whiteList, blackList
end

local function normalizeFilterDefinition(filter)
  local normalized = deepCopy(type(filter) == 'table' and filter or {})
  local whiteList, blackList = getFilterLists(normalized)
  normalized.whiteList = deepCopy(whiteList or {})
  normalized.blackList = deepCopy(blackList or {})
  normalized.whitelist = nil
  normalized.white_list = nil
  normalized.blacklist = nil
  normalized.black_list = nil
  return normalized
end

local function isDiscreteListParams(parameters)
  return type(parameters) == 'table' and parameters.min == nil and parameters.max == nil
end

local function mergeDiscreteListsUnique(a, b)
  local seen, out = {}, {}
  for _, lst in ipairs({ a, b }) do
    for _, v in ipairs(lst or {}) do
      local k = tostring(v)
      if not seen[k] then
        seen[k] = true
        table.insert(out, v)
      end
    end
  end
  return out
end

local function mergeAuctionBlacklistWithDefaults(customFilter)
  local normalized = normalizeFilterDefinition(customFilter or {})
  normalized.blackList = normalized.blackList or {}
  local defBl =
    normalizeFilterDefinition(type(defaultAuctionFilters.filter) == 'table' and defaultAuctionFilters.filter or {}).blackList or
    {}
  for key, defParams in pairs(defBl) do
    if isDiscreteListParams(defParams) then
      local cur = normalized.blackList[key]
      if cur == nil then
        normalized.blackList[key] = deepCopy(defParams)
      elseif isDiscreteListParams(cur) then
        normalized.blackList[key] = mergeDiscreteListsUnique(defParams, cur)
      end
    end
  end
  return normalized
end

local function getSubFilterBody(subFilter)
  if type(subFilter) ~= 'table' then
    return {}
  end
  if type(subFilter.filter) == 'table' then
    return subFilter.filter
  end
  return subFilter
end

local function mergeFilter(baseFilter, subFilter)
  local merged = normalizeFilterDefinition(baseFilter)
  local normalizedSubFilter = normalizeFilterDefinition(getSubFilterBody(subFilter))

  for key, value in pairs(normalizedSubFilter.whiteList or {}) do
    merged.whiteList[key] = deepCopy(value)
  end
  for key, value in pairs(normalizedSubFilter.blackList or {}) do
    merged.blackList[key] = deepCopy(value)
  end

  return merged
end

local function getAuctionFilterConfig()
  local level = getCurrentLevelIdentifier() or 'west_coast_usa'
  local path = '/levels/' .. level .. '/auction.filters.json'
  local cfg = jsonReadFile(path)

  if type(cfg) == 'table' then
    cfg = deepCopy(cfg)
    cfg.filter = mergeAuctionBlacklistWithDefaults(cfg.filter)
    return cfg
  end

  return deepCopy(defaultAuctionFilters)
end

local function buildWeightedFilters()
  local cfg = getAuctionFilterConfig()
  local baseFilter = normalizeFilterDefinition(cfg.filter or {})
  local subFilters = cfg.subFilters or {}

  local weighted = {}
  if #subFilters == 0 then
    table.insert(weighted, {prob = 1, filter = deepCopy(baseFilter)})
    return weighted
  end

  for _, subFilter in ipairs(subFilters) do
    local body = getSubFilterBody(subFilter)
    local probability = tonumber(subFilter.probability)
      or tonumber(subFilter._probability)
      or tonumber(body.probability)
      or tonumber(body._probability)
      or 1

    table.insert(weighted, {
      prob = math.max(0.01, probability),
      filter = mergeFilter(baseFilter, subFilter)
    })
  end

  return weighted
end

local function pickWeightedFilter(weighted)
  if not weighted or #weighted == 0 then
    return {}
  end

  local total = 0
  for _, item in ipairs(weighted) do
    total = total + (item.prob or 1)
  end

  local roll = math.random() * total
  local acc = 0
  for _, item in ipairs(weighted) do
    acc = acc + (item.prob or 1)
    if roll <= acc then
      return item.filter or {}
    end
  end

  return weighted[#weighted].filter or {}
end

local function getVehicleConfigPath(info)
  if not info or not info.model_key or not info.key then
    return nil
  end

  local key = tostring(info.key):gsub('%.pc$', '')
  local candidatePaths = {
    '/vehicles/' .. info.model_key .. '/configurations/' .. key .. '.pc',
    '/vehicles/' .. info.model_key .. '/' .. key .. '.pc'
  }

  for _, path in ipairs(candidatePaths) do
    if FS:fileExists(path) then
      return path
    end
  end

  return nil
end

local function isRollerLikeInfo(info)
  local a = string.lower(tostring(info.key or ''))
  local b = string.lower(tostring(info.Name or ''))
  local c = string.lower(tostring(info['Config Type'] or ''))
  return a:find('roller', 1, true) or b:find('roller', 1, true) or c:find('roller', 1, true)
end

local function rawMileageToMiles(raw)
  local mileage = tonumber(raw)
  if not mileage then
    return nil
  end
  if mileage > CATALOG_MILEAGE_AS_METERS_THRESHOLD then
    mileage = mileage / MILES_TO_METERS
  end
  return math.max(0, mileage)
end

local function getMileageFromInfo(info)
  local mileage = rawMileageToMiles(info and (tonumber(info.Mileage) or tonumber(info.mileage) or tonumber(info['Mileage'])))
  if not mileage or mileage <= 0 then
    return nil
  end
  return math.floor(mileage)
end

local function isRangeParams(parameters)
  return type(parameters) == 'table' and (parameters.min ~= nil or parameters.max ~= nil)
end

local function normalizeToken(value)
  if value == nil then
    return ''
  end
  return tostring(value):lower():gsub('[^%w]', '')
end

local filterFieldAliases = {
  bodytype = { 'Body Type', 'BodyType', 'Body Style', 'BodyStyle' },
  bodystyle = { 'Body Style', 'BodyStyle', 'Body Type', 'BodyType' },
  configtype = { 'Config Type', 'ConfigType' },
  type = { 'Type', 'Vehicle Type', 'VehicleType' },
  brand = { 'Brand', 'Make' },
  years = { 'Years', 'Year' },
  mileage = { 'Mileage', 'mileage' }
}

local function getFilterFieldCandidates(fieldName)
  local candidates = {}
  local seen = {}

  local function addCandidate(value)
    if value == nil then
      return
    end

    local key = tostring(value)
    if key == '' or seen[key] then
      return
    end
    seen[key] = true
    table.insert(candidates, key)
  end

  addCandidate(fieldName)
  local aliases = filterFieldAliases[normalizeToken(fieldName)]
  if type(aliases) == 'table' then
    for _, alias in ipairs(aliases) do
      addCandidate(alias)
    end
  end

  return candidates
end

local function getLooseTableField(source, fieldName)
  if type(source) ~= 'table' then
    return nil
  end

  local value = source[fieldName]
  if value ~= nil then
    return value
  end

  local wantedKey = normalizeToken(fieldName)
  for key, item in pairs(source) do
    if normalizeToken(key) == wantedKey then
      return item
    end
  end

  return nil
end

local function getVehicleFieldValue(vehicleInfo, fieldName)
  if type(vehicleInfo) ~= 'table' then
    return nil
  end

  local candidates = getFilterFieldCandidates(fieldName)
  for _, candidate in ipairs(candidates) do
    local value = getLooseTableField(vehicleInfo, candidate)
    if value ~= nil then
      return value
    end
  end

  if type(vehicleInfo.aggregates) == 'table' then
    for _, candidate in ipairs(candidates) do
      local value = getLooseTableField(vehicleInfo.aggregates, candidate)
      if value ~= nil then
        return value
      end
    end
  end

  return nil
end

local function boundsFromYearTable(years)
  if type(years) ~= 'table' then
    return nil, nil
  end

  local minYear = tonumber(years.min) or tonumber(years[1])
  local maxYear = tonumber(years.max) or minYear
  if not minYear then
    return nil, nil
  end
  if not maxYear then
    maxYear = minYear
  end
  if minYear > maxYear then
    minYear, maxYear = maxYear, minYear
  end
  return minYear, maxYear
end

local function getVehicleYearRange(vehicleInfo)
  if type(vehicleInfo) ~= 'table' then
    return nil, nil
  end
  local years = vehicleInfo.Years or (vehicleInfo.aggregates and vehicleInfo.aggregates.Years) or getVehicleFieldValue(vehicleInfo, 'Years')
  if type(years) == 'number' then
    return years, years
  end
  return boundsFromYearTable(years)
end

local function isDiscreteMatch(value, wanted)
  if value == wanted then
    return true
  end
  if normalizeToken(value) ~= '' and normalizeToken(value) == normalizeToken(wanted) then
    return true
  end
  if type(value) ~= 'table' then
    return false
  end
  if value[wanted] then return true end
  if value[tostring(wanted)] then return true end
  if value[normalizeToken(wanted)] then return true end

  local wantedToken = normalizeToken(wanted)
  for key, keyed in pairs(value) do
    if keyed and normalizeToken(key) == wantedToken then
      return true
    end
  end
  for _, item in ipairs(value) do
    if item == wanted or (normalizeToken(item) ~= '' and normalizeToken(item) == wantedToken) then
      return true
    end
  end
  return false
end

local function mileageRangeBoundToMiles(bound)
  local n = tonumber(bound)
  if not n then
    return nil
  end
  if n > CATALOG_MILEAGE_AS_METERS_THRESHOLD then
    return n / MILES_TO_METERS
  end
  return n
end

local function doesVehicleMatchFilterRule(vehicleInfo, filterName, parameters)
  if filterName == 'Years' then
    local minYear, maxYear = getVehicleYearRange(vehicleInfo)
    if not minYear then
      return false
    end
    local minAllowed = tonumber(parameters and parameters.min)
    local maxAllowed = tonumber(parameters and parameters.max)
    if minAllowed and maxYear < minAllowed then
      return false
    end
    if maxAllowed and minYear > maxAllowed then
      return false
    end
    return true
  end

  if normalizeToken(filterName) == 'mileage' and isRangeParams(parameters) then
    local value = getVehicleFieldValue(vehicleInfo, filterName)
    local miles = rawMileageToMiles(value)
    if miles == nil then
      return false
    end
    local minAllowed = mileageRangeBoundToMiles(parameters.min)
    local maxAllowed = mileageRangeBoundToMiles(parameters.max)
    if minAllowed and miles < minAllowed then
      return false
    end
    if maxAllowed and miles > maxAllowed then
      return false
    end
    return true
  end

  if isRangeParams(parameters) then
    local value = getVehicleFieldValue(vehicleInfo, filterName)
    local numberValue = tonumber(value)
    if numberValue == nil and type(value) == 'table' then
      numberValue = tonumber(value.min) or tonumber(value.max)
    end
    if numberValue == nil then
      return false
    end

    local minAllowed = tonumber(parameters.min)
    local maxAllowed = tonumber(parameters.max)
    if minAllowed and numberValue < minAllowed then
      return false
    end
    if maxAllowed and numberValue > maxAllowed then
      return false
    end
    return true
  end

  local value = getVehicleFieldValue(vehicleInfo, filterName)
  if type(parameters) ~= 'table' then
    return isDiscreteMatch(value, parameters)
  end

  for _, wanted in ipairs(parameters) do
    if isDiscreteMatch(value, wanted) then
      return true
    end
  end
  return false
end

local function doesVehicleMatchFilterList(vehicleInfo, filters, requireAll)
  if type(filters) ~= 'table' or next(filters) == nil then
    return requireAll and true or false
  end

  for filterName, parameters in pairs(filters) do
    local matched = doesVehicleMatchFilterRule(vehicleInfo, filterName, parameters)
    if requireAll then
      if not matched then
        return false
      end
    elseif matched then
      return true
    end
  end

  return requireAll and true or false
end

local function doesVehiclePassAuctionFilter(vehicleInfo, filter)
  local normalized = normalizeFilterDefinition(filter)
  if not doesVehicleMatchFilterList(vehicleInfo, normalized.whiteList, true) then
    return false
  end
  if doesVehicleMatchFilterList(vehicleInfo, normalized.blackList, false) then
    return false
  end
  return true
end

local function buildRelaxedFallbackFilter(filter)
  return normalizeFilterDefinition(filter)
end

local function buildSelectionFilter(filter)
  local selection = normalizeFilterDefinition(filter)
  for key in pairs(selection.whiteList or {}) do
    if normalizeToken(key) == 'mileage' then
      selection.whiteList[key] = nil
    end
  end
  return selection
end

local function getMileageRangeFromFilter(filter)
  local normalized = normalizeFilterDefinition(filter)
  for key, value in pairs(normalized.whiteList or {}) do
    if normalizeToken(key) == 'mileage' and isRangeParams(value) then
      return value
    end
  end
end

local function applyLotMileageFromFilter(lot, filter)
  if type(lot) ~= 'table' then
    return lot
  end
  local mileageRange = getMileageRangeFromFilter(filter)
  if not mileageRange then
    return lot
  end

  local minAllowed = mileageRangeBoundToMiles(mileageRange.min)
  local maxAllowed = mileageRangeBoundToMiles(mileageRange.max)
  minAllowed = math.max(0, math.floor(tonumber(minAllowed) or 0))
  maxAllowed = math.max(minAllowed, math.floor(tonumber(maxAllowed) or minAllowed))
  lot.mileage = math.random(minAllowed, maxAllowed)
  return lot
end

local function buildVehicleDefFromInfo(info, configPath)
  local brand = tostring(info.Brand or '')
  local name = tostring(info.Name or info.key or info.model_key)
  local title = ((brand ~= '' and (brand .. ' ') or '') .. name)

  return {
    model = info.model_key,
    config = configPath,
    title = title,
    basePrice = math.max(1500, math.floor(tonumber(info.Value or 4500))),
    mileage = getMileageFromInfo(info) or getFallbackMileage(),
    year = tonumber(info.Year) or tonumber(info.year) or (function()
      local yMin, yMax = boundsFromYearTable(info.Years)
      if yMin and yMax then
        return math.random(yMin, yMax)
      end
    end)() or getCurrentYear()
  }
end

local function shuffleIndicesInclusive(n)
  local order = {}
  for i = 1, n do
    order[i] = i
  end
  for i = n, 2, -1 do
    local j = math.random(i)
    order[i], order[j] = order[j], order[i]
  end
  return order
end

local function shallowCopyVehicleInfo(src)
  if type(src) ~= 'table' then
    return src
  end
  local out = {}
  for k, v in pairs(src) do
    out[k] = v
  end
  return out
end

local function getRandomVehicleDefWithFilter(filter, sampleCount)
  local eligibleVehicles = util_configListGenerator.getEligibleVehicles(false, false)
  local normalizedFilter = buildSelectionFilter(filter or {})
  local safeCount = math.max(1, math.floor(tonumber(sampleCount) or 140))
  local filterSet = { filter = normalizedFilter }
  local popKey = 'Population'
  local vehiclesForInfos = eligibleVehicles
  if normalizedFilter._auctionSpawnInversePopulation then
    popKey = '_auctionSpawnWeight'
    vehiclesForInfos = {}
    for _, v in ipairs(eligibleVehicles or {}) do
      local w = shallowCopyVehicleInfo(v)
      local p = math.max(1, tonumber(w.Population) or 1)
      w._auctionSpawnWeight = math.max(1, math.min(2000000, math.floor(2000000 / p)))
      table.insert(vehiclesForInfos, w)
    end
  end
  local infos = util_configListGenerator.getRandomVehicleInfos(filterSet, safeCount, vehiclesForInfos, popKey)

  for _, info in ipairs(infos or {}) do
    if doesVehiclePassAuctionFilter(info, normalizedFilter) then
      local configPath = getVehicleConfigPath(info)
      if configPath and (not usedConfigKeys[configPath]) and (not isRollerLikeInfo(info)) then
        usedConfigKeys[configPath] = true
        return buildVehicleDefFromInfo(info, configPath)
      end
    end
  end

  local n = #(eligibleVehicles or {})
  if n > 0 then
    local order = shuffleIndicesInclusive(n)
    for k = 1, n do
      local info = eligibleVehicles[order[k]]
      if doesVehiclePassAuctionFilter(info, normalizedFilter) then
        local configPath = getVehicleConfigPath(info)
        if configPath and (not usedConfigKeys[configPath]) and (not isRollerLikeInfo(info)) then
          usedConfigKeys[configPath] = true
          return buildVehicleDefFromInfo(info, configPath)
        end
      end
    end
  end

  return nil
end

local function buildLotFromVehicleDef(vehicleDef, lotIndex, spawnSpot, blockSpot)
  local minStep = 250
  local startBid = roundToNearestStep(vehicleDef.basePrice * (0.55 + math.random() * 0.2), 500)

  return {
    lotIndex = lotIndex,
    spawnSpot = spawnSpot,
    blockSpot = blockSpot,
    model = vehicleDef.model,
    config = vehicleDef.config,
    title = vehicleDef.title,
    basePrice = vehicleDef.basePrice,
    mileage = vehicleDef.mileage or getFallbackMileage(),
    year = vehicleDef.year or getCurrentYear(),
    minStep = minStep,
    currentBid = startBid,
    previewStartBid = startBid,
    highestBidder = 'npc',
    highestBidderName = 'NPC',
    leadingNpcPersonaId = nil,
    npcMaxBidsByPersonaId = {},
    npcPersonaNamesById = {},
    extensionCount = 0,
    endTime = 0,
    state = 'pending',
    vehId = nil,
    wonByPlayer = false,
    wonInventoryId = nil,
    driveState = nil,
    driveStartedAt = 0,
    lastMotionPos = nil,
    lastMotionAt = 0,
    nextApproachControlAt = 0
  }
end

function M.resetUsedConfigs()
  clearTable(usedConfigKeys)
end

function M.getSafetyAuctionFilter()
  return normalizeFilterDefinition({
    whiteList = {},
    blackList = deepCopy(((defaultAuctionFilters.filter or {}).blackList) or {})
  })
end

function M.composeAuctionTypeFilter(typeId)
  local typeDef = auctionTypes[typeId]
  if typeDef == nil then
    return nil
  end
  local merged = mergeFilter(M.getSafetyAuctionFilter(), {
    whiteList = deepCopy(typeDef.whiteList)
  })
  if typeId == 'rare_finds' then
    merged._auctionSpawnInversePopulation = true
  end
  return merged
end

function M.buildNextLotEntry(lotIndex, spawnSpots, blockSpots, fixedFilter)
  local spawnCount = #(spawnSpots or {})
  if spawnCount <= 0 then
    return nil
  end

  local safeLotIndex = math.max(1, math.floor(tonumber(lotIndex) or 1))
  local blockCount = #(blockSpots or {})
  local spawnSpot = spawnSpots[((safeLotIndex - 1) % spawnCount) + 1]
  local blockSpot = spawnSpot
  if blockCount > 0 then
    blockSpot = blockSpots[((safeLotIndex - 1) % blockCount) + 1]
  end

  local lotFilter = normalizeFilterDefinition(fixedFilter)
  if next(lotFilter.whiteList) == nil and next(lotFilter.blackList) == nil then
    local weightedFilters = buildWeightedFilters()
    lotFilter = pickWeightedFilter(weightedFilters)
  end
  local vehicleDef = getRandomVehicleDefWithFilter(lotFilter)
  if not vehicleDef then
    vehicleDef = getRandomVehicleDefWithFilter(buildRelaxedFallbackFilter(lotFilter))
  end
  if not vehicleDef then
    vehicleDef = fallbackPool[math.random(1, #fallbackPool)]
  end

  local lot = buildLotFromVehicleDef(vehicleDef, safeLotIndex, spawnSpot, blockSpot)
  applyLotMileageFromFilter(lot, lotFilter)
  return lot
end

function M.buildLotBatch(startLotIndex, lotCount, spawnSpots, blockSpots, fixedFilter)
  local batch = {}
  local safeStartIndex = math.max(1, math.floor(tonumber(startLotIndex) or 1))
  local safeCount = math.max(1, math.floor(tonumber(lotCount) or 1))

  M.resetUsedConfigs()

  for offset = 0, safeCount - 1 do
    local lot = M.buildNextLotEntry(safeStartIndex + offset, spawnSpots, blockSpots, fixedFilter)
    if not lot then
      break
    end
    table.insert(batch, lot)
  end

  return batch
end

return M
