-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding
-- Fork of stock lua/ge/extensions/career/modules/milestones/generalMilestones/money.lua (BeamNG 0.40).
-- Money milestones: money gained and spent by category (rewards, deliveries, purchases, sales, fines), with step values.
-- Keeps the stock layout on purpose so it still diffs against stock.
local M = {}
local milestones
local moneyMilestones = {}
local moneyValues = {}
for _, k in ipairs({1000, 10000, 100000}) do
  for _, i in ipairs({1,2,5}) do
    table.insert(moneyValues, i*k)
  end
end
table.insert(moneyValues,1000000)

local modeConfigs = {
  {
    mode = "gains",
    tags = {"reward"},
    filter = {general=true},
    values = moneyValues,
    label = "ui.career.milestones.money.moneymaker.label",
    description = "ui.career.milestones.money.moneymaker.description",
    achievements = {{id="FIRST_PAYCHECK", amount=10000},{id="SIX_FIGURES", amount=100000}}
  },
  {
    mode = "losses",
    label = "ui.career.milestones.money.bigSpender.label",
    tags = {"buying"},
    filter = {general=true},
    values = moneyValues,
    description = "ui.career.milestones.money.bigSpender.description",
  },
  {
    mode = "losses",
    label = "ui.career.milestones.money.newPartsCostMoney.label",
    tags = {"partsBought"},
    filter = {},
    values = {5000,15000,50000},
    description = "ui.career.milestones.money.newPartsCostMoney.description",
  },
  {
    mode = "losses",
    label = "ui.career.milestones.money.vehicleBought.label",
    tags = {"vehicleBought"},
    filter = {},
    values = {10000,20000,500000},
    description = "ui.career.milestones.money.vehicleBought.description",
  },
  {
    mode = "gains",
    label = "ui.career.milestones.money.selling.label",
    tags = {"selling"},
    filter = {},
    values = {5000,15000,50000},
    description = "ui.career.milestones.money.selling.description",
  },

  {
    mode = "gains",
    tags = {"delivery"},
    filter = {},
    values = {5000,15000,50000,100000},
    label = "ui.career.milestones.money.deliveryEarner.label",
    description = "ui.career.milestones.money.deliveryEarner.description",
  },
  {
    mode = "losses",
    label = "ui.career.milestones.money.fine.label",
    tags = {"fine"},
    filter = {},
    values = {500,1500,5000},
    description = "ui.career.milestones.money.fine.description",
  },
}
M.onOverhaulGeneralMilestonesCollect = function(milestonesList)
  milestones = overhaul_career_progression_milestones_milestones

  for _, modeConfig in ipairs(modeConfigs) do
    local mode = modeConfig.mode
    local tags = modeConfig.tags
    local values = modeConfig.values
    local milestoneConfig = {
      id = "money_"..modeConfig.mode.."--"..table.concat(tags,"-"),
      sortIndex = 100,
      mode = modeConfig.mode,
      filter = modeConfig.filter or {},
      icon="beamCurrency",
      color=milestones.colorOrange,
      getValue = function()
        local sum = 0
        for _, tag in ipairs(tags) do
          sum = sum + math.abs(overhaul_career_economy_playerAttributes.getAttribute("money")[modeConfig.mode][tag] or 0)
        end
        return sum
      end,
      getLabel = function(step, displayValue, target) return modeConfig.label end,
      getDescription = function(step, displayValue, target) return {txt=modeConfig.description, context={amount = string.format("%0.2f", target)}} end,
      getProgressLabel = function(step, current, target) return {txt="ui.career.milestones.money.progressLabel", context={current = string.format("%0.2f", current), target = string.format("%0.2f", target)}} end,
      getTarget = function(step) return values[step] end,
      getRewards = milestones.minorLinear,
      maxStep = #values,
      achievements = modeConfig.achievements or {}
    }
    milestoneConfig.filter.money = true
    milestones.saveData.general[milestoneConfig.id] = milestones.saveData.general[milestoneConfig.id] or {claimedStep = 0, notificationStep = 0}
    table.insert(milestonesList, milestoneConfig)
    table.insert(moneyMilestones, milestoneConfig)
  end
end

M.onOverhaulGeneralMilestonesSetupCallbacks = function()
  for _, milestoneConfig in ipairs(moneyMilestones) do
    M.setNotificationTarget(milestoneConfig)
  end
end


-- branch related updates
local function setNotificationTarget(milestoneConfig)
  local step = milestones.saveData.general[milestoneConfig.id].notificationStep +1
  -- check if completed
  if milestoneConfig.maxStep and step > milestoneConfig.maxStep then return end
  local target = milestoneConfig.getTarget(step)
  if target then
    milestoneConfig._target = target
  end
end

local function onOverhaulPlayerAttributesChanged(change)
  if change.money then
    for _, milestoneConfig in ipairs(moneyMilestones) do
      local step = milestones.saveData.general[milestoneConfig.id].notificationStep +1
      if milestoneConfig._target and milestoneConfig.getValue() >= milestoneConfig._target then
        for _, achievement in ipairs(milestoneConfig.achievements) do
          if milestoneConfig.getValue() >= achievement.amount then
            gameplay_achievement.unlockAchievement(achievement.id)
          end
        end
        milestones.milestoneReached(milestoneConfig.getLabel(step))
        milestoneConfig._target = nil
        milestones.saveData.general[milestoneConfig.id].notificationStep = step
        M.setNotificationTarget(milestoneConfig)
      end
    end
  end
end
M.setNotificationTarget = setNotificationTarget
M.onOverhaulPlayerAttributesChanged = onOverhaulPlayerAttributesChanged

return M