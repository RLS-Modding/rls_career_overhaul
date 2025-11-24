local M = {}

local jbeamIO = require('jbeam/io')
local json = require('json')

local businessKits = {}
local pendingKitCallbacks = {}

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
  log('I', 'tuningShopKits',
    'createKitFromConfig called with: businessId=' .. tostring(businessId) .. ', jobId=' .. tostring(jobId) ..
      ', kitName=' .. tostring(kitName))
  if not businessId or not jobId or not kitName or not config then
    log('E', 'tuningShopKits', 'Missing data in createKitFromConfig')
    return false
  end

  local tuningShop = career_modules_business_tuningShop
  local job = tuningShop and tuningShop.getJobById(businessId, jobId)

  if not job then
    log('E', 'tuningShopKits', 'Job not found: ' .. tostring(jobId))
    return false
  end

  local kitParts = {}
  if config.partsTree then
    kitParts = extractKitParts(config.partsTree)
  else
    log('W', 'tuningShopKits', 'No partsTree in config, cannot save kit')
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

  if not businessKits[businessId] then
    businessKits[businessId] = {}
  end

  table.insert(businessKits[businessId], kit)
  log('I', 'tuningShopKits', 'Kit added to memory. Saving to file...')

  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  if currentSavePath then
    saveBusinessKits(businessId, currentSavePath)
    log('I', 'tuningShopKits', 'Kit saved to file.')
  else
    log('W', 'tuningShopKits', 'No current save path, kit not saved to file.')
  end

  if guihooks then
    guihooks.trigger('businessComputer:onKitsUpdated', {
      businessId = businessId
    })
  end

  return true
end

local function createKit(businessId, jobId, kitName, spawnedVehicleId)
  log('I', 'tuningShopKits',
    'createKit called with: businessId=' .. tostring(businessId) .. ', jobId=' .. tostring(jobId) .. ', kitName=' ..
      tostring(kitName))
  businessId = normalizeBusinessId(businessId)
  if not businessId or not jobId or not kitName then
    log("E", "tuningShopKits", "createKit: Missing or invalid arguments.")
    return false
  end

  local tuningShop = career_modules_business_tuningShop

  -- Try to get vehicle from helper first
  local vehicle = nil
  if tuningShop and tuningShop.getVehicleByJobId then
    vehicle = tuningShop.getVehicleByJobId(businessId, jobId)
  end

  if not vehicle then
    log('E', 'tuningShopKits', 'Vehicle not found for job ' .. tostring(jobId))
    return false
  end

  if not vehicle.config then
    log('E', 'tuningShopKits', 'Vehicle config not found for job ' .. tostring(jobId))
    return false
  end

  log('I', 'tuningShopKits', 'Vehicle and config found. Proceeding to createKitFromConfig.')
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
    log("D", "tuningShopKits", "[MERGE] kitNode is nil at path: " .. slotPath)
    return configNode
  end

  local kitPart = kitNode.chosenPartName
  local configPart = configNode and configNode.chosenPartName or ""

  log("D", "tuningShopKits", "[MERGE] Path: " .. slotPath .. " | Kit part: " .. tostring(kitPart) .. " | Config part: " .. tostring(configPart))

  if kitPart and kitPart ~= "" then
    if kitPart ~= configPart then
      log("D", "tuningShopKits", "[MERGE] CHANGING part at " .. slotPath .. ": " .. tostring(configPart) .. " -> " .. tostring(kitPart))
      if not configNode then
        configNode = {}
      end
      configNode.chosenPartName = kitPart
    else
      log("D", "tuningShopKits", "[MERGE] SAME part at " .. slotPath .. ", no change needed")
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

local function applyKit(businessId, vehicleId, kitId)
  log("I", "tuningShopKits", "========== APPLY KIT START ==========")
  log("I", "tuningShopKits", "businessId: " .. tostring(businessId) .. ", vehicleId: " .. tostring(vehicleId) .. ", kitId: " .. tostring(kitId))

  businessId = normalizeBusinessId(businessId)
  if not businessId or not vehicleId or not kitId then
    log("E", "tuningShopKits", "Missing parameters")
    return {
      success = false,
      error = "Missing parameters"
    }
  end

  local kits = loadBusinessKits(businessId)
  log("I", "tuningShopKits", "Loaded " .. #kits .. " kits for business: " .. tostring(businessId))

  local kit = nil
  for _, k in ipairs(kits) do
    if k.id == kitId then
      kit = k
      break
    end
  end

  if not kit then
    log("E", "tuningShopKits", "Kit not found: " .. tostring(kitId))
    return {
      success = false,
      error = "Kit not found"
    }
  end

  log("I", "tuningShopKits", "Found kit: " .. tostring(kit.name))
  log("I", "tuningShopKits", "Kit model_key: " .. tostring(kit.model_key))
  log("I", "tuningShopKits", "Kit parts count: " .. tostring(kit.parts and tableSize(kit.parts) or 0))

  if kit.parts then
    for slotName, kitNode in pairs(kit.parts) do
      log("I", "tuningShopKits", "  Kit slot: " .. slotName .. " -> part: " .. tostring(kitNode.chosenPartName))
    end
  end

  local vehicle = career_modules_business_businessInventory.getVehicleById(businessId, vehicleId)
  if not vehicle or not vehicle.vehicleConfig then
    log("E", "tuningShopKits", "Vehicle configuration not found")
    return {
      success = false,
      error = "Vehicle configuration not found"
    }
  end

  local modelKey = vehicle.vehicleConfig.model_key or vehicle.model_key
  log("I", "tuningShopKits", "Vehicle modelKey: " .. tostring(modelKey))

  if not modelKey then
    log("E", "tuningShopKits", "Vehicle model key not found")
    return {
      success = false,
      error = "Vehicle model key not found"
    }
  end

  local currentConfig = deepcopy(vehicle.config)
  if not currentConfig or not currentConfig.partsTree then
    log("E", "tuningShopKits", "Vehicle configuration tree not found")
    log("E", "tuningShopKits", "vehicle.config exists: " .. tostring(vehicle.config ~= nil))
    log("E", "tuningShopKits", "currentConfig exists: " .. tostring(currentConfig ~= nil))
    if currentConfig then
      log("E", "tuningShopKits", "currentConfig.partsTree exists: " .. tostring(currentConfig.partsTree ~= nil))
    end
    return {
      success = false,
      error = "Vehicle configuration tree not found"
    }
  end

  log("I", "tuningShopKits", "Current config partsTree root: " .. tostring(currentConfig.partsTree.chosenPartName))
  if currentConfig.partsTree.children then
    log("I", "tuningShopKits", "Current config has " .. tostring(tableSize(currentConfig.partsTree.children)) .. " top-level slots")
    for slotName, node in pairs(currentConfig.partsTree.children) do
      log("I", "tuningShopKits", "  Current slot: " .. slotName .. " -> part: " .. tostring(node.chosenPartName))
    end
  else
    log("W", "tuningShopKits", "Current config has NO children!")
  end

  local vehObj = nil
  if career_modules_business_businessInventory and career_modules_business_businessInventory.getSpawnedVehicleId then
    local spawnedVehicleId = career_modules_business_businessInventory.getSpawnedVehicleId(businessId, vehicleId)
    log("I", "tuningShopKits", "Spawned vehicle ID: " .. tostring(spawnedVehicleId))
    if spawnedVehicleId then
      vehObj = getObjectByID(spawnedVehicleId)
    end
  end

  if not vehObj then
    log("E", "tuningShopKits", "Vehicle not found or not spawned")
    return {
      success = false,
      error = "Vehicle not found or not spawned"
    }
  end

  log("I", "tuningShopKits", "Vehicle object found, ID: " .. tostring(vehObj:getID()))

  -- local kitCost = calculateKitCost(businessId, vehicleId, kit)
  local kitCost = 0
  log("I", "tuningShopKits", "Kit cost: " .. tostring(kitCost))

  local businessAccount = nil
  local accountId = nil
  if career_modules_bank then
    businessAccount = career_modules_bank.getBusinessAccount("tuningShop", businessId)
    if businessAccount then
      accountId = businessAccount.id
      local balance = career_modules_bank.getAccountBalance(accountId)
      log("I", "tuningShopKits", "Account balance: " .. tostring(balance))
      if balance < kitCost then
        log("E", "tuningShopKits", "Insufficient funds")
        return {
          success = false,
          error = "Insufficient funds",
          cost = kitCost,
          balance = balance
        }
      end
    end
  end

  if not currentConfig.partsTree.children then
    currentConfig.partsTree.children = {}
    log("W", "tuningShopKits", "Created empty children table for partsTree")
  end

  local function findAndMergeSlot(node, slotName, kitNode, path)
    path = path or "/"
    if not node or not node.children then
      return false
    end

    if node.children[slotName] then
      local slotPath = path .. slotName .. "/"
      log("I", "tuningShopKits", "Found slot '" .. slotName .. "' at path: " .. slotPath)
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

  log("I", "tuningShopKits", "========== MERGING KIT PARTS ==========")
  for slotName, kitNode in pairs(kit.parts or {}) do
    log("I", "tuningShopKits", "Processing kit slot: " .. slotName)
    local found = findAndMergeSlot(currentConfig.partsTree, slotName, kitNode, "/")
    if not found then
      log("W", "tuningShopKits", "Slot '" .. slotName .. "' not found anywhere in config tree!")
    end
  end

  log("I", "tuningShopKits", "========== CONFIG AFTER MERGE (top-level) ==========")
  if currentConfig.partsTree.children then
    for slotName, node in pairs(currentConfig.partsTree.children) do
      log("I", "tuningShopKits", "  Root slot: " .. slotName .. " -> part: " .. tostring(node.chosenPartName))
    end
  end

  local function logKitSlots(node, path)
    path = path or "/"
    if not node or not node.children then return end
    for slotName, childNode in pairs(node.children) do
      if kit.parts[slotName] then
        log("I", "tuningShopKits", "  Kit slot found: " .. path .. slotName .. " -> part: " .. tostring(childNode.chosenPartName))
      end
      logKitSlots(childNode, path .. slotName .. "/")
    end
  end
  log("I", "tuningShopKits", "========== KIT SLOTS IN CONFIG ==========")
  logKitSlots(currentConfig.partsTree, "/")

  if kit.tuning and next(kit.tuning) then
    log("I", "tuningShopKits", "Applying tuning vars...")
    if not currentConfig.vars then
      currentConfig.vars = {}
    end
    for k, v in pairs(kit.tuning) do
      currentConfig.vars[k] = v
      log("I", "tuningShopKits", "  Tuning var: " .. tostring(k) .. " = " .. tostring(v))
    end
  end

  local callbackId = tostring(os.time()) .. "_" .. tostring(math.random(10000, 99999))
  log("I", "tuningShopKits", "Callback ID: " .. callbackId)

  pendingKitCallbacks[callbackId] = {
    businessId = businessId,
    vehicleId = vehicleId,
    kitId = kitId,
    kit = kit,
    accountId = accountId,
    kitCost = kitCost
  }

  log("I", "tuningShopKits", "========== REPLACING VEHICLE ==========")
  storeFuelLevels(vehObj, function(storedFuelLevels)
    log("I", "tuningShopKits", "Fuel levels stored, proceeding with replace...")
    local vehId = vehObj:getID()
    local additionalVehicleData = {
      spawnWithEngineRunning = false
    }
    core_vehicle_manager.queueAdditionalVehicleData(additionalVehicleData, vehId)

    local spawnOptions = {}
    spawnOptions.config = currentConfig
    spawnOptions.keepOtherVehRotation = true

    log("I", "tuningShopKits", "Calling replaceVehicle with modelKey: " .. tostring(modelKey))
    core_vehicles.replaceVehicle(modelKey, spawnOptions, vehObj)

    core_vehicleBridge.requestValue(vehObj, function()
      log("I", "tuningShopKits", "Vehicle ping received, restoring fuel and fetching config...")
      restoreFuelLevels(vehObj, storedFuelLevels)

      log("I", "tuningShopKits", "Queuing Lua command to get v.config...")
      vehObj:queueLuaCommand([[
        local configData = serialize(v.config)
        obj:queueGameEngineLua("career_modules_business_tuningShopKits.onVehicleConfigReceived(']] .. callbackId .. [[', " .. configData .. ")")
      ]])
    end, 'ping')
  end)

  log("I", "tuningShopKits", "applyKit returning success (async operations pending)")
  return {
    success = true,
    cost = kitCost
  }
end

local function onVehicleConfigReceived(callbackId, config)
  log("I", "tuningShopKits", "========== CONFIG RECEIVED FROM VEHICLE ==========")
  log("I", "tuningShopKits", "Callback ID: " .. tostring(callbackId))

  local callbackData = pendingKitCallbacks[callbackId]
  if not callbackData then
    log("E", "tuningShopKits", "No pending callback for id: " .. tostring(callbackId))
    return
  end

  pendingKitCallbacks[callbackId] = nil

  local businessId = callbackData.businessId
  local vehicleId = callbackData.vehicleId
  local kit = callbackData.kit
  local accountId = callbackData.accountId
  local kitCost = callbackData.kitCost
  local kitId = callbackData.kitId

  log("I", "tuningShopKits", "businessId: " .. tostring(businessId) .. ", vehicleId: " .. tostring(vehicleId))

  if not config then
    log("E", "tuningShopKits", "Config is nil!")
    return
  end

  log("I", "tuningShopKits", "Config received successfully")

  local actualConfig = config

  if actualConfig.partsTree then
    log("I", "tuningShopKits", "Received partsTree root: " .. tostring(actualConfig.partsTree.chosenPartName))
    if actualConfig.partsTree.children then
      log("I", "tuningShopKits", "Received config has " .. tostring(tableSize(actualConfig.partsTree.children)) .. " top-level slots")
      for slotName, node in pairs(actualConfig.partsTree.children) do
        log("I", "tuningShopKits", "  Received slot: " .. slotName .. " -> part: " .. tostring(node.chosenPartName))
      end
    else
      log("W", "tuningShopKits", "Received config has NO children!")
    end
  else
    log("E", "tuningShopKits", "Received config has NO partsTree!")
  end

  if kit.tuning and next(kit.tuning) then
    log("I", "tuningShopKits", "Applying tuning vars to received config...")
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

  log("I", "tuningShopKits", "Built partList with " .. tostring(tableSize(partList)) .. " entries")

  log("I", "tuningShopKits", "========== SAVING TO INVENTORY ==========")
  if career_modules_business_businessInventory then
    log("I", "tuningShopKits", "Calling updateVehicle...")
    career_modules_business_businessInventory.updateVehicle(businessId, vehicleId, {
      config = actualConfig,
      vars = actualConfig.vars,
      partList = partList
    })
    log("I", "tuningShopKits", "updateVehicle called")

    if career_modules_business_businessInventory.getPulledOutVehicles then
      local pulledVehicles = career_modules_business_businessInventory.getPulledOutVehicles(businessId) or {}
      log("I", "tuningShopKits", "Found " .. #pulledVehicles .. " pulled out vehicles")
      local targetId = tonumber(vehicleId) or vehicleId
      for _, pulled in ipairs(pulledVehicles) do
        local pulledId = tonumber(pulled.vehicleId) or pulled.vehicleId
        if pulledId == targetId then
          log("I", "tuningShopKits", "Updating pulled out vehicle reference...")
          pulled.config = actualConfig
          pulled.vars = actualConfig.vars
          pulled.partList = partList
          break
        end
      end
    else
      local pulledOutVehicle = career_modules_business_businessInventory.getPulledOutVehicle(businessId)
      if pulledOutVehicle and (tonumber(pulledOutVehicle.vehicleId) == tonumber(vehicleId) or pulledOutVehicle.vehicleId == vehicleId) then
        log("I", "tuningShopKits", "Updating single pulled out vehicle reference...")
        pulledOutVehicle.config = actualConfig
        pulledOutVehicle.vars = actualConfig.vars
        pulledOutVehicle.partList = partList
      end
    end
  end

  if career_modules_bank and accountId and kitCost > 0 then
    log("I", "tuningShopKits", "Charging account " .. tostring(accountId) .. " for " .. tostring(kitCost))
    career_modules_bank.removeFunds(accountId, kitCost, "Kit Application", "Applied kit: " .. kit.name)
  end

  log("I", "tuningShopKits", "========== KIT APPLICATION COMPLETE ==========")
  log("I", "tuningShopKits", "Kit applied successfully: " .. kit.name)

  if guihooks then
    guihooks.trigger('businessComputer:onKitApplied', {
      businessId = businessId,
      vehicleId = vehicleId,
      kitId = kitId,
      kitName = kit.name,
      cost = kitCost
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
end

M.loadBusinessKits = loadBusinessKits
M.getBusinessKits = loadBusinessKits
M.getKitDetails = getKitDetails
M.createKit = createKit
M.deleteKit = deleteKit
M.applyKit = applyKit
M.onVehicleConfigReceived = onVehicleConfigReceived

M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot

return M
