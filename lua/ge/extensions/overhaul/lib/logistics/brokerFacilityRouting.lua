-- Only logistics inspection entries hand off to the independent broker.
-- Read cargo detection, facility exclusions, then the broker eligibility query.
local M = {}

local facilityRole = require("overhaul/lib/logistics/facilityRole")

local generators = { parcelProvider = true, parcelReceiver = true, trailerOfferProvider = true,
  materialProvider = true, materialReceiver = true }
local cargoTypes = { parcel = true, fluid = true, dryBulk = true, cement = true, cash = true }
local excludedParcels = { food = true, takeout = true }

local function hasCargoTypes(record)
  for _, field in ipairs({ "logisticTypesProvidedLookup", "logisticTypesReceivedLookup" }) do
    for kind, enabled in pairs(record[field] or {}) do
      if enabled and cargoTypes[kind] then return true end
    end
  end
  for _, field in ipairs({ "logisticTypesProvided", "logisticTypesReceived" }) do
    for _, kind in ipairs(record[field] or {}) do
      if cargoTypes[kind] then return true end
    end
  end
  return false
end

function M.isFoodPickup(facility)
  local food = false
  for _, generator in ipairs(facility and facility.logisticGenerators or {}) do
    if generator.type == "parcelProvider" then
      local types = generator.logisticTypes or {}
      if not next(types) then return false end
      for _, kind in ipairs(types) do
        if not excludedParcels[kind] then return false end
        food = true
      end
    elseif generator.type == "trailerOfferProvider" or generator.type == "vehOfferProvider"
        or generator.type == "materialProvider" then
      return false
    end
  end
  return food
end

-- Decides whether a logistics entry opens the independent broker. Service exclusions and inspection-bay checks still apply to configured car-haul sources.
function M.shouldOpen(facility, organization, parkingSpotPath)
  if not facility or M.isFoodPickup(facility) then return false end
  if facility.broker and facility.broker.enabled == false then return false end
  if facility.associatedOrganization and not organization then return false end
  -- Do not use employment eligibility here: the hospital opts out but remains a paramedic service.
  if facilityRole.resolve(facility, organization) then return false end
  if parkingSpotPath then
    local inspection = false
    for _, point in pairs(facility.accessPointsByName or {}) do
      local path = point.psPath or (point.ps and point.ps.getPath and point.ps:getPath())
      if path == parkingSpotPath then inspection = point.isInspectSpot == true; break end
    end
    if not inspection then return false end
  end
  if facility.broker and facility.broker.enabled == true then return true end
  if type(facility.ownerOpCarHauling) == "table" then return true end
  if facility.vehicleDistributor ~= false and (facility.vehicleDistributor == true or facility.carHaulFacility == true) then
    return true
  end
  local configured = false
  for _, generator in ipairs(facility.logisticGenerators or {}) do
    if generators[generator.type] then
      configured = true
      if not generator.offerMode or generator.offerMode == "shared" or generator.offerMode == "independent" then
        if generator.type ~= "parcelProvider" and generator.type ~= "parcelReceiver" then return true end
        local types = generator.logisticTypes or {}
        if not next(types) then return true end
        for _, kind in ipairs(types) do
          if not excludedParcels[kind] then return true end
        end
      end
    end
  end
  if configured then return false end
  -- A bare vehicleDelivery flag is car-jockey work, not a hauling contract.
  return hasCargoTypes(facility)
    or (facility.providedSystemsLookup or {}).trailerDelivery == true
end

return M
