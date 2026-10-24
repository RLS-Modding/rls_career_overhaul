-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding
-- Fork of stock lua/ge/extensions/career/modules/milestones/generalMilestones/statistic.lua (BeamNG 0.40).
-- Statistic milestones: distance, play time and other tracked statistics, each with step targets and rewards.
-- Keeps the stock layout on purpose so it still diffs against stock.
local M = {}
local milestones
  -- statistic milestones
local statisticMilestonesConfig
local function clearStatisticCallbacks()
  for _, milestone in ipairs(statisticMilestonesConfig or {}) do
    M.clearStatisticCallback(milestone)
  end
end
M.onOverhaulGeneralMilestonesCollect = function(milestonesList)
  -- The statistic service outlives this owner and a fresh milestone collection.
  clearStatisticCallbacks()
  milestones = overhaul_career_progression_milestones_milestones
  statisticMilestonesConfig = {
    {
      id = "stat_distance",
      sortIndex = 0,
      watchStatisticKey = "vehicle/total_odometer.length",
      filter = {statistic=true, general=true},
      type = "stat",
      icon = "odometer",
      color = milestones.colorGeneralGray,
      maxStep = 8,
      getValue = function() return (gameplay_statistic.metricGet("vehicle/total_odometer.length", true) or {value=0}).value end,
      getLabel = function(step, current, target) return "ui.career.milestones.statistic.distance.label" end,
      getDescription = function(step, current, target) return {txt="ui.career.milestones.statistic.distance.description", context={distance = string.format("%0.1f", target/1000)}} end,
      getProgressLabel = function(step, current, target) return {txt="ui.career.milestones.statistic.distance.progressLabel", context={current = string.format("%0.1f", current/1000), target = string.format("%0.1f", target/1000)}} end,
      getTarget = function(step) return step == 0 and 0 or ({10,20,35,60,90,145,215,300})[step]*1000 end,
      getRewards = milestones.majorLinear,
    },
    {
      id = "stat_playtime",
      sortIndex = 1,
      watchStatisticKey = "general/mode/career.time",
      filter = {statistic=true, general=true},
      type = "stat",
      icon = "timer",
      color = milestones.colorGeneralGray,
      maxStep = 8,
      getValue = function() return (gameplay_statistic.metricGet("general/mode/career.time", true) or {value=0}).value end,
      getLabel = function(step, current, target) return "ui.career.milestones.statistic.playtime.label" end,
      getDescription = function(step, current, target) return {txt="ui.career.milestones.statistic.playtime.description", context={hours = target/3600}} end,
      getProgressLabel = function(step, current, target) return {txt="ui.career.milestones.statistic.playtime.progressLabel", context={currentHours = math.floor(current / 3600), currentMinutes = math.floor(((current % 3600) or 0) / 60), targetHours = target/3600}} end,
      getTarget = function(step) return step == 0 and 0 or math.max(1,(step)*5)*3600 end,
      getRewards = milestones.majorLinear,
    },
    {
      id = "stat_rollover",
      sortIndex = 2,
      watchStatisticKey = "vehicle/rollover",
      filter = {statistic=true, general=true},
      type = "stat",
      icon = "carToWheels",
      color = milestones.colorGeneralGray,
      maxStep = 8,
      getValue = function() return (gameplay_statistic.metricGet("vehicle/rollover", true)  or {value=0}).value end,
      getLabel = function(step, current, target) return "ui.career.milestones.statistic.rollovers.label" end,
      getDescription = function(step, current, target) return milestones.countDescription("ui.career.milestones.statistic.rollovers.descriptionOne", "ui.career.milestones.statistic.rollovers.descriptionMany", target) end,
      getProgressLabel = function(step, current, target) return {txt="ui.career.milestones.progress.count", context={current = current, target = target}} end,
      getTarget = function(step) return step == 0 and 0 or math.max(1,math.floor(math.pow(step-1,1.5))*5) end,
      getRewards = milestones.majorLinear,
    },
    {
      id = "jump",
      sortIndex = 3,
      watchStatisticKey = "vehicle/airtime.time",
      filter = {statistic=true, general=true},
      type = "stat",
      icon = "jump",
      color = milestones.colorGeneralGray,
      maxStep = 8,
      getValue = function() return (gameplay_statistic.metricGet("vehicle/airtime.time", true) or {value=0}).value  end,
      getLabel = function(step, current, target) return "ui.career.milestones.statistic.airtime.label" end,
      getDescription = function(step, current, target) return {txt="ui.career.milestones.statistic.airtime.descriptionTotal", context={duration = milestones.durationLabel(target)}} end,
      getProgressLabel = function(step, current, target) return {txt="ui.career.milestones.progress.count", context={current = milestones.durationLabel(current), target = milestones.durationLabel(target)}} end,
      getTarget = function(step) return step == 0 and 0 or math.max(1,math.floor(math.pow(step,1.5)))*30 end,
      getRewards = milestones.majorLinear,
    },
  }
  for _, milestone in ipairs(statisticMilestonesConfig) do
    table.insert(milestonesList, milestone)
  end
end

M.onOverhaulGeneralMilestonesSetupCallbacks = function(milestone)
  for _, milestone in ipairs(statisticMilestonesConfig) do
    M.registerStastisticCallback(milestone)
  end
end

-- statistic callback functions
local function clearStatisticCallback(milestone)
  if not milestone._statCallback then return end
  gameplay_statistic.callbackRemove(milestone.watchStatisticKey, milestone._callbackTrigger, milestone._statCallback, true)
  milestone._statCallback = nil
  milestone._callbackTrigger = nil
end

local function registerStastisticCallback(milestone)
  if not milestone.watchStatisticKey then return end

  M.clearStatisticCallback(milestone)

  local saveEntry = milestones.saveData.general[milestone.id]
  local step = math.max(saveEntry.claimedStep, saveEntry.notificationStep or 0) + 1
  if step < milestone.maxStep then
    local statCallback = function()
      log("I","",string.format("Milestone Reached: %s %0.2f!", milestone.getLabel(step), milestone.getTarget(step)))
      milestones.milestoneReached(milestone.getLabel(step))
      saveEntry.notificationStep = step
      milestone._statCallback = nil
    end
    milestone._statCallback = statCallback
    milestone._callbackTrigger = milestone.getTarget(step)
    gameplay_statistic.callbackRegister(milestone.watchStatisticKey, milestone.getTarget(step), statCallback, true)
  end
end

-- after a milestone is claimed, also re-register the watch
M.onOverhaulGeneralMilestoneClaimed = registerStastisticCallback
M.registerStastisticCallback = registerStastisticCallback
M.clearStatisticCallback = clearStatisticCallback
M.onExtensionUnloaded = clearStatisticCallbacks





return M
