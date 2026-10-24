-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding
-- Part of the Overhaul fork of stock lua/ge/extensions/career/modules/delivery/general.lua.

-- Logistics stall activities. Map: counts, props, stall state, entry builders, gather, permission rows; general owns runtime state.

local part = {}

local cargoSemantics = require('overhaul/lib/logistics/cargoSemantics')
local rigCargo = require('overhaul/lib/logistics/rigCargo')

-- Cargo within this radius of a stall counts as dropped or loaded there.
local STALL_RADIUS_SQUARED_M = 40 * 40

-- Tags of vehicle work that is refused while the vehicle carries delivery cargo.
local CARGO_VEHICLE_TAGS = {
  vehicleSelling = true, vehicleStorage = true, vehicleStoring = true,
  returnLoanedVehicle = true, junkVehicle = true,
}

-- Tags delivery mode does not restrict. A row is not added for them: native permissions treat an explicit "allowed" entry differently from the unrestricted default.
local UNRESTRICTED_TAGS = {
  vehicleModification = true, vehicleRepair = true, vehicleRetrieval = true, vehicleShopping = true,
  recoveryTowToGarage = true, interactMission = true, recoveryFlipUpright = true, recoveryTowToRoad = true,
  vehicleSelling = true, vehicleStorage = true,
}

-- Counts per cargo type, with the same five keys every caller reads.
local function newCargoCounts()
  return {parcel = 0, fluid = 0, dryBulk = 0, cement = 0, cash = 0}
end

local function hasAnyCargo(counts)
  return counts.parcel > 0 or counts.fluid > 0 or counts.dryBulk > 0 or counts.cement > 0 or counts.cash > 0
end

local function addCheckmark(props, keyLabel)
  table.insert(props, {icon = "checkmark", keyLabel = keyLabel})
end

-- counts ----------------------------------------------------------------------------------------

local function addDropOffCargo(inputs, counts, elem, psPos, container, cargo)
  local materialContracts = inputs.services.materialContracts
  local isContractCargo = cargo.data and cargo.data.materialContractId and materialContracts
  local acceptsContractMaterial = isContractCargo
    and materialContracts.getMaterialDeliveryCapacity(cargo.materialType, {
      type = "facilityParkingspot", facId = elem.facId, psPath = elem.psPath,
    }, cargo.data.materialContractId) > 0
  local measuredType, add = cargoSemantics.measure(cargo)
  local nearStall = (container.position - psPos):squaredLength() < STALL_RADIUS_SQUARED_M
  if acceptsContractMaterial then
    counts[measuredType] = counts[measuredType] + (nearStall and add or 0)
  elseif cargo.destination.type == "facilityParkingspot" then
    -- Writes under cargo.type but sums the measured type. The two match for ordinary cargo; the mismatch is kept as it was, because changing it changes the counts.
    counts[cargo.type] = counts[measuredType] + ((cargo.destination.psPath == elem.psPath and nearStall) and add or 0)
  elseif cargo.destination.type == "multi" then
    for _, dest in ipairs(cargo.destination.destinations) do
      counts[measuredType] = counts[measuredType] + ((dest.psPath == elem.psPath and nearStall) and add or 0)
    end
  end
end

local function countDropOffCargo(inputs, elem, psPos)
  local counts = newCargoCounts()
  for _, container in ipairs(inputs.state.mostRecentCargoContainerData) do
    for _, cargo in ipairs(container.rawCargo) do
      addDropOffCargo(inputs, counts, elem, psPos, container, cargo)
    end
  end
  return counts
end

local function addPickUpCargo(counts, elem, psPos, container, cargo)
  local measuredType, add = cargoSemantics.measure(cargo)
  if cargo.location.type == "facilityParkingspot" then
    local nearStall = (container.position - psPos):squaredLength() < STALL_RADIUS_SQUARED_M
    -- Same index mismatch as addDropOffCargo; kept as it was.
    counts[cargo.type] = counts[measuredType] + ((cargo.location.psPath == elem.psPath and nearStall) and add or 0)
  end
end

local function countPickUpCargo(inputs, elem, psPos)
  local counts = newCargoCounts()
  for _, container in ipairs(inputs.state.mostRecentCargoContainerData) do
    for _, cargo in ipairs(container.transientCargo) do
      addPickUpCargo(counts, elem, psPos, container, cargo)
    end
  end
  return counts
end

local function countAvailableCargo(inputs, elem)
  local services = inputs.services
  local counts = newCargoCounts()
  for _, cargo in ipairs(services.parcelManager.getAllCargoForFacilityUnexpiredUndelivered(elem.facId)) do
    local measuredType, add = cargoSemantics.measure(cargo)
    counts[measuredType] = counts[measuredType] + add
  end
  -- Material availability is contract-based; raw facility stock is no longer freely loadable.
  local materialContracts = services.materialContracts
  for _, contract in ipairs(materialContracts and materialContracts.getOffersForFacility(elem.facId) or {}) do
    local template = services.generator.getMaterialsTemplatesById(contract.materialType)
    if template then
      counts[template.type] = (counts[template.type] or 0) + contract.totalAmount
    end
  end
  for _, activeContract in ipairs(materialContracts and materialContracts.getActiveContracts() or {}) do
    if activeContract.sourceFacId == elem.facId then
      local template = services.generator.getMaterialsTemplatesById(activeContract.materialType)
      if template then
        counts[template.type] = (counts[template.type] or 0) + activeContract.loadableAmount
      end
    end
  end
  return counts
end

-- props -----------------------------------------------------------------------------------------

local function addDropOffProps(props, counts, vehsClose, trailersClose)
  if counts.parcel > 0 then
    addCheckmark(props, counts.parcel > 1
      and core_locales.contextTranslate("ui.career.delivery.general.parcelsDropoff", {count = counts.parcel})
      or _tr("ui.career.delivery.general.parcelDropoff"))
  end
  if counts.fluid > 0 then
    addCheckmark(props, core_locales.contextTranslate("ui.career.delivery.general.fluidDropoff", {volume = counts.fluid}))
  end
  if counts.dryBulk > 0 then
    addCheckmark(props, core_locales.contextTranslate("ui.career.delivery.general.dryBulkDropoff", {volume = counts.dryBulk}))
  end
  if counts.cement > 0 then
    addCheckmark(props, string.format("%dL cement dropoff", counts.cement))
  end
  if counts.cash > 0 then
    addCheckmark(props, string.format("%d cash dropoff", counts.cash))
  end
  if vehsClose > 0 then
    addCheckmark(props, _tr("ui.career.delivery.general.vehicleDropoff"))
  end
  if trailersClose > 0 then
    addCheckmark(props, _tr("ui.career.delivery.general.trailerDropoff"))
  end
end

local function addPickUpProps(props, counts)
  if counts.parcel > 0 then
    addCheckmark(props, counts.parcel > 1
      and core_locales.contextTranslate("ui.career.delivery.general.parcelsPickup", {count = counts.parcel})
      or _tr("ui.career.delivery.general.parcelPickup"))
  end
  if counts.fluid > 0 then
    addCheckmark(props, core_locales.contextTranslate("ui.career.delivery.general.fluidPickup", {volume = counts.fluid}))
  end
  if counts.dryBulk > 0 then
    addCheckmark(props, core_locales.contextTranslate("ui.career.delivery.general.dryBulkPickup", {volume = counts.dryBulk}))
  end
  if counts.cement > 0 then
    addCheckmark(props, string.format("%dL cement pickup", counts.cement))
  end
  if counts.cash > 0 then
    addCheckmark(props, string.format("%d cash pickup", counts.cash))
  end
end

local function addAvailableCargoProps(inputs, elem, props)
  local counts = countAvailableCargo(inputs, elem)
  if counts.parcel > 0 then
    addCheckmark(props, core_locales.contextTranslate(counts.parcel ~= 1 and "ui.career.delivery.general.parcelsAvailable" or "ui.career.delivery.general.parcelAvailable", {count = counts.parcel}))
  end
  if counts.fluid > 0 then
    addCheckmark(props, core_locales.contextTranslate("ui.career.delivery.general.fluidAvailable", {volume = counts.fluid}))
  end
  if counts.dryBulk > 0 then
    addCheckmark(props, core_locales.contextTranslate("ui.career.delivery.general.dryBulkAvailable", {volume = counts.dryBulk}))
  end
  if counts.cement > 0 then
    addCheckmark(props, string.format("%dL of cement available", counts.cement))
  end
  if counts.cash > 0 then
    addCheckmark(props, string.format("%d cash available", counts.cash))
  end
  local vehOffers, trailerOffers = cargoSemantics.groupVehicleOffers(
    inputs.services.vehicleOffers.getAllOfferAtFacilityUnexpired(elem.facId))
  if #vehOffers > 0 then
    addCheckmark(props, core_locales.contextTranslate(#vehOffers ~= 1 and "ui.career.delivery.general.vehicleTransportsAvailable" or "ui.career.delivery.general.vehicleTransportAvailable", {count = #vehOffers}))
  end
  if #trailerOffers > 0 then
    addCheckmark(props, core_locales.contextTranslate(#trailerOffers ~= 1 and "ui.career.delivery.general.trailerTransportsAvailable" or "ui.career.delivery.general.trailerTransportAvailable", {count = #trailerOffers}))
  end
end

-- stall record ----------------------------------------------------------------------------------

-- Measures the drop-offs at a stall, adds their props, and returns what the entries need later.
local function dropOffStall(inputs, elem, poiTemplate, psPos)
  local pois = inputs.pois
  local counts = countDropOffCargo(inputs, elem, psPos)
  local vehsClose, trailersClose = inputs.services.vehicleTasks.canDropOffCargoAtPsPath(elem.psPath)
  local anyCargoDropOffable = hasAnyCargo(counts) or vehsClose > 0 or trailersClose > 0
  local showDropOff = pois.shouldShowShiftDropOff(elem, anyCargoDropOffable, vehsClose, trailersClose, counts)
  local suppressInspect = pois.suppressInspectUiForDropOff(elem, showDropOff)
  addDropOffProps(poiTemplate.props, counts, vehsClose, trailersClose)
  return {
    dropOffCounts = counts,
    vehiclesClose = vehsClose,
    trailersClose = trailersClose,
    showDropOff = showDropOff,
    suppressInspect = suppressInspect,
  }
end

-- entries ---------------------------------------------------------------------------------------

local function addBlockedSpawnActivity(activityData)
  local employment = overhaul_career_work_employment
  local loaners = overhaul_career_logistics_loanerVehicles
  local blocked = employment and employment.getBlockedSpawnStatus and employment.getBlockedSpawnStatus()
  local blockedSource = "employment"
  if not blocked then
    blocked = loaners and loaners.getBlockedSpawnStatus and loaners.getBlockedSpawnStatus()
    blockedSource = "loaner"
  end
  if blocked and blocked.nearby then
    local fromEmployment = blockedSource == "employment"
    table.insert(activityData, {
      icon = "poi_delivery_round",
      heading = fromEmployment and "Company vehicle spawn area" or "Loaner vehicle spawn area",
      buttonLabel = "Spawn vehicle",
      disabled = not blocked.ready,
      sorting = {type = "logisticsParking", id = fromEmployment and "employment-spawn" or "loaner-spawn"},
      props = {{icon = "info", keyLabel = blocked.ready and "Area clear - ready to spawn" or "Clear the highlighted stalls first"}},
      buttonFun = function()
        if fromEmployment then
          employment.spawnBlockedEquipment()
        else
          loaners.spawnBlockedOffers()
        end
      end,
    })
  end
end

local function materialLoaderEntry(inputs, poiTemplate, contract, elem)
  local entry = deepcopy(poiTemplate)
  local units = contract.units or "L"
  entry.preheadings = {"Active Material Contract"}
  entry.heading = string.format("Load %s", _tr(contract.materialName))
  entry.props = {
    {icon = "locationSource", keyLabel = "Destination", valueLabel = _tr(contract.destinationName)},
    {icon = "checkmark", keyLabel = "Delivered", valueLabel = string.format("%d %s", math.floor((contract.deliveredAmount or 0) + 0.5), units)},
    {icon = "deliveryTruck", keyLabel = "In Transit", valueLabel = string.format("%d %s", math.floor((contract.inTransitAmount or 0) + 0.5), units)},
    {icon = "route", keyLabel = "Remaining", valueLabel = string.format("%d %s", math.floor((contract.remainingAmount or 0) + 0.5), units)},
  }
  entry.buttonLabel = "Open Material Loader"
  local contractId = contract.id
  entry.buttonFun = function()
    inputs.services.cargoScreen.enterMaterialContractPickupScreen(contractId, elem.facId, elem.psPath)
  end
  return entry
end

local function addMaterialLoaderEntries(inputs, activityData, poiTemplate, elem)
  for _, contract in ipairs(inputs.services.materialContracts and inputs.services.materialContracts.getActiveContracts() or {}) do
    if contract.status == "active" and contract.origin and contract.origin.facId == elem.facId
        and contract.origin.psPath == elem.psPath and (contract.loadableAmount or 0) > 0 then
      table.insert(activityData, materialLoaderEntry(inputs, poiTemplate, contract, elem))
    end
  end
end

-- Drop-off with the shift rules: an assigned employee drop-off first, then a hint when a company shift has nothing to drop at this stall, then the cargo drop-off screen.
local function dropOffEntry(inputs, poiTemplate, elem, stall)
  local entry = deepcopy(poiTemplate)
  entry.heading = _tr("ui.career.delivery.general.deliveryDropOff")
  entry.buttonLabel = _tr("ui.career.delivery.general.dropOff")
  entry.buttonFun = function()
    local employment = overhaul_career_work_employment
    if employment and employment.shouldOpenEmployeeDropOff and employment.shouldOpenEmployeeDropOff(elem.facId, elem.psPath) then
      if employment.tryAutoDropOffAssigned and employment.tryAutoDropOffAssigned(elem.facId, elem.psPath) then
        return
      end
      if employment.openDropOffUi then
        employment.openDropOffUi(elem.facId, elem.psPath)
        return
      end
    end
    if inputs.pois.hasCompanyShift() then
      local counts = stall.dropOffCounts
      local materialsHere = counts.fluid > 0 or counts.dryBulk > 0 or counts.cement > 0 or counts.cash > 0
      if stall.vehiclesClose <= 0 and stall.trailersClose <= 0 and not materialsHere then
        ui_message("Drop off assigned cargo at the marked destination.", 5, "warning")
        return
      end
    end
    extensions.ui_router.navigate('overhaul.cargoDropOff', {facilityId = elem.facId, parkingSpotPath = elem.psPath})
  end
  entry.icon = "poi_dropoff_round"
  return entry
end

local function pickUpEntry(inputs, poiTemplate, elem)
  local entry = deepcopy(poiTemplate)
  entry.heading = _tr("ui.career.delivery.general.deliveryPickUp")
  entry.buttonLabel = _tr("ui.career.delivery.general.pickUp")
  entry.buttonFun = function()
    inputs.services.parcelManager.applyTransientMoves({type = "facilityParkingspot", facId = elem.facId, psPath = elem.psPath})
    inputs.requestContainerWeightUpdate()
    overhaul_integration_services_markerInteraction.closeViewDetailPrompt(true)
    Engine.Audio.playOnce('AudioGui', 'event:>UI>Missions>Info_Open')
    gameplay_rawPois.clear()
    inputs.services.cargoScreen.onCargoPickedUp()
  end
  entry.icon = "poi_dropoff_round"
  return entry
end

-- Job Broker parcels reserved at this spot: the same "Pick Up" prompt, opening the broker's loader (My Loads, first reservation here selected) instead of applying staged moves.
local function addBrokerPickupEntry(activityData, poiTemplate, elem)
  local broker = overhaul_career_logistics_broker
  local reservedHere, reservedSlots = {}, 0
  for _, pickup in ipairs(broker and broker.getReservedPickups and broker.getReservedPickups() or {}) do
    if pickup.psPath == elem.psPath then
      reservedHere[#reservedHere + 1] = pickup
      reservedSlots = reservedSlots + (pickup.slots or 0)
    end
  end
  if #reservedHere == 0 then return end
  local entry = deepcopy(poiTemplate)
  entry.heading = _tr("ui.career.delivery.general.deliveryPickUp")
  entry.props = {{
    icon = "cardboardBox",
    keyLabel = #reservedHere == 1 and "1 reserved load" or string.format("%d reserved loads", #reservedHere),
    valueLabel = reservedSlots > 0 and string.format("%d %s", reservedSlots, reservedSlots == 1 and "slot" or "slots")
      or "Collect reserved loads here",
  }}
  entry.buttonLabel = _tr("ui.career.delivery.general.pickUp")
  local firstJobId = reservedHere[1].jobId
  entry.buttonFun = function()
    overhaul_integration_services_markerInteraction.closeViewDetailPrompt(true)
    broker.setOpenContext(elem.facId, broker.isAtLoanerFacility and broker.isAtLoanerFacility(elem.facId) or false,
      reservedHere[1].kind == 'loaner' and 'loaners' or 'jobs', firstJobId)
    guihooks.trigger('ChangeState', {state = 'phone-logistics'})
  end
  entry.icon = "poi_pickup_round"
  table.insert(activityData, entry)
end

local function passiveSupplyEntry(inputs, poiTemplate, elem)
  local entry = deepcopy(poiTemplate)
  entry.heading = "Pickup business supplies"
  entry.buttonLabel = "Pickup supplies"
  entry.icon = "poi_pickup_round"
  entry.props = {{icon = "checkmark", keyLabel = "Paid pallets waiting at this supplier"}}
  entry.buttonFun = function()
    inputs.services.cargoScreen.enterPassiveBusinessSupplyPickupScreen(elem.facId, elem.psPath)
  end
  return entry
end

local function engineSupplyEntry(inputs, poiTemplate, elem)
  local entry = deepcopy(poiTemplate)
  entry.heading = "Pickup engine materials"
  entry.buttonLabel = "Pickup materials"
  entry.icon = "poi_pickup_round"
  entry.props = {{icon = "checkmark", keyLabel = "Paid engine loads waiting at this supplier"}}
  entry.buttonFun = function()
    inputs.services.cargoScreen.enterEngineShopSupplyPickupScreen(elem.facId, elem.psPath)
  end
  return entry
end

local function inspectEntry(inputs, poiTemplate, elem)
  local entry = deepcopy(poiTemplate)
  if inputs.pois.cargoBoardIsBlocked(elem.facId) then
    entry.heading = "No work here"
    entry.buttonLabel = "No work here"
    entry.props = {{icon = "info", keyLabel = "No freelance cargo at this stop right now"}}
    entry.buttonFun = function()
      local employment = overhaul_career_work_employment
      local msg = employment and employment.getCargoBoardBlockMessage and employment.getCargoBoardBlockMessage(elem.facId)
      ui_message(msg or "No work here", 6, "info")
    end
  else
    entry.heading = _tr("ui.career.delivery.general.inspectCargo")
    entry.buttonLabel = _tr("ui.career.delivery.general.inspect")
    entry.buttonFun = function()
      inputs.services.cargoScreen.enterCargoOverviewScreen(elem.facId, elem.psPath)
    end
  end
  return entry
end

-- Entries that exist only at an inspect spot: clock-in, paid supplies, and the freelance inspect.
local function appendInspectSpotEntries(inputs, activityData, poiTemplate, elem, stall)
  local pois = inputs.pois
  local atStall = pois.playerAtFacilityStall(elem.psPath)
  local inspectAtStall = atStall or pois.playerAtFacilityStall(elem.psPath, true)
  local employment = overhaul_career_work_employment
  local employmentDropOffAuto = employment and employment.willAutoOpenDropOffAt
    and employment.willAutoOpenDropOffAt(elem.facId, elem.psPath)
  if atStall and not employmentDropOffAuto then
    pois.addClockInActivity(activityData, poiTemplate, elem.facId)
  end
  if pois.isRoleplayFacility(elem.facId) then return end

  local passive = overhaul_career_business_passive
  if passive and passive.hasPaidSupplyAt and passive.hasPaidSupplyAt(elem.facId, elem.psPath) then
    table.insert(activityData, passiveSupplyEntry(inputs, poiTemplate, elem))
  end
  local engineShop = overhaul_career_business_engineShop
  if engineShop and engineShop.hasPaidSupplyAt and engineShop.hasPaidSupplyAt(elem.facId, elem.psPath) then
    table.insert(activityData, engineSupplyEntry(inputs, poiTemplate, elem))
  end
  if inspectAtStall and not stall.suppressInspect and pois.shouldShowFreelanceInspectAt(elem.facId) then
    table.insert(activityData, inspectEntry(inputs, poiTemplate, elem))
  end
end

local function appendParkingActions(inputs, elem, activityData, poiTemplate, stall)
  addMaterialLoaderEntries(inputs, activityData, poiTemplate, elem)
  if stall.showDropOff then
    table.insert(activityData, dropOffEntry(inputs, poiTemplate, elem, stall))
  end
  if stall.pickUpAvailable then
    table.insert(activityData, pickUpEntry(inputs, poiTemplate, elem))
  end
  addBrokerPickupEntry(activityData, poiTemplate, elem)
  local employment = overhaul_career_work_employment
  if employment and employment.tryAutoLoadAssignedParcelsAtSpot then
    employment.tryAutoLoadAssignedParcelsAtSpot(elem.facId, elem.psPath)
  end
  if inputs.pois.isInspectParkingSpot(elem.facId, elem.psPath) then
    appendInspectSpotEntries(inputs, activityData, poiTemplate, elem, stall)
  end
end

-- gather ----------------------------------------------------------------------------------------

local function gatherParkingActivity(inputs, elem, activityData)
  local pois = inputs.pois
  local poiTemplate = {
    icon = "poi_pickup_round",
    preheadings = {inputs.services.parcelManager.getLocationLabelShort({type = "facilityParkingspot", facId = elem.facId, psPath = elem.psPath})},
    props = {},
    sorting = {type = elem.type, id = elem.id},
  }
  local psPos = inputs.services.generator.getParkingSpotByPath(elem.psPath).pos
  local stall = dropOffStall(inputs, elem, poiTemplate, psPos)
  local pickUpCounts = countPickUpCargo(inputs, elem, psPos)
  addPickUpProps(poiTemplate.props, pickUpCounts)
  stall.pickUpAvailable = hasAnyCargo(pickUpCounts)
  if not stall.suppressInspect and pois.isInspectParkingSpot(elem.facId, elem.psPath)
      and not pois.isRoleplayFacility(elem.facId) and pois.shouldShowFreelanceInspectAt(elem.facId) then
    addAvailableCargoProps(inputs, elem, poiTemplate.props)
  end
  appendParkingActions(inputs, elem, activityData, poiTemplate, stall)
end

local function onActivityAcceptGatherData(inputs, elemData, activityData)
  addBlockedSpawnActivity(activityData)
  for _, elem in ipairs(elemData) do
    if elem.type == "logisticsOffice" then
      local officeTemplate = {
        icon = "poi_delivery_round",
        heading = inputs.services.generator.getFacilityById(elem.facId).name,
        preheadings = {_tr("ui.career.delivery.general.logisticsOffice")},
        sorting = {type = elem.type, id = elem.id},
        props = {},
      }
      inputs.pois.addClockInActivity(activityData, officeTemplate, elem.facId)
    elseif elem.type == "logisticsParking" then
      gatherParkingActivity(inputs, elem, activityData)
    end
  end
end

-- permission ------------------------------------------------------------------------------------

-- Permission rows for the tags delivery mode can restrict. Only the reachable ones produce an entry.
local function newPermissionRows(inputs)
  local deliveryModePenalty = inputs.deliveryModePenalty
  local penaltyText = function()
    return string.format("%0.2f", -deliveryModePenalty().money)
  end
  return {
    id = "deliveryMode",
    name = _tr("ui.career.cargoOverview.deliveryMode"),

    vehicleModification = "warning",
    vehicleSelling = "warning",
    vehicleStorage = "warning",
    vehicleRepair = "warning",
    vehicleRetrieval = "allowed",

    vehicleShopping = "forbidden",

    interactRefuel = "allowed",
    interactMission = "warning",
    interactDelivery = "allowed",

    recoveryFlipUpright = "allowed",
    recoveryTowToRoad = "allowed",
    recoveryTowToGarage = "warning",

    getLabel = function(tag)
      local penaltyCtx = {penalty = penaltyText()}
      if tag == "vehicleModification" then
        return core_locales.contextTranslate("ui.career.delivery.general.permissionVehicleModification", penaltyCtx)
      elseif tag == "vehicleSelling" then
        return core_locales.contextTranslate("ui.career.delivery.general.permissionVehicleSelling", penaltyCtx)
      elseif tag == "vehicleStorage" then
        return core_locales.contextTranslate("ui.career.delivery.general.permissionVehicleStorage", penaltyCtx)
      elseif tag == "vehicleRepair" then
        return core_locales.contextTranslate("ui.career.delivery.general.permissionVehicleRepair", penaltyCtx)
      elseif tag == "interactMission" then
        return core_locales.contextTranslate("ui.career.delivery.general.permissionInteractMission", penaltyCtx)
      elseif tag == "recoveryTowToGarage" then
        return core_locales.contextTranslate("ui.career.delivery.general.permissionRecoveryTowToGarage", penaltyCtx)
      elseif tag == "vehicleShopping" then
        return _tr("ui.career.delivery.general.permissionVehicleShopping")
      end
    end,
  }
end

function part.new(inputs)
  assert(type(inputs.deliveryModePenalty) == "function", "logistics general activity needs deliveryModePenalty")
  assert(type(inputs.requestContainerWeightUpdate) == "function", "logistics general activity needs requestContainerWeightUpdate")
  assert(inputs.state and inputs.services and inputs.pois and inputs.persistence, "logistics general activity needs state, services, pois and persistence")
  for _, name in ipairs({"shouldShowShiftDropOff", "suppressInspectUiForDropOff", "hasCompanyShift",
      "cargoBoardIsBlocked", "playerAtFacilityStall", "addClockInActivity", "isRoleplayFacility",
      "shouldShowFreelanceInspectAt", "isInspectParkingSpot"}) do
    assert(type(inputs.pois[name]) == "function", "logistics general activity needs pois." .. name)
  end
  local permissionRows = newPermissionRows(inputs)

  local function onOverhaulCheckPermission(tags, permissions, additionalData)
    for _, tag in ipairs(tags) do
      if tag == "recoveryTowToGarage" and additionalData then
        local inventory = overhaul_career_garage_inventory
        local vehId = additionalData.vehId
          or (additionalData.inventoryId and inventory.getVehicleIdFromInventoryId(additionalData.inventoryId))
        if rigCargo.hasJobCargo(vehId, {
          playerVehicles = overhaul_vehicles_playerVehicles,
          parcelManager = inputs.services.parcelManager,
          vehicleTasks = inputs.services.vehicleTasks,
          employment = overhaul_career_work_employment,
        }) then
          table.insert(permissions, {permission = "forbidden", label = "Cancel current job to tow"})
          return
        end
      elseif not inputs.state.deliveryModeActive then
        -- Physical job cargo must block garage towing even if mode state is stale.
      elseif CARGO_VEHICLE_TAGS[tag] and additionalData and inputs.persistence.hasVehicleWork(additionalData.inventoryId) then
        table.insert(permissions, {permission = 'forbidden', label = 'Unload or transfer cargo, or explicitly abandon its delivery, first.'})
        return
      elseif UNRESTRICTED_TAGS[tag] then
        -- No restriction from delivery.
      elseif permissionRows[tag] then
        table.insert(permissions, {permission = permissionRows[tag], label = permissionRows.getLabel(tag)})
        return
      end
    end
  end

  return {
    onActivityAcceptGatherData = function(elemData, activityData)
      onActivityAcceptGatherData(inputs, elemData, activityData)
    end,
    onOverhaulCheckPermission = onOverhaulCheckPermission,
  }
end

return part
