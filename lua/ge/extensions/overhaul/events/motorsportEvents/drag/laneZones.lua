-- Owns lane boundary geometry for event racers.
-- drag/runner.lua installs strip-derived zones; vehicle helpers enforce the supplied lane boundaries.
local M = {}

function M.attach(data)
  local lanes = {}
  for _, lane in ipairs(data.strip and data.strip.lanes or {}) do
    local zone, direction = lane.zone, lane.stageToEndNormalized
    local stage = lane.waypoints and lane.waypoints.stage
    local origin = stage and stage.transform and stage.transform.pos
    if not zone or type(zone.containsPoint2D) ~= 'function' or not origin or not direction then return function() end end
    local length = math.sqrt(direction.x * direction.x + direction.y * direction.y)
    if length < .001 then return function() end end
    lanes[#lanes + 1] = {lane = lane, zone = zone, x = origin.x, y = origin.y, nx = -direction.y / length, ny = direction.x / length}
  end
  if #lanes < 2 then return function() end end
  local function distance(lane, point)
    return math.abs((point.x - lane.x) * lane.nx + (point.y - lane.y) * lane.ny)
  end
  for _, own in ipairs(lanes) do
    own.wrapper = setmetatable({containsPoint2D = function(_, point)
      if not own.zone:containsPoint2D(point) then return false end
      local offset = distance(own, point)
      for _, other in ipairs(lanes) do
        if other ~= own and other.zone:containsPoint2D(point) and distance(other, point) + .000001 < offset then return false end
      end
      return true
    end}, {__index = own.zone})
    own.lane.zone = own.wrapper
  end
  return function()
    for _, own in ipairs(lanes) do if own.lane.zone == own.wrapper then own.lane.zone = own.zone end end
  end
end

return M
