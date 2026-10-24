-- Maintenance state: default and normalized profiles and the tracked part conditions.
-- Each extension load owns its runtime and the parts it calls.
local M = {}

function M.create(inputs)
  local runtime, config = inputs.runtime, inputs.config

  local function buildDefaultCategoryState(categoryName)
    return {
      avgOdometer = 0,
      wearBand = "fresh",
      lastFailureTime = 0,
      lastFailureType = nil,
      persistentCareerDamage = false,
      persistentDamageReason = nil,
      rootPartId = nil,
      cachedPartIds = {},
      maintenance = config.categoryModules[categoryName].getDefaultMaintenance()
    }
  end

  local function buildDefaultProfile()
    return {
      class = 'passenger',
      classSource = 'default',
      capacities = config.common.getClassDefaultCapacities('passenger'),
      fuelType = 'gasoline',
      isDiesel = false,
      curbWeightKg = 0,
      engineMassKg = 0,
      powerHp = 0,
      torqueNm = 0,
      modelFamily = nil
    }
  end

  local function normalizeProfile(source)
    local profile = buildDefaultProfile()
    source = type(source) == 'table' and source or {}
    local validClasses = {passenger = true, lightTruck = true, mediumTruck = true, heavyTruck = true}
    profile.class = validClasses[source.class] and source.class or profile.class
    profile.classSource = source.classSource or profile.classSource
    profile.capacities = config.common.getClassDefaultCapacities(profile.class)
    if type(source.capacities) == 'table' then
      for _, kind in ipairs({'oil', 'coolant', 'transmission'}) do
        local value = tonumber(source.capacities[kind])
        if value and value > 0 then
          profile.capacities[kind] = value
        end
      end
    end
    profile.fuelType = string.lower(tostring(source.fuelType or profile.fuelType))
    profile.isDiesel = source.isDiesel == true or string.find(string.lower(profile.fuelType), 'diesel', 1, true) ~= nil
    if profile.isDiesel then
      profile.fuelType = 'diesel'
    end
    profile.curbWeightKg = config.max(tonumber(source.curbWeightKg) or 0, 0)
    profile.engineMassKg = config.max(tonumber(source.engineMassKg) or 0, 0)
    profile.powerHp = config.max(tonumber(source.powerHp) or 0, 0)
    profile.torqueNm = config.max(tonumber(source.torqueNm) or 0, 0)
    profile.modelFamily = source.modelFamily
    return profile
  end

  local function buildDefaultState()
    return {
      version = 3,
      lastSyncMileage = 0, -- Metres; the persisted key is kept for existing vehicle snapshots.
      lastHardFailureTime = 0,
      profile = buildDefaultProfile(),
      categories = {
        engine = buildDefaultCategoryState('engine'),
        radiator = buildDefaultCategoryState('radiator'),
        transmission = buildDefaultCategoryState('transmission')
      }
    }
  end

  local function resetRuntimeState()
    runtime.runtimeState = {
      engine = {},
      radiator = {},
      transmission = {},
      debug = {
        scenarioPresetId = nil,
        scenarioInputs = nil,
        scenarioUpdatedAt = 0
      },
      shared = {
        wasWarm = false,
        warmupEventCount = 0,
        cooldownEventCount = 0,
        totalHotRuntimeSeconds = 0,
        totalOverheatingRuntimeSeconds = 0,
        lastCoolantTemp = nil
      }
    }
  end

  local function markDebugStreamDirty()
    runtime.debugStreamDirty = true
  end

  local function markStateDirty()
    runtime.dirtyState = true
    runtime.syncTimer = 0
    markDebugStreamDirty()
  end

  local function mergeTrackedPartConditions(partConditions)
    if type(runtime.trackedPartConditions) == "table" then
      for partId, entry in pairs(runtime.trackedPartConditions) do
        local liveEntry = partConditions[partId]
        local merged = config.common.deepCopy(entry)
        if type(liveEntry) == "table" and liveEntry.odometer ~= nil then
          merged.odometer = liveEntry.odometer
        end
        partConditions[partId] = merged
      end
    end
    return partConditions
  end

  local function getTrackedPartConditions()
    if runtime.tickPartConditions then
      return runtime.tickPartConditions
    end
    local partConditions = partCondition.getConditions() or {}
    config.conditionView.noteFullConditions(partConditions)
    return mergeTrackedPartConditions(partConditions)
  end

  -- A tick reads every part's odometer but the rest of an entry only for category roots.
  local function getTickPartConditions()
    local fullParts = {}
    for _, categoryName in ipairs(config.categoryOrder) do
      local cache = runtime.categoryCache and runtime.categoryCache[categoryName]
      if cache and cache.rootPartId then fullParts[cache.rootPartId] = true end
    end
    local live = config.conditionView.build(fullParts)
    if live == nil then
      return getTrackedPartConditions()
    end
    return mergeTrackedPartConditions(live or {})
  end

  local function clearTrackedPartConditions()
    runtime.trackedPartConditions = nil
    runtime.trackedPartConditionsSignature = nil
    runtime.lastAppliedPartConditionsSignature = nil
    runtime.tickPartConditions = nil
  end

  local function conditionValuesEqual(a, b)
    if a == b then
      return true
    end
    if type(a) ~= "table" or type(b) ~= "table" then
      return false
    end
    for key, value in pairs(a) do
      if not conditionValuesEqual(value, b[key]) then
        return false
      end
    end
    for key in pairs(b) do
      if a[key] == nil then
        return false
      end
    end
    return true
  end

  local function conditionEntryEqualsIgnoringOdometer(entry, liveEntry)
    if type(entry) ~= "table" or type(liveEntry) ~= "table" then
      return false
    end
    local odometer, liveOdometer = entry.odometer, liveEntry.odometer
    entry.odometer, liveEntry.odometer = nil, nil
    local equal = conditionValuesEqual(entry, liveEntry)
    entry.odometer, liveEntry.odometer = odometer, liveOdometer
    return equal
  end

  local function setTrackedPartConditions(partConditions, signature)
    runtime.tickPartConditions = nil
    if type(partConditions) ~= "table" then
      clearTrackedPartConditions()
      return
    end

    local liveConditions = partCondition.getConditions() or {}
    local overrides = nil
    for partId, entry in pairs(partConditions) do
      if not conditionEntryEqualsIgnoringOdometer(entry, liveConditions[partId]) then
        overrides = overrides or {}
        overrides[partId] = config.common.deepCopy(entry)
      end
    end
    runtime.trackedPartConditions = overrides
    runtime.trackedPartConditionsSignature = overrides and signature or nil
  end

  local function normalizeState(snapshot)
    local normalized = buildDefaultState()
    if type(snapshot) ~= "table" then
      return normalized
    end

    normalized.version = 3
    normalized.lastSyncMileage = tonumber(snapshot.lastSyncMileage) or 0
    normalized.lastHardFailureTime = tonumber(snapshot.lastHardFailureTime) or 0
    normalized.profile = normalizeProfile(snapshot.profile)
    for categoryName, categoryState in pairs(normalized.categories) do
      local source = snapshot.categories and snapshot.categories[categoryName] or nil
      if type(source) == "table" then
        categoryState.avgOdometer = tonumber(source.avgOdometer) or 0
        categoryState.wearBand = source.wearBand or categoryState.wearBand
        categoryState.lastFailureTime = tonumber(source.lastFailureTime) or 0
        categoryState.lastFailureType = source.lastFailureType
        categoryState.persistentCareerDamage = source.persistentCareerDamage == true
        categoryState.persistentDamageReason = source.persistentDamageReason
        categoryState.rootPartId = source.rootPartId
        -- Preserve hidden hardware so its later installation re-seeds maintenance.
        if type(source.hardwareInstalled) == "boolean" then
          categoryState.hardwareInstalled = source.hardwareInstalled
        end
        categoryState.cachedPartIds = type(source.cachedPartIds) == "table" and config.common.deepCopy(source.cachedPartIds) or {}
        categoryState.maintenance = config.categoryModules[categoryName].getDefaultMaintenance()
        if type(source.maintenance) == "table" then
          for itemName, itemValue in pairs(source.maintenance) do
            if categoryState.maintenance[itemName] ~= nil then
              categoryState.maintenance[itemName] = config.common.clamp(tonumber(itemValue) or categoryState.maintenance[itemName] or 1, 0, 1)
            end
          end
        end
      end
    end
    return normalized
  end

  return {
    buildDefaultProfile = buildDefaultProfile,
    buildDefaultState = buildDefaultState,
    clearTrackedPartConditions = clearTrackedPartConditions,
    getTickPartConditions = getTickPartConditions,
    getTrackedPartConditions = getTrackedPartConditions,
    markDebugStreamDirty = markDebugStreamDirty,
    markStateDirty = markStateDirty,
    normalizeProfile = normalizeProfile,
    normalizeState = normalizeState,
    resetRuntimeState = resetRuntimeState,
    setTrackedPartConditions = setTrackedPartConditions,
  }

end

return M
