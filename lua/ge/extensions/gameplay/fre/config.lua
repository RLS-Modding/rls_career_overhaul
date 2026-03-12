local M = {}

local CONFIG_PATH = "/gameplay/fre/freProgression.config.json"
local LOG_TAG = "fre.config"

local defaultConfig = {
  version = 1,
  disciplines = {
    {id = "crawling", label = "Crawling", skillKey = "fre-crawling", placeholderOnly = false},
    {id = "roadracing", label = "Road Racing", skillKey = "fre-roadracing", placeholderOnly = false},
    {id = "drift", label = "Drift", skillKey = "fre-drift", placeholderOnly = false},
    {id = "drag", label = "Drag", skillKey = "fre-drag", placeholderOnly = false},
    {id = "trail", label = "Trail", skillKey = "fre-trail", placeholderOnly = true},
    {id = "oval", label = "Oval", skillKey = "fre-oval", placeholderOnly = false},
    {id = "offroad", label = "Off-Road", skillKey = "fre-offroad", placeholderOnly = false},
    {id = "rally", label = "Rally", skillKey = "fre-rally", placeholderOnly = false},
    {id = "landspeed", label = "Land Speed", skillKey = "fre-landspeed", placeholderOnly = true},
    {id = "mudding", label = "Mudding", skillKey = "fre-mudding", placeholderOnly = false}
  },
  typeAliasMap = {
    crawl = "crawling",
    crawling = "crawling",
    apexracing = "roadracing",
    roadracing = "roadracing",
    road_racing = "roadracing",
    drift = "drift",
    drag = "drag",
    trail = "trail",
    oval = "oval",
    offroad = "offroad",
    ["off-road"] = "offroad",
    rally = "rally",
    landspeed = "landspeed",
    land_speed = "landspeed",
    mud = "mudding",
    extrememud = "mudding",
    mudding = "mudding"
  },
  rewardScaling = {
    levelPercentPerLevelUp = 0.1,
    sponsorBonusCap = 2.0
  },
  contracts = {
    offerBaseCount = 3,
    offerBumpCount = 2,
    offerIncreaseLevels = {12, 27, 42},
    tierUnlockLevels = {easy = 5, medium = 20, hard = 35},
    slotUnlockLevels = {baseLevel = 5, baseSlots = 2, extraLevels = {14, 29, 44}},
    expiryMinutesByTier = {easy = 120, medium = 60, hard = 30},
    targetMultiplierByTier = {
      easy = {min = 1.06, max = 1.25},
      medium = {min = 1.02, max = 1.12},
      hard = {min = 0.96, max = 1.05}
    },
    rewardRangeByTier = {
      easy = {moneyMin = 15000, moneyMax = 30000, xpMin = 500, xpMax = 1000},
      medium = {moneyMin = 35000, moneyMax = 70000, xpMin = 1200, xpMax = 2500},
      hard = {moneyMin = 90000, moneyMax = 220000, xpMin = 3000, xpMax = 8000}
    }
  },
  sponsors = {
    offerBaseCount = 3,
    offerBumpCount = 2,
    offerIncreaseLevels = {16, 31, 46},
    tierUnlockLevels = {easy = 10, medium = 25, hard = 40},
    slotUnlockLevels = {baseLevel = 10, baseSlots = 2, extraLevels = {18, 33, 48}},
    upkeepMinutesByTier = {easy = 360, medium = 240, hard = 120},
    graceMinutes = 20,
    bonusRangeByTier = {
      easy = {min = 0.01, max = 0.10},
      medium = {min = 0.15, max = 0.25},
      hard = {min = 0.50, max = 1.00}
    },
    bonusTypeWeights = {
      money = 0.47,
      disciplineXP = 0.47,
      both = 0.06
    }
  },
  contractVehicleModels = {
    "moonhawk", "barstow", "pessima", "etk800", "vivace", "sunburst", "dseries", "roamer", "hopper", "crawler", "racetruck", "sbr", "scintilla"
  },
  contractVehicleBlacklist = {},
  contractVehicleBlacklistByDiscipline = {}
}

local cached
local disciplineById
local skillKeyByDiscipline
local aliasMap

local function deepCopy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for k, v in pairs(value) do
    out[k] = deepCopy(v)
  end
  return out
end

local function mergeDeep(baseValue, overrideValue)
  if type(baseValue) ~= "table" then
    if overrideValue == nil then
      return deepCopy(baseValue)
    end
    return deepCopy(overrideValue)
  end
  local result = deepCopy(baseValue)
  if type(overrideValue) ~= "table" then
    return result
  end
  for key, value in pairs(overrideValue) do
    if type(value) == "table" and type(result[key]) == "table" then
      result[key] = mergeDeep(result[key], value)
    else
      result[key] = deepCopy(value)
    end
  end
  return result
end

local function rebuildIndexes(cfg)
  disciplineById = {}
  skillKeyByDiscipline = {}
  aliasMap = {}

  for _, discipline in ipairs(cfg.disciplines or {}) do
    if type(discipline.id) == "string" and discipline.id ~= "" then
      local id = string.lower(discipline.id)
      disciplineById[id] = discipline
      if type(discipline.skillKey) == "string" and discipline.skillKey ~= "" then
        skillKeyByDiscipline[id] = discipline.skillKey
      end
    end
  end

  for rawType, disciplineId in pairs(cfg.typeAliasMap or {}) do
    if type(rawType) == "string" and type(disciplineId) == "string" then
      aliasMap[string.lower(rawType)] = string.lower(disciplineId)
    end
  end
end

local function loadConfig(forceReload)
  if cached and not forceReload then
    return cached
  end

  local raw = jsonReadFile(CONFIG_PATH)
  if type(raw) ~= "table" then
    log("W", LOG_TAG, string.format("Unable to read %s. Using defaults.", CONFIG_PATH))
    cached = deepCopy(defaultConfig)
  else
    cached = mergeDeep(defaultConfig, raw)
  end
  rebuildIndexes(cached)
  return cached
end

local function normalizeDisciplineIdFromType(rawType)
  if type(rawType) ~= "string" or rawType == "" then
    return nil
  end
  local key = string.lower(rawType)
  local mapped = aliasMap[key]
  if mapped then
    return mapped
  end
  if disciplineById[key] then
    return key
  end
  return nil
end

M.getConfig = function()
  return loadConfig(false)
end

M.reload = function()
  return loadConfig(true)
end

M.getDisciplines = function()
  return (loadConfig(false) or {}).disciplines or {}
end

M.getDisciplineById = function(disciplineId)
  loadConfig(false)
  if type(disciplineId) ~= "string" then
    return nil
  end
  return disciplineById[string.lower(disciplineId)]
end

M.getDisciplineIdFromType = function(rawType)
  loadConfig(false)
  return normalizeDisciplineIdFromType(rawType)
end

M.getSkillKey = function(disciplineId)
  loadConfig(false)
  if type(disciplineId) ~= "string" then
    return nil
  end
  return skillKeyByDiscipline[string.lower(disciplineId)]
end

M.getRewardScaling = function()
  return (loadConfig(false) or {}).rewardScaling or {}
end

M.getContractConfig = function()
  return (loadConfig(false) or {}).contracts or {}
end

M.getSponsorConfig = function()
  return (loadConfig(false) or {}).sponsors or {}
end

M.getContractVehicleModels = function()
  return (loadConfig(false) or {}).contractVehicleModels or {}
end

M.getContractVehicleBlacklist = function(disciplineId)
  local cfg = loadConfig(false) or {}
  local byDiscipline = cfg.contractVehicleBlacklistByDiscipline or {}
  local merged = {}
  local seen = {}

  local function appendList(list)
    for _, model in ipairs(list or {}) do
      if type(model) == "string" and model ~= "" then
        local key = string.lower(model)
        if not seen[key] then
          seen[key] = true
          table.insert(merged, key)
        end
      end
    end
  end

  appendList(cfg.contractVehicleBlacklist)
  if type(disciplineId) == "string" and disciplineId ~= "" then
    local normalized = string.lower(disciplineId)
    appendList(byDiscipline[normalized] or byDiscipline[disciplineId])
  end

  return merged
end

return M
