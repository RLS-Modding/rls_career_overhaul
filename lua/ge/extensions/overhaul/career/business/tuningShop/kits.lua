-- Capture mechanical parts as saved business kits and apply them behind timed install locks.
-- Read the config and state, then the sections in order; the M exports at the bottom are the public API.
local capabilities = require("overhaul/lib/platform/capabilities")
local businessSaveState = require("overhaul/lib/business/saveState")
local M = {}
local checkout = require('overhaul/lib/checkout/operations')

local jbeamIO = require('jbeam/io')
require('json')

-- SaveStore key for the business kit file this module writes (metadata only).
require('overhaul/lib/save/store').registerKeys({
  {key = "business.tuningShopKits", owner = "overhaul_career_business_tuningShop_kits", files = {"career/rls_career/businesses/*/kits.json"}, phase = "profile", required = true},
})

-- Config ------------------------------------------------------------------------------------------


-- A kit install callback that has not answered after this many seconds is rolled back.
local CALLBACK_TIMEOUT_SECONDS = 30
-- Slots whose names contain one of these words hold the mechanical parts a kit captures.
local MECHANICAL_CATEGORIES = {"engine", "transmission", "suspension", "drivetrain", "differential", "transfer",
  "driveshaft", "steering", "fuel", "brake", "wheel", "tire", "hub", "spring", "shock",
  "coilover", "swaybar", "radiator", "intake", "exhaust"}
-- Each part-supplier level takes this share off the price of new parts.
local SUPPLIER_DISCOUNT_PER_LEVEL = 0.05
-- Each kit-storage level holds this many kits.
local KIT_SLOTS_PER_STORAGE_LEVEL = 2
-- A tank comes back from a respawn with at least this share of its capacity.
local MIN_FUEL_SHARE = 0.05

-- State -------------------------------------------------------------------------------------------


-- Runtime state belongs to this facade load: the saved kits, pending callbacks and install locks live here.
local runtimeState = {
  businessKits = {},
  pendingKitCallbacks = {},
  kitInstallLocks = {},
  loadedProfile = nil,
}

local parts = {kits = {}}

-- Shared helpers ----------------------------------------------------------------------------------

function parts.kits.normalizeBusinessId(businessId)
  if type(businessId) == "boolean" then
    return nil
  end
  return tonumber(businessId) or businessId
end

-- Parts -------------------------------------------------------------------------------------------


-- The quote part shares this load's owner helpers and keeps reload state isolated.
parts.quote = require("overhaul/career/business/tuningShop/kitsParts/quote").new({parts = parts, jbeamIO = jbeamIO})

-- Pending callbacks -------------------------------------------------------------------------------


-- Cancels a pending kit application: puts the car's original config back and refunds the debit.
local function rollbackKitCallback(callbackId)
  local pending = runtimeState.pendingKitCallbacks[callbackId]
  if not pending then return end
  pending.cancelled = true
  if pending.originalConfig then
    local vehObj = getObjectByID(pending.spawnedVehicleId)
    if vehObj then
      local restored = pcall(core_vehicles.replaceVehicle, pending.modelKey,
        {config = deepcopy(pending.originalConfig), keepOtherVehRotation = true}, vehObj)
      if not restored then vehObj:delete() end
    end
    if pending.inventoryId then
      local vehicle = overhaul_career_garage_inventory.getVehicles()[pending.inventoryId]
      if vehicle then vehicle.config = deepcopy(pending.originalConfig) end
    else
      overhaul_career_business_fleet.updateVehicle(pending.businessId, pending.vehicleId,
        {config = deepcopy(pending.originalConfig), vars = pending.originalConfig.vars, partList = pending.originalPartList})
    end
  end
  if pending.debited and not checkout.compensate(pending.operation, function()
        return checkout.money.execute(overhaul_career_economy_bank.addFunds, pending.accountId, pending.kitCost,
          "Kit Application Refund", "Kit application cancelled", {category = "refund"})
      end) then
    log("E", "tuningShopKits", "Kit refund failed for business " .. tostring(pending.businessId) .. ": " .. tostring(pending.kitCost))
    return
  end
  pending.saveHold.release()
  runtimeState.pendingKitCallbacks[callbackId] = nil
end

-- Profile and cars --------------------------------------------------------------------------------

local function resetState()
  for callbackId in pairs(runtimeState.pendingKitCallbacks) do rollbackKitCallback(callbackId) end
  require("overhaul/lib/save/store").releaseHolds(M)
  runtimeState.businessKits, runtimeState.pendingKitCallbacks, runtimeState.kitInstallLocks = {}, {}, {}
  runtimeState.loadedProfile = nil
end

local function ensureProfile()
  local profile = overhaul_career_saveSystem.getCurrentProfile()
  if runtimeState.loadedProfile ~= profile then
    resetState()
    runtimeState.loadedProfile = profile
  end
end

function parts.kits.isPersonalVehicleId(vehicleId)
  if not vehicleId then
    return false
  end
  return tostring(vehicleId):sub(1, 9) == "personal_"
end

function parts.kits.getSpawnedIdFromPersonalVehicleId(vehicleId)
  if not parts.kits.isPersonalVehicleId(vehicleId) then
    return nil
  end
  return tonumber(tostring(vehicleId):sub(10))
end

-- The personal car is only usable while it is the business's active one.
function parts.kits.getPersonalVehicleData(vehicleId, businessId)
  if not parts.kits.isPersonalVehicleId(vehicleId) or not businessId then
    return nil
  end
  local businessObj = overhaul_career_business_manager.getBusinessObject("tuningShop")
  if businessObj and businessObj.getActivePersonalVehicle then
    local activePersonal = businessObj.getActivePersonalVehicle(businessId)
    if activePersonal and tostring(activePersonal.vehicleId) == tostring(vehicleId) then
      return activePersonal
    end
  end
  return nil
end

local function getBusinessKitsPath(businessId)
  if not overhaul_career_career.isActive() then
    return nil
  end
  local _, currentSavePath = overhaul_career_saveSystem.getCurrentProfile()
  if not currentSavePath then
    return nil
  end
  return businessSaveState.businessFilePath(businessId .. "", "kits.json", currentSavePath .. "")
end

-- Saved kits --------------------------------------------------------------------------------------

function parts.kits.loadBusinessKits(businessId)
  ensureProfile()
  businessId = parts.kits.normalizeBusinessId(businessId)
  if not businessId then
    return {}
  end

  if runtimeState.businessKits[businessId] then
    return runtimeState.businessKits[businessId]
  end

  local filePath = getBusinessKitsPath(businessId)
  if not filePath then
    return {}
  end

  local data = jsonReadFile(filePath) or {}
  runtimeState.businessKits[businessId] = data.kits or {}
  return runtimeState.businessKits[businessId]
end

local function saveBusinessKits(businessId, currentSavePath, writer)
  businessId = parts.kits.normalizeBusinessId(businessId)
  if not businessId or not runtimeState.businessKits[businessId] then
    return
  end
  if not currentSavePath then
    return
  end

  local filePath = businessSaveState.businessFilePath(businessId .. "", "kits.json", currentSavePath .. "")

  local dirPath = string.match(filePath, "^(.*)/[^/]+$")
  if dirPath and not writer.exists(dirPath) then
    writer.mkdir(dirPath)
  end

  local data = {
    kits = runtimeState.businessKits[businessId]
  }

  require('overhaul/lib/save/store').writeSlot(filePath, data, true)
end

local function flattenKitTree(node, result)
  result = result or {}
  if not node then
    return result
  end

  if node.chosenPartName and node.chosenPartName ~= "" then
    table.insert(result, node.chosenPartName)
  end

  if node.children then
    for _, child in pairs(node.children) do
      flattenKitTree(child, result)
    end
  end

  return result
end

local function countKitParts(kit)
  if not kit or not kit.parts then
    return 0
  end
  local count = 0
  for _, partTree in pairs(kit.parts) do
    local parts = flattenKitTree(partTree)
    count = count + #parts
  end
  return count
end

local function isMechanicalPart(slotName, parentMap)
  if not slotName then
    return false
  end
  local lowerSlot = string.lower(slotName)

  for _, category in ipairs(MECHANICAL_CATEGORIES) do
    if string.find(lowerSlot, category, 1, true) then -- plain text search
      return true
    end
  end

  if parentMap and parentMap[slotName] then
    if parentMap[slotName] ~= slotName then
      return isMechanicalPart(parentMap[slotName], parentMap)
    end
  end

  return false
end

local function copyPartsTree(node)
  local copy = {
    chosenPartName = node.chosenPartName
  }
  if node.children then
    copy.children = {}
    for slot, child in pairs(node.children) do
      copy.children[slot] = copyPartsTree(child)
    end
  end
  return copy
end

-- Walks past the non-mechanical slots and keeps the mechanical ones as copied trees.
local function extractKitParts(node)
  local kitParts = {}
  if not node or not node.children then
    return kitParts
  end

  for slotName, childNode in pairs(node.children) do
    if isMechanicalPart(slotName) then
      if childNode.chosenPartName and childNode.chosenPartName ~= "" then
        kitParts[slotName] = copyPartsTree(childNode)
      end
    else
      local deeper = extractKitParts(childNode)
      for k, v in pairs(deeper) do
        kitParts[k] = v
      end
    end
  end
  return kitParts
end

-- Storage and supplier discount -------------------------------------------------------------------

local function getMaxKitStorage(businessId)
  businessId = parts.kits.normalizeBusinessId(businessId)
  if not businessId then
    return 0
  end
  local kitStorageLevel = overhaul_career_business_skillTree.getNodeProgress(businessId, "quality-of-life", "kit-storage") or 0
  local kitStorageIILevel = overhaul_career_business_skillTree.getNodeProgress(businessId, "quality-of-life", "kit-storage-ii") or 0
  return (kitStorageLevel * KIT_SLOTS_PER_STORAGE_LEVEL) + (kitStorageIILevel * KIT_SLOTS_PER_STORAGE_LEVEL)
end

local function hasKitStorageUnlocked(businessId)
  return getMaxKitStorage(businessId) > 0
end

local function kitStorageFull(businessId)
  local maxKits = getMaxKitStorage(businessId)
  return #parts.kits.loadBusinessKits(businessId) >= maxKits
end

function parts.kits.getPartSupplierDiscountMultiplier(businessId)
  if not businessId then
    return 1.0
  end

  local treeId = "shop-upgrades"
  local nodeId = "part-suppliers"

  local level = overhaul_career_business_skillTree.getNodeProgress(businessId, treeId, nodeId) or 0
  return 1.0 - (SUPPLIER_DISCOUNT_PER_LEVEL * level)
end

-- Kit creation ------------------------------------------------------------------------------------

local function notifyKitsUpdated(businessId)
  do
    guihooks.trigger('businessComputer:onKitsUpdated', {
      businessId = businessId
    })
  end
end

local function newKitId()
  return tostring(os.time()) .. "-" .. tostring(math.random(1000, 9999))
end

local function storeNewKit(businessId, kit)
  if not runtimeState.businessKits[businessId] then
    runtimeState.businessKits[businessId] = {}
  end
  table.insert(runtimeState.businessKits[businessId], kit)
  notifyKitsUpdated(businessId)
end

-- The job's best leaderboard time for its car when there is one, else the job's own time.
local function sourceJobTimeOf(businessId, job)
  local business = overhaul_career_business_manager.getBusinessObject("tuningShop")
  local bestTime = business.getJobLeaderboardBestTime(businessId, job)
  return bestTime or job.currentTime or job.baseTime
end

local function createKitFromConfig(businessId, jobId, kitName, config)
  if not businessId or not jobId or not kitName or not config then
    return false
  end

  local businessObj = overhaul_career_business_manager.getBusinessObject("tuningShop")
  local job = businessObj and businessObj.getJobById and businessObj.getJobById(businessId, jobId)
  if not job then
    return false
  end

  if not config.partsTree then
    return false
  end
  local kitParts = extractKitParts(config.partsTree)
  local tuning = config.vars or {}
  local sourceJobTime = sourceJobTimeOf(businessId, job)

  local kit = {
    id = newKitId(),
    name = kitName,
    model_key = config.model,
    sourceJobId = jobId,
    sourceJobEvent = job.raceLabel or job.raceType,
    sourceJobTime = sourceJobTime,
    parts = kitParts,
    tuning = tuning,
    createdTime = os.time()
  }
  kit.partCount = countKitParts(kit)
  storeNewKit(businessId, kit)
  return true
end

-- A personal car is kitted from its live config, with no source job.
local function createKitFromPersonalVehicle(businessId, vehicleId, kitName)
  businessId = parts.kits.normalizeBusinessId(businessId)
  if not businessId or not vehicleId or not kitName then
    return false
  end
  if kitStorageFull(businessId) then
    return false
  end
  if not parts.kits.getPersonalVehicleData(vehicleId, businessId) then
    return false
  end

  local spawnedId = parts.kits.getSpawnedIdFromPersonalVehicleId(vehicleId)
  if not spawnedId then
    return false
  end

  local vehObj = be:getObjectByID(spawnedId)
  if not vehObj then
    return false
  end

  local vehicleData = extensions.core_vehicle_manager.getVehicleData(spawnedId)
  if not vehicleData or not vehicleData.config or not vehicleData.config.partsTree then
    return false
  end

  local config = vehicleData.config
  local kitParts = extractKitParts(config.partsTree)
  local kit = {
    id = newKitId(),
    name = kitName,
    model_key = config.model or vehObj:getJBeamFilename(),
    sourceJobId = nil,
    sourceJobEvent = "Personal Vehicle",
    sourceJobTime = nil,
    parts = kitParts,
    tuning = config.vars or {},
    createdTime = os.time(),
    isPersonalSource = true
  }
  kit.partCount = countKitParts(kit)
  storeNewKit(businessId, kit)
  return true
end

local function createKit(businessId, jobId, kitName)
  businessId = parts.kits.normalizeBusinessId(businessId)
  if not businessId or not kitName then
    return false
  end

  if parts.kits.isPersonalVehicleId(jobId) then
    return createKitFromPersonalVehicle(businessId, jobId, kitName)
  end

  if not jobId or kitStorageFull(businessId) then
    return false
  end

  local businessObj = overhaul_career_business_manager.getBusinessObject("tuningShop")

  local vehicle = nil
  if businessObj and businessObj.getVehicleByJobId then
    vehicle = businessObj.getVehicleByJobId(businessId, jobId)
  end

  if not vehicle or not vehicle.config then
    return false
  end

  return createKitFromConfig(businessId, jobId, kitName, vehicle.config)
end

local function deleteKit(businessId, kitId)
  businessId = parts.kits.normalizeBusinessId(businessId)
  if not businessId or not kitId then
    return false
  end

  local kits = parts.kits.loadBusinessKits(businessId)
  local kitIndex = nil
  for i, kit in ipairs(kits) do
    if kit.id == kitId then
      kitIndex = i
      break
    end
  end

  if not kitIndex then
    return false
  end
  table.remove(kits, kitIndex)
  notifyKitsUpdated(businessId)
  return true
end

-- Install locks -----------------------------------------------------------------------------------

local function getKitInstallLocksPath(businessId)
  if not overhaul_career_career.isActive() then
    return nil
  end
  local _, currentSavePath = overhaul_career_saveSystem.getCurrentProfile()
  if not currentSavePath then
    return nil
  end
  return businessSaveState.businessFilePath(businessId .. "", "kitInstallLocks.json", currentSavePath .. "")
end

local function loadKitInstallLocks(businessId)
  ensureProfile()
  businessId = parts.kits.normalizeBusinessId(businessId)
  if not businessId then
    return {}
  end
  if runtimeState.kitInstallLocks[businessId] then
    return runtimeState.kitInstallLocks[businessId]
  end
  local businessObj = overhaul_career_business_manager.getBusinessObject("tuningShop")
  if businessObj and businessObj.initializeBusinessData then
    businessObj.initializeBusinessData(businessId)
  end
  return runtimeState.kitInstallLocks[businessId] or {}
end

local function setKitInstallLocksFromData(businessId, locksData)
  ensureProfile()
  businessId = parts.kits.normalizeBusinessId(businessId)
  if not businessId then
    return
  end
  runtimeState.kitInstallLocks[businessId] = locksData or {}
end

local function getKitInstallLocksForSave(businessId)
  ensureProfile()
  businessId = parts.kits.normalizeBusinessId(businessId)
  return runtimeState.kitInstallLocks[businessId] or {}
end

local function setKitInstallLock(businessId, vehicleId, unlockTime, kitName)
  businessId = parts.kits.normalizeBusinessId(businessId)
  if not businessId or not vehicleId then
    return
  end
  if not runtimeState.kitInstallLocks[businessId] then
    runtimeState.kitInstallLocks[businessId] = {}
  end
  runtimeState.kitInstallLocks[businessId][tostring(vehicleId)] = {
    unlockTime = unlockTime,
    kitName = kitName
  }
end

local function getKitInstallLock(businessId, vehicleId)
  businessId = parts.kits.normalizeBusinessId(businessId)
  if not businessId or not vehicleId then
    return nil
  end
  local locks = loadKitInstallLocks(businessId)
  return locks[tostring(vehicleId)]
end

local function isVehicleKitLocked(businessId, vehicleId)
  local lock = getKitInstallLock(businessId, vehicleId)
  if not lock then
    return false
  end
  return os.time() < lock.unlockTime
end

local function getKitInstallTimeRemaining(businessId, vehicleId)
  local lock = getKitInstallLock(businessId, vehicleId)
  if not lock then
    return 0
  end
  local remaining = lock.unlockTime - os.time()
  return math.max(0, remaining)
end

-- Clears the locks whose time has passed and tells the computer which cars are ready.
local function processKitInstallLocks(businessId)
  businessId = parts.kits.normalizeBusinessId(businessId)
  if not businessId then
    return
  end
  local locks = loadKitInstallLocks(businessId)
  if not locks or not next(locks) then
    return
  end
  local currentTime = os.time()
  local changed = false
  local unlockedVehicles = {}
  for vehicleId, lock in pairs(locks) do
    if currentTime >= lock.unlockTime then
      table.insert(unlockedVehicles, { vehicleId = vehicleId, kitName = lock.kitName })
      locks[vehicleId] = nil
      changed = true
    end
  end
  if changed then
    for _, unlocked in ipairs(unlockedVehicles) do
      do
        guihooks.trigger('businessComputer:onKitInstallComplete', {
          businessId = businessId,
          vehicleId = unlocked.vehicleId,
          kitName = unlocked.kitName
        })
      end
    end
  end
end

-- Fuel --------------------------------------------------------------------------------------------

local function storeFuelLevels(vehObj, callback)
  if not vehObj then
    if callback then
      callback()
    end
    return
  end

  core_vehicleBridge.requestValue(vehObj, function(data)
    local storedFuelLevels = {}
    if data and data[1] then
      for _, tank in ipairs(data[1]) do
        if tank.energyType ~= "n2o" then
          storedFuelLevels[tank.name] = {
            currentEnergy = tank.currentEnergy,
            maxEnergy = tank.maxEnergy,
            energyType = tank.energyType,
            relativeFuel = tank.maxEnergy > 0 and (tank.currentEnergy / tank.maxEnergy) or 0
          }
        end
      end
    end
    if callback then
      callback(storedFuelLevels)
    end
  end, 'energyStorage')
end

local function restoreFuelLevels(vehObj, storedFuelLevels)
  if not vehObj or not storedFuelLevels or not next(storedFuelLevels) then
    return
  end

  core_vehicleBridge.requestValue(vehObj, function(data)
    if not data or not data[1] then
      return
    end

    for _, tank in ipairs(data[1]) do
      local stored = storedFuelLevels[tank.name]
      if stored and stored.energyType == tank.energyType then
        local newFuelAmount = math.min(stored.currentEnergy, tank.maxEnergy)
        if tank.maxEnergy > stored.maxEnergy then
          newFuelAmount = tank.maxEnergy * stored.relativeFuel
        end

        local minFuel = tank.maxEnergy * MIN_FUEL_SHARE
        newFuelAmount = math.max(newFuelAmount, minFuel)

        core_vehicleBridge.executeAction(vehObj, 'setEnergyStorageEnergy', tank.name, newFuelAmount)
      end
    end
  end, 'energyStorage')
end

-- Applying a kit: vehicle resolution --------------------------------------------------------------


-- A personal car: its spawned object and config, or a refusal when it is missing or not spawned.
local function resolvePersonalKitCar(businessId, vehicleId)
  local vehicle = parts.kits.getPersonalVehicleData(vehicleId, businessId)
  if not vehicle then
    return nil, {success = false, error = "Personal vehicle not found"}
  end

  local spawnedId = parts.kits.getSpawnedIdFromPersonalVehicleId(vehicleId)
  if not spawnedId then
    return nil, {success = false, error = "Invalid personal vehicle ID"}
  end

  local vehObj = be:getObjectByID(spawnedId)
  if not vehObj then
    return nil, {success = false, error = "Personal vehicle not spawned"}
  end

  local vehicleData = extensions.core_vehicle_manager.getVehicleData(spawnedId)
  if not vehicleData or not vehicleData.config then
    return nil, {success = false, error = "Personal vehicle configuration not found"}
  end

  return {
    vehicle = vehicle,
    vehObj = vehObj,
    modelKey = vehicleData.config.model or vehObj:getJBeamFilename(),
    currentConfig = deepcopy(vehicleData.config),
    inventoryId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(spawnedId)
  }
end

-- A fleet car: its config comes from the live object when one is spawned, else from the fleet record.
local function resolveFleetKitCar(businessId, vehicleId)
  local vehicle = overhaul_career_business_fleet.getVehicleById(businessId, vehicleId)
  if not vehicle or not vehicle.vehicleConfig then
    return nil, {success = false, error = "Vehicle configuration not found"}
  end

  local vehObj = nil
  local spawnedVehicleId = overhaul_career_business_fleet.getSpawnedVehicleId(businessId, vehicleId)
  if spawnedVehicleId then
    vehObj = getObjectByID(spawnedVehicleId)
  end

  local vehicleData = vehObj and extensions.core_vehicle_manager.getVehicleData(spawnedVehicleId)
  if vehicleData and vehicleData.config then
    return {
      vehicle = vehicle,
      vehObj = vehObj,
      modelKey = vehicleData.config.model or vehObj:getJBeamFilename(),
      currentConfig = deepcopy(vehicleData.config)
    }
  end
  return {
    vehicle = vehicle,
    vehObj = vehObj,
    modelKey = vehicle.vehicleConfig.model_key or vehicle.model_key,
    currentConfig = deepcopy(vehicle.config)
  }
end

-- Checks what the car needs before a kit goes on: a model, a parts tree and a spawned object.
local function resolveKitApplicationVehicle(businessId, vehicleId)
  local resolution, refusal
  if parts.kits.isPersonalVehicleId(vehicleId) then
    resolution, refusal = resolvePersonalKitCar(businessId, vehicleId)
  else
    resolution, refusal = resolveFleetKitCar(businessId, vehicleId)
  end
  if not resolution then
    return nil, refusal
  end

  if not resolution.modelKey then
    return nil, {success = false, error = "Vehicle model key not found"}
  end
  if not resolution.currentConfig or not resolution.currentConfig.partsTree then
    return nil, {success = false, error = "Vehicle configuration tree not found"}
  end
  if not resolution.vehObj then
    return nil, {success = false, error = "Vehicle not found or not spawned"}
  end
  return resolution
end

-- Applying a kit: checks and pricing --------------------------------------------------------------


-- Refuses a kit while the save is busy or the same car already has one pending.
local function applyRefusal(businessId, vehicleId)
  if overhaul_career_saveSystem.isSaveBusy() then
    guihooks.trigger("toastrMsg", {type="info", title="Saving career", msg="Please try applying the kit again in a moment."})
    return {success = false, error = "Career save in progress"}
  end
  for _, pending in pairs(runtimeState.pendingKitCallbacks) do
    if tostring(pending.businessId) == tostring(businessId) and tostring(pending.vehicleId) == tostring(vehicleId) then
      guihooks.trigger("toastrMsg", {type="info", title="Kit application in progress", msg="Please wait for the current kit to finish."})
      return {success = false, error = "Kit application in progress"}
    end
  end
  return nil
end

local function findKitById(kits, kitId)
  for _, kit in ipairs(kits) do
    if kit.id == kitId then
      return kit
    end
  end
  return nil
end

-- Returns the business account id, or a refusal when the account cannot cover the price.
local function checkKitFunds(businessId, kitCost, costBreakdown)
  local businessAccount = overhaul_career_economy_bank.getBusinessAccount("tuningShop", businessId)
  if not businessAccount then
    return nil, nil
  end
  local accountId = businessAccount.id
  local balance = overhaul_career_economy_bank.getAccountBalance(accountId)
  if balance < kitCost then
    return nil, {
      success = false,
      error = "Insufficient funds",
      cost = kitCost,
      costBreakdown = costBreakdown,
      balance = balance
    }
  end
  return accountId, nil
end

-- Merges the kit's part tree into the first node that holds slotName; true when one did.
local function mergeSlotIntoTree(node, slotName, kitNode, path)
  path = path or "/"
  if not node or not node.children then
    return false
  end

  if node.children[slotName] then
    node.children[slotName] = parts.quote.mergeKitIntoConfig(kitNode, node.children[slotName], path .. slotName .. "/")
    return true
  end

  for childSlotName, childNode in pairs(node.children) do
    if mergeSlotIntoTree(childNode, slotName, kitNode, path .. childSlotName .. "/") then
      return true
    end
  end
  return false
end

-- Writes the kit's parts and tuning into the car's config; the caller keeps the original first.
local function applyKitToConfig(currentConfig, kit)
  if not currentConfig.partsTree.children then
    currentConfig.partsTree.children = {}
  end
  for slotName, kitNode in pairs(kit.parts or {}) do
    mergeSlotIntoTree(currentConfig.partsTree, slotName, kitNode, "/")
  end

  if kit.tuning and next(kit.tuning) then
    if not currentConfig.vars then
      currentConfig.vars = {}
    end
    for k, v in pairs(kit.tuning) do
      currentConfig.vars[k] = v
    end
  end
end

-- Takes the kit price from the business account; a free kit skips the debit. False when the debit is refused.
local function settleKitPrice(checkout, operation, accountId, kitCost, kit)
  if kitCost <= 0 then
    return true
  end
  if not accountId then
    return false
  end
  return checkout.settle(operation, function()
    return checkout.money.execute(overhaul_career_economy_bank.removeFunds, accountId, kitCost, "Kit Application", "Applied kit: " .. kit.name, nil, {category = "purchase"})
  end) and true or false
end

-- Applying a kit: spawn and reply -----------------------------------------------------------------


-- A kit callback still counts only while it is pending and has not been cancelled.
local function kitCallbackLive(callbackId)
  local pending = runtimeState.pendingKitCallbacks[callbackId]
  return pending ~= nil and not pending.cancelled
end

-- Asks the respawned car for the config it settled into; the reply lands in onVehicleConfigReceived.
local function requestKitConfig(callbackId, vehObj, storedFuelLevels)
  core_vehicleBridge.requestValue(vehObj, function()
    if not kitCallbackLive(callbackId) then return end
    restoreFuelLevels(vehObj, storedFuelLevels)

    vehObj:queueLuaCommand([[
        local configData = serialize(v.config)
        obj:queueGameEngineLua(require('vehicle/overhaul/geCallback').reply(]] .. require('overhaul/lib/vehicles/callbacks').open('kitVehicleConfig', {owner = 'tuningShopKits', vehId = vehObj:getID(), onFail = function() rollbackKitCallback(callbackId) end}) .. [[, 'kitVehicleConfig', "']] .. callbackId .. [[', " .. configData))
      ]])
  end, 'ping')
end

local function respawnWithKit(callbackId, vehObj, modelKey, currentConfig, storedFuelLevels)
  if not kitCallbackLive(callbackId) then return end
  local additionalVehicleData = {
    spawnWithEngineRunning = false
  }
  core_vehicle_manager.queueAdditionalVehicleData(additionalVehicleData, vehObj:getID())

  local spawnOptions = {}
  spawnOptions.config = currentConfig
  spawnOptions.keepOtherVehRotation = true
  core_vehicles.replaceVehicle(modelKey, spawnOptions, vehObj)

  requestKitConfig(callbackId, vehObj, storedFuelLevels)
end

-- Stores the fuel first, so the respawn can restore it.
local function startKitSpawn(callbackId, vehObj, modelKey, currentConfig)
  storeFuelLevels(vehObj, function(storedFuelLevels)
    respawnWithKit(callbackId, vehObj, modelKey, currentConfig, storedFuelLevels)
  end)
end

-- Applies a kit to a car: prices it, takes the money, and respawns the car with the kit.
local function rememberKitApplication(callbackId, businessId, vehicleId, kitId, kit, accountId, kitCost, operation, costBreakdown, resolution, originalConfig)
  runtimeState.pendingKitCallbacks[callbackId] = {
    saveHold = require("overhaul/lib/save/store").hold(M, "kit application"),
    businessId = businessId,
    vehicleId = vehicleId,
    kitId = kitId,
    kit = kit,
    accountId = accountId,
    kitCost = kitCost,
    operation = operation,
    costBreakdown = costBreakdown,
    inventoryId = resolution.inventoryId,
    installTimeSeconds = costBreakdown.installTimeSeconds or 0,
    originalConfig = originalConfig,
    originalPartList = deepcopy(resolution.vehicle.partList),
    modelKey = resolution.modelKey,
    spawnedVehicleId = resolution.vehObj:getID(),
    debited = kitCost > 0,
    elapsed = 0
  }
end

local function applyKit(businessId, vehicleId, kitId)
  businessId = parts.kits.normalizeBusinessId(businessId)
  if not businessId or not vehicleId or not kitId then
    return {success = false, error = "Missing parameters"}
  end

  local kits = parts.kits.loadBusinessKits(businessId)
  local refusal = applyRefusal(businessId, vehicleId)
  if refusal then
    return refusal
  end

  local kit = findKitById(kits, kitId)
  if not kit then
    return {success = false, error = "Kit not found"}
  end

  local resolution, resolveRefusal = resolveKitApplicationVehicle(businessId, vehicleId)
  if not resolution then
    return resolveRefusal
  end

  local repairReason = require('overhaul/lib/business/customizationAccess').getRepairReason(businessId, vehicleId, resolution.vehicle)
  if repairReason then return {success = false, error = repairReason.label} end
  if not overhaul_career_business_partCustomization.settlePreviewVehicle() then
    return {success = false, error = "Preview restoration pending; retry the kit"}
  end
  -- Resolution above may have observed an unpaid live preview, even when discard settled synchronously.
  resolution, resolveRefusal = resolveKitApplicationVehicle(businessId, vehicleId)
  if not resolution then return resolveRefusal end

  local costBreakdown = parts.quote.getKitCostBreakdown(businessId, vehicleId, kitId)
  if not costBreakdown then
    return {success = false, error = "Could not price the kit for this vehicle"}
  end
  local kitCost = costBreakdown.totalCost
  local accountId, fundsRefusal = checkKitFunds(businessId, kitCost, costBreakdown)
  if fundsRefusal then
    return fundsRefusal
  end

  local originalConfig = deepcopy(resolution.currentConfig)
  applyKitToConfig(resolution.currentConfig, kit)

  local callbackId = Engine.generateUUID()
  local operation = checkout.begin("kit", {amount = kitCost, payer = checkout.business(businessId, accountId),
    target = {vehicleId = vehicleId, kitId = kitId}})
  if not settleKitPrice(checkout, operation, accountId, kitCost, kit) then
    return {success = false, error = "Payment failed", cost = kitCost}
  end

  rememberKitApplication(callbackId, businessId, vehicleId, kitId, kit, accountId, kitCost, operation, costBreakdown, resolution, originalConfig)

  local started, startError = pcall(startKitSpawn, callbackId, resolution.vehObj, resolution.modelKey, resolution.currentConfig)
  if not started then
    rollbackKitCallback(callbackId)
    return {success = false, error = tostring(startError)}
  end

  return {
    success = true,
    cost = kitCost,
    costBreakdown = costBreakdown
  }
end

-- Completing a kit: the car's reply ---------------------------------------------------------------


-- Merges the kit's tuning into the reported config and tells the shop to re-price the tune.
local function applyKitTuning(businessId, vehicleId, kit, actualConfig)
  if kit.tuning and next(kit.tuning) then
    if not actualConfig.vars then
      actualConfig.vars = {}
    end
    for k, v in pairs(kit.tuning) do
      actualConfig.vars[k] = v
    end

    capabilities.get("businessComputer").applyVehicleTuning(businessId, vehicleId, kit.tuning, nil)
  end
end

-- Maps every part in the tree to its slot path.
local function collectPartList(tree, path, partList)
  path = path or "/"
  if tree.chosenPartName and tree.chosenPartName ~= "" then
    partList[path] = tree.chosenPartName
  end
  if tree.children then
    for slotName, child in pairs(tree.children) do
      collectPartList(child, path .. slotName .. "/", partList)
    end
  end
end

-- Maps every part the kit names to its slot path, so only those parts get fresh conditions.
local function collectKitPartPaths(node, path, kitPartPaths)
  path = path or "/"
  if node.chosenPartName and node.chosenPartName ~= "" then
    kitPartPaths[path .. node.chosenPartName] = true
  end
  if node.children then
    for childSlot, childNode in pairs(node.children) do
      collectKitPartPaths(childNode, path .. childSlot .. "/", kitPartPaths)
    end
  end
end

-- The spawned car for this vehicle: a personal car by its id, a fleet car by the fleet's spawn record.
local function resolveKitCarObject(businessId, vehicleId, inventoryId)
  if inventoryId then
    local spawnedId = parts.kits.getSpawnedIdFromPersonalVehicleId(vehicleId)
    if spawnedId then
      return be:getObjectByID(spawnedId)
    end
  else
    local spawnedVehicleId = overhaul_career_business_fleet.getSpawnedVehicleId(businessId, vehicleId)
    if spawnedVehicleId then
      return getObjectByID(spawnedVehicleId)
    end
  end
  return nil
end

-- Gives freshly fitted parts new conditions; the old parts keep theirs.
local function initKitPartConditions(vehObj, partList, kitPartPaths)
  local newPartConditions = {}
  for slotPath, partName in pairs(partList) do
    if kitPartPaths[slotPath .. partName] then
      newPartConditions[slotPath .. partName] = {
        integrityValue = 1,
        odometer = 0,
        visualValue = 1
      }
    end
  end
  if next(newPartConditions) then
    core_vehicleBridge.executeAction(vehObj, 'initPartConditions', newPartConditions)
  end
end

local function writeKitConfigToInventory(inventoryId, actualConfig)
  local vehicles = overhaul_career_garage_inventory.getVehicles()
  if vehicles and vehicles[inventoryId] then
    vehicles[inventoryId].config = actualConfig
    vehicles[inventoryId].config.vars = actualConfig.vars
    overhaul_career_garage_inventory.setVehicleDirty(inventoryId)
  end
end

-- Writes the config to a fleet car, including the copy the pulled-out list holds, and drops its job proof.
local function writeKitConfigToFleet(businessId, vehicleId, actualConfig, partList)
  overhaul_career_business_fleet.updateVehicle(businessId, vehicleId, {
    config = actualConfig,
    vars = actualConfig.vars,
    partList = partList
  })

  local pulledVehicles = overhaul_career_business_fleet.getPulledOutVehicles(businessId) or {}
  local targetId = tonumber(vehicleId) or vehicleId
  for _, pulled in ipairs(pulledVehicles) do
    local pulledId = tonumber(pulled.vehicleId) or pulled.vehicleId
    if pulledId == targetId then
      pulled.config = actualConfig
      pulled.vars = actualConfig.vars
      pulled.partList = partList
      break
    end
  end

  local jobId = overhaul_career_business_fleet.getJobIdFromVehicle(businessId, vehicleId)
  if jobId then
    overhaul_career_business_tuningShop_tuningShop.invalidateJobCompletionProof(businessId, jobId)
  end
end

-- A timed install parks the car until the lock runs out; then tells the computer the kit is on.
local function lockAndAnnounceKit(businessId, vehicleId, kit, kitId, kitCost, installTimeSeconds)
  if installTimeSeconds > 0 then
    local unlockTime = os.time() + installTimeSeconds
    setKitInstallLock(businessId, vehicleId, unlockTime, kit.name)

    capabilities.get("businessComputer").putAwayVehicle(businessId, vehicleId)
  end

  guihooks.trigger('businessComputer:onKitApplied', {
    businessId = businessId,
    vehicleId = vehicleId,
    kitId = kitId,
    kitName = kit.name,
    cost = kitCost,
    installTimeSeconds = installTimeSeconds
  })
end

-- Writes the reported config to the car and its record, then releases the pending callback.
local function completeKitApplication(callbackId, config)
  ensureProfile()
  local callbackData = runtimeState.pendingKitCallbacks[callbackId]
  if not callbackData or callbackData.cancelled then
    return
  end

  local businessId = callbackData.businessId
  local vehicleId = callbackData.vehicleId
  local kit = callbackData.kit
  local inventoryId = callbackData.inventoryId

  if type(config) ~= "table" or type(config.partsTree) ~= "table" then
    rollbackKitCallback(callbackId)
    return
  end

  local actualConfig = config
  applyKitTuning(businessId, vehicleId, kit, actualConfig)

  local partList = {}
  collectPartList(actualConfig.partsTree or {}, "/", partList)

  local kitPartPaths = {}
  if kit.parts then
    for slotName, kitNode in pairs(kit.parts) do
      collectKitPartPaths(kitNode, "/" .. slotName .. "/", kitPartPaths)
    end
  end

  local vehObj = resolveKitCarObject(businessId, vehicleId, inventoryId)
  if vehObj and kit.parts then
    initKitPartConditions(vehObj, partList, kitPartPaths)
  end

  if inventoryId then
    writeKitConfigToInventory(inventoryId, actualConfig)
  else
    writeKitConfigToFleet(businessId, vehicleId, actualConfig, partList)
  end

  if inventoryId then
    overhaul_career_repair_damageManager.saveDamageState(inventoryId)
  end
  lockAndAnnounceKit(businessId, vehicleId, kit, callbackData.kitId, callbackData.kitCost, callbackData.installTimeSeconds or 0)
  callbackData.saveHold.release()
  runtimeState.pendingKitCallbacks[callbackId] = nil
  require('overhaul/lib/save/store').request("kits:applied", inventoryId and {inventoryId} or nil)
end

-- Runs completeKitApplication under pcall, so a broken reply rolls the kit back instead of leaking.
local function onVehicleConfigReceived(callbackId, config)
  local ok, err = pcall(completeKitApplication, callbackId, config)
  if not ok then
    rollbackKitCallback(callbackId)
    log("E", "tuningShopKits", tostring(err))
  end
end

-- Kit lookup --------------------------------------------------------------------------------------

local function getKitDetails(businessId, kitId)
  businessId = parts.kits.normalizeBusinessId(businessId)
  if not businessId or not kitId then
    return nil
  end

  local kits = parts.kits.loadBusinessKits(businessId)
  for _, kit in ipairs(kits) do
    if kit.id == kitId then
      return kit
    end
  end
  return nil
end

-- Per-frame update --------------------------------------------------------------------------------


-- Rolls back any kit whose car has not replied in time.
local function onUpdate(dt)
  for callbackId, pending in pairs(runtimeState.pendingKitCallbacks) do
    pending.elapsed = (pending.elapsed or 0) + math.max(dt or 0, 0)
    if pending.elapsed >= CALLBACK_TIMEOUT_SECONDS or pending.cancelled then
      rollbackKitCallback(callbackId)
      if not runtimeState.pendingKitCallbacks[callbackId] then require('overhaul/lib/save/store').request("kits:rolledBack") end
    end
  end
end

-- Lifecycle ---------------------------------------------------------------------------------------



local function onOverhaulSaveCurrentProfile(currentSavePath, _, writer)
  writer = writer or overhaul_career_saveSystem.getSaveWriter()
  ensureProfile()
  if currentSavePath then
    for businessId, owned in pairs(overhaul_career_business_manager.getPurchasedBusinesses("tuningShop") or {}) do
      if owned and parts.kits.normalizeBusinessId(businessId) then
        parts.kits.loadBusinessKits(businessId)
        loadKitInstallLocks(businessId)
      end
    end
  end
  for businessId, _ in pairs(runtimeState.businessKits) do
    saveBusinessKits(businessId, currentSavePath, writer)
  end
  require('overhaul/lib/business/saveState').clearUnownedFiles(currentSavePath,
    {"kits.json", "kitInstallLocks.json"}, "tuningShop", writer)
end

local function clearBusinessKits(businessId)
  ensureProfile()
  businessId = parts.kits.normalizeBusinessId(businessId)
  if not businessId then return false end
  runtimeState.businessKits[businessId] = {}
  runtimeState.kitInstallLocks[businessId] = {}
  for callbackId, callbackData in pairs(runtimeState.pendingKitCallbacks) do
    if callbackData and parts.kits.normalizeBusinessId(callbackData.businessId) == businessId then
      rollbackKitCallback(callbackId)
    end
  end
  return true
end

-- Public API ---------------------------------------------------------------------------------------

M.loadBusinessKits = parts.kits.loadBusinessKits
M.getBusinessKits = parts.kits.loadBusinessKits
M.getKitDetails = getKitDetails
M.getKitCostBreakdown = parts.quote.getKitCostBreakdown
M.countKitParts = countKitParts
M.createKit = createKit
M.deleteKit = deleteKit
M.applyKit = applyKit
M.isSettlementPending = function() return next(runtimeState.pendingKitCallbacks) ~= nil end
M.getMaxKitStorage = getMaxKitStorage
M.hasKitStorageUnlocked = hasKitStorageUnlocked
M.isVehicleKitLocked = isVehicleKitLocked
M.getKitInstallTimeRemaining = getKitInstallTimeRemaining
M.getKitInstallLock = getKitInstallLock
M.getKitInstallLocksPath = getKitInstallLocksPath
M.processKitInstallLocks = processKitInstallLocks
M.setKitInstallLocksFromData = setKitInstallLocksFromData
M.getKitInstallLocksForSave = getKitInstallLocksForSave
M.clearBusinessKits = clearBusinessKits

M.resetState = resetState


-- Game hooks --------------------------------------------------------------------------------------

M.onVehicleConfigReceived = onVehicleConfigReceived
M.onUpdate = onUpdate
M.onOverhaulSaveCurrentProfile = onOverhaulSaveCurrentProfile
M.onExtensionLoaded = resetState
M.onExtensionUnloaded = resetState
M.onCareerActivated = resetState
M.onOverhaulActive = resetState
M.onOverhaulBeforeSetProfile = resetState

return M
