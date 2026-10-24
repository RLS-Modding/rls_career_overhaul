-- Business computer cart pricing, payment, part settlement and refunds.
-- Read pricing, vehicle records, part inventory, payment, settlement, cart purchase, then balances and power.
local installer = {}

-- Each construction shares state and sibling tables with that owner load.
function installer.new(inputs)
  local api = {}
  local M = inputs.M
  local pendingCartPurchases = inputs.pendingCartPurchases
  local SALES_TAX_RATE = 0.07

  -- Pricing ----------------------------------------------------------------------------------------

  local function priceCartParts(businessId, vehicle, parts)
    local obj = inputs.parts.vehicles.getBusinessVehicleObject(businessId, vehicle.vehicleId)
    local model = obj and obj:getJBeamFilename() or
      (vehicle.vehicleConfig and vehicle.vehicleConfig.model_key) or vehicle.model_key or (vehicle.config and vehicle.config.model)
    local data = obj and extensions.core_vehicle_manager.getVehicleData(obj:getID())
    local ioCtx = data and data.ioCtx
    local loaded = false
    local subtotal = 0
    local ok, err = pcall(function()
      local slots, inventoryIds = {}, {}
      for _, part in ipairs(parts) do
        if type(part) == "table" and (part.emptyPlaceholder or part.partName == nil) then part.partName = "" end
        assert(type(part) == "table" and type(part.partName) == "string" and type(part.slotPath) == "string", "Invalid cart part")
        assert(not slots[part.slotPath], "Duplicate cart slot")
        slots[part.slotPath] = true
        local price = 0
        if part.fromInventory then
          local inventory = overhaul_career_business_partInventory.getInventory()
          local owned = inventory and inventory[part.partId]
          assert(owned and tostring(owned.businessId) == tostring(businessId) and owned.name == part.partName
            and owned.vehicleModel == model and not inventoryIds[part.partId], "Invalid inventory part")
          inventoryIds[part.partId] = true
        elseif part.partName ~= "" then
          if not ioCtx then
            assert(model, "Missing vehicle model")
            ioCtx = inputs.jbeamIO.startLoading({"/vehicles/" .. model .. "/", "/vehicles/common/"})
            loaded = true
          end
          local jbeamData = inputs.jbeamIO.getPart(ioCtx, part.partName)
          assert(jbeamData, "Unknown cart part")
          local base = jbeamData.information and jbeamData.information.value or 100
          price = base
          price = math.max(roundNear(overhaul_career_market_valueCalculator.getPartValue({name = part.partName, value = base,
            vehicleModel = model, partCondition = {integrityValue = 1, odometer = 0, visualValue = 1}}), 5) - 0.01, 0)
          price = price * inputs.parts.partsTree.getPartSupplierDiscountMultiplier(businessId)
        end
        assert(type(price) == "number" and price >= 0 and price < math.huge, "Invalid part price")
        part.price = price
        subtotal = subtotal + price
      end
    end)
    if loaded then inputs.jbeamIO.finishLoading() end
    if not ok then
      log("E", "businessComputer", "priceCartParts: " .. tostring(err))
      return nil
    end
    return subtotal
  end

  -- Returns the variable map for the tuning changes, or nil when a value is not a finite number.
  local function tuningVarsFromChanges(tuning)
    local tuningVars = {}
    for _, change in ipairs(tuning) do
      if change.type == "variable" and change.varName and change.value ~= nil then
        if type(change.value) ~= "number" or change.value ~= change.value or math.abs(change.value) == math.huge then
          return nil
        end
        tuningVars[change.varName] = change.value
      end
    end
    return tuningVars
  end

  -- Returns the pre-tax subtotal with the tuning cost added, or nil when the tuning cost is not a usable number.
  local function priceTuningChanges(businessId, vehicle, tuningVars, partsSubtotal)
    local initial = overhaul_career_business_partCustomization.getInitialVehicleState(businessId)
    if not initial or tostring(initial.vehicleId) ~= tostring(vehicle.vehicleId) then return nil end
    -- Remove the tuning tax before the shared cart tax to avoid charging it twice.
    local tuningTotal = inputs.parts.tuning.calculateTuningCost(businessId, vehicle.vehicleId, tuningVars, initial.vars or {})
    if type(tuningTotal) ~= "number" or tuningTotal < 0 or tuningTotal ~= tuningTotal or tuningTotal == math.huge then
      return nil
    end
    return partsSubtotal + (tuningTotal / (1 + SALES_TAX_RATE))
  end

  -- Vehicle records ----------------------------------------------------------------------------------

  local function collectChosenParts(tree, partList)
    if not tree then
      return
    end
    if tree.chosenPartName and tree.path then
      partList[tree.path] = tree.chosenPartName
    end
    if tree.children then
      for _, child in pairs(tree.children) do
        collectChosenParts(child, partList)
      end
    end
  end

  local function syncPersonalInventoryConfig(businessId, vehicleIdStr, config)
    local inventoryId = inputs.parts.vehicles.getInventoryIdFromPersonalVehicleId(vehicleIdStr, businessId)
    if inventoryId then
      local inventoryVehicles = overhaul_career_garage_inventory.getVehicles()
      if inventoryVehicles and inventoryVehicles[inventoryId] then
        inventoryVehicles[inventoryId].config = config
        overhaul_career_garage_inventory.setVehicleDirty(inventoryId)
      end
    end
  end

  -- Copies the vehicle's config and part list into the matching pulled-out record.
  local function syncPulledOutVehicles(businessId, vehicle)
    local pulledVehicles = overhaul_career_business_fleet.getPulledOutVehicles(businessId) or {}
    local targetId = inputs.parts.vehicles.normalizeVehicleIdValue(vehicle.vehicleId)
    for _, pulled in ipairs(pulledVehicles) do
      if inputs.parts.vehicles.normalizeVehicleIdValue(pulled.vehicleId) == targetId then
        pulled.config = vehicle.config
        pulled.partList = vehicle.partList
        return
      end
    end
  end

  local function syncPreviewConfigToFleet(businessId, vehicle)
    overhaul_career_business_fleet.updateVehicle(businessId, vehicle.vehicleId, {
      config = vehicle.config,
      partList = vehicle.partList
    })

    syncPulledOutVehicles(businessId, vehicle)
  end

  local function persistPurchasedPreviewConfigForVehicle(businessId, vehicle, vehicleIdStr, isPersonalVehicle, promoteSessionInitial)
    local previewConfig = nil
    previewConfig = overhaul_career_business_partCustomization.getPreviewVehicleConfig(businessId)
    if not previewConfig then
      return
    end

    previewConfig = deepcopy(previewConfig)
    vehicle.config = previewConfig
    if vehicle.vars then
      vehicle.config.vars = deepcopy(vehicle.vars)
    end

    local partList = {}
    collectChosenParts(previewConfig.partsTree or {}, partList)
    vehicle.partList = partList

    if isPersonalVehicle then
      syncPersonalInventoryConfig(businessId, vehicleIdStr, vehicle.config)
    else
      syncPreviewConfigToFleet(businessId, vehicle)
    end

    if promoteSessionInitial then
      overhaul_career_business_partCustomization.commitSessionInitialFromPreview(businessId, vehicle.vehicleId)
    end
  end

  local function captureInventorySnapshot(vehicle)
    return {
      config = vehicle.config and deepcopy(vehicle.config) or nil,
      partList = vehicle.partList and deepcopy(vehicle.partList) or nil,
      partConditions = vehicle.partConditions and deepcopy(vehicle.partConditions) or nil
    }
  end

  local function restorePurchasedPartsSnapshot(businessId, vehicle, isPersonalVehicle, inventorySnapshot, transaction)
    if isPersonalVehicle or not inventorySnapshot or not vehicle then
      return
    end

    overhaul_career_business_fleet.updateVehicle(businessId, vehicle.vehicleId, {
      config = inventorySnapshot.config,
      partList = inventorySnapshot.partList,
      partConditions = inventorySnapshot.partConditions
    })

    vehicle.config = inventorySnapshot.config and deepcopy(inventorySnapshot.config) or vehicle.config
    vehicle.partList = inventorySnapshot.partList and deepcopy(inventorySnapshot.partList) or vehicle.partList

    syncPulledOutVehicles(businessId, vehicle)

    if not transaction.cancelled then
      overhaul_career_business_partCustomization.initializePreviewVehicle(businessId, vehicle.vehicleId)
    end
  end

  -- Part inventory -----------------------------------------------------------------------------------

  local function findRemovedPartsForPurchase(businessId, vehicle, parts, inventorySnapshot)
    local removedParts = {}
    removedParts = overhaul_career_business_partCustomization.findRemovedParts(businessId, vehicle.vehicleId) or {}
    if #removedParts > 0 then
      return removedParts
    end
    if inventorySnapshot and inventorySnapshot.partList then
      return inputs.parts.partsTree.findRemovedPartsFromCart(businessId, vehicle.vehicleId, parts, inventorySnapshot.partList,
        inventorySnapshot.partConditions) or {}
    end
    return inputs.parts.partsTree.findRemovedPartsFromCart(businessId, vehicle.vehicleId, parts) or {}
  end

  -- Installed parts leave storage; newly bought parts must not inherit an old tire state.
  local function takePurchasedPartsFromInventory(businessId, vehicle, parts)
    local partsRemovedFromInventory = false
    for _, part in ipairs(parts) do
      if part.fromInventory and part.partId then
        local storedPart = overhaul_career_business_partInventory.getInventory()[part.partId]
        if storedPart and storedPart.rlsTireState and vehicle then
          local installedPath = tostring(part.slotPath or part.containingSlot or "") ..
                                  tostring(part.partName or storedPart.name or "")
          vehicle.rlsTireStateByPartPath = vehicle.rlsTireStateByPartPath or {}
          vehicle.rlsTireStateByPartPath[installedPath] = deepcopy(storedPart.rlsTireState)
        end
        overhaul_career_business_partInventory.removePart(part.partId, businessId)
        partsRemovedFromInventory = true
      elseif vehicle and (part.slotPath or part.containingSlot) and part.partName then
        -- Clear same-path tire wear so the new part starts with fresh condition.
        local installedPath = tostring(part.slotPath or part.containingSlot) .. tostring(part.partName)
        if vehicle.rlsTireStateByPartPath then
          vehicle.rlsTireStateByPartPath[installedPath] = nil
        end
      end
    end
    return partsRemovedFromInventory
  end

  local function commitPurchasedPartsInventoryForVehicle(businessId, vehicle, isPersonalVehicle, inventorySnapshot, parts)
    if isPersonalVehicle then
      return
    end

    local removedParts = findRemovedPartsForPurchase(businessId, vehicle, parts, inventorySnapshot)
    if #removedParts > 0 then
      overhaul_career_business_partInventory.addParts(removedParts, businessId)
    end

    local partsRemovedFromInventory = takePurchasedPartsFromInventory(businessId, vehicle, parts)
    if #removedParts > 0 or partsRemovedFromInventory then
      inputs.parts.actions.requestPartInventory(businessId)
    end
  end

  -- Payment ------------------------------------------------------------------------------------------

  local function notifyBusinessAccountUpdate(accountId)
    local businessTypeFromAccount, businessIdFromAccount = accountId:match("^business_(.+)_(.+)$")
    if not (businessTypeFromAccount and businessIdFromAccount) then
      return
    end
    local account = overhaul_career_economy_bank.getBusinessAccount(businessTypeFromAccount, businessIdFromAccount)
    if not account then
      return
    end
    guihooks.trigger('bank:onOverhaulAccountUpdate', {
      accountId = account.id,
      balance = account.balance or 0,
      accountType = account.type or "unknown",
      businessType = account.businessType,
      businessId = account.businessId,
      name = account.name or "Account"
    })
  end

  local function cartFinance(purchase)
    if purchase.finance then return purchase.finance end
    local vehicleId = purchase.vehicle and purchase.vehicle.vehicleId
    local inventoryId = inputs.parts.vehicles.isPersonalVehicleId(vehicleId)
      and inputs.parts.vehicles.getInventoryIdFromPersonalVehicleId(vehicleId, purchase.businessId) or nil
    local metadata = require("overhaul/lib/finance/metadata")
    local snapshot = metadata.capture(metadata.tag(nil, "purchase", {vehicleId = inventoryId}), os.time(), -purchase.totalCost)
    purchase.finance = {vehicleId = snapshot.vehicleId, vehicleKey = snapshot.vehicleKey, vehicleName = snapshot.vehicleName}
    return purchase.finance
  end

  local function debitCartPurchase(purchase)
    if purchase.totalCost <= 0 then
      return true
    end
    local success = overhaul_career_economy_bank.payFromAccount({
      money = {
        amount = purchase.totalCost,
        canBeNegative = false
      }
    }, purchase.accountId, "Shop Purchase", "Purchased parts/tuning", require("overhaul/lib/finance/metadata").tag(nil, "purchase", cartFinance(purchase)))
    if not success then
      purchase.saveHold.release()
      pendingCartPurchases[purchase.purchaseKey] = nil
      log("E", "businessComputer", "purchaseCartItems: Payment failed for amount " .. tostring(purchase.totalCost))
      return false
    end
    notifyBusinessAccountUpdate(purchase.accountId)
    return true
  end

  -- Refreshes the preview and power-to-weight after purchase, then saves.
  local function finalizePurchase(businessId, vehicleId, callback)
    if not businessId or not vehicleId then
      if callback then callback(false) end
      return
    end

    overhaul_career_business_partCustomization.clearPreviewVehicle(businessId)
    local ok = overhaul_career_business_partCustomization.initializePreviewVehicle(businessId, vehicleId)
    if not ok then
      log("W", "businessVehicleModificationUtil",
        "initializePreviewVehicle failed after purchase businessId=" .. tostring(businessId) ..
          " vehicleId=" .. tostring(vehicleId) .. " — save still runs")
    end
    overhaul_career_business_partCustomization.requestVehiclePowerWeightAfterPurchase(businessId, vehicleId)

    overhaul_career_business_vehicleTuning.clearTuningDataCache()

    overhaul_career_saveSystem.saveCurrent()

    if callback then callback(true) end
  end

  -- Settlement ---------------------------------------------------------------------------------------

  local function finalizeCartPurchase(businessId, vehicle, saveHold, purchaseKey)
    saveHold.release()
    pendingCartPurchases[purchaseKey] = nil
    if not vehicle or not vehicle.vehicleId then
      return
    end
    local vehicleIdStr = tostring(vehicle.vehicleId)
    local isPersonalVehicle = inputs.parts.vehicles.isPersonalVehicleId(vehicleIdStr)

    M.exitShoppingVehicle(businessId)

    if isPersonalVehicle then
      overhaul_career_business_partCustomization.clearPreviewVehicle(businessId)
      overhaul_career_business_vehicleTuning.clearTuningDataCache()
      local inventoryId = inputs.parts.vehicles.getInventoryIdFromPersonalVehicleId(vehicleIdStr, businessId)
      if inventoryId then
        overhaul_career_saveSystem.saveCurrent({inventoryId})
      end
    else
      finalizePurchase(businessId, vehicle.vehicleId, nop)
    end
  end

  local function clearCachesForPurchase(purchase)
    inputs.parts.vehicles.clearCachesForVehicle(purchase.businessId, purchase.vehicle.vehicleId)
  end

  local function persistPurchasePreviewConfig(purchase, promoteSessionInitial)
    persistPurchasedPreviewConfigForVehicle(purchase.businessId, purchase.vehicle, purchase.vehicleIdStr,
      purchase.isPersonalVehicle, promoteSessionInitial)
  end

  local function settleAppliedParts(purchase)
    local businessId, vehicle = purchase.businessId, purchase.vehicle
    if not purchase.isPersonalVehicle then
      inputs.parts.tuning.invalidateTuningShopJobCompletionIfNeeded(businessId, vehicle.vehicleId)
    end
    commitPurchasedPartsInventoryForVehicle(businessId, vehicle, purchase.isPersonalVehicle, purchase.inventorySnapshot, purchase.parts)
    persistPurchasePreviewConfig(purchase, true)
    if not purchase.isPersonalVehicle then
      local module, businessType = inputs.resolveBusinessModule(businessId)
      if businessType == "racingTeam" and module and module.notifyBusinessVehiclePartsPurchased then
        module.notifyBusinessVehiclePartsPurchased(businessId, purchase.parts)
      end
    end
  end

  local function refundRejectedParts(purchase)
    local vehicle = purchase.vehicle
    restorePurchasedPartsSnapshot(purchase.businessId, vehicle, purchase.isPersonalVehicle, purchase.inventorySnapshot, purchase.transaction)
    if vehicle.config and vehicle.vars then vehicle.config.vars = deepcopy(vehicle.vars) end
    local refundAmount = math.min(purchase.totalCost, purchase.partsSubtotal * (1 + SALES_TAX_RATE))
    if refundAmount > 0 then
      overhaul_career_economy_bank.rewardToAccount({
        money = {
          amount = refundAmount
        }
      }, purchase.accountId, "Shop Refund", "Part change could not be applied", require("overhaul/lib/finance/metadata").tag(nil, "refund", cartFinance(purchase)))
    end
  end

  -- Runs once: when the parts apply ok, the parts are committed; otherwise they are restored and refunded.
  local function settlePartsPurchase(purchase, ok)
    if purchase.partsSettled then return end
    purchase.partsSettled = true
    local settled, err = pcall(ok and settleAppliedParts or refundRejectedParts, purchase)
    purchase.saveHold.release()
    pendingCartPurchases[purchase.purchaseKey] = nil
    if not settled then
      purchase.settlementFailed, purchase.deferFinalize = true, false
      log('E', 'businessComputer', 'Cart settlement failed: ' .. tostring(err))
      guihooks.trigger('toastrMsg', {type = 'error', title = 'Purchase failed',
        msg = 'The purchase could not be settled. Please check the vehicle and account.'})
      return false
    end
    if ok then
      if purchase.deferFinalize then
        purchase.deferFinalize = false
        finalizeCartPurchase(purchase.businessId, purchase.vehicle, purchase.saveHold, purchase.purchaseKey)
      end
    else
      purchase.deferFinalize = false
      overhaul_career_saveSystem.saveCurrent()
    end
  end

  -- Applies the parts. Returns false when the sync reject already refunded a parts-only purchase.
  local function applyPartsToVehicle(purchase)
    local businessId, vehicle = purchase.businessId, purchase.vehicle
    if not purchase.isPersonalVehicle then
      purchase.inventorySnapshot = captureInventorySnapshot(vehicle)
    end

    local function settleParts(ok)
      return settlePartsPurchase(purchase, ok)
    end
    purchase.transaction.cancel = function()
      if purchase.partsSettled or purchase.transaction.cancelled then return false end
      purchase.transaction.cancelled = true
      local restored, err = true, nil
      if purchase.transaction.restore then restored, err = pcall(purchase.transaction.restore, vehicle.vars) end
      if not restored then
        log('E', 'businessComputer', 'Cart rollback failed: ' .. tostring(err))
        pcall(overhaul_career_business_partCustomization.clearPreviewVehicle, businessId)
      end
      settleParts(false)
      return false
    end
    local partsApplied = inputs.parts.tuning.applyCartPartsToVehicle(businessId, vehicle.vehicleId, purchase.parts, settleParts, purchase.transaction)
    if purchase.settlementFailed then return false end
    if partsApplied and not purchase.partsSettled then
      purchase.deferFinalize = true
    elseif not partsApplied and #purchase.tuning == 0 then
      -- Sync reject already ran onComplete(false) (refund). Do not finalize a failed parts-only purchase.
      clearCachesForPurchase(purchase)
      return false
    end
    return true
  end

  local function applyCartToVehicle(purchase)
    local businessId, vehicle = purchase.businessId, purchase.vehicle
    if vehicle.vehicleId then
      if #purchase.parts > 0 then
        if not applyPartsToVehicle(purchase) then
          return false
        end
      elseif not purchase.isPersonalVehicle and #purchase.tuning > 0 then
        inputs.parts.tuning.invalidateTuningShopJobCompletionIfNeeded(businessId, vehicle.vehicleId)
      end

      if #purchase.tuning > 0 then
        -- Do not assign vehicle.vars = tuningVars here (applyVehicleTuning merges into saved vars).
        inputs.parts.tuning.applyVehicleTuning(businessId, vehicle.vehicleId, purchase.tuningVars, nil)
      end

      if not purchase.deferFinalize then
        finalizeCartPurchase(businessId, vehicle, purchase.saveHold, purchase.purchaseKey)
      end
    else
      log("W", "businessComputer", "purchaseCartItems: No active vehicle found for businessId=" .. tostring(businessId))
    end
    return true
  end

  -- Cart purchase ------------------------------------------------------------------------------------

  local function prepareCartPurchase(businessId, accountId, cartData, purchaseKey)
    local vehicle = inputs.parts.vehicles.getActiveBusinessVehicle(businessId)
    if not vehicle or not vehicle.vehicleId then return nil end
    if not require('overhaul/lib/business/customizationAccess').allow(businessId, vehicle.vehicleId, vehicle) then return nil end
    local parts = deepcopy(cartData.parts or {})
    local tuning = cartData.tuning or {}

    local partsSubtotal = priceCartParts(businessId, vehicle, parts)
    if partsSubtotal == nil then return nil end

    local subtotal = partsSubtotal
    local tuningVars = {}
    if #tuning > 0 then
      tuningVars = tuningVarsFromChanges(tuning)
      if not tuningVars then return nil end
      subtotal = priceTuningChanges(businessId, vehicle, tuningVars, partsSubtotal)
      if subtotal == nil then return nil end
    end

    local totalCost = subtotal + subtotal * SALES_TAX_RATE
    if #parts == 0 and #tuning == 0 then
      return nil
    end

    return {
      businessId = businessId,
      accountId = accountId,
      purchaseKey = purchaseKey,
      vehicle = vehicle,
      parts = parts,
      tuning = tuning,
      tuningVars = tuningVars,
      partsSubtotal = partsSubtotal,
      totalCost = totalCost,
      deferFinalize = false,
      partsSettled = false,
    }
  end

  local function reserveCartPurchase(purchase)
    purchase.saveHold = require("overhaul/lib/save/store").hold(M, "cart purchase", {stage = 'beforeRecovery'})
    purchase.transaction = {elapsed = 0}
    pendingCartPurchases[purchase.purchaseKey] = purchase.transaction
  end

  function api.purchaseCartItems(businessId, accountId, cartData)
    if not businessId or not accountId or not cartData then
      return false
    end
    local purchaseKey = tostring(businessId)
    if pendingCartPurchases[purchaseKey] or (overhaul_career_saveSystem.isSaveBusy()) then
      guihooks.trigger("toastrMsg", {type="info", title="Purchase pending", msg="A purchase or career save is in progress. Please try again in a moment."})
      return false
    end

    local purchase = prepareCartPurchase(businessId, accountId, cartData, purchaseKey)
    if not purchase then return false end
    reserveCartPurchase(purchase)

    local function failPurchase(err)
      purchase.partsSettled, purchase.settlementFailed, purchase.deferFinalize = true, true, false
      purchase.saveHold.release()
      pendingCartPurchases[purchase.purchaseKey] = nil
      log('E', 'businessComputer', 'Cart purchase failed: ' .. tostring(err))
      guihooks.trigger('toastrMsg', {type = 'error', title = 'Purchase failed',
        msg = 'The purchase could not be completed. Please check the vehicle and account.'})
    end
    local debited, debitResult = pcall(debitCartPurchase, purchase)
    if not debited then failPurchase(debitResult); return false end
    if not debitResult then return false end

    purchase.vehicleIdStr = tostring(purchase.vehicle.vehicleId)
    purchase.isPersonalVehicle = inputs.parts.vehicles.isPersonalVehicleId(purchase.vehicleIdStr)

    local applied, result = pcall(applyCartToVehicle, purchase)
    if not applied then failPurchase(result); return false end
    if not result then return false end

    if purchase.vehicle then
      clearCachesForPurchase(purchase)
    end
    if not purchase.deferFinalize then
      purchase.saveHold.release()
      pendingCartPurchases[purchaseKey] = nil
    end

    Engine.Audio.playOnce('AudioGui','event:>UI>Career>Buy_01')
    return true
  end

  -- Balances and power ------------------------------------------------------------------------------

  function api.getBusinessAccountBalance(businessType, businessId)
    if not businessType or not businessId then
      return 0
    end

    local account = overhaul_career_economy_bank.getBusinessAccount(businessType, businessId)
    if account then
      return overhaul_career_economy_bank.getAccountBalance(account.id)
    end

    return 0
  end

  function api.getBusinessXP(businessType, businessId)
    if not businessType or not businessId then
      return 0
    end

    inputs.setBusinessContext(businessType, businessId)

    local module = inputs.getBusinessModule(businessType)
    if module and module.getBusinessXP then
      return module.getBusinessXP(businessId)
    end

    return 0
  end

  function api.onPowerWeightReceived(requestId, power, weight)
    return overhaul_career_business_partCustomization.onPowerWeightReceived(requestId, power, weight)
  end

  function api.getVehiclePowerWeight(businessId, vehicleId)
    if inputs.parts.vehicles.shouldPreventVehicleOperation(businessId, vehicleId) then
      return nil
    end

    return overhaul_career_business_partCustomization.getVehiclePowerWeight(businessId, vehicleId)
  end

  return api
end

return installer
