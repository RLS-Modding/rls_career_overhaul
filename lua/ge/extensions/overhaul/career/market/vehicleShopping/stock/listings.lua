-- Listing maintenance: seller projection, expiry, duplicates and refresh scheduling.
-- Stock owns these operations; the shopping owner supplies the state.
local M = {}

local REQUIRED_BINDINGS = {
  "isPoliceDealershipLocked",
  "isCarMeetShopVehicle",
  "normalizeVehicleShopTiming",
  "generateSoldVehicleValue",
  "getVehicleConfigTrackingKey",
}
local EMPTY_SCHEDULE_RETRY_SECONDS = 60
local DEFAULT_SELLER_STOCK = 10

function M.new(inputs)
  local state = inputs.state
  local config = inputs.config
  local dependencies = {}

  local function retainCurrentMapStock(currentMap)
    local changed = false
    local keptVehicles = {}
    for _, vehicleInfo in ipairs(state.vehiclesInShop) do
      if vehicleInfo.mapId == currentMap then
        table.insert(keptVehicles, vehicleInfo)
      else
        changed = true
      end
    end
    state.vehiclesInShop = keptVehicles

    local keptSellers = {}
    for sellerId, sellerInfo in pairs(state.sellersInfos) do
      if sellerInfo.mapId == currentMap then
        keptSellers[sellerId] = sellerInfo
      else
        changed = true
      end
    end
    state.sellersInfos = keptSellers
    return changed
  end

  local function starterSeller(dealership)
    return {
      id = dealership.id,
      name = dealership.name,
      description = dealership.description,
      preview = dealership.preview,
      hiddenFromDealerList = dealership.hiddenFromDealerList or dependencies.isPoliceDealershipLocked(dealership.id),
      associatedOrganization = dealership.associatedOrganization,
      vehicleGenerationMultiplier = dealership.vehicleGenerationMultiplier,
      stock = dealership.stock,
      maxStockPerModel = dealership.maxStockPerModel,
      salesChannel = dealership.salesChannel or (dealership.remotePurchaseOnly and "factory"),
      range = dealership.range,
      fees = dealership.fees,
      salesTax = dealership.salesTax,
      priceRoundingType = dealership.priceRoundingType,
      taxExempt = dealership.taxExempt,
      usedVehicleProfile = dealership.usedVehicleProfile,
      usedVehicleCondition = dealership.usedVehicleCondition,
      usedVehicleCategoryOverrides = dealership.usedVehicleCategoryOverrides,
      negotiationArchetype = dealership.negotiationArchetype,
      stockSchemaVersion = dealership.stockSchemaVersion,
      stockPolicy = dealership.stockPolicy,
      filter = { whiteList = { careerStarterVehicle = { true } } },
    }
  end

  local function dealershipSeller(dealership)
    return {
      id = dealership.id,
      name = dealership.name,
      description = dealership.description,
      preview = dealership.preview,
      hiddenFromDealerList = dealership.hiddenFromDealerList or dependencies.isPoliceDealershipLocked(dealership.id),
      associatedOrganization = dealership.associatedOrganization,
      vehicleGenerationMultiplier = dealership.vehicleGenerationMultiplier,
      stock = dealership.stock,
      maxStockPerModel = dealership.maxStockPerModel,
      range = dealership.range,
      fees = dealership.fees,
      salesTax = dealership.salesTax,
      priceRoundingType = dealership.priceRoundingType,
      taxExempt = dealership.taxExempt,
      usedVehicleProfile = dealership.usedVehicleProfile,
      usedVehicleCondition = dealership.usedVehicleCondition,
      usedVehicleCategoryOverrides = dealership.usedVehicleCategoryOverrides,
      negotiationArchetype = dealership.negotiationArchetype,
      stockSchemaVersion = dealership.stockSchemaVersion,
      stockPolicy = dealership.stockPolicy,
      salesChannel = dealership.salesChannel or (dealership.remotePurchaseOnly and "factory"),
      mileageProfile = dealership.mileageProfile,
      remanCommercial = dealership.remanCommercial,
      remotePurchaseLevel = dealership.remotePurchaseLevel,
      garageDeliveryLevel = dealership.garageDeliveryLevel,
      deliveryDiscountLevel = dealership.deliveryDiscountLevel,
      deliveryDiscount = dealership.deliveryDiscount,
      freightPickupSpotNames = dealership.freightPickupSpotNames,
      filter = dealership.filter or {},
      subFilters = dealership.subFilters,
    }
  end

  local function privateSeller(seller)
    return {
      id = seller.id,
      name = seller.name,
      description = seller.description,
      preview = seller.preview,
      hiddenFromDealerList = seller.hiddenFromDealerList,
      associatedOrganization = seller.associatedOrganization,
      vehicleGenerationMultiplier = seller.vehicleGenerationMultiplier,
      stock = seller.stock,
      maxStockPerModel = seller.maxStockPerModel,
      range = seller.range,
      fees = seller.fees,
      salesTax = seller.salesTax,
      priceRoundingType = seller.priceRoundingType,
      usedVehicleProfile = seller.usedVehicleProfile,
      usedVehicleCondition = seller.usedVehicleCondition,
      usedVehicleCategoryOverrides = seller.usedVehicleCategoryOverrides,
      negotiationArchetype = seller.negotiationArchetype,
      stockSchemaVersion = seller.stockSchemaVersion,
      stockPolicy = seller.stockPolicy,
      salesChannel = seller.salesChannel or "private",
      filter = seller.filter or {},
      subFilters = seller.subFilters,
    }
  end

  local function collectSellers(facilities, onlyStarterVehicles)
    local sellers = {}
    for _, dealership in ipairs(facilities.dealerships or {}) do
      local cached = state.vehicleCache.dealershipCache[dealership.id]
      if not (cached and cached.conditionPolicyUnavailable) then
        if not onlyStarterVehicles then
          table.insert(sellers, dealershipSeller(dealership))
        elseif dealership.containsStarterVehicles then
          table.insert(sellers, starterSeller(dealership))
        end
      end
    end
    if not onlyStarterVehicles then
      for _, seller in ipairs(facilities.privateSellers or {}) do
        local cached = state.vehicleCache.dealershipCache[seller.id]
        if not (cached and cached.conditionPolicyUnavailable) then
          table.insert(sellers, privateSeller(seller))
        end
      end
    end
    table.sort(sellers, function(a, b) return a.id < b.id end)
    return sellers
  end

  -- The listing stays visible until its removal deadline.
  local function markWatchedListingSold(vehicleInfo, currentTime)
    local shopId = vehicleInfo.shopId
    local removalDeadlineSeconds = state.vehicleWatchlist[shopId]
    -- The deadline is reset when the OS clock was adjusted back in time.
    if type(removalDeadlineSeconds) ~= "number" or removalDeadlineSeconds > currentTime + config.timeToRemoveSoldVehicle then
      state.vehicleWatchlist[shopId] = currentTime + config.timeToRemoveSoldVehicle
      if not vehicleInfo.soldFor then
        vehicleInfo.soldFor = dependencies.generateSoldVehicleValue(shopId)
      end
    end
    vehicleInfo.soldViewCounter = (vehicleInfo.soldViewCounter or 0) + 1
    vehicleInfo.markedSold = true
  end

  local function expireOffers(currentTime, protectedShopId)
    local changed = false
    local justExpiredShopIds = {}
    -- Watched expired listings stay visible until their removal deadline; inspections protect their listing.
    for index = #state.vehiclesInShop, 1, -1 do
      local vehicleInfo = state.vehiclesInShop[index]
      dependencies.normalizeVehicleShopTiming(vehicleInfo, currentTime)
      local offerAgeSeconds = currentTime - vehicleInfo.generationTime
      if vehicleInfo.shopId ~= protectedShopId and offerAgeSeconds > vehicleInfo.offerTTL then
        if state.vehicleWatchlist[vehicleInfo.shopId] then
          markWatchedListingSold(vehicleInfo, currentTime)
          justExpiredShopIds[vehicleInfo.shopId] = true
          if currentTime > state.vehicleWatchlist[vehicleInfo.shopId] then
            state.vehicleWatchlist[vehicleInfo.shopId] = nil
            table.remove(state.vehiclesInShop, index)
          end
        else
          table.remove(state.vehiclesInShop, index)
        end
        changed = true
      end
    end
    return changed, justExpiredShopIds
  end

  local function removeDuplicateStock()
    local changed = false
    local unsoldCountBySellerId = {}
    local stockedConfigsBySeller = {}
    local duplicateStockRemoved = 0
    for index = #state.vehiclesInShop, 1, -1 do
      local vehicleInfo = state.vehiclesInShop[index]
      local sellerId = vehicleInfo.sellerId
      if sellerId and not vehicleInfo.soldViewCounter then
        local isDuplicate = false
        if not dependencies.isCarMeetShopVehicle(vehicleInfo) then
          local sellerConfigKeys = stockedConfigsBySeller[sellerId] or {}
          stockedConfigsBySeller[sellerId] = sellerConfigKeys
          local configKey = dependencies.getVehicleConfigTrackingKey(vehicleInfo)
          isDuplicate = sellerConfigKeys[configKey] == true
          sellerConfigKeys[configKey] = true
        end
        if isDuplicate then
          table.remove(state.vehiclesInShop, index)
          duplicateStockRemoved = duplicateStockRemoved + 1
          changed = true
        else
          unsoldCountBySellerId[sellerId] = (unsoldCountBySellerId[sellerId] or 0) + 1
        end
      end
    end
    if duplicateStockRemoved > 0 then
      log("I", "Career", string.format("Removed %d duplicate dealer configuration listings", duplicateStockRemoved))
    end
    return changed, unsoldCountBySellerId
  end

  local function earliestFutureExpiry(currentTime)
    local earliest = math.huge
    for _, vehicleInfo in ipairs(state.vehiclesInShop) do
      if vehicleInfo.generationTime and vehicleInfo.offerTTL then
        local expiryTime = vehicleInfo.generationTime + vehicleInfo.offerTTL
        if expiryTime > currentTime and expiryTime < earliest then earliest = expiryTime end
      end
    end
    return earliest
  end

  local function scheduleNextUpdate(sellers, sellerMeta, unsoldCountBySellerId, currentTime)
    local nextUpdateTime = earliestFutureExpiry(currentTime)
    for _, seller in ipairs(sellers) do
      local meta = sellerMeta[seller.id]
      local fallbackMaxStock = math.max(math.floor(tonumber(seller.stock) or DEFAULT_SELLER_STOCK), 1)
      local maxStock = meta and meta.maxStock or fallbackMaxStock
      local openSlots = math.max(0, maxStock - (unsoldCountBySellerId[seller.id] or 0))
      if openSlots > 0 then
        local lastGenerationTime = (state.sellersInfos[seller.id] and state.sellersInfos[seller.id].lastGenerationTime) or 0
        local interval = meta and meta.adjustedTimeBetweenOffers or (config.vehicleOfferTimeToLive / maxStock)
        local nextGenerationTime = (lastGenerationTime > 0 and (lastGenerationTime + interval)) or currentTime
        if nextGenerationTime < nextUpdateTime then nextUpdateTime = nextGenerationTime end
      end
    end
    if nextUpdateTime == math.huge then nextUpdateTime = currentTime + EMPTY_SCHEDULE_RETRY_SECONDS end
    state.nextShopUpdateTime = nextUpdateTime
  end

  local function bindServices(bindings)
    for _, name in ipairs(REQUIRED_BINDINGS) do
      assert(type(bindings[name]) == "function", "stock/listings requires " .. name)
    end
    dependencies = bindings
  end

  return {
    retainCurrentMapStock = retainCurrentMapStock,
    collectSellers = collectSellers,
    expireOffers = expireOffers,
    removeDuplicateStock = removeDuplicateStock,
    scheduleNextUpdate = scheduleNextUpdate,
    bindServices = bindServices,
  }
end

return M
