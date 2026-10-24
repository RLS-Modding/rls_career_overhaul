-- Import-time cash-out choices applied to an in-memory legacy save.
-- Map: vehicle and part sales, property settlement, option selection, folder preprocessing and reports.
local M = {}

local shapes = require("overhaul/lib/save/migrationShapes")

-- Config --------------------------------------------------------------------------------------------

local manifestFile = "career/rls_career/legacyMigration.json"
local reportFile = "career/rls_career/legacyMigrationReport.json"
local PART_RENAME_VERSION = 3
local INVENTORY_PATH = "career/inventory.json"
local PART_INVENTORY_PATH = "career/partInventory.json"
local MARKETPLACE_PATH = "career/marketplace.json"
local PLAYER_ATTRIBUTES_PATH = "career/playerAttributes.json"
local ATTRIBUTE_LOG_PATH = "career/attributeLog.json"
local INSURANCE_PATH = "career/insurance.json"
local PURCHASED_GARAGES_PATH = "career/rls_career/purchasedGarages.json"
local MORTGAGES_PATH = "career/rls_career/mortgages.json"
local REAL_ESTATE_LISTINGS_PATH = "career/rls_career/realEstateListings.json"
local COOLDOWNS_PATH = "career/rls_career/negotiationCooldowns.json"
local NEGOTIATION_PATH = "career/rls_career/realEstateNegotiationState.json"
local VEHICLE_POLICIES = {sellall = true, individual = true, preserve = true, cashout = true}

-- Storage -------------------------------------------------------------------------------------------

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, child in pairs(value) do result[key] = copy(child) end
  return result
end

-- jsonReadFile: only decoded JSON entries have data.
local function read(files, file)
  local entry = files[file]
  return type(entry) == "table" and copy(entry.data) or nil
end

-- jsonWriteFileSafe
local function write(files, file, data)
  files[file] = {data = data}
  return true
end

local function exists(files, file)
  return files[file] ~= nil
end

-- FS:findFiles(<slot>/career/vehicles/, "*.json", 0): top-level vehicle records only.
local function vehicleFiles(files)
  local result = {}
  for file in pairs(files) do
    if type(file) == "string" and file:match("^career/vehicles/[^/]+%.json$") then result[#result + 1] = file end
  end
  table.sort(result)
  return result
end

-- Id lists ------------------------------------------------------------------------------------------

-- Distinct converted ids in sorted order; `convert` returns nil for a value to skip.
local function distinctSorted(values, convert)
  local result, seen = {}, {}
  if type(values) ~= "table" then return result end
  for _, value in ipairs(values) do
    local id = convert(value)
    if id ~= nil and not seen[id] then
      seen[id] = true
      table.insert(result, id)
    end
  end
  table.sort(result)
  return result
end

local function normalizeVehicleIds(values)
  return distinctSorted(values, function(value) return tonumber(value) end)
end

local function normalizeGarageIds(values)
  return distinctSorted(values, function(value)
    local id = tostring(value or "")
    if id ~= "" then return id end
  end)
end

local function idsToLookup(values)
  local result = {}
  for _, value in ipairs(values or {}) do
    local id = tonumber(value)
    if id then result[id] = true end
  end
  return result
end

local function stringIdsToLookup(values)
  local result = {}
  for _, value in ipairs(values or {}) do
    local id = tostring(value or "")
    if id ~= "" then result[id] = true end
  end
  return result
end

local function sortedKeys(set)
  local result = {}
  for id in pairs(set) do table.insert(result, id) end
  table.sort(result)
  return result
end

-- Compensation --------------------------------------------------------------------------------------

local function payoutLabel(vehicleCount, partCount, garageCount)
  return string.format(
    "Legacy save migration: sold %d vehicle%s, %d loose part%s, and %d garage%s",
    vehicleCount,
    vehicleCount == 1 and "" or "s",
    partCount,
    partCount == 1 and "" or "s",
    garageCount or 0,
    garageCount == 1 and "" or "s"
  )
end

-- Credits the sale to the player's money and records it in the attribute log.
local function addMigrationCompensation(files, amount, vehicleCount, partCount, garageCount)
  amount = math.max(0, tonumber(amount) or 0)
  if amount <= 0 then return true end

  local attributes = read(files, PLAYER_ATTRIBUTES_PATH)
  if type(attributes) ~= "table" then
    return false, "The copied save has no readable player attributes for the migration payout."
  end

  attributes.money = type(attributes.money) == "table" and attributes.money or {value = 0, gains = {}, losses = {}}
  attributes.money.gains = type(attributes.money.gains) == "table" and attributes.money.gains or {}
  attributes.money.losses = type(attributes.money.losses) == "table" and attributes.money.losses or {}
  attributes.money.value = (tonumber(attributes.money.value) or 0) + amount
  attributes.money.gains.all = (tonumber(attributes.money.gains.all) or 0) + amount
  attributes.money.gains.migration = (tonumber(attributes.money.gains.migration) or 0) + amount
  attributes.money.gains.selling = (tonumber(attributes.money.gains.selling) or 0) + amount

  if not write(files, PLAYER_ATTRIBUTES_PATH, attributes) then
    return false, "The migration payout could not be written to the copied save."
  end

  local attributeLog = read(files, ATTRIBUTE_LOG_PATH)
  if type(attributeLog) ~= "table" then attributeLog = {} end
  table.insert(attributeLog, {
    attributeChange = {money = amount},
    reason = {
      label = payoutLabel(vehicleCount, partCount, garageCount),
      tags = {migration = true, selling = true},
    },
    time = os.time(),
  })
  if not write(files, ATTRIBUTE_LOG_PATH, attributeLog) then
    return false, "The migration payout history could not be written to the copied save."
  end
  return true
end

-- Vehicle cash-out ----------------------------------------------------------------------------------

-- Multiple autosaves may contain the same vehicle; count its configured value only once.
local function tallyCashOutVehicles(files, cashOutVehicleIds)
  local vehicleValue = 0
  local appliedVehicleIds = {}
  for _, inventoryId in ipairs(cashOutVehicleIds) do
    local vehicle = read(files, "career/vehicles/" .. inventoryId .. ".json")
    if type(vehicle) == "table" then
      if vehicle.owned ~= false then
        vehicleValue = vehicleValue + math.max(0, tonumber(vehicle.configBaseValue) or 0)
      end
      table.insert(appliedVehicleIds, inventoryId)
    end
  end
  return vehicleValue, appliedVehicleIds
end

-- Clears the sold vehicles from the inventory's current, last, favourite and spawned references.
local function removeVehicleReferences(inventory, appliedLookup)
  for inventoryId in pairs(appliedLookup) do
    if tonumber(inventory.currentVehicle) == inventoryId then inventory.currentVehicle = nil end
    if tonumber(inventory.lastVehicle) == inventoryId then inventory.lastVehicle = nil end
    if tonumber(inventory.favoriteVehicle) == inventoryId then inventory.favoriteVehicle = nil end
    if type(inventory.spawnedPlayerVehicles) == "table" then
      inventory.spawnedPlayerVehicles[inventoryId] = nil
      inventory.spawnedPlayerVehicles[tostring(inventoryId)] = nil
    end
  end
end

-- Sell loose inventory separately from installed parts already included in a vehicle cash-out.
local function sellCashOutParts(files, appliedLookup, appliedVehicleIds, sellParts)
  local partValue, soldPartCount = 0, 0
  local partInventoryJson = read(files, PART_INVENTORY_PATH)
  if type(partInventoryJson) == "table" and type(partInventoryJson[1]) == "string" then
    local ok, partInventory = pcall(deserialize, partInventoryJson[1])
    if not ok or type(partInventory) ~= "table" then
      return 0, 0, "The copied part inventory could not be decoded."
    end
    local changed = false
    for partId, part in pairs(partInventory) do
      local location = type(part) == "table" and tonumber(part.location) or nil
      if (sellParts and location == 0) or (location and appliedLookup[location]) then
        if sellParts and location == 0 then
          partValue = partValue + math.max(0, tonumber(part.value) or 0)
          soldPartCount = soldPartCount + 1
        end
        partInventory[partId] = nil
        changed = true
      end
    end
    if changed and not write(files, PART_INVENTORY_PATH, {serialize(partInventory)}) then
      return 0, 0, "The copied part inventory could not be updated."
    end
  elseif sellParts and #appliedVehicleIds > 0 then
    return 0, 0, "The copied save has no readable part inventory."
  end
  return partValue, soldPartCount
end

-- Drops the cashed-out vehicles' listings. Returns an error text when the marketplace cannot be written.
local function removeCashOutListings(files, appliedLookup)
  local marketplace = read(files, MARKETPLACE_PATH)
  if type(marketplace) ~= "table" or type(marketplace.listedVehicles) ~= "table" then return nil end
  local changed = false
  for i = #marketplace.listedVehicles, 1, -1 do
    local listing = marketplace.listedVehicles[i]
    if not listing.rtBiz and appliedLookup[tonumber(listing.id)] then
      table.remove(marketplace.listedVehicles, i)
      changed = true
    end
  end
  if changed and not write(files, MARKETPLACE_PATH, marketplace) then
    return "The copied marketplace listings could not be updated."
  end
  return nil
end

local function removeCashOutVehicleFiles(files, appliedLookup)
  for inventoryId in pairs(appliedLookup) do
    files["career/vehicles/" .. inventoryId .. ".json"] = nil
    files["career/vehicles/" .. inventoryId .. ".jpg"] = nil
    files["career/vehicles/damage/" .. inventoryId .. "_damageState.json"] = nil
  end
end

local function emptyVehicleCashOut(appliedVehicleIds)
  return {
    appliedVehicleIds = appliedVehicleIds,
    vehicleValue = 0,
    partValue = 0,
    soldPartCount = 0,
    totalValue = 0,
  }
end

local function preprocessVehicleCashOut(files, cashOutVehicleIds, sellParts)
  local vehicleValue, appliedVehicleIds = tallyCashOutVehicles(files, cashOutVehicleIds)
  local appliedLookup = idsToLookup(appliedVehicleIds)

  local inventory = read(files, INVENTORY_PATH)
  if type(inventory) ~= "table" then
    if #appliedVehicleIds == 0 then return emptyVehicleCashOut(appliedVehicleIds) end
    return nil, "The copied vehicle inventory could not be read."
  end
  removeVehicleReferences(inventory, appliedLookup)
  if not write(files, INVENTORY_PATH, inventory) then
    return nil, "The copied vehicle inventory could not be updated."
  end

  local partValue, soldPartCount, partError = sellCashOutParts(files, appliedLookup, appliedVehicleIds, sellParts)
  if partError then return nil, partError end

  local listingError = removeCashOutListings(files, appliedLookup)
  if listingError then return nil, listingError end

  removeCashOutVehicleFiles(files, appliedLookup)

  local totalValue = vehicleValue + partValue
  local payoutOk, payoutError = addMigrationCompensation(files, totalValue, #appliedVehicleIds, soldPartCount)
  if not payoutOk then return nil, payoutError end

  return {
    appliedVehicleIds = appliedVehicleIds,
    vehicleValue = vehicleValue,
    partValue = partValue,
    soldPartCount = soldPartCount,
    totalValue = totalValue,
  }
end

-- Garage cash-out -----------------------------------------------------------------------------------

local function removeSelectedKeysFromFile(files, filePath, rootKey, selectedIds)
  if not exists(files, filePath) then return true end
  local data = read(files, filePath)
  if type(data) ~= "table" then return false end
  local target = rootKey and data[rootKey] or data
  if type(target) ~= "table" then return true end
  for garageId in pairs(selectedIds) do
    target[garageId] = nil
  end
  return write(files, filePath, data)
end

-- Removes the chosen garages from purchasedGarages.json and sums their sale figures.
local function sellPurchasedGarages(files, purchasedData, cashOutGarageIds, reportById)
  local garageValue, grossGarageValue, mortgageBalanceCleared = 0, 0, 0
  local appliedGarageIds = {}
  for _, garageId in ipairs(cashOutGarageIds) do
    local garage = reportById[garageId]
    if garage and purchasedData.garages[garageId] then
      garageValue = garageValue + math.max(0, tonumber(garage.savedValue) or 0)
      grossGarageValue = grossGarageValue + math.max(0, tonumber(garage.grossSaleValue) or 0)
      mortgageBalanceCleared = mortgageBalanceCleared + math.max(0, tonumber(garage.mortgageBalance) or 0)
      purchasedData.garages[garageId] = nil
      if type(purchasedData.discovered) == "table" then purchasedData.discovered[garageId] = nil end
      table.insert(appliedGarageIds, garageId)
    end
  end
  if #appliedGarageIds > 0 and not write(files, PURCHASED_GARAGES_PATH, purchasedData) then
    return nil, "The copied garage ownership data could not be updated."
  end
  return {
    appliedGarageIds = appliedGarageIds,
    garageValue = garageValue,
    grossGarageValue = grossGarageValue,
    mortgageBalanceCleared = mortgageBalanceCleared,
  }
end

local function clearActiveNegotiation(files, selectedIds)
  if not exists(files, NEGOTIATION_PATH) then return true end
  local negotiation = read(files, NEGOTIATION_PATH)
  if type(negotiation) == "table" and selectedIds[tostring(negotiation.propertyId or "")] then
    return write(files, NEGOTIATION_PATH, {})
  end
  return true
end

-- Vehicles kept in a sold garage lose their location. Returns the count moved, or nil and an error text.
local function relocateVehicles(files, selectedIds)
  local relocatedVehicleCount = 0
  for _, vehiclePath in ipairs(vehicleFiles(files)) do
    local vehicle = read(files, vehiclePath)
    if type(vehicle) == "table" and selectedIds[tostring(vehicle.location or "")] then
      vehicle.location = nil
      vehicle.niceLocation = nil
      if not write(files, vehiclePath, vehicle) then
        return nil, "A retained vehicle could not be moved out of a sold garage."
      end
      relocatedVehicleCount = relocatedVehicleCount + 1
    end
  end
  return relocatedVehicleCount
end

-- Settle property ownership before transferring its cash-out proceeds.
local function clearGarageReferences(files, selectedIds)
  if not removeSelectedKeysFromFile(files, MORTGAGES_PATH, "mortgages", selectedIds) then
    return nil, "The copied mortgage data could not be updated."
  end
  if not removeSelectedKeysFromFile(files, REAL_ESTATE_LISTINGS_PATH, nil, selectedIds) then
    return nil, "The copied property listing data could not be updated."
  end
  if not removeSelectedKeysFromFile(files, COOLDOWNS_PATH, "cooldowns", selectedIds) then
    return nil, "The copied property negotiation data could not be updated."
  end
  if not removeSelectedKeysFromFile(files, COOLDOWNS_PATH, "frozenPrices", selectedIds) then
    return nil, "The copied frozen property pricing data could not be updated."
  end
  if not clearActiveNegotiation(files, selectedIds) then
    return nil, "The copied active property negotiation could not be cleared."
  end
  return relocateVehicles(files, selectedIds)
end

local function preprocessGarageCashOut(files, cashOutGarageIds, reportGarages)
  local selectedIds = stringIdsToLookup(cashOutGarageIds)
  local reportById = {}
  for _, garage in ipairs(reportGarages or {}) do
    reportById[tostring(garage.id)] = garage
  end

  local purchasedData = read(files, PURCHASED_GARAGES_PATH)
  -- Divergent autosaves may lack garage tables; treat as nothing to cash out here.
  if #cashOutGarageIds > 0 and (type(purchasedData) ~= "table" or type(purchasedData.garages) ~= "table") then
    return {
      appliedGarageIds = {},
      garageValue = 0,
      grossGarageValue = 0,
      mortgageBalanceCleared = 0,
      relocatedVehicleCount = 0,
    }
  end

  local sale, saleError = sellPurchasedGarages(files, purchasedData, cashOutGarageIds, reportById)
  if not sale then return nil, saleError end
  local relocatedVehicleCount, clearError = clearGarageReferences(files, selectedIds)
  if not relocatedVehicleCount then return nil, clearError end

  local payoutOk, payoutError = addMigrationCompensation(files, sale.garageValue, 0, 0, #sale.appliedGarageIds)
  if not payoutOk then return nil, payoutError end

  sale.relocatedVehicleCount = relocatedVehicleCount
  return sale
end

-- Insurance -----------------------------------------------------------------------------------------

-- Fresh invVehs rows for the kept vehicles, merged with any salvageable row from the old file.
local function keptVehicleInsuranceRows(files, cashOutVehicleIds, oldInvVehs)
  local cashOutLookup = idsToLookup(cashOutVehicleIds)
  local newInvVehs = {}
  for _, vehiclePath in ipairs(vehicleFiles(files)) do
    local inventoryId = tonumber(vehiclePath:match("([%d]+)%.json$"))
    if inventoryId and not cashOutLookup[inventoryId] then
      local vehicle = read(files, vehiclePath)
      if type(vehicle) == "table" then
        newInvVehs[inventoryId] = shapes.ensureInvVehShape(
          shapes.lookupOldInvVeh(oldInvVehs, inventoryId), inventoryId, vehicle)
      end
    end
  end
  return newInvVehs
end

-- Bumps info.json to the target version, so insurance load does not treat this as a brand-new save.
local function bumpSaveVersion(files, targetVersion)
  local infoPath = "info.json"
  local info = read(files, infoPath)
  if not targetVersion then
    return false, "The copied save version could not be updated after insurance migration."
  end
  if type(info) ~= "table" then
    return false, "The copied save info.json could not be read after insurance migration."
  end
  info.version = tonumber(targetVersion) or info.version
  if not write(files, infoPath, info) then
    return false, "The copied save version could not be updated after insurance migration."
  end
  return true
end

local function preprocessInsurance(files, cashOutVehicleIds, targetVersion)
  local oldData = read(files, INSURANCE_PATH)
  if type(oldData) ~= "table" then oldData = {} end
  local oldInvVehs = type(oldData.invVehs) == "table" and oldData.invVehs or {}
  local newInvVehs = keptVehicleInsuranceRows(files, cashOutVehicleIds, oldInvVehs)
  if not write(files, INSURANCE_PATH, shapes.insuranceData(oldData, newInvVehs)) then
    return false, "The copied insurance data could not be rewritten for migration."
  end
  return bumpSaveVersion(files, targetVersion)
end

-- Plan selection ------------------------------------------------------------------------------------

-- Vehicle ids the report knows, and the ones it marks unavailable.
local function reportVehicleIds(report)
  local knownIds, unavailableIds = {}, {}
  for _, vehicle in ipairs(report.vehicles) do
    knownIds[tonumber(vehicle.id) or vehicle.id] = true
    if not vehicle.available then unavailableIds[tonumber(vehicle.id) or vehicle.id] = true end
  end
  return knownIds, unavailableIds
end

local function garageIdSet(report)
  local ids = {}
  for _, garage in ipairs(report.garages or {}) do
    ids[tostring(garage.id)] = true
  end
  return ids
end

-- Unknown policies fall back to sell-all; sources older than 64 keep their cars unless told otherwise.
local function vehiclePolicyOf(report, options)
  local policy = tostring(options.vehiclePolicy or (report.sourceVersion == 64 and "preserve" or "sellall"))
  if not VEHICLE_POLICIES[policy] then return "sellall" end
  return policy
end

local function pickCashOutVehicles(policy, knownIds, unavailableIds, options)
  if policy == "sellall" then return sortedKeys(knownIds) end
  local picked = {}
  if policy == "individual" then
    for _, id in ipairs(normalizeVehicleIds(options.cashOutVehicleIds)) do
      if knownIds[id] then table.insert(picked, id) end
    end
  elseif policy == "cashout" then
    -- Backwards compatibility for migration manifests created by the first UI.
    for _, id in ipairs(normalizeVehicleIds(options.cashOutVehicleIds)) do
      if unavailableIds[id] then table.insert(picked, id) end
    end
  end
  return picked
end

local function pickCashOutGarages(policy, knownGarageIds, options)
  if policy == "sellall" then return sortedKeys(knownGarageIds) end
  local picked = {}
  if policy == "individual" then
    for _, id in ipairs(normalizeGarageIds(options.cashOutGarageIds)) do
      if knownGarageIds[id] then table.insert(picked, id) end
    end
  end
  return picked
end

-- Unavailable vehicles that are not being cashed out stay quarantined.
local function quarantinedVehicles(unavailableIds, cashOutLookup)
  local quarantined = {}
  for id in pairs(unavailableIds) do
    if not cashOutLookup[id] then table.insert(quarantined, id) end
  end
  return normalizeVehicleIds(quarantined)
end

-- Import choices follow the preflight report so missing ids retain their refusal behavior.
function M.selectPlan(report, options)
  options = type(options) == "table" and options or {}
  if not report.requiresMigration then return nil, "This save does not require migration." end
  if not report.canMigrate or report.blockerCount > 0 then
    return nil, "Resolve the blocking issues before migrating."
  end

  local knownIds, unavailableIds = reportVehicleIds(report)
  local knownGarageIds = garageIdSet(report)
  local vehiclePolicy = vehiclePolicyOf(report, options)
  local cashOutVehicleIds = pickCashOutVehicles(vehiclePolicy, knownIds, unavailableIds, options)
  return {
    report = report,
    vehiclePolicy = vehiclePolicy,
    cashOutVehicleIds = cashOutVehicleIds,
    cashOutGarageIds = pickCashOutGarages(vehiclePolicy, knownGarageIds, options),
    sellParts = vehiclePolicy == "sellall",
    quarantinedVehicleIds = quarantinedVehicles(unavailableIds, idsToLookup(cashOutVehicleIds)),
  }
end

-- Slot runner ---------------------------------------------------------------------------------------

-- Preserve migration order: vehicles, garages, insurance and the destination wallet.
function M.applyToSlot(files, plan, targetVersion)
  local cashOut, cashOutError = preprocessVehicleCashOut(files, plan.cashOutVehicleIds, plan.sellParts)
  if not cashOut then
    return nil, cashOutError or "The copied save could not be prepared safely."
  end
  local garageCashOut, garageError = preprocessGarageCashOut(files, plan.cashOutGarageIds, plan.report.garages)
  if not garageCashOut then
    return nil, garageError or "The copied garage data could not be prepared safely."
  end
  local info = read(files, "info.json")
  local insuranceMigrated = false
  if not info or (tonumber(info.version) or 0) < targetVersion or #plan.cashOutVehicleIds > 0 then
    local insuranceOk, insuranceError = preprocessInsurance(files, cashOut.appliedVehicleIds or {}, targetVersion)
    if not insuranceOk then
      return nil, insuranceError or "The copied insurance data could not be prepared safely."
    end
    insuranceMigrated = true
  end
  return {cashOut = cashOut, garageCashOut = garageCashOut, insuranceMigrated = insuranceMigrated}
end

-- Manifest ------------------------------------------------------------------------------------------

local function manifestOf(plan, primary, profile, targetProfile, targetVersion)
  local report = plan.report
  return {
    schemaVersion = 3,
    status = "prepared",
    createdAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    sourceProfile = profile,
    sourceSaveFolder = report.saveFolder,
    sourceVersion = report.sourceVersion,
    targetVersion = targetVersion,
    targetLayoutVersion = PART_RENAME_VERSION,
    targetProfile = targetProfile,
    vehiclePolicy = plan.vehiclePolicy,
    quarantinedVehicleIds = plan.quarantinedVehicleIds,
    cashOutVehicleIds = plan.cashOutVehicleIds,
    cashOutGarageIds = plan.cashOutGarageIds,
    sellParts = plan.sellParts,
    preprocessed = true,
    compensationAppliedToSave = true,
    vehicleCashOutValue = primary.cashOut.vehicleValue,
    partCashOutValue = primary.cashOut.partValue,
    soldLoosePartCount = primary.cashOut.soldPartCount,
    garageCashOutValue = primary.garageCashOut.garageValue,
    grossGarageCashOutValue = primary.garageCashOut.grossGarageValue,
    mortgageBalanceCleared = primary.garageCashOut.mortgageBalanceCleared,
    soldGarageCount = #primary.garageCashOut.appliedGarageIds,
    relocatedVehicleCount = primary.garageCashOut.relocatedVehicleCount,
    totalCashOutValue = primary.cashOut.totalValue + primary.garageCashOut.garageValue,
  }
end

-- The report's layout results per folder and its cash-out summary.
local function decorateReport(report, primary, layoutReports, primaryFolder, manifest)
  report.layoutMigration = layoutReports[primaryFolder]
  report.layoutMigrationsByFolder = layoutReports
  report.cashOut = {
    vehiclesSold = #(primary.cashOut.appliedVehicleIds or {}),
    garagesSold = manifest.soldGarageCount,
    loosePartsSold = manifest.soldLoosePartCount,
    amountCredited = manifest.totalCashOutValue,
  }
end

-- Every copied folder receives the same migration choices and primary-folder report.
function M.writeManifest(files, plan, primary, layoutReports, primaryFolder, profile, targetProfile, targetVersion)
  local report = plan.report
  local manifest = manifestOf(plan, primary, profile, targetProfile, targetVersion)
  decorateReport(report, primary, layoutReports, primaryFolder, manifest)
  write(files, manifestFile, manifest)
  write(files, reportFile, copy(report))
  return manifest
end

M.manifestFile = manifestFile
M.reportFile = reportFile

return M
