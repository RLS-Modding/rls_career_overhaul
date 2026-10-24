-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Part of the Overhaul fork of stock lua/ge/extensions/career/modules/delivery/general.lua.

-- Logistics general: the raw POI list for the level. Each delivery facility gets one marker per stall that needs one, plus an office marker. general.lua owns the runtime state and the binding.

local part = {}

-- Lines a stall shows on the big map, one per kind of work waiting there.
local function stallTaskLines(interactive)
  local tasks = {}
  if next(interactive.dropOffs) then
    table.insert(tasks, core_locales.contextTranslate("ui.career.delivery.general.deliverCargoItemsHere", {count = #interactive.dropOffs}))
  end
  if next(interactive.pickUps) then
    table.insert(tasks, core_locales.contextTranslate("ui.career.delivery.general.pickUpCargoItemsHere", {count = #interactive.pickUps}))
  end
  local reservedHere = interactive.brokerPickups
  if reservedHere and next(reservedHere) then
    table.insert(tasks, #reservedHere == 1 and "Load 1 reserved parcel" or string.format("Load %d reserved parcels", #reservedHere))
  end
  if next(interactive.vehicles) then
    table.insert(tasks, core_locales.contextTranslate("ui.career.delivery.general.deliverVehiclesHere", {count = #interactive.vehicles}))
  end
  if next(interactive.materialContracts) then
    for _, contract in ipairs(interactive.materialContracts) do
      table.insert(tasks, string.format("Load %s - %d %s remaining", _tr(contract.materialName), math.floor((contract.remainingAmount or 0) + 0.5), contract.units or "L"))
    end
  end
  if next(interactive.businessSupplies or {}) then
    table.insert(tasks, "Pick up paid supplies")
  end
  return table.concat(tasks, "<br/>")
end

-- A facility offers logistics types either as a lookup table or as a list.
local function hasLogisticTypes(lookup, list)
  return (lookup and next(lookup) ~= nil) or (list and (list[1] ~= nil or next(list) ~= nil))
end

-- A facility is on the map when it is visible or a delivery target; employment can hide it.
local function facilityIncluded(inputs, facility, targetFacilityIds)
  local included = inputs.services.progress.isFacilityVisible(facility.id) or targetFacilityIds[facility.id]
  local employment = overhaul_career_work_employment
  if employment and not employment.shouldShowDeliveryFacilityWorldPin(facility.id) then
    included = targetFacilityIds[facility.id] and true or false
  end
  return included
end

-- Facts about one stall, read once so the decisions below name what they test.
local function readStall(scan, view, accessPoint)
  local facility = view.facility
  local parkingSpot = accessPoint.ps
  local psPath = parkingSpot:getPath()
  local cargoCount = scan.cargoCounts[facility.id] and scan.cargoCounts[facility.id][psPath] or 0
  local canInspectCargo = accessPoint.isInspectSpot == true
  if canInspectCargo then view.hasInspectSpot = true end
  view.cargoCount = view.cargoCount + cargoCount
  view.lastPosition = parkingSpot.pos

  local interactiveHere = scan.interactive[psPath]
  if interactiveHere then scan.addedDropOff = true end
  return {
    facility = facility,
    parkingSpot = parkingSpot,
    psPath = psPath,
    loc = {type = "facilityParkingspot", facId = facility.id, psPath = psPath},
    cargoCount = cargoCount,
    canInspectCargo = canInspectCargo,
    -- Loaner-only pads are not cargo inspect spots; they show only when the player has cargo business here.
    isLoanerOnlySpot = accessPoint.isLoanerVehicleSpot and not accessPoint.isInspectSpot,
    interactiveHere = interactiveHere,
    icon = interactiveHere and "poi_dropoff_round" or "poi_pickup_round",
  }
end

-- Which markers this stall gets: work to do here, an employment return, and the inspect pad's offers.
-- A focused parking marker shows its beam from any distance. Real cargo work focuses its spot; a Broker
-- reservation focuses only its primary spot, and loaner pads (usable at every loaner site) stay close-range.
local function isFarVisibleSpot(interactive)
  if next(interactive.dropOffs) or next(interactive.pickUps) or next(interactive.vehicles)
    or next(interactive.materialContracts) or next(interactive.businessSupplies or {}) then
    return true
  end
  for _, pickup in ipairs(interactive.brokerPickups or {}) do
    if pickup.primary and pickup.kind ~= "loaner" then return true end
  end
  return false
end

local function decideStall(inputs, view, stall)
  local pois = inputs.pois
  local facilityId, psPath = stall.facility.id, stall.psPath
  local interactiveHere = stall.interactiveHere
  local employment = overhaul_career_work_employment
  local companyShift = pois.hasCompanyShift()
  local employmentReturnHere = employment and employment.hasAssignedReturnCargoAtSpot(facilityId, psPath)
  local deliveringHere = interactiveHere
    and (next(interactiveHere.dropOffs) or next(interactiveHere.vehicles)) and true or false
  local supplyHere = stall.canInspectCargo and pois.hasPaidBusinessSupplyAt(facilityId, psPath)
  local clockInHere = stall.canInspectCargo and view.canClockInHere and not deliveringHere
  local inspectHere = stall.canInspectCargo and pois.shouldShowFreelanceInspectAt(facilityId)
    and not view.boardBlocked and not deliveringHere
  -- Available offers belong at the acceptance pad. Separate work bays become visible through missionSpot/employmentReturnHere once needed.
  local showInspectPad = false
  if stall.canInspectCargo then
    showInspectPad = clockInHere or inspectHere or supplyHere
      or ((not companyShift) and stall.cargoCount > 0 and not view.boardBlocked)
  end
  local missionSpot = interactiveHere ~= nil
  return {
    missionSpot = missionSpot,
    farVisible = missionSpot and isFarVisibleSpot(interactiveHere),
    employmentReturnHere = employmentReturnHere,
    supplyHere = supplyHere,
    clockInHere = clockInHere,
    inspectHere = inspectHere,
    deliveringHere = deliveringHere,
    showParkingMarker = missionSpot or employmentReturnHere or showInspectPad,
  }
end

local function stallElement(stall, decision)
  local interactiveHere = stall.interactiveHere
  local parkingSpot = stall.parkingSpot
  return {
    id = string.format("delivery-parking-%s-%s", stall.facility.id, stall.psPath),
    data = {
      type = "logisticsParking",
      facId = stall.facility.id,
      psPath = stall.psPath,
      canInspectCargo = decision.inspectHere,
      hasPlayerCargo = decision.missionSpot,
      hasPaidSupply = decision.supplyHere,
      hasPickup = interactiveHere and (next(interactiveHere.pickUps) ~= nil or next(interactiveHere.brokerPickups or {}) ~= nil) or false,
      hasMaterialContract = decision.missionSpot and next(interactiveHere.materialContracts) ~= nil or false,
      hasEmploymentReturn = decision.employmentReturnHere,
      hasEmploymentClockIn = decision.clockInHere,
    },
    markerInfo = {
      parkingMarker = decision.showParkingMarker and {
        path = stall.psPath, pos = parkingSpot.pos, rot = parkingSpot.rot, scl = parkingSpot.scl,
        icon = stall.icon, focus = decision.farVisible,
      } or nil,
    },
  }
end

-- The cargo screen names the stall by its facility; otherwise a stall with work shows its task lines.
local function stallBigmapMarker(services, stall)
  local parkingSpot = stall.parkingSpot
  if services.cargoScreen.isCargoScreenOpen() then
    return {
      pos = parkingSpot.pos,
      name = _tr("ui.career.delivery.general.pickupPrefix") .. _tr(stall.facility.name),
      icon = stall.icon,
    }
  end
  if stall.interactiveHere then
    return {
      pos = parkingSpot.pos,
      name = services.parcelManager.getLocationLabelShort(stall.loc),
      description = stallTaskLines(stall.interactiveHere),
      icon = "poi_dropoff_round",
      previews = {stall.facility.preview},
      thumbnail = stall.facility.preview,
    }
  end
  return nil
end

-- Marker for one parking spot of a facility. It is listed when it has work, a return or an inspect pad, and always while the cargo screen is open (loaner-only pads excepted).
local function addStallPoi(inputs, scan, view, accessPoint, elements)
  local services = inputs.services
  local stall = readStall(scan, view, accessPoint)
  local decision = decideStall(inputs, view, stall)
  local element = stallElement(stall, decision)
  element.markerInfo.bigmapMarker = stallBigmapMarker(services, stall)
  if decision.showParkingMarker or (not stall.isLoanerOnlySpot and services.cargoScreen.isCargoScreenOpen()) then
    table.insert(elements, element)
  end
end

-- One marker for the whole facility, shown under the labourer branch of the big map.
local function addOfficePoi(inputs, view, elements)
  local services = inputs.services
  local facility = view.facility
  local hasProvided = hasLogisticTypes(facility.logisticTypesProvidedLookup, facility.logisticTypesProvided)
  local hasReceived = hasLogisticTypes(facility.logisticTypesReceivedLookup, facility.logisticTypesReceived)
  local unlocked = services.progress.isFacilityUnlocked(facility.id)
  if not (unlocked and (hasProvided or (view.hasInspectSpot and hasReceived))
      and (not view.boardBlocked or view.canClockInHere)) then
    return
  end

  local walkingElements = {}
  if facility.doors and next(facility.doors) then
    overhaul_world_facilities.walkingMarkerFormatFacility(facility, walkingElements)
  end
  -- The office sits on the last inspect spot, or on the last stall when there is none.
  local pos = view.lastPosition
  for _, accessPoint in pairs(facility.accessPointsByName or {}) do
    if accessPoint.isInspectSpot and accessPoint.ps then
      pos = accessPoint.ps.pos
    end
  end
  local countKey = view.cargoCount ~= 1
    and "ui.career.delivery.general.facilityItemsAvailablePlural"
    or "ui.career.delivery.general.facilityItemsAvailableSingular"
  table.insert(elements, {
    id = string.format("logisticsFacility-%s", facility.id),
    data = {type = "logisticsOffice", facId = facility.id},
    markerInfo = {
      walkingMarker = next(walkingElements) and walkingElements[1].markerInfo.walkingMarker or nil,
      bigmapMarker = {
        pos = pos,
        name = _tr(facility.name),
        description = core_locales.contextTranslate(countKey, {description = _tr(facility.description), count = view.cargoCount}),
        icon = "poi_delivery_round",
        previews = {facility.preview},
        thumbnail = facility.preview,
      },
    },
  })
end

local function addFacilityPois(inputs, facility, scan, elements)
  local pois = inputs.pois
  local view = {
    facility = facility,
    boardBlocked = pois.cargoBoardIsBlocked(facility.id),
    canClockInHere = pois.canClockInAtFacility(facility.id),
    cargoCount = 0,
    lastPosition = nil,
    hasInspectSpot = false,
  }
  for _, accessPoint in pairs(facility.accessPointsByName or {}) do
    if accessPoint.ps and accessPoint.ps.getPath then
      addStallPoi(inputs, scan, view, accessPoint, elements)
    end
  end
  if not inputs.services.cargoScreen.isCargoScreenOpen() then
    addOfficePoi(inputs, view, elements)
  end
end

-- Interactive stalls are built without generation, which would otherwise rebuild the facilities mid-scan.
local function interactiveStallsForLevel(inputs)
  local generator = inputs.services.generator
  if not generator then
    return inputs.pois.getInteractivePois()
  end
  local interactive, targetFacilityIds = generator.withoutGeneration(inputs.pois.getInteractivePois)
  return interactive, targetFacilityIds
end

local function onGetRawPoiListForLevel(inputs, elements)
  if not overhaul_career_career.isActive() then return end
  if not inputs.bindDeliveryDeps() then
    inputs.requestDeliveryPoiRefresh()
    return
  end

  local interactive, targetFacilityIds = interactiveStallsForLevel(inputs)
  local scan = {
    interactive = interactive,
    cargoCounts = inputs.pois.getPoiCargoCounts(),
    addedDropOff = false,
  }
  for _, facility in ipairs(overhaul_world_facilities.getFacilitiesByType("deliveryProvider") or {}) do
    if facilityIncluded(inputs, facility, targetFacilityIds) then
      addFacilityPois(inputs, facility, scan, elements)
    end
  end
  -- Interactive spots exist but no stall showed one, so ask for another pass to pick them up.
  if next(interactive) and not scan.addedDropOff then
    inputs.requestDeliveryPoiRefresh()
  end
end

function part.new(inputs)
  assert(type(inputs.bindDeliveryDeps) == "function", "logistics general poiList needs bindDeliveryDeps")
  assert(type(inputs.requestDeliveryPoiRefresh) == "function", "logistics general poiList needs requestDeliveryPoiRefresh")
  assert(inputs.pois and inputs.services, "logistics general poiList needs pois and services")
  for _, name in ipairs({"getInteractivePois", "getPoiCargoCounts"}) do
    assert(type(inputs.pois[name]) == "function", "logistics general poiList needs pois." .. name)
  end
  return {
    onGetRawPoiListForLevel = function(levelIdentifier, elements)
      onGetRawPoiListForLevel(inputs, elements)
    end,
  }
end

return part
