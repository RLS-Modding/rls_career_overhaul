local M = {}
M.dependencies = { 'career_career', 'career_saveSystem', 'freeroam_facilities', 'career_modules_realEstateNegotiation', 'career_modules_propertyOwners', 'career_modules_propertyMortgage' }

local purchasedGarages = {}
local discoveredGarages = {}
local garageToPurchase = nil
local saveFile = "purchasedGarages.json"

local garageSize = {}
local CLOSING_FEE_RATE = 0.03
local PROPERTY_TAX_RATE = 0.012
local requestGarageListing
local pendingGarageListingData = nil

local NEGOTIATION_COOLDOWN_SECONDS = 30 * 60
local negotiationCooldowns = {}
local frozenPrices = {}
local pendingNegotiatedPrices = {}

local function savePurchasedGarages(currentSavePath)
  if not currentSavePath then
    local slot, path = career_saveSystem.getCurrentSaveSlot()
    currentSavePath = path
    if not currentSavePath then return end
  end

  local dirPath = currentSavePath .. "/career/rls_career"
  if not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end
  
  local data = {
    garages    = purchasedGarages,
    discovered = discoveredGarages
  }
  career_saveSystem.jsonWriteFileSafe(dirPath .. "/" .. saveFile, data, true)
end

local function saveNegotiationCooldowns(currentSavePath)
  if not currentSavePath then
    local slot, path = career_saveSystem.getCurrentSaveSlot()
    currentSavePath = path
    if not currentSavePath then return end
  end

  local dirPath = currentSavePath .. "/career/rls_career"
  if not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end
  
  local data = {
    cooldowns = negotiationCooldowns,
    frozenPrices = frozenPrices
  }
  career_saveSystem.jsonWriteFileSafe(dirPath .. "/negotiationCooldowns.json", data, true)
end

local function loadNegotiationCooldowns()
  if not career_career.isActive() then return end
  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  if not currentSavePath then return end
  
  local filePath = currentSavePath .. "/career/rls_career/negotiationCooldowns.json"
  local data = jsonReadFile(filePath)
  if data then
    negotiationCooldowns = data.cooldowns or {}
    frozenPrices = data.frozenPrices or {}
    
    local currentTime = career_modules_playerAttributes and career_modules_playerAttributes.getAttributeValue("simTime") or 0
    for garageId, cooldownTime in pairs(negotiationCooldowns) do
      if currentTime - cooldownTime > NEGOTIATION_COOLDOWN_SECONDS then
        negotiationCooldowns[garageId] = nil
        if not frozenPrices[garageId] then
          frozenPrices[garageId] = nil
        end
      end
    end
  end
end

local function getCurrentSimTime()
  return os.time()
end

local function canNegotiateGarage(garageId)
  if not garageId then return false, 0 end
  
  local currentTime = getCurrentSimTime()
  local lastNegotiationTime = negotiationCooldowns[garageId]
  
  if not lastNegotiationTime then
    return true, 0
  end
  
  local timeSinceNegotiation = currentTime - lastNegotiationTime
  local cooldownRemaining = math.max(0, NEGOTIATION_COOLDOWN_SECONDS - timeSinceNegotiation)
  
  return cooldownRemaining == 0, cooldownRemaining
end

local function setNegotiationCooldown(garageId)
  if not garageId then return end
  negotiationCooldowns[garageId] = getCurrentSimTime()
end

local function freezeNegotiatedPrice(garageId, price)
  if not garageId or not price then return end
  frozenPrices[garageId] = {
    price = price,
    timestamp = getCurrentSimTime()
  }
end

local function getFrozenPrice(garageId)
  if not garageId then return nil end
  local frozen = frozenPrices[garageId]
  if not frozen then return nil end
  
  local currentTime = getCurrentSimTime()
  local timeSinceFreeze = currentTime - frozen.timestamp
  
  if timeSinceFreeze > NEGOTIATION_COOLDOWN_SECONDS then
    frozenPrices[garageId] = nil
    return nil
  end
  
  return frozen.price
end

local function getPendingNegotiatedPrice(garageId)
  if not garageId then return nil end
  local pending = pendingNegotiatedPrices[garageId]
  if not pending then return nil end

  local currentTime = getCurrentSimTime()
  local timeSinceOffer = currentTime - pending.timestamp
  if timeSinceOffer > NEGOTIATION_COOLDOWN_SECONDS then
    pendingNegotiatedPrices[garageId] = nil
    return nil
  end

  return pending.price
end

local function setPendingNegotiatedPrice(garageId, price)
  if not garageId or not price then return end
  pendingNegotiatedPrices[garageId] = {
    price = price,
    timestamp = getCurrentSimTime()
  }
end

local function clearPendingNegotiatedPrice(garageId)
  if garageId then
    pendingNegotiatedPrices[garageId] = nil
  end
end

local function clearFrozenPrice(garageId)
  if garageId then
    frozenPrices[garageId] = nil
  end
end

local function onSaveCurrentSaveSlot(currentSavePath)
  log("D", "garageManager", "Saving garage data to: " .. currentSavePath .. "/career/rls_career/" .. saveFile)
  savePurchasedGarages(currentSavePath)
  saveNegotiationCooldowns(currentSavePath)
end

local function isPurchasedGarage(garageId)
  return purchasedGarages[garageId] or false
end

local function isAccessibleGarage(garageId)
  if purchasedGarages[garageId] then return true end
  if career_modules_propertyRentals and career_modules_propertyRentals.isRentedGarage(garageId) then return true end
  return false
end

local function isDiscoveredGarage(garageId)
  return discoveredGarages[garageId] or false
end

local function isGarageForSale(garageId)
  if not garageId then return false end
  if not career_modules_realEstateNegotiation or not career_modules_realEstateNegotiation.getPropertyListing then return false end
  return career_modules_realEstateNegotiation.getPropertyListing(garageId) ~= nil
end

local function isStarterGaragePurchasable(garageId)
  if not garageId then return false end
  local garage = freeroam_facilities.getFacility("garage", garageId)
  if not garage or not garage.starterGarage then return false end
  if purchasedGarages[garageId] then return false end
  if not career_challengeModes or not career_challengeModes.isChallengeActive() then return false end
  local activeChallenge = career_challengeModes.getActiveChallenge()
  if not activeChallenge or not activeChallenge.startingGarages or #activeChallenge.startingGarages == 0 then return false end
  for _, startingGarageId in ipairs(activeChallenge.startingGarages) do
    if startingGarageId == garageId then return false end
  end
  return true
end

local function reloadRecoveryPrompt()
  if core_recoveryPrompt then
    core_recoveryPrompt.addTowingButtons()
    core_recoveryPrompt.addTaxiButtons()
  end
end

local function buildGarageSizes()
  local garages = freeroam_facilities.getFacilitiesByType("garage")
  
  if garages then
    for _, garage in pairs(garages) do
      if isGarageForSale(garage.id) then
        garageSize[tostring(garage.id)] = nil
        goto continue
      end
      local isRented = career_modules_propertyRentals and career_modules_propertyRentals.isRentedGarage(garage.id)
      if purchasedGarages[garage.id] or isRented then
        garageSize[tostring(garage.id)] = (math.ceil(garage.capacity / (career_modules_hardcore.isHardcoreMode() and 2 or 1)) or 0)
      end
      ::continue::
    end
  end
end

local function addPurchasedGarage(garageId)
  log("I", "garageManager", "Adding purchased garage: " .. garageId)
  purchasedGarages[garageId] = true
  discoveredGarages[garageId] = true
  reloadRecoveryPrompt()
  buildGarageSizes()
end

local function addDiscoveredGarage(garageId)
  if not discoveredGarages[garageId] then
    local garages = freeroam_facilities.getFacilitiesByType("garage")
    local garage = garages[garageId]
    if garage and garage.defaultPrice == 0 then
      purchasedGarages[garageId] = true
    end
    discoveredGarages[garageId] = true
    reloadRecoveryPrompt()
  end
end

local function purchaseDefaultGarage()
  if career_career.hardcoreMode or career_modules_hardcore.isHardcoreMode() then return end
  
  -- Check if challenge has starting garages
  if career_challengeModes and career_challengeModes.isChallengeActive() then
    local activeChallenge = career_challengeModes.getActiveChallenge()
    if activeChallenge and activeChallenge.startingGarages and #activeChallenge.startingGarages > 0 then
      -- Challenge has starting garages, don't purchase default starter garage
      log("D", "garageManager", "purchaseDefaultGarage: Skipping default garage purchase - challenge has starting garages: " .. dumps(activeChallenge.startingGarages))
      return
    end
  end
  
  -- Only purchase default starter garage if no challenge starting garages are selected
  local garages = freeroam_facilities.getFacilitiesByType("garage")
  if not garages or #garages == 0 then return end  -- Return if no garages
  for _, garage in ipairs(garages) do
    if garage.starterGarage then
      log("D", "garageManager", "purchaseDefaultGarage: Purchasing default starter garage: " .. garage.id)
      addPurchasedGarage(garage.id)
      return
    end
  end
end

local function fillGarages()
  local vehicles = career_modules_inventory.getVehicles()
  for id, vehicle in pairs(vehicles) do
    if not vehicle.location then
      career_modules_inventory.moveVehicleToGarage(id)
    end
    if not vehicle.niceLocation then
      career_modules_inventory.moveVehicleToGarage(id, vehicle.location)
    end
  end
end

local function loadPurchasedGarages()
  if not career_career.isActive() then return end
  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  if not currentSavePath then return end
  
  local filePath = currentSavePath .. "/career/rls_career/" .. saveFile
  local data = jsonReadFile(filePath) or {}
  purchasedGarages = data.garages or {}
  discoveredGarages = data.discovered or {}
  -- Check general data
  if career_career.hardcoreMode then
    purchasedGarages = {}
    discoveredGarages = {}
  end

  -- If we have an active challenge with starting garages, ensure they are purchased
  if career_challengeModes and career_challengeModes.isChallengeActive() then
    local activeChallenge = career_challengeModes.getActiveChallenge()
    if activeChallenge and activeChallenge.startingGarages and #activeChallenge.startingGarages > 0 then
      log("D", "garageManager", "loadPurchasedGarages: Ensuring challenge starting garages are purchased: " .. dumps(activeChallenge.startingGarages))
      for _, garageId in ipairs(activeChallenge.startingGarages) do
        if not purchasedGarages[garageId] then
          log("D", "garageManager", "loadPurchasedGarages: Adding missing challenge starting garage: " .. garageId)
          purchasedGarages[garageId] = true
          discoveredGarages[garageId] = true
        end
      end
    end
  end

  reloadRecoveryPrompt()
  buildGarageSizes()
  fillGarages()
end

local function onCareerModulesActivated()
  loadPurchasedGarages()
end

local function onExtensionLoaded()
  loadPurchasedGarages()
  loadNegotiationCooldowns()
  buildGarageSizes()
end

local function calculateGaragePurchasePrice(garageId)
  if not garageId then
    return nil
  end

  local garage = freeroam_facilities.getFacility("garage", garageId)
  if not garage then
    return nil
  end

  if not career_modules_hardcore.isHardcoreMode() and garage.starterGarage then
    if not isStarterGaragePurchasable(garageId) then
      return 0
    end
  end

  local price = garage.defaultPrice
  if career_modules_globalEconomy and career_modules_globalEconomy.getHousingMarketIndex then
    price = math.floor(price * career_modules_globalEconomy.getHousingMarketIndex() + 0.5)
  end
  return price
end

local function calculateClosingFee(price)
  if not price or price <= 0 then return 0 end
  return math.floor((price * CLOSING_FEE_RATE) + 0.5)
end

local function calculateAnnualPropertyTax(price)
  if not price or price <= 0 then return 0 end
  return math.floor((price * PROPERTY_TAX_RATE) + 0.5)
end

-- Wrapper for backward compatibility
local function getGaragePrice(garage, computerId)
  local garageId
  if garage then
    garageId = type(garage) == "table" and garage.id or garage
  elseif computerId then
    local computer = freeroam_facilities.getFacility("computer", computerId)
    if computer then garageId = computer.garageId end
  end
  return calculateGaragePurchasePrice(garageId)
end

-- Complete purchase with negotiated price (called from realEstateNegotiation module)
local function completePurchaseWithNegotiatedPrice(garageId, finalPrice, freezePrice, useFinancing, selectedTerm)
  if not career_career.isActive() then 
    log("E", "garageManager", "completePurchaseWithNegotiatedPrice: Career not active")
    return false 
  end
  
  if not garageId or not finalPrice then
    log("E", "garageManager", "completePurchaseWithNegotiatedPrice: Missing garageId or finalPrice")
    return false
  end
  
  local garage = freeroam_facilities.getFacility("garage", garageId)
  if not garage then
    log("E", "garageManager", "completePurchaseWithNegotiatedPrice: Garage not found: " .. tostring(garageId))
    return false
  end
  
  garageToPurchase = garage
  setNegotiationCooldown(garageId)
  setPendingNegotiatedPrice(garageId, finalPrice)
  
  if freezePrice then
    freezeNegotiatedPrice(garageId, finalPrice)
  end
  
  local listingData = requestGarageListing(garageId)
  
  -- Always show the negotiated price on the listing, even if not frozen
  listingData.negotiatedPrice = finalPrice
  listingData.isFrozen = freezePrice == true
  local closingFee = calculateClosingFee(finalPrice)
  local propertyTax = calculateAnnualPropertyTax(finalPrice)
  listingData.closingFee = closingFee
  listingData.propertyTax = propertyTax
  listingData.estimatedTotal = finalPrice + closingFee + propertyTax
  
  listingData.useFinancing = useFinancing == true
  listingData.selectedTerm = selectedTerm
  pendingGarageListingData = listingData
  
  guihooks.trigger('openGarageListing', listingData)
  guihooks.trigger('ChangeState', {state = 'garage-listing', params = {}})
  
  return true
end

local function purchaseGarageAtNegotiatedPrice(garageId, useFinancing, selectedTerm)
  if not career_career.isActive() then 
    log("E", "garageManager", "purchaseGarageAtNegotiatedPrice: Career not active")
    return false 
  end
  
  if not garageId or type(garageId) ~= "string" or garageId == "" then
    log("E", "garageManager", "purchaseGarageAtNegotiatedPrice: Invalid garageId (expected non-empty string)")
    return false
  end
  
  local garage = freeroam_facilities.getFacility("garage", garageId)
  if not garage then
    log("E", "garageManager", "purchaseGarageAtNegotiatedPrice: Garage not found: " .. tostring(garageId))
    return false
  end
  
  local negotiatedPrice = getFrozenPrice(garageId)
  if not negotiatedPrice then
    negotiatedPrice = getPendingNegotiatedPrice(garageId)
  end
  if not negotiatedPrice then
    log("E", "garageManager", "purchaseGarageAtNegotiatedPrice: No negotiated price found")
    return false
  end
  
  if not career_modules_payment then
    log("E", "garageManager", "purchaseGarageAtNegotiatedPrice: Payment module not loaded")
    return false
  end

  local closingFee = calculateClosingFee(negotiatedPrice)
  local propertyTax = calculateAnnualPropertyTax(negotiatedPrice)

  local success = false
  if useFinancing and career_modules_propertyMortgage and career_modules_propertyMortgage.isMortgageAvailable and career_modules_propertyMortgage.isMortgageAvailable() then
    local feesOnly = closingFee + propertyTax
    local feesPaid = true
    if feesOnly > 0 then
      local feesPrice = { money = { amount = feesOnly, canBeNegative = false } }
      feesPaid = career_modules_payment.pay(feesPrice, { label = "Closing costs for " .. garage.name })
    end

    if feesPaid then
      local mortgage = career_modules_propertyMortgage.createMortgage(garage.id, negotiatedPrice, selectedTerm)
      success = mortgage ~= nil
    end
  else
    local totalPrice = negotiatedPrice + closingFee + propertyTax
    local price = { money = { amount = totalPrice, canBeNegative = false } }
    success = career_modules_payment.pay(price, { label = "Purchased " .. garage.name })
  end

  if success then
    addPurchasedGarage(garage.id)
    clearFrozenPrice(garageId)
    clearPendingNegotiatedPrice(garageId)
    career_saveSystem.saveCurrent()
    guihooks.trigger('toastrMsg', {type="success", title="Property Purchased", msg="Welcome to your new garage!"})
    guihooks.trigger('ChangeState', {state = 'play'})
    return true
  end

  return false
end

-- Request garage listing data for UI (with negotiation support)
requestGarageListing = function(garageId)
  if not career_career.isActive() then return nil end
  
  local garage = freeroam_facilities.getFacility("garage", garageId)
  if not garage then return nil end
  
  local listedPrice = getGaragePrice(garage)
  local canNegotiate = (not garage.starterGarage or isStarterGaragePurchasable(garageId)) and listedPrice > 0
  local ownerInfo = nil
  if career_modules_propertyOwners and career_modules_propertyOwners.getOwnerForListing then
    ownerInfo = career_modules_propertyOwners.getOwnerForListing(garageId, listedPrice)
    if ownerInfo and ownerInfo.currentAskingPrice then
      listedPrice = ownerInfo.currentAskingPrice
    end
  end
  
  -- Get garage preview from computer preview if available
  local preview = garage.preview or ""
  local computers = freeroam_facilities.getFacilitiesByType("computer")
  if computers then
    for _, comp in pairs(computers) do
      if comp.garageId == garageId and comp.preview then
        preview = comp.preview
        break
      end
    end
  end
  
  -- Translate name if needed
  local name = garage.name
  if translateLanguage then
    local translated = translateLanguage(garage.name, garage.name, true)
    if translated then name = translated end
  end
  
  local negotiatedPrice = getFrozenPrice(garageId)
  if not negotiatedPrice then
    negotiatedPrice = getPendingNegotiatedPrice(garageId)
  end
  local effectivePrice = negotiatedPrice or listedPrice
  
  local closingFee = calculateClosingFee(effectivePrice)
  local propertyTax = calculateAnnualPropertyTax(effectivePrice)
  local estimatedTotal = effectivePrice + closingFee + propertyTax
  
  local canNegotiateNow, cooldownRemaining = canNegotiateGarage(garageId)
  canNegotiate = canNegotiate and canNegotiateNow

  local mortgageAvailableFlag = false
  local mortgageInfo = nil
  local creditTier = ""
  if career_modules_propertyMortgage and career_modules_propertyMortgage.isMortgageAvailable then
    mortgageAvailableFlag = career_modules_propertyMortgage.isMortgageAvailable()
    if mortgageAvailableFlag and career_modules_propertyMortgage.getMortgageOfferDetails then
      local details = career_modules_propertyMortgage.getMortgageOfferDetails()
      if details then
        local dpPct = details.downPaymentPercent or 0.2
        mortgageInfo = {
          creditTier = details.tier or "",
          downPaymentPct = math.floor(dpPct * 100),
          downPayment = math.floor(effectivePrice * dpPct),
          interestRate = details.rate or 0,
          availableTerms = details.termsAvailable or {12, 24, 36, 48},
        }
      end
    end
  end
  if career_modules_credit and career_modules_credit.getTier then
    local tier = career_modules_credit.getTier()
    if tier then creditTier = tier.label end
  end

  local rentalBreakdown = nil
  if career_modules_propertyRentals and career_modules_propertyRentals.getRentalBreakdown then
    rentalBreakdown = career_modules_propertyRentals.getRentalBreakdown(garageId)
  end

  local data = {
    garageId = garage.id,
    name = name,
    preview = preview,
    listedPrice = listedPrice,
    negotiatedPrice = negotiatedPrice,
    closingFee = closingFee,
    propertyTax = propertyTax,
    estimatedTotal = estimatedTotal,
    capacity = math.ceil(garage.capacity / (career_modules_hardcore.isHardcoreMode() and 2 or 1)),
    parkingSpots = (garage.parkingSpotNames and #garage.parkingSpotNames) or 0,
    neighborhood = "West Coast",
    canNegotiate = canNegotiate,
    cooldownRemaining = cooldownRemaining,
    isFrozen = getFrozenPrice(garageId) ~= nil,
    starterGarage = (garage.starterGarage and not isStarterGaragePurchasable(garageId)) or false,
    ownerInfo = ownerInfo,
    ownerName = ownerInfo and ownerInfo.name or nil,
    ownerArchetype = ownerInfo and ownerInfo.archetype or nil,
    mortgageAvailable = mortgageAvailableFlag,
    mortgageInfo = mortgageInfo,
    creditTier = creditTier,
    rentalBreakdown = rentalBreakdown,
  }
  
  return data
end

-- Start negotiation for a garage purchase
local function startGarageNegotiation(garageId)
  if not career_career.isActive() then return false end
  if not career_modules_realEstateNegotiation then
    log("E", "garageManager", "realEstateNegotiation module not loaded")
    return false
  end
  
  local canNegotiateNow, cooldownRemaining = canNegotiateGarage(garageId)
  if not canNegotiateNow then
    log("W", "garageManager", "Negotiation on cooldown for garage: " .. tostring(garageId))
    return false
  end
  
  return career_modules_realEstateNegotiation.startNegotiateBuying(garageId)
end

-- Purchase garage at listed price (no negotiation)
local function purchaseGarageAtListedPrice(garageId, useFinancing, selectedTerm)
  if not career_career.isActive() then 
    log("E", "garageManager", "purchaseGarageAtListedPrice: Career not active")
    return false 
  end
  
  if not garageId or type(garageId) ~= "string" or garageId == "" then
    log("E", "garageManager", "purchaseGarageAtListedPrice: Invalid garageId (expected non-empty string)")
    return false
  end
  
  local garage = freeroam_facilities.getFacility("garage", garageId)
  if not garage then
    log("E", "garageManager", "purchaseGarageAtListedPrice: Garage not found: " .. tostring(garageId))
    return false
  end
  
  local listedPrice = getGaragePrice(garage)
  if not listedPrice then
    log("E", "garageManager", "purchaseGarageAtListedPrice: Could not determine price for garage: " .. tostring(garageId))
    return false
  end
  
  if career_modules_propertyOwners and career_modules_propertyOwners.getOwnerForListing then
    local ownerInfo = career_modules_propertyOwners.getOwnerForListing(garageId, listedPrice)
    if ownerInfo and ownerInfo.currentAskingPrice then
      listedPrice = ownerInfo.currentAskingPrice
    end
  end
  
  -- Free garages (starter garages)
  if listedPrice == 0 then
    addPurchasedGarage(garage.id)
    career_saveSystem.saveCurrent()
    
    local computers = freeroam_facilities.getFacilitiesByType("computer")
    if computers then
      for _, computer in pairs(computers) do
        if computer.garageId == garageId then
          career_modules_computer.openComputerMenuById(computer.id)
          break
        end
      end
    end
    
    return true
  end
  
  -- Paid garages
  if not career_modules_payment then
    log("E", "garageManager", "purchaseGarageAtListedPrice: Payment module not loaded")
    return false
  end

  local closingFee = calculateClosingFee(listedPrice)
  local propertyTax = calculateAnnualPropertyTax(listedPrice)

  local success = false
  if useFinancing and career_modules_propertyMortgage and career_modules_propertyMortgage.isMortgageAvailable and career_modules_propertyMortgage.isMortgageAvailable() then
    local feesOnly = closingFee + propertyTax
    local feesPaid = true
    if feesOnly > 0 then
      local feesPrice = { money = { amount = feesOnly, canBeNegative = false } }
      feesPaid = career_modules_payment.pay(feesPrice, { label = "Closing costs for " .. garage.name })
    end

    if feesPaid then
      local mortgage = career_modules_propertyMortgage.createMortgage(garage.id, listedPrice, selectedTerm)
      success = mortgage ~= nil
    end
  else
    local totalPrice = listedPrice + closingFee + propertyTax
    local priceTable = { money = { amount = totalPrice, canBeNegative = false } }
    success = career_modules_payment.pay(priceTable, { label = "Purchased " .. garage.name })
  end

  if success then
    addPurchasedGarage(garage.id)
    career_saveSystem.saveCurrent()
    guihooks.trigger('toastrMsg', {type="success", title="Property Purchased", msg="Welcome to your new garage!"})
    guihooks.trigger('ChangeState', {state = 'play'})
    return true
  end

  return false
end

local function getPendingGarageListing()
  local data = pendingGarageListingData
  pendingGarageListingData = nil
  return data
end

local function showPurchaseGaragePrompt(garageId)
  if not career_career.isActive() then return end
  if not garageId or type(garageId) ~= "string" or garageId == "" then return end

  -- Rented garages: treat as accessible, open computer directly
  if career_modules_propertyRentals and career_modules_propertyRentals.isRentedGarage(garageId) then
    local computers = freeroam_facilities.getFacilitiesByType("computer")
    local computerId = nil
    for _, computer in pairs(computers) do
      if computer.garageId == garageId then
        computerId = computer.id
        break
      end
    end
    if computerId then
      career_modules_computer.openComputerMenuById(computerId)
    end
    return
  end

  garageToPurchase = freeroam_facilities.getFacility("garage", garageId)
  
  -- Free garages (starter garages) - purchase immediately
  if getGaragePrice(garageToPurchase) == 0 then
    addPurchasedGarage(garageToPurchase.id)
    local computers = freeroam_facilities.getFacilitiesByType("computer")
    local computerId = nil
    for _, computer in pairs(computers) do
      if computer.garageId == garageId then
        computerId = computer.id
        break
      end
    end
    if computerId then
      career_modules_computer.openComputerMenuById(computerId)
    end
    career_saveSystem.saveCurrent()
    return
  end
  
  -- Paid garages - show listing view with negotiation option
  pendingGarageListingData = requestGarageListing(garageId)
  guihooks.trigger('openGarageListing', pendingGarageListingData)
  guihooks.trigger('ChangeState', {state = 'garage-listing'})
end

local function requestGarageData()
  local garage = garageToPurchase
  if garage then
    if translateLanguage(garage.name, garage.name, true) then
      garage.name = translateLanguage(garage.name, garage.name, true)
    end
    local price = getGaragePrice(garage)
    local closingFee = calculateClosingFee(price)
    local propertyTax = calculateAnnualPropertyTax(price)
    local garageData = {
      name = garage.name,
      price = price,
      capacity = math.ceil(garage.capacity / (career_modules_hardcore.isHardcoreMode() and 2 or 1)),
      closingFeeRate = CLOSING_FEE_RATE,
      propertyTaxRate = PROPERTY_TAX_RATE,
      closingFee = closingFee,
      propertyTax = propertyTax,
      estimatedTotal = price + closingFee + propertyTax
    }
    return garageData
  end
  return nil
end

local function canPay(overriddenTotal)
  if career_modules_cheats and career_modules_cheats.isCheatsMode() then
    return true
  end
  local totalPrice = tonumber(overriddenTotal)
  if not totalPrice or totalPrice <= 0 then
    return false
  end
  totalPrice = math.floor(totalPrice + 0.5)
  local currentMoney = career_modules_playerAttributes.getAttributeValue("money")
  return currentMoney >= totalPrice
end

local function buyGarage(overriddenTotal, useFinancing, selectedTerm)
  if not garageToPurchase then
    return false
  end

  local listedPrice = getGaragePrice(garageToPurchase)
  if not listedPrice then
    garageToPurchase = nil
    return false
  end
  
  if career_modules_propertyOwners and career_modules_propertyOwners.getOwnerForListing then
    local ownerInfo = career_modules_propertyOwners.getOwnerForListing(garageToPurchase.id, listedPrice)
    if ownerInfo and ownerInfo.currentAskingPrice then
      listedPrice = ownerInfo.currentAskingPrice
    end
  end

  local negotiatedPrice = getFrozenPrice(garageToPurchase.id)
  if not negotiatedPrice then
    negotiatedPrice = getPendingNegotiatedPrice(garageToPurchase.id)
  end
  local effectivePrice = negotiatedPrice or listedPrice
  
  local closingFee = calculateClosingFee(effectivePrice)
  local propertyTax = calculateAnnualPropertyTax(effectivePrice)
  local totalPrice = effectivePrice + closingFee + propertyTax
  local overrideAmount = tonumber(overriddenTotal)
  if overrideAmount and overrideAmount > 0 then
    totalPrice = math.floor(overrideAmount + 0.5)
  end

  local success = false
  if useFinancing and career_modules_propertyMortgage and career_modules_propertyMortgage.isMortgageAvailable and career_modules_propertyMortgage.isMortgageAvailable() then
    local feesOnly = closingFee + propertyTax
    local feesPaid = true
    if feesOnly > 0 then
      local feesPrice = { money = { amount = feesOnly, canBeNegative = false } }
      feesPaid = career_modules_payment.pay(feesPrice, { label = "Closing costs for " .. garageToPurchase.name })
    end

    if feesPaid then
      local mortgage = career_modules_propertyMortgage.createMortgage(garageToPurchase.id, effectivePrice, selectedTerm)
      success = mortgage ~= nil
    end
  else
    local price = { money = { amount = totalPrice, canBeNegative = false } }
    success = career_modules_payment.pay(price, { label = "Purchased " .. garageToPurchase.name })
  end

  if success then
    addPurchasedGarage(garageToPurchase.id)
    if negotiatedPrice then
      clearFrozenPrice(garageToPurchase.id)
      clearPendingNegotiatedPrice(garageToPurchase.id)
    end
    career_saveSystem.saveCurrent()
    guihooks.trigger('ChangeState', {state = 'play'})
    garageToPurchase = nil
    return true
  end

  garageToPurchase = nil
  return false
end

local function cancelGaragePurchase()
  if garageToPurchase then
    clearPendingNegotiatedPrice(garageToPurchase.id)
  end
  guihooks.trigger('ChangeState', {state = 'play'})
  garageToPurchase = nil
end

local function getStoredLocations()
  local vehicles = career_modules_inventory.getVehicles()
  local storedLocation = {}
  for id, vehicle in pairs(vehicles) do -- Builds stored location table
      if vehicle.location then
          if not storedLocation[vehicle.location] then
              storedLocation[vehicle.location] = {}
          end
          table.insert(storedLocation[vehicle.location], id) -- Adds vehicle to location
      end
  end
  return storedLocation
end

local function getVehiclesInGarage(garageId)
  if not garageId then return {} end
  local storedLocation = getStoredLocations()
  return storedLocation[garageId] or {}
end

local function removePurchasedGarage(garageId)
  if not garageId then return false end
  if not purchasedGarages[garageId] then return false end

  purchasedGarages[garageId] = nil
  discoveredGarages[garageId] = nil
  reloadRecoveryPrompt()
  buildGarageSizes()
  career_saveSystem.saveCurrent()
  return true
end

local function getGarageCapacityData()
  buildGarageSizes()
  local storedLocation = getStoredLocations()
  local data = {}

  for garageId, owned in pairs(purchasedGarages) do
    if owned and not isGarageForSale(garageId) then
      local garage = freeroam_facilities.getFacility("garage", garageId)
      local capacity = garageSize[tostring(garageId)]
      if not capacity and garage and garage.capacity then
        capacity = math.ceil(garage.capacity / (career_modules_hardcore.isHardcoreMode() and 2 or 1))
      end
      local vehiclesInGarage = storedLocation[garageId]
      local count = vehiclesInGarage and #vehiclesInGarage or 0

      data[tostring(garageId)] = {
        id = garageId,
        name = garage and garage.name or tostring(garageId),
        capacity = capacity or 0,
        count = count
      }
    end
  end

  return data
end

local function getPurchasedGarages()
  local result = {}
  for garageId, _ in pairs(purchasedGarages) do
    table.insert(result, garageId)
  end
  return result
end

local function isGarageSpace(garage)
  if isGarageForSale(garage) then return {false, 0} end
  if not garageSize[garage] then
    buildGarageSizes()
    if not garageSize[garage] then return {false, 0} end
  end
  local storedLocation = getStoredLocations()

  local carsInGarage
  if not storedLocation[garage] or storedLocation[garage] == {} then
    carsInGarage = 0
  else
    carsInGarage = #storedLocation[garage]
  end
  return {(garageSize[garage] - carsInGarage) > 0, garageSize[garage] - carsInGarage}
end

local function getFreeSlots()
  local totalCapacity = 0
  for garage, owned in pairs(purchasedGarages) do
    if not owned then goto continue end
    if isGarageForSale(garage) then goto continue end
    local space = isGarageSpace(garage)
    if space[1] then 
      totalCapacity = totalCapacity + space[2]
    end
    ::continue::
  end
  if career_modules_propertyRentals and career_modules_propertyRentals.getActiveRentals then
    for garageId, _ in pairs(career_modules_propertyRentals.getActiveRentals()) do
      if not purchasedGarages[garageId] then
        local space = isGarageSpace(garageId)
        if space[1] then
          totalCapacity = totalCapacity + space[2]
        end
      end
    end
  end
  return totalCapacity
end

local function garageIdToName(garageId)
  local garage = freeroam_facilities.getFacility("garage", garageId)
  if garage then
    return garage.name
  end
  return nil
end

local function computerIdToGarageId(computerId)
  local computer = freeroam_facilities.getFacility("computer", computerId)
  if computer then
    return computer.garageId
  end
  return nil
end

local function getGaragePurchasePrice(garageId)
  return calculateGaragePurchasePrice(garageId)
end

-- Legacy function for garage selling (applies 0.75 multiplier for sell-back price)
-- DO NOT use for purchase price - use getGaragePurchasePrice instead
local function getGarageSellPrice(garageId, computerId)
  if not garageId and not computerId then
    return nil
  elseif not garageId and computerId then
    garageId = computerIdToGarageId(computerId)
  end
  if not garageId then
    return nil
  end
  local garage = freeroam_facilities.getFacility("garage", garageId)
  if garage then
    if career_modules_hardcore.isHardcoreMode() then
      return garage.defaultPrice * 0.75
    else
      -- Check if this garage is a starting garage in an active challenge
      if career_challengeModes and career_challengeModes.isChallengeActive() then
        local activeChallenge = career_challengeModes.getActiveChallenge()
        if activeChallenge and activeChallenge.startingGarages then
          for _, startingGarageId in ipairs(activeChallenge.startingGarages) do
            if startingGarageId == garageId then
              -- This garage is selected as a starting garage, charge full price
              log("D", "garageManager", "getGarageSellPrice: Garage " .. garageId .. " is challenge starting garage, sell price: " .. garage.defaultPrice)
              return tonumber(garage.defaultPrice)
            end
          end
        end
      end
      
      local starterWasPurchased = false
      if garage.starterGarage and career_challengeModes and career_challengeModes.isChallengeActive() then
        local ac = career_challengeModes.getActiveChallenge()
        if ac and ac.startingGarages and #ac.startingGarages > 0 then
          local isStart = false
          for _, sgId in ipairs(ac.startingGarages) do
            if sgId == garageId then isStart = true break end
          end
          if not isStart then starterWasPurchased = true end
        end
      end
      local price = (garage.starterGarage and not starterWasPurchased) and 0 or garage.defaultPrice
      -- Apply housing market index if available
      if career_modules_globalEconomy and career_modules_globalEconomy.getHousingMarketIndex then
        price = math.floor(price * career_modules_globalEconomy.getHousingMarketIndex() + 0.5)
      end
      log("D", "garageManager", "getGarageSellPrice: Garage " .. garageId .. " sell price: " .. price .. " (starterGarage: " .. tostring(garage.starterGarage) .. ")")
      return math.floor(tonumber(price) * 0.75 + 0.5)
    end
  end
  return nil
end

local function canSellGarageByGarageId(garageId)
  if not garageId then
    return false
  end
  local garage = freeroam_facilities.getFacility("garage", garageId)
  if not garage then
    return false
  end
  
  if career_challengeModes and career_challengeModes.isChallengeActive() then
    local activeChallenge = career_challengeModes.getActiveChallenge()
    if activeChallenge and activeChallenge.startingGarages then
      -- In challenges, only block selling garages that were given for free as starting garages
      for _, startingGarageId in ipairs(activeChallenge.startingGarages) do
        if startingGarageId == garageId then
          return {false, 0}
        end
      end
      -- Starter garages purchased in a challenge (not given for free) can be sold
    end
  elseif garage.starterGarage then
    -- Outside of challenges, starter garages given at career start can't be sold
    return {false, 0}
  end
  
  local space = isGarageSpace(garageId)
  local capacity = math.ceil(garage.capacity / (career_modules_hardcore.isHardcoreMode() and 2 or 1))
  return {space[2] == capacity, capacity - space[2]}
end

local function canSellGarage(computerId)
  local garageId = computerIdToGarageId(computerId)
  if not garageId then
    return false
  end
  return canSellGarageByGarageId(garageId)
end

local function listGarageForSale(computerId, askingPrice)
  if not career_career.isActive() then return false end

  local garageId = computerIdToGarageId(computerId)
  if not garageId then
    return false
  end

  local canSellInfo = canSellGarage(computerId)
  if not canSellInfo or not canSellInfo[1] then
    return false
  end

  if not career_modules_realEstateNegotiation or not career_modules_realEstateNegotiation.listPropertyForSale then
    log("E", "garageManager", "listPropertyForSale is not available")
    return false
  end

  local marketPrice = getGaragePurchasePrice(garageId) or 0
  local desiredPrice = tonumber(askingPrice) or marketPrice
  if desiredPrice <= 0 then
    return false
  end

  if career_modules_propertyMortgage and career_modules_propertyMortgage.hasMortgage and career_modules_propertyMortgage.hasMortgage(garageId) then
    if not career_modules_propertyMortgage.canSellMortgagedProperty(garageId, desiredPrice) then
      guihooks.trigger('toastrMsg', {type="error", title="Sale Blocked", msg="Asking price must exceed remaining mortgage balance."})
      return false
    end
  end

  return career_modules_realEstateNegotiation.listPropertyForSale(garageId, desiredPrice)
end

local function listGarageForSaleByGarageId(garageId, askingPrice)
  if not career_career.isActive() then return false end
  if not garageId then return false end

  local canSellInfo = canSellGarageByGarageId(garageId)
  if not canSellInfo or not canSellInfo[1] then
    return false
  end

  if not career_modules_realEstateNegotiation or not career_modules_realEstateNegotiation.listPropertyForSale then
    log("E", "garageManager", "listPropertyForSale is not available")
    return false
  end

  local marketPrice = getGaragePurchasePrice(garageId) or 0
  local desiredPrice = tonumber(askingPrice) or marketPrice
  if desiredPrice <= 0 then
    return false
  end

  if career_modules_propertyMortgage and career_modules_propertyMortgage.hasMortgage and career_modules_propertyMortgage.hasMortgage(garageId) then
    if not career_modules_propertyMortgage.canSellMortgagedProperty(garageId, desiredPrice) then
      guihooks.trigger('toastrMsg', {type="error", title="Sale Blocked", msg="Asking price must exceed remaining mortgage balance."})
      return false
    end
  end

  return career_modules_realEstateNegotiation.listPropertyForSale(garageId, desiredPrice)
end

local function sellGarage(computerId, sellPrice)
  -- Legacy API kept for compatibility: now routes to listing flow.
  return listGarageForSale(computerId, sellPrice)
end

local function completePropertySaleFromListing(garageId, finalPrice, buyerPersonality)
  if not career_career.isActive() then return false end
  if not garageId or not finalPrice then return false end

  local garage = freeroam_facilities.getFacility("garage", garageId)
  if not garage then return false end
  if not purchasedGarages[garageId] then return false end

  local payoutAmount = finalPrice
  if career_modules_propertyMortgage and career_modules_propertyMortgage.hasMortgage and career_modules_propertyMortgage.hasMortgage(garageId) then
    if not career_modules_propertyMortgage.canSellMortgagedProperty(garageId, finalPrice) then
      guihooks.trigger('toastrMsg', {type="error", title="Sale Blocked", msg="Sale price does not cover remaining mortgage balance."})
      return false
    end

    local processed, netProceeds = career_modules_propertyMortgage.processMortgageSale(garageId, finalPrice)
    if not processed then
      return false
    end
    payoutAmount = netProceeds or 0
  end

  purchasedGarages[garageId] = nil
  reloadRecoveryPrompt()
  buildGarageSizes()

  local soldMessage = "Sold " .. (garage.name or tostring(garageId))
  career_modules_payment.reward({ money = { amount = payoutAmount } }, { label = soldMessage }, true)

  if career_modules_propertyOwners and career_modules_propertyOwners.registerOwnerFromSale then
    career_modules_propertyOwners.registerOwnerFromSale(garageId, finalPrice, buyerPersonality)
  end

  if career_modules_realEstateNegotiation and career_modules_realEstateNegotiation.removePropertyListing then
    career_modules_realEstateNegotiation.removePropertyListing(garageId)
  end

  career_saveSystem.saveCurrent()
  guihooks.trigger('garageListingsUpdated')
  return true
end

local function getGarageListingPriceGuidance(computerId, askingPrice)
  local garageId = computerIdToGarageId(computerId)
  if not garageId then return nil end
  if not career_modules_realEstateNegotiation or not career_modules_realEstateNegotiation.getPriceGuidanceForListing then
    return nil
  end
  return career_modules_realEstateNegotiation.getPriceGuidanceForListing(garageId, askingPrice)
end

local function getGarageListingPriceGuidanceByGarageId(garageId, askingPrice)
  if not garageId then return nil end
  if not career_modules_realEstateNegotiation or not career_modules_realEstateNegotiation.getPriceGuidanceForListing then
    return nil
  end
  return career_modules_realEstateNegotiation.getPriceGuidanceForListing(garageId, askingPrice)
end

local function getGarageActiveListing(computerId)
  local garageId = computerIdToGarageId(computerId)
  if not garageId then return nil end
  if not career_modules_realEstateNegotiation or not career_modules_realEstateNegotiation.getPropertyListing then
    return nil
  end
  return career_modules_realEstateNegotiation.getPropertyListing(garageId)
end

local function removeGarageListing(computerId)
  local garageId = computerIdToGarageId(computerId)
  if not garageId then return false end
  if not career_modules_realEstateNegotiation or not career_modules_realEstateNegotiation.removePropertyListing then
    return false
  end
  return career_modules_realEstateNegotiation.removePropertyListing(garageId)
end

local function startGarageSellingNegotiation(computerId, offerIndex)
  local garageId = computerIdToGarageId(computerId)
  if not garageId then return false end
  if not career_modules_realEstateNegotiation or not career_modules_realEstateNegotiation.startNegotiateSelling then
    return false
  end
  return career_modules_realEstateNegotiation.startNegotiateSelling(garageId, offerIndex)
end

local function getNextAvailableSpace()
  for garage, owned in pairs(purchasedGarages) do
    if not owned then goto continue end
    if isGarageForSale(garage) then goto continue end
    if isGarageSpace(garage)[1] then 
      return garage
    end
    ::continue::
  end
  if career_modules_propertyRentals and career_modules_propertyRentals.getActiveRentals then
    for garageId, _ in pairs(career_modules_propertyRentals.getActiveRentals()) do
      if not purchasedGarages[garageId] and isGarageSpace(garageId)[1] then
        return garageId
      end
    end
  end
  return nil
end

local function onWorldReadyState(state)
  if state == 2 and career_career.isActive() then
    buildGarageSizes()
    fillGarages()
    purchaseDefaultGarage()
  end
end

M.onWorldReadyState = onWorldReadyState

M.purchaseDefaultGarage = purchaseDefaultGarage

M.showPurchaseGaragePrompt = showPurchaseGaragePrompt
M.requestGarageData = requestGarageData
M.canPay = canPay
M.buyGarage = buyGarage
M.cancelGaragePurchase = cancelGaragePurchase
M.getGaragePrice = getGaragePrice
M.getGaragePurchasePrice = getGaragePurchasePrice

-- Real estate negotiation integration
M.completePurchaseWithNegotiatedPrice = completePurchaseWithNegotiatedPrice
M.purchaseGarageAtNegotiatedPrice = purchaseGarageAtNegotiatedPrice
M.freezeNegotiatedPrice = freezeNegotiatedPrice
M.requestGarageListing = requestGarageListing
M.getPendingGarageListing = getPendingGarageListing
M.startGarageNegotiation = startGarageNegotiation
M.purchaseGarageAtListedPrice = purchaseGarageAtListedPrice
M.canNegotiateGarage = canNegotiateGarage
M.setNegotiationCooldown = setNegotiationCooldown
M.canSellGarage = canSellGarage
M.listGarageForSale = listGarageForSale
M.listGarageForSaleByGarageId = listGarageForSaleByGarageId
M.sellGarage = sellGarage
M.completePropertySaleFromListing = completePropertySaleFromListing
M.getGarageListingPriceGuidance = getGarageListingPriceGuidance
M.getGarageListingPriceGuidanceByGarageId = getGarageListingPriceGuidanceByGarageId
M.getGarageActiveListing = getGarageActiveListing
M.removeGarageListing = removeGarageListing
M.startGarageSellingNegotiation = startGarageSellingNegotiation

local function getOwnedGaragesListingData()
  local result = {}
  local storedLocation = getStoredLocations()

  for garageId, owned in pairs(purchasedGarages) do
    if owned then
      local garage = freeroam_facilities.getFacility("garage", garageId)
      if not garage then goto continue end

      local capacity = math.ceil((garage.capacity or 0) / (career_modules_hardcore.isHardcoreMode() and 2 or 1))
      local vehiclesInGarage = storedLocation[garageId]
      local vehicleCount = vehiclesInGarage and #vehiclesInGarage or 0

      local preview = garage.preview or ""
      local computers = freeroam_facilities.getFacilitiesByType("computer")
      if computers then
        for _, comp in pairs(computers) do
          if comp.garageId == garageId and comp.preview then
            preview = comp.preview
            break
          end
        end
      end

      local name = garage.name or tostring(garageId)
      if translateLanguage then
        local translated = translateLanguage(garage.name, garage.name, true)
        if translated then name = translated end
      end

      local marketValue = garage.defaultPrice or 0
      if career_modules_globalEconomy and career_modules_globalEconomy.getHousingMarketIndex then
        marketValue = math.floor(marketValue * career_modules_globalEconomy.getHousingMarketIndex() + 0.5)
      end
      local isStarter = false
      if career_challengeModes and career_challengeModes.isChallengeActive() then
        local activeChallenge = career_challengeModes.getActiveChallenge()
        if activeChallenge and activeChallenge.startingGarages then
          for _, sgId in ipairs(activeChallenge.startingGarages) do
            if sgId == garageId then
              isStarter = true
              break
            end
          end
        end
      elseif garage.starterGarage then
        isStarter = true
      end
      local canSellInfo = canSellGarageByGarageId(garageId)
      local canSell = canSellInfo and canSellInfo[1] or false

      local listing = nil
      local offerCount = 0
      local askingPrice = nil
      if career_modules_realEstateNegotiation and career_modules_realEstateNegotiation.getPropertyListing then
        listing = career_modules_realEstateNegotiation.getPropertyListing(garageId)
        if listing then
          askingPrice = listing.askingPrice
          offerCount = listing.offers and #listing.offers or 0
        end
      end

      -- Find computerId for this garage
      local computerId = nil
      if computers then
        for _, comp in pairs(computers) do
          if comp.garageId == garageId then
            computerId = comp.id
            break
          end
        end
      end

      table.insert(result, {
        garageId = garageId,
        computerId = computerId,
        name = name,
        preview = preview,
        capacity = capacity,
        vehicleCount = vehicleCount,
        marketValue = marketValue,
        isStarter = isStarter,
        canSell = canSell,
        isListed = listing ~= nil,
        askingPrice = askingPrice,
        offerCount = offerCount,
        neighborhood = "West Coast",
      })
      ::continue::
    end
  end

  return result
end

local function getGarageOffersData(garageId)
  if not garageId then return nil end
  if not career_modules_realEstateNegotiation or not career_modules_realEstateNegotiation.getPropertyListing then
    return nil
  end

  local listing = career_modules_realEstateNegotiation.getPropertyListing(garageId)
  if not listing then return nil end

  local garage = freeroam_facilities.getFacility("garage", garageId)
  if not garage then return nil end

  local preview = garage.preview or ""
  local computers = freeroam_facilities.getFacilitiesByType("computer")
  if computers then
    for _, comp in pairs(computers) do
      if comp.garageId == garageId and comp.preview then
        preview = comp.preview
        break
      end
    end
  end

  local name = garage.name or tostring(garageId)
  if translateLanguage then
    local translated = translateLanguage(garage.name, garage.name, true)
    if translated then name = translated end
  end

  local marketValue = garage.defaultPrice or 0
  if career_modules_globalEconomy and career_modules_globalEconomy.getHousingMarketIndex then
    marketValue = math.floor(marketValue * career_modules_globalEconomy.getHousingMarketIndex() + 0.5)
  end

  local offers = {}
  if listing.offers then
    for i, offer in ipairs(listing.offers) do
      table.insert(offers, {
        index = i,
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

local function acceptOffer(garageId, offerIndex)
  if not garageId or not offerIndex then return false end
  if not career_modules_realEstateNegotiation then return false end

  local listing = career_modules_realEstateNegotiation.getPropertyListing(garageId)
  if not listing or not listing.offers then return false end

  local idx = tonumber(offerIndex)
  if not idx or idx < 1 or idx > #listing.offers then return false end

  local offer = listing.offers[idx]
  if not offer then return false end

  local salePrice = offer.negotiatedPrice or offer.value
  return completePropertySaleFromListing(garageId, salePrice, offer.buyerPersonality)
end

local function declineOffer(garageId, offerIndex)
  if not garageId or not offerIndex then return false end
  if not career_modules_realEstateNegotiation then return false end

  local listing = career_modules_realEstateNegotiation.getPropertyListing(garageId)
  if not listing or not listing.offers then return false end

  local idx = tonumber(offerIndex)
  if not idx or idx < 1 or idx > #listing.offers then return false end

  table.remove(listing.offers, idx)
  return true
end

M.getOwnedGaragesListingData = getOwnedGaragesListingData
M.getGarageOffersData = getGarageOffersData
M.acceptOffer = acceptOffer
M.declineOffer = declineOffer

M.getFreeSlots = getFreeSlots
M.onCareerModulesActivated = onCareerModulesActivated
M.onExtensionLoaded = onExtensionLoaded
M.isPurchasedGarage = isPurchasedGarage
M.isAccessibleGarage = isAccessibleGarage
M.getPurchasedGarages = getPurchasedGarages
M.addPurchasedGarage = addPurchasedGarage
M.addDiscoveredGarage = addDiscoveredGarage
M.isDiscoveredGarage = isDiscoveredGarage
M.loadPurchasedGarages = loadPurchasedGarages
M.savePurchasedGarages = savePurchasedGarages
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot
M.garageIdToName = garageIdToName
M.computerIdToGarageId = computerIdToGarageId

-- Localization
M.isGarageSpace = isGarageSpace
M.getNextAvailableSpace = getNextAvailableSpace
M.buildGarageSizes = buildGarageSizes
M.fillGarages = fillGarages
M.getStoredLocations = getStoredLocations
M.getGarageCapacityData = getGarageCapacityData
M.getVehiclesInGarage = getVehiclesInGarage
M.removePurchasedGarage = removePurchasedGarage
M.isGarageForSale = isGarageForSale
M.isStarterGaragePurchasable = isStarterGaragePurchasable

return M
