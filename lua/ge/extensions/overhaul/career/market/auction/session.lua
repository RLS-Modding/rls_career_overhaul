-- Auction sessions: entering the vault, leaving it (purchased cars are parked outside), resetting the
-- visit, and moving a player who loads the career out of the vault.
local constants = require('overhaul/career/market/auction/constants')
local pricing = require('overhaul/career/market/auction/pricing')

local session = {}

function session.create(deps)
  local api = {}
  local auctionState = deps.auctionState

  function api.resetAuction(keepPurchases)
    local inventory = overhaul_career_garage_inventory
    if inventory and inventory.cancelPendingAuctionListings then inventory.cancelPendingAuctionListings() end
    deps.presentation.closeAuctionOverlayUi()
    deps.site.clearAuctionExitMarker()
    deps.site.clearAuctionCounterMarker()

    for _, lot in ipairs(auctionState.lots) do
      if lot.vehId then
        deps.vehicleControl.cancelLotTransit(lot.vehId)
        local keepVeh = false
        if keepPurchases then
          for _, invId in ipairs(auctionState.purchasedInventoryIds) do
            local savedVehId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(invId)
            if savedVehId and savedVehId == lot.vehId then
              keepVeh = true
              break
            end
          end
        end

        if not keepVeh then
          deps.presentation.deleteVehicleSafe(lot.vehId)
        end
      end
    end

    deps.newAuctionState(auctionState, true)
    -- A held entry payment or loading callback from before this reset must not charge or enter.
    auctionState.entryPaymentToken = (auctionState.entryPaymentToken or 0) + 1
    auctionState.entryPaymentPending = false
    overhaul_career_market_auctionNpcs.resetSession()
    require('overhaul/career/market/auction/lots').resetUsedConfigs()
    auctionState.winEmitterPulseToken = (auctionState.winEmitterPulseToken or 0) + 1
    deps.presentation.setAuctionWinEmittersEnabled(false)
    deps.presentation.setAuctionActiveAssetsEnabled(false)
    deps.finishAuctionReset(auctionState)
    deps.presentation.setIdleTriggerState()
    deps.site.clearSelection()
  end

  -- A usable vault needs a player spot, spawn spots, a despawn spot and an exit.

  local function siteLayoutUsable(layout)
    if not layout.playerSpot or #layout.spawnSpots < 1 or #layout.blockSpots < 1 or not layout.despawnSpot then
      return false
    end
    return deps.site.getPlayerExitSpot(layout, true) and true or false
  end

  -- Builds the vault for a visit. Any missing tagged spot resets the visit and returns false.
  local function setupAuctionSite(playerVeh, spots)
    local layout = deps.site.buildSiteLayout(spots)
    auctionState.siteLayout = layout
    auctionState.auctionSpot = layout.playerSpot
    auctionState.travelSpot = layout.playerSpot

    if not siteLayoutUsable(layout) then
      api.resetAuction(false)
      return false
    end

    deps.presentation.setAuctionActiveAssetsEnabled(true)
    deps.motion.teleportVehicleToSpot(playerVeh, auctionState.auctionSpot)
    deps.site.ensureAuctionExitMarker(layout)
    deps.site.ensureAuctionCounterMarker()

    auctionState.lots = {}
    auctionState.lotsRegisteredThisVisit = 0
    auctionState.counterOffers = {}
    auctionState.rerollCounterOffersOnOpen = false
    auctionState.counterLotBatchSize = pricing.clampLotBatchSize(constants.DEFAULT_LOT_COUNT)
    auctionState.npcPersonas = overhaul_career_market_auctionNpcs.generatePersonas(constants.DEFAULT_LOT_COUNT)
    deps.bidding.beginNpcSession(auctionState.npcPersonas, {})
    auctionState.activeLotIndex = 0
    auctionState.awaitingFinalExit = false
    auctionState.phase = 'vaultIdle'
    auctionState.entryFeeRefundable = nil
    deps.presentation.openMenu()
    return true
  end

  function api.startAuctionImmediate()
    if auctionState.phase ~= 'idle' or auctionState.transitionActive then
      return false
    end

    deps.presentation.setAuctionWinEmittersEnabled(false)
    deps.presentation.setAuctionActiveAssetsEnabled(false)

    local playerVeh = be:getPlayerVehicle(0)
    if not playerVeh then
      return false
    end
    auctionState.lastValidPlayerVehId = playerVeh:getID()

    local spots = deps.site.getSiteParkingSpots()
    if not spots or #spots < 1 then
      return false
    end

    deps.presentation.setAuctionRunningTriggerState()
    auctionState.phase = 'starting'
    auctionState.counterPromptActive = false
    auctionState.counterLotBatchSize = pricing.clampLotBatchSize(constants.DEFAULT_LOT_COUNT)
    auctionState.entryCreditRemaining = pricing.roundMoney(deps.payments.getEntryFee())
    auctionState.returnTransform = {
      pos = playerVeh:getPosition(),
      rot = quat(playerVeh:getRefNodeRotation()),
      nativeRotation = true
    }
    require('overhaul/career/market/auction/lots').resetUsedConfigs()

    deps.presentation.runFadedTransition(function()
      -- Site setup is transactional: unwind the visit and refund entry even if placement fails.
      local ok, result = pcall(setupAuctionSite, playerVeh, spots)
      if ok and result then
        return
      end
      if auctionState.phase == 'starting' then
        pcall(api.resetAuction, false)
      end
      deps.payments.refundEntryFee()
      if not ok then
        error(result, 0)
      end
    end)

    return true
  end

  -- Parks each purchased car at a free return spot, or beside the exit when none is free.
  local function distributePurchasedVehiclesAround(pos, baseRot)
    local returnSpots = ((auctionState.siteLayout or {}).returnSpots) or {}
    local availableReturnSpots = {}
    for _, spot in ipairs(returnSpots) do
      table.insert(availableReturnSpots, spot)
    end

    local placed = 0
    for _, inventoryId in ipairs(auctionState.purchasedInventoryIds) do
      local invVeh = overhaul_career_garage_inventory.getVehicle(inventoryId)
      local vehId = invVeh and not invVeh.listedForAuction and overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId)
      local veh = vehId and getObjectByID(vehId)
      if not veh and invVeh and not invVeh.listedForAuction then
        local spawnedVeh = overhaul_career_garage_inventory.spawnVehicle(inventoryId)
        if spawnedVeh then
          vehId = spawnedVeh:getID()
          veh = spawnedVeh
        end
      end

      if veh then
        placed = placed + 1
        local movedToReturnSpot = false
        local returnSpot = deps.presentation.getBestReturnSpotForVehicle(veh:getID(), availableReturnSpots)
        -- Failed spot placement falls back to the exit-side arrangement.
        if returnSpot and returnSpot.moveResetVehicleTo then
          local ok, placedPos = pcall(function()
            return returnSpot:moveResetVehicleTo(veh:getID(), nil, nil, nil, nil, true)
          end)
          if ok and placedPos then
            movedToReturnSpot = true
            deps.presentation.removeSpotFromList(availableReturnSpots, returnSpot)
          end
        end

        if not movedToReturnSpot then
          local row = math.floor((placed - 1) / 2)
          local side = ((placed - 1) % 2 == 0) and 1 or -1
          local offset = vec3((6 + row * 4) * side, -8 - (row * 4), 0)
          local worldOffset = baseRot * offset
          local target = pos + worldOffset
          -- baseRot is already converted for placement and footprint checks.
          local rot = baseRot
          if not require('overhaul/lib/vehicles/placement').place(veh,
            {pos = target, rot = rot}, {requireClear = true}) then
            deps.vehicleControl.cancelLotTransit(vehId)
            deps.vehicleControl.setLotVehicleDriveLock(veh, 'staged')
            deps.vehicleControl.restorePlayerGearboxMode(veh)
            -- A restoring spawn must be discarded without replacing its saved snapshot.
            local restoring = overhaul_career_garage_inventory.isDamageRestorePending(inventoryId)
            overhaul_career_garage_inventory.removeVehicleObject(inventoryId, restoring)
            -- Normal removal snapshots damage asynchronously; reset must not delete it first.
            for _, lot in ipairs(auctionState.lots) do
              if lot.vehId == vehId then lot.vehId = nil end
            end
            veh = nil
            guihooks.trigger('toastrMsg', {type = 'warning', title = 'Auction parking',
              msg = 'No safe parking spot. Your purchased car is in storage.'})
          end
        end
        if veh then
          deps.motion.stopVehicleAI(veh)
          deps.vehicleControl.setLotVehicleDriveLock(veh, 'released')
        end
      end
    end
  end

  function api.exitAuctionArea()
    if auctionState.transitionActive then
      return false
    end

    deps.presentation.closeAuctionOverlayUi()

    local playerVeh = be:getPlayerVehicle(0)
    local exitSpot = auctionState.returnTransform or deps.site.getPlayerExitSpot(auctionState.siteLayout, true)
    if not playerVeh or not exitSpot then
      return false
    end

    local anchorPos = vec3(exitSpot.pos)
    local anchorRot = exitSpot.nativeRotation and quat(0, 0, 1, 0) * quat(exitSpot.rot) or quat(exitSpot.rot)

    deps.presentation.runFadedTransition(function()
      deps.motion.teleportVehicleToSpot(playerVeh, exitSpot)
      distributePurchasedVehiclesAround(anchorPos, anchorRot)

      overhaul_career_saveSystem.saveCurrent()

      api.resetAuction(true)
      auctionState.entryCooldownUntil = deps.getAuctionTime() + constants.ENTRY_RETRIGGER_COOLDOWN_S
    end)

    return true
  end

  -- A player who loads the career inside the vault is moved to the exit, and the entry cooldown starts.
  function api.ejectPlayerFromAuctionInteriorOnCareerLoad()
    local playerVeh = be:getPlayerVehicle(0)
    if not playerVeh then
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

    local exitSpot = deps.site.getPlayerExitSpot(layout, true)
    if not exitSpot then
      return false
    end

    local distToAuctionCenter = (playerVeh:getPosition() - vec3(layout.playerSpot.pos)):length()
    if distToAuctionCenter > constants.LOAD_EJECT_DISTANCE_M then
      return false
    end

    deps.presentation.runFadedTransition(function()
      deps.motion.teleportVehicleToSpot(playerVeh, exitSpot)
      auctionState.entryCooldownUntil = deps.getAuctionTime() + constants.ENTRY_RETRIGGER_COOLDOWN_S
      deps.presentation.setIdleTriggerState()
    end)

    return true
  end

  return api
end

return session
