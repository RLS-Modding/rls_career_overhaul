-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding

-- Facility placement of loaner vehicles using owner-supplied helpers.
-- Company vehicles preserve reserved spot order and clear only ambient parked traffic.
local M = {}
local parkingReservation = require('overhaul/lib/parking/reservation')

-- Use the spot's placement math so box centering and facing remain identical.
local function plantLoanerAt(services, spot, vehId, worldPos)
  if not spot or not vehId then return false end
  local offset = vec3(0, 0, 0)
  if worldPos then
    local back = services.flattenXY(quat(spot.rot) * vec3(0, -1, 0), vec3(0, -1, 0))
    local right = services.flattenXY(vec3(-back.y, back.x, 0), vec3(1, 0, 0))
    local delta = worldPos - spot.pos
    offset = vec3(right:dot(delta), back:dot(delta), 0)
  end
  spot:moveResetVehicleTo(vehId, false, false, offset, nil, false, true, true)
  return true
end

-- Empty stall: plant at the marker. Occupied stalls report occupied; parked ambient traffic may be relocated once.
local function teleportLoanerToSpot(services, vehObj, vehId, spot, _isTrailer)
  if not vehObj or not spot or not spot.pos or not spot.rot then return false, "noSpace" end

  if not parkingReservation.clearParkedOccupants(spot, vehId) then
    return false, "occupied"
  end

  plantLoanerAt(services, spot, vehId, nil)
  return true
end

-- The facility's inspect spot, when it is free.
local function teleportLoanerNearInspect(services, fac, _vehObj, vehId)
  local inspectSpot = services.getInspectParkingSpot(fac)
  if not inspectSpot then return false, "noSpace" end
  if not parkingReservation.clearParkedOccupants(inspectSpot, vehId) then
    return false, "occupied"
  end
  plantLoanerAt(services, inspectSpot, vehId, nil)
  return true
end

-- The preferred spot first (the trailer's first spot, or the best parking spot for the vehicle), then the rest, once each.
local function orderedSpots(vehId, spots, isTrailer)
  local ordered, seen = {}, {}
  local function addSpot(spot)
    if spot and not seen[spot] then
      seen[spot] = true
      ordered[#ordered + 1] = spot
    end
  end
  local preferred = isTrailer and spots[1]
    or (gameplay_sites_sitesManager and gameplay_sites_sitesManager.getBestParkingSpotForVehicleFromList
      and gameplay_sites_sitesManager.getBestParkingSpotForVehicleFromList(vehId, spots))
    or spots[1]
  addSpot(preferred)
  for _, spot in ipairs(spots) do
    addSpot(spot)
  end
  return ordered
end

-- Tries each spot in order. Returns the placed spot, or nil and whether any stall was occupied.
local function placeInOrder(services, vehObj, vehId, ordered, isTrailer, companyPlacement)
  local sawOccupied = false
  for _, parkingSpot in ipairs(ordered) do
    local placed, reason = nil, nil
    if companyPlacement then
      if not parkingSpot.hasAnyVehicles or not parkingSpot.pos or not parkingSpot.rot then
        reason = "noSpace"
      elseif not parkingReservation.clearParkedOccupants(parkingSpot, vehId) then
        reason = "occupied"
      else
        placed = plantLoanerAt(services, parkingSpot, vehId, nil)
      end
    else
      placed, reason = teleportLoanerToSpot(services, vehObj, vehId, parkingSpot, isTrailer)
    end
    if placed then
      return parkingSpot
    end
    if reason == "occupied" then
      sawOccupied = true
    end
  end
  return nil, sawOccupied
end

-- Places a loaner only at the facility's authored spawn spots, in order.
local function teleportLoanerToFacility(services, fac, vehObj, vehId, offer, _waitForPhysics)
  if not fac or not vehObj or not vehId then return false, nil, "noSpace" end
  local configInfo = offer and services.getConfigInfo(offer.model, offer.config) or nil
  local modelKey = offer and offer.model or vehObj:getField('JBeam', '0')
  local isTrailer = services.isTrailerVehicle(configInfo, modelKey)
  local spots = isTrailer and fac.loanerTrailerSpots or fac.loanerNonTrailerSpots
  local companyPlacement = offer and (offer.loanType == "company" or offer._fromEmploymentPool)
  if spots and spots[1] then
    local placedSpot, sawOccupied = placeInOrder(services, vehObj, vehId, orderedSpots(vehId, spots, isTrailer),
      isTrailer, companyPlacement)
    if placedSpot then return true, placedSpot end
    if sawOccupied then return false, nil, "occupied" end
    return false, nil, "noSpace"
  end
  log('W', 'loanerPlacement', 'No authored loaner spawn priorities at facility ' .. tostring(fac.id))
  return false, nil, "noSpace"
end

-- One placement per loaner extension load. The methods read their lookups from `services`, filled by bind().
function M.create()
  local services = {}
  return {
    plantLoanerAt = function(...) return plantLoanerAt(services, ...) end,
    teleportLoanerToSpot = function(...) return teleportLoanerToSpot(services, ...) end,
    teleportLoanerNearInspect = function(...) return teleportLoanerNearInspect(services, ...) end,
    teleportLoanerToFacility = function(...) return teleportLoanerToFacility(services, ...) end,
    bind = function(deps)
      services.flattenXY = deps.flattenXY
      services.getConfigInfo = deps.getConfigInfo
      services.getInspectParkingSpot = deps.getInspectParkingSpot
      services.isTrailerVehicle = deps.isTrailerVehicle
    end,
  }
end

return M
