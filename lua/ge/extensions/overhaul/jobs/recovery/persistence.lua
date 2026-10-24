-- Recovery pose, energy and damage snapshots.
-- State stays with the job owner; these helpers preserve the save paths and snapshot bytes.
local vehicleCommands = require('overhaul/lib/vehicles/vehicleCommands')
return function(constants, getSaveAdapter)
  local function tableCount(value)
    local count = 0
    for _ in pairs(value or {}) do count = count + 1 end
    return count
  end

  local function toVec3Array(value)
    if not value then return nil end
    return {tonumber(value.x) or tonumber(value[1]) or 0, tonumber(value.y) or tonumber(value[2]) or 0, tonumber(value.z) or tonumber(value[3]) or 0}
  end

  local function toQuatArray(value)
    if not value then return nil end
    return {
      tonumber(value.x) or tonumber(value[1]) or 0,
      tonumber(value.y) or tonumber(value[2]) or 0,
      tonumber(value.z) or tonumber(value[3]) or 0,
      tonumber(value.w) or tonumber(value[4]) or 1
    }
  end

  local function arrayToVec3(value)
    return value and vec3(value[1] or 0, value[2] or 0, value[3] or 0) or vec3()
  end

  local function arrayToQuat(value)
    return value and quat(value[1] or 0, value[2] or 0, value[3] or 0, value[4] or 1) or quat(0, 0, 0, 1)
  end

  local function currentSavePath()
    if not overhaul_career_saveSystem or not overhaul_career_saveSystem.getCurrentProfile then return nil end
    local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
    return savePath
  end

  local function currentProfileName()
    if not overhaul_career_saveSystem or not overhaul_career_saveSystem.getCurrentProfile then return nil end
    return (overhaul_career_saveSystem.getCurrentProfile())
  end

  local function ensureSaveDirectories(savePath, writer)
    if not savePath then return end
    writer = writer or overhaul_career_saveSystem.getSaveWriter()
    if not writer.exists(savePath .. constants.SAVE_DIR) then writer.mkdir(savePath .. constants.SAVE_DIR) end
    if not writer.exists(savePath .. constants.DAMAGE_DIR) then writer.mkdir(savePath .. constants.DAMAGE_DIR) end
  end

  local function damageFileName(jobId)
    return (tostring(jobId):gsub("[^%w_%-]", "_")) .. ".json"
  end

  local function damageFilePath(jobId, savePath)
    if not savePath then return nil end
    return string.format("%s%s/%s", savePath, constants.DAMAGE_DIR, damageFileName(jobId))
  end

  local function sessionDamageFilePath(jobId, createDir)
    if createDir and not FS:directoryExists(constants.SESSION_DAMAGE_DIR) then FS:directoryCreate(constants.SESSION_DAMAGE_DIR, true) end
    return string.format("%s/%s", constants.SESSION_DAMAGE_DIR, damageFileName(jobId))
  end

  local function clearSessionDamage(writer)
    if not FS:directoryExists(constants.SESSION_DAMAGE_DIR) then return end
    local list = writer and writer.findFiles or function(...) return FS:findFiles(...) end
    local remove = writer and writer.remove or function(file) return FS:removeFile(file) end
    for _, filePath in ipairs(list(constants.SESSION_DAMAGE_DIR, "*.json", 0, false, false) or {}) do
      pcall(remove, filePath)
    end
  end

  local function loadableDamageFilePath(jobId)
    local sessionPath = sessionDamageFilePath(jobId)
    if FS:fileExists(sessionPath) then return sessionPath end
    local savePath = damageFilePath(jobId, currentSavePath())
    if savePath and FS:fileExists(savePath) then return savePath end
    return nil
  end

  local function capturePose(job)
    local vehicle = job and job.vehicleId and getObjectByID(job.vehicleId)
    if not vehicle then return false end
    job.targetPos = toVec3Array(vehicle:getPosition())
    job.targetRot = toQuatArray(quat(0, 0, 1, 0) * quat(vehicle:getRefNodeRotation()))
    return true
  end

  local function captureEnergy(job, callback)
    local vehicle = job and job.vehicleId and getObjectByID(job.vehicleId)
    if not vehicle then
      if callback then callback(false) end
      return
    end
    core_vehicleBridge.requestValue(vehicle, function(response)
      local tanks = response and (response.result or response)
      if type(tanks) ~= "table" then
        if callback then callback(false) end
        return
      end
      job.energyStorage = {}
      for _, tank in ipairs(tanks[1] or tanks) do
        if tank.name then
          job.energyStorage[#job.energyStorage + 1] = {
            name = tank.name,
            energyType = tank.energyType,
            currentEnergy = tonumber(tank.currentEnergy) or 0
          }
        end
      end
      if callback then callback(true) end
    end, "energyStorage")
  end

  local function dispatchDamageSnapshot(context, vehicle, file, callbackCode)
    -- The VE serializer keeps its own compact format; only its declared destination is bound here.
    local pathName = context.path(file)
    local command = "extensions.load('overhaulDamageState'); if overhaulDamageState then "
      .. vehicleCommands.call('overhaulDamageState', 'saveDamageData', (pathName:gsub("\\", "/"))) .. " end"
    if callbackCode then
      command = command .. string.format("; obj:queueGameEngineLua(require('vehicle/overhaul/geCallback').reply(%d, 'recoveryDamageSnapshot', %q))", require('overhaul/lib/vehicles/callbacks').open('recoveryDamageSnapshot', {owner = 'offroadRecovery', timeout = false}), callbackCode)
    end
    vehicle:queueLuaCommand(command)
    return true
  end

  local function saveDamageSnapshot(job, savePath, callbackCode)
    local vehicle = job and job.vehicleId and getObjectByID(job.vehicleId)
    local pathName
    if job then
      if savePath then
        ensureSaveDirectories(savePath)
        pathName = damageFilePath(job.id, savePath)
      else
        pathName = sessionDamageFilePath(job.id, true)
      end
    end
    if not vehicle or not pathName then return false end
    local saved = getSaveAdapter()
    if savePath then
      return saved.damage(savePath, dispatchDamageSnapshot, vehicle,
        constants.DAMAGE_DIR:sub(2) .. '/' .. damageFileName(job.id), callbackCode)
    end
    return saved.session(dispatchDamageSnapshot, vehicle, pathName:sub(2), callbackCode)
  end

  local function updateJobSnapshotFromInventory(job)
    if not job or not job.inventoryId or not overhaul_career_garage_inventory then return false end
    local record = overhaul_career_garage_inventory.getVehicles()[job.inventoryId]
    if not record then return false end
    record.year = job.year or record.year
    record.mileage = math.max(tonumber(record.mileage) or 0, tonumber(job.mileage) or 0)
    job.vehicleSnapshot = job.vehicleSnapshot or {}
    job.vehicleSnapshot.model = job.vehicleSnapshot.model or record.model
    job.vehicleSnapshot.config = job.vehicleSnapshot.config or deepcopy(record.config)
    job.vehicleSnapshot.partConditions = deepcopy(record.partConditions or {})
    return true
  end

  local function captureExitState(job)
    local vehicle = job and job.vehicleId and getObjectByID(job.vehicleId)
    if not vehicle then return end
    capturePose(job)
    captureEnergy(job)
    saveDamageSnapshot(job, nil)
    if job.inventoryId and overhaul_career_garage_inventory then
      overhaul_career_garage_inventory.updatePartConditions(job.vehicleId, job.inventoryId, function()
        updateJobSnapshotFromInventory(job)
      end)
    end
  end

  return {arrayToQuat = arrayToQuat, arrayToVec3 = arrayToVec3, captureEnergy = captureEnergy,
      captureExitState = captureExitState, capturePose = capturePose,
      clearSessionDamage = clearSessionDamage, currentProfileName = currentProfileName,
      currentSavePath = currentSavePath, damageFilePath = damageFilePath,
      ensureSaveDirectories = ensureSaveDirectories, loadableDamageFilePath = loadableDamageFilePath,
      saveDamageSnapshot = saveDamageSnapshot, sessionDamageFilePath = sessionDamageFilePath,
      tableCount = tableCount, toQuatArray = toQuatArray, toVec3Array = toVec3Array,
      updateJobSnapshotFromInventory = updateJobSnapshotFromInventory}
end
