local M = {}

M.dependencies = {'career_career', 'career_saveSystem', 'freeroam_facilities', 'core_vehicles', 'core_jobsystem'}

local jbeamIO = require('jbeam/io')
local jbeamSlotSystem = require('jbeam/slotSystem')

local vehicleInfoCache = nil
local partsTreeCache = {}

local function invalidateVehicleInfoCache()
  vehicleInfoCache = nil
end

local function clearVehicleDataCaches()
  partsTreeCache = {}
  if career_modules_business_businessVehicleTuning then
    career_modules_business_businessVehicleTuning.clearTuningDataCache()
  end
end

local DAMAGE_LOCK_THRESHOLD = 1000

local function getBusinessVehicleObject(businessId, vehicleId)
  if not businessId or not vehicleId then return nil end
  
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

local function isDamageLocked(businessId, vehicleId)
  local lockInfo = {
    locked = false,
    damage = 0,
    threshold = DAMAGE_LOCK_THRESHOLD
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
  lockInfo.locked = damage >= DAMAGE_LOCK_THRESHOLD

  return lockInfo
end

local function notifyDamageLocked(lockInfo)
  if not lockInfo or not lockInfo.locked then
    return
  end

  local message = string.format("Vehicle damage (%.0f) exceeds the %d limit. Abandon the job to continue.", lockInfo.damage or 0, lockInfo.threshold or DAMAGE_LOCK_THRESHOLD)
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
    local bestTime = career_modules_business_businessHelpers.getBestLeaderboardTime(businessId, job.jobId, job.raceType, job.raceLabel)
    if bestTime then
      currentTime = bestTime
    end
  end

  local penalty = 0
  if career_modules_business_businessJobManager and career_modules_business_businessJobManager.getAbandonPenalty then
    penalty = career_modules_business_businessJobManager.getAbandonPenalty(businessId, job.jobId)
  else
    penalty = math.floor((job.reward or 20000) * 0.5)
  end

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

  return {
    id = tostring(vehicle.vehicleId),
    vehicleId = vehicle.vehicleId,
    vehicleName = vehicleName,
    vehicleYear = vehicleYear,
    vehicleType = vehicleType,
    vehicleImage = vehicleImage,
    jobId = vehicle.jobId,
    storedTime = vehicle.storedTime
  }
end

local function getBusinessComputerUIData(businessType, businessId)
  if not businessType or not businessId then
    return nil
  end

  local business = freeroam_facilities.getFacility(businessType, businessId)
  if not business then
    return nil
  end

  local jobs = career_modules_business_businessJobManager.getJobsForBusiness(businessId, businessType)
  local vehicles = career_modules_business_businessInventory.getBusinessVehicles(businessId)
  local parts = career_modules_business_businessPartInventory.getBusinessParts(businessId)
  local pulledOutVehicle = career_modules_business_businessInventory.getPulledOutVehicle(businessId)
  local pulledOutDamageInfo = {
    locked = false,
    damage = 0,
    threshold = DAMAGE_LOCK_THRESHOLD
  }

  local activeJobs = {}
  for _, job in ipairs(jobs.active or {}) do
    table.insert(activeJobs, formatJobForUI(job, businessId))
  end

  local newJobs = {}
  for _, job in ipairs(jobs.new or {}) do
    table.insert(newJobs, formatJobForUI(job, businessId))
  end

  local vehicleList = {}
  for _, vehicle in ipairs(vehicles) do
    table.insert(vehicleList, formatVehicleForUI(vehicle, businessId))
  end

  local pulledOutVehicleData = nil
  if pulledOutVehicle then
    pulledOutVehicleData = formatVehicleForUI(pulledOutVehicle, businessId)
    pulledOutDamageInfo = isDamageLocked(businessId, pulledOutVehicle.vehicleId)
    if pulledOutVehicleData then
      pulledOutVehicleData.damage = pulledOutDamageInfo.damage
      pulledOutVehicleData.damageLocked = pulledOutDamageInfo.locked
      pulledOutVehicleData.damageThreshold = pulledOutDamageInfo.threshold
    end
  end

  local totalPartsValue = 0
  for _, part in ipairs(parts) do
    totalPartsValue = totalPartsValue + (part.price or part.value or 0)
  end

  local tabs = {}
  if career_modules_business_businessTabRegistry then
    if career_modules_business_businessSkillTree and career_modules_business_businessSkillTree.ensureTabsRegistered then
      log('I', 'businessComputer', 'Ensuring skill tree tabs registered for: ' .. tostring(businessType))
      pcall(function()
        career_modules_business_businessSkillTree.ensureTabsRegistered(businessType)
      end)
    else
      log('W', 'businessComputer', 'Skill tree module or ensureTabsRegistered not available')
    end
    tabs = career_modules_business_businessTabRegistry.getTabs(businessType) or {}
    log('I', 'businessComputer', 'Retrieved ' .. tostring(#tabs) .. ' tabs for businessType: ' .. tostring(businessType))

    if pulledOutDamageInfo.locked then
      local allowedTabs = {
        home = true,
        ["active-jobs"] = true,
        ["new-jobs"] = true
      }

      local filteredTabs = {}
      for _, tab in ipairs(tabs) do
        if tab.id and allowedTabs[tab.id] then
          table.insert(filteredTabs, tab)
        end
      end
      tabs = filteredTabs
    end
  else
    log('W', 'businessComputer', 'Tab registry not available')
  end

  return {
    businessId = businessId,
    businessType = businessType,
    businessName = business.name or "Business",
    activeJobs = activeJobs,
    newJobs = newJobs,
    vehicles = vehicleList,
    parts = parts,
    pulledOutVehicle = pulledOutVehicleData,
    tabs = tabs,
    vehicleDamage = pulledOutDamageInfo.damage,
    vehicleDamageLocked = pulledOutDamageInfo.locked,
    vehicleDamageThreshold = pulledOutDamageInfo.threshold,
    stats = {
      totalVehicles = #vehicleList,
      totalParts = #parts,
      totalPartsValue = totalPartsValue,
      activeJobsCount = #activeJobs,
      newJobsCount = #newJobs
    }
  }
end

local function acceptJob(businessId, jobId)
  return career_modules_business_businessJobManager.acceptJob(businessId, jobId)
end

local function declineJob(businessId, jobId)
  return career_modules_business_businessJobManager.declineJob(businessId, jobId)
end

local function abandonJob(businessId, jobId)
  return career_modules_business_businessJobManager.abandonJob(businessId, jobId)
end

local function pullOutVehicle(businessId, vehicleId)
  if not businessId or not vehicleId then
    return false
  end

  local currentVehicle = career_modules_business_businessInventory.getPulledOutVehicle(businessId)
  if currentVehicle and currentVehicle.vehicleId then
    local lockInfo = isDamageLocked(businessId, currentVehicle.vehicleId)
    if lockInfo.locked then
      notifyDamageLocked(lockInfo)
      return { success = false, error = "Vehicle damage >= 1000. Abandon the job first." }
    end
  end

  local result = career_modules_business_businessInventory.pullOutVehicle(businessId, vehicleId)
  return result
end

local function putAwayVehicle(businessId)
  if not businessId then
    return false
  end

  local currentVehicle = career_modules_business_businessInventory.getPulledOutVehicle(businessId)
  if currentVehicle and currentVehicle.vehicleId then
    local lockInfo = isDamageLocked(businessId, currentVehicle.vehicleId)
    if lockInfo.locked then
      notifyDamageLocked(lockInfo)
      return { success = false, error = "Vehicle damage >= 1000. Abandon the job first." }
    end
  end

  return career_modules_business_businessInventory.putAwayVehicle(businessId)
end

local function getActiveJobs(businessId)
  local jobs = career_modules_business_businessJobManager.getJobsForBusiness(businessId, "tuningShop")
  local activeJobs = {}
  for _, job in ipairs(jobs.active or {}) do
    table.insert(activeJobs, formatJobForUI(job, businessId))
  end
  return activeJobs
end

local function getNewJobs(businessId)
  local jobs = career_modules_business_businessJobManager.getJobsForBusiness(businessId, "tuningShop")
  local newJobs = {}
  for _, job in ipairs(jobs.new or {}) do
    table.insert(newJobs, formatJobForUI(job, businessId))
  end
  return newJobs
end

local function getCompatiblePartsFromInventory(businessId, slotPath, slotInfo, vehicleData, vehicleModel)
  if not businessId or not slotPath or not slotInfo or not vehicleData or not vehicleData.ioCtx then
    return {}
  end
  
  if not career_modules_business_businessPartInventory then
    return {}
  end
  
  local businessParts = career_modules_business_businessPartInventory.getBusinessParts(businessId)
  if not businessParts then return {} end
  
  local compatibleParts = {}
  
  for _, inventoryPart in ipairs(businessParts) do
    if not vehicleModel or not inventoryPart.vehicleModel or inventoryPart.vehicleModel == vehicleModel then
      local partDescription = jbeamIO.getPart(vehicleData.ioCtx, inventoryPart.name)
      if partDescription and jbeamSlotSystem.partFitsSlot(partDescription, slotInfo) then
        local niceName = inventoryPart.name
        if partDescription.information and partDescription.information.description then
          niceName = type(partDescription.information.description) == "table" and 
                     partDescription.information.description.description or 
                     partDescription.information.description or 
                     inventoryPart.name
        end
        
        local mileage = 0
        if inventoryPart.partCondition and inventoryPart.partCondition.odometer then
          mileage = inventoryPart.partCondition.odometer
        end
        
        table.insert(compatibleParts, {
          name = inventoryPart.name,
          niceName = niceName,
          value = 0, -- Used parts are free
          mileage = mileage,
          partId = inventoryPart.partId,
          fromInventory = true
        })
      end
    end
  end
  
  return compatibleParts
end

local function formatPartsTreeForUI(node, slotName, slotInfo, availableParts, slotsNiceName, partsNiceName, pathPrefix,
  parentSlotName, ioCtx, businessId, vehicleData, vehicleModel)
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
    for _, partName in ipairs(node.suitablePartNames) do
      local partInfoData = availableParts[partName]
      if partInfoData then
        local desc = partInfoData.description
        local niceName = type(desc) == "table" and desc.description or desc or partName

        local value = 100
        if ioCtx then
          local jbeamData = jbeamIO.getPart(ioCtx, partName)
          if jbeamData and jbeamData.information and jbeamData.information.value then
            value = jbeamData.information.value
          elseif partInfoData.information and partInfoData.information.value then
            value = partInfoData.information.value
          end
        elseif partInfoData.information and partInfoData.information.value then
          value = partInfoData.information.value
        end

        table.insert(availablePartsList, {
          name = partName,
          niceName = niceName,
          value = value,
          installed = (node.chosenPartName == partName)
        })
      end
    end

    table.sort(availablePartsList, function(a, b)
      local nameA = string.lower(a.niceName or a.name or "")
      local nameB = string.lower(b.niceName or b.name or "")
      return nameA < nameB
    end)

    local compatibleInventoryParts = {}
    if businessId and vehicleData and currentSlotInfo then
      compatibleInventoryParts = getCompatiblePartsFromInventory(businessId, currentPath, currentSlotInfo, vehicleData, vehicleModel)
    end
    
    if #availablePartsList > 0 or #compatibleInventoryParts > 0 then
      table.insert(result, {
        id = currentPath,
        path = currentPath,
        slotName = slotName or "",
        slotNiceName = slotNiceName,
        chosenPartName = node.chosenPartName or "",
        partNiceName = partNiceName,
        availableParts = availablePartsList,
        compatibleInventoryParts = compatibleInventoryParts,
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
        partsNiceName, childPath, slotNiceName, ioCtx, businessId, vehicleData, vehicleModel)
      for _, childResult in ipairs(childResults) do
        table.insert(result, childResult)
      end
    end
  end

  return result
end

local function requestVehiclePartsTree(businessId, vehicleId)
  if not businessId or not vehicleId then
    guihooks.trigger('businessComputer:onVehiclePartsTree', {
      success = false,
      error = "Missing parameters"
    })
    return
  end

  local cacheKey = businessId .. "_" .. tostring(vehicleId)
  local previewConfig = nil
  if career_modules_business_businessPartCustomization then
    previewConfig = career_modules_business_businessPartCustomization.getPreviewVehicleConfig(businessId)
  end
  
  if partsTreeCache[cacheKey] and not previewConfig then
    guihooks.trigger('businessComputer:onVehiclePartsTree', {
      success = true,
      businessId = businessId,
      vehicleId = vehicleId,
      partsTree = partsTreeCache[cacheKey].partsTree,
      slotsNiceName = partsTreeCache[cacheKey].slotsNiceName,
      partsNiceName = partsTreeCache[cacheKey].partsNiceName
    })
    return
  end

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
      pos = vec3(0, 0, -1000), -- Spawn far away
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
      if vehicleObj then
        vehicleObj:delete()
      end
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
          slotsNiceName[slotName] = type(slotInfo.description) == "table" and slotInfo.description.description or
                                      slotInfo.description
        end
      end

      local desc = partInfo.description
      partsNiceName[partName] = type(desc) == "table" and desc.description or desc
    end

    local vehicle = career_modules_business_businessInventory.getVehicleById(businessId, vehicleId)
    local vehicleModel = nil
    if vehicle and vehicle.vehicleConfig then
      vehicleModel = vehicle.vehicleConfig.model_key or vehicle.model_key
    end
    
    local partsTreeList = formatPartsTreeForUI(vehicleData.config.partsTree, "", nil, availableParts, slotsNiceName,
      partsNiceName, "/", nil, vehicleData.ioCtx, businessId, vehicleData, vehicleModel)

    if vehicleObj then
      vehicleObj:delete()
    end

    partsTreeCache[cacheKey] = {
      partsTree = partsTreeList,
      slotsNiceName = slotsNiceName,
      partsNiceName = partsNiceName
    }

    guihooks.trigger('businessComputer:onVehiclePartsTree', {
      success = true,
      businessId = businessId,
      vehicleId = vehicleId,
      partsTree = partsTreeList,
      slotsNiceName = slotsNiceName,
      partsNiceName = partsNiceName
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
    return career_modules_business_businessVehicleTuning.calculateTuningCost(businessId, vehicleId, tuningVars, originalVars)
  end
  return 0
end

local function getTuningShoppingCart(businessId, vehicleId, tuningVars, originalVars)
  if career_modules_business_businessVehicleTuning then
    return career_modules_business_businessVehicleTuning.getShoppingCart(businessId, vehicleId, tuningVars, originalVars)
  end
  return {items = {}, total = 0, taxes = 0}
end

local function addTuningToCart(businessId, vehicleId, currentTuningVars, baselineTuningVars)
  if shouldPreventVehicleOperation(businessId, vehicleId) then
    return {}
  end

  if career_modules_business_businessVehicleTuning then
    return career_modules_business_businessVehicleTuning.addTuningToCart(businessId, vehicleId, currentTuningVars, baselineTuningVars)
  end
  return {}
end

local function getAllRequiredParts(businessId, vehicleId, parts, cartParts)
  if career_modules_business_businessPartCustomization then
    return career_modules_business_businessPartCustomization.getAllRequiredParts(businessId, vehicleId, parts, cartParts)
  end
  return {}
end

local function addPartToCart(businessId, vehicleId, currentCart, partToAdd)
  if shouldPreventVehicleOperation(businessId, vehicleId) then
    return currentCart or {}
  end

  if career_modules_business_businessPartCustomization then
    return career_modules_business_businessPartCustomization.addPartToCart(businessId, vehicleId, currentCart, partToAdd)
  end
  return currentCart or {}
end

local function applyVehicleTuning(businessId, vehicleId, tuningVars, accountId)
  if shouldPreventVehicleOperation(businessId, vehicleId) then
    return false
  end

  if career_modules_business_businessVehicleTuning then
    return career_modules_business_businessVehicleTuning.applyVehicleTuning(businessId, vehicleId, tuningVars, accountId)
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
    return career_modules_business_businessPartCustomization.installPartOnVehicle(businessId, vehicleId, partName, slotPath)
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
    local vehicle = career_modules_business_businessInventory.getPulledOutVehicle(businessId)
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

  if subtotal <= 0 then
    return false
  end
  
  local taxAmount = subtotal * salesTax
  local totalCost = subtotal + taxAmount

  local success = career_modules_bank.payFromAccount({
    money = {
      amount = totalCost,
      canBeNegative = false
    }
  }, accountId)
  if not success then
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

  local vehicle = career_modules_business_businessInventory.getPulledOutVehicle(businessId)
  if vehicle and vehicle.vehicleId then
    if #parts > 0 then
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
        
        career_modules_business_businessInventory.updateVehicle(businessId, vehicle.vehicleId, {
          config = vehicle.config,
          partList = vehicle.partList
        })
        
        local pulledOutVehicle = career_modules_business_businessInventory.getPulledOutVehicle(businessId)
        if pulledOutVehicle and pulledOutVehicle.vehicleId == vehicle.vehicleId then
          pulledOutVehicle.config = vehicle.config
          pulledOutVehicle.partList = vehicle.partList
        end
        
        if career_modules_business_businessPartCustomization and career_modules_business_businessPartInventory then
          local removedParts = career_modules_business_businessPartCustomization.findRemovedParts(businessId, vehicle.vehicleId)
          for _, removedPart in ipairs(removedParts) do
            career_modules_business_businessPartInventory.addPart(businessId, removedPart)
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
    end
  end

  career_saveSystem.saveCurrent()

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
  return career_modules_business_businessJobManager.completeJob(businessId, jobId)
end

local function canCompleteJob(businessId, jobId)
  return career_modules_business_businessJobManager.canCompleteJob(businessId, jobId)
end

local function getAbandonPenalty(businessId, jobId)
  if career_modules_business_businessJobManager and career_modules_business_businessJobManager.getAbandonPenalty then
    return career_modules_business_businessJobManager.getAbandonPenalty(businessId, jobId)
  end
  return 0
end

M.getBusinessComputerUIData = getBusinessComputerUIData
M.acceptJob = acceptJob
M.declineJob = declineJob
M.abandonJob = abandonJob
M.completeJob = completeJob
M.canCompleteJob = canCompleteJob
M.getAbandonPenalty = getAbandonPenalty
M.pullOutVehicle = pullOutVehicle
M.putAwayVehicle = putAwayVehicle
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
M.getBusinessAccountBalance = getBusinessAccountBalance
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

local function onExtensionLoaded()
  return true
end

M.onExtensionLoaded = onExtensionLoaded

return M
