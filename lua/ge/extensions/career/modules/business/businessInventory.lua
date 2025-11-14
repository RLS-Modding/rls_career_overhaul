local M = {}

M.dependencies = {'career_career', 'career_saveSystem', 'gameplay_sites_sitesManager'}

local businessVehicles = {}
local pulledOutVehicles = {}
local spawnedBusinessVehicles = {}

local function getBusinessVehiclesPath(businessId)
  if not career_career.isActive() then return nil end
  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  if not currentSavePath then return nil end
  return currentSavePath .. "/career/rls_career/businesses/" .. businessId .. "/vehicles.json"
end

local function loadBusinessVehicles(businessId)
  if not businessId then return {} end
  
  if businessVehicles[businessId] then
    return businessVehicles[businessId]
  end
  
  local filePath = getBusinessVehiclesPath(businessId)
  if not filePath then return {} end
  
  local data = jsonReadFile(filePath) or {}
  businessVehicles[businessId] = data.vehicles or {}
  
  for _, vehicle in ipairs(businessVehicles[businessId]) do
    if vehicle.vehicleId then
      vehicle.vehicleId = tonumber(vehicle.vehicleId) or vehicle.vehicleId
    end
  end
  
  return businessVehicles[businessId]
end

local function saveBusinessVehicles(businessId, currentSavePath)
  if not businessId or not businessVehicles[businessId] or not currentSavePath then return end
  
  local filePath = currentSavePath .. "/career/rls_career/businesses/" .. businessId .. "/vehicles.json"
  
  local dirPath = string.match(filePath, "^(.*)/[^/]+$")
  if dirPath and not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end
  
  local data = {
    vehicles = businessVehicles[businessId]
  }
  jsonWriteFile(filePath, data, true)
end

local function getBusinessVehicles(businessId)
  return loadBusinessVehicles(businessId)
end

local function storeVehicle(businessId, vehicleData)
  if not businessId or not vehicleData then return false end
  
  local vehicles = loadBusinessVehicles(businessId)
  
  local vehicleId = vehicleData.vehicleId or (#vehicles + 1)
  vehicleId = tonumber(vehicleId) or vehicleId
  vehicleData.vehicleId = vehicleId
  vehicleData.storedTime = os.time()
  
  table.insert(vehicles, vehicleData)
  businessVehicles[businessId] = vehicles
  
  return true, vehicleId
end

local function removeVehicle(businessId, vehicleId)
  if not businessId or not vehicleId then return false end
  
  vehicleId = tonumber(vehicleId) or vehicleId
  local vehicles = loadBusinessVehicles(businessId)
  
  for i, vehicle in ipairs(vehicles) do
    local vehId = tonumber(vehicle.vehicleId) or vehicle.vehicleId
    if vehId == vehicleId then
      table.remove(vehicles, i)
      businessVehicles[businessId] = vehicles
      return true
    end
  end
  
  return false
end

local function getVehicleById(businessId, vehicleId)
  if not businessId or not vehicleId then return nil end
  
  vehicleId = tonumber(vehicleId) or vehicleId
  local vehicles = loadBusinessVehicles(businessId)
  
  for _, vehicle in ipairs(vehicles) do
    local vehId = tonumber(vehicle.vehicleId) or vehicle.vehicleId
    if vehId == vehicleId then
      return vehicle
    end
  end
  
  return nil
end

local function getPulledOutVehicle(businessId)
  return pulledOutVehicles[businessId]
end

local function getBusinessGarage(businessId)
  local business = freeroam_facilities.getFacility("tuningShop", businessId)
  if not business then 
    return nil 
  end
  
  if not business.businessGarageId then 
    return nil 
  end
  
  local businessGarages = freeroam_facilities.getFacilitiesByType("businessGarage")
  if not businessGarages then 
    return nil 
  end
  
  for _, garage in ipairs(businessGarages) do
    if garage.id == business.businessGarageId then
      return garage
    end
  end
  
  return nil
end

local function getBusinessGarageParkingSpots(businessId)
  local garage = getBusinessGarage(businessId)
  if not garage then 
    return {} 
  end
  
  if not garage.sitesFile then 
    return {} 
  end
  
  local sites = gameplay_sites_sitesManager.loadSites(garage.sitesFile)
  if not sites or not sites.parkingSpots then 
    return {} 
  end
  
  local spots = {}
  for _, spotName in ipairs(garage.parkingSpotNames or {}) do
    local spot = sites.parkingSpots.byName[spotName]
    if spot and not spot.missing then
      table.insert(spots, spot)
    end
  end
  
  return spots
end

local function getBusinessGaragePosRot(businessId, veh)
  veh = veh or getPlayerVehicle(0)
  local garage = getBusinessGarage(businessId)
  if not garage then return nil, nil end
  
  local parkingSpots = getBusinessGarageParkingSpots(businessId)
  if #parkingSpots == 0 then return nil, nil end
  
  local parkingSpot = gameplay_sites_sitesManager.getBestParkingSpotForVehicleFromList(veh:getID(), parkingSpots)
  if parkingSpot then
    return parkingSpot.pos, parkingSpot.rot
  end
  
  return parkingSpots[1].pos, parkingSpots[1].rot
end

local function spawnBusinessVehicle(businessId, vehicleId)
  vehicleId = tonumber(vehicleId) or vehicleId
  
  local vehicle = getVehicleById(businessId, vehicleId)
  if not vehicle then 
    log("E", "businessInventory", "spawnBusinessVehicle: Vehicle not found for businessId=" .. tostring(businessId) .. ", vehicleId=" .. tostring(vehicleId))
    return nil 
  end
  
  if not vehicle.vehicleConfig then 
    log("E", "businessInventory", "spawnBusinessVehicle: Vehicle missing vehicleConfig for businessId=" .. tostring(businessId) .. ", vehicleId=" .. tostring(vehicleId))
    return nil 
  end
  
  local modelKey = vehicle.vehicleConfig.model_key or vehicle.model_key
  local configKey = vehicle.vehicleConfig.key or vehicle.config_key
  
  if not modelKey or not configKey then 
    log("E", "businessInventory", "spawnBusinessVehicle: Vehicle missing modelKey or configKey. modelKey=" .. tostring(modelKey) .. ", configKey=" .. tostring(configKey) .. ", businessId=" .. tostring(businessId) .. ", vehicleId=" .. tostring(vehicleId))
    return nil 
  end
  
  local vehicleData = {
    config = configKey,
    autoEnterVehicle = false,
    keepLoaded = true
  }
  
  if vehicle.config and vehicle.config.partsTree then
    vehicleData.config = deepcopy(vehicle.config)
    if vehicle.vars then
      vehicleData.config.vars = deepcopy(vehicle.vars)
    end
  elseif vehicle.vars then
    vehicleData.config = {
      key = configKey,
      vars = deepcopy(vehicle.vars)
    }
  end
  
  local vehObj = core_vehicles.spawnNewVehicle(modelKey, vehicleData)
  
  if vehicle.partConditions and vehObj then
    core_vehicleBridge.executeAction(vehObj, 'initPartConditions', vehicle.partConditions, nil, nil, nil, nil)
  end
  if not vehObj then 
    log("E", "businessInventory", "spawnBusinessVehicle: Failed to spawn vehicle. modelKey=" .. tostring(modelKey) .. ", configKey=" .. tostring(configKey) .. ", businessId=" .. tostring(businessId) .. ", vehicleId=" .. tostring(vehicleId))
    return nil 
  end
  
  if not spawnedBusinessVehicles[businessId] then
    spawnedBusinessVehicles[businessId] = {}
  end
  spawnedBusinessVehicles[businessId][vehicleId] = vehObj:getID()
  
  return vehObj
end

local function teleportToBusinessGarage(businessId, veh, resetVeh)
  resetVeh = resetVeh or false
  local pos, rot = getBusinessGaragePosRot(businessId, veh)
  if pos and rot then
    spawn.safeTeleport(veh, pos, rot, nil, nil, nil, true, resetVeh)
    core_camera.resetCamera(0)
    return true
  end
  return false
end

local function removeBusinessVehicleObject(businessId, vehicleId)
  if not businessId or not vehicleId then return end
  
  vehicleId = tonumber(vehicleId) or vehicleId
  if not spawnedBusinessVehicles[businessId] or not spawnedBusinessVehicles[businessId][vehicleId] then
    return
  end
  
  local vehId = spawnedBusinessVehicles[businessId][vehicleId]
  local vehObj = getObjectByID(vehId)
  if vehObj then
    vehObj:delete()
  end
  
  spawnedBusinessVehicles[businessId][vehicleId] = nil
end

local function pullOutVehicle(businessId, vehicleId)
  if not businessId or not vehicleId then 
    log("E", "businessInventory", "pullOutVehicle: Missing parameters. businessId=" .. tostring(businessId) .. ", vehicleId=" .. tostring(vehicleId))
    return false 
  end
  
  vehicleId = tonumber(vehicleId) or vehicleId
  
  local vehicle = getVehicleById(businessId, vehicleId)
  if not vehicle then 
    log("E", "businessInventory", "pullOutVehicle: Vehicle not found. businessId=" .. tostring(businessId) .. ", vehicleId=" .. tostring(vehicleId))
    local vehicles = loadBusinessVehicles(businessId)
    log("D", "businessInventory", "pullOutVehicle: Available vehicles for businessId=" .. tostring(businessId) .. ": " .. tostring(#vehicles))
    for i, v in ipairs(vehicles) do
      log("D", "businessInventory", "pullOutVehicle: Vehicle[" .. tostring(i) .. "] vehicleId=" .. tostring(v.vehicleId) .. " (type: " .. type(v.vehicleId) .. ")")
    end
    return false 
  end
  
  local existingVehicle = pulledOutVehicles[businessId]
  if existingVehicle then
    local existingId = tonumber(existingVehicle.vehicleId) or existingVehicle.vehicleId
    if existingId ~= vehicleId then
      removeBusinessVehicleObject(businessId, existingVehicle.vehicleId)
    end
  end
  
  pulledOutVehicles[businessId] = vehicle
  
  local vehObj = spawnBusinessVehicle(businessId, vehicleId)
  if vehObj then
    teleportToBusinessGarage(businessId, vehObj, false)
    log("D", "businessInventory", "pullOutVehicle: Successfully pulled out vehicle. businessId=" .. tostring(businessId) .. ", vehicleId=" .. tostring(vehicleId))
  else
    log("E", "businessInventory", "pullOutVehicle: Failed to spawn vehicle. businessId=" .. tostring(businessId) .. ", vehicleId=" .. tostring(vehicleId))
    pulledOutVehicles[businessId] = nil
    return false
  end
  
  return true
end

local function putAwayVehicle(businessId)
  if not businessId then return false end
  
  local vehicle = pulledOutVehicles[businessId]
  if vehicle then
    removeBusinessVehicleObject(businessId, vehicle.vehicleId)
  end
  
  pulledOutVehicles[businessId] = nil
  return true
end

local function getSpawnedVehicleId(businessId, vehicleId)
  if not businessId or not vehicleId then return nil end
  
  vehicleId = tonumber(vehicleId) or vehicleId
  if spawnedBusinessVehicles[businessId] and spawnedBusinessVehicles[businessId][vehicleId] then
    return spawnedBusinessVehicles[businessId][vehicleId]
  end
  return nil
end

local function getBusinessVehicleIdentifier(businessId, vehicleId)
  return "business_" .. tostring(businessId) .. "_" .. tostring(vehicleId)
end

local function getBusinessJobIdentifier(businessId, jobId)
  return "business_" .. tostring(businessId) .. "_job_" .. tostring(jobId)
end

local function getJobIdFromVehicle(businessId, vehicleId)
  if not businessId or not vehicleId then return nil end
  
  vehicleId = tonumber(vehicleId) or vehicleId
  local vehicle = getVehicleById(businessId, vehicleId)
  if vehicle and vehicle.jobId then
    return vehicle.jobId
  end
  return nil
end

local function getBusinessVehicleFromSpawnedId(spawnedVehicleId)
  if not spawnedVehicleId then return nil, nil end
  
  for businessId, vehicles in pairs(spawnedBusinessVehicles) do
    for vehicleId, spawnedId in pairs(vehicles) do
      if spawnedId == spawnedVehicleId then
        return businessId, vehicleId
      end
    end
  end
  
  return nil, nil
end

local function onCareerActivated()
  businessVehicles = {}
  pulledOutVehicles = {}
  spawnedBusinessVehicles = {}
end

local function onSaveCurrentSaveSlot(currentSavePath)
  for businessId, _ in pairs(businessVehicles) do
    saveBusinessVehicles(businessId, currentSavePath)
  end
end

local function updateVehicle(businessId, vehicleId, vehicleData)
  if not businessId or not vehicleId or not vehicleData then return false end
  
  vehicleId = tonumber(vehicleId) or vehicleId
  local vehicles = loadBusinessVehicles(businessId)
  
  for i, vehicle in ipairs(vehicles) do
    local vehId = tonumber(vehicle.vehicleId) or vehicle.vehicleId
    if vehId == vehicleId then
      for key, value in pairs(vehicleData) do
        vehicle[key] = value
      end
      businessVehicles[businessId] = vehicles
      return true
    end
  end
  
  return false
end

M.onCareerActivated = onCareerActivated
M.getBusinessVehicles = getBusinessVehicles
M.storeVehicle = storeVehicle
M.removeVehicle = removeVehicle
M.getVehicleById = getVehicleById
M.updateVehicle = updateVehicle
M.pullOutVehicle = pullOutVehicle
M.putAwayVehicle = putAwayVehicle
M.getPulledOutVehicle = getPulledOutVehicle
M.getBusinessGarage = getBusinessGarage
M.getBusinessGarageParkingSpots = getBusinessGarageParkingSpots
M.getBusinessGaragePosRot = getBusinessGaragePosRot
M.spawnBusinessVehicle = spawnBusinessVehicle
M.teleportToBusinessGarage = teleportToBusinessGarage
M.removeBusinessVehicleObject = removeBusinessVehicleObject
M.getSpawnedVehicleId = getSpawnedVehicleId
M.getBusinessVehicleIdentifier = getBusinessVehicleIdentifier
M.getBusinessJobIdentifier = getBusinessJobIdentifier
M.getJobIdFromVehicle = getJobIdFromVehicle
M.getBusinessVehicleFromSpawnedId = getBusinessVehicleFromSpawnedId
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot

return M

