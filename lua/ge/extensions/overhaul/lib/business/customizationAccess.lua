-- Build-changing business services use the mapped paid record, never the UI's personal copy.
local M = {}

function M.getRepairReason(businessId, vehicleId, vehicle)
  local personal = tostring(vehicleId):sub(1, 9) == 'personal_'
  if personal then
    local inventory = overhaul_career_garage_inventory
    local spawnedId = tonumber(tostring(vehicleId):sub(10))
    local inventoryId = inventory and spawnedId and inventory.getInventoryIdFromVehicleId(spawnedId)
    local vehicles = inventory and inventory.getVehicles()
    vehicle = inventoryId and vehicles and vehicles[inventoryId]
    -- A stale UI identity cannot authorize replacing an unbound inventory car.
    if not vehicle then return {label = 'Vehicle not found'} end
  elseif not vehicle then
    vehicle = overhaul_career_business_fleet.getVehicleById(businessId, vehicleId)
  end
  if vehicle and overhaul_career_market_valueCalculator.getNumberOfBrokenParts(vehicle.partConditions or {}) > 0 then
    return overhaul_career_garage_computer.reasons.needsRepair
  end
end

function M.allow(businessId, vehicleId, vehicle)
  local reason = M.getRepairReason(businessId, vehicleId, vehicle)
  if not reason then return true end
  guihooks.trigger('toastrMsg', {type = 'warning', title = 'Vehicle unavailable', msg = reason.label})
  return false
end

return M
