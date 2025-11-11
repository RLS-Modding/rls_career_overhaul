local M = {}

M.dependencies = {'career_career', 'career_saveSystem', 'freeroam_facilities', 'core_vehicles', 'spawn', 'gameplay_sites_sitesManager'}

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
  
  return businessVehicles[businessId]
end

local function saveBusinessVehicles(businessId)
  if not businessId or not businessVehicles[businessId] then return end
  
  local filePath = getBusinessVehiclesPath(businessId)
  if not filePath then return end
  
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
  vehicleData.vehicleId = vehicleId
  vehicleData.storedTime = os.time()
  
  table.insert(vehicles, vehicleData)
  businessVehicles[businessId] = vehicles
  
  saveBusinessVehicles(businessId)
  return true, vehicleId
end

local function removeVehicle(businessId, vehicleId)
  if not businessId or not vehicleId then return false end
  
  local vehicles = loadBusinessVehicles(businessId)
  
  for i, vehicle in ipairs(vehicles) do
    if vehicle.vehicleId == vehicleId then
      table.remove(vehicles, i)
      businessVehicles[businessId] = vehicles
      saveBusinessVehicles(businessId)
      return true
    end
  end
  
  return false
end

local function getVehicleById(businessId, vehicleId)
  local vehicles = loadBusinessVehicles(businessId)
  
  for _, vehicle in ipairs(vehicles) do
    if vehicle.vehicleId == vehicleId then
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
    log("E", "businessInventory", "getBusinessGarage: Could not find business facility")
    return nil 
  end
  
  if not business.businessGarageId then 
    log("E", "businessInventory", "getBusinessGarage: Business missing businessGarageId")
    return nil 
  end
  
  log("D", "businessInventory", "getBusinessGarage: Looking for garage with id=" .. tostring(business.businessGarageId))
  
  local businessGarages = freeroam_facilities.getFacilitiesByType("businessGarage")
  if not businessGarages then 
    log("E", "businessInventory", "getBusinessGarage: Could not get businessGarages facilities")
    return nil 
  end
  
  for _, garage in ipairs(businessGarages) do
    if garage.id == business.businessGarageId then
      log("D", "businessInventory", "getBusinessGarage: Found garage " .. tostring(garage.id))
      return garage
    end
  end
  
  log("E", "businessInventory", "getBusinessGarage: Garage not found with id=" .. tostring(business.businessGarageId))
  return nil
end

local function getBusinessGarageParkingSpots(businessId)
  local garage = getBusinessGarage(businessId)
  if not garage then 
    log("E", "businessInventory", "getBusinessGarageParkingSpots: Could not find business garage for businessId=" .. tostring(businessId))
    return {} 
  end
  
  if not garage.sitesFile then 
    log("E", "businessInventory", "getBusinessGarageParkingSpots: Garage missing sitesFile")
    return {} 
  end
  
  log("D", "businessInventory", "getBusinessGarageParkingSpots: Loading sites from " .. tostring(garage.sitesFile))
  
  local sites = gameplay_sites_sitesManager.loadSites(garage.sitesFile)
  if not sites or not sites.parkingSpots then 
    log("E", "businessInventory", "getBusinessGarageParkingSpots: Could not load sites or parkingSpots missing")
    return {} 
  end
  
  local spots = {}
  for _, spotName in ipairs(garage.parkingSpotNames or {}) do
    local spot = sites.parkingSpots.byName[spotName]
    if spot and not spot.missing then
      table.insert(spots, spot)
      log("D", "businessInventory", "getBusinessGarageParkingSpots: Found parking spot " .. tostring(spotName))
    else
      log("W", "businessInventory", "getBusinessGarageParkingSpots: Parking spot not found or missing: " .. tostring(spotName))
    end
  end
  
  log("D", "businessInventory", "getBusinessGarageParkingSpots: Found " .. tostring(#spots) .. " parking spots")
  
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
  local vehicle = getVehicleById(businessId, vehicleId)
  if not vehicle then 
    log("E", "businessInventory", "spawnBusinessVehicle: Vehicle not found")
    return nil 
  end
  
  if not vehicle.vehicleConfig then 
    log("E", "businessInventory", "spawnBusinessVehicle: Vehicle missing vehicleConfig. Vehicle data: " .. dumpsz(vehicle, 2))
    return nil 
  end
  
  local modelKey = vehicle.vehicleConfig.model_key or vehicle.model_key
  local configKey = vehicle.vehicleConfig.key or vehicle.config_key
  
  if not modelKey or not configKey then 
    log("E", "businessInventory", "spawnBusinessVehicle: Missing model_key or key. modelKey=" .. tostring(modelKey) .. ", configKey=" .. tostring(configKey))
    return nil 
  end
  
  log("D", "businessInventory", "spawnBusinessVehicle: Spawning vehicle model=" .. tostring(modelKey) .. ", config=" .. tostring(configKey))
  
  local vehicleData = {
    config = configKey,
    autoEnterVehicle = false,
    keepLoaded = true
  }
  
  local vehObj = core_vehicles.spawnNewVehicle(modelKey, vehicleData)
  if not vehObj then 
    log("E", "businessInventory", "spawnBusinessVehicle: core_vehicles.spawnNewVehicle returned nil")
    return nil 
  end
  
  log("D", "businessInventory", "spawnBusinessVehicle: Vehicle spawned successfully with ID=" .. tostring(vehObj:getID()))
  
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
  if not businessId or not vehicleId then return false end
  
  log("D", "businessInventory", "pullOutVehicle: Called with businessId=" .. tostring(businessId) .. ", vehicleId=" .. tostring(vehicleId))
  
  local vehicle = getVehicleById(businessId, vehicleId)
  if not vehicle then 
    log("E", "businessInventory", "pullOutVehicle: Vehicle not found for businessId=" .. tostring(businessId) .. ", vehicleId=" .. tostring(vehicleId))
    return false 
  end
  
  local existingVehicle = pulledOutVehicles[businessId]
  if existingVehicle and existingVehicle.vehicleId ~= vehicleId then
    log("D", "businessInventory", "pullOutVehicle: Removing existing vehicle " .. tostring(existingVehicle.vehicleId))
    removeBusinessVehicleObject(businessId, existingVehicle.vehicleId)
  end
  
  pulledOutVehicles[businessId] = vehicle
  
  log("D", "businessInventory", "pullOutVehicle: Spawning vehicle...")
  local vehObj = spawnBusinessVehicle(businessId, vehicleId)
  if vehObj then
    log("D", "businessInventory", "pullOutVehicle: Vehicle spawned, teleporting to garage...")
    local success = teleportToBusinessGarage(businessId, vehObj, false)
    if not success then
      log("W", "businessInventory", "pullOutVehicle: Failed to teleport vehicle to business garage")
    else
      log("D", "businessInventory", "pullOutVehicle: Vehicle successfully pulled out and teleported")
    end
  else
    log("E", "businessInventory", "pullOutVehicle: Failed to spawn vehicle")
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
  if spawnedBusinessVehicles[businessId] and spawnedBusinessVehicles[businessId][vehicleId] then
    return spawnedBusinessVehicles[businessId][vehicleId]
  end
  return nil
end

function M.onCareerActivated()
  businessVehicles = {}
  pulledOutVehicles = {}
  spawnedBusinessVehicles = {}
end

local function updateVehicle(businessId, vehicleId, vehicleData)
  if not businessId or not vehicleId or not vehicleData then return false end
  
  local vehicles = loadBusinessVehicles(businessId)
  
  for i, vehicle in ipairs(vehicles) do
    if vehicle.vehicleId == vehicleId then
      -- Merge the new data with existing vehicle data
      for key, value in pairs(vehicleData) do
        vehicle[key] = value
      end
      businessVehicles[businessId] = vehicles
      saveBusinessVehicles(businessId)
      return true
    end
  end
  
  return false
end

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

return M

