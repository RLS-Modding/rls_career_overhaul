-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding
-- Fork of stock lua/ge/extensions/career/modules/delivery/general.lua (BeamNG 0.40).

-- Owns delivery-mode state, its clock, vehicle containers and the logistics save boundary.
-- Private parts in general/ implement containers, points of interest and activity behavior.
-- Map of this file, in reading order:
--   state       runtime record (delivery mode, containers, POI cache), sibling services, clock, setup
--   binding     bindDeliveryDeps, and the parcel-access wrappers installed on the parcel manager
--   offers      which offers an audience may take (employment, independent, shared)
--   refresh     POI refresh requests and the POI cache snapshot
--   parts       containers, pois, poiList and activity, built in that order (general/*.lua)
--   save        the logistics database descriptor, the load, and the save projection
--   setup       map setup, activation and level switches
--   update      per-frame clock, background generation and container weights
--   delivery    start, exit, and the checks that end delivery mode
--   penalty     abandonment penalty and summary
--   settings    automatic route, drop-off detail and nav focus
--   facade      the public functions and game hooks on M, grouped by topic

local M = {}
local phoneLayout = require("overhaul/lib/phone/layoutOwner")
local moduleVersion = 42
local saveFile = "logisticsDatabase.json"

local parkingReservation = require('overhaul/lib/parking/reservation')
local persistence = require('overhaul/career/logistics/general/persistence')

-- Config --------------------------------------------------------------------------------------

local config = {
  abandonPenaltyFactor = 0.1,
  poiScanIntervalSec = 0.25,
  idleRefreshIntervalSec = 5,
  activeRefreshIntervalSec = 1,
  poiRefreshMaxTries = 90,
  staleSaveSeconds = 3600,
  timeScale = 1,
}

-- State ---------------------------------------------------------------------------------------

-- Delivery mode, container data and the POI cache. Shared with general/*.lua; not saved.
local runtime = {
  deliveryModeActive = false,
  lastInteractivePoiKey = nil,
  mostRecentCargoContainerData = {},
  nearbyScanGeneration = 0,
  nearbyScanLifecycle = 0,
  updateWeightsScheduled = false,
  defaultWeightUpdateActive = false,
  poiCargoSnapshot = setmetatable({}, {__mode = "k"}),
  noCargoApiUntil = {},
  warnedCargoResponses = {},
  rememberedWeightVehicleIds = {},
}

-- Sibling extensions the logistics code calls. bindDeliveryDeps refreshes them from the globals.
local deliveryServices = {
  parcelManager = nil,
  cargoScreen = nil,
  generator = nil,
  progress = nil,
  vehicleTasks = nil,
  vehicleOffers = nil,
  materialContracts = nil,
  ownerOpContracts = nil,
  parcelMods = nil,
  tasklist = nil,
  general = nil,
}

-- Delivery clock in sim seconds. It stops while paused and is only meaningful after a save loads.
local gameClock = {seconds = 0, paused = false, ready = false}
local poiRefresh = {framesLeft = nil, tries = 0}
-- Discovery has its own clock: changing its fallback must never change offer timing.
local discovery = {dirty = false, poiDirty = false, elapsed = 0, poiElapsed = 0, eventElapsed = math.huge, inFlight = nil, nextExpiry = math.huge}
local function resetDiscovery()
  discovery.dirty, discovery.poiDirty = false, false
  discovery.elapsed, discovery.poiElapsed, discovery.nextExpiry = 0, 0, math.huge
  discovery.eventElapsed, discovery.inFlight = math.huge, nil
  runtime.mostRecentCargoContainerData = {}
  runtime.nearbyScanGeneration = runtime.nearbyScanGeneration + 1
  runtime.nearbyScanLifecycle = runtime.nearbyScanLifecycle + 1
end
local function invalidateDiscovery()
  discovery.dirty, discovery.poiDirty = true, true
end
local function trackCargoExpiry(cargo)
  local expires = cargo and tonumber(cargo.offerExpiresAt)
  if expires and expires > gameClock.seconds then
    discovery.nextExpiry = math.min(discovery.nextExpiry, expires)
  end
end
-- completedMapId is the map whose setup finished, so its live freight may overwrite the saved database.
-- Unlike loadedMapId it survives the level-switch hook, because the travel save still holds that map's state.
local mapSetup = {loadedMapId = nil, completedMapId = nil, busy = false, mapHadProviders = false}
local tickTimer = 0
local settingDeliveryNavFocus = false
local savedFeature = nil
-- The loaded save, kept as the working copy for settings and the save projection.
local loadData = {}

local function withoutGeneration(fn)
  if deliveryServices.generator then
    return deliveryServices.generator.withoutGeneration(fn)
  end
  return fn()
end

-- binding ---------------------------------------------------------------------------------------

-- Reloads and activate races can leave the siblings unbound while career is active and the marker
-- interaction asks for POIs. Rebind from the globals on demand.
local function bindDeliveryDeps()
  deliveryServices.parcelManager = overhaul_career_logistics_parcelManager
  deliveryServices.cargoScreen = overhaul_career_logistics_cargoScreen
  deliveryServices.general = overhaul_career_logistics_general
  deliveryServices.generator = overhaul_career_logistics_generator
  deliveryServices.progress = overhaul_career_logistics_progress
  deliveryServices.vehicleTasks = overhaul_career_logistics_vehicleTasks
  deliveryServices.tasklist = overhaul_career_logistics_tasklist
  deliveryServices.parcelMods = overhaul_career_logistics_parcelMods
  deliveryServices.vehicleOffers = overhaul_career_logistics_vehicleOfferManager
  deliveryServices.materialContracts = overhaul_career_logistics_materialContractManager
  deliveryServices.ownerOpContracts = overhaul_career_logistics_ownerOpContracts
  return deliveryServices.parcelManager and deliveryServices.progress and deliveryServices.vehicleTasks
end

local function clearDeliveryParkingReservations()
  runtime.poiCargoSnapshot = setmetatable({}, {__mode = "k"})
  parkingReservation.setDeliveryDestinations({})
end
M.onClientEndMission = clearDeliveryParkingReservations

-- offers ----------------------------------------------------------------------------------------

-- Optional facility-generator offerMode: employment, independent, or shared (default).
-- This is the common cargo-board/dispatch boundary, regardless of map or authoring tool.
function M.isOfferAvailable(item, audience)
  if not item then return false end
  if audience == 'employment' and (item.brokerId or (item.data and item.data.brokerId)) then return false end
  if item.employmentAssigned and audience ~= "employment" then return false end
  local mode = item.offerMode
  if not mode or mode == "shared" then return true end
  return mode == (audience or "independent")
end

function M.canAcceptOffer(item, audience)
  if not M.isOfferAvailable(item, audience) then return false end
  if item.offerMode ~= "employment" then return true end
  local employment = overhaul_career_work_employment
  local company = employment and employment.getEmployerOrgId()
  return company ~= nil and (not item.organization or item.organization == company)
end

function M.migrateOfferAccess(item)
  if not item then return end
  item.offerMode = item.offerMode or item.plannerMode
  item.organization = item.organization or item.plannerCompanyId
  item.plannerMode = nil; item.plannerLineId = nil; item.plannerCompanyId = nil
  item.plannerDefinitionVersion = nil; item._plannerAccepted = nil
end

-- Wraps the parcel manager once. A move drops the cargo's old binding and captures it at the new spot;
-- audience-filtered listings and transient moves apply the employment offer rules.
local function installParcelAccess()
  local parcelManager = deliveryServices.parcelManager
  if not parcelManager or parcelManager._deliveryAccess then return end
  parcelManager._deliveryAccess = true
  local change = parcelManager.changeCargoLocation
  parcelManager.changeCargoLocation = function(id, location)
    local cargo = parcelManager.getCargoById(id)
    if cargo then cargo.logisticsBinding = nil; cargo.logisticsPending = nil end
    local result = change(id, location)
    if cargo then persistence.captureCargo(cargo) end
    invalidateDiscovery()
    return result
  end
  local list = parcelManager.getAllCargoForFacilityUnexpiredUndelivered
  parcelManager.getAllCargoForFacilityUnexpiredUndelivered = function(facId, minTime, maxTime, audience)
    local out = {}
    for _, cargo in ipairs(list(facId, minTime, maxTime)) do
      if M.isOfferAvailable(cargo, audience) then out[#out + 1] = cargo end
    end
    return out
  end
  local move = parcelManager.addTransientMoveCargo
  parcelManager.addTransientMoveCargo = function(id, target)
    local cargo = parcelManager.getCargoById(id)
    if cargo and cargo.offerMode == "employment" then
      local employment = overhaul_career_work_employment
      if not M.canAcceptOffer(cargo, "employment") or not (employment and employment.isAssignedCargo(cargo)) then return false end
    end
    return move(id, target)
  end
end

-- refresh ---------------------------------------------------------------------------------------

-- Discover available cargo while loading/screens are open, not during marker refreshes.
local function refreshPoiCargoSnapshot()
  if not bindDeliveryDeps() then return end
  local snapshot = setmetatable({}, {__mode = "k"})
  deliveryServices.parcelManager.getAllCargoCustomFilter(function(cargo)
    snapshot[cargo] = true
    trackCargoExpiry(cargo)
    return false
  end)
  runtime.poiCargoSnapshot = snapshot
end
M.refreshPoiCargoSnapshot = refreshPoiCargoSnapshot
M.onOverhaulCargoGenerated = function(cargo)
  runtime.poiCargoSnapshot[cargo] = true
  trackCargoExpiry(cargo)
  discovery.poiDirty = true
end
M.onOverhaulCargoRemoved = function(cargo)
  runtime.poiCargoSnapshot[cargo] = nil
  discovery.poiDirty = true
end

-- World drop-offs are baked into gameplay_rawPois once. Pause unsticks them only
-- because nearbyActivities calls clear() after career/cargo is actually ready.
-- Rebuild on the next updates so we do not cache an empty list from the first pass.
local function requestDeliveryPoiRefresh(resetTries)
  poiRefresh.framesLeft = 2
  discovery.poiDirty = true
  if resetTries then
    poiRefresh.tries = 0
  end
end

local function refreshDeliveryWorldPoisIfPending()
  if not poiRefresh.framesLeft then return end
  poiRefresh.framesLeft = poiRefresh.framesLeft - 1
  if poiRefresh.framesLeft > 0 then return end
  poiRefresh.framesLeft = nil
  poiRefresh.tries = poiRefresh.tries + 1
  if poiRefresh.tries > config.poiRefreshMaxTries then
    return
  end
  if not bindDeliveryDeps() then
    poiRefresh.framesLeft = 2
    return
  end
  if gameplay_rawPois then
    gameplay_rawPois.clear()
  end
end
M.requestDeliveryPoiRefresh = requestDeliveryPoiRefresh

M.onOverhaulPlayerAttributesChanged = function(change)
  -- Owner-operator access can change without any active cargo changing. Rebuild
  -- cached inspection/map markers after the XP and unlock listeners have settled.
  local logisticsXp = change and change["logistics-delivery"]
  if logisticsXp and logisticsXp ~= 0 then
    requestDeliveryPoiRefresh(true)
  end
end

-- parts -----------------------------------------------------------------------------------------

-- The parts reach these through M, so a replaced facade function still reaches the parts' callers.
local function deliveryModePenaltyForParts()
  return M.getDeliveryModePenalty()
end

local function requestContainerWeightUpdateForParts()
  M.requestUpdateContainerWeights()
end

local parts = {}
parts.containers = require("overhaul/career/logistics/general/containers").new({
  state = runtime,
  services = deliveryServices,
})
parts.pois = require("overhaul/career/logistics/general/pois").new({
  state = runtime,
  services = deliveryServices,
  parkingReservation = parkingReservation,
  bindDeliveryDeps = bindDeliveryDeps,
  clearDeliveryParkingReservations = clearDeliveryParkingReservations,
})
parts.poiList = require("overhaul/career/logistics/general/poiList").new({
  services = deliveryServices,
  pois = parts.pois,
  bindDeliveryDeps = bindDeliveryDeps,
  requestDeliveryPoiRefresh = requestDeliveryPoiRefresh,
})
parts.activity = require("overhaul/career/logistics/general/activity").new({
  state = runtime,
  services = deliveryServices,
  persistence = persistence,
  pois = parts.pois,
  deliveryModePenalty = deliveryModePenaltyForParts,
  requestContainerWeightUpdate = requestContainerWeightUpdateForParts,
})

M.getVehicleName = parts.containers.getVehicleName
M.getNearbyVehicleCargoContainers = parts.containers.getNearbyVehicleCargoContainers
M.rememberCargoWeightVehicle = parts.containers.rememberCargoWeightVehicle
M.rememberCurrentCargoWeightVehicles = parts.containers.rememberCurrentCargoWeightVehicles
M.updateContainerWeights = parts.containers.updateContainerWeights
-- Engine events include traffic. Only wake for a vehicle in the interaction footprint.
local function relevantVehicle(vehId)
  if vehId == nil then return true end
  if be and be.getPlayerVehicleID and be:getPlayerVehicleID(0) == vehId then return true end
  for _, container in ipairs(runtime.mostRecentCargoContainerData) do
    if container.vehId == vehId then return true end
  end
  local veh = scenetree and scenetree.findObjectById(vehId)
  local pos = core_camera and core_camera.getPosition and core_camera.getPosition()
  return veh and pos and (veh:getPosition() - pos):squaredLength() <= 1600
end
local function onVehicleChanged(vehId)
  if relevantVehicle(vehId) then invalidateDiscovery() end
end
M.onVehicleSpawned = function(vehId)
  parts.containers.clearNoCargoApiRetry(vehId)
  onVehicleChanged(vehId)
end
M.onVehicleSwitched = invalidateDiscovery
M.onVehicleDestroyed = onVehicleChanged
M.onVehicleResetted = M.onVehicleSpawned
M.onCouplerAttached = function(id1, id2)
  if relevantVehicle(id1) or relevantVehicle(id2) then invalidateDiscovery() end
end
M.onCouplerDetached = M.onCouplerAttached
M.onBeamNGTrigger = function(data)
  if type(data) == "table" and relevantVehicle(data.subjectID) then invalidateDiscovery() end
end
M.onOverhaulNearbyPoiSetChanged = invalidateDiscovery
M.onOverhaulPoiAreaChanged = invalidateDiscovery
M.getMostRecentCargoContainerData = function() return runtime.mostRecentCargoContainerData end

M.playerAtFacilityStall = parts.pois.playerAtFacilityStall
M.onGetRawPoiListForLevel = parts.poiList.onGetRawPoiListForLevel
M.onActivityAcceptGatherData = parts.activity.onActivityAcceptGatherData
M.onOverhaulCheckPermission = parts.activity.onOverhaulCheckPermission

-- save ------------------------------------------------------------------------------------------

local function saveableCargoFilter(cargo)
  local employment = overhaul_career_work_employment
  if employment.isAssignedCargo(cargo) then return false end
  -- Reservation ledgers save uncollected material; persistentJobs saves the
  -- actual accepted vehicle loads, including quantities already in transit.
  if cargo.data and cargo.data.materialContractId then return false end
  if cargo.data and cargo.data.passiveBusinessSupplyReservationId then return false end
  if cargo.data and cargo.data.engineShopSupplyReservationId then return false end
  if cargo.data and cargo.data.delivered then return true end
  return cargo.location.type == "facilityParkingspot"
    and cargo.generatorLabel ~= "addMaterialAsParcelToContainer"
end

local function saveableParcelRecord(cargo)
  local record = {
    id = cargo.id,
    rewards = cargo.rewards,
    templateId = cargo.templateId,
    offerMode = cargo.offerMode,
    name = cargo.name,
    type = cargo.type,
    slots = cargo.slots,
    offerExpiresAt = cargo.offerExpiresAt,
    location = cargo.location,
    origin = cargo.origin,
    destination = cargo.destination,
    data = cargo.data,
    generatorLabel = cargo.generatorLabel,
    modifiers = cargo.modifiers,
    generatedAtTimestamp = cargo.generatedAtTimestamp,
    weight = cargo.weight,
    density = cargo.density,
    groupSeed = cargo.groupSeed,
    automaticDropOff = cargo.automaticDropOff,
    organization = cargo.organization,
    materialType = cargo.materialType,
    merge = cargo.merge,
    sourceStorage = cargo.sourceStorage,
    hiddenInFacility = cargo.hiddenInFacility,
  }
  for _, key in ipairs({'brokerId', 'employmentAssigned', 'loadedAtTimeStamp', 'loanerOrganisations',
      'logisticsBinding', 'logisticsPending', 'homeMap', 'accepted', 'reserved', 'booked', 'loading'}) do record[key] = cargo[key] end
  -- A staged move has scene IDs and cannot be replayed after a reload. Keep its
  -- original job available to load again instead of treating it as fresh stock.
  record.logisticsReserved = cargo._transientMove ~= nil or cargo.logisticsReserved or nil
  return record
end

-- Parcel records with group ids renumbered in first-seen order, and the number of groups.
local function buildParcelSaveRecords(referencedIds)
  local records = {}
  local maxGroupId = 0
  local groupMap = {}
  for _, cargo in ipairs(deliveryServices.parcelManager.getAllCargoCustomFilter(saveableCargoFilter)) do
    if not persistence.isRegenerableOffer(cargo, referencedIds) then
      local record = saveableParcelRecord(cargo)
      local group = cargo.groupId or cargo.id
      if not groupMap[group] then
        maxGroupId = maxGroupId + 1
        groupMap[group] = maxGroupId
      end
      record.groupId = groupMap[group]
      table.insert(records, record)
    end
  end
  return records, maxGroupId
end

local function buildFacilitySaveRecords()
  local records = {}
  for _, facility in ipairs(deliveryServices.generator.getFacilities()) do
    local record = {
      logisticGenerators = {},
      progress = facility.progress,
      materialStorages = facility.materialStorages,
    }
    for i, generator in ipairs(facility.logisticGenerators or {}) do
      record.logisticGenerators[i] = {nextGenerationTimestamp = generator.nextGenerationTimestamp}
    end
    records[facility.id] = record
  end
  return records
end

-- Defined with the load below; the capture needs it to keep the saved database.
local readSavedDatabase

-- Setup discards saved freight whose facilities are not loaded yet. A save before setup
-- finished would write that emptied list over the database for good.
local function liveStateMatchesSavedDatabase()
  return mapSetup.completedMapId ~= nil and mapSetup.completedMapId == getCurrentLevelIdentifier()
end

-- Writes the previous slot's database unchanged. False when there is none to keep.
local function keepPreviousDatabase(context)
  local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
  local previous = savePath and readSavedDatabase(savePath)
  if not previous then return false end
  log("W", "delivery", string.format("Logistics setup for map %s has not finished; keeping the previously saved database",
    tostring(getCurrentLevelIdentifier())))
  context.write(previous)
  return true
end

local function captureSaveData(context)
  if not liveStateMatchesSavedDatabase() and keepPreviousDatabase(context) then return end
  local saveData = {
    general = {},
    persistentJobs = persistence.serialize(true),
    settings = loadData.settings or {},
    materialContracts = deliveryServices.materialContracts.serialize() or nil,
    ownerOpContracts = deliveryServices.ownerOpContracts.serialize(true) or nil,
    broker = overhaul_career_logistics_broker.serialize(true) or nil,
  }
  saveData.general.gameTime = M.time()
  saveData.general.osTime = os.time()
  saveData.progress = deliveryServices.progress.getProgress()
  saveData.parcelModProgress = deliveryServices.parcelMods.getProgress()

  local referencedIds = persistence.referencedOfferIds(saveData)
  local parcels, maxGroupId = buildParcelSaveRecords(referencedIds)
  saveData.parcels = parcels
  saveData.general.maxGroupId = maxGroupId

  saveData.vehicleOffers = {}
  for _, offer in ipairs(deliveryServices.vehicleOffers.getAllSaveableOffers()) do
    if not persistence.isRegenerableOffer(offer, referencedIds) then
      table.insert(saveData.vehicleOffers, offer)
    end
  end

  saveData.facilities = buildFacilitySaveRecords()
  context.write(saveData)
end

local function saveFeature()
  if not savedFeature then
    savedFeature = assert(require('overhaul/lib/save/store').bind(overhaul_career_saveSystem).feature('logistics.database', {
      owner = 'overhaul_career_logistics_general', files = {'career/' .. saveFile},
      root = 'slot', phase = 'profile', required = true, writer = {pretty = false},
      capture = function(context) captureSaveData(context) end,
    }))
  end
  return savedFeature
end

-- Save data older than staleSaveSeconds keeps its parcels and clock, but its generator timers are cleared.
local function wipeStaleSaveTimers()
  local savedOsTime = loadData.general and loadData.general.osTime
  if not savedOsTime then return end
  local ageSec = os.time() - savedOsTime
  log("I", "", string.format("Save data age: %ds", ageSec))
  if ageSec > config.staleSaveSeconds then
    log("I", "", string.format("Save data is older than %ds (%d), wiping cargo and facility timers", config.staleSaveSeconds, ageSec))
    loadData.cargo = {}
    for _, facility in pairs(loadData.facilities) do
      facility.logisticGenerators = nil
    end
  end
end

-- The slot's database file, or nil when the slot is missing, outdated or has no database.
readSavedDatabase = function(savePath)
  local saveInfo = jsonReadFile(savePath .. "/info.json")
  if not saveInfo or saveInfo.version < moduleVersion then return nil end
  return jsonReadFile(saveFeature().path(savePath))
end

local function loadSaveData()
  local saveSlot, savePath = overhaul_career_saveSystem.getCurrentProfile()
  if not saveSlot then return end

  local data = (savePath and readSavedDatabase(savePath)) or {}

  loadData = data
  -- Old databases included the entire facility board. Retain referenced work,
  -- then let generator setup refill the untaken pools from current definitions.
  local referencedIds = persistence.referencedOfferIds({broker = data.broker,
    persistentJobs = data.persistentJobs, ownerOpContracts = data.ownerOpContracts,
    materialContracts = data.materialContracts})
  for _, key in ipairs({'parcels', 'vehicleOffers'}) do
    local retained = {}
    for _, item in ipairs(data[key] or {}) do
      if not persistence.isRegenerableOffer(item, referencedIds) then retained[#retained + 1] = item end
    end
    loadData[key] = retained
  end
  local savedMap = persistence.savedMap(data.persistentJobs)
  if data.persistentJobs then
    loadData.materialContracts = savedMap and savedMap.materialContracts
    loadData.ownerOpContracts = savedMap and savedMap.ownerOpContracts
  end
  deliveryServices.progress.setProgress(loadData.progress)
  deliveryServices.parcelMods.setProgress(loadData.parcelModProgress)
  loadData.facilities = loadData.facilities or {}
  loadData.settings = data.settings or {}

  if loadData.settings.automaticRoute == nil then
    loadData.settings.automaticRoute = true
  end

  gameClock.seconds = loadData.general and loadData.general.gameTime or gameClock.seconds
  gameClock.ready = true
  wipeStaleSaveTimers()
end
M.loadSaveData = loadSaveData

M.onOverhaulSaveCurrentProfile = function(currentSavePath)
  saveFeature().capture(currentSavePath)
end

-- The save feature is disposed when this extension unloads, after the reservations are cleared.
M.onExtensionUnloaded = function()
  clearDeliveryParkingReservations()
  if savedFeature then savedFeature.dispose(); savedFeature = nil end
end

-- setup -----------------------------------------------------------------------------------------

local function currentMapId()
  return getCurrentLevelIdentifier()
end

local function mapHasDeliveryProviders(mapId)
  local providers = overhaul_world_facilities.getFacilitiesByType("deliveryProvider", mapId)
  return type(providers) == "table" and providers[1] ~= nil
end

local function generatorNeedsResync(mapId)
  local generator = deliveryServices.generator
  if not generator then return true end
  if generator.getSetupLevelIdentifier() ~= mapId then return true end
  if generator.hasFacilities() then return false end
  return mapHasDeliveryProviders(mapId) and not mapSetup.mapHadProviders
end

local function levelSwitchInProgress()
  local switchState = overhaul_career_career.getLevelSwitchState()
  local phase = switchState and switchState.phase
  return phase ~= nil and phase ~= "idle"
end

-- Loads the save, parcels, contracts and broker for the current map, once per map.
local function setupLogisticsForMap(mapId)
  mapSetup.completedMapId = nil
  log("I", "delivery", string.format("Setting up logistics for map %s (was %s)",
    tostring(mapId), tostring(deliveryServices.generator.getSetupLevelIdentifier())))
  loadSaveData()
  map.assureLoad()
  installParcelAccess()
  deliveryServices.vehicleOffers.resetOffersForLoad()
  deliveryServices.generator.setup(loadData)
  refreshPoiCargoSnapshot()
  persistence.load(loadData.persistentJobs)
  if deliveryServices.materialContracts then
    deliveryServices.materialContracts.setup(loadData.materialContracts)
  end
  if not overhaul_career_logistics_broker then extensions.load('overhaul_career_logistics_broker') end
  overhaul_career_logistics_broker.setup(loadData.broker)
  deliveryServices.ownerOpContracts.setup(loadData.ownerOpContracts)
  persistence.restore()
  mapSetup.mapHadProviders = mapHasDeliveryProviders(mapId)
  local ready = deliveryServices.generator.hasFacilities() or not mapSetup.mapHadProviders
  mapSetup.loadedMapId = ready and mapId or nil
  mapSetup.completedMapId = mapSetup.loadedMapId
  invalidateDiscovery()
  requestDeliveryPoiRefresh(true)
  return ready
end

local function ensureSetupForCurrentMap(force)
  if mapSetup.busy then return mapSetup.loadedMapId == currentMapId() end
  if not overhaul_career_career.isActive() then return false end
  if not bindDeliveryDeps() then
    log("E", "delivery", "ensureSetupForCurrentMap: delivery deps not ready (parcelManager missing)")
    return false
  end
  local mapId = currentMapId()
  if not mapId or mapId == '' then return false end
  if force then
    mapSetup.loadedMapId = nil
    mapSetup.mapHadProviders = false
  elseif levelSwitchInProgress() then
    return false
  elseif mapSetup.loadedMapId == mapId and not generatorNeedsResync(mapId) then
    return true
  end

  mapSetup.busy = true
  local ok, result = xpcall(function()
    return setupLogisticsForMap(mapId)
  end, debug.traceback)
  mapSetup.busy = false
  if not ok then
    mapSetup.loadedMapId = nil
    mapSetup.mapHadProviders = false
    log("E", "delivery", "ensureSetupForCurrentMap failed:\n" .. tostring(result))
    return false
  end
  return result and true or false
end
M.ensureSetupForCurrentMap = ensureSetupForCurrentMap

local function onOverhaulActive(active)
  if not active then
    mapSetup.loadedMapId = nil
    mapSetup.completedMapId = nil
    mapSetup.mapHadProviders = false
    runtime.deliveryModeActive = false
    resetDiscovery()
    persistence.reset()
    clearDeliveryParkingReservations()
    return
  end
  ensureSetupForCurrentMap()
end
M.onOverhaulActive = onOverhaulActive
M.onOverhaulBeforeCareerLevelSwitch = function()
  persistence.shelveForeign()
  resetDiscovery()
  mapSetup.loadedMapId = nil
  mapSetup.mapHadProviders = false
end
M.onOverhaulMapTravelCompleted = function()
  ensureSetupForCurrentMap(true)
end
M.onWorldReadyState = function(state)
  if state == 2 then ensureSetupForCurrentMap() end
end

M.onCareerActivated = function()
  bindDeliveryDeps()
end

-- update ----------------------------------------------------------------------------------------

M.time = function() return gameClock.seconds end
M.isGameTimeReady = function() return gameClock.ready end
M.setDeliveryTimePaused = function(paused) gameClock.paused = paused end
M.isDeliveryTimePaused = function() return gameClock.paused end

M.isContainerWeightUpdatePending = function()
  return runtime.updateWeightsScheduled or runtime.defaultWeightUpdateActive
end
M.requestUpdateContainerWeights = function() runtime.updateWeightsScheduled = true end

M.onUpdate = function(dtReal, dtSim, dtRaw)
  profilerPushEvent("Delivery DeliveryManager")
  if poiRefresh.framesLeft then
    withoutGeneration(refreshDeliveryWorldPoisIfPending)
  end
  if not gameClock.paused then
    gameClock.seconds = gameClock.seconds + dtSim * config.timeScale
  end

  -- Old saves stored a speculative abandonment fine. Loading is not abandoning.
  loadData.penalty = nil

  tickTimer = tickTimer + dtSim
  if deliveryServices.generator then
    deliveryServices.generator.updateBackgroundGeneration(tickTimer > 1)
  end
  if tickTimer > 1 then
    tickTimer = tickTimer - 1
  end

  -- Events coalesce into one discovery pass. The bounded fallback covers moving
  -- loose containers and third-party changes that do not publish lifecycle hooks.
  if overhaul_career_career and overhaul_career_career.isActive() and not levelSwitchInProgress() then
    discovery.elapsed = discovery.elapsed + (dtSim or 0)
    discovery.eventElapsed = discovery.eventElapsed + (dtReal or 0)
    discovery.poiElapsed = discovery.poiElapsed + (dtReal or 0)
    local interval = runtime.deliveryModeActive and config.activeRefreshIntervalSec or config.idleRefreshIntervalSec
    if gameClock.seconds >= discovery.nextExpiry then
      discovery.nextExpiry = math.huge
      for cargo in pairs(runtime.poiCargoSnapshot) do trackCargoExpiry(cargo) end
      discovery.poiDirty = true
    end
    local fallbackDue = discovery.elapsed >= interval
    -- A lost bridge reply must not disable the bounded safety pass.
    local containersDue = fallbackDue or (not discovery.inFlight and discovery.dirty and discovery.eventElapsed >= config.poiScanIntervalSec)
    if containersDue then
      discovery.dirty, discovery.elapsed, discovery.eventElapsed = false, 0, 0
      local scan = {}
      discovery.inFlight = scan
      persistence.reconcile()
      M.getNearbyVehicleCargoContainers(function()
        if discovery.inFlight == scan then discovery.inFlight = nil end
      end)
    end
    if containersDue or (discovery.poiDirty and discovery.poiElapsed >= config.poiScanIntervalSec) then
      discovery.poiDirty, discovery.poiElapsed = false, 0
      withoutGeneration(parts.pois.refreshDeliveryWorldPoisIfChanged)
    end
  end

  -- Weight requests may outlive delivery mode (unloading must clear the last load).
  if dtSim > 10e-10 and runtime.updateWeightsScheduled then
    M.updateContainerWeights()
  end
  profilerPopEvent("Delivery DeliveryManager")
end

-- delivery --------------------------------------------------------------------------------------

local function startDeliveryMode()
  if runtime.deliveryModeActive then return end
  bindDeliveryDeps()
  log("I", "", "Delivery Mode Started.")
  runtime.deliveryModeActive = true
  invalidateDiscovery()
  gameplay_rawPois.clear()
  requestDeliveryPoiRefresh(true)
  deliveryServices.tasklist.sendCargoToTasklist()
  extensions.hook("onOverhaulDeliveryModeStarted")
end
M.startDeliveryMode = startDeliveryMode

-- Shown when a delivery is abandoned with a fine; the phone layout is loaded on demand.
local function fireCargoAbandonedNotification(penaltyAmount)
  if not penaltyAmount or penaltyAmount >= 0 then return end
  local layout = phoneLayout.get()
  if layout then
    layout.fireNotification("logistics.cargoAbandoned", {
      title = "Cargo Abandoned",
      message = string.format("Penalty: $%0.2f", -penaltyAmount),
      kind = "warning",
      ttl = 8,
      source = "Logistics",
      sound = {soundClass = "AudioGui", type = "event:>UI>Missions>Info_Open"},
    })
  end
end

-- Cargo aboard goes back to a supplier that takes it, otherwise it is deleted.
local function returnOrDeleteCargo(cargoInVehicles)
  for _, cargo in ipairs(cargoInVehicles) do
    local passiveBusiness = overhaul_career_business_passive
    local engineShop = overhaul_career_business_engineShop
    if not (engineShop and engineShop.returnCargoToSupplier(cargo, false))
        and not (passiveBusiness and passiveBusiness.returnCargoToSupplier(cargo, false)) then
      deliveryServices.parcelManager.changeCargoLocation(cargo.id, {type = "delete"})
    end
  end
end

local function announceAbandonPenalty(penalty)
  local hasPenalty = false
  for _, amount in pairs(penalty) do
    if amount < 0 then hasPenalty = true; break end
  end
  if not hasPenalty then return end
  if penalty.money < 0 then fireCargoAbandonedNotification(penalty.money) end
  log("I", "", string.format("Penalty for abandoning cargo: %0.2f$", -penalty.money))
  overhaul_career_economy_playerAttributes.addAttributes(penalty, require("overhaul/lib/finance/metadata").tag({tags = {"gameplay", "delivery", "fine"}, label = "ui.career.delivery.general.penaltyAbandonLabel"}, "fine"))
  Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Buy_01')
end

local function exitDeliveryMode(explicitAbandon, fromEmployment)
  if not runtime.deliveryModeActive then return end
  local parcelManager = deliveryServices.parcelManager
  if not explicitAbandon and (next(parcelManager.getAllCargoInVehicles(true)) or next(deliveryServices.vehicleTasks.getVehicleTasks())
      or (deliveryServices.materialContracts and next(deliveryServices.materialContracts.getActiveContracts()))) then
    return false
  end
  -- Close the transaction gate before cleanup hooks can re-enter this method.
  runtime.deliveryModeActive = false
  log("I", "", "Delivery Mode Exited.")
  -- clearTransientFlags is a deprecated stub that only emits an error. Clear
  -- the real pending-move list when leaving delivery mode instead.
  parcelManager.clearAllTransientMoves()
  local penalty = M.getDeliveryModePenalty()
  local cargoInVehicles = parcelManager.getAllCargoInVehicles(true)
  for _, cargo in ipairs(cargoInVehicles) do
    if cargo.location and cargo.location.vehId then
      M.rememberCargoWeightVehicle(cargo.location.vehId)
    end
  end
  returnOrDeleteCargo(cargoInVehicles)
  announceAbandonPenalty(penalty)

  deliveryServices.vehicleTasks.abandonAllVehicleTasks()

  if explicitAbandon and deliveryServices.materialContracts then
    -- The combined penalty already includes each contract once.
    deliveryServices.materialContracts.abandonContract(nil, {noFine = true, silent = true})
  end

  parcelManager.clearAllTransientMoves()

  runtime.deliveryModeActive = false
  invalidateDiscovery()
  local employment = overhaul_career_work_employment
  if explicitAbandon and not fromEmployment and employment then
    employment.onLogisticsAbandoned()
  end
  gameplay_rawPois.clear()
  freeroam_bigMapMode.setNavFocus(nil)

  M.requestUpdateContainerWeights()
  deliveryServices.tasklist.clearAll()
  if deliveryServices.materialContracts then
    deliveryServices.materialContracts.refreshTaskGuidance(true)
  end
  extensions.hook("onOverhaulDeliveryModeStopped")
end
M.exitDeliveryMode = exitDeliveryMode

local function checkExitDeliveryMode()
  local employment = overhaul_career_work_employment
  if employment and employment.keepDeliveryModeActive() then
    return
  end
  local transfer = overhaul_career_logistics_vehicleTransfer
  if transfer and transfer.isOnShift() then
    return
  end
  local cargoInVehicles = deliveryServices.parcelManager.getAllCargoInVehicles(true)
  local vehicleTasks = deliveryServices.vehicleTasks.getVehicleTasks()
  if not next(cargoInVehicles) and not next(vehicleTasks) then
    M.exitDeliveryMode()
  end
end
M.checkExitDeliveryMode = checkExitDeliveryMode
M.isDeliveryModeActive = function() return runtime.deliveryModeActive end

-- penalty ---------------------------------------------------------------------------------------

-- Resolve inventory when eligibility needs it; the broker extension may be absent during save queries.
local function inventoryIdForBrokerCargo(vehId)
  local inventory = overhaul_career_garage_inventory
  return inventory and inventory.getInventoryIdFromVehicleId(vehId)
end

-- Whether a cargo item counts toward the penalty for this query: the vehicle filter, the saved
-- freight exclusion, and the caller's own filter.
local function penaltyAppliesToCargo(cargo, onlyVehIdsAsKeys, forSave, cargoFilter)
  if onlyVehIdsAsKeys and not (cargo.location.vehId and onlyVehIdsAsKeys[cargo.location.vehId]) then
    return false
  end
  if forSave and require('overhaul/lib/logistics/brokerCargoBinding').canPersistCargo(cargo, inventoryIdForBrokerCargo) then
    return false
  end
  if cargoFilter and not cargoFilter(cargo) then
    return false
  end
  return true
end

local function addCargoPenalty(penalty, cargo)
  local abandonFactor = M.getDeliveryAbandonPenaltyFactor()
  local modifierFactor = 0
  if cargo.modifiers then
    for _, mod in ipairs(cargo.modifiers) do
      modifierFactor = modifierFactor + (mod.abandonMultiplier or 0)
    end
  end
  if not cargo._transientMove and not (cargo.data and cargo.data.materialContractId) then
    local rewardMoney = cargo.rewards and tonumber(cargo.rewards.money) or 0
    penalty.money = penalty.money - rewardMoney * (abandonFactor + modifierFactor)
  end
  if cargo.organization and cargo.rewards then
    local repKey = cargo.organization .. "Reputation"
    local repHit = math.ceil(tonumber(cargo.rewards[repKey]) or 0)
    if repHit ~= 0 then
      penalty[repKey] = (penalty[repKey] or 0) - repHit
    end
  end
end

M.getDeliveryModePenalty = function(onlyVehIdsAsKeys, forSave, cargoFilter)
  local cargoInVehicles = deliveryServices.parcelManager.getAllCargoInVehicles(true)
  local penalty = {money = 0}
  if not onlyVehIdsAsKeys and not cargoFilter then
    local fine = deliveryServices.vehicleTasks.getFineForAbandonAllVehicleTasks(forSave)
    for attKey, amount in pairs(fine) do
      penalty[attKey] = (penalty[attKey] or 0) + amount
    end
  end

  for _, cargo in ipairs(cargoInVehicles) do
    if penaltyAppliesToCargo(cargo, onlyVehIdsAsKeys, forSave, cargoFilter) then
      addCargoPenalty(penalty, cargo)
    end
  end
  if not onlyVehIdsAsKeys and not cargoFilter and deliveryServices.materialContracts then
    for _, contract in ipairs(deliveryServices.materialContracts.getActiveContracts()) do
      penalty.money = penalty.money - (tonumber(contract.abandonmentFine) or 0)
    end
  end
  return penalty
end

M.getDeliveryAbandonPenaltyFactor = function() return config.abandonPenaltyFactor end

M.getAbandonmentSummary = function()
  local jobs, seen = {}, {}
  for _, cargo in ipairs(deliveryServices.parcelManager.getAllCargoInVehicles(true)) do
    local name = cargo.name or 'Cargo delivery'
    if not seen[name] then jobs[#jobs + 1] = {name = name}; seen[name] = true end
  end
  for _, task in ipairs(deliveryServices.vehicleTasks.getVehicleTasks()) do
    if not task.remove and not task.finished then
      jobs[#jobs + 1] = {name = task.offer.name or task.offer.vehicle.name or 'Vehicle delivery'}
    end
  end
  for _, contract in ipairs(deliveryServices.materialContracts.getActiveContracts()) do
    jobs[#jobs + 1] = {name = (contract.materialName or 'Material') .. ' contract: ' .. (contract.destinationName or contract.destinationFacId or '')}
  end
  return {jobs = jobs, penalty = math.max(0, -(M.getDeliveryModePenalty().money or 0))}
end

-- settings --------------------------------------------------------------------------------------

local function isAutomaticRouteEnabled()
  return loadData.settings.automaticRoute
end
M.isAutomaticRouteEnabled = isAutomaticRouteEnabled

M.setDeliveryNavFocus = function(pos)
  settingDeliveryNavFocus = true
  freeroam_bigMapMode.setNavFocus(pos)
  settingDeliveryNavFocus = false
end

local function setAutomaticRoute(enabled)
  loadData.settings.automaticRoute = enabled
  if enabled then
    overhaul_career_logistics_cargoScreen.setBestRoute()
  else
    core_groundMarkers.setPath(nil)
    freeroam_bigMapMode.resetRoute()
  end
  guihooks.trigger("automaticRouteSet", enabled)
end

local function setDetailedDropOff(enabled)
  loadData.settings.detailedDropOff = enabled
  guihooks.trigger("detailedDropOffSet", enabled)
end

-- Deactivate automatic route when setting a manual waypoint
local function onSetBigmapNavFocus()
  if M.isDeliveryModeActive() and not settingDeliveryNavFocus then
    setAutomaticRoute(false)
  end
end

local function setSetting(key, value)
  loadData.settings[key] = value
end

local function getSettings()
  return loadData.settings
end

M.setAutomaticRoute = setAutomaticRoute
M.setDetailedDropOff = setDetailedDropOff
M.onSetBigmapNavFocus = onSetBigmapNavFocus
M.setSetting = setSetting
M.getSettings = getSettings

-- facade ----------------------------------------------------------------------------------------

-- Service UI entry captures stable container identities before preview respawns.
M.onOverhaulPartShoppingStarted = function()
  persistence.capture()
end

M.onCareerPaintingStarted = function()
  persistence.capture()
end

M.onOverhaulTuningStarted = function()
  persistence.capture()
end

M.onTeleportedToGarage = function(garageId, veh)
  invalidateDiscovery()
  persistence.reconcile()
end

-- Missions may temporarily replace the scene; accepted work remains bound to inventory.
M.onAnyMissionChanged = function() persistence.capture() end

M.onOverhaulRepairInGarage = function(invVehId)
  persistence.capture()
end

M.onOverhaulInventoryPreRemoveVehicleObject = function(inventoryId, vehId)
  persistence.suspendVehicle(inventoryId, vehId)
end

M.capturePersistentCargo = persistence.capture
M.capturePersistentTask = persistence.captureTask
M.canRemoveLogisticsVehicle = persistence.allowRemoval
M.validateLogisticsContainers = persistence.validateVehicle
M.getPendingLogisticsVehicles = persistence.getPending
M.retryLogisticsVehicle = persistence.retry
M.ownerOfFacility = persistence.ownerOfFacility
M.belongsHere = persistence.belongsHere
M.parkMaterialContracts = persistence.parkMaterialContracts

return M
