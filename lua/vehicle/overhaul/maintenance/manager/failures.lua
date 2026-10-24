-- Owns maintenance state progression, category reset and persistent hard-failure application.
-- Read tracked conditions and mileage, failure detection/application, then per-tick category progression.
local M = {}

function M.create(inputs)
  local runtime, config, helpers, parts = inputs.runtime, inputs.config, inputs.helpers, inputs.parts

  local function getOverallMileage(partConditions)
    local maxOdometer = 0
    for _, conditionData in pairs(partConditions or {}) do
      maxOdometer = config.max(maxOdometer, tonumber(conditionData.odometer) or 0)
    end
    return maxOdometer
  end

  -- Hardware detection matches the shop, so hidden categories cannot wear out here.
  local function categoryHasInstalledPowertrainDevice(categoryName)
    local definition = config.partCategories.definitions[categoryName]
    local deviceTypes = definition and definition.installedPowertrainDevices
    if type(deviceTypes) ~= "table" or not deviceTypes[1] then return false end
    for _, partData in pairs(v.data.activePartsData or {}) do
      for _, deviceType in ipairs(deviceTypes) do
        if config.partCategories.partDataHasDeviceType(partData, deviceType) then return true end
      end
    end
    return false
  end

  local function getAverageOdometer(partIds, partConditions, fallbackOdometer)
    local entries = {}
    local valueTotal, valueCount, minValue = 0, 0, nil
    for _, partId in ipairs(partIds or {}) do
      local partConditionData = partConditions[partId]
      if partConditionData and partConditionData.odometer then
        local partValue = tonumber((runtime.activePartInfos and runtime.activePartInfos[partId] or {}).partValue)
        if partValue and partValue > 0 then
          valueTotal = valueTotal + partValue
          valueCount = valueCount + 1
          if not minValue or partValue < minValue then minValue = partValue end
        else
          partValue = nil
        end
        table.insert(entries, {odometer = partConditionData.odometer, value = partValue})
      end
    end
    if #entries == 0 then
      return fallbackOdometer or 0
    end

    -- Cap unpriced parts at the priced total so cosmetic mod parts cannot outweigh the block.
    local unpricedCount = #entries - valueCount
    local fallbackWeight = valueCount > 0 and minValue or 1
    if valueCount > 0 and unpricedCount > 0 then
      local aggregate = fallbackWeight * unpricedCount
      if aggregate > valueTotal then
        fallbackWeight = valueTotal / unpricedCount
      end
    end

    local weightedTotal, weightTotal = 0, 0
    for _, entry in ipairs(entries) do
      local weight = entry.value or fallbackWeight
      weightedTotal = weightedTotal + entry.odometer * weight
      weightTotal = weightTotal + weight
    end
    if weightTotal <= 0 then
      return fallbackOdometer or 0
    end
    return weightedTotal / weightTotal
  end

  local function getCategoryAgeMiles(categoryName, categoryOdometers)
    local odometer = tonumber(categoryOdometers[categoryName]) or 0
    if categoryName == 'radiator' then
      -- coolant also circulates through the engine, so an old block keeps its leak paths
      odometer = config.max(odometer, tonumber(categoryOdometers.engine) or 0)
    end
    return config.partCategories.getClassAgeMiles(odometer * config.common.metersToMiles, runtime.state and runtime.state.profile)
  end

  local function isCategoryBroken(categoryName, partConditions)
    local cache = runtime.categoryCache[categoryName]
    if not cache or not cache.rootPartId then
      return false
    end

    local rootCondition = partConditions and partConditions[cache.rootPartId] or nil
    return rootCondition and tonumber(rootCondition.integrityValue) ~= nil and tonumber(rootCondition.integrityValue) <= 0 or false
  end

  local function isMaintenanceFailureType(categoryName, failureType)
    if type(failureType) ~= "string" then
      return false
    end
    return string.find(failureType, categoryName, 1, true) ~= nil or string.find(failureType, "break", 1, true) ~= nil
  end

  local function refreshLastHardFailureTime()
    if not runtime.state or type(runtime.state.categories) ~= "table" then
      return
    end

    local latestTimestamp = 0
    for _, categoryName in ipairs(config.categoryOrder) do
      local categoryState = runtime.state.categories[categoryName]
      if categoryState and isMaintenanceFailureType(categoryName, categoryState.lastFailureType) then
        latestTimestamp = config.max(latestTimestamp, tonumber(categoryState.lastFailureTime) or 0)
      end
    end

    runtime.state.lastHardFailureTime = latestTimestamp
  end

  local function getCategoryCandidatePartIds(categoryName)
    local candidatePartIds = {}
    local seen = {}

    local function addCandidate(partId)
      if not partId or seen[partId] then
        return
      end
      seen[partId] = true
      table.insert(candidatePartIds, partId)
    end

    local cache = runtime.categoryCache and runtime.categoryCache[categoryName] or nil
    local categoryState = runtime.state and runtime.state.categories and runtime.state.categories[categoryName] or nil
    addCandidate(cache and cache.rootPartId or nil)
    addCandidate(categoryState and categoryState.rootPartId or nil)

    for _, partId in ipairs(cache and cache.partIds or {}) do
      addCandidate(partId)
    end

    for _, partId in ipairs(categoryState and categoryState.cachedPartIds or {}) do
      addCandidate(partId)
    end

    return candidatePartIds
  end

  local function hasMaintenanceFailureState(categoryName, rootEntry, rootDevice)
    local deviceState = parts.environment.getPowertrainDeviceState(rootEntry, rootDevice)
    if type(deviceState) ~= "table" then
      return false
    end

    if deviceState.rlsMaintenanceFailure == true then
      return true
    end

    if categoryName == 'engine' then
      return deviceState.isBroken == true and deviceState.damageFrictionCoef == 2.5 and
                 deviceState.damageDynamicFrictionCoef == 3.5 and deviceState.damageIdleAVReadErrorRangeCoef == 32
    elseif categoryName == 'radiator' then
      return deviceState.radiatorDamage == 0.1
    elseif categoryName == 'transmission' then
      if deviceState.isBroken == true and deviceState.damageFrictionCoef == 50 then
        return true
      end
      return deviceState.damageClutchFreePlayCoef == 20 and deviceState.damageLockTorqueCoef == 0.5 and
                 deviceState.clutchPermanentlyDamaged == true
    end

    return false
  end

  local function sanitizeMaintenanceConditionEntry(rootEntry, hasMaintenanceMarker)
    if type(rootEntry) ~= "table" or not hasMaintenanceMarker then
      return false
    end

    local didSanitize = false
    local integrityValue = tonumber(rootEntry.integrityValue)
    if integrityValue ~= nil and integrityValue < 1 then
      rootEntry.integrityValue = 1
      didSanitize = true
    end

    local powertrainState = type(rootEntry.integrityState) == "table" and rootEntry.integrityState.powertrain or nil
    local powertrainAlreadyHealthy = type(powertrainState) == "table"
    for _, deviceState in pairs(powertrainAlreadyHealthy and powertrainState or {}) do
      if deviceState ~= 1 then
        powertrainAlreadyHealthy = false
        break
      end
    end
    if powertrainState and not powertrainAlreadyHealthy then
      rootEntry.integrityState.powertrain = nil
      if not next(rootEntry.integrityState) then
        rootEntry.integrityState = nil
      elseif type(powertrainState) == "table" then
        local healthyState = {}
        for deviceName in pairs(powertrainState) do
          healthyState[deviceName] = 1
        end
        rootEntry.integrityState.powertrain = healthyState
      end
      didSanitize = true
    end

    return didSanitize
  end

  local function sanitizeCategoryBreakage(partConditions, categoryName, clearFailureHistory)
    if not runtime.state or type(partConditions) ~= "table" then
      return false
    end

    local categoryState = runtime.state.categories and runtime.state.categories[categoryName] or nil
    if type(categoryState) ~= "table" then
      return false
    end
    if categoryState.persistentCareerDamage == true then
      return false
    end

    local rootDevice = parts.environment.getRootDeviceForCategory(categoryName)
    local didSanitize = false

    for _, partId in ipairs(getCategoryCandidatePartIds(categoryName)) do
      local rootEntry = partConditions[partId]
      local looksLikeOurFailure = isMaintenanceFailureType(categoryName, categoryState.lastFailureType) or
                                      hasMaintenanceFailureState(categoryName, rootEntry, rootDevice)

      if sanitizeMaintenanceConditionEntry(rootEntry, looksLikeOurFailure) then
        partConditions[partId] = rootEntry
        didSanitize = true
      end
    end

    if didSanitize or clearFailureHistory then
      categoryState.lastFailureType = nil
      categoryState.lastFailureTime = 0
    end

    return didSanitize
  end

  local function clearCategoryMaintenanceState(partConditions, categoryName, clearFailureHistory, ignorePersistentDamage)
    if not runtime.state or type(partConditions) ~= "table" then
      return false
    end

    local categoryState = runtime.state.categories and runtime.state.categories[categoryName] or nil
    if type(categoryState) ~= "table" then
      return false
    end
    if categoryState.persistentCareerDamage == true and not ignorePersistentDamage then
      return false
    end

    local rootDevice = parts.environment.getRootDeviceForCategory(categoryName)
    local didSanitize = false
    local didResetFlags = false

    for _, partId in ipairs(getCategoryCandidatePartIds(categoryName)) do
      local rootEntry = partConditions[partId]
      local hasPowertrainState = type(rootEntry) == "table" and type(rootEntry.integrityState) == "table" and
                                     rootEntry.integrityState.powertrain ~= nil
      local looksLikeOurFailure = isMaintenanceFailureType(categoryName, categoryState.lastFailureType) or
                                      hasMaintenanceFailureState(categoryName, rootEntry, rootDevice) or
                                      (ignorePersistentDamage and hasPowertrainState and not runtime.runtimeDisabled)

      if sanitizeMaintenanceConditionEntry(rootEntry, looksLikeOurFailure) then
        partConditions[partId] = rootEntry
        didSanitize = true
      end
    end

    if ignorePersistentDamage and (categoryState.persistentCareerDamage == true or categoryState.persistentDamageReason ~= nil) then
      categoryState.persistentCareerDamage = false
      categoryState.persistentDamageReason = nil
      didResetFlags = true
    end

    if didSanitize or clearFailureHistory then
      if categoryState.lastFailureType ~= nil or (categoryState.lastFailureTime or 0) ~= 0 then
        didResetFlags = true
      end
      categoryState.lastFailureType = nil
      categoryState.lastFailureTime = 0
    end

    return didSanitize or didResetFlags
  end

  local function clearMaintenanceBreakage()
    if not runtime.state then
      return false
    end

    local partConditions = parts.state.getTrackedPartConditions()
    local didSanitize = false

    for _, categoryName in ipairs(config.categoryOrder) do
      didSanitize = sanitizeCategoryBreakage(partConditions, categoryName, false) or didSanitize
    end

    if didSanitize then
      helpers.syncPartConditions(partConditions)
      refreshLastHardFailureTime()
      runtime.dirtyState = true
    end

    return didSanitize
  end

  local function clearLiveMaintenanceFailureState(categoryName)
    local function contextFor(targetCategoryName)
      local context = {}
      for key, value in pairs(runtime.deviceContexts and runtime.deviceContexts[targetCategoryName] or {}) do context[key] = value end
      context.runtime = runtime.runtimeState and runtime.runtimeState[targetCategoryName]
      return context
    end
    local function shouldClear(targetCategoryName)
      if categoryName and targetCategoryName ~= categoryName then
        return false
      end
      local categoryState = runtime.state and runtime.state.categories and runtime.state.categories[targetCategoryName] or nil
      return not (type(categoryState) == "table" and categoryState.persistentCareerDamage == true)
    end

    if shouldClear('engine') and config.categoryModules.engine and config.categoryModules.engine.clearFailureRuntime then
      config.categoryModules.engine.clearFailureRuntime(contextFor('engine'))
    end
    if shouldClear('radiator') and config.categoryModules.radiator and config.categoryModules.radiator.clearFailureRuntime then
      config.categoryModules.radiator.clearFailureRuntime(contextFor('radiator'))
    end
    if shouldClear('transmission') and config.categoryModules.transmission and config.categoryModules.transmission.clearFailureRuntime then
      config.categoryModules.transmission.clearFailureRuntime(contextFor('transmission'))
    end
  end

  local function resetCategoryStateForNewRoot(categoryName, partConditions, overallDistanceM)
    if not runtime.state or not runtime.state.categories or not runtime.categoryCache or not runtime.categoryCache[categoryName] then
      return false
    end

    local categoryState = runtime.state.categories[categoryName]
    local cache = runtime.categoryCache[categoryName]
    local newRootPartId = cache.rootPartId
    local oldRootPartId = categoryState.rootPartId

    if not oldRootPartId or not newRootPartId or newRootPartId == oldRootPartId then
      return false
    end

    categoryState.maintenance = config.categoryModules[categoryName].getDefaultMaintenance()
    categoryState.avgOdometer = getAverageOdometer(cache.partIds, partConditions, overallDistanceM)
    categoryState.wearBand = "fresh"
    categoryState.lastFailureType = nil
    categoryState.lastFailureTime = 0
    categoryState.persistentCareerDamage = false
    categoryState.persistentDamageReason = nil
    categoryState.rootPartId = newRootPartId
    categoryState.cachedPartIds = config.common.deepCopy(cache.partIds or {})
    runtime.runtimeState[categoryName] = {}

    parts.state.markStateDirty()
    return true
  end

  local function buildHardFailurePowertrainState(categoryName, reason)
    local powertrainState = {}

    if categoryName == 'engine' then
      local rootDevice = parts.environment.getRootDeviceForCategory(categoryName)
      if rootDevice and config.categoryModules.engine.getHardFailureState then
        powertrainState[rootDevice.name] = config.common.deepCopy(config.categoryModules.engine.getHardFailureState(reason))
      end
    elseif categoryName == 'radiator' then
      local rootDevice = parts.environment.getRootDeviceForCategory(categoryName)
      local entry = rootDevice and parts.environment.getDeviceEntryByName(runtime.deviceContexts.radiator.devices, rootDevice.name) or
                        runtime.deviceContexts.radiator.devices[1]
      if rootDevice and config.categoryModules.radiator.getHardFailureState then
        powertrainState[rootDevice.name] = config.common.deepCopy(config.categoryModules.radiator.getHardFailureState(entry and entry.base or nil))
      end
    elseif categoryName == 'transmission' then
      for _, entry in ipairs(runtime.deviceContexts.transmission.gearboxes or {}) do
        if entry.device and config.categoryModules.transmission.getHardFailureStateForDevice then
          powertrainState[entry.device.name] = config.common.deepCopy(config.categoryModules.transmission.getHardFailureStateForDevice(entry.device))
        end
      end
      for _, entry in ipairs(runtime.deviceContexts.transmission.clutches or {}) do
        if entry.device and config.categoryModules.transmission.getHardFailureStateForDevice then
          powertrainState[entry.device.name] = config.common.deepCopy(config.categoryModules.transmission.getHardFailureStateForDevice(entry.device))
        end
      end
    end

    for _, deviceState in pairs(powertrainState) do
      if type(deviceState) == "table" then
        deviceState.rlsMaintenanceFailure = true
      end
    end

    return next(powertrainState) and powertrainState or nil
  end

  local function applyHardFailure(categoryName, options)
    if not runtime.state or not runtime.state.categories[categoryName] then
      return false
    end

    local cache = runtime.categoryCache and runtime.categoryCache[categoryName] or nil
    if not cache or not cache.rootPartId then
      return false
    end

    local partConditions = parts.state.getTrackedPartConditions()
    local categoryState = runtime.state.categories[categoryName]
    local rootEntry = partConditions[cache.rootPartId] or {}
    local persistentCareerDamage = type(options) == "table" and options.persistentCareerDamage == true
    local persistentDamageReason = type(options) == "table" and options.reason or nil
    local powertrainState = buildHardFailurePowertrainState(categoryName, persistentDamageReason)

    local lastSyncDistanceM = tonumber(runtime.state.lastSyncMileage) or 0
    rootEntry.odometer = tonumber(rootEntry.odometer) or tonumber(categoryState.avgOdometer) or lastSyncDistanceM
    rootEntry.integrityValue = 0
    rootEntry.visualValue = rootEntry.visualValue or 1
    rootEntry.integrityState = type(rootEntry.integrityState) == "table" and rootEntry.integrityState or {}

    if powertrainState then
      rootEntry.integrityState.powertrain = powertrainState
    elseif not next(rootEntry.integrityState) then
      rootEntry.integrityState = nil
    end

    partConditions[cache.rootPartId] = rootEntry
    helpers.syncPartConditions(partConditions)

    runtime.runtimeState[categoryName] = {}
    categoryState.lastFailureTime = os.time()
    categoryState.lastFailureType = persistentCareerDamage and string.format("%s_lockup", categoryName) or
                                        string.format("%s_break", categoryName)
    categoryState.persistentCareerDamage = persistentCareerDamage
    categoryState.persistentDamageReason = persistentDamageReason
    refreshLastHardFailureTime()

    parts.state.markStateDirty()
    parts.failures.updateState(0)
    parts.diagnostics.sendDebugStream(true)
    helpers.sendStateToGE()
    return true
  end

  local function beginMaintenanceTick(dt)
    runtime.tickPartConditions = nil
    local partConditions = parts.state.getTickPartConditions()
    runtime.tickPartConditions = partConditions
    local previousProfileSignature = helpers.getSerializedSignature(runtime.state.profile)
    runtime.state.profile = parts.classification.buildLiveVehicleProfile(runtime.state.profile)
    if previousProfileSignature ~= helpers.getSerializedSignature(runtime.state.profile) then
      runtime.dirtyState = true
    end
    local environmentSnapshot = parts.environment.buildEnvironmentSnapshot(dt)
    local overallDistanceM = runtime.runtimeReadOnly and (tonumber(runtime.state.lastSyncMileage) or 0) or
                             getOverallMileage(partConditions)
    local previousOverallDistanceM = tonumber(runtime.state.lastSyncMileage) or overallDistanceM
    local distanceLimit = config.abs(tonumber(electrics and electrics.values and electrics.values.wheelspeed) or 0) * config.max(dt or 0, 0) * 1.5
    local drivenDeltaMiles = previousOverallDistanceM > 0 and
      math.min(config.max(overallDistanceM - previousOverallDistanceM, 0), distanceLimit) * config.common.metersToMiles or 0
    if config.abs((runtime.state.lastSyncMileage or 0) - overallDistanceM) > 0.0001 then
      runtime.dirtyState = true
    end
    runtime.state.lastSyncMileage = overallDistanceM

    return partConditions, environmentSnapshot, overallDistanceM, drivenDeltaMiles
  end

  local function collectCategoryOdometers(partConditions, overallDistanceM)
    local categoryOdometers = {}
    for _, categoryName in ipairs(config.categoryOrder) do
      local cache = runtime.categoryCache[categoryName]
      local categoryState = runtime.state.categories[categoryName]
      categoryOdometers[categoryName] = runtime.runtimeReadOnly and (tonumber(categoryState.avgOdometer) or overallDistanceM) or
                                          getAverageOdometer(cache.partIds, partConditions, overallDistanceM)
    end

    return categoryOdometers
  end

  local function copyDrivingObservations(derived, env)
    derived.rpmFactor = env.rpmFactor
    derived.loadFactor = env.loadFactor
    derived.heatFactor = env.heatFactor
    derived.torqueNm = env.torqueNm
    derived.combustionTorque = env.combustionTorque
    derived.maxTorqueRating = env.maxTorqueRating
    derived.torqueFactor = env.torqueFactor
    derived.powerHp = env.powerHp
    derived.powerFactor = env.powerFactor
    derived.outputStressFactor = env.outputStressFactor
    derived.rpmCapacity = env.rpmCapacity
    derived.engineRunningSeconds = env.engineRunningSeconds
    derived.idleRuntimeSeconds = env.idleRuntimeSeconds
    derived.profile = config.common.deepCopy(env.profile)
    derived.pistonRingsDamaged = env.pistonRingsDamaged
    derived.coolantTemp = env.coolantTemp
    derived.oilTemp = env.oilTemp
    derived.oilHeatFactor = env.oilHeatFactor
    derived.oilOverheatFactor = env.oilOverheatFactor
    derived.isOverheating = env.isOverheating
    derived.overheatFactor = env.overheatFactor
    derived.hotRuntimeSeconds = env.hotRuntimeSeconds
    derived.overheatingRuntimeSeconds = env.overheatingRuntimeSeconds
    derived.totalHotRuntimeSeconds = env.totalHotRuntimeSeconds
    derived.totalOverheatingRuntimeSeconds = env.totalOverheatingRuntimeSeconds
    derived.warmupEvent = env.warmupEvent
    derived.cooldownEvent = env.cooldownEvent
    derived.warmupEventCount = env.warmupEventCount
    derived.cooldownEventCount = env.cooldownEventCount
  end

  local function applyCategoryEffects(module, categoryName, categoryState, runtimeCategory, dt)
    local deviceContext = runtime.deviceContexts[categoryName]
    module.apply(deviceContext, categoryState, runtimeCategory, runtimeCategory.derived)
    if module.updateAudio then
      module.updateAudio(deviceContext, runtimeCategory, runtimeCategory.derived, dt)
    end
  end

  local function prepareCategoryRuntime(categoryName, partConditions, module, categoryState, deltaMiles, env)
    local runtimeCategory = runtime.runtimeState[categoryName]
    -- Forecast from recent driving so service estimates stay steady while the phone is open.
    env.plannedDriveMultipliers = runtimeCategory.plannedDriveMultipliers
    local derived = module.buildDerived(categoryState, env)
    if deltaMiles > 0 and type(derived.effectiveDriveMultipliers) == "table" then
      local weight = 1 - math.exp(-deltaMiles / config.plannedDriveWindowMiles)
      local planned = runtimeCategory.plannedDriveMultipliers or {}
      for itemName, current in pairs(derived.effectiveDriveMultipliers) do
        current = tonumber(current)
        if current then
          local previous = tonumber(planned[itemName]) or current
          planned[itemName] = previous + (current - previous) * weight
        end
      end
      runtimeCategory.plannedDriveMultipliers = planned
    end
    copyDrivingObservations(derived, env)
    runtimeCategory.derived = derived
    categoryState.wearBand = derived.wear.bandName

    local categoryBroken = isCategoryBroken(categoryName, partConditions)
    return runtimeCategory, derived, categoryBroken
  end

  local function advanceCategoryMaintenanceAndFailures(
    categoryName, dt, partConditions, environmentSnapshot, categoryOdometers, pendingHardFailure,
    module, categoryState, deltaMiles, avgMiles, previousHardwareInstalled, hasHardware
  )
    local env = parts.environment.buildEnvironment(categoryName, avgMiles, environmentSnapshot)
    if not runtime.runtimeReadOnly and hasHardware then
      if previousHardwareInstalled == false then
        -- Newly visible hardware uses its own age; draining a lifetime as one increment would empty every item.
        local seeded = module.getDefaultMaintenance()
        -- Use radiator age here so fitting it to an old engine does not seed it as already worn.
        local seedValue = config.partCategories.getInitialWearSeedValue(config.partCategories.getClassAgeMiles(
          (categoryOdometers[categoryName] or 0) * config.common.metersToMiles, runtime.state and runtime.state.profile))
        for itemName in pairs(seeded) do
          seeded[itemName] = seedValue
        end
        categoryState.maintenance = seeded
      else
        categoryState.maintenance = module.drainMaintenance(categoryState.maintenance, deltaMiles, avgMiles, env)
      end
    end

    local runtimeCategory, derived, categoryBroken = prepareCategoryRuntime(
      categoryName, partConditions, module, categoryState, deltaMiles, env
    )
    if categoryBroken or not hasHardware then
      runtimeCategory.activeSymptom = nil
      runtimeCategory.symptomTimer = 0
      runtimeCategory.cooldownTimer = 0
    else
      module.stepRuntime(runtimeCategory, categoryState, derived, env, dt)
      local forcedHardFailureTarget = runtimeCategory.forceHardFailureTarget
      local canRollHardFailure = avgMiles >= (tonumber(module.minimumHardFailureMileage) or math.huge)
      if categoryName == 'engine' and not canRollHardFailure then
        canRollHardFailure = (derived.severeOilStarvation == true or derived.catastrophicOilStarvation == true) or
                                 ((derived.oilStarvationSeverity or 0) >= 0.3 and (derived.integritySeverity or 0) >= 0.25) or
                                 ((derived.oilConditionSeverity or 0) >= 0.28 and
                                     ((derived.loadFactor or 0) >= 0.65 or (derived.rpmFactor or 0) >= 0.65))
      end
      if type(forcedHardFailureTarget) == "string" then
        if not pendingHardFailure and not isCategoryBroken(forcedHardFailureTarget, partConditions) then
          pendingHardFailure = {
            categoryName = forcedHardFailureTarget,
            persistentCareerDamage = runtimeCategory.forceHardFailurePersistent == true,
            reason = runtimeCategory.forceHardFailureReason
          }
        end
      elseif canRollHardFailure and config.common.rollChance(derived.hardFailureRate, dt) then
        pendingHardFailure = pendingHardFailure or {categoryName = categoryName}
      end
    end

    if hasHardware and not categoryBroken and not pendingHardFailure then
      applyCategoryEffects(module, categoryName, categoryState, runtimeCategory, dt)
    end
    return pendingHardFailure
  end

  local function updateCategory(categoryName, dt, partConditions, environmentSnapshot, drivenDeltaMiles, categoryOdometers, pendingHardFailure)
    local module = config.categoryModules[categoryName]
    local cache = runtime.categoryCache[categoryName]
    local categoryState = runtime.state.categories[categoryName]
    local previousFailureTime = categoryState.lastFailureTime
    local previousFailureType = categoryState.lastFailureType
    local previousWearBand = categoryState.wearBand
    local previousMaintenance = config.common.deepCopy(categoryState.maintenance)
    local previousPartCount = #(categoryState.cachedPartIds or {})
    local currentOdometer = categoryOdometers[categoryName]
    local deltaMiles = runtime.runtimeReadOnly and 0 or drivenDeltaMiles
    local avgMiles = getCategoryAgeMiles(categoryName, categoryOdometers)

    local previousAverageOdometer = categoryState.avgOdometer
    categoryState.avgOdometer = currentOdometer
    categoryState.rootPartId = cache and cache.rootPartId or nil
    categoryState.cachedPartIds = config.common.deepCopy(cache.partIds)
    -- Hidden categories have no installed hardware to wear or service.
    local previousHardwareInstalled = categoryState.hardwareInstalled
    local hasHardware = runtime.hardwareByCategory[categoryName]
    if hasHardware == nil then
      hasHardware = config.partCategories.hasInstalledHardware(categoryName, cache and cache.partIds,
        function(partId) return runtime.activePartInfos[partId] end) or
                            categoryHasInstalledPowertrainDevice(categoryName)
      runtime.hardwareByCategory[categoryName] = hasHardware
    end
    categoryState.hardwareInstalled = hasHardware
    pendingHardFailure = advanceCategoryMaintenanceAndFailures(
      categoryName, dt, partConditions, environmentSnapshot, categoryOdometers, pendingHardFailure,
      module, categoryState, deltaMiles, avgMiles, previousHardwareInstalled, hasHardware
    )

    if deltaMiles > 0 or previousWearBand ~= categoryState.wearBand or previousFailureType ~= categoryState.lastFailureType or
        previousFailureTime ~= categoryState.lastFailureTime or previousPartCount ~= #(categoryState.cachedPartIds or {}) or
        config.abs((previousAverageOdometer or 0) - (categoryState.avgOdometer or 0)) > 0.0001 or
        helpers.maintenanceChanged(previousMaintenance, categoryState.maintenance) then
      runtime.dirtyState = true
      parts.state.markDebugStreamDirty()
    end
    return pendingHardFailure
  end

  local function updateState(dt)
    if not runtime.state then return end
    local partConditions, environmentSnapshot, overallDistanceM, drivenDeltaMiles = beginMaintenanceTick(dt)
    local categoryOdometers = collectCategoryOdometers(partConditions, overallDistanceM)
    local pendingHardFailure
    for _, categoryName in ipairs(config.categoryOrder) do
      pendingHardFailure = updateCategory(categoryName, dt, partConditions, environmentSnapshot, drivenDeltaMiles,
        categoryOdometers, pendingHardFailure)
    end
    runtime.tickPartConditions = nil
    if pendingHardFailure then
      applyHardFailure(pendingHardFailure.categoryName, pendingHardFailure)
    end
  end

  return {
    applyHardFailure = applyHardFailure,
    clearCategoryMaintenanceState = clearCategoryMaintenanceState,
    clearLiveMaintenanceFailureState = clearLiveMaintenanceFailureState,
    clearMaintenanceBreakage = clearMaintenanceBreakage,
    getAverageOdometer = getAverageOdometer,
    getOverallMileage = getOverallMileage,
    isCategoryBroken = isCategoryBroken,
    refreshLastHardFailureTime = refreshLastHardFailureTime,
    resetCategoryStateForNewRoot = resetCategoryStateForNewRoot,
    updateState = updateState,
  }

end

return M
