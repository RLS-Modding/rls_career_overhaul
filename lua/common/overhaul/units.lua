-- Exact shared conversions for GE and vehicle Lua; tuning approximations stay with their owner.
-- Keeping exact values here prevents the two VMs from drifting during conversion.
local M = {}

M.METERS_PER_MILE = 1609.344
M.MS_TO_KMH = 3.6
M.AV_TO_RPM = 9.549296596425384
M.STANDARD_GRAVITY_MS2 = 9.80665

function M.fahrenheitToCelsius(temperatureF)
  return (temperatureF - 32) * 5 / 9
end

return M
