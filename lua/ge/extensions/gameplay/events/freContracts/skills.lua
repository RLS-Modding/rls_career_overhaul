local M = {}

local freConfig = require('gameplay/fre/config')

local function getBranchForSkillKey(skillKey)
  local function isValidBranch(candidate)
    return candidate and not candidate.missing and type(candidate.levels) == "table" and next(candidate.levels)
  end
  local function isCareerSkillsBranch(candidate)
    if type(candidate) ~= "table" then return false end
    if candidate.parentId == "careerSkills" then return true end
    if candidate.domainId == "careerSkills" then return true end
    if candidate.rootId == "careerSkills" then return true end
    if type(candidate.path) == "string" and candidate.path:find("careerSkills", 1, true) then return true end
    return false
  end

  local candidates = {}
  if career_branches and career_branches.getBranchById then
    local byId = career_branches.getBranchById(skillKey)
    if isValidBranch(byId) then
      table.insert(candidates, byId)
    end
  end
  if career_branches and career_branches.getBranchByPath then
    local byPath = career_branches.getBranchByPath(skillKey)
    if isValidBranch(byPath) then
      table.insert(candidates, byPath)
    end
  end
  if career_branches and career_branches.getSortedBranches then
    for _, candidate in ipairs(career_branches.getSortedBranches() or {}) do
      if type(candidate) == "table" and candidate.attributeKey == skillKey and isValidBranch(candidate) then
        table.insert(candidates, candidate)
      end
    end
  end

  local bestBranch, bestScore = nil, -math.huge
  for _, candidate in ipairs(candidates) do
    local score = #(candidate.levels or {})
    if isCareerSkillsBranch(candidate) then score = score + 10000 end
    if candidate.parentId == "careerSkills" then score = score + 1000 end
    if score > bestScore then
      bestBranch, bestScore = candidate, score
    end
  end

  return bestBranch
end

local function getSkillRefs(disciplineId)
  local skillKey = freConfig.getSkillKey(disciplineId)
  if not skillKey then
    return nil, {}
  end

  local refs = {}
  local seen = {}
  local function addRef(ref)
    if type(ref) ~= "string" or ref == "" or seen[ref] then
      return
    end
    seen[ref] = true
    table.insert(refs, ref)
  end

  addRef(skillKey)
  local branch = getBranchForSkillKey(skillKey)
  if branch then
    addRef(branch.id)
    addRef(branch.attributeKey)
  end

  return skillKey, refs
end

local function getSkillLevel(disciplineId)
  local skillKey, refs = getSkillRefs(disciplineId)
  if not skillKey then
    return 0
  end

  local value = 0
  if career_modules_playerAttributes and career_modules_playerAttributes.getAttributeValue then
    local raw = career_modules_playerAttributes.getAttributeValue(skillKey)
    value = tonumber(raw) or 0
  end

  local level = 0
  local hasBranches = career_branches ~= nil
  local getBranchLevel = hasBranches and career_branches.getBranchLevel
  local calcFromValue = hasBranches and career_branches.calcBranchLevelFromValue

  for _, branchRef in ipairs(refs) do
    if getBranchLevel then
      local raw = getBranchLevel(branchRef)
      local directLevel = tonumber(raw)
      if directLevel and directLevel > level then
        level = directLevel
      end
    end
    if calcFromValue then
      local raw = calcFromValue(value, branchRef)
      local calcLevel = tonumber(raw)
      if calcLevel and calcLevel > level then
        level = calcLevel
      end
    end
  end

  return math.max(0, math.floor(level))
end

local function buildProgressFromValueRefs(value, refs)
  local best = {
    level = 0,
    prevThreshold = nil,
    nextThreshold = nil
  }

  local calcFromValue = career_branches and career_branches.calcBranchLevelFromValue
  if calcFromValue then
    for _, branchRef in ipairs(refs) do
      local level, _, _, prevThreshold, nextThreshold = calcFromValue(value, branchRef)
      level = tonumber(level)
      prevThreshold = tonumber(prevThreshold)
      nextThreshold = tonumber(nextThreshold)
      if level and
        (level > best.level or
          (level == best.level and (nextThreshold or -math.huge) > (best.nextThreshold or -math.huge))) then
        best.level = level
        best.prevThreshold = prevThreshold
        best.nextThreshold = nextThreshold
      end
    end
  end

  local level = math.max(0, math.floor(best.level or 0))
  local prevThreshold = best.prevThreshold
  local nextThreshold = best.nextThreshold
  local xpIntoLevel = 0
  local xpNeededForLevel = 0
  local xpToNextLevel = 0
  local progress = 1

  if type(prevThreshold) == "number" and type(nextThreshold) == "number" and nextThreshold > prevThreshold then
    xpIntoLevel = math.max(0, value - prevThreshold)
    xpNeededForLevel = math.max(0, nextThreshold - prevThreshold)
    xpToNextLevel = math.max(0, nextThreshold - value)
    progress = math.min(1, math.max(0, xpIntoLevel / xpNeededForLevel))
  end

  return {
    value = value,
    level = level,
    progress = progress,
    xpIntoLevel = xpIntoLevel,
    xpNeededForLevel = xpNeededForLevel,
    xpToNextLevel = xpToNextLevel,
    prevThreshold = prevThreshold,
    nextThreshold = nextThreshold
  }
end

local function readAttributeValueFromSave(attData, skillKey)
  if type(attData) ~= "table" or type(skillKey) ~= "string" or skillKey == "" then
    return 0
  end
  local storageKey = skillKey
  if career_branches and career_branches.newAttributeNamesToOldNames then
    storageKey = career_branches.newAttributeNamesToOldNames[skillKey] or skillKey
  end
  local blob = attData[storageKey] or attData[skillKey]
  if type(blob) == "table" then
    return tonumber(blob.value) or 0
  end
  return tonumber(blob) or 0
end

local function getSkillProgressFromSavedAttributes(attData, disciplineId)
  local skillKey, refs = getSkillRefs(disciplineId)
  if not skillKey then
    return {
      value = 0,
      level = 0,
      progress = 0,
      xpIntoLevel = 0,
      xpNeededForLevel = 0,
      xpToNextLevel = 0,
      prevThreshold = nil,
      nextThreshold = nil
    }
  end
  local value = 0
  if type(attData) == "table" then
    value = readAttributeValueFromSave(attData, skillKey)
  end
  return buildProgressFromValueRefs(value, refs)
end

local function getSkillProgress(disciplineId)
  local skillKey, refs = getSkillRefs(disciplineId)
  if not skillKey then
    return {
      value = 0,
      level = 0,
      progress = 0,
      xpIntoLevel = 0,
      xpNeededForLevel = 0,
      xpToNextLevel = 0,
      prevThreshold = nil,
      nextThreshold = nil
    }
  end

  local value = 0
  if career_modules_playerAttributes and career_modules_playerAttributes.getAttributeValue then
    local raw = career_modules_playerAttributes.getAttributeValue(skillKey)
    value = tonumber(raw) or 0
  end

  return buildProgressFromValueRefs(value, refs)
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

local function getUnlockedTiersFromUnlockConfig(level, tierUnlock)
  tierUnlock = tierUnlock or {}
  local tiers = {}
  if hasLevel(level, tierUnlock.easy or math.huge) then
    table.insert(tiers, "easy")
  end
  if hasLevel(level, tierUnlock.medium or math.huge) then
    table.insert(tiers, "medium")
  end
  if hasLevel(level, tierUnlock.hard or math.huge) then
    table.insert(tiers, "hard")
  end
  return tiers
end

local function getUnlockedContractTiers(disciplineId, level)
  local tierUnlock = (freConfig.getContractConfig(disciplineId) or {}).tierUnlockLevels or {}
  return getUnlockedTiersFromUnlockConfig(level, tierUnlock)
end

local function getUnlockedSponsorTiers(disciplineId, level)
  local tierUnlock = (freConfig.getSponsorConfig(disciplineId) or {}).tierUnlockLevels or {}
  return getUnlockedTiersFromUnlockConfig(level, tierUnlock)
end

local function normalizePerformanceRatioFromTargetTime(targetTime, actualTime)
  local target = tonumber(targetTime)
  local actual = tonumber(actualTime)
  if not target or target <= 0 or not actual or actual <= 0 then
    return 0
  end
  return target / actual
end

local function calculateXpFromTierCurve(curveCfg, normalizedPerformance)
  local clamp = gameplay_events_freContracts_helpers.clamp
  local tierCfg = type(curveCfg) == "table" and curveCfg or {}
  local xpAtTarget = math.max(0, tonumber(tierCfg.xpAtTarget) or 0)
  if xpAtTarget <= 0 then
    return 0
  end
  local tenPercentBetterMultiplier = tonumber(tierCfg.tenPercentBetterMultiplier) or 1.25
  if tenPercentBetterMultiplier <= 0 then
    tenPercentBetterMultiplier = 1.25
  end
  local belowTargetFloorMultiplier = tonumber(tierCfg.belowTargetFloorMultiplier) or 0.25
  local maxMultiplier = tonumber(tierCfg.maxMultiplier) or 3.0
  if maxMultiplier < belowTargetFloorMultiplier then
    maxMultiplier = belowTargetFloorMultiplier
  end
  local normalized = math.max(0, tonumber(normalizedPerformance) or 0)
  local exponent = (normalized - 1.0) / 0.1
  local rawMultiplier = tenPercentBetterMultiplier ^ exponent
  local scaledMultiplier = clamp(rawMultiplier, belowTargetFloorMultiplier, maxMultiplier)
  return math.max(0, math.floor(xpAtTarget * scaledMultiplier))
end

M.getSkillLevel = getSkillLevel
M.getSkillProgress = getSkillProgress
M.getSkillProgressFromSavedAttributes = getSkillProgressFromSavedAttributes
M.countOfferCap = countOfferCap
M.countSlotCap = countSlotCap
M.getUnlockedContractTiers = getUnlockedContractTiers
M.getUnlockedSponsorTiers = getUnlockedSponsorTiers
M.normalizePerformanceRatioFromTargetTime = normalizePerformanceRatioFromTargetTime
M.calculateXpFromTierCurve = calculateXpFromTierCurve

return M
