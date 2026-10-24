-- Entry and registration may admit a seller even when there is no room to buy.
local M = {}
local buildConfig = require('overhaul/lib/vehicles/buildConfig')

-- The same maximum part odometer used by the garage, with the saved reading
-- retained when conditions are unavailable (for example during a reload).
function M.mileageMeters(inventoryId)
  local inventory = overhaul_career_garage_inventory
  local vehicle = inventory.getVehicle(inventoryId)
  if not vehicle then return nil end
  if vehicle.partConditions and inventory.setMileage then return inventory.setMileage(inventoryId) end
  return vehicle.mileage
end

-- Keep paid entry eligibility aligned with the player lot builder.
function M.canBuildLot(vehicle)
  if not vehicle or not vehicle.model or type(vehicle.config) ~= 'table' then
    return false
  end
  return buildConfig.canBuild(vehicle.config)
end

-- Everything inventory.sellVehicle needs when an NPC wins the lot: an owned, non-loaned car with no
-- access timer (repair, delivery, rental, engine job) that logistics can release, and a buildable lot.
function M.saleBlockReason(inventoryId, vehicle)
  if not vehicle or vehicle.owned ~= true then return 'Not owned' end
  if vehicle.loanType then return 'Loaned car' end
  if vehicle.timeToAccess ~= nil then return 'Not in storage' end
  if not overhaul_career_logistics_general.canRemoveLogisticsVehicle(inventoryId, true) then return 'In use for a delivery' end
  if not M.canBuildLot(vehicle) then return 'Vehicle configuration unavailable' end
end

function M.canSell(inventoryId, vehicle)
  return M.saleBlockReason(inventoryId, vehicle) == nil
end

function M.getListedVehicleIds()
  local inventory = overhaul_career_garage_inventory
  if inventory.getListedVehicleIds then return inventory.getListedVehicleIds() end
  -- Keep callers working across an inventory extension reload from the single-listing version.
  local id = inventory.getListedVehicleId and inventory.getListedVehicleId()
  return id and {id} or {}
end

function M.hasListedVehicle()
  local inventory = overhaul_career_garage_inventory
  for _, inventoryId in ipairs(M.getListedVehicleIds()) do
    local vehicle = inventory.getVehicle(inventoryId)
    if vehicle and vehicle.listedForAuction == true and M.canSell(inventoryId, vehicle) then return true end
  end
  return false
end

return M
