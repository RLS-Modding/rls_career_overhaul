-- Seats a visible driver in vehicles that drive themselves (AI cabs and the like).
-- The seat system's dummy occupant does the drawing: body, pose and weight come from the vehicle's own occupant
-- part in its driver seat, so any vehicle with such a seat works and others simply keep their empty seat.
-- Read claims, show and clear, seat system events, reload note, then public API and hooks.
local M = {}
M.dependencies = {'overhaul_vehicles_legacyDriverSeat'}

local passengerSeats = require('overhaul/lib/vehicles/passengerSeats')

-- gameplay_seatOccupants is a level preset, so it is read at call time and not a dependency.

-- State -------------------------------------------------------------------------------------------

-- The driver seats this extension claimed: vehicleId -> seatId. A feature shows and clears by vehicle id.
local claims = {}

-- Show and clear ---------------------------------------------------------------------------------

-- clearDummyOccupant only ever removes a dummy, so a player who took the seat meanwhile stays seated. The seat
-- system keeps no owner for dummies: another feature's dummy on this seat could not be told from ours, which is why
-- a driver is only ever claimed on a free seat.
local function release(vehicleId, seatId)
  local api = gameplay_seatOccupants
  if api and api.clearDummyOccupant then api.clearDummyOccupant(vehicleId, seatId) end
end

-- Whether the driver seat is claimed afterwards. The seat system draws dummies by the player's seat-occupants
-- setting, so with that setting off the seat is still claimed and nothing is drawn.
local function show(vehicleId)
  local api = gameplay_seatOccupants
  if not (vehicleId and api and api.setDummyOccupant) then return false end
  -- Older all-passenger layouts get their driver seat resolved first.
  local legacy = overhaul_vehicles_legacyDriverSeat
  if legacy then legacy.refresh(vehicleId) end
  local seat = passengerSeats.driverSeat(vehicleId)
  local previous = claims[vehicleId]
  if not seat then
    -- The vehicle lost its driver seat (a rebuild without the occupant part). The seat system dropped our dummy with
    -- it, so the claim is forgotten and not released: what sits there now is not ours.
    claims[vehicleId] = nil
    return false
  end
  if previous == seat.seatId and seat.occupantType == 'dummy' then return true end
  if previous then
    release(vehicleId, previous)
    claims[vehicleId] = nil
  end
  -- A player or another feature's occupant is never replaced.
  if seat.occupied then return false end
  if not api.setDummyOccupant(vehicleId, seat.seatId) then return false end
  claims[vehicleId] = seat.seatId
  return true
end

local function clear(vehicleId)
  local seatId = claims[vehicleId]
  if not seatId then return end
  claims[vehicleId] = nil
  release(vehicleId, seatId)
end

-- Traffic's whole-vehicle fade also reveals the meshes in empty occupant slots. Reapply our existing
-- claim through the seat API once the fade finishes; it draws the driver and hides every empty seat.
local function refresh(vehicleId)
  local seatId = claims[vehicleId]
  local api = gameplay_seatOccupants
  if not (seatId and api and api.getSeats and api.setDummyOccupant) then return end
  for _, seat in ipairs(api.getSeats(vehicleId)) do
    if seat.seatId == seatId and seat.occupantType == 'dummy' then
      api.setDummyOccupant(vehicleId, seatId)
      return
    end
  end
end

local function clearAll()
  local previous = claims
  claims = {}
  for vehicleId, seatId in pairs(previous) do release(vehicleId, seatId) end
end

-- Seat system events ------------------------------------------------------------------------------

-- The seat system drops every dummy when a vehicle's seat layout changes or the vehicle is rebuilt, and reports it
-- with no player. A job first runs on the job system's next update, after that pass is over, so the driver is
-- claimed again there, unless the drive ended meanwhile.
local function onSeatOccupantExit(player, vehicleId)
  if player ~= nil or not claims[vehicleId] then return end
  core_jobsystem.create(function()
    if claims[vehicleId] then show(vehicleId) end
  end)
end

-- Lua reload -------------------------------------------------------------------------------------

-- Nothing is saved across a reload: the engine serializes every extension and then unloads them all while the seat
-- system is still loaded, and the seat system hands out its claims by reference. Unloading releases ours from that
-- table before it is written out, so no claim comes back after the reload.

-- Public API --------------------------------------------------------------------------------------

M.show = show
M.clear = clear
M.refresh = refresh

-- Game hooks --------------------------------------------------------------------------------------

-- The vehicle's own destruction already dropped the seat system's claim.
M.onVehicleDestroyed = function(vehicleId) claims[vehicleId] = nil end
M.onSeatOccupantExit = onSeatOccupantExit
M.onClientEndMission = clearAll
M.onExtensionUnloaded = clearAll
M.onOverhaulBeforeSetProfile = clearAll
M.onOverhaulActive = function(active) if active == false then clearAll() end end

return M
