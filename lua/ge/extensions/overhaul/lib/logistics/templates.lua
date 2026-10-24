-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Shared delivery template loading; none of it requires career mode to be active.
-- Owns the once-per-session reads of gameplay/delivery/; reset() forces a reload.
local M = {}

local dataFiles = require("overhaul/lib/data/dataFiles")

-- Stock delivery files the overhaul replaces with its own data.
local blacklist = {
  ["/gameplay/delivery/materials.deliveryMaterials.json"] = true,
  ["/gameplay/delivery/materials.deliveryParcels.json"] = true,
  ["/gameplay/delivery/mechanics.deliveryParcels.json"] = true,
  ["/gameplay/delivery/restaurants.deliveryParcels.json"] = true,
  ["/gameplay/delivery/vehicles.deliveryVehicles.json"] = true,
  ["/gameplay/delivery/warehouses.deliveryParcels.json"] = true,
}
local canonicalMaterialFile = "/gameplay/overhaul/delivery/rlsmaterials.deliveryMaterials.json"

local parcelItemTemplates = nil
local parcelTemplatesById = {}
local parcelTemplateIdsByLogisticType = {}
local vehicleFilterTemplates = nil
local vehicleFilterTemplatesById = {}
local materialTemplates = nil
local materialTemplatesById = {}

M.getBlacklist = function() return blacklist end

local function deliveryFiles(pattern)
  local files = {}
  for _, file in ipairs(dataFiles.findFiles("gameplay/delivery/", pattern, -1, false, true)) do
    if not blacklist[file] then table.insert(files, file) end
  end
  return files
end

local function prepareParcelTemplate(id, item)
  item.id = id
  item.type = item.cargoType
  item.logisticType = item.logisticTypes[1] -- fix from table to one elem!
  if not item.materialType then
    parcelTemplateIdsByLogisticType[item.logisticType] = parcelTemplateIdsByLogisticType[item.logisticType] or {}
    table.insert(parcelTemplateIdsByLogisticType[item.logisticType], item.id)
  end
  item.duplicationChanceSum = 0
  item.duplicationChance = item.duplicationChance or { 1 }
  for _, chance in ipairs(item.duplicationChance or {}) do
    item.duplicationChanceSum = item.duplicationChanceSum + chance
  end

  item.weight = item.weight or 0
  -- Weight is a table so later rolls can pick among several values.
  if type(item.weight) ~= "table" then
    item.weight = { item.weight }
  end

  if type(item.slots) ~= "table" then
    item.slots = { item.slots }
  end
  table.sort(item.slots)
  item.minSlots = item.slots[1]
  item.maxSlots = item.slots[#item.slots]

  parcelTemplatesById[item.id] = item
  -- Material orders use the bulk-material workflow. Retain a legacy template by id for old saves, but never offer it as a parcel.
  if not item.materialType then
    table.insert(parcelItemTemplates, item)
  end
  item.modChance = item.modChance or {}
  item.modChance.timed = item.modChance.timed or 0.2
end

local function registerParcelTemplate(id, item, file)
  if type(item) ~= "table" or type(item.logisticTypes) ~= "table" or item.logisticTypes[1] == nil then
    log("W", "delivery.templates", string.format("Skipping parcel template '%s' in %s: missing logisticTypes", tostring(id), tostring(file)))
    return
  end
  prepareParcelTemplate(id, item)
end

-- Third-party definitions can migrate at their own pace. An old per-unit rate becomes an equivalent per-kilogram base rate before route scaling is applied.
local function migrateMaterialRate(data)
  if data.moneyPerKg == nil then
    local density = tonumber(data.density) or 0
    local legacyMoney = tonumber(data.money) or 0
    data.moneyPerKg = density > 0 and legacyMoney / density or 0
  end
end

function M.loadParcelTemplates()
  if not parcelItemTemplates then
    parcelItemTemplates = {}
    parcelTemplatesById = {}
    parcelTemplateIdsByLogisticType = {}
    local files = deliveryFiles("*.deliveryParcels.json")
    for _, file in ipairs(files) do
      for id, item in pairs(jsonReadFile(file) or {}) do
        registerParcelTemplate(id, item, file)
      end
    end
    log("I", "", string.format("Loaded %d item templates from %d files.", #tableKeys(parcelItemTemplates), #files))
  end
  return parcelItemTemplates
end

function M.getTemplateById(id)
  M.loadParcelTemplates()
  return parcelTemplatesById[id]
end

function M.getTemplatesByLogisticType(logisticType)
  M.loadParcelTemplates()
  local ids = parcelTemplateIdsByLogisticType[logisticType]
  if not ids then return {} end
  local result = {}
  for _, id in ipairs(ids) do
    if parcelTemplatesById[id] then
      table.insert(result, parcelTemplatesById[id])
    end
  end
  return result
end

function M.getTemplateIdsByLogisticType()
  M.loadParcelTemplates()
  return parcelTemplateIdsByLogisticType
end

function M.loadVehicleFilters()
  if not vehicleFilterTemplates then
    vehicleFilterTemplates = {}
    vehicleFilterTemplatesById = {}
    for _, file in ipairs(deliveryFiles("*.deliveryVehicles.json")) do
      for id, filter in pairs(jsonReadFile(file) or {}) do
        filter.id = id
        filter.unlockTag = filter.unlockTag or nil
        table.insert(vehicleFilterTemplates, filter)
        vehicleFilterTemplatesById[id] = filter
      end
    end
  end
  return vehicleFilterTemplates
end

function M.getVehicleFilterById(id)
  M.loadVehicleFilters()
  return vehicleFilterTemplatesById[id]
end

function M.getVehicleFilterUnlockTag(id)
  if not id then return nil end
  M.loadVehicleFilters()
  local filter = M.getVehicleFilterById(id)
  return filter and filter.unlockTag or nil
end

function M.loadMaterialTemplates()
  if not materialTemplates then
    materialTemplates = {}
    materialTemplatesById = {}
    local files = deliveryFiles("*.deliveryMaterials.json")
    -- Map expansions may carry legacy copies of core material ids alongside their map-specific materials. Load the overhaul's rebalance last so those compatibility definitions cannot silently replace its rates.
    table.sort(files, function(a, b)
      if a == canonicalMaterialFile then return false end
      if b == canonicalMaterialFile then return true end
      return a < b
    end)
    for _, file in ipairs(files) do
      for id, data in pairs(jsonReadFile(file) or {}) do
        data.id = id
        migrateMaterialRate(data)
        materialTemplatesById[id] = data
      end
    end
    for _, id in ipairs(tableKeysSorted(materialTemplatesById)) do
      table.insert(materialTemplates, materialTemplatesById[id])
    end
  end
  return materialTemplates
end

function M.getMaterialTemplateById(id)
  M.loadMaterialTemplates()
  return materialTemplatesById[id]
end

function M.resolveMaterialBulkType(materialTypeOrBulk)
  if not materialTypeOrBulk then return nil end
  if require("overhaul/lib/logistics/cargoSemantics").cargo(materialTypeOrBulk).material then
    return materialTypeOrBulk
  end
  pcall(M.loadMaterialTemplates)
  local template = M.getMaterialTemplateById(materialTypeOrBulk)
  return template and template.type or nil
end

function M.reset()
  parcelItemTemplates = nil
  parcelTemplatesById = {}
  parcelTemplateIdsByLogisticType = {}
  vehicleFilterTemplates = nil
  vehicleFilterTemplatesById = {}
  materialTemplates = nil
  materialTemplatesById = {}
end

return M
