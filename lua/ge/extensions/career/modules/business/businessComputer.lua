local M = {}

M.dependencies = {'career_career', 'career_saveSystem', 'freeroam_facilities', 'core_vehicles', 'core_jobsystem', 'career_modules_business_businessHelpers'}

local jbeamIO = require('jbeam/io')
local jbeamSlotSystem = require('jbeam/slotSystem')

-- Cache for vehicle info lookup
local vehicleInfoCache = nil

-- Cache for parts tree (keyed by businessId_vehicleId)
local partsTreeCache = {}

-- Function to invalidate cache (useful when vehicles are added/removed)
local function invalidateVehicleInfoCache()
  vehicleInfoCache = nil
end

-- Function to clear vehicle data caches
local function clearVehicleDataCaches()
  partsTreeCache = {}
  if career_modules_business_businessVehicleTuning then
    career_modules_business_businessVehicleTuning.clearTuningDataCache()
  end
end

-- Helper function to get vehicle object from business
local function getBusinessVehicleObject(businessId, vehicleId)
  if not businessId or not vehicleId then return nil end
  
  -- Get spawned vehicle ID from businessInventory
  if career_modules_business_businessInventory then
    local vehId = career_modules_business_businessInventory.getSpawnedVehicleId(businessId, vehicleId)
    if vehId then
      return getObjectByID(vehId)
    end
  end
  
  return nil
end

local function normalizeConfigKey(configKey)
  if not configKey then
    return nil
  end
  -- Config key from getEligibleVehicles might be a path like "vehicles/legran/configurations/legran_s_v6_a.pc"
  -- or just a name like "legran_s_v6_a". We need to extract just the config name.
  if configKey:find("/") then
    -- It's a path, extract the filename without extension
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
    -- It's already just a name, might have extension
    local name, ext = configKey:match("^(.+)%.(.+)$")
    return name or configKey
  end
  return configKey
end

local function getVehicleInfo(modelKey, configKey)
  if not modelKey or not configKey then
    return nil
  end

  -- Normalize config key for matching
  local normalizedConfigKey = normalizeConfigKey(configKey)

  -- Try to get from eligible vehicles cache first (same as vehicleShopping.lua)
  if util_configListGenerator and util_configListGenerator.getEligibleVehicles then
    -- Cache eligible vehicles to avoid repeated calls
    if not vehicleInfoCache then
      vehicleInfoCache = util_configListGenerator.getEligibleVehicles(false, false) or {}
    end

    -- Find matching vehicle (try both original and normalized key)
    for _, vehicleInfo in ipairs(vehicleInfoCache) do
      if vehicleInfo.model_key == modelKey then
        local vehicleKey = normalizeConfigKey(vehicleInfo.key)
        if vehicleInfo.key == configKey or vehicleKey == normalizedConfigKey or vehicleInfo.key == normalizedConfigKey then
          return vehicleInfo
        end
      end
    end
  end

  -- Fallback: try to get config info using core_vehicles.getConfig (same as inventory.lua)
  if core_vehicles and core_vehicles.getConfig then
    local model = core_vehicles.getModel(modelKey)
    if model and not tableIsEmpty(model) then
      local configName = normalizedConfigKey
      local configInfo = core_vehicles.getConfig(modelKey, configName)
      if configInfo then
        -- Build a vehicleInfo-like structure from config
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

  -- Format goal time properly (times are in seconds, format as "X min Y s" if >= 60s)
  local goalTimeFormatted = ""
  local goalTimeSeconds = job.targetTime or 0
  if goalTimeSeconds >= 60 then
    local minutes = math.floor(goalTimeSeconds / 60)
    local seconds = math.floor(goalTimeSeconds % 60 + 0.5)
    if seconds >= 1 then
      goalTimeFormatted = string.format("%d min %d s", minutes, seconds)
    else
      goalTimeFormatted = string.format("%d min", minutes)
    end
  else
    goalTimeFormatted = string.format("%d s", math.floor(goalTimeSeconds + 0.5))
  end
  
  local goal = goalTimeFormatted .. " " .. (job.raceLabel or "")

  -- Time values are stored in seconds
  local baselineTime = job.baseTime or 0
  local currentTime = job.currentTime or job.baseTime or 0
  local goalTime = job.targetTime or 0

  -- Try to get best leaderboard time for this job (checking all race label variations)
  if job.raceLabel and businessId and job.jobId then
    local bestTime = career_modules_business_businessHelpers.getBestLeaderboardTime(businessId, job.jobId, job.raceType, job.raceLabel)
    if bestTime then
      currentTime = bestTime
    end
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
    deadline = job.deadline or "7 days",
    priority = job.priority or "medium"
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
  end

  local totalPartsValue = 0
  for _, part in ipairs(parts) do
    totalPartsValue = totalPartsValue + (part.price or part.value or 0)
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
  local result = career_modules_business_businessInventory.pullOutVehicle(businessId, vehicleId)
  return result
end

local function putAwayVehicle(businessId)
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

-- Function to recursively format parts tree for UI (flattened for easier navigation)
-- Get compatible parts from business inventory for a slot
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
    -- Check if part is compatible with vehicle model (if specified)
    if not vehicleModel or not inventoryPart.vehicleModel or inventoryPart.vehicleModel == vehicleModel then
      -- Get jbeam data for the inventory part
      local partDescription = jbeamIO.getPart(vehicleData.ioCtx, inventoryPart.name)
      if partDescription and jbeamSlotSystem.partFitsSlot(partDescription, slotInfo) then
        -- Get part nice name
        local niceName = inventoryPart.name
        if partDescription.information and partDescription.information.description then
          niceName = type(partDescription.information.description) == "table" and 
                     partDescription.information.description.description or 
                     partDescription.information.description or 
                     inventoryPart.name
        end
        
        -- Get mileage
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

  -- Skip the root node (vehicle itself) - only process its children
  local isRootNode = (currentPath == "/" or currentPath == "" or slotName == "")

  -- Get slot nice name from slotInfo or slotsNiceName
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

  -- Get nice name for chosen part
  local partNiceName = node.chosenPartNiceName or ""
  if node.chosenPartName and availableParts[node.chosenPartName] then
    local partInfo = availableParts[node.chosenPartName]
    local desc = partInfo.description
    partNiceName = type(desc) == "table" and desc.description or desc or node.chosenPartName
    partsNiceName[node.chosenPartName] = partNiceName
  elseif node.chosenPartName then
    partNiceName = node.chosenPartName
  end

  -- Get part info for current node to access slotInfoUi for children
  local partInfo = nil
  if node.chosenPartName and availableParts[node.chosenPartName] then
    partInfo = availableParts[node.chosenPartName]
  end

  -- Get slotInfo for this slot (needed for inventory compatibility check)
  local currentSlotInfo = slotInfo
  if not currentSlotInfo and partInfo and partInfo.slotInfoUi and slotName then
    currentSlotInfo = partInfo.slotInfoUi[slotName]
  end
  
  -- Create entry for this slot if it has available parts (but skip root node)
  if not isRootNode and node.suitablePartNames and #node.suitablePartNames > 0 then
    local availablePartsList = {}
    for _, partName in ipairs(node.suitablePartNames) do
      local partInfoData = availableParts[partName]
      if partInfoData then
        local desc = partInfoData.description
        local niceName = type(desc) == "table" and desc.description or desc or partName

        -- Get part price using jbeamIO.getPart (same as vanilla part shopping)
        local value = 100 -- Default fallback
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

    -- Sort parts alphabetically by niceName
    table.sort(availablePartsList, function(a, b)
      local nameA = string.lower(a.niceName or a.name or "")
      local nameB = string.lower(b.niceName or b.name or "")
      return nameA < nameB
    end)

    -- Get compatible parts from business inventory
    local compatibleInventoryParts = {}
    if businessId and vehicleData and currentSlotInfo then
      compatibleInventoryParts = getCompatiblePartsFromInventory(businessId, currentPath, currentSlotInfo, vehicleData, vehicleModel)
    end
    
    -- Only add if there are available parts or compatible inventory parts
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

  -- Process children recursively
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

-- Function to request parts tree for a business vehicle (triggers hook)
local function requestVehiclePartsTree(businessId, vehicleId)
  if not businessId or not vehicleId then
    guihooks.trigger('businessComputer:onVehiclePartsTree', {
      success = false,
      error = "Missing parameters"
    })
    return
  end

  -- Check cache first (but only if preview vehicle hasn't been modified)
  local cacheKey = businessId .. "_" .. tostring(vehicleId)
  local previewConfig = nil
  if career_modules_business_businessPartCustomization then
    previewConfig = career_modules_business_businessPartCustomization.getPreviewVehicleConfig(businessId)
  end
  
  if partsTreeCache[cacheKey] and not previewConfig then
    -- Return cached data immediately only if no preview vehicle exists
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

  -- Run async to avoid blocking
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

    -- Use preview vehicle config if available (has installed parts), otherwise use stored config
    local configToUse = configKey
    if career_modules_business_businessPartCustomization then
      local previewConfig = career_modules_business_businessPartCustomization.getPreviewVehicleConfig(businessId)
      if previewConfig then
        configToUse = previewConfig
      end
    end

    -- Spawn vehicle temporarily to get parts tree
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

    -- Get vehicle data
    local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehId)
    if not vehicleData or not vehicleData.config or not vehicleData.config.partsTree then
      -- Clean up spawned vehicle
      if vehicleObj then
        vehicleObj:delete()
      end
      guihooks.trigger('businessComputer:onVehiclePartsTree', {
        success = false,
        error = "No parts tree found"
      })
      return
    end

    -- Get available parts
    local availableParts = jbeamIO.getAvailableParts(vehicleData.ioCtx)

    -- Build slots nice names
    local slotsNiceName = {}
    local partsNiceName = {}

    for partName, partInfo in pairs(availableParts) do
      if partInfo.slotInfoUi then
        for slotName, slotInfo in pairs(partInfo.slotInfoUi) do
          slotsNiceName[slotName] = type(slotInfo.description) == "table" and slotInfo.description.description or
                                      slotInfo.description
        end
      end

      -- Get part nice names
      local desc = partInfo.description
      partsNiceName[partName] = type(desc) == "table" and desc.description or desc
    end

    -- Get vehicle model for inventory filtering
    local vehicle = career_modules_business_businessInventory.getVehicleById(businessId, vehicleId)
    local vehicleModel = nil
    if vehicle and vehicle.vehicleConfig then
      vehicleModel = vehicle.vehicleConfig.model_key or vehicle.model_key
    end
    
    -- Format parts tree for UI (returns a flat list of slots with their available parts)
    local partsTreeList = formatPartsTreeForUI(vehicleData.config.partsTree, "", nil, availableParts, slotsNiceName,
      partsNiceName, "/", nil, vehicleData.ioCtx, businessId, vehicleData, vehicleModel)

    -- Clean up spawned vehicle
    if vehicleObj then
      vehicleObj:delete()
    end

    -- Cache the data
    partsTreeCache[cacheKey] = {
      partsTree = partsTreeList,
      slotsNiceName = slotsNiceName,
      partsNiceName = partsNiceName
    }

    -- Trigger hook with data
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

-- Legacy function for backward compatibility (now uses hook internally)
local function getVehiclePartsTree(businessId, vehicleId)
  requestVehiclePartsTree(businessId, vehicleId)
  return nil -- Return nil since data comes via hook
end

-- Forward tuning functions to businessVehicleTuning module
local function requestVehicleTuningData(businessId, vehicleId)
  if career_modules_business_businessVehicleTuning then
    return career_modules_business_businessVehicleTuning.requestVehicleTuningData(businessId, vehicleId)
  end
end

local function getVehicleTuningData(businessId, vehicleId)
  if career_modules_business_businessVehicleTuning then
    return career_modules_business_businessVehicleTuning.getVehicleTuningData(businessId, vehicleId)
  end
  return nil
end

local function applyTuningToVehicle(businessId, vehicleId, tuningVars)
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
  if career_modules_business_businessPartCustomization then
    return career_modules_business_businessPartCustomization.addPartToCart(businessId, vehicleId, currentCart, partToAdd)
  end
  return currentCart or {}
end

local function applyVehicleTuning(businessId, vehicleId, tuningVars, accountId)
  if career_modules_business_businessVehicleTuning then
    return career_modules_business_businessVehicleTuning.applyVehicleTuning(businessId, vehicleId, tuningVars, accountId)
  end
  return false
end

-- Forward part customization functions to businessPartCustomization module
local function initializePreviewVehicle(businessId, vehicleId)
  if career_modules_business_businessPartCustomization then
    return career_modules_business_businessPartCustomization.initializePreviewVehicle(businessId, vehicleId)
  end
  return false
end

local function resetVehicleToOriginal(businessId, vehicleId)
  if career_modules_business_businessPartCustomization then
    return career_modules_business_businessPartCustomization.resetVehicleToOriginal(businessId, vehicleId)
  end
  return false
end

local function applyPartsToVehicle(businessId, vehicleId, parts)
  if career_modules_business_businessPartCustomization then
    return career_modules_business_businessPartCustomization.applyPartsToVehicle(businessId, vehicleId, parts)
  end
  return false
end

local function applyCartPartsToVehicle(businessId, vehicleId, parts)
  if career_modules_business_businessPartCustomization then
    return career_modules_business_businessPartCustomization.applyCartPartsToVehicle(businessId, vehicleId, parts)
  end
  return false
end

local function installPartOnVehicle(businessId, vehicleId, partName, slotPath)
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
  
  local salesTax = 0.07 -- 7% sales tax (matching vanilla)

  -- Calculate subtotal (parts + tuning, before tax)
  local subtotal = 0

  for _, part in ipairs(parts) do
    subtotal = subtotal + (part.price or 0)
  end

  -- Calculate tuning cost properly
  if #tuning > 0 then
    local vehicle = career_modules_business_businessInventory.getPulledOutVehicle(businessId)
    if vehicle and vehicle.vehicleId then
      local originalVars = vehicle.vars or {}
      
      local tuningVars = {}
      for _, change in ipairs(tuning) do
        -- Only process variables, skip categories and subcategories
        if change.type == "variable" and change.varName and change.value ~= nil then
          tuningVars[change.varName] = change.value
        end
      end
      
      local tuningCost = calculateTuningCost(businessId, vehicle.vehicleId, tuningVars, originalVars)
      subtotal = subtotal + tuningCost
    else
      -- Fallback if vehicle not found - only count variables
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
  
  -- Calculate tax and total
  local taxAmount = subtotal * salesTax
  local totalCost = subtotal + taxAmount

  -- Charge from account
  local success = career_modules_bank.payFromAccount({
    money = {
      amount = totalCost,
      canBeNegative = false
    }
  }, accountId)
  if not success then
    return false
  end

  -- Explicitly trigger account update hook to ensure UI gets updated
  if career_modules_bank then
    -- Parse accountId format: "business_" + businessType + "_" + businessId
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

  -- Apply parts
  local vehicle = career_modules_business_businessInventory.getPulledOutVehicle(businessId)
  if vehicle and vehicle.vehicleId then
    -- Apply all parts at once using applyCartPartsToVehicle
    if #parts > 0 then
      applyCartPartsToVehicle(businessId, vehicle.vehicleId, parts)
      
      -- Get preview vehicle config to save
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
        
        -- Update pulled out vehicle reference
        local pulledOutVehicle = career_modules_business_businessInventory.getPulledOutVehicle(businessId)
        if pulledOutVehicle and pulledOutVehicle.vehicleId == vehicle.vehicleId then
          pulledOutVehicle.config = vehicle.config
          pulledOutVehicle.partList = vehicle.partList
        end
        
        -- Find removed parts and add them to business inventory (matching vanilla updateInventory pattern)
        if career_modules_business_businessPartCustomization and career_modules_business_businessPartInventory then
          local removedParts = career_modules_business_businessPartCustomization.findRemovedParts(businessId, vehicle.vehicleId)
          for _, removedPart in ipairs(removedParts) do
            -- Add part to business inventory
            career_modules_business_businessPartInventory.addPart(businessId, removedPart)
          end
        end
      end
    end

    if #tuning > 0 then
      local tuningVars = {}
      for _, change in ipairs(tuning) do
        -- Only process variables, skip categories and subcategories
        if change.type == "variable" and change.varName and change.value ~= nil then
          tuningVars[change.varName] = change.value
        end
      end
      applyVehicleTuning(businessId, vehicle.vehicleId, tuningVars, nil)
    end
  end

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

-- Forward power/weight functions to businessPartCustomization module
function M.onPowerWeightReceived(requestId, power, weight)
  if career_modules_business_businessPartCustomization then
    return career_modules_business_businessPartCustomization.onPowerWeightReceived(requestId, power, weight)
  end
end

local function getVehiclePowerWeight(businessId, vehicleId)
  if career_modules_business_businessPartCustomization then
    return career_modules_business_businessPartCustomization.getVehiclePowerWeight(businessId, vehicleId)
  end
  return nil
end

M.getBusinessComputerUIData = getBusinessComputerUIData
M.acceptJob = acceptJob
M.declineJob = declineJob
M.abandonJob = abandonJob
M.completeJob = function(businessId, jobId)
  return career_modules_business_businessJobManager.completeJob(businessId, jobId)
end
M.canCompleteJob = function(businessId, jobId)
  return career_modules_business_businessJobManager.canCompleteJob(businessId, jobId)
end
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

return M
