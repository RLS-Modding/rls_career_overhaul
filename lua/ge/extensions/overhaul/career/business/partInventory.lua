-- Business-owned parts, their save migration and quarantine of unowned rows.
-- Read config, state, ownership checks, persistence, UI payloads, pricing, sales, then the public API.
local M = {}

local jbeamIO = require("jbeam/io")

-- Config ------------------------------------------------------------------------------------------

local PART_INVENTORY_SAVE_VERSION = 2
local LEGACY_MIGRATION_WINDOW_BEFORE = 120
local LEGACY_MIGRATION_WINDOW_AFTER = 5
local businessPartInventoryPath = "business/partInventory.json"
local businessPartInventoryQuarantinePath = "business/partInventoryQuarantine.json"
local businessPartInventoryMetaPath = "business/partInventoryMeta.json"

-- State -------------------------------------------------------------------------------------------

local inventory = {}
local inventoryLoaded = false
local quarantineEntries = {}
local activeBusinessId = nil
local pricePartIoCtxCache = {}

-- Load and save live in one table so they can call each other without forward declarations.
local persistence = {}

-- Ids and ownership -------------------------------------------------------------------------------

local function normalizeBusinessId(businessId)
  if businessId == nil or businessId == "" then return nil end
  return tostring(businessId)
end

local function partBelongsToBusiness(part, businessId)
  if not part then return false end
  local wantedId = normalizeBusinessId(businessId)
  if not wantedId then return false end
  local partOwnerId = part.businessId
  if partOwnerId == nil or tostring(partOwnerId) == "" then return false end
  return tostring(partOwnerId) == wantedId
end

local function partOwnerIsPurchasedBusiness(part)
  if not part then return false end
  local ownerId = normalizeBusinessId(part.businessId)
  if not ownerId then return false end
  local businessManager = overhaul_career_business_manager
  if not businessManager or not businessManager.isPurchasedBusiness or not businessManager.getAllPurchasedBusinesses then
    return false
  end
  local purchasedByType = businessManager.getAllPurchasedBusinesses()
  if type(purchasedByType) ~= "table" then return false end
  for businessType in pairs(purchasedByType) do
    if type(businessType) == "string" and businessManager.isPurchasedBusiness(businessType, ownerId) then
      return true
    end
  end
  return false
end

local function generatePartId()
  local id = 1
  while inventory[id] do
    id = id + 1
  end
  return id
end

-- Quarantine --------------------------------------------------------------------------------------

local function appendQuarantineEntries(entries)
  if not entries or #entries == 0 then return end
  for _, row in ipairs(entries) do
    table.insert(quarantineEntries, row)
  end
end

-- Moves rows whose business is not purchased (or has no business) out of the live inventory.
local function validateInventoryOwnershipAfterLoad()
  local businessManager = overhaul_career_business_manager
  if not businessManager or not businessManager.isBusinessOwnershipReady or not businessManager.isBusinessOwnershipReady() then
    return
  end
  local toRemove = {}
  local batch = {}
  for partId, part in pairs(inventory) do
    if part and not partOwnerIsPurchasedBusiness(part) then
      table.insert(toRemove, partId)
      local reason = normalizeBusinessId(part.businessId) and "invalid_owner" or "missing_owner"
      table.insert(batch, {quarantinedAt = os.time(), reason = reason, part = deepcopy(part)})
    end
  end
  if #toRemove == 0 then return end
  appendQuarantineEntries(batch)
  for _, partId in ipairs(toRemove) do
    inventory[partId] = nil
  end
  persistence.save()
  log("I", "businessPartInventory", string.format(
    "Quarantined %d part inventory row(s) with missing or invalid business ownership (see career/business/partInventoryQuarantine.json).",
    #toRemove))
end

local function onPurchasedBusinessesOwnershipReady()
  if not inventoryLoaded then return end
  validateInventoryOwnershipAfterLoad()
end

-- Add, remove and condition ----------------------------------------------------------------------

local function addPart(part, ownerBusinessId)
  if not part then return nil end
  local ownerId = normalizeBusinessId(ownerBusinessId or part.businessId or activeBusinessId)
  if not ownerId then
    log("W", "businessPartInventory", "addPart: missing businessId — part not added.")
    return nil
  end

  local newPart = {
    name = part.name,
    vehicleModel = part.vehicleModel,
    year = part.year,
    manufacturedYear = part.manufacturedYear,
    engineShopManufactured = part.engineShopManufactured == true,
    factoryPackageId = part.factoryPackageId,
    tags = type(part.tags) == "table" and deepcopy(part.tags) or nil,
    partCondition = deepcopy(part.partCondition or {integrityValue = 1, odometer = 0, visualValue = 1}),
    slot = part.slot or part.slotType,
    containingSlot = part.containingSlot,
    partPath = part.partPath,
    rlsTireState = type(part.rlsTireState) == "table" and deepcopy(part.rlsTireState) or nil,
    businessId = ownerId,
    location = part.location == nil and 0 or part.location,
    enginePackageId = part.enginePackageId,
    productRevisionId = part.productRevisionId,
    mainPart = part.mainPart == true,
  }

  local id = generatePartId()
  newPart.partId = id
  inventory[id] = newPart
  persistence.save()
  return id
end

local function addParts(partsList, ownerBusinessId)
  if not partsList then return end
  for _, part in ipairs(partsList) do
    addPart(part, ownerBusinessId)
  end
  persistence.save()
end

local function removePart(partId, ownerBusinessId)
  local existing = inventory[partId]
  if not existing then return false end
  local ownerId = normalizeBusinessId(ownerBusinessId)
  if ownerId and not partBelongsToBusiness(existing, ownerId) then return false end
  inventory[partId] = nil
  persistence.save()
  return true
end

local function updatePartCondition(partId, condition)
  if inventory[partId] then
    inventory[partId].partCondition = deepcopy(condition)
    return true
  end
  return false
end

-- Legacy save folder ------------------------------------------------------------------------------

local function getFileModTime(path)
  if not path or not FS:fileExists(path) then return nil end
  local fileStat = FS:stat(path)
  return fileStat and fileStat.modtime or nil
end

-- Legacy inventories were written to a sibling save folder; pick the one saved closest to this profile's info.json.
local function findLegacyInventoryFile(savePath)
  local infoTime = getFileModTime(savePath .. "/info.json")
  if not infoTime then return nil end
  local function inWindow(modTime)
    return modTime and modTime >= infoTime - LEGACY_MIGRATION_WINDOW_BEFORE and modTime <= infoTime + LEGACY_MIGRATION_WINDOW_AFTER
  end
  if inWindow(getFileModTime(savePath .. "/career/" .. businessPartInventoryPath)) then return nil end
  local profileDir = savePath:match("^(.*)[/\\][^/\\]+$")
  local ownName = savePath:match("([^/\\]+)$")
  if not profileDir or not ownName then return nil end
  local bestFile, bestDelta = nil, nil
  for _, folder in ipairs(FS:directoryList(profileDir, false, true) or {}) do
    local name = folder:match("([^/\\]+)$")
    if name and name ~= ownName then
      local candidate = folder .. "/career/" .. businessPartInventoryPath
      local modTime = getFileModTime(candidate)
      if inWindow(modTime) then
        local delta = math.abs(infoTime - modTime)
        if not bestDelta or delta < bestDelta then
          bestFile, bestDelta = candidate, delta
        end
      end
    end
  end
  return bestFile
end

-- Save and load ----------------------------------------------------------------------------------

local function readQuarantineRows(savePath)
  local existingQuarantine = jsonReadFile(savePath .. "/career/" .. businessPartInventoryQuarantinePath)
  if type(existingQuarantine) ~= "table" then return end
  for _, row in ipairs(existingQuarantine) do
    table.insert(quarantineEntries, row)
  end
end

local function inventoryFilePath(savePath)
  local filePath = savePath .. "/career/" .. businessPartInventoryPath
  if FS:fileExists(savePath .. "/career/" .. businessPartInventoryMetaPath) then return filePath end
  local legacyFile = findLegacyInventoryFile(savePath)
  if not legacyFile then return filePath end
  log("I", "businessPartInventory", "Loading part inventory written by the old save code from " .. tostring(legacyFile))
  return legacyFile
end

function persistence.load()
  local saveSlot, savePath = overhaul_career_saveSystem.getCurrentProfile()
  if not saveSlot or not savePath then return end

  local data = jsonReadFile(inventoryFilePath(savePath))
  inventory = {}
  pricePartIoCtxCache = {}
  quarantineEntries = {}
  readQuarantineRows(savePath)

  if type(data) == "table" then
    for idx, part in pairs(data) do
      if part and type(part) == "table" then
        local partId = part.partId or tonumber(idx) or idx
        inventory[partId] = part
        if not part.partId then
          part.partId = partId
        end
      end
    end
  end
  validateInventoryOwnershipAfterLoad()
  inventoryLoaded = true
end

-- Does nothing without a save path, so the ownership pass can call it safely.
function persistence.save(savePath, writer)
  if not savePath then return end
  if not inventoryLoaded then persistence.load() end

  local partsArray = {}
  for _, part in pairs(inventory) do
    if part then table.insert(partsArray, part) end
  end
  writer = writer or overhaul_career_saveSystem.getSaveWriter()
  writer.json(savePath .. "/career/" .. businessPartInventoryPath, partsArray, true)
  writer.json(savePath .. "/career/" .. businessPartInventoryMetaPath, {version = PART_INVENTORY_SAVE_VERSION}, true)
  if #quarantineEntries > 0 then
    writer.json(savePath .. "/career/" .. businessPartInventoryQuarantinePath, quarantineEntries, true)
  end
end

-- Pricing -----------------------------------------------------------------------------------------

local function startJbeamLoading(vehicleModel)
  local vehicleDir = string.format("/vehicles/%s/", vehicleModel)
  if not FS:directoryExists(vehicleDir) then return nil end
  return jbeamIO.startLoading({vehicleDir, "/vehicles/common/"})
end

-- Price is the market value of the part with its jbeam value and name, or 0 with no valuation service.
local function pricePartForSale(part)
  if not part then return 0 end
  if not overhaul_career_market_valueCalculator then return 0 end
  local expandedPart = deepcopy(part)
  local ioCtx = pricePartIoCtxCache[part.vehicleModel]
  if ioCtx == nil then
    ioCtx = startJbeamLoading(part.vehicleModel)
    pricePartIoCtxCache[part.vehicleModel] = ioCtx or false
  end
  local jbeamData = ioCtx and jbeamIO.getPart(ioCtx, part.name)

  if jbeamData and jbeamData.information then
    expandedPart.value = jbeamData.information.value or part.value or 0
    expandedPart.niceName = jbeamData.information.name or part.name
  else
    expandedPart.value = part.value or 0
    expandedPart.niceName = part.name
  end
  return overhaul_career_market_valueCalculator.getPartValue(expandedPart) or 0
end

-- UI payload --------------------------------------------------------------------------------------

-- Reads the jbeam part for a row, sharing one IO context per vehicle model across the payload.
local function jbeamDataFor(part, ioContexts)
  if not ioContexts[part.vehicleModel] then
    ioContexts[part.vehicleModel] = startJbeamLoading(part.vehicleModel)
  end
  local ioCtx = ioContexts[part.vehicleModel]
  if ioCtx then return jbeamIO.getPart(ioCtx, part.name) end
  return nil
end

local function vehicleNiceName(vehicleModel)
  local modelData = core_vehicles.getModel(vehicleModel)
  if not (modelData and modelData.model) then return vehicleModel end
  local brand = modelData.model.Brand or ""
  local name = modelData.model.Name or vehicleModel or ""
  return (brand .. " " .. name):match("^%s*(.-)%s*$")
end

local function expandedPartForUi(part, ioContexts)
  local expandedPart = deepcopy(part)
  local jbeamData = jbeamDataFor(part, ioContexts)

  if jbeamData then
    expandedPart.value = jbeamData.information and jbeamData.information.value or 100
    expandedPart.niceName = jbeamData.information and jbeamData.information.name or part.name
    expandedPart.description = expandedPart.niceName
    if not expandedPart.slot and jbeamData.slotType then
      expandedPart.slot = jbeamData.slotType
    end
  else
    expandedPart.description = part.name .. " (Unknown)"
    expandedPart.niceName = part.name
    expandedPart.value = 0
  end

  expandedPart.vehicleNiceName = vehicleNiceName(part.vehicleModel)
  expandedPart.finalValue = pricePartForSale(part)
  return expandedPart
end

local function getUIData(businessId)
  activeBusinessId = businessId
  local ownerId = normalizeBusinessId(businessId)
  if not inventoryLoaded then persistence.load() end

  local partsByModel = {}
  local ioContexts = {}
  local partCount = 0
  for _, part in pairs(inventory) do
    if part and ownerId and partBelongsToBusiness(part, ownerId) then
      partCount = partCount + 1
      partsByModel[part.vehicleModel] = partsByModel[part.vehicleModel] or {}
      table.insert(partsByModel[part.vehicleModel], expandedPartForUi(part, ioContexts))
    end
  end
  return {partsByModel = partsByModel, partCount = partCount}
end

-- Sales and liquidation ---------------------------------------------------------------------------

local function sellPart(partId, businessId)
  if not partId then return false, 0 end
  local part = inventory[partId]
  if not part or not partBelongsToBusiness(part, businessId) or part.enginePackageId then return false, 0 end
  local price = pricePartForSale(part)
  if price <= 0 then return false, 0 end
  inventory[partId] = nil
  persistence.save()
  return true, price
end

-- Removes every part that matches and is worth something, then returns what they sold for.
local function sellMatchingParts(matches)
  local totalPrice = 0
  local partsToRemove = {}
  for partId, part in pairs(inventory) do
    if part and matches(part) and not part.enginePackageId then
      local price = pricePartForSale(part)
      if price > 0 then
        totalPrice = totalPrice + price
        table.insert(partsToRemove, partId)
      end
    end
  end
  for _, partId in ipairs(partsToRemove) do
    inventory[partId] = nil
  end
  persistence.save()
  return true, totalPrice
end

local function sellAllParts(businessId)
  if not normalizeBusinessId(businessId) then return false, 0 end
  return sellMatchingParts(function(part) return partBelongsToBusiness(part, businessId) end)
end

local function sellPartsByVehicle(vehicleModel, businessId)
  if not vehicleModel then return false, 0 end
  if not normalizeBusinessId(businessId) then return false, 0 end
  return sellMatchingParts(function(part)
    return part.vehicleModel == vehicleModel and partBelongsToBusiness(part, businessId)
  end)
end

local function getLiquidationValue(businessId)
  if not normalizeBusinessId(businessId) then return 0 end
  if not inventoryLoaded then persistence.load() end
  local totalPrice = 0
  for _, part in pairs(inventory) do
    if part and partBelongsToBusiness(part, businessId) then
      totalPrice = totalPrice + pricePartForSale(part)
    end
  end
  return totalPrice
end

local function clearBusinessParts(businessId)
  if not normalizeBusinessId(businessId) then return 0 end
  if not inventoryLoaded then persistence.load() end
  local removed = 0
  for partId, part in pairs(inventory) do
    if part and partBelongsToBusiness(part, businessId) then
      inventory[partId] = nil
      removed = removed + 1
    end
  end
  persistence.save()
  return removed
end

-- Queries -----------------------------------------------------------------------------------------

local function getInventory()
  return inventory
end

local function getPartsByModel(model, businessId)
  local matching = {}
  local ownerId = normalizeBusinessId(businessId)
  if not ownerId then return matching end
  for _, part in pairs(inventory) do
    if part and part.vehicleModel == model and partBelongsToBusiness(part, ownerId) then
      table.insert(matching, part)
    end
  end
  return matching
end

-- Public API --------------------------------------------------------------------------------------

M.addPart = addPart
M.addParts = addParts
M.removePart = removePart
M.getInventory = getInventory
M.getPartsByModel = getPartsByModel
M.updatePartCondition = updatePartCondition
M.getUIData = getUIData
M.loadInventory = persistence.load
M.saveInventory = persistence.save
M.sellPart = sellPart
M.sellAllParts = sellAllParts
M.sellPartsByVehicle = sellPartsByVehicle
M.getLiquidationValue = getLiquidationValue
M.clearBusinessParts = clearBusinessParts

-- Game hooks --------------------------------------------------------------------------------------

function M.onExtensionLoaded()
  if not overhaul_career_career.isActive() then return false end
  persistence.load()
end

function M.onOverhaulActive()
  persistence.load()
end

function M.onOverhaulSaveCurrentProfile(currentSavePath, _, writer)
  writer = writer or overhaul_career_saveSystem.getSaveWriter()
  persistence.save(currentSavePath, writer)
end

M.onPurchasedBusinessesOwnershipReady = onPurchasedBusinessesOwnershipReady

return M
