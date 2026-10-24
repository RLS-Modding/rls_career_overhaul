-- The GE progress tracker and VE driver share the same origin-space trajectory.
-- Only terminal points get the vehicle's front-reference offset in the driver.
local M = {}

function M.points(routePoints, target, direction, options)
  options = options or {}
  local terminalDistance = tonumber(options.terminalStartDistance) or 15
  local result = {}
  for _, point in ipairs(routePoints) do
    local dx, dy, dz = point.x - target.x, point.y - target.y, point.z - target.z
    if math.sqrt(dx * dx + dy * dy + dz * dz) > terminalDistance then
      result[#result + 1] = {x = point.x, y = point.y, z = point.z, v = tonumber(point.v)}
    end
  end
  local approach = options.approach or {
    {distance = 15, speed = 2.2}, {distance = 9, speed = 1.5},
    {distance = 4, speed = 0.9}, {distance = 0, speed = 0.45},
    {distance = -2, speed = 0}
  }
  for _, point in ipairs(approach) do
    local distance = tonumber(point.distance) or 0
    result[#result + 1] = {
      x = target.x - direction.x * distance,
      y = target.y - direction.y * distance,
      z = target.z - direction.z * distance,
      v = tonumber(point.speed), terminal = true
    }
  end
  return result
end

return M
