-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Cargo-screen request: the cargo overview data the UI reads, published once per request.
-- Owned by career/logistics/cargoScreen.lua, which builds this part with part.new(inputs).
-- Part of the Overhaul fork of stock `lua/ge/extensions/career/modules/delivery/cargoScreen.lua`.
--
-- Map, in reading order:
--   serial: beginRequest; a snapshot that finishes after a newer request is dropped before any work
--   base payload: formatBasePayload, the skill and services panels, the level name
--   facility: publishFacility with its services, parking-spot cards and offers
--   player: publishPlayerData with formatPlayerContainer per container
--   accepted offers: publishAcceptedOffers
--   card sets: publishCardSets for filters, sorting and the confirm button
--   publish: map markers, tab, the UI payload, then the hovered-marker highlight

local part = {}

-- Built once per cargo screen load.
function part.new(inputs)
  local ext, screen = inputs.ext, inputs.screen
  local cardsById = inputs.cardsById
  -- Distances for one publish, keyed by vehicle and destination; false when the route cannot be resolved.
  local vehToLocationDistanceCache = {}

  -- Serial and snapshot ------------------------------------------------------------------------------

  -- Starts a request: a newer request makes every older snapshot stale, and the time window moves only on request.
  local function beginRequest(updateMaxTimeTimestamp)
    if screen.cargoOverviewScreenOpen then
      screen.cargoOverviewUiReady = true
    end
    screen.cargoDataRequestSerial = screen.cargoDataRequestSerial + 1
    local requestSerial = screen.cargoDataRequestSerial
    if updateMaxTimeTimestamp ~= false then
      screen.cargoOverviewMaxTimeTimestamp = ext.general.time()
      screen.cargoOverviewScreenOpenedTime = screen.cargoOverviewMaxTimeTimestamp
    end
    screen.sentNewCargoNotificationAlready = false
    return requestSerial
  end

  -- Base payload ------------------------------------------------------------------------------------

  local function logisticsBranchKey()
    local branchKey = "careerSkills"
    local progressBranch = overhaul_career_progression_skills.getBranchById(branchKey)
    if not progressBranch or progressBranch.missing then
      branchKey = "labourer"
    end
    return branchKey
  end

  -- The payload the UI always gets: the logistics skill panel, the services panel and the level name.
  local function formatBasePayload(branchKey)
    return {
      player = {
        vehicles = {},
      },
      availableSystems = {},
      settings = ext.general.getSettings(),
      facilityPanels = {
        {
          type = "skill",
          -- careerSkills-logistics is the pathId; "logistics-delivery" would pin the legacy 5-level card at max.
          skillInfo = overhaul_career_progression_skillsPage.getBranchSkillCardData("careerSkills-logistics"),
          branchId = branchKey, skillId="careerSkills-logistics",
          filterValueButtons = {'parcel','trailer','material','vehicle'},
          heading = "Logistics",
          description = 'Deliver parcels, trailers, materials, and vehicle jobs to level one unified logistics skill.',
          externalButtons = { {
            type = "progress",
            label = _tr("ui.career.cargoOverview.progress"),
            externalButtonId = 'openDeliveryProgress',
          } }
        }, {
          type = "services",
          filterValueButtons = {'loaner'},
          heading = _tr("ui.career.cargoOverview.servicesHeading"),
          description = _tr("ui.career.cargoOverview.servicesDescription"),
          externalButtons = {
            {
              type = "reputaion",
              label = _tr("ui.career.cargoOverview.viewReputationDetails"),
              externalButtonId = 'reputation',
            }
          }

        }
      },
      levelInfo = {
        name = overhaul_career_ui_uiUtils.getCareerCurrentLevelName().title
      }
    }
  end

  -- Only the containers' vehicles count: one moving vehicle above the walking pace holds the screen as "moving".
  local function anyContainerMoving(playerCargoContainers)
    local moving = false
    for _, con in ipairs(playerCargoContainers) do
      if not moving then
        local veh = scenetree.findObjectById(con.vehId)
        if veh then
          moving = veh:getVelocity():length() > 0.25
        end
      end
    end
    return moving
  end

  -- Facility -----------------------------------------------------------------------------------------

  local function formatFacilityPanel(fac)
    return {
      name = fac.name,
      longDescription = fac.facilityInformation or _tr("ui.career.cargoOverview.noFacilityInformation"),
      id = fac.id,
      preview = fac.preview,
      outgoingCargo = {},
      trailerOffers = {},
      vehicleOffers = {},
    }
  end

  -- Loaner offers for this facility, plus the loaners already spawned for the player.
  local function addLoanerCards(fac)
    if fac.hasLoanerSpots then
      local loanersFormatted = overhaul_career_logistics_loanerVehicles.formatLoanerOfferForUi(fac) or {}
      for _, item in ipairs(loanersFormatted) do
        item.cardType = "loaner"
        item.isFacilityCard = true
        inputs.addCard(item)

        if item.spawnWhenCommitingCargo then
          local copy = deepcopy(item)
          copy.isFacilityCard = false
          copy.isPlayerCard = true
          inputs.addCard(copy)
        end
      end
    end

    for _, item in ipairs(overhaul_career_logistics_loanerVehicles.formatSpawnedLoanersForUi()) do
      item.isFacilityCard = false
      item.isPlayerCard = true
      item.cardType = "loaner"
      inputs.addCard(item)
    end
  end

  -- Only a facility with an organization exposes its organization and services.
  local function addOrganizationServices(uiData, fac, organization)
    overhaul_career_career.interactWithOrganization(fac.associatedOrganization)
    uiData.facility.organization = organization
    addLoanerCards(fac)
  end

  -- Large delivery systems the facility receives are offered too, even when it does not provide them.
  local function formatAvailableSystems(fac)
    local systems = deepcopy(fac.providedSystemsLookup or {})
    systems.largeFluidDelivery = systems.largeFluidDelivery or fac.receivedSystemsLookup.largeFluidDelivery
    systems.largeDryBulkDelivery = systems.largeDryBulkDelivery or fac.receivedSystemsLookup.largeDryBulkDelivery
    systems.largeCementDelivery = systems.largeCementDelivery or fac.receivedSystemsLookup.largeCementDelivery
    systems.largeCashDelivery = systems.largeCashDelivery or fac.receivedSystemsLookup.largeCashDelivery
    return systems
  end

  -- Vehicle and trailer offers at this parking spot, split by type and shown only when the facility provides them.
  local function addFacilityOffers(uiData, fac, facId, psPath)
    local vehOffers = (not screen.cargoOverviewLoanersOnly) and (ext.vehicleOfferManager.getAllOfferAtFacilityUnexpired(facId, psPath) or {}) or {}
    local vehs, trailers = {}, {}
    for _, offer in ipairs(vehOffers) do
      if offer.data.type == "vehicle" then
        table.insert(vehs, offer)
      else
        table.insert(trailers, offer)
      end
    end
    if fac.providedSystemsLookup.vehicleDelivery then
      uiData.facility.vehicleOffers = inputs.formatVehicleOfferForUi(vehs)
    end
    if fac.providedSystemsLookup.trailerDelivery then
      uiData.facility.trailerOffers = inputs.formatVehicleOfferForUi(trailers)
    end
  end

  -- Everything tied to one parking spot: supply offers, parcels waiting here, and offers here.
  -- Returns the location that load eligibility is checked against.
  local function addParkingSpotCards(uiData, fac, facId, psPath, playerCargoContainers)
    local facPsLocation = {type = "facilityParkingspot", facId = facId, psPath = psPath}

    local passiveBusiness = overhaul_career_business_passive
    if passiveBusiness and passiveBusiness.getSupplyOfferCard then
      local supplyCard = passiveBusiness.getSupplyOfferCard(facId, psPath, playerCargoContainers)
      if supplyCard then inputs.addCard(supplyCard) end
    end
    local engineShop = overhaul_career_business_engineShop
    if engineShop and engineShop.getSupplyOfferCard then
      local engineCard = engineShop.getSupplyOfferCard(facId, psPath, playerCargoContainers)
      if engineCard then inputs.addCard(engineCard) end
    end

    local outgoingCargo = {}
    if not screen.cargoOverviewLoanersOnly then
      outgoingCargo = ext.parcelManager.getAllCargoForFacilityUnexpiredUndelivered(facId, screen.cargoOverviewScreenOpenedTime, screen.cargoOverviewMaxTimeTimestamp)
    end
    uiData.facility.outgoingCargo = inputs.clusterFormatCargo(outgoingCargo, playerCargoContainers, true)

    addFacilityOffers(uiData, fac, facId, psPath)
    return facPsLocation
  end

  -- The facility projection: the facility panel and its cards. Returns the parking-spot location, when a spot was given.
  local function publishFacility(uiData, facId, psPath, playerCargoContainers)
    local fac = ext.generator.getFacilityById(facId)
    fac.progress.interacted = true
    local organization = overhaul_world_organizations.getUIDataForOrg(fac.associatedOrganization)
    uiData.facility = formatFacilityPanel(fac)
    if organization then
      addOrganizationServices(uiData, fac, organization)
    end

    uiData.availableSystems = formatAvailableSystems(fac)

    local facPsLocation
    if psPath and psPath ~= "undefined" then
      facPsLocation = addParkingSpotCards(uiData, fac, facId, psPath, playerCargoContainers)
    end

    -- Contract offers belong to the facility, not to the parking spot used to open the screen.
    -- Loading eligibility stays tied to facPsLocation; the offer pool is always exposed.
    if (not screen.cargoOverviewLoanersOnly) and next(fac.materialStorages) then
      uiData.facility.materialStorageData = inputs.formatMaterialStorage(fac, facPsLocation, playerCargoContainers)
    end
    return facPsLocation
  end

  -- Player ------------------------------------------------------------------------------------------

  -- Task lines for the cargo a container already carries: where it goes next.
  local function labelLoadedCargo(entry)
    for _, formatted in ipairs(entry.cargo) do
      formatted.nextTasks = {{label=core_locales.contextTranslate("ui.career.delivery.cargoScreen.bringTo", {destination = formatted.destinationName}), checked = false}}
      formatted.taskList = {core_locales.contextTranslate("ui.career.delivery.cargoScreen.deliverTo", {destination = formatted.destinationName})}
    end
  end

  -- Cargo moved onto the vehicle but not yet loaded: it is loaded here if this spot is its pickup, otherwise at its own location.
  local function addTransientCargo(entry, con, facPsLocation)
    for _, formatted in ipairs(inputs.clusterFormatCargo(con.transientCargo)) do
      formatted.transientMove = true
      formatted.nextTasks = { }
      if facPsLocation and ext.parcelManager.sameLocation(formatted.location, facPsLocation) then
        formatted.nextTasks[1] = {label=_tr("ui.career.delivery.cargoScreen.loadingHere"), checked = true}
        formatted.taskList = {core_locales.contextTranslate("ui.career.delivery.cargoScreen.deliverTo", {destination = formatted.destinationName})}
      else
        formatted.nextTasks[1] = {label=core_locales.contextTranslate("ui.career.delivery.cargoScreen.loadAt", {location = formatted.locationNameLong}), checked = false}
        formatted.taskList = {core_locales.contextTranslate("ui.career.delivery.cargoScreen.pickUpAt", {location = formatted.locationNameLong})}
      end
      formatted.nextTasks[2] = {label=core_locales.contextTranslate("ui.career.delivery.cargoScreen.bringTo", {destination = formatted.destinationNameLong}), checked = false}

      table.insert(entry.cargo, formatted)
    end
  end

  -- Distance from the container's vehicle to a facility destination, cached per vehicle and destination.
  local function addCargoDistance(cargo, con)
    if cargo.destination.type == "facilityParkingspot" then
      local distanceKey = string.format("%d-%s-%s", con.vehId, cargo.destination.facId, cargo.destination.psPath)
      if vehToLocationDistanceCache[distanceKey] == nil then
        vehToLocationDistanceCache[distanceKey] = false
        local a, b = ext.generator.getLocationCoordinates(cargo.location), ext.generator.getLocationCoordinates(cargo.destination)
        if a and b then
          vehToLocationDistanceCache[distanceKey] = ext.generator.distanceBetween(a,b)
        end
      end
      cargo.distance = vehToLocationDistanceCache[distanceKey] or nil
    end
  end

  -- Every container where this cargo could be moved. Fluids and materials only mix with the same material.
  local function addCargoTargets(cargo, con, playerCargoContainers)
    cargo.targetLocations = {}
    for _, otherCon in ipairs(playerCargoContainers) do
      local isMixable = ext.generator.isMixable(cargo.materialType)
      local validTarget = true
      if not isMixable then
        for _, otherCargo in ipairs(otherCon.rawCargo) do
          validTarget = validTarget and otherCargo.materialType == cargo.materialType
        end
      end

      if validTarget and otherCon.cargoTypesLookup[cargo.type] then
        local loc = {
          label = otherCon.moveToLabel,
          location = otherCon.location,
          enabled = otherCon.freeCargoSlots >= cargo.slots,
          maxAmount = math.min(math.floor(otherCon.freeCargoSlots / cargo.slots), #cargo.ids),
          containerVehicleInfo = {
            vehId = con.vehId,
            vehName = con.vehName,
            conName = con.name,
          },
          usedCargoSlots = otherCon.usedCargoSlots,
          totalCargoSlots = otherCon.totalCargoSlots,
          selectedAmount = 0,
        }
        if con.containerId == otherCon.containerId then
          loc.maxAmount = #cargo.ids
          loc.usedCargoSlots = loc.usedCargoSlots - cargo.slots * #cargo.ids
          loc.selectedAmount = #cargo.ids
        end
        if loc.maxAmount > 0 then
          table.insert(cargo.targetLocations, loc)
        end
      end
    end
  end

  -- Cargo that was never moved from the vehicle can be thrown away for a penalty.
  local function addThrowAwayInfo(cargo)
    if not cargo.transientMove then
      cargo.throwAwayInfo = {
        penalty = cargo.rewardMoney * ext.general.getDeliveryAbandonPenaltyFactor(),
        location = {type="deleted"},
      }
    end
  end

  -- One player container: its cargo rows (loaded and in transit), the money and weight it adds, and its vehicle group.
  local function formatPlayerContainer(con, playerCargoContainers, facPsLocation, uiData, totals, hasContainersOfCargoType)
    local entry = {
      vehId = con.vehId,
      name = con.name,
      moveToLabel = con.moveToLabel,
      cargoTypesLookup = con.cargoTypesLookup,
      cargoTypesString = con.cargoTypesString,
      totalCargoSlots = con.totalCargoSlots,
      usedCargoSlots = con.usedCargoSlots,
      freeCargoSlots = con.freeCargoSlots,
      transientCargoSlots = con.transientCargoSlots,
      cargo = inputs.clusterFormatCargo(con.rawCargo, nil),
      weight = 0,
      taskList = {},
    }
    labelLoadedCargo(entry)
    addTransientCargo(entry, con, facPsLocation)

    -- player can load the cargo of this containers cargo type
    hasContainersOfCargoType[con.cargoTypesString] = true

    for _, cargo in ipairs(entry.cargo) do
      -- enable systems for this type, even if the facilitiy does not offer it
      require('overhaul/lib/logistics/cargoSemantics').enableSystem(cargo.type, uiData.availableSystems)

      totals.money = totals.money + #cargo.ids * cargo.rewardMoney
      entry.weight = entry.weight + cargo.weight * #cargo.ids

      addCargoDistance(cargo, con)
      addCargoTargets(cargo, con, playerCargoContainers)
      addThrowAwayInfo(cargo)
    end

    totals.weight = totals.weight + entry.weight

    -- containers are grouped by vehicle in the UI
    if not uiData.player.vehicles[entry.vehId] then
      uiData.player.vehicles[entry.vehId] = { containers = {}, niceName = ext.general.getVehicleName(entry.vehId), vehId = entry.vehId, hasContainersOfCargoType = {}}
    end
    uiData.player.vehicles[entry.vehId].hasContainersOfCargoType[con.cargoTypesString] = true
    table.insert(uiData.player.vehicles[entry.vehId].containers, entry)
  end

  -- Vehicle groups as a list, sorted by vehicle id for a stable order in the UI.
  local function vehicleGroupList(vehicleGroups)
    local vehicleInfoList = {}
    for _, vehicleInfo in pairs(vehicleGroups) do
      table.insert(vehicleInfoList, vehicleInfo)
    end
    table.sort(vehicleInfoList, function(a,b) return a.vehId < b.vehId end)
    return vehicleInfoList
  end

  -- The player projection: every container, its totals and its vehicle groups.
  local function publishPlayerData(uiData, playerCargoContainers, facPsLocation)
    local totals = {money = 0, weight = 0}
    table.clear(vehToLocationDistanceCache)
    local hasContainersOfCargoType = {}

    for _, con in ipairs(playerCargoContainers) do
      formatPlayerContainer(con, playerCargoContainers, facPsLocation, uiData, totals, hasContainersOfCargoType)
    end

    uiData.player.loadedCargoMoneySum = totals.money
    uiData.player.penaltyForAbandon = ext.general.getDeliveryModePenalty()
    uiData.player.weightSum = totals.weight
    uiData.player.noContainers = not next(playerCargoContainers)
    uiData.player.hasContainersOfCargoType = hasContainersOfCargoType
    uiData.player.vehicles = vehicleGroupList(uiData.player.vehicles)
  end

  -- Accepted offers ---------------------------------------------------------------------------------

  -- Accepted offers and owner-operator jobs are cards too, and they enable their delivery systems.
  local function publishAcceptedOffers(uiData)
    inputs.addActiveOwnerOpMyCargoCards()
    uiData.player.acceptedOffers = inputs.getAcceptedVehicleOffers()
    for _, offer in ipairs(uiData.player.acceptedOffers) do
      if offer.type == "vehicle" then
        uiData.availableSystems.vehicleDelivery = true
      end
      if offer.type == "trailer" then
        uiData.availableSystems.trailerDelivery = true
      end
    end
    if inputs.getActiveOwnerOpContract() then
      uiData.availableSystems.vehicleDelivery = true
    end
  end

  -- Card sets ---------------------------------------------------------------------------------------

  -- Filters, sorting and the confirm button, built from the card store after every card is in.
  local function publishCardSets(uiData, playerCargoContainers)
    local cargoCards = overhaul_career_logistics_cargoCards
    uiData.cardsById = cardsById
    uiData.filterSets = cargoCards.resetFilterCounters()

    uiData.sortingSets = cargoCards.getCardSortingSetsByKey(cardsById)
    uiData.facilityCardGroupSets = cargoCards.getCardGroupSetsByKey(cardsById, false)
    uiData.playerCardGroupSets = cargoCards.getCardGroupSetsByKey(cardsById, true, playerCargoContainers)

    cargoCards.addSortingValuesToGroups(cardsById, uiData.facilityCardGroupSets)
    cargoCards.addSortingValuesToGroups(cardsById, uiData.playerCardGroupSets)

    uiData.filterSets = cargoCards.getFilterSets(cardsById)

    cargoCards.addFilterPlayerData(uiData.filterSets, uiData.playerCardGroupSets, playerCargoContainers)

    uiData.confirmButtonInfo = cargoCards.getConfirmButtonFromPlayerCards(uiData.cardsById)
  end

  -- Publish -----------------------------------------------------------------------------------------

  -- The publish projection: map markers and the tab first, then the UI payload, then the highlight for the hovered marker.
  local function publish(uiData)
    inputs.setVisibleIdsForBigMap()
    inputs.setCargoScreenTab(screen.cargoOverviewTab)
    guihooks.trigger("cargoDataForUiReady", uiData)
    inputs.highlightCargoInPoi(freeroam_bigMapMode.selectedPoiId)
  end

  -- Gets all offers and player cargo, depending on supplied facId and psPath. A stale snapshot publishes nothing.
  local function requestCargoDataForUi(facId, psPath, updateMaxTimeTimestamp)
    local requestSerial = beginRequest(updateMaxTimeTimestamp)
    ext.general.getNearbyVehicleCargoContainers(function(playerCargoContainers)
      if requestSerial ~= screen.cargoDataRequestSerial then return end
      local uiData = formatBasePayload(logisticsBranchKey())
      uiData.player.isMoving = anyContainerMoving(playerCargoContainers)

      table.clear(cardsById)
      screen.cardId = 0
      local facPsLocation
      if facId and facId ~= "undefined" then
        facPsLocation = publishFacility(uiData, facId, psPath, playerCargoContainers)
      end
      publishPlayerData(uiData, playerCargoContainers, facPsLocation)
      publishAcceptedOffers(uiData)
      publishCardSets(uiData, playerCargoContainers)
      publish(uiData)
    end)
  end

  -- Notifies the screen once per open, when cargo appears at the facility or parking spot it is showing.
  local function onOverhaulCargoGenerated(cargo)
    if not screen.cargoOverviewScreenOpen then return end
    if screen.sentNewCargoNotificationAlready then return end
    if not screen.cargoScreenFacId then return end
    if cargo.origin.facId ~= screen.cargoScreenFacId then return end
    if screen.cargoScreenPsPath and cargo.origin.psPath ~= screen.cargoScreenPsPath then return end
    screen.sentNewCargoNotificationAlready = true
    guihooks.trigger("newCargoAvailable")
  end

  return {
    bindNavigation = function(navigation)
      inputs.setVisibleIdsForBigMap = navigation.setVisibleIdsForBigMap
      inputs.highlightCargoInPoi = navigation.highlightCargoInPoi
    end,
    onOverhaulCargoGenerated = onOverhaulCargoGenerated,
    requestCargoDataForUi = requestCargoDataForUi,
  }
end

return part
