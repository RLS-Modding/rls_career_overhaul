-- Builds auction lots: draws catalogue vehicles under an auction type's filter and wraps each as a lot with a start bid.
-- Read config/state, filter matching and catalog enrichment, then lot building, cache reset and the public API.
local M = {}
M.schemaVersion = 2
local stockOverrides = require('overhaul/lib/vehicles/stockVehicleOverrides')

-- Config ------------------------------------------------------------------------------------------

local fallbackPool = {
  { model = 'covet', config = '/vehicles/covet/covet_tutorial.pc', title = 'Ibishu Covet', basePrice = 2600 },
  { model = 'hopper', config = '/vehicles/hopper/classic.pc', title = 'Ibishu Hopper', basePrice = 4200 },
  { model = 'wendover', config = '/vehicles/wendover/se_v6_A.pc', title = 'Gavril Wendover', basePrice = 6400 }
}

local MILES_TO_METERS = 1609.344
-- Catalogue mileage above this is metres, not miles.
local CATALOG_MILEAGE_AS_METERS_THRESHOLD = 2000000

local MAX_AUCTION_MILES = 300000
local BASE_ANNUAL_MILES = 11500
local MIN_BID_STEP = 250
local ROLLER_LIKE_NAME = 'roller'
local BLOCKED_RACE_PHRASES = { 'race', 'rally', 'drag', 'drift', 'nascar', 'track car', 'cup car' }
local FORKLIFT_MARKERS = { 'forklift', 'forktruck', 'wheelloader', 'telehandler', 'blockforks', 'palletforks' }

local auctionMileageProfiles = {
  default = { annualMiles = 9000, minFactor = 0.55, maxFactor = 1.35, minMiles = 500, maxMiles = 300000, timeCapsuleChance = 0.015 },
  anything_goes = { annualMiles = 9000, minFactor = 0.55, maxFactor = 1.45, minMiles = 500, maxMiles = 300000, timeCapsuleChance = 0.015 },
  budget = { annualMiles = 13000, minFactor = 1.15, maxFactor = 1.75, minMiles = 100000, maxMiles = 250000 },
  salvage_special = { minFactor = 1.35, maxFactor = 2.00, minMiles = 150000, maxMiles = 300000 },
  vintage = { annualMiles = 6500, minFactor = 0.20, maxFactor = 0.65, minMiles = 20000, maxMiles = 160000, timeCapsuleChance = 0.05 },
  truck_night = { annualMiles = 16000, minFactor = 0.85, maxFactor = 1.35, minMiles = 40000, maxMiles = 300000 },
  touge_nights = { minFactor = 0.60, maxFactor = 1.25, minMiles = 10000, maxMiles = 220000 },
  autobahn_after_dark = { minFactor = 0.60, maxFactor = 1.25, minMiles = 10000, maxMiles = 220000 },
  american_allstars = { minFactor = 0.65, maxFactor = 1.35, minMiles = 10000, maxMiles = 250000 },
  modern_daily = { minFactor = 0.70, maxFactor = 1.25, minMiles = 3000, maxMiles = 120000 },
  sports_weekend = { minFactor = 0.45, maxFactor = 1.05, minMiles = 5000, maxMiles = 140000 },
  work_fleet = { annualMiles = 22000, minFactor = 0.85, maxFactor = 1.35, minMiles = 70000, maxMiles = 300000 },
  rare_finds = { minFactor = 0.45, maxFactor = 1.05, minMiles = 10000, maxMiles = 160000, timeCapsuleChance = 0.03 },
  high_rollers = { minFactor = 0.20, maxFactor = 0.65, minMiles = 2000, maxMiles = 80000, timeCapsuleChance = 0.05 }
}

local sharedAuctionFilters
local function defaultFilters()
  if not sharedAuctionFilters then
    local data = jsonReadFile('/gameplay/overhaul/market/auctionFilters.json')
    if type(data) ~= 'table' or data.version ~= 1 or type(data.filter) ~= 'table' then
      log('W', 'auctionLots', 'Shared auction filter policy unavailable')
      return nil
    end
    sharedAuctionFilters = data
  end
  return sharedAuctionFilters
end

local auctionTypes = {
  anything_goes = {
    whiteList = {
      Years = { min = 1950 },
      Mileage = { min = 10000, max = 300000 }
    }
  },
  budget = {
    whiteList = {
      Value = { min = 1, max = 30000 },
      Mileage = { min = 100000, max = 250000 },
      Years = { min = 1980, max = 2019 }
    }
  },
  salvage_special = {
    whiteList = {
      ['Config Type'] = { 'joesjunkcar' },
      Mileage = { min = 150000, max = 300000 }
    }
  },
  vintage = {
    whiteList = {
      Type = { 'Car' },
      ['Config Type'] = { 'Factory', 'Custom' },
      Years = { min = 1900, max = 1980 }
    }
  },
  truck_night = {
    whiteList = {
      ['Body Style'] = { 'Van', 'SUV', 'Pickup' },
      Years = { min = 1995 },
      Mileage = { min = 70000, max = 300000 }
    }
  },
  touge_nights = {
    whiteList = {
      Country = { 'Japan' },
      Type = { 'Car' },
      Years = { min = 1980 },
      Mileage = { min = 10000, max = 220000 }
    }
  },
  autobahn_after_dark = {
    whiteList = {
      Country = {
        'Poland',
        'Italy',
        'France',
        'Germany',
        'Sweden',
        'United Kingdom',
        'Soviet Union/Russia',
        'Great Britain',
        'The Netherlands'
      },
      Type = { 'Car' },
      Years = { min = 1980 },
      Mileage = { min = 10000, max = 220000 }
    }
  },
  american_allstars = {
    whiteList = {
      Country = { 'United States' },
      Type = { 'Car', 'Truck' },
      Years = { min = 1950 },
      Mileage = { min = 10000, max = 250000 }
    }
  },
  modern_daily = {
    whiteList = {
      ['Config Type'] = { 'Factory' },
      Value = { min = 10000, max = 80000 },
      Years = { min = 2015 },
      Mileage = { min = 10000, max = 120000 }
    },
    blackList = {
      model_key = { 'wydra', 'wl40' },
      Type = { 'Trailer', 'Semi Truck', 'Forklift', 'ATV', 'Bus' },
      ['Body Style'] = { 'ATV', 'Forklift' },
      ['Body Type'] = { 'ATV', 'Forklift' }
    }
  },
  sports_weekend = {
    whiteList = {
      ['Body Style'] = { 'Coupe', 'Roadster' },
      Value = { min = 25000, max = 150000 },
      Years = { min = 1990 },
      Mileage = { min = 10000, max = 120000 }
    }
  },
  work_fleet = {
    whiteList = {
      Type = { 'Truck', 'Semi Truck', 'Forklift' },
      ['Config Type'] = { 'Factory', 'Service' },
      Years = { min = 1980 },
      Mileage = { min = 70000, max = 300000 }
    },
    blackList = {
      model_key = { 'wydra' },
      Type = { 'Trailer' },
      ['Config Type'] = { 'Roller', 'Race', 'Rally', 'Drag', 'Drift', 'Police', 'Frame' }
    }
  },
  rare_finds = {
    whiteList = {
      Population = { min = 1, max = 500 },
      Type = { 'Car', 'Truck' },
      ['Config Type'] = { 'Factory', 'Custom' },
      Value = { min = 20000 },
      Years = { min = 1950 }
    }
  },
  high_rollers = {
    whiteList = {
      Type = { 'Car' },
      ['Config Type'] = { 'Factory' },
      Years = { min = 2000 }
    }
  }
}

-- State -------------------------------------------------------------------------------------------

-- Configs and high-roller models used this session; resetUsedConfigs clears them per batch.
local usedConfigKeys = {}
local usedHighRollerModelCounts = {}
local enrichedEligibleVehicleCache
local highRollerLookupCache

-- Shared helpers ----------------------------------------------------------------------------------

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
  return math.random(10000, 300000)
end

local function roundToNearestStep(value, step)
  local safeStep = math.max(1, tonumber(step) or 1)
  local normalized = math.max(0, tonumber(value) or 0) / safeStep
  return math.floor(normalized + 0.5) * safeStep
end

local function normalizeToken(value)
  if value == nil then
    return ''
  end
  return tostring(value):lower():gsub('[^%w]', '')
end

local function isRangeParams(parameters)
  return type(parameters) == 'table' and (parameters.min ~= nil or parameters.max ~= nil)
end

-- Filter definitions ------------------------------------------------------------------------------

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

-- Custom filters keep the default blacklist: a discrete default list is merged into any custom one.
local function mergeAuctionBlacklistWithDefaults(customFilter)
  local normalized = normalizeFilterDefinition(customFilter or {})
  normalized.blackList = normalized.blackList or {}
  local defBl =
    normalizeFilterDefinition((defaultFilters() or {}).filter or {}).blackList or
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

local function filterConfigValid(cfg)
  if type(cfg) ~= 'table' or type(cfg.filter) ~= 'table' then return false end
  for _, key in ipairs({'whiteList', 'blackList'}) do
    if cfg.filter[key] ~= nil and type(cfg.filter[key]) ~= 'table' then return false end
  end
  if cfg.subFilters ~= nil then
    if type(cfg.subFilters) ~= 'table' then return false end
    for _, sub in ipairs(cfg.subFilters) do
      if type(sub) ~= 'table' or (sub.filter ~= nil and type(sub.filter) ~= 'table') then return false end
    end
  end
  return true
end

-- Filters belong to this auction's level. The shared catalog explicitly permits a neutral default.
local function getAuctionFilterConfig(facility)
  local level = getCurrentLevelIdentifier()
  if not level or level == '' then
    log('W', 'auctionLots', 'Auction inventory requires an owner level')
    return nil
  end
  local defaults = defaultFilters()
  if not defaults then return nil end
  local file = facility and facility.filtersFile or 'auction.filters.json'
  local path = require('overhaul/lib/world/levelData').assetPath(level, file)
  local cfg = path and jsonReadFile(path)
  if not filterConfigValid(cfg) then
    log('W', 'auctionLots', 'Auction filters unavailable or invalid: ' .. tostring(path))
    if not defaults.useWhenLocalMissing then return nil end
    cfg = defaults
  end
  cfg = deepCopy(cfg)
  cfg.filter = mergeAuctionBlacklistWithDefaults(cfg.filter)
  return cfg
end

local function buildWeightedFilters(facility)
  local cfg = getAuctionFilterConfig(facility)
  if not cfg then return {} end
  local baseFilter = normalizeFilterDefinition(cfg.filter or {})
  local subFilters = cfg.subFilters or {}

  local weighted = {}
  if #subFilters == 0 then
    local filter = deepCopy(baseFilter)
    filter._auctionTypeId = 'default'
    return {{prob = 1, filter = filter}}
  end

  for _, subFilter in ipairs(subFilters) do
    local body = getSubFilterBody(subFilter)
    local probability = tonumber(subFilter.probability)
      or tonumber(subFilter._probability)
      or tonumber(body.probability)
      or tonumber(body._probability)
      or 1
    local mergedFilter = mergeAuctionBlacklistWithDefaults(mergeFilter(baseFilter, subFilter))
    mergedFilter._auctionTypeId = 'default'
    table.insert(weighted, {prob = math.max(0.01, probability), filter = mergedFilter})
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

local function buildRelaxedFallbackFilter(filter)
  return normalizeFilterDefinition(filter)
end

-- The selection drops mileage limits: lots get their mileage from the auction type instead.
local function buildSelectionFilter(filter)
  local selection = normalizeFilterDefinition(filter)
  for key in pairs(selection.whiteList or {}) do
    if normalizeToken(key) == 'mileage' then
      selection.whiteList[key] = nil
    end
  end
  return selection
end

-- Vehicle identity --------------------------------------------------------------------------------

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
  return a:find(ROLLER_LIKE_NAME, 1, true) or b:find(ROLLER_LIKE_NAME, 1, true) or c:find(ROLLER_LIKE_NAME, 1, true)
end

-- Reads a catalogue field, falling back to the aggregated row it was merged from.
local function readVehicleField(info, name)
  local value = info[name]
  if value ~= nil then
    return value
  end
  if type(info.aggregates) == 'table' then
    return info.aggregates[name]
  end
end

-- ATVs, FPU and Wydra models are never auctioned, whichever field names them.
local function isBlockedByCatalogIdentity(info)
  local modelKey = normalizeToken(info.model_key or info.modelKey or info.Model or info.model)
  local brand = normalizeToken(readVehicleField(info, 'Brand') or readVehicleField(info, 'Make') or info.brand or info.make)
  local typeName = normalizeToken(readVehicleField(info, 'Type') or readVehicleField(info, 'Vehicle Type'))
  local bodyStyle = normalizeToken(readVehicleField(info, 'Body Style') or readVehicleField(info, 'BodyStyle')
    or readVehicleField(info, 'Body Type') or readVehicleField(info, 'BodyType'))
  return modelKey == 'wydra' or modelKey == 'atv' or brand == 'fpu' or typeName == 'atv' or bodyStyle == 'atv'
end

-- Race and rally configs are blocked by word, so 'Grace' or 'Trace' are not caught.
local function hasBlockedRacePhrase(info)
  local identity = string.lower(table.concat({
    tostring(info.model_key or info.modelKey or ''),
    tostring(info.key or ''),
    tostring(info.Configuration or ''),
    tostring(info.Name or ''),
    tostring(info['Config Type'] or '')
  }, ' '))
  for _, blockedPhrase in ipairs(BLOCKED_RACE_PHRASES) do
    if string.find(identity, '%f[%a]' .. blockedPhrase) then
      return true
    end
  end
  return false
end

local function containsWydra(value)
  return normalizeToken(value):find('wydra', 1, true) ~= nil
end

local function hasWydraIdentity(info)
  return containsWydra(info.key) or containsWydra(info.Configuration) or containsWydra(info.Name) or
    containsWydra(info.model_key) or containsWydra(info.modelKey) or containsWydra(info.Model) or
    containsWydra(info.model) or containsWydra(readVehicleField(info, 'Brand')) or
    containsWydra(readVehicleField(info, 'Make')) or containsWydra(readVehicleField(info, 'Type')) or
    containsWydra(readVehicleField(info, 'Vehicle Type')) or containsWydra(readVehicleField(info, 'Body Style')) or
    containsWydra(readVehicleField(info, 'BodyStyle')) or containsWydra(readVehicleField(info, 'Body Type')) or
    containsWydra(readVehicleField(info, 'BodyType'))
end

local function isBlockedAuctionVehicleInfo(info)
  if type(info) ~= 'table' then
    return true
  end
  return isBlockedByCatalogIdentity(info) or hasBlockedRacePhrase(info) or hasWydraIdentity(info)
end

-- Mileage -----------------------------------------------------------------------------------------

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

-- Gaussian-ish draw in [0, 1): the mean of three uniforms.
local function randomGauss3()
  return (math.random() + math.random() + math.random()) / 3
end

local function getExpectedAuctionMileage(age, annualMiles)
  local safeAge = math.max(0, tonumber(age) or 0)
  local yearlyMiles = tonumber(annualMiles) or BASE_ANNUAL_MILES
  if safeAge <= 25 then
    return safeAge * yearlyMiles
  end
  return 25 * yearlyMiles + (safeAge - 25) * math.min(yearlyMiles, 2500)
end

-- Sets the lot's mileage from its age and its auction type's profile, with the time-capsule chance.
local function applyLotMileageFromFilter(lot, filter)
  if type(lot) ~= 'table' then
    return lot
  end

  local typeId = type(filter) == 'table' and filter._auctionTypeId or 'default'
  local profile = auctionMileageProfiles[typeId] or auctionMileageProfiles.default
  local currentYear = getCurrentYear()
  local age = math.max(0, currentYear - (tonumber(lot.year) or currentYear))

  if age >= 25 and math.random() < (tonumber(profile.timeCapsuleChance) or 0) then
    lot.mileage = math.floor(5000 + randomGauss3() * 15000)
    lot.mileageClass = 'timeCapsule'
    lot.auctionTypeId = typeId
    return lot
  end

  local expected = getExpectedAuctionMileage(age, profile.annualMiles)
  local minFactor = tonumber(profile.minFactor) or 0.70
  local maxFactor = tonumber(profile.maxFactor) or 1.55
  local miles = expected * (minFactor + randomGauss3() * (maxFactor - minFactor))

  if age == 0 then
    miles = 50 + math.random() * 1950
  elseif age >= 15 then
    miles = math.max(miles, tonumber(profile.minMiles) or 5000)
  end

  local minMiles = tonumber(profile.minMiles) or 0
  local maxMiles = math.min(MAX_AUCTION_MILES, tonumber(profile.maxMiles) or MAX_AUCTION_MILES)
  miles = math.max(minMiles, math.min(maxMiles, miles))
  if miles >= maxMiles then
    local compressionBand = math.min(30000, maxMiles * 0.25)
    miles = math.max(minMiles, maxMiles - math.random() * compressionBand)
  end

  lot.mileage = math.max(0, math.floor(miles + 0.5))
  lot.mileageClass = 'ageCurve'
  lot.auctionTypeId = typeId
  return lot
end

-- Catalogue years ---------------------------------------------------------------------------------

-- Catalogue spellings of each filter field, tried after the field's own name.
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

-- Filter matching ---------------------------------------------------------------------------------

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

-- True when the number lies within whichever bounds are set.
local function isWithinBounds(number, minAllowed, maxAllowed)
  if minAllowed and number < minAllowed then
    return false
  end
  if maxAllowed and number > maxAllowed then
    return false
  end
  return true
end

-- A car matches a year range when its own years overlap the allowed range.
local function matchesYearsRule(vehicleInfo, parameters)
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

local function matchesMileageRule(vehicleInfo, filterName, parameters)
  local miles = rawMileageToMiles(getVehicleFieldValue(vehicleInfo, filterName))
  if miles == nil then
    return false
  end
  return isWithinBounds(miles, mileageRangeBoundToMiles(parameters.min), mileageRangeBoundToMiles(parameters.max))
end

local function matchesRangeRule(vehicleInfo, filterName, parameters)
  local value = getVehicleFieldValue(vehicleInfo, filterName)
  local numberValue = tonumber(value)
  if numberValue == nil and type(value) == 'table' then
    numberValue = tonumber(value.min) or tonumber(value.max)
  end
  if numberValue == nil then
    return false
  end
  return isWithinBounds(numberValue, tonumber(parameters.min), tonumber(parameters.max))
end

local function matchesDiscreteRule(vehicleInfo, filterName, parameters)
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

local function doesVehicleMatchFilterRule(vehicleInfo, filterName, parameters)
  if filterName == 'Years' then
    return matchesYearsRule(vehicleInfo, parameters)
  end
  if normalizeToken(filterName) == 'mileage' and isRangeParams(parameters) then
    return matchesMileageRule(vehicleInfo, filterName, parameters)
  end
  if isRangeParams(parameters) then
    return matchesRangeRule(vehicleInfo, filterName, parameters)
  end
  return matchesDiscreteRule(vehicleInfo, filterName, parameters)
end

-- requireAll: every rule must match (whitelist). Otherwise any rule matching is enough (blacklist).
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

-- Catalogue enrichment and special selection ------------------------------------------------------

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

local function getAuctionVehicleTrackingKey(info)
  return tostring(info and info.model_key or '') .. '::' .. tostring(info and info.key or '')
end

local function enrichAuctionVehicleInfo(sourceInfo)
  local info = shallowCopyVehicleInfo(sourceInfo)
  local rawCatalogValue = tonumber(info.Value) or 0
  local profile = overhaul_career_market_valueCalculator.getVehicleCatalogProfile(info.model_key, info.key, info)

  info.rawCatalogValue = rawCatalogValue
  info.effectiveCatalogValue = profile and tonumber(profile.catalogValue) or rawCatalogValue
  info.haloScore = profile and tonumber(profile.haloScore) or 0
  info.auctionCatalogSource = profile and profile.catalogSource or 'configFallback'
  if info.effectiveCatalogValue > 0 then
    info.Value = info.effectiveCatalogValue
  end
  return info
end

-- The top 20% of each model's factory cars (at least one, at most five) qualify for high rollers.
local function buildHighRollerLookup(eligibleVehicles)
  local modelGroups = {}
  for _, info in ipairs(eligibleVehicles or {}) do
    local _, maxYear = getVehicleYearRange(info)
    local configTypes = getVehicleFieldValue(info, 'Config Type')
    local vehicleTypes = getVehicleFieldValue(info, 'Type')
    local isFactory = isDiscreteMatch(configTypes, 'Factory')
    local isCar = isDiscreteMatch(vehicleTypes, 'Car')
    local value = math.max(tonumber(info.effectiveCatalogValue) or 0, tonumber(info.rawCatalogValue) or 0)
    local halo = tonumber(info.haloScore) or 0

    if isFactory and isCar and maxYear and maxYear >= 2000 and not isBlockedAuctionVehicleInfo(info)
        and (value >= 45000 or (value >= 35000 and halo >= 0.75)) then
      local modelKey = tostring(info.model_key)
      modelGroups[modelKey] = modelGroups[modelKey] or {}
      table.insert(modelGroups[modelKey], {
        key = getAuctionVehicleTrackingKey(info),
        score = value * (1 + 0.35 * halo)
      })
    end
  end

  local lookup = {}
  for _, configs in pairs(modelGroups) do
    table.sort(configs, function(a, b)
      if a.score == b.score then return a.key < b.key end
      return a.score > b.score
    end)
    local selectedCount = math.max(1, math.min(5, math.ceil(#configs * 0.20)))
    for rank = 1, selectedCount do
      lookup[configs[rank].key] = true
    end
  end
  return lookup
end

-- Built once per session from the catalogue; invalidateVehicleCache rebuilds it.
local function getEnrichedEligibleVehicles()
  if enrichedEligibleVehicleCache then
    return enrichedEligibleVehicleCache
  end

  enrichedEligibleVehicleCache = {}
  for _, info in ipairs(stockOverrides.getEligibleVehicles(false, false)) do
    table.insert(enrichedEligibleVehicleCache, enrichAuctionVehicleInfo(info))
  end
  highRollerLookupCache = buildHighRollerLookup(enrichedEligibleVehicleCache)
  return enrichedEligibleVehicleCache
end

local function isForkliftLikeAuctionVehicle(info)
  if type(info) ~= 'table' then
    return false
  end

  local modelToken = normalizeToken(info.model_key or info.modelKey)
  if modelToken == 'wl40' then
    return true
  end

  local identityValues = {
    modelToken,
    info.key,
    info.config_key,
    info.configKey,
    info.Name,
    info.name,
    info.Configuration,
    info.configuration,
    getVehicleFieldValue(info, 'Type'),
    getVehicleFieldValue(info, 'Body Style'),
    getVehicleFieldValue(info, 'Body Type')
  }

  for _, value in pairs(identityValues) do
    local token = normalizeToken(value)
    for _, marker in ipairs(FORKLIFT_MARKERS) do
      if string.find(token, marker, 1, true) then
        return true
      end
    end
  end
  return false
end

-- Semis, forklifts, buses and trailers stay out of every type except work fleet.
local function isExcludedHeavyVehicle(info)
  local modelToken = normalizeToken(info.model_key or info.modelKey)
  local typeToken = normalizeToken(getVehicleFieldValue(info, 'Type'))
  local bodyToken = normalizeToken(getVehicleFieldValue(info, 'Body Style')
    or getVehicleFieldValue(info, 'Body Type'))
  return isForkliftLikeAuctionVehicle(info)
    or modelToken == 'ussemi'
    or string.find(modelToken, 'semi', 1, true) ~= nil
    or typeToken == 'semitruck' or typeToken == 'forklift' or typeToken == 'bus' or typeToken == 'trailer'
    or bodyToken == 'semitruck' or bodyToken == 'forklift' or bodyToken == 'bus' or bodyToken == 'trailer'
end

local function countHighRollerModel(info)
  local modelKey = tostring(info.model_key)
  usedHighRollerModelCounts[modelKey] = (usedHighRollerModelCounts[modelKey] or 0) + 1
end

local function doesVehiclePassAuctionSpecialSelection(info, filter)
  local typeId = type(filter) == 'table' and filter._auctionTypeId or nil
  if typeId ~= 'work_fleet' and isExcludedHeavyVehicle(info) then
    return false
  end

  if typeId == 'high_rollers' then
    local value = math.max(tonumber(info.effectiveCatalogValue) or 0, tonumber(info.rawCatalogValue) or 0)
    if (usedHighRollerModelCounts[tostring(info.model_key)] or 0) >= 2 then
      return false
    end
    return value >= 100000 or (highRollerLookupCache and highRollerLookupCache[getAuctionVehicleTrackingKey(info)])
  end
  if typeId == 'rare_finds' then
    local value = math.max(tonumber(info.effectiveCatalogValue) or 0, tonumber(info.rawCatalogValue) or 0)
    local population = tonumber(info.Population) or math.huge
    local halo = tonumber(info.haloScore) or 0
    return value >= 20000 and (population <= 200 or halo >= 0.50)
  end
  return true
end

-- Lot building -----------------------------------------------------------------------------------

-- Turns a catalogue row into a vehicle def: name, config path, base price, mileage and a year in range.
local function buildVehicleDefFromInfo(info, configPath, filter)
  local brand = tostring(info.Brand or '')
  local name = tostring(info.Name or info.key or info.model_key)
  local title = ((brand ~= '' and (brand .. ' ') or '') .. name)
  local yearMin, yearMax = getVehicleYearRange(info)
  local normalizedFilter = normalizeFilterDefinition(filter)
  local filterYears = normalizedFilter.whiteList and normalizedFilter.whiteList.Years or nil
  if type(filterYears) == 'table' then
    yearMin = math.max(yearMin or tonumber(filterYears.min) or getCurrentYear(),
      tonumber(filterYears.min) or yearMin or getCurrentYear())
    yearMax = math.min(yearMax or tonumber(filterYears.max) or yearMin,
      tonumber(filterYears.max) or yearMax or yearMin)
  end
  if not yearMin or not yearMax or yearMin > yearMax then
    yearMin, yearMax = getVehicleYearRange(info)
  end
  local currentYear = getCurrentYear()
  yearMin = math.min(tonumber(yearMin) or currentYear, currentYear)
  yearMax = math.min(tonumber(yearMax) or currentYear, currentYear)
  if yearMin > yearMax then yearMin = yearMax end
  local selectedYear = yearMin and yearMax and math.random(yearMin, yearMax) or getCurrentYear()

  return {
    model = info.model_key,
    config = configPath,
    title = title,
    basePrice = math.max(1500, math.floor(tonumber(info.Value or 4500))),
    mileage = getMileageFromInfo(info) or getFallbackMileage(),
    year = selectedYear or tonumber(info.Year) or tonumber(info.year) or getCurrentYear(),
    rawCatalogValue = tonumber(info.rawCatalogValue),
    effectiveCatalogValue = tonumber(info.effectiveCatalogValue),
    haloScore = tonumber(info.haloScore) or 0,
    auctionCatalogSource = info.auctionCatalogSource,
    population = tonumber(info.Population)
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

-- Rare finds weight each car by 1 / population, so scarce models come up more often.
local function withInversePopulationWeights(vehicles)
  local weighted = {}
  for _, vehicle in ipairs(vehicles or {}) do
    local copy = shallowCopyVehicleInfo(vehicle)
    local population = math.max(1, tonumber(copy.Population) or 1)
    copy._auctionSpawnWeight = math.max(1, math.min(2000000, math.floor(2000000 / population)))
    table.insert(weighted, copy)
  end
  return weighted
end

-- Returns a vehicle def for the first candidate that passes every check and has an unused config.
local function tryBuildVehicleDef(info, normalizedFilter)
  if isBlockedAuctionVehicleInfo(info)
      or not doesVehiclePassAuctionFilter(info, normalizedFilter)
      or not doesVehiclePassAuctionSpecialSelection(info, normalizedFilter) then
    return nil
  end
  local configPath = getVehicleConfigPath(info)
  if not configPath or usedConfigKeys[configPath] or isRollerLikeInfo(info) then
    return nil
  end

  usedConfigKeys[configPath] = true
  if normalizedFilter._auctionTypeId == 'high_rollers' then
    countHighRollerModel(info)
  end
  return buildVehicleDefFromInfo(info, configPath, normalizedFilter)
end

-- The engine proposes candidates by filter; if none survives, every catalogue car is tried in random order.
local function getRandomVehicleDefWithFilter(filter, sampleCount)
  local eligibleVehicles = getEnrichedEligibleVehicles()
  local normalizedFilter = buildSelectionFilter(filter or {})
  local safeCount = math.max(1, math.floor(tonumber(sampleCount) or 140))
  local vehiclesForInfos = eligibleVehicles
  local popKey = nil
  if normalizedFilter._auctionSpawnInversePopulation then
    popKey = '_auctionSpawnWeight'
    vehiclesForInfos = withInversePopulationWeights(eligibleVehicles)
  end
  local infos = util_configListGenerator.getRandomVehicleInfos({ filter = normalizedFilter }, safeCount, vehiclesForInfos, popKey)

  for _, info in ipairs(infos or {}) do
    local vehicleDef = tryBuildVehicleDef(info, normalizedFilter)
    if vehicleDef then return vehicleDef end
  end

  local n = #(eligibleVehicles or {})
  if n > 0 then
    local order = shuffleIndicesInclusive(n)
    for k = 1, n do
      local vehicleDef = tryBuildVehicleDef(eligibleVehicles[order[k]], normalizedFilter)
      if vehicleDef then return vehicleDef end
    end
  end

  return nil
end

local function buildLotFromVehicleDef(vehicleDef, lotIndex, spawnSpot, blockSpot)
  local minStep = MIN_BID_STEP
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
    rawCatalogValue = vehicleDef.rawCatalogValue,
    effectiveCatalogValue = vehicleDef.effectiveCatalogValue,
    haloScore = vehicleDef.haloScore,
    auctionCatalogSource = vehicleDef.auctionCatalogSource,
    population = vehicleDef.population,
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

-- Lifecycle ---------------------------------------------------------------------------------------

function M.resetUsedConfigs()
  clearTable(usedConfigKeys)
  clearTable(usedHighRollerModelCounts)
end

function M.invalidateVehicleCache()
  enrichedEligibleVehicleCache = nil
  highRollerLookupCache = nil
end

-- Library state lasts one career session: usedCarAuction resets it when it unloads.
function M.resetState()
  M.resetUsedConfigs()
  M.invalidateVehicleCache()
  sharedAuctionFilters = nil
end

-- Public API --------------------------------------------------------------------------------------

function M.getSafetyAuctionFilter()
  return normalizeFilterDefinition({
    whiteList = {},
    blackList = deepCopy((((defaultFilters() or {}).filter or {}).blackList) or {})
  })
end

function M.composeAuctionTypeFilter(typeId, facility)
  local cfg = getAuctionFilterConfig(facility)
  if not cfg then return nil end
  local typeDef = auctionTypes[typeId]
  if typeDef == nil then
    return nil
  end
  local base = facility and facility.filtersApplyToTypes and cfg.filter or M.getSafetyAuctionFilter()
  local merged = mergeFilter(base, {
    whiteList = deepCopy(typeDef.whiteList),
    blackList = deepCopy(typeDef.blackList)
  })
  if typeId == 'rare_finds' then
    merged._auctionSpawnInversePopulation = true
  end
  merged._auctionTypeId = typeId
  return merged
end

M.getAuctionFilterConfig = getAuctionFilterConfig

function M.buildNextLotEntry(lotIndex, spawnSpots, blockSpots, fixedFilter, facility)
  if not getAuctionFilterConfig(facility) then return nil end
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
    lotFilter = pickWeightedFilter(buildWeightedFilters(facility))
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

function M.buildLotBatch(startLotIndex, lotCount, spawnSpots, blockSpots, fixedFilter, facility)
  local batch = {}
  local safeStartIndex = math.max(1, math.floor(tonumber(startLotIndex) or 1))
  local safeCount = math.max(1, math.floor(tonumber(lotCount) or 1))

  M.resetUsedConfigs()

  for offset = 0, safeCount - 1 do
    local lot = M.buildNextLotEntry(safeStartIndex + offset, spawnSpots, blockSpots, fixedFilter, facility)
    if not lot then
      break
    end
    table.insert(batch, lot)
  end

  return batch
end

return M
