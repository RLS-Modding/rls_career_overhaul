-- Shared delivery template loading
-- Extracted from career/modules/delivery/generator.lua
-- These functions do NOT require career mode to be active.

local M = {}

-- RLS blacklist — exact copy from generator.lua line 8
local blacklist = {
  ["/gameplay/delivery/materials.deliveryMaterials.json"] = true,
  ["/gameplay/delivery/materials.deliveryParcels.json"] = true,
  ["/gameplay/delivery/mechanics.deliveryParcels.json"] = true,
  ["/gameplay/delivery/restaurants.deliveryParcels.json"] = true,
  ["/gameplay/delivery/vehicles.deliveryVehicles.json"] = true,
  ["/gameplay/delivery/warehouses.deliveryParcels.json"] = true,
}

M.getBlacklist = function() return blacklist end

-------------------------------
-- Parcel Templates
-------------------------------

local parcelItemTemplates = nil
local parcelTemplatesById = {}
local parcelTemplateIdsByLogisticType = {}

-- Exact copy of getDeliveryParcelTemplates from generator.lua ~line 200
function M.loadParcelTemplates()
  if not parcelItemTemplates then
    parcelItemTemplates = {}
    parcelTemplatesById = {}
    parcelTemplateIdsByLogisticType = {}
    local Allfiles = FS:findFiles("gameplay/delivery/", '*.deliveryParcels.json', -1, false, true)
    local files = {}
    for _, file in ipairs(Allfiles) do
      if not blacklist[file] then
        table.insert(files, file)
      end
    end
    for _,file in ipairs(files) do
      for k, v in pairs(jsonReadFile(file) or {}) do
        local item = v
        item.id = k
        item.type = item.cargoType
        item.logisticType = item.logisticTypes[1] -- fix from table to one elem!
        if not item.materialType then
          parcelTemplateIdsByLogisticType[item.logisticType] = parcelTemplateIdsByLogisticType[item.logisticType] or {}
          table.insert(parcelTemplateIdsByLogisticType[item.logisticType], item.id)
        end
        item.duplicationChanceSum = 0
        item.duplicationChance = item.duplicationChance or {1}
        for _, chance in ipairs(item.duplicationChance or {}) do
          item.duplicationChanceSum = item.duplicationChanceSum + chance
        end

        item.weight = item.weight or 0
        -- make weight into a table to pick random ones later
        if type(item.weight) ~= "table" then
          item.weight = {item.weight}
        end

        if type(item.slots) ~= "table" then
          item.slots = {item.slots}
        end
        table.sort(item.slots)
        item.minSlots = item.slots[1]
        item.maxSlots = item.slots[#item.slots]

        table.insert(parcelItemTemplates, item)
        parcelTemplatesById[item.id] = item
        item.modChance = item.modChance or {}
        item.modChance.timed = item.modChance.timed or 0.2
      end
    end
    log("I","",string.format("Loaded %d item templates from %d files.", #tableKeys(parcelItemTemplates), #files))
  end
  return parcelItemTemplates
end

function M.getTemplateById(id)
  return parcelTemplatesById[id]
end

function M.getTemplatesByLogisticType(logisticType)
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
  return parcelTemplateIdsByLogisticType
end

-------------------------------
-- Vehicle Filter Templates
-------------------------------

local vehicleFilterTemplates = nil
local vehicleFilterTemplatesById = {}

-- Exact copy of getDeliveryVehicleTemplates from generator.lua ~line 380
function M.loadVehicleFilters()
  if not vehicleFilterTemplates then
    vehicleFilterTemplates = {}
    vehicleFilterTemplatesById = {}
    local Allfiles = FS:findFiles("gameplay/delivery/", '*.deliveryVehicles.json', -1, false, true)
    local files = {}
    for _, file in ipairs(Allfiles) do
      if not blacklist[file] then
        table.insert(files, file)
      end
    end
    for _,file in ipairs(files) do
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
  return vehicleFilterTemplatesById[id]
end

-------------------------------
-- Material Templates
-------------------------------

local materialTemplates = nil
local materialTemplatesById = {}

-- Exact copy of getMaterialsTemplates from generator.lua ~line 470
function M.loadMaterialTemplates()
  if not materialTemplates then
    materialTemplates = {}
    materialTemplatesById = {}
    local Allfiles = FS:findFiles("gameplay/delivery/", '*.deliveryMaterials.json', -1, false, true)
    local files = {}
    for _, file in ipairs(Allfiles) do
      if not blacklist[file] then
        table.insert(files, file)
      end
    end
    for _,file in ipairs(files) do
      for id, data in pairs(jsonReadFile(file) or {}) do
        data.id = id
        table.insert(materialTemplates, data)
        materialTemplatesById[id] = data
      end
    end
  end
  return materialTemplates
end

function M.getMaterialTemplateById(id)
  return materialTemplatesById[id]
end

-------------------------------
-- Reset (for reloading)
-------------------------------
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
