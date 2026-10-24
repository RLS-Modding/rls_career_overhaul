-- Company assignment progress and drop-off settlement.
-- Reading order: freight identity, bundle progress, ownership, drop-off lookup, delivery progress and settlement.
local part = {}

-- Freight identity -------------------------------------------------------------------------------

local function addFreightIdentityApi(api, inputs)
  local eligibility, shared, state = inputs.eligibility, inputs.shared, inputs.state

  api.isBundleShift = function(shift)
    return shift and shared.kindPolicy(shift.jobKind).bundledAssignments
  end

  api.isBundleHaulBackhaulPending = function(shift)
    shift = shift or state.shift
    if not api.isBundleShift(shift) then return false end
    local assignments = shift.assignments
    return assignments and assignments.vehicle and assignments.vehicle.complete and assignments.repo and not assignments.repo.complete and true or false
  end

  api.DISTRIBUTOR_HAUL_COUNT = 2

  function api.isDistributorHaulShift(shift)
    return shift and shift.distributorHaul and true or false
  end

  api.accessPointProvidesLogisticType = function(ap, logisticType)
    return eligibility.facilityScanner().accessPointProvidesLogisticType(ap, logisticType)
  end

  api.offerHaulLogisticType = function(offer)
    return (offer and offer.task and offer.task.lookupType)
      or (offer and offer.data and offer.data.lookupType)
      or "vehDeliveryNew"
  end

  api.distributorHaulStagingPads = function(fac, logisticType)
    local pads = {}
    if not fac then return pads end
    logisticType = logisticType or "vehDeliveryNew"
    for name, ap in pairs(fac.accessPointsByName or {}) do
      if api.accessPointProvidesLogisticType(ap, logisticType) then
        local path = ap.psPath
        if (not path or path == "") and ap.ps and ap.ps.getPath then
          path = ap.ps:getPath()
        end
        if path then
          table.insert(pads, { name = name, path = path })
        end
      end
    end
    table.sort(pads, function(left, right) return tostring(left.name) < tostring(right.name) end)
    return pads
  end

  -- Pure table builder: keeps the whole pad assignment pass in one place.
  api.stageDistributorHaulOffers = function(fac, offers)
    if not fac or not offers or not offers[1] then return end
    local pads = api.distributorHaulStagingPads(fac, api.offerHaulLogisticType(offers[1]))
    if not pads[1] then return end
    local padByPath = {}
    for _, pad in ipairs(pads) do
      padByPath[pad.path] = pad
    end
    local reserved = {}
    for _, offer in ipairs(offers) do
      local path = offer.spawnLocation and offer.spawnLocation.psPath
      if path and padByPath[path] and not reserved[path] then
        reserved[path] = offer.id
      end
    end
    local function applyPad(offer, path)
      local loc = { type = "facilityParkingspot", facId = fac.id, psPath = path }
      offer.origin = loc
      offer.spawnLocation = loc
      if offer.locations then
        offer.locations[1] = loc
      end
    end
    local nextIdx = 1
    local function nextFreePad()
      while pads[nextIdx] and reserved[pads[nextIdx].path] do
        nextIdx = nextIdx + 1
      end
      local pad = pads[nextIdx]
      if pad then
        nextIdx = nextIdx + 1
        return pad
      end
      return pads[1]
    end
    for _, offer in ipairs(offers) do
      local path = offer.spawnLocation and offer.spawnLocation.psPath
      if path and reserved[path] == offer.id then
        applyPad(offer, path)
      else
        local pad = nextFreePad()
        if pad then
          reserved[pad.path] = offer.id
          applyPad(offer, pad.path)
        end
      end
    end
  end

  function api.shiftVehicleOfferIdSet(shift)
    local set = {}
    if not shift then return set end
    for _, id in ipairs(shift.assignedOfferIds or {}) do
      if id then set[id] = true end
    end
    if shift.assignedOfferId then set[shift.assignedOfferId] = true end
    local bundled = api.getShiftVehicleOfferId(shift)
    if bundled then set[bundled] = true end
    return set
  end

  function api.distributorHaulRemaining(shift)
    if not api.isDistributorHaulShift(shift) then return 0 end
    local delivered = {}
    for _, id in ipairs(shift.deliveredOfferIds or {}) do
      delivered[id] = true
    end
    local remaining = 0
    for id in pairs(api.shiftVehicleOfferIdSet(shift)) do
      if not delivered[id] then remaining = remaining + 1 end
    end
    return remaining
  end

  api.facilityOffersRepo = function(facId)
    local fac = shared.generator() and shared.generator().getFacilityById(facId)
    local caps = shared.loanerCapabilities()
    if fac and fac.employmentRepo == false then return false end
    return fac and caps and caps.canIssueRepoForFacility(fac, {}) or false
  end

  api.getShiftVehicleOfferId = function(shift)
    if not shift then return nil end
    if shift.assignments and shift.assignments.vehicle then
      if shift.assignments.vehicle.complete then
        return shift.assignedOfferId or (shift.assignments.repo and shift.assignments.repo.offerId)
      end
      return shift.assignments.vehicle.offerId
    end
    return shift.assignedOfferId
  end

  api.vehicleOfferTaskActive = function(offerId)
    if not offerId or not overhaul_career_logistics_vehicleTasks then return false end
    local tasks = overhaul_career_logistics_vehicleTasks.getVehicleTasks() or {}
    for _, taskData in ipairs(tasks) do
      if taskData.offer and taskData.offer.id == offerId then
        return true
      end
    end
    return false
  end
end

-- Bundle and haul progress -----------------------------------------------------------------------

local function addBundleProgressApi(api, inputs)
  local parcelLoading, projections, routing = inputs.parcelLoading, inputs.projections, inputs.routing
  local shared, state = inputs.shared, inputs.state

  api.getShiftAssignmentsForUi = function(shift)
    if not api.isBundleShift(shift) or not shift.assignments then return nil end
    local assignments = shift.assignments
    local items = {}
    if assignments.vehicle then
      table.insert(items, {
        id = "vehicle",
        label = assignments.vehicle.label or "Car hauling",
        subtext = assignments.vehicle.subtext or "",
        complete = assignments.vehicle.complete and true or false,
      })
    end
    if assignments.repo then
      local repoLabel = assignments.repo.label or "Pickup — haul a vehicle back to the yard"
      if assignments.vehicle and assignments.vehicle.complete and shift.returnIsBackhaul
          and assignments.repo.offerId == shift.assignedOfferId and parcelLoading.assignedReturnCargoInVehicle(shift) then
        repoLabel = shift.returnDeliverLabel or "Deliver the assigned vehicle"
      end
      table.insert(items, {
        id = "repo",
        label = repoLabel,
        subtext = assignments.repo.subtext or "",
        complete = assignments.repo.complete and true or false,
      })
    end
    return #items > 0 and items or nil
  end

  api.maybeCompleteBundleShift = function(opts)
    local shift = state.shift
    if not api.isBundleShift(shift) then return end
    local assignments = shift.assignments
    if not assignments or not assignments.vehicle or not assignments.repo then return end
    if not assignments.vehicle.complete or not assignments.repo.complete then
      projections.refreshTaskGuidance(true)
      projections.notifyUi()
      return
    end
    opts = opts or {}
    -- Repo drop-off is the home yard; jockey finishing last can be elsewhere.
    if opts.atYard or routing.playerNearHomeYard() then
      routing.offerLoopCompleteChoice({
        label = "Assignments complete",
        subtext = "Take another job or end your day",
      })
      return
    end
    routing.beginYardReturnForLoopChoice()
  end

  function api.materialsAssignmentHasWork()
    local active = shared.materials() and shared.materials().getActiveContract()
    if not active or active.status ~= "active" then return false end
    return (tonumber(active.remainingAmount) or 0) > 0
      or (tonumber(active.inTransitAmount) or 0) > 0
      or (tonumber(active.loadableAmount) or 0) > 0
  end

  api.assignmentStillInProgress = function()
    local shift = state.shift
    if not shift or shift.paused then return false end
    if api.isBundleShift(shift) then
      if shift.wrecked then return false end
      local assignments = shift.assignments
      if not assignments then return false end
      if not assignments.vehicle or not assignments.vehicle.complete then return true end
      if not assignments.repo or not assignments.repo.complete then
        return true
      end
      return false
    end
    if shared.kindPolicy(shift.jobKind).roleplay then
      return false
    end
    if shared.kindPolicy(shift.jobKind).materialContract then
      return api.materialsAssignmentHasWork()
    end
    if shared.kindPolicy(shift.jobKind).repossession then
      if shift.repoPendingStart then return true end
      local repo = shared.repoJob()
      return repo and repo.isEmploymentRepoActive() or false
    end
    if shift.wrecked or shift.phase == "loopComplete" then return false end
    return shift.phase == "outbound" or shift.phase == "return"
  end
end

-- Delivery-mode ownership ------------------------------------------------------------------------

local function addDeliveryOwnershipApi(api, inputs)
  local eligibility, lifecycle, shared, state = inputs.eligibility, inputs.lifecycle, inputs.shared, inputs.state

  function api.getEmployerOrgId()
    return state.employerOrgId
  end

  function api.keepDeliveryModeActive()
    -- Held (paused) shifts keep delivery mode so exitDeliveryMode does not abandon what the player will resume.
    return state.shift ~= nil and (lifecycle.isOnShift() or state.shift.paused) and true or false
  end

  local function assignedIdSet()
    local set = {}
    local shift = state.shift
    if not shift then return set end
    for _, id in ipairs(shift.assignedCargoIds or {}) do
      set[id] = true
    end
    return set
  end

  function api.cargoIsAssigned(cargo)
    if not cargo or not state.shift then return false end
    if state.shift.assignedContractId and cargo.data and cargo.data.materialContractId == state.shift.assignedContractId then
      return true
    end
    return assignedIdSet()[cargo.id] and true or false
  end

  api.facilityMatchesEmployer = function(facId)
    if not lifecycle.isEmployed() then return false end
    local fac = shared.generator() and shared.generator().getFacilityById(facId)
    return fac and fac.associatedOrganization == state.employerOrgId
      and (fac.employmentCustomer ~= true or eligibility.isRoleplayFacility(facId))
  end

  function api.closeWorldPrompt()
    if overhaul_integration_services_markerInteraction then
      overhaul_integration_services_markerInteraction.closeViewDetailPrompt(true)
    end
  end

  function api.pauseSim(paused)
    simTimeAuthority.pause(paused and true or false)
  end

  function api.changeToPlay()
    guihooks.trigger("ChangeState", { state = "play" })
  end

  api.cargoDestinationMatchesSpot = function(cargo, facId, psPath)
    if not cargo or not facId or not psPath then return false end
    local destination = cargo.destination
    if not destination then return false end
    if destination.type == "facilityParkingspot" then
      return destination.facId == facId and destination.psPath == psPath
    end
    if destination.type == "multi" then
      for _, candidate in ipairs(destination.destinations or {}) do
        if candidate and candidate.facId == facId and candidate.psPath == psPath then return true end
      end
    end
    return false
  end

  function api.canMoveCargoOntoLocation(cargoId, targetLocation)
    if type(targetLocation) ~= "table" then return true end
    local parcelMgr = shared.parcelManager()
    local cargo = parcelMgr and parcelMgr.getCargoById(cargoId)
    if targetLocation.type == "facilityParkingspot" then
      if not eligibility.hasCompanyShift() then return true end
      return false
    end
    if not targetLocation.vehId then return true end
    local inventoryId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(targetLocation.vehId)
    local vehInfo = inventoryId and overhaul_career_garage_inventory.getVehicles()[inventoryId]
    if not (vehInfo and vehInfo.loanType == "company") then return true end
    if not lifecycle.isOnShift() then return false end
    return api.cargoIsAssigned(cargo)
  end
end

-- Assigned drop-off lookup -----------------------------------------------------------------------

-- Cargo ids and vehicle offer ids the shift can confirm at this pad; empty while a departure or pickup is pending.
local function gatherAssignedDropOffs(api, inputs, facId, psPath)
  local shared, state = inputs.shared, inputs.state
  local confirmedCargoIds, confirmedOfferIds = {}, {}
  local shift = state.shift
  if shift and shared.kindPolicy(shift.jobKind).parcels
      and ((shift.phase == "outbound" and shift.needsRemotePickup)
        or (shift.phase == "return" and shift.returnNeedsPickup)
        or shift.dropOffDepartureRequired) then
    return confirmedCargoIds, confirmedOfferIds
  end
  local parcelMgr = shared.parcelManager()
  if parcelMgr then
    for _, cargo in ipairs(parcelMgr.getAllCargoInVehicles(true) or {}) do
      if ((cargo.location and cargo.location.type == "vehicle")
          or (cargo._transientMove and cargo._transientMove.targetLocation
            and cargo._transientMove.targetLocation.type == "vehicle"))
          and api.cargoIsAssigned(cargo) and api.cargoDestinationMatchesSpot(cargo, facId, psPath) then
        table.insert(confirmedCargoIds, { id = cargo.id, ids = { cargo.id }, amount = cargo.slots })
      end
    end
  end
  if state.shift and overhaul_career_logistics_vehicleTasks then
    local tasks = overhaul_career_logistics_vehicleTasks.getVehicleTasks() or {}
    local assigned = api.shiftVehicleOfferIdSet(state.shift)
    for _, taskData in ipairs(tasks) do
      local offer = taskData.offer
      local activeTask = taskData.tasks and taskData.tasks[taskData.activeTaskIndex]
      local destination = activeTask and activeTask.destination
        or (offer and (offer.destination or (offer.task and offer.task.destination)))
      local missingVehicle = taskData.logisticsPending
        or not (taskData.vehId and getObjectByID(taskData.vehId))
      local readyToDropOff = activeTask and (activeTask.type == "confirmDropOff"
        or (missingVehicle and (tonumber(taskData.activeTaskIndex) or 0) > 1
          and activeTask.type == "bringToDestination"))
      if offer and offer.id and assigned[offer.id] and readyToDropOff then
        if destination and destination.psPath == psPath
            and (not destination.facId or destination.facId == facId) then
          table.insert(confirmedOfferIds, offer.id)
        end
      end
    end
  end
  return confirmedCargoIds, confirmedOfferIds
end

local function addDropOffLookupApi(api, inputs)
  local parcelLoading, projections, shared, state = inputs.parcelLoading, inputs.projections, inputs.shared, inputs.state
  local lifecycle = inputs.lifecycle

  function api.hasAssignedDropOffHere(facId, psPath)
    local cargoIds, offerIds = gatherAssignedDropOffs(api, inputs, facId, psPath)
    return next(cargoIds) ~= nil or next(offerIds) ~= nil
  end

  api.getDropOffParkingLevels = function(facId, psPath)
    if not facId or not psPath then return nil end
    local generator = shared.generator()
    local precision = overhaul_career_logistics_precisionParking
    local spot = generator and generator.getParkingSpotByPath(psPath)
    if not (spot and precision) then return nil end

    local cargoIds, offerIds = gatherAssignedDropOffs(api, inputs, facId, psPath)
    local levels, seen = {}, {}
    local function addVehicle(vehId)
      if not (vehId and getObjectByID(vehId)) then return end
      local score = precision.calculateVehiclePrecisionScore(vehId, spot)
      local level = score and score.precisionLevel
      if level and not seen[level] then
        levels[#levels + 1] = level
        seen[level] = true
      end
    end

    if #offerIds > 0 then
      local assigned = {}
      for _, id in ipairs(offerIds) do assigned[id] = true end
      local tasks = overhaul_career_logistics_vehicleTasks.getVehicleTasks() or {}
      for _, task in ipairs(tasks) do
        local activeTask = task.tasks and task.tasks[task.activeTaskIndex]
        local destination = activeTask and activeTask.destination
        if task.offer and assigned[task.offer.id] and destination
            and destination.psPath == psPath then
          addVehicle(task.vehId)
        end
      end
    end

    if #cargoIds > 0 then
      local parcelMgr = shared.parcelManager()
      for _, elem in ipairs(cargoIds) do
        local cargo = parcelMgr and parcelMgr.getCargoById(elem.id)
        if cargo and cargo.destination and cargo.destination.psPath == psPath then
          addVehicle(be:getPlayerVehicleID(0))
          break
        end
      end
    end

    return #levels > 0 and levels or nil
  end

  function api.hasOutstandingReturnWork(shift)
    if not shift or shift.phase ~= "return" then return false end
    if shift.returnNeedsPickup then return true end
    if shift.assignedOfferId then return true end
    local parcelMgr = shared.parcelManager()
    for _, cargoId in ipairs(shift.assignedCargoIds or {}) do
      local cargo = parcelMgr and parcelMgr.getCargoById(cargoId)
      if cargo then return true end
    end
    return false
  end

  -- true = handled (drop-off opened or routed); false = open shift UI as normal
  api.tryReturnDropOffBeforeShiftUi = function(facId)
    local shift = state.shift
    if not shift or shift.paused then
      return false
    end
    if shared.kindPolicy(shift.jobKind).parcels and shift.phase == "outbound" then
      local destFac = shift.destFacId
      local destPs = shift.destPsPath
      if facId == destFac and destPs and api.hasAssignedDropOffHere(destFac, destPs) then
        projections.openDropOffUi(destFac, destPs)
        return true
      end
      return false
    end
    if shift.phase ~= "return" or not shift.returnIsBackhaul then return false end
    if not (parcelLoading.assignedReturnCargoInVehicle(shift) or api.hasOutstandingReturnWork(shift)) then
      return false
    end
    local destFac = shift.destFacId
    local destPs = shift.destPsPath
    if not destFac or not destPs then return false end
    if api.hasAssignedDropOffHere(destFac, destPs) then
      projections.openDropOffUi(destFac, destPs)
      return true
    end
    return false
  end

  function api.shouldOpenEmployeeDropOff(facId, psPath)
    if not lifecycle.isOnShift() then return false end
    local shift = state.shift
    if shared.kindPolicy(shift.jobKind).materialContract then
      local active = shared.materials() and shared.materials().getActiveContract()
      if active and active.status == "active" then
        return false
      end
    end
    return api.hasAssignedDropOffHere(facId, psPath)
  end
end

-- Outbound and return delivery -------------------------------------------------------------------

local function addDeliveryProgressApi(api, inputs)
  local parcelStrings, projections, routing, state = inputs.parcelStrings, inputs.projections, inputs.routing, inputs.state

  local function closeDropOffUnlessProgress()
    if inputs.screen.dropOffOpen and not projections.maybeKeepDropOffOpenForProgress() then
      projections.closeDropOffUi()
    end
  end

  local function finishMaterialOutbound(shift)
    if api.materialsAssignmentHasWork() then
      shift.phase = "outbound"
      projections.refreshTaskGuidance(true)
      projections.notifyUi()
      return
    end
    routing.beginYardReturnForLoopChoice()
  end

  local function returnDistributorHaulToYard(shift)
    shift.phase = "return"
    shift.returnIsBackhaul = nil
    shift.returnNeedsPickup = nil
    shift.assignedOfferId = nil
    shift.assignedOfferIds = nil
    shift.awaitingLoopChoice = true
    shift.returnLabel = "Return the company vehicle to the office"
    shift.returnDeliverLabel = nil
    shift.returnSubtext = "No return freight — head back to the yard"
    shift.destFacId = shift.originFacId or state.homeFacId
    shift.destLocation = nil
    shift.destPsPath = nil
    routing.routeToYard()
    projections.refreshTaskGuidance(true)
    projections.notifyUi()
    closeDropOffUnlessProgress()
  end

  local function finishVehicleDelivery(shift)
    if api.isDistributorHaulShift(shift) then
      returnDistributorHaulToYard(shift)
      return
    end
    -- Drive-off vehicle work gets a return vehicle when the destination has one.
    shift.phase = "return"
    inputs.backhaul.assignReturnLoad(shift.destFacId)
    api.trySetShiftRoute()
    projections.refreshTaskGuidance(true)
    projections.notifyUi()
    closeDropOffUnlessProgress()
  end

  local function returnEmptyFromString(shift)
    shift.phase = "return"
    shift.returnIsBackhaul = nil
    shift.returnNeedsPickup = nil
    shift.assignedCargoIds = {}
    shift.destFacId = shift.originFacId or state.homeFacId
    shift.destLocation = nil
    shift.destPsPath = nil
    shift.returnLabel = "Return to the company yard"
    shift.returnSubtext = "Empty return — take another string or end your day"
    api.trySetShiftRoute()
    projections.refreshTaskGuidance(true)
    projections.notifyUi()
    routing.refreshDeliveryPois()
    closeDropOffUnlessProgress()
  end

  local function finishStringStop(shift)
    local hadRemainingHere = parcelStrings.currentStopHasRemaining(shift)
    if hadRemainingHere then
      parcelStrings.applyStop(shift, shift.stopIndex or 1)
      projections.refreshTaskGuidance(true)
      projections.notifyUi()
      routing.refreshDeliveryPois()
      return
    end
    shift.stopsCompleted = (tonumber(shift.stopsCompleted) or 0) + 1
    if parcelStrings.advanceStop(shift) then
      routing.routeCurrentAssignment()
      projections.refreshTaskGuidance(true)
      projections.notifyUi()
      routing.refreshDeliveryPois()
      closeDropOffUnlessProgress()
      return
    end
    if parcelStrings.planFromTruck(shift, shift.destLocation or shift.destFacId) then
      routing.routeCurrentAssignment()
      projections.refreshTaskGuidance(true)
      projections.notifyUi()
      routing.refreshDeliveryPois()
      closeDropOffUnlessProgress()
      return
    end
    if api.facilityMatchesEmployer(shift.destFacId) or api.facilityMatchesEmployer(inputs.screen.dropOffFacId) or routing.playerNearHomeYard() then
      routing.offerLoopCompleteChoice({
        label = "Loop complete",
        subtext = "Take another job or end your day",
      })
      return
    end
    returnEmptyFromString(shift)
  end

  -- Parcel / trailer: enter return (backhaul) automatically — no player choice.
  local function startAutomaticBackhaul(shift)
    shift.phase = "return"
    shift.returnLabel = shift.returnLabel or "Pick up the return load, then drive to the yard"
    inputs.backhaul.assignReturnLoad(shift.destFacId)
    api.trySetShiftRoute()
    projections.refreshTaskGuidance(true)
    projections.notifyUi()
    closeDropOffUnlessProgress()
  end

  api.afterOutboundDelivered = function()
    local shift = state.shift
    if not shift or shift.phase ~= "outbound" then return end
    if inputs.shared.kindPolicy(shift.jobKind).materialContract then
      finishMaterialOutbound(shift)
      return
    end
    if inputs.shared.isOpenEndedJobKind(shift.jobKind) then
      -- Repo / roleplay finish at the yard (or open-ended site); prompt, do not auto-dispatch.
      routing.offerLoopCompleteChoice({
        label = "Assignment complete",
        subtext = "Take another job or end your day",
      })
      return
    end
    if inputs.shared.kindPolicy(shift.jobKind).vehicleDelivery then
      finishVehicleDelivery(shift)
      return
    end
    if shift.stringMode and shift.stops then
      finishStringStop(shift)
      return
    end
    startAutomaticBackhaul(shift)
  end

  api.afterReturnDelivered = function()
    local shift = state.shift
    if not shift then return end
    if shift.phase == "loopComplete" then return end
    if shift.phase ~= "return" then return end
    shift.awaitingLoopChoice = nil
    -- Back at yard (return drop-off / empty yard arrival): prompt, never auto-assign.
    routing.offerLoopCompleteChoice({
      label = "Loop complete",
      subtext = "Take another job or end your day",
    })
  end
end

-- Company drop-off actions -----------------------------------------------------------------------

local function addCompanyDropOffApi(api, inputs)
  local projections, routing, screen, shared = inputs.projections, inputs.routing, inputs.screen, inputs.shared

  local function openShiftUiOrRefresh(shift)
    if not screen.dropOffOpen and not screen.uiOpen then
      projections.openShiftUi(shift.originFacId or inputs.state.homeFacId)
    else
      projections.notifyUi()
    end
  end

  local function reportMaterialDelivery(materials, active)
    if materials.refreshTaskGuidance then materials.refreshTaskGuidance(true) end
    local remaining = math.max(0, tonumber(active.remainingAmount) or 0)
    local delivered = math.max(0, tonumber(active.deliveredAmount) or 0)
    local units = active.units or "L"
    local cargoScreen = shared.cargoScreen()
    if (active.inTransitAmount or 0) > 0 then
      if cargoScreen and cargoScreen.setMaterialContractDestinationRoute then
        cargoScreen.setMaterialContractDestinationRoute(false)
      end
    elseif (active.loadableAmount or 0) > 0 then
      if cargoScreen and cargoScreen.setMaterialContractPickupRoute then
        cargoScreen.setMaterialContractPickupRoute(false)
      else
        routing.routeToYard()
      end
    else
      routing.routeToYard()
    end
    if shared.general() then
      shared.general().requestUpdateContainerWeights()
      shared.general().updateContainerWeights()
    end
    ui_message(string.format("Delivered %d %s · %d %s remaining. Return to the yard.", math.floor(delivered + 0.5), units, math.floor(remaining + 0.5), units), 7, "info")
    routing.refreshDeliveryPois()
    projections.notifyUi()
  end

  -- When shift nav declines, route the assignment dest; never force the inspect pad over a loaded delivery pin.
  local function applyPostDropOffRoute()
    if not inputs.lifecycle.isOnShift() then return end
    if not api.trySetShiftRoute() then
      routing.routeCurrentAssignment()
    end
    projections.refreshTaskGuidance(true)
    projections.notifyUi()
  end

  api.afterCompanyDropOff = function()
    if not inputs.lifecycle.isOnShift() then return end
    local shift = inputs.state.shift
    if shift.phase == "loopComplete" and not shift.wrecked then
      openShiftUiOrRefresh(shift)
      return
    end
    local materials = shared.materials()
    local active = materials and materials.getActiveContract and materials.getActiveContract()
    if shared.kindPolicy(shift.jobKind).materialContract and api.materialsAssignmentHasWork() then
      reportMaterialDelivery(materials, active)
      return
    end
    if shared.kindPolicy(shift.jobKind).materialContract and shift.phase == "outbound" then
      api.afterOutboundDelivered()
      return
    end
    -- Defer one tick: finishing the outbound trailer task calls navigateToActiveTasks with no targets and clears the path set here.
    core_jobsystem.create(function(job)
      job.sleep(0)
      applyPostDropOffRoute()
    end)
  end

  api.trySetShiftRoute = function()
    if not inputs.lifecycle.isOnShift() then return false end
    local shift = inputs.state.shift
    if shift.awaitingPark then
      return inputs.equipment.routeToParkStall()
    end
    if shared.kindPolicy(shift.jobKind).materialContract then
      local active = shared.materials() and shared.materials().getActiveContract()
      if active and active.status == "active" then
        return false
      end
    end
    if shift.phase == "return" then
      -- Still need to collect return freight at another yard — pin that pickup, not the office.
      if shift.returnNeedsPickup and not inputs.parcelLoading.assignedReturnCargoInVehicle(shift) then
        return routing.routeToReturnPickup()
      end
      if inputs.parcelLoading.assignedReturnCargoInVehicle(shift) then
        shift.returnNeedsPickup = nil
      end
      -- Backhaul drop-off pad (including home-yard trailer/parcel dest) — never the inspect stall.
      if shift.returnIsBackhaul then
        local loc = shift.destLocation
        if not loc and shift.destFacId then
          loc = { type = "facilityParkingspot", facId = shift.destFacId, psPath = shift.destPsPath }
        end
        if loc and routing.routeToLocation(loc) then
          routing.refreshDeliveryPois()
          return true
        end
      end
      -- Empty yard return / no dest pad.
      return routing.routeToYard()
    end
    if shift.phase == "loopComplete" or shift.wrecked then
      return routing.routeToYard()
    end
    if shared.kindPolicy(shift.jobKind).parcels and shift.phase == "outbound" then
      local loc = shift.destLocation
      if not loc and shift.destFacId then
        loc = { type = "facilityParkingspot", facId = shift.destFacId, psPath = shift.destPsPath }
      end
      if loc and routing.routeToLocation(loc) then
        routing.refreshDeliveryPois()
        return true
      end
    end
    return false
  end

  -- Hands the assigned cargo and vehicle offers to the progress service; false when it refuses.
  local function submitAssignedDropOff(facId, psPath, cargoIds, offerIds)
    local progress = overhaul_career_logistics_progress
    if not progress then return false end
    screen.lastDropOffParkingLevels = api.getDropOffParkingLevels(facId, psPath)
    screen.dropOffEscrowPending = true
    screen.holdDropOffForProgress = screen.dropOffOpen
    local shift = inputs.state.shift
    local atDropOff = routing.playerNearLocation({ type = "facilityParkingspot", facId = facId, psPath = psPath }, 8)
    local result = progress.confirmDropOffData({
      confirmedCargoIds = cargoIds,
      confirmedOfferIds = offerIds,
    }, facId, psPath, function(cargo)
      local recoverable = cargo.logisticsPending
        or (cargo.location and cargo._transientMove and cargo._transientMove.targetLocation
          and cargo._transientMove.targetLocation.type == "vehicle")
      return atDropOff and inputs.state.shift == shift and recoverable
        and api.cargoIsAssigned(cargo) and api.cargoDestinationMatchesSpot(cargo, facId, psPath)
    end, atDropOff and { facId = facId, psPath = psPath } or nil)
    if result == false then
      screen.dropOffEscrowPending = false
      screen.holdDropOffForProgress = false
      projections.notifyUi()
      return false
    end
    projections.notifyUi()
    return true
  end

  -- With nothing to settle, a finished loop at the yard still ends through the return prompt.
  local function confirmYardArrivalWithoutFreight(facId)
    local shift = inputs.state.shift
    if not shift then return false end
    if shift.phase == "loopComplete" or shift.awaitingLoopChoice then
      api.afterReturnDelivered()
      return true
    end
    if shift.phase == "return" and api.facilityMatchesEmployer(facId) and not api.hasOutstandingReturnWork(shift) then
      api.afterReturnDelivered()
      return true
    end
    return false
  end

  function api.confirmEmployeeDropOff(facId, psPath)
    if not inputs.lifecycle.isOnShift() then return false end
    if screen.dropOffEscrowPending then
      ui_message("Still confirming the last drop-off — wait a moment.", 5, "info")
      return false
    end
    local cargoIds, offerIds = gatherAssignedDropOffs(api, inputs, facId, psPath)
    if next(cargoIds) or next(offerIds) then
      return submitAssignedDropOff(facId, psPath, cargoIds, offerIds)
    end
    return confirmYardArrivalWithoutFreight(facId)
  end

  function api.tryAutoDropOffAssigned(_facId, _psPath)
    return false
  end
end

-- Timed parcels ----------------------------------------------------------------------------------

local function addTimedParcelApi(api, inputs)
  local eligibility, parcelStrings, shared = inputs.eligibility, inputs.parcelStrings, inputs.shared

  function api.cargoHasTimedModifier(item)
    if not item then return false end
    if item.rewards == nil and not item._modsChecked then
      local generator = shared.generator()
      if generator then
        generator.finalizeParcelItemDistanceAndRewards(item)
        item._modsChecked = true
      end
    end
    return eligibility.sharedParcelMods().hasModifier(item, "timed")
  end

  api.purgeTimedParcelsFromShift = function(shift)
    if not shift then return end
    local parcelMgr = shared.parcelManager()
    local keep, keepSet = {}, {}
    for _, cargoId in ipairs(shift.assignedCargoIds or {}) do
      local cargo = parcelMgr and parcelMgr.getCargoById(cargoId)
      if cargo and not api.cargoHasTimedModifier(cargo) then
        table.insert(keep, cargoId)
        keepSet[cargoId] = true
      elseif cargo and cargo.location and cargo.location.type == "vehicle" and shift.originLocation and parcelMgr.changeCargoLocation then
        parcelMgr.changeCargoLocation(cargoId, shift.originLocation)
      end
    end
    shift.assignedCargoIds = keep
    if shift.stringCargoIds then
      local keptStringCargoIds = {}
      for _, cargoId in ipairs(shift.stringCargoIds) do
        if keepSet[cargoId] then table.insert(keptStringCargoIds, cargoId) end
      end
      shift.stringCargoIds = keptStringCargoIds
    end
    shift.stops = {}
    shift.stopIndex = 1
    shift.stopsCompleted = 0
    shift.stringStopTotal = nil
    shift.stringRouteLocked = nil
  end

  api.rebuildStringFromFinalTruckLoad = function(shift)
    if not (shift and shift.stringMode) then return false end
    api.purgeTimedParcelsFromShift(shift)
    return parcelStrings.planFromTruck(shift, shift.originLocation or shift.originFacId)
  end

  function api.countAssignedParcelsOnTruck(shift)
    local parcelMgr = shared.parcelManager()
    if not (shift and parcelMgr and parcelMgr.getCargoById) then return 0 end
    local count = 0
    for _, cargoId in ipairs(shift.assignedCargoIds or {}) do
      local cargo = parcelMgr.getCargoById(cargoId)
      if cargo and cargo.location and cargo.location.type == "vehicle" and not api.cargoHasTimedModifier(cargo) then
        count = count + 1
      end
    end
    return count
  end
end

-- Constructor ------------------------------------------------------------------------------------

function part.new(inputs)
  local api = inputs.api or {}

  addFreightIdentityApi(api, inputs)
  addBundleProgressApi(api, inputs)
  addDeliveryOwnershipApi(api, inputs)
  addDropOffLookupApi(api, inputs)
  addDeliveryProgressApi(api, inputs)
  addCompanyDropOffApi(api, inputs)
  addTimedParcelApi(api, inputs)
  return api
end

return part
