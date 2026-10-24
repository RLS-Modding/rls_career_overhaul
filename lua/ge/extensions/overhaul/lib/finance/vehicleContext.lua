-- Aggregate identity snapshots without consulting the current player vehicle.
local M = {}
function M.single(ids, snapshots, hasUnknown, otherContributors)
  ids = ids or {}
  local first = next(ids)
  if not first or next(ids, first) or hasUnknown or (otherContributors or 0) > 0 then return {} end
  local vehicle = (snapshots or {})[first] or {}
  return {vehicleId = first, vehicleKey = vehicle.vehicleKey, vehicleName = vehicle.vehicleName}
end
return M
