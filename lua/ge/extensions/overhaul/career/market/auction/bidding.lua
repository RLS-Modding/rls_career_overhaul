-- Auction lots in play: spawning a lot car, driving it onto the block, the bidding window and the exit drive.
-- Read in order: garage slots and leaders, bid hint and live status, lot spawn and paint, the lot drive sequence, player bids.

local constants = require('overhaul/career/market/auction/constants')
local pricing = require('overhaul/career/market/auction/pricing')
local buildConfig = require('overhaul/lib/vehicles/buildConfig')

local bidding = {}

function bidding.create(deps)
  local api = {}
  local auctionState = deps.auctionState
  local function ownsLot(lot)
    return lot and auctionState.phase == 'bidding'
      and auctionState.lots[lot.lotIndex] == lot
  end

  -- Garage and status -----------------------------------------------------------------------------
  local function getGarageFreeSlots()
    if not overhaul_career_garage_inventory.hasFreeSlot() then
      return 0
    end

    return math.max(0, tonumber(overhaul_career_garage_garageManager.getFreeSlots()) or 0)
  end

  function api.hasGarageSpaceForPurchase()
    return getGarageFreeSlots() > 0
  end

  function api.setBidHint(text, seconds)
    auctionState.bidHint = text
    auctionState.bidHintUntil = deps.getAuctionTime() + (tonumber(seconds) or 4)
  end

  function api.showLiveAuctionStatus(force)
    if auctionState.phase ~= 'bidding' then return end

    local now = deps.getAuctionTime()
    if not force and now < (auctionState.nextLiveStatusAt or 0) then
      return
    end

    auctionState.nextLiveStatusAt = now + constants.LIVE_STATUS_INTERVAL_S
  end

  -- Each bid or NPC raise on the block extends the timer when it lands in the last few seconds.
  function api.maybeExtendLotTimer(lot)
    if not lot or lot.state ~= 'active' then return false end
    local now = deps.getAuctionTime()
    local remaining = (lot.endTime or 0) - now
    if remaining > constants.ANTI_SNIPE_WINDOW_S then
      return false
    end

    lot.endTime = (lot.endTime or now) + constants.ANTI_SNIPE_EXTEND_S
    lot.extensionCount = (lot.extensionCount or 0) + 1
    return true
  end

  function api.getLotLeaderName(lot)
    if not lot then return '-' end
    if lot.highestBidder == 'player' then
      return 'You'
    end
    if lot.highestBidder == 'npc' then
      if lot.highestBidderName and lot.highestBidderName ~= '' then
        return lot.highestBidderName
      end
      local npcName = lot.npcPersonaNamesById and lot.leadingNpcPersonaId and lot.npcPersonaNamesById[lot.leadingNpcPersonaId]
      if npcName and npcName ~= '' then
        return npcName
      end
      return 'NPC'
    end
    return '-'
  end

  local function setPlayerAsLeader(lot)
    if not lot then return end
    lot.highestBidder = 'player'
    lot.leadingNpcPersonaId = nil
    lot.highestBidderName = 'You'
  end

  function api.setNpcAsLeader(lot, persona)
    if not lot then return end
    lot.highestBidder = 'npc'
    lot.leadingNpcPersonaId = persona and persona.id or nil
    local npcName = persona and persona.name or nil
    if (not npcName or npcName == '') and lot.npcPersonaNamesById and lot.leadingNpcPersonaId then
      npcName = lot.npcPersonaNamesById[lot.leadingNpcPersonaId]
    end
    lot.highestBidderName = npcName or 'NPC'
  end

  -- Starts an NPC bidding session over the given personas and lots (an empty list before the lots exist).
  function api.beginNpcSession(personas, lots)
    overhaul_career_market_auctionNpcs.initSession({
      getAuctionTime = deps.getAuctionTime,
      commitNpcBid = function(lot, persona, increment)
        lot.currentBid = lot.currentBid + increment
        api.setNpcAsLeader(lot, persona)
        deps.presentation.playBidAcceptedSound()
        api.maybeExtendLotTimer(lot)
        api.showLiveAuctionStatus(true)
      end
    }, personas, lots)
  end

  -- Lot spawn and paint ---------------------------------------------------------------------------
  local function applyConditionedLotPricing(lot)
    if not lot or lot.pricingInitialized then
      return
    end

    local conditionedBase = pricing.conditionedLotBasePrice(lot)
    if not conditionedBase then
      lot.pricingInitialized = true
      return
    end

    overhaul_career_market_auctionNpcs.repriceLot(lot, conditionedBase, auctionState.npcPersonas)
    lot.pricingInitialized = true
  end

  local function applyRandomPaintToSpawnOptions(options, modelKey, configPath)
    if not options or not modelKey then return end

    local paintResult = core_vehiclePaints.getRandomPaints(modelKey, pricing.configKeyFromPath(configPath))
    if type(paintResult) ~= 'table' then return end

    local modelData = core_vehicles.getModel(modelKey)
    local modelPaints = modelData and modelData.model and modelData.model.paints
    if type(modelPaints) ~= 'table' then return end

    local paintName = paintResult.paintName1
    local paint1 = paintName and modelPaints[paintName]
    if not paint1 then
      return
    end

    -- Only randomize paint slot 1 for auction vehicles.
    options.paintName = paintName
    options.paint = deps.copyTable(paint1)

    -- Also embed paints into config data before spawn so loaded config keeps auction paint.
    if type(configPath) == 'string' then
      local cfg = jsonReadFile(configPath)
      if type(cfg) == 'table' and cfg.format ~= 4 then
        cfg = deps.copyTable(cfg)
        cfg.partConfigFilename = configPath
        cfg.colors = nil
        local paints = type(cfg.paints) == 'table' and deps.copyTable(cfg.paints) or {}
        paints[1] = deps.copyTable(options.paint)
        cfg.paints = paints
        options.config = cfg
      end
    end
  end

  local function spawnLotVehicle(lot, spot, startApproach)
    if not lot then return false end
    local spawnSpot = spot or lot.spawnSpot
    -- Sites and spawn options both use a facing rotation; spawn converts it to
    -- the native vehicle rotation. Never use the block as a spawn fallback.
    if not spawnSpot or not lot.blockSpot or
      (vec3(spawnSpot.pos) - vec3(lot.blockSpot.pos)):length() < constants.LOT_OFFSTAGE_DISTANCE_M then
      return false
    end
    local options = {
      config = lot.config,
      autoEnterVehicle = false,
      autoFlip = true,
      pos = vec3(spawnSpot.pos),
      rot = quat(spawnSpot.rot)
    }

    if lot.playerListing then
      options.config = buildConfig.prepare(lot.config, deps.copyTable, lot.model)
      if not options.config then return false end
    end

    if not lot.playerListing then
      applyRandomPaintToSpawnOptions(options, lot.model, lot.config)
    end

    local veh = core_vehicles.spawnNewVehicle(lot.model, options)
    if not veh then
      lot.state = 'failed'
      return false
    end

    if lot.playerListing and type(lot.sellerPartConditions) == 'table' then
      core_vehicleBridge.executeAction(veh, 'initPartConditions', lot.sellerPartConditions, 0, 1, 1)
    else
      core_vehicleBridge.executeAction(veh, 'initPartConditions', {}, pricing.lotMileageMeters(lot), 1, 1)
    end
    applyConditionedLotPricing(lot)

    lot.vehId = veh:getID()
    lot.state = startApproach and 'approaching' or 'queued'
    lot.driveState = startApproach and 'approach' or nil
    lot.driveStartedAt = deps.getAuctionTime()
    lot.lastMotionDistance = nil
    lot.lastMotionAt = lot.driveStartedAt
    veh:queueLuaCommand('electrics.setLightsState(1)')
    deps.motion.ensureLotOverrideAI(veh)
    -- insertTraffic(..., true) only tracks the car, so its AI is disabled explicitly here.
    gameplay_traffic.insertTraffic(lot.vehId, true)
    veh:queueLuaCommand('if ai then ai.setMode("disabled") end')
    if startApproach then
      -- No freeze here: a delayed freeze callback would hit mid-driveUsingPath (fatal 5635).
      deps.pendingFreezeTokens[lot.vehId] = (deps.pendingFreezeTokens[lot.vehId] or 0) + 1
      deps.vehicleControl.setVehicleFreezeSafe(veh, false)
    else
      -- Queued on the pad: safe to hold frozen until this lot is called.
      deps.vehicleControl.setLotVehicleDriveLock(veh, 'staged')
    end

    return true
  end

  -- Lot drive sequence ----------------------------------------------------------------------------
  local function lotDestination(lot)
    local target = lot.blockSpot or lot.spawnSpot
    if lot.state == 'exiting' then
      target = auctionState.siteLayout and auctionState.siteLayout.despawnSpot
    end
    return target
  end

  local function lotTargetDistance(lot, veh)
    local target = lot.motionTargets and lot.motionTargets[lot.motionTargetIndex or 1]
      or lotDestination(lot)
    if not veh or not target or not target.pos then return nil end
    local delta = vec3(veh:getPosition()) - vec3(target.pos)
    delta.z = 0
    return delta:length()
  end

  function api.beginLotBidding(lot)
    if not lot then return end
    local veh = lot.vehId and getObjectByID(lot.vehId)
    if not veh then return end

    lot.state = 'active'
    lot.driveState = nil
    lot.blockReady, lot.biddingUiReady = false, false
    deps.vehicleControl.setLotVehicleDriveLock(veh, 'bidding')
    -- Arrival is a state transition, never a request to take over the screen.
    local now = deps.getAuctionTime()
    lot.endTime = now + constants.LOT_DURATION_S
    auctionState.nextLiveStatusAt = 0
    overhaul_career_market_auctionNpcs.onLotBiddingBegin(lot, now, auctionState.npcPersonas)
    api.showLiveAuctionStatus(true)
    deps.publishState()
  end

  local function setLotMotionTrackingNow(lot, veh)
    if not lot or not veh then
      return
    end
    lot.driveStartedAt = deps.getAuctionTime()
    lot.motionTargets, lot.motionTargetIndex = nil, nil
    lot.lastMotionDistance = lotTargetDistance(lot, veh)
    lot.lastMotionAt = lot.driveStartedAt
  end

  local function trackLotRoute(lot, routePoints)
    if not routePoints then return end
    lot.motionTargets, lot.motionTargetIndex = {}, 1
    for _, point in ipairs(routePoints) do
      table.insert(lot.motionTargets, {pos = point})
    end
    table.insert(lot.motionTargets, lotDestination(lot))
    lot.lastMotionDistance = nil
  end

  local function beginLotApproach(lot)
    if not lot then return false end
    local veh = lot.vehId and getObjectByID(lot.vehId)
    if not veh then return false end
    lot.state = 'approaching'
    lot.driveState = 'approach'
    setLotMotionTrackingNow(lot, veh)
    deps.motion.ensureLotOverrideAI(veh)
    -- Cancel any staged freeze still in flight from spawn/queue.
    deps.pendingFreezeTokens[lot.vehId] = (deps.pendingFreezeTokens[lot.vehId] or 0) + 1
    deps.vehicleControl.setVehicleFreezeSafe(veh, false)

    local routeSpots = {}
    table.insert(routeSpots, lot.spawnSpot)
    for _, spot in ipairs((auctionState.siteLayout and auctionState.siteLayout.pathInSpots) or {}) do
      table.insert(routeSpots, spot)
    end
    table.insert(routeSpots, lot.blockSpot or lot.spawnSpot)

    local blockSpot = lot.blockSpot or lot.spawnSpot

    local function startApproachDrive(vehicle)
      if not vehicle or not ownsLot(lot) or lot.state ~= 'approaching' then
        return
      end
      local function isCurrent() return ownsLot(lot) and lot.state == 'approaching' and lot.vehId == vehicle:getID() end
      local routed, routePoints = deps.motion.driveVehicleToExactSpot(vehicle, routeSpots, blockSpot, 0.25, isCurrent)
      if routed then
        trackLotRoute(lot, routePoints)
        return
      end
      if deps.motion.driveVehicleAlongRouteSpots(vehicle, routeSpots, 0.35) then
        return
      end
      if lot.spawnSpot and blockSpot and deps.motion.driveVehicleToSpot(vehicle, lot.spawnSpot, blockSpot, 0.35) then
        return
      end
      api.recoverLotApproach(lot)
    end

    -- Disable AI (clear any leftover plan) before path start.
    deps.vehicleControl.queueSafeLotTransit(veh, startApproachDrive)
    return true
  end

  -- A blocked entrance must not send the same car back through the obstacle.
  -- Clear the previous lot first, then place this one directly on its block.
  function api.recoverLotApproach(lot)
    if not ownsLot(lot) or lot.state ~= 'approaching' or lot.recoveryPending then return end
    for _, other in ipairs(auctionState.lots) do
      if other ~= lot and (other.state == 'active' or other.state == 'exiting') then return end
    end
    lot.recoveryPending = true
    local ok, recovered = pcall(function()
      local veh = lot.vehId and getObjectByID(lot.vehId)
      if not veh then
        lot.vehId = nil
        if not spawnLotVehicle(lot, lot.spawnSpot, true) then return false end
        veh = getObjectByID(lot.vehId)
      end
      deps.vehicleControl.cancelLotTransit(lot.vehId)
      if not deps.motion.recoverLotVehicleToSpot(veh, lot.blockSpot) then return false end
      api.beginLotBidding(lot)
      return true
    end)
    lot.recoveryPending = nil
    if not ok or not recovered then
      local cleaned, cleanupError = pcall(deps.presentation.deleteVehicleSafe, lot.vehId)
      if not cleaned then log('E', 'usedCarAuction', 'Failed lot cleanup: ' .. tostring(cleanupError)) end
      lot.vehId, lot.state, lot.driveState = nil, 'failed', 'done'
      api.startNextLotAfter(lot.lotIndex)
    end
    if not ok then error(recovered, 0) end
  end

  local function beginLotExit(lot)
    if not lot then return false end

    local veh = lot.vehId and getObjectByID(lot.vehId)
    if not veh then
      lot.state = 'finished'
      lot.driveState = 'done'
      return false
    end

    deps.motion.closeVehicleOpenables(veh)
    lot.state = 'exiting'
    lot.driveState = 'exit'
    setLotMotionTrackingNow(lot, veh)
    deps.motion.ensureLotOverrideAI(veh)

    local blockSpot = lot.blockSpot or lot.spawnSpot
    local despawnSpot = auctionState.siteLayout and auctionState.siteLayout.despawnSpot

    local function startExitDrive(vehicle)
      if not vehicle or not ownsLot(lot) or lot.state ~= 'exiting' then
        return
      end
      deps.motion.ensureLotOverrideAI(vehicle)
      local exitSpots = {}
      for _, spot in ipairs((auctionState.siteLayout and auctionState.siteLayout.pathOutSpots) or {}) do
        table.insert(exitSpots, spot)
      end
      if despawnSpot then
        table.insert(exitSpots, despawnSpot)
      end
      -- Script first: road AI often builds a stub plan here, and the car then idles with ignition on.
      local function isCurrent() return ownsLot(lot) and lot.state == 'exiting' and lot.vehId == vehicle:getID() end
      local routed, routePoints = deps.motion.driveLotVehicleExitScript(vehicle, exitSpots, isCurrent)
      if routed then
        trackLotRoute(lot, routePoints)
        return
      end
      if despawnSpot then
        routed, routePoints = deps.motion.driveLotVehicleExitScript(vehicle, {despawnSpot}, isCurrent)
        if routed then
          trackLotRoute(lot, routePoints)
          return
        end
      end
      if deps.motion.driveLotVehicleExit(vehicle, exitSpots, 0.25) then
        return
      end
      if despawnSpot and deps.motion.driveVehicleToSpot(vehicle, blockSpot, despawnSpot, 0.25) then
        return
      end
      api.completeLotExit(lot, true)
    end

    -- Bidding left the car frozen. Clear AI plan first, then unfreeze, then drive.
    deps.vehicleControl.queueSafeLotTransit(veh, startExitDrive)
    return true
  end

  function api.setAuctionComplete()
    if auctionState.phase == 'complete' then return end
    auctionState.phase = 'complete'
    auctionState.awaitingFinalExit = false
    auctionState.rerollCounterOffersOnOpen = true
    deps.presentation.setAuctionRunningTriggerState()
  end

  function api.hasLiveTransitionLots()
    for _, checkLot in ipairs(auctionState.lots or {}) do
      if checkLot.state == 'approaching' or checkLot.state == 'active' or checkLot.state == 'exiting' then
        return true
      end
    end
    return false
  end

  function api.getActiveAuctionLot()
    for _, lot in ipairs(auctionState.lots or {}) do
      if lot.state == 'active' then
        return lot
      end
    end
    return nil
  end

  function api.refreshLotMotionProgress(lot, veh, tNow)
    if not lot then return end
    lot.driveStartedAt = lot.driveStartedAt or tNow
    lot.lastMotionAt = lot.lastMotionAt or lot.driveStartedAt
    local distance = lotTargetDistance(lot, veh)
    if not distance then return end
    -- The lot loop bends away from the block. Track its actual script points
    -- in order so a healthy detour is progress, but circling one point is not.
    while lot.motionTargets and lot.motionTargetIndex < #lot.motionTargets
      and distance <= constants.LOT_PROGRESS_WAYPOINT_DISTANCE_M do
      lot.motionTargetIndex = lot.motionTargetIndex + 1
      lot.lastMotionDistance = nil
      lot.lastMotionAt = tNow
      distance = lotTargetDistance(lot, veh)
    end
    -- Only a new best distance counts. Circling, reversing and vertical motion
    -- must not renew the recovery timer, even while the car is moving quickly.
    if not lot.lastMotionDistance then
      lot.lastMotionDistance = distance
    elseif lot.lastMotionDistance - distance >= constants.LOT_PROGRESS_DISTANCE_M then
      lot.lastMotionDistance = distance
      lot.lastMotionAt = tNow
    end
  end

  local function startLotByIndex(idx)
    local lot = auctionState.lots[idx]
    if not lot then
      return false
    end

    if lot.vehId and getObjectByID(lot.vehId) then
      beginLotApproach(lot)
      return true
    end

    if spawnLotVehicle(lot, lot.spawnSpot, true) then
      beginLotApproach(lot)
      return true
    end

    lot.state = 'failed'
    return false
  end

  function api.startNextLotAfter(currentLotIndex)
    local idx = (tonumber(currentLotIndex) or 0) + 1
    while true do
      local nextLot = auctionState.lots[idx]
      if not nextLot then
        auctionState.awaitingFinalExit = true
        return false
      end

      auctionState.activeLotIndex = idx
      if startLotByIndex(idx) then
        return true
      end

      idx = idx + 1
    end
  end

  -- The stage belongs to one car until it has driven to the off-stage exit.
  function api.beginLotExitThenNext(lot)
    if not lot then
      return
    end
    lot.advanceAfterExit = true
    if not beginLotExit(lot) then
      lot.advanceAfterExit = nil
      api.startNextLotAfter(lot.lotIndex)
    end
  end

  function api.completeLotExit(lot, recoverToExit)
    if lot.exitCleanupPending or not ownsLot(lot) or lot.state ~= 'exiting' then return end
    lot.exitCleanupPending = true
    local veh = lot.vehId and getObjectByID(lot.vehId)
    if recoverToExit and veh then
      deps.vehicleControl.cancelLotTransit(lot.vehId)
      local exitSpot = auctionState.siteLayout and auctionState.siteLayout.despawnSpot
      if not deps.motion.recoverLotVehicleToSpot(veh, exitSpot) then
        lot.exitCleanupPending = nil
        return
      end
    end
    lot.exitCleanupPending = nil
    if deps.presentation.despawnLotVehicle(lot) == false then return end
    lot.state, lot.driveState = 'finished', 'done'
    if lot.advanceAfterExit then
      lot.advanceAfterExit = nil
      api.startNextLotAfter(lot.lotIndex)
    end
  end

  local function setLotLeaderFromPlayerBid(lot, bidAmount)
    if not lot then
      return false
    end

    auctionState.bidHint = nil
    auctionState.bidHintUntil = 0

    local prevBid = lot.currentBid or 0
    lot.currentBid = bidAmount
    setPlayerAsLeader(lot)
    deps.presentation.playBidAcceptedSound()
    api.maybeExtendLotTimer(lot)
    overhaul_career_market_auctionNpcs.onPlayerBid(lot, bidAmount - prevBid)
    api.showLiveAuctionStatus(true)
    return true
  end

  -- Player bids -----------------------------------------------------------------------------------

  -- The active lot when the player may bid on it. Otherwise sets the reason as the bid hint and returns nil.
  local function biddableActiveLot()
    if auctionState.phase ~= 'bidding' then
      api.setBidHint('Auction is not taking bids right now.', 3)
      return nil
    end

    local lot = api.getActiveAuctionLot()
    if not lot or lot.state ~= 'active' then
      api.setBidHint('Wait until this lot is live on the block.', 3)
      return nil
    end
    if not api.hasGarageSpaceForPurchase() then
      api.setBidHint('No free garage slot. You cannot bid on vehicles.', 4)
      return nil
    end
    if lot.sellerInventoryId or lot.playerListing then
      api.setBidHint("You can't bid on your own consignment.", 4)
      return nil
    end
    if lot.highestBidder == 'player' then
      api.setBidHint('You already have the high bid.', 3)
      return nil
    end
    return lot
  end

  -- Leads the lot at bidAmount when the player can afford it; otherwise sets the hint and returns false.
  local function placeBidIfAffordable(lot, bidAmount)
    if not deps.payments.canAfford(bidAmount) then
      api.setBidHint('Not enough money for this bid.', 5)
      return false
    end
    return setLotLeaderFromPlayerBid(lot, bidAmount)
  end

  -- Bids the minimum step above the current bid.
  function api.placePlayerBidIfPossible()
    local lot = biddableActiveLot()
    if not lot then
      return false
    end
    return placeBidIfAffordable(lot, lot.currentBid + lot.minStep)
  end

  -- Bids the current bid plus amount, and at least the minimum step.
  function api.placePlayerBidByAmount(amount)
    local lot = biddableActiveLot()
    if not lot then
      return false
    end

    amount = math.max(lot.minStep or constants.DEFAULT_BID_STEP_DOLLARS, tonumber(amount) or 0)
    return placeBidIfAffordable(lot, lot.currentBid + amount)
  end

  return api
end

return bidding
