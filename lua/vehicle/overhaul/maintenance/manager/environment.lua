-- Driving environment: powertrain device state and the per-tick environment snapshot.
-- Each extension load owns its runtime and the parts it calls.
local M = {}

function M.create(inputs)
  local runtime, config, parts = inputs.runtime, inputs.config, inputs.parts
  local warmCoolantTempC = 80

  local function getRootDeviceForCategory(categoryName)
    local cache = runtime.categoryCache[categoryName] or {}
    if cache.rootDeviceName then
      local device = powertrain.getDevice(cache.rootDeviceName)
      if device then
        return device
      end
    end

    if categoryName == 'engine' or categoryName == 'radiator' then
      return runtime.deviceContexts.engine.devices[1] and runtime.deviceContexts.engine.devices[1].device or nil
    end
    return runtime.deviceContexts.transmission.gearboxes[1] and runtime.deviceContexts.transmission.gearboxes[1].device or
               (runtime.deviceContexts.transmission.clutches[1] and runtime.deviceContexts.transmission.clutches[1].device or nil)
  end

  local function getPowertrainDeviceState(rootEntry, rootDevice)
    local powertrainState = rootEntry and rootEntry.integrityState and rootEntry.integrityState.powertrain
    if type(powertrainState) ~= "table" then
      return nil
    end

    local deviceState = rootDevice and powertrainState[rootDevice.name] or nil
    if type(deviceState) ~= "table" then
      for _, candidate in pairs(powertrainState) do
        if type(candidate) == "table" then
          deviceState = candidate
          break
        end
      end
    end

    if type(deviceState) ~= "table" then
      return nil
    end

    return deviceState
  end

  local function getDeviceEntryByName(entries, deviceName)
    if type(entries) ~= "table" or not deviceName then
      return nil
    end

    for _, entry in ipairs(entries) do
      if entry.device and entry.device.name == deviceName then
        return entry
      end
    end

    return nil
  end

  local function getNumericValue(value)
    if type(value) == "table" then
      value = value.val or value.value or value[1]
    end
    return tonumber(value) or 0
  end

  local function observeEngineLoadAndThermals(dt, shared, env, engineEntry, engine, currentAV, redlineAV)
    local rpmCapacity = currentAV / redlineAV
    env.rpmCapacity = config.common.clamp(rpmCapacity, 0, 1.5)
    env.rpmFactor = config.common.clamp(config.common.linearScale(rpmCapacity, 0.35, 0.85, 0, 1), 0, 1)
    env.engineRunningSeconds = currentAV > 20 and config.max(tonumber(dt) or 0, 0) or 0
    env.idleRuntimeSeconds = env.engineRunningSeconds > 0 and env.loadFactor <= 0.15 and env.rpmCapacity <= 0.32 and
                                 env.engineRunningSeconds or 0

    env.coolantTemp = getNumericValue(engine.thermals and engine.thermals.coolantTemperature or nil)
    env.oilTemp = getNumericValue(engine.thermals and engine.thermals.oilTemperature or nil)
    local engineRootPartId = runtime.categoryCache and runtime.categoryCache.engine and runtime.categoryCache.engine.rootPartId or nil
    local engineRootEntry = nil
    if engineRootPartId then
      local partConditions = parts.state.getTrackedPartConditions()
      engineRootEntry = partConditions[engineRootPartId]
    end
    local engineDeviceState = getPowertrainDeviceState(engineRootEntry, engine)
    local thermalFailureState = engineDeviceState and engineDeviceState.thermals or nil
    env.pistonRingsDamaged = engine.thermals and engine.thermals.pistonRingsDamaged == true or
                                 type(thermalFailureState) == "table" and thermalFailureState.pistonRingsDamaged == true or false
    env.heatFactor = config.common.clamp(config.common.linearScale(env.coolantTemp, 90, 125, 0, 1), 0, 1)
    env.overheatFactor = config.common.clamp(config.common.linearScale(env.coolantTemp, 115, 135, 0, 1), 0, 1)
    env.oilHeatFactor = config.common.clamp(config.common.linearScale(env.oilTemp, 105, 145, 0, 1), 0, 1)
    env.oilOverheatFactor = config.common.clamp(config.common.linearScale(env.oilTemp, 135, 170, 0, 1), 0, 1)
    env.isOverheating = env.overheatFactor > 0

    env.torqueNm = config.max(getNumericValue(engineEntry.base.maxTorque or engine.maxTorque or 0), 0)
    env.combustionTorque = config.max(config.abs(getNumericValue(engine.combustionTorque)), 0)
    env.maxTorqueRating = config.max(getNumericValue(engine.maxTorqueRating or engineEntry.base.maxTorqueRating), 0)
    env.torqueFactor = config.common.getTorqueFactor(env.torqueNm)
    local basePower = getNumericValue(engineEntry.base.maxPower or engine.maxPower or 0)
    local normalizedPowerHp = basePower > 10000 and basePower / 745.7 or basePower * 0.98632
    env.powerHp = config.max(tonumber(runtime.state and runtime.state.profile and runtime.state.profile.powerHp) or normalizedPowerHp, 0)
    env.powerFactor = config.common.getPowerFactor(env.powerHp)
    env.outputStressFactor = config.common.getOutputStress(env.powerHp, env.torqueNm, env.maxTorqueRating).engine

    local isWarmNow = env.coolantTemp >= warmCoolantTempC
    local isCoolNow = env.coolantTemp <= 70
    if shared.wasWarm ~= true and isWarmNow then
      shared.wasWarm = true
      shared.warmupEventCount = (tonumber(shared.warmupEventCount) or 0) + 1
      env.warmupEvent = true
    elseif shared.wasWarm == true and isCoolNow then
      shared.wasWarm = false
      shared.cooldownEventCount = (tonumber(shared.cooldownEventCount) or 0) + 1
      env.cooldownEvent = true
    elseif isWarmNow then
      shared.wasWarm = true
    end
  end

  local function newEnvironmentReadings(throttleValue, shared)
    local env = {
      throttleFactor = config.common.clamp(getNumericValue(throttleValue), 0, 1),
      loadFactor = config.common.clamp(getNumericValue(throttleValue), 0, 1),
      rpmFactor = 0,
      heatFactor = 0,
      torqueNm = 0,
      combustionTorque = 0,
      maxTorqueRating = 0,
      torqueFactor = 0,
      coolantTemp = 0,
      oilTemp = 0,
      oilHeatFactor = 0,
      oilOverheatFactor = 0,
      powerHp = 0,
      powerFactor = 0,
      outputStressFactor = 0,
      rpmCapacity = 0,
      vehicleSpeed = math.abs(getNumericValue(electrics and electrics.values and electrics.values.wheelspeed)),
      engineRunningSeconds = 0,
      idleRuntimeSeconds = 0,
      profile = config.common.deepCopy(runtime.state and runtime.state.profile or parts.state.buildDefaultProfile()),
      pistonRingsDamaged = false,
      isOverheating = false,
      overheatFactor = 0,
      warmupEvent = false,
      cooldownEvent = false,
      hotRuntimeSeconds = 0,
      overheatingRuntimeSeconds = 0,
      totalHotRuntimeSeconds = tonumber(shared.totalHotRuntimeSeconds) or 0,
      totalOverheatingRuntimeSeconds = tonumber(shared.totalOverheatingRuntimeSeconds) or 0,
      warmupEventCount = tonumber(shared.warmupEventCount) or 0,
      cooldownEventCount = tonumber(shared.cooldownEventCount) or 0
    }
    return env
  end

  local function buildEnvironmentSnapshot(dt, readOnly)
    local throttleValue = (input and input.state and input.state.throttle) or
                              (electrics and electrics.values and electrics.values.throttle) or 0
    local shared = runtime.runtimeState and runtime.runtimeState.shared or {}
    if readOnly then
      local sharedCopy = {}
      for key, value in pairs(shared) do
        sharedCopy[key] = value
      end
      shared = sharedCopy
    end
    local env = newEnvironmentReadings(throttleValue, shared)

    local engineEntry = runtime.deviceContexts.engine.devices[1]
    local engine = engineEntry and engineEntry.device or nil
    if not engine then
      return env
    end

    env.loadFactor = config.common.clamp(config.max(getNumericValue(engine.engineLoad or engine.instantEngineLoad), env.loadFactor), 0, 1)

    local currentAV = config.max(config.abs(getNumericValue(engine.outputAV1 or engine.inputAV or engine.outputAV2)), 0)
    local redlineAV = config.max(getNumericValue(engineEntry.base.maxAV or engine.maxAV), 1)
    observeEngineLoadAndThermals(dt, shared, env, engineEntry, engine, currentAV, redlineAV)

    env.hotRuntimeSeconds = env.heatFactor > 0 and config.max(tonumber(dt) or 0, 0) or 0
    env.overheatingRuntimeSeconds = env.isOverheating and config.max(tonumber(dt) or 0, 0) or 0
    shared.totalHotRuntimeSeconds = (tonumber(shared.totalHotRuntimeSeconds) or 0) + env.hotRuntimeSeconds
    shared.totalOverheatingRuntimeSeconds = (tonumber(shared.totalOverheatingRuntimeSeconds) or 0) + env.overheatingRuntimeSeconds
    shared.lastCoolantTemp = env.coolantTemp

    env.totalHotRuntimeSeconds = shared.totalHotRuntimeSeconds
    env.totalOverheatingRuntimeSeconds = shared.totalOverheatingRuntimeSeconds
    env.warmupEventCount = shared.warmupEventCount or 0
    env.cooldownEventCount = shared.cooldownEventCount or 0

    return env
  end

  -- Start at the engine's current temperature so loading a warm car does not wear its radiator.
  local function seedCoolantTransitionBaseline()
    local engineEntry = runtime.deviceContexts.engine.devices[1]
    local engine = engineEntry and engineEntry.device or nil
    local coolantTemp = engine and getNumericValue(engine.thermals and engine.thermals.coolantTemperature or nil) or 0
    runtime.runtimeState.shared.wasWarm = coolantTemp >= warmCoolantTempC
  end

  local function buildEnvironment(categoryName, avgMiles, snapshot)
    local env = {
      avgMiles = avgMiles,
      throttleFactor = snapshot and snapshot.throttleFactor or 0,
      loadFactor = snapshot and snapshot.loadFactor or 0,
      rpmFactor = snapshot and snapshot.rpmFactor or 0,
      heatFactor = snapshot and snapshot.heatFactor or 0,
      torqueNm = snapshot and snapshot.torqueNm or 0,
      combustionTorque = snapshot and snapshot.combustionTorque or 0,
      maxTorqueRating = snapshot and snapshot.maxTorqueRating or 0,
      torqueFactor = snapshot and snapshot.torqueFactor or 0,
      coolantTemp = snapshot and snapshot.coolantTemp or 0,
      oilTemp = snapshot and snapshot.oilTemp or 0,
      oilHeatFactor = snapshot and snapshot.oilHeatFactor or 0,
      oilOverheatFactor = snapshot and snapshot.oilOverheatFactor or 0,
      powerHp = snapshot and snapshot.powerHp or 0,
      powerFactor = snapshot and snapshot.powerFactor or 0,
      outputStressFactor = snapshot and snapshot.outputStressFactor or 0,
      rpmCapacity = snapshot and snapshot.rpmCapacity or 0,
      vehicleSpeed = snapshot and snapshot.vehicleSpeed or 0,
      engineRunningSeconds = snapshot and snapshot.engineRunningSeconds or 0,
      idleRuntimeSeconds = snapshot and snapshot.idleRuntimeSeconds or 0,
      profile = config.common.deepCopy(snapshot and snapshot.profile or runtime.state and runtime.state.profile or parts.state.buildDefaultProfile()),
      integrityValue = 1,
      pistonRingsDamaged = snapshot and snapshot.pistonRingsDamaged or false,
      isOverheating = snapshot and snapshot.isOverheating or false,
      overheatFactor = snapshot and snapshot.overheatFactor or 0,
      warmupEvent = snapshot and snapshot.warmupEvent or false,
      cooldownEvent = snapshot and snapshot.cooldownEvent or false,
      hotRuntimeSeconds = snapshot and snapshot.hotRuntimeSeconds or 0,
      overheatingRuntimeSeconds = snapshot and snapshot.overheatingRuntimeSeconds or 0,
      totalHotRuntimeSeconds = snapshot and snapshot.totalHotRuntimeSeconds or 0,
      totalOverheatingRuntimeSeconds = snapshot and snapshot.totalOverheatingRuntimeSeconds or 0,
      warmupEventCount = snapshot and snapshot.warmupEventCount or 0,
      cooldownEventCount = snapshot and snapshot.cooldownEventCount or 0
    }

    if categoryName ~= 'radiator' then
      env.warmupEvent = false
      env.cooldownEvent = false
    end

    local rootPartId = runtime.categoryCache and runtime.categoryCache[categoryName] and runtime.categoryCache[categoryName].rootPartId or nil
    if rootPartId then
      local partConditions = parts.state.getTrackedPartConditions()
      local rootEntry = partConditions and partConditions[rootPartId] or nil
      if rootEntry and tonumber(rootEntry.integrityValue) ~= nil then
        env.integrityValue = config.common.clamp(tonumber(rootEntry.integrityValue), 0, 1)
      end
    end

    return env
  end

  return {
    buildEnvironment = buildEnvironment,
    buildEnvironmentSnapshot = buildEnvironmentSnapshot,
    seedCoolantTransitionBaseline = seedCoolantTransitionBaseline,
    getDeviceEntryByName = getDeviceEntryByName,
    getNumericValue = getNumericValue,
    getPowertrainDeviceState = getPowertrainDeviceState,
    getRootDeviceForCategory = getRootDeviceForCategory,
  }

end

return M
