-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Fork of stock lua/ge/extensions/career/modules/inventory.lua (BeamNG 0.40).

-- Inventory owns records and the public garage API; its private parts share one extension load.
-- Read in order: config, state, garage helpers, registry view, part construction, frame update, then the public API and game hooks.

local M = {}
M.dependencies = {"gameplay_tutorial_setup", "gameplay_sites_sitesManager"}

local capabilities = require("overhaul/lib/platform/capabilities")
local saleEvents = require("overhaul/career/garage/inventory/saleEvents")
local dateUtils = require('utils/dateUtils')
local maintenanceComputerConfig = require('overhaul/lib/maintenance/computerConfig')
local condition = require('overhaul/lib/vehicles/condition')
local levelData = require('overhaul/lib/world/levelData')

-- Config ------------------------------------------------------------------------------------------

local BASE_TOW_SERVICE_COST = 250
local ACCESS_TIMER_UPDATE_INTERVAL = 0.25
local NEW_CAREER_SAVE_FRAME_COUNT = 10
local minimumVersion = 42
local saveAnyVehiclePosDEBUG = true
local xVec, yVec, zVec = vec3(1,0,0), vec3(0,1,0), vec3(0,0,1)

-- State -------------------------------------------------------------------------------------------

-- Every part reads and writes these tables.
local garageState = {}
local vehicles = {}
local dirtiedVehicles = {}
local vehIdToInventoryId = {}
local inventoryIdToVehId = {}
local pendingDamageRestore = {}
local pendingMaintenanceSeedInventoryIds = {}
-- Temporary builds never put runtime policy on the saved record or a reused inventory id.
local transientBuilds = setmetatable({}, {__mode = "k"})
function M.setTransientBuild(inventoryId, active)
  local record = vehicles[inventoryId]
  if record then transientBuilds[record] = active == true or nil end
end
function M.isTransientBuild(inventoryId)
  local record = vehicles[inventoryId]
  return record ~= nil and transientBuilds[record] == true
end
local travel = {
  pending = nil,
  restoreAttempts = 0,
}

garageState.accessTimerAccumulator = 0
garageState.inventorySetupDone = false
garageState.lastFailedSpawnPos = nil
garageState.hardcoreStarterGranted = false

-- Garage helpers ----------------------------------------------------------------------------------

-- The condition library owns the maintenance-failure mask.
local sanitizeMaintenancePartConditionsForVehicle = condition.sanitizeMaintenancePartConditionsForVehicle

local function isExperimentalMaintenanceEnabled()
  return overhaul_career_maintenance_maintenanceMode.isEnabled() == true
end

local function sanitizeLoadedVehiclesForDisabledMaintenance()
  if isExperimentalMaintenanceEnabled() then return end
  for inventoryId, vehicleData in pairs(vehicles) do
    if type(vehicleData) == "table" then
      if type(vehicleData.partConditions) == "table" then
        vehicleData.partConditions = sanitizeMaintenancePartConditionsForVehicle(vehicleData, vehicleData.partConditions)
      end
      if vehicleData.maintenanceState ~= nil then
        vehicleData.maintenanceState = nil
        dirtiedVehicles[inventoryId] = true
      end
    end
  end
end

local function onOverhaulExperimentalMaintenanceModeChanged(enabled)
  if enabled == true then return end
  sanitizeLoadedVehiclesForDisabledMaintenance()
end

local function searchOrigin(pos)
  if pos then return pos end
  local playerVeh = getPlayerVehicle(0)
  return playerVeh and playerVeh:getPosition() or nil
end

local function getClosestGarage(pos, levelName)
  levelName = levelName or getCurrentLevelIdentifier()
  local facilities = overhaul_world_facilities.getFacilities(levelName)
  if not facilities or not facilities.garages then return nil end

  local playerPos = searchOrigin(pos)
  if not playerPos then return nil end

  local closestGarage
  local closestDistanceMeters = math.huge
  for _, garage in pairs(facilities.garages) do
    local garagePos = overhaul_world_facilities.getAverageDoorPositionForFacility(garage)
    if garagePos then
      local distanceMeters = garagePos:distance(playerPos)
      if distanceMeters < closestDistanceMeters then
        closestGarage = garage
        closestDistanceMeters = distanceMeters
      end
    end
  end
  return closestGarage
end

local function getInventoryMenuGarage(pos, levelName)
  local garageManager = overhaul_career_garage_garageManager
  local computerId = garageState.originComputerId or overhaul_career_garage_computer.getComputerId()
  local garageId = computerId and garageManager.computerIdToGarageId(computerId)
  if garageId then
    local garage = overhaul_world_facilities.getFacility("garage", garageId)
    if garage then return garage end
  end

  return getClosestGarage(pos, levelName)
end

local function getClosestOwnedGarageWithSpace(pos, levelName, inventoryId)
  local garageManager = overhaul_career_garage_garageManager

  -- The garage linked to the current computer wins.
  local currentComputerId = overhaul_career_garage_computer.getComputerId()
  if currentComputerId then
    local currentGarageId = garageManager.computerIdToGarageId(currentComputerId)
    if currentGarageId and garageManager.isPurchasedGarage(currentGarageId)
      and not garageManager.isGarageForSale(currentGarageId) then
      local spaceInfo = garageManager.isGarageSpace(currentGarageId, inventoryId)
      if spaceInfo and spaceInfo[1] then
        return overhaul_world_facilities.getFacility("garage", currentGarageId)
      end
    end
  end

  levelName = levelName or getCurrentLevelIdentifier()
  local facilities = overhaul_world_facilities.getFacilities(levelName)
  if not facilities or not facilities.garages then return nil end

  local playerPos = searchOrigin(pos)
  if not playerPos then return nil end

  local closestGarage
  local closestDistanceMeters = math.huge
  for _, garage in pairs(facilities.garages) do
    if garageManager.isPurchasedGarage(garage.id)
      and not garageManager.isGarageForSale(garage.id) then
      local spaceInfo = garageManager.isGarageSpace(garage.id, inventoryId)
      if spaceInfo and spaceInfo[1] then
        local garagePos = overhaul_world_facilities.getAverageDoorPositionForFacility(garage)
        if garagePos then
          local distanceMeters = garagePos:distance(playerPos)
          if distanceMeters < closestDistanceMeters then
            closestGarage = garage
            closestDistanceMeters = distanceMeters
          end
        end
      end
    end
  end

  return closestGarage
end

local function getVehicleRetrievalQuote(inventoryId, routePrice)
  local coveredByInsurance = overhaul_career_repair_insurance.isRoadSideAssistanceFree(inventoryId) or false
  if coveredByInsurance then
    return {cost = 0, coveredByInsurance = true}
  end

  local globalIndex = overhaul_career_economy_globalEconomy.getGlobalIndex() or 1
  local baseCost = math.floor(BASE_TOW_SERVICE_COST * globalIndex * 100 + 0.5) / 100
  return {
    cost = baseCost + math.max(0, tonumber(routePrice) or 0),
    coveredByInsurance = false
  }
end

local function useVehicleRetrievalService(inventoryId, routePrice, label)
  local quote = getVehicleRetrievalQuote(inventoryId, routePrice)
  if quote.coveredByInsurance then
    overhaul_career_repair_insurance.useRoadsideAssistance(inventoryId)
    ui_message("Roadside assistance tow used.", 5, "Vehicle retrieval", "info")
    return quote
  end

  overhaul_career_economy_payment.pay({money = {amount = quote.cost, canBeNegative = true}}, require("overhaul/lib/finance/metadata").tag({label = label or "Retrieved vehicle with towing service", tags = {"delivery"}}, "service", {vehicleId = inventoryId}))
  return quote
end

local function getLocalGarageRetrievalRoutePrice()
  local garage = getInventoryMenuGarage()
  if not garage then return 0 end
  return overhaul_career_garage_quickTravel.getPriceForQuickTravelToGarage(garage) or 0
end

local function getResolvedStartingGarageId(levelName)
  return overhaul_career_garage_garageManager.getPrimaryStartingGarageId(levelName)
end

local function teleportPlayerToStartingGarage(levelName)
  local spawnGarageId = getResolvedStartingGarageId(levelName)
  if spawnGarageId and overhaul_world_facilities.getFacilityIfExists("garage", spawnGarageId) then
    local ok, placed = pcall(overhaul_world_facilities.teleportToGarage, spawnGarageId, getPlayerVehicle(0))
    if ok and placed ~= false then return spawnGarageId end
  end

  local initial = levelData.startSpawn('initialSpawn', levelName) or levelData.recoverySpawn(levelName)
  if initial then
    gameplay_walk.setWalkingMode(true, initial.pos, initial.rot, true)
    local player = getPlayerVehicle(0)
    if not player then return nil end
    if spawn.safeTeleport(player, initial.pos, initial.rot) == false then return nil end
    return 'initialSpawn'
  end

  local facilities = overhaul_world_facilities.getFacilities(levelName or getCurrentLevelIdentifier())
  if facilities then
    for _, facilityListName in ipairs({"dealerships", "privateSellers", "computers"}) do
      local facilityList = facilities[facilityListName]
      if facilityList and facilityList[1] then
        local facility = facilityList[1]
        local pos = overhaul_world_facilities.getAverageDoorPositionForFacility(facility)
        if pos then
          gameplay_walk.setWalkingMode(true)
          local player = getPlayerVehicle(0)
          if not player or spawn.safeTeleport(player, pos) == false then return nil end
          return facility.id
        end
      end
    end
  end

  log('W', 'career.inventory', 'Starting placement unavailable: no usable local spawn or garage')
  return nil
end

-- Registry view -----------------------------------------------------------------------------------

-- Read-only handles stay tied to one record, binding and extension load; a new generation invalidates
-- old handles even when the engine reuses a vehicle id.
local generations = {}
local lastGeneration = 0
local baseGeneration = 0

local function bumpGeneration(inventoryId)
  if inventoryId == nil then return end
  lastGeneration = lastGeneration + 1
  generations[inventoryId] = lastGeneration
end

local function bumpAllGenerations()
  for inventoryId in pairs(generations) do generations[inventoryId] = nil end
  lastGeneration = lastGeneration + 1
  baseGeneration = lastGeneration
end

local function generationOf(inventoryId)
  return generations[inventoryId] or baseGeneration
end

-- read-only proxies, one per live table, built on demand
local proxies = setmetatable({}, {__mode = "kv"})
local proxyTargets = setmetatable({}, {__mode = "k"})
local function refuse(_, key)
  error("the inventory registry view is read-only (write to " .. tostring(key) .. ")", 2)
end
local function readOnly(value)
  if type(value) ~= "table" then return value end
  local proxy = proxies[value]
  if proxy then return proxy end
  proxy = setmetatable({}, {
    __index = function(_, key) return readOnly(value[key]) end,
    __newindex = refuse,
    __metatable = false,
  })
  proxies[value] = proxy
  proxyTargets[proxy] = value
  return proxy
end

local registryView = {}

-- The record for an inventory id, read-only, or nil.
function registryView.get(inventoryId)
  local record = vehicles[inventoryId]
  if record == nil then return nil end
  return readOnly(record)
end

-- Inventory ids with a record, sorted (numbers before strings).
function registryView.ids()
  local ids = {}
  for inventoryId in pairs(vehicles) do ids[#ids + 1] = inventoryId end
  table.sort(ids, function(a, b)
    if type(a) == type(b) then return a < b end
    return type(a) == "number"
  end)
  return ids
end

function registryView.vehId(inventoryId)
  if inventoryId == nil then return nil end
  return inventoryIdToVehId[inventoryId]
end

function registryView.inventoryId(vehId)
  if vehId == nil then return nil end
  return vehIdToInventoryId[vehId]
end

-- pairs() and # for a read-only table from this view (a Lua 5.1 proxy has neither).
function registryView.pairs(proxy)
  local target = proxyTargets[proxy]
  if not target then error("not a registry view table", 2) end
  local key
  return function()
    local value
    key, value = next(target, key)
    if key == nil then return nil end
    return key, readOnly(value)
  end
end

function registryView.len(proxy)
  local target = proxyTargets[proxy]
  if not target then error("not a registry view table", 2) end
  return #target
end

-- A handle for a record and its current binding (vehId nil while stored), or nil without a record.
function registryView.handle(inventoryId)
  if inventoryId == nil or vehicles[inventoryId] == nil then return nil end
  return {inventoryId = inventoryId, vehId = inventoryIdToVehId[inventoryId],
    generation = generationOf(inventoryId), registry = registryView}
end

-- A handle for a bound vehicle id, or nil when the id is not an inventory vehicle.
function registryView.handleForVehId(vehId)
  if vehId == nil then return nil end
  local inventoryId = vehIdToInventoryId[vehId]
  if inventoryId == nil then return nil end
  return registryView.handle(inventoryId)
end

-- True while the handle's record, binding and generation are unchanged in this extension load.
function registryView.isCurrent(handle)
  if type(handle) ~= "table" or handle.registry ~= registryView then return false end
  local inventoryId = handle.inventoryId
  if inventoryId == nil or vehicles[inventoryId] == nil then return false end
  if generationOf(inventoryId) ~= handle.generation then return false end
  if inventoryIdToVehId[inventoryId] ~= handle.vehId then return false end
  if handle.vehId ~= nil and vehIdToInventoryId[handle.vehId] ~= inventoryId then return false end
  return true
end

-- The record a current handle names, read-only, or nil when the handle is stale.
function registryView.resolve(handle)
  if not registryView.isCurrent(handle) then return nil end
  return readOnly(vehicles[handle.inventoryId])
end

-- Parts -------------------------------------------------------------------------------------------

-- Each part is built once per load, in dependency order; named inputs are bound after all exist.
local parts = {}
parts.persistence = require('overhaul/career/garage/inventory/persistence').new({
  state = garageState,
  M = M,
  dirtiedVehicles = dirtiedVehicles,
  inventoryIdToVehId = inventoryIdToVehId,
  isExperimentalMaintenanceEnabled = isExperimentalMaintenanceEnabled,
  sanitizeMaintenancePartConditionsForVehicle = sanitizeMaintenancePartConditionsForVehicle,
  travel = travel,
  vehIdToInventoryId = vehIdToInventoryId,
  vehicles = vehicles,
})
parts.bindings = require('overhaul/career/garage/inventory/bindings').new({
  state = garageState,
  M = M,
  inventoryIdToVehId = inventoryIdToVehId,
  maintenanceComputerConfig = maintenanceComputerConfig,
  pendingMaintenanceSeedInventoryIds = pendingMaintenanceSeedInventoryIds,
  sanitizeMaintenancePartConditionsForVehicle = sanitizeMaintenancePartConditionsForVehicle,
  vehIdToInventoryId = vehIdToInventoryId,
  vehicles = vehicles,
})
parts.spawn = require('overhaul/career/garage/inventory/spawn').new({
  state = garageState,
  M = M,
  dirtiedVehicles = dirtiedVehicles,
  getInventoryMenuGarage = getInventoryMenuGarage,
  inventoryIdToVehId = inventoryIdToVehId,
  pendingDamageRestore = pendingDamageRestore,
  teleportPlayerToStartingGarage = teleportPlayerToStartingGarage,
  vehicles = vehicles,
})
parts.travel = require('overhaul/career/garage/inventory/travel').new({
  state = garageState,
  M = M,
  inventoryIdToVehId = inventoryIdToVehId,
  travel = travel,
  vehicles = vehicles,
})
parts.setup = require('overhaul/career/garage/inventory/setup').new({
  state = garageState,
  M = M,
  dateUtils = dateUtils,
  inventoryIdToVehId = inventoryIdToVehId,
  minimumVersion = minimumVersion,
  sanitizeMaintenancePartConditionsForVehicle = sanitizeMaintenancePartConditionsForVehicle,
  saveAnyVehiclePosDEBUG = saveAnyVehiclePosDEBUG,
  teleportPlayerToStartingGarage = teleportPlayerToStartingGarage,
  travel = travel,
  vehIdToInventoryId = vehIdToInventoryId,
  vehicles = vehicles,
})
parts.ui = require('overhaul/career/garage/inventory/ui').new({
  state = garageState,
  M = M,
  getClosestGarage = getClosestGarage,
  getInventoryMenuGarage = getInventoryMenuGarage,
  getLocalGarageRetrievalRoutePrice = getLocalGarageRetrievalRoutePrice,
  getVehicleRetrievalQuote = getVehicleRetrievalQuote,
  inventoryIdToVehId = inventoryIdToVehId,
  useVehicleRetrievalService = useVehicleRetrievalService,
  vehIdToInventoryId = vehIdToInventoryId,
  vehicles = vehicles,
  xVec = xVec,
  yVec = yVec,
  zVec = zVec,
})
parts.operations = require('overhaul/career/garage/inventory/operations').new({
  state = garageState,
  M = M,
  dirtiedVehicles = dirtiedVehicles,
  getInventoryMenuGarage = getInventoryMenuGarage,
  getLocalGarageRetrievalRoutePrice = getLocalGarageRetrievalRoutePrice,
  inventoryIdToVehId = inventoryIdToVehId,
  teleportPlayerToStartingGarage = teleportPlayerToStartingGarage,
  useVehicleRetrievalService = useVehicleRetrievalService,
  vehicles = vehicles,
})
-- Frame update ------------------------------------------------------------------------------------

-- Real-time access delays and frame-counted startup saves retain their separate clocks.

local function getCurrentVehicle()
  -- Direct switches can bypass entry, so reconcile the seated car before answering.
  local playerVehId = be and be:getPlayerVehicleID(0) or nil
  local seatedInventoryId = playerVehId and vehIdToInventoryId[playerVehId] or nil
  if seatedInventoryId and seatedInventoryId ~= garageState.currentVehicle then
    garageState.currentVehicle = seatedInventoryId
    garageState.lastVehicle = seatedInventoryId
    dirtiedVehicles[seatedInventoryId] = true
  end
  return garageState.currentVehicle
end

-- Dependencies can activate later, so retry a prepared migration until its first successful apply.
local function retryPendingMigration()
  if garageState.pendingMigrationRetry and parts.setup.applyPendingMigration() then
    garageState.pendingMigrationRetry = false
  end
end

-- Waits for condition initialization before saving the new career.
local function tickNewCareerSave()
  if not garageState.saveCareer then return end
  if garageState.saveCareer >= NEW_CAREER_SAVE_FRAME_COUNT then
    overhaul_career_saveSystem.saveCurrent() -- this is the save just after starting a new career
    garageState.saveCareer = nil
  else
    garageState.saveCareer = garageState.saveCareer + 1
  end
end

local function showOneShotToast(flagName, label, translationKey)
  if not garageState[flagName] then return end
  guihooks.trigger("toastrMsg", {
    type = "warning",
    label = label,
    title = _tr("ui.career.inventory.toast." .. translationKey .. ".title"),
    msg = _tr("ui.career.inventory.toast." .. translationKey .. ".msg"),
  })
  garageState[flagName] = nil
end

-- Delay owners without their own UI get a toast here; others (studio rentals) answer the
-- onOverhaulVehicleAccessRestored hook with their own view. The hook runs before the delay
-- fields clear, so listeners can still read the record that explains the delay.
local function announceVehicleAccessible(inventoryId, vehInfo)
  local reason = vehInfo.delayReason
  if reason == "bought" then
    ui_message(core_locales.contextTranslate("ui.career.inventory.message.vehicleDeliveredToStorage", {vehicleName = vehInfo.niceName}), nil, "vehicleInventory")
  elseif reason == "repair" then
    ui_message(core_locales.contextTranslate("ui.career.inventory.message.vehicleRepairedReturnedToStorage", {vehicleName = vehInfo.niceName}), nil, "vehicleInventory")
  elseif reason == "certification" then
    ui_message(string.format("Your %s has been certified and returned to your vehicle storage.", vehInfo.niceName), nil, "vehicleInventory")
  end
  extensions.hook("onOverhaulVehicleAccessRestored", inventoryId, reason)
end

local function tickAccessTimers(elapsed)
  for inventoryId, vehInfo in pairs(vehicles) do
    if vehInfo.timeToAccess and vehInfo.delayReason ~= "engineRetailInstall"
        and vehInfo.delayReason ~= "engineRetailPickup" then
      vehInfo.timeToAccess = vehInfo.timeToAccess - elapsed
      parts.persistence.setVehicleDirty(inventoryId)
      if vehInfo.timeToAccess < 0 then
        announceVehicleAccessible(inventoryId, vehInfo)
        vehInfo.timeToAccess = nil
        vehInfo.delayReason = nil
        vehInfo.repairTimeTotal = nil
        if parts.ui.isMenuOpen() then parts.ui.sendVehicleUpdatesToUi() end
      end
    end
  end
end

local function onUpdate(dtReal, _dtSim, _dtRaw)
  parts.persistence.pumpThumbnailCaptures()
  retryPendingMigration()
  tickNewCareerSave()
  showOneShotToast("vehiclesMovedToStorage", "vehStored", "vehicleStored")
  showOneShotToast("loanedVehicleReturned", "loanReturned", "loanReturned")

  garageState.accessTimerAccumulator = garageState.accessTimerAccumulator + math.max(tonumber(dtReal) or 0, 0)
  if garageState.accessTimerAccumulator < ACCESS_TIMER_UPDATE_INTERVAL then return end
  local accessTimerElapsed = garageState.accessTimerAccumulator
  garageState.accessTimerAccumulator = 0
  tickAccessTimers(accessTimerElapsed)
end

-- Part wiring -------------------------------------------------------------------------------------

parts.bindings.bindInputs({
  bumpGeneration = bumpGeneration,
  spawnReadiness = parts.spawn.spawnReadiness,
  isPersonalInventoryId = parts.persistence.isPersonalInventoryId,
  isVehicleListedForAuction = parts.persistence.isVehicleListedForAuction,
  partConditionBatches = parts.persistence.partConditionBatches,
})
parts.spawn.bindInputs({
  assignInventoryIdToVehId = parts.bindings.assignInventoryIdToVehId,
  updatePartConditionsOfCurrentVehicle = parts.persistence.updatePartConditionsOfCurrentVehicle,
})
parts.travel.bindInputs({
  removeVehicleObject = parts.bindings.removeVehicleObject,
  spawnVehicle = parts.spawn.spawnVehicle,
})
parts.setup.bindInputs({
  bumpAllGenerations = bumpAllGenerations,
  ensureGameCameraWithRetry = parts.spawn.ensureGameCameraWithRetry,
  enterVehicle = parts.spawn.enterVehicle,
  isPersonalInventoryId = parts.persistence.isPersonalInventoryId,
  spawnVehicle = parts.spawn.spawnVehicle,
  teleportWalkFallback = parts.spawn.teleportWalkFallback,
})
parts.ui.bindInputs({
  enterVehicle = parts.spawn.enterVehicle,
  getNumberOfFreeSlots = parts.bindings.getNumberOfFreeSlots,
  hasFreeSlot = parts.bindings.hasFreeSlot,
  isPersonalInventoryId = parts.persistence.isPersonalInventoryId,
  setVehicleDirty = parts.persistence.setVehicleDirty,
  spawnVehicle = parts.spawn.spawnVehicle,
  updatePartConditionsOfSpawnedVehicles = parts.persistence.updatePartConditionsOfSpawnedVehicles,
})
parts.operations.bindInputs({
  ensureGameCameraWithRetry = parts.spawn.ensureGameCameraWithRetry,
  enterVehicle = parts.spawn.enterVehicle,
  getCurrentVehicle = getCurrentVehicle,
  getInitialRepairTime = parts.ui.getInitialRepairTime,
  getInventoryIdFromVehicleId = parts.ui.getInventoryIdFromVehicleId,
  getVehicleIdFromInventoryId = parts.ui.getVehicleIdFromInventoryId,
  getVehicleThumbnail = parts.ui.getVehicleThumbnail,
  getVehiclesInGarage = parts.ui.getVehiclesInGarage,
  hasFreeSlot = parts.bindings.hasFreeSlot,
  isVehicleListedForAuction = parts.persistence.isVehicleListedForAuction,
  openMenuFromComputer = parts.ui.openMenuFromComputer,
  removeVehicle = parts.bindings.removeVehicle,
  removeVehicleObject = parts.bindings.removeVehicleObject,
  sendDataToUi = parts.ui.sendVehicleUpdatesToUi,
  setVehicleDirty = parts.persistence.setVehicleDirty,
  spawnVehicle = parts.spawn.spawnVehicle,
  teleportWalkFallback = parts.spawn.teleportWalkFallback,
  updatePartConditions = parts.bindings.updatePartConditions,
})

-- Vehicle statistics ------------------------------------------------------------------------------

local function bumpRecordField(inventoryId, field, amount)
  local record = vehicles[inventoryId]
  if not record then return end
  record[field] = (record[field] or 0) + amount
end

local function readRecordField(inventoryId, field)
  local record = vehicles[inventoryId]
  if not record then return 0 end
  return record[field] or 0
end

function M.setVehicleRole(inventoryId, role)
  if not vehicles[inventoryId] then return end
  vehicles[inventoryId].role = role
end

function M.getVehicleRole(inventoryId)
  return vehicles[inventoryId] and vehicles[inventoryId].role or nil
end

function M.addAccident(inventoryId) bumpRecordField(inventoryId, "accidents", 1) end
function M.getAccidents(inventoryId) return readRecordField(inventoryId, "accidents") end
function M.addArrest(inventoryId) bumpRecordField(inventoryId, "arrests", 1) end
function M.getArrests(inventoryId) return readRecordField(inventoryId, "arrests") end
function M.addTicket(inventoryId) bumpRecordField(inventoryId, "tickets", 1) end
function M.getTickets(inventoryId) return readRecordField(inventoryId, "tickets") end
function M.addEvade(inventoryId) bumpRecordField(inventoryId, "evades", 1) end
function M.getEvades(inventoryId) return readRecordField(inventoryId, "evades") end
function M.addTaxiDropoff(inventoryId, passengers) bumpRecordField(inventoryId, "taxiDropoffs", passengers) end
function M.getTaxiDropoffs(inventoryId) return readRecordField(inventoryId, "taxiDropoffs") end
function M.addRepossession(inventoryId) bumpRecordField(inventoryId, "repos", 1) end
function M.getRepossessions(inventoryId) return readRecordField(inventoryId, "repos") end
function M.addMovieRental(inventoryId) bumpRecordField(inventoryId, "movieRentals", 1) end
function M.getMovieRentals(inventoryId) return readRecordField(inventoryId, "movieRentals") end
function M.addSuspectCaught(inventoryId) bumpRecordField(inventoryId, "suspectsCaught", 1) end
function M.getSuspectsCaught(inventoryId) return readRecordField(inventoryId, "suspectsCaught") end

function M.addDeliveredItems(inventoryId, amount)
  if not vehicles[inventoryId] then return end
  vehicles[inventoryId].deliveredItems = vehicles[inventoryId].deliveredItems or 0
  vehicles[inventoryId].deliveredItems = vehicles[inventoryId].deliveredItems + amount
end

function M.getDeliveredItems(inventoryId) return readRecordField(inventoryId, "deliveredItems") end

function M.setCertifications(vehId, certifications)
  local inventoryId = parts.ui.getInventoryIdFromVehicleId(vehId)
  if not inventoryId then return end
  vehicles[inventoryId].certifications = certifications
end

function M.getCertifications()
  local inventoryId = parts.ui.getInventoryIdFromVehicleId(be:getPlayerVehicleID(0))
  local vehicle = vehicles[inventoryId]
  if not vehicle then return {} end
  return vehicle.certifications
end

-- Mileage -----------------------------------------------------------------------------------------

function M.setMileage(inventoryId)
  if not inventoryId then inventoryId = garageState.currentVehicle end
  local vehicle = vehicles[inventoryId]
  if not vehicle or not vehicle.partConditions then return 0 end

  local maxOdometer = 0
  for _, conditionData in pairs(vehicle.partConditions) do
    if conditionData.odometer then
      maxOdometer = math.max(maxOdometer, conditionData.odometer)
    end
  end
  vehicle.mileage = maxOdometer
  return maxOdometer
end

function M.getAllFRETimes()
  local inventoryId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(be:getPlayerVehicleID(0))
  if not inventoryId then return {} end
  return vehicles[inventoryId].FRETimes
end

function M.getAllFRECompletions()
  local inventoryId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(be:getPlayerVehicleID(0))
  if not inventoryId then return {} end
  return vehicles[inventoryId].FRECompletions
end

-- Garage storage ----------------------------------------------------------------------------------

-- Picks the garage a stored vehicle goes to: the asked-for one when it can take it, else the closest owned garage.
local function resolveStorageGarage(id, garage)
  local garageManager = overhaul_career_garage_garageManager
  if garage and garageManager.isGarageForSale(garage) then
    log("W", "Inventory", string.format("Cannot move vehicle ID %d to garage %s - garage is listed for sale", id, tostring(garage)))
    garage = nil
  end

  if not garage or not garageManager.isGarageSpace(garage, id)[1] then
    garage = nil
    local bestGarage = getClosestOwnedGarageWithSpace(nil, nil, id)
    if bestGarage then
      garage = bestGarage.id
    end
  end

  -- Reject foreign-map garage ids so current-map records cannot acquire a garage from another level.
  if garage then
    local getFacilityIfExists = overhaul_world_facilities.getFacilityIfExists
    if not getFacilityIfExists("garage", garage) then
      garage = nil
      local bestGarage = getClosestOwnedGarageWithSpace(nil, nil, id)
      if bestGarage then
        garage = bestGarage.id
      else
        garage = garageManager.getNextAvailableSpace(id)
      end
    end
  end

  if not garage then
    garage = garageManager.getNextAvailableSpace(id)
  end
  return garage
end

local function reportNoGarageSpace(id)
  local availabilityReason = overhaul_career_garage_garageManager.getGarageAvailabilityReason() or "full"
  if availabilityReason == "none" then
    ui_message("You need to buy or rent a garage before storing vehicles.", nil, "vehicleInventory")
  else
    ui_message("No garage space is available for this vehicle.", nil, "vehicleInventory")
  end
  log("W", "Inventory", string.format("No available garage space found for vehicle ID %d (reason: %s)", id, tostring(availabilityReason)))
end

function M.moveVehicleToGarage(id, garage)
  local delivery = overhaul_career_logistics_general
  if not delivery.canRemoveLogisticsVehicle(id) then return false end
  if parts.persistence.isVehicleListedForAuction(id) then return false end

  garage = resolveStorageGarage(id, garage)
  if not garage then
    reportNoGarageSpace(id)
    return false
  end

  if vehicles[id] then
    vehicles[id].location = garage
    vehicles[id].worldPosition = nil
    if M.clearCarriedPlacement then M.clearCarriedPlacement(id) end
    vehicles[id].lastKnownLevel = getCurrentLevelIdentifier()
    vehicles[id].niceLocation = overhaul_career_garage_garageManager.garageIdToName(garage)
    log("I", "Inventory", string.format("Vehicle ID %d moved to garage: %s", id, garage))
    return true
  else
    log("W", "Inventory", string.format("Vehicle ID %d not found in inventory", id))
    return false
  end
end

function M.deliverVehicle(id, money)
  if parts.persistence.isVehicleListedForAuction(id) then return end
  if not M.moveVehicleToGarage(id) then return end
  local price = {money = {amount = money, canBeNegative = true}}
  overhaul_career_economy_payment.pay(price, require("overhaul/lib/finance/metadata").tag({label = string.format("Delivering vehicle to garage"), tags = {"delivery"}}, "service", {vehicleId = id}))
  parts.operations.delayVehicleAccess(id, 120, "delivery")
  parts.ui.sendVehicleUpdatesToUi()
end

function M.storeVehicle(id)
  return M.moveVehicleToGarage(id)
end

function M.switchGarageSpots(first, second)
  if parts.persistence.isVehicleListedForAuction(first) or parts.persistence.isVehicleListedForAuction(second) then
    return nil
  end
  local spot1 = vehicles[first].location
  local spot2 = vehicles[second].location
  if not spot1 or not spot2 then return nil end
  vehicles[first].location = spot2
  vehicles[first].niceLocation = overhaul_career_garage_garageManager.garageIdToName(spot2)
  vehicles[second].location = spot1
  vehicles[second].niceLocation = overhaul_career_garage_garageManager.garageIdToName(spot1)
  return true
end

function M.getVehicleLocation(id)
  if not vehicles[id] then return nil end
  return vehicles[id].location
end

-- Public API: records and operations --------------------------------------------------------------

M.addVehicle = parts.bindings.addVehicle
M.removeVehicle = parts.bindings.removeVehicle
M.removeVehicleObject = parts.bindings.removeVehicleObject
M.spawnVehicle = parts.spawn.spawnVehicle
M.enterVehicle = parts.spawn.enterVehicle
M.sellVehicle = parts.operations.sellVehicle
M.sellVehicleFromInventory = parts.operations.sellVehicleFromInventory
M.returnLoanedVehicleFromInventory = parts.operations.returnLoanedVehicleFromInventory
M.expediteRepairFromInventory = parts.operations.expediteRepairFromInventory
M.delayVehicleAccess = parts.operations.delayVehicleAccess
M.recoverPlayerAfterCompanyReturn = parts.operations.recoverPlayerAfterCompanyReturn
M.storeVehicleAtClosestGarage = parts.operations.storeVehicleAtClosestGarage
M.debugRespawnCurrentVehicle = parts.operations.debugRespawnCurrentVehicle
M.setFavoriteVehicle = parts.operations.setFavoriteVehicle
M.getFavoriteVehicle = parts.operations.getFavoriteVehicle
M.saveFRETimeToVehicle = parts.operations.saveFRETimeToVehicle
M.getFRETimeToVehicle = parts.operations.getFRETimeToVehicle
M.getFRECompletions = parts.operations.getFRECompletions
M.hasFreeSlot = parts.bindings.hasFreeSlot
M.getNumberOfFreeSlots = parts.bindings.getNumberOfFreeSlots
M.setVehicleDirty = parts.persistence.setVehicleDirty
M.getDirtiedVehicles = parts.operations.getDirtiedVehicles
M.getVehicles = parts.operations.getVehicles
M.getVehicle = parts.operations.getVehicle
M.isEmpty = parts.operations.isEmpty
M.updatePartConditions = parts.bindings.updatePartConditions
M.updatePartConditionsOfSpawnedVehicles = parts.persistence.updatePartConditionsOfSpawnedVehicles
M.getPartConditionsCallback = parts.bindings.getPartConditionsCallback
M.applyPartConditions = parts.bindings.applyPartConditions
M.applyPreparedMigration = parts.setup.applyPendingMigration
M.isVehiclePendingTravel = travel.isPending
M.prepareMapTravel = travel.prepare
M.clearPreparedMapTravel = travel.clear

-- Public API: license plates and names ------------------------------------------------------------

M.setLicensePlateText = parts.operations.setLicensePlateText
M.getLicensePlateText = parts.operations.getLicensePlateText
M.purchaseLicensePlateText = parts.operations.purchaseLicensePlateText
M.getLicensePlateCost = parts.operations.getLicensePlateCost
M.renameVehicle = parts.operations.renameVehicle
M.isLicensePlateValid = parts.operations.isLicensePlateValid
M.isVehicleNameValid = parts.operations.isVehicleNameValid

-- Public API: menu and UI data --------------------------------------------------------------------

M.openMenu = parts.ui.openMenu
M.closeMenu = parts.ui.closeMenu
M.requestPickerExit = parts.ui.requestPickerExit
M.openMenuFromComputer = parts.ui.openMenuFromComputer
M.chooseVehicleFromMenu = parts.ui.chooseVehicleFromMenu
M.openInventoryMenuForChoosingListing = parts.ui.openInventoryMenuForChoosingListing
M.sendDataToUi = parts.ui.sendDataToUi
M.sendVehicleUpdatesToUi = parts.ui.sendVehicleUpdatesToUi
M.getVehicleThumbnail = parts.ui.getVehicleThumbnail
M.ensureVehicleThumbnail = parts.persistence.ensureVehicleThumbnail
M.getVehicleNiceNameTranslated = parts.ui.getVehicleNiceNameTranslated
M.getVehicleUiData = parts.ui.getVehicleUiData
M.getVehicleDetailsUiData = parts.ui.getVehicleDetailsUiData
M.teleportedFromBigmap = parts.ui.teleportedFromBigmap

-- Public API: queries -----------------------------------------------------------------------------

M.isVehicleRestorePending = function()
  return travel.activeRestore ~= nil
end
M.isDamageRestorePending = parts.spawn.isDamageRestorePending
M.completeVehiclePlacement = parts.spawn.completeVehiclePlacement
M.deferVehiclePlacement = parts.spawn.deferVehiclePlacement
M.getCarriedPlacement = travel.getCarriedPlacement
M.rememberCarriedPlacement = travel.rememberCarriedPlacement
M.clearCarriedPlacement = travel.clearCarriedPlacement
M.getCurrentVehicle = getCurrentVehicle
-- Resolve the seated vehicle, not the last owned car (walking and work/test-drive cars can differ).
M.getPauseCardSummary = function()
  if gameplay_walk.isWalking() then return {kind = 'value', label = 'Current vehicle', value = 'On foot', icon = 'person'} end
  local playerId = be:getPlayerVehicleID(0)
  local inventoryId = vehIdToInventoryId[playerId]
  local name = inventoryId and parts.ui.getVehicleNiceNameTranslated(inventoryId)
  local thumbnail = inventoryId and parts.ui.getVehicleThumbnail(inventoryId)
  if not name then
    local details = core_vehicles.getCurrentVehicleDetails() or {}
    local model = details.model or {}
    thumbnail = (details.configs or {}).preview
    if type(thumbnail) ~= 'string' or thumbnail == '' or not FS:fileExists(thumbnail) then thumbnail = model.preview end
    local function translated(value)
      local text = value and core_locales.translateWithOrWithoutContext(value)
      return type(text) == 'string' and text ~= '' and text or nil
    end
    local brand = translated(model.Brand)
    local modelName = translated(model.Name)
    name = brand and modelName and (brand .. ' ' .. modelName) or modelName
      or translated((details.configs or {}).Name) or 'Unknown vehicle'
  end
  if type(thumbnail) ~= 'string' or thumbnail == '' or not FS:fileExists(thumbnail) then thumbnail = nil end
  if thumbnail and thumbnail:sub(1, 1) ~= '/' then thumbnail = '/' .. thumbnail end
  -- Match the garage's image version when a save refreshes a thumbnail in place.
  local vehicle = inventoryId and vehicles[inventoryId]
  if thumbnail and vehicle and vehicle.dirtyDate then thumbnail = thumbnail .. '?' .. tostring(vehicle.dirtyDate) end
  return {kind = 'value', label = 'Current vehicle', value = name, thumbnail = thumbnail}
end
M.getCurrentVehicleId = parts.ui.getCurrentVehicleId
M.getLastVehicle = parts.ui.getLastVehicle
M.getVehicleIdFromInventoryId = parts.ui.getVehicleIdFromInventoryId
M.getInventoryIdFromVehicleId = parts.ui.getInventoryIdFromVehicleId
M.getMapInventoryIdToVehId = parts.ui.getMapInventoryIdToVehId
M.isSeatedInsideOwnedVehicle = parts.ui.isSeatedInsideOwnedVehicle
M.getInventoryIdsInClosestGarage = parts.ui.getInventoryIdsInClosestGarage
M.getVehiclesInGarage = parts.ui.getVehiclesInGarage
M.getClosestGarage = getClosestGarage
M.getClosestOwnedGarageWithSpace = getClosestOwnedGarageWithSpace
M.getVehicleTimeToAccess = parts.operations.getVehicleTimeToAccess
M.getVehicleRetrievalQuote = getVehicleRetrievalQuote
M.useVehicleRetrievalService = useVehicleRetrievalService
-- A read-only view of the records and bindings, with stale-proof vehicle handles.
M.getRegistryView = function() return registryView end
-- Per-attempt spawn readiness (placed, bound, conditions, VE ack, damage, AI), observed only.
M.getSpawnReadiness = function() return parts.spawn.spawnReadiness end

-- Public API: auction listings --------------------------------------------------------------------

M.isVehicleListedForAuction = parts.persistence.isVehicleListedForAuction
M.getListedVehicleId = parts.persistence.getListedVehicleId
M.getListedVehicleIds = parts.persistence.getListedVehicleIds
M.isAuctionListingPending = parts.persistence.isAuctionListingPending
M.cancelPendingAuctionListings = parts.persistence.cancelPendingAuctionListings
M.setVehicleListedForAuction = parts.persistence.setVehicleListedForAuction
M.clearVehicleAuctionListing = parts.persistence.clearVehicleAuctionListing
M.getAuctionListingBlockReason = parts.persistence.auctionListingBlockReason

-- Sale contracts ----------------------------------------------------------------------------------

-- Providers retain their private state; each query resolves the currently loaded owner.
function M.getVehicleSaleSource(source)
  local owner = capabilities.get("vehicleSaleSource_" .. source)
  return owner and owner.getVehicleSaleSource()
end

function M.getVehicleShoppingService()
  local owner = capabilities.get("vehicleShoppingService")
  return owner and owner.getVehicleShoppingService()
end

function M.getVehicleNegotiationService()
  local owner = capabilities.get("vehicleNegotiationService")
  return owner and owner.getVehicleNegotiationService()
end

function M.getVehicleValuationService()
  return capabilities.get("vehicleValuationService")
end

function M.getVehicleSaleValueBonus(inventoryId)
  return capabilities.get("vehicleSaleReputation").getVehicleSaleValueBonus(inventoryId)
end

-- Sale observers ----------------------------------------------------------------------------------

M.subscribeVehicleSales = saleEvents.subscribe
M.publishVehicleSale = saleEvents.publish

-- Game hooks --------------------------------------------------------------------------------------

M.onExtensionLoaded = parts.setup.onExtensionLoaded
M.onOverhaulSaveCurrentProfile = parts.persistence.onOverhaulSaveCurrentProfile
M.onOverhaulSaveCurrentProfileAsyncStart = parts.persistence.onOverhaulSaveCurrentProfileAsyncStart
M.onBigMapActivated = parts.ui.onBigMapActivated
M.onUpdate = onUpdate
M.onBeforeWalkingModeToggled = parts.ui.onBeforeWalkingModeToggled
M.onOverhaulActive = parts.setup.onOverhaulActive
M.onWorldReadyState = parts.setup.onWorldReadyState
M.onOverhaulEnterVehicleFinished = parts.ui.onOverhaulEnterVehicleFinished
M.onExitVehicleInventory = parts.ui.onExitVehicleInventory
M.onScreenFadeState = parts.ui.onScreenFadeState
M.onAvailableMissionsSentToUi = parts.operations.onAvailableMissionsSentToUi
M.onOverhaulComputerAddFunctions = parts.operations.onOverhaulComputerAddFunctions
M.onOverhaulExperimentalMaintenanceModeChanged = onOverhaulExperimentalMaintenanceModeChanged
M.onOverhaulCheckPermission = parts.operations.onOverhaulCheckPermission
M.onGetRawPoiListForLevel = parts.operations.onGetRawPoiListForLevel

-- Inventory owns name resolution; finance only runs registered providers while recording.
local disposeFinanceProvider = require("overhaul/lib/finance/metadata").registerProvider("inventory.vehicleName", function(context)
  local finance = context.reason and context.reason.finance
  local id = type(finance) == "table" and finance.vehicleId
  if not id and type(finance) == "table" and finance.vehicleObjectId then
    id = M.getInventoryIdFromVehicleId(finance.vehicleObjectId)
  end
  if not id and type(finance) == "table" and finance.vehicleRole == "player" and be then
    id = M.getInventoryIdFromVehicleId(be:getPlayerVehicleID(0))
  end
  local vehicle = id and M.getVehicles()[tonumber(id) or id]
  if not vehicle then return end
  local key, changed = require("overhaul/lib/vehicles/financeIdentity").ensure(vehicle, Engine.generateUUID)
  if changed then M.setVehicleDirty(tonumber(id) or id) end
  local name = vehicle.niceName
  if type(name) == "table" then name = core_locales.translateWithOrWithoutContext(name) end
  return {vehicleId = id, vehicleName = name, vehicleKey = key}
end)
M.onExtensionUnloaded = function() disposeFinanceProvider() end

return M
