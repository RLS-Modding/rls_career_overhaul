-- Shared logistics XP config loader/validator
-- Source of truth: /gameplay/delivery/logisticsXP.config.json

local M = {}

local CONFIG_PATH = "/gameplay/delivery/logisticsXP.config.json"
local LOG_TAG = "delivery.logisticsXPConfig"

local VALID_ROUND_MODES = {
  round = true,
  ceil = true,
  floor = true
}

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

local DEFAULT_CONFIG = {
  version = 1,
  rounding = {
    moneyFinal = "round"
  },
  parcel = {
    baseXP = 2,
    slotMilestones = {16, 32, 64},
    distanceDivisor = 800,
    reputationDistanceDivisor = 1000,
    distanceRounding = "round",
    reputationDistanceRounding = "round"
  },
  vehicleTrailer = {
    baseXP = 5,
    moneyDistanceDivisor = 1000,
    xpDistanceDivisor = 400,
    reputationDistanceDivisor = 4000,
    moneyDistanceRounding = "round",
    xpDistanceRounding = "round",
    reputationDistanceRounding = "round"
  },
  materials = {
    baseXP = 3,
    distanceDivisor = 2000,
    distanceOffset = -1,
    slotsDivisor = 400,
    xpRounding = "round"
  },
  precisionParking = {
    thresholds = {
      perfect = 20,
      great = 15,
      good = 10,
      bad = 5
    },
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
      scoreRounding = "round"
    },
    rewardRounding = "floor",
    rewards = {
      perfect = {
        moneyFlat = 30, moneyPercent = 0.25,
        logisticsFlat = 10, logisticsPercent = 0.2,
        skillFlat = 5, skillPercent = 0.15,
        reputationFlat = 5, reputationPercent = 0.2
      },
      great = {
        moneyFlat = 20, moneyPercent = 0.15,
        logisticsFlat = 5, logisticsPercent = 0.15,
        skillFlat = 5, skillPercent = 0.1,
        reputationFlat = 2, reputationPercent = 0.15
      },
      good = {
        moneyFlat = 10, moneyPercent = 0.1,
        logisticsFlat = 5, logisticsPercent = 0.1,
        skillFlat = 3, skillPercent = 0.05,
        reputationFlat = 0, reputationPercent = 0
      },
      bad = {
        moneyFlat = 0, moneyPercent = -0.05,
        logisticsFlat = 0, logisticsPercent = 0,
        skillFlat = 0, skillPercent = 0,
        reputationFlat = 0, reputationPercent = 0
      },
      horrible = {
        moneyFlat = 0, moneyPercent = -0.1,
        logisticsFlat = 0, logisticsPercent = 0,
        skillFlat = 0, skillPercent = 0,
        reputationFlat = -5, reputationPercent = -0.1
      }
    }
  }
}

local cachedConfig

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

local function sanitizeConfig(rawConfig)
  local issues = {}
  local cfg = deepCopyTable(DEFAULT_CONFIG)

  if type(rawConfig) ~= "table" then
    appendIssue(issues, "Config root is invalid; using defaults")
    return cfg, issues
  end

  cfg.version = readNumber(rawConfig.version, DEFAULT_CONFIG.version, 1, nil, "version", issues)

  local rawRounding = rawConfig.rounding
  if type(rawRounding) ~= "table" then
    appendIssue(issues, "rounding section missing; using defaults")
  else
    cfg.rounding.moneyFinal = readRoundMode(rawRounding.moneyFinal, DEFAULT_CONFIG.rounding.moneyFinal, "rounding.moneyFinal", issues)
  end

  local rawParcel = rawConfig.parcel
  if type(rawParcel) ~= "table" then
    appendIssue(issues, "parcel section missing; using defaults")
  else
    cfg.parcel.baseXP = readNumber(rawParcel.baseXP, DEFAULT_CONFIG.parcel.baseXP, 0, nil, "parcel.baseXP", issues)
    cfg.parcel.slotMilestones = sanitizeMilestones(rawParcel.slotMilestones, DEFAULT_CONFIG.parcel.slotMilestones, "parcel.slotMilestones", issues)
    cfg.parcel.distanceDivisor = readNumber(rawParcel.distanceDivisor, DEFAULT_CONFIG.parcel.distanceDivisor, 1, nil, "parcel.distanceDivisor", issues)
    cfg.parcel.reputationDistanceDivisor = readNumber(rawParcel.reputationDistanceDivisor, DEFAULT_CONFIG.parcel.reputationDistanceDivisor, 1, nil, "parcel.reputationDistanceDivisor", issues)
    cfg.parcel.distanceRounding = readRoundMode(rawParcel.distanceRounding, DEFAULT_CONFIG.parcel.distanceRounding, "parcel.distanceRounding", issues)
    cfg.parcel.reputationDistanceRounding = readRoundMode(rawParcel.reputationDistanceRounding, DEFAULT_CONFIG.parcel.reputationDistanceRounding, "parcel.reputationDistanceRounding", issues)
  end

  local rawVehicle = rawConfig.vehicleTrailer
  if type(rawVehicle) ~= "table" then
    appendIssue(issues, "vehicleTrailer section missing; using defaults")
  else
    cfg.vehicleTrailer.baseXP = readNumber(rawVehicle.baseXP, DEFAULT_CONFIG.vehicleTrailer.baseXP, 0, nil, "vehicleTrailer.baseXP", issues)
    cfg.vehicleTrailer.moneyDistanceDivisor = readNumber(rawVehicle.moneyDistanceDivisor, DEFAULT_CONFIG.vehicleTrailer.moneyDistanceDivisor, 1, nil, "vehicleTrailer.moneyDistanceDivisor", issues)
    cfg.vehicleTrailer.xpDistanceDivisor = readNumber(rawVehicle.xpDistanceDivisor, DEFAULT_CONFIG.vehicleTrailer.xpDistanceDivisor, 1, nil, "vehicleTrailer.xpDistanceDivisor", issues)
    cfg.vehicleTrailer.reputationDistanceDivisor = readNumber(rawVehicle.reputationDistanceDivisor, DEFAULT_CONFIG.vehicleTrailer.reputationDistanceDivisor, 1, nil, "vehicleTrailer.reputationDistanceDivisor", issues)
    cfg.vehicleTrailer.moneyDistanceRounding = readRoundMode(rawVehicle.moneyDistanceRounding, DEFAULT_CONFIG.vehicleTrailer.moneyDistanceRounding, "vehicleTrailer.moneyDistanceRounding", issues)
    cfg.vehicleTrailer.xpDistanceRounding = readRoundMode(rawVehicle.xpDistanceRounding, DEFAULT_CONFIG.vehicleTrailer.xpDistanceRounding, "vehicleTrailer.xpDistanceRounding", issues)
    cfg.vehicleTrailer.reputationDistanceRounding = readRoundMode(rawVehicle.reputationDistanceRounding, DEFAULT_CONFIG.vehicleTrailer.reputationDistanceRounding, "vehicleTrailer.reputationDistanceRounding", issues)
  end

  local rawMaterials = rawConfig.materials
  if type(rawMaterials) ~= "table" then
    appendIssue(issues, "materials section missing; using defaults")
  else
    cfg.materials.baseXP = readNumber(rawMaterials.baseXP, DEFAULT_CONFIG.materials.baseXP, 0, nil, "materials.baseXP", issues)
    cfg.materials.distanceDivisor = readNumber(rawMaterials.distanceDivisor, DEFAULT_CONFIG.materials.distanceDivisor, 1, nil, "materials.distanceDivisor", issues)
    cfg.materials.distanceOffset = readNumber(rawMaterials.distanceOffset, DEFAULT_CONFIG.materials.distanceOffset, nil, nil, "materials.distanceOffset", issues)
    cfg.materials.slotsDivisor = readNumber(rawMaterials.slotsDivisor, DEFAULT_CONFIG.materials.slotsDivisor, 1, nil, "materials.slotsDivisor", issues)
    cfg.materials.xpRounding = readRoundMode(rawMaterials.xpRounding, DEFAULT_CONFIG.materials.xpRounding, "materials.xpRounding", issues)
  end

  local rawPrecision = rawConfig.precisionParking
  if type(rawPrecision) ~= "table" then
    appendIssue(issues, "precisionParking section missing; using defaults")
  else
    cfg.precisionParking.rewardRounding = readRoundMode(rawPrecision.rewardRounding, DEFAULT_CONFIG.precisionParking.rewardRounding, "precisionParking.rewardRounding", issues)
    cfg.precisionParking.thresholds = sanitizeThresholds(rawPrecision.thresholds, DEFAULT_CONFIG.precisionParking.thresholds, "precisionParking.thresholds", issues)
    cfg.precisionParking.rewards = sanitizeRewards(rawPrecision.rewards, DEFAULT_CONFIG.precisionParking.rewards, "precisionParking.rewards", issues)

    local rawScore = rawPrecision.score
    local scoreDefaults = DEFAULT_CONFIG.precisionParking.score
    if type(rawScore) ~= "table" then
      appendIssue(issues, "precisionParking.score section missing; using defaults")
    else
      cfg.precisionParking.score.angleWorst = readNumber(rawScore.angleWorst, scoreDefaults.angleWorst, 0, nil, "precisionParking.score.angleWorst", issues)
      cfg.precisionParking.score.angleBest = readNumber(rawScore.angleBest, scoreDefaults.angleBest, 0, nil, "precisionParking.score.angleBest", issues)
      cfg.precisionParking.score.toleranceSpaceFactor = readNumber(rawScore.toleranceSpaceFactor, scoreDefaults.toleranceSpaceFactor, 0, nil, "precisionParking.score.toleranceSpaceFactor", issues)
      cfg.precisionParking.score.sideToleranceMin = readNumber(rawScore.sideToleranceMin, scoreDefaults.sideToleranceMin, 0, nil, "precisionParking.score.sideToleranceMin", issues)
      cfg.precisionParking.score.forwardToleranceMin = readNumber(rawScore.forwardToleranceMin, scoreDefaults.forwardToleranceMin, 0, nil, "precisionParking.score.forwardToleranceMin", issues)
      cfg.precisionParking.score.toleranceFloorFactor = readNumber(rawScore.toleranceFloorFactor, scoreDefaults.toleranceFloorFactor, 0, nil, "precisionParking.score.toleranceFloorFactor", issues)
      cfg.precisionParking.score.sideToleranceFloorMin = readNumber(rawScore.sideToleranceFloorMin, scoreDefaults.sideToleranceFloorMin, 0, nil, "precisionParking.score.sideToleranceFloorMin", issues)
      cfg.precisionParking.score.forwardToleranceFloorMin = readNumber(rawScore.forwardToleranceFloorMin, scoreDefaults.forwardToleranceFloorMin, 0, nil, "precisionParking.score.forwardToleranceFloorMin", issues)
      cfg.precisionParking.score.scoreScale = readNumber(rawScore.scoreScale, scoreDefaults.scoreScale, 0, nil, "precisionParking.score.scoreScale", issues)
      cfg.precisionParking.score.scoreOffset = readNumber(rawScore.scoreOffset, scoreDefaults.scoreOffset, nil, nil, "precisionParking.score.scoreOffset", issues)
      cfg.precisionParking.score.scoreCap = readNumber(rawScore.scoreCap, scoreDefaults.scoreCap, 1, nil, "precisionParking.score.scoreCap", issues)
      cfg.precisionParking.score.scoreRounding = readRoundMode(rawScore.scoreRounding, scoreDefaults.scoreRounding, "precisionParking.score.scoreRounding", issues)
    end
  end

  return cfg, issues
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

M.getConfig = function()
  return loadConfig(false)
end

M.getParcelRules = function()
  return loadConfig(false).parcel
end

M.getVehicleRules = function()
  return loadConfig(false).vehicleTrailer
end

M.getMaterialRules = function()
  return loadConfig(false).materials
end

M.getPrecisionParkingRules = function()
  return loadConfig(false).precisionParking
end

M.applyRounding = applyRounding

M.reload = function()
  return loadConfig(true)
end

M.reset = function()
  cachedConfig = nil
end

return M
