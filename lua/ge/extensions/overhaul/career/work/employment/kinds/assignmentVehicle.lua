-- Vehicle deliveries: a distributor haul (company truck and trailer) or a single vehicle handoff.
-- Handlers use the parent's state so equipment and wages belong to the same shift.
local M = {}

local function beginDistributorHaul(job, shiftInputs)
  local shared, state, caps, fac = shiftInputs.shared, shiftInputs.state, shiftInputs.caps, shiftInputs.fac
  local truck, trailer
  if caps then
    truck, trailer = caps.getIssuedLoanersForFacility(fac, "trailer", {})
  end
  if not truck or not trailer then
    local detail = shiftInputs.dispatch.diagnoseLoanerFailure(fac, { kind = "trailer" }, {})
    shiftInputs.assignment.assignmentMessage("No company truck and trailer are available for this haul.", 6, "warning")
    shared.shiftLog("beginAssignment blocked", string.format("jobKind=vehicle distributorHaul; %s", detail))
    return false, detail
  end
  job.couplerClass = caps.getOfferCouplerClass(trailer)
  state.shift = shiftInputs.makeShiftState(shiftInputs.facId, job, shiftInputs.captureIssuedInventoryIds())
  local isCurrent = shiftInputs.projections.makeAssignmentGuard()
  shared.shiftLog("beginAssignment", string.format("jobKind=vehicle distributorHaul offers=%s truck=%s trailer=%s",
    dumps(job.offerIds or { job.offerId }), shiftInputs.dispatch.describeLoanerOffer(truck), shiftInputs.dispatch.describeLoanerOffer(trailer)))
  local function afterHaulerSpawn()
    if not isCurrent() then
      shared.shiftLog("beginAssignment vehicle haul", "shift cleared before equipment handoff finished")
      return
    end
    state.shift.issuedInventoryIds = shiftInputs.captureIssuedInventoryIds()
    if not shiftInputs.equipment.companyInventoryHasTowTractor(state.shift.couplerClass) or not shiftInputs.equipment.companyInventoryHasTrailer() then
      shared.shiftLog("afterSpawn blocked", "distributor haul missing truck or trailer after company spawn")
      shiftInputs.routing.handleMissingCompanySpawn("Company truck and trailer did not spawn at the yard.", {needAssignedOffers = true})
      return
    end
    if shared.general() then
      shared.general().startDeliveryMode()
    end
    shiftInputs.activateAssignedWork(job)
    shiftInputs.refreshTaskGuidance(true)
    shiftInputs.firePhoneNotification("employment.shiftStarted", "Shift started", job.label or "Haul the assigned vehicles.", "success")
    shiftInputs.notifyUi()
    shiftInputs.routing.beginCompanyVehiclePickupRoute()
  end
  if shiftInputs.equipment.canReuseIssuedEquipmentForJob("trailer", job.couplerClass) and shiftInputs.equipment.companyInventoryHasTrailer() then
    afterHaulerSpawn()
    return true
  end
  shiftInputs.markIssued(truck)
  shiftInputs.markIssued(trailer)
  shiftInputs.equipment.spawnCompanyOffers(afterHaulerSpawn)
  return true
end

local function beginHandoff(job, shiftInputs)
  local shared, state = shiftInputs.shared, shiftInputs.state
  state.shift = shiftInputs.makeShiftState(shiftInputs.facId, job, {})
  local isCurrent = shiftInputs.projections.makeAssignmentGuard()
  shared.shiftLog("beginAssignment", string.format("jobKind=vehicle offer=%s", tostring(job.offerId)))
  local function afterEquipmentCleared(returned)
    if not isCurrent() then
      shared.shiftLog("beginAssignment vehicle", "shift cleared before equipment handoff finished")
      return
    end
    if returned == false then shared.emptyShift(); shiftInputs.notifyUi(); return end
    if shared.general() then
      shared.general().startDeliveryMode()
    end
    shiftInputs.activateAssignedWork(job)
    shiftInputs.refreshTaskGuidance(true)
    shiftInputs.firePhoneNotification("employment.shiftStarted", "Shift started", job.label or "Deliver the assigned vehicle.", "success")
    shiftInputs.notifyUi()
    shared.shiftLog("beginAssignment", string.format("vehicle offer=%s activated after equipment clear", tostring(job.offerId)))
  end
  shiftInputs.equipment.handoffCompanyEquipmentThen(afterEquipmentCleared)
  return true
end

function M.beginAssignment(job, shiftInputs)
  if job.distributorHaul then return beginDistributorHaul(job, shiftInputs) end
  return beginHandoff(job, shiftInputs)
end

return M
