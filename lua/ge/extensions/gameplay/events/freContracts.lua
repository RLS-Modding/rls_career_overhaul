local M = {}

M.dependencies = {'career_career'}

local freConfig = require('gameplay/fre/config')

local SAVE_FILE = "/career/fre/freContractsSponsors.json"
local STATE_VERSION = 1
local LOG_TAG = "fre.contracts"

local state = nil
local raceCache = {levelId = nil, byDiscipline = {}}
local maintenanceAccumulator = 0

local sponsorNamePrefixes = {"Torque", "Summit", "Grid", "Rustline", "Blacktop", "Apex", "Ridge", "Mudline", "Trackside", "Overdrive"}
local sponsorNameSuffixes = {"Motors", "Performance", "Motorsport", "Industries", "Dynamics", "Works", "Racing", "Garage", "Labs", "Partners"}

local function roundTo(value, places)
  local mult = math.pow(10, places or 0)
  return math.floor(value * mult + 0.5) / mult
end

local function randomFloat(minValue, maxValue)
  if minValue == nil then minValue = 0 end
  if maxValue == nil then maxValue = minValue end
  if maxValue < minValue then
    minValue, maxValue = maxValue, minValue
  end
  return minValue + (maxValue - minValue) * math.random()
end

local function randomInt(minValue, maxValue)
  minValue = math.floor(minValue or 0)
  maxValue = math.floor(maxValue or minValue)
  if maxValue < minValue then
    minValue, maxValue = maxValue, minValue
  end
  return math.random(minValue, maxValue)
end

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

local function isCareerActive()
  local career = career_career
  return career and type(career.isActive) == "function" and career.isActive()
end

local function getCurrentLevelId()
  if getCurrentLevelIdentifier and getCurrentLevelIdentifier() then
    return getCurrentLevelIdentifier()
  end
  if core_levels and getMissionFilename and getMissionFilename() ~= '' then
    return core_levels.getLevelName(getMissionFilename())
  end
  return nil
end

local function getCurrentSavePath()
  if not career_saveSystem or not career_saveSystem.getCurrentSaveSlot then
    return nil
  end
  local _, savePath = career_saveSystem.getCurrentSaveSlot()
  return savePath
end

local function ensureSaveDirectory(savePath)
  if type(savePath) ~= "string" or savePath == "" then
    return
  end
  local relDir = SAVE_FILE:match("^(.+)/[^/]+$")
  if not relDir or relDir == "" then
    return
  end
  local fullDir = savePath .. relDir
  if FS and not FS:directoryExists(fullDir) then
    FS:directoryCreate(fullDir, true)
  end
end

local function initDisciplineState(disciplineId)
  return {
    id = disciplineId,
    contracts = {
      available = {},
      active = {},
      completed = 0,
      failed = 0
    },
    sponsors = {
      available = {},
      active = {},
      dropped = 0
    }
  }
end

local function buildDefaultState()
  local cfg = freConfig.getConfig()
  local disciplines = {}
  for _, discipline in ipairs(cfg.disciplines or {}) do
    disciplines[discipline.id] = initDisciplineState(discipline.id)
  end
  return {
    version = STATE_VERSION,
    simTime = 0,
    nextId = 1,
    disciplines = disciplines
  }
end

local function ensureState()
  if not state then
    state = buildDefaultState()
  end

  local cfg = freConfig.getConfig()
  state.version = STATE_VERSION
  state.nextId = tonumber(state.nextId) or 1
  state.simTime = tonumber(state.simTime) or 0
  state.disciplines = type(state.disciplines) == "table" and state.disciplines or {}

  for _, discipline in ipairs(cfg.disciplines or {}) do
    if not state.disciplines[discipline.id] then
      state.disciplines[discipline.id] = initDisciplineState(discipline.id)
    end
    local dState = state.disciplines[discipline.id]
    dState.contracts = type(dState.contracts) == "table" and dState.contracts or {}
    dState.contracts.available = type(dState.contracts.available) == "table" and dState.contracts.available or {}
    dState.contracts.active = type(dState.contracts.active) == "table" and dState.contracts.active or {}
    dState.contracts.completed = tonumber(dState.contracts.completed) or 0
    dState.contracts.failed = tonumber(dState.contracts.failed) or 0

    dState.sponsors = type(dState.sponsors) == "table" and dState.sponsors or {}
    dState.sponsors.available = type(dState.sponsors.available) == "table" and dState.sponsors.available or {}
    dState.sponsors.active = type(dState.sponsors.active) == "table" and dState.sponsors.active or {}
    dState.sponsors.dropped = tonumber(dState.sponsors.dropped) or 0
  end

  return state
end

local function loadState()
  local defaultState = buildDefaultState()
  local savePath = getCurrentSavePath()
  if not savePath then
    state = defaultState
    return state
  end

  local loaded = jsonReadFile(savePath .. SAVE_FILE)
  if type(loaded) ~= "table" then
    state = defaultState
    return state
  end
  state = loaded
  ensureState()
  return state
end

local function saveState(forcePath)
  ensureState()
  local savePath = forcePath or getCurrentSavePath()
  if not savePath then
    return false
  end
  ensureSaveDirectory(savePath)
  local writePath = savePath .. SAVE_FILE
  return career_saveSystem.jsonWriteFileSafe(writePath, state, true)
end

local function nextId(prefix)
  ensureState()
  local id = string.format("%s-%d", prefix or "fre", state.nextId)
  state.nextId = state.nextId + 1
  return id
end

local function getSkillLevel(disciplineId)
  local skillKey = freConfig.getSkillKey(disciplineId)
  if not skillKey then
    return 0
  end

  local refs = {}
  local seen = {}
  local function addRef(ref)
    if type(ref) ~= "string" or ref == "" then
      return
    end
    if seen[ref] then
      return
    end
    seen[ref] = true
    table.insert(refs, ref)
  end

  addRef(skillKey)
  local discipline = freConfig.getDisciplineById(disciplineId)
  if discipline then
    addRef(discipline.id)
  end

  if career_branches and career_branches.getBranchById then
    local branchBySkillKey = career_branches.getBranchById(skillKey)
    if type(branchBySkillKey) == "table" then
      addRef(branchBySkillKey.id)
      addRef(branchBySkillKey.path)
      addRef(branchBySkillKey.attributeKey)
    end
  end

  if career_branches and career_branches.getSortedBranches then
    for _, branch in ipairs(career_branches.getSortedBranches() or {}) do
      if type(branch) == "table" and branch.attributeKey == skillKey then
        addRef(branch.id)
        addRef(branch.path)
      end
    end
  end

  local value = 0
  if career_modules_playerAttributes and career_modules_playerAttributes.getAttributeValue then
    local rawValue = career_modules_playerAttributes.getAttributeValue(skillKey)
    value = tonumber(rawValue) or 0
  end

  local level = 0
  for _, branchRef in ipairs(refs) do
    if career_branches and career_branches.getBranchLevel then
      local directLevelRaw = career_branches.getBranchLevel(branchRef)
      local directLevel = tonumber(directLevelRaw)
      if directLevel and directLevel > level then
        level = directLevel
      end
    end
    if career_branches and career_branches.calcBranchLevelFromValue then
      local calcLevel = career_branches.calcBranchLevelFromValue(value, branchRef)
      calcLevel = tonumber(calcLevel)
      if calcLevel and calcLevel > level then
        level = calcLevel
      end
    end
  end

  return math.max(0, math.floor(level))
end

local function hasLevel(level, requiredLevel)
  return type(level) == "number" and type(requiredLevel) == "number" and level >= requiredLevel
end

local function countOfferCap(level, cfg)
  local offerCount = tonumber(cfg.offerBaseCount) or 0
  local bumpCount = tonumber(cfg.offerBumpCount) or 0
  for _, requiredLevel in ipairs(cfg.offerIncreaseLevels or {}) do
    if hasLevel(level, requiredLevel) then
      offerCount = offerCount + bumpCount
    end
  end
  return math.max(0, math.floor(offerCount))
end

local function countSlotCap(level, slotCfg)
  if not slotCfg then
    return 0
  end
  if not hasLevel(level, slotCfg.baseLevel) then
    return 0
  end
  local slotCount = tonumber(slotCfg.baseSlots) or 0
  for _, requiredLevel in ipairs(slotCfg.extraLevels or {}) do
    if hasLevel(level, requiredLevel) then
      slotCount = slotCount + 1
    end
  end
  return math.max(0, math.floor(slotCount))
end

local function getUnlockedContractTiers(level)
  local tierUnlock = (freConfig.getContractConfig() or {}).tierUnlockLevels or {}
  local tiers = {}
  if hasLevel(level, tierUnlock.easy or math.huge) then table.insert(tiers, "easy") end
  if hasLevel(level, tierUnlock.medium or math.huge) then table.insert(tiers, "medium") end
  if hasLevel(level, tierUnlock.hard or math.huge) then table.insert(tiers, "hard") end
  return tiers
end

local function getUnlockedSponsorTiers(level)
  local tierUnlock = (freConfig.getSponsorConfig() or {}).tierUnlockLevels or {}
  local tiers = {}
  if hasLevel(level, tierUnlock.easy or math.huge) then table.insert(tiers, "easy") end
  if hasLevel(level, tierUnlock.medium or math.huge) then table.insert(tiers, "medium") end
  if hasLevel(level, tierUnlock.hard or math.huge) then table.insert(tiers, "hard") end
  return tiers
end

local function refreshRaceCache()
  local levelId = getCurrentLevelId()
  if not levelId or levelId == "" then
    raceCache = {levelId = nil, byDiscipline = {}}
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
        table.insert(byDiscipline[disciplineId], {
          raceName = raceName,
          raceLabel = race.label or raceName,
          bestTime = tonumber(race.bestTime) or tonumber(race.hotlap) or 60
        })
      end
    end
  end

  raceCache = {
    levelId = levelId,
    byDiscipline = byDiscipline
  }
  return raceCache
end

local function pickRandomFromList(list)
  if type(list) ~= "table" or #list == 0 then
    return nil
  end
  return list[randomInt(1, #list)]
end

local function pickWeightedBonusType(weightTable)
  local total = 0
  for _, value in pairs(weightTable or {}) do
    total = total + (tonumber(value) or 0)
  end
  if total <= 0 then
    return "money"
  end
  local roll = randomFloat(0, total)
  local running = 0
  for key, value in pairs(weightTable or {}) do
    running = running + (tonumber(value) or 0)
    if roll <= running then
      return key
    end
  end
  return "money"
end

local function randomSponsorName()
  local prefix = pickRandomFromList(sponsorNamePrefixes) or "Apex"
  local suffix = pickRandomFromList(sponsorNameSuffixes) or "Performance"
  return prefix .. " " .. suffix
end

local function getOwnedVehicleModels()
  local models = {}
  local seen = {}
  local vehicles = career_modules_inventory and career_modules_inventory.getVehicles and career_modules_inventory.getVehicles() or {}
  for _, vehicle in pairs(vehicles or {}) do
    local model = type(vehicle.model) == "string" and string.lower(vehicle.model) or nil
    if model and model ~= "" and not seen[model] then
      seen[model] = true
      table.insert(models, model)
    end
  end
  return models
end

local function buildVehicleBlacklistLookup(disciplineId)
  local lookup = {}
  for _, model in ipairs(freConfig.getContractVehicleBlacklist(disciplineId) or {}) do
    if type(model) == "string" and model ~= "" then
      lookup[string.lower(model)] = true
    end
  end
  return lookup
end

local function filterModelPool(models, blacklistLookup)
  local filtered = {}
  local seen = {}
  for _, model in ipairs(models or {}) do
    local normalized = type(model) == "string" and string.lower(model) or nil
    if normalized and normalized ~= "" and not blacklistLookup[normalized] and not seen[normalized] then
      seen[normalized] = true
      table.insert(filtered, normalized)
    end
  end
  return filtered
end

local function getContractModelPool(disciplineId)
  local blacklist = buildVehicleBlacklistLookup(disciplineId)
  local ownedModels = filterModelPool(getOwnedVehicleModels(), blacklist)
  return ownedModels
end

local function isOwnedAndAllowedModel(disciplineId, model)
  local normalized = type(model) == "string" and string.lower(model) or nil
  if not normalized or normalized == "" then
    return false
  end

  local blacklist = buildVehicleBlacklistLookup(disciplineId)
  if blacklist[normalized] then
    return false
  end

  for _, ownedModel in ipairs(getOwnedVehicleModels()) do
    if ownedModel == normalized then
      return true
    end
  end
  return false
end

local function purgeExpiredEntries(now)
  ensureState()
  local sponsorCfg = freConfig.getSponsorConfig()
  local graceMinutes = tonumber(sponsorCfg.graceMinutes) or 20

  for _, discipline in ipairs(freConfig.getDisciplines()) do
    local dState = state.disciplines[discipline.id]
    if dState then
      for i = #dState.contracts.available, 1, -1 do
        local entry = dState.contracts.available[i]
        if (tonumber(entry.expiresAt) or 0) <= now then
          table.remove(dState.contracts.available, i)
        end
      end
      for i = #dState.contracts.active, 1, -1 do
        local entry = dState.contracts.active[i]
        if (tonumber(entry.expiresAt) or 0) <= now then
          dState.contracts.failed = dState.contracts.failed + 1
          table.remove(dState.contracts.active, i)
        end
      end

      for i = #dState.sponsors.available, 1, -1 do
        local entry = dState.sponsors.available[i]
        if (tonumber(entry.expiresAt) or 0) <= now then
          table.remove(dState.sponsors.available, i)
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
          else
            dState.sponsors.dropped = dState.sponsors.dropped + 1
            table.remove(dState.sponsors.active, i)
          end
        end
      end
    end
  end
end

local function generateContractOffer(disciplineId, level, now)
  local contractCfg = freConfig.getContractConfig()
  local unlockedTiers = getUnlockedContractTiers(level)
  if #unlockedTiers == 0 then
    return nil
  end

  local raceData = refreshRaceCache().byDiscipline[disciplineId] or {}
  if #raceData == 0 then
    return nil
  end

  local tier = unlockedTiers[randomInt(1, #unlockedTiers)]
  local raceEntry = pickRandomFromList(raceData)
  if not raceEntry then
    return nil
  end

  local multiplierRange = ((contractCfg.targetMultiplierByTier or {})[tier]) or {min = 1.0, max = 1.1}
  local targetTime = roundTo((tonumber(raceEntry.bestTime) or 60) * randomFloat(multiplierRange.min, multiplierRange.max), 3)

  local rewardRange = ((contractCfg.rewardRangeByTier or {})[tier]) or {}
  local rewardMoney = randomInt(tonumber(rewardRange.moneyMin) or 1000, tonumber(rewardRange.moneyMax) or 2000)
  local rewardXp = randomInt(tonumber(rewardRange.xpMin) or 100, tonumber(rewardRange.xpMax) or 300)

  local expiryMinutes = tonumber((contractCfg.expiryMinutesByTier or {})[tier]) or 60
  local model = pickRandomFromList(getContractModelPool(disciplineId))
  if not model or model == "" then
    return nil
  end

  return {
    id = nextId("fre-contract"),
    disciplineId = disciplineId,
    tier = tier,
    raceName = raceEntry.raceName,
    raceLabel = raceEntry.raceLabel,
    targetTime = targetTime,
    requiredModel = model,
    requiredModelFamily = model,
    rewardMoney = rewardMoney,
    rewardXp = rewardXp,
    expiresAt = now + expiryMinutes,
    createdAt = now
  }
end

local function generateSponsorOffer(disciplineId, level, now)
  local sponsorCfg = freConfig.getSponsorConfig()
  local unlockedTiers = getUnlockedSponsorTiers(level)
  if #unlockedTiers == 0 then
    return nil
  end

  local tier = unlockedTiers[randomInt(1, #unlockedTiers)]
  local bonusRange = ((sponsorCfg.bonusRangeByTier or {})[tier]) or {min = 0.01, max = 0.05}
  local bonusPercent = roundTo(randomFloat(bonusRange.min or 0.01, bonusRange.max or 0.05), 3)
  local bonusType = pickWeightedBonusType(sponsorCfg.bonusTypeWeights or {})
  local upkeepMinutes = tonumber((sponsorCfg.upkeepMinutesByTier or {})[tier]) or 120

  local offerExpiry = math.max(60, math.floor(upkeepMinutes * 0.75))

  return {
    id = nextId("fre-sponsor"),
    disciplineId = disciplineId,
    tier = tier,
    name = randomSponsorName(),
    bonusType = bonusType,
    bonusPercent = bonusPercent,
    upkeepMinutes = upkeepMinutes,
    requirement = "Complete one " .. (freConfig.getDisciplineById(disciplineId).label or disciplineId) .. " event in the window.",
    expiresAt = now + offerExpiry,
    createdAt = now
  }
end

local function syncOffersForDiscipline(disciplineId, now)
  ensureState()
  local dState = state.disciplines[disciplineId]
  if not dState then return end

  -- Remove stale offers that require models the player no longer owns (or are now blacklisted).
  for i = #dState.contracts.available, 1, -1 do
    local offer = dState.contracts.available[i]
    local requiredModel = offer and (offer.requiredModelFamily or offer.requiredModel)
    if requiredModel and requiredModel ~= "" and not isOwnedAndAllowedModel(disciplineId, requiredModel) then
      table.remove(dState.contracts.available, i)
    end
  end

  local level = getSkillLevel(disciplineId)
  local contractCfg = freConfig.getContractConfig()
  local sponsorCfg = freConfig.getSponsorConfig()

  local contractTierUnlock = (contractCfg.tierUnlockLevels or {}).easy or math.huge
  local sponsorTierUnlock = (sponsorCfg.tierUnlockLevels or {}).easy or math.huge

  if level < contractTierUnlock then
    dState.contracts.available = {}
  else
    local contractCap = countOfferCap(level, contractCfg)
    while #dState.contracts.available < contractCap do
      local offer = generateContractOffer(disciplineId, level, now)
      if not offer then
        break
      end
      table.insert(dState.contracts.available, offer)
    end
  end

  if level < sponsorTierUnlock then
    dState.sponsors.available = {}
  else
    local sponsorCap = countOfferCap(level, sponsorCfg)
    while #dState.sponsors.available < sponsorCap do
      local offer = generateSponsorOffer(disciplineId, level, now)
      if not offer then
        break
      end
      table.insert(dState.sponsors.available, offer)
    end
  end
end

local function syncAllOffers(now)
  refreshRaceCache()
  for _, discipline in ipairs(freConfig.getDisciplines()) do
    syncOffersForDiscipline(discipline.id, now)
  end
end

local function getSponsorBonusesForDiscipline(disciplineId)
  ensureState()
  local cap = tonumber((freConfig.getRewardScaling() or {}).sponsorBonusCap) or 2.0
  local dState = state.disciplines[disciplineId]
  if not dState then
    return {money = 0, xp = 0}
  end

  local moneyBonus = 0
  local xpBonus = 0
  for _, sponsor in ipairs(dState.sponsors.active or {}) do
    local bonus = tonumber(sponsor.bonusPercent) or 0
    local bonusType = sponsor.bonusType
    if bonusType == "money" then
      moneyBonus = moneyBonus + bonus
    elseif bonusType == "disciplineXP" then
      xpBonus = xpBonus + bonus
    elseif bonusType == "both" then
      moneyBonus = moneyBonus + bonus
      xpBonus = xpBonus + bonus
    end
  end
  moneyBonus = math.min(cap, math.max(0, moneyBonus))
  xpBonus = math.min(cap, math.max(0, xpBonus))
  return {money = moneyBonus, xp = xpBonus}
end

local function calculateRewardModifiers(disciplineIds)
  local scaling = freConfig.getRewardScaling() or {}
  local levelPct = tonumber(scaling.levelPercentPerLevelUp) or 0.1
  local maxLevel = math.floor(tonumber(scaling.maxLevel) or 50)
  if maxLevel < 1 then
    maxLevel = 50
  end
  local result = {
    moneyMultiplier = 1.0,
    disciplineMultipliers = {}
  }

  if type(disciplineIds) ~= "table" or #disciplineIds == 0 then
    return result
  end

  local moneyTotal = 0
  local moneyCount = 0
  local seen = {}
  for _, rawDisciplineId in ipairs(disciplineIds) do
    local disciplineId = freConfig.getDisciplineIdFromType(rawDisciplineId) or rawDisciplineId
    if disciplineId and not seen[disciplineId] then
      seen[disciplineId] = true
      local level = getSkillLevel(disciplineId)
      local effectiveLevel = math.max(1, math.min(level, maxLevel))
      local levelUps = math.max(0, effectiveLevel - 1)
      local skillMultiplier = 1.0 + levelUps * levelPct
      local sponsorBonus = getSponsorBonusesForDiscipline(disciplineId)
      local xpMultiplier = skillMultiplier * (1 + sponsorBonus.xp)
      local moneyMultiplier = skillMultiplier * (1 + sponsorBonus.money)

      result.disciplineMultipliers[disciplineId] = {
        level = level,
        effectiveLevel = effectiveLevel,
        levelBonus = levelUps * levelPct,
        skillMultiplier = skillMultiplier,
        sponsorMoneyBonus = sponsorBonus.money,
        sponsorXpBonus = sponsorBonus.xp,
        xpMultiplier = xpMultiplier,
        moneyMultiplier = moneyMultiplier
      }
      moneyTotal = moneyTotal + moneyMultiplier
      moneyCount = moneyCount + 1
    end
  end

  if moneyCount > 0 then
    result.moneyMultiplier = moneyTotal / moneyCount
  end
  return result
end

local function getCurrentVehicleModel(vehId)
  local vehicleId = vehId or be:getPlayerVehicleID(0)
  if not vehicleId then return nil end

  if career_modules_inventory and career_modules_inventory.getInventoryIdFromVehicleId and career_modules_inventory.getVehicles then
    local inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(vehicleId)
    if inventoryId then
      local vehicleData = (career_modules_inventory.getVehicles() or {})[inventoryId]
      if vehicleData and type(vehicleData.model) == "string" and vehicleData.model ~= "" then
        return string.lower(vehicleData.model)
      end
    end
  end
  return nil
end

local function normalizeModelFamilyToken(value)
  if type(value) ~= "string" or value == "" then
    return nil
  end
  local normalized = string.lower(value):gsub("[^%w]", "")
  if normalized == "" then
    return nil
  end
  return normalized
end

local function modelFamilyMatches(requiredModel, actualModel)
  if type(requiredModel) ~= "string" or requiredModel == "" then
    return true
  end
  local requiredToken = normalizeModelFamilyToken(requiredModel)
  local actualToken = normalizeModelFamilyToken(actualModel)
  if not requiredToken or not actualToken then
    return false
  end
  if requiredToken == actualToken then
    return true
  end
  if string.find(actualToken, requiredToken, 1, true) or string.find(requiredToken, actualToken, 1, true) then
    return true
  end
  return false
end

local function awardContract(contract, disciplineId)
  if not isCareerActive() then
    return
  end
  if not career_modules_payment or not career_modules_payment.reward then
    return
  end
  local skillKey = freConfig.getSkillKey(disciplineId)
  if not skillKey then
    return
  end

  local money = tonumber(contract.rewardMoney) or 0
  local xp = tonumber(contract.rewardXp) or 0
  local rewardData = {
    money = {amount = money, canBeNegative = false},
    beamXP = {amount = math.floor(xp / 10)}
  }
  rewardData[skillKey] = {amount = xp}
  career_modules_payment.reward(rewardData, {
    label = string.format("FRE Contract Complete: %s", contract.raceLabel or contract.raceName or disciplineId),
    tags = {"gameplay", "reward", "fre", "contract"}
  }, true)

  if ui_message then
    local disciplineLabel = ((freConfig.getDisciplineById(disciplineId) or {}).label) or disciplineId
    local raceLabel = contract.raceLabel or contract.raceName or disciplineId
    local moneyRounded = math.floor(money + 0.5)
    ui_message(string.format("Contract Complete\n%s - %s\nReward: $%d | XP: %d", disciplineLabel, raceLabel, moneyRounded, xp), 8, "FRE Contract")
  end
end

local function onFreeroamRaceCompleted(payload)
  ensureState()
  if type(payload) ~= "table" then
    return
  end

  local now = tonumber(state.simTime) or 0
  local raceName = payload.raceName
  local finishTime = tonumber(payload.finishTime) or math.huge
  local invalidLap = payload.invalidLap == true
  local vehicleModel = string.lower(payload.vehicleModel or getCurrentVehicleModel(payload.vehicleId) or "")
  local disciplineIds = payload.disciplineIds or {}

  if type(disciplineIds) ~= "table" then
    return
  end

  local seen = {}
  for _, rawDisciplineId in ipairs(disciplineIds) do
    local disciplineId = freConfig.getDisciplineIdFromType(rawDisciplineId) or rawDisciplineId
    if disciplineId and not seen[disciplineId] then
      seen[disciplineId] = true
      local dState = state.disciplines[disciplineId]
      if dState then
        if not invalidLap then
          for _, sponsor in ipairs(dState.sponsors.active or {}) do
            sponsor.warningIssued = false
            sponsor.warningIssuedAt = nil
            sponsor.lastQualifiedAt = now
            sponsor.nextCheckAt = now + (tonumber(sponsor.upkeepMinutes) or 120)
          end
        end

        for i = #dState.contracts.active, 1, -1 do
          local contract = dState.contracts.active[i]
          local raceOk = (contract.raceName == raceName)
          local requiredModelFamily = contract.requiredModelFamily or contract.requiredModel
          local modelOk = modelFamilyMatches(requiredModelFamily, vehicleModel)
          local timeOk = finishTime <= (tonumber(contract.targetTime) or math.huge)
          local notExpired = now <= (tonumber(contract.expiresAt) or 0)

          if not invalidLap and raceOk and modelOk and timeOk and notExpired then
            awardContract(contract, disciplineId)
            dState.contracts.completed = dState.contracts.completed + 1
            table.remove(dState.contracts.active, i)
          end
        end
      end
    end
  end
end

local function sortForUi(list, typeKey)
  table.sort(list, function(a, b)
    local levelA = tonumber(a.level) or 0
    local levelB = tonumber(b.level) or 0
    if levelA ~= levelB then
      return levelA > levelB
    end
    if typeKey == "contract" then
      local tierOrder = {easy = 1, medium = 2, hard = 3}
      local ta = tierOrder[a.tier] or 99
      local tb = tierOrder[b.tier] or 99
      if ta ~= tb then return ta < tb end
    end
    local expiresA = tonumber(a.expiresAt) or math.huge
    local expiresB = tonumber(b.expiresAt) or math.huge
    return expiresA < expiresB
  end)
end

local function buildDisciplineUiState(disciplineId, now)
  local discipline = freConfig.getDisciplineById(disciplineId)
  if not discipline then
    return nil
  end

  local level = getSkillLevel(disciplineId)
  local contractCfg = freConfig.getContractConfig()
  local sponsorCfg = freConfig.getSponsorConfig()
  local contractUnlockLevel = tonumber((contractCfg.tierUnlockLevels or {}).easy) or 0
  local sponsorUnlockLevel = tonumber((sponsorCfg.tierUnlockLevels or {}).easy) or 0
  local contractsUnlocked = level >= contractUnlockLevel
  local sponsorsUnlocked = level >= sponsorUnlockLevel

  local contractSlots = countSlotCap(level, contractCfg.slotUnlockLevels)
  local sponsorSlots = countSlotCap(level, sponsorCfg.slotUnlockLevels)
  local contractOfferCap = 0
  local sponsorOfferCap = 0

  if contractsUnlocked then
    contractOfferCap = countOfferCap(level, contractCfg)
  end
  if sponsorsUnlocked then
    sponsorOfferCap = countOfferCap(level, sponsorCfg)
  end

  local dState = state.disciplines[disciplineId]
  local sponsorBonuses = getSponsorBonusesForDiscipline(disciplineId)

  return {
    id = discipline.id,
    label = discipline.label or discipline.id,
    skillKey = discipline.skillKey,
    placeholderOnly = discipline.placeholderOnly == true,
    level = level,
    contractUnlockLevel = contractUnlockLevel,
    sponsorUnlockLevel = sponsorUnlockLevel,
    contractsUnlocked = contractsUnlocked,
    sponsorsUnlocked = sponsorsUnlocked,
    contractUnlockedTiers = getUnlockedContractTiers(level),
    sponsorUnlockedTiers = getUnlockedSponsorTiers(level),
    contractSlots = contractSlots,
    contractSlotsUsed = #(dState.contracts.active or {}),
    contractOfferCap = contractOfferCap,
    sponsorSlots = sponsorSlots,
    sponsorSlotsUsed = #(dState.sponsors.active or {}),
    sponsorOfferCap = sponsorOfferCap,
    sponsorBonusMoney = sponsorBonuses.money,
    sponsorBonusXp = sponsorBonuses.xp,
    contractCompleted = dState.contracts.completed or 0,
    contractFailed = dState.contracts.failed or 0,
    sponsorsDropped = dState.sponsors.dropped or 0
  }
end

local function formatContractForUi(contract, now, level)
  return {
    id = contract.id,
    disciplineId = contract.disciplineId,
    tier = contract.tier,
    raceName = contract.raceName,
    raceLabel = contract.raceLabel,
    targetTime = contract.targetTime,
    requiredModel = contract.requiredModel,
    requiredModelFamily = contract.requiredModelFamily,
    rewardMoney = contract.rewardMoney,
    rewardXp = contract.rewardXp,
    expiresAt = contract.expiresAt,
    minutesRemaining = math.max(0, (tonumber(contract.expiresAt) or now) - now),
    level = level
  }
end

local function formatSponsorForUi(sponsor, now, level)
  local nextCheckAt = tonumber(sponsor.nextCheckAt) or now
  return {
    id = sponsor.id,
    disciplineId = sponsor.disciplineId,
    tier = sponsor.tier,
    name = sponsor.name,
    bonusType = sponsor.bonusType,
    bonusPercent = sponsor.bonusPercent,
    upkeepMinutes = sponsor.upkeepMinutes,
    requirement = sponsor.requirement,
    expiresAt = sponsor.expiresAt,
    minutesRemaining = math.max(0, (tonumber(sponsor.expiresAt) or now) - now),
    level = level,
    warningIssued = sponsor.warningIssued == true,
    warningIssuedAt = sponsor.warningIssuedAt,
    nextCheckAt = nextCheckAt,
    checkMinutesRemaining = math.max(0, nextCheckAt - now)
  }
end

local function getUiState(filterDisciplineId)
  ensureState()
  local now = tonumber(state.simTime) or 0
  purgeExpiredEntries(now)
  syncAllOffers(now)

  local activeContracts = {}
  local availableContracts = {}
  local activeSponsors = {}
  local availableSponsors = {}
  local disciplinesUi = {}

  local allowed = {}
  if type(filterDisciplineId) == "string" and filterDisciplineId ~= "" then
    local normalized = freConfig.getDisciplineIdFromType(filterDisciplineId) or string.lower(filterDisciplineId)
    allowed[normalized] = true
  end

  for _, discipline in ipairs(freConfig.getDisciplines()) do
    if next(allowed) == nil or allowed[discipline.id] then
      local dState = state.disciplines[discipline.id]
      local level = getSkillLevel(discipline.id)
      table.insert(disciplinesUi, buildDisciplineUiState(discipline.id, now))

      for _, entry in ipairs(dState.contracts.active or {}) do
        table.insert(activeContracts, formatContractForUi(entry, now, level))
      end
      for _, entry in ipairs(dState.contracts.available or {}) do
        table.insert(availableContracts, formatContractForUi(entry, now, level))
      end

      for _, entry in ipairs(dState.sponsors.active or {}) do
        table.insert(activeSponsors, formatSponsorForUi(entry, now, level))
      end
      for _, entry in ipairs(dState.sponsors.available or {}) do
        table.insert(availableSponsors, formatSponsorForUi(entry, now, level))
      end
    end
  end

  sortForUi(activeContracts, "contract")
  sortForUi(availableContracts, "contract")
  sortForUi(activeSponsors, "sponsor")
  sortForUi(availableSponsors, "sponsor")

  return {
    version = STATE_VERSION,
    simTimeMinutes = now,
    levelId = raceCache.levelId,
    disciplines = disciplinesUi,
    activeContracts = activeContracts,
    availableContracts = availableContracts,
    activeSponsors = activeSponsors,
    availableSponsors = availableSponsors
  }
end

local function acceptContract(contractId)
  ensureState()
  local now = tonumber(state.simTime) or 0
  for _, discipline in ipairs(freConfig.getDisciplines()) do
    local dState = state.disciplines[discipline.id]
    for idx, entry in ipairs(dState.contracts.available) do
      if entry.id == contractId then
        local requiredModel = entry.requiredModelFamily or entry.requiredModel
        if requiredModel and requiredModel ~= "" and not isOwnedAndAllowedModel(discipline.id, requiredModel) then
          table.remove(dState.contracts.available, idx)
          saveState()
          return false, "Required vehicle model is no longer available."
        end
        local level = getSkillLevel(discipline.id)
        local slotCap = countSlotCap(level, (freConfig.getContractConfig() or {}).slotUnlockLevels)
        if #dState.contracts.active >= slotCap then
          return false, "No contract slots available."
        end
        local tier = entry.tier or "easy"
        local ttl = tonumber(((freConfig.getContractConfig() or {}).expiryMinutesByTier or {})[tier]) or 60
        entry.expiresAt = now + ttl
        entry.acceptedAt = now
        table.insert(dState.contracts.active, entry)
        table.remove(dState.contracts.available, idx)
        saveState()
        return true
      end
    end
  end
  return false, "Contract not found."
end

local function abandonContract(contractId)
  ensureState()
  for _, discipline in ipairs(freConfig.getDisciplines()) do
    local dState = state.disciplines[discipline.id]
    for idx, entry in ipairs(dState.contracts.active) do
      if entry.id == contractId then
        dState.contracts.failed = dState.contracts.failed + 1
        table.remove(dState.contracts.active, idx)
        saveState()
        return true
      end
    end
  end
  return false, "Contract not found."
end

local function signSponsor(sponsorId)
  ensureState()
  local now = tonumber(state.simTime) or 0
  for _, discipline in ipairs(freConfig.getDisciplines()) do
    local dState = state.disciplines[discipline.id]
    for idx, entry in ipairs(dState.sponsors.available) do
      if entry.id == sponsorId then
        local level = getSkillLevel(discipline.id)
        local slotCap = countSlotCap(level, (freConfig.getSponsorConfig() or {}).slotUnlockLevels)
        if #dState.sponsors.active >= slotCap then
          return false, "No sponsor slots available."
        end
        entry.warningIssued = false
        entry.warningIssuedAt = nil
        entry.nextCheckAt = now + (tonumber(entry.upkeepMinutes) or 120)
        table.insert(dState.sponsors.active, entry)
        table.remove(dState.sponsors.available, idx)
        saveState()
        return true
      end
    end
  end
  return false, "Sponsor not found."
end

local function dropSponsor(sponsorId)
  ensureState()
  for _, discipline in ipairs(freConfig.getDisciplines()) do
    local dState = state.disciplines[discipline.id]
    for idx, entry in ipairs(dState.sponsors.active) do
      if entry.id == sponsorId then
        dState.sponsors.dropped = dState.sponsors.dropped + 1
        table.remove(dState.sponsors.active, idx)
        saveState()
        return true
      end
    end
  end
  return false, "Sponsor not found."
end

local function acknowledgeSponsorWarning(sponsorId)
  ensureState()
  local now = tonumber(state.simTime) or 0
  for _, discipline in ipairs(freConfig.getDisciplines()) do
    local dState = state.disciplines[discipline.id]
    for _, entry in ipairs(dState.sponsors.active) do
      if entry.id == sponsorId then
        entry.warningAcknowledgedAt = now
        saveState()
        return true
      end
    end
  end
  return false
end

local function updateSimTime(dtSim)
  ensureState()
  local dt = tonumber(dtSim) or 0
  if dt < 0 then dt = 0 end
  state.simTime = (tonumber(state.simTime) or 0) + dt / 60
end

local function onUpdate(_, dtSim, _)
  if not isCareerActive() then
    return
  end
  updateSimTime(dtSim)
  maintenanceAccumulator = maintenanceAccumulator + (tonumber(dtSim) or 0)
  if maintenanceAccumulator < 1 then
    return
  end
  maintenanceAccumulator = 0
  local now = tonumber(state.simTime) or 0
  purgeExpiredEntries(now)
  syncAllOffers(now)
end

local function onSaveCurrentSaveSlot(currentSavePath)
  if not state then return end
  saveState(currentSavePath)
end

local function onExtensionLoaded()
  loadState()
  refreshRaceCache()
  local now = tonumber(state.simTime) or 0
  purgeExpiredEntries(now)
  syncAllOffers(now)
end

local function onCareerModulesActivated()
  loadState()
  refreshRaceCache()
end

M.calculateRewardModifiers = calculateRewardModifiers
M.getSponsorBonusesForDiscipline = getSponsorBonusesForDiscipline
M.getUiState = getUiState
M.acceptContract = acceptContract
M.abandonContract = abandonContract
M.signSponsor = signSponsor
M.dropSponsor = dropSponsor
M.acknowledgeSponsorWarning = acknowledgeSponsorWarning
M.getCurrentVehicleModel = getCurrentVehicleModel
M.onFreeroamRaceCompleted = onFreeroamRaceCompleted
M.onUpdate = onUpdate
M.onExtensionLoaded = onExtensionLoaded
M.onCareerModulesActivated = onCareerModulesActivated
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot

return M
