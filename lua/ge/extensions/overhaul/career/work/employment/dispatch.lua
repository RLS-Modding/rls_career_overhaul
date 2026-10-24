-- Selects employment assignments and return loads from the caller's services and policy, with dispatch diagnostics.
-- Reading order: policy, diagnostics, outbound and return selectors, job options, surge weighting and bound API.
local M = {}

-- Config ------------------------------------------------------------------------------------------

local PARCEL_CARGO = { parcel = true }
local DEV_KIND_ORDER = { "parcel", "trailer", "materials", "vehicle", "repo" }
local DEV_KIND_LABELS = {
  parcel = "Parcel",
  trailer = "Trailer",
  materials = "Materials",
  vehicle = "Vehicle assignment",
  repo = "Car hauling",
  vehicle_repo_bundle = "Car hauling",
  police = "Police patrol",
  bus = "Bus route",
  paramedic = "Paramedic",
}

-- Shared helpers ----------------------------------------------------------------------------------

-- Each call reads the owning employment instance's kind catalog.
local function kindPolicyOf(employment, kind)
  return employment.shared.kindPolicy(kind)
end

-- Diagnostics ---------------------------------------------------------------------------------------

function M.summarizeKindMap(_ctx, kinds)
  if not kinds then return "none" end
  local names = {}
  for kind in pairs(kinds) do
    table.insert(names, tostring(kind))
  end
  table.sort(names)
  return #names > 0 and table.concat(names, ", ") or "none"
end

function M.describeLoanerOffer(_ctx, offer)
  if not offer then return "nil" end
  local model = offer.model or offer.vehId or "?"
  local config = offer.config or offer.configKey or "?"
  local reputationLevel = offer.reputationLvl
  if reputationLevel ~= nil then
    return string.format("%s/%s (rep<=%s)", model, config, tostring(reputationLevel))
  end
  return string.format("%s/%s", model, config)
end

function M.diagnoseDispatch(employment, facId, context)
  context = context or "dispatch"
  local deliveryGenerator = employment.services.generator()
  local facility = deliveryGenerator and deliveryGenerator.getFacilityById(facId)
  local loanerCapabilities = employment.services.loanerCapabilities()
  local kinds = employment.parts.eligibility.getAssignableKinds(facId)
  local organization = employment.parts.eligibility.getOrg(employment.employment.employerOrgId)
  local organizationReputationLevel = employment.parts.eligibility.getRepLevel(organization)
  local assignmentTier = loanerCapabilities and loanerCapabilities.getEmploymentAssignmentRepTier(facility, organizationReputationLevel) or nil
  local lines = {
    string.format("employment=%s facId=%s employer=%s home=%s employed=%s onShift=%s",
      context,
      tostring(facId),
      tostring(employment.employment.employerOrgId),
      tostring(employment.employment.homeFacId),
      tostring(employment.lifecycle.isEmployed()),
      tostring(employment.lifecycle.isOnShift())),
    string.format("facility=%s orgMatch=%s kinds=[%s] orgRep=%s assignmentRepTier=%s",
      facility and tostring(facility.id) or "missing",
      tostring(employment.parts.dropOff.facilityMatchesEmployer(facId)),
      M.summarizeKindMap(employment, kinds),
      tostring(organizationReputationLevel),
      tostring(assignmentTier)),
  }
  if employment.employment.shift then
    table.insert(lines, string.format("shift phase=%s kind=%s paused=%s",
      tostring(employment.employment.shift.phase),
      tostring(employment.employment.shift.jobKind),
      tostring(employment.employment.shift.paused)))
  end
  if not loanerCapabilities then
    table.insert(lines, "loanerCapabilities module not loaded")
    return table.concat(lines, "; ")
  end
  if not facility then
    table.insert(lines, "facility lookup failed")
    return table.concat(lines, "; ")
  end
  for _, kind in ipairs({ "repo", "vehicle", "parcel", "trailer", "materials" }) do
    local canIssue = loanerCapabilities.canIssueLoanersForFacility(facility, kind, {})
    local truck, trailer = loanerCapabilities.getIssuedLoanersForFacility(facility, kind, {})
    table.insert(lines, string.format("%s canIssue=%s truck=%s trailer=%s",
      kind,
      tostring(canIssue),
      M.describeLoanerOffer(employment, truck),
      M.describeLoanerOffer(employment, trailer)))
  end
  return table.concat(lines, "; ")
end

function M.diagnoseNoJob(employment, facId)
  return M.diagnoseDispatch(employment, facId, "chooseJob")
end

function M.diagnoseLoanerFailure(employment, facility, job, opts)
  opts = opts or {}
  local loanerCapabilities = employment.services.loanerCapabilities()
  if not loanerCapabilities then
    return "loanerCapabilities module not loaded"
  end
  if not facility then
    return "facility missing for loaner pick"
  end
  local jobKind = job and job.kind or "?"
  if not loanerCapabilities.canIssueLoanersForFacility(facility, jobKind, opts) then
    return string.format("canIssueLoanersForFacility(%s) is false; %s",
      jobKind, M.diagnoseDispatch(employment, facility.id, "loanerGate"))
  end
  local truck, trailer = loanerCapabilities.getIssuedLoanersForFacility(facility, jobKind, opts)
  if not truck then
    return string.format("getIssuedLoanersForFacility(%s) returned no truck; %s",
      jobKind, M.diagnoseDispatch(employment, facility.id, "loanerPick"))
  end
  if kindPolicyOf(employment, jobKind).trailerDelivery and not trailer then
    return string.format("trailer job missing org trailer; truck=%s; %s",
      M.describeLoanerOffer(employment, truck), M.diagnoseDispatch(employment, facility.id, "loanerPick"))
  end
  return M.diagnoseDispatch(employment, facility.id, "loanerPick")
end

-- Return legs ---------------------------------------------------------------------------------------

function M.facDistanceToHome(employment, facId)
  local homeId = employment.employment.homeFacId
  if not homeId or not facId then return math.huge end
  if facId == homeId then return 0 end
  local deliveryGenerator = employment.services.generator()
  if deliveryGenerator then
    -- getDistanceBetweenFacilities returns (distance, routeReliable); only take distance.
    local distanceMeters = deliveryGenerator.getDistanceBetweenFacilities(facId, homeId)
    return tonumber(distanceMeters) or math.huge
  end
  return math.huge
end

function M.destMovesTowardHome(employment, destFacId, fromFacId)
  if not destFacId or not employment.employment.homeFacId then return false end
  if destFacId == employment.employment.homeFacId then return true end
  local startingDistanceToHomeMeters = M.facDistanceToHome(employment, fromFacId or destFacId)
  local destinationDistanceToHomeMeters = M.facDistanceToHome(employment, destFacId)
  return destinationDistanceToHomeMeters < startingDistanceToHomeMeters
end

function M.collectParcelGroups(employment, facId, towardHomeOnly)
  local parcelManager = employment.services.parcelManager()
  if not parcelManager then return {} end
  local cargo = parcelManager.getAllCargoForFacilityUnexpiredUndelivered(facId, nil, nil, "employment") or {}
  local groupsByDestination = {}
  for _, item in ipairs(cargo) do
    local logisticType = item.logisticType or item.lookupType
    if logisticType and employment.excludedParcelTypes[logisticType] then
      goto continueParcel
    end
    if item.offerMode == "independent" then
      goto continueParcel
    end
    if item.offerMode == "employment" and item.organization
        and item.organization ~= employment.employment.employerOrgId then
      goto continueParcel
    end
    if PARCEL_CARGO[item.type] and employment.parts.eligibility.cargoItemUnlocked(item) and item.destination and item.destination.facId and item.destination.facId ~= facId then
      if employment.parts.dropOff.cargoHasTimedModifier(item) then
        goto continueParcel
      end
      if towardHomeOnly and not M.destMovesTowardHome(employment, item.destination.facId, facId) then
        goto continueParcel
      end
      local key = tostring(item.destination.facId) .. "|" .. tostring(item.destination.psPath)
      groupsByDestination[key] = groupsByDestination[key] or { destination = item.destination, items = {}, facId = facId }
      table.insert(groupsByDestination[key].items, item)
    end
    ::continueParcel::
  end
  local groups = {}
  for _, group in pairs(groupsByDestination) do
    table.insert(groups, group)
  end
  table.sort(groups, function(a, b) return #a.items > #b.items end)
  return groups
end

function M.applyParcelCapacity(employment, facId, group)
  if not group then return nil end
  local trim = employment.parts.parcelStrings.trimItems
  if not trim then return group end
  local gen = employment.services.generator()
  local yardId = facId or group.facId
  local facility = yardId and gen and gen.getFacilityById(yardId)
  local items = trim(facility, group.items)
  if not items or not items[1] then return nil end
  if items == group.items then return group end
  return {
    destination = group.destination,
    items = items,
    facId = group.facId,
  }
end

function M.pickParcelGroup(employment, facId)
  local groups = employment.parts.backhaul.ensureParcelGroupsAtFacility(facId)
  return M.applyParcelCapacity(employment, facId, groups[1])
end

function M.pickReturnParcelGroup(employment, fromFacId)
  local groups = M.collectParcelGroups(employment, fromFacId, true)
  local homeId = employment.employment.homeFacId
  -- Prefer a real return to the company yard over other toward-home destinations.
  if homeId then
    for _, group in ipairs(groups) do
      if group.destination and group.destination.facId == homeId then
        local trimmed = M.applyParcelCapacity(employment, group.facId or fromFacId, group)
        if trimmed then return trimmed end
      end
    end
  end
  if groups[1] then return M.applyParcelCapacity(employment, groups[1].facId or fromFacId, groups[1]) end
  local deliveryGenerator = employment.services.generator()
  if not deliveryGenerator then return nil end
  local nearestParcelGroup, nearestDistanceMeters
  for _, facility in ipairs(deliveryGenerator.getFacilities() or {}) do
    if facility and facility.id and facility.id ~= fromFacId then
      local distanceMeters = math.huge
      if deliveryGenerator.getDistanceBetweenFacilities and fromFacId then
        local d = deliveryGenerator.getDistanceBetweenFacilities(fromFacId, facility.id)
        distanceMeters = tonumber(d) or math.huge
      end
      local parcelGroupsAtFacility = M.collectParcelGroups(employment, facility.id, true)
      local homeGroup = nil
      if homeId then
        for _, group in ipairs(parcelGroupsAtFacility) do
          if group.destination and group.destination.facId == homeId then
            homeGroup = group
            break
          end
        end
      end
      local pick = homeGroup or parcelGroupsAtFacility[1]
      if pick then
        pick = M.applyParcelCapacity(employment, facility.id, pick)
      end
      if pick and (not nearestDistanceMeters or distanceMeters < nearestDistanceMeters) then
        nearestParcelGroup, nearestDistanceMeters = pick, distanceMeters
      end
    end
  end
  return nearestParcelGroup
end

function M.pickReturnTrailerOffer(employment, fromFacId)
  local mgr = employment.services.vehicleOffers()
  if not (mgr and mgr.getAllOfferAtFacilityUnexpired) then return nil end
  local loanerCapabilities = employment.services.loanerCapabilities()
  local function scan(facId)
    for _, offer in ipairs(mgr.getAllOfferAtFacilityUnexpired(facId, nil, "employment") or {}) do
      if offer.data and offer.data.type ~= "vehicle" and employment.parts.eligibility.trailerOfferUnlocked(offer)
          and (offer.offerMode ~= "employment" or not offer.organization
            or offer.organization == employment.employment.employerOrgId) then
        local destFacId = offer.destination and offer.destination.facId
          or (offer.locations and offer.locations[2] and offer.locations[2].facId)
        if M.destMovesTowardHome(employment, destFacId, facId)
            and employment.parts.equipment.canReuseIssuedEquipmentForJob("trailer", loanerCapabilities and loanerCapabilities.getOfferCouplerClass(offer) or nil) then
          return offer
        end
      end
    end
    return nil
  end
  local offer = scan(fromFacId)
  if offer then return offer end
  local deliveryGenerator = employment.services.generator()
  if not (deliveryGenerator and deliveryGenerator.getFacilities and deliveryGenerator.getDistanceBetweenFacilities) then return nil end
  local nearestOffer, nearestDistanceMeters
  for _, facility in ipairs(deliveryGenerator.getFacilities() or {}) do
    if facility and facility.id and facility.id ~= fromFacId then
      local candidate = scan(facility.id)
      if candidate then
        local d = deliveryGenerator.getDistanceBetweenFacilities(fromFacId, facility.id)
        local distanceMeters = tonumber(d) or math.huge
        if not nearestDistanceMeters or distanceMeters < nearestDistanceMeters then
          nearestOffer, nearestDistanceMeters = candidate, distanceMeters
        end
      end
    end
  end
  return nearestOffer
end

function M.pickReturnVehicleOffer(employment, fromFacId, excludedOfferIds, opts)
  local mgr = employment.services.vehicleOffers()
  if not (mgr and mgr.getAllOfferAtFacilityUnexpired) then return nil end
  excludedOfferIds = excludedOfferIds or {}
  opts = type(opts) == "table" and opts or {}
  local homeFacId = employment.employment and employment.employment.homeFacId
  local spawnContext = opts.requireHomeDest and "pickHaulBackhaulVehicleOffer" or "pickReturnVehicleOffer"
  local candidates = {}
  local seenFacilities = {}
  local function scan(facId, distance)
    if not facId or seenFacilities[facId] then return end
    seenFacilities[facId] = true
    for _, offer in ipairs(mgr.getAllOfferAtFacilityUnexpired(facId, nil, "employment") or {}) do
      if offer.id and not excludedOfferIds[offer.id]
          and offer.data and offer.data.type == "vehicle" and employment.parts.eligibility.vehicleOfferUnlocked(offer) then
        local destFacId = offer.destination and offer.destination.facId
          or (offer.locations and offer.locations[2] and offer.locations[2].facId)
        local destOk = M.destMovesTowardHome(employment, destFacId, facId)
        if destOk and opts.requireHomeDest then
          destOk = destFacId == homeFacId
        end
        if destOk then
          local ready = true
          if mgr.ensureOfferSpawnReady then
            ready = mgr.ensureOfferSpawnReady(offer, spawnContext) and true or false
          elseif mgr.isOfferSpawnReady then
            ready = mgr.isOfferSpawnReady(offer) and true or false
          end
          if ready then
            candidates[#candidates + 1] = {
              offer = offer,
              distance = tonumber(distance) or math.huge,
            }
          end
        end
      end
    end
  end
  scan(fromFacId, 0)
  local deliveryGenerator = employment.services.generator()
  if deliveryGenerator then
    for _, facility in ipairs(deliveryGenerator.getFacilities() or {}) do
      if facility and facility.id and facility.id ~= fromFacId then
        scan(facility.id, employment.parts.parcelStrings.facDistanceBetween(fromFacId, facility.id))
      end
    end
  end
  table.sort(candidates, function(a, b)
    if a.distance == b.distance then
      return tostring(a.offer.id) < tostring(b.offer.id)
    end
    return a.distance < b.distance
  end)
  return candidates[1] and candidates[1].offer or nil
end

function M.pickHaulBackhaulVehicleOffer(employment, fromFacId, excludedOfferIds)
  return M.pickReturnVehicleOffer(employment, fromFacId, excludedOfferIds, { requireHomeDest = true })
end

-- Outbound offers ----------------------------------------------------------------------------------

function M.pickTrailerOffer(employment, facId)
  local mgr = employment.services.vehicleOffers()
  if not (mgr and mgr.getAllOfferAtFacilityUnexpired) then return nil end
  local function firstOffer()
    for _, offer in ipairs(mgr.getAllOfferAtFacilityUnexpired(facId, nil, "employment") or {}) do
      if offer.data and offer.data.type ~= "vehicle" and employment.parts.eligibility.trailerOfferUnlocked(offer) then
        return offer
      end
    end
    return nil
  end
  local offer = firstOffer()
  if offer then return offer end
  local deliveryGenerator = employment.services.generator()
  local facility = deliveryGenerator and deliveryGenerator.getFacilityById(facId)
  if deliveryGenerator and facility and deliveryGenerator.triggerGenerator then
    for _, generator in ipairs(facility.logisticGenerators or {}) do
      if generator.type == "trailerOfferProvider" then
        deliveryGenerator.triggerGenerator(facility, generator)
      end
    end
  end
  return firstOffer()
end

function M.collectReadyVehicleOffers(employment, facId, minCount)
  local mgr = employment.services.vehicleOffers()
  if not (mgr and mgr.getAllOfferAtFacilityUnexpired) then return {} end
  local deliveryGenerator = employment.services.generator()
  if deliveryGenerator then
    deliveryGenerator.triggerAllGenerators()
  end
  local ready = {}
  local function scan()
    ready = {}
    for _, offer in ipairs(mgr.getAllOfferAtFacilityUnexpired(facId, nil, "employment") or {}) do
      if offer.data and offer.data.type == "vehicle" and employment.parts.eligibility.vehicleOfferUnlocked(offer) then
        local ok, err = true, nil
        if mgr.ensureOfferSpawnReady then
          ok, err = mgr.ensureOfferSpawnReady(offer, "collectReadyVehicleOffers")
        elseif mgr.isOfferSpawnReady then
          ok = mgr.isOfferSpawnReady(offer)
          if ok then
            err = nil
          else
            err = "not spawnable"
          end
        end
        if ok then
          table.insert(ready, offer)
        else
          employment.log("pickVehicleOffer", string.format("skipped offer %s: %s", tostring(offer.id), err or "not spawnable"))
        end
      end
    end
  end
  scan()
  if minCount and #ready < minCount and deliveryGenerator then
    local facility = deliveryGenerator.getFacilityById(facId)
    local prev = #ready
    for _ = 1, 8 do
      if #ready >= minCount then break end
      for _, generator in ipairs((facility and facility.logisticGenerators) or {}) do
        if generator.type == "vehOfferProvider" then
          deliveryGenerator.triggerGenerator(facility, generator)
        end
      end
      scan()
      if #ready <= prev then break end
      prev = #ready
    end
  end
  return ready
end

function M.pickDistributorVehicleOffers(employment, facId, count)
  count = count or employment.distributorCount
  local offers = M.collectReadyVehicleOffers(employment, facId, count)
  if not offers[1] then return {} end
  local groupsByDestination = {}
  local largest = nil
  for _, offer in ipairs(offers) do
    local destination = offer.destination or (offer.locations and offer.locations[2])
    local key = destination and tostring(destination.facId or destination.psPath or offer.id) or tostring(offer.id)
    groupsByDestination[key] = groupsByDestination[key] or {}
    table.insert(groupsByDestination[key], offer)
    if not largest or #groupsByDestination[key] > #largest then
      largest = groupsByDestination[key]
    end
  end
  local picked = {}
  local used = {}
  local function takeFrom(group)
    for _, offer in ipairs(group or {}) do
      if #picked >= count then return end
      if offer and offer.id and not used[offer.id] then
        used[offer.id] = true
        table.insert(picked, offer)
      end
    end
  end
  takeFrom(largest)
  takeFrom(offers)
  if #picked < count then return {} end
  local deliveryGenerator = employment.services.generator()
  local facility = deliveryGenerator and deliveryGenerator.getFacilityById(facId)
  employment.parts.dropOff.stageDistributorHaulOffers(facility, picked)
  return picked
end

function M.pickVehicleOffer(employment, facId)
  local offers = M.collectReadyVehicleOffers(employment, facId)
  return offers[1]
end

function M.materialTripLimits(mgr)
  if mgr and mgr.getEmploymentTripLimits then
    local preferred, max = mgr.getEmploymentTripLimits()
    if preferred and max then return preferred, max end
  end
  return 4, 6
end

function M.materialCapacityLookup(employment, facility)
  local cache = {}
  return function(cargoType)
    if not (facility and cargoType) then return nil end
    if cache[cargoType] == nil then
      local loanerCapabilities = employment.services.loanerCapabilities()
      local capacity = 0
      if loanerCapabilities and loanerCapabilities.getIssuedLoanersForFacility and loanerCapabilities.getCapacity then
        local ok, truck, trailer = pcall(loanerCapabilities.getIssuedLoanersForFacility, facility, "materials", { cargoType = cargoType })
        if ok and truck then
          capacity = math.max(loanerCapabilities.getCapacity(truck, cargoType) or 0, trailer and loanerCapabilities.getCapacity(trailer, cargoType) or 0)
        end
      end
      cache[cargoType] = capacity
    end
    return cache[cargoType] > 0 and cache[cargoType] or nil
  end
end

function M.materialOfferTrips(offer, capacity)
  if not (offer and capacity and capacity > 0) then return nil end
  return math.ceil((tonumber(offer.totalAmount) or 0) / capacity - 1e-6)
end

function M.materialOfferFits(offer, capacity, maxTrips)
  local trips = M.materialOfferTrips(offer, capacity)
  return not trips or not maxTrips or trips <= maxTrips
end

function M.pickMaterialOffer(employment, facId)
  local mgr = employment.services.materials()
  if not mgr then return nil end
  local facility = employment.services.generator() and employment.services.generator().getFacilityById and employment.services.generator().getFacilityById(facId)
  local loanerCapabilities = employment.services.loanerCapabilities()
  local preferredTrips, maxTrips = M.materialTripLimits(mgr)
  local capacityFor = M.materialCapacityLookup(employment, facility)
  local function offerIssuable(offer)
    if not offer or not employment.parts.eligibility.materialOfferUnlocked(offer) then return false end
    if offer.offerExpiresAt and offer.offerExpiresAt <= employment.nowSim() then return false end
    if not (facility and loanerCapabilities) then return true end
    return employment.parts.eligibility.canIssueEmploymentMaterials(facility, offer.cargoType)
  end
  local function fits(offer, trips)
    return M.materialOfferFits(offer, capacityFor(offer.cargoType), trips)
  end
  local function firstLiveOffer(trips)
    if not mgr.getOffersForFacility then return nil end
    for _, offer in ipairs(mgr.getOffersForFacility(facId, "employment") or {}) do
      if offerIssuable(offer) and fits(offer, trips) then
        return offer
      end
    end
    return nil
  end
  local offer = firstLiveOffer(preferredTrips)
  if offer then return offer end
  if mgr.generateSizedOffer then
    offer = mgr.generateSizedOffer(facId, {
      audience = "employment",
      allows = function(shape) return employment.parts.eligibility.materialOfferUnlocked(shape) and employment.parts.eligibility.canIssueEmploymentMaterials(facility, shape.cargoType) end,
      tripCapacity = capacityFor,
      replaceable = function(existing) return not fits(existing, preferredTrips) end,
    })
    if offer and offerIssuable(offer) and fits(offer, maxTrips) then return offer end
  end
  if mgr.generateOfferForFacility then
    for _ = 1, 3 do
      offer = mgr.generateOfferForFacility(facId)
      if offer and offerIssuable(offer) and fits(offer, preferredTrips) then
        return offer
      end
    end
  end
  return firstLiveOffer(maxTrips)
end

-- Inbound offers (pickups toward the employer's yard) ------------------------------------------

function M.iterFacilitiesPreferOrg(employment, homeFacId, orgId, fn)
  local deliveryGenerator = employment.services.generator()
  if not deliveryGenerator then return nil end
  local function pass(preferOrgOnly)
    for _, facility in ipairs(deliveryGenerator.getFacilities() or {}) do
      if facility and facility.id and facility.id ~= homeFacId then
        if (not preferOrgOnly) or (orgId and facility.associatedOrganization == orgId) then
          local result = fn(facility)
          if result then return result end
        end
      end
    end
    return nil
  end
  return pass(true) or pass(false)
end

function M.pickInboundParcelGroup(employment, homeFacId)
  if not homeFacId then return nil end
  local orgId = employment.employment.employerOrgId
  local deliveryGenerator = employment.services.generator()
  local homeFac = deliveryGenerator and deliveryGenerator.getFacilityById(homeFacId)
  orgId = orgId or (homeFac and homeFac.associatedOrganization)
  return M.iterFacilitiesPreferOrg(employment, homeFacId, orgId, function(facility)
    for _, group in ipairs(M.collectParcelGroups(employment, facility.id, false)) do
      if group.destination and group.destination.facId == homeFacId then
        group.facId = group.facId or facility.id
        local trimmed = M.applyParcelCapacity(employment, facility.id, group)
        if trimmed then return trimmed end
      end
    end
    return nil
  end)
end

function M.pickInboundTrailerOffer(employment, homeFacId)
  if not homeFacId then return nil end
  local mgr = employment.services.vehicleOffers()
  if not (mgr and mgr.getAllOfferAtFacilityUnexpired) then return nil end
  local orgId = employment.employment.employerOrgId
  local deliveryGenerator = employment.services.generator()
  local homeFac = deliveryGenerator and deliveryGenerator.getFacilityById(homeFacId)
  orgId = orgId or (homeFac and homeFac.associatedOrganization)
  return M.iterFacilitiesPreferOrg(employment, homeFacId, orgId, function(facility)
    for _, offer in ipairs(mgr.getAllOfferAtFacilityUnexpired(facility.id, nil, "employment") or {}) do
      if offer.data and offer.data.type ~= "vehicle" and employment.parts.eligibility.trailerOfferUnlocked(offer) then
        local destFacId = offer.destination and offer.destination.facId
          or (offer.locations and offer.locations[2] and offer.locations[2].facId)
        if destFacId == homeFacId then
          return offer
        end
      end
    end
    return nil
  end)
end

function M.pickInboundMaterialOffer(employment, homeFacId)
  if not homeFacId then return nil end
  local mgr = employment.services.materials()
  local deliveryGenerator = employment.services.generator()
  local loanerCapabilities = employment.services.loanerCapabilities()
  if not (mgr and deliveryGenerator and deliveryGenerator.getFacilityById) then return nil end
  local homeFac = deliveryGenerator.getFacilityById(homeFacId)
  local orgId = employment.employment.employerOrgId or (homeFac and homeFac.associatedOrganization)
  local _, maxTrips = M.materialTripLimits(mgr)
  local capacityFor = M.materialCapacityLookup(employment, homeFac)
  local function offerOk(offer)
    if not offer or not employment.parts.eligibility.materialOfferUnlocked(offer) then return false end
    if offer.offerExpiresAt and offer.offerExpiresAt <= employment.nowSim() then return false end
    local destId = offer.destinationFacId or (offer.destination and offer.destination.facId)
    if destId ~= homeFacId then return false end
    if not (homeFac and loanerCapabilities) then return true end
    return employment.parts.eligibility.canIssueEmploymentMaterials(homeFac, offer.cargoType)
      and M.materialOfferFits(offer, capacityFor(offer.cargoType), maxTrips)
  end
  return M.iterFacilitiesPreferOrg(employment, homeFacId, orgId, function(facility)
    if mgr.generateOfferForFacility and #(mgr.getOffersForFacility(facility.id, "employment") or {}) == 0 then
      for _ = 1, 2 do
        mgr.generateOfferForFacility(facility.id)
      end
    end
    for _, offer in ipairs(mgr.getOffersForFacility(facility.id, "employment") or {}) do
      if offerOk(offer) then
        return offer
      end
    end
    return nil
  end)
end

function M.pickInboundVehicleOffer(employment, homeFacId)
  if not homeFacId then return nil end
  local mgr = employment.services.vehicleOffers()
  if not (mgr and mgr.getAllOfferAtFacilityUnexpired) then return nil end
  local orgId = employment.employment.employerOrgId
  local deliveryGenerator = employment.services.generator()
  local homeFac = deliveryGenerator and deliveryGenerator.getFacilityById(homeFacId)
  orgId = orgId or (homeFac and homeFac.associatedOrganization)
  local function tryPick(requireHomeDest)
    return M.iterFacilitiesPreferOrg(employment, homeFacId, orgId, function(facility)
      if not employment.parts.eligibility.facilityOffersKind(facility, "vehicle") then return nil end
      for _, offer in ipairs(mgr.getAllOfferAtFacilityUnexpired(facility.id, nil, "employment") or {}) do
        if offer.data and offer.data.type == "vehicle" and employment.parts.eligibility.vehicleOfferUnlocked(offer) then
          local destOk = true
          if requireHomeDest then
            local destFacId = offer.destination and offer.destination.facId
              or (offer.locations and offer.locations[2] and offer.locations[2].facId)
            destOk = destFacId == homeFacId
          end
          if destOk then
            local ready = true
            if mgr.ensureOfferSpawnReady then
              ready = mgr.ensureOfferSpawnReady(offer, "pickInboundVehicleOffer")
            elseif mgr.isOfferSpawnReady then
              ready = mgr.isOfferSpawnReady(offer)
            end
            if ready then
              return offer
            end
          end
        end
      end
      return nil
    end)
  end
  return tryPick(true) or tryPick(false)
end

-- Surge and weights --------------------------------------------------------------------------------

-- Each kind owns its surge leaf; a kind without one returns nil.
function M.surgeLeaf(employment, kind, cargoType)
  return (employment.shared.kindHandler(kind, "surgeLeaf", cargoType))
end

function M.dispatchSurgeLeaf(employment, kind, cargoType)
  return M.surgeLeaf(employment, kind, cargoType) or "delivery_parcel"
end

function M.dispatchKindBaseWeight(_ctx, _kind, _cargoType)
  return 1.0
end

function M.dispatchSurgeWeight(employment, kind, cargoType)
  local base = M.dispatchKindBaseWeight(employment, kind, cargoType)
  local factor = overhaul_career_economy_activityHeat.getDemandFactor(M.dispatchSurgeLeaf(employment, kind, cargoType))
  local surge = math.max(0.05, tonumber(factor) or 1)
  return base * surge
end

function M.chooseWeightedJobOption(employment, options)
  if not options or not options[1] then return nil end
  if #options == 1 then return options[1] end
  local total = 0
  for _, option in ipairs(options) do
    option._weight = M.dispatchSurgeWeight(employment, option.kind, option.cargoType)
    total = total + option._weight
  end
  if total <= 0 then return options[((math.floor(employment.nowSim()) % #options) + 1)] end
  local roll = math.random() * total
  for _, option in ipairs(options) do
    roll = roll - option._weight
    if roll <= 0 then return option end
  end
  return options[#options]
end

function M.parcelGroupTargetLoad(_ctx, group)
  local total = 0
  for _, item in ipairs((group and group.items) or {}) do
    total = total + math.max(1, math.floor(tonumber(item.slots) or 1))
  end
  return total
end

function M.vehicleOfferRollbackPolicy(_ctx, vehicleOffer, facility, loanerCaps)
  local vehicle = vehicleOffer and vehicleOffer.vehicle or {}
  local filterId = vehicle.filterId or (vehicleOffer and vehicleOffer.filterId)
  local unlockTag = vehicle.unlockTag or (vehicleOffer and vehicleOffer.unlockTag)
  local model = vehicle.model or (vehicleOffer and vehicleOffer.model)
  local isHeavy = filterId == "heavyVehFilter" or unlockTag == "heavyVeh"
  local requireTSeriesRollback = not isHeavy and model == "pickup"
  if isHeavy then return false, false end
  if requireTSeriesRollback then
    local available = loanerCaps and loanerCaps.canIssueTSeriesRollbackRepoForFacility
      and loanerCaps.canIssueTSeriesRollbackRepoForFacility(facility, {})
    return available and true or false, true
  end
  return true, false
end

-- Job options ----------------------------------------------------------------------------------------

-- Yards with empty boards must refresh before any kind reads its offers, or the first clock-in falls through to car jockeys.
local function refreshYardGenerators(employment)
  local deliveryGenerator = employment.services.generator()
  if deliveryGenerator then
    deliveryGenerator.triggerAllGenerators()
  end
end

local function addOption(options, option)
  if option then table.insert(options, option) end
end

local function roleplayJobOptions(employment, facility, profile)
  local loanerCapabilities = employment.services.loanerCapabilities()
  if loanerCapabilities and loanerCapabilities.canIssueRoleplayVehicleForFacility(facility, {}) then
    return { employment.parts.eligibility.makeRoleplayJob(profile) }
  end
  local _, fleet
  if loanerCapabilities then _, fleet = loanerCapabilities.getServiceFleetForFacility(facility) end
  return {}, (fleet and fleet.unavailableReason) or "No company vehicle is unlocked yet"
end

-- A distributor haul sends several vehicles to one dealer; the company truck and trailer are issued.
local function distributorJobOption(employment, offers)
  local first = offers[1]
  local destination = first.destination or (first.locations and first.locations[2])
  local origin = first.origin or (first.locations and first.locations[1])
  local ids = {}
  for _, offer in ipairs(offers) do
    table.insert(ids, offer.id)
  end
  local destName = employment.parts.parcelLoading.describeDest(destination)
  return {
    kind = "vehicle",
    distributorHaul = true,
    offerId = ids[1],
    offerIds = ids,
    destFacId = destination and destination.facId,
    destPsPath = destination and destination.psPath,
    destLocation = destination,
    originLocation = origin,
    label = #ids > 1
      and string.format("Haul %d vehicles to %s", #ids, destName)
      or string.format("Deliver %s to %s", first.name or "assigned vehicle", destName),
    subtext = "Company truck and trailer issued — no return freight",
  }
end

local function distributorJobOptions(employment, facId, kinds)
  if not kinds.vehicle then
    return {}, M.diagnoseNoJob(employment, facId)
  end
  local offers = M.pickDistributorVehicleOffers(employment, facId, employment.distributorCount)
  if #offers < employment.distributorCount then
    return {}, M.diagnoseNoJob(employment, facId)
  end
  return { distributorJobOption(employment, offers) }
end

-- Picks one source per kind; an inbound pickup is tried only when nothing is ready at this yard.
local function pickJobSources(employment, facId, kinds)
  local picks = {}
  picks.parcelGroup = kinds.parcel and M.pickParcelGroup(employment, facId) or nil
  picks.parcelInbound = false
  if kinds.parcel and not picks.parcelGroup then
    picks.parcelGroup = M.pickInboundParcelGroup(employment, facId)
    picks.parcelInbound = picks.parcelGroup ~= nil
  end
  picks.trailerOffer = kinds.trailer and M.pickTrailerOffer(employment, facId) or nil
  picks.trailerInbound = false
  if kinds.trailer and not picks.trailerOffer then
    picks.trailerOffer = M.pickInboundTrailerOffer(employment, facId)
    picks.trailerInbound = picks.trailerOffer ~= nil
  end
  picks.vehicleOffer = kinds.vehicle and M.pickVehicleOffer(employment, facId) or nil
  if kinds.vehicle and not picks.vehicleOffer then
    picks.vehicleOffer = M.pickInboundVehicleOffer(employment, facId)
  end
  picks.materialOffer = kinds.materials and M.pickMaterialOffer(employment, facId) or nil
  picks.materialInbound = false
  if kinds.materials and not picks.materialOffer then
    picks.materialOffer = M.pickInboundMaterialOffer(employment, facId)
    picks.materialInbound = picks.materialOffer ~= nil
  end
  return picks
end

local function parcelJobOption(employment, facId, facility, picks)
  local parcelGroup = picks.parcelGroup
  if not parcelGroup then return nil end
  local ids = {}
  for _, item in ipairs(parcelGroup.items) do table.insert(ids, item.id) end
  local targetLoad = M.parcelGroupTargetLoad(employment, parcelGroup)
  if not (facility and employment.services.loanerCapabilities() and employment.services.loanerCapabilities().canIssueLoanersForFacility(facility, "parcel", { targetLoad = targetLoad })) then
    return nil
  end
  local pickupFacId = parcelGroup.facId
    or (parcelGroup.items[1] and parcelGroup.items[1].origin and parcelGroup.items[1].origin.facId)
    or facId
  local pickupName = employment.parts.parcelLoading.describeFacilityName(pickupFacId)
  local destName = employment.parts.parcelLoading.describeDest(parcelGroup.destination)
  return {
    kind = "parcel",
    cargoIds = ids,
    destFacId = parcelGroup.destination.facId,
    destPsPath = parcelGroup.destination.psPath,
    destLocation = parcelGroup.destination,
    originLocation = parcelGroup.items[1] and parcelGroup.items[1].origin
      or { type = "facilityParkingspot", facId = pickupFacId },
    needsRemotePickup = picks.parcelInbound or (pickupFacId ~= facId),
    pickupFacId = pickupFacId,
    label = (picks.parcelInbound or pickupFacId ~= facId)
      and string.format("Pick up parcels at %s, deliver to %s", pickupName, destName)
      or string.format("Deliver assigned parcels to %s", destName),
    subtext = string.format("%d assigned parcels", #ids),
  }
end

local function trailerJobOption(employment, facId, facility, picks)
  local trailerOffer = picks.trailerOffer
  if not (trailerOffer and facility and employment.services.loanerCapabilities() and employment.services.loanerCapabilities().canIssueLoanersForFacility(facility, "trailer", {
    couplerClass = employment.services.loanerCapabilities().getOfferCouplerClass and employment.services.loanerCapabilities().getOfferCouplerClass(trailerOffer) or nil,
  })) then
    return nil
  end
  local destination = trailerOffer.destination or (trailerOffer.locations and trailerOffer.locations[2])
  local origin = trailerOffer.origin or (trailerOffer.locations and trailerOffer.locations[1])
  local pickupFacId = origin and origin.facId or facId
  local pickupName = employment.parts.parcelLoading.describeFacilityName(pickupFacId)
  local destName = employment.parts.parcelLoading.describeDest(destination)
  return {
    kind = "trailer",
    offerId = trailerOffer.id,
    destFacId = destination and destination.facId,
    destPsPath = destination and destination.psPath,
    destLocation = destination,
    originLocation = origin,
    couplerClass = employment.services.loanerCapabilities().getOfferCouplerClass and employment.services.loanerCapabilities().getOfferCouplerClass(trailerOffer) or nil,
    label = (picks.trailerInbound or pickupFacId ~= facId)
      and string.format("Pick up trailer at %s, deliver to %s", pickupName, destName)
      or string.format("Tow the assigned trailer to %s", destName),
    subtext = trailerOffer.name or "Assigned trailer",
  }
end

local function yardNameOf(employment, facility)
  return (facility and employment.parts.eligibility.translateUiText(facility.name, facility.id))
    or employment.parts.eligibility.getOrgDisplayName(employment.parts.eligibility.getOrg(facility and facility.associatedOrganization or employment.employment.employerOrgId), employment.employment.employerOrgId)
end

-- A vehicle delivery becomes a car-hauling bundle when the yard can issue a rollback to bring a car back.
local function vehicleJobOption(employment, facility, vehicleOffer, yardName)
  local loanerCaps = employment.services.loanerCapabilities()
  if not (vehicleOffer and facility and loanerCaps) then return nil end
  local destination = vehicleOffer.destination or (vehicleOffer.locations and vehicleOffer.locations[2])
  local vehName = vehicleOffer.name or "assigned vehicle"
  local useRollback, requireTSeriesRollback = M.vehicleOfferRollbackPolicy(employment, vehicleOffer, facility, loanerCaps)
  local option = {
    offerId = vehicleOffer.id,
    destFacId = destination and destination.facId,
    destPsPath = destination and destination.psPath,
    destLocation = destination,
    originLocation = vehicleOffer.origin or (vehicleOffer.locations and vehicleOffer.locations[1]),
  }
  if useRollback then
    option.kind = "vehicle_repo_bundle"
    option.requireTSeriesRollback = requireTSeriesRollback and true or nil
    option.vehicleLabel = string.format("Deliver %s to %s", vehName, employment.parts.parcelLoading.describeDest(destination))
    option.vehicleSubtext = "Car hauling"
    option.repoLabel = "Pickup — haul a vehicle back to the yard"
    option.repoSubtext = "Company rollback"
    option.label = "Car hauling"
    option.subtext = string.format("Deliver the %s, then pick up another vehicle for %s", vehName, yardName)
  else
    option.kind = "vehicle"
    option.label = "Vehicle delivery"
    option.subtext = string.format("Drive the %s to %s", vehName, employment.parts.parcelLoading.describeDest(destination))
  end
  return option
end

local function materialJobOption(employment, facId, facility, picks)
  local materialOffer = picks.materialOffer
  if not (materialOffer and facility and employment.parts.eligibility.canIssueEmploymentMaterials(facility, materialOffer.cargoType)) then return nil end
  local materialName = employment.parts.eligibility.translateUiText(materialOffer.materialName, materialOffer.materialType or "material")
  local destName = employment.parts.eligibility.translateUiText(materialOffer.destinationName, "the receiver")
  local sourceName = employment.parts.eligibility.translateUiText(materialOffer.sourceName, materialOffer.sourceFacId or "the loader")
  local pickupFacId = materialOffer.sourceFacId
    or (materialOffer.origin and materialOffer.origin.facId)
    or facId
  return {
    kind = "materials",
    contractId = materialOffer.id,
    cargoType = materialOffer.cargoType,
    standardLoad = materialOffer.standardLoad and math.min(materialOffer.totalAmount or math.huge, materialOffer.standardLoad) or materialOffer.totalAmount,
    materialName = materialName,
    destFacId = materialOffer.destination and materialOffer.destination.facId,
    destPsPath = materialOffer.destination and materialOffer.destination.psPath,
    originLocation = materialOffer.origin,
    destLocation = materialOffer.destination,
    label = (picks.materialInbound or pickupFacId ~= facId)
      and string.format("Pick up %s at %s, deliver to %s", materialName, sourceName, destName)
      or string.format("Load %s, then deliver to %s", materialName, destName),
    subtext = (picks.materialInbound or pickupFacId ~= facId)
      and string.format("Company truck at the yard — load at %s", sourceName)
      or "Go to the marked loading point",
  }
end

local function repoJobOption(employment, facility, kinds, vehicleOffer, yardName)
  if not (kinds.repo and not vehicleOffer and facility and employment.services.loanerCapabilities() and employment.services.loanerCapabilities().canIssueRepoForFacility(facility, {})) then
    return nil
  end
  return {
    kind = "repo",
    label = "Pickup — haul a vehicle back to the yard",
    subtext = string.format("Company rollback for %s", yardName),
  }
end

function M.buildJobOptions(employment, facId)
  local facility = employment.services.generator() and employment.services.generator().getFacilityById and employment.services.generator().getFacilityById(facId)
  local profile, organization = employment.parts.eligibility.getFacilityEmployerProfile(facId)
  if not organization then
    organization = employment.parts.eligibility.getOrg(employment.employment.employerOrgId)
  end
  if employment.parts.eligibility.isRoleplayProfile(profile) then
    return roleplayJobOptions(employment, facility, profile)
  end

  organization = employment.parts.eligibility.getOrg(employment.employment.employerOrgId) or organization
  refreshYardGenerators(employment)

  local kinds = employment.parts.eligibility.getAssignableKinds(facId)
  if employment.parts.eligibility.facilityIssuesDistributorHaul(facility) then
    return distributorJobOptions(employment, facId, kinds)
  end
  if employment.parts.eligibility.isParcelStringEmployer(facId) then
    local stringJob = employment.parts.parcelStrings.buildJob(facId)
    if stringJob then
      return { stringJob }
    end
  end

  local picks = pickJobSources(employment, facId, kinds)
  local options = {}
  addOption(options, parcelJobOption(employment, facId, facility, picks))
  addOption(options, trailerJobOption(employment, facId, facility, picks))
  local yardName = yardNameOf(employment, facility)
  addOption(options, vehicleJobOption(employment, facility, picks.vehicleOffer, yardName))
  addOption(options, materialJobOption(employment, facId, facility, picks))
  addOption(options, repoJobOption(employment, facility, kinds, picks.vehicleOffer, yardName))
  if #options == 0 then
    return {}, M.diagnoseNoJob(employment, facId)
  end
  return options
end

function M.chooseJob(employment, facId)
  local options, err = M.buildJobOptions(employment, facId)
  if not options or #options == 0 then
    return nil, err or M.diagnoseNoJob(employment, facId)
  end
  return M.chooseWeightedJobOption(employment, options)
end

-- Selection ------------------------------------------------------------------------------------------

function M.selectedJobKind(_ctx, selection)
  if type(selection) == "string" then return selection end
  if type(selection) == "table" and selection.kind then return tostring(selection.kind) end
  return nil
end

local function firstBundledOption(employment, options)
  for _, option in ipairs(options) do
    if kindPolicyOf(employment, option.kind).bundledAssignments then
      return option
    end
  end
  return nil
end

function M.resolveSelectedJob(employment, facId, selection)
  local kind = M.selectedJobKind(employment, selection)
  if not kind or kind == "" then
    return nil, "No job selected."
  end
  local options, err = M.buildJobOptions(employment, facId)
  local policy = kindPolicyOf(employment, kind)
  if policy.parcels and (not options or not options[1]) then
    employment.parts.backhaul.ensureParcelGroupsAtFacility(facId)
    options, err = M.buildJobOptions(employment, facId)
  end
  if not options or #options == 0 then
    if policy.parcels then
      return nil, "No parcel loads are ready at this yard yet. Try again in a moment."
    end
    return nil, err or M.diagnoseNoJob(employment, facId)
  end
  for _, option in ipairs(options) do
    if option.kind == kind then
      return option
    end
  end
  -- "hauling" is the dev-menu alias for any car-hauling option, not a kind of its own.
  if policy.vehicleDelivery or kind == "hauling" then
    local bundled = firstBundledOption(employment, options)
    if bundled then return bundled end
  end
  if policy.bundledAssignments then
    local bundled = firstBundledOption(employment, options)
    if bundled then return bundled end
  end
  return nil, string.format("No live %s job ready at this yard.", DEV_KIND_LABELS[kind] or kind)
end

function M.getDevJobOptions(employment, facId)
  if not employment.shared.isDevToolsEnabled() then
    return { ok = false, message = "Dev key required.", options = {} }
  end
  local list = {}
  local profile = select(1, employment.parts.eligibility.getFacilityEmployerProfile(facId))
  if employment.parts.eligibility.isRoleplayProfile(profile) then
    list[1] = {
      id = profile,
      kind = profile,
      label = DEV_KIND_LABELS[profile] or profile,
      subtext = "Roleplay shift",
    }
    return { ok = true, options = list }
  end
  local deliveryGenerator = employment.services.generator()
  local facility = deliveryGenerator and deliveryGenerator.getFacilityById(facId)
  if facility and employment.parts.eligibility.facilityIssuesDistributorHaul(facility) then
    list[1] = {
      id = "vehicle",
      kind = "vehicle",
      label = "Car hauling",
      subtext = "Multiple vehicles to one dealer — truck and trailer by rep",
    }
    return { ok = true, options = list }
  end
  local kinds = employment.parts.eligibility.getAssignableKinds(facId)
  for _, kind in ipairs(DEV_KIND_ORDER) do
    if kinds[kind] then
      -- Vehicle + repo at the same yard is issued as one bundle; don't list repo twice.
      if kindPolicyOf(employment, kind).repossession and kinds.vehicle then
        goto continue
      end
      list[#list + 1] = {
        id = kind,
        kind = kind,
        label = DEV_KIND_LABELS[kind] or kind,
        subtext = "Force this job type on clock-in",
      }
    end
    ::continue::
  end
  return {
    ok = true,
    options = list,
    message = (#list == 0) and "No job types available at this yard." or nil,
  }
end

-- Context -----------------------------------------------------------------------------------------

local function dispatchContext(inputs)
  local shared, state = inputs.shared, inputs.state
  return {
    parts = inputs.parts,
    shared = inputs.shared,
    lifecycle = inputs.lifecycle,
    employment = {
      employerOrgId = state.employerOrgId,
      homeFacId = (state.shift and state.shift.originFacId) or state.homeFacId,
      shift = state.shift and {phase = state.shift.phase, jobKind = state.shift.jobKind, paused = state.shift.paused},
    },
    excludedParcelTypes = inputs.EMPLOYMENT_PARCEL_EXCLUDED_TYPES,
    distributorCount = inputs.dropOff.DISTRIBUTOR_HAUL_COUNT,
    nowSim = shared.nowSim,
    log = shared.shiftLog,
    services = {
      generator = shared.generator,
      loanerCapabilities = shared.loanerCapabilities,
      materials = shared.materials,
      parcelManager = shared.parcelManager,
      vehicleOffers = shared.vehicleOffers,
    },
  }
end

-- Part factory ------------------------------------------------------------------------------------

function M.new(inputs)
  local api = require("overhaul/career/work/employment/operations").new {
    api = inputs.api,
    operations = M,
    context = function() return dispatchContext(inputs) end,
    withContext = {
      summarizeKindMap = true,
      describeLoanerOffer = true,
      diagnoseDispatch = true,
      diagnoseNoJob = true,
      diagnoseLoanerFailure = true,
      facDistanceToHome = true,
      destMovesTowardHome = true,
      collectParcelGroups = true,
      applyParcelCapacity = true,
      pickParcelGroup = true,
      pickReturnParcelGroup = true,
      pickReturnTrailerOffer = true,
      pickReturnVehicleOffer = true,
      pickHaulBackhaulVehicleOffer = true,
      pickTrailerOffer = true,
      collectReadyVehicleOffers = true,
      pickDistributorVehicleOffers = true,
      pickVehicleOffer = true,
      materialCapacityLookup = true,
      pickMaterialOffer = true,
      iterFacilitiesPreferOrg = true,
      pickInboundParcelGroup = true,
      pickInboundTrailerOffer = true,
      pickInboundMaterialOffer = true,
      pickInboundVehicleOffer = true,
      surgeLeaf = true,
      dispatchSurgeLeaf = true,
      dispatchKindBaseWeight = true,
      dispatchSurgeWeight = true,
      chooseWeightedJobOption = true,
      parcelGroupTargetLoad = true,
      vehicleOfferRollbackPolicy = true,
      buildJobOptions = true,
      chooseJob = true,
      selectedJobKind = true,
      resolveSelectedJob = true,
      getDevJobOptions = true,
    },
  }
  -- Callers that need the raw context (kind handlers, market offerings) read it here.
  api.dispatchContext = function() return dispatchContext(inputs) end
  return api
end

return M
