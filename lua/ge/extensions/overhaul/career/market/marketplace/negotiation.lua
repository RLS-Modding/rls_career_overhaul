-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Marketplace negotiation: one session owns offers, patience, UI routing and sale completion.
-- Notable: also owns listing travel (route preview, inspection taxi hail); inspection owns the private listing spawn.
-- What the other party says comes from lib/market/negotiationLines; this file only says who is talking (the source).
local negotiation = {}
local policy = require('overhaul/career/market/marketplace/negotiationPolicy')
local negotiationLines = require('overhaul/lib/market/negotiationLines')

-- Config ----------------------------------------------------------------------------------------

local replyTuning = {happyPriceMultiplier = 1.10, lastChancePatienceFraction = 0.05}
local NEGOTIATION_ROUTE_SELLING = "overhaul.computer.vehicleShopping.negotiation"
local NEGOTIATION_ROUTE_BUYING = "overhaul.computer.vehicleShopping.vehicles.vehiclePurchase.negotiation"
local INSPECTION_SETTLE_S = 3.5

-- Listing travel --------------------------------------------------------------------------------------

local function routeToListing(_shopId)
  local vehicleInfo = overhaul_career_market_vehicleShopping.getVehicleInfoByShopId(_shopId)
  local pos = vehicleInfo and vehicleInfo.pos
  if not pos then return {ok = false} end
  core_groundMarkers.setPath(vec3(pos.x, pos.y, pos.z))
  return {
    ok = true,
    distance = core_groundMarkers.getPathLength() or nil,
  }
end

local function goToListing(_shopId, wantTaxi)
  local vehicleInfo = overhaul_career_market_vehicleShopping.getVehicleInfoByShopId(_shopId)
  if not (vehicleInfo and vehicleInfo.pos) then return false end

  overhaul_career_career.closeAllMenus()

  overhaul_career_market_vehicleShopping.clearFleetContext()
  overhaul_career_market_vehicleShopping.navigateToPos(vehicleInfo.pos, _shopId)

  if wantTaxi then
    local ready = overhaul_career_police_playerDriving.ensureVanillaTaxiReady()
    if not ready then
      local ok, err = pcall(extensions.load, "overhaul_integration_services_taxi")
      if not ok then log("W", "marketplace", "Could not load taxi service: " .. tostring(err)) end
      ready = overhaul_career_police_playerDriving.ensureVanillaTaxiReady()
    end
    if ready then
      -- Inspection fades the screen first; hail after it settles.
      core_jobsystem.create(function(job)
        job.sleep(INSPECTION_SETTLE_S)
        overhaul_career_police_playerDriving.ensureVanillaTaxiReady()
        if overhaul_integration_services_taxi and overhaul_integration_services_taxi.callForTaxi then
          overhaul_integration_services_taxi.callForTaxi()
        end
      end)
    end
  end
  return true
end

function negotiation.create(marketplace, listingOffers, minRatioDenominator)
  -- State ---------------------------------------------------------------------------------------

  -- Real session state, assigned when a negotiation begins; the stock marketplace keeps it as bare locals.
  local negotiationActive = false
  local negotiationToken = 0
  local negotiationOfferId

  local offerTaken = false
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
  local vehicleHideMarketValue = false
  local vehiclePlayerStartsNegotiation = false
  local vehicleHasVisibleTheirOffer = false
  local isDesperate = false
  local insultThreshold = 0.75
  local opponentQuote = ""
  -- Set while settling a reply and stored on that turn: "insulted" or "happy", plus the personality line drawn for it.
  local replyMood
  local replyQuote
  -- Words for the current negotiation, rebuilt whenever a new offer history starts.
  local lineSession = {history = nil, context = nil, recent = {}, openingQuote = nil, noPriceOpening = nil}

  local negotiationInventoryId
  local negotiationOfferIndex
  local negotiationCarMeetOfferIndex
  local negotiationMaxBuyerPrice = math.huge

  local shopId
  local opponentPersonality
  local purchaseFailureReason
  local saleCompleted = false
  local phoneMarketplaceUiOpen = false
  -- A stale phone mount flag must not route a later computer negotiation.
  local negotiationFromPhone = false
  local negotiationReturnRoute = "play"
  local negotiationReturnParams = {}

  -- Shared helpers ------------------------------------------------------------------------------

  local function isOfferProtectedFromRetraction(offer)
    if not offer or offer.expiredViewCounter or offer.committed then
      return true
    end
    if negotiationActive and negotiationOfferId and offer.id == negotiationOfferId then
      return true
    end
    return false
  end

  local function isNegotiationRoute(routeName)
    return routeName == NEGOTIATION_ROUTE_SELLING or routeName == NEGOTIATION_ROUTE_BUYING
  end

  -- UI and routing -------------------------------------------------------------------------------

  local function captureNegotiationReturnRoute(fallbackRoute)
    local routeName = fallbackRoute or "play"
    local routeParams = {}
    local current = extensions.ui_router.getCurrent()
    local request = current and current.request or nil
    if request and type(request.name) == "string" and request.name ~= "" and not isNegotiationRoute(request.name) then
      routeName = request.name
      routeParams = deepcopy(request.params or {})
    end
    negotiationReturnRoute = routeName
    negotiationReturnParams = routeParams
  end

  local function setPhoneMarketplaceUiOpen(open)
    phoneMarketplaceUiOpen = open and true or false
    overhaul_career_market_vehicleShopping.setShoppingUiOpen(phoneMarketplaceUiOpen)
  end

  -- Seller lines ---------------------------------------------------------------------------------

  local function priceTierFor(personality, vehicleValue)
    local thresholds = personality and personality.priceTierThresholds or {low = 5000, mid = 15000}
    if vehicleValue >= thresholds.mid then return "high" end
    if vehicleValue >= thresholds.low then return "mid" end
    return "low"
  end

  -- Who is talking: the side, the kind of source and, for a dealership, its facility's voice, channel and profile.
  local function buildLineContext(vehicleInfo)
    local personality = opponentPersonality or {}
    local context = {
      side = amISelling and "selling" or "buying",
      personality = personality,
      archetype = personality.archetype,
      priceTier = priceTierFor(personality, tonumber(startingPrice) or 0),
      fill = {vehicle = vehicleNiceName},
    }
    if amISelling then
      context.source = personality.isDealership and "dealership"
        or (negotiationCarMeetOfferIndex and "carMeet" or "marketplace")
      return context
    end
    local sellerId = vehicleInfo and vehicleInfo.sellerId
    context.sellerId = sellerId
    if (vehicleInfo and vehicleInfo.source == "carMeet") or sellerId == "carMeet" then
      context.source = "carMeet"
    elseif sellerId == "private" or (sellerId == nil and not personality.isDealership) then
      context.source = "private"
    else
      context.source = "dealership"
      local dealership = sellerId and overhaul_world_facilities and overhaul_world_facilities.getDealership(sellerId)
      if type(dealership) == "table" then
        context.voice = dealership.negotiationVoice
        context.salesChannel = dealership.salesChannel
        context.usedVehicleProfile = dealership.usedVehicleProfile
        context.fill.seller = dealership.name and _tr(dealership.name) or nil
      end
    end
    return context
  end

  local STATUS_SITUATION = {
    initial = "askingPrice", counterOffer = "counter", counterOfferLastChance = "finalOffer",
    refused = "hold", accepted = "accepted", failed = "walkedAway",
  }

  local function pickLine(situation, preferred)
    return negotiationLines.pick(lineSession.context, situation, lineSession.recent, preferred)
  end

  -- {text, pre, post}: pre/post wrap their price; text is the pitch, a happy remark or the walk-away line.
  local function describeTheirTurn(entry)
    local situation = STATUS_SITUATION[entry.negotiationStatus]
    if not situation then return nil end
    if situation == "walkedAway" then
      local line = pickLine(entry.mood == "insulted" and "insulted" or "walkedAway", entry.quote)
      return line and {text = line.text}
    end
    local textLine
    if entry.negotiationStatus == "initial" then
      textLine = pickLine("opening", lineSession.openingQuote)
    elseif entry.mood == "happy" then
      textLine = pickLine("acceptedHappy", entry.quote)
    end
    local priceLine = pickLine(situation)
    if not (textLine or priceLine) then return nil end
    return {text = textLine and textLine.text, pre = priceLine and priceLine.pre, post = priceLine and priceLine.post}
  end

  -- Lines are chosen once per turn and kept on the history entry, so a reopened screen shows the same words.
  local function describeOfferHistory(vehicleInfo)
    if lineSession.history ~= offerHistory then
      lineSession.history = offerHistory
      lineSession.context = buildLineContext(vehicleInfo)
      lineSession.recent = {}
      lineSession.openingQuote = opponentQuote
      lineSession.noPriceOpening = nil
    end
    local openingText
    for _, entry in ipairs(offerHistory) do
      if entry.theirOffer ~= nil and entry.line == nil then
        entry.line = describeTheirTurn(entry) or false
      end
      if entry.theirOffer ~= nil and entry.negotiationStatus == "initial" and entry.line then
        openingText = entry.line.text
      end
    end
    if openingText then return openingText end
    if not lineSession.noPriceOpening then
      local line = pickLine("openingNoPrice", lineSession.openingQuote)
      lineSession.noPriceOpening = line and line.text or false
    end
    return lineSession.noPriceOpening or nil
  end

  local function getNegotiationState()
    local visibleActualVehicleValue
    if not vehicleHideMarketValue then visibleActualVehicleValue = actualVehicleValue end
    local negotiationVehicleInfo = shopId and overhaul_career_market_vehicleShopping.getVehicleInfoByShopId(shopId) or nil
    local openingText = describeOfferHistory(negotiationVehicleInfo)
    return {
      active = negotiationActive,
      amISelling = amISelling,
      startingPrice = startingPrice,
      patience = patience,
      myOffer = myOffer,
      theirOffer = theirOffer,
      status = negotiationStatus,
      -- Dealer stock can inherit private pricing personalities; its public identity is still the facility.
      opponentName = lineSession.context.fill.seller or (opponentPersonality and _tr(opponentPersonality.name)) or "",
      -- The opening pitch; archetype quotes use locale keys, just like the opponent name.
      opponentQuote = openingText or (opponentQuote and _tr(opponentQuote)) or "",
      vehicleNiceName = vehicleNiceName,
      vehicleThumbnail = vehicleThumbnail,
      vehicleMileage = vehicleMileage,
      actualVehicleValue = visibleActualVehicleValue,
      hideMarketValue = vehicleHideMarketValue == true,
      playerStartsNegotiation = vehiclePlayerStartsNegotiation == true,
      hasVisibleTheirOffer = vehicleHasVisibleTheirOffer == true,
      purchaseAfterAccept = not amISelling and negotiationVehicleInfo and negotiationVehicleInfo.source == "carMeet",
      purchaseFailureReason = purchaseFailureReason,
      saleCompleted = saleCompleted == true,
      negotiationStatus = negotiationStatus,
      offerHistory = offerHistory,
      returnRoute = negotiationReturnRoute,
      returnParams = negotiationReturnParams
    }
  end

  local function openNegotiationUi()
    if negotiationFromPhone then
      guihooks.trigger('negotiationData', getNegotiationState())
    else
      captureNegotiationReturnRoute("overhaul.computer.vehicleShopping")
      extensions.ui_router.navigate(NEGOTIATION_ROUTE_SELLING)
    end
  end

  local function selectQuoteForPersonality(personality, vehicleValue, isBuyer)
    if not personality then
      return ""
    end

    local priceTier = priceTierFor(personality, vehicleValue)
    local quotes = personality.quotesByPriceTier and personality.quotesByPriceTier[priceTier]
    if not isBuyer and not personality.isDealership then
      quotes = marketplace.privateSellerQuotes
    end
    if isBuyer and personality.isDealership then
      quotes = marketplace.dealershipBuyerQuotes
    end
    if not quotes and not isBuyer and personality.isDealership then
      quotes = {
        "We're here to work with you on this vehicle.",
        "Let me see what I can do for you.",
        "I think we can find a price that works for both of us.",
        "We want to make this work for you.",
        "Let's see if we can reach an agreement."
      }
    end
    if quotes and #quotes > 0 then
      return quotes[math.random(1, #quotes)]
    end
    return isBuyer and "ui.career.negotiation.fallback.buyerInterested" or "ui.career.negotiation.fallback.sellerThanks"
  end

  -- Opening offers -------------------------------------------------------------------------------

  local function configureOpponent(personality)
    opponentPersonality = personality
    if opponentPersonality.isDealership then
      local desperation = opponentPersonality.desperation or 0.15
      isDesperate = math.random() < desperation

      local baseThreshold = opponentPersonality.insultThresholdBase or 0.75
      local variance = opponentPersonality.insultThresholdVariance or 0.05
      insultThreshold = baseThreshold + (math.random() * variance * 2 - variance)
    else
      isDesperate = false
      insultThreshold = 0.75
    end
  end

  local function beginNegotiateBuyingOffer(listing, offer, inventoryId, offerIndex)
    local buyerPersonality = offer.buyerPersonality

    configureOpponent(buyerPersonality)
    opponentQuote = selectQuoteForPersonality(opponentPersonality, listing.value, true)

    negotiationInventoryId = listing.id
    negotiationOfferIndex = offerIndex
    negotiationOfferId = offer.id
    negotiationCarMeetOfferIndex = nil
    vehicleNiceName = core_locales.translateWithOrWithoutContext(listing.niceName)
    vehicleThumbnail = listing.thumbnail
    vehicleMileage = overhaul_career_market_valueCalculator.getVehicleMileageById(inventoryId)
    actualVehicleValue = overhaul_career_market_valueCalculator.getInventoryVehicleSellValue(inventoryId)
    vehicleHideMarketValue = false
    vehiclePlayerStartsNegotiation = false
    vehicleHasVisibleTheirOffer = true
    negotiationMaxBuyerPrice = math.max(50,
      (tonumber(actualVehicleValue) or 0) * 1.25,
      (tonumber(offer.value) or 0) * 1.5)
    startingPrice = listing.value
    negotiationActive = true
    negotiationToken = negotiationToken + 1
    offerTaken = false
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

    openNegotiationUi()
  end

  local function startNegotiateBuyingOffer(inventoryId, offerIndex, fromPhone)
    negotiationFromPhone = fromPhone == true
    saleCompleted = false
    local listing = listingOffers.findVehicleListing(inventoryId)
    if listing and listing.rtBiz then
      return
    end
    listingOffers.refreshLiveListingValues(listing)
    local offer = listing and listing.offers[offerIndex]
    if not listing or not offer then
      return
    end
    local offerId = offer.id
    local originalListing = listing

    local function continueNegotiate()
      listing, offerIndex = listingOffers.findOfferById(offerId)
      offer = listing and listing.offers[offerIndex]
      if listing ~= originalListing or not offer then
        return
      end
      -- Sync may reveal post-list crash damage; keep negotiation closed when so.
      if listingOffers.listingDamagedAfterListing(listing, inventoryId) then
        guihooks.trigger("toastrMsg", {
          type = "warning",
          title = "Repair required",
          msg = "This vehicle was damaged after listing. Repair it before accepting offers."
        })
        return
      end
      beginNegotiateBuyingOffer(listing, offer, inventoryId, offerIndex)
    end

    if listingOffers.syncSpawnedListingPartConditions(inventoryId, continueNegotiate) then
      return
    end
    continueNegotiate()
  end

  local function startNegotiateBuyingOfferById(offerId, fromPhone)
    local listing, offerIndex = listingOffers.findOfferById(offerId)
    if not listing then return false end
    startNegotiateBuyingOffer(listing.id, offerIndex, fromPhone)
    return true
  end

  local function startCarMeetBuyingOffer(listing, offer, offerIndex)
    negotiationFromPhone = false
    if not listing or not offer then return false end
    local buyerPersonality = offer.buyerPersonality or listingOffers.generatePersonality(true)
    if not buyerPersonality then return false end

    configureOpponent(buyerPersonality)
    opponentQuote = selectQuoteForPersonality(opponentPersonality, listing.value or listing.marketValue or 0, true)

    negotiationInventoryId = listing.inventoryId
    negotiationOfferIndex = nil
    negotiationCarMeetOfferIndex = tonumber(offerIndex)
    vehicleNiceName = listing.niceName
    vehicleThumbnail = listing.thumbnail
    vehicleMileage = overhaul_career_market_valueCalculator.getVehicleMileageById(listing.inventoryId)
    actualVehicleValue = tonumber(listing.marketValue) or overhaul_career_market_valueCalculator.getInventoryVehicleSellValue(listing.inventoryId)
    vehicleHideMarketValue = false
    vehiclePlayerStartsNegotiation = false
    vehicleHasVisibleTheirOffer = true
    negotiationMaxBuyerPrice = math.max(50,
      (tonumber(actualVehicleValue) or 0) * 1.25,
      (tonumber(offer.value) or 0) * 1.5)
    startingPrice = tonumber(listing.value) or tonumber(actualVehicleValue) or tonumber(offer.value) or 0
    negotiationActive = true
    negotiationToken = negotiationToken + 1
    offerTaken = false
    patience = 1
    isInsulted = false
    theirOffer = tonumber(offer.value) or startingPrice
    myOffer = startingPrice
    amISelling = true
    negotiationStatus = "initial"
    offerHistory = {
      {
        myOffer = startingPrice,
        negotiationStatus = "initial"
      },
      {
        theirOffer = theirOffer,
        negotiationStatus = "initial"
      }
    }

    captureNegotiationReturnRoute("carMeetOffers")
    extensions.ui_router.navigate(NEGOTIATION_ROUTE_SELLING)
    return true
  end

  local function canNegotiateShopVehicle(vehicleInfo)
    if not vehicleInfo then return false end
    if vehicleInfo.source == "carMeet" then
      if not overhaul_career_market_vehicleShopping.canPurchaseCarMeetVehicle(true) then
        return false
      end
    end
    local noSeller = not vehicleInfo.negotiationPersonality
      and not overhaul_career_market_vehicleShopping.ensureNegotiationPersonality(vehicleInfo)
    if noSeller or (vehicleInfo.discountPercentage or 0) > 0 or vehicleInfo.negotiationPossible == false then
      guihooks.trigger("toastrMsg", {
        type = "warning",
        title = _tr("ui.career.vehiclePurchase.negotiationUnavailableTitle"),
        msg = vehicleInfo.negotiationDisabledReason or _tr("ui.career.vehiclePurchase.negotiationCannotNegotiateFallback")
      })
      return false
    end
    return true
  end

  local function initializeShopPricing(vehicleInfo)
    local sellerPersonality = vehicleInfo.negotiationPersonality
    configureOpponent(sellerPersonality)
    local vehicleBuyMult = overhaul_career_market_valueCalculator.getVehicleBuyMarketMultiplier()
    local valueBase = vehicleInfo.valueBase or (vehicleInfo.marketValue and vehicleInfo.marketValue * (vehicleInfo.negotiationPersonality and vehicleInfo.negotiationPersonality.priceMultiplier or 1)) or vehicleInfo.Value
    local roundedVehicleValue = math.floor((valueBase or vehicleInfo.Value or 0) * vehicleBuyMult + 0.5)
    opponentQuote = selectQuoteForPersonality(opponentPersonality, roundedVehicleValue, false)

    negotiationInventoryId = nil
    negotiationOfferIndex = nil
    negotiationCarMeetOfferIndex = nil
    negotiationMaxBuyerPrice = math.huge
    vehicleNiceName = vehicleInfo.Name
    vehicleThumbnail = vehicleInfo.preview
    vehicleMileage = vehicleInfo.Mileage
    local marketValueBase = vehicleInfo.marketValueBase or vehicleInfo.marketValue or valueBase
    actualVehicleValue = math.floor((marketValueBase or roundedVehicleValue) * vehicleBuyMult + 0.5)
    startingPrice = roundedVehicleValue
    vehicleHideMarketValue = vehicleInfo.hideMarketValue == true
    vehiclePlayerStartsNegotiation = vehicleInfo.playerStartsNegotiation == true
    vehicleHasVisibleTheirOffer = not vehiclePlayerStartsNegotiation

  end

  local function initializeShopOfferHistory(vehicleInfo)
    negotiationActive = true
    negotiationToken = negotiationToken + 1
    offerTaken = false

    if (vehicleInfo.discountPercentage or 0) > 0 then
      startingPrice = startingPrice * (1 - vehicleInfo.discountPercentage / 100)
    end

    theirOffer = startingPrice
    isInsulted = false
    myOffer = nil
    amISelling = false
    negotiationStatus = "initial"
    offerHistory = vehiclePlayerStartsNegotiation and {} or {
      {
        theirOffer = startingPrice,
        negotiationStatus = negotiationStatus
      }
    }

    local basePatience = opponentPersonality.startingPatience or 1.0
    local patienceVariance = opponentPersonality.patienceVariance or 0.1
    patience = math.max(0.2, math.min(1.0, basePatience + (math.random() * patienceVariance * 2 - patienceVariance)))

  end

  local function openBuyingNegotiationUi()
    if negotiationFromPhone then
      guihooks.trigger('negotiationData', getNegotiationState())
    else
      captureNegotiationReturnRoute("overhaul.computer.vehicleShopping.vehicles")
      extensions.ui_router.navigate(NEGOTIATION_ROUTE_BUYING)
    end
  end

  local function startNegotiateSellingOffer(requestedShopId, fromPhone)
    negotiationFromPhone = fromPhone == true
    shopId = requestedShopId
    purchaseFailureReason = nil
    saleCompleted = false
    local vehicleInfo = overhaul_career_market_vehicleShopping.getVehicleInfoByShopId(shopId)
    if not canNegotiateShopVehicle(vehicleInfo) then return false end
    initializeShopPricing(vehicleInfo)
    initializeShopOfferHistory(vehicleInfo)
    openBuyingNegotiationUi()
    return true
  end

  local function isOfferAllowed(price)
    if amISelling then
      return price > theirOffer and (not myOffer or price <= myOffer)
    else
      return (not vehiclePlayerStartsNegotiation or vehicleHasVisibleTheirOffer or price >= 0) and (not vehicleHasVisibleTheirOffer or price < theirOffer) and price >= (myOffer or 0)
    end
  end

  -- Offer replies --------------------------------------------------------------------------------

  local function calculatePatienceDrop(baseValue)
    if amISelling then
      return policy.sellingPatienceDrop(myOffer, theirOffer, baseValue,
        opponentPersonality.isDealership, minRatioDenominator)
    end
    local drop, insulted = policy.buyingPatienceDrop(myOffer, theirOffer, baseValue,
      startingPrice, insultThreshold, opponentPersonality.isDealership, minRatioDenominator)
    if insulted then isInsulted = true end
    return drop
  end

  local function dealerBuyingCounter(minAcceptable)
    local theirOfferCandidate
    if isInsulted then
      replyMood = "insulted"
      local insultQuotes = opponentPersonality.insultQuotes
      if insultQuotes and type(insultQuotes) == "table" and #insultQuotes > 0 then
        replyQuote = insultQuotes[math.random(1, #insultQuotes)]
      end
    else
      theirOfferCandidate = policy.dealerBuyingCounter(myOffer, theirOffer, minAcceptable, patience)
    end
    return theirOfferCandidate
  end

  local function settleDealerBuyingReply(minAcceptable)
    local theirOfferCandidate = dealerBuyingCounter(minAcceptable)
    if patience <= 0 then
      negotiationStatus = "failed"
      theirOffer = startingPrice
    elseif theirOfferCandidate <= myOffer then
      theirOffer = myOffer
      negotiationStatus = "accepted"

      if myOffer > (minAcceptable * replyTuning.happyPriceMultiplier) then
        replyMood = "happy"
        local happyQuotes = opponentPersonality.happyQuotes
        if happyQuotes and type(happyQuotes) == "table" and #happyQuotes > 0 then
          replyQuote = happyQuotes[math.random(1, #happyQuotes)]
        end
      end
    else
      if theirOfferCandidate >= theirOffer then
        negotiationStatus = "refused"
      else
        theirOffer = theirOfferCandidate
        if patience <= replyTuning.lastChancePatienceFraction then
          negotiationStatus = "counterOfferLastChance"
        else
          negotiationStatus = "counterOffer"
        end
      end
    end
  end

  local function settleDealerSellingReply()
    local theirOfferCandidate
    theirOfferCandidate = policy.dealerSellingCounter(myOffer, theirOffer,
      startingPrice, patience, negotiationMaxBuyerPrice)
    if theirOfferCandidate >= myOffer then
      theirOffer = math.min(myOffer, negotiationMaxBuyerPrice)
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

  local function settlePrivateReply()
    if patience <= 0 then
      negotiationStatus = "failed"
    else
      local counter = policy.privateCounterOffer(myOffer, theirOffer, amISelling,
        vehiclePlayerStartsNegotiation and not vehicleHasVisibleTheirOffer, negotiationMaxBuyerPrice)
      if (not amISelling and counter <= myOffer) or (amISelling and counter >= myOffer) then
        theirOffer = amISelling and math.min(myOffer, negotiationMaxBuyerPrice) or myOffer
        negotiationStatus = "accepted"
      else
        theirOffer = counter
        negotiationStatus = "counterOffer"
      end
    end
  end

  local function settleOfferReply(baseValue)
    if not opponentPersonality.isDealership then
      settlePrivateReply()
      return
    end
    local minAcceptable = policy.dealerMinimumPrice(startingPrice, baseValue,
      patience, isDesperate, opponentPersonality)
    if amISelling then
      settleDealerSellingReply()
    else
      settleDealerBuyingReply(minAcceptable)
    end
  end

  local function respondToOffer(job, baseValue, token)
    local patienceChange = calculatePatienceDrop(baseValue)
    local thinkingTimeS = policy.thinkingTimeS(myOffer, startingPrice, baseValue,
      patience, opponentPersonality.isDealership, minRatioDenominator)
    log('I', 'marketplace', string.format('thinking on offer %d for %0.1fs...', myOffer, thinkingTimeS))

    job.sleep(thinkingTimeS)
    if token ~= negotiationToken then return end
    negotiationStatus = "typing"
    guihooks.trigger('negotiationData', getNegotiationState())
    log('I', 'marketplace', string.format('typing for %0.1fs...', thinkingTimeS))

    job.sleep(thinkingTimeS)
    if token ~= negotiationToken then return end
    patience = math.max(0, patience - patienceChange)

    replyMood, replyQuote = nil, nil
    settleOfferReply(baseValue)
    table.insert(offerHistory, {
      theirOffer = theirOffer, negotiationStatus = negotiationStatus, mood = replyMood, quote = replyQuote,
    })
    if theirOffer ~= nil then
      vehicleHasVisibleTheirOffer = true
    end
    guihooks.trigger('negotiationData', getNegotiationState())
  end

  local function makeOffer(price)
    if not isOfferAllowed(price) then return false end

    if not amISelling then
      local vehicleInfo = shopId and overhaul_career_market_vehicleShopping.getVehicleInfoByShopId(shopId)
      if vehicleInfo and vehicleInfo.source == "carMeet" then
        if not overhaul_career_market_vehicleShopping.canPurchaseCarMeetVehicle(true) then
          return false
        end
      end
    end

    myOffer = price
    table.insert(offerHistory, {
      myOffer = myOffer
    })
    local baseValue = tonumber(actualVehicleValue) or 0

    negotiationStatus = "thinking"
    guihooks.trigger('negotiationData', getNegotiationState())
    local token = negotiationToken
    core_jobsystem.create(function(job)
      respondToOffer(job, baseValue, token)
    end)
    return true
  end

  local function makeNegotiationOffer(price)
    return makeOffer(tonumber(price))
  end

  -- Acceptance and purchase ----------------------------------------------------------------------

  local function notifyCarMeetPurchaseFailure(reason)
    purchaseFailureReason = reason or "Purchase could not be completed."
    -- Purchase blocks (garage space, afford, etc.) are not negotiation failures.
    negotiationStatus = "accepted"
    negotiationActive = true
    ui_message(purchaseFailureReason, 10, "vehicleShopping")
    guihooks.trigger('negotiationData', getNegotiationState())
  end

  local function acceptCarMeetSale()
    -- Expired meet offers must report refusal before any sale state is cleared.
    local accepted = overhaul_career_garage_inventory.getVehicleSaleSource("carMeet").acceptOffer(negotiationCarMeetOfferIndex, theirOffer)
    if accepted == false then
      return {ok = false, reason = "This offer is no longer available."}
    end
    myOffer = nil
    negotiationCarMeetOfferIndex = nil
    purchaseFailureReason = nil
    offerTaken = true
    return {ok = true}
  end

  local function acceptListingSale()
    local listing, offerIndex = listingOffers.findOfferById(negotiationOfferId)
    local offer = listing and listing.offers[offerIndex]
    if not offer or listing.id ~= negotiationInventoryId then
      return {ok = false, reason = "This offer is no longer available."}
    end

    local inventoryId = negotiationInventoryId
    local offerId = offer.id
    local agreedValue = theirOffer

    if listingOffers.acceptInFlight[inventoryId] then
      return {ok = false, reason = "A sale is already being processed for this vehicle."}
    end
    listingOffers.acceptInFlight[inventoryId] = true
    local result
    local function finalizeSellAttempt(ok, reason)
      listingOffers.acceptInFlight[inventoryId] = nil
      result = {ok = ok, reason = reason}
      if ok then
        myOffer = nil
        negotiationCarMeetOfferIndex = nil
        purchaseFailureReason = nil
        saleCompleted = true
        offerTaken = true
      else
        purchaseFailureReason = reason or "The sale could not be completed. Please try again."
        saleCompleted = false
        ui_message(purchaseFailureReason, 10, "vehicleShopping")
      end
      guihooks.trigger('negotiationData', getNegotiationState())
      saleCompleted = false
    end

    -- Sync live damage before accepting; a refusal must leave the advertised offer value intact.
    if listingOffers.syncSpawnedListingPartConditions(inventoryId, function()
      finalizeSellAttempt(listingOffers.tryAcceptOfferAfterSync(inventoryId, offerId, agreedValue))
    end) then
      return {ok = true, pending = true}
    end

    return result
  end

  local function takeShopOffer()
    local vehicleInfo = overhaul_career_market_vehicleShopping.getVehicleInfoByShopId(shopId)
    if not vehicleInfo then
      notifyCarMeetPurchaseFailure("This vehicle is no longer available for purchase.")
      return {ok = false, reason = purchaseFailureReason}
    end

    if vehicleInfo.source == "carMeet" then
      if theirOffer < vehicleInfo.Value then
        vehicleInfo.originalSellValue = vehicleInfo.Value
      end
      vehicleInfo.Value = theirOffer
      vehicleInfo.valueBase = theirOffer / overhaul_career_market_valueCalculator.getVehicleBuyMarketMultiplier()

      local purchaseOk, purchaseReason = overhaul_career_market_vehicleShopping.buyCarMeetVehicleNow(shopId)

      if not purchaseOk then
        notifyCarMeetPurchaseFailure(purchaseReason)
        return {ok = false, reason = purchaseFailureReason}
      end

      vehicleInfo.negotiationPossible = false
      myOffer = nil
      negotiationCarMeetOfferIndex = nil
      purchaseFailureReason = nil
      offerTaken = true
      return {ok = true}
    end

    if theirOffer < vehicleInfo.Value then
      vehicleInfo.originalSellValue = vehicleInfo.Value
    end
    vehicleInfo.Value = theirOffer
    vehicleInfo.negotiationPossible = false
    vehicleInfo.valueBase = theirOffer / overhaul_career_market_valueCalculator.getVehicleBuyMarketMultiplier()
    myOffer = nil
    negotiationCarMeetOfferIndex = nil
    purchaseFailureReason = nil
    offerTaken = true
    return {ok = true}
  end

  local function takeTheirOffer()
    if not negotiationActive then
      return {ok = false, reason = "This offer is no longer available."}
    end
    if amISelling then
      if negotiationCarMeetOfferIndex then return acceptCarMeetSale() end
      return acceptListingSale()
    end
    return takeShopOffer()
  end

  -- Close the phone before the purchase route so both menus cannot own input at once.
  local function finishPhonePurchase()
    local purchaseShopId = shopId
    negotiationFromPhone = false
    negotiationActive = false
    negotiationToken = negotiationToken + 1
    negotiationOfferId = nil
    if not purchaseShopId then
      return false
    end

    -- A phone buyer is out in the world; guide them to the listing's parking spot.
    local vehicleInfo = overhaul_career_market_vehicleShopping.getVehicleInfoByShopId(purchaseShopId)
    local pos = vehicleInfo and vehicleInfo.pos
    if pos then
      core_groundMarkers.setPath(vec3(pos.x, pos.y, pos.z))
    end

    overhaul_career_career.closeAllMenus()
    overhaul_career_market_vehicleShopping.clearFleetContext()
    overhaul_career_market_vehicleShopping.openPurchaseMenu("instant", purchaseShopId)
    return true
  end

  -- Lifecycle -----------------------------------------------------------------------------------

  local function dismissNegotiation()
    negotiationFromPhone = false
    negotiationActive = false
    negotiationToken = negotiationToken + 1
    negotiationOfferId = nil
    purchaseFailureReason = nil
    saleCompleted = false
    negotiationCarMeetOfferIndex = nil
    myOffer = nil
  end

  local function cancelNegotiation()
    negotiationFromPhone = false
    negotiationActive = false
    negotiationToken = negotiationToken + 1
    negotiationStatus = "failed"
    purchaseFailureReason = nil
    saleCompleted = false

    if myOffer then
      if amISelling then
        if negotiationCarMeetOfferIndex then
          overhaul_career_garage_inventory.getVehicleSaleSource("carMeet").disableOfferNegotiation(negotiationCarMeetOfferIndex)
        else
          local listing, offerIndex = listingOffers.findOfferById(negotiationOfferId)
          if listing and listing.id == negotiationInventoryId and listing.offers[offerIndex] then
            listing.offers[offerIndex].negotiationPossible = false
          end
        end
      else
        local vehicleInfo = overhaul_career_market_vehicleShopping.getVehicleInfoByShopId(shopId)
        if vehicleInfo then
          vehicleInfo.negotiationPossible = false
        end
      end
    end
    negotiationOfferId = nil
    negotiationCarMeetOfferIndex = nil
  end

  local function finalizeNegotiationExit()
    if not negotiationActive then return end
    if purchaseFailureReason then
      dismissNegotiation()
    elseif negotiationStatus == "accepted" then
      if not offerTaken then
        local vehicleInfo = not amISelling and shopId and overhaul_career_market_vehicleShopping.getVehicleInfoByShopId(shopId) or nil
        if vehicleInfo and vehicleInfo.source == "carMeet" then
          dismissNegotiation()
        end
      end
    else
      cancelNegotiation()
    end
  end

  local function isNegotiationActive()
    return negotiationActive
  end

  -- Public API -----------------------------------------------------------------------------------

  return {
    isOfferProtectedFromRetraction = isOfferProtectedFromRetraction,
    selectQuoteForPersonality = selectQuoteForPersonality,
    isNegotiationActive = isNegotiationActive,
    startNegotiateBuyingOffer = startNegotiateBuyingOffer,
    startNegotiateBuyingOfferById = startNegotiateBuyingOfferById,
    startNegotiateSellingOffer = startNegotiateSellingOffer,
    startCarMeetBuyingOffer = startCarMeetBuyingOffer,
    getNegotiationState = getNegotiationState,
    makeNegotiationOffer = makeNegotiationOffer,
    takeTheirOffer = takeTheirOffer,
    cancelNegotiation = cancelNegotiation,
    finalizeNegotiationExit = finalizeNegotiationExit,
    dismissNegotiation = dismissNegotiation,
    setPhoneMarketplaceUiOpen = setPhoneMarketplaceUiOpen,
    finishPhonePurchase = finishPhonePurchase,
    routeToListing = routeToListing,
    goToListing = goToListing,
  }
end

return negotiation
