-- Native cargo handlers own measurement, container loading and capacity presentation.
-- Read manifest validation and discovery, then the native-cargo query facade.
local M = {}

local manifests = require("overhaul/lib/platform/manifests")

M.dir = "/gameplay/overhaul/logistics/nativeCargoKinds/"

local providerTypes = {
  parcel = { parcelProvider = true, parcelReceiver = true },
  vehicle = { vehOfferProvider = true }, trailer = { trailerOfferProvider = true },
}
-- Fallbacks for cargo kinds that no handler claims, so lookups never fail.
local unknownMaterial = { economyKey = "delivery_trailer", market = "bulk", requirement = "Bulk cargo capacity" }
local unknownCargo = { parcel = false, material = false, measure = function() return 1 end,
  load = function() end, capacityLabel = function() end }

local builtins = {}
for _, kind in ipairs({ "parcel", "fluid", "dryBulk", "cement", "cash" }) do
  builtins[kind] = require("overhaul/lib/logistics/nativeCargoKinds/" .. kind)
end
local catalog, current = builtins, nil

local function validate(data)
  if type(data.handler) ~= "string" or not data.handler:match("^[%w_][%w_/%.%-]*$")
      or data.handler:sub(-4) == ".lua" then return nil, "native cargo handler path required" end
  local ok, handler = pcall(require, data.handler)
  if not ok or type(handler) ~= "table" then return nil, "native cargo handler did not load" end
  for _, field in ipairs({ "measure", "load", "capacityLabel" }) do
    if type(handler[field]) ~= "function" then return nil, "native cargo handler needs " .. field end
  end
  if type(handler.parcel) ~= "boolean" or type(handler.material) ~= "boolean" then
    return nil, "native cargo family flags required"
  end
  if handler.parcel and handler.material then return nil, 'cargo cannot be both parcel and material' end
  if handler.requiresMaterialUnlock ~= nil and type(handler.requiresMaterialUnlock) ~= 'boolean' then
    return nil, 'native cargo requiresMaterialUnlock must be a boolean'
  end
  if handler.smallSystem ~= nil and not manifests.isNonEmptyString(handler.smallSystem) then
    return nil, "native cargo smallSystem must be a non-empty string"
  end
  if handler.material then
    for _, field in ipairs({ "economyKey", "market", "requirement", "smallSystem", "largeSystem" }) do
      if not manifests.isNonEmptyString(handler[field]) then return nil, "material cargo needs " .. field end
    end
  end
  return { id = data.id, order = data.order, handler = handler }
end

-- Discovery belongs to the broker's lifetime. An older unload cannot withdraw its replacement.
function M.discover()
  local entries, rejected = manifests.scan({ dir = M.dir, tag = "logisticsNativeCargo", validate = validate })
  local nextCatalog = {}
  for kind, handler in pairs(builtins) do nextCatalog[kind] = handler end
  for _, entry in ipairs(entries) do nextCatalog[entry.id] = entry.handler end
  local instance = {}
  current, catalog = instance, nextCatalog
  local function dispose()
    if current ~= instance then return end
    current, catalog = nil, builtins
  end
  return dispose, rejected
end

function M.cargo(kind) return catalog[kind] or unknownCargo end

function M.material(kind)
  local handler = M.cargo(kind)
  return handler.material and handler or unknownMaterial
end

function M.measure(cargo) return cargo.type, M.cargo(cargo.type).measure(cargo) end

function M.addContainerLoad(container, cargo) return M.cargo(cargo.type).load(container, cargo) end

function M.capacityLabel(cap, icon, translate) return M.cargo(cap.type).capacityLabel(cap, icon, translate) end

function M.generatorMatches(kind, generator)
  local providers = providerTypes[kind]
  return providers and providers[generator.type] == true or false
end

function M.enableSystem(kind, systems)
  local key = M.cargo(kind).smallSystem
  if key then systems[key] = true end
end

function M.materialSystems(kind, facility, storageId)
  local descriptor = M.cargo(kind)
  if not descriptor.material then return {} end
  return { [descriptor.smallSystem] = true,
    [descriptor.largeSystem] = facility and (facility.materialStorages[storageId] ~= nil) }
end

function M.groupVehicleOffers(offers)
  local groups = { vehicle = {}, trailer = {} }
  for _, offer in ipairs(offers) do
    local group = groups[offer.data.type]
    if group then group[#group + 1] = offer end
  end
  return groups.vehicle, groups.trailer
end

return M
