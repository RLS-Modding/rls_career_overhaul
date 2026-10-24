-- How close the drive is to its rpm, load and heat limits; each category supplies its own ramp starts and weights.
-- Owns the limit-stress factor shared by the engine and transmission maintenance models.
local common = require('vehicle/overhaul/maintenance/common')
local weightedSum = require('vehicle/overhaul/maintenance/weightedSum')

return function(env, limitStressFractions)
  env = env or {}
  local rpmNearLimit = common.clamp(common.linearScale(env.rpmFactor or 0, limitStressFractions.rpmRampStart, 1, 0, 1), 0, 1)
  local loadNearLimit = common.clamp(common.linearScale(env.loadFactor or 0, limitStressFractions.loadRampStart, 1, 0, 1), 0, 1)
  local heatNearLimit = common.clamp(common.linearScale(env.heatFactor or 0, limitStressFractions.heatRampStart, 1, 0, 1), 0, 1)
  local overheatFactor = common.clamp(env.overheatFactor or 0, 0, 1)

  return common.clamp(weightedSum(rpmNearLimit * limitStressFractions.rpm, loadNearLimit * limitStressFractions.load,
    heatNearLimit * limitStressFractions.heat, overheatFactor * limitStressFractions.overheat), 0, limitStressFractions.maximum)
end
