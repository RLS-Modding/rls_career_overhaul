-- Company shift construction, admission, next-run dispatch and the next-assignment transition.
-- Reading order: kind inputs, shift construction, starting work, guided dispatch, admission, next runs, transition.
-- gameplay_walk is per-level and may be absent during career load or level teardown.
local part = {}

-- Shared helpers ---------------------------------------------------------------------------------

-- A kind's owner module answers through manifest handlers; a kind without a handler gets the default.
local function kindHasHandler(shared, kindId, name)
  local kind = shared.kindDefinition(kindId)
  return kind ~= nil and kind.handlers ~= nil and kind.handlers[name] ~= nil
end

local function loanerFailureDetail(shared, dispatch, facId, job)
  return dispatch.diagnoseLoanerFailure(
    shared.generator() and shared.generator().getFacilityById(facId),
    job,
    { cargoType = job.cargoType, targetLoad = job.standardLoad or job.targetLoad })
end

local function payHeldWages(settlement)
  local paid, wages, bonus = settlement.payEscrow()
  if paid == nil then return nil, wages end
  if paid > 0 then
    ui_message(settlement.formatTodaysWagesMessage(paid, wages, bonus), 6, "success")
  end
  return paid
end

local function nextRunGateFailure(inputs, facId)
  local dispatch, dropOff, routing, shared = inputs.dispatch, inputs.dropOff, inputs.routing, inputs.shared
  if not inputs.lifecycle.isOnShift() or inputs.state.shift.phase ~= "loopComplete" or dropOff.assignmentStillInProgress() then
    return shared.failShift("Finish the current assignment loop first.", dispatch.diagnoseDispatch(facId, "nextRunGate"))
  end
  if not routing.playerNearHomeYard() then
    routing.routeToYard()
    return shared.failShift("Return to the company yard before taking another job.", dispatch.diagnoseDispatch(facId, "nextRunAwayFromYard"))
  end
  return nil
end

-- Kind context -----------------------------------------------------------------------------------

-- Built per call so it sees current closures; add-ons use the wage and guidance contract (kindContract.lua).
local function addKindContextApi(api, inputs)
  local backhaul, equipment, projections, routing = inputs.backhaul, inputs.equipment, inputs.projections, inputs.routing

  function api.kindContext(facId, fac, caps, kindId, shift)
    local kindContext = {
      dispatch = inputs.dispatch,
      equipment = equipment,
      shared = inputs.shared, state = inputs.state, screen = inputs.screen, runtime = inputs.runtime, facId = facId, fac = fac, caps = caps,
      assignment = api,
      backhaul = backhaul,
      eligibility = inputs.eligibility,
      endDay = inputs.endDay,
      projections = projections,
      routing = routing,
      settlement = inputs.settlement,
      captureIssuedInventoryIds = equipment.captureIssuedInventoryIds,
      activateAssignedWork = routing.activateAssignedWork,
      firePhoneNotification = projections.firePhoneNotification,
      markIssued = equipment.markIssued,
      markShiftStartPresentationReady = routing.markShiftStartPresentationReady,
      notifyUi = projections.notifyUi,
      refreshTaskGuidance = projections.refreshTaskGuidance,
    }
    if kindId then inputs.kindContract.addKindContract(kindContext, kindId, shift) end
    return kindContext
  end
end

-- Assignment start -------------------------------------------------------------------------------

local function defaultShiftState(shared, facId, job, issuedInventoryIds)
  return {
    phase = "outbound",
    jobKind = job.kind,
    spawnFallbackAttempted = job.spawnFallbackAttempted,
    issuedInventoryIds = issuedInventoryIds or {},
    assignedCargoIds = job.cargoIds or {},
    assignedOfferId = job.offerId,
    assignedContractId = job.contractId,
    cargoType = job.cargoType,
    targetLoad = shared.kindPolicy(job.kind).parcels and shared.kindHandler(job.kind, "targetLoad", job) or job.standardLoad,
    materialName = job.materialName,
    destFacId = job.destFacId,
    destPsPath = job.destPsPath,
    originFacId = facId,
    originLocation = job.originLocation,
    destLocation = job.destLocation,
    needsRemotePickup = job.needsRemotePickup and true or false,
    dropOffDepartureRequired = shared.kindPolicy(job.kind).parcels and true or nil,
    pickupFacId = job.pickupFacId,
    distributorHaul = job.distributorHaul and true or nil,
    couplerClass = job.couplerClass,
    assignedOfferIds = job.offerIds and deepcopy(job.offerIds) or nil,
    deliveredOfferIds = job.distributorHaul and {} or nil,
    stringMode = job.stringMode and true or nil,
    stops = job.stops,
    stopIndex = job.stringMode and (job.stopIndex or 1) or nil,
    stringCargoIds = job.stringMode and (job.cargoIds and deepcopy(job.cargoIds) or nil) or nil,
    stringStopTotal = nil,
    stopsCompleted = job.stringMode and 0 or nil,
    loopComplete = false,
    wrecked = false,
    outboundLabel = job.label,
    outboundSubtext = job.subtext,
    returnLabel = "Return to the company yard",
    returnSubtext = "Clock out after you arrive, or take another run",
  }
end

local function newShiftStateMaker(api, inputs)
  local kindContract, parcelStrings, settlement, shared = inputs.kindContract, inputs.parcelStrings, inputs.settlement, inputs.shared

  return function(facId, job, issuedInventoryIds)
    if kindHasHandler(shared, job.kind, "shiftState") then
      local fac = shared.generator() and shared.generator().getFacilityById(facId)
      local kindContext = api.kindContext(facId, fac, nil, job.kind)
      local shift = shared.kindHandler(job.kind, "shiftState", kindContext, job, issuedInventoryIds)
      kindContract.bindContextShift(kindContext, shift)
      return shift
    end
    local shift = defaultShiftState(shared, facId, job, issuedInventoryIds)
    if shift.stringMode and shift.stops and parcelStrings.applyStop then
      parcelStrings.applyStop(shift, shift.stopIndex or 1)
    end
    shift.surgeBonusEligible = settlement.isJobKindSurged(job.kind, job.cargoType) and true or nil
    return shift
  end
end

local function suppressConflictingRoleplay(shared, state, jobKind)
  jobKind = jobKind or (state.shift and state.shift.jobKind)
  if shared.kindPolicy(jobKind).roleplay then return end
  overhaul_jobs_bus.cancelActiveRoute("company logistics shift")
  overhaul_jobs_ambulance.cancelActiveCall("company logistics shift")
end

local function loanerRequest(shared, job)
  local targetLoad = job.standardLoad
  if shared.kindPolicy(job.kind).parcels then
    targetLoad = shared.kindHandler(job.kind, "targetLoad", job)
  end
  return targetLoad, {
    cargoType = job.cargoType,
    targetLoad = targetLoad,
  }
end

local function issueLoaners(shared, job, fac, caps, kindContext, targetLoad, loanerOpts)
  if kindHasHandler(shared, job.kind, "issueLoaners") then
    return shared.kindHandler(job.kind, "issueLoaners", kindContext, job, targetLoad)
  end
  return caps and caps.getIssuedLoanersForFacility(fac, job.kind, loanerOpts) or nil, nil, loanerOpts
end

local function newAfterSpawn(inputs, kindContext, job, isCurrent)
  local equipment, projections, routing, shared, state = inputs.equipment, inputs.projections, inputs.routing, inputs.shared, inputs.state

  return function()
    if not isCurrent() then
      shared.shiftLog("afterSpawn skipped", "shift state cleared before spawn callback")
      return
    end
    state.shift.issuedInventoryIds = equipment.captureIssuedInventoryIds()
    if shared.kindHandler(job.kind, "rejectSpawn", kindContext, job, state.shift) then return end
    if shared.general() then
      shared.general().startDeliveryMode()
    end
    if not shared.kindHandler(job.kind, "activate", kindContext, job, isCurrent) then
      routing.activateAssignedWork(job)
    end
    if not isCurrent() then return end
    if state.shift and state.shift.spawnBlocked then
      projections.refreshTaskGuidance(true)
      projections.notifyUi()
      projections.closeShiftUi()
      return
    end
    projections.refreshTaskGuidance(true)
    projections.firePhoneNotification("employment.shiftStarted", "Shift started", job.label or "Deliver the assigned load.", "success")
    shared.kindHandler(job.kind, "presentationReady", kindContext, job)
    projections.notifyUi()
    routing.beginCompanyVehiclePickupRoute()
    shared.shiftLog("afterSpawn complete", string.format("jobKind=%s issued=%d",
      tostring(job.kind), #(state.shift.issuedInventoryIds or {})))
  end
end

local function newIssueEquipment(inputs, job, truck, trailer, isCurrent, afterSpawn)
  local equipment, projections, routing, shared = inputs.equipment, inputs.projections, inputs.routing, inputs.shared

  return function(returned)
    if not isCurrent() then return end
    if returned == false then shared.emptyShift(); projections.notifyUi(); return end
    equipment.markIssued(truck)
    if trailer and not shared.kindPolicy(job.kind).trailerDelivery then
      equipment.markIssued(trailer)
    end
    if not truck.id then
      shared.shiftLog("beginAssignment blocked", "loaner offer missing id after markIssued")
      routing.handleAssignmentStartFailure("No company truck is available for this assignment.")
      return
    end
    shared.shiftLog("beginAssignment", "spawning company loaner offers")
    equipment.spawnCompanyOffers(afterSpawn)
  end
end

-- Cargo and loader kinds: loaner issue, company vehicle spawn, then activation through each kind's handlers.
local function newLoaderStarter(api, inputs, makeShiftState)
  local dispatch, equipment, shared, state = inputs.dispatch, inputs.equipment, inputs.shared, inputs.state

  return function(facId, job, fac, caps, kindContext)
    local targetLoad, loanerOpts = loanerRequest(shared, job)
    shared.kindHandler(job.kind, "loanerOptions", kindContext, job, loanerOpts)
    local truck, trailer
    truck, trailer, loanerOpts = issueLoaners(shared, job, fac, caps, kindContext, targetLoad, loanerOpts)
    if not truck then
      local detail = dispatch.diagnoseLoanerFailure(fac, job, loanerOpts)
      api.assignmentMessage("No company truck is available for this assignment.", 6, "warning")
      shared.shiftLog("beginAssignment blocked", string.format("jobKind=%s; %s", tostring(job.kind), detail))
      return false, detail
    end

    state.shift = makeShiftState(facId, job, equipment.captureIssuedInventoryIds())
    inputs.kindContract.bindContextShift(kindContext, state.shift)
    local isCurrent = inputs.projections.makeAssignmentGuard()
    if loanerOpts.couplerClass then
      state.shift.couplerClass = loanerOpts.couplerClass
    end
    shared.shiftLog("beginAssignment", string.format("jobKind=%s coupler=%s truck=%s trailer=%s",
      tostring(job.kind), tostring(loanerOpts.couplerClass), dispatch.describeLoanerOffer(truck), dispatch.describeLoanerOffer(trailer)))

    local afterSpawn = newAfterSpawn(inputs, kindContext, job, isCurrent)
    if equipment.canReuseIssuedEquipmentForJob(job.kind, loanerOpts.couplerClass, loanerOpts) then
      shared.shiftLog("beginAssignment", "reusing existing issued company inventory")
      afterSpawn()
      return true
    end

    local issueEquipment = newIssueEquipment(inputs, job, truck, trailer, isCurrent, afterSpawn)
    if equipment.collectCompanyInventoryIds()[1] then
      shared.shiftLog("beginAssignment", "returning incompatible company equipment")
      if equipment.playerInIssuedCompanyTruck() then
        api.assignmentMessage("Step out of the company van. This job uses a different vehicle.", 7, "info")
      end
      equipment.handoffCompanyEquipmentThen(issueEquipment)
    else
      issueEquipment()
    end
    return true
  end
end

local function newBeginAssignment(api, inputs)
  local kindContract, persistence, shared, state = inputs.kindContract, inputs.persistence, inputs.shared, inputs.state
  local makeShiftState = newShiftStateMaker(api, inputs)
  local beginLoaderAssignment = newLoaderStarter(api, inputs, makeShiftState)

  return function(facId, job)
    persistence.touchLastWorkAt()
    state.ignoreCompanyDamageStrikes = nil
    job = job or {}
    local gen = shared.generator()
    if not gen then
      return false, "delivery generator not loaded"
    end
    local fac = gen.getFacilityById(facId)
    if not fac then
      return false, "facility not found: " .. tostring(facId)
    end
    local caps = shared.loanerCapabilities()
    local kindContext = api.kindContext(facId, fac, caps, job.kind)
    kindContext.makeShiftState = function(...)
      local shift = makeShiftState(...)
      kindContract.bindContextShift(kindContext, shift)
      return shift
    end
    -- Roleplay shifts own the player outright; every other kind first clears freestanding roleplay routes.
    local roleplay = shared.kindPolicy(job.kind).roleplay
    if not roleplay then suppressConflictingRoleplay(shared, state, job.kind) end
    local started, detail
    if kindHasHandler(shared, job.kind, "beginAssignment") then
      started, detail = shared.kindHandler(job.kind, "beginAssignment", job, kindContext)
    elseif roleplay then
      started, detail = false, "kind has no roleplay handler"
    else
      started, detail = beginLoaderAssignment(facId, job, fac, caps, kindContext)
    end
    -- A start that created no shift leaves its handlers' wage handle unbound: it can never pay.
    kindContract.settleContextStart(kindContext, started)
    return started, detail
  end
end

-- Guided dispatch --------------------------------------------------------------------------------

local function addGuidedStartApi(api, inputs, beginAssignment)
  local projections, routing, runtime = inputs.projections, inputs.routing, inputs.runtime

  api.beginAssignmentWithGuidance = function(facId, job)
    if runtime.nextAssignmentTransition then
      api.resetNextAssignmentAttempt(runtime.nextAssignmentTransition)
    end
    local ok, err = beginAssignment(facId, job)
    if not ok then
      local retrying = routing.handleAssignmentStartFailure("Could not issue the company assignment.", {
        jobKind = job.kind,
        originFacId = facId,
        spawnFallbackAttempted = job.spawnFallbackAttempted,
      })
      return retrying, err
    end
    if ok then projections.refreshActiveTaskGuidance() end
    return ok, err
  end
end

-- Admission --------------------------------------------------------------------------------------

local function addShiftStartApi(api, inputs)
  local dispatch, eligibility, shared, state = inputs.dispatch, inputs.eligibility, inputs.shared, inputs.state

  local function facilityBelongsToShiftOrg(facId)
    local fac = shared.generator() and shared.generator().getFacilityById(facId)
    return fac and fac.associatedOrganization == state.shift.shiftOrgId
  end

  local function canResumeHeldShift(facId, roleplay)
    return (not roleplay and inputs.dropOff.facilityMatchesEmployer(facId))
      or (roleplay and state.shift.originFacId == facId)
      or (roleplay and state.shift.shiftOrgId and facId and facilityBelongsToShiftOrg(facId))
  end

  local function continueHeldShift(facId, roleplay)
    if canResumeHeldShift(facId, roleplay) then
      local ok = inputs.recovery.resumeShift(facId)
      if ok then
        shared.shiftLog("startShift", "resumed held assignment")
        return shared.okShift()
      end
      return shared.failShift("Could not continue the held assignment.", dispatch.diagnoseDispatch(facId, "resumeShift"))
    end
    return shared.failShift("End your current company shift before starting another.",
      string.format("pausedKind=%s", tostring(state.shift.jobKind)))
  end

  function api.startShift(facId, resolveJob)
    shared.shiftLog("startShift requested", string.format("facId=%s", tostring(facId)))
    local gate, fail = api.startShiftGate(facId, true)
    if not gate then return fail end
    local roleplay = eligibility.isRoleplayFacility(facId)
    if gate == "resume" then return continueHeldShift(facId, roleplay) end
    if gate == "nextRun" then return api.startNextRun(facId, resolveJob) end
    if not roleplay then
      local gate = eligibility.getListingSkillGate(facId)
      if gate.skillLocked then return shared.failShift(gate.skillMessage) end
    end
    local job, chooseErr
    if resolveJob then job, chooseErr = resolveJob(facId)
    else job, chooseErr = inputs.backhaul.chooseJob(facId) end
    if not job then
      return shared.failShift("No company assignments are ready.", chooseErr or dispatch.diagnoseNoJob(facId))
    end
    inputs.screen.shiftStartPresentationPending = inputs.screen.uiOpen and true or false
    inputs.screen.shiftStartPresentationReady = false
    shared.shiftLog("startShift dispatch", string.format("jobKind=%s label=%s", tostring(job.kind), tostring(job.label)))
    local ok, assignErr = api.beginAssignmentWithGuidance(facId, job)
    if not ok then
      inputs.screen.shiftStartPresentationPending = false
      return shared.failShift("Could not issue the company truck.", assignErr or loanerFailureDetail(shared, dispatch, facId, job))
    end
    shared.shiftLog("startShift", "assignment begun; waiting for loaner spawn callback if needed")
    return shared.okShift({ jobKind = job.kind, label = job.label })
  end

  function api.startShiftGate(facId, continueHeld)
    if overhaul_career_logistics_vehicleTransfer.isOnShift() then
      return false, shared.failShift("End your CarGo day before starting a company shift.")
    end
    local roleplay = eligibility.isRoleplayFacility(facId)
    if not roleplay and not eligibility.isEmploymentUnlocked() then
      return false, shared.failShift("Company employment is not enabled for this career.")
    end
    if not roleplay and not inputs.dropOff.facilityMatchesEmployer(facId) then
      return false, shared.failShift("You are not employed at this company.", dispatch.diagnoseDispatch(facId, "employerMismatch"))
    end
    if state.shift and state.shift.paused and not continueHeld then
      return false, shared.failShift("End or continue the held assignment before selecting a new job.")
    end
    if state.shift and not state.shift.paused then
      if inputs.lifecycle.isOnShift() and state.shift.phase == "loopComplete" and not roleplay then
        return "nextRun"
      end
      return false, shared.failShift("End your current company shift before starting another.",
        string.format("phase=%s kind=%s", tostring(state.shift.phase), tostring(state.shift.jobKind)))
    end
    local depotId = state.shift and state.shift.originFacId or facId
    if not inputs.routing.playerNearShiftStart(depotId) then
      local name = eligibility.getBusinessDisplayName(depotId, state.employerOrgId)
      local routed = inputs.routing.routeToShiftStart(depotId)
      return false, shared.failShift("Report to " .. name .. " to clock in. "
        .. (routed and "Route to the company depot set." or "The company depot location is unavailable."))
    end
    return state.shift and "resume" or "start"
  end
end

local function addStartWithJobApi(api, inputs)
  local dispatch, projections, shared, state = inputs.dispatch, inputs.projections, inputs.shared, inputs.state

  local function startNextRunWithJob(facId, job)
    local gateFailure = nextRunGateFailure(inputs, facId)
    if gateFailure then return gateFailure end
    if inputs.screen.dropOffEscrowPending then
      return shared.failShift("Still confirming drop-off pay — wait a moment.", dispatch.diagnoseDispatch(facId, "escrow"))
    end
    local previousKind = state.shift and state.shift.jobKind
    if previousKind and not shared.isOpenEndedJobKind(previousKind) then
      local paid, problem = payHeldWages(inputs.settlement)
      if paid == nil then return shared.failShift("Could not settle held wages.", problem) end
    end
    local ok, assignErr = api.beginNextAssignment(facId, job)
    if not ok then
      if state.shift and state.shift.phase ~= "loopComplete" then
        state.shift.phase = "loopComplete"
      end
      return shared.failShift("Could not issue the company truck.", assignErr or loanerFailureDetail(shared, dispatch, facId, job))
    end
    shared.shiftLog("startShiftWithJob nextRun", string.format("from=%s to=%s label=%s",
      tostring(previousKind), tostring(job.kind), tostring(job.label)))
    projections.closeShiftUi()
    projections.closeDropOffUi()
    inputs.persistence.saveEmploymentProgress()
    return shared.okShift({ jobKind = job.kind, label = job.label })
  end

  function api.startShiftWithJob(facId, selection)
    if inputs.runtime.nextAssignmentTransition then return shared.okShift({preparing = true}) end
    if not shared.isDevToolsEnabled() then
      return shared.failShift("Dev key required.")
    end
    shared.shiftLog("startShiftWithJob requested", string.format("facId=%s selection=%s", tostring(facId), dumps(selection)))
    local gate, fail = api.startShiftGate(facId)
    if not gate then
      return fail
    end
    local job, chooseErr = dispatch.resolveSelectedJob(facId, selection)
    if not job then
      local readyMsg = chooseErr
      if type(readyMsg) == "string" and #readyMsg < 160 and not readyMsg:find("ctx=", 1, true) then
        return shared.failShift(readyMsg, dispatch.diagnoseNoJob(facId))
      end
      return shared.failShift("Selected job is no longer available.", chooseErr or dispatch.diagnoseNoJob(facId))
    end
    if gate == "nextRun" then return startNextRunWithJob(facId, job) end
    shared.shiftLog("startShiftWithJob dispatch", string.format("jobKind=%s label=%s", tostring(job.kind), tostring(job.label)))
    local ok, assignErr = api.beginAssignmentWithGuidance(facId, job)
    if not ok then
      return shared.failShift("Could not issue the company truck.", assignErr or loanerFailureDetail(shared, dispatch, facId, job))
    end
    return shared.okShift({ jobKind = job.kind, label = job.label })
  end
end

local function addNextRunApi(api, inputs)
  local projections, runtime, shared, state = inputs.projections, inputs.runtime, inputs.shared, inputs.state

  api.startNextRun = function(facId, resolveJob)
    if runtime.nextAssignmentTransition then return shared.okShift({preparing = true}) end
    if state.shift and state.shift.endAfterAssignment then return false end
    local gateFailure = nextRunGateFailure(inputs, facId)
    if gateFailure then return gateFailure end
    if api.tryAutoAssignNextRun(resolveJob) then
      projections.closeShiftUi()
      projections.closeDropOffUi()
      return shared.okShift({
        jobKind = state.shift and state.shift.jobKind,
        label = state.shift and state.shift.outboundLabel,
      })
    end
    return shared.failShift("No further assignments are ready.", inputs.dispatch.diagnoseNoJob(facId or state.homeFacId))
  end

  api.tryAutoAssignNextRun = function(resolveJob)
    if runtime.nextAssignmentTransition then return true end
    if state.shift and state.shift.endAfterAssignment then return false end
    if not inputs.lifecycle.isOnShift() then return false end
    if inputs.screen.dropOffEscrowPending then
      shared.shiftLog("tryAutoAssignNextRun", "blocked: drop-off escrow still pending")
      return false
    end
    local shift = state.shift
    if not shift or shift.paused then return false end
    if shift.phase ~= "loopComplete" then return false end
    if inputs.dropOff.assignmentStillInProgress() then return false end
    local facId = shift.originFacId or state.homeFacId
    local previousKind = shift.jobKind
    local job, chooseErr
    if not resolveJob and kindHasHandler(shared, previousKind, "buildAssignment") then
      resolveJob = shared.kindAssignmentResolver(previousKind)
    end
    if resolveJob then job, chooseErr = resolveJob(facId)
    else job, chooseErr = inputs.backhaul.chooseJob(facId) end
    if not job then
      shared.shiftLog("tryAutoAssignNextRun", chooseErr or "no job available")
      return false
    end
    -- Finite loops cash out between runs. Open-ended shifts hold pay until End day.
    if not shared.isOpenEndedJobKind(previousKind) then
      if payHeldWages(inputs.settlement) == nil then return false end
    end
    -- Damaged / wrong-kind company equipment is returned and replaced inside beginAssignment.
    local ok, assignErr = api.beginNextAssignment(facId, job)
    if not ok then
      shared.shiftLog("tryAutoAssignNextRun", assignErr or "beginAssignment failed")
      if state.shift and state.shift.phase ~= "loopComplete" then
        state.shift.phase = "loopComplete"
      end
      return false
    end
    shared.shiftLog("tryAutoAssignNextRun", string.format("jobKind=%s label=%s", tostring(job.kind), tostring(job.label)))
    inputs.persistence.saveEmploymentProgress()
    return true
  end
end

-- Shift actions ----------------------------------------------------------------------------------

local function addShiftActionApi(api, inputs)
  local equipment, shared = inputs.equipment, inputs.shared

  function api.callShiftAction(actionName, fn, facId)
    local ok, result = pcall(fn, facId)
    if not ok then
      return shared.failShift("Shift action crashed: " .. tostring(actionName), tostring(result))
    end
    if type(result) ~= "table" then
      return shared.failShift("Shift action returned unexpected value: " .. tostring(actionName), tostring(result))
    end
    return result
  end

  function api.issuedVehiclesStillPresent()
    for _, inventoryId in ipairs(equipment.collectCompanyInventoryIds()) do
      if overhaul_career_garage_inventory.getVehicles()[inventoryId] then
        return true
      end
    end
    return false
  end
end

-- Begin, readiness and cancellation --------------------------------------------------------------

local function addNextAssignmentStartApi(api, inputs)
  local effects, runtime, shared, state = inputs.projections, inputs.runtime, inputs.shared, inputs.state

  api.assignmentMessage = function(...)
    if not runtime.nextAssignmentTransition then ui_message(...) end
  end

  runtime.NEXT_ASSIGNMENT_LOADING_TAG = "rlsEmploymentNextAssignment"
  runtime.NEXT_ASSIGNMENT_LOADING_FALLBACK_S = 4
  runtime.NEXT_ASSIGNMENT_TIMEOUT_S = 15
  runtime.NEXT_ASSIGNMENT_RETRY_S = 1
  runtime.NEXT_ASSIGNMENT_SETTLE_S = 0.5
  runtime.NEXT_ASSIGNMENT_CARGO_QUERY_TIMEOUT_S = 3
  runtime.NEXT_ASSIGNMENT_STEP_LABELS = {
    screen = "showing the loading screen",
    returnEquipment = "returning the previous vehicle",
    spawn = "spawning the company vehicle",
    enter = "entering the company vehicle",
    load = "loading cargo",
    prepare = "preparing the job",
    settle = "settling the vehicle",
  }

  api.setNextAssignmentStep = function(transition, step)
    if transition.step == step then return end
    shared.shiftLog("next assignment", string.format("%s -> %s at %.1fs",
      tostring(transition.step or "start"), step, tonumber(transition.elapsed) or 0))
    transition.step = step
    transition.stepWait = 0
    transition.nextRetryAt = 0
  end

  api.resetNextAssignmentAttempt = function(transition)
    transition.elapsed = 0
    transition.stepWait = 0
    transition.readyShift = nil
    transition.equipmentShift = nil
    transition.deferredWork = nil
    transition.enterAttempts = 0
    transition.settled = 0
    transition.cargoWait = 0
  end

  api.enterCareerLoadingScreen = function(tag, onShown)
    core_gamestate.requestEnterLoadingScreen(tag, onShown)
  end

  api.exitCareerLoadingScreen = function(tag)
    if not core_gamestate.getLoadingStatus(tag) then return end
    core_gamestate.requestExitLoadingScreen(tag)
  end

  api.finishNextAssignmentTransition = function()
    if not runtime.nextAssignmentTransition then return end
    runtime.nextAssignmentTransition = nil
    core_input_actionFilter.addAction(0, "employmentNextAssignment", false)
    api.exitCareerLoadingScreen(runtime.NEXT_ASSIGNMENT_LOADING_TAG)
  end

  api.markNextAssignmentReady = function(shift)
    if runtime.nextAssignmentTransition and shift and state.shift == shift then
      runtime.nextAssignmentTransition.readyShift = shift
    end
  end

  api.beginNextAssignment = function(facId, job)
    if runtime.nextAssignmentTransition then return true end
    local transition = {elapsed = 0, employerOrgId = state.employerOrgId}
    runtime.nextAssignmentTransition = transition
    api.setNextAssignmentStep(transition, "screen")
    core_input_actionFilter.setGroup("employmentNextAssignment", {
      "throttle", "brake", "clutch", "steering", "parkingbrake", "toggleParkingbrake",
      "walkingMode", "switch_next_vehicle", "switch_previous_vehicle", "reset_physics",
    })
    core_input_actionFilter.addAction(0, "employmentNextAssignment", true)
    effects.closeShiftUi()
    effects.closeDropOffUi()
    local previousShift = state.shift
    local started = false
    local function begin()
      if started then return end
      started = true
      if runtime.nextAssignmentTransition ~= transition then return end
      if state.shift ~= previousShift or state.employerOrgId ~= transition.employerOrgId then
        api.finishNextAssignmentTransition()
        return
      end
      api.setNextAssignmentStep(transition, "spawn")
      local ok, err = pcall(api.beginAssignmentWithGuidance, facId, job)
      if not ok then
        shared.shiftLog("next assignment failed", tostring(err))
        shared.emptyShift()
        ui_message("Could not prepare another assignment. Clock in again to try another job.", 8, "warning")
      end
    end
    api.enterCareerLoadingScreen(runtime.NEXT_ASSIGNMENT_LOADING_TAG, begin)
    core_jobsystem.create(function(jobSystem)
      jobSystem.sleep(runtime.NEXT_ASSIGNMENT_LOADING_FALLBACK_S)
      begin()
    end)
    return true
  end
end

-- Vehicle entry, retries and completion ----------------------------------------------------------

function part.addTickApi(api, inputs)
  local effects = inputs.effects
  local shared = inputs.shared
  local state = inputs.state
  local runtime = inputs.runtime

  api.nextAssignmentVehicle = function(shift)
    if shared.kindPolicy(shift.jobKind).vehicleDelivery and not shift.distributorHaul then
      local mgr = shared.vehicleOffers()
      local offer = mgr and mgr.getOfferById and mgr.getOfferById(shift.assignedOfferId)
      local vehId = offer and offer.spawned and offer.vehicle and offer.vehicle.vehId
      return vehId and getObjectByID(vehId) and vehId or nil
    end
    for _, id in ipairs(shift.personalVehicleId and {shift.personalVehicleId} or shift.issuedInventoryIds or {}) do
      local candidateId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(id)
      local info = overhaul_career_garage_inventory.getVehicles()[id]
      if candidateId and getObjectByID(candidateId) and not inputs.equipment.isCompanyTrailer(info, candidateId) then
        return candidateId, id
      end
    end
  end

  api.requestNextAssignmentEntry = function(transition, vehId, inventoryId)
    transition.enterAttempts = (transition.enterAttempts or 0) + 1
    shared.shiftLog("next assignment", string.format("enter vehicle %s attempt %d", tostring(vehId), transition.enterAttempts))
    if transition.enterAttempts == 1 and inventoryId then
      overhaul_career_garage_inventory.enterVehicle(inventoryId)
      return
    end
    if gameplay_walk then require("overhaul/lib/avatar/walkTarget").leaveWalkingModeForced(gameplay_walk) end
    be:enterVehicle(0, getObjectByID(vehId))
  end

  api.stepRetryDue = function(transition, dt)
    transition.stepWait = (transition.stepWait or 0) + dt
    if transition.stepWait < (transition.nextRetryAt or 0) then return false end
    transition.nextRetryAt = transition.stepWait + runtime.NEXT_ASSIGNMENT_RETRY_S
    return true
  end

  local function timeOutNextAssignment(transition)
    local label = runtime.NEXT_ASSIGNMENT_STEP_LABELS[transition.step] or "preparing the job"
    shared.shiftLog("next assignment", string.format("timed out while %s", label))
    inputs.routing.handleAssignmentStartFailure("Assignment preparation timed out while " .. label .. ".", {spawnFallbackAttempted = true})
  end

  -- Steps 8-13: returns true while the player is still being put into the company vehicle.
  local function tickEquipmentPhase(transition, shift, dt)
    if state.companyEquipmentHandoff then
      api.setNextAssignmentStep(transition, "returnEquipment")
      return true
    end
    if shift.spawnBlocked then
      inputs.routing.handleAssignmentStartFailure("The company vehicle parking area is blocked.")
      return true
    end
    if transition.equipmentShift ~= shift and transition.readyShift ~= shift then
      api.setNextAssignmentStep(transition, "spawn")
      return true
    end
    local vehId, inventoryId = api.nextAssignmentVehicle(shift)
    if not vehId then
      api.setNextAssignmentStep(transition, "spawn")
      return true
    end
    if be:getPlayerVehicleID(0) ~= vehId then
      api.setNextAssignmentStep(transition, "enter")
      transition.settled = 0
      if api.stepRetryDue(transition, dt) then
        api.requestNextAssignmentEntry(transition, vehId, inventoryId)
      end
      return true
    end
    shift.awaitingCompanyVehicleEntry = nil
    return false
  end

  local function tickCargoWait(transition, shift, dt)
    api.setNextAssignmentStep(transition, "load")
    transition.cargoWait = (transition.cargoWait or 0) + dt
    local limit = runtime.bindAssignedInFlight and runtime.NEXT_ASSIGNMENT_CARGO_QUERY_TIMEOUT_S or runtime.NEXT_ASSIGNMENT_RETRY_S
    if transition.cargoWait >= limit then
      transition.cargoWait = 0
      if runtime.bindAssignedInFlight then
        shared.shiftLog("next assignment", "cargo container query timed out; retrying")
        runtime.bindAssignedInFlight = false
      end
      shift.parcelLoadRetryAt = nil
      inputs.parcelLoading.bindAssignedCargoToIssuedTruck()
    end
  end

  -- Steps 14-17: returns true while deferred work, repo pickup or cargo still holds the transition.
  local function tickLoadPhase(transition, shift, dt)
    if transition.deferredWork then
      local job = transition.deferredWork
      transition.deferredWork = nil
      api.setNextAssignmentStep(transition, "load")
      inputs.routing.activateAssignedWork(job)
      return true
    end
    if shared.kindPolicy(shift.jobKind).repossession then
      local repo = shared.repoJob()
      if not (repo and repo.isEmploymentPickupReady()) then
        api.setNextAssignmentStep(transition, "prepare")
        return true
      end
      api.markNextAssignmentReady(shift)
    end
    if runtime.bindAssignedInFlight or shift.parcelLoadPending then
      tickCargoWait(transition, shift, dt)
      return true
    end
    transition.cargoWait = 0
    if transition.readyShift ~= shift then
      api.setNextAssignmentStep(transition, shared.kindPolicy(shift.jobKind).parcels and "load" or "prepare")
      return true
    end
    return false
  end

  -- Steps 18-19: once the settle time passes, route the player and close the transition.
  local function finishNextAssignmentIfSettled(transition, shift, dt)
    api.setNextAssignmentStep(transition, "settle")
    transition.settled = (transition.settled or 0) + dt
    if transition.settled < runtime.NEXT_ASSIGNMENT_SETTLE_S then return end
    inputs.routing.routeCurrentAssignment()
    effects.refreshActiveTaskGuidance()
    if state.shift ~= shift or runtime.nextAssignmentTransition ~= transition then return end
    inputs.persistence.saveEmploymentProgress()
    api.finishNextAssignmentTransition()
    ui_message(shift.outboundLabel or "Next assignment ready.", 6, "info")
  end

  -- Per-frame update -------------------------------------------------------------------------------

  api.tickNextAssignmentTransition = function(dtReal, _dtSim)
    local transition = runtime.nextAssignmentTransition
    if not transition then return end
    if state.employerOrgId ~= transition.employerOrgId then
      api.finishNextAssignmentTransition()
      return
    end
    local dt = tonumber(dtReal) or 0
    transition.elapsed = transition.elapsed + dt
    local shift = state.shift
    if transition.elapsed >= runtime.NEXT_ASSIGNMENT_TIMEOUT_S then
      timeOutNextAssignment(transition)
      return
    end
    if transition.step == "screen" or not shift then return end
    if tickEquipmentPhase(transition, shift, dt) or tickLoadPhase(transition, shift, dt) then return end
    finishNextAssignmentIfSettled(transition, shift, dt)
  end
end

-- Constructor ------------------------------------------------------------------------------------

function part.new(inputs)
  local api = inputs.api or {}

  addKindContextApi(api, inputs)
  local beginAssignment = newBeginAssignment(api, inputs)
  addNextAssignmentStartApi(api, inputs)
  addGuidedStartApi(api, inputs, beginAssignment)
  addShiftStartApi(api, inputs)
  addStartWithJobApi(api, inputs)
  addNextRunApi(api, inputs)
  addShiftActionApi(api, inputs)
  return api
end

return part
