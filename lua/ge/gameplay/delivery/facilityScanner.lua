-- Shared facility discovery functions
-- Extracted from career/modules/delivery/generator.lua
-- These functions require the map to be loaded but NOT career mode.

local M = {}

-------------------------------
-- Facility Scanning
-------------------------------

-- Gets ALL delivery facilities on the current map.
-- Tries gameplay_sites_sitesManager.getFacilities() first (returns all facilities),
-- falls back to freeroam_facilities.getFacilitiesByType("deliveryProvider").
-- Returns the facilities list, or empty table if unavailable.
function M.scanFacilities()
  -- Primary: sitesManager has all facilities
  if gameplay_sites_sitesManager and gameplay_sites_sitesManager.getFacilities then
    local facs = gameplay_sites_sitesManager.getFacilities()
    if facs and next(facs) then
      return facs
    end
  end

  -- Fallback: freeroam_facilities
  if freeroam_facilities then
    if freeroam_facilities.getFacilities then
      local facs = freeroam_facilities.getFacilities()
      if facs and next(facs) then
        return facs
      end
    end
    -- Last resort: get by type
    if freeroam_facilities.getFacilitiesByType then
      return freeroam_facilities.getFacilitiesByType("deliveryProvider") or {}
    end
  end

  log("W", "facilityScanner", "No facility source available")
  return {}
end

-------------------------------
-- Facility Processing
-------------------------------

-- Helper: convert array values to lookup dict {val=true}
local function tableValuesAsLookupDict(t)
  local lookup = {}
  if t then
    for _, v in ipairs(t) do
      lookup[v] = true
    end
  end
  return lookup
end

-- Mirrors generator.lua setupFacilities() logic for building logistic type lookups.
-- Takes raw facilities list and builds logisticTypesProvidedLookup / logisticTypesReceivedLookup
-- on each facility from their logistic types and generator definitions.
-- Also maps generatorType -> direction for lookup validation.
local generatorTypeToDirection = {
  parcelProvider = "providedSystemsLookup",
  parcelReceiver = "receivedSystemsLookup",
  vehOfferProvider = "providedSystemsLookup",
  trailerOfferProvider = "providedSystemsLookup",
  materialProvider = "providedSystemsLookup",
  materialReceiver = "receivedSystemsLookup",
}

function M.processFacilities(rawFacilities)
  if not rawFacilities then return {} end

  for _, fac in ipairs(rawFacilities) do
    -- Build logistic type lookups from facility data
    fac.logisticTypesProvided = fac.logisticTypesProvided or {}
    fac.logisticTypesReceived = fac.logisticTypesReceived or {}

    fac.logisticTypesProvidedLookup = tableValuesAsLookupDict(fac.logisticTypesProvided)
    fac.logisticTypesReceivedLookup = tableValuesAsLookupDict(fac.logisticTypesReceived)

    fac.providedSystemsLookup = fac.providedSystemsLookup or {}
    fac.receivedSystemsLookup = fac.receivedSystemsLookup or {}

    fac.logisticGenerators = fac.logisticGenerators or {}

    -- Validate generator logistic types against facility lookups
    for _, generator in ipairs(fac.logisticGenerators) do
      generator.logisticTypes = generator.logisticTypes or {}
      generator.logisticTypesLookup = tableValuesAsLookupDict(generator.logisticTypes)

      for _, logisticType in ipairs(generator.logisticTypes) do
        if generatorTypeToDirection[generator.type] == "providedSystemsLookup" then
          if not fac.logisticTypesProvidedLookup[logisticType] then
            fac.logisticTypesProvidedLookup[logisticType] = true
          end
        end
        if generatorTypeToDirection[generator.type] == "receivedSystemsLookup" then
          if not fac.logisticTypesReceivedLookup[logisticType] then
            fac.logisticTypesReceivedLookup[logisticType] = true
          end
        end
      end

      if generator.type == "vehOfferProvider" then
        fac.providedSystemsLookup.vehicleDelivery = true
      end
      if generator.type == "trailerOfferProvider" then
        fac.providedSystemsLookup.trailerDelivery = true
      end
    end

    -- Build access point logistic type lookups
    if fac.accessPointsByName then
      for _, ap in pairs(fac.accessPointsByName) do
        if ap.logisticTypesProvided then
          ap.logisticTypesProvidedLookup = tableValuesAsLookupDict(ap.logisticTypesProvided)
        end
        if ap.logisticTypesReceived then
          ap.logisticTypesReceivedLookup = tableValuesAsLookupDict(ap.logisticTypesReceived)
        end
      end
    end
  end

  return rawFacilities
end

-------------------------------
-- Facilities by Logistic Type
-------------------------------

-- Returns facilities that can provide or receive a given logistic type.
-- direction: "provided" or "received"
function M.getFacilitiesByLogisticType(logisticType, direction)
  local facilities = M.scanFacilities()
  facilities = M.processFacilities(facilities)
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
