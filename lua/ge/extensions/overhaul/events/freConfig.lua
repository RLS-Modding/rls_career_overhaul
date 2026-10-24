-- Freeroam progression defaults and overrides, with discipline and skill indexes.
-- Read defaults, loaded-data merging, cache lifetime and public configuration lookup.
local M = {}

-- Config ------------------------------------------------------------------------------------------

local CONFIG_PATH = "/gameplay/overhaul/fre/freProgression.config.json"
local LOG_TAG = "fre.config"

-- Configuration constructors --------------------------------------------------------------------

local function deepCopy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for k, v in pairs(value) do
    out[k] = deepCopy(v)
  end
  return out
end

local function isArrayLike(value)
  if type(value) ~= "table" then return false end

  local count = 0
  local maxIndex = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return false end
    count = count + 1
    if key > maxIndex then maxIndex = key end
  end

  return count > 0 and maxIndex == count
end

local function mergeDeep(baseValue, overrideValue)
  if type(baseValue) ~= "table" then
    if overrideValue == nil then return deepCopy(baseValue) end
    return deepCopy(overrideValue)
  end

  local result = deepCopy(baseValue)
  if type(overrideValue) ~= "table" then return result end

  local baseIsArray = isArrayLike(baseValue)
  local overrideIsArray = isArrayLike(overrideValue)
  if baseIsArray or overrideIsArray then return deepCopy(overrideValue) end

  for key, value in pairs(overrideValue) do
    if type(value) == "table" and type(result[key]) == "table" then
      result[key] = mergeDeep(result[key], value)
    else
      result[key] = deepCopy(value)
    end
  end
  return result
end

-- Discipline defaults -------------------------------------------------------------------------------

local defaultDisciplineContractConfig = {
  tierUnlockLevels = { easy = 5, medium = 20, hard = 35 },
  targetMultiplierByTier = {
    easy = { min = 0.9, max = 1.0 },
    medium = { min = 0.8, max = 0.9 },
    hard = { min = 0.7, max = 0.8 },
  },
  xpByTier = {
    easy = {
      xpAtTarget = 750,
      tenPercentBetterMultiplier = 1.25,
      belowTargetFloorMultiplier = 0.25,
      maxMultiplier = 3.0,
    },
    medium = {
      xpAtTarget = 1500,
      tenPercentBetterMultiplier = 1.25,
      belowTargetFloorMultiplier = 0.25,
      maxMultiplier = 3.0,
    },
    hard = {
      xpAtTarget = 3500,
      tenPercentBetterMultiplier = 1.25,
      belowTargetFloorMultiplier = 0.25,
      maxMultiplier = 3.0,
    },
  },
  vehicleBlacklist = {},
}

local defaultDisciplineSponsorConfig = {
  tierUnlockLevels = { easy = 10, medium = 25, hard = 40 },
  targetMultiplierByTier = {
    easy = { min = 1.08, max = 1.25 },
    medium = { min = 1.00, max = 1.12 },
    hard = { min = 0.94, max = 1.04 },
  },
}

local defaultDisciplineEventXpConfig = {
  tierUnlockLevels = { easy = 1, medium = 20, hard = 35 },
  xpByTier = {
    easy = {
      xpAtTarget = 200,
      tenPercentBetterMultiplier = 1.25,
      belowTargetFloorMultiplier = 0.25,
      maxMultiplier = 3.0,
    },
    medium = {
      xpAtTarget = 200,
      tenPercentBetterMultiplier = 1.25,
      belowTargetFloorMultiplier = 0.25,
      maxMultiplier = 3.0,
    },
    hard = {
      xpAtTarget = 200,
      tenPercentBetterMultiplier = 1.25,
      belowTargetFloorMultiplier = 0.25,
      maxMultiplier = 3.0,
    },
  },
}

local function makeDiscipline(id, label, parentSkillId, skillKey, placeholderOnly, legacyOnly)
  local d = {
    id = id,
    label = label,
    parentSkillId = parentSkillId,
    skillKey = skillKey,
    placeholderOnly = placeholderOnly == true,
    legacyOnly = legacyOnly == true,
    contracts = deepCopy(defaultDisciplineContractConfig),
    sponsors = deepCopy(defaultDisciplineSponsorConfig),
    eventXp = deepCopy(defaultDisciplineEventXpConfig),
  }
  if id == "roadracing" then d.sanctionedRacingUnlockLevel = 15 end
  return d
end

local defaultConfig = {
  version = 3,
  disciplines = {
    makeDiscipline("offroad", "Off-Road", "offroad", "careerSkills-offroad", false),
    makeDiscipline("rally", "Rally", "offroad", "careerSkills-offroad", false),
    makeDiscipline("crawling", "Crawling", "offroad", "careerSkills-offroad", false),
    makeDiscipline("mudding", "Mudding", "offroad", "careerSkills-offroad", false),
    makeDiscipline("trail", "Trail", "offroad", "careerSkills-offroad", true, true),
    makeDiscipline("drag", "Drag Racing", "speed", "careerSkills-speed", false),
    makeDiscipline("landspeed", "Top Speed", "speed", "careerSkills-speed", false),
    makeDiscipline("pulling", "Tractor Pulling", "speed", "careerSkills-speed", false),
    makeDiscipline("drift", "Drift", "mayhem", "careerSkills-mayhem", false),
    makeDiscipline("burnout", "Burnout", "mayhem", "careerSkills-mayhem", false),
    makeDiscipline("demo", "Demolition Derby", "mayhem", "careerSkills-mayhem", false),
    makeDiscipline("roadracing", "Road Racing", "circuitRacing", "careerSkills-circuitRacing", false),
    makeDiscipline("oval", "Oval", "circuitRacing", "careerSkills-circuitRacing", false),
  },
  parentSkills = {
    {
      id = "offroad",
      label = "Off-Road",
      skillKey = "careerSkills-offroad",
      laneIds = { "offroad", "rally", "crawling", "mudding" },
    },
    { id = "speed", label = "Speed", skillKey = "careerSkills-speed", laneIds = { "drag", "landspeed", "pulling" } },
    { id = "mayhem", label = "Mayhem", skillKey = "careerSkills-mayhem", laneIds = { "drift", "burnout", "demo" } },
    {
      id = "circuitRacing",
      label = "Circuit Racing",
      skillKey = "careerSkills-circuitRacing",
      laneIds = { "roadracing", "oval" },
    },
  },
  licenses = {
    pointAwards = { [5] = 1, [10] = 1, [15] = 1, [20] = 1, [25] = 2, [30] = 2, [35] = 1, [40] = 2, [45] = 1 },
    hardMinimumLevel = 30,
    sponsorDelayLevels = 2,
  },
  typeAliasMap = {
    crawl = "crawling",
    crawling = "crawling",
    apexracing = "roadracing",
    roadracing = "roadracing",
    road_racing = "roadracing",
    drift = "drift",
    burnout = "burnout",
    burnoutcomp = "burnout",
    drag = "drag",
    trail = "trail",
    oval = "oval",
    offroad = "offroad",
    ["off-road"] = "offroad",
    rally = "rally",
    landspeed = "landspeed",
    land_speed = "landspeed",
    pulling = "pulling",
    tractor_pull = "pulling",
    tractor_pulling = "pulling",
    mud = "mudding",
    extrememud = "mudding",
    mudding = "mudding",
    demo = "demo",
    demolition = "demo",
    demolitionderby = "demo",
  },
  rewardScaling = {
    maxLevel = 50,
    normalLaneMaxBonus = 2.0,
    level50TopOff = 0.08,
    sponsorBonusCap = 10.0,
  },
  contracts = {
    offerBaseCount = 3,
    offerBumpCount = 2,
    offerIncreaseLevels = { 12, 27, 42 },
    slotUnlockLevels = { baseLevel = 5, baseSlots = 2, extraLevels = { 20, 35, 50 } },
    offerExpiryMinutes = 5,
    offerRefreshMinutes = 2,
    contractVehiclePickWeights = {
      experiencedOwned = 0.5,
      otherOwned = 0.3,
      notOwned = 0.2,
    },
    contractVehicleRewardMultipliers = {
      experiencedOwned = 1,
      otherOwned = 1,
      notOwned = 1.25,
    },
    expiryMinutesByTier = { easy = 240, medium = 120, hard = 60 },
    basePayoutMultiplierByTier = {
      easy = 10,
      medium = 15,
      hard = 25,
    },
    payoutVariance = { min = 0.95, max = 1.05 },
    extraLapEventBonusPerUnit = 0.33,
    xpPercentOfMoney = 0.5,
    timeWindowMinutesByTier = {
      easy = { min = 3, max = 9 },
      medium = { min = 3, max = 9 },
      hard = { min = 3, max = 9 },
    },
    nonLoopEventTimeMultiplier = 1.66,
    contractPbTimeMultipliersByTier = {
      easy = { min = 1.025, max = 1.1 },
      medium = { min = 0.975, max = 1.025 },
      hard = { min = 0.925, max = 0.975 },
    },
    disciplinesUsingEventCountOverride = { "crawling" },
    eventCountOverrideByTier = {
      easy = { eventsMin = 2, eventsMax = 3 },
      medium = { eventsMin = 3, eventsMax = 5 },
      hard = { eventsMin = 4, eventsMax = 6 },
    },
  },
  sponsors = {
    offerBaseCount = 3,
    offerBumpCount = 2,
    offerIncreaseLevels = { 16, 31, 46 },
    slotUnlockLevels = { baseLevel = 7, baseSlots = 2, extraLevels = { 30, 40, 50 } },
    offerExpiryMinutes = 5,
    offerRefreshMinutes = 2,
    upkeepMinutesByTier = { easy = 60, medium = 45, hard = 30, master = 30 },
    probationMinutesByTier = { easy = 30, medium = 30, hard = 30, master = 15 },
    graceMinutes = 5,
    droppedSlotCooldownMinutes = 15,
    bonusRangeByTier = {
      easy = { min = 0.01, max = 0.10 },
      medium = { min = 0.10, max = 0.18 },
      hard = { min = 0.15, max = 0.30 },
      master = { min = 0.20, max = 0.50 },
    },
    bonusTypeWeights = {
      money = 0.47,
      disciplineXP = 0.47,
      both = 0.06,
    },
  },
  contractVehicleModels = {
    "moonhawk",
    "barstow",
    "pessima",
    "etk800",
    "vivace",
    "sunburst",
    "dseries",
    "roamer",
    "hopper",
    "crawler",
    "racetruck",
    "sbr",
    "scintilla",
  },
}

-- State ---------------------------------------------------------------------------------------------

local cached
local disciplineById
local skillKeyByDiscipline
local aliasMap

-- Cache loading and discipline lookup ---------------------------------------------------------------

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
  if cached and not forceReload then return cached end

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
  if type(rawType) ~= "string" or rawType == "" then return nil end
  local key = string.lower(rawType)
  local mapped = aliasMap[key]
  if mapped then return mapped end
  if disciplineById[key] then return key end
  return nil
end

local function getDisciplineConfig(disciplineId)
  loadConfig(false)
  if type(disciplineId) ~= "string" or disciplineId == "" then return nil end
  return disciplineById[string.lower(disciplineId)]
end

local function mergeDisciplineScoped(baseConfig, disciplineSection)
  if type(disciplineSection) ~= "table" then return baseConfig or {} end
  return mergeDeep(baseConfig or {}, disciplineSection)
end

-- Public API --------------------------------------------------------------------------------------

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
  return getDisciplineConfig(disciplineId)
end

M.getDisciplineIdFromType = function(rawType)
  loadConfig(false)
  return normalizeDisciplineIdFromType(rawType)
end

M.getSkillKey = function(disciplineId)
  loadConfig(false)
  if type(disciplineId) ~= "string" then return nil end
  return skillKeyByDiscipline[string.lower(disciplineId)]
end

M.getParentSkillId = function(disciplineId)
  local discipline = getDisciplineConfig(disciplineId)
  return discipline and discipline.parentSkillId or nil
end

M.getParentSkills = function()
  return (loadConfig(false) or {}).parentSkills or {}
end

M.getParentSkill = function(parentSkillId)
  for _, parent in ipairs(M.getParentSkills()) do
    if parent.id == parentSkillId then return parent end
  end
  return nil
end

M.getLicenseConfig = function()
  return (loadConfig(false) or {}).licenses or {}
end

M.getRewardScaling = function()
  return (loadConfig(false) or {}).rewardScaling or {}
end

M.getContractConfig = function(disciplineId)
  local cfg = loadConfig(false) or {}
  local globalContracts = cfg.contracts or {}
  if type(disciplineId) ~= "string" or disciplineId == "" then return globalContracts end
  local discipline = getDisciplineConfig(disciplineId)
  return mergeDisciplineScoped(globalContracts, discipline and discipline.contracts)
end

M.getSponsorConfig = function(disciplineId)
  local cfg = loadConfig(false) or {}
  local globalSponsors = cfg.sponsors or {}
  if type(disciplineId) ~= "string" or disciplineId == "" then return globalSponsors end
  local discipline = getDisciplineConfig(disciplineId)
  return mergeDisciplineScoped(globalSponsors, discipline and discipline.sponsors)
end

M.getEventXpConfig = function(disciplineId)
  local discipline = getDisciplineConfig(disciplineId)
  return mergeDisciplineScoped(defaultDisciplineEventXpConfig, discipline and discipline.eventXp)
end

M.getDisciplineRewardTuning = function(disciplineId)
  local discipline = getDisciplineConfig(disciplineId)
  return discipline and discipline.rewardTuning or {}
end

M.getContractVehicleModels = function()
  return (loadConfig(false) or {}).contractVehicleModels or {}
end

M.getContractVehicleBlacklist = function(disciplineId)
  local merged = {}
  local seen = {}
  local discipline = getDisciplineConfig(disciplineId)
  local list = discipline and discipline.contracts and discipline.contracts.vehicleBlacklist or {}
  for _, model in ipairs(list or {}) do
    if type(model) == "string" and model ~= "" then
      local key = string.lower(model)
      if not seen[key] then
        seen[key] = true
        table.insert(merged, key)
      end
    end
  end
  return merged
end

M.getSanctionedRacingUnlockLevel = function()
  local d = getDisciplineConfig("roadracing")
  local v = d and d.sanctionedRacingUnlockLevel
  if v == nil then return 15 end
  return math.max(1, math.floor(tonumber(v) or 15))
end

return M
