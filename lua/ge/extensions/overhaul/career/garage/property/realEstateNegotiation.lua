-- Property negotiations and listings; this file owns reply jobs and saved negotiation state.
-- Read tuning/state, personalities, UI projection, replies and actions, listings, then save/load and hooks.
local M = {}
local levelData = require("overhaul/lib/world/levelData")
local phoneLayout = require("overhaul/lib/phone/layoutOwner")

local ensureDir = require("overhaul/lib/save/ensureDir")

-- Config ------------------------------------------------------------------------------------------

local PERSONALITIES_FALLBACK_PATH = "gameplay/overhaul/property/realEstatePersonalities.json"
local LOG_TAG = "realEstateNegotiation"
local NEGOTIATION_HOOK = "realEstateNegotiationData"
local SAVE_SUBDIR = "/career/rls_career"
local OFFER_POLL_INTERVAL_S = 5
local DEFAULT_QUOTE = "Let's discuss the price."

local tuning = {
  thinkingBaseS = 2.5,
  thinkingRandomS = 2.0,
  patiencePercentWeight = 1.5,
  patienceAbsoluteScaleMoney = 1000,
  patienceAbsoluteWeight = 4,
  patiencePriceScaleMoney = 100000,
  institutionalPatienceMultiplier = 0.5,
  patienceRandomPoints = 8,
  counterPatienceWeight = 0.3,
  counterBaseFraction = 0.20,
  counterBoostRangeFraction = 0.12,
  counterBoostOffsetFraction = 0.06,
  counterNoiseRangeFraction = 0.15,
  counterNoiseOffsetFraction = 0.075,
  counterMinFraction = 0.15,
  counterMaxFraction = 0.50,
  priceRoundingMoney = 100,
  buyerPatiencePercentWeight = 1.2,
  buyerPatienceAbsoluteWeight = 3,
  buyerPatienceRandomPoints = 6,
  buyerDesperationBonusFraction = 0.03,
  buyerAcceptanceBufferFraction = 0.04,
  buyerAcceptancePatienceWeight = 0.05,
  buyerAcceptanceMinMultiplier = 0.96,
  buyerAcceptanceRandomRange = 0.08,
  overBudgetCounterMinFraction = 0.20,
  overBudgetCounterMaxFraction = 0.55,
  buyerCounterMaxFraction = 0.45,
  buyerCounterRandomRangeFraction = 0.1,
  buyerCounterRandomOffsetFraction = 0.05,
  buyerCounterNoiseRangeFraction = 0.14,
  buyerCounterNoiseOffsetFraction = 0.07,
  buyerLastChancePatienceFraction = 0.12,
  defaultInsultThresholdFraction = 0.85,
  lowballPatiencePenaltyFraction = 0.4,
  defaultDesperationDiscountFraction = 0.05,
  sellerPatienceDiscountWeight = 0.7,
  happyAcceptanceMultiplier = 1.05,
  sellerLastChancePatienceFraction = 0.05,
}

local timeBetweenOffersBase = 190 -- twice the vehicle offer timing (95s)
local offerTTL = 1000 -- twice the vehicle offer lifetime (500s)
local CLOSING_FEE_RATE = 0.03
local PROPERTY_TAX_RATE = 0.012 -- annualized estimate

-- State -------------------------------------------------------------------------------------------

local negotiationActive = false
local amISelling = false -- false = buying, true = selling
local startingPrice = 0
local patience = 1.0
local isInsulted = false
local myOffer = nil
local theirOffer = 0
local offerHistory = {}
local negotiationStatus = "initial"
local opponentPersonality = nil
local opponentQuote = ""

local propertyId = nil -- garageId being negotiated
local propertyName = ""
local propertyPreview = ""
local propertyMarketValue = 0
local propertyCapacity = 0
local propertyParkingSpots = 0
local propertyNeighborhood = ""

local listingIndex = nil -- index into listedProperties[propertyId].offers
local listedProperties = {} -- [garageId] = { listingTimestamp, askingPrice, offers, ... }
local negotiationOrigin = "computer"
local negotiationToken = 0
local offerUpdateAccumulator = 0
local personalitiesCache = {}

-- Reset -------------------------------------------------------------------------------------------

local function resetNegotiationState()
  negotiationToken = negotiationToken + 1
  negotiationActive = false
  amISelling = false
  startingPrice = 0
  patience = 1.0
  isInsulted = false
  myOffer = nil
  theirOffer = 0
  offerHistory = {}
  negotiationStatus = "initial"
  opponentPersonality = nil
  opponentQuote = ""
  propertyId = nil
  propertyName = ""
  propertyPreview = ""
  propertyMarketValue = 0
  propertyCapacity = 0
  propertyParkingSpots = 0
  propertyNeighborhood = ""
  listingIndex = nil
  negotiationOrigin = "computer"
end

-- Personalities -----------------------------------------------------------------------------------

local function getDefaultSellerPersonality()
  return {
    archetype = "default_private_seller",
    name = "Property Seller",
    isDealership = false,
    startingPatience = 0.8,
    patienceVariance = 0.1,
    isDesperate = false,
    desperation = 0.05,
    desperationMaxDiscount = 0.05,
    insultThresholdBase = 0.85,
    priceMultiplier = 0,
    counterOfferReadiness = 0.5,
    quotesByPriceTier = {
      low = {DEFAULT_QUOTE},
      mid = {"I'm open to reasonable offers."},
      high = {"This is a valuable property."}
    },
    insultQuotes = {"That's way too low."},
    happyQuotes = {"Deal."},
    minimumOverMarket = 0,
  }
end

local function loadPersonalityData()
  local paths = {}
  local levelId = getCurrentLevelIdentifier()
  if levelId and levelId ~= "" then
    table.insert(paths, "levels/" .. levelId .. "/facilities/realEstatePersonalities.json")
  end
  table.insert(paths, PERSONALITIES_FALLBACK_PATH)
  for _, filePath in ipairs(paths) do
    if personalitiesCache[filePath] == nil then
      local exists = filePath == PERSONALITIES_FALLBACK_PATH or FS:fileExists(filePath)
      local data = exists and jsonReadFile(filePath)
      local valid = type(data) == "table" and type(data.archetypes) == "table"
        and type(data.randomSellerArchetypes) == "table" and #data.randomSellerArchetypes > 0
        and type(data.randomBuyerArchetypes) == "table" and #data.randomBuyerArchetypes > 0
      if valid then
        for _, group in ipairs({data.randomSellerArchetypes, data.randomBuyerArchetypes}) do
          for _, key in ipairs(group) do
            if type(data.archetypes[key]) ~= "table" then valid = false end
          end
        end
      end
      if exists and not valid then log("W", LOG_TAG, "Missing required property archetypes: " .. filePath) end
      personalitiesCache[filePath] = valid and data or false
    end
    if personalitiesCache[filePath] then
      return personalitiesCache[filePath]
    end
  end
  return nil
end

local function rollStartingPatience(archetype, defaultPatience)
  local basePatience = archetype.startingPatience or defaultPatience
  local patienceVariance = archetype.patienceVariance or 0.1
  return math.max(0.3, math.min(1.0, basePatience + (math.random() * patienceVariance * 2 - patienceVariance)))
end

-- Draws a first name, then initials only when some exist; nil when there are no first names.
local function randomPersonName(firstNames, initials)
  if not (firstNames and #firstNames > 0) then return nil end
  local name = firstNames[math.random(1, #firstNames)]
  if initials and #initials > 0 then
    name = name .. " " .. initials[math.random(1, #initials)] .. "."
  end
  return name
end

local function pickSellerName(archetype)
  if archetype.isDealership then
    if archetype.names and #archetype.names > 0 then
      return archetype.names[math.random(1, #archetype.names)]
    end
    return "Property Manager"
  end
  return randomPersonName(overhaul_career_market_marketplace.firstNames, overhaul_career_market_marketplace.initials) or "Private Seller"
end

local function pickBuyerName(archetype)
  if archetype.names and #archetype.names > 0 then
    return archetype.names[math.random(1, #archetype.names)]
  elseif overhaul_career_market_marketplace and overhaul_career_market_marketplace.firstNames then
    return randomPersonName(overhaul_career_market_marketplace.firstNames, overhaul_career_market_marketplace.initials) or "Buyer"
  end
  return "Buyer"
end

local function generateSellerPersonality()
  local data = loadPersonalityData()
  if not data or not data.randomSellerArchetypes or not data.archetypes then
    log("W", LOG_TAG, "Could not load realEstatePersonalities.json, using default")
    return getDefaultSellerPersonality()
  end

  local archetypeKeys = data.randomSellerArchetypes or {}
  if #archetypeKeys == 0 then
    log("W", LOG_TAG, "No seller archetypes found, using default")
    return getDefaultSellerPersonality()
  end

  local chosenKey = archetypeKeys[math.random(1, #archetypeKeys)]
  local archetype = data.archetypes[chosenKey]
  if not archetype then
    log("W", LOG_TAG, "Archetype not found: " .. chosenKey .. ", using default")
    return getDefaultSellerPersonality()
  end

  local isDesperate = math.random() < (archetype.desperation or 0.05)
  local baseThreshold = archetype.insultThresholdBase or 0.85
  local variance = archetype.insultThresholdVariance or 0.03
  local insultThreshold = baseThreshold + (math.random() * variance * 2 - variance)

  local patienceRoll = rollStartingPatience(archetype, 0.8)
  local name = pickSellerName(archetype)

  return {
    archetype = chosenKey,
    name = name,
    isDealership = archetype.isDealership or false,
    startingPatience = patienceRoll,
    patienceVariance = archetype.patienceVariance or 0.1,
    isDesperate = isDesperate,
    desperation = archetype.desperation or 0.05,
    desperationMaxDiscount = archetype.desperationMaxDiscount or 0.05,
    insultThresholdBase = insultThreshold,
    priceMultiplier = archetype.priceMultiplier or 0,
    counterOfferReadiness = archetype.counterOfferReadiness or 0.5,
    quotesByPriceTier = archetype.quotesByPriceTier,
    insultQuotes = archetype.insultQuotes or {"That's too low."},
    happyQuotes = archetype.happyQuotes or {"Deal."},
    minimumOverMarket = archetype.minimumOverMarket or 0,
    maxOverMarket = archetype.maxOverMarket or 0,
  }
end

local function generateBuyerPersonality()
  local data = loadPersonalityData()
  if not data or not data.randomBuyerArchetypes or not data.archetypes then
    return getDefaultSellerPersonality()
  end

  local archetypeKeys = data.randomBuyerArchetypes or {}
  if #archetypeKeys == 0 then
    return getDefaultSellerPersonality()
  end

  local chosenKey = archetypeKeys[math.random(1, #archetypeKeys)]
  local archetype = data.archetypes[chosenKey] or {}

  local name = pickBuyerName(archetype)
  local patienceRoll = rollStartingPatience(archetype, 0.7)

  return {
    archetype = chosenKey,
    name = name,
    isDealership = archetype.isDealership or false,
    startingPatience = patienceRoll,
    patienceVariance = archetype.patienceVariance or 0.1,
    isDesperate = math.random() < (archetype.desperation or 0.05),
    priceMultiplier = archetype.priceMultiplier or 0.9,
    counterOfferReadiness = archetype.counterOfferReadiness or 0.5,
    maxOverMarket = archetype.maxOverMarket or 0,
    quotesByPriceTier = archetype.quotesByPriceTier,
    insultQuotes = archetype.insultQuotes or {"That's too high for me."},
    happyQuotes = archetype.happyQuotes or {"Deal."},
  }
end

-- Quote selection ---------------------------------------------------------------------------------

local function selectQuoteForPersonality(personality, propertyValue)
  if not personality then
    log("W", LOG_TAG, "selectQuoteForPersonality: personality is nil")
    return DEFAULT_QUOTE
  end

  if not propertyValue or propertyValue <= 0 then
    log("W", LOG_TAG, "selectQuoteForPersonality: invalid property value")
    return DEFAULT_QUOTE
  end

  local priceTier = "low"
  if propertyValue >= 800000 then
    priceTier = "high"
  elseif propertyValue >= 400000 then
    priceTier = "mid"
  end

  local quotes = nil
  if personality.quotesByPriceTier and type(personality.quotesByPriceTier) == "table" then
    quotes = personality.quotesByPriceTier[priceTier]
  end

  if quotes and type(quotes) == "table" and #quotes > 0 then
    return quotes[math.random(1, #quotes)]
  end

  log("W", LOG_TAG, "No quotes found for tier: " .. priceTier)
  return DEFAULT_QUOTE
end

-- UI projection -----------------------------------------------------------------------------------

local function getNegotiationState()
  local mortgageAvailable = overhaul_career_garage_property_propertyMortgage.isMortgageAvailable() or false
  local mortgageDetails = overhaul_career_garage_property_propertyMortgage.getMortgageOfferDetails() or nil

  return {
    active = negotiationActive,
    amISelling = amISelling,
    propertyId = propertyId,
    propertyName = propertyName,
    propertyPreview = propertyPreview,
    propertyCapacity = propertyCapacity,
    propertyParkingSpots = propertyParkingSpots,
    propertyNeighborhood = propertyNeighborhood,
    startingPrice = startingPrice,
    patience = patience,
    myOffer = myOffer,
    theirOffer = theirOffer,
    status = negotiationStatus,
    opponentName = opponentPersonality and opponentPersonality.name or "Seller",
    opponentQuote = opponentQuote,
    propertyMarketValue = propertyMarketValue,
    negotiationStatus = negotiationStatus,
    offerHistory = offerHistory,
    isInsulted = isInsulted,
    closingFeeRate = CLOSING_FEE_RATE,
    propertyTaxRate = PROPERTY_TAX_RATE,
    mortgageAvailable = mortgageAvailable,
    mortgageDetails = mortgageDetails,
    origin = negotiationOrigin,
  }
end

-- Listed offer lookup -----------------------------------------------------------------------------

local function findListedOffer(garageId, offerIndex)
  local listing = listedProperties[garageId]
  if not listing or not listing.offers then return nil end
  local idx = tonumber(offerIndex)
  if not idx or idx < 1 or idx > #listing.offers then return nil end
  return listing.offers[idx], idx
end

local function findCurrentListedOffer()
  if not amISelling or not propertyId or not listingIndex then return nil end
  return findListedOffer(propertyId, listingIndex)
end

local function markOfferAsNoDeal()
  local offer = findCurrentListedOffer()
  if not offer then return false end
  offer.negotiationPossible = false
  offer.negotiatedPrice = nil
  return true
end

local function markOfferAsAccepted()
  local offer = findCurrentListedOffer()
  if not offer then return false end
  offer.negotiatedPrice = theirOffer
  offer.negotiationPossible = false
  return true
end

-- Replies -----------------------------------------------------------------------------------------

local function calculatePatienceDrop(myOfferAmount, theirOfferAmount, marketValue, personality)
  local gapFromTheirOffer = math.abs(myOfferAmount - theirOfferAmount)
  local gapPct = (gapFromTheirOffer / theirOfferAmount) * 100

  local percentagePatienceDrop = gapPct * tuning.patiencePercentWeight
  local absolutePatienceDrop = (gapFromTheirOffer / tuning.patienceAbsoluteScaleMoney) * tuning.patienceAbsoluteWeight

  local priceScale = math.min(1, marketValue / tuning.patiencePriceScaleMoney)
  local percentageWeight = priceScale
  local absoluteWeight = 1 - priceScale

  local institutionalModifier = personality.isDealership and tuning.institutionalPatienceMultiplier or 1.0

  local patienceDrop = ((percentagePatienceDrop * percentageWeight + absolutePatienceDrop * absoluteWeight) * institutionalModifier) + math.random() * tuning.patienceRandomPoints

  return patienceDrop / 100
end

local function generateCounterOffer(myOfferAmount, theirOfferAmount, currentPatience)
  local diff = theirOfferAmount - myOfferAmount
  -- Low patience means bigger jumps, to close faster.
  local baseMovePercent = (1 - currentPatience) * tuning.counterPatienceWeight + tuning.counterBaseFraction
  local randomBoost = (math.random() * tuning.counterBoostRangeFraction - tuning.counterBoostOffsetFraction)
  local noisePercent = (math.random() * tuning.counterNoiseRangeFraction - tuning.counterNoiseOffsetFraction)
  local movePercent = baseMovePercent + randomBoost + noisePercent
  movePercent = math.max(tuning.counterMinFraction, math.min(tuning.counterMaxFraction, movePercent))

  local counterAmount = myOfferAmount + (math.abs(diff) * movePercent)
  return math.max(myOfferAmount, math.floor(counterAmount / tuning.priceRoundingMoney + 0.5) * tuning.priceRoundingMoney)
end

local function isOfferAllowed(price)
  if not negotiationActive then return false end
  if negotiationStatus == "accepted" or negotiationStatus == "failed" then return false end
  if negotiationStatus == "thinking" or negotiationStatus == "typing" then return false end
  if not price or price <= 0 then return false end

  if amISelling then
    if price <= theirOffer then return false end
    if myOffer and price > myOffer then return false end
  else
    if price > theirOffer then return false end
    if myOffer and price <= myOffer then return false end
  end

  return true
end

local function buyerCounterOffer(maxWillingToPay, minMoveFraction, maxMoveFraction)
  local diff = myOffer - theirOffer
  local movePercent = math.max(minMoveFraction, math.min(maxMoveFraction,
    ((1 - patience) * tuning.counterPatienceWeight + tuning.counterBaseFraction)
      + (math.random() * tuning.buyerCounterRandomRangeFraction - tuning.buyerCounterRandomOffsetFraction)))
  local counter = theirOffer + (diff * movePercent)
    + (diff * (math.random() * tuning.buyerCounterNoiseRangeFraction - tuning.buyerCounterNoiseOffsetFraction))
  return math.min(maxWillingToPay, math.floor(counter / tuning.priceRoundingMoney + 0.5) * tuning.priceRoundingMoney)
end

local function failBuyerReply(quote)
  negotiationStatus = "failed"
  opponentQuote = quote
  markOfferAsNoDeal()
end

local function acceptMyOffer(quote)
  theirOffer = myOffer
  negotiationStatus = "accepted"
  opponentQuote = quote
  markOfferAsAccepted()
end

local function counterWith(counter)
  theirOffer = counter
  negotiationStatus = patience <= tuning.buyerLastChancePatienceFraction and "counterOfferLastChance" or "counterOffer"
  opponentQuote = selectQuoteForPersonality(opponentPersonality, propertyMarketValue)
end

local function dropBuyerPatience()
  local askGap = math.abs(myOffer - theirOffer)
  local askGapPct = (askGap / math.max(1, theirOffer)) * 100
  local patienceDrop = ((askGapPct * tuning.buyerPatiencePercentWeight) + (askGap / tuning.patienceAbsoluteScaleMoney) * tuning.buyerPatienceAbsoluteWeight + math.random() * tuning.buyerPatienceRandomPoints) / 100
  patience = math.max(0, patience - patienceDrop)
end

local function replyToSellerPrice()
  dropBuyerPatience()

  local maxOver = opponentPersonality.maxOverMarket or 0
  local desperationBonus = opponentPersonality.isDesperate and tuning.buyerDesperationBonusFraction or 0
  local maxWillingToPay = propertyMarketValue * (1 + maxOver + desperationBonus)
  local acceptanceBuffer = tuning.buyerAcceptanceBufferFraction + ((1 - patience) * tuning.buyerAcceptancePatienceWeight)
  local acceptanceThreshold = maxWillingToPay * (1 - (acceptanceBuffer * (tuning.buyerAcceptanceMinMultiplier + math.random() * tuning.buyerAcceptanceRandomRange)))

  if myOffer > maxWillingToPay then
    if patience <= 0 then
      failBuyerReply("I can't go that high.")
      return
    end
    local counter = buyerCounterOffer(maxWillingToPay, tuning.overBudgetCounterMinFraction, tuning.overBudgetCounterMaxFraction)
    if counter <= theirOffer then
      failBuyerReply("I can't go that high.")
    else
      counterWith(counter)
    end
  elseif myOffer >= acceptanceThreshold then
    acceptMyOffer(opponentPersonality.happyQuotes[math.random(1, #opponentPersonality.happyQuotes)])
  else
    local counter = buyerCounterOffer(maxWillingToPay, tuning.counterMinFraction, tuning.buyerCounterMaxFraction)
    if counter >= myOffer then
      acceptMyOffer("That works for me.")
    elseif counter <= theirOffer then
      failBuyerReply("That's my final number.")
    else
      counterWith(counter)
    end
  end
end

local function sellerAbsoluteMinimum()
  if opponentPersonality.isDesperate then
    local maxDiscount = opponentPersonality.desperationMaxDiscount or tuning.defaultDesperationDiscountFraction
    return propertyMarketValue * (1 - maxDiscount)
  end
  local maxPossibleDiscount = startingPrice
  local negotiationRange = math.min(math.max(0, startingPrice - propertyMarketValue), maxPossibleDiscount)
  local patienceMultiplier = patience * tuning.sellerPatienceDiscountWeight
  local willingToNegotiate = negotiationRange * patienceMultiplier
  return startingPrice - willingToNegotiate
end

-- Lowballs only cost patience, further below the seller's threshold costs more.
local function dropSellerPatience()
  local thresholdPrice = startingPrice * (opponentPersonality.insultThresholdBase or tuning.defaultInsultThresholdFraction)
  local patienceChange = calculatePatienceDrop(myOffer, theirOffer, propertyMarketValue, opponentPersonality)

  if myOffer < thresholdPrice then
    local howFarBelow = (thresholdPrice - myOffer) / thresholdPrice
    patienceChange = patienceChange + howFarBelow * tuning.lowballPatiencePenaltyFraction
    opponentQuote = opponentPersonality.insultQuotes[math.random(1, #opponentPersonality.insultQuotes)]
  end
  patience = math.max(0, patience - patienceChange)
end

local function counterBuyerOffer()
  local counter = generateCounterOffer(myOffer, theirOffer, patience)
  if counter <= myOffer then
    theirOffer = myOffer
    negotiationStatus = "accepted"
    opponentQuote = "That works for me."
  elseif patience <= tuning.sellerLastChancePatienceFraction then
    theirOffer = counter
    negotiationStatus = "counterOfferLastChance"
    opponentQuote = "This is my final offer. Take it or leave it."
  else
    theirOffer = counter
    negotiationStatus = "counterOffer"
    opponentQuote = selectQuoteForPersonality(opponentPersonality, propertyMarketValue)
  end
end

local function replyToBuyerPrice()
  dropSellerPatience()
  local absoluteMinimum = sellerAbsoluteMinimum()

  if patience <= 0 then
    negotiationStatus = "failed"
    opponentQuote = "I'm not interested in continuing this negotiation."
    theirOffer = startingPrice
    overhaul_career_garage_garageManager.setNegotiationCooldown(propertyId)
    markOfferAsNoDeal()
  elseif myOffer >= absoluteMinimum then
    theirOffer = myOffer
    negotiationStatus = "accepted"
    if myOffer > (absoluteMinimum * tuning.happyAcceptanceMultiplier) then
      opponentQuote = opponentPersonality.happyQuotes[math.random(1, #opponentPersonality.happyQuotes)]
    else
      opponentQuote = "Alright, we have a deal."
    end
  else
    counterBuyerOffer()
  end
end

local function makeOffer(price)
  if not isOfferAllowed(price) then
    log("W", LOG_TAG, "Offer not allowed: " .. tostring(price))
    return false
  end

  myOffer = price
  table.insert(offerHistory, { myOffer = myOffer })
  negotiationStatus = "thinking"
  guihooks.trigger(NEGOTIATION_HOOK, getNegotiationState())

  local jobToken = negotiationToken
  local jobPersonality = opponentPersonality
  local jobPropertyId = propertyId
  local function isStale()
    return jobToken ~= negotiationToken or not negotiationActive
      or opponentPersonality ~= jobPersonality or propertyId ~= jobPropertyId
  end

  core_jobsystem.create(function(job)
    local thinkingTime = tuning.thinkingBaseS + math.random() * tuning.thinkingRandomS
    job.sleep(thinkingTime)
    if isStale() then return end
    negotiationStatus = "typing"
    guihooks.trigger(NEGOTIATION_HOOK, getNegotiationState())
    job.sleep(thinkingTime)
    if isStale() then return end

    if amISelling then replyToSellerPrice() else replyToBuyerPrice() end

    table.insert(offerHistory, { theirOffer = theirOffer, negotiationStatus = negotiationStatus })
    guihooks.trigger(NEGOTIATION_HOOK, getNegotiationState())
  end)

  return true
end

local function completePurchase(garageId, finalPrice, freezePrice, useFinancing, selectedTerm)
  if not garageId or not finalPrice then
    log("E", LOG_TAG, "completePurchase: missing garageId or finalPrice")
    return
  end

  local success = overhaul_career_garage_garageManager.completePurchaseWithNegotiatedPrice(garageId, finalPrice, freezePrice == true, useFinancing == true, selectedTerm)
  if not success then
    log("E", LOG_TAG, "Failed to store negotiated price")
    return
  end

  if freezePrice then
    resetNegotiationState()
  end
end

local function takeTheirOffer()
  if not negotiationActive then return false end
  if not theirOffer or theirOffer <= 0 then return false end

  myOffer = theirOffer
  negotiationStatus = "accepted"
  negotiationToken = negotiationToken + 1
  opponentQuote = opponentPersonality.happyQuotes[math.random(1, #opponentPersonality.happyQuotes)]

  guihooks.trigger(NEGOTIATION_HOOK, getNegotiationState())

  if amISelling then
    local sold = overhaul_career_garage_garageManager.completePropertySaleFromListing(propertyId, theirOffer, opponentPersonality)

    if sold and listedProperties[propertyId] and listingIndex then
      table.remove(listedProperties[propertyId].offers, listingIndex)
      if listedProperties[propertyId].offers and #listedProperties[propertyId].offers == 0 then
        listedProperties[propertyId].timeOfNextOffer = os.time() + timeBetweenOffersBase
      end
    end
    if sold then
      resetNegotiationState()
    end
  else
    completePurchase(propertyId, theirOffer, false, false, nil)
  end

  return true
end

local function freezeCurrentOffer()
  if not negotiationActive then return false end
  if not theirOffer or theirOffer <= 0 then return false end

  if not amISelling then
    completePurchase(propertyId, theirOffer, true)
  end

  return true
end

local function cancelNegotiation()
  if not negotiationActive then return false end

  negotiationStatus = "cancelled"

  guihooks.trigger(NEGOTIATION_HOOK, getNegotiationState())
  guihooks.trigger('ChangeState', {state = 'play', params = {}})

  resetNegotiationState()

  return true
end

local function persistentOwnerPersonality(sellerProfile)
  return {
    archetype = sellerProfile.archetype,
    name = sellerProfile.name,
    isDealership = false,
    startingPatience = sellerProfile.patience or 0.6,
    patienceVariance = 0.05,
    isDesperate = (sellerProfile.archetype == "cash_strapped" and (sellerProfile.willingnessToSell or 0) > 0.65) or false,
    desperation = 0.1,
    desperationMaxDiscount = 0.12,
    insultThresholdBase = 0.9,
    priceMultiplier = 0,
    counterOfferReadiness = 0.55,
    quotesByPriceTier = {
      low = {"I own this place now, so let's keep this realistic."},
      mid = {"I've had this property for a while — make me a fair offer."},
      high = {"This is prime real estate. The price reflects that."}
    },
    insultQuotes = {"I just bought this. That offer doesn't work for me.", "No chance at that price."},
    happyQuotes = {"Deal.", "Alright, we can close at that number."},
    minimumOverMarket = 0,
    maxOverMarket = 0.25,
  }
end

local function fallbackSellerPersonality(sellerProfile)
  return {
    archetype = sellerProfile.archetype or "default_private_seller",
    name = sellerProfile.name or "Property Seller",
    isDealership = sellerProfile.sellerType == "bank",
    startingPatience = sellerProfile.patience or 0.7,
    patienceVariance = 0.08,
    isDesperate = false,
    desperation = 0.05,
    desperationMaxDiscount = 0.05,
    insultThresholdBase = 0.87,
    priceMultiplier = 0,
    counterOfferReadiness = 0.5,
    quotesByPriceTier = {
      low = {"Let's discuss the offer."},
      mid = {"I'm open to a reasonable deal."},
      high = {"This property is priced for its value."}
    },
    insultQuotes = {"That's too low."},
    happyQuotes = {"Deal."},
    minimumOverMarket = 0,
    maxOverMarket = 0.2,
  }
end

local function setPropertyFacts(garageId, garage, marketValue)
  propertyId = garageId
  propertyName = garage.name or "Property"
  propertyPreview = garage.preview or ""
  propertyMarketValue = marketValue
  propertyCapacity = garage.capacity or 0
  propertyParkingSpots = (garage.parkingSpotNames and #garage.parkingSpotNames) or 0
  propertyNeighborhood = garage.neighborhood or (levelData.getMap() or {}).label or ""
end

local function startNegotiateBuying(garageId)
  if require("overhaul/lib/business/bundles").forGarage(garageId) then return false end
  local garage = overhaul_world_facilities.getFacility("garage", garageId)
  if not garage then
    log("E", LOG_TAG, "Garage not found: " .. tostring(garageId))
    return false
  end

  local listedPrice = overhaul_career_garage_garageManager.getGaragePurchasePrice(garageId)
  if not listedPrice or listedPrice == 0 then
    listedPrice = garage.defaultPrice or 0
  end

  local marketValue = listedPrice

  local sellerProfile = overhaul_career_garage_property_propertyOwners.getSellerProfileForNegotiation(garageId, listedPrice)

  if sellerProfile and sellerProfile.isPersistentOwner then
    opponentPersonality = persistentOwnerPersonality(sellerProfile)
    if sellerProfile.startingPrice and sellerProfile.startingPrice > 0 then
      listedPrice = sellerProfile.startingPrice
      marketValue = listedPrice
    end
  elseif sellerProfile then
    opponentPersonality = fallbackSellerPersonality(sellerProfile)
    listedPrice = sellerProfile.startingPrice or listedPrice
    marketValue = listedPrice
  else
    opponentPersonality = generateSellerPersonality()
  end

  setPropertyFacts(garageId, garage, marketValue)

  startingPrice = listedPrice
  negotiationActive = true
  patience = opponentPersonality.startingPatience
  isInsulted = false
  theirOffer = listedPrice
  myOffer = nil
  amISelling = false
  negotiationStatus = "initial"
  offerHistory = {
    { theirOffer = listedPrice, negotiationStatus = "initial" }
  }

  opponentQuote = selectQuoteForPersonality(opponentPersonality, marketValue)

  log("I", LOG_TAG, "Started negotiation for " .. propertyName .. " at $" .. tostring(listedPrice))

  extensions.ui_router.navigate('realEstateNegotiation')
  guihooks.trigger(NEGOTIATION_HOOK, getNegotiationState())

  return true
end

-- Listing pricing ---------------------------------------------------------------------------------

local function getMarketValue(garageId)
  local garage = overhaul_world_facilities.getFacility("garage", garageId)
  local base = garage and garage.defaultPrice or 0
  if base > 0 and overhaul_career_economy_globalEconomy and overhaul_career_economy_globalEconomy.getHousingMarketIndex then
    return math.floor(base * overhaul_career_economy_globalEconomy.getHousingMarketIndex() + 0.5)
  end
  return base
end

-- Hook point for a dynamic housing market: 0.5 is a bad market, 1.5 a hot one, 1.0 normal.
local function getHousingMarketHealth()
  return 1.0
end

local function lerpClamped(fromValue, toValue, fromRatio, toRatio, marketRatio)
  local t = inverseLerp(fromRatio, toRatio, marketRatio)
  return lerp(fromValue, toValue, math.max(0, math.min(1, t)))
end

-- How the asking price compares to market sets offer speed: far below is near instant, far above is very slow.
local function priceOfferTimeMultiplier(marketRatio)
  if marketRatio <= 0.50 then
    return 0.05
  elseif marketRatio < 0.80 then
    return lerpClamped(0.2, 0.05, 0.80, 0.50, marketRatio)
  elseif marketRatio < 0.90 then
    return lerpClamped(0.5, 0.2, 0.90, 0.80, marketRatio)
  elseif marketRatio >= 0.90 and marketRatio <= 1.1 then
    return 1.0
  elseif marketRatio <= 1.3 then
    return lerpClamped(1.0, 2.5, 1.1, 1.3, marketRatio)
  elseif marketRatio <= 1.5 then
    return lerpClamped(2.5, 5.0, 1.3, 1.5, marketRatio)
  end
  return 6.0
end

local function calculateOfferTimeMultiplier(marketRatio)
  local priceMult = priceOfferTimeMultiplier(marketRatio)
  -- A hot market (1.5) waits 0.67x as long; a bad market (0.5) waits twice as long.
  local marketMult = 1.0 / math.max(0.3, getHousingMarketHealth())
  return priceMult * marketMult
end

local function scheduleNextPropertyOffer(listing, timeNow)
  if not listing then return end
  local mult = listing.offerTimeMultiplier or 1
  listing.timeOfNextOffer = timeNow + (timeBetweenOffersBase * mult) + (math.random(-60, 60) / 100 * timeBetweenOffersBase * mult)
end

local function getPriceGuidanceForListing(garageId, askingPrice)
  local marketValue = getMarketValue(garageId)
  local price = tonumber(askingPrice) or 0
  if marketValue <= 0 or price <= 0 then return nil end

  local ratio = price / marketValue
  local tier = "fair"
  local label = "Fair"
  local description = "Should receive normal offer flow."

  if ratio < 0.98 then
    tier = "low"
    label = "Below market"
    description = "Likely to get faster/more offers, but buyers still won't overpay."
  elseif ratio > 1.10 then
    tier = "high"
    label = "Over market"
    description = "Expect fewer offers and more lowball attempts."
  end

  return {
    marketValue = marketValue,
    askingPrice = price,
    marketRatio = ratio,
    tier = tier,
    label = label,
    description = description,
    offerTimeMultiplier = calculateOfferTimeMultiplier(ratio),
  }
end

local function listPropertyForSale(garageId, askingPrice)
  if require("overhaul/lib/business/bundles").forGarage(garageId) then return false end
  if not garageId or not askingPrice then return false end

  local marketValue = getMarketValue(garageId)
  local price = tonumber(askingPrice)
  if not price or price <= 0 or marketValue <= 0 then return false end

  local garage = overhaul_world_facilities.getFacility("garage", garageId)
  if not garage then return false end

  local guidance = getPriceGuidanceForListing(garageId, price)
  if not guidance then return false end

  local now = os.time()
  listedProperties[garageId] = {
    listingTimestamp = now,
    askingPrice = price,
    marketValueAtListing = marketValue,
    marketRatio = guidance.marketRatio,
    offerTimeMultiplier = guidance.offerTimeMultiplier,
    timeOfNextOffer = nil,
    offers = {},
    garageName = garage.name or tostring(garageId),
    preview = garage.preview or "",
  }

  scheduleNextPropertyOffer(listedProperties[garageId], now)
  guihooks.trigger('garageListingsUpdated')
  return true
end

local function removePropertyListing(garageId)
  if not garageId then return false end
  listedProperties[garageId] = nil
  guihooks.trigger('garageListingsUpdated')
  return true
end

local function getPropertyListing(garageId)
  if not garageId then return nil end
  return listedProperties[garageId]
end

local function generateBuyerOffer(garageId)
  local listing = listedProperties[garageId]
  if not listing then return nil end

  local marketValue = getMarketValue(garageId)
  if marketValue <= 0 then marketValue = listing.marketValueAtListing or listing.askingPrice end

  local buyer = generateBuyerPersonality()
  local baseOffer = marketValue
  local personalityMult = buyer.priceMultiplier or 0.9
  local noise = (math.random() * 0.1) + 0.92
  local finalOffer = baseOffer * personalityMult * noise

  local ratio = listing.marketRatio or 1.0
  if ratio < 0.98 then
    finalOffer = math.min(finalOffer, listing.askingPrice)
  elseif ratio > 1.1 then
    local cap = marketValue * (0.90 + math.random() * 0.08)
    finalOffer = math.min(finalOffer, cap)
  else
    finalOffer = math.min(finalOffer, listing.askingPrice * 1.01)
  end

  finalOffer = math.max(1000, math.floor((finalOffer + 500) / 1000) * 1000)

  local offer = {
    timestamp = os.time(),
    value = finalOffer,
    ttl = offerTTL,
    negotiationPossible = true,
    buyerPersonality = buyer,
  }
  table.insert(listing.offers, offer)
  return offer
end

local function notifyNewOffer(garageId, listing, offer)
  local layout = phoneLayout.get()
  if layout and layout.fireNotification then
    layout.fireNotification("realEstate.newOffer", {
      title = "New Property Offer",
      message = listing.garageName or "Property",
      meta = "$" .. tostring(offer.value),
      kind = "invite",
      ttl = 8,
      source = "Real Estate",
      sound = { soundClass = "AudioGui", type = "event:>UI>Missions>Info_Open" },
      entityId = tostring(garageId),
    }, { entityId = tostring(garageId) })
  end
  guihooks.trigger('garageListingsUpdated')
end

local function dropExpiredOffers(listing, now)
  for i = #listing.offers, 1, -1 do
    local offer = listing.offers[i]
    if offer and now - (offer.timestamp or now) > (offer.ttl or offerTTL) then
      table.remove(listing.offers, i)
    end
  end
end

local function generateNewPropertyOffers()
  local now = os.time()
  for garageId, listing in pairs(listedProperties) do
    if not listing.timeOfNextOffer then
      scheduleNextPropertyOffer(listing, now)
    end

    if listing.timeOfNextOffer and now >= listing.timeOfNextOffer then
      listing.timeOfNextOffer = nil
      local offer = generateBuyerOffer(garageId)
      if offer then
        notifyNewOffer(garageId, listing, offer)
      end
    end

    dropExpiredOffers(listing, now)
  end
end

local function startNegotiateSelling(garageId, offerIdx, origin)
  if require("overhaul/lib/business/bundles").forGarage(garageId) then return false end
  if not garageId or not offerIdx then return false end
  local offer, idx = findListedOffer(garageId, offerIdx)
  if not offer then return false end
  if offer.negotiationPossible == false then return false end

  local garage = overhaul_world_facilities.getFacility("garage", garageId)
  if not garage then return false end

  local listing = listedProperties[garageId]
  opponentPersonality = offer.buyerPersonality or generateBuyerPersonality()
  setPropertyFacts(garageId, garage, getMarketValue(garageId))

  listingIndex = idx
  startingPrice = listing.askingPrice or propertyMarketValue
  negotiationActive = true
  amISelling = true
  negotiationOrigin = origin or "computer"
  patience = opponentPersonality.startingPatience or 0.7
  isInsulted = false
  theirOffer = offer.value
  myOffer = startingPrice
  negotiationStatus = "initial"
  offerHistory = {
    { myOffer = myOffer, negotiationStatus = "initial" },
    { theirOffer = theirOffer, negotiationStatus = "initial" },
  }
  opponentQuote = selectQuoteForPersonality(opponentPersonality, propertyMarketValue)

  extensions.ui_router.navigate('realEstateNegotiation')
  guihooks.trigger(NEGOTIATION_HOOK, getNegotiationState())
  return true
end

-- Save and load -----------------------------------------------------------------------------------

local function activeNegotiationSnapshot()
  if not negotiationActive then return {negotiationActive = false} end
  return {
    negotiationActive = negotiationActive,
    amISelling = amISelling,
    propertyId = propertyId,
    propertyName = propertyName,
    propertyPreview = propertyPreview,
    propertyMarketValue = propertyMarketValue,
    propertyCapacity = propertyCapacity,
    propertyParkingSpots = propertyParkingSpots,
    propertyNeighborhood = propertyNeighborhood,
    startingPrice = startingPrice,
    patience = patience,
    isInsulted = isInsulted,
    myOffer = myOffer,
    theirOffer = theirOffer,
    negotiationStatus = negotiationStatus,
    offerHistory = offerHistory,
    opponentPersonality = opponentPersonality,
    opponentQuote = opponentQuote,
    listingIndex = listingIndex,
    negotiationOrigin = negotiationOrigin,
  }
end

-- Reply jobs do not survive loading a save, so a pending reply falls back to the last settled status.
local function settleInterruptedReply()
  if negotiationStatus ~= "thinking" and negotiationStatus ~= "typing" then return end
  negotiationStatus = "initial"
  for i = #offerHistory, 1, -1 do
    local entryStatus = offerHistory[i] and offerHistory[i].negotiationStatus
    if entryStatus and entryStatus ~= "thinking" and entryStatus ~= "typing" then
      negotiationStatus = entryStatus
      break
    end
  end
end

local function restoreActiveNegotiation(data)
  negotiationActive = data.negotiationActive
  amISelling = data.amISelling or false
  propertyId = data.propertyId
  propertyName = data.propertyName or ""
  propertyPreview = data.propertyPreview or ""
  propertyMarketValue = data.propertyMarketValue or 0
  propertyCapacity = data.propertyCapacity or 0
  propertyParkingSpots = data.propertyParkingSpots or 0
  propertyNeighborhood = data.propertyNeighborhood or ""
  startingPrice = data.startingPrice or 0
  patience = data.patience or 1.0
  isInsulted = data.isInsulted or false
  myOffer = data.myOffer
  theirOffer = data.theirOffer or 0
  negotiationStatus = data.negotiationStatus or "initial"
  offerHistory = data.offerHistory or {}
  settleInterruptedReply()
  opponentPersonality = data.opponentPersonality
  opponentQuote = data.opponentQuote or ""
  listingIndex = data.listingIndex
end

-- Only listings for garages still owned by this profile survive a load.
local function restoreOwnedListings(listingsData)
  listedProperties = {}
  for garageId, listing in pairs(listingsData) do
    if listing and overhaul_career_garage_garageManager.isPurchasedGarage(garageId) then
      listedProperties[garageId] = listing
    end
  end
end

local function loadNegotiationState()
  if not overhaul_career_career.isActive() then return end
  local _, currentSavePath = overhaul_career_saveSystem.getCurrentProfile()
  if not currentSavePath then return end
  resetNegotiationState()
  listedProperties = {}

  local data = jsonReadFile(currentSavePath .. SAVE_SUBDIR .. "/realEstateNegotiationState.json")
  if data and data.negotiationActive then
    restoreActiveNegotiation(data)
  end

  local listingsData = jsonReadFile(currentSavePath .. SAVE_SUBDIR .. "/realEstateListings.json")
  if listingsData then
    restoreOwnedListings(listingsData)
  end
  negotiationOrigin = (data and data.negotiationActive and data.negotiationOrigin) or "computer"
end

local function onOverhaulSaveCurrentProfile(currentSavePath, _, writer)
  writer = writer or overhaul_career_saveSystem.getSaveWriter()
  -- Always write the state so an older file in this rotated slot cannot reopen a finished negotiation.
  local stateDir = ensureDir.directory(writer, currentSavePath .. SAVE_SUBDIR)
  overhaul_career_saveSystem.jsonWriteFileSafe(stateDir .. "/realEstateNegotiationState.json", activeNegotiationSnapshot(), true)

  -- Listings persist independently of an active negotiation.
  local listingsDir = ensureDir.directory(writer, currentSavePath .. SAVE_SUBDIR)
  overhaul_career_saveSystem.jsonWriteFileSafe(listingsDir .. "/realEstateListings.json", listedProperties or {}, true)
end

-- Update and lifecycle ----------------------------------------------------------------------------

local function onUpdate(dtReal, dtSim)
  offerUpdateAccumulator = offerUpdateAccumulator + (dtSim or 0)
  if offerUpdateAccumulator < OFFER_POLL_INTERVAL_S then return end
  offerUpdateAccumulator = 0
  generateNewPropertyOffers()
end

local function onCareerActivated()
  loadNegotiationState()
end

local function onExtensionLoaded()
  loadNegotiationState()
end

local function onOverhaulActive(active)
  if active then return end
  resetNegotiationState()
  listedProperties = {}
end

-- Public API: negotiation -------------------------------------------------------------------------

M.startNegotiateBuying = startNegotiateBuying
M.startNegotiateSelling = startNegotiateSelling
M.makeOffer = makeOffer
M.takeTheirOffer = takeTheirOffer
M.freezeCurrentOffer = freezeCurrentOffer
M.cancelNegotiation = cancelNegotiation
M.getNegotiationState = getNegotiationState
M.completePurchase = completePurchase

-- Public API: listings ----------------------------------------------------------------------------

M.listPropertyForSale = listPropertyForSale
M.removePropertyListing = removePropertyListing
M.getPropertyListing = getPropertyListing
M.getPriceGuidanceForListing = getPriceGuidanceForListing
M.generateNewPropertyOffers = generateNewPropertyOffers

-- Game hooks --------------------------------------------------------------------------------------

M.onUpdate = onUpdate
M.onOverhaulSaveCurrentProfile = onOverhaulSaveCurrentProfile
M.onCareerActivated = onCareerActivated
M.onExtensionLoaded = onExtensionLoaded
M.onOverhaulActive = onOverhaulActive

return M
