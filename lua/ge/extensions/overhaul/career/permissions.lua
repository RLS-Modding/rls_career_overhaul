-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Fork of stock lua/ge/extensions/career/modules/permissions.lua (BeamNG 0.40).
-- Asks the features which permission applies to an action tag and returns the strictest answer.
-- Reading order: config, then the strictest-answer helpers, then the public getStatusForTag.

local M = {}

-- Action tags the features answer for. Every tag defaults to "allowed"; a feature hook can restrict it.
local permissionTags = {
  vehicleModification = "allowed", -- slow and fast repairing, changing and buying parts, tuning, painting
  vehicleSelling = "allowed", -- selling a vehicle
  vehicleStorage = "allowed", -- put vehicles into storage
  vehicleRetrieval = "allowed", -- retrieve vehicles from storage

  vehicleShopping = "allowed",

  interactRefuel = "allowed", -- use the refueling POI to refuel the vehicle
  interactMission = "allowed", -- use the mission POI to start a mission
  interactDelivery = "allowed", -- use any delivery POI to start delivery mode

  recoveryFlipUpright = "allowed", -- flip upright
  recoveryTowToRoad = "allowed", -- tow to road
  recoveryTowToGarage = "allowed", -- tow to garage
}

-- Permissions are assumed not to change during an activity; split the activity if they do.
local permissionPriorities = {
  allowed = 0,
  warning = 1,
  forbidden = 2,
  hidden = 3,
}

-- The answer with the highest priority, or nil when no feature answered.
local function strictestAnswer(answers)
  local strictest
  for _, answer in ipairs(answers) do
    if not strictest or permissionPriorities[answer.permission] > permissionPriorities[strictest.permission] then
      strictest = answer
    end
  end
  return strictest
end

-- Returns { allow, permission, label, type, penalty } for one tag or a list of tags.
function M.getStatusForTag(tags, additionalData)
  local answers = {}
  if type(tags) ~= "table" then
    tags = {tags}
  end
  extensions.hook("onOverhaulCheckPermission", tags, answers, additionalData)

  local strictest = strictestAnswer(answers)
  if not strictest then
    return {permission = "allowed", allow = true}
  end
  return {
    allow = strictest.permission == "warning",
    permission = strictest.permission,
    label = strictest.label,
    type = "text",
    penalty = strictest.penalty,
  }
end

return M
