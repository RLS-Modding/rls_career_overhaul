-- Passenger reward bounds shared by the built-in taxi preferences.
-- Arithmetic is supplied by the preference, so multiplication order and rounding stay unchanged.
local M = {}

function M.cappedTip(amount, maximum)
  return math.min(amount, maximum)
end

function M.clampRating(rating)
  if rating > 5 then rating = 5 end
  if rating < 1 then rating = 1 end
  return rating
end

return M
