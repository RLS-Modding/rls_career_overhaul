-- Engine material orders: local endpoints, supplier screen, loading and delivery.
-- Read pickup state, endpoint resolution, vehicle rows, pickup actions and supplier returns.
local M = {}

function M.new(inputs)
  local shop, host = inputs.shop, inputs.host
  local generator, general, parcelManager = inputs.generator, inputs.general, inputs.parcelManager
  local pickup = {open = false, loading = false, facId = nil, psPath = nil}
  local api = {}

  function api.reset()
    pickup.open, pickup.loading, pickup.facId, pickup.psPath = false, false, nil, nil
  end

  function api.endpoints(record)
    if not record or (record.mapId and record.mapId ~= getCurrentLevelIdentifier()) then return nil end
    for _, key in ipairs({"supplierFacilityId", "supplierParkingSpotName", "receivingFacilityId", "receivingParkingSpotName"}) do
      if type(record[key]) ~= "string" or record[key] == "" then return nil end
    end
    local facilities = generator()
    if not facilities then return nil end
    local supplier = record.supplierFacilityId and facilities.getFacilityById(record.supplierFacilityId)
    local receiver = record.receivingFacilityId and facilities.getFacilityById(record.receivingFacilityId)
    local source = supplier and supplier.accessPointsByName and supplier.accessPointsByName[record.supplierParkingSpotName]
    local destination = receiver and receiver.accessPointsByName and receiver.accessPointsByName[record.receivingParkingSpotName]
    if not source or not destination then return nil end
    return {type = "facilityParkingspot", facId = supplier.id, psPath = source.psPath},
      {type = "facilityParkingspot", facId = receiver.id, psPath = destination.psPath}, supplier, receiver
  end

  function api.supplierName(id)
    local _, _, supplier = api.endpoints(host.currentFacility(id))
    return supplier and supplier.name or "Supplier"
  end

  local function availableRawReservations(facId, psPath)
    local result = {}
    for businessId, state in pairs(shop.states) do
      if inputs.owned(businessId) then
        for _, reservation in pairs(state.reservations) do
          local source, destination = api.endpoints(reservation)
          if reservation.status == "available" and reservation.mapId == getCurrentLevelIdentifier()
            and source and destination and (not facId or (source.facId == facId and source.psPath == psPath)) then
            local row = deepcopy(reservation)
            row.businessId = businessId
            result[#result + 1] = row
          end
        end
      end
    end
    table.sort(result, function(a, b)
      if a.businessId ~= b.businessId then return tostring(a.businessId) < tostring(b.businessId) end
      return tostring(a.id) < tostring(b.id)
    end)
    return result
  end

  -- Preview image of a spawned vehicle (its current config), for the pickup UI.
  local function vehicleThumb(vehId)
    if not vehId then return nil end
    -- Inventory thumbnails retain the player's parts and paint; other vehicles use their stock preview.
    local inventory = overhaul_career_garage_inventory
    local invId = inventory.getInventoryIdFromVehicleId(vehId)
    if invId then
      -- no captured picture yet: render one now and push the screen data again when it lands
      inventory.ensureVehicleThumbnail(invId, api.requestSupplyPickupData)
      local thumb = inventory.getVehicleThumbnail(invId)
      if type(thumb) == "string" and thumb ~= "" then return thumb end
    end
    local ok, details = pcall(core_vehicles.getVehicleDetails, vehId)
    if not ok or type(details) ~= "table" then return nil end
    local thumbConfig = details.configs
    return type(thumbConfig) == "table" and thumbConfig.preview or nil
  end

  local function formatCargoEquipment(containers)
    local equipment, capacity = {}, 0
    for _, container in ipairs(containers or {}) do
      local supports = container.cargoTypesLookup and container.cargoTypesLookup.parcel
      local free = math.max(0, tonumber(container.freeCargoSlots) or 0)
      local pallets = supports and math.floor(free / 128) or 0
      capacity = capacity + pallets
      -- Only a container that cannot take a load explains why; eligible ones carry no reason.
      local reason
      if not supports then
        reason = "Parcel freight is not supported"
      elseif pallets > 0 then
        reason = nil
      else
        reason = "Less than 128 slots free"
      end
      equipment[#equipment + 1] = {vehId = container.vehId, containerId = container.containerId,
        vehicleName = container.vehName or "Vehicle", containerName = container.name or "Cargo container",
        thumbnail = vehicleThumb(container.vehId),
        used = container.usedCargoSlots or 0, capacity = container.totalCargoSlots or 0, free = free,
        pallets = pallets, eligible = pallets > 0,
        reason = reason}
    end
    return equipment, capacity
  end

  local function supplyPickupData(containers, facId, psPath)
    local equipment, vehicleCapacity = formatCargoEquipment(containers)
    local reservations = availableRawReservations(facId or pickup.facId, psPath or pickup.psPath)
    local first = reservations[1]
    local _, _, supplier = api.endpoints(first)
    local names, seen = {}, {}
    for _, reservation in ipairs(reservations) do
      local facility = host.currentFacility(reservation.businessId)
      local name = facility and facility.name or "Engine shop"
      if not seen[name] then names[#names + 1], seen[name] = name, true end
    end
    local available = #reservations
    return {available = available > 0, reason = available == 0 and "Order raw material at the engine shop first." or nil,
      facilityName = supplier and supplier.name or "Supplier", facilityPreview = supplier and supplier.preview,
      businessName = table.concat(names, ", "),
      supplyName = "Engine Production Materials", slotsPerPallet = 128, paidAtSupplier = available,
      vehicleCapacity = vehicleCapacity, maximumLoad = math.min(available, vehicleCapacity), equipment = equipment,
      loading = pickup.loading}
  end

  function api.requestSupplyPickupData()
    if not pickup.open then return false end
    local facId, psPath = pickup.facId, pickup.psPath
    general().getNearbyVehicleCargoContainers(function(containers)
      if pickup.open and pickup.facId == facId and pickup.psPath == psPath then
        guihooks.trigger("engineShopSupplyPickupData", supplyPickupData(containers, facId, psPath))
      end
    end)
    return true
  end

  function api.hasPaidSupplyAt(facId, psPath)
    return facId ~= nil and psPath ~= nil and #availableRawReservations(facId, psPath) > 0
  end

  function api.getPaidSupplyPickupLocations()
    local result, seen = {}, {}
    for _, reservation in ipairs(availableRawReservations()) do
      local source = api.endpoints(reservation)
      local key = source.facId .. ":" .. source.psPath
      if not seen[key] then result[#result + 1], seen[key] = source, true end
    end
    return result
  end

  function api.getSupplyOfferCard(facId, psPath, containers)
    local reservations = availableRawReservations(facId, psPath)
    local first = reservations[1]
    if not first then return nil end
    local source, destination, _, receiver = api.endpoints(first)
    local data = supplyPickupData(containers, facId, psPath)
    local enabled = data.maximumLoad > 0
    local reason = data.vehicleCapacity <= 0 and "Bring a freight container with at least 128 free parcel slots." or nil
    return {id = "engineShopPaidMaterials", cardType = "engineShopSupplyOffer", isFacilityCard = true,
      name = "Paid Engine Materials Pickup", type = "parcel", rewardMoney = 0,
      destinationName = data.businessName, destinationNameLong = receiver.name or "Receiving point",
      distance = generator().getDistanceBetweenFacilities(source, destination) or 0, slots = 128, enabled = enabled,
      disableReason = not enabled and {type = "noSpace", label = reason or "Engine materials are unavailable."} or nil,
      modifiers = {}, bigMapIds = {}, supplyLimits = data, sourceFacId = facId,
      origin = {facId = facId, psPath = psPath}}
  end

  function api.enterSupplyPickupScreen(facId, psPath)
    if not api.hasPaidSupplyAt(facId, psPath) then return false end
    pickup.open, pickup.loading, pickup.facId, pickup.psPath = true, false, facId, psPath
    overhaul_integration_services_markerInteraction.closeViewDetailPrompt(true)
    simTimeAuthority.pause(true)
    guihooks.trigger("ChangeState", {state = "overhaul.engineShopSupplyPickup"})
    return true
  end

  function api.closeSupplyPickupScreen()
    api.reset()
    simTimeAuthority.pause(false)
    guihooks.trigger("ChangeState", {state = "play"})
    overhaul_integration_services_markerInteraction.setForceReevaluateOpenPrompt()
  end

  local function loadEligibleReservations(containers, count, facId, psPath)
    local reservations, loaded = availableRawReservations(facId, psPath), 0
    for _, container in ipairs(containers or {}) do
      local pallets = container.cargoTypesLookup and container.cargoTypesLookup.parcel
        and math.floor(math.max(0, container.freeCargoSlots or 0) / 128) or 0
      while pallets > 0 and loaded < count do
        local reservation = reservations[loaded + 1]
        if not reservation then return loaded end
        local source, destination = api.endpoints(reservation)
        local cargo = generator().addEngineShopSupplyCargo(container, reservation, source, {destination})
        if not cargo then break end
        local saved = shop.states[tostring(reservation.businessId)].reservations[tostring(reservation.id)]
        saved.status, saved.cargoId = "inTransit", cargo.id
        loaded, pallets = loaded + 1, pallets - 1
      end
    end
    return loaded
  end

  function api.loadSupply(quantity)
    if not pickup.open or pickup.loading then return false end
    pickup.loading = true
    local facId, psPath = pickup.facId, pickup.psPath
    general().getNearbyVehicleCargoContainers(function(containers)
      if not pickup.open or pickup.facId ~= facId or pickup.psPath ~= psPath then return end
      local limits = supplyPickupData(containers, facId, psPath)
      local count = math.min(math.max(0, math.floor(tonumber(quantity) or 0)), limits.maximumLoad)
      if count <= 0 then
        pickup.loading = false
        guihooks.trigger("engineShopSupplyPickupResult", {success = false, message = "No paid order can be loaded. Bring at least 128 free parcel slots."})
        api.requestSupplyPickupData()
        return
      end
      if not general().isDeliveryModeActive() then general().startDeliveryMode() end
      local loaded = loadEligibleReservations(containers, count, facId, psPath)
      if loaded > 0 then
        parcelManager().applyTransientMoves({type = "facilityParkingspot", facId = facId, psPath = psPath})
        general().requestUpdateContainerWeights()
        overhaul_career_logistics_tasklist.sendCargoToTasklist()
        guihooks.trigger("engineShopSupplyPickupResult", {success = true, message = "Loaded " .. tostring(loaded) .. " paid engine material load(s)."})
        api.closeSupplyPickupScreen()
      else
        pickup.loading = false
        guihooks.trigger("engineShopSupplyPickupResult", {success = false, message = "No compatible 128-slot cargo space was available."})
        api.requestSupplyPickupData()
      end
    end)
    return true
  end

  local function getReservationForCargo(cargo)
    local reservationId = cargo and cargo.data and cargo.data.engineShopSupplyReservationId
    local businessId = cargo and cargo.data and cargo.data.engineShopBusinessId
    local state = businessId and shop.states[tostring(businessId)]
    return state and state.reservations[tostring(reservationId)], state
  end

  function api.canDeliverSupplyCargo(cargo, location)
    local reservation = getReservationForCargo(cargo)
    local _, destination = api.endpoints(reservation)
    return reservation ~= nil and reservation.mapId == getCurrentLevelIdentifier()
      and inputs.owned(reservation.businessId) and destination ~= nil and location ~= nil
      and location.facId == destination.facId and location.psPath == destination.psPath
  end

  function api.deliverSupplyCargo(cargo, location)
    if not api.canDeliverSupplyCargo(cargo, location) then return false end
    local reservation, state = getReservationForCargo(cargo)
    reservation.status = "delivered"
    state.rawStock[tostring(reservation.blueprintId)] = (state.rawStock[tostring(reservation.blueprintId)] or 0) + 1
    state.reservations[tostring(reservation.id)] = nil
    return true
  end

  function api.returnCargoToSupplier(cargo, forfeited)
    local reservation, state = getReservationForCargo(cargo)
    if not reservation then return false end
    if forfeited then state.reservations[tostring(reservation.id)] = nil else reservation.status, reservation.cargoId = "available", nil end
    if cargo.id then parcelManager().changeCargoLocation(cargo.id, {type = "deleted"}) end
    return true
  end

  return api
end

return M
