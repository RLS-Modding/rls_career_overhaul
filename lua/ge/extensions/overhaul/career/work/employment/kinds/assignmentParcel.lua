-- Parcel runs: when a next-assignment transition is loading, the parcel's activation waits for its load step.
-- Handlers use the parent's state so equipment and wages belong to the same shift.
local M = {}

function M.activate(shiftInputs, job)
  local transition = shiftInputs.runtime.nextAssignmentTransition
  if not transition then return false end
  transition.deferredWork = job
  return true
end

return M
