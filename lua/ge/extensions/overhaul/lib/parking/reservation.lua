-- Parking reservations for Overhaul and vanilla providers with isolated state.
-- Each provider resolves live spots; service dispatch selects the current mode on every call.
local logTag = "parkingReservation"
local geometry = require('overhaul/lib/parking/geometry')

-- Helpers -------------------------------------------------------------------------------------------

local function getSpotPath(spot)
  if spot and spot.getPath then
    local ok, path = pcall(function() return spot:getPath() end)
    if ok then
      return path
    end
  end
end

local function getSpotOccupants(spot, ignoredVehId)
  if not spot or type(spot.hasAnyVehicles) ~= "function" then return "unknown", {} end

  local ok, hasVehicles, occupants = pcall(function()
    local occupied, ids = spot:hasAnyVehicles(ignoredVehId)
    -- Copy the engine's result before supplementing it with box overlaps.
    local all = {}
    for _, id in ipairs(ids or {}) do all[#all + 1] = id end
    geometry.addVehicleOccupants(geometry.bounds(spot), all, ignoredVehId)
    return occupied or #all > 0, all
  end)

  if not ok then
    log("W", logTag, string.format("Failed to query parking spot occupants for '%s'", tostring(spot and spot.name)))
    return "unknown", {}
  end

  return hasVehicles and "occupied" or "empty", occupants or {}
end

local function clearTrafficForSpawn(state, vehId)
  local parking = state.parking()
  if parking.clearForSpawn then return parking.clearForSpawn(vehId) end
  -- Stock providers have no spawn-clearing operation; their teleport succeeds
  -- with a nil result. The caller still verifies physical occupancy afterwards.
  return parking.forceTeleport(vehId) ~= false
end

local clearParkedOccupants

local function makeReservationToken(prefix)
  prefix = prefix or "reservation"
  return string.format("%s:%d:%d", prefix, os.time(), math.random(100000, 999999))
end

local function shuffleSpots(spots)
  local shuffled = {}
  for i, spot in ipairs(spots or {}) do
    shuffled[i] = spot
  end

  for i = #shuffled, 2, -1 do
    local j = math.random(i)
    shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
  end

  return shuffled
end

-- Live spot resolution ------------------------------------------------------------------------------

-- The spot table of the parking module, or the table the caller already has.
local function getLiveParkingSpots(state, parkingSpots)
  local parkingModule = state.parking()
  return parkingSpots or (parkingModule and parkingModule.getParkingSpots and parkingModule.getParkingSpots())
end

local function buildPathIndex(state, liveParkingSpots)
  local index = {}
  for _, liveSpot in pairs(liveParkingSpots.objects or {}) do
    local path = getSpotPath(liveSpot)
    if path ~= nil and index[path] == nil then
      index[path] = liveSpot
    end
  end
  state.pathIndex, state.pathIndexSource = index, liveParkingSpots
end

local function findLiveSpotByPath(state, liveParkingSpots, path)
  if path == nil then return nil end
  if state.pathIndexSource ~= liveParkingSpots or not state.pathIndex then
    buildPathIndex(state, liveParkingSpots)
  end
  local hit = state.pathIndex[path]
  local objects = liveParkingSpots.objects
  if hit and (hit.id == nil or (objects and rawget(objects, hit.id) == hit)) then
    return hit
  end
  buildPathIndex(state, liveParkingSpots)
  return state.pathIndex[path]
end

local function resolveLiveSpot(state, spotOrPathOrName, parkingSpots)
  local liveParkingSpots = getLiveParkingSpots(state, parkingSpots)
  if not liveParkingSpots then
    log("W", logTag, "Unable to resolve live parking spot; " .. state.owner .. " has no spots loaded")
    return nil
  end

  local spotType = type(spotOrPathOrName)
  if spotType == "string" then
    local byPath = findLiveSpotByPath(state, liveParkingSpots, spotOrPathOrName)
    if byPath then
      return byPath
    end

    if liveParkingSpots.byName and liveParkingSpots.byName[spotOrPathOrName] then
      return liveParkingSpots.byName[spotOrPathOrName]
    end
  elseif spotOrPathOrName then
    local directPath = getSpotPath(spotOrPathOrName)
    if directPath then
      local byPath = findLiveSpotByPath(state, liveParkingSpots, directPath)
      if byPath then
        return byPath
      end
    end

    if spotOrPathOrName.name and liveParkingSpots.byName then
      return liveParkingSpots.byName[spotOrPathOrName.name]
    end
  end

  log("W", logTag, string.format("Failed to resolve live parking spot for '%s'", tostring(spotOrPathOrName and spotOrPathOrName.name or spotOrPathOrName)))
  return nil
end

-- Delivery reservations -----------------------------------------------------------------------------

-- Delivery destinations are held by path; parked cars are evicted from them.

local function isDeliveryReserved(state, spot)
  local path = getSpotPath(spot)
  local paths = state.pendingDeliveryDestinations or state.deliveryDestinations
  if path ~= nil and paths[path] == true then return true end
  local reservedBounds = state.pendingDeliveryBounds or state.deliveryBounds
  if not next(reservedBounds) then return false end
  local bounds = geometry.bounds(spot)
  for _, reserved in pairs(reservedBounds) do
    if geometry.overlaps(bounds, reserved) then return true end
  end
  return false
end

-- Paths held now that were not held before, or every held path when the spot table itself changed.
local function newlyHeldPaths(state, previous, parkingSpots, paths)
  local newPaths = {}
  for path in pairs(paths) do
    if not previous[path] or parkingSpots ~= state.deliveryParkingSpots then
      newPaths[path] = true
    end
  end
  return newPaths
end

-- Moves the parked cars out of the spots just taken for delivery; the player's own car stays where it is.
local function evictParkedFrom(state, spots, newPaths)
  local rejected = {}
  for path in pairs(newPaths) do
    local spot = spots[path]
    if spot and not clearParkedOccupants(state, spot) then rejected[path] = true end
  end
  return rejected
end

local function setDeliveryDestinations(state, paths, resolveDestination)
  local parkingSpots = getLiveParkingSpots(state)
  local previous = state.deliveryDestinations
  paths = paths or {}
  local spots, bounds = {}, {}
  for path in pairs(paths) do
    local ok, spot = pcall(function()
      if resolveDestination then return resolveDestination(path) end
      return parkingSpots and findLiveSpotByPath(state, parkingSpots, path)
    end)
    if ok and spot then
      spots[path] = spot
      bounds[path] = geometry.bounds(spot)
    end
  end
  local rejected = {}
  if parkingSpots or resolveDestination then
    local newPaths = newlyHeldPaths(state, previous, parkingSpots, paths)
    for path in pairs(paths) do
      if spots[path] ~= state.deliverySpots[path] then newPaths[path] = true end
      if resolveDestination and not spots[path] then rejected[path] = true end
    end
    -- Exclude every requested destination from relocation targets while
    -- eviction runs, without accepting a destination that cannot be cleared.
    state.pendingDeliveryDestinations = paths
    state.pendingDeliveryBounds = bounds
    local ok, result = true, {}
    if next(newPaths) then ok, result = pcall(evictParkedFrom, state, spots, newPaths) end
    state.pendingDeliveryDestinations = nil
    state.pendingDeliveryBounds = nil
    for path in pairs(ok and result or newPaths) do rejected[path] = true end
    if not ok then log("W", logTag, "Failed to clear delivery parking: " .. tostring(result)) end
  end
  if next(rejected) then
    local accepted = {}
    for path, value in pairs(paths) do
      if not rejected[path] then accepted[path] = value end
    end
    state.deliveryDestinations = accepted
  else
    state.deliveryDestinations = paths
  end
  state.deliveryBounds, state.deliverySpots = {}, spots
  for path, box in pairs(bounds) do
    if not rejected[path] then state.deliveryBounds[path] = box end
  end
  state.deliveryParkingSpots = parkingSpots
end

-- Occupants -----------------------------------------------------------------------------------------

-- A spot can be reserved when it is empty, or when every car on it is a parked car that can be moved away and the spot then checks empty.

local function isSpotHardBlocked(state, spot, ownerToken)
  if not spot then return true end
  if isDeliveryReserved(state, spot) then return true end
  if spot.customFields and spot.customFields.tags and spot.customFields.tags.ignoreOthers then
    return true
  end

  if spot.ignoreOthers and spot._rlsReservationOwner ~= ownerToken then
    return true
  end

  return false
end

local function canRelocateOccupants(state, spot, ignoredVehId)
  local status, occupants = getSpotOccupants(spot, ignoredVehId)
  if status == "unknown" then
    return false
  end

  if status == "empty" and (not spot.vehicle or spot.vehicle == ignoredVehId) then
    return true
  end

  local parkingModule = state.parking()
  local parkedVehData = parkingModule and parkingModule.getParkedCarsData and parkingModule.getParkedCarsData() or {}
  local ids = {}
  for _, id in ipairs(occupants) do ids[#ids + 1] = id end
  if spot.vehicle and spot.vehicle ~= ignoredVehId then ids[#ids + 1] = spot.vehicle end
  if not ids[1] then return false end
  for _, vehId in ipairs(ids) do
    if vehId == be:getPlayerVehicleID(0) or not parkedVehData[vehId]
      or (parkingModule.isParkedPoolVehicle and not parkingModule.isParkedPoolVehicle(vehId)) then
      return false
    end
  end

  return true
end

clearParkedOccupants = function(state, spot, ignoredVehId)
  local status, occupants = getSpotOccupants(spot, ignoredVehId)
  if status == "unknown" then
    return false
  end

  if status == "empty" and (not spot.vehicle or spot.vehicle == ignoredVehId) then
    return true
  end

  if not canRelocateOccupants(state, spot, ignoredVehId) then
    return false
  end

  local parkingModule = state.parking()
  if not parkingModule or not (parkingModule.clearForSpawn or parkingModule.forceTeleport) then
    log("W", logTag, string.format("Unable to relocate occupants for '%s'; %s.forceTeleport is unavailable", tostring(spot.name), state.owner))
    return false
  end

  local toMove = {}
  for _, id in ipairs(occupants) do toMove[id] = true end
  if spot.vehicle and spot.vehicle ~= ignoredVehId then toMove[spot.vehicle] = true end
  if not next(toMove) then return false end
  local ignored = spot.ignoreOthers
  spot.ignoreOthers = true
  local ok, cleared = pcall(function()
    for vehId in pairs(toMove) do
      if not clearTrafficForSpawn(state, vehId) then return false end
    end
    return getSpotOccupants(spot, ignoredVehId) == "empty"
  end)
  spot.ignoreOthers = ignored
  return ok and cleared == true
end

-- Reservation operations ----------------------------------------------------------------------------

local function reserveSpot(state, spot, ownerToken)
  if not spot or not ownerToken then return false end
  if isSpotHardBlocked(state, spot, ownerToken) then
    return false
  end
  if not clearParkedOccupants(state, spot) then return false end

  spot.ignoreOthers = true
  spot._rlsReservationOwner = ownerToken
  if state.trackReservations then state.reservations[spot] = ownerToken end
  log("I", logTag, string.format("Reserved parking spot '%s' for %s", tostring(spot.name), ownerToken))
  return true
end

local function releaseSpot(state, spot, ownerToken)
  if not spot or not ownerToken then return false end
  if spot._rlsReservationOwner ~= ownerToken then
    return false
  end

  spot.ignoreOthers = nil
  spot._rlsReservationOwner = nil
  if state.trackReservations then state.reservations[spot] = nil end
  log("I", logTag, string.format("Released parking spot '%s' for %s", tostring(spot.name), ownerToken))
  return true
end

-- Clears every reservation still held, e.g. by a job abandoned when Overhaul stops or the level ends.
local function releaseAll(state)
  local count = 0
  for spot, ownerToken in pairs(state.reservations) do
    if spot._rlsReservationOwner == ownerToken then
      spot.ignoreOthers = nil
      spot._rlsReservationOwner = nil
      count = count + 1
    end
  end
  state.reservations = setmetatable({}, {__mode = "k"})
  state.provider.epoch = state.provider.epoch + 1
  if count > 0 then
    log("I", logTag, string.format("Released %d leftover parking reservation(s)", count))
  end
  return count
end

-- Returns the first candidate that resolves, is not blocked and can be reserved, after relocating any parked cars on it.
local function findReservableSpot(state, candidates, ownerToken, options)
  options = options or {}
  local liveParkingSpots = getLiveParkingSpots(state, options.parkingSpots)
  if not liveParkingSpots or not candidates then
    return nil
  end

  for _, candidate in ipairs(candidates) do
    local spot = resolveLiveSpot(state, candidate, liveParkingSpots)
    if spot and not isSpotHardBlocked(state, spot, ownerToken) then
      local status = getSpotOccupants(spot)
      if status == "empty" then
        if reserveSpot(state, spot, ownerToken) then
          return spot
        end
      elseif status == "occupied" and canRelocateOccupants(state, spot) then
        if clearParkedOccupants(state, spot) and reserveSpot(state, spot, ownerToken) then
          return spot
        end
      elseif status == "occupied" then
        log("I", logTag, string.format("Rejected parking spot '%s' due to non-parked occupant(s)", tostring(spot.name)))
      else
        log("I", logTag, string.format("Skipped parking spot '%s' because occupancy could not be verified", tostring(spot.name)))
      end
    end
  end

  return nil
end

-- Providers -----------------------------------------------------------------------------------------

-- Provider closures remain distinct even when their underlying operation is stateless.
local function newProvider(scope, owner, parking, trackReservations)
  local provider = {scope = scope, owner = owner, epoch = 0}
  local state = {
    provider = provider, owner = owner, parking = parking, trackReservations = trackReservations,
    deliveryDestinations = {}, deliveryBounds = {}, deliverySpots = {}, reservations = setmetatable({}, {__mode = "k"}),
  }

  provider.resolveLiveSpot = function(spotOrPathOrName, parkingSpots)
    return resolveLiveSpot(state, spotOrPathOrName, parkingSpots)
  end
  provider.isDeliveryReserved = function(spot) return isDeliveryReserved(state, spot) end
  provider.setDeliveryDestinations = function(paths, resolveDestination) return setDeliveryDestinations(state, paths, resolveDestination) end
  provider.isSpotHardBlocked = function(spot, ownerToken) return isSpotHardBlocked(state, spot, ownerToken) end
  provider.getSpotOccupants = function(spot, ignoredVehId) return getSpotOccupants(spot, ignoredVehId) end
  provider.canRelocateOccupants = function(spot, ignoredVehId) return canRelocateOccupants(state, spot, ignoredVehId) end
  provider.clearParkedOccupants = function(spot, ignoredVehId) return clearParkedOccupants(state, spot, ignoredVehId) end
  provider.makeReservationToken = function(prefix) return makeReservationToken(prefix) end
  provider.reserveSpot = function(spot, ownerToken) return reserveSpot(state, spot, ownerToken) end
  provider.releaseSpot = function(spot, ownerToken) return releaseSpot(state, spot, ownerToken) end
  -- The vanilla backend keeps no reservation list, so it has nothing to release.
  if trackReservations then provider.releaseAll = function() return releaseAll(state) end end
  provider.shuffleSpots = function(spots) return shuffleSpots(spots) end
  provider.findReservableSpot = function(candidates, ownerToken, options)
    return findReservableSpot(state, candidates, ownerToken, options)
  end
  return provider
end

-- Public API ----------------------------------------------------------------------------------------

-- Dispatch through the current mode rather than retaining the previous parking provider.
local M = newProvider("overhaul", "overhaul_integration_services_parking", function() return overhaul_integration_services_parking end, true)
M.vanilla = newProvider("vanilla", "gameplay_parking", function() return gameplay_parking end, false)

-- Jobs that also run outside Overhaul pick the provider of the running mode on every call.
local service = {}
for name, fn in pairs(M) do
  if type(fn) == "function" then
    service[name] = function(...)
      local provider = overhaul_shell_gameMode and overhaul_shell_gameMode.isActive() and M or M.vanilla
      if not provider[name] then return nil end
      return provider[name](...)
    end
  end
end
M.service = service

return M
