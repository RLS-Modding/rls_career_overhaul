-- Employment phone, screen and task-guidance projections built from career state.
-- Reading order: notices, task guidance, screen actions, assignment cards, UI state.
local part = {}

local DEFAULT_COMPANY_SHARE = 0.5
local ROLEPLAY_OPEN_DELAY_S = 0.2
local DROP_OFFER_SETTLE_TIMEOUT_S = 10

-- Shared helpers ----------------------------------------------------------------------------------

local function companyShareForLevel(level)
  local share = DEFAULT_COMPANY_SHARE
  if level ~= nil and overhaul_career_progression_reputation then
    share = tonumber(overhaul_career_progression_reputation.getCompanyShareValue(level)) or share
  end
  return share
end

local function employerPreviewFor(displayFacId)
  local generator = overhaul_career_logistics_generator
  local fac = displayFacId and generator and generator.getFacilityById(displayFacId)
  return fac and fac.preview or nil
end

local function canClockInHere(inputs, employment, facId, viewProfile)
  if inputs.eligibility.isRoleplayProfile(viewProfile) then
    if employment.blocksRoleplay and employment.blocksRoleplay() then return false end
    return true
  end
  return inputs.dropOff.facilityMatchesEmployer(facId) and true or false
end

local function pendingView(inputs, pending)
  if not pending then return nil end
  return {orgId = pending.orgId,
    orgName = inputs.eligibility.getBusinessDisplayName(pending.facId, pending.orgId), facId = pending.facId,
    facName = inputs.eligibility.getBusinessDisplayName(pending.facId, pending.orgId)}
end


-- Notices and tasklist ----------------------------------------------------------------------------

local function addGuidanceApi(api, inputs)
  local shared = inputs.shared
  local state = inputs.state
  local runtime = inputs.runtime
  local M = inputs.M

  api.getCompanyShare = function()
    local orgId = inputs.eligibility.getActiveShiftOrgId()
    local org = inputs.eligibility.getOrg(orgId)
    local level = inputs.eligibility.getRepLevel(org)
    if overhaul_career_progression_reputation then
      return overhaul_career_progression_reputation.getCompanyShareValue(level)
    end
    return DEFAULT_COMPANY_SHARE
  end

  api.notifyUi = function()
    guihooks.trigger("employmentUpdated")
  end

  api.firePhoneNotification = function(channelKey, title, message, kind, extra, opts)
    if runtime.nextAssignmentTransition and (channelKey == "employment.shiftStarted" or channelKey == "employment.stringReady") then return end
    inputs.eligibility.uiLibrary().firePhoneNotification(channelKey, title, message, kind, extra, opts)
  end

  -- Employment is preinstalled from career start, so there is no unlock notification.
  api.maybeNotifyEmploymentUnlock = function() end

  api.getEmployerTasklistHeader = function()
    local facId = (state.shift and state.shift.originFacId) or state.homeFacId
    local fac = shared.generator() and shared.generator().getFacilityById(facId)
    local org = inputs.eligibility.getOrg(state.employerOrgId)
    return inputs.eligibility.uiLibrary().employerTasklistHeader({
      facName = fac and type(fac.name) == "string" and fac.name ~= "" and fac.name or nil,
      orgName = org and org.name,
      orgId = state.employerOrgId,
    })
  end

  api.clearTaskGuidance = function()
    inputs.eligibility.uiLibrary().clearTaskGuidance(guihooks)
  end

  api.purgeIndependentTasklist = function()
    local tasklist = overhaul_career_logistics_tasklist
    if tasklist then
      tasklist.clearAll()
    end
  end

  api.buildTaskGuidanceContext = function(shift)
    local bundle = shift and inputs.dropOff.isBundleShift(shift)
    return {
      guihooks = guihooks,
      shift = shift,
      policy = { kindPolicy = shared.kindPolicy, kindHandler = shared.kindHandler },
      header = api.getEmployerTasklistHeader(),
      assignmentStillInProgress = inputs.dropOff.assignmentStillInProgress(),
      purgeIndependent = api.purgeIndependentTasklist,
      isBundle = bundle and true or false,
      bundleItems = bundle and inputs.dropOff.getShiftAssignmentsForUi(shift) or nil,
      getRepo = shared.repoJob,
      getMaterialsActive = function()
        local mgr = shared.materials()
        return mgr and mgr.getActiveContract and mgr.getActiveContract()
      end,
      getVehicleTaskInfo = function()
        return overhaul_career_logistics_vehicleTasks
          and overhaul_career_logistics_vehicleTasks.getPrimaryActiveVehicleTaskInfo()
      end,
      -- Both callbacks resolve the kind owner; the UI context contract keeps these names.
      getBusGuidance = function() return shared.kindHandler(shift.jobKind, 'guidance', shift) end,
      getAmbulanceGuidance = function() return shared.kindHandler(shift.jobKind, 'guidance', shift) end,
      accidentTask = shift and inputs.accidents.accidentTaskGuidance and inputs.accidents.accidentTaskGuidance(shift) or nil,
      assignedReturnCargoInVehicle = shift and inputs.parcelLoading.assignedReturnCargoInVehicle(shift) or false,
      clearReturnNeedsPickup = function()
        if shift then shift.returnNeedsPickup = nil end
      end,
      handoffPolice = function() return shared.kindHandler(shift.jobKind, 'handoffTasklist', shift) end,
    }
  end

  function api.refreshTaskGuidance(force)
    inputs.eligibility.uiLibrary().refreshTaskGuidance(api.buildTaskGuidanceContext(state.shift), force)
  end

  api.makeAssignmentGuard = function()
    local shift, mapId = state.shift, shared.currentMapId()
    return function()
      return shift ~= nil and state.shift == shift and shared.currentMapId() == mapId
        and overhaul_career_work_employment == M
    end
  end

  api.refreshActiveTaskGuidance = function()
    local shift = state.shift
    if not shift or (not shift.awaitingPark and not shift.spawnBlocked and (shift.paused or shift.phase == "loopComplete")) then return end
    api.refreshTaskGuidance(true)
    if shared.kindPolicy(shift.jobKind).materialContract and not shift.awaitingPark and not shift.spawnBlocked then
      local mgr = shared.materials()
      local active = mgr and mgr.getActiveContract and mgr.getActiveContract()
      if active and active.status == "active" and mgr.refreshTaskGuidance then
        mgr.refreshTaskGuidance(true)
      end
    end
  end
end

-- Shift screen -----------------------------------------------------------------------------------

local function addShiftScreenApi(api, inputs)
  local shared = inputs.shared
  local state = inputs.state
  local runtime = inputs.runtime
  local screen = inputs.screen

  function api.openShiftUi(facId)
    facId = facId or (state.shift and state.shift.originFacId) or state.homeFacId
    local roleplay = facId and inputs.eligibility.isRoleplayFacility(facId)
    if not roleplay then
      if not inputs.eligibility.isEmploymentUnlocked() then
        ui_message("Company employment is not enabled for this career.", 6, "warning")
        return false
      end
      if not inputs.lifecycle.isEmployed() then return false end
      if facId and not inputs.dropOff.facilityMatchesEmployer(facId) then
        facId = (state.shift and state.shift.originFacId) or state.homeFacId
      end
    end
    if not facId then return false end
    if roleplay then
      runtime.roleplayPhoneFacId = facId
      inputs.dropOff.closeWorldPrompt()
      core_jobsystem.create(function(job)
        job.sleep(ROLEPLAY_OPEN_DELAY_S)
        api.notifyUi()
        overhaul_phone_phone.openRoute("phone-employment")
      end)
      return true
    end
    if inputs.dropOff.tryReturnDropOffBeforeShiftUi(facId) then
      return screen.dropOffOpen and true or false
    end
    screen.uiOpen = true
    inputs.dropOff.closeWorldPrompt()
    inputs.dropOff.pauseSim(true)
    if shared.general() then
      shared.general().refreshPoiCargoSnapshot()
    end
    guihooks.trigger("ChangeState", { state = "overhaul.employeeShift", params = { facilityId = facId } })
    return true
  end

  function api.closeShiftUi()
    screen.uiOpen = false
    screen.shiftStartPresentationPending = false
    screen.shiftStartPresentationReady = false
    inputs.dropOff.pauseSim(false)
    inputs.dropOff.changeToPlay()
    if overhaul_integration_services_markerInteraction then
      overhaul_integration_services_markerInteraction.setForceReevaluateOpenPrompt()
    end
  end

  function api.onShiftRouteLeave()
    screen.uiOpen = false
    screen.shiftStartPresentationPending = false
    screen.shiftStartPresentationReady = false
    inputs.dropOff.pauseSim(false)
  end
end

-- Drop-off screen --------------------------------------------------------------------------------

local function addDropOffScreenApi(api, inputs)
  local shared = inputs.shared
  local state = inputs.state
  local runtime = inputs.runtime
  local screen = inputs.screen

  local function clearDropOffScreenFields()
    screen.dropOffFacId, screen.dropOffPsPath = nil, nil
    screen.lastDropOffProgress = nil
    screen.lastDropOffParkingLevels = nil
    screen.holdDropOffForProgress = false
  end

  local function completedLoopCanOpenShiftUi(shift)
    return not runtime.nextAssignmentTransition and state.shift == shift and inputs.lifecycle.isOnShift()
      and shift.phase == "loopComplete" and not shift.wrecked
      and not screen.uiOpen and not screen.dropOffOpen
  end

  local function openShiftUiAfterDropOffSettles(closedShift)
    core_jobsystem.create(function(job)
      job.sleep(0)
      local waited = 0
      while state.shift == closedShift and screen.dropOffEscrowPending and waited < DROP_OFFER_SETTLE_TIMEOUT_S do
        job.sleep(0.1)
        waited = waited + 0.1
      end
      if completedLoopCanOpenShiftUi(closedShift) then
        api.openShiftUi(closedShift.originFacId or state.homeFacId)
      end
    end)
  end

  function api.openDropOffUi(facId, psPath)
    screen.dropOffOpen = true
    screen.dropOffFacId, screen.dropOffPsPath = facId, psPath
    screen.lastDropOffProgress = nil
    screen.lastDropOffParkingLevels = nil
    screen.holdDropOffForProgress = false
    inputs.dropOff.closeWorldPrompt()
    inputs.dropOff.pauseSim(true)
    if shared.general() then
      shared.general().setDeliveryTimePaused(true)
    end
    guihooks.trigger("ChangeState", {
      state = "overhaul.employeeDropOff",
      params = { facilityId = facId, parkingSpotPath = psPath },
    })
    return true
  end

  function api.closeDropOffUi()
    if not screen.dropOffOpen then return end
    local closedShift = state.shift
    screen.dropOffOpen = false
    clearDropOffScreenFields()
    if not runtime.nextAssignmentTransition and closedShift and inputs.lifecycle.isOnShift() and closedShift.phase == "loopComplete"
        and not closedShift.wrecked and not screen.dropOffEscrowPending then
      if not screen.uiOpen then api.openShiftUi(closedShift.originFacId or state.homeFacId) end
      return
    end
    inputs.dropOff.pauseSim(false)
    if shared.general() then
      shared.general().setDeliveryTimePaused(false)
    end
    inputs.dropOff.changeToPlay()
    if overhaul_integration_services_markerInteraction then
      overhaul_integration_services_markerInteraction.setForceReevaluateOpenPrompt(true)
    end
    if closedShift then
      openShiftUiAfterDropOffSettles(closedShift)
    end
  end

  function api.maybeKeepDropOffOpenForProgress()
    if screen.dropOffOpen and (screen.holdDropOffForProgress or screen.lastDropOffProgress) then
      api.notifyUi()
      return true
    end
    return false
  end

  function api.onDropOffRouteLeave()
    local completedShift = state.shift
    local openCompletedShift = not runtime.nextAssignmentTransition and completedShift and inputs.lifecycle.isOnShift()
      and completedShift.phase == "loopComplete" and not completedShift.wrecked
    screen.dropOffOpen = false
    clearDropOffScreenFields()
    if not screen.uiOpen then inputs.dropOff.pauseSim(false) end
    if shared.general() then
      shared.general().setDeliveryTimePaused(false)
    end
    if openCompletedShift then
      core_jobsystem.create(function(job)
        job.sleep(0)
        if runtime.nextAssignmentTransition or state.shift ~= completedShift or not inputs.lifecycle.isOnShift()
            or completedShift.phase ~= "loopComplete" or completedShift.wrecked
            or screen.uiOpen or screen.dropOffOpen then return end
        api.openShiftUi(completedShift.originFacId or state.homeFacId)
      end)
    end
  end
end

-- Assignment formatting --------------------------------------------------------------------------

local function addAssignmentViews(inputs, shared, state, screen)
  local function assignmentAtYard(shift, facId)
    if not facId then return false end
    local fac = shared.generator() and shared.generator().getFacilityById(facId)
    return inputs.dropOff.facilityMatchesEmployer(facId)
      or (shift.originFacId and shift.originFacId == facId)
      or (shift.shiftOrgId and fac and fac.associatedOrganization == shift.shiftOrgId)
      or false
  end

  -- Flags the assignment card reads; computed in the order the card always used.
  local function assignmentFlags(shift)
    local held = shift.paused and true or false
    local spawnBlocked = shift.spawnBlocked and true or false
    local inProgress = inputs.dropOff.assignmentStillInProgress()
    local openEnded = shared.isOpenEndedJobKind(shift.jobKind)
    local loopComplete = shift.phase == "loopComplete" and not inProgress
    local presentation = shared.kindHandler(shift.jobKind, 'presentation', shift) or {}
    local busState = presentation.busState
    local useParamedicGuidance = presentation.useParamedicGuidance or false
    local paramedicGuidance = presentation.paramedicGuidance
    local busGuidance = presentation.busGuidance
    local canAbandon = inputs.endDay.canAbandonEmploymentAssignment()
    local yardDropOffPending = shared.kindPolicy(shift.jobKind).materialContract and inputs.endDay.yardDropOffPendingForEndDay(shift)
    return {
      held = held,
      spawnBlocked = spawnBlocked,
      inProgress = inProgress,
      openEnded = openEnded,
      loopComplete = loopComplete,
      busState = busState,
      useParamedicGuidance = useParamedicGuidance,
      paramedicGuidance = paramedicGuidance,
      busGuidance = busGuidance,
      canAbandon = canAbandon,
      yardDropOffPending = yardDropOffPending,
    }
  end

  local function assignmentCardView(shift, facId, atYard, flags)
    local held, spawnBlocked, inProgress, busState = flags.held, flags.spawnBlocked, flags.inProgress, flags.busState
    local canAbandon = flags.canAbandon
    return {
      phase = shift.phase,
      jobKind = shift.jobKind,
      cargoType = shift.cargoType,
      outboundLabel = shift.outboundLabel,
      outboundSubtext = shift.outboundSubtext,
      returnLabel = shift.returnLabel,
      returnSubtext = shift.returnSubtext,
      returnDeliverLabel = shift.returnDeliverLabel,
      returnIsBackhaul = shift.returnIsBackhaul,
      assignedReturnCargoInVehicle = inputs.parcelLoading.assignedReturnCargoInVehicle(shift),
      wrecked = shift.wrecked,
      endAfterAssignment = shift.endAfterAssignment,
      awaitingPark = shift.awaitingPark,
      stringMode = shift.stringMode,
      stopIndex = shift.stopIndex,
      stopCount = shift.stops and #shift.stops or nil,
      stringStopTotal = shift.stringStopTotal,
      hasStops = shift.stops and true or false,
      spawnBlocked = spawnBlocked,
      spawnBlockedReady = shift.spawnBlocked and shift.spawnBlocked.ready,
      held = held,
      atYard = atYard,
      inProgress = inProgress,
      openEnded = flags.openEnded,
      loopComplete = flags.loopComplete,
      isBundle = inputs.dropOff.isBundleShift(shift),
      isDistributorHaul = inputs.dropOff.isDistributorHaulShift(shift),
      distributorRemaining = inputs.dropOff.distributorHaulRemaining(shift),
      dropOffEscrowPending = screen.dropOffEscrowPending,
      vehiclesParked = inputs.equipment.companyVehiclesParked(),
      busState = busState,
      useParamedicGuidance = flags.useParamedicGuidance,
      paramedicGuidance = flags.paramedicGuidance,
      busGuidance = flags.busGuidance,
      accident = inputs.accidents.accidentUi and inputs.accidents.accidentUi(shift) or nil,
      canReportAccident = inputs.accidents.canReportAccident and inputs.accidents.canReportAccident() or false,
      canEndBusShiftNow = busState and busState.active and busState.routeId ~= nil and not held and not spawnBlocked and not screen.dropOffEscrowPending or false,
      holdsOnEndDay = shared.kindPolicy(shift.jobKind).materialContract and inProgress and not inputs.endDay.onlyCompanyYardReturnLeft(shift) and true or false,
      canSpawnBlockedEquipment = spawnBlocked and state.shift.spawnBlocked.ready == true and not state.shift.spawnBlocked.retryInFlight,
      yardDropOffPending = flags.yardDropOffPending,
      canEndDay = (not held) and inputs.lifecycle.isOnShift() and not screen.dropOffEscrowPending and not flags.yardDropOffPending,
      canAbandonAssignment = canAbandon,
      abandonFine = canAbandon and inputs.endDay.abandonAssignmentQuote() or 0,
      canNextRun = (not shift.endAfterAssignment) and (not held) and (not spawnBlocked) and flags.loopComplete
        and (atYard or inputs.endDay.playerAtEmployerYard(facId)) and not screen.dropOffEscrowPending,
      canContinue = held and atYard,
      shiftAssignments = inputs.dropOff.getShiftAssignmentsForUi(shift),
    }
  end

  local function formatAssignment(facId)
    local shift = state.shift
    if not shift then return nil end
    local atYard = assignmentAtYard(shift, facId)
    return inputs.eligibility.uiLibrary().formatAssignment(assignmentCardView(shift, facId, atYard, assignmentFlags(shift)))
  end

  local function getAssignedVehiclesForUi(shift)
    if not shift or not overhaul_career_garage_inventory then return {} end
    local ids, seen = {}, {}
    local function addId(inventoryId, role)
      if inventoryId == nil then return end
      local key = tostring(inventoryId)
      if seen[key] then return end
      seen[key] = true
      ids[#ids + 1] = { id = inventoryId, role = role }
    end
    for _, inventoryId in ipairs(shift.issuedInventoryIds or {}) do
      addId(inventoryId, "Company vehicle")
    end
    local offerManager = shared.vehicleOffers()
    for offerId in pairs(inputs.dropOff.shiftVehicleOfferIdSet(shift)) do
      local offer = offerManager and offerManager.getOfferById and offerManager.getOfferById(offerId)
      addId(offer and offer.vehicle and offer.vehicle.inventoryId, "Assigned vehicle")
    end
    return inputs.eligibility.uiLibrary().formatAssignedVehicles(ids, overhaul_career_garage_inventory)
  end

  return formatAssignment, getAssignedVehiclesForUi
end

local function addEmployerUiApi(api, inputs, shared, state, runtime, screen, config, owner, MATERIAL_TYPE_UNLOCK_FLAGS, formatAssignment, getAssignedVehiclesForUi)
  -- UI state ---------------------------------------------------------------------------------------

  local function loadListingsForUi()
    local ok, result = pcall(inputs.hiring.getListings)
    if ok and type(result) == "table" then return result end
    log("E", "employment", "getListings failed: " .. tostring(result))
    return {}
  end

  -- The company the screen speaks for: the shift's, a roleplay facility's owner, or the employer on file.
  local function displayIdentity(org, viewProfile, viewFac, viewOrg)
    local displayOrgId, displayOrg = state.employerOrgId, org
    if state.shift and state.shift.shiftOrgId then
      displayOrgId = state.shift.shiftOrgId
      displayOrg = inputs.eligibility.getOrg(displayOrgId) or displayOrg
    elseif inputs.eligibility.isRoleplayProfile(viewProfile) and viewFac then
      displayOrgId = viewFac.associatedOrganization
      displayOrg = viewOrg or displayOrg
    end
    local displayFacId = state.homeFacId
    if state.shift and state.shift.originFacId then
      displayFacId = state.shift.originFacId
    elseif inputs.eligibility.isRoleplayProfile(viewProfile) and viewFac then
      displayFacId = viewFac.id
    end
    return { orgId = displayOrgId, org = displayOrg, facId = displayFacId }
  end

  local function fleetMaterialTypesFor(assignableKinds, offeringFac)
    local fleetMaterialTypes = {}
    if assignableKinds.materials then
      for cargoType in pairs(inputs.eligibility.facilityMaterialTypes(offeringFac)) do
        local flag = MATERIAL_TYPE_UNLOCK_FLAGS[cargoType]
        if flag and inputs.eligibility.hasUnlockFlag(flag) then fleetMaterialTypes[cargoType] = true end
      end
    end
    return fleetMaterialTypes
  end

  -- Returns the employer offerings and the company fleet offered at one facility.
  local function offeringsAndFleet(offeringFacId)
    if not offeringFacId then return {}, {} end
    local offeringProfile, _offeringOrg, offeringFac = inputs.eligibility.getFacilityEmployerProfile(offeringFacId)
    local assignableKinds = inputs.eligibility.getAssignableKinds(offeringFacId)
    local employerOfferings = inputs.eligibility.buildFacilityOfferings(offeringFacId, offeringProfile, assignableKinds)
    local caps = shared.loanerCapabilities()
    if not caps then return employerOfferings, {} end
    local companyVehicles = caps.getCompanyFleetForUi(offeringFac, {
      parcel = assignableKinds.parcel,
      trailer = assignableKinds.trailer,
      repo = assignableKinds.repo,
      vehicle = assignableKinds.vehicle,
      distributorHaul = inputs.eligibility.facilityIssuesDistributorHaul(offeringFac),
      materialTypes = fleetMaterialTypesFor(assignableKinds, offeringFac),
    })
    return employerOfferings, companyVehicles
  end

  local function damageStatusForUi()
    return inputs.eligibility.uiLibrary().formatDamageStatus(
        inputs.settlement.getDamageStrikeCount(),
        config.DAMAGE_STRIKE_WARN_COUNT,
        config.DAMAGE_STRIKE_DOCK_COUNT,
        config.DAMAGE_STRIKE_DOCK_PERCENT
      )
  end

  api.getUiState = function(facId)
    facId = facId or (state.shift and state.shift.originFacId) or runtime.roleplayPhoneFacId
    inputs.persistence.ensureRehireSaveV3()
    inputs.eligibility.syncUnlockFlagsForDeliveryLevel()
    local listings = loadListingsForUi()
    local org = inputs.eligibility.getOrg(state.employerOrgId)
    local pending = state.pendingApplications[1]
    local unlocked = inputs.eligibility.isEmploymentUnlocked()
    local viewProfile, viewOrg, viewFac = inputs.eligibility.getFacilityEmployerProfile(facId)
    local display = displayIdentity(org, viewProfile, viewFac, viewOrg)
    local businessName = inputs.eligibility.getBusinessDisplayName(display.facId, display.orgId)
    local employerRepLevel = display.orgId and inputs.eligibility.getRepLevel(display.org) or nil
    local employerRepLabel = display.orgId and inputs.eligibility.getOrgReputationLabel(display.org, employerRepLevel) or nil
    local skillLevel, skillLabel = shared.uiSkillProgress(viewProfile, viewFac, viewOrg)
    local commissionPercent = inputs.eligibility.uiLibrary().commissionPercent(companyShareForLevel(employerRepLevel))
    local employerOfferings, companyVehicles = offeringsAndFleet(display.facId or facId)
    local roleplaySetup = (not state.shift) and shared.buildRoleplaySetupUi(viewProfile, viewFac, facId) or nil
    return inputs.eligibility.uiLibrary().formatUiState({
      employed = inputs.lifecycle.isEmployed() and true or false,
      onShift = inputs.lifecycle.isOnShift() and true or false,
      roleplayFacility = inputs.eligibility.isRoleplayProfile(viewProfile) and true or false,
      roleplaySetup = roleplaySetup,
      canClockInHere = canClockInHere(inputs, owner, facId, viewProfile),
      employerOrgId = display.orgId,
      employerName = businessName,
      employerPreview = employerPreviewFor(display.facId),
      employerRepLevel = employerRepLevel,
      employerRepLabel = employerRepLabel,
      commissionPercent = commissionPercent,
      employerOfferings = employerOfferings,
      companyVehicles = companyVehicles,
      assignedVehicles = getAssignedVehiclesForUi(state.shift),
      shiftStartPending = screen.shiftStartPresentationPending and true or false,
      shiftStartReady = screen.shiftStartPresentationReady and true or false,
      logisticsEmployerOrgId = state.employerOrgId,
      logisticsEmployerName = inputs.eligibility.getBusinessDisplayName(state.homeFacId, state.employerOrgId),
      homeFacId = (state.shift and state.shift.originFacId) or state.homeFacId,
      pending = pendingView(inputs, pending),
      assignment = formatAssignment(facId),
      canReportAccident = inputs.accidents.canReportAccident and inputs.accidents.canReportAccident() or false,
      escrowMoney = inputs.settlement.reconcileEscrowMoney("getUiState"),
      escrowLegs = state.escrow.legs or {},
      surgeBonusHeld = inputs.settlement.escrowSurgeBonusTotal(),
      damageStrikeCount = inputs.settlement.getDamageStrikeCount(),
      showDamageNotice = inputs.settlement.getDamageStrikeCount() > 0,
      damageStatus = damageStatusForUi(),
      listings = listings,
      atEmployerYard = facId and inputs.dropOff.facilityMatchesEmployer(facId) or false,
      deliveryLevel = inputs.eligibility.getDeliveryLevel(),
      skillLevel = tonumber(skillLevel) or 0,
      skillLabel = skillLabel,
      unlocked = unlocked,
      apprenticeship = inputs.eligibility.isApprenticeshipEnabled(),
      independentCargoLevel = config.INDEPENDENT_CARGO_LEVEL,
      devTools = shared.isDevToolsEnabled(),
      headhunterOffer = state.headhunter and state.headhunter.pending or nil,
    })
  end

  function api.getDropOffUiState()
    local shift = state.shift
    if not screen.dropOffEscrowPending and shift and screen.dropOffFacId and inputs.dropOff.facilityMatchesEmployer(screen.dropOffFacId) then
      if not inputs.dropOff.isBundleHaulBackhaulPending(shift)
          and (shift.awaitingLoopChoice
            or (shift.phase == "return" and not inputs.dropOff.hasOutstandingReturnWork(shift))) then
        inputs.dropOff.afterReturnDelivered()
      end
    end
    local ui = api.getUiState(screen.dropOffFacId)
    ui.facilityId = screen.dropOffFacId
    ui.parkingSpotPath = screen.dropOffPsPath
    ui.canConfirm = (not screen.dropOffEscrowPending) and inputs.dropOff.hasAssignedDropOffHere(screen.dropOffFacId, screen.dropOffPsPath)
    if ui.canConfirm then
      screen.lastDropOffParkingLevels = inputs.dropOff.getDropOffParkingLevels(screen.dropOffFacId, screen.dropOffPsPath)
    end
    ui.parkingLevels = screen.lastDropOffParkingLevels
    ui.progressRewards = nil
    ui.repDelta = screen.lastDropOffProgress
    return ui
  end
end

local function addUiStateApi(api, inputs)
  local shared, state, runtime, screen = inputs.shared, inputs.state, inputs.runtime, inputs.screen

  local formatAssignment, getAssignedVehiclesForUi = addAssignmentViews(inputs, shared, state, screen)
  addEmployerUiApi(api, inputs, shared, state, runtime, screen, inputs.config, inputs.M, inputs.MATERIAL_TYPE_UNLOCK_FLAGS, formatAssignment, getAssignedVehiclesForUi)
end

-- Constructor ------------------------------------------------------------------------------------

function part.new(inputs)
  local api = inputs.api or {}
  addGuidanceApi(api, inputs)
  addShiftScreenApi(api, inputs)
  addDropOffScreenApi(api, inputs)
  addUiStateApi(api, inputs)
  return api
end

return part
