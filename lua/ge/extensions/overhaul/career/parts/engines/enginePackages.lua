-- Engine packages: captured builds, stored recipes and transactional installation.
-- Read the named sections below in order; the final API binds the owner's game hooks.

local M = {}

M.dependencies = {"overhaul_career_parts_partInventory"}

local jbeamIO = require("jbeam/io")
local jbeamSlotSystem = require("jbeam/slotSystem")
local captureLib = require("overhaul/career/parts/engines/enginePackages/packages/capture")
local thumbnailsLib = require("overhaul/career/parts/engines/enginePackages/packages/thumbnails")
local installLib = require("overhaul/career/parts/engines/enginePackages/packages/install")
local recipesLib = require("overhaul/career/parts/engines/enginePackages/packages/recipes")

-- Config -------------------------------------------------------------------------------------------

local constants = {logTag = "enginePackages"}
constants.saveVersion = 2
constants.saveRelativePath = "/career/rls_career/enginePackages.json"
constants.thumbnailRelativeDir = "/career/rls_career/enginePackages/"
constants.thumbnailCaptureVersion = 6
constants.CONDITION_REQUEST_TIMEOUT_S = 15

-- State ------------------------------------------------------------------------------------------

-- The package records and their transaction state. Owned here; the libraries read and write these fields through inputs.packageStore, so a reload or a rollback (packageStore.packages = snapshot) is seen everywhere.
local packageStore = {
  packages = {},
  nextPackageId = 1,
  currentInventoryId = nil,
  transactionBusy = false,
  activeInstallCallback = nil,
}
local menuOpen = false
local originComputerId
local originBusinessContext
local activeTransactionId = 0
local lifetimeGeneration = 0
local loaded = false
local packageReferenceGuards = {}
local authoredPartValueCache = {}

-- The four library instances, created in the parts section below. Functions above it reach them at call time.
local libraries = {}

-- Transactions ---------------------------------------------------------------------------------------

local function beginTransaction()
  activeTransactionId = activeTransactionId + 1
  packageStore.transactionBusy = true
  return activeTransactionId
end

local function isActiveTransaction(transactionId)
  return transactionId ~= nil and transactionId == activeTransactionId
end

local function endTransaction(transactionId)
  if not isActiveTransaction(transactionId) then return false end
  packageStore.transactionBusy = false
  return true
end

-- Helpers ----------------------------------------------------------------------------------------------

local function countTableEntries(value)
  local count = 0
  for _ in pairs(value or {}) do
    count = count + 1
  end
  return count
end

local function trim(value)
  if type(value) ~= "string" then return "" end
  return value:match("^%s*(.-)%s*$") or ""
end

-- Part valuation uses the real calendar year as its age reference. Factory engines therefore need a production year of their own; using the donor vehicle's model year makes a newly-built engine look decades old.
local function getCurrentManufacturingYear()
  local date = os.date("*t") or {}
  return math.max(1, math.floor(tonumber(date.year) or tonumber(os.date("%Y")) or 2026))
end

-- Inventory lookups stay guarded: the thumbnail and condition-timeout jobs reach them through getPackageStatus and can fire after the career modules are unloaded.
local function getPartInventory()
  return overhaul_career_parts_partInventory and overhaul_career_parts_partInventory.getInventory and
    overhaul_career_parts_partInventory.getInventory() or {}
end

local function isBusinessPackage(package)
  return package and package.ownerType == "business"
end

local function getInventoryForPackage(package)
  if isBusinessPackage(package) then
    return overhaul_career_business_partInventory
      and overhaul_career_business_partInventory.getInventory
      and overhaul_career_business_partInventory.getInventory() or {}
  end
  return getPartInventory()
end

local function getPartIdsFromPackageTree(node, result)
  result = result or {}
  if not node then return result end
  if node.partId then
    table.insert(result, tonumber(node.partId) or node.partId)
  end
  for _, child in pairs(node.children or {}) do
    getPartIdsFromPackageTree(child, result)
  end
  return result
end

-- Stamps the manufactured year and factory provenance onto one physical part. Returns true when anything changed.
local function markPartAsManufactured(part, manufacturedYear, factoryPackageId)
  if not part then return false end
  manufacturedYear = math.max(1, math.floor(tonumber(part.manufacturedYear) or tonumber(manufacturedYear)
    or getCurrentManufacturingYear()))
  local changed = part.year ~= manufacturedYear or part.manufacturedYear ~= manufacturedYear
    or part.engineShopManufactured ~= true or tostring(part.factoryPackageId or "") ~= tostring(factoryPackageId or "")
  part.year = manufacturedYear
  part.manufacturedYear = manufacturedYear
  part.engineShopManufactured = true
  part.factoryPackageId = tostring(factoryPackageId or part.factoryPackageId or "")
  part.tags = type(part.tags) == "table" and part.tags or {}
  part.tags.engineShopManufactured = true
  part.tags.manufacturedYear = manufacturedYear
  part.tags.factoryPackageId = part.factoryPackageId
  return changed
end

-- Stamps the manufactured year onto a package and every physical part it owns. Returns true when anything changed.
local function markPackageAsManufactured(package, manufacturedYear)
  if not package then return false end
  manufacturedYear = math.max(1, math.floor(tonumber(package.manufacturedYear) or tonumber(manufacturedYear)
    or getCurrentManufacturingYear()))
  local changed = package.manufacturedYear ~= manufacturedYear or package.engineShopManufactured ~= true
  package.manufacturedYear = manufacturedYear
  package.engineShopManufactured = true
  local inventory = getInventoryForPackage(package)
  for _, partId in ipairs(getPartIdsFromPackageTree(package.tree)) do
    changed = markPartAsManufactured(inventory[tonumber(partId) or partId], manufacturedYear, package.id) or changed
  end
  return changed
end

-- Save paths and thumbnails -------------------------------------------------------------------------

local function getCurrentSavePath()
  local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
  return savePath
end

local function normalizeSavePath(savePath)
  savePath = savePath or getCurrentSavePath()
  if not savePath then return nil end
  if savePath:sub(1, 1) ~= "/" then
    savePath = "/" .. savePath
  end
  return savePath
end

local function ensureSaveDirectory(filePath, writer)
  local dirPath = filePath and filePath:match("^(.*)/[^/]+$")
  writer = writer or overhaul_career_saveSystem.getSaveWriter()
  if dirPath and not writer.exists(dirPath) then
    writer.mkdir(dirPath, true)
  end
end

local function getPackageThumbnailDiskPath(packageId, savePath)
  savePath = savePath or getCurrentSavePath()
  if not savePath or not packageId then return nil end
  return savePath .. constants.thumbnailRelativeDir .. tostring(packageId) .. ".jpg"
end

local function getPackageThumbnailUiPath(packageId, savePath)
  local filePath = getPackageThumbnailDiskPath(packageId, savePath)
  return filePath and normalizeSavePath(filePath) or nil
end

local function packageThumbnailExists(packageId)
  local diskPath = getPackageThumbnailDiskPath(packageId)
  local uiPath = getPackageThumbnailUiPath(packageId)
  return (diskPath and FS:fileExists(diskPath)) or (uiPath and FS:fileExists(uiPath)) or false
end

local function getPackageById(packageId)
  packageId = tostring(packageId or "")
  for _, package in ipairs(packageStore.packages) do
    if tostring(package.id) == packageId then
      return package
    end
  end
end

local function getPackageThumbnailPath(packageId, savePath)
  local package = getPackageById(packageId)
  -- Stored engines cannot be recaptured until installed; never keep showing an old ghost image.
  if not package or tonumber(package.thumbnailCaptureVersion) ~= constants.thumbnailCaptureVersion
    or not packageThumbnailExists(packageId) then return nil end
  return getPackageThumbnailUiPath(packageId, savePath)
end

local function saveData(currentSavePath, writer)
  if not currentSavePath then return false end

  local filePath = currentSavePath .. constants.saveRelativePath
  ensureSaveDirectory(filePath, writer)
  return overhaul_career_saveSystem.jsonWriteFileSafe(filePath, {
    version = constants.saveVersion,
    nextPackageId = packageStore.nextPackageId,
    packages = packageStore.packages
  }, true) and true or false
end

-- Package records ----------------------------------------------------------------------------------

-- Status is "installed", "stored" or "incomplete", from the library's inventory check.
local function getPackageStatus(package)
  return libraries.capture.getPackageStatus(package)
end

local function restoreTable(target, snapshot)
  table.clear(target)
  for key, value in pairs(snapshot or {}) do
    target[key] = deepcopy(value)
  end
end


local function clearPackageFlags(package)
  local inventory = getInventoryForPackage(package)
  for _, partId in ipairs(getPartIdsFromPackageTree(package and package.tree)) do
    local part = inventory[partId]
    if part and tostring(part.enginePackageId or "") == tostring(package.id) then
      part.enginePackageId = nil
      part.mainPart = part.containingSlot == "/"
    end
  end
end

local function removePackage(packageId, clearFlags)
  packageId = tostring(packageId or "")
  for index, package in ipairs(packageStore.packages) do
    if tostring(package.id) == packageId then
      if clearFlags then clearPackageFlags(package) end
      table.remove(packageStore.packages, index)
      return package
    end
  end
end

-- Parts that name a package that no longer exists are released; each live package's parts and status are re-marked from the inventory.
local function releaseOrphanedPartFlags(validPackageIds)
  for _, part in pairs(getPartInventory()) do
    local packageId = part.enginePackageId and tostring(part.enginePackageId)
    if packageId and not validPackageIds[packageId] then
      -- Keep the former package ID just long enough for the Engine Works state to identify and repair factory parts from saves made before production provenance was persisted.
      part.orphanedEnginePackageId = packageId
      part.enginePackageId = nil
      part.mainPart = part.containingSlot == "/"
    end
  end
end

local function repairPackageFlags()
  local validPackageIds = {}
  for _, package in ipairs(packageStore.packages) do
    validPackageIds[tostring(package.id)] = true
  end
  releaseOrphanedPartFlags(validPackageIds)

  for _, package in ipairs(packageStore.packages) do
    local packageInventory = getInventoryForPackage(package)
    for _, partId in ipairs(getPartIdsFromPackageTree(package.tree)) do
      local part = packageInventory[partId]
      if part then
        part.enginePackageId = tostring(package.id)
        part.mainPart = true
        if package.engineShopManufactured == true then
          markPartAsManufactured(part, package.manufacturedYear, package.id)
        end
      end
    end
    local status, installedInventoryId = getPackageStatus(package)
    if status == "installed" then package.installedInventoryId = installedInventoryId end
    if status == "stored" then package.installedInventoryId = nil end
  end
end

-- Loads the saved packages, assigns ids and repairs the part flags.
local function loadData()
  packageStore.packages = {}
  packageStore.nextPackageId = 1

  local savePath = getCurrentSavePath()
  local filePath = savePath and (savePath .. constants.saveRelativePath)
  local data = filePath and FS:fileExists(filePath) and jsonReadFile(filePath) or nil
  if type(data) == "table" and type(data.packages) == "table" then
    packageStore.packages = data.packages
    packageStore.nextPackageId = math.max(tonumber(data.nextPackageId) or 1, 1)
  end

  for _, package in ipairs(packageStore.packages) do
    package.id = tostring(package.id)
    package.ownerType = package.ownerType or "personal"
    local numericId = tonumber(package.id)
    if numericId then
      packageStore.nextPackageId = math.max(packageStore.nextPackageId, numericId + 1)
    end
  end

  repairPackageFlags()
  loaded = true
end

-- Values ------------------------------------------------------------------------------------------------

local function getPackageSaleValue(package)
  local inventory = getInventoryForPackage(package)
  local total = 0
  for _, partId in ipairs(getPartIdsFromPackageTree(package and package.tree)) do
    local part = inventory[tonumber(partId) or partId]
    if not part then return nil end
    if part.value == nil then
      part.value = libraries.capture.getAuthoredPartValue(part.vehicleModel or package.createdModel or package.lastInstalledModel, part.name)
    end
    total = total + math.max(0, tonumber(overhaul_career_market_valueCalculator.getPartResaleValue(part)) or 0)
  end
  return math.max(0, math.floor(total + 0.5))
end

-- Sum of the package's part values and the highest odometer on its parts.
local function getConditionSummary(package)
  local inventory = getInventoryForPackage(package)
  local integrityTotal, integrityCount, maxOdometer = 0, 0, 0
  for _, partId in ipairs(getPartIdsFromPackageTree(package.tree)) do
    local condition = inventory[partId] and inventory[partId].partCondition
    if type(condition) == "table" then
      local integrity = tonumber(condition.integrityValue)
      if integrity then
        integrityTotal = integrityTotal + integrity
        integrityCount = integrityCount + 1
      end
      maxOdometer = math.max(maxOdometer, tonumber(condition.odometer) or 0)
    end
  end
  return integrityCount > 0 and (integrityTotal / integrityCount) or 1, maxOdometer
end

local function getVehicleName(inventoryId)
  local vehicle = overhaul_career_garage_inventory.getVehicles()[tonumber(inventoryId)]
  if not vehicle then return nil end
  local name = vehicle.niceName or vehicle.model
  return core_locales.translateWithOrWithoutContext(name)
end

-- UI data and messages -------------------------------------------------------------------------------

-- Whether the package fits the selected vehicle, and why not when it does not.
local function compatibilityFor(package, status)
  local compatible, compatibilityReason = false, nil
  if packageStore.currentInventoryId and status ~= "incomplete" then
    local target, err = libraries.capture.findCompatibleTarget(package, packageStore.currentInventoryId)
    compatible = target ~= nil
    compatibilityReason = err
  end
  return compatible, compatibilityReason
end

local function packageListRow(package, currentVehicleName)
  local status, installedInventoryId, missingCount = getPackageStatus(package)
  package.installedInventoryId = installedInventoryId
  local compatible, compatibilityReason = compatibilityFor(package, status)
  if not compatible and compatibilityReason == "This engine package does not fit the selected vehicle."
      and currentVehicleName then
    compatibilityReason = "Does not fit " .. tostring(currentVehicleName) .. "."
  end
  local integrity, odometer = getConditionSummary(package)
  local saleValue = status == "stored" and getPackageSaleValue(package) or nil
  local thumbnailPath = getPackageThumbnailPath(package.id)
  local busy = packageStore.transactionBusy
  return {
    id = tostring(package.id),
    name = package.name,
    rootEngineName = package.rootEngineName,
    rootEngineNiceName = package.rootEngineNiceName or package.rootEngineName,
    partCount = #getPartIdsFromPackageTree(package.tree),
    tuningCount = countTableEntries(package.tuning),
    integrity = integrity,
    odometer = odometer,
    status = status,
    missingCount = missingCount,
    installedInventoryId = installedInventoryId,
    installedVehicleName = installedInventoryId and getVehicleName(installedInventoryId) or nil,
    createdModel = package.createdModel,
    lastInstalledModel = package.lastInstalledModel,
    compatible = compatible,
    compatibilityReason = compatibilityReason,
    canInstall = not busy and status == "stored" and compatible,
    canStore = not busy and status == "installed" and tonumber(installedInventoryId) == tonumber(packageStore.currentInventoryId),
    canDismantle = not busy,
    canSell = not busy and status == "stored" and saleValue ~= nil,
    saleValue = saleValue,
    thumbnail = thumbnailPath,
    dirtyDate = package.thumbnailAt or package.updatedAt or 0,
    certification = deepcopy(package.engineShopCertification)
  }
end

-- The vehicle's engine is present and combustion (electric vehicles have no swappable engine).
local function vehicleHasInstalledEngine(inventoryId)
  local runtimeData = libraries.capture.getRuntimeVehicleData(inventoryId)
  return runtimeData and runtimeData.config and not libraries.capture.vehicleIsElectric(inventoryId)
    and libraries.capture.getPrimaryEngine(runtimeData.config.partsTree, runtimeData.ioCtx) ~= nil or false
end

local function buildUIData()
  local result = {
    busy = packageStore.transactionBusy,
    currentInventoryId = packageStore.currentInventoryId,
    currentVehicleName = packageStore.currentInventoryId and getVehicleName(packageStore.currentInventoryId) or nil,
    browseOnly = packageStore.currentInventoryId == nil,
    currentPackageId = nil,
    hasInstalledEngine = false,
    packages = {}
  }
  if packageStore.currentInventoryId then
    result.hasInstalledEngine = vehicleHasInstalledEngine(packageStore.currentInventoryId)
  end
  local currentPackage = packageStore.currentInventoryId and libraries.capture.findPackageForInventory(packageStore.currentInventoryId)
  result.currentPackageId = currentPackage and tostring(currentPackage.id) or nil

  for _, package in ipairs(packageStore.packages) do
    if not isBusinessPackage(package) then
      table.insert(result.packages, packageListRow(package, result.currentVehicleName))
    end
  end

  table.sort(result.packages, function(a, b)
    if a.status ~= b.status then return a.status == "installed" end
    return string.lower(a.name or "") < string.lower(b.name or "")
  end)
  return result
end

-- Parts list for the package detail view: every part in the package tree (parent before children, slots in name order) with its condition and value. Missing parts are kept, flagged missing.
local function getPackageDetails(packageId)
  local package = getPackageById(packageId)
  if not package or isBusinessPackage(package) then return nil end
  local inventory = getInventoryForPackage(package)
  local fallbackModel = package.createdModel or package.lastInstalledModel
  local parts = {}

  local function walk(node, slotPath, slotName, depth)
    if not node then return end
    local partId = tonumber(node.partId) or node.partId
    local part = partId ~= nil and inventory[partId] or nil
    local condition = part and part.partCondition
    local value = nil
    if part then
      if part.value == nil then
        part.value = libraries.capture.getAuthoredPartValue(part.vehicleModel or fallbackModel, part.name)
      end
      value = math.max(0, math.floor((tonumber(overhaul_career_market_valueCalculator.getPartValue(part)) or 0) + 0.5))
    end
    table.insert(parts, {
      partId = partId,
      name = node.name,
      niceName = part and libraries.capture.getDescriptionText(part.description, node.name) or node.name,
      slot = slotName,
      slotPath = slotPath,
      depth = depth,
      integrity = condition and tonumber(condition.integrityValue) or nil,
      odometer = condition and tonumber(condition.odometer) or nil,
      value = value,
      missing = part == nil
    })
    local slotNames = {}
    for childSlot in pairs(node.children or {}) do table.insert(slotNames, childSlot) end
    table.sort(slotNames)
    for _, childSlot in ipairs(slotNames) do
      walk(node.children[childSlot], slotPath .. childSlot .. "/", childSlot, depth + 1)
    end
  end

  walk(package.tree, "/", package.tree and package.tree.relativeSlot or nil, 0)
  return {
    id = tostring(package.id),
    name = package.name,
    parts = parts,
    tuningCount = countTableEntries(package.tuning),
    certification = deepcopy(package.engineShopCertification)
  }
end

local function sendUIData()
  if not menuOpen then return end
  guihooks.trigger("enginePackagesData", buildUIData())
end

local function sendResult(success, message)
  guihooks.trigger("enginePackagesActionResult", {success = success == true, message = message or ""})
  sendUIData()
  if packageStore.activeInstallCallback then
    local callback = packageStore.activeInstallCallback
    packageStore.activeInstallCallback = nil
    local ok, err = pcall(callback, success == true, message or "")
    if not ok then log("E", constants.logTag, "Engine installation callback failed: " .. tostring(err)) end
  end
end

-- Expands live part paths from the engine's part names. Used by thumbnails for the engine-only highlight.
local function collectLivePartPaths(node, result)
  result = result or {}
  if not node then return result end
  local partPath = node.partPath
  if (not partPath or partPath == "") and node.path and (node.chosenPartName or node.name) then
    partPath = node.path .. tostring(node.chosenPartName or node.name)
  end
  if partPath and partPath ~= "" then
    result[partPath] = true
  end
  for _, child in pairs(node.children or {}) do
    collectLivePartPaths(child, result)
  end
  return result
end

local function collectLivePartNames(node, result)
  result = result or {}
  if not node then return result end
  local name = node.chosenPartName or node.name
  if name and name ~= "" then result[name] = true end
  for _, child in pairs(node.children or {}) do
    collectLivePartNames(child, result)
  end
  return result
end

-- Adds the part paths of the named parts from the vehicle data (flexbodies, props and nodes).
local function expandPartPathsFromVdata(vdata, partNames, partPaths)
  partPaths = partPaths or {}
  if not vdata or not partNames then return partPaths end

  local function consider(path)
    if type(path) ~= "string" or path == "" or partPaths[path] then return end
    local name = path:match("([^/]+)$")
    if name and partNames[name] then
      partPaths[path] = true
    end
  end

  for _, section in ipairs({"flexbodies", "props", "nodes"}) do
    for _, entry in pairs(vdata[section] or {}) do
      if type(entry) == "table" then consider(entry.partPath) end
    end
  end
  return partPaths
end

-- Vehicle guards ---------------------------------------------------------------------------------------

-- Vehicle callbacks have no timeout and may never fire after deletion.
local function guardConditionRequest(transactionId)
  local wait = {answered = false}
  core_jobsystem.create(function(job)
    job.sleep(constants.CONDITION_REQUEST_TIMEOUT_S)
    if not wait.answered and isActiveTransaction(transactionId) then
      activeTransactionId = activeTransactionId + 1
      packageStore.transactionBusy = false
      log("W", constants.logTag, "Part condition request timed out; transaction abandoned")
      sendResult(false, "The vehicle did not respond. Try again.")
      sendUIData()
    end
  end)
  return wait
end

-- The first reason the selected vehicle cannot take part in an engine swap, or true when it can.
local function validateSelectedVehicle()
  local vehicle = packageStore.currentInventoryId and overhaul_career_garage_inventory.getVehicles()[packageStore.currentInventoryId]
  if not vehicle then return false, "No vehicle is selected." end
  if vehicle.owned ~= true then return false, "The selected vehicle is not owned." end
  if vehicle.timeToAccess then return false, "The selected vehicle is not accessible." end
  if not overhaul_career_garage_inventory.getVehicleIdFromInventoryId(packageStore.currentInventoryId) then
    return false, "The selected vehicle is not spawned."
  end
  if overhaul_career_repair_insurance.inventoryVehNeedsRepair(packageStore.currentInventoryId) then
    return false, "Repair this vehicle before managing engine packages."
  end
  local permission = overhaul_career_permissions.getStatusForTag({"partSwapping", "vehicleModification"}, {inventoryId = packageStore.currentInventoryId})
  if not permission.allow then return false, permission.label or "Vehicle modification is not allowed." end
  if libraries.capture.vehicleIsElectric(packageStore.currentInventoryId) then
    return false, "Electric vehicles cannot swap engines."
  end
  return true
end

-- Parts ---------------------------------------------------------------------------------------

local packageInputs = {
  parts = libraries,
  authoredPartValueCache = authoredPartValueCache,
  getInventoryForPackage = getInventoryForPackage,
  getPartIdsFromPackageTree = getPartIdsFromPackageTree,
  getPartInventory = getPartInventory,
  jbeamIO = jbeamIO,
  jbeamSlotSystem = jbeamSlotSystem,
  packageStore = packageStore,
  trim = trim,
  collectLivePartNames = collectLivePartNames,
  collectLivePartPaths = collectLivePartPaths,
  constants = constants,
  countTableEntries = countTableEntries,
  ensureSaveDirectory = ensureSaveDirectory,
  expandPartPathsFromVdata = expandPartPathsFromVdata,
  getPackageById = getPackageById,
  getPackageStatus = getPackageStatus,
  getPackageThumbnailDiskPath = getPackageThumbnailDiskPath,
  isSaveBusy = function() return overhaul_career_saveSystem and overhaul_career_saveSystem.isSaveBusy() end,
  getPackageThumbnailUiPath = getPackageThumbnailUiPath,
  packageThumbnailExists = packageThumbnailExists,
  sendUIData = sendUIData,
  beginTransaction = beginTransaction,
  endTransaction = endTransaction,
  guardConditionRequest = guardConditionRequest,
  isActiveTransaction = isActiveTransaction,
  repairPackageFlags = repairPackageFlags,
  getLifetimeGeneration = function() return lifetimeGeneration end,
  restoreTable = restoreTable,
  sendResult = sendResult,
  validateSelectedVehicle = validateSelectedVehicle,
  clearPackageFlags = clearPackageFlags,
  getCurrentManufacturingYear = getCurrentManufacturingYear,
  isBusinessPackage = isBusinessPackage,
  markPackageAsManufactured = markPackageAsManufactured,
  markPartAsManufactured = markPartAsManufactured,
  packageReferenceGuards = packageReferenceGuards,
  removePackage = removePackage,
}

libraries.capture = captureLib.create(packageInputs)
libraries.thumbnails = thumbnailsLib.create(packageInputs)
libraries.install = installLib.create(packageInputs)
libraries.recipes = recipesLib.create(packageInputs)


-- Vehicle actions: create, rename, dismantle, sell ---------------------------------------------------------

local function createFromCurrent(name)
  if packageStore.transactionBusy then return end
  local valid, err = validateSelectedVehicle()
  if not valid then sendResult(false, err) return end
  local inventoryId = packageStore.currentInventoryId
  if libraries.capture.findPackageForInventory(inventoryId) then
    sendResult(false, "This engine is already grouped as a package.")
    return
  end
  local transactionId = beginTransaction()
  sendUIData()
  local conditionWait = guardConditionRequest(transactionId)
  overhaul_career_garage_inventory.updatePartConditions(nil, inventoryId, function()
    conditionWait.answered = true
    if not isActiveTransaction(transactionId) then return end
    local package, captureError = libraries.capture.captureCurrentEngineActual(inventoryId, name)
    if not package then
      endTransaction(transactionId)
      sendResult(false, captureError)
      return
    end
    overhaul_career_garage_inventory.setVehicleDirty(inventoryId)
    libraries.thumbnails.enqueueEngineThumbnail(package, inventoryId)
    libraries.thumbnails.whenThumbnailsIdleOrTimeout(function()
      if not isActiveTransaction(transactionId) then return end
      if overhaul_career_career.isAutosaveEnabled() then overhaul_career_saveSystem.saveCurrent() end
      endTransaction(transactionId)
      sendResult(true, "Created engine package " .. tostring(package.name) .. ".")
    end, 8)
  end)
end

local function renamePackage(packageId, name)
  if packageStore.transactionBusy then return end
  local package = getPackageById(packageId)
  if not package then sendResult(false, "Engine package not found.") return end
  name = trim(name)
  if name == "" then sendResult(false, "Enter a package name.") return end
  package.name = libraries.capture.uniquePackageName(name, package.id)
  package.updatedAt = os.time()
  if overhaul_career_career.isAutosaveEnabled() then overhaul_career_saveSystem.saveCurrent() end
  sendResult(true, "Renamed engine package.")
end

-- The first guard that refuses this package, with its reason, or nil when none does.
local function referenceRefusal(package)
  for _, guard in ipairs(packageReferenceGuards) do
    local ok, reason = guard(package)
    if ok == false then
      return reason or "This engine package is protected by an active reference."
    end
  end
end

local function dismantlePackage(packageId)
  if packageStore.transactionBusy then return end
  local package = getPackageById(packageId)
  if not package then sendResult(false, "Engine package not found.") return end
  local refusal = referenceRefusal(package)
  if refusal then sendResult(false, refusal) return end
  local _, installedInventoryId = getPackageStatus(package)
  removePackage(package.id, true)
  if installedInventoryId then overhaul_career_garage_inventory.setVehicleDirty(installedInventoryId) end
  if overhaul_career_career.isAutosaveEnabled() then
    overhaul_career_saveSystem.saveCurrent()
  end
  sendResult(true, "Dismantled engine package. Its parts are available in My Parts again.")
end

-- Every part of the package must be stored before it can be sold; returns the reason when one is not.
local function storedPartsProblem(partIds, inventory)
  for _, partId in ipairs(partIds) do
    local part = inventory[tonumber(partId) or partId]
    if not part or (tonumber(part.location) ~= 0 and tostring(part.location) ~= "stored") then
      return "Every engine package part must be stored before sale."
    end
  end
end

local function sellPackage(packageId)
  if packageStore.transactionBusy then return end
  local package = getPackageById(packageId)
  if not package or isBusinessPackage(package) then sendResult(false, "Personal engine package not found.") return end
  if getPackageStatus(package) ~= "stored" then
    sendResult(false, "Only a stored engine package can be sold.")
    return
  end
  local refusal = referenceRefusal(package)
  if refusal then sendResult(false, refusal) return end
  local inventory = getPartInventory()
  local partIds = getPartIdsFromPackageTree(package.tree)
  local saleValue = getPackageSaleValue(package)
  if saleValue == nil then sendResult(false, "The engine package is missing one or more parts.") return end
  local problem = storedPartsProblem(partIds, inventory)
  if problem then sendResult(false, problem) return end
  removePackage(package.id, false)
  for _, partId in ipairs(partIds) do inventory[tonumber(partId) or partId] = nil end
  overhaul_career_economy_playerAttributes.addAttributes({money = saleValue}, require("overhaul/lib/finance/metadata").tag({
    tags = {"partsSold", "enginePackageSold", "selling"},
    label = "Sold " .. tostring(package.name)
  }, "sale", {vehicleRelated = false}), true)
  Engine.Audio.playOnce("AudioGui", "event:>UI>Career>Buy_01")
  overhaul_career_parts_partInventory.onOverhaulPartShoppingTransactionComplete()
  if overhaul_career_career.isAutosaveEnabled() then overhaul_career_saveSystem.saveCurrent() end
  sendResult(true, string.format("Sold %s for $%d.", tostring(package.name), saleValue))
end

-- Vehicle changes ----------------------------------------------------------------------------------------

-- Read the live hardware without capturing a package or changing part ownership.
local function getInstalledEngineRecipe(inventoryId)
  inventoryId = tonumber(inventoryId)
  if not inventoryId then return nil, "The raced vehicle is unavailable." end
  local vehicle = overhaul_career_garage_inventory.getVehicles()[inventoryId]
  local runtimeData = libraries.capture.getRuntimeVehicleData(inventoryId)
  local anchor = runtimeData and runtimeData.config and libraries.capture.resolveEngineCaptureAnchor(runtimeData.config.partsTree, runtimeData.ioCtx)
  if not vehicle or not anchor then return nil, "The raced engine hardware could not be identified." end
  local tree, reason = libraries.capture.makePackageTree(anchor.node, inventoryId)
  if not tree then return nil, reason end
  return libraries.recipes.getRecipeFromPackage({createdModel = vehicle.model, rootSlotName = anchor.slotName,
    rootPath = anchor.path, tree = tree})
end

-- Re-reads an installed package's tuning and certification after the vehicle changed, or drops the link when the engine no longer matches the package.
local function refreshInstalledPackage(inventoryId, refreshTree)
  local package = libraries.capture.findPackageForInventory(inventoryId)
  if not package then return false end
  local runtimeData = libraries.capture.getRuntimeVehicleData(inventoryId)
  local vehicle = overhaul_career_garage_inventory.getVehicles()[inventoryId]
  if not runtimeData or not vehicle then return false end
  if refreshTree then
    local anchor = runtimeData.config and libraries.capture.resolveEngineCaptureAnchor(runtimeData.config.partsTree, runtimeData.ioCtx)
    local currentTree = anchor and libraries.capture.makePackageTree(anchor.node, inventoryId)
    if not currentTree or not libraries.capture.installedPackageTreeMatches(package.tree, currentTree) then
      package.installedInventoryId = nil
      package.updatedAt = os.time()
      local inventory = getPartInventory()
      for _, partId in ipairs(getPartIdsFromPackageTree(package.tree)) do
        local part = inventory[partId]
        if part and tonumber(part.location) == tonumber(inventoryId) then
          part.enginePackageId = nil
          part.mainPart = part.containingSlot == "/"
        end
      end
      return true
    end
    local refreshed = libraries.capture.captureCurrentEngineActual(inventoryId, package.name, package, anchor)
    return refreshed ~= nil
  end
  package.tuning = libraries.capture.captureTuning(package.tree, runtimeData, vehicle.config)
  package.updatedAt = os.time()
  libraries.recipes.refreshCertificationValidity(package)
  return true
end

local function onOverhaulPartShoppingTransactionComplete()
  if packageStore.transactionBusy then return end
  for _, package in ipairs(packageStore.packages) do
    local inventoryId = tonumber(package.installedInventoryId)
    if inventoryId and overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId) then
      refreshInstalledPackage(inventoryId, true)
    end
  end
  sendUIData()
end

local function onOverhaulTuningApplied()
  if packageStore.transactionBusy then return end
  local inventoryId = overhaul_career_garage_inventory.getCurrentVehicle()
  if inventoryId then refreshInstalledPackage(inventoryId, false) end
  sendUIData()
end

local function onOverhaulVehicleRemoved(inventoryId)
  inventoryId = tonumber(inventoryId)
  -- Temporary job ids must never match stored packages with no installed vehicle.
  if not inventoryId then return end
  for index = #packageStore.packages, 1, -1 do
    if tonumber(packageStore.packages[index].installedInventoryId) == inventoryId then
      table.remove(packageStore.packages, index)
    end
  end
  sendUIData()
end

-- Menu ----------------------------------------------------------------------------------------------------

local function requestData()
  sendUIData()
  libraries.thumbnails.maybeCaptureMissingThumbnails()
  return buildUIData()
end

local function openMenu(inventoryId, computerId, businessContext)
  packageStore.currentInventoryId = tonumber(inventoryId)
  originComputerId = tonumber(computerId) or computerId
  originBusinessContext = type(businessContext) == "table" and deepcopy(businessContext) or nil
  if not packageStore.currentInventoryId and not originBusinessContext and not originComputerId then return false end
  menuOpen = true
  extensions.ui_router.navigate("overhaul.computer.enginePackages")
  libraries.thumbnails.maybeCaptureMissingThumbnails()
  core_jobsystem.create(function(job)
    job.sleep(0.8)
    if menuOpen then libraries.thumbnails.maybeCaptureMissingThumbnails() end
  end, 1)
  return true
end

-- Returns to the business or computer screen that opened the menu, or to the career menus.
local function closeMenu()
  menuOpen = false
  if originBusinessContext then
    local context = originBusinessContext
    packageStore.currentInventoryId = nil
    originComputerId = nil
    originBusinessContext = nil
    local owner = overhaul_career_business_manager.hasFeature(context.businessType, "engineProduction")
      and overhaul_career_business_manager.getBusinessModule(context.businessType)
    if owner and owner.openMenu then
      owner.openMenu(context.businessId)
      return
    end
  end
  if originComputerId then
    local computer = overhaul_world_facilities.getFacility("computer", originComputerId)
    if computer then
      overhaul_career_garage_computer.openMenu(computer)
      packageStore.currentInventoryId = nil
      originComputerId = nil
      return
    end
  end
  packageStore.currentInventoryId = nil
  originComputerId = nil
  overhaul_career_career.closeAllMenus()
end

-- Computer functions --------------------------------------------------------------------------------------

-- The engine package library on the computer, and a per-vehicle workshop action for each owned garage vehicle.
local function onOverhaulComputerAddFunctions(menuData, computerFunctions)
  local computerId = menuData.computerFacility and menuData.computerFacility.id
  computerFunctions.general.enginePackages = {
    id = "enginePackages",
    label = "My Engine Packages",
    routeTarget = "overhaul.computer.enginePackages",
    callback = function(callbackComputerId) openMenu(nil, callbackComputerId or computerId) end,
    order = 6
  }

  -- The general entry is the package library and deliberately opens without a selected vehicle. Keep a separate garage action so capture, removal, and installation operate on the vehicle represented by that card.
  local garageId = computerId and overhaul_career_garage_garageManager.computerIdToGarageId(computerId)
  if not garageId or not overhaul_career_garage_garageManager.isPurchasedGarage(garageId) then return end

  for _, vehicleData in ipairs(menuData.vehiclesInGarage or {}) do
    local inventoryId = vehicleData.inventoryId
    local vehicle = overhaul_career_garage_inventory.getVehicles()[inventoryId]
    local data = {
      id = "enginePackageWorkshop",
      label = "Engine Package Workshop",
      routeTarget = "overhaul.computer.enginePackages",
      callback = function(callbackComputerId)
        openMenu(inventoryId, callbackComputerId or computerId)
      end,
      order = 6
    }
    if not vehicle or vehicle.owned ~= true or vehicle.timeToAccess
        or not overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId) then
      data.disabled = true
      data.reason = {type = "text", label = "The vehicle must be owned, accessible, and spawned."}
    elseif libraries.capture.vehicleIsElectric(inventoryId) then
      data.disabled = true
      data.reason = {type = "text", label = "Electric vehicles cannot use combustion engine packages."}
    elseif vehicleData.needsRepair then
      data.disabled = true
      data.reason = overhaul_career_garage_computer.reasons.needsRepair
    else
      local permission = overhaul_career_permissions.getStatusForTag(
        {"partSwapping", "vehicleModification"}, {inventoryId = inventoryId})
      if not permission.allow then data.disabled = true end
      if permission.permission ~= "allowed" then data.reason = permission end
    end
    computerFunctions.vehicleSpecific[inventoryId][data.id] = data
  end
end

-- Save migration and profile hooks --------------------------------------------------------------------------

-- Copies the thumbnails of the saved packages to a new save folder when the profile moves.
local function copyPackageThumbnails(newSavePath, writer)
  local oldSavePath = getCurrentSavePath()
  if not oldSavePath or not newSavePath then return end
  if normalizeSavePath(oldSavePath) == normalizeSavePath(newSavePath) then return end
  for _, package in ipairs(packageStore.packages) do
    local id = package and package.id
    if id then
      local src = getPackageThumbnailDiskPath(id, oldSavePath)
      if src and not FS:fileExists(src) then src = getPackageThumbnailUiPath(id, oldSavePath) end
      if src and FS:fileExists(src) then
        local dst = getPackageThumbnailDiskPath(id, newSavePath)
        ensureSaveDirectory(dst, writer)
        writer.copy(src, dst)
      end
    end
  end
end

-- Deletes thumbnail files whose package no longer exists.
local function prunePackageThumbnails(savePath, writer)
  local dirPath = savePath and (savePath .. constants.thumbnailRelativeDir)
  if not dirPath or not writer.exists(dirPath) then return end
  local live = {}
  for _, package in ipairs(packageStore.packages) do
    if package and package.id then live[tostring(package.id)] = true end
  end
  for _, filePath in ipairs(writer.findFiles(dirPath, "*.jpg", 0, false, false) or {}) do
    local id = filePath:match("([^/]+)%.jpg$")
    if id and not live[id] then writer.remove(filePath) end
  end
end

local function onOverhaulSaveCurrentProfile(currentSavePath, _, writer)
  writer = writer or overhaul_career_saveSystem.getSaveWriter()
  if not loaded then loadData() end
  saveData(currentSavePath, writer)
  copyPackageThumbnails(currentSavePath, writer)
  prunePackageThumbnails(currentSavePath, writer)
end

local function initialize()
  libraries.thumbnails.resumeCaptures()
  if loaded then return end
  loadData()
end

-- Public ownership-aware package API. Personal garage actions above continue to use the same physical records; business modules use these adapters so their packages share persistence without appearing in the personal garage screen.
local function listPackages(ownerContext)
  local result = {}
  local ownerType = ownerContext and (ownerContext.ownerType or ownerContext.type)
  for _, package in ipairs(packageStore.packages) do
    local matches = not ownerContext or (package.ownerType or "personal") == (ownerType or "personal")
    if matches and ownerType == "business" then
      matches = tostring(package.businessType or "") == tostring(ownerContext.businessType or "")
        and tostring(package.businessId or "") == tostring(ownerContext.businessId or "")
    end
    if matches then result[#result + 1] = package end
  end
  return result
end

local function onExtensionLoaded()
  if not overhaul_career_career.isActive() then return false end
  initialize()
end

local function onCareerActivated()
  initialize()
end

local function onOverhaulModulesActivated()
  initialize()
end

local function onVehicleSpawned(vehId)
  -- Inventory rebuilds can reuse the isolated vehicle id; restore the replacement meshes.
  if not libraries.thumbnails.isolatedVehicleIds[vehId] then return end
  libraries.thumbnails.restoreVehiclePartVisibility(getObjectByID(vehId), vehId)
end

-- Public API -----------------------------------------------------------------------------------------------

M.openMenu = openMenu
M.requestData = requestData
M.createFromCurrent = createFromCurrent
M.renamePackage = renamePackage
M.installPackage = libraries.install.installPackage
M.storeInstalledPackage = libraries.install.storeInstalledPackage
M.dismantlePackage = dismantlePackage
M.sellPackage = sellPackage
M.closeMenu = closeMenu
M.getPackage = getPackageById
M.getPackageDetails = getPackageDetails
M.listPackages = listPackages
M.removeBusinessPackage = libraries.recipes.removeBusinessPackage
M.cloneFreshPackageFromRecipe = libraries.recipes.cloneFreshPackageFromRecipe
M.clonePersonalPackageFromRecipe = libraries.recipes.clonePersonalPackageFromRecipe
M.getFreshRecipeValue = function(recipe, existingIoCtx)
  return libraries.recipes.getRecipeValue(recipe, existingIoCtx)
end
M.getConditionedRecipeValue = function(recipe, metadata, existingIoCtx)
  return libraries.recipes.getRecipeValue(recipe, existingIoCtx, metadata or {})
end
M.getInstalledRecipeAndValue = libraries.recipes.getInstalledRecipeAndValue
M.getInstalledEngineRecipe = getInstalledEngineRecipe
M.consumeStoredPersonalPackage = libraries.recipes.consumeStoredPersonalPackage
M.cloneFreshBusinessPackageFromRecipe = libraries.recipes.cloneFreshBusinessPackageFromRecipe
M.transferBusinessPackageToPersonal = libraries.recipes.transferBusinessPackageToPersonal
M.transferPersonalPackageToBusiness = libraries.recipes.transferPersonalPackageToBusiness
M.repairManufacturedPackageYears = libraries.recipes.repairManufacturedPackageYears
M.getCurrentManufacturingYear = getCurrentManufacturingYear
M.installPackageIntoVehicle = libraries.recipes.installPackageIntoVehicle
M.storePackageFromVehicle = libraries.recipes.storePackageFromVehicle
M.getRecipeFromPackage = libraries.recipes.getRecipeFromPackage
M.getFreshPackageValue = libraries.recipes.getFreshPackageValue
M.setEngineShopCertification = libraries.recipes.setEngineShopCertification
M.computeRecipeSignature = libraries.recipes.computeRecipeSignature
M.getEngineCompatibilityKey = libraries.recipes.getEngineCompatibilityKey
M.registerPackageReferenceGuard = libraries.recipes.registerPackageReferenceGuard
M.filterRecipeTuning = libraries.capture.filterRecipeTuning
M.getPackageStatus = getPackageStatus
M.getPartIdsFromPackageTree = getPartIdsFromPackageTree
M.validatePackageTreeFits = libraries.capture.validatePackageTreeFits
M.findCompatibleRecipeTarget = libraries.recipes.findCompatibleRecipeTarget
M.findEngineAssemblyCandidates = libraries.capture.findEngineCandidates
M.getPackageThumbnailPath = getPackageThumbnailPath

-- Hooks --------------------------------------------------------------------------------------------

-- Teardown cancels continuations before capture completion can release a store
-- swap or autosave into career modules that are already unloading.
local function stopPackageWork()
  lifetimeGeneration = lifetimeGeneration + 1
  activeTransactionId = activeTransactionId + 1
  packageStore.transactionBusy = false
  packageStore.activeInstallCallback = nil
  menuOpen = false
  libraries.thumbnails.stopCaptures()
end

M.onExtensionUnloaded = stopPackageWork
M.onClientEndMission = stopPackageWork
M.onExtensionLoaded = onExtensionLoaded
M.onCareerActivated = onCareerActivated
M.onOverhaulModulesActivated = onOverhaulModulesActivated
M.onOverhaulComputerAddFunctions = onOverhaulComputerAddFunctions
M.onOverhaulPartShoppingTransactionComplete = onOverhaulPartShoppingTransactionComplete
M.onOverhaulTuningApplied = onOverhaulTuningApplied
M.onOverhaulVehicleRemoved = onOverhaulVehicleRemoved
M.onVehicleSpawned = onVehicleSpawned
M.onOverhaulSaveCurrentProfile = onOverhaulSaveCurrentProfile

return M
