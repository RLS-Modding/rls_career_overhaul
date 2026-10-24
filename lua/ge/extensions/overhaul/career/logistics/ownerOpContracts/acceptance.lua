-- Contract acceptance. Map: listing, facility bays, hub/car-haul acceptance, native offers, serial spawn, trip staging, delivery hooks.
-- Read serializeContractForList, contractMatchesFacility, listContracts in order.

local part = {}

-- The owner supplies state, catalog and generation APIs, log tag and haul-kind constants; each load captures its own inputs.
function part.new(inputs)
  local api = {}
  local state, catalog, generation = inputs.state, inputs.catalog, inputs.generation
  local logTag, DISTRIBUTOR_LOGISTIC_TYPE, CAR_HAUL_KIND =
    inputs.logTag, inputs.distributorLogisticType, inputs.carHaulKind

  -- Board listing ------------------------------------------------------------------------------------

  local function serializeContractForList(contract)
    local payload = {
      id = contract.id,
      kind = contract.kind,
      title = contract.title,
      summary = contract.summary,
      pay = contract.pay,
      qty = contract.qty,
      trips = contract.trips,
      loadSlots = contract.loadSlots,
      sizeUnit = contract.sizeUnit,
      logisticType = contract.logisticType,
      originFacId = contract.originFacId,
      destFacId = contract.destFacId,
      dispatchFacId = contract.dispatchFacId,
      stringMode = contract.stringMode and true or false,
      stopCount = contract.stopCount or (contract.stops and #contract.stops) or nil,
    }
    if contract.kind == "finkHaul" then
      payload.detailSummary = contract.detailSummary
      payload.destinationCount = contract.destinationCount
      payload.destinations = contract.destinations
      payload.vehicles = {}
      for _, veh in ipairs(contract.vehicles or {}) do
        table.insert(payload.vehicles, catalog.serializeVehicle(veh))
      end
    end
    return payload
  end

  local function contractMatchesFacility(contract, facilityId)
    if not facilityId or facilityId == "" then return true end
    return contract.originFacId == facilityId
      or contract.dispatchFacId == facilityId
      or (contract.kind == CAR_HAUL_KIND and contract.originFacId == facilityId)
  end

  function api.listContracts(facilityId)
    generation.rebuildContracts(false)
    local list = {}
    for _, contract in pairs(state.contracts) do
      if contractMatchesFacility(contract, facilityId) then table.insert(list, serializeContractForList(contract)) end
    end
    table.sort(list, function(a, b) return tostring(a.title) < tostring(b.title) end)
    return list
  end

  -- Access points -----------------------------------------------------------------------------------

  --- Combine parcel hubs and car-haul sources without repeating mixed facilities.
  -- @return Facility IDs for owner-op board discovery.
  function api.getOwnerOpHubFacilityIds()
    local ids = {}
    local seen = {}
    for _, fac in ipairs(catalog.listOwnerOpHubs()) do
      table.insert(ids, fac.id)
      seen[fac.id] = true
    end
    for _, fac in ipairs(catalog.listVehicleDistributors()) do
      if not seen[fac.id] then table.insert(ids, fac.id) end
    end
    return ids
  end

  function api.routeTo(facId, psPath)
    local gen = overhaul_career_logistics_generator
    if not (gen and core_groundMarkers) then return end
    local pos = gen.getLocationCoordinates(catalog.makeLoc(facId, psPath))
    if pos then core_groundMarkers.setPath(pos, { clearPathOnReachingTarget = true }) end
  end

  -- Hub contracts -----------------------------------------------------------------------------------

  function api.acceptBps(contract)
    local nativeMaterial
    if catalog.materialTemplate(contract.logisticType) then
      local materials = overhaul_career_logistics_materialContractManager
      if not materials or not materials.acceptOwnerOpContract then return false, "Material dispatch is unavailable." end
      local order = deepcopy(contract)
      if not order.sizeUnit or order.sizeUnit == "trips" or order.sizeUnit == "slots" then
        local size = catalog.sizeForLogisticType(order.logisticType)
        order.loadSlots = size.loadSlots
        order.qty = size.loadSlots * math.max(1, tonumber(order.trips) or 1)
      end
      order.materialAmountRequired = order.qty
      nativeMaterial = materials.acceptOwnerOpContract(order)
      if not nativeMaterial then return false, "No native material route serves this contract." end
    end
    local firstStop = contract.stringMode and contract.stops and contract.stops[1] or nil
    state.active = {
      id = contract.id,
      kind = contract.kind,
      pay = contract.pay,
      originFacId = contract.originFacId,
      originPsPath = contract.originPsPath,
      destFacId = (firstStop and firstStop.destFacId) or contract.destFacId,
      destPsPath = (firstStop and firstStop.destPsPath) or contract.destPsPath,
      phase = "pickup",
      stringMode = contract.stringMode and true or nil,
      stops = contract.stops,
      stopIndex = contract.stringMode and 1 or nil,
      stopCount = contract.stopCount or (contract.stops and #contract.stops) or nil,
      qty = contract.qty,
      logisticType = contract.logisticType,
      loadSlots = contract.loadSlots,
      tripsRequired = math.max(1, tonumber(contract.trips) or 1),
      tripsCompleted = 0,
      deliveredStops = 0,
      nativeMaterialContractId = nativeMaterial and nativeMaterial.id,
      materialAmountRequired = nativeMaterial and nativeMaterial.totalAmount,
      materialAmountDelivered = nativeMaterial and 0,
    }
    if nativeMaterial then
      state.active.originPsPath, state.active.destPsPath = nativeMaterial.origin.psPath, nativeMaterial.destination.psPath
      state.active.loadSlots = nativeMaterial.standardLoad
      state.active.stringMode, state.active.stops = nil, nil
    end
    api.routeTo(state.active.originFacId, state.active.originPsPath)
    if contract.stringMode then
      ui_message(
        string.format(
          "Parcel string accepted (%d stops). Load matching parcels through the cargo screen over as many trips as needed. Pay on full completion.",
          state.active.stopCount or #(contract.stops or {})
        ),
        8,
        "info"
      )
      return true, "Navigate to hub pickup."
    end
    ui_message(
      "Contract accepted. Collect a matching native load at the marked facility, then complete its delivery.",
      8,
      "info"
    )
    return true, "Navigate to pickup."
  end

  -- Car-haul offers ---------------------------------------------------------------------------------

  -- Brand and model name shown on the offer: the distributor and the car label, refined by the model data.
  local function offerDisplayNames(distributor, veh)
    local brand, name = tostring(distributor and distributor.name or "Distributor"), veh.label or veh.model
    local modelData = core_vehicles.getModel(veh.model)
    if modelData then
      local modelInfo = modelData.model or modelData
      if modelInfo and modelInfo.Brand and modelInfo.Brand ~= "" then brand = modelInfo.Brand end
      local cfg = modelData.configs and modelData.configs[veh.config]
      if cfg and cfg.Name and cfg.Name ~= "" then
        name = cfg.Name
      elseif modelInfo and modelInfo.Name and modelInfo.Name ~= "" then
        name = modelInfo.Name
      end
    end
    return brand, name
  end

  --- Create a native vehicle offer for one broker car and its destination.
  -- Staging uses prefiltered clear bays when supplied, otherwise source bays; unavailable delivery sources produce no native offer.
  local function buildCarHaulOffer(contract, veh, slotIndex, stagingPads)
    local vom = overhaul_career_logistics_vehicleOfferManager
    if not vom then return nil end
    local now = overhaul_career_logistics_general.time() or os.time()
    local originFacId = (state.active and state.active.originFacId) or (contract and contract.originFacId)
    local distributor = catalog.facById(originFacId)
    local pads = stagingPads or catalog.distributorStagingPads(distributor)
    local pad = pads[((slotIndex - 1) % math.max(1, #pads)) + 1] or pads[1]
    local originPs = pad and pad.path or catalog.primaryPsPath(distributor)
    if not originFacId or not originPs then return nil end
    local origin = catalog.makeLoc(originFacId, originPs)
    local dest = catalog.makeLoc(veh.destFacId, veh.destPsPath)
    -- The native manager appends offers and resolves the first matching ID. Persist this counter with the active contract so retries, including after reload, cannot resolve to an earlier failed/expired offer.
    state.active.offerSequence = (tonumber(state.active.offerSequence) or 0) + 1
    local offerId = string.format("carHaulOffer_%s_%s_%d", contract.id, veh.key, state.active.offerSequence)
    local gen = overhaul_career_logistics_generator
    local routeDistance = 0
    if gen then routeDistance = tonumber((gen.getDistanceBetweenFacilities(origin, dest))) or 0 end
    local brand, name = offerDisplayNames(distributor, veh)
    local tpl = require("overhaul/lib/logistics/templates")
    tpl.loadVehicleFilters()
    local filter = tpl.getVehicleFilterById(veh.filterId)
    local offer = {
      id = offerId,
      name = string.format("%s: %s → %s", brand, name, veh.destFacName or veh.destFacId),
      data = {
        type = "vehicle",
        tag = filter and filter.unlockTag or "fleetVeh",
        originalDistance = routeDistance,
        finkContractId = contract.id,
        finkVehicleKey = veh.key,
        logisticsBonusIncluded = veh.logisticsBonusIncluded == true,
      },
      task = {
        type = "vehicleDropOff",
        destination = dest,
        dropOff = dest,
        lookupType = DISTRIBUTOR_LOGISTIC_TYPE,
      },
      locations = { origin, dest },
      origin = origin,
      destination = dest,
      dropOffFacId = veh.destFacId,
      spawnLocation = origin,
      offerExpiresAt = now + (6 * 3600),
      vehicle = {
        model = veh.model,
        config = veh.config,
        filterId = veh.filterId,
        unlockTag = veh.unlockTag or (filter and filter.unlockTag),
        name = name,
        brand = brand,
        mileage = math.random(0, 800),
      },
      rewards = { money = veh.pay or 0 },
    }
    return offer
  end

  -- A failed spawn returns its car to pending and expires the native offer, so the car can be restaged.
  local function failSpawnedOffer(vom, offerIds, index)
    log("W", logTag, "Distributor offer spawn failed at index " .. tostring(index))
    for _, veh in ipairs(state.active.vehicles or {}) do
      if veh.offerId == offerIds[index] then
        veh.status = "pending"
        veh.offerId = nil
        break
      end
    end
    local failed = vom.getOfferById(offerIds[index])
    if failed then failed.offerExpiresAt = 0 end
  end

  -- Ends the staging queue: cars that spawned go to the yard phase; with none, the trip is replanned.
  local function finishSpawnQueue()
    local staged = catalog.countVehiclesByStatus(state.active.vehicles, "staged")
    state.active.phase = staged > 0 and "hauling" or "planTrip"
    state.active.spawning = nil
    state.active.pendingOfferIds = nil
    if staged > 0 then
      ui_message(
        "Cars ready at the pickup yard. Load the marked cars, then deliver to their destinations.",
        8,
        "success"
      )
    else
      ui_message("No cars could be staged. Clear the pickup bays and retry.", 8, "warning")
    end
    local vtasks = overhaul_career_logistics_vehicleTasks
    if vtasks then vtasks.navigateToNextTask() end
    if overhaul_career_logistics_general then overhaul_career_logistics_general.requestDeliveryPoiRefresh(true) end
  end

  --- Spawn queued cars sequentially, returning failed cars to pending for a later retry.
  -- Callbacks ignore an abandoned or replaced active contract. @return Whether the queue could be started.
  function api.spawnQueuedCarHaulOffers()
    if not state.active or state.active.kind ~= "finkHaul" or state.active.phase ~= "staging" then return false end
    if state.active.spawning then return true end
    local vom = overhaul_career_logistics_vehicleOfferManager
    if not vom then
      ui_message("Vehicle delivery system unavailable.", 6, "warning")
      return false
    end
    state.active.spawning = true
    local contractId = state.active.id
    local offerIds = state.active.pendingOfferIds or {}
    local idx = 0
    --- Process the previous spawn result and continue this contract queue.
    -- @param ok Previous result; nil starts the queue and false restores the failed car.
    local function spawnNext(ok)
      if not state.active or state.active.id ~= contractId or state.active.kind ~= CAR_HAUL_KIND then return end
      if ok == false then failSpawnedOffer(vom, offerIds, idx) end
      idx = idx + 1
      local offerId = offerIds[idx]
      if not offerId then
        finishSpawnQueue()
        return
      end
      vom.spawnOffer(offerId, false, spawnNext)
    end
    ui_message(string.format("Staging %d cars at distributor pickup pads...", #offerIds), 5, "info")
    spawnNext()
    return true
  end

  local function cloneActiveVehicles()
    local list = {}
    for _, veh in ipairs(state.active and state.active.vehicles or {}) do
      table.insert(list, catalog.serializeVehicle(veh))
    end
    return list
  end

  function api.getActiveCarHaulSnapshot()
    if not state.active or state.active.kind ~= "finkHaul" then return nil end
    local vehicles = cloneActiveVehicles()
    return {
      id = state.active.id,
      kind = state.active.kind,
      phase = state.active.phase,
      pay = state.active.pay,
      qty = #(state.active.vehicles or {}),
      pendingCount = catalog.countVehiclesByStatus(state.active.vehicles, "pending"),
      stagedCount = catalog.countVehiclesByStatus(state.active.vehicles, "staged"),
      deliveredCount = catalog.countVehiclesByStatus(state.active.vehicles, "delivered"),
      escrowedMoney = math.floor(tonumber(state.active.escrowedMoney) or 0),
      destinations = catalog.buildDestinationSummary(state.active.vehicles),
      vehicles = vehicles,
      originFacId = state.active.originFacId,
    }
  end

  function api.acceptCarHaul(contract)
    local vehicles = {}
    for _, veh in ipairs(contract.vehicles or {}) do
      table.insert(vehicles, {
        key = veh.key,
        model = veh.model,
        config = veh.config,
        label = veh.label,
        thumbnail = veh.thumbnail,
        filterId = veh.filterId,
        filterName = veh.filterName,
        unlockTag = veh.unlockTag,
        destFacId = veh.destFacId,
        destFacName = veh.destFacName,
        destPsPath = veh.destPsPath,
        pay = veh.pay,
        basePay = veh.basePay,
        logisticsBonusIncluded = veh.logisticsBonusIncluded == true,
        status = "pending",
      })
    end
    if not vehicles[1] then return false, "This contract has no vehicles." end

    local originFacId = contract.originFacId
    local distributor = catalog.facById(originFacId)
    local yardPs = catalog.primaryPsPath(distributor)
      or (catalog.distributorStagingPads(distributor)[1] and catalog.distributorStagingPads(distributor)[1].path)

    state.active = {
      id = contract.id,
      kind = CAR_HAUL_KIND,
      pay = contract.pay,
      vehicles = vehicles,
      originFacId = originFacId,
      originPsPath = yardPs,
      phase = "planTrip",
      escrowedMoney = 0,
      escrowedRewards = {},
    }

    state.contracts[contract.id] = nil
    api.routeTo(originFacId, yardPs)
    overhaul_career_logistics_general.requestDeliveryPoiRefresh(true)
    ui_message("Contract accepted. Open Logistics on your phone to plan each yard trip.", 10, "info")
    return true, "Plan your first trip in the Logistics app."
  end

  -- Trip staging ------------------------------------------------------------------------------------

  -- Picks the cars for this trip. Explicit keys take each pending car once, in the order given; with no keys the trip takes the first pending car.
  local function selectPendingCars(selectedKeys)
    local byKey = {}
    for _, veh in ipairs(state.active.vehicles or {}) do
      byKey[veh.key] = veh
    end

    local selected = {}
    local seen = {}
    if selectedKeys[1] then
      for _, key in ipairs(selectedKeys) do
        local veh = byKey[key]
        if veh and veh.status == "pending" and not seen[key] then
          seen[key] = true
          table.insert(selected, veh)
        end
      end
    else
      for _, veh in ipairs(state.active.vehicles or {}) do
        if veh.status == "pending" then
          table.insert(selected, veh)
          break
        end
      end
    end
    return selected
  end

  -- Pickup bays that have no vehicle parked in them.
  local function clearStagingPads()
    local gen = overhaul_career_logistics_generator
    local pads = {}
    for _, pad in ipairs(catalog.distributorStagingPads(catalog.facById(state.active.originFacId))) do
      local ps = pad.ps or gen.getParkingSpotByPath(pad.path)
      if not (ps and ps.hasAnyVehicles and ps:hasAnyVehicles()) then table.insert(pads, pad) end
    end
    return pads
  end

  -- Creates a native offer for each selected car that fits a clear bay; returns the offer IDs made.
  local function addStagingOffers(selected, pads)
    local vom = overhaul_career_logistics_vehicleOfferManager
    local offerIds = {}
    for i, veh in ipairs(selected) do
      if i > #pads then break end
      local offer = buildCarHaulOffer({ id = state.active.id }, veh, i, pads)
      if offer then
        local broker = overhaul_career_logistics_broker
        offer.brokerId = broker.jobForNative("cars", state.active.id)
        vom.addOffer(offer)
        veh.offerId = offer.id
        veh.status = "staged"
        table.insert(offerIds, offer.id)
      end
    end
    return offerIds
  end

  --- Stage unique pending cars up to the number of clear pickup bays.
  -- Unselected and excess cars stay pending for subsequent trips. @param selectedKeys Optional vehicle keys; an empty list selects the default trip. @return Success flag and a player-facing status message.
  function api.stageCarHaulTrip(selectedKeys)
    selectedKeys = selectedKeys or {}
    if not state.active or state.active.kind ~= "finkHaul" then return false, "No active distributor contract." end
    if state.active.phase == "staging" or state.active.spawning then return false, "Cars are still staging." end

    local selected = selectPendingCars(selectedKeys)
    if not selected[1] then return false, "Select at least one pending car to stage." end

    local pads = clearStagingPads()
    if not pads[1] then return false, "Clear the pickup bays before staging cars." end

    local offerIds = addStagingOffers(selected, pads)
    if not offerIds[1] then return false, "Could not prepare selected cars." end

    state.active.pendingOfferIds = offerIds
    state.active.phase = "staging"
    api.spawnQueuedCarHaulOffers()
    return true,
      string.format("Staging %d car(s) at the yard. Remaining cars stay available for later trips.", #offerIds)
  end

  function api.isCarHaulVehicleDelivered(veh)
    if not veh or not veh.offerId then return false end
    local vom = overhaul_career_logistics_vehicleOfferManager
    local vtasks = overhaul_career_logistics_vehicleTasks
    if not vom or not vtasks then return false end
    local offer = vom.getOfferById(veh.offerId)
    if not offer or not offer.spawned or offer.brokerRestoring then return false end
    if offer.ownerOpAbandoned then return false end
    local task = vtasks.getVehicleTaskForOffer(offer)
    return task == nil
  end

  -- An abandoned staged car returns to pending; a trip with no cars left staged goes back to planning.
  function api.onCarHaulOfferAbandoned(offer)
    if type(offer) ~= "table" then return end
    local data = offer.data
    if not data or data.finkContractId == nil then return end
    offer.ownerOpAbandoned = true
    if
      not state.active
      or state.active.kind ~= "finkHaul"
      or tostring(data.finkContractId) ~= tostring(state.active.id)
    then
      return
    end
    local changed = false
    for _, veh in ipairs(state.active.vehicles or {}) do
      if
        veh.status == "staged"
        and (tostring(veh.key) == tostring(data.finkVehicleKey) or (veh.offerId ~= nil and veh.offerId == offer.id))
      then
        veh.status = "pending"
        veh.offerId = nil
        changed = true
      end
    end
    if
      changed
      and state.active.phase == "hauling"
      and catalog.countVehiclesByStatus(state.active.vehicles, "staged") == 0
    then
      state.active.phase = "planTrip"
    end
  end

  return api
end

return part
