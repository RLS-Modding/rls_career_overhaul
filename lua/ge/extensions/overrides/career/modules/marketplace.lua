-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local im = ui_imgui

local listedVehicles = {}

local timeBetweenOffersBase = 95
local offerTTL = 500
local offerTTLVariance = 0.5
local valueLossLimit = 0.95
local maximumExpiredOffers = 10

local offerMenuOpen = false

local function findVehicleListing(inventoryId)
  for _, listing in ipairs(listedVehicles) do
    if listing.id == inventoryId then
      return listing
    end
  end
end

local function listVehicles(vehicles)
  local timestamp = os.time()
  for _, entry in ipairs(vehicles) do
    local inventoryId = entry.inventoryId
    local customValue = entry.value
    local veh = career_modules_inventory.getVehicles()[inventoryId]
    if veh and not findVehicleListing(inventoryId) then
      local value = customValue or career_modules_valueCalculator.getInventoryVehicleValue(inventoryId)
      local marketValue = career_modules_valueCalculator.getInventoryVehicleValue(inventoryId)
      local marketRatio = value / (marketValue or 1)

      local offerTimeMultiplier = 1
      if marketRatio >= 0.98 and marketRatio <= 1.1 then
        offerTimeMultiplier = 1
      elseif marketRatio < 0.98 then
        -- Lerp from 1 to 0.4 as ratio goes from 0.98 to 0.85
        local t = math.max(0, math.min(1, inverseLerp(0.98, 0.85, marketRatio)))
        offerTimeMultiplier = lerp(1, 0.4, t)
      elseif marketRatio > 1.1 then
        -- Lerp from 1 to 4.0 as ratio goes from 1.1 to 1.5
        local t = math.max(0, math.min(1, inverseLerp(1.1, 1.5, marketRatio)))
        offerTimeMultiplier = lerp(1, 4.0, t)
      end

      local listingData = {
        id = veh.id,
        timestamp = timestamp,
        offers = {},
        value = value,
        marketValue = marketValue,
        marketRatio = marketRatio,
        timeOfNextOffer = nil,
        offerTimeMultiplier = offerTimeMultiplier,
        niceName = veh.niceName,
        thumbnail = career_modules_inventory.getVehicleThumbnail(inventoryId),
      }
      table.insert(listedVehicles, listingData)
    end
  end
end

local function removeVehicleListing(inventoryId)
  for i, listing in ipairs(listedVehicles) do
    if listing.id == inventoryId then
      table.remove(listedVehicles, i)
    end
  end
end

local function generatePersonality(buyer, _archetypes)
  local data = jsonReadFile("levels/west_coast_usa/facilities/negotiationPersonalities.json")
  if not data then return end

  local archetypeKeys = _archetypes
  if not archetypeKeys then
    archetypeKeys = buyer and data.randomBuyerArchetypes or data.randomSellerArchetypes
  end
  if #archetypeKeys == 0 then return end

  local chosenKey = archetypeKeys[math.random(1, #archetypeKeys)]
  local chosenArchetype = data.archetypes[chosenKey] or {}

  local delayRange
  local name
  if chosenArchetype.isDealership then
    name = chosenArchetype.names[math.random(1, #chosenArchetype.names)]
  else
    name = M.firstNames[math.random(1, M.firstNameCount)] -- first name
    if math.random() < 0.01 then
      if math.random() < 0.5 then
        name = name .. " " .. M.initials[math.random(1, M.initialCount)] -- low chance of adding an initial
      else
        name = name .. "-" .. M.firstNames[math.random(1, M.firstNameCount)] -- low chance of adding a hyphen and a new first name
      end
    end
    name = name .. " " .. M.initials[math.random(1, M.initialCount)] .. "." -- add an initial for the last name and a period
  end



  local dr = chosenArchetype.delayRange
  if type(dr) == "table" and dr[1] and dr[2] then
    delayRange = { min = dr[1], max = dr[2] }
  end
  delayRange = delayRange or { min = 3, max = 4 }



  local priceMultiplier
  if buyer then
    priceMultiplier = 1 - (chosenArchetype.priceMultiplier or 0.1)
  else
    priceMultiplier = 1 + (chosenArchetype.priceMultiplier or 0.1)
  end

  return {
    archetype = chosenKey,
    counterOfferReadiness = chosenArchetype.counterOfferReadiness or 0.5,
    offerAcceptanceThreshold = chosenArchetype.offerAcceptanceThreshold or 0.1,
    unpredictability = chosenArchetype.unpredictability or 0.02,
    priceMultiplier = priceMultiplier,
    delayRange = delayRange,
    name = name,
    quotesByPriceTier = chosenArchetype.quotesByPriceTier,

    -- dealership specific negotiation parameters
    isDealership = chosenArchetype.isDealership,
    minimumOverMarket = chosenArchetype.minimumOverMarket,
    desperation = chosenArchetype.desperation,
    desperationMaxDiscount = chosenArchetype.desperationMaxDiscount,
    insultThresholdBase = chosenArchetype.insultThresholdBase,
    insultThresholdVariance = chosenArchetype.insultThresholdVariance,
    insultQuotes = chosenArchetype.insultQuotes,
    happyQuotes = chosenArchetype.happyQuotes,
    startingPatience = chosenArchetype.startingPatience,
    patienceVariance = chosenArchetype.patienceVariance
  }
end

local function generateOffer(inventoryId)
  local listing = inventoryId and findVehicleListing(inventoryId) or listedVehicles[math.random(1, #listedVehicles)]
  local buyerPersonality = generatePersonality(true)
  local marketRatio = listing.marketRatio or (listing.value / (listing.marketValue or 1))

  local baseOffer = listing.marketValue

  local personalityMult = buyerPersonality.priceMultiplier or 1.0
  local noise = (biasGainFun(math.random(), 0.5, 0.03) * 0.5) + 0.73
  local finalOfferValue = baseOffer * personalityMult * noise

  --log("I","",string.format("Generating offer for %s with market ratio %0.2f (%.2f / %.2f)", listing.niceName, marketRatio, listing.value, listing.marketValue))
  --log("I","",string.format(" Base offer: %.2f. Personality multiplier: %.2f. Noise: %.4f. Final offer: %.2f.", baseOffer, personalityMult, noise, finalOfferValue))

  if marketRatio < 0.9 then
    local cap = listing.value * (1.05 + (math.random() * 0.1))
    finalOfferValue = math.min(finalOfferValue, cap)
    --log("I","",string.format(" Market ratio is less than 0.9, capping offer at %.2f", cap))
    --if finalOfferValue == cap then
      --log("I","","  clamp to cap")
    --end
  elseif marketRatio > 1.1 then
    local cap = listing.marketValue * (0.95 + (math.random() * 0.1))
    finalOfferValue = math.min(finalOfferValue, cap)
    --log("I","",string.format(" Market ratio is greater than 1.1, capping offer at %.2f", cap))
    --if finalOfferValue == cap then
      --log("I","","  clamp to cap")
    --end
  end

  local offer = {
    timestamp = os.time(),
    value = math.max(50, math.floor((finalOfferValue + 25) / 50) * 50),
    ttl = offerTTL + ((math.random() * offerTTLVariance*2) - offerTTLVariance) * offerTTL,
    negotiationPossible = true,
    buyerPersonality = buyerPersonality
  }
  --log("I","",string.format(" Final offer: %.2f", offer.value))
  table.insert(listing.offers, offer)
  return offer
end

local function acceptOffer(inventoryId, offerIndex)
  for i, listing in ipairs(listedVehicles) do
    if listing.id == inventoryId then
      local offer = listing.offers[offerIndex]
      table.remove(listing.offers, offerIndex)
      career_modules_inventory.sellVehicle(inventoryId, offer.value)
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

local function generateNewOffers()
  local timeNow = os.time()
  local offerCountDiff = 0

  for _, listing in ipairs(listedVehicles) do
    if not listing.timeOfNextOffer then
      local multiplier = listing.offerTimeMultiplier or 1
      listing.timeOfNextOffer = timeNow + (timeBetweenOffersBase * multiplier) + (math.random(-60, 60) / 100 * timeBetweenOffersBase * multiplier)
    end

    if timeNow >= listing.timeOfNextOffer then
      listing.timeOfNextOffer = nil
      generateOffer(listing.id)
      local offerValue = listing.offers[#listing.offers].value
      guihooks.trigger("toastrMsg", {type="info", title="New offer for your listed vehicle", msg = listing.niceName .. ": $" .. string.format("%.2f", offerValue) .. " ( " .. (offerValue > listing.value and "+ " or "- ") .. string.format("%.2f", math.abs(offerValue - listing.value)) .. "$ )"})
      offerCountDiff = offerCountDiff + 1
    end

    local expiredOffersCount = 0
    for offerIndex = #listing.offers, 1, -1 do
      local offer = listing.offers[offerIndex]
      if not offer.expiredViewCounter and timeNow - offer.timestamp > (offer.ttl or offerTTL) then
        offer.expiredViewCounter = 0
        offerCountDiff = offerCountDiff - 1
      end

      if offer.expiredViewCounter then
        expiredOffersCount = expiredOffersCount + 1
        if expiredOffersCount > maximumExpiredOffers then
          table.remove(listing.offers, offerIndex)
        end
      end
    end
  end

  return offerCountDiff
end

-- negotiation variables
local negotiationActive = false
local startingPrice
local patience = 1
local isInsulted = false
local myOffer
local theirOffer
local offerHistory = {}
local amISelling
local negotiationStatus
local vehicleNiceName
local vehicleThumbnail
local vehicleMileage
local actualVehicleValue
local isDesperate = false  -- Determined once at negotiation start (for dealerships)
local insultThreshold = 0.75  -- Determined once at negotiation start (varies per negotiation)
local opponentQuote = ""

-- selling
local negotiationInventoryId
local negotiationOfferIndex

-- buying
local shopId

-- opponent variables
local opponentPersonality = nil  -- Store the full personality object

-- UI bridge helpers for negotiation -----------------------------------------
local function getNegotiationState()
  return {
    active = negotiationActive,
    amISelling = amISelling,
    startingPrice = startingPrice,
    patience = patience,
    myOffer = myOffer,
    theirOffer = theirOffer,
    status = negotiationStatus,
    opponentName = opponentPersonality.name,
    opponentQuote = opponentQuote,
    vehicleNiceName = vehicleNiceName,
    vehicleThumbnail = vehicleThumbnail,
    vehicleMileage = vehicleMileage,
    actualVehicleValue = actualVehicleValue,
    negotiationStatus = negotiationStatus,
    offerHistory = offerHistory
  }
end

local function selectQuoteForPersonality(personality, vehicleValue, isBuyer)
  if not personality then
    return ""
  end

  -- Determine price tier based on dealership-specific thresholds or fallback to defaults
  local priceTier = "low"

  if personality.priceTierThresholds then
    -- Use dealership-specific thresholds
    if vehicleValue >= personality.priceTierThresholds.mid then
      priceTier = "high"
    elseif vehicleValue >= personality.priceTierThresholds.low then
      priceTier = "mid"
    end
  else
    -- Fallback to static thresholds for private sellers
    if vehicleValue >= 15000 then
      priceTier = "high"
    elseif vehicleValue >= 5000 then
      priceTier = "mid"
    end
  end

  -- Get appropriate quotes
  -- default quotes are from personality, but private is always buyer and dealership is always seller
  local quotes = nil
  if personality.quotesByPriceTier and type(personality.quotesByPriceTier) == "table" then
    quotes = personality.quotesByPriceTier[priceTier]
  end

  -- override quotes for private sellers and dealership buyers
  if not isBuyer and not personality.isDealership then
    quotes = M.privateSellerQuotes
  end
  if isBuyer and personality.isDealership then
    quotes = M.dealershipBuyerQuotes
  end

  -- Fallback for dealership sellers when quotesByPriceTier is missing
  if not quotes and not isBuyer and personality.isDealership then
    -- Use generic dealership seller quotes as fallback
    quotes = {
      "We're here to work with you on this vehicle.",
      "Let me see what I can do for you.",
      "I think we can find a price that works for both of us.",
      "We want to make this work for you.",
      "Let's see if we can reach an agreement."
    }
  end

  -- Return random quote from pool
  if quotes and type(quotes) == "table" and #quotes > 0 then
    local selectedQuote = quotes[math.random(1, #quotes)]
    return selectedQuote
  end

  -- Final fallback
  return isBuyer and "I'm interested in this vehicle." or "Thanks for your interest."
end

local function startNegotiateBuyingOffer(inventoryId, offerIndex)
  local listing = findVehicleListing(inventoryId)
  local offer = listing.offers[offerIndex]
  local buyerPersonality = offer.buyerPersonality

  opponentPersonality = buyerPersonality  -- Store full personality object

  if opponentPersonality.isDealership then
    local desperation = opponentPersonality.desperation or 0.15
    isDesperate = math.random() < desperation

    -- Roll insult threshold once per negotiation (varies per negotiation)
    local baseThreshold = opponentPersonality.insultThresholdBase or 0.75
    local variance = opponentPersonality.insultThresholdVariance or 0.05
    insultThreshold = baseThreshold + (math.random() * variance * 2 - variance)
  else
    isDesperate = false
    insultThreshold = 0.75
  end

  -- select quote based on personality and vehicle value
  opponentQuote = selectQuoteForPersonality(opponentPersonality, listing.value, true)

  negotiationInventoryId = inventoryId
  negotiationOfferIndex = offerIndex
  vehicleNiceName = listing.niceName
  vehicleThumbnail = listing.thumbnail
  vehicleMileage = career_modules_valueCalculator.getVehicleMileageById(inventoryId)
  actualVehicleValue = career_modules_valueCalculator.getInventoryVehicleValue(inventoryId)
  startingPrice = listing.value
  negotiationActive = true
  patience = 1
  isInsulted = false
  theirOffer = offer.value
  myOffer = listing.value
  amISelling = true
  negotiationStatus = "initial"
  offerHistory = {
    {
      myOffer = startingPrice,
      negotiationStatus = "initial"
    },
    {
      theirOffer = offer.value,
      negotiationStatus = "initial"
    }
  }

  guihooks.trigger('ChangeState', {state = 'negotiation', params = {}})
end

local function startNegotiateSellingOffer(_shopId)
  shopId = _shopId
  local vehicleInfo = career_modules_vehicleShopping.getVehicleInfoByShopId(shopId)
  local sellerPersonality = vehicleInfo.negotiationPersonality

  opponentPersonality = sellerPersonality  -- Store full personality object

  -- Determine desperation once at negotiation start (for dealerships only)
  if opponentPersonality.isDealership then
    local desperation = opponentPersonality.desperation or 0.15
    isDesperate = math.random() < desperation

    -- Roll insult threshold once per negotiation (varies per negotiation)
    local baseThreshold = opponentPersonality.insultThresholdBase or 0.75
    local variance = opponentPersonality.insultThresholdVariance or 0.05
    insultThreshold = baseThreshold + (math.random() * variance * 2 - variance)
  else
    isDesperate = false
    insultThreshold = 0.75
  end

  -- select quote based on personality and vehicle value
  opponentQuote = selectQuoteForPersonality(opponentPersonality, vehicleInfo.Value, false)

  negotiationInventoryId = nil
  negotiationOfferIndex = nil
  vehicleNiceName = vehicleInfo.Name
  vehicleThumbnail = vehicleInfo.preview
  vehicleMileage = vehicleInfo.Mileage
  actualVehicleValue = vehicleInfo.marketValue or vehicleInfo.Value
  startingPrice = vehicleInfo.Value
  negotiationActive = true
  theirOffer = startingPrice
  isInsulted = false
  myOffer = nil
  amISelling = false
  negotiationStatus = "initial"
  offerHistory = {
    {
      theirOffer = startingPrice,
      negotiationStatus = negotiationStatus
    }
  }

  -- Initialize patience based on personality (with some randomness)
  local basePatience = opponentPersonality.startingPatience or 1.0
  local patienceVariance = opponentPersonality.patienceVariance or 0.1
  patience = math.max(0.2, math.min(1.0, basePatience + (math.random() * patienceVariance * 2 - patienceVariance)))

  guihooks.trigger('ChangeState', {state = 'negotiation', params = {}})
end

local function cancelNegotiation()
  negotiationActive = false
  negotiationStatus = "failed"

  -- mark the offer as not negotiable if we made an offer and cancelled
  if myOffer then
    if amISelling then
      local listing = findVehicleListing(negotiationInventoryId)
      listing.offers[negotiationOfferIndex].negotiationPossible = false
    else
      local vehicleInfo = career_modules_vehicleShopping.getVehicleInfoByShopId(shopId)
      vehicleInfo.negotiationPossible = false
    end
  end
end

local function isOfferAllowed(price)
  if amISelling then
    return price > theirOffer and (not myOffer or price <= myOffer)
  else
    return price < theirOffer and price >= (myOffer or 0)
  end
end

local function calculatePatienceDrop(baseValue)
  local patienceDrop = 0

  if amISelling then
    -- When you're selling TO them

    local theirOfferAmount = theirOffer or baseValue
    local gapFromTheirOffer = math.abs(myOffer - theirOfferAmount)
    local gapFromMarket = math.abs(myOffer - baseValue)

    -- Dealerships focus on their offer, individuals consider market value
    local referenceGap = opponentPersonality.isDealership and gapFromTheirOffer or gapFromMarket
    local referenceValue = opponentPersonality.isDealership and theirOfferAmount or baseValue
    local gapPct = (referenceGap / referenceValue) * 100

    -- Price scaling: expensive items use percentage more, cheap items use absolute more
    local priceScale = math.min(1, referenceValue / 1000)
    local percentageWeight = priceScale
    local absoluteWeight = 1 - priceScale

    local percentagePatienceDrop = gapPct * 3
    local absolutePatienceDrop = (referenceGap / 100) * 8

    -- Dealerships lose patience slower (they're professionals)
    local dealershipModifier = opponentPersonality.isDealership and 0.6 or 1.0

    patienceDrop = ((percentagePatienceDrop * percentageWeight + absolutePatienceDrop * absoluteWeight) * dealershipModifier) + math.random() * 12

  else
    -- When you're buying FROM them
    local theirAskingPrice = theirOffer or baseValue
    local gapFromTheirPrice = math.abs(myOffer - theirAskingPrice)
    local gapFromMarket = math.abs(myOffer - baseValue)

    local referenceGap, referenceValue
    if opponentPersonality.isDealership then

      local minimumAcceptableOffer = math.min(startingPrice * insultThreshold, baseValue * 0.9)-- Only insult if: below threshold AND not near market value
      if myOffer < minimumAcceptableOffer then
        isInsulted = true
        return 1 --insulted
      end

      -- Dealerships: gap from their asking price matters most
      referenceGap = gapFromTheirPrice
      referenceValue = theirAskingPrice
    else
      -- Individuals: if your offer is near/above market, they shouldn't lose patience as quickly
      if myOffer >= baseValue * 0.9 then
        referenceGap = gapFromTheirPrice * 0.5  -- 50% less patience penalty
        referenceValue = theirAskingPrice
      else
        referenceGap = gapFromMarket
        referenceValue = baseValue
      end
    end

    local gapPct = (referenceGap / referenceValue) * 100

    -- Price scaling
    local priceScale = math.min(1, referenceValue / 1000)
    local percentageWeight = priceScale
    local absoluteWeight = 1 - priceScale

    local percentagePatienceDrop = gapPct * 2.5
    local absolutePatienceDrop = (referenceGap / 100) * 6

    -- Dealerships lose patience slower
    local dealershipModifier = opponentPersonality.isDealership and 0.6 or 1.0

    patienceDrop = ((percentagePatienceDrop * percentageWeight + absolutePatienceDrop * absoluteWeight) * dealershipModifier) + math.random() * 10
  end

  return patienceDrop / 100  -- Convert to 0-1 scale for patience
end

local function generateCounterOffer()
  local diff = theirOffer - myOffer
  local weight = 0.3 + math.random() * 0.4  -- 30-70% of gap

  if amISelling then
    -- Player is selling, opponent (buyer) moves their offer up
    local currentBuyerPosition = theirOffer
    local movement = math.abs(diff) * weight
    local result = currentBuyerPosition + movement
    return math.max(theirOffer, math.floor(result / 50 + 0.5) * 50)  -- Round to nearest $50
  else
    -- Player is buying, opponent (seller) moves their price down
    local currentSellerPosition = theirOffer
    local movement = math.abs(diff) * weight
    local result = currentSellerPosition - movement
    return math.max(myOffer, math.floor(result / 50 + 0.5) * 50)  -- Round to nearest $50
  end
end

local function makeOffer(price)
  if not isOfferAllowed(price) then return false end

  myOffer = price
  table.insert(offerHistory, {
    myOffer = myOffer
  })
  local baseValue = actualVehicleValue or startingPrice

  negotiationStatus = "thinking"
  guihooks.trigger('negotiationData', getNegotiationState())
  core_jobsystem.create(function(job)
    -- Use advanced patience calculation
    local patienceChange = calculatePatienceDrop(baseValue)

    -- Smart delay: dealer thinks longer about offers far from their expectations
    local thinkingTime = 5.5  -- Base delay

    if opponentPersonality.isDealership then
      -- Compare player offer to both market value AND asking price
      local marketGap = math.abs(myOffer - baseValue) / baseValue  -- How far from market value
      local askingGap = math.abs(myOffer - startingPrice) / startingPrice  -- How far from asking price

      -- If offer is close to market (good for player) but far from asking (bad for dealer)
      -- = dealer needs to think about this carefully
      if marketGap < 0.15 and askingGap > 0.20 then
        thinkingTime = 2.5 + math.random() * 1.5  -- 2.5-4 seconds (considering it)
      elseif askingGap > 0.30 then
        thinkingTime = 1.0 + math.random() * 0.8  -- 1-1.8 seconds (quick rejection/counter)
      elseif marketGap < 0.10 then
        thinkingTime = 2.0 + math.random() * 1.0  -- 2-3 seconds (fair offer, calculating)
      else
        thinkingTime = 1.5 + math.random() * 1.0  -- 1.5-2.5 seconds (normal)
      end
    else
      -- Private individuals are less calculating
      thinkingTime = 2.0 + math.random() * 2.0  -- 2-4 seconds
    end
    if patience <= 0 then
      thinkingTime = 0.5
    end

    thinkingTime = thinkingTime/2 + 1
    log('I', 'marketplace', string.format('thinking on offer %d for %0.1fs...', myOffer, thinkingTime))

    job.sleep(thinkingTime)
    negotiationStatus = "typing"
    guihooks.trigger('negotiationData', getNegotiationState())
    log('I', 'marketplace', string.format('typing for %0.1fs...', thinkingTime))


    job.sleep(thinkingTime) -- typing time
    patience = math.max(0, patience - patienceChange)

    -- ========================================================================
    -- DEALERSHIP BEHAVIOR: Each dealer has their own minimum over market value
    -- Dealerships ALWAYS negotiate - they never accept first offer, even if it's good!
    -- They only give "final offer" when patience is low, but they NEVER walk away
    -- 15% chance they'll go lower (desperation - need to move the car)
    -- ========================================================================
    if opponentPersonality.isDealership then
      -- Get personality-specific minimum over market value (use opponentPersonality which works for both buy/sell)
      local minimumOverMarket = opponentPersonality.minimumOverMarket or 200  -- Default $200
      local desperationMaxDiscount = opponentPersonality.desperationMaxDiscount or 0.35  -- Default 35% below market

      -- Calculate absolute floor (won't go below this no matter what)
      local absoluteMinimum
      if isDesperate then
        -- Desperate - absolute floor can be up to 35% below market
        absoluteMinimum = baseValue * (1 - desperationMaxDiscount)
      else
        -- Normal - absolute floor is minimum over market
        absoluteMinimum = baseValue + minimumOverMarket
      end

      -- Patience affects acceptable range:
      -- High patience = willing to negotiate, can move far from asking (wide range)
      -- Low patience = stubborn, won't move far from asking (narrow range)
      local negotiationRange = startingPrice - absoluteMinimum
      local patienceMultiplier = patience * 0.8  -- High patience = 80% of range, low = small range
      local willingToNegotiate = negotiationRange * patienceMultiplier
      local minAcceptable = startingPrice - willingToNegotiate
      local theirOfferCandidate

      if not amISelling then
        -- Dealership selling to player
        if isInsulted then
          -- they are insulted
          local insultQuotes = opponentPersonality.insultQuotes
          if insultQuotes and type(insultQuotes) == "table" and #insultQuotes > 0 then
            opponentQuote = insultQuotes[math.random(1, #insultQuotes)]
          else
            opponentQuote = "That's funny, do you have a real offer?"
          end

        elseif patience <= 0.40 then
          -- Low patience - jump straight to floor
          theirOfferCandidate = math.floor(minAcceptable / 50 + 0.5) * 50
        elseif myOffer >= minAcceptable then
          -- Within acceptable range - but dealerships ALWAYS try to counter first!
          local gapToClose = theirOffer - myOffer

          -- Make sure gap is positive (we're above their last position)
          if gapToClose > 0 then
            -- High patience = willing to negotiate slowly (small moves, trying to maximize)
            -- Low patience = make bigger jumps (less interested in drawn-out negotiation)
            local baseMovePercent = (1 - patience) * 0.4 + 0.25  -- High patience (1.0) = 25%, low (0.2) = 57%
            local movePercent = baseMovePercent + (math.random() * 0.15 - 0.075)  -- ±7.5% randomness
            movePercent = math.max(0.15, math.min(0.75, movePercent))  -- Clamp to reasonable range
            local counterAmount = myOffer + (gapToClose * movePercent)
            theirOfferCandidate = math.min(math.max(myOffer, math.floor(counterAmount / 50 + 0.5) * 50), theirOffer)
          else
            -- Player's offer is already at or above our position - accept!
            theirOfferCandidate = myOffer
          end
        else
          -- Below acceptable range, but still negotiating
          local gapToClose = theirOffer - myOffer
          -- High patience = smaller moves (dragging it out), low patience = bigger jumps
          local baseMovePercent = (1 - patience) * 0.4 + 0.25  -- High patience = 25%, low = 57%
          local movePercent = baseMovePercent + (math.random() * 0.15 - 0.075)  -- ±7.5% randomness
          movePercent = math.max(0.15, math.min(0.75, movePercent))
          local counterAmount = myOffer + (gapToClose * movePercent)
          theirOfferCandidate = math.max(minAcceptable, math.floor(counterAmount / 50 + 0.5) * 50)
        end

        if patience <= 0 then
          negotiationStatus = "failed"
          theirOffer = startingPrice
        elseif theirOfferCandidate <= myOffer then
          theirOffer = myOffer
          negotiationStatus = "accepted"

          -- Check if player paid more than dealer expected (happy dealer!)
          if myOffer > (minAcceptable * 1.10) then
            local happyQuotes = opponentPersonality.happyQuotes
            if happyQuotes and type(happyQuotes) == "table" and #happyQuotes > 0 then
              opponentQuote = happyQuotes[math.random(1, #happyQuotes)]
            end
          end
        else
          if theirOfferCandidate >= theirOffer then
            negotiationStatus = "refused"
          else
            theirOffer = theirOfferCandidate
            if patience <= 0.05 then
              negotiationStatus = "counterOfferLastChance"
              opponentQuote = "That's it! Take it or leave it."
            else
              negotiationStatus = "counterOffer"
            end
          end
        end
      else
        -- Dealership buying from player
        -- When buying, they're more conservative - only willing to pay 5% more per negotiation round
        local maxAcceptable = startingPrice * 1.05  -- Willing to go up to 5% higher

        if patience <= 0.40 then
          theirOfferCandidate = math.floor(maxAcceptable / 50 + 0.5) * 50
        elseif myOffer <= maxAcceptable then
          -- Within acceptable range for this round
          local gapToClose = myOffer - theirOffer
          -- High patience = smaller moves (trying to pay less), low patience = bigger jumps
          local baseMovePercent = (1 - patience) * 0.4 + 0.25  -- High patience = 25%, low = 57%
          local movePercent = baseMovePercent + (math.random() * 0.15 - 0.075)  -- ±7.5% randomness
          movePercent = math.max(0.15, math.min(0.75, movePercent))
          local counterAmount = theirOffer + (gapToClose * movePercent)
          theirOfferCandidate = math.min(myOffer, math.floor(counterAmount / 50 + 0.5) * 50)
        else
          -- Ask is too high, but still willing to negotiate
          local gapToClose = myOffer - theirOffer
          -- Move slower when ask is above acceptable range
          local baseMovePercent = ((1 - patience) * 0.4 + 0.25) * 0.5  -- Half speed when asking too much
          local movePercent = baseMovePercent + (math.random() * 0.1 - 0.05)  -- ±5% randomness (smaller here)
          movePercent = math.max(0.10, math.min(0.50, movePercent))
          local counterAmount = theirOffer + (gapToClose * movePercent)
          theirOfferCandidate = math.min(maxAcceptable, math.floor(counterAmount / 50 + 0.5) * 50)
        end

        theirOfferCandidate = math.max(theirOfferCandidate, theirOffer)
        if theirOfferCandidate >= myOffer then
          -- Our counter would be at/above their ask - accept it
          theirOffer = myOffer
          negotiationStatus = "accepted"
        else
          if theirOfferCandidate <= theirOffer then
            negotiationStatus = "refused"
          else
            theirOffer = theirOfferCandidate
            negotiationStatus = "counterOffer"
          end
        end
      end
    else
      -- ========================================================================
      -- PRIVATE INDIVIDUAL BEHAVIOR: Emotional, can walk away
      -- ========================================================================

      if patience <= 0 then
        negotiationStatus = "failed"
      else
        local counter = generateCounterOffer()

        -- Check if they accept
        if (not amISelling and counter <= myOffer) or (amISelling and counter >= myOffer) then
          theirOffer = myOffer
          negotiationStatus = "accepted"
        else
          theirOffer = counter
          negotiationStatus = "counterOffer"
        end
      end
    end
    local theirOfferElement = {
      theirOffer = theirOffer,
      negotiationStatus = negotiationStatus
    }
    table.insert(offerHistory, theirOfferElement)
    guihooks.trigger('negotiationData', getNegotiationState())
  end)
  return true
end

local function makeNegotiationOffer(price)
  return makeOffer(tonumber(price))
end

local function takeTheirOffer()
  if amISelling then
    local listing = findVehicleListing(negotiationInventoryId)
    local offer = listing.offers[negotiationOfferIndex]
    offer.value = theirOffer

    M.acceptOffer(negotiationInventoryId, negotiationOfferIndex)
  else
    local vehicleInfo = career_modules_vehicleShopping.getVehicleInfoByShopId(shopId)
    if theirOffer < vehicleInfo.Value then
      vehicleInfo.originalSellValue = vehicleInfo.Value
    end
    vehicleInfo.Value = theirOffer
    vehicleInfo.negotiationPossible = false
  end
  myOffer = nil
end

local myOfferValuePtr = im.IntPtr(0)
local timeSinceUpdate = 0
local function onUpdate(dtReal, dtSim, dtRaw)
  if tableIsEmpty(listedVehicles) or offerMenuOpen then
    return
  end

  if negotiationActive then
    im.Begin("Negotiation Buying")
      if negotiationStatus == "thinking" then
        im.Text("Thinking...")
      else
        im.Text("Initial Offer: " .. startingPrice)
        im.Text("Their current Offer: " .. theirOffer)
        im.Text("My current Offer: " .. (myOffer or "(Not set)"))

        myOfferValuePtr[0] = myOffer or startingPrice
        local disabled = myOffer == theirOffer
        if disabled then
          im.BeginDisabled()
        end
        if im.InputInt("Make New Offer", myOfferValuePtr, nil, nil, im.InputTextFlags_EnterReturnsTrue) then
          makeOffer(myOfferValuePtr[0])
        end
        if disabled then
          im.EndDisabled()
        end

        if patience > 0.66 then im.PushStyleColor2(im.Col_Text, im.ImVec4(0.2, 1, 0.2, 1))
        elseif patience > 0.33 then im.PushStyleColor2(im.Col_Text, im.ImVec4(1, 1, 0.2, 1))
        else im.PushStyleColor2(im.Col_Text, im.ImVec4(1, 0.2, 0.2, 1)) end

        im.Text("Patience: " .. patience)
        im.PopStyleColor()
        im.Text("Status: " .. negotiationStatus)

        if im.Button("Take their offer") then
          negotiationActive = false
        end
        if im.Button("Cancel negotiation") then
          negotiationActive = false
        end
      end
    im.End()
  end
  timeSinceUpdate = timeSinceUpdate + dtSim
  if timeSinceUpdate < 10 then return end
  timeSinceUpdate = 0

  generateNewOffers()
end

local function onVehicleRemoved(inventoryId)
  removeVehicleListing(inventoryId)
end

local function getListings()
  local listingsCopy = deepcopy(listedVehicles)
  for i, listing in ipairs(listingsCopy) do
    local currentValue = career_modules_valueCalculator.getInventoryVehicleValue(listing.id)
    if currentValue < listing.marketValue * valueLossLimit then
      listing.disabled = true
      listing.disableReason = "Cant sell the vehicle because value has dropped below " .. valueLossLimit * 100 .. "% of the market value when the vehicle was listed."
    end

    for _, offer in ipairs(listing.offers) do
      if offer.expiredViewCounter then
        offer.disabled = true
        offer.disableReason = "Cant sell the vehicle because the offer has expired"
      end
    end
  end
  return listingsCopy
end

local function updateListings()
  if offerMenuOpen then
    local expiredOffersCount = 0
    for i, listing in ipairs(listedVehicles) do
      for offerIndex = #listing.offers, 1, -1 do
        local offer = listing.offers[offerIndex]
        if offer.expiredViewCounter then
          expiredOffersCount = expiredOffersCount + 1
          offer.expiredViewCounter = offer.expiredViewCounter + 1
          if offer.expiredViewCounter > 1 or expiredOffersCount > maximumExpiredOffers then
            table.remove(listing.offers, offerIndex)
          end
        end
      end
    end
  else
    -- generate offers as if they have been generated while the menu was open
    local offerCountDiff = generateNewOffers()
    if offerCountDiff < 0 then
      for i = 1, math.abs(offerCountDiff) do
        local offer = generateOffer()
        -- randomize the offer timestamp
        offer.timestamp = offer.timestamp + math.random(1, offerTTL)
      end
    end
  end
end

local function menuOpened(open)
  local newOfferMenuOpen = open or negotiationActive -- count the negotiation as part of the menu
  if newOfferMenuOpen == offerMenuOpen then return end
  offerMenuOpen = newOfferMenuOpen
  updateListings()
end

local function openMenu(computerId)
  career_modules_vehicleShopping.openShop(nil, computerId, "marketplace")
end

local function onSaveCurrentSaveSlot(currentSavePath, oldSaveDate, vehiclesThumbnailUpdate)
  career_saveSystem.jsonWriteFileSafe(currentSavePath .. "/career/marketplace.json", {
    listedVehicles = listedVehicles
  }, true)
end

local function onExtensionLoaded()
  if not career_career.isActive() then return false end

  local saveSlot, savePath = career_saveSystem.getCurrentSaveSlot()
  if not saveSlot or not savePath then return end

  local data = jsonReadFile(savePath .. "/career/marketplace.json")
  if data then
    listedVehicles = data.listedVehicles
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

M.generatePersonality = generatePersonality
M.startNegotiateBuyingOffer = startNegotiateBuyingOffer
M.startNegotiateSellingOffer = startNegotiateSellingOffer
M.getNegotiationState = getNegotiationState
M.makeNegotiationOffer = makeNegotiationOffer
M.takeTheirOffer = takeTheirOffer
M.cancelNegotiation = cancelNegotiation

M.firstNames = {
  "Aaliyah", "Aaron", "Abdullah", "Abigail", "Adam", "Aditya", "Adrian", "Adriana", "Adrien", "Agustin", "Ahmed", "Aisha", "Akari", "Akira", "Alan", "Albert", "Alberto", "Alejandra", "Alejandro", "Alessandro", "Alessia", "Alexander", "Alexandre", "Alexei", "Alexis", "Alfonso", "Alfredo", "Ali", "Alice", "Alicia", "Amanda", "Amandine", "Amber", "Amelia", "Amelie", "Amina", "Amir", "Amit", "Amparo", "Amy", "Ana", "Ananya", "Anastasia", "Andre", "Andrea", "Andreas", "Andrei", "Andres", "Andrew", "Angel", "Angela", "Anh", "Anjali", "Ann", "Anna", "Anselmo", "Anthony", "Antoine", "Anton", "Antonia", "Antonio", "Aoi", "Arjun", "Armando", "Artem", "Arthur", "Arturo", "Ascension", "Ashley", "Audrey", "Aurelie", "Aurora", "Austin", "Baptiste", "Barbara", "Beatrice", "Beatriz", "Benjamin", "Bernardo", "Betty", "Beverly", "Bilal", "Billy", "Binh", "Blanca", "Bobby", "Brandon", "Brenda", "Brian", "Brianna", "Brittany", "Bruce", "Bryan", "Camila", "Camille", "Cao", "Carl", "Carlos", "Carmen", "Carol", "Carolina", "Caroline", "Carolyn", "Catalina", "Catherine", "Cecile", "Celestino", "Celine", "Cesar", "Charles", "Charlotte", "Chen", "Cheng", "Cheryl", "Chiara", "Christian", "Christina", "Christine", "Christopher", "Claire", "Claudia", "Clement", "Concepcion", "Consuelo", "Cristian", "Cristina", "Cynthia", "Dalia", "Daniel", "Daniela", "Danielle", "Daria", "Dario", "Darius", "Darnell", "David", "Davide", "DeAndre", "Deborah", "Debra", "Deepika", "Deng", "Denis", "Denise", "Dennis", "Destiny", "Devonte", "Diana", "Diane", "Diego", "Dina", "Divya", "Dmitri", "Dolores", "Donald", "Donna", "Dorothy", "Douglas", "Duc", "Dylan", "Ebony", "Edoardo", "Eduardo", "Edward", "Ekaterina", "Elena", "Elisa", "Elisabeth", "Elise", "Eliseo", "Elizabeth", "Elodie", "Emilie", "Emilio", "Emily", "Emma", "Encarnacion", "Enrique", "Eric", "Erick", "Ernesto", "Esperanza", "Esteban", "Esther", "Ethan", "Eugene", "Eugenio", "Eun", "Eusebio", "Evelyn", "Fabian", "Fabien", "Faisal", "Fang", "Fatima", "Federico", "Felipe", "Felix", "Feng", "Fernanda", "Fernando", "Florian", "Frances", "Francesca", "Francesco", "Francisca", "Francisco", "Francois", "Frank", "Gabriel", "Gabriela", "Gabriele", "Gao", "Gary", "George", "Gerald", "Gerardo", "Ginevra", "Giorgia", "Giovanni", "Giulia", "Gloria", "Gonzalo", "Grace", "Graciela", "Gregory", "Greta", "Guadalupe", "Guillaume", "Guo", "Gustavo", "Hafsa", "Hai", "Hala", "Hamza", "Han", "Hana", "Hanan", "Hannah", "Harold", "Harry", "Haruka", "Hassan", "He", "Heather", "Hector", "Helen", "Helene", "Henri", "Henry", "Hiroshi", "Hoa", "Hu", "Huang", "Hugo", "Hui", "Hung", "Huong", "Hussein", "Hye", "Ibrahim", "Ignacio", "Igor", "Ines", "Irina", "Irma", "Isabel", "Isabelle", "Isha", "Isidro", "Ismael", "Ivan", "Jack", "Jacob", "Jacqueline", "Jalen", "Jamal", "James", "Jamil", "Jan", "Jane", "Janet", "Janice", "Jasmine", "Jason", "Javier", "Jean", "Jeffrey", "Jennifer", "Jeremy", "Jerry", "Jesse", "Jessica", "Ji", "Jimena", "Jin", "Jing", "Joan", "Joaquin", "Joe", "Johannes", "John", "Johnny", "Jonas", "Jonathan", "Jordan", "Jorge", "Jose", "Joseph", "Joshua", "Joyce", "Juan", "Juana", "Judith", "Judy", "Julia", "Julie", "Julien", "Juliette", "Julio", "Jun", "Justin", "Kai", "Karan", "Kareem", "Karen", "Karim", "Katharina", "Katherine", "Kathleen", "Kathryn", "Kathy", "Kavita", "Keisha", "Keith", "Kelly", "Kendrick", "Kenji", "Kenneth", "Kevin", "Khadija", "Khaled", "Khalid", "Kimberly", "Kiran", "Kristina", "Kyle", "Kyung", "Lan", "Larry", "Latoya", "Laura", "Lawrence", "Layla", "Lea", "Leandro", "Leila", "Leonardo", "Leticia", "Li", "Liliana", "Lin", "Lina", "Linda", "Ling", "Linh", "Lisa", "Liu", "Logan", "Lorenzo", "Lori", "Louis", "Luca", "Lucas", "Lucia", "Luis", "Lukas", "Luo", "Ma", "Madison", "Mahmoud", "Mai", "Malik", "Manoj", "Manon", "Manuel", "Manuela", "Marcelo", "Marco", "Marcus", "Margaret", "Margarita", "Maria", "Mariam", "Mariana", "Marie", "Marilyn", "Marina", "Marine", "Mario", "Marion", "Marisol", "Mark", "Markus", "Marquis", "Martha", "Martin", "Martina", "Mary", "Maryam", "Matteo", "Matthew", "Matthias", "Matthieu", "Maxim", "Maxime", "Maximilian", "Maximo", "Maya", "Meera", "Megan", "Mei", "Melanie", "Melissa", "Mercedes", "Mi", "Michael", "Michelle", "Miguel", "Mikhail", "Milagros", "Mildred", "Min", "Ming", "Mohammed", "Moises", "Mona", "Monica", "Monique", "Mustafa", "Na", "Nadia", "Nadine", "Nam", "Nancy", "Nasir", "Nasser", "Natalia", "Nathalie", "Nathan", "Natividad", "Neha", "Nestor", "Nga", "Nia", "Nicholas", "Nicolas", "Nicole", "Nikhil", "Nikolai", "Nina", "Nisha", "Noah", "Noha", "Noor", "Norma", "Nour", "Octavio", "Olga", "Olivier", "Omar", "Oscar", "Pablo", "Pamela", "Paola", "Patricia", "Patrick", "Paul", "Pauline", "Pavel", "Pedro", "Peter", "Petra", "Philip", "Philipp", "Philippe", "Phuong", "Piedad", "Pierre", "Pietro", "Pilar", "Polina", "Pooja", "Pradeep", "Presentacion", "Priya", "Purificacion", "Quang", "Rachel", "Rafael", "Rahul", "Raj", "Ralph", "Rami", "Ramon", "Rana", "Randy", "Rania", "Raquel", "Rashid", "Raul", "Ravi", "Raymond", "Rebecca", "Reem", "Regina", "Remedios", "Renato", "Rene", "Ricardo", "Riccardo", "Richard", "Rima", "Rin", "Riya", "Robert", "Roberto", "Rocio", "Rodolfo", "Rodrigo", "Rogelio", "Roger", "Rohan", "Romain", "Roman", "Ronald", "Rosa", "Rosario", "Rose", "Roy", "Ruben", "Russell", "Ryan", "Ryo", "Sabine", "Safiya", "Sakura", "Salma", "Salvador", "Salvatore", "Samantha", "Sami", "Samira", "Samuel", "Sandra", "Sang", "Sara", "Sarah", "Satoshi", "Saul", "Scott", "Sean", "Sebastian", "Sebastien", "Sergei", "Sergio", "Seung", "Shanice", "Sharon", "Shirley", "Shreya", "Siddharth", "Silvia", "Simon", "Simone", "Sneha", "Sofia", "Soledad", "Song", "Soo", "Sophie", "Stefan", "Stephanie", "Stephen", "Steven", "Sun", "Suresh", "Susan", "Susana", "Susanne", "Svetlana", "Swati", "Takeshi", "Tamer", "Tang", "Tanvi", "Tarek", "Tariq", "Tatiana", "Teodoro", "Teresa", "Terry", "Thao", "Theresa", "Thomas", "Tiffany", "Tim", "Timothy", "Tobias", "Tomas", "Tommaso", "Trevon", "Tuan", "Tyler", "Tyrone", "Valentin", "Valentina", "Valeria", "Valerio", "Vanessa", "Varun", "Veronica", "Victor", "Victoria", "Vikram", "Viktor", "Vincent", "Vincenzo", "Virginia", "Virginie", "Visitacion", "Vladimir", "Waleed", "Walter", "Wayne", "Wei", "William", "Willie", "Woo", "Wu", "Xia", "Xie", "Ximena", "Xu", "Yan", "Yang", "Yasmin", "Yolanda", "Young", "Youssef", "Yuan", "Yui", "Yuki", "Yulia", "Yusuf", "Yusuke", "Zachary", "Zain", "Zainab", "Zhang", "Zhao", "Zheng", "Zhou", "Zhu", "Zoe"
}
M.firstNameCount = #M.firstNames

M.initialProbabilities= {
  A = 0.038,
  B = 0.085,
  C = 0.077,
  D = 0.045,
  E = 0.019,
  F = 0.034,
  G = 0.056,
  H = 0.071,
  I = 0.004,
  J = 0.030,
  K = 0.033,
  L = 0.049,
  M = 0.096,
  N = 0.019,
  O = 0.015,
  P = 0.050,
  Q = 0.002,
  R = 0.059,
  S = 0.094,
  T = 0.035,
  U = 0.002,
  V = 0.018,
  W = 0.055,
  X = 0.0004,
  Y = 0.006,
  Z = 0.006,
}
M.initials = {}
for initial, probability in pairs(M.initialProbabilities) do
  for i = 1, math.ceil(probability * 100) do
    table.insert(M.initials, initial)
  end
end
M.initialCount = #M.initials


M.privateSellerQuotes = {
  "Just want it gone, moving next week.",
  "Hate to see her go, but need the space.",
  "Been in the family for years, well maintained.",
  "Price is firm, I know what I have.",
  "Make me an offer, need cash ASAP.",
  "No lowballers, I know what it's worth.",
  "Garage kept, all service records available.",
  "Drove it myself for 5 years, runs great.",
  "Life changes, gotta sell unfortunately.",
  "Open to reasonable offers.",
  "Priced to sell this weekend.",
  "Take care of it and it'll take care of you.",
  "Never had any issues with it.",
  "Only selling because I upgraded.",
  "Don't waste my time with ridiculous offers.",
  "First reasonable offer takes it.",
  "Selling for a friend, flexible on price.",
  "Mechanically sound, cosmetically rough.",
  "It's been reliable for me.",
  "New job means I don't need it anymore.",
  "Adult owned, never abused.",
  "Clean title in hand, ready to transfer.",
  "Runs and drives, needs some TLC.",
  "Everything works as it should.",
  "Minor cosmetic issues, drives perfect.",
  "Recent oil change and new tires.",
  "Hate to part with it, but downsizing.",
  "Priced below book value for quick sale.",
  "Zero mechanical problems, drives smooth.",
  "Cold AC, heat works great too.",
  "Always serviced on time.",
  "Second owner, bought from family.",
  "Won't find a better deal than this.",
  "Serious inquiries only please.",
  "Text is best, I work nights.",
  "Can meet at DMV to transfer title.",
  "No joy rides, cash talks.",
  "Perfect winter car, starts every time.",
  "Great gas mileage, very economical.",
  "Retiring and don't need two cars.",
  "Baby on the way, need something bigger.",
  "Moving out of state next month.",
  "Estate sale, must sell quickly.",
  "Lost my license, don't need it anymore.",
  "Bought a truck, this has to go.",
  "Wife's car, she wants something newer.",
  "College kid car, heading off to school.",
  "Transmission rebuilt last year.",
  "Just passed inspection last month.",
  "Great starter car for a teenager."
}

M.dealershipBuyerQuotes = {
  "We're always looking for quality inventory.",
  "Let me see what I can offer you for this.",
  "I'll need to get it appraised, but we're interested.",
  "We can make you an offer today.",
  "What are you looking to get out of it?",
  "We buy cars in any condition.",
  "I can take it off your hands.",
  "We're prepared to make a fair offer.",
  "Let me run the numbers real quick.",
  "We need inventory, I can work with you.",
  "I'll have to inspect it first, but we're interested.",
  "We can process this today if the price is right.",
  "What's your bottom line on it?",
  "We're in the market for one of these.",
  "I can make you an offer, but it needs to be realistic.",
  "We'll need to account for reconditioning costs.",
  "Let's talk numbers.",
  "We buy dozens of cars every month.",
  "I can give you a quote, but our margins are tight.",
  "We're definitely interested in adding this to our lot.",
  "What were you hoping to get for it?",
  "We can make this quick and easy for you.",
  "I'll need to factor in wholesale value.",
  "We're always buying - let's make a deal.",
  "I can write you a check today."
}

return M