-- Holds, resumes and restores employment assignments after a load or clock-in; no career state is kept here.
-- Map: hold/resume, restage per job kind, freight snapshots, load reconcile, interrupted-shift abort.
-- gameplay_walk is per-level and may be absent during career load or level teardown.
local M = {}

-- Config ------------------------------------------------------------------------------------------

local OFFER_HOLD_SECONDS = 3600

-- Parcel selectors read cargo ids; every other selector reads offer ids.
local CARGO_ID_FREIGHT = { parcel = true }

-- Shared helpers ----------------------------------------------------------------------------------

-- A held shift replaced or cleared while a callback was pending must not be touched.
local function isStaleHeldShift(recovery, shift)
  return recovery.getState().shift ~= shift or shift.paused
end

local function idSet(ids)
  local set = {}
  for _, id in ipairs(ids or {}) do set[id] = true end
  return set
end

local function findOffer(vehicleOfferManager, offerId)
  return vehicleOfferManager and vehicleOfferManager.getOfferById and vehicleOfferManager.getOfferById(offerId)
end

local function holdOfferForSpawn(recovery, offer)
  recovery.parts.endDay.resetOfferSpawnFlags(offer)
  recovery.parts.endDay.extendOfferExpiry(offer, OFFER_HOLD_SECONDS)
end

local function facilityById(recovery, facId)
  local generator = recovery.services.generator()
  return generator and generator.getFacilityById and generator.getFacilityById(facId)
end

local function startDeliveryModeIfAvailable(recovery)
  local general = recovery.services.general()
  if general and general.startDeliveryMode then general.startDeliveryMode() end
end

-- Hold and resume --------------------------------------------------------------------------------

function M.pauseShift(recovery)
  local shift = recovery.getState().shift
  if not shift or not recovery.lifecycle.isOnShift() then return false end
  recovery.parts.equipment.cancelSpawnBlockedWatch()
  shift.issuedInventoryIds = recovery.parts.equipment.collectCompanyInventoryIds()
  shift.paused = true
  shift.awaitingPark = nil
  shift.parkedNotified = nil
  shift.pendingClockOut = nil
  recovery.parts.persistence.touchLastWorkAt()
  -- Do not exitDeliveryMode here: it abandons vehicle tasks and deletes cargo, which destroys the held backhaul/outbound load.
  freeroam_bigMapMode.setNavFocus(nil)
  core_groundMarkers.setPath(nil)
  recovery.parts.projections.refreshTaskGuidance(true)
  recovery.parts.projections.firePhoneNotification("employment.shiftEnded", "Day ended", "Assignment held. Company vehicle stays in the world. Clock in to continue — pay stays held until the job is finished.", "info")
  ui_message("Day ended. Assignment held; company vehicle stays where it is until you finish the job.", 7, "info")
  recovery.parts.projections.notifyUi()
  recovery.parts.projections.closeShiftUi()
  recovery.parts.projections.closeDropOffUi()
  return true
end

-- Restage ----------------------------------------------------------------------------------------

-- Points the shift at a replacement offer; callers decide what to spawn and say.
local function adoptReplacementOffer(shift, replacement)
  local destination = replacement.destination or (replacement.locations and replacement.locations[2])
  shift.assignedOfferId = replacement.id
  shift.destFacId = destination and destination.facId
  shift.destPsPath = destination and destination.psPath
  shift.destLocation = destination
end

local function spawnReplacementOffer(recovery, vehicleOfferManager, replacement, onResult)
  holdOfferForSpawn(recovery, replacement)
  vehicleOfferManager.spawnAssignedOffer(replacement.id, false, onResult)
end

-- Backhaul return: re-spawn the return vehicle when its offer still exists, else start the repo leg.
local function restageBundleBackhaulLeg(recovery, shift, vehicleOfferManager)
  if shift.returnIsBackhaul and shift.assignedOfferId then
    local offer = findOffer(vehicleOfferManager, shift.assignedOfferId)
    if offer then
      holdOfferForSpawn(recovery, offer)
      recovery.parts.routing.trySpawnAssignedReturnVehicle()
      return
    end
  end
  recovery.parts.routing.beginBundleRepoLeg()
end

local function restageCompletedBundleVehicle(recovery, shift, vehicleOfferManager)
  if recovery.parts.dropOff.isBundleHaulBackhaulPending(shift) then
    recovery.parts.settlement.cancelEmploymentRepoJob()
    restageBundleBackhaulLeg(recovery, shift, vehicleOfferManager)
  end
  recovery.parts.routing.routeCurrentAssignment()
end

local function restageMaterialContract(recovery, shift)
  if shift.assignedContractId then
    local materialsManager = recovery.services.materials()
    if materialsManager and materialsManager.acceptAssignedOffer then
      materialsManager.acceptAssignedOffer(shift.assignedContractId)
    end
  end
  recovery.parts.routing.routeCurrentAssignment()
end

local function restageRepossession(recovery, shift)
  shift.repoPendingStart = true
  recovery.parts.backhaul.tryStartEmploymentRepo()
end

local function restageParcels(recovery, shift)
  if shift.accident and (shift.accident.needReload or shift.accident.needCouple) then
    recovery.parts.routing.routeCurrentAssignment()
    return
  end
  if recovery.parts.endDay.assignedParcelFreightAlive(shift) then
    if shift.needsRemotePickup or (shift.phase == "return" and shift.returnNeedsPickup) then
      recovery.parts.parcelLoading.stageAssignedReturnPickup()
    elseif shift.phase ~= "return" or not shift.returnNeedsPickup then
      recovery.parts.parcelLoading.bindAssignedCargoToIssuedTruck()
    end
    recovery.parts.routing.routeCurrentAssignment()
    return
  end
  if shift.phase == "return" then
    ui_message("Held return parcels are gone — finding another return load.", 6, "info")
    recovery.parts.backhaul.assignReturnLoad(shift.returnPickupFacId or shift.originFacId or recovery.getState().homeFacId)
    return
  end
  ui_message("Held parcel load is gone. End day or start a new assignment from the shift screen.", 7, "warning")
  shift.phase = "loopComplete"
  shift.returnLabel = "Assignment interrupted"
  shift.returnSubtext = "Take another job or end your day"
  recovery.parts.routing.routeToYard()
end

local function restageReturnTrailer(recovery, shift, vehicleOfferManager)
  if recovery.parts.parcelLoading.assignedReturnCargoInVehicle(shift) then
    recovery.parts.dropOff.trySetShiftRoute()
    return
  end
  local offer = shift.assignedOfferId and findOffer(vehicleOfferManager, shift.assignedOfferId)
  if offer then
    holdOfferForSpawn(recovery, offer)
    shift.returnNeedsPickup = true
    shift._returnTrailerSpawned = nil
    shift._returnTrailerSpawning = nil
    shift.originLocation = offer.spawnLocation or offer.origin or shift.originLocation
    shift.returnPickupFacId = (offer.origin and offer.origin.facId)
      or (offer.locations and offer.locations[1] and offer.locations[1].facId)
      or shift.returnPickupFacId
    shift.returnLabel = string.format("Pick up return trailer at %s",
      recovery.parts.parcelLoading.describeFacilityName(shift.returnPickupFacId))
    recovery.parts.routing.routeToReturnPickup()
    recovery.parts.routing.trySpawnAssignedReturnTrailer()
    return
  end
  ui_message("Held return trailer is gone — finding another return load.", 6, "info")
  recovery.parts.backhaul.assignReturnLoad(shift.returnPickupFacId or shift.originFacId or recovery.getState().homeFacId)
end

-- Spawn callback for a re-staged trailer: on failure, try a replacement load before giving up.
local function heldTrailerSpawnCallback(recovery, shift, vehicleOfferManager)
  return function(success, reason)
    if isStaleHeldShift(recovery, shift) then return end
    if success == false then
      if reason == "occupied" then
        recovery.parts.routing.handleVehicleSpawnResult(false, reason)
        return
      end
      ui_message("Could not re-stage the held trailer — finding another load.", 7, "warning")
      local replacement = recovery.parts.dispatch.pickTrailerOffer(shift.originFacId or recovery.getState().homeFacId)
      if replacement then
        adoptReplacementOffer(shift, replacement)
        spawnReplacementOffer(recovery, vehicleOfferManager, replacement, recovery.parts.routing.handleVehicleSpawnResult)
      else
        recovery.parts.routing.handleVehicleSpawnResult(false)
      end
      return
    end
    recovery.parts.routing.handleVehicleSpawnResult(true)
  end
end

local function restageOutboundTrailer(recovery, shift, vehicleOfferManager)
  if recovery.parts.dropOff.vehicleOfferTaskActive(shift.assignedOfferId) then
    recovery.parts.routing.routeCurrentAssignment()
    return
  end
  local offer = shift.assignedOfferId and findOffer(vehicleOfferManager, shift.assignedOfferId)
  if offer then
    holdOfferForSpawn(recovery, offer)
    vehicleOfferManager.spawnAssignedOffer(offer.id, false, heldTrailerSpawnCallback(recovery, shift, vehicleOfferManager))
    return
  end
  local replacement = recovery.parts.dispatch.pickTrailerOffer(shift.originFacId or recovery.getState().homeFacId)
  if replacement then
    ui_message("Held trailer is gone — staging a replacement.", 6, "info")
    adoptReplacementOffer(shift, replacement)
    shift.outboundLabel = "Deliver the assigned trailer"
    spawnReplacementOffer(recovery, vehicleOfferManager, replacement, recovery.parts.routing.handleVehicleSpawnResult)
    return
  end
  ui_message("Held trailer assignment is gone. End day or start a new assignment.", 7, "warning")
  shift.phase = "loopComplete"
  recovery.parts.routing.routeToYard()
end

local function restageTrailerDelivery(recovery, shift, vehicleOfferManager)
  if shift.phase == "return" then
    restageReturnTrailer(recovery, shift, vehicleOfferManager)
  else
    restageOutboundTrailer(recovery, shift, vehicleOfferManager)
  end
end

-- True when any undelivered vehicle offer of a distributor haul can still be re-spawned.
local function distributorHasRecoverableOffers(recovery, shift, vehicleOfferManager)
  local deliveredOfferIdSet = idSet(shift.deliveredOfferIds)
  local hasRecoverable = false
  for id in pairs(recovery.parts.dropOff.shiftVehicleOfferIdSet(shift)) do
    if not deliveredOfferIdSet[id] then
      if recovery.parts.dropOff.vehicleOfferTaskActive(id) then
        hasRecoverable = true
      end
      local offer = id and findOffer(vehicleOfferManager, id)
      if offer then
        hasRecoverable = true
        holdOfferForSpawn(recovery, offer)
      end
    end
  end
  return hasRecoverable
end

local function restageDistributorHaul(recovery, shift, vehicleOfferManager)
  if shift.phase == "return" or shift.awaitingLoopChoice then
    recovery.parts.routing.routeToYard()
    return
  end
  if distributorHasRecoverableOffers(recovery, shift, vehicleOfferManager) then
    recovery.parts.equipment.spawnAssignedVehicleOffers(recovery.parts.routing.handleVehicleSpawnResult)
    return
  end
  ui_message("Held vehicle assignment is gone. End day or start a new assignment from the shift screen.", 7, "warning")
  shift.phase = "loopComplete"
  recovery.parts.routing.routeToYard()
end

-- A bundle with its vehicle leg done moves on to its repo leg or completes; any other shift ends at the yard.
local function endGoneVehicleAssignment(recovery, shift)
  ui_message("Held vehicle assignment is gone. End day or start a new assignment from the shift screen.", 7, "warning")
  if recovery.parts.dropOff.isBundleShift(shift) and shift.assignments and shift.assignments.vehicle then
    shift.assignments.vehicle.complete = true
    if shift.assignments.repo and not shift.assignments.repo.complete then
      recovery.parts.routing.beginBundleRepoLeg()
    else
      recovery.parts.dropOff.maybeCompleteBundleShift({ atYard = true })
    end
  else
    shift.phase = "loopComplete"
    recovery.parts.routing.routeToYard()
  end
end

local function restageVehicleOffer(recovery, shift, vehicleOfferManager)
  local offerId = recovery.parts.dropOff.getShiftVehicleOfferId(shift) or shift.assignedOfferId
  if offerId and recovery.parts.dropOff.vehicleOfferTaskActive(offerId) then
    recovery.parts.routing.routeCurrentAssignment()
    return
  end
  local offer = offerId and findOffer(vehicleOfferManager, offerId)
  if offer then
    holdOfferForSpawn(recovery, offer)
    vehicleOfferManager.spawnAssignedOffer(offer.id, false, recovery.parts.routing.handleVehicleSpawnResult)
    return
  end
  endGoneVehicleAssignment(recovery, shift)
end

local function restageVehicleDelivery(recovery, shift, vehicleOfferManager)
  if recovery.parts.dropOff.isDistributorHaulShift(shift) then
    restageDistributorHaul(recovery, shift, vehicleOfferManager)
  else
    restageVehicleOffer(recovery, shift, vehicleOfferManager)
  end
end

-- First matching kind wins; each restage helper ends the shift in a spawned, routed, or loopComplete state.
local function restageHeldShift(recovery, shift, vehicleOfferManager)
  if recovery.parts.dropOff.isBundleShift(shift) and shift.assignments and shift.assignments.vehicle
      and shift.assignments.vehicle.complete then
    restageCompletedBundleVehicle(recovery, shift, vehicleOfferManager)
    return
  end
  local policy = recovery.shared.kindPolicy(shift.jobKind)
  if policy.materialContract then
    restageMaterialContract(recovery, shift)
  elseif policy.repossession then
    restageRepossession(recovery, shift)
  elseif policy.parcels then
    restageParcels(recovery, shift)
  elseif policy.trailerDelivery then
    restageTrailerDelivery(recovery, shift, vehicleOfferManager)
  elseif policy.vehicleDelivery or recovery.parts.dropOff.isBundleShift(shift) then
    restageVehicleDelivery(recovery, shift, vehicleOfferManager)
  else
    recovery.parts.routing.routeCurrentAssignment()
  end
end

function M.restageHeldAssignment(recovery)
  local shift = recovery.getState().shift
  if not shift then return false end
  restageHeldShift(recovery, shift, recovery.services.vehicleOffers())
  recovery.parts.projections.refreshTaskGuidance(true)
  return true
end

-- Resume ------------------------------------------------------------------------------------------

function M.hasMissingSavedVehicles(recovery, shift)
  local inventory, vehicleOfferManager = recovery.services.inventory(), recovery.services.vehicleOffers()
  if not inventory then return false end
  local ids = {}
  for _, id in ipairs(shift.issuedInventoryIds or {}) do ids[#ids + 1] = id end
  for _, id in ipairs(shift.assignedOfferIds or {shift.assignedOfferId}) do
    local offer = vehicleOfferManager and vehicleOfferManager.getOfferById(id)
    if offer and offer.vehicle and offer.vehicle.inventoryId then ids[#ids + 1] = offer.vehicle.inventoryId end
  end
  for _, id in ipairs(ids) do
    if inventory.getVehicle(id) then
      local vehId = inventory.getVehicleIdFromInventoryId(id)
      if not vehId or not getObjectByID(vehId) then return true end
    end
  end
  return false
end

-- Rig check: a truck (and trailer, for trailer and distributor jobs) must be issued before resuming.
local function resumeNeedsCompanyRig(recovery, shift)
  return not recovery.parts.assignment.issuedVehiclesStillPresent()
    or (recovery.shared.kindPolicy(shift.jobKind).trailerDelivery and not recovery.parts.equipment.companyInventoryHasTowTractor(shift.couplerClass))
    or (recovery.parts.dropOff.isDistributorHaulShift(shift) and (not recovery.parts.equipment.companyInventoryHasTowTractor(shift.couplerClass) or not recovery.parts.equipment.companyInventoryHasTrailer()))
end

local function loanerRequest(shift)
  return { cargoType = shift.cargoType, targetLoad = shift.targetLoad, couplerClass = shift.couplerClass }
end

local function issueResumeRig(recovery, shift, facility)
  local loanerCapabilities = recovery.services.loanerCapabilities()
  if recovery.shared.kindPolicy(shift.jobKind).roleplay then
    return facility and loanerCapabilities and loanerCapabilities.getIssuedRoleplayVehicleForFacility(facility, {}) or nil
  end
  local loanerKind = recovery.parts.equipment.shiftLoanerKind(shift)
  if not (facility and loanerCapabilities) then return nil end
  if recovery.parts.dropOff.isDistributorHaulShift(shift) then
    return loanerCapabilities.getIssuedLoanersForFacility(facility, loanerKind, loanerRequest(shift))
  end
  if recovery.shared.kindPolicy(loanerKind).materialContract then
    return recovery.parts.eligibility.getIssuedEmploymentMaterials(facility, shift.cargoType, shift.targetLoad)
  end
  local truck = loanerCapabilities.getIssuedLoanersForFacility(facility, loanerKind, loanerRequest(shift))
  return truck
end

-- Runs once the rig has spawned: re-attach the offers to the world, then restage the held assignment.
local function restageResumedShift(recovery, shift)
  if isStaleHeldShift(recovery, shift) then return end
  M.restageHeldAssignment(recovery)
  recovery.parts.projections.notifyUi()
  recovery.parts.projections.closeShiftUi()
end

local function completeRigResume(recovery, shift)
  if isStaleHeldShift(recovery, shift) then return end
  shift.issuedInventoryIds = recovery.parts.equipment.captureIssuedInventoryIds()
  if recovery.parts.equipment.spawnBlockedNeedsCompanyLoaner(shift) then
    recovery.parts.routing.handleMissingCompanySpawn("Company vehicle did not spawn at the yard.", {
      needAssignedOffers = recovery.parts.equipment.spawnBlockedNeedsAssignedOffers(shift),
    })
    return
  end
  local general = recovery.services.general()
  if general and general.startDeliveryMode and not recovery.shared.isOpenEndedJobKind(shift.jobKind) then
    general.startDeliveryMode()
  end
  core_jobsystem.create(function(job)
    job.sleep(0)
    restageResumedShift(recovery, shift)
  end)
end

local function finishRigResume(recovery, shift, truck, trailer)
  recovery.parts.equipment.markIssued(truck)
  if trailer and (not recovery.shared.kindPolicy(shift.jobKind).trailerDelivery or recovery.parts.dropOff.isDistributorHaulShift(shift)) then
    recovery.parts.equipment.markIssued(trailer)
  end
  local loaners = recovery.services.loaners()
  if loaners and loaners.spawnAllOffers then
    loaners.spawnAllOffers(function() completeRigResume(recovery, shift) end)
  else
    completeRigResume(recovery, shift)
  end
  ui_message("Clocked in. Continue the held assignment.", 6, "info")
end

-- A resume at a facility is allowed at the employer, its organization, or the shift's own origin.
local function facilityAllowsResume(recovery, shift, facId)
  local facility = facilityById(recovery, facId)
  local shiftOrg = shift.shiftOrgId
  return recovery.parts.dropOff.facilityMatchesEmployer(facId)
    or (shiftOrg and facility and facility.associatedOrganization == shiftOrg)
    or (shift.originFacId and shift.originFacId == facId)
end

local function resumeWithCompanyRig(recovery, shift, facId)
  local facility = facilityById(recovery, facId or shift.originFacId or recovery.getState().homeFacId)
  local truck, trailer = issueResumeRig(recovery, shift, facility)
  if not truck or (recovery.parts.dropOff.isDistributorHaulShift(shift) and not trailer) then
    shift.paused = true
    ui_message("No company truck is available to continue this assignment.", 6, "warning")
    return false
  end
  finishRigResume(recovery, shift, truck, trailer)
  return true
end

function M.resumeShift(recovery, facId)
  if recovery.getState().restoringFreight then
    ui_message("Please wait for the saved assignment to finish restoring.", 5, "info")
    return false
  end
  local shift = recovery.getState().shift
  if not shift or not shift.paused then return false end
  if shift.legacyFreightUnavailable then
    ui_message('This older save did not retain the assignment cargo. The assignment and held pay are preserved; explicitly abandon it in Employment if the missing freight cannot be restored.', 10, 'warning')
    return false
  end
  if M.hasMissingSavedVehicles(recovery, shift) then
    ui_message("A saved assignment vehicle could not be restored. Retry its vehicle in Logistics, then continue the assignment in Employment.", 10, "warning")
    return false
  end
  recovery.getState().ignoreCompanyDamageStrikes = nil
  if facId and not facilityAllowsResume(recovery, shift, facId) then
    ui_message("Clock in at the company yard.", 5, "warning")
    return false
  end
  shift.paused = false
  recovery.parts.persistence.touchLastWorkAt()
  if resumeNeedsCompanyRig(recovery, shift) then
    return resumeWithCompanyRig(recovery, shift, facId)
  end
  startDeliveryModeIfAvailable(recovery)
  M.restageHeldAssignment(recovery)
  recovery.parts.projections.firePhoneNotification("employment.shiftStarted", "Clocked in", "Continue the held assignment.", "success")
  ui_message("Clocked in. Continue the held assignment.", 6, "info")
  recovery.parts.projections.notifyUi()
  recovery.parts.projections.closeShiftUi()
  return true
end

-- Freight -----------------------------------------------------------------------------------------

-- Context-free on purpose: nil-context callers stay allocation-free.
function M.isAssignedFreight(shift, item, kind)
  if not shift or not item then return false end
  local ids = (CARGO_ID_FREIGHT[kind] and shift.assignedCargoIds) or shift.assignedOfferIds or {shift.assignedOfferId}
  for _, id in ipairs(ids or {}) do if id == item.id then return true end end
  return false
end

local function capturedParcelSnapshots(recovery, shift, parcels)
  local snapshots = {}
  for _, id in ipairs(shift.assignedCargoIds or {}) do
    local cargo = parcels and parcels.getCargoById(id)
    if cargo and cargo.location and (cargo.location.type == 'vehicle'
      or (cargo.location.type == 'facilityParkingspot' and cargo.origin and cargo.location.facId == cargo.origin.facId)) then
      local saved = deepcopy(cargo)
      if cargo.location.type == "vehicle" and recovery.services.inventory() then
        saved.savedInventoryId = cargo.logisticsBinding and cargo.logisticsBinding.inventoryId
          or recovery.services.inventory().getInventoryIdFromVehicleId(cargo.location.vehId)
      end
      snapshots[#snapshots + 1] = saved
    end
  end
  return snapshots
end

local function capturedOfferSnapshots(recovery, shift, vehicles, persistence)
  local deliveredOfferIdSet = idSet(shift.deliveredOfferIds)
  local vehicleLeg = shift.assignments and shift.assignments.vehicle
  if vehicleLeg and vehicleLeg.complete and vehicleLeg.offerId then
    deliveredOfferIdSet[vehicleLeg.offerId] = true
  end
  local snapshots = {}
  for _, id in ipairs(shift.assignedOfferIds or {shift.assignedOfferId}) do
    local offer = not deliveredOfferIdSet[id] and vehicles and vehicles.getOfferById(id)
    if offer then
      local saved = deepcopy(offer)
      local tasks = recovery.services.vehicleTasks()
      local task = tasks and tasks.getVehicleTaskForOffer and tasks.getVehicleTaskForOffer(offer)
      if task and persistence.capturePersistentTask then saved.logisticsTask = persistence.capturePersistentTask(task) end
      snapshots[#snapshots + 1] = saved
    end
  end
  return snapshots
end

function M.captureFreight(recovery, shift, api)
  if not shift then return end
  if recovery.shared.kindPolicy(shift.jobKind).roleplay then return end
  local persistence = recovery.services.general() or {}
  if persistence.capturePersistentCargo then persistence.capturePersistentCargo() end
  local parcels = capturedParcelSnapshots(recovery, shift, api and api.parcels)
  local offers = capturedOfferSnapshots(recovery, shift, api and api.vehicles, persistence)
  return { parcels = parcels, offers = offers, phase = shift.phase, sessionVehicles = true }
end

-- Recreates one saved cargo with a fresh id; a vehicle-bound cargo reattaches once its inventory vehicle exists.
local function restoreCargoEntry(recovery, saved, api)
  local cargo = deepcopy(saved)
  cargo.id = api.newId()
  cargo.location = deepcopy(cargo.origin)
  if saved.location and saved.location.type == 'vehicle' then
    cargo.location = deepcopy(saved.location)
    cargo.location.vehId = -1
    cargo.logisticsBinding = cargo.logisticsBinding or {inventoryId = saved.savedInventoryId, containerId = saved.location.containerId}
    cargo.logisticsPending = true
  end
  local inventory = recovery.services.inventory()
  local vehId = saved.savedInventoryId and inventory and inventory.getVehicleIdFromInventoryId(saved.savedInventoryId)
  if vehId and getObjectByID(vehId) then
    cargo.location = deepcopy(saved.location)
    cargo.location.vehId = vehId
    cargo.logisticsPending = nil
  end
  cargo.savedInventoryId = nil
  cargo._transientMove = nil
  cargo.employmentAssigned = true
  recovery.services.general().migrateOfferAccess(cargo)
  cargo.offerExpiresAt = math.max(cargo.offerExpiresAt or 0, api.now() + OFFER_HOLD_SECONDS)
  api.parcels.addCargo(cargo)
  return cargo.id
end

-- Recreates one saved offer with a fresh id; a vehicle offer reattaches to a live delivery vehicle when one exists.
local function restoreOfferEntry(recovery, saved, api)
  local offer = deepcopy(saved)
  offer.id = api.newId()
  offer.spawned = nil
  offer._spawning = nil
  offer.employmentAssigned = true
  recovery.services.general().migrateOfferAccess(offer)
  offer.spawnWhenCommitingCargo = nil
  if offer.vehicle then offer.vehicle.vehId = nil end
  local inventory = recovery.services.inventory()
  local inventoryId = offer.vehicle and offer.vehicle.inventoryId
  local info = inventoryId and inventory and inventory.getVehicle(inventoryId)
  local vehId = info and info.loanType == "delivery" and inventory.getVehicleIdFromInventoryId(inventoryId)
  if inventoryId then
    offer.spawned = true
    offer.vehicle.vehId = -1
  end
  if vehId and getObjectByID(vehId) then
    offer.vehicle.vehId = vehId
    offer.spawned = true
  end
  offer.offerExpiresAt = math.max(offer.offerExpiresAt or 0, api.now() + OFFER_HOLD_SECONDS)
  api.vehicles.addOffer(offer)
  return offer.id
end

-- String stops and string membership follow the restored cargo ids.
local function relinkStringStops(shift, cargoIds, cargoIdMap)
  shift.stringCargoIds = deepcopy(cargoIds)
  for _, stop in ipairs(shift.stops or {}) do
    local ids = {}
    for _, id in ipairs(stop.cargoIds or {}) do
      if cargoIdMap[id] then ids[#ids + 1] = cargoIdMap[id] end
    end
    stop.cargoIds = ids
  end
end

function M.restoreFreight(recovery, shift, api)
  local snapshot = shift and (shift.freight or shift.plannerFreight)
  if not snapshot then return false end
  local cargoIds, offerIds, cargoIdMap, offerIdMap = {}, {}, {}, {}
  for _, saved in ipairs(snapshot.parcels or {}) do
    local newId = restoreCargoEntry(recovery, saved, api)
    cargoIds[#cargoIds + 1] = newId
    cargoIdMap[saved.id] = newId
  end
  for _, saved in ipairs(snapshot.offers or {}) do
    local newId = restoreOfferEntry(recovery, saved, api)
    offerIds[#offerIds + 1] = newId
    offerIdMap[saved.id] = newId
  end
  shift.assignedCargoIds = cargoIds
  if shift.stringMode then relinkStringStops(shift, cargoIds, cargoIdMap) end
  if shift.distributorHaul or shift.assignedOfferIds then
    shift.assignedOfferIds = offerIds
    shift.deliveredOfferIds = {}
  end
  shift.assignedOfferId = offerIds[1]
  for _, assignment in pairs(shift.assignments or {}) do
    if offerIdMap[assignment.offerId] then assignment.offerId = offerIdMap[assignment.offerId] end
  end
  shift.phase = snapshot.phase or shift.phase
  shift.freight = nil
  shift.plannerFreight = nil
  shift.plannerLineId = nil
  shift.plannerMode = nil
  shift.plannerRepoOfferId = nil
  return true
end

-- Load --------------------------------------------------------------------------------------------

-- Reattaches restored offers that were spawned in the world to the vehicle task system.
local function retaskSpawnedOffers(recovery, shift)
  local vehicleOfferManager, tasks = recovery.services.vehicleOffers(), recovery.services.vehicleTasks()
  for _, id in ipairs(shift.assignedOfferIds or {shift.assignedOfferId}) do
    local offer = vehicleOfferManager and vehicleOfferManager.getOfferById(id)
    if offer and offer.spawned and offer.vehicle and tasks then
      tasks.addVehicleTask(offer.vehicle.vehId, offer)
    end
  end
end

local function reconcileLoadedFreight(recovery, shift)
  local snapshot = shift.freight or shift.plannerFreight
  local resumeInWorld = snapshot.sessionVehicles == true and not shift.paused
  M.restoreFreight(recovery, shift, {
    parcels = recovery.services.parcelManager(), vehicles = recovery.services.vehicleOffers(),
    newId = recovery.services.generator().allocateCargoId, now = recovery.services.general().time,
  })
  shift.paused = not resumeInWorld
  shift.sessionVehicles = true
  shift._returnTrailerSpawning = nil
  shift._returnTrailerSpawned = nil
  recovery.getState().ignoreCompanyDamageStrikes = nil
  retaskSpawnedOffers(recovery, shift)
  if M.hasMissingSavedVehicles(recovery, shift) then
    shift.paused = true
    ui_message("A saved assignment vehicle could not be restored. Retry it from Logistics; the assignment is held.", 10, "warning")
  elseif resumeInWorld then
    startDeliveryModeIfAvailable(recovery)
    M.restageHeldAssignment(recovery)
  end
  local general = recovery.services.general()
  if general and general.requestUpdateContainerWeights then general.requestUpdateContainerWeights() end
  recovery.parts.persistence.flushEmploymentCache()
  recovery.parts.projections.notifyUi()
end

function M.reconcileLoadedShift(recovery)
  local shift = recovery.getState().shift
  if not shift then return end
  if not (recovery.lifecycle.isOnShift() or shift.paused) then return end
  if shift.originFacId and shift.originFacId ~= recovery.getState().homeFacId
      and shift.phase == "return" and not shift.returnIsBackhaul and not shift.returnNeedsPickup
      and shift.destFacId == recovery.getState().homeFacId then
    shift.destFacId = shift.originFacId
    shift.destLocation = nil
    shift.destPsPath = nil
  end
  if shift.freight or shift.plannerFreight then
    reconcileLoadedFreight(recovery, shift)
    return
  end
  M.abortInterruptedShiftOnLoad(recovery)
end

-- Interrupted shifts ------------------------------------------------------------------------------

-- Older saves can lose their freight; mark the held shift so the player retries it, never invent a load.
local function markLegacyFreightUnavailable(recovery, held)
  local parcels, offers, materials = recovery.services.parcelManager(), recovery.services.vehicleOffers(), recovery.services.materials()
  for _, id in ipairs(held.assignedCargoIds or {}) do
    if not (parcels and parcels.getCargoById(id)) then held.legacyFreightUnavailable = true end
  end
  for _, id in ipairs(held.assignedOfferIds or {held.assignedOfferId}) do
    if not (offers and offers.getOfferById(id)) then held.legacyFreightUnavailable = true end
  end
  if held.assignedContractId and not (materials and materials.getContractById(held.assignedContractId)) then
    held.legacyFreightUnavailable = true
  end
end

local function abortHeldRoleplayOnLoad(recovery, held)
  held.paused = true
  if held.phase ~= "return" and held.phase ~= "loopComplete" and not held.awaitingLoopChoice then
    markLegacyFreightUnavailable(recovery, held)
  end
  ui_message("Your saved assignment is held. Continue it from Employment; unavailable equipment can be retried from Logistics.", 10, "warning")
  return true
end

-- Ends the company's side of the shift: materials, repo job, vehicle tasks and delivery mode.
local function releaseCompanyWork(recovery)
  local materials = recovery.services.materials()
  if materials and materials.abandonContract then
    materials.abandonContract(nil, { noFine = true, silent = true })
  end
  if materials and materials.clearTaskGuidance then
    materials.clearTaskGuidance()
  end
  recovery.parts.settlement.cancelEmploymentRepoJob()
  local vehicleTasks = recovery.services.vehicleTasks()
  if vehicleTasks and vehicleTasks.abandonAllVehicleTasks then
    vehicleTasks.abandonAllVehicleTasks()
  end
  recovery.parts.endDay.exitDeliveryModeIfActive()
end

local function resetRouteAndCache(recovery)
  if core_groundMarkers then
    core_groundMarkers.setPath(nil)
  end
  if freeroam_bigMapMode then
    freeroam_bigMapMode.resetRoute()
  end
  recovery.parts.persistence.flushEmploymentCache()
end

-- Puts the player back in a garage, or in the company vehicle when the inventory keeps them there.
local function movePlayerAfterShift(recovery)
  local inventory = recovery.services.inventory()
  if inventory and inventory.recoverPlayerAfterCompanyReturn then
    return inventory.recoverPlayerAfterCompanyReturn() or "garage"
  end
  if gameplay_walk then
    gameplay_walk.setWalkingMode(true, nil, nil, true)
  end
  return "garage"
end

local function announceShiftEnd(recovery, total, wages, bonus, removed, playerDestination)
  local wagesMessage = recovery.parts.settlement.formatTodaysWagesMessage(total, wages, bonus)
  local detail = string.format(
    "%s Company equipment returned (%d). You were moved to your %s.",
    wagesMessage,
    removed,
    playerDestination == "vehicle" and "vehicle" or "garage")
  recovery.parts.projections.firePhoneNotification("employment.shiftEnded", "Shift ended", detail, "info")
  ui_message(detail, 8, "info")
  recovery.parts.projections.notifyUi()
  recovery.parts.projections.closeShiftUi()
  recovery.parts.projections.closeDropOffUi()
end

-- Releases company equipment, pays escrow, and returns the player to a garage or vehicle.
local function endInterruptedShift(recovery, shift)
  recovery.shared.shiftLog("abortInterruptedShiftOnLoad", tostring(shift.jobKind or "?"))
  spawn.preventPlayerSpawning = nil
  releaseCompanyWork(recovery)

  local previousDamageSuppression = recovery.getState().ignoreCompanyDamageStrikes
  recovery.getState().ignoreCompanyDamageStrikes = true
  recovery.parts.settlement.reconcileEscrowMoney("abortInterruptedShiftOnLoad")
  local total, wages, bonus = recovery.parts.settlement.payEscrow()
  if total == nil then
    recovery.getState().ignoreCompanyDamageStrikes = previousDamageSuppression
    return false
  end
  local removed = recovery.parts.endDay.returnAllCompanyVehicles()
  recovery.shared.emptyShift()
  resetRouteAndCache(recovery)
  announceShiftEnd(recovery, total, wages, bonus, removed, movePlayerAfterShift(recovery))
  require("overhaul/lib/save/store").request("shiftRecovery:abortInterruptedShiftOnLoad")
  return true
end

function M.abortInterruptedShiftOnLoad(recovery)
  local held = recovery.getState().shift
  if held and not recovery.shared.kindPolicy(held.jobKind).roleplay then
    return abortHeldRoleplayOnLoad(recovery, held)
  end
  local shift = recovery.getState().shift
  if not shift then return false end
  if not (recovery.lifecycle.isOnShift() or shift.paused) then return false end
  return endInterruptedShift(recovery, shift)
end

-- Context -----------------------------------------------------------------------------------------

local function recoveryServices(inputs)
  return setmetatable({
    inventory = function() return overhaul_career_garage_inventory end,
    loaners = function() return overhaul_career_logistics_loanerVehicles end,
    vehicleTasks = function() return overhaul_career_logistics_vehicleTasks end,
  }, {__index = inputs.shared})
end

local function recoveryContext(inputs)
  return {
    getState = function() return inputs.state end,
    parts = inputs.parts,
    shared = inputs.shared,
    lifecycle = inputs.lifecycle,
    services = recoveryServices(inputs),
  }
end

-- Binding -----------------------------------------------------------------------------------------

function M.new(inputs)
  local api = require("overhaul/career/work/employment/operations").new {
    api = inputs.api,
    operations = M,
    context = function() return recoveryContext(inputs) end,
    withContext = {
      pauseShift = true,
      restageHeldAssignment = true,
      hasMissingSavedVehicles = true,
      resumeShift = true,
      captureFreight = true,
      restoreFreight = true,
      reconcileLoadedShift = true,
      abortInterruptedShiftOnLoad = true,
    },
  }
  api.shiftRecoveryContext = function() return recoveryContext(inputs) end
  return api
end

return M
