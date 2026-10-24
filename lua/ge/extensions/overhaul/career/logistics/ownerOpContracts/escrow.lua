-- Contract escrow. Map: payout guards, haul completion, active contract, hub capture/stops/top-up, delivery credit, reload re-link.
-- Read contractPayout, payEscrowRewards, addCarHaulEscrowRewards, markCarHaulOfferDelivered, countCarHaulStatuses in order.

local recordContract = require("overhaul/lib/progression/logbookFeed").register("overhaul.brokerContractCompleted", {
  title = "Broker contract completed", label = "Logistics", icon = "deliveryTruck"
}, "career/logistics/ownerOpContracts/escrow.lua")

local part = {}
local ORIGIN_RADIUS_M = 35
local STOP_ARRIVAL_RADIUS_M = 25

-- inputs: state (the shared board record), balance, catalog, generation, acceptance and logTag. Nothing is kept at file level, so each owner-operator load gets its own closures over its own state.
-- Payout guard and legs -----------------------------------------------------------------------------

local function installPayouts(helpers, inputs)
  local payoutAttempts = setmetatable({}, { __mode = "k" })

  -- Runs one payout for the active record at most once. A refusal or an error marks the contract interrupted, because a partial backend mutation cannot be replayed safely after a profile reload.
  function helpers.contractPayout(call)
    local active = inputs.state.active
    if active.payoutInterrupted or payoutAttempts[active] then return false end
    payoutAttempts[active] = true
    local ok, accepted, problem = pcall(call)
    if not ok or accepted ~= true then
      active.payoutInterrupted = true
      local failure = problem
      if not ok then failure = accepted end
      log("E", inputs.logTag, "Contract payment interrupted: " .. tostring(failure))
      ui_message("Payment failed. This contract remains open.", 8, "warning")
      if not ok then error(accepted, 0) end
      return false
    end
    return true
  end

  -- Pays each escrowed leg in pairs() order and stops at the first refused leg; earlier legs stay paid.
  function helpers.payEscrowRewards(rewards)
    -- A backend can mutate before refusing or throwing. Never replay completed legs on a tick.
    return helpers.contractPayout(function()
      for key, amount in pairs(rewards) do
        local value = tonumber(amount) or 0
        if value ~= 0 then
          local accepted, problem = nil, nil
          if key == "money" then
            accepted, problem = inputs.catalog.payMoney(value, "Owner-op contract")
          else
            local payment = overhaul_career_economy_payment
            if not payment then return false, "Payment is unavailable" end
            accepted, problem = payment.payout({
              xp = { [key] = value },
              tags = { "gameplay", "deliveryReward" },
              label = "Owner-op contract",
            })
          end
          if accepted ~= true then return false, problem end
        end
      end
      return true
    end)
  end
end

-- Car-haul escrow ----------------------------------------------------------------------------------

local function installCarHaulEscrow(api, helpers, inputs)
  function helpers.addCarHaulEscrowRewards(rewards)
    if type(rewards) ~= "table" then return end
    inputs.state.active.escrowedRewards = inputs.state.active.escrowedRewards or {}
    for key, amount in pairs(rewards) do
      local value = tonumber(amount) or 0
      if value ~= 0 then
        inputs.state.active.escrowedRewards[key] = (tonumber(inputs.state.active.escrowedRewards[key]) or 0) + value
      end
    end
    inputs.state.active.escrowedMoney = math.floor(tonumber(inputs.state.active.escrowedRewards.money) or 0)
  end

  function helpers.markCarHaulOfferDelivered(offerData)
    if not inputs.state.active or inputs.state.active.kind ~= "finkHaul" or type(offerData) ~= "table" then return false end
    local offer = offerData.offer or offerData
    local data = offer and offer.data
    if not data or tostring(data.finkContractId) ~= tostring(inputs.state.active.id) then return false end
    local vehKey = data.finkVehicleKey
    local veh = nil
    for _, candidate in ipairs(inputs.state.active.vehicles or {}) do
      if tostring(candidate.key) == tostring(vehKey) then
        veh = candidate
        break
      end
    end
    if not veh then return false end
    if veh.status == "delivered" then return false end
    veh.status = "delivered"
    helpers.addCarHaulEscrowRewards(offerData.adjustedRewards or (offer and offer.rewards))
    return true
  end

  function helpers.countCarHaulStatuses()
    local vehicles = inputs.state.active.vehicles
    return inputs.catalog.countVehiclesByStatus(vehicles, "pending"),
      inputs.catalog.countVehiclesByStatus(vehicles, "staged"),
      inputs.catalog.countVehiclesByStatus(vehicles, "delivered")
  end

  -- Takes a delivered leg out of the native drop-off payout; a leg that is not in the payout is left alone.
  function helpers.deductDeliveredRewards(payoutSum, rewards)
    for key, amount in pairs(rewards) do
      local value = tonumber(amount) or 0
      if value ~= 0 and payoutSum[key] ~= nil then
        payoutSum[key] = (tonumber(payoutSum[key]) or 0) - value
        if math.abs(payoutSum[key]) < 0.0001 then payoutSum[key] = nil end
      end
    end
  end

  -- Adds the whole escrow to the native payout once every car is delivered.
  function helpers.addEscrowToPayout(payoutSum)
    for key, amount in pairs(inputs.state.active.escrowedRewards or {}) do
      local value = tonumber(amount) or 0
      if value ~= 0 then payoutSum[key] = (tonumber(payoutSum[key]) or 0) + value end
    end
  end

  -- Drop-off pays into escrow until every car on the contract is delivered.
  function api.consumeVehicleDropOffForContractEscrow(payoutSum, dropOffData)
    if type(payoutSum) ~= "table" or not inputs.state.active or inputs.state.active.kind ~= "finkHaul" then return payoutSum, nil end
    local touched = false
    for _, offerData in ipairs((dropOffData and dropOffData.offers) or {}) do
      if helpers.markCarHaulOfferDelivered(offerData) then
        touched = true
        helpers.deductDeliveredRewards(payoutSum, offerData.adjustedRewards or {})
      end
    end
    if not touched then return payoutSum, nil end

    local pending, staged, delivered = helpers.countCarHaulStatuses()
    local progress = {
      kind = "finkHaul",
      id = inputs.state.active.id,
      name = "Distributor contract",
      deliveredCount = delivered,
      totalCount = #(inputs.state.active.vehicles or {}),
      pendingCount = pending,
      stagedCount = staged,
      escrowedMoney = math.floor(tonumber(inputs.state.active.escrowedMoney) or 0),
      escrowedRewards = deepcopy(inputs.state.active.escrowedRewards or {}),
      complete = pending == 0 and staged == 0 and delivered > 0,
    }

    if progress.complete then
      helpers.addEscrowToPayout(payoutSum)
      ui_message(string.format("Distributor contract complete. %d cars delivered.", delivered), 8, "success")
      inputs.state.active = nil
      inputs.generation.rebuildContracts(false)
    elseif inputs.state.active.phase == "hauling" and pending > 0 and staged == 0 then
      inputs.state.active.phase = "planTrip"
      ui_message("Trip delivered. Pay is held until the full contract is finished.", 7, "info")
    end
    return payoutSum, progress
  end
end

-- Completion checks ---------------------------------------------------------------------------------

local function installCarHaulCompletion(api, helpers, inputs)
  -- Marks staged cars whose native offer has been delivered; returns whether any car changed.
  function helpers.markDeliveredCars()
    local changed = false
    for _, veh in ipairs(inputs.state.active.vehicles or {}) do
      if veh.status == "staged" and inputs.acceptance.isCarHaulVehicleDelivered(veh) then
        veh.status = "delivered"
        changed = true
      end
    end
    return changed
  end

  -- Runs on the tick: a finished contract pays its escrow once, and a trip with no staged cars left is planned again.
  function api.trackCarHaulDeliveries()
    if not inputs.state.active or inputs.state.active.kind ~= "finkHaul" then return end
    local progress = overhaul_career_logistics_progress
    if progress and progress.isSettlementPending() then return end
    if not helpers.markDeliveredCars() then return end

    local pending, staged, delivered = helpers.countCarHaulStatuses()
    if pending == 0 and staged == 0 and delivered > 0 then
      local escrow = math.floor(tonumber(inputs.state.active.escrowedMoney) or 0)
      local rewards = deepcopy(inputs.state.active.escrowedRewards or {})
      if escrow > 0 or next(rewards) then
        if not helpers.payEscrowRewards(rewards) then return end
        ui_message(string.format("Distributor contract complete. Paid $%d.", escrow), 8, "success")
      else
        ui_message(string.format("Distributor contract complete. %d cars delivered.", delivered), 8, "success")
      end
      recordContract({detail = (inputs.state.active.name or "Distributor haul") .. " / " .. tostring(delivered) .. " cars delivered", money = escrow})
      inputs.state.active = nil
      inputs.generation.rebuildContracts(false)
      return
    end

    if inputs.state.active.phase == "hauling" and pending > 0 and staged == 0 then
      inputs.state.active.phase = "planTrip"
      ui_message("Trip delivered. Plan your next yard run on the Logistics app.", 7, "info")
    end
  end
end

-- Accepting and reading the active contract -------------------------------------------------------

local function installActiveContract(api, inputs)
  function api.acceptContract(contractId)
    if not inputs.catalog.ownerOpUnlocked() then return false, "Reach Logistics level 30 for owner-operator contracts." end
    if inputs.state.active then return false, "Finish the active owner-operator contract first." end
    if overhaul_career_work_employment.isOnShift() then
      return false, "End your company shift before taking owner-operator contracts."
    end
    inputs.generation.rebuildContracts(false)
    local contract = inputs.state.contracts[contractId]
    if not contract and inputs.state.active and inputs.state.active.id == contractId and inputs.state.active.kind == "finkHaul" then
      return false, "This distributor contract is already active."
    end
    if not contract then return false, "Contract expired. Refresh the board." end
    if contract.kind == "finkHaul" then return inputs.acceptance.acceptCarHaul(contract) end
    return inputs.acceptance.acceptBps(contract)
  end

  function api.getActiveContract()
    if inputs.state.active and inputs.state.active.kind == "finkHaul" then return inputs.acceptance.getActiveCarHaulSnapshot() end
    if inputs.state.active and inputs.state.active.stringMode then
      local stop = inputs.state.active.stops and inputs.state.active.stops[inputs.state.active.stopIndex or 1]
      return {
        id = inputs.state.active.id,
        kind = inputs.state.active.kind,
        pay = inputs.state.active.pay,
        phase = inputs.state.active.phase,
        stringMode = true,
        stopIndex = inputs.state.active.stopIndex or 1,
        stopCount = inputs.state.active.stopCount or #(inputs.state.active.stops or {}),
        deliveredStops = inputs.state.active.deliveredStops or 0,
        qty = inputs.state.active.qty,
        loadSlots = inputs.state.active.loadSlots,
        currentDestName = stop and stop.destName or nil,
        destFacId = inputs.state.active.destFacId,
        originFacId = inputs.state.active.originFacId,
        logisticType = inputs.state.active.logisticType,
        stops = inputs.state.active.stops,
      }
    end
    return inputs.state.active
  end

  function api.isHubContract()
    return inputs.state.active
      and (
        inputs.state.active.kind == "hubDistribute"
        or inputs.state.active.kind == "hubAB"
        or inputs.state.active.kind == "bpsHub"
        or inputs.state.active.kind == "bpsAB"
        or inputs.state.active.kind == "bpsPort"
      )
  end

  function api.abandonHubContract(contractId)
    if not api.isHubContract() then return false, "No active hub contract to abandon." end
    if not contractId or tostring(inputs.state.active.id) ~= tostring(contractId) then
      return false, "The active hub contract changed. Please review it before abandoning."
    end
    local materialId = inputs.state.active.nativeMaterialContractId
    inputs.state.contracts[inputs.state.active.id] = nil
    inputs.state.active = nil
    if materialId then
      overhaul_career_logistics_materialContractManager.abandonContract(materialId)
    end
    return true, materialId and "Hub and material order abandoned." or "Hub contract abandoned. Your native delivery jobs remain active."
  end
end

-- Hub loads -----------------------------------------------------------------------------------------

local function installHubLoads(api, helpers, inputs)
  function helpers.hubCargoKind(cargo)
    if not cargo.materialType then return "delivery_parcel" end
    return inputs.catalog.logisticTypeHeatLeaf(cargo.materialType)
  end

  function api.hubCargoMatches(cargo, destFacId)
    if not (destFacId and cargo and cargo.id and cargo.origin and cargo.origin.facId == inputs.state.active.originFacId) then
      return false
    end
    if helpers.hubCargoKind(cargo) ~= inputs.catalog.logisticTypeHeatLeaf(inputs.state.active.logisticType) then return false end
    local template = cargo.templateId and require('overhaul/lib/logistics/templates').getTemplateById(cargo.templateId)
    local logisticType = cargo.logisticType or (template and template.logisticType)
    if logisticType and logisticType ~= inputs.state.active.logisticType then return false end
    if inputs.state.active.nativeMaterialContractId
      and (cargo.materialType ~= inputs.state.active.logisticType or not cargo.data
        or cargo.data.materialContractId ~= inputs.state.active.nativeMaterialContractId) then return false end
    local dest = cargo.destination
    if dest and dest.facId == destFacId then return true end
    if dest and dest.type == "multi" then
      for _, loc in ipairs(dest.destinations or {}) do
        if loc.facId == destFacId then return true end
      end
    end
    return false
  end

  function helpers.requiredHubLoad(cargo)
    if inputs.catalog.logisticTypeHeatLeaf(inputs.state.active.logisticType) == "delivery_parcel" then
      return math.max(1, tonumber(inputs.state.active.loadSlots) or 1)
    end
    local gen = overhaul_career_logistics_generator
    local material = cargo and gen and gen.getMaterialsTemplatesById(cargo.materialType)
    local _, capacity = inputs.balance.getMaterialPay(material)
    return capacity
  end

  function helpers.vehicleAtOrigin(vehId, originPos)
    local veh = vehId and be:getObjectByID(vehId)
    return veh and originPos and veh:getPosition():squaredDistance(originPos) <= (ORIGIN_RADIUS_M * ORIGIN_RADIUS_M)
  end

  -- A trailer trip counts once its trailer task starts at the origin and ends at this contract's destination.
  function helpers.captureTrailerLoad(proof, originPos)
    local tasks = overhaul_career_logistics_vehicleTasks
    for _, task in ipairs(tasks and tasks.getVehicleTasks() or {}) do
      local offer = task.offer
      local dest = offer and (offer.destination or (offer.task and offer.task.destination))
      if
        not task.remove
        and offer
        and offer.id
        and offer.data
        and offer.data.type == "trailer"
        and (not offer.lookupType or offer.lookupType == inputs.state.active.logisticType)
        and offer.origin
        and offer.origin.facId == inputs.state.active.originFacId
        and dest
        and dest.facId == inputs.state.active.destFacId
        and helpers.vehicleAtOrigin(task.vehId, originPos)
      then
        proof.trailers[tostring(offer.id)] = inputs.state.active.destFacId
        proof.amount = proof.amount + 1
      end
    end
    proof.required = 1
  end

  -- The destination a cargo load is credited to: the contract's one destination, or for a string the first stop it matches.
  function helpers.cargoDestinationFor(cargo)
    if not inputs.state.active.stringMode then return inputs.state.active.destFacId end
    for _, stop in ipairs(inputs.state.active.stops or {}) do
      local delivered = (inputs.state.active.deliveredByStop or {})[stop.destFacId] or 0
      if delivered < (tonumber(stop.slots) or 1) and api.hubCargoMatches(cargo, stop.destFacId) then return stop.destFacId end
    end
    return nil
  end

  -- Loads native cargo at the origin. A non-parcel load keeps one material type, taken from the first match.
  function helpers.captureCargoLoad(proof, kind, originPos)
    local parcels = overhaul_career_logistics_parcelManager
    local materialType = nil
    for _, cargo in ipairs(parcels and parcels.getAllCargoInVehicles() or {}) do
      if cargo.location and cargo.location.type == "vehicle" and helpers.vehicleAtOrigin(cargo.location.vehId, originPos) then
        local destFacId = helpers.cargoDestinationFor(cargo)
        if
          destFacId
          and api.hubCargoMatches(cargo, destFacId)
          and (kind == "delivery_parcel" or not materialType or cargo.materialType == materialType)
        then
          materialType = materialType or cargo.materialType
          if cargo.materialType then
            cargo.data = cargo.data or {}
            cargo.data.ownerOpSourceCargoId = cargo.id
          end
          local amount = math.max(0, tonumber(cargo.slots) or 0)
          proof.cargo[tostring(cargo.id)] = { amount = amount, destFacId = destFacId }
          proof.amount = proof.amount + amount
          proof.byStop[destFacId] = (proof.byStop[destFacId] or 0) + amount
          proof.required = proof.required or helpers.requiredHubLoad(cargo)
        end
      end
    end
  end

  -- A hub trip must be backed by native cargo or a native trailer task. The native drop-off callback below is the only place that credits its delivery.
  function helpers.captureHubLoad()
    local kind = inputs.catalog.logisticTypeHeatLeaf(inputs.state.active.logisticType)
    local proof = { cargo = {}, trailers = {}, delivered = {}, amount = 0, byStop = {} }
    local gen = overhaul_career_logistics_generator
    local originPos = gen
      and gen.getLocationCoordinates(inputs.catalog.makeLoc(inputs.state.active.originFacId, inputs.state.active.originPsPath))
    if kind == "delivery_trailer" then
      helpers.captureTrailerLoad(proof, originPos)
    else
      helpers.captureCargoLoad(proof, kind, originPos)
    end
    if inputs.state.active.materialAmountRequired or inputs.state.active.stringMode then proof.required = proof.amount end
    if proof.amount <= 0 then return nil end
    if not proof.required or proof.amount < proof.required then return nil end
    return proof
  end
end

-- Hub stops and top-up ------------------------------------------------------------------------------

local function installHubStops(helpers, inputs)
  -- A string hub run moves to its next stop; returns true when a later stop remains.
  function helpers.advanceStringStop()
    local stopIndex = inputs.state.active.stopIndex or 1
    inputs.state.active.deliveredStops = (inputs.state.active.deliveredStops or 0) + 1
    if stopIndex >= #inputs.state.active.stops then return false end
    inputs.state.active.stopIndex = stopIndex + 1
    local nextStop = inputs.state.active.stops[inputs.state.active.stopIndex]
    inputs.state.active.destFacId, inputs.state.active.destPsPath = nextStop.destFacId, nextStop.destPsPath
    inputs.acceptance.routeTo(nextStop.destFacId, nextStop.destPsPath)
    ui_message(
      string.format(
        "Stop %d done. Pay held. Next: stop %d/%d · %s.",
        stopIndex,
        inputs.state.active.stopIndex,
        #inputs.state.active.stops,
        nextStop.destName or "destination"
      ),
      7,
      "info"
    )
    return true
  end

  -- A load run counts one completed load; returns true when more loads remain.
  function helpers.advanceLoadTrip()
    inputs.state.active.tripsCompleted = (inputs.state.active.tripsCompleted or 0) + 1
    if inputs.state.active.materialAmountRequired then
      if (inputs.state.active.materialAmountDelivered or 0) >= inputs.state.active.materialAmountRequired then return false end
    elseif inputs.state.active.tripsCompleted >= (inputs.state.active.tripsRequired or 1) then return false end
    inputs.state.active.phase, inputs.state.active.loadProof = "pickup", nil
    inputs.acceptance.routeTo(inputs.state.active.originFacId, inputs.state.active.originPsPath)
    ui_message(
      string.format(
        "Load %d/%d delivered. Return for the next load.",
        inputs.state.active.tripsCompleted,
        inputs.state.active.tripsRequired
      ),
      7,
      "info"
    )
    return true
  end

  -- The native delivery already awards its own money. The contract quote is the total target for these loads, so only pay the remaining difference.
  function helpers.finishHubContract()
    local topUp = math.max(0, math.floor((tonumber(inputs.state.active.pay) or 0) - (tonumber(inputs.state.active.nativeMoney) or 0)))
    if not helpers.contractPayout(function() return inputs.catalog.payMoney(topUp, "Owner-op contract") end) then return end
    recordContract({detail = (inputs.state.active.name or "Owner-op load") .. " / Contract top-up", money = topUp})
    ui_message(string.format("Contract complete. Contract top-up $%d.", topUp), 7, "success")
    inputs.state.contracts[inputs.state.active.id] = nil
    inputs.state.active = nil
  end

  function helpers.completeHubStop()
    if inputs.state.active.stringMode and inputs.state.active.stops then
      if helpers.advanceStringStop() then return end
    elseif helpers.advanceLoadTrip() then
      return
    end
    helpers.finishHubContract()
  end
end

-- Delivery credit -----------------------------------------------------------------------------------

local function installDeliveryCredit(api, helpers, inputs)
  function api.creditHubDelivery(id, sourceId, destFacId, amount, trailer, nativeMoney)
    if not api.isHubContract() or inputs.state.active.phase ~= "dropoff" or not inputs.state.active.loadProof then return end
    if not inputs.state.active.stringMode and destFacId ~= inputs.state.active.destFacId then return end
    local proof = inputs.state.active.loadProof
    local key = tostring(id)
    if proof.delivered[key] then return end
    local sourceKey = tostring(sourceId or id)
    local loaded = trailer and proof.trailers[key] or proof.cargo[sourceKey]
    if not loaded or (trailer and loaded ~= destFacId) or (not trailer and loaded.destFacId ~= destFacId) then
      return
    end
    proof.creditedByCargo = proof.creditedByCargo or {}
    local credited = proof.creditedByCargo[sourceKey] or 0
    local credit = trailer and 1 or math.min(math.max(0, tonumber(amount) or 0), math.max(0, loaded.amount - credited))
    if credit <= 0 then return end
    proof.delivered[key] = true
    if not trailer then
      proof.creditedByCargo[sourceKey] = credited + credit
      proof.completedCargo = proof.completedCargo or {}
      if proof.creditedByCargo[sourceKey] >= loaded.amount then proof.completedCargo[sourceKey] = true end
    end
    inputs.state.active.nativeMoney = (tonumber(inputs.state.active.nativeMoney) or 0) + math.max(0, tonumber(nativeMoney) or 0)
    if inputs.state.active.stringMode then
      proof.deliveredByStop = proof.deliveredByStop or {}
      proof.deliveredByStop[destFacId] = (proof.deliveredByStop[destFacId] or 0) + credit
      inputs.state.active.deliveredByStop = inputs.state.active.deliveredByStop or {}
      local totals = inputs.state.active.deliveredByStop
      totals[destFacId] = (totals[destFacId] or 0) + credit
      proof.deliveredAmount = (proof.deliveredAmount or 0) + credit
      -- A refused final top-up retains the stop, so it cannot be consumed again.
      while inputs.state.active and inputs.state.active.stringMode and not inputs.state.active.payoutInterrupted do
        local stop = inputs.state.active.stops[inputs.state.active.stopIndex]
        if (totals[stop.destFacId] or 0) < (tonumber(stop.slots) or 1) then break end
        helpers.completeHubStop()
      end
      if inputs.state.active and not inputs.state.active.payoutInterrupted and proof.deliveredAmount >= proof.amount then
        inputs.state.active.phase, inputs.state.active.loadProof = "pickup", nil
        inputs.acceptance.routeTo(inputs.state.active.originFacId, inputs.state.active.originPsPath)
        ui_message("Load delivered. Return to the hub for the remaining stop quantities.", 7, "info")
      end
      return
    end
    proof.deliveredAmount = (proof.deliveredAmount or 0) + credit
    if inputs.state.active.materialAmountRequired then
      inputs.state.active.materialAmountDelivered = (inputs.state.active.materialAmountDelivered or 0) + credit
    end
    if proof.deliveredAmount >= proof.required then
      proof.deliveredAmount = 0
      helpers.completeHubStop()
    end
  end

  -- Runs on the tick: a player who reaches the pickup within range confirms the load.
  function api.advanceBpsIfNear()
    if not api.isHubContract() then return end
    local gen = overhaul_career_logistics_generator
    if not gen then return end
    local playerVeh = getPlayerVehicle(0)
    if not playerVeh then return end
    local pos = playerVeh:getPosition()
    local function near(facId, psPath)
      local p = gen.getLocationCoordinates(inputs.catalog.makeLoc(facId, psPath))
      return p and pos:squaredDistance(p) <= (STOP_ARRIVAL_RADIUS_M * STOP_ARRIVAL_RADIUS_M)
    end
    if inputs.state.active.phase == "pickup" and near(inputs.state.active.originFacId, inputs.state.active.originPsPath) then
      local proof = helpers.captureHubLoad()
      if proof then
        inputs.state.active.loadProof = proof
        inputs.state.active.phase = "dropoff"
        local target = inputs.state.active
        if target.stringMode then
          for _, stop in ipairs(target.stops or {}) do
            if (proof.byStop[stop.destFacId] or 0) > 0 then target = stop; break end
          end
        end
        inputs.acceptance.routeTo(target.destFacId, target.destPsPath)
        ui_message("Load confirmed. Complete the native delivery at the marked destination.", 6, "info")
      end
    end
  end
end

-- Reload -------------------------------------------------------------------------------------------

local function installReloadReconciliation(api, helpers, inputs)
  function helpers.findCarHaulOfferForVehicle(contractId, veh)
    local vom = overhaul_career_logistics_vehicleOfferManager
    if not vom then return nil end
    if veh.offerId then
      local offer = vom.getOfferById(veh.offerId)
      local data = offer and offer.data
      if
        data
        and data.finkContractId == contractId
        and data.finkVehicleKey == veh.key
        and offer.offerExpiresAt ~= 0
      then
        return offer
      end
    end
    for _, offer in ipairs(vom.getAllOfferCustomFilter(function(o) return o.brokerId or not o.spawned end) or {}) do
      local data = offer.data
      if
        data
        and data.finkContractId == contractId
        and data.finkVehicleKey == veh.key
        and offer.offerExpiresAt ~= 0
      then
        return offer
      end
    end
    return nil
  end

  -- Points each staged or delivered car at its native offer after a reload; a staged car with no offer goes back to pending.
  function helpers.relinkCarHaulOffers()
    for _, veh in ipairs(inputs.state.active.vehicles) do
      if veh.status == "staged" or veh.status == "delivered" then
        local offer = helpers.findCarHaulOfferForVehicle(inputs.state.active.id, veh)
        if offer then
          veh.offerId = offer.id
          if veh.status == "staged" and inputs.acceptance.isCarHaulVehicleDelivered(veh) then veh.status = "delivered" end
        elseif veh.status == "staged" then
          veh.status = "pending"
          veh.offerId = nil
        end
      end
    end
  end

  function api.reconcileCarHaulAfterLoad()
    if inputs.state.active and inputs.state.active.payoutInterrupted then
      ui_message("This contract remains open because its payment was interrupted.", 8, "warning")
      return
    end
    if not inputs.state.active or inputs.state.active.kind ~= "finkHaul" then return end

    inputs.state.active.spawning = nil
    inputs.state.active.pendingOfferIds = nil

    if type(inputs.state.active.vehicles) ~= "table" or not inputs.state.active.vehicles[1] then
      inputs.state.active = nil
      return
    end

    helpers.relinkCarHaulOffers()

    local pending, staged, delivered = helpers.countCarHaulStatuses()

    if inputs.state.active.phase == "staging" then inputs.state.active.phase = staged > 0 and "hauling" or "planTrip" end

    if pending == 0 and staged == 0 and delivered > 0 then
      local escrow = math.floor(tonumber(inputs.state.active.escrowedMoney) or 0)
      local rewards = deepcopy(inputs.state.active.escrowedRewards or {})
      if next(rewards) then
        if not helpers.payEscrowRewards(rewards) then return end
        ui_message(string.format("Distributor contract complete. Paid $%d.", escrow), 8, "success")
      else
        ui_message(string.format("Distributor contract complete. %d cars delivered.", delivered), 8, "success")
      end
      recordContract({detail = (inputs.state.active.name or "Distributor haul") .. " / " .. tostring(delivered) .. " cars delivered", money = escrow})
      inputs.state.active = nil
      inputs.generation.rebuildContracts(false)
      return
    end

    if inputs.state.active.phase == "hauling" and pending > 0 and staged == 0 then inputs.state.active.phase = "planTrip" end
  end
end

function part.new(inputs)
  local api, helpers = {}, {}
  installPayouts(helpers, inputs)
  installCarHaulEscrow(api, helpers, inputs)
  installCarHaulCompletion(api, helpers, inputs)
  installActiveContract(api, inputs)
  installHubLoads(api, helpers, inputs)
  installHubStops(helpers, inputs)
  installDeliveryCredit(api, helpers, inputs)
  installReloadReconciliation(api, helpers, inputs)
  return api
end

return part
