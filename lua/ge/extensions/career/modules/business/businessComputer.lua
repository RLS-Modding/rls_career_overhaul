local M = {}

M.dependencies = {
  'career_career',
  'career_saveSystem',
  'freeroam_facilities',
  'career_modules_business_businessManager',
  'career_modules_business_businessJobManager',
  'career_modules_business_businessInventory',
  'career_modules_business_businessPartInventory',
  'util_configListGenerator',
  'extensions.core_vehicle_manager',
  'core_vehicles',
  'core_jobsystem'
}

local jbeamIO = require('jbeam/io')

-- Cache for vehicle info lookup
local vehicleInfoCache = nil

-- Cache for parts tree and tuning data (keyed by businessId_vehicleId)
local partsTreeCache = {}
local tuningDataCache = {}

-- Function to invalidate cache (useful when vehicles are added/removed)
local function invalidateVehicleInfoCache()
  vehicleInfoCache = nil
end

-- Function to clear vehicle data caches
local function clearVehicleDataCaches()
  partsTreeCache = {}
  tuningDataCache = {}
end

local function normalizeConfigKey(configKey)
  if not configKey then return nil end
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
  if not modelKey or not configKey then return nil end
  
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
          Years = configInfo.Years or {min = 1990, max = 2025},
          preview = configInfo.preview
        }
      end
    end
  end
  
  return nil
end

local function formatJobForUI(job, businessId)
  if not job then return nil end
  
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
  
  local goal = string.format("%.1f%s %s", job.targetTime, timeUnit, job.raceLabel or "")
  
  -- Format time values to 1 decimal place
  local baselineTime = job.baseTime or 0
  local currentTime = job.currentTime or job.baseTime or 0
  local goalTime = job.targetTime or 0
  
  return {
    id = tostring(job.jobId),
    jobId = job.jobId,
    vehicleName = vehicleName,
    vehicleYear = vehicleYear or "Unknown",
    vehicleType = vehicleType,
    vehicleImage = vehicleImage,
    goal = goal,
    budget = job.budget or 5000,
    reward = math.floor((job.budget or 5000) * 3),
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
  if not vehicle then return nil end
  
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
  if not businessType or not businessId then return nil end
  
  local business = freeroam_facilities.getFacility(businessType, businessId)
  if not business then return nil end
  
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
  log("D", "businessComputer", "pullOutVehicle: Called with businessId=" .. tostring(businessId) .. ", vehicleId=" .. tostring(vehicleId))
  local result = career_modules_business_businessInventory.pullOutVehicle(businessId, vehicleId)
  log("D", "businessComputer", "pullOutVehicle: Result=" .. tostring(result))
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
local function formatPartsTreeForUI(node, slotName, slotInfo, availableParts, slotsNiceName, partsNiceName, pathPrefix, parentSlotName, ioCtx)
  if not node then return {} end
  
  local result = {}
  local currentPath = node.path or pathPrefix or "/"
  
  -- Skip the root node (vehicle itself) - only process its children
  local isRootNode = (currentPath == "/" or currentPath == "" or slotName == "")
  
  -- Get slot nice name from slotInfo or slotsNiceName
  local slotNiceName = node.slotNiceName or ""
  if not slotNiceName and slotInfo then
    slotNiceName = type(slotInfo.description) == "table" and slotInfo.description.description or slotInfo.description or slotName or ""
  elseif not slotNiceName and slotName and slotsNiceName[slotName] then
    slotNiceName = type(slotsNiceName[slotName]) == "table" and slotsNiceName[slotName].description or slotsNiceName[slotName] or slotName
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
    
    -- Only add if there are available parts
    if #availablePartsList > 0 then
      table.insert(result, {
        id = currentPath,
        path = currentPath,
        slotName = slotName or "",
        slotNiceName = slotNiceName,
        chosenPartName = node.chosenPartName or "",
        partNiceName = partNiceName,
        availableParts = availablePartsList,
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
      local childResults = formatPartsTreeForUI(childNode, childSlotName, childSlotInfo, availableParts, slotsNiceName, partsNiceName, childPath, slotNiceName, ioCtx)
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
    guihooks.trigger('businessComputer:onVehiclePartsTree', {success = false, error = "Missing parameters"})
    return
  end
  
  -- Check cache first
  local cacheKey = businessId .. "_" .. tostring(vehicleId)
  if partsTreeCache[cacheKey] then
    -- Return cached data immediately
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
      guihooks.trigger('businessComputer:onVehiclePartsTree', {success = false, error = "Vehicle not found"})
      return
    end
    
    local modelKey = vehicle.vehicleConfig.model_key or vehicle.model_key
    local configKey = vehicle.vehicleConfig.key or vehicle.config_key
    
    if not modelKey or not configKey then
      guihooks.trigger('businessComputer:onVehiclePartsTree', {success = false, error = "Invalid vehicle config"})
      return
    end
    
    -- Spawn vehicle temporarily to get parts tree
    local vehicleObj = core_vehicles.spawnNewVehicle(modelKey, {
      config = configKey,
      pos = vec3(0, 0, -1000), -- Spawn far away
      rot = quat(0, 0, 0, 1),
      keepLoaded = true,
      autoEnterVehicle = false
    })
    
    if not vehicleObj then
      guihooks.trigger('businessComputer:onVehiclePartsTree', {success = false, error = "Failed to spawn vehicle"})
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
      guihooks.trigger('businessComputer:onVehiclePartsTree', {success = false, error = "No parts tree found"})
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
          slotsNiceName[slotName] = type(slotInfo.description) == "table" and slotInfo.description.description or slotInfo.description
        end
      end
      
      -- Get part nice names
      local desc = partInfo.description
      partsNiceName[partName] = type(desc) == "table" and desc.description or desc
    end
    
    -- Format parts tree for UI (returns a flat list of slots with their available parts)
    local partsTreeList = formatPartsTreeForUI(vehicleData.config.partsTree, "", nil, availableParts, slotsNiceName, partsNiceName, "/", nil, vehicleData.ioCtx)
    
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

function M.onCareerActivated()
end

-- Function to request tuning data for a business vehicle (triggers hook)
local function requestVehicleTuningData(businessId, vehicleId)
  if not businessId or not vehicleId then 
    guihooks.trigger('businessComputer:onVehicleTuningData', {success = false, error = "Missing parameters"})
    return
  end
  
  -- Check cache first
  local cacheKey = businessId .. "_" .. tostring(vehicleId)
  if tuningDataCache[cacheKey] then
    -- Return cached data immediately
    guihooks.trigger('businessComputer:onVehicleTuningData', {
      success = true,
      businessId = businessId,
      vehicleId = vehicleId,
      tuningData = tuningDataCache[cacheKey]
    })
    return
  end
  
  -- Run async to avoid blocking
  core_jobsystem.create(function(job)
    local vehicle = career_modules_business_businessInventory.getVehicleById(businessId, vehicleId)
    if not vehicle or not vehicle.vehicleConfig then
      guihooks.trigger('businessComputer:onVehicleTuningData', {success = false, error = "Vehicle not found"})
      return
    end
    
    local modelKey = vehicle.vehicleConfig.model_key or vehicle.model_key
    local configKey = vehicle.vehicleConfig.key or vehicle.config_key
    
    if not modelKey or not configKey then
      guihooks.trigger('businessComputer:onVehicleTuningData', {success = false, error = "Invalid vehicle config"})
      return
    end
    
    -- Spawn vehicle temporarily to get tuning data
    local vehicleObj = core_vehicles.spawnNewVehicle(modelKey, {
      config = configKey,
      pos = vec3(0, 0, -1000), -- Spawn far away
      rot = quat(0, 0, 0, 1),
      keepLoaded = true,
      autoEnterVehicle = false
    })
    
    if not vehicleObj then
      guihooks.trigger('businessComputer:onVehicleTuningData', {success = false, error = "Failed to spawn vehicle"})
      return
    end
    
    local vehId = vehicleObj:getID()
    
    -- Get vehicle data and tuning variables
    local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehId)
    if not vehicleData or not vehicleData.vdata or not vehicleData.vdata.variables then
      -- Clean up spawned vehicle
      if vehicleObj then
        vehicleObj:delete()
      end
      guihooks.trigger('businessComputer:onVehicleTuningData', {success = false, error = "No tuning variables found"})
      return
    end
    
    -- Get current vars from vehicle config (if any)
    local currentVars = vehicle.vars or {}
    
    -- Get all available tuning variables
    local tuningVariables = deepcopy(vehicleData.vdata.variables)
    
    -- Merge current vars with defaults and calculate display values
    for varName, varData in pairs(tuningVariables) do
      -- Use current var value if it exists, otherwise use the default val from the variable definition
      if currentVars[varName] ~= nil then
        varData.val = currentVars[varName]
      elseif varData.val == nil then
        -- If no val is set, use min as baseline (or 0 if min is nil)
        varData.val = varData.min or 0
      end
      
      -- Calculate display values (valDis, minDis, maxDis, stepDis)
      -- These are typically the same as val/min/max/step unless there's a conversion factor
      varData.valDis = varData.val or (varData.min or 0)
      varData.minDis = varData.min or 0
      varData.maxDis = varData.max or 100
      -- Use step if available, otherwise calculate a reasonable default based on range
      if varData.step and varData.step > 0 then
        varData.stepDis = varData.step
      else
        -- Calculate step as 1/1000th of the range, but ensure it's at least 0.001
        local range = math.abs((varData.max or 100) - (varData.min or 0))
        varData.stepDis = math.max(0.001, math.min(1, range / 1000))
      end
      
      -- Ensure valDis is within bounds
      if varData.valDis < varData.minDis then
        varData.valDis = varData.minDis
      elseif varData.valDis > varData.maxDis then
        varData.valDis = varData.maxDis
      end
    end
    
    -- Clean up spawned vehicle
    if vehicleObj then
      vehicleObj:delete()
    end
    
    -- Cache the data
    tuningDataCache[cacheKey] = tuningVariables
    
    -- Trigger hook with data
    guihooks.trigger('businessComputer:onVehicleTuningData', {
      success = true,
      businessId = businessId,
      vehicleId = vehicleId,
      tuningData = tuningVariables
    })
  end)
end

-- Legacy function for backward compatibility (now uses hook internally)
local function getVehicleTuningData(businessId, vehicleId)
  requestVehicleTuningData(businessId, vehicleId)
  return nil -- Return nil since data comes via hook
end

-- Function to apply tuning settings to a business vehicle
local function applyVehicleTuning(businessId, vehicleId, tuningVars)
  if not businessId or not vehicleId or not tuningVars then return false end
  
  local vehicle = career_modules_business_businessInventory.getVehicleById(businessId, vehicleId)
  if not vehicle then return false end
  
  -- Initialize vars if it doesn't exist
  if not vehicle.vars then
    vehicle.vars = {}
  end
  
  -- Merge new tuning vars with existing ones
  for varName, value in pairs(tuningVars) do
    vehicle.vars[varName] = value
  end
  
  -- Update pulled out vehicle if it's the same one
  local pulledOutVehicle = career_modules_business_businessInventory.getPulledOutVehicle(businessId)
  if pulledOutVehicle and pulledOutVehicle.vehicleId == vehicleId then
    pulledOutVehicle.vars = vehicle.vars
  end
  
  -- Save the updated vehicle data
  career_modules_business_businessInventory.updateVehicle(businessId, vehicleId, {vars = vehicle.vars})
  
  return true
end

M.getBusinessComputerUIData = getBusinessComputerUIData
M.acceptJob = acceptJob
M.declineJob = declineJob
M.abandonJob = abandonJob
M.pullOutVehicle = pullOutVehicle
M.putAwayVehicle = putAwayVehicle
M.getActiveJobs = getActiveJobs
M.getNewJobs = getNewJobs
M.getVehiclePartsTree = getVehiclePartsTree
M.requestVehiclePartsTree = requestVehiclePartsTree
M.getVehicleTuningData = getVehicleTuningData
M.requestVehicleTuningData = requestVehicleTuningData
M.applyVehicleTuning = applyVehicleTuning
M.clearVehicleDataCaches = clearVehicleDataCaches

return M

