-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local im = ui_imgui
local utils = require('gameplay/events/freeroam/utils')

local listedVehicles = {}
local interestedCustomers = {}
local globalVehicleData = {}
local lastOfferTime = {}
local offerInterval = {}

local timeBetweenOffersBase = 95
local offerTTL = 500
local offerTTLVariance = 0.5
local valueLossLimit = 0.95
local notifications = true

local offerMenuOpen = false

local function racesToLabels(races)
  local raceLabels = {}
  for id, race in pairs(races) do
    raceLabels[race.label] = {time = race.bestTime, types = race.type, driftScore = race.driftGoal}
    if race.hotlap then
      raceLabels[race.label .. " (Hotlap)"] = {time = race.hotlap, types = race.type, driftScore = race.driftGoal}
    end
    if race.altRoute then
      raceLabels[race.altRoute.label] = {time = race.altRoute.bestTime, types = race.type, driftScore = race.altRoute.driftGoal}
      if race.altRoute.hotlap then
        raceLabels[race.altRoute.label .. " (Hotlap)"] = {time = race.altRoute.hotlap, types = race.type, driftScore = race.altRoute.driftGoal}
      end
    end
  end
  return raceLabels
end

local function sumInterest(interestedCustomersList)
  local sum = 0
  for _, interest in ipairs(interestedCustomersList) do
    sum = sum + interest.interest
  end
  return sum
end

local function setOfferInterval(inventoryId)
  inventoryId = tonumber(inventoryId)
  lastOfferTime[inventoryId] = 0
  interestedCustomers[inventoryId] = M.getInterestedCustomers(inventoryId)
  local interestSum = sumInterest(interestedCustomers[inventoryId])
  local minInterval = 60 * (career_modules_hardcore.isHardcoreMode() and 2 or 1)
  local maxInterval = 450 * (career_modules_hardcore.isHardcoreMode() and 2 or 1)
  local maxInterestSum = 55

  local normalizedInterestSum = math.min(interestSum / maxInterestSum, 1)

  -- Inverse relationship: fewer customers = longer intervals
  local calculatedInterval = maxInterval - ((maxInterval - minInterval) * normalizedInterestSum)

  local intervalRandomness = 0.3
  local randomOffset = calculatedInterval * intervalRandomness * (2 * math.random() - 1)
  offerInterval[inventoryId] = math.min(maxInterval, math.max(minInterval, calculatedInterval + randomOffset))
end

local function getTableSize(t)
  local count = 0
  for _ in pairs(t) do
      count = count + 1
  end
  return count
end

local function FREtoPerformanceValue(raceLabels, FRETimes)
  local performanceValues = {}
  if not FRETimes then return {} end
  for label, time in pairs(FRETimes) do
    local raceDetails = raceLabels and raceLabels[label] or {}
    if not raceDetails or not raceDetails.types then goto continue end
    for _, type in ipairs(raceDetails.types) do
      if not performanceValues[type] then
        performanceValues[type] = {}
      end
      if type == "drift" then
        table.insert(performanceValues[type], {label = label, performance = time / raceDetails.driftScore})
      else
        table.insert(performanceValues[type], {label = label, performance = raceDetails.time / time})
      end
    end
    ::continue::
  end
  return performanceValues
end

local function getCompletions(raceLabels, FRECompletions)
  local completions = {}
  if not FRECompletions then return {} end
  for label, amount in pairs(FRECompletions) do
    local raceDetails = raceLabels and raceLabels[label] or {}
    if not raceDetails or not raceDetails.types then goto continue end
    for _, type in ipairs(raceDetails.types) do
      if not completions[type] then
        completions[type] = {}
      end
      table.insert(completions[type], {label = label, completions = amount.total, consecutive = amount.consecutive})
    end
    ::continue::
  end
  return completions
end

local function pullVehicleData(inventoryId)
  local veh = career_modules_inventory.getVehicles()[inventoryId]
  if not veh then return end
  
  local FRETimes = veh.FRETimes or {}
  local FRECompletions = veh.FRECompletions or {}
  local value = career_modules_valueCalculator.getInventoryVehicleValue(inventoryId)
  local power = 0
  local weight = 0
  local torque = 0
  local powerPerWeight = 0
  local mileage = (veh.mileage and veh.mileage or 0) / 1609.34

  if veh.certifications then
    power = string.format("%d", veh.certifications.power)
    weight = string.format("%d", veh.certifications.weight)
    torque = string.format("%d", veh.certifications.torque)
    powerPerWeight = string.format("%0.3f", power / weight)
  end

  local partInventory = career_modules_partInventory.getInventory()

  local newParts = {}
  -- Loop through partInventory to find parts belonging to this vehicle
  for _, part in pairs(partInventory) do
    if part.location == veh.id then
      newParts[part.containingSlot] = part.name
    end
  end
  local originalParts = veh.originalParts
  local changedSlots = veh.changedSlots

  local addedParts, removedParts = career_modules_valueCalculator.getPartDifference(originalParts, newParts, changedSlots)
  
  local races = utils.loadRaceData() or {}
  if races == {} then return end
  local raceLabels = racesToLabels(races)

  local vehicleData = {
    performanceValues = FREtoPerformanceValue(raceLabels, FRETimes),
    completions = getCompletions(raceLabels, FRECompletions),
    value = value or 0,
    power = power or 0,
    weight = weight or 0,
    torque = torque or 0,
    powerPerWeight = powerPerWeight or 0,
    mileage = mileage or 0,
    rep = veh.meetReputation or 0,
    year = veh.year or 0,
    arrests = veh.arrests or 0,
    tickets = veh.tickets or 0,
    evades = veh.evades or 0,
    accidents = veh.accidents or 0,
    movieRentals = veh.movieRentals or 0,
    repos = veh.repos or 0,
    taxiDropoffs = veh.taxiDropoffs or 0,
    deliveredItems = veh.deliveredItems or 0,
    suspectsCaught = veh.suspectsCaught or 0,
    FRETimes = FRETimes,
    numAddedParts = getTableSize(addedParts),
    numRemovedParts = getTableSize(removedParts),
    needsRepair = veh.needsRepair or false
  }

  globalVehicleData[inventoryId] = vehicleData
  return globalVehicleData[inventoryId]
end

local function getInterestedCustomers(inventoryId)
  local vehicleData = pullVehicleData(tonumber(inventoryId))
  return career_modules_marketplaceCustomers.getInterestedCustomers(vehicleData)
end

local function findVehicleListing(inventoryId)
  for _, listing in ipairs(listedVehicles) do
    if tonumber(listing.inventoryId) == tonumber(inventoryId) then
      return listing
    end
  end
end

local function listVehicles(vehicles)
  local timestamp = os.time()
  for _, inventoryId in ipairs(vehicles) do
    local veh = career_modules_inventory.getVehicles()[inventoryId]
    if veh and not findVehicleListing(inventoryId) then
      local vehicleData = pullVehicleData(inventoryId)
      local listingData = {
        id = veh.id,
        inventoryId = inventoryId,
        timestamp = timestamp,
        offers = {},
        value = career_modules_valueCalculator.getInventoryVehicleValue(inventoryId),
        timeOfNextOffer = nil,
        niceName = veh.niceName,
        thumbnail = career_modules_inventory.getVehicleThumbnail(inventoryId),
        vehicleData = vehicleData
      }
      table.insert(listedVehicles, listingData)
      setOfferInterval(inventoryId)
    end
  end
end

local function removeVehicleListing(inventoryId)
  for i, listing in ipairs(listedVehicles) do
    if tonumber(listing.id) == tonumber(inventoryId) then
      table.remove(listedVehicles, i)
      lastOfferTime[tonumber(inventoryId)] = nil
      offerInterval[tonumber(inventoryId)] = nil
      interestedCustomers[tonumber(inventoryId)] = nil
      globalVehicleData[tonumber(inventoryId)] = nil
      break
    end
  end
end

local function generateOfferAdvanced(inventoryId)
  inventoryId = tonumber(inventoryId)
  if not interestedCustomers[inventoryId] then
    interestedCustomers[inventoryId] = getInterestedCustomers(inventoryId)
  end
  local customerList = interestedCustomers[inventoryId]

  if not customerList or #customerList == 0 then
    return nil -- No interested customers
  end

  local selectedCustomerIndex = math.random(1, #customerList)
  local selectedCustomer = customerList[selectedCustomerIndex]

  local offerRange = selectedCustomer.offerRange
  local interest = selectedCustomer.interest

  -- Calculate offer price based on offer range and interest
  local range = offerRange.max - offerRange.min
  local interestFactor = interest -- Use interest directly as a factor
  local randomValue = math.random() -- Random value between 0 and 1
  local offerValue = offerRange.min + range * (randomValue * (1 - interestFactor) + interestFactor)

  if offerValue > 1 and career_modules_hardcore.isHardcoreMode() then
    offerValue = 1 + ((offerValue - 1) * 0.75)
  end

  -- Ensure offer is within range (though it should be already)
  offerValue = math.max(offerRange.min, math.min(offerRange.max, offerValue))

  -- Format the price to 2 decimal places (optional)
  offerValue = math.floor(offerValue * 100) / 100

  local vehicleValue = pullVehicleData(inventoryId).value

  local offer = {
    timestamp = os.time(),
    value = offerValue * vehicleValue,
    customer = selectedCustomer.name,
    ttl = offerTTL + ((math.random() * offerTTLVariance*2) - offerTTLVariance) * offerTTL
  }

  return offer
end

local function generateOffer(inventoryId)
  local listing = inventoryId and findVehicleListing(inventoryId) or listedVehicles[math.random(1, #listedVehicles)]
  
  -- Try advanced offer generation first
  local advancedOffer = generateOfferAdvanced(inventoryId or listing.id)
  if advancedOffer then
    return advancedOffer
  end
  
  -- Fallback to basic offer generation
  local offer = {
    timestamp = os.time(),
    value = round(listing.value * (biasGainFun(math.random(), 0.5, 0.03) * 0.5 + 0.73)),
    customer = "Generic Buyer",
    ttl = offerTTL + ((math.random() * offerTTLVariance*2) - offerTTLVariance) * offerTTL
  }
  return offer
end

local function acceptOffer(inventoryId, offerIndex)
  for i, listing in ipairs(listedVehicles) do
    if listing.id == inventoryId then
      local offer = listing.offers[offerIndex]
      if offer.expiredViewCounter then
        return -- Cannot accept expired offers
      end
      
      -- Try to sell the vehicle and check if it was successful
      local sellSuccess = career_modules_inventory.sellVehicle(inventoryId, offer.value)
      if sellSuccess then
        table.remove(listing.offers, offerIndex)
        Engine.Audio.playOnce('AudioGui','event:>UI>Career>Buy_01')
      else
        -- Vehicle couldn't be sold (e.g., it's being rented), show error message
        guihooks.trigger("toastrMsg", {type="error", title="Cannot sell vehicle", msg="This vehicle cannot be sold right now because it is currently being rented or is otherwise unavailable."})
      end
      return
    end
  end
end

local function deleteOffer(inventoryId, offerIndex)
  for i, listing in ipairs(listedVehicles) do
    if listing.id == inventoryId then
      table.remove(listing.offers, offerIndex)
      return
    end
  end
end

local function getOfferCount()
  local count = 0
  for _, listing in ipairs(listedVehicles) do
    count = count + #listing.offers
  end
  return count
end

local function updateListings()
  local timeNow = os.time()
  local offerCountDiff = 0

  for _, listing in ipairs(listedVehicles) do
    local inventoryId = listing.id
    
    if not listing.timeOfNextOffer then
      listing.timeOfNextOffer = timeNow + timeBetweenOffersBase + (math.random(-60, 60) / 100 * timeBetweenOffersBase)
    end

    if timeNow >= listing.timeOfNextOffer then
      listing.timeOfNextOffer = nil
      local offer = generateOffer(inventoryId)
      if offer then
        -- Check if customer already has an offer and replace it
        local existingOfferIndex = nil
        for i, existingOffer in ipairs(listing.offers) do
          if existingOffer.customer == offer.customer then
            existingOfferIndex = i
            break
          end
        end
        
        if existingOfferIndex then
          -- Replace existing offer and reset TTL
          listing.offers[existingOfferIndex] = offer
        else
          -- Add new offer
          table.insert(listing.offers, offer)
          offerCountDiff = offerCountDiff + 1
        end
        
        local offerValue = offer.value
        if notifications then
          local messageType = existingOfferIndex and "Updated offer" or "New offer"
          guihooks.trigger("toastrMsg", {type="info", title=messageType .. " for your listed vehicle", msg = listing.niceName .. ": $" .. string.format("%.2f", offerValue) .. " ( " .. (offerValue > listing.value and "+ " or "- ") .. string.format("%.2f", math.abs(offerValue - listing.value)) .. "$ )"})
        end
      end
    end

    -- Handle offer expiration and removal
    for offerIndex = #listing.offers, 1, -1 do
      local offer = listing.offers[offerIndex]
      local timeSinceOffer = timeNow - offer.timestamp
      local offerTTLToUse = offer.ttl or offerTTL
      
      if not offer.expiredViewCounter and timeSinceOffer > offerTTLToUse then
        offer.expiredViewCounter = 1
        offer.expiredAt = timeNow
        offerCountDiff = offerCountDiff - 1
      elseif offer.expiredViewCounter and offer.expiredAt then
        -- Remove expired offers after 5 minutes (300 seconds)
        local timeSinceExpired = timeNow - offer.expiredAt
        if timeSinceExpired > 300 then
          table.remove(listing.offers, offerIndex)
        end
      end
    end
  end

  return offerCountDiff
end

local timeSinceUpdate = 0
local function onUpdate(dtReal, dtSim, dtRaw)
  if tableIsEmpty(listedVehicles) or offerMenuOpen then
    return
  end

  timeSinceUpdate = timeSinceUpdate + dtSim
  if timeSinceUpdate < 10 then return end
  timeSinceUpdate = 0

  updateListings()
end

local function onVehicleRemoved(inventoryId)
  removeVehicleListing(inventoryId)
end

local function getListings()
  local listingsCopy = deepcopy(listedVehicles)
  for i, listing in ipairs(listingsCopy) do
    local currentValue = career_modules_valueCalculator.getInventoryVehicleValue(listing.id)
    if currentValue < listing.value * valueLossLimit then
      listing.disabled = true
      listing.disableReason = "Cant sell the vehicle because value has dropped below " .. valueLossLimit * 100 .. "% of the initial listing value"
    end

    -- Update vehicle data for enhanced listings
    listing.vehicleData = pullVehicleData(listing.id)

    for _, offer in ipairs(listing.offers) do
      if offer.expiredViewCounter then
        offer.disabled = true
        offer.disableReason = "Cant sell the vehicle because the offer has expired"
      end
    end
  end
  return listingsCopy
end

local function menuOpened(open)
  offerMenuOpen = open

  -- generate offers as if they have been generated while the menu was closed
  if open then
    for i, listing in ipairs(listedVehicles) do
      for offerIndex = #listing.offers, 1, -1 do
        local offer = listing.offers[offerIndex]
        if offer.expiredViewCounter then
          offer.expiredViewCounter = offer.expiredViewCounter + 1
          if offer.expiredViewCounter > 3 then
            table.remove(listing.offers, offerIndex)
          end
        end
      end
    end
  else
    local offerCountDiff = updateListings()
    if offerCountDiff < 0 then
      for i = 1, math.abs(offerCountDiff) do
        local offer = generateOffer()
        -- randomize the offer timestamp
        if offer then
          offer.timestamp = offer.timestamp + math.random(1, offerTTL)
        end
      end
    end
  end
end

local function openMenu(computerId)
  career_modules_vehicleShopping.openShop(nil, computerId, "marketplace")
end

local function toggleNotifications(newValue)
  notifications = newValue
end

local function onSaveCurrentSaveSlot(currentSavePath, oldSaveDate, vehiclesThumbnailUpdate)
  career_saveSystem.jsonWriteFileSafe(currentSavePath .. "/career/marketplace.json", {
    listedVehicles = listedVehicles,
    notifications = notifications
  }, true)
end

local function onExtensionLoaded()
  if not career_career.isActive() then return false end

  local saveSlot, savePath = career_saveSystem.getCurrentSaveSlot()
  if not saveSlot or not savePath then return end

  local data = jsonReadFile(savePath .. "/career/marketplace.json")
  if data then
    listedVehicles = data.listedVehicles or {}
    notifications = data.notifications or true
    
    -- Initialize advanced data for existing listings
    for _, listing in ipairs(listedVehicles) do
      setOfferInterval(listing.id)
    end
  end
end

M.onUpdate = onUpdate
M.onVehicleRemoved = onVehicleRemoved
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot
M.onExtensionLoaded = onExtensionLoaded

M.getListings = getListings
M.menuOpened = menuOpened
M.acceptOffer = acceptOffer
M.declineOffer = deleteOffer
M.listVehicles = listVehicles
M.findVehicleListing = findVehicleListing
M.openMenu = openMenu
M.removeVehicleListing = removeVehicleListing
M.generateOffer = generateOffer
M.toggleNotifications = toggleNotifications
M.pullVehicleData = pullVehicleData
M.getInterestedCustomers = getInterestedCustomers
M.racesToLabels = racesToLabels

return M