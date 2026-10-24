-- Parking bays from different sites files can cover the same physical space.
local M = {}

function M.bounds(spot)
  if not (spot and spot.pos and spot.rot and spot.scl and vec3 and overlapsOBB_OBB) then return nil end
  return {center = spot.pos, x = spot.rot * vec3(spot.scl.x / 2, 0, 0),
    y = spot.rot * vec3(0, spot.scl.y / 2, 0), z = spot.rot * vec3(0, 0, spot.scl.z / 2)}
end

function M.overlaps(a, b)
  return a and b and overlapsOBB_OBB(a.center, a.x, a.y, a.z, b.center, b.x, b.y, b.z) or false
end

-- Include partial box overlaps, even for cars not tracked by map.objects.
function M.addVehicleOccupants(bounds, occupants, ignoredVehId)
  if not (bounds and getAllVehicles) then return end
  local seen = {}
  for _, id in ipairs(occupants) do seen[id] = true end
  for _, vehicle in ipairs(getAllVehicles()) do
    local id = vehicle:getID()
    if id ~= ignoredVehId and not seen[id] and vehicle:getActive() then
      local box = vehicle:getSpawnWorldOOBB()
      local half = box:getHalfExtents()
      if M.overlaps(bounds, {center = box:getCenter(), x = box:getAxis(0) * half.x,
        y = box:getAxis(1) * half.y, z = box:getAxis(2) * half.z}) then
        occupants[#occupants + 1] = id
      end
    end
  end
end

return M
