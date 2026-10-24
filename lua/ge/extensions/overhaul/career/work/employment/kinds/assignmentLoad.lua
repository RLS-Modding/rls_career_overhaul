-- Load kinds (parcel, materials, repo): the company vehicle must be issued, and the start is presented on ready.
-- Handlers use the parent's state so equipment and wages belong to the same shift.
local M = {}

function M.rejectSpawn(shiftInputs, job, shift)
  local shared = shiftInputs.shared
  if shift.issuedInventoryIds and shift.issuedInventoryIds[1] then return end
  shared.shiftLog("afterSpawn blocked", string.format("%s job missing company vehicle after spawn", tostring(job.kind)))
  shiftInputs.routing.handleMissingCompanySpawn("Company vehicle did not spawn at the yard.")
  return true
end

function M.presentationReady(shiftInputs)
  shiftInputs.markShiftStartPresentationReady()
end

return M
