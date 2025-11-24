local M = {}

M.dependencies = {'career_career', 'career_saveSystem', 'gameplay_sites_sitesManager'}

local businessVehicles = {}
local pulledOutVehicles = {}
local spawnedBusinessVehicles = {}
local vehicleIdCounters = {}
local pendingConfigCallbacks = {}

local function clearCachesForVehicleJob(businessId, vehicle)
  if not vehicle then
    return
  end
  if career_modules_business_businessComputer and career_modules_business_businessComputer.clearBusinessCachesForJob then
    career_modules_business_businessComputer.clearBusinessCachesForJob(businessId, vehicle.jobId)
  end
end

local function getBusinessVehiclesPath(businessId)
  if not career_career.isActive() then
    return nil
  end
  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  if not currentSavePath then
    return nil
  end
  return currentSavePath .. "/career/rls_career/businesses/" .. businessId .. "/vehicles.json"
end

local function loadBusinessVehicles(businessId)
  if not businessId then
    return {}
  end

  if businessVehicles[businessId] then
    return businessVehicles[businessId]
  end

  local filePath = getBusinessVehiclesPath(businessId)
  if not filePath then
    return {}
  end

  local data = jsonReadFile(filePath) or {}
  businessVehicles[businessId] = data.vehicles or {}

  for _, vehicle in ipairs(businessVehicles[businessId]) do
    if vehicle.vehicleId then
      vehicle.vehicleId = tonumber(vehicle.vehicleId) or vehicle.vehicleId
    end
  end

  local maxId = 0
  for _, vehicle in ipairs(businessVehicles[businessId]) do
    local vehId = tonumber(vehicle.vehicleId)
    if vehId and vehId > maxId then
      maxId = vehId
    end
  end
  vehicleIdCounters[businessId] = math.max((vehicleIdCounters[businessId] or 1), maxId + 1)

  return businessVehicles[businessId]
end

local function getNextVehicleId(businessId)
  vehicleIdCounters[businessId] = vehicleIdCounters[businessId] or 1
  local nextId = vehicleIdCounters[businessId]
  vehicleIdCounters[businessId] = nextId + 1
  return nextId
end

local function saveBusinessVehicles(businessId, currentSavePath)
  if not businessId or not businessVehicles[businessId] or not currentSavePath then
    return
  end

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
  if not businessId or not vehicleData then
    return false
  end

  local vehicles = loadBusinessVehicles(businessId)

  local vehicleId = vehicleData.vehicleId
  if vehicleId == nil then
    vehicleId = getNextVehicleId(businessId)
  end
  vehicleId = tonumber(vehicleId) or vehicleId
  if type(vehicleId) == "number" then
    local nextId = vehicleId + 1
    vehicleIdCounters[businessId] = math.max(vehicleIdCounters[businessId] or nextId, nextId)
  end
  vehicleData.vehicleId = vehicleId
  vehicleData.storedTime = os.time()

  table.insert(vehicles, vehicleData)
  businessVehicles[businessId] = vehicles

  return true, vehicleId
end

local function removeVehicle(businessId, vehicleId)
  if not businessId or not vehicleId then
    return false
  end

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
  if not businessId or not vehicleId then
    return nil
  end

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

local function normalizeVehicleId(vehicleId)
  if vehicleId == nil then
    return nil
  end
  return tonumber(vehicleId) or vehicleId
end

local function ensurePulledOutState(businessId)
  if not pulledOutVehicles[businessId] then
    pulledOutVehicles[businessId] = {
      vehicles = {},
      activeVehicleId = nil,
      spotAssignments = {}
    }
  end
  return pulledOutVehicles[businessId]
end

local function findPulledOutVehicleIndex(state, vehicleId)
  if not state or not state.vehicles then
    return nil
  end
  for index, vehicle in ipairs(state.vehicles) do
    if normalizeVehicleId(vehicle.vehicleId) == vehicleId then
      return index
    end
  end
  return nil
end

local function getPulledOutVehicles(businessId)
  local state = pulledOutVehicles[businessId]
  if not state or not state.vehicles then
    return {}
  end
  return state.vehicles
end

local function getActiveVehicle(businessId)
  local state = pulledOutVehicles[businessId]
  if not state or not state.vehicles then
    return nil
  end
  if state.activeVehicleId then
    local index = findPulledOutVehicleIndex(state, state.activeVehicleId)
    if index then
      return state.vehicles[index]
    end
  end
  return state.vehicles[1]
end

local function setActiveVehicle(businessId, vehicleId)
  if not businessId or not vehicleId then
    return false
  end
  local state = pulledOutVehicles[businessId]
  if not state then
    return false
  end
  local normalizedId = normalizeVehicleId(vehicleId)
  local index = findPulledOutVehicleIndex(state, normalizedId)
  if not index then
    return false
  end
  state.activeVehicleId = normalizedId
  return true
end

local function getPulledOutVehicle(businessId)
  return getActiveVehicle(businessId)
end

local function getBusinessGarage(businessType, businessId)
  local business = freeroam_facilities.getFacility(businessType, businessId)
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

local function getBusinessGarageParkingSpots(businessType, businessId)
  local garage = getBusinessGarage(businessType, businessId)
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

local function getBusinessGaragePosRot(businessType, businessId, veh, spotIndex)
  veh = veh or getPlayerVehicle(0)
  local garage = getBusinessGarage(businessType, businessId)
  if not garage then
    return nil, nil
  end

  local parkingSpots = getBusinessGarageParkingSpots(businessType, businessId)
  if #parkingSpots == 0 then
    return nil, nil
  end

  if spotIndex and parkingSpots[spotIndex] then
    local spot = parkingSpots[spotIndex]
    return spot.pos, spot.rot
  end

  local parkingSpot = gameplay_sites_sitesManager.getBestParkingSpotForVehicleFromList(veh:getID(), parkingSpots)
  if parkingSpot then
    return parkingSpot.pos, parkingSpot.rot
  end

  return parkingSpots[1].pos, parkingSpots[1].rot
end

local function getVisualValueFromMileage(mileage)
  if not mileage then
    return nil
  end
  return career_modules_vehicleShopping.getVisualValueFromMileage(mileage)
end

local function requestAndStorePartConditions(vehicle, vehObj)
  if not vehObj or not vehicle then
    return
  end
  core_vehicleBridge.requestValue(vehObj, function(res)
    if not res or not res.result then
      return
    end
    vehicle.partConditions = deepcopy(res.result)
  end, 'getPartConditions')
end

local function applyPartConditionsForVehicle(vehicle, vehObj)
  if not vehObj or not vehicle then
    return
  end

  if vehicle.partConditions then
    log("D", "businessInventory",
      "applyPartConditionsForVehicle: Using stored partConditions for vehicleId=" .. tostring(vehicle.vehicleId))
    core_vehicleBridge.executeAction(vehObj, 'initPartConditions', vehicle.partConditions)
    return
  end

  local mileage = tonumber(vehicle.mileage or 0)
  if mileage > 0 then
    local visualValue = getVisualValueFromMileage(mileage) or 1
    print("applyPartConditionsForVehicle: mileage=" .. tostring(mileage) .. ", visualValue=" .. tostring(visualValue))
    vehObj:queueLuaCommand(string.format("partCondition.initConditions(nil, %d, nil, %f)", mileage, visualValue))
    requestAndStorePartConditions(vehicle, vehObj)
    return
  end

  log("D", "businessInventory",
    "applyPartConditionsForVehicle: No mileage or partConditions, requesting default for vehicleId=" ..
      tostring(vehicle.vehicleId))
  requestAndStorePartConditions(vehicle, vehObj)
end

local function spawnBusinessVehicle(businessId, vehicleId)
  vehicleId = tonumber(vehicleId) or vehicleId

  local vehicle = getVehicleById(businessId, vehicleId)
  if not vehicle then
    log("E", "businessInventory",
      "spawnBusinessVehicle: Vehicle not found for businessId=" .. tostring(businessId) .. ", vehicleId=" ..
        tostring(vehicleId))
    return nil
  end

  if not vehicle.vehicleConfig then
    log("E", "businessInventory",
      "spawnBusinessVehicle: Vehicle missing vehicleConfig for businessId=" .. tostring(businessId) .. ", vehicleId=" ..
        tostring(vehicleId))
    return nil
  end

  local modelKey = vehicle.vehicleConfig.model_key or vehicle.model_key
  local configKey = vehicle.vehicleConfig.key or vehicle.config_key

  if not modelKey or not configKey then
    log("E", "businessInventory",
      "spawnBusinessVehicle: Vehicle missing modelKey or configKey. modelKey=" .. tostring(modelKey) .. ", configKey=" ..
        tostring(configKey) .. ", businessId=" .. tostring(businessId) .. ", vehicleId=" .. tostring(vehicleId))
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

  if not vehObj then
    log("E", "businessInventory",
      "spawnBusinessVehicle: Failed to spawn vehicle. modelKey=" .. tostring(modelKey) .. ", configKey=" ..
        tostring(configKey) .. ", businessId=" .. tostring(businessId) .. ", vehicleId=" .. tostring(vehicleId))
    return nil
  end

  core_vehicleBridge.requestValue(vehObj, function()
    applyPartConditionsForVehicle(vehicle, vehObj)
  end, 'ping')

  if not spawnedBusinessVehicles[businessId] then
    spawnedBusinessVehicles[businessId] = {}
  end
  spawnedBusinessVehicles[businessId][vehicleId] = vehObj:getID()

  return vehObj
end

local function teleportToBusinessGarage(businessType, businessId, veh, resetVeh, spotIndex)
  resetVeh = resetVeh or false
  local pos, rot = getBusinessGaragePosRot(businessType, businessId, veh, spotIndex)
  if pos and rot then
    spawn.safeTeleport(veh, pos, rot, nil, nil, nil, true, resetVeh)
    core_camera.resetCamera(0)
    return true
  end
  return false
end

local function removeBusinessVehicleObject(businessId, vehicleId)
  if not businessId or not vehicleId then
    return
  end

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

local function getAvailableParkingSpotIndex(businessType, businessId, state)
  local parkingSpots = getBusinessGarageParkingSpots(businessType, businessId)
  if #parkingSpots == 0 then
    return nil
  end
  local used = {}
  for _, index in pairs(state.spotAssignments or {}) do
    if index then
      used[index] = true
    end
  end
  for idx = 1, #parkingSpots do
    if not used[idx] then
      return idx
    end
  end
  return ((#state.vehicles) % #parkingSpots) + 1
end

local function pullOutVehicle(businessType, businessId, vehicleId)
  if not businessType or not businessId or not vehicleId then
    log("E", "businessInventory",
      "pullOutVehicle: Missing parameters. businessType=" .. tostring(businessType) .. ", businessId=" ..
        tostring(businessId) .. ", vehicleId=" .. tostring(vehicleId))
    return false
  end

  local normalizedVehicleId = normalizeVehicleId(vehicleId)
  if not normalizedVehicleId then
    return false
  end

  local vehicle = getVehicleById(businessId, normalizedVehicleId)
  if not vehicle then
    log("E", "businessInventory", "pullOutVehicle: Vehicle not found. businessId=" .. tostring(businessId) ..
      ", vehicleId=" .. tostring(vehicleId))
    local vehicles = loadBusinessVehicles(businessId)
    log("D", "businessInventory",
      "pullOutVehicle: Available vehicles for businessId=" .. tostring(businessId) .. ": " .. tostring(#vehicles))
    for i, v in ipairs(vehicles) do
      log("D", "businessInventory",
        "pullOutVehicle: Vehicle[" .. tostring(i) .. "] vehicleId=" .. tostring(v.vehicleId) .. " (type: " ..
          type(v.vehicleId) .. ")")
    end
    return false
  end

  local state = ensurePulledOutState(businessId)
  local existingIndex = findPulledOutVehicleIndex(state, normalizedVehicleId)
  if existingIndex then
    state.activeVehicleId = normalizedVehicleId
    return true
  end

  local vehObj = spawnBusinessVehicle(businessId, normalizedVehicleId)
  if not vehObj then
    log("E", "businessInventory", "pullOutVehicle: Failed to spawn vehicle. businessId=" .. tostring(businessId) ..
      ", vehicleId=" .. tostring(vehicleId))
    if #state.vehicles == 0 then
      pulledOutVehicles[businessId] = nil
    end
    return false
  end

  table.insert(state.vehicles, vehicle)
  state.activeVehicleId = normalizedVehicleId
  state.spotAssignments = state.spotAssignments or {}
  local spotIndex = getAvailableParkingSpotIndex(businessType, businessId, state)
  state.spotAssignments[normalizedVehicleId] = spotIndex
  teleportToBusinessGarage(businessType, businessId, vehObj, false, spotIndex)
  log("D", "businessInventory",
    "pullOutVehicle: Successfully pulled out vehicle. businessId=" .. tostring(businessId) .. ", vehicleId=" ..
      tostring(vehicleId))

  local callbackId = tostring(businessId) .. "_" .. tostring(normalizedVehicleId) .. "_" .. tostring(os.time())
  pendingConfigCallbacks[callbackId] = {
    businessId = businessId,
    vehicleId = normalizedVehicleId
  }

  dump(vehicle)
  if not vehicle.config then
    vehObj:queueLuaCommand([[
        local configData = serialize(v.config)
        obj:queueGameEngineLua("career_modules_business_businessInventory.onVehicleConfigReceived(']] .. callbackId ..
                             [[', " .. configData .. ")")
      ]])
  end

  return true
end


local function putAwayVehicle(businessId, vehicleId)
  if not businessId then
    return false
  end

  local state = pulledOutVehicles[businessId]
  if not state or not state.vehicles then
    pulledOutVehicles[businessId] = nil
    return true
  end

  if not vehicleId then
    for _, vehicle in ipairs(state.vehicles) do
      clearCachesForVehicleJob(businessId, vehicle)
      removeBusinessVehicleObject(businessId, vehicle.vehicleId)
    end
    pulledOutVehicles[businessId] = nil
    return true
  end

  local normalizedVehicleId = normalizeVehicleId(vehicleId)
  local index = findPulledOutVehicleIndex(state, normalizedVehicleId)
  if not index then
    return false
  end

  local vehicle = state.vehicles[index]
  clearCachesForVehicleJob(businessId, vehicle)
  removeBusinessVehicleObject(businessId, vehicle.vehicleId)
  table.remove(state.vehicles, index)
  if state.spotAssignments then
    state.spotAssignments[normalizedVehicleId] = nil
  end
  if state.activeVehicleId == normalizedVehicleId then
    state.activeVehicleId = state.vehicles[1] and normalizeVehicleId(state.vehicles[1].vehicleId) or nil
  end
  if #state.vehicles == 0 then
    pulledOutVehicles[businessId] = nil
  end

  return true
end

local function getSpawnedVehicleId(businessId, vehicleId)
  if not businessId or not vehicleId then
    return nil
  end

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
  if not businessId or not vehicleId then
    return nil
  end

  vehicleId = tonumber(vehicleId) or vehicleId
  local vehicle = getVehicleById(businessId, vehicleId)
  if vehicle and vehicle.jobId then
    return vehicle.jobId
  end
  return nil
end

local function getBusinessVehicleFromSpawnedId(spawnedVehicleId)
  if not spawnedVehicleId then
    return nil, nil
  end

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
  vehicleIdCounters = {}
end

local function onSaveCurrentSaveSlot(currentSavePath)
  for businessId, _ in pairs(businessVehicles) do
    saveBusinessVehicles(businessId, currentSavePath)
  end
end

local function updateVehicle(businessId, vehicleId, vehicleData)
  if not businessId or not vehicleId or not vehicleData then
    return false
  end

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

local function onVehicleConfigReceived(callbackId, config)
  local callbackData = pendingConfigCallbacks[callbackId]
  if not callbackData then
    return
  end

  pendingConfigCallbacks[callbackId] = nil

  local businessId = callbackData.businessId
  local vehicleId = callbackData.vehicleId

  if not config then
    return
  end

  log("D", "businessInventory", "onVehicleConfigReceived: Syncing config for vehicle " .. tostring(vehicleId))
  updateVehicle(businessId, vehicleId, {
    config = config,
    vars = config.vars
  })
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
M.getPulledOutVehicles = getPulledOutVehicles
M.getActiveVehicle = getActiveVehicle
M.setActiveVehicle = setActiveVehicle
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
M.onVehicleConfigReceived = onVehicleConfigReceived
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot

return M
