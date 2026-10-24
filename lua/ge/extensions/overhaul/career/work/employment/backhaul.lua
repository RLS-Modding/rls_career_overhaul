-- Return assignments and repo legs for a company shift: return loads, haul routes and repo pickups.
-- Reading order: offer preparation, return choice, haul routes, repo lifecycle, parcel strings and dispatch fallback.
local part = {}

local OFFER_HOLD_SECONDS = 3600

-- Keeps a board offer alive long enough to drive to its pickup.
local function extendOfferExpiry(offer, now)
  offer.offerExpiresAt = math.max(tonumber(offer.offerExpiresAt) or 0, now + OFFER_HOLD_SECONDS)
end

local function offerDestFacId(offer)
  return offer.destination and offer.destination.facId
    or (offer.locations and offer.locations[2] and offer.locations[2].facId)
end

-- Shared helpers ----------------------------------------------------------------------------------

local function nowSim(shared)
  return (shared.general() and shared.general().time()) or 0
end

local function facilityLabel(inputs, facId, fac)
  if fac and fac.name then
    return inputs.eligibility.translateUiText(fac.name, facId or fac.id)
  end
  return inputs.parcelLoading.describeFacilityName(facId)
end

-- Pays the repo skill XP; a failed grant is logged and never blocks the finished leg.
local function payRepoSkillXp(RECOVERY_SKILL_ATTRIBUTE_KEY, meta)
  local skillXp = meta and tonumber(meta.skillXp) or 0
  if skillXp <= 0 then return end
  local xpOk, xpErr = pcall(overhaul_career_economy_payment.payout, {
    xp = { [RECOVERY_SKILL_ATTRIBUTE_KEY] = skillXp },
    tags = { "gameplay", "repo", "recovery", "employment" },
  })
  if not xpOk then
    log("W", "employment", "Repo skill XP grant failed: " .. tostring(xpErr))
  end
end

-- Holds the leg's gross in escrow until the shift ends, then applies any surge bonus.
local function settleRepoGross(inputs, shift, gross)
  if gross > 0 then
    local keep = inputs.settlement.addEscrowKeep("Flatbed haul", gross, inputs.projections.getCompanyShare())
    ui_message(string.format("Company is holding $%d until you end your shift.", keep), 6, "info")
  end
  inputs.settlement.maybeApplySurgeAssignmentBonus(shift)
end


-- Return loads -----------------------------------------------------------------------------------

local function addVehicleBackhaulApi(api, inputs, shared, state)
  api.assignVehicleBackhaulOffer = function(vehicleOffer, fromFacId)
    local shift = state.shift
    if not (shift and vehicleOffer) then return false end
    local dest = vehicleOffer.destination or (vehicleOffer.locations and vehicleOffer.locations[2])
    local pickupFacId = (vehicleOffer.origin and vehicleOffer.origin.facId)
      or (vehicleOffer.locations and vehicleOffer.locations[1] and vehicleOffer.locations[1].facId)
      or fromFacId
    shift.assignedOfferId = vehicleOffer.id
    shift.assignedOfferIds = nil
    shift.returnIsBackhaul = true
    shift.destFacId = dest and dest.facId
    shift.destPsPath = dest and dest.psPath
    shift.destLocation = dest
    shift.originLocation = vehicleOffer.spawnLocation
      or vehicleOffer.origin
      or (vehicleOffer.locations and vehicleOffer.locations[1])
      or { type = "facilityParkingspot", facId = pickupFacId }
    shift.returnPickupFacId = pickupFacId
    shift.returnNeedsPickup = true
    shift.returnLabel = string.format("Pick up return vehicle at %s", inputs.parcelLoading.describeFacilityName(pickupFacId))
    shift.returnDeliverLabel = string.format("Deliver return vehicle to %s", inputs.parcelLoading.describeFacilityName(dest and dest.facId))
    shift.returnSubtext = vehicleOffer.name or "Return vehicle"
    extendOfferExpiry(vehicleOffer, nowSim(shared))
    if pickupFacId ~= fromFacId then
      inputs.routing.routeToReturnPickup()
    end
    inputs.routing.trySpawnAssignedReturnVehicle()
    return true
  end

end

local function addReturnLoadApi(api, inputs)
  local shared = inputs.shared
  local state = inputs.state

  addVehicleBackhaulApi(api, inputs, shared, state)

  -- Clears last leg's return fields before a new return load is chosen.
  local function resetReturnFields(shift)
    shift.returnIsBackhaul = nil
    shift.assignedOfferId = nil
    shift.assignedCargoIds = {}
    shift.returnNeedsPickup = nil
    shift.returnPickupFacId = nil
    shift.returnDeliverLabel = nil
    shift._returnTrailerSpawning = nil
    shift._returnTrailerSpawned = nil
    shift._returnVehicleSpawning = nil
    shift._returnVehicleSpawned = nil
  end

  -- No return freight: the company vehicle goes back to the office.
  local function assignEmptyYardReturn(shift)
    shift.returnIsBackhaul = nil
    shift.awaitingLoopChoice = true
    shift.returnLabel = "Return the company vehicle to the office"
    shift.returnDeliverLabel = nil
    shift.returnSubtext = "No matching return freight — head back to the yard"
    shift.destFacId = shift.originFacId or state.homeFacId
    shift.destLocation = nil
    shift.destPsPath = nil
    shift.assignedOfferId = nil
    shift.returnNeedsPickup = nil
    shift.returnPickupFacId = nil
    shift._returnTrailerSpawning = nil
    shift._returnTrailerSpawned = nil
    inputs.routing.routeToYard()
    return false
  end

  local function assignParcelBackhaul(shift, parcelGroup, fromFacId)
    local now = nowSim(shared)
    for _, item in ipairs(parcelGroup.items) do
      extendOfferExpiry(item, now)
      table.insert(shift.assignedCargoIds, item.id)
    end
    shift.returnIsBackhaul = true
    shift.dropOffDepartureRequired = true
    shift.destFacId = parcelGroup.destination and parcelGroup.destination.facId
    shift.destPsPath = parcelGroup.destination and parcelGroup.destination.psPath
    shift.destLocation = parcelGroup.destination
    local pickupFacId = parcelGroup.facId
      or (parcelGroup.items[1] and parcelGroup.items[1].origin and parcelGroup.items[1].origin.facId)
      or fromFacId
    shift.originLocation = parcelGroup.items[1] and parcelGroup.items[1].origin
      or { type = "facilityParkingspot", facId = pickupFacId }
    local pickLabel, deliverLabel, subtext = inputs.parcelLoading.formatReturnParcelGuidance(
      pickupFacId, parcelGroup.destination, #shift.assignedCargoIds, fromFacId)
    shift.returnLabel = pickLabel
    shift.returnDeliverLabel = deliverLabel
    shift.returnSubtext = subtext
    shift.returnPickupFacId = pickupFacId
    if pickupFacId == fromFacId then
      inputs.parcelLoading.bindAssignedCargoToIssuedTruck()
    else
      shift.returnNeedsPickup = true
      inputs.parcelLoading.stageAssignedReturnPickup()
      inputs.routing.routeToReturnPickup()
    end
    return true
  end

  local function assignTrailerBackhaul(shift, trailerOffer, fromFacId)
    local dest = trailerOffer.destination or (trailerOffer.locations and trailerOffer.locations[2])
    shift.assignedOfferId = trailerOffer.id
    shift.returnIsBackhaul = true
    shift.destFacId = dest and dest.facId
    shift.destPsPath = dest and dest.psPath
    shift.destLocation = dest
    local pickupFacId = (trailerOffer.origin and trailerOffer.origin.facId)
      or (trailerOffer.locations and trailerOffer.locations[1] and trailerOffer.locations[1].facId)
      or fromFacId
    -- Pin the spawn pad, not the yard inspect spot.
    shift.originLocation = trailerOffer.spawnLocation
      or trailerOffer.origin
      or (trailerOffer.locations and trailerOffer.locations[1])
      or { type = "facilityParkingspot", facId = pickupFacId }
    shift.returnPickupFacId = pickupFacId
    local pickupName = inputs.parcelLoading.describeFacilityName(pickupFacId)
    local destName = inputs.parcelLoading.describeFacilityName(dest and dest.facId)
    local toOffice = dest and dest.facId == (shift.originFacId or state.homeFacId)
    shift.returnLabel = string.format("Pick up return trailer at %s", pickupName)
    shift.returnDeliverLabel = string.format("Deliver return trailer to %s", destName)
    shift.returnSubtext = toOffice
      and ((trailerOffer.name or "Return trailer") .. " · back to the office")
      or (trailerOffer.name or "Return trailer")
    extendOfferExpiry(trailerOffer, nowSim(shared))
    trailerOffer._employmentReturnTrailer = true
    shift.returnNeedsPickup = true

    if pickupFacId ~= fromFacId then
      -- Spawn only once the player is near the yard; a remote spawn often fails or vanishes.
      shift.returnNeedsPickup = true
      shift._returnTrailerSpawning = nil
      shift._returnTrailerSpawned = nil
      inputs.routing.routeToReturnPickup()
      inputs.projections.refreshTaskGuidance(true)
      inputs.projections.notifyUi()
      return true
    end

    inputs.routing.trySpawnAssignedReturnTrailer()
    return true
  end

  -- Vehicle delivery with no return car left: the shift heads back to the yard to wait.
  local function assignVehicleYardFallback(shift)
    shift.awaitingLoopChoice = true
    shift.returnLabel = "Return to the company yard"
    shift.returnSubtext = "No more deliveries available. Please check back later for more assignments"
    shift.destFacId = shift.originFacId or state.homeFacId
    shift.destLocation = nil
    shift.destPsPath = nil
    shift.returnVehicleAttemptedOfferIds = nil
    shift.returnVehicleOffersRescanned = nil
    ui_message(shift.returnSubtext, 8, "info")
    inputs.routing.routeToYard()
    inputs.projections.refreshTaskGuidance(true)
    inputs.projections.notifyUi()
    return false
  end

  local function assignVehicleReturn(shift, fromFacId)
    if not shift.returnVehicleOffersRescanned then
      local gen = shared.generator()
      if gen then gen.triggerAllGenerators() end
      shift.returnVehicleOffersRescanned = true
    end
    local vehicleOffer = inputs.dispatch.pickReturnVehicleOffer(fromFacId, shift.returnVehicleAttemptedOfferIds)
    if vehicleOffer then
      return api.assignVehicleBackhaulOffer(vehicleOffer, fromFacId)
    end
    return assignVehicleYardFallback(shift)
  end

  api.assignReturnLoad = function(fromFacId, opts)
    local shift = state.shift
    if not shift or shared.kindPolicy(shift.jobKind).materialContract or shift.wrecked then return false end
    opts = type(opts) == "table" and opts or {}
    fromFacId = fromFacId or shift.destFacId or shift.originFacId or state.homeFacId
    local policy = shared.kindPolicy(shift.jobKind)
    if policy.vehicleDelivery and not opts.retryVehicle then
      shift.returnVehicleAttemptedOfferIds = {}
      shift.returnVehicleOffersRescanned = nil
    end
    resetReturnFields(shift)
    if policy.trailerDelivery then
      local trailerOffer = inputs.dispatch.pickReturnTrailerOffer(fromFacId)
      if trailerOffer then return assignTrailerBackhaul(shift, trailerOffer, fromFacId) end
      return assignEmptyYardReturn(shift)
    end
    if policy.parcels then
      local parcelGroup = inputs.dispatch.pickReturnParcelGroup(fromFacId)
      if parcelGroup then return assignParcelBackhaul(shift, parcelGroup, fromFacId) end
      return assignEmptyYardReturn(shift)
    end
    if policy.vehicleDelivery then return assignVehicleReturn(shift, fromFacId) end
    return assignEmptyYardReturn(shift)
  end
end

-- Haul routes ------------------------------------------------------------------------------------

local function addHaulRouteApi(api, inputs)
  local shared = inputs.shared
  local state = inputs.state

  -- Home yard can't ship, so look for vehicle offers at neighbouring facilities.
  api.listVehOfferPartnerFacilities = function(excludeFacId)
    local gen = shared.generator()
    if not gen then return {} end
    local out = {}
    for _, fac in ipairs(gen.getFacilities() or {}) do
      if fac and fac.id and fac.id ~= excludeFacId and inputs.eligibility.facilityOffersKind(fac, "vehicle") then
        table.insert(out, fac)
      end
    end
    return out
  end

  local function offerReadyForHome(offer, homeFacId, mgr)
    if not (offer and offer.data and offer.data.type == "vehicle" and inputs.eligibility.vehicleOfferUnlocked(offer)) then
      return false
    end
    if offerDestFacId(offer) ~= homeFacId then
      return false
    end
    if mgr and mgr.ensureOfferSpawnReady then
      return mgr.ensureOfferSpawnReady(offer, "pickEmploymentHaulRoute") and true or false
    end
    if mgr and mgr.isOfferSpawnReady then
      return mgr.isOfferSpawnReady(offer) and true or false
    end
    return true
  end

  local function facilityHasInboundToHome(facId, homeFacId, mgr)
    if not (mgr and mgr.getAllOfferAtFacilityUnexpired and facId) then return false end
    for _, offer in ipairs(mgr.getAllOfferAtFacilityUnexpired(facId) or {}) do
      if offerReadyForHome(offer, homeFacId, mgr) then
        return true
      end
    end
    return false
  end

  local function pickNearFacility(inboundFacs, nearFacId)
    for _, fac in ipairs(inboundFacs) do
      if fac.id == nearFacId then return fac end
    end
    return nil
  end

  local function pickClosestFacility(inboundFacs, nearFacId)
    local best, bestDist
    for _, fac in ipairs(inboundFacs) do
      local dist = inputs.parcelStrings.facDistanceBetween(nearFacId, fac.id)
      if not best or dist < bestDist then
        best, bestDist = fac, dist
      end
    end
    return best
  end

  local function pickOrgFacility(inboundFacs, orgId)
    for _, fac in ipairs(inboundFacs) do
      if orgId and fac.associatedOrganization == orgId then return fac end
    end
    return inboundFacs[1]
  end

  -- Prefers the facility the player is near, then the closest, then the employer's own.
  local function chooseInboundPickup(inboundFacs, nearFacId, gen, homeFac)
    local pickupFac = nearFacId and pickNearFacility(inboundFacs, nearFacId) or nil
    if not pickupFac and nearFacId and gen and gen.getDistanceBetweenFacilities and #inboundFacs > 0 then
      pickupFac = pickClosestFacility(inboundFacs, nearFacId)
    end
    if not pickupFac and #inboundFacs > 0 then
      local orgId = state.employerOrgId or (homeFac and homeFac.associatedOrganization)
      pickupFac = pickOrgFacility(inboundFacs, orgId)
    end
    return pickupFac
  end

  -- Flatbed haul always delivers to the yard; it prefers a facility with a vehicle headed home, else a street repo.
  api.pickEmploymentHaulRoute = function(opts)
    opts = type(opts) == "table" and opts or {}
    local homeFacId = opts.homeFacId
    local gen = shared.generator()
    local mgr = shared.vehicleOffers()
    local homeFac = gen and gen.getFacilityById(homeFacId) or nil
    local inboundFacs = {}
    for _, fac in ipairs(api.listVehOfferPartnerFacilities(homeFacId)) do
      if facilityHasInboundToHome(fac.id, homeFacId, mgr) then
        table.insert(inboundFacs, fac)
      end
    end
    local pickupFac = chooseInboundPickup(inboundFacs, opts.nearFacId, gen, homeFac)
    return {
      pickupFacId = pickupFac and pickupFac.id or nil,
      pickupLabel = pickupFac and facilityLabel(inputs, pickupFac.id, pickupFac) or nil,
      deliveryFacId = homeFacId,
      deliveryLabel = facilityLabel(inputs, homeFacId, homeFac),
      mode = pickupFac and "facilityBackhaul" or "repo",
    }
  end
end

-- Repo legs --------------------------------------------------------------------------------------

local function addRepoApi(api, inputs)
  local shared = inputs.shared
  local state = inputs.state
  local RECOVERY_SKILL_ATTRIBUTE_KEY = inputs.RECOVERY_SKILL_ATTRIBUTE_KEY

  function api.getEmployerFacility()
    local facId = (state.shift and state.shift.originFacId) or state.homeFacId
    if not facId then return nil end
    local gen = shared.generator()
    if gen then
      local fac = gen.getFacilityById(facId)
      if fac then return fac end
    end
    return overhaul_world_facilities.getFacility("deliveryProvider", facId)
  end

  function api.getEmployerDeliveryContext()
    local facId = (state.shift and state.shift.originFacId) or state.homeFacId
    if not facId then return nil end
    local fac = api.getEmployerFacility()
    local label = fac and inputs.eligibility.translateUiText(fac.name, fac.id)
      or inputs.eligibility.getOrgDisplayName(inputs.eligibility.getOrg(state.employerOrgId), state.employerOrgId)
    return {
      facId = facId,
      label = label,
      fac = fac,
    }
  end

  local function completeBundleRepo(shift, gross, meta)
    if shift.assignments and shift.assignments.repo then
      shift.assignments.repo.repoPendingStart = false
    end
    settleRepoGross(inputs, shift, gross)
    if shift.assignments and shift.assignments.repo then
      shift.assignments.repo.complete = true
    end
    ui_message("Car hauling complete.", 6, "success")
    -- Mark complete before XP so attribute errors cannot leave the leg unfinished.
    payRepoSkillXp(RECOVERY_SKILL_ATTRIBUTE_KEY, meta)
    inputs.dropOff.maybeCompleteBundleShift({ atYard = true })
    inputs.projections.notifyUi()
  end

  local function completeOutboundRepo(shift, gross, meta)
    shift.repoPendingStart = nil
    settleRepoGross(inputs, shift, gross)
    payRepoSkillXp(RECOVERY_SKILL_ATTRIBUTE_KEY, meta)
    if meta and meta.vehicleLabel then
      shift.outboundLabel = "Haul the " .. meta.vehicleLabel .. " back to the yard"
      shift.outboundSubtext = "Company rollback"
    end
    ui_message("Car hauling complete.", 6, "success")
    inputs.dropOff.afterOutboundDelivered()
  end

  function api.handleEmploymentRepoComplete(gross, meta)
    local shift = state.shift
    if not shift then return end
    gross = tonumber(gross) or 0
    if inputs.dropOff.isBundleShift(shift) then
      completeBundleRepo(shift, gross, meta)
      return
    end
    if not shared.kindPolicy(shift.jobKind).repossession then return end
    completeOutboundRepo(shift, gross, meta)
  end

  -- Labels the outbound leg for the route the haul will take.
  local function setRepoOutboundLabel(shift, route)
    if route.pickupLabel then
      shift.outboundLabel = string.format("Pickup at %s — haul back to the yard", route.pickupLabel)
    else
      shift.outboundLabel = "Pickup — haul a vehicle back to the yard"
    end
    shift.outboundSubtext = "Company rollback"
  end

  function api.tryStartEmploymentRepo()
    local shift = state.shift
    if not shift or not inputs.lifecycle.isOnShift() then return false end
    if inputs.dropOff.isBundleShift(shift) then return false end
    if not shared.kindPolicy(shift.jobKind).repossession then
      return false
    end
    local repo = shared.repoJob()
    if repo and repo.isEmploymentRepoActive() then
      shift.repoPendingStart = false
      return true
    end
    if not shift.repoPendingStart then
      return false
    end
    if not inputs.equipment.playerInIssuedCompanyTruck() then
      return false
    end
    if not repo or not repo.startEmploymentJob then
      inputs.routing.handleAssignmentStartFailure("Company pickup service is unavailable.")
      return false
    end
    local delivery = api.getEmployerDeliveryContext()
    local nearFacId = shift.destFacId
    local homeFacId = (delivery and delivery.facId) or shift.originFacId or state.homeFacId
    local route = api.pickEmploymentHaulRoute({
      homeFacId = homeFacId,
      nearFacId = nearFacId,
    })
    local deliveryFacId = route.deliveryFacId or homeFacId
    local deliveryLabel = route.deliveryLabel
      or (delivery and delivery.label)
      or inputs.eligibility.getOrgDisplayName(inputs.eligibility.getOrg(state.employerOrgId), state.employerOrgId)
    setRepoOutboundLabel(shift, route)
    local isCurrent = inputs.projections.makeAssignmentGuard()
    local started = repo.startEmploymentJob(api.handleEmploymentRepoComplete, function(reason, generationFailed)
      if not isCurrent() then return end
      if generationFailed then
        inputs.routing.handleAssignmentStartFailure(reason or "Company pickup could not be created.")
        return
      end
      shift.repoPendingStart = true
      if reason and reason ~= "" then
        ui_message(tostring(reason), 6, "warning")
      end
      inputs.projections.refreshTaskGuidance(true)
      inputs.projections.notifyUi()
    end, {
      homeFacId = deliveryFacId,
      deliveryLabel = deliveryLabel,
      pickupFacId = route.pickupFacId,
      pickupLabel = route.pickupLabel,
    })
    if started then
      shift.repoPendingStart = false
      inputs.projections.refreshTaskGuidance(true)
    end
    return started
  end

  api.rearmMissingEmploymentRepo = function()
    local shift = state.shift
    if not shift or not inputs.lifecycle.isOnShift() then return false end
    if inputs.dropOff.isBundleShift(shift) then
      if not inputs.dropOff.isBundleHaulBackhaulPending(shift) then return false end
      if shift.returnNeedsPickup and shift.assignedOfferId then
        return inputs.routing.trySpawnAssignedReturnVehicle() and true or false
      end
      if shift.returnIsBackhaul and shift.assignedOfferId then
        return false
      end
      inputs.routing.beginBundleRepoLeg()
      return true
    end
    if not shared.kindPolicy(shift.jobKind).repossession or shift.phase ~= "outbound" or shift.repoPendingStart then
      return false
    end
    local repo = shared.repoJob()
    if not repo
        or repo.isEmploymentRepoActive()
        or repo.isEmploymentRepoCompleting() then
      return false
    end
    shift.repoPendingStart = true
    inputs.projections.refreshTaskGuidance(true)
    inputs.projections.notifyUi()
    return true
  end
end

-- Parcel strings and dispatch fallback -----------------------------------------------------------

local function addParcelDispatchApi(api, inputs)
  local shared = inputs.shared
  local state = inputs.state
  local runtime = inputs.runtime

  api.forceTriggerParcelGeneratorsAtFacility = function(facId)
    local gen = shared.generator()
    local fac = gen and gen.getFacilityById(facId)
    if not (gen and fac and gen.triggerGenerator) then return end
    for _, generator in ipairs(fac.logisticGenerators or {}) do
      if generator.type == "parcelProvider" or generator.type == "parcelReceiver" then
        gen.triggerGenerator(fac, generator)
      end
    end
  end

  api.ensureParcelGroupsAtFacility = function(facId)
    local groups = inputs.dispatch.collectParcelGroups(facId, false)
    if groups[1] then return groups end
    for _ = 1, 6 do
      api.forceTriggerParcelGeneratorsAtFacility(facId)
      groups = inputs.dispatch.collectParcelGroups(facId, false)
      if groups[1] then return groups end
    end
    return groups
  end

  api.parcelStringContext = function()
    return {
      services = {
        generator = shared.generator,
        loanerCapabilities = shared.loanerCapabilities,
        parcelManager = shared.parcelManager,
      },
      prepare = {
        parcelGroups = api.ensureParcelGroupsAtFacility,
        cargoHasTimedModifier = inputs.dropOff.cargoHasTimedModifier,
        deliveryLevel = inputs.eligibility.getDeliveryLevel,
      },
      labels = {
        facility = inputs.parcelLoading.describeFacilityName,
        destination = inputs.parcelLoading.describeDest,
      },
    }
  end

  -- All issuable jobs at this yard right now (same pool chooseJob weights from).
  function api.chooseJob(facId)
    local fac = shared.generator() and shared.generator().getFacilityById(facId)
    local namedKind = fac and shared.kindDefinition(fac.roleplayType)
    if namedKind and namedKind.policy.roleplay and namedKind.handlers and namedKind.handlers.buildAssignment then
      local offer = inputs.eligibility.discoveredOffer(facId, fac, namedKind.id)
      if offer and offer.available then return shared.kindAssignmentResolver(namedKind.id)(facId) end
    end
    local job, reason = inputs.dispatch.chooseJob(facId)
    if job then return job end
    for _, offer in ipairs(inputs.eligibility.discoveredMarketOffers(facId, fac)) do
      if offer.available then
        local resolve = shared.kindAssignmentResolver(offer.id)
        local assignment, failure = resolve(facId)
        if assignment then return assignment end
        reason = failure or reason
      end
    end
    return nil, reason
  end

  api.retryFailedAssignment = function(failedShift)
    if not failedShift or failedShift.spawnFallbackAttempted then return false end
    local facId = failedShift.originFacId or state.homeFacId
    if not facId or not state.employerOrgId then return false end
    local options = inputs.dispatch.buildJobOptions(facId) or {}
    local alternatives = {}
    local carJockeyKinds = { vehicle = true, repo = true, vehicle_repo_bundle = true }
    for _, option in ipairs(options) do
      if option.kind ~= failedShift.jobKind
          and not (carJockeyKinds[failedShift.jobKind] and carJockeyKinds[option.kind]) then
        alternatives[#alternatives + 1] = option
      end
    end
    if not alternatives[1] then return false end
    local job = inputs.dispatch.chooseWeightedJobOption(alternatives)
    job.spawnFallbackAttempted = true
    local employerOrgId = state.employerOrgId
    local transition = runtime.nextAssignmentTransition
    local function retry()
      if transition and runtime.nextAssignmentTransition ~= transition then return end
      if state.shift or state.employerOrgId ~= employerOrgId then return end
      inputs.assignment.assignmentMessage("Assignment unavailable. Dispatch is trying a different job type.", 8, "info")
      local ok = inputs.assignment.beginAssignmentWithGuidance(facId, job)
      if ok then
        inputs.persistence.saveEmploymentProgress()
      end
    end
    -- Finish the failed spawn sequence before starting replacement equipment.
    core_jobsystem.create(function(spawnJob)
      spawnJob.sleep(0)
      retry()
    end)
    return true
  end
end

-- Constructor ------------------------------------------------------------------------------------

function part.new(inputs)
  local api = inputs.api or {}
  addReturnLoadApi(api, inputs)
  addHaulRouteApi(api, inputs)
  addRepoApi(api, inputs)
  addParcelDispatchApi(api, inputs)
  return api
end

return part
