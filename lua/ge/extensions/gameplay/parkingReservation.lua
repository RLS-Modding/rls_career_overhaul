local M = {}

local logTag = "parkingReservation"

local function getLiveParkingSpots(parkingSpots)
  return parkingSpots or (gameplay_parking and gameplay_parking.getParkingSpots and gameplay_parking.getParkingSpots())
end

local function getSpotPath(spot)
  if type(spot) == "table" and spot.getPath then
    local ok, path = pcall(function() return spot:getPath() end)
    if ok then
      return path
    end
  end
end

local function resolveLiveSpot(spotOrPathOrName, parkingSpots)
  local liveParkingSpots = getLiveParkingSpots(parkingSpots)
  if not liveParkingSpots then
    log("W", logTag, "Unable to resolve live parking spot; gameplay_parking has no spots loaded")
    return nil
  end

  local spotType = type(spotOrPathOrName)
  if spotType == "table" then
    local directPath = getSpotPath(spotOrPathOrName)
    if directPath then
      for _, liveSpot in pairs(liveParkingSpots.objects or {}) do
        if getSpotPath(liveSpot) == directPath then
          return liveSpot
        end
      end
    end

    if spotOrPathOrName.name and liveParkingSpots.byName then
      return liveParkingSpots.byName[spotOrPathOrName.name]
    end
  elseif spotType == "string" then
    if liveParkingSpots.byName and liveParkingSpots.byName[spotOrPathOrName] then
      return liveParkingSpots.byName[spotOrPathOrName]
    end

    for _, liveSpot in pairs(liveParkingSpots.objects or {}) do
      if getSpotPath(liveSpot) == spotOrPathOrName then
        return liveSpot
      end
    end
  end

  log("W", logTag, string.format("Failed to resolve live parking spot for '%s'", tostring(spotOrPathOrName and spotOrPathOrName.name or spotOrPathOrName)))
  return nil
end

local function isSpotHardBlocked(spot, ownerToken)
  if not spot then return true end
  if spot.customFields and spot.customFields.tags and spot.customFields.tags.ignoreOthers then
    return true
  end

  if spot.ignoreOthers and spot._rlsReservationOwner ~= ownerToken then
    return true
  end

  return false
end

local function getSpotOccupants(spot)
  if not spot or not spot.hasAnyVehicles then return false, {} end

  local ok, hasVehicles, occupants = pcall(function()
    return spot:hasAnyVehicles()
  end)

  if not ok then
    log("W", logTag, string.format("Failed to query parking spot occupants for '%s'", tostring(spot and spot.name)))
    return false, {}
  end

  return hasVehicles and true or false, occupants or {}
end

local function canRelocateOccupants(spot)
  local hasVehicles, occupants = getSpotOccupants(spot)
  if not hasVehicles then
    return true
  end

  local parkedVehData = gameplay_parking and gameplay_parking.getParkedCarsData and gameplay_parking.getParkedCarsData() or {}
  for _, vehId in ipairs(occupants) do
    if not parkedVehData[vehId] then
      return false
    end
  end

  return true
end

local function clearParkedOccupants(spot)
  local hasVehicles, occupants = getSpotOccupants(spot)
  if not hasVehicles then
    return true
  end

  if not canRelocateOccupants(spot) then
    return false
  end

  for _, vehId in ipairs(occupants) do
    log("I", logTag, string.format("Relocating parked vehicle %d from reserved spot '%s'", vehId, tostring(spot.name)))
    gameplay_parking.forceTeleport(vehId)
  end

  local stillOccupied = getSpotOccupants(spot)
  return not stillOccupied
end

local function reserveSpot(spot, ownerToken)
  if not spot or not ownerToken then return false end
  if isSpotHardBlocked(spot, ownerToken) then
    return false
  end

  spot.ignoreOthers = true
  spot._rlsReservationOwner = ownerToken
  log("I", logTag, string.format("Reserved parking spot '%s' for %s", tostring(spot.name), ownerToken))
  return true
end

local function releaseSpot(spot, ownerToken)
  if not spot or not ownerToken then return false end
  if spot._rlsReservationOwner ~= ownerToken then
    return false
  end

  spot.ignoreOthers = nil
  spot._rlsReservationOwner = nil
  log("I", logTag, string.format("Released parking spot '%s' for %s", tostring(spot.name), ownerToken))
  return true
end

local function findReservableSpot(candidates, ownerToken, options)
  options = options or {}
  local liveParkingSpots = getLiveParkingSpots(options.parkingSpots)
  if not liveParkingSpots or not candidates then
    return nil
  end

  for _, candidate in ipairs(candidates) do
    local spot = resolveLiveSpot(candidate, liveParkingSpots)
    if spot and not isSpotHardBlocked(spot, ownerToken) then
      local hasVehicles, occupants = getSpotOccupants(spot)
      if not hasVehicles then
        if reserveSpot(spot, ownerToken) then
          return spot
        end
      elseif canRelocateOccupants(spot) then
        if clearParkedOccupants(spot) and reserveSpot(spot, ownerToken) then
          return spot
        end
      else
        log("I", logTag, string.format("Rejected parking spot '%s' due to non-parked occupant(s)", tostring(spot.name)))
      end
    end
  end

  return nil
end

M.resolveLiveSpot = resolveLiveSpot
M.isSpotHardBlocked = isSpotHardBlocked
M.getSpotOccupants = getSpotOccupants
M.canRelocateOccupants = canRelocateOccupants
M.clearParkedOccupants = clearParkedOccupants
M.reserveSpot = reserveSpot
M.releaseSpot = releaseSpot
M.findReservableSpot = findReservableSpot

return M
