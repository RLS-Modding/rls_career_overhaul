-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
-- Copyright (C) RLS Modding
-- SPDX-License-Identifier: AGPL-3.0-only

-- Ground-marker route lease: set (one position or a waypoint list), isCurrent and clear
-- act only on the path this lease set, so another owner's route
-- is never cleared by mistake. `owner` is an optional label (the activity id when created through the activity host).
local M = {}

-- Whether the marker target is still where this lease put it (for markers without a path generation).

local function samePosition(position, target)
  return math.abs(position.x - target.x) < 0.001
    and math.abs(position.y - target.y) < 0.001
    and math.abs(position.z - target.z) < 0.001
end

function M.new(owner)
  local markers, generation, target = nil, nil, nil
  local lease = {}
  function lease.getOwner() return owner end
  function lease.isCurrent()
    local groundMarkers = core_groundMarkers
    if not target or groundMarkers ~= markers then return false end
    if groundMarkers.currentlyHasTarget and not groundMarkers.currentlyHasTarget() then return false end
    if generation and groundMarkers.getPathGeneration then return groundMarkers.getPathGeneration() == generation end
    local current = groundMarkers.getTargetPos and groundMarkers.getTargetPos()
    return current and samePosition(current, target) or false
  end
  function lease.set(pos, options)
    local groundMarkers = core_groundMarkers
    if not groundMarkers or not groundMarkers.setPath or not pos then return false end
    groundMarkers.setPath(pos, options)
    local first = type(pos) == "table" and pos[1] or pos
    markers, target = groundMarkers, {x = first.x, y = first.y, z = first.z}
    generation = groundMarkers.getPathGeneration and groundMarkers.getPathGeneration() or nil
    return true
  end
  function lease.clear()
    if lease.isCurrent() then
      if generation and markers.clearOwnedPath then markers.clearOwnedPath(generation)
      else markers.setPath(nil) end
    end
    markers, generation, target = nil, nil, nil
  end
  return lease
end

return M
