-- Shared facility discovery functions
-- Extracted from career/modules/delivery/generator.lua
-- These functions require the map to be loaded but NOT career mode.

local M = {}

-------------------------------
-- Facility Scanning
-------------------------------

-- Wraps freeroam_facilities to get all delivery facilities on the current map.
-- Returns the facilities list from freeroam_facilities, or empty table if unavailable.
function M.scanFacilities()
  if not freeroam_facilities or not freeroam_facilities.getFacilitiesByType then
    log("W", "facilityScanner", "freeroam_facilities not available")
    return {}
  end
  return freeroam_facilities.getFacilitiesByType("deliveryProvider") or {}
end

-------------------------------
-- Facilities by Logistic Type
-------------------------------

-- Returns facilities that can provide or receive a given logistic type.
-- direction: "provided" or "received"
function M.getFacilitiesByLogisticType(logisticType, direction)
  local facilities = M.scanFacilities()
  local lookupKey = direction == "received" and "logisticTypesReceivedLookup" or "logisticTypesProvidedLookup"
  local result = {}
  for _, fac in ipairs(facilities) do
    if fac[lookupKey] and fac[lookupKey][logisticType] then
      table.insert(result, fac)
    end
  end
  return result
end

-------------------------------
-- Distance Between Locations
-------------------------------

-- Exact copy of distanceBetween from generator.lua ~line 93
-- Requires map to be loaded (map.findClosestRoad, map.getPath, map.getMap)
local tmpVec = vec3()
function M.getDistanceBetweenLocations(posA, posB)
  if not map or not map.findClosestRoad then
    log("W", "facilityScanner", "map not available for distance calculation")
    return 1
  end
  local name_a,_,distance_a = map.findClosestRoad(posA)
  local name_b,_,distance_b = map.findClosestRoad(posB)
  if not name_a or not name_b then return 1 end
  local path = map.getPath(name_a, name_b)
  local d = 0
  for i = 1, #path-1 do
    tmpVec:set(   map.getMap().nodes[path[i  ]].pos)
    tmpVec:setSub(map.getMap().nodes[path[i+1]].pos)
    d = d + tmpVec:length()
  end
  d = d + distance_a + distance_b
  return d
end

return M
