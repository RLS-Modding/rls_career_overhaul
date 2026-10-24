-- Tyre checkout: payment and refund, the fresh wheel state, and the personal and fleet part replacement with rollback.
-- Part of the tire system; the functions attach to the tire system's M, so callers reach them as before.
local partFactory = {}
local capabilities = require("overhaul/lib/platform/capabilities")

-- Built by tireSystem.lua with the tire system's M, sibling helpers and dependencies.
function partFactory.new(inputs)

  local parts = inputs.parts

  -- Payment ------------------------------------------------------------------------------------------

  local function payCheckout(amount, paymentContext)
    amount = tonumber(amount) or 0
    if paymentContext and paymentContext.skipPayment then
      return true
    end
    if paymentContext and paymentContext.mode == "businessAccount" then
      local account = overhaul_career_economy_bank.getBusinessAccount(paymentContext.businessType, paymentContext.businessId) or nil
      if not account then
        return false, "Business account is unavailable."
      end
      if not overhaul_career_economy_bank.payFromAccount({money = {amount = amount, canBeNegative = false}}, account.id, "Tire Replacement", "Fresh replacement tires", require("overhaul/lib/finance/metadata").tag(nil, "repair", {vehicleId = paymentContext and paymentContext.inventoryId})) then
        return false, "Not enough funds in business account."
      end
      return true
    end
    local price = {money = {amount = amount, canBeNegative = false}}
    if not overhaul_career_economy_payment.canPay(price) then
      return false, "Not enough money."
    end
    if not overhaul_career_economy_payment.pay(price, require("overhaul/lib/finance/metadata").tag({label = "Fresh replacement tires", tags = {"maintenance", "tires", "buying"}}, "repair", {vehicleId = paymentContext and paymentContext.inventoryId})) then
      return false, "Payment failed."
    end
    return true
  end

  local function refundCheckout(amount, paymentContext)
    amount = tonumber(amount) or 0
    if paymentContext and paymentContext.skipPayment then
      return true
    end
    if paymentContext and paymentContext.mode == "businessAccount" then
      local account = overhaul_career_economy_bank.getBusinessAccount(paymentContext.businessType, paymentContext.businessId) or nil
      return account and overhaul_career_economy_bank.rewardToAccount({money = {amount = amount}}, account.id, "Tire Replacement Refund", "Tire replacement could not be completed", require("overhaul/lib/finance/metadata").tag(nil, "refund", {vehicleId = paymentContext and paymentContext.inventoryId}))
    end
    return overhaul_career_economy_payment.reward({money = {amount = amount}}, require("overhaul/lib/finance/metadata").tag({
               label = "Tire replacement refund",
               tags = {"maintenance", "tires", "refund"},
             }, "refund", {vehicleId = paymentContext and paymentContext.inventoryId}), true)
  end

  -- Quote ---------------------------------------------------------------------------------------------

  -- The axle groups the player picked, or nil when an id no longer matches a group.
  local function selectedGroups(uiData, axleIds)
    local wanted = {}
    for _, id in ipairs(axleIds or {}) do wanted[tostring(id)] = true end
    local result = {}
    for _, group in ipairs(uiData.axles or {}) do
      if wanted[group.id] then
        table.insert(result, group)
        wanted[group.id] = nil
      end
    end
    if next(wanted) then
      return nil
    end
    return result
  end

  -- Checks the quote the player is buying against the live tyre state. Returns the groups, or an error result.
  local function quotedGroups(uiData, axleIds, revision)
    if not uiData.available then
      return nil, {ok = false, message = uiData.message or "Tire replacement is unavailable."}
    end
    if not uiData.inspected then
      return nil, {ok = false, message = "Check all tires before replacing them."}
    end
    if tostring(revision or "") ~= tostring(uiData.quoteRevision or "") then
      return nil, {ok = false, staleQuote = true, message = "Tire condition or pricing changed. Review the updated quote."}
    end
    local groups = selectedGroups(uiData, axleIds)
    if not groups or #groups == 0 then
      return nil, {ok = false, message = "Select at least one axle."}
    end
    return groups
  end

  local function quoteTotal(groups)
    local total = 0
    for _, group in ipairs(groups) do total = total + group.subtotal end
    return total
  end

  -- Wheel state -------------------------------------------------------------------------------------

  local function freshStateForWheels(wheels)
    local state = {schemaVersion = 1, wheels = {}}
    for _, wheel in ipairs(wheels or {}) do
      state.wheels[wheel.name] = inputs.freshWheelState()
    end
    return state
  end

  local function stateFromWheels(wheels)
    local state = {schemaVersion = 1, wheels = {}}
    for _, wheel in ipairs(wheels or {}) do
      state.wheels[tostring(wheel.name)] = {
        remaining = inputs.tireModel.clamp(wheel.remaining, 0, 1),
        flat = wheel.flat == true,
      }
    end
    return state
  end

  local function markLayoutWheelsFresh(vehicleData, groups)
    local wanted = {}
    for _, group in ipairs(groups or {}) do
      for _, wheel in ipairs(group.wheels or {}) do
        wanted[tostring(wheel.name)] = true
      end
    end
    for _, wheel in ipairs(vehicleData and vehicleData.rlsTireLayout and vehicleData.rlsTireLayout.wheels or {}) do
      if wanted[tostring(wheel.name)] then
        wheel.remaining = 1
        wheel.flat = false
      end
    end
  end

  -- True when the fleet vehicle's parts tree still holds the tyre the quote priced.
  local function businessPartIsFitted(vehicleData, descriptor)
    local function walk(node)
      if type(node) ~= "table" then return false end
      local chosen = node.chosenPartName
      local candidatePath = node.partPath or
                              (type(node.path) == "string" and chosen and (node.path .. chosen) or nil)
      if chosen == descriptor.partOrigin and
         (not descriptor.partPath or candidatePath == descriptor.partPath) then
        return true
      end
      for _, child in pairs(node.children or {}) do
        if walk(child) then return true end
      end
      return false
    end
    return walk(vehicleData and vehicleData.config and vehicleData.config.partsTree)
  end

  -- Part replacement --------------------------------------------------------------------------------

  -- Swaps each quoted personal tyre for a new one, recording what to undo if the commit fails.
  local function replacePersonalParts(inventoryId, vehicleData, groups, rollback)
    local inventory = inputs.personalInventory()
    for _, group in ipairs(groups) do
      for _, descriptor in ipairs(group.parts) do
        local partId, oldPart = inputs.findPersonalPart(inventoryId, descriptor.partPath, descriptor.partOrigin,
          descriptor.containingSlot)
        if not oldPart then
          error("Installed tire part is no longer available: " .. tostring(descriptor.partOrigin))
        end
        rollback.personalParts[partId] = inputs.deepCopy(oldPart)
        inputs.setPartState(oldPart, stateFromWheels(group.wheels))
        oldPart.location = 0
        local newPart = inputs.deepCopy(oldPart)
        newPart.location = inventoryId
        newPart.partCondition = {integrityValue = 1, odometer = 0, visualValue = 1}
        inputs.setPartState(newPart, freshStateForWheels(group.wheels))
        local before = {}
        for id in pairs(inventory) do before[id] = true end
        overhaul_career_parts_partInventory.addPartToInventory(newPart)
        for id in pairs(inventory) do
          if not before[id] then
            table.insert(rollback.addedPersonalIds, id)
            break
          end
        end
        vehicleData.partConditions = type(vehicleData.partConditions) == "table" and vehicleData.partConditions or {}
        vehicleData.partConditions[newPart.partPath] = inputs.deepCopy(newPart.partCondition)
        vehicleData.rlsTireStateByPartPath = type(vehicleData.rlsTireStateByPartPath) == "table" and
                                               vehicleData.rlsTireStateByPartPath or {}
        vehicleData.rlsTireStateByPartPath[newPart.partPath] = freshStateForWheels(group.wheels)
      end
    end
    markLayoutWheelsFresh(vehicleData, groups)
    overhaul_career_parts_partInventory.onOverhaulPartShoppingTransactionComplete()
  end

  -- Puts each quoted fleet tyre into business inventory and fits a new one, recording what to undo.
  local function replaceBusinessParts(inventoryId, vehicleData, groups, paymentContext, rollback)
    local businessInventory = overhaul_career_business_partInventory
    if not businessInventory or not businessInventory.addPart then
      error("Business part inventory is unavailable.")
    end
    vehicleData.rlsTireStateByPartPath = type(vehicleData.rlsTireStateByPartPath) == "table" and
                                           vehicleData.rlsTireStateByPartPath or {}
    for _, group in ipairs(groups) do
      for _, descriptor in ipairs(group.parts) do
        if not businessPartIsFitted(vehicleData, descriptor) then
          error("The quoted fleet tire is no longer fitted: " .. tostring(descriptor.partOrigin))
        end
        local path = descriptor.partPath or ((descriptor.containingSlot or "") .. tostring(descriptor.partOrigin or ""))
        local slotPath = path:match("^(.*[/])[^/]+$") or descriptor.containingSlot
        local oldState = stateFromWheels(group.wheels)
        local partCondition = vehicleData.partConditions and vehicleData.partConditions[path] or
                                {integrityValue = 1, odometer = 0, visualValue = 1}
        local addedId = businessInventory.addPart({
          name = descriptor.partOrigin,
          vehicleModel = vehicleData.model or vehicleData.model_key or
                           (vehicleData.vehicleConfig and vehicleData.vehicleConfig.model_key),
          containingSlot = slotPath,
          slot = slotPath and (slotPath:match("/([^/]+)/$") or slotPath:match("/([^/]+)$")) or nil,
          partPath = path,
          partCondition = inputs.deepCopy(partCondition),
          rlsTireState = inputs.deepCopy(oldState),
        }, paymentContext.businessId)
        if not addedId then
          error("Could not return the removed tire to business inventory.")
        end
        table.insert(rollback.addedBusinessIds, addedId)
        vehicleData.partConditions = type(vehicleData.partConditions) == "table" and vehicleData.partConditions or {}
        vehicleData.partConditions[path] = {integrityValue = 1, odometer = 0, visualValue = 1}
        vehicleData.rlsTireStateByPartPath[path] = freshStateForWheels(group.wheels)
      end
    end
    markLayoutWheelsFresh(vehicleData, groups)
  end

  -- Snapshot of everything a failed checkout must put back on the vehicle.
  local function snapshotVehicle(vehicleData)
    return {
      vehiclePartConditions = inputs.deepCopy(vehicleData.partConditions),
      vehicleTireState = inputs.deepCopy(vehicleData.rlsTireStateByPartPath),
      maintenanceComputerState = inputs.deepCopy(vehicleData.maintenanceComputerState),
      personalParts = {},
      addedPersonalIds = {},
      addedBusinessIds = {},
    }
  end

  local function restoreVehicleFields(vehicleData, rollback)
    vehicleData.partConditions = rollback.vehiclePartConditions
    vehicleData.rlsTireStateByPartPath = rollback.vehicleTireState
    vehicleData.maintenanceComputerState = rollback.maintenanceComputerState
  end

  local function rollBackPersonalCheckout(inventoryId, vehicleData, rollback, total, paymentContext, commitError)
    restoreVehicleFields(vehicleData, rollback)
    local inventory = inputs.personalInventory()
    for id, part in pairs(rollback.personalParts) do inventory[id] = part end
    for _, id in ipairs(rollback.addedPersonalIds) do inventory[id] = nil end
    for _, id in ipairs(rollback.addedBusinessIds) do
      overhaul_career_business_partInventory.removePart(id, paymentContext and paymentContext.businessId)
    end
    overhaul_career_parts_partInventory.onOverhaulPartShoppingTransactionComplete()
    refundCheckout(total, paymentContext)
    inputs.markDirty(inventoryId)
    overhaul_career_saveSystem.saveCurrent()
    log("E", "tireSystem", "Tire checkout rolled back: " .. tostring(commitError))
    return {ok = false, message = "Tire replacement failed; payment was refunded."}
  end

  local function rollBackBusinessCheckout(businessId, vehicleId, vehicleData, rollback, total, paymentContext, commitError)
    restoreVehicleFields(vehicleData, rollback)
    for _, id in ipairs(rollback.addedBusinessIds) do
      overhaul_career_business_partInventory.removePart(id, businessId)
    end
    refundCheckout(total, paymentContext)
    inputs.M.sendContextForBusinessVehicle(businessId, vehicleId, true)
    overhaul_career_saveSystem.saveCurrent()
    log("E", "tireSystem", "Business tire checkout rolled back: " .. tostring(commitError))
    return {ok = false, message = "Tire replacement failed; payment was refunded."}
  end

  -- Public API --------------------------------------------------------------------------------------

  -- Buys the quoted tyres for a personal vehicle, or for a business account when the payment context says so.
  function inputs.M.checkout(inventoryId, axleIds, revision, paymentContext)
    paymentContext = require("overhaul/lib/finance/metadata").copy(paymentContext or {})
    paymentContext.inventoryId = inventoryId
    inventoryId = tonumber(inventoryId)
    local uiData = inputs.M.buildUiData(inventoryId)
    local groups, quoteError = quotedGroups(uiData, axleIds, revision)
    if quoteError then return quoteError end
    local total = quoteTotal(groups)
    local paid, paymentError = payCheckout(total, paymentContext)
    if not paid then
      return {ok = false, message = paymentError or "Payment failed."}
    end

    local vehicleData = inputs.vehicleDataForInventory(inventoryId)
    local rollback = snapshotVehicle(vehicleData)
    local committed, commitError = xpcall(function()
      if paymentContext and paymentContext.mode == "businessAccount" then
        replaceBusinessParts(inventoryId, vehicleData, groups, paymentContext, rollback)
      else
        replacePersonalParts(inventoryId, vehicleData, groups, rollback)
      end
      vehicleData.maintenanceComputerState.tireInspection = nil
      inputs.partRevisions[inventoryId] = (tonumber(inputs.partRevisions[inventoryId]) or 0) + 1
      inputs.markDirty(inventoryId)
      overhaul_career_saveSystem.saveCurrent({inventoryId})
      local vehId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId) or nil
      inputs.M.sendContextForVehicle(vehId, true)
      parts.context.applyFreshTiresOnVehId(vehId,
        parts.context.initialStateWithFreshGroups(parts.context.buildInitialWheelState(inventoryId, vehicleData), groups))
    end, debug.traceback)

    if not committed then
      return rollBackPersonalCheckout(inventoryId, vehicleData, rollback, total, paymentContext, commitError)
    end
    return {ok = true, completed = true, price = inputs.round(total, 2)}
  end

  -- Buys the quoted tyres for a fleet vehicle, paid from the business account.
  function inputs.M.checkoutBusiness(businessType, businessId, vehicleId, axleIds, revision)
    if not overhaul_career_business_manager.isPurchasedBusiness(businessType, businessId) then
      return {ok = false, message = "Business ownership could not be verified."}
    end
    local uiData = inputs.M.buildBusinessUiData(businessId, vehicleId)
    local groups, quoteError = quotedGroups(uiData, axleIds, revision)
    if quoteError then return quoteError end
    local total = quoteTotal(groups)
    local paymentContext = {mode = "businessAccount", businessType = businessType, businessId = businessId}
    local paid, paymentError = payCheckout(total, paymentContext)
    if not paid then return {ok = false, message = paymentError or "Payment failed."} end

    local vehicleData = inputs.businessVehicleData(businessId, vehicleId)
    local rollback = snapshotVehicle(vehicleData)
    local committed, commitError = xpcall(function()
      replaceBusinessParts(vehicleId, vehicleData, groups, paymentContext, rollback)
      vehicleData.maintenanceComputerState.tireInspection = nil
      local revisionKey = "b:" .. tostring(businessId) .. ":" .. tostring(vehicleId)
      inputs.partRevisions[revisionKey] = (tonumber(inputs.partRevisions[revisionKey]) or 0) + 1
      overhaul_career_saveSystem.saveCurrent()
      inputs.M.sendContextForBusinessVehicle(businessId, vehicleId, true)
      local vehId = capabilities.get("businessVehicles").getSpawnedVehicleId(businessId, vehicleId) or nil
      parts.context.applyFreshTiresOnVehId(vehId,
        parts.context.initialStateWithFreshGroups(parts.context.buildInitialWheelState(nil, vehicleData), groups))
    end, debug.traceback)

    if not committed then
      return rollBackBusinessCheckout(businessId, vehicleId, vehicleData, rollback, total, paymentContext, commitError)
    end
    return {ok = true, completed = true, price = inputs.round(total, 2)}
  end
end

return partFactory
