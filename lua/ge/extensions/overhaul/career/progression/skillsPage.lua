-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding
-- Skills page: builds the landing page, branch headers and skill cards from the live branch catalog and player attributes.
-- Based on stock's branches/landing.lua; the careerSkills page rules and legacy page aliases are local.
local M = {}

-- Requires --------------------------------------------------------------------------------------------

local skillLookup = require("overhaul/lib/progression/skillLookup")
-- Kept for load order; the retired facility cards no longer read it.
require("overhaul/lib/logistics/xpConfig")

-- Config ----------------------------------------------------------------------------------------------

local CIVIL_SERVICE_LIST_CARD_BRANCH_ID = "careerSkills-civilService"
local CAREER_SKILLS_DOMAIN_ID = "careerSkills"

-- Stock's merged branch data can keep legacy isSkill=true, so the careerSkills page lists this fixed set.
local visibleCareerSkillIds = {
  ["careerSkills-offroad"] = true,
  ["careerSkills-speed"] = true,
  ["careerSkills-mayhem"] = true,
  ["careerSkills-circuitRacing"] = true,
  ["careerSkills-emergency"] = true,
  ["careerSkills-passenger"] = true,
  ["careerSkills-operator"] = true,
  ["careerSkills-recovery"] = true,
  ["careerSkills-logistics"] = true,
  ["careerSkills-gambling"] = true,
  ["careerSkills-stamina"] = true,
}

-- Retired page ids that now show on the careerSkills page. Stock-domain ids have no page.
local legacyParentBranchAliases = {
  ["careerSkills-drag"] = "careerSkills-speed",
  ["careerSkills-drift"] = "careerSkills-mayhem",
  ["careerSkills-roadracing"] = "careerSkills-circuitRacing",
  ["careerSkills-taxi"] = "careerSkills-passenger",
  ["careerSkills-repo"] = "careerSkills-recovery",
  drift = "careerSkills-mayhem",
  crawl = "careerSkills-offroad",
  crawling = "careerSkills-offroad",
  apexRacing = "careerSkills-circuitRacing",
  motorsport = "careerSkills-circuitRacing",
  police = "careerSkills-emergency",
}

-- Helpers ---------------------------------------------------------------------------------------------

local function canonicalParentBranchId(branchId)
  return legacyParentBranchAliases[branchId] or branchId
end

local function isVisibleSkillForPage(skill, parentId)
  if not skill or skill.isSkill ~= true then return false end
  if parentId == CAREER_SKILLS_DOMAIN_ID then return visibleCareerSkillIds[skill.id] == true end
  return true
end

-- Hidden until it has progress: branches flagged hideUntilProgress, and gambling.
local function shouldHideSkill(branch, value)
  if branch.hideUntilProgress or branch.attributeKey == "careerSkills-gambling" then
    return (tonumber(value) or 0) <= 0
  end
  return false
end

-- Level, level minimum and level maximum of a value on one branch's level table.
local function levelWindow(branch, value)
  local level, _, _, min, max = skillLookup.levelFromValue(value, branch.id)
  return level, min, max
end

-- Returns the cards for one level's unlocks and marks each one's type for the page.
local function levelUnlockCards(levelUnlocks)
  local list = {}
  for _, unlock in ipairs(levelUnlocks or {}) do
    if unlock.type == "tasklist" then
      local tasklistData = {}
      extensions.hook("onOverhaulProgressPageGetTasklistData", tasklistData, unlock.tasklistId)
      if tasklistData and next(tasklistData) then
        unlock.tasklistData = tasklistData
      end
      table.insert(list, unlock)
      unlock.type = "tasklist"
    else
      table.insert(list, unlock)
      unlock.type = "unlockCard"
    end
  end
  return list
end

-- Per-level unlock rows for a skill, the sum of their required values, and whether any level has unlocks to show.
local function calculateUnlockInfo(skill, value, level)
  local unlockInfo = {}
  local unlocks = skill.levels
  local hasUnlocks = false

  if unlocks then
    local previousRequiredValue = 0
    for i = 1, #unlocks do
      local previousLevelInfo = skill.levels[i-1]
      local currentLevelInfo = skill.levels[i]
      local requiredRelative = (currentLevelInfo and currentLevelInfo.requiredValue or -1) - previousRequiredValue

      previousRequiredValue = (currentLevelInfo and currentLevelInfo.requiredValue or -1)
      unlockInfo[i] = {
        index = i,
        currentValue = previousLevelInfo and value - previousLevelInfo.requiredValue or -1,
        requiredValue = currentLevelInfo and requiredRelative or -1,
        xpCurrent = value,
        xpRequired = currentLevelInfo and currentLevelInfo.requiredValue or -1,
        isInDevelopment = unlocks[i].isInDevelopment,
        isMaxLevel = unlocks[i].isMaxLevel,
        isBase = i == 1,
        unlocked = i >= level,
        description = unlocks[i].description,
      }
      if (unlocks[i].unlocks and #unlocks[i].unlocks > 0) or unlocks[i].description then
        hasUnlocks = true
      end
      unlockInfo[i].list = levelUnlockCards(unlocks[i].unlocks)
    end
  end

  local maxRequiredValue = 0
  for _, info in ipairs(unlockInfo) do
    maxRequiredValue = maxRequiredValue + info.requiredValue
  end

  return unlockInfo, maxRequiredValue, hasUnlocks
end

-- Container branches have one level entry and no attribute of their own, so their header
-- aggregates the child skills instead of showing max level.
local function applyChildSkillAggregate(branchInfo, childSkills)
  if not childSkills or #childSkills == 0 then
    return
  end

  local sumValue, sumMin, sumMax, sumLevel = 0, 0, 0, 0
  for _, skillInfo in ipairs(childSkills) do
    sumValue = sumValue + (tonumber(skillInfo.value) or 0)
    sumMin = sumMin + (tonumber(skillInfo.min) or 0)
    sumMax = sumMax + (tonumber(skillInfo.max) or 0)
    sumLevel = sumLevel + (tonumber(skillInfo.level) or 0)
  end

  branchInfo.value = sumValue
  branchInfo.min = sumMin
  branchInfo.max = math.max(sumMax, 1)
  branchInfo.level = math.floor(sumLevel / #childSkills + 0.5)
  branchInfo.levelLabel = {txt = "ui.career.lvlLabel", context = {lvl = branchInfo.level}}
  branchInfo.isMaxLevel = false
end

-- Visible, non-hidden skills under a parent, reduced to the numbers the aggregate needs.
local function getVisibleChildSkillStats(parentId)
  local ret = {}
  for _, skill in pairs(overhaul_career_progression_skills.getSortedBranches()) do
    if skill.parentId == parentId and isVisibleSkillForPage(skill, parentId) then
      local value = skillLookup.attributeValue(skill.attributeKey)
      if not shouldHideSkill(skill, value) then
        local level, min, max = levelWindow(skill, value)
        table.insert(ret, {value = value, min = min, max = max, level = level})
      end
    end
  end
  return ret
end

-- Skill cards -----------------------------------------------------------------------------------------

local function skillCardForPage(skill, value)
  local level, min, max = levelWindow(skill, value)
  local skillData = {
    icon = skill.icon,
    isSkill = skill.isSkill,
    id = skill.id,
    attributeKey = skill.attributeKey,
    name = skill.name,
    description = skill.description,
    level = level,
    levelLabel = {txt = "ui.career.lvlLabel", context = {lvl = level}},
    unlocked = skill.unlocked,
    min = min,
    value = value,
    max = max,
    unlockInfo = {},
    order = skill.order,
    isInDevelopment = skill.isInDevelopment,
    hasLevels = skill.hasLevels,
    color = skill.color,
    accentColor = skill.accentColor,
  }
  if skill.levels then
    skillData.unlockInfo, skillData.maxRequiredValue, skillData.hasUnlocks = calculateUnlockInfo(skill, value, level)
  end
  return skillData
end

-- Skill cards for one branch's page: each visible child skill that has not been hidden.
local function getSkillsProgressForUi(branchId)
  local ret = {}
  for _, skill in pairs(overhaul_career_progression_skills.getSortedBranches()) do
    if skill.parentId == branchId and isVisibleSkillForPage(skill, branchId) then
      local value = skillLookup.attributeValue(skill.attributeKey)
      if not shouldHideSkill(skill, value) then
        table.insert(ret, skillCardForPage(skill, value))
      end
    end
  end
  return ret
end

-- Branch page ---------------------------------------------------------------------------------------

-- Header card for a branch: its level, value and the lock state of the skill itself.
local function buildBranchCard(branch)
  local value = skillLookup.attributeValue(branch.attributeKey)
  local level, min, max = levelWindow(branch, value)
  return {
    name = branch.name,
    description = branch.description,
    shortDescription = branch.shortDescription,
    id = branch.id,
    levelLabel = overhaul_career_progression_skills.getLevelLabel(branch.id, level),
    isMaxLevel = level >= #branch.levels,
    unlocked = branch.unlocked,
    cover = branch.progressCover,
    icon = branch.icon,
    glyphIcon = branch.icon,
    color = branch.color,
    accentColor = branch.accentColor,
    min = min,
    value = value,
    max = max,
    skills = {},
    isDomain = branch.isDomain,
    isSkill = branch.isSkill,
    level = level,
    lockedReason = branch.lockedReason,
    unlockInfos = branch.unlockInfos,
    isInDevelopment = branch.isInDevelopment,
  }
end

-- One row for a child skill of a branch page.
local function buildChildSkillInfo(subBranch, value)
  local level, min, max = levelWindow(subBranch, value)
  return {
    id = subBranch.id,
    name = subBranch.name,
    levelLabel = overhaul_career_progression_skills.getLevelLabel(subBranch.id, level),
    isMaxLevel = level >= #subBranch.levels,
    unlocked = subBranch.unlocked,
    min = min,
    value = value,
    max = max,
    isInDevelopment = subBranch.isInDevelopment,
    hasLevels = subBranch.hasLevels,
    icon = subBranch.icon,
    level = level,
    color = subBranch.color,
    accentColor = subBranch.accentColor,
    isBranch = subBranch.isBranch,
    isSkill = subBranch.isSkill,
  }
end

-- Child rows of a branch page. The careerSkills page drops retired skills: their XP already sits on a
-- canonical attribute, so listing them would repeat the parent's XP under other names.
local function collectChildSkills(branchId)
  local childSkills = {}
  for _, subBranch in pairs(overhaul_career_progression_skills.getSortedBranches()) do
    local retired = branchId == CAREER_SKILLS_DOMAIN_ID and not isVisibleSkillForPage(subBranch, branchId)
    if subBranch.parentId == branchId and not retired then
      local value = skillLookup.attributeValue(subBranch.attributeKey)
      if not shouldHideSkill(subBranch, value) then
        table.insert(childSkills, buildChildSkillInfo(subBranch, value))
      end
    end
  end
  return childSkills
end

-- Card data for a branch page. The Civil Service list card shows one aggregate instead of rows.
local function getBranchSkillCardData(branchId)
  branchId = canonicalParentBranchId(branchId)
  overhaul_career_progression_skills.checkUnlocks()
  local branch = overhaul_career_progression_skills.getBranchById(branchId)
  local branchInfo = buildBranchCard(branch)
  local childSkills = collectChildSkills(branchId)

  local isCivilServiceListCard = branch.id == CIVIL_SERVICE_LIST_CARD_BRANCH_ID
    or branch.attributeKey == CIVIL_SERVICE_LIST_CARD_BRANCH_ID
    or branchId == CIVIL_SERVICE_LIST_CARD_BRANCH_ID
  if isCivilServiceListCard then
    applyChildSkillAggregate(branchInfo, childSkills)
    branchInfo.skills = {}
    branchInfo.shortDescription = nil
  else
    branchInfo.skills = childSkills
    if branchId == CAREER_SKILLS_DOMAIN_ID then
      applyChildSkillAggregate(branchInfo, getVisibleChildSkillStats(branchId))
    end
  end

  return branchInfo
end

-- Landing page ----------------------------------------------------------------------------------------

-- Tiles for the children of the landing page's parent, filtered like the skills page.
local function landingEntries(pathId)
  local entries = {}
  for _, branch in ipairs(overhaul_career_progression_skills.getSortedBranches()) do
    if branch.parentId == pathId and branch.attributeKey ~= CIVIL_SERVICE_LIST_CARD_BRANCH_ID
        and (pathId ~= CAREER_SKILLS_DOMAIN_ID or visibleCareerSkillIds[branch.id] == true) then
      local branchValue = branch.attributeKey and skillLookup.attributeValue(branch.attributeKey)
      if not shouldHideSkill(branch, branchValue) then
        table.insert(entries, {
          id = branch.id,
          target = "skillPage",
          isSkill = branch.isSkill,
          description = branch.description,
        })
      end
    end
  end
  return entries
end

-- Breadcrumbs from the Skills root down to the domain, and the reward multiplier of the domain
-- or its nearest ancestor that sets one. Returns the crumbs (the root crumb is added by the caller).
local function domainTrail(domainBranch)
  local rewardMultiplier = overhaul_career_progression_skills.getLevelRewardMultiplier(domainBranch.id)
  local rewardMultiplierSourceIcon = rewardMultiplier and domainBranch.icon

  local trail = {}
  table.insert(trail, {label = core_locales.translateWithOrWithoutContext(domainBranch.name), routeName = "overhaul.branchPage", params = {pathId = domainBranch.id}})
  local parentBranch = overhaul_career_progression_skills.getBranchById(domainBranch.parentId)
  while parentBranch and not parentBranch.missing do
    rewardMultiplier = rewardMultiplier or overhaul_career_progression_skills.getLevelRewardMultiplier(parentBranch.id)
    rewardMultiplierSourceIcon = rewardMultiplierSourceIcon or (rewardMultiplier and parentBranch.icon)
    table.insert(trail, {label = core_locales.translateWithOrWithoutContext(parentBranch.name), routeName = "overhaul.branchPage", params = {pathId = parentBranch.id}})
    parentBranch = overhaul_career_progression_skills.getBranchById(parentBranch.parentId)
  end
  arrayReverse(trail)

  local crumbs = {}
  for _, crumb in ipairs(trail) do
    -- the Skills root crumb already stands for the careerSkills page
    if crumb.params.pathId ~= CAREER_SKILLS_DOMAIN_ID then
      table.insert(crumbs, crumb)
    end
  end
  return crumbs, rewardMultiplier, rewardMultiplierSourceIcon
end

local function domainHeaderInfo(domainBranch, value, level, min, max, rewardMultiplier, rewardMultiplierSourceIcon)
  return {
    name = domainBranch.name,
    icon = domainBranch.icon,
    glyphIcon = domainBranch.icon,
    color = domainBranch.color,
    accentColor = domainBranch.accentColor,
    unlocked = domainBranch.unlocked,
    levelLabel = overhaul_career_progression_skills.getLevelLabel(domainBranch.id, level),
    isMaxLevel = level >= #domainBranch.levels,
    isInDevelopment = domainBranch.isInDevelopment,
    min = min,
    value = value,
    max = max,
    level = level,
    hasLevels = domainBranch.hasLevels,
    rewardMultiplier = rewardMultiplier,
    rewardMultiplierSourceIcon = rewardMultiplierSourceIcon,
  }
end

-- Fills the landing page's heading, breadcrumbs, skill header and skill rows for a domain or branch.
local function applyDomainHeader(data, domainBranch)
  local crumbs, rewardMultiplier, rewardMultiplierSourceIcon = domainTrail(domainBranch)
  for _, crumb in ipairs(crumbs) do
    table.insert(data.breadcrumbs, crumb)
  end

  data.heading = domainBranch.name
  data.description = domainBranch.description
  data.branchHeading = domainBranch.branchHeading

  local value = skillLookup.attributeValue(domainBranch.attributeKey)
  local level, min, max = levelWindow(domainBranch, value)
  data.skillInfo = domainHeaderInfo(domainBranch, value, level, min, max, rewardMultiplier, rewardMultiplierSourceIcon)
  if domainBranch.id == CAREER_SKILLS_DOMAIN_ID then
    applyChildSkillAggregate(data.skillInfo, getVisibleChildSkillStats(domainBranch.id))
  end

  if domainBranch.isBranch or domainBranch.isSkill then
    if domainBranch.levels then
      data.skillInfo.unlockInfo, data.skillInfo.maxRequiredValue, data.skillInfo.hasUnlocks = calculateUnlockInfo(domainBranch, value, level)
    end
    data.skillInfo.hasUnlocks = data.skillInfo.hasUnlocks or false

    data.skills = getSkillsProgressForUi(domainBranch.id)
    data.leagues = {}
    data.isBranch = true
  end
end

local function getLandingPageData(pathId)
  pathId = canonicalParentBranchId(pathId)
  -- The Skills page is the progression root: stock domains are gone and Overhaul's logistics domain is never offered as a page.
  if not pathId or pathId == "" or pathId == "undefined" then
    pathId = CAREER_SKILLS_DOMAIN_ID
  end

  local skillsRoot = overhaul_career_progression_skills.getBranchById(CAREER_SKILLS_DOMAIN_ID)
  local rootLabel = skillsRoot and not skillsRoot.missing and core_locales.translateWithOrWithoutContext(skillsRoot.name) or "Skills"
  local data = {
    heading = rootLabel,
    description = "ui.career.landingPage.description",
    branches = landingEntries(pathId),
    breadcrumbs = {{label = _tr("ui.environment.pause"), routeName = "pause"}},
  }
  table.insert(data.breadcrumbs, {label = rootLabel, routeName = "overhaul.domainSelection"})

  local domainBranch = overhaul_career_progression_skills.getBranchById(pathId)
  if domainBranch then
    applyDomainHeader(data, domainBranch)
  end
  return data
end

-- Public API ------------------------------------------------------------------------------------------

local function resolveBranchTitle(pathId)
  local branch = pathId and overhaul_career_progression_skills.getBranchById(pathId) or nil
  if branch and not branch.missing then
    return core_locales.translateWithOrWithoutContext(branch.branchHeading or branch.name)
  end
  return "Skills"
end

M.getBranchSkillCardData = getBranchSkillCardData
M.resolveBranchTitle = resolveBranchTitle
M.getLandingPageData = getLandingPageData

return M
