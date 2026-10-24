-- Roadside service: spot eligibility, repair selection, payment and screen data.
-- State, level config and vehicle helpers; repair quotes and UI; services, menu state, public API and hooks.

local M = {}
local repairConfig = require('overhaul/lib/repair/operationSettings')

-- State -------------------------------------------------------------------------------------------

local config = nil
local configLevelId = nil

local activeInventoryId = nil
local activeTriggerName = nil
local repairOperation
local repairState = {status = 'idle'}

local function publishRepairState(inventoryId, status, result)
  repairState = {inventoryId = tostring(inventoryId), status = status,
    message = result.message, cost = result.cost, refunded = result.refunded}
  guihooks.trigger('roadsideServiceRepairState', repairState)
end

-- Level config ------------------------------------------------------------------------------------

local function configPathForLevel(levelId)
  return levelId and ("/levels/" .. levelId .. "/facilities/roadsideService.json") or nil
end

local function loadConfig(force)
  local levelId = getCurrentLevelIdentifier()
  if not force and config and configLevelId == levelId then
    return config
  end

  configLevelId = levelId
  local path = configPathForLevel(levelId)
  config = path and jsonReadFile(path)
  if type(config) ~= "table" then
    log("W", "roadsideService", "No roadside services configured for " .. tostring(levelId))
    config = {}
  end
  config.default = type(config.default) == "table" and config.default or {}
  config.spots = type(config.spots) == "table" and config.spots or {}
  for name, spot in pairs(config.spots) do
    local services = type(spot) == "table" and (spot.services or config.default.services)
    local multiplier = type(spot) == "table" and (spot.laborMultiplier or config.default.laborMultiplier or 1)
    if type(name) ~= "string" or name == "" or type(services) ~= "table"
      or type(multiplier) ~= "number" or multiplier <= 0 or multiplier ~= multiplier then
      log("W", "roadsideService", "Ignoring invalid service record: " .. tostring(name))
      config.spots[name] = nil
    end
  end
  return config
end

local function getSpotConfig(triggerName)
  loadConfig()
  local spotCfg = config.spots[triggerName]
  if not spotCfg then return {services = {}, name = "Service Spot", laborMultiplier = 1} end
  return {
    services = spotCfg.services or config.default.services or {},
    laborMultiplier = spotCfg.laborMultiplier or config.default.laborMultiplier or 1,
    name = spotCfg.name or "Service Spot",
  }
end

local function hasService(triggerName, serviceName)
  local spotCfg = getSpotConfig(triggerName)
  for _, svc in ipairs(spotCfg.services or {}) do
    if svc == serviceName then return true end
  end
  return false
end

-- Vehicle and money helpers -----------------------------------------------------------------------

local function getVehicleRecord(inventoryId)
  local vehicles = overhaul_career_garage_inventory.getVehicles() or {}
  return vehicles[tonumber(inventoryId)] or vehicles[tostring(inventoryId)]
end

local function buildVehicleSummary(inventoryId)
  local vehicle = getVehicleRecord(inventoryId)
  if not vehicle then
    return nil
  end

  local niceName = overhaul_career_garage_inventory.getVehicleNiceNameTranslated(inventoryId)

  -- photo for the roadside screen header (same thumbnail the vehicle inventory uses)
  local thumbnail = overhaul_career_garage_inventory.getVehicleThumbnail(inventoryId)

  return {
    niceName = niceName or vehicle.niceName or vehicle.model or "Vehicle",
    model = vehicle.model,
    mileage = tonumber(vehicle.mileage) or 0,
    thumbnail = thumbnail,
  }
end

local function getPlayerMoney()
  return overhaul_career_economy_playerAttributes.getAttributeValue("money") or 0
end

local function isMaintenanceEnabled()
  return overhaul_career_maintenance_maintenanceMode.isEnabled() == true
end

local function ensureFiniteDamage()
  if not overhaul_career_repair_finiteDamage then
    extensions.load("overhaul_career_repair_finiteDamage")
  end
  return overhaul_career_repair_finiteDamage
end

local function vehicleNeedsRoadsideRepair(inventoryId)
  local finite = ensureFiniteDamage()
  return finite.hasRepairableDamage(inventoryId)
end

-- Finite-only jobs stay cheap: a lighter labor bump than full part-replace jobs.
local function laborMultiplierForQuote(spotCfg, hasBrokenParts)
  local laborMult = tonumber(spotCfg.laborMultiplier) or 1.25
  if not hasBrokenParts then
    laborMult = math.min(laborMult, 1.1)
  end
  return laborMult
end

-- Tuning is blocked at spots that also repair, so a damaged car cannot dodge the free minor-damage fix.
local function tuningNeedsRepairFirst()
  return hasService(activeTriggerName, "repair") and vehicleNeedsRoadsideRepair(activeInventoryId)
end

-- Repair quote -----------------------------------------------------------------------------------

local function buildRepairData(inventoryId)
  local vehicle = getVehicleRecord(inventoryId)
  if not vehicle then
    return {available = false, reason = "Vehicle not found."}
  end

  -- Fully broken parts (stock replace price) plus finite soft damage / cosmetics / tires. Do not require insurance "needs repair" (≥3 broken) so spots can fix small damage.
  local finite = ensureFiniteDamage()
  local assessment = finite.assess(inventoryId)
  if not assessment or not assessment.hasDamage then
    return {available = false, reason = (assessment and assessment.reason) or "No damage to repair."}
  end

  local baseCost = tonumber(assessment.totalPreLabor) or 0
  local spotCfg = getSpotConfig(activeTriggerName)
  local laborMult = laborMultiplierForQuote(spotCfg, assessment.hasBrokenParts == true)
  local adjustedCost = math.ceil(baseCost * laborMult)

  return {
    available = true,
    baseCost = baseCost,
    laborMultiplier = laborMult,
    totalCost = adjustedCost,
    canAfford = getPlayerMoney() >= adjustedCost,
    hasTireDamage = assessment.hasTireDamage == true,
    hasFiniteDamage = assessment.hasFiniteDamage == true,
    hasBrokenParts = assessment.hasBrokenParts == true,
    brokenParts = tonumber(assessment.brokenParts) or 0,
    brokenPartsCost = tonumber(assessment.brokenPartsCost) or 0,
    finiteCost = tonumber(assessment.finiteCost) or 0,
    finiteMinimum = tonumber(assessment.finiteMinimum) or 40,
    damageLines = assessment.lines or {},
  }
end

-- UI payload -------------------------------------------------------------------------------------

local function repairServiceUi(inventoryId)
  local repairData = buildRepairData(inventoryId) or {}
  return {
    id = "repair",
    label = "Repair",
    description = "Fix vehicle damage",
    available = repairData.available == true,
    reason = repairData.reason,
    cost = tonumber(repairData.totalCost) or 0,
    canAfford = repairData.canAfford == true,
    laborMultiplier = tonumber(repairData.laborMultiplier) or 1.25,
    hasBrokenParts = repairData.hasBrokenParts == true,
    hasFiniteDamage = repairData.hasFiniteDamage == true,
    hasTireDamage = repairData.hasTireDamage == true,
    brokenParts = tonumber(repairData.brokenParts) or 0,
    brokenPartsCost = tonumber(repairData.brokenPartsCost) or 0,
    finiteCost = tonumber(repairData.finiteCost) or 0,
    finiteMinimum = tonumber(repairData.finiteMinimum) or 40,
    damageLines = repairData.damageLines or {},
  }
end

local function maintenanceServiceUi()
  local maintEnabled = isMaintenanceEnabled()
  return {
    id = "maintenance",
    label = "Maintenance",
    description = "Service fluids and check vehicle systems",
    available = maintEnabled,
    reason = not maintEnabled and "Maintenance mode is disabled." or nil,
  }
end

local function tuningServiceUi()
  local mustRepairFirst = tuningNeedsRepairFirst()
  return {
    id = "tuning",
    label = "Tuning",
    description = "Adjust suspension, alignment, and more",
    available = not mustRepairFirst,
    reason = mustRepairFirst and "Repair the vehicle first." or nil,
  }
end

local function buildUiData()
  if not activeInventoryId then
    return {error = "No vehicle selected."}
  end

  local spotCfg = getSpotConfig(activeTriggerName)
  local vehicleSummary = buildVehicleSummary(activeInventoryId)

  local services = {}
  for _, svc in ipairs(spotCfg.services or {}) do
    if svc == "repair" then
      services.repair = repairServiceUi(activeInventoryId)
    elseif svc == "maintenance" then
      services.maintenance = maintenanceServiceUi()
    elseif svc == "tuning" then
      services.tuning = tuningServiceUi()
    end
  end

  return {
    inventoryId = tostring(activeInventoryId),
    triggerName = activeTriggerName,
    spotName = spotCfg.name,
    vehicle = vehicleSummary,
    services = services,
    playerMoney = getPlayerMoney(),
    laborMultiplier = tonumber(spotCfg.laborMultiplier) or 1.25,
    repairState = repairState.inventoryId == tostring(activeInventoryId) and repairState or {status = 'idle'},
  }
end

local function getUiData()
  local success, result = xpcall(buildUiData, debug.traceback)
  if success then return result end
  log("E", "roadsideServiceComputer", tostring(result))
  return {error = "Failed to load service data.", debugError = tostring(result)}
end

-- Repair -----------------------------------------------------------------------------------------

local function refundRepair(amount, inventoryId)
  if not amount or amount <= 0 then
    return
  end
  overhaul_career_economy_payment.pay({money = {amount = -amount, canBeNegative = true}}, require("overhaul/lib/finance/metadata").tag({label = "Roadside repair refund: id " .. tostring(inventoryId)}, "refund", {vehicleId = inventoryId}))
end

-- Refunds the share of the price that belongs to lines the repair could not finish.
local function failedRepairCost(applied, cost, laborMult)
  local failedCost = 0
  for _, line in ipairs(applied and applied.failedLines or {}) do
    failedCost = failedCost + (tonumber(line.cost) or 0)
  end
  return math.min(cost, math.ceil(failedCost * laborMult))
end

-- Only successful tyre lines from the paid selection may edit the captured snapshot.
local function paidTireNames(paidLines, applied)
  local failed, selected, names = {}, {}, {}
  for _, line in ipairs(applied.failedLines or {}) do if line.id then failed[line.id] = true end end
  for _, line in ipairs(applied.quote and applied.quote.selectedLines or {}) do
    if line.kind == "tire" and line.id then selected[line.id] = line.wheelName end
  end
  for _, line in ipairs(paidLines) do
    if line.kind == "tire" and line.wheelName and not failed[line.id] and selected[line.id] == line.wheelName then
      names[line.wheelName] = true
    end
  end
  return names
end

-- Prices the quoted repair; returns the cost and the labor multiplier, or nil when nothing is owed.
local function quoteRepairCost(quote)
  local spotCfg = getSpotConfig(activeTriggerName)
  local laborMult = laborMultiplierForQuote(spotCfg, quote.hasBrokenParts == true)
  local cost = math.ceil((tonumber(quote.totalPreLabor) or 0) * laborMult)
  return cost, laborMult
end

local function performRepair()
  if repairOperation then return {ok = false, message = "A repair is already in progress."} end
  if not activeInventoryId or not activeTriggerName then
    return {ok = false, message = "No vehicle or service station selected."}
  end

  if not hasService(activeTriggerName, "repair") then
    return {ok = false, message = "Repair not available at this location."}
  end

  local inventoryId = activeInventoryId
  local originalRecord = getVehicleRecord(inventoryId)
  local originalBinding = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId)
  local originalLevel = getCurrentLevelIdentifier()
  if not originalRecord then return {ok = false, message = "Vehicle not found."} end
  local function originalVehicle()
    return getVehicleRecord(inventoryId) == originalRecord
      and overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId) == originalBinding
      and getCurrentLevelIdentifier() == originalLevel
  end
  local finite = ensureFiniteDamage()
  -- Always repair everything on the quote — no per-part selection.
  local quote = finite.quoteSelection(inventoryId, nil)
  if not quote or not quote.ok then
    return {ok = false, message = (quote and quote.message) or "Nothing to repair."}
  end

  local cost, laborMult = quoteRepairCost(quote)
  if cost <= 0 then
    return {ok = false, message = "Nothing to repair."}
  end
  if getPlayerMoney() < cost then
    return {ok = false, message = "Not enough money."}
  end

  -- Capture can yield while the menu and assessment change. Keep the paid IDs and tyre names.
  local paidLines, selectedIds = {}, {}
  for _, line in ipairs(quote.selectedLines or {}) do
    if line.id then
      selectedIds[#selectedIds + 1] = line.id
      paidLines[#paidLines + 1] = {id = line.id, kind = line.kind, wheelName = line.wheelName}
    end
  end
  if #selectedIds == 0 or not originalVehicle() then
    return {ok = false, message = "Vehicle or repair quote changed."}
  end
  local operation = {elapsed = 0}
  repairOperation = operation
  local paid = overhaul_career_economy_payment.pay({money = {amount = cost, canBeNegative = false}}, require("overhaul/lib/finance/metadata").tag({label = "Roadside repair: id " .. tostring(inventoryId)}, "repair", {vehicleId = inventoryId}))
  if not paid then
    repairOperation = nil
    return {ok = false, message = "Not enough money."}
  end

  Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Buy_01')
  publishRepairState(inventoryId, 'pending', {message = 'Repair in progress. Please wait.'})

  local settled, committed, applied, result = false, false, nil, nil
  local function complete(success, reason)
    if settled then return end
    settled = true
    if repairOperation == operation then repairOperation = nil end
    if success == false and not committed then
      refundRepair(cost, inventoryId)
      result = {ok = false, refunded = cost,
        message = 'Repair failed. Your payment was refunded. ' .. (reason or 'Unable to complete repair.')}
    else
      refundRepair(failedRepairCost(applied, cost, laborMult), inventoryId)
      if success == false then
        -- The paid snapshot must not be overwritten by another capture of the failed live car.
        if getVehicleRecord(inventoryId) == originalRecord then
          local vehId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId)
          if vehId and getObjectByID(vehId) then
            overhaul_career_garage_inventory.removeVehicleObject(inventoryId, true)
          end
          if not overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId) then
            overhaul_career_saveSystem.saveCurrent({inventoryId})
          end
        end
        local message = "Repair saved, but vehicle replacement failed. Retrieve the vehicle from inventory."
        log("W", "roadsideService", message .. " " .. tostring(reason))
        result = {ok = false, cost = cost, message = message}
      else
        result = {ok = true, cost = cost, message = "Vehicle repaired."}
      end
    end
    publishRepairState(inventoryId, result.ok and 'succeeded' or 'failed', result)
    ui_fadeScreen.stop(0.5)
  end
  operation.cancel = function(reason)
    if settled then return end
    log('W', 'roadsideService', reason .. ': id ' .. tostring(inventoryId))
    complete(false, reason)
  end
  local function prepareReplacement()
    if settled or not originalVehicle() then return false end
    applied = finite.applySelection(inventoryId, selectedIds, function(prepared)
      local names = paidTireNames(paidLines, prepared)
      if next(names) and overhaul_career_repair_damageManager.repairTireDamage(inventoryId, names) ~= true then
        return false
      end
      committed = true
      return true
    end)
    if not applied or not applied.ok then return false end
    return true
  end

  ui_fadeScreen.start(0.5)
  local ok, err = pcall(function()
    if originalBinding then
      overhaul_career_garage_inventory.spawnVehicle(inventoryId, 2, complete, nil, nil,
        {prepareReplacement = prepareReplacement})
    else
      complete(prepareReplacement())
    end
  end)
  if not ok then complete(false, tostring(err)) end
  return result or {ok = true, cost = cost, pending = true, message = "Repair in progress."}
end

-- Other services ---------------------------------------------------------------------------------

local function openMaintenance()
  if not activeInventoryId or not activeTriggerName then
    return {ok = false, message = "No vehicle or service station selected."}
  end

  if not hasService(activeTriggerName, "maintenance") then
    return {ok = false, message = "Maintenance not available at this location."}
  end

  if not isMaintenanceEnabled() then
    return {ok = false, message = "Maintenance mode is disabled."}
  end

  overhaul_career_maintenance_maintenanceComputer.openMenuFromComputer(activeInventoryId, nil, "roadside-service")
  return {ok = true}
end

local function openTuning()
  if not activeInventoryId or not activeTriggerName then
    return {ok = false, message = "No vehicle or service station selected."}
  end

  if not hasService(activeTriggerName, "tuning") then
    return {ok = false, message = "Tuning not available at this location."}
  end

  if tuningNeedsRepairFirst() then
    return {ok = false, message = "Repair the vehicle first."}
  end

  -- Third arg is returnRoute: back from tuning returns to Roadside Service.
  overhaul_career_parts_tuning.start(activeInventoryId, nil, "roadside-service")
  return {ok = true}
end

-- Menu state -------------------------------------------------------------------------------------

local function openMenu(inventoryId, triggerName)

  if not overhaul_career_career.isActive() then
    log("W", "roadsideServiceComputer", "Career not active, cannot open menu")
    return false
  end

  activeInventoryId = tonumber(inventoryId)
  activeTriggerName = triggerName

  if not activeInventoryId then
    log("W", "roadsideServiceComputer", "No valid inventory ID")
    return false
  end

  extensions.ui_router.navigate('roadside-service')
  return true
end

local function closeMenu()
  activeInventoryId = nil
  activeTriggerName = nil
  overhaul_career_career.closeAllMenus()
end

local function getActiveInventoryId()
  return activeInventoryId
end

local function getActiveTriggerName()
  return activeTriggerName
end

-- Public API --------------------------------------------------------------------------------------

M.loadConfig = loadConfig
M.getSpotConfig = getSpotConfig
M.hasService = hasService
M.openMenu = openMenu
M.closeMenu = closeMenu
M.getUiData = getUiData
M.performRepair = performRepair
M.openMaintenance = openMaintenance
M.openTuning = openTuning
M.getActiveInventoryId = getActiveInventoryId
M.getActiveTriggerName = getActiveTriggerName
-- Hooks -------------------------------------------------------------------------------------------

M.onClientStartMission = function() loadConfig(true) end

local function resetRepairs(reason)
  local operation = repairOperation
  if operation and operation.cancel then operation.cancel(reason) end
  repairOperation = nil
  repairState = {status = 'idle'}
  activeInventoryId, activeTriggerName = nil, nil
end

function M.onUpdate(dtReal)
  local operation = repairOperation
  if not operation or not operation.cancel then return end
  operation.elapsed = operation.elapsed + dtReal
  if operation.elapsed >= repairConfig.get().replacementTimeoutS then
    operation.cancel('Roadside repair timed out')
  end
end

function M.onOverhaulActive() resetRepairs('Career changed during roadside repair') end
function M.onClientEndMission() resetRepairs('Level unloaded during roadside repair') end
function M.onExtensionUnloaded() resetRepairs('Roadside service unloaded during repair') end

return M
