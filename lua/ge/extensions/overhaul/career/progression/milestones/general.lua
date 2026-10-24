-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding
-- Fork of stock lua/ge/extensions/career/modules/milestones/general.lua (BeamNG 0.40).
-- General milestone collector: asks each milestone extension for its configs on activation and serves them by id.
-- Keeps the stock layout on purpose so it still diffs against stock.
local recordClaim = require("overhaul/lib/progression/logbookFeed").register("overhaul.milestoneClaimed", {
  title = "Milestone claimed", label = "Milestones", icon = "checkmark"
}, "career/progression/milestones/general.lua")

local M = {}
local optional = require("overhaul/lib/platform/optional")
local milestoneConfigs = {}
local milestonesById = {}

local typeOrder = {
  stat = 0,
  branch = 1,
}


-- collector order of the stock career's hook dispatch; the renamed extensions resolve in a different order.
-- Full extension names, so the rename tooling can find and rewrite each one.
local collectorOrder = {
  "overhaul_career_progression_milestones_skills",
  "overhaul_career_progression_milestones_delivery",
  "overhaul_career_progression_milestones_insurance",
  "overhaul_career_progression_milestones_money",
  "overhaul_career_progression_milestones_speedTraps",
  "overhaul_career_progression_milestones_statistic",
}

local function collectMilestones(list)
  local collected = {}
  local names = {}
  for _, name in ipairs(collectorOrder) do
    table.insert(names, name)
  end
  for _, name in ipairs(extensions.getLoadedExtensionsNames()) do
    table.insert(names, name)
  end
  for _, name in ipairs(names) do
    local ext = not collected[name] and optional(name)
    if ext and type(ext.onOverhaulGeneralMilestonesCollect) == "function" then
      collected[name] = true
      ext.onOverhaulGeneralMilestonesCollect(list)
    end
  end
end

local milestones
M.onOverhaulActive = function(active)
  if not active then return end
  milestoneConfigs = {}
  milestonesById = {}
  milestones = overhaul_career_progression_milestones_milestones
  milestones.saveData.general = milestones.saveData.general or {}
  -- get all milestones from subsystems.
  collectMilestones(milestoneConfigs)

  --cache/sort Ids.
  for i, milestone in ipairs(milestoneConfigs) do
    milestonesById[milestone.id] = milestone
    milestone._generatedId = i
  end

  -- check savedata correctness
  for _, milestone in ipairs(milestoneConfigs) do
    milestones.saveData.general[milestone.id] = milestones.saveData.general[milestone.id] or {claimedStep = 0, notificationStep = 0}
    if not milestones.saveData.general[milestone.id].claimedStep then
      log("W","",string.format("Milestone %s has no 'claimedStep' in its savedata. Please addd it you make custom savedata!", dumps(milestone.id)))
    end
  end

  -- sort by group and
  table.sort(milestones, function(a,b) if a.type == b.type then return a._generatedId < b._generatedId else return a.type < b.type end end)

  -- notify systems to set up callbacks, if they have any.
  extensions.hook('onOverhaulGeneralMilestonesSetupCallbacks')
end

-- milestone system interaction
local function claim(id)
  local milestoneConfig = milestonesById[id]
  local saveData = milestones and milestones.saveData.general and milestones.saveData.general[id]
  if not milestoneConfig or not saveData then return false end
  local step = saveData.claimedStep
  if milestoneConfig.maxStep and step + 1 > milestoneConfig.maxStep then return false end
  if milestoneConfig.getValue() < milestoneConfig.getTarget(step + 1) then return false end
  local sumChange = {}
  local rewardsLabel = {}
  for _, reward in pairs(milestoneConfig.getRewards(step)) do
    sumChange[reward.attributeKey] = (sumChange[reward.attributeKey] or 0) + reward.rewardAmount
    table.insert(rewardsLabel, core_locales.contextTranslate("ui.career.milestones.claimedRewardLine", {
      attributeLabel = overhaul_career_economy_playerAttributes.getRewardDisplayName(reward.attributeKey),
      amount = reward.rewardAmount
    }))
  end
  overhaul_career_economy_playerAttributes.addAttributes(sumChange, require("overhaul/lib/finance/metadata").tag({tags={"milestone","reward", "gameplay"}, label={txt = "ui.career.milestones.claimedRewardsFor", context = { milestoneName = milestoneConfig.getLabel(step)}}}, "reward", {vehicleRelated = false}))
  milestones.saveData.general[id].claimedStep = step + 1
  recordClaim({detail = milestoneConfig.getLabel(step),
    money = sumChange.money, receipt = tostring(id) .. ":" .. tostring(step + 1)})
  extensions.hook("onOverhaulGeneralMilestoneClaimed", milestoneConfig)

  guihooks.trigger("toastrMsg", {type="success", label="Milestone-"..id.."-"..step, msg = "ui.career.milestones.claimedRewardsForWithRewards", context = {milestoneName =milestoneConfig.getLabel(step), rewards=table.concat(rewardsLabel,', ')}})

  --guihooks.trigger("toastrMsg", {type="success", label=milestoneConfig.getLabel(step), msg="test: <br>" .. table.concat(rewardsLabel,', ')})
end
M.claim = claim

local function getMilestone(id)
  -- current step is the next one after the currently claimed one.
  local step = milestones.saveData.general[id].claimedStep + 1
  --log("I","","Getting milestone " .. id .." / " .. step)
  local milestoneConfig = milestonesById[id]
  local current = milestoneConfig.getValue()
  if milestoneConfig.maxStep and step > milestoneConfig.maxStep then
    local target = milestoneConfig.getTarget(milestoneConfig.maxStep)
    local elem = {
      label = milestoneConfig.getLabel(milestoneConfig.maxStep, current, target),
      description = milestoneConfig.getDescription(milestoneConfig.maxStep, current, target),
      filter = milestoneConfig.filter or {},
      progress = {},
      rewards = nil,
      hideTier = milestoneConfig.hideTier,
      maxStep = milestoneConfig.maxStep,
      step = milestoneConfig.maxStep,
      icon = milestoneConfig.icon or "star",
      color = milestoneConfig.color or "orange",
      completed = true,
    }
    return elem
  else
    local target = milestoneConfig.getTarget(step)
    local displayValue = math.min(target, current)
    local minValue = milestoneConfig.getTarget(step-1)
    local currValue = displayValue
    local maxValue = target

    if milestoneConfig.minValueIsPreviousStepTarget then
      currValue = currValue - minValue
      maxValue = maxValue - minValue
      minValue = minValue - minValue
    else
      minValue = 0
    end

    local elem = {
      label = milestoneConfig.getLabel(step, displayValue, target),
      description = milestoneConfig.getDescription(step, displayValue, target),
      filter = milestoneConfig.filter or {},
      progress = {{
        type = "progressBar",
        minValue = minValue,
        currValue = currValue,
        maxValue = maxValue,
        label = milestoneConfig.getProgressLabel(step, currValue, maxValue),
        done = displayValue >= target,
      }},
      hideTier = milestoneConfig.hideTier,
      maxStep = milestoneConfig.maxStep,
      step = step-1,
      icon = milestoneConfig.icon or "star",
      color = milestoneConfig.color or "orange",
      rewards = milestoneConfig.getRewards(step-1),
      claimable = displayValue >= target,
      claimFunction = function() M.claim(id) end,
      claimRefreshFunction = function() if not milestoneConfig.maxStep or milestoneConfig.maxStep >= step then return M.getMilestone(id) end end
    }
    return elem
  end
end
M.getMilestone = getMilestone

local function onOverhaulGetMilestones(list, filter)
  for _, milestoneConfig in ipairs(milestoneConfigs) do
    local valid = true
    if filter and next(filter) then
      valid = false
      if milestoneConfig.filter then
        for _, filterId in ipairs(filter) do
          if milestoneConfig.filter[filterId] then
            valid = true
          end
        end
      end
    end
    if valid then
      table.insert(list, getMilestone(milestoneConfig.id))
    end
  end
end
M.onOverhaulGetMilestones = onOverhaulGetMilestones

M.printDebug = function()
  local csvdata = require('csvlib').newCSV("id","step","maxStep","name","description","target","money","xp")
  for _, c in ipairs(milestoneConfigs) do
    for s = 1, (c.maxStep or 1) do
      local name = c.getLabel(s, -1, -1)
      if type(name) == "table" then name = _tr(name.txt) .. (dumps(name.context or {})) end
      local target = c.getTarget(s)
      local desc = c.getDescription(s, -1, target)
      if type(desc) == "table" then desc = _tr(desc.txt) .. (dumps(desc.context or {})) end

      local r = c.getRewards(s)

      csvdata:add(c.id,  s, (c.maxStep or 1), name, desc, target, r[1].rewardAmount, r[2].rewardAmount)
    end
  end
  csvdata:write("/temp/rls_career/milestones.csv")
end

return M