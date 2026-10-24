-- Employment listings, applications, hires and headhunter offers.
-- Reading order: headhunter search, eligibility, listings, applications, hiring and construction.
local part = {}

-- Headhunter milestones -------------------------------------------------------------------------

local function headhunterMilestones()
  return {
    { id = "fluids", level = 19, flag = "logisticsFluidDelivery", cargoType = "fluid", label = "fluid delivery" },
    { id = "aggregates", level = 16, flag = "logisticsAggregateDelivery", cargoType = "dryBulk", label = "aggregate delivery" },
    { id = "cement", level = 11, flag = "logisticsCementDelivery", cargoType = "cement", label = "cement delivery" },
  }
end

local function milestoneForPending(runtime, pending)
  for _, candidate in ipairs(runtime.HEADHUNTER_MILESTONES) do
    if candidate.id == pending.id then return candidate end
  end
  return nil
end

-- Headhunter search -----------------------------------------------------------------------------

local function addHeadhunterSearchApi(api, inputs)
  local eligibility, persistence, shared, state = inputs.eligibility, inputs.persistence, inputs.shared, inputs.state

  api.facilityHasMilestoneCargo = function(facility, wantedCargoType)
    if not facility or not wantedCargoType then return false end
    if eligibility.facilitySupportsMaterialType(facility, wantedCargoType) then return true end
    local materialsManager = shared.materials()
    if not materialsManager then return false end
    for _, offer in ipairs(materialsManager.getOffersForFacility(facility.id, "employment") or {}) do
      local materialType = offer.materialType or (offer.material and offer.material.type)
      local bulkType = eligibility.resolveMaterialBulkType(materialType) or materialType
      if bulkType == wantedCargoType then return true end
    end
    return false
  end

  api.findHeadhunterListing = function(milestone)
    local generator = eligibility.ensureDeliveryGenerator()
    if not generator then return nil end
    local wantedCargoType = milestone and milestone.cargoType
    if not wantedCargoType then return nil end
    local loanerCapabilities = shared.loanerCapabilities()
    local organizations = overhaul_world_organizations.getOrganizations()
    if type(organizations) ~= "table" then return nil end
    local matchingListings = {}
    local scannedFacilityCount, supportedCargoFacilityCount, employableFacilityCount = 0, 0, 0
    for orgId, organization in pairs(organizations) do
      if orgId ~= state.employerOrgId and persistence.canRehireOrg(orgId) then
        local facilities = generator.getFacilitiesForOrganizationId(orgId) or {}
        for _, facility in ipairs(facilities) do
          scannedFacilityCount = scannedFacilityCount + 1
          if api.facilityHasMilestoneCargo(facility, wantedCargoType) then
            supportedCargoFacilityCount = supportedCargoFacilityCount + 1
            local canIssueLoaners = loanerCapabilities and loanerCapabilities.canIssueLoanersForFacility(facility, "materials", { cargoType = wantedCargoType })
            local canEmploy, profile = eligibility.canEmployAt(orgId, facility.id, organization)
            if canIssueLoaners and canEmploy and not eligibility.isRoleplayProfile(profile) then
              employableFacilityCount = employableFacilityCount + 1
              local kinds = eligibility.getAssignableKinds(facility.id)
              table.insert(matchingListings, {
                orgId = orgId,
                orgName = eligibility.getOrgDisplayName(organization, orgId),
                facId = facility.id,
                facName = eligibility.translateUiText(facility.name, facility.id),
                preview = api.facilityPreview(facility),
                workSummary = eligibility.workSummaryForProfile(profile, kinds, facility),
                employerProfile = profile,
                matchedType = true,
              })
            end
          end
        end
      end
    end
    shared.shiftLog("headhunter scan", string.format("%s scanned=%d support=%d employable=%d hits=%d",
      tostring(wantedCargoType), scannedFacilityCount, supportedCargoFacilityCount, employableFacilityCount, #matchingListings))
    if not matchingListings[1] then return nil end
    table.sort(matchingListings, function(a, b)
      return tostring(a.orgName) < tostring(b.orgName)
    end)
    return matchingListings[1]
  end

  api.pendingHeadhunterMatchesMilestone = function(pending, milestone)
    if not (pending and milestone and milestone.cargoType) then return false end
    if pending.id ~= milestone.id then return false end
    local generator = shared.generator()
    local facility = generator and generator.getFacilityById(pending.facId)
    return facility and api.facilityHasMilestoneCargo(facility, milestone.cargoType) or false
  end
end

-- Headhunter offers -----------------------------------------------------------------------------

local function prepareHeadhunterState(inputs)
  local projections, state = inputs.projections, inputs.state
  state.headhunter = state.headhunter or { offered = {}, pending = nil }
  state.headhunter.offered = state.headhunter.offered or {}
  if (tonumber(state.headhunter.offerVersion) or 0) < 4 then
    state.headhunter.offered = {}
    state.headhunter.pending = nil
    state.headhunter.nextCheckAt = 0
    state.headhunter.offerVersion = 4
    projections.notifyUi()
  end
end

local function recheckWhenContextChanges(inputs, level, mapId)
  local runtime, state = inputs.runtime, inputs.state
  if not runtime.headhunterCheckContext or runtime.headhunterCheckMap ~= mapId
      or runtime.headhunterCheckEmployer ~= state.employerOrgId or runtime.headhunterCheckLevel ~= level then
    runtime.headhunterCheckContext = true
    runtime.headhunterCheckMap = mapId
    runtime.headhunterCheckEmployer = state.employerOrgId
    runtime.headhunterCheckLevel = level
    state.headhunter.nextCheckAt = 0
  end
end

-- True while a still-valid pending offer exists; a mismatched one is cleared.
local function pendingOfferStillValid(api, inputs)
  local projections, runtime, shared, state = inputs.projections, inputs.runtime, inputs.shared, inputs.state
  local pending = state.headhunter.pending
  if not pending then return false end
  local milestone = milestoneForPending(runtime, pending)
  if milestone and not api.pendingHeadhunterMatchesMilestone(pending, milestone) then
    shared.shiftLog("headhunter", string.format("clearing mismatched pending %s at %s",
      tostring(pending.id), tostring(pending.facId)))
    state.headhunter.pending = nil
    projections.notifyUi()
    return false
  end
  return true
end

local function announceHeadhunterOffer(inputs, milestone, listing)
  local projections, shared, state = inputs.projections, inputs.shared, inputs.state
  state.headhunter.pending = {
    id = milestone.id,
    level = milestone.level,
    label = milestone.label,
    orgId = listing.orgId,
    facId = listing.facId,
    orgName = listing.orgName,
    facName = listing.facName,
    preview = listing.preview,
    workSummary = listing.workSummary,
  }
  if overhaul_phone_apps_layout then
    overhaul_phone_apps_layout.ensureDefaultAppsPlaced()
  end
  projections.firePhoneNotification(
    "employment.headhunter",
    "New career path",
    string.format("Logistics L%d unlocked %s. %s is hiring — open Employment to switch.",
      milestone.level, milestone.label, listing.facName or listing.orgName),
    "invite",
    nil,
    { ttl = 20 }
  )
  shared.shiftLog("headhunter", string.format("offered %s -> %s (%s)",
    tostring(milestone.id), tostring(listing.orgId), tostring(listing.facId)))
  projections.notifyUi()
end

-- True once an offer was made, which ends this check.
local function offerFirstAvailableMilestone(api, inputs, level)
  local runtime, shared, state = inputs.runtime, inputs.shared, inputs.state
  for _, milestone in ipairs(runtime.HEADHUNTER_MILESTONES) do
    if level >= milestone.level and not state.headhunter.offered[milestone.id] then
      local listing = api.findHeadhunterListing(milestone)
      if listing then
        announceHeadhunterOffer(inputs, milestone, listing)
        return true
      end
      shared.shiftLog("headhunter", string.format("no listing for milestone %s at L%d",
        tostring(milestone.id), level))
    end
  end
  return false
end

local function addHeadhunterOfferApi(api, inputs)
  local eligibility, lifecycle, shared, state = inputs.eligibility, inputs.lifecycle, inputs.shared, inputs.state

  api.maybeOfferHeadhunter = function()
    if not eligibility.isEmploymentUnlocked() or not lifecycle.isEmployed() then return end
    if lifecycle.isOnShift() then return end
    prepareHeadhunterState(inputs)
    local now = shared.nowSim()
    local level = eligibility.getDeliveryLevel()
    recheckWhenContextChanges(inputs, level, shared.currentMapId())
    if (tonumber(state.headhunter.nextCheckAt) or 0) > now then return end
    state.headhunter.nextCheckAt = now + 30
    if pendingOfferStillValid(api, inputs) then return end
    if offerFirstAvailableMilestone(api, inputs, level) then return end
    state.headhunter.nextCheckAt = now + 300
  end
end

-- Offered listings ------------------------------------------------------------------------------

local function addOfferedListingsApi(api, inputs)
  local config, projections, shared, state = inputs.config, inputs.projections, inputs.shared, inputs.state

  api.clearOfferedListings = function()
    state.offeredFacIds = {}
    state.offeredListingsAt = nil
  end

  api.shuffleInPlace = function(t)
    for i = #t, 2, -1 do
      local j = math.random(i)
      t[i], t[j] = t[j], t[i]
    end
    return t
  end

  api.listingOfferKey = function(listing)
    if not listing then return nil end
    return listing.facId or listing.orgId
  end

  -- Keep still-valid cached yards, then fill remaining slots from a shuffled pool.
  api.selectOfferedListings = function(allListings, count, preferIds, forceRefresh)
    count = count or config.LISTING_OFFER_COUNT
    if type(allListings) ~= "table" or #allListings == 0 then
      return {}
    end
    if #allListings <= count then
      return allListings
    end
    local listingsByKey = {}
    for _, listing in ipairs(allListings) do
      local key = api.listingOfferKey(listing)
      if key then
        listingsByKey[key] = listing
      end
    end
    local selectedListings, selectedKeys = {}, {}
    if not forceRefresh and type(preferIds) == "table" then
      for _, id in ipairs(preferIds) do
        local listing = listingsByKey[id]
        local key = api.listingOfferKey(listing)
        if listing and key and not selectedKeys[key] and #selectedListings < count then
          table.insert(selectedListings, listing)
          selectedKeys[key] = true
        end
      end
    end
    local remainingListings = {}
    for _, listing in ipairs(allListings) do
      local key = api.listingOfferKey(listing)
      if key and not selectedKeys[key] then
        table.insert(remainingListings, listing)
      end
    end
    api.shuffleInPlace(remainingListings)
    for _, listing in ipairs(remainingListings) do
      if #selectedListings >= count then break end
      local key = api.listingOfferKey(listing)
      table.insert(selectedListings, listing)
      if key then selectedKeys[key] = true end
    end
    table.sort(selectedListings, function(a, b)
      if tostring(a.orgName) == tostring(b.orgName) then
        return tostring(a.facName) < tostring(b.facName)
      end
      return tostring(a.orgName) < tostring(b.orgName)
    end)
    return selectedListings
  end

  function api.rollJobListings()
    if not shared.isDevToolsEnabled() then
      log("W", "employment", "rollJobListings blocked: no valid dev key")
      return { ok = false, message = "Dev key required." }
    end
    api.clearOfferedListings()
    local ui = projections.getUiState()
    ui.rollOk = true
    return ui
  end
end

-- Applying for a job ----------------------------------------------------------------------------

local function applicationTarget(orgIdOrListing, facId)
  local orgId, resolvedFacId = orgIdOrListing, facId
  if type(orgIdOrListing) == "table" then
    orgId = orgIdOrListing.orgId
    resolvedFacId = orgIdOrListing.facId
  end
  orgId = orgId ~= nil and tostring(orgId) or nil
  resolvedFacId = resolvedFacId ~= nil and tostring(resolvedFacId) or nil
  return orgId, resolvedFacId
end

local function addApplicationApi(api, inputs)
  local eligibility, lifecycle, shared, state = inputs.eligibility, inputs.lifecycle, inputs.shared, inputs.state

  local function failApplication(orgId, facId, reason)
    reason = tostring(reason or "Application failed.")
    shared.shiftLog("applyForJob fail", string.format("orgId=%s facId=%s :: %s", tostring(orgId), tostring(facId), reason))
    ui_message(reason, 8, "warning")
    inputs.projections.firePhoneNotification("employment.applyFailed", "Application failed", reason, "warning")
    inputs.projections.notifyUi()
    return { ok = false, reason = reason, orgId = orgId, facId = facId }
  end

  -- Falls back to the organization's first classifiable yard when the asked-for one has no profile.
  local function locateApplicantFacility(orgId, facId, organization)
    local facility = shared.generator() and shared.generator().getFacilityById(facId)
    local profile = facility and eligibility.classifyEmployer(organization, facility) or nil
    if not profile and shared.generator() then
      for _, candidate in ipairs(shared.generator().getFacilitiesForOrganizationId(orgId) or {}) do
        profile = eligibility.classifyEmployer(organization, candidate)
        if profile then
          facId = candidate.id
          facility = candidate
          break
        end
      end
    end
    return facId, facility, profile
  end

  local function applicationBlockReason(orgId, facId, endCurrentEmployment, profile)
    if eligibility.isRoleplayProfile(profile) then
      return "No application needed — clock in at the station when you're ready."
    end
    if lifecycle.isOnShift() or (state.shift and state.shift.paused) then
      return "Finish your current shift before applying for another job."
    end
    if lifecycle.isEmployed() and state.employerOrgId == orgId and state.homeFacId == facId then
      return "You already work at this yard."
    end
    if lifecycle.isEmployed() and endCurrentEmployment ~= true then
      return "Confirm ending your current employment before applying elsewhere."
    end
    if not inputs.persistence.canRehireOrg(orgId) then
      local days = shared.simDaysRemaining(inputs.persistence.getRehireBlockUntil(orgId))
      return string.format("You cannot reapply to this company for %d more sim day%s.", days, days == 1 and "" or "s")
    end
    if state.pendingApplications[1] then
      return "You already have an application pending."
    end
    return nil
  end

  local function firstEmployableFacility(orgId, organization)
    local facilities = shared.generator() and shared.generator().getFacilitiesForOrganizationId(orgId) or {}
    for _, candidate in ipairs(facilities) do
      if eligibility.canEmployAt(orgId, candidate.id, organization) then
        return candidate.id, candidate
      end
    end
    return nil, nil
  end

  local function noWorkReason(facId, facility, workProfile, profile)
    local gate = facId and eligibility.getListingSkillGate(facId, workProfile or profile) or nil
    if gate and gate.skillMessage then
      return gate.skillMessage
    end
    local kinds = facId and eligibility.getAssignableKinds(facId) or {}
    local kindBits = {}
    for k, v in pairs(kinds) do
      if v then table.insert(kindBits, k) end
    end
    return string.format(
      "Yard '%s' has no issuable work yet (profile=%s kinds=%s). Fac assoc=%s.",
      tostring(facId),
      tostring(workProfile or profile),
      (#kindBits > 0 and table.concat(kindBits, ",") or "none"),
      tostring(facility and facility.associatedOrganization)
    )
  end

  local function employmentRefusalReason(orgId, facId, facility, organization, profile)
    local canEmploy, workProfile = eligibility.canEmployAt(orgId, facId, organization)
    if not facId or not canEmploy then
      return noWorkReason(facId, facility, workProfile, profile)
    end
    local gate = eligibility.getListingSkillGate(facId, workProfile or profile)
    if gate and gate.skillLocked and gate.skillMessage then
      return gate.skillMessage
    end
    return nil
  end

  local function submitApplication(orgId, facId)
    if lifecycle.isEmployed() then
      inputs.endDay.quitJob({ silent = true })
    end
    if not state.activeMapId or state.activeMapId == "" then
      state.activeMapId = shared.currentMapId()
    end
    table.insert(state.pendingApplications, {
      orgId = orgId,
      facId = facId,
      appliedAt = shared.nowSim(),
      hireAt = shared.nowSim() + (shared.isDevToolsEnabled() and inputs.config.HIRE_DELAY_SIM or inputs.config.HIRE_DELAY_SIM_RELEASE),
    })
    inputs.persistence.flushEmploymentCache()
    local businessName = eligibility.getBusinessDisplayName(facId, orgId)
    ui_message(string.format("Application sent to %s. You'll get a notification if you're hired.", businessName), 7, "info")
    shared.shiftLog("applyForJob ok", string.format("%s pending fac=%s", businessName, tostring(facId)))
    inputs.projections.notifyUi()
    return { ok = true, orgId = orgId, facId = facId, name = businessName }
  end

  function api.applyForJob(orgIdOrListing, facId, endCurrentEmployment)
    local orgId
    orgId, facId = applicationTarget(orgIdOrListing, facId)
    local function fail(reason) return failApplication(orgId, facId, reason) end

    shared.shiftLog("applyForJob", string.format("orgId=%s facId=%s", tostring(orgId), tostring(facId)))
    if overhaul_career_logistics_broker.hasObligations() then
      return fail('Finish or cancel Broker work and return rentals before applying for employment.')
    end
    inputs.persistence.ensureRehireSaveV3()
    eligibility.syncUnlockFlagsForDeliveryLevel()
    if not eligibility.isEmploymentUnlocked() then
      return fail("Company employment is not enabled for this career.")
    end
    local organization = eligibility.getOrg(orgId)
    if not organization then
      return fail(string.format("Company id '%s' is not loaded.", tostring(orgId)))
    end

    local facility, profile
    facId, facility, profile = locateApplicantFacility(orgId, facId, organization)
    local blockReason = applicationBlockReason(orgId, facId, endCurrentEmployment, profile)
    if blockReason then return fail(blockReason) end

    if not facility or facility.associatedOrganization ~= orgId then
      facId, facility = firstEmployableFacility(orgId, organization)
    end
    local refusalReason = employmentRefusalReason(orgId, facId, facility, organization, profile)
    if refusalReason then return fail(refusalReason) end
    return submitApplication(orgId, facId)
  end
end

-- Hiring and headhunter placement ---------------------------------------------------------------

local function addHireApi(api, inputs)
  local eligibility, projections, routing, state = inputs.eligibility, inputs.projections, inputs.routing, inputs.state

  function api.completeHire(application)
    local broker = overhaul_career_logistics_broker
    if broker and broker.hasObligations() then
      state.pendingApplications = {}
      ui_message('Finish or cancel Broker work and return rentals before accepting employment.', 8, 'warning')
      projections.notifyUi()
      return false
    end
    state.employerOrgId = application.orgId
    state.homeFacId = application.facId
    state.hiredAt = inputs.shared.nowSim()
    state.lastWorkAt = state.hiredAt
    state.hiredWorldMinute = inputs.shared.nowWorldMinutes()
    state.lastWorkWorldMinute = state.hiredWorldMinute
    state.pendingApplications = {}
    state.ignoreCompanyDamageStrikes = nil
    inputs.settlement.resetEscrow()
    inputs.settlement.resetDamageStrikes()
    inputs.persistence.flushEmploymentCache()
    api.clearOfferedListings()
    local businessName = eligibility.getBusinessDisplayName(application.facId, application.orgId)
    local title = application.headhunter and "Headhunter placement" or "You're hired"
    local message = application.headhunter
      and string.format("You're now at %s — report to the yard for %s work.", businessName, application.milestoneLabel or "company")
      or string.format("You've been hired at %s. Report to the office for your first assignment.", businessName)
    projections.firePhoneNotification(
      application.headhunter and "employment.headhunter" or "employment.hired",
      title,
      message,
      "success"
    )
    projections.notifyUi()
    if application.headhunter then
      routing.routeToYard()
    else
      routing.refreshDeliveryPois()
    end
  end

  function api.acceptHeadhunterOffer()
    local broker = overhaul_career_logistics_broker
    if broker and broker.hasObligations() then
      ui_message('Finish or cancel Broker work and return rentals before accepting employment.', 8, 'warning')
      return false
    end
    local offer = state.headhunter and state.headhunter.pending
    if not offer then return false end
    if not eligibility.isEmploymentUnlocked() then return false end
    if inputs.lifecycle.isOnShift() or (state.shift and state.shift.paused) then
      ui_message("End your shift before switching employers.", 6, "warning")
      return false
    end
    local orgId, facId = offer.orgId, offer.facId
    local milestoneLabel = offer.label
    local milestoneId = offer.id
    state.headhunter.pending = nil
    if milestoneId then
      state.headhunter.offered = state.headhunter.offered or {}
      state.headhunter.offered[milestoneId] = true
    end
    inputs.endDay.quitJob({ silent = true })
    api.completeHire({
      orgId = orgId,
      facId = facId,
      headhunter = true,
      milestoneLabel = milestoneLabel,
    })
    ui_message(string.format("Switched employers for %s work.", milestoneLabel or "company"), 7, "success")
    return true
  end

  function api.dismissHeadhunterOffer()
    if not (state.headhunter and state.headhunter.pending) then return false end
    local pending = state.headhunter.pending
    local milestone = milestoneForPending(inputs.runtime, pending)
    state.headhunter.pending = nil
    -- Only consume the milestone when the yard actually offered that logistic.
    if milestone and api.pendingHeadhunterMatchesMilestone(pending, milestone) then
      state.headhunter.offered = state.headhunter.offered or {}
      state.headhunter.offered[pending.id] = true
    end
    projections.notifyUi()
    return true
  end
end

-- Listings --------------------------------------------------------------------------------------

-- True in the second result when the map is ready and the listings are complete.
local function collectEmployableListings(api, inputs)
  local eligibility, shared = inputs.eligibility, inputs.shared
  local listings = {}
  eligibility.syncUnlockFlagsForDeliveryLevel()
  if not eligibility.isEmploymentUnlocked() then
    return listings, false
  end
  local generator = eligibility.ensureDeliveryGenerator()
  shared.loanerCapabilities()
  if not generator then
    return listings, false
  end
  local general = shared.general()
  if general then
    general.ensureSetupForCurrentMap()
  end
  if generator.getSetupLevelIdentifier() ~= shared.currentMapId() then
    return listings, false
  end
  local organizations = overhaul_world_organizations.getOrganizations()
  if type(organizations) ~= "table" then
    return listings, false
  end
  for orgId, organization in pairs(organizations) do
    local facilities = generator.getFacilitiesForOrganizationId(orgId) or {}
    for _, facility in ipairs(facilities) do
      local canEmploy, profile = eligibility.canEmployAt(orgId, facility.id, organization)
      if profile and not eligibility.isRoleplayProfile(profile) then
        table.insert(listings, api.buildEmploymentListing(orgId, organization, facility, profile, canEmploy))
      end
    end
  end
  table.sort(listings, function(a, b)
    if (not a.skillLocked) ~= (not b.skillLocked) then
      return not a.skillLocked
    end
    return tostring(a.facName) < tostring(b.facName)
  end)
  return listings, true
end

local function addListingApi(api, inputs)
  local config, eligibility, persistence, shared, state = inputs.config, inputs.eligibility, inputs.persistence, inputs.shared, inputs.state

  api.facilityPreview = function(facility)
    if type(facility) == "table" and facility.preview then return facility.preview end
    local facId = type(facility) == "table" and facility.id or facility
    local generator = overhaul_career_logistics_generator
    local loadedFacility = facId and generator and generator.getFacilityById(facId)
    return loadedFacility and loadedFacility.preview or nil
  end

  api.buildEmploymentListing = function(orgId, organization, facility, profile, canEmploy)
    local kinds = eligibility.getAssignableKinds(facility.id)
    local gate = eligibility.getListingSkillGate(facility.id, profile)
    local skillLocked = (not canEmploy) or (gate and gate.skillLocked) or false
    local offerings = eligibility.buildFacilityOfferings(facility.id, profile, kinds)
    return eligibility.uiLibrary().formatListing({
      orgId = orgId,
      orgName = eligibility.getOrgDisplayName(organization, orgId),
      facId = facility.id,
      facName = eligibility.translateUiText(facility.name, facility.id),
      offerings = offerings,
      employerProfile = profile,
      rehireBlocked = not persistence.canRehireOrg(orgId),
      rehireDaysRemaining = shared.simDaysRemaining(persistence.getRehireBlockUntil(orgId)),
      skillLocked = skillLocked,
      preview = api.facilityPreview(facility),
      requiredLevel = gate and gate.requiredLevel or nil,
      skillMessage = gate and gate.skillMessage or nil,
    })
  end

  function api.getListings()
    local listings, ready = collectEmployableListings(api, inputs)
    if not ready then return listings end

    local now = shared.nowSim()
    local forceRefresh = false
    if not state.offeredFacIds or not state.offeredFacIds[1] then
      forceRefresh = true
    elseif state.offeredListingsAt and (now - (tonumber(state.offeredListingsAt) or 0)) >= config.LISTING_REFRESH_SIM then
      forceRefresh = true
    end
    local shownListings = api.selectOfferedListings(listings, config.LISTING_OFFER_COUNT, state.offeredFacIds, forceRefresh)
    state.offeredFacIds = {}
    for _, listing in ipairs(shownListings) do
      table.insert(state.offeredFacIds, listing.facId or listing.orgId)
    end
    if forceRefresh or not state.offeredListingsAt then
      state.offeredListingsAt = now
    end
    return shownListings
  end
end

-- Constructor -----------------------------------------------------------------------------------

function part.new(inputs)
  local api = inputs.api or {}
  inputs.runtime.HEADHUNTER_MILESTONES = headhunterMilestones()
  addHeadhunterSearchApi(api, inputs)
  addHeadhunterOfferApi(api, inputs)
  addOfferedListingsApi(api, inputs)
  addApplicationApi(api, inputs)
  addHireApi(api, inputs)
  addListingApi(api, inputs)
  return api
end

return part
