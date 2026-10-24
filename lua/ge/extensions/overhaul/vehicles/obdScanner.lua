-- OBD installation, Pro Tuner licensing and saved tune values for the vehicle-side scanner.
-- Read observation time/cache, licensing and tunes, vehicle monitoring, then public API and hooks.
local M = {}
local phoneLayout = require("overhaul/lib/phone/layoutOwner")
local vehicleCommands = require('overhaul/lib/vehicles/vehicleCommands')
local capabilities = require("overhaul/lib/platform/capabilities")

-- Config ------------------------------------------------------------------------------------------

local APP_ID = "obd-scanner"
local PRO_TUNER_LICENSE_PRICE = 5000
local PRO_TUNER_SAVE_DIR = "/career/rls_career"
local PRO_TUNER_SAVE_FILE = PRO_TUNER_SAVE_DIR .. "/obdProTuner.json"

-- State -------------------------------------------------------------------------------------------

local monitoredVehicleId
local recentObservationCache
local liveProTunerByVehicleId = {}
local nativeSpawnValByVehicleId = {}
local proTunerLicense = { purchased = false, purchasedAt = nil }

-- Decay observation windows on sim time so pause and time-scale stay correct.
local simulationElapsed = 0

-- Observation clock -------------------------------------------------------------------------------

local function simulationTime()
  return simulationElapsed
end

local function onUpdate(_, dtSim)
  simulationElapsed = simulationElapsed + (tonumber(dtSim) or 0)
end

-- Recent observations -----------------------------------------------------------------------------

local function clearRecentObservationCache()
  recentObservationCache = nil
end

-- Returns the cached observations with their remaining time, or nil once every window has run out.
local function adjustedRecentObservations(vehicleId)
  local cached = recentObservationCache
  if not cached or cached.vehicleId ~= vehicleId or type(cached.state) ~= "table" then return nil end

  local state = deepcopy(cached.state)
  local elapsed = math.max(0, simulationTime() - cached.recordedAt)
  local fields = {
    "clutchHeatSeconds", "motorRestrictionSeconds", "engineRestrictionSeconds",
    "combustionStabilitySeconds", "misfireRiskSeconds", "transmissionThermalStressSeconds",
    "idleStallSeconds",
  }
  local hasRecent = false
  for _, field in ipairs(fields) do
    local remaining = math.max(0, (tonumber(state[field]) or 0) - elapsed)
    state[field] = remaining
    if remaining > 0 then hasRecent = true end
  end
  for _, event in ipairs(state.damageEvents or {}) do
    if event.active ~= true then
      event.secondsRemaining = math.max(0, (tonumber(event.secondsRemaining) or 0) - elapsed)
    end
    if event.active == true or event.secondsRemaining > 0 then hasRecent = true end
  end
  return hasRecent and state or nil
end

local function recordRecentObservations(vehicleId, state)
  vehicleId = tonumber(vehicleId)
  if not vehicleId or vehicleId ~= monitoredVehicleId or type(state) ~= "table" then return false end
  recentObservationCache = {
    vehicleId = vehicleId,
    state = state,
    recordedAt = simulationTime(),
  }
  return true
end

-- Career checks -----------------------------------------------------------------------------------

local function careerActive()
  return overhaul_career_career and overhaul_career_career.isActive and overhaul_career_career.isActive() == true
end

local function maintenanceModeEnabled()
  if not careerActive() or not overhaul_career_maintenance_maintenanceMode
      or type(overhaul_career_maintenance_maintenanceMode.isEnabled) ~= "function" then
    return nil
  end
  return overhaul_career_maintenance_maintenanceMode.isEnabled() == true
end

local function scannerInstalled()
  local layout = phoneLayout.get()
  return layout and layout.isAppInstalled and layout.isAppInstalled(APP_ID) == true
end

-- Pro Tuner license -------------------------------------------------------------------------------

local currentPlayerVehicle, applyStoredProTuner, getProTunerState

local function hasProTunerLicense()
  return proTunerLicense.purchased == true
end

local function proTunerUnlocked()
  return hasProTunerLicense()
end

local function licensePriceTable()
  return { money = { amount = PRO_TUNER_LICENSE_PRICE, canBeNegative = false } }
end

local function canAffordProTunerLicense()
  if PRO_TUNER_LICENSE_PRICE <= 0 then return true end
  if overhaul_career_economy_payment and type(overhaul_career_economy_payment.canPay) == "function" then
    return overhaul_career_economy_payment.canPay(licensePriceTable()) == true
  end
  if overhaul_career_economy_playerAttributes and type(overhaul_career_economy_playerAttributes.getAttributeValue) == "function" then
    return (tonumber(overhaul_career_economy_playerAttributes.getAttributeValue("money")) or 0) >= PRO_TUNER_LICENSE_PRICE
  end
  return false
end

local function resetProTunerLicense()
  proTunerLicense.purchased = false
  proTunerLicense.purchasedAt = nil
end

local function ensureProTunerSaveDir(currentSavePath, writer)
  if not currentSavePath then return end
  local dirPath = currentSavePath .. PRO_TUNER_SAVE_DIR
  if not writer.exists(dirPath) then
    writer.mkdir(dirPath)
  end
end

local function loadProTunerLicense()
  resetProTunerLicense()
  if not careerActive() or not overhaul_career_saveSystem or type(overhaul_career_saveSystem.getCurrentProfile) ~= "function" then
    return
  end
  local _, currentSavePath = overhaul_career_saveSystem.getCurrentProfile()
  if not currentSavePath then return end
  local data = jsonReadFile(currentSavePath .. PRO_TUNER_SAVE_FILE)
  if type(data) == "table" and data.purchased == true then
    proTunerLicense.purchased = true
    proTunerLicense.purchasedAt = tonumber(data.purchasedAt)
  end
end

local function saveProTunerLicense(currentSavePath, writer)
  if not careerActive() or not overhaul_career_saveSystem or type(overhaul_career_saveSystem.jsonWriteFileSafe) ~= "function" then
    return
  end
  if not currentSavePath then
    local _, path = overhaul_career_saveSystem.getCurrentProfile()
    currentSavePath = path
  end
  if not currentSavePath then return end
  if proTunerLicense.purchased ~= true and not FS:fileExists(currentSavePath .. PRO_TUNER_SAVE_FILE) then
    return
  end
  ensureProTunerSaveDir(currentSavePath, writer)
  overhaul_career_saveSystem.jsonWriteFileSafe(currentSavePath .. PRO_TUNER_SAVE_FILE, {
    purchased = proTunerLicense.purchased == true,
    purchasedAt = proTunerLicense.purchasedAt,
  }, true)
end

local function proTunerAccessFields()
  local owned = hasProTunerLicense()
  local unlocked = proTunerUnlocked()
  local reason
  if not unlocked then
    reason = "Unlock Kapoow Racing PRO Tuner to adjust wastegate from this scanner."
  end
  return {
    enabled = true,
    unlocked = unlocked,
    licenseOwned = owned,
    price = PRO_TUNER_LICENSE_PRICE,
    canAfford = canAffordProTunerLicense(),
    reason = reason,
  }
end

local function withProTunerAccess(state)
  state = state or {}
  for key, value in pairs(proTunerAccessFields()) do
    if state[key] == nil then
      state[key] = value
    end
  end
  state.enabled = true
  state.unlocked = proTunerUnlocked()
  return state
end

local function purchaseProTunerLicense()
  if not careerActive() or hasProTunerLicense() then
    return getProTunerState()
  end
  if not canAffordProTunerLicense() then
    return getProTunerState()
  end
  if overhaul_career_economy_payment and type(overhaul_career_economy_payment.pay) == "function" then
    if overhaul_career_economy_payment.pay(licensePriceTable(), require("overhaul/lib/finance/metadata").tag({ label = "Kapoow Racing PRO Tuner" }, "purchase", {vehicleRelated = false})) ~= true then
      return getProTunerState()
    end
  elseif overhaul_career_economy_playerAttributes and type(overhaul_career_economy_playerAttributes.addAttributes) == "function" then
    overhaul_career_economy_playerAttributes.addAttributes({ money = -PRO_TUNER_LICENSE_PRICE }, require("overhaul/lib/finance/metadata").tag({ label = "Kapoow Racing PRO Tuner" }, "purchase", {vehicleRelated = false}))
  else
    return getProTunerState()
  end
  proTunerLicense.purchased = true
  proTunerLicense.purchasedAt = os.time()
  -- Persist with the career save so money and license cannot diverge.
  if overhaul_career_saveSystem and type(overhaul_career_saveSystem.saveCurrent) == "function" then
    overhaul_career_saveSystem.saveCurrent()
  end
  local vehicle = currentPlayerVehicle()
  if vehicle then
    applyStoredProTuner(vehicle)
  end
  return getProTunerState()
end

-- Tune values -------------------------------------------------------------------------------------

local function snapTuneValue(value, minValue, maxValue, step)
  value = tonumber(value)
  minValue = tonumber(minValue)
  maxValue = tonumber(maxValue)
  step = tonumber(step)
  if not value or not minValue or not maxValue then return nil end
  local lower, upper = math.min(minValue, maxValue), math.max(minValue, maxValue)
  value = math.max(lower, math.min(upper, value))
  if step and step > 0 then
    value = lower + math.floor((value - lower) / step + 0.5) * step
  end
  return tonumber(string.format("%.3f", value))
end

local function getInventoryVehicle(vehicleId)
  if not overhaul_career_garage_inventory or type(overhaul_career_garage_inventory.getInventoryIdFromVehicleId) ~= "function" then
    return nil, nil
  end
  local inventoryId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(vehicleId)
  local vehicles = overhaul_career_garage_inventory.getVehicles and overhaul_career_garage_inventory.getVehicles() or nil
  if not inventoryId or type(vehicles) ~= "table" then return nil, inventoryId end
  return vehicles[inventoryId], inventoryId
end

local function currentNativeVarValue(vehicleId, varName)
  if not varName then return nil end
  local inventoryVehicle = getInventoryVehicle(vehicleId)
  local inventoryVars = inventoryVehicle and inventoryVehicle.config and inventoryVehicle.config.vars
  local fromInventory = inventoryVars and tonumber(inventoryVars[varName])
  if fromInventory ~= nil then return fromInventory end
  local vehData = core_vehicle_manager.getVehicleData(vehicleId)
  local configVars = vehData and vehData.config and vehData.config.vars
  local fromConfig = configVars and tonumber(configVars[varName])
  if fromConfig ~= nil then return fromConfig end
  local varData = vehData and vehData.vdata and vehData.vdata.variables and vehData.vdata.variables[varName]
  return tonumber(varData and varData.val)
end

local function persistNativeTuneVar(vehicleId, varName, value)
  if not varName or value == nil then return end
  local inventoryVehicle, inventoryId = getInventoryVehicle(vehicleId)
  if inventoryVehicle then
    inventoryVehicle.config = inventoryVehicle.config or {}
    inventoryVehicle.config.vars = inventoryVehicle.config.vars or {}
    inventoryVehicle.config.vars[varName] = value
    if inventoryId and overhaul_career_garage_inventory.setVehicleDirty then
      overhaul_career_garage_inventory.setVehicleDirty(inventoryId)
    end
  end
  local vehData = core_vehicle_manager.getVehicleData(vehicleId)
  if not vehData then return end
  vehData.config = vehData.config or {}
  vehData.config.vars = vehData.config.vars or {}
  vehData.config.vars[varName] = value
  -- Tuning menu reads vdata.variables.val; physics still uses the spawn-compiled wastegate.
  local varData = vehData.vdata and vehData.vdata.variables and vehData.vdata.variables[varName]
  if type(varData) == "table" then
    varData.val = value
    varData.valDis = value
  end
end

local function readStoredProTuner(vehicleId)
  local live = liveProTunerByVehicleId[vehicleId]
  local inventoryVehicle = getInventoryVehicle(vehicleId)
  local stored = inventoryVehicle and inventoryVehicle.obdProTuner or live
  if type(stored) ~= "table" then return nil end
  stored.spawnedVarValue = nil
  return stored
end

local function writeStoredProTuner(vehicleId, stored)
  if type(stored) == "table" then
    stored.spawnedVarValue = nil
  end
  liveProTunerByVehicleId[vehicleId] = stored
  local inventoryVehicle = getInventoryVehicle(vehicleId)
  if inventoryVehicle then
    inventoryVehicle.obdProTuner = stored
  end
end

local function slimDynoCurve(curve)
  local points = {}
  if type(curve) ~= "table" then return points end
  for _, point in ipairs(curve) do
    if type(point) == "table" then
      points[#points + 1] = {
        rpm = tonumber(point.rpm) or 0,
        power = tonumber(point.power) or 0,
        torque = tonumber(point.torque) or 0,
      }
    end
  end
  return points
end

local function slimQualityFlags(flags)
  local list = {}
  if type(flags) ~= "table" then return list end
  if flags[1] ~= nil then
    for _, flag in ipairs(flags) do
      if flag then list[#list + 1] = tostring(flag) end
    end
    return list
  end
  for flag, enabled in pairs(flags) do
    if enabled then list[#list + 1] = tostring(flag) end
  end
  return list
end

local function slimDynoPulls(history, limit)
  local pulls = {}
  if type(history) ~= "table" then return pulls end
  limit = tonumber(limit) or 1
  for i = 1, math.min(limit, #history) do
    local entry = history[i]
    if type(entry) == "table" then
      pulls[#pulls + 1] = {
        id = tonumber(entry.id),
        savedAt = tonumber(entry.savedAt) or 0,
        peakPower = tonumber(entry.peakPower) or 0,
        peakTorque = tonumber(entry.peakTorque) or 0,
        peakPowerRpm = tonumber(entry.peakPowerRpm) or 0,
        peakTorqueRpm = tonumber(entry.peakTorqueRpm) or 0,
        valid = entry.valid and true or false,
        pullQuality = entry.pullQuality,
        qualityFlags = slimQualityFlags(entry.qualityFlags),
        acceptedSampleCount = tonumber(entry.acceptedSampleCount) or 0,
        rejectedSampleCount = tonumber(entry.rejectedSampleCount) or 0,
        curve = slimDynoCurve(entry.curve),
      }
    end
  end
  return pulls
end

local function recentDynoPullsForVehicle(vehicleId)
  local _, inventoryId = getInventoryVehicle(vehicleId)
  if not inventoryId then return {} end
  local history = capabilities.peek("businessSession")
  if history then
    return slimDynoPulls(history.getPullHistoryForVehicle(inventoryId), 1)
  end
  return {}
end

local function describePlayerBoostTune(vehicleId)
  if not overhaul_vehicles_adjustableWastegate or type(overhaul_vehicles_adjustableWastegate.describeBoostTune) ~= "function" then
    return { available = false }
  end
  local vehData = core_vehicle_manager.getVehicleData(vehicleId)
  return overhaul_vehicles_adjustableWastegate.describeBoostTune(vehData)
end

local function nativeDesiredValue(vehicleId, desc, stored)
  local fromVars = currentNativeVarValue(vehicleId, desc.varName)
  if fromVars ~= nil then return fromVars end
  if stored and stored.mode ~= "software" and stored.varName == desc.varName and tonumber(stored.varValue) then
    return tonumber(stored.varValue)
  end
  return tonumber(desc.baseline) or 0
end

-- Never persist this. onVehicleSpawned runs before inventory id mapping, so a saved baseline would stack on the already-built tune after retrieve/reload.
local function vehDataSpawnBaseline(vehicleId, varName, value)
  local vehData = core_vehicle_manager.getVehicleData(vehicleId)
  if not vehData or not varName then return nil end
  if value ~= nil then
    vehData.rlsObdNativeSpawnVals = vehData.rlsObdNativeSpawnVals or {}
    vehData.rlsObdNativeSpawnVals[varName] = value
    return value
  end
  local stash = vehData.rlsObdNativeSpawnVals
  return type(stash) == "table" and tonumber(stash[varName]) or nil
end

local function nativeSpawnBaseline(vehicleId, desc)
  local varName = desc and desc.varName
  if nativeSpawnValByVehicleId[vehicleId] ~= nil then
    vehDataSpawnBaseline(vehicleId, varName, nativeSpawnValByVehicleId[vehicleId])
    return nativeSpawnValByVehicleId[vehicleId]
  end
  local fromVehData = vehDataSpawnBaseline(vehicleId, varName)
  if fromVehData ~= nil then
    nativeSpawnValByVehicleId[vehicleId] = fromVehData
    return fromVehData
  end
  local compiled = tonumber(desc and desc.baseline) or 0
  nativeSpawnValByVehicleId[vehicleId] = compiled
  vehDataSpawnBaseline(vehicleId, varName, compiled)
  return compiled
end

local function forgetNativeSpawnBaseline(vehicleId)
  if not vehicleId then return end
  nativeSpawnValByVehicleId[vehicleId] = nil
  local vehData = core_vehicle_manager.getVehicleData(vehicleId)
  if vehData then
    vehData.rlsObdNativeSpawnVals = nil
  end
end

local function offsetFromStored(vehicleId, desc, stored)
  if desc.mode == "native" then
    return nativeDesiredValue(vehicleId, desc, stored) - nativeSpawnBaseline(vehicleId, desc)
  end
  if type(stored) ~= "table" then return 0 end
  return tonumber(stored.offsetPsi) or 0
end

local function proTunerApplyCommand(vehicle)
  if not vehicle then return "" end
  if not proTunerUnlocked() then
    return "if overhaulObdScanner and overhaulObdScanner.setWastegateOffsetPsi then overhaulObdScanner.setWastegateOffsetPsi(0) end; "
  end
  local vehicleId = vehicle:getID()
  local desc = describePlayerBoostTune(vehicleId)
  if not desc.available then return "" end
  local stored = readStoredProTuner(vehicleId)
  local offset = offsetFromStored(vehicleId, desc, stored)
  if desc.mode == "software" then
    local commanded = snapTuneValue((tonumber(desc.baseline) or 0) + offset, desc.min, desc.max, desc.step)
    offset = commanded and (commanded - (tonumber(desc.baseline) or 0)) or 0
  end
  return "if overhaulObdScanner and overhaulObdScanner.setWastegateOffsetPsi then "
    .. vehicleCommands.call('overhaulObdScanner', 'setWastegateOffsetPsi', tonumber(string.format("%.3f", offset))) .. " end; "
end

applyStoredProTuner = function(vehicle)
  if not vehicle then return end
  local command = proTunerApplyCommand(vehicle)
  if command ~= "" then
    vehicle:queueLuaCommand(command)
  end
end

currentPlayerVehicle = function()
  local vehicle = be:getPlayerVehicle(0)
  if not vehicle then return nil, nil end
  return vehicle, vehicle:getID()
end

getProTunerState = function()
  if not proTunerUnlocked() then
    return withProTunerAccess({ available = false, recentPulls = {} })
  end
  local vehicle, vehicleId = currentPlayerVehicle()
  if not vehicle then
    return withProTunerAccess({ available = false, reason = "No vehicle connected.", recentPulls = {} })
  end
  local desc = describePlayerBoostTune(vehicleId)
  local recentPulls = recentDynoPullsForVehicle(vehicleId)
  if not desc.available then
    return withProTunerAccess({
      available = false,
      reason = "Wastegate or turbo not supported by PRO Tuner.",
      recentPulls = recentPulls,
    })
  end
  local stored = readStoredProTuner(vehicleId)
  if desc.mode == "native" and stored and stored.mode == "software" then
    stored = nil
    writeStoredProTuner(vehicleId, nil)
  end
  local offset = offsetFromStored(vehicleId, desc, stored)
  local minValue, maxValue = tonumber(desc.min), tonumber(desc.max)
  if minValue and maxValue and minValue > maxValue then
    minValue, maxValue = maxValue, minValue
  end
  local value
  if desc.mode == "native" then
    value = snapTuneValue(nativeDesiredValue(vehicleId, desc, stored), minValue, maxValue, desc.step)
  else
    value = snapTuneValue((tonumber(desc.baseline) or 0) + offset, minValue, maxValue, desc.step)
  end
  return withProTunerAccess({
    available = true,
    mode = desc.mode,
    varName = desc.varName,
    title = desc.title,
    description = desc.description,
    unit = desc.unit,
    min = minValue,
    max = maxValue,
    step = desc.step,
    value = value,
    openingPressurePsi = desc.openingPressurePsi,
    recentPulls = recentPulls,
  })
end

local function setProTunerValue(value)
  if not proTunerUnlocked() then
    return getProTunerState()
  end
  local vehicle, vehicleId = currentPlayerVehicle()
  if not vehicle then
    return getProTunerState()
  end
  local desc = describePlayerBoostTune(vehicleId)
  if not desc.available then
    return getProTunerState()
  end
  value = snapTuneValue(value, desc.min, desc.max, desc.step)
  if not value then
    return getProTunerState()
  end
  local spawnVal = desc.mode == "native" and nativeSpawnBaseline(vehicleId, desc) or (tonumber(desc.baseline) or 0)
  local offset = value - spawnVal
  writeStoredProTuner(vehicleId, {
    mode = desc.mode,
    offsetPsi = offset,
    varName = desc.varName,
    varValue = desc.mode == "native" and value or nil,
  })
  if desc.mode == "native" then
    persistNativeTuneVar(vehicleId, desc.varName, value)
  end
  applyStoredProTuner(vehicle)
  return getProTunerState()
end

-- Vehicle monitor ---------------------------------------------------------------------------------

local function unloadVehicleMonitor(vehicleId)
  if not vehicleId then return end
  local vehicle = getObjectByID(vehicleId)
  if vehicle then
    vehicle:queueLuaCommand("if extensions.isExtensionLoaded('overhaulObdScanner') then extensions.unload('overhaulObdScanner') end")
  end
end

local function stopVehicleMonitor()
  unloadVehicleMonitor(monitoredVehicleId)
  monitoredVehicleId = nil
  clearRecentObservationCache()
end

local function ensureVehicleMonitor()
  if not careerActive() then
    stopVehicleMonitor()
    return
  end
  if not scannerInstalled() then
    stopVehicleMonitor()
    return
  end
  if gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking() then return end
  local vehicle = be:getPlayerVehicle(0)
  if not vehicle then return end
  local vehicleId = vehicle:getID()
  if monitoredVehicleId and monitoredVehicleId ~= vehicleId then
    unloadVehicleMonitor(monitoredVehicleId)
    clearRecentObservationCache()
  end
  monitoredVehicleId = vehicleId
  local enabled = maintenanceModeEnabled()
  local recent = adjustedRecentObservations(vehicleId)
  local restoreCommand = recent and
    ("if overhaulObdScanner and overhaulObdScanner.restoreRecentObservations then "
      .. vehicleCommands.call('overhaulObdScanner', 'restoreRecentObservations', recent) .. "; end; ") or ""
  vehicle:queueLuaCommand("if not extensions.isExtensionLoaded('overhaulObdScanner') then extensions.load('overhaulObdScanner') end; "
    .. restoreCommand
    .. "if overhaulObdScanner and overhaulObdScanner.setMaintenanceModeEnabled then "
    .. vehicleCommands.call('overhaulObdScanner', 'setMaintenanceModeEnabled', enabled) .. " end; "
    .. proTunerApplyCommand(vehicle))
end

-- Lifecycle ---------------------------------------------------------------------------------------

local function onOverhaulExperimentalMaintenanceModeChanged()
  ensureVehicleMonitor()
end

local function onExtensionLoaded()
  if careerActive() then
    loadProTunerLicense()
  end
  ensureVehicleMonitor()
end

local function onExtensionUnloaded()
  stopVehicleMonitor()
end

local function onVehicleSwitched(_, _, player)
  if player ~= nil and player ~= 0 then return end
  ensureVehicleMonitor()
end

local function onVehicleDestroyed(vehicleId)
  liveProTunerByVehicleId[vehicleId] = nil
  nativeSpawnValByVehicleId[vehicleId] = nil
  if monitoredVehicleId == vehicleId then
    monitoredVehicleId = nil
    clearRecentObservationCache()
  end
end

local function onVehicleSpawned(vehicleId)
  forgetNativeSpawnBaseline(vehicleId)
  if vehicleId ~= be:getPlayerVehicleID(0) then return end
  ensureVehicleMonitor()
end

local function onOverhaulTuningApplied()
  local vehicleId = be:getPlayerVehicleID(0)
  forgetNativeSpawnBaseline(vehicleId)
  ensureVehicleMonitor()
end

local function onPhoneAppInstallStateChanged()
  ensureVehicleMonitor()
end

local function onOverhaulVehicleSaveFinished()
  -- Part-condition saves can reload the vehicle extension on the same object.
  ensureVehicleMonitor()
end

local function onOverhaulModulesActivated()
  if careerActive() then
    loadProTunerLicense()
  end
  ensureVehicleMonitor()
end

local function onOverhaulActive(active)
  if active then
    loadProTunerLicense()
    ensureVehicleMonitor()
  else
    stopVehicleMonitor()
    resetProTunerLicense()
  end
end

local function onOverhaulSaveCurrentProfile(currentSavePath, _, writer)
  writer = writer or overhaul_career_saveSystem.getSaveWriter()
  saveProTunerLicense(currentSavePath, writer)
end

-- The vehicle's overhaulObdScanner asks on load whether Overhaul is active: activate while it is, unload otherwise. Answered here, by the owner, so the callback row names this extension.
local function answerObdScannerGate(vehId)
  local vehicle = getObjectByID(vehId)
  if vehicle then
    vehicle:queueLuaCommand(overhaul_shell_gameMode and overhaul_shell_gameMode.isActive() and ('if overhaulObdScanner then ' .. vehicleCommands.call('overhaulObdScanner', 'activate') .. ' end')
      or 'extensions.unload("overhaulObdScanner")')
  end
end

-- Public API --------------------------------------------------------------------------------------

M.ensureVehicleMonitor = ensureVehicleMonitor
M.recordRecentObservations = recordRecentObservations
M.answerObdScannerGate = answerObdScannerGate
M.getProTunerState = getProTunerState
M.setProTunerValue = setProTunerValue
M.purchaseProTunerLicense = purchaseProTunerLicense

-- Game hooks --------------------------------------------------------------------------------------

M.onUpdate = onUpdate
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onOverhaulModulesActivated = onOverhaulModulesActivated
M.onOverhaulActive = onOverhaulActive
M.onOverhaulSaveCurrentProfile = onOverhaulSaveCurrentProfile
M.onVehicleSwitched = onVehicleSwitched
M.onVehicleDestroyed = onVehicleDestroyed
M.onVehicleSpawned = onVehicleSpawned
M.onOverhaulTuningApplied = onOverhaulTuningApplied
M.onOverhaulExperimentalMaintenanceModeChanged = onOverhaulExperimentalMaintenanceModeChanged
M.onPhoneAppInstallStateChanged = onPhoneAppInstallStateChanged
M.onOverhaulVehicleSaveFinished = onOverhaulVehicleSaveFinished

return M
