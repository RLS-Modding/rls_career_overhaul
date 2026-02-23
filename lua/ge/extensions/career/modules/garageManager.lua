local M = {}
M.dependencies = { 'career_career', 'career_saveSystem', 'freeroam_facilities', 'career_modules_realEstateNegotiation' }

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
  print("Saved Garage Data to: " .. dirPath .. "/" .. saveFile)
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

local function clearFrozenPrice(garageId)
  if garageId then
    frozenPrices[garageId] = nil
  end
end

local function onSaveCurrentSaveSlot(currentSavePath)
  -- This is the correct handler that will save to the new autosave
  print("Saving Garage Data to: " .. currentSavePath .. "/career/rls_career/" .. saveFile)
  savePurchasedGarages(currentSavePath)
  saveNegotiationCooldowns(currentSavePath)
end

local function isPurchasedGarage(garageId)
  return purchasedGarages[garageId] or false
end

local function isDiscoveredGarage(garageId)
  return discoveredGarages[garageId] or false
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
      if purchasedGarages[garage.id] then
        garageSize[tostring(garage.id)] = (math.ceil(garage.capacity / (career_modules_hardcore.isHardcoreMode() and 2 or 1)) or 0)
      end
    end
  end
end

local function addPurchasedGarage(garageId)
  if purchasedGarages == {} then
    print("Showing non-tutorial welcome splashscreen")
    career_modules_linearTutorial.showNonTutorialWelcomeSplashscreen()
  end
  print("Adding purchased garage: " .. garageId)
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

  if career_modules_hardcore.isHardcoreMode() then
    return garage.defaultPrice
  else
    if career_challengeModes and career_challengeModes.isChallengeActive() then
      local activeChallenge = career_challengeModes.getActiveChallenge()
      if activeChallenge and activeChallenge.startingGarages then
        return garage.defaultPrice
      end
    end

    if garage.starterGarage then return 0 end
    local price = garage.defaultPrice
    if career_modules_globalEconomy and career_modules_globalEconomy.getHousingMarketIndex then
      price = math.floor(price * career_modules_globalEconomy.getHousingMarketIndex() + 0.5)
    end
    return price
  end
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
local function getGaragePrice(garage)
  local garageId = type(garage) == "table" and garage.id or garage
  return calculateGaragePurchasePrice(garageId)
end

-- Complete purchase with negotiated price (called from realEstateNegotiation module)
local function completePurchaseWithNegotiatedPrice(garageId, finalPrice, freezePrice)
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
  
  setNegotiationCooldown(garageId)
  
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
  
  pendingGarageListingData = listingData
  
  -- Send data and change state with a small delay to ensure negotiation UI updates first
  guihooks.trigger('openGarageListing', listingData)
  
  core_jobsystem.create(function(job)
    job.sleep(0.2)
    guihooks.trigger('ChangeState', {state = 'garage-listing', params = {}})
  end)
  
  return true
end

local function purchaseGarageAtNegotiatedPrice(garageId)
  if not career_career.isActive() then 
    log("E", "garageManager", "purchaseGarageAtNegotiatedPrice: Career not active")
    return false 
  end
  
  if not garageId then
    log("E", "garageManager", "purchaseGarageAtNegotiatedPrice: Missing garageId")
    return false
  end
  
  local garage = freeroam_facilities.getFacility("garage", garageId)
  if not garage then
    log("E", "garageManager", "purchaseGarageAtNegotiatedPrice: Garage not found: " .. tostring(garageId))
    return false
  end
  
  local negotiatedPrice = getFrozenPrice(garageId)
  if not negotiatedPrice then
    log("E", "garageManager", "purchaseGarageAtNegotiatedPrice: No negotiated price found")
    return false
  end
  
  if not career_modules_payment then
    log("E", "garageManager", "purchaseGarageAtNegotiatedPrice: Payment module not loaded")
    return false
  end
  
  local price = { money = { amount = negotiatedPrice, canBeNegative = false } }
  local success = career_modules_payment.pay(price, { label = "Purchased " .. garage.name })
  if success then
    addPurchasedGarage(garage.id)
    clearFrozenPrice(garageId)
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
  
  return false
end

-- Request garage listing data for UI (with negotiation support)
requestGarageListing = function(garageId)
  if not career_career.isActive() then return nil end
  
  local garage = freeroam_facilities.getFacility("garage", garageId)
  if not garage then return nil end
  
  local listedPrice = getGaragePrice(garage)
  local canNegotiate = not garage.starterGarage and listedPrice > 0
  
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
  local effectivePrice = negotiatedPrice or listedPrice
  
  local closingFee = calculateClosingFee(effectivePrice)
  local propertyTax = calculateAnnualPropertyTax(effectivePrice)
  local estimatedTotal = effectivePrice + closingFee + propertyTax
  
  local canNegotiateNow, cooldownRemaining = canNegotiateGarage(garageId)
  canNegotiate = canNegotiate and canNegotiateNow

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
    neighborhood = "West Coast",  -- TODO: Get from propertyMarket when available
    canNegotiate = canNegotiate,
    cooldownRemaining = cooldownRemaining,
    isFrozen = negotiatedPrice ~= nil,
    starterGarage = garage.starterGarage or false,
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
local function purchaseGarageAtListedPrice(garageId)
  if not career_career.isActive() then 
    log("E", "garageManager", "purchaseGarageAtListedPrice: Career not active")
    return false 
  end
  
  if not garageId then
    log("E", "garageManager", "purchaseGarageAtListedPrice: Missing garageId")
    return false
  end
  
  local garage = freeroam_facilities.getFacility("garage", garageId)
  if not garage then
    log("E", "garageManager", "purchaseGarageAtListedPrice: Garage not found: " .. tostring(garageId))
    return false
  end
  
  local price = getGaragePrice(garage)
  if not price then
    log("E", "garageManager", "purchaseGarageAtListedPrice: Could not determine price for garage: " .. tostring(garageId))
    return false
  end
  
  -- Free garages (starter garages)
  if price == 0 then
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
  
  local priceTable = { money = { amount = price, canBeNegative = false } }
  local success = career_modules_payment.pay(priceTable, { label = "Purchased " .. garage.name })
  if success then
    addPurchasedGarage(garage.id)
    career_saveSystem.saveCurrent()
    guihooks.trigger('toastrMsg', {type="success", title="Property Purchased", msg="Welcome to your new garage!"})
    guihooks.trigger('ChangeState', {state = 'menu.career', params = {}})
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
  if not garageId or garageId == "" then return end
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

local function canPay()
  if career_modules_cheats and career_modules_cheats.isCheatsMode() then
    return true
  end
  if not garageToPurchase then return false end
  local price = { money = { amount = getGaragePrice(garageToPurchase), canBeNegative = false } }
  for currency, info in pairs(price) do
    if not info.canBeNegative and career_modules_playerAttributes.getAttributeValue(currency) < info.amount then
      return false
    end
  end
  return true
end

local function buyGarage()
  if garageToPurchase then
    local price = { money = { amount = getGaragePrice(garageToPurchase), canBeNegative = false } }
    local success = career_modules_payment.pay(price, { label = "Purchased " .. garageToPurchase.name })
    if success then
      addPurchasedGarage(garageToPurchase.id)
      career_saveSystem.saveCurrent()
    end
    garageToPurchase = nil
  end
end

local function cancelGaragePurchase()
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

local function getGarageCapacityData()
  buildGarageSizes()
  local storedLocation = getStoredLocations()
  local data = {}

  for garageId, owned in pairs(purchasedGarages) do
    if owned then
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
  if not garageSize[garage] then
    buildGarageSizes()
    if not garageSize[garage] then return {false, 0} end
  end -- No size for garage
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
    local space = isGarageSpace(garage)
    if space[1] then 
      totalCapacity = totalCapacity + space[2]
    end
    ::continue::
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
      
      local price = garage.starterGarage and 0 or garage.defaultPrice
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

local function canSellGarage(computerId)
  local garageId = computerIdToGarageId(computerId)
  if not garageId then
    return false
  end
  local garage = freeroam_facilities.getFacility("garage", garageId)
  if not garage then
    return false
  end
  
  if garage.starterGarage then
    return {false, 0}
  end
  
  if career_challengeModes and career_challengeModes.isChallengeActive() then
    local activeChallenge = career_challengeModes.getActiveChallenge()
    if activeChallenge and activeChallenge.startingGarages then
      for _, startingGarageId in ipairs(activeChallenge.startingGarages) do
        if startingGarageId == garageId then
          return {false, 0}
        end
      end
    end
  end
  
  local space = isGarageSpace(garageId)
  local capacity = math.ceil(garage.capacity / (career_modules_hardcore.isHardcoreMode() and 2 or 1))
  return {space[2] == capacity, capacity - space[2]}
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

  return career_modules_realEstateNegotiation.listPropertyForSale(garageId, desiredPrice)
end

local function sellGarage(computerId, sellPrice)
  -- Legacy API kept for compatibility: now routes to listing flow.
  return listGarageForSale(computerId, sellPrice)
end

local function completePropertySaleFromListing(garageId, finalPrice)
  if not career_career.isActive() then return false end
  if not garageId or not finalPrice then return false end

  local garage = freeroam_facilities.getFacility("garage", garageId)
  if not garage then return false end
  if not purchasedGarages[garageId] then return false end

  purchasedGarages[garageId] = nil
  reloadRecoveryPrompt()
  buildGarageSizes()

  local soldMessage = "Sold " .. (garage.name or tostring(garageId))
  career_modules_payment.reward({ money = { amount = finalPrice } }, { label = soldMessage }, true)

  if career_modules_realEstateNegotiation and career_modules_realEstateNegotiation.removePropertyListing then
    career_modules_realEstateNegotiation.removePropertyListing(garageId)
  end

  career_saveSystem.saveCurrent()
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
    if isGarageSpace(garage)[1] then 
      return garage
    end
    ::continue::
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
M.sellGarage = sellGarage
M.completePropertySaleFromListing = completePropertySaleFromListing
M.getGarageListingPriceGuidance = getGarageListingPriceGuidance
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

      local marketValue = calculateGaragePurchasePrice(garageId) or 0
      local isStarter = garage.starterGarage or false
      local canSell = not isStarter and vehicleCount == 0

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

  local marketValue = calculateGaragePurchasePrice(garageId) or 0

  local offers = {}
  if listing.offers then
    for i, offer in ipairs(listing.offers) do
      table.insert(offers, {
        index = i,
        value = offer.value,
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

  return completePropertySaleFromListing(garageId, offer.value)
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

return M
