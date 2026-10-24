-- Auction UI state: live lots and counter offers, with owned-car rows cached until their inputs change.
local constants = require('overhaul/career/market/auction/constants')
local pricing = require('overhaul/career/market/auction/pricing')
local consignment = require('overhaul/career/market/auction/consignment')

local view = {}

local LIVE_LOT_STATES = {queued = true, approaching = true, active = true, exiting = true}
local OWNED_VEHICLE_FIELDS = {
  'id', 'niceName', 'configBaseValue', 'model', 'config', 'year', 'mileage',
  'originalParts', 'changedSlots', 'partConditions', 'listedForAuction',
  'defaultThumbnail', 'dirtyDate',
}

local function same(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= 'table' then return a == b end
  for key, value in pairs(a) do if not same(value, b[key]) then return false end end
  for key in pairs(b) do if a[key] == nil then return false end end
  return true
end

-- Whole dollars with thousands separators, matching the UI's fee row: 1000 -> "$1,000".
function view.formatDollars(amount)
  local digits = tostring(math.floor((tonumber(amount) or 0) + 0.5))
  local grouped = digits:reverse():gsub('(%d%d%d)', '%1,'):reverse()
  return '$' .. (grouped:gsub('^(-?),', '%1'))
end

function view.create(deps)
  local api = {}
  local auctionState = deps.auctionState
  local ownedVehicleCache

  function api.computeAuctionExitNeedsConfirm()
    if overhaul_career_garage_inventory.getListedVehicleId() ~= nil then return true end
    for _, lot in ipairs(auctionState.lots or {}) do
      if lot.state == 'active' then return true end
    end
    return false
  end

  local function buildLotRows(now)
    local rows = {}
    for _, lot in ipairs(auctionState.lots or {}) do
      local mileage = lot.mileage
      if lot.sellerInventoryId then
        local metres = consignment.mileageMeters(lot.sellerInventoryId)
        if metres ~= nil then mileage = metres / constants.METERS_PER_MILE end
      end
      table.insert(rows, {
        lotIndex = lot.lotIndex,
        title = lot.title,
        mileage = mileage,
        state = lot.state,
        outcome = lot.outcome,
        wonByPlayer = lot.wonByPlayer == true and lot.wonInventoryId ~= nil,
        currentBid = lot.currentBid or 0,
        minStep = lot.minStep or constants.DEFAULT_BID_STEP_DOLLARS,
        highestBidder = lot.highestBidder,
        highestBidderName = deps.bidding.getLotLeaderName(lot),
        highestBidderNpcId = lot.leadingNpcPersonaId,
        saleStatus = lot.saleStatus,
        timeLeft = math.max(0, math.ceil((lot.endTime or 0) - now)),
        isPlayerListing = lot.sellerInventoryId ~= nil or lot.playerListing == true
      })
    end
    return rows
  end

  -- The lot the screen centres on: on the block, else leaving it, else at the active index, else the first live lot.
  local function findCurrentLotRow(lots, lotRows)
    for i, lot in ipairs(lots) do
      if lot.state == 'active' then
        return lotRows[i]
      end
    end
    for i, lot in ipairs(lots) do
      if lot.state == 'exiting' then
        return lotRows[i]
      end
    end
    local activeIdx = tonumber(auctionState.activeLotIndex)
    local indexedRow = (activeIdx and activeIdx >= 1) and lotRows[activeIdx] or nil
    if indexedRow and LIVE_LOT_STATES[indexedRow.state] then
      return indexedRow
    end
    for i, lot in ipairs(lots) do
      if LIVE_LOT_STATES[lot.state] then
        return lotRows[i]
      end
    end
    return nil
  end

  -- A live lot means the vault is in bidding; the entry prompt shows while the player is idle in the hall.
  local function derivePhase(hasLiveLot)
    local phase = auctionState.phase
    if hasLiveLot and (phase == 'idle' or phase == 'starting') then
      phase = 'bidding'
    end
    if auctionState.entryPromptActive and phase == 'idle' then
      phase = 'entryPrompt'
    end
    return phase
  end

  local function statusLine(phase)
    if phase == 'entryPrompt' then
      local fee = deps.payments.getEntryFee()
      if not deps.bidding.hasGarageSpaceForPurchase() and not consignment.hasListedVehicle() then
        return 'You need at least one free garage slot to enter the auction.'
      end
      if deps.payments.canAffordEntry() then
        return string.format('Pay %s to enter the auction.', view.formatDollars(fee))
      end
      return string.format('Not enough money. %s required to enter.', view.formatDollars(fee))
    end
    if phase == 'starting' then
      return 'Entering the vault…'
    end
    if phase == 'vaultIdle' then
      return 'Go to the counter to start the auction.'
    end
    if phase == 'bidding' then
      return 'Auction in progress.'
    end
    if phase == 'complete' then
      return 'Go to the counter to start another auction.'
    end
    return 'Enter the auction trigger to begin.'
  end

  local function currentBidMessage(now)
    if (auctionState.bidHintUntil or 0) > now and auctionState.bidHint and auctionState.bidHint ~= '' then
      return tostring(auctionState.bidHint)
    end
    return ''
  end

  local function counterOfferRows()
    local rows = {}
    for _, offer in ipairs(auctionState.counterOffers or {}) do
      local quote = pricing.counterOfferPricing(offer, auctionState.counterLotBatchSize, auctionState.entryCreditRemaining) or {}
      local registrationFee = quote.registrationFee or 0
      table.insert(rows, {
        id = offer.id,
        label = offer.label,
        subtitle = offer.subtitle,
        tier = offer.tier,
        creditApplied = quote.creditApplied or 0,
        registrationFee = registrationFee,
        coveredByEntry = registrationFee <= 0
      })
    end
    return rows
  end

  -- The player's own owned cars, listed only while the counter prompt is open.
  local function myVehicleRows(refreshVehicles)
    local rows = {}
    if not auctionState.counterPromptActive then
      ownedVehicleCache = nil
      return rows
    end

    local inventory = overhaul_career_garage_inventory
    local vehicles = inventory.getVehicles()
    local lockedIds = {}
    for _, lot in ipairs(auctionState.lots or {}) do
      if lot.sellerInventoryId and lot.state ~= 'finished' and lot.state ~= 'failed' then
        lockedIds[lot.sellerInventoryId] = true
      end
    end
    local inputs = {vehicles = {}}
    for invId, vehicle in pairs(vehicles) do
      if vehicle.owned then
        local mileage = consignment.mileageMeters(invId)
        local entry = {
          odometer = mileage,
          saleValueBonus = inventory.getVehicleSaleValueBonus(invId),
          accidents = inventory.getAccidents(invId),
          listBlockedReason = inventory.getAuctionListingBlockReason(invId),
          listingPending = inventory.isAuctionListingPending and inventory.isAuctionListingPending(invId) or false,
          listingInSession = lockedIds[invId] == true,
        }
        for _, field in ipairs(OWNED_VEHICLE_FIELDS) do entry[field] = vehicle[field] end
        inputs.vehicles[invId] = entry
      end
    end
    if next(inputs.vehicles) then
      -- Compare the shared part inventory once, including in-place repairs and swaps.
      -- Valuing each car again would scan that inventory once per owned vehicle.
      inputs.parts = overhaul_career_parts_partInventory.getInventory()
      inputs.partPriceMultiplier = overhaul_career_economy_globalEconomy.getPartPriceMultiplier()
      inputs.hardcore = overhaul_career_economy_difficultyMode.isHardcoreMode()
      inputs.year = os.date('%Y')
    end
    if not refreshVehicles and ownedVehicleCache and same(inputs, ownedVehicleCache.inputs) then
      return ownedVehicleCache.rows
    end

    for invId, veh in pairs(vehicles) do
      if veh.owned then
        table.insert(rows, {
          inventoryId = invId,
          niceName = deps.registration.vehicleDisplayName(veh.niceName, 'Vehicle'),
          value = overhaul_career_market_valueCalculator.getInventoryVehicleValue(invId) or 0,
          mileage = inputs.vehicles[invId].odometer,
          thumbnail = overhaul_career_garage_inventory.getVehicleThumbnail(invId),
          listedForAuction = veh.listedForAuction and true or false,
          listingPending = inputs.vehicles[invId].listingPending,
          listingInSession = inputs.vehicles[invId].listingInSession,
          -- the listing rule's own answer, so the button and listing never disagree
          listBlockedReason = inputs.vehicles[invId].listBlockedReason
        })
      end
    end
    table.sort(rows, function(a, b)
      if a.listedForAuction ~= b.listedForAuction then return a.listedForAuction end
      return (a.niceName or '') < (b.niceName or '')
    end)
    ownedVehicleCache = {inputs = deepcopy(inputs), rows = rows}
    return rows
  end

  local function hasOpenConsignment(lots)
    for _, lot in ipairs(lots) do
      if lot.sellerInventoryId and lot.state ~= 'finished' and lot.state ~= 'failed' then
        return true
      end
    end
    return false
  end

  -- Shared event payload for the route and passive overlay; no inventory scan.
  function api.requestAuctionHudState()
    local lots = auctionState.lots or {}
    local rows = buildLotRows(deps.getAuctionTime())
    local currentLot = findCurrentLotRow(lots, rows)
    return {
      sessionActive = auctionState.phase ~= 'idle',
      fullViewOpen = auctionState.uiOpen == true,
      playerBalance = overhaul_career_economy_playerAttributes.getAttributeValue("money") or 0,
      hasFreeGarageSlot = deps.bidding.hasGarageSpaceForPurchase(),
      auctionExitNeedsConfirm = api.computeAuctionExitNeedsConfirm(),
      phase = derivePhase(currentLot ~= nil),
      lots = rows,
      currentLot = currentLot,
      currentLotIndex = currentLot and currentLot.lotIndex or nil,
      activeLotIndex = auctionState.activeLotIndex,
    }
  end

  function api.requestAuctionState(refreshVehicles)
    local now = deps.getAuctionTime()
    local lots = auctionState.lots or {}
    local lotRows = buildLotRows(now)
    local currentLot = findCurrentLotRow(lots, lotRows)
    local hasLiveLot = currentLot ~= nil
    local phase = derivePhase(hasLiveLot)
    local bidMessage = currentBidMessage(now)
    local status = statusLine(phase)
    local mainAuctionPanelActive = (auctionState.phase == 'bidding') or deps.bidding.hasLiveTransitionLots()
    local counterOffers = counterOfferRows()
    local counterShowAuctionsTab = not (auctionState.phase == 'bidding' or auctionState.phase == 'starting')
    local myVehicles = myVehicleRows(refreshVehicles == true)
    local listedVehicleInventoryId = overhaul_career_garage_inventory.getListedVehicleId()
    local listedVehicleInventoryIds = consignment.getListedVehicleIds()
    local hasPlayerListingLotAtAuction = hasOpenConsignment(lots)
    local auctionExitNeedsConfirm = api.computeAuctionExitNeedsConfirm()

    return {
      phase = phase,
      entryPromptActive = auctionState.entryPromptActive and true or false,
      counterPromptActive = auctionState.counterPromptActive and true or false,
      musicEnabled = auctionState.musicEnabled ~= false,
      entryFee = deps.payments.getEntryFee(),
      canPayEntryFee = deps.payments.canAffordEntry(),
      canRegisterMoreLots = deps.registration.canRegisterMoreLots(),
      lotsRegisteredThisVisit = auctionState.lotsRegisteredThisVisit or 0,
      entryCreditRemaining = pricing.roundMoney(auctionState.entryCreditRemaining or 0),
      hasFreeGarageSlot = deps.bidding.hasGarageSpaceForPurchase(),
      hasValidConsignment = consignment.hasListedVehicle(),
      activeLotIndex = auctionState.activeLotIndex,
      currentLotIndex = currentLot and currentLot.lotIndex or nil,
      hasLiveLot = hasLiveLot,
      currentLot = currentLot,
      statusMessage = status,
      purchasedCount = #(auctionState.purchasedInventoryIds or {}),
      autoBidEnabled = false,
      autoBidMax = 0,
      bidMessage = bidMessage,
      playerBalance = overhaul_career_economy_playerAttributes.getAttributeValue("money") or 0,
      totalLots = #lots,
      lots = lotRows,
      counterOffers = counterOffers,
      mainAuctionPanelActive = mainAuctionPanelActive,
      lotBatchSize = pricing.clampLotBatchSize(auctionState.counterLotBatchSize),
      counterShowAuctionsTab = counterShowAuctionsTab,
      myVehicles = myVehicles,
      listedVehicleInventoryId = listedVehicleInventoryId,
      listedVehicleInventoryIds = listedVehicleInventoryIds,
      listingLimit = constants.MAX_CONSIGNMENT_LISTINGS,
      hasPlayerListingLotAtAuction = hasPlayerListingLotAtAuction,
      auctionExitNeedsConfirm = auctionExitNeedsConfirm
    }
  end

  return api
end

return view
