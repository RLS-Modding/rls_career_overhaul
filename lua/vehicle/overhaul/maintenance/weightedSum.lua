-- Adds terms left to right from the first argument, preserving calibrated floating-point results.
-- Stateless callable used by engine and transmission calculations.
local function weightedSum(...)
  local total = select(1, ...)
  for index = 2, select('#', ...) do
    total = total + select(index, ...)
  end
  return total
end

return weightedSum
