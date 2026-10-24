-- Shared logistics rules from logisticsXP.config.json.
-- Read defaults, section sanitizers, loading, then public rule queries.
local M = {}

-- Config ------------------------------------------------------------------------------------------

local CONFIG_PATH = "/gameplay/overhaul/delivery/logisticsXP.config.json"
local LOG_TAG = "delivery.logisticsXPConfig"

local VALID_ROUND_MODES = { round = true, ceil = true, floor = true }
local VALID_MATERIAL_TYPES = { fluid = true, dryBulk = true, cement = true, cash = true }
local VALID_TRAILER_XP_GROUPS = {
  small = true, medium = true, heavyHitch = true, dryvan = true, flatbed = true,
  dump = true, tanker = true, container = true, log = true,
}
local VALID_VEHICLE_XP_TAGS = {
  junkerVeh = true, smallVeh = true, fleetVeh = true, highEndVeh = true,
  exoticVeh = true, heavyVeh = true, largeVeh = true,
}

local DEFAULT_CONFIG = {
  version = 1,
  rounding = { moneyFinal = "round" },
  levelBonus = { moneyPercentPerLevel = 0 },
  parcel = {
    baseXP = 2,
    slotMilestones = { 16, 32, 64 },
    slotXPBySize = {},
    distanceDivisor = 800,
    reputationDistanceDivisor = 1000,
    distanceRounding = "round",
    reputationDistanceRounding = "round",
  },
  vehicleTrailer = {
    baseXP = 5,
    vehicleXPByTag = {},
    trailerXPByUnlockGroup = {},
    trailerXPByUnlockLevel = {},
    trailerMoneyMultiplierByUnlockGroup = {},
    moneyDistanceDivisor = 1000,
    xpDistanceDivisor = 400,
    reputationDistanceDivisor = 2000,
    moneyDistanceRounding = "round",
    xpDistanceRounding = "round",
    reputationDistanceRounding = "round",
  },
  materials = {
    baseXP = 3,
    baseXPByType = {},
    moneyBaseFactor = 0.35,
    moneyFactorPerKm = 0.2,
    distanceDivisor = 2000,
    distanceOffset = -1,
    slotsDivisor = 400,
    xpRounding = "round",
  },
  materialContracts = {
    initialOffersPerFacility = 2,
    maxOffersPerFacility = 3,
    offerDuration = 900,
    refillInterval = 300,
    abandonPenaltyFactor = 0.15,
    bulkLoadCount = { min = 2, max = 6 },
    bulkLoadWeights = { ["2"] = 2, ["3"] = 4, ["4"] = 4, ["5"] = 1, ["6"] = 0.5 },
    secureLoadCount = { min = 1, max = 3 },
    standardLoadByType = { fluid = 17000, dryBulk = 15600, cement = 7800 },
    tripLoadsByType = {
      fluid = { 4000, 7400 },
      dryBulk = { 4800, 12000 },
      cement = { 6000 },
    },
    employmentTrips = { preferred = 4, max = 6 },
    standardLoadByMaterial = { cash = 500, coin = 100, gold = 250 },
    stockCycleSecondsPerLoad = 900,
  },
  precisionParking = {
    thresholds = { perfect = 20, great = 15, good = 10, bad = 5 },
    score = {
      angleWorst = 7.5,
      angleBest = 1.6,
      toleranceSpaceFactor = 0.3,
      sideToleranceMin = 0.3,
      forwardToleranceMin = 0.4,
      toleranceFloorFactor = 0.3,
      sideToleranceFloorMin = 0.1,
      forwardToleranceFloorMin = 0.15,
      scoreScale = 6,
      scoreOffset = 2,
      scoreCap = 20,
      scoreRounding = "round",
    },
    rewardRounding = "floor",
    rewards = {
      perfect = {
        moneyFlat = 30, moneyPercent = 0.25,
        logisticsFlat = 10, logisticsPercent = 0.2,
        skillFlat = 5, skillPercent = 0.15,
        reputationFlat = 5, reputationPercent = 0.2,
      },
      great = {
        moneyFlat = 20, moneyPercent = 0.15,
        logisticsFlat = 5, logisticsPercent = 0.15,
        skillFlat = 5, skillPercent = 0.1,
        reputationFlat = 2, reputationPercent = 0.15,
      },
      good = {
        moneyFlat = 10, moneyPercent = 0.1,
        logisticsFlat = 5, logisticsPercent = 0.1,
        skillFlat = 3, skillPercent = 0.05,
        reputationFlat = 0, reputationPercent = 0,
      },
      bad = {
        moneyFlat = 0, moneyPercent = 0,
        logisticsFlat = 0, logisticsPercent = 0,
        skillFlat = 0, skillPercent = 0,
        reputationFlat = 0, reputationPercent = 0,
      },
      horrible = {
        moneyFlat = 0, moneyPercent = 0,
        logisticsFlat = 0, logisticsPercent = 0,
        skillFlat = 0, skillPercent = 0,
        reputationFlat = 0, reputationPercent = 0,
      },
    },
  },
  beamEats = {
    baseXP = 24,
    distanceDivisor = 400,
    xpRounding = "round",
    streakTiers = {
      { maxStreak = 5, xp = 4 },
      { maxStreak = 15, xp = 6 },
      { maxStreak = 20, xp = 10 },
      { maxStreak = 30, xp = 12 },
      { maxStreak = 40, xp = 16 },
      { maxStreak = 45, xp = 20 },
      { maxStreak = 999999, xp = 30 },
    },
  },
}

-- State -------------------------------------------------------------------------------------------

local cachedConfig

-- Helpers -----------------------------------------------------------------------------------------

local function deepCopyTable(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for k, v in pairs(value) do
    result[k] = deepCopyTable(v)
  end
  return result
end

local function isFiniteNumber(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function appendIssue(issues, message)
  issues[#issues + 1] = message
end

-- Returns a section table, or records it as missing and returns nil so the caller keeps defaults.
local function requireSection(rawSection, label, issues)
  if type(rawSection) ~= "table" then
    appendIssue(issues, label .. " section missing; using defaults")
    return nil
  end
  return rawSection
end

local function readNumber(rawValue, defaultValue, minValue, maxValue, label, issues)
  if not isFiniteNumber(rawValue) then
    appendIssue(issues, string.format("%s is invalid; using default %s", label, tostring(defaultValue)))
    return defaultValue
  end
  if minValue ~= nil and rawValue < minValue then
    appendIssue(issues, string.format("%s (%s) is below min %s; using default %s", label, tostring(rawValue), tostring(minValue), tostring(defaultValue)))
    return defaultValue
  end
  if maxValue ~= nil and rawValue > maxValue then
    appendIssue(issues, string.format("%s (%s) is above max %s; using default %s", label, tostring(rawValue), tostring(maxValue), tostring(defaultValue)))
    return defaultValue
  end
  return rawValue
end

local function readRoundMode(rawValue, defaultValue, label, issues)
  if type(rawValue) ~= "string" or not VALID_ROUND_MODES[rawValue] then
    appendIssue(issues, string.format("%s is invalid; using default '%s'", label, defaultValue))
    return defaultValue
  end
  return rawValue
end

local function applyRounding(value, mode)
  local safeMode = mode
  if not VALID_ROUND_MODES[safeMode] then
    safeMode = "round"
  end
  if safeMode == "ceil" then
    return math.ceil(value)
  end
  if safeMode == "floor" then
    return math.floor(value)
  end
  return round(value)
end

-- Validation: shared map and list readers ---------------------------------------------------------

local function sanitizeMilestones(rawValue, defaults, label, issues)
  if type(rawValue) ~= "table" then
    appendIssue(issues, string.format("%s is invalid; using default thresholds", label))
    return deepCopyTable(defaults)
  end

  local collected = {}
  for i, value in ipairs(rawValue) do
    local n = readNumber(value, nil, 1, nil, string.format("%s[%d]", label, i), issues)
    if n then
      collected[#collected + 1] = math.floor(n)
    end
  end

  if #collected == 0 then
    appendIssue(issues, string.format("%s has no valid entries; using default thresholds", label))
    return deepCopyTable(defaults)
  end

  table.sort(collected)
  local deduped = {}
  local last
  for _, value in ipairs(collected) do
    if value ~= last then
      deduped[#deduped + 1] = value
      last = value
    end
  end
  return deduped
end

local function sanitizeSlotXPBySize(rawValue, defaults, label, issues)
  if rawValue == nil then
    return deepCopyTable(defaults)
  end

  if type(rawValue) ~= "table" then
    appendIssue(issues, string.format("%s is invalid; using default slot XP tiers", label))
    return deepCopyTable(defaults)
  end

  local collected = {}
  for rawSlots, rawXP in pairs(rawValue) do
    local slotThreshold = tonumber(rawSlots)
    if not isFiniteNumber(slotThreshold) or slotThreshold < 1 or slotThreshold ~= math.floor(slotThreshold) then
      appendIssue(issues, string.format("%s[%s] has an invalid slot threshold; skipping", label, tostring(rawSlots)))
    else
      local tierXP = readNumber(rawXP, nil, 0, nil, string.format("%s[%s]", label, tostring(rawSlots)), issues)
      if tierXP ~= nil then
        collected[#collected + 1] = { slots = slotThreshold, xp = tierXP }
      end
    end
  end

  if #collected == 0 then
    appendIssue(issues, string.format("%s has no valid entries; using default slot XP tiers", label))
    return deepCopyTable(defaults)
  end

  table.sort(collected, function(a, b) return a.slots < b.slots end)

  local deduped = {}
  local lastSlot = nil
  for _, tier in ipairs(collected) do
    if tier.slots == lastSlot then
      deduped[#deduped].xp = tier.xp
    else
      deduped[#deduped + 1] = tier
      lastSlot = tier.slots
    end
  end

  return deduped
end

local function sanitizeNumericXPByLevel(rawValue, defaults, label, issues)
  if rawValue == nil then
    return deepCopyTable(defaults)
  end

  if type(rawValue) ~= "table" then
    appendIssue(issues, string.format("%s is invalid; using default values", label))
    return deepCopyTable(defaults)
  end

  local result = {}
  for rawLevel, rawXP in pairs(rawValue) do
    local level = tonumber(rawLevel)
    if not isFiniteNumber(level) or level < 0 or level ~= math.floor(level) then
      appendIssue(issues, string.format("%s[%s] has an invalid level key; skipping", label, tostring(rawLevel)))
    else
      local xpValue = readNumber(rawXP, nil, 0, nil, string.format("%s[%s]", label, tostring(rawLevel)), issues)
      if xpValue ~= nil then
        result[tostring(level)] = xpValue
      end
    end
  end

  if not next(result) then
    return deepCopyTable(defaults)
  end

  return result
end

-- Copies defaults, then overrides each key of an allowed-key map that the raw table provides.
local function sanitizeKeyedValues(rawValue, defaults, allowedKeys, label, issues)
  local result = deepCopyTable(defaults)
  if rawValue == nil then
    return result
  end

  if type(rawValue) ~= "table" then
    appendIssue(issues, string.format("%s is invalid; using default values", label))
    return result
  end

  for rawKey, rawXP in pairs(rawValue) do
    if not allowedKeys[rawKey] then
      appendIssue(issues, string.format("%s.%s is unknown; skipping", label, tostring(rawKey)))
    else
      local defaultXP = result[rawKey] or 0
      result[rawKey] = readNumber(rawXP, defaultXP, 0, nil, string.format("%s.%s", label, rawKey), issues)
    end
  end

  return result
end

local function sanitizeMaterialTypeXP(rawValue, defaults, label, issues)
  return sanitizeKeyedValues(rawValue, defaults, VALID_MATERIAL_TYPES, label, issues)
end

local function sanitizeTrailerXPByUnlockGroup(rawValue, defaults, label, issues)
  return sanitizeKeyedValues(rawValue, defaults, VALID_TRAILER_XP_GROUPS, label, issues)
end

local function sanitizeVehicleXPByTag(rawValue, defaults, label, issues)
  return sanitizeKeyedValues(rawValue, defaults, VALID_VEHICLE_XP_TAGS, label, issues)
end

local function sanitizeStreakTiers(rawValue, defaults, label, issues)
  if type(rawValue) ~= "table" then
    appendIssue(issues, string.format("%s is invalid; using default streak tiers", label))
    return deepCopyTable(defaults)
  end

  local tiers = {}
  for i, entry in ipairs(rawValue) do
    if type(entry) == "table" then
      local maxStreak = readNumber(entry.maxStreak, nil, 1, nil, string.format("%s[%d].maxStreak", label, i), issues)
      local xp = readNumber(entry.xp, nil, 0, nil, string.format("%s[%d].xp", label, i), issues)
      if maxStreak and xp then
        tiers[#tiers + 1] = { maxStreak = math.floor(maxStreak), xp = xp }
      end
    end
  end

  if #tiers == 0 then
    appendIssue(issues, string.format("%s has no valid entries; using default streak tiers", label))
    return deepCopyTable(defaults)
  end

  table.sort(tiers, function(a, b) return a.maxStreak < b.maxStreak end)
  return tiers
end

local function sanitizeRewards(rawRewards, defaults, label, issues)
  local result = deepCopyTable(defaults)
  if type(rawRewards) ~= "table" then
    appendIssue(issues, string.format("%s is invalid; using default reward values", label))
    return result
  end

  for levelName, defaultValues in pairs(defaults) do
    local src = rawRewards[levelName]
    if type(src) ~= "table" then
      appendIssue(issues, string.format("%s.%s is invalid; using defaults", label, levelName))
    else
      for rewardKey, defaultValue in pairs(defaultValues) do
        result[levelName][rewardKey] = readNumber(src[rewardKey], defaultValue, nil, nil, string.format("%s.%s.%s", label, levelName, rewardKey), issues)
      end
    end
  end

  return result
end

local function sanitizeThresholds(rawThresholds, defaults, label, issues)
  local result = deepCopyTable(defaults)
  if type(rawThresholds) ~= "table" then
    appendIssue(issues, string.format("%s is invalid; using default thresholds", label))
    return result
  end

  result.perfect = readNumber(rawThresholds.perfect, defaults.perfect, 0, nil, label .. ".perfect", issues)
  result.great = readNumber(rawThresholds.great, defaults.great, 0, nil, label .. ".great", issues)
  result.good = readNumber(rawThresholds.good, defaults.good, 0, nil, label .. ".good", issues)
  result.bad = readNumber(rawThresholds.bad, defaults.bad, 0, nil, label .. ".bad", issues)

  if not (result.perfect >= result.great and result.great >= result.good and result.good >= result.bad) then
    appendIssue(issues, string.format("%s ordering is invalid; using default thresholds", label))
    return deepCopyTable(defaults)
  end

  return result
end

-- Validation: one sanitizer per config section, applied in this order -----------------------------

local function sanitizeRounding(cfg, rawConfig, issues)
  local rawRounding = requireSection(rawConfig.rounding, "rounding", issues)
  if rawRounding then
    cfg.rounding.moneyFinal = readRoundMode(rawRounding.moneyFinal, DEFAULT_CONFIG.rounding.moneyFinal, "rounding.moneyFinal", issues)
  end
end

local function sanitizeLevelBonus(cfg, rawConfig, issues)
  local rawLevelBonus = rawConfig.levelBonus
  if rawLevelBonus == nil then
    appendIssue(issues, "levelBonus section missing; using defaults")
  elseif type(rawLevelBonus) ~= "table" then
    appendIssue(issues, "levelBonus section invalid; using defaults")
  else
    cfg.levelBonus.moneyPercentPerLevel = readNumber(rawLevelBonus.moneyPercentPerLevel, DEFAULT_CONFIG.levelBonus.moneyPercentPerLevel, 0, nil, "levelBonus.moneyPercentPerLevel", issues)
  end
end

local function sanitizeParcel(cfg, rawConfig, issues)
  local rawParcel = requireSection(rawConfig.parcel, "parcel", issues)
  if not rawParcel then return end
  local defaults = DEFAULT_CONFIG.parcel
  cfg.parcel.baseXP = readNumber(rawParcel.baseXP, defaults.baseXP, 0, nil, "parcel.baseXP", issues)
  cfg.parcel.slotMilestones = sanitizeMilestones(rawParcel.slotMilestones, defaults.slotMilestones, "parcel.slotMilestones", issues)
  cfg.parcel.slotXPBySize = sanitizeSlotXPBySize(rawParcel.slotXPBySize, defaults.slotXPBySize, "parcel.slotXPBySize", issues)
  cfg.parcel.distanceDivisor = readNumber(rawParcel.distanceDivisor, defaults.distanceDivisor, 1, nil, "parcel.distanceDivisor", issues)
  cfg.parcel.reputationDistanceDivisor = readNumber(rawParcel.reputationDistanceDivisor, defaults.reputationDistanceDivisor, 1, nil, "parcel.reputationDistanceDivisor", issues)
  cfg.parcel.distanceRounding = readRoundMode(rawParcel.distanceRounding, defaults.distanceRounding, "parcel.distanceRounding", issues)
  cfg.parcel.reputationDistanceRounding = readRoundMode(rawParcel.reputationDistanceRounding, defaults.reputationDistanceRounding, "parcel.reputationDistanceRounding", issues)
end

local function sanitizeVehicleTrailer(cfg, rawConfig, issues)
  local rawVehicle = requireSection(rawConfig.vehicleTrailer, "vehicleTrailer", issues)
  if not rawVehicle then return end
  local defaults = DEFAULT_CONFIG.vehicleTrailer
  cfg.vehicleTrailer.baseXP = readNumber(rawVehicle.baseXP, defaults.baseXP, 0, nil, "vehicleTrailer.baseXP", issues)
  cfg.vehicleTrailer.vehicleXPByTag = sanitizeVehicleXPByTag(rawVehicle.vehicleXPByTag, defaults.vehicleXPByTag, "vehicleTrailer.vehicleXPByTag", issues)
  cfg.vehicleTrailer.trailerXPByUnlockGroup = sanitizeTrailerXPByUnlockGroup(rawVehicle.trailerXPByUnlockGroup, defaults.trailerXPByUnlockGroup, "vehicleTrailer.trailerXPByUnlockGroup", issues)
  cfg.vehicleTrailer.trailerXPByUnlockLevel = sanitizeNumericXPByLevel(rawVehicle.trailerXPByUnlockLevel, defaults.trailerXPByUnlockLevel, "vehicleTrailer.trailerXPByUnlockLevel", issues)
  cfg.vehicleTrailer.trailerMoneyMultiplierByUnlockGroup = sanitizeTrailerXPByUnlockGroup(rawVehicle.trailerMoneyMultiplierByUnlockGroup, defaults.trailerMoneyMultiplierByUnlockGroup, "vehicleTrailer.trailerMoneyMultiplierByUnlockGroup", issues)
  cfg.vehicleTrailer.moneyDistanceDivisor = readNumber(rawVehicle.moneyDistanceDivisor, defaults.moneyDistanceDivisor, 1, nil, "vehicleTrailer.moneyDistanceDivisor", issues)
  cfg.vehicleTrailer.xpDistanceDivisor = readNumber(rawVehicle.xpDistanceDivisor, defaults.xpDistanceDivisor, 1, nil, "vehicleTrailer.xpDistanceDivisor", issues)
  cfg.vehicleTrailer.reputationDistanceDivisor = readNumber(rawVehicle.reputationDistanceDivisor, defaults.reputationDistanceDivisor, 1, nil, "vehicleTrailer.reputationDistanceDivisor", issues)
  cfg.vehicleTrailer.moneyDistanceRounding = readRoundMode(rawVehicle.moneyDistanceRounding, defaults.moneyDistanceRounding, "vehicleTrailer.moneyDistanceRounding", issues)
  cfg.vehicleTrailer.xpDistanceRounding = readRoundMode(rawVehicle.xpDistanceRounding, defaults.xpDistanceRounding, "vehicleTrailer.xpDistanceRounding", issues)
  cfg.vehicleTrailer.reputationDistanceRounding = readRoundMode(rawVehicle.reputationDistanceRounding, defaults.reputationDistanceRounding, "vehicleTrailer.reputationDistanceRounding", issues)
end

local function sanitizeMaterials(cfg, rawConfig, issues)
  local rawMaterials = requireSection(rawConfig.materials, "materials", issues)
  if not rawMaterials then return end
  local defaults = DEFAULT_CONFIG.materials
  cfg.materials.baseXP = readNumber(rawMaterials.baseXP, defaults.baseXP, 0, nil, "materials.baseXP", issues)
  cfg.materials.baseXPByType = sanitizeMaterialTypeXP(rawMaterials.baseXPByType, defaults.baseXPByType, "materials.baseXPByType", issues)
  cfg.materials.moneyBaseFactor = readNumber(rawMaterials.moneyBaseFactor, defaults.moneyBaseFactor, 0, nil, "materials.moneyBaseFactor", issues)
  cfg.materials.moneyFactorPerKm = readNumber(rawMaterials.moneyFactorPerKm, defaults.moneyFactorPerKm, 0, nil, "materials.moneyFactorPerKm", issues)
  cfg.materials.distanceDivisor = readNumber(rawMaterials.distanceDivisor, defaults.distanceDivisor, 1, nil, "materials.distanceDivisor", issues)
  cfg.materials.distanceOffset = readNumber(rawMaterials.distanceOffset, defaults.distanceOffset, nil, nil, "materials.distanceOffset", issues)
  cfg.materials.slotsDivisor = readNumber(rawMaterials.slotsDivisor, defaults.slotsDivisor, 1, nil, "materials.slotsDivisor", issues)
  cfg.materials.xpRounding = readRoundMode(rawMaterials.xpRounding, defaults.xpRounding, "materials.xpRounding", issues)
end

-- Offer counts, refill timing and penalty for material contracts.
local function sanitizeContractCounts(contracts, rawContracts, issues)
  local defaults = DEFAULT_CONFIG.materialContracts
  contracts.initialOffersPerFacility = math.floor(readNumber(rawContracts.initialOffersPerFacility, defaults.initialOffersPerFacility, 1, nil, "materialContracts.initialOffersPerFacility", issues))
  contracts.maxOffersPerFacility = math.floor(readNumber(rawContracts.maxOffersPerFacility, defaults.maxOffersPerFacility, 1, nil, "materialContracts.maxOffersPerFacility", issues))
  contracts.initialOffersPerFacility = math.min(contracts.initialOffersPerFacility, contracts.maxOffersPerFacility)
  contracts.offerDuration = readNumber(rawContracts.offerDuration, defaults.offerDuration, 1, nil, "materialContracts.offerDuration", issues)
  contracts.refillInterval = readNumber(rawContracts.refillInterval, defaults.refillInterval, 1, nil, "materialContracts.refillInterval", issues)
  contracts.abandonPenaltyFactor = readNumber(rawContracts.abandonPenaltyFactor, defaults.abandonPenaltyFactor, 0, 1, "materialContracts.abandonPenaltyFactor", issues)
  contracts.stockCycleSecondsPerLoad = readNumber(rawContracts.stockCycleSecondsPerLoad, defaults.stockCycleSecondsPerLoad, 1, nil, "materialContracts.stockCycleSecondsPerLoad", issues)
end

-- Min/max load-count ranges for bulk and secure contracts.
local function sanitizeLoadRanges(contracts, rawContracts, issues)
  local defaults = DEFAULT_CONFIG.materialContracts
  for _, key in ipairs({ "bulkLoadCount", "secureLoadCount" }) do
    local rawRange = rawContracts[key]
    local defaultRange = defaults[key]
    if type(rawRange) == "table" then
      contracts[key].min = math.floor(readNumber(rawRange.min, defaultRange.min, 1, nil, "materialContracts." .. key .. ".min", issues))
      contracts[key].max = math.floor(readNumber(rawRange.max, defaultRange.max, contracts[key].min, nil, "materialContracts." .. key .. ".max", issues))
    else
      appendIssue(issues, "materialContracts." .. key .. " is invalid; using defaults")
    end
  end
end

-- Standard load sizes per cargo type and per material.
local function sanitizeStandardLoads(contracts, rawContracts, issues)
  local defaults = DEFAULT_CONFIG.materialContracts
  for _, key in ipairs({ "standardLoadByType", "standardLoadByMaterial" }) do
    local rawLoads = rawContracts[key]
    if type(rawLoads) == "table" then
      for loadKey, defaultValue in pairs(defaults[key]) do
        contracts[key][loadKey] = readNumber(rawLoads[loadKey], defaultValue, 1, nil, "materialContracts." .. key .. "." .. loadKey, issues)
      end
    else
      appendIssue(issues, "materialContracts." .. key .. " is invalid; using defaults")
    end
  end
end

-- Relative weight of each whole-number load count for bulk contracts.
local function sanitizeBulkLoadWeights(contracts, rawContracts, issues)
  local rawWeights = rawContracts.bulkLoadWeights
  if type(rawWeights) == "table" then
    local weights = {}
    for loadKey, value in pairs(rawWeights) do
      local loads = tonumber(loadKey)
      local weight = readNumber(value, nil, 0, nil, "materialContracts.bulkLoadWeights." .. tostring(loadKey), issues)
      if loads and loads >= 1 and loads % 1 == 0 and weight then
        weights[tostring(loads)] = weight
      end
    end
    if next(weights) then
      contracts.bulkLoadWeights = weights
    else
      appendIssue(issues, "materialContracts.bulkLoadWeights has no valid entries; using defaults")
    end
  elseif rawWeights ~= nil then
    appendIssue(issues, "materialContracts.bulkLoadWeights is invalid; using defaults")
  end
end

-- Sorted trip sizes per cargo type.
local function sanitizeTripLoads(contracts, rawContracts, issues)
  local rawTripLoads = rawContracts.tripLoadsByType
  if type(rawTripLoads) == "table" then
    local tripLoads = {}
    for cargoType, list in pairs(rawTripLoads) do
      local sizes = {}
      if type(list) == "table" then
        for i, value in ipairs(list) do
          local size = readNumber(value, nil, 1, nil, string.format("materialContracts.tripLoadsByType.%s[%d]", tostring(cargoType), i), issues)
          if size then sizes[#sizes + 1] = size end
        end
      else
        appendIssue(issues, "materialContracts.tripLoadsByType." .. tostring(cargoType) .. " is invalid; ignoring")
      end
      table.sort(sizes)
      tripLoads[cargoType] = sizes
    end
    contracts.tripLoadsByType = tripLoads
  elseif rawTripLoads ~= nil then
    appendIssue(issues, "materialContracts.tripLoadsByType is invalid; using defaults")
  end
end

-- Preferred trip count, and a maximum that never falls below the preferred count.
local function sanitizeEmploymentTrips(contracts, rawContracts, issues)
  local rawTrips = rawContracts.employmentTrips
  if type(rawTrips) == "table" then
    local tripDefaults = DEFAULT_CONFIG.materialContracts.employmentTrips
    contracts.employmentTrips.preferred = math.floor(readNumber(rawTrips.preferred, tripDefaults.preferred, 1, nil, "materialContracts.employmentTrips.preferred", issues))
    local preferredTrips = contracts.employmentTrips.preferred
    contracts.employmentTrips.max = math.max(preferredTrips, math.floor(readNumber(rawTrips.max, tripDefaults.max, preferredTrips, nil, "materialContracts.employmentTrips.max", issues)))
  elseif rawTrips ~= nil then
    appendIssue(issues, "materialContracts.employmentTrips is invalid; using defaults")
  end
end

local function sanitizeMaterialContracts(cfg, rawConfig, issues)
  local rawContracts = requireSection(rawConfig.materialContracts, "materialContracts", issues)
  if not rawContracts then return end
  sanitizeContractCounts(cfg.materialContracts, rawContracts, issues)
  sanitizeLoadRanges(cfg.materialContracts, rawContracts, issues)
  sanitizeStandardLoads(cfg.materialContracts, rawContracts, issues)
  sanitizeBulkLoadWeights(cfg.materialContracts, rawContracts, issues)
  sanitizeTripLoads(cfg.materialContracts, rawContracts, issues)
  sanitizeEmploymentTrips(cfg.materialContracts, rawContracts, issues)
end

-- Score tolerances and their floors, used to grade a precision park.
local function sanitizePrecisionScore(precision, rawPrecision, issues)
  local rawScore = requireSection(rawPrecision.score, "precisionParking.score", issues)
  if not rawScore then return end
  local scoreDefaults = DEFAULT_CONFIG.precisionParking.score
  local score = precision.score
  score.angleWorst = readNumber(rawScore.angleWorst, scoreDefaults.angleWorst, 0, nil, "precisionParking.score.angleWorst", issues)
  score.angleBest = readNumber(rawScore.angleBest, scoreDefaults.angleBest, 0, nil, "precisionParking.score.angleBest", issues)
  score.toleranceSpaceFactor = readNumber(rawScore.toleranceSpaceFactor, scoreDefaults.toleranceSpaceFactor, 0, nil, "precisionParking.score.toleranceSpaceFactor", issues)
  score.sideToleranceMin = readNumber(rawScore.sideToleranceMin, scoreDefaults.sideToleranceMin, 0, nil, "precisionParking.score.sideToleranceMin", issues)
  score.forwardToleranceMin = readNumber(rawScore.forwardToleranceMin, scoreDefaults.forwardToleranceMin, 0, nil, "precisionParking.score.forwardToleranceMin", issues)
  score.toleranceFloorFactor = readNumber(rawScore.toleranceFloorFactor, scoreDefaults.toleranceFloorFactor, 0, nil, "precisionParking.score.toleranceFloorFactor", issues)
  score.sideToleranceFloorMin = readNumber(rawScore.sideToleranceFloorMin, scoreDefaults.sideToleranceFloorMin, 0, nil, "precisionParking.score.sideToleranceFloorMin", issues)
  score.forwardToleranceFloorMin = readNumber(rawScore.forwardToleranceFloorMin, scoreDefaults.forwardToleranceFloorMin, 0, nil, "precisionParking.score.forwardToleranceFloorMin", issues)
  score.scoreScale = readNumber(rawScore.scoreScale, scoreDefaults.scoreScale, 0, nil, "precisionParking.score.scoreScale", issues)
  score.scoreOffset = readNumber(rawScore.scoreOffset, scoreDefaults.scoreOffset, nil, nil, "precisionParking.score.scoreOffset", issues)
  score.scoreCap = readNumber(rawScore.scoreCap, scoreDefaults.scoreCap, 1, nil, "precisionParking.score.scoreCap", issues)
  score.scoreRounding = readRoundMode(rawScore.scoreRounding, scoreDefaults.scoreRounding, "precisionParking.score.scoreRounding", issues)
end

local function sanitizePrecisionParking(cfg, rawConfig, issues)
  local rawPrecision = requireSection(rawConfig.precisionParking, "precisionParking", issues)
  if not rawPrecision then return end
  local defaults = DEFAULT_CONFIG.precisionParking
  cfg.precisionParking.rewardRounding = readRoundMode(rawPrecision.rewardRounding, defaults.rewardRounding, "precisionParking.rewardRounding", issues)
  cfg.precisionParking.thresholds = sanitizeThresholds(rawPrecision.thresholds, defaults.thresholds, "precisionParking.thresholds", issues)
  cfg.precisionParking.rewards = sanitizeRewards(rawPrecision.rewards, defaults.rewards, "precisionParking.rewards", issues)
  sanitizePrecisionScore(cfg.precisionParking, rawPrecision, issues)
end

local function sanitizeBeamEats(cfg, rawConfig, issues)
  local rawBeamEats = requireSection(rawConfig.beamEats, "beamEats", issues)
  if not rawBeamEats then return end
  local defaults = DEFAULT_CONFIG.beamEats
  cfg.beamEats.baseXP = readNumber(rawBeamEats.baseXP, defaults.baseXP, 0, nil, "beamEats.baseXP", issues)
  cfg.beamEats.distanceDivisor = readNumber(rawBeamEats.distanceDivisor, defaults.distanceDivisor, 1, nil, "beamEats.distanceDivisor", issues)
  cfg.beamEats.xpRounding = readRoundMode(rawBeamEats.xpRounding, defaults.xpRounding, "beamEats.xpRounding", issues)
  cfg.beamEats.streakTiers = sanitizeStreakTiers(rawBeamEats.streakTiers, defaults.streakTiers, "beamEats.streakTiers", issues)
end

-- Loading -----------------------------------------------------------------------------------------

-- Applies every section sanitizer in order to a copy of the defaults. The result is one snapshot; the issues list explains every value that fell back.
local function sanitizeConfig(rawConfig)
  local issues = {}
  local cfg = deepCopyTable(DEFAULT_CONFIG)

  if type(rawConfig) ~= "table" then
    appendIssue(issues, "Config root is invalid; using defaults")
    return cfg, issues
  end

  cfg.version = readNumber(rawConfig.version, DEFAULT_CONFIG.version, 1, nil, "version", issues)
  sanitizeRounding(cfg, rawConfig, issues)
  sanitizeLevelBonus(cfg, rawConfig, issues)
  sanitizeParcel(cfg, rawConfig, issues)
  sanitizeVehicleTrailer(cfg, rawConfig, issues)
  sanitizeMaterials(cfg, rawConfig, issues)
  sanitizeMaterialContracts(cfg, rawConfig, issues)
  sanitizePrecisionParking(cfg, rawConfig, issues)
  sanitizeBeamEats(cfg, rawConfig, issues)
  return cfg, issues
end

local function loadConfig(forceReload)
  if cachedConfig and not forceReload then
    return cachedConfig
  end

  local rawConfig = jsonReadFile(CONFIG_PATH)
  if type(rawConfig) ~= "table" then
    log("W", LOG_TAG, string.format("Unable to read '%s'. Using built-in defaults.", CONFIG_PATH))
    cachedConfig = deepCopyTable(DEFAULT_CONFIG)
    return cachedConfig
  end

  local cfg, issues = sanitizeConfig(rawConfig)
  cachedConfig = cfg
  for _, issue in ipairs(issues) do
    log("W", LOG_TAG, issue)
  end
  return cachedConfig
end

-- Public API: rules --------------------------------------------------------------------------------

function M.getConfig()
  return loadConfig(false)
end

function M.getParcelRules()
  return loadConfig(false).parcel
end

function M.getVehicleRules()
  return loadConfig(false).vehicleTrailer
end

function M.getMaterialRules()
  return loadConfig(false).materials
end

function M.getMaterialContractRules()
  return loadConfig(false).materialContracts
end

function M.getPrecisionParkingRules()
  return loadConfig(false).precisionParking
end

function M.getLevelBonusRules()
  return loadConfig(false).levelBonus
end

function M.getBeamEatsRules()
  return loadConfig(false).beamEats
end

M.applyRounding = applyRounding

-- getBranchLevel takes a pathId. The attributeKey "logistics-delivery" collides with a legacy 5-level branch and silently returns that branch's level.
M.LOGISTICS_SKILL_PATH_ID = "careerSkills-logistics"
M.LOGISTICS_ATTRIBUTE_KEY = "logistics-delivery"

function M.getLogisticsLevel()
  local skillLookup = require("overhaul/lib/progression/skillLookup")
  -- Assign first; getBranchLevel returns extra values that would become tonumber's base.
  local level = skillLookup.branchLevel(M.LOGISTICS_SKILL_PATH_ID)
  return tonumber(level) or 0
end

function M.reload()
  return loadConfig(true)
end

function M.reset()
  cachedConfig = nil
end

return M
