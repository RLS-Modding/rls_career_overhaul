-- Business fleet purchase delivery, stats capture, put-away and emergency respawn.
-- Read owner inputs, stats capture, delivery, put-away steps, then emergency respawn and the returned API.
local capabilities = require("overhaul/lib/platform/capabilities")
local part = {}

-- Each construction shares state and helpers with that owner load.
function part.new(inputs)
  local fleetState = inputs.fleetState

  local function runComplete(onComplete, ok)
    if onComplete then
      onComplete(ok ~= false)
    end
  end

  -- Put-away --------------------------------------------------------------------------------------

  local function persistSpawnedVehiclePartConditions(businessId, normalizedVehicleId, onDone)
    if onDone == nil then
      onDone = function() end
    end
    businessId = inputs.normalizeBusinessId(businessId)
    normalizedVehicleId = inputs.normalizeVehicleId(normalizedVehicleId)
    if not businessId or not normalizedVehicleId then
      onDone()
      return
    end
    local stored = inputs.getVehicleById(businessId, normalizedVehicleId)
    local spawnedId = inputs.getSpawnedVehicleId(businessId, normalizedVehicleId)
    local vehObj = spawnedId and getObjectByID(spawnedId)
    if not vehObj then
      onDone()
      return
    end
    local records = fleetState.businessVehicles
    local profile = overhaul_career_saveSystem.getCurrentProfile()
    local finished = false
    core_vehicleBridge.requestValue(vehObj, function(res)
      if finished then return end
      finished = true
      if fleetState.businessVehicles ~= records or profile ~= overhaul_career_saveSystem.getCurrentProfile()
        or inputs.getVehicleById(businessId, normalizedVehicleId) ~= stored
        or inputs.getSpawnedVehicleId(businessId, normalizedVehicleId) ~= spawnedId then
        onDone(false)
        return
      end
      if type(res) ~= "table" or type(res.result) ~= "table" then
        onDone(false)
        return
      end
      if stored then
        stored.partConditions = deepcopy(res.result)
      end
      onDone()
    end, 'getPartConditions')
  end

  -- A spawned fleet vehicle with no pulled-out record (left over from a reload or a failed pull-out).
  local function putAwayOrphanSpawnedVehicle(businessId, fleetVehicleId, skipPersist, onComplete)
    if not fleetVehicleId or not inputs.getSpawnedVehicleId(businessId, fleetVehicleId) then
      return false
    end
    local vehicleRow = inputs.getVehicleById(businessId, fleetVehicleId)
    local function finishOrphan(ok)
      if ok == false then return runComplete(onComplete, false) end
      if vehicleRow then
        inputs.clearCachesForStoredVehicle(businessId, vehicleRow)
      else
        local computer = capabilities.peek("businessComputer")
        if computer then computer.clearBusinessCachesForVehicle(businessId, fleetVehicleId) end
      end
      inputs.parts.garage.removeBusinessVehicleObject(businessId, vehicleRow and vehicleRow.vehicleId or fleetVehicleId)
      runComplete(onComplete, true)
    end
    if skipPersist then
      finishOrphan()
    else
      persistSpawnedVehiclePartConditions(businessId, fleetVehicleId, finishOrphan)
    end
    return true
  end

  -- Clears every listed vehicle's world object and caches, then forgets the business's pulled-out state.
  local function dropPulledOutVehicles(businessId, vehicles, onComplete)
    for _, vehicle in ipairs(vehicles) do
      inputs.clearCachesForStoredVehicle(businessId, vehicle)
      inputs.parts.garage.removeBusinessVehicleObject(businessId, vehicle.vehicleId)
    end
    fleetState.pulledOutVehicles[businessId] = nil
    runComplete(onComplete, true)
  end

  -- Saves each vehicle's part conditions in turn, then drops them all.
  local function persistThenDropPulledOutVehicles(businessId, vehicles, onComplete)
    local nextIndex = 1
    local function persistNext(ok)
      if ok == false then return runComplete(onComplete, false) end
      if nextIndex > #vehicles then
        return dropPulledOutVehicles(businessId, vehicles, onComplete)
      end
      local vehicle = vehicles[nextIndex]
      local vehicleId = inputs.normalizeVehicleId(vehicle.vehicleId)
      nextIndex = nextIndex + 1
      persistSpawnedVehiclePartConditions(businessId, vehicleId, persistNext)
    end
    persistNext()
  end

  local function putAwayAllPulledOutVehicles(businessId, skipPersist, onComplete)
    local state = fleetState.pulledOutVehicles[businessId]
    local vehicles = {}
    if state and state.vehicles then
      for _, vehicle in ipairs(state.vehicles) do
        table.insert(vehicles, vehicle)
      end
    end
    if skipPersist or #vehicles == 0 then
      return dropPulledOutVehicles(businessId, vehicles, onComplete)
    end
    persistThenDropPulledOutVehicles(businessId, vehicles, onComplete)
  end

  -- Removes one vehicle from the pulled-out list once its part conditions are saved (or skipped).
  local function forgetPulledOutVehicle(businessId, state, vehicle, normalizedVehicleId, onComplete)
    if fleetState.pulledOutVehicles[businessId] ~= state then
      return runComplete(onComplete, false)
    end
    -- Other replies may have removed earlier rows while this car was being sampled.
    local index = inputs.findPulledOutVehicleIndex(state, normalizedVehicleId)
    if not index or state.vehicles[index] ~= vehicle then
      return runComplete(onComplete, false)
    end
    inputs.clearCachesForStoredVehicle(businessId, vehicle)
    inputs.parts.garage.removeBusinessVehicleObject(businessId, vehicle.vehicleId)
    table.remove(state.vehicles, index)
    if state.spotAssignments then
      state.spotAssignments[normalizedVehicleId] = nil
    end
    if state.activeVehicleId == normalizedVehicleId then
      state.activeVehicleId = state.vehicles[1] and inputs.normalizeVehicleId(state.vehicles[1].vehicleId) or nil
    end
    if #state.vehicles == 0 then
      fleetState.pulledOutVehicles[businessId] = nil
    end
    runComplete(onComplete, true)
  end

  local function putAwayOnePulledOutVehicle(businessId, normalizedVehicleId, skipPersist, onComplete)
    local state = fleetState.pulledOutVehicles[businessId]
    if not state or not state.vehicles then
      fleetState.pulledOutVehicles[businessId] = nil
      if not putAwayOrphanSpawnedVehicle(businessId, normalizedVehicleId, skipPersist, onComplete) then
        runComplete(onComplete, true)
      end
      return true
    end

    local index = inputs.findPulledOutVehicleIndex(state, normalizedVehicleId)
    if not index then
      if putAwayOrphanSpawnedVehicle(businessId, normalizedVehicleId, skipPersist, onComplete) then
        return true
      end
      runComplete(onComplete, false)
      return false
    end

    local vehicle = state.vehicles[index]
    local spawnedId = inputs.getSpawnedVehicleId(businessId, normalizedVehicleId)
    local liveObj = spawnedId and getObjectByID(spawnedId) or nil
    -- Missing world object: clear ghost lift state without trying to read part conditions.
    if not liveObj then
      skipPersist = true
    end

    local function forget(ok)
      if ok == false then return runComplete(onComplete, false) end
      forgetPulledOutVehicle(businessId, state, vehicle, normalizedVehicleId, onComplete)
    end
    if skipPersist then
      forget()
      return true
    end
    persistSpawnedVehiclePartConditions(businessId, normalizedVehicleId, forget)
    return true
  end

  local function putAwayVehicle(businessId, vehicleId, onComplete, opts)
    if not businessId then
      if onComplete then
        onComplete(false)
      end
      return false
    end

    local skipPersist = opts and opts.skipPartConditionPersist == true
    businessId = inputs.normalizeBusinessId(businessId)
    if not vehicleId then
      putAwayAllPulledOutVehicles(businessId, skipPersist, onComplete)
      return true
    end

    local normalizedVehicleId = inputs.normalizeVehicleId(vehicleId)
    if not normalizedVehicleId then
      runComplete(onComplete, false)
      return false
    end
    return putAwayOnePulledOutVehicle(businessId, normalizedVehicleId, skipPersist, onComplete)
  end

  -- Purchase and drive-in delivery ----------------------------------------------------------------

  -- Counts garage spots held by pulled-out vehicles, to know whether a new car has a free spot.
  local function countUsedSpots(businessId)
    local existingState = fleetState.pulledOutVehicles[businessId]
    local usedSpots = 0
    if existingState and type(existingState.spotAssignments) == "table" then
      for _, idx in pairs(existingState.spotAssignments) do
        if idx then usedSpots = usedSpots + 1 end
      end
    end
    return usedSpots
  end

  -- Eligibility needs live power and weight; put excess deliveries away so cars do not stack on a full garage.
  local function deliverFleetVehicleAtPurchase(businessType, businessId, vehicleId)
    if not businessType or not businessId or vehicleId == nil then
      return false
    end
    businessId = inputs.normalizeBusinessId(businessId)
    local normalizedVehicleId = inputs.normalizeVehicleId(vehicleId)
    if not businessId or not normalizedVehicleId then
      return false
    end

    local parkingSpots = inputs.getBusinessGarageParkingSpots(businessType, businessId)
    local totalSpots = parkingSpots and #parkingSpots or 0
    local hasFreeSpot = (totalSpots == 0) or (countUsedSpots(businessId) < totalSpots)

    if not inputs.parts.garage.pullOutVehicle(businessType, businessId, normalizedVehicleId) then
      return false
    end

    local spawnedId = inputs.getSpawnedVehicleId(businessId, normalizedVehicleId)
    local vehObj = spawnedId and getObjectByID(spawnedId) or nil
    if not vehObj then
      return true
    end

    local function fireStatsReadAndMaybeStow()
      overhaul_career_business_partCustomization.requestVehiclePowerWeightAfterPurchase(businessId, normalizedVehicleId)
      if not hasFreeSpot then
        core_jobsystem.create(function(job)
          job.sleep(2)
          putAwayVehicle(businessId, normalizedVehicleId)
        end)
      end
    end

    core_vehicleBridge.requestValue(vehObj, fireStatsReadAndMaybeStow, 'ping')

    return true
  end

  -- Drive-in delivery already has a live vehicle, so sample it instead of spawning another.
  local function requestFleetVehicleStatsRead(businessId, vehicleId)
    if not businessId or vehicleId == nil then
      return false
    end
    businessId = inputs.normalizeBusinessId(businessId)
    local normalizedVehicleId = inputs.normalizeVehicleId(vehicleId)
    if not businessId or not normalizedVehicleId then
      return false
    end
    local spawnedId = inputs.getSpawnedVehicleId(businessId, normalizedVehicleId)
    local vehObj = spawnedId and getObjectByID(spawnedId) or nil
    if not vehObj then
      return false
    end
    local function fire()
      overhaul_career_business_partCustomization.requestVehiclePowerWeightAfterPurchase(businessId, normalizedVehicleId)
    end
    core_vehicleBridge.requestValue(vehObj, fire, 'ping')
    return true
  end

  -- Recovery and placement ------------------------------------------------------------------------

  -- Re-spawn a pulled-out fleet vehicle when replaceVehicle left a ghost / dead object.
  local function emergencyRespawnPulledOutVehicle(businessType, businessId, vehicleId, restoreConfig, partConditions)
    if not businessId or vehicleId == nil then
      return nil
    end

    businessId = inputs.normalizeBusinessId(businessId)
    vehicleId = tonumber(vehicleId) or vehicleId

    local vehicle = inputs.getVehicleById(businessId, vehicleId)
    if not vehicle then
      return nil
    end

    inputs.parts.garage.removeBusinessVehicleObject(businessId, vehicleId)

    if restoreConfig then
      vehicle.config = deepcopy(restoreConfig)
    end
    if partConditions then
      vehicle.partConditions = deepcopy(partConditions)
    end

    local vehObj = inputs.parts.garage.spawnBusinessVehicle(businessId, vehicleId)
    if not vehObj then
      log('E', 'businessInventory.emergencyRespawn',
        string.format('spawn failed businessId=%s vehicleId=%s', tostring(businessId), tostring(vehicleId)))
      return nil
    end

    if businessType then
      local state = fleetState.pulledOutVehicles[businessId]
      local preferredSpotIndex = state and state.spotAssignments and state.spotAssignments[vehicleId] or nil
      inputs.parts.garage.teleportToBusinessGarage(businessType, businessId, vehObj, false, preferredSpotIndex)
    end

    log('I', 'businessInventory.emergencyRespawn',
      string.format('respawned businessId=%s vehicleId=%s', tostring(businessId), tostring(vehicleId)))
    return vehObj
  end

  local function teleportSpawnedBusinessVehicleToSpot(businessId, vehicleId, spot)
    if not businessId or not vehicleId or not spot or not spot.pos or not spot.rot then
      return false
    end
    businessId = inputs.normalizeBusinessId(businessId)
    vehicleId = tonumber(vehicleId) or vehicleId
    local sid = inputs.getSpawnedVehicleId(businessId, vehicleId)
    local vehObj = sid and getObjectByID(sid)
    if not vehObj then
      vehObj = inputs.parts.garage.spawnBusinessVehicle(businessId, vehicleId)
    end
    if not vehObj then
      return false
    end
    local pos = spot.pos
    local r = spot.rot
    local q = quat(r[1] or 0, r[2] or 0, r[3] or 0, r[4] or 1)
    inputs.parts.garage.teleportVehicleExact(vehObj, vec3(pos[1], pos[2], pos[3]), q, true, true)
    core_camera.resetCamera(0)
    return true
  end

  local function getBusinessVehicleIdentifier(businessId, vehicleId)
    return "business_" .. tostring(businessId) .. "_" .. tostring(vehicleId)
  end

  return {
    deliverFleetVehicleAtPurchase = deliverFleetVehicleAtPurchase,
    emergencyRespawnPulledOutVehicle = emergencyRespawnPulledOutVehicle,
    getBusinessVehicleIdentifier = getBusinessVehicleIdentifier,
    persistSpawnedVehiclePartConditions = persistSpawnedVehiclePartConditions,
    putAwayVehicle = putAwayVehicle,
    requestFleetVehicleStatsRead = requestFleetVehicleStatsRead,
    teleportSpawnedBusinessVehicleToSpot = teleportSpawnedBusinessVehicleToSpot,
  }
end

return part
