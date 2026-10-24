-- Materials contracts: strict-then-soft loaner match for the contract's material, not a generic loaner query.
-- Handlers use the parent's state so equipment and wages belong to the same shift.
local M = {}

function M.issueLoaners(shiftInputs, job, targetLoad)
  local shared = shiftInputs.shared
  local truck, trailer, loanerOpts = shiftInputs.eligibility.getIssuedEmploymentMaterials(shiftInputs.fac, job.cargoType, targetLoad)
  if truck and not loanerOpts.targetLoad and targetLoad then
    shared.shiftLog("beginAssignment", string.format("materials soft loaner match without targetLoad=%s", tostring(targetLoad)))
  end
  return truck, trailer, loanerOpts
end

return M
