-- Dyno rebuilds must preserve driving permission rather than choose a nearby passenger seat.
local M = {}
function M.enter(vehicle)
  if not vehicle then return false end
  local id = vehicle:getID()
  local api = gameplay_seatOccupants
  if api and api.getSeats and api.requestEnterSeat then
    if overhaul_vehicles_legacyDriverSeat then overhaul_vehicles_legacyDriverSeat.refresh(id) end
    local presence = api.getPlayerPresence and api.getPlayerPresence(0)
    for _, seat in ipairs(api.getSeats(id) or {}) do
      if seat.isDriver then
        -- requestEnterSeat toggles walking when already seated here.
        if presence and presence.vehicleId == id and presence.seatId == seat.seatId then
          if presence.permissionMode == 'driver' then return true end
          return api.setOccupied(id, seat.seatId, 0)
        end
        return api.requestEnterSeat(id, seat.seatId, 0) == true
      end
    end
    -- Legacy/modded cars can have no occupant driver slot. Native unseated driving
    -- explicitly clears any passenger transition left over from the replacement.
    if api.requestUnseatedPresence then return api.requestUnseatedPresence(0, id, 'unrestricted') == true end
  end
  if be and be.enterVehicle then be:enterVehicle(0, vehicle) end
  return true
end
return M
