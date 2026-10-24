-- Shopping and purchase screens, navigation and route cleanup for one shopping instance.
-- Read shopping projections and routes, purchase projections, inspection and navigation, then cleanup.
local M = {}

local ROUTE_SHOPPING = "overhaul.computer.vehicleShopping"
local ROUTE_VEHICLE_LIST = "overhaul.computer.vehicleShopping.vehicles"
local PRIVATE_SELLER_ID = "private"
local POLICE_MESSAGE_SECONDS = 8
local MAX_LOGGED_SHOP_IDS = 5

local REQUIRED_BINDINGS = {
  "applyPurchaseAdjustedMarketValue",
  "collectOrganizationsForUi",
  "convertKeysToStrings",
  "discoverDealer",
  "ensureNegotiationPersonality",
  "getDealershipForSellerId",
  "getDeliveryDelay",
  "getPoliceDealershipLockLabel",
  "getSellerAccessInfo",
  "getUiDealershipsData",
  "getVehicleInfoByShopId",
  "isCarMeetShopVehicle",
  "isDealerDiscovered",
  "isOnlineSellerId",
  "isPoliceDealershipLocked",
  "sanitizeVehicleForUi",
  "fleet.rtFleetCap",
  "purchase.awardCarMeetPurchase",
  "purchase.computePurchaseTaxAndFinalPrice",
  "purchase.getDeliveryGarages",
  "purchase.getDeliveryOrigin",
  "purchase.hasInventorySlotForPurchase",
  "spawn.completeFreightPickup",
  "stock.updateVehicleList",
  "validation.coerceVehiclePricingFields",
}

local function resolveBinding(bindings, path)
  local value = bindings
  for key in path:gmatch("[^.]+") do value = value[key] end
  return value
end

function M.new(inputs)
  local dependencies = {}
  local state = inputs.state
  local shoppingConfig = inputs.config
  local travelQuotes = require("overhaul/career/market/vehicleShopping/travelQuotes").new {
    cellSize = shoppingConfig.travelQuoteCellSize,
    getOrigin = function()
      local player = getPlayerVehicle(0)
      return player and player:getPosition()
    end,
    getContext = function()
      return getCurrentLevelIdentifier() .. ':' .. tostring(overhaul_career_economy_globalEconomy.getGlobalIndex())
    end,
    getDestination = function(vehicle)
      if not vehicle.pos then return nil end
      if vehicle.sellerId == PRIVATE_SELLER_ID then return vehicle.pos end
      -- Dealer stock shares the first listing's destination, matching the original seller quote.
      for _, listing in ipairs(state.vehiclesInShop) do
        if listing.sellerId == vehicle.sellerId and listing.pos then return listing.pos end
      end
      return vehicle.pos
    end,
    quote = function(pos) return overhaul_career_garage_quickTravel.getPriceForQuickTravel(pos) end,
  }

  -- Shared helpers ------------------------------------------------------------------------------

  local function announcePoliceLock(dealershipId)
    ui_message(dependencies.getPoliceDealershipLockLabel(dealershipId), POLICE_MESSAGE_SECONDS, "Police", "info")
  end

  local function policeLockReason(policeLocked, dealershipId)
    return policeLocked and dependencies.getPoliceDealershipLockLabel(dealershipId) or nil
  end

  local function businessBalance(businessType, businessId)
    local account = overhaul_career_economy_bank.getBusinessAccount(businessType, businessId)
    return tonumber(account and account.balance) or tonumber(account and account.balanceMoney)
      or tonumber(account and account.money) or 0
  end

  local function fleetVehicleCount(businessId)
    return #(overhaul_career_business_fleet.getBusinessVehicles(businessId) or {})
  end

  local function navigateToVehicleListOrShopping(sellerId, vehicleListParams)
    if sellerId then
      extensions.ui_router.navigate(ROUTE_VEHICLE_LIST, vehicleListParams(sellerId))
    else
      extensions.ui_router.navigate(ROUTE_SHOPPING)
    end
  end

  -- The selected sellerId travels with the route, so focus returns to its card and reload restores it.
  local function vehicleListParams(sellerId)
    sellerId = sellerId or state.selectedSellerId
    if type(sellerId) ~= "string" or sellerId == "" then return nil end
    return { sellerId = sellerId }
  end

  local function clearFleetContext()
    state.rtBizId = nil
    state.fleetBusinessType = "racingTeam"
  end

  local function endShopping()
    overhaul_career_career.closeAllMenus()
    extensions.hook("onOverhaulVehicleShoppingMenuClosed", {})
  end

  local function cancelShopping()
    if state.originComputerId then
      local computer = overhaul_world_facilities.getFacility("computer", state.originComputerId)
      overhaul_career_garage_computer.openMenu(computer)
    else
      overhaul_career_career.closeAllMenus()
    end
  end

  -- Shopping data -------------------------------------------------------------------------------

  local function removeCarMeetListings(listings)
    for index = #listings, 1, -1 do
      if dependencies.isCarMeetShopVehicle(listings[index]) then table.remove(listings, index) end
    end
  end

  local function addRacingTeamContext(data)
    data.racingTeamBusinessId = state.rtBizId
    data.racingTeamBusinessMoney = businessBalance(state.fleetBusinessType, state.rtBizId)
    data.fleetBusinessType = state.fleetBusinessType
    local vehicleCount = fleetVehicleCount(state.rtBizId)
    local capacity = dependencies.fleet.rtFleetCap(state.rtBizId)
    data.inventoryHasFreeSlot = vehicleCount < capacity
    data.numberOfFreeSlots = math.max(0, capacity - vehicleCount)
    -- Racing-team shop: do not expose the personal wallet in playerAttributes (the UI uses racingTeamBusinessMoney).
    data.playerPersonalMoneyForTaxi = overhaul_career_economy_playerAttributes.getAttributeValue("money")
    if not data.playerAttributes then return end
    data.playerAttributes = deepcopy(data.playerAttributes)
    if type(data.playerAttributes.money) == "table" then
      data.playerAttributes.money = deepcopy(data.playerAttributes.money)
      data.playerAttributes.money.value = nil
    else
      data.playerAttributes.money = nil
    end
  end

  local function addPlayerInventoryContext(data)
    data.inventoryHasFreeSlot = overhaul_career_garage_inventory.hasFreeSlot()
    data.numberOfFreeSlots = overhaul_career_garage_inventory.getNumberOfFreeSlots()
  end

  local function addShoppingPermission(data)
    local status = overhaul_career_permissions.getStatusForTag("vehicleShopping")
    data.disableShopping = not status.allow
    if status.permission ~= "allowed" then
      data.disableShoppingReason = status.label or _tr("ui.career.vehicleShopping.disableReason.notAllowed")
    end
  end

  local function dealershipCard(dealer, policeLocked, discovered, accessInfo)
    return {
      id = dealer.id,
      name = dealer.name,
      description = dealer.description,
      location = dealer.location,
      preview = dealer.preview,
      hiddenFromDealerList = dealer.hiddenFromDealerList or policeLocked or not discovered,
      undiscovered = not discovered,
      salesChannel = accessInfo.salesChannel,
      remotePurchaseAllowed = accessInfo.remotePurchaseAllowed,
      garageDeliveryAllowed = accessInfo.garageDeliveryAllowed,
      deliveryDiscount = accessInfo.deliveryDiscount,
      associatedOrganization = dealer.associatedOrganization,
      disabled = policeLocked,
      disabledReason = policeLockReason(policeLocked, dealer.id),
    }
  end

  local function privateSellerCard(seller, policeLocked)
    return {
      id = seller.id,
      name = seller.name,
      description = seller.description,
      location = seller.location,
      preview = seller.preview,
      hiddenFromDealerList = seller.hiddenFromDealerList or policeLocked,
      associatedOrganization = seller.associatedOrganization,
      disabled = policeLocked,
      disabledReason = policeLockReason(policeLocked, seller.id),
    }
  end

  local function addDealerships(data, facilities)
    data.dealerships = {}
    data.dealershipDiscovery = { discovered = 0, total = 0 }
    data.organizations = dependencies.collectOrganizationsForUi(facilities)
    for _, dealer in ipairs(facilities and facilities.dealerships or {}) do
      local policeLocked = dependencies.isPoliceDealershipLocked(dealer.id)
      local discovered = dependencies.isDealerDiscovered(dealer)
      local accessInfo = dependencies.getSellerAccessInfo(dealer)
      -- Count every listable dealer, online and always-visible ones included, so the header matches the cards.
      data.dealershipDiscovery.total = data.dealershipDiscovery.total + 1
      if discovered then data.dealershipDiscovery.discovered = data.dealershipDiscovery.discovered + 1 end
      table.insert(data.dealerships, dealershipCard(dealer, policeLocked, discovered, accessInfo))
    end
    for _, seller in ipairs(facilities and facilities.privateSellers or {}) do
      table.insert(data.dealerships, privateSellerCard(seller, dependencies.isPoliceDealershipLocked(seller.id)))
    end
  end

  -- Listings persist across sessions, so reputation-driven access is copied onto every existing card.
  local function copySellerAccessOntoListings(data)
    for _, vehicleInfo in ipairs(data.vehiclesInShop) do
      for _, dealership in ipairs(data.dealerships) do
        if dealership.id == vehicleInfo.sellerId then
          vehicleInfo.salesChannel = dealership.salesChannel
          vehicleInfo.remotePurchaseAllowed = dealership.remotePurchaseAllowed
          vehicleInfo.garageDeliveryAllowed = dealership.garageDeliveryAllowed
          vehicleInfo.deliveryDiscount = dealership.deliveryDiscount
          break
        end
      end
    end
  end

  local function sanitizedListings(listings)
    local sanitized = {}
    for _, vehicleInfo in ipairs(listings) do
      table.insert(sanitized, dependencies.sanitizeVehicleForUi(vehicleInfo))
    end
    return sanitized
  end

  -- Use the same seller records as the picker, including private and authored seller kinds.
  -- Listing-only sellers (for example event stock) retain their published seller identity.
  local function addCurrentSeller(data)
    if not data.currentSeller then return end
    local seller
    for _, record in ipairs(data.dealerships) do
      if record.id == data.currentSeller then seller = record; break end
    end
    if not seller then
      for _, listing in ipairs(data.vehiclesInShop) do
        if listing.sellerId == data.currentSeller then
          seller = {name = listing.sellerName}
          break
        end
      end
    end
    data.currentSellerNiceName = seller and seller.name or data.currentSeller
    data.currentSellerDescription = seller and seller.description
    data.currentSellerLocation = seller and seller.location
  end

  local function getShoppingData()
    local data = {}
    local unsoldVehicles, soldVehicles = dependencies.convertKeysToStrings(state.vehiclesInShop)
    removeCarMeetListings(unsoldVehicles)
    removeCarMeetListings(soldVehicles)
    for _, vehicleInfo in ipairs(unsoldVehicles) do dependencies.applyPurchaseAdjustedMarketValue(vehicleInfo) end
    for _, vehicleInfo in ipairs(soldVehicles) do dependencies.applyPurchaseAdjustedMarketValue(vehicleInfo) end
    data.vehiclesInShop = unsoldVehicles
    data.soldVehicles = soldVehicles
    data.uiDealershipsData = dependencies.getUiDealershipsData(unsoldVehicles)
    data.currentSeller = state.currentSeller
    data.selectedSellerId = state.selectedSellerId
    data.screenTag = state.shoppingScreenTag
    data.buyingAvailable = state.buyingAvailable
    data.marketplaceAvailable = state.marketplaceAvailable
    data.playerAttributes = overhaul_career_economy_playerAttributes.getAllAttributes()
    if state.rtBizId then addRacingTeamContext(data) else addPlayerInventoryContext(data) end
    data.cheatsMode = overhaul_career_economy_cheats.isCheatsMode() or false
    data.dealershipPurchaseReputationGain = shoppingConfig.dealershipPurchaseReputationGain
    data.tutorialPurchase = (not overhaul_career_career.hasBoughtStarterVehicle()) or nil
    data.hasboughtStarterVehicle = overhaul_career_career.hasBoughtStarterVehicle()
    addShoppingPermission(data)
    addDealerships(data, overhaul_world_facilities.getFacilities(getCurrentLevelIdentifier()))
    addCurrentSeller(data)
    copySellerAccessOntoListings(data)
    -- Strip vec3 userdata so the phone can read stock before the computer sends a sanitized delta.
    data.vehiclesInShop = sanitizedListings(data.vehiclesInShop)
    data.soldVehicles = sanitizedListings(data.soldVehicles)
    return data
  end

  local function sendShoppingDataToUI()
    guihooks.trigger("vehicleShoppingData", getShoppingData())
  end

  -- Shopping screens and navigation ---------------------------------------------------------------

  local function requestVehicleTravelQuotes(shopIds)
    local vehicles = {}
    for _, shopId in ipairs(shopIds or {}) do
      local vehicle = dependencies.getVehicleInfoByShopId(shopId)
      if vehicle then vehicles[#vehicles + 1] = vehicle end
    end
    travelQuotes.request(vehicles, true)
  end

  local function updateTravelQuotes(dtReal)
    if not state.uiOpen then return end
    local updates = travelQuotes.update(dtReal)
    if #updates > 0 then guihooks.trigger("vehicleShopDelta", {updated = updates}) end
  end

  local function getListing(shopId)
    local vehicle = dependencies.getVehicleInfoByShopId(shopId)
    if not vehicle or dependencies.isCarMeetShopVehicle(vehicle) then return nil end
    dependencies.applyPurchaseAdjustedMarketValue(vehicle)
    local listing = dependencies.sanitizeVehicleForUi(vehicle, true)
    local dealer = dependencies.getDealershipForSellerId(vehicle.sellerId)
    if dealer then
      local access = dependencies.getSellerAccessInfo(dealer)
      listing.salesChannel = access.salesChannel
      listing.remotePurchaseAllowed = access.remotePurchaseAllowed
      listing.garageDeliveryAllowed = access.garageDeliveryAllowed
      listing.deliveryDiscount = access.deliveryDiscount
    end
    return listing
  end

  local function startSellerTether()
    local dealership = overhaul_world_facilities.getFacility("dealership", state.currentSeller)
    local tetherPosition
    if dealership then
      tetherPosition = overhaul_world_facilities.getAverageDoorPositionForFacility(dealership)
    else
      for _, vehicleInfo in ipairs(state.vehiclesInShop) do
        if vehicleInfo.sellerId == state.currentSeller and vehicleInfo.pos then
          tetherPosition = vehicleInfo.pos
          break
        end
      end
    end
    if tetherPosition then
      state.tether = overhaul_career_maintenance_tether.startSphereTether(tetherPosition, shoppingConfig.tetherRange, endShopping)
    end
  end

  -- Returns the origin computer facility, if the shop was opened from one.
  local function startShoppingTether()
    if state.currentSeller then
      startSellerTether()
      return nil
    end
    if not state.originComputerId then return nil end
    local computer = overhaul_world_facilities.getFacility("computer", state.originComputerId)
    state.tether = overhaul_career_maintenance_tether.startDoorTether(computer.doors[1], nil, endShopping)
    return computer
  end

  -- TODO At this point, the part conditions of the previous vehicle should have already been saved. for example when entering the garage
  local function openShop(seller, originComputerId, screenTag)
    if seller and dependencies.isPoliceDealershipLocked(seller) then
      announcePoliceLock(seller)
      return
    end
    if seller then dependencies.discoverDealer(seller) end
    clearFleetContext()
    state.currentSeller = seller
    state.originComputerId = originComputerId
    if not overhaul_career_market_inspectVehicle.getSpawnedVehicleInfo() then
      dependencies.stock.updateVehicleList()
    end
    travelQuotes.cancel()
    for _, vehicleInfo in ipairs(state.vehiclesInShop) do
      vehicleInfo.distance = nil
      if not vehicleInfo.pos then vehicleInfo.distance = 0 end
      vehicleInfo.quickTravelPrice = nil
    end
    -- Distance sorting can need every quote; spread those routes across updates.
    travelQuotes.request(state.vehiclesInShop)
    local computer = startShoppingTether()
    state.shoppingScreenTag = screenTag
    state.buyingAvailable = (not computer or computer.functions.vehicleShop) and true or false
    state.marketplaceAvailable = (overhaul_career_career.hasBoughtStarterVehicle() and not state.currentSeller) and true or false
    state.selectedSellerId = state.currentSeller
    navigateToVehicleListOrShopping(state.currentSeller, vehicleListParams)
    extensions.hook("onOverhaulVehicleShoppingMenuOpened", { seller = state.currentSeller })
  end

  local function isAtSeller(vehicleInfo)
    -- Closing the shop may clear currentSeller before the inspection job runs.
    return vehicleInfo ~= nil and state.currentSeller ~= nil and vehicleInfo.sellerId == state.currentSeller
  end

  local function startInspectionWorkitem(job, vehicleInfo, teleportToVehicle, atSeller)
    if dependencies.isOnlineSellerId(vehicleInfo and vehicleInfo.sellerId) then return end
    ui_fadeScreen.start(0.5)
    job.sleep(1.0)
    extensions.ui_router.navigate("play")
    local success, reason = overhaul_career_market_inspectVehicle.startInspection(vehicleInfo, teleportToVehicle, job, atSeller == true)
    if not success then
      ui_fadeScreen.stop(0.5)
      if reason ~= "travelFailed" then
        guihooks.trigger("toastrMsg", {
          type = "error",
          title = _tr("ui.career.inspectVehicle.message.spawnFailed"),
        })
      end
      return
    end
    job.sleep(0.5)
    ui_fadeScreen.stop(0.5)
    job.sleep(1.0)
    state.inspectingVehicleShopId = vehicleInfo.shopId
    extensions.hook("onOverhaulVehicleShoppingVehicleShown", { vehicleInfo = vehicleInfo })
  end

  local function queueInspection(vehicleInfo, teleportToVehicle)
    core_jobsystem.create(startInspectionWorkitem, nil, vehicleInfo, teleportToVehicle, isAtSeller(vehicleInfo))
  end

  local function navigateToPos(pos, shopId)
    if shopId then
      local vehicleInfo = dependencies.getVehicleInfoByShopId(shopId)
      if not vehicleInfo then
        log("E", "Career", "Failed to find vehicle for inspection with shopId: " .. tostring(shopId))
        return
      end
      if dependencies.isOnlineSellerId(vehicleInfo.sellerId) then return end
      if not pos then return end
      core_groundMarkers.setPath(vec3(pos.x, pos.y, pos.z))
      queueInspection(vehicleInfo, false)
      return
    end
    if not pos then return end
    core_groundMarkers.setPath(vec3(pos.x, pos.y, pos.z))
    extensions.ui_router.navigate("play")
  end

  -- Returns the dealership and its door position, or nothing when the dealer cannot be visited.
  local function visitableDealership(dealershipId)
    if dependencies.isPoliceDealershipLocked(dealershipId) then
      announcePoliceLock(dealershipId)
      return nil
    end
    if dependencies.isOnlineSellerId(dealershipId) then return nil end
    local dealership = overhaul_world_facilities.getDealership(dealershipId)
    if not dealership then return nil end
    local position = overhaul_world_facilities.getAverageDoorPositionForFacility(dealership)
    if not position then return nil end
    return dealership, position
  end

  local function navigateToDealership(dealershipId)
    local _, position = visitableDealership(dealershipId)
    if position then navigateToPos(position) end
  end

  -- Returns where the taxi should face, plus the first spot's rotation.
  local function parkingLookTarget(dealership, doorPosition)
    local parkingSpots = overhaul_world_facilities.getParkingSpotsForFacility(dealership)
    if not (parkingSpots and parkingSpots[1]) then return doorPosition, nil end
    local center, count = vec3(0, 0, 0), 0
    for _, spot in ipairs(parkingSpots) do
      if spot.pos then
        center = center + spot.pos
        count = count + 1
      end
    end
    return count > 0 and center / count or doorPosition, parkingSpots[1].rot
  end

  local function taxiToDealership(dealershipId)
    local dealership, position = visitableDealership(dealershipId)
    if not position then return end
    local lookAt, spotRotation = parkingLookTarget(dealership, position)
    overhaul_career_garage_quickTravel.quickTravelToPos(position, true,
      string.format("Took a taxi to %s", dealership.name or "dealership"), spotRotation, lookAt)
    -- At the racing team lot, scope shopping to this seller so inspect and instant buys match in-person flow.
    if state.rtBizId then
      state.currentSeller = dealershipId
      state.originComputerId = nil
    end
  end

  local function getTaxiPriceToDealership(dealershipId)
    if dependencies.isPoliceDealershipLocked(dealershipId) then return 0 end
    if dependencies.isOnlineSellerId(dealershipId) then return 0 end
    local dealership = overhaul_world_facilities.getDealership(dealershipId)
    if not dealership then
      log("W", "Career", "getTaxiPriceToDealership: Dealership not found: " .. tostring(dealershipId))
      return 0
    end
    local position = overhaul_world_facilities.getAverageDoorPositionForFacility(dealership)
    if not position then
      log("W", "Career", "getTaxiPriceToDealership: No position found for dealership: " .. tostring(dealershipId))
      return 0
    end
    return overhaul_career_garage_quickTravel.getPriceForQuickTravel(position) or 0
  end

  local function requestExit()
    if not state.rtBizId then return cancelShopping() end
    local businessId = state.rtBizId
    state.rtBizId = nil
    state.currentSeller = nil
    state.originComputerId = nil
    state.selectedSellerId = nil
    return extensions.ui_router.navigate("business-computer", {
      businessType = state.fleetBusinessType,
      businessId = tostring(businessId),
    })
  end

  -- Restore the seller from route params before mount, so a reload or deep link skips the seller grid.
  local function onRouteEnter(_, toRoute, fromRoute, data)
    local sellerId = toRoute and toRoute.params and toRoute.params.sellerId
    if type(sellerId) == "string" and sellerId ~= "" then
      state.selectedSellerId = sellerId
    end
  end

  local function onRouteMount(context, toRoute, fromRoute, data)
    sendShoppingDataToUI()
  end

  local function selectSeller(sellerId)
    if type(sellerId) ~= "string" or sellerId == "" then return end
    if dependencies.isPoliceDealershipLocked(sellerId) then
      announcePoliceLock(sellerId)
      return
    end
    local dealership = dependencies.getDealershipForSellerId(sellerId)
    if dealership and not dependencies.isDealerDiscovered(dealership) then return end
    state.selectedSellerId = sellerId
    extensions.hook("onOverhaulVehicleShoppingSelectedSellerIdChanged", sellerId)
    sendShoppingDataToUI()
    return extensions.ui_router.navigate(ROUTE_VEHICLE_LIST, vehicleListParams(sellerId))
  end

  local function clearSelectedSeller()
    state.selectedSellerId = nil
    extensions.hook("onOverhaulVehicleShoppingSelectedSellerIdChanged", nil)
  end

  local function requestVehicleListExit()
    if state.currentSeller then return cancelShopping() end
    clearSelectedSeller()
    return extensions.ui_router.navigate(ROUTE_SHOPPING)
  end

  local function getSelectedSellerBreadcrumbTitle()
    if not state.selectedSellerId then return nil end
    if state.selectedSellerId == PRIVATE_SELLER_ID then
      return _tr("ui.career.vehicleShopping.privateSellers")
    end
    local dealership = overhaul_world_facilities.getDealership(state.selectedSellerId)
    if dealership and dealership.name then return _tr(dealership.name) end
    return nil
  end

  local function onShoppingMenuClosed()
    if state.tether then
      state.tether.remove = true
      state.tether = nil
    end
    state.inspectingVehicleShopId = nil
    state.purchaseMenuOpen = false
    state.currentSeller = nil
    state.originComputerId = nil
  end

  local function getVehiclesInShop()
    return state.vehiclesInShop
  end

  local function removeUnusedPlayerVehicles()
    for inventoryId in pairs(overhaul_career_garage_inventory.getMapInventoryIdToVehId()) do
      if inventoryId ~= overhaul_career_garage_inventory.getCurrentVehicle() then
        overhaul_career_garage_inventory.removeVehicleObject(inventoryId)
      end
    end
  end

  -- Purchase screen -----------------------------------------------------------------------------

  -- A completed or withdrawn purchase leaves nothing to show; return to the vehicle list.
  local function leaveUnavailablePurchase()
    ui_message("This purchase is no longer available. Please select a vehicle again.", 6, "vehicleShopping")
    navigateToVehicleListOrShopping(state.selectedSellerId, vehicleListParams)
  end

  -- Returns nil (after logging) when the listing is gone.
  local function purchaseVehicleInfo(purchaseData)
    local listing = dependencies.getVehicleInfoByShopId(purchaseData.shopId)
    local negotiable = listing and listing.negotiationPossible ~= false
      and (listing.discountPercentage or 0) <= 0
      and dependencies.ensureNegotiationPersonality(listing) ~= nil
    local vehicleInfo = deepcopy(listing)
    if not vehicleInfo then
      log("E", "Career", "sendPurchaseDataToUi: Vehicle not found for shopId: " .. tostring(purchaseData.shopId))
      return nil
    end
    vehicleInfo.shopId = purchaseData.shopId
    -- Project availability without making a temporary missing source permanent in saved stock.
    vehicleInfo.negotiationPossible = negotiable == true
    vehicleInfo.niceName = vehicleInfo.Brand .. " " .. vehicleInfo.Name
    vehicleInfo.deliveryDelay = dependencies.getDeliveryDelay(vehicleInfo.distance)
    dependencies.applyPurchaseAdjustedMarketValue(vehicleInfo)
    vehicleInfo.Value = vehicleInfo.valueAdjusted or vehicleInfo.Value
    dependencies.validation.coerceVehiclePricingFields(vehicleInfo)
    return vehicleInfo
  end

  local function chooseDefaultInsurance(purchaseData, vehicleInfo)
    if vehicleInfo.source == "carMeet" then
      purchaseData.insuranceId = -1
      return
    end
    if purchaseData.insuranceId then return end
    if not (vehicleInfo.insuranceClass and vehicleInfo.insuranceClass.id) then return end
    local defaultInsurance = overhaul_career_repair_insurance.getDefaultInsuranceForClassId(vehicleInfo.insuranceClass.id)
    if defaultInsurance then purchaseData.insuranceId = defaultInsurance.id end
  end

  local function buildInsuranceOptions(purchaseData)
    local options = { insuranceId = purchaseData.insuranceId, shopId = purchaseData.shopId }
    if purchaseData.insuranceId and purchaseData.insuranceId >= 0 then
      local insuranceInfo = overhaul_career_repair_insurance.getInsuranceDataById(purchaseData.insuranceId)
      if insuranceInfo then
        options.name = insuranceInfo.name
        options.spendingReason = string.format("Insurance Policy: \"%s\"", insuranceInfo.name)
        options.priceMoney = overhaul_career_repair_insurance.calculateAddVehiclePrice(purchaseData.insuranceId, purchaseData.vehicleInfo.Value)
      end
    end
    return options
  end

  local function testDriveDamageFee()
    if not (overhaul_career_market_inspectVehicle.getDidTestDrive() and overhaul_career_market_inspectVehicle.isTestDriveDamageDetected()) then
      return 0
    end
    return tonumber(overhaul_career_repair_insurance.getTestDriveClaimPrice()) or 0
  end

  local function buildPurchaseData(purchaseData, vehicleInfo, businessId)
    local playerMoney = overhaul_career_economy_playerAttributes.getAttributeValue("money")
    local racingTeamBusinessMoney = nil
    local inventoryHasFreeSlot = dependencies.purchase.hasInventorySlotForPurchase()
    if businessId then
      local fleetType = purchaseData.fleetBusinessType or state.fleetBusinessType
      racingTeamBusinessMoney = businessBalance(fleetType, businessId)
      inventoryHasFreeSlot = fleetVehicleCount(businessId) < dependencies.fleet.rtFleetCap(businessId)
    end
    local damageFee = testDriveDamageFee()
    return {
      vehicleInfo = purchaseData.vehicleInfo,
      playerMoney = playerMoney,
      racingTeamBusinessMoney = racingTeamBusinessMoney,
      racingTeamFleetPurchase = businessId ~= nil,
      inventoryHasFreeSlot = inventoryHasFreeSlot,
      garageAvailability = overhaul_career_garage_garageManager.getGarageAvailabilityReason() or "ok",
      purchaseType = purchaseData.purchaseType,
      forceTradeIn = (not businessId) and (not overhaul_career_career.hasBoughtStarterVehicle()) or nil,
      tradeInVehicleInfo = purchaseData.tradeInVehicleInfo,
      prices = purchaseData.prices,
      dealershipId = vehicleInfo.sellerId,
      alreadyDidTestDrive = overhaul_career_market_inspectVehicle.getDidTestDrive() or false,
      vehId = purchaseData.vehId,
      cheatsMode = overhaul_career_economy_cheats.isCheatsMode() or false,
      insuranceOptions = purchaseData.insuranceOptions,
      testDriveDamageFee = damageFee,
    }
  end

  local function addDeliveryAccess(data, vehicleInfo)
    local dealership = dependencies.getDealershipForSellerId(vehicleInfo.sellerId)
    local accessInfo = dependencies.getSellerAccessInfo(dealership or vehicleInfo)
    local _, freightReason = dependencies.purchase.getDeliveryOrigin(dealership)
    data.salesChannel = accessInfo.salesChannel
    data.remotePurchaseAllowed = accessInfo.remotePurchaseAllowed
    data.garageDeliveryAllowed = accessInfo.garageDeliveryAllowed
    data.deliveryDiscount = accessInfo.deliveryDiscount
    data.deliveryGarages = dependencies.purchase.getDeliveryGarages(dealership)
    data.freightAvailable = not accessInfo.isOnline or freightReason == nil
    data.freightUnavailableReason = accessInfo.isOnline and freightReason or nil
    return accessInfo
  end

  local function addPurchaseOptions(data, purchaseData, vehicleInfo, accessInfo, businessId)
    local atDealership = (purchaseData.purchaseType == "instant" and state.currentSeller)
      or (purchaseData.purchaseType == "inspect" and vehicleInfo.sellerId ~= PRIVATE_SELLER_ID)
    local notCarMeet = vehicleInfo.source ~= "carMeet"
    if atDealership and not businessId and notCarMeet then data.tradeInEnabled = true end
    local canChooseLocation = atDealership or accessInfo.isOnline or accessInfo.remotePurchaseAllowed
      or vehicleInfo.sellerId == PRIVATE_SELLER_ID
    if canChooseLocation and notCarMeet then data.locationSelectionEnabled = true end
    if not overhaul_career_career.hasBoughtStarterVehicle() then data.forceNoDelivery = true end
  end

  local function sendPurchaseDataToUi()
    local purchaseData = state.purchaseData
    if not purchaseData then
      leaveUnavailablePurchase()
      return
    end
    local businessId = purchaseData.racingTeamBusinessId or state.rtBizId
    local vehicleInfo = purchaseVehicleInfo(purchaseData)
    if not vehicleInfo then return end
    purchaseData.vehicleInfo = vehicleInfo

    local tradeInValue = purchaseData.tradeInVehicleInfo and purchaseData.tradeInVehicleInfo.Value or 0
    local taxes, finalPrice = dependencies.purchase.computePurchaseTaxAndFinalPrice(vehicleInfo, tradeInValue)
    purchaseData.prices = { fees = vehicleInfo.fees, taxes = taxes, finalPrice = finalPrice, customLicensePlate = shoppingConfig.customLicensePlatePrice }
    local spawnedVehicleInfo = overhaul_career_market_inspectVehicle.getSpawnedVehicleInfo()
    purchaseData.vehId = spawnedVehicleInfo and spawnedVehicleInfo.vehId
    chooseDefaultInsurance(purchaseData, vehicleInfo)
    purchaseData.insuranceOptions = buildInsuranceOptions(purchaseData)

    local data = buildPurchaseData(purchaseData, vehicleInfo, businessId)
    local accessInfo = addDeliveryAccess(data, vehicleInfo)
    data.ownsRequiredInsurance = false
    addPurchaseOptions(data, purchaseData, vehicleInfo, accessInfo, businessId)
    guihooks.trigger("vehiclePurchaseData", data)
  end

  local function updateInsuranceSelection(insuranceId)
    if not state.purchaseData then return end
    state.purchaseData.insuranceId = insuranceId
    sendPurchaseDataToUi()
  end

  -- Inspection and navigation -------------------------------------------------------------------

  local function showVehicle(shopId)
    local vehicleInfo = dependencies.getVehicleInfoByShopId(shopId)
    if not vehicleInfo then
      log("E", "Career", "Failed to find vehicle for inspection with shopId: " .. tostring(shopId))
      return
    end
    if dependencies.isOnlineSellerId(vehicleInfo.sellerId) then return end
    queueInspection(vehicleInfo, true)
  end

  local function logShopIdSamples()
    log("D", "Career", "Vehicles in shop: " .. tableSize(state.vehiclesInShop))
    if tableSize(state.vehiclesInShop) == 0 then return end
    log("D", "Career", "Sample shopIds in state.vehiclesInShop:")
    for index = 1, math.min(MAX_LOGGED_SHOP_IDS, #state.vehiclesInShop) do
      local shopId = state.vehiclesInShop[index].shopId
      log("D", "Career", "  Vehicle " .. index .. ": shopId=" .. tostring(shopId) .. " (type: " .. type(shopId) .. ")")
    end
  end

  local function quickTravelToVehicle(shopId)
    if not shopId then
      log("E", "Career", "quickTravelToVehicle: shopId is nil")
      return
    end
    log("D", "Career", "quickTravelToVehicle called with shopId: " .. tostring(shopId) .. " (type: " .. type(shopId) .. ")")
    local vehicleInfo = dependencies.getVehicleInfoByShopId(shopId)
    if not vehicleInfo then
      log("E", "Career", "Failed to find vehicle for quick travel with shopId: " .. tostring(shopId))
      logShopIdSamples()
      return
    end
    if dependencies.isOnlineSellerId(vehicleInfo.sellerId) then return end
    queueInspection(vehicleInfo, true)
  end

  -- Dependencies --------------------------------------------------------------------------------

  local function bindServices(bindings)
    for _, path in ipairs(REQUIRED_BINDINGS) do
      assert(type(resolveBinding(bindings, path)) == "function", "ui requires " .. path)
    end
    dependencies = bindings
  end

  -- Public API ----------------------------------------------------------------------------------

  local service = {
    getShoppingData = getShoppingData,
    getListing = getListing,
    requestVehicleTravelQuotes = requestVehicleTravelQuotes,
    updateTravelQuotes = updateTravelQuotes,
    cancelTravelQuotes = travelQuotes.cancel,
    sendShoppingDataToUI = sendShoppingDataToUI,
    clearFleetContext = clearFleetContext,
    openShop = openShop,
    navigateToDealership = navigateToDealership,
    taxiToDealership = taxiToDealership,
    getTaxiPriceToDealership = getTaxiPriceToDealership,
    endShopping = endShopping,
    cancelShopping = cancelShopping,
    requestExit = requestExit,
    vehicleListParams = vehicleListParams,
    onRouteEnter = onRouteEnter,
    onRouteMount = onRouteMount,
    selectSeller = selectSeller,
    clearSelectedSeller = clearSelectedSeller,
    requestVehicleListExit = requestVehicleListExit,
    getSelectedSellerBreadcrumbTitle = getSelectedSellerBreadcrumbTitle,
    onShoppingMenuClosed = onShoppingMenuClosed,
    getVehiclesInShop = getVehiclesInShop,
    removeUnusedPlayerVehicles = removeUnusedPlayerVehicles,
    leaveUnavailablePurchase = leaveUnavailablePurchase,
    sendPurchaseDataToUi = sendPurchaseDataToUi,
    updateInsuranceSelection = updateInsuranceSelection,
    isAtSeller = isAtSeller,
    startInspectionWorkitem = startInspectionWorkitem,
    navigateToPos = navigateToPos,
    showVehicle = showVehicle,
    quickTravelToVehicle = quickTravelToVehicle,
    bindServices = bindServices,
  }

  -- Game hooks ----------------------------------------------------------------------------------

  function service.onClientStartMission()
    travelQuotes.clear()
    state.vehiclesInShop = {}
  end

  service.onOverhaulAddedVehiclePartsToInventory = function(inventoryId, newParts)
    local vehicle = overhaul_career_garage_inventory.getVehicles()[inventoryId]
    -- The inventory record owns the year; shared dealer state may belong to another purchase.
    vehicle.year = tonumber(vehicle.year) or tonumber(os.date("%Y"))
    vehicle.originalParts = {}
    local allSlotsInVehicle = { main = true }
    for _, part in pairs(newParts) do
      part.year = vehicle.year
      vehicle.originalParts[part.containingSlot] = { name = part.name, value = part.value }
      if part.description.slotInfoUi then
        for slot in pairs(part.description.slotInfoUi) do allSlotsInVehicle[slot] = true end
      end
    end
    vehicle.changedSlots = {}

    local pending = state.pendingPurchase
    if pending and pending.inventoryId == inventoryId then
      state.pendingPurchase = nil
      local purchaseData = pending.purchaseData
      if state.deleteAddedVehicle then
        overhaul_career_garage_inventory.removeVehicleObject(inventoryId)
        state.deleteAddedVehicle = nil
      end
      service.endShopping()
      extensions.hook("onOverhaulVehicleAddedToInventory", {
        inventoryId = inventoryId,
        vehicleInfo = purchaseData and purchaseData.vehicleInfo,
        selectedPolicyId = purchaseData and purchaseData.selectedPolicyId,
        purchaseData = purchaseData,
      })
      if overhaul_career_garage_inventory.getVehicleSaleSource("carMeet") and overhaul_career_garage_inventory.getVehicleSaleSource("carMeet").awardTransaction then
        dependencies.purchase.awardCarMeetPurchase(inventoryId, purchaseData)
      end
    end

    if overhaul_career_career.isAutosaveEnabled() then
      overhaul_career_saveSystem.saveCurrent()
    end
  end

  service.onOverhaulEnterVehicleFinished = function(inventoryId)
    state.removeNonUsedPlayerVehicles = nil
    dependencies.spawn.completeFreightPickup(inventoryId)
  end

  return service
end

return M
