-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding
-- Fork of stock lua/ge/extensions/career/modules/milestones/generalMilestones/speedTraps.lua (BeamNG 0.40).
-- Speed-trap milestones: the top speed through any trap, the share of traps triggered and the total trigger count.
-- Keeps the stock layout on purpose so it still diffs against stock.
local M = {}
local milestones, speedTraps
local velocityMilestonesByTrapName = {}
local velocityMilestone
local allTrapMilestone
local triggerCounterMilestone
M.onOverhaulGeneralMilestonesCollect = function(milestonesList)
  milestones = overhaul_career_progression_milestones_milestones
  speedTraps = overhaul_integration_services_speedTraps
  table.clear(velocityMilestonesByTrapName)

  -- one milestone per speedTrap
  -- TODO getAllSpeedTraps. consider traps in other levels too?
  -- TODO speedTrap needs to have field for a UI name (some name)
  -- individual speed traps disabled ATM
  --[[
  for _, trap in ipairs(speedTraps.getSpeedTrapsInCurrentLevel("speed")) do
    local milestoneId = "velocityMilestone_" .. trap:getName()
    local name = trap:getName()
    local velocityMilestone = {
      id = milestoneId,
      filter = {speedTrap=true},
      type = "velocity",
      icon = "movieCamera",
      maxStep = 4,
      color = milestones.colorGeneralGray,
      getValue = function() return milestones.saveData.general[milestoneId].maxVelocityReachedByPlayer or 0 end,
      getLabel = function(step, current, target) return string.format('Speeding in %s', name) end,
      getDescription = function(step, current, target) return string.format("Trigger the speed trap %s by driving very fast in front of it. Watch for the flash!", name) end,
      getProgressLabel = function(step, current, target) return {txt="ui.career.milestones.speedTrapVelocity.progressLabel", context={current = current, target = target}} end,
      getTarget = function(step) return trap.speedLimit + 6*(step-1) end, -- so it starts at speedlimit for first step
      getRewards = milestones.minorLinear,
    }
    -- setup save data
    milestones.saveData.general[milestoneId] = milestones.saveData.general[milestoneId] or {claimedStep = 0, notificationStep = 0, maxVelocityReachedByPlayer = 0}
    -- save reference to the milestone config
    velocityMilestonesByTrapName[name] = velocityMilestone
    table.insert(milestonesList, velocityMilestone)
  end
  ]]


  -- trigger each speed camera at least once
  -- also disabled until we have a proper speedtraps/level system
  --[[
  local allTrapMilestoneId = "allSpeedTrapMilestone"
  local numOfTraps = tableSize(velocityMilestonesByTrapName)
  local stepPercent = {0.01,0.3,0.6,1.0}
  allTrapMilestone = {
    id = allTrapMilestoneId,
    filter = {speedTrap=true, general=true},
    type = "velocity",
    maxStep = #stepPercent,
    icon = "movieCamera",
    color = milestones.colorGeneralGray,
    getValue = function()
      local numOfTrapsTriggered = 0
      for name, velocityMilestone in pairs(velocityMilestonesByTrapName) do
        if milestones.saveData.general[velocityMilestone.id].notificationStep > 0 then
          numOfTrapsTriggered = numOfTrapsTriggered + 1
        end
      end
      return numOfTrapsTriggered
     end,
    getLabel = function(step, current, target) return string.format("Speeding Menace") end,
    getDescription = function(step, current, target) return string.format("Trigger %s different speed traps.", target) end,
    getProgressLabel = function(step, current, target) return string.format("%d / %d", current, target) end,
    getTarget = function(step) return step == 0 and 0 or math.ceil(stepPercent[step]*numOfTraps) end,
    getRewards = milestones.majorLinear,
  }
  -- setup save data
  milestones.saveData.general[allTrapMilestoneId] = milestones.saveData.general[allTrapMilestoneId] or {claimedStep = 0, notificationStep = 0}
  table.insert(milestonesList, allTrapMilestone)
  ]]

  -- one milestone for an all-time high across all speed traps
  local milestoneId = "velocitySpeedTrapMilestone"
  local speeds = {70/3.6, 90/3.6, 120/3.6, 150/3.6, 180/3.6, 220/3.6}
  velocityMilestone = {
    id = milestoneId,
    filter = {speedTrap=true},
    type = "velocity",
    icon = "powerGauge05",
    maxStep = #speeds,
    color = milestones.colorGeneralGray,
    getValue = function() return milestones.saveData.general[milestoneId].maxVelocityReachedByPlayer or 0 end,
    getLabel = function(step, current, target) return "ui.career.milestones.speedTrapVelocity.label" end,
    getDescription = function(step, current, target) return "ui.career.milestones.speedTrapVelocity.description" end,
    getProgressLabel = function(step, current, target) return {txt="ui.career.milestones.speedTrapVelocity.progressLabel", context={current = current, target = target}} end,
    getTarget = function(step) return speeds[step] end, -- so it starts at speedlimit for first step
    getRewards = milestones.minorLinear,
  }
  -- setup save data
  milestones.saveData.general[milestoneId] = milestones.saveData.general[milestoneId] or {claimedStep = 0, notificationStep = 0, maxVelocityReachedByPlayer = 0}
  -- save reference to the milestone config
  table.insert(milestonesList, velocityMilestone)


  -- one milestone for tracking the total amount of triggers
  local triggerCounterMilestoneId = "speedTrapTriggerCounterMilestone"
  triggerCounterMilestone = {
    id = triggerCounterMilestoneId,
    filter = {speedTrap=true, general=true},
    type = "velocity",
    icon = "powerGauge05",
    color = milestones.colorGeneralGray,
    maxStep = 10,
    getValue = function() return milestones.saveData.general[triggerCounterMilestoneId].triggerCount or 0 end,
    getLabel = function(step, current, target) return "ui.career.milestones.speedTrapTriggerCounter.label" end,
    getDescription = function(step, current, target) return "ui.career.milestones.speedTrapTriggerCounter.description" end,
    getProgressLabel = function(step, current, target) return {txt="ui.career.milestones.progress.count", context={current = current, target = target}} end,
    getTarget = function(step) return (step) * 15 end,
    getRewards = milestones.minorLinear,
  }
  -- setup save data
  milestones.saveData.general[triggerCounterMilestoneId] = milestones.saveData.general[triggerCounterMilestoneId] or {claimedStep = 0, notificationStep = 0, triggerCount = 0 }
  table.insert(milestonesList, triggerCounterMilestone)
end

local function onSpeedTrapTriggered(speedTrapData, playerSpeed, overSpeed)
  if not speedTrapData.speedLimit then return end
  local vehId = speedTrapData.subjectID
  if not vehId then
    return
  end

  if vehId ~= be:getPlayerVehicleID(0) then
    return
  end

  local saveData = milestones.saveData.general


  -- update the players record
  if playerSpeed > saveData[velocityMilestone.id].maxVelocityReachedByPlayer then
    -- this could also be used for a message... even tho its not milestone releated.
    saveData[velocityMilestone.id].maxVelocityReachedByPlayer = playerSpeed
  end

  -- loop-check if a new milestone has been reached
  local checkNext = true
  while checkNext do
    local maxVelocitySaveData = saveData[velocityMilestone.id]
    local maxVelocity = maxVelocitySaveData.maxVelocityReachedByPlayer
    local velocityTarget = velocityMilestone.getTarget(maxVelocitySaveData.notificationStep + 1)
    if velocityTarget == nil then
      -- no more steps
      checkNext = false
    else
      if maxVelocity >= velocityTarget then
        milestones.milestoneReached(velocityMilestone.getLabel(maxVelocitySaveData.notificationStep + 1))
        maxVelocitySaveData.notificationStep = maxVelocitySaveData.notificationStep + 1
      else
        checkNext = false
      end
    end
  end

  -- all Traps milestone
  --[[
  local allTrapsSaveData = saveData[allTrapMilestone.id]
  local allTrapsTarget = allTrapMilestone.getTarget(allTrapsSaveData.notificationStep + 1)
  if allTrapMilestone.getValue() >= allTrapsTarget then
    milestones.milestoneReached(allTrapMilestone.getLabel(allTrapsSaveData.notificationStep + 1))
    allTrapsSaveData.notificationStep = allTrapsSaveData.notificationStep + 1
  end
  ]]

  -- trigger counter milestone
  local milestoneSaveData = saveData[triggerCounterMilestone.id]
  local counterTarget = triggerCounterMilestone.getTarget(milestoneSaveData.notificationStep + 1)
  if counterTarget then
    milestoneSaveData.triggerCount = milestoneSaveData.triggerCount + 1
    if milestoneSaveData.triggerCount >= counterTarget then
      milestones.milestoneReached(triggerCounterMilestone.getLabel(milestoneSaveData.notificationStep + 1))
      milestoneSaveData.notificationStep = milestoneSaveData.notificationStep + 1
    end
  end
end


-- after a milestone is claimed, also re-register the watch
M.onOverhaulGeneralMilestoneClaimed = registerStastisticCallback
M.onSpeedTrapTriggered = onSpeedTrapTriggered

return M