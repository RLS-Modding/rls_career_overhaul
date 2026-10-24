-- Vehicle repo bundles: a company rollback truck plus the car jockey run, activated by the bundle owner.
-- Handlers use the parent's state so equipment and wages belong to the same shift.
local M = {}

function M.shiftState(shiftInputs, job, issuedInventoryIds)
  return {
    phase = "active",
    jobKind = job.kind,
    spawnFallbackAttempted = job.spawnFallbackAttempted,
    issuedInventoryIds = issuedInventoryIds or {},
    assignedOfferId = job.offerId,
    destFacId = job.destFacId,
    destPsPath = job.destPsPath,
    originFacId = shiftInputs.facId,
    originLocation = job.originLocation,
    destLocation = job.destLocation,
    requireTSeriesRollback = job.requireTSeriesRollback and true or nil,
    loopComplete = false,
    wrecked = false,
    outboundLabel = job.label,
    outboundSubtext = job.subtext,
    surgeBonusEligible = shiftInputs.settlement.isJobKindSurged(job.kind, job.cargoType) and true or nil,
    assignments = {
      vehicle = {
        complete = false,
        offerId = job.offerId,
        label = job.vehicleLabel,
        subtext = job.vehicleSubtext,
      },
      repo = {
        complete = false,
        repoPendingStart = false,
        label = job.repoLabel,
        subtext = job.repoSubtext,
      },
    },
  }
end

function M.beginAssignment(job, shiftInputs)
  local shared, state, fac = shiftInputs.shared, shiftInputs.state, shiftInputs.fac
  state.shift = shiftInputs.makeShiftState(shiftInputs.facId, job, {})
  local isCurrent = shiftInputs.projections.makeAssignmentGuard()
  shared.shiftLog("beginAssignment", string.format("jobKind=vehicle_repo_bundle offer=%s", tostring(job.offerId)))

  local function afterSpawn()
    if not isCurrent() then return end
    state.shift.issuedInventoryIds = shiftInputs.captureIssuedInventoryIds()
    if shiftInputs.equipment.bundleNeedsRepoTruckSpawn(state.shift) then
      shiftInputs.routing.handleMissingCompanySpawn("Company rollback did not spawn at the yard.", {needAssignedOffers = true})
      return
    end
    shiftInputs.routing.activateBundleShiftWork(job)
    shiftInputs.firePhoneNotification("employment.shiftStarted", "Shift started", job.label or "Car hauling.", "success")
    shiftInputs.routing.beginCompanyVehiclePickupRoute()
  end

  local function issueOrReuse()
    if not isCurrent() then return end
    if not shiftInputs.equipment.bundleNeedsRepoTruckSpawn(state.shift) then
      afterSpawn()
      return
    end
    local ok, detail = shiftInputs.equipment.issueBundleRepoTruck(fac, afterSpawn)
    if not ok then
      shared.shiftLog("beginAssignment blocked", string.format("jobKind=vehicle_repo_bundle; %s", detail or "no truck"))
      shiftInputs.routing.handleAssignmentStartFailure("No company truck is available for this assignment.")
    end
  end

  if shiftInputs.equipment.bundleNeedsRepoTruckSpawn(state.shift) and shiftInputs.captureIssuedInventoryIds()[1] then
    shiftInputs.equipment.handoffCompanyEquipmentThen(issueOrReuse)
    return true
  end
  if not shiftInputs.equipment.bundleNeedsRepoTruckSpawn(state.shift) then
    afterSpawn()
    return true
  end
  local ok, detail = shiftInputs.equipment.issueBundleRepoTruck(fac, afterSpawn)
  if not ok then
    state.shift = nil
    shiftInputs.assignment.assignmentMessage("No company truck is available for this assignment.", 6, "warning")
    shared.shiftLog("beginAssignment blocked", string.format("jobKind=vehicle_repo_bundle; %s", detail or "no truck"))
    return false, detail
  end
  return true
end

return M
