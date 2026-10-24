-- Passenger-service seating uses the resolved occupant layout, not model names.
local M = {}
M.rearRowSeparationMeters = 0.35
local sideThresholdMeters = 0.05
local sameRowToleranceMeters = 0.01
local exitClearanceMeters = 0.9
local enteringSeat = {}

local function kerbSign()
  local roads = rawget(_G, 'map')
  local rules = roads and roads.getRoadRules and roads.getRoadRules()
  return rules and rules.rightHandDrive and 1 or -1 -- vehicle +X is left
end

local function cameraPosition(vdata, camera)
  local node = camera and vdata.nodes and vdata.nodes[camera.camNodeID]
  return node and node.pos
end

function M.candidates(vehicleId)
  local api = rawget(_G, 'gameplay_seatOccupants')
  local manager, camera = rawget(_G, 'core_vehicle_manager'), rawget(_G, 'core_camera')
  if not (api and api.getSeats and manager and manager.getVehicleData and camera and camera.getCameraDataById) then return {} end
  local data = manager.getVehicleData(vehicleId)
  local vdata = data and data.vdata
  local cameras = camera.getCameraDataById(vehicleId)
  if not (vdata and cameras) then return {} end
  local seats = api.getSeats(vehicleId)
  local frontY
  for _, seat in ipairs(seats) do
    local pos = cameraPosition(vdata, cameras[seat.cameraName or ('occupant.' .. seat.seatId)])
    if seat.isDriver and pos then frontY = pos.y break end
  end
  -- Legacy driver cameras can coexist with passenger occupant slots.
  local driverPos = cameraPosition(vdata, cameras['onboard.driver'] or cameras.driver)
  frontY = frontY or (driverPos and driverPos.y)
  local candidates = {}
  for _, seat in ipairs(seats) do
    local name = seat.cameraName or ('occupant.' .. seat.seatId)
    local pos = cameraPosition(vdata, cameras[name])
    if not seat.isDriver and seat.defaultPermissionMode == 'passenger'
        and (not seat.occupied or seat.player == 0) and pos then
      candidates[#candidates + 1] = {seatId = seat.seatId, cameraName = name, pos = pos}
    end
  end
  -- Without a driver anchor, the foremost occupant row is the front row.
  if not frontY then
    for _, seat in ipairs(candidates) do frontY = math.min(frontY or seat.pos.y, seat.pos.y) end
  end
  local side = kerbSign()
  for _, seat in ipairs(candidates) do seat.rear = seat.pos.y > frontY + M.rearRowSeparationMeters end
  table.sort(candidates, function(a, b)
    if a.rear ~= b.rear then return a.rear end
    local aKerb, bKerb = a.pos.x * side > sideThresholdMeters, b.pos.x * side > sideThresholdMeters
    if aKerb ~= bKerb then return aKerb end
    if math.abs(a.pos.y - b.pos.y) > sameRowToleranceMeters then return a.pos.y < b.pos.y end
    return a.seatId < b.seatId
  end)
  return candidates
end

-- The driver's seat as the seat system reports it, once the vehicle's occupant part is installed there.
-- Without that part (older or modded layouts) there is no body to draw, so nothing is returned.
function M.driverSeat(vehicleId)
  local api = rawget(_G, 'gameplay_seatOccupants')
  if not (vehicleId and api and api.getSeats) then return end
  for _, seat in ipairs(api.getSeats(vehicleId)) do
    if seat.isDriver and seat.partPath then return seat end
  end
end

function M.board(vehicleId, preferredSeatId)
  local api = rawget(_G, 'gameplay_seatOccupants')
  -- Cancel the walking entry's pending driver-seat transition before assigning a seat.
  if api and api.requestUnseatedPresence then api.requestUnseatedPresence(0, vehicleId, 'passenger') end
  if not (api and api.setOccupied) then return end
  preferredSeatId = preferredSeatId or enteringSeat[vehicleId]
  local candidates = M.candidates(vehicleId)
  for i, seat in ipairs(candidates) do
    if seat.seatId == preferredSeatId then table.remove(candidates, i); table.insert(candidates, 1, seat); break end
  end
  for _, seat in ipairs(candidates) do
    if api.setOccupied(vehicleId, seat.seatId, 0, nil, 'passenger') then return seat.cameraName end
  end
end

function M.enter(vehicleId, preferredSeat)
  local api = rawget(_G, 'gameplay_seatOccupants')
  if not api then return end
  local candidates = M.candidates(vehicleId)
  if preferredSeat then
    for i, seat in ipairs(candidates) do
      if seat.seatId == preferredSeat.seatId then table.remove(candidates, i); table.insert(candidates, 1, seat); break end
    end
  end
  if #candidates > 0 and api.requestEnterSeat then
    for _, seat in ipairs(candidates) do
      -- The service's switch hook may choose another free passenger seat.
      enteringSeat[vehicleId] = seat.seatId
      local ok, result = pcall(api.requestEnterSeat, vehicleId, seat.seatId, 0, 'passenger')
      enteringSeat[vehicleId] = nil
      if not ok then error(result) end
      local presence = api.getPlayerPresence and api.getPlayerPresence(0)
      if presence and presence.vehicleId == vehicleId and presence.permissionMode == 'passenger' and presence.seatId then
        for _, actual in ipairs(M.candidates(vehicleId)) do
          if actual.seatId == presence.seatId then return true, actual end
        end
      end
      if result then return true, seat end
    end
    return false
  end
  if api.requestUnseatedPresence then
    local entered = api.requestUnseatedPresence(0, vehicleId, 'passenger')
    return entered -- Native failure reasons are not resolved seat records.
  end
end

function M.forDoor(vehicleId, side)
  local candidates = M.candidates(vehicleId)
  -- Keep the rear-first fallback, preferring the seat beside the selected doorway.
  for _, seat in ipairs(candidates) do
    if seat.rear == (candidates[1] and candidates[1].rear)
        and seat.pos.x * (side == 'R' and -1 or 1) > sideThresholdMeters then return seat end
  end
  return candidates[1]
end

function M.exitPosition(vehicleId)
  local vehicle = getObjectByID(vehicleId)
  if not vehicle then return end
  local box = vehicle:getSpawnWorldOOBB()
  local center, half, left = box:getCenter(), box:getHalfExtents(), box:getAxis(0)
  local api = rawget(_G, 'gameplay_seatOccupants')
  local anchor = api and api.getSeatExitData and api.getSeatExitData(0, vehicleId) or center
  -- Preserve the seat's longitudinal position but always clear the kerb-side body.
  return anchor + left * (kerbSign() * (half.x + exitClearanceMeters) - (anchor - center):dot(left))
end

return M
