-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding
-- Fork of stock lua/ge/extensions/career/modules/vehicleShopping.lua (BeamNG 0.40).

-- Owns shopping state and save snapshots; parts own validation, catalog, stock, UI, spawn and purchase.
-- Read config and state, shared helpers, service construction, update and lifecycle, then the public API.
local recordDiscovery = require("overhaul/lib/progression/logbookFeed").register("overhaul.dealerDiscovered", {
  title = "Dealership discovered", label = "Discovery", icon = "mapPoint"
}, "career/market/vehicleShopping.lua")

local M = {}
local cardProjection = require("overhaul/career/market/vehicleShopping/projection")
local levelData = require("overhaul/lib/world/levelData")
local skillLookup = require("overhaul/lib/progression/skillLookup")
local usedVehicleCondition = require("overhaul/lib/market/usedVehicleCondition")
local jsonCatalog = require("overhaul/lib/platform/jsonCatalog")

M.dependencies =
  {'util_configListGenerator'}

M.limitedMileageDealerSchemaVersion = 1

-- Config ------------------------------------------------------------------------------------------
local shoppingConfig = {
  moduleVersion = 69,
  valuationSchemaVersion = 12,
  vehicleDeliveryDelay = 60,
  vehicleOfferTimeToLive = 10 * 60,
  timeToRemoveSoldVehicle = 5 * 60,
  dealershipTimeBetweenOffers = 1 * 60,
  salesTax = 0.07,
  customLicensePlatePrice = 300,
  dealershipPurchaseReputationGain = 2000,
  missingYearsFallbackModelYear = 2023,
  refreshInterval = 5,
  tetherRange = 4,
  travelQuoteCellSize = 50,
  REMOTE_PURCHASE_LEVEL = 2,
  DELIVERY_DISCOUNT_LEVEL = 3,
  DELIVERY_DISCOUNT_AT_LEVEL_3 = 0.25,
}
shoppingConfig.vehiclesPerDealership = shoppingConfig.vehicleOfferTimeToLive / shoppingConfig.dealershipTimeBetweenOffers

-- State -------------------------------------------------------------------------------------------
local state = {
  vehiclesInShop = {},
  sellersInfos = {},
  otherMapsData = {},
  discoveredDealers = {},
  vehicleWatchlist = {},
  buyingAvailable = true,
  marketplaceAvailable = true,
  lastSnapshotByShopId = {},
  lastDelta = { seq = 0, added = {}, removed = {}, sold = {}, updated = {} },
  deltaSeq = 0,
  pendingSoldShopIds = {},
  soldVehicles = {},
  uiOpen = false,
  shoppingUiOpenCount = 0,
  refreshAccumulator = 0,
  nextShopUpdateTime = 0,
  rtPendingFleetPurchases = {},
  rewardVehicleGrants = {},
  rtPendingFleetProcessing = false,
  rtPendingTimerFailureGraceSec = 20,
  rtPendingDriveStaleSec = 20 * 60,
  rtPendingStoreFailureRefundSec = 10 * 60,
  vehicleCache = {
    regularVehicles = {},
    dealershipCache = {},
    lastCacheTime = 0,
    cacheValid = false,
  },
  badConfigQuarantine = {},
  badConfigLogOnce = {},
  validationStats = {
    quarantined = 0,
    loadDropped = 0,
    cacheDropped = 0,
    generationDropped = 0,
  },
  purchaseMenuOpen = false,
  fleetBusinessType = "racingTeam",
  inspectingVehicleShopId = nil,
  spawnFollowUpActions = nil,
  rewardVehicleGrantData = nil,
  deleteAddedVehicle = nil,
  pendingPurchase = nil,
  removeNonUsedPlayerVehicles = nil,
}

local helpers = {}
local parts = {}

-- Shared helpers ----------------------------------------------------------------------------------
helpers.generateShopId = function()
  local shopId = 0
  while true do
    shopId = math.floor(math.random() * 1000000)
    local found = false
    for _, vehInfo in ipairs(state.vehiclesInShop) do
      if vehInfo.shopId == shopId then
        found = true
        break
      end
    end
    if not found then
      return shopId
    end
  end
end

helpers.getBranchLevelByPathIds = skillLookup.firstPathLevel

helpers.getDealerPurchasePolicy = function(dealershipId)
  local dealer = overhaul_world_facilities.getFacilityIfExists("dealership", dealershipId)
  return dealer and dealer.purchaseUnlock, dealer and dealer.purchaseVehicleRole
end

helpers.isPoliceDealershipLocked = function(dealershipId)
  local unlock = helpers.getDealerPurchasePolicy(dealershipId)
  if not unlock then return false end
  if type(unlock.skillPath) ~= 'string' or not jsonCatalog.finite(unlock.minimumLevel) or unlock.minimumLevel < 0 then
    log('W', 'vehicleShopping', 'Invalid purchase unlock for ' .. tostring(dealershipId))
    return true
  end
  local level = skillLookup.levelFirstPathOrValueUncheckedCalc(unlock.skillPath, unlock.skillPaths or {unlock.skillPath})
  return level < unlock.minimumLevel
end

helpers.getPoliceDealershipLockLabel = function(dealershipId)
  local unlock = helpers.getDealerPurchasePolicy(dealershipId)
  if not unlock then return 'Dealer purchase requirement unavailable' end
  return string.format(unlock.label or 'Dealer requires skill level %d', unlock.minimumLevel or 0)
end

helpers.getVehicleInfoByShopId = function(shopId)
  if not shopId then
    return nil
  end
  local numShopId = tonumber(shopId)
  if not numShopId then
    log("W", "Career", "getVehicleInfoByShopId: Invalid shopId type: " .. tostring(shopId))
    return nil
  end
  for _, vehInfo in ipairs(state.vehiclesInShop) do
    if vehInfo.shopId == numShopId then
      return vehInfo
    end
  end
  return nil
end

helpers.isCarMeetShopVehicle = function(vehicleInfo)
  return vehicleInfo and (vehicleInfo.source == "carMeet" or vehicleInfo.sellerId == "carMeet")
end

helpers.normalizeVehicleShopTiming = function(vehicleInfo, currentTime)
  if not vehicleInfo then return end
  currentTime = currentTime or os.time()
  -- guard against OS clock adjusted back in time
  vehicleInfo.generationTime = math.min(tonumber(vehicleInfo.generationTime) or currentTime, currentTime)
  vehicleInfo.offerTTL = tonumber(vehicleInfo.offerTTL) or (24 * 60 * 60)
end

helpers.registerCarMeetVehicle = function(vehicleInfo)
  if not vehicleInfo then return nil end
  local info = deepcopy(vehicleInfo)
  info.shopId = info.shopId or helpers.generateShopId()
  info.sellerId = "carMeet"
  info.sellerName = info.sellerName or "Car Meet Owner"
  info.negotiationPossible = true
  info.playerStartsNegotiation = true
  info.hideMarketValue = true
  info.tax = tonumber(info.tax) or 0
  info.fees = tonumber(info.fees) or 0
  info.Value = tonumber(info.Value) or tonumber(info.marketValue) or 10000
  info.marketValue = tonumber(info.marketValue) or info.Value
  info.marketValueBase = info.marketValue
  info.Mileage = tonumber(info.Mileage) or 0
  info.mapId = getCurrentLevelIdentifier()
  helpers.normalizeVehicleShopTiming(info)
  info.negotiationPersonality = info.negotiationPersonality or overhaul_career_market_marketplace.generatePersonality(false)
  if info.negotiationPersonality and info.negotiationPersonality.name then
    info.sellerName = info.negotiationPersonality.name
  end
  local priceMultiplier = (info.negotiationPersonality and info.negotiationPersonality.priceMultiplier) or 1
  priceMultiplier = math.max(0.95, math.min(1.05, tonumber(priceMultiplier) or 1))
  info.priceMultiplier = priceMultiplier
  info.valueBase = tonumber(info.valueBase) or info.marketValue * priceMultiplier
  local vehicleBuyMult = overhaul_career_market_valueCalculator.getVehicleBuyMarketMultiplier()
  info.Value = helpers.getRoundedPrice(info.valueBase * vehicleBuyMult, info.priceRoundingType or "private")
  table.insert(state.vehiclesInShop, info)
  return info.shopId
end

helpers.removeCarMeetVehicles = function()
  for i = #state.vehiclesInShop, 1, -1 do
    if state.vehiclesInShop[i].sellerId == "carMeet" or state.vehiclesInShop[i].source == "carMeet" then
      table.remove(state.vehiclesInShop, i)
    end
  end
end

helpers.generateSoldVehicleValue = function(shopId)
  local vehicleInfo = helpers.getVehicleInfoByShopId(shopId)
  if not vehicleInfo then return 0 end
  local value = vehicleInfo.Value * (0.9 + math.random() * 0.1)
  return round(value / 10) * 10
end

helpers.getRoundedPrice = function(value, priceRoundingType)
  if priceRoundingType == "prestige" then
    local thousands = math.floor(value / 1000)
    local candidate495 = thousands * 1000 + 495
    if value <= candidate495 then return candidate495 end
    local candidate995 = thousands * 1000 + 995
    if value <= candidate995 then return candidate995 end
    return (thousands + 1) * 1000 + 495
  elseif priceRoundingType == "private" then
    return math.ceil(value / 100) * 100
  elseif priceRoundingType == "dealer" then
    return math.ceil(value / 20) * 20
  else
    return math.ceil(value / 10) * 10
  end
end

helpers.getEligibleVehiclesWithoutDealershipVehicles = function(eligibleVehicles, seller)
  local eligibleVehiclesWithoutDealershipVehicles = deepcopy(eligibleVehicles)
  local configsInDealership = {}
  for _, vehicleInfo in ipairs(state.vehiclesInShop) do
    if vehicleInfo.sellerId == seller.id then
      configsInDealership[vehicleInfo.model_key] = configsInDealership[vehicleInfo.model_key] or {}
      configsInDealership[vehicleInfo.model_key][vehicleInfo.key] = true
    end
  end

  for i = #eligibleVehiclesWithoutDealershipVehicles, 1, -1 do
    local vehicleInfo = eligibleVehiclesWithoutDealershipVehicles[i]
    if configsInDealership[vehicleInfo.model_key] and configsInDealership[vehicleInfo.model_key][vehicleInfo.key] then
      table.remove(eligibleVehiclesWithoutDealershipVehicles, i)
    end
  end
  return eligibleVehiclesWithoutDealershipVehicles
end

helpers.getUiDealershipsData = function(unsoldVehicles)
  local privateSellers = overhaul_world_facilities.getFacilitiesByType("privateSeller") or {}
  local dealerships = overhaul_world_facilities.getFacilitiesByType("dealership")
  local vehicleCountPerDealership = {}
  for _, vehicle in ipairs(unsoldVehicles) do
    if not helpers.isCarMeetShopVehicle(vehicle) then
      vehicleCountPerDealership[vehicle.sellerId] = (vehicleCountPerDealership[vehicle.sellerId] or 0) + 1
    end
  end
  local data = {}
  if dealerships then
    for _, dealership in ipairs(dealerships) do
      local policeLocked = helpers.isPoliceDealershipLocked(dealership.id)
      local discovered = helpers.isDealerDiscovered(dealership)
      local accessInfo = helpers.getSellerAccessInfo(dealership)
      table.insert(data, {
        id = dealership.id,
        name = _tr(dealership.name),
        description = _tr(dealership.description),
        vehicleCount = vehicleCountPerDealership[dealership.id] or 0,
        preview = dealership.preview,
        icon = "carDealer",
        remotePurchaseOnly = dealership.remotePurchaseOnly or false,
        hiddenFromDealerList = dealership.hiddenFromDealerList or not discovered,
        undiscovered = not discovered,
        salesChannel = accessInfo.salesChannel,
        remotePurchaseAllowed = accessInfo.remotePurchaseAllowed,
        garageDeliveryAllowed = accessInfo.garageDeliveryAllowed,
        deliveryDiscount = accessInfo.deliveryDiscount,
        disabled = policeLocked,
        disabledReason = policeLocked and helpers.getPoliceDealershipLockLabel(dealership.id) or nil,
      })
    end
  end
  table.sort(data, function(a,b) return a.name < b.name end)
  table.insert(data, {
    id = "private",
    name = _tr("ui.career.vehicleShopping.privateSellers"),
    vehicleCount = vehicleCountPerDealership["private"] or 0,
    preview = privateSellers[1] and privateSellers[1].preview,
    icon = "personSolid",
    disabled = false,
  })
  return data
end

helpers.sanitizeVehicleForUi = function(vehicleInfo, fullListing)
  local uiVehicle = {}
  uiVehicle.shopId = vehicleInfo.shopId

  for key, value in pairs(fullListing and vehicleInfo or cardProjection.card(vehicleInfo)) do
    local valueType = type(value)
    if key == "pos" then
      if value and value.x then
        uiVehicle.pos = {
          x = value.x,
          y = value.y,
          z = value.z
        }
      end
    elseif key == "precomputedFilter" or key == "filter" or key == "distanceVec" then
    elseif valueType == "function" or valueType == "userdata" then
    else
      uiVehicle[key] = value
    end
  end
  -- Use a model image instead of the generic app icon when the config has no image.
  if type(uiVehicle.preview) == "string" and uiVehicle.preview:find("appDefault.png", 1, true) then
    local modelData = uiVehicle.model_key and core_vehicles.getModel(uiVehicle.model_key) or nil
    local modelPreview = modelData and modelData.model and modelData.model.preview
    if type(modelPreview) == "string" and not modelPreview:find("appDefault.png", 1, true) then
      uiVehicle.preview = modelPreview
    else
      uiVehicle.preview = nil
    end
  end
  return uiVehicle
end

helpers.convertKeysToStrings = function(vehicles)
  local unsoldVehicles = {}
  local soldVehiclesResult = {}
  for index, vehicleInfo in ipairs(vehicles) do
    if vehicleInfo.soldViewCounter and vehicleInfo.soldViewCounter > 0 then
      table.insert(soldVehiclesResult, vehicleInfo)
    else
      table.insert(unsoldVehicles, vehicleInfo)
    end
  end
  return unsoldVehicles, soldVehiclesResult
end

helpers.sanitizeOrganizationForUi = function(org)
  if not org then
    return nil
  end

  local sanitizedOrg = {
    reputationLevels = {},
    reputation = {}
  }

  if org.reputation then
    local repLevel = org.reputation.level or 0
    if type(repLevel) ~= "number" then
      repLevel = 0
    end
    sanitizedOrg.reputation.level = repLevel
    sanitizedOrg.reputation.levelIndex = repLevel + 2
    sanitizedOrg.reputation.value = org.reputation.value
    sanitizedOrg.reputation.curLvlProgress = org.reputation.curLvlProgress
    sanitizedOrg.reputation.neededForNext = org.reputation.neededForNext
    sanitizedOrg.reputation.prevThreshold = org.reputation.prevThreshold
    sanitizedOrg.reputation.nextThreshold = org.reputation.nextThreshold
  else
    sanitizedOrg.reputation.level = 0
    sanitizedOrg.reputation.levelIndex = 2
  end

  if org.reputationLevels then
    for idx, lvl in pairs(org.reputationLevels) do
      sanitizedOrg.reputationLevels[idx] = {
        hiddenFromDealerList = lvl and lvl.hiddenFromDealerList or nil
      }
    end
  end

  return sanitizedOrg
end

helpers.collectOrganizationsForUi = function(facilities)
  local organizations = {}
  if not facilities or not facilities.dealerships then
    return organizations
  end

  local organizationsById = overhaul_world_organizations.getOrganizations()
  for _, dealer in ipairs(facilities.dealerships) do
    local orgId = dealer.associatedOrganization
    if orgId and not organizations[orgId] then
      local org = organizationsById and organizationsById[orgId]
      local sanitizedOrg = helpers.sanitizeOrganizationForUi(org)
      if sanitizedOrg then
        organizations[orgId] = sanitizedOrg
      end
    end
  end

  return organizations
end

helpers.getVisualValueFromMileage = function(mileage)
  mileage = clamp(mileage, 0, 2000000000)
  if mileage <= 10000000 then
    return 1
  elseif mileage <= 50000000 then
    return rescale(mileage, 10000000, 50000000, 1, 0.95)
  elseif mileage <= 100000000 then
    return rescale(mileage, 50000000, 100000000, 0.95, 0.925)
  elseif mileage <= 200000000 then
    return rescale(mileage, 100000000, 200000000, 0.925, 0.88)
  elseif mileage <= 500000000 then
    return rescale(mileage, 200000000, 500000000, 0.88, 0.825)
  elseif mileage <= 1000000000 then
    return rescale(mileage, 500000000, 1000000000, 0.825, 0.8)
  else
    return rescale(mileage, 1000000000, 2000000000, 0.8, 0.75)
  end
end

helpers.getDeliveryDelay = function(distance)
  distance = math.max(0, tonumber(distance) or 0)
  return clamp(shoppingConfig.vehicleDeliveryDelay + math.floor((distance / 1000) * 10 + 0.5), shoppingConfig.vehicleDeliveryDelay, 600)
end

helpers.getSellerReputationLevel = function(dealership)
  if not dealership or not dealership.associatedOrganization then return 0 end
  local org = overhaul_world_organizations.getOrganization(dealership.associatedOrganization)
  local level = org and org.reputation and tonumber(org.reputation.level) or 0
  return math.max(0, math.floor(level or 0))
end

helpers.getSellerAccessInfo = function(dealership)
  dealership = dealership or {}
  local salesChannel = dealership.salesChannel or (dealership.remotePurchaseOnly and "factory" or "local")
  local repLevel = helpers.getSellerReputationLevel(dealership)
  local isOnline = salesChannel == "factory" or salesChannel == "remanufactured"
  local remotePurchaseAllowed = isOnline or repLevel >= (tonumber(dealership.remotePurchaseLevel) or shoppingConfig.REMOTE_PURCHASE_LEVEL)
  local garageDeliveryAllowed = repLevel >= (tonumber(dealership.garageDeliveryLevel) or shoppingConfig.REMOTE_PURCHASE_LEVEL)
  local discount = 0
  if type(dealership.deliveryDiscounts) == "table" then
    for requiredLevel, configuredDiscount in pairs(dealership.deliveryDiscounts) do
      if repLevel >= (tonumber(requiredLevel) or math.huge) then
        discount = math.max(discount, tonumber(configuredDiscount) or 0)
      end
    end
  elseif repLevel >= (tonumber(dealership.deliveryDiscountLevel) or shoppingConfig.DELIVERY_DISCOUNT_LEVEL) then
    discount = tonumber(dealership.deliveryDiscount) or shoppingConfig.DELIVERY_DISCOUNT_AT_LEVEL_3
  end
  return {
    salesChannel = salesChannel,
    reputationLevel = repLevel,
    isOnline = isOnline,
    remotePurchaseAllowed = remotePurchaseAllowed,
    garageDeliveryAllowed = garageDeliveryAllowed,
    deliveryDiscount = clamp(discount, 0, 0.95)
  }
end

helpers.getDealershipForSellerId = function(sellerId)
  if not sellerId or sellerId == "private" or sellerId == "carMeet" then
    return nil
  end
  return overhaul_world_facilities.getDealership(sellerId)
end

-- Stock saved while the map's personality data was still loading has none; negotiation fills it in
-- from the vehicle's seller, the same way stock generation chooses it.
helpers.ensureNegotiationPersonality = function(vehicleInfo)
  if not vehicleInfo then return nil end
  if vehicleInfo.negotiationPersonality then return vehicleInfo.negotiationPersonality end
  local dealership = helpers.getDealershipForSellerId(vehicleInfo.sellerId)
  local archetype = dealership and (dealership.negotiationArchetype or vehicleInfo.sellerId)
  vehicleInfo.negotiationPersonality = overhaul_career_market_marketplace.generatePersonality(false,
    archetype and {archetype} or nil)
  return vehicleInfo.negotiationPersonality
end

helpers.isOnlineSellerId = function(sellerId)
  local dealership = helpers.getDealershipForSellerId(sellerId)
  if not dealership then return false end
  return helpers.getSellerAccessInfo(dealership).isOnline
end

helpers.getExpectedMileageMiles = usedVehicleCondition.getExpectedMileageMiles
helpers.generateAgeDrivenMileage = usedVehicleCondition.generateAgeDrivenMileage

helpers.getDiscoveredDealersForMap = function(mapId)
  mapId = mapId or getCurrentLevelIdentifier()
  state.discoveredDealers[mapId] = state.discoveredDealers[mapId] or {}
  return state.discoveredDealers[mapId]
end

helpers.isDealerDiscovered = function(dealership)
  if not dealership then return false end
  local accessInfo = helpers.getSellerAccessInfo(dealership)
  if dealership.discoverable == false or accessInfo.isOnline then return true end
  return helpers.getDiscoveredDealersForMap()[dealership.id] == true
end

helpers.discoverDealer = function(dealershipId)
  local dealership = overhaul_world_facilities.getDealership(dealershipId)
  if not dealership or dealership.discoverable == false then return false end
  if helpers.getSellerAccessInfo(dealership).isOnline then return false end
  local mapDiscoveries = helpers.getDiscoveredDealersForMap()
  if mapDiscoveries[dealershipId] then return false end
  mapDiscoveries[dealershipId] = true
  recordDiscovery({name = dealership.name or dealershipId,
    receipt = tostring(getCurrentLevelIdentifier()) .. ":" .. tostring(dealershipId)})
  -- Save discovery immediately because a later purchase or autosave may never occur.
  overhaul_career_saveSystem.saveCurrent()
  ui_message(string.format("%s is now available in the vehicle-shopping computer.",
    dealership.name or "Dealership"), 6, "Dealership discovered", "info")
  return true
end

-- Tester: marks every discoverable dealership on this map as discovered and saves once.
helpers.discoverAllDealers = function()
  local mapDiscoveries = helpers.getDiscoveredDealersForMap()
  local count = 0
  for _, dealership in ipairs(overhaul_world_facilities.getFacilitiesByType("dealership") or {}) do
    if dealership.id and not helpers.isDealerDiscovered(dealership) then
      mapDiscoveries[dealership.id] = true
      count = count + 1
    end
  end
  if count > 0 then overhaul_career_saveSystem.saveCurrent() end
  return count
end

helpers.applyPurchaseAdjustedMarketValue = function(vehicleInfo)
  if not vehicleInfo then return end
  local vehicleBuyMult = overhaul_career_market_valueCalculator.getVehicleBuyMarketMultiplier()
  local marketValue = vehicleInfo.marketValueBase or vehicleInfo.marketValue or vehicleInfo.Value
  vehicleInfo.marketValueAdjusted = math.floor((marketValue or 0) * vehicleBuyMult + 0.5)

  local valueBase = vehicleInfo.valueBase
  if not valueBase then
    if vehicleInfo.marketValue and vehicleInfo.negotiationPersonality and vehicleInfo.negotiationPersonality.priceMultiplier then
      valueBase = vehicleInfo.marketValue * vehicleInfo.negotiationPersonality.priceMultiplier
    else
      valueBase = vehicleInfo.Value
    end
  end
  if valueBase then
    vehicleInfo.valueAdjusted = helpers.getRoundedPrice(valueBase * vehicleBuyMult, vehicleInfo.priceRoundingType or "default")
  else
    vehicleInfo.valueAdjusted = vehicleInfo.Value
  end
end

helpers.getOrgLevelData = function(org, offset)
  if not org then
    return nil
  end
  local repLevel = (org.reputation and org.reputation.level) or 0
  if type(repLevel) ~= "number" then
    repLevel = 0
  end
  local levels = org.reputationLevels
  if not levels then
    return nil
  end
  local arrayIndex = repLevel + 2 + (offset or 0)
  if arrayIndex < 1 or arrayIndex > #levels then
    return nil
  end
  return levels[arrayIndex]
end

-- Delta tracking ----------------------------------------------------------------------------------
helpers.buildSnapshot = function()
  local snapshotByShopId = {}
  for _, vehicleInfo in ipairs(state.vehiclesInShop) do
    if not helpers.isCarMeetShopVehicle(vehicleInfo) then
      snapshotByShopId[vehicleInfo.shopId] = vehicleInfo
    end
  end
  return snapshotByShopId
end

helpers.commitDelta = function(newSnapshotByShopId, justExpiredShopIds)
  justExpiredShopIds = justExpiredShopIds or {}
  local added, removed, sold, updated = {}, {}, {}, {}
  for shopId, vehicleInfo in pairs(newSnapshotByShopId) do
    if not state.lastSnapshotByShopId[shopId] then
      table.insert(added, helpers.sanitizeVehicleForUi(vehicleInfo))
    end
  end
  for shopId, vehicleInfo in pairs(newSnapshotByShopId) do
    local previousVehicleInfo = state.lastSnapshotByShopId[shopId]
    if previousVehicleInfo and vehicleInfo then
      local wasMarkedSold = previousVehicleInfo.markedSold == true
      local isMarkedSold = vehicleInfo.markedSold == true
      local previousSoldViewCount = (previousVehicleInfo.soldViewCounter or 0)
      local currentSoldViewCount = (vehicleInfo.soldViewCounter or 0)

      if justExpiredShopIds[shopId] or (isMarkedSold and not wasMarkedSold) or (currentSoldViewCount > previousSoldViewCount) then
        local soldVehicleForUi = helpers.sanitizeVehicleForUi(vehicleInfo)
        soldVehicleForUi.__sold = true
        table.insert(updated, soldVehicleForUi)
      end
    end
  end
  for shopId, _ in pairs(state.lastSnapshotByShopId) do
    if not newSnapshotByShopId[shopId] then
      if state.pendingSoldShopIds[shopId] then
        local previousVehicleInfo = state.lastSnapshotByShopId[shopId]
        if previousVehicleInfo then
          local soldVehicleForUi = helpers.sanitizeVehicleForUi(previousVehicleInfo)
          soldVehicleForUi.shopId = shopId
          soldVehicleForUi.__sold = true
          table.insert(sold, soldVehicleForUi)
        else
          table.insert(sold, shopId)
        end
        state.pendingSoldShopIds[shopId] = nil
      else
        table.insert(removed, shopId)
      end
    end
  end
  state.lastSnapshotByShopId = newSnapshotByShopId
  state.deltaSeq = state.deltaSeq + 1
  state.lastDelta = {
    seq = state.deltaSeq,
    added = added,
    removed = removed,
    sold = sold,
    updated = updated,
    organizations = helpers.collectOrganizationsForUi(overhaul_world_facilities.getFacilities(getCurrentLevelIdentifier())),
    dealershipPurchaseReputationGain = shoppingConfig.dealershipPurchaseReputationGain
  }
end

-- Parts -------------------------------------------------------------------------------------------
parts.validation = require("overhaul/career/market/vehicleShopping/validation").new {
  state = state,
  config = shoppingConfig,
  usedVehicleCondition = usedVehicleCondition,
}
parts.fleet = require("overhaul/career/market/vehicleShopping/fleet").new {
  state = state,
}
parts.ui = require("overhaul/career/market/vehicleShopping/ui").new {
  state = state,
  config = shoppingConfig,
}
parts.catalog = require("overhaul/career/market/vehicleShopping/catalog").new {
  state = state,
}
parts.stock = require("overhaul/career/market/vehicleShopping/stock").new {
  state = state,
  config = shoppingConfig,
}
parts.spawn = require("overhaul/career/market/vehicleShopping/spawn").new {
  state = state,
  owner = M,
}
parts.purchase = require("overhaul/career/market/vehicleShopping/purchase").new {
  state = state,
  config = shoppingConfig,
}

-- Bind cycles after every service exists; calls read sibling APIs when they run.
parts.validation.bindServices {
  getOrgLevelData = helpers.getOrgLevelData,
}

parts.fleet.bindServices {
  getDeliveryDelay = helpers.getDeliveryDelay,
}

parts.ui.bindServices {
  ensureNegotiationPersonality = helpers.ensureNegotiationPersonality,
  applyPurchaseAdjustedMarketValue = helpers.applyPurchaseAdjustedMarketValue,
  collectOrganizationsForUi = helpers.collectOrganizationsForUi,
  convertKeysToStrings = helpers.convertKeysToStrings,
  discoverDealer = helpers.discoverDealer,
  getDealershipForSellerId = helpers.getDealershipForSellerId,
  getDeliveryDelay = helpers.getDeliveryDelay,
  getPoliceDealershipLockLabel = helpers.getPoliceDealershipLockLabel,
  getSellerAccessInfo = helpers.getSellerAccessInfo,
  getUiDealershipsData = helpers.getUiDealershipsData,
  getVehicleInfoByShopId = helpers.getVehicleInfoByShopId,
  isCarMeetShopVehicle = helpers.isCarMeetShopVehicle,
  isDealerDiscovered = helpers.isDealerDiscovered,
  isOnlineSellerId = helpers.isOnlineSellerId,
  isPoliceDealershipLocked = helpers.isPoliceDealershipLocked,
  sanitizeVehicleForUi = helpers.sanitizeVehicleForUi,
  fleet = parts.fleet,
  purchase = parts.purchase,
  spawn = parts.spawn,
  stock = parts.stock,
  validation = parts.validation,
}

parts.catalog.bindServices {
  getOrgLevelData = helpers.getOrgLevelData,
  validation = parts.validation,
}

parts.stock.bindServices {
  buildSnapshot = helpers.buildSnapshot,
  commitDelta = helpers.commitDelta,
  generateAgeDrivenMileage = helpers.generateAgeDrivenMileage,
  generateShopId = helpers.generateShopId,
  generateSoldVehicleValue = helpers.generateSoldVehicleValue,
  getDealershipForSellerId = helpers.getDealershipForSellerId,
  getOrgLevelData = helpers.getOrgLevelData,
  getRoundedPrice = helpers.getRoundedPrice,
  getSellerAccessInfo = helpers.getSellerAccessInfo,
  isCarMeetShopVehicle = helpers.isCarMeetShopVehicle,
  isPoliceDealershipLocked = helpers.isPoliceDealershipLocked,
  normalizeVehicleShopTiming = helpers.normalizeVehicleShopTiming,
  catalog = parts.catalog,
  validation = parts.validation,
}

parts.spawn.bindServices {
  getDealershipForSellerId = helpers.getDealershipForSellerId,
  getVisualValueFromMileage = helpers.getVisualValueFromMileage,
  purchase = parts.purchase,
}

parts.purchase.bindServices {
  isPoliceDealershipLocked = helpers.isPoliceDealershipLocked,
  buildSnapshot = helpers.buildSnapshot,
  commitDelta = helpers.commitDelta,
  getDealershipForSellerId = helpers.getDealershipForSellerId,
  getDeliveryDelay = helpers.getDeliveryDelay,
  getSellerAccessInfo = helpers.getSellerAccessInfo,
  getVehicleInfoByShopId = helpers.getVehicleInfoByShopId,
  fleet = parts.fleet,
  spawn = parts.spawn,
  ui = parts.ui,
  validation = parts.validation,
}

-- Per-frame update --------------------------------------------------------------------------------
-- UI state ----------------------------------------------------------------------------------------
-- Phone buy and computer shop both restock; counting keeps refresh on until both close.
helpers.setShoppingUiOpen = function(isOpen)
  if isOpen then
    state.shoppingUiOpenCount = state.shoppingUiOpenCount + 1
  else
    state.shoppingUiOpenCount = math.max(0, state.shoppingUiOpenCount - 1)
  end
  state.uiOpen = state.shoppingUiOpenCount > 0
  if not state.uiOpen then parts.ui.cancelTravelQuotes() end
  state.refreshAccumulator = 0
  if isOpen then
    parts.stock.updateVehicleList(false)
    state.nextShopUpdateTime = 0
  end
end

helpers.onUiChangedState = function(toState)
  state.currentUiState = toState
end

helpers.onUpdate = function(dt)
  parts.ui.updateTravelQuotes(dt)
  parts.spawn.processRewardVehicleGrants(dt)
  local attempt = state.personalPurchaseAttempt
  if attempt then
    attempt.elapsed = (attempt.elapsed or 0) + math.max(dt or 0, 0)
    if attempt.elapsed >= 30 then parts.spawn.cancelPersonalPurchase() end
  end
  state.rtPendingFleetAccumulator = (state.rtPendingFleetAccumulator or 0) + dt
  if state.rtPendingFleetAccumulator >= 1 then
    state.rtPendingFleetAccumulator = 0
    parts.fleet.processPendingRacingTeamFleetPurchases()
  end
  state.refreshAccumulator = state.refreshAccumulator + dt
  if state.refreshAccumulator < 5 then
    return
  end
  state.refreshAccumulator = 0

  -- Watchlist expiration check
  if not tableIsEmpty(state.vehicleWatchlist) and (not state.currentUiState or state.currentUiState == "play") then
    local currentTime = os.time()
    local inspectedVehicleInfo = overhaul_career_market_inspectVehicle.getSpawnedVehicleInfo()
    for shopId, status in pairs(state.vehicleWatchlist) do
      if status == "unsold" and (not inspectedVehicleInfo or inspectedVehicleInfo.shopId ~= shopId) then
        local vehicleInfo = helpers.getVehicleInfoByShopId(shopId)
        if vehicleInfo then
          helpers.normalizeVehicleShopTiming(vehicleInfo, currentTime)
          local offerTime = currentTime - vehicleInfo.generationTime
          if offerTime > vehicleInfo.offerTTL then
            vehicleInfo.soldFor = helpers.generateSoldVehicleValue(shopId)
            state.vehicleWatchlist[shopId] = "sold"
            guihooks.trigger("toastrMsg", {type="info", title="A vehicle you were interested in has been sold.", msg = vehicleInfo.Name .. " for $" .. string.format("%.2f", vehicleInfo.soldFor)})
            break
          end
        end
      end
    end
  end

  -- UI refresh logic
  if not state.uiOpen then
    return
  end
  local now = os.time()
  if (state.nextShopUpdateTime == 0) or (now >= state.nextShopUpdateTime) then
    parts.stock.updateVehicleList(false)
  end

  M.checkSpawnedVehicleStatus()
end

-- Dealer renames are scoped to their owning map and the recorded shop version.
local function migrateDealerSnapshot(snapshot, mapId, saveVersion)
  local function renamed(id)
    return levelData.resolveAlias('dealer', id, {levelId = mapId, facilityId = id, saveVersion = saveVersion})
  end
  for _, vehicle in ipairs(snapshot.vehiclesInShop or {}) do vehicle.sellerId = renamed(vehicle.sellerId) end
  local sellers = {}
  for id, seller in pairs(snapshot.sellersInfos or {}) do
    local target = renamed(id)
    seller.id = seller.id and renamed(seller.id)
    if sellers[target] == nil or target == id then sellers[target] = seller end
  end
  snapshot.sellersInfos = sellers
end

local function savedStockNeedsRegeneration(vehicle, mapId, savedSchemaVersion)
  local action = levelData.resolveAlias('sellerStockRegeneration', vehicle.sellerId, {
    levelId = mapId, facilityId = vehicle.sellerId, saveVersion = savedSchemaVersion or 0,
  })
  if action == 'regenerate' then return true end
  for _, dealer in ipairs(overhaul_world_facilities.getFacilitiesByType('dealership', mapId) or {}) do
    if dealer.id == vehicle.sellerId and dealer.stockSchemaVersion then
      local version = tonumber(vehicle.stockSchemaVersion)
        or (dealer.stockPolicy == 'limitedMileage' and savedSchemaVersion) or 0
      return version < dealer.stockSchemaVersion
    end
  end
  return false
end

local function restoreShoppingMapSnapshots(data, currentMap, savedSchemaVersion)
  if data.maps then
    state.otherMapsData = data.maps
    for mapId, mapData in pairs(state.otherMapsData) do
      migrateDealerSnapshot(mapData, mapId, tonumber(data.version))
      if mapData.vehiclesInShop then
        local sanitizedVehicles, loadSummary = parts.validation.sanitizeSavedVehicleEntries(mapData.vehiclesInShop,
          "load:" .. tostring(mapId))
        for i = #sanitizedVehicles, 1, -1 do
          if savedStockNeedsRegeneration(sanitizedVehicles[i], mapId, savedSchemaVersion) then
            table.remove(sanitizedVehicles, i)
          end
        end
        mapData.vehiclesInShop = sanitizedVehicles
        if loadSummary.raw > 0 then
          parts.validation.logVehicleSanitizationSummary("saved vehicle load " .. tostring(mapId), loadSummary)
        end
      end
    end
  else
    -- Migration from old flat format
    local oldVehicles = data.vehiclesInShop or {}
    local oldSellers = data.sellersInfos or {}
    local oldDirtyDate = data.dirtyDate
    for _, vehicle in ipairs(oldVehicles) do
      vehicle.sellerId = levelData.resolveAlias('dealer', vehicle.sellerId, {
        levelId = vehicle.mapId or currentMap, facilityId = vehicle.sellerId, saveVersion = tonumber(data.version),
      })
    end

    for _, vehicleInfo in ipairs(oldVehicles) do
      local sanitizedVehicles, _ = parts.validation.sanitizeSavedVehicleEntries({vehicleInfo}, "load:migration")
      local sanitizedVehicle = sanitizedVehicles[1]
      if sanitizedVehicle and not savedStockNeedsRegeneration(sanitizedVehicle,
        sanitizedVehicle.mapId or currentMap, savedSchemaVersion) then
        local mId = sanitizedVehicle.mapId or currentMap
        if not state.otherMapsData[mId] then state.otherMapsData[mId] = {vehiclesInShop = {}, sellersInfos = {}} end
        table.insert(state.otherMapsData[mId].vehiclesInShop, sanitizedVehicle)
      end
    end

    for sellerId, sellerInfo in pairs(oldSellers) do
      local mId = sellerInfo.mapId or currentMap
      if not state.otherMapsData[mId] then state.otherMapsData[mId] = {vehiclesInShop = {}, sellersInfos = {}} end
      local target = levelData.resolveAlias('dealer', sellerId, {
        levelId = mId, facilityId = sellerId, saveVersion = tonumber(data.version),
      })
      state.otherMapsData[mId].sellersInfos[target] = sellerInfo
    end

    -- Assign dirty date to the current map if it was migration
    if state.otherMapsData[currentMap] then
      state.otherMapsData[currentMap].dirtyDate = oldDirtyDate
    end
  end
end

local function restoreShoppingProgressAndPendingPurchases(savedData)
  state.discoveredDealers = savedData and type(savedData.discoveredDealers) == "table"
    and savedData.discoveredDealers or {}
  for mapId, discoveries in pairs(state.discoveredDealers) do
    local migrated = {}
    for id, found in pairs(discoveries) do
      local target = levelData.resolveAlias('dealer', id, {
        levelId = mapId, facilityId = id, saveVersion = tonumber(savedData.version),
      })
      migrated[target] = migrated[target] or found
    end
    state.discoveredDealers[mapId] = migrated
  end
  state.rtPendingFleetPurchases = savedData and type(savedData.rtPendingFleetPurchases) == "table"
    and savedData.rtPendingFleetPurchases or {}
  state.rewardVehicleGrants = savedData and type(savedData.rewardVehicleGrants) == "table"
    and savedData.rewardVehicleGrants or {}
  state.rewardVehicleGrantData = nil
  for _, grant in ipairs(state.rewardVehicleGrants) do
    grant.token, grant.spawnedVehId, grant.elapsed = nil, nil, nil
  end
  for _, entries in pairs(state.rtPendingFleetPurchases) do
    for _, pending in ipairs(entries) do
      pending.purchaseId = pending.purchaseId or Engine.generateUUID()
      if pending.kind == "drive" then
        pending.kind, pending.dueEpoch, pending.spawnedVehId = "timer", os.time(), nil
      end
    end
  end
end

helpers.onExtensionLoaded = function()
  if not overhaul_career_career.isActive() then
    return false
  end

  parts.validation.resetVehicleValidationState()
  -- Catalog is prepared once at world ready; building here too repeated the work on career load.

  state.purchaseMenuOpen = false
  state.inspectingVehicleShopId = nil

  local saveSlot, savePath = overhaul_career_saveSystem.getCurrentProfile()
  if not saveSlot or not savePath then
    return
  end

  local savedData = jsonReadFile(savePath .. "/career/vehicleShop.json")
  -- Compare the shop module version; info.json's save-system version is a different number.
  local outdated = not savedData or (tonumber(savedData.version) or 0) < shoppingConfig.moduleVersion

  -- Discovery is player progress, not generated inventory, so it loads even when saved offers are discarded.
  restoreShoppingProgressAndPendingPurchases(savedData)

  local data = not outdated and savedData
  if data and tonumber(data.valuationSchemaVersion) ~= shoppingConfig.valuationSchemaVersion then
    log("I", "vehicleShopping", string.format(
      "Discarding saved shop offers from valuation schema %s; current schema is %d",
      tostring(data.valuationSchemaVersion), shoppingConfig.valuationSchemaVersion))
    data = nil
    state.otherMapsData = {}
    state.vehiclesInShop = {}
    state.sellersInfos = {}
    state.vehicleWatchlist = {}
  end
  if data then
    local currentMap = getCurrentLevelIdentifier()
    local savedSchemaVersion = tonumber(data.limitedMileageDealerSchemaVersion) or 0
    -- JSON converts numeric shopId keys to strings.
    state.vehicleWatchlist = {}
    for shopId, status in pairs(data.vehicleWatchlist or {}) do
      state.vehicleWatchlist[tonumber(shopId) or shopId] = status
    end

    -- New format with 'maps' key
    restoreShoppingMapSnapshots(data, currentMap, savedSchemaVersion)

    local currentData = state.otherMapsData[currentMap] or {}
    local sanitizedVehicles, loadSummary = parts.validation.sanitizeSavedVehicleEntries(currentData.vehiclesInShop or {},
      "load:current:" .. tostring(currentMap))
    if loadSummary.raw > 0 then
      parts.validation.logVehicleSanitizationSummary("saved vehicle load current " .. tostring(currentMap), loadSummary)
    end
    currentData.vehiclesInShop = sanitizedVehicles
    state.vehiclesInShop = sanitizedVehicles
    state.sellersInfos = currentData.sellersInfos or {}
    state.vehicleShopDirtyDate = currentData.dirtyDate
    state.lastMap = currentMap
  end
end

helpers.onOverhaulSaveCurrentProfile = function(currentSavePath)
  local currentMap = getCurrentLevelIdentifier()

  state.otherMapsData[currentMap] = {
    vehiclesInShop = state.vehiclesInShop,
    sellersInfos = state.sellersInfos,
    dirtyDate = state.vehicleShopDirtyDate
  }

  local data = {}
  data.maps = state.otherMapsData
  data.vehicleWatchlist = state.vehicleWatchlist
  data.rtPendingFleetPurchases = state.rtPendingFleetPurchases
  data.rewardVehicleGrants = state.rewardVehicleGrants
  data.discoveredDealers = state.discoveredDealers
  data.version = shoppingConfig.moduleVersion
  data.valuationSchemaVersion = shoppingConfig.valuationSchemaVersion
  data.limitedMileageDealerSchemaVersion = M.limitedMileageDealerSchemaVersion

  overhaul_career_saveSystem.jsonWriteFileSafe(currentSavePath .. "/career/vehicleShop.json", data, true)
end

helpers.getCurrentSellerId = function()
  return state.currentSeller
end

helpers.onOverhaulComputerAddFunctions = function(menuData, computerFunctions)
  local computerFunctionData = {
    id = "vehicleShop",
    label = "Vehicle Marketplace",
    routeTarget = "overhaul.computer.vehicleShopping",
    callback = function()
      parts.ui.openShop(nil, menuData.computerFacility.id)
    end,
    order = 10
  }
  local reason = overhaul_career_permissions.getStatusForTag("vehicleShopping")
  if not reason.allow then
    computerFunctionData.disabled = true
  end
  if reason.permission ~= "allowed" then
    computerFunctionData.reason = reason
  end

  computerFunctions.general[computerFunctionData.id] = computerFunctionData
end

helpers.onModActivated = function()
  -- Coalesce mod activation bursts; rebuild once on the next stock update.
  parts.catalog.invalidateVehicleCache()
end

helpers.onWorldReadyState = function(worldReadyState)
  if worldReadyState == 2 then
    local currentMap = getCurrentLevelIdentifier()

    if state.lastMap and state.lastMap ~= currentMap then
      state.otherMapsData[state.lastMap] = {
        vehiclesInShop = state.vehiclesInShop,
        sellersInfos = state.sellersInfos,
        dirtyDate = state.vehicleShopDirtyDate
      }
    end

    if state.otherMapsData[currentMap] then
      local currentData = state.otherMapsData[currentMap]
      local sanitizedVehicles, loadSummary = parts.validation.sanitizeSavedVehicleEntries(currentData.vehiclesInShop or {},
        "onWorldReadyState:" .. tostring(currentMap))
      if loadSummary.raw > 0 then
        parts.validation.logVehicleSanitizationSummary("world load " .. tostring(currentMap), loadSummary)
      end
      currentData.vehiclesInShop = sanitizedVehicles
      state.vehiclesInShop = sanitizedVehicles
      state.sellersInfos = currentData.sellersInfos or {}
      state.vehicleShopDirtyDate = currentData.dirtyDate
    else
      -- If no data for this map, start fresh but keep watchlist
      state.vehiclesInShop = {}
      state.sellersInfos = {}
      state.vehicleShopDirtyDate = nil
    end

    state.lastMap = currentMap
    parts.catalog.prepareVehicleCache()

    -- Repairs freight bought before pickup set a home garage; a current or last vehicle proves pickup.
    local collectedInventoryId =
      overhaul_career_garage_inventory.getCurrentVehicle() or
      overhaul_career_garage_inventory.getLastVehicle()
    parts.spawn.completeFreightPickup(collectedInventoryId)
  end
end

-- Statistics --------------------------------------------------------------------------------------
helpers.getCacheStats = function()
  if not state.vehicleCache.cacheValid then
    return {
      valid = false,
      message = "Cache not initialized"
    }
  end

  local stats = {
    valid = true,
    cacheTime = state.vehicleCache.lastCacheTime,
    dealerships = {},
    totalVehicles = 0
  }

  for dealershipId, data in pairs(state.vehicleCache.dealershipCache) do
    local regularCount = data.regularVehicles and #data.regularVehicles or 0
    stats.dealerships[dealershipId] = {
      regularVehicles = regularCount,
      total = regularCount
    }
    stats.totalVehicles = stats.totalVehicles + regularCount
  end

  return stats
end

helpers.getMapStats = function()
  local stats = {
    currentMap = getCurrentLevelIdentifier(),
    vehiclesByMap = {},
    sellersByMap = {},
    totalVehicles = #state.vehiclesInShop,
    totalSellers = tableSize(state.sellersInfos)
  }

  for _, vehicleInfo in ipairs(state.vehiclesInShop) do
    local mapId = vehicleInfo.mapId or "unknown"
    stats.vehiclesByMap[mapId] = (stats.vehiclesByMap[mapId] or 0) + 1
  end

  for sellerId, sellerInfo in pairs(state.sellersInfos) do
    local mapId = sellerInfo.mapId or "unknown"
    stats.sellersByMap[mapId] = (stats.sellersByMap[mapId] or 0) + 1
  end

  return stats
end

helpers.clearDataFromOtherMaps = function(targetMap)
  targetMap = targetMap or getCurrentLevelIdentifier()

  local filteredVehicles = {}
  for _, vehicleInfo in ipairs(state.vehiclesInShop) do
    if vehicleInfo.mapId == targetMap then
      table.insert(filteredVehicles, vehicleInfo)
    end
  end
  local removedVehicles = #state.vehiclesInShop - #filteredVehicles
  state.vehiclesInShop = filteredVehicles

  local filteredSellers = {}
  local removedSellers = 0
  for sellerId, sellerInfo in pairs(state.sellersInfos) do
    if sellerInfo.mapId == targetMap then
      filteredSellers[sellerId] = sellerInfo
    else
      removedSellers = removedSellers + 1
    end
  end
  state.sellersInfos = filteredSellers

  return {
    vehiclesRemoved = removedVehicles,
    sellersRemoved = removedSellers
  }
end

-- Public API: catalog and stock ------------------------------------------------------------------
M.addVehicleToDealerCache = parts.catalog.addVehicleToDealerCache
M.choosePrecomputedFilter = parts.catalog.choosePrecomputedFilter
M.addModelBlacklistToLookup = parts.validation.addModelBlacklistToLookup
M.pruneBlacklistedSellerStock = parts.validation.pruneBlacklistedSellerStock
M.isRichsStreetVehicle = parts.validation.isRichsStreetVehicle
M.buildRichsTopTrimLookup = parts.validation.buildRichsTopTrimLookup
M.isRichsPrestigeVehicle = parts.validation.isRichsPrestigeVehicle
M.updateVehicleList = parts.stock.updateVehicleList
M.getVisualValueFromMileage = helpers.getVisualValueFromMileage
M.invalidateVehicleCache = parts.catalog.invalidateVehicleCache

M.getLastDelta = function()
  return state.lastDelta
end

M.getVehicleInfoByShopId = helpers.getVehicleInfoByShopId
M.getVehiclesInShop = parts.ui.getVehiclesInShop
M.cacheDealers = parts.catalog.cacheDealers
M.rebuildDealershipCache = parts.catalog.rebuildDealershipCache
M.getRandomVehicleFromCache = parts.catalog.getRandomVehicleFromCache
M.getCacheStats = helpers.getCacheStats
M.getMapStats = helpers.getMapStats
M.clearDataFromOtherMaps = helpers.clearDataFromOtherMaps
M.getEligibleVehiclesWithoutDealershipVehicles = helpers.getEligibleVehiclesWithoutDealershipVehicles
M.discoverAllDealers = helpers.discoverAllDealers

-- Public API: browsing and navigation ------------------------------------------------------------
M.moveVehicleToListingSpot = parts.spawn.moveVehicleToListingSpot
M.openShop = parts.ui.openShop
M.clearFleetContext = parts.ui.clearFleetContext
M.showVehicle = parts.ui.showVehicle
M.navigateToPos = parts.ui.navigateToPos
M.navigateToDealership = parts.ui.navigateToDealership
M.taxiToDealership = parts.ui.taxiToDealership
M.getTaxiPriceToDealership = parts.ui.getTaxiPriceToDealership
M.quickTravelToVehicle = parts.ui.quickTravelToVehicle
M.getShoppingData = parts.ui.getShoppingData
M.getListing = parts.ui.getListing
M.requestVehicleTravelQuotes = parts.ui.requestVehicleTravelQuotes
M.sendShoppingDataToUI = parts.ui.sendShoppingDataToUI
M.selectSeller = parts.ui.selectSeller
M.getSelectedSellerBreadcrumbTitle = parts.ui.getSelectedSellerBreadcrumbTitle
M.getCurrentSellerId = helpers.getCurrentSellerId
M.getSellerAccessInfo = helpers.getSellerAccessInfo
M.isOnlineSellerId = helpers.isOnlineSellerId
M.ensureNegotiationPersonality = helpers.ensureNegotiationPersonality
M.setShoppingUiOpen = helpers.setShoppingUiOpen
M.endShopping = parts.ui.endShopping
M.cancelShopping = parts.ui.cancelShopping
M.requestExit = parts.ui.requestExit
M.requestVehicleListExit = parts.ui.requestVehicleListExit

M.checkSpawnedVehicleStatus = function()
  local spawnedVehicleInfo = overhaul_career_market_inspectVehicle.getSpawnedVehicleInfo()
  if spawnedVehicleInfo and state.inspectingVehicleShopId and spawnedVehicleInfo.shopId == state.inspectingVehicleShopId then
    return true
  elseif state.inspectingVehicleShopId then
    log("D", "Career", "Clearing inspection state for vehicle: " .. tostring(state.inspectingVehicleShopId))
    state.inspectingVehicleShopId = nil
    return false
  end
  return false
end

-- Public API: purchases and trade-ins ------------------------------------------------------------
M.computePurchaseTaxAndFinalPrice = parts.purchase.computePurchaseTaxAndFinalPrice
M.tradeInFreesInventorySlot = parts.purchase.tradeInFreesInventorySlot
M.hasInventorySlotForPurchase = parts.purchase.hasInventorySlotForPurchase
M.applyDeliveryCharge = parts.purchase.applyDeliveryCharge
M.canCompletePersonalVehiclePurchase = parts.purchase.canCompletePersonalVehiclePurchase
M.completeFreightPickup = parts.spawn.completeFreightPickup
M.buySpawnedVehicle = parts.purchase.buySpawnedVehicle
M.sendPurchaseDataToUi = parts.ui.sendPurchaseDataToUi
M.getDeliveryQuote = parts.purchase.getDeliveryQuote
M.openPurchaseMenu = parts.purchase.openPurchaseMenu
M.updateInsuranceSelection = parts.ui.updateInsuranceSelection
M.buyFromPurchaseMenu = parts.purchase.buyFromPurchaseMenu
M.openInventoryMenuForTradeIn = parts.purchase.openInventoryMenuForTradeIn
M.removeTradeInVehicle = parts.purchase.removeTradeInVehicle
M.cancelPurchase = parts.purchase.cancelPurchase
M.requestPurchaseExit = parts.purchase.requestPurchaseExit

M.isSettlementPending = function() return state.personalPurchaseAttempt ~= nil end
M.getPendingInventorySlotCount = parts.spawn.getPendingInventorySlotCount

-- Public API: fleet, rewards and car meets -------------------------------------------------------
M.registerCarMeetVehicle = helpers.registerCarMeetVehicle
M.removeCarMeetVehicles = helpers.removeCarMeetVehicles
M.canPurchaseCarMeetVehicle = parts.purchase.canPurchaseCarMeetVehicle
M.getCarMeetPurchaseBlockReason = parts.purchase.getCarMeetPurchaseBlockReason
M.buyCarMeetVehicleNow = parts.purchase.buyCarMeetVehicleNow
M.grantRewardVehicle = parts.spawn.grantRewardVehicle
M.getPendingRacingTeamFleetPurchases = parts.fleet.getPendingRacingTeamFleetPurchases
M.clearPendingRacingTeamFleetPurchases = parts.fleet.clearPendingRacingTeamFleetPurchases

local function openFleetShopping()
  state.currentSeller, state.originComputerId, state.selectedSellerId = nil, nil, nil
  state.shoppingScreenTag, state.buyingAvailable, state.marketplaceAvailable = "buying", true, false
  parts.ui.sendShoppingDataToUI()
end

function M.setRtBiz(id)
  if id == nil or id == "" then
    state.rtBizId = nil
    return true
  end
  state.rtBizId = tonumber(id) or id
  state.fleetBusinessType = "racingTeam"
  -- Drop the last visited dealer scope so the racing team shop is not silently filtered to it.
  openFleetShopping()
  return true
end

function M.setFleetBiz(businessType, id)
  if id == nil or id == "" then
    state.rtBizId = nil
    state.fleetBusinessType = "racingTeam"
    return true
  end
  state.fleetBusinessType = tostring(businessType or "racingTeam")
  state.rtBizId = tonumber(id) or id
  openFleetShopping()
  return true
end

-- Inventory shopping contract ---------------------------------------------------------------------

function M.onFirstVehicleAdded()
  M.updateVehicleList(true)
end

function M.getVehicleShoppingService()
  return {
    registerListing = M.registerCarMeetVehicle,
    removeListings = M.removeCarMeetVehicles,
    canPurchase = M.canPurchaseCarMeetVehicle,
    getPurchaseBlockReason = M.getCarMeetPurchaseBlockReason,
  }
end

-- Game hooks -------------------------------------------------------------------------------------
M.onRouteEnter = parts.ui.onRouteEnter
M.onRouteMount = parts.ui.onRouteMount
M.onWorldReadyState = helpers.onWorldReadyState
M.onOverhaulModulesActivated = parts.catalog.prepareVehicleCache
M.onModActivated = helpers.onModActivated
M.onModDeactivated = helpers.onModActivated
M.onModManagerReady = helpers.onModActivated
M.onClientStartMission = parts.ui.onClientStartMission
M.onVehicleSpawnFinished = parts.spawn.onVehicleSpawnFinished
M.onRewardVehicleSpawnFinished = parts.spawn.onRewardVehicleSpawnFinished
M.onRacingTeamFleetVehicleSpawnFinished = parts.spawn.onRacingTeamFleetVehicleSpawnFinished
M.onOverhaulAddedVehiclePartsToInventory = parts.ui.onOverhaulAddedVehiclePartsToInventory
M.onOverhaulEnterVehicleFinished = parts.ui.onOverhaulEnterVehicleFinished
M.onExtensionLoaded = helpers.onExtensionLoaded
M.onOverhaulSaveCurrentProfile = helpers.onOverhaulSaveCurrentProfile
M.onShoppingMenuClosed = parts.ui.onShoppingMenuClosed
M.onOverhaulComputerAddFunctions = helpers.onOverhaulComputerAddFunctions
M.onUpdate = helpers.onUpdate

M.onOverhaulBeforeSetProfile = function()
  parts.spawn.cancelPersonalPurchase(true)
  require("overhaul/lib/save/store").releaseHolds(M)
end

M.onExtensionUnloaded = M.onOverhaulBeforeSetProfile
M.onUiChangedState = helpers.onUiChangedState

M.onVehicleInspectionFinished = function(shopId)
  if state.inspectingVehicleShopId == shopId then
    state.inspectingVehicleShopId = nil
    log("D", "Career", "Inspection finished for vehicle: " .. tostring(shopId))
  end
end

return M
