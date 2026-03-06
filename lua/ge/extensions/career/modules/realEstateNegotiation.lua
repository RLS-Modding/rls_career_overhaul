-- Real Estate Negotiation Module
-- Handles buying/selling property with AI negotiation

local M = {}
M.dependencies = { 'career_career', 'career_saveSystem', 'freeroam_facilities', 'career_modules_garageManager', 'career_modules_propertyOwners', 'career_modules_propertyMortgage' }

-- Negotiation state (in-memory, persisted to save file)
local negotiationActive = false
local amISelling = false              -- false = buying, true = selling
local startingPrice = 0
local patience = 1.0
local isInsulted = false
local myOffer = nil
local theirOffer = 0
local offerHistory = {}
local negotiationStatus = "initial"
local opponentPersonality = nil
local opponentQuote = ""

-- Property-specific data
local propertyId = nil                -- garageId being negotiated
local propertyName = ""
local propertyPreview = ""
local propertyMarketValue = 0
local propertyCapacity = 0
local propertyParkingSpots = 0
local propertyNeighborhood = ""

-- Selling-side data (Phase 2)
local listingIndex = nil              -- Index into listedProperties[propertyId].offers
local listedProperties = {}           -- [garageId] = { listingTimestamp, askingPrice, offers, ... }
local completePurchase
local resetNegotiationState
local markOfferAsNoDeal
local markOfferAsAccepted
local negotiationOrigin = "computer"

-- Constants
local timeBetweenOffersBase = 190  -- ~2x vehicle offer timing (vehicles = 95s)
local offerTTL = 1000              -- ~2x vehicle TTL (vehicles = 500s)
local CLOSING_FEE_RATE = 0.03      -- 3%
local PROPERTY_TAX_RATE = 0.012     -- 1.2% annualized estimate

-- ────────────────────────────────────────────────────────────────────────────
-- PERSONALITY GENERATION
-- ────────────────────────────────────────────────────────────────────────────

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
      low = {"Let's discuss the price."},
      mid = {"I'm open to reasonable offers."},
      high = {"This is a valuable property."}
    },
    insultQuotes = {"That's way too low."},
    happyQuotes = {"Deal."},
    minimumOverMarket = 0,
  }
end

local function generateSellerPersonality()
  local data = jsonReadFile("levels/west_coast_usa/facilities/realEstatePersonalities.json")
  if not data or not data.randomSellerArchetypes or not data.archetypes then
    log("W", "realEstateNegotiation", "Could not load realEstatePersonalities.json, using default")
    return getDefaultSellerPersonality()
  end

  local archetypeKeys = data.randomSellerArchetypes or {}
  if #archetypeKeys == 0 then
    log("W", "realEstateNegotiation", "No seller archetypes found, using default")
    return getDefaultSellerPersonality()
  end

  local chosenKey = archetypeKeys[math.random(1, #archetypeKeys)]
  local archetype = data.archetypes[chosenKey]
  if not archetype then
    log("W", "realEstateNegotiation", "Archetype not found: " .. chosenKey .. ", using default")
    return getDefaultSellerPersonality()
  end

  local isDesperate = math.random() < (archetype.desperation or 0.05)
  local baseThreshold = archetype.insultThresholdBase or 0.85
  local variance = archetype.insultThresholdVariance or 0.03
  local insultThreshold = baseThreshold + (math.random() * variance * 2 - variance)

  local basePatience = archetype.startingPatience or 0.8
  local patienceVariance = archetype.patienceVariance or 0.1
  local patienceRoll = math.max(0.3, math.min(1.0, basePatience + (math.random() * patienceVariance * 2 - patienceVariance)))

  local name = "Private Seller"
  if archetype.isDealership then
    if archetype.names and #archetype.names > 0 then
      name = archetype.names[math.random(1, #archetype.names)]
    else
      name = "Property Manager"
    end
  elseif career_modules_marketplace then
    local firstNames = career_modules_marketplace.firstNames
    local initials = career_modules_marketplace.initials
    if firstNames and #firstNames > 0 then
      name = firstNames[math.random(1, #firstNames)]
      if initials and #initials > 0 then
        name = name .. " " .. initials[math.random(1, #initials)] .. "."
      end
    end
  end

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
  local data = jsonReadFile("levels/west_coast_usa/facilities/realEstatePersonalities.json")
  if not data or not data.randomBuyerArchetypes or not data.archetypes then
    return getDefaultSellerPersonality()
  end

  local archetypeKeys = data.randomBuyerArchetypes or {}
  if #archetypeKeys == 0 then
    return getDefaultSellerPersonality()
  end

  local chosenKey = archetypeKeys[math.random(1, #archetypeKeys)]
  local archetype = data.archetypes[chosenKey] or {}

  local name = "Buyer"
  if archetype.names and #archetype.names > 0 then
    name = archetype.names[math.random(1, #archetype.names)]
  elseif career_modules_marketplace and career_modules_marketplace.firstNames then
    local firstNames = career_modules_marketplace.firstNames
    local initials = career_modules_marketplace.initials
    if firstNames and #firstNames > 0 then
      name = firstNames[math.random(1, #firstNames)]
      if initials and #initials > 0 then
        name = name .. " " .. initials[math.random(1, #initials)] .. "."
      end
    end
  end

  local basePatience = archetype.startingPatience or 0.7
  local patienceVariance = archetype.patienceVariance or 0.1
  local patienceRoll = math.max(0.3, math.min(1.0, basePatience + (math.random() * patienceVariance * 2 - patienceVariance)))

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

-- ────────────────────────────────────────────────────────────────────────────
-- QUOTE SELECTION
-- ────────────────────────────────────────────────────────────────────────────

local function selectQuoteForPersonality(personality, propertyValue, isBuyer)
  if not personality then
    log("W", "realEstateNegotiation", "selectQuoteForPersonality: personality is nil")
    return "Let's discuss the price."
  end

  if not propertyValue or propertyValue <= 0 then
    log("W", "realEstateNegotiation", "selectQuoteForPersonality: invalid property value")
    return "Let's discuss the price."
  end

  -- Determine price tier for real estate (higher thresholds than vehicles)
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

  -- Fallback if no quotes found for tier
  log("W", "realEstateNegotiation", "No quotes found for tier: " .. priceTier)
  return "Let's discuss the price."
end

-- ────────────────────────────────────────────────────────────────────────────
-- UI BRIDGE
-- ────────────────────────────────────────────────────────────────────────────

local function getNegotiationState()
  local mortgageAvailable = (career_modules_propertyMortgage and career_modules_propertyMortgage.isMortgageAvailable and career_modules_propertyMortgage.isMortgageAvailable()) or false
  local mortgageDetails = (career_modules_propertyMortgage and career_modules_propertyMortgage.getMortgageOfferDetails and career_modules_propertyMortgage.getMortgageOfferDetails()) or nil

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

local function markOfferAsNoDeal()
  if not amISelling or not propertyId or not listingIndex then
    return false
  end

  local listing = listedProperties[propertyId]
  if not listing or not listing.offers then
    return false
  end

  local idx = tonumber(listingIndex)
  if not idx or idx < 1 or idx > #listing.offers then
    return false
  end

  local offer = listing.offers[idx]
  if not offer then
    return false
  end

  offer.negotiationPossible = false
  offer.negotiatedPrice = nil

  return true
end

markOfferAsAccepted = function()
  if not amISelling or not propertyId or not listingIndex then return false end
  local listing = listedProperties[propertyId]
  if not listing or not listing.offers then return false end
  local idx = tonumber(listingIndex)
  if not idx or idx < 1 or idx > #listing.offers then return false end
  local offer = listing.offers[idx]
  if not offer then return false end
  offer.negotiatedPrice = theirOffer
  offer.negotiationPossible = false
  return true
end

local function calculateClosingFee(price)
  if not price or price <= 0 then return 0 end
  return math.floor((price * CLOSING_FEE_RATE) + 0.5)
end

local function calculateAnnualPropertyTax(price)
  if not price or price <= 0 then return 0 end
  return math.floor((price * PROPERTY_TAX_RATE) + 0.5)
end

-- ────────────────────────────────────────────────────────────────────────────
-- NEGOTIATION LOGIC (BUYING SIDE)
-- ────────────────────────────────────────────────────────────────────────────

local function calculatePatienceDrop(myOfferAmount, theirOfferAmount, marketValue, personality)
  local gapFromTheirOffer = math.abs(myOfferAmount - theirOfferAmount)
  local gapPct = (gapFromTheirOffer / theirOfferAmount) * 100
  
  -- Real estate: slower patience decay than vehicles
  local percentagePatienceDrop = gapPct * 1.5  -- vs 2.5-3 for vehicles
  local absolutePatienceDrop = (gapFromTheirOffer / 1000) * 4  -- vs 6-8 for vehicles
  
  -- Price scaling: high-value properties use percentage more
  local priceScale = math.min(1, marketValue / 100000)
  local percentageWeight = priceScale
  local absoluteWeight = 1 - priceScale
  
  -- Institutional sellers (banks, property managers) lose patience even slower
  local institutionalModifier = personality.isDealership and 0.5 or 1.0
  
  local patienceDrop = ((percentagePatienceDrop * percentageWeight + absolutePatienceDrop * absoluteWeight) * institutionalModifier) + math.random() * 8
  
  return patienceDrop / 100  -- Convert to 0–1 scale
end

local function generateCounterOffer(myOfferAmount, theirOfferAmount, currentPatience, personality)
  local diff = theirOfferAmount - myOfferAmount
  
  -- High patience = smaller moves (dragging out negotiation, maximizing price)
  -- Low patience = bigger jumps (trying to close faster)
  local baseMovePercent = (1 - currentPatience) * 0.3 + 0.20  -- High patience = 20%, low = 50%
  local randomBoost = (math.random() * 0.12 - 0.06)  -- ±6% randomness
  local noisePercent = (math.random() * 0.15 - 0.075)  -- ±7.5% randomness
  local movePercent = baseMovePercent + randomBoost + noisePercent
  movePercent = math.max(0.15, math.min(0.50, movePercent))  -- Clamp to 15–50%
  
  local counterAmount = myOfferAmount + (math.abs(diff) * movePercent)
  return math.max(myOfferAmount, math.floor(counterAmount / 100 + 0.5) * 100)  -- Round to nearest $100
end

local function isOfferAllowed(price)
  if not negotiationActive then return false end
  if negotiationStatus == "accepted" or negotiationStatus == "failed" then return false end
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

local function makeOffer(price)
  if not isOfferAllowed(price) then
    log("W", "realEstateNegotiation", "Offer not allowed: " .. tostring(price))
    return false
  end

  myOffer = price
  table.insert(offerHistory, { myOffer = myOffer })
  negotiationStatus = "thinking"
  guihooks.trigger('realEstateNegotiationData', getNegotiationState())

  core_jobsystem.create(function(job)
    local thinkingTime = 2.5 + math.random() * 2.0
    job.sleep(thinkingTime)
    negotiationStatus = "typing"
    guihooks.trigger('realEstateNegotiationData', getNegotiationState())
    job.sleep(thinkingTime)

    if amISelling then
      local askGap = math.abs(myOffer - theirOffer)
      local askGapPct = (askGap / math.max(1, theirOffer)) * 100
      local patienceDrop = ((askGapPct * 1.2) + (askGap / 1000) * 3 + math.random() * 6) / 100
      patience = math.max(0, patience - patienceDrop)

      local maxOver = opponentPersonality.maxOverMarket or 0
      local desperationBonus = opponentPersonality.isDesperate and 0.03 or 0
      local maxWillingToPay = propertyMarketValue * (1 + maxOver + desperationBonus)
      local acceptanceBuffer = 0.04 + ((1 - patience) * 0.05)
      local acceptanceThreshold = maxWillingToPay * (1 - (acceptanceBuffer * (0.96 + math.random() * 0.08)))

      if myOffer > maxWillingToPay then
        if patience <= 0 then
          negotiationStatus = "failed"
          opponentQuote = "I can't go that high."
          markOfferAsNoDeal()
        else
          local diff = myOffer - theirOffer
          local movePercent = math.max(0.20, math.min(0.55, ((1 - patience) * 0.30 + 0.20) + (math.random() * 0.1 - 0.05)))
          local counter = theirOffer + (diff * movePercent) + (diff * (math.random() * 0.14 - 0.07))
          counter = math.min(maxWillingToPay, math.floor(counter / 100 + 0.5) * 100)

          if counter <= theirOffer then
            negotiationStatus = "failed"
            opponentQuote = "I can't go that high."
            markOfferAsNoDeal()
          else
            theirOffer = counter
            negotiationStatus = patience <= 0.12 and "counterOfferLastChance" or "counterOffer"
            opponentQuote = selectQuoteForPersonality(opponentPersonality, propertyMarketValue, true)
          end
        end
      elseif myOffer >= acceptanceThreshold then
        theirOffer = myOffer
        negotiationStatus = "accepted"
        opponentQuote = opponentPersonality.happyQuotes[math.random(1, #opponentPersonality.happyQuotes)]
        markOfferAsAccepted()
      else
        local diff = myOffer - theirOffer
        local movePercent = math.max(0.15, math.min(0.45, ((1 - patience) * 0.30 + 0.20) + (math.random() * 0.1 - 0.05)))
        local counter = theirOffer + (diff * movePercent) + (diff * (math.random() * 0.14 - 0.07))
        counter = math.min(maxWillingToPay, math.floor(counter / 100 + 0.5) * 100)

        if counter >= myOffer then
          theirOffer = myOffer
          negotiationStatus = "accepted"
          opponentQuote = "That works for me."
          markOfferAsAccepted()
        elseif counter <= theirOffer then
          negotiationStatus = "failed"
          opponentQuote = "That's my final number."
          markOfferAsNoDeal()
        else
          theirOffer = counter
          negotiationStatus = patience <= 0.12 and "counterOfferLastChance" or "counterOffer"
          opponentQuote = selectQuoteForPersonality(opponentPersonality, propertyMarketValue, true)
        end
      end
    else
      -- No hard rejection — lowball offers just cause bigger patience hits
      -- The further below their threshold, the angrier they get
      local thresholdPrice = startingPrice * (opponentPersonality.insultThresholdBase or 0.85)
      local patienceChange = calculatePatienceDrop(myOffer, theirOffer, propertyMarketValue, opponentPersonality)
      
      if myOffer < thresholdPrice then
        -- Extra patience penalty for offers below their comfort zone
        local howFarBelow = (thresholdPrice - myOffer) / thresholdPrice
        local extraPenalty = howFarBelow * 0.4  -- up to 40% extra patience loss for extreme lowballs
        patienceChange = patienceChange + extraPenalty
        -- Use an annoyed quote but don't instantly fail
        opponentQuote = opponentPersonality.insultQuotes[math.random(1, #opponentPersonality.insultQuotes)]
      end
      patience = math.max(0, patience - patienceChange)

      local absoluteMinimum
      if opponentPersonality.isDesperate then
        local maxDiscount = opponentPersonality.desperationMaxDiscount or 0.05
        absoluteMinimum = propertyMarketValue * (1 - maxDiscount)
      else
        local maxPossibleDiscount = startingPrice
        local negotiationRange = math.min(math.max(0, startingPrice - propertyMarketValue), maxPossibleDiscount)
        local patienceMultiplier = patience * 0.7
        local willingToNegotiate = negotiationRange * patienceMultiplier
        absoluteMinimum = startingPrice - willingToNegotiate
      end

      if patience <= 0 then
        negotiationStatus = "failed"
        opponentQuote = "I'm not interested in continuing this negotiation."
        theirOffer = startingPrice
        if career_modules_garageManager and career_modules_garageManager.setNegotiationCooldown then
          career_modules_garageManager.setNegotiationCooldown(propertyId)
        end
        markOfferAsNoDeal()
      elseif myOffer >= absoluteMinimum then
        theirOffer = myOffer
        negotiationStatus = "accepted"
        if myOffer > (absoluteMinimum * 1.05) then
          opponentQuote = opponentPersonality.happyQuotes[math.random(1, #opponentPersonality.happyQuotes)]
        else
          opponentQuote = "Alright, we have a deal."
        end
      else
        local counter = generateCounterOffer(myOffer, theirOffer, patience, opponentPersonality)
        if counter <= myOffer then
          theirOffer = myOffer
          negotiationStatus = "accepted"
          opponentQuote = "That works for me."
        else
          theirOffer = counter
          if patience <= 0.05 then
            negotiationStatus = "counterOfferLastChance"
            opponentQuote = "This is my final offer. Take it or leave it."
          else
            negotiationStatus = "counterOffer"
            opponentQuote = selectQuoteForPersonality(opponentPersonality, propertyMarketValue, false)
          end
        end
      end
    end

    table.insert(offerHistory, { theirOffer = theirOffer, negotiationStatus = negotiationStatus })
    guihooks.trigger('realEstateNegotiationData', getNegotiationState())
  end)

  return true
end

local function takeTheirOffer()
  if not negotiationActive then return false end
  if not theirOffer or theirOffer <= 0 then return false end

  myOffer = theirOffer
  negotiationStatus = "accepted"
  opponentQuote = opponentPersonality.happyQuotes[math.random(1, #opponentPersonality.happyQuotes)]

  guihooks.trigger('realEstateNegotiationData', getNegotiationState())

  if amISelling then
    local sold = false
    if career_modules_garageManager and career_modules_garageManager.completePropertySaleFromListing then
      sold = career_modules_garageManager.completePropertySaleFromListing(propertyId, theirOffer, opponentPersonality)
    end

    if sold and listedProperties[propertyId] and listingIndex then
      table.remove(listedProperties[propertyId].offers, listingIndex)
      if listedProperties[propertyId].offers and #listedProperties[propertyId].offers == 0 then
        listedProperties[propertyId].timeOfNextOffer = os.time() + timeBetweenOffersBase
      end
    end
  else
    completePurchase(propertyId, theirOffer, false, false, nil)
  end

  return true
end

local function freezeCurrentOffer()
  if not negotiationActive then return false end
  if not theirOffer or theirOffer <= 0 then return false end
  
  -- Freeze current offer without accepting (for later purchase)
  if not amISelling then
    completePurchase(propertyId, theirOffer, true)
  end
  
  return true
end

resetNegotiationState = function()
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

local function cancelNegotiation()
  if not negotiationActive then return false end
  
  negotiationStatus = "cancelled"
  
  guihooks.trigger('realEstateNegotiationData', getNegotiationState())
  guihooks.trigger('ChangeState', {state = 'play', params = {}})
  
  resetNegotiationState()
  
  return true
end

completePurchase = function(garageId, finalPrice, freezePrice, useFinancing, selectedTerm)
  if not garageId or not finalPrice then
    log("E", "realEstateNegotiation", "completePurchase: missing garageId or finalPrice")
    return
  end
  
  -- Call garageManager to store the negotiated price and return to listing
  if not career_modules_garageManager then
    log("E", "realEstateNegotiation", "completePurchase: garageManager module not loaded")
    return
  end
  
  if not career_modules_garageManager.completePurchaseWithNegotiatedPrice then
    log("E", "realEstateNegotiation", "completePurchaseWithNegotiatedPrice not available")
    return
  end
  
  local success = career_modules_garageManager.completePurchaseWithNegotiatedPrice(garageId, finalPrice, freezePrice == true, useFinancing == true, selectedTerm)
  if not success then
    log("E", "realEstateNegotiation", "Failed to store negotiated price")
    return
  end
  
  if freezePrice then
    resetNegotiationState()
  end
end

local function startNegotiateBuying(garageId)
  local garage = freeroam_facilities.getFacility("garage", garageId)
  if not garage then
    log("E", "realEstateNegotiation", "Garage not found: " .. tostring(garageId))
    return false
  end
  
  -- Get the current market price
  local listedPrice = 0
  if career_modules_garageManager and career_modules_garageManager.getGaragePurchasePrice then
    listedPrice = career_modules_garageManager.getGaragePurchasePrice(garageId)
  end
  if not listedPrice or listedPrice == 0 then
    listedPrice = garage.defaultPrice or 0
  end
  
  local marketValue = listedPrice  -- In Phase 1, listed price = market value
  
  local sellerProfile = nil
  if career_modules_propertyOwners and career_modules_propertyOwners.getSellerProfileForNegotiation then
    sellerProfile = career_modules_propertyOwners.getSellerProfileForNegotiation(garageId, listedPrice)
  end

  -- Generate seller personality / persistent owner profile
  if sellerProfile and sellerProfile.isPersistentOwner then
    opponentPersonality = {
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
    if sellerProfile.startingPrice and sellerProfile.startingPrice > 0 then
      listedPrice = sellerProfile.startingPrice
      marketValue = listedPrice
    end
  elseif sellerProfile then
    opponentPersonality = {
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
    listedPrice = sellerProfile.startingPrice or listedPrice
    marketValue = listedPrice
  else
    opponentPersonality = generateSellerPersonality()
  end

  -- Initialize negotiation state
  propertyId = garageId
  propertyName = garage.name or "Property"
  propertyPreview = garage.preview or ""
  propertyMarketValue = marketValue
  propertyCapacity = garage.capacity or 0
  propertyParkingSpots = (garage.parkingSpotNames and #garage.parkingSpotNames) or 0
  propertyNeighborhood = "West Coast"  -- placeholder until propertyMarket module
  
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
  
  -- Select opening quote
  opponentQuote = selectQuoteForPersonality(opponentPersonality, marketValue, false)
  
  log("I", "realEstateNegotiation", "Started negotiation for " .. propertyName .. " at $" .. tostring(listedPrice))
  
  guihooks.trigger('ChangeState', {state = 'realEstateNegotiation', params = {}})
  guihooks.trigger('realEstateNegotiationData', getNegotiationState())
  
  return true
end

-- ────────────────────────────────────────────────────────────────────────────
-- NEGOTIATION LOGIC (SELLING SIDE)
-- ────────────────────────────────────────────────────────────────────────────

local function getMarketValue(garageId)
  local garage = freeroam_facilities.getFacility("garage", garageId)
  local base = garage and garage.defaultPrice or 0
  if base > 0 and career_modules_globalEconomy and career_modules_globalEconomy.getHousingMarketIndex then
    return math.floor(base * career_modules_globalEconomy.getHousingMarketIndex() + 0.5)
  end
  return base
end

local function getHousingMarketHealth()
  -- Hook point for dynamic housing market (globalEconomy.housingMarket.index)
  -- Returns 0.5 (bad market) to 1.5 (hot market), 1.0 = normal
  -- TODO: integrate with career_modules_propertyMarket when available
  if career_modules_propertyMarket and career_modules_propertyMarket.getMarketIndex then
    return career_modules_propertyMarket.getMarketIndex() or 1.0
  end
  return 1.0
end

local function calculateOfferTimeMultiplier(marketRatio)
  -- Price-based: how the listing price compares to market value
  local priceMult
  if marketRatio <= 0.50 then
    priceMult = 0.05  -- 50%+ below market: offers almost instant
  elseif marketRatio < 0.80 then
    local t = inverseLerp(0.80, 0.50, marketRatio)
    priceMult = lerp(0.2, 0.05, math.max(0, math.min(1, t)))
  elseif marketRatio < 0.90 then
    local t = inverseLerp(0.90, 0.80, marketRatio)
    priceMult = lerp(0.5, 0.2, math.max(0, math.min(1, t)))
  elseif marketRatio >= 0.90 and marketRatio <= 1.1 then
    priceMult = 1.0  -- Fair price: normal offer speed
  elseif marketRatio <= 1.3 then
    local t = inverseLerp(1.1, 1.3, marketRatio)
    priceMult = lerp(1.0, 2.5, math.max(0, math.min(1, t)))
  elseif marketRatio <= 1.5 then
    local t = inverseLerp(1.3, 1.5, marketRatio)
    priceMult = lerp(2.5, 5.0, math.max(0, math.min(1, t)))
  else
    priceMult = 6.0  -- 50%+ above market: very slow offers
  end

  -- Market health: hot market = faster offers, bad market = slower
  local marketHealth = getHousingMarketHealth()
  local marketMult = 1.0 / math.max(0.3, marketHealth)  -- hot market (1.5) → 0.67x time, bad market (0.5) → 2x time

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
  if not garageId or not askingPrice then return false end

  local marketValue = getMarketValue(garageId)
  local price = tonumber(askingPrice)
  if not price or price <= 0 or marketValue <= 0 then return false end

  local garage = freeroam_facilities.getFacility("garage", garageId)
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
        guihooks.trigger("toastrMsg", { type = "info", title = "New property offer", msg = (listing.garageName or "Property") .. ": $" .. tostring(offer.value) })
        guihooks.trigger('garageListingsUpdated')
      end
    end

    for i = #listing.offers, 1, -1 do
      local offer = listing.offers[i]
      if offer and now - (offer.timestamp or now) > (offer.ttl or offerTTL) then
        table.remove(listing.offers, i)
      end
    end
  end
end

local offerUpdateAccumulator = 0
local function onUpdate(dtReal, dtSim)
  offerUpdateAccumulator = offerUpdateAccumulator + (dtSim or 0)
  if offerUpdateAccumulator < 5 then return end
  offerUpdateAccumulator = 0
  generateNewPropertyOffers()
end

local function startNegotiateSelling(garageId, offerIdx, origin)
  if not garageId or not offerIdx then return false end
  local listing = listedProperties[garageId]
  if not listing or not listing.offers then return false end

  local idx = tonumber(offerIdx)
  if not idx or idx < 1 or idx > #listing.offers then return false end

  local offer = listing.offers[idx]
  if not offer then return false end
  if offer.negotiationPossible == false then
    return false
  end

  local garage = freeroam_facilities.getFacility("garage", garageId)
  if not garage then return false end

  opponentPersonality = offer.buyerPersonality or generateBuyerPersonality()
  propertyId = garageId
  propertyName = garage.name or "Property"
  propertyPreview = garage.preview or ""
  propertyMarketValue = getMarketValue(garageId)
  propertyCapacity = garage.capacity or 0
  propertyParkingSpots = (garage.parkingSpotNames and #garage.parkingSpotNames) or 0
  propertyNeighborhood = "West Coast"

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
  opponentQuote = selectQuoteForPersonality(opponentPersonality, propertyMarketValue, true)

  guihooks.trigger('ChangeState', {state = 'realEstateNegotiation', params = {}})
  guihooks.trigger('realEstateNegotiationData', getNegotiationState())
  return true
end

-- ────────────────────────────────────────────────────────────────────────────
-- SAVE/LOAD
-- ────────────────────────────────────────────────────────────────────────────

local function onSaveCurrentSaveSlot(currentSavePath)
  -- Save negotiation state if active
  if negotiationActive then
    local dirPath = currentSavePath .. "/career/rls_career"
    if not FS:directoryExists(dirPath) then
      FS:directoryCreate(dirPath)
    end
    
    local data = {
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
    
    career_saveSystem.jsonWriteFileSafe(dirPath .. "/realEstateNegotiationState.json", data, true)
  end
  
  -- Save listings (Phase 2)
  if next(listedProperties) then
    local dirPath = currentSavePath .. "/career/rls_career"
    if not FS:directoryExists(dirPath) then
      FS:directoryCreate(dirPath)
    end
    career_saveSystem.jsonWriteFileSafe(dirPath .. "/realEstateListings.json", listedProperties, true)
  end
end

local function loadNegotiationState()
  if not career_career.isActive() then return end
  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  if not currentSavePath then return end
  
  local filePath = currentSavePath .. "/career/rls_career/realEstateNegotiationState.json"
  local data = jsonReadFile(filePath)
  if data and data.negotiationActive then
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
    opponentPersonality = data.opponentPersonality
    opponentQuote = data.opponentQuote or ""
    listingIndex = data.listingIndex
  end
  
  -- Load listings (Phase 2)
  local listingsPath = currentSavePath .. "/career/rls_career/realEstateListings.json"
  local listingsData = jsonReadFile(listingsPath)
  if listingsData then
    listedProperties = listingsData
  end
  negotiationOrigin = (data and data.negotiationOrigin) and data.negotiationOrigin or "computer"
end

local function onCareerActivated()
  loadNegotiationState()
end

local function onExtensionLoaded()
  loadNegotiationState()
end

-- ────────────────────────────────────────────────────────────────────────────
-- PUBLIC API
-- ────────────────────────────────────────────────────────────────────────────

M.startNegotiateBuying = startNegotiateBuying
M.startNegotiateSelling = startNegotiateSelling
M.makeOffer = makeOffer
M.takeTheirOffer = takeTheirOffer
M.freezeCurrentOffer = freezeCurrentOffer
M.cancelNegotiation = cancelNegotiation
M.getNegotiationState = getNegotiationState
M.completePurchase = completePurchase

-- Selling-side listing API
M.listPropertyForSale = listPropertyForSale
M.removePropertyListing = removePropertyListing
M.getPropertyListing = getPropertyListing
M.getPriceGuidanceForListing = getPriceGuidanceForListing
M.generateNewPropertyOffers = generateNewPropertyOffers
M.onUpdate = onUpdate

-- Save/load hooks
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot
M.onCareerActivated = onCareerActivated
M.onExtensionLoaded = onExtensionLoaded

return M
