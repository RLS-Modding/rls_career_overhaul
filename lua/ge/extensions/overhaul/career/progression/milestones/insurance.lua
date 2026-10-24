-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding
-- Fork of stock lua/ge/extensions/career/modules/milestones/generalMilestones/insurance.lua (BeamNG 0.40).
-- Insurance milestone: repair claims filed, with step targets and rewards.
-- Keeps the stock layout on purpose so it still diffs against stock.
local M = {}

local id = "insurance_repair_claims"
local stepsInfo = {1,5,10,20,50}
local milestones
local currMilestone = {}
M.onOverhaulGeneralMilestonesCollect = function(milestonesList)
  milestones = overhaul_career_progression_milestones_milestones
  currMilestone = {
    id = id,
    sortIndex = 0,
    filter = {insurance=true, general=true},
    type = "repair_claims",
    maxStep = #stepsInfo,
    icon = "publisher",
    color=milestones.colorGeneralGray,
    getValue = function() return overhaul_career_repair_insuranceHistory.getInsuranceClaimsCount() end,
    getLabel = function(step, displayValue, target) return "ui.career.milestones.insurance.repairClaims.label" end,
    getDescription = function(step, displayValue, target) return milestones.countDescription("ui.career.milestones.insurance.repairClaims.descriptionOne", "ui.career.milestones.insurance.repairClaims.descriptionMany", stepsInfo[step]) end,
    getProgressLabel = function(step, current, target) return {txt="ui.career.milestones.progress.count", context={current = current, target = target}} end,
    getTarget = function(step) return step == 0 and 0 or stepsInfo[step] end,
    getRewards = milestones.minorLinear,
  }

  milestones.saveData.general[id] = milestones.saveData.general[id] or {claimedStep = 0, notificationStep = 0}
  table.insert(milestonesList, currMilestone)
end

local function onOverhaulInsuranceRepairClaim()
  local step = milestones.saveData.general[id].notificationStep + 1
    -- check if milestone is completed
  if currMilestone.maxStep and step > currMilestone.maxStep then return end
  if overhaul_career_repair_insuranceHistory.getInsuranceClaimsCount() >= currMilestone.getTarget(step) then
    milestones.milestoneReached(currMilestone.getLabel(step))
    milestones.saveData.general[id].notificationStep = step
  end
end

M.onOverhaulInsuranceRepairClaim = onOverhaulInsuranceRepairClaim

return M