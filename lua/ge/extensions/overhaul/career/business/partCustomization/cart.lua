-- Business part-cart application, replacement settlement and power replies.
-- Read owner inputs, selections, rollback and settlement steps, power replies, then the returned API.
local capabilities = require("overhaul/lib/platform/capabilities")
local installer = {}

function installer.new(inputs)
  local runtime = inputs.runtime
  local jbeamIO = inputs.jbeamIO
  local sharedParts = inputs.parts

  -- Cart selections ---------------------------------------------------------------------------------

  local function clearChildParts(node, path)
    if not node or not node.children then
      return
    end
    for slotName, childNode in pairs(node.children) do
      childNode.chosenPartName = ""
      if childNode.children then
        clearChildParts(childNode, path .. slotName .. "/")
      end
    end
  end

  -- Price of a part the cart adds only because another part needs it: its market value less a cent, discounted.
  local function requiredPartPrice(vehObj, reqPart, vehicleModel, discountMultiplier)
    local price = reqPart.value or 0
    if not vehObj then
      return price
    end
    local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehObj:getID())
    if not vehicleData or not vehicleData.ioCtx then
      return price
    end
    local jbeamData = jbeamIO.getPart(vehicleData.ioCtx, reqPart.partName)
    if not jbeamData then
      return price
    end

    local baseValue = jbeamData.information and jbeamData.information.value or 100
    local partForValueCalc = {
      name = reqPart.partName,
      value = baseValue,
      partCondition = {
        integrityValue = 1,
        odometer = 0,
        visualValue = 1
      },
      vehicleModel = vehicleModel
    }
    price = math.max(roundNear(overhaul_career_market_valueCalculator.getPartValue(partForValueCalc), 5) - 0.01, 0)
    return price * discountMultiplier
  end

  -- Removal markers clear their slot first; the cart's parts plus the parts they require are then priced and applied.
  local function applyCartPartSelections(businessId, vehicleId, parts, vehObj, completeConfig)
    if not parts or #parts == 0 then
      return
    end

    local removalMarkers = {}
    local partsToApply = {}
    for _, part in ipairs(parts) do
      if part.emptyPlaceholder or (part.partName == "" or not part.partName) then
        removalMarkers[part.slotPath] = part
      elseif part.partName and part.slotPath then
        table.insert(partsToApply, {
          partName = part.partName,
          slotPath = part.slotPath
        })
      end
    end

    for slotPath, _ in pairs(removalMarkers) do
      local node = sharedParts.baseline.getNodeFromSlotPath(completeConfig.partsTree, slotPath)
      if node then
        node.chosenPartName = ""
        node.emptyPlaceholder = true
        clearChildParts(node, slotPath)
      end
    end

    local requiredParts = sharedParts.preview.getAllRequiredParts(businessId, vehicleId, partsToApply, parts)

    local allParts = {}
    for _, part in ipairs(parts) do
      if part.partName and part.slotPath and part.partName ~= "" then
        allParts[part.slotPath] = part
      end
    end

    local discountMultiplier = sharedParts.baseline.getPartSupplierDiscountMultiplier(businessId)
    local vehicleModel = nil
    if vehObj then
      vehicleModel = vehObj:getJBeamFilename()
    end

    for _, reqPart in ipairs(requiredParts) do
      if not allParts[reqPart.slotPath] then
        allParts[reqPart.slotPath] = {
          partName = reqPart.partName,
          slotPath = reqPart.slotPath,
          partNiceName = reqPart.partNiceName or reqPart.partName,
          slotNiceName = reqPart.slotName or '',
          price = requiredPartPrice(vehObj, reqPart, vehicleModel, discountMultiplier)
        }
      end
    end

    sharedParts.baseline.applyPartsBySlotPath(completeConfig.partsTree, allParts)
  end

  -- Cart application -------------------------------------------------------------------------------

  -- Marks the session busy and returns it with its live vehicle; nil (and nothing marked) when the cart cannot apply.
  local function claimVehicleForCart(businessId, vehicleId)
    local session = sharedParts.preview.ensureActiveSession(businessId, vehicleId)
    if not session or session.operationInProgress then
      return nil
    end

    session.operationInProgress = true
    session.previewGeneration = (session.previewGeneration or 0) + 1

    local vehObj = sharedParts.baseline.getBusinessVehicleObject(businessId, vehicleId)
    if not vehObj then
      local restoreConfig, restorePartConditions = sharedParts.baseline.resolveRestoreBaseline(businessId, vehicleId, session)
      vehObj = sharedParts.preview.emergencyRestoreBusinessVehicle(businessId, vehicleId, restoreConfig, restorePartConditions)
    end
    if not vehObj or not session.initial or not session.initial.config then
      session.operationInProgress = false
      return nil
    end
    return session, vehObj
  end

  -- The transaction's restore: puts the initial config back over the vehicle, keeping the tuning vars given.
  local function cartRestorer(session, initialVehicle, vehObj, rollbackConfig)
    return function(tuningVars)
      session.previewGeneration = (session.previewGeneration or 0) + 1
      local restoredConfig = deepcopy(rollbackConfig)
      if tuningVars then restoredConfig.vars = deepcopy(tuningVars) end
      session.preview = {config = deepcopy(restoredConfig), partList = sharedParts.baseline.flattenPartsTree(restoredConfig.partsTree or {}),
        partConditions = deepcopy(initialVehicle.partConditions or {}), model = initialVehicle.model}
      sharedParts.preview.replaceVehicleWithFuelHandling(vehObj, initialVehicle.model, restoredConfig, function()
        require('overhaul/lib/business/partConditions').applyInitPartConditions(vehObj,
          initialVehicle.partConditions or {}, nil, nil, nil, sharedParts.preview.getPartConditionApplyOpts(restoredConfig))
      end, function(ok)
        session.operationInProgress = false
        if ok ~= false then sharedParts.conditions.captureCurrentBuild(session); sharedParts.conditions.release(session) end
      end)
    end
  end

  local function notifyCartApplyFailed(businessId, vehicleId, message, operationId)
    ui_message(message, 6, "Business Computer", "error")
    guihooks.trigger('businessComputer:onPartCartApplyFailed', {
      businessId = businessId,
      vehicleId = vehicleId,
      message = message,
      operationId = operationId
    })
  end

  -- The replace failed: puts the rollback config back on the vehicle, then reports the failure.
  local function restoreAfterFailedReplace(businessId, vehicleId, session, vehObj, initialVehicle, rollbackConfig, transaction, message, finish, operationId)
    local function restoreConditions()
      require('overhaul/lib/business/partConditions').applyInitPartConditions(vehObj,
        initialVehicle.partConditions or {}, nil, nil, nil, sharedParts.preview.getPartConditionApplyOpts(rollbackConfig))
    end
    sharedParts.preview.replaceVehicleWithFuelHandling(vehObj, initialVehicle.model, rollbackConfig, restoreConditions, function(ok)
      if transaction and transaction.cancelled then return end
      if ok == false then session.operationInProgress = false; finish(false); return end
      session.preview = {
        config = deepcopy(rollbackConfig),
        partList = sharedParts.baseline.flattenPartsTree(rollbackConfig.partsTree or {}),
        partConditions = deepcopy(initialVehicle.partConditions or {}),
        model = initialVehicle.model
      }
      session.operationInProgress = false
      sharedParts.conditions.captureCurrentBuild(session)
      sharedParts.conditions.release(session)
      notifyCartApplyFailed(businessId, vehicleId, message, operationId)
      capabilities.get("businessComputer").requestVehiclePartsTree(businessId, vehicleId)
      finish(false)
    end, transaction)
  end

  -- The live vehicle after a replace, and whether the game loaded it with a chosen part at its root.
  local function liveVehicleLoaded(businessId, vehicleId, vehObj)
    local liveVeh = sharedParts.baseline.getBusinessVehicleObject(businessId, vehicleId) or vehObj
    local liveId = liveVeh and liveVeh:getID() or nil
    local actualVehicleData = liveId and extensions.core_vehicle_manager.getVehicleData(liveId) or nil
    local loadedOk = actualVehicleData and actualVehicleData.config and actualVehicleData.config.partsTree and
      actualVehicleData.config.partsTree.chosenPartName and actualVehicleData.config.partsTree.chosenPartName ~= ""
    return liveVeh, loadedOk
  end

  -- Once the replaced vehicle has its conditions handled, the cart change is complete and the session takes the new state.
  local function finishCartChange(businessId, vehicleId, session, liveVeh, vehObj, completeConfig, transaction, finish)
    sharedParts.preview.finishPartReplaceConditionHandling(businessId, vehicleId, liveVeh or vehObj, completeConfig, function()
      if transaction and transaction.cancelled then return end
      session.operationInProgress = false
      capabilities.get("businessComputer").requestVehiclePartsTree(businessId, vehicleId)
      overhaul_career_business_vehicleTuning.clearTuningDataCache()
      sharedParts.baseline.requestVehiclePowerWeight(liveVeh or vehObj, businessId, vehicleId)
      extensions.hook("onOverhaulBusinessVehicleConfigurationChanged", businessId, vehicleId, "parts")
      finish(true)
    end, transaction)
  end

  local function cartCompletion(businessId, vehicleId, parts, onComplete, operationId)
    return function(ok)
      if ok == true and operationId then
        guihooks.trigger("businessComputer:onPartCartUpdated", {
          businessId = businessId, vehicleId = vehicleId, cart = parts, operationId = operationId
        })
      end
      if onComplete then
        onComplete(ok == true)
      end
    end
  end

  local function applyCartPartsToVehicle(businessId, vehicleId, parts, onComplete, transaction, operationId)
    local finish = cartCompletion(businessId, vehicleId, parts, onComplete, operationId)

    if not businessId or not vehicleId then
      finish(false)
      return false
    end

    local session, vehObj = claimVehicleForCart(businessId, vehicleId)
    if not session then
      finish(false)
      return false
    end

    local initialVehicle = session.initial
    session.replacementParts = deepcopy(parts or {})
    local rollbackConfig = deepcopy(initialVehicle.config)
    if transaction then
      transaction.restore = cartRestorer(session, initialVehicle, vehObj, rollbackConfig)
    end
    local completeConfig = deepcopy(initialVehicle.config)
    sharedParts.preview.mergePreviewTuningVarsIntoConfig(completeConfig, session)

    local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehObj:getID())
    if parts and #parts > 0 and sharedParts.preview.cartHasBlockedCoreRemovals(parts, session, vehicleData) then
      session.operationInProgress = false
      notifyCartApplyFailed(businessId, vehicleId, "Core parts cannot be removed from this vehicle.", operationId)
      finish(false)
      return false
    end

    applyCartPartSelections(businessId, vehicleId, parts, vehObj, completeConfig)

    local pendingPreview = {
      config = completeConfig,
      partList = sharedParts.baseline.flattenPartsTree(completeConfig.partsTree or {}),
      partConditions = deepcopy(initialVehicle.partConditions or {}),
      model = initialVehicle.model
    }

    sharedParts.preview.replaceVehicleWithFuelHandling(vehObj, initialVehicle.model, completeConfig, nil, function(ok)
      if transaction and transaction.cancelled then return end
      if ok == false then
        session.operationInProgress = false
        finish(false)
        sharedParts.cartBuild.clearPreviewVehicle(businessId)
        return
      end
      local liveVeh, loadedOk = liveVehicleLoaded(businessId, vehicleId, vehObj)
      if not loadedOk then
        restoreAfterFailedReplace(businessId, vehicleId, session, vehObj, initialVehicle, rollbackConfig, transaction,
          "That part change would make the vehicle unloadable. Change was not applied.", finish, operationId)
        return
      end

      session.preview = pendingPreview
      if transaction and transaction.ownedBuild then transaction.captureState() end
      finishCartChange(businessId, vehicleId, session, liveVeh, vehObj, completeConfig, transaction, finish)
    end, transaction)

    return true
  end

  local function installPartOnVehicle()
    return true
  end

  -- Power and weight -------------------------------------------------------------------------------

  -- Reply from the vehicle's power/weight read; a pending request names the business and vehicle it was sent for.
  local function onPowerWeightReceived(requestId, power, weight, torqueData)
    local businessId, vehicleId
    local pending = runtime.pendingPowerRequests[requestId]
    if pending then
      runtime.pendingPowerRequests[requestId] = nil
      runtime.pendingPowerRequestCount = math.max(0, runtime.pendingPowerRequestCount - 1)
      businessId, vehicleId = pending.businessId, pending.vehicleId
    else
      businessId, vehicleId = requestId:match("^(.+)_(.+)_")
    end
    if businessId and vehicleId and power and weight and weight > 0 then
      local numericVehicleId = tonumber(vehicleId)
      local result = {
        power = power,
        weight = weight,
        powerToWeight = power / weight,
        torque = torqueData
      }
      if sharedParts.session.sessionMatches(businessId, numericVehicleId or vehicleId) then
        runtime.currentSession.powerWeight = result
      end

      guihooks.trigger('businessComputer:onVehiclePowerWeight', {
        success = true,
        businessId = businessId,
        vehicleId = numericVehicleId or vehicleId,
        power = power,
        weight = weight,
        powerToWeight = result.powerToWeight,
        torque = torqueData
      })
      overhaul_career_business_racingTeam_racingTeam.notifyTeamVehicleDynoPeakHp(businessId, numericVehicleId or vehicleId, power, weight)
    end
  end

  -- A stored reading is returned; otherwise a request goes out and the caller gets nil until the reply arrives.
  local function getVehiclePowerWeight(businessId, vehicleId)
    if not businessId or not vehicleId then
      return nil
    end
    if not sharedParts.baseline.powerReadAllowed(businessId) then
      return nil
    end

    local vehObj = sharedParts.baseline.getBusinessVehicleObject(businessId, vehicleId)
    if not vehObj then
      return nil
    end

    local session = sharedParts.session.getActiveSession(businessId)
    if session and tostring(session.vehicleId) == tostring(vehicleId) and session.powerWeight then
      return session.powerWeight
    end

    sharedParts.baseline.requestVehiclePowerWeight(vehObj, businessId, vehicleId)

    return nil
  end

  -- Preview config ---------------------------------------------------------------------------------

  local function getPreviewVehicleConfig(businessId)
    local session = sharedParts.session.getActiveSession(businessId)
    if session and session.preview and not session.discarding and not session.resetInProgress then
      return session.preview.config
    end
    return nil
  end

  local function updatePreviewVehicleConfig(businessId, newConfig)
    local session = sharedParts.session.getActiveSession(businessId)
    if session and session.preview then
      session.preview.config = newConfig
      return true
    end
    return false
  end

  local function getInitialVehicleState(businessId)
    local session = sharedParts.session.getActiveSession(businessId)
    if session and session.initial and not session.discarding and not session.resetInProgress then
      return deepcopy(session.initial)
    end
    return nil
  end

  local function commitSessionInitialFromPreview(businessId, vehicleId)
    local session = sharedParts.session.getActiveSession(businessId)
    if not session or not session.preview or not session.preview.config then
      return false
    end
    if vehicleId and tostring(session.vehicleId) ~= tostring(vehicleId) then
      return false
    end

    local previewConfig = deepcopy(session.preview.config)
    previewConfig.vars = deepcopy(session.initial.vars or {})
    session.initial.config = previewConfig
    session.initial.partConditions = deepcopy(session.preview.partConditions or session.initial.partConditions or {})
    session.replacementParts = {}
    session.initial.partList = sharedParts.baseline.flattenPartsTree(previewConfig.partsTree or {})
    session.preview.config = deepcopy(session.preview.config)
    session.preview.partList = sharedParts.baseline.flattenPartsTree(session.preview.config.partsTree or {})
    local vehicle = session.isPersonal and sharedParts.preview.getPersonalVehicleData(session.vehicleId, businessId)
      or overhaul_career_business_fleet.getVehicleById(businessId, session.vehicleId)
    if vehicle then vehicle.partConditions = deepcopy(session.initial.partConditions) end
    if session.isPersonal and session.inventoryId then
      local inventory = overhaul_career_garage_inventory.getVehicles()
      if inventory and inventory[session.inventoryId] then
        inventory[session.inventoryId].partConditions = deepcopy(session.initial.partConditions)
        overhaul_career_garage_inventory.setVehicleDirty(session.inventoryId)
      end
    elseif vehicle then
      overhaul_career_business_fleet.updateVehicle(businessId, session.vehicleId, {partConditions = deepcopy(session.initial.partConditions)})
    end
    if not sharedParts.conditions.captureCurrentBuild(session) then return false end
    sharedParts.conditions.release(session)
    return true
  end

  local function commitSessionTuning(businessId, vehicleId, vars)
    local session = sharedParts.session.getActiveSession(businessId)
    if not session or tostring(session.vehicleId) ~= tostring(vehicleId) then return false end
    session.initial.vars = tableMerge(session.initial.vars or {}, deepcopy(vars))
    session.initial.config.vars = tableMerge(session.initial.config.vars or {}, deepcopy(vars))
    return sharedParts.conditions.captureCurrentBuild(session)
  end

  -- Every slot whose part differs from the baseline tree, keyed by slot path, with the part it now holds.
  local function findChangedParts(baselineTree, newTree, changedParts, path)
    changedParts = changedParts or {}
    path = path or (baselineTree and baselineTree.path) or (newTree and newTree.path) or "/"

    local baselinePart = baselineTree and baselineTree.chosenPartName or ""
    local newPart = newTree and newTree.chosenPartName or ""

    if baselinePart ~= newPart and newPart and newPart ~= "" then
      changedParts[path] = {
        partName = newPart,
        slotPath = path
      }
    end

    local baselineChildren = baselineTree and baselineTree.children or {}
    local newChildren = newTree and newTree.children or {}

    for slotName, newChild in pairs(newChildren) do
      local childPath = newChild.path or (path .. slotName .. "/")
      findChangedParts(baselineChildren[slotName], newChild, changedParts, childPath)
    end

    return changedParts
  end

  return {
    applyCartPartsToVehicle = applyCartPartsToVehicle,
    commitSessionInitialFromPreview = commitSessionInitialFromPreview,
    commitSessionTuning = commitSessionTuning,
    findChangedParts = findChangedParts,
    getInitialVehicleState = getInitialVehicleState,
    getPreviewVehicleConfig = getPreviewVehicleConfig,
    getVehiclePowerWeight = getVehiclePowerWeight,
    installPartOnVehicle = installPartOnVehicle,
    onPowerWeightReceived = onPowerWeightReceived,
    updatePreviewVehicleConfig = updatePreviewVehicleConfig,
  }
end

return installer
