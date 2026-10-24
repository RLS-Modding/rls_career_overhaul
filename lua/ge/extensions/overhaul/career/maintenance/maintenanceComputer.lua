-- Maintenance computer: the menu for checks, services, tyres and the cart, for personal and business vehicles.
-- The work lives in maintenanceComputer/; this file owns the shared runtime state, the menu session and the public API.
local M = {}

local config = require('overhaul/lib/maintenance/computerConfig')
local partCategories = require('common/overhaul/maintenancePartCategories')
local capabilities = require('overhaul/lib/platform/capabilities')
local jbeamIO = require("jbeam/io")

-- Config ------------------------------------------------------------------------------------------

local DYNO_MAINTENANCE_CATEGORIES = {
  engine = true,
  radiator = true,
  transmission = true,
}

local floor = math.floor
local max = math.max
local metersToMiles = 1 / 1609.344

-- State -------------------------------------------------------------------------------------------

-- Session and runtime state shared by every part of this load.
local computerState = {}
computerState.sessionMode = nil
computerState.jbeamIO = jbeamIO

local returnRoute = nil
local ioCtxCache = {}

-- Shared helpers ----------------------------------------------------------------------------------

local function roundMoney(amount)
  return floor((tonumber(amount) or 0) * 100 + 0.5) / 100
end

local function roundWholeMoney(amount)
  return floor((tonumber(amount) or 0) + 0.5)
end

local function roundPercent(value)
  return floor((max(0, math.min(1, tonumber(value) or 0)) * 100) + 0.5)
end

local function isMaintenanceEnabled()
  return overhaul_career_maintenance_maintenanceMode.isEnabled() == true
end

local function getVehicleData(inventoryId)
  return overhaul_career_garage_inventory.getVehicle(tonumber(inventoryId))
end

local function getBusinessVehicleData(businessId, vehicleId)
  return capabilities.get('businessVehicles').getVehicleById(businessId, vehicleId) or nil
end

local function markVehicleDirty(inventoryId)
  overhaul_career_garage_inventory.setVehicleDirty(tonumber(inventoryId))
end

local function persistVehicleMutation(inventoryId)
  markVehicleDirty(inventoryId)
  overhaul_career_saveSystem.saveCurrent()
end

local function ensureMaintenanceComputerState(vehicleData)
  local changed = false
  if type(vehicleData.maintenanceComputerState) ~= "table" then
    vehicleData.maintenanceComputerState = {}
    changed = true
  end

  local state = vehicleData.maintenanceComputerState
  if type(state.revealed) ~= "table" then
    state.revealed = {}
    changed = true
  end
  if type(state.jobs) ~= "table" then
    state.jobs = {}
    changed = true
  end

  for _, categoryName in ipairs(config.categoryOrder) do
    if type(state.revealed[categoryName]) ~= "table" then
      state.revealed[categoryName] = {}
      changed = true
    end
  end

  return state, changed
end

-- Rewrites the snapshot only when its content changed, so an identical snapshot keeps its table identity.
local function normalizeVehicleMaintenanceState(vehicleData)
  local normalized = config.normalizeSnapshot(vehicleData.maintenanceState, vehicleData)
  local changed = false

  local currentSignature = serialize(vehicleData.maintenanceState)
  local nextSignature = serialize(normalized)
  if currentSignature ~= nextSignature then
    vehicleData.maintenanceState = normalized
    changed = true
  elseif vehicleData.maintenanceState ~= normalized then
    vehicleData.maintenanceState = normalized
  end

  return vehicleData.maintenanceState, changed
end

-- Compiled jbeam contexts per model, so each model is only loaded once; the cache is small and cleared when full.
local function getVehicleIoCtx(vehicleData)
  if type(vehicleData) ~= "table" then
    return nil
  end
  if vehicleData.ioCtx then
    return vehicleData.ioCtx
  end

  local model = vehicleData.model or vehicleData.vehicleModel
  if type(model) ~= "string" or model == "" then
    return nil
  end

  local cached = ioCtxCache[model]
  if cached then
    return cached
  end

  local ok, ioCtx = pcall(computerState.jbeamIO.startLoading, {
    "/vehicles/" .. model .. "/",
    "/vehicles/common/",
  })
  if ok and ioCtx then
    if tableSize(ioCtxCache) >= 8 then table.clear(ioCtxCache) end
    ioCtxCache[model] = ioCtx
    return ioCtx
  end
  return nil
end

-- Parts -------------------------------------------------------------------------------------------

local parts = {}

local partInputs = {
  quotes = {
    state = computerState,
    config = config,
    deepCopy = deepcopy,
    floor = floor,
    getVehicleIoCtx = getVehicleIoCtx,
    max = max,
    partCategories = partCategories,
    partDataHasDeviceType = partCategories.partDataHasDeviceType,
    roundMoney = roundMoney,
    roundWholeMoney = roundWholeMoney,
  },
  services = {
    parts = parts,
    state = computerState,
    DYNO_MAINTENANCE_CATEGORIES = DYNO_MAINTENANCE_CATEGORIES,
    config = config,
    deepCopy = deepcopy,
    ensureMaintenanceComputerState = ensureMaintenanceComputerState,
    getBusinessVehicleData = getBusinessVehicleData,
    getVehicleData = getVehicleData,
    isMaintenanceEnabled = isMaintenanceEnabled,
    markVehicleDirty = markVehicleDirty,
    normalizeVehicleMaintenanceState = normalizeVehicleMaintenanceState,
    persistVehicleMutation = persistVehicleMutation,
    roundPercent = roundPercent,
  },
  ui = {
    parts = parts,
    state = computerState,
    config = config,
    deepCopy = deepcopy,
    isMaintenanceEnabled = isMaintenanceEnabled,
    max = max,
    metersToMiles = metersToMiles,
    partCategories = partCategories,
    roundMoney = roundMoney,
    roundPercent = roundPercent,
  },
  cart = {
    parts = parts,
    state = computerState,
    DYNO_MAINTENANCE_CATEGORIES = DYNO_MAINTENANCE_CATEGORIES,
    config = config,
    deepCopy = deepcopy,
    markVehicleDirty = markVehicleDirty,
    persistVehicleMutation = persistVehicleMutation,
  },
}

parts.quotes = require('overhaul/career/maintenance/maintenanceComputer/quotes').new(partInputs.quotes)
parts.services = require('overhaul/career/maintenance/maintenanceComputer/services').new(partInputs.services)
parts.ui = require('overhaul/career/maintenance/maintenanceComputer/ui').new(partInputs.ui)
parts.cart = require('overhaul/career/maintenance/maintenanceComputer/cart').new(partInputs.cart)

-- Menu session ------------------------------------------------------------------------------------

local function openMenuFromComputer(inventoryId, computerId, _returnRoute, options)
  if not isMaintenanceEnabled() then
    return false
  end

  computerState.activeInventoryId = tonumber(inventoryId)
  computerState.originComputerId = computerId
  returnRoute = _returnRoute
  computerState.sessionMode = type(options) == "table" and options.mode or nil
  if not computerState.activeInventoryId then
    computerState.sessionMode = nil
    return false
  end

  extensions.ui_router.navigate('maintenance')
  return true
end

-- Hands the menu back to whoever opened it: the dyno session, the previous route, or the computer.
local function closeMenu()
  local route = returnRoute
  returnRoute = nil
  local closingMode = computerState.sessionMode
  computerState.sessionMode = nil
  local computerId = computerState.originComputerId
  computerState.originComputerId = nil

  if route == "dynoSession" or closingMode == "dyno" then
    overhaul_career_career.closeAllMenus()
    capabilities.get("businessSession").resumeFromService()
    return
  end

  if route then
    extensions.ui_router.navigate(route)
    return
  end

  local opened = false
  if computerId then
    local computer = overhaul_world_facilities.getFacility("computer", computerId, true)
    if computer then
      overhaul_career_garage_computer.openMenu(computer)
      opened = true
    end
  end
  if not opened then
    extensions.ui_router.navigate("overhaul.computer")
  end
end

parts.closeMenu = closeMenu

-- Computer menu contributions --------------------------------------------------------------------

local function onOverhaulComputerAddFunctions(menuData, computerFunctions)
  if not isMaintenanceEnabled() then
    return
  end
  if not menuData.computerFacility.functions["vehicleInventory"] then
    return
  end

  for _, vehicleData in ipairs(menuData.vehiclesInGarage or {}) do
    local inventoryId = vehicleData.inventoryId
    computerFunctions.vehicleSpecific[inventoryId].maintenance = {
      id = "maintenance",
      label = "Maintenance",
      callback = function(computerId)
        openMenuFromComputer(inventoryId, computerId or menuData.computerFacility.id)
      end,
      order = 6,
    }
  end
end

-- Lifecycle ---------------------------------------------------------------------------------------

-- Moves saved check and service jobs from the old timed system to the current state, personal and business vehicles.
local function migrateAllLegacyJobs()
  for inventoryId, vehicleData in pairs(overhaul_career_garage_inventory.getVehicles() or {}) do
    local jobs = vehicleData and vehicleData.maintenanceComputerState and vehicleData.maintenanceComputerState.jobs
    if type(jobs) == "table" and next(jobs) then
      parts.services.prepareVehicleState(inventoryId)
    end
  end
  local purchased = overhaul_career_business_manager.getAllPurchasedBusinesses() or {}
  for _, businessesById in pairs(purchased) do
    for businessId, owned in pairs(businessesById or {}) do
      if owned == true or type(owned) == "table" then
        for _, vehicleData in ipairs(capabilities.get('businessVehicles').getBusinessVehicles(businessId) or {}) do
          local jobs = vehicleData and vehicleData.maintenanceComputerState and vehicleData.maintenanceComputerState.jobs
          if type(jobs) == "table" and next(jobs) then
            parts.services.prepareBusinessVehicleState(businessId, vehicleData.vehicleId)
          end
        end
      end
    end
  end
end

-- Public API --------------------------------------------------------------------------------------

M.openMenuFromComputer = openMenuFromComputer
M.closeMenu = closeMenu
M.getMaintenanceUiData = parts.ui.getMaintenanceUiDataSafe
M.getMaintenanceUiDataForInventory = parts.ui.getMaintenanceUiDataForInventorySafe
M.getMaintenanceUiDataForBusinessVehicle = parts.ui.getMaintenanceUiDataForBusinessVehicleSafe
M.categoryHardwareIsInstalled = parts.quotes.categoryHardwareIsInstalled
M.startCheck = parts.services.startCheck
M.startCheckForBusinessVehicle = parts.services.startCheckForBusinessVehicle
M.startService = parts.services.startService
M.startServiceForBusinessVehicle = parts.services.startServiceForBusinessVehicle
M.inspectTires = parts.cart.inspectTires
M.inspectBusinessVehicleTires = parts.cart.inspectBusinessVehicleTires
M.checkoutTires = parts.cart.checkoutTires
M.checkoutTiresForBusinessVehicle = parts.cart.checkoutTiresForBusinessVehicle
M.checkoutCart = parts.cart.checkoutCart
M.activity = require('overhaul/career/maintenance/maintenanceComputer/activity')(M)

-- Hooks -------------------------------------------------------------------------------------------

M.onOverhaulComputerAddFunctions = onOverhaulComputerAddFunctions
M.onOverhaulActive = migrateAllLegacyJobs

return M
