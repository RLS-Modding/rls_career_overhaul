-- Dyno pulls: screen state, recording, saved results and service transitions.
-- Map: Session data for the HUD and UI; Saved pulls; HUD and pull start; Tuning and maintenance from the bay; Pull samples and results.

local lib = {}
local vehicleCommands = require("overhaul/lib/vehicles/vehicleCommands")

-- Reasons the vehicle reports while a pull is still settling; they are not rejected samples.
local EXPECTED_EXCLUSION_REASONS = {
  waitingForStableGear = true, waitingForThrottle = true, finishing = true, startBuffer = true,
  pendingBuffer = true, endBuffer = true, limiterBuffer = true, incompleteWindow = true,
}

function lib.create(inputs)
  local parts = inputs.parts
  local dynoState = inputs.dynoState
  local dynoSession = inputs.dynoSession

  local resultSource, resultSavedId, resultSummary
  local resultRevision = 0

  local function currentResultForUi()
    local result = dynoSession.result
    local savedId = result and result.savedPullId
    if result ~= resultSource or savedId ~= resultSavedId then
      resultSource, resultSavedId = result, savedId
      resultSummary = parts.history.pullSummaryForUi(result)
      resultRevision = resultRevision + 1
    end
    return resultSummary
  end

  -- Session data for the HUD and UI -------------------------------------------------------------------

  -- The vehicle the offer is about: the live car in the bay, or the session's own car once a session runs.
  local function sessionVehicleContext()
    if not dynoSession.active then
      return parts.vehicle.getCurrentVehicleContext()
    end
    local vehicles = overhaul_career_garage_inventory.getVehicles()
    local vehicleData = dynoSession.inventoryId and vehicles[dynoSession.inventoryId] or nil
    return {
      inventoryId = dynoSession.inventoryId,
      vehicleData = vehicleData,
      vehicleName = parts.vehicle.buildVehicleName(vehicleData, dynoSession.inventoryId)
    }
  end

  local function supportStateFor(context, contextError, ownershipReady, repairQuote)
    local supportState = {
      supported = context ~= nil,
      reason = contextError
    }

    if not ownershipReady then
      supportState.reason = supportState.reason or "Business ownership is still loading."
    elseif context and repairQuote and not repairQuote.ok then
      supportState.supported = false
      supportState.reason = repairQuote.message
    elseif context then
      supportState.reason = nil
    end
    return supportState
  end

  -- Only the pulls left matter to the offer; an unlimited business never runs out.
  local function pullsRemainingFor(policy, pullsUsed)
    return policy.unlimitedPulls and 0 or math.max(0, inputs.SESSION_PULL_LIMIT - pullsUsed)
  end

  local function repairQuoteForUi(quote, ownershipReady, offerTotal)
    return quote and quote.ok and {
      baseCost = quote.baseCost,
      laborMultiplier = quote.laborMultiplier,
      repairCost = quote.repairCost,
      dynoFee = ownershipReady and quote.dynoFee or 0,
      totalCost = offerTotal,
      revision = quote.revision,
      selectedCount = quote.selectedCount or 0,
      damageLines = quote.damageLines or {}
    } or nil
  end

  local function selectedHubForUi(active)
    local selectedHubId = dynoSession.selectedHubId or inputs.DEFAULT_DYNO_HUB_ID
    if not parts.hubs.isDynoHubAvailable(selectedHubId) then
      selectedHubId = inputs.DEFAULT_DYNO_HUB_ID
      if not active then
        dynoSession.selectedHubId = selectedHubId
      end
    end
    return selectedHubId
  end

  local function prepareSessionUi(liveOnly)
    liveOnly = liveOnly == true
    local policy = parts.history.currentPolicy()
    local ownershipReady = policy.ownershipReady ~= false
    local context, contextError = sessionVehicleContext()

    local currentPhase = dynoSession.phase or "offer"
    local active = dynoSession.active and true or false
    local sessionBusy = currentPhase == "inspecting" or currentPhase == "starting" or currentPhase == "leaving"
      or #dynoState.ownershipWaitCallbacks > 0
    local result = currentResultForUi()
    local pullsUsed = math.max(0, math.floor(tonumber(dynoSession.pullsUsed) or 0))
    local pullsRemaining = pullsRemainingFor(policy, pullsUsed)
    local inventoryId = context and context.inventoryId or nil
    local readiness = not active and parts.vehicle.startReadinessMessage(context) or nil
    if readiness then sessionBusy = true end
    if not active and not readiness and (dynoSession.error == "Damage capture unavailable"
      or dynoSession.error == "Your vehicle is still being restored. Please wait.") then
      dynoSession.error, dynoSession.statusText = nil, nil
    end
    local repairQuote = nil
    if not active and inventoryId then
      repairQuote = parts.history.getRepairQuoteForUi(inventoryId)
    end
    local repairRequired = repairQuote and repairQuote.ok and repairQuote.required or false
    local offerTotal = (ownershipReady and (repairRequired and repairQuote.totalCost or policy.fee)) or 0
    local serviceAvailable = active and not dynoSession.serviceOpen and
                               (currentPhase == "ready" or currentPhase == "complete")
    local supportState = supportStateFor(context, contextError, ownershipReady, repairQuote)
    local hubOptions = (not liveOnly) and parts.hubs.getDynoHubOptionsForUi() or nil
    local selectedHubId = selectedHubForUi(active)
    local pullState = dynoSession.pullState

    return {
      readiness = readiness,
      liveOnly = liveOnly,
      policy = policy,
      ownershipReady = ownershipReady,
      context = context,
      currentPhase = currentPhase,
      active = active,
      sessionBusy = sessionBusy,
      result = result,
      pullsUsed = pullsUsed,
      pullsRemaining = pullsRemaining,
      inventoryId = inventoryId,
      repairQuote = repairQuote,
      repairRequired = repairRequired,
      offerTotal = offerTotal,
      serviceAvailable = serviceAvailable,
      supportState = supportState,
      hubOptions = hubOptions,
      selectedHubId = selectedHubId,
      pullState = pullState,
    }
  end

  dynoState.requestSessionData = function(liveOnly)
    local view = prepareSessionUi(liveOnly)
    return {
      fee = view.ownershipReady and view.policy.fee or 0,
      feePaid = dynoSession.feePaid or 0,
      ownerBenefit = view.ownershipReady and view.policy.ownerBenefit or false,
      unlimitedPulls = view.ownershipReady and view.policy.unlimitedPulls or false,
      ownershipReady = view.ownershipReady,
      pullLimit = (view.ownershipReady and view.policy.unlimitedPulls) and 0 or inputs.SESSION_PULL_LIMIT,
      pullsUsed = view.pullsUsed,
      pullsRemaining = view.pullsRemaining,
      triggerActive = dynoState.playerInsideTrigger,
      active = view.active,
      phase = view.currentPhase,
      inventoryId = view.inventoryId,
      vehicleName = view.context and view.context.vehicleName or "Current Vehicle",
      selectedHubId = view.selectedHubId,
      hubOptions = view.hubOptions,
      repairRequired = view.repairRequired,
      repairQuote = repairQuoteForUi(view.repairQuote, view.ownershipReady, view.offerTotal),
      canPay = view.ownershipReady and parts.history.canPayAmount(view.offerTotal) or false,
      canStart = view.ownershipReady and (not view.active) and (not view.repairRequired) and (not view.sessionBusy)
        and dynoState.playerInsideTrigger and view.supportState.supported and parts.history.canPayFee(),
      canRepairAndStart = view.ownershipReady and (not view.active) and view.repairRequired and (not view.sessionBusy)
        and dynoState.playerInsideTrigger and view.supportState.supported and parts.history.canPayAmount(view.offerTotal),
      canRetry = view.active and view.currentPhase == "complete" and (view.policy.unlimitedPulls or view.pullsRemaining > 0),
      canOpenTuning = view.serviceAvailable,
      canOpenMaintenance = view.serviceAvailable,
      serviceOpen = dynoSession.serviceOpen,
      canLeave = view.currentPhase ~= "pulling" and view.currentPhase ~= "resetting" and view.currentPhase ~= "leaving",
      support = view.supportState,
      pullInProgress = view.pullState and view.pullState.inProgress or false,
      pullStage = view.pullState and view.pullState.pullStage or nil,
      liveSample = view.pullState and parts.history.safeDeepcopy(view.pullState.liveSample) or nil,
      pullQuality = view.pullState and view.pullState.pullQuality or (view.result and view.result.pullQuality or nil),
      qualityFlags = view.pullState and parts.history.safeDeepcopy(view.pullState.qualityFlags) or (view.result and parts.history.safeDeepcopy(view.result.qualityFlags) or {}),
      acceptedSampleCount = view.pullState and view.pullState.acceptedSampleCount or (view.result and view.result.acceptedSampleCount or 0),
      rejectedSampleCount = view.pullState and view.pullState.rejectedSampleCount or (view.result and view.result.rejectedSampleCount or 0),
      savedPulls = (not view.liveOnly) and parts.history.getPullHistoryForUi(view.inventoryId) or nil,
      savedPullsRevision = dynoState.savedPullsRevision,
      liveOnly = view.liveOnly or nil,
      currentResultSaved = view.result and view.result.savedPullId ~= nil or false,
      waitingForVehicle = view.readiness ~= nil,
      error = view.readiness or dynoSession.error,
      statusText = dynoSession.statusText,
      result = view.result,
      resultRevision = resultRevision
    }
  end

  local function requestResultData()
    return parts.history.pullSummaryForUi(dynoSession.result)
  end

  -- Saved pulls ------------------------------------------------------------------------------------

  -- Adds the pull to the front of the car's history and drops the oldest past the per-car limit.
  local function storeSavedPull(inventoryKey, entry)
    dynoState.pullHistoryByVehicle[inventoryKey] = dynoState.pullHistoryByVehicle[inventoryKey] or {}
    table.insert(dynoState.pullHistoryByVehicle[inventoryKey], 1, entry)
    while #dynoState.pullHistoryByVehicle[inventoryKey] > inputs.HISTORY_LIMIT_PER_VEHICLE do
      table.remove(dynoState.pullHistoryByVehicle[inventoryKey])
    end
  end

  local function saveCurrentPull()
    if not dynoSession.active or dynoSession.phase ~= "complete" or not dynoSession.result or not dynoSession.inventoryId then
      parts.vehicle.setDynoError("Complete a dyno pull before saving it.", dynoSession.phase)
      return false
    end

    if dynoSession.result.savedPullId then
      return true
    end

    parts.history.ensurePullHistoryLoaded()
    local inventoryKey = tostring(dynoSession.inventoryId)
    local vehicleData = overhaul_career_garage_inventory.getVehicles()[dynoSession.inventoryId]
    local entry = parts.history.safeDeepcopy(dynoSession.result)
    entry.liveSample = nil
    entry.id = dynoState.nextPullHistoryId
    entry.savedAt = os.time()
    entry.inventoryId = inventoryKey
    entry.vehicleName = parts.vehicle.buildVehicleName(vehicleData)
    entry.hubId = dynoSession.selectedHubId

    dynoState.nextPullHistoryId = dynoState.nextPullHistoryId + 1
    storeSavedPull(inventoryKey, entry)

    dynoState.savedPullsRevision = dynoState.savedPullsRevision + 1
    dynoSession.result.savedPullId = entry.id
    dynoSession.statusText = "Dyno pull saved to this car's history."
    dynoSession.error = nil
    return true
  end

  local function deleteSavedPull(pullId)
    parts.history.ensurePullHistoryLoaded()
    pullId = tonumber(pullId)
    if not pullId then
      parts.vehicle.setDynoError("The saved dyno pull could not be identified.", dynoSession.phase)
      return false
    end

    local inventoryId = dynoSession.inventoryId
    if not inventoryId then
      local context, contextError = parts.vehicle.getCurrentVehicleContext()
      if not context then
        parts.vehicle.setDynoError(contextError or "The current car could not be identified.", dynoSession.phase)
        return false
      end
      inventoryId = context.inventoryId
    end

    local inventoryKey = tostring(inventoryId)
    local entries = dynoState.pullHistoryByVehicle[inventoryKey]
    if type(entries) ~= "table" then
      parts.vehicle.setDynoError("That saved dyno pull no longer exists for this car.", dynoSession.phase)
      return false
    end

    local removedEntry = nil
    for index, entry in ipairs(entries) do
      if tonumber(entry.id) == pullId then
        removedEntry = table.remove(entries, index)
        break
      end
    end

    if not removedEntry then
      parts.vehicle.setDynoError("That saved dyno pull no longer exists for this car.", dynoSession.phase)
      return false
    end

    if #entries == 0 then
      dynoState.pullHistoryByVehicle[inventoryKey] = nil
    end

    dynoState.savedPullsRevision = dynoState.savedPullsRevision + 1
    if dynoSession.result and tonumber(dynoSession.result.savedPullId) == pullId then
      dynoSession.result.savedPullId = nil
    end
    dynoSession.statusText = "Saved dyno pull deleted."
    dynoSession.error = nil
    return true
  end

  -- HUD and pull start ---------------------------------------------------------------------------

  -- Live HUD updates are throttled to 12 a second; forced pushes always go out.
  local function pushDynoHudState(force)
    if not dynoSession.active then
      return
    end

    if not force then
      local now = os.clock()
      if dynoSession.lastHudPushTime and now - dynoSession.lastHudPushTime < 0.08 then
        return
      end
      dynoSession.lastHudPushTime = now
    else
      dynoSession.lastHudPushTime = os.clock()
    end

    guihooks.trigger("DynoSessionHudState", dynoState.requestSessionData(true))
  end

  local function sessionPullLimitReached()
    return not parts.history.currentPolicy().unlimitedPulls and (tonumber(dynoSession.pullsUsed) or 0) >= inputs.SESSION_PULL_LIMIT
  end

  local function sessionVehicleOrFinish()
    local sessionVeh = dynoSession.sessionVehicleId and getObjectByID(dynoSession.sessionVehicleId) or nil
    if not sessionVeh then
      parts.vehicle.setDynoError("The dyno vehicle is no longer available.", "offer")
      parts.setup.finishSessionRestore()
    end
    return sessionVeh
  end

  dynoState.startPull = function()
    -- The legacy Angular HUD already routes its primary action through startPull. Reusing that stable action also lets a hot-loaded HUD retry without requiring a newly registered controller method.
    if dynoSession.active and dynoSession.phase == "complete" then
      return dynoState.retryPull()
    end

    if not dynoSession.active or dynoSession.phase ~= "ready" then
      parts.vehicle.setDynoError("The dyno session is not ready for a pull yet.", dynoSession.phase)
      return false
    end

    if sessionPullLimitReached() then
      parts.vehicle.setDynoError("All three pulls in this dyno session have been used.", dynoSession.phase)
      pushDynoHudState(true)
      return false
    end

    local sessionVeh = sessionVehicleOrFinish()
    if not sessionVeh then
      return false
    end

    local pullId = string.format("%d_%d_%d", sessionVeh:getID(), os.time(), math.random(1000, 9999))
    dynoSession.pullsUsed = (tonumber(dynoSession.pullsUsed) or 0) + 1

    dynoSession.phase = "pulling"
    dynoSession.error = nil
    dynoSession.result = nil
    dynoSession.statusText = "Running dyno pull."
    dynoSession.pullState = {
      inProgress = true,
      pullId = pullId,
      pullStage = "armed",
      liveSample = nil,
      pullQuality = "warning",
      qualityFlags = {},
      acceptedSampleCount = 0,
      rejectedSampleCount = 0
    }

    parts.vehicle.setVehicleFreeze(sessionVeh, false)

    sessionVeh:queueLuaCommand(string.format([[
      extensions.load("overhaulDynoSession")
      if overhaulDynoSession and overhaulDynoSession.startPull then
        %s
      end
    ]], vehicleCommands.call("overhaulDynoSession", "startPull", pullId)))

    pushDynoHudState(true)

    return true
  end

  -- Retry: the car is moved back onto the dyno spot and the next pull is armed after a short delay.
  dynoState.retryPull = function()
    if not dynoSession.active or dynoSession.phase ~= "complete" then
      parts.vehicle.setDynoError("A completed dyno pull is required before retrying.", dynoSession.phase)
      pushDynoHudState(true)
      return false
    end

    local sessionVeh = sessionVehicleOrFinish()
    if not sessionVeh then
      return false
    end

    if sessionPullLimitReached() then
      parts.vehicle.setDynoError("All three pulls in this dyno session have been used.", "complete")
      pushDynoHudState(true)
      return false
    end

    -- Moving through the dyno parking spot performs a full physics reset while preserving the already-installed hub parts and the active career session.
    local moved, moveError = parts.vehicle.moveVehicleToDyno(sessionVeh)
    if not moved then
      parts.vehicle.setDynoError(moveError or "The dyno could not reset the vehicle for another pull.", "complete")
      pushDynoHudState(true)
      return false
    end

    parts.vehicle.setVehicleFreeze(sessionVeh, true)
    parts.vehicle.setVehicleIgnition(sessionVeh, 0)

    dynoSession.pullState = nil
    dynoSession.result = nil
    dynoSession.phase = "resetting"
    dynoSession.error = nil
    local nextPull = (tonumber(dynoSession.pullsUsed) or 0) + 1
    dynoSession.statusText = parts.history.currentPolicy().unlimitedPulls
      and string.format("Resetting the vehicle for pull %d. Unlimited pulls.", nextPull)
      or string.format("Resetting the vehicle for pull %d of %d.", nextPull, inputs.SESSION_PULL_LIMIT)
    dynoSession.retryArmDelay = 0.5
    pushDynoHudState(true)
    return true
  end

  -- Tuning and maintenance from the bay ------------------------------------------------------------

  local function canOpenSessionService()
    return dynoSession.active and not dynoSession.serviceOpen and
             (dynoSession.phase == "ready" or dynoSession.phase == "complete")
  end

  -- Hands the car to a service screen and remembers which phase to return to.
  local function enterSessionService(serviceName)
    parts.recovery.beginService()
    dynoSession.serviceOpen = serviceName
    dynoSession.resumePhase = dynoSession.phase
    parts.vehicle.hideDynoHud()
  end

  -- Undoes enterSessionService after the service refused to open, and shows the bay again.
  local function refuseSessionService(message)
    dynoSession.serviceOpen = nil
    dynoSession.resumePhase = nil
    parts.vehicle.setDynoError(message, dynoSession.phase)
    parts.vehicle.showDynoHud()
    pushDynoHudState(true)
    return false
  end

  local function openTuning()
    if not canOpenSessionService() then
      parts.vehicle.setDynoError("Tuning is only available while the dyno is idle.", dynoSession.phase)
      pushDynoHudState(true)
      return false
    end

    enterSessionService("tuning")
    local opened = overhaul_career_parts_tuning.start(dynoSession.inventoryId, nil, "dynoSession", {mode = "dyno"})
    if opened == false then
      return refuseSessionService("Engine tuning data is unavailable for this vehicle.")
    end
    return true
  end

  local function openMaintenance()
    if not canOpenSessionService() then
      parts.vehicle.setDynoError("Maintenance is only available while the dyno is idle.", dynoSession.phase)
      pushDynoHudState(true)
      return false
    end

    enterSessionService("maintenance")
    local opened = overhaul_career_maintenance_maintenanceComputer.openMenuFromComputer(
      dynoSession.inventoryId, nil, "dynoSession", {mode = "dyno"})
    if not opened then
      return refuseSessionService("Powertrain maintenance is unavailable while maintenance mode is disabled.")
    end
    return true
  end

  -- Puts the car back on the dyno spot after tuning or maintenance; returns whether it could move.
  local function returnServicedVehicleToDyno(currentVeh, currentVehId)
    dynoSession.sessionVehicleId = currentVehId
    parts.setup.refreshVehiclePartVisibility(currentVehId)
    parts.setup.beginTireProtection(dynoSession.inventoryId)
    local moved, moveError = parts.vehicle.moveVehicleToDyno(currentVeh)
    if not moved then
      parts.vehicle.setDynoError(moveError or "The vehicle could not be returned to the dyno.", dynoSession.phase)
      return false
    end

    parts.vehicle.protectDynoSteering(currentVeh)
    parts.vehicle.setVehicleFreeze(currentVeh, true)
    parts.vehicle.setVehicleIgnition(currentVeh, 0)
    be:enterVehicle(0, currentVeh)
    parts.vehicle.refreshDynoCamera(currentVeh)
    dynoSession.error = nil
    dynoSession.statusText = dynoSession.phase == "complete" and
      "Service complete. Review the result or prepare the next pull." or
      "Service complete. The dyno is ready."
    return true
  end

  local function resumeFromService()
    if not dynoSession.active or not dynoSession.inventoryId or not dynoSession.serviceOpen
      or dynoState.restoreRequest then
      return false
    end

    parts.setup.syncTunedVarsToOriginalConfig()
    local currentVehId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(dynoSession.inventoryId)
    local currentVeh = currentVehId and getObjectByID(currentVehId) or nil
    local displacedTransform = dynoState.serviceDisplacedTransform
    if not displacedTransform and currentVeh and parts.vehicle.isDisplacedFromDyno(currentVeh) then
      displacedTransform = parts.vehicle.captureVehicleTransform(currentVeh)
    end
    dynoState.serviceDisplacedTransform = nil
    dynoSession.serviceOpen = nil
    dynoSession.phase = dynoSession.resumePhase or dynoSession.phase
    dynoSession.resumePhase = nil

    if displacedTransform then
      parts.vehicle.stopVehiclePullExtension(currentVeh)
      dynoSession.statusText = "Restoring your vehicle."
      parts.setup.finishSessionRestore(displacedTransform)
      return true
    end

    if not currentVeh then
      parts.vehicle.setDynoError("The dyno vehicle could not be restored after service.", dynoSession.phase)
      parts.vehicle.showDynoHud()
      pushDynoHudState(true)
      return false
    end

    local moved = returnServicedVehicleToDyno(currentVeh, currentVehId)
    parts.vehicle.showDynoHud()
    pushDynoHudState(true)
    return moved == true
  end

  -- There is no shared service-close capability. Keep cleanup beside the existing
  -- service-open adapters: tuning owns pending previews and its async resume reply.
  local serviceClosers = {
    tuning = function()
      local service = overhaul_career_parts_tuning
      if service and service.cancelShopping then return service.cancelShopping() end
      return resumeFromService()
    end,
    maintenance = function()
      local service = overhaul_career_maintenance_maintenanceComputer
      if service and service.closeMenu then return service.closeMenu() end
      return resumeFromService()
    end,
  }
  local function closeSessionService()
    if not dynoSession.active or not dynoSession.serviceOpen or dynoState.restoreRequest then return end
    return (serviceClosers[dynoSession.serviceOpen] or resumeFromService)()
  end

  -- Pull samples and results -----------------------------------------------------------------------

  -- Copies one vehicle-side sample into the live sample the HUD shows.
  local function liveSampleFrom(sample)
    return {
      time = tonumber(sample.time) or 0,
      stage = sample.stage,
      rpm = tonumber(sample.rpm) or 0,
      gear = tonumber(sample.gear) or 0,
      throttle = tonumber(sample.throttle) or 0,
      brake = tonumber(sample.brake) or 0,
      wheelPower = tonumber(sample.wheelPower) or 0,
      wheelTorque = tonumber(sample.wheelTorque) or 0,
      rawWheelTorque = tonumber(sample.rawWheelTorque) or 0,
      flywheelPower = tonumber(sample.flywheelPower) or 0,
      flywheelTorque = tonumber(sample.flywheelTorque) or 0,
      rawWheelPowerSource = sample.rawWheelPowerSource,
      rawWheelTorqueSource = sample.rawWheelTorqueSource,
      rawFlywheelTorqueSource = sample.rawFlywheelTorqueSource,
      telemetrySource = sample.telemetrySource,
      rawGear = parts.history.safeDeepcopy(sample.rawGear),
      valid = sample.valid and true or false,
      invalidReason = sample.invalidReason
    }
  end

  -- Counts a sample as accepted or rejected; expected reasons (waiting for gear, buffers) are not rejections.
  local function countPullSample(sample)
    local pullState = dynoSession.pullState
    local expectedExclusion = EXPECTED_EXCLUSION_REASONS[sample.invalidReason] == true
    if sample.invalidReason and not expectedExclusion then
      pullState.qualityFlags[tostring(sample.invalidReason)] = true
    end

    if sample.acceptedSampleCount ~= nil then
      pullState.acceptedSampleCount = tonumber(sample.acceptedSampleCount) or 0
      pullState.rejectedSampleCount = tonumber(sample.rejectedSampleCount) or 0
    elseif sample.valid then
      pullState.acceptedSampleCount = pullState.acceptedSampleCount + 1
    else
      if sample.invalidReason and not expectedExclusion then
        pullState.rejectedSampleCount = pullState.rejectedSampleCount + 1
      end
    end
  end

  local PULL_STAGE_STATUS = {
    armed = "Dyno armed. Hold the selected high gear steady.",
    ready = "Ready. Apply at least 90% throttle to start recording.",
    recording = "Recording. Hold gear and throttle; lift below 75% to finish.",
    finishing = "Finishing dyno pull.",
  }

  local function onPullSample(sample)
    if not dynoSession.active or not dynoSession.pullState or not sample then
      return
    end

    if sample.pullId ~= dynoSession.pullState.pullId then
      return
    end

    dynoSession.pullState.liveSample = liveSampleFrom(sample)
    dynoSession.pullState.pullStage = sample.stage or dynoSession.pullState.pullStage
    countPullSample(sample)
    dynoSession.statusText = PULL_STAGE_STATUS[dynoSession.pullState.pullStage] or dynoSession.statusText

    pushDynoHudState(false)
  end

  local function cleanupIfSessionVehicleMissing()
    if not dynoSession.active then
      return
    end

    if dynoSession.phase == "starting" or dynoSession.phase == "leaving" or dynoState.restoreFailed then
      return
    end

    if not dynoSession.inventoryId then
      parts.setup.abandonSessionWithoutRestore()
      return
    end

    local currentVehId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(dynoSession.inventoryId)
    if not currentVehId then
      if dynoSession.serviceOpen then
        return
      end
      parts.vehicle.setDynoError("The dyno vehicle disappeared, so the session was cancelled.", dynoSession.phase)
      parts.setup.finishSessionRestore()
      return
    end

    dynoSession.sessionVehicleId = currentVehId
  end

  local function onVehicleConfigSnapshotReceived(callbackId, config, tireState)
    local callbackData = inputs.pendingConfigSnapshots[callbackId]
    if not callbackData then
      return
    end

    inputs.pendingConfigSnapshots[callbackId] = nil

    if callbackData.type == "startSession" then
      if not config then
        if callbackData.extraData and callbackData.extraData.prepaidFee then
          parts.history.refundAmount(callbackData.extraData.prepaidFeePaid, "Dyno setup refund", callbackData.extraData)
          callbackData.extraData.prepaidFeePaid = 0
          callbackData.extraData.prepaidFee = false
        end
        parts.vehicle.setDynoError("The dyno could not read the vehicle configuration.", "offer")
        return
      end
      parts.setup.startSessionFromSnapshot(config, callbackData.extraData, tireState)
    end
  end

  -- Builds the result the session keeps: measured data stays in, warnings included.
  local function pullResultFrom(result, pullState, quality, measurementComplete, flags)
    return {
      peakPower = tonumber(result.peakPower) or 0,
      peakTorque = tonumber(result.peakTorque) or 0,
      peakPowerRpm = tonumber(result.peakPowerRpm) or 0,
      peakTorqueRpm = tonumber(result.peakTorqueRpm) or 0,
      valid = true,
      measurementComplete = measurementComplete,
      pullQuality = quality,
      qualityFlags = flags,
      acceptedSampleCount = tonumber(result.acceptedSampleCount) or pullState.acceptedSampleCount or 0,
      rejectedSampleCount = tonumber(result.rejectedSampleCount) or pullState.rejectedSampleCount or 0,
      curve = parts.history.safeDeepcopy(result.curve) or {},
      -- Preserve measured data in current results and saved history, including warnings.
      rawSamples = parts.history.safeDeepcopy(result.rawSamples),
      averagedSamples = parts.history.safeDeepcopy(result.averagedSamples),
      averageWindow = result.averageWindow,
      endReason = result.endReason,
      cutoffTime = result.cutoffTime,
      startBuffer = result.startBuffer,
      tailBuffer = result.tailBuffer,
      liveSample = parts.history.safeDeepcopy(result.liveSample)
    }
  end

  local function onPullFinished(result)
    if not dynoSession.active or not dynoSession.pullState or not result then
      return
    end

    if dynoSession.phase == "leaving" then
      return
    end

    if result.pullId ~= dynoSession.pullState.pullId then
      return
    end

    dynoSession.pullState.inProgress = false
    local flags = dynoState.normalizeQualityFlags(result.qualityFlags)
    local measurementComplete = result.measurementComplete ~= false and result.valid ~= false
    local quality = parts.vehicle.getQualityFromFlags(flags, measurementComplete)
    if result.pullQuality == "warning" or result.pullQuality == "invalid" then quality = "warning" end
    dynoSession.result = pullResultFrom(result, dynoSession.pullState, quality, measurementComplete, flags)
    dynoSession.pullState = nil
    dynoSession.phase = "complete"
    dynoSession.statusText = quality == "clean" and (result.endReason == "revLimiter"
      and "Dyno pull complete. Release the throttle." or "Dyno pull complete.")
      or "Dyno pull complete with warnings."
    pushDynoHudState(true)
  end

  return {
    requestResultData = requestResultData,
    saveCurrentPull = saveCurrentPull,
    deleteSavedPull = deleteSavedPull,
    openTuning = openTuning,
    openMaintenance = openMaintenance,
    resumeFromService = resumeFromService,
    closeSessionService = closeSessionService,
    onPullSample = onPullSample,
    cleanupIfSessionVehicleMissing = cleanupIfSessionVehicleMissing,
    onVehicleConfigSnapshotReceived = onVehicleConfigSnapshotReceived,
    onPullFinished = onPullFinished,
  }
end

return lib
