-- Business fleet spawning, garage placement, removal, delivery and pull-out.
-- Read owner inputs, spawn and placement helpers, garage spots, delivery, then pull-out and the returned API.
local part = {}

-- Each construction shares state and helpers with that owner load.
function part.new(inputs)
  local fleetState = inputs.fleetState

  -- Spawning --------------------------------------------------------------------------------------

  local function buildSpawnData(vehicle, configKey)
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
    return vehicleData
  end

  -- Restores the stored part conditions once the new vehicle answers its first ping.
  local function applySpawnPartConditions(businessId, vehicle, vehObj)
    if vehicle.fleetRepairBaselinePending then
      core_vehicleBridge.requestValue(vehObj, function()
        core_vehicleBridge.executeAction(vehObj, 'initPartConditions', {}, tonumber(vehicle.mileage) or 0, 1, 1)
        inputs.parts.condition.requestFleetRepairBaseline(businessId, vehicle, vehObj)
      end, 'ping')
    elseif vehicle.partConditions and inputs.businessPartConditions then
      inputs.businessPartConditions.applyInitPartConditions(
        vehObj, vehicle.partConditions, 0, 1, 1, inputs.parts.condition.getPartConditionApplyOpts(vehicle))
    else
      core_vehicleBridge.requestValue(vehObj, function()
        inputs.parts.condition.applyPartConditionsForVehicle(vehicle, vehObj, businessId)
      end, 'ping')
    end
  end

  local function spawnBusinessVehicle(businessId, vehicleId)
    businessId = inputs.normalizeBusinessId(businessId)
    vehicleId = tonumber(vehicleId) or vehicleId

    local vehicle = inputs.getVehicleById(businessId, vehicleId)
    if not vehicle then
      return nil
    end

    local existingSpawnId = inputs.getSpawnedVehicleId(businessId, vehicleId)
    if existingSpawnId then
      local existingObj = getObjectByID(existingSpawnId)
      if existingObj then
        return existingObj
      end
    end

    if not vehicle.vehicleConfig then
      return nil
    end

    local modelKey = vehicle.vehicleConfig.model_key or vehicle.model_key
    local configKey = vehicle.vehicleConfig.key or vehicle.config_key

    if not modelKey or not configKey then
      return nil
    end

    local vehObj = core_vehicles.spawnNewVehicle(modelKey, buildSpawnData(vehicle, configKey))

    if not vehObj then
      return nil
    end

    vehObj:queueLuaCommand("extensions.load('overhaulDamageState')")
    applySpawnPartConditions(businessId, vehicle, vehObj)

    if not fleetState.spawnedBusinessVehicles[businessId] then
      fleetState.spawnedBusinessVehicles[businessId] = {}
    end
    fleetState.spawnedBusinessVehicles[businessId][vehicleId] = vehObj:getID()

    if overhaul_career_career.isActive() then
      overhaul_career_maintenance_tireSystem.registerBusinessVehicle(businessId, vehicleId, vehObj:getID())
    end

    return vehObj
  end

  -- Ground placement ------------------------------------------------------------------------------

  local function teleportVehicleExact(veh, pos, rot, resetVeh, applyHeadingFlip)
    if not veh or not pos or not rot then
      return false
    end
    -- Bay positions describe the vehicle center. Stock placement finds the static
    -- floor and accounts for the refnode offset without burying the box below it.
    -- safeTeleport already flips the heading used by site parking spots.
    local spawnRot = applyHeadingFlip == true and rot or (quat(0, 0, 1, 0) * rot)
    return spawn.safeTeleport(veh, pos, spawnRot, nil, nil, nil, true, resetVeh == true) ~= false
  end

  -- Garage spots ----------------------------------------------------------------------------------

  -- The spot for a vehicle: a free spot if one is left, otherwise the best of all spots.
  local function pickParkingSpot(veh, parkingSpots, businessId)
    local usedSpotIndexes = {}
    local pulledOut = fleetState.pulledOutVehicles[inputs.normalizeBusinessId(businessId)]
    if pulledOut and type(pulledOut.spotAssignments) == "table" then
      for _, idx in pairs(pulledOut.spotAssignments) do
        local n = tonumber(idx)
        if n then usedSpotIndexes[n] = true end
      end
    end

    local freeSpots = {}
    for idx, spot in ipairs(parkingSpots) do
      if not usedSpotIndexes[idx] then
        table.insert(freeSpots, spot)
      end
    end

    local parkingSpot
    if #freeSpots > 0 then
      parkingSpot = gameplay_sites_sitesManager.getBestParkingSpotForVehicleFromList(veh:getID(), freeSpots)
    end
    if not parkingSpot then
      parkingSpot = gameplay_sites_sitesManager.getBestParkingSpotForVehicleFromList(veh:getID(), parkingSpots)
    end
    if not parkingSpot then
      parkingSpot = parkingSpots[1]
    end
    return parkingSpot
  end

  -- Racing team cars sit where the spot is; other businesses' cars are grounded onto it.
  local function placeVehicleOnParkingSpot(businessType, veh, parkingSpot, resetVeh)
    if businessType == "racingTeam" then
      local adjustedRot = quat(0, 0, 1, 0) * parkingSpot.rot
      local p = parkingSpot.pos
      veh:setPosRot(p.x, p.y, p.z, adjustedRot.x, adjustedRot.y, adjustedRot.z, adjustedRot.w)
      if resetVeh then
        veh:resetBrokenFlexMesh()
      else
        veh:applyClusterVelocityScaleAdd(veh:getRefNodeId(), 0, 0, 0, 0)
      end
    elseif not teleportVehicleExact(veh, parkingSpot.pos, parkingSpot.rot, resetVeh, true) then
      return false
    end
    core_camera.resetCamera(0)
    return true
  end

  local function teleportToBusinessGarage(businessType, businessId, veh, resetVeh)
    resetVeh = resetVeh or false
    if not veh then
      return false
    end

    if overhaul_career_permissions then
      local status = overhaul_career_permissions.getStatusForTag("recoveryTowToGarage", {vehId = veh:getID()})
      if not status.allow then return false end
    end
    local garage = inputs.getBusinessGarage(businessType, businessId)
    if not garage then return false end

    local parkingSpots = overhaul_world_facilities.getParkingSpotsForFacility(garage)
    if not parkingSpots or #parkingSpots == 0 then
      return false
    end

    local parkingSpot = pickParkingSpot(veh, parkingSpots, businessId)
    if not parkingSpot or not parkingSpot.pos or not parkingSpot.rot then
      return false
    end
    if not placeVehicleOnParkingSpot(businessType, veh, parkingSpot, resetVeh) then
      return false
    end

    local chosenIdx = 1
    for idx, sp in ipairs(parkingSpots) do
      if sp == parkingSpot then
        chosenIdx = idx
        break
      end
    end

    return true, chosenIdx
  end

  local function getAvailableParkingSpotIndex(businessType, businessId, state)
    local parkingSpots = inputs.getBusinessGarageParkingSpots(businessType, businessId)
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

  -- Removal and clearing --------------------------------------------------------------------------

  local function removeBusinessVehicleObject(businessId, vehicleId)
    if not businessId or not vehicleId then
      return
    end

    businessId = inputs.normalizeBusinessId(businessId)
    vehicleId = tonumber(vehicleId) or vehicleId
    if not fleetState.spawnedBusinessVehicles[businessId] or not fleetState.spawnedBusinessVehicles[businessId][vehicleId] then
      return
    end

    local vehId = fleetState.spawnedBusinessVehicles[businessId][vehicleId]
    local vehObj = getObjectByID(vehId)
    if vehObj then
      overhaul_career_maintenance_tireSystem.unregisterBusinessVehicle(businessId, vehicleId, vehId)
      if be:getPlayerVehicleID(0) == vehId then
        gameplay_walk.setWalkingMode(true, nil, nil, true)
      end
      vehObj:delete()
    end

    fleetState.spawnedBusinessVehicles[businessId][vehicleId] = nil
  end

  local function clearBusinessInventory(businessId)
    if not businessId then
      return false
    end

    businessId = inputs.normalizeBusinessId(businessId)
    local vehicles = inputs.loadBusinessVehicles(businessId) or {}
    for _, vehicle in ipairs(vehicles) do
      inputs.clearCachesForStoredVehicle(businessId, vehicle)
      if vehicle and vehicle.vehicleId ~= nil then
        removeBusinessVehicleObject(businessId, vehicle.vehicleId)
      end
    end

    if fleetState.spawnedBusinessVehicles[businessId] then
      local spawnedVehicleIds = {}
      for vehicleId, _ in pairs(fleetState.spawnedBusinessVehicles[businessId]) do
        spawnedVehicleIds[#spawnedVehicleIds + 1] = vehicleId
      end
      for _, vehicleId in ipairs(spawnedVehicleIds) do
        removeBusinessVehicleObject(businessId, vehicleId)
      end
    end

    fleetState.businessVehicles[businessId] = {}
    fleetState.pulledOutVehicles[businessId] = nil
    fleetState.spawnedBusinessVehicles[businessId] = nil
    fleetState.vehicleIdCounters[businessId] = 1

    return true
  end

  -- Drive-in delivery -----------------------------------------------------------------------------

  -- Index of the parking spot nearest to a position, or nil when no spot has a position.
  local function nearestParkingSpotIndex(parkingSpots, pos)
    local bestIdx, bestDist = nil, math.huge
    for idx, sp in ipairs(parkingSpots) do
      if sp and sp.pos then
        local d = pos:distance(sp.pos)
        if d < bestDist then
          bestDist = d
          bestIdx = idx
        end
      end
    end
    return bestIdx
  end

  local function registerFleetVehicleDeliveredDriveIn(businessType, businessId, fleetVehicleId, spawnedGameId)
    if not businessType or not businessId or not fleetVehicleId or not spawnedGameId then
      return false
    end
    businessId = inputs.normalizeBusinessId(businessId)
    fleetVehicleId = inputs.normalizeVehicleId(fleetVehicleId)
    spawnedGameId = tonumber(spawnedGameId) or spawnedGameId
    local vehObj = getObjectByID(spawnedGameId)
    if not vehObj then
      return false
    end
    local vehicleRow = inputs.getVehicleById(businessId, fleetVehicleId)
    if not vehicleRow then
      return false
    end
    if not fleetState.spawnedBusinessVehicles[businessId] then
      fleetState.spawnedBusinessVehicles[businessId] = {}
    end
    fleetState.spawnedBusinessVehicles[businessId][fleetVehicleId] = spawnedGameId

    local state = inputs.ensurePulledOutState(businessId)
    if not inputs.findPulledOutVehicleIndex(state, fleetVehicleId) then
      table.insert(state.vehicles, vehicleRow)
    end
    state.activeVehicleId = fleetVehicleId
    state.spotAssignments = state.spotAssignments or {}
    local parkingSpots = inputs.getBusinessGarageParkingSpots(businessType, businessId)
    if parkingSpots and #parkingSpots > 0 then
      local bestIdx = nearestParkingSpotIndex(parkingSpots, vehObj:getPosition())
      if bestIdx then
        state.spotAssignments[fleetVehicleId] = bestIdx
      end
    end
    return true
  end

  -- Pull-out --------------------------------------------------------------------------------------

  -- Bookkeeping says the vehicle is out, but its world object is gone: drop the record and return the state to use.
  local function clearGhostLift(businessId, state, existingIndex, vehicleId)
    table.remove(state.vehicles, existingIndex)
    if state.spotAssignments then
      state.spotAssignments[vehicleId] = nil
    end
    if fleetState.spawnedBusinessVehicles[businessId] then
      fleetState.spawnedBusinessVehicles[businessId][vehicleId] = nil
    end
    if state.activeVehicleId == vehicleId then
      state.activeVehicleId = state.vehicles[1] and inputs.normalizeVehicleId(state.vehicles[1].vehicleId) or nil
    end
    if #state.vehicles == 0 then
      fleetState.pulledOutVehicles[businessId] = nil
      return inputs.ensurePulledOutState(businessId)
    end
    return state
  end

  -- A pull-out that failed leaves no spawned record and no empty pulled-out state behind.
  local function forgetFailedPullOut(businessId, state, vehicleId)
    if fleetState.spawnedBusinessVehicles[businessId] then
      fleetState.spawnedBusinessVehicles[businessId][vehicleId] = nil
    end
    if #state.vehicles == 0 then
      fleetState.pulledOutVehicles[businessId] = nil
    end
  end

  -- Vehicles without a stored config get it read back from the vehicle, keyed by a callback id.
  local function requestMissingVehicleConfig(vehObj, vehicle, businessId, vehicleId)
    local callbackId = tostring(businessId) .. "_" .. tostring(vehicleId) .. "_" .. tostring(os.time())
    inputs.pendingConfigCallbacks[callbackId] = {
      businessId = businessId,
      vehicleId = vehicleId
    }

    if not vehicle.config then
      vehObj:queueLuaCommand([[
        local configData = serialize(v.config)
        obj:queueGameEngineLua(require('vehicle/overhaul/geCallback').reply(]] .. require('overhaul/lib/vehicles/callbacks').open('businessVehicleConfig', {owner = 'businessInventory', timeout = false}) .. [[, 'businessVehicleConfig', "']] .. callbackId ..
                               [[', " .. configData))
      ]])
    end
  end

  local function reconcileExistingPullOut(businessId, state, normalizedVehicleId)
    local existingIndex = inputs.findPulledOutVehicleIndex(state, normalizedVehicleId)
    if existingIndex then
      local existingSpawnId = inputs.getSpawnedVehicleId(businessId, normalizedVehicleId)
      local existingObj = existingSpawnId and getObjectByID(existingSpawnId) or nil
      if existingObj then
        state.activeVehicleId = normalizedVehicleId
        return state, true
      end
      state = clearGhostLift(businessId, state, existingIndex, normalizedVehicleId)
    end

    return state, false
  end

  local function pullOutVehicle(businessType, businessId, vehicleId)
    if not businessType or not businessId or not vehicleId then
      log('D', 'businessInventory.pullOut', 'abort: missing businessType, businessId, or vehicleId')
      return false
    end

    businessId = inputs.normalizeBusinessId(businessId)
    local normalizedVehicleId = inputs.normalizeVehicleId(vehicleId)
    if not normalizedVehicleId then
      log('D', 'businessInventory.pullOut',
        string.format('abort: bad vehicleId businessId=%s raw=%s', tostring(businessId), tostring(vehicleId)))
      return false
    end

    local vehicle = inputs.getVehicleById(businessId, normalizedVehicleId)
    if not vehicle then
      log('D', 'businessInventory.pullOut',
        string.format('abort: no stored vehicle row businessId=%s vehicleId=%s', tostring(businessId),
          tostring(normalizedVehicleId)))
      return false
    end

    local state = inputs.ensurePulledOutState(businessId)
    local alreadyLive
    state, alreadyLive = reconcileExistingPullOut(businessId, state, normalizedVehicleId)
    if alreadyLive then return true end

    local vehObj = spawnBusinessVehicle(businessId, normalizedVehicleId)
    if not vehObj then
      log('D', 'businessInventory.pullOut',
        string.format('spawnBusinessVehicle failed businessId=%s vehicleId=%s', tostring(businessId),
          tostring(normalizedVehicleId)))
      forgetFailedPullOut(businessId, state, normalizedVehicleId)
      return false
    end

    state.spotAssignments = state.spotAssignments or {}
    local preferredSpotIndex = getAvailableParkingSpotIndex(businessType, businessId, state)
    local teleportSuccess, actualSpotIndex = teleportToBusinessGarage(businessType, businessId, vehObj, false)

    if not teleportSuccess then
      log('D', 'businessInventory.pullOut',
        string.format('teleportToBusinessGarage failed businessId=%s vehicleId=%s spotIndex=%s',
          tostring(businessId), tostring(normalizedVehicleId), tostring(preferredSpotIndex)))
      vehObj:delete()
      forgetFailedPullOut(businessId, state, normalizedVehicleId)
      return false
    end

    table.insert(state.vehicles, vehicle)
    state.activeVehicleId = normalizedVehicleId
    state.spotAssignments[normalizedVehicleId] = actualSpotIndex

    requestMissingVehicleConfig(vehObj, vehicle, businessId, normalizedVehicleId)
    return true
  end

  return {
    clearBusinessInventory = clearBusinessInventory,
    pullOutVehicle = pullOutVehicle,
    registerFleetVehicleDeliveredDriveIn = registerFleetVehicleDeliveredDriveIn,
    removeBusinessVehicleObject = removeBusinessVehicleObject,
    spawnBusinessVehicle = spawnBusinessVehicle,
    teleportToBusinessGarage = teleportToBusinessGarage,
    teleportVehicleExact = teleportVehicleExact,
  }
end

return part
