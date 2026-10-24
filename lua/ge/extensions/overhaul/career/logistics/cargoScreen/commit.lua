-- Cargo-screen commit: applies the delivery configuration, spawns vehicle offers and loads parcels, or cancels it.
-- Read isPassengerOnly, snapshotVehiclesToRefreshWeights, buildSpawnStepsForCommit, involvesVehicle, collectDeletedTransientMoves in order.

-- Part of the Overhaul fork of stock `lua/ge/extensions/career/modules/delivery/cargoScreen.lua`.

local part = {}

-- Built once per cargo screen load.
function part.new(inputs)
  local ext, screen = inputs.ext, inputs.screen

  -- Helpers -----------------------------------------------------------------------------------------

  local function isPassengerOnly(cargoTypes)
    if not cargoTypes then return false end
    local hasPassenger = false
    for _, cargoType in ipairs(cargoTypes) do
      if cargoType ~= "passenger" then return false end
      hasPassenger = true
    end
    return hasPassenger
  end

  local function snapshotVehiclesToRefreshWeights(vehiclesToRefreshWeights)
    if ext.general.rememberCurrentCargoWeightVehicles then
      ext.general.rememberCurrentCargoWeightVehicles()
    end
    for _, cargo in ipairs(ext.parcelManager.getAllCargoInVehicles() or {}) do
      if cargo.location and cargo.location.vehId then
        vehiclesToRefreshWeights[cargo.location.vehId] = true
      end
    end
    if ext.parcelManager.getTransientMoveCargo then
      for _, cargo in ipairs(ext.parcelManager.getTransientMoveCargo() or {}) do
        if cargo.location and cargo.location.vehId then
          vehiclesToRefreshWeights[cargo.location.vehId] = true
        end
        local target = cargo._transientMove and cargo._transientMove.targetLocation
        if target and target.vehId then
          vehiclesToRefreshWeights[target.vehId] = true
        end
      end
    end
  end

  local function buildSpawnStepsForCommit()
    local stepsList = {}
    local vehOffers = ext.vehicleOfferManager.getAllOfferUnexpired()
    for _, offer in ipairs(vehOffers) do
      if offer.spawnWhenCommitingCargo and offer.origin.facId == screen.cargoScreenFacId then
        local offerSteps = (ext.vehicleOfferManager.makeSpawnOfferSteps(offer.id, false, 0.5)) or {}
        for _, st in ipairs(offerSteps) do
          table.insert(stepsList, st)
        end
      end
    end
    return stepsList
  end

  -- Transient moves ---------------------------------------------------------------------------------

  local function involvesVehicle(cargo, targetLoc)
    return targetLoc.type == "vehicle" or (cargo.location and cargo.location.type == "vehicle")
  end

  -- Deletions go first: a supplier that takes the cargo back keeps it, otherwise it is removed.
  local function collectDeletedTransientMoves(allTransientCargo)
    local deletionsToApply = {}
    for _, cargo in ipairs(allTransientCargo) do
      if cargo and cargo._transientMove and cargo._transientMove.targetLocation then
        local targetLoc = cargo._transientMove.targetLocation
        if targetLoc.type == "deleted" then
          table.insert(deletionsToApply, cargo)
          ext.parcelManager.clearTransientMoveForCargo(cargo.id)
        end
      end
    end
    return deletionsToApply
  end

  local function applyDeletedTransientMoves(deletionsToApply)
    for _, cargo in ipairs(deletionsToApply) do
      local passiveBusiness = overhaul_career_business_passive
      local engineShop = overhaul_career_business_engineShop
      if not (engineShop and engineShop.returnCargoToSupplier(cargo, true))
        and not (passiveBusiness and passiveBusiness.returnCargoToSupplier and passiveBusiness.returnCargoToSupplier(cargo, true)) then
        ext.parcelManager.changeCargoLocation(cargo.id, {type="deleted"})
      end
    end
  end

  -- Vehicle spawns hold the other moves back: parcels stay at their provider, vehicle moves wait for the spawn.
  local function holdOrDeferTransientMoves(allTransientCargo, hasVehicleOfferSpawns)
    local deferredCargo = {}
    local heldParcelMoves = 0
    for _, cargo in ipairs(allTransientCargo) do
      if cargo and cargo._transientMove and cargo._transientMove.targetLocation then
        local targetLoc = cargo._transientMove.targetLocation
        if targetLoc.type ~= "deleted" then
          -- Trailer spawns leave parcels at their provider until the player collects them.
          if hasVehicleOfferSpawns and require('overhaul/lib/logistics/cargoSemantics').cargo(cargo.type).parcel then
            heldParcelMoves = heldParcelMoves + 1
            ext.parcelManager.clearTransientMoveForCargo(cargo.id)
          elseif hasVehicleOfferSpawns and involvesVehicle(cargo, targetLoc) then
            local copiedTargetLoc = {}
            for k, v in pairs(targetLoc) do
              copiedTargetLoc[k] = v
            end
            table.insert(deferredCargo, {
              cargoId = cargo.id,
              targetLocation = copiedTargetLoc
            })
            ext.parcelManager.clearTransientMoveForCargo(cargo.id)
          end
        end
      end
    end
    return deferredCargo, heldParcelMoves
  end

  -- A vehicle move that survived the deferral is dropped, with a warning, rather than applied mid-spawn.
  local function dropUndeferredVehicleMoves()
    local remainingVehicleMoves = ext.parcelManager.getTransientMoveCargo()
    for _, cargo in ipairs(remainingVehicleMoves) do
      if cargo and cargo._transientMove and cargo._transientMove.targetLocation then
        local targetLoc = cargo._transientMove.targetLocation
        if involvesVehicle(cargo, targetLoc) and targetLoc.type ~= "deleted" then
          log("W","",string.format("Warning: Vehicle-related transient move for cargo %s was not deferred!", cargo.id))
          ext.parcelManager.clearTransientMoveForCargo(cargo.id)
        end
      end
    end
  end

  local function deferVehicleTransientMovesIfNeeded(hasVehicleOfferSpawns)
    local allTransientCargo = ext.parcelManager.getTransientMoveCargo()
    hasVehicleOfferSpawns = hasVehicleOfferSpawns == true

    local deletionsToApply = collectDeletedTransientMoves(allTransientCargo)
    applyDeletedTransientMoves(deletionsToApply)
    local deferredCargo, heldParcelMoves = holdOrDeferTransientMoves(allTransientCargo, hasVehicleOfferSpawns)
    if hasVehicleOfferSpawns then
      dropUndeferredVehicleMoves()
    end

    local movedCargo, remainingCargo = ext.parcelManager.applyTransientMoves({type="facilityParkingspot",facId=screen.cargoScreenFacId, psPath=screen.cargoScreenPsPath})

    log("I","",string.format("Commited Delivery Configuration. (Cargo Added: %d. Remaining to be loaded: %d. Deferred vehicle moves: %d. Held parcel moves: %d. Deletions applied: %d)",#movedCargo, #remainingCargo, #deferredCargo, heldParcelMoves, #deletionsToApply))
    return movedCargo, remainingCargo, deferredCargo
  end

  local function applyValidDeferredCargo(deferredCargo)
    local validDeferredCargo = {}
    for _, deferred in ipairs(deferredCargo) do
      local cargo = ext.parcelManager.getCargoById(deferred.cargoId)
      if cargo and cargo.location and cargo.location.type ~= "deleted" then
        table.insert(validDeferredCargo, deferred)
        ext.parcelManager.addTransientMoveCargo(deferred.cargoId, deferred.targetLocation)
      end
    end
    if #validDeferredCargo > 0 then
      ext.parcelManager.applyTransientMoves()
      log("I","",string.format("Applied %d deferred transient moves (filtered %d invalid)", #validDeferredCargo, #deferredCargo - #validDeferredCargo))
    end
    return validDeferredCargo
  end

  local function hasLoanersMarkedForSpawning()
    if not screen.cargoScreenFacId then
      return false
    end
    local fac = ext.generator.getFacilityById(screen.cargoScreenFacId)
    if not fac or not fac.hasLoanerSpots then
      return false
    end
    local loanersFormatted = overhaul_career_logistics_loanerVehicles.formatLoanerOfferForUi(fac) or {}
    for _, item in ipairs(loanersFormatted) do
      if item.spawnWhenCommitingCargo then
        return true
      end
    end
    return false
  end

  local function getVehicleIdsForCargoLoad(vehiclesToRefreshWeights)
    local vehIdsLookup = {}
    local playerVehId = be:getPlayerVehicleID(0)
    if playerVehId then
      vehIdsLookup[playerVehId] = true
    end

    for vehId in pairs(vehiclesToRefreshWeights) do
      vehIdsLookup[vehId] = true
    end

    for _, cargo in ipairs(ext.parcelManager.getAllCargoInVehicles()) do
      if cargo.location and cargo.location.vehId then
        vehIdsLookup[cargo.location.vehId] = true
      end
    end

    local vehIds = {}
    for vehId in pairs(vehIdsLookup) do
      local veh = scenetree.findObjectById(vehId)
      if veh and veh:getJBeamFilename() ~= "unicycle" then
        table.insert(vehIds, vehId)
      end
    end
    return vehIds
  end

  -- Parcel loading ----------------------------------------------------------------------------------

  -- Freezes one vehicle, waits out its container reach time, then unfreezes it and reports back.
  local function loadParcelsForVehicle(vehId, containerData, callback)
    local veh = scenetree.findObjectById(vehId)
    if not veh then
      if callback then callback() end
      return
    end

    core_vehicleBridge.executeAction(veh, "overhaulSetCargoContainers", containerData or {}, "updateDelivery")
    core_vehicleBridge.executeAction(veh, 'setFreeze', true)

    core_vehicleBridge.requestValue(veh, function(vehCargoContainerData)
      local maxForContainer = 0
      if vehCargoContainerData and vehCargoContainerData[1] then
        for _, container in ipairs(vehCargoContainerData[1]) do
          if not isPassengerOnly(container.cargoTypes) then
            local reachTimeRemainingS = container.reachTargetTimeRemaining or 0
            maxForContainer = math.max(maxForContainer, reachTimeRemainingS)
          end
        end
      end

      local delay = math.max(maxForContainer, 0)
      local sequence = {}

      if delay > 0 then
        delay = math.max(delay, 1)
        table.insert(sequence, ext.step.makeStepWait(delay + 0.5))
      end

      table.insert(sequence, ext.step.makeStepReturnTrueFunction(function()
        local v = scenetree.findObjectById(vehId)
        if v then
          core_vehicleBridge.executeAction(v, 'setFreeze', false)
        end
        overhaul_integration_services_markerInteraction.setForceReevaluateOpenPrompt()
        return true
      end))

      ext.step.startStepSequence(sequence, function()
        overhaul_integration_services_markerInteraction.setForceReevaluateOpenPrompt()
        if callback then callback() end
      end)

      if delay > 0 then
        guihooks.trigger("OpenSimpleDelayPopup",{timer=delay, heading=_tr("ui.career.delivery.general.loadingCargo")})
      end
      log("I","",string.format("Vehicle %d: %0.2fs delay after adjusting weights for cargo.", vehId, delay))
    end, "overhaulGetCargoContainers")
  end

  -- One loader per commit: its queue holds the vehicles still waiting, and one vehicle loads at a time.
  local function startNextParcelLoad(loader)
    if loader.inProgress then return end
    local req = table.remove(loader.queue, 1)
    if not req then return end

    loader.inProgress = true
    loadParcelsForVehicle(req.vehId, req.containerData, function()
      loader.inProgress = false
      if req.callback then req.callback() end
      startNextParcelLoad(loader)
    end)
  end

  -- Container load for each vehicle that is still in the commit's set, from the cargo it carries.
  local function containerLoadsByVehicle(vehIds)
    local updatePerVehicle = {}
    for _, vehId in ipairs(vehIds) do
      local veh = scenetree.findObjectById(vehId)
      if veh and veh:getJBeamFilename() ~= "unicycle" then
        updatePerVehicle[vehId] = {}
      end
    end

    for _, cargo in ipairs(ext.parcelManager.getAllCargoInVehicles()) do
      if cargo.location.vehId and updatePerVehicle[cargo.location.vehId] then
        updatePerVehicle[cargo.location.vehId][cargo.location.containerId] = updatePerVehicle[cargo.location.vehId][cargo.location.containerId] or {
          volume = 0,
          density = 1,
          containerId = cargo.location.containerId
        }

        require('overhaul/lib/logistics/cargoSemantics').addContainerLoad(
          updatePerVehicle[cargo.location.vehId][cargo.location.containerId], cargo)
      end
    end
    return updatePerVehicle
  end

  local function loadParcelsForVehicleGroup(loader, vehIds, callback)
    local updatePerVehicle = containerLoadsByVehicle(vehIds)

    loader.queue = {}
    for vehId, containerData in pairs(updatePerVehicle) do
      local vid = vehId
      local cdata = containerData
      table.insert(loader.queue, {
        vehId = vid,
        containerData = cdata,
        callback = function()
          log("I","",string.format("Finished loading parcels for vehicle %d", vid))
        end
      })
    end

    if #loader.queue > 0 then
      log("I","",string.format("Queueing %d vehicles for parcel loading", #loader.queue))
      local parcelsLoaded = 0
      local totalParcels = #loader.queue

      local function onParcelLoadComplete()
        parcelsLoaded = parcelsLoaded + 1
        if parcelsLoaded >= totalParcels then
          if callback then callback() end
        end
      end

      for _, req in ipairs(loader.queue) do
        local originalCallback = req.callback
        req.callback = function()
          if originalCallback then originalCallback() end
          onParcelLoadComplete()
        end
      end

      startNextParcelLoad(loader)
    else
      if callback then callback() end
    end
  end

  -- Each commit gets its own queue, so a finished commit cannot hold up the next one.
  local function createParcelLoader()
    local loader = {queue = {}, inProgress = false}
    return function(vehIds, callback)
      loadParcelsForVehicleGroup(loader, vehIds, callback)
    end
  end

  -- Commit ------------------------------------------------------------------------------------------

  -- An owner-operator contract blocks per-diem cargo and offers; returns true when it blocked this commit.
  local function blockedByOwnerOperator(brokerCallback)
    local activeOwnerOp = inputs.getActiveOwnerOpContract()
    if not (activeOwnerOp and not brokerCallback) then return false end
    for _, offer in ipairs(ext.vehicleOfferManager.getAllOfferUnexpired() or {}) do
      if offer.spawnWhenCommitingCargo and inputs.ownerOpBlocksPerDiemOffer(offer) then
        ui_message(inputs.OWNER_OP_PER_DIEM_BLOCK.label, 6, "warning")
        return true
      end
    end
    if ext.parcelManager.getTransientMoveCargo then
      for _, cargo in ipairs(ext.parcelManager.getTransientMoveCargo() or {}) do
        local fromFacility = cargo.location and cargo.location.type == "facilityParkingspot"
        if fromFacility and inputs.ownerOpBlocksPerDiemOffer(cargo) then
          ui_message(inputs.OWNER_OP_PER_DIEM_BLOCK.label, 6, "warning")
          return true
        end
      end
    end
    return false
  end

  local function startVehicleSpawnSequence(spawnSteps, afterSpawn)
    inputs.setVehicleSpawnInProgress(true)
    local vehicleSpawnSequence = {}
    table.insert(vehicleSpawnSequence, ext.step.makeStepFadeToBlack(0.4))

    for _, st in ipairs(spawnSteps) do
      table.insert(vehicleSpawnSequence, st)
    end

    table.insert(vehicleSpawnSequence, ext.step.makeStepReturnTrueFunction(function()
      overhaul_integration_services_markerInteraction.setForceReevaluateOpenPrompt()
      return true
    end))

    table.insert(vehicleSpawnSequence, ext.step.makeStepFadeFromBlack(0.4))

    ext.step.startStepSequence(vehicleSpawnSequence, function()
      overhaul_career_logistics_loanerVehicles.spawnAllOffers(afterSpawn)
    end)
  end

  local function finishDeliveryCommit(brokerCallback)
    inputs.setVehicleSpawnInProgress(false)
    local postCommitTransientCargo = ext.parcelManager.getTransientMoveCargo()
    screen.pendingTransientMoves = #postCommitTransientCargo > 0
    gameplay_rawPois.clear()
    overhaul_integration_services_markerInteraction.setForceReevaluateOpenPrompt()
    if type(brokerCallback)=='function' then brokerCallback() end
  end

  -- call this function to commit the configuration and clear all transient flags.
  local function commitDeliveryConfiguration(brokerCallback)
    if blockedByOwnerOperator(brokerCallback) then return end

    local vehiclesToRefreshWeights = {}
    snapshotVehiclesToRefreshWeights(vehiclesToRefreshWeights)

    local spawnSteps = buildSpawnStepsForCommit()
    local hasVehicleOfferSpawns = spawnSteps and #spawnSteps > 0
    local movedCargo, remainingCargo, deferredCargo = deferVehicleTransientMovesIfNeeded(hasVehicleOfferSpawns)

    local allTransientCargo = ext.parcelManager.getTransientMoveCargo()
    screen.pendingTransientMoves = #allTransientCargo > 0 or #deferredCargo > 0

    if not overhaul_career_logistics_general.isDeliveryModeActive() and (#movedCargo > 0 or #remainingCargo > 0) then
      ext.general.startDeliveryMode()
    end
    overhaul_career_logistics_tasklist.sendCargoToTasklist()

    local hasLoanersToSpawn = hasLoanersMarkedForSpawning()

    local loadParcelsForVehicleGroup = createParcelLoader()

    local function finishCommit() finishDeliveryCommit(brokerCallback) end

    local function afterLoanersSpawned()
      applyValidDeferredCargo(deferredCargo)
      deferredCargo = {} -- clear reference for GC

      local vehIdsToLoad = getVehicleIdsForCargoLoad(vehiclesToRefreshWeights)
      if next(vehIdsToLoad) then
        loadParcelsForVehicleGroup(vehIdsToLoad, finishCommit)
      else
        finishCommit()
      end
    end

    if hasVehicleOfferSpawns or #deferredCargo > 0 then
      startVehicleSpawnSequence(spawnSteps, afterLoanersSpawned)
    elseif hasLoanersToSpawn then
      -- spawnAllOffers has its own fade. A dummy fade sequence here nested
      -- startStepSequence and skipped the loaner's fade-to-black.
      inputs.setVehicleSpawnInProgress(true)
      overhaul_career_logistics_loanerVehicles.spawnAllOffers(afterLoanersSpawned)
    else
      applyValidDeferredCargo(deferredCargo)
      deferredCargo = {} -- clear reference for GC

      local vehIdsToLoad = getVehicleIdsForCargoLoad(vehiclesToRefreshWeights)
      if next(vehIdsToLoad) then
        inputs.setVehicleSpawnInProgress(true)
        loadParcelsForVehicleGroup(vehIdsToLoad, finishCommit)
      else
        finishCommit()
      end
    end
  end

  -- Cancel ------------------------------------------------------------------------------------------

  -- call this function to cancel the delivery - all cargo will be placed back.
  local function cancelDeliveryConfiguration()
    ext.parcelManager.clearAllTransientMoves()
    screen.pendingTransientMoves = false
    inputs.setVehicleSpawnInProgress(false)
    for _, offer in ipairs(ext.vehicleOfferManager.getAllOfferCustomFilter(function() return true end)) do
      offer.spawnWhenCommitingCargo = nil
    end
    overhaul_career_logistics_loanerVehicles.unmarkAllForSpawning()
    ext.general.getNearbyVehicleCargoContainers(nop)
    ui_message(_tr("ui.career.delivery.cargoScreen.cancelledDeliveryConfiguration"))
  end

  return {
    cancelDeliveryConfiguration = cancelDeliveryConfiguration,
    commitDeliveryConfiguration = commitDeliveryConfiguration,
  }
end

return part
