-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding

-- Facility discovery by cargo capabilities; queries need a loaded map but also work outside a career.
-- Part of the Overhaul fork of stock lua/ge/extensions/career/modules/delivery/generator.lua.
local M = {}

-- Each kind names its generator type and how a facility offers it. Offer checks fall back to the facility's lookups for data that predates generators.
local facilityKinds = {
  parcel = {
    provider = "parcelProvider",
    accepts = function(generator, parcelTypes, excludedParcelTypes)
      return M.generatorProvidesParcels(generator, parcelTypes, excludedParcelTypes)
    end,
    offers = function(fac, parcelTypes, excludedParcelTypes)
      for _, generator in ipairs(fac.logisticGenerators or {}) do
        if M.generatorProvidesParcels(generator, parcelTypes, excludedParcelTypes) then return true end
      end
      return fac.logisticTypesProvidedLookup and fac.logisticTypesProvidedLookup.parcel == true
    end,
  },
  trailer = {
    provider = "trailerOfferProvider",
    offers = function(fac)
      if fac.providedSystemsLookup and fac.providedSystemsLookup.trailerDelivery then return true end
      for _, generator in ipairs(fac.logisticGenerators or {}) do
        if generator.type == "trailerOfferProvider" then return true end
      end
      return false
    end,
  },
  materials = {
    provider = "materialProvider",
    offers = function(fac)
      if type(fac.materialStorages) == "table" and next(fac.materialStorages) then return true end
      for _, generator in ipairs(fac.logisticGenerators or {}) do
        if generator.type == "materialProvider" then return true end
      end
      local lookup = fac.logisticTypesProvidedLookup or {}
      return lookup.fluid == true or lookup.dryBulk == true or lookup.cement == true or lookup.cash == true
    end,
  },
  vehicle = {
    provider = "vehOfferProvider",
    offers = function(fac)
      if fac.providedSystemsLookup and fac.providedSystemsLookup.vehicleDelivery then return true end
      for _, generator in ipairs(fac.logisticGenerators or {}) do
        if generator.type == "vehOfferProvider" then return true end
      end
      return false
    end,
  },
}
local unknownFacilityKind = {}

-- Reused scratch vector for summing navgraph segments without allocating per step.
local tmpVec = vec3()

local function getDirectDistance(posA, posB)
  if not posA or not posB then return 0 end
  return posA:distance(posB)
end

function M.generatorProvidesParcels(generator, allowedTypes, excludedTypes)
  if not generator or generator.type ~= "parcelProvider" then return false end
  local types = generator.logisticTypes or {}
  if not types[1] then
    return not allowedTypes
  end
  for _, logisticType in ipairs(types) do
    if not (excludedTypes and excludedTypes[logisticType]) then
      if allowedTypes then
        if allowedTypes[logisticType] then return true end
      else
        return true
      end
    end
  end
  return false
end

function M.facilityOffersKind(fac, kind, parcelTypes, audience, excludedParcelTypes)
  if not fac then return false end
  local descriptor = facilityKinds[kind] or unknownFacilityKind
  if audience then
    local configured = false
    for _, generator in ipairs(fac.logisticGenerators or {}) do
      if generator.type == descriptor.provider then
        if generator.offerMode then
          configured = true
          if generator.offerMode == audience or generator.offerMode == "shared" then
            if not descriptor.accepts or descriptor.accepts(generator, parcelTypes, excludedParcelTypes) then return true end
          end
        elseif not descriptor.accepts or descriptor.accepts(generator, parcelTypes, excludedParcelTypes) then
          return true
        end
      end
    end
    if configured then return false end
  end
  if descriptor.offers then return descriptor.offers(fac, parcelTypes, excludedParcelTypes) end
  return false
end

function M.facilityMaterialTypes(fac, resolveType, allowedTypes, audience)
  local types = {}
  if not fac then return types end
  resolveType = resolveType or require("overhaul/lib/logistics/templates").resolveMaterialBulkType
  local function note(key)
    local bulk = resolveType(key)
    if bulk and (not allowedTypes or allowedTypes[bulk]) then
      types[bulk] = true
    end
  end
  if audience then
    local configured = false
    for _, generator in ipairs(fac.logisticGenerators or {}) do
      if generator.type == "materialProvider" and generator.offerMode then configured = true end
    end
    if configured then
      for _, generator in ipairs(fac.logisticGenerators or {}) do
        if generator.type == "materialProvider" and (not generator.offerMode or generator.offerMode == audience or generator.offerMode == "shared") then
          note(generator.materialType)
        end
      end
      return types
    end
  end
  for key, enabled in pairs(fac.logisticTypesProvidedLookup or {}) do
    if enabled then note(key) end
  end
  for materialType in pairs(fac.materialStorages or {}) do
    note(materialType)
  end
  for _, generator in ipairs(fac.logisticGenerators or {}) do
    if (generator.type == "materialProvider" or generator.type == "materialReceiver") and generator.materialType then
      note(generator.materialType)
    end
  end
  for _, ap in pairs(fac.accessPointsByName or {}) do
    for key, enabled in pairs(ap.logisticTypesProvidedLookup or {}) do
      if enabled then note(key) end
    end
  end
  return types
end

function M.facilitySupportsMaterialType(fac, cargoType, resolveType, allowedTypes)
  if not fac or not cargoType then return false end
  return M.facilityMaterialTypes(fac, resolveType, allowedTypes)[cargoType] == true
end

function M.accessPointProvidesLogisticType(ap, logisticType)
  if not ap or not logisticType then return false end
  local lookup = ap.logisticTypesProvidedLookup
  if type(lookup) == "table" and lookup[logisticType] then return true end
  for _, t in ipairs(ap.logisticTypesProvided or {}) do
    if t == logisticType then return true end
  end
  return false
end

-- Returns metres and whether a complete navgraph route produced them. A direct-distance result is an estimate: callers may use it, but must not cache it as a finished driving route.
function M.getDistanceBetweenLocations(posA, posB)
  local directDistance = getDirectDistance(posA, posB)
  local name_a, _, distance_a = map.findClosestRoad(posA)
  local name_b, _, distance_b = map.findClosestRoad(posB)
  if not name_a or not name_b then return directDistance, false end
  local path = map.getPath(name_a, name_b)
  if type(path) ~= "table" or #path == 0 or (#path == 1 and name_a ~= name_b) then
    return directDistance, false
  end
  local mapData = map.getMap()
  if not mapData or not mapData.nodes then return directDistance, false end

  local d = 0
  for i = 1, #path - 1 do
    local nodeA = mapData.nodes[path[i]]
    local nodeB = mapData.nodes[path[i + 1]]
    if not nodeA or not nodeA.pos or not nodeB or not nodeB.pos then
      return directDistance, false
    end
    tmpVec:set(nodeA.pos)
    tmpVec:setSub(nodeB.pos)
    d = d + tmpVec:length()
  end
  d = d + (tonumber(distance_a) or 0) + (tonumber(distance_b) or 0)
  return d, true
end

return M
