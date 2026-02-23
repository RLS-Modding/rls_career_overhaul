-- Real Estate Negotiation Module
-- Handles buying/selling property with AI negotiation

local M = {}
M.dependencies = { 'career_career', 'career_saveSystem', 'freeroam_facilities', 'career_modules_garageManager' }

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

-- Constants
local SIM_SECONDS_PER_GAME_DAY = 1200
local timeBetweenOffersBase = 5 * SIM_SECONDS_PER_GAME_DAY  -- 5 game days
local offerTTL = 10 * SIM_SECONDS_PER_GAME_DAY              -- 10 game days
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
  
  -- Roll desperation once per negotiation
  local isDesperate = math.random() < (archetype.desperation or 0.05)
  
  -- Roll insult threshold once per negotiation
  local baseThreshold = archetype.insultThresholdBase or 0.85
  local variance = archetype.insultThresholdVariance or 0.03
  local insultThreshold = baseThreshold + (math.random() * variance * 2 - variance)
  
  -- Roll patience with variance
  local basePatience = archetype.startingPatience or 0.8
  local patienceVariance = archetype.patienceVariance or 0.1
  local patienceRoll = math.max(0.3, math.min(1.0, basePatience + (math.random() * patienceVariance * 2 - patienceVariance)))
  
  -- Generate name
  local name
  if archetype.isDealership then
    if archetype.names and #archetype.names > 0 then
      name = archetype.names[math.random(1, #archetype.names)]
    else
      name = "Property Manager"
    end
  else
    -- Use first name pool from marketplace if available
    if career_modules_marketplace then
      local firstNames = career_modules_marketplace.firstNames
      local initials = career_modules_marketplace.initials
      if firstNames and #firstNames > 0 then
        name = firstNames[math.random(1, #firstNames)]
        if initials and #initials > 0 then
          name = name .. " " .. initials[math.random(1, #initials)] .. "."
        end
      else
        name = "Private Seller"
      end
    else
      name = "Private Seller"
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
  }
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
  local movePercent = baseMovePercent + (math.random() * 0.1 - 0.05)  -- ±5% randomness
  movePercent = math.max(0.15, math.min(0.50, movePercent))  -- Clamp to 15–50%
  
  local counterAmount = myOfferAmount + (math.abs(diff) * movePercent)
  return math.max(myOfferAmount, math.floor(counterAmount / 100 + 0.5) * 100)  -- Round to nearest $100
end

local function isOfferAllowed(price)
  if not negotiationActive then return false end
  if negotiationStatus == "accepted" or negotiationStatus == "failed" then return false end
  if not price or price <= 0 then return false end
  
  -- For buying: can't offer more than their current offer
  if not amISelling then
    if price > theirOffer then return false end
    if myOffer and price <= myOffer then return false end  -- Can't go backwards (lower)
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
  
  -- Check for insult
  local minimumAcceptableOffer = math.max(
    startingPrice * opponentPersonality.insultThresholdBase,
    propertyMarketValue * 0.80
  )
  
  if myOffer < minimumAcceptableOffer then
    isInsulted = true
    opponentQuote = opponentPersonality.insultQuotes[math.random(1, #opponentPersonality.insultQuotes)]
    patience = 0
    negotiationStatus = "failed"
    if career_modules_garageManager and career_modules_garageManager.setNegotiationCooldown then
      career_modules_garageManager.setNegotiationCooldown(propertyId)
    end
    guihooks.trigger('realEstateNegotiationData', getNegotiationState())
    return true
  end
  
  negotiationStatus = "thinking"
  guihooks.trigger('realEstateNegotiationData', getNegotiationState())
  
  core_jobsystem.create(function(job)
    -- Thinking delay
    local thinkingTime = 2.5 + math.random() * 2.0
    job.sleep(thinkingTime)
    
    negotiationStatus = "typing"
    guihooks.trigger('realEstateNegotiationData', getNegotiationState())
    job.sleep(thinkingTime)
    
    -- Calculate patience drop
    local patienceChange = calculatePatienceDrop(myOffer, theirOffer, propertyMarketValue, opponentPersonality)
    patience = math.max(0, patience - patienceChange)
    
    -- Determine acceptance/counter
    local absoluteMinimum
    if opponentPersonality.isDesperate then
      -- Desperate sellers can go up to desperationMaxDiscount (no fixed 10% hard cap)
      local maxDiscount = opponentPersonality.desperationMaxDiscount or 0.05
      absoluteMinimum = propertyMarketValue * (1 - maxDiscount)
    else
      -- Normal seller: minimum is based on patience
      -- High patience = holds firm near asking price
      -- Low patience = willing to go lower
      local maxPossibleDiscount = startingPrice
      local negotiationRange = math.min(math.max(0, startingPrice - propertyMarketValue), maxPossibleDiscount)
      local patienceMultiplier = patience * 0.7  -- High patience = 70% of range, low = smaller range
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
    elseif myOffer >= absoluteMinimum then
      theirOffer = myOffer
      negotiationStatus = "accepted"
      if myOffer > (absoluteMinimum * 1.05) then
        opponentQuote = opponentPersonality.happyQuotes[math.random(1, #opponentPersonality.happyQuotes)]
      else
        opponentQuote = "Alright, we have a deal."
      end
    else
      -- Generate counter-offer
      local counter = generateCounterOffer(myOffer, theirOffer, patience, opponentPersonality)
      if counter <= myOffer then
        -- Can't counter lower than player's offer → accept
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
  
  if not amISelling then
    completePurchase(propertyId, theirOffer, false)
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

local function resetNegotiationState()
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
end

local function cancelNegotiation()
  if not negotiationActive then return false end
  
  negotiationStatus = "cancelled"
  
  guihooks.trigger('realEstateNegotiationData', getNegotiationState())
  guihooks.trigger('ChangeState', {state = 'play', params = {}})
  
  resetNegotiationState()
  
  return true
end

function completePurchase(garageId, finalPrice, freezePrice)
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
  
  local success = career_modules_garageManager.completePurchaseWithNegotiatedPrice(garageId, finalPrice, freezePrice == true)
  if not success then
    log("E", "realEstateNegotiation", "Failed to store negotiated price")
    return
  end
  
  -- Delay reset to ensure state change completes
  core_jobsystem.create(function(job)
    job.sleep(0.1)
    resetNegotiationState()
  end)
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
  
  -- Generate seller personality
  opponentPersonality = generateSellerPersonality()
  
  -- Initialize negotiation state
  propertyId = garageId
  propertyName = garage.name or "Property"
  propertyPreview = garage.preview or ""
  propertyMarketValue = marketValue
  propertyCapacity = garage.capacity or 0
  propertyParkingSpots = (garage.parkingSpotNames and #garage.parkingSpotNames) or 0
  propertyNeighborhood = "West Coast"  -- TODO: Get from propertyMarket when available
  
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
-- NEGOTIATION LOGIC (SELLING SIDE) — Stub for Phase 2
-- ────────────────────────────────────────────────────────────────────────────

local function startNegotiateSelling(garageId, offerIdx)
  log("W", "realEstateNegotiation", "Selling-side negotiation not yet implemented (Phase 2)")
  return false
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
      startingPrice = startingPrice,
      patience = patience,
      myOffer = myOffer,
      theirOffer = theirOffer,
      negotiationStatus = negotiationStatus,
      offerHistory = offerHistory,
      opponentPersonality = opponentPersonality,
      opponentQuote = opponentQuote,
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
    startingPrice = data.startingPrice or 0
    patience = data.patience or 1.0
    myOffer = data.myOffer
    theirOffer = data.theirOffer or 0
    negotiationStatus = data.negotiationStatus or "initial"
    offerHistory = data.offerHistory or {}
    opponentPersonality = data.opponentPersonality
    opponentQuote = data.opponentQuote or ""
  end
  
  -- Load listings (Phase 2)
  local listingsPath = currentSavePath .. "/career/rls_career/realEstateListings.json"
  local listingsData = jsonReadFile(listingsPath)
  if listingsData then
    listedProperties = listingsData
  end
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

-- Save/load hooks
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot
M.onCareerActivated = onCareerActivated
M.onExtensionLoaded = onExtensionLoaded

return M
