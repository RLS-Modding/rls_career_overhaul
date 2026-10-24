-- Owns independent freight offers, reservations, dispatch and broker state. Native logistics owners keep cargo and payment; broker/ holds kind handlers, arrival monitoring and pure rules.
-- Read shared helpers, kind services, restore helpers, updates/hooks, then save and freight APIs and activity.

local M = {}
local kinds = require("overhaul/career/logistics/broker/kinds").new()
local access = require("overhaul/career/logistics/broker/access")
local presence = require("overhaul/career/logistics/broker/presence")
local loanerKind = require("overhaul/career/logistics/broker/kinds/loaner")
local capabilities = require("overhaul/career/logistics/loanerCapabilities")
local nativeCargo = require("overhaul/lib/logistics/cargoSemantics")
local rules = require("overhaul/career/logistics/broker/brokerRules")
local cargoBinding = require("overhaul/lib/logistics/brokerCargoBinding")
local viewCache = require("overhaul/career/logistics/broker/viewCache")
local rentalRoute = require("overhaul/lib/activity/routeLease").new()
local freightRoute = require("overhaul/lib/activity/routeLease").new()

-- Config ------------------------------------------------------------------------------------------
-- Vehicle callbacks have no timeout and may never fire after deletion.
local busyToken, BUSY_TIMEOUT_S = 0, 60
local FINISHED_JOB_KEEP = 50

-- State -------------------------------------------------------------------------------------------
local disposeNativeCargo
local pendingRestore = { cargo = {}, tasks = {} }
local state =
  { version = 1, jobs = {}, plans = {}, stops = {}, rentals = {}, depots = {}, preferences = {}, nextId = 1 }
local offers, natives, busy = {}, {}, false
local collectionFailed
local startingJobs = {}
-- What cargo kind handlers may use. Admission, busy and refresh guards stay in this module.
local brokerServices = {}
local openContext
local routeCache, routeCacheMap, routeCacheSize = {}, nil, 0
local offerCache, jobCache = viewCache.new(), viewCache.new()
local offerFacilities
local restoreTimer = 0
local presenceWatcher = presence.newWatcher()
local rentalRouteId
local freightRouteJobs, freightRouteIsPlan = {}, false

-- Accepted freight persistence -------------------------------------------------------------------

local persistence = {}

local function inventoryId(vehId)
  local inventory = overhaul_career_garage_inventory
  return inventory and inventory.getInventoryIdFromVehicleId(vehId)
end

-- Terminal work must never be resurrected, including work saved on another map.
local function isTerminal(jobs, brokerId)
  local job = jobs[brokerId]
  return job and (job.status == "complete" or job.status == "cancelled")
end

local function pruneTerminalJobs(pending, jobs)
  for key, saved in pairs((pending or {}).cargo or {}) do
    if isTerminal(jobs, saved.cargo.data.brokerId) then pending.cargo[key] = nil end
  end
  for key, saved in pairs((pending or {}).tasks or {}) do
    if isTerminal(jobs, saved.offer.brokerId) then pending.tasks[key] = nil end
  end
end

function persistence.canPersistCargo(cargo)
  return cargoBinding.canPersistCargo(cargo, inventoryId)
end

function persistence.capture(pending)
  local result = deepcopy(pending or { cargo = {}, tasks = {} })
  result.cargo = result.cargo or {}
  result.tasks = result.tasks or {}
  local parcelManager = overhaul_career_logistics_parcelManager
  for _, cargo in ipairs(parcelManager and parcelManager.getAllCargoInVehicles() or {}) do
    if persistence.canPersistCargo(cargo) and not cargo._transientMove then
      cargo.data.brokerCargoKey = cargo.data.brokerCargoKey or (cargo.data.brokerId .. ":" .. cargo.id)
      result.cargo[cargo.data.brokerCargoKey] = { cargo = deepcopy(cargo),
        inventoryId = (cargo.logisticsBinding and cargo.logisticsBinding.inventoryId) or inventoryId(cargo.location.vehId) }
    end
  end
  local manager = overhaul_career_logistics_vehicleTasks
  for _, task in ipairs(manager and manager.getVehicleTasks() or {}) do
    if task.offer.brokerId and not task.remove and not task.finished and not task.giveBack then
      local invId = task.offer.vehicle.inventoryId or inventoryId(task.vehId)
      if invId then
        local key = task.offer.brokerId .. ":" .. tostring((task.offer.data or {}).finkVehicleKey or "trailer")
        result.tasks[key] = { inventoryId = invId, offer = deepcopy(task.offer),
          tasks = deepcopy(task.tasks), activeTaskIndex = task.activeTaskIndex, startedTimestamp = task.startedTimestamp }
      end
    end
  end
  return result
end

function persistence.prepare(pending, jobs, onRestoredOffer)
  pruneTerminalJobs(pending, jobs)
  for _, saved in pairs((pending or {}).tasks or {}) do
    local offer = saved.offer
    local job = jobs[offer.brokerId]
    if job and job.map == getCurrentLevelIdentifier() then
      offer.id = overhaul_career_logistics_generator.allocateCargoId()
      offer.spawned = true
      offer.brokerRestoring = true
      offer.vehicle.vehId = nil
      overhaul_career_logistics_vehicleOfferManager.addOffer(offer)
      onRestoredOffer(job, offer)
    end
  end
end

function persistence.restore(pending, jobs)
  pruneTerminalJobs(pending, jobs)
  local inv, pm = overhaul_career_garage_inventory, overhaul_career_logistics_parcelManager
  if not inv or not pm then return end
  local changed = false
  for key, saved in pairs(pending.cargo or {}) do
    local job = jobs[saved.cargo.data.brokerId]
    local vehId = inv.getVehicleIdFromInventoryId(saved.inventoryId)
    if job and job.map == getCurrentLevelIdentifier() and vehId and be:getObjectByID(vehId) then
      local filter = function(c) return c.data and c.data.brokerCargoKey == key end
      local gen = overhaul_career_logistics_generator
      local exists = gen.withoutGeneration and gen.withoutGeneration(pm.getAllCargoCustomFilter, filter)
        or pm.getAllCargoCustomFilter(filter)
      if not exists[1] then
        local cargo = deepcopy(saved.cargo)
        cargo.id = overhaul_career_logistics_generator.allocateCargoId()
        cargo.location.vehId = vehId
        cargo._transientMove = nil
        pm.addCargo(cargo)
      end
      pending.cargo[key] = nil
      changed = true
    end
  end
  for key, saved in pairs(pending.tasks or {}) do
    local job = jobs[saved.offer.brokerId]
    local vehId = inv.getVehicleIdFromInventoryId(saved.inventoryId)
    if job and job.map == getCurrentLevelIdentifier() and vehId and be:getObjectByID(vehId) then
      saved.offer.vehicle.vehId = vehId
      overhaul_career_logistics_vehicleTasks.restoreBrokerTask(saved, vehId)
      saved.offer.brokerRestoring = nil
      pending.tasks[key] = nil
      changed = true
    end
  end
  if changed then
    local general = overhaul_career_logistics_general
    if not general.isDeliveryModeActive() then general.startDeliveryMode() end
    general.requestUpdateContainerWeights()
    overhaul_career_logistics_tasklist.sendCargoToTasklist()
  end
end

-- Shared helpers ----------------------------------------------------------------------------------
-- The stock route module is loaded on first use.
local function newRoute() return require("gameplay/route/route")() end

local function setBusy()
  if busy then return end
  busy = true
  busyToken = busyToken + 1
  local token = busyToken
  core_jobsystem.create(function(job)
    job.sleep(BUSY_TIMEOUT_S)
    if busy and token == busyToken then
      log("W", "broker", "Collection request timed out; releasing the lock")
      if collectionFailed then
        collectionFailed("Collection timed out. Check your loads before retrying.")
      else
        busy = false
      end
    end
  end)
end

-- Native callbacks may arrive after timeout, setup or another collection.
-- Only the current collection may mutate its work or release its lock.
local function collectionCallback(callback)
  local token = busyToken
  return function(...)
    if not busy or token ~= busyToken then return end
    local ok, message = pcall(callback, ...)
    if ok then return end
    log("E", "broker", tostring(message))
    if token ~= busyToken then return end
    if collectionFailed then
      collectionFailed("Collection could not finish. Check your loads before retrying.")
    else
      busy = false
    end
  end
end

local function gen() return overhaul_career_logistics_generator end
local function general() return overhaul_career_logistics_general end
local function parcels() return overhaul_career_logistics_parcelManager end
local function vehicles() return overhaul_career_logistics_vehicleOfferManager end
local function materials() return overhaul_career_logistics_materialContractManager end
local function ownerOp() return overhaul_career_logistics_ownerOpContracts end
local function mapId() return getCurrentLevelIdentifier() or "" end
local function now() return general().time() end
local function text(v, context)
  if context then return core_locales.contextTranslate(v, context) end
  return _tr(v or "")
end
local function employed()
  local e = overhaul_career_work_employment
  return e and e.isEmployed and e.isEmployed() or false
end
-- Listings show pay with the Logistics level bonus that drop-off adds to parcel and vehicle pay.
local function levelBonus()
  local p = overhaul_career_logistics_progress
  if not (p and p.getLogisticsMoneyBonus) then return 0 end
  local ok, b = pcall(p.getLogisticsMoneyBonus)
  return ok and tonumber(b) or 0
end

local function withLevelPay(row, bonus)
  local applies = kinds.forKind(row.kind).levelBonus
  row.basePay = row.pay
  row.levelBonus = applies and bonus or 0
  row.estimatedPay = math.floor((tonumber(row.pay) or 0) * (1 + row.levelBonus) + 0.5)
  return row
end
-- Name of the current employer, for the "on the clock" screen in the phone app.
local function employerName()
  local e = overhaul_career_work_employment
  if not (e and e.isEmployed and e.isEmployed() and e.getUiState) then return nil end
  local ok, st = pcall(e.getUiState)
  return ok and type(st) == "table" and st.employerName or nil
end

local function nextId(prefix)
  local id = prefix .. ":" .. tostring(state.nextId)
  state.nextId = state.nextId + 1
  return id
end

local function locationName(loc)
  local f = loc and gen().getFacilityById(loc.facId)
  return f and text(f.name) or (loc and loc.facId) or "Destination"
end

local function position(loc)
  if not loc then return nil end
  local ok, pos = pcall(gen().getLocationCoordinates, loc)
  return ok and pos or nil
end

local function playerPosition()
  local v = getPlayerVehicle(0)
  return v and v:getPosition() or core_camera.getPosition()
end

local function near(loc)
  if not loc then return false end
  local fac = loc and gen().getFacilityById(loc.facId)
  return presence.measure(presence.area({origin = loc}, fac), playerPosition(), position).here
end

local function pickupPresence(row, player, distances)
  if row.map and row.map ~= mapId() then return {here = false} end
  local area = kinds.forKind(row.kind).pickupArea(brokerServices, row)
  return presence.measure(area, player or playerPosition(), position, distances)
end

local function atPickup(row) return pickupPresence(row).here end

local function branchInfo(branch)
  local skills = overhaul_career_progression_skills
  return skills and skills.getBranchSimpleInfo and skills.getBranchSimpleInfo(branch) or {}
end

local function rowAccess(row, native)
  return access.apply(row, access.evaluate(kinds.forKind(row.kind).requirements(brokerServices, row, native), branchInfo, text))
end

local function distance(a, b)
  if not a or not b then return nil end
  if routeCacheMap ~= mapId() or routeCacheSize >= 8192 then
    routeCache = {}
    routeCacheMap = mapId()
    routeCacheSize = 0
  end
  -- Planned stop summaries keep metre precision; market rows never query roads.
  local key = string.format(
    "%d:%d:%d:%.0f:%.0f:%.0f",
    math.floor(a.x),
    math.floor(a.y),
    math.floor(a.z),
    b.x,
    b.y,
    b.z
  )
  if routeCache[key] then return routeCache[key] end
  local route = newRoute()
  route:setupPath(a, b)
  local value = route.path and route.path[1] and route.path[1].distToTarget
  if value then
    routeCache[key] = value
    routeCacheSize = routeCacheSize + 1
  end
  return value
end

local function destination(loc) return loc and deepcopy(loc) end
local function facilityPreview(loc)
  local g = gen()
  local fac = loc and loc.facId and g and g.getFacilityById and g.getFacilityById(loc.facId)
  return fac and fac.preview or nil
end

local function addOffer(id, kind, native, row)
  row.offerExpiresAt = native.offerExpiresAt
  row.modifiers = deepcopy(native.modifiers or {})
  row.id = id
  row.kind = kind
  row.map = mapId()
  row.from = locationName(row.origin)
  row.to = locationName(row.destination)
  row.originPreview = facilityPreview(row.origin)
  row.destinationPreview = facilityPreview(row.destination)
  local origin, target = position(row.origin), position(row.destination)
  row.haulDistance = row.haulDistance or (origin and target and (origin - target):length())
  row.pay = tonumber(row.pay) or 0
  row.signature = table.concat({
    row.map,
    kind,
    tostring(row.nativeId),
    row.from,
    row.to,
    tostring(row.title),
    tostring(row.quantity),
    tostring(row.pay),
    tostring(native.generatedAtTimestamp or ""),
  }, "|")
  return row
end

local function syncJobs()
  local changed = false
  for _, job in pairs(state.jobs) do
    if job.map == mapId() and job.status ~= "complete" and job.status ~= "cancelled" then
      local status = job.status
      kinds.forKind(job.kind).sync(brokerServices, job)
      if status ~= job.status then changed = true end
    end
  end
  if changed then presenceWatcher.invalidate() end
end

local function booked(kind, id)
  for _, j in pairs(state.jobs) do
    if
      j.map == mapId()
      and j.kind == kind
      and j.nativeId == id
      and j.status ~= "cancelled"
      and j.status ~= "complete"
    then
      return true
    end
  end
  return false
end

local function refreshPois()
  presenceWatcher.invalidate()
  general().requestDeliveryPoiRefresh(true)
end

local function collect(callback, run)
  setBusy()
  local token, completed = busyToken, false
  local function finish(ok, message)
    if completed or token ~= busyToken then return end
    completed = true
    busy, collectionFailed = false, nil
    local updated, reason = pcall(function() syncJobs(); refreshPois() end)
    if not updated then
      log("E", "broker", tostring(reason))
      ok, message = false, "Collection could not finish. Check your loads before retrying."
    end
    if callback then callback(ok, message) end
  end
  collectionFailed = function(message) finish(false, message) end
  local called, ok, message = pcall(run, finish)
  if not called then
    log("E", "broker", tostring(ok))
    message = "Collection could not finish. Check your loads before retrying."
    finish(false, message)
    return false, message
  end
  if ok == false then finish(false, message) end
  return ok, message
end

-- Kind services -----------------------------------------------------------------------------------
brokerServices.mapId = mapId
brokerServices.now = now
brokerServices.text = text
brokerServices.destination = destination
brokerServices.addOffer = function(id, kind, native, row)
  offers[id], natives[id] = addOffer(id, kind, native, row), native
end
-- Board reads must not finish a background generation batch on the UI frame.
-- Keep suppression around each native query, never across a coroutine yield.
function brokerServices.readCurrentOffers(fn, ...)
  if gen().withoutGeneration then return gen().withoutGeneration(fn, ...) end
  return fn(...)
end
-- Kind handlers keep admission live, but only build a row when its native data
-- or presentation dependencies change. Prices still come from native owners.
local function cachedOffer(targetOffers, targetNatives, id, kind, native, dependencies, build)
  local row = offerCache.get(id, dependencies, native.generatedAtTimestamp, function()
    return addOffer(id, kind, native, build())
  end)
  rowAccess(row, native)
  row.offerExpiresAt = native.offerExpiresAt
  row.modifiers = deepcopy(native.modifiers or {})
  row.timed, row.fragile = false, false
  for _, modifier in ipairs(row.modifiers) do
    if modifier.type == "timed" then row.timed = true end
    if modifier.type == "fragile" then row.fragile = true end
  end
  targetOffers[id], targetNatives[id] = row, native
end
function brokerServices.cachedOffer(...) return cachedOffer(offers, natives, ...) end
brokerServices.booked = booked
brokerServices.syncJobs = syncJobs
brokerServices.collectionCallback = collectionCallback
-- Feature services. Kind handlers reach owner features only through these accessors.
brokerServices.gen = gen
brokerServices.general = general
brokerServices.parcels = parcels
brokerServices.materials = materials
brokerServices.vehicles = vehicles
brokerServices.ownerOp = ownerOp
function brokerServices.flagRequirement(flag)
  local flags = overhaul_career_progression_unlockFlags
  return {flag = flag, unlocked = flags.getFlag(flag) == true,
    definition = flags.getFlagDefinition and flags.getFlagDefinition(flag)}
end
function brokerServices.employment() return overhaul_career_work_employment end
function brokerServices.cargoScreen() return overhaul_career_logistics_cargoScreen end
function brokerServices.tasklist() return overhaul_career_logistics_tasklist end
function brokerServices.vehicleTasks() return overhaul_career_logistics_vehicleTasks end
function brokerServices.parcelMods() return overhaul_career_logistics_parcelMods end
function brokerServices.playerAttributes() return overhaul_career_economy_playerAttributes end

local discardPicker = require("overhaul/career/logistics/broker/discard").new(brokerServices, function(job)
  return kinds.forKind(job.kind)
end)
-- A saved parcel for this job is waiting to be restored onto its vehicle.
function brokerServices.awaitingCargoRestore(jobId)
  for _, saved in pairs(pendingRestore.cargo or {}) do
    if saved.cargo and saved.cargo.data and saved.cargo.data.brokerId == jobId then return true end
  end
  return false
end
-- Busy until finish; checks the pickup and container before load(target) runs.
function brokerServices.withContainer(job, containerKey, finish, load, allowDefault)
  general().getNearbyVehicleCargoContainers(collectionCallback(function(containers)
    if not atPickup(job) or employed() then
      finish(false, "Return to the pickup to load.")
      return
    end
    local target
    for _, con in ipairs(containers or {}) do
      if tostring(con.vehId) .. ":" .. tostring(con.containerId) == containerKey
        or (allowDefault and not containerKey and kinds.forKind(job.kind).containerFits(job, con)) then
        target = con
        break
      end
    end
    if not target then
      finish(false, "Select a nearby cargo container, then retry.")
      return
    end
    load(target)
  end))
  return true, "Checking cargo capacity…"
end
-- Fines for the vehicle tasks a job holds (trailer and car-haul loads).
function brokerServices.vehicleTaskFine(id)
  local fine = 0
  for _, task in ipairs(overhaul_career_logistics_vehicleTasks.getVehicleTasks()) do
    if task.offer.brokerId == id and not task.remove then
      fine = fine - (overhaul_career_logistics_vehicleTasks.getFineForAbandon(task).money or 0)
    end
  end
  return fine
end

-- Helpers for the public API ----------------------------------------------------------------------
local function cancelReservationForTravel(id)
  syncJobs()
  local job = state.jobs[id]
  if not job or job.status ~= "reserved" then return false, "Only uncollected reservations can be cancelled." end
  local ok, msg = kinds.forKind(job.kind).release(brokerServices, job)
  if not ok then return false, msg end
  state.jobs[id] = nil
  for i = #state.stops, 1, -1 do
    if state.stops[i].jobId == id then table.remove(state.stops, i) end
  end
  refreshPois()
  return true
end

local function stopPoints()
  local pts = {}
  for _, stop in ipairs(state.stops) do
    local pos = position(stop.location)
    if pos then pts[#pts + 1] = { stop = stop, pos = pos } end
  end
  return pts
end
-- polyline along the roads between two points, for the phone's route map
local function routePolyline(a, b)
  local route = newRoute()
  route:setupPath(a, b)
  local path = {}
  for _, p in ipairs(route.path or {}) do
    path[#path + 1] = { p.pos.x, p.pos.y }
  end
  local total = route.path and route.path[1] and route.path[1].distToTarget or nil
  if #path < 2 then path = { { a.x, a.y }, { b.x, b.y } } end
  return path, total
end
-- Runs the single-job path for each job, so fines and cleanup stay the same for groups.
local function eachJob(ids, fn)
  local done, reason = 0, nil
  for _, id in ipairs(type(ids) == "table" and ids or {}) do
    local ok, msg = fn(id)
    if ok then
      done = done + 1
    else
      reason = reason or msg
    end
  end
  return done, reason
end

local function inventoryRental(id)
  for invId, v in pairs(overhaul_career_garage_inventory.getVehicles() or {}) do
    if v.brokerRentalId == id then return invId, v end
  end
end

local function remapFreightRouteJob(fromId, toId)
  if fromId == toId or not freightRouteJobs[fromId] then return end
  freightRouteJobs[fromId], freightRouteJobs[toId] = nil, true
end

local function clearFreightRoute(id)
  if id and not freightRouteJobs[id] then return end
  local current, rebuild = freightRoute.isCurrent(), id and freightRouteIsPlan
  freightRoute.clear()
  freightRouteJobs, freightRouteIsPlan = {}, false
  if not current then return end
  general().setDeliveryNavFocus(nil)
  if rebuild then M.showRoute() end
end

local function clearRentalRoute(id)
  if id and rentalRouteId and id ~= rentalRouteId then return end
  local current = rentalRoute.isCurrent()
  rentalRoute.clear()
  rentalRouteId = nil
  if current then general().setDeliveryNavFocus(nil) end
end

local function clearRentalRecord(id)
  if not state.rentals[id] then return end
  state.rentals[id] = nil
  clearRentalRoute(id)
end

local function reconcileRentals()
  for id, r in pairs(state.rentals) do
    local invId = inventoryRental(id)
    if invId then
      if r.status == "reserved" then clearRentalRoute(id) end
      r.status = "rented"
      r.inventoryId = invId
    elseif r.status == "rented" then
      clearRentalRecord(id)
    end
  end
end

local function openJob(j) return j.status ~= "complete" and j.status ~= "cancelled" end
local function vehiclePreview(vehId)
  local ok, preview = pcall(function()
    local details = core_vehicles.getVehicleDetails(vehId)
    return details and details.configs and details.configs.preview
  end)
  return ok and preview or nil
end

local function depot()
  local level = mapId()
  if level == '' then return nil end
  local function commercial(fac)
    if not fac then return false end
    local org = fac.associatedOrganization and overhaul_world_organizations.getOrganization(fac.associatedOrganization)
    return require("overhaul/lib/logistics/brokerFacilityRouting").shouldOpen(fac, org)
  end
  local id = state.depots[level]
  local fac = id and gen().getFacilityById(id)
  if id and not fac then
    id = require('overhaul/lib/world/levelData').resolveAlias('logisticsDepot', id, {levelId = level, facilityId = id, saveVersion = state.version})
    fac = gen().getFacilityById(id)
  end
  if not commercial(fac) then
    local candidates = {}
    for _, candidate in ipairs(gen().getFacilities()) do
      if commercial(candidate) then candidates[#candidates + 1] = candidate end
    end
    fac = rules.chooseDepot(candidates)
    if not fac then log('W', 'broker', 'No authored freight depot is available on ' .. level) end
  end
  state.depots[level] = fac and fac.id or nil
  return fac
end

local function depotLocation(fac)
  local spot = fac
    and ((fac.inspectSpots or {})[1] or (fac.pickUpSpots or {})[1] or (fac.loanerNonTrailerSpots or {})[1] or (fac.loanerTrailerSpots or {})[1])
  return spot and { type = "facilityParkingspot", facId = fac.id, psPath = spot:getPath() }
end

local function rentalVehicleSpawned(invId)
  if not invId then return false end
  local vehId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(invId)
  return vehId and be:getObjectByID(vehId) and true or false
end

local function dismissCollectUi()
  overhaul_phone_phone.closePhone()
  guihooks.trigger("ChangeState", { state = "play" })
  if
    overhaul_integration_services_markerInteraction
    and overhaul_integration_services_markerInteraction.closeViewDetailPrompt
  then
    overhaul_integration_services_markerInteraction.closeViewDetailPrompt(true)
  end
end

-- Checks each reserved parcel and returns the batch plan, or the reason it cannot load.
local function planBatch(items)
  local plan, seen = {}, {}
  for _, item in pairs(type(items) == "table" and items or {}) do
    local job = type(item) == "table" and state.jobs[item.id]
    if job and not seen[job.id] then
      seen[job.id] = true
      local batch = kinds.forKind(job.kind).batch
      if not batch or job.map ~= mapId() or (job.status ~= "reserved" and job.status ~= "active") then
        return nil, "A parcel is no longer reserved. Refresh and retry."
      end
      if not atPickup(job) then return nil, "Drive to the marked pickup first." end
      plan[#plan + 1] = { job = job, key = tostring(item.container or ""), batch = batch }
    end
  end
  if #plan == 0 then return nil, "Choose at least one parcel to load." end
  return plan
end

-- Every parcel's kind must pass its precheck before any container is touched.
local function precheckBatch(plan)
  for _, p in ipairs(plan) do
    local ok, msg = p.batch.precheck(brokerServices)
    if not ok then return false, msg end
  end
  return true
end

-- Stages each parcel into its chosen box; the first failure finishes the batch and returns false.
local function stageBatch(plan, containers, finish)
  local boxes = {}
  for _, con in ipairs(containers or {}) do
    boxes[tostring(con.vehId) .. ":" .. tostring(con.containerId)] = { con = con, left = con.freeCargoSlots or 0 }
  end
  for _, p in ipairs(plan) do
    if not atPickup(p.job) then
      finish(false, "Return to the pickup to load.")
      return false
    end
    p.box = boxes[p.key]
    if not p.box then
      finish(false, "A chosen cargo box is no longer nearby. Rescan and retry.")
      return false
    end
    local ok, msg = p.batch.stage(brokerServices, p)
    if not ok then
      finish(false, msg)
      return false
    end
  end
  return true
end

-- Moves every staged parcel in one commit, then reports how many reached their vehicle.
local function commitBatch(plan, finish)
  for _, p in ipairs(plan) do
    p.batch.move(brokerServices, p)
  end
  overhaul_career_logistics_cargoScreen.commitDeliveryConfiguration(collectionCallback(function()
    local loaded = 0
    for _, p in ipairs(plan) do
      if p.batch.loaded(brokerServices, p.job) then loaded = loaded + 1 end
    end
    if loaded == #plan then
      finish(true, loaded == 1 and "Parcel loaded." or loaded .. " parcels loaded.")
    elseif loaded > 0 then
      finish(false, loaded .. " of " .. #plan .. " parcels loaded. Retry the rest at the pickup.")
    else
      finish(false, "Cargo could not be loaded. Retry at the pickup.")
    end
  end))
end

-- Per-frame update --------------------------------------------------------------------------------
function M.onUpdate(dtReal)
  if not overhaul_career_career or not overhaul_career_career.isActive() then return end
  local generator = gen()
  local map = mapId()
  -- A map transition can leave the old generator in place until setup finishes.
  if generator.getSetupLevelIdentifier and generator.getSetupLevelIdentifier() ~= map then return end
  if presenceWatcher.update(dtReal or 0, map, generator.getFacilities(), playerPosition, position) then
    extensions.hook("onOverhaulBrokerPresenceChanged")
  end
  restoreTimer = restoreTimer + (dtReal or 0)
  if restoreTimer < 1 then return end
  restoreTimer = 0
  if next(pendingRestore.cargo or {}) or next(pendingRestore.tasks or {}) then
    persistence.restore(pendingRestore, state.jobs)
  end
end

-- Save and setup ----------------------------------------------------------------------------------
function M.serialize(forSave)
  syncJobs()
  local saved
  if forSave then
    saved = {}
    for key, value in pairs(state) do
      saved[key] = value
    end
  else
    saved = deepcopy(state)
  end
  saved.inTransit = persistence.capture(pendingRestore)
  return saved
end

local function pruneFinishedJobs()
  local finished = {}
  for id, job in pairs(state.jobs) do
    if type(job) == "table" and (job.status == "complete" or job.status == "cancelled") then
      finished[#finished + 1] = { id = id, n = tonumber(tostring(id):match("(%d+)$")) or 0 }
    end
  end
  if #finished <= FINISHED_JOB_KEEP then return end
  table.sort(finished, function(a, b) return a.n > b.n end)
  for i = FINISHED_JOB_KEEP + 1, #finished do
    local id = finished[i].id
    state.jobs[id] = nil
    if type(state.stops) == "table" then
      for j = #state.stops, 1, -1 do
        if state.stops[j].jobId == id then table.remove(state.stops, j) end
      end
    end
  end
end

function M.setup(saved)
  clearFreightRoute()
  discardPicker.clear()
  clearRentalRoute()
  local tasks = overhaul_career_logistics_vehicleTasks
  if tasks and tasks.clearBrokerTasksForLoad then tasks.clearBrokerTasksForLoad() end
  state = { version = 1, jobs = {}, plans = {}, stops = {}, rentals = {}, depots = {}, preferences = {}, nextId = 1 }
  if type(saved) == "table" then
    for k, v in pairs(saved) do
      state[k] = v
    end
  end
  if type(state.jobs) == "table" then pruneFinishedJobs() end
  offers = {}
  natives = {}
  offerCache, jobCache = viewCache.new(), viewCache.new()
  offerFacilities = nil
  routeCache, routeCacheMap, routeCacheSize = {}, nil, 0
  busy = false
  busyToken = busyToken + 1
  collectionFailed = nil
  presenceWatcher.reset()
  restoreTimer = 0
  pendingRestore = state.inTransit or { cargo = {}, tasks = {} }
  state.inTransit = nil
  if vehicles() and vehicles().getAllOfferCustomFilter then
    for _, offer in ipairs(vehicles().getAllOfferCustomFilter(function(o) return o.brokerId ~= nil end) or {}) do
      local job = state.jobs[offer.brokerId]
      if job then kinds.forKind(job.kind).restoreOffer(brokerServices, job, offer) end
    end
  end
  persistence.prepare(
    pendingRestore,
    state.jobs,
    function(job, offer) kinds.forKind(job.kind).restoreOffer(brokerServices, job, offer) end
  )
end

-- Public API: status ------------------------------------------------------------------------------
function M.setOpenContext(facility, atDepot, tab, select)
  openContext = { facility = facility, depot = atDepot, tab = tab, select = select }
end

local function fitCandidates(yieldWork)
  local candidates = {owned = {}, loaners = M.getLoanerCatalog(yieldWork) or {}}
  local inventory = overhaul_career_garage_inventory
  local current = getPlayerVehicle(0)
  local currentId = current and current.getID and inventory.getInventoryIdFromVehicleId(current:getID())
  for id, vehicle in pairs(inventory.getVehicles() or {}) do
    local offer = capabilities.inventoryVehAsOffer(vehicle)
    if offer then
      candidates.owned[#candidates.owned + 1] = {id = id, offer = offer}
      if id == currentId then candidates.current = offer end
    end
  end
  if not candidates.current and current and current.getID then
    local data = core_vehicle_manager.getVehicleData(current:getID())
    if data then candidates.current = capabilities.inventoryVehAsOffer({model = current.JBeam, config = data.config}) end
  end
  return candidates
end

local function withFit(row, candidates, handler)
  handler = handler or kinds.forKind(row.kind)
  local fit = {current = {state = "unknown"}, owned = {}, loaners = {}}
  local function result(offer)
    local profile = capabilities.getProfile(offer)
    local compatible = profile and handler.fit(profile, row, capabilities)
    return {state = compatible == nil and "unknown" or compatible and "compatible" or "incompatible",
      equipment = profile and (profile.isTrailer and "trailer" or "vehicle") or nil}
  end
  if candidates.current then fit.current = result(candidates.current) end
  for _, item in ipairs(candidates.owned) do
    local entry = result(item.offer); entry.id = item.id
    fit.owned[#fit.owned + 1] = entry
  end
  for _, item in ipairs(candidates.loaners) do
    local entry = result(item); entry.id = item.id
    fit.loaners[#fit.loaners + 1] = entry
  end
  row.access = row.access or {state = "available", reasons = {}}
  row.access.fit = fit
  return row
end

function M.getState(yieldWork)
  syncJobs()
  M.refreshOffers(yieldWork)
  local bonus = levelBonus()
  local list = {}
  local player, candidates = playerPosition(), fitCandidates(yieldWork)
  local distances = {}
  local nextUnlock
  for _, offer in pairs(offers) do
    local r = offer
    local present = pickupPresence(r, player, distances)
    r.pickupDistance, r.atPickup = present.distance, present.here
    for _, reason in ipairs(r.access.reasons) do
      if reason.need and (not nextUnlock or reason.need < nextUnlock.need) then nextUnlock = deepcopy(reason) end
    end
    list[#list + 1] = withFit(withLevelPay(r, bonus), candidates)
    if yieldWork then yieldWork() end
  end
  local jobs = {}
  for id, j in pairs(state.jobs) do
    -- Native car-haul state is saved with the job but never crosses to the UI.
    local source = {}
    for key, value in pairs(j) do if key ~= 'native' then source[key] = value end end
    local row = jobCache.get(id, source, nil, function() return deepcopy(source) end)
    local present = pickupPresence(row, player, distances)
    row.atPickup, row.pickupDistance = present.here, present.distance
    row.atDelivery = row.map == mapId() and near(row.destination) or false
    withFit(withLevelPay(row, bonus), candidates)
    if row.status == "active" and row.map == mapId() then row.abandonFine = M.abandonQuote(row.id) end
    jobs[#jobs + 1] = row
    if yieldWork then yieldWork() end
  end
  jobCache.retain(state.jobs)
  for _, row in ipairs(candidates.loaners) do withFit(row, candidates, loanerKind) end
  local context = openContext
  openContext = nil
  return {
    markets = rules.markets,
    nextUnlock = nextUnlock,
    logisticsTime = now(), -- Offer expiry uses simulation time, never the wall clock.
    offers = list,
    jobs = jobs,
    plans = state.plans,
    stops = state.stops,
    preferences = state.preferences,
    openContext = context,
    reservationCount = rules.holdCount(state.jobs),
    employed = employed(),
    employerName = employerName(),
    map = mapId(),
    busy = busy,
    profile = overhaul_career_saveSystem.getCurrentSaveSlot() or "",
    depot = M.getDepotView(),
    loanerFacilities = M.getLoanerFacilities(),
    loaners = candidates.loaners,
    rentals = M.getRentals() or {},
    route = M.routeSummary(),
  }
end

-- Cheap dependencies for the phone's backup poll. Offer generation, equipment,
-- skills and native outcomes also invalidate its snapshot through change hooks.
function M.getPollingState()
  local player = playerPosition()
  return {map = mapId(), profile = overhaul_career_saveSystem.getCurrentSaveSlot() or "",
    x = player and math.floor(player.x), y = player and math.floor(player.y), z = player and math.floor(player.z),
    day = math.floor(now() / 86400), employed = employed()}, now()
end

function M.abandonQuote(id)
  local job = state.jobs[id]
  if not job then return 0 end
  return kinds.forKind(job.kind).abandonQuote(brokerServices, job)
end

-- Public API: reservations ------------------------------------------------------------------------
M.isNativeBooked = booked
function M.jobForNative(kind, id)
  for key, j in pairs(state.jobs) do
    if
      j.kind == kind
      and j.nativeId == id
      and j.map == mapId()
      and j.status ~= "complete"
      and j.status ~= "cancelled"
    then
      return key
    end
  end
end

function M.refreshOffers(yieldWork)
  local previousOffers = offers
  local nextOffers, nextNatives = {}, {}
  local context = setmetatable({}, {__index = brokerServices})
  context.cachedOffer = function(...)
    cachedOffer(nextOffers, nextNatives, ...)
    if yieldWork then yieldWork() end
  end
  context.addOffer = function(id, kind, native, row)
    nextOffers[id], nextNatives[id] = addOffer(id, kind, native, row), native
  end
  -- After a map switch the generator may hold the old map's facilities; re-run setup for this map.
  local g = general()
  if g and g.ensureSetupForCurrentMap then g.ensureSetupForCurrentMap() end
  if gen().getSetupLevelIdentifier and gen().getSetupLevelIdentifier() ~= mapId() then
    offers, natives = nextOffers, nextNatives
    return
  end
  -- Explicit actions retain their synchronous catch-up. Phone refreshes read
  -- the board that the budgeted logistics generator has already produced.
  if not yieldWork then gen().triggerAllGenerators() end
  local facilities = gen().getFacilities() or {}
  local presentation = {mapId()}
  for _, fac in ipairs(facilities) do
    presentation[#presentation + 1] = table.concat({fac.id, text(fac.name), tostring(fac.preview), tostring(fac)}, '|')
  end
  presentation = table.concat(presentation, '\n')
  if presentation ~= offerFacilities then
    offerCache = viewCache.new()
    offerFacilities = presentation
  end
  for _, fac in ipairs(facilities) do
    for _, h in ipairs(kinds.list()) do
      h.collect(context, fac)
      if yieldWork then yieldWork() end
    end
  end
  for _, h in ipairs(kinds.list()) do
    h.collectBoard(context)
    if yieldWork then yieldWork() end
  end
  -- A cancelled phone refresh never publishes a partially built offer board.
  offers, natives = nextOffers, nextNatives
  offerCache.retain(offers)
  local changed = false
  for id, row in pairs(offers) do
    if previousOffers[id] ~= row then changed = true; break end
  end
  if not changed then
    for id in pairs(previousOffers) do
      if not offers[id] then changed = true; break end
    end
  end
  if changed then presenceWatcher.invalidate() end
end

function M.reserve(id, signature, keepOffers)
  if busy then return false, "Finish the current collection first." end
  if employed() then return false, "Job Broker is for independent contractors." end
  syncJobs()
  if not keepOffers then M.refreshOffers() end
  local plan = state.plans[id]
  if plan then
    signature = plan.signature
    id = plan.offerId
  end
  local row, native = offers[id], natives[id]
  if not row then return false, "This load is no longer available." end
  rowAccess(row, native)
  if not row.unlocked then return false, row.lockedReason end
  if signature and signature ~= row.signature then
    return false, "This saved offer has changed. Choose a current load from the market."
  end
  local job = deepcopy(row)
  job.access, job.offerExpiresAt, job.modifiers = nil, nil, nil
  job.id = nextId("job")
  job.offerId = id
  job.status = "reserved"
  local ok, msg = kinds.forKind(row.kind).reserve(brokerServices, job, row, native)
  if not ok then return false, msg end
  state.jobs[job.id] = job
  remapFreightRouteJob(id, job.id)
  for key, p in pairs(state.plans) do
    if key == id or (p.offerId == id and p.signature == row.signature) then
      for _, stop in ipairs(state.stops) do
        if stop.jobId == key then stop.jobId = job.id end
      end
      remapFreightRouteJob(key, job.id)
      state.plans[key] = nil
    end
  end
  refreshPois()
  return true, "Load reserved.", job.id
end

function M.cancel(id)
  if busy then return false, "Finish the current collection first." end
  syncJobs()
  local job = state.jobs[id]
  if not job or job.map ~= mapId() or job.status ~= "reserved" then
    return false, "Only uncollected reservations can be cancelled here."
  end
  local ok, msg = kinds.forKind(job.kind).release(brokerServices, job)
  if not ok then return false, msg end
  state.jobs[id] = nil
  for i = #state.stops, 1, -1 do
    if state.stops[i].jobId == id then table.remove(state.stops, i) end
  end
  refreshPois()
  clearFreightRoute(id)
  return true, "Reservation cancelled."
end
-- Reserved parcels waiting at their pickup spot; general.lua shows them as the vanilla Pick Up prompt.
function M.getReservedPickups()
  local out = {}
  if employed() then return out end
  for _, job in pairs(state.jobs) do
    local handler = kinds.forKind(job.kind)
    local pickup = handler.reservedPickup(brokerServices, job)
    if pickup then
      -- Every spot in the area takes the pickup, but only one (the job's own spot, else the first) is its
      -- far-visible marker; the rest show up close, as normal parking markers do.
      local first, primaryFound = #out + 1, false
      for _, spot in ipairs(handler.pickupArea(brokerServices, job).spots) do
        if spot.psPath then
          local row = deepcopy(pickup)
          row.primary = spot.psPath == pickup.psPath and not primaryFound
          primaryFound = primaryFound or row.primary
          row.psPath, row.facId = spot.psPath, spot.facId
          out[#out + 1] = row
        end
      end
      if not primaryFound and out[first] then out[first].primary = true end
    end
  end
  for id, rental in pairs(state.rentals) do
    if rental.status == "reserved" then
      for _, location in ipairs(M.getLoanerFacilities()) do
        local fac = gen().getFacilityById(location.id)
        local area = presence.area({origin = location.location}, fac,
          {"loanerNonTrailerSpots", "loanerTrailerSpots"})
        for _, spot in ipairs(area.spots) do
          if spot.psPath then out[#out + 1] = {facId = spot.facId, psPath = spot.psPath,
            jobId = id, title = rental.name, kind = "loaner", slots = 0} end
        end
      end
    end
  end
  return out
end
-- Reserves a group of identical offers in one pass and reports how many were taken.
function M.reserveMany(items)
  local list = {}
  for _, item in ipairs(type(items) == "table" and items or {}) do
    if type(item) == "table" and item.id then list[#list + 1] = item end
  end
  if #list == 0 then return false, "Choose loads to reserve." end
  M.refreshOffers()
  local reserved, firstId, reason = 0, nil, nil
  for _, item in ipairs(list) do
    local ok, msg, jobId = M.reserve(item.id, item.signature, true)
    if not ok then
      reason = msg
      break
    end
    reserved = reserved + 1
    firstId = firstId or jobId
  end
  if reserved == 0 then return false, reason or "Nothing could be reserved." end
  if reserved < #list then
    return true, reserved .. " of " .. #list .. " loads reserved. " .. (reason or ""), firstId
  end
  return true, reserved == 1 and "Load reserved." or reserved .. " loads reserved.", firstId
end

-- Public API: route and stops ---------------------------------------------------------------------
-- The big-map focus follows the first stop; the path then keeps markers up on arrival and covers every stop.
local function guideTo(waypoints, jobs, isPlan)
  general().setDeliveryNavFocus(waypoints[1])
  freightRoute.set(waypoints, { clearPathOnReachingTarget = false })
  freightRouteJobs, freightRouteIsPlan = jobs, isPlan or false
end

function M.navigate(id, leg, stopId)
  local item = state.jobs[id] or offers[id] or state.plans[id]
  if not item or item.map ~= mapId() then return false, "This load is on another map." end
  local loc = leg == "delivery" and item.destination or item.origin
  if stopId then
    for _, stop in ipairs(state.stops) do
      if stop.id == stopId and stop.jobId == id then
        loc = stop.location or loc
        break
      end
    end
  end
  local pos = position(loc)
  if not pos then return false, "The selected stop is unavailable." end
  guideTo({ pos }, {[id] = true})
  return true, leg == "delivery" and "Route to delivery set." or "Route to pickup set."
end

function M.plan(id)
  for key, p in pairs(state.plans) do
    if p.offerId == id then
      id = key
      break
    end
  end
  if state.plans[id] then
    state.plans[id] = nil
    for i = #state.stops, 1, -1 do
      if state.stops[i].jobId == id then table.remove(state.stops, i) end
    end
    clearFreightRoute(id)
    return true, "Plan removed."
  end
  local row = offers[id] or state.jobs[id]
  if not row then return false, "This load is no longer available." end
  local originalId = id
  if not row.status then id = nextId("plan") end
  state.plans[id] = deepcopy(row)
  state.plans[id].id = id
  state.plans[id].offerId = originalId
  remapFreightRouteJob(originalId, id)
  state.stops[#state.stops + 1] =
    { id = nextId("stop"), jobId = id, kind = "pickup", location = deepcopy(row.origin), name = row.from }
  local destinations = kinds.forKind(row.kind).destinations(row)
  if not destinations[1] then destinations = { row.destination } end
  for _, loc in ipairs(destinations) do
    state.stops[#state.stops + 1] =
      { id = nextId("stop"), jobId = id, kind = "delivery", location = deepcopy(loc), name = locationName(loc) }
  end
  return true, "Added to route."
end

function M.moveStop(index, delta)
  index = tonumber(index)
  delta = tonumber(delta)
  if not index or (delta ~= -1 and delta ~= 1) or not state.stops[index] or not state.stops[index + delta] then
    return false, "Cannot move this stop."
  end
  local copy = deepcopy(state.stops)
  copy[index], copy[index + delta] = copy[index + delta], copy[index]
  if not rules.validStopOrder(copy) then return false, "Delivery must follow pickup." end
  state.stops = copy
  return true, "Route updated."
end

function M.routeSummary()
  local legs, total, prev = {}, 0, playerPosition()
  for _, p in ipairs(stopPoints()) do
    local d = distance(prev, p.pos)
    legs[#legs + 1] = { stopId = p.stop.id, distance = d }
    if d then total = total + d end
    prev = p.pos
  end
  return { legs = legs, total = total, stops = #legs }
end

function M.showRoute()
  local pts = stopPoints()
  if not pts[1] then return false, "Save loads to your route first." end
  local list, jobs = {}, {}
  for _, p in ipairs(pts) do
    list[#list + 1] = p.pos
    jobs[p.stop.jobId] = true
  end
  guideTo(list, jobs, true)
  return true, string.format("Route set through %d stop%s.", #list, #list == 1 and "" or "s")
end

-- Same call as cancelling on the big map: it drops the markers, the big-map focus and, in delivery mode, the
-- automatic route that would otherwise draw them again.
function M.clearRoute()
  clearFreightRoute()
  freeroam_bigMapMode.setNavFocus(nil)
  return true, "Route cleared."
end

function M.optimizeStops()
  if #state.stops < 2 then return false, "Add more stops to order them." end
  local remaining, ordered, cur = deepcopy(state.stops), {}, playerPosition()
  while #remaining > 0 do
    local bestI, bestD = nil, nil
    for i, stop in ipairs(remaining) do
      local blocked = false
      if stop.kind == "delivery" then
        for _, o in ipairs(remaining) do
          if o ~= stop and o.jobId == stop.jobId and o.kind == "pickup" then
            blocked = true
            break
          end
        end
      end
      if not blocked then
        local pos = position(stop.location)
        local d = pos and distance(cur, pos) or math.huge
        if not bestD or d < bestD then
          bestI, bestD = i, d
        end
      end
    end
    if not bestI then break end
    local stop = table.remove(remaining, bestI)
    ordered[#ordered + 1] = stop
    cur = position(stop.location) or cur
  end
  for _, stop in ipairs(remaining) do
    ordered[#ordered + 1] = stop
  end
  if not rules.validStopOrder(ordered) then return false, "Could not order the stops." end
  state.stops = ordered
  return true, "Stops ordered by shortest drive."
end

function M.routePreview(id)
  local item = state.jobs[id] or offers[id] or state.plans[id]
  if not item or item.map ~= mapId() then return nil end
  local a, b = position(item.origin), position(item.destination)
  if not a or not b then return nil end
  local me = playerPosition()
  local p1, d1 = routePolyline(me, a)
  local p2, d2 = routePolyline(a, b)
  return {
    legs = { { kind = "approach", path = p1, distance = d1 }, { kind = "delivery", path = p2, distance = d2 } },
    points = { player = { me.x, me.y }, pickup = { a.x, a.y }, delivery = { b.x, b.y } },
  }
end

function M.planPreview()
  local pts = stopPoints()
  if not pts[1] then return nil end
  local prev = playerPosition()
  local legs, stops = {}, {}
  for _, p in ipairs(pts) do
    local path, d = routePolyline(prev, p.pos)
    legs[#legs + 1] =
      { stopId = p.stop.id, kind = p.stop.kind == "pickup" and "pickup" or "delivery", path = path, distance = d }
    stops[#stops + 1] = { p.pos.x, p.pos.y, p.stop.kind }
    prev = p.pos
  end
  local me = playerPosition()
  return { legs = legs, points = { player = { me.x, me.y }, stops = stops } }
end

function M.setPreferences(value)
  if type(value) == "table" then state.preferences = deepcopy(value) end
end

-- Public API: collection --------------------------------------------------------------------------
function M.pickup(id, amount, containerKey, selectedCars, callback)
  if busy or employed() then return false, "Collection is unavailable right now." end
  local job = state.jobs[id]
  if not job or job.map ~= mapId() or (job.status ~= "reserved" and job.status ~= "active") then
    return false, "Select a current reservation."
  end
  if not atPickup(job) then return false, "Drive to the marked pickup first." end
  return collect(callback, function(finish)
    return kinds.forKind(job.kind)
      .pickup(brokerServices, job, { amount = amount, containerKey = containerKey, selectedCars = selectedCars, startHere = startingJobs[id] }, finish)
  end)
end
-- Reserve and collect through the same kind workflow; failed collections release their hold.
function M.startHere(id, amount, containerKey, selectedCars, callback)
  if busy or employed() then return false, "Collection is unavailable right now." end
  M.refreshOffers()
  local row = offers[id]
  if not row then
    for _, item in ipairs(M.getLoanerCatalog()) do
      if item.id == id then
        if not item.atPickup then return false, "Go to a facility with compatible loaner bays first." end
        local ok, message, rentalId = M.reserveRental(id)
        if not ok then return false, message end
        local completed = false
        local function done(success, reason)
          if completed then return end
          completed = true
          if not success then M.cancelRental(rentalId) end
          if callback then callback(success, reason) end
        end
        local started, reason = M.collectRental(rentalId, done)
        if started == false then done(false, reason) end
        return started, reason, rentalId
      end
    end
    return false, "This load is no longer available."
  end
  if not atPickup(row) then return false, "Drive to the marked pickup first." end
  local ok, message, jobId = M.reserve(id, nil, true)
  if not ok then return false, message end
  local completed = false
  local function done(success, reason)
    if completed then return end
    completed = true
    if not success then M.cancel(jobId) end
    if callback then callback(success, reason) end
  end
  startingJobs[jobId] = true
  local started, reason = M.pickup(jobId, amount, containerKey, selectedCars, done)
  startingJobs[jobId] = nil
  if started == false then done(false, reason) end
  return started, reason, jobId
end

-- Loads several reserved parcels at one pickup in one commit; each must fit the space left in its box.
function M.pickupBatch(items, callback)
  if busy or employed() then return false, "Collection is unavailable right now." end
  local plan, reason = planBatch(items)
  if not plan then return false, reason end
  local ok, msg = precheckBatch(plan)
  if not ok then return false, msg end
  return collect(callback, function(finish)
    general().getNearbyVehicleCargoContainers(collectionCallback(function(containers)
      if employed() then
        finish(false, "Collection is unavailable right now.")
        return
      end
      if stageBatch(plan, containers, finish) then commitBatch(plan, finish) end
    end))
    return true, "Loading " .. #plan .. (#plan == 1 and " parcel…" or " parcels…")
  end)
end
-- Load now: reserves unreserved offers here and loads them with existing reservations; unloaded ones are released.
function M.loadHere(items, callback)
  if busy or employed() then return false, "Collection is unavailable right now." end
  local list = {}
  for _, item in ipairs(type(items) == "table" and items or {}) do
    if type(item) == "table" and (item.offer or item.id) then list[#list + 1] = item end
  end
  if #list == 0 then return false, "Choose at least one parcel to load." end
  local created, batch = {}, {}
  local function release()
    for _, jobId in ipairs(created) do
      local job = state.jobs[jobId]
      if job and job.status == "reserved" then M.cancel(jobId) end
    end
  end
  M.refreshOffers()
  for _, item in ipairs(list) do
    if item.offer then
      local row = offers[item.offer]
      if not row or not kinds.forKind(row.kind).batch or not atPickup(row) then
        release()
        return false, "A parcel here is no longer available. Refresh and retry."
      end
      local ok, msg, jobId = M.reserve(item.offer, item.signature, true)
      if not ok then
        release()
        return false, msg
      end
      created[#created + 1] = jobId
      batch[#batch + 1] = { id = jobId, container = item.container }
    else
      batch[#batch + 1] = { id = item.id, container = item.container }
    end
  end
  local ok, message = M.pickupBatch(batch, function(done, msg)
    release()
    if callback then callback(done, msg) end
  end)
  if not ok then release() end
  return ok, message
end

function M.requestContainers(callback)
  general().getNearbyVehicleCargoContainers(function(containers)
    local result, previews = {}, {}
    for _, c in ipairs(containers or {}) do
      if previews[c.vehId] == nil then previews[c.vehId] = vehiclePreview(c.vehId) or false end
      result[#result + 1] = {
        key = tostring(c.vehId) .. ":" .. tostring(c.containerId),
        name = c.moveToLabel,
        free = c.freeCargoSlots,
        capacity = c.totalCargoSlots,
        types = c.cargoTypesLookup,
        material = c.rawCargo[1] and c.rawCargo[1].materialType,
        vehId = c.vehId,
        vehName = c.vehName,
        boxName = c.name,
        preview = previews[c.vehId] or nil,
        attachment = c.attachmentStatus,
      }
    end
    callback(result)
  end)
end

-- Public API: obligations -------------------------------------------------------------------------
function M.requestDiscardGroups(ids)
  syncJobs()
  local jobs = {}
  for _, id in ipairs(ids or {}) do
    local job = state.jobs[id]
    if busy or not job or job.status ~= "active" or job.map ~= mapId() or brokerServices.awaitingCargoRestore(id) then
      discardPicker.clear()
      return {ok = false, message = "Select loaded work on this map and wait for its vehicle to restore."}
    end
    jobs[id] = job
  end
  -- The selected load opens the cargo picker for all loaded work. My Loads lists
  -- parcels individually, so limiting this to the row would hide every other type.
  if discardPicker.hasCargo(jobs) then
    for id, job in pairs(state.jobs) do
      if job.status == "active" and job.map == mapId() and not brokerServices.awaitingCargoRestore(id) then jobs[id] = job end
    end
  end
  return discardPicker.prepare(jobs)
end

function M.discardSelectedCargo(token, selections)
  if busy then return false, "Wait for the current loading operation to finish." end
  syncJobs()
  local ok, message = discardPicker.commit(token, selections)
  if not ok then return false, message end
  -- Discard can cancel several jobs at once. Remove every cancelled stop before
  -- rebuilding owned guidance, while retained loads keep their route stops.
  for i = #state.stops, 1, -1 do
    local job = state.jobs[state.stops[i].jobId]
    if job and job.status == "cancelled" then table.remove(state.stops, i) end
  end
  for id, job in pairs(state.jobs) do
    if job.status == "cancelled" then clearFreightRoute(id) end
  end
  return true, message
end

function M.abandon(id)
  local job = state.jobs[id]
  if busy or not job or job.status ~= "active" or job.map ~= mapId() then
    return false, "Select work in progress on this map."
  end
  for _, saved in pairs(pendingRestore.cargo or {}) do
    if saved.cargo and saved.cargo.data and saved.cargo.data.brokerId == id then
      return false, "Wait for the loaded vehicle to restore first."
    end
  end
  for _, saved in pairs(pendingRestore.tasks or {}) do
    if saved.offer and saved.offer.brokerId == id then
      return false, "Wait for the delivery vehicle to restore first."
    end
  end
  local ok, msg = kinds.forKind(job.kind).abandon(brokerServices, job)
  if not ok then return false, msg end
  job.status = "cancelled"
  for i = #state.stops, 1, -1 do
    if state.stops[i].jobId == id then table.remove(state.stops, i) end
  end
  clearFreightRoute(id)
  refreshPois()
  overhaul_career_logistics_tasklist.sendCargoToTasklist()
  return true, "Work abandoned. Existing delivery penalties apply."
end

function M.abandonMany(ids)
  local done, reason = eachJob(ids, M.abandon)
  if done == 0 then return false, reason or "Select work in progress on this map." end
  local head = done == 1 and "Work abandoned." or done .. " loads abandoned."
  return true,
    reason and head .. " Some could not be abandoned: " .. reason or head .. " Existing delivery penalties apply."
end

function M.cancelMany(ids)
  local done, reason = eachJob(ids, M.cancel)
  if done == 0 then return false, reason or "Only uncollected reservations can be cancelled here." end
  local head = done == 1 and "Reservation cancelled." or done .. " reservations cancelled."
  return true, reason and head .. " Some could not be cancelled: " .. reason or head
end

function M.hasObligations()
  syncJobs()
  reconcileRentals()
  for _, j in pairs(state.jobs) do
    if openJob(j) then return true end
  end
  for _, r in pairs(state.rentals) do
    if r.status ~= "returned" then return true end
  end
  return false
end

function M.getObligations()
  syncJobs()
  reconcileRentals()
  local jobs, rentals, fine = {}, {}, 0
  for _, j in pairs(state.jobs) do
    if openJob(j) then
      local row = {
        id = j.id,
        kind = j.kind,
        title = j.title,
        from = j.from,
        to = j.to,
        status = j.status,
        map = j.map,
        onMap = j.map == mapId(),
        fine = 0,
      }
      if j.status == "active" and row.onMap then row.fine = M.abandonQuote(j.id) end
      fine = fine + row.fine
      jobs[#jobs + 1] = row
    end
  end
  for id, r in pairs(state.rentals) do
    if r.status ~= "returned" then
      rentals[#rentals + 1] = {
        id = id,
        name = r.name,
        status = r.status,
        map = r.map,
        onMap = r.map == mapId(),
        collected = inventoryRental(id) ~= nil,
      }
    end
  end
  table.sort(jobs, function(a, b) return a.id < b.id end)
  table.sort(rentals, function(a, b) return a.id < b.id end)
  return { jobs = jobs, rentals = rentals, totalFine = fine, count = #jobs + #rentals }
end

function M.clearObligations(callback)
  if busy then return false, "Finish the current collection first." end
  syncJobs()
  reconcileRentals()
  local failures = {}
  local function fail(label, message)
    failures[#failures + 1] = tostring(label or "?") .. ": " .. tostring(message or "failed")
  end
  local jobIds = {}
  for id in pairs(state.jobs) do
    jobIds[#jobIds + 1] = id
  end
  table.sort(jobIds)
  for _, id in ipairs(jobIds) do
    local j = state.jobs[id]
    if j and j.status == "reserved" then
      local ok, msg = cancelReservationForTravel(id)
      if not ok then fail(j.title or id, msg) end
    elseif j and j.status == "active" then
      local ok, msg = M.abandon(id)
      if not ok then fail(j.title or id, msg) end
    end
  end
  local toReturn = {}
  for id, r in pairs(state.rentals) do
    local invId = inventoryRental(id)
    if invId then
      toReturn[#toReturn + 1] = { id = id, name = r.name, invId = invId }
    elseif r.status ~= "returned" then
      clearRentalRecord(id)
    end
  end
  local pending = #toReturn
  local function finish()
    if pending > 0 then return end
    busy = false
    reconcileRentals()
    refreshPois()
    if callback then callback(#failures == 0, failures) end
  end
  if pending == 0 then
    finish()
    return true
  end
  setBusy()
  local loaners = overhaul_career_logistics_loanerVehicles
  loaners.stepOutIfInCompanyVehicle()
  for _, item in ipairs(toReturn) do
    loaners.returnVehicle(item.invId, collectionCallback(function(ok)
      pending = pending - 1
      if ok == false or inventoryRental(item.id) then
        fail(item.name or item.id, "could not be returned.")
      else
        clearRentalRecord(item.id)
      end
      finish()
    end))
  end
  return true
end

-- Public API: depot and rentals -------------------------------------------------------------------
function M.getLoanerFacilities()
  local out, seen = {}, {}
  local selected = depot()
  local function add(fac)
    if not fac or seen[fac.id] then return end
    seen[fac.id] = true
    local area = loanerKind.pickupArea(brokerServices, {origin = depotLocation(fac)})
    local present = presence.measure(area, playerPosition(), position)
    out[#out + 1] = {id = fac.id, name = text(fac.name), location = depotLocation(fac),
      isDepot = selected and fac.id == selected.id or false,
      atDepot = present.here, atPickup = present.here, pickupDistance = present.distance}
  end
  add(selected)
  for _, fac in ipairs(gen().getFacilities() or {}) do
    if (fac.loanerNonTrailerSpots or {})[1] or (fac.loanerTrailerSpots or {})[1] then add(fac) end
  end
  return out
end

local function rentalFacility(item)
  local locations = M.getLoanerFacilities()
  for _, location in ipairs(locations) do
    local fac = gen().getFacilityById(location.id)
    local profile = item and capabilities.getProfile(item)
    local spots = fac and (profile and profile.isTrailer and fac.loanerTrailerSpots or fac.loanerNonTrailerSpots)
    if location.atDepot and (location.isDepot or (spots or {})[1]
      or (not item and (fac.loanerTrailerSpots or {})[1])) then return fac, location.location end
  end
  -- Old bookings retain their collection depot even if its authored role changed.
  local saved = item and item.map == mapId() and item.depotId and gen().getFacilityById(item.depotId)
  local location = depotLocation(saved)
  if location and near(location) then return saved, location end
end

function M.isAtLoanerFacility(facId)
  for _, location in ipairs(M.getLoanerFacilities()) do
    if location.id == facId then return location.atDepot end
  end
  return false
end

function M.getDepotView()
  local fac = rentalFacility() or depot()
  local loc = depotLocation(fac)
  return fac and { id = fac.id, name = text(fac.name), location = loc, atDepot = loc and near(loc) or false } or nil
end

function M.navigateDepot()
  local pos = position(depotLocation(depot()))
  if not pos then return false, "No depot is available on this map." end
  general().setDeliveryNavFocus(pos)
  rentalRoute.set(pos, { clearPathOnReachingTarget = false })
  rentalRouteId = nil
  return true, "Route to depot set."
end

function M.getLoanerCatalog(yieldWork)
  local result = {}
  local config = jsonReadFile("/gameplay/overhaul/loaners/broker.json") or {}
  local day = math.floor(now() / 86400)
  for _, item in ipairs(config.vehicles or {}) do
    local info = core_vehicles.getConfig(item.model, item.config)
    if info and (item.basic or (day + (item.rotation or 0)) % 2 == 0) then
      local row = deepcopy(item)
      row.rate =
        rules.dailyRate(overhaul_career_logistics_loanerVehicles.getHourlyRateForOffer(item, info), item.id, day)
      row.preview = info.preview
      row.capacity = info.capacity
      row.kind = "loaner"
      access.apply(row, access.evaluate(loanerKind.requirements(brokerServices, item), branchInfo, text))
      row.access.fit = {profile = capabilities.getProfile(item)}
      local fac = rentalFacility(item)
      row.atPickup = fac ~= nil
      row.facilityId = fac and fac.id
      row.pickupAreas = M.getLoanerFacilities()
      result[#result + 1] = row
    end
    if yieldWork then yieldWork() end
  end
  return result
end

function M.reserveRental(id)
  if employed() then return false, "Job Broker is for independent contractors." end
  local fac = rentalFacility() or depot()
  if not fac then
    local location = M.getLoanerFacilities()[1]
    fac = location and gen().getFacilityById(location.id)
  end
  if not fac then return false, "No loaner facility is available on this map." end
  for _, item in ipairs(M.getLoanerCatalog()) do
    if item.id == id then
      if not item.unlocked then return false, item.lockedReason end
      fac = rentalFacility(item) or fac
      local rental = deepcopy(item)
      rental.access, rental.pickupAreas = nil, nil
      rental.id = nextId("rental")
      rental.catalogId = id
      rental.status = "reserved"
      rental.map = mapId()
      rental.depotId = fac.id
      state.rentals[rental.id] = rental
      return true, "Equipment reserved. Collect it at a loaner facility.", rental.id
    end
  end
  return false, "This equipment is no longer available."
end

function M.navigateRental(id)
  local rental = state.rentals[id]
  if not rental or rental.status ~= "rented" or rental.map ~= mapId() then
    return false, "Select collected equipment on this map."
  end
  local invId = inventoryRental(id)
  local vehId = invId and overhaul_career_garage_inventory.getVehicleIdFromInventoryId(invId)
  local veh = vehId and be:getObjectByID(vehId)
  if not veh then return false, "This vehicle is not currently available on the map." end
  local pos = veh:getPosition()
  general().setDeliveryNavFocus(pos)
  rentalRoute.set(pos, { clearPathOnReachingTarget = false })
  rentalRouteId = id
  return true, "Waypoint set to " .. rental.name .. "."
end

function M.getRentals()
  reconcileRentals()
  local out = {}
  for id, r in pairs(state.rentals) do
    if r.status ~= "returned" then
      local row = deepcopy(r)
      row.vehicleSpawned = rentalVehicleSpawned(inventoryRental(id))
      local fac = rentalFacility(row)
      row.atPickup, row.atDepot = fac ~= nil, fac ~= nil
      out[#out + 1] = row
    end
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

function M.cancelRental(id)
  if busy then return false, "Finish the current equipment handoff first." end
  local r = state.rentals[id]
  if not r or r.status ~= "reserved" or inventoryRental(id) then
    return false, "Return collected equipment at the depot."
  end
  clearRentalRecord(id)
  return true, "Rental booking cancelled."
end

function M.collectRental(id, callback)
  local rental = state.rentals[id]
  if busy or employed() or not rental or rental.status ~= "reserved" or inventoryRental(id) then
    return false, "Rental cannot be collected."
  end
  local fac = rentalFacility(rental)
  if not fac then return false, "Go to a facility with compatible loaner bays first." end
  local loaners = overhaul_career_logistics_loanerVehicles
  if loaners.hasMarkedOffers() then return false, "Finish the other vehicle collection first." end
  return collect(callback, function(finish)
    dismissCollectUi()
    local offer = {
      id = rental.id,
      model = rental.model,
      config = rental.config,
      vehMileage = 0,
      loanType = "rental",
      hourlyRate = rental.rate,
      sourceFacility = { type = "deliveryProvider", id = fac.id },
      brokerRentalId = id,
      brokerDepotId = fac.id,
      brokerMap = mapId(),
    }
    loaners.setMarkedForSpawning(offer, true)
    loaners.spawnAllOffers(collectionCallback(function()
      local invId = inventoryRental(id)
      if invId then
        rental.status = "rented"
        rental.map, rental.depotId = mapId(), fac.id
        rental.inventoryId = invId
        clearRentalRoute(id)
      end
      finish(invId ~= nil, invId and "Rental collected." or "No safe collection space. Clear the bay and retry.")
    end))
    return true, "Collecting equipment…"
  end)
end

function M.returnRental(id, callback)
  local r = state.rentals[id]
  if busy or not r then return false, "This rental is not available here." end
  local fac, loc = rentalFacility(r)
  if not fac then return false, "Go to a facility with compatible loaner bays first." end
  local invId = inventoryRental(id)
  if not invId then
    if r.status ~= "rented" then return false, "This rental is not available here." end
    clearRentalRecord(id)
    if callback then callback(true, "Rental cleared.") end
    return true, "Rental cleared."
  end
  local vehId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(invId)
  local veh = vehId and be:getObjectByID(vehId)
  if veh then
    local area = loanerKind.pickupArea(brokerServices, {origin = loc})
    if not presence.measure(area, veh:getPosition(), position).here then
      return false, "Bring this vehicle to the loaner facility."
    end
    local tasks = overhaul_career_logistics_vehicleTasks
    if tasks and tasks.canReturnBrokerEquipment then
      local ok, message = tasks.canReturnBrokerEquipment(vehId)
      if not ok then return false, message end
    end
    for _, c in ipairs(parcels().getAllCargoInVehicles() or {}) do
      if c.location.vehId == vehId then return false, "Unload cargo before returning this vehicle." end
    end
  end
  return collect(callback, function(finish)
    overhaul_career_logistics_loanerVehicles.returnVehicle(invId, collectionCallback(function()
      local settled = not inventoryRental(id)
      if settled then clearRentalRecord(id) end
      finish(settled, settled and "Rental returned and bill settled." or "Rental could not be returned.")
    end))
    return true, "Returning equipment…"
  end)
end

-- Activity ----------------------------------------------------------------------------------------
M.activity = require("overhaul/career/logistics/broker/activity")(M)

-- Game hooks --------------------------------------------------------------------------------------
M.onOverhaulDeliveryModeStopped = syncJobs
-- A native loading screen does not attach broker cargo tags; observe the order before cleanup.
M.onOverhaulMaterialContractCompleted = syncJobs
-- Builtins remain available while the career's add-on cargo catalogs reload.
function M.onExtensionLoaded()
  kinds.discover()
  if disposeNativeCargo then disposeNativeCargo() end
  disposeNativeCargo = nativeCargo.discover()
end

function M.onExtensionUnloaded()
  clearFreightRoute()
  clearRentalRoute()
  presenceWatcher.reset()
  busy, collectionFailed = false, nil
  busyToken = busyToken + 1
  if disposeNativeCargo then
    disposeNativeCargo()
    disposeNativeCargo = nil
  end
end

function M.onBrokerCargoDelivered(cargoItems)
  for _, c in ipairs(cargoItems or {}) do
    local job = c.data and c.data.brokerId and state.jobs[c.data.brokerId]
    if job then
      kinds.forKind(job.kind).cargoDelivered(brokerServices, job)
      presenceWatcher.invalidate()
    end
  end
end

function M.onBrokerVehicleDelivered(items)
  for _, o in ipairs(items or {}) do
    o = o.offer or o
    local job = o.brokerId and state.jobs[o.brokerId]
    if job then
      kinds.forKind(job.kind).vehicleDelivered(brokerServices, job)
      presenceWatcher.invalidate()
    end
  end
end

function M.onBrokerVehicleAbandoned(offer)
  local job = offer and state.jobs[offer.brokerId]
  if job then
    kinds.forKind(job.kind).vehicleAbandoned(brokerServices, job)
    presenceWatcher.invalidate()
  end
  local oo = ownerOp()
  if oo and oo.onCarHaulOfferAbandoned then oo.onCarHaulOfferAbandoned(offer) end
end

function M.onRentalVehicleReturned(rentalId)
  if rentalId then clearRentalRecord(tostring(rentalId)) end
end

return M
