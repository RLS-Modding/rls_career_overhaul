-- Paramedic employment admission, assignment and shift actions.
-- Calls stay with the ambulance owner so employment does not duplicate patient state.
local M = {}
function M.allowsPersonalVehicle(vehicleId)
  return overhaul_jobs_ambulance.canUsePersonalVehicle(vehicleId)
end
function M.finalAssignment(shift)
  if shift.endAfterAssignment then return overhaul_jobs_ambulance.hasPatientOnboard() end
  return overhaul_jobs_ambulance.isAmbulanceJobActive() or false
end
function M.requestEndShift(_, force)
  if force then return false end
  overhaul_jobs_ambulance.requestEndDay()
  return true
end
M.finishShift = M.requestEndShift
function M.guidance()
  return overhaul_jobs_ambulance.getEmploymentTaskGuidance()
end
function M.presentation()
  return {useParamedicGuidance = true, paramedicGuidance = M.guidance()}
end
function M.cancelAssignment(reason)
  overhaul_jobs_ambulance.cancelActiveCall(reason)
end
return M
