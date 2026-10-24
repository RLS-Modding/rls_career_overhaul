-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding
-- Part of the Overhaul fork of stock lua/ge/extensions/career/modules/delivery/general.lua.

-- Logistics stall visibility and employment gates. Map: spot rules, interactive entries, cargo counts, cache hooks, part API.

local part = {}

-- Helpers -------------------------------------------------------------------------------------

-- Adds one entry to a stall's list. Each stall keeps one list per kind of work it offers.
local function addInteractivePoi(spots, psPath, field, elem)
  if not psPath or not spots or not field then return end
  if not spots[psPath] then
    spots[psPath] = {dropOffs = {}, pickUps = {}, vehicles = {}, materialContracts = {}, businessSupplies = {}}
  end
  spots[psPath][field] = spots[psPath][field] or {}
  table.insert(spots[psPath][field], elem)
end

local function collectPaidSupplyPickupLocations()
  local locations = {}
  local function addFrom(mod)
    if not mod then return end
    for _, loc in ipairs(mod.getPaidSupplyPickupLocations() or {}) do
      if loc and loc.psPath then
        locations[#locations + 1] = loc
      end
    end
  end
  addFrom(overhaul_career_business_passive)
  addFrom(overhaul_career_business_engineShop)
  return locations
end

local function cargoBoardIsBlocked(facId)
  local employment = overhaul_career_work_employment
  if not employment then return false end
  return employment.getCargoBoardBlockMessage(facId) ~= nil
end

local function canClockInAtFacility(facId)
  local employment = overhaul_career_work_employment
  return employment and employment.canOpenFacilityShiftUi(facId) or false
end

local function isRoleplayFacility(facId)
  local employment = overhaul_career_work_employment
  return employment and employment.isRoleplayFacility(facId) or false
end

local function hasCompanyShift()
  local employment = overhaul_career_work_employment
  if employment then
    return employment.hasCompanyShift()
  end
  return false
end

local function shouldShowFreelanceInspectAt(facId)
  local employment = overhaul_career_work_employment
  if employment then
    return employment.shouldShowFreelanceInspectAt(facId)
  end
  if hasCompanyShift() then return false end
  if isRoleplayFacility(facId) then return false end
  return true
end

local function shouldShowShiftDropOff(elem, anyCargoDropOffable, vehsClose, trailersClose, dropOffable)
  if not anyCargoDropOffable then return false end
  if not hasCompanyShift() then return true end
  local employment = overhaul_career_work_employment
  if employment and employment.isEmployeeDropOffBlocked(elem.facId, elem.psPath) then
    return false
  end
  if employment and employment.shouldOpenEmployeeDropOff(elem.facId, elem.psPath) then
    return true
  end
  if (vehsClose or 0) > 0 or (trailersClose or 0) > 0 then return true end
  dropOffable = dropOffable or {}
  if (dropOffable.fluid or 0) > 0 or (dropOffable.dryBulk or 0) > 0 or (dropOffable.cement or 0) > 0
      or (dropOffable.cash or 0) > 0 then
    return true
  end
  return false
end

local function suppressInspectUiForDropOff(elem, showDropOff)
  if showDropOff then return true end
  local employment = overhaul_career_work_employment
  return employment and employment.willAutoOpenDropOffAt(elem.facId, elem.psPath) or false
end

local function hasPaidBusinessSupplyAt(facId, psPath)
  local passive = overhaul_career_business_passive
  if passive and passive.hasPaidSupplyAt(facId, psPath) then return true end
  local engineShop = overhaul_career_business_engineShop
  if engineShop and engineShop.hasPaidSupplyAt(facId, psPath) then return true end
  return false
end

local function addClockInActivity(activityData, template, facId)
  if not canClockInAtFacility(facId) then return end
  local employment = overhaul_career_work_employment
  local clockPoi = deepcopy(template)
  local onShift = employment.isOnShift()
  local roleplay = isRoleplayFacility(facId)
  clockPoi.icon = "poi_delivery_round"
  if roleplay then
    clockPoi.heading = onShift and "On duty" or "Start shift"
    clockPoi.buttonLabel = onShift and "Open shift" or "Start shift"
    clockPoi.props = {{icon = "checkmark", keyLabel = onShift and "Continue your shift" or "Clock in and take a company vehicle"}}
  else
    clockPoi.heading = onShift and "Company shift" or "Clock in"
    clockPoi.buttonLabel = onShift and "Open shift" or "Clock in"
    clockPoi.props = {{icon = "checkmark", keyLabel = onShift and "Continue your company shift" or "Start your company shift"}}
  end
  clockPoi.buttonFun = function()
    employment.tryOpenFacilityShiftUi(facId)
  end
  table.insert(activityData, clockPoi)
end

-- A loaded parcel is a drop-off at the stall its contract or its own destination names.
local function addLoadedCargoDropOffs(services, spots, targetFacilityIds, cargo)
  local acceptingContracts = cargo.data and cargo.data.materialContractId and services.materialContracts
    and services.materialContracts.getContractsAcceptingMaterial(cargo.materialType, nil, cargo.data.materialContractId) or nil
  if acceptingContracts then
    local addedPaths = {}
    for _, contract in ipairs(acceptingContracts) do
      local destination = contract.destination
      if destination and destination.type == "facilityParkingspot" and destination.psPath and not addedPaths[destination.psPath] then
        addInteractivePoi(spots, destination.psPath, "dropOffs", cargo)
        addedPaths[destination.psPath] = true
        if destination.facId then targetFacilityIds[destination.facId] = true end
      end
    end
  elseif cargo.destination and cargo.destination.type == "facilityParkingspot" and cargo.destination.psPath then
    addInteractivePoi(spots, cargo.destination.psPath, "dropOffs", cargo)
    if cargo.destination.facId then
      targetFacilityIds[cargo.destination.facId] = true
    end
  elseif cargo.destination and cargo.destination.type == "multi" then
    for _, dest in ipairs(cargo.destination.destinations or {}) do
      if dest and dest.psPath then
        addInteractivePoi(spots, dest.psPath, "dropOffs", cargo)
      end
    end
  end
end

-- Interactive stalls --------------------------------------------------------------------------

-- While on shift, parcel pins hide for cargo that the employment rules do not show.
local function parcelPinFilter(employment)
  local filterParcelPins = employment and employment.isOnShift() and employment.shouldShowParcelDropOffPin
  return function(cargo)
    return filterParcelPins and not employment.shouldShowParcelDropOffPin(cargo)
  end
end

-- Cargo in a vehicle is a drop-off at its contract or destination; cargo in transit is a pickup.
local function addCargoStops(services, spots, targetFacilityIds, isHidden)
  -- One pass over all cargo (offers included) yields both the loaded and the waiting cargo, in pool order.
  local loadedCargo, waitingCargo = services.parcelManager.getCargoForStops()

  for _, cargo in ipairs(loadedCargo) do
    if not isHidden(cargo) then
      addLoadedCargoDropOffs(services, spots, targetFacilityIds, cargo)
    end
  end

  -- Cargo staged before a reload has lost its move but still waits at its spot, so its marker stays until the player stages it again.
  for _, cargo in ipairs(waitingCargo) do
    if not isHidden(cargo) then
      local locPsPath = cargo.location and cargo.location.psPath
      if locPsPath then
        addInteractivePoi(spots, locPsPath, "pickUps", cargo)
      end
    end
  end
end

-- Job Broker reservations waiting at their pickup make that spot a mission spot, so its "Pick Up" prompt opens on arrival like vanilla staged cargo, even mid-run.
local function addBrokerPickups(spots, targetFacilityIds)
  local broker = overhaul_career_logistics_broker
  for _, pickup in ipairs(broker and broker.getReservedPickups() or {}) do
    addInteractivePoi(spots, pickup.psPath, "brokerPickups", pickup)
    if pickup.facId then targetFacilityIds[pickup.facId] = true end
  end
end

-- Figure out which facilities need to be active in order to drop off vehicles.
local function addVehicleDestinations(services, spots, targetFacilityIds)
  for _, destination in ipairs(services.vehicleTasks.getTargetDestinationsForActiveTasks()) do
    if destination and destination.facId then
      targetFacilityIds[destination.facId] = true
    end
    if destination and destination.psPath then
      addInteractivePoi(spots, destination.psPath, "vehicles", "vehicle")
    end
  end
end

local function addMaterialContractOrigins(services, spots, targetFacilityIds)
  for _, activeContract in ipairs(services.materialContracts and services.materialContracts.getActiveContracts() or {}) do
    if activeContract.status == "active" and activeContract.origin
      and activeContract.origin.psPath
      and (activeContract.loadableAmount or 0) > 0 then
      addInteractivePoi(spots, activeContract.origin.psPath, "materialContracts", activeContract)
      if activeContract.origin.facId then
        targetFacilityIds[activeContract.origin.facId] = true
      end
    end
  end
end

local function addPaidSupplyPickups(spots, targetFacilityIds)
  for _, loc in ipairs(collectPaidSupplyPickupLocations()) do
    addInteractivePoi(spots, loc.psPath, "businessSupplies", loc)
    if loc.facId then
      targetFacilityIds[loc.facId] = true
    end
  end
end

-- Every delivery parcel, vehicle and material contract that wants a stall, keyed by parking spot path. Also returns the facilities those stalls belong to, so their markers stay visible.
local function getInteractivePois(inputs)
  if not inputs.bindDeliveryDeps() then
    return {}, {}
  end
  local services = inputs.services
  local spots, targetFacilityIds = {}, {}
  addCargoStops(services, spots, targetFacilityIds, parcelPinFilter(overhaul_career_work_employment))
  addBrokerPickups(spots, targetFacilityIds)
  addVehicleDestinations(services, spots, targetFacilityIds)
  addMaterialContractOrigins(services, spots, targetFacilityIds)
  addPaidSupplyPickups(spots, targetFacilityIds)
  return spots, targetFacilityIds
end

-- Cargo counts and reservations ---------------------------------------------------------------

-- Counts of parcels waiting at each stall, keyed by facility id and then parking spot path. The clock is read from the logistics general facade, the newest one loaded.
local function getPoiCargoCounts(inputs)
  local services = inputs.services
  local counts = {}
  local now = services.general.time()
  for cargo in pairs(inputs.state.poiCargoSnapshot) do
    local loc = cargo.location
    local expiresAt = cargo.offerExpiresAt
    local hasExpiry = type(expiresAt) == 'number'
    -- Weak keys alone keep iterating retired cargo while a screen or owner still
    -- holds it. Expired offers cannot become visible again on this map's clock.
    if not loc or loc.type == "delete" or loc.type == "deleted" or (hasExpiry and expiresAt <= now) then
      inputs.state.poiCargoSnapshot[cargo] = nil
    elseif loc.type == "facilityParkingspot" and loc.facId and loc.psPath
        and hasExpiry and expiresAt > now
        and cargo.generatedAtTimestamp <= math.huge
        and services.parcelManager.sameLocation(loc, {type = "facilityParkingspot", facId = loc.facId, psPath = loc.psPath})
        and not services.parcelManager.sameLocation(loc, cargo.destination) then
      counts[loc.facId] = counts[loc.facId] or {}
      local spots = counts[loc.facId]
      spots[loc.psPath] = (spots[loc.psPath] or 0) + 1
    end
  end
  return counts
end

-- Stalls that must keep their reservation: ones with a drop-off or a vehicle, and the stalls of accepted vehicle deliveries that the player has not reached yet.
local function reservedStallPaths(inputs, spots)
  local reservedPaths = {}
  for path, data in pairs(spots) do
    if next(data.dropOffs) or next(data.vehicles) then reservedPaths[path] = true end
  end
  for _, taskData in ipairs(inputs.services.vehicleTasks.getVehicleTasks()) do
    if not taskData.remove and not taskData.finished then
      for i = taskData.activeTaskIndex or 1, #(taskData.tasks or {}) do
        local destination = taskData.tasks[i].destination
        if destination and destination.psPath then reservedPaths[destination.psPath] = true end
      end
    end
  end
  return reservedPaths
end

-- Pause unsticks drop-offs by clearing this cache. Any change to parcel, vehicle, or trailer interactive spots must do the same or the world markers stay stale.
local function refreshDeliveryWorldPoisIfChanged(inputs)
  if not (overhaul_career_career and overhaul_career_career.isActive()) then
    inputs.clearDeliveryParkingReservations()
    return
  end
  if not inputs.bindDeliveryDeps() then return end
  local spots = getInteractivePois(inputs)
  inputs.parkingReservation.setDeliveryDestinations(reservedStallPaths(inputs, spots),
    inputs.services.generator and inputs.services.generator.getParkingSpotByPath)
  local keys = {}
  for path in pairs(spots) do
    keys[#keys + 1] = path
  end
  table.sort(keys)
  local key = table.concat(keys, "|")
  if key == inputs.state.lastInteractivePoiKey then return end
  inputs.state.lastInteractivePoiKey = key
  if gameplay_rawPois then
    gameplay_rawPois.clear()
  end
end

local function isInspectParkingSpot(inputs, facId, psPath)
  if not facId or not psPath or not inputs.services.generator then
    return false
  end
  local facility = inputs.services.generator.getFacilityById(facId)
  if not facility then return false end
  for _, accessPoint in pairs(facility.accessPointsByName or {}) do
    if accessPoint.isInspectSpot == true then
      local path = accessPoint.psPath
      if not path and accessPoint.ps and accessPoint.ps.getPath then
        path = accessPoint.ps:getPath()
      end
      if path == psPath then
        return true
      end
    end
  end
  return false
end

-- Player occupancy ---------------------------------------------------------------------------

-- Whether a vehicle stands on the stall. A walking player never counts as parked in a bay.
local function vehicleOnStall(spot, vehicle, walking)
  if not walking then
    local vehId = vehicle.getID and vehicle:getID()
    if vehId and spot.checkParking and spot:checkParking(vehId, 0, 8, 2.5) then
      return true
    end
  end
  local pos = vehicle:getPosition()
  if spot.containsPoint and spot:containsPoint(pos) then return true end
  if not spot.pos then return false end
  local radius = 5
  if spot.scl then
    radius = math.max(math.abs(spot.scl.x or 0), math.abs(spot.scl.y or 0), 3) * 0.5 + 1.25
  end
  return (pos - spot.pos):length() <= radius
end

-- A coupled vehicle counts when its position or its box overlaps the stall.
local function coupledVehicleOnStall(spot, vehId, walking)
  local attached = getObjectByID(vehId)
  if attached and attached.getPosition and vehicleOnStall(spot, attached, walking) then return true end
  if attached and spot.pos and spot.rot and spot.scl and overlapsOBB_OBB then
    local center = vec3(be:getObjectOOBBCenterXYZ(vehId))
    local axis0 = vec3(be:getObjectOOBBHalfAxisXYZ(vehId, 0))
    local axis1 = vec3(be:getObjectOOBBHalfAxisXYZ(vehId, 1))
    local axis2 = vec3(be:getObjectOOBBHalfAxisXYZ(vehId, 2))
    return overlapsOBB_OBB(spot.pos, spot.rot * vec3(spot.scl.x / 2, 0, 0),
      spot.rot * vec3(0, spot.scl.y / 2, 0), spot.rot * vec3(0, 0, spot.scl.z / 2),
      center, axis0, axis1, axis2) and true or false
  end
  return false
end

local function playerAtFacilityStall(inputs, psPath, includeCoupled)
  if not psPath then return false end
  if not inputs.services.generator then inputs.bindDeliveryDeps() end
  local generator = inputs.services.generator or overhaul_career_logistics_generator
  if not generator then return false end
  local spot = generator.getParkingSpotByPath(psPath)
  if not spot then return false end
  local veh = be:getPlayerVehicle(0)
  if not (veh and veh.getPosition) then return false end
  local walking = gameplay_walk and gameplay_walk.isWalking()
  if vehicleOnStall(spot, veh, walking) then return true end
  if includeCoupled and not walking then
    for _, vehId in ipairs(overhaul_vehicles_playerVehicles.getPlayerVehicleIds()) do
      if vehId ~= veh:getID() and coupledVehicleOnStall(spot, vehId, walking) then return true end
    end
  end
  return false
end

-- Part API ------------------------------------------------------------------------------------

function part.new(inputs)
  assert(type(inputs.bindDeliveryDeps) == "function", "logistics general pois need bindDeliveryDeps")
  assert(type(inputs.clearDeliveryParkingReservations) == "function", "logistics general pois need clearDeliveryParkingReservations")
  return {
    getInteractivePois = function()
      return getInteractivePois(inputs)
    end,
    getPoiCargoCounts = function()
      return getPoiCargoCounts(inputs)
    end,
    refreshDeliveryWorldPoisIfChanged = function()
      refreshDeliveryWorldPoisIfChanged(inputs)
    end,
    playerAtFacilityStall = function(psPath, includeCoupled)
      return playerAtFacilityStall(inputs, psPath, includeCoupled)
    end,
    isInspectParkingSpot = function(facId, psPath)
      return isInspectParkingSpot(inputs, facId, psPath)
    end,
    cargoBoardIsBlocked = cargoBoardIsBlocked,
    canClockInAtFacility = canClockInAtFacility,
    isRoleplayFacility = isRoleplayFacility,
    hasCompanyShift = hasCompanyShift,
    shouldShowFreelanceInspectAt = shouldShowFreelanceInspectAt,
    shouldShowShiftDropOff = shouldShowShiftDropOff,
    suppressInspectUiForDropOff = suppressInspectUiForDropOff,
    hasPaidBusinessSupplyAt = hasPaidBusinessSupplyAt,
    addClockInActivity = addClockInActivity,
  }
end

return part
