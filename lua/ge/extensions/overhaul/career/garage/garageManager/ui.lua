-- Garage listing and offer projections; state comes from garageManager.
-- Read owned listing projection, offers and responses, then exports.
local levelData = require("overhaul/lib/world/levelData")

local ui = {}

function ui.new(inputs)

  local function previewFor(garage, garageId, computers)
    local preview = garage.preview or ""
    if computers then
      for _, computer in pairs(computers) do
        if computer.garageId == garageId and computer.preview then
          preview = computer.preview
          break
        end
      end
    end
    return preview
  end

  local function computerIdFor(garageId, computers)
    if not computers then return nil end
    for _, computer in pairs(computers) do
      if computer.garageId == garageId then return computer.id end
    end
    return nil
  end

  local function displayName(garage, garageId)
    local name = garage.name or tostring(garageId)
    local translated = translateLanguage(garage.name, garage.name, true)
    if translated then name = translated end
    return name
  end

  local function marketValueOf(garage)
    local marketValue = garage.defaultPrice or 0
    return math.floor(marketValue * overhaul_career_economy_globalEconomy.getHousingMarketIndex() + 0.5)
  end

  -- A garage that is rented or waiting to be reclaimed has no sale, move-out or listing state of its own.
  local function ownedGarageFlags(garageId, garage, isRented, isReclaimable)
    local flags = {}
    flags.isStarter = (not isReclaimable) and inputs.parts.ownership.isFreeStarterGarage(garageId, garage)
    flags.isGranted = (not isRented) and (not isReclaimable) and inputs.parts.ownership.isGrantedGarageOwnership(garageId)
    local canSellInfo = (not isRented) and (not isReclaimable) and inputs.parts.sales.canSellGarageByGarageId(garageId) or nil
    flags.canSell = canSellInfo and canSellInfo[1] or false
    local canMoveInfo = (not isRented) and (not isReclaimable) and inputs.parts.sales.canMoveOutOfGarage(garageId) or nil
    flags.canMoveOut = canMoveInfo and canMoveInfo[1] or false
    flags.moveOutBlockedReason = canMoveInfo and canMoveInfo[3] or nil
    return flags
  end

  local function buildGarageListingEntry(garageId, garage, options, storedLocation)
    local isRented = options and options.isRented == true
    local capacity = math.ceil((garage.capacity or 0) / (inputs.parts.ownership.isHardcoreMode() and 2 or 1))
    local vehiclesInGarage = storedLocation[garageId]
    local vehicleCount = vehiclesInGarage and #vehiclesInGarage or 0

    local computers = overhaul_world_facilities.getFacilitiesByType("computer")
    local preview = previewFor(garage, garageId, computers)
    local name = displayName(garage, garageId)
    local marketValue = marketValueOf(garage)
    local isReclaimable = options and options.canReclaim == true
    local flags = ownedGarageFlags(garageId, garage, isRented, isReclaimable)

    local listing, offerCount, askingPrice = nil, 0, nil
    if not isRented and not isReclaimable then
      listing = overhaul_career_garage_property_realEstateNegotiation.getPropertyListing(garageId)
      if listing then
        askingPrice = listing.askingPrice
        offerCount = listing.offers and #listing.offers or 0
      end
    end

    local computerId = computerIdFor(garageId, computers)
    local rentalInfo = nil
    if isRented then rentalInfo = overhaul_career_garage_property_propertyRentals.getRentalInfo(garageId) end
    local acquisition = (not isReclaimable) and inputs.parts.ownership.getGarageAcquisition(garageId) or nil

    return {
      garageId = garageId,
      computerId = computerId,
      name = name,
      preview = preview,
      capacity = capacity,
      vehicleCount = isReclaimable and 0 or vehicleCount,
      marketValue = marketValue,
      isStarter = flags.isStarter,
      isGranted = flags.isGranted,
      canSell = flags.canSell,
      canMoveOut = flags.canMoveOut,
      moveOutBlockedReason = flags.moveOutBlockedReason,
      canReclaim = isReclaimable,
      amountPaid = acquisition and acquisition.amountPaid or 0,
      acquisitionType = acquisition and acquisition.type or nil,
      isListed = listing ~= nil,
      askingPrice = askingPrice,
      offerCount = offerCount,
      neighborhood = garage.neighborhood or (levelData.getMap() or {}).label or "",
      isRented = isRented,
      rentalType = rentalInfo and rentalInfo.type or nil,
      paymentsRemaining = rentalInfo and rentalInfo.paymentsRemaining or nil,
    }
  end

  local function getOwnedGaragesListingData()
    local result = {}
    local storedLocation = inputs.parts.capacity.getStoredLocations()
    local included = {}

    local function addGarageListingEntry(garageId, options)
      if included[garageId] then return end
      local garage = overhaul_world_facilities.getFacility("garage", garageId)
      if not garage or garage.notPurchasable then return end
      local entry = buildGarageListingEntry(garageId, garage, options, storedLocation)
      included[garageId] = true
      table.insert(result, entry)
    end

    for garageId, owned in pairs(inputs.state.purchasedGarages) do
      if owned then addGarageListingEntry(garageId, { isRented = false }) end
    end
    for garageId in pairs(overhaul_career_garage_property_propertyRentals.getActiveRentals()) do
      if not inputs.state.purchasedGarages[garageId] then addGarageListingEntry(garageId, { isRented = true }) end
    end
    for garageId, flagged in pairs(inputs.state.relinquishedGrants) do
      if flagged and inputs.parts.sales.canReclaimGrantedGarage(garageId) then addGarageListingEntry(garageId, { canReclaim = true }) end
    end
    return result
  end

  local function getGarageOffersData(garageId)
    if not garageId then return nil end
    local listing = overhaul_career_garage_property_realEstateNegotiation.getPropertyListing(garageId)
    if not listing then return nil end
    local garage = overhaul_world_facilities.getFacility("garage", garageId)
    if not garage then return nil end

    local preview = previewFor(garage, garageId, overhaul_world_facilities.getFacilitiesByType("computer"))
    local name = displayName(garage, garageId)
    local marketValue = marketValueOf(garage)

    local offers = {}
    if listing.offers then
      for index, offer in ipairs(listing.offers) do
        table.insert(offers, {
          index = index,
          value = offer.value,
          negotiatedPrice = offer.negotiatedPrice,
          buyerName = offer.buyerPersonality and offer.buyerPersonality.name or "Buyer",
          timestamp = offer.timestamp,
          negotiationPossible = offer.negotiationPossible ~= false,
        })
      end
    end
    return {
      garageId = garageId,
      name = name,
      preview = preview,
      askingPrice = listing.askingPrice,
      marketValue = marketValue,
      offers = offers,
    }
  end

  -- Returns the listing and the validated offer index, or nil when the response cannot apply.
  local function findListedOffer(garageId, offerIndex)
    if not garageId or not offerIndex then return nil end
    local listing = overhaul_career_garage_property_realEstateNegotiation.getPropertyListing(garageId)
    if not listing or not listing.offers then return nil end
    local index = tonumber(offerIndex)
    if not index or index < 1 or index > #listing.offers then return nil end
    return listing, index
  end

  local function acceptOffer(garageId, offerIndex)
    local listing, index = findListedOffer(garageId, offerIndex)
    if not listing then return false end
    local offer = listing.offers[index]
    if not offer then return false end
    local salePrice = offer.negotiatedPrice or offer.value
    return inputs.parts.sales.completePropertySaleFromListing(garageId, salePrice, offer.buyerPersonality)
  end

  local function declineOffer(garageId, offerIndex)
    local listing, index = findListedOffer(garageId, offerIndex)
    if not listing then return false end
    table.remove(listing.offers, index)
    return true
  end

  return {
    acceptOffer = acceptOffer,
    declineOffer = declineOffer,
    getGarageOffersData = getGarageOffersData,
    getOwnedGaragesListingData = getOwnedGaragesListingData,
  }
end

return ui
