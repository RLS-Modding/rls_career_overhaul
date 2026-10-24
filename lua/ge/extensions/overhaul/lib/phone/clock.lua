-- Shared phone clock projection; reading the current label never emits a UI event.
local M = {}

function M.format(timeOfDay)
  local totalMinutes = ((timeOfDay + 0.5) % 1) * 1440
  local hours = math.floor(totalMinutes / 60)
  local minutes = math.floor(totalMinutes % 60)
  local period = hours < 12 and 'AM' or 'PM'
  local twelveHour = hours % 12
  return string.format('%d:%02d %s', twelveHour == 0 and 12 or twelveHour, minutes, period)
end

function M.current()
  local timeOfDay = scenetree and scenetree.tod and scenetree.tod.time
  if timeOfDay ~= nil then return M.format(timeOfDay) end
end

return M
