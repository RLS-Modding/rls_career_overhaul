-- Business vehicle part-condition cleanup and bridge initialization.
-- Saved condition keys stay unchanged; malformed devices are removed before the bridge reads them.
local M = {}

local partConditionCompatibility = require("overhaul/lib/parts/conditionCompatibility")

local function collectPartConditionKeysFromPartsTree(partsTree, out)
  out = out or {}
  if not partsTree then
    return out
  end
  if partsTree.chosenPartName and partsTree.path then
    out[partsTree.path .. partsTree.chosenPartName] = true
  end
  if partsTree.children then
    for _, childNode in pairs(partsTree.children) do
      collectPartConditionKeysFromPartsTree(childNode, out)
    end
  end
  return out
end

local function sanitizeSynchroWear(synchroWear)
  if type(synchroWear) ~= "table" then
    return nil
  end

  -- JSON can turn gear indices into strings; reverse gears use negative indices
  local cleaned = {}
  local maxIndex = 0
  for gearIndex, wear in pairs(synchroWear) do
    local index = tonumber(gearIndex)
    if index then
      cleaned[index] = tonumber(wear) or 0
      if index > maxIndex then
        maxIndex = index
      end
    end
  end

  if maxIndex < 1 then
    maxIndex = 6
  end

  for gearIndex = 0, maxIndex do
    cleaned[gearIndex] = cleaned[gearIndex] or 0
  end
  return cleaned
end

local function sanitizePowertrainDeviceState(deviceState)
  if type(deviceState) ~= "table" then
    return nil, true
  end

  if deviceState.synchroWear ~= nil then
    local cleaned = sanitizeSynchroWear(deviceState.synchroWear)
    if cleaned == nil then
      return nil, true
    end
    deviceState.synchroWear = cleaned
  end

  return deviceState, false
end

local function stripEmptyIntegrityState(partCondition)
  if type(partCondition.integrityState) ~= "table" then
    return
  end
  if not next(partCondition.integrityState) then
    partCondition.integrityState = nil
  end
end

local function sanitizePartConditionEntry(partCondition)
  if type(partCondition) ~= "table" then
    return partCondition
  end

  local integrityState = partCondition.integrityState
  if type(integrityState) ~= "table" then
    return partCondition
  end

  local powertrain = integrityState.powertrain
  if type(powertrain) ~= "table" then
    return partCondition
  end

  local didStripDevice = false
  for deviceName, deviceState in pairs(powertrain) do
    local sanitizedState, shouldStrip = sanitizePowertrainDeviceState(deviceState)
    if shouldStrip then
      powertrain[deviceName] = nil
      didStripDevice = true
    elseif sanitizedState ~= deviceState then
      powertrain[deviceName] = sanitizedState
    end
  end

  if didStripDevice and not next(powertrain) then
    integrityState.powertrain = nil
    stripEmptyIntegrityState(partCondition)
  end

  return partCondition
end

function M.collectPartConditionKeysFromPartsTree(partsTree)
  return collectPartConditionKeysFromPartsTree(partsTree, {})
end

function M.sanitizePartConditions(partConditions, opts)
  opts = opts or {}
  if type(partConditions) ~= "table" then
    return {}
  end

  local sanitized = deepcopy(partConditions)
  local validPartKeys = opts.validPartKeys

  for partId, partCondition in pairs(sanitized) do
    if validPartKeys and not validPartKeys[partId] then
      sanitized[partId] = nil
    elseif type(partCondition) == "table" then
      sanitized[partId] = sanitizePartConditionEntry(partCondition)
    end
  end

  return partConditionCompatibility.normalizeEmptyIntegrityStates(sanitized)
end

function M.applyInitPartConditions(vehObj, partConditions, odometer, integrity, visual, opts)
  if not vehObj or not core_vehicleBridge or not core_vehicleBridge.executeAction then
    return false
  end

  local conditions = partConditions
  if type(conditions) == "table" and next(conditions) then
    conditions = M.sanitizePartConditions(conditions, opts)
  else
    conditions = conditions or {}
  end

  core_vehicleBridge.executeAction(vehObj, 'initPartConditions', conditions, odometer or 0, integrity or 1, visual or 1)
  return true
end

function M.reinitializePartConditionsFromVehicle(vehObj, vehicleRecord, onDone)
  if onDone == nil then
    onDone = function() end
  end

  if not vehObj or not core_vehicleBridge then
    onDone(nil)
    return
  end

  local function storeFreshConditions(res)
    local freshConditions = nil
    if res and res.result and type(res.result) == "table" then
      freshConditions = deepcopy(res.result)
      if vehicleRecord then
        vehicleRecord.partConditions = freshConditions
      end
    end
    onDone(freshConditions)
  end

  local function readFreshConditions()
    core_vehicleBridge.requestValue(vehObj, storeFreshConditions, 'getPartConditions')
  end

  if core_vehicleBridge.requestValue then
    core_vehicleBridge.requestValue(vehObj, function()
      core_vehicleBridge.executeAction(vehObj, 'initPartConditions', {}, 0, 1, 1)
      readFreshConditions()
    end, 'ping')
  else
    core_vehicleBridge.executeAction(vehObj, 'initPartConditions', {}, 0, 1, 1)
    readFreshConditions()
  end
end

return M
