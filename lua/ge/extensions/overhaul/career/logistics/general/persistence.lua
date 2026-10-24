-- Shared saved freight. Map: vehicle binding/reconcile, map ownership, snapshots/projection, serialize/load/restore.
-- Read relevantCargo, parcels, tasks, inventory, mapId in order.

local M = {}

-- Config ------------------------------------------------------------------------------------------

-- Metadata only: general.lua writes the delivery database with this module's projection.
require("overhaul/lib/save/store").registerKeys({
  { key = "logistics.database", owner = "overhaul_career_logistics_general", files = { "career/logisticsDatabase.json" }, phase = "profile", required = true },
})

-- State -------------------------------------------------------------------------------------------

-- Saved per-map snapshots and the map currently loaded. Accepted freight belongs to an inventory vehicle, not its temporary scene ID, so every binding below is keyed by inventory ID.
local maps, activeMap = {}, nil
-- Facility ID to owning map name; false caches a miss so it is not searched again.
local facilityOwnerCache = {}
local heldOfferFields = {'brokerId', 'employmentAssigned', 'logisticsBinding', 'logisticsPending',
  '_transientMove', 'loadedAtTimeStamp', 'spawned', '_spawning', 'spawnWhenCommitingCargo', 'logisticsTask',
  'logisticsReserved', 'accepted', 'reserved', 'booked', 'loading'}

-- Only untouched generator output may be omitted. Unknown/custom work and any
-- ownership marker remain conservative, including future reservation kinds.
function M.isRegenerableOffer(item, referencedIds)
  if not item.generatorLabel or (referencedIds and referencedIds[item.id]) then return false end
  for _, key in ipairs(heldOfferFields) do
    if item[key] then return false end
  end
  local data = item.data or {}
  if data.delivered then return false end
  for key, value in pairs(data) do
    if type(key) == 'string' and key:match('Id$') and value ~= nil then return false end
  end
  local location = item.location or item.spawnLocation
  return location ~= nil and location.type == 'facilityParkingspot'
end

function M.referencedOfferIds(saved)
  local ids, seen = {}, {}
  local function visit(value)
    if type(value) ~= 'table' or seen[value] then return end
    seen[value] = true
    for key, entry in pairs(value) do
      if key == 'nativeId' or key == 'cargoId' or key == 'offerId' then ids[entry] = true end
      if type(entry) == 'table' then visit(entry) end
    end
  end
  visit(saved)
  return ids
end

-- Freight and vehicle lookup -----------------------------------------------------------------------------------------

local function relevantCargo(cargo)
  return cargo.logisticsBinding or (cargo.location and cargo.location.type == "vehicle")
end

local function parcels()
  local gen = overhaul_career_logistics_generator
  local read = overhaul_career_logistics_parcelManager.getAllCargoCustomFilter
  if gen and gen.withoutGeneration then return gen.withoutGeneration(read, relevantCargo) end
  return read(relevantCargo)
end

local function tasks() return overhaul_career_logistics_vehicleTasks.getVehicleTasks() end
local function inventory() return overhaul_career_garage_inventory end
local function mapId() return getCurrentLevelIdentifier() or "unknown" end

local function containers(vehId)
  local data = vehId and core_vehicle_manager.getVehicleData(vehId)
  return data and data.vdata and data.vdata.cargoStorage
end

local function key(c) return tostring(c.partPath or "") .. ":" .. tostring(c.groupId or c.cid) end

local function live(cargo)
  return cargo.location and cargo.location.type == "vehicle" and not (cargo.data and cargo.data.delivered)
end

local function assigned(item, kind)
  local emp = overhaul_career_work_employment
  local fn = emp and (require("overhaul/lib/logistics/cargoSemantics").cargo(kind).parcel and emp.isAssignedCargo or emp.isAssignedVehicleOffer)
  return fn and fn(item) or false
end

local function boundCargoByVehicle(allCargo)
  local byId = {}
  for _, cargo in ipairs(allCargo) do
    local binding = cargo.logisticsBinding
    if live(cargo) and binding and binding.inventoryId then
      local list = byId[binding.inventoryId]
      if not list then
        list = {}
        byId[binding.inventoryId] = list
      end
      list[#list + 1] = cargo
    end
  end
  return byId
end

local function hasVehicleWorkIn(id, byId)
  if not id then return false end
  if byId[id] then return true end
  for _, task in ipairs(tasks()) do
    if not task.remove and not task.finished and not task.giveBack and task.offer.vehicle.inventoryId == id then return true end
  end
  for name, saved in pairs(maps) do
    if name ~= activeMap then
      for _, cargo in ipairs(saved.parcels or {}) do
        if cargo.logisticsBinding and cargo.logisticsBinding.inventoryId == id then return true end
      end
      for _, offer in ipairs(saved.offers or {}) do
        if offer.vehicle and offer.vehicle.inventoryId == id then return true end
      end
    end
  end
  return false
end

-- Map and freight identity ------------------------------------------------------------------------

local function facIdOf(loc)
  if type(loc) ~= "table" then return nil end
  if loc.facId then return loc.facId end
  local first = loc.destinations and loc.destinations[1]
  return first and first.facId or nil
end

local function destinationFacId(offer)
  if not offer then return nil end
  local facId = facIdOf(offer.destination) or facIdOf(offer.task and offer.task.destination)
  if facId then return facId end
  local saved = offer.logisticsTask
  for _, step in ipairs(saved and saved.tasks or {}) do
    facId = facIdOf(step.destination) or facIdOf(step.dropOff)
    if facId then return facId end
  end
end

local function homeForCargo(cargo)
  if cargo.homeMap and cargo.homeMap ~= "" then return cargo.homeMap end
  return M.ownerOfFacility(facIdOf(cargo.destination)) or M.ownerOfFacility(facIdOf(cargo.origin)) or mapId()
end

local function homeForOffer(offer)
  if offer.homeMap and offer.homeMap ~= "" then return offer.homeMap end
  return M.ownerOfFacility(destinationFacId(offer)) or mapId()
end

local function cargoKey(cargo)
  local binding = cargo.logisticsBinding
  if binding and binding.inventoryId then
    return table.concat({ "b", tostring(binding.inventoryId), tostring(binding.containerKey or binding.containerId),
      tostring(cargo.templateId or cargo.name), tostring(cargo.groupSeed or ""), tostring(cargo.slots), tostring(cargo.generatedAtTimestamp or "") }, ":")
  end
  return table.concat({ "c", tostring(cargo.templateId or cargo.name), tostring(cargo.slots),
    tostring(cargo.generatedAtTimestamp or cargo.id), tostring(facIdOf(cargo.destination)) }, ":")
end

local function offerKey(offer)
  local vehicle = offer.vehicle or {}
  return table.concat({ tostring(vehicle.inventoryId), tostring(offer.name), tostring(offer.startingOdometer), tostring(offer.homeMap) }, ":")
end

local function mergeUnique(existing, incoming, keyFn)
  local out, seen = {}, {}
  for _, item in ipairs(existing or {}) do
    local itemKey = keyFn(item)
    if not seen[itemKey] then
      seen[itemKey] = true
      out[#out + 1] = item
    end
  end
  for _, item in ipairs(incoming or {}) do
    local itemKey = keyFn(item)
    if not seen[itemKey] then
      seen[itemKey] = true
      out[#out + 1] = item
    end
  end
  return out
end

-- Map snapshots and shelving ----------------------------------------------------------------------

local function ensureMap(name, gameTime)
  local snap = maps[name]
  if not snap then
    snap = { parcels = {}, offers = {}, gameTime = gameTime }
    maps[name] = snap
  end
  snap.parcels = snap.parcels or {}
  snap.offers = snap.offers or {}
  return snap
end

-- Moves each saved entry to the map that owns its facility, so nothing stays under the wrong map.
local function rehomeMaps()
  local moves = {}
  for name, snap in pairs(maps) do
    if type(snap) == "table" then
      local keepParcels, keepOffers = {}, {}
      for _, cargo in ipairs(snap.parcels or {}) do
        local home = cargo.homeMap or M.ownerOfFacility(facIdOf(cargo.destination)) or M.ownerOfFacility(facIdOf(cargo.origin)) or name
        cargo.homeMap = home
        if home ~= name then
          moves[#moves + 1] = { home = home, kind = "parcels", item = cargo }
        else
          keepParcels[#keepParcels + 1] = cargo
        end
      end
      snap.parcels = keepParcels
      for _, offer in ipairs(snap.offers or {}) do
        local home = offer.homeMap or M.ownerOfFacility(destinationFacId(offer)) or name
        offer.homeMap = home
        if home ~= name then
          moves[#moves + 1] = { home = home, kind = "offers", item = offer }
        else
          keepOffers[#keepOffers + 1] = offer
        end
      end
      snap.offers = keepOffers
    end
  end
  for _, move in ipairs(moves) do
    local snap = ensureMap(move.home, 0)
    if move.kind == "parcels" then
      snap.parcels = mergeUnique(snap.parcels, { move.item }, cargoKey)
    else
      snap.offers = mergeUnique(snap.offers, { move.item }, offerKey)
    end
  end
end

-- Parks a live parcel under its home map and leaves a deleted location behind in this session.
local function shelveForeignParcels(current)
  local parcelMgr = overhaul_career_logistics_parcelManager
  for _, cargo in ipairs(parcels()) do
    if live(cargo) and not (cargo.data and cargo.data.brokerId) and not assigned(cargo, "parcel") then
      local home = homeForCargo(cargo)
      cargo.homeMap = home
      if home ~= current then
        local copy = deepcopy(cargo)
        copy.homeMap = home
        copy._transientMove = nil
        copy.location.vehId = -1
        copy.logisticsPending = true
        local snap = ensureMap(home, overhaul_career_logistics_general.time())
        snap.parcels = mergeUnique(snap.parcels, { copy }, cargoKey)
        if parcelMgr and parcelMgr.changeCargoLocation then
          parcelMgr.changeCargoLocation(cargo.id, { type = "deleted" })
        else
          cargo.location = { type = "deleted" }
        end
      end
    end
  end
end

-- Parks a live offer task under its home map and shelves the task here.
local function shelveForeignTasks(current)
  local vehicleTasks = overhaul_career_logistics_vehicleTasks
  for _, task in ipairs(tasks()) do
    if not task.remove and not task.finished and not task.giveBack and task.offer and not task.offer.brokerId and not assigned(task.offer, "offer") then
      local home = homeForOffer(task.offer)
      task.offer.homeMap = home
      if home ~= current then
        local offer = deepcopy(task.offer)
        offer.homeMap = home
        offer.vehicle.vehId = nil
        offer._spawning, offer.spawnWhenCommitingCargo = nil, nil
        offer.logisticsTask = M.captureTask(task)
        local snap = ensureMap(home, overhaul_career_logistics_general.time())
        snap.offers = mergeUnique(snap.offers, { offer }, offerKey)
        if vehicleTasks and vehicleTasks.shelveOffMapTask then
          vehicleTasks.shelveOffMapTask(task)
        else
          task.remove = true
        end
      end
    end
  end
end

local function shelveForeignLive(current)
  shelveForeignParcels(current)
  shelveForeignTasks(current)
end

-- Splits the snapshot into this map's entries and entries that belong to other maps.
local function splitByHome(snap, current)
  local hereParcels, hereOffers = {}, {}
  local extra = {}
  for _, cargo in ipairs(snap.parcels) do
    local home = cargo.homeMap or current
    if home == current then
      hereParcels[#hereParcels + 1] = cargo
    else
      extra[home] = extra[home] or { parcels = {}, offers = {} }
      extra[home].parcels[#extra[home].parcels + 1] = cargo
    end
  end
  for _, offer in ipairs(snap.offers) do
    local home = offer.homeMap or current
    if home == current then
      hereOffers[#hereOffers + 1] = offer
    else
      extra[home] = extra[home] or { parcels = {}, offers = {} }
      extra[home].offers[#extra[home].offers + 1] = offer
    end
  end
  return hereParcels, hereOffers, extra
end

-- Writes live work homed on another map into that map's entry, without leaving this session.
local function mergeExtraIntoOutput(out, extra, snap)
  for home, bucket in pairs(extra) do
    local existing = maps[home] or {}
    local dest = {}
    for k, v in pairs(existing) do dest[k] = v end
    dest.gameTime = existing.gameTime or snap.gameTime
    dest.parcels = mergeUnique(existing.parcels, bucket.parcels, cargoKey)
    dest.offers = mergeUnique(existing.offers, bucket.offers, offerKey)
    out[home] = dest
  end
end

-- Snapshot restoration ----------------------------------------------------------------------------

local function restoreParcels(savedParcels, gen)
  local groups = {}
  local cargoIds, restoredCargo = {}, {}
  for _, value in ipairs(savedParcels or {}) do
    if not value.homeMap or value.homeMap == activeMap then
      local cargo = deepcopy(value)
      cargo.id = gen.allocateCargoId()
      cargoIds[tostring(value.id)] = cargo.id
      restoredCargo[#restoredCargo + 1] = cargo
      groups[cargo.groupId] = groups[cargo.groupId] or gen.allocateCargoGroupId()
      cargo.groupId = groups[cargo.groupId]
      cargo.location.vehId, cargo.logisticsPending = -1, true
      overhaul_career_logistics_parcelManager.addCargo(cargo)
    end
  end
  return cargoIds, restoredCargo
end

local function restoreOffers(offers, gen)
  local offerIds = {}
  for _, value in ipairs(offers or {}) do
    if not value.homeMap or value.homeMap == activeMap then
      local offer = deepcopy(value)
      offer.id, offer.spawned = gen.allocateCargoId(), true
      offerIds[tostring(value.id)] = offer.id
      offer.vehicle.vehId = -1
      overhaul_career_logistics_vehicleOfferManager.addOffer(offer)
      overhaul_career_logistics_vehicleTasks.addVehicleTask(-1, offer)
    end
  end
  return offerIds
end

-- Material fragments can still refer to their original source cargo after that source itself has been delivered. Give those fragments one new source identity so the owner-op proof and subsequent split deliveries agree.
local function remapOwnerOpSources(restoredCargo, cargoIds)
  local sourceIds = {}
  for key, id in pairs(cargoIds) do sourceIds[key] = id end
  for _, cargo in ipairs(restoredCargo) do
    local sourceId = cargo.data and cargo.data.ownerOpSourceCargoId
    if sourceId ~= nil then
      local key = tostring(sourceId)
      sourceIds[key] = sourceIds[key] or cargo.id
    end
  end
  for _, cargo in ipairs(restoredCargo) do
    local sourceId = cargo.data and cargo.data.ownerOpSourceCargoId
    if sourceId ~= nil then
      cargo.data.ownerOpSourceCargoId = sourceIds[tostring(sourceId)]
    end
  end
  return sourceIds
end

local function restoreParkedContracts(snapshot)
  if not snapshot.parkedContracts then return end
  local materials = overhaul_career_logistics_materialContractManager
  if materials and materials.restoreParkedContracts then
    materials.restoreParkedContracts(snapshot.parkedContracts)
  end
  snapshot.parkedContracts = nil
end

local function restoreSnapshot(snapshot)
  if not snapshot then return end
  local gen = overhaul_career_logistics_generator
  local cargoIds, restoredCargo = restoreParcels(snapshot.parcels, gen)
  local offerIds = restoreOffers(snapshot.offers, gen)
  local sourceIds = remapOwnerOpSources(restoredCargo, cargoIds)
  local ownerOp = overhaul_career_logistics_ownerOpContracts
  if ownerOp and ownerOp.remapRestoredHubProofIds then
    ownerOp.remapRestoredHubProofIds(cargoIds, offerIds, sourceIds)
  end
  restoreParkedContracts(snapshot)
  if #(snapshot.parcels or {}) > 0 or #(snapshot.offers or {}) > 0 then
    overhaul_career_logistics_general.startDeliveryMode()
  end
end

-- Vehicle reconcile -------------------------------------------------------------------------------

-- Clears the in-use flag of vehicles that no longer carry logistics work.
local function releaseIdleVehicles(byId)
  if not inventory().getVehicles then return end
  for id, info in pairs(inventory().getVehicles()) do
    if info.logisticsInUse and not hasVehicleWorkIn(id, byId) then info.logisticsInUse = nil end
  end
end

-- Rebinds each vehicle's loads to the vehicle now carrying them; returns whether anything changed.
local function rebindVehicleLoads(byId)
  local changed = false
  for id, loads in pairs(byId) do
    local vehId = inventory().getVehicleIdFromInventoryId(id)
    local obj = vehId and getObjectByID(vehId)
    local needsRebind, companyLoad = false, true
    for _, cargo in ipairs(loads) do
      if cargo.logisticsPending or cargo.location.vehId ~= vehId then needsRebind = true end
      if not assigned(cargo, "parcel") then companyLoad = false end
    end
    -- Employment owns live loading; still validate its containers after a respawn.
    local matches = obj and (companyLoad and not needsRebind and {} or M.matchLoads(id, containers(vehId), loads))
    if matches then
      for _, entry in ipairs(matches) do
        local cargo, c = entry.cargo, entry.container
        if cargo.location.vehId ~= vehId or cargo.location.containerId ~= c.cid or cargo.logisticsPending then
          cargo.location.vehId, cargo.location.containerId = vehId, c.cid
          cargo.logisticsPending = nil
          changed = true
        end
      end
    else
      for _, cargo in ipairs(loads) do
        if not cargo.logisticsPending then changed = true end
        cargo.location.vehId, cargo.logisticsPending = -1, true
      end
    end
  end
  return changed
end

-- Points each live task at its vehicle, or marks it pending while the vehicle is absent.
local function reconcileTasks()
  local changed = false
  for _, task in ipairs(tasks()) do
    if not task.remove and not task.finished then
      local id = task.offer.vehicle.inventoryId
      local vehId = id and inventory().getVehicleIdFromInventoryId(id)
      local ready = vehId and getObjectByID(vehId)
      if ready and (task.vehId ~= vehId or task.logisticsPending) then
        task.vehId, task.offer.vehicle.vehId, task.logisticsPending = vehId, vehId, nil
        changed = true
      elseif not ready and id then
        if not task.logisticsPending then changed = true end
        task.vehId, task.offer.vehicle.vehId, task.logisticsPending = -1, -1, true
      end
    end
  end
  return changed
end

-- Cargo binding -----------------------------------------------------------------------------------

function M.captureCargo(cargo)
  if not live(cargo) then
    cargo.logisticsBinding = nil
    return
  end
  if cargo.logisticsBinding then
    local info = inventory().getVehicle(cargo.logisticsBinding.inventoryId)
    if info then info.logisticsInUse = true end
    return
  end
  local loc = cargo.location
  local id = inventory().getInventoryIdFromVehicleId(loc.vehId)
  if not id then return end
  for _, c in pairs(containers(loc.vehId) or {}) do
    if c.cid == loc.containerId then
      cargo.logisticsBinding = { inventoryId = id, containerKey = key(c), containerId = c.cid }
      local info = inventory().getVehicle(id)
      if info then info.logisticsInUse = true end
      return
    end
  end
end

function M.capture(allCargo)
  for _, cargo in ipairs(allCargo or parcels()) do M.captureCargo(cargo) end
end

-- Called before removing/replacing an object, while both mappings still exist.
function M.suspendVehicle(id, vehId)
  local allCargo = parcels()
  M.capture(allCargo)
  for _, cargo in ipairs(allCargo) do
    if live(cargo) and cargo.location.vehId == vehId then
      cargo.logisticsBinding = cargo.logisticsBinding or { inventoryId = id, containerId = cargo.location.containerId }
      cargo.location.vehId = -1
      cargo.logisticsPending = true
    end
  end
  for _, task in ipairs(tasks()) do
    if task.vehId == vehId then
      task.offer.vehicle.inventoryId = id
      task.vehId = -1
      task.offer.vehicle.vehId = -1
      task.logisticsPending = true
    end
  end
end

function M.hasVehicleWork(id)
  if not id then return false end
  local allCargo = parcels()
  M.capture(allCargo)
  return hasVehicleWorkIn(id, boundCargoByVehicle(allCargo))
end

function M.allowRemoval(id, quiet)
  if not M.hasVehicleWork(id) then return true end
  if not quiet then
    ui_message("Unload or transfer the cargo, or explicitly abandon its delivery, before storing, selling, or returning this vehicle.", 8, "warning")
  end
  return false
end

-- Match by JBeam part/group identity, never by a coincidentally reused numeric CID.
function M.matchLoads(id, storage, allCargo)
  local used, matches = {}, {}
  for _, cargo in ipairs(allCargo or parcels()) do
    local binding = cargo.logisticsBinding
    if live(cargo) and binding and binding.inventoryId == id then
      local found
      for _, c in pairs(storage or {}) do
        if (binding.containerKey and binding.containerKey == key(c))
          or (not binding.containerKey and c.cid == binding.containerId) then
          found = c
          break
        end
      end
      local accepts = false
      for _, kind in ipairs(found and found.cargoTypes or {}) do
        if kind == cargo.type then accepts = true end
      end
      if not found or not accepts then return nil, "The loaded cargo container would be removed or become incompatible." end
      used[found.cid] = (used[found.cid] or 0) + (tonumber(cargo.slots) or 0)
      if used[found.cid] > (tonumber(found.capacity) or 0) then return nil, "The new container is too small for the current load." end
      matches[#matches + 1] = { cargo = cargo, container = found }
    end
  end
  return matches
end

function M.validateVehicle(id)
  local vehId = inventory().getVehicleIdFromInventoryId(id)
  local matches, reason = M.matchLoads(id, containers(vehId))
  if not matches then
    ui_message(reason .. " Unload or transfer the cargo first.", 8, "warning")
    return false
  end
  return true
end

-- Vehicle reconcile -------------------------------------------------------------------------------

function M.reconcile()
  if inventory().isVehicleRestorePending and inventory().isVehicleRestorePending() then return end
  local allCargo = overhaul_career_logistics_parcelManager.getCargoForPersistence()
  M.capture(allCargo)
  local byId = boundCargoByVehicle(allCargo)
  releaseIdleVehicles(byId)
  local loadsChanged = rebindVehicleLoads(byId)
  local tasksChanged = reconcileTasks()
  if loadsChanged or tasksChanged then
    overhaul_career_logistics_general.requestUpdateContainerWeights()
    overhaul_career_logistics_tasklist.sendCargoToTasklist()
    overhaul_career_logistics_general.requestDeliveryPoiRefresh(true)
    guihooks.trigger("LogisticsVehiclesRestored")
  end
end

function M.captureTask(task)
  -- Do not persist transient completion callbacks/flags. Reward settlement is synchronous in progress; the next snapshot only contains outstanding tasks.
  return { activeTaskIndex = task.activeTaskIndex, startedTimestamp = task.startedTimestamp,
    tasks = deepcopy(task.tasks), haulAcquired = task.haulAcquired }
end

-- Map ownership -----------------------------------------------------------------------------------

function M.ownerOfFacility(facId)
  if not facId or facId == "" then return nil end
  if facilityOwnerCache[facId] ~= nil then
    return facilityOwnerCache[facId] ~= false and facilityOwnerCache[facId] or nil
  end
  local names, seen = {}, {}
  local function add(name)
    if name and name ~= "" and not seen[name] then
      seen[name] = true
      names[#names + 1] = name
    end
  end
  add(mapId())
  local compatible = overhaul_world_maps.getCompatibleMaps()
  for name in pairs(compatible or {}) do add(name) end
  for _, name in ipairs(names) do
    local list = overhaul_world_facilities.getFacilitiesByType("deliveryProvider", name) or {}
    for _, fac in ipairs(list) do
      if fac.id == facId then
        facilityOwnerCache[facId] = name
        return name
      end
    end
  end
  facilityOwnerCache[facId] = false
  return nil
end

function M.belongsHere(item)
  if not item then return true end
  local current = mapId()
  if item.homeMap and item.homeMap ~= "" and item.homeMap ~= current then return false end
  local facId = item.sourceFacId or item.destinationFacId or facIdOf(item.destination) or destinationFacId(item)
  local owner = facId and M.ownerOfFacility(facId)
  if owner and owner ~= current then return false end
  return true
end

-- Snapshot and save -------------------------------------------------------------------------------

function M.snapshot()
  local allCargo = parcels()
  M.capture(allCargo)
  local snapshot = { parcels = {}, offers = {}, gameTime = overhaul_career_logistics_general.time() }
  local materials, ownerOp = overhaul_career_logistics_materialContractManager, overhaul_career_logistics_ownerOpContracts
  snapshot.materialContracts = materials and materials.serialize()
  snapshot.ownerOpContracts = ownerOp and ownerOp.serialize()
  for _, cargo in ipairs(allCargo) do
    -- Broker's ledger owns its job IDs and restore flow; never save the same freight through both ledgers. Runtime bindings still protect all cargo.
    if live(cargo) and not (cargo.data and cargo.data.brokerId) and not assigned(cargo, "parcel") then
      local copy = deepcopy(cargo)
      copy._transientMove = nil
      copy.homeMap = homeForCargo(cargo)
      cargo.homeMap = copy.homeMap
      copy.location.vehId = -1
      copy.logisticsPending = true
      snapshot.parcels[#snapshot.parcels + 1] = copy
    end
  end
  for _, task in ipairs(tasks()) do
    if not task.remove and not task.finished and not task.giveBack and not task.offer.brokerId and not assigned(task.offer, "offer") then
      local offer = deepcopy(task.offer)
      offer.homeMap = homeForOffer(offer)
      task.offer.homeMap = offer.homeMap
      offer.vehicle.vehId = nil
      offer._spawning, offer.spawnWhenCommitingCargo = nil, nil
      offer.logisticsTask = M.captureTask(task)
      snapshot.offers[#snapshot.offers + 1] = offer
    end
  end
  return snapshot
end

function M.serialize(forSave)
  local current = mapId()
  activeMap = current
  local snap = M.snapshot()
  local hereParcels, hereOffers, extra = splitByHome(snap, current)
  local prev = maps[current]
  maps[current] = {
    parcels = hereParcels,
    offers = hereOffers,
    gameTime = snap.gameTime,
    materialContracts = snap.materialContracts,
    ownerOpContracts = snap.ownerOpContracts,
    parkedContracts = prev and prev.parkedContracts or nil,
  }
  local out = {}
  for name, saved in pairs(maps) do out[name] = saved end
  mergeExtraIntoOutput(out, extra, snap)
  return { version = 1, maps = forSave and out or deepcopy(out) }
end

-- Map travel: park live work that belongs to another map before the travel save.
function M.shelveForeign()
  local current = mapId()
  activeMap = current
  shelveForeignLive(current)
  local tasklist = overhaul_career_logistics_tasklist
  if tasklist and tasklist.sendCargoToTasklist then tasklist.sendCargoToTasklist() end
end

function M.parkMaterialContracts(list)
  for _, contract in ipairs(list or {}) do
    local home = contract.homeMap or M.ownerOfFacility(contract.sourceFacId)
    if home and home ~= mapId() then
      local snap = ensureMap(home, 0)
      snap.parkedContracts = snap.parkedContracts or {}
      snap.parkedContracts[contract.id] = contract
    end
  end
end

function M.load(saved)
  maps = deepcopy(saved and saved.maps or {})
  activeMap = mapId()
  rehomeMaps()
end

function M.restore()
  restoreSnapshot(maps[activeMap])
  shelveForeignLive(activeMap)
end

function M.setup(saved)
  M.load(saved)
  M.restore()
end

function M.reset()
  maps, activeMap = {}, nil
end

function M.savedMap(saved)
  return saved and saved.maps and saved.maps[mapId()]
end

-- Pending vehicles --------------------------------------------------------------------------------

function M.getPending()
  local out, seen = {}, {}
  local function add(id, name)
    if not id or seen[id] then return end
    seen[id] = true
    local info = inventory().getVehicle(id)
    out[#out + 1] = { inventoryId = id, name = info and info.niceName or name or "Delivery vehicle" }
  end
  for _, cargo in ipairs(parcels()) do
    if live(cargo) and cargo.logisticsPending and cargo.logisticsBinding then
      add(cargo.logisticsBinding.inventoryId, cargo.name)
    end
  end
  for _, task in ipairs(tasks()) do
    if not task.remove and task.logisticsPending then add(task.offer.vehicle.inventoryId, task.offer.name) end
  end
  return out
end

function M.retry(id)
  for _, pending in ipairs(M.getPending()) do
    if tostring(pending.inventoryId) == tostring(id) then
      local info = inventory().getVehicle(pending.inventoryId)
      if not info then
        ui_message("The saved vehicle is unavailable. Restore its vehicle content and retry; the job is still saved.", 8, "warning")
        return false
      end
      local vehId = inventory().getVehicleIdFromInventoryId(pending.inventoryId)
      if not (vehId and getObjectByID(vehId)) then inventory().spawnVehicle(pending.inventoryId) end
      M.reconcile()
      return true
    end
  end
  return false
end

return M
