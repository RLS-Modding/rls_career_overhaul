-- Company vehicles, rig reuse and blocked-spawn recovery for employment.
-- Vehicle identity and damage, inventory and fleet queries, spawning and handoffs, blocked spawns and markers.
local M = {}

-- Requires ----------------------------------------------------------------------------------------

-- gameplay_walk is per-level and may be absent during career load or level teardown.
-- Company vehicles are issued and returned through the shared issued library.
local issued = require('overhaul/lib/vehicles/issued')

-- Config ------------------------------------------------------------------------------------------

local OFFER_HOLD_SECONDS = 3600
local SPAWN_BLOCKED_NEARBY_M = 40
local MOVING_SPEED_SQ = 0.25 * 0.25
local MOVING_RECHECK_SECONDS = 1
local IDLE_RECHECK_SECONDS = 2

-- State -------------------------------------------------------------------------------------------

-- Module-level marker cache, shared across instances as before.
local screen = {}

-- Shared helpers ----------------------------------------------------------------------------------

local function idSetOf(ids)
  local set = {}
  for _, id in ipairs(ids or {}) do
    set[id] = true
  end
  return set
end

local function startDeliveryModeIfAvailable(employment)
  local general = employment.services.general()
  if general and general.startDeliveryMode then general.startDeliveryMode() end
end

local function isTrailerModel(model)
  local modelInfo = core_vehicles.getModel(model)
  local modelData = modelInfo and (modelInfo.model or modelInfo)
  return modelData and modelData.Type == "Trailer" or false
end

-- Vehicle identity and damage ---------------------------------------------------------------------

function M.issuedVehicleNeedsRepair(employment)
  local shift = employment.getState().shift
  if not shift or not employment.services.insurance() then return false end
  for _, inventoryId in ipairs(shift.issuedInventoryIds or {}) do
    if employment.services.insurance().inventoryVehNeedsRepair(inventoryId) then
      return true
    end
  end
  return false
end

function M.isCompanyTrailer(employment, vehInfo, vehId)
  local caps = employment.services.loanerCapabilities()
  if caps then
    return caps.isInventoryTrailer(vehInfo, vehId)
  end
  if vehInfo and vehInfo.model and isTrailerModel(vehInfo.model) then return true end
  local obj = vehId and getObjectByID(vehId)
  if obj and obj.getField then
    local jbeam = obj:getField("JBeam", "0")
    if jbeam and isTrailerModel(jbeam) then return true end
  end
  return false
end

function M.inventoryVehAsLoanerOffer(employment, vehInfo)
  local caps = employment.services.loanerCapabilities()
  if caps then
    return caps.inventoryVehAsOffer(vehInfo)
  end
  if not vehInfo or not vehInfo.model then return nil end
  local config = vehInfo.config
  if type(config) == "table" then
    if config.partConfigFilename then
      local _, configKey = path.splitWithoutExt(config.partConfigFilename)
      config = configKey
    else
      config = config.key or config.config
    end
  end
  if type(config) ~= "string" or config == "" then return nil end
  return { model = vehInfo.model, config = config }
end

-- Inventory and fleet queries ---------------------------------------------------------------------

function M.collectCompanyInventoryIds(employment)
  local ids, seen = {}, {}
  local function add(id)
    id = tonumber(id) or id
    if id and not seen[id] then
      seen[id] = true
      table.insert(ids, id)
    end
  end
  if employment.getState().shift then
    for _, id in ipairs(employment.getState().shift.issuedInventoryIds or {}) do add(id) end
  end
  if employment.services.inventory() and employment.services.inventory().getVehicles then
    for inventoryId, vehInfo in pairs(employment.services.inventory().getVehicles() or {}) do
      if vehInfo and vehInfo.loanType == "company" then
        local orgId = employment.parts.eligibility.getActiveShiftOrgId()
        if orgId and vehInfo.owningOrganization == orgId then
          add(inventoryId)
        end
      end
    end
  end
  return ids
end

function M.captureIssuedInventoryIds(employment)
  local ids = {}
  if not employment.services.inventory() then return ids end
  local orgId = employment.parts.eligibility.getActiveShiftOrgId()
  for inventoryId, vehInfo in pairs(employment.services.inventory().getVehicles() or {}) do
    if orgId and vehInfo.owningOrganization == orgId and vehInfo.loanType == "company" then
      table.insert(ids, inventoryId)
    end
  end
  return ids
end

function M.inventoryEntriesForIds(employment, ids)
  local vehicles = {}
  if not employment.services.inventory() then return vehicles end
  for _, inventoryId in ipairs(ids or {}) do
    table.insert(vehicles, {
      vehInfo = employment.services.inventory().getVehicles()[inventoryId],
      vehId = employment.services.inventory().getVehicleIdFromInventoryId
        and employment.services.inventory().getVehicleIdFromInventoryId(inventoryId),
    })
  end
  return vehicles
end

function M.companyInventoryHasTrailer(employment)
  if not employment.services.inventory() then return false end
  local vehicles = M.inventoryEntriesForIds(employment, M.collectCompanyInventoryIds(employment))
  local caps = employment.services.loanerCapabilities()
  if caps then
    return caps.inventoryHasTrailer(vehicles)
  end
  for _, entry in ipairs(vehicles) do
    if M.isCompanyTrailer(employment, entry.vehInfo, entry.vehId) then
      return true
    end
  end
  return false
end

function M.companyInventoryHasTowTractor(employment, couplerClass)
  if not employment.services.inventory() then return false end
  local vehicles = M.inventoryEntriesForIds(employment, M.collectCompanyInventoryIds(employment))
  local caps = employment.services.loanerCapabilities()
  if caps then
    return caps.inventoryHasTowTractor(vehicles, couplerClass)
  end
  return false
end

function M.companyInventoryHasRepoTruck(employment, requireTSeriesRollback)
  if not employment.services.inventory() then return false end
  local vehicles = M.inventoryEntriesForIds(employment, M.collectCompanyInventoryIds(employment))
  local caps = employment.services.loanerCapabilities()
  local inventoryHelper = requireTSeriesRollback and caps and caps.inventoryHasTSeriesRollbackRepoTruck
    or caps and caps.inventoryHasRepoTruck
  if inventoryHelper then
    return inventoryHelper(vehicles)
  end
  local repoCheck = requireTSeriesRollback and caps and caps.canDoTSeriesRollbackRepoJob
    or caps and caps.canDoRepoJob
  if not repoCheck then return false end
  for _, entry in ipairs(vehicles) do
    local offer = M.inventoryVehAsLoanerOffer(employment, entry.vehInfo)
    if offer and repoCheck(offer) then
      return true
    end
  end
  return false
end

function M.canReuseIssuedEquipmentForJob(employment, jobKind, couplerClass, jobOpts)
  local ids = M.captureIssuedInventoryIds(employment)
  if not ids[1] then return false end
  local caps = employment.services.loanerCapabilities()
  if not caps then
    return false
  end
  return caps.canReuseIssuedEquipmentForJob(jobKind, couplerClass, {
    issuedVehicles = M.inventoryEntriesForIds(employment, ids),
    companyVehicles = M.inventoryEntriesForIds(employment, M.collectCompanyInventoryIds(employment)),
    cargoType = jobOpts and jobOpts.cargoType,
    targetLoad = jobOpts and jobOpts.targetLoad,
  })
end

function M.companyVehiclesParked(employment)
  if not employment.services.inventory() then return true end
  local world = {}
  for _, inventoryId in ipairs(M.collectCompanyInventoryIds(employment)) do
    local vehId = employment.services.inventory().getVehicleIdFromInventoryId and employment.services.inventory().getVehicleIdFromInventoryId(inventoryId)
    if vehId and vehId >= 0 and getObjectByID(vehId) then
      table.insert(world, {
        vehId = vehId,
        vehInfo = employment.services.inventory().getVehicles()[inventoryId],
      })
    end
  end
  if #world == 0 then return true end

  local truckSpots = M.getLoanerTruckSpots(employment)
  local fac = employment.parts.backhaul.getEmployerFacility()
  local trailerSpots = (fac and fac.loanerTrailerSpots) or truckSpots
  if not truckSpots or not truckSpots[1] then
    return false
  end

  local parkedTrucks = {}
  for _, entry in ipairs(world) do
    if not M.isCompanyTrailer(employment, entry.vehInfo, entry.vehId) then
      if not M.vehicleParkedInSpots(employment, entry.vehId, truckSpots) then return false end
      parkedTrucks[entry.vehId] = true
    end
  end
  for _, entry in ipairs(world) do
    if M.isCompanyTrailer(employment, entry.vehInfo, entry.vehId) then
      local puller = core_trailerRespawn and core_trailerRespawn.getAttachedNonTrailer(entry.vehId)
      if not (puller and parkedTrucks[puller]) then
        if not M.vehicleParkedInSpots(employment, entry.vehId, trailerSpots) then return false end
      end
    end
  end
  return true
end

-- Routing and parking ----------------------------------------------------------------------------

function M.forEachSpot(_ctx, spots, fn)
  if type(spots) ~= "table" then return end
  if spots[1] then
    for _, spot in ipairs(spots) do fn(spot) end
  else
    for _, spot in pairs(spots) do
      if type(spot) == "table" then fn(spot) end
    end
  end
end

function M.getLoanerTruckSpots(employment)
  local spots = {}
  local seen = {}
  local function addFrom(fac)
    if not fac then return end
    M.forEachSpot(employment, fac.loanerNonTrailerSpots, function(spot)
      if type(spot) == "table" and spot.pos and not seen[spot] then
        seen[spot] = true
        table.insert(spots, spot)
      end
    end)
  end
  local facId = (employment.getState().shift and employment.getState().shift.originFacId) or employment.getState().homeFacId
  if facId then
    addFrom(overhaul_world_facilities.getFacility("deliveryProvider", facId))
  end
  local gen = employment.services.generator()
  addFrom(gen and gen.getFacilityById(facId))
  addFrom(employment.parts.backhaul.getEmployerFacility())
  return spots
end

function M.vehicleParkedInSpots(employment, vehId, spots)
  local parked = false
  M.forEachSpot(employment, spots, function(spot)
    if parked or not spot then return end
    if spot.checkParking then
      local valid = spot:checkParking(vehId, 0, 8, 2.5)
      if valid then parked = true end
    elseif spot.containsPoint then
      local center = vec3(be:getObjectOOBBCenterXYZ(vehId))
      if spot:containsPoint(center) then parked = true end
    elseif spot.pos then
      local obj = getObjectByID(vehId)
      if obj then
        local pos = obj:getPosition()
        local maxDim = 8
        if spot.scl then
          maxDim = math.max(math.abs(spot.scl.x or 8), math.abs(spot.scl.y or 8), 8)
        end
        if pos:squaredDistance(spot.pos) <= (maxDim * maxDim) then parked = true end
      end
    end
  end)
  return parked
end

function M.routeToCompanyTruck(employment)
  if employment.services.inventory() and employment.services.inventory().getVehicleIdFromInventoryId then
    for _, inventoryId in ipairs(M.collectCompanyInventoryIds(employment)) do
      local vehId = employment.services.inventory().getVehicleIdFromInventoryId(inventoryId)
      if vehId and vehId >= 0 then
        local vehInfo = employment.services.inventory().getVehicles()[inventoryId]
        if not M.isCompanyTrailer(employment, vehInfo, vehId) then
          local obj = getObjectByID(vehId)
          if obj then
            local pos = obj:getPosition()
            if freeroam_bigMapMode then
              freeroam_bigMapMode.setNavFocus(pos)
            end
            if core_groundMarkers then
              core_groundMarkers.setPath({pos}, {clearPathOnReachingTarget = false})
            end
            employment.parts.routing.refreshDeliveryPois()
            return true
          end
        end
      end
    end
  end
  return employment.parts.routing.routeToYard()
end

function M.playerInIssuedCompanyTruck(employment)
  if not (employment.services.inventory() and employment.services.inventory().getInventoryIdFromVehicleId) then
    return false
  end
  local vehId = be:getPlayerVehicleID(0)
  if not vehId or vehId < 0 then return false end
  local inventoryId = employment.services.inventory().getInventoryIdFromVehicleId(vehId)
  local vehInfo = inventoryId and employment.services.inventory().getVehicles()[inventoryId]
  return vehInfo and vehInfo.loanType == "company" and vehInfo.owningOrganization == employment.parts.eligibility.getActiveShiftOrgId()
end

function M.beginCompanyVehiclePickupRoute(employment)
  local shift = employment.getState().shift
  if not shift or M.playerInIssuedCompanyTruck(employment) then return false end
  shift.awaitingCompanyVehicleEntry = true
  return M.routeToCompanyTruck(employment)
end

function M.getParkRoutePos(employment)
  local spots = M.getLoanerTruckSpots(employment)
  local playerVehId = be:getPlayerVehicleID(0)
  local fromPos
  if playerVehId and playerVehId >= 0 then
    local obj = getObjectByID(playerVehId)
    fromPos = obj and obj:getPosition() or nil
  end
  local best, bestDist
  for _, spot in ipairs(spots) do
    if spot.pos then
      local dist = fromPos and fromPos:squaredDistance(spot.pos) or 0
      if not best or dist < bestDist then
        best, bestDist = spot.pos, dist
      end
    end
  end
  return best
end

function M.routeToParkStall(employment)
  local pos = M.getParkRoutePos(employment)
  if not pos then return false end
  if freeroam_bigMapMode then
    freeroam_bigMapMode.setNavFocus(pos)
  end
  if core_groundMarkers then
    core_groundMarkers.setPath({pos}, {clearPathOnReachingTarget = false})
  end
  if freeroam_bigMapMode then
    freeroam_bigMapMode.resetRoute()
  end
  employment.parts.routing.refreshDeliveryPois()
  return true
end

-- Handoffs and clearing --------------------------------------------------------------------------

function M.returnIssuedVehicles(employment)
  if not employment.services.loaners() then return end
  issued.returnCompany(employment.services.loaners(), function() return M.collectCompanyInventoryIds(employment) end)
end

function M.deleteCargoOnCompanyVehicles(employment)
  local parcelMgr = employment.services.parcelManager()
  if not (parcelMgr and parcelMgr.getAllCargoInVehicles and parcelMgr.changeCargoLocation) then return end
  local issuedInv = {}
  for _, inventoryId in ipairs(M.collectCompanyInventoryIds(employment) or {}) do
    issuedInv[tonumber(inventoryId) or inventoryId] = true
  end
  if not next(issuedInv) then return end
  local inventory = employment.services.inventory()
  for _, cargo in ipairs(parcelMgr.getAllCargoInVehicles(true) or {}) do
    local vehId = cargo and cargo.location and cargo.location.vehId
    local invId = vehId and inventory and inventory.getInventoryIdFromVehicleId(vehId)
    if invId and issuedInv[tonumber(invId) or invId] and cargo.id then
      parcelMgr.changeCargoLocation(cargo.id, { type = "deleted" })
    end
  end
end

function M.deleteOrphanedVehicleCargo(employment)
  local parcelMgr = employment.services.parcelManager()
  if not (parcelMgr and parcelMgr.getAllCargoInVehicles and parcelMgr.changeCargoLocation) then return end
  for _, cargo in ipairs(parcelMgr.getAllCargoInVehicles(true) or {}) do
    local vehId = cargo and cargo.location and cargo.location.vehId
    if cargo.id and vehId and not be:getObjectByID(vehId) then
      if cargo._transientMove and parcelMgr.clearTransientMoveForCargo then
        parcelMgr.clearTransientMoveForCargo(cargo.id)
      end
      parcelMgr.changeCargoLocation(cargo.id, { type = "deleted" })
    end
  end
end

function M.clearCompanyEquipmentThen(employment, callback)
  if core_groundMarkers then
    core_groundMarkers.setPath(nil)
  end
  if freeroam_bigMapMode then
    freeroam_bigMapMode.resetRoute()
  end
  local canReturn = employment.services.loaners() and employment.services.loaners().returnVehicle
  local ids = canReturn and M.collectCompanyInventoryIds(employment) or {}
  if not canReturn or not ids[1] then
    if callback then callback() end
    return
  end
  M.deleteCargoOnCompanyVehicles(employment)
  M.deleteOrphanedVehicleCargo(employment)
  issued.returnCompany(employment.services.loaners(), ids, callback)
end

function M.handoffCompanyEquipmentThen(employment, callback)
  local previousHandoff = employment.getState().companyEquipmentHandoff
  employment.getState().companyEquipmentHandoff = true
  M.clearCompanyEquipmentThen(employment, function(returned)
    employment.getState().companyEquipmentHandoff = previousHandoff
    if callback then callback(returned) end
  end)
end

-- Issuing and spawning ---------------------------------------------------------------------------

function M.markIssued(employment, offer)
  if not offer or not employment.services.loaners() then return end
  local serviceFacId = employment.getState().shift and employment.getState().shift.shiftOrgId and employment.getState().shift.originFacId
  issued.issueCompany(employment.services.loaners(), offer,
    serviceFacId or (employment.getState().shift and employment.getState().shift.originFacId) or employment.getState().homeFacId, "employment")
end

function M.shiftLoanerKind(employment, shift)
  if employment.parts.dropOff.isBundleShift(shift) then return "repo" end
  if employment.parts.dropOff.isDistributorHaulShift(shift) then return "trailer" end
  return shift and shift.jobKind
end

function M.bundleNeedsRepoTruckSpawn(employment, shift)
  if not employment.parts.dropOff.isBundleShift(shift) then return false end
  return not M.companyInventoryHasRepoTruck(employment, shift.requireTSeriesRollback)
end

function M.issueBundleRepoTruck(employment, fac, onReady)
  local caps = employment.services.loanerCapabilities()
  local loanerOpts = {
    requireTSeriesRollback = employment.getState().shift and employment.getState().shift.requireTSeriesRollback or nil,
  }
  local truck = caps and caps.getIssuedLoanersForFacility(fac, "repo", loanerOpts) or nil
  if not truck then
    return false, employment.parts.dispatch.diagnoseLoanerFailure(fac, { kind = "repo" }, loanerOpts)
  end
  M.markIssued(employment, truck)
  M.spawnCompanyOffers(employment, onReady)
  return true
end

function M.spawnAssignedWork(employment, onSpawned)
  local shift = employment.getState().shift
  if not shift then return false end
  if employment.shared.kindPolicy(shift.jobKind).trailerDelivery and shift.assignedOfferId then
    local mgr = employment.services.vehicleOffers()
    if mgr and mgr.spawnAssignedOffer then
      mgr.spawnAssignedOffer(shift.assignedOfferId, false, onSpawned)
      return true
    end
  end
  if (employment.shared.kindPolicy(shift.jobKind).vehicleDelivery or employment.parts.dropOff.isBundleShift(shift))
      and (shift.assignedOfferId or (shift.assignedOfferIds and shift.assignedOfferIds[1])) then
    local mgr = employment.services.vehicleOffers()
    if mgr and mgr.spawnAssignedOffer then
      M.spawnAssignedVehicleOffers(employment, onSpawned)
      return true
    end
  end
  return false
end

function M.spawnCompanyOffers(employment, onReady)
  issued.spawnMarked(employment.services.loaners(), onReady)
end

-- Offers this shift still has to spawn: assigned and not yet delivered.
local function undeliveredOfferIds(shift)
  local delivered = idSetOf(shift.deliveredOfferIds)
  local ids = {}
  for _, id in ipairs(shift.assignedOfferIds or { shift.assignedOfferId }) do
    if id and not delivered[id] then
      table.insert(ids, id)
    end
  end
  return ids
end

-- A distributor haul stages its offers at the facility before the first one spawns.
local function stageDistributorOffers(employment, shift, mgr, ids)
  local gen = employment.services.generator()
  local facId = shift.originFacId or employment.getState().homeFacId
  local fac = gen and gen.getFacilityById and facId and gen.getFacilityById(facId)
  local toStage = {}
  for _, id in ipairs(ids) do
    local offer = mgr.getOfferById and mgr.getOfferById(id)
    if offer then table.insert(toStage, offer) end
  end
  employment.parts.dropOff.stageDistributorHaulOffers(fac, toStage)
end

function M.spawnAssignedVehicleOffers(employment, onDone)
  local shift = employment.getState().shift
  local mgr = employment.services.vehicleOffers()
  if not (shift and mgr and mgr.spawnAssignedOffer) then
    if onDone then onDone(false) end
    return
  end
  local ids = undeliveredOfferIds(shift)
  if not ids[1] then
    if onDone then onDone(true) end
    return
  end
  if employment.parts.dropOff.isDistributorHaulShift(shift) then
    stageDistributorOffers(employment, shift, mgr, ids)
  end
  local left = #ids
  local ok = true
  local failReason = nil
  for _, id in ipairs(ids) do
    mgr.spawnAssignedOffer(id, false, function(success, reason)
      if success == false then
        ok = false
        if reason == "occupied" then failReason = "occupied" end
      end
      left = left - 1
      if left <= 0 and onDone then
        onDone(ok, failReason)
      end
    end)
  end
end

-- Blocked spawns: watching and extending ---------------------------------------------------------

function M.cancelSpawnBlockedWatch(employment)
  screen.markerOwner, screen.markerCorners = nil, nil
  local shift = employment.getState().shift
  if not shift or not shift.spawnBlocked then return end
  shift.spawnBlocked.token = (shift.spawnBlocked.token or 0) + 1
  shift.spawnBlocked = nil
  if freeroam_bigMapMode then
    freeroam_bigMapMode.setNavFocus(nil)
  end
  if core_groundMarkers then
    core_groundMarkers.setPath(nil)
  end
end

function M.extendAssignedOfferExpiryWhileBlocked(employment, shift)
  shift = shift or employment.getState().shift
  if not shift then return end
  local mgr = employment.services.vehicleOffers()
  if not (mgr and mgr.getOfferById) then return end
  local ids = {}
  if shift.assignedOfferId then ids[#ids + 1] = shift.assignedOfferId end
  for _, id in ipairs(shift.assignedOfferIds or {}) do
    ids[#ids + 1] = id
  end
  local now = (employment.services.general() and employment.services.general().time and employment.services.general().time()) or 0
  for _, offerId in ipairs(ids) do
    local offer = mgr.getOfferById(offerId)
    if offer then
      offer.offerExpiresAt = math.max(tonumber(offer.offerExpiresAt) or 0, now + OFFER_HOLD_SECONDS)
      offer._spawning = nil
    end
  end
end

-- Blocked spawns: which spots matter ------------------------------------------------------------

local function addSpotOnce(spots, seen, spot)
  if type(spot) ~= "table" or not spot.pos then return end
  local key = (spot.getPath and spot:getPath()) or spot
  if seen[key] then return end
  seen[key] = true
  spots[#spots + 1] = spot
end

local function spawnBlockedFacility(employment, shift)
  local facId = (shift and shift.originFacId) or employment.getState().homeFacId
  local fac = employment.services.generator() and employment.services.generator().getFacilityById and employment.services.generator().getFacilityById(facId)
  if facId then
    fac = overhaul_world_facilities.getFacility("deliveryProvider", facId) or fac
  end
  return fac
end

-- Only authored loaner spots can be blocked company spawn locations.
local function addFacilityLoanerSpots(employment, shift, fac, spots, seen)
  if not employment.parts.dropOff.isDistributorHaulShift(shift) or not M.companyInventoryHasTowTractor(employment) then
    for _, spot in ipairs(fac.loanerNonTrailerSpots or {}) do addSpotOnce(spots, seen, spot) end
  end
  if not employment.parts.dropOff.isDistributorHaulShift(shift) or not M.companyInventoryHasTrailer(employment) then
    for _, spot in ipairs(fac.loanerTrailerSpots or {}) do addSpotOnce(spots, seen, spot) end
  end
end

-- The spawn spot of each undelivered offer, plus the loader access points that serve its origin.
local function addOfferSpots(employment, shift, spots, seen)
  local mgr = employment.services.vehicleOffers()
  local offerIds = {}
  if shift.assignedOfferId then offerIds[#offerIds + 1] = shift.assignedOfferId end
  for _, id in ipairs(shift.assignedOfferIds or {}) do offerIds[#offerIds + 1] = id end
  for _, offerId in ipairs(offerIds) do
    local offer = mgr and mgr.getOfferById and mgr.getOfferById(offerId)
    if not (offer and offer.spawned) then
      local psPath = offer and offer.spawnLocation and offer.spawnLocation.psPath
      local ps = psPath and employment.services.generator() and employment.services.generator().getParkingSpotByPath and employment.services.generator().getParkingSpotByPath(psPath)
      addSpotOnce(spots, seen, ps)
      local originFac = offer and offer.origin and offer.origin.facId
        and employment.services.generator() and employment.services.generator().getFacilityById and employment.services.generator().getFacilityById(offer.origin.facId)
      local logisticType = offer and offer.task and offer.task.lookupType
      if originFac and logisticType then
        for _, accessPoint in pairs(originFac.accessPointsByName or {}) do
          if accessPoint.logisticTypesProvidedLookup and accessPoint.logisticTypesProvidedLookup[logisticType] then
            addSpotOnce(spots, seen, accessPoint.ps)
          end
        end
      end
    end
  end
end

function M.collectSpawnBlockedSpots(employment, shift, needs)
  shift = shift or employment.getState().shift
  local spots, seen = {}, {}
  local fac = spawnBlockedFacility(employment, shift)
  if fac and (not needs or needs.needCompanyLoaner) then
    addFacilityLoanerSpots(employment, shift, fac, spots, seen)
  end
  local policy = shift and employment.shared.kindPolicy(shift.jobKind)
  if shift and (not needs or needs.needAssignedOffers)
      and (policy.trailerDelivery or policy.vehicleDelivery or employment.parts.dropOff.isBundleShift(shift)) then
    addOfferSpots(employment, shift, spots, seen)
  end
  return spots
end

-- Blocked spawns: occupancy ----------------------------------------------------------------------

-- Whether the spots are free, and which vehicles still stand on them (moving ones count as not settled).
local function scanSpotOccupancy(spots)
  local occupantIds, seen, moving = {}, {}, false
  local occupied = false
  local reservation = require('overhaul/lib/parking/reservation')
  for _, spot in ipairs(spots) do
    reservation.clearParkedOccupants(spot)
    local status, ids = reservation.getSpotOccupants(spot)
    if status ~= 'empty' then
      occupied = true
      for _, vehId in ipairs(ids or {}) do
        if not seen[vehId] then
          seen[vehId] = true
          occupantIds[#occupantIds + 1] = vehId
          local obj = getObjectByID(vehId)
          local vel = obj and obj.getVelocity and obj:getVelocity()
          if vel and vel:squaredLength() > MOVING_SPEED_SQ then
            moving = true
          end
        end
      end
    end
  end
  return occupied, moving, occupantIds
end

-- The blocked spots, recollected when the needs of a loaner retry changed.
local function currentBlockedSpots(employment, blocked)
  local spots = (blocked and blocked.spots) or M.collectSpawnBlockedSpots(employment)
  if blocked and blocked.needCompanyLoaner ~= nil and employment.getState().shift then
    local shift = employment.getState().shift
    local needCompanyLoaner = blocked.needCompanyLoaner
    if blocked.retryKind ~= "accidentReplacement" then
      needCompanyLoaner = needCompanyLoaner and M.spawnBlockedNeedsCompanyLoaner(employment, shift)
    end
    spots = M.collectSpawnBlockedSpots(employment, shift, {
      needCompanyLoaner = needCompanyLoaner,
      needAssignedOffers = blocked.needAssignedOffers and M.spawnBlockedNeedsAssignedOffers(employment, shift),
    })
    blocked.spots = spots
  end
  return spots
end

-- A trailer parked on its return offer's spawn spot counts as clear without the spot scan.
local function returnTrailerSpawnClear(employment, blocked)
  local shift = employment.getState().shift
  local mgr = employment.services.vehicleOffers and employment.services.vehicleOffers()
  if not (blocked and not blocked.needCompanyLoaner and shift and employment.shared.kindPolicy(shift.jobKind).trailerDelivery
      and shift.phase == "return" and mgr and mgr.getAvailableTrailerSpawnSpot) then
    return false
  end
  local offer = shift.assignedOfferId and mgr.getOfferById(shift.assignedOfferId)
  return offer and offer._employmentReturnTrailer and mgr.getAvailableTrailerSpawnSpot(offer) and true or false
end

function M.inspectSpawnBlockedOccupancy(employment, blocked)
  if returnTrailerSpawnClear(employment, blocked) then
    return true, false, {}, blocked.spots or {}
  end
  local spots = currentBlockedSpots(employment, blocked)
  local occupied, moving, occupantIds = scanSpotOccupancy(spots)
  return not occupied, moving, occupantIds, spots
end

function M.spawnBlockedNeedsCompanyLoaner(employment, shift)
  shift = shift or employment.getState().shift
  if not shift then return false end
  if employment.shared.kindPolicy(shift.jobKind).trailerDelivery then
    return not M.companyInventoryHasTowTractor(employment, shift.couplerClass)
  end
  if employment.parts.dropOff.isDistributorHaulShift(shift) then
    return not M.companyInventoryHasTowTractor(employment) or not M.companyInventoryHasTrailer(employment)
  end
  local policy = employment.shared.kindPolicy(shift.jobKind)
  if policy.parcels or policy.materialContract or policy.repossession or policy.roleplay
      or employment.parts.dropOff.isBundleShift(shift) then
    local hasIssued = shift.issuedInventoryIds and shift.issuedInventoryIds[1]
    if hasIssued then return false end
    return not M.collectCompanyInventoryIds(employment)[1]
  end
  return false
end

function M.spawnBlockedNeedsAssignedOffers(employment, shift)
  shift = shift or employment.getState().shift
  if not shift then return false end
  local policy = employment.shared.kindPolicy(shift.jobKind)
  if not (policy.trailerDelivery or policy.vehicleDelivery or employment.parts.dropOff.isBundleShift(shift)) then
    return false
  end
  local mgr = employment.services.vehicleOffers()
  if not (mgr and mgr.getOfferById) then return false end
  local ids = {}
  if shift.assignedOfferId then ids[#ids + 1] = shift.assignedOfferId end
  for _, id in ipairs(shift.assignedOfferIds or {}) do ids[#ids + 1] = id end
  if not ids[1] then return false end
  for _, offerId in ipairs(ids) do
    local offer = mgr.getOfferById(offerId)
    if offer and not offer.spawned then
      return true
    end
  end
  return false
end

-- Blocked spawns: entering, routing and clearing -------------------------------------------------

function M.routeToSpawnBlockedArea(employment, spots)
  spots = spots or M.collectSpawnBlockedSpots(employment)
  local best
  for _, spot in ipairs(spots or {}) do
    if spot.pos then
      best = spot.pos
      break
    end
  end
  if not best then return false end
  if freeroam_bigMapMode then
    freeroam_bigMapMode.setNavFocus(best)
  end
  if core_groundMarkers then
    core_groundMarkers.setPath({best}, {clearPathOnReachingTarget = false})
  end
  return true
end

function M.clearSpawnBlockedState(employment, success)
  local shift = employment.getState().shift
  if not shift or not shift.spawnBlocked then return end
  shift.spawnBlocked.token = (shift.spawnBlocked.token or 0) + 1
  shift.spawnBlocked = nil
  screen.markerOwner, screen.markerCorners = nil, nil
  if success and freeroam_bigMapMode then
    freeroam_bigMapMode.setNavFocus(nil)
  end
  employment.parts.projections.refreshTaskGuidance(true)
  employment.parts.projections.notifyUi()
end

function M.enterSpawnBlockedState(employment, opts)
  opts = opts or {}
  local shift = employment.getState().shift
  if not shift then return false end
  local spots = M.collectSpawnBlockedSpots(employment, shift, opts)
  local clear, moving, occupantIds = M.inspectSpawnBlockedOccupancy(employment, {spots = spots})
  local prevToken = shift.spawnBlocked and shift.spawnBlocked.token or 0
  local alreadyWaiting = shift.spawnBlocked ~= nil
  shift.spawnBlocked = {
    token = prevToken + 1,
    needCompanyLoaner = opts.needCompanyLoaner and true or false,
    needAssignedOffers = opts.needAssignedOffers and true or false,
    retryKind = opts.retryKind,
    spots = spots,
    occupantIds = occupantIds,
    occupantMoving = moving,
    ready = clear,
    accum = 0,
    retryInFlight = nil,
  }
  M.extendAssignedOfferExpiryWhileBlocked(employment, shift)
  M.routeToSpawnBlockedArea(employment, spots)
  employment.parts.projections.purgeIndependentTasklist()
  employment.parts.projections.refreshTaskGuidance(true)
  if not alreadyWaiting then
    ui_message("Clear the highlighted spawn area, then select Spawn vehicle at the facility or in Employment.", 8, "warning")
  end
  employment.parts.projections.notifyUi()
  employment.shared.shiftLog("spawn blocked", string.format("needLoaner=%s needOffers=%s clear=%s occupants=%d",
    tostring(shift.spawnBlocked.needCompanyLoaner), tostring(shift.spawnBlocked.needAssignedOffers),
    tostring(clear), #(occupantIds or {})))
  return true
end

function M.jobFromShiftForActivation(employment, shift)
  shift = shift or employment.getState().shift
  if not shift then return nil end
  return {
    kind = shift.jobKind,
    offerId = shift.assignedOfferId,
    offerIds = shift.assignedOfferIds,
    assignedContractId = shift.assignedContractId,
    cargoIds = shift.assignedCargoIds,
    couplerClass = shift.couplerClass,
    distributorHaul = shift.distributorHaul,
    label = shift.outboundLabel,
  }
end

-- Blocked spawns: retry --------------------------------------------------------------------------

-- Backhaul returns re-spawn their own vehicle first, whether the blocked piece was a loaner or an offer.
local function returnsBackhaulFirst(employment, shift)
  return (employment.shared.kindPolicy(shift.jobKind).vehicleDelivery and shift.phase == "return"
      and shift.returnIsBackhaul and not employment.parts.dropOff.isDistributorHaulShift(shift))
    or (employment.parts.dropOff.isBundleHaulBackhaulPending(shift) and shift.returnIsBackhaul)
end

-- The offers are spawned: the work activates, or a backhaul return re-spawns its own vehicle.
local function resumeAssignedOffers(employment, shift)
  if returnsBackhaulFirst(employment, shift) then
    M.clearSpawnBlockedState(employment, true)
    employment.parts.routing.trySpawnAssignedReturnVehicle()
    return
  end
  local job = M.jobFromShiftForActivation(employment, shift)
  startDeliveryModeIfAvailable(employment)
  employment.parts.routing.activateAssignedWork(job)
end

-- Truck, and trailer for trailer and distributor jobs, re-issued with the same rules as the shift start.
local function issueRetryLoaners(employment, shift)
  local facId = shift.originFacId or employment.getState().homeFacId
  local fac = employment.services.generator() and employment.services.generator().getFacilityById and employment.services.generator().getFacilityById(facId)
  local caps = employment.services.loanerCapabilities()
  local loanerOpts = {
    cargoType = shift.cargoType,
    targetLoad = shift.targetLoad,
    couplerClass = shift.couplerClass,
  }
  local truck, trailer
  if employment.parts.eligibility.isRoleplayProfile(shift.jobKind) then
    loanerOpts.selection = shift.roleplayVehicleSelection
    truck = caps and caps.getIssuedRoleplayVehicleForFacility(fac, loanerOpts) or nil
  elseif employment.parts.dropOff.isDistributorHaulShift(shift) then
    if caps then truck, trailer = caps.getIssuedLoanersForFacility(fac, "trailer", loanerOpts) end
  elseif employment.shared.kindPolicy(M.shiftLoanerKind(employment, shift)).materialContract then
    truck, trailer = employment.parts.eligibility.getIssuedEmploymentMaterials(fac, shift.cargoType, shift.targetLoad)
  else
    truck = caps and caps.getIssuedLoanersForFacility(fac, M.shiftLoanerKind(employment, shift), loanerOpts) or nil
  end
  return truck, trailer
end

-- Runs when the re-issued loaners have spawned: either the blocked spot is still busy, or the rest of the assignment resumes.
local function afterLoanerRetry(employment, shift, blocked, stillValid)
  if not stillValid() then return end
  shift.issuedInventoryIds = M.captureIssuedInventoryIds(employment)
  local batch = employment.services.loaners() and employment.services.loaners().consumeLastSpawnBatchResult
    and employment.services.loaners().consumeLastSpawnBatchResult()
  if M.spawnBlockedNeedsCompanyLoaner(employment, shift) then
    blocked.retryInFlight = nil
    if batch and batch.occupiedBlocked then
      M.routeToSpawnBlockedArea(employment, blocked.spots)
      return
    end
    M.cancelSpawnBlockedWatch(employment)
    employment.parts.routing.handleAssignmentStartFailure("Company vehicle did not spawn at the yard.")
    return
  end
  if M.spawnBlockedNeedsAssignedOffers(employment, shift) then
    resumeAssignedOffers(employment, shift)
    return
  end
  blocked.retryInFlight = nil
  M.clearSpawnBlockedState(employment, true)
  startDeliveryModeIfAvailable(employment)
  local job = M.jobFromShiftForActivation(employment, shift)
  if job and (employment.shared.kindPolicy(job.kind).parcels or employment.shared.kindPolicy(job.kind).materialContract
      or employment.shared.kindPolicy(job.kind).repossession or employment.shared.kindPolicy(job.kind).roleplay) then
    employment.parts.routing.activateAssignedWork(job)
  else
    employment.parts.routing.routeCurrentAssignment()
    employment.parts.projections.refreshActiveTaskGuidance()
  end
end

local function retryWithCompanyLoaners(employment, shift, blocked, stillValid)
  local truck, trailer = issueRetryLoaners(employment, shift)
  local distributor = employment.parts.dropOff.isDistributorHaulShift(shift)
  if not truck or (distributor and not trailer) then
    blocked.retryInFlight = nil
    M.cancelSpawnBlockedWatch(employment)
    employment.parts.routing.handleAssignmentStartFailure("No company truck is available for this assignment.")
    return
  end
  if not distributor or not M.companyInventoryHasTowTractor(employment) then M.markIssued(employment, truck) end
  if trailer and (not employment.shared.kindPolicy(shift.jobKind).trailerDelivery or distributor) then
    if not M.companyInventoryHasTrailer(employment) then M.markIssued(employment, trailer) end
  end
  M.spawnCompanyOffers(employment, function() afterLoanerRetry(employment, shift, blocked, stillValid) end)
end

function M.attemptSpawnBlockedRetry(employment)
  local shift = employment.getState().shift
  local blocked = shift and shift.spawnBlocked
  if not blocked or blocked.retryInFlight then return end
  local clear = M.inspectSpawnBlockedOccupancy(employment, blocked)
  if not clear then return end
  local token = blocked.token
  local isCurrent = employment.parts.projections.makeAssignmentGuard()
  local function stillValid()
    return isCurrent() and employment.getState().shift and employment.getState().shift.spawnBlocked == blocked
      and blocked.token == token
  end

  blocked.retryInFlight = true
  M.extendAssignedOfferExpiryWhileBlocked(employment, shift)
  employment.shared.shiftLog("spawn blocked retry", "area clear; retrying missing equipment")

  if M.spawnBlockedNeedsCompanyLoaner(employment, shift) then
    retryWithCompanyLoaners(employment, shift, blocked, stillValid)
    return
  end
  if M.spawnBlockedNeedsAssignedOffers(employment, shift) then
    resumeAssignedOffers(employment, shift)
    return
  end
  blocked.retryInFlight = nil
  M.clearSpawnBlockedState(employment, true)
  employment.parts.routing.routeCurrentAssignment()
  employment.parts.projections.refreshActiveTaskGuidance()
end

-- Per-frame update -------------------------------------------------------------------------------

function M.tickSpawnBlockedWatch(employment, dtSim)
  local shift = employment.getState().shift
  local blocked = shift and shift.spawnBlocked
  if not blocked or blocked.retryInFlight or not employment.lifecycle.isOnShift() then return end
  M.drawSpawnBlockedArea(employment, blocked)
  blocked.accum = (blocked.accum or 0) + (tonumber(dtSim) or 0)
  local interval = blocked.occupantMoving and MOVING_RECHECK_SECONDS or IDLE_RECHECK_SECONDS
  if blocked.accum < interval then return end
  blocked.accum = 0
  local clear, moving, occupantIds, spots = M.inspectSpawnBlockedOccupancy(employment, blocked)
  blocked.occupantMoving = moving
  blocked.occupantIds = occupantIds
  blocked.spots = spots
  M.extendAssignedOfferExpiryWhileBlocked(employment, shift)
  if blocked.ready ~= clear then
    blocked.ready = clear
    employment.parts.projections.refreshTaskGuidance(true)
    employment.parts.projections.notifyUi()
    if overhaul_integration_services_markerInteraction then overhaul_integration_services_markerInteraction.setForceReevaluateOpenPrompt() end
  end
end

-- Markers ----------------------------------------------------------------------------------------

-- Four ground corners around a spot, lifted off the surface, with the outward axes for the marker posts.
local function spotMarkerCorners(spot)
  local corners = {}
  local x = vec3(1, 0, 0):rotated(spot.rot)
  local y = vec3(0, 1, 0):rotated(spot.rot)
  for _, sx in ipairs({-1, 1}) do
    for _, sy in ipairs({-1, 1}) do
      local pos = spot.pos + x * sx * spot.scl.x * 0.5 + y * sy * spot.scl.y * 0.5
      local hit = Engine.castRay(pos + vec3(0, 0, 5), pos - vec3(0, 0, 10), true, false)
      pos = (hit and vec3(hit.pt) or pos) + vec3(0, 0, 0.12)
      corners[#corners + 1] = {pos = pos, x = x * -sx, y = y * -sy}
    end
  end
  return corners
end

function M.drawSpawnBlockedArea(_ctx, blocked)
  if screen.markerOwner ~= blocked then
    screen.markerOwner = blocked
    screen.markerCorners = {}
  end
  local color = ColorF(1, 0.05, 0.05, 1)
  for _, spot in ipairs(blocked.spots or {}) do
    if spot.pos and spot.rot and spot.scl then
      local corners = screen.markerCorners[spot]
      if not corners then
        corners = spotMarkerCorners(spot)
        screen.markerCorners[spot] = corners
      end
      local center = vec3(0, 0, 0)
      for _, corner in ipairs(corners) do center = center + corner.pos end
      center = center * 0.25
      local direction = vec3(0, 1, 0):rotated(spot.rot)
      local fill = blocked.ready and ColorF(0.15, 1, 0.25, 0.25) or ColorF(1, 0.6, 0.05, 0.25)
      debugDrawer:drawSquarePrism(center - direction * spot.scl.y * 0.5,
        center + direction * spot.scl.y * 0.5, Point2F(0.15, spot.scl.x), Point2F(0.15, spot.scl.x), fill)
      if not blocked.ready then
        for _, corner in ipairs(corners) do
          debugDrawer:drawCylinder(corner.pos, corner.pos + corner.x, 0.07, color)
          debugDrawer:drawCylinder(corner.pos, corner.pos + corner.y, 0.07, color)
          debugDrawer:drawCylinder(corner.pos, corner.pos + vec3(0, 0, 0.6), 0.07, color)
        end
      end
    end
  end
end

function M.getBlockedSpawnStatus(employment)
  local blocked = employment.getState().shift and employment.getState().shift.spawnBlocked
  if not blocked or not employment.lifecycle.isOnShift() then return nil end
  local veh = getPlayerVehicle(0)
  local pos = veh and veh:getPosition()
  local nearby = false
  for _, spot in ipairs(blocked.spots or {}) do
    if pos and spot.pos and (pos - spot.pos):squaredLength() <= SPAWN_BLOCKED_NEARBY_M * SPAWN_BLOCKED_NEARBY_M then
      nearby = true
      break
    end
  end
  return {ready = blocked.ready == true and not blocked.retryInFlight, nearby = nearby}
end

-- Context -----------------------------------------------------------------------------------------

-- Built once per instance and reused by every call.
local function equipmentContext(inputs)
  local runtime, shared = inputs.runtime, inputs.shared
  if runtime.equipmentContextCache then return runtime.equipmentContextCache end
  runtime.equipmentContextCache = {
    getState = function() return inputs.state end,
    parts = inputs.parts,
    shared = inputs.shared,
    lifecycle = inputs.lifecycle,
    services = {
      loanerCapabilities = shared.loanerCapabilities,
      parcelManager = shared.parcelManager,
      general = shared.general,
      generator = shared.generator,
      vehicleOffers = shared.vehicleOffers,
      inventory = function() return overhaul_career_garage_inventory end,
      loaners = function() return overhaul_career_logistics_loanerVehicles end,
      insurance = function() return overhaul_career_repair_insurance end,
    },
  }
  return runtime.equipmentContextCache
end

-- Binding -----------------------------------------------------------------------------------------

local EQUIPMENT_CONTEXT_OPERATIONS = {
  issuedVehicleNeedsRepair = true,
  collectCompanyInventoryIds = true,
  deleteCargoOnCompanyVehicles = true,
  deleteOrphanedVehicleCargo = true,
  returnIssuedVehicles = true,
  clearCompanyEquipmentThen = true,
  handoffCompanyEquipmentThen = true,
  playerInIssuedCompanyTruck = true,
  markIssued = true,
  captureIssuedInventoryIds = true,
  shiftLoanerKind = true,
  bundleNeedsRepoTruckSpawn = true,
  issueBundleRepoTruck = true,
  forEachSpot = true,
  inventoryEntriesForIds = true,
  isCompanyTrailer = true,
  inventoryVehAsLoanerOffer = true,
  companyInventoryHasTrailer = true,
  companyInventoryHasTowTractor = true,
  companyInventoryHasRepoTruck = true,
  canReuseIssuedEquipmentForJob = true,
  routeToCompanyTruck = true,
  beginCompanyVehiclePickupRoute = true,
  vehicleParkedInSpots = true,
  companyVehiclesParked = true,
  getLoanerTruckSpots = true,
  getParkRoutePos = true,
  routeToParkStall = true,
  spawnAssignedWork = true,
  spawnCompanyOffers = true,
  spawnAssignedVehicleOffers = true,
  cancelSpawnBlockedWatch = true,
  extendAssignedOfferExpiryWhileBlocked = true,
  collectSpawnBlockedSpots = true,
  inspectSpawnBlockedOccupancy = true,
  routeToSpawnBlockedArea = true,
  clearSpawnBlockedState = true,
  enterSpawnBlockedState = true,
  spawnBlockedNeedsCompanyLoaner = true,
  spawnBlockedNeedsAssignedOffers = true,
  jobFromShiftForActivation = true,
  attemptSpawnBlockedRetry = true,
  tickSpawnBlockedWatch = true,
  drawSpawnBlockedArea = true,
  getBlockedSpawnStatus = true,
}

local function installEquipmentOperations(inputs)
  local api = require("overhaul/career/work/employment/operations").new {
    api = inputs.api,
    operations = M,
    context = function() return equipmentContext(inputs) end,
    withContext = EQUIPMENT_CONTEXT_OPERATIONS,
  }
  return api
end

local function installCompanyVehicleEntry(api)
  api.stepOutIfInInventoryIds = function(idSet)
    local vehId = be:getPlayerVehicleID(0)
    if not vehId or vehId < 0 then return end
    local inventoryId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(vehId)
    if not (inventoryId and idSet[inventoryId]) then return end
    spawn.preventPlayerSpawning = nil
    if gameplay_walk then gameplay_walk.setWalkingMode(true, nil, nil, true) end
  end

  api.detachVehicleTrailers = function(vehId)
    local veh = vehId and scenetree.findObjectById(vehId)
    if veh and veh.queueLuaCommand then
      veh:queueLuaCommand("if beamstate and beamstate.detachAll then beamstate.detachAll() end")
    end
  end

  api.enterCompanyTractor = function(opts)
    opts = type(opts) == "table" and opts or {}
    local skipInv = {}
    if opts.skipInventoryId then
      skipInv[opts.skipInventoryId] = true
      skipInv[tonumber(opts.skipInventoryId) or opts.skipInventoryId] = true
    end
    local function tryEnter()
      for _, inventoryId in ipairs(api.collectCompanyInventoryIds()) do
        local invN = tonumber(inventoryId) or inventoryId
        if skipInv[inventoryId] or skipInv[invN] then goto continueTractor end
        local vehId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId)
        local vehInfo = overhaul_career_garage_inventory.getVehicles()[inventoryId]
        if vehId and not api.isCompanyTrailer(vehInfo, vehId) then
          spawn.preventPlayerSpawning = nil
          overhaul_career_garage_inventory.enterVehicle(inventoryId)
          return true
        end
        ::continueTractor::
      end
      return false
    end
    if tryEnter() then return true end
    core_jobsystem.create(function(job)
      for _ = 1, 32 do
        job.sleep(0.25)
        if tryEnter() then return end
      end
    end)
    return false
  end
end

function M.new(inputs)
  local api = installEquipmentOperations(inputs)
  api.equipmentContext = function() return equipmentContext(inputs) end
  installCompanyVehicleEntry(api)
  return api
end

return M
