-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding

-- Delivery achievements are granted once per save through progress.deliveryAchievements. This extension keeps its saved name; delivery introductions are not enabled.
-- Read deliveryAchievements, then onDeliveryCompleted, which progress calls after each delivery.
local M = {}
local dProgress
M.onCareerActivated = function()
  dProgress = overhaul_career_logistics_progress
end

local deliveryAchievements = {
  parcel = "DELIVERY_TUTORIAL_COMPLETED",
  vehicle = "VEHICLE_DELIVERY_COMPLETED",
  material = "MATERIALS_DELIVERY_COMPLETED",
}

M.onDeliveryCompleted = function(deliveryType)
  local achievement = deliveryAchievements[deliveryType]
  if not achievement or not dProgress then return end
  local progress = dProgress.getProgress()
  progress.deliveryAchievements = progress.deliveryAchievements or {}
  if progress.deliveryAchievements[achievement] then return end
  gameplay_achievement.unlockAchievement(achievement)
  progress.deliveryAchievements[achievement] = true
end

return M
