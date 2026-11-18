-- Owns pure qualifying averages, odds and stake/closure validation for drag/betting.
-- Parts: gameplay/overhaul/motorsportBetting.json owns tuning; lib/progression/gambling owns skill caps.
-- Contract: times in seconds, decimal returns include stake; missing/invalid tuning disables markets.
local gambling = require('overhaul/lib/progression/gambling')
local M = {}
local tuning
local function finite(n) return type(n) == 'number' and n == n and math.abs(n) < math.huge end
function M.average(entrant)
  local sum, count = 0, 0
  for _, run in ipairs(entrant.qualifyingAttempts or {entrant.qualifying}) do
    if run.valid == true and not run.breakout and finite(run.time) and run.time > 0 then
      sum, count = sum + run.time, count + 1
    end
  end
  if count > 0 then return sum / count, count end
end
function M.configure(config)
  tuning = nil
  M.window = nil
  if type(config) ~= 'table' then return false end
  for _, key in ipairs({'windowSeconds', 'oddsScaleSeconds', 'houseMarginRatio', 'minimumWinProbabilityRatio', 'maximumWinProbabilityRatio'}) do
    if not finite(config[key]) then return false end
  end
  if config.windowSeconds <= 0 or config.oddsScaleSeconds <= 0 or config.houseMarginRatio < 0 or config.houseMarginRatio >= 1
    or config.minimumWinProbabilityRatio <= 0 or config.maximumWinProbabilityRatio >= 1
    or config.minimumWinProbabilityRatio >= config.maximumWinProbabilityRatio then return false end
  tuning = config
  M.window = config.windowSeconds
  return true
end
function M.prices(a, b)
  if not tuning then return end
  if not finite(a) or not finite(b) then return end
  local p = 1 / (1 + math.exp(math.max(-40, math.min(40, (a - b) / tuning.oddsScaleSeconds))))
  -- Do not manufacture value on near-certain outcomes or extreme long shots.
  if p < tuning.minimumWinProbabilityRatio or p > tuning.maximumWinProbabilityRatio then return end
  return math.floor((1 - tuning.houseMarginRatio) / p * 100) / 100, math.floor((1 - tuning.houseMarginRatio) / (1 - p) * 100) / 100
end
function M.validStake(stake, wallet, xp)
  return finite(stake) and stake == math.floor(stake) and stake >= gambling.minimum
    and stake <= gambling.maxBet(xp) and stake <= wallet
end
function M.closed(runtime)
  if not runtime or runtime.phase == 'idle' or runtime.phase == 'cooldown' then return true end
  local staged, count = 0, 0
  for _, row in ipairs(runtime.racers or {}) do
    count = count + 1
    if row.phase == 'race' or row.phase == 'stop' or row.phase == 'emergencyStop' or row.phase == 'DNF' then return true end
    if row.staged or row.phase == 'countdown' then staged = staged + 1 end
  end
  return count == 2 and staged == 2
end
function M.key(event, match)
  return table.concat({event.id, event.activeClassId or 'open', match.id}, ':')
end
return M
