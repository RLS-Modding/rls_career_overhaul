local M = {}

M.dependencies = {'career_career', 'career_saveSystem', 'freeroam_facilities', 'core_vehicles', 'core_jobsystem'}

local jbeamIO = require('jbeam/io')
local jbeamSlotSystem = require('jbeam/slotSystem')

local vehicleInfoCache = nil
local partsTreeCache = {}
local businessContexts = {}

local function normalizeJobIdValue(jobId)
  if jobId == nil then
    return "nojob"
  end
  return tostring(jobId)
end

local function getPartsCacheBucket(businessId, createIfMissing)
  if not businessId then
    return nil
  end
  local bucket = partsTreeCache[businessId]
  if not bucket and createIfMissing then
    bucket = {}
    partsTreeCache[businessId] = bucket
  end
  return bucket
end

local function getCachedPartsTree(businessId, jobId)
  local bucket = getPartsCacheBucket(businessId, false)
  if not bucket then
    return nil
  end
  return bucket[normalizeJobIdValue(jobId)]
end

local function setCachedPartsTree(businessId, jobId, data)
  if not businessId then
    return
  end
  local bucket = getPartsCacheBucket(businessId, true)
  bucket[normalizeJobIdValue(jobId)] = data
end

local function clearPartsTreeCacheForJob(businessId, jobId)
  local bucket = getPartsCacheBucket(businessId, false)
  if not bucket then
    return
  end
  bucket[normalizeJobIdValue(jobId)] = nil
  if not next(bucket) then
    partsTreeCache[businessId] = nil
  end
end

local function setBusinessContext(businessType, businessId)
  if not businessType or not businessId then
    return
  end
  businessContexts[businessId] = businessType
end

local function getBusinessModule(businessType)
  if not businessType then
    return nil
  end
  return _G["career_modules_business_" .. tostring(businessType)]
end

local function resolveBusinessModule(businessId)
  if not businessId then
    return nil, nil
  end
  local businessType = businessContexts[businessId]
  if not businessType then
    log('E', 'businessComputer', 'No business context for businessId=' .. tostring(businessId))
    return nil, nil
  end
  local module = getBusinessModule(businessType)
  if not module then
    log('E', 'businessComputer', 'Missing business module career_modules_business_' .. tostring(businessType))
    return nil, businessType
  end
  return module, businessType
end

local function invalidateVehicleInfoCache()
  vehicleInfoCache = nil
end

local function clearVehicleDataCaches()
  partsTreeCache = {}
  if career_modules_business_businessVehicleTuning then
    career_modules_business_businessVehicleTuning.clearTuningDataCache()
  end
end

local function clearCachesForJob(businessId, jobId)
  if not businessId then
    return
  end
  clearPartsTreeCacheForJob(businessId, jobId)
  if career_modules_business_businessVehicleTuning and
    career_modules_business_businessVehicleTuning.clearTuningDataCacheForJob then
    career_modules_business_businessVehicleTuning.clearTuningDataCacheForJob(businessId, jobId)
  end
end

local function getDamageThreshold(businessId)
  local _, businessType = resolveBusinessModule(businessId)
  if businessType then
    local businessObj = career_modules_business_businessManager and career_modules_business_businessManager.getBusinessObject(businessType)
    if businessObj and businessObj.getDamageThreshold then
      return businessObj.getDamageThreshold(businessId)
    end
  end
  return 1500
end

local function isPersonalVehicleId(vehicleId)
  if not vehicleId then
    return false
  end
  local str = tostring(vehicleId)
  return str:sub(1, 9) == "personal_"
end

local function getSpawnedIdFromPersonalVehicleId(vehicleId)
  if not vehicleId then
    return nil
  end
  local str = tostring(vehicleId)
  if str:sub(1, 9) ~= "personal_" then
    return nil
  end
  local spawnedIdStr = str:sub(10)
  return tonumber(spawnedIdStr)
end

local function getInventoryIdFromPersonalVehicleId(vehicleId, businessId)
  if not isPersonalVehicleId(vehicleId) then
    return nil
  end
  if businessId then
    local _, businessType = resolveBusinessModule(businessId)
    if businessType then
      local businessObj = career_modules_business_businessManager and career_modules_business_businessManager.getBusinessObject(businessType)
      if businessObj and businessObj.getActivePersonalVehicle then
        local activePersonal = businessObj.getActivePersonalVehicle(businessId)
        if activePersonal and tostring(activePersonal.vehicleId) == tostring(vehicleId) and activePersonal.inventoryId then
          return activePersonal.inventoryId
        end
      end
    end
  else
    local allBusinessObjects = career_modules_business_businessManager and career_modules_business_businessManager.getAllBusinessObjects and career_modules_business_businessManager.getAllBusinessObjects() or {}
    for businessType, businessObj in pairs(allBusinessObjects) do
      if businessObj.getActivePersonalVehicle then
        local purchased = career_modules_business_businessManager.getPurchasedBusinesses(businessType) or {}
        for bId, _ in pairs(purchased) do
          local activePersonal = businessObj.getActivePersonalVehicle(bId)
          if activePersonal and tostring(activePersonal.vehicleId) == tostring(vehicleId) and activePersonal.inventoryId then
            return activePersonal.inventoryId
          end
        end
      end
    end
  end
  return nil
end

local function getBusinessVehicleObject(businessId, vehicleId)
  if not businessId or not vehicleId then
    return nil
  end

  if isPersonalVehicleId(vehicleId) then
    local spawnedId = getSpawnedIdFromPersonalVehicleId(vehicleId)
    if spawnedId then
      return getObjectByID(spawnedId)
    end
    return nil
  end

  if career_modules_business_businessInventory then
    local vehId = career_modules_business_businessInventory.getSpawnedVehicleId(businessId, vehicleId)
    if vehId then
      return getObjectByID(vehId)
    end
  end

  return nil
end

local function getVehicleDamageByVehId(vehId)
  if not vehId or not map or not map.objects then
    return 0
  end

  local objectData = map.objects[vehId]
  if not objectData then
    return 0
  end

  return objectData.damage or 0
end

local function normalizeVehicleIdValue(vehicleId)
  if vehicleId == nil then
    return nil
  end
  local num = tonumber(vehicleId)
  if num then
    return num
  end
  return vehicleId
end

local function getPulledOutVehiclesList(businessId)
  if not career_modules_business_businessInventory then
    return {}
  end
  if career_modules_business_businessInventory.getPulledOutVehicles then
    return career_modules_business_businessInventory.getPulledOutVehicles(businessId) or {}
  end
  local vehicle = career_modules_business_businessInventory.getPulledOutVehicle(businessId)
  if vehicle then
    return {vehicle}
  end
  return {}
end

local function getActiveBusinessVehicle(businessId)
  local _, businessType = resolveBusinessModule(businessId)
  if businessType then
    local businessObj = career_modules_business_businessManager and career_modules_business_businessManager.getBusinessObject(businessType)
    if businessObj and businessObj.getActivePersonalVehicle then
      local personalVehicle = businessObj.getActivePersonalVehicle(businessId)
      if personalVehicle then
        return personalVehicle
      end
    end
  end

  if not career_modules_business_businessInventory then
    return nil
  end
  if career_modules_business_businessInventory.getActiveVehicle then
    return career_modules_business_businessInventory.getActiveVehicle(businessId)
  end
  return career_modules_business_businessInventory.getPulledOutVehicle(businessId)
end

local function isDamageLocked(businessId, vehicleId)
  local threshold = getDamageThreshold(businessId)
  local lockInfo = {
    locked = false,
    damage = 0,
    threshold = threshold
  }

  if not businessId or not vehicleId then
    return lockInfo
  end

  local vehObj = getBusinessVehicleObject(businessId, vehicleId)
  if not vehObj then
    return lockInfo
  end

  local vehId = vehObj:getID()
  if not vehId then
    return lockInfo
  end

  local damage = getVehicleDamageByVehId(vehId)
  lockInfo.damage = damage
  lockInfo.locked = damage >= threshold

  return lockInfo
end

local function getDamageLockedVehicleInfo(businessId, vehicleId)
  if not businessId then
    return nil
  end

  if vehicleId then
    local lockInfo = isDamageLocked(businessId, vehicleId)
    if lockInfo.locked then
      lockInfo.vehicleId = vehicleId
      return lockInfo
    end
    return nil
  end

  for _, vehicle in ipairs(getPulledOutVehiclesList(businessId)) do
    local vId = normalizeVehicleIdValue(vehicle.vehicleId)
    local lockInfo = isDamageLocked(businessId, vId)
    if lockInfo.locked then
      lockInfo.vehicleId = vId
      return lockInfo
    end
  end

  return nil
end

local function notifyDamageLocked(lockInfo)
  if not lockInfo or not lockInfo.locked then
    return
  end

  local message = string.format("Vehicle damage (%.0f) exceeds the %d limit. Abandon the job to continue.",
    lockInfo.damage or 0, lockInfo.threshold or 1500)
  if ui_message then
    ui_message(message, 5, "Business Computer", "error")
  else
    log('W', 'businessComputer', message)
  end
end

local function shouldPreventVehicleOperation(businessId, vehicleId)
  if not businessId or not vehicleId then
    return false
  end

  local lockInfo = isDamageLocked(businessId, vehicleId)
  if lockInfo.locked then
    notifyDamageLocked(lockInfo)
    return true
  end

  return false
end

local function normalizeConfigKey(configKey)
  if not configKey then
    return nil
  end
  if configKey:find("/") then
    local parts = {}
    for part in configKey:gmatch("[^/]+") do
      table.insert(parts, part)
    end
    if #parts > 0 then
      local filename = parts[#parts]
      local name, ext = filename:match("^(.+)%.(.+)$")
      return name or filename
    end
  else
    local name, ext = configKey:match("^(.+)%.(.+)$")
    return name or configKey
  end
  return configKey
end

local function getVehicleInfo(modelKey, configKey)
  if not modelKey or not configKey then
    return nil
  end

  local normalizedConfigKey = normalizeConfigKey(configKey)

  if util_configListGenerator and util_configListGenerator.getEligibleVehicles then
    if not vehicleInfoCache then
      vehicleInfoCache = util_configListGenerator.getEligibleVehicles(false, false) or {}
    end

    for _, vehicleInfo in ipairs(vehicleInfoCache) do
      if vehicleInfo.model_key == modelKey then
        local vehicleKey = normalizeConfigKey(vehicleInfo.key)
        if vehicleInfo.key == configKey or vehicleKey == normalizedConfigKey or vehicleInfo.key == normalizedConfigKey then
          return vehicleInfo
        end
      end
    end
  end

  if core_vehicles and core_vehicles.getConfig then
    local model = core_vehicles.getModel(modelKey)
    if model and not tableIsEmpty(model) then
      local configName = normalizedConfigKey
      local configInfo = core_vehicles.getConfig(modelKey, configName)
      if configInfo then
        return {
          model_key = modelKey,
          key = configKey,
          Name = configInfo.Name or modelKey,
          Brand = configInfo.Brand or "",
          Years = configInfo.Years or {
            min = 1990,
            max = 2025
          },
          preview = configInfo.preview
        }
      end
    end
  end

  return nil
end

local function formatJobForUI(job, businessId)
  if not job then
    return nil
  end

  local vehicleConfig = job.vehicleConfig or {}
  local modelKey = vehicleConfig.model_key or "unknown"
  local configKey = vehicleConfig.key or "unknown"

  local vehicleInfo = getVehicleInfo(modelKey, configKey)
  local vehicleName = modelKey
  local vehicleYear = "Unknown"
  local vehicleType = "Unknown"
  local vehicleImage = "/ui/images/appDefault.png"

  if vehicleInfo then
    -- Build nice name from Brand and Name (same pattern as vehicleShopping.lua line 1255)
    if vehicleInfo.Brand and vehicleInfo.Name then
      vehicleName = vehicleInfo.Brand .. " " .. vehicleInfo.Name
    elseif vehicleInfo.Name then
      vehicleName = vehicleInfo.Name
    end

    -- Get year if available (handle Years with min/max like vehicleShopping.lua line 852-854)
    local years = vehicleInfo.Years or (vehicleInfo.aggregates and vehicleInfo.aggregates.Years)
    if years then
      if type(years) == "table" and years.min and years.max then
        -- Use min year (or could use a random year between min and max)
        vehicleYear = tostring(years.min)
      elseif type(years) == "number" then
        vehicleYear = tostring(years)
      end
    elseif vehicleInfo.Year then
      vehicleYear = tostring(vehicleInfo.Year)
    end

    -- Get type/body style if available
    if vehicleInfo["Body Style"] then
      vehicleType = vehicleInfo["Body Style"]
    elseif vehicleInfo.Type then
      vehicleType = vehicleInfo.Type
    end

    -- Get preview image if available
    if vehicleInfo.preview then
      vehicleImage = vehicleInfo.preview
    end
  end

  local timeUnit = "s"
  if job.raceType == "track" or job.raceType == "trackAlt" then
    timeUnit = "min"
  end

  local goalTimeFormatted = ""
  local goalTimeSeconds = job.targetTime or 0
  local decimalPlaces = job.decimalPlaces or 0
  if goalTimeSeconds >= 60 then
    local minutes = math.floor(goalTimeSeconds / 60)
    local seconds = math.floor(goalTimeSeconds % 60 + 0.5)
    if seconds >= 1 then
      goalTimeFormatted = string.format("%d min %d s", minutes, seconds)
    else
      goalTimeFormatted = string.format("%d min", minutes)
    end
  else
    if decimalPlaces > 0 then
      goalTimeFormatted = string.format("%." .. decimalPlaces .. "f s", goalTimeSeconds)
    else
      goalTimeFormatted = string.format("%d s", math.floor(goalTimeSeconds + 0.5))
    end
  end

  local goal = goalTimeFormatted .. " " .. (job.raceLabel or "")

  local baselineTime = job.baseTime or 0
  local currentTime = job.currentTime or job.baseTime or 0
  local goalTime = job.targetTime or 0

  if job.raceLabel and businessId and job.jobId then
    local bestTime = career_modules_business_businessHelpers.getBestLeaderboardTime(businessId, job.jobId, job.raceType,
      job.raceLabel)
    if bestTime then
      currentTime = bestTime
    end
  end

  local penalty = math.floor((job.reward or 20000) * 0.5)

  return {
    id = tostring(job.jobId),
    jobId = job.jobId,
    vehicleName = vehicleName,
    vehicleYear = vehicleYear or "Unknown",
    vehicleType = vehicleType,
    vehicleImage = vehicleImage,
    goal = goal,
    reward = job.reward or 20000,
    status = job.status or "new",
    baselineTime = tonumber(string.format("%.1f", baselineTime)),
    currentTime = tonumber(string.format("%.1f", currentTime)),
    goalTime = tonumber(string.format("%.1f", goalTime)),
    timeUnit = timeUnit,
    raceType = job.raceType,
    raceLabel = job.raceLabel,
    decimalPlaces = job.decimalPlaces or 0,
    deadline = job.deadline or "7 days",
    priority = job.priority or "medium",
    penalty = penalty
  }
end

local function formatVehicleForUI(vehicle, businessId)
  if not vehicle then
    return nil
  end

  local vehicleConfig = vehicle.vehicleConfig or {}
  local modelKey = vehicleConfig.model_key or vehicle.model_key or "unknown"
  local configKey = vehicleConfig.key or vehicle.config_key or "unknown"

  local vehicleInfo = getVehicleInfo(modelKey, configKey)
  local vehicleName = modelKey
  local vehicleYear = "Unknown"
  local vehicleType = "Unknown"
  local vehicleImage = "/ui/images/appDefault.png"

  if vehicleInfo then
    -- Build nice name from Brand and Name (same pattern as vehicleShopping.lua line 1255)
    if vehicleInfo.Brand and vehicleInfo.Name then
      vehicleName = vehicleInfo.Brand .. " " .. vehicleInfo.Name
    elseif vehicleInfo.Name then
      vehicleName = vehicleInfo.Name
    end

    -- Get year if available (handle Years with min/max like vehicleShopping.lua line 852-854)
    local years = vehicleInfo.Years or (vehicleInfo.aggregates and vehicleInfo.aggregates.Years)
    if years then
      if type(years) == "table" and years.min and years.max then
        -- Use min year (or could use a random year between min and max)
        vehicleYear = tostring(years.min)
      elseif type(years) == "number" then
        vehicleYear = tostring(years)
      end
    elseif vehicleInfo.Year then
      vehicleYear = tostring(vehicleInfo.Year)
    end

    -- Get type/body style if available
    if vehicleInfo["Body Style"] then
      vehicleType = vehicleInfo["Body Style"]
    elseif vehicleInfo.Type then
      vehicleType = vehicleInfo.Type
    end

    -- Get preview image if available
    if vehicleInfo.preview then
      vehicleImage = vehicleInfo.preview
    end
  end

  local kitInstallLocked = false
  local kitInstallTimeRemaining = 0
  local kitInstallKitName = nil
  if businessId then
    local _, businessType = resolveBusinessModule(businessId)
    local businessObj = businessType and career_modules_business_businessManager and career_modules_business_businessManager.getBusinessObject(businessType)
    if businessObj then
      if businessObj.isVehicleKitLocked then
        kitInstallLocked = businessObj.isVehicleKitLocked(businessId, vehicle.vehicleId) or false
      end
      if businessObj.getKitInstallTimeRemaining then
        kitInstallTimeRemaining = businessObj.getKitInstallTimeRemaining(businessId, vehicle.vehicleId) or 0
      end
      if businessObj.getKitInstallLock then
        local lockInfo = businessObj.getKitInstallLock(businessId, vehicle.vehicleId)
        if lockInfo then
          kitInstallKitName = lockInfo.kitName
        end
      end
    end
  end

  return {
    id = tostring(vehicle.vehicleId),
    vehicleId = vehicle.vehicleId,
    vehicleName = vehicleName,
    vehicleYear = vehicleYear,
    vehicleType = vehicleType,
    vehicleImage = vehicleImage,
    jobId = vehicle.jobId,
    storedTime = vehicle.storedTime,
    kitInstallLocked = kitInstallLocked,
    kitInstallTimeRemaining = kitInstallTimeRemaining,
    kitInstallKitName = kitInstallKitName
  }
end

local function getBusinessComputerUIData(businessType, businessId)
  if not businessType or not businessId then
    return nil
  end

  setBusinessContext(businessType, businessId)

  local module = getBusinessModule(businessType)
  if not module or not module.getUIData then
    log('E', 'businessComputer', 'Business module missing getUIData for type ' .. tostring(businessType))
    return nil
  end

  local ok, result = pcall(module.getUIData, businessId)
  if not ok then
    log('E', 'businessComputer', 'Error getting UI data for type ' .. tostring(businessType) .. ': ' .. tostring(result))
    return nil
  end

  return result
end

local function getManagerData(businessType, businessId)
  if not businessType or not businessId then
    return nil
  end

  setBusinessContext(businessType, businessId)

  local module = getBusinessModule(businessType)
  if not module or not module.getManagerData then
    return nil
  end

  local ok, result = pcall(module.getManagerData, businessId)
  if not ok then
    log('E', 'businessComputer',
      'Error getting manager data for type ' .. tostring(businessType) .. ': ' .. tostring(result))
    return nil
  end

  return result
end

local function requestPartInventory(businessId)
  if not businessId then
    if guihooks then
      guihooks.trigger('businessComputer:onPartInventoryData', {
        success = false,
        error = "Missing businessId"
      })
    end
    return
  end

  if not career_modules_business_businessPartInventory then
    if guihooks then
      guihooks.trigger('businessComputer:onPartInventoryData', {
        success = false,
        error = "Inventory module not available",
        businessId = businessId
      })
    end
    return
  end

  local data = career_modules_business_businessPartInventory.getUIData(businessId) or {}
  data.businessId = businessId
  data.success = true

  if guihooks then
    guihooks.trigger('businessComputer:onPartInventoryData', data)
  end
end

local function sellPart(businessId, partId)
  if not businessId or not partId then
    return false
  end

  if not career_modules_business_businessPartInventory then
    return false
  end

  local businessType = businessContexts[businessId]
  if not businessType then
    return false
  end

  local success, price = career_modules_business_businessPartInventory.sellPart(partId)
  if not success or price <= 0 then
    return false
  end

  if career_modules_bank then
    local account = career_modules_bank.getBusinessAccount(businessType, businessId)
    if account then
      career_modules_bank.rewardToAccount({
        money = {
          amount = price
        }
      }, account.id, "Sold Parts", "Sold part")
      if ui_message then
        ui_message(string.format("Sold parts $%s", tostring(math.floor(price))), 3, "Parts Inventory", "info")
      end
    end
  end

  career_modules_business_businessPartInventory.saveInventory()
  requestPartInventory(businessId)

  return true
end

local function sellAllParts(businessId)
  if not businessId then
    return false
  end

  if not career_modules_business_businessPartInventory then
    return false
  end

  local businessType = businessContexts[businessId]
  if not businessType then
    return false
  end

  local success, totalPrice = career_modules_business_businessPartInventory.sellAllParts()
  if not success or totalPrice <= 0 then
    return false
  end

  if career_modules_bank then
    local account = career_modules_bank.getBusinessAccount(businessType, businessId)
    if account then
      career_modules_bank.rewardToAccount({
        money = {
          amount = totalPrice
        }
      }, account.id, "Sold Parts", "Sold all parts")
      if ui_message then
        ui_message(string.format("Sold parts $%s", tostring(math.floor(totalPrice))), 3, "Parts Inventory", "info")
      end
    end
  end

  career_modules_business_businessPartInventory.saveInventory()
  requestPartInventory(businessId)

  return true
end

local function sellPartsByVehicle(businessId, vehicleNiceName)
  if not businessId or not vehicleNiceName then
    return false
  end

  if not career_modules_business_businessPartInventory then
    return false
  end

  local businessType = businessContexts[businessId]
  if not businessType then
    return false
  end

  local vehicleModel = nil
  local inventory = career_modules_business_businessPartInventory.getInventory()
  for _, part in pairs(inventory) do
    if part and part.vehicleModel then
      local modelData = core_vehicles.getModel(part.vehicleModel)
      if modelData and modelData.model then
        local brand = modelData.model.Brand or ""
        local name = modelData.model.Name
        local niceName = (brand .. " " .. name):match("^%s*(.-)%s*$")
        if niceName == vehicleNiceName then
          vehicleModel = part.vehicleModel
          break
        end
      end
    end
  end

  if not vehicleModel then
    return false
  end

  local success, totalPrice = career_modules_business_businessPartInventory.sellPartsByVehicle(vehicleModel)
  if not success or totalPrice <= 0 then
    return false
  end

  if career_modules_bank then
    local account = career_modules_bank.getBusinessAccount(businessType, businessId)
    if account then
      career_modules_bank.rewardToAccount({
        money = {
          amount = totalPrice
        }
      }, account.id, "Sold Parts", "Sold " .. vehicleNiceName .. " parts")
      if ui_message then
        ui_message(string.format("Sold parts $%s", tostring(math.floor(totalPrice))), 3, "Parts Inventory", "info")
      end
    end
  end

  career_modules_business_businessPartInventory.saveInventory()
  requestPartInventory(businessId)

  return true
end

local function acceptJob(businessId, jobId)
  local module, businessType = resolveBusinessModule(businessId)
  if module and module.acceptJob then
    local success = module.acceptJob(businessId, jobId)
    if success and guihooks then
      local jobsData = M.getJobsOnly(businessId)
      local vehiclesData = M.getVehiclesOnly(businessId)
      guihooks.trigger('businessComputer:onJobAccepted', {
        businessType = businessType,
        businessId = businessId,
        jobId = jobId,
        activeJobs = jobsData.activeJobs,
        newJobs = jobsData.newJobs,
        maxActiveJobs = jobsData.maxActiveJobs,
        vehicles = vehiclesData.vehicles
      })
    end
    return success
  end
  return false
end

local function declineJob(businessId, jobId)
  local module, businessType = resolveBusinessModule(businessId)
  if module and module.declineJob then
    local success = module.declineJob(businessId, jobId)
    if success and guihooks then
      local jobsData = M.getJobsOnly(businessId)
      guihooks.trigger('businessComputer:onJobDeclined', {
        businessType = businessType,
        businessId = businessId,
        jobId = jobId,
        newJobs = jobsData.newJobs
      })
    end
    return success
  end
  return false
end

local function abandonJob(businessId, jobId)
  local module, businessType = resolveBusinessModule(businessId)
  if module and module.abandonJob then
    local success = module.abandonJob(businessId, jobId)
    if success and guihooks then
      local jobsData = M.getJobsOnly(businessId)
      local vehiclesData = M.getVehiclesOnly(businessId)
      guihooks.trigger('businessComputer:onJobAbandoned', {
        businessType = businessType,
        businessId = businessId,
        jobId = jobId,
        activeJobs = jobsData.activeJobs,
        vehicles = vehiclesData.vehicles,
        pulledOutVehicles = vehiclesData.pulledOutVehicles
      })
    end
    return success
  end
  return false
end

local function assignTechToJob(businessId, techId, jobId)
  if not businessId or not techId or not jobId then
    return false
  end

  local businessType = businessContexts[businessId]
  if not businessType then
    return false
  end

  local module = getBusinessModule(businessType)
  if module and module.assignJobToTech then
    local ok, result = pcall(module.assignJobToTech, businessId, techId, jobId)
    if not ok then
      log('E', 'businessComputer', 'assignTechToJob failed: ' .. tostring(result))
      return false
    end
    if result and guihooks then
      local jobsData = M.getJobsOnly(businessId)
      local techsData = M.getTechsOnly(businessId)
      guihooks.trigger('businessComputer:onTechAssigned', {
        businessType = businessType,
        businessId = businessId,
        techId = techId,
        jobId = jobId,
        activeJobs = jobsData.activeJobs,
        techs = techsData.techs
      })
    end
    return result
  end

  return false
end

local function renameTech(businessId, techId, newName)
  if not businessId or not techId then
    return false
  end

  local businessType = businessContexts[businessId]
  if not businessType then
    return false
  end

  local module = getBusinessModule(businessType)
  if module and module.updateTechName then
    local ok, result = pcall(module.updateTechName, businessId, techId, newName)
    if not ok then
      log('E', 'businessComputer', 'renameTech failed: ' .. tostring(result))
      return false
    end
    return result
  end

  return false
end

local function pullOutVehicle(businessId, vehicleId)
  if not businessId or not vehicleId then
    return false
  end

  local businessType = businessContexts[businessId]
  if not businessType then
    log('E', 'businessComputer',
      'Cannot pull out vehicle, unknown business type for businessId=' .. tostring(businessId))
    return {
      success = false,
      errorCode = "unknownBusiness"
    }
  end

  local module = getBusinessModule(businessType)
  local maxPulledOut = 1
  if module and module.getMaxPulledOutVehicles then
    maxPulledOut = tonumber(module.getMaxPulledOutVehicles(businessId)) or 1
  end
  if maxPulledOut < 1 then
    maxPulledOut = 1
  end

  local lockInfo = getDamageLockedVehicleInfo(businessId)
  if lockInfo then
    notifyDamageLocked(lockInfo)
    return {
      success = false,
      errorCode = "damageLocked"
    }
  end

  local normalizedVehicleId = normalizeVehicleIdValue(vehicleId)
  local pulledOutVehiclesList = getPulledOutVehiclesList(businessId)
  for _, current in ipairs(pulledOutVehiclesList) do
    local currentId = normalizeVehicleIdValue(current.vehicleId)
    if currentId == normalizedVehicleId then
      if career_modules_business_businessInventory.setActiveVehicle then
        career_modules_business_businessInventory.setActiveVehicle(businessId, normalizedVehicleId)
      end
      return true
    end
  end

  if module and module.isJobLockedByTech and career_modules_business_businessInventory then
    local vehicles = career_modules_business_businessInventory.getBusinessVehicles(businessId) or {}
    for _, stored in ipairs(vehicles) do
      local storedId = normalizeVehicleIdValue(stored.vehicleId)
      if storedId == normalizedVehicleId then
        local jobId = tonumber(stored.jobId) or stored.jobId
        if jobId and module.isJobLockedByTech(businessId, jobId) then
          return {
            success = false,
            errorCode = "jobLocked"
          }
        end
        break
      end
    end
  end

  local businessObj = businessType and career_modules_business_businessManager and career_modules_business_businessManager.getBusinessObject(businessType)
  if businessObj and businessObj.isVehicleKitLocked then
    if businessObj.isVehicleKitLocked(businessId, normalizedVehicleId) then
      local remaining = businessObj.getKitInstallTimeRemaining and businessObj.getKitInstallTimeRemaining(businessId, normalizedVehicleId) or 0
      return {
        success = false,
        errorCode = "kitInstallLocked",
        timeRemaining = remaining
      }
    end
  end

  if #pulledOutVehiclesList >= maxPulledOut then
    local message = string.format("All %d lift slots are in use. Put away a vehicle first.", maxPulledOut)
    return {
      success = false,
      errorCode = "maxVehicles",
      message = message
    }
  end

  local result = career_modules_business_businessInventory.pullOutVehicle(businessType, businessId, vehicleId)
  if result and career_modules_business_businessInventory.setActiveVehicle then
    career_modules_business_businessInventory.setActiveVehicle(businessId, normalizedVehicleId)
  end
  if result and guihooks then
    local vehiclesData = M.getVehiclesOnly(businessId)
    guihooks.trigger('businessComputer:onVehiclePulledOut', {
      businessType = businessType,
      businessId = businessId,
      vehicleId = normalizedVehicleId,
      vehicles = vehiclesData.vehicles,
      pulledOutVehicles = vehiclesData.pulledOutVehicles,
      maxPulledOutVehicles = vehiclesData.maxPulledOutVehicles
    })
  end
  return result
end

local function putAwayVehicle(businessId, vehicleId)
  if not businessId then
    return false
  end

  local businessType = businessContexts[businessId]
  local targetVehicleId = vehicleId
  if not targetVehicleId then
    local activeVehicle = getActiveBusinessVehicle(businessId)
    targetVehicleId = activeVehicle and activeVehicle.vehicleId
  end

  if targetVehicleId then
    local normalizedVehicleId = normalizeVehicleIdValue(targetVehicleId)
    local lockInfo = getDamageLockedVehicleInfo(businessId, normalizedVehicleId)
    if lockInfo then
      notifyDamageLocked(lockInfo)
      return {
        success = false,
        errorCode = "damageLocked"
      }
    end
    local result = career_modules_business_businessInventory.putAwayVehicle(businessId, normalizedVehicleId)
    if result and guihooks then
      local vehiclesData = M.getVehiclesOnly(businessId)
      guihooks.trigger('businessComputer:onVehiclePutAway', {
        businessType = businessType,
        businessId = businessId,
        vehicleId = normalizedVehicleId,
        vehicles = vehiclesData.vehicles,
        pulledOutVehicles = vehiclesData.pulledOutVehicles,
        maxPulledOutVehicles = vehiclesData.maxPulledOutVehicles
      })
    end
    return result
  end

  local lockInfo = getDamageLockedVehicleInfo(businessId)
  if lockInfo then
    notifyDamageLocked(lockInfo)
    return {
      success = false,
      errorCode = "damageLocked"
    }
  end

  local result = career_modules_business_businessInventory.putAwayVehicle(businessId)
  if result and guihooks then
    local vehiclesData = M.getVehiclesOnly(businessId)
    guihooks.trigger('businessComputer:onVehiclePutAway', {
      businessType = businessType,
      businessId = businessId,
      vehicles = vehiclesData.vehicles,
      pulledOutVehicles = vehiclesData.pulledOutVehicles,
      maxPulledOutVehicles = vehiclesData.maxPulledOutVehicles
    })
  end
  return result
end

local function getActiveJobs(businessId)
  local module = resolveBusinessModule(businessId)
  if module and module.getActiveJobs then
    return module.getActiveJobs(businessId)
  end
  return {}
end

local function getNewJobs(businessId)
  local module = resolveBusinessModule(businessId)
  if module and module.getNewJobs then
    return module.getNewJobs(businessId)
  end
  return {}
end

local function getBrandSelection(businessId)
  local module = resolveBusinessModule(businessId)
  if module and module.getBrandSelection then
    return module.getBrandSelection(businessId)
  end
  return nil
end

local function setBrandSelection(businessId, brand)
  local module = resolveBusinessModule(businessId)
  if module and module.setBrandSelection then
    return module.setBrandSelection(businessId, brand)
  end
  return false
end

local function getRaceSelection(businessId)
  local module = resolveBusinessModule(businessId)
  if module and module.getRaceSelection then
    return module.getRaceSelection(businessId)
  end
  return nil
end

local function setRaceSelection(businessId, raceType)
  local module = resolveBusinessModule(businessId)
  if module and module.setRaceSelection then
    return module.setRaceSelection(businessId, raceType)
  end
  return false
end

local function getAvailableBrands()
  local allBusinessObjects = career_modules_business_businessManager and career_modules_business_businessManager.getAllBusinessObjects and career_modules_business_businessManager.getAllBusinessObjects() or {}
  for _, businessObj in pairs(allBusinessObjects) do
    if businessObj.getAvailableBrands then
      return businessObj.getAvailableBrands()
    end
  end
  return {}
end

local function getAvailableRaceTypes()
  local allBusinessObjects = career_modules_business_businessManager and career_modules_business_businessManager.getAllBusinessObjects and career_modules_business_businessManager.getAllBusinessObjects() or {}
  for _, businessObj in pairs(allBusinessObjects) do
    if businessObj.getAvailableRaceTypes then
      return businessObj.getAvailableRaceTypes()
    end
  end
  return {}
end

local function requestAvailableBrands()
  local allBusinessObjects = career_modules_business_businessManager and career_modules_business_businessManager.getAllBusinessObjects and career_modules_business_businessManager.getAllBusinessObjects() or {}
  for _, businessObj in pairs(allBusinessObjects) do
    if businessObj.requestAvailableBrands then
      businessObj.requestAvailableBrands()
      return
    end
  end
end

local function requestAvailableRaceTypes(businessId)
  if not businessId then
    return
  end
  local allBusinessObjects = career_modules_business_businessManager and career_modules_business_businessManager.getAllBusinessObjects and career_modules_business_businessManager.getAllBusinessObjects() or {}
  for _, businessObj in pairs(allBusinessObjects) do
    if businessObj.requestAvailableRaceTypes then
      businessObj.requestAvailableRaceTypes(businessId)
      return
    end
  end
end

local function getPartSupplierDiscountMultiplier(businessId)
  if not businessId then
    return 1.0
  end

  local _, businessType = resolveBusinessModule(businessId)
  if businessType then
    local businessObj = career_modules_business_businessManager and career_modules_business_businessManager.getBusinessObject(businessType)
    if businessObj and businessObj.getPartSupplierDiscountMultiplier then
      return businessObj.getPartSupplierDiscountMultiplier(businessId)
    end
  end

  return 1.0
end

local function buildOwnedPartsLookup(inventoryParts, vehicleModel)
  if not inventoryParts then
    return nil
  end
  local lookup = {}
  for _, part in ipairs(inventoryParts) do
    if part and part.name then
      if not part.vehicleModel or part.vehicleModel == vehicleModel then
        local mileage = part.mileage
        if not mileage and part.partCondition and part.partCondition.odometer then
          mileage = part.partCondition.odometer / 1609.344
        end
        local variant = {
          partId = part.partId,
          name = part.name,
          partCondition = part.partCondition,
          finalValue = part.finalValue,
          value = part.value,
          mileage = mileage
        }
        lookup[part.name] = lookup[part.name] or {}
        table.insert(lookup[part.name], variant)
      end
    end
  end
  return lookup
end

local function findRemovedPartsFromCart(businessId, vehicleId, cartParts)
  if not businessId or not vehicleId or not cartParts then
    return {}
  end

  local vehicle = career_modules_business_businessInventory.getVehicleById(businessId, vehicleId)
  if not vehicle then
    return {}
  end

  local vehicleModel = vehicle.vehicleConfig and vehicle.vehicleConfig.model_key or vehicle.model_key
  
  local originalPartList = vehicle.partList or {}
  local partConditions = vehicle.partConditions or {}
  
  -- Only fall back to vehicle object's config if stored data is empty
  if next(originalPartList) == nil then
    local vehObj = getBusinessVehicleObject(businessId, vehicleId)
    if vehObj then
      local vehId = vehObj:getID()
      local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehId)
      if vehicleData and vehicleData.config and vehicleData.config.partsTree then
        local function extractParts(tree, path)
          path = path or "/"
          if tree.chosenPartName and tree.path then
            originalPartList[tree.path] = tree.chosenPartName
          end
          if tree.children then
            for slotName, child in pairs(tree.children) do
              local childPath = path .. slotName .. "/"
              extractParts(child, childPath)
            end
          end
        end
        extractParts(vehicleData.config.partsTree)
        
        if vehicleData.partConditions then
          partConditions = vehicleData.partConditions
        end
      end
    end
  end

  local cartPartsBySlot = {}
  for _, part in ipairs(cartParts) do
    if part.slotPath and part.partName and part.partName ~= "" then
      cartPartsBySlot[part.slotPath] = part.partName
    elseif part.slotPath and part.emptyPlaceholder then
      cartPartsBySlot[part.slotPath] = ""
    end
  end

  local removedParts = {}
  for slotPath, originalPartName in pairs(originalPartList) do
    if originalPartName and originalPartName ~= "" then
      local cartPartName = cartPartsBySlot[slotPath]
      if cartPartName ~= nil and cartPartName ~= originalPartName then
        local partCondition = partConditions[slotPath .. originalPartName]
        if not partCondition then
          partCondition = {
            integrityValue = 1,
            visualValue = 1,
            odometer = 0
          }
        end

        local partData = {
          name = originalPartName,
          containingSlot = slotPath,
          slot = slotPath:match("/([^/]+)/$") or slotPath:match("/([^/]+)$") or "",
          vehicleModel = vehicleModel,
          partCondition = partCondition
        }

        if career_modules_valueCalculator then
          partData.value = career_modules_valueCalculator.getPartValue(partData) or 0
        else
          partData.value = 100
        end

        table.insert(removedParts, partData)
      end
    end
  end

  return removedParts
end

local function formatPartsTreeForUI(node, slotName, slotInfo, availableParts, slotsNiceName, partsNiceName, pathPrefix,
  parentSlotName, ioCtx, businessId, vehicleData, vehicleModel, ownedPartsByName)
  if not node then
    return {}
  end

  local result = {}
  local currentPath = node.path or pathPrefix or "/"

  local isRootNode = (currentPath == "/" or currentPath == "" or slotName == "")

  local slotNiceName = node.slotNiceName or ""
  if not slotNiceName and slotInfo then
    slotNiceName = type(slotInfo.description) == "table" and slotInfo.description.description or slotInfo.description or
                     slotName or ""
  elseif not slotNiceName and slotName and slotsNiceName[slotName] then
    slotNiceName = type(slotsNiceName[slotName]) == "table" and slotsNiceName[slotName].description or
                     slotsNiceName[slotName] or slotName
  elseif not slotNiceName and slotName then
    slotNiceName = slotName
  end

  local partNiceName = node.chosenPartNiceName or ""
  if node.chosenPartName and availableParts[node.chosenPartName] then
    local partInfo = availableParts[node.chosenPartName]
    local desc = partInfo.description
    partNiceName = type(desc) == "table" and desc.description or desc or node.chosenPartName
    partsNiceName[node.chosenPartName] = partNiceName
  elseif node.chosenPartName then
    partNiceName = node.chosenPartName
  end

  local partInfo = nil
  if node.chosenPartName and availableParts[node.chosenPartName] then
    partInfo = availableParts[node.chosenPartName]
  end

  local currentSlotInfo = slotInfo
  if not currentSlotInfo and partInfo and partInfo.slotInfoUi and slotName then
    currentSlotInfo = partInfo.slotInfoUi[slotName]
  end

  if not isRootNode and node.suitablePartNames and #node.suitablePartNames > 0 then
    local availablePartsList = {}
    local addedPartNames = {}

    for _, partName in ipairs(node.suitablePartNames) do
      local partInfoData = availableParts[partName]
      if partInfoData then
        local desc = partInfoData.description
        local niceName = type(desc) == "table" and desc.description or desc or partName

        local value = 100
        local baseValue = 100
        if ioCtx then
          local jbeamData = jbeamIO.getPart(ioCtx, partName)
          if jbeamData and jbeamData.information and jbeamData.information.value then
            baseValue = jbeamData.information.value
          elseif partInfoData.information and partInfoData.information.value then
            baseValue = partInfoData.information.value
          end
        elseif partInfoData.information and partInfoData.information.value then
          baseValue = partInfoData.information.value
        end

        if career_modules_valueCalculator and vehicleModel then
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
          value = math.max(roundNear(career_modules_valueCalculator.getPartValue(partForValueCalc), 5) - 0.01, 0)
        else
          value = baseValue
        end

        if businessId and value > 0 then
          local discountMultiplier = getPartSupplierDiscountMultiplier(businessId)
          value = value * discountMultiplier
        end

        table.insert(availablePartsList, {
          name = partName,
          niceName = niceName,
          value = value,
          installed = (node.chosenPartName == partName)
        })
        addedPartNames[partName] = true
      end
    end

    local slotCompatibleVariants = {}
    if ownedPartsByName then
      for _, partName in ipairs(node.suitablePartNames) do
        local variants = ownedPartsByName[partName]
        if variants and #variants > 0 then
          local existingEntry = nil
          for _, entry in ipairs(availablePartsList) do
            if entry.name == partName then
              existingEntry = entry
              break
            end
          end
          if not existingEntry then
            local partInfoData = availableParts[partName]
            local niceName = partName
            if partInfoData then
              local desc = partInfoData.description
              niceName = type(desc) == "table" and desc.description or desc or partName
            end
            existingEntry = {
              name = partName,
              niceName = niceName,
              value = 0,
              installed = false,
              fromInventory = true,
              isOwned = true
            }
            table.insert(availablePartsList, existingEntry)
          end
          existingEntry.hasOwnedVariants = true
          existingEntry.ownedVariants = variants
          for _, variant in ipairs(variants) do
            table.insert(slotCompatibleVariants, variant)
          end
        end
      end
    end

    table.sort(availablePartsList, function(a, b)
      local nameA = string.lower(a.niceName or a.name or "")
      local nameB = string.lower(b.niceName or b.name or "")
      return nameA < nameB
    end)

    if #availablePartsList > 0 then
      table.insert(result, {
        id = currentPath,
        path = currentPath,
        slotName = slotName or "",
        slotNiceName = slotNiceName,
        chosenPartName = node.chosenPartName or "",
        partNiceName = partNiceName,
        availableParts = availablePartsList,
        compatibleInventoryParts = slotCompatibleVariants,
        parentSlotName = parentSlotName
      })
    end
  end

  if node.children then
    for childSlotName, childNode in pairs(node.children) do
      local childPath = (currentPath == "/" and "" or currentPath) .. childSlotName .. "/"
      local childSlotInfo = nil
      if partInfo and partInfo.slotInfoUi and partInfo.slotInfoUi[childSlotName] then
        childSlotInfo = partInfo.slotInfoUi[childSlotName]
      end
      local childResults = formatPartsTreeForUI(childNode, childSlotName, childSlotInfo, availableParts, slotsNiceName,
        partsNiceName, childPath, slotNiceName, ioCtx, businessId, vehicleData, vehicleModel, ownedPartsByName)
      for _, childResult in ipairs(childResults) do
        table.insert(result, childResult)
      end
    end
  end

  return result
end

local function getPersonalVehicleData(vehicleId, businessId)
  if not isPersonalVehicleId(vehicleId) then
    return nil
  end
  
  local activePersonal = nil
  if businessId then
    local _, businessType = resolveBusinessModule(businessId)
    if businessType then
      local businessObj = career_modules_business_businessManager and career_modules_business_businessManager.getBusinessObject(businessType)
      if businessObj and businessObj.getActivePersonalVehicle then
        activePersonal = businessObj.getActivePersonalVehicle(businessId)
      end
    end
  else
    local allBusinessObjects = career_modules_business_businessManager and career_modules_business_businessManager.getAllBusinessObjects and career_modules_business_businessManager.getAllBusinessObjects() or {}
    for businessType, businessObj in pairs(allBusinessObjects) do
      if businessObj.getActivePersonalVehicle then
        local purchased = career_modules_business_businessManager.getPurchasedBusinesses(businessType) or {}
        for bId, _ in pairs(purchased) do
          local entry = businessObj.getActivePersonalVehicle(bId)
          if entry and tostring(entry.vehicleId) == tostring(vehicleId) then
            activePersonal = entry
            break
          end
        end
        if activePersonal then break end
      end
    end
  end
  
  if activePersonal and tostring(activePersonal.vehicleId) == tostring(vehicleId) then
    return activePersonal
  end
  
  return nil
end

local function requestVehiclePartsTree(businessId, vehicleId)
  if not businessId or not vehicleId then
    guihooks.trigger('businessComputer:onVehiclePartsTree', {
      success = false,
      error = "Missing parameters"
    })
    return
  end

  local isPersonal = isPersonalVehicleId(vehicleId)
  
  if isPersonal then
    local spawnedId = getSpawnedIdFromPersonalVehicleId(vehicleId)
    if not spawnedId then
      guihooks.trigger('businessComputer:onVehiclePartsTree', {
        success = false,
        error = "Invalid personal vehicle ID"
      })
      return
    end
    
    local vehicleData = extensions.core_vehicle_manager.getVehicleData(spawnedId)
    
    if not vehicleData or not vehicleData.config or not vehicleData.config.partsTree then
      guihooks.trigger('businessComputer:onVehiclePartsTree', {
        success = false,
        error = "No parts tree found for personal vehicle"
      })
      return
    end
    
    local availableParts = jbeamIO.getAvailableParts(vehicleData.ioCtx)
    local slotsNiceName = {}
    local partsNiceName = {}
    
    for partName, partInfo in pairs(availableParts) do
      if partInfo.slotInfoUi then
        for slotName, slotInfo in pairs(partInfo.slotInfoUi) do
          slotsNiceName[slotName] = type(slotInfo.description) == "table" and slotInfo.description.description or slotInfo.description
        end
      end
      local desc = partInfo.description
      partsNiceName[partName] = type(desc) == "table" and desc.description or desc
    end
    
    local vehObj = be:getObjectByID(spawnedId)
    local personalVehicleModel = vehObj and vehObj:getJBeamFilename() or nil
    local partsTreeList = formatPartsTreeForUI(vehicleData.config.partsTree, "", nil, availableParts, slotsNiceName, partsNiceName, "/", nil, vehicleData.ioCtx, businessId, vehicleData, personalVehicleModel, nil)
    
    guihooks.trigger('businessComputer:onVehiclePartsTree', {
      success = true,
      businessId = businessId,
      vehicleId = vehicleId,
      jobId = nil,
      partsTree = partsTreeList,
      slotsNiceName = slotsNiceName,
      partsNiceName = partsNiceName,
      isPersonal = true
    })
    return
  end

  local normalizedVehicleId = tonumber(vehicleId) or vehicleId
  local initialVehicle = career_modules_business_businessInventory.getVehicleById(businessId, normalizedVehicleId)
  if not initialVehicle then
    guihooks.trigger('businessComputer:onVehiclePartsTree', {
      success = false,
      error = "Vehicle not found"
    })
    return
  end

  local spawnedVehicleId = nil
  if career_modules_business_businessInventory and career_modules_business_businessInventory.getSpawnedVehicleId then
    spawnedVehicleId = career_modules_business_businessInventory.getSpawnedVehicleId(businessId, normalizedVehicleId)
  end

  if spawnedVehicleId then
    local vehicleData = extensions.core_vehicle_manager.getVehicleData(spawnedVehicleId)
    if vehicleData and vehicleData.config and vehicleData.config.partsTree then
      local availableParts = jbeamIO.getAvailableParts(vehicleData.ioCtx)
      local slotsNiceName = {}
      local partsNiceName = {}
      
      for partName, partInfo in pairs(availableParts) do
        if partInfo.slotInfoUi then
          for slotName, slotInfo in pairs(partInfo.slotInfoUi) do
            slotsNiceName[slotName] = type(slotInfo.description) == "table" and slotInfo.description.description or slotInfo.description
          end
        end
        local desc = partInfo.description
        partsNiceName[partName] = type(desc) == "table" and desc.description or desc
      end
      
      local spawnedVehicleModel = initialVehicle.vehicleConfig and initialVehicle.vehicleConfig.model_key or initialVehicle.model_key
      local ownedPartsLookup = nil
      if career_modules_business_businessPartInventory and spawnedVehicleModel then
        local inventoryParts = career_modules_business_businessPartInventory.getPartsByModel(spawnedVehicleModel)
        ownedPartsLookup = buildOwnedPartsLookup(inventoryParts, spawnedVehicleModel)
      end
      local partsTreeList = formatPartsTreeForUI(vehicleData.config.partsTree, "", nil, availableParts, slotsNiceName, partsNiceName, "/", nil, vehicleData.ioCtx, businessId, vehicleData, spawnedVehicleModel, ownedPartsLookup)
      
      guihooks.trigger('businessComputer:onVehiclePartsTree', {
        success = true,
        businessId = businessId,
        vehicleId = vehicleId,
        jobId = initialVehicle.jobId,
        partsTree = partsTreeList,
        slotsNiceName = slotsNiceName,
        partsNiceName = partsNiceName
      })
      return
    end
  end

  local previewConfig = nil
  if career_modules_business_businessPartCustomization then
    previewConfig = career_modules_business_businessPartCustomization.getPreviewVehicleConfig(businessId)
  end

  local cachedEntry = getCachedPartsTree(businessId, initialVehicle.jobId)
  if cachedEntry and cachedEntry.vehicleId == initialVehicle.vehicleId and not previewConfig then
    guihooks.trigger('businessComputer:onVehiclePartsTree', {
      success = true,
      businessId = businessId,
      vehicleId = vehicleId,
      jobId = initialVehicle.jobId,
      partsTree = cachedEntry.partsTree,
      slotsNiceName = cachedEntry.slotsNiceName,
      partsNiceName = cachedEntry.partsNiceName
    })
    return
  end

  -- Fallback: Business vehicles need job system to spawn temporary vehicle
  core_jobsystem.create(function(job)
    local vehicle = career_modules_business_businessInventory.getVehicleById(businessId, vehicleId)
    if not vehicle or not vehicle.vehicleConfig then
      guihooks.trigger('businessComputer:onVehiclePartsTree', {
        success = false,
        error = "Vehicle not found"
      })
      return
    end

    local modelKey = vehicle.vehicleConfig.model_key or vehicle.model_key
    local configKey = vehicle.vehicleConfig.key or vehicle.config_key

    if not modelKey or not configKey then
      guihooks.trigger('businessComputer:onVehiclePartsTree', {
        success = false,
        error = "Invalid vehicle config"
      })
      return
    end

    local configToUse = configKey
    if career_modules_business_businessPartCustomization then
      local previewConfig = career_modules_business_businessPartCustomization.getPreviewVehicleConfig(businessId)
      if previewConfig then
        configToUse = previewConfig
      end
    end

    local vehicleObj = core_vehicles.spawnNewVehicle(modelKey, {
      config = configToUse,
      pos = vec3(0, 0, -1000),
      rot = quat(0, 0, 0, 1),
      keepLoaded = true,
      autoEnterVehicle = false
    })

    if not vehicleObj then
      guihooks.trigger('businessComputer:onVehiclePartsTree', {
        success = false,
        error = "Failed to spawn vehicle"
      })
      return
    end

    local vehId = vehicleObj:getID()
    local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehId)

    if not vehicleData or not vehicleData.config or not vehicleData.config.partsTree then
      log("W", "businessComputer", "requestVehiclePartsTree: No parts tree for business vehicle")
      vehicleObj:delete()
      guihooks.trigger('businessComputer:onVehiclePartsTree', {
        success = false,
        error = "No parts tree found"
      })
      return
    end

    local availableParts = jbeamIO.getAvailableParts(vehicleData.ioCtx)
    local slotsNiceName = {}
    local partsNiceName = {}

    for partName, partInfo in pairs(availableParts) do
      if partInfo.slotInfoUi then
        for slotName, slotInfo in pairs(partInfo.slotInfoUi) do
          slotsNiceName[slotName] = type(slotInfo.description) == "table" and slotInfo.description.description or slotInfo.description
        end
      end
      local desc = partInfo.description
      partsNiceName[partName] = type(desc) == "table" and desc.description or desc
    end

    local vehicleModel = vehicle.vehicleConfig.model_key or vehicle.model_key
    local ownedPartsLookup = nil
    if career_modules_business_businessPartInventory and vehicleModel then
      local inventoryParts = career_modules_business_businessPartInventory.getPartsByModel(vehicleModel)
      ownedPartsLookup = buildOwnedPartsLookup(inventoryParts, vehicleModel)
    end

    local partsTreeList = formatPartsTreeForUI(vehicleData.config.partsTree, "", nil, availableParts, slotsNiceName,
      partsNiceName, "/", nil, vehicleData.ioCtx, businessId, vehicleData, vehicleModel, ownedPartsLookup)

    -- Delete the temporary spawned vehicle
    vehicleObj:delete()

    local cacheJobId = vehicle.jobId
    if isPersonal then
      cacheJobId = "personal_" .. tostring(vehicle.inventoryId or vehicleId)
    end
    setCachedPartsTree(businessId, cacheJobId, {
      vehicleId = vehicle.vehicleId,
      partsTree = partsTreeList,
      slotsNiceName = slotsNiceName,
      partsNiceName = partsNiceName
    })

    guihooks.trigger('businessComputer:onVehiclePartsTree', {
      success = true,
      businessId = businessId,
      vehicleId = vehicleId,
      jobId = cacheJobId,
      partsTree = partsTreeList,
      slotsNiceName = slotsNiceName,
      partsNiceName = partsNiceName,
      isPersonal = isPersonal
    })
  end)
end

local function getVehiclePartsTree(businessId, vehicleId)
  requestVehiclePartsTree(businessId, vehicleId)
  return nil
end

local function requestVehicleTuningData(businessId, vehicleId)
  if shouldPreventVehicleOperation(businessId, vehicleId) then
    return false
  end

  if career_modules_business_businessVehicleTuning then
    return career_modules_business_businessVehicleTuning.requestVehicleTuningData(businessId, vehicleId)
  end
end

local function getVehicleTuningData(businessId, vehicleId)
  if shouldPreventVehicleOperation(businessId, vehicleId) then
    return nil
  end

  if career_modules_business_businessVehicleTuning then
    return career_modules_business_businessVehicleTuning.getVehicleTuningData(businessId, vehicleId)
  end
  return nil
end

local function applyTuningToVehicle(businessId, vehicleId, tuningVars)
  if shouldPreventVehicleOperation(businessId, vehicleId) then
    return false
  end

  if career_modules_business_businessVehicleTuning then
    return career_modules_business_businessVehicleTuning.applyTuningToVehicle(businessId, vehicleId, tuningVars)
  end
  return false
end

local activeWheelDataVehicles = {}

local function loadWheelDataExtension(businessId, vehicleId)
  if not businessId or not vehicleId then
    return false
  end

  local vehicleObj = getBusinessVehicleObject(businessId, vehicleId)
  if not vehicleObj then
    return false
  end

  local vehId = vehicleObj:getID()
  local key = businessId .. "_" .. tostring(vehicleId)

  for oldVehId, entry in pairs(activeWheelDataVehicles) do
    if entry.key == key and oldVehId ~= vehId then
      local oldVehicleObj = be:getObjectByID(oldVehId)
      if oldVehicleObj then
        oldVehicleObj:queueLuaCommand([[
          if extensions.businessWheelData then
            extensions.businessWheelData.disableWheelData()
          end
          extensions.unload("businessWheelData")
        ]])
      end
      activeWheelDataVehicles[oldVehId] = nil
    end
  end

  vehicleObj:queueLuaCommand([[
    if extensions.businessWheelData then
      extensions.businessWheelData.disableWheelData()
    end
    extensions.unload("businessWheelData")
  ]])

  vehicleObj:queueLuaCommand([[
    extensions.load("businessWheelData")
    if extensions.businessWheelData then
      extensions.businessWheelData.enableWheelData()
    end
  ]])

  activeWheelDataVehicles[vehId] = {
    businessId = businessId,
    vehicleId = vehicleId,
    key = key
  }

  return true
end

local function unloadWheelDataExtension(businessId, vehicleId)
  if not businessId or not vehicleId then
    return false
  end

  local vehicleObj = getBusinessVehicleObject(businessId, vehicleId)
  if not vehicleObj then
    return false
  end

  local vehId = vehicleObj:getID()
  if not activeWheelDataVehicles[vehId] then
    return false
  end

  vehicleObj:queueLuaCommand([[
    if extensions.businessWheelData then
      extensions.businessWheelData.disableWheelData()
    end
    extensions.unload("businessWheelData")
  ]])

  activeWheelDataVehicles[vehId] = nil

  return true
end

local function onVehicleWheelDataUpdate(vehId, dataStr)
  local vehicleInfo = activeWheelDataVehicles[vehId]
  if not vehicleInfo then
    return
  end

  local data = {}
  if dataStr and dataStr ~= "{}" then
    local success, decoded = pcall(function()
      return jsonDecode(dataStr)
    end)
    if success and decoded then
      data = decoded
    end
  end

  guihooks.trigger('businessComputer:onVehicleWheelData', {
    success = true,
    businessId = vehicleInfo.businessId,
    vehicleId = tonumber(vehicleInfo.vehicleId),
    wheelData = data
  })
end

local function calculateTuningCost(businessId, vehicleId, tuningVars, originalVars)
  if career_modules_business_businessVehicleTuning then
    return career_modules_business_businessVehicleTuning.calculateTuningCost(businessId, vehicleId, tuningVars,
      originalVars)
  end
  return 0
end

local function getTuningShoppingCart(businessId, vehicleId, tuningVars, originalVars)
  if career_modules_business_businessVehicleTuning then
    return
      career_modules_business_businessVehicleTuning.getShoppingCart(businessId, vehicleId, tuningVars, originalVars)
  end
  return {
    items = {},
    total = 0,
    taxes = 0
  }
end

local function addTuningToCart(businessId, vehicleId, currentTuningVars, baselineTuningVars)
  if shouldPreventVehicleOperation(businessId, vehicleId) then
    return {}
  end

  if career_modules_business_businessVehicleTuning then
    return career_modules_business_businessVehicleTuning.addTuningToCart(businessId, vehicleId, currentTuningVars,
      baselineTuningVars)
  end
  return {}
end

local function getAllRequiredParts(businessId, vehicleId, parts, cartParts)
  if career_modules_business_businessPartCustomization then
    return
      career_modules_business_businessPartCustomization.getAllRequiredParts(businessId, vehicleId, parts, cartParts)
  end
  return {}
end

local function addPartToCart(businessId, vehicleId, currentCart, partToAdd)
  if shouldPreventVehicleOperation(businessId, vehicleId) then
    return currentCart or {}
  end

  if career_modules_business_businessPartCustomization then
    return
      career_modules_business_businessPartCustomization.addPartToCart(businessId, vehicleId, currentCart, partToAdd)
  end
  return currentCart or {}
end

local function applyVehicleTuning(businessId, vehicleId, tuningVars, accountId)
  if shouldPreventVehicleOperation(businessId, vehicleId) then
    return false
  end

  if career_modules_business_businessVehicleTuning then
    return
      career_modules_business_businessVehicleTuning.applyVehicleTuning(businessId, vehicleId, tuningVars, accountId)
  end
  return false
end

local function initializePreviewVehicle(businessId, vehicleId)
  if shouldPreventVehicleOperation(businessId, vehicleId) then
    return false
  end

  if career_modules_business_businessPartCustomization then
    return career_modules_business_businessPartCustomization.initializePreviewVehicle(businessId, vehicleId)
  end
  return false
end

local function resetVehicleToOriginal(businessId, vehicleId)
  if shouldPreventVehicleOperation(businessId, vehicleId) then
    return false
  end

  if career_modules_business_businessPartCustomization then
    return career_modules_business_businessPartCustomization.resetVehicleToOriginal(businessId, vehicleId)
  end
  return false
end

local function applyPartsToVehicle(businessId, vehicleId, parts)
  if shouldPreventVehicleOperation(businessId, vehicleId) then
    return false
  end

  if career_modules_business_businessPartCustomization then
    return career_modules_business_businessPartCustomization.applyPartsToVehicle(businessId, vehicleId, parts)
  end
  return false
end

local function applyCartPartsToVehicle(businessId, vehicleId, parts)
  if shouldPreventVehicleOperation(businessId, vehicleId) then
    return false
  end

  if career_modules_business_businessPartCustomization then
    return career_modules_business_businessPartCustomization.applyCartPartsToVehicle(businessId, vehicleId, parts)
  end
  return false
end

local function installPartOnVehicle(businessId, vehicleId, partName, slotPath)
  if shouldPreventVehicleOperation(businessId, vehicleId) then
    return false
  end

  if career_modules_business_businessPartCustomization then
    return career_modules_business_businessPartCustomization.installPartOnVehicle(businessId, vehicleId, partName,
      slotPath)
  end
  return false
end

local function purchaseCartItems(businessId, accountId, cartData)
  if not businessId or not accountId or not cartData then
    return false
  end
  if not career_modules_bank then
    return false
  end

  local parts = cartData.parts or {}
  local tuning = cartData.tuning or {}

  local salesTax = 0.07

  local subtotal = 0

  for _, part in ipairs(parts) do
    subtotal = subtotal + (part.price or 0)
  end

  if #tuning > 0 then
    local vehicle = getActiveBusinessVehicle(businessId)
    if vehicle and vehicle.vehicleId then
      local originalVars = vehicle.vars or {}

      local tuningVars = {}
      for _, change in ipairs(tuning) do
        if change.type == "variable" and change.varName and change.value ~= nil then
          tuningVars[change.varName] = change.value
        end
      end

      local tuningCost = calculateTuningCost(businessId, vehicle.vehicleId, tuningVars, originalVars)
      subtotal = subtotal + tuningCost
    else
      local variableCount = 0
      for _, change in ipairs(tuning) do
        if change.type == "variable" and change.varName and change.value ~= nil then
          variableCount = variableCount + 1
        end
      end
      subtotal = subtotal + (50 * variableCount)
    end
  end

  local taxAmount = subtotal * salesTax
  local totalCost = subtotal + taxAmount

  local hasItems = (#parts > 0) or (#tuning > 0)
  if not hasItems then
    return false
  end

  if totalCost > 0 then
    local success = career_modules_bank.payFromAccount({
      money = {
        amount = totalCost,
        canBeNegative = false
      }
    }, accountId, "Shop Purchase", "Purchased parts/tuning")
    if not success then
      log("E", "businessComputer", "purchaseCartItems: Payment failed for amount " .. tostring(totalCost))
      return false
    end

    if career_modules_bank then
      local businessTypeFromAccount, businessIdFromAccount = accountId:match("^business_(.+)_(.+)$")
      if businessTypeFromAccount and businessIdFromAccount then
        local account = career_modules_bank.getBusinessAccount(businessTypeFromAccount, businessIdFromAccount)
        if account then
          local accountData = {
            accountId = account.id,
            balance = account.balance or 0,
            accountType = account.type or "unknown",
            businessType = account.businessType,
            businessId = account.businessId,
            name = account.name or "Account"
          }
          guihooks.trigger('bank:onAccountUpdate', accountData)
        end
      end
    end
  end

  local vehicle = getActiveBusinessVehicle(businessId)
  if vehicle and vehicle.vehicleId then
    local vehicleIdStr = tostring(vehicle.vehicleId)
    local isPersonalVehicle = isPersonalVehicleId(vehicleIdStr)

    if #parts > 0 then
      if not isPersonalVehicle and career_modules_business_businessPartInventory then
        local removedParts = {}
        if career_modules_business_businessPartCustomization then
          removedParts = career_modules_business_businessPartCustomization.findRemovedParts(businessId, vehicle.vehicleId) or {}
        end

        if #removedParts == 0 then
          removedParts = findRemovedPartsFromCart(businessId, vehicle.vehicleId, parts) or {}
        end

        if #removedParts > 0 then
          career_modules_business_businessPartInventory.addParts(removedParts)
        end

        local partsRemovedFromInventory = false
        for _, part in ipairs(parts) do
          if part.fromInventory and part.partId then
            career_modules_business_businessPartInventory.removePart(part.partId)
            partsRemovedFromInventory = true
          end
        end
        
        -- Refresh inventory UI if parts were added or removed
        if (#removedParts > 0) or partsRemovedFromInventory then
          requestPartInventory(businessId)
        end
      end

      applyCartPartsToVehicle(businessId, vehicle.vehicleId, parts)

      local previewConfig = nil
      if career_modules_business_businessPartCustomization then
        previewConfig = career_modules_business_businessPartCustomization.getPreviewVehicleConfig(businessId)
      end

      if previewConfig then
        vehicle.config = previewConfig

        if vehicle.vars then
          vehicle.config.vars = deepcopy(vehicle.vars)
        end

        local partList = {}
        local function extractParts(tree)
          if tree.chosenPartName and tree.path then
            partList[tree.path] = tree.chosenPartName
          end
          if tree.children then
            for _, child in pairs(tree.children) do
              extractParts(child)
            end
          end
        end
        extractParts(previewConfig.partsTree or {})

        vehicle.partList = partList

        if isPersonalVehicle then
          local inventoryId = getInventoryIdFromPersonalVehicleId(vehicleIdStr, businessId)
          if inventoryId and career_modules_inventory then
            local inventoryVehicles = career_modules_inventory.getVehicles()
            if inventoryVehicles and inventoryVehicles[inventoryId] then
              inventoryVehicles[inventoryId].config = vehicle.config
              if career_modules_inventory.setVehicleDirty then
                career_modules_inventory.setVehicleDirty(inventoryId)
              end
            end
          end
        else
          -- For business vehicles, save to business inventory
          career_modules_business_businessInventory.updateVehicle(businessId, vehicle.vehicleId, {
            config = vehicle.config,
            partList = vehicle.partList
          })

          if career_modules_business_businessInventory.getPulledOutVehicles then
            local pulledVehicles = career_modules_business_businessInventory.getPulledOutVehicles(businessId) or {}
            local targetId = normalizeVehicleIdValue(vehicle.vehicleId)
            for _, pulled in ipairs(pulledVehicles) do
              local pulledId = normalizeVehicleIdValue(pulled.vehicleId)
              if pulledId == targetId then
                pulled.config = vehicle.config
                pulled.partList = vehicle.partList
                break
              end
            end
          else
            local pulledOutVehicle = career_modules_business_businessInventory.getPulledOutVehicle(businessId)
            if pulledOutVehicle and pulledOutVehicle.vehicleId == vehicle.vehicleId then
              pulledOutVehicle.config = vehicle.config
              pulledOutVehicle.partList = vehicle.partList
            end
          end
        end
      end
    end

    if #tuning > 0 then
      local tuningVars = {}
      for _, change in ipairs(tuning) do
        if change.type == "variable" and change.varName and change.value ~= nil then
          tuningVars[change.varName] = change.value
        end
      end
      applyVehicleTuning(businessId, vehicle.vehicleId, tuningVars, nil)
      
      -- Update vehicle vars and config for job vehicles
      if not isPersonalVehicle then
        -- Update vehicle.vars
        vehicle.vars = tuningVars
        
        -- Update vehicle.config.vars if config exists
        if vehicle.config then
          vehicle.config.vars = deepcopy(tuningVars)
        end
        
        -- Save updated config and vars to business inventory
        local updateData = {
          vars = tuningVars
        }
        if vehicle.config then
          updateData.config = vehicle.config
        end
        career_modules_business_businessInventory.updateVehicle(businessId, vehicle.vehicleId, updateData)
        
        -- Update pulled out vehicle references
        if career_modules_business_businessInventory.getPulledOutVehicles then
          local pulledVehicles = career_modules_business_businessInventory.getPulledOutVehicles(businessId) or {}
          local targetId = normalizeVehicleIdValue(vehicle.vehicleId)
          for _, pulled in ipairs(pulledVehicles) do
            local pulledId = normalizeVehicleIdValue(pulled.vehicleId)
            if pulledId == targetId then
              pulled.vars = tuningVars
              if vehicle.config then
                pulled.config = vehicle.config
              end
              break
            end
          end
        else
          local pulledOutVehicle = career_modules_business_businessInventory.getPulledOutVehicle(businessId)
          if pulledOutVehicle and pulledOutVehicle.vehicleId == vehicle.vehicleId then
            pulledOutVehicle.vars = tuningVars
            if vehicle.config then
              pulledOutVehicle.config = vehicle.config
            end
          end
        end
      end
    end

    M.exitShoppingVehicle(businessId)

    if isPersonalVehicle then
      if career_modules_business_businessPartCustomization then
        career_modules_business_businessPartCustomization.clearPreviewVehicle(businessId)
      end
      if career_modules_business_businessVehicleTuning then
        career_modules_business_businessVehicleTuning.clearTuningDataCache()
      end
      local inventoryId = getInventoryIdFromPersonalVehicleId(vehicleIdStr, businessId)
      if inventoryId then
        career_saveSystem.saveCurrent({inventoryId})
      end
    else
      -- Save the vehicle config changes before finalizing purchase
      -- This ensures the updated config is persisted before finalizePurchase puts away and respawns the vehicle
      if (#parts > 0) or (#tuning > 0) then
        career_saveSystem.saveCurrent()
      end
      career_modules_business_businessVehicleModificationUtil.finalizePurchase(businessId, vehicle.vehicleId, nop)
    end
  else
    log("W", "businessComputer", "purchaseCartItems: No active vehicle found for businessId=" .. tostring(businessId))
  end

  if vehicle then
    clearCachesForJob(businessId, vehicle.jobId)
  end

  Engine.Audio.playOnce('AudioGui','event:>UI>Career>Buy_01')
  return true
end

local function getBusinessAccountBalance(businessType, businessId)
  if not businessType or not businessId then
    return 0
  end

  if career_modules_bank then
    local account = career_modules_bank.getBusinessAccount(businessType, businessId)
    if account then
      return career_modules_bank.getAccountBalance(account.id)
    end
  end

  return 0
end

local function getBusinessXP(businessType, businessId)
  if not businessType or not businessId then
    return 0
  end

  setBusinessContext(businessType, businessId)

  local module = getBusinessModule(businessType)
  if module and module.getBusinessXP then
    return module.getBusinessXP(businessId)
  end

  return 0
end

local function onPowerWeightReceived(requestId, power, weight)
  if career_modules_business_businessPartCustomization then
    return career_modules_business_businessPartCustomization.onPowerWeightReceived(requestId, power, weight)
  end
end

local function getVehiclePowerWeight(businessId, vehicleId)
  if shouldPreventVehicleOperation(businessId, vehicleId) then
    return nil
  end

  if career_modules_business_businessPartCustomization then
    return career_modules_business_businessPartCustomization.getVehiclePowerWeight(businessId, vehicleId)
  end
  return nil
end

local function completeJob(businessId, jobId)
  local module, businessType = resolveBusinessModule(businessId)
  if module and module.completeJob then
    local success = module.completeJob(businessId, jobId)
    if success and guihooks then
      local jobsData = M.getJobsOnly(businessId)
      local vehiclesData = M.getVehiclesOnly(businessId)
      guihooks.trigger('businessComputer:onJobCompleted', {
        businessType = businessType,
        businessId = businessId,
        jobId = jobId,
        activeJobs = jobsData.activeJobs,
        vehicles = vehiclesData.vehicles,
        pulledOutVehicles = vehiclesData.pulledOutVehicles
      })
    end
    return success
  end
  return false
end

local function setActiveVehicle(businessId, vehicleId)
  if not businessId or not vehicleId then
    return false
  end

  local lockInfo = getDamageLockedVehicleInfo(businessId, vehicleId)
  if lockInfo then
    notifyDamageLocked(lockInfo)
    return {
      success = false,
      errorCode = "damageLocked"
    }
  end

  if career_modules_business_businessInventory and career_modules_business_businessInventory.setActiveVehicle then
    return career_modules_business_businessInventory.setActiveVehicle(businessId, vehicleId)
  end

  return false
end

local function getActiveVehicle(businessId)
  return getActiveBusinessVehicle(businessId)
end

local function enterShoppingVehicle(businessId, vehicleId)
  if not businessId or not vehicleId then
    log("W", "businessComputer", "enterShoppingVehicle: Missing businessId or vehicleId")
    return false
  end
  
  local spawnedVehId = nil
  
  if isPersonalVehicleId(vehicleId) then
    spawnedVehId = getSpawnedIdFromPersonalVehicleId(vehicleId)
    else
      if not career_modules_business_businessInventory then
      log("W", "businessComputer", "enterShoppingVehicle: businessInventory module not available")
      return false
    end
    spawnedVehId = career_modules_business_businessInventory.getSpawnedVehicleId(businessId, vehicleId)
  end
  
  if not spawnedVehId or spawnedVehId == 0 then
    return false
  end
  
  local vehObj = be:getObjectByID(spawnedVehId)
  if not vehObj then
    return false
  end
  
  if gameplay_walk and gameplay_walk.isWalking() then
    gameplay_walk.getInVehicle(vehObj)
  else
    be:enterVehicle(0, vehObj)
  end
  return true
end

local function exitShoppingVehicle(businessId)
  local playerVeh = be:getPlayerVehicle(0)
  if not playerVeh then
    return false
  end
  if businessId then
    local playerVehId = playerVeh:getID()
    local isValidVehicle = false

    local _, businessType = resolveBusinessModule(businessId)
    if businessType then
      local businessObj = career_modules_business_businessManager and career_modules_business_businessManager.getBusinessObject(businessType)
      if businessObj and businessObj.getActivePersonalVehicle then
        local activePersonal = businessObj.getActivePersonalVehicle(businessId)
        if activePersonal and activePersonal.spawnedVehicleId == playerVehId then
          isValidVehicle = true
        end
      end
    end

    if not isValidVehicle and career_modules_business_businessInventory then
      local pulledOutList = getPulledOutVehiclesList(businessId)
      for _, vehicle in ipairs(pulledOutList) do
        local spawnedId = career_modules_business_businessInventory.getSpawnedVehicleId(businessId, vehicle.vehicleId)
        if spawnedId and spawnedId == playerVehId then
          isValidVehicle = true
          break
        end
      end
    end

    if not isValidVehicle then
      return false
    end
  end
  if gameplay_walk then
    gameplay_walk.setWalkingMode(true, nil, nil, true)
  end
  return true
end

local function canCompleteJob(businessId, jobId)
  local module = resolveBusinessModule(businessId)
  if module and module.canCompleteJob then
    return module.canCompleteJob(businessId, jobId)
  end
  return false
end

local function getAbandonPenalty(businessId, jobId)
  local module = resolveBusinessModule(businessId)
  if module and module.getAbandonPenalty then
    return module.getAbandonPenalty(businessId, jobId)
  end
  return 0
end

local function getJobsOnly(businessId)
  local module = resolveBusinessModule(businessId)
  if not module then
    return { activeJobs = {}, newJobs = {} }
  end
  local activeJobs = {}
  local newJobs = {}
  if module.getActiveJobs then
    activeJobs = module.getActiveJobs(businessId) or {}
  end
  if module.getNewJobs then
    newJobs = module.getNewJobs(businessId) or {}
  end
  local maxActiveJobs = 2
  if module.getMaxActiveJobs then
    maxActiveJobs = module.getMaxActiveJobs(businessId) or 2
  end
  return {
    businessId = businessId,
    activeJobs = activeJobs,
    newJobs = newJobs,
    maxActiveJobs = maxActiveJobs
  }
end

local function getVehiclesOnly(businessId)
  if not businessId or not career_modules_business_businessInventory then
    return { vehicles = {}, pulledOutVehicles = {} }
  end
  local vehicles = career_modules_business_businessInventory.getBusinessVehicles(businessId) or {}
  local pulledOutVehiclesRaw = getPulledOutVehiclesList(businessId)
  local formattedVehicles = {}
  for _, vehicle in ipairs(vehicles) do
    table.insert(formattedVehicles, formatVehicleForUI(vehicle, businessId))
  end
  local formattedPulledOut = {}
  for _, vehicle in ipairs(pulledOutVehiclesRaw) do
    local formatted = formatVehicleForUI(vehicle, businessId)
    if formatted then
      local vehicleDamageInfo = isDamageLocked(businessId, vehicle.vehicleId)
      formatted.damage = vehicleDamageInfo.damage
      formatted.damageLocked = vehicleDamageInfo.locked
      formatted.damageThreshold = vehicleDamageInfo.threshold
      table.insert(formattedPulledOut, formatted)
    end
  end
  local module = resolveBusinessModule(businessId)
  local maxPulledOut = 1
  if module and module.getMaxPulledOutVehicles then
    maxPulledOut = module.getMaxPulledOutVehicles(businessId) or 1
  end
  return {
    businessId = businessId,
    vehicles = formattedVehicles,
    pulledOutVehicles = formattedPulledOut,
    maxPulledOutVehicles = maxPulledOut
  }
end

local function getTechsOnly(businessId)
  local module, businessType = resolveBusinessModule(businessId)
  if not module then
    return { techs = {} }
  end
  local techs = {}
  local businessObj = businessType and career_modules_business_businessManager and career_modules_business_businessManager.getBusinessObject(businessType)
  if businessObj and businessObj.getTechsForBusiness then
    local rawTechs = businessObj.getTechsForBusiness(businessId) or {}
    if businessObj.formatTechForUIEntry then
      for _, tech in ipairs(rawTechs) do
        local formattedTech = businessObj.formatTechForUIEntry(businessId, tech)
        if formattedTech then
          table.insert(techs, formattedTech)
        end
      end
    else
      techs = rawTechs
    end
  elseif module.getTechsForBusiness then
    techs = module.getTechsForBusiness(businessId) or {}
  end
  return {
    businessId = businessId,
    techs = techs
  }
end

local function getStatsOnly(businessId)
  local module, businessType = resolveBusinessModule(businessId)
  if not module then
    return { stats = {} }
  end
  local kits = {}
  local businessObj = businessType and career_modules_business_businessManager and career_modules_business_businessManager.getBusinessObject(businessType)
  if businessObj and businessObj.loadBusinessKits then
    kits = businessObj.loadBusinessKits(businessId) or {}
  end
  local vehicles = {}
  if career_modules_business_businessInventory then
    vehicles = career_modules_business_businessInventory.getBusinessVehicles(businessId) or {}
  end
  return {
    businessId = businessId,
    stats = {
      totalVehicles = #vehicles,
      kits = kits
    }
  }
end

local function getManagerDataOnly(businessId)
  local module, businessType = resolveBusinessModule(businessId)
  if not module or not module.getManagerData then
    return nil
  end
  return module.getManagerData(businessId)
end

M.getBusinessComputerUIData = getBusinessComputerUIData
M.getManagerData = getManagerData
M.acceptJob = acceptJob
M.declineJob = declineJob
M.abandonJob = abandonJob
M.assignTechToJob = assignTechToJob
M.renameTech = renameTech
M.completeJob = completeJob
M.canCompleteJob = canCompleteJob
M.getAbandonPenalty = getAbandonPenalty
M.pullOutVehicle = pullOutVehicle
M.putAwayVehicle = putAwayVehicle
M.setActiveVehicle = setActiveVehicle
M.getActiveVehicle = getActiveVehicle
M.getActiveJobs = getActiveJobs
M.getNewJobs = getNewJobs
M.getVehiclePartsTree = getVehiclePartsTree
M.requestVehiclePartsTree = requestVehiclePartsTree
M.getVehicleTuningData = getVehicleTuningData
M.requestVehicleTuningData = requestVehicleTuningData
M.applyVehicleTuning = applyVehicleTuning
M.loadWheelDataExtension = loadWheelDataExtension
M.unloadWheelDataExtension = unloadWheelDataExtension
M.clearVehicleDataCaches = clearVehicleDataCaches
M.clearBusinessCachesForJob = clearCachesForJob
M.getBusinessAccountBalance = getBusinessAccountBalance
M.getBusinessXP = getBusinessXP
M.purchaseCartItems = purchaseCartItems
M.installPartOnVehicle = installPartOnVehicle
M.initializePreviewVehicle = initializePreviewVehicle
M.applyTuningToVehicle = applyTuningToVehicle
M.calculateTuningCost = calculateTuningCost
M.getTuningShoppingCart = getTuningShoppingCart
M.addTuningToCart = addTuningToCart
M.getVehiclePowerWeight = getVehiclePowerWeight
M.resetVehicleToOriginal = resetVehicleToOriginal
M.applyPartsToVehicle = applyPartsToVehicle
M.applyCartPartsToVehicle = applyCartPartsToVehicle
M.getAllRequiredParts = getAllRequiredParts
M.addPartToCart = addPartToCart
M.onVehicleWheelDataUpdate = onVehicleWheelDataUpdate
M.onPowerWeightReceived = onPowerWeightReceived
M.requestPartInventory = requestPartInventory
M.requestFinancesData = function(businessType, businessId)
  if not businessType or not businessId then
    if guihooks then
      guihooks.trigger('businessComputer:onFinancesData', {
        success = false,
        error = "Missing parameters"
      })
    end
    return
  end

  local module = getBusinessModule(businessType)
  if module and module.requestFinancesData then
    module.requestFinancesData(businessId)
  else
    if guihooks then
      guihooks.trigger('businessComputer:onFinancesData', {
        success = false,
        error = "Finances not available for this business type",
        businessType = businessType,
        businessId = businessId
      })
    end
  end
end
M.requestSimulationTime = function()
  local allBusinessObjects = career_modules_business_businessManager and career_modules_business_businessManager.getAllBusinessObjects and career_modules_business_businessManager.getAllBusinessObjects() or {}
  for _, businessObj in pairs(allBusinessObjects) do
    if businessObj.requestSimulationTime then
      businessObj.requestSimulationTime()
      return
    end
  end
  if guihooks then
    guihooks.trigger('businessComputer:onSimulationTime', {
      success = true,
      simulationTime = os.time()
    })
  end
end
M.sellPart = sellPart
M.sellAllParts = sellAllParts
M.sellPartsByVehicle = sellPartsByVehicle
M.getBrandSelection = getBrandSelection
M.setBrandSelection = setBrandSelection
M.getRaceSelection = getRaceSelection
M.setRaceSelection = setRaceSelection
M.getAvailableBrands = getAvailableBrands
M.getAvailableRaceTypes = getAvailableRaceTypes
M.requestAvailableBrands = requestAvailableBrands
M.requestAvailableRaceTypes = requestAvailableRaceTypes
M.getPartSupplierDiscountMultiplier = getPartSupplierDiscountMultiplier
M.getJobsOnly = getJobsOnly
M.getVehiclesOnly = getVehiclesOnly
M.getTechsOnly = getTechsOnly
M.getStatsOnly = getStatsOnly
M.getManagerDataOnly = getManagerDataOnly

M.createKit = function(businessId, jobId, kitName)
  local module = resolveBusinessModule(businessId)
  if module and module.createKit then
    return module.createKit(businessId, jobId, kitName)
  end
  return false
end

M.deleteKit = function(businessId, kitId)
  local module = resolveBusinessModule(businessId)
  if module and module.deleteKit then
    return module.deleteKit(businessId, kitId)
  end
  return false
end

M.applyKit = function(businessId, vehicleId, kitId)
  local module = resolveBusinessModule(businessId)
  if module and module.applyKit then
    return module.applyKit(businessId, vehicleId, kitId)
  end
  return {
    success = false,
    error = "Module not found"
  }
end

local function onExtensionLoaded()
  businessContexts = {}
  return true
end

local function getTechData(businessId)
  local module = resolveBusinessModule(businessId)
  if module and module.getTechData then
    return module.getTechData(businessId)
  end
  return nil
end

local function getManagerData(businessId)
  local module = resolveBusinessModule(businessId)
  if module and module.getManagerData then
    return module.getManagerData(businessId)
  end
  return nil
end

local function selectPersonalVehicle(businessId, inventoryId)
  local module = resolveBusinessModule(businessId)
  if module and module.selectPersonalVehicle then
    return module.selectPersonalVehicle(businessId, inventoryId)
  end
  return { success = false, errorCode = "notSupported", message = "Personal vehicles not supported for this business type" }
end

local function isPersonalUseUnlocked(businessId)
  local module = resolveBusinessModule(businessId)
  if module and module.isPersonalUseUnlocked then
    return module.isPersonalUseUnlocked(businessId)
  end
  return false
end

M.onExtensionLoaded = onExtensionLoaded
M.getTechData = getTechData
M.getManagerData = getManagerData
M.enterShoppingVehicle = enterShoppingVehicle
M.exitShoppingVehicle = exitShoppingVehicle
M.selectPersonalVehicle = selectPersonalVehicle
M.isPersonalUseUnlocked = isPersonalUseUnlocked

return M
