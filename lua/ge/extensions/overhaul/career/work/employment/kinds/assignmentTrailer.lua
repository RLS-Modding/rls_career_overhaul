-- Trailer deliveries: a tow vehicle coupled to a trailer, activated on a job-system tick.
-- Handlers use the parent's state so equipment and wages belong to the same shift.
local M = {}

function M.loanerOptions(shiftInputs, job, loanerOpts)
  local shared, caps = shiftInputs.shared, shiftInputs.caps
  loanerOpts.couplerClass = job.couplerClass
  if not loanerOpts.couplerClass and job.offerId then
    local mgr = shared.vehicleOffers()
    local offer = mgr and mgr.getOfferById and mgr.getOfferById(job.offerId)
    if offer and caps then
      loanerOpts.couplerClass = caps.getOfferCouplerClass(offer)
    end
  end
end

function M.rejectSpawn(shiftInputs, _job, shift)
  local shared = shiftInputs.shared
  if shiftInputs.equipment.companyInventoryHasTowTractor(shift.couplerClass) then return end
  shared.shiftLog("afterSpawn blocked", "trailer job missing tow vehicle after company spawn")
  shiftInputs.routing.handleMissingCompanySpawn("Company tow vehicle did not spawn at the yard.", {needAssignedOffers = true})
  return true
end

function M.activate(shiftInputs, job, isCurrent)
  core_jobsystem.create(function(spawnJob)
    spawnJob.sleep(0)
    if isCurrent() then shiftInputs.activateAssignedWork(job) end
  end)
  return true
end

return M
