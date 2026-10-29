-- Older-save migration: scans a save, prepares a migrated copy (cash-out of chosen vehicles and garages) and runs the 0.40 part-rename pass.
-- Rename and shape rules live in lib/save/partMigration040.lua and migrationShapes.lua; read top-down from the preflight to the profile hooks.
local M = {}

-- Requires ----------------------------------------------------------------------------------------

-- SaveStore keys over the files this module writes (metadata only).
require("overhaul/lib/save/store").registerKeys({
  {key = "migration.layoutMarker", owner = "overhaul_career_saveMigration", files = {"career/rls_career/partRenames040.json"}, phase = "profile", required = true},
  {key = "migration.manifest", owner = "overhaul_career_saveMigration", files = {"career/rls_career/legacyMigration.json"}, phase = "profile", required = true},
})

local partMigration = require("overhaul/lib/save/partMigration040")
local migrationShapes = require("overhaul/lib/save/migrationShapes")

-- Config ------------------------------------------------------------------------------------------

local LOG_TAG = "career.saveMigration"
local MANIFEST_PATH = "/career/rls_career/legacyMigration.json"
local REPORT_PATH = "/career/rls_career/legacyMigrationReport.json"
local PART_RENAME_MARKER_PATH = "/career/rls_career/partRenames040.json"
local PART_RENAME_VERSION = 3
-- Saves at this version may predate the 0.40 part renames, so the layout marker decides.
local LAYOUT_RENAME_SAVE_VERSION = 64
-- A sold garage pays this share of its market value.
local GARAGE_SALE_RATIO = 0.75
local VEHICLE_POLICIES = { sellall = true, individual = true, preserve = true, cashout = true }

-- State -------------------------------------------------------------------------------------------

-- Report waiting for the profile screen to show the migration prompt.
local pendingMigrationReport
-- Plan prepared for the loaded save; the save hook writes it back to disk.
local activeMigrationPlan
-- Applied this session; disk is updated only by the save hook, so this blocks a second apply.
local appliedThisSession = {}
-- Set once the current profile's part-rename marker has been checked.
local partRenamesDoneForSession = false
-- Warnings collected by one applyPartRenames pass; nil outside that pass.
local partMigrationWarnings

-- Save paths and layout ---------------------------------------------------------------------------

local function isSaveLayoutCurrent(savePath)
  local marker = require("overhaul/lib/save/sourcePaths").readJson(savePath .. PART_RENAME_MARKER_PATH)
  return type(marker) == "table" and (tonumber(marker.version) or 0) >= PART_RENAME_VERSION
end

local function requiresSaveMigration(savePath, info)
  local version = type(info) == "table" and tonumber(info.version)
  local target = overhaul_career_saveSystem.getSaveSystemVersion()
  return version ~= nil and (version < target or (version == LAYOUT_RENAME_SAVE_VERSION and not isSaveLayoutCurrent(savePath)))
end

local function splitSavePath(savePath)
  if type(savePath) ~= "string" then return nil end
  return savePath:match("([^/\\]+)$")
end

local function getSavePath(profile, specificSaveFolder)
  if type(profile) ~= "string" or profile == "" then return nil end

  local saveRoot = overhaul_career_saveSystem.getSaveRootDirectory()
  if specificSaveFolder and specificSaveFolder ~= "" then
    local candidate = saveRoot .. profile .. "/" .. specificSaveFolder
    if FS:directoryExists(candidate) then return candidate end
    return nil
  end

  local newest = overhaul_career_saveSystem.getNewestSave(saveRoot .. profile)
  if newest and newest ~= "" then return newest end
  return nil
end

-- Strips earlier " (Migrated 0.40)" suffixes, then adds the first free name.
local function getUniqueMigrationName(profile)
  local saveRoot = overhaul_career_saveSystem.getSaveRootDirectory()
  local name = tostring(profile)
  repeat
    local stripped = name:gsub("%s*%(Migrated 0%.%d+%)%s*%d*%s*$", "")
    if stripped == name then break end
    name = stripped
  until false

  local base = name .. " (Migrated 0.40)"
  local candidate = base
  local suffix = 2
  while FS:directoryExists(saveRoot .. candidate) do
    candidate = base .. " " .. suffix
    suffix = suffix + 1
  end
  return candidate
end

-- Content checks ----------------------------------------------------------------------------------

-- Checks for jbeam files directly; core_vehicles.getModel() would build the whole vehicle cache and stall the profile screen.
local function modelExists(model)
  if type(model) ~= "string" or model == "" then return false end
  local vehicleDir = "/vehicles/" .. model .. "/"
  if not FS:directoryExists(vehicleDir) then return false end
  local jbeamFiles = FS:findFiles(vehicleDir, "*.jbeam", -1, false, false)
  return type(jbeamFiles) == "table" and #jbeamFiles > 0
end

-- Modern levels ship a main/ scene tree, not the legacy main.level.json that path.getPathLevelMain returns.
local function levelExists(level)
  if type(level) ~= "string" or level == "" then return false, nil end

  local levelDir = "/levels/" .. level .. "/"
  if not FS:directoryExists(levelDir) then return false, levelDir end

  local sceneTreeDir = levelDir .. "main/"
  if FS:directoryExists(sceneTreeDir) then return true, sceneTreeDir end

  local legacyMain = path.getPathLevelMain(level)
  if legacyMain and FS:fileExists(legacyMain) then return true, legacyMain end

  local missionFiles = FS:findFiles(levelDir, "*.mis", 1, true, false)
  if #missionFiles > 0 then return true, missionFiles[1] end

  return false, levelDir
end

-- Saved parts data rebuilds the car even when its original .pc file is gone, so the file is only a fallback.
local function configExists(config)
  if type(config) ~= "table" then return false, nil end

  local filename = config.partConfigFilename
  if type(filename) ~= "string" or filename == "" then
    filename = nil
  elseif filename:sub(1, 1) ~= "/" then
    filename = "/" .. filename
  end

  local partsTree = config.partsTree
  if type(partsTree) == "table" and next(partsTree) ~= nil then return true, filename end

  local parts = config.parts
  if type(parts) == "table" and next(parts) ~= nil then return true, filename end

  if filename then return FS:fileExists(filename), filename end
  return false, filename
end

-- Saved-file readers ------------------------------------------------------------------------------

local function getGarageFacilityIndex()
  local result = {}
  local facilityFiles = FS:findFiles("/levels/", "*.facilities.json", -1, false, false)
  table.sort(facilityFiles)
  for _, facilityFile in ipairs(facilityFiles) do
    local data = jsonReadFile(facilityFile)
    if type(data) == "table" and type(data.garages) == "table" then
      local level = facilityFile:match("^/levels/([^/]+)/")
      for _, garage in ipairs(data.garages) do
        if type(garage) == "table" and type(garage.id) == "string" and not result[garage.id] then
          result[garage.id] = {
            id = garage.id,
            name = garage.name or garage.id,
            defaultPrice = math.max(0, tonumber(garage.defaultPrice) or 0),
            capacity = math.max(0, tonumber(garage.capacity) or 0),
            starterGarage = garage.starterGarage == true,
            level = level,
          }
        end
      end
    end
  end
  return result
end

local function getSavedHousingMarketIndex(savePath)
  local economy = jsonReadFile(savePath .. "/career/rls_career/globalEconomy.json")
  local index = type(economy) == "table"
    and type(economy.housingMarket) == "table"
    and tonumber(economy.housingMarket.index)
    or nil
  return index and math.max(0, index) or 1
end

-- Mirrors the persisted difficulty mode (difficultyMode.json, else the legacy hardcore.json); hardcore careers pay for the starter garage.
local function isSavedHardcore(savePath)
  local difficulty = jsonReadFile(savePath .. "/career/rls_career/difficultyMode.json")
  if type(difficulty) == "table" and type(difficulty.mode) == "string" then
    return string.lower(difficulty.mode) == "hardcore"
  end
  local legacy = jsonReadFile(savePath .. "/career/rls_career/hardcore.json")
  return type(legacy) == "table" and legacy.hardcoreMode == true
end

local function getSavedMortgages(savePath)
  local data = jsonReadFile(savePath .. "/career/rls_career/mortgages.json")
  return type(data) == "table" and type(data.mortgages) == "table" and data.mortgages or {}
end

-- Report helpers ----------------------------------------------------------------------------------

local function addIssue(report, severity, code, title, detail, extra)
  local issue = {
    severity = severity,
    code = code,
    title = title,
    detail = detail,
  }
  if type(extra) == "table" then
    for key, value in pairs(extra) do issue[key] = value end
  end
  table.insert(report.issues, issue)
  if severity == "blocker" then
    report.blockerCount = report.blockerCount + 1
  elseif severity == "action" then
    report.actionCount = report.actionCount + 1
  else
    report.warningCount = report.warningCount + 1
  end
end

-- Scans and preflight -----------------------------------------------------------------------------

local function buildVehicleRecord(vehicleData)
  local availableModel = modelExists(vehicleData.model)
  local availableConfig, configPath = configExists(vehicleData.config)
  local available = availableModel and availableConfig
  return {
    id = tonumber(vehicleData.id) or vehicleData.id,
    name = vehicleData.niceName or vehicleData.model or "Unknown vehicle",
    model = vehicleData.model,
    configPath = configPath,
    savedValue = tonumber(vehicleData.configBaseValue) or 0,
    owned = vehicleData.owned ~= false,
    loanType = vehicleData.loanType,
    location = vehicleData.location,
    niceLocation = vehicleData.niceLocation,
    available = available,
    modelAvailable = availableModel,
    configAvailable = availableConfig,
    recommendedAction = available and "preserve" or "quarantine",
    issues = {},
  }
end

-- Every career vehicle is recorded; one with a missing model or config is flagged for review, not dropped.
local function scanLegacyVehicleRecords(report, savePath)
  local vehicleFiles = FS:findFiles(savePath .. "/career/vehicles/", "*.json", 0, false, false)
  table.sort(vehicleFiles)
  for _, vehicleFile in ipairs(vehicleFiles) do
    local vehicleData = jsonReadFile(vehicleFile)
    if type(vehicleData) ~= "table" then
      report.canMigrate = false
      addIssue(
        report,
        "blocker",
        "vehicle.unreadable",
        "Vehicle record cannot be migrated safely",
        splitSavePath(vehicleFile) or tostring(vehicleFile)
      )
    else
      local vehicle = buildVehicleRecord(vehicleData)
      report.vehicleCount = report.vehicleCount + 1
      if vehicle.available then
        report.compatibleVehicleCount = report.compatibleVehicleCount + 1
      else
        report.incompatibleVehicleCount = report.incompatibleVehicleCount + 1
        if not vehicle.modelAvailable then table.insert(vehicle.issues, "Vehicle model is missing or disabled") end
        if not vehicle.configAvailable then table.insert(vehicle.issues, "Saved configuration is missing") end
        addIssue(
          report,
          "action",
          "vehicle.contentMissing",
          string.format("%s cannot currently be spawned", tostring(vehicle.name)),
          table.concat(vehicle.issues, ". ") .. ". It is highlighted for review before migration.",
          {vehicleId = vehicle.id, contentId = vehicle.model}
        )
      end
      table.insert(report.vehicles, vehicle)
    end
  end
end

-- Values one owned garage: market value, mortgage balance and what a sale would credit.
local function buildGarageRecord(garageId, facilityIndex, mortgages, housingMarketIndex, hardcore)
  local facility = facilityIndex[tostring(garageId)]
  local mortgage = mortgages[tostring(garageId)]
  local mortgageBalance = type(mortgage) == "table"
    and math.max(0, tonumber(mortgage.remainingBalance or mortgage.principal) or 0)
    or 0
  -- Same rule as garageManager.getGarageSellPrice: outside hardcore the starter garage was granted free and sells for 0.
  local freeStarter = facility ~= nil and facility.starterGarage and not hardcore
  local marketValue = (facility and not freeStarter)
    and math.floor(facility.defaultPrice * housingMarketIndex + 0.5)
    or 0
  local grossSaleValue = math.floor(marketValue * GARAGE_SALE_RATIO + 0.5)
  return {
    id = tostring(garageId),
    name = facility and facility.name or tostring(garageId),
    level = facility and facility.level or nil,
    capacity = facility and facility.capacity or 0,
    available = facility ~= nil,
    freeStarterGarage = freeStarter or nil,
    marketValue = marketValue,
    grossSaleValue = grossSaleValue,
    mortgageBalance = mortgageBalance,
    savedValue = math.max(0, grossSaleValue - mortgageBalance),
    vehicleCount = 0,
    issues = {},
  }
end

local function scanLegacyGarageOwnership(report, savePath)
  local purchasedGarageData = jsonReadFile(savePath .. "/career/rls_career/purchasedGarages.json")
  if type(purchasedGarageData) ~= "table" or type(purchasedGarageData.garages) ~= "table" then return end

  local facilityIndex = getGarageFacilityIndex()
  local housingMarketIndex = getSavedHousingMarketIndex(savePath)
  local mortgages = getSavedMortgages(savePath)
  local hardcore = isSavedHardcore(savePath)
  for garageId, owned in pairs(purchasedGarageData.garages) do
    if owned then
      local garage = buildGarageRecord(garageId, facilityIndex, mortgages, housingMarketIndex, hardcore)
      for _, vehicle in ipairs(report.vehicles) do
        if tostring(vehicle.location or "") == garage.id then garage.vehicleCount = garage.vehicleCount + 1 end
      end

      report.garageCount = report.garageCount + 1
      if garage.available then
        report.availableGarageCount = report.availableGarageCount + 1
      else
        report.unavailableGarageCount = report.unavailableGarageCount + 1
        table.insert(garage.issues, "Garage content is missing or disabled")
        addIssue(
          report,
          "action",
          "garage.contentMissing",
          string.format("%s cannot currently be found", tostring(garage.name)),
          "Its ownership record is highlighted for review and can be safely removed during migration.",
          {garageId = garage.id, contentId = garage.id}
        )
      end
      table.insert(report.garages, garage)
    end
  end
  table.sort(report.garages, function(a, b)
    return tostring(a.name):lower() < tostring(b.name):lower()
  end)
end

local function newPreflightReport(profile, specificSaveFolder, savePath, targetVersion)
  return {
    schemaVersion = 1,
    profile = profile,
    saveFolder = specificSaveFolder,
    savePath = savePath,
    sourceVersion = nil,
    targetVersion = targetVersion,
    requiresMigration = false,
    preparedMigration = false,
    canMigrate = true,
    blockerCount = 0,
    actionCount = 0,
    warningCount = 0,
    vehicleCount = 0,
    compatibleVehicleCount = 0,
    incompatibleVehicleCount = 0,
    vehicles = {},
    garageCount = 0,
    availableGarageCount = 0,
    unavailableGarageCount = 0,
    garages = {},
    issues = {},
    defaultTargetProfile = getUniqueMigrationName(profile),
  }
end

local function readSaveInfoFields(report, savePath, profile, info)
  report.sourceVersion = tonumber(info.version)
  report.displayName = info.displayName or profile
  report.defaultTargetProfile = getUniqueMigrationName(report.displayName)
  report.corrupted = info.corrupted == true
  report.requiresLayoutMigration = report.sourceVersion ~= nil
    and report.sourceVersion <= LAYOUT_RENAME_SAVE_VERSION
    and not isSaveLayoutCurrent(savePath)
  report.requiresMigration = requiresSaveMigration(savePath, info)
  report.sourceLabel = report.sourceVersion == LAYOUT_RENAME_SAVE_VERSION and "RLS 0.39 save" or ("Legacy Career v" .. tostring(report.sourceVersion))
  report.targetLabel = "0.40"
  report.migrationLabel = report.sourceLabel .. " → " .. report.targetLabel
end

-- A prepared plan counts only for the current save version and with the layout marker in place.
local function markPreparedMigration(report, savePath, profile)
  local prepared = jsonReadFile(savePath .. MANIFEST_PATH)
  if type(prepared) == "table" and prepared.targetVersion == report.targetVersion and isSaveLayoutCurrent(savePath) then
    report.preparedMigration = true
    report.defaultTargetProfile = profile
  end
end

local function addSaveStateBlockers(report, minimumVersion)
  if report.corrupted then
    report.canMigrate = false
    addIssue(report, "blocker", "save.corrupted", "Save is marked corrupted", "Choose an earlier healthy autosave before migrating.")
  end

  if not report.sourceVersion then
    report.canMigrate = false
    addIssue(report, "blocker", "save.versionMissing", "Save version is missing", "The migration path cannot be selected safely.")
  elseif report.sourceVersion < minimumVersion then
    report.canMigrate = false
    addIssue(
      report,
      "blocker",
      "save.unsupported",
      "Save version is too old",
      string.format("Version %d is older than the supported migration floor (%d).", report.sourceVersion, minimumVersion)
    )
  elseif report.sourceVersion > report.targetVersion then
    report.canMigrate = false
    addIssue(
      report,
      "blocker",
      "save.newer",
      "Save was created by a newer Career version",
      string.format("This build supports version %d, but the save is version %d.", report.targetVersion, report.sourceVersion)
    )
  end
end

local function checkSavedLevel(report, savePath)
  local general = jsonReadFile(savePath .. "/career/general.json")
  report.level = type(general) == "table" and general.level or nil
  if not report.level then
    report.canMigrate = false
    addIssue(report, "blocker", "map.unknown", "Saved map is unknown", "career/general.json does not contain a level.")
    return
  end

  local levelAvailable, levelPath = levelExists(report.level)
  report.levelPath = levelPath
  if not levelAvailable then
    report.canMigrate = false
    addIssue(
      report,
      "blocker",
      "map.missing",
      "Required map is missing",
      string.format("The save requires '%s', but that level is not currently mounted.", tostring(report.level)),
      {contentId = report.level}
    )
  end
end

local function checkSavedInventory(report, savePath)
  local inventory = jsonReadFile(savePath .. "/career/inventory.json")
  if type(inventory) ~= "table" then
    report.canMigrate = false
    addIssue(report, "blocker", "inventory.missing", "Vehicle inventory is unreadable", "career/inventory.json is missing or invalid.")
  end
end

local function buildLegacySavePreflight(profile, specificSaveFolder, sourceSavePath, forceScan)
  local targetVersion = overhaul_career_saveSystem.getSaveSystemVersion()
  local minimumVersion = overhaul_career_saveSystem.getBackwardsCompVersion()
  local savePath = sourceSavePath or getSavePath(profile, specificSaveFolder)
  local report = newPreflightReport(profile, specificSaveFolder, savePath, targetVersion)

  if not savePath then
    report.canMigrate = false
    addIssue(report, "blocker", "save.missing", "Save data was not found", "No readable save folder could be selected.")
    return report
  end

  report.saveFolder = splitSavePath(savePath)
  local info = jsonReadFile(savePath .. "/info.json")
  if type(info) ~= "table" then
    report.canMigrate = false
    addIssue(report, "blocker", "save.infoMissing", "Save metadata is unreadable", "The selected save has no readable info.json.")
    return report
  end

  readSaveInfoFields(report, savePath, profile, info)
  -- The load gate calls this on every career load, so skip the content scans unless a migration needs them.
  if not report.requiresMigration and not forceScan then
    report.contentScanSkipped = true
    return report
  end

  markPreparedMigration(report, savePath, profile)
  addSaveStateBlockers(report, minimumVersion)
  checkSavedLevel(report, savePath)
  checkSavedInventory(report, savePath)
  scanLegacyVehicleRecords(report, savePath)
  scanLegacyGarageOwnership(report, savePath)

  if report.requiresMigration then
    addIssue(
      report,
      "warning",
      "save.versionUpgrade",
      "Legacy Career data requires migration",
      report.migrationLabel .. ". A migrated copy will be created; the original is kept unchanged."
    )
  end
  return report
end

local function getLegacySavePreflight(profile, specificSaveFolder)
  return buildLegacySavePreflight(profile, specificSaveFolder)
end

-- Read-only: the importer's slot under settings/cloud/saves/, always fully scanned.
local function getSourceSavePreflight(profile, sourceSavePath)
  if type(sourceSavePath) ~= "string" or sourceSavePath == "" then return nil end
  return buildLegacySavePreflight(profile, nil, sourceSavePath, true)
end

-- Cash-out helpers --------------------------------------------------------------------------------

local function normalizeVehicleIds(values)
  local result = {}
  local seen = {}
  if type(values) ~= "table" then return result end
  for _, value in ipairs(values) do
    local id = tonumber(value)
    if id and not seen[id] then
      seen[id] = true
      table.insert(result, id)
    end
  end
  table.sort(result)
  return result
end

local function normalizeGarageIds(values)
  local result = {}
  local seen = {}
  if type(values) ~= "table" then return result end
  for _, value in ipairs(values) do
    local id = tostring(value or "")
    if id ~= "" and not seen[id] then
      seen[id] = true
      table.insert(result, id)
    end
  end
  table.sort(result)
  return result
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

-- Adds the payout to the copied save's money and its attribute log; false with a player-facing reason on write failure.
local function addMigrationCompensation(targetSavePath, amount, vehicleCount, partCount, garageCount)
  amount = math.max(0, tonumber(amount) or 0)
  if amount <= 0 then return true end

  local attributesPath = targetSavePath .. "/career/playerAttributes.json"
  local attributes = jsonReadFile(attributesPath)
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

  if not overhaul_career_saveSystem.jsonWriteFileSafe(attributesPath, attributes, true) then
    return false, "The migration payout could not be written to the copied save."
  end

  local attributeLogPath = targetSavePath .. "/career/attributeLog.json"
  local attributeLog = jsonReadFile(attributeLogPath)
  if type(attributeLog) ~= "table" then attributeLog = {} end
  table.insert(attributeLog, {
    attributeChange = {money = amount},
    reason = {
      label = string.format(
        "Legacy save migration: sold %d vehicle%s, %d loose part%s, and %d garage%s",
        vehicleCount,
        vehicleCount == 1 and "" or "s",
        partCount,
        partCount == 1 and "" or "s",
        garageCount or 0,
        garageCount == 1 and "" or "s"
      ),
      tags = {migration = true, selling = true},
    },
    time = os.time(),
  })
  if not overhaul_career_saveSystem.jsonWriteFileSafe(attributeLogPath, attributeLog, true) then
    return false, "The migration payout history could not be written to the copied save."
  end
  return true
end

-- Vehicle cash-out ----------------------------------------------------------------------------------

-- Reads the selected vehicle records in this folder; a missing record is a no-op because autosave copies can diverge.
local function readCashOutVehicles(targetSavePath, cashOutVehicleIds)
  local vehicleValue = 0
  local appliedVehicleIds = {}
  for _, inventoryId in ipairs(cashOutVehicleIds) do
    local vehicle = jsonReadFile(targetSavePath .. "/career/vehicles/" .. inventoryId .. ".json")
    if type(vehicle) == "table" then
      if vehicle.owned ~= false then
        vehicleValue = vehicleValue + math.max(0, tonumber(vehicle.configBaseValue) or 0)
      end
      table.insert(appliedVehicleIds, inventoryId)
    end
  end
  return appliedVehicleIds, vehicleValue
end

-- Forgets the cashed-out vehicles in the inventory's current, last, favourite and spawned pointers.
local function forgetInventoryVehicles(inventory, appliedLookup)
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

-- Sells loose parts (sell-all) and parts installed on cashed-out vehicles; returns value, count and an error.
local function cashOutPartInventory(targetSavePath, appliedLookup, sellParts, appliedVehicleCount)
  local partValue = 0
  local soldPartCount = 0
  local partInventoryPath = targetSavePath .. "/career/partInventory.json"
  local partInventoryJson = jsonReadFile(partInventoryPath)
  if type(partInventoryJson) == "table" and type(partInventoryJson[1]) == "string" then
    local decoded, partInventory = pcall(deserialize, partInventoryJson[1])
    if not decoded or type(partInventory) ~= "table" then
      return 0, 0, "The copied part inventory could not be decoded."
    end
    local changed = false
    for partId, part in pairs(partInventory) do
      local location = type(part) == "table" and tonumber(part.location) or nil
      -- Parts installed on a vehicle that exists only in this older autosave stay, or that vehicle loses them.
      if (sellParts and location == 0) or (location and appliedLookup[location]) then
        if sellParts and location == 0 then
          partValue = partValue + math.max(0, tonumber(part.value) or 0)
          soldPartCount = soldPartCount + 1
        end
        partInventory[partId] = nil
        changed = true
      end
    end
    if changed and not overhaul_career_saveSystem.jsonWriteFileSafe(partInventoryPath, {serialize(partInventory)}, true) then
      return 0, 0, "The copied part inventory could not be updated."
    end
  elseif sellParts and appliedVehicleCount > 0 then
    return 0, 0, "The copied save has no readable part inventory."
  end
  return partValue, soldPartCount, nil
end

-- Removes listings of cashed-out vehicles; returns an error when the write fails.
local function removeCashedOutListings(targetSavePath, appliedLookup)
  local marketplacePath = targetSavePath .. "/career/marketplace.json"
  local marketplace = jsonReadFile(marketplacePath)
  if type(marketplace) ~= "table" or type(marketplace.listedVehicles) ~= "table" then return nil end

  local changed = false
  for index = #marketplace.listedVehicles, 1, -1 do
    local listing = marketplace.listedVehicles[index]
    if not listing.rtBiz and appliedLookup[tonumber(listing.id)] then
      table.remove(marketplace.listedVehicles, index)
      changed = true
    end
  end
  if changed and not overhaul_career_saveSystem.jsonWriteFileSafe(marketplacePath, marketplace, true) then
    return "The copied marketplace listings could not be updated."
  end
  return nil
end

local function preprocessVehicleCashOut(targetSavePath, cashOutVehicleIds, sellParts)
  local appliedVehicleIds, vehicleValue = readCashOutVehicles(targetSavePath, cashOutVehicleIds)
  local appliedLookup = idsToLookup(appliedVehicleIds)

  local inventoryPath = targetSavePath .. "/career/inventory.json"
  local inventory = jsonReadFile(inventoryPath)
  if type(inventory) ~= "table" then
    if #appliedVehicleIds == 0 then
      return {
        appliedVehicleIds = appliedVehicleIds,
        vehicleValue = 0,
        partValue = 0,
        soldPartCount = 0,
        totalValue = 0,
      }
    end
    return nil, "The copied vehicle inventory could not be read."
  end
  forgetInventoryVehicles(inventory, appliedLookup)
  if not overhaul_career_saveSystem.jsonWriteFileSafe(inventoryPath, inventory, true) then
    return nil, "The copied vehicle inventory could not be updated."
  end

  local partValue, soldPartCount, partError = cashOutPartInventory(targetSavePath, appliedLookup, sellParts, #appliedVehicleIds)
  if partError then return nil, partError end
  local listingError = removeCashedOutListings(targetSavePath, appliedLookup)
  if listingError then return nil, listingError end

  for inventoryId in pairs(appliedLookup) do
    FS:removeFile(targetSavePath .. "/career/vehicles/" .. inventoryId .. ".json")
    FS:removeFile(targetSavePath .. "/career/vehicles/" .. inventoryId .. ".jpg")
    FS:removeFile(targetSavePath .. "/career/vehicles/damage/" .. inventoryId .. "_damageState.json")
  end

  local totalValue = vehicleValue + partValue
  local payoutOk, payoutError = addMigrationCompensation(targetSavePath, totalValue, #appliedVehicleIds, soldPartCount)
  if not payoutOk then return nil, payoutError end

  return {
    appliedVehicleIds = appliedVehicleIds,
    vehicleValue = vehicleValue,
    partValue = partValue,
    soldPartCount = soldPartCount,
    totalValue = totalValue,
  }
end

-- Rebuilds insurance.json for the kept fleet and bumps info.json to targetVersion, so insurance load does not wipe the bookkeeping as a new save.
local function preprocessInsurance(targetSavePath, cashOutVehicleIds, targetVersion)
  local insurancePath = targetSavePath .. "/career/insurance.json"
  local oldData = jsonReadFile(insurancePath)
  if type(oldData) ~= "table" then oldData = {} end

  local cashOutLookup = idsToLookup(cashOutVehicleIds)
  local oldInvVehs = type(oldData.invVehs) == "table" and oldData.invVehs or {}

  local newInvVehs = {}
  local vehicleFiles = FS:findFiles(targetSavePath .. "/career/vehicles/", "*.json", 0, false, false)
  for _, vehiclePath in ipairs(vehicleFiles) do
    local inventoryId = tonumber(vehiclePath:match("([%d]+)%.json$"))
    if inventoryId and not cashOutLookup[inventoryId] then
      local vehicle = jsonReadFile(vehiclePath)
      if type(vehicle) == "table" then
        newInvVehs[inventoryId] = migrationShapes.ensureInvVehShape(
          migrationShapes.lookupOldInvVeh(oldInvVehs, inventoryId), inventoryId, vehicle)
      end
    end
  end

  local newData = migrationShapes.insuranceData(oldData, newInvVehs)
  if not overhaul_career_saveSystem.jsonWriteFileSafe(insurancePath, newData, true) then
    return false, "The copied insurance data could not be rewritten for migration."
  end

  local infoPath = targetSavePath .. "/info.json"
  local info = jsonReadFile(infoPath)
  if not targetVersion then
    return false, "The copied save version could not be updated after insurance migration."
  end
  if type(info) ~= "table" then
    return false, "The copied save info.json could not be read after insurance migration."
  end
  info.version = tonumber(targetVersion) or info.version
  if not overhaul_career_saveSystem.jsonWriteFileSafe(infoPath, info, true) then
    return false, "The copied save version could not be updated after insurance migration."
  end
  return true
end

local function removeSelectedKeysFromFile(filePath, rootKey, selectedIds)
  if not FS:fileExists(filePath) then return true end
  local data = jsonReadFile(filePath)
  if type(data) ~= "table" then return false end
  local target = rootKey and data[rootKey] or data
  if type(target) ~= "table" then return true end
  for garageId in pairs(selectedIds) do target[garageId] = nil end
  return overhaul_career_saveSystem.jsonWriteFileSafe(filePath, data, true)
end

-- Garage sales --------------------------------------------------------------------------------------

-- Garage-keyed records cleared in this order; a nil rootKey clears the file's top-level keys.
local SOLD_GARAGE_KEY_FILES = {
  {file = "mortgages.json", rootKey = "mortgages", failure = "The copied mortgage data could not be updated."},
  {file = "realEstateListings.json", failure = "The copied property listing data could not be updated."},
  {file = "negotiationCooldowns.json", rootKey = "cooldowns", failure = "The copied property negotiation data could not be updated."},
  {file = "negotiationCooldowns.json", rootKey = "frozenPrices", failure = "The copied frozen property pricing data could not be updated."},
}

-- Drops the sold garages from the ownership record; returns the sale totals, or nil and an error when the write fails.
local function sellPurchasedGarages(purchasedPath, purchasedData, cashOutGarageIds, reportById)
  local sales = {appliedGarageIds = {}, garageValue = 0, grossGarageValue = 0, mortgageBalanceCleared = 0}
  for _, garageId in ipairs(cashOutGarageIds) do
    local garage = reportById[garageId]
    if garage and purchasedData.garages[garageId] then
      sales.garageValue = sales.garageValue + math.max(0, tonumber(garage.savedValue) or 0)
      sales.grossGarageValue = sales.grossGarageValue + math.max(0, tonumber(garage.grossSaleValue) or 0)
      sales.mortgageBalanceCleared = sales.mortgageBalanceCleared + math.max(0, tonumber(garage.mortgageBalance) or 0)
      purchasedData.garages[garageId] = nil
      if type(purchasedData.discovered) == "table" then purchasedData.discovered[garageId] = nil end
      table.insert(sales.appliedGarageIds, garageId)
    end
  end

  if #sales.appliedGarageIds > 0 and not overhaul_career_saveSystem.jsonWriteFileSafe(purchasedPath, purchasedData, true) then
    return nil, "The copied garage ownership data could not be updated."
  end
  return sales
end

-- Clears the sold garages from the mortgage, listing, cooldown and negotiation records; returns an error on failure.
local function clearSoldGarageRecords(targetSavePath, selectedIds)
  for _, entry in ipairs(SOLD_GARAGE_KEY_FILES) do
    if not removeSelectedKeysFromFile(targetSavePath .. "/career/rls_career/" .. entry.file, entry.rootKey, selectedIds) then
      return entry.failure
    end
  end

  local negotiationPath = targetSavePath .. "/career/rls_career/realEstateNegotiationState.json"
  if FS:fileExists(negotiationPath) then
    local negotiation = jsonReadFile(negotiationPath)
    if type(negotiation) == "table" and selectedIds[tostring(negotiation.propertyId or "")] then
      if not overhaul_career_saveSystem.jsonWriteFileSafe(negotiationPath, {}, true) then
        return "The copied active property negotiation could not be cleared."
      end
    end
  end
  return nil
end

-- Moves retained vehicles out of sold garages; returns the count, or nil and an error.
local function relocateVehiclesFromSoldGarages(targetSavePath, selectedIds)
  local vehicleFiles = FS:findFiles(targetSavePath .. "/career/vehicles/", "*.json", 0, false, false)
  local relocatedVehicleCount = 0
  for _, vehiclePath in ipairs(vehicleFiles) do
    local vehicle = jsonReadFile(vehiclePath)
    if type(vehicle) == "table" and selectedIds[tostring(vehicle.location or "")] then
      vehicle.location = nil
      vehicle.niceLocation = nil
      if not overhaul_career_saveSystem.jsonWriteFileSafe(vehiclePath, vehicle, true) then
        return nil, "A retained vehicle could not be moved out of a sold garage."
      end
      relocatedVehicleCount = relocatedVehicleCount + 1
    end
  end
  return relocatedVehicleCount
end

local function preprocessGarageCashOut(targetSavePath, cashOutGarageIds, reportGarages)
  local selectedIds = stringIdsToLookup(cashOutGarageIds)
  local reportById = {}
  for _, garage in ipairs(reportGarages or {}) do reportById[tostring(garage.id)] = garage end

  local purchasedPath = targetSavePath .. "/career/rls_career/purchasedGarages.json"
  local purchasedData = jsonReadFile(purchasedPath)
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

  local sales, salesError = sellPurchasedGarages(purchasedPath, purchasedData, cashOutGarageIds, reportById)
  if not sales then return nil, salesError end
  local clearError = clearSoldGarageRecords(targetSavePath, selectedIds)
  if clearError then return nil, clearError end
  local relocatedVehicleCount, relocateError = relocateVehiclesFromSoldGarages(targetSavePath, selectedIds)
  if not relocatedVehicleCount then return nil, relocateError end

  local payoutOk, payoutError = addMigrationCompensation(targetSavePath, sales.garageValue, 0, 0, #sales.appliedGarageIds)
  if not payoutOk then return nil, payoutError end

  sales.relocatedVehicleCount = relocatedVehicleCount
  return sales
end

-- Copied autosave folders ---------------------------------------------------------------------------

-- Vehicles cashed out under the policy: sell-all takes every known vehicle, individual and cashout take the chosen ids.
local function selectCashOutVehicles(options, vehiclePolicy, knownIds, unavailableIds)
  local cashOutVehicleIds = {}
  if vehiclePolicy == "sellall" then
    for id in pairs(knownIds) do table.insert(cashOutVehicleIds, id) end
    table.sort(cashOutVehicleIds)
  elseif vehiclePolicy == "individual" then
    for _, id in ipairs(normalizeVehicleIds(options.cashOutVehicleIds)) do
      if knownIds[id] then table.insert(cashOutVehicleIds, id) end
    end
  elseif vehiclePolicy == "cashout" then
    -- Backwards compatibility for migration manifests created by the first UI.
    for _, id in ipairs(normalizeVehicleIds(options.cashOutVehicleIds)) do
      if unavailableIds[id] then table.insert(cashOutVehicleIds, id) end
    end
  end
  return cashOutVehicleIds
end

local function selectCashOutGarages(options, vehiclePolicy, knownGarageIds)
  local cashOutGarageIds = {}
  if vehiclePolicy == "sellall" then
    for id in pairs(knownGarageIds) do table.insert(cashOutGarageIds, id) end
    table.sort(cashOutGarageIds)
  elseif vehiclePolicy == "individual" then
    for _, id in ipairs(normalizeGarageIds(options.cashOutGarageIds)) do
      if knownGarageIds[id] then table.insert(cashOutGarageIds, id) end
    end
  end
  return cashOutGarageIds
end

local function selectLegacyMigrationCashOut(report, options)
  local knownIds = {}
  local unavailableIds = {}
  for _, vehicle in ipairs(report.vehicles) do
    knownIds[tonumber(vehicle.id) or vehicle.id] = true
    if not vehicle.available then unavailableIds[tonumber(vehicle.id) or vehicle.id] = true end
  end
  local knownGarageIds = {}
  for _, garage in ipairs(report.garages or {}) do knownGarageIds[tostring(garage.id)] = true end

  local vehiclePolicy = tostring(options.vehiclePolicy or (report.sourceVersion == LAYOUT_RENAME_SAVE_VERSION and "preserve" or "sellall"))
  if not VEHICLE_POLICIES[vehiclePolicy] then vehiclePolicy = "sellall" end

  local cashOutVehicleIds = selectCashOutVehicles(options, vehiclePolicy, knownIds, unavailableIds)
  return {
    vehiclePolicy = vehiclePolicy,
    cashOutVehicleIds = cashOutVehicleIds,
    cashOutGarageIds = selectCashOutGarages(options, vehiclePolicy, knownGarageIds),
    unavailableIds = unavailableIds,
    cashOutLookup = idsToLookup(cashOutVehicleIds),
    sellParts = vehiclePolicy == "sellall",
  }
end

-- duplicateSaveSlot copies every autosave. Each one is preprocessed, so a later slot rotation cannot load a stale insurance.json and wipe the fleet.
local function orderCopiedAutosaveFolders(targetProfile, report)
  local targetFolders = {}
  local primaryFolder = report.saveFolder
  for _, folderInfo in ipairs(overhaul_career_saveSystem.getAllSaveFolders(targetProfile) or {}) do
    if folderInfo and folderInfo.name then table.insert(targetFolders, folderInfo.name) end
  end
  if #targetFolders == 0 then
    table.insert(targetFolders, primaryFolder or "autosave1")
  elseif primaryFolder then
    table.sort(targetFolders, function(a, b)
      if a == primaryFolder then return true end
      if b == primaryFolder then return false end
      return tostring(a) < tostring(b)
    end)
  end
  return targetFolders, primaryFolder
end

-- Part renames ------------------------------------------------------------------------------------

local function writePartRenameMarker(savePath, writer)
  writer = writer or overhaul_career_saveSystem.getSaveWriter()
  local dir = savePath .. "/career/rls_career"
  if not writer.exists(dir) then writer.mkdir(dir, true) end
  return writer.json(savePath .. PART_RENAME_MARKER_PATH, {version = PART_RENAME_VERSION}, true)
end

local function partMigrationWarning(message)
  log("W", LOG_TAG, message)
  if partMigrationWarnings then table.insert(partMigrationWarnings, message) end
end

local function runPartRenames(savePath, summary)
  if type(savePath) ~= "string" or savePath == "" then return false end
  if isSaveLayoutCurrent(savePath) then return true end

  local inventoryPath = savePath .. "/career/partInventory.json"
  local inventoryJson = jsonReadFile(inventoryPath)
  local inventory = {}
  if FS:fileExists(inventoryPath) then
    if type(inventoryJson) ~= "table" or type(inventoryJson[1]) ~= "string" then return false end
    inventory = deserialize(inventoryJson[1])
    if type(inventory) ~= "table" then return false end
  end
  local originalInventory = serialize(inventory)
  local beforeInventory = deepcopy(inventory)

  local updates = {}
  local vehicleFiles = FS:findFiles(savePath .. "/career/vehicles/", "*.json", 0, false, false)
  table.sort(vehicleFiles)
  for _, file in ipairs(vehicleFiles) do
    local vehicle = jsonReadFile(file)
    if type(vehicle) ~= "table" then return false end
    vehicle.id = vehicle.id or tonumber(file:match("(%d+)%.json$"))
    if partMigration.migrateVehicleParts040(vehicle, inventory, partMigrationWarning) then updates[#updates + 1] = {file, vehicle} end
  end
  partMigration.migrateLooseParts040(inventory, partMigrationWarning)
  summary.vehiclesMigrated = #updates
  migrationShapes.countPartChanges(inventory, beforeInventory, summary)

  local inventoryData = serialize(inventory)
  if inventoryData ~= originalInventory and not overhaul_career_saveSystem.jsonWriteFileSafe(inventoryPath, {inventoryData}, true) then
    log("E", LOG_TAG, "Could not write migrated part inventory for " .. savePath)
    return false
  end
  for _, update in ipairs(updates) do
    if not overhaul_career_saveSystem.jsonWriteFileSafe(update[1], update[2], true) then
      log("E", LOG_TAG, "Could not write migrated vehicle " .. update[1])
      return false
    end
  end
  if #updates > 0 then log("I", LOG_TAG, string.format("Migrated 0.39 parts on %d vehicle(s) in %s", #updates, savePath)) end
  return writePartRenameMarker(savePath) ~= false
end

-- Returns whether the layout pass succeeded, plus its summary; errors inside the pass are rethrown.
local function applyPartRenames(savePath)
  local summary = {vehiclesMigrated = 0, partsMigrated = 0, itemsMovedToInventory = 0, warnings = {}}
  partMigrationWarnings = summary.warnings
  local ok, result = pcall(runPartRenames, savePath, summary)
  partMigrationWarnings = nil
  if not ok then error(result) end
  return ok and result == true, summary
end

-- Migration preparation ---------------------------------------------------------------------------

local function failedMigration(report, message)
  return {ok = false, error = message, report = report}
end

-- Returns the trimmed copy name, or nil and the refusal when the name is empty or has path characters.
local function chooseMigratedProfileName(report, options)
  local targetProfile = tostring(options.targetProfile or report.defaultTargetProfile or "")
  targetProfile = targetProfile:gsub("^%s+", ""):gsub("%s+$", "")
  if targetProfile == "" or targetProfile:find('[<>:"/\\|?*]') then
    return nil, "Choose a valid name for the migrated copy."
  end
  return targetProfile
end

-- Runs the cash-out, garage sale, insurance and part-rename passes on one copied autosave folder.
local function preprocessCopiedFolder(folderSavePath, report, selection)
  if not FS:directoryExists(folderSavePath) then
    return nil, "The copied save could not be prepared safely."
  end

  local vehicleResult, vehicleError = preprocessVehicleCashOut(folderSavePath, selection.cashOutVehicleIds, selection.sellParts)
  if not vehicleResult then
    return nil, vehicleError or "The copied save could not be prepared safely."
  end

  local garageResult, garageError = preprocessGarageCashOut(folderSavePath, selection.cashOutGarageIds, report.garages)
  if not garageResult then
    return nil, garageError or "The copied garage data could not be prepared safely."
  end

  local folderInfo = jsonReadFile(folderSavePath .. "/info.json")
  local insuranceOk, insuranceError = true, nil
  if not folderInfo or (tonumber(folderInfo.version) or 0) < report.targetVersion or #selection.cashOutVehicleIds > 0 then
    insuranceOk, insuranceError = preprocessInsurance(folderSavePath, vehicleResult.appliedVehicleIds or {}, report.targetVersion)
  end
  if not insuranceOk then
    return nil, insuranceError or "The copied insurance data could not be prepared safely."
  end

  local layoutCallOk, layoutOk, layoutReport = pcall(applyPartRenames, folderSavePath)
  if not layoutCallOk or not layoutOk then
    return nil, "The copied 0.40 parts could not be migrated safely."
  end
  return {vehicle = vehicleResult, garage = garageResult, layoutReport = layoutReport}
end

local function quarantinedVehicleIdsOf(unavailableIds, cashOutLookup)
  local ids = {}
  for id in pairs(unavailableIds) do
    if not cashOutLookup[id] then table.insert(ids, id) end
  end
  return normalizeVehicleIds(ids)
end

local function buildMigrationPlan(profile, targetProfile, report, selection, cashOutResult, garageCashOutResult)
  return {
    schemaVersion = 3,
    status = "prepared",
    createdAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    sourceProfile = profile,
    sourceSaveFolder = report.saveFolder,
    sourceVersion = report.sourceVersion,
    targetVersion = report.targetVersion,
    targetLayoutVersion = PART_RENAME_VERSION,
    targetProfile = targetProfile,
    vehiclePolicy = selection.vehiclePolicy,
    quarantinedVehicleIds = quarantinedVehicleIdsOf(selection.unavailableIds, selection.cashOutLookup),
    cashOutVehicleIds = selection.cashOutVehicleIds,
    cashOutGarageIds = selection.cashOutGarageIds,
    sellParts = selection.sellParts,
    preprocessed = true,
    compensationAppliedToSave = true,
    vehicleCashOutValue = cashOutResult.vehicleValue,
    partCashOutValue = cashOutResult.partValue,
    soldLoosePartCount = cashOutResult.soldPartCount,
    garageCashOutValue = garageCashOutResult.garageValue,
    grossGarageCashOutValue = garageCashOutResult.grossGarageValue,
    mortgageBalanceCleared = garageCashOutResult.mortgageBalanceCleared,
    soldGarageCount = #garageCashOutResult.appliedGarageIds,
    relocatedVehicleCount = garageCashOutResult.relocatedVehicleCount,
    totalCashOutValue = cashOutResult.totalValue + garageCashOutResult.garageValue,
  }
end

-- Writes the plan and the report into every copied folder; false when any write fails.
local function writeMigrationFiles(copiedRoot, targetFolders, plan, report)
  local manifestOk = true
  local reportOk = true
  for _, folderName in ipairs(targetFolders) do
    local folderSavePath = copiedRoot .. "/" .. folderName
    local migrationDir = folderSavePath .. "/career/rls_career"
    if not FS:directoryExists(migrationDir) then FS:directoryCreate(migrationDir, true) end
    manifestOk = manifestOk and overhaul_career_saveSystem.jsonWriteFileSafe(folderSavePath .. MANIFEST_PATH, plan, true)
    reportOk = reportOk and overhaul_career_saveSystem.jsonWriteFileSafe(folderSavePath .. REPORT_PATH, report, true)
  end
  return manifestOk and reportOk
end

-- Refusals that stop before any copy is made; an already-prepared plan is reused as-is.
local function refusalBeforeCopy(profile, report)
  if not report.requiresMigration then
    return failedMigration(report, "This save does not require migration.")
  end
  if not report.canMigrate or report.blockerCount > 0 then
    return failedMigration(report, "Resolve the blocking issues before migrating.")
  end
  if report.preparedMigration then
    return {
      ok = true,
      targetProfile = profile,
      targetSaveFolder = report.saveFolder,
      alreadyPrepared = true,
      report = report,
      summary = report.layoutMigration,
      cashOut = report.cashOut,
    }
  end
  return nil
end

-- Copies the save into the new profile and preprocesses every copied autosave folder; returns the copy or nil and the refusal.
local function copyAndPreprocessFolders(saveRoot, profile, targetProfile, report, selection)
  if not overhaul_career_saveSystem.duplicateSaveSlot(profile, targetProfile, {sourceSaveReady = true}) then
    return nil, "The save copy could not be created."
  end

  local copiedRoot = saveRoot .. targetProfile
  local targetFolders, primaryFolder = orderCopiedAutosaveFolders(targetProfile, report)
  local copy = {copiedRoot = copiedRoot, targetFolders = targetFolders, primaryFolder = primaryFolder, layoutReports = {}}
  for _, folderName in ipairs(targetFolders) do
    local folderSavePath = copiedRoot .. "/" .. folderName
    local folderResult, folderError = preprocessCopiedFolder(folderSavePath, report, selection)
    if not folderResult then
      FS:directoryRemove(copiedRoot)
      return nil, folderError
    end

    copy.layoutReports[folderName] = folderResult.layoutReport
    if not copy.targetSavePath or folderName == primaryFolder then
      copy.targetSavePath = folderSavePath
      copy.vehicle = folderResult.vehicle
      copy.garage = folderResult.garage
    end
  end
  if not copy.targetSavePath then
    FS:directoryRemove(copiedRoot)
    return nil, "The copied save could not be prepared safely."
  end
  return copy
end

-- Records the layout and cash-out summaries on the report, writes the plan to every copied folder, and logs the result.
local function finishMigration(profile, targetProfile, report, copy, plan)
  report.layoutMigration = copy.layoutReports[copy.primaryFolder] or copy.layoutReports[copy.targetFolders[1]]
  report.layoutMigrationsByFolder = copy.layoutReports
  report.cashOut = {
    vehiclesSold = #(copy.vehicle.appliedVehicleIds or {}),
    garagesSold = plan.soldGarageCount,
    loosePartsSold = plan.soldLoosePartCount,
    amountCredited = plan.totalCashOutValue,
  }
  if not writeMigrationFiles(copy.copiedRoot, copy.targetFolders, plan, report) then
    FS:directoryRemove(copy.copiedRoot)
    return failedMigration(report, "The copied save was rolled back because its migration plan could not be written.")
  end

  log(
    "I",
    LOG_TAG,
    string.format(
      "Prepared legacy migration %s/%s -> %s/%s (v%d -> v%d)",
      profile,
      tostring(report.saveFolder),
      targetProfile,
      tostring(report.saveFolder),
      report.sourceVersion,
      report.targetVersion
    )
  )

  return {
    ok = true,
    targetProfile = targetProfile,
    targetSaveFolder = report.saveFolder,
    report = report,
    summary = report.layoutMigration,
    cashOut = report.cashOut,
  }
end

local function prepareLegacySaveMigration(profile, specificSaveFolder, options)
  options = type(options) == "table" and options or {}
  local report = getLegacySavePreflight(profile, specificSaveFolder)
  local refusal = refusalBeforeCopy(profile, report)
  if refusal then return refusal end

  local targetProfile, nameError = chooseMigratedProfileName(report, options)
  if not targetProfile then return failedMigration(report, nameError) end
  local saveRoot = overhaul_career_saveSystem.getSaveRootDirectory()
  if FS:directoryExists(saveRoot .. targetProfile) then
    return failedMigration(report, "A profile with that name already exists.")
  end

  local selection = selectLegacyMigrationCashOut(report, options)
  local copy, copyError = copyAndPreprocessFolders(saveRoot, profile, targetProfile, report, selection)
  if not copy then return failedMigration(report, copyError) end

  local plan = buildMigrationPlan(profile, targetProfile, report, selection, copy.vehicle, copy.garage)
  return finishMigration(profile, targetProfile, report, copy, plan)
end

-- Saved plan --------------------------------------------------------------------------------------

local function getPreparedMigration(profile, specificSaveFolder)
  local savePath = getSavePath(profile, specificSaveFolder)
  if not savePath then return nil end
  if appliedThisSession[savePath] then
    return deepcopy(appliedThisSession[savePath]), savePath
  end
  local plan = jsonReadFile(savePath .. MANIFEST_PATH)
  if type(plan) == "table" and tonumber(plan.targetVersion) == overhaul_career_saveSystem.getSaveSystemVersion() then
    return plan, savePath
  end
  return nil
end

local function isPreparedMigration(profile, specificSaveFolder)
  return getPreparedMigration(profile, specificSaveFolder) ~= nil
end

local function markMigrationApplied(profile, specificSaveFolder, appliedVehicleIds)
  local plan, savePath = getPreparedMigration(profile, specificSaveFolder)
  if not plan then return false end
  plan.status = "applied"
  plan.appliedAt = os.date("!%Y-%m-%dT%H:%M:%SZ")
  plan.appliedCashOutVehicleIds = normalizeVehicleIds(appliedVehicleIds)
  activeMigrationPlan = deepcopy(plan)
  appliedThisSession[savePath] = deepcopy(plan)
  return true
end

-- Pending prompt ----------------------------------------------------------------------------------

local function requestLegacySaveMigration(report)
  pendingMigrationReport = report
  extensions.ui_router.navigate("overhaul.profiles")
  guihooks.trigger("legacySaveMigrationRequired", report)
end

local function takePendingLegacySaveMigration()
  local report = pendingMigrationReport
  pendingMigrationReport = nil
  return report
end

-- Public API: preflight and layout ----------------------------------------------------------------

M.getLegacySavePreflight = getLegacySavePreflight
M.getSourceSavePreflight = getSourceSavePreflight
M.requiresSaveMigration = requiresSaveMigration
M.isSaveLayoutCurrent = isSaveLayoutCurrent
M.stampCurrentLayout = writePartRenameMarker
M.applyPartRenames = applyPartRenames

-- Public API: prepare and apply -------------------------------------------------------------------

M.prepareLegacySaveMigration = prepareLegacySaveMigration
M.getPreparedMigration = getPreparedMigration
M.isPreparedMigration = isPreparedMigration
M.markMigrationApplied = markMigrationApplied

-- Public API: pending prompt ----------------------------------------------------------------------

M.requestLegacySaveMigration = requestLegacySaveMigration
M.takePendingLegacySaveMigration = takePendingLegacySaveMigration

-- Game hooks --------------------------------------------------------------------------------------

local function onOverhaulSetProfile(savePath)
  partRenamesDoneForSession = false
  if type(savePath) ~= "string" or savePath == "" then return end
  if not FS:fileExists(savePath .. "/info.json") then
    partRenamesDoneForSession = writePartRenameMarker(savePath) ~= false
  else
    partRenamesDoneForSession = isSaveLayoutCurrent(savePath)
  end
end

local function onOverhaulSaveCurrentProfile(currentSavePath, _, writer)
  writer = writer or overhaul_career_saveSystem.getSaveWriter()
  -- Carry the current layout marker when autosaves rotate.
  if partRenamesDoneForSession and type(currentSavePath) == "string" then
    pcall(writePartRenameMarker, currentSavePath, writer)
  end
  if type(activeMigrationPlan) ~= "table" then return end

  local migrationDir = currentSavePath .. "/career/rls_career"
  if not writer.exists(migrationDir) then writer.mkdir(migrationDir, true) end
  overhaul_career_saveSystem.jsonWriteFileSafe(currentSavePath .. MANIFEST_PATH, activeMigrationPlan, true)
end

local function onOverhaulBeforeSetProfile()
  activeMigrationPlan = nil
  appliedThisSession = {}
end

M.onOverhaulSetProfile = onOverhaulSetProfile
M.onOverhaulSaveCurrentProfile = onOverhaulSaveCurrentProfile
M.onOverhaulBeforeSetProfile = onOverhaulBeforeSetProfile

return M
