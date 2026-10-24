-- Refresh deleted vehicles cached in front of a walker before leaving walking mode.
-- Stock rebuilds that cache only on its next frame, so an immediate entry can still see a dead object.
local M = {}

local function readObjectId(object)
  return object:getId()
end

-- The engine raises an error for any method called on a deleted object; there is no query.
local function isDeletedObject(object)
  return not pcall(readObjectId, object)
end

function M.dropDeletedVehicleInFront(walk, player)
  if not walk or not walk.getVehicleInFront or not walk.onUpdate then return false end
  local target = walk.getVehicleInFront(player)
  if target == nil or not isDeletedObject(target) then return false end
  log("W", "walkTarget", "Vehicle in front of the walker was deleted; refreshing it before leaving walking mode")
  walk.onUpdate(0, 0)
  return true
end

function M.leaveWalkingModeForced(walk)
  M.dropDeletedVehicleInFront(walk)
  return walk.setWalkingMode(false, nil, nil, true)
end

return M
