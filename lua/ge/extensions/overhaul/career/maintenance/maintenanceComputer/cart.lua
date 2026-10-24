-- Maintenance cart: checkout of services and tyres, plus the tyre inspection and replacement entry points.
-- Part of the maintenance computer; the shared part table keeps services on the same load.
local partFactory = {}

function partFactory.new(inputs)
  local computerState = inputs.state

  local parts = inputs.parts

  -- Lists and cart payloads -------------------------------------------------------------------------

  local function tableToList(value)
    if type(value) ~= "table" then
      return {}
    end
    if value[1] ~= nil then
      local list = {}
      for index = 1, #value do
        list[index] = value[index]
      end
      return list
    end
    local list = {}
    for _, nested in pairs(value) do
      table.insert(list, nested)
    end
    return list
  end

  -- Keeps one entry per known category and item, and drops services a fuller entry already covers.
  local function filterCartServices(rawServices)
    local byKey = {}
    local ordered = {}
    for _, entry in ipairs(tableToList(rawServices)) do
      local categoryName = entry and entry.category
      local itemName = entry and entry.item
      local definition = inputs.config.getItemDefinition(categoryName, itemName)
      if definition then
        local key = tostring(categoryName) .. ":" .. tostring(itemName)
        if not byKey[key] then
          local filtered = {
            category = categoryName,
            item = itemName,
            definition = definition,
          }
          byKey[key] = filtered
          table.insert(ordered, filtered)
        end
      end
    end

    local covered = {}
    for _, entry in ipairs(ordered) do
      if entry.definition.fillsItem then
        covered[entry.category .. ":" .. entry.definition.fillsItem] = true
      end
    end

    local filtered = {}
    for _, entry in ipairs(ordered) do
      if not covered[entry.category .. ":" .. entry.item] then
        table.insert(filtered, entry)
      end
    end
    return filtered
  end

  local function payCartTotal(amount, paymentContext)
    amount = tonumber(amount) or 0
    if amount <= 0 then
      return true
    end
    return parts.services.payServicePrice(amount, {actionLabel = "Checkout", label = "cart"}, paymentContext)
  end

  local function refundCartTotal(amount, paymentContext)
    amount = tonumber(amount) or 0
    if amount <= 0 then
      return true
    end
    return parts.services.refundServicePrice(amount, {actionLabel = "Checkout", label = "cart"}, paymentContext)
  end

  local function decodeCartPayload(cartOrServices, tireAxleIds, quoteRevision)
    if type(cartOrServices) == "string" then
      local decoded = jsonDecode(cartOrServices)
      if type(decoded) ~= "table" then
        return nil, parts.services.buildErrorResult("Invalid checkout payload.")
      end
      return decoded
    end
    if type(cartOrServices) == "table" and (cartOrServices.services ~= nil or cartOrServices.tireAxleIds ~= nil) then
      return cartOrServices
    end
    return {
      services = cartOrServices,
      tireAxleIds = tireAxleIds,
      quoteRevision = quoteRevision,
    }
  end

  -- Pricing ------------------------------------------------------------------------------------------

  -- Prices each service and returns the total, or an error result at the first item the vehicle cannot take.
  local function priceCartServices(vehicleData, maintenanceState, services)
    local serviceTotal = 0
    for _, entry in ipairs(services) do
      local categoryState = maintenanceState.categories[entry.category]
      if not categoryState or categoryState.maintenance[entry.item] == nil then
        return nil, parts.services.buildErrorResult("Maintenance state unavailable for " .. entry.definition.label .. ".")
      end
      local trackedPartsValue = parts.quotes.calculateTrackedPartsValue(vehicleData, maintenanceState, entry.category)
      entry.price = parts.quotes.calculateServicePrice(vehicleData, maintenanceState, entry.category, entry.definition, trackedPartsValue)
      serviceTotal = serviceTotal + (tonumber(entry.price) or 0)
    end
    return serviceTotal
  end

  -- Returns the subtotal of the chosen axles, or an error result when the tyre quote cannot be honoured.
  local function priceCartTires(inventoryId, cart, tireAxleIds)
    local tireUi = overhaul_career_maintenance_tireSystem.buildUiData(inventoryId) or {available = false}
    if not tireUi.available then
      return nil, parts.services.buildErrorResult(tireUi.message or "Tire replacement is unavailable.")
    end
    if not tireUi.inspected then
      return nil, parts.services.buildErrorResult("Check all tires before replacing them.")
    end
    if tostring(cart.quoteRevision or "") ~= tostring(tireUi.quoteRevision or "") then
      return nil, {ok = false, staleQuote = true, message = "Tire condition or pricing changed. Review the updated quote."}
    end

    local wanted = {}
    for _, axleId in ipairs(tireAxleIds) do
      wanted[tostring(axleId)] = true
    end
    local tireTotal = 0
    local matched = 0
    for _, axle in ipairs(tireUi.axles or {}) do
      if wanted[tostring(axle.id)] then
        tireTotal = tireTotal + (tonumber(axle.subtotal) or 0)
        matched = matched + 1
        wanted[tostring(axle.id)] = nil
      end
    end
    if matched == 0 then
      return nil, parts.services.buildErrorResult("Select at least one axle.")
    end
    return tireTotal
  end

  -- Commit and rollback -----------------------------------------------------------------------------

  -- Completes the services and fits the tyres. Tyre checkout commits and saves its own charge. Returns committed, error and whether the tyres were already fitted.
  local function commitCartChanges(inventoryId, vehicleData, maintenanceState, uiState, services, tireAxleIds, quoteRevision)
    local tiresCommitted = false
    local committed, commitError = xpcall(function()
      for _, entry in ipairs(services) do
        parts.services.completeServiceJob(uiState, maintenanceState.categories[entry.category], {
          kind = "service",
          category = entry.category,
          item = entry.item,
        }, entry.definition)
      end

      if #tireAxleIds > 0 then
        local tireResult = overhaul_career_maintenance_tireSystem.checkout(inventoryId, tireAxleIds, quoteRevision, {skipPayment = true})
        if not tireResult or not tireResult.ok then
          error(tireResult and tireResult.message or "Tire replacement failed.")
        end
        tiresCommitted = true
      end

      -- Sync completed services after tire checkout so its runtime refresh cannot leave stale maintenance state.
      parts.services.syncRuntimeState(vehicleData.id)
      inputs.persistVehicleMutation(vehicleData.id)
    end, debug.traceback)
    return committed, commitError, tiresCommitted
  end

  local function rollBackCartCheckout(vehicleData, stateBefore, computerStateBefore, refundAmount, paymentContext, commitError, tiresCommitted)
    vehicleData.maintenanceState = stateBefore
    vehicleData.maintenanceComputerState = computerStateBefore
    refundCartTotal(refundAmount, paymentContext)
    inputs.markVehicleDirty(vehicleData.id)
    log("E", "maintenanceComputer", "Cart checkout rolled back: " .. tostring(commitError))
    if tiresCommitted then
      return parts.services.buildErrorResult("Maintenance checkout failed after the tires were fitted; the service payment was refunded.")
    end
    return parts.services.buildErrorResult("Maintenance checkout failed; payment was refunded.")
  end

  local function logCartCheckout(inventoryId, total, services, tireAxleIds, maintenanceState)
    local serviced = {}
    for _, entry in ipairs(services) do
      local value = maintenanceState.categories[entry.category].maintenance[entry.item]
      table.insert(serviced, string.format("%s.%s=%.3f", entry.category, entry.item, tonumber(value) or -1))
    end
    log("I", "maintenanceComputer", string.format("Cart checkout: inventory=%s total=%s tires=%d services=%d [%s]",
      tostring(inventoryId), tostring(total), #tireAxleIds, #services, table.concat(serviced, " ")))
  end

  -- Checkout ----------------------------------------------------------------------------------------

  -- Runs a checkout or tyre call under xpcall; a failure is logged and comes back as the given error result.
  local function runCartAction(operation, failureMessage)
    local success, result = xpcall(operation, debug.traceback)
    if success then return result end
    log("E", "maintenanceComputer", tostring(result))
    return parts.services.buildErrorResult(failureMessage)
  end

  local function performCartCheckout(inventoryId, cart)
    cart = cart or {}
    local services = filterCartServices(cart.services)
    local tireAxleIds = tableToList(cart.tireAxleIds)
    if #services == 0 and #tireAxleIds == 0 then
      return parts.services.buildErrorResult("Cart is empty.")
    end

    inventoryId = tonumber(inventoryId)
    if not inventoryId then
      return parts.services.buildErrorResult("Invalid vehicle.")
    end

    local vehicleData, maintenanceState, uiState = parts.services.prepareVehicleState(inventoryId)
    if not vehicleData then
      return parts.services.buildErrorResult("Vehicle not found.")
    end

    local serviceTotal, serviceError = priceCartServices(vehicleData, maintenanceState, services)
    if serviceError then return serviceError end

    local tireTotal = 0
    if #tireAxleIds > 0 then
      local tireError
      tireTotal, tireError = priceCartTires(inventoryId, cart, tireAxleIds)
      if tireError then return tireError end
    end

    local total = serviceTotal + tireTotal
    local stateBefore = inputs.deepCopy(vehicleData.maintenanceState)
    local computerStateBefore = inputs.deepCopy(vehicleData.maintenanceComputerState)
    local paid, paymentMessage = payCartTotal(total)
    if not paid then
      return parts.services.buildErrorResult(paymentMessage or "Payment failed.")
    end

    local committed, commitError, tiresCommitted = commitCartChanges(
      inventoryId, vehicleData, maintenanceState, uiState, services, tireAxleIds, cart.quoteRevision)
    if not committed then
      local refundAmount = tiresCommitted and serviceTotal or total
      return rollBackCartCheckout(vehicleData, stateBefore, computerStateBefore, refundAmount, nil, commitError, tiresCommitted)
    end

    logCartCheckout(inventoryId, total, services, tireAxleIds, maintenanceState)
    parts.closeMenu()
    return {
      ok = true,
      completed = true,
      price = total,
      serviceCount = #services,
      tireCount = #tireAxleIds,
    }
  end

  -- A dyno session only allows powertrain services on the vehicle it was opened for and no tyres.
  local function dynoCartRefusal(inventoryId, cart)
    if computerState.sessionMode ~= "dyno" then
      return nil
    end
    if tonumber(inventoryId) ~= tonumber(computerState.activeInventoryId) then
      return parts.services.buildErrorResult("The dyno maintenance vehicle changed.")
    end
    if #tableToList(cart.tireAxleIds) > 0 then
      return parts.services.buildErrorResult("Tire service is not available during a dyno session.")
    end
    for _, entry in ipairs(tableToList(cart.services)) do
      if not entry or not inputs.DYNO_MAINTENANCE_CATEGORIES[tostring(entry.category)] then
        return parts.services.buildErrorResult("Only powertrain maintenance is available during a dyno session.")
      end
    end
    return nil
  end

  local function checkoutCart(inventoryId, cartOrServices, tireAxleIds, quoteRevision)
    local cart, payloadError = decodeCartPayload(cartOrServices, tireAxleIds, quoteRevision)
    if payloadError then
      return payloadError
    end
    local refusal = dynoCartRefusal(inventoryId, cart)
    if refusal then return refusal end
    return runCartAction(function()
      return performCartCheckout(inventoryId, cart)
    end, "Failed to complete maintenance checkout.")
  end

  -- Tyre entry points -------------------------------------------------------------------------------

  local function tyreServiceRefusal()
    if computerState.sessionMode == "dyno" then
      return parts.services.buildErrorResult("Tire service is not available during a dyno session.")
    end
    return nil
  end

  local function inspectTires(inventoryId)
    local refusal = tyreServiceRefusal()
    if refusal then return refusal end
    return runCartAction(function()
      return overhaul_career_maintenance_tireSystem.inspectAll(inventoryId)
    end, "Failed to inspect tires.")
  end

  local function inspectBusinessVehicleTires(vehicleId, businessType, businessId)
    return runCartAction(function()
      if not overhaul_career_business_manager.isPurchasedBusiness(businessType, businessId) then
        return parts.services.buildErrorResult("Business ownership could not be verified.")
      end
      return overhaul_career_maintenance_tireSystem.inspectBusiness(businessId, vehicleId)
    end, "Failed to inspect fleet tires.")
  end

  local function checkoutTires(inventoryId, axleIds, quoteRevision)
    local refusal = tyreServiceRefusal()
    if refusal then return refusal end
    return runCartAction(function()
      return overhaul_career_maintenance_tireSystem.checkout(inventoryId, axleIds, quoteRevision)
    end, "Failed to replace tires.")
  end

  local function checkoutTiresForBusinessVehicle(inventoryId, axleIds, quoteRevision, businessType, businessId)
    return runCartAction(function()
      return overhaul_career_maintenance_tireSystem.checkoutBusiness(businessType, businessId, inventoryId, axleIds, quoteRevision)
    end, "Failed to replace business vehicle tires.")
  end

  -- Public API --------------------------------------------------------------------------------------

  return {
    checkoutCart = checkoutCart,
    checkoutTires = checkoutTires,
    checkoutTiresForBusinessVehicle = checkoutTiresForBusinessVehicle,
    inspectBusinessVehicleTires = inspectBusinessVehicleTires,
    inspectTires = inspectTires,
  }
end

return partFactory
