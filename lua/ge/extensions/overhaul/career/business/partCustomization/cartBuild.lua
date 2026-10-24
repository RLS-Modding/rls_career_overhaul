-- Business part-cart changes, removed-part valuation and session recovery.
-- Read owner inputs, cart rows, candidate replacement, removed-part valuation, then recovery and the returned API.
local capabilities = require("overhaul/lib/platform/capabilities")
local installer = {}

function installer.new(inputs)
  local slotLabels = require("overhaul/lib/parts/slotLabels")
  local runtime = inputs.runtime
  local jbeamIO = inputs.jbeamIO
  local sharedParts = inputs.parts

  -- Cart rows ----------------------------------------------------------------------------------------

  -- Display name for a part: its jbeam description, else its catalog entry, else its file name.
  local function partNiceNameFor(partName, jbeamData, availableParts)
    if jbeamData and jbeamData.information and jbeamData.information.description then
      local desc = jbeamData.information.description
      return type(desc) == "table" and desc.description or desc or partName
    end
    local partDescription = availableParts[partName]
    if partDescription then
      if type(partDescription) == "string" then
        return partDescription
      elseif partDescription.description then
        local desc = partDescription.description
        return type(desc) == "table" and desc.description or desc or partName
      end
    end
    return partName
  end

  -- Display name for the slot a part sits in: the parent part's slot, else the session's slot data, else the slot name.
  local function slotNiceNameFor(slotPath, slotData, actualTree, ioCtx)
    local slotName = slotPath:match("/([^/]+)/$") or ""
    local slotNiceName = ""

    local parentPath = slotPath:match("(.+)/[^/]+/$") or "/"
    local actualParentNode = sharedParts.baseline.getNodeFromSlotPath(actualTree, parentPath)
    if actualParentNode and actualParentNode.chosenPartName then
      local parentJbeamData = jbeamIO.getPart(ioCtx, actualParentNode.chosenPartName)
      local info = slotLabels.getSlotInfo(parentJbeamData, slotName)
      if info and info.description and info.description ~= "" then
        slotNiceName = slotLabels.getLabel(slotName, info)
      end
    end

    if slotNiceName == "" and slotData then
      if slotData[slotPath] and slotData[slotPath].description then
        local desc = slotData[slotPath].description
        slotNiceName = type(desc) == "table" and desc.description or desc or slotName
      end
    end

    if slotNiceName == "" then
      slotNiceName = slotName
    end
    return slotNiceName
  end

  -- Price of a part before any cart discount: its market value less a cent, times the supplier discount.
  local function partPriceFor(businessId, jbeamData, partName, vehicleModel)
    local baseValue = jbeamData.information and jbeamData.information.value or 100
    local partForValueCalc = {
      name = partName,
      value = baseValue,
      partCondition = {
        integrityValue = 1,
        odometer = 0,
        visualValue = 1
      },
      vehicleModel = vehicleModel
    }
    local price = math.max(roundNear(overhaul_career_market_valueCalculator.getPartValue(partForValueCalc), 5) - 0.01, 0)
    return price * sharedParts.baseline.getPartSupplierDiscountMultiplier(businessId)
  end

  -- One cart row for a changed slot. The part being added keeps the name, slot name and price it was given.
  local function changedPartRow(rowContext, slotPath, partInfo)
    local jbeamData = jbeamIO.getPart(rowContext.vehicleData.ioCtx, partInfo.partName)
    local partNiceName = partNiceNameFor(partInfo.partName, jbeamData, rowContext.availableParts)

    local partValue = 0
    if jbeamData then
      partValue = partPriceFor(rowContext.businessId, jbeamData, partInfo.partName, rowContext.vehicleModel)
    end

    local slotNiceName = slotNiceNameFor(slotPath, rowContext.slotData, rowContext.actualTree, rowContext.vehicleData.ioCtx)
    local canRemove = sharedParts.preview.slotAllowsRemoval(rowContext.session, slotPath, rowContext.vehicleData)

    local newPartItem = rowContext.newPartItem
    local partToAdd = rowContext.partToAdd
    local fromInventory = false
    local partId = nil
    if newPartItem.slotPath == slotPath and newPartItem.fromInventory then
      fromInventory = true
      partId = newPartItem.partId
      partValue = 0
    end

    local partData = {
      type = 'part',
      partName = partInfo.partName,
      partNiceName = partNiceName,
      slotPath = slotPath,
      slotNiceName = slotNiceName,
      price = partValue,
      canRemove = canRemove
    }

    if fromInventory then
      partData.fromInventory = true
      partData.partId = partId
    end

    if slotPath == partToAdd.slotPath then
      partData.partNiceName = partToAdd.partNiceName or partData.partNiceName
      partData.slotNiceName = partToAdd.slotNiceName or partData.slotNiceName

      if partToAdd.fromInventory then
        partData.fromInventory = true
        partData.partId = partToAdd.partId
        partData.price = 0
      else
        partData.price = partValue
      end
    end

    return partData
  end

  -- Appends a row for every changed slot to finalCart.
  local function appendChangedPartsToCart(finalCart, changedPartsMap, rowContext)
    for slotPath, partInfo in pairs(changedPartsMap) do
      table.insert(finalCart, changedPartRow(rowContext, slotPath, partInfo))
    end
  end

  -- The cart without the rows whose slots the replaced vehicle now reports as changed.
  local function cartWithoutChangedSlots(cart, changedPartsMap)
    local kept = {}
    for _, item in ipairs(cart) do
      if item.type ~= 'part' or not changedPartsMap[item.slotPath] then
        table.insert(kept, item)
      end
    end
    return kept
  end

  local function newCartPartItem(partToAdd)
    local item = {
      type = 'part',
      partName = partToAdd.partName,
      partNiceName = partToAdd.partNiceName or partToAdd.partName,
      slotPath = partToAdd.slotPath,
      slotNiceName = partToAdd.slotNiceName or "",
      price = partToAdd.price or 0
    }
    if partToAdd.fromInventory then
      item.fromInventory = true
      item.partId = partToAdd.partId
      item.price = 0
    end
    return item
  end

  -- Removes the row at the slot and any row below it (the slot's children), from the end so indexes stay valid.
  local function dropCartRowsAtSlot(cart, slotPath)
    for i = #cart, 1, -1 do
      local item = cart[i]
      if item.type == 'part' then
        if item.slotPath == slotPath or item.slotPath:match("^" .. slotPath:gsub("%-", "%%-") .. "[^/]+") then
          table.remove(cart, i)
        end
      end
    end
  end

  local function partsBySlotPathFromCart(cartRows)
    local partsBySlotPath = {}
    for _, part in ipairs(cartRows) do
      if part.type == 'part' and part.partName and part.slotPath then
        partsBySlotPath[part.slotPath] = {
          partName = part.partName,
          slotPath = part.slotPath
        }
      end
    end
    return partsBySlotPath
  end

  -- Add a part ---------------------------------------------------------------------------------------

  local function cartChangeIsCurrent(change)
    return runtime.currentSession == change.session and not change.session.discarding
      and change.session.previewGeneration == change.generation
  end

  -- Once the vehicle answers the replace, the cart is rebuilt from its live parts and the preview is updated.
  local function refreshCartFromLiveVehicle(cartChange, actualVehicleData)
    if not cartChangeIsCurrent(cartChange) then return end
    local businessId, vehicleId, session = cartChange.businessId, cartChange.vehicleId, cartChange.session
    local actualTree = actualVehicleData.config.partsTree
    local changedPartsMap = sharedParts.cart.findChangedParts(cartChange.baselineTree, actualTree, {})

    local finalCart = cartWithoutChangedSlots(cartChange.cart, changedPartsMap)
    appendChangedPartsToCart(finalCart, changedPartsMap, {
      businessId = businessId,
      session = session,
      vehicleData = cartChange.vehicleData,
      vehicleModel = cartChange.vehicleModel,
      availableParts = cartChange.availableParts,
      slotData = cartChange.slotData,
      actualTree = actualTree,
      newPartItem = cartChange.newPartItem,
      partToAdd = cartChange.partToAdd,
    })

    session.preview = {
      config = deepcopy(actualVehicleData.config),
      partList = sharedParts.baseline.flattenPartsTree(actualVehicleData.config.partsTree or {}),
      partConditions = sharedParts.conditions.forConfig(session, actualVehicleData.config),
      model = cartChange.vehicleModel
    }

    sharedParts.baseline.restoreFuelLevels(cartChange.vehObj, cartChange.storedFuelLevels)
    session.operationInProgress = false

    guihooks.trigger('businessComputer:onPartCartUpdated', {
      businessId = businessId,
      vehicleId = vehicleId,
      cart = finalCart,
      sourceCart = cartChange.sourceCart
    })

    capabilities.get("businessComputer").requestVehiclePartsTree(businessId, vehicleId)
    overhaul_career_business_vehicleTuning.clearTuningDataCache()
    sharedParts.baseline.requestVehiclePowerWeight(cartChange.vehObj, businessId, vehicleId)
  end

  -- Failed previews restore the retained paid build rather than keeping another unpaid candidate.
  local function restoreVehicleAfterFailedAdd(cartChange)
    if not cartChangeIsCurrent(cartChange) then return end
    cartChange.session.operationInProgress = false
    sharedParts.cartBuild.clearPreviewVehicle(cartChange.businessId)
  end

  -- Puts the candidate config on the vehicle, then reads the live tree back once the vehicle answers.
  local function replaceWithCandidate(cartChange, completeConfig)
    if not cartChangeIsCurrent(cartChange) then return end
    core_vehicle_manager.queueAdditionalVehicleData({ spawnWithEngineRunning = false }, cartChange.vehId)
    local replaced = core_vehicles.replaceVehicle(cartChange.vehicleModel, { config = completeConfig, keepOtherVehRotation = true }, cartChange.vehObj)
    if replaced == false then restoreVehicleAfterFailedAdd(cartChange); return end
    sharedParts.conditions.apply(cartChange.session, cartChange.vehObj, completeConfig)

    core_vehicleBridge.requestValue(cartChange.vehObj, function()
      if not cartChangeIsCurrent(cartChange) then return end
      local actualVehicleData = extensions.core_vehicle_manager.getVehicleData(cartChange.vehId)
      if not actualVehicleData or not actualVehicleData.config or not actualVehicleData.config.partsTree then
        restoreVehicleAfterFailedAdd(cartChange)
        return
      end
      refreshCartFromLiveVehicle(cartChange, actualVehicleData)
    end, 'ping')
  end

  -- Keep one cart-change snapshot so delayed replies cannot mix the old and replacement configurations.
  local function beginCartChange(businessId, vehicleId, currentCart, partToAdd, includeSourceCart)
    if not businessId or not vehicleId or not partToAdd or not partToAdd.partName or not partToAdd.slotPath then
      return nil
    end

    local session = sharedParts.preview.ensureActiveSession(businessId, vehicleId)
    if not session or session.operationInProgress or not session.initial or not session.initial.config then
      return nil
    end

    local baselineCfg = sharedParts.preview.getActiveSessionConfig(session)
    if not baselineCfg or not baselineCfg.partsTree then
      return nil
    end

    local sourceCart = includeSourceCart and deepcopy(currentCart or {}) or nil
    local cart = deepcopy(currentCart or {})
    dropCartRowsAtSlot(cart, partToAdd.slotPath)

    local vehObj = sharedParts.baseline.getBusinessVehicleObject(businessId, vehicleId)
    if not vehObj then
      return nil
    end

    local vehId = vehObj:getID()
    local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehId)
    if not vehicleData or not vehicleData.ioCtx then
      return nil
    end

    local availableParts = jbeamIO.getAvailableParts(vehicleData.ioCtx)
    local vehicleModel = vehObj:getJBeamFilename()

    local newPartItem = newCartPartItem(partToAdd)
    local tempCart = deepcopy(cart)
    table.insert(tempCart, newPartItem)
    session.replacementParts = deepcopy(tempCart)

    local rollbackCfg = sharedParts.preview.getActiveSessionConfig(session) or session.initial.config
    local completeConfig = deepcopy(rollbackCfg)
    sharedParts.baseline.applyPartsBySlotPath(completeConfig.partsTree, partsBySlotPathFromCart(tempCart))
    session.previewGeneration = (session.previewGeneration or 0) + 1
    session.operationInProgress = true

    return {
      businessId = businessId,
      vehicleId = vehicleId,
      session = session,
      generation = session.previewGeneration,
      vehObj = vehObj,
      vehId = vehId,
      vehicleData = vehicleData,
      vehicleModel = vehicleModel,
      availableParts = availableParts,
      baselineTree = baselineCfg.partsTree,
      cart = cart,
      sourceCart = sourceCart,
      slotData = session.slotData or {},
      newPartItem = newPartItem,
      partToAdd = partToAdd,
      initialConfig = deepcopy(rollbackCfg),
      completeConfig = completeConfig,
    }
  end

  local function addPartToCart(businessId, vehicleId, currentCart, partToAdd, includeSourceCart)
    local cartChange = beginCartChange(businessId, vehicleId, currentCart, partToAdd, includeSourceCart)
    if not cartChange then
      return currentCart or {}
    end

    sharedParts.conditions.capture(cartChange.session, function(ready)
      if not cartChangeIsCurrent(cartChange) then return end
      if not ready then restoreVehicleAfterFailedAdd(cartChange); return end
      sharedParts.baseline.storeFuelLevels(cartChange.vehObj, function(storedFuelLevels)
      if not cartChangeIsCurrent(cartChange) then return end
      cartChange.storedFuelLevels = storedFuelLevels
      replaceWithCandidate(cartChange, cartChange.completeConfig)
      end)
    end)

    return cartChange.cart
  end

  -- Removed parts ------------------------------------------------------------------------------------

  -- The market calculator values the removed part with its saved condition and mileage.
  local function removedPartValue(partData)
    return overhaul_career_market_valueCalculator.getPartValue(partData, true) or 0
  end

  -- The record for one removed part, shaped the way the market valuation reads it.
  local function removedPartRecord(initialVehicle, vehicle, vehicleModel, slotPath, partName)
    local partCondition = initialVehicle.partConditions and initialVehicle.partConditions[slotPath .. partName]
    if not partCondition then
      partCondition = {
        integrityValue = 1,
        visualValue = 1,
        odometer = 0
      }
    end

    return {
      name = partName,
      containingSlot = slotPath,
      slot = slotPath:match("/([^/]+)/$") or slotPath:match("/([^/]+)$") or "",
      vehicleModel = vehicleModel,
      year = vehicle.year,
      partCondition = partCondition,
      partPath = slotPath .. partName,
      rlsTireState = vehicle.rlsTireStateByPartPath and
                       deepcopy(vehicle.rlsTireStateByPartPath[slotPath .. partName]) or nil,
    }
  end

  -- Parts the session's initial config has and the preview lacks, each with its value for the sell price.
  local function findRemovedParts(businessId, vehicleId)
    if not businessId or not vehicleId then
      return {}
    end

    local session = sharedParts.session.getActiveSession(businessId)
    if not session or not session.initial or not session.preview then
      return {}
    end

    local initialVehicle = session.initial
    local previewVehicle = session.preview

    local baselinePartList = initialVehicle.partList or {}
    local finalPartList = previewVehicle.partList or {}

    local vehObj = sharedParts.baseline.getBusinessVehicleObject(businessId, vehicleId)
    if not vehObj then
      return {}
    end

    local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehObj:getID())
    if not vehicleData then
      return {}
    end

    local vehicle = overhaul_career_business_fleet.getVehicleById(businessId, vehicleId)
    if not vehicle or not vehicle.vehicleConfig then
      return {}
    end
    local vehicleModel = vehicle.vehicleConfig.model_key or vehicle.model_key

    local removedParts = {}
    for slotPath, partName in pairs(baselinePartList) do
      if partName and partName ~= "" then
        local finalPartName = finalPartList[slotPath]
        if not finalPartName or finalPartName == "" or finalPartName ~= partName then
          local partData = removedPartRecord(initialVehicle, vehicle, vehicleModel, slotPath, partName)
          partData.value = removedPartValue(partData)
          table.insert(removedParts, partData)
        end
      end
    end

    return removedParts
  end

  -- Session recovery ---------------------------------------------------------------------------------

  local function clearPreviewVehicle(businessId)
    if businessId and sharedParts.session.sessionMatches(businessId) then
      local session = runtime.currentSession
      if session.discarding and session.resetInProgress then return true end
      sharedParts.buildOperation.cancelCurrent('Preview discarded')
      session.discarding = true
      session.previewGeneration = (session.previewGeneration or 0) + 1
      session.operationInProgress = false
      session.resetInProgress = false
      local restored, accepted = pcall(sharedParts.preview.resetVehicleToOriginal, businessId, session.vehicleId, function(ok)
        if runtime.currentSession ~= session then return end
        if ok then session.discarded = true; sharedParts.session.resetCurrentSession()
        else session.operationInProgress, session.resetInProgress = false, false end
      end)
      if not restored or not accepted then
        session.operationInProgress, session.resetInProgress = false, false
        log('E', 'businessPartCustomization', 'Paid build restoration failed: ' .. tostring(accepted))
        guihooks.trigger('toastrMsg', {type = 'error', title = 'Preview could not be discarded',
          msg = 'The paid vehicle build could not be restored. Please retry before leaving the computer.'})
        return false
      end
      return true
    end
    return true
  end

  -- Puts the session's baseline back on the vehicle when the vehicle has gone missing from the world.
  local function tryEmergencyRestoreSessionVehicle(businessId, vehicleId)
    if not runtime.currentSession or not sharedParts.session.sessionMatches(businessId, vehicleId) then
      return
    end
    if sharedParts.baseline.getBusinessVehicleObject(businessId, vehicleId) then
      return
    end
    local initial = runtime.currentSession.initial
    if not initial or not initial.config then
      return
    end
    runtime.currentSession.operationInProgress = false
    local restoreConfig, restorePartConditions = sharedParts.baseline.resolveRestoreBaseline(businessId, vehicleId, runtime.currentSession)
    sharedParts.preview.emergencyRestoreBusinessVehicle(businessId, vehicleId, restoreConfig, restorePartConditions)
  end

  return {
    addPartToCart = addPartToCart,
    clearPreviewVehicle = clearPreviewVehicle,
    findRemovedParts = findRemovedParts,
    tryEmergencyRestoreSessionVehicle = tryEmergencyRestoreSessionVehicle,
  }
end

return installer
