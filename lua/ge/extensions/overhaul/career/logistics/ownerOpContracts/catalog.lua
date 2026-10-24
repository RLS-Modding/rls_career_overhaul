-- Owner-operator catalog. Map: unlocks and bays, logistics types and sizing, pay, facility lists, vehicle rolls, serialization.
-- Read getDeliveryLevel, ownerOpUnlocked, facById, allFacilities, isOwnerOpHubFacility in order.

local part = {}
local cargoSemantics = require("overhaul/lib/logistics/cargoSemantics")
local xpConfig = require("overhaul/lib/logistics/xpConfig")

-- Unlocks and access points ----------------------------------------------------------------------

local function installFacilityAccess(api, helpers, inputs)
  function api.getDeliveryLevel()
    if overhaul_career_work_employment then return overhaul_career_work_employment.getDeliveryLevel() or 0 end
    return 0
  end

  function api.ownerOpUnlocked()
    local emp = overhaul_career_work_employment
    if not emp then return true end
    if not emp.isApprenticeshipEnabled() then return true end
    if overhaul_career_progression_unlockFlags.getFlag("logisticsOwnerOp") then return true end
    return api.getDeliveryLevel() >= 30
  end

  function api.facById(id)
    local gen = overhaul_career_logistics_generator
    return gen and gen.getFacilityById(id)
  end

  function helpers.allFacilities()
    local gen = overhaul_career_logistics_generator
    return (gen and gen.getFacilities()) or {}
  end

  function api.isOwnerOpHubFacility(fac)
    local emp = overhaul_career_work_employment
    return emp and emp.isOwnerOpYardFacility(fac) or false
  end

  --- Recognize configured owner-op sources without changing their employment role.
  -- @param fac Facility record, or nil. @return Whether the facility can originate car-haul contracts.
  function api.isVehicleDistributorFacility(fac)
    if fac and type(fac.ownerOpCarHauling) == "table" then return true end
    local emp = overhaul_career_work_employment
    if emp then return emp.isVehicleDistributorFacility(fac) end
    return fac and (fac.vehicleDistributor == true or fac.carHaulFacility == true) or false
  end

  function api.primaryPsPath(fac, preferName)
    if not fac then return nil end
    if preferName and fac.accessPointsByName and fac.accessPointsByName[preferName] then
      local ap = fac.accessPointsByName[preferName]
      local ps = ap.ps or ap
      if ps and ps.getPath then return ps:getPath() end
    end
    if fac.inspectSpots and fac.inspectSpots[1] and fac.inspectSpots[1].getPath then
      return fac.inspectSpots[1]:getPath()
    end
    for _, ap in pairs(fac.accessPointsByName or {}) do
      local ps = ap.ps or ap
      if ps and ps.getPath then return ps:getPath() end
    end
    return nil
  end

  function api.dealerDropPsPath(dealer)
    if not dealer then return nil end
    local trailerKey = string.format("%s_trailer", dealer.id)
    if dealer.accessPointsByName and dealer.accessPointsByName[trailerKey] then
      local ap = dealer.accessPointsByName[trailerKey]
      local ps = ap.ps or ap
      if ps and ps.getPath then return ps:getPath() end
    end
    return api.primaryPsPath(dealer)
  end

  function helpers.apProvidesType(ap, logisticType)
    if not ap or not logisticType then return false end
    local lookup = ap.logisticTypesProvidedLookup
    if type(lookup) == "table" and lookup[logisticType] then return true end
    for _, t in ipairs(ap.logisticTypesProvided or {}) do
      if t == logisticType then return true end
    end
    return false
  end

  function helpers.facReceivesType(fac, logisticType)
    if not fac or not logisticType then return false end
    local lookup = fac.logisticTypesReceivedLookup
    if type(lookup) == "table" and lookup[logisticType] then return true end
    for _, t in ipairs(fac.logisticTypesReceived or {}) do
      if t == logisticType then return true end
    end
    for _, ap in pairs(fac.accessPointsByName or {}) do
      local recv = ap.logisticTypesReceivedLookup
      if type(recv) == "table" and recv[logisticType] then return true end
      for _, t in ipairs(ap.logisticTypesReceived or {}) do
        if t == logisticType then return true end
      end
    end
    return false
  end

  --- Resolve distinct pickup bays, excluding loaner bays.
  -- An explicit stagingParkingSpotNames list is authoritative; unconfigured yards use legacy fallbacks. @param fac Source facility, or nil. @return Ordered bay records with name, path and optional parking-spot object.
  function api.distributorStagingPads(fac)
    local pads = {}
    if not fac then return pads end
    local configured = fac.ownerOpCarHauling and fac.ownerOpCarHauling.stagingParkingSpotNames
    if configured then
      local seen = {}
      for _, name in ipairs(configured) do
        local ap = fac.accessPointsByName and fac.accessPointsByName[name]
        local ps = ap and (ap.ps or ap)
        local path = ps and ps.getPath and ps:getPath()
        if path and not seen[path] and not ap.loanerNonTrailerPriority and not ap.loanerTrailerPriority then
          seen[path] = true
          table.insert(pads, { name = name, path = path, ps = ps })
        end
      end
      return pads
    end
    for name, ap in pairs(fac.accessPointsByName or {}) do
      if ap.isInspectSpot then goto continue end
      if ap.loanerNonTrailerPriority or ap.loanerTrailerPriority then goto continue end
      if helpers.apProvidesType(ap, inputs.distributorLogisticType) then
        local ps = ap.ps or ap
        if ps and ps.getPath then table.insert(pads, { name = name, path = ps:getPath() }) end
      end
      ::continue::
    end
    table.sort(pads, function(a, b) return tostring(a.name) < tostring(b.name) end)
    if not pads[1] then
      for name, ap in pairs(fac.accessPointsByName or {}) do
        if ap.isInspectSpot then goto continueFallback end
        if ap.loanerNonTrailerPriority or ap.loanerTrailerPriority then goto continueFallback end
        local ps = ap.ps or ap
        if ps and ps.getPath then table.insert(pads, { name = name, path = ps:getPath() }) end
        ::continueFallback::
      end
      table.sort(pads, function(a, b) return tostring(a.name) < tostring(b.name) end)
    end
    if not pads[1] then
      local fallback = api.primaryPsPath(fac)
      if fallback then table.insert(pads, { name = "primary", path = fallback }) end
    end
    return pads
  end
end

-- Logistic types and sizing ----------------------------------------------------------------------

local function installSizingRules(api, helpers)
  function api.materialTemplate(logisticType)
    local gen = overhaul_career_logistics_generator
    return gen and gen.getMaterialsTemplatesById and gen.getMaterialsTemplatesById(logisticType)
  end

  -- Cargo types that have their own owner-op pipeline (not hub distribute/A-B).
  local HUB_CONTRACT_SKIP_TYPES = {
    vehDeliveryNew = true,
  }

  function api.isVehicleHaulLogisticType(logisticType)
    if not logisticType then return false end
    if HUB_CONTRACT_SKIP_TYPES[logisticType] then return true end
    return type(logisticType) == "string" and logisticType:sub(1, 3) == "veh"
  end

  function helpers.hasUnlockFlag(flag)
    return overhaul_career_progression_unlockFlags and overhaul_career_progression_unlockFlags.getFlag(flag) and true
      or false
  end

  -- Biggest relevant vehicle for sizing = player's unlocked parcel slot cap.
  function api.playerMaxParcelSlots()
    if helpers.hasUnlockFlag("logisticsParcel128Slots") then return 128 end
    if helpers.hasUnlockFlag("logisticsParcel64Slots") then return 64 end
    if helpers.hasUnlockFlag("logisticsParcel32Slots") or helpers.hasUnlockFlag("largePackagesDelivery") then return 32 end
    return 16
  end

  function api.logisticTypeHeatLeaf(logisticType)
    local t = tostring(logisticType or "")
    local lower = t:lower()
    local material = api.materialTemplate(logisticType)
    if material and material.type then return cargoSemantics.material(material.type).economyKey end
    if lower:find("trailer", 1, true) then return "delivery_trailer" end
    if
      lower:find("cash", 1, true)
      or lower:find("money", 1, true)
      or lower:find("gold", 1, true)
      or lower:find("coin", 1, true)
    then
      return "delivery_cash"
    end
    if t:find("cement", 1, true) then return "delivery_cement" end
    if
      t:find("dryBulk", 1, true)
      or t:find("aggregate", 1, true)
      or t:find("lime", 1, true)
      or t:find("ash", 1, true)
    then
      return "delivery_dryBulk"
    end
    if t:find("fluid", 1, true) or t:find("Fluid", 1, true) then return "delivery_fluid" end
    if t:sub(1, 3) == "veh" then return "delivery_vehicle" end
    return "delivery_parcel"
  end

  function api.surgeFactorForLeaf(leafId)
    if overhaul_career_economy_activityHeat then
      return math.max(0.05, tonumber(overhaul_career_economy_activityHeat.getDemandFactor(leafId)) or 1)
    end
    return 1
  end

  function api.playerCanTakeLogisticType(logisticType)
    if api.isVehicleHaulLogisticType(logisticType) then return false end
    local leaf = api.logisticTypeHeatLeaf(logisticType)
    if leaf == "delivery_trailer" then
      return helpers.hasUnlockFlag("smallTrailersDelivery")
        or helpers.hasUnlockFlag("logisticsTrailerMedium")
        or helpers.hasUnlockFlag("logisticsTrailerFlatbed")
        or helpers.hasUnlockFlag("logisticsTrailerFramelessDump")
        or helpers.hasUnlockFlag("largeTrailersDelivery")
        or helpers.hasUnlockFlag("logisticsTrailerDryvan")
        or helpers.hasUnlockFlag("logisticsTrailerDolly")
        or helpers.hasUnlockFlag("logisticsTrailerTanker")
        or helpers.hasUnlockFlag("logisticsTrailerContainer")
        or helpers.hasUnlockFlag("logisticsTrailerLog")
    end
    if leaf == "delivery_fluid" then
      return helpers.hasUnlockFlag("logisticsFluidDelivery") or helpers.hasUnlockFlag("hazardousMaterialsDelivery")
    end
    if leaf == "delivery_dryBulk" then return helpers.hasUnlockFlag("logisticsAggregateDelivery") end
    if leaf == "delivery_cement" then return helpers.hasUnlockFlag("logisticsCementDelivery") end
    if leaf == "delivery_cash" then return helpers.hasUnlockFlag("logisticsCashDelivery") end
    return helpers.hasUnlockFlag("smallPackagesDelivery")
  end

  function api.sizeForLogisticType(logisticType)
    local leaf = api.logisticTypeHeatLeaf(logisticType)
    local surge = api.surgeFactorForLeaf(leaf)
    local material = api.materialTemplate(logisticType)
    if material then
      local cfg = xpConfig.getMaterialContractRules()
      local load = cfg.standardLoadByMaterial[logisticType] or cfg.standardLoadByType[material.type] or 1
      local secure = material.type == "cash"
      local range = secure and cfg.secureLoadCount or cfg.bulkLoadCount
      local amount, trips = require("overhaul/lib/logistics/materialContractAmounts").choose({
        standardLoad = load, minLoads = range.min, maxLoads = range.max,
        loadWeights = not secure and cfg.bulkLoadWeights or nil,
      })
      return {unit = material.units or "L", loadSlots = load, trips = trips, amount = amount}
    end
    if leaf == "delivery_parcel" then
      local loadSlots = api.playerMaxParcelSlots()
      local trips = 2
      if loadSlots >= 128 then
        trips = 6 + math.floor(surge * 4)
      elseif loadSlots >= 64 then
        trips = 4 + math.floor(surge * 2)
      else
        trips = 2 + (surge > 1.2 and 1 or 0) + (surge > 1.5 and 1 or 0)
      end
      trips = math.max(2, trips)
      return {
        unit = "slots",
        loadSlots = loadSlots,
        trips = trips,
        amount = loadSlots * trips,
      }
    end
    local trips = 2 + (surge > 1.15 and 1 or 0) + (surge > 1.4 and 1 or 0)
    trips = math.max(2, trips)
    return {
      unit = "trips",
      loadSlots = 1,
      trips = trips,
      amount = trips,
    }
  end
end

-- Pay -------------------------------------------------------------------------------------------

local function installContractPricing(api, inputs)
  function api.basePayForSizedContract(logisticType, size, extraStops)
    local leaf = api.logisticTypeHeatLeaf(logisticType)
    local trips = math.max(1, tonumber(size and size.trips) or 1)
    local base = nil
    if size and size.unit == "slots" then
      local slots = math.max(1, tonumber(size.amount) or tonumber(size.loadSlots) or 16)
      local boxSlots = math.min(128, math.max(16, tonumber(size.loadSlots) or 16))
      base = math.ceil(slots / boxSlots) * inputs.balance.getParcelPay(boxSlots)
    else
      local perTrip = ({
        delivery_trailer = 750,
        delivery_cash = 5000,
        delivery_cement = 6500,
        delivery_dryBulk = 7500,
        delivery_fluid = 7500,
      })[leaf] or 750
      base = inputs.balance.scaleBasePay(perTrip) * trips
    end
    base = base * (1 + 0.2 * math.max(0, (tonumber(extraStops) or 1) - 1))
    return base
  end

  function api.payForSizedContract(logisticType, size, extraStops)
    return inputs.balance.applyLevelBonus(api.basePayForSizedContract(logisticType, size, extraStops), api.getDeliveryLevel())
  end

  function api.summarizeSizedContract(logisticType, size)
    if api.materialTemplate(logisticType) and size then
      return string.format("Owner-operator %s run · %d %s (~%d loads of %d).", tostring(logisticType),
        size.amount, size.unit, size.trips, size.loadSlots)
    end
    if size and size.unit == "slots" then
      return string.format(
        "Owner-operator %s run · %d slots (~%d loads of %d).",
        tostring(logisticType),
        size.amount or 0,
        size.trips or 0,
        size.loadSlots or 0
      )
    end
    return string.format("Owner-operator %s run · %d trips minimum.", tostring(logisticType), size and size.trips or 2)
  end
end

-- Depot and provider queries ----------------------------------------------------------------------

local function installDepotQueries(api, helpers, inputs)
  function helpers.apReceivesType(ap, logisticType)
    if not ap or not logisticType then return false end
    local lookup = ap.logisticTypesReceivedLookup
    if type(lookup) == "table" and lookup[logisticType] then return true end
    for _, t in ipairs(ap.logisticTypesReceived or {}) do
      if t == logisticType then return true end
    end
    return false
  end

  function api.listFacProvidedTypes(fac)
    local types, seen = {}, {}
    local parcelTemplates = inputs.getParcelTemplates and inputs.getParcelTemplates()
    local generatedParcels = {}
    for _, template in ipairs(parcelTemplates or {}) do
      if (template.generationChance or 1) > 0 then generatedParcels[template.logisticType] = true end
    end
    local function add(t)
      if not t or seen[t] or api.isVehicleHaulLogisticType(t) then return end
      -- Business reservations advertise service endpoints but never create public freight.
      if parcelTemplates and api.logisticTypeHeatLeaf(t) == "delivery_parcel" and not generatedParcels[t] then return end
      seen[t] = true
      table.insert(types, t)
    end
    local lookup = fac and fac.logisticTypesProvidedLookup
    if type(lookup) == "table" then
      for t, on in pairs(lookup) do
        if on then add(t) end
      end
    end
    for _, t in ipairs(fac and fac.logisticTypesProvided or {}) do
      add(t)
    end
    for _, ap in pairs(fac and fac.accessPointsByName or {}) do
      for _, t in ipairs(ap.logisticTypesProvided or {}) do
        add(t)
      end
      local apLookup = ap.logisticTypesProvidedLookup
      if type(apLookup) == "table" then
        for t, on in pairs(apLookup) do
          if on then add(t) end
        end
      end
    end
    table.sort(types)
    return types
  end

  function api.psPathForLogisticType(fac, logisticType, asProvider)
    if not fac or not logisticType then return api.primaryPsPath(fac) end
    local preferred, fallback = nil, nil
    for _, ap in pairs(fac.accessPointsByName or {}) do
      local match = asProvider and helpers.apProvidesType(ap, logisticType) or helpers.apReceivesType(ap, logisticType)
      if match then
        local ps = ap.ps or ap
        if ps and ps.getPath then
          local path = ps:getPath()
          local isLoaner = ap.loanerNonTrailerPriority or ap.loanerTrailerPriority
          if not ap.isInspectSpot and not isLoaner then
            preferred = preferred or path
          else
            fallback = fallback or path
          end
        end
      end
    end
    return preferred or fallback or api.primaryPsPath(fac)
  end

  function api.findTypedReceivers(logisticType, excludeIds)
    local receivers = {}
    if not logisticType then return receivers end
    excludeIds = excludeIds or {}
    for _, fac in ipairs(helpers.allFacilities()) do
      if fac and fac.id and not excludeIds[fac.id] and helpers.facReceivesType(fac, logisticType) then
        local ps = api.psPathForLogisticType(fac, logisticType, false)
        if ps then table.insert(receivers, { fac = fac, ps = ps, logisticType = logisticType }) end
      end
    end
    table.sort(receivers, function(a, b) return tostring(a.fac.id) < tostring(b.fac.id) end)
    return receivers
  end

  -- Appends one pair per (provided type, receiving facility) of an origin that has both bays.
  function helpers.appendOriginPairs(pairsList, origin, facilities, excludeIds)
    local provided = api.listFacProvidedTypes(origin)
    if not provided[1] then return end
    for _, dest in ipairs(facilities) do
      if dest and dest.id and dest.id ~= origin.id and not excludeIds[dest.id] then
        for _, logisticType in ipairs(provided) do
          if helpers.facReceivesType(dest, logisticType) then
            local originPs = api.psPathForLogisticType(origin, logisticType, true)
            local destPs = api.psPathForLogisticType(dest, logisticType, false)
            if originPs and destPs then
              table.insert(pairsList, {
                origin = origin,
                dest = dest,
                originPs = originPs,
                destPs = destPs,
                logisticType = logisticType,
              })
            end
          end
        end
      end
    end
  end

  function api.findTypedProviderReceiverPairs(excludeIds)
    local pairsList = {}
    excludeIds = excludeIds or {}
    local facilities = helpers.allFacilities()
    for _, origin in ipairs(facilities) do
      if origin and origin.id and not excludeIds[origin.id] then
        helpers.appendOriginPairs(pairsList, origin, facilities, excludeIds)
      end
    end
    return pairsList
  end

end

-- Vehicle filters and facility listings ------------------------------------------------------------

local function installVehicleListings(api, helpers, inputs)
  --- Read ownerOpCarHauling.vehicleFilters or infer filters from independent generators.
  -- @param fac Source facility. @return Vehicle filter IDs; company-only sources return an empty list.
  function api.getDistributorFilters(fac)
    local configured = fac and fac.ownerOpCarHauling and fac.ownerOpCarHauling.vehicleFilters
    if configured then return configured end
    local filters, seen = {}, {}
    local companyOnly = false
    local hasIndependentGenerator = false
    for _, generator in ipairs(fac and fac.logisticGenerators or {}) do
      if generator.type == "vehOfferProvider" then
        if generator.offerMode == "employment" then
          companyOnly = true
        else
          hasIndependentGenerator = true
        end
      end
      if generator.type == "vehOfferProvider" and generator.filter and generator.offerMode ~= "employment" then
        local isDistributor = false
        for _, t in ipairs(generator.logisticTypes or {}) do
          if t == inputs.distributorLogisticType then
            isDistributor = true
            break
          end
        end
        if isDistributor then
          for _, filterId in ipairs(type(generator.filter) == "table" and generator.filter or { generator.filter }) do
            if not seen[filterId] then
              seen[filterId] = true
              table.insert(filters, filterId)
            end
          end
        end
      end
    end
    if not filters[1] and api.isVehicleDistributorFacility(fac) and (not companyOnly or hasIndependentGenerator) then
      table.insert(filters, inputs.distributorFilterId)
    end
    return filters
  end

  function api.getDealerAcceptedFilters(dealer)
    local filters, seen = {}, {}
    for _, filterId in ipairs(dealer and dealer.acceptedVehicleFilters or {}) do
      if filterId and not seen[filterId] then
        seen[filterId] = true
        table.insert(filters, filterId)
      end
    end
    if filters[1] then return filters end
    for _, generator in ipairs(dealer and dealer.logisticGenerators or {}) do
      if generator.type == "vehOfferProvider" and generator.filter then
        for _, t in ipairs(generator.logisticTypes or {}) do
          if t == inputs.distributorLogisticType then
            for _, filterId in ipairs(type(generator.filter) == "table" and generator.filter or { generator.filter }) do
              if not seen[filterId] then
                seen[filterId] = true
                table.insert(filters, filterId)
              end
            end
          end
        end
      end
    end
    if not filters[1] and helpers.facReceivesType(dealer, inputs.distributorLogisticType) then
      table.insert(filters, inputs.distributorFilterId)
    end
    return filters
  end

  --- List parcel hubs while retaining hubs that also opt into configured car hauling.
  -- @return Eligible hub facilities sorted by ID.
  function api.listOwnerOpHubs()
    local hubs = {}
    for _, fac in ipairs(helpers.allFacilities()) do
      local configuredMixedYard = fac.ownerOpCarHauling and not (fac.vehicleDistributor or fac.carHaulFacility)
      if api.isOwnerOpHubFacility(fac) and (configuredMixedYard or not api.isVehicleDistributorFacility(fac)) then
        table.insert(hubs, fac)
      end
    end
    table.sort(hubs, function(a, b) return tostring(a.id) < tostring(b.id) end)
    return hubs
  end

  function api.listVehicleDistributors()
    local list = {}
    for _, fac in ipairs(helpers.allFacilities()) do
      if api.isVehicleDistributorFacility(fac) then table.insert(list, fac) end
    end
    table.sort(list, function(a, b) return tostring(a.id) < tostring(b.id) end)
    return list
  end

  function api.listNewVehicleDealers()
    local dealers = {}
    for _, fac in ipairs(helpers.allFacilities()) do
      if
        helpers.facReceivesType(fac, inputs.distributorLogisticType)
        or (fac.acceptedVehicleFilters and fac.acceptedVehicleFilters[1])
      then
        local filters = api.getDealerAcceptedFilters(fac)
        if filters[1] and api.dealerDropPsPath(fac) then table.insert(dealers, fac) end
      end
    end
    table.sort(dealers, function(a, b) return tostring(a.id) < tostring(b.id) end)
    return dealers
  end
end

-- Vehicles, money and records --------------------------------------------------------------------

local function installVehicleRecords(api)
  function api.rollVehicleFromFilter(filterId)
    local gen = overhaul_career_logistics_generator
    if not gen then return nil end
    local stub = {
      vehicle = { filterId = filterId },
      locations = {},
      data = { type = "vehicle" },
    }
    gen.finalizeVehicleOffer(stub)
    local veh = stub.vehicle
    if not veh or not veh.model or not veh.config then return nil end
    local modelData = core_vehicles.getModel(veh.model)
    local cfg = modelData and modelData.configs and modelData.configs[veh.config]
    local tpl = require("overhaul/lib/logistics/templates")
    tpl.loadVehicleFilters()
    local filter = tpl.getVehicleFilterById(filterId)
    return {
      model = veh.model,
      config = veh.config,
      label = veh.name or (cfg and cfg.Name) or veh.model,
      thumbnail = (cfg and cfg.preview) or "/ui/images/appDefault.png",
      filterId = filterId,
      filterName = (filter and filter.filterName) or filterId,
      unlockTag = filter and filter.unlockTag or nil,
    }
  end

  function api.makeLoc(facId, psPath) return { type = "facilityParkingspot", facId = facId, psPath = psPath } end

  function api.payMoney(amount, label)
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 then return true end
    local payment = overhaul_career_economy_payment
    if not payment then return false, "Payment is unavailable" end
    return payment.payout(require("overhaul/lib/finance/metadata").tagPayout({
      amount = amount,
      tags = { "gameplay", "deliveryReward", "ownerOp" },
      label = label or "Contract pay",
    }, "activity:delivery"))
  end

  function api.countVehiclesByStatus(vehicles, status)
    local n = 0
    for _, veh in ipairs(vehicles or {}) do
      if veh.status == status then n = n + 1 end
    end
    return n
  end

  function api.buildDestinationSummary(vehicles)
    local byDealer = {}
    for _, veh in ipairs(vehicles or {}) do
      local id = veh.destFacId
      if id then
        if not byDealer[id] then
          byDealer[id] = {
            facId = id,
            name = veh.destFacName or id,
            count = 0,
          }
        end
        byDealer[id].count = byDealer[id].count + 1
      end
    end
    local list = {}
    for _, entry in pairs(byDealer) do
      table.insert(list, entry)
    end
    table.sort(list, function(a, b) return tostring(a.name) < tostring(b.name) end)
    return list
  end

  function api.serializeVehicle(veh)
    return {
      key = veh.key,
      model = veh.model,
      config = veh.config,
      label = veh.label,
      thumbnail = veh.thumbnail,
      filterId = veh.filterId,
      filterName = veh.filterName,
      destFacId = veh.destFacId,
      destFacName = veh.destFacName,
      destPsPath = veh.destPsPath,
      status = veh.status or "pending",
      offerId = veh.offerId,
      pay = veh.pay,
      basePay = veh.basePay,
      logisticsBonusIncluded = veh.logisticsBonusIncluded == true,
    }
  end

  function api.intersectFilters(a, b)
    local lookup, out = {}, {}
    for _, id in ipairs(b or {}) do
      lookup[id] = true
    end
    for _, id in ipairs(a or {}) do
      if lookup[id] then table.insert(out, id) end
    end
    return out
  end

end

function part.new(inputs)
  local api, helpers = {}, {}
  installFacilityAccess(api, helpers, inputs)
  installSizingRules(api, helpers)
  installContractPricing(api, inputs)
  installDepotQueries(api, helpers, inputs)
  installVehicleListings(api, helpers, inputs)
  installVehicleRecords(api)
  return api
end

return part
