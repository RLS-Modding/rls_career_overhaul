-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Skill and branch milestones: one milestone per branch that owns its attribute, with a reward at each level.
-- Based on stock's generalMilestones/branches.lua, with canonical-attribute ownership and batched claims.
local M = {}

local branchIcon = {
  motorsport = "raceFlag",
  labourer = "deliveryTruckArrows",
  specialized = "carChase01",
  adventurer = "jump",
}

local attKeyToMilestone = {}
local milestones

local function skillLinear(step)
  return {{attributeKey = "money", rewardAmount = 10 * (step + 1)}}
end

-- Sets the next tier's target, unless every tier is claimed.
local function setNotificationTarget(attKey)
  local milestoneConfig = attKeyToMilestone[attKey]
  local step = milestones.saveData.general[milestoneConfig.id].notificationStep + 1
  if milestoneConfig.maxStep and step > milestoneConfig.maxStep then return end
  local target = milestoneConfig.getTarget(step)
  if target then
    milestoneConfig._target = target
  end
end

-- Several skills write their XP to a parent attribute (careerSkills-police -> careerSkills-emergency,
-- fre-trail -> careerSkills-offroad, ...). Their milestones would mirror the parent and pay the rewards twice,
-- so only the branch that owns the canonical attribute gets a milestone.
local function canonicalKey(attKey)
  local attributes = overhaul_career_economy_playerAttributes
  if attributes and attributes.canonicalAttributeKey then
    return attributes.canonicalAttributeKey(attKey) or attKey
  end
  return attKey
end

local function buildMilestoneOwners(sortedBranches)
  local owners = {}
  for _, branchInfo in ipairs(sortedBranches) do
    local attKey = branchInfo.attributeKey
    if not branchInfo.isInDevelopment and attKey then
      local canonical = canonicalKey(attKey)
      if canonical == attKey or not owners[canonical] then
        owners[canonical] = branchInfo
      end
    end
  end
  return owners
end

-- Builds the milestone for one branch or skill. Its progress is the attribute's value; its tiers are the branch levels.
local function buildBranchMilestone(branchInfo, sortIndex)
  local attKey = branchInfo.attributeKey
  local isBranch = not branchInfo.isSkill
  local levelCount = branchInfo.maxReachableLevel - 1 -- level 0 is the entry, not a tier
  local color = branchInfo.color
  if not color then
    color = overhaul_career_progression_skills.getBranchById(branchInfo.parentBranch).color
  end
  local filter = {branch = true, ["branch_" .. branchInfo.id] = true}
  if isBranch then
    filter.general = true
  end

  return {
    id = "branch_" .. branchInfo.id,
    sortIndex = 100 + sortIndex,
    branchKey = branchInfo.id,
    _attKey = attKey,
    filter = filter,
    type = "branch",
    hideTier = true, -- the description already names the target level
    minValueIsPreviousStepTarget = true,
    icon = branchIcon[branchInfo.parentBranch or branchInfo.id],
    color = color,
    getValue = function() return overhaul_career_economy_playerAttributes.getAttributeValue(attKey) end,
    getLabel = function(step, displayValue, target) return {txt = isBranch and "ui.career.branchSemicolon" or "ui.career.skillSemicolon", context = {branch = branchInfo.name}} end,
    getDescription = function(step, displayValue, target) return {txt = isBranch and "ui.career.milestones.branches.reachBranchLevel.description" or "ui.career.milestones.branches.reachSkillLevel.description", context = {lvl = step + 1, name = branchInfo.name}} end,
    getProgressLabel = function(step, current, target) return {txt = "ui.career.milestones.branches.progressLabel", context = {current = current, target = target}} end,
    getTarget = function(step) return branchInfo.levels[step + 1].requiredValue end,
    getRewards = isBranch and milestones.majorLinear or skillLinear,
    maxStep = levelCount,
  }
end

-- Claims every tier the player has already reached, so a maxed skill does not need one click per tier.
-- Returns the summed rewards and the number of tiers claimed.
local function claimReachedTiers(milestoneConfig, save)
  local current = milestoneConfig.getValue() or 0
  local sumChange, claimed = {}, 0
  while true do
    local step = (save.claimedStep or 0) + 1
    if milestoneConfig.maxStep and step > milestoneConfig.maxStep then break end
    local target = milestoneConfig.getTarget(step)
    if type(target) ~= "number" or current < target then break end
    for _, reward in pairs(milestoneConfig.getRewards(step - 1) or {}) do
      sumChange[reward.attributeKey] = (sumChange[reward.attributeKey] or 0) + (reward.rewardAmount or 0)
    end
    save.claimedStep = step
    claimed = claimed + 1
  end
  return sumChange, claimed
end

-- Stops the "milestone reached" notices from re-announcing the tiers that were just claimed.
local function syncNotificationStep(milestoneConfig, save)
  if (save.notificationStep or 0) < save.claimedStep then
    save.notificationStep = save.claimedStep
    milestoneConfig._target = nil
    M.setNotificationTarget(milestoneConfig._attKey)
  end
end

-- One toast and one reward grant for the whole batch.
local function announceBatchClaim(milestoneConfig, save, sumChange)
  local label = milestoneConfig.getLabel(save.claimedStep)
  overhaul_career_economy_playerAttributes.addAttributes(sumChange, require("overhaul/lib/finance/metadata").tag({tags = {"milestone", "reward", "gameplay"}, label = {txt = "ui.career.milestones.claimedRewardsFor", context = {milestoneName = label}}}, "reward", {vehicleRelated = false}))
  local rewardsLabel = {}
  for attributeKey, amount in pairs(sumChange) do
    table.insert(rewardsLabel, string.format("%s: +%d", attributeKey, amount))
  end
  table.sort(rewardsLabel)
  guihooks.trigger("toastrMsg", {type = "success", label = "Milestone-" .. milestoneConfig.id .. "-batch", msg = "ui.career.milestones.claimedRewardsForWithRewards", context = {milestoneName = label, rewards = table.concat(rewardsLabel, ", ")}})
end

local function onOverhaulGeneralMilestoneClaimed(milestoneConfig)
  if not milestones or type(milestoneConfig) ~= "table" or milestoneConfig.type ~= "branch" then return end
  if not milestoneConfig.branchKey or attKeyToMilestone[milestoneConfig._attKey or ""] ~= milestoneConfig then return end
  local save = milestones.saveData.general[milestoneConfig.id]
  if not save then return end
  local sumChange, claimed = claimReachedTiers(milestoneConfig, save)
  if claimed == 0 then return end
  syncNotificationStep(milestoneConfig, save)
  announceBatchClaim(milestoneConfig, save, sumChange)
end

local function onOverhaulGeneralMilestonesCollect(milestonesList)
  milestones = overhaul_career_progression_milestones_milestones
  table.clear(attKeyToMilestone)

  local sortedBranches = overhaul_career_progression_skills.getSortedBranches()
  local owners = buildMilestoneOwners(sortedBranches)
  for i, branchInfo in ipairs(sortedBranches) do
    if not branchInfo.isInDevelopment and owners[canonicalKey(branchInfo.attributeKey)] == branchInfo then
      local milestoneConfig = buildBranchMilestone(branchInfo, i)
      attKeyToMilestone[branchInfo.attributeKey] = milestoneConfig
      milestones.saveData.general[milestoneConfig.id] = milestones.saveData.general[milestoneConfig.id] or {claimedStep = 0, notificationStep = 0}
      table.insert(milestonesList, milestoneConfig)
    end
  end
end

local function onOverhaulGeneralMilestonesSetupCallbacks()
  for attKey in pairs(attKeyToMilestone) do
    M.setNotificationTarget(attKey)
  end
end

-- Reports a tier once the attribute reaches its target, then moves the target to the next tier.
local function onOverhaulPlayerAttributesChanged(change)
  for attKey, val in pairs(change) do
    local milestoneConfig = val > 0 and attKeyToMilestone[attKey]
    if milestoneConfig then
      local step = milestones.saveData.general[milestoneConfig.id].notificationStep + 1
      if milestoneConfig._target and milestoneConfig.getValue() >= milestoneConfig._target then
        extensions.hook("onOverhaulBranchTierReached", milestoneConfig.branchKey, step + 1)
        milestones.milestoneReached(milestoneConfig.getLabel(step))
        milestoneConfig._target = nil
        milestones.saveData.general[milestoneConfig.id].notificationStep = step
        M.setNotificationTarget(attKey)
      end
    end
  end
end

M.setNotificationTarget = setNotificationTarget
M.onOverhaulPlayerAttributesChanged = onOverhaulPlayerAttributesChanged
M.onOverhaulGeneralMilestoneClaimed = onOverhaulGeneralMilestoneClaimed
M.onOverhaulGeneralMilestonesCollect = onOverhaulGeneralMilestonesCollect
M.onOverhaulGeneralMilestonesSetupCallbacks = onOverhaulGeneralMilestonesSetupCallbacks

return M
