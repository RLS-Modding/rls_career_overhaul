-- Owns per-event drag runtime policy values.
-- definitions.lua supplies accepted event settings; drag/runner.lua and the coordinator consume the policy.
local M = {minEntrants = 16, maxEntrants = 48, passIntervalSeconds = 15, maxPassIntervalSeconds = 60}

function M.fieldSize(availableEntrants)
  local maximum = math.min(M.maxEntrants, availableEntrants or M.maxEntrants)
  if maximum < 2 then return nil end
  local minimum = math.min(M.minEntrants, maximum)
  return math.random(minimum, maximum)
end

local definitions = require('overhaul/events/motorsportEvents/definitions')

function M.passInterval(eventState)
  local policy = definitions.event(eventState)
  if not eventState or eventState.phase ~= 'eliminations' or not eventState.bracket then return policy.passIntervalSeconds end
  local first = eventState.bracket.rounds and eventState.bracket.rounds[1]
  if not first then return policy.passIntervalSeconds end
  local matches = #first.matches
  local rounds = 1
  while matches > 1 do matches = math.ceil(matches / 2); rounds = rounds + 1 end
  local progress = rounds > 1 and (eventState.bracket.currentRound - 1) / (rounds - 1) or 1
  return math.floor(policy.passIntervalSeconds + (policy.maxPassIntervalSeconds - policy.passIntervalSeconds) * math.min(1, progress) + .5)
end

return M
