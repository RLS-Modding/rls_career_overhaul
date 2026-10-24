-- Auction lot registration and settlement: a counter offer's batch is built, opened and paid for, a
-- player's consignment joins it, and a finished lot is settled (won, sold, or voided).
local recordPurchase = require("overhaul/lib/progression/logbookFeed").register("overhaul.auctionVehiclePurchased", {
  title = "Auction vehicle purchased", label = "Vehicles", icon = "carCoins"
}, "career/market/auction/registration.lua")

local constants = require('overhaul/career/market/auction/constants')
local lotLib = require('overhaul/career/market/auction/lots')
local pricing = require('overhaul/career/market/auction/pricing')
local consignment = require('overhaul/career/market/auction/consignment')

local registration = {}

function registration.create(deps)
  local api = {}
  local auctionState = deps.auctionState

  -- Display and consignment -----------------------------------------------------------------------
  function api.vehicleDisplayName(niceName, fallback)
    if type(niceName) == 'string' and niceName ~= '' then
      return niceName
    end
    if type(niceName) == 'table' then
      local key = niceName.txt or niceName.name
      if type(key) == 'string' and key ~= '' then
        local translated = translateLanguage(key, key, true)
        if type(translated) == 'string' and translated ~= '' then
          return translated
        end
        return key
      end
    end
    return fallback or 'Vehicle'
  end

  -- The player's listed car as a lot, priced from its book value. Nil when the car can't be sold.
  local function buildPlayerConsignmentLot(sellerInventoryId)
    local veh = overhaul_career_garage_inventory.getVehicle(sellerInventoryId)
    if not consignment.canSell(sellerInventoryId, veh) then
      return nil
    end
    local mileageMeters = consignment.mileageMeters(sellerInventoryId)
    -- Keep the inventory odometer's precision, including new cars below one mile.
    local mileageMi = mileageMeters and math.max(0, mileageMeters / constants.METERS_PER_MILE)
    local basePrice = overhaul_career_market_valueCalculator.getInventoryVehicleValue(sellerInventoryId) or 2000
    basePrice = math.max(500, math.floor(basePrice))
    local minStep = constants.DEFAULT_BID_STEP_DOLLARS
    local startBid = math.max(minStep * 2, pricing.roundToStep(basePrice * (0.55 + math.random() * 0.2), 500))
    local partCopy = nil
    if type(veh.partConditions) == 'table' then
      partCopy = deps.copyTable(veh.partConditions)
    end

    return {
      lotIndex = 0,
      spawnSpot = nil,
      blockSpot = nil,
      model = veh.model,
      config = deps.copyTable(veh.config),
      title = api.vehicleDisplayName(veh.niceName, 'Your vehicle'),
      basePrice = basePrice,
      mileage = mileageMi,
      year = tonumber(veh.year) or (tonumber(os.date('%Y')) or 2026),
      minStep = minStep,
      currentBid = startBid,
      previewStartBid = startBid,
      highestBidder = 'npc',
      highestBidderName = 'NPC',
      leadingNpcPersonaId = nil,
      npcMaxBidsByPersonaId = {},
      npcPersonaNamesById = {},
      extensionCount = 0,
      endTime = 0,
      state = 'pending',
      vehId = nil,
      wonByPlayer = false,
      wonInventoryId = nil,
      driveState = nil,
      driveStartedAt = 0,
      lastMotionPos = nil,
      lastMotionAt = 0,
      sellerInventoryId = sellerInventoryId,
      playerListing = true,
      sellerPartConditions = partCopy,
      -- basePrice already includes age and mileage depreciation.
      conditionedBasePrice = basePrice,
      pricingInitialized = true
    }
  end

  local function deleteBatchVehicles()
    for _, lot in ipairs(auctionState.lots or {}) do
      if lot.vehId and not lot.wonInventoryId then
        deps.presentation.deleteVehicleSafe(lot.vehId)
      end
    end
  end

  -- Batch registration ----------------------------------------------------------------------------
  function api.clearLotsForNextBatch()
    deleteBatchVehicles()
    auctionState.lots = {}
    auctionState.activeLotIndex = 1
    auctionState.awaitingFinalExit = false
    auctionState.nextLiveStatusAt = 0
    auctionState.bidHint = nil
    auctionState.bidHintUntil = 0
  end

  function api.canRegisterMoreLots()
    return auctionState.phase == 'vaultIdle' or (auctionState.phase == 'complete' and not deps.bidding.hasLiveTransitionLots())
  end

  local function canUseAuctionCounter()
    return auctionState.phase == 'vaultIdle' or auctionState.phase == 'complete'
  end

  local function shuffleLotsAndAssignSpawnOrder(batch, spawnSpots, blockSpots)
    for i = #batch, 2, -1 do
      local j = math.random(i)
      batch[i], batch[j] = batch[j], batch[i]
    end
    local sc = #(spawnSpots or {})
    local bc = #(blockSpots or {})
    if sc <= 0 then
      return
    end
    for i, lot in ipairs(batch) do
      lot.lotIndex = i
      local si = ((i - 1) % sc) + 1
      lot.spawnSpot = spawnSpots[si]
      lot.blockSpot = (bc > 0) and blockSpots[((i - 1) % bc) + 1] or lot.spawnSpot
    end
  end

  -- Each consignment takes a slot in Anything Goes. Overflow stays listed for the next batch.
  local function buildRegistrationBatch(selectedTypeId, lotCount, auctionFilter)
    local layout = auctionState.siteLayout or {}
    local spawnSpots = layout.spawnSpots or {}
    local blockSpots = layout.blockSpots or {}
    local sellerIds = selectedTypeId == 'anything_goes' and consignment.getListedVehicleIds() or {}
    if #sellerIds == 0 then
      return lotLib.buildLotBatch(1, lotCount, spawnSpots, blockSpots, auctionFilter, layout.facility)
    end

    local playerLots = {}
    local cancelled = false
    for _, sellerInvId in ipairs(sellerIds) do
      local ok, playerLot = pcall(buildPlayerConsignmentLot, sellerInvId)
      if ok and playerLot then
        if #playerLots < lotCount then playerLots[#playerLots + 1] = playerLot end
      else
        overhaul_career_garage_inventory.clearVehicleAuctionListing(sellerInvId)
        cancelled = true
      end
    end
    if cancelled then
      auctionState.rerollCounterOffersOnOpen = true
      overhaul_career_saveSystem.saveCurrent()
      ui_message('An auction listing was cancelled because its vehicle is no longer eligible. Other listings are unchanged.', 8, 'warning', 'warning')
    end
    if #playerLots == 0 then return nil end
    lotLib.resetUsedConfigs()
    local remainder = lotCount - #playerLots
    local lotBatch = remainder > 0 and lotLib.buildLotBatch(1, remainder, spawnSpots, blockSpots, auctionFilter, layout.facility) or {}
    if type(lotBatch) ~= 'table' then
      lotBatch = {}
    end
    for _, playerLot in ipairs(playerLots) do table.insert(lotBatch, playerLot) end
    shuffleLotsAndAssignSpawnOrder(lotBatch, spawnSpots, blockSpots)
    return lotBatch
  end

  -- The counter offer a batch may be queued against; nil while the vault can't take a batch.
  local function openableCounterOffer(selectedTypeId)
    if not canUseAuctionCounter() or auctionState.transitionActive then
      return nil
    end
    local canSell = selectedTypeId == 'anything_goes' and consignment.hasListedVehicle()
    if (not deps.bidding.hasGarageSpaceForPurchase() and not canSell) or not api.canRegisterMoreLots() then
      return nil
    end
    return pricing.findCounterOffer(auctionState.counterOffers, selectedTypeId)
  end

  -- Puts the batch on the block with its NPCs; false, with the lots cleared, when no lot can start.
  local function startLotBatch(lotBatch)
    api.clearLotsForNextBatch()
    auctionState.lots = lotBatch

    local npcModule = overhaul_career_market_auctionNpcs
    auctionState.npcPersonas = npcModule.generatePersonas(#auctionState.lots)
    deps.bidding.beginNpcSession(auctionState.npcPersonas, auctionState.lots)

    auctionState.activeLotIndex = 0
    auctionState.awaitingFinalExit = false
    if deps.bidding.startNextLotAfter(0) then
      return true
    end
    api.clearLotsForNextBatch()
    npcModule.resetSession()
    auctionState.awaitingFinalExit = false
    return false
  end

  -- A batch that can't be paid for is torn down and the vault goes back to idle.
  local function abandonUnpaidBatch()
    deleteBatchVehicles()
    api.clearLotsForNextBatch()
    overhaul_career_market_auctionNpcs.resetSession()
    auctionState.phase = 'vaultIdle'
  end

  -- Opens a counter offer's batch and pays for it; false, with the lots cleared, when it can't.
  local function queueNextLotBatch(selectedTypeId, requestedLotCount)
    local selectedOffer = openableCounterOffer(selectedTypeId)
    if not selectedOffer then
      return false
    end
    local lotCount = pricing.clampLotBatchSize(requestedLotCount)
    if not deps.payments.canAffordLotRegistration(selectedTypeId, lotCount) then
      return false
    end
    local auctionFilter = lotLib.composeAuctionTypeFilter(selectedTypeId, auctionState.siteLayout and auctionState.siteLayout.facility)
    if type(auctionFilter) ~= 'table' then
      return false
    end

    local lotBatch = buildRegistrationBatch(selectedTypeId, lotCount, auctionFilter)
    if type(lotBatch) ~= 'table' or #lotBatch < 1 then
      return false
    end

    local payCount = #lotBatch
    local paymentLabel = string.format('%s (%s, %d Lots)', constants.AUCTION_LOT_REGISTRATION_PAYMENT_LABEL, selectedOffer.label, payCount)
    if not startLotBatch(lotBatch) then
      return false
    end
    if not deps.payments.payLotRegistration(selectedTypeId, payCount, paymentLabel) then
      abandonUnpaidBatch()
      return false
    end

    auctionState.lotsRegisteredThisVisit = (auctionState.lotsRegisteredThisVisit or 0) + 1
    auctionState.phase = 'bidding'
    return true
  end

  function api.confirmRegisterNextLot(selectedTypeId, lotCount)
    if not auctionState.counterPromptActive then
      return false
    end

    local queued = queueNextLotBatch(selectedTypeId, lotCount)
    if not queued then
      return false
    end

    auctionState.counterPromptActive = false
    deps.presentation.closeCounterOverlayUi()
    return true
  end

  -- Settlement ------------------------------------------------------------------------------------

  -- Pays for a won lot and moves it into the garage. A failed payment or garage refusal voids the win.
  local function registerWonLot(lot)
    if not lot or lot.purchaseResolved or lot.wonInventoryId then
      return false
    end
    lot.purchaseResolved = true
    lot.pendingPurchase = nil

    local price = tonumber(lot.currentBid) or 0
    local label = string.format('Used Auction: %s', lot.title or 'Vehicle')
    local finance = {vehicleObjectId = lot.vehId, vehicleName = lot.title}
    local recorded
    if not lot.vehId or not deps.payments.pay(price, label, "purchase", finance,
      function(row) recorded = row end) then
      lot.outcome = 'voided'

      deps.bidding.setBidHint('Payment for the won lot failed. The win was voided.', 5)
      return false
    end

    local inventoryId = overhaul_career_garage_inventory.addVehicle(lot.vehId, nil, {
      owned = true, year = lot.year, finalPrice = lot.currentBid
    })
    if not inventoryId then
      deps.payments.refund(price, label .. ' (refund)', finance)
      lot.outcome = 'refunded'

      deps.bidding.setBidHint('The won vehicle could not be registered. You were refunded.', 5)
      return false
    end
    -- Registration creates the inventory identity after the charge. Complete the
    -- captured receipt before garage handling can remove the newly registered car.
    finance.vehicleId = inventoryId
    local captured = require("overhaul/lib/finance/metadata").capture(
      {category = "purchase", finance = finance}, recorded and recorded.time, -price)
    if recorded then
      recorded.finance = captured
    end
    finance.vehicleKey, finance.vehicleName = captured.vehicleKey, captured.vehicleName
    if not overhaul_career_garage_inventory.moveVehicleToGarage(inventoryId) then
      lot.outcome = 'refunded'
      overhaul_career_garage_inventory.removeVehicle(inventoryId)
      deps.payments.refund(price, label .. ' (refund)', finance)
      deps.bidding.setBidHint('No garage could take the won vehicle. You were refunded.', 5)
      return false
    end

    lot.wonByPlayer = true
    lot.wonInventoryId = inventoryId
    lot.outcome = 'won'
    recordPurchase({name = lot.title or "Auction vehicle", money = -price})
    table.insert(auctionState.purchasedInventoryIds, inventoryId)
    deps.presentation.playLotWinCelebrationSound()
    deps.presentation.triggerAuctionWinEmitters(constants.LOT_WIN_EMITTER_DURATION_S)
    return true
  end

  -- Settles the lot when its bidding ends: a consignment is sold, a won lot is paid for once its car is parked.
  function api.finishCurrentLot()
    local lot = deps.bidding.getActiveAuctionLot()
    if not lot or lot.state ~= 'active' then
      return
    end

    lot.state = 'finished'
    overhaul_career_market_auctionNpcs.onLotEnd(lot, auctionState.npcPersonas)

    if lot.highestBidder == 'player' and lot.sellerInventoryId then
      lot.outcome = 'unsold'
      overhaul_career_garage_inventory.clearVehicleAuctionListing(lot.sellerInventoryId)
      lot.saleStatus = 'unsold'
      overhaul_career_saveSystem.saveCurrent()
      deps.bidding.beginLotExitThenNext(lot)
      return
    end

    if lot.highestBidder == 'npc' and lot.sellerInventoryId then
      local salePrice = math.max(0, tonumber(lot.currentBid) or 0)
      local vehicle = overhaul_career_garage_inventory.getVehicle(lot.sellerInventoryId)
      local eligible = consignment.canSell(lot.sellerInventoryId, vehicle)
      overhaul_career_garage_inventory.clearVehicleAuctionListing(lot.sellerInventoryId)
      local ok, sold = false, false
      if eligible then ok, sold = pcall(overhaul_career_garage_inventory.sellVehicle, lot.sellerInventoryId, salePrice) end
      lot.saleStatus = ok and sold and 'sold' or 'unsold'
      lot.outcome = lot.saleStatus
      if lot.saleStatus ~= 'sold' then
        deps.bidding.setBidHint('Your consignment could not be sold (vehicle is in use). It stays in your inventory.', 6)
        overhaul_career_saveSystem.saveCurrent()
      end
      deps.bidding.beginLotExitThenNext(lot)
      return
    end

    if lot.highestBidder == 'player' then
      if not deps.bidding.hasGarageSpaceForPurchase() then
        lot.outcome = 'voided'
        deps.bidding.setBidHint('No free garage slot. The win was voided.', 5)
      elseif deps.payments.canAfford(lot.currentBid) then
        local veh = lot.vehId and getObjectByID(lot.vehId)
        if veh and deps.vehicleControl.normalizePurchasedLotVehicleState(veh, lot.lotIndex) then
          lot.outcome = 'pending'
          lot.pendingPurchase = true
          lot.pendingPurchaseUntil = deps.getAuctionTime() + constants.PURCHASE_CALLBACK_TIMEOUT_S
          return
        end
        registerWonLot(lot)
      else
        lot.outcome = 'voided'
        deps.bidding.setBidHint('Not enough money to pay for the won lot. The win was voided.', 5)
      end
    else
      lot.outcome = lot.highestBidder == 'npc' and 'sold' or 'unsold'
    end

    deps.bidding.beginLotExitThenNext(lot)
  end

  -- Registers a won lot whose vehicle callback timed out, then starts the next lot.
  function api.finalizePurchasedLot(lotIndex)
    local lot = auctionState.lots and auctionState.lots[tonumber(lotIndex or 0)]
    if not lot then
      return false
    end
    if lot.sellerInventoryId then
      return false
    end
    if lot.highestBidder ~= 'player' or lot.purchaseResolved or lot.wonInventoryId then
      return false
    end

    local registered = registerWonLot(lot)
    deps.bidding.beginLotExitThenNext(lot)
    return registered
  end

  return api
end

return registration
