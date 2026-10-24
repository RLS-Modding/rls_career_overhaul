-- Auction flow commands the player triggers: the entry prompt and its payment, the counter prompt and
-- its offers, bids, the music toggle, and closing the menus. Lot registration lives in registration.lua.
local constants = require('overhaul/career/market/auction/constants')
local pricing = require('overhaul/career/market/auction/pricing')
local consignment = require('overhaul/career/market/auction/consignment')

local flow = {}

function flow.create(deps)
  local api = {}
  local auctionState = deps.auctionState

  local function closeMenuIfCounterOnly()
    if auctionState.phase ~= 'idle' then
      return
    end
    deps.presentation.closeAuctionOverlayUi()
  end

  local function cancelEntryPrompt(closeUi)
    if auctionState.phase ~= 'idle' or not auctionState.entryPromptActive then
      if closeUi then deps.presentation.closeAuctionOverlayUi() end
      return false
    end

    auctionState.entryPromptActive = false
    auctionState.entryPaymentToken = (auctionState.entryPaymentToken or 0) + 1
    auctionState.entryPaymentPending = false

    if closeUi then deps.presentation.closeAuctionOverlayUi() end
    return true
  end

  -- The vault needs a player vehicle, tagged spots, and room to buy or a car to sell.
  local function auctionReadyToStart()
    if auctionState.transitionActive then
      return false
    end

    if not be:getPlayerVehicle(0) then
      return false
    end

    local spots = deps.site.getSiteParkingSpots()
    if not spots or #spots < 1 then
      return false
    end

    local layout = deps.site.buildSiteLayout(spots)
    if not layout.playerSpot then
      return false
    end
    if #layout.spawnSpots < 1 or #layout.blockSpots < 1 then
      return false
    end
    if not layout.despawnSpot then
      return false
    end
    if not deps.site.getPlayerExitSpot(layout, false) then
      return false
    end

    return deps.bidding.hasGarageSpaceForPurchase() or consignment.hasListedVehicle()
  end

  function api.openEntryPrompt()
    if auctionState.phase ~= 'idle' or auctionState.transitionActive then
      return false
    end
    auctionState.entryPromptActive = true
    deps.presentation.openMenu()
    return true
  end

  -- Behind the entry loading screen: charges the fee and enters, or only drops the screen if a newer prompt won.
  local function enterVaultAfterLoading(paymentToken)
    if paymentToken ~= auctionState.entryPaymentToken then
      if not auctionState.entryPaymentPending then
        deps.presentation.exitAuctionEntryLoadingScreen()
      end
      return
    end
    auctionState.entryPaymentPending = false
    if auctionState.phase ~= 'idle' or not auctionState.entryPromptActive then
      deps.presentation.exitAuctionEntryLoadingScreen()
      return
    end

    if not deps.payments.payEntryFee() then
      deps.presentation.exitAuctionEntryLoadingScreen()
      return
    end

    overhaul_career_saveSystem.saveCurrent()

    auctionState.entryPromptActive = false
    if not deps.session.startAuctionImmediate() then
      deps.payments.refundEntryFee()
      deps.presentation.exitAuctionEntryLoadingScreen()
    end
  end

  -- Charges the entry fee behind the loading screen, then enters the vault.
  local function confirmEntryPaymentAndStartAuction()
    if auctionState.phase ~= 'idle' or not auctionState.entryPromptActive then
      return false
    end
    if auctionState.entryPaymentPending then
      return false
    end

    if not auctionReadyToStart() then
      return false
    end

    if not deps.payments.canAffordEntry() then
      return false
    end

    deps.presentation.playUiSound(constants.AUCTION_ENTRY_PAYMENT_SFX_EVENT)
    auctionState.entryPaymentToken = (auctionState.entryPaymentToken or 0) + 1
    local paymentToken = auctionState.entryPaymentToken
    auctionState.entryPaymentPending = true
    core_gamestate.requestEnterLoadingScreen(constants.AUCTION_ENTRY_LOADING_TAG, function()
      enterVaultAfterLoading(paymentToken)
    end)
    return true
  end

  function api.cancelCounterPrompt(closeUi)
    if not auctionState.counterPromptActive then
      if closeUi then
        closeMenuIfCounterOnly()
      end
      return false
    end

    auctionState.counterPromptActive = false
    deps.presentation.closeCounterOverlayUi()
    if closeUi then
      closeMenuIfCounterOnly()
    end
    return true
  end

  function api.closeMenu()
    if auctionState.phase == 'idle' and auctionState.entryPromptActive then
      return cancelEntryPrompt(true)
    end
    if auctionState.counterPromptActive then
      return api.cancelCounterPrompt(true)
    end
    deps.presentation.closeAuctionOverlayUi()
    return true
  end

  function api.startAuction()
    if auctionState.phase ~= 'idle' then
      return false
    end
    if auctionState.entryPromptActive then
      return confirmEntryPaymentAndStartAuction()
    end
    return api.openEntryPrompt()
  end

  function api.cancelTravelPrompt()
    if auctionState.phase == 'idle' and auctionState.entryPromptActive then
      return cancelEntryPrompt(true)
    end
    return api.closeMenu()
  end

  local function refreshCounterOfferPricing(offer)
    local quote = pricing.counterOfferPricing(offer, auctionState.counterLotBatchSize, auctionState.entryCreditRemaining) or {}
    offer.creditApplied = quote.creditApplied or 0
    offer.registrationFee = quote.registrationFee or 0
    offer.coveredByEntry = offer.registrationFee <= 0
  end

  local function buildCounterOffer(tierConfig, baseOffer)
    local offer = {
      id = baseOffer.id,
      label = baseOffer.label,
      subtitle = baseOffer.subtitle,
      tier = tierConfig.tier,
      fullFee = tierConfig.fullFee
    }
    refreshCounterOfferPricing(offer)
    return offer
  end

  -- A listed car leads the first tier with the anything-goes offer; other tiers roll one at random.
  local function pickTierOffer(tierIndex, tierOffers)
    if tierIndex ~= 1 or not consignment.hasListedVehicle() then
      return tierOffers[math.random(1, #tierOffers)]
    end
    for _, o in ipairs(tierOffers) do
      if o.id == 'anything_goes' then
        return o
      end
    end
    return tierOffers[1]
  end

  -- One offer per tier.
  local function rollCounterOffers()
    auctionState.counterOffers = {}

    for tierIndex, tierConfig in ipairs(constants.COUNTER_OFFER_TIERS) do
      local tierOffers = tierConfig.offers or {}
      if #tierOffers > 0 then
        table.insert(auctionState.counterOffers, buildCounterOffer(tierConfig, pickTierOffer(tierIndex, tierOffers)))
      end
    end
  end

  function api.openCounterPrompt()
    if auctionState.transitionActive then
      return false
    end
    local ph = auctionState.phase
    if not (ph == 'vaultIdle' or ph == 'complete' or ph == 'bidding' or ph == 'starting') then
      return false
    end
    auctionState.counterLotBatchSize = pricing.clampLotBatchSize(constants.DEFAULT_LOT_COUNT)
    local co = auctionState.counterOffers or {}
    if auctionState.rerollCounterOffersOnOpen or #co < 1 then
      rollCounterOffers()
      auctionState.rerollCounterOffersOnOpen = false
    end
    auctionState.counterPromptActive = true
    deps.presentation.openMenu()
    guihooks.trigger('UsedAuctionCounterShow')
    return true
  end

  function api.setCounterLotBatchSize(lotCount)
    auctionState.counterLotBatchSize = pricing.clampLotBatchSize(lotCount)
    for _, offer in ipairs(auctionState.counterOffers or {}) do
      refreshCounterOfferPricing(offer)
    end
    return auctionState.counterLotBatchSize
  end

  function api.placeBid(amount)
    if amount and tonumber(amount) and tonumber(amount) > 0 then
      return deps.bidding.placePlayerBidByAmount(tonumber(amount))
    end
    return deps.bidding.placePlayerBidIfPossible()
  end

  function api.setAuctionMusicEnabled(enabled)
    auctionState.musicEnabled = enabled and true or false
    if auctionState.phase ~= 'idle' then
      deps.presentation.setAuctionActiveAssetsEnabled(true)
    end
    return auctionState.musicEnabled
  end

  -- Auto-bid and passing were removed; these stay as no-ops for the UI callers that still make them.
  function api.setAutoBidEnabled()
    return false
  end

  function api.setAutoBidMax()
    return false
  end

  function api.passCurrentLot()
    return false
  end

  return api
end

return flow
