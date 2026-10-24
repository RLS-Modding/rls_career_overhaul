-- Garage prices and purchases; state comes from garageManager; siblings use the instance parts table.
-- Read pricing and financing, listing projection, purchase operations, prompt actions, then exports.
local levelData = require("overhaul/lib/world/levelData")

local purchase = {}

function purchase.new(inputs)

  -- Pricing ---------------------------------------------------------------------------------------

  local function calculateGaragePurchasePrice(garageId)
    if not garageId then return nil end
    local garage = overhaul_world_facilities.getFacility("garage", garageId)
    if not garage then return nil end
    if not inputs.parts.ownership.isHardcoreMode() and garage.starterGarage then
      if not inputs.parts.ownership.isStarterGaragePurchasable(garageId) then return 0 end
    end
    local price = garage.defaultPrice
    return math.floor(price * overhaul_career_economy_globalEconomy.getHousingMarketIndex() + 0.5)
  end

  local function calculateClosingFee(price)
    if not price or price <= 0 then return 0 end
    return math.floor((price * inputs.CLOSING_FEE_RATE) + 0.5)
  end

  local function calculateAnnualPropertyTax(price)
    if not price or price <= 0 then return 0 end
    return math.floor((price * inputs.PROPERTY_TAX_RATE) + 0.5)
  end

  local function getGaragePrice(garage, computerId)
    local garageId
    if garage then
      garageId = type(garage) == "table" and garage.id or garage
    elseif computerId then
      local computer = overhaul_world_facilities.getFacility("computer", computerId)
      if computer then garageId = computer.garageId end
    end
    return calculateGaragePurchasePrice(garageId)
  end

  -- The previous owner's asking price replaces the market price when the garage has one.
  local function applyOwnerAskingPrice(garageId, listedPrice)
    local ownerInfo = overhaul_career_garage_property_propertyOwners.getOwnerForListing(garageId, listedPrice)
    if ownerInfo and ownerInfo.currentAskingPrice then listedPrice = ownerInfo.currentAskingPrice end
    return listedPrice, ownerInfo
  end

  -- Paying ----------------------------------------------------------------------------------------

  local function purchaseGarageWithFinancing(garage, purchasePrice, selectedTerm)
    if inputs.bundles.forGarage(garage and garage.id) then return false end
    if not garage then return false end
    if not overhaul_career_garage_property_propertyMortgage.isMortgageAvailable() then return false end

    local downPayment = overhaul_career_garage_property_propertyMortgage.computeDownPayment(purchasePrice)
    if not downPayment then return false end

    local closingFee = calculateClosingFee(purchasePrice)
    local propertyTax = calculateAnnualPropertyTax(purchasePrice)
    local cashToClose = downPayment + closingFee + propertyTax

    if cashToClose > 0 then
      local paid = overhaul_career_economy_payment.pay({ money = { amount = cashToClose, canBeNegative = false } }, require("overhaul/lib/finance/metadata").tag({ label = "Closing on " .. garage.name }, "purchase", {locationId = garage.id, locationName = garage.name, vehicleRelated = false}))
      if not paid then return false end
    end

    local mortgage = overhaul_career_garage_property_propertyMortgage.createMortgage(garage.id, purchasePrice, selectedTerm, true)
    if not mortgage then
      if cashToClose > 0 then
        overhaul_career_economy_payment.reward({ money = { amount = cashToClose } }, require("overhaul/lib/finance/metadata").tag({ label = "Closing refund for " .. garage.name, tags = {"refund"} }, "refund", {locationId = garage.id, locationName = garage.name, vehicleRelated = false}), true)
      end
      return false
    end
    return true
  end

  -- Listing ---------------------------------------------------------------------------------------

  local function listingPreview(garage, garageId)
    local preview = garage.preview or ""
    local computers = overhaul_world_facilities.getFacilitiesByType("computer")
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

  local function listingName(garage)
    local name = garage.name
    local translated = translateLanguage(garage.name, garage.name, true)
    if translated then name = translated end
    return name
  end

  local function mortgageListingInfo(effectivePrice, closingFee, propertyTax)
    local available = overhaul_career_garage_property_propertyMortgage.isMortgageAvailable()
    if not available then return available, nil end
    local details = overhaul_career_garage_property_propertyMortgage.getMortgageOfferDetails()
    if not details then return available, nil end
    local downPaymentPercent = details.downPaymentPercent or 0.2
    local downPayment = math.floor(effectivePrice * downPaymentPercent)
    return available, {
      creditTier = details.tier or "",
      downPaymentPct = math.floor(downPaymentPercent * 100),
      downPayment = downPayment,
      cashToClose = downPayment + closingFee + propertyTax,
      interestRate = details.rate or 0,
      availableTerms = details.termsAvailable or {12, 24, 36, 48},
    }
  end

  local function requestGarageListing(garageId)
    if inputs.bundles.forGarage(garageId) then return false end
    if not overhaul_career_career.isActive() then return nil end
    local garage = overhaul_world_facilities.getFacility("garage", garageId)
    if not garage then return nil end

    local listedPrice = getGaragePrice(garage)
    local canNegotiate = (not garage.starterGarage or inputs.parts.ownership.isStarterGaragePurchasable(garageId)) and listedPrice > 0
    local ownerInfo
    listedPrice, ownerInfo = applyOwnerAskingPrice(garageId, listedPrice)

    local preview = listingPreview(garage, garageId)
    local name = listingName(garage)

    local negotiatedPrice = inputs.parts.ownership.getFrozenPrice(garageId)
    if not negotiatedPrice then negotiatedPrice = inputs.parts.ownership.getPendingNegotiatedPrice(garageId) end
    local effectivePrice = negotiatedPrice or listedPrice
    local closingFee = calculateClosingFee(effectivePrice)
    local propertyTax = calculateAnnualPropertyTax(effectivePrice)

    local canNegotiateNow, cooldownRemaining = inputs.parts.ownership.canNegotiateGarage(garageId)
    canNegotiate = canNegotiate and canNegotiateNow

    local mortgageAvailable, mortgageInfo = mortgageListingInfo(effectivePrice, closingFee, propertyTax)
    local creditTier = ""
    local tier = overhaul_career_economy_credit.getTier()
    if tier then creditTier = tier.label end

    local rentalBreakdown = overhaul_career_garage_property_propertyRentals.getRentalBreakdown(garageId)

    return {
      garageId = garage.id,
      name = name,
      preview = preview,
      listedPrice = listedPrice,
      negotiatedPrice = negotiatedPrice,
      closingFee = closingFee,
      propertyTax = propertyTax,
      estimatedTotal = effectivePrice + closingFee + propertyTax,
      capacity = math.ceil(garage.capacity / (inputs.parts.ownership.isHardcoreMode() and 2 or 1)),
      parkingSpots = (garage.parkingSpotNames and #garage.parkingSpotNames) or 0,
      neighborhood = garage.neighborhood or (levelData.getMap() or {}).label or "",
      canNegotiate = canNegotiate,
      cooldownRemaining = cooldownRemaining,
      isFrozen = inputs.parts.ownership.getFrozenPrice(garageId) ~= nil,
      starterGarage = (garage.starterGarage and not inputs.parts.ownership.isStarterGaragePurchasable(garageId)) or false,
      ownerInfo = ownerInfo,
      ownerName = ownerInfo and ownerInfo.name or nil,
      ownerArchetype = ownerInfo and ownerInfo.archetype or nil,
      mortgageAvailable = mortgageAvailable,
      mortgageInfo = mortgageInfo,
      creditTier = creditTier,
      rentalBreakdown = rentalBreakdown,
    }
  end

  local function getPendingGarageListing()
    local data = inputs.state.pendingGarageListingData
    inputs.state.pendingGarageListingData = nil
    return data
  end

  -- Purchase operations ---------------------------------------------------------------------------

  local function openComputerMenuForGarage(garageId, computers)
    for _, computer in pairs(computers) do
      if computer.garageId == garageId then
        overhaul_career_garage_computer.openComputerMenuById(computer.id)
        return
      end
    end
  end

  local function completePurchaseWithNegotiatedPrice(garageId, finalPrice, freezePrice, useFinancing, selectedTerm)
    if inputs.bundles.forGarage(garageId) then return false end
    if not overhaul_career_career.isActive() then
      log("E", "garageManager", "completePurchaseWithNegotiatedPrice: Career not active")
      return false
    end
    if not garageId or not finalPrice then
      log("E", "garageManager", "completePurchaseWithNegotiatedPrice: Missing garageId or finalPrice")
      return false
    end
    local garage = overhaul_world_facilities.getFacility("garage", garageId)
    if not garage then
      log("E", "garageManager", "completePurchaseWithNegotiatedPrice: Garage not found: " .. tostring(garageId))
      return false
    end

    inputs.state.garageToPurchase = garage
    inputs.parts.ownership.setNegotiationCooldown(garageId)
    inputs.parts.ownership.setPendingNegotiatedPrice(garageId, finalPrice)
    if freezePrice then inputs.parts.ownership.freezeNegotiatedPrice(garageId, finalPrice) end

    local listingData = requestGarageListing(garageId)
    -- The negotiated price shows on the listing even when it is not frozen.
    listingData.negotiatedPrice = finalPrice
    listingData.isFrozen = freezePrice == true
    local closingFee = calculateClosingFee(finalPrice)
    local propertyTax = calculateAnnualPropertyTax(finalPrice)
    listingData.closingFee = closingFee
    listingData.propertyTax = propertyTax
    listingData.estimatedTotal = finalPrice + closingFee + propertyTax
    listingData.useFinancing = useFinancing == true
    listingData.selectedTerm = selectedTerm
    inputs.state.pendingGarageListingData = listingData

    guihooks.trigger('openGarageListing', listingData)
    extensions.ui_router.navigate('garage-listing')
    return true
  end

  local function purchaseGarageAtNegotiatedPrice(garageId, useFinancing, selectedTerm)
    if inputs.bundles.forGarage(garageId) then return false end
    if not overhaul_career_career.isActive() then
      log("E", "garageManager", "purchaseGarageAtNegotiatedPrice: Career not active")
      return false
    end
    if not garageId or type(garageId) ~= "string" or garageId == "" then
      log("E", "garageManager", "purchaseGarageAtNegotiatedPrice: Invalid garageId (expected non-empty string)")
      return false
    end
    local garage = overhaul_world_facilities.getFacility("garage", garageId)
    if not garage then
      log("E", "garageManager", "purchaseGarageAtNegotiatedPrice: Garage not found: " .. tostring(garageId))
      return false
    end
    if inputs.parts.ownership.isNotPurchasableGarage(garageId, garage) then
      log("W", "garageManager", "purchaseGarageAtNegotiatedPrice: Facility is not purchasable: " .. tostring(garageId))
      return false
    end

    local negotiatedPrice = inputs.parts.ownership.getFrozenPrice(garageId)
    if not negotiatedPrice then negotiatedPrice = inputs.parts.ownership.getPendingNegotiatedPrice(garageId) end
    if not negotiatedPrice then
      log("E", "garageManager", "purchaseGarageAtNegotiatedPrice: No negotiated price found")
      return false
    end

    local success, historyAmountPaid
    if useFinancing and overhaul_career_garage_property_propertyMortgage.isMortgageAvailable() then
      success = purchaseGarageWithFinancing(garage, negotiatedPrice, selectedTerm)
    else
      local totalPrice = negotiatedPrice + calculateClosingFee(negotiatedPrice) + calculateAnnualPropertyTax(negotiatedPrice)
      historyAmountPaid = totalPrice
      local price = { money = { amount = totalPrice, canBeNegative = false } }
      success = overhaul_career_economy_payment.pay(price, require("overhaul/lib/finance/metadata").tag({ label = "Purchased " .. garage.name }, "purchase", {locationId = garage.id, locationName = garage.name, vehicleRelated = false}))
    end
    if not success then return false end

    local financed = useFinancing and overhaul_career_garage_property_propertyMortgage.hasMortgage(garage.id)
    inputs.parts.ownership.addPurchasedGarage(garage.id, {
      type = financed and "finance" or "purchase",
      amountPaid = negotiatedPrice,
      historyAmountPaid = historyAmountPaid
    })
    inputs.parts.ownership.clearFrozenPrice(garageId)
    inputs.parts.ownership.clearPendingNegotiatedPrice(garageId)
    overhaul_career_saveSystem.saveCurrent(nil, {force = true})
    guihooks.trigger('toastrMsg', {type="success", title="Property Purchased", msg="Welcome to your new garage!"})
    guihooks.trigger('ChangeState', {state = 'play'})
    return true
  end

  local function startGarageNegotiation(garageId)
    if inputs.bundles.forGarage(garageId) then return false end
    if not overhaul_career_career.isActive() then return false end
    local canNegotiateNow = inputs.parts.ownership.canNegotiateGarage(garageId)
    if not canNegotiateNow then
      log("W", "garageManager", "Negotiation on cooldown for garage: " .. tostring(garageId))
      return false
    end
    return overhaul_career_garage_property_realEstateNegotiation.startNegotiateBuying(garageId)
  end

  -- Starter garages cost nothing, so they are granted and the computer menu opens straight away.
  local function grantFreeGarage(garage, garageId)
    inputs.parts.ownership.addPurchasedGarage(garage.id, { type = "grant", amountPaid = 0 })
    overhaul_career_saveSystem.saveCurrent(nil, {force = true})
    local computers = overhaul_world_facilities.getFacilitiesByType("computer")
    if computers then openComputerMenuForGarage(garageId, computers) end
  end

  local function purchaseGarageAtListedPrice(garageId, useFinancing, selectedTerm)
    if inputs.bundles.forGarage(garageId) then return false end
    if not overhaul_career_career.isActive() then
      log("E", "garageManager", "purchaseGarageAtListedPrice: Career not active")
      return false
    end
    if not garageId or type(garageId) ~= "string" or garageId == "" then
      log("E", "garageManager", "purchaseGarageAtListedPrice: Invalid garageId (expected non-empty string)")
      return false
    end
    local garage = overhaul_world_facilities.getFacility("garage", garageId)
    if not garage then
      log("E", "garageManager", "purchaseGarageAtListedPrice: Garage not found: " .. tostring(garageId))
      return false
    end

    local listedPrice = getGaragePrice(garage)
    if not listedPrice then
      log("E", "garageManager", "purchaseGarageAtListedPrice: Could not determine price for garage: " .. tostring(garageId))
      return false
    end
    listedPrice = applyOwnerAskingPrice(garageId, listedPrice)

    if listedPrice == 0 then
      grantFreeGarage(garage, garageId)
      return true
    end

    local success, financed, historyAmountPaid = false, false, nil
    if useFinancing and overhaul_career_garage_property_propertyMortgage.isMortgageAvailable() then
      success = purchaseGarageWithFinancing(garage, listedPrice, selectedTerm)
      financed = success
    else
      local totalPrice = listedPrice + calculateClosingFee(listedPrice) + calculateAnnualPropertyTax(listedPrice)
      historyAmountPaid = totalPrice
      local priceTable = { money = { amount = totalPrice, canBeNegative = false } }
      success = overhaul_career_economy_payment.pay(priceTable, require("overhaul/lib/finance/metadata").tag({ label = "Purchased " .. garage.name }, "purchase", {locationId = garage.id, locationName = garage.name, vehicleRelated = false}))
    end
    if not success then return false end
    inputs.parts.ownership.addPurchasedGarage(garage.id, {
      type = financed and "finance" or "purchase",
      amountPaid = listedPrice,
      historyAmountPaid = historyAmountPaid
    })
    overhaul_career_saveSystem.saveCurrent(nil, {force = true})
    guihooks.trigger('toastrMsg', {type="success", title="Property Purchased", msg="Welcome to your new garage!"})
    guihooks.trigger('ChangeState', {state = 'play'})
    return true
  end

  -- Prompt actions --------------------------------------------------------------------------------

  local function showPurchaseGaragePrompt(garageId)
    if not overhaul_career_career.isActive() then return end
    if not garageId or type(garageId) ~= "string" or garageId == "" then return end
    if inputs.parts.ownership.isNotPurchasableGarage(garageId) then return end

    -- A rented garage counts as accessible, so its computer opens directly.
    if overhaul_career_garage_property_propertyRentals.isRentedGarage(garageId) then
      openComputerMenuForGarage(garageId, overhaul_world_facilities.getFacilitiesByType("computer"))
      return
    end

    inputs.state.garageToPurchase = overhaul_world_facilities.getFacility("garage", garageId)

    if getGaragePrice(inputs.state.garageToPurchase) == 0 then
      inputs.parts.ownership.addPurchasedGarage(inputs.state.garageToPurchase.id, { type = "grant", amountPaid = 0 })
      openComputerMenuForGarage(garageId, overhaul_world_facilities.getFacilitiesByType("computer"))
      overhaul_career_saveSystem.saveCurrent()
      return
    end

    inputs.state.pendingGarageListingData = requestGarageListing(garageId)
    guihooks.trigger('openGarageListing', inputs.state.pendingGarageListingData)
    extensions.ui_router.navigate('garage-listing')
  end

  local function requestGarageData()
    local garage = inputs.state.garageToPurchase
    if not garage then return nil end
    if translateLanguage(garage.name, garage.name, true) then
      garage.name = translateLanguage(garage.name, garage.name, true)
    end
    local price = getGaragePrice(garage)
    local closingFee = calculateClosingFee(price)
    local propertyTax = calculateAnnualPropertyTax(price)
    return {
      name = garage.name,
      price = price,
      capacity = math.ceil(garage.capacity / (inputs.parts.ownership.isHardcoreMode() and 2 or 1)),
      closingFeeRate = inputs.CLOSING_FEE_RATE,
      propertyTaxRate = inputs.PROPERTY_TAX_RATE,
      closingFee = closingFee,
      propertyTax = propertyTax,
      estimatedTotal = price + closingFee + propertyTax
    }
  end

  local function canPay(overriddenTotal)
    if overhaul_career_economy_cheats.isCheatsMode() then return true end
    local totalPrice = tonumber(overriddenTotal)
    if not totalPrice or totalPrice <= 0 then return false end
    totalPrice = math.floor(totalPrice + 0.5)
    return overhaul_career_economy_playerAttributes.getAttributeValue("money") >= totalPrice
  end

  local function buyGarage(overriddenTotal, useFinancing, selectedTerm)
    if inputs.state.garageToPurchase and inputs.bundles.forGarage(inputs.state.garageToPurchase.id) then return false end
    if not inputs.state.garageToPurchase then return false end
    if inputs.parts.ownership.isNotPurchasableGarage(inputs.state.garageToPurchase.id, inputs.state.garageToPurchase) then
      inputs.state.garageToPurchase = nil
      return false
    end

    local listedPrice = getGaragePrice(inputs.state.garageToPurchase)
    if not listedPrice then
      inputs.state.garageToPurchase = nil
      return false
    end
    local ownerInfo = overhaul_career_garage_property_propertyOwners.getOwnerForListing(inputs.state.garageToPurchase.id, listedPrice)
    if ownerInfo and ownerInfo.currentAskingPrice then listedPrice = ownerInfo.currentAskingPrice end

    local negotiatedPrice = inputs.parts.ownership.getFrozenPrice(inputs.state.garageToPurchase.id)
    if not negotiatedPrice then negotiatedPrice = inputs.parts.ownership.getPendingNegotiatedPrice(inputs.state.garageToPurchase.id) end
    local effectivePrice = negotiatedPrice or listedPrice
    local totalPrice = effectivePrice + calculateClosingFee(effectivePrice) + calculateAnnualPropertyTax(effectivePrice)

    local success, financed, historyAmountPaid = false, false, nil
    if useFinancing and overhaul_career_garage_property_propertyMortgage.isMortgageAvailable() then
      success = purchaseGarageWithFinancing(inputs.state.garageToPurchase, effectivePrice, selectedTerm)
      financed = success
    else
      historyAmountPaid = totalPrice
      local price = { money = { amount = totalPrice, canBeNegative = false } }
      success = overhaul_career_economy_payment.pay(price, require("overhaul/lib/finance/metadata").tag({ label = "Purchased " .. inputs.state.garageToPurchase.name }, "purchase", {locationId = inputs.state.garageToPurchase.id, locationName = inputs.state.garageToPurchase.name, vehicleRelated = false}))
    end
    if success then
      inputs.parts.ownership.addPurchasedGarage(inputs.state.garageToPurchase.id, {
        type = financed and "finance" or "purchase",
        amountPaid = effectivePrice,
        historyAmountPaid = historyAmountPaid
      })
      if negotiatedPrice then
        inputs.parts.ownership.clearFrozenPrice(inputs.state.garageToPurchase.id)
        inputs.parts.ownership.clearPendingNegotiatedPrice(inputs.state.garageToPurchase.id)
      end
      overhaul_career_saveSystem.saveCurrent(nil, {force = true})
      guihooks.trigger('ChangeState', {state = 'play'})
      inputs.state.garageToPurchase = nil
      return true
    end

    inputs.state.garageToPurchase = nil
    return false
  end

  local function cancelGaragePurchase()
    if inputs.state.garageToPurchase then
      inputs.parts.ownership.clearPendingNegotiatedPrice(inputs.state.garageToPurchase.id)
    end
    guihooks.trigger('ChangeState', {state = 'play'})
    inputs.state.garageToPurchase = nil
  end

  return {
    buyGarage = buyGarage,
    calculateGaragePurchasePrice = calculateGaragePurchasePrice,
    canPay = canPay,
    cancelGaragePurchase = cancelGaragePurchase,
    completePurchaseWithNegotiatedPrice = completePurchaseWithNegotiatedPrice,
    getGaragePrice = getGaragePrice,
    getPendingGarageListing = getPendingGarageListing,
    purchaseGarageAtListedPrice = purchaseGarageAtListedPrice,
    purchaseGarageAtNegotiatedPrice = purchaseGarageAtNegotiatedPrice,
    requestGarageData = requestGarageData,
    requestGarageListing = requestGarageListing,
    showPurchaseGaragePrompt = showPurchaseGaragePrompt,
    startGarageNegotiation = startGarageNegotiation,
  }
end

return purchase
