-- Owns event traffic suppression and restoration.
-- motorsportEvents.lua supplies venue state; native traffic and parking services retain their original settings.
local M = {}
local previousTraffic, previousParking
local venueKey, lanes = nil, {}
local ENTER_DISTANCE, LEAVE_DISTANCE = 500, 750

function M.onSerialize()
  return {traffic = previousTraffic, parking = previousParking}
end

function M.onDeserialized(data)
  previousTraffic, previousParking = data and data.traffic, data and data.parking
end

local function venueLanes(eventState)
  local key = tostring(eventState.level) .. ':' .. tostring(eventState.stripId) .. ':' .. tostring(eventState.stripFile)
  if key == venueKey then return lanes end
  local core = gameplay_drag_core
  if not core or not core.getDragDataForLevel then return {} end
  for _, data in pairs(core.getDragDataForLevel(eventState.level) or {}) do
    if data.strip and data.strip.id == eventState.stripId then
      lanes = {}
      for _, lane in ipairs(data.strip.lanes or {}) do
        local waypoints = lane.waypoints or {}
        local first = waypoints.spawn or waypoints.stage
        local last = waypoints.stop or waypoints.endLine
        local a = first and first.transform and first.transform.pos
        local b = last and last.transform and last.transform.pos
        if a and b then lanes[#lanes + 1] = {a, b} end
      end
      venueKey = key
      return lanes
    end
  end
  return {}
end

function M.isAtVenue(eventState)
  if not eventState or eventState.level ~= getCurrentLevelIdentifier() then return false end
  local player = be and be:getPlayerVehicle(0)
  if not player then return false end
  local p = player:getPosition()
  local limit = previousTraffic ~= nil and LEAVE_DISTANCE or ENTER_DISTANCE
  for _, lane in ipairs(venueLanes(eventState)) do
    local a, b = lane[1], lane[2]
    local x, y, z = b.x - a.x, b.y - a.y, b.z - a.z
    local length = x * x + y * y + z * z
    local t = length > 0 and math.max(0, math.min(1, ((p.x - a.x) * x + (p.y - a.y) * y + (p.z - a.z) * z) / length)) or 0
    local dx, dy, dz = p.x - a.x - t * x, p.y - a.y - t * y, p.z - a.z - t * z
    if dx * dx + dy * dy + dz * dz <= limit * limit then return true end
  end
  return false
end

local function hasActiveTraffic()
  local data = gameplay_traffic.getTrafficData and gameplay_traffic.getTrafficData()
  if not data or not be or not be.getObjectActive then return false end
  for id, vehicle in pairs(data) do
    if vehicle.isAi and not (vehicle.reserved and vehicle.claimed) and be:getObjectActive(id) then return true end
  end
  return false
end

function M.sync(active, eventState)
  active = active and (eventState and eventState.checkInVersion == 1 and eventState.level == getCurrentLevelIdentifier()
    and eventState.venueArrivalDay ~= nil or M.isAtVenue(eventState))
  if active then
    if not gameplay_traffic or not overhaul_integration_services_parking then return end
    local traffic = gameplay_traffic.getTrafficVars()
    local parking = overhaul_integration_services_parking.getParkingVars()
    if previousTraffic == nil then previousTraffic = traffic.activeAmount end
    if previousParking == nil then previousParking = parking.activeAmount end
    if traffic.activeAmount ~= 0 or hasActiveTraffic() then gameplay_traffic.setActiveAmount(0) end
    if parking.activeAmount ~= 0 then overhaul_integration_services_parking.setActiveAmount(0) end
  else
    if previousTraffic ~= nil and gameplay_traffic then gameplay_traffic.setActiveAmount(previousTraffic) end
    if previousParking ~= nil and overhaul_integration_services_parking then overhaul_integration_services_parking.setActiveAmount(previousParking) end
    previousTraffic, previousParking = nil, nil
  end
end

return M
