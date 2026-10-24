-- Finishing, holding, quitting and abandoning company shifts.
-- Reading order: shift finish, yard return, End Day, held shifts, cargo abandonment and construction.
local recordShift = require("overhaul/lib/progression/logbookFeed").register("overhaul.shiftCompleted", {
  title = "Shift completed", label = "Employment", icon = "deliveryTruck"
}, "career/work/employment/endDay.lua")

local part = {}

-- Shared helpers ---------------------------------------------------------------------------------

local function deleteCargo(parcelMgr, cargoList)
  for _, cargo in ipairs(cargoList) do
    if cargo._transientMove and parcelMgr.clearTransientMoveForCargo then
      parcelMgr.clearTransientMoveForCargo(cargo.id)
    end
    parcelMgr.changeCargoLocation(cargo.id, { type = "deleted" })
  end
end

-- Deletes the assignment's cargo and charges the abandonment penalty for it.
local function discardAssignmentCargoWithPenalty(api, shared)
  local general = shared.general()
  local parcelMgr = shared.parcelManager()
  local penalty = general and general.getDeliveryModePenalty
    and general.getDeliveryModePenalty(nil, false, api.employmentAssignmentCargoFilter) or {}
  if parcelMgr and parcelMgr.getAllCargoCustomFilter and parcelMgr.changeCargoLocation then
    deleteCargo(parcelMgr, parcelMgr.getAllCargoCustomFilter(api.employmentAssignmentCargoFilter) or {})
  end
  api.applyEmploymentCargoPenalty(penalty)
end

-- Finishing a shift ------------------------------------------------------------------------------

local function addFinishShiftApi(api, inputs)
  local projections, settlement, shared, state = inputs.projections, inputs.settlement, inputs.shared, inputs.state

  -- Car jockeys drive the delivery car; other accepted deliveries stay active when issuing the next company vehicle.
  function api.exitDeliveryModeIfActive()
    if shared.general() and shared.general().isDeliveryModeActive() then
      shared.general().exitDeliveryMode()
    end
  end

  local function releaseShiftWork(terminateAfterSettlement)
    inputs.equipment.deleteCargoOnCompanyVehicles()
    inputs.equipment.deleteOrphanedVehicleCargo()
    inputs.equipment.returnIssuedVehicles()
    shared.emptyShift()
    if terminateAfterSettlement then settlement.terminateEmploymentForDamage() end
    api.exitDeliveryModeIfActive()
    projections.purgeIndependentTasklist()
    if overhaul_career_logistics_tasklist then
      overhaul_career_logistics_tasklist.sendCargoToTasklist()
    end
  end

  local function clearPassengerRoute()
    if freeroam_bigMapMode then freeroam_bigMapMode.setNavFocus(nil) end
    if freeroam_bigMapMode then freeroam_bigMapMode.resetRoute() end
    if core_groundMarkers then core_groundMarkers.setPath(nil) end
  end

  local function announceShiftEnd(total, wages, bonus, wagesMessageOptions)
    local wagesMsg = settlement.formatTodaysWagesMessage(total, wages, bonus, wagesMessageOptions)
    projections.firePhoneNotification("employment.shiftEnded", "Shift ended", wagesMsg, "success")
    ui_message(wagesMsg, 7, "success")
    projections.notifyUi()
    projections.closeShiftUi()
    projections.closeDropOffUi()
  end

  -- opts.abandonFine: the abandon penalty already charged, named in the unavailable-kind message.
  function api.finishShift(opts)
    if inputs.screen.dropOffEscrowPending then
      ui_message("Still confirming drop-off pay — wait a moment before ending the day.", 6, "warning")
      return false
    end
    if state.shift and (shared.kindPolicy(state.shift.jobKind).repossession or inputs.dropOff.isBundleShift(state.shift)) then
      settlement.cancelEmploymentRepoJob()
    end
    settlement.reconcileEscrowMoney("finishShift")
    local endingPassengerShift = state.shift and shared.kindPolicy(state.shift.jobKind).passengerService
    local openEndedShift = state.shift and shared.isOpenEndedJobKind(state.shift.jobKind)
    -- A shift whose add-on was removed still settles and ends, but the player is told why.
    local kindUnavailable = state.shift and shared.kindUnavailable(state.shift)
    if endingPassengerShift then state.shift.awaitingCompanyVehicleEntry = nil end
    if state.shift then shared.kindHandler(state.shift.jobKind, 'finishShift', state.shift) end
    local previousDamageSuppression = state.ignoreCompanyDamageStrikes
    state.ignoreCompanyDamageStrikes = true
    settlement.assessCompanyDamageBeforePayout()
    local terminateAfterSettlement = state.shift and state.shift.pendingDamageTermination
    inputs.persistence.touchLastWorkAt()
    inputs.persistence.flushEmploymentCache()
    local completedShift = state.shift
    local total, wages, bonus = settlement.payEscrow()
    if total == nil then
      state.ignoreCompanyDamageStrikes = previousDamageSuppression
      return false
    end
    if completedShift then
      local definition = shared.kindDefinition and shared.kindDefinition(completedShift.jobKind)
      recordShift({name = definition and definition.label or completedShift.jobKind or "Work",
        facts = {{label = "Job", value = definition and definition.label or completedShift.jobKind},
          {label = "Wages", value = wages, kind = "money"}, {label = "Bonus", value = bonus, kind = "money"},
          {label = "Status", value = "Shift settled"}}, money = total})
    end
    releaseShiftWork(terminateAfterSettlement)
    if endingPassengerShift then clearPassengerRoute() end
    announceShiftEnd(total, wages, bonus, { openEnded = openEndedShift, kindUnavailable = kindUnavailable,
      abandonFine = opts and opts.abandonFine })
    inputs.persistence.saveEmploymentProgress()
    return true
  end
end

-- Final assignment and yard return ---------------------------------------------------------------

local function addYardReturnApi(api, inputs)
  local config, dropOff, routing, shared = inputs.config, inputs.dropOff, inputs.routing, inputs.shared

  api.discardUncollectedParcelPickup = function(shift)
    local parcelMgr = shared.parcelManager()
    if parcelMgr then
      for _, cargoId in ipairs(shift.assignedCargoIds or {}) do
        if parcelMgr.clearTransientMoveForCargo then
          parcelMgr.clearTransientMoveForCargo(cargoId)
        end
        if parcelMgr.getCargoById(cargoId)
            and parcelMgr.changeCargoLocation then
          parcelMgr.changeCargoLocation(cargoId, { type = "deleted" })
        end
      end
    end
    shift.assignedCargoIds = {}
    shift.needsRemotePickup = nil
    shift.returnNeedsPickup = nil
    shift.returnPickupFacId = nil
    shift.returnIsBackhaul = nil
  end

  local function companyLoanersReturnedWithNoFreight(shift)
    if shift.phase ~= "outbound" and shift.phase ~= "return" then return false end
    local parcelMgr = shared.parcelManager()
    for _, cargoId in ipairs(shift.assignedCargoIds or {}) do
      local cargo = parcelMgr and parcelMgr.getCargoById(cargoId)
      if cargo then return false end
    end
    if shift.assignedOfferId then return false end
    if dropOff.isDistributorHaulShift(shift) and dropOff.distributorHaulRemaining(shift) > 0 then return false end
    if shared.kindPolicy(shift.jobKind).materialContract and dropOff.materialsAssignmentHasWork() then return false end
    return true
  end

  -- Empty yard return / wrecked / loop complete — no freight left to move.
  function api.onlyCompanyYardReturnLeft(shift)
    if not shift then return false end
    if shift.wrecked or shift.phase == "loopComplete" then return true end
    if shift.awaitingLoopChoice then return true end
    if shift.phase == "return" and not dropOff.hasOutstandingReturnWork(shift) then return true end
    -- Player already returned the company loaner(s); nothing left but payout.
    if not inputs.assignment.issuedVehiclesStillPresent() then
      return companyLoanersReturnedWithNoFreight(shift)
    end
    return false
  end

  api.playerAtEmployerYard = function(facId)
    if facId and dropOff.facilityMatchesEmployer(facId) then return true end
    if routing.playerNearHomeYard and routing.playerNearHomeYard() then return true end
    return false
  end

  api.chargeRemoteEndDayRecoveryFee = function()
    local base = config.REMOTE_END_DAY_TOW_BASE * config.REMOTE_END_DAY_TOW_FRACTION
    base = base * (tonumber(overhaul_career_economyAdjuster.getSectionMultiplier("delivery")) or 1)
    local fee = math.max(0, math.floor(base + 0.5))
    if fee <= 0 then return 0 end
    overhaul_career_economy_playerAttributes.addAttributes({ money = -fee }, require("overhaul/lib/finance/metadata").tag({
      tags = { "gameplay", "employment", "tow", "fine" },
      label = "Remote company vehicle recovery",
    }, "service", {locationId = inputs.state.homeFacId}))
    return fee
  end

  api.finalAssignmentInProgress = function()
    local shift = inputs.state.shift
    if not shift then return false end
    if shift.spawnBlocked then return true end
    local active = shared.kindHandler(shift.jobKind, 'finalAssignment', shift)
    if active ~= nil then return active end
    return dropOff.assignmentStillInProgress() and not api.onlyCompanyYardReturnLeft(shift)
  end

  api.yardDropOffPendingForEndDay = function(shift)
    if not shift or shift.wrecked then return false end
    return not api.finalAssignmentInProgress() and routing.companyVehiclesAwayFromYard()
  end
end

-- End Day ----------------------------------------------------------------------------------------

local function addEndDayApi(api, inputs)
  local lifecycle, projections, screen, shared = inputs.lifecycle, inputs.projections, inputs.screen, inputs.shared

  local function holdMaterialShift(shift)
    shift.endAfterAssignment = nil
    local held = inputs.recovery.pauseShift()
    if held then inputs.persistence.saveEmploymentProgress() end
    return held
  end

  local function sendMaterialTruckToYard()
    inputs.routing.routeToYard()
    ui_message("Drop the company truck off at the yard to collect pay and end the day.", 8, "info")
    projections.notifyUi()
    return false
  end

  -- Returns handled, result; handled is false when the kind does not take over ending the shift.
  local function requestRoleplayEndShift(shift)
    local previousEnding = shift.endAfterAssignment
    shift.endAfterAssignment = true
    local requested = shared.kindHandler(shift.jobKind, 'requestEndShift', shift, false)
    if requested == false then
      shift.endAfterAssignment = previousEnding
      return true, false
    end
    if requested ~= nil then
      if not api.finalAssignmentInProgress() then return true, api.finishShift() end
      local kind = shared.kindDefinition(shift.jobKind)
      if kind.endShiftMessage then ui_message(kind.endShiftMessage, 8, 'info') end
      projections.notifyUi()
      return true, true
    end
    shift.endAfterAssignment = previousEnding
    return false
  end

  local function hasUncollectedParcelPickup(shift)
    return shift and shared.kindPolicy(shift.jobKind).parcels
      and ((shift.phase == "outbound" and shift.needsRemotePickup)
        or (shift.phase == "return" and shift.returnNeedsPickup))
  end

  local function deferEndDayToFinalAssignment(shift)
    shift.endAfterAssignment = true
    ui_message("Final assignment. Finish your current work to collect pay and end the day.", 8, "info")
    projections.notifyUi()
    projections.closeShiftUi()
    return true
  end

  local function clearParkingFlags(shift)
    shift.awaitingPark = nil
    shift.parkedNotified = nil
    shift.pendingClockOut = nil
  end

  local function chargeAwayFromYardRecovery(facId)
    if api.playerAtEmployerYard(facId) then return end
    local fee = api.chargeRemoteEndDayRecoveryFee()
    if fee > 0 then
      ui_message(string.format("Away-from-yard recovery: $%d (half tow rate).", fee), 6, "info")
    end
  end

  function api.endDay(facId)
    if not lifecycle.isOnShift() then return false end
    if screen.dropOffEscrowPending then
      ui_message("Still confirming drop-off pay — wait a moment before ending the day.", 6, "warning")
      projections.notifyUi()
      return false
    end
    local shift = inputs.state.shift
    -- Nothing can finish the work of a kind that is no longer mounted: settle and drop it now.
    if shift and shared.kindUnavailable(shift) then
      return api.finishShift()
    end
    if shift and shared.kindPolicy(shift.jobKind).materialContract and api.finalAssignmentInProgress() then
      return holdMaterialShift(shift)
    end
    if shift and shared.kindPolicy(shift.jobKind).materialContract and api.yardDropOffPendingForEndDay(shift) then
      return sendMaterialTruckToYard()
    end
    if shift and shared.kindPolicy(shift.jobKind).roleplay and not shift.spawnBlocked then
      local handled, result = requestRoleplayEndShift(shift)
      if handled then return result end
    end
    if hasUncollectedParcelPickup(shift) and not inputs.parcelLoading.assignedReturnCargoInVehicle(shift) then
      api.discardUncollectedParcelPickup(shift)
      return api.finishShift()
    end
    if shift and shift.endAfterAssignment then return true end
    if api.finalAssignmentInProgress() then return deferEndDayToFinalAssignment(shift) end
    if shift then clearParkingFlags(shift) end
    -- Open-ended work (repo, etc.): always pay out and return the loaner.
    if shift and shared.isOpenEndedJobKind(shift.jobKind) then
      return api.finishShift()
    end
    -- Yard-return-only / wrecked / vehicle already returned: finish from anywhere.
    if api.onlyCompanyYardReturnLeft(shift) then chargeAwayFromYardRecovery(facId) end
    return api.finishShift()
  end

  -- The confirmation belongs to a specific active route. A delayed UI reply must never transfer passengers or settle a different shift that started meanwhile.
  api.endBusShiftNow = function(expectedRouteId)
    local shift = inputs.state.shift
    if not lifecycle.isOnShift() or not shift or not shared.kindPolicy(shift.jobKind).passengerService or shift.spawnBlocked or screen.dropOffEscrowPending then return false end
    if not shared.kindHandler(shift.jobKind, 'requestEndShift', shift, true, expectedRouteId) then return false end
    shift.endAfterAssignment = true
    if api.finalAssignmentInProgress() then return false end
    return api.finishShift()
  end
end

-- Offers and parcel freight ----------------------------------------------------------------------

local function addOfferApi(api, inputs)
  local shared = inputs.shared

  api.resetOfferSpawnFlags = function(offer)
    if not offer then return end
    if offer.vehicle and offer.vehicle.inventoryId then
      offer.spawned = true
      offer._spawning = nil
      return
    end
    if offer.vehicle and offer.vehicle.vehId and getObjectByID(offer.vehicle.vehId) then
      offer.spawned = true
      offer._spawning = nil
      return
    end
    offer.spawned = nil
    offer._spawning = nil
  end

  api.extendOfferExpiry = function(offer, seconds)
    if not offer then return end
    local now = (shared.general() and shared.general().time()) or 0
    offer.offerExpiresAt = math.max(tonumber(offer.offerExpiresAt) or 0, now + (tonumber(seconds) or 3600))
  end

  api.assignedParcelFreightAlive = function(shift)
    if not shift or not shift.assignedCargoIds or not shift.assignedCargoIds[1] then return false end
    local parcelMgr = shared.parcelManager()
    if not parcelMgr then return false end
    for _, cargoId in ipairs(shift.assignedCargoIds) do
      if parcelMgr.getCargoById(cargoId) then return true end
    end
    return false
  end
end

-- Accepting the return leg -----------------------------------------------------------------------

local function addAcceptReturnApi(api, inputs)
  local projections, routing, shared, state = inputs.projections, inputs.routing, inputs.shared, inputs.state

  local function showReturnLeg()
    projections.refreshTaskGuidance(true)
    projections.notifyUi()
    projections.closeDropOffUi()
  end

  local function returnWithoutFreight(shift)
    shift.returnIsBackhaul = nil
    shift.returnNeedsPickup = nil
    shift.assignedOfferId = nil
    shift.assignedOfferIds = nil
    shift.returnLabel = "Return the company vehicle to the office"
    shift.returnSubtext = "No return freight — head back to the yard"
    shift.destFacId = shift.originFacId or state.homeFacId
    shift.destLocation = nil
    shift.destPsPath = nil
    routing.routeToYard()
  end

  local function resumeAssignedReturnFreight(shift)
    if shift.assignedOfferId and shared.vehicleOffers() then
      shared.vehicleOffers().spawnAssignedOffer(shift.assignedOfferId, false, routing.handleVehicleSpawnResult)
    else
      inputs.parcelLoading.bindAssignedCargoToIssuedTruck()
    end
  end

  function api.acceptReturn(facId)
    local shift = state.shift
    if not shift or shift.wrecked or shared.kindPolicy(shift.jobKind).materialContract then return false end
    if shift.phase ~= "return" then return false end
    if inputs.dropOff.isDistributorHaulShift(shift) then
      returnWithoutFreight(shift)
      showReturnLeg()
      return true
    end
    if shift.assignedOfferId or (shift.assignedCargoIds and shift.assignedCargoIds[1]) then
      resumeAssignedReturnFreight(shift)
      showReturnLeg()
      return true
    end
    if inputs.backhaul.assignReturnLoad(facId or shift.destFacId) then
      showReturnLeg()
      return true
    end
    shift.returnLabel = "Return the company vehicle to the yard"
    shift.destFacId = shift.originFacId or state.homeFacId
    routing.routeToYard()
    showReturnLeg()
    return true
  end
end

-- Quitting ---------------------------------------------------------------------------------------

local function addQuitApi(api, inputs)
  local persistence, projections, settlement, shared = inputs.persistence, inputs.projections, inputs.settlement, inputs.shared

  function api.quitJob(opts)
    if not inputs.lifecycle.isEmployed() then return false end
    opts = type(opts) == "table" and opts or {}
    local silent = opts.silent == true
    local shift = inputs.state.shift
    if shift and shared.kindPolicy(shift.jobKind).materialContract and shift.assignedContractId and shared.materials() then
      -- A nil contract id would also abandon the player's independent contracts.
      shared.materials().abandonContract(shift.assignedContractId, { noFine = true, silent = true })
    end
    if shift and (shared.kindPolicy(shift.jobKind).repossession or inputs.dropOff.isBundleShift(shift)) then
      settlement.cancelEmploymentRepoJob()
    end
    local general = shared.general()
    if shift and not shared.kindPolicy(shift.jobKind).materialContract then
      discardAssignmentCargoWithPenalty(api, shared)
      api.giveBackEmploymentVehicleTasks(shift)
    end
    if shift then api.discardEmploymentCargoForReset() end
    if general then
      general.requestUpdateContainerWeights()
    end
    inputs.state.ignoreCompanyDamageStrikes = true
    settlement.assessCompanyDamageBeforePayout()
    inputs.equipment.returnIssuedVehicles()
    shared.emptyShift()
    settlement.resetEscrow()
    if general and general.isDeliveryModeActive() and general.checkExitDeliveryMode then
      general.checkExitDeliveryMode()
    end
    persistence.clearEmploymentCache()
    persistence.flushEmploymentCache()
    if not silent then
      projections.firePhoneNotification("employment.shiftEnded", "Left the company", "You are no longer employed at this yard.", "error")
      ui_message("You quit the job.", 6, "warning")
    end
    inputs.hiring.clearOfferedListings()
    projections.notifyUi()
    inputs.routing.refreshDeliveryPois()
    return true
  end

  function api.returnAllCompanyVehicles()
    if not (overhaul_career_logistics_loanerVehicles and overhaul_career_garage_inventory) then
      return 0
    end
    return overhaul_career_logistics_loanerVehicles.returnAllCompanyVehicles()
  end
end

-- Assignment cargo and vehicle tasks -------------------------------------------------------------

local function addAssignmentCargoApi(api, inputs)
  local dropOff, lifecycle, screen, shared, state = inputs.dropOff, inputs.lifecycle, inputs.screen, inputs.shared, inputs.state

  api.discardEmploymentCargoForReset = function()
    local parcelMgr = shared.parcelManager()
    if not (parcelMgr and parcelMgr.getAllCargoCustomFilter and parcelMgr.changeCargoLocation) then return end
    local assigned, companyVehicles = {}, {}
    for _, cargoId in ipairs(state.shift and state.shift.assignedCargoIds or {}) do
      assigned[cargoId] = true
    end
    for inventoryId, vehInfo in pairs(overhaul_career_garage_inventory.getVehicles() or {}) do
      if vehInfo and vehInfo.loanType == "company" then companyVehicles[inventoryId] = true end
    end
    local cargoToDiscard = parcelMgr.getAllCargoCustomFilter(function(cargo)
      if assigned[cargo.id] then return true end
      local binding = cargo.logisticsBinding
      if binding and companyVehicles[binding.inventoryId] then return true end
      local vehId = cargo.location and cargo.location.vehId
      local inventoryId = vehId and overhaul_career_garage_inventory.getInventoryIdFromVehicleId(vehId)
      return inventoryId and companyVehicles[inventoryId] or false
    end) or {}
    deleteCargo(parcelMgr, cargoToDiscard)
  end

  api.employmentCompanyVehicleIds = function()
    local companyVehicles = {}
    for inventoryId, vehInfo in pairs(overhaul_career_garage_inventory.getVehicles() or {}) do
      if vehInfo and vehInfo.loanType == "company" then companyVehicles[inventoryId] = true end
    end
    return companyVehicles
  end

  api.employmentAssignmentCargoFilter = function(cargo)
    if not cargo or not state.shift then return false end
    local shift = state.shift
    for _, cargoId in ipairs(shift.assignedCargoIds or {}) do
      if cargo.id == cargoId then return true end
    end
    if cargo.employmentAssigned then return true end
    if shift.assignedContractId and cargo.data and cargo.data.materialContractId == shift.assignedContractId then
      return true
    end
    local companyVehicles = api.employmentCompanyVehicleIds()
    local binding = cargo.logisticsBinding
    if binding and companyVehicles[binding.inventoryId] then return true end
    local vehId = cargo.location and cargo.location.vehId
    local inventoryId = vehId and overhaul_career_garage_inventory
      and overhaul_career_garage_inventory.getInventoryIdFromVehicleId(vehId)
    return inventoryId and companyVehicles[inventoryId] or false
  end

  api.canAbandonEmploymentAssignment = function()
    if screen.dropOffEscrowPending then return false end
    if not lifecycle.isOnShift() then return false end
    local shift = state.shift
    if not shift or shift.paused then return false end
    if shared.kindPolicy(shift.jobKind).roleplay then return false end
    if shift.spawnBlocked then return true end
    if dropOff.assignmentStillInProgress() then return true end
    if shift.endAfterAssignment and api.finalAssignmentInProgress() then return true end
    return false
  end

  api.deliveredEmploymentOfferIds = function(shift)
    local delivered = {}
    for _, id in ipairs(shift.deliveredOfferIds or {}) do
      delivered[id] = true
    end
    if dropOff.isBundleShift(shift) and shift.assignments and shift.assignments.vehicle
        and shift.assignments.vehicle.complete and shift.assignments.vehicle.offerId then
      delivered[shift.assignments.vehicle.offerId] = true
    end
    return delivered
  end

  api.quoteEmploymentVehicleTaskPenalty = function(shift)
    local vehicleTasks = overhaul_career_logistics_vehicleTasks
    if not vehicleTasks then return 0 end
    local offerSet = dropOff.shiftVehicleOfferIdSet(shift)
    local delivered = api.deliveredEmploymentOfferIds(shift)
    local money = 0
    for _, taskData in ipairs(vehicleTasks.getVehicleTasks() or {}) do
      local offerId = taskData.offer and taskData.offer.id
      if offerId and offerSet[offerId] and not delivered[offerId] and not taskData.remove then
        money = money - (vehicleTasks.getFineForAbandon(taskData).money or 0)
      end
    end
    return math.max(0, money)
  end

  api.abandonAssignmentQuote = function()
    if not api.canAbandonEmploymentAssignment() then return 0 end
    local shift = state.shift
    local total = 0
    if shared.kindPolicy(shift.jobKind).materialContract then
      local materials = shared.materials()
      local contractId = shift.assignedContractId
      if materials and materials.getContractById and contractId then
        local contract = materials.getContractById(contractId)
        total = total + (contract and contract.abandonmentFine or 0)
      end
    else
      local general = shared.general()
      if general then
        local penalty = general.getDeliveryModePenalty(nil, false, api.employmentAssignmentCargoFilter)
        total = total + math.max(0, -(penalty.money or 0))
      end
      total = total + api.quoteEmploymentVehicleTaskPenalty(shift)
    end
    return math.max(0, math.floor(total + 0.5))
  end

  api.clearEmploymentAssignmentFields = function(shift)
    shift.endAfterAssignment = nil
    shift.spawnBlocked = nil
    shift.assignedCargoIds = {}
    shift.assignedOfferId = nil
    shift.assignedOfferIds = nil
    shift.assignedContractId = nil
    shift.assignments = nil
    shift.repoPendingStart = nil
    shift.needsRemotePickup = nil
    shift.returnNeedsPickup = nil
    shift.returnIsBackhaul = nil
    shift.returnPickupFacId = nil
    shift.returnDeliverLabel = nil
    shift.wrecked = nil
    shift.stringMode = nil
    shift.stops = nil
    shift.stopIndex = nil
    shift.stringCargoIds = nil
    shift.stringStopTotal = nil
    shift.stopsCompleted = nil
    shift.freight = nil
    shift.plannerFreight = nil
    shift.deliveredOfferIds = nil
    shift.distributorHaul = nil
    shift.awaitingPark = nil
    shift.destFacId = nil
    shift.destPsPath = nil
    shift.destLocation = nil
    shift.outboundLabel = nil
    shift.outboundSubtext = nil
    shift.dropOffDepartureRequired = nil
    shift.parcelLoadPending = nil
    shift.parcelLoadRetryAt = nil
    shift.stringRouteLocked = nil
    shift._returnTrailerSpawning = nil
    shift._returnTrailerSpawned = nil
    shift._returnVehicleSpawning = nil
    shift._returnVehicleSpawned = nil
  end

  api.giveBackEmploymentVehicleTasks = function(shift)
    local vehicleTasks = overhaul_career_logistics_vehicleTasks
    if not vehicleTasks then return end
    local offerSet = dropOff.shiftVehicleOfferIdSet(shift)
    local delivered = api.deliveredEmploymentOfferIds(shift)
    for _, taskData in ipairs(vehicleTasks.getVehicleTasks() or {}) do
      local offerId = taskData.offer and taskData.offer.id
      if offerId and offerSet[offerId] and not delivered[offerId] and not taskData.remove then
        taskData.giveBack = true
      end
    end
  end

  api.employmentPenaltyHasCharge = function(penalty)
    if type(penalty) ~= "table" then return false end
    for _, amount in pairs(penalty) do
      if amount ~= 0 then return true end
    end
    return false
  end

  api.applyEmploymentCargoPenalty = function(penalty)
    if not api.employmentPenaltyHasCharge(penalty) then return end
    overhaul_career_economy_playerAttributes.addAttributes(penalty, require("overhaul/lib/finance/metadata").tag({
      tags = { "gameplay", "delivery", "fine", "employment" },
      label = "Company assignment abandonment",
    }, "fine"))
  end
end

-- Abandoning an assignment -----------------------------------------------------------------------

local function addAbandonApi(api, inputs)
  local dropOff, equipment, shared, state = inputs.dropOff, inputs.equipment, inputs.shared, inputs.state

  local function discardAssignmentWork(shift)
    if shared.kindPolicy(shift.jobKind).materialContract then
      local materials = shared.materials()
      if materials and materials.abandonContract then
        materials.abandonContract(shift.assignedContractId)
      end
    else
      local general = shared.general()
      discardAssignmentCargoWithPenalty(api, shared)
      if general then
        general.requestUpdateContainerWeights()
      end
      api.giveBackEmploymentVehicleTasks(shift)
    end
    inputs.settlement.cancelEmploymentRepoJob()
    api.discardEmploymentCargoForReset()
    if shared.materials() then
      shared.materials().clearTaskGuidance()
    end
    if shared.general() and shared.general().isDeliveryModeActive() then
      shared.general().checkExitDeliveryMode()
    end
  end

  api.abandonEmploymentAssignment = function()
    if not api.canAbandonEmploymentAssignment() then
      return shared.failShift("Nothing to abandon on this assignment.")
    end
    local shift = state.shift
    local quotedFine = api.abandonAssignmentQuote()
    local kindUnavailable = shared.kindUnavailable(shift)
    equipment.cancelSpawnBlockedWatch()
    discardAssignmentWork(shift)
    api.clearEmploymentAssignmentFields(shift)
    dropOff.closeWorldPrompt()
    state.dropOffProximityTimer = 0
    core_groundMarkers.setPath(nil)
    freeroam_bigMapMode.resetRoute()
    if not api.finishShift(kindUnavailable and { abandonFine = quotedFine } or nil) then
      return shared.failShift("The assignment was abandoned, but the day could not end. Try End day again.")
    end
    inputs.routing.refreshDeliveryPois()
    if overhaul_integration_services_markerInteraction then
      overhaul_integration_services_markerInteraction.setForceReevaluateOpenPrompt(true)
    end
    -- finishShift already told the player the job type is gone, what was paid and any penalty: one message.
    if kindUnavailable then return shared.okShift({ abandonFine = quotedFine }) end
    local msg = quotedFine > 0
      and string.format("Assignment abandoned. Day ended. Penalty: $%d", quotedFine)
      or "Assignment abandoned. Day ended."
    ui_message(msg, 8, quotedFine > 0 and "warning" or "info")
    return shared.okShift({ abandonFine = quotedFine })
  end
end

-- Clearing a shift while staying employed --------------------------------------------------------

local function addShiftResetApi(api, inputs)
  local equipment, persistence, projections, settlement, shared = inputs.equipment, inputs.persistence, inputs.projections, inputs.settlement, inputs.shared

  function api.clearShiftKeepEmployment(opts)
    opts = opts or {}
    equipment.cancelSpawnBlockedWatch()
    if shared.materials() then
      shared.materials().abandonContract(nil, { noFine = true, silent = true })
    end
    if shared.materials() then
      shared.materials().clearTaskGuidance()
    end
    settlement.cancelEmploymentRepoJob()
    api.discardEmploymentCargoForReset()
    local vehicleTasks = overhaul_career_logistics_vehicleTasks
    if vehicleTasks then
      vehicleTasks.abandonAllVehicleTasks()
    end
    if shared.general() and shared.general().isDeliveryModeActive() then
      shared.general().exitDeliveryMode()
    end
    local removed = api.returnAllCompanyVehicles()
    shared.emptyShift()
    if opts.keepEscrow ~= true then
      settlement.resetEscrow()
    end
    core_groundMarkers.setPath(nil)
    freeroam_bigMapMode.resetRoute()
    persistence.flushEmploymentCache()
    return removed
  end

  -- Wipe a stuck pre-fix shift: trucks, assignment, escrow, tasklist. Keep the job.
  function api.resetShiftAndEquipment()
    if not shared.isDevToolsEnabled() then
      log("W", "employment", "resetShiftAndEquipment blocked: no valid dev key")
      return false
    end
    local removed = api.clearShiftKeepEmployment()
    overhaul_career_saveSystem.saveCurrent()
    projections.firePhoneNotification("employment.shiftEnded", "Shift reset", "Company trucks returned. Clock in for a clean assignment.", "info")
    ui_message(string.format("Company shift reset (%d truck%s returned). You are still employed.", removed, removed == 1 and "" or "s"), 7, "info")
    projections.notifyUi()
    projections.closeShiftUi()
    projections.closeDropOffUi()
    return true
  end
end

-- Constructor ------------------------------------------------------------------------------------

function part.new(inputs)
  local api = inputs.api or {}

  addFinishShiftApi(api, inputs)
  addYardReturnApi(api, inputs)
  addEndDayApi(api, inputs)
  addOfferApi(api, inputs)
  addAcceptReturnApi(api, inputs)
  addQuitApi(api, inputs)
  addAssignmentCargoApi(api, inputs)
  addAbandonApi(api, inputs)
  addShiftResetApi(api, inputs)
  return api
end

return part
