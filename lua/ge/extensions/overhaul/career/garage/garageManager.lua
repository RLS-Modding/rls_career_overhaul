-- Garage ownership and transactions; garageManager/ holds the named parts.
-- Read config/state, capacity helpers, shared parts construction, then the public API and hooks.
local M = {}
M.dependencies = {"overhaul_career_career"}

local vehicleMap = require('overhaul/career/garage/inventory/vehicleMap')

local bundles = require("overhaul/lib/business/bundles")

local saveFile = "purchasedGarages.json"
local CLOSING_FEE_RATE = 0.03
local PROPERTY_TAX_RATE = 0.012
local NEGOTIATION_COOLDOWN_SECONDS = 30 * 60

local garageState = {
  purchasedGarages = {},
  discoveredGarages = {},
  garageAcquisitions = {},
  -- Relinquished grants stay relinquished until the player reclaims or buys them.
  relinquishedGrants = {},
  garageSize = {},
  negotiationCooldowns = {},
  frozenPrices = {},
}
local pendingNegotiatedPrices = {}

local parts = {}

function M.getStoredLocations()
  local storedLocation = {}
  for id, vehicle in pairs(overhaul_career_garage_inventory.getVehicles()) do
    if vehicle.location then
      if not storedLocation[vehicle.location] then storedLocation[vehicle.location] = {} end
      table.insert(storedLocation[vehicle.location], id)
    end
  end
  return storedLocation
end

function M.getVehiclesInGarage(garageId)
  if not garageId then return {} end
  return M.getStoredLocations()[garageId] or {}
end

local function vehicleUsesGarageCapacity(vehicle, garageId)
  if not vehicle or vehicle.takesNoInventorySpace then return false end
  local homeGarage = vehicleMap.homeGarage(vehicle)
  local level, reason = vehicleMap.resolve(vehicle)
  if reason == 'ambiguous' or (level and level ~= getCurrentLevelIdentifier()) then return false end
  if garageId then return tostring(homeGarage) == tostring(garageId) end
  return true
end

function M.vehicleUsesGarageCapacity(vehicle, garageId)
  parts.ownership.buildGarageSizes()
  return vehicleUsesGarageCapacity(vehicle, garageId)
end

-- Every capacity reader takes a fresh view of the same inventory and pending reservations.
-- Unassigned local vehicles consume the map total even when no garage can claim them.
local function readCapacity(inventoryId, excludedPurchaseToken, forDisposal)
  parts.ownership.buildGarageSizes()
  local data, totalCapacity, used = {}, 0, 0
  local function addGarage(garageId)
    garageId = tostring(garageId)
    if data[garageId] or parts.ownership.isGarageForSale(garageId) then return end
    local capacity = garageState.garageSize[garageId]
    if not capacity then return end
    local garage = overhaul_world_facilities.getFacility('garage', garageId)
    data[garageId] = {id = garageId, name = garage and garage.name or garageId, capacity = capacity, count = 0}
    totalCapacity = totalCapacity + capacity
  end
  for garageId, owned in pairs(garageState.purchasedGarages) do
    if owned then addGarage(garageId) end
  end
  for garageId in pairs(overhaul_career_garage_property_propertyRentals.getActiveRentals()) do addGarage(garageId) end
  local occupancy = {}
  for id, vehicle in pairs(overhaul_career_garage_inventory.getVehicles() or {}) do
    if id ~= inventoryId then
      local home = vehicleMap.homeGarage(vehicle)
      local level, reason = vehicleMap.resolve(vehicle)
      -- Disposal must protect every possible home of an unresolved assignment.
      -- Purchase capacity still excludes ambiguous records through its normal filter.
      local onMap = (forDisposal or reason ~= 'ambiguous') and (not level or level == getCurrentLevelIdentifier())
      if home and onMap and (forDisposal or vehicleUsesGarageCapacity(vehicle, home)) then
        home = tostring(home)
        occupancy[home] = (occupancy[home] or 0) + 1
      end
      if vehicleUsesGarageCapacity(vehicle) then used = used + 1 end
    end
  end
  local shopping = overhaul_career_market_vehicleShopping
  local function pending(garageId)
    return shopping and shopping.getPendingInventorySlotCount
      and (tonumber(shopping.getPendingInventorySlotCount(excludedPurchaseToken, garageId, forDisposal)) or 0) or 0
  end
  for garageId, info in pairs(data) do
    info.count = (occupancy[garageId] or 0) + pending(garageId)
    info.freeSlots = math.max(0, info.capacity - info.count)
  end
  return data, math.max(0, totalCapacity - used - pending()), occupancy, pending
end

function M.getGarageOccupancy(garageId)
  local _, _, occupancy, pending = readCapacity(nil, nil, true)
  return (occupancy[tostring(garageId)] or 0) + pending(garageId)
end

function M.isGarageSpace(garage, inventoryId)
  local data = readCapacity(inventoryId)
  local info = data[tostring(garage)]
  if not info then return {false, 0} end
  local incoming = inventoryId and overhaul_career_garage_inventory.getVehicles()[inventoryId]
  -- Returning to a confirmed reservation adds no occupancy, even in older
  -- saves already over capacity. A matching garage id alone is not proof.
  local retainsReservation = incoming and vehicleMap.resolve(incoming) == getCurrentLevelIdentifier()
    and vehicleUsesGarageCapacity(incoming, garage)
  return {(incoming and incoming.takesNoInventorySpace) or retainsReservation or info.freeSlots > 0, info.freeSlots}
end

function M.getGarageCapacityData()
  local data = readCapacity()
  -- Delivery offers owned garages; rentals still participate in storage and the map total.
  for garageId in pairs(data) do
    if not garageState.purchasedGarages[garageId] then data[garageId] = nil end
  end
  return data
end

function M.getFreeSlots(excludedPurchaseToken)
  local _, free = readCapacity(nil, excludedPurchaseToken)
  return free
end

function M.getGarageAvailabilityReason()
  if M.getFreeSlots() > 0 then return "ok" end
  for garageId, owned in pairs(garageState.purchasedGarages) do
    if owned and not parts.ownership.isGarageForSale(garageId) then return "full" end
  end
  for garageId in pairs(overhaul_career_garage_property_propertyRentals.getActiveRentals()) do
    if not parts.ownership.isGarageForSale(garageId) then return "full" end
  end
  return "none"
end

function M.removePurchasedGarage(garageId)
  if bundles.forGarage(garageId) then return false end
  if not garageId then return false end
  if not garageState.purchasedGarages[garageId] then return false end
  garageState.purchasedGarages[garageId] = nil
  garageState.discoveredGarages[garageId] = nil
  parts.ownership.clearGarageAcquisition(garageId)
  parts.ownership.reloadRecoveryPrompt()
  parts.ownership.buildGarageSizes()
  overhaul_career_saveSystem.saveCurrent()
  return true
end

function M.getPurchasedGarages()
  parts.ownership.syncBusinessGarages()
  local result = {}
  for garageId in pairs(garageState.purchasedGarages) do table.insert(result, garageId) end
  return result
end

function M.garageIdToName(garageId)
  local garage = overhaul_world_facilities.getFacilityIfExists("garage", garageId)
  if garage then return garage.name end
  return garageId and tostring(garageId) or nil
end

function M.computerIdToGarageId(computerId)
  local computer = overhaul_world_facilities.getFacility("computer", computerId)
  if computer then return computer.garageId end
  return nil
end

function M.getGaragePurchasePrice(garageId)
  return parts.purchase.calculateGaragePurchasePrice(garageId)
end

parts.ownership = require('overhaul/career/garage/garageManager/ownership').new({
  state = garageState,
  parts = parts,
  NEGOTIATION_COOLDOWN_SECONDS = NEGOTIATION_COOLDOWN_SECONDS,
  bundles = bundles,
  pendingNegotiatedPrices = pendingNegotiatedPrices,
  saveFile = saveFile,
})
parts.purchase = require('overhaul/career/garage/garageManager/purchase').new({
  state = garageState,
  parts = parts,
  CLOSING_FEE_RATE = CLOSING_FEE_RATE,
  PROPERTY_TAX_RATE = PROPERTY_TAX_RATE,
  bundles = bundles,
})
parts.capacity = M
parts.sales = require('overhaul/career/garage/garageManager/sales').new({state = garageState, bundles = bundles, parts = parts})
parts.ui = require('overhaul/career/garage/garageManager/ui').new({state = garageState, parts = parts})

M.purchaseDefaultGarage = parts.ownership.purchaseDefaultGarage

M.showPurchaseGaragePrompt = parts.purchase.showPurchaseGaragePrompt
M.requestGarageData = parts.purchase.requestGarageData
M.canPay = parts.purchase.canPay
M.buyGarage = parts.purchase.buyGarage
M.cancelGaragePurchase = parts.purchase.cancelGaragePurchase
M.getGaragePrice = parts.purchase.getGaragePrice

M.completePurchaseWithNegotiatedPrice = parts.purchase.completePurchaseWithNegotiatedPrice
M.purchaseGarageAtNegotiatedPrice = parts.purchase.purchaseGarageAtNegotiatedPrice

-- The UI price argument is ignored: the price frozen is always the pending negotiated one.
function M.freezeNegotiatedPrice(garageId, _uiPrice)
  local price = parts.ownership.getPendingNegotiatedPrice(garageId)
  if price then parts.ownership.freezeNegotiatedPrice(garageId, price) end
end

M.requestGarageListing = parts.purchase.requestGarageListing
M.getPendingGarageListing = parts.purchase.getPendingGarageListing
M.startGarageNegotiation = parts.purchase.startGarageNegotiation
M.purchaseGarageAtListedPrice = parts.purchase.purchaseGarageAtListedPrice
M.canNegotiateGarage = parts.ownership.canNegotiateGarage
M.setNegotiationCooldown = parts.ownership.setNegotiationCooldown
M.canSellGarage = parts.sales.canSellGarage
M.canMoveOutOfGarage = parts.sales.canMoveOutOfGarage
M.canMoveOutOfGarageByComputerId = parts.sales.canMoveOutOfGarageByComputerId
M.moveOutOfGarage = parts.sales.moveOutOfGarage
M.moveOutOfGarageByComputerId = parts.sales.moveOutOfGarageByComputerId
M.canReclaimGrantedGarage = parts.sales.canReclaimGrantedGarage
M.reclaimGrantedGarage = parts.sales.reclaimGrantedGarage
M.isGrantedGarageOwnership = parts.ownership.isGrantedGarageOwnership
M.wasGaragePurchasedWithMoney = parts.ownership.wasGaragePurchasedWithMoney
M.getGarageAcquisition = parts.ownership.getGarageAcquisition
M.listGarageForSale = parts.sales.listGarageForSale
M.listGarageForSaleByGarageId = parts.sales.listGarageForSaleByGarageId
M.sellGarage = parts.sales.sellGarage
M.completePropertySaleFromListing = parts.sales.completePropertySaleFromListing
M.getGarageListingPriceGuidance = parts.sales.getGarageListingPriceGuidance
M.getGarageListingPriceGuidanceByGarageId = parts.sales.getGarageListingPriceGuidanceByGarageId
M.getGarageActiveListing = parts.sales.getGarageActiveListing
M.removeGarageListing = parts.sales.removeGarageListing
M.startGarageSellingNegotiation = parts.sales.startGarageSellingNegotiation

M.getOwnedGaragesListingData = parts.ui.getOwnedGaragesListingData
M.getGarageOffersData = parts.ui.getGarageOffersData
M.acceptOffer = parts.ui.acceptOffer
M.declineOffer = parts.ui.declineOffer

M.onOverhaulModulesActivated = parts.ownership.onOverhaulModulesActivated
M.onExtensionLoaded = parts.ownership.onExtensionLoaded
M.isPurchasedGarage = parts.ownership.isPurchasedGarage
M.isAccessibleGarage = parts.ownership.isAccessibleGarage
M.isNotPurchasableGarage = parts.ownership.isNotPurchasableGarage
M.addPurchasedGarage = parts.ownership.addPurchasedGarage
M.addDiscoveredGarage = parts.ownership.addDiscoveredGarage
M.isDiscoveredGarage = parts.ownership.isDiscoveredGarage
M.loadPurchasedGarages = parts.ownership.loadPurchasedGarages
M.savePurchasedGarages = parts.ownership.savePurchasedGarages
M.onOverhaulSaveCurrentProfile = parts.ownership.onOverhaulSaveCurrentProfile

M.getNextAvailableSpace = parts.sales.getNextAvailableSpace
M.getEffectiveStartingGarages = parts.ownership.getEffectiveStartingGarages
M.getPrimaryStartingGarageId = parts.ownership.getPrimaryStartingGarageId
M.buildGarageSizes = parts.ownership.buildGarageSizes
M.fillGarages = parts.ownership.fillGarages
M.isGarageForSale = parts.ownership.isGarageForSale
M.isStarterGaragePurchasable = parts.ownership.isStarterGaragePurchasable

function M.syncBusinessGarages()
  parts.ownership.buildGarageSizes()
  parts.ownership.reloadRecoveryPrompt()
end

function M.onWorldReadyState(worldReadyState)
  if worldReadyState == 2 and overhaul_career_career.isActive() then
    parts.ownership.buildGarageSizes()
    parts.ownership.fillGarages()
    parts.ownership.purchaseDefaultGarage()
  end
end

M.onExtensionUnloaded = parts.ownership.disposeSaveFeature

return M
