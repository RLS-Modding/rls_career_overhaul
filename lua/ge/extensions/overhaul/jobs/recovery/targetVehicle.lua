-- Recovery target setup, fuel, energy and temporary-vehicle cleanup.
-- Command templates retain exact bytes; cleanup waits for hauler couplers before deleting cargo.
return function(LOG_TAG, resolveConfigPath, sessionDamageFilePath)
  local function waitForEnergyUpdate(vehicle, callback)
    if not callback then return end
    if not vehicle then
      callback()
      return
    end
    core_vehicleBridge.requestValue(vehicle, function() callback() end, "ping")
  end

  local function setStoredEnergy(job, vehicle, callback)
    if not vehicle or type(job.energyStorage) ~= "table" then
      if callback then callback() end
      return
    end
    for _, tank in ipairs(job.energyStorage) do
      if tank.name then
        core_vehicleBridge.executeAction(vehicle, "setEnergyStorageEnergy", tank.name, tonumber(tank.currentEnergy) or 0)
      end
    end
    waitForEnergyUpdate(vehicle, callback)
  end

  -- Maneuvering fuel only: enough to creep onto a trailer. 1% of tank, capped at 1 L.
  local function setOneLiter(job, vehicle, callback, isCurrent)
    core_vehicleBridge.requestValue(vehicle, function(response)
      if isCurrent and not isCurrent() then return end
      local tanks = response and (response.result or response)
      local allTanks = type(tanks) == "table" and (tanks[1] or tanks) or {}
      local factors = {gasoline = 31.125, diesel = 36.112, kerosine = 34.4}
      local assigned = false
      job.energyStorage = {}
      for _, tank in ipairs(allTanks) do
        local energy = 0
        local factor = factors[tank.energyType]
        if factor and not assigned then
          local oneLiterJ = factor * 1000000
          local maxEnergy = tonumber(tank.maxEnergy) or 0
          energy = maxEnergy > 0 and math.min(maxEnergy * 0.01, oneLiterJ) or oneLiterJ
          assigned = true
        end
        if tank.name then
          core_vehicleBridge.executeAction(vehicle, "setEnergyStorageEnergy", tank.name, energy)
          job.energyStorage[#job.energyStorage + 1] = {name = tank.name, energyType = tank.energyType, currentEnergy = energy}
        end
      end
      waitForEnergyUpdate(vehicle, callback)
    end, "energyStorage")
  end

  local function initialConditionCommand(job, vehId)
    local conditionKind = job.condition == "brokenEngine" and "engine" or "normal"
    local mileage = math.max(0, tonumber(job.mileage) or 0)
    return string.format([[
    local conditionKind = %q
    local mileage = %.0f
    local parts = {}
    for partPath, partName in pairs(v.data.activeParts or {}) do
      -- Match part names so drivetrain parts nested below an engine slot survive.
      local key = string.lower(tostring(partName))
      local integrity = 1
      if conditionKind == "engine" and string.find(key, "engine", 1, true)
          and not string.find(key, "mount", 1, true) then
        integrity = 0
      end
      parts[partPath] = {odometer = mileage, integrityValue = integrity, visualValue = 1}
    end
    partCondition.initConditions(parts, mileage, 1, 1)
    obj:queueGameEngineLua(require('vehicle/overhaul/geCallback').reply(%d, 'recoveryInitialCondition', %q))
  ]], conditionKind, mileage, require('overhaul/lib/vehicles/callbacks').open('recoveryInitialCondition', {owner = 'offroadRecovery', timeout = false}),
      string.format("%q, %d", job.id, vehId))
  end

  local function isWheelPartSlot(slotName)
    local key = tostring(slotName or ""):lower()
    if key == "" or key:find("wheeldata", 1, true) or key:find("wheelhub", 1, true)
        or key:find("wheelie", 1, true) or key:find("wheelskirt", 1, true) then
      return false
    end
    return key:match("^wheel[_%d]") ~= nil or key:find("_wheel", 1, true) ~= nil
  end

  local function configWithMissingWheelSlots(job, config)
    local count = math.max(0, math.floor(tonumber(job and job.missingWheelCount) or 0))
    if count == 0 then return config end

    local result
    local configPath
    if type(config) == "table" then
      result = deepcopy(config)
    else
      configPath = resolveConfigPath(job.model, config)
      result = configPath and jsonReadFile(configPath) or nil
    end
    if type(result) ~= "table" or type(result.parts) ~= "table" then
      log("W", LOG_TAG, "Could not prepare missing wheel slots for recovery " .. tostring(job.id))
      return config
    end

    local candidates = {}
    for slotName, partName in pairs(result.parts) do
      if partName ~= nil and partName ~= "" and isWheelPartSlot(slotName) then
        candidates[#candidates + 1] = slotName
      end
    end
    table.sort(candidates)
    if #candidates == 0 then
      log("W", LOG_TAG, "Recovery config has no removable wheel slots: " .. tostring(job.id))
      return result
    end

    local startIndex = ((tonumber(job.wheelSeed) or 1) % #candidates) + 1
    job.missingWheelSlots = {}
    for offset = 0, math.min(count, #candidates) - 1 do
      local slotName = candidates[((startIndex + offset - 1) % #candidates) + 1]
      result.parts[slotName] = ""
      job.missingWheelSlots[#job.missingWheelSlots + 1] = slotName
    end
    if configPath and not result.partConfigFilename then result.partConfigFilename = configPath end
    return result
  end

  local function withRecoverySpawnFlag(job, config)
    local result
    if type(config) == "table" then
      result = deepcopy(config)
    else
      local configPath = resolveConfigPath(job and job.model, config)
      result = configPath and jsonReadFile(configPath) or nil
      if type(result) ~= "table" then return config end
      if configPath and not result.partConfigFilename then result.partConfigFilename = configPath end
    end
    result.isRecovery = true
    return result
  end

  -- Re-attach currently coupled nodes at huge strength so a deck-mass delete cannot impulse-break gooseneck/pintle hitches. Restore after settle.
  local TEMP_COUPLER_LOCK_CMD = [[
if beamstate and beamstate.attachedCouplers and beamstate.couplerCache then
  for nid, _ in pairs(beamstate.attachedCouplers) do
    local c = beamstate.couplerCache[nid]
    if c and c.cid and not c.couplerWeld then
      local tag = c.couplerTag or c.tag
      if tag then
        obj:attachCoupler(c.cid, tag, 1e12, c.couplerRadius or 0.2, c.couplerLockRadius or 0.025, c.couplerLatchSpeed or 0.3, c.couplerTargets or 0)
      end
    end
  end
end
]]

  local TEMP_COUPLER_UNLOCK_CMD = [[
if beamstate and beamstate.attachedCouplers and beamstate.couplerCache then
  for nid, _ in pairs(beamstate.attachedCouplers) do
    local c = beamstate.couplerCache[nid]
    if c and c.cid and not c.couplerWeld then
      local tag = c.couplerTag or c.tag
      if tag then
        obj:attachCoupler(c.cid, tag, c.couplerStrength or 1000000, c.couplerRadius or 0.2, c.couplerLockRadius or 0.025, c.couplerLatchSpeed or 0.3, c.couplerTargets or 0)
      end
    end
  end
end
]]

  local function collectHaulerIdsNearTarget(targetVehId)
    local ids = {}
    local seen = {}
    local function add(id)
      if id and id ~= targetVehId and not seen[id] then
        seen[id] = true
        ids[#ids + 1] = id
      end
    end

    local function addTrain(rootId)
      if not rootId or rootId == targetVehId then return end
      local group = {}
      overhaul_vehicles_playerVehicles.fillCouplerGroup(rootId, group, {resolveLead = true})
      for _, id in ipairs(group) do add(id) end
    end

    local playerId = be:getPlayerVehicleID(0)
    if playerId and playerId ~= -1 then addTrain(playerId) end

    local target = targetVehId and getObjectByID(targetVehId)
    local tpos = target and target:getPosition()
    if tpos and getAllVehicles then
      for _, veh in ipairs(getAllVehicles()) do
        local id = veh.getID and veh:getID() or (veh.getId and veh:getId())
        if id and id ~= targetVehId then
          local p = veh:getPosition()
          local dx, dy = p.x - tpos.x, p.y - tpos.y
          if (dx * dx + dy * dy) < (25 * 25) then
            addTrain(id)
          end
        end
      end
    end
    return ids
  end

  local function setHaulerCouplerLock(haulerIds, lock)
    local cmd = lock and TEMP_COUPLER_LOCK_CMD or TEMP_COUPLER_UNLOCK_CMD
    for _, id in ipairs(haulerIds or {}) do
      local obj = getObjectByID(id)
      if obj and obj.queueLuaCommand then
        pcall(function() obj:queueLuaCommand(cmd) end)
      end
    end
  end

  -- Ghost + lift clear of the deck so contact ends before the object is deleted.
  local function clearTargetFromHaulerDeck(vehicle)
    if not vehicle then return end
    pcall(function()
      if vehicle.queueLuaCommand then
        vehicle:queueLuaCommand("obj:setGhostEnabled(true); obj:setVelocity(0,0,0); obj:setAngularVelocity(0,0,0)")
      end
      local pos = vehicle:getPosition()
      local rot = quat(0, 0, 1, 0) * quat(vehicle:getRefNodeRotation())
      local clearZ = (pos.z or 0) + 60
      if vehicle.setPositionRotation then
        vehicle:setPositionRotation(pos.x, pos.y, clearZ, rot.x, rot.y, rot.z, rot.w)
      elseif vehicle.setPosRot then
        vehicle:setPosRot(pos.x, pos.y, clearZ, rot.x, rot.y, rot.z, rot.w)
      end
    end)
  end

  local function deleteTemporaryTargetObject(job, vehicleId, inventoryId)
    if inventoryId and overhaul_career_garage_inventory and overhaul_career_garage_inventory.getVehicles()[inventoryId] then
      -- The final part state was already captured by the contract. Delete the temporary world object directly so inventory removal does not start a second asynchronous damage save against an object it is deleting.
      local removedObjectOk, removedObjectErr = pcall(overhaul_career_garage_inventory.removeVehicleObject, inventoryId, true)
      if not removedObjectOk then log("W", LOG_TAG, "Could not remove abandoned recovery target object: " .. tostring(removedObjectErr)) end
      local ok, err = pcall(overhaul_career_garage_inventory.removeVehicle, inventoryId)
      if not ok then log("W", LOG_TAG, "Could not remove abandoned recovery inventory record: " .. tostring(err)) end
    elseif vehicleId then
      local vehicle = getObjectByID(vehicleId)
      if vehicle then
        local ok, err = pcall(vehicle.delete, vehicle)
        if not ok then log("W", LOG_TAG, "Could not delete abandoned recovery target: " .. tostring(err)) end
      end
    end
    local pathName = job and sessionDamageFilePath(job.id)
    if pathName and FS:fileExists(pathName) then
      local ok, err = pcall(FS.removeFile, FS, pathName)
      if not ok then log("W", LOG_TAG, "Could not remove abandoned recovery damage snapshot: " .. tostring(err)) end
    end
  end

  return {clearTargetFromHaulerDeck = clearTargetFromHaulerDeck,
      collectHaulerIdsNearTarget = collectHaulerIdsNearTarget,
      configWithMissingWheelSlots = configWithMissingWheelSlots,
      deleteTemporaryTargetObject = deleteTemporaryTargetObject,
      initialConditionCommand = initialConditionCommand, setHaulerCouplerLock = setHaulerCouplerLock,
      setOneLiter = setOneLiter, setStoredEnergy = setStoredEnergy,
      withRecoverySpawnFlag = withRecoverySpawnFlag}
end
