-- Business preview sessions, fuel and condition preservation, reset and required parts.
-- Read owner inputs, replacement helpers, sessions, reset, required parts, then the returned API.
local capabilities = require("overhaul/lib/platform/capabilities")
local installer = {}

function installer.new(inputs)
  local runtime = inputs.runtime
  local sharedParts = inputs.parts

  -- Replacement ---------------------------------------------------------------------------------------

  local function getPartConditionApplyOpts(config)
    local partsTree = config and config.partsTree
    if not partsTree then
      return nil
    end
    return {
      validPartKeys = require('overhaul/lib/business/partConditions').collectPartConditionKeysFromPartsTree(partsTree),
    }
  end

  -- Only the preview receives new conditions until payment advances the paid baseline.
  local function finishPartReplaceConditionHandling(businessId, vehicleId, vehObj, config, afterDone, transaction)
    local session = sharedParts.session.getActiveSession(businessId)
    local generation = session and session.previewGeneration
    local function finishConditions(freshConditions)
      if not session or runtime.currentSession ~= session or session.discarding
        or session.previewGeneration ~= generation or (transaction and transaction.cancelled) then return end
      if type(freshConditions) ~= 'table' then
        if transaction and transaction.fail then transaction.fail('Condition read failed') end
        return
      end
      session.preview.partConditions = deepcopy(freshConditions)
      if afterDone then afterDone(freshConditions) end
    end
    if transaction and transaction.ownedBuild then
      transaction.reinitializeConditions(vehObj, sharedParts.conditions.forConfig(session, config), config,
        transaction.guard(finishConditions))
      return
    end
    sharedParts.conditions.apply(session, vehObj, config)
    core_vehicleBridge.requestValue(vehObj, function(res) finishConditions(res and res.result) end, 'getPartConditions')
  end

  -- Spawns the config over the vehicle, then puts the stored fuel back once the vehicle answers.
  local function replaceVehicleWithFuelHandling(vehObj, modelKey, config, beforeRestoreCallback, afterRestoreCallback, transaction, canContinue)
    if transaction and transaction.ownedBuild then
      return transaction.replace(vehObj, modelKey, config, beforeRestoreCallback, afterRestoreCallback)
    end
    if canContinue and not canContinue() then return end
    if not vehObj or not modelKey or not config then
      if afterRestoreCallback then
        afterRestoreCallback()
      end
      return
    end

    local vehId = vehObj:getID()
    local session = runtime.currentSession
    local generation = session and session.previewGeneration
    canContinue = canContinue or function()
      return not session or (runtime.currentSession == session and session.previewGeneration == generation)
    end
    local function replaceAfterCapture(ready)
    if not ready or not canContinue() then
      if afterRestoreCallback then afterRestoreCallback(false) end
      return
    end
    sharedParts.baseline.storeFuelLevels(vehObj, function(storedFuelLevels)
      if transaction and transaction.cancelled then return end
      if canContinue and not canContinue() then return end
      core_vehicle_manager.queueAdditionalVehicleData({ spawnWithEngineRunning = false }, vehId)
      local replaced = core_vehicles.replaceVehicle(modelKey, { config = config, keepOtherVehRotation = true }, vehObj)
      if replaced == false then
        if afterRestoreCallback then afterRestoreCallback(false) end
        return
      end

      if canContinue and not canContinue() then return end
      if beforeRestoreCallback then
        beforeRestoreCallback()
      elseif session then
        sharedParts.conditions.apply(session, vehObj, config)
      end

      core_vehicleBridge.requestValue(vehObj, function()
        if transaction and transaction.cancelled then return end
        if canContinue and not canContinue() then return end
        if canContinue then sharedParts.baseline.restoreFuelLevels(vehObj, storedFuelLevels, canContinue)
        else sharedParts.baseline.restoreFuelLevels(vehObj, storedFuelLevels) end
        if canContinue and not canContinue() then return end
        if afterRestoreCallback then
          afterRestoreCallback(true)
        end
      end, 'ping')
    end)
    end
    if session then sharedParts.conditions.capture(session, replaceAfterCapture)
    else replaceAfterCapture(true) end
  end

  local function getPersonalVehicleData(vehicleId, businessId)
    local businessComputer = capabilities.get("businessComputer")
    if businessComputer and businessComputer.getPersonalVehicleData then
      return businessComputer.getPersonalVehicleData(vehicleId, businessId)
    end
    return nil
  end

  -- Slot info keyed by slot path, and display names keyed by part name, from what the vehicle can use.
  local function partLookupTables(vehicleData)
    local slotData = {}
    local partsNiceName = {}
    for partName, partInfo in pairs(inputs.jbeamIO.getAvailableParts(vehicleData.ioCtx)) do
      local desc = partInfo.description
      partsNiceName[partName] = type(desc) == "table" and desc.description or desc
      if partInfo.slotInfoUi then
        for slotName, slotInfo in pairs(partInfo.slotInfoUi) do
          slotData["/" .. slotName .. "/"] = slotInfo
        end
      end
    end
    return slotData, partsNiceName
  end

  -- Sessions ----------------------------------------------------------------------------------------

  -- The vehicle record a preview starts from: a personal vehicle's data, or the fleet's record.
  local function previewVehicleRecord(businessId, vehicleId, isPersonal)
    if isPersonal then
      return getPersonalVehicleData(vehicleId, businessId)
    end
    return overhaul_career_business_fleet.getVehicleById(businessId, vehicleId)
  end

  -- The session a preview starts with: the saved config as both initial and preview state.
  local function newPreviewSession(businessId, vehicleId, isPersonal, vehicle, originalConfig, vehicleData)
    local slotData, partsNiceName = partLookupTables(vehicleData)
    local modelKey = vehicle.vehicleConfig.model_key or vehicle.model_key
    originalConfig = deepcopy(originalConfig)
    originalConfig.vars = tableMerge(deepcopy(vehicle.vars or {}), originalConfig.vars or {})
    for name, variable in pairs(vehicleData.vdata and vehicleData.vdata.variables or {}) do
      if originalConfig.vars[name] == nil then originalConfig.vars[name] = variable.val or variable.default end
    end
    local inventoryId = isPersonal and overhaul_career_garage_inventory.getInventoryIdFromVehicleId(
      tonumber(tostring(vehicleId):sub(10))) or nil
    local inventory = isPersonal and overhaul_career_garage_inventory.getVehicles()
    local conditions = inventory and inventory[inventoryId] and inventory[inventoryId].partConditions or vehicle.partConditions

    return {
      businessId = businessId,
      vehicleId = vehicleId,
      initial = {
        config = deepcopy(originalConfig),
        partList = sharedParts.baseline.flattenPartsTree(originalConfig.partsTree or {}),
        partConditions = deepcopy(conditions or {}),
        vars = deepcopy(originalConfig.vars),
        model = modelKey,
        vehicleId = vehicleId,
        partsNiceName = partsNiceName,
        isPersonal = isPersonal,
        inventoryId = inventoryId
      },
      preview = {
        config = deepcopy(originalConfig),
        partList = sharedParts.baseline.flattenPartsTree(originalConfig.partsTree or {}),
        partConditions = deepcopy(conditions or {}),
        model = modelKey
      },
      slotData = slotData,
      powerWeight = nil,
      operationInProgress = false,
      previewGeneration = 0,
      isPersonal = isPersonal,
      inventoryId = inventoryId
    }
  end

  local function initializePreviewVehicle(businessId, vehicleId)
    if not businessId or not vehicleId then
      return false
    end

    if not require('overhaul/lib/business/customizationAccess').allow(businessId, vehicleId) then return false end
    local current = runtime.currentSession
    if current then
      -- Explicit reentry cancels an owned build, while an unpaid discard must finish first.
      if current.buildOperation then sharedParts.buildOperation.cancelCurrent('Preview session reentered') end
      if current.discarding or current.resetInProgress then return false end
      if sharedParts.session.sessionMatches(businessId, vehicleId) then
        sharedParts.buildOperation.cancelCurrent('Preview session reentered')
        return true
      end
      sharedParts.cartBuild.clearPreviewVehicle(current.businessId)
      if runtime.currentSession then return false end
    end

    local isPersonal = sharedParts.baseline.isPersonalVehicleId(vehicleId)
    local vehicle = previewVehicleRecord(businessId, vehicleId, isPersonal)

    if not vehicle or not vehicle.vehicleConfig then
      return false
    end

    local vehObj = sharedParts.baseline.getBusinessVehicleObject(businessId, vehicleId)
    if not vehObj then
      return false
    end

    local vehId = vehObj:getID()

    local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehId)
    if not vehicleData then
      return false
    end

    local paidVehicle = vehicle
    if isPersonal then
      local inventoryId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(vehId)
      paidVehicle = overhaul_career_garage_inventory.getVehicles()[inventoryId]
    end
    local originalConfig = sharedParts.baseline.resolveBaselineVehicleConfig(paidVehicle, vehicleData, isPersonal, true)
    if not originalConfig then
      return false
    end

    sharedParts.buildOperation.cancelCurrent('Preview session replaced')
    runtime.currentSession = newPreviewSession(businessId, vehicleId, isPersonal, vehicle, originalConfig, vehicleData)
    return true
  end

  local function ensureActiveSession(businessId, vehicleId)
    local session = sharedParts.session.getActiveSession(businessId)
    if session and (session.discarding or session.resetInProgress) then return nil end
    if session and (not vehicleId or tostring(session.vehicleId) == tostring(vehicleId)) then
      return session
    end
    if vehicleId and initializePreviewVehicle(businessId, vehicleId) then
      return runtime.currentSession
    end
    return nil
  end

  local function getActiveSessionConfig(session)
    if not session then
      return nil
    end
    local prev = session.preview and session.preview.config
    if prev and prev.partsTree then
      return prev
    end
    local ini = session.initial and session.initial.config
    if ini and ini.partsTree then
      return ini
    end
    return prev or ini
  end

  local function mergePreviewTuningVarsIntoConfig(destConfig, session)
    if not destConfig or not session or not session.preview or not session.preview.config then
      return
    end
    local previewVars = session.preview.config.vars
    if previewVars then
      destConfig.vars = deepcopy(previewVars)
    end
  end

  local function emergencyRestoreBusinessVehicle(businessId, vehicleId, baselineConfig, baselinePartConditions)
    if sharedParts.baseline.isPersonalVehicleId(vehicleId) then
      return nil
    end
    local fleet = overhaul_career_business_fleet
    if not fleet or not fleet.emergencyRespawnPulledOutVehicle then
      return nil
    end
    local businessType = capabilities.get("businessComputer").getBusinessTypeForId(businessId) or "tuningShop"
    return fleet.emergencyRespawnPulledOutVehicle(businessType, businessId, vehicleId, baselineConfig, baselinePartConditions)
  end

  local function replaceOwnedBaseline(session, businessId, vehicleId, vehObj, modelKey, baselineConfig, baselinePartConditions, onComplete, transaction)
    core_jobsystem.create(transaction.guard(function(job)
      job.sleep(0.5)
      if not transaction.isCurrent() then return end
      transaction.replaceBaseline(vehObj, modelKey, baselineConfig, baselinePartConditions, transaction.guard(function()
        session.preview = {
          config = deepcopy(baselineConfig), partList = sharedParts.baseline.flattenPartsTree(baselineConfig.partsTree or {}),
          partConditions = deepcopy(baselinePartConditions or {}), model = modelKey,
        }
        transaction.captureState()
        sharedParts.baseline.requestVehiclePowerWeight(vehObj, businessId, vehicleId)
        session.operationInProgress, session.resetInProgress = false, false
        onComplete(true)
      end))
    end))
  end

  -- Respawns the vehicle on its baseline parts after a job-system delay; the busy flag clears once it settles.
  local function replaceWithBaseline(session, businessId, vehicleId, vehObj, modelKey, baselineConfig, baselinePartConditions, onComplete, transaction)
    if transaction then
      return replaceOwnedBaseline(session, businessId, vehicleId, vehObj, modelKey, baselineConfig, baselinePartConditions, onComplete, transaction)
    end
    local oldClaim = session.ownedBuildClaim
    local generation = session.previewGeneration
    local function canContinue()
      local owner = rawget(_G, 'overhaul_career_business_partCustomization')
      local predicate = type(owner) == 'table' and rawget(owner, 'hasNewerOwnedPreviewForVehicle')
      return runtime.currentSession == session and session.previewGeneration == generation
        and not (type(predicate) == 'function' and predicate(session, vehObj, oldClaim))
    end
    core_jobsystem.create(function(job)
      if not canContinue() then return end
      job.sleep(0.5)
      if not canContinue() then return end

      replaceVehicleWithFuelHandling(vehObj, modelKey, baselineConfig, function()
        if baselinePartConditions and next(baselinePartConditions) then
          require('overhaul/lib/business/partConditions').applyInitPartConditions(
            vehObj, baselinePartConditions, nil, nil, nil, getPartConditionApplyOpts(baselineConfig))
        end
      end, function(ok)
        if not canContinue() then return end
        session.operationInProgress, session.resetInProgress = false, false
        if ok == false then if onComplete then onComplete(false) end; return end
        if not sharedParts.conditions.captureCurrentBuild(session) then
          if onComplete then onComplete(false) end
          return
        end
        sharedParts.conditions.release(session)
        sharedParts.baseline.requestVehiclePowerWeight(vehObj, businessId, vehicleId)
        if not canContinue() then return end
        if onComplete then onComplete(true) end
      end, nil, canContinue)

      if not canContinue() then return end
      session.preview = {
        config = deepcopy(baselineConfig),
        partList = sharedParts.baseline.flattenPartsTree(baselineConfig.partsTree or {}),
        partConditions = deepcopy(baselinePartConditions or {}),
        model = modelKey
      }
    end)
  end

  -- Marks the session busy and reads what the baseline replace loads; nil (busy flag cleared) when there is no model.
  local function baselineReplaceFor(businessId, vehicleId, session)
    session.operationInProgress = true

    local baselineConfig = deepcopy(session.initial.config)
    local modelKey = session.initial.model
    local vehicle = overhaul_career_business_fleet.getVehicleById(businessId, vehicleId) or nil

    if not modelKey and vehicle and vehicle.vehicleConfig then
      modelKey = vehicle.vehicleConfig.model_key or vehicle.model_key
    end
    if not modelKey then
      session.operationInProgress = false
      return nil
    end

    local baselinePartConditions = deepcopy(session.initial.partConditions or {})
    if (not next(baselinePartConditions)) and vehicle and vehicle.partConditions then
      baselinePartConditions = deepcopy(vehicle.partConditions)
    end
    return modelKey, baselineConfig, baselinePartConditions
  end

  -- The vehicle to reset: the live one, else the one the emergency restore respawns.
  local function vehicleForReset(businessId, vehicleId, session)
    local vehObj = sharedParts.baseline.getBusinessVehicleObject(businessId, vehicleId)
    if vehObj then
      return vehObj
    end
    local restoreConfig, restorePartConditions = sharedParts.baseline.resolveRestoreBaseline(businessId, vehicleId, session)
    return emergencyRestoreBusinessVehicle(businessId, vehicleId, restoreConfig, restorePartConditions)
  end

  local function resetVehicleToOriginal(businessId, vehicleId, onComplete, transaction)
    if not businessId or not vehicleId then
      return false
    end

    if transaction then transaction.captureState() end

    local session = sharedParts.session.getActiveSession(businessId) or ensureActiveSession(businessId, vehicleId)
    if not session or not session.initial or not session.initial.config then
      return false
    end
    if tostring(session.vehicleId) ~= tostring(vehicleId) or session.resetInProgress then return false end
    if session.operationInProgress then
      if sharedParts.baseline.getBusinessVehicleObject(businessId, vehicleId) then
        return false
      end
      session.operationInProgress = false
    end

    local baselineParts = session.initial.partList or sharedParts.baseline.flattenPartsTree(session.initial.config.partsTree or {})
    local previewDiffers = sharedParts.baseline.sessionPreviewDiffersFromInitial(session)

    local vehObj = vehicleForReset(businessId, vehicleId, session)
    if not vehObj then
      return false
    end

    if not previewDiffers and sharedParts.baseline.liveVehicleMatchesBaseline(vehObj, baselineParts, session.initial.vars)
      and (not transaction or transaction.baselineMatches(vehObj, session.initial.config)) then
      session.preview = {
        config = deepcopy(session.initial.config),
        partList = deepcopy(baselineParts),
        partConditions = deepcopy(session.initial.partConditions or {}),
        model = session.initial.model
      }
      if transaction then transaction.captureState() end
      sharedParts.conditions.release(session)
      if onComplete then onComplete(true) end
      return true
    end

    local modelKey, baselineConfig, baselinePartConditions = baselineReplaceFor(businessId, vehicleId, session)
    if not modelKey then
      return false
    end

    session.resetInProgress = true
    replaceWithBaseline(session, businessId, vehicleId, vehObj, modelKey, baselineConfig, baselinePartConditions, onComplete, transaction)
    return true
  end

  -- Part application --------------------------------------------------------------------------------

  local function partsBySlotPathFrom(parts)
    local partsBySlotPath = {}
    for _, part in ipairs(parts) do
      if part.partName and part.slotPath then
        partsBySlotPath[part.slotPath] = {
          partName = part.partName,
          slotPath = part.slotPath
        }
      end
    end
    return partsBySlotPath
  end

  local function applyPartsToVehicle(businessId, vehicleId, parts)
    if not businessId or not vehicleId or not parts then
      return false
    end

    local vehObj = sharedParts.baseline.getBusinessVehicleObject(businessId, vehicleId)
    if not vehObj then
      return false
    end

    local vehicle = overhaul_career_business_fleet.getVehicleById(businessId, vehicleId)
    if not vehicle or not vehicle.vehicleConfig then
      return false
    end

    local modelKey = vehicle.vehicleConfig.model_key or vehicle.model_key
    if not modelKey then
      return false
    end

    local session = ensureActiveSession(businessId, vehicleId)
    if not session or session.operationInProgress then
      return false
    end

    local initialVehicle = session.initial
    if not initialVehicle or not initialVehicle.config then
      return false
    end

    local completeConfig = deepcopy(initialVehicle.config)
    mergePreviewTuningVarsIntoConfig(completeConfig, session)
    sharedParts.baseline.applyPartsBySlotPath(completeConfig.partsTree, partsBySlotPathFrom(parts))

    session.operationInProgress = true
    session.previewGeneration = (session.previewGeneration or 0) + 1
    session.replacementParts = deepcopy(parts)
    session.preview = {
      config = completeConfig,
      partList = sharedParts.baseline.flattenPartsTree(completeConfig.partsTree or {}),
      partConditions = deepcopy(vehicle.partConditions or {}),
      model = modelKey
    }

    replaceVehicleWithFuelHandling(vehObj, modelKey, completeConfig, nil, function(ok)
      if ok == false then
        session.operationInProgress = false
        sharedParts.cartBuild.clearPreviewVehicle(businessId)
        return
      end
      finishPartReplaceConditionHandling(businessId, vehicleId, vehObj, completeConfig, function()
        session.operationInProgress = false
        capabilities.get("businessComputer").requestVehiclePartsTree(businessId, vehicleId)
        sharedParts.baseline.requestVehiclePowerWeight(vehObj, businessId, vehicleId)
      end)
    end)

    return true
  end

  local function buildPartsTreeFromCart(businessId, parts)
    local session = sharedParts.session.getActiveSession(businessId)
    if not session or not session.initial or not session.initial.config then
      return {}
    end

    local baselineConfig = session.initial.config
    if not baselineConfig or not baselineConfig.partsTree then
      return {}
    end

    local partsTree = deepcopy(baselineConfig.partsTree)

    if parts and #parts > 0 then
      sharedParts.baseline.applyPartsBySlotPath(partsTree, partsBySlotPathFrom(parts))
    end

    return partsTree
  end

  -- Required parts ----------------------------------------------------------------------------------

  local function getDefaultPartName(jbeamData, slotName)
    if jbeamData.slots2 then
      for _, slot in ipairs(jbeamData.slots2) do
        if slot.name == slotName and slot.default and slot.default ~= "" then
          return slot.default
        end
      end
    end
    return nil
  end

  -- A slot needs a part when it is empty, or when the part in it does not fit the slot.
  local function slotNeedsPart(ioCtx, childNode, slotInfo)
    local hasPart = childNode and childNode.chosenPartName and childNode.chosenPartName ~= ""
    if not hasPart then
      return true
    end
    local existingPartData = inputs.jbeamIO.getPart(ioCtx, childNode.chosenPartName)
    return not (existingPartData and inputs.jbeamSlotSystem.partFitsSlot(existingPartData, slotInfo))
  end

  local function getRequiredPartsForPart(businessId, vehicleId, partName, slotPath, currentPartsTree)
    if not businessId or not vehicleId or not partName or not slotPath then
      return {}
    end

    local vehObj = sharedParts.baseline.getBusinessVehicleObject(businessId, vehicleId)
    if not vehObj then
      return {}
    end

    local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehObj:getID())
    if not vehicleData or not vehicleData.ioCtx then
      return {}
    end

    local jbeamData = inputs.jbeamIO.getPart(vehicleData.ioCtx, partName)
    if not jbeamData or not jbeamData.slotInfoUi then
      return {}
    end

    local requiredParts = {}
    local availableParts = inputs.jbeamIO.getAvailableParts(vehicleData.ioCtx)

    for slotName, slotInfo in pairs(jbeamData.slotInfoUi) do
      local childPath = slotPath .. slotName .. "/"
      local childNode = sharedParts.baseline.getNodeFromSlotPath(currentPartsTree, childPath)

      if slotNeedsPart(vehicleData.ioCtx, childNode, slotInfo) then
        local defaultPartName = getDefaultPartName(jbeamData, slotName)
        if defaultPartName then
          table.insert(requiredParts, {
            partName = defaultPartName,
            slotPath = childPath,
            slotName = slotName,
            partNiceName = availableParts[defaultPartName] or defaultPartName,
            value = 0
          })

          local childTree = childNode or {
            path = childPath,
            children = {}
          }
          for _, nestedPart in ipairs(getRequiredPartsForPart(businessId, vehicleId, defaultPartName, childPath, childTree)) do
            table.insert(requiredParts, nestedPart)
          end
        end
      end
    end

    return requiredParts
  end

  local function getAllRequiredParts(businessId, vehicleId, parts, cartParts)
    if not businessId or not vehicleId or not parts then
      return {}
    end

    local currentPartsTree = buildPartsTreeFromCart(businessId, cartParts)

    local allRequiredParts = {}
    local processedParts = {}
    local requiredPartsBySlotPath = {}

    local function processPart(partName, slotPath)
      local key = partName .. "_" .. slotPath
      if processedParts[key] then
        return
      end
      processedParts[key] = true

      local required = getRequiredPartsForPart(businessId, vehicleId, partName, slotPath, currentPartsTree)
      for _, reqPart in ipairs(required) do
        local reqKey = reqPart.partName .. "_" .. reqPart.slotPath
        if not processedParts[reqKey] then
          table.insert(allRequiredParts, reqPart)
          requiredPartsBySlotPath[reqPart.slotPath] = {
            partName = reqPart.partName,
            slotPath = reqPart.slotPath
          }
          sharedParts.baseline.applyPartsBySlotPath(currentPartsTree, requiredPartsBySlotPath)
          processPart(reqPart.partName, reqPart.slotPath)
        end
      end
    end

    for _, part in ipairs(parts) do
      if part.partName and part.slotPath then
        processPart(part.partName, part.slotPath)
      end
    end

    return allRequiredParts
  end

  -- Removal ------------------------------------------------------------------------------------------

  -- Slot info for a path: the session's own record, else the unique slot of that name, else the parent part's slot.
  local function getSlotInfoForPath(session, slotPath, vehicleData)
    if not session or not slotPath or slotPath == "" then
      return nil
    end
    local slotData = session.slotData or {}
    if slotData[slotPath] then
      return slotData[slotPath]
    end
    local slotName = slotPath:match("/([^/]+)/$") or ""
    local nameMatch = nil
    local nameMatchCount = 0
    for path, info in pairs(slotData) do
      local pathSlotName = path:match("/([^/]+)/$") or ""
      if pathSlotName == slotName then
        nameMatch = info
        nameMatchCount = nameMatchCount + 1
        if nameMatchCount > 1 then
          nameMatch = nil
          break
        end
      end
    end
    if nameMatchCount == 1 then
      return nameMatch
    end
    if not vehicleData or not vehicleData.ioCtx then
      return nil
    end
    local baselineCfg = session.initial and session.initial.config
    if not baselineCfg or not baselineCfg.partsTree then
      return nil
    end
    local parentPath = slotPath:match("(.+)/[^/]+/$") or "/"
    local parentNode = sharedParts.baseline.getNodeFromSlotPath(baselineCfg.partsTree, parentPath)
    if parentNode and parentNode.chosenPartName then
      local parentJbeamData = inputs.jbeamIO.getPart(vehicleData.ioCtx, parentNode.chosenPartName)
      if parentJbeamData and parentJbeamData.slotInfoUi and parentJbeamData.slotInfoUi[slotName] then
        return parentJbeamData.slotInfoUi[slotName]
      end
    end
    return nil
  end

  local function slotAllowsRemoval(session, slotPath, vehicleData)
    if not session or not session.initial or not session.initial.partList then
      return false
    end
    local baselinePartName = session.initial.partList[slotPath]
    if not baselinePartName or baselinePartName == "" then
      return false
    end
    local slotInfo = getSlotInfoForPath(session, slotPath, vehicleData)
    if slotInfo and slotInfo.coreSlot then
      return false
    end
    return true
  end

  local function cartHasBlockedCoreRemovals(parts, session, vehicleData)
    if not parts or not session then
      return false
    end
    for _, part in ipairs(parts) do
      if part.emptyPlaceholder or part.partName == "" or not part.partName then
        if not slotAllowsRemoval(session, part.slotPath or "", vehicleData) then
          return true
        end
      end
    end
    return false
  end

  return {
    applyPartsToVehicle = applyPartsToVehicle,
    cartHasBlockedCoreRemovals = cartHasBlockedCoreRemovals,
    emergencyRestoreBusinessVehicle = emergencyRestoreBusinessVehicle,
    ensureActiveSession = ensureActiveSession,
    finishPartReplaceConditionHandling = finishPartReplaceConditionHandling,
    getActiveSessionConfig = getActiveSessionConfig,
    getAllRequiredParts = getAllRequiredParts,
    getPartConditionApplyOpts = getPartConditionApplyOpts,
    getPersonalVehicleData = getPersonalVehicleData,
    initializePreviewVehicle = initializePreviewVehicle,
    mergePreviewTuningVarsIntoConfig = mergePreviewTuningVarsIntoConfig,
    replaceVehicleWithFuelHandling = replaceVehicleWithFuelHandling,
    resetVehicleToOriginal = resetVehicleToOriginal,
    slotAllowsRemoval = slotAllowsRemoval,
  }
end

return installer
