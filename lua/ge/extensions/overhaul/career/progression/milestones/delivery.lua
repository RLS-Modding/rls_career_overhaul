-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Fork of stock lua/ge/extensions/career/modules/milestones/generalMilestones/delivery.lua (BeamNG 0.40).
-- Delivery milestones: cargo delivered by type, parcel-mod counts and facility counts, each with step targets and rewards.
-- Keeps the stock layout on purpose so it still diffs against stock.
local M = {}

local deliveryCounterConfigs = {
  {
    progressKey = "parcel",
    icon = "cardboardBox",
    label = "ui.career.milestones.delivery.parcel.label",
    description = "ui.career.milestones.delivery.parcel.description",
    targets = {5,25,50,100,150,250}
  },
  {
    progressKey = "vehicle",
    label = "ui.career.milestones.delivery.vehicle.label",
    icon = "carStarred",
    description = "ui.career.milestones.delivery.vehicle.description",
    targets = {1,4,9,25,35,50},
  },
  {
    progressKey = "trailer",
    label = "ui.career.milestones.delivery.trailer.label",
    icon = "smallTrailer",
    description = "ui.career.milestones.delivery.trailer.description",
    targets = {1,4,9,25,35,50},
  },
  {
    progressKey = "fluid",
    icon = "droplet",
    label = "ui.career.milestones.delivery.fluid.label",
    description = "ui.career.milestones.delivery.fluid.description",
    targets = {100,1000,10000,100000}
  },
  {
    progressKey = "dryBulk",
    icon = "rocks",
    label = "ui.career.milestones.delivery.dryBulk.label",
    description = "ui.career.milestones.delivery.dryBulk.description",
    targets = {100,1000,10000,100000}
  },  
  {
    progressKey = "cement",
    icon = "rocks",
    label = "Cement Travel",
    descriptionFormat = "Deliver %dL of cement.",
    targets = {100,1000,10000,100000}
  },
  {
    progressKey = "cash",
    icon = "beamCurrency",
    label = "Cash Delivery",
    descriptionFormat = "Deliver %d cash.",
    targets = {100,1000,10000,100000}
  }
}

local parcelModConfigs = {
  {
    modKey = "timed",
    progressKey = "onTimeDeliveries",
    icon = "stopwatchSectionSolidStart",
    label = "ui.career.milestones.delivery.timed.onTime.label",
    description = "ui.career.milestones.delivery.timed.onTime.description",
    targets = {1,8,20,50}
  }, {
    modKey = "timed",
    progressKey = "delayedDeliveries",
    icon = "stopwatchSectionSolidStart",
    label = "ui.career.milestones.delivery.timed.delayed.label",
    description = "ui.career.milestones.delivery.timed.delayed.description",
    targets = {1,8,20,50}
  }, {
    modKey = "timed",
    progressKey = "lateDeliveries",
    icon = "stopwatchSectionSolidStart",
    label = "ui.career.milestones.delivery.timed.late.label",
    description = "ui.career.milestones.delivery.timed.late.description",
    targets = {1,8,20,50}
  }
}

local milestones, logisticsProgress, parcelMods
local milestoneConfigs = {}
M.onOverhaulGeneralMilestonesCollect = function(milestonesList)
  logisticsProgress = overhaul_career_logistics_progress
  parcelMods = overhaul_career_logistics_parcelMods
  milestones = overhaul_career_progression_milestones_milestones
  for _, config in ipairs(deliveryCounterConfigs) do
    local milestoneConfig = {
      id = config.progressKey.."deliveryProgress",
      filter = {delivery=true, gameplay=true},
      maxStep = #config.targets,
      icon = config.icon,
      color = milestones.colorGeneralGray,
      getValue = function() return logisticsProgress.getProgress().cargoDeliveredByType[config.progressKey] or 0 end,
      getLabel = function(step, displayValue, target) return config.label end,
      getDescription = function(step, displayValue, target)
        if config.descriptionFormat then
          return {txt = string.format(config.descriptionFormat, math.floor(tonumber(target) or 0))}
        end
        return {txt=config.description, context={count = target, volume = target}}
      end,
      getProgressLabel = function(step, current, target) return {txt="ui.career.milestones.progress.count", context={current = current, target = target}} end,
      getTarget = function(step) return step == 0 and 0 or config.targets[step] end,
      getRewards = milestones.minorLinear,
    }
    table.insert(milestonesList, milestoneConfig)
    table.insert(milestoneConfigs, milestoneConfig)
  end

  for _, config in ipairs(parcelModConfigs) do
    local milestoneConfig = {
      id = config.modKey .. "/"..config.progressKey.."-parcelMods",
      filter = {delivery=true, gameplay=true},
      maxStep = #config.targets,
      icon = config.icon,
      color = milestones.colorGeneralGray,
      getValue = function() return (parcelMods.getProgress()[config.modKey] or {})[config.progressKey] or 0 end,
      getLabel = function(step, displayValue, target) return config.label end,
      getDescription = function(step, displayValue, target) return {txt=config.description, context={count = target}} end,
      getProgressLabel = function(step, current, target) return {txt="ui.career.milestones.progress.count", context={current = current, target = target}} end,
      getTarget = function(step) return step == 0 and 0 or config.targets[step] end,
      getRewards = milestones.minorLinear,
    }
    table.insert(milestonesList, milestoneConfig)
    table.insert(milestoneConfigs, milestoneConfig)
  end

  local providerSteps = {1,4,9,16,25}
  local receiverSteps = {1,4,9,16,25,35,45}
  local deliverToConfig =  {
    id = "deliverToMilestone",
    filter = {delivery=true, gameplay=true},
    maxStep = #providerSteps,
    icon = "garage01",
    color=milestones.colorGeneralGray,
    getValue = function() return logisticsProgress.getFacilityCountForCargoCount("deliveredFromHere") end,
    getLabel = function(step, displayValue, target) return "ui.career.milestones.delivery.facilityFinder.label" end,
    getDescription = function(step, displayValue, target) return {txt="ui.career.milestones.delivery.facilityFinder.description", context={count = target}} end,
    getProgressLabel = function(step, current, target) return {txt="ui.career.milestones.progress.count", context={current = current, target = target}} end,
    getTarget = function(step) return step == 0 and 0 or providerSteps[step] end,
    getRewards = milestones.minorLinear,
  }
  table.insert(milestonesList, deliverToConfig)
  table.insert(milestoneConfigs, deliverToConfig)

  local deliverFromConfig =  {
    id = "deliverFromMilestone",
    filter = {delivery=true, gameplay=true},
    maxStep = #receiverSteps,
    icon = "garage01",
    color=milestones.colorGeneralGray,
    getValue = function() return logisticsProgress.getFacilityCountForCargoCount("deliveredToHere") end,
    getLabel = function(step, displayValue, target) return "ui.career.milestones.delivery.facilitySatisfier.label" end,
    getDescription = function(step, displayValue, target) return {txt="ui.career.milestones.delivery.facilitySatisfier.description", context={count = target}} end,
    getProgressLabel = function(step, current, target) return {txt="ui.career.milestones.progress.count", context={current = current, target = target}} end,
    getTarget = function(step) return step == 0 and 0 or receiverSteps[step] end,
    getRewards = milestones.minorLinear,
  }
  table.insert(milestonesList, deliverFromConfig)
  table.insert(milestoneConfigs, deliverFromConfig)

end


M.onOverhaulGeneralMilestonesSetupCallbacks = function()
  for _, milestoneConfig in ipairs(milestoneConfigs) do
    M.setNotificationTarget(milestoneConfig)
  end
end

local function setNotificationTarget(milestoneConfig)
  local step = milestones.saveData.general[milestoneConfig.id].notificationStep +1
  -- check if milestone is completed
  if milestoneConfig.maxStep and step > milestoneConfig.maxStep then return end
  local target = milestoneConfig.getTarget(step)
  if target then
    milestoneConfig._target = target
  end
end
M.setNotificationTarget = setNotificationTarget

local function onOverhaulDeliveryFacilityProgressStatsChanged()
  for _, milestoneConfig in ipairs(milestoneConfigs) do
    local step = milestones.saveData.general[milestoneConfig.id].notificationStep +1
    if milestoneConfig._target and milestoneConfig.getValue() >= milestoneConfig._target then
      milestones.milestoneReached(milestoneConfig.getLabel(step))
      milestoneConfig._target = nil
      milestones.saveData.general[milestoneConfig.id].notificationStep = step
      M.setNotificationTarget(milestoneConfig)
    end
  end
end

M.onOverhaulDeliveryFacilityProgressStatsChanged = onOverhaulDeliveryFacilityProgressStatsChanged

return M