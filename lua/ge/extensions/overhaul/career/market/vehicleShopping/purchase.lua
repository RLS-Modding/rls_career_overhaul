-- Purchase pricing, payment and trade-in transactions for one shopping instance.
-- Read pricing and inventory capacity, delivery quotes, purchase menus, fleet checkout, then car-meet buys.
local recordTradeIn = require("overhaul/lib/progression/logbookFeed").register("overhaul.vehicleTradedIn", {
  title = "Vehicle traded in", label = "Vehicles", icon = "carCoins"
}, "career/market/vehicleShopping/purchase.lua")

local recordPurchase = require("overhaul/lib/progression/logbookFeed").register("overhaul.vehiclePurchased", {
  title = "Vehicle purchased", label = "Vehicles", icon = "carCoins"
}, "career/market/vehicleShopping/purchase.lua")

local M = {}

local BUY_SOUND_EVENT = "event:>UI>Career>Buy_01"
local TRADE_IN_RATE = 0.66
local TRADE_IN_RATE_HARDCORE = 0.33
local GARAGE_REQUIRED_MESSAGE = "Buy or rent a garage before purchasing a vehicle."
local NO_FREE_SPACE_MESSAGE = "No free garage space for another vehicle. Vehicles awaiting freight pickup also reserve garage space."
local PURCHASE_BLOCK_MESSAGES = { garage = GARAGE_REQUIRED_MESSAGE, slot = NO_FREE_SPACE_MESSAGE }

local REQUIRED_BINDINGS = {
  "buildSnapshot", "commitDelta", "getDealershipForSellerId", "getDeliveryDelay", "getSellerAccessInfo",
  "getVehicleInfoByShopId", "fleet.addPendingRacingTeamFleetPurchase", "fleet.getRacingTeamDeliveryDelaySeconds",
  "fleet.rtFleetCap", "spawn.rtFleetSpawnVehicle", "spawn.spawnVehicle", "ui.clearFleetContext",
  "ui.leaveUnavailablePurchase", "ui.sendPurchaseDataToUi", "ui.vehicleListParams",
  "validation.coerceVehiclePricingFields",
}

local function bindingAt(bindings, path)
  local value = bindings
  for key in path:gmatch("[^.]+") do value = value[key] end
  return value
end

function M.new(inputs)
  local service = {}
  local dependencies = {}
  local state = inputs.state
  local shoppingConfig = inputs.config

  -- Pricing and inventory capacity ----------------------------------------------------------------

  -- Trade-in surplus can push finalPrice below zero (cash back); tax stays on a non-negative base.
  local function computePurchaseTaxAndFinalPrice(vehicleShopInfo, tradeInValue)
    tradeInValue = tonumber(tradeInValue) or 0
    local vehicleAndFees = (tonumber(vehicleShopInfo.Value) or 0) + (tonumber(vehicleShopInfo.fees) or 0)
    local taxes = math.max((vehicleAndFees - tradeInValue) * (vehicleShopInfo.tax or shoppingConfig.salesTax), 0)
    if vehicleShopInfo.taxExempt then taxes = 0 end
    return taxes, vehicleAndFees + taxes - tradeInValue
  end

  local function tradeInFreesInventorySlot()
    local info = state.purchaseData and state.purchaseData.tradeInVehicleInfo
    local vehicle = info and info.id and overhaul_career_garage_inventory.getVehicles()[info.id]
    return vehicle ~= nil and vehicle.owned == true
      and overhaul_career_garage_garageManager.vehicleUsesGarageCapacity(vehicle)
  end

  local function hasInventorySlotForPurchase()
    local vehicleInfo = state.purchaseData and state.purchaseData.vehicleInfo
    return (vehicleInfo and vehicleInfo.takesNoInventorySpace)
      or overhaul_career_garage_inventory.hasFreeSlot() or service.tradeInFreesInventorySlot()
  end

  local function removeTradeInVehicleForPurchase()
    if state.personalPurchaseAttempt then return end
    local info = state.purchaseData and state.purchaseData.tradeInVehicleInfo
    if info and info.id and not info.removedForPurchase then
      info.removedForPurchase = true
      overhaul_career_garage_inventory.removeVehicle(info.id)
    end
  end

  local function applyDeliveryCharge(quote)
    local previousDelivery = tonumber(state.purchaseData.prices.delivery) or 0
    local deliveryPrice = tonumber(quote and quote.finalPrice) or 0
    state.purchaseData.attemptPrice =
      (tonumber(state.purchaseData.prices.finalPrice) or 0) - previousDelivery + deliveryPrice
    return state.purchaseData.attemptPrice
  end

  local function canAffordAttemptPrice()
    return overhaul_career_economy_cheats.isCheatsMode()
      or overhaul_career_economy_playerAttributes.getAttributeValue("money") >= state.purchaseData.attemptPrice
  end

  local function hasNoGarage()
    return (overhaul_career_garage_garageManager.getGarageAvailabilityReason() or "ok") == "none"
  end

  -- Delivery quotes -------------------------------------------------------------------------------

  local function garageHasFreeSpace(garageId)
    local spaceInfo = overhaul_career_garage_garageManager.isGarageSpace(garageId)
    local vehicle = state.purchaseData and state.purchaseData.vehicleInfo
    return spaceInfo and (spaceInfo[1] or (vehicle and vehicle.takesNoInventorySpace
      and overhaul_world_facilities.getFacilityIfExists("garage", garageId)
      and overhaul_career_garage_garageManager.isPurchasedGarage(garageId)
      and not overhaul_career_garage_garageManager.isGarageForSale(garageId)))
  end

  local function getDeliveryOrigin(dealership)
    if not dealership then return nil, "Dealership is unavailable." end
    if dependencies.getSellerAccessInfo(dealership).isOnline then
      local freightFacility = dealership
      if type(dealership.freightPickupSpotNames) == "table" then
        freightFacility = deepcopy(dealership)
        freightFacility.parkingSpotNames = dealership.freightPickupSpotNames
      end
      local parkingSpots = overhaul_world_facilities.getParkingSpotsForFacility(freightFacility) or {}
      if not parkingSpots[1] then
        return nil, "This map has no freight pickup point configured for online vehicle orders."
      end
      return parkingSpots[1].pos
    end
    local pos = overhaul_world_facilities.getAverageDoorPositionForFacility(dealership)
    if not pos then return nil, "The dealership has no delivery origin configured." end
    return pos
  end

  local function getDeliveryGarages(dealership)
    local result = {}
    if not dealership or not dependencies.getSellerAccessInfo(dealership).garageDeliveryAllowed then return result end
    local capacityData = overhaul_career_garage_garageManager.getGarageCapacityData() or {}
    local vehicle = state.purchaseData and state.purchaseData.vehicleInfo
    for garageId, info in pairs(capacityData) do
      if (vehicle and vehicle.takesNoInventorySpace) or (tonumber(info.freeSlots) or 0) > 0 then
        local garage = overhaul_world_facilities.getFacility("garage", garageId)
        if garage then
          table.insert(result, {
            id = tostring(garageId),
            name = garage.name or info.name or tostring(garageId),
            freeSlots = info.freeSlots
          })
        end
      end
    end
    table.sort(result, function(a, b) return tostring(a.name) < tostring(b.name) end)
    return result
  end

  local function getDeliveryQuote(garageId)
    if not state.purchaseData or not state.purchaseData.vehicleInfo then
      return { disabled = true, reason = "No active vehicle purchase." }
    end
    local vehicleInfo = state.purchaseData.vehicleInfo
    local dealership = dependencies.getDealershipForSellerId(vehicleInfo.sellerId)
    local accessInfo = dependencies.getSellerAccessInfo(dealership or vehicleInfo)
    if not accessInfo.garageDeliveryAllowed then
      return { disabled = true, reason = "Garage delivery unlocks at dealer reputation level 2." }
    end
    if not garageId or not overhaul_career_garage_garageManager.isPurchasedGarage(garageId) then
      return { disabled = true, reason = "Choose an owned garage." }
    end
    if not garageHasFreeSpace(garageId) then
      return { disabled = true, reason = "The selected garage has no free space." }
    end
    local garage = overhaul_world_facilities.getFacility("garage", garageId)
    local garagePos = garage and overhaul_world_facilities.getGaragePosRot(garage)
    local origin, reason = service.getDeliveryOrigin(dealership)
    if not origin or not garagePos then
      return { disabled = true, reason = reason or "Delivery route is unavailable." }
    end
    local routeQuote = overhaul_career_garage_quickTravel.getRoadRouteQuote(origin, garagePos)
    local fullPrice = routeQuote.price
    local roadDistance = routeQuote.roadDistance
    local discount = accessInfo.deliveryDiscount
    local finalPrice = math.floor((tonumber(fullPrice) or 0) * (1 - discount) * 100 + 0.5) / 100
    return {
      disabled = false,
      garageId = tostring(garageId),
      garageName = garage.name or tostring(garageId),
      roadDistance = roadDistance or 0,
      fullPrice = fullPrice or 0,
      discount = discount,
      finalPrice = finalPrice,
      etaSeconds = dependencies.getDeliveryDelay(roadDistance)
    }
  end

  -- Validate before removing a trade-in so a failed purchase cannot eat the traded vehicle.
  local function canCompletePersonalVehiclePurchase(options)
    options = options or {}
    local cheats = overhaul_career_economy_cheats.isCheatsMode()
    local prices = state.purchaseData.prices or {}
    local price = (tonumber(prices.finalPrice) or 0) - (tonumber(prices.delivery) or 0)
    if options.makeDelivery then
      local quote = service.getDeliveryQuote(options.targetGarageId)
      if not quote or quote.disabled then return false, "delivery" end
      price = price + (tonumber(quote.finalPrice) or 0)
    end
    if options.licensePlateText then price = price + (tonumber(prices.customLicensePlate) or 0) end
    if not cheats and (tonumber(overhaul_career_economy_playerAttributes.getAttributeValue("money")) or 0) < price then
      return false, "funds"
    end
    if hasNoGarage() then return false, "garage" end
    if not service.hasInventorySlotForPurchase() then return false, "slot" end
    return true
  end

  -- Payment and rewards ---------------------------------------------------------------------------

  local function awardCarMeetPurchase(inventoryId, purchaseData)
    local info = purchaseData and purchaseData.vehicleInfo
    local vehicle = inventoryId and overhaul_career_garage_inventory.getVehicles()[inventoryId]
    if not info or info.source ~= "carMeet" or not vehicle or vehicle.rlsCarMeetPurchaseRewarded then return end
    if not overhaul_career_garage_inventory.getVehicleSaleSource("carMeet") or not overhaul_career_garage_inventory.getVehicleSaleSource("carMeet").awardTransaction then return end
    vehicle.rlsCarMeetPurchaseRewarded = true
    overhaul_career_garage_inventory.setVehicleDirty(inventoryId)
    overhaul_career_garage_inventory.getVehicleSaleSource("carMeet").awardTransaction("buy", purchaseData.prices.finalPrice,
      info.marketValue or info.Value or purchaseData.prices.finalPrice, inventoryId)
  end

  local function settlePurchaseReputation(purchase)
    if not purchase or purchase.settled then return end
    purchase.settled = true
    local info = purchase.vehicleInfo or {}
    local tradeIn = purchase.tradeInVehicleInfo
    if tradeIn then recordTradeIn({name = tradeIn.niceName or "Vehicle",
      facts = {{label = "Trade-in credit", value = tradeIn.Value, kind = "money"}}}) end
    recordPurchase({name = info.niceName or info.Name or info.model or "Vehicle",
      facts = {{label = "Vehicle", value = info.niceName or info.Name or info.model},
        {label = "Seller", value = info.sellerName or info.source},
        {label = "Purchase", value = purchase.racingTeamBusinessId and "Business fleet" or nil},
        {label = "Mileage", value = tonumber(info.Mileage) and string.format("%.1f km", tonumber(info.Mileage) / 1000)}},
      money = -(tonumber(purchase.historyPrice or purchase.attemptPrice or (purchase.prices and purchase.prices.finalPrice)) or 0) - (purchase.historyExtraCost or 0)})
    local orgId = purchase.reputationOrganization
    if orgId and overhaul_world_organizations.getOrganization(orgId) then
      overhaul_career_economy_playerAttributes.addAttributes(
        { [orgId .. "Reputation"] = shoppingConfig.dealershipPurchaseReputationGain },
        { tags = { "buying" }, label = string.format("Bought vehicle from %s", orgId) })
    end
  end

  local function attemptCharge()
    return state.purchaseData.attemptPrice or state.purchaseData.prices.finalPrice
  end

  local function playSaleFeedback()
    Engine.Audio.playOnce("AudioGui", BUY_SOUND_EVENT)
    state.vehicleWatchlist[state.purchaseData.shopId] = nil
  end

  local function payForVehicle(inventoryId)
    if state.rtBizId then return end
    local label = string.format("Bought a vehicle: %s", state.purchaseData.vehicleInfo.niceName)
    if state.purchaseData.tradeInVehicleInfo then
      label = label .. string.format(" and traded in vehicle id %d: %s", state.purchaseData.tradeInVehicleInfo.id,
        state.purchaseData.tradeInVehicleInfo.niceName)
    end
    local info = state.purchaseData.vehicleInfo
    local seller = dependencies.getDealershipForSellerId(info.sellerId)
    local pending = state.pendingPurchase
    overhaul_career_economy_playerAttributes.addAttributes({
      money = -attemptCharge()
    }, {
      category = "purchase",
      finance = {
        vehicleId = inventoryId or (pending and pending.purchaseData == state.purchaseData and pending.inventoryId or nil),
        vehicleName = info.niceName,
        locationId = seller and seller.id, locationName = seller and seller.name,
      },
      tags = { "vehicleBought", "buying" },
      label = label
    }, nil, function(record)
      if state.personalPurchaseAttempt then state.personalPurchaseAttempt.financeRecord = record end
    end)
    if state.personalPurchaseAttempt then
      state.personalPurchaseAttempt.paid = attemptCharge()
    end
    local saleSource = overhaul_career_garage_inventory.getVehicleSaleSource("carMeet")
    if state.purchaseData.vehicleInfo and state.purchaseData.vehicleInfo.source == "carMeet"
        and saleSource and saleSource.onPurchased then
      saleSource.onPurchased(state.purchaseData.shopId, state.purchaseData.keepCarMeetWorldVehicle == true)
    end
    playSaleFeedback()
  end

  -- Shop bookkeeping ------------------------------------------------------------------------------

  local function removeSoldVehicleFromShop()
    local targetShopId = tonumber(state.purchaseData.shopId) or state.purchaseData.shopId
    for index, shopVehicle in ipairs(state.vehiclesInShop) do
      local shopVehicleId = tonumber(shopVehicle.shopId) or shopVehicle.shopId
      if shopVehicleId == targetShopId then
        shopVehicle.markedSold = true
        shopVehicle.soldViewCounter = 1
        state.pendingSoldShopIds[state.purchaseData.shopId] = true
        table.remove(state.vehiclesInShop, index)
        break
      end
    end
  end

  local function closePurchaseMenuState()
    state.purchaseMenuOpen = false
    state.inspectingVehicleShopId = nil
  end

  local function pushShopDeltaIfOpen()
    if not state.uiOpen then return end
    dependencies.commitDelta(dependencies.buildSnapshot())
    guihooks.trigger("vehicleShopDelta", state.lastDelta)
  end

  -- Buying a spawned vehicle ----------------------------------------------------------------------

  local function buyVehicleAndSendToGarage(options)
    if state.rtBizId then return false end
    local targetGarageId = options and options.targetGarageId
    local targetGarage = targetGarageId and overhaul_world_facilities.getFacility("garage", targetGarageId)
    if not targetGarage or not overhaul_career_garage_garageManager.isPurchasedGarage(targetGarageId) then return false end
    if not garageHasFreeSpace(targetGarageId) then return false end
    local quote = service.getDeliveryQuote(targetGarageId)
    if not quote or quote.disabled then return false end
    service.applyDeliveryCharge(quote)
    if not canAffordAttemptPrice() or not service.hasInventorySlotForPurchase() then return false end
    state.spawnFollowUpActions = {
      delayAccess = quote.etaSeconds,
      targetGarageId = targetGarageId,
      licensePlateText = options.licensePlateText,
      dealershipId = options.dealershipId,
      purchaseVehicleRole = state.purchaseData.purchaseVehicleRole,
      policyId = options.policyId
    }
    local spawnedVehicle = dependencies.spawn.spawnVehicle(state.purchaseData.vehicleInfo)
    if not spawnedVehicle then
      state.spawnFollowUpActions = nil
      return false
    end
    service.removeTradeInVehicleForPurchase()
    service.payForVehicle()
    state.deleteAddedVehicle = true
    return true
  end

  local function buyVehicleAndSpawnInParkingSpot(options)
    if state.rtBizId then return false end
    service.applyDeliveryCharge(nil)
    if not canAffordAttemptPrice() or not service.hasInventorySlotForPurchase() then return false end

    local dealershipId = options.dealershipId or (state.purchaseData.vehicleInfo and state.purchaseData.vehicleInfo.sellerId)
    local dealership = dependencies.getDealershipForSellerId(dealershipId)
    local freightPickup = dealership and dependencies.getSellerAccessInfo(dealership).isOnline or false
    local targetGarage =
      overhaul_career_garage_inventory.getClosestOwnedGarageWithSpace() or overhaul_career_garage_inventory.getClosestGarage()

    state.spawnFollowUpActions = {
      targetGarageId = targetGarage and targetGarage.id or nil,
      licensePlateText = options.licensePlateText,
      dealershipId = dealershipId,
      purchaseVehicleRole = state.purchaseData.purchaseVehicleRole,
      freightPickup = freightPickup,
      policyId = options.policyId
    }
    -- "private" is a seller id, not a facility, so it must not be used as a dealership to move to
    local sellerId = state.purchaseData.vehicleInfo.sellerId
    local moveToDealership = (sellerId ~= "private" and sellerId ~= "carMeet") and dealershipId or nil
    local spawnedVehicle = dependencies.spawn.spawnVehicle(state.purchaseData.vehicleInfo, moveToDealership, freightPickup)
    if not spawnedVehicle then
      state.spawnFollowUpActions = nil
      return false
    end
    service.removeTradeInVehicleForPurchase()
    service.payForVehicle()
    if gameplay_walk.isWalking() then
      gameplay_walk.setRot(spawnedVehicle:getPosition() - getPlayerVehicle(0):getPosition())
    end
    return true
  end

  local function applyPurchaseOptionsToInventoryVehicle(inventoryId, buyVehicleOptions)
    local inventoryVehicle = overhaul_career_garage_inventory.getVehicles()[inventoryId]
    if inventoryVehicle then
      overhaul_vehicles_maintenanceBridge.applyInspectionSnapshotToVehicleData(state.purchaseData.vehicleInfo, inventoryVehicle)
    end
    if buyVehicleOptions.licensePlateText then
      overhaul_career_garage_inventory.setLicensePlateText(inventoryId, buyVehicleOptions.licensePlateText)
    end
    if state.purchaseData.purchaseVehicleRole then
      overhaul_career_garage_inventory.setVehicleRole(inventoryId, state.purchaseData.purchaseVehicleRole)
    end
  end

  local function storeBoughtVehicle(inventoryId, buyVehicleOptions, deliveryQuote)
    if not deliveryQuote then return overhaul_career_garage_inventory.storeVehicle(inventoryId) end
    local stored = overhaul_career_garage_inventory.moveVehicleToGarage(inventoryId, buyVehicleOptions.targetGarageId)
    if stored then
      overhaul_career_garage_inventory.delayVehicleAccess(inventoryId, deliveryQuote.etaSeconds, "bought")
    end
    return stored
  end

  local function buySpawnedVehicle(buyVehicleOptions)
    if state.rtBizId then return false end
    buyVehicleOptions = buyVehicleOptions or {}
    service.applyDeliveryCharge(nil)
    local deliveryQuote
    if buyVehicleOptions.makeDelivery then
      deliveryQuote = service.getDeliveryQuote(buyVehicleOptions.targetGarageId)
      if not deliveryQuote or deliveryQuote.disabled then return false end
      service.applyDeliveryCharge(deliveryQuote)
    end
    local canAfford = canAffordAttemptPrice()
    local noGarage = hasNoGarage()
    if not canAfford then return false end
    if noGarage then
      ui_message(GARAGE_REQUIRED_MESSAGE, nil, "vehicleShopping")
      return false
    end
    if not service.hasInventorySlotForPurchase() then return false end

    local vehicleObject = getObjectByID(state.purchaseData.vehId)
    if not vehicleObject then return false end
    local newInventoryId = overhaul_career_garage_inventory.addVehicle(vehicleObject:getID(), nil, {
      year = state.purchaseData.vehicleInfo and state.purchaseData.vehicleInfo.year,
      finalPrice = state.purchaseData.attemptPrice,
      replacingInventoryId = state.purchaseData.tradeInVehicleInfo and state.purchaseData.tradeInVehicleInfo.id
    })
    if not newInventoryId then
      log("E", "Career", "buySpawnedVehicle: could not add the vehicle to the inventory, purchase aborted before payment")
      return false
    end
    state.pendingPurchase = { inventoryId = newInventoryId, purchaseData = state.purchaseData }
    service.removeTradeInVehicleForPurchase()
    service.payForVehicle()
    applyPurchaseOptionsToInventoryVehicle(newInventoryId, buyVehicleOptions)
    if not storeBoughtVehicle(newInventoryId, buyVehicleOptions, deliveryQuote) then
      log("W", "Career", "buySpawnedVehicle: vehicle paid and added but could not be stored, inventoryId " .. tostring(newInventoryId))
      return true
    end
    state.removeNonUsedPlayerVehicles = true
    if not deliveryQuote and be:getPlayerVehicleID(0) == vehicleObject:getID() then
      overhaul_career_garage_inventory.enterVehicle(newInventoryId)
    end
    return true
  end

  -- Purchase menu ---------------------------------------------------------------------------------

  local function logMissingShopListing(shopId)
    log("E", "Career", "Failed to find vehicle for purchase with shopId: " .. tostring(shopId))
    if #state.vehiclesInShop == 0 then
      log("E", "Career", "No vehicles available in shop")
      return
    end
    log("D", "Career", "Available vehicles in shop:")
    for index, shopVehicle in ipairs(state.vehiclesInShop) do
      log("D", "Career", "  Vehicle " .. index .. ": shopId=" .. tostring(shopVehicle.shopId) .. ", key=" .. tostring(shopVehicle.key))
    end
  end

  -- True (after telling the player why) when a remote checkout is not allowed for this listing.
  local function remoteCheckoutBlocked(vehicle, purchaseType)
    if purchaseType ~= "instant" or state.currentSeller or vehicle.sellerId == "private" or vehicle.source == "carMeet" then
      return false
    end
    local dealership = overhaul_world_facilities.getDealership(vehicle.sellerId)
    local accessInfo = dependencies.getSellerAccessInfo(dealership)
    if not accessInfo.remotePurchaseAllowed then
      ui_message("Visit this dealership to purchase. Remote checkout unlocks at reputation level 2.",
        6, "In-person purchase required", "info")
      return true
    end
    if accessInfo.isOnline then
      local origin, reason = service.getDeliveryOrigin(dealership)
      if not origin then
        ui_message(reason, 8, "Online ordering unavailable", "warning")
        return true
      end
    end
    return false
  end

  local function buildVehicleShopInfo(vehicle)
    local vehicleShopInfo = deepcopy(vehicle)
    vehicleShopInfo.niceName = vehicleShopInfo.Brand .. " " .. vehicleShopInfo.Name
    dependencies.validation.coerceVehiclePricingFields(vehicleShopInfo)

    local distance = vehicleShopInfo.distance
    if type(distance) ~= "number" then
      if vehicleShopInfo.pos then
        local quickTravelPrice, travelDistance = overhaul_career_garage_quickTravel.getPriceForQuickTravel(vehicleShopInfo.pos)
        vehicleShopInfo.quickTravelPrice = vehicleShopInfo.quickTravelPrice or quickTravelPrice
        distance = travelDistance
      else
        distance = 0
      end
      vehicleShopInfo.distance = distance
    end
    vehicleShopInfo.deliveryDelay = dependencies.getDeliveryDelay(distance)
    return vehicleShopInfo
  end

  local function openPurchaseMenu(purchaseType, shopId, insuranceId, silent)
    log("D", "Career",
      "openPurchaseMenu called with purchaseType: " .. tostring(purchaseType) .. ", shopId: " .. tostring(shopId))
    if not purchaseType then
      log("E", "Career", "openPurchaseMenu: purchaseType is nil")
      return
    end
    if not shopId then
      log("E", "Career", "openPurchaseMenu: shopId is nil")
      return
    end

    local vehicle = dependencies.getVehicleInfoByShopId(shopId)
    if not vehicle then
      logMissingShopListing(shopId)
      return
    end
    if dependencies.isPoliceDealershipLocked(vehicle.sellerId) then return end
    if remoteCheckoutBlocked(vehicle, purchaseType) then return end

    state.vehicleWatchlist[shopId] = "unsold"
    -- Snapshot before switching UI: leaving vehicle shopping can remount the view and clear global state.rtBizId.
    local racingTeamPurchaseBizId = state.rtBizId

    local dealer = dependencies.getDealershipForSellerId(vehicle.sellerId)
    local vehicleShopInfo = buildVehicleShopInfo(vehicle)
    vehicleShopInfo.taxExempt = dealer and dealer.taxExempt or vehicleShopInfo.taxExempt
    local taxes, finalPrice = service.computePurchaseTaxAndFinalPrice(vehicleShopInfo, 0)
    state.purchaseData = {
      shopId = shopId,
      purchaseType = purchaseType,
      -- The list unmounts during checkout; retain its return target through child screens.
      shoppingReturn = state.uiOpen and {
        name = "overhaul.computer.vehicleShopping.vehicles",
        params = dependencies.ui.vehicleListParams()
      } or nil,
      vehicleInfo = vehicleShopInfo,
      purchaseVehicleRole = dealer and dealer.purchaseVehicleRole,
      purchaseUnlock = dealer and deepcopy(dealer.purchaseUnlock),
      insuranceId = vehicleShopInfo.source == "carMeet" and -1 or insuranceId,
      racingTeamBusinessId = racingTeamPurchaseBizId,
      fleetBusinessType = state.fleetBusinessType,
      prices = {
        fees = vehicleShopInfo.fees,
        taxes = taxes,
        finalPrice = finalPrice,
        customLicensePlate = shoppingConfig.customLicensePlatePrice
      }
    }
    if racingTeamPurchaseBizId then state.purchaseData.insuranceId = -1 end

    state.purchaseMenuOpen = true
    log("D", "Career", "Successfully opened purchase menu for vehicle: " .. tostring(shopId))
    if silent then return end
    extensions.ui_router.navigate("overhaul.computer.vehicleShopping.vehicles.vehiclePurchase")
    extensions.hook("onOverhaulVehicleShoppingPurchaseMenuOpened", {
      purchaseType = purchaseType,
      shopId = shopId
    })
  end

  -- Racing team fleet checkout --------------------------------------------------------------------

  -- Racing team fleet checkout: the business account pays and the car joins the fleet, not the personal garage.
  local function queueFleetTimerDelivery(businessId, vehicleInfo, price)
    local delay = dependencies.fleet.getRacingTeamDeliveryDelaySeconds(businessId, vehicleInfo)
    dependencies.fleet.addPendingRacingTeamFleetPurchase(businessId, {
      kind = "timer",
      dueEpoch = os.time() + delay,
      model_key = vehicleInfo.model_key,
      key = vehicleInfo.key,
      mileage = vehicleInfo.Mileage or 0,
      purchasePrice = price,
      purchasedEpoch = os.time()
    })
  end

  local function queueFleetDriveInDelivery(businessId, vehicleInfo, spawnedVehicleId, price)
    dependencies.fleet.addPendingRacingTeamFleetPurchase(businessId, {
      kind = "drive",
      spawnedVehId = spawnedVehicleId,
      model_key = vehicleInfo.model_key,
      key = vehicleInfo.key,
      mileage = vehicleInfo.Mileage or 0,
      purchasePrice = price,
      purchasedEpoch = os.time()
    })
  end

  local function deliverFleetVehicleInPerson(businessId, vehicleInfo, options, price)
    local spawnedVehicleId = tonumber(state.purchaseData.vehId) or state.purchaseData.vehId
    local spawnedVehicle = spawnedVehicleId and be:getObjectByID(spawnedVehicleId)
    if not spawnedVehicle then
      local dealershipId = options.dealershipId or vehicleInfo.sellerId
      local respawnedVehicle = dependencies.spawn.rtFleetSpawnVehicle(vehicleInfo, dealershipId)
      spawnedVehicleId = respawnedVehicle and respawnedVehicle:getID() or nil
    end
    if not spawnedVehicleId then
      queueFleetTimerDelivery(businessId, vehicleInfo, price)
      return
    end
    queueFleetDriveInDelivery(businessId, vehicleInfo, spawnedVehicleId, price)
    -- Clear inspect/test-drive state without deleting the purchased world vehicle.
    overhaul_career_market_inspectVehicle.leaveSaleCallback("dontDespawn", false, false, "You purchased the vehicle.")
  end

  local function deliverFleetVehicleRemotely(businessId, vehicleInfo, effectivePurchaseType, price)
    queueFleetTimerDelivery(businessId, vehicleInfo, price)
    -- Remote and instant flows have no world car to drive.
    if effectivePurchaseType ~= "inspect" then
      overhaul_career_market_inspectVehicle.leaveSaleCallback("despawn", false, false, "You purchased the vehicle.")
    end
  end

  -- Racing team purchases always debit the business account; cheats mode does not waive this.
  local function payFleetFromBusinessAccount(businessId, price)
    local bank = overhaul_career_economy_bank
    local purchaseFleetType = state.purchaseData.fleetBusinessType or state.fleetBusinessType
    local account = bank.getBusinessAccount(purchaseFleetType, businessId)
    local accountId = account and (account.id or account.accountId)
    if not accountId then return false end
    return bank.payFromAccount({
      money = { amount = price, canBeNegative = false }
    }, accountId, "Vehicle Purchase", purchaseFleetType .. " fleet vehicle", require("overhaul/lib/finance/metadata").tag(nil, "purchase"))
  end

  local function buyRacingTeamFleetFromPurchaseMenu(businessId, purchaseType, options)
    local fleetCapacity = dependencies.fleet.rtFleetCap(businessId)
    local fleetCount = #(overhaul_career_business_fleet.getBusinessVehicles(businessId) or {})
    if fleetCount >= fleetCapacity then
      ui_message(string.format("Racing team fleet is full (%d/%d). Make room in the fleet before buying another vehicle.",
        fleetCount, fleetCapacity), 8, "vehicleShopping", "error")
      return
    end
    local price = tonumber(state.purchaseData.prices.finalPrice) or 0
    if options.licensePlateText then
      price = price + (tonumber(state.purchaseData.prices.customLicensePlate) or 0)
    end
    if not payFleetFromBusinessAccount(businessId, price) then return end
    state.purchaseData.historyPrice = price

    local vehicleInfo = state.purchaseData.vehicleInfo
    -- Same in-person check as the purchase UI: instant buys while at a seller, or inspect buys from a non-private seller.
    local effectivePurchaseType = purchaseType or state.purchaseData.purchaseType
    local isInPersonSellerFlow = effectivePurchaseType == "inspect"
      or (effectivePurchaseType == "instant" and state.currentSeller ~= nil and vehicleInfo.sellerId ~= "private")
    if isInPersonSellerFlow then
      deliverFleetVehicleInPerson(businessId, vehicleInfo, options, price)
    else
      deliverFleetVehicleRemotely(businessId, vehicleInfo, effectivePurchaseType, price)
    end
    playSaleFeedback()
    removeSoldVehicleFromShop()
    closePurchaseMenuState()
    pushShopDeltaIfOpen()
    service.settlePurchaseReputation(state.purchaseData)
    state.purchaseData = nil
    dependencies.ui.clearFleetContext()
    overhaul_career_career.closeAllMenus()
  end

  -- Buying from the purchase menu -----------------------------------------------------------------

  local function purchaseNoLongerValid(listing)
    local tradeIn = state.purchaseData.tradeInVehicleInfo
    local owned = tradeIn and overhaul_career_garage_inventory.getVehicles()[tradeIn.id]
    return state.purchaseData.settled or not listing or listing.markedSold
      or (tradeIn and (not owned or owned.owned == false or tradeIn.removedForPurchase))
  end

  local function reputationOrganizationFor(listing, options)
    local orgId = listing.associatedOrganization
    if orgId then return orgId end
    local dealershipId = options.dealershipId or listing.sellerId
    local dealership = dealershipId and dealershipId ~= "private" and overhaul_world_facilities.getDealership(dealershipId)
    return dealership and dealership.associatedOrganization
  end

  local function ensurePurchasePrices()
    if state.purchaseData.prices then return end
    log("W", "Career", "buyFromPurchaseMenu: state.purchaseData.prices is nil, calculating prices as fallback")
    local vehicleShopInfo = state.purchaseData.vehicleInfo
    dependencies.validation.coerceVehiclePricingFields(vehicleShopInfo)
    local tradeInValue = state.purchaseData.tradeInVehicleInfo and state.purchaseData.tradeInVehicleInfo.Value or 0
    local taxes, finalPrice = service.computePurchaseTaxAndFinalPrice(vehicleShopInfo, tradeInValue)
    state.purchaseData.prices = {
      fees = vehicleShopInfo.fees,
      taxes = taxes,
      finalPrice = finalPrice,
      customLicensePlate = shoppingConfig.customLicensePlatePrice
    }
  end

  local function attemptPurchase(purchaseType, options, buyVehicleOptions)
    if purchaseType == "inspect" then
      if options.makeDelivery then state.deleteAddedVehicle = true end
      return overhaul_career_market_inspectVehicle.buySpawnedVehicle(buyVehicleOptions) == true
    end
    if purchaseType ~= "instant" then return false end
    if options.makeDelivery then return service.buyVehicleAndSendToGarage(buyVehicleOptions) == true end
    return service.buyVehicleAndSpawnInParkingSpot(buyVehicleOptions) == true
  end

  local function reportFailedPurchase()
    state.deleteAddedVehicle = nil
    local tradeIn = state.purchaseData.tradeInVehicleInfo
    if tradeIn and tradeIn.removedForPurchase then
      log("E", "Career", "buyFromPurchaseMenu: purchase failed after trade-in was removed")
    else
      log("W", "Career", "buyFromPurchaseMenu: purchase failed, trade-in kept")
    end
  end

  local function chargeCustomLicensePlate()
    state.purchaseData.historyExtraCost = state.purchaseData.prices.customLicensePlate
    overhaul_career_economy_playerAttributes.addAttributes({
      money = -state.purchaseData.prices.customLicensePlate
    }, require("overhaul/lib/finance/metadata").tag({
      tags = { "buying" },
      label = "Bought custom license plate for new vehicle"
    }, "purchase"))
    if state.personalPurchaseAttempt then
      state.personalPurchaseAttempt.purchase.historyExtraCost = state.purchaseData.historyExtraCost
      state.personalPurchaseAttempt.paid = (state.personalPurchaseAttempt.paid or 0) + state.purchaseData.prices.customLicensePlate
    end
  end

  local function finishPersonalPurchase(purchaseType)
    removeSoldVehicleFromShop()
    closePurchaseMenuState()
    pushShopDeltaIfOpen()
    if purchaseType == "inspect" or purchaseType == "instant" then overhaul_career_career.closeAllMenus() end
    if not state.personalPurchaseAttempt then
      service.settlePurchaseReputation(state.purchaseData)
      state.purchaseData = nil
    end
  end

  local function buyFromPurchaseMenu(purchaseType, options)
    options = options or {}
    if state.personalPurchaseAttempt or overhaul_career_saveSystem.isSaveBusy() then
      ui_message("A purchase or career save is in progress. Please try again in a moment.", 6, "vehicleShopping")
      return
    end
    if not state.purchaseData then
      dependencies.ui.leaveUnavailablePurchase()
      return
    end
    if not state.purchaseData.vehicleInfo then
      log("E", "Career", "buyFromPurchaseMenu: state.purchaseData.vehicleInfo is nil")
      return
    end
    local unlock = state.purchaseData.purchaseUnlock
    if unlock and require('overhaul/lib/progression/skillLookup').levelFirstPathOrValueUncheckedCalc(
      unlock.skillPath, unlock.skillPaths or {unlock.skillPath}) < unlock.minimumLevel then return end
    local listing = dependencies.getVehicleInfoByShopId(state.purchaseData.shopId)
    if purchaseNoLongerValid(listing) then
      state.purchaseData = nil
      dependencies.ui.leaveUnavailablePurchase()
      return
    end
    state.purchaseData.reputationOrganization = reputationOrganizationFor(listing, options)
    if options.makeDelivery then
      local quote = service.getDeliveryQuote(options.targetGarageId)
      if not quote or quote.disabled then
        ui_message(quote and quote.reason or "Delivery quote is unavailable.", 6, "Delivery unavailable", "warning")
        return
      end
    end
    ensurePurchasePrices()

    local businessId = state.purchaseData.racingTeamBusinessId or state.rtBizId
    if businessId then return buyRacingTeamFleetFromPurchaseMenu(businessId, purchaseType, options) end

    local canPurchase, blockReason = service.canCompletePersonalVehiclePurchase(options)
    if not canPurchase then
      local blockMessage = PURCHASE_BLOCK_MESSAGES[blockReason]
      if blockMessage then ui_message(blockMessage, nil, "vehicleShopping") end
      return
    end

    local selectedPolicyId = options.policyId or 0
    state.purchaseData.selectedPolicyId = selectedPolicyId
    local buyVehicleOptions = {
      makeDelivery = options.makeDelivery == true,
      targetGarageId = options.targetGarageId,
      licensePlateText = options.licensePlateText,
      dealershipId = options.dealershipId or state.purchaseData.vehicleInfo.sellerId,
      policyId = selectedPolicyId
    }
    if not attemptPurchase(purchaseType, options, buyVehicleOptions) then
      reportFailedPurchase()
      return
    end
    service.removeTradeInVehicleForPurchase()
    if options.licensePlateText then chargeCustomLicensePlate() end
    finishPersonalPurchase(purchaseType)
  end

  -- Leaving the purchase menu ---------------------------------------------------------------------

  local function cancelPurchase(purchaseType)
    state.purchaseMenuOpen = false
    if purchaseType == "inspect" then
      overhaul_career_career.closeAllMenus()
    elseif purchaseType == "instant" then
      local shoppingReturn = state.purchaseData and state.purchaseData.shoppingReturn
      if shoppingReturn then
        extensions.ui_router.navigate(shoppingReturn.name, shoppingReturn.params)
      else
        overhaul_career_career.closeAllMenus()
      end
    end
  end

  local function requestPurchaseExit()
    local purchaseType = state.purchaseData and state.purchaseData.purchaseType
    state.purchaseMenuOpen = false
    if purchaseType == "inspect" then
      overhaul_career_career.closeAllMenus()
      return
    end
    local shoppingReturn = state.purchaseData and state.purchaseData.shoppingReturn
    if shoppingReturn then
      return extensions.ui_router.navigate(shoppingReturn.name, shoppingReturn.params)
    end
    return overhaul_career_career.closeAllMenus()
  end

  -- Car meet purchases ----------------------------------------------------------------------------

  local function getCarMeetPurchaseBlockReason()
    if hasNoGarage() then return GARAGE_REQUIRED_MESSAGE end
    if not overhaul_career_garage_inventory.hasFreeSlot() then return NO_FREE_SPACE_MESSAGE end
    return nil
  end

  local function canPurchaseCarMeetVehicle(showMessage)
    local reason = service.getCarMeetPurchaseBlockReason()
    if not reason then return true end
    if showMessage then ui_message(reason, nil, "vehicleShopping") end
    return false
  end

  local function prepareCarMeetVehicle(shopId)
    local saleSource = overhaul_career_garage_inventory.getVehicleSaleSource("carMeet")
    if saleSource and saleSource.preparePurchase then
      return saleSource.preparePurchase(shopId, state.purchaseData.vehicleInfo)
    end
    local vehicleId = saleSource and saleSource.getWorldVehicleId and saleSource.getWorldVehicleId(shopId)
    if saleSource and saleSource.snapshotPurchase then
      saleSource.snapshotPurchase(vehicleId)
    end
    return vehicleId
  end

  local function recordCarMeetVehicleInInventory(inventoryId, vehicleId)
    local inventoryVehicle = overhaul_career_garage_inventory.getVehicles()[inventoryId]
    if not inventoryVehicle then return end
    local vehicleData = core_vehicle_manager.getVehicleData(vehicleId)
    if vehicleData and type(vehicleData.config) == "table" then
      inventoryVehicle.config = deepcopy(vehicleData.config)
    end
    inventoryVehicle.mileage = state.purchaseData.vehicleInfo.Mileage or inventoryVehicle.mileage or 0
    inventoryVehicle.purchasePrice = state.purchaseData.prices and state.purchaseData.prices.finalPrice or state.purchaseData.vehicleInfo.Value
  end

  local function parkCarMeetVehicle(vehicleObject)
    vehicleObject:queueLuaCommand('ai.setMode("disabled")')
    vehicleObject:queueLuaCommand('electrics.setIgnitionLevel(0)')
    vehicleObject:queueLuaCommand('if electrics.setLightsState then electrics.setLightsState(0) end')
    vehicleObject:queueLuaCommand('if electrics.set_warn_signal then electrics.set_warn_signal(0) end')
  end

  local function buyCarMeetVehicleNow(shopId)
    dependencies.ui.clearFleetContext()
    service.openPurchaseMenu("instant", shopId, -1, true)
    if not state.purchaseData or not state.purchaseData.vehicleInfo or state.purchaseData.vehicleInfo.source ~= "carMeet" then
      return false, "This vehicle is no longer available for purchase."
    end
    local blockReason = service.getCarMeetPurchaseBlockReason()
    if blockReason then return false, blockReason end
    if not (overhaul_career_economy_cheats.isCheatsMode()
        or overhaul_career_economy_playerAttributes.getAttributeValue("money") >= state.purchaseData.prices.finalPrice) then
      return false, "You cannot afford this vehicle."
    end

    state.purchaseData.keepCarMeetWorldVehicle = true
    local vehicleId = prepareCarMeetVehicle(shopId)
    local vehicleObject = vehicleId and getObjectByID(vehicleId)
    if not vehicleObject then
      return false, "The vehicle could not be found at the meet. Try again before the event ends."
    end

    local info = state.purchaseData.vehicleInfo
    local mileage = tonumber(info.Mileage)
    if not mileage or mileage < 0 or mileage ~= mileage or mileage == math.huge then
      mileage = require("overhaul/lib/market/usedVehicleCondition").generateAgeDrivenMileage(
        {salesChannel = "private"}, info, info.year)
    end
    info.Mileage = mileage
    -- Queue before addVehicle requests conditions: the odometer and saved parts must agree with the offer.
    vehicleObject:queueLuaCommand(string.format("partCondition.initConditions(nil, %.17g, nil, %f)",
      mileage, overhaul_career_market_vehicleShopping.getVisualValueFromMileage(mileage)))

    -- The normal inventory init registers installed parts with partInventory before the vehicle is modifiable.
    local inventoryId = overhaul_career_garage_inventory.addVehicle(vehicleId, nil, {
      owned = true, year = state.purchaseData.vehicleInfo.year,
      finalPrice = state.purchaseData.prices and state.purchaseData.prices.finalPrice
    })
    if not inventoryId then return false, "Could not add the vehicle to your garage." end
    recordCarMeetVehicleInInventory(inventoryId, vehicleId)
    if not overhaul_career_garage_inventory.moveVehicleToGarage(inventoryId) then
      overhaul_career_garage_inventory.removeVehicle(inventoryId)
      return false, NO_FREE_SPACE_MESSAGE
    end
    parkCarMeetVehicle(vehicleObject)
    service.payForVehicle(inventoryId)
    service.settlePurchaseReputation(state.purchaseData)

    -- Register with insurance as uninsured; coverage can be added later at a garage/computer.
    state.purchaseData.insuranceId = -1
    extensions.hook("onOverhaulVehicleAddedToInventory", {
      inventoryId = inventoryId,
      vehicleInfo = state.purchaseData.vehicleInfo,
      selectedPolicyId = 0,
      purchaseData = state.purchaseData
    })
    if overhaul_career_garage_inventory.getVehicleSaleSource("carMeet") and overhaul_career_garage_inventory.getVehicleSaleSource("carMeet").awardTransaction then
      service.awardCarMeetPurchase(inventoryId, state.purchaseData)
    end

    removeSoldVehicleFromShop()
    closePurchaseMenuState()
    if overhaul_career_career.isAutosaveEnabled() then
      overhaul_career_saveSystem.saveCurrent(nil, { force = true })
    end
    overhaul_career_career.closeAllMenus()
    return true
  end

  -- Trade-ins -------------------------------------------------------------------------------------

  local function removeTradeInVehicle()
    state.purchaseData.tradeInVehicleInfo = nil
    dependencies.ui.sendPurchaseDataToUi()
  end

  local function tradeInNiceName(inventoryId, vehicle)
    local niceName = overhaul_career_garage_inventory.getVehicleNiceNameTranslated(inventoryId)
    if type(niceName) ~= "string" or niceName == "" then niceName = vehicle.niceName end
    if type(niceName) == "table" then niceName = core_locales.translateWithOrWithoutContext(niceName) end
    if type(niceName) ~= "string" then niceName = tostring(niceName or "Trade-In Vehicle") end
    return niceName
  end

  local function tradeInRate()
    return overhaul_career_economy_difficultyMode.isHardcoreMode() and TRADE_IN_RATE_HARDCORE or TRADE_IN_RATE
  end

  local function chooseTradeInVehicle(inventoryId)
    local vehicle = overhaul_career_garage_inventory.getVehicles()[inventoryId]
    if not vehicle then return end
    state.purchaseData.tradeInVehicleInfo = {
      id = inventoryId,
      niceName = tradeInNiceName(inventoryId, vehicle),
      Value = overhaul_career_market_valueCalculator.getInventoryVehicleValue(inventoryId) * tradeInRate(),
      takesNoInventorySpace = vehicle.takesNoInventorySpace
    }
    guihooks.trigger("UINavigation", "back", 1)
    dependencies.ui.sendPurchaseDataToUi()
  end

  local function openInventoryMenuForTradeIn()
    overhaul_career_garage_inventory.openMenu({ {
      callback = chooseTradeInVehicle,
      buttonText = "Trade-In",
      repairRequired = true,
      ownedRequired = true
    } }, "Trade-In", {
      repairEnabled = false,
      sellEnabled = false,
      favoriteEnabled = false,
      storingEnabled = false,
      returnLoanerEnabled = false
    }, "overhaul.computer.vehicleShopping.vehicles.vehiclePurchase")
  end

  -- Service bindings ------------------------------------------------------------------------------

  local function bindServices(bindings)
    for _, path in ipairs(REQUIRED_BINDINGS) do
      assert(type(bindingAt(bindings, path)) == "function", "purchase requires " .. path)
    end
    dependencies = bindings
  end

  -- Public API ------------------------------------------------------------------------------------

  service = {
    computePurchaseTaxAndFinalPrice = computePurchaseTaxAndFinalPrice,
    tradeInFreesInventorySlot = tradeInFreesInventorySlot,
    hasInventorySlotForPurchase = hasInventorySlotForPurchase,
    removeTradeInVehicleForPurchase = removeTradeInVehicleForPurchase,
    applyDeliveryCharge = applyDeliveryCharge,
    canCompletePersonalVehiclePurchase = canCompletePersonalVehiclePurchase,

    getDeliveryOrigin = getDeliveryOrigin,
    getDeliveryGarages = getDeliveryGarages,
    getDeliveryQuote = getDeliveryQuote,

    awardCarMeetPurchase = awardCarMeetPurchase,
    settlePurchaseReputation = settlePurchaseReputation,
    payForVehicle = payForVehicle,

    buyVehicleAndSendToGarage = buyVehicleAndSendToGarage,
    buyVehicleAndSpawnInParkingSpot = buyVehicleAndSpawnInParkingSpot,
    buySpawnedVehicle = buySpawnedVehicle,

    openPurchaseMenu = openPurchaseMenu,
    buyFromPurchaseMenu = buyFromPurchaseMenu,
    cancelPurchase = cancelPurchase,
    requestPurchaseExit = requestPurchaseExit,

    getCarMeetPurchaseBlockReason = getCarMeetPurchaseBlockReason,
    canPurchaseCarMeetVehicle = canPurchaseCarMeetVehicle,
    buyCarMeetVehicleNow = buyCarMeetVehicleNow,

    removeTradeInVehicle = removeTradeInVehicle,
    openInventoryMenuForTradeIn = openInventoryMenuForTradeIn,

    bindServices = bindServices,
  }
  return service
end

return M
