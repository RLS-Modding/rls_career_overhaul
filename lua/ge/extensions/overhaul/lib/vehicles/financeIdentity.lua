-- Inventory ids are reusable slots. Keep a saved identity for a particular vehicle's
-- financial lifetime so a replacement, even the same model, gets a separate group.
local M = {}
function M.ensure(vehicle, createId)
  if type(vehicle.financeId) == "string" and vehicle.financeId ~= "" then return vehicle.financeId, false end
  vehicle.financeId = "vehicle:" .. createId()
  return vehicle.financeId, true
end
return M
