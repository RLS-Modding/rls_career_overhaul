-- Job-cargo query for a coupled rig and vehicles carried on its beds.
-- Owners supply live services; loaded business stock is an active delivery.
local M = {}

function M.hasJobCargo(vehId, services)
  vehId = tonumber(vehId)
  if not vehId or vehId < 0 then return false end
  local ids = {vehId}
  if services.playerVehicles then
    services.playerVehicles.fillCouplerGroup(vehId, ids, {resolveLead = true})
  end
  local rig = {[vehId] = true}
  for _, id in ipairs(ids) do rig[id] = true end
  local parcels = services.parcelManager
  for _, cargo in ipairs(parcels and parcels.getAllCargoInVehicles(true) or {}) do
    local location = cargo.location
    if location and location.type == "vehicle" and rig[location.vehId]
        and not (cargo.data and cargo.data.delivered) then return true end
  end
  local tasks = services.vehicleTasks
  for _, task in ipairs(tasks and tasks.getVehicleTasks() or {}) do
    if not task.remove and not task.finished and not task.giveBack and task.vehId and task.vehId >= 0
        and task.offer then
      if rig[task.vehId] then return true end
      if tasks.getCargoCarrier then
        local carrier, pending = tasks.getCargoCarrier(task.vehId, ids)
        if carrier or pending then return true end
      end
    end
  end
  return false
end

return M
