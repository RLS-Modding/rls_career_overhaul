-- Board generation. Map: helpers, distributor vehicles, repricing, offers, hub candidates, parcel strings, passes, rebuild.
-- Read sizedBasePay, freeContractId, pickWeightedIndex, buildDistributorVehicles, estimateDistributorPay in order.

local part = {}

-- Config ------------------------------------------------------------------------------------------

-- An empty board regenerates at most once per window, so repeated screen opens do not rebuild it.
local BOARD_REGEN_COOLDOWN_S = 45

-- The owner supplies board state, catalog, balance and haul constants; each load captures its own inputs.
function part.new(inputs)

  -- Shared helpers -----------------------------------------------------------------------------------

  local function sizedBasePay(contract)
    return inputs.catalog.basePayForSizedContract(
      contract.logisticType,
      { unit = contract.sizeUnit, amount = contract.qty, trips = contract.trips, loadSlots = contract.loadSlots },
      contract.stopCount or 1
    )
  end

  -- Returns base when unused, otherwise base with the lowest numeric suffix that is free on the board.
  local function freeContractId(base)
    local id, n = base, 1
    while inputs.state.contracts[id] do
      n = n + 1
      id = base .. "_" .. n
    end
    return id
  end

  -- Weighted pick with one math.random() draw; returns 1 when every weight is zero.
  local function pickWeightedIndex(weights)
    local total = 0
    for _, w in ipairs(weights) do
      total = total + w
    end
    if total <= 0 then return 1 end
    local roll = math.random() * total
    for i, w in ipairs(weights) do
      roll = roll - w
      if roll <= 0 then return i end
    end
    return #weights
  end

  -- Distributor vehicles and quotes ------------------------------------------------------------------

  -- Count caps generated cars; the seed picks routes, and destinations follow the distributor's destinationFacilityIds allowlist.
  local function buildDistributorVehicles(count, seed, distributor, dealers)
    local vehicles = {}
    local distributorFilters = inputs.catalog.getDistributorFilters(distributor)
    local eligibleDealers = {}
    local configured = distributor.ownerOpCarHauling and distributor.ownerOpCarHauling.destinationFacilityIds
    local destinations = {}
    for _, id in ipairs(configured or {}) do
      destinations[id] = true
    end
    for _, dealer in ipairs(dealers or {}) do
      if dealer.id ~= distributor.id and (not configured or destinations[dealer.id]) then
        eligibleDealers[#eligibleDealers + 1] = dealer
      end
    end
    if not distributorFilters[1] or not eligibleDealers[1] then return vehicles end
    local tries = 0
    local i = 0
    while #vehicles < count and tries < count * 12 do
      tries = tries + 1
      local dealerIdx = ((seed + tries - 1) % #eligibleDealers) + 1
      local dealer = eligibleDealers[dealerIdx]
      local accepted = inputs.catalog.getDealerAcceptedFilters(dealer)
      local filters = inputs.catalog.intersectFilters(distributorFilters, accepted)
      if not filters[1] and not (distributor.ownerOpCarHauling and distributor.ownerOpCarHauling.vehicleFilters) then
        filters = accepted
      end
      if filters[1] then
        local filterId = filters[((seed + #vehicles + tries) % #filters) + 1]
        local rolled = inputs.catalog.rollVehicleFromFilter(filterId)
        local destPs = inputs.catalog.dealerDropPsPath(dealer)
        if rolled and destPs then
          i = i + 1
          table.insert(vehicles, {
            key = string.format("%s|%s|%d", rolled.model, rolled.config, i),
            model = rolled.model,
            config = rolled.config,
            label = rolled.label,
            thumbnail = rolled.thumbnail,
            filterId = rolled.filterId,
            filterName = rolled.filterName,
            unlockTag = rolled.unlockTag,
            destFacId = dealer.id,
            destFacName = dealer.name or dealer.id,
            destPsPath = destPs,
            status = "pending",
          })
        end
      end
    end
    return vehicles
  end

  local function estimateDistributorPay(vehicles, distributor)
    local gen = overhaul_career_logistics_generator
    local pads = inputs.catalog.distributorStagingPads(distributor)
    local originPs = pads[1] and pads[1].path or inputs.catalog.primaryPsPath(distributor)
    if not originPs then
      local basePay = inputs.balance.getCarHaulPay()
      local each = inputs.balance.applyLevelBonus(basePay, inputs.catalog.getDeliveryLevel())
      for _, veh in ipairs(vehicles or {}) do
        veh.basePay = basePay
        veh.pay = each
        veh.logisticsBonusIncluded = true
      end
      return each * #(vehicles or {})
    end
    local origin = inputs.catalog.makeLoc(distributor.id, originPs)
    local total = 0
    for _, veh in ipairs(vehicles or {}) do
      local dest = inputs.catalog.makeLoc(veh.destFacId, veh.destPsPath)
      local distance = 0
      if gen and gen.getDistanceBetweenFacilities then
        distance = tonumber((gen.getDistanceBetweenFacilities(origin, dest))) or 0
      end
      if distance <= 0 then distance = inputs.balance.referenceDistance end
      local tpl = require("overhaul/lib/logistics/templates")
      if tpl.loadVehicleFilters then tpl.loadVehicleFilters() end
      local filter = tpl.getVehicleFilterById and tpl.getVehicleFilterById(veh.filterId)
      local basePay = inputs.balance.getCarHaulPay()
      local base = inputs.balance.vehiclePayAtDistance(basePay, filter, distance, 1000) or basePay
      veh.basePay = base
      veh.pay = inputs.balance.applyLevelBonus(base, inputs.catalog.getDeliveryLevel())
      veh.logisticsBonusIncluded = true
      total = total + veh.pay
    end
    return total
  end

  -- Board repricing ----------------------------------------------------------------------------------

  -- Reprice offers in place after a skill gain. Rerolling the catalog invokes vehicle selection repeatedly and can stall a loaded career. Active quotes are held separately and never pass through here.
  local function repriceUnacceptedContracts()
    local level = inputs.catalog.getDeliveryLevel()
    for id, contract in pairs(inputs.state.contracts) do
      local invalidSelfHaul = false
      if contract.kind == inputs.carHaulKind then
        for _, veh in ipairs(contract.vehicles or {}) do
          if veh.logisticsBonusIncluded == nil and (tonumber(contract.quoteVersion) or 0) >= 2 then
            veh.logisticsBonusIncluded = true
          end
          if veh.destFacId == contract.originFacId then
            invalidSelfHaul = true
            break
          end
        end
      end
      if
        invalidSelfHaul
        or (contract.kind ~= inputs.carHaulKind and inputs.catalog.isVehicleHaulLogisticType(contract.logisticType))
      then
        inputs.state.contracts[id] = nil
      elseif contract.quoteVersion ~= inputs.quoteVersion or contract.quoteLevel ~= level then
        if contract.kind == inputs.carHaulKind then
          local canScaleOldQuote = contract.quoteVersion == 2
          for _, veh in ipairs(contract.vehicles or {}) do
            if type(veh.basePay) ~= "number" then
              canScaleOldQuote = false
              break
            end
          end
          if canScaleOldQuote then
            for _, veh in ipairs(contract.vehicles or {}) do
              veh.basePay = inputs.balance.scaleBasePay(veh.basePay)
            end
          elseif contract.quoteVersion ~= inputs.quoteVersion then
            estimateDistributorPay(contract.vehicles, inputs.catalog.facById(contract.originFacId))
          end
          local total = 0
          for _, veh in ipairs(contract.vehicles or {}) do
            local base = tonumber(veh.basePay) or tonumber(veh.pay) or inputs.balance.getCarHaulPay()
            veh.basePay = base
            veh.pay = inputs.balance.applyLevelBonus(base, level)
            veh.logisticsBonusIncluded = true
            total = total + veh.pay
          end
          contract.pay = total
        else
          if contract.quoteVersion == 2 and type(contract.basePay) == "number" then
            contract.basePay = inputs.balance.scaleBasePay(contract.basePay)
          elseif contract.quoteVersion ~= inputs.quoteVersion then
            contract.basePay = sizedBasePay(contract)
          end
          contract.pay = inputs.balance.applyLevelBonus(contract.basePay or contract.pay or 0, level)
        end
        contract.quoteLevel = level
        contract.quoteVersion = inputs.quoteVersion
      end
    end
  end

  -- Distributor offers -------------------------------------------------------------------------------

  -- Refills sources without an available haul but with a usable staging bay; multipliers clamp to 1–2, routes and counts vary.
  local function addDistributorContracts(distributors, dealers, now)
    local available = {}
    for _, contract in pairs(inputs.state.contracts) do
      if contract.kind == inputs.carHaulKind then available[contract.originFacId] = true end
    end
    for di, distributor in ipairs(distributors) do
      if dealers[1] and not available[distributor.id] and inputs.catalog.distributorStagingPads(distributor)[1] then
        local contractCount = 1 + ((now + di) % 2)
        local configured = distributor.ownerOpCarHauling and distributor.ownerOpCarHauling.contractMultiplier
        local multiplier = math.max(1, math.min(2, math.floor(tonumber(configured) or 1)))
        contractCount = contractCount * multiplier
        for ci = 1, contractCount do
          local qty = math.min(inputs.maxContractCars, 4 + ((now + ci * 3 + di) % 7))
          local vehicles = buildDistributorVehicles(qty, now + ci * 17 + di * 31, distributor, dealers)
          if vehicles[1] then
            local destinations = inputs.catalog.buildDestinationSummary(vehicles)
            local pay = estimateDistributorPay(vehicles, distributor)
            local id = string.format("carhaul_%s_%d_%d", distributor.id, ci, now)
            local destNames = {}
            for _, dest in ipairs(destinations) do
              table.insert(destNames, string.format("%s (%d)", dest.name, dest.count))
            end
            inputs.state.contracts[id] = {
              id = id,
              kind = inputs.carHaulKind,
              title = tostring(distributor.name or distributor.id),
              summary = string.format(
                "Haul %d cars to %d destinations. Stage cars per trip at the yard; rent equipment if needed.",
                #vehicles,
                #destinations
              ),
              detailSummary = table.concat(destNames, " · "),
              pay = pay,
              qty = #vehicles,
              destinationCount = #destinations,
              destinations = destinations,
              originFacId = distributor.id,
              vehicles = vehicles,
              quoteVersion = inputs.quoteVersion,
              quoteLevel = inputs.catalog.getDeliveryLevel(),
            }
          end
        end
      end
    end
  end

  -- Hub candidates and distribution ------------------------------------------------------------------

  -- Each hub offers every unlocked type it can ship to a real receiver, with that type's receivers.
  local function buildTypeCandidates(hubs, hubLookup)
    local typeCandidates = {}
    local typeIndex = {}
    for _, hub in ipairs(hubs) do
      for _, logisticType in ipairs(inputs.catalog.listFacProvidedTypes(hub)) do
        if inputs.catalog.playerCanTakeLogisticType(logisticType) then
          local receivers = inputs.catalog.findTypedReceivers(logisticType, hubLookup)
          if receivers[1] then
            local entry = typeIndex[logisticType]
            if not entry then
              entry = {
                logisticType = logisticType,
                hubs = {},
                receiversByHub = {},
              }
              typeIndex[logisticType] = entry
              table.insert(typeCandidates, entry)
            end
            table.insert(entry.hubs, hub)
            entry.receiversByHub[hub.id] = receivers
          end
        end
      end
    end
    return typeCandidates
  end

  local function addHubDistribute(logisticType, hub, dest, seed)
    local hubPs = inputs.catalog.psPathForLogisticType(hub, logisticType, true)
    if not (hubPs and dest and dest.ps) then return false end
    local size = inputs.catalog.sizeForLogisticType(logisticType)
    local id = freeContractId(string.format("hub_%s_%s_%s", hub.id, logisticType, tostring(seed)))
    inputs.state.contracts[id] = {
      id = id,
      kind = "hubDistribute",
      title = string.format("%s → %s", tostring(hub.name or hub.id), tostring(dest.fac.name or dest.fac.id)),
      summary = inputs.catalog.summarizeSizedContract(logisticType, size),
      pay = inputs.catalog.payForSizedContract(logisticType, size, 1),
      logisticType = logisticType,
      originFacId = hub.id,
      originPsPath = hubPs,
      destFacId = dest.fac.id,
      destPsPath = dest.ps,
      qty = size.amount,
      trips = size.trips,
      loadSlots = size.loadSlots,
      sizeUnit = size.unit,
    }
    return true
  end

  -- Parcel strings -----------------------------------------------------------------------------------

  -- Parcel strings: a hub run that visits several receivers in one load.
  local function parcelStopLimit(loadSlots)
    if loadSlots >= 128 then return 5 end
    if loadSlots >= 64 then return 4 end
    if loadSlots >= 32 then return 3 end
    return 2
  end

  -- Walks the receivers from a seeded start and keeps up to maxStops distinct facilities.
  local function pickParcelReceivers(receivers, seed, maxStops)
    local picked = {}
    local seen = {}
    local start = (seed % #receivers) + 1
    for i = 0, #receivers - 1 do
      if #picked >= maxStops then break end
      local dest = receivers[((start + i - 1) % #receivers) + 1]
      local facId = dest and dest.fac and dest.fac.id
      if facId and not seen[facId] and dest.ps then
        seen[facId] = true
        table.insert(picked, dest)
      end
    end
    return picked
  end

  -- Nearest-neighbour route from the hub through the picked receivers; ties keep the first index.
  local function orderParcelStops(picked, hub, hubPs)
    local remaining = {}
    for _, dest in ipairs(picked) do
      table.insert(remaining, dest)
    end
    local ordered = {}
    local cursor = inputs.catalog.makeLoc(hub.id, hubPs)
    local gen = overhaul_career_logistics_generator
    while remaining[1] do
      local bestI, bestD = 1, math.huge
      for i, dest in ipairs(remaining) do
        local d = math.huge
        if gen and gen.getDistanceBetweenFacilities then
          d = tonumber((gen.getDistanceBetweenFacilities(cursor, inputs.catalog.makeLoc(dest.fac.id, dest.ps)))) or math.huge
        end
        if d < bestD then
          bestI, bestD = i, d
        end
      end
      local pick = table.remove(remaining, bestI)
      table.insert(ordered, pick)
      cursor = inputs.catalog.makeLoc(pick.fac.id, pick.ps)
    end
    return ordered
  end

  -- Splits the load's slots across the stops, giving the first remainder slots one extra each.
  local function buildParcelStops(ordered, loadSlots)
    local stopCount = #ordered
    local baseSlots = math.floor(loadSlots / stopCount)
    local remSlots = loadSlots - (baseSlots * stopCount)
    local stops = {}
    for i, dest in ipairs(ordered) do
      table.insert(stops, {
        destFacId = dest.fac.id,
        destPsPath = dest.ps,
        destName = tostring(dest.fac.name or dest.fac.id),
        slots = math.max(1, baseSlots + (i <= remSlots and 1 or 0)),
      })
    end
    return stops
  end

  local function addHubParcelString(logisticType, hub, receivers, seed)
    if inputs.catalog.logisticTypeHeatLeaf(logisticType) ~= "delivery_parcel" then return false end
    if not (hub and receivers and receivers[1]) then return false end
    local hubPs = inputs.catalog.psPathForLogisticType(hub, logisticType, true)
    if not hubPs then return false end
    local loadSlots = inputs.catalog.playerMaxParcelSlots()
    local maxStops = math.min(parcelStopLimit(loadSlots), #receivers)
    local picked = pickParcelReceivers(receivers, seed, maxStops)
    if not picked[1] then return false end

    local ordered = orderParcelStops(picked, hub, hubPs)
    local stopCount = #ordered
    local stops = buildParcelStops(ordered, loadSlots)
    local size = { unit = "slots", loadSlots = loadSlots, trips = 1, amount = loadSlots }
    local id = freeContractId(string.format("hub_str_%s_%s_%s", hub.id, logisticType, tostring(seed)))
    local first = stops[1]
    inputs.state.contracts[id] = {
      id = id,
      kind = "hubDistribute",
      stringMode = true,
      title = string.format("Parcel string: %d stops · %s", stopCount, tostring(hub.name or hub.id)),
      summary = string.format(
        "Owner-operator parcel string · %d stops · %d slots. Pay on full completion.",
        stopCount,
        loadSlots
      ),
      pay = inputs.catalog.payForSizedContract(logisticType, size, stopCount),
      logisticType = logisticType,
      originFacId = hub.id,
      originPsPath = hubPs,
      destFacId = first.destFacId,
      destPsPath = first.destPsPath,
      qty = loadSlots,
      trips = 1,
      loadSlots = loadSlots,
      sizeUnit = "slots",
      stopCount = stopCount,
      stops = stops,
    }
    return true
  end

  -- Floor, surge and hub-pair offers -----------------------------------------------------------------

  -- One offer for a candidate from one hub. Parcel types build a string, other types a single leg to the receiver at destSeed; both use the same seed for their id.
  local function offerCandidateRun(candidate, hub, destSeed, seed, hubLookup)
    local receivers = candidate.receiversByHub[hub.id] or inputs.catalog.findTypedReceivers(candidate.logisticType, hubLookup)
    if not receivers[1] then return end
    if inputs.catalog.logisticTypeHeatLeaf(candidate.logisticType) == "delivery_parcel" then
      addHubParcelString(candidate.logisticType, hub, receivers, seed)
    else
      addHubDistribute(candidate.logisticType, hub, receivers[(destSeed % #receivers) + 1], seed)
    end
  end

  -- Floor: one contract for every available logistic type.
  local function addFloorContracts(typeCandidates, hubLookup, now)
    for ti, candidate in ipairs(typeCandidates) do
      local hub = candidate.hubs[((now + ti - 1) % #candidate.hubs) + 1]
      offerCandidateRun(candidate, hub, now + ti * 3, now + ti, hubLookup)
    end
  end

  -- Extra contracts, weighted by surge. Parcel and high-slot types get more volume.
  local function addSurgeContracts(typeCandidates, hubLookup, now)
    if not typeCandidates[1] then return end
    local extraSlots = math.min(8, math.max(2, #typeCandidates + 1))
    local weights = {}
    for _, candidate in ipairs(typeCandidates) do
      local leaf = inputs.catalog.logisticTypeHeatLeaf(candidate.logisticType)
      local w = inputs.catalog.surgeFactorForLeaf(leaf)
      if leaf == "delivery_parcel" and inputs.catalog.playerMaxParcelSlots() >= 64 then
        w = w * 1.75
      elseif leaf == "delivery_trailer" then
        w = w * 1.35
      end
      table.insert(weights, w)
    end
    for ei = 1, extraSlots do
      local candidate = typeCandidates[pickWeightedIndex(weights)]
      local hub = candidate.hubs[((now + ei * 7) % #candidate.hubs) + 1]
      offerCandidateRun(candidate, hub, now + ei * 11, now + 1000 + ei, hubLookup)
    end
  end

  -- One A-to-B contract, drawn from the unlocked provider-receiver pairs and dispatched through a hub.
  local function addHubPairContract(hubs, hubLookup, now)
    if not hubs[1] then return end
    local dispatchHub = hubs[((now - 1) % #hubs) + 1]
    local unlockedPairs, pairWeights = {}, {}
    for _, pair in ipairs(inputs.catalog.findTypedProviderReceiverPairs(hubLookup)) do
      if inputs.catalog.playerCanTakeLogisticType(pair.logisticType) then
        table.insert(unlockedPairs, pair)
        table.insert(pairWeights, inputs.catalog.surgeFactorForLeaf(inputs.catalog.logisticTypeHeatLeaf(pair.logisticType)))
      end
    end
    if not unlockedPairs[1] then return end
    local pair = unlockedPairs[pickWeightedIndex(pairWeights)]
    local size = inputs.catalog.sizeForLogisticType(pair.logisticType)
    local id = string.format("hub_ab_%s_%s_%d", dispatchHub.id, pair.logisticType, now)
    inputs.state.contracts[id] = {
      id = id,
      kind = "hubAB",
      title = string.format(
        "A→B: %s → %s",
        tostring(pair.origin.name or pair.origin.id),
        tostring(pair.dest.name or pair.dest.id)
      ),
      summary = string.format(
        "%s via %s",
        inputs.catalog.summarizeSizedContract(pair.logisticType, size),
        tostring(dispatchHub.name or dispatchHub.id)
      ),
      pay = inputs.catalog.payForSizedContract(pair.logisticType, size, 1),
      logisticType = pair.logisticType,
      originFacId = pair.origin.id,
      originPsPath = pair.originPs,
      destFacId = pair.dest.id,
      destPsPath = pair.destPs,
      dispatchFacId = dispatchHub.id,
      qty = size.amount,
      trips = size.trips,
      loadSlots = size.loadSlots,
      sizeUnit = size.unit,
    }
  end

  -- Board rebuild and top-up -------------------------------------------------------------------------

  local function clearBoard()
    for k in pairs(inputs.state.contracts) do
      inputs.state.contracts[k] = nil
    end
  end

  -- Hubs, car-haul sources and dealers, plus the set of facilities any contract may name.
  local function collectBoardSources()
    local hubs = inputs.catalog.listOwnerOpHubs()
    local distributors = inputs.catalog.listVehicleDistributors()
    local dealers = inputs.catalog.listNewVehicleDealers()
    local hubLookup = {}
    for _, hub in ipairs(hubs) do
      hubLookup[hub.id] = true
    end
    for _, dist in ipairs(distributors) do
      hubLookup[dist.id] = true
    end
    return { hubs = hubs, distributors = distributors, dealers = dealers, hubLookup = hubLookup }
  end

  -- Every quote on the board gets the current version and level, and the basePay of its sized haul.
  local function finalizeQuotes()
    local level = inputs.catalog.getDeliveryLevel()
    for _, contract in pairs(inputs.state.contracts) do
      contract.quoteVersion = inputs.quoteVersion
      contract.quoteLevel = level
      if contract.kind ~= inputs.carHaulKind then contract.basePay = sizedBasePay(contract) end
    end
  end

  local function generateBoard(now)
    clearBoard()
    local sources = collectBoardSources()
    local typeCandidates = buildTypeCandidates(sources.hubs, sources.hubLookup)
    addFloorContracts(typeCandidates, sources.hubLookup, now)
    addSurgeContracts(typeCandidates, sources.hubLookup, now)
    addHubPairContract(sources.hubs, sources.hubLookup, now)
    addDistributorContracts(sources.distributors, sources.dealers, now)
    finalizeQuotes()
  end

  -- A hub contract saved before its type was recorded cannot be kept; the board must be rebuilt.
  local function boardNeedsRegen()
    for _, contract in pairs(inputs.state.contracts) do
      if (contract.kind == "hubDistribute" or contract.kind == "hubAB") and not contract.logisticType then
        return true
      end
    end
    return false
  end

  -- Keeps the typed board and refreshes only car hauls. Returns false when a full rebuild is needed.
  local function topUpExistingBoard(now)
    if boardNeedsRegen() then return false end
    repriceUnacceptedContracts()
    if not next(inputs.state.contracts) then return false end
    addDistributorContracts(inputs.catalog.listVehicleDistributors(), inputs.catalog.listNewVehicleDealers(), now)
    return true
  end

  local function rebuildContracts(force)
    local now = os.time()
    if not force then
      if inputs.state.active then return end
      if next(inputs.state.contracts) then
        if topUpExistingBoard(now) then return end
      elseif (now - inputs.state.lastGenAt) < BOARD_REGEN_COOLDOWN_S then
        return
      end
    end
    inputs.state.lastGenAt = now
    generateBoard(now)
  end

  return {
    rebuildContracts = rebuildContracts,
  }
end

return part
