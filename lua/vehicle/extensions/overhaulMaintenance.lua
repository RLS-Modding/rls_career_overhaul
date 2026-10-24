-- GE API: initFromSave, clearForDisabledSave, refreshFromCurrentPartConditions, debugForceFailure, debugResetCategory.
-- Owns per-load maintenance state/hooks; read config/state, shared helpers, manager parts, update, lifecycle and exports.
local M = {}
local geCallback = require('vehicle/overhaul/geCallback')

local common = require('vehicle/overhaul/maintenance/common')
local engineCategory = require('vehicle/overhaul/maintenance/engine')
local radiatorCategory = require('vehicle/overhaul/maintenance/radiator')
local transmissionCategory = require('vehicle/overhaul/maintenance/transmission')
local partCategories = require('common/overhaul/maintenancePartCategories')
local conditionView = require('vehicle/overhaul/maintenance/conditionView')

local abs = math.abs
local floor = math.floor
local max = math.max
local min = math.min

-- Config -----------------------------------------------------------------------------------------

local categoryModules = {
  engine = engineCategory,
  radiator = radiatorCategory,
  transmission = transmissionCategory
}

local keywordSets = {}
local rootKeywordSets = {}
for categoryName, definition in pairs(partCategories.definitions) do
  keywordSets[categoryName] = definition.keywords
  rootKeywordSets[categoryName] = definition.rootKeywords
end

local categoryOrder = partCategories.categoryOrder
local categoryLabels = {
  engine = "Engine",
  radiator = "Cooling",
  transmission = "Transmission"
}
local maintenanceLabels = {
  oilCondition = "Oil quality",
  oilLevel = "Oil level",
  ignitionService = "Ignition service",
  coolantLevel = "Coolant level",
  coolantIntegrity = "Coolant integrity",
  fluidCondition = "Fluid quality",
  fluidLevel = "Fluid level"
}
local symptomLabels = {
  roughRunning = "Mechanical roughness",
  ticking = "Mechanical roughness",
  roughIdle = "Rough idle",
  torqueDip = "Torque dip",
  powerFade = "Power fade",
  stall = "Stall",
  coolantSeep = "Coolant seep",
  fanOverwork = "Fan overwork",
  roughShift = "Rough shift",
  shiftDelay = "Shift delay",
  slip = "Slip"
}
local categoryColors = {
  engine = "#f08b49",
  radiator = "#57b8d8",
  transmission = "#b8d75c"
}

local plannedDriveWindowMiles = 25 -- Average recent driving so service forecasts stay steady at idle.
local debugStreamInterval = 0.25

-- State ------------------------------------------------------------------------------------------

local runtime = {}
runtime.state = nil
runtime.runtimeState = nil
runtime.categoryCache = nil
-- Per-category installed-hardware answers; static until the category cache is rebuilt.
runtime.hardwareByCategory = {}
runtime.deviceContexts = nil
runtime.activePartInfos = nil
runtime.partTypeTags = nil
runtime.inventoryId = nil
local updateTimer = 0
runtime.syncTimer = 0
runtime.dirtyState = false
runtime.runtimeDisabled = true
runtime.runtimeReadOnly = false
runtime.trackedPartConditions = nil
runtime.trackedPartConditionsSignature = nil
runtime.lastAppliedPartConditionsSignature = nil
runtime.tickPartConditions = nil
local debugStreamTimer = 0
runtime.debugStreamDirty = true
runtime.debugStreamCache = nil
runtime.debugStreamBuildCount = 0
runtime.debugStreamSendCount = 0

local config = {
  abs = abs,
  categoryColors = categoryColors,
  categoryLabels = categoryLabels,
  categoryModules = categoryModules,
  categoryOrder = categoryOrder,
  common = common,
  conditionView = conditionView,
  debugStreamInterval = debugStreamInterval,
  engineCategory = engineCategory,
  keywordSets = keywordSets,
  maintenanceLabels = maintenanceLabels,
  max = max,
  partCategories = partCategories,
  plannedDriveWindowMiles = plannedDriveWindowMiles,
  rootKeywordSets = rootKeywordSets,
  symptomLabels = symptomLabels,
}
local helpers = {}
local parts = {}

-- Shared helpers ---------------------------------------------------------------------------------

local function buildSnapshot()
  return common.deepCopy(runtime.state or parts.state.buildDefaultState())
end

local function serializeValue(value)
  if type(serialize) ~= "function" then
    return nil
  end
  return serialize(value)
end

local function getSerializedSignature(value)
  return serializeValue(value)
end

local function roundValue(value, places)
  local precision = 10 ^ (places or 0)
  return floor((tonumber(value) or 0) * precision + 0.5) / precision
end

local function maintenanceChanged(previousMaintenance, nextMaintenance)
  if type(previousMaintenance) ~= "table" or type(nextMaintenance) ~= "table" then
    return previousMaintenance ~= nextMaintenance
  end

  for itemName, itemValue in pairs(nextMaintenance) do
    if abs((previousMaintenance[itemName] or 0) - (itemValue or 0)) > 0.0001 then
      return true
    end
  end

  for itemName, itemValue in pairs(previousMaintenance) do
    if abs((nextMaintenance[itemName] or 0) - (itemValue or 0)) > 0.0001 then
      return true
    end
  end

  return false
end

local function sendStateToGE()
  if not runtime.inventoryId or not runtime.state or type(serialize) ~= "function" then
    return
  end
  obj:queueGameEngineLua(geCallback.command("onVehicleMaintenanceStateChanged", tostring(runtime.inventoryId) .. ", " .. serialize(buildSnapshot())))
end

local function syncPartConditions(partConditions)
  if type(partConditions) ~= "table" then
    return false
  end

  local signature = getSerializedSignature(partConditions)
  parts.state.setTrackedPartConditions(partConditions, signature)
  parts.state.markDebugStreamDirty()

  if not runtime.inventoryId or type(serialize) ~= "function" then
    return false
  end

  if signature and signature == runtime.lastAppliedPartConditionsSignature then
    return true
  end

  obj:queueGameEngineLua(geCallback.command("applyMaintenancePartConditions",
    tostring(runtime.inventoryId) .. ", " .. serialize(partConditions) .. ", " .. tostring(obj:getId())))
  runtime.lastAppliedPartConditionsSignature = signature
  return true
end

local function sendDisabledStateToGE()
  if not runtime.inventoryId then
    return
  end

  obj:queueGameEngineLua(geCallback.command("onVehicleMaintenanceStateChanged", tostring(runtime.inventoryId) .. ", nil"))
end

local function resetRuntimeContexts()
  parts.state.resetRuntimeState()
  parts.state.clearTrackedPartConditions()
  parts.classification.rebuildCategoryCache()
  parts.classification.rebuildDeviceContexts()
end

helpers.getSerializedSignature = getSerializedSignature
helpers.maintenanceChanged = maintenanceChanged
helpers.roundValue = roundValue
helpers.sendStateToGE = sendStateToGE
helpers.syncPartConditions = syncPartConditions

-- Parts ------------------------------------------------------------------------------------------

local inputs = {runtime = runtime, config = config, helpers = helpers, parts = parts}
parts.state = require('vehicle/overhaul/maintenance/manager/state').create(inputs)
parts.classification = require('vehicle/overhaul/maintenance/manager/classification').create(inputs)
parts.diagnostics = require('vehicle/overhaul/maintenance/manager/diagnostics').create(inputs)
parts.environment = require('vehicle/overhaul/maintenance/manager/environment').create(inputs)
-- Scenario presets are only consumed by the maintenance debug view.
local function preview()
  if not parts.preview then parts.preview = require('vehicle/overhaul/maintenance/manager/preview').create(inputs) end
  return parts.preview
end
helpers.preview = preview
parts.failures = require('vehicle/overhaul/maintenance/manager/failures').create(inputs)

-- Per-frame update -------------------------------------------------------------------------------

local function updateGFX(dt)
  if runtime.runtimeDisabled or not runtime.state then
    return
  end

  updateTimer = updateTimer + dt
  runtime.syncTimer = runtime.syncTimer + dt

  if updateTimer >= 0.5 then
    parts.failures.updateState(updateTimer)
    updateTimer = 0
  end

  if runtime.dirtyState and runtime.syncTimer >= 2 then
    sendStateToGE()
    runtime.dirtyState = false
    runtime.syncTimer = 0
  end

  debugStreamTimer = debugStreamTimer + dt
  if debugStreamTimer >= debugStreamInterval then
    parts.diagnostics.sendDebugStream(false)
    debugStreamTimer = 0
  end
end

-- Lifecycle --------------------------------------------------------------------------------------

local function onExtensionLoaded()
  runtime.state = parts.state.buildDefaultState()
  resetRuntimeContexts()
  runtime.debugStreamCache = nil
  parts.state.markDebugStreamDirty()
end

local function onReset()
  if runtime.runtimeDisabled then
    M.clearForDisabledSave(runtime.inventoryId)
    return
  end

  resetRuntimeContexts()
  updateTimer = 0
  runtime.syncTimer = 0
  debugStreamTimer = 0
  runtime.debugStreamCache = nil
  parts.state.markDebugStreamDirty()
  if runtime.state then
    parts.failures.updateState(0)
    parts.diagnostics.sendDebugStream(true)
  end
end

-- Public API: maintenance -----------------------------------------------------------------------

local function initFromSave(snapshot, newInventoryId, readOnly)
  runtime.runtimeDisabled = false
  runtime.runtimeReadOnly = readOnly == true
  if runtime.runtimeReadOnly then
    runtime.inventoryId = nil
  else
    runtime.inventoryId = tonumber(newInventoryId) or runtime.inventoryId
  end
  runtime.state = parts.state.normalizeState(snapshot)
  resetRuntimeContexts()
  parts.environment.seedCoolantTransitionBaseline()
  runtime.debugStreamCache = nil
  debugStreamTimer = 0
  parts.state.markDebugStreamDirty()
  local partConditions = parts.state.getTrackedPartConditions()
  local overallDistanceM = parts.failures.getOverallMileage(partConditions)
  if not runtime.runtimeReadOnly then
    for _, categoryName in ipairs(categoryOrder) do
      parts.failures.resetCategoryStateForNewRoot(categoryName, partConditions, overallDistanceM)
    end
  end
  runtime.state.lastSyncMileage = overallDistanceM
  parts.failures.clearLiveMaintenanceFailureState()
  parts.failures.clearMaintenanceBreakage()
  parts.failures.updateState(0)
  parts.diagnostics.sendDebugStream(true)
  sendStateToGE()
end

local function refreshFromCurrentPartConditions()
  runtime.runtimeDisabled = false
  if not runtime.state then
    runtime.state = parts.state.buildDefaultState()
  end
  parts.state.clearTrackedPartConditions()
  local partConditions = parts.state.getTrackedPartConditions()
  parts.classification.rebuildCategoryCache()
  parts.classification.rebuildDeviceContexts()
  runtime.debugStreamCache = nil
  parts.state.markDebugStreamDirty()

  for _, categoryName in ipairs(categoryOrder) do
    local categoryState = runtime.state.categories and runtime.state.categories[categoryName] or nil
    if type(categoryState) == "table" and categoryState.persistentCareerDamage == true and
        not parts.failures.isCategoryBroken(categoryName, partConditions) then
      categoryState.persistentCareerDamage = false
      categoryState.persistentDamageReason = nil
      categoryState.lastFailureType = nil
      categoryState.lastFailureTime = 0
      parts.state.markStateDirty()
    end
  end

  parts.failures.clearLiveMaintenanceFailureState()
  parts.failures.clearMaintenanceBreakage()
  parts.failures.updateState(0)
  parts.diagnostics.sendDebugStream(true)
  sendStateToGE()
end

local function clearForDisabledSave(newInventoryId)
  runtime.inventoryId = tonumber(newInventoryId) or runtime.inventoryId
  runtime.runtimeDisabled = true
  runtime.runtimeReadOnly = false
  runtime.state = parts.state.buildDefaultState()
  resetRuntimeContexts()
  updateTimer = 0
  runtime.syncTimer = 0
  debugStreamTimer = 0
  runtime.debugStreamCache = nil
  parts.state.markDebugStreamDirty()

  local partConditions = parts.state.getTrackedPartConditions()
  local overallDistanceM = parts.failures.getOverallMileage(partConditions)
  local didSanitize = false

  for _, categoryName in ipairs(categoryOrder) do
    local categoryState = runtime.state.categories and runtime.state.categories[categoryName] or nil
    local cache = runtime.categoryCache and runtime.categoryCache[categoryName] or nil
    if categoryState and cache then
      categoryState.rootPartId = cache.rootPartId
      categoryState.cachedPartIds = common.deepCopy(cache.partIds or {})
      categoryState.avgOdometer = parts.failures.getAverageOdometer(cache.partIds, partConditions, overallDistanceM)
    end

    didSanitize = parts.failures.clearCategoryMaintenanceState(partConditions, categoryName, true, true) or didSanitize
  end

  parts.failures.clearLiveMaintenanceFailureState()
  parts.failures.refreshLastHardFailureTime()
  if didSanitize then
    syncPartConditions(partConditions)
  end
  runtime.dirtyState = false
  sendDisabledStateToGE()
  parts.diagnostics.sendDebugStream(true)
end

local function getSnapshot()
  return buildSnapshot()
end

-- Avoid copying a snapshot just to check whether a category has parts.
local function hasCategoryParts(categoryName)
  local source = runtime.state or parts.state.buildDefaultState()
  local category = type(source.categories) == "table" and source.categories[categoryName] or nil
  if type(category) ~= "table" or type(category.cachedPartIds) ~= "table" then return nil end
  return next(category.cachedPartIds) ~= nil
end

-- Reuse device baselines and runtime reasons without copying the debug payload.
local function getLiveConditionState()
  if runtime.runtimeDisabled or not runtime.state then return nil end

  local engineRuntime = runtime.runtimeState and runtime.runtimeState.engine or {}
  local engineMetrics = parts.diagnostics.captureLiveMetrics('engine', engineRuntime, engineRuntime.derived or {})
  local radiatorRuntime = runtime.runtimeState and runtime.runtimeState.radiator or {}
  local radiatorMetrics = parts.diagnostics.captureLiveMetrics('radiator', radiatorRuntime, radiatorRuntime.derived or {})
  local transmissionRuntime = runtime.runtimeState and runtime.runtimeState.transmission or {}
  local transmissionDerived = transmissionRuntime.derived or {}
  local activeSymptom = parts.diagnostics.getRuntimeSymptom(engineRuntime)
  local reason = engineMetrics.powerLimitReason
  local engineRestrictionActive = parts.diagnostics.engineRestrictionIsDiagnostic(engineMetrics, activeSymptom)
  local coolingRestrictionActive = radiatorMetrics.powerLimitActive == true
  local roughness = tonumber(engineMetrics.roughnessCoef)
  local ignitionErrorChance = tonumber(engineMetrics.ignitionErrorChance)

  local outputRestrictionReason = nil
  if coolingRestrictionActive then
    outputRestrictionReason = radiatorMetrics.powerLimitReason
  elseif engineRestrictionActive then
    outputRestrictionReason = reason
  end

  local combustionStability = roughness and roughness > 1.25 and 'elevated' or 'normal'
  local misfireRisk = 'normal'
  if ignitionErrorChance and ignitionErrorChance >= 0.02 then
    misfireRisk = 'high'
  elseif ignitionErrorChance and ignitionErrorChance >= 0.01 then
    misfireRisk = 'elevated'
  end

  local transmissionThermalStress = parts.diagnostics.getTransmissionThermalStress(transmissionDerived)

  return {
    engine = {
      outputRestriction = {
        active = coolingRestrictionActive or engineRestrictionActive,
        reason = outputRestrictionReason,
      },
      combustionStability = combustionStability,
      misfireRisk = misfireRisk,
    },
    transmission = {
      thermalStress = transmissionThermalStress,
    },
  }
end

local function debugForceFailure(categoryName, mode)
  if not runtime.runtimeState or not runtime.runtimeState[categoryName] then
    return
  end
  mode = mode or "symptom"
  if mode == "hard" then
    parts.failures.applyHardFailure(categoryName)
    return
  end
  if categoryName == 'engine' then
    runtime.runtimeState[categoryName].activeSymptom = 'powerFade'
  elseif categoryName == 'radiator' then
    runtime.runtimeState[categoryName].activeSymptom = 'coolantSeep'
  else
    runtime.runtimeState[categoryName].activeSymptom = 'slip'
  end
  runtime.runtimeState[categoryName].symptomTimer = 8
  runtime.runtimeState[categoryName].cooldownTimer = 16
  runtime.state.categories[categoryName].lastFailureTime = os.time()
  runtime.state.categories[categoryName].lastFailureType = runtime.runtimeState[categoryName].activeSymptom
  parts.state.markStateDirty()
  parts.failures.updateState(0)
  parts.diagnostics.sendDebugStream(true)
  sendStateToGE()
end

local function debugResetCategory(categoryName)
  if not runtime.state or not runtime.state.categories[categoryName] then
    return
  end

  local partConditions = parts.state.getTrackedPartConditions()
  if parts.failures.clearCategoryMaintenanceState(partConditions, categoryName, true, true) then
    syncPartConditions(partConditions)
  end

  runtime.state.categories[categoryName].maintenance = categoryModules[categoryName].getDefaultMaintenance()
  runtime.runtimeState[categoryName] = {}
  parts.failures.clearLiveMaintenanceFailureState(categoryName)
  parts.failures.refreshLastHardFailureTime()
  parts.state.markStateDirty()
  parts.failures.updateState(0)
  parts.diagnostics.sendDebugStream(true)
  sendStateToGE()
end

-- Game hooks -------------------------------------------------------------------------------------

M.onExtensionLoaded = onExtensionLoaded
M.onReset = onReset
M.updateGFX = updateGFX

M.initFromSave = initFromSave
M.refreshFromCurrentPartConditions = refreshFromCurrentPartConditions
M.clearForDisabledSave = clearForDisabledSave
M.getSnapshot = getSnapshot
M.hasCategoryParts = hasCategoryParts
M.getLiveConditionState = getLiveConditionState
M.debugForceFailure = debugForceFailure
M.debugResetCategory = debugResetCategory

return M
