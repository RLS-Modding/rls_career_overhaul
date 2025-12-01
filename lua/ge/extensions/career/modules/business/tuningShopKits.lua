local M = {}

local jbeamIO = require('jbeam/io')
local json = require('json')

local businessKits = {}
local pendingKitCallbacks = {}
local kitInstallLocks = {}

local function isPersonalVehicleId(vehicleId)
  if not vehicleId then
    return false
  end
  return tostring(vehicleId):sub(1, 9) == "personal_"
end

local function getSpawnedIdFromPersonalVehicleId(vehicleId)
  if not isPersonalVehicleId(vehicleId) then
    return nil
  end
  return tonumber(tostring(vehicleId):sub(10))
end

local function getPersonalVehicleData(vehicleId, businessId)
  if not isPersonalVehicleId(vehicleId) then
    return nil
  end
  if career_modules_business_tuningShop and career_modules_business_tuningShop.getActivePersonalVehicle and businessId then
    local activePersonal = career_modules_business_tuningShop.getActivePersonalVehicle(businessId)
    if activePersonal and tostring(activePersonal.vehicleId) == tostring(vehicleId) then
      return activePersonal
    end
  end
  return nil
end

local function normalizeBusinessId(businessId)
  if type(businessId) == "boolean" then
    return "fastAutoTuningShop"
  end
  return tonumber(businessId) or businessId
end

local function getBusinessKitsPath(businessId)
  if not career_career.isActive() then
    return nil
  end
  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  if not currentSavePath then
    return nil
  end
  return currentSavePath .. "/career/rls_career/businesses/" .. businessId .. "/kits.json"
end

local function loadBusinessKits(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return {}
  end

  if businessKits[businessId] then
    return businessKits[businessId]
  end

  local filePath = getBusinessKitsPath(businessId)
  if not filePath then
    return {}
  end

  local data = jsonReadFile(filePath) or {}
  businessKits[businessId] = data.kits or {}
  return businessKits[businessId]
end

local function saveBusinessKits(businessId, currentSavePath)
  businessId = normalizeBusinessId(businessId)
  if not businessId or not businessKits[businessId] then
    return
  end
  if not currentSavePath then
    return
  end

  local filePath = currentSavePath .. "/career/rls_career/businesses/" .. businessId .. "/kits.json"

  local dirPath = string.match(filePath, "^(.*)/[^/]+$")
  if dirPath and not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end

  local data = {
    kits = businessKits[businessId]
  }

  jsonWriteFile(filePath, data, true)
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

  -- Minimal top-level mechanical categories
  -- Everything under these parent terms will be saved automatically
  local topLevelCategories = {"engine", "transmission", "suspension", "drivetrain", "differential", "transfer",
                              "driveshaft", "steering", "fuel", "brake", "wheel", "tire", "hub", "spring", "shock",
                              "coilover", "swaybar", "radiator", "intake", "exhaust"}

  -- Check if the slot path contains any top-level mechanical category
  for _, category in ipairs(topLevelCategories) do
    if string.find(lowerSlot, category, 1, true) then -- plain text search
      return true
    end
  end

  -- Check parent
  if parentMap and parentMap[slotName] then
    -- Simple cycle prevention: if parent is same as slot (shouldn't happen)
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

local function createKitFromConfig(businessId, jobId, kitName, config)
  if not businessId or not jobId or not kitName or not config then
    return false
  end

  local tuningShop = career_modules_business_tuningShop
  local job = tuningShop and tuningShop.getJobById(businessId, jobId)

  if not job then
    return false
  end

  local kitParts = {}
  if config.partsTree then
    kitParts = extractKitParts(config.partsTree)
  else
    return false
  end

  local tuning = config.vars or {}

  local sourceJobTime = job.currentTime or job.baseTime
  if career_modules_business_businessHelpers and career_modules_business_businessHelpers.getBestLeaderboardTime then
    local bestTime = career_modules_business_businessHelpers.getBestLeaderboardTime(businessId, jobId, job.raceType,
      job.raceLabel)
    if bestTime then
      sourceJobTime = bestTime
    end
  end

  local kit = {
    id = tostring(os.time()) .. "-" .. tostring(math.random(1000, 9999)),
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

  if not businessKits[businessId] then
    businessKits[businessId] = {}
  end

  table.insert(businessKits[businessId], kit)

  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  if currentSavePath then
    saveBusinessKits(businessId, currentSavePath)
  end

  if guihooks then
    guihooks.trigger('businessComputer:onKitsUpdated', {
      businessId = businessId
    })
  end

  return true
end

local function createKitFromPersonalVehicle(businessId, vehicleId, kitName)
  businessId = normalizeBusinessId(businessId)
  if not businessId or not vehicleId or not kitName then
    return false
  end

  local maxKits = M.getMaxKitStorage(businessId)
  local currentKits = loadBusinessKits(businessId)
  if #currentKits >= maxKits then
    return false
  end

  local personalVehicle = getPersonalVehicleData(vehicleId, businessId)
  if not personalVehicle then
    return false
  end

  local spawnedId = getSpawnedIdFromPersonalVehicleId(vehicleId)
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
  local tuning = config.vars or {}

  local kit = {
    id = tostring(os.time()) .. "-" .. tostring(math.random(1000, 9999)),
    name = kitName,
    model_key = config.model or vehObj:getJBeamFilename(),
    sourceJobId = nil,
    sourceJobEvent = "Personal Vehicle",
    sourceJobTime = nil,
    parts = kitParts,
    tuning = tuning,
    createdTime = os.time(),
    isPersonalSource = true
  }
  kit.partCount = countKitParts(kit)

  if not businessKits[businessId] then
    businessKits[businessId] = {}
  end

  table.insert(businessKits[businessId], kit)

  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  if currentSavePath then
    saveBusinessKits(businessId, currentSavePath)
  end

  if guihooks then
    guihooks.trigger('businessComputer:onKitsUpdated', {
      businessId = businessId
    })
  end

  return true
end

local function createKit(businessId, jobId, kitName, spawnedVehicleId)
  businessId = normalizeBusinessId(businessId)
  if not businessId or not kitName then
    return false
  end

  if isPersonalVehicleId(jobId) then
    return createKitFromPersonalVehicle(businessId, jobId, kitName)
  end

  if not jobId then
    return false
  end

  local maxKits = M.getMaxKitStorage(businessId)
  local currentKits = loadBusinessKits(businessId)
  if #currentKits >= maxKits then
    return false
  end

  local tuningShop = career_modules_business_tuningShop

  local vehicle = nil
  if tuningShop and tuningShop.getVehicleByJobId then
    vehicle = tuningShop.getVehicleByJobId(businessId, jobId)
  end

  if not vehicle then
    return false
  end

  if not vehicle.config then
    return false
  end

  return createKitFromConfig(businessId, jobId, kitName, vehicle.config)
end

local function deleteKit(businessId, kitId)
  businessId = normalizeBusinessId(businessId)
  if not businessId or not kitId then
    return false
  end

  local kits = loadBusinessKits(businessId)
  local kitIndex = nil
  for i, kit in ipairs(kits) do
    if kit.id == kitId then
      kitIndex = i
      break
    end
  end

  if kitIndex then
    table.remove(kits, kitIndex)
    local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
    if currentSavePath then
      saveBusinessKits(businessId, currentSavePath)
    end

    if guihooks then
      guihooks.trigger('businessComputer:onKitsUpdated', {
        businessId = businessId
      })
    end

    return true
  end

  return false
end

local function getPartSupplierDiscountMultiplier(businessId)
  if not businessId then
    return 1.0
  end

  if not career_modules_business_businessSkillTree then
    return 1.0
  end

  local businessType = "tuningShop"
  local treeId = "shop-upgrades"
  local nodeId = "part-suppliers"

  local level = career_modules_business_businessSkillTree.getNodeProgress(businessId, treeId, nodeId) or 0
  return 1.0 - (0.05 * level)
end

local function getMaxKitStorage(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId or not career_modules_business_businessSkillTree then
    return 0
  end
  local kitStorageLevel = career_modules_business_businessSkillTree.getNodeProgress(businessId, "quality-of-life", "kit-storage") or 0
  local kitStorageIILevel = career_modules_business_businessSkillTree.getNodeProgress(businessId, "quality-of-life", "kit-storage-ii") or 0
  return (kitStorageLevel * 2) + (kitStorageIILevel * 2)
end

local function hasKitStorageUnlocked(businessId)
  return getMaxKitStorage(businessId) > 0
end

local function getKitInstallLocksPath(businessId)
  if not career_career.isActive() then
    return nil
  end
  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  if not currentSavePath then
    return nil
  end
  return currentSavePath .. "/career/rls_career/businesses/" .. businessId .. "/kitInstallLocks.json"
end

M.getKitInstallLocksPath = getKitInstallLocksPath

local function loadKitInstallLocks(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return {}
  end
  if kitInstallLocks[businessId] then
    return kitInstallLocks[businessId]
  end
  if career_modules_business_tuningShop and career_modules_business_tuningShop.initializeBusinessData then
    career_modules_business_tuningShop.initializeBusinessData(businessId)
  end
  return kitInstallLocks[businessId] or {}
end

local function setKitInstallLocksFromData(businessId, locksData)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return
  end
  kitInstallLocks[businessId] = locksData or {}
end

local function getKitInstallLocksForSave(businessId)
  businessId = normalizeBusinessId(businessId)
  return kitInstallLocks[businessId] or {}
end

local function saveKitInstallLocks(businessId, currentSavePath)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return
  end
  if not currentSavePath then
    return
  end
  local filePath = currentSavePath .. "/career/rls_career/businesses/" .. businessId .. "/kitInstallLocks.json"
  local dirPath = string.match(filePath, "^(.*)/[^/]+$")
  if dirPath and not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end
  local data = { locks = kitInstallLocks[businessId] or {} }
  jsonWriteFile(filePath, data, true)
end

local function setKitInstallLock(businessId, vehicleId, unlockTime, kitName)
  businessId = normalizeBusinessId(businessId)
  if not businessId or not vehicleId then
    return
  end
  if not kitInstallLocks[businessId] then
    kitInstallLocks[businessId] = {}
  end
  kitInstallLocks[businessId][tostring(vehicleId)] = {
    unlockTime = unlockTime,
    kitName = kitName
  }
  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  if currentSavePath then
    saveKitInstallLocks(businessId, currentSavePath)
  end
end

local function clearKitInstallLock(businessId, vehicleId)
  businessId = normalizeBusinessId(businessId)
  if not businessId or not vehicleId then
    return
  end
  if not kitInstallLocks[businessId] then
    return
  end
  kitInstallLocks[businessId][tostring(vehicleId)] = nil
  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  if currentSavePath then
    saveKitInstallLocks(businessId, currentSavePath)
  end
end

local function getKitInstallLock(businessId, vehicleId)
  businessId = normalizeBusinessId(businessId)
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

local function processKitInstallLocks(businessId)
  businessId = normalizeBusinessId(businessId)
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
    local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
    if currentSavePath then
      saveKitInstallLocks(businessId, currentSavePath)
    end
    for _, unlocked in ipairs(unlockedVehicles) do
      if guihooks then
        guihooks.trigger('businessComputer:onKitInstallComplete', {
          businessId = businessId,
          vehicleId = unlocked.vehicleId,
          kitName = unlocked.kitName
        })
      end
    end
  end
end

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

        local minFuel = tank.maxEnergy * 0.05
        newFuelAmount = math.max(newFuelAmount, minFuel)

        core_vehicleBridge.executeAction(vehObj, 'setEnergyStorageEnergy', tank.name, newFuelAmount)
      end
    end
  end, 'energyStorage')
end

local function comparePartsTree(kitNode, currentNode, slotPath, differingParts)
  slotPath = slotPath or "/"
  differingParts = differingParts or {}

  if not kitNode then
    return differingParts
  end

  local kitPart = kitNode.chosenPartName or ""
  local currentPart = currentNode and currentNode.chosenPartName or ""

  if kitPart ~= "" and kitPart ~= currentPart then
    differingParts[slotPath] = {
      partName = kitPart,
      oldPartName = currentPart ~= "" and currentPart or nil
    }
  end

  if kitNode.children then
    for slotName, kitChild in pairs(kitNode.children) do
      local childPath = slotPath .. slotName .. "/"
      local currentChild = currentNode and currentNode.children and currentNode.children[slotName] or nil
      comparePartsTree(kitChild, currentChild, childPath, differingParts)
    end
  end

  return differingParts
end

local function getNodeFromSlotPath(tree, path)
  if not tree or not path then
    return nil
  end

  if path == "/" then
    return tree
  end

  local segments = {}
  for segment in string.gmatch(path, "[^/]+") do
    table.insert(segments, segment)
  end

  local currentNode = tree
  for _, segment in ipairs(segments) do
    if currentNode.children and currentNode.children[segment] then
      currentNode = currentNode.children[segment]
    else
      return nil
    end
  end

  return currentNode
end

local function mergeKitIntoConfig(kitNode, configNode, slotPath)
  slotPath = slotPath or "/"
  if not kitNode then
    return configNode
  end

  local kitPart = kitNode.chosenPartName
  local configPart = configNode and configNode.chosenPartName or ""

  if kitPart and kitPart ~= "" then
    if kitPart ~= configPart then
      if not configNode then
        configNode = {}
      end
      configNode.chosenPartName = kitPart
    end
  end

  if kitNode.children then
    if not configNode then
      configNode = {}
    end
    if not configNode.children then
      configNode.children = {}
    end

    for slotName, kitChild in pairs(kitNode.children) do
      local childPath = slotPath .. slotName .. "/"
      configNode.children[slotName] = mergeKitIntoConfig(kitChild, configNode.children[slotName], childPath)
    end
  end

  return configNode
end

local function kitToCartParts(businessId, vehicleId, kit, currentPartsTree)
  if not kit or not kit.parts or not currentPartsTree then
    return {}
  end

  local cartParts = {}
  local differingParts = {}

  for slotName, kitNode in pairs(kit.parts) do
    local slotPath = "/" .. slotName .. "/"
    local currentNode = nil
    if currentPartsTree.children and currentPartsTree.children[slotName] then
      currentNode = currentPartsTree.children[slotName]
    end
    comparePartsTree(kitNode, currentNode, slotPath, differingParts)
  end

  local vehObj = nil
  if career_modules_business_businessInventory and career_modules_business_businessInventory.getSpawnedVehicleId then
    local spawnedVehicleId = career_modules_business_businessInventory.getSpawnedVehicleId(businessId, vehicleId)
    if spawnedVehicleId then
      vehObj = getObjectByID(spawnedVehicleId)
    end
  end

  if not vehObj then
    return {}
  end

  local vehId = vehObj:getID()
  local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehId)
  if not vehicleData or not vehicleData.ioCtx then
    return {}
  end

  local availableParts = jbeamIO.getAvailableParts(vehicleData.ioCtx)
  local vehicleModel = vehObj:getJBeamFilename()
  local discountMultiplier = getPartSupplierDiscountMultiplier(businessId)

  for slotPath, partInfo in pairs(differingParts) do
    local jbeamData = jbeamIO.getPart(vehicleData.ioCtx, partInfo.partName)
    local partNiceName = partInfo.partName
    if jbeamData and jbeamData.information and jbeamData.information.description then
      local desc = jbeamData.information.description
      partNiceName = type(desc) == "table" and desc.description or desc or partInfo.partName
    else
      local partDescription = availableParts[partInfo.partName]
      if partDescription then
        if type(partDescription) == "string" then
          partNiceName = partDescription
        elseif partDescription.description then
          local desc = partDescription.description
          partNiceName = type(desc) == "table" and desc.description or desc or partInfo.partName
        end
      end
    end

    local partValue = 0
    if jbeamData then
      local baseValue = jbeamData.information and jbeamData.information.value or 100

      if career_modules_valueCalculator then
        local partForValueCalc = {
          name = partInfo.partName,
          value = baseValue,
          partCondition = {
            integrityValue = 1,
            odometer = 0,
            visualValue = 1
          },
          vehicleModel = vehicleModel
        }
        partValue = math.max(roundNear(career_modules_valueCalculator.getPartValue(partForValueCalc), 5) - 0.01, 0)
      else
        partValue = baseValue
      end

      partValue = partValue * discountMultiplier
    end

    local slotNiceName = ""
    local slotName = slotPath:match("/([^/]+)/$") or ""
    if jbeamData and jbeamData.slotInfoUi and jbeamData.slotInfoUi[slotName] then
      local slotInfo = jbeamData.slotInfoUi[slotName]
      local desc = slotInfo.description
      slotNiceName = type(desc) == "table" and desc.description or desc or slotName
    end

    if slotNiceName == "" then
      slotNiceName = slotName
    end

    table.insert(cartParts, {
      type = 'part',
      partName = partInfo.partName,
      partNiceName = partNiceName,
      slotPath = slotPath,
      slotNiceName = slotNiceName,
      price = partValue
    })
  end

  return cartParts
end

local function calculateKitCost(businessId, vehicleId, kit)
  if not businessId or not vehicleId or not kit or not kit.parts then
    return 0
  end

  local vehObj = nil
  if career_modules_business_businessInventory and career_modules_business_businessInventory.getSpawnedVehicleId then
    local spawnedVehicleId = career_modules_business_businessInventory.getSpawnedVehicleId(businessId, vehicleId)
    if spawnedVehicleId then
      vehObj = getObjectByID(spawnedVehicleId)
    end
  end

  if not vehObj then
    return 0
  end

  local vehId = vehObj:getID()
  local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehId)
  if not vehicleData or not vehicleData.ioCtx then
    return 0
  end

  local vehicleModel = vehObj:getJBeamFilename()
  local discountMultiplier = getPartSupplierDiscountMultiplier(businessId)
  local totalCost = 0

  -- Flatten all parts from the kit tree
  local allParts = {}
  for slotPath, partTree in pairs(kit.parts) do
    allParts = flattenKitTree(partTree, allParts)
  end

  for _, partName in ipairs(allParts) do
    local jbeamData = jbeamIO.getPart(vehicleData.ioCtx, partName)
    if jbeamData then
      local baseValue = jbeamData.information and jbeamData.information.value or 100
      local partPrice = baseValue

      if career_modules_valueCalculator then
        local partForValueCalc = {
          name = partName,
          value = baseValue,
          partCondition = {
            integrityValue = 1,
            odometer = 0,
            visualValue = 1
          },
          vehicleModel = vehicleModel
        }
        partPrice = math.max(roundNear(career_modules_valueCalculator.getPartValue(partForValueCalc), 5) - 0.01, 0)
      end

      partPrice = partPrice * discountMultiplier
      totalCost = totalCost + partPrice
    end
  end

  return totalCost
end

local function findSlotInTree(tree, slotName)
  if not tree or not tree.children then
    return nil
  end

  if tree.children[slotName] then
    return tree.children[slotName]
  end

  for _, childNode in pairs(tree.children) do
    local found = findSlotInTree(childNode, slotName)
    if found then
      return found
    end
  end

  return nil
end

local function getKitCostBreakdown(businessId, vehicleId, kitId)
  businessId = normalizeBusinessId(businessId)
  if not businessId or not vehicleId or not kitId then
    return nil
  end

  local kits = loadBusinessKits(businessId)
  local kit = nil
  for _, k in ipairs(kits) do
    if k.id == kitId then
      kit = k
      break
    end
  end

  if not kit or not kit.parts then
    return nil
  end

  local isPersonal = isPersonalVehicleId(vehicleId)
  local vehicle = nil
  local vehObj = nil
  local vehicleMileage = 0

  if isPersonal then
    vehicle = getPersonalVehicleData(vehicleId, businessId)
    if not vehicle then
      return nil
    end
    local spawnedId = getSpawnedIdFromPersonalVehicleId(vehicleId)
    if spawnedId then
      vehObj = be:getObjectByID(spawnedId)
    end
    if vehicle.inventoryId and career_modules_inventory then
      local invVehicles = career_modules_inventory.getVehicles()
      if invVehicles and invVehicles[vehicle.inventoryId] then
        vehicleMileage = tonumber(invVehicles[vehicle.inventoryId].mileage or 0)
      end
    end
  else
    vehicle = career_modules_business_businessInventory.getVehicleById(businessId, vehicleId)
    if not vehicle then
      return nil
    end
    if career_modules_business_businessInventory and career_modules_business_businessInventory.getSpawnedVehicleId then
      local spawnedVehicleId = career_modules_business_businessInventory.getSpawnedVehicleId(businessId, vehicleId)
      if spawnedVehicleId then
        vehObj = getObjectByID(spawnedVehicleId)
      end
    end
    vehicleMileage = tonumber(vehicle.mileage or 0)
  end

  if not vehObj then
    return nil
  end

  local vehId = vehObj:getID()
  local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehId)
  if not vehicleData or not vehicleData.ioCtx then
    return nil
  end

  local vehicleModel = vehObj:getJBeamFilename()
  local discountMultiplier = getPartSupplierDiscountMultiplier(businessId)

  local currentPartsTree = vehicleData.config and vehicleData.config.partsTree or
                           (vehicle.config and vehicle.config.partsTree or nil)
  local differingParts = {}

  for slotName, kitNode in pairs(kit.parts) do
    local slotPath = "/" .. slotName .. "/"
    local currentNode = findSlotInTree(currentPartsTree, slotName)
    comparePartsTree(kitNode, currentNode, slotPath, differingParts)
  end

  local newPartsCost = 0
  local oldPartsValue = 0

  for slotPath, partInfo in pairs(differingParts) do
    local jbeamData = jbeamIO.getPart(vehicleData.ioCtx, partInfo.partName)
    if jbeamData then
      local baseValue = jbeamData.information and jbeamData.information.value or 100
      local newPartPrice = baseValue

      if career_modules_valueCalculator then
        local partForValueCalc = {
          name = partInfo.partName,
          value = baseValue,
          partCondition = {
            integrityValue = 1,
            odometer = 0,
            visualValue = 1
          },
          vehicleModel = vehicleModel
        }
        newPartPrice = math.max(roundNear(career_modules_valueCalculator.getPartValue(partForValueCalc), 5) - 0.01, 0)
      end

      newPartPrice = newPartPrice * discountMultiplier
      newPartsCost = newPartsCost + newPartPrice
    end

    if partInfo.oldPartName then
      local oldJbeamData = jbeamIO.getPart(vehicleData.ioCtx, partInfo.oldPartName)
      if oldJbeamData then
        local oldBaseValue = oldJbeamData.information and oldJbeamData.information.value or 100
        local oldPartPrice = oldBaseValue

        if career_modules_valueCalculator then
          local partForValueCalc = {
            name = partInfo.oldPartName,
            value = oldBaseValue,
            partCondition = {
              integrityValue = 1,
              odometer = vehicleMileage,
              visualValue = 1
            },
            vehicleModel = vehicleModel
          }
          oldPartPrice = math.max(roundNear(career_modules_valueCalculator.getPartValue(partForValueCalc), 5) - 0.01, 0)
        end

        oldPartsValue = oldPartsValue + oldPartPrice
      end
    end
  end

  local tradeInCredit = oldPartsValue * 0.9
  local totalCost = math.max(newPartsCost - tradeInCredit, 0)

  local changedPartsCount = 0
  for _ in pairs(differingParts) do
    changedPartsCount = changedPartsCount + 1
  end

  -- Base install time is 25 seconds per part, reduced by 5 seconds per level of quick-installs upgrade
  local baseTimePerPart = 25
  local quickInstallsLevel = 0
  if career_modules_business_businessSkillTree and career_modules_business_businessSkillTree.getNodeProgress then
    quickInstallsLevel = career_modules_business_businessSkillTree.getNodeProgress(businessId, "quality-of-life", "quick-installs") or 0
  end
  local timePerPart = math.max(5, baseTimePerPart - (quickInstallsLevel * 5)) -- Minimum 5 seconds per part
  local installTimeSeconds = changedPartsCount * timePerPart

  return {
    newPartsCost = newPartsCost,
    oldPartsValue = oldPartsValue,
    tradeInCredit = tradeInCredit,
    totalCost = totalCost,
    changedPartsCount = changedPartsCount,
    installTimeSeconds = installTimeSeconds
  }
end

local function applyKit(businessId, vehicleId, kitId)
  businessId = normalizeBusinessId(businessId)
  if not businessId or not vehicleId or not kitId then
    return {
      success = false,
      error = "Missing parameters"
    }
  end

  local kits = loadBusinessKits(businessId)

  local kit = nil
  for _, k in ipairs(kits) do
    if k.id == kitId then
      kit = k
      break
    end
  end

  if not kit then
    return {
      success = false,
      error = "Kit not found"
    }
  end

  local isPersonal = isPersonalVehicleId(vehicleId)
  local vehicle = nil
  local modelKey = nil
  local currentConfig = nil
  local vehObj = nil
  local inventoryId = nil

  if isPersonal then
    vehicle = getPersonalVehicleData(vehicleId, businessId)
    if not vehicle then
      return {
        success = false,
        error = "Personal vehicle not found"
      }
    end

    local spawnedId = getSpawnedIdFromPersonalVehicleId(vehicleId)
    if not spawnedId then
      return {
        success = false,
        error = "Invalid personal vehicle ID"
      }
    end

    vehObj = be:getObjectByID(spawnedId)
    if not vehObj then
      return {
        success = false,
        error = "Personal vehicle not spawned"
      }
    end

    local vehicleData = extensions.core_vehicle_manager.getVehicleData(spawnedId)
    if not vehicleData or not vehicleData.config then
      return {
        success = false,
        error = "Personal vehicle configuration not found"
      }
    end

    modelKey = vehicleData.config.model or vehObj:getJBeamFilename()
    currentConfig = deepcopy(vehicleData.config)
    inventoryId = vehicle.inventoryId
  else
    vehicle = career_modules_business_businessInventory.getVehicleById(businessId, vehicleId)
    if not vehicle or not vehicle.vehicleConfig then
      return {
        success = false,
        error = "Vehicle configuration not found"
      }
    end

    local spawnedVehicleId = nil
    if career_modules_business_businessInventory and career_modules_business_businessInventory.getSpawnedVehicleId then
      spawnedVehicleId = career_modules_business_businessInventory.getSpawnedVehicleId(businessId, vehicleId)
      if spawnedVehicleId then
        vehObj = getObjectByID(spawnedVehicleId)
      end
    end

    if vehObj then
      local vehicleData = extensions.core_vehicle_manager.getVehicleData(spawnedVehicleId)
      if vehicleData and vehicleData.config then
        modelKey = vehicleData.config.model or vehObj:getJBeamFilename()
        currentConfig = deepcopy(vehicleData.config)
      else
        modelKey = vehicle.vehicleConfig.model_key or vehicle.model_key
        currentConfig = deepcopy(vehicle.config)
      end
    else
      modelKey = vehicle.vehicleConfig.model_key or vehicle.model_key
      currentConfig = deepcopy(vehicle.config)
    end
  end

  if not modelKey then
    return {
      success = false,
      error = "Vehicle model key not found"
    }
  end

  if not currentConfig or not currentConfig.partsTree then
    return {
      success = false,
      error = "Vehicle configuration tree not found"
    }
  end

  if not vehObj then
    return {
      success = false,
      error = "Vehicle not found or not spawned"
    }
  end

  local costBreakdown = getKitCostBreakdown(businessId, vehicleId, kitId) or {
    newPartsCost = 0,
    oldPartsValue = 0,
    tradeInCredit = 0,
    totalCost = 0,
    changedPartsCount = 0,
    installTimeSeconds = 0
  }
  local kitCost = costBreakdown.totalCost
  local installTimeSeconds = costBreakdown.installTimeSeconds or 0

  local businessAccount = nil
  local accountId = nil
  if career_modules_bank then
    businessAccount = career_modules_bank.getBusinessAccount("tuningShop", businessId)
    if businessAccount then
      accountId = businessAccount.id
      local balance = career_modules_bank.getAccountBalance(accountId)
      if balance < kitCost then
        return {
          success = false,
          error = "Insufficient funds",
          cost = kitCost,
          costBreakdown = costBreakdown,
          balance = balance
        }
      end
    end
  end

  if not currentConfig.partsTree.children then
    currentConfig.partsTree.children = {}
  end

  local function findAndMergeSlot(node, slotName, kitNode, path)
    path = path or "/"
    if not node or not node.children then
      return false
    end

    if node.children[slotName] then
      local slotPath = path .. slotName .. "/"
      node.children[slotName] = mergeKitIntoConfig(kitNode, node.children[slotName], slotPath)
      return true
    end

    for childSlotName, childNode in pairs(node.children) do
      local childPath = path .. childSlotName .. "/"
      if findAndMergeSlot(childNode, slotName, kitNode, childPath) then
        return true
      end
    end

    return false
  end

  for slotName, kitNode in pairs(kit.parts or {}) do
    findAndMergeSlot(currentConfig.partsTree, slotName, kitNode, "/")
  end

  if kit.tuning and next(kit.tuning) then
    if not currentConfig.vars then
      currentConfig.vars = {}
    end
    for k, v in pairs(kit.tuning) do
      currentConfig.vars[k] = v
    end
  end

  local callbackId = tostring(os.time()) .. "_" .. tostring(math.random(10000, 99999))

  pendingKitCallbacks[callbackId] = {
    businessId = businessId,
    vehicleId = vehicleId,
    kitId = kitId,
    kit = kit,
    accountId = accountId,
    kitCost = kitCost,
    costBreakdown = costBreakdown,
    inventoryId = inventoryId,
    installTimeSeconds = installTimeSeconds
  }

  storeFuelLevels(vehObj, function(storedFuelLevels)
    local vehId = vehObj:getID()
    local additionalVehicleData = {
      spawnWithEngineRunning = false
    }
    core_vehicle_manager.queueAdditionalVehicleData(additionalVehicleData, vehId)

    local spawnOptions = {}
    spawnOptions.config = currentConfig
    spawnOptions.keepOtherVehRotation = true

    core_vehicles.replaceVehicle(modelKey, spawnOptions, vehObj)

    core_vehicleBridge.requestValue(vehObj, function()
      restoreFuelLevels(vehObj, storedFuelLevels)

      vehObj:queueLuaCommand([[
        local configData = serialize(v.config)
        obj:queueGameEngineLua("career_modules_business_tuningShopKits.onVehicleConfigReceived(']] .. callbackId .. [[', " .. configData .. ")")
      ]])
    end, 'ping')
  end)

  return {
    success = true,
    cost = kitCost,
    costBreakdown = costBreakdown
  }
end

local function onVehicleConfigReceived(callbackId, config)
  local callbackData = pendingKitCallbacks[callbackId]
  if not callbackData then
    return
  end

  pendingKitCallbacks[callbackId] = nil

  local businessId = callbackData.businessId
  local vehicleId = callbackData.vehicleId
  local kit = callbackData.kit
  local accountId = callbackData.accountId
  local kitCost = callbackData.kitCost
  local kitId = callbackData.kitId
  local inventoryId = callbackData.inventoryId
  local installTimeSeconds = callbackData.installTimeSeconds or 0

  if not config then
    return
  end

  local actualConfig = config

  if kit.tuning and next(kit.tuning) then
    if not actualConfig.vars then
      actualConfig.vars = {}
    end
    for k, v in pairs(kit.tuning) do
      actualConfig.vars[k] = v
    end

    if career_modules_business_businessComputer and career_modules_business_businessComputer.applyVehicleTuning then
      career_modules_business_businessComputer.applyVehicleTuning(businessId, vehicleId, kit.tuning, nil)
    end
  end

  local partList = {}
  local function extractParts(tree, path)
    path = path or "/"
    if tree.chosenPartName and tree.chosenPartName ~= "" then
      partList[path] = tree.chosenPartName
    end
    if tree.children then
      for slotName, child in pairs(tree.children) do
        local childPath = path .. slotName .. "/"
        extractParts(child, childPath)
      end
    end
  end
  extractParts(actualConfig.partsTree or {})

  local kitPartPaths = {}
  if kit.parts then
    for slotName, kitNode in pairs(kit.parts) do
      local function extractKitPartPaths(node, path)
        path = path or "/"
        if node.chosenPartName and node.chosenPartName ~= "" then
          kitPartPaths[path .. node.chosenPartName] = true
        end
        if node.children then
          for childSlot, childNode in pairs(node.children) do
            extractKitPartPaths(childNode, path .. childSlot .. "/")
          end
        end
      end
      extractKitPartPaths(kitNode, "/" .. slotName .. "/")
    end
  end

  local vehObj = nil
  if inventoryId then
    local spawnedId = getSpawnedIdFromPersonalVehicleId(vehicleId)
    if spawnedId then
      vehObj = be:getObjectByID(spawnedId)
    end
  elseif career_modules_business_businessInventory and career_modules_business_businessInventory.getSpawnedVehicleId then
    local spawnedVehicleId = career_modules_business_businessInventory.getSpawnedVehicleId(businessId, vehicleId)
    if spawnedVehicleId then
      vehObj = getObjectByID(spawnedVehicleId)
    end
  end

  if vehObj and kit.parts then
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

  if inventoryId then
    if career_modules_inventory then
      local vehicles = career_modules_inventory.getVehicles()
      if vehicles and vehicles[inventoryId] then
        vehicles[inventoryId].config = actualConfig
        vehicles[inventoryId].config.vars = actualConfig.vars
        if career_modules_inventory.setVehicleDirty then
          career_modules_inventory.setVehicleDirty(inventoryId)
        end
      end
    end
    career_saveSystem.saveCurrent({inventoryId})
  else
    if career_modules_business_businessInventory then
      career_modules_business_businessInventory.updateVehicle(businessId, vehicleId, {
        config = actualConfig,
        vars = actualConfig.vars,
        partList = partList
      })

      if career_modules_business_businessInventory.getPulledOutVehicles then
        local pulledVehicles = career_modules_business_businessInventory.getPulledOutVehicles(businessId) or {}
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
      else
        local pulledOutVehicle = career_modules_business_businessInventory.getPulledOutVehicle(businessId)
        if pulledOutVehicle and tostring(pulledOutVehicle.vehicleId) == tostring(vehicleId) then
          pulledOutVehicle.config = actualConfig
          pulledOutVehicle.vars = actualConfig.vars
          pulledOutVehicle.partList = partList
        end
      end
    end
    career_saveSystem.saveCurrent()
  end

  if career_modules_bank and accountId and kitCost > 0 then
    career_modules_bank.removeFunds(accountId, kitCost, "Kit Application", "Applied kit: " .. kit.name)
  end

  if career_modules_business_businessPartCustomization and career_modules_business_businessPartCustomization.clearPreviewVehicle then
    career_modules_business_businessPartCustomization.clearPreviewVehicle(businessId)
  end

  if installTimeSeconds > 0 then
    local unlockTime = os.time() + installTimeSeconds
    setKitInstallLock(businessId, vehicleId, unlockTime, kit.name)

    if career_modules_business_businessComputer and career_modules_business_businessComputer.putAwayVehicle then
      career_modules_business_businessComputer.putAwayVehicle(businessId, vehicleId)
    end
  end

  if guihooks then
    guihooks.trigger('businessComputer:onKitApplied', {
      businessId = businessId,
      vehicleId = vehicleId,
      kitId = kitId,
      kitName = kit.name,
      cost = kitCost,
      installTimeSeconds = installTimeSeconds
    })
  end
end

local function getKitDetails(businessId, kitId)
  businessId = normalizeBusinessId(businessId)
  if not businessId or not kitId then
    return nil
  end

  local kits = loadBusinessKits(businessId)
  for _, kit in ipairs(kits) do
    if kit.id == kitId then
      return kit
    end
  end
  return nil
end

local function onSaveCurrentSaveSlot(currentSavePath)
  for businessId, _ in pairs(businessKits) do
    saveBusinessKits(businessId, currentSavePath)
  end
  for businessId, _ in pairs(kitInstallLocks) do
    saveKitInstallLocks(businessId, currentSavePath)
  end
end

M.loadBusinessKits = loadBusinessKits
M.getBusinessKits = loadBusinessKits
M.getKitDetails = getKitDetails
M.getKitCostBreakdown = getKitCostBreakdown
M.countKitParts = countKitParts
M.createKit = createKit
M.deleteKit = deleteKit
M.applyKit = applyKit
M.onVehicleConfigReceived = onVehicleConfigReceived
M.getMaxKitStorage = getMaxKitStorage
M.hasKitStorageUnlocked = hasKitStorageUnlocked
M.isVehicleKitLocked = isVehicleKitLocked
M.getKitInstallTimeRemaining = getKitInstallTimeRemaining
M.getKitInstallLock = getKitInstallLock
M.processKitInstallLocks = processKitInstallLocks
M.setKitInstallLocksFromData = setKitInstallLocksFromData
M.getKitInstallLocksForSave = getKitInstallLocksForSave

M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot

return M
