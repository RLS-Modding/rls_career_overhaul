-- Roleplay shifts (police, bus, paramedic): a company service vehicle, no cargo.
-- Handlers use the parent's state so equipment and wages belong to the same shift.
local M = {}

function M.shiftState(shiftInputs, job, issuedInventoryIds)
  local shiftOrgId = shiftInputs.fac and shiftInputs.fac.associatedOrganization or shiftInputs.state.employerOrgId
  return {
    phase = "active",
    jobKind = job.kind,
    spawnFallbackAttempted = job.spawnFallbackAttempted,
    shiftOrgId = shiftOrgId,
    issuedInventoryIds = issuedInventoryIds or {},
    originFacId = shiftInputs.facId,
    loopComplete = false,
    wrecked = false,
    outboundLabel = job.label,
    outboundSubtext = job.subtext,
  }
end

function M.beginAssignment(job, shiftInputs)
  local shared, state, caps, fac = shiftInputs.shared, shiftInputs.state, shiftInputs.caps, shiftInputs.fac
  state.shift = shiftInputs.makeShiftState(shiftInputs.facId, job, {})
  state.shift.issuedInventoryIds = shiftInputs.captureIssuedInventoryIds()
  state.shift.roleplayVehicleSelection = job.vehicleSelection
  if job.personalVehicleId then
    state.shift.personalVehicleId = job.personalVehicleId
    state.shift.issuedInventoryIds = {}
    shiftInputs.refreshTaskGuidance(true)
    shiftInputs.notifyUi()
    shiftInputs.assignment.markNextAssignmentReady(state.shift)
    return true
  end
  local isCurrent = shiftInputs.projections.makeAssignmentGuard()
  shared.shiftLog("beginAssignment", string.format("jobKind=%s", tostring(job.kind)))
  local truck = caps and caps.getIssuedRoleplayVehicleForFacility and caps.getIssuedRoleplayVehicleForFacility(fac, {selection = job.vehicleSelection}) or nil
  if not truck and not (state.shift.issuedInventoryIds and state.shift.issuedInventoryIds[1]) then
    state.shift = nil
    shiftInputs.assignment.assignmentMessage("No company vehicle is available for this shift.", 6, "warning")
    return false, "no roleplay vehicle"
  end
  local function afterSpawn()
    if not isCurrent() then return end
    state.shift.issuedInventoryIds = shiftInputs.captureIssuedInventoryIds()
    if not state.shift.issuedInventoryIds[1] then
      shiftInputs.routing.handleMissingCompanySpawn("Company vehicle did not spawn at the yard.")
      return
    end
    shiftInputs.refreshTaskGuidance(true)
    shiftInputs.firePhoneNotification("employment.shiftStarted", "Shift started", job.label or "On company time", "success")
    shiftInputs.markShiftStartPresentationReady()
    shiftInputs.notifyUi()
    shiftInputs.routing.beginCompanyVehiclePickupRoute()
    shiftInputs.assignment.markNextAssignmentReady(state.shift)
  end
  if state.shift.issuedInventoryIds and state.shift.issuedInventoryIds[1] then
    afterSpawn()
    return true
  end
  shiftInputs.markIssued(truck)
  shiftInputs.equipment.spawnCompanyOffers(afterSpawn)
  return true
end

return M
