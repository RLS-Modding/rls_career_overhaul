-- Owns the shared Gambling skill limits and net-result XP calculation.
-- Parts: cardGames and drag/betting supply stakes/results; payment owns wallet/skill mutations.
-- Contract: pure rules, dollars in/cap out, integer XP out; no wallet or session state.
local M = {attribute = 'careerSkills-gambling', minimum = 50, defaultCap = 1000}
M.thresholds = {
  {xp = 301000, cap = 50000}, {xp = 225000, cap = 30000},
  {xp = 162000, cap = 25000}, {xp = 113000, cap = 20000},
  {xp = 75000, cap = 15000}, {xp = 46000, cap = 10000},
  {xp = 26000, cap = 5000}, {xp = 13000, cap = 2500},
  {xp = 5300, cap = 2000}, {xp = 1400, cap = 1500},
}
function M.maxBet(xp)
  for _, tier in ipairs(M.thresholds) do if (tonumber(xp) or 0) >= tier.xp then return tier.cap end end
  return M.defaultCap
end
function M.xp(net)
  if type(net) ~= 'number' or net ~= net or math.abs(net) == math.huge then return 0 end
  if net < 0 then return math.floor(.30 * (9 / 130) * math.abs(net)) end
  return math.floor((9 / 130) * net)
end
return M
