-- Dyno setup: protect tires, inspect configurations, start sessions and restore vehicles.
-- Read the named sections below in order; the final API binds the owner's game hooks.

local lib = {}

function lib.create(inputs)
  local parts = inputs.parts
  local DEFAULT_DYNO_HUB_ID = inputs.DEFAULT_DYNO_HUB_ID
  local dynoState = inputs.dynoState
  local dynoSession = inputs.dynoSession
  local pendingConfigSnapshots = inputs.pendingConfigSnapshots

  -- Tire protection and tuned config -------------------------------------------------------------

  local function releaseRestorePause()
    if dynoState.restorePaused then
      dynoState.restorePaused = nil
      simTimeAuthority.popPauseRequest("dynoBuildRestore")
    end
  end

  local function pauseRestore()
    if not dynoState.restorePaused and simTimeAuthority and simTimeAuthority.pushPauseRequest then
      simTimeAuthority.pushPauseRequest("dynoBuildRestore")
      dynoState.restorePaused = true
    end
  end

  local function finalizeUiAfterLeave()
    releaseRestorePause()
    dynoState.garageTowTransform = nil
    parts.vehicle.resetDynoSessionState()
    parts.vehicle.closeDynoUi()
  end

  local function beginTireProtection(inventoryId, liveState)
    return overhaul_career_maintenance_tireSystem.beginDynoSession(inventoryId, liveState) == true
  end

  -- Also runs from the unload and level-end hooks and the async respawn callback, where tireSystem may be gone.
  local function endTireProtection(inventoryId)
    if not overhaul_career_maintenance_tireSystem then
      return false
    end
    return overhaul_career_maintenance_tireSystem.endDynoSession(inventoryId) == true
  end

  local function syncTunedVarsToOriginalConfig()
    if not dynoSession.inventoryId or not dynoSession.originalConfig then
      return
    end
    local vehicleData = overhaul_career_garage_inventory.getVehicles()[dynoSession.inventoryId]
    local currentVars
    -- finishSessionRestore reaches this from the unload and level-end hooks, so the tuning module stays optional.
    if dynoSession.serviceOpen == "tuning" and overhaul_career_parts_tuning then
      currentVars = overhaul_career_parts_tuning.getPurchasedVarsForInventory(dynoSession.inventoryId)
    end
    currentVars = currentVars or (vehicleData and vehicleData.config and vehicleData.config.vars or nil)
    if type(currentVars) == "table" then
      dynoSession.originalConfig.vars = parts.history.safeDeepcopy(currentVars)
    end
  end

  local function sameInventoryId(first, second)
    return first ~= nil and second ~= nil and tostring(first) == tostring(second)
  end

  local function isTransientConfigActive(targetInventoryId)
    return dynoSession.active == true and dynoSession.hubConfigApplied == true and
             sameInventoryId(targetInventoryId, dynoSession.inventoryId)
  end

  -- Inventory saves: the dyno swaps in the car's original config while a session runs. -----------

  local function buildInventorySaveOverride(originalConfig, originalPartConditions, durableVars)
    if type(originalConfig) ~= "table" then return nil end
    local result = {
      config = parts.history.safeDeepcopy(originalConfig),
      partConditions = parts.history.safeDeepcopy(originalPartConditions),
    }
    if type(durableVars) == "table" then
      result.config.vars = parts.history.safeDeepcopy(durableVars)
    end
    return result
  end

  local function getInventorySaveOverride(targetInventoryId)
    if not isTransientConfigActive(targetInventoryId) then return nil end

    local durableVars
    if dynoSession.serviceOpen == "tuning" then
      durableVars = overhaul_career_parts_tuning.getPurchasedVarsForInventory(dynoSession.inventoryId)
    end
    durableVars = durableVars or (dynoSession.originalConfig and dynoSession.originalConfig.vars)
    return buildInventorySaveOverride(
      dynoSession.originalConfig, dynoSession.originalPartConditions, durableVars)
  end

  local function applyInventorySpawnOverrides(data)
    if type(data) ~= "table" or not isTransientConfigActive(dynoSession.inventoryId) or
        type(dynoSession.originalTransform) ~= "table" then
      return false
    end
    data.spawnedPlayerVehicles = type(data.spawnedPlayerVehicles) == "table" and
                                   data.spawnedPlayerVehicles or {}
    data.spawnedPlayerVehicles[tostring(dynoSession.inventoryId)] = {
      pos = parts.history.safeDeepcopy(dynoSession.originalTransform.pos),
      rot = parts.history.safeDeepcopy(dynoSession.originalTransform.rot),
    }
    return true
  end

  local function commitTuningPurchase(targetInventoryId, purchasedVars)
    if not isTransientConfigActive(targetInventoryId) or type(purchasedVars) ~= "table" or
        type(dynoSession.originalConfig) ~= "table" then
      return false
    end
    dynoSession.originalConfig.vars = parts.history.safeDeepcopy(purchasedVars)
    return true
  end

  local function refundSetupFee(reason)
    if not dynoSession.setupFeeRefundable then
      return
    end
    dynoSession.setupFeeRefundable = false
    local paid = dynoSession.feePaid or 0
    dynoSession.feePaid = 0
    parts.history.refundAmount(paid, reason or "Dyno setup refund", dynoSession)
  end

  -- Plates and mesh visibility ---------------------------------------------------------------------

  local function rememberPlateMesh(set, mesh)
    if type(mesh) == "string" and mesh ~= "" then
      set[mesh] = true
    end
  end

  local function isPlateMeshName(meshName)
    if type(meshName) ~= "string" then return false end
    local lowered = meshName:lower()
    return lowered:find("licenseplate", 1, true) or lowered:find("licenceplate", 1, true)
  end

  local function plateMeshSet(veh, vdata)
    local set = {}
    local ok, meshes = pcall(function()
      return veh:getMeshesContainingMaterial("licenseplate")
    end)
    if ok and type(meshes) == "string" then
      for mesh in meshes:gmatch("%S+") do
        rememberPlateMesh(set, mesh)
      end
    end
    local function consider(entry)
      if type(entry) ~= "table" then return end
      local mesh = entry.mesh
      local originalMesh = entry.originalMesh
      local named = isPlateMeshName(mesh) or isPlateMeshName(originalMesh)
      if named or set[mesh] or set[originalMesh] then
        rememberPlateMesh(set, mesh)
        rememberPlateMesh(set, originalMesh)
      end
    end
    if vdata then
      for _, flexbody in pairs(vdata.flexbodies or {}) do
        consider(flexbody)
      end
      for _, prop in pairs(vdata.props or {}) do
        consider(prop)
      end
    end
    return set
  end

  local function refreshVehiclePartVisibility(vehId)
    -- Inventory respawns reuse a vehicle ID. A highlight map left on that id (engine thumbnail isolate, or the old dyno-hub pass) stores false for wheels. setNewParts copies those false entries, so drop the map first.
    core_vehicle_partmgmt.resetVehicleHighlights(false, vehId)
    core_vehicle_partmgmt.setNewParts(vehId)
    local veh = getObjectByID(vehId)
    if not veh then return end
    local vehicleData = core_vehicle_manager.getVehicleData(vehId)
    local vdata = vehicleData and vehicleData.vdata
    local plates = plateMeshSet(veh, vdata)
    local seen = {}
    local function showMesh(entry)
      if type(entry) ~= "table" then return end
      local mesh = entry.mesh
      if type(mesh) ~= "string" or mesh == "" or seen[mesh] or plates[mesh] or plates[entry.originalMesh] then return end
      if mesh == "SPOTLIGHT" or mesh == "POINTLIGHT" then return end
      seen[mesh] = true
      pcall(function() veh:setMeshAlpha(1, mesh, false) end)
    end
    if vdata then
      for _, flexbody in pairs(vdata.flexbodies or {}) do
        showMesh(flexbody)
      end
      for _, prop in pairs(vdata.props or {}) do
        showMesh(prop)
      end
    end
    -- Runs from the async respawn callback of finishSessionRestore, which the unload and level-end hooks start.
    overhaul_vehicles_licensePlates.requestRefresh(vehId)
  end

  -- Restore and leave ------------------------------------------------------------------------------

  local function restoreIsCurrent(request)
    return dynoState.restoreRequest == request and dynoSession.active
      and dynoSession.originalConfig == request.config and dynoSession.inventoryId == request.inventoryId
  end

  local function failRestore(request, reason)
    if not restoreIsCurrent(request) then return end
    releaseRestorePause()
    dynoState.restoreRequest = nil
    dynoState.restoreFailed = true
    dynoSession.pullState, dynoSession.result = nil, nil
    -- Retain protection only when this request actually began with a hub build.
    overhaul_career_garage_inventory.setTransientBuild(request.inventoryId, request.hadTransientBuild)
    parts.vehicle.setDynoError(reason or "The dyno could not restore your vehicle. Try leaving again.", "restoreFailed")
  end

  local function restoreAfterRespawn(request, transform)
    return function(success, reason)
      if not restoreIsCurrent(request) then return end
      if success == false then
        failRestore(request, reason)
        return
      end
      local inventoryId = request.inventoryId
      local restoredVehId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId)
      local restoredVeh = restoredVehId and getObjectByID(restoredVehId) or nil
      if not restoredVeh then
        failRestore(request, "The restored vehicle is unavailable. Try leaving again.")
        return
      end

      if restoredVeh then refreshVehiclePartVisibility(restoredVehId) end

      -- Keep the dyno override active while the hub vehicle is removed. Its shutdown state must not overwrite the tire snapshot. Restore and re-enable tire persistence only after the original wheels exist again.
      endTireProtection(inventoryId)

      if restoredVeh and transform then
        parts.vehicle.restoreVehicleTransform(restoredVeh, transform, true)
        parts.vehicle.setVehicleFreeze(restoredVeh, false)
        parts.vehicle.setVehicleIgnition(restoredVeh, 0)
        be:enterVehicle(0, restoredVeh)
        parts.vehicle.refreshDynoCamera(restoredVeh)
      end

      if overhaul_career_garage_inventory.completeVehiclePlacement then
        overhaul_career_garage_inventory.completeVehiclePlacement(inventoryId, restoredVehId)
      end
      parts.vehicle.releaseAllDynoSteering()
      if restoredVeh then parts.vehicle.releaseDynoSteering(restoredVeh) end
      finalizeUiAfterLeave()
    end
  end

  local function finishSessionRestore(transformOverride)
    dynoState.pendingSteeringSetup = nil
    if dynoState.restoreRequest then return end
    if not dynoSession.inventoryId then
      parts.vehicle.releaseAllDynoSteering()
      finalizeUiAfterLeave()
      return
    end

    local inventoryId = dynoSession.inventoryId
    if not transformOverride and dynoState.restoreFailed then
      local mappedId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId)
      local veh = mappedId and getObjectByID(mappedId)
      if parts.vehicle.isDisplacedFromDyno(veh) then
        transformOverride = parts.vehicle.captureVehicleTransform(veh)
      end
    end
    dynoState.restoreFailed = nil
    local request = {inventoryId = inventoryId, config = dynoSession.originalConfig, age = 0,
      hadTransientBuild = overhaul_career_garage_inventory.isTransientBuild(inventoryId)}
    dynoState.restoreRequest = request
    dynoSession.phase = "leaving"
    refundSetupFee("Dyno setup refund")
    syncTunedVarsToOriginalConfig()
    if transformOverride then dynoState.restoreTransform = parts.history.safeDeepcopy(transformOverride) end
    local transform = parts.history.safeDeepcopy(dynoState.restoreTransform or dynoSession.originalTransform)
    local originalConfig = parts.history.safeDeepcopy(dynoSession.originalConfig)

    local vehicleData = overhaul_career_garage_inventory.getVehicles()[inventoryId]
    if vehicleData and originalConfig then
      vehicleData.config = originalConfig
    end
    -- Wheels must not simulate at the anchored hub pose before final placement.
    pauseRestore()
    local ok, spawned = pcall(overhaul_career_garage_inventory.spawnVehicle, inventoryId, 2, restoreAfterRespawn(request, transform), nil, true, {
      prepareReplacement = function()
        if not restoreIsCurrent(request) then return false end
        overhaul_career_garage_inventory.setTransientBuild(inventoryId, false)
        return true
      end,
    })
    if ok then request.spawnedVehicle = spawned else failRestore(request, tostring(spawned)) end
  end

  local function tickRestore(dtReal)
    local request = dynoState.restoreRequest
    if not request then return end
    -- Readiness callbacks continue while paused; a single loading frame is not a deadline.
    local config = inputs.getRecoveryConfig()
    request.age = request.age + math.min(math.max(tonumber(dtReal) or 0, 0), config.maxRestoreTickSeconds)
    if request.age >= config.restoreTimeoutSeconds then
      failRestore(request, "Vehicle restoration timed out. Try leaving the dyno again.")
    end
  end

  -- Lifecycle hooks cannot leave callbacks owning the next career/module lifetime.
  -- Loaded-level exits request the normal replacement first. Inventory replaces a
  -- transient build synchronously; its later readiness reply must then be retired.
  local function finishSessionForTeardown(restoreWorld)
    refundSetupFee("Dyno setup refund")
    if restoreWorld and dynoSession.active then finishSessionRestore() end
    local request = dynoState.restoreRequest
    local inventoryId = dynoSession.inventoryId
    if inventoryId then
      syncTunedVarsToOriginalConfig()
      local record = overhaul_career_garage_inventory.getVehicles()[inventoryId]
      if record then
        if dynoSession.originalConfig then record.config = parts.history.safeDeepcopy(dynoSession.originalConfig) end
        if dynoSession.originalPartConditions then record.partConditions = parts.history.safeDeepcopy(dynoSession.originalPartConditions) end
      end
      if restoreWorld then
        local id = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId)
        local veh = id and getObjectByID(id)
        if veh and request and request.spawnedVehicle == veh then
          parts.vehicle.stopVehiclePullExtension(veh)
          refreshVehiclePartVisibility(id)
          parts.vehicle.restoreVehicleTransform(veh, dynoState.restoreTransform or dynoSession.originalTransform)
          parts.vehicle.setVehicleFreeze(veh, false)
        elseif veh and overhaul_career_garage_inventory.isTransientBuild(inventoryId) then
          -- A refused replacement must not leave an unprotected hub car in gameplay.
          overhaul_career_garage_inventory.removeVehicleObject(inventoryId, true)
        end
      end
      endTireProtection(inventoryId)
    end
    parts.vehicle.releaseAllDynoSteering()
    finalizeUiAfterLeave()
  end

  local function abandonSessionWithoutRestore()
    dynoState.pendingSteeringSetup = nil
    parts.vehicle.releaseAllDynoSteering()
    if dynoSession.inventoryId then
      refundSetupFee("Dyno setup refund")
      endTireProtection(dynoSession.inventoryId)
    end
    parts.vehicle.resetDynoSessionState()
    parts.vehicle.closeDynoUi()
  end

  local function leaveSession()
    if not dynoSession.active then
      abandonSessionWithoutRestore()
      return true
    end

    local mappedId = dynoSession.inventoryId and overhaul_career_garage_inventory.getVehicleIdFromInventoryId(dynoSession.inventoryId)
    local sessionVeh = mappedId and getObjectByID(mappedId) or nil
    if sessionVeh then
      parts.vehicle.stopVehiclePullExtension(sessionVeh)
    end

    dynoSession.phase = "leaving"
    dynoSession.statusText = "Restoring your vehicle."

    finishSessionRestore()
    return true
  end

  -- Starting from a config snapshot ----------------------------------------------------------------

  -- Returns the policy to use, or nil after refunding a prepaid fee and reporting why setup cannot continue.
  local function resolveSnapshotPolicy(extraData, prepaidFee, feePaid)
    local policy = extraData and extraData.policy
    if policy and policy.ownershipReady ~= false then
      return policy
    end
    local resolved, resolveError = parts.history.requireResolvedShopPolicy()
    if not resolved then
      if prepaidFee then
        parts.history.refundAmount(feePaid, "Dyno setup refund", extraData)
      end
      parts.vehicle.setDynoError(resolveError or "Business ownership is still loading.", "offer")
      return nil
    end
    if extraData then extraData.policy = resolved end
    return resolved
  end

  -- Checks everything the snapshot start needs before any money or state changes. Returns the start details, or nil and the message to show the player.
  local function checkSnapshotStart(policy, config, extraData, prepaidFee)
    if policy.mapId ~= getCurrentLevelIdentifier() then
      return nil, "The dyno location changed during setup."
    end
    local context, contextError = parts.vehicle.getCurrentVehicleContext()
    if not context then
      return nil, contextError or "The dyno session could not start."
    end

    if dynoSession.active then
      return nil, "A dyno session is already active."
    end

    if not dynoState.playerInsideTrigger or not dynoState.station
      or dynoState.station.mapId ~= getCurrentLevelIdentifier() then
      return nil, "Drive into the dyno trigger to start a session."
    end

    local repairQuote = parts.history.buildRepairQuote(context.inventoryId)
    if not repairQuote.ok then
      return nil, repairQuote.message
    end
    if repairQuote.required then
      return nil, "Repair the vehicle first to start the dyno."
    end

    if not prepaidFee and not parts.history.canPayAmount(policy.fee) then
      return nil, "You do not have enough funds for the dyno session."
    end

    if prepaidFee and extraData then context.locationId = extraData.locationId end
    local requestedHubId = extraData and extraData.hubId or DEFAULT_DYNO_HUB_ID
    if not parts.hubs.isDynoHubAvailable(requestedHubId) then
      return nil, "The selected dyno hub is not available."
    end

    local dynoConfig, dynoConfigError = parts.hubs.buildDynoConfig(config, context.vehicleId, requestedHubId)
    if not dynoConfig then
      return nil, dynoConfigError or "This vehicle is not supported by the dyno yet."
    end

    return {context = context, requestedHubId = requestedHubId, dynoConfig = dynoConfig}
  end

  -- Moves the car onto the dyno once the steering guard has acknowledged; runs from onSteeringProtectionReady.
  local function beginSteeringSetup(context)
    local originalConfig = dynoSession.originalConfig
    return function()
      overhaul_career_garage_inventory.spawnVehicle(context.inventoryId, 2, function(success, reason)
        if dynoSession.originalConfig ~= originalConfig or not dynoSession.active
          or dynoSession.phase ~= "starting" then return end
        if success == false then
          if overhaul_career_garage_inventory.isTransientBuild(context.inventoryId) then
            finishSessionRestore()
          else
            abandonSessionWithoutRestore()
          end
          parts.vehicle.setDynoError(reason or "The dyno could not spawn your vehicle.", "offer")
          return
        end
        local sessionVehId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(context.inventoryId)
        local sessionVeh = sessionVehId and getObjectByID(sessionVehId) or nil

        if not sessionVeh then
          parts.vehicle.setDynoError("The dyno could not spawn your vehicle.", "offer")
          finishSessionRestore()
          return
        end

        parts.vehicle.protectDynoSteering(sessionVeh)
        dynoSession.sessionVehicleId = sessionVehId
        refreshVehiclePartVisibility(sessionVehId)
        beginTireProtection(context.inventoryId)
        local moved, moveError = parts.vehicle.moveVehicleToDyno(sessionVeh)
        if not moved then
          parts.vehicle.setDynoError(moveError or "The dyno parking spot could not move your vehicle.", "offer")
          finishSessionRestore()
          return
        end

        parts.vehicle.setVehicleFreeze(sessionVeh, true)
        parts.vehicle.setVehicleIgnition(sessionVeh, 0)
        dynoSession.phase = "ready"
        dynoSession.setupFeeRefundable = false
        dynoSession.statusText = "Start the engine, select a high forward gear, then arm the pull."
        dynoSession.error = nil

        be:enterVehicle(0, sessionVeh)
        parts.vehicle.openDynoUi()
      end, nil, nil, {
        prepareReplacement = function()
          if dynoSession.originalConfig ~= originalConfig or dynoSession.phase ~= "starting" then return false end
          overhaul_career_garage_inventory.setTransientBuild(context.inventoryId, true)
          return true
        end,
      })
    end
  end

  -- Records the session as active and queues the steering guard before the car moves.
  local function activateSnapshotSession(start, config, policy, feePaid, prepaidFee)
    local context = start.context
    local inventoryVehicleData = context.vehicleData
    dynoSession.active = true
    dynoSession.inventoryId = context.inventoryId
    dynoSession.locationId = context.locationId or (dynoState.station and dynoState.station.id)
    dynoSession.sourceVehicleId = context.vehicleId
    dynoSession.originalTransform = parts.vehicle.captureVehicleTransform(context.veh)
    dynoSession.originalConfig = parts.history.safeDeepcopy(inventoryVehicleData.config)
    dynoSession.originalPartConditions = parts.history.safeDeepcopy(inventoryVehicleData.partConditions)
    dynoSession.originalLiveConfig = parts.history.safeDeepcopy(config)
    dynoSession.selectedHubId = start.requestedHubId
    dynoSession.hubConfigApplied = true
    dynoSession.result = nil
    dynoSession.pullState = nil
    dynoSession.pullsUsed = 0
    dynoSession.policy = policy
    dynoSession.feePaid = feePaid
    dynoSession.setupFeeRefundable = prepaidFee
    dynoSession.phase = "starting"
    dynoSession.error = nil
    dynoSession.statusText = "Moving your vehicle onto the dyno."

    inventoryVehicleData.config = start.dynoConfig

    dynoState.pendingSteeringSetup = beginSteeringSetup(context)
    dynoState.steeringSetupTimer = 0
    dynoState.steeringSetupToken = dynoState.steeringSetupToken + 1
    parts.vehicle.protectDynoSteering(context.veh, true)
  end

  local function startSessionFromSnapshot(config, extraData, tireState)
    local prepaidFee = extraData and extraData.prepaidFee == true
    local feePaid = prepaidFee and (extraData.prepaidFeePaid or 0) or 0
    local policy = resolveSnapshotPolicy(extraData, prepaidFee, feePaid)
    if not policy then
      return false
    end
    -- Transfer the pending payment token once, so cancellation cannot refund twice.
    if extraData then extraData.prepaidFeePaid = 0; extraData.prepaidFee = false end

    local function failBeforeActivation(message)
      if prepaidFee then
        parts.history.refundAmount(feePaid, "Dyno setup refund", extraData)
        feePaid = 0
        prepaidFee = false
      end
      parts.vehicle.setDynoError(message or "The dyno session could not start.", "offer")
      return false
    end

    local start, startError = checkSnapshotStart(policy, config, extraData, prepaidFee)
    if not start then
      return failBeforeActivation(startError)
    end

    if not prepaidFee then
      if not parts.history.chargeAmount(policy.fee, "Dyno session fee", {"dyno", "tuning", "buying"}, start.context) then
        return failBeforeActivation("The dyno session payment could not be processed.")
      end
      extraData = extraData or {}
      extraData.inventoryId = start.context.inventoryId
      extraData.locationId = start.context.locationId
      prepaidFee = true
      feePaid = policy.fee
    end

    if not beginTireProtection(start.context.inventoryId, tireState) then
      return failBeforeActivation("The dyno could not protect the vehicle's tire state.")
    end

    activateSnapshotSession(start, config, policy, feePaid, prepaidFee)
    return true
  end

  -- Start and repair-and-start -----------------------------------------------------------------------

  -- Shows the session is waiting on the shop or the vehicle inspection, before the deferred check runs again.
  local function markInspecting(hubId, statusText)
    dynoSession.selectedHubId = hubId
    dynoSession.phase = "inspecting"
    dynoSession.error = nil
    dynoSession.statusText = statusText
  end

  local function resumeWhenDriverStillInBay(callback)
    return function()
      if dynoState.playerInsideTrigger and dynoState.station
        and dynoState.station.mapId == getCurrentLevelIdentifier() and not dynoSession.active then
        callback()
      end
    end
  end

  -- Waits for the shop's ownership to load, then runs resume while the driver is still in the bay.
  local function deferUntilOwnershipReady(hubId, statusText, resume)
    markInspecting(hubId, statusText)
    parts.history.waitForShopOwnership(resumeWhenDriverStillInBay(resume))
  end

  -- Re-inspects the car's damage, then runs resume; returns whether the inspection was queued.
  local function deferUntilConditionsChecked(context, hubId, statusText, resume)
    markInspecting(hubId, statusText)
    return parts.vehicle.refreshLiveVehicleConditions(context, resumeWhenDriverStillInBay(resume))
  end

  -- The damage must be repaired and the driver able to pay the fee; returns the reason, or nil when clear.
  local function startBlockedMessage(context, policy)
    local repairQuote = parts.history.buildRepairQuote(context.inventoryId)
    if not repairQuote.ok then
      return repairQuote.message or "Vehicle damage could not be assessed."
    end
    if repairQuote.required then
      return "Repair first to start the dyno."
    end
    if not parts.history.canPayAmount(policy.fee) then
      return "You do not have enough funds for the dyno session."
    end
    return nil
  end

  local function requestSessionSnapshot(context, requestedHubId, policy)
    dynoSession.selectedHubId = requestedHubId
    dynoSession.phase = "starting"
    dynoSession.error = nil
    dynoSession.statusText = "Inspecting your vehicle for the dyno."

    local callbackId = inputs.requestVehicleConfigSnapshot(context.veh, "startSession", {
      inventoryId = context.inventoryId,
      locationId = context.locationId or (dynoState.station and dynoState.station.id),
      sourceVehicleId = context.vehicleId,
      hubId = requestedHubId,
      policy = policy
    })

    if not callbackId then
      parts.vehicle.setDynoError("The dyno could not inspect the vehicle configuration.", "offer")
      return false
    end

    return true
  end

  dynoState.startSession = function(hubId, conditionsFresh, ownershipFresh)
    if next(pendingConfigSnapshots) or dynoState.pendingSteeringSetup then return false end
    local context, contextError = parts.vehicle.getCurrentVehicleContext()
    if not context then
      parts.vehicle.setDynoError(contextError or "The dyno session could not start.", "offer")
      return false
    end

    if dynoSession.active then
      parts.vehicle.setDynoError("A dyno session is already active.", dynoSession.phase)
      return false
    end

    if not dynoState.playerInsideTrigger or not dynoState.station
      or dynoState.station.mapId ~= getCurrentLevelIdentifier() then
      parts.vehicle.setDynoError("Drive into the dyno trigger to start a session.", "offer")
      return false
    end

    local requestedHubId = hubId or DEFAULT_DYNO_HUB_ID
    if not parts.hubs.isDynoHubAvailable(requestedHubId) then
      parts.vehicle.setDynoError("The selected dyno hub is not available.", "offer")
      return false
    end

    if not ownershipFresh and parts.history.shopNeedsOwnershipResolution() then
      deferUntilOwnershipReady(requestedHubId, "Checking business ownership.", function()
        dynoState.startSession(requestedHubId, conditionsFresh, true)
      end)
      return true
    end

    local readiness = parts.vehicle.startReadinessMessage(context)
    if readiness then
      parts.vehicle.setDynoError(readiness, "offer")
      return false
    end

    if not conditionsFresh then
      local queued = deferUntilConditionsChecked(context, requestedHubId, "Inspecting current vehicle damage.", function()
        dynoState.startSession(requestedHubId, true, true)
      end)
      if not queued then
        parts.vehicle.setDynoError("The vehicle damage inspection is already in progress.", "inspecting")
      end
      return queued
    end

    local policy, policyError = parts.history.requireResolvedShopPolicy()
    if not policy then
      parts.vehicle.setDynoError(policyError or "Business ownership is still loading.", "offer")
      return false
    end

    local blocked = startBlockedMessage(context, policy)
    if blocked then
      parts.vehicle.setDynoError(blocked, "offer")
      return false
    end

    return requestSessionSnapshot(context, requestedHubId, policy)
  end

  -- Runs the private repair and charges it, refunding any failed work; returns the failure message or nil.
  local function payAndApplyPrivateRepair(context, repairQuote)
    if not parts.history.canPayAmount(repairQuote.totalCost) then
      parts.vehicle.setDynoError("You do not have enough funds for the private repair and dyno session.", "offer")
      return "You do not have enough funds for the private repair and dyno session."
    end
    if not parts.history.chargeAmount(repairQuote.totalCost, "Private dyno repair and session", {"dyno", "repair", "buying"}, context, "repair") then
      parts.vehicle.setDynoError("The private repair payment could not be processed.", "offer")
      return "The private repair payment could not be processed."
    end

    local applied = overhaul_career_repair_finiteDamage.applySelection(context.inventoryId, repairQuote.selectedIds)
    if not applied or not applied.ok then
      parts.history.refundAmount(repairQuote.totalCost, "Private dyno repair refund", context)
      local message = applied and applied.message or "The private repair could not be completed."
      parts.vehicle.setDynoError(message, "offer")
      return message
    end

    local failedBaseCost = 0
    for _, line in ipairs(applied.failedLines or {}) do
      failedBaseCost = failedBaseCost + (tonumber(line.cost) or 0)
    end
    local failedRefund = math.min(repairQuote.repairCost,
      math.ceil(failedBaseCost * repairQuote.laborMultiplier - 0.000001))
    if failedRefund > 0 then
      parts.history.refundAmount(failedRefund, "Private dyno repair partial refund", context)
    end
    return nil
  end

  -- Once the repair is paid, checks the car is now clear and asks for its config to start the dyno.
  local function startAfterPrivateRepair(context, requestedHubId, repairQuote, policy)
    local postRepairQuote = parts.history.buildRepairQuote(context.inventoryId)
    if not postRepairQuote.ok or postRepairQuote.required then
      parts.history.refundAmount(repairQuote.dynoFee, "Dyno session refund", context)
      parts.vehicle.setDynoError("The vehicle still needs repair. Successful work was kept and failed work was refunded.", "offer")
      return {ok = false, repaired = true, message = dynoSession.error}
    end

    dynoSession.selectedHubId = requestedHubId
    dynoSession.phase = "starting"
    dynoSession.error = nil
    dynoSession.statusText = "Private repair complete. Inspecting the vehicle for the dyno."
    local callbackId = inputs.requestVehicleConfigSnapshot(context.veh, "startSession", {
      inventoryId = context.inventoryId,
      locationId = context.locationId or (dynoState.station and dynoState.station.id),
      sourceVehicleId = context.vehicleId,
      hubId = requestedHubId,
      prepaidFee = true,
      prepaidFeePaid = repairQuote.dynoFee,
      policy = policy
    })
    if not callbackId then
      parts.history.refundAmount(repairQuote.dynoFee, "Dyno setup refund", context)
      parts.vehicle.setDynoError("The repair completed, but the dyno could not inspect the vehicle. The dyno fee was refunded.", "offer")
      return {ok = false, repaired = true, message = dynoSession.error}
    end

    return {ok = true, repaired = true, repairCost = repairQuote.repairCost, dynoFee = repairQuote.dynoFee}
  end

  dynoState.repairAndStart = function(hubId, quoteRevision, conditionsFresh, ownershipFresh)
    if next(pendingConfigSnapshots) or dynoState.pendingSteeringSetup then return {ok = false, message = "Dyno setup is already in progress."} end
    local context, contextError = parts.vehicle.getCurrentVehicleContext()
    if not context then
      parts.vehicle.setDynoError(contextError or "The dyno session could not start.", "offer")
      return {ok = false, message = dynoSession.error}
    end
    if dynoSession.active or not dynoState.playerInsideTrigger or not dynoState.station
      or dynoState.station.mapId ~= getCurrentLevelIdentifier() then
      parts.vehicle.setDynoError(dynoSession.active and "A dyno session is already active." or "Drive into the dyno trigger to start a session.", "offer")
      return {ok = false, message = dynoSession.error}
    end
    local requestedHubId = hubId or DEFAULT_DYNO_HUB_ID
    if not parts.hubs.isDynoHubAvailable(requestedHubId) then
      parts.vehicle.setDynoError("The selected dyno hub is not available.", "offer")
      return {ok = false, message = dynoSession.error}
    end

    if not ownershipFresh and parts.history.shopNeedsOwnershipResolution() then
      deferUntilOwnershipReady(requestedHubId, "Checking business ownership.", function()
        dynoState.repairAndStart(requestedHubId, quoteRevision, conditionsFresh, true)
      end)
      return {ok = true, pending = true}
    end

    local readiness = parts.vehicle.startReadinessMessage(context)
    if readiness then
      parts.vehicle.setDynoError(readiness, "offer")
      return {ok = false, message = readiness}
    end

    if not conditionsFresh then
      local queued = deferUntilConditionsChecked(context, requestedHubId, "Rechecking current vehicle damage.", function()
        dynoState.repairAndStart(requestedHubId, quoteRevision, true, true)
      end)
      if not queued then
        parts.vehicle.setDynoError("The vehicle damage inspection is already in progress.", "inspecting")
        return {ok = false, pending = true, message = dynoSession.error}
      end
      return {ok = true, pending = true}
    end

    local policy, policyError = parts.history.requireResolvedShopPolicy()
    if not policy then
      parts.vehicle.setDynoError(policyError or "Business ownership is still loading.", "offer")
      return {ok = false, message = dynoSession.error}
    end

    local repairQuote = parts.history.buildRepairQuote(context.inventoryId)
    if not repairQuote.ok then
      parts.vehicle.setDynoError(repairQuote.message or "Private repair could not be quoted.", "offer")
      return {ok = false, message = dynoSession.error}
    end
    if not repairQuote.required then
      return {ok = dynoState.startSession(requestedHubId, true, true), repaired = false}
    end
    -- Reject a changed quote until the player has seen it.
    if quoteRevision ~= nil and tostring(quoteRevision) ~= tostring(repairQuote.revision) then
      parts.vehicle.setDynoError("The repair quote changed. Review the updated price and try again.", "offer")
      return {ok = false, staleQuote = true, message = dynoSession.error}
    end
    if payAndApplyPrivateRepair(context, repairQuote) then
      return {ok = false, message = dynoSession.error}
    end

    return startAfterPrivateRepair(context, requestedHubId, repairQuote, policy)
  end

  return {
    beginGarageTow = function(vehId, transform)
      local inventory = overhaul_career_garage_inventory
      if not dynoSession.active or inventory.getVehicleIdFromInventoryId(dynoSession.inventoryId) ~= vehId then return false end
      if transform then dynoState.garageTowTransform = parts.history.safeDeepcopy(transform) end
      pauseRestore()
      return true
    end,
    cancelGarageTow = releaseRestorePause,
    beginTireProtection = beginTireProtection,
    syncTunedVarsToOriginalConfig = syncTunedVarsToOriginalConfig,
    isTransientConfigActive = isTransientConfigActive,
    buildInventorySaveOverride = buildInventorySaveOverride,
    getInventorySaveOverride = getInventorySaveOverride,
    applyInventorySpawnOverrides = applyInventorySpawnOverrides,
    commitTuningPurchase = commitTuningPurchase,
    refreshVehiclePartVisibility = refreshVehiclePartVisibility,
    finishSessionRestore = finishSessionRestore,
    finishSessionForTeardown = finishSessionForTeardown,
    tickRestore = tickRestore,
    abandonSessionWithoutRestore = abandonSessionWithoutRestore,
    leaveSession = leaveSession,
    startSessionFromSnapshot = startSessionFromSnapshot,
  }
end

return lib
