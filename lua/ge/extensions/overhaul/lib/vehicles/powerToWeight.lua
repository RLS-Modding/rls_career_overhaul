-- Who should win a heads-up race, read from both cars' power-to-weight. Shared by car-meet challengers and the No Prep Knights boss.
local M = {}
local function finite(n) return type(n)=='number' and n==n and n>0 and n<math.huge end
function M.ratio(stats)
  if type(stats)~='table' or not finite(stats.power) or not finite(stats.weight) then return end
  return stats.power/stats.weight
end
-- How sure the opponent is of winning, 0 to 1, from both power-to-weight ratios; 0.5 means even cars.
function M.confidence(p, o) return math.max(0,math.min(1,(o/p-0.65)/0.7)) end
return M
