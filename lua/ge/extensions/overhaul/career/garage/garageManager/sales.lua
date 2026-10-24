-- Garage sales, grants and listings; state comes from garageManager; siblings use the instance parts table.
-- Read sell eligibility and settlement, moving/reclaiming grants, listing actions, then exports.
local recordSale = require("overhaul/lib/progression/logbookFeed").register("overhaul.propertySold", {
  title = "Property sold", label = "Property", icon = "garage01"
}, "career/garage/garageManager/sales.lua")

local sales = {}

function sales.new(inputs)

  local function toastError(title, message)
    guihooks.trigger('toastrMsg', {type = "error", title = title, msg = message})
  end

  local function canSellGarageByGarageId(garageId)
    if inputs.bundles.forGarage(garageId) then return {false, 0} end
    if not garageId then return false end
    local garage = overhaul_world_facilities.getFacility("garage", garageId)
    if not garage then return false end
    -- Granted / unpaid ownership cannot be sold for money.
    if inputs.parts.ownership.isGrantedGarageOwnership(garageId) then return {false, 0} end
    local space = inputs.parts.capacity.isGarageSpace(garageId)
    local capacity = math.ceil(garage.capacity / (inputs.parts.ownership.isHardcoreMode() and 2 or 1))
    local vehicleCount = inputs.parts.capacity.getGarageOccupancy(garageId)
    return {space and space[2] == capacity and vehicleCount == 0, vehicleCount}
  end

  local function canSellGarage(computerId)
    local garageId = inputs.parts.capacity.computerIdToGarageId(computerId)
    if not garageId then return false end
    return canSellGarageByGarageId(garageId)
  end

  local function canMoveOutOfGarage(garageId)
    if inputs.bundles.forGarage(garageId) then return {false, 0, "businessBundle"} end
    if not garageId then return {false, 0, "invalid"} end
    if not inputs.state.purchasedGarages[garageId] then return {false, 0, "notOwned"} end
    if not inputs.parts.ownership.isGrantedGarageOwnership(garageId) then return {false, 0, "purchased"} end
    if overhaul_career_garage_property_propertyRentals.isRentedGarage(garageId) then return {false, 0, "rented"} end
    if inputs.parts.ownership.isGarageForSale(garageId) then return {false, 0, "listed"} end
    local garage = overhaul_world_facilities.getFacility("garage", garageId)
    if not garage then return {false, 0, "missing"} end

    local space = inputs.parts.capacity.isGarageSpace(garageId)
    local capacity = math.ceil((garage.capacity or 0) / (inputs.parts.ownership.isHardcoreMode() and 2 or 1))
    local vehicleCount = inputs.parts.capacity.getGarageOccupancy(garageId)
    if not space or space[2] ~= capacity or vehicleCount > 0 then return {false, vehicleCount, "vehicles"} end
    return {true, 0, nil}
  end

  local function canMoveOutOfGarageByComputerId(computerId)
    return canMoveOutOfGarage(inputs.parts.capacity.computerIdToGarageId(computerId))
  end

  local function canReclaimGrantedGarage(garageId)
    if inputs.bundles.forGarage(garageId) then return false end
    if not garageId or not overhaul_career_career.isActive() then return false end
    if inputs.state.purchasedGarages[garageId] then return false end
    if not inputs.parts.ownership.isRelinquishedGrant(garageId) then return false end
    if inputs.parts.ownership.isNotPurchasableGarage(garageId) then return false end
    local garage = overhaul_world_facilities.getFacility("garage", garageId)
    if not garage then return false end
    if overhaul_career_garage_property_propertyRentals.isRentedGarage(garageId) then return false end
    return true
  end

  local function moveOutOfGarage(garageId)
    if not overhaul_career_career.isActive() then return false end
    local canMove = canMoveOutOfGarage(garageId)
    if not canMove or not canMove[1] then
      if canMove and canMove[3] == "vehicles" then
        toastError("Cannot Move Out", "Remove all vehicles from this garage first.")
      end
      return false
    end

    local garage = overhaul_world_facilities.getFacility("garage", garageId)
    local wasGrant = inputs.parts.ownership.isGrantedGarageOwnership(garageId)
    inputs.state.purchasedGarages[garageId] = nil
    inputs.parts.ownership.clearGarageAcquisition(garageId)
    -- Keep discovered so the property can be reclaimed/bought later.
    inputs.state.discoveredGarages[garageId] = true
    if wasGrant then inputs.parts.ownership.markRelinquishedGrant(garageId) end
    inputs.parts.ownership.reloadRecoveryPrompt()
    inputs.parts.ownership.buildGarageSizes()
    overhaul_career_saveSystem.saveCurrent()
    guihooks.trigger('garageListingsUpdated')

    local message = "You no longer have access to " .. ((garage and garage.name) or tostring(garageId)) .. "."
    if wasGrant then message = message .. " You can reclaim it for free from Real Estate." end
    guihooks.trigger('toastrMsg', {type = "success", title = "Moved Out", msg = message})
    return true
  end

  local function moveOutOfGarageByComputerId(computerId)
    return moveOutOfGarage(inputs.parts.capacity.computerIdToGarageId(computerId))
  end

  local function reclaimGrantedGarage(garageId)
    if not canReclaimGrantedGarage(garageId) then return false end
    local garage = overhaul_world_facilities.getFacility("garage", garageId)
    inputs.parts.ownership.addPurchasedGarage(garageId, { type = "grant", amountPaid = 0 })
    overhaul_career_saveSystem.saveCurrent()
    guihooks.trigger('garageListingsUpdated')
    guihooks.trigger('toastrMsg', {
      type = "success",
      title = "Reclaimed",
      msg = "You reclaimed access to " .. ((garage and garage.name) or tostring(garageId)) .. ".",
    })
    return true
  end

  -- A mortgaged property can only be listed above what is still owed.
  local function listAtAskingPrice(garageId, askingPrice)
    local marketPrice = inputs.parts.capacity.getGaragePurchasePrice(garageId) or 0
    local desiredPrice = tonumber(askingPrice) or marketPrice
    if desiredPrice <= 0 then return false end

    if overhaul_career_garage_property_propertyMortgage.hasMortgage(garageId) then
      if not overhaul_career_garage_property_propertyMortgage.canSellMortgagedProperty(garageId, desiredPrice) then
        toastError("Sale Blocked", "Asking price must exceed remaining mortgage balance.")
        return false
      end
    end
    return overhaul_career_garage_property_realEstateNegotiation.listPropertyForSale(garageId, desiredPrice)
  end

  local function listGarageForSale(computerId, askingPrice)
    if not overhaul_career_career.isActive() then return false end
    local garageId = inputs.parts.capacity.computerIdToGarageId(computerId)
    if not garageId then return false end
    local canSellInfo = canSellGarage(computerId)
    if not canSellInfo or not canSellInfo[1] then return false end
    return listAtAskingPrice(garageId, askingPrice)
  end

  local function listGarageForSaleByGarageId(garageId, askingPrice)
    if inputs.bundles.forGarage(garageId) then return false end
    if not overhaul_career_career.isActive() then return false end
    if not garageId then return false end
    local canSellInfo = canSellGarageByGarageId(garageId)
    if not canSellInfo or not canSellInfo[1] then return false end
    return listAtAskingPrice(garageId, askingPrice)
  end

  -- Older callers still sell by computer id; it now goes through the listing flow.
  local function sellGarage(computerId, sellPrice)
    return listGarageForSale(computerId, sellPrice)
  end

  -- Pays off any mortgage from the sale price and returns false when it cannot be settled.
  local function settleMortgageForSale(garageId, finalPrice)
    local mortgage = overhaul_career_garage_property_propertyMortgage
    if not mortgage.hasMortgage(garageId) then return finalPrice end
    if not mortgage.canSellMortgagedProperty(garageId, finalPrice) then
      toastError("Sale Blocked", "Sale price does not cover remaining mortgage balance.")
      return false
    end
    local processed, netProceeds = mortgage.processMortgageSale(garageId, finalPrice)
    if not processed then return false end
    return netProceeds or 0
  end

  local function completePropertySaleFromListing(garageId, finalPrice, buyerPersonality)
    if inputs.bundles.forGarage(garageId) then return false end
    if not overhaul_career_career.isActive() then return false end
    if not garageId or not finalPrice then return false end
    local garage = overhaul_world_facilities.getFacility("garage", garageId)
    if not garage then return false end
    if not inputs.state.purchasedGarages[garageId] then return false end

    local payoutAmount = settleMortgageForSale(garageId, finalPrice)
    if payoutAmount == false then return false end

    inputs.state.purchasedGarages[garageId] = nil
    inputs.state.discoveredGarages[garageId] = nil
    inputs.parts.ownership.clearGarageAcquisition(garageId)
    inputs.parts.ownership.reloadRecoveryPrompt()
    inputs.parts.ownership.buildGarageSizes()

    local soldMessage = "Sold " .. (garage.name or tostring(garageId))
    overhaul_career_economy_payment.reward({ money = { amount = payoutAmount } }, require("overhaul/lib/finance/metadata").tag({ label = soldMessage }, "sale", {locationId = garage.id, locationName = garage.name, vehicleRelated = false}), true)
    recordSale({name = garage.name or tostring(garageId), money = payoutAmount,
      detail = (garage.name or tostring(garageId)) .. " / Net proceeds after mortgage"})
    overhaul_career_garage_property_propertyOwners.registerOwnerFromSale(garageId, finalPrice, buyerPersonality)
    overhaul_career_garage_property_realEstateNegotiation.removePropertyListing(garageId)
    overhaul_career_saveSystem.saveCurrent()
    guihooks.trigger('garageListingsUpdated')
    return true
  end

  local function getGarageListingPriceGuidance(computerId, askingPrice)
    local garageId = inputs.parts.capacity.computerIdToGarageId(computerId)
    if not garageId then return nil end
    return overhaul_career_garage_property_realEstateNegotiation.getPriceGuidanceForListing(garageId, askingPrice)
  end

  local function getGarageListingPriceGuidanceByGarageId(garageId, askingPrice)
    if not garageId then return nil end
    return overhaul_career_garage_property_realEstateNegotiation.getPriceGuidanceForListing(garageId, askingPrice)
  end

  local function getGarageActiveListing(computerId)
    local garageId = inputs.parts.capacity.computerIdToGarageId(computerId)
    if not garageId then return nil end
    return overhaul_career_garage_property_realEstateNegotiation.getPropertyListing(garageId)
  end

  local function removeGarageListing(computerId)
    local garageId = inputs.parts.capacity.computerIdToGarageId(computerId)
    if not garageId then return false end
    return overhaul_career_garage_property_realEstateNegotiation.removePropertyListing(garageId)
  end

  local function startGarageSellingNegotiation(computerId, offerIndex)
    local garageId = inputs.parts.capacity.computerIdToGarageId(computerId)
    if not garageId then return false end
    return overhaul_career_garage_property_realEstateNegotiation.startNegotiateSelling(garageId, offerIndex)
  end

  local function getNextAvailableSpace(inventoryId)
    local getFacilityIfExists = overhaul_world_facilities.getFacilityIfExists
    for garage, owned in pairs(inputs.state.purchasedGarages) do
      if owned and getFacilityIfExists("garage", garage) and not inputs.parts.ownership.isGarageForSale(garage)
          and inputs.parts.capacity.isGarageSpace(garage, inventoryId)[1] then
        return garage
      end
    end
    for garageId in pairs(overhaul_career_garage_property_propertyRentals.getActiveRentals()) do
      if not inputs.state.purchasedGarages[garageId]
        and getFacilityIfExists("garage", garageId)
        and inputs.parts.capacity.isGarageSpace(garageId, inventoryId)[1] then
        return garageId
      end
    end
    return nil
  end

  return {
    canMoveOutOfGarage = canMoveOutOfGarage,
    canMoveOutOfGarageByComputerId = canMoveOutOfGarageByComputerId,
    canReclaimGrantedGarage = canReclaimGrantedGarage,
    canSellGarage = canSellGarage,
    canSellGarageByGarageId = canSellGarageByGarageId,
    completePropertySaleFromListing = completePropertySaleFromListing,
    getGarageActiveListing = getGarageActiveListing,
    getGarageListingPriceGuidance = getGarageListingPriceGuidance,
    getGarageListingPriceGuidanceByGarageId = getGarageListingPriceGuidanceByGarageId,
    getNextAvailableSpace = getNextAvailableSpace,
    listGarageForSale = listGarageForSale,
    listGarageForSaleByGarageId = listGarageForSaleByGarageId,
    moveOutOfGarage = moveOutOfGarage,
    moveOutOfGarageByComputerId = moveOutOfGarageByComputerId,
    reclaimGrantedGarage = reclaimGrantedGarage,
    removeGarageListing = removeGarageListing,
    sellGarage = sellGarage,
    startGarageSellingNegotiation = startGarageSellingNegotiation,
  }
end

return sales
