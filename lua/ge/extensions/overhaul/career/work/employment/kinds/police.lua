-- Service vehicle admission belongs to this shift owner.
-- Read allowsPersonalVehicle, finalAssignment, handoffTasklist in order.

local M = {}

function M.allowsPersonalVehicle(_, inventoryId)
  local inventory = overhaul_career_garage_inventory
  return inventory and inventory.getVehicleRole(inventoryId) == 'police'
end
function M.finalAssignment()
  for _, vehicle in pairs(gameplay_traffic and gameplay_traffic.getTrafficData() or {}) do
    if vehicle.pursuit and (tonumber(vehicle.pursuit.mode) or 0) > 0 then return true end
  end
  return false
end
function M.handoffTasklist()
  if not overhaul_career_career.isActive() then return end
  overhaul_career_police_policeTasklist.refresh()
end
return M
