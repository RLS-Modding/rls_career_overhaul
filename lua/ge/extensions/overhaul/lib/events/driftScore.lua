-- Read stock banked points plus the current chain without retaining failed chains.
local M = {}

local function points(value)
  local number = tonumber(value)
  if number and number >= 0 and number < math.huge then return number end
end

function M.read(scoring)
  if not scoring or type(scoring.getScore) ~= "function" then return nil, nil end
  local data = scoring.getScore()
  if type(data) ~= "table" then return nil, nil end
  local banked = points(data.score) or 0
  local cached, combo = points(data.cachedScore), points(data.combo)
  local pending
  if cached == 0 then
    pending = 0
  elseif cached and combo and combo > 0 then
    pending = points(math.floor(cached * combo))
  else
    -- Both 0.40 builds expose potentialScore = floor(cachedScore * combo).
    pending = points(data.potentialScore)
    if not pending and type(scoring.getPotentialScore) == "function" then
      pending = points(scoring.getPotentialScore())
    end
  end
  return points(banked + (pending or 0)) or banked, combo
end

function M.take(scoring, general)
  local score = M.read(scoring)
  if score ~= nil and general and type(general.reset) == "function" then
    general.reset()
  end
  return score or 0
end

return M
