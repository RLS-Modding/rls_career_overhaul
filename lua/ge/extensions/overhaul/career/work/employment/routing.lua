-- Company logistics employment routing: routes to yard, pickups and stops, yard arrival, return legs and starting assigned work.
-- part.new publishes every method onto inputs.api; calls between methods stay late bound through api.
-- gameplay_walk is per-level and may be absent during career load or level teardown.
local part = {}

local HOME_YARD_NEAR_DIST = 70
local SHIFT_START_DIST = 30
local YARD_AUTO_OPEN_DIST = 10
local YARD_SETTLE_SPEED = 0.35
local YARD_SETTLE_TIME = 1.0

-- Helpers -----------------------------------------------------------------------------------------

-- The first facility spot with a position, in the order the yard routes use.
local function facilitySpot(fac)
  return (fac.trailerSpots and fac.trailerSpots[1])
    or (fac.pickUpSpots and fac.pickUpSpots[1])
    or (fac.inspectSpots and fac.inspectSpots[1])
    or (fac.dropOffSpots and fac.dropOffSpots[1])
end

-- The position a location routes to, or nil when it cannot be resolved yet.
local function locationPosition(gen, location)
  local toPos = location.type == "coordinates" and location.pos
    or (gen and gen.getLocationCoordinates(location))
  if not toPos and location.type == "facilityParkingspot" and location.psPath and gen then
    local spot = gen.getParkingSpotByPath(location.psPath)
    toPos = spot and spot.pos
  end
  return toPos
end

-- Falls back to the facility's first spot, and remembers its path on the location.
local function facilityFallbackPosition(gen, location)
  local fac = gen.getFacilityById(location.facId)
  local spot = fac and facilitySpot(fac)
  if not spot then return nil end
  if not location.psPath then
    location.psPath = (spot.getPath and spot:getPath()) or spot.psPath
  end
  return spot.pos
end

local function yardLocation(state, shared)
  local shift = state.shift
  local facId = (shift and shift.originFacId) or state.homeFacId
  local gen = shared.generator()
  local fac = gen and gen.getFacilityById(facId)
  if not fac then return shift and shift.originLocation or nil end
  local spot = (fac.inspectSpots and fac.inspectSpots[1])
    or (fac.pickUpSpots and fac.pickUpSpots[1])
    or (fac.dropOffSpots and fac.dropOffSpots[1])
  if not spot then return shift and shift.originLocation or nil end
  local path = (spot.getPath and spot:getPath()) or spot.psPath
  if not path then return shift and shift.originLocation or nil end
  return { type = "facilityParkingspot", facId = facId, psPath = path }
end

-- The yard's parking spot position, or nil when the yard has no resolvable spot.
local function yardSpotPosition(yard, shared)
  local gen = shared.generator()
  local spot = yard and yard.psPath and gen and gen.getParkingSpotByPath(yard.psPath)
  return spot and spot.pos
end

local function playerVehicleSpeed()
  local veh = be:getPlayerVehicle(0)
  if not (veh and veh.getVelocity) then return nil end
  return veh:getVelocity():length()
end

-- Drops the map route, its nav focus and the ground path.
local function clearRoute()
  if freeroam_bigMapMode then
    freeroam_bigMapMode.setNavFocus(nil)
    freeroam_bigMapMode.resetRoute()
  end
  if core_groundMarkers then core_groundMarkers.setPath(nil) end
end

-- True when the player is still in a state where the drop-off screen must not open.
local function dropOffProximityBlocked(screen, shift)
  return screen.uiOpen or screen.dropOffOpen or screen.dropOffEscrowPending
    or not shift
    or (gameplay_walk and gameplay_walk.isWalking())
end

-- Rescans the generators once so the return offers are fresh for this leg.
local function rescanReturnOffersOnce(shared, shift)
  if shift.returnVehicleOffersRescanned then return end
  local gen = shared.generator()
  if gen then gen.triggerAllGenerators() end
  shift.returnVehicleOffersRescanned = true
end

-- Offers already delivered or attempted on this shift are excluded from the next pick.
local function returnOfferExclusions(endDay, shift)
  local excluded = {}
  for id in pairs(endDay.deliveredEmploymentOfferIds(shift)) do
    excluded[id] = true
  end
  shift.returnVehicleAttemptedOfferIds = shift.returnVehicleAttemptedOfferIds or {}
  for id, flagged in pairs(shift.returnVehicleAttemptedOfferIds) do
    if flagged then excluded[id] = true end
  end
  return excluded
end

-- Marks the repo leg complete when no inbound vehicle is left for the yard.
local function completeRepoLegWithoutVehicle(dropOff, a)
  a.repo.complete = true
  a.repo.offerId = nil
  a.repo.label = "Return to the company yard"
  a.repo.subtext = "No inbound vehicle available"
  ui_message("No inbound vehicle for the yard. Head back to return the company truck.", 7, "info")
  dropOff.maybeCompleteBundleShift()
end

-- Routing -----------------------------------------------------------------------------------------

-- Navigation --------------------------------------------------------------------------------------

local function addNavigationApi(api, inputs)
  local equipment, shared, state = inputs.equipment, inputs.shared, inputs.state

  function api.routeToLocation(location)
    if not location then return false end
    local gen = shared.generator()
    local toPos = locationPosition(gen, location)
    if not toPos and location.facId and gen then
      toPos = facilityFallbackPosition(gen, location)
    end
    if not toPos then return false end
    if freeroam_bigMapMode then
      freeroam_bigMapMode.setNavFocus(toPos)
    end
    if core_groundMarkers then
      core_groundMarkers.setPath({toPos}, {clearPathOnReachingTarget = false})
    end
    return true
  end

  function api.getYardLocation()
    return yardLocation(state, shared)
  end

  -- Admission uses only this depot's clock-in and company spawn pads, never nearby businesses.
  function api.shiftStartSpots(facId)
    local gen = shared.generator()
    local fac = gen and gen.getFacilityById(facId)
    local spots = {}
    for _, collection in ipairs({fac and fac.inspectSpots or {}, fac and fac.loanerNonTrailerSpots or {}}) do
      for _, spot in ipairs(collection) do
        if spot.pos then spots[#spots + 1] = spot end
      end
    end
    return spots
  end

  function api.playerNearShiftStart(facId)
    local player = be:getPlayerVehicle(0)
    if not player then return false end
    local position = player:getPosition()
    for _, spot in ipairs(api.shiftStartSpots(facId)) do
      if (position - spot.pos):length() <= SHIFT_START_DIST then return true end
    end
    return false
  end

  function api.routeToShiftStart(facId)
    local spot = api.shiftStartSpots(facId)[1]
    return spot and api.routeToLocation({type = "coordinates", pos = spot.pos}) or false
  end

  function api.refreshDeliveryPois()
    if gameplay_rawPois then gameplay_rawPois.clear() end
    if shared.general() then
      shared.general().requestDeliveryPoiRefresh(true)
    end
  end

  function api.routeToYard()
    -- Leave the route alone: resetting it here leaves pins on old cargo instead of the yard.
    if not api.routeToLocation(api.getYardLocation()) then return false end
    api.refreshDeliveryPois()
    return true
  end

  function api.playerNearHomeYard(maxDist)
    maxDist = tonumber(maxDist) or HOME_YARD_NEAR_DIST
    local veh = be:getPlayerVehicle(0)
    if not veh or not veh.getPosition then return false end
    return api.nearYardAnchor(veh:getPosition(), maxDist, api.yardAnchorPositions())
  end

  function api.yardAnchorPositions()
    local positions = {}
    local yard, gen = api.getYardLocation(), shared.generator()
    if not (yard and gen) then return positions end
    local fac = yard.facId and gen.getFacilityById(yard.facId)
    for _, point in pairs(fac and fac.accessPointsByName or {}) do
      if point.ps and point.ps.pos then positions[#positions + 1] = point.ps.pos end
    end
    if not positions[1] then
      local position = yardSpotPosition(yard, shared)
      if position then positions[1] = position end
    end
    return positions
  end

  function api.nearYardAnchor(position, maxDist, anchors)
    for _, anchor in ipairs(anchors) do
      if (position - anchor):length() <= maxDist then return true end
    end
    return false
  end

  function api.companyVehiclesAwayFromYard(maxDist)
    maxDist = tonumber(maxDist) or HOME_YARD_NEAR_DIST
    local inventory = overhaul_career_garage_inventory
    if not inventory then return false end
    local anchors = api.yardAnchorPositions()
    if not anchors[1] then return false end
    for _, inventoryId in ipairs(equipment.collectCompanyInventoryIds()) do
      local vehId = inventory.getVehicleIdFromInventoryId(inventoryId)
      local veh = vehId and vehId >= 0 and getObjectByID(vehId)
      if veh and not api.nearYardAnchor(veh:getPosition(), maxDist, anchors) then return true end
    end
    return false
  end

  function api.playerNearLocation(loc, maxDist)
    maxDist = tonumber(maxDist) or 150
    if not loc then return false end
    local veh = be:getPlayerVehicle(0)
    if not veh or not veh.getPosition then return false end
    local gen = shared.generator()
    local pos = gen and gen.getLocationCoordinates(loc)
    if not pos and loc.psPath and gen then
      local spot = gen.getParkingSpotByPath(loc.psPath)
      pos = spot and spot.pos
    end
    if not pos then return false end
    return (veh:getPosition() - pos):length() <= maxDist
  end
end

-- Assignment route --------------------------------------------------------------------------------

-- Routes to the company truck while the player still needs to get into it; true when that took the step.
local function routeCompanyVehicleEntry(equipment, shift)
  if shift.parcelLoadPending then
    equipment.routeToCompanyTruck()
    return true
  end
  if shift.awaitingCompanyVehicleEntry then
    if equipment.playerInIssuedCompanyTruck() then
      shift.awaitingCompanyVehicleEntry = nil
    else
      equipment.routeToCompanyTruck()
      return true
    end
  end
  return false
end

local function addAssignmentRouteApi(api, inputs)
  local equipment, shared, state = inputs.equipment, inputs.shared, inputs.state

  local function routeToDestination(shift, cs)
    if shift.destLocation then
      api.routeToLocation(shift.destLocation)
    elseif shift.destFacId then
      api.routeToLocation({ type = "facilityParkingspot", facId = shift.destFacId, psPath = shift.destPsPath })
    elseif cs and cs.setBestRoute then
      cs.setBestRoute(true)
    end
  end

  -- Follows the vehicle task list first; the destination is the fallback when no task routes.
  local function routeToNextTaskOrDestination(shift, cs)
    local tasks = overhaul_career_logistics_vehicleTasks
    local routed = tasks and tasks.navigateToNextTask()
    if not routed then
      routeToDestination(shift, cs)
    end
  end

  local function routeMaterialContract(shift, cs)
    local active = shared.materials() and shared.materials().getActiveContract()
    if active and (tonumber(active.inTransitAmount) or 0) > 0 and cs and cs.setMaterialContractDestinationRoute then
      if cs.setMaterialContractDestinationRoute(false) then
        api.refreshDeliveryPois()
        return
      end
    end
    if cs and cs.setMaterialContractPickupRoute and cs.setMaterialContractPickupRoute(false) then
      api.refreshDeliveryPois()
      return
    end
    if api.routeToLocation(shift.originLocation) then
      api.refreshDeliveryPois()
    end
  end

  local function routeTrailerDelivery(shift, cs)
    if shift.phase == "return" and shift.returnNeedsPickup and not inputs.parcelLoading.assignedReturnCargoInVehicle(shift) then
      if not api.routeToReturnPickup() and shift.returnPickupFacId then
        api.routeToLocation({ type = "facilityParkingspot", facId = shift.returnPickupFacId })
      end
      api.refreshDeliveryPois()
      return
    end
    local tasks = overhaul_career_logistics_vehicleTasks
    if tasks then
      tasks.navigateToNextTask()
    elseif cs and cs.setBestRoute then
      cs.setBestRoute(true)
    end
    api.refreshDeliveryPois()
  end

  local function routeBundleRepoLeg(shift, cs)
    if not equipment.playerInIssuedCompanyTruck() then
      equipment.routeToCompanyTruck()
    elseif shift.returnNeedsPickup and not inputs.parcelLoading.assignedReturnCargoInVehicle(shift) then
      api.trySpawnAssignedReturnVehicle()
      if not api.routeToReturnPickup() and shift.returnPickupFacId then
        api.routeToLocation({ type = "facilityParkingspot", facId = shift.returnPickupFacId })
      end
    else
      routeToNextTaskOrDestination(shift, cs)
    end
  end

  -- The bundle's car is delivered first; the repo leg follows once the flatbed is in hand.
  local function routeBundleShift(shift, cs)
    local a = shift.assignments
    if a and a.vehicle and not a.vehicle.complete then
      routeToNextTaskOrDestination(shift, cs)
    elseif a and not a.repo.complete then
      routeBundleRepoLeg(shift, cs)
    end
    api.refreshDeliveryPois()
  end

  local function routeVehicleDelivery(shift, cs)
    if shift.phase == "return" and shift.returnNeedsPickup
        and not inputs.parcelLoading.assignedReturnCargoInVehicle(shift) then
      api.trySpawnAssignedReturnVehicle()
      if not api.routeToReturnPickup() and shift.returnPickupFacId then
        api.routeToLocation({type = "facilityParkingspot", facId = shift.returnPickupFacId})
      end
      api.refreshDeliveryPois()
      return
    end
    if inputs.dropOff.isDistributorHaulShift(shift) and (shift.phase == "return" or shift.awaitingLoopChoice) then
      api.routeToYard()
      api.refreshDeliveryPois()
      return
    end
    local tasks = overhaul_career_logistics_vehicleTasks
    local routed = tasks and tasks.navigateToNextTask()
    if inputs.dropOff.isDistributorHaulShift(shift) then
      api.refreshDeliveryPois()
      return
    end
    if not routed then
      routeToDestination(shift, cs)
    end
    api.refreshDeliveryPois()
  end

  -- Dispatches on the kind policy; true when a kind phase took the step.
  local function routeByKind(shift, cs)
    local policy = shared.kindPolicy(shift.jobKind)
    if policy.materialContract then
      routeMaterialContract(shift, cs)
      return true
    end
    if policy.trailerDelivery then
      routeTrailerDelivery(shift, cs)
      return true
    end
    if inputs.dropOff.isBundleShift(shift) then
      routeBundleShift(shift, cs)
      return true
    end
    if policy.vehicleDelivery then
      routeVehicleDelivery(shift, cs)
      return true
    end
    if policy.repossession then
      inputs.backhaul.tryStartEmploymentRepo()
      api.refreshDeliveryPois()
      return true
    end
    return false
  end

  -- Parcels left for a remote pickup route there; true when that took the step.
  local function routeRemoteParcelPickup(shift)
    local needsPickup = shift.phase == "return" and shift.returnNeedsPickup or shift.needsRemotePickup
    if not (shared.kindPolicy(shift.jobKind).parcels and needsPickup) then return false end
    if inputs.parcelLoading.assignedReturnCargoInVehicle(shift)
        and not inputs.parcelLoading.parcelPickupPendingAtOrigin(shift) then
      shift.needsRemotePickup = nil
      shift.returnNeedsPickup = nil
      return false
    end
    if shift.originLocation and api.routeToLocation(shift.originLocation) then
      api.refreshDeliveryPois()
      return true
    end
    if shift.pickupFacId then
      api.routeToLocation({ type = "facilityParkingspot", facId = shift.pickupFacId })
      api.refreshDeliveryPois()
      return true
    end
    return false
  end

  -- Parcel strings follow the locked stop order (nearest-neighbor, planned once at load). Do not use setBestRoute here: it pins nearest cargo dest and desyncs the tasklist.
  local function routeStringStop(shift)
    if not (shift.stringMode and shift.stops and shift.phase == "outbound") then return false end
    if shift.destLocation and api.routeToLocation(shift.destLocation) then
      api.refreshDeliveryPois()
      return true
    end
    if shift.destFacId then
      api.routeToLocation({ type = "facilityParkingspot", facId = shift.destFacId, psPath = shift.destPsPath })
      api.refreshDeliveryPois()
      return true
    end
    return false
  end

  -- Parcel (and similar): prefer cargo-screen best route, then hard dest fallback. A no-op setBestRoute is not success, or the player is left at the yard inspect spot.
  local function routeCargoFallback(shift, cs)
    if cs and cs.setBestRoute and cs.setBestRoute(true) then
      api.refreshDeliveryPois()
      return
    end
    if shift.destLocation and api.routeToLocation(shift.destLocation) then
      api.refreshDeliveryPois()
      return
    end
    if shift.destFacId then
      api.routeToLocation({ type = "facilityParkingspot", facId = shift.destFacId, psPath = shift.destPsPath })
    end
    api.refreshDeliveryPois()
  end

  function api.routeCurrentAssignment()
    local shift = state.shift
    if not shift then return end
    if routeCompanyVehicleEntry(equipment, shift) then return end
    if inputs.accidents.routeAccidentRecovery and inputs.accidents.routeAccidentRecovery() then
      return
    end
    local cs = shared.cargoScreen()
    if routeByKind(shift, cs) then return end
    if routeRemoteParcelPickup(shift) then return end
    if routeStringStop(shift) then return end
    routeCargoFallback(shift, cs)
  end
end

-- Yard arrival ------------------------------------------------------------------------------------

local function addYardArrivalApi(api, inputs)
  local projections, shared, state = inputs.projections, inputs.shared, inputs.state

  -- Settle timers wait for the vehicle to stop so a drive-through does not open screens early.

  -- True when the player is close to any spot of the home yard, or the shift's origin yard.
  local function playerAtHomeYardStall()
    if api.playerNearHomeYard(YARD_AUTO_OPEN_DIST) then return true end
    local facId = (state.shift and state.shift.originFacId) or state.homeFacId
    local gen = shared.generator()
    local fac = facId and gen and gen.getFacilityById(facId)
    if not fac then return false end
    local function anySpot(spots)
      for _, spot in ipairs(spots or {}) do
        local path = (spot.getPath and spot:getPath()) or spot.psPath
        if path and api.playerNearLocation({ type = "facilityParkingspot", facId = facId, psPath = path }, 8) then
          return true
        end
      end
      return false
    end
    return anySpot(fac.inspectSpots) or anySpot(fac.pickUpSpots)
      or anySpot(fac.dropOffSpots) or anySpot(fac.loanerNonTrailerSpots)
  end

  -- True when the player's trailer or vehicle sits inside the assigned drop-off spot.
  local function trailerInAssignedDropOffSpot(facId, psPath)
    local shift = state.shift
    if not (shift and shared.kindPolicy(shift.jobKind).trailerDelivery) then return false end
    local gen = shared.generator()
    local spot = gen and gen.getParkingSpotByPath(psPath)
    local tasks = overhaul_career_logistics_vehicleTasks
    if not (spot and spot.containsPoint and tasks) then
      return false
    end
    local assigned = inputs.dropOff.shiftVehicleOfferIdSet(shift)
    for _, taskData in ipairs(tasks.getVehicleTasks() or {}) do
      local activeTask = taskData.tasks and taskData.tasks[taskData.activeTaskIndex]
      local destination = activeTask and activeTask.destination
      if taskData.offer and assigned[taskData.offer.id]
          and activeTask and activeTask.type == "confirmDropOff" and destination
          and destination.psPath == psPath
          and (not destination.facId or destination.facId == facId)
          and overhaul_vehicles_playerVehicles.isPlayerVehicle(taskData.vehId) then
        local trailer = getObjectByID(taskData.vehId)
        if trailer and spot:containsPoint(trailer:getPosition()) then return true end
      end
    end
    return false
  end

  -- True when the player is at the stop, or the assigned trailer is parked in it.
  local function playerAtAssignedDropOffSpot(facId, psPath)
    if not facId or not psPath then return false end
    if not inputs.dropOff.shouldOpenEmployeeDropOff(facId, psPath) then return false end
    if api.playerNearLocation({ type = "facilityParkingspot", facId = facId, psPath = psPath }, 8) then
      return true
    end
    return trailerInAssignedDropOffSpot(facId, psPath)
  end

  -- Opens the drop-off screen when the player has settled on the spot; true when it opened.
  local function openDropOffWhenSettled(facId, psPath)
    if not playerAtAssignedDropOffSpot(facId, psPath) then return false end
    state.dropOffProximityTimer = 0
    return projections.openDropOffUi(facId, psPath)
  end

  -- The player has been stopped at the yard long enough to count as arrived.
  function api.playerReadyAtYardInspect(dtSim)
    if not playerAtHomeYardStall() then
      inputs.screen.yardArriveSettleTimer = 0
      return false
    end
    local speed = playerVehicleSpeed()
    if speed == nil or speed > YARD_SETTLE_SPEED then
      inputs.screen.yardArriveSettleTimer = 0
      return false
    end
    inputs.screen.yardArriveSettleTimer = inputs.screen.yardArriveSettleTimer + (tonumber(dtSim) or 0)
    return inputs.screen.yardArriveSettleTimer >= YARD_SETTLE_TIME
  end

  function api.willAutoOpenDropOffAt(facId, psPath)
    if not inputs.lifecycle.isOnShift() or inputs.screen.uiOpen or inputs.screen.dropOffOpen or inputs.screen.dropOffEscrowPending then return false end
    if not facId or not psPath then return false end
    if gameplay_walk and gameplay_walk.isWalking() then return false end
    return playerAtAssignedDropOffSpot(facId, psPath)
  end

  function api.isEmployeeDropOffBlocked()
    local shift = state.shift
    if not (shift and shared.kindPolicy(shift.jobKind).parcels) then return false end
    if shift.dropOffDepartureRequired then return true end
    if shift.phase == "outbound" then return shift.needsRemotePickup == true end
    if shift.phase == "return" then return shift.returnNeedsPickup == true end
    return false
  end

  function api.tryOpenNearbyAssignedDropOff(dtSim)
    local shift = state.shift
    if dropOffProximityBlocked(inputs.screen, shift) then
      state.dropOffProximityTimer = 0
      return false
    end
    local speed = playerVehicleSpeed()
    if speed == nil or speed > YARD_SETTLE_SPEED then
      state.dropOffProximityTimer = 0
      return false
    end
    state.dropOffProximityTimer = (state.dropOffProximityTimer or 0) + (tonumber(dtSim) or 0)
    if state.dropOffProximityTimer < YARD_SETTLE_TIME then return false end
    if openDropOffWhenSettled(shift.destFacId, shift.destPsPath) then return true end
    local stop = shift.stops and shift.stops[shift.stopIndex or 1]
    if stop and (stop.destFacId ~= shift.destFacId or stop.destPsPath ~= shift.destPsPath) then
      if openDropOffWhenSettled(stop.destFacId, stop.destPsPath) then return true end
    end
    state.dropOffProximityTimer = YARD_SETTLE_TIME - 0.25
    return false
  end

  function api.offerLoopCompleteChoice(opts)
    opts = opts or {}
    local shift = state.shift
    if not shift then return end
    shift.phase = "loopComplete"
    shift.awaitingLoopChoice = nil
    shift.returnLabel = opts.label or "Assignment complete"
    shift.returnSubtext = opts.subtext or "Take another job or end your day"
    projections.refreshTaskGuidance(true)
    projections.notifyUi()
    ui_message(shift.returnSubtext, 7, "info")
    inputs.persistence.saveEmploymentProgress()
    if inputs.screen.dropOffOpen or inputs.screen.dropOffEscrowPending then
      return
    end
    if not inputs.screen.uiOpen then
      projections.openShiftUi(shift.originFacId or state.homeFacId)
    end
  end

  function api.beginYardReturnForLoopChoice()
    local shift = state.shift
    if not shift then return end
    shift.phase = "return"
    shift.returnIsBackhaul = false
    shift.returnNeedsPickup = nil
    shift.awaitingLoopChoice = true
    shift.returnLabel = "Return to the company yard"
    shift.returnSubtext = "Then choose your next job or end the day"
    api.routeToYard()
    projections.refreshTaskGuidance(true)
    projections.notifyUi()
    ui_message("Assignments complete — head back to the yard.", 7, "info")
  end
end

-- Return pickup -----------------------------------------------------------------------------------

local function addReturnPickupApi(api, inputs)
  local equipment, projections, shared, state = inputs.equipment, inputs.projections, inputs.shared, inputs.state

  -- A return that cannot be spawned falls back to the yard instead of stalling the shift.

  -- Sends the return leg back to the yard, after the return trailer cannot be had.
  local function returnToYardWithoutReturn(shift, notifyFirst)
    if notifyFirst then ui_message("No returns available. Head back to the yard", 7, "info") end
    shift.returnIsBackhaul = nil
    shift.assignedOfferId = nil
    shift.returnNeedsPickup = nil
    shift.returnPickupFacId = nil
    shift.awaitingLoopChoice = true
    shift.returnLabel = "Return the company vehicle to the office"
    shift.returnSubtext = "No returns available. Head back to the yard"
    shift.destFacId = shift.originFacId or state.homeFacId
    shift.destLocation = nil
    shift.destPsPath = nil
    if not notifyFirst then ui_message(shift.returnSubtext, 7, "info") end
    api.routeToYard()
    projections.refreshTaskGuidance(true)
    projections.notifyUi()
  end

  function api.finishUnavailableReturnTrailer(shift, reason)
    if not shift or state.shift ~= shift then return end
    shared.shiftLog("return trailer unavailable", tostring(reason or "unknown"))
    equipment.cancelSpawnBlockedWatch()
    shift._returnTrailerSpawning = nil
    shift._returnTrailerSpawned = nil
    returnToYardWithoutReturn(shift)
  end

  -- Spawn result for the return trailer: occupied stalls block, other failures fall back to the yard.
  local function handleReturnTrailerSpawn(shift, success, reason)
    shift._returnTrailerSpawning = nil
    if not state.shift or state.shift ~= shift then return end
    if success == false then
      if reason == "occupied" then
        equipment.enterSpawnBlockedState({needAssignedOffers = true})
        return
      end
      api.finishUnavailableReturnTrailer(shift, reason)
      return
    end
    shift._returnTrailerSpawned = true
    local tasks = overhaul_career_logistics_vehicleTasks
    if tasks then
      tasks.navigateToNextTask()
    else
      api.routeToReturnPickup()
    end
    projections.refreshTaskGuidance(true)
    projections.notifyUi()
  end

  -- True when the return trailer is already present, so there is nothing to spawn.
  local function returnTrailerAlreadyLoaded(shift)
    if not inputs.parcelLoading.assignedReturnCargoInVehicle(shift) then return false end
    shift.returnNeedsPickup = nil
    shift._returnTrailerSpawned = true
    return true
  end

  -- Spawns the assigned trailer once the player is near its spawn point; true when a spawn was started.
  local function spawnReturnTrailer(shift, mgr, offer)
    local spawnLoc = offer.spawnLocation or offer.origin or shift.originLocation
    if not api.playerNearLocation(spawnLoc, 150) then return false end
    shift._returnTrailerSpawning = true
    offer._employmentReturnTrailer = true
    mgr.spawnAssignedOffer(offer.id, false, function(success, reason)
      handleReturnTrailerSpawn(shift, success, reason)
    end)
    return true
  end

  -- Spawns the assigned return trailer when it is needed, and reports whether it did.
  function api.trySpawnAssignedReturnTrailer()
    local shift = state.shift
    if not shift or not shared.kindPolicy(shift.jobKind).trailerDelivery or shift.phase ~= "return" then return false end
    if shift.spawnBlocked then return false end
    if not shift.returnNeedsPickup or not shift.assignedOfferId then return false end
    if shift._returnTrailerSpawning or shift._returnTrailerSpawned then return false end
    if returnTrailerAlreadyLoaded(shift) then return false end

    local mgr = shared.vehicleOffers()
    local offer = mgr and mgr.getOfferById and mgr.getOfferById(shift.assignedOfferId)
    if not offer then
      shared.shiftLog("return trailer unavailable", "missingOffer")
      returnToYardWithoutReturn(shift, true)
      return false
    end
    if offer.spawned then
      shift._returnTrailerSpawned = true
      local tasks = overhaul_career_logistics_vehicleTasks
      if tasks then
        tasks.navigateToNextTask()
      end
      return true
    end
    return spawnReturnTrailer(shift, mgr, offer)
  end

  -- The offer's spawn point, or the car's live position once it has been spawned.
  local function offerPickupLocation(shift, loc)
    local mgr = shared.vehicleOffers()
    local offer = mgr and mgr.getOfferById and mgr.getOfferById(shift.assignedOfferId)
    if offer and (offer.spawnLocation or offer.origin) then
      loc = offer.spawnLocation or offer.origin
      shift.originLocation = loc
      local veh = offer.vehicle and offer.vehicle.vehId and getObjectByID(offer.vehicle.vehId)
      if veh then loc = {type = "coordinates", pos = veh:getPosition()} end
    end
    return loc
  end

  -- The pickup facility's first spot, or the bare facility when it has no path.
  local function facilityPickupLocation(shift)
    local gen = shared.generator()
    local fac = gen and gen.getFacilityById(shift.returnPickupFacId)
    local spot = fac and facilitySpot(fac)
    local path = spot and ((spot.getPath and spot:getPath()) or spot.psPath)
    if path then
      return { type = "facilityParkingspot", facId = shift.returnPickupFacId, psPath = path }
    end
    return { type = "facilityParkingspot", facId = shift.returnPickupFacId }
  end

  function api.routeToReturnPickup()
    local shift = state.shift
    if not shift then return false end
    local loc = shift.originLocation
    if shift.assignedOfferId then
      loc = offerPickupLocation(shift, loc)
    end
    if not loc and shift.returnPickupFacId then
      loc = facilityPickupLocation(shift)
    end
    if not loc or not api.routeToLocation(loc) then return false end
    api.refreshDeliveryPois()
    return true
  end
end

-- Backhaul return ---------------------------------------------------------------------------------

local function addBackhaulReturnApi(api, inputs)
  local equipment, projections, shared, state = inputs.equipment, inputs.projections, inputs.shared, inputs.state

  -- Backhaul offers are checked against the issued rollback before one is assigned.

  -- Spawn result for a return vehicle: occupied stalls block, failures try the next nearby offer.
  local function handleReturnVehicleSpawn(shift, offerId, pickupFacId, success, reason)
    if state.shift ~= shift then return end
    shift._returnVehicleSpawning = nil
    if success == false then
      if reason == "occupied" then
        equipment.enterSpawnBlockedState({needAssignedOffers = true})
        return
      end
      shift.returnVehicleAttemptedOfferIds = shift.returnVehicleAttemptedOfferIds or {}
      shift.returnVehicleAttemptedOfferIds[offerId] = true
      ui_message("Assigned vehicle unavailable. Dispatch is checking the next nearest delivery.", 6, "info")
      inputs.backhaul.assignReturnLoad(pickupFacId, { retryVehicle = true })
      return
    end
    shift._returnVehicleSpawned = true
    if shift.spawnBlocked and not equipment.spawnBlockedNeedsCompanyLoaner(shift)
        and not equipment.spawnBlockedNeedsAssignedOffers(shift) then
      equipment.clearSpawnBlockedState(true)
    end
    api.routeCurrentAssignment()
    projections.refreshTaskGuidance(true)
    projections.notifyUi()
  end

  -- True when a return is due: a vehicle delivery returning to the yard, or a bundle haul backhaul pending.
  local function returnVehicleDue(shift)
    local vehicleReturn = shared.kindPolicy(shift.jobKind).vehicleDelivery and shift.phase == "return"
    local bundleReturn = inputs.dropOff.isBundleHaulBackhaulPending(shift)
    return vehicleReturn or bundleReturn
  end

  -- Starts the spawn of the assigned return vehicle; true when a spawn was started.
  local function spawnAssignedReturnVehicle(shift, mgr, offer)
    local spawnLoc = offer.spawnLocation or offer.origin or shift.originLocation
    if not api.playerNearLocation(spawnLoc, 150) then return false end
    if not (mgr and mgr.spawnAssignedOffer) then return false end

    shift._returnVehicleSpawning = true
    local offerId = offer.id
    local pickupFacId = shift.returnPickupFacId
    mgr.spawnAssignedOffer(offerId, false, function(success, reason)
      handleReturnVehicleSpawn(shift, offerId, pickupFacId, success, reason)
    end)
    return true
  end

  -- Spawns the assigned return vehicle when it is due; true when a spawn or reassignment was started.
  function api.trySpawnAssignedReturnVehicle()
    local shift = state.shift
    if not shift then return false end
    if shift.spawnBlocked then return false end
    if not returnVehicleDue(shift) then return false end
    if not shift.returnNeedsPickup or not shift.assignedOfferId then return false end
    if shift._returnVehicleSpawning or shift._returnVehicleSpawned then return false end
    if inputs.parcelLoading.assignedReturnCargoInVehicle(shift) then
      shift.returnNeedsPickup = nil
      shift._returnVehicleSpawned = true
      return false
    end

    local mgr = shared.vehicleOffers()
    local offer = mgr and mgr.getOfferById and mgr.getOfferById(shift.assignedOfferId)
    if not offer then
      shift.returnVehicleAttemptedOfferIds = shift.returnVehicleAttemptedOfferIds or {}
      shift.returnVehicleAttemptedOfferIds[shift.assignedOfferId] = true
      return inputs.backhaul.assignReturnLoad(shift.returnPickupFacId, { retryVehicle = true })
    end
    return spawnAssignedReturnVehicle(shift, mgr, offer)
  end

  function api.vehicleOfferFitsIssuedRollback(offer)
    if not offer then return false end
    local caps = shared.loanerCapabilities()
    local fac = inputs.backhaul.getEmployerFacility()
    local useRollback, requireTSeries = inputs.dispatch.vehicleOfferRollbackPolicy(offer, fac, caps)
    if not useRollback then return false end
    if requireTSeries then
      return equipment.companyInventoryHasRepoTruck(true)
    end
    return true
  end

  function api.beginCompanyVehiclePickupRoute()
    if inputs.runtime.nextAssignmentTransition then
      inputs.runtime.nextAssignmentTransition.equipmentShift = state.shift
      return true
    end
    return equipment.beginCompanyVehiclePickupRoute()
  end

  -- The flatbed is already assigned for a return: spawn the vehicle or get the player into the truck.
  local function beginFlatbedReturn()
    if inputs.screen.dropOffOpen and not projections.maybeKeepDropOffOpenForProgress() then
      projections.closeDropOffUi()
    end
    if equipment.playerInIssuedCompanyTruck() then
      api.trySpawnAssignedReturnVehicle()
      ui_message("Flatbed assignment ready — follow the route to the pickup.", 7, "info")
    else
      equipment.routeToCompanyTruck()
      ui_message("Get in the company flatbed to start your car haul assignment.", 7, "info")
    end
    projections.refreshTaskGuidance(true)
    projections.notifyUi()
  end

  -- The nearest backhaul offer that fits the issued rollback, skipping any that do not.
  local function pickFittingBackhaulOffer(shift, fromFacId, excluded)
    local offer = inputs.dispatch.pickHaulBackhaulVehicleOffer(fromFacId, excluded)
    while offer and not api.vehicleOfferFitsIssuedRollback(offer) do
      excluded[offer.id] = true
      shift.returnVehicleAttemptedOfferIds[offer.id] = true
      offer = inputs.dispatch.pickHaulBackhaulVehicleOffer(fromFacId, excluded)
    end
    return offer
  end

  -- Keeps the flatbed route pinned once the job system has settled the new leg.
  local function pinFlatbedRoute()
    if not inputs.lifecycle.isOnShift() or not inputs.M.isBundleFlatbedPending() then return end
    inputs.M.reassertBundleFlatbedRoute()
    projections.refreshTaskGuidance(true)
  end

  -- Records the chosen offer on the repo leg and routes the player to the flatbed.
  local function assignRepoLegOffer(shift, a, offer, fromFacId)
    inputs.backhaul.assignVehicleBackhaulOffer(offer, fromFacId)
    a.repo.offerId = offer.id
    a.repo.complete = false
    local pickupName = inputs.parcelLoading.describeFacilityName(shift.returnPickupFacId)
    a.repo.label = string.format("Pickup at %s — haul back to the yard", pickupName)
    a.repo.subtext = offer.name or "Company rollback"
    if equipment.playerInIssuedCompanyTruck() then
      ui_message("Flatbed assignment ready — follow the route to the pickup.", 7, "info")
    else
      equipment.routeToCompanyTruck()
      ui_message("Get in the company flatbed to start your car haul assignment.", 7, "info")
    end
    core_jobsystem.create(function(job)
      job.sleep(0)
      pinFlatbedRoute()
    end)
    projections.refreshTaskGuidance(true)
    projections.notifyUi()
  end

  function api.beginBundleRepoLeg()
    local shift = state.shift
    if not inputs.dropOff.isBundleShift(shift) then return end
    local a = shift.assignments
    if not a or not a.repo or a.repo.complete then
      inputs.dropOff.maybeCompleteBundleShift()
      return
    end
    inputs.settlement.cancelEmploymentRepoJob()
    a.repo.repoPendingStart = nil
    if shift.returnIsBackhaul and shift.assignedOfferId then
      beginFlatbedReturn()
      return
    end

    rescanReturnOffersOnce(shared, shift)
    local excluded = returnOfferExclusions(inputs.endDay, shift)
    local fromFacId = shift.destFacId or shift.originFacId or state.homeFacId
    local offer = pickFittingBackhaulOffer(shift, fromFacId, excluded)
    if not offer then
      completeRepoLegWithoutVehicle(inputs.dropOff, a)
      return
    end

    if inputs.screen.dropOffOpen then
      projections.closeDropOffUi()
    end
    assignRepoLegOffer(shift, a, offer, fromFacId)
  end
end

-- Assignment activation ---------------------------------------------------------------------------

local function addActivationGuardApi(api, inputs)
  local equipment, projections, shared, state = inputs.equipment, inputs.projections, inputs.shared, inputs.state

  -- Spawn callbacks check that the shift is still current before acting on it.

  -- A return vehicle that cannot be spawned sends the player back to the yard instead of stalling.
  local function returnVehicleUnavailable(shift)
    shift.returnIsBackhaul = nil
    shift.assignedOfferId = nil
    shift.returnNeedsPickup = nil
    shift.returnPickupFacId = nil
    shift.awaitingLoopChoice = true
    shift.returnLabel = "Return to the company yard"
    shift.returnSubtext = "No return vehicle available — head back to the yard"
    shift.destFacId = shift.originFacId or state.homeFacId
    shift.destLocation = nil
    shift.destPsPath = nil
    ui_message(shift.returnSubtext, 7, "info")
    api.routeToYard()
    projections.refreshTaskGuidance(true)
    projections.notifyUi()
  end

  -- Routes a failed vehicle spawn to the right recovery for the shift's kind and phase.
  local function handleSpawnFailure(shift, failReason)
    if failReason == "occupied" and shift then
      equipment.enterSpawnBlockedState({
        needCompanyLoaner = equipment.spawnBlockedNeedsCompanyLoaner(shift),
        needAssignedOffers = true,
      })
      return
    end
    if shift and shared.kindPolicy(shift.jobKind).trailerDelivery and shift.phase == "return" and shift.returnIsBackhaul then
      api.finishUnavailableReturnTrailer(shift, failReason)
      return
    end
    if shift and shared.kindPolicy(shift.jobKind).vehicleDelivery and shift.phase == "return" and shift.returnIsBackhaul then
      returnVehicleUnavailable(shift)
      return
    end
    api.handleAssignmentStartFailure("Could not spawn the assigned vehicle.")
  end

  -- True when a spawn-blocked shift still waits on a loaner or an assigned offer.
  local function spawnStillBlocked(shift)
    return equipment.spawnBlockedNeedsCompanyLoaner(shift) or equipment.spawnBlockedNeedsAssignedOffers(shift)
  end

  -- A failed start releases its parcels' bay reservations, so no pickup stays staged for a dropped job.
  local function releaseAssignedPickups(shift)
    local parcelMgr = shift and shift.assignedCargoIds and shared.parcelManager()
    if not (parcelMgr and parcelMgr.clearTransientMoveForCargo) then return end
    for _, cargoId in ipairs(shift.assignedCargoIds) do
      parcelMgr.clearTransientMoveForCargo(cargoId)
    end
  end

  function api.handleMissingCompanySpawn(reason, opts)
    opts = opts or {}
    local batch = overhaul_career_logistics_loanerVehicles.consumeLastSpawnBatchResult()
    if batch and batch.occupiedBlocked and state.shift then
      equipment.enterSpawnBlockedState({
        needCompanyLoaner = true,
        needAssignedOffers = opts.needAssignedOffers and true or false,
      })
      projections.notifyUi()
      projections.closeShiftUi()
      return true
    end
    api.handleAssignmentStartFailure(reason)
    return false
  end

  function api.handleAssignmentStartFailure(reason, failedShift)
    failedShift = failedShift or state.shift
    equipment.cancelSpawnBlockedWatch()
    shared.shiftLog("assignment start failed", reason)
    releaseAssignedPickups(state.shift)
    if shared.general() and shared.general().isDeliveryModeActive() then
      shared.general().exitDeliveryMode()
    end
    shared.emptyShift(true)
    projections.closeShiftUi()
    if inputs.backhaul.retryFailedAssignment(failedShift) then return true end
    inputs.assignment.finishNextAssignmentTransition()
    -- Without a retry nothing is left to drive to, so the route and the facility prompts go too.
    clearRoute()
    api.refreshDeliveryPois()
    ui_message((reason or "Could not start the assignment.") .. " Clock in again to try another job.", 8, "warning")
    projections.notifyUi()
    return false
  end

  function api.markShiftStartPresentationReady()
    if not inputs.screen.shiftStartPresentationPending or not inputs.screen.uiOpen then return false end
    inputs.screen.shiftStartPresentationPending = false
    inputs.screen.shiftStartPresentationReady = true
    return true
  end

  function api.handleVehicleSpawnResult(success, failReason)
    local shift = state.shift
    if shift and shift.spawnBlocked then
      shift.spawnBlocked.retryInFlight = nil
    end
    if success == false then
      handleSpawnFailure(shift, failReason)
      return
    end
    if shift and shift.spawnBlocked then
      if spawnStillBlocked(shift) then return end
      equipment.clearSpawnBlockedState(true)
    end
    if api.markShiftStartPresentationReady() then projections.notifyUi() end
    -- Defer one tick so addVehicleTask has registered before we navigate.
    local isCurrent = projections.makeAssignmentGuard()
    local function apply()
      if not isCurrent() or not inputs.lifecycle.isOnShift() then return end
      api.routeCurrentAssignment()
      projections.refreshActiveTaskGuidance()
      inputs.assignment.markNextAssignmentReady(shift)
    end
    core_jobsystem.create(function(job)
      job.sleep(0)
      apply()
    end)
  end
end

local function addActivationWorkApi(api, inputs)
  local equipment, projections, shared, state = inputs.equipment, inputs.projections, inputs.shared, inputs.state

  -- Parcel work is either staged for a remote pickup or bound to the issued truck.
  local function activateParcelWork(shift)
    local parcelMgr = shared.parcelManager()
    local hasCargo = false
    for _, cargoId in ipairs(shift.assignedCargoIds or {}) do
      if parcelMgr and parcelMgr.getCargoById(cargoId) then
        hasCargo = true
        break
      end
    end
    if not hasCargo then
      api.handleAssignmentStartFailure("The assigned parcels are no longer available.")
      return
    end
    -- Parcels waiting at a dock other than the facility's inspect spot are fetched from that dock before loading.
    local pickup = shift.originLocation
    if pickup and pickup.type == "facilityParkingspot"
        and not inputs.parcelLoading.isInspectProviderSpot(pickup.facId, pickup.psPath) then
      shift.needsRemotePickup = true
    end
    if shift.needsRemotePickup then
      inputs.parcelLoading.stageAssignedReturnPickup()
      if shift.originLocation and api.routeToLocation(shift.originLocation) then
        api.refreshDeliveryPois()
      else
        api.routeCurrentAssignment()
      end
      projections.refreshTaskGuidance(true)
      inputs.assignment.markNextAssignmentReady(shift)
      return
    end
    inputs.parcelLoading.bindAssignedCargoToIssuedTruck()
  end

  local function activateMaterialWork(shift)
    local mgr = shared.materials()
    if not (shift.assignedContractId and mgr and mgr.acceptAssignedOffer
        and mgr.acceptAssignedOffer(shift.assignedContractId)) then
      api.handleAssignmentStartFailure("The assigned material contract is no longer available.")
      return
    end
    api.routeCurrentAssignment()
    inputs.assignment.markNextAssignmentReady(shift)
  end

  -- Work that needs no spawned equipment: a repo truck, or a failure when the offer is gone.
  local function activateVehicleWork(shift)
    if shared.kindPolicy(shift.jobKind).repossession then
      shift.repoPendingStart = true
      inputs.backhaul.tryStartEmploymentRepo()
      projections.refreshTaskGuidance(true)
      return
    end
    if shared.kindPolicy(shift.jobKind).trailerDelivery or shared.kindPolicy(shift.jobKind).vehicleDelivery
        or inputs.dropOff.isBundleShift(shift) then
      api.handleAssignmentStartFailure("The assigned vehicle offer is no longer available.")
      return
    end
    api.routeCurrentAssignment()
  end

  function api.activateAssignedWork(_job)
    local shift = state.shift
    if not shift then return end
    local isCurrent = projections.makeAssignmentGuard()
    local function onSpawned(success, failReason)
      if isCurrent() then api.handleVehicleSpawnResult(success, failReason) end
    end
    if shared.kindPolicy(shift.jobKind).parcels then
      activateParcelWork(shift)
      return
    end
    if shared.kindPolicy(shift.jobKind).materialContract then
      activateMaterialWork(shift)
      return
    end
    if equipment.spawnAssignedWork(onSpawned) then return end
    activateVehicleWork(shift)
  end

  -- Car jockey spawnOffer uses stepHandler. Repo truck spawnAllOffers finishes by calling us from its completion step; starting a nested sequence there skips the first spawn step. Defer one tick (same pattern as loanerVehicles).
  function api.activateBundleShiftWork(job)
    local isCurrent = projections.makeAssignmentGuard()
    if shared.general() then
      shared.general().startDeliveryMode()
    end
    local function run()
      if not isCurrent() or not inputs.dropOff.isBundleShift(state.shift) then return end
      api.activateAssignedWork(job)
      projections.refreshTaskGuidance(true)
      projections.notifyUi()
    end
    shared.shiftLog("activateBundleShiftWork", "deferring car jockey spawn one tick")
    core_jobsystem.create(function(jobsys)
      jobsys.sleep(0)
      run()
    end)
  end
end

-- Constructor -------------------------------------------------------------------------------------

function part.new(inputs)
  local api = inputs.api or {}

  addNavigationApi(api, inputs)
  addAssignmentRouteApi(api, inputs)
  addYardArrivalApi(api, inputs)
  addReturnPickupApi(api, inputs)
  addBackhaulReturnApi(api, inputs)
  addActivationGuardApi(api, inputs)
  addActivationWorkApi(api, inputs)
  return api
end

return part
