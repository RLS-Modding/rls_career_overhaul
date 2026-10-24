-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding

-- Cargo-screen navigation: entering and leaving the screen, the big map, the best route and route previews.
-- Owned by career/logistics/cargoScreen.lua, which builds this part with part.new(inputs).
-- Part of the Overhaul fork of stock `lua/ge/extensions/career/modules/delivery/cargoScreen.lua`.
--
-- Map, in reading order:
--   entering: enterCargoOverviewScreen dispatches to the owner of the facility work; enterMyCargo
--   big map: mapKeyWantsNormalMap, toggleBigMapWrapper, setBigMapPanEnabled
--   leaving: exitCargoOverviewScreen and onCargoOverviewRouteLeave
--   routes: setBestRoute, its target collection and the multi-stop route; showRoutePreview and the preview helpers
--   markers: deliveryMarkerSelected, highlightCargoInPoi, setVisibleIdsForBigMap
--   events: onCargoPickedUp, onDeactivateBigMapCallback, onOverhaulDeliveryRewardsPopupClosed

local part = {}

-- Built once per cargo screen load; the big-map patch id and route planner live in this closure.
function part.new(inputs)
  local ext, screen = inputs.ext, inputs.screen
  local cardsById = inputs.cardsById

  -- Entering and exiting the screen -----------------------------------------------------------------
  -- Called by activity accept or from the career menu to enter the cargo screen. Compatibility entry for parking prompts and older UI links. Never reopen the legacy cargo/loaner board; dispatch to the owner of this facility's work.
  local function enterCargoOverviewScreen(facilityId, parkingSpotPath)
    local facility = facilityId and ext.generator and ext.generator.getFacilityById(facilityId)
    local organization = facility and facility.associatedOrganization and overhaul_world_organizations.getOrganization(facility.associatedOrganization)
    local emp = overhaul_career_work_employment
    local service = require('overhaul/lib/logistics/facilityRole').resolve(facility, organization)
    if service or (facilityId and emp.canOpenFacilityShiftUi(facilityId)) then
      if not emp.tryOpenFacilityShiftUi(facilityId) then
        ui_message('Service dispatch is unavailable. Close this menu and try again.', 6, 'warning')
        guihooks.trigger('ChangeState', {state='play'})
      end
      return
    end
    if facilityId and emp.isEmployed() then
      -- A different employer's yard cannot open the independent board.
      if not (emp.openShiftUi()) then guihooks.trigger('ChangeState', {state='play'}) end
      return
    end
    if require('overhaul/lib/logistics/brokerFacilityRouting').isFoodPickup(facility) then
      guihooks.trigger('ChangeState', {state='phone-beam-eats'})
      return
    end
    if facility and not require('overhaul/lib/logistics/brokerFacilityRouting').shouldOpen(facility, organization, parkingSpotPath) then
      for _,generator in ipairs(facility.logisticGenerators or {}) do
        if generator.type=='vehOfferProvider' then
          guihooks.trigger('ChangeState', {state='phone-vehicle-transfer'})
          return
        end
      end
      ui_message('No independent freight is offered at this parking spot.', 6, 'info')
      guihooks.trigger('ChangeState', {state='play'})
      return
    end
    if facilityId and not facility then
      ui_message('This work location is no longer available.', 6, 'warning')
      guihooks.trigger('ChangeState', {state='play'})
      return
    end
    local commercial = facilityId and overhaul_career_logistics_broker.isAtLoanerFacility(facilityId) or false
    overhaul_career_logistics_broker.setOpenContext(facilityId, commercial, not facilityId and 'jobs' or nil)
    guihooks.trigger('ChangeState', {state='phone-logistics'})
  end

  local function companyShiftWantsNormalMap()
    local emp = overhaul_career_work_employment
    return emp and ((emp.isOnShift()) or (emp.isEmployed())) or false
  end

  local function mapKeyWantsNormalMap()
    if companyShiftWantsNormalMap() then return true end
    local general = overhaul_career_logistics_general
    return general and general.isDeliveryModeActive() or false
  end

  local function openNormalCareerBigMap(options)
    options = options or {}
    freeroam_bigMapMode.enterBigMap({
      instant = options.instant ~= false,
      ignoreUiStateChange = false,
      routeTarget = options.routeTarget,
    })
  end

  local function enterMyCargo()
    if companyShiftWantsNormalMap() then
      openNormalCareerBigMap({instant = true})
      return
    end
    enterCargoOverviewScreen()
  end

  local MAP_PATCH_ID = "cargoScreenBigMapToggle"

  -- Big map -----------------------------------------------------------------------------------------

  local function toggleBigMapWrapper(originalToggle)
    if type(originalToggle) ~= "function" then return end
    return function()
      if mapKeyWantsNormalMap()
        and not freeroam_bigMapMode.bigMapActive()
        and not freeroam_bigMapMode.isTransitionActive()
      then
        local currentRoute = ui_router and ui_router.getCurrent and ui_router.getCurrent()
        if currentRoute and currentRoute.resolved then
          local name = currentRoute.resolved.name
          if name ~= "play" and name ~= "pause" then
            log("I", "cargoScreen", "Cannot open bigmap from route: " .. tostring(name))
            return
          end
        end
        if overhaul_integration_services_taxi.isTaxiRideActive() then
          overhaul_integration_services_taxi.onChangeDestinationCalled()
          return
        end
        freeroam_bigMapMode.enterBigMap({ignoreUiStateChange = false})
        return
      end
      return originalToggle()
    end
  end

  local bigMapPanActions = {"bigMapMoveForwardBackward", "bigMapMoveLeftRight"}
  local function setBigMapPanEnabled(enabled)
    core_input_actionFilter.setGroup("cargoScreenBigMapPan", bigMapPanActions)
    core_input_actionFilter.addAction(0, "cargoScreenBigMapPan", not enabled)
    if not enabled then
      -- filtered axis actions no longer report their return to 0
      core_camera.moveForwardBackward(0)
      core_camera.moveLeftRight(0)
    end
  end

  -- Leaving the screen ------------------------------------------------------------------------------
  -- Called whenever the cargo screen is closed for any reason. The phone hand-off never opens the legacy cargo screen.
  local function exitCargoOverviewScreen(facilityId, parkingSpotPath)
    if not screen.cargoOverviewScreenOpen then return end
    screen.cargoOverviewScreenOpen = false
    setBigMapPanEnabled(true)
    screen.cargoOverviewLoanersOnly = false
    screen.cargoOverviewUiReady = false
    screen.cargoOverviewEnterToken = screen.cargoOverviewEnterToken + 1
    screen.cargoDataRequestSerial = screen.cargoDataRequestSerial + 1
    gameplay_rawPois.clear()
    if ext.general and ext.general.requestDeliveryPoiRefresh then
      ext.general.requestDeliveryPoiRefresh(true)
    end
    freeroam_bigMapMode.exitBigMap(true)
    simTimeAuthority.pause(false) -- the career pause menu unpauses too late for the big map to start
    if not inputs.isVehicleSpawnInProgress() and not screen.pendingTransientMoves then
      overhaul_career_logistics_loanerVehicles.unmarkAllForSpawning()
    end
    if not inputs.isVehicleSpawnInProgress() and not screen.pendingTransientMoves then
      ext.general.checkExitDeliveryMode()
    end
  end

  local function isCargoOverviewChildRoute(routeName)
    return type(routeName) == "string" and routeName:find("^overhaul%.cargoOverview%.") ~= nil
  end

  local function onCargoOverviewRouteLeave(context, toRoute, fromRoute, data)
    if not screen.cargoOverviewScreenOpen then return end
    -- do not run full teardown if leaving a cargo child route
    if toRoute and isCargoOverviewChildRoute(toRoute.name) then
      return
    end
    if ext.parcelManager.hasUncommittedTransientMoves() then
      inputs.cancelDeliveryConfiguration()
    end
    exitCargoOverviewScreen()
  end

  -- Route planning ----------------------------------------------------------------------------------

  local routePlanner = require('gameplay/route/route')()

  local function getDistanceBetweenPoints(pos1, pos2)
    routePlanner:setupPath(pos1, pos2)
    return routePlanner.path[1].distToTarget
  end

  local function getClosestNeighbor(sourceId, targetsById, result, onlyClosestTarget)
    local minDist = math.huge
    local minDistTarget
    targetsById[sourceId] = nil
    for _, targetData in pairs(targetsById) do
      local dist = targetData.distances[sourceId]
      if dist < minDist then
        minDistTarget = targetData
        minDist = dist
      end
    end
    table.insert(result, minDistTarget.pos)
    if tableSize(targetsById) <= 1 or onlyClosestTarget then return end
    getClosestNeighbor(minDistTarget.id, targetsById, result)
  end

  -- A loaded contract cargo already routes through the multi-stop route, so only an unloaded one needs a pickup.
  local function hasLoadedMaterialContract(allCargo)
    for _, cargo in ipairs(allCargo) do
      if cargo.data and cargo.data.materialContractId then
        return true
      end
    end
    return false
  end

  -- Guides to the oldest accepted contract with material left to load. Returns true when a route was set.
  local function routeToActiveMaterialPickup(allCargo)
    if hasLoadedMaterialContract(allCargo) then return false end
    for _, active in ipairs(ext.materialContracts and ext.materialContracts.getActiveContracts() or {}) do
      if active.status == "active" and active.origin and (active.loadableAmount or 0) > 0 then
        if inputs.setMaterialContractPickupRoute(active.id, false) then
          freeroam_bigMapMode.resetRoute()
          return true
        end
      end
    end
    return false
  end

  local function clearBestRoute()
    core_groundMarkers.setPath(nil)
    freeroam_bigMapMode.resetRoute()
    return false
  end

  -- The route targets: parking spots keyed by id, plus the player's own position as the start.
  local function addRouteTarget(book, target)
    if not target then return end
    if target.type == "facilityParkingspot" then
      local targetId = string.format("%s-%s", target.facId, target.psPath)
      if not book.byId[targetId] then
        local parkingSpot = ext.generator.getParkingSpotByPath(target.psPath)
        if not parkingSpot then return end
        book.hasTargetable = true
        local targetData = {pos = parkingSpot.pos, location = target, id = targetId}
        local distToPlayer = book.playerPos and getDistanceBetweenPoints(book.playerPos, targetData.pos) or 0
        targetData.distances = {player = distToPlayer}
        book.byId.player.distances[targetId] = distToPlayer
        book.byId[targetId] = targetData
      else
        book.hasTargetable = true
      end
    elseif target.type == "multi" then
      local closest = nil
      local closestDistance = nil
      for _, destination in ipairs(target.destinations or {}) do
        local spot = destination.type == "facilityParkingspot" and ext.generator.getParkingSpotByPath(destination.psPath)
        if spot then
          local distance = book.playerPos and getDistanceBetweenPoints(book.playerPos, spot.pos) or 0
          if not closestDistance or distance < closestDistance then
            closest, closestDistance = destination, distance
          end
        end
      end
      if closest then addRouteTarget(book, closest) end
    end
  end

  -- Adds the stops one cargo item still needs. A park-at-stall clock-out hides the drop-offs it has not reached.
  local function addCargoRouteTargets(book, cargo, emp)
    if emp and emp.isOnShift()
        and emp.shouldShowParcelDropOffPin and not emp.shouldShowParcelDropOffPin(cargo) then
      return
    end
    local routeToDestination = (screen.cargoOverviewScreenOpen and cargo.location.facId == screen.cargoScreenFacId)
      or not cargo._transientMove
    if routeToDestination and cargo.data and cargo.data.materialContractId and ext.materialContracts then
      for _, contract in ipairs(ext.materialContracts.getContractsAcceptingMaterial(cargo.materialType, nil, cargo.data.materialContractId)) do
        addRouteTarget(book, contract.destination)
      end
      return
    end
    local destination = cargo.destination
    local business = overhaul_career_business_passive
    if routeToDestination and business and business.getSupplyRouteDestination then
      local orderedDestination = business.getSupplyRouteDestination(cargo)
      if orderedDestination and ext.generator.getParkingSpotByPath(orderedDestination.psPath) then
        destination = orderedDestination
      end
    end
    addRouteTarget(book, routeToDestination and destination or cargo.location)
  end

  local function collectRouteTargets(allCargo, emp, playerPos)
    local book = {byId = {player = {distances = {}}}, hasTargetable = false, playerPos = playerPos}
    for _, cargo in ipairs(allCargo) do
      addCargoRouteTargets(book, cargo, emp)
    end
    return book
  end

  -- Every pair of stops gets its real distance; the player's own distances were set while adding them.
  local function linkRouteTargetDistances(book)
    for tgtId1, targetData1 in pairs(book.byId) do
      for tgtId2, targetData2 in pairs(book.byId) do
        if tgtId1 ~= tgtId2 and tgtId1 ~= "player" and tgtId2 ~= "player" then
          targetData1.distances[tgtId2] = ext.generator.getDistanceBetweenFacilities(targetData1.location, targetData2.location)
        end
      end
    end
  end

  -- Sets the ground-marker route: the shift's own route first, then material pickups, then vehicle tasks, then cargo.
  local function setBestRoute(onlyClosestTarget)
    local allCargo = overhaul_career_logistics_parcelManager.getAllCargoInVehicles(true)
    local vehicleTasks = overhaul_career_logistics_vehicleTasks.getVehicleTasks()

    -- Park-at-stall clock-out takes priority over leftover cargo routing.
    local emp = overhaul_career_work_employment
    if emp and emp.trySetShiftRoute() then
      return true
    end

    if routeToActiveMaterialPickup(allCargo) then
      return true
    end

    if vehicleTasks and next(vehicleTasks) then
      overhaul_career_logistics_vehicleTasks.navigateToNextTask()
      freeroam_bigMapMode.resetRoute()
      return true
    end

    if tableIsEmpty(allCargo) then
      return clearBestRoute()
    end

    local playerVeh = getPlayerVehicle(0)
    local playerPos = playerVeh and playerVeh:getPosition() or nil
    local book = collectRouteTargets(allCargo, emp, playerPos)
    if not book.hasTargetable then
      return clearBestRoute()
    end

    linkRouteTargetDistances(book)
    local result = {}
    getClosestNeighbor("player", deepcopy(book.byId), result, onlyClosestTarget)
    core_groundMarkers.setPath(result, {clearPathOnReachingTarget = false})
    freeroam_bigMapMode.resetRoute()
    return true
  end

  -- Route events ------------------------------------------------------------------------------------
  -- recalculate route after closing the popup with the rewards
  local function onOverhaulDeliveryRewardsPopupClosed()
    -- recalculate the best route after delivering, because sometimes the the waypoint at the delivery spot doesnt count as "reached" for the groundmarkers and so it will keep pointing to it
    if overhaul_career_logistics_general.getSettings().automaticRoute then
      setBestRoute(true)
    end

    -- tell player they can take a taxi back, and show one-time 0.5 s delayed
    local sequence = {
      ext.step.makeStepWait(0.5),
      ext.step.makeStepReturnTrueFunction(function()
        overhaul_career_guide_tutorialPopups.introPopup("delivery/cargoDelivered")
        if gameplay_walk.isWalking() then
          ui_message(_tr("ui.career.delivery.cargoScreen.takeTaxiHint"),6,"post_delivery","local_taxi")
          overhaul_career_guide_tutorialPopups.introPopup("delivery/postDeliveryTaxi")
        end
        return true
    end)}
    ext.step.startStepSequence(sequence)
  end

  local function onCargoPickedUp(forceRoute)
    local emp = overhaul_career_work_employment
    if emp and emp.clearAwaitingParkIfWorking then
      emp.clearAwaitingParkIfWorking()
    end
    local onCompanyShift = emp and emp.isOnShift()
    if forceRoute == true or onCompanyShift or overhaul_career_logistics_general.getSettings().automaticRoute then
      setBestRoute(true)
    end
  end

  -- Show only the route up until the first destination in gameplay
  local function onDeactivateBigMapCallback()
    if not overhaul_career_logistics_general.isDeliveryModeActive() then return end
    local emp = overhaul_career_work_employment
    local onCompanyShift = emp and emp.isOnShift()
    if onCompanyShift or overhaul_career_logistics_general.getSettings().automaticRoute then
      setBestRoute(true)
    end
  end

  -- Markers -----------------------------------------------------------------------------------------
  -- highlight entries in list
  local function highlightCargoInPoi(poiId)
    if not screen.visibleBigMapIdsToCardIds[poiId] or not poiId then
      guihooks.trigger("sendHighlightedCardIds", {})
      return
    end
    local cardIds = {}
    for _, id in ipairs(freeroam_bigMapMarkers.getIdsFromHoveredPoiId(poiId)) do
      local elem = screen.visibleBigMapIdsToCardIds[id]
      if elem then
        for cardId, _ in pairs(elem.cardIds) do
          cardIds[cardId] = true
        end
      end
    end

    guihooks.trigger("sendHighlightedCardIds", cardIds)
  end

  -- when a marker is clicked, set route there
  local function deliveryMarkerSelected(poiId)
    highlightCargoInPoi(poiId)
    if not screen.visibleBigMapIdsToCardIds[poiId] then return end
    if not ext.general.isAutomaticRouteEnabled() then
      freeroam_bigMapMode.navigateToMission(poiId)
    end
  end

  -- Route previews ----------------------------------------------------------------------------------
  -- when a parcel list entry is hovered, preview the route on bigMap
  local function showRoutePreview(route)
    if not route then freeroam_bigMapMode.clearRoutePreview() return end
    if route.type == "navgraph" then
      local unsimplifiedRoute = {}
      for _, loc in ipairs(route.locations) do
        if loc.type ~= "multi" then
          local pos =  ext.generator.getLocationCoordinates(loc)
          table.insert(unsimplifiedRoute, pos)
        end
      end
      if #unsimplifiedRoute > 1 then
        local routeUtil = require('/lua/ge/extensions/gameplay/route/route')()
        routeUtil:setupPathMulti(unsimplifiedRoute)
        freeroam_bigMapMode.setRoutePreview(routeUtil.path)
      else
        freeroam_bigMapMode.clearRoutePreview()
      end
    else
      freeroam_bigMapMode.clearRoutePreview()
    end
  end

  local function showCargoRoutePreview(cargoId)
    if cargoId == nil then
      freeroam_bigMapMode.clearRoutePreview()
      return
    end
    local cargo = ext.parcelManager.getCargoById(cargoId)
    if not cargo then return end

    if cargo.destination.type == "multi" then
      local route = {}
      local fromPos = ext.generator.getLocationCoordinates(cargo.location)
      for _, dest in ipairs(cargo.destination.destinations) do
        local toPos = ext.generator.getLocationCoordinates(dest)
        table.insert(route, {pos = fromPos})
        table.insert(route, {pos = toPos})
      end
      freeroam_bigMapMode.setRoutePreview(route)
    else
      local fromPos = ext.generator.getLocationCoordinates(cargo.location)
      local toPos = ext.generator.getLocationCoordinates(cargo.destination)
      if fromPos and toPos then
        freeroam_bigMapMode.setRoutePreviewSimple(fromPos, toPos)
      end
    end
  end

  -- when a vehicle offer list entry is hovered, preview route on bigMap
  local function showVehicleOfferRoutePreview(offerId)
    if offerId == nil then
      freeroam_bigMapMode.clearRoutePreview()
      return
    end
    local offer = ext.vehicleOfferManager.getOfferById(offerId)
    if not offer then return end
    local fromPos = ext.generator.getLocationCoordinates(offer.locations[1])
    local toPos = ext.generator.getLocationCoordinates(offer.locations[2])
    if fromPos and toPos then
      freeroam_bigMapMode.setRoutePreviewSimple(fromPos, toPos)
    end
  end

  -- when a facility list entry is hovered, preview the route from the screen's spot to its first stop
  local function showLocationRoutePreview(locationId, asProvider)
    if locationId == nil then
      freeroam_bigMapMode.clearRoutePreview()
      return
    end
    local fromPos = ext.generator.getLocationCoordinates({type="facilityParkingspot",facId = screen.cargoScreenFacId, psPath = screen.cargoScreenPsPath})
    local fac = ext.generator.getFacilityById(locationId)
    if not fac then return end
    local spots = asProvider and fac.pickUpSpots or fac.dropOffSpots
    if not spots or not spots[1] then return end
    local toPos = ext.generator.getLocationCoordinates({type="facilityParkingspot", facId = fac.id, psPath=spots[1]:getPath()})
    if fromPos and toPos then
      freeroam_bigMapMode.setRoutePreviewSimple(fromPos, toPos)
    end
  end

  -- when a cargo list element is clicked, set the bigMap route there
  local function setCargoRoute(cargoId, origin)
    if cargoId == nil then
      return
    end
    local cargo = ext.parcelManager.getCargoById(cargoId)
    if not cargo then return end
    local toPos = ext.generator.getLocationCoordinates(origin and cargo.origin or cargo.destination)
    if toPos then
      freeroam_bigMapMode.setNavFocus(toPos)
    end
  end

  -- Visible markers --------------------------------------------------------------------------------
  -- By default, all cargo locations are active as bigMap markers. This keeps only the relevant ones visible: the destination of loaded and available cargo, and the vehicle offers.
  local function setVisibleIdsForBigMap()
    screen.visibleBigMapIdsToCardIds = {}
    for cardId, card in pairs(cardsById) do
      for bigMapId, _ in pairs(card.bigMapIds or {}) do
        screen.visibleBigMapIdsToCardIds[bigMapId] = screen.visibleBigMapIdsToCardIds[bigMapId] or {cardIds = {}}
        screen.visibleBigMapIdsToCardIds[bigMapId].cardIds[cardId] = true
      end
    end
  end

  return {
    MAP_PATCH_ID = MAP_PATCH_ID,
    deliveryMarkerSelected = deliveryMarkerSelected,
    enterCargoOverviewScreen = enterCargoOverviewScreen,
    enterMyCargo = enterMyCargo,
    exitCargoOverviewScreen = exitCargoOverviewScreen,
    highlightCargoInPoi = highlightCargoInPoi,
    onCargoOverviewRouteLeave = onCargoOverviewRouteLeave,
    onCargoPickedUp = onCargoPickedUp,
    onDeactivateBigMapCallback = onDeactivateBigMapCallback,
    onOverhaulDeliveryRewardsPopupClosed = onOverhaulDeliveryRewardsPopupClosed,
    setBestRoute = setBestRoute,
    setBigMapPanEnabled = setBigMapPanEnabled,
    setCargoRoute = setCargoRoute,
    setVisibleIdsForBigMap = setVisibleIdsForBigMap,
    showCargoRoutePreview = showCargoRoutePreview,
    showLocationRoutePreview = showLocationRoutePreview,
    showRoutePreview = showRoutePreview,
    showVehicleOfferRoutePreview = showVehicleOfferRoutePreview,
    toggleBigMapWrapper = toggleBigMapWrapper,
  }
end

return part
