-- Shared eligibility for broker cargo saved against an inventory vehicle.
-- Owners supply a late inventory lookup so save queries also work without a loaded broker.
local M = {}

function M.canPersistCargo(cargo, inventoryId)
  return cargo.data and cargo.data.brokerId and cargo.location
    and cargo.location.type == "vehicle"
    and ((cargo.logisticsBinding and cargo.logisticsBinding.inventoryId) or inventoryId(cargo.location.vehId)) ~= nil
end

return M
