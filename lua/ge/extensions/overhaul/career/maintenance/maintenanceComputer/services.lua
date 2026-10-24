-- Maintenance services: revealed items, legacy job migration, vehicle state, payment and refund, and the check and service actions.
-- Map: Revealed items and legacy jobs; Vehicle state; Payment; Actions; Public API.

local partFactory = {}

function partFactory.new(inputs)
  local computerState = inputs.state

  local parts = inputs.parts

  -- Revealed items and legacy jobs --------------------------------------------------------------------

  -- Hides any reveal whose rounded percent no longer matches the item; returns true when something changed.
  local function invalidateRevealedState(uiState, maintenanceState)
    local changed = false
    for _, categoryName in ipairs(inputs.config.categoryOrder) do
      local categoryRevealed = uiState.revealed[categoryName] or {}
      local maintenance = maintenanceState.categories[categoryName].maintenance
      for _, itemDefinition in ipairs(inputs.config.categoryDefinitions[categoryName].items) do
        local revealedState = categoryRevealed[itemDefinition.name]
        if type(revealedState) == "table" then
          local currentRoundedPercent = inputs.roundPercent(maintenance[itemDefinition.name] or 0)
          if tonumber(revealedState.roundedPercent) ~= currentRoundedPercent then
            categoryRevealed[itemDefinition.name] = nil
            changed = true
          end
        end
      end
      uiState.revealed[categoryName] = categoryRevealed
    end
    return changed
  end

  local function syncRuntimeState(inventoryId)
    overhaul_vehicles_maintenanceBridge.syncVehicleMaintenance(tonumber(inventoryId))
  end

  local function syncDriveLock(inventoryId)
    overhaul_vehicles_maintenanceBridge.syncMaintenanceDriveLock(tonumber(inventoryId))
  end

  local function revealMaintenanceItem(uiState, categoryName, itemName, roundedPercent)
    local categoryRevealed = uiState.revealed[categoryName]
    if type(categoryRevealed) ~= "table" then
      categoryRevealed = {}
      uiState.revealed[categoryName] = categoryRevealed
    end

    categoryRevealed[itemName] = {roundedPercent = tonumber(roundedPercent) or 100}
  end

  local function completeServiceJob(uiState, categoryState, job, itemDefinition)
    categoryState.maintenance[job.item] = 1
    revealMaintenanceItem(uiState, job.category, job.item, 100)

    local filledItemName = itemDefinition and itemDefinition.fillsItem or nil
    if filledItemName and categoryState.maintenance[filledItemName] ~= nil then
      categoryState.maintenance[filledItemName] = 1
      revealMaintenanceItem(uiState, job.category, filledItemName, 100)
    end
  end

  -- Checks and services used to be timed jobs. Existing service jobs were paid for when they were queued, so complete them once during normalization instead of making the player wait or charging again.
  local function migrateLegacyJobs(vehicleData, maintenanceState, uiState, runtimeInventoryId)
    local changed = false
    local didService = false

    local sortedJobKeys = {}
    for jobKey in pairs(uiState.jobs or {}) do
      table.insert(sortedJobKeys, jobKey)
    end
    table.sort(sortedJobKeys)

    for _, jobKey in ipairs(sortedJobKeys) do
      local job = uiState.jobs[jobKey]
      local definition = job and inputs.config.getItemDefinition(job.category, job.item) or nil
      local categoryState = job and maintenanceState.categories[job.category] or nil
      if type(job) == "table" and definition and categoryState then
        if job.kind == "service" then
          completeServiceJob(uiState, categoryState, job, definition)
          didService = true
        else
          revealMaintenanceItem(uiState, job.category, job.item, inputs.roundPercent(categoryState.maintenance[job.item] or 0))
        end
      end
      uiState.jobs[jobKey] = nil
      changed = true
    end

    if changed and didService then
      if runtimeInventoryId then syncRuntimeState(runtimeInventoryId) end
    end

    if changed then
      if runtimeInventoryId then syncDriveLock(runtimeInventoryId) end
    end

    return changed
  end

  -- Vehicle state ---------------------------------------------------------------------------------

  local function prepareVehicleState(inventoryId, options)
    options = options or {}
    local vehicleData = inputs.getVehicleData(inventoryId)
    if not vehicleData then
      return nil
    end

    local maintenanceState, maintenanceChanged = inputs.normalizeVehicleMaintenanceState(vehicleData)
    local uiState, uiChanged = inputs.ensureMaintenanceComputerState(vehicleData)
    local cacheChanged = false
    local trackedPartIdsByCategory

    uiChanged = invalidateRevealedState(uiState, maintenanceState) or uiChanged
    local jobsChanged = migrateLegacyJobs(vehicleData, maintenanceState, uiState, inventoryId)
    trackedPartIdsByCategory, _, cacheChanged = parts.quotes.getTrackedPartData(vehicleData, maintenanceState)

    if maintenanceChanged or uiChanged or jobsChanged or cacheChanged then
      if options.persistChanges == false then
        if jobsChanged and options.persistCompletedJobs ~= false then
          inputs.persistVehicleMutation(vehicleData.id)
        elseif options.markDirtyOnChange ~= false then
          inputs.markVehicleDirty(vehicleData.id)
        end
      else
        inputs.persistVehicleMutation(vehicleData.id)
      end
    end

    return vehicleData, maintenanceState, uiState, trackedPartIdsByCategory
  end

  local function prepareBusinessVehicleState(businessId, vehicleId)
    local vehicleData = inputs.getBusinessVehicleData(businessId, vehicleId)
    if not vehicleData then return nil end
    local maintenanceState, maintenanceChanged = inputs.normalizeVehicleMaintenanceState(vehicleData)
    local uiState, uiChanged = inputs.ensureMaintenanceComputerState(vehicleData)
    uiChanged = invalidateRevealedState(uiState, maintenanceState) or uiChanged
    local jobsChanged = migrateLegacyJobs(vehicleData, maintenanceState, uiState, nil)
    local _, _, cacheChanged = parts.quotes.getTrackedPartData(vehicleData, maintenanceState)
    if maintenanceChanged or uiChanged or jobsChanged or cacheChanged then
      overhaul_career_saveSystem.saveCurrent()
    end
    return vehicleData, maintenanceState, uiState
  end

  local function buildErrorResult(message)
    return {ok = false, message = message}
  end

  -- Payment -----------------------------------------------------------------------------------------

  local function serviceLabel(prefix, itemDefinition)
    return string.format("%s: %s %s", prefix, itemDefinition.actionLabel, itemDefinition.label)
  end

  local function payFromBusinessAccount(amount, itemDefinition, paymentContext)
    local businessType = paymentContext.businessType or nil
    local businessId = paymentContext.businessId or nil
    if not businessType or businessId == nil or businessId == "" then
      return false, "Business account context is missing."
    end
    local account = overhaul_career_economy_bank.getBusinessAccount(businessType, businessId)
    if not account then
      return false, "Business account not found."
    end
    local paid = overhaul_career_economy_bank.payFromAccount({
      money = { amount = amount, canBeNegative = false },
    }, account.id, "Vehicle Maintenance", serviceLabel("Maintenance", itemDefinition), require("overhaul/lib/finance/metadata").tag(nil, "repair", {vehicleId = paymentContext and paymentContext.inventoryId}))
    if not paid then
      return false, "Not enough funds in business account."
    end
    return true
  end

  local function payServicePrice(price, itemDefinition, paymentContext)
    local amount = tonumber(price) or 0
    if amount <= 0 then
      return true
    end

    local mode = paymentContext and paymentContext.mode or "player"
    if mode == "businessAccount" then
      return payFromBusinessAccount(amount, itemDefinition, paymentContext)
    end

    local priceData = {money = {amount = amount, canBeNegative = false}}
    if not overhaul_career_economy_payment.canPay(priceData) then
      return false, "Not enough money."
    end
    if not overhaul_career_economy_payment.pay(priceData, require("overhaul/lib/finance/metadata").tag({
      label = serviceLabel("Maintenance", itemDefinition),
      tags = {"maintenance", "overhaul_vehicles_maintenanceBridge", "buying"},
    }, "repair", {vehicleId = paymentContext and paymentContext.inventoryId})) then
      return false, "Payment failed."
    end

    return true
  end

  local function refundServicePrice(price, itemDefinition, paymentContext)
    local amount = tonumber(price) or 0
    if amount <= 0 then
      return true
    end

    local label = serviceLabel("Maintenance refund", itemDefinition)
    if paymentContext and paymentContext.mode == "businessAccount" then
      local account = overhaul_career_economy_bank.getBusinessAccount(paymentContext.businessType, paymentContext.businessId) or nil
      if account then
        return overhaul_career_economy_bank.rewardToAccount({money = {amount = amount}}, account.id, "Vehicle Maintenance Refund", label, require("overhaul/lib/finance/metadata").tag(nil, "refund", {vehicleId = paymentContext and paymentContext.inventoryId}))
      end
      return false
    end

    return overhaul_career_economy_payment.reward({money = {amount = amount}}, require("overhaul/lib/finance/metadata").tag({
      label = label,
      tags = {"maintenance", "overhaul_vehicles_maintenanceBridge", "refund"},
    }, "refund", {vehicleId = paymentContext and paymentContext.inventoryId}), true)
  end

  -- Actions -----------------------------------------------------------------------------------------

  -- Shared checks for one item: its hardware is fitted and its state exists. Returns an error result or nil.
  local function itemUnavailableError(vehicleData, maintenanceState, categoryName, itemName)
    if not parts.quotes.categoryHardwareIsInstalled(vehicleData, categoryName) then
      return buildErrorResult("That system is not installed on this vehicle.")
    end
    local categoryState = maintenanceState.categories[categoryName]
    if not categoryState or categoryState.maintenance[itemName] == nil then
      return buildErrorResult("Maintenance state unavailable for this item.")
    end
    return nil
  end

  -- Returns vehicle, maintenance state, ui state and the item definition, or nils with an error result last.
  local function prepareAction(inventoryId, categoryName, itemName)
    if not inputs.isMaintenanceEnabled() then
      return nil, nil, nil, nil, buildErrorResult("Maintenance mode is not enabled.")
    end

    inventoryId = tonumber(inventoryId)
    if not inventoryId then
      return nil, nil, nil, nil, buildErrorResult("Invalid vehicle.")
    end

    local itemDefinition = inputs.config.getItemDefinition(categoryName, itemName)
    if not itemDefinition then
      return nil, nil, nil, nil, buildErrorResult("Unknown maintenance item.")
    end

    local vehicleData, maintenanceState, uiState = prepareVehicleState(inventoryId)
    if not vehicleData then
      return nil, nil, nil, nil, buildErrorResult("Vehicle not found.")
    end

    local unavailable = itemUnavailableError(vehicleData, maintenanceState, categoryName, itemName)
    if unavailable then
      return nil, nil, nil, nil, unavailable
    end

    return vehicleData, maintenanceState, uiState, itemDefinition
  end

  local function prepareBusinessAction(vehicleId, categoryName, itemName, businessType, businessId)
    if not inputs.isMaintenanceEnabled() then
      return nil, nil, nil, nil, buildErrorResult("Maintenance mode is not enabled.")
    end
    if not overhaul_career_business_manager.isPurchasedBusiness(businessType, businessId) then
      return nil, nil, nil, nil, buildErrorResult("Business ownership could not be verified.")
    end
    local itemDefinition = inputs.config.getItemDefinition(categoryName, itemName)
    if not itemDefinition then return nil, nil, nil, nil, buildErrorResult("Unknown maintenance item.") end
    local vehicleData, maintenanceState, uiState = prepareBusinessVehicleState(businessId, vehicleId)
    if not vehicleData then return nil, nil, nil, nil, buildErrorResult("Fleet vehicle not found.") end
    local unavailable = itemUnavailableError(vehicleData, maintenanceState, categoryName, itemName)
    if unavailable then
      return nil, nil, nil, nil, unavailable
    end
    return vehicleData, maintenanceState, uiState, itemDefinition
  end

  local function performBusinessCheck(vehicleId, categoryName, itemName, businessType, businessId)
    local vehicleData, maintenanceState, uiState, itemDefinition, errorResult =
      prepareBusinessAction(vehicleId, categoryName, itemName, businessType, businessId)
    if errorResult then return errorResult end
    local roundedValue = inputs.roundPercent(maintenanceState.categories[categoryName].maintenance[itemName])
    revealMaintenanceItem(uiState, categoryName, itemName, roundedValue)
    overhaul_career_saveSystem.saveCurrent()
    return {ok = true, completed = true, category = categoryName, item = itemDefinition.name,
      revealedPercent = roundedValue, price = 0}
  end

  -- Prices the service, takes payment, completes the job and rolls everything back if the commit fails.
  local function performBusinessService(vehicleId, categoryName, itemName, businessType, businessId)
    local vehicleData, maintenanceState, uiState, itemDefinition, errorResult =
      prepareBusinessAction(vehicleId, categoryName, itemName, businessType, businessId)
    if errorResult then return errorResult end
    local trackedPartsValue = parts.quotes.calculateTrackedPartsValue(vehicleData, maintenanceState, categoryName)
    local price = parts.quotes.calculateServicePrice(vehicleData, maintenanceState, categoryName, itemDefinition, trackedPartsValue)
    local stateBefore = inputs.deepCopy(vehicleData.maintenanceState)
    local computerStateBefore = inputs.deepCopy(vehicleData.maintenanceComputerState)
    local paymentContext = {mode = "businessAccount", businessType = businessType, businessId = businessId}
    local paid, paymentMessage = payServicePrice(price, itemDefinition, paymentContext)
    if not paid then return buildErrorResult(paymentMessage or "Payment failed.") end
    local committed, commitError = xpcall(function()
      completeServiceJob(uiState, maintenanceState.categories[categoryName], {
        kind = "service", category = categoryName, item = itemName,
      }, itemDefinition)
      overhaul_career_saveSystem.saveCurrent()
    end, debug.traceback)
    if not committed then
      vehicleData.maintenanceState = stateBefore
      vehicleData.maintenanceComputerState = computerStateBefore
      refundServicePrice(price, itemDefinition, paymentContext)
      overhaul_career_saveSystem.saveCurrent()
      log("E", "maintenanceComputer", "Immediate business service rolled back: " .. tostring(commitError))
      return buildErrorResult("Maintenance service failed; payment was refunded.")
    end
    return {ok = true, completed = true, category = categoryName, item = itemName, price = price}
  end

  local function performCheck(inventoryId, categoryName, itemName)
    local vehicleData, maintenanceState, uiState, itemDefinition, errorResult = prepareAction(inventoryId, categoryName, itemName)
    if errorResult then
      return errorResult
    end

    local value = maintenanceState.categories[categoryName].maintenance[itemName]
    local roundedValue = inputs.roundPercent(value)
    revealMaintenanceItem(uiState, categoryName, itemName, roundedValue)
    inputs.persistVehicleMutation(vehicleData.id)
    return {
      ok = true,
      completed = true,
      category = categoryName,
      item = itemDefinition.name,
      revealedPercent = roundedValue,
      price = 0,
    }
  end

  local function performService(inventoryId, categoryName, itemName, paymentContext)
    paymentContext = require("overhaul/lib/finance/metadata").copy(paymentContext or {})
    paymentContext.inventoryId = inventoryId
    local vehicleData, maintenanceState, uiState, itemDefinition, errorResult = prepareAction(inventoryId, categoryName, itemName)
    if errorResult then
      return errorResult
    end

    local trackedPartsValue = parts.quotes.calculateTrackedPartsValue(vehicleData, maintenanceState, categoryName)
    local price = parts.quotes.calculateServicePrice(vehicleData, maintenanceState, categoryName, itemDefinition, trackedPartsValue)
    local stateBefore = inputs.deepCopy(vehicleData.maintenanceState)
    local computerStateBefore = inputs.deepCopy(vehicleData.maintenanceComputerState)
    local paid, paymentMessage = payServicePrice(price, itemDefinition, paymentContext)
    if not paid then
      return buildErrorResult(paymentMessage or "Payment failed.")
    end

    local committed, commitError = xpcall(function()
      completeServiceJob(uiState, maintenanceState.categories[categoryName], {
        kind = "service",
        category = categoryName,
        item = itemName,
      }, itemDefinition)
      syncRuntimeState(vehicleData.id)
      inputs.persistVehicleMutation(vehicleData.id)
    end, debug.traceback)

    if not committed then
      vehicleData.maintenanceState = stateBefore
      vehicleData.maintenanceComputerState = computerStateBefore
      refundServicePrice(price, itemDefinition, paymentContext)
      inputs.markVehicleDirty(vehicleData.id)
      log("E", "maintenanceComputer", "Immediate service rolled back: " .. tostring(commitError))
      return buildErrorResult("Maintenance service failed; payment was refunded.")
    end

    return {
      ok = true,
      completed = true,
      category = categoryName,
      item = itemName,
      price = price,
    }
  end

  -- Runs an action under xpcall; a failure is logged and comes back as the given error result.
  local function runGuarded(operation, failureMessage)
    local success, result = xpcall(operation, debug.traceback)
    if success then
      return result
    end
    log("E", "maintenanceComputer", tostring(result))
    return buildErrorResult(failureMessage)
  end

  -- A dyno session only allows powertrain maintenance on the vehicle it was opened for.
  local function dynoSessionRefusal(inventoryId, categoryName)
    if computerState.sessionMode ~= "dyno" then
      return nil
    end
    local sameVehicle = tonumber(inventoryId) == tonumber(computerState.activeInventoryId)
    if sameVehicle and inputs.DYNO_MAINTENANCE_CATEGORIES[tostring(categoryName)] then
      return nil
    end
    return buildErrorResult("Only powertrain maintenance is available during a dyno session.")
  end

  local function startCheck(inventoryId, categoryName, itemName)
    local refusal = dynoSessionRefusal(inventoryId, categoryName)
    if refusal then return refusal end
    return runGuarded(function()
      return performCheck(inventoryId, categoryName, itemName)
    end, "Failed to complete maintenance check.")
  end

  local function startCheckForBusinessVehicle(vehicleId, categoryName, itemName, businessType, businessId)
    return runGuarded(function()
      return performBusinessCheck(vehicleId, categoryName, itemName, businessType, businessId)
    end, "Failed to complete maintenance check.")
  end

  local function startService(inventoryId, categoryName, itemName)
    local refusal = dynoSessionRefusal(inventoryId, categoryName)
    if refusal then return refusal end
    return runGuarded(function()
      return performService(inventoryId, categoryName, itemName)
    end, "Failed to complete maintenance service.")
  end

  local function startServiceForBusinessVehicle(inventoryId, categoryName, itemName, businessType, businessId)
    return runGuarded(function()
      return performBusinessService(inventoryId, categoryName, itemName, businessType, businessId)
    end, "Failed to complete business maintenance service.")
  end

  -- Public API --------------------------------------------------------------------------------------

  return {
    buildErrorResult = buildErrorResult,
    completeServiceJob = completeServiceJob,
    payServicePrice = payServicePrice,
    prepareBusinessVehicleState = prepareBusinessVehicleState,
    prepareVehicleState = prepareVehicleState,
    refundServicePrice = refundServicePrice,
    startCheck = startCheck,
    startCheckForBusinessVehicle = startCheckForBusinessVehicle,
    startService = startService,
    startServiceForBusinessVehicle = startServiceForBusinessVehicle,
    syncRuntimeState = syncRuntimeState,
  }
end

return partFactory
