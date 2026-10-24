-- Property bundles share ownership with their business; they keep no separate entitlement state.
-- Read catalog lookups, ownership, dyno identity, then sale blockers.
local M = {}

local capabilities = require("overhaul/lib/platform/capabilities")
local catalog = require("overhaul/lib/platform/jsonCatalog")

local definitions = nil

local function validateBundle(data)
  if data.version ~= 1 then return nil, "unsupported bundle version" end
  for _, field in ipairs({"businessType", "businessId", "mapId", "name"}) do
    if type(data[field]) ~= "string" or data[field] == "" then return nil, "missing " .. field end
  end
  if data.garageId ~= nil and not catalog.validId(data.garageId) then return nil, "invalid garageId" end
  if data.dyno ~= nil then
    if type(data.dyno) ~= "table" then return nil, "invalid dyno" end
    for _, field in ipairs({"triggerName", "sitesFile", "parkingSpotName"}) do
      if type(data.dyno[field]) ~= "string" or data.dyno[field] == "" then return nil, "missing dyno " .. field end
    end
  end
  if not data.garageId and not data.dyno then return nil, "bundle has no ownership benefits" end
  return data
end

local function conflicts(left, right)
  if left.businessType == right.businessType and left.businessId == right.businessId then return true end
  if left.garageId and left.garageId == right.garageId then return true end
  local a, b = left.dyno, right.dyno
  return left.mapId == right.mapId and a and b and a.triggerName == b.triggerName
    and a.sitesFile == b.sitesFile and a.parkingSpotName == b.parkingSpotName
end

function M.getAll()
  if definitions then return definitions end
  definitions = jsonReadFile("gameplay/overhaul/business/propertyBundles.json") or {}
  local additions = catalog.scan("/gameplay/overhaul/business/propertyBundles/", validateBundle, "businessBundles")
  for _, bundle in ipairs(additions) do
    local duplicate = false
    for _, existing in ipairs(definitions) do
      if conflicts(existing, bundle) then duplicate = true; break end
    end
    if duplicate then
      log("W", "businessBundles", "Ignoring conflicting property bundle: " .. bundle.id)
    else
      definitions[#definitions + 1] = bundle
    end
  end
  return definitions
end

function M.forGarage(garageId)
  if not garageId then return nil end
  for _, bundle in ipairs(M.getAll()) do
    if bundle.garageId == garageId then return bundle end
  end
end

function M.forBusiness(businessType, businessId)
  for _, bundle in ipairs(M.getAll()) do
    if bundle.businessType == businessType and bundle.businessId == businessId then return bundle end
  end
end

function M.isOwned(bundle)
  local manager = overhaul_career_business_manager
  return bundle ~= nil and overhaul_career_career.isActive()
    and manager.isBusinessOwnershipReady()
    and manager.isPurchasedBusiness(bundle.businessType, bundle.businessId) == true or false
end

function M.forDyno(mapId, triggerName, sitesFile, parkingSpotName)
  for _, bundle in ipairs(M.getAll()) do
    local dyno = bundle.dyno
    if bundle.mapId == mapId and dyno and dyno.triggerName == triggerName
      and dyno.sitesFile == sitesFile and dyno.parkingSpotName == parkingSpotName then
      return bundle
    end
  end
end

function M.saleBlockReason(bundle)
  if not bundle then return nil end
  local name = bundle.name or bundle.businessId
  if bundle.garageId then
    local inventory = overhaul_career_garage_inventory
    if not inventory or not inventory.getVehicles then return "Vehicle storage is not ready." end
    for _, vehicle in pairs(inventory.getVehicles() or {}) do
      if vehicle.location == bundle.garageId then
        return "Move all vehicles out of the " .. name .. " garage before selling the business."
      end
    end
  end
  local dyno = capabilities.peek("businessSession")
  if bundle.dyno and dyno and dyno.isBusinessSessionBusy
    and dyno.isBusinessSessionBusy(bundle.businessId) then
    return "Finish the " .. name .. " dyno session before selling the business."
  end
end

return M
