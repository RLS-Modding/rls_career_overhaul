-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding
-- Fork of stock lua/ge/extensions/career/modules/computer.lua (BeamNG 0.40).

-- Garage computer menu: tether, per-garage and per-vehicle function lists, and the UI payload for the computer screen.
-- Read the menu-state helpers, rebuildMenuData (hooks plus discovered function entries), the UI projection, then open/close and exports.

local M = {}

local computerTetherRangeSphere = 4 --meter
-- Door buffer beyond the gameplay area; too small and the first interact closes the menu at once.
local computerTetherRangeBox = 2.5 --meter
local tether

local computerFunctions
local computerId
local computerFacilityName
local menuData = {}
local functionManifests -- per extension instance; a replacement extension starts fresh
local functionContext

-- Tuning tents are tuning-only: several computer functions don't gate on facility.functions, so opening one would show a garage screen.
local function isTuningOnlyFacility(computerFacility)
  return computerFacility ~= nil and computerFacility.openTuningDirectly == true
end

local function clearMenuState()
  computerId = nil
  functionContext = nil
  computerFunctions = nil
  computerFacilityName = nil
  menuData = {}
end

local function rebuildMenuData(resetActiveVehicleIndex)
  if not computerId then return false end

  local computerFacility = menuData and menuData.computerFacility
  if not computerFacility then
    computerFacility = overhaul_world_facilities.getFacility("computer", computerId)
  end
  if not computerFacility then return false end
  if isTuningOnlyFacility(computerFacility) then
    clearMenuState()
    return false
  end

  if resetActiveVehicleIndex == nil and menuData then
    resetActiveVehicleIndex = menuData.resetActiveVehicleIndex
  end

  computerFunctions = {general = {}, vehicleSpecific = {}}
  computerFacilityName = computerFacility.name

  menuData = {
    vehiclesInGarage = {},
    resetActiveVehicleIndex = resetActiveVehicleIndex,
    computerFacility = computerFacility,
    hasBoughtStarterVehicle = overhaul_career_career.hasBoughtStarterVehicle()
  }

  local inventoryIds = overhaul_career_garage_inventory.getInventoryIdsInClosestGarage()
  for _, inventoryId in ipairs(inventoryIds) do
    local vehicleData = {}
    vehicleData.inventoryId = inventoryId
    vehicleData.needsRepair = overhaul_career_repair_insurance.inventoryVehNeedsRepair(inventoryId) or nil
    local vehicleInfo = overhaul_career_garage_inventory.getVehicles()[inventoryId]
    vehicleData.vehicleName = vehicleInfo and vehicleInfo.niceName
    vehicleData.dirtyDate = vehicleInfo and vehicleInfo.dirtyDate
    table.insert(menuData.vehiclesInGarage, vehicleData)

    computerFunctions.vehicleSpecific[inventoryId] = {}
  end

  extensions.hook("onOverhaulComputerAddFunctions", menuData, computerFunctions)
  local catalog = require("overhaul/career/garage/computer/functionCatalog")
  if not functionManifests then
    functionManifests = catalog.scan()
    catalog.registerRoutes(functionManifests, overhaul_ui_routes)
  end
  catalog.addEntries(functionManifests, menuData, computerFunctions, function(route, params)
    functionContext = params
    extensions.ui_router.navigate(route, params)
  end)
  return true
end

local function buildComputerUIData()
  local data = {}
  if not computerFunctions then
    return data
  end

  local inventoryVehicles = overhaul_career_garage_inventory.getVehicles()

  local function translateReasons(functions)
    for _, functionData in pairs(functions) do
      if functionData.reason and functionData.reason.label then
        functionData.reason.label = core_locales.translateWithOrWithoutContext(functionData.reason.label)
      end
    end
  end

  -- Work on a copy so the shared M.reasons tables keep their keys.
  local computerFunctionsForUI = deepcopy(computerFunctions)
  local vehicleSpecificForUI = {}

  -- JS has no number keys.
  for inventoryId, computerFunction in pairs(computerFunctionsForUI.vehicleSpecific) do
    if inventoryVehicles and inventoryVehicles[inventoryId] then
      translateReasons(computerFunction)
      vehicleSpecificForUI[tostring(inventoryId)] = computerFunction
    end
  end
  computerFunctionsForUI.vehicleSpecific = vehicleSpecificForUI
  translateReasons(computerFunctionsForUI.general)

  local vehiclesForUI = {}
  for _, vehicleData in ipairs(menuData.vehiclesInGarage or {}) do
    local vehicleInventoryId = vehicleData.inventoryId
    if inventoryVehicles and inventoryVehicles[vehicleInventoryId] then
      local vehicleForUi = deepcopy(vehicleData)
      local thumb = overhaul_career_garage_inventory.getVehicleThumbnail(vehicleInventoryId)
      if thumb then
        vehicleForUi.thumbnail = thumb .. "?" .. (vehicleForUi.dirtyDate or "")
      end
      vehicleForUi.inventoryId = tostring(vehicleInventoryId)
      table.insert(vehiclesForUI, vehicleForUi)
    end
  end

  data.computerFunctions = computerFunctionsForUI
  data.vehicles = vehiclesForUI
  data.facilityName = computerFacilityName
  data.resetActiveVehicleIndex = menuData.resetActiveVehicleIndex
  data.computerId = computerId
  return data
end

local function openMenu(computerFacility, resetActiveVehicleIndex, activityElement, stillOwnsRoute)
  if stillOwnsRoute and not stillOwnsRoute() then return nil, {success = true, superseded = true} end
  if not computerFacility then return false end
  local bundle = computerFacility and require("overhaul/lib/business/bundles").forGarage(computerFacility.garageId)
  if bundle and not require("overhaul/lib/business/bundles").isOwned(bundle) then return false end
  if isTuningOnlyFacility(computerFacility) then
    clearMenuState()
    overhaul_career_career.closeAllMenus()
    return
  end
  computerId = computerFacility.id
  menuData.computerFacility = computerFacility
  rebuildMenuData(resetActiveVehicleIndex)

  -- Providers can navigate while rebuilding; a superseded recovery must leave that request alone.
  if stillOwnsRoute and not stillOwnsRoute() then return nil, {success = true, superseded = true} end

  local door = computerFacility.doors and computerFacility.doors[1]
  if tether then tether.remove = true end
  tether = nil
  if door then
    tether = overhaul_career_maintenance_tether.startDoorTether(door, computerTetherRangeBox, M.closeMenu)
  end
  if not tether then
    local computerPos = overhaul_world_facilities.getAverageDoorPositionForFacility(computerFacility)
    if computerPos then
      tether = overhaul_career_maintenance_tether.startSphereTether(computerPos, computerTetherRangeSphere, M.closeMenu)
    end
  end

  if stillOwnsRoute and not stillOwnsRoute() then return nil, {success = true, superseded = true} end
  local navigation = extensions.ui_router.navigate("overhaul.computer")
  extensions.hook("onOverhaulComputerMenuOpened")
  -- Callers that must know whether the router accepted the request read this reply. It is nil, not false, so
  -- the refusal convention above is unchanged.
  return nil, navigation
end

local function refreshMenu(resetActiveVehicleIndex)
  if not rebuildMenuData(resetActiveVehicleIndex) then return false end
  guihooks.trigger("computerUIData", buildComputerUIData())
  return true
end

local function computerButtonCallback(buttonId, inventoryId)
  if not computerFunctions then return end
  local functionData
  if inventoryId then
    functionData = computerFunctions.vehicleSpecific[inventoryId] and computerFunctions.vehicleSpecific[inventoryId][buttonId]
  else
    functionData = computerFunctions.general[buttonId]
  end
  if not functionData then return end

  functionData.callback(computerId)
end

local function getComputerUIData()
  -- Rebuild from live garage state; with no usable computer (a stray route back out of a tuning tent) leave instead.
  if not computerId or not rebuildMenuData() then
    overhaul_career_career.closeAllMenus()
    return {}
  end
  return buildComputerUIData()
end

local function getComputerId()
  return computerId
end

local function onMenuClosed()
  if tether then
    tether.remove = true
    tether = nil
  end
end

local function closeMenu()
  overhaul_career_career.closeAllMenus()
end

local function openComputerMenuById(computerIdArg)
  local computer = overhaul_world_facilities.getFacility("computer", computerIdArg)
  overhaul_career_garage_computer.openMenu(computer)
end

M.reasons = {
  hasBoughtStarterVehicle = {
    type = "text",
    label = "ui.career.computer.reason.buyStarterVehicleFirst"
  },
  needsRepair = {
    type = "needsRepair",
    label = "ui.career.computer.reason.vehicleNeedsRepairFirst"
  }
}

M.openMenu = openMenu
M.refreshMenu = refreshMenu
M.openComputerMenuById = openComputerMenuById
M.onMenuClosed = onMenuClosed
M.closeMenu = closeMenu
M.getComputerUIData = getComputerUIData
M.computerButtonCallback = computerButtonCallback
M.getComputerId = getComputerId
M.getFunctionContext = function() return deepcopy(functionContext or {}) end

return M
