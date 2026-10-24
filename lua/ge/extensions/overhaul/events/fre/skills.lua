-- Freeroam event skill levels, license tiers, offer and sponsor slot caps and XP curves.
-- Reads the career skill branches; other freeroam files ask it for caps, unlocked tiers and sponsor cooldowns.
local M = {}
local freHelpers = require("overhaul/events/fre/helpers")

local freConfig = require("overhaul/events/freConfig")
local skillLookup = require("overhaul/lib/progression/skillLookup")

local tierRanks = { easy = 1, medium = 2, hard = 3, master = 4 }
local tierNames = { [1] = "easy", [2] = "medium", [3] = "hard" }

-- Skill references and progress ---------------------------------------------------------------------

local function getBranchForSkillKey(skillKey)
  return skillLookup.findBranchForAttributeKey(skillKey, { guarded = true })
end

local function getSkillRefs(disciplineId)
  local skillKey = freConfig.getSkillKey(disciplineId)
  if not skillKey then return nil, {} end

  local refs = {}
  local seen = {}
  local function addRef(ref)
    if type(ref) ~= "string" or ref == "" or seen[ref] then return end
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
  if not skillKey then return 0 end

  local value = 0
  if overhaul_career_economy_playerAttributes and overhaul_career_economy_playerAttributes.getAttributeValue then
    local raw = skillLookup.attributeValue(skillKey)
    value = tonumber(raw) or 0
  end

  local level = skillLookup.maxInterleavedLevel(0, value, refs)

  return math.max(0, math.floor(level))
end

local function buildProgressFromValueRefs(value, refs)
  local best = {
    level = 0,
    prevThreshold = nil,
    nextThreshold = nil,
  }

  local calcFromValue = skillLookup.captureLevelCalc()
  if calcFromValue then
    for _, branchRef in ipairs(refs) do
      local level, _, _, prevThreshold, nextThreshold = calcFromValue(value, branchRef)
      level = tonumber(level)
      prevThreshold = tonumber(prevThreshold)
      nextThreshold = tonumber(nextThreshold)
      if
        level
        and (
          level > best.level
          or (level == best.level and (nextThreshold or -math.huge) > (best.nextThreshold or -math.huge))
        )
      then
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
    nextThreshold = nextThreshold,
  }
end

local function readAttributeValueFromSave(attData, skillKey)
  if type(attData) ~= "table" or type(skillKey) ~= "string" or skillKey == "" then return 0 end
  -- The canonical saved key wins; a legacy name is only a fallback for saves that never migrated.
  local legacyKey
  if overhaul_career_progression_skills and overhaul_career_progression_skills.newAttributeNamesToOldNames then
    legacyKey = overhaul_career_progression_skills.newAttributeNamesToOldNames[skillKey]
  end
  local blob = attData[skillKey]
  if blob == nil and legacyKey then blob = attData[legacyKey] end
  if type(blob) == "table" then return tonumber(blob.value) or 0 end
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
      nextThreshold = nil,
    }
  end
  local value = 0
  if type(attData) == "table" then value = readAttributeValueFromSave(attData, skillKey) end
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
      nextThreshold = nil,
    }
  end

  local value = 0
  if overhaul_career_economy_playerAttributes and overhaul_career_economy_playerAttributes.getAttributeValue then
    local raw = skillLookup.attributeValue(skillKey)
    value = tonumber(raw) or 0
  end

  return buildProgressFromValueRefs(value, refs)
end

-- Offer tiers and slot limits -----------------------------------------------------------------------

local function hasLevel(level, requiredLevel)
  return type(level) == "number" and type(requiredLevel) == "number" and level >= requiredLevel
end

local function countOfferCap(level, cfg)
  local offerCount = tonumber(cfg.offerBaseCount) or 0
  local bumpCount = tonumber(cfg.offerBumpCount) or 0
  for _, requiredLevel in ipairs(cfg.offerIncreaseLevels or {}) do
    if hasLevel(level, requiredLevel) then offerCount = offerCount + bumpCount end
  end
  return math.max(0, math.floor(offerCount))
end

local function countSlotCap(level, slotCfg)
  if not slotCfg then return 0 end
  if not hasLevel(level, slotCfg.baseLevel) then return 0 end
  local slotCount = tonumber(slotCfg.baseSlots) or 0
  for _, requiredLevel in ipairs(slotCfg.extraLevels or {}) do
    if hasLevel(level, requiredLevel) then slotCount = slotCount + 1 end
  end
  return math.max(0, math.floor(slotCount))
end

local function getUnlockedTiersFromUnlockConfig(level, tierUnlock)
  tierUnlock = tierUnlock or {}
  local tiers = {}
  if hasLevel(level, tierUnlock.easy or math.huge) then table.insert(tiers, "easy") end
  if hasLevel(level, tierUnlock.medium or math.huge) then table.insert(tiers, "medium") end
  if hasLevel(level, tierUnlock.hard or math.huge) then table.insert(tiers, "hard") end
  return tiers
end

-- Contract licenses stop at Hard. The retained level argument keeps the
-- exported API stable for existing callers; Master is intentionally sponsor-only.
local function getUnlockedContractTiers(disciplineId, _level)
  local discipline = freConfig.getDisciplineById(disciplineId)
  if not discipline or discipline.legacyOnly == true then return {} end
  local state = overhaul_events_fre_state and overhaul_events_fre_state.getState()
  local parentState = state and state.parentSkills and state.parentSkills[discipline.parentSkillId]
  local license = parentState and parentState.licenses and parentState.licenses[disciplineId]
  local rank = tierRanks[license and license.tier] or 0
  local tiers = {}
  for i = 1, math.min(rank, 3) do
    table.insert(tiers, tierNames[i])
  end
  return tiers
end

local function getUnlockedSponsorTiers(disciplineId, level)
  local discipline = freConfig.getDisciplineById(disciplineId)
  if not discipline or discipline.legacyOnly == true then return {} end
  local state = overhaul_events_fre_state and overhaul_events_fre_state.getState()
  local parentState = state and state.parentSkills and state.parentSkills[discipline.parentSkillId]
  local license = parentState and parentState.licenses and parentState.licenses[disciplineId]
  if not license then return {} end
  local delay = tonumber((freConfig.getLicenseConfig() or {}).sponsorDelayLevels) or 2
  local tiers = {}
  for i = 1, math.min(tierRanks[license.tier] or 0, 3) do
    local tier = tierNames[i]
    local unlockedAt = tonumber((license.unlockLevels or {})[tier]) or math.huge
    if level >= unlockedAt + delay then table.insert(tiers, tier) end
  end
  if level >= 50 and (tierRanks[license.tier] or 0) >= 3 then table.insert(tiers, "master") end
  return tiers
end

-- Parent skills and licence cooldowns ---------------------------------------------------------------

local function getParentSkillId(disciplineId)
  return freConfig.getParentSkillId(disciplineId)
end

local function getParentSkillState(parentSkillId)
  local state = overhaul_events_fre_state.getState()
  state.parentSkills = state.parentSkills or {}
  state.parentSkills[parentSkillId] = state.parentSkills[parentSkillId] or { licenses = {}, sponsorSlotCooldowns = {} }
  return state.parentSkills[parentSkillId]
end

local function buildEarnedPointMilestones(level, maxPoints)
  -- JSON string keys override numeric defaults, so select one tier entry without merging its weights.
  local pointsByLevel = {}
  for rawLevel, amount in pairs((freConfig.getLicenseConfig() or {}).pointAwards or {}) do
    local milestoneLevel = tonumber(rawLevel)
    if milestoneLevel then
      pointsByLevel[milestoneLevel] =
        math.max(pointsByLevel[milestoneLevel] or 0, math.max(0, math.floor(tonumber(amount) or 0)))
    end
  end
  local result = {}
  for milestoneLevel, amount in pairs(pointsByLevel) do
    if level >= milestoneLevel then
      for _ = 1, amount do
        table.insert(result, milestoneLevel)
      end
    end
  end
  table.sort(result)
  while #result > (maxPoints or #result) do
    table.remove(result)
  end
  return result
end

local function pruneSponsorSlotCooldowns(parentState, now)
  if type(parentState) ~= "table" then return {}, nil end
  local activeCooldowns = {}
  local nextCooldown = nil
  for _, expiry in ipairs(parentState.sponsorSlotCooldowns or {}) do
    expiry = tonumber(expiry) or 0
    if expiry > now then
      table.insert(activeCooldowns, expiry)
      nextCooldown = not nextCooldown and expiry or math.min(nextCooldown, expiry)
    end
  end
  parentState.sponsorSlotCooldowns = activeCooldowns
  return activeCooldowns, nextCooldown
end

local function getSponsorCooldownOccupancy(parentSkillId, now)
  local parentState = getParentSkillState(parentSkillId)
  local activeCooldowns = pruneSponsorSlotCooldowns(parentState, now or overhaul_events_fre_state.getSimTime())
  return #activeCooldowns
end

local function pruneAllSponsorSlotCooldowns(now)
  local state = overhaul_events_fre_state.getState()
  now = tonumber(now) or overhaul_events_fre_state.getSimTime()
  local changed = false
  for _, parent in ipairs(freConfig.getParentSkills()) do
    local parentState = state.parentSkills and state.parentSkills[parent.id]
    if parentState then
      local before = #(parentState.sponsorSlotCooldowns or {})
      pruneSponsorSlotCooldowns(parentState, now)
      if #(parentState.sponsorSlotCooldowns or {}) ~= before then changed = true end
    end
  end
  return changed
end

local function getEarliestSponsorCooldownExpiry(now)
  local state = overhaul_events_fre_state.getState()
  now = tonumber(now) or overhaul_events_fre_state.getSimTime()
  local nextExpiry = nil
  for _, parent in ipairs(freConfig.getParentSkills()) do
    local parentState = state.parentSkills and state.parentSkills[parent.id]
    if parentState then
      local _, expiry = pruneSponsorSlotCooldowns(parentState, now)
      if expiry then nextExpiry = not nextExpiry and expiry or math.min(nextExpiry, expiry) end
    end
  end
  return nextExpiry
end

local function getLicenseSummary(parentSkillId)
  local parent = freConfig.getParentSkill(parentSkillId)
  if not parent then return nil end
  local laneIds = parent.laneIds or {}
  local level = #laneIds > 0 and getSkillLevel(laneIds[1]) or 0
  local maxPoints = #laneIds * 3
  local milestones = buildEarnedPointMilestones(level, maxPoints)
  local parentState = getParentSkillState(parentSkillId)
  local spent = 0
  for _, license in pairs(parentState.licenses or {}) do
    spent = spent + math.min(3, tierRanks[license.tier] or 0)
  end
  local now = overhaul_events_fre_state.getSimTime()
  local activeCooldowns, nextCooldown = pruneSponsorSlotCooldowns(parentState, now)
  return {
    id = parent.id,
    label = parent.label,
    skillKey = parent.skillKey,
    level = level,
    laneIds = laneIds,
    licenses = parentState.licenses,
    pointsEarned = #milestones,
    pointsSpent = spent,
    pointsAvailable = math.max(0, #milestones - spent),
    sponsorCooldownSlots = #activeCooldowns,
    nextSponsorCooldownMinutes = nextCooldown and math.max(0, nextCooldown - now) or 0,
    nextSpendMilestone = milestones[spent + 1],
    hardMinimumLevel = tonumber((freConfig.getLicenseConfig() or {}).hardMinimumLevel) or 30,
  }
end

-- Licence upgrades and shared slots -----------------------------------------------------------------

local function canUpgradeLicense(disciplineId, suppliedSummary)
  local discipline = freConfig.getDisciplineById(disciplineId)
  if not discipline or discipline.legacyOnly == true then return false, "This lane cannot be licensed." end
  local summary = suppliedSummary or getLicenseSummary(discipline.parentSkillId)
  if not summary then return false, "License data is unavailable." end
  local license = summary.licenses[disciplineId]
  local rank = tierRanks[license and license.tier] or 0
  if rank >= 3 then return false, "This license is already Hard." end
  local nextTier = tierNames[rank + 1]
  if summary.pointsAvailable < 1 then return false, "No license points are available.", nextTier, summary end
  if rank == 2 and summary.level < summary.hardMinimumLevel then
    return false, string.format("Hard licenses require level %d.", summary.hardMinimumLevel), nextTier, summary
  end
  return true, nil, nextTier, summary
end

local function upgradeLicense(disciplineId)
  local ok, err, nextTier, summary = canUpgradeLicense(disciplineId)
  if not ok then return false, err end
  local parentState = getParentSkillState(freConfig.getParentSkillId(disciplineId))
  local license = parentState.licenses[disciplineId] or { unlockLevels = {} }
  license.unlockLevels = license.unlockLevels or {}
  license.tier = nextTier
  license.unlockLevels[nextTier] = summary.nextSpendMilestone or summary.level
  parentState.licenses[disciplineId] = license
  overhaul_events_fre_state.saveNow()
  return true, nil, nextTier
end

local function countActiveForParent(parentSkillId, kind)
  local state = overhaul_events_fre_state.getState()
  local count = 0
  for _, discipline in ipairs(freConfig.getDisciplines()) do
    if discipline.parentSkillId == parentSkillId then
      local dState = state.disciplines[discipline.id]
      local bucket = dState and dState[kind]
      count = count + #(bucket and bucket.active or {})
    end
  end
  return count
end

local function getSharedSlotCap(disciplineId, kind)
  local level = getSkillLevel(disciplineId)
  local cfg = kind == "sponsors" and freConfig.getSponsorConfig(disciplineId)
    or freConfig.getContractConfig(disciplineId)
  return countSlotCap(level, cfg.slotUnlockLevels)
end

local function hasFreeSponsorSlot(disciplineId)
  local parentSkillId = getParentSkillId(disciplineId)
  local cap = getSharedSlotCap(disciplineId, "sponsors")
  local used = countActiveForParent(parentSkillId, "sponsors")
  local cooldowns = getSponsorCooldownOccupancy(parentSkillId)
  return used + cooldowns < cap
end

-- Performance XP ------------------------------------------------------------------------------------

local function normalizePerformanceRatioFromTargetTime(targetTime, actualTime)
  local target = tonumber(targetTime)
  local actual = tonumber(actualTime)
  if not target or target <= 0 or not actual or actual <= 0 then return 0 end
  return target / actual
end

local function calculateXpFromTierCurve(curveCfg, normalizedPerformance)
  local clamp = freHelpers.clamp
  local tierCfg = type(curveCfg) == "table" and curveCfg or {}
  local xpAtTarget = math.max(0, tonumber(tierCfg.xpAtTarget) or 0)
  if xpAtTarget <= 0 then return 0 end
  local tenPercentBetterMultiplier = tonumber(tierCfg.tenPercentBetterMultiplier) or 1.25
  if tenPercentBetterMultiplier <= 0 then tenPercentBetterMultiplier = 1.25 end
  local belowTargetFloorMultiplier = tonumber(tierCfg.belowTargetFloorMultiplier) or 0.25
  local maxMultiplier = tonumber(tierCfg.maxMultiplier) or 3.0
  if maxMultiplier < belowTargetFloorMultiplier then maxMultiplier = belowTargetFloorMultiplier end
  local normalized = math.max(0, tonumber(normalizedPerformance) or 0)
  local exponent = (normalized - 1.0) / 0.1
  local rawMultiplier = tenPercentBetterMultiplier ^ exponent
  local scaledMultiplier = clamp(rawMultiplier, belowTargetFloorMultiplier, maxMultiplier)
  return math.max(0, math.floor(xpAtTarget * scaledMultiplier))
end

-- Public API --------------------------------------------------------------------------------------

M.getSkillLevel = getSkillLevel
M.getSkillProgress = getSkillProgress
M.getSkillProgressFromSavedAttributes = getSkillProgressFromSavedAttributes
M.countOfferCap = countOfferCap
M.countSlotCap = countSlotCap
M.getUnlockedContractTiers = getUnlockedContractTiers
M.getUnlockedSponsorTiers = getUnlockedSponsorTiers
M.getParentSkillId = getParentSkillId
M.getLicenseSummary = getLicenseSummary
M.canUpgradeLicense = canUpgradeLicense
M.upgradeLicense = upgradeLicense
M.countActiveForParent = countActiveForParent
M.getSharedSlotCap = getSharedSlotCap
M.getParentSkillState = getParentSkillState
M.getSponsorCooldownOccupancy = getSponsorCooldownOccupancy
M.pruneAllSponsorSlotCooldowns = pruneAllSponsorSlotCooldowns
M.getEarliestSponsorCooldownExpiry = getEarliestSponsorCooldownExpiry
M.hasFreeSponsorSlot = hasFreeSponsorSlot
M.normalizePerformanceRatioFromTargetTime = normalizePerformanceRatioFromTargetTime
M.calculateXpFromTierCurve = calculateXpFromTierCurve

return M
