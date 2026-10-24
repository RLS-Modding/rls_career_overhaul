-- Maintenance computer UI data: the screen payload for a personal vehicle or a business fleet vehicle.
-- Part of the maintenance computer; the shared part table keeps quote and state helpers on the same load.
local partFactory = {}

function partFactory.new(inputs)
  local computerState = inputs.state

  local parts = inputs.parts

  local function getPlayerMoney()
    return overhaul_career_economy_playerAttributes.getAttributeValue("money") or 0
  end

  local function buildFacilityName()
    if computerState.sessionMode == "dyno" then
      return "Dyno Powertrain Maintenance"
    end
    if computerState.originComputerId then
      local computer = overhaul_world_facilities.getFacility("computer", computerState.originComputerId)
      return computer and computer.name or "Maintenance"
    end
    return "Maintenance"
  end

  local function buildUiRow(vehicleData, maintenanceState, uiState, categoryName, itemDefinition)
    local itemValue = maintenanceState.categories[categoryName].maintenance[itemDefinition.name] or 0
    local roundedValue = inputs.roundPercent(itemValue)
    local revealedState = uiState.revealed[categoryName][itemDefinition.name]
    local trackedPartsValue, trackedPartIds = parts.quotes.calculateTrackedPartsValue(vehicleData, maintenanceState, categoryName)
    local servicePrice, pricingBreakdown = parts.quotes.calculateServicePrice(vehicleData, maintenanceState, categoryName, itemDefinition, trackedPartsValue)
    local canAffordService = true

    if servicePrice > 0 then
      canAffordService = overhaul_career_economy_payment.canPay({money = {amount = servicePrice, canBeNegative = false}})
    end

    return {
      category = categoryName,
      item = itemDefinition.name,
      label = itemDefinition.label,
      actionLabel = itemDefinition.actionLabel,
      roundedPercent = roundedValue,
      revealedPercent = type(revealedState) == "table" and tonumber(revealedState.roundedPercent) or nil,
      isRevealed = type(revealedState) == "table",
      servicePricePct = itemDefinition.servicePricePct,
      servicePrice = servicePrice,
      pricingBreakdown = pricingBreakdown,
      canAffordService = canAffordService,
      fillsItem = itemDefinition.fillsItem,
      trackedPartsValue = trackedPartsValue,
      trackedPartCount = #(trackedPartIds or {}),
    }
  end

  local function buildCategoryUiData(vehicleData, maintenanceState, uiState, categoryName)
    local categoryState = maintenanceState.categories[categoryName]
    local rows = {}
    for _, itemDefinition in ipairs(inputs.config.categoryDefinitions[categoryName].items) do
      table.insert(rows, buildUiRow(vehicleData, maintenanceState, uiState, categoryName, itemDefinition))
    end

    return {
      name = categoryName,
      label = inputs.config.categoryDefinitions[categoryName].label,
      avgMiles = inputs.roundMoney((tonumber(categoryState.avgOdometer) or 0) * inputs.metersToMiles),
      wearRatio = math.min(1, inputs.max(0, inputs.partCategories.getClassAgeMiles(
        (tonumber(categoryState.avgOdometer) or 0) * inputs.metersToMiles, maintenanceState.profile) / 250000)),
      rows = rows,
    }
  end

  -- Lists the categories whose hardware is fitted, in display order.
  local function buildInstalledCategories(vehicleData, maintenanceState, uiState)
    local categories = {}
    for _, categoryName in ipairs(inputs.config.categoryOrder) do
      if parts.quotes.categoryHardwareIsInstalled(vehicleData, categoryName) then
        table.insert(categories, buildCategoryUiData(vehicleData, maintenanceState, uiState, categoryName))
      end
    end
    return categories
  end

  local function buildMaintenanceUiDataForInventory(inventoryId)
    if not inputs.isMaintenanceEnabled() then
      return {enabled = false}
    end

    inventoryId = tonumber(inventoryId)
    if not inventoryId then
      return {enabled = false}
    end

    local vehicleData, maintenanceState, uiState = parts.services.prepareVehicleState(inventoryId, {
      persistChanges = false,
      persistCompletedJobs = true,
      markDirtyOnChange = true,
    })
    if not vehicleData then
      return {enabled = false}
    end

    local vehicleUiData = overhaul_career_garage_inventory.getVehicleUiData(inventoryId) or inputs.deepCopy(vehicleData)

    local categories = buildInstalledCategories(vehicleData, maintenanceState, uiState)
    local tireShop = nil
    if computerState.sessionMode ~= "dyno" then
      tireShop = overhaul_career_maintenance_tireSystem.buildUiData(inventoryId) or {available = false}
    end

    return {
      enabled = true,
      facilityName = buildFacilityName(),
      inventoryId = tostring(inventoryId),
      vehicle = vehicleUiData,
      maintenanceProfile = inputs.deepCopy(maintenanceState.profile),
      categories = categories,
      playerMoney = getPlayerMoney(),
      sessionMode = computerState.sessionMode,
      tireShop = tireShop,
    }
  end

  local function buildMaintenanceUiDataForBusinessVehicle(vehicleId, businessType, businessId)
    if not inputs.isMaintenanceEnabled() then return {enabled = false} end
    if not businessType or businessId == nil or vehicleId == nil then
      return {enabled = false, errorMessage = "Business vehicle context is missing."}
    end
    if not overhaul_career_business_manager.isPurchasedBusiness(businessType, businessId) then
      return {enabled = false, errorMessage = "Business ownership could not be verified."}
    end
    local vehicleData, maintenanceState, uiState = parts.services.prepareBusinessVehicleState(businessId, vehicleId)
    if not vehicleData then return {enabled = false, errorMessage = "Fleet vehicle not found."} end
    -- Categories first: building them can refresh cached part ids, which the vehicle copy must include.
    local categories = buildInstalledCategories(vehicleData, maintenanceState, uiState)
    return {
      enabled = true,
      facilityName = buildFacilityName(),
      inventoryId = tostring(vehicleId),
      vehicle = inputs.deepCopy(vehicleData),
      maintenanceProfile = inputs.deepCopy(maintenanceState.profile),
      categories = categories,
      playerMoney = getPlayerMoney(),
      tireShop = overhaul_career_maintenance_tireSystem.buildBusinessUiData(businessId, vehicleId),
    }
  end

  -- Runs a UI build under xpcall; a failure is logged and comes back as a disabled screen with the given message.
  local function buildGuarded(operation, failureMessage)
    local success, result = xpcall(operation, debug.traceback)
    if success then
      return result
    end
    log("E", "maintenanceComputer", tostring(result))
    return {
      enabled = false,
      errorMessage = failureMessage,
      debugError = tostring(result),
    }
  end

  local function getMaintenanceUiData()
    return buildMaintenanceUiDataForInventory(computerState.activeInventoryId)
  end

  return {
    getMaintenanceUiDataForBusinessVehicleSafe = function(vehicleId, businessType, businessId)
      return buildGuarded(function()
        return buildMaintenanceUiDataForBusinessVehicle(vehicleId, businessType, businessId)
      end, "Business maintenance data failed to load.")
    end,
    getMaintenanceUiDataForInventorySafe = function(inventoryId)
      return buildGuarded(function()
        return buildMaintenanceUiDataForInventory(inventoryId)
      end, "Maintenance data failed to load.")
    end,
    getMaintenanceUiDataSafe = function()
      return buildGuarded(getMaintenanceUiData, "Maintenance data failed to load.")
    end,
  }
end

return partFactory
