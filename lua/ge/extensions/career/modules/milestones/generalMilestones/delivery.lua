-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

local deliveryCounterConfigs = {
  {
    progressKey = "parcel",
    icon = "cardboardBox",
    label = "Parcel Processor",
    description = "Deliver %d parcels.",
    progressLabel = "%d / %d",
    targets = {5,25,50,100,150,250}
  },
  {
    progressKey = "vehicle",
    label = "Car Jockey",
    icon = "carStarred",
    description = "Deliver %d vehicles.",
    progressLabel = "%d / %d",
    targets = {1,4,9,25,35,50},
  },
  {
    progressKey = "trailer",
    label = "Trained Trailer Transporter",
    icon = "smallTrailer",
    description = "Deliver %d trailers.",
    progressLabel = "%d / %d",
    targets = {1,4,9,25,35,50},
  },
  {
    progressKey = "fluid",
    icon = "droplet",
    label = "Go with the Flow",
    description = "Deliver %dL of fluids.",
    progressLabel = "%d / %d",
    targets = {100,1000,10000,100000}
  },
  {
    progressKey = "dryBulk",
    icon = "rocks",
    label = "Gravel Travel",
    description = "Deliver %dL of dry bulk.",
    progressLabel = "%d / %d",
    targets = {100,1000,10000,100000}
  },  
  {
    progressKey = "cement",
    icon = "rocks",
    label = "Cement Travel",
    description = "Deliver %dL of cement.",
    progressLabel = "%d / %d",
    targets = {100,1000,10000,100000}
  }
}

local parcelModConfigs = {
  {
    modKey = "timed",
    progressKey = "onTimeDeliveries",
    icon = "stopwatchSectionSolidStart",
    label = "Ahead of the Curve",
    description = "Deliver %d timed parcels on time.",
    progressLabel = "%d / %d",
    targets = {1,8,20,50}
  }, {
    modKey = "timed",
    progressKey = "delayedDeliveries",
    icon = "stopwatchSectionSolidStart",
    label = "Detour Dilemma",
    description = "Deliver %d timed parcels delayed.",
    progressLabel = "%d / %d",
    targets = {1,8,20,50}
  }, {
    modKey = "timed",
    progressKey = "lateDeliveries",
    icon = "stopwatchSectionSolidStart",
    label = "Lost in Transit",
    description = "Deliver %d timed parcels late.",
    progressLabel = "%d / %d",
    targets = {1,8,20,50}
  }
}

local milestones, dProgress, dParcelMods
local milestoneConfigs = {}
M.onGeneralMilestonesCollect = function(milestonesList)
  dProgress = career_modules_delivery_progress
  dParcelMods = career_modules_delivery_parcelMods
  milestones = career_modules_milestones_milestones
  for _, config in ipairs(deliveryCounterConfigs) do
    local milestoneConfig = {
      id = config.progressKey.."deliveryProgress",
      filter = {delivery=true, gameplay=true},
      maxStep = #config.targets,
      icon = config.icon,
      color = milestones.colorGeneralGray,
      getValue = function() return dProgress.getProgress().cargoDeliveredByType[config.progressKey] or 0 end,
      getLabel = function(step, displayValue, target) return config.label end,
      getDescription = function(step, displayValue, target) return string.format(config.description, target) end,
      getProgressLabel = function(step, current, target) return string.format(config.progressLabel, current, target) end,
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
      getValue = function() return (dParcelMods.getProgress()[config.modKey] or {})[config.progressKey] or 0 end,
      getLabel = function(step, displayValue, target) return config.label end,
      getDescription = function(step, displayValue, target) return string.format(config.description, target) end,
      getProgressLabel = function(step, current, target) return string.format(config.progressLabel, current, target) end,
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
    getValue = function() return dProgress.getFacilityCountForCargoCount("deliveredFromHere") end,
    getLabel = function(step, displayValue, target) return "Facility Finder" end,
    getDescription = function(step, displayValue, target) return string.format("Deliver any kind of cargo from %d different facilities.", target) end,
    getProgressLabel = function(step, current, target) return string.format("%d / %d", current, target) end,
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
    getValue = function() return dProgress.getFacilityCountForCargoCount("deliveredToHere") end,
    getLabel = function(step, displayValue, target) return "Facility Satisfier" end,
    getDescription = function(step, displayValue, target) return string.format("Deliver any kind of cargo to %d different facilities.", target) end,
    getProgressLabel = function(step, current, target) return string.format("%d / %d", current, target) end,
    getTarget = function(step) return step == 0 and 0 or receiverSteps[step] end,
    getRewards = milestones.minorLinear,
  }
  table.insert(milestonesList, deliverFromConfig)
  table.insert(milestoneConfigs, deliverFromConfig)

end


M.onGeneralMilestonesSetupCallbacks = function()
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

local function onDeliveryFacilityProgressStatsChanged()
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

M.onDeliveryFacilityProgressStatsChanged = onDeliveryFacilityProgressStatsChanged

return M