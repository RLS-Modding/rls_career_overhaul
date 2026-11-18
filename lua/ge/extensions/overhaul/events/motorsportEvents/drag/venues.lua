-- Owns drag venue discovery and selection.
-- Native drag data supplies strip geometry; motorsportEvents.lua consumes chosen venue descriptors.
local M = {}

function M.list(level)
  local venues = {}
  for _, data in pairs(gameplay_drag_core.getDragDataForLevel(level) or {}) do
    local strip = data.strip
    local valid = strip and strip.id and data._originFile and strip.lanes and #strip.lanes == 2
    if valid then
      for _, lane in ipairs(strip.lanes) do
        for _, name in ipairs({'spawn', 'stage', 'endLine'}) do
          local waypoint = lane.waypoints and lane.waypoints[name]
          local transform = waypoint and waypoint.transform
          if not transform or not transform.pos or not transform.rot then valid = false end
        end
      end
    end
    if valid then venues[#venues + 1] = data end
  end
  table.sort(venues, function(a, b) return a.strip.id < b.strip.id end)
  return venues
end

function M.choose(level, stripId)
  local venues = M.list(level)
  if stripId then
    for _, venue in ipairs(venues) do if venue.strip.id == stripId then return venue end end
    return nil
  end
  if #venues > 0 then return venues[math.random(#venues)] end
end

return M
