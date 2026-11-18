-- GE API: activate, setWastegateOffsetPsi, setMaintenanceModeEnabled, restoreRecentObservations, requestState.
-- Read state/readers, observations, parts/diagnostics, payload, wastegate, frame updates, requests and lifecycle.
local calibratedAVToRPM = 9.549296596
local boostControl=require('vehicle/rlsBoostControl')
local M = {}
local geCallback = require('vehicle/overhaul/geCallback')

-- Config and state --------------------------------------------------------------------------------
local FUEL_PULL_LOAD, FUEL_PULL_RPM_FRACTION, FUEL_PULL_MIN_SECONDS, FUEL_PULL_GAP_SECONDS = 0.75, 0.4, 0.5, 1.5
local fuelPull, lastFuelPull, ensureWastegateWrap
local UPDATE_INTERVAL = 0.20
local RECENT_EVENT_SECONDS = 300
local RECENT_HANDOFF_INTERVAL = 1
local timer = 0
local recentHandoffTimer = 0
local milRequestMode = nil
local recentClutchHeatSeconds = 0
local recentClutchHeatPeakC = nil
local recentMotorRestrictionSeconds = 0
local recentMotorTorqueAvailability = nil
local recentEngineRestrictionSeconds = 0
local recentEngineRestrictionReason = nil
local recentCombustionStabilitySeconds = 0
local recentMisfireRiskSeconds = 0
local recentMisfireRiskLevel = nil
local recentTransmissionThermalStressSeconds = 0
local recentTransmissionThermalStressLevel = nil
local recentIdleStallSeconds = 0
local idleStallArmed = false
local recentDamageEvents = {}
local wastegateOffsetPsi = 0
local wastegateModeBasePsi = 0
local originalWastegateSetters = {}
local activated = false

-- Damage states a scan tool can explain; device-named powertrain entries are vehicle-specific, so excluded.
local trackedDamage = {
  engine = {
    overRevDanger = true,
    mildOverrevDamage = true,
    catastrophicOverrevDamage = true,
    overTorqueDanger = true,
    catastrophicOverTorqueDamage = true,
    coolantOverheating = true,
    oilOverheating = true,
    starvedOfOil = true,
    oilLevelCritical = true,
    oilLevelTooHigh = true,
    engineIsHydrolocking = true,
    engineReducedTorque = true,
    engineDisabled = true,
    engineLockedUp = true,
    impactDamage = true,
    radiatorLeak = true,
    oilRadiatorLeak = true,
    oilpanLeak = true,
    exhaustBroken = true,
    blockMelted = true,
    cylinderWallsMelted = true,
    turbochargerHot = true,
    inductionSystemDamaged = true,
  },
  gearbox = {
    synchroWear = true,
  },
  pressureTank = {
    deformationLeak = true,
    breakLeak = true,
  },
  drivingDynamics = {
    systemStateDegraded = true,
  },
}

-- Numbers -----------------------------------------------------------------------------------------
local function number(value)
  value = tonumber(value)
  if value and value == value and value ~= math.huge and value ~= -math.huge then return value end
  return nil
end

local function firstNumber(...)
  for i = 1, select("#", ...) do
    local value = number(select(i, ...))
    if value ~= nil then return value end
  end
  return nil
end

-- Powertrain devices ------------------------------------------------------------------------------
local function isCombustionEngine(device)
  -- Substring match: mod engines use types such as "classic_combustionEngine".
  return tostring(device and device.type or ""):find("combustionEngine", 1, true) ~= nil
end

local function getEngine()
  if powertrain and powertrain.getDevice then
    local mainEngine = powertrain.getDevice("mainEngine")
    if mainEngine then return mainEngine end
  end
  local devices = powertrain and powertrain.getDevicesByCategory and powertrain.getDevicesByCategory("engine") or nil
  for _, device in pairs(devices or {}) do
    if isCombustionEngine(device) then return device end
  end
  return devices and devices[1] or nil
end

local function findDescendantByType(device, targetType, visited)
  if type(device) ~= "table" then return nil end
  visited = visited or {}
  if visited[device] then return nil end
  visited[device] = true
  if device.type == targetType then return device end
  for _, child in ipairs(device.children or {}) do
    local found = findDescendantByType(child, targetType, visited)
    if found then return found end
  end
  return nil
end

local function drivesWheels(device)
  return findDescendantByType(device, "differential") ~= nil
end

local function getElectricMotors()
  local result = {}
  local devices = powertrain and powertrain.getDevicesByCategory and powertrain.getDevicesByCategory("engine") or nil
  for _, device in pairs(devices or {}) do
    -- Generators also use the electricMotor type; only motors feeding a differential are traction motors.
    if device.type == "electricMotor" and drivesWheels(device) then result[#result + 1] = device end
  end
  table.sort(result, function(a, b)
    return tostring(a.name or "") < tostring(b.name or "")
  end)
  return result
end

local function getGearbox()
  if powertrain and powertrain.getDevice then
    local mainGearbox = powertrain.getDevice("gearbox")
    if mainGearbox then return mainGearbox end
  end
  local devices = powertrain and powertrain.getDevicesByCategory and powertrain.getDevicesByCategory("gearbox") or nil
  for _, device in pairs(devices or {}) do
    if device.type ~= "rangeBox" then return device end
  end
  return nil
end

local function getClutch()
  local devices = powertrain and powertrain.getDevicesByCategory and powertrain.getDevicesByCategory("clutch") or nil
  return devices and devices[1] or nil
end

local function hasDrivingDynamicsControl()
  if not (controller and controller.getControllersFromPath) then return false end
  for _, deviceController in pairs(controller.getControllersFromPath("drivingDynamics/") or {}) do
    if deviceController.typeName == "drivingDynamics/CMU" then return true end
  end
  return false
end

local function getElectricBatteryCharge()
  if not (energyStorage and energyStorage.getStorages) then return nil end
  local storedEnergy, capacity = 0, 0
  for _, storage in pairs(energyStorage.getStorages() or {}) do
    if type(storage) == "table" and storage.type == "electricBattery" then
      local storageEnergy = number(storage.storedEnergy)
      local storageCapacity = number(storage.energyCapacity)
      if storageEnergy and storageCapacity and storageCapacity > 0 then
        storedEnergy = storedEnergy + storageEnergy
        capacity = capacity + storageCapacity
      end
    end
  end
  if capacity <= 0 then return nil end
  local ratio = storedEnergy / capacity
  return ratio >= 0 and ratio <= 1 and ratio or nil
end

-- Signal readers ----------------------------------------------------------------------------------
local function normalized(value)
  value = number(value)
  if value == nil or value < 0 or value > 1 then return nil end
  return value
end

local function normalizedEngineLoad(value)
  value = number(value)
  if value == nil or value > 1 then return nil end
  -- Regeneration reports negative load; the scanner is stationary-focused, so clamp it at zero.
  return math.max(0, value)
end

local function reportedBoolean(container, key)
  if type(container) ~= "table" or container[key] == nil then return nil end
  if container[key] == true then return true end
  local numeric = number(container[key])
  return numeric ~= nil and numeric ~= 0
end

local function firstReportedBoolean(container, ...)
  for i = 1, select("#", ...) do
    local value = reportedBoolean(container, select(i, ...))
    if value ~= nil then return value end
  end
  return nil
end

local function damageIsActive(value)
  if value == true then return true end
  local numeric = number(value)
  return numeric ~= nil and numeric ~= 0
end

-- Damage events -----------------------------------------------------------------------------------
-- Some native faults are only published to the damage registry, never onto the thermals table.
local function trackerDamageActive(group, name)
  if not damageTracker or type(damageTracker.getDamage) ~= "function" then return nil end
  local ok, value = pcall(damageTracker.getDamage, group, name)
  if not ok or value == nil then return nil end
  return damageIsActive(value)
end

local function damageEventKey(group, name)
  return tostring(group) .. ":" .. tostring(name)
end

local function observeDamageChange(group, name, value)
  if not (trackedDamage[group] and trackedDamage[group][name]) then return end
  local key = damageEventKey(group, name)
  local active = damageIsActive(value)
  local event = recentDamageEvents[key]
  if active then
    recentDamageEvents[key] = {
      group = group,
      name = name,
      active = true,
      secondsRemaining = RECENT_EVENT_SECONDS,
    }
  elseif event and event.active then
    event.active = false
    event.secondsRemaining = RECENT_EVENT_SECONDS
  end
end

local function onDamageDataChanged(_, damageDelta)
  if type(damageDelta) ~= "table" then return end
  for group, values in pairs(damageDelta) do
    if type(values) == "table" and trackedDamage[group] then
      for name, value in pairs(values) do
        observeDamageChange(group, name, value)
      end
    end
  end
end

local registerDamageHook = require("vehicle/overhaul/obd/damageHook")

local function registerDamageListener()
  if not damageTracker or type(damageTracker.registerDamageUpdateCallback) ~= "function" then return end
  registerDamageHook()

  if type(damageTracker.getDamage) == "function" then
    for group, names in pairs(trackedDamage) do
      for name in pairs(names) do
        if damageIsActive(damageTracker.getDamage(group, name)) then
          observeDamageChange(group, name, true)
        end
      end
    end
  end
end

-- A vehicle reset can clear the registry without delivering a false delta.
-- Runs on the timed update, not every frame.
local function reconcileRecentDamageEvents()
  for _, event in pairs(recentDamageEvents) do
    local active = trackerDamageActive(event.group, event.name)
    if active ~= nil and active ~= event.active then
      event.active = active
      event.secondsRemaining = RECENT_EVENT_SECONDS
    end
  end
end

local function updateRecentDamageEvents(elapsed)
  for key, event in pairs(recentDamageEvents) do
    if event.active then
      event.secondsRemaining = RECENT_EVENT_SECONDS
    else
      event.secondsRemaining = math.max(0, (number(event.secondsRemaining) or 0) - elapsed)
      if event.secondsRemaining <= 0 then recentDamageEvents[key] = nil end
    end
  end
end

local function recentDamageEventData()
  local result = {}
  for _, event in pairs(recentDamageEvents) do
    result[#result + 1] = {
      group = event.group,
      name = event.name,
      active = event.active == true,
      secondsRemaining = math.ceil(number(event.secondsRemaining) or 0),
    }
  end
  table.sort(result, function(left, right)
    if left.active ~= right.active then return left.active end
    if left.secondsRemaining ~= right.secondsRemaining then return left.secondsRemaining > right.secondsRemaining end
    return damageEventKey(left.group, left.name) < damageEventKey(right.group, right.name)
  end)
  return result
end

-- Recent observations -----------------------------------------------------------------------------
local function recentObservationHandoff()
  return {
    clutchHeatSeconds = recentClutchHeatSeconds,
    clutchHeatPeakC = recentClutchHeatPeakC,
    motorRestrictionSeconds = recentMotorRestrictionSeconds,
    motorTorqueAvailability = recentMotorTorqueAvailability,
    engineRestrictionSeconds = recentEngineRestrictionSeconds,
    engineRestrictionReason = recentEngineRestrictionReason,
    combustionStabilitySeconds = recentCombustionStabilitySeconds,
    misfireRiskSeconds = recentMisfireRiskSeconds,
    misfireRiskLevel = recentMisfireRiskLevel,
    transmissionThermalStressSeconds = recentTransmissionThermalStressSeconds,
    transmissionThermalStressLevel = recentTransmissionThermalStressLevel,
    idleStallSeconds = recentIdleStallSeconds,
    damageEvents = recentDamageEventData(),
  }
end

-- GE shows nothing for an empty handoff, so sending another empty one changes nothing.
local lastHandoffEmpty = false

local function handoffIsEmpty(handoff)
  for _, field in ipairs({"clutchHeatSeconds", "motorRestrictionSeconds", "engineRestrictionSeconds",
    "combustionStabilitySeconds", "misfireRiskSeconds", "transmissionThermalStressSeconds", "idleStallSeconds"}) do
    if (tonumber(handoff[field]) or 0) > 0 then return false end
  end
  return #handoff.damageEvents == 0
end

local function sendRecentObservationHandoff()
  if type(serialize) ~= "function" then return end
  local handoff = recentObservationHandoff()
  local empty = handoffIsEmpty(handoff)
  if empty and lastHandoffEmpty then return end
  lastHandoffEmpty = empty
  obj:queueGameEngineLua(geCallback.command("recordRecentObservations", tostring(obj:getId()) .. "," .. serialize(handoff)))
end

local function restoreRecentObservations(state)
  if type(state) ~= "table" then return end
  recentClutchHeatSeconds = math.max(recentClutchHeatSeconds, number(state.clutchHeatSeconds) or 0)
  recentClutchHeatPeakC = math.max(recentClutchHeatPeakC or 0, number(state.clutchHeatPeakC) or 0)
  if recentClutchHeatSeconds <= 0 then recentClutchHeatPeakC = nil end

  recentMotorRestrictionSeconds = math.max(recentMotorRestrictionSeconds, number(state.motorRestrictionSeconds) or 0)
  local motorAvailability = number(state.motorTorqueAvailability)
  if motorAvailability then
    recentMotorTorqueAvailability = math.min(recentMotorTorqueAvailability or motorAvailability, motorAvailability)
  end

  recentEngineRestrictionSeconds = math.max(recentEngineRestrictionSeconds, number(state.engineRestrictionSeconds) or 0)
  if recentEngineRestrictionSeconds > 0 and state.engineRestrictionReason ~= nil then
    recentEngineRestrictionReason = state.engineRestrictionReason
  end
  recentCombustionStabilitySeconds = math.max(recentCombustionStabilitySeconds,
    number(state.combustionStabilitySeconds) or 0)
  recentMisfireRiskSeconds = math.max(recentMisfireRiskSeconds, number(state.misfireRiskSeconds) or 0)
  if state.misfireRiskLevel == "high" or
      (state.misfireRiskLevel == "elevated" and recentMisfireRiskLevel ~= "high") then
    recentMisfireRiskLevel = state.misfireRiskLevel
  end
  recentTransmissionThermalStressSeconds = math.max(recentTransmissionThermalStressSeconds,
    number(state.transmissionThermalStressSeconds) or 0)
  recentIdleStallSeconds = math.max(recentIdleStallSeconds, number(state.idleStallSeconds) or 0)
  if state.transmissionThermalStressLevel == "high" or
      (state.transmissionThermalStressLevel == "elevated" and recentTransmissionThermalStressLevel ~= "high") then
    recentTransmissionThermalStressLevel = state.transmissionThermalStressLevel
  end

  for _, event in ipairs(state.damageEvents or {}) do
    if event.group and event.name then
      local key = damageEventKey(event.group, event.name)
      local existing = recentDamageEvents[key]
      -- History survives same-object reloads, but only current damage can assert a fault.
      local live = trackerDamageActive(event.group, event.name)
      local active = live == true or (live == nil and existing and existing.active == true) or false
      local remaining = math.min(RECENT_EVENT_SECONDS, math.max(0, number(event.secondsRemaining) or 0))
      if active or (existing and existing.active) then
        remaining = RECENT_EVENT_SECONDS
      elseif existing then
        -- Repeated monitor setup must not restart an already-cleared event's history.
        remaining = number(existing.secondsRemaining) or 0
      end
      recentDamageEvents[key] = {
        group = event.group,
        name = event.name,
        active = active,
        secondsRemaining = remaining,
      }
    end
  end
end

-- Part names and tuning ---------------------------------------------------------------------------
-- A translation object goes to the phone as-is; matching uses its English key.
local translatedNamePrefix = "ui.vehicleconfig.information.name."
local function partNameOf(part)
  local name = type(part) == "table" and type(part.information) == "table" and part.information.name or nil
  if type(name) == "table" then
    local text = tostring(name.txt or "")
    if text:sub(1, #translatedNamePrefix) == translatedNamePrefix then text = text:sub(#translatedNamePrefix + 1) end
    if text == "" then return nil, "" end
    return name, text
  end
  if name == nil then return nil, "" end
  local text = tostring(name)
  return text ~= "" and text or nil, text
end

local function findActivePart(slotNeedle, nameNeedle, excludedName)
  local activeParts = v and v.data and v.data.activePartsData or nil
  if type(activeParts) ~= "table" then return nil end
  for _, part in pairs(activeParts) do
    local slotType = tostring(type(part) == "table" and part.slotType or ""):lower()
    local displayName, partName = partNameOf(part)
    local lowerName = partName:lower()
    if slotType:find(slotNeedle, 1, true)
      and (not nameNeedle or lowerName:find(nameNeedle, 1, true))
      and (not excludedName or not lowerName:find(excludedName, 1, true)) then
      return part, displayName
    end
  end
  return nil
end

local function findActivePartForPowertrainDevice(deviceName)
  local activeParts = v and v.data and v.data.activePartsData or nil
  if type(activeParts) ~= "table" then return nil end
  for _, part in pairs(activeParts) do
    local partPowertrain = type(part) == "table" and part.powertrain or nil
    for _, row in ipairs(type(partPowertrain) == "table" and partPowertrain or {}) do
      if type(row) == "table" and row[2] == deviceName then
        local displayName = partNameOf(part)
        return part, displayName
      end
    end
  end
  return nil
end

local function deviceHasMode(device, wantedMode)
  for _, mode in pairs(type(device) == "table" and device.availableModes or {}) do
    if mode == wantedMode then return true end
  end
  return false
end

local function transferCaseData(partName)
  if not powertrain then return nil end
  local devices = powertrain.getDevices and powertrain.getDevices() or {}
  local rangeBox, selectableDrive = nil, nil
  for deviceName, device in pairs(devices or {}) do
    if device.type == "rangeBox" and deviceHasMode(device, "high") and deviceHasMode(device, "low") then
      rangeBox = rangeBox or device
    end
    if tostring(deviceName):lower():find("transfer", 1, true)
      and deviceHasMode(device, "connected") and deviceHasMode(device, "disconnected") then
      selectableDrive = selectableDrive or device
    end
  end
  if not partName and not rangeBox and not selectableDrive then return nil end
  local currentDriveMode = selectableDrive and ({connected = "4WD", disconnected = "2WD"})[selectableDrive.mode] or nil
  local currentRangeMode = rangeBox and ({high = "High", low = "Low"})[rangeBox.mode] or nil
  return {
    name = partName,
    driveModes = selectableDrive and {"2WD", "4WD"} or nil,
    rangeModes = rangeBox and {"High", "Low"} or nil,
    currentDriveMode = currentDriveMode,
    currentRangeMode = currentRangeMode,
  }
end

local function findEngineName(engine)
  -- The part that defines the engine device names it; slot wrappers would outscore it on name alone.
  local _, definingName = findActivePartForPowertrainDevice(engine and engine.name)
  if definingName then return definingName end
  local activeParts = v and v.data and v.data.activePartsData or nil
  if type(activeParts) ~= "table" then return nil end
  local bestName, bestScore = nil, 0
  for partKey, part in pairs(activeParts) do
    local slotType = tostring(type(part) == "table" and part.slotType or ""):lower()
    local displayName, partName = partNameOf(part)
    local lowerName = partName:lower()
    local lowerKey = tostring(partKey):lower()
    local isManagement = lowerName:find("management", 1, true)
      or lowerKey:find("ecu", 1, true)
    local isGenericName = lowerName == "engine" or lowerName:find("engine options", 1, true)
    if partName ~= "" and not isManagement and not isGenericName then
      local score = 0
      if slotType == "engine" or slotType:sub(-7) == "_engine" then score = score + 4 end
      if lowerKey:find("engine", 1, true) then score = score + 2 end
      if lowerName:find("engine", 1, true) then score = score + 2 end
      if lowerName:find("generator", 1, true) then score = score + 1 end
      if score > bestScore then bestName, bestScore = displayName, score end
    end
  end
  return bestName
end

local function electricMotorPosition(device)
  local name = tostring(device and device.name or ""):lower()
  if name:find("front", 1, true) then return "Front" end
  local rearIndex = name:match("rear.-(%d+)$")
  if rearIndex then return "Rear axle " .. rearIndex end
  if name:find("rear", 1, true) then return "Rear" end
  return nil
end

local function findElectricMotorName(device)
  local position = electricMotorPosition(device)
  if position and position:find("Rear", 1, true) then
    local rearIndex = tostring(device and device.name or ""):match("(%d+)$")
    local _, name = findActivePart(rearIndex and ("differential_r_" .. rearIndex) or "differential_r", "electric drive")
    if name then return name end
  elseif position == "Front" then
    local name = findEngineName()
    if name then return name end
  end
  return position and (position .. " electric motor") or "Electric motor"
end

local function electricMotorData(device)
  local rearIndex = tostring(device and device.name or ""):match("(%d+)$")
  -- EV reductions are a range box or a torsion reactor; prefer the selectable range box.
  local reduction = findDescendantByType(device, "rangeBox")
    or findDescendantByType(device, "torsionReactor")
  local differential = findDescendantByType(device, "differential")
  local reductionName, differentialName = nil, nil
  if rearIndex then
    local _
    _, reductionName = findActivePart("ev_reduction_r_" .. rearIndex, nil)
    _, differentialName = findActivePart("ev_differential_r_" .. rearIndex, "differential")
  end
  local reductionRatios = {}
  for _, ratio in pairs(reduction and reduction.gearRatios or {}) do
    if number(ratio) then reductionRatios[#reductionRatios + 1] = number(ratio) end
  end
  table.sort(reductionRatios, function(a, b) return a > b end)
  local differentialRatio = differential and number(differential.gearRatio) or nil
  return {
    id = tostring(device.name or "electricMotor"),
    position = electricMotorPosition(device),
    name = findElectricMotorName(device),
    rpm = math.abs(firstNumber(device.outputRPM, device.outputAV1 and device.outputAV1 * calibratedAVToRPM) or 0),
    load = normalizedEngineLoad(device.engineLoad),
    ratedTorqueNm = firstNumber(device.maxTorque, device.torqueData and device.torqueData.maxTorque),
    torqueLimitNm = number(device.maxTorqueLimit),
    maxRpm = firstNumber(device.maxRPM, device.maxAV and device.maxAV * calibratedAVToRPM),
    reductionName = reductionName,
    reductionRatios = reductionRatios,
    reductionRatio = reduction and number(reduction.gearRatio) or nil,
    reductionType = reduction and reduction.type or nil,
    reductionMode = reduction and reduction.mode or nil,
    differentialName = differentialName,
    -- A unity differential just follows the upstream reduction, so it is not a separate final drive.
    finalDriveRatio = differentialRatio and math.abs(differentialRatio - 1) > 0.0001
      and differentialRatio or nil,
    broken = reportedBoolean(device, "isBroken"),
    disabled = reportedBoolean(device, "isDisabled"),
    hasEnergy = reportedBoolean(device, "hasEnergy"),
  }
end

local function findClutchAndFlywheelNames()
  local activeParts = v and v.data and v.data.activePartsData or nil
  if type(activeParts) ~= "table" then return nil, nil end
  local clutchName, clutchScore = nil, 0
  local flywheelName, flywheelScore = nil, 0
  for _, part in pairs(activeParts) do
    local slotType = tostring(type(part) == "table" and part.slotType or ""):lower()
    local displayName, partName = partNameOf(part)
    local lowerName = partName:lower()
    local isClutchSlot = slotType:find("clutch", 1, true) ~= nil
    local isFlywheelSlot = slotType:find("flywheel", 1, true) ~= nil
    local isDifferential = slotType:find("differential", 1, true) ~= nil
    local isOptionsContainer = lowerName:find("options", 1, true) ~= nil
    if not isDifferential and not isOptionsContainer and partName ~= "" and (isClutchSlot or isFlywheelSlot) then
      if lowerName:find("clutch", 1, true) and lowerName ~= "clutch" then
        local score = (isClutchSlot and 2 or 0) + (isFlywheelSlot and 1 or 0)
        if score > clutchScore then
          clutchName, clutchScore = displayName, score
        end
      elseif lowerName:find("flywheel", 1, true) and lowerName ~= "flywheel" then
        local score = isFlywheelSlot and 2 or 1
        if score > flywheelScore then
          flywheelName, flywheelScore = displayName, score
        end
      end
    end
  end
  return clutchName, flywheelName
end

local function finalDriveRatio(axis)
  local activeParts = v and v.data and v.data.activePartsData or nil
  if type(activeParts) ~= "table" then return nil end
  local axisSuffix = "_" .. axis:lower()
  for _, part in pairs(activeParts) do
    local slotType = tostring(type(part) == "table" and part.slotType or ""):lower()
    local _, name = partNameOf(part)
    if slotType:find("finaldrive", 1, true) and slotType:sub(-2) == axisSuffix
      and name:lower():find("final drive", 1, true) then
      return number(name:match("([%d%.]+)%s*:%s*1"))
    end
  end
  return nil
end

local function displayedTuningValue(part, title, actualValue)
  actualValue = number(actualValue)
  if type(part) ~= "table" or type(part.variables) ~= "table" or actualValue == nil then return nil end
  for _, variable in ipairs(part.variables) do
    if type(variable) == "table" and variable[8] == title then
      local minimum, maximum = number(variable[6]), number(variable[7])
      local options = variable[10]
      local displayMin = type(options) == "table" and number(options.minDis) or nil
      local displayMax = type(options) == "table" and number(options.maxDis) or nil
      if minimum and maximum and maximum ~= minimum and displayMin and displayMax then
        return displayMin + (actualValue - minimum) / (maximum - minimum) * (displayMax - displayMin)
      end
    end
  end
  return nil
end

local function partDefinesPowertrainValue(part, deviceName, fieldName)
  if type(part) ~= "table" or type(part.powertrain) ~= "table" then return false end
  for _, row in ipairs(part.powertrain) do
    local options = type(row) == "table" and row[5] or nil
    if type(row) == "table" and row[2] == deviceName
      and type(options) == "table" and options[fieldName] ~= nil then
      return true
    end
  end
  return false
end

local function differentialData(axis)
  local key = axis:lower()
  local deviceName = "differential_" .. axis
  local device = powertrain and powertrain.getDevice and powertrain.getDevice(deviceName) or nil
  local part, name = findActivePartForPowertrainDevice(deviceName)
  if not name then part, name = findActivePart("differential_" .. key, "differential") end
  if not device and not name then return nil end
  return {
    name = name,
    finalDriveRatio = firstNumber(finalDriveRatio(axis), device and device.gearRatio),
    powerLockPercent = displayedTuningValue(part, "Power Lock Rate", device and device.lsdLockCoef),
    coastLockPercent = displayedTuningValue(part, "Coast Lock Rate", device and device.lsdRevLockCoef),
    preloadNm = partDefinesPowertrainValue(part, deviceName, "lsdPreload")
      and device and number(device.lsdPreload) or nil,
  }
end

-- Maintenance bridge ------------------------------------------------------------------------------
local function getMaintenanceManager()
  if extensions.isExtensionLoaded("overhaulMaintenance") ~= true then
    return nil
  end
  local manager = extensions.overhaulMaintenance or rawget(_G, "overhaulMaintenance")
  if type(manager) ~= "table" or type(manager.getSnapshot) ~= "function" then return nil end
  return manager
end

local maintenanceModeEnabled = nil

-- nil when maintenance is not running or does not know the category.
local function maintenanceCategoryHasHardware(categoryName)
  local manager = getMaintenanceManager()
  if not manager or type(manager.hasCategoryParts) ~= "function" then return nil end
  local ok, hasParts = pcall(manager.hasCategoryParts, categoryName)
  if not ok then return nil end
  return hasParts
end

local function getMilRequestMode(engine, thermals, electricValues, hasCoolingSystem, maintenanceLiveConditions)
  if not engine then return nil end

  local nativeDamage = reportedBoolean(thermals, "pistonRingsDamaged") == true
    or reportedBoolean(thermals, "headGasketBlown") == true
    or reportedBoolean(thermals, "connectingRodBearingsDamaged") == true
    or trackerDamageActive("engine", "engineHydrolocked") == true
  if nativeDamage then return "steady" end

  local coolantTemp = firstNumber(electricValues.watertemp, electricValues.coolantTemperature, thermals and thermals.coolantTemperature)
  if hasCoolingSystem ~= false and coolantTemp and coolantTemp >= 120 then return "steady" end

  local ignitionErrorChance = math.max(
    number(engine.fastIgnitionErrorChance) or 0,
    number(engine.slowIgnitionErrorChance) or 0
  )
  if ignitionErrorChance >= 0.02 then return "steady" end

  local engineCondition = maintenanceLiveConditions and maintenanceLiveConditions.engine
  local outputRestriction = engineCondition and engineCondition.outputRestriction
  if maintenanceModeEnabled ~= true or not outputRestriction or outputRestriction.active ~= true then return nil end

  local ratedTorque = number(engine.maxTorque)
  local torqueLimit = number(engine.maxTorqueLimit)
  local seriousRestriction = ratedTorque and ratedTorque > 0 and torqueLimit and torqueLimit < ratedTorque * 0.90
  return seriousRestriction and "pulse" or nil
end

local function collectLiveDevices()
  local manager = getMaintenanceManager()
  local maintenanceLiveConditions = nil
  if manager and type(manager.getLiveConditionState) == "function" then
    local ok, conditions = pcall(manager.getLiveConditionState)
    if ok and type(conditions) == "table" then maintenanceLiveConditions = conditions end
  end
  return {
    ev = electrics and electrics.values or {},
    engine = getEngine(),
    electricMotors = getElectricMotors(),
    gearbox = getGearbox(),
    clutch = getClutch(),
    hasCoolingSystem = maintenanceCategoryHasHardware("radiator"),
    maintenanceLiveConditions = maintenanceLiveConditions,
  }
end

local function observeEngineConditions(conditions)
  if maintenanceModeEnabled ~= true then return end
  local engineConditions = conditions and conditions.engine
  if type(engineConditions) ~= "table" then return end

  local restriction = engineConditions.outputRestriction
  if type(restriction) == "table" and restriction.active == true then
    recentEngineRestrictionReason = restriction.reason
    recentEngineRestrictionSeconds = RECENT_EVENT_SECONDS
  end
  if engineConditions.combustionStability == "elevated" then
    recentCombustionStabilitySeconds = RECENT_EVENT_SECONDS
  end
  if engineConditions.misfireRisk == "elevated" or engineConditions.misfireRisk == "high" then
    if engineConditions.misfireRisk == "high" or recentMisfireRiskLevel ~= "high" then
      recentMisfireRiskLevel = engineConditions.misfireRisk
    end
    recentMisfireRiskSeconds = RECENT_EVENT_SECONDS
  end

  local transmissionConditions = conditions and conditions.transmission
  if type(transmissionConditions) == "table" and
      (transmissionConditions.thermalStress == "elevated" or transmissionConditions.thermalStress == "high") then
    if transmissionConditions.thermalStress == "high" or recentTransmissionThermalStressLevel ~= "high" then
      recentTransmissionThermalStressLevel = transmissionConditions.thermalStress
    end
    recentTransmissionThermalStressSeconds = RECENT_EVENT_SECONDS
  end
end

-- Engine diagnostics ------------------------------------------------------------------------------
-- BeamNG's idle controller misreads speed by up to minIdleAV; once that spans idle, stalls become likely.
local function idleStabilityState(engine)
  if not isCombustionEngine(engine) then return nil end
  local idleAV, minIdleAV = number(engine.idleAV), number(engine.minIdleAV)
  if not idleAV or idleAV <= 0 or not minIdleAV then return nil end
  local spread = (idleAV - minIdleAV) / idleAV
  if spread >= 1 then return "unstable" end
  if spread >= 0.5 then return "rough" end
  return "normal"
end

-- Mirrors BeamNG's thermal constants; warm matches its pre-heated start, and oil has no native warning.
local COOLANT_DAMAGE_C, COOLANT_MAX_C, OIL_DAMAGE_C, OIL_WARN_MARGIN_C = 120, 130, 150, 15
local function thermalLimits(engine)
  if not isCombustionEngine(engine) then return nil end
  local thermalData = engine.thermals and engine.thermals.debugData and engine.thermals.debugData.engineThermalData or {}
  local jbeamData = v and v.data and v.data[engine.name] or {}
  local thermostatC = firstNumber(thermalData.thermostatTemperature, jbeamData.thermostatTemperature, 90)
  return {
    warmC = thermostatC - 10,
    fanC = math.max(firstNumber(jbeamData.radiatorFanTemperature, 110), thermostatC * 1.03 + 2),
    coolantDamageC = COOLANT_DAMAGE_C,
    coolantMaxC = COOLANT_MAX_C,
    oilWarnC = OIL_DAMAGE_C - OIL_WARN_MARGIN_C,
    oilDamageC = OIL_DAMAGE_C,
  }
end

local automaticGearboxTypes = {automaticGearbox = true, cvtGearbox = true, dctGearbox = true}

-- A stall counts only from an unloaded idle, so driver stalls under load are not faults.
local function observeIdleStall(engine, electricValues, gearbox, hasElectricDrive)
  if hasElectricDrive or not isCombustionEngine(engine) or engine.isDisabled
      or (number(engine.ignitionCoef) or 0) <= 0 or (number(engine.remainingFuelRatio) or 1) <= 0 then
    idleStallArmed = false
    return
  end
  if engine.isStalled then
    if idleStallArmed then recentIdleStallSeconds = RECENT_EVENT_SECONDS end
    idleStallArmed = false
    return
  end
  if (number(engine.starterEngagedCoef) or 0) > 0 then
    idleStallArmed = false
    return
  end
  local idleAV = number(engine.idleAV)
  if not idleAV or (number(engine.outputAV1) or 0) < idleAV * 0.5 then return end
  local decoupled = number(electricValues.gearIndex) == 0 or (number(electricValues.clutchRatio) or 1) < 0.1
      or (gearbox and automaticGearboxTypes[gearbox.type] and math.abs(number(electricValues.wheelspeed) or 0) < 1)
  idleStallArmed = (number(electricValues.throttle) or 0) < 0.05 and decoupled == true
end

-- Payload -----------------------------------------------------------------------------------------
-- Motors with propulsion totals; the motor with the lowest torque-limit share sets the restriction.
local function summarizeElectricMotors(motorDevices)
  local motors, propulsionRpm, propulsionLoad = {}, nil, nil
  local worstMotor, worstMotorAvailability = nil, nil
  for _, device in ipairs(motorDevices) do
    local motor = electricMotorData(device)
    motors[#motors + 1] = motor
    if motor.rpm then propulsionRpm = math.max(propulsionRpm or 0, motor.rpm) end
    if motor.load then propulsionLoad = math.max(propulsionLoad or 0, motor.load) end
    if motor.ratedTorqueNm and motor.ratedTorqueNm > 0 and motor.torqueLimitNm then
      local availability = math.max(0, math.min(1, motor.torqueLimitNm / motor.ratedTorqueNm))
      if not worstMotorAvailability or availability < worstMotorAvailability then
        worstMotorAvailability = availability
        worstMotor = motor
      end
    end
  end
  return motors, propulsionRpm, propulsionLoad, worstMotor
end

-- A flag is true when any motor reports it, and nil when no motor reports it at all.
local function motorStatusFlags(motors)
  local broken, disabled, hasEnergy = nil, nil, nil
  for _, motor in ipairs(motors) do
    if motor.broken ~= nil then broken = broken == true or motor.broken end
    if motor.disabled ~= nil then disabled = disabled == true or motor.disabled end
    if motor.hasEnergy ~= nil then hasEnergy = hasEnergy == true or motor.hasEnergy end
  end
  return broken, disabled, hasEnergy
end

-- The clutch lock torque scaled by its thermal, damage and wear state; nil without a clutch.
local function clutchLockTorqueNm(clutch)
  local lockTorque = clutch and number(clutch.lockTorque) or nil
  if not lockTorque then return nil end
  return math.max(0, lockTorque
    * (number(clutch.thermalEfficiency) or 1)
    * (number(clutch.damageLockTorqueCoef) or 1)
    * (number(clutch.wearLockTorqueCoef) or 1))
end

local function writeScannerPropulsionReadings(
  result, electricValues, engine, hasElectricDrive, isHybrid, isElectric, hasCoolingSystem, motors,
  propulsionRpm, propulsionLoad, turbocharger, supercharger, hasForcedInduction, wastegateStartPsi,
  turbochargerName, superchargerName, ecuLimiterRpm, engineRpm
)
  result.vehicleId = obj:getId()
  result.maintenanceModeEnabled = maintenanceModeEnabled
  result.vehicleName = v and v.config and (v.config.name or v.config.model) or nil
  result.isElectric = isElectric
  result.isHybrid = isHybrid
  result.hasElectricDrive = hasElectricDrive
  result.hasCoolingSystem = hasCoolingSystem
  result.motors = motors
  result.rpm = propulsionRpm
  result.engineRpm = engineRpm
  result.propulsionLoad = propulsionLoad
  result.engineLoad = engine and (isElectric and normalizedEngineLoad(engine.engineLoad) or normalized(engine.engineLoad)) or nil
  result.idleRpm = engine and engine.idleAV and engine.idleAV * calibratedAVToRPM or nil
  result.ecuLimiterRpm = ecuLimiterRpm
  result.peakPowerRpm = isCombustionEngine(engine) and engine.torqueData and number(engine.torqueData.maxPowerRPM) or nil
  result.revLimiterActive = isCombustionEngine(engine) and engine.hasRevLimiter == true
    and (number(engine.revLimiterWasActiveTimer) or math.huge) < 0.5 or nil
  result.revLimiterType = engine and engine.revLimiterType or nil
  result.revLimiterCutTime = engine and number(engine.revLimiterCutTime) or nil
  result.wastegateStartPsi = wastegateStartPsi
  result.turboBoostPsi = hasForcedInduction and firstNumber(electricValues.boost, electricValues.turboBoost) or nil
  result.forcedInductionType = turbocharger and "Turbocharger" or (supercharger and "Supercharger" or nil)
  result.forcedInductionName = turbochargerName or superchargerName
end

local function writeScannerOperatingReadings(
  result, electricValues, engine, hasElectricDrive, hasCoolingSystem, thermals, generatorRunning
)
  result.ignition = firstNumber(electricValues.ignitionLevel, electricValues.ignition)
  result.engineRunning = firstReportedBoolean(electricValues, "engineRunning", "running")
  result.generatorRunning = generatorRunning
  result.fuel = normalized(electricValues.fuel)
  result.lowFuel = reportedBoolean(electricValues, "lowfuel")
  result.thermalLimits = thermalLimits(engine)
  result.batteryCharge = hasElectricDrive and getElectricBatteryCharge() or nil
  result.airPressurePa = firstNumber(electricValues.mainAirTank_pressureRelative)
  result.lowAirPressure = reportedBoolean(electricValues, "lowAirPressure")
  result.parkingBrakeApplied = firstReportedBoolean(electricValues, "parkingbrake", "parkingbrake_input")
  result.hasDrivingDynamicsControl = hasDrivingDynamicsControl()
  result.checkEngine = reportedBoolean(electricValues, "checkengine")
  result.coolantTemp = hasCoolingSystem ~= false and isCombustionEngine(engine)
    and firstNumber(thermals and thermals.coolantTemperature, electricValues.coolantTemperature, electricValues.watertemp)
    or (hasCoolingSystem ~= false and firstNumber(electricValues.watertemp, electricValues.coolantTemperature, thermals and thermals.coolantTemperature) or nil)
  result.oilTemp = isCombustionEngine(engine)
    and firstNumber(thermals and thermals.oilTemperature, electricValues.oilTemperature, electricValues.oiltemp)
    or firstNumber(electricValues.oiltemp, electricValues.oilTemperature, thermals and thermals.oilTemperature)
end

local function writeScannerRestrictionReadings(
  result, engine, isElectric, worstMotor, overtorqueThreshold, overrevThresholdRpm, motorBroken,
  motorDisabled, motorHasEnergy
)
  result.motorRestrictionRatedTorqueNm = worstMotor and worstMotor.ratedTorqueNm or nil
  result.motorTorqueLimitNm = worstMotor and worstMotor.torqueLimitNm or nil
  result.motorBroken = motorBroken
  result.motorDisabled = motorDisabled
  result.motorHasEnergy = motorHasEnergy
  result.recentMotorTorqueAvailability = recentMotorRestrictionSeconds > 0 and recentMotorTorqueAvailability or nil
  result.recentEngineRestriction = recentEngineRestrictionSeconds > 0 and {
    reason = recentEngineRestrictionReason,
  } or nil
  result.recentCombustionStability = recentCombustionStabilitySeconds > 0 or nil
  result.recentMisfireRisk = recentMisfireRiskSeconds > 0 and recentMisfireRiskLevel or nil
  result.recentTransmissionThermalStress = recentTransmissionThermalStressSeconds > 0 and
    recentTransmissionThermalStressLevel or nil
  result.idleStability = idleStabilityState(engine)
  result.recentIdleStall = recentIdleStallSeconds > 0 or nil
  result.overtorqueThresholdNm = overtorqueThreshold
  result.overrevThresholdRpm = overrevThresholdRpm
  result.motorMaxRpm = isElectric and firstNumber(engine.maxRPM, engine.maxAV and engine.maxAV * calibratedAVToRPM) or nil
end

local function writeScannerComponentReadings(
  result, gearbox, clutch, clutchRatedTorque, clutchAvailableTorque, thermals, engineName,
  gearboxName, clutchName, flywheelName, centerCouplingName, transferCase
)
  result.engineName = engineName
  result.pistonRingsDamaged = reportedBoolean(thermals, "pistonRingsDamaged")
  result.headGasketDamaged = reportedBoolean(thermals, "headGasketBlown")
  result.rodBearingsDamaged = reportedBoolean(thermals, "connectingRodBearingsDamaged")
  result.engineHydrolocked = trackerDamageActive("engine", "engineHydrolocked")
  result.gearboxType = gearbox and gearbox.type or nil
  result.gearboxName = gearboxName
  result.forwardGearCount = gearbox and number(gearbox.maxGearIndex) or nil
  result.clutchName = clutchName
  result.flywheelName = flywheelName
  result.clutchRatedTorqueNm = clutchRatedTorque
  result.clutchAvailableTorqueNm = clutchAvailableTorque
  result.clutchTempC = clutch and number(clutch.clutchTemperature) or nil
  result.clutchWarningTempC = clutch and number(clutch.clutchWarningTemp) or nil
  result.clutchMaxSafeTempC = clutch and number(clutch.clutchMaxSafeTemp) or nil
  result.recentClutchHeatPeakC = recentClutchHeatSeconds > 0 and recentClutchHeatPeakC or nil
  result.recentDamageEvents = recentDamageEventData()
  result.clutchDamaged = reportedBoolean(clutch, "clutchPermanentlyDamaged")
  result.frontDifferential = differentialData("F")
  result.transferCase = transferCase
  result.centerCoupling = centerCouplingName and not (transferCase and (transferCase.driveModes or transferCase.rangeModes))
    and {name = centerCouplingName} or nil
  result.rearDifferential = differentialData("R")
end

local function readScannerEngineLimits(electricValues, engine, hasElectricDrive, isHybrid, motors, propulsionRpm)
  local overtorqueThreshold = engine and firstNumber(
    engine.maxTorqueRating,
    engine.torqueData and engine.torqueData.maxTorqueRating
  ) or nil
  -- BeamNG starts accumulating over-rev damage above maxPhysicalAV.
  local overrevThresholdRpm = engine and engine.maxPhysicalAV and engine.maxPhysicalAV * calibratedAVToRPM or nil
  -- Engines with a limiter clamp maxRPM to it; some mod engines only keep it there.
  local ecuLimiterRpm = engine and firstNumber(
    engine.revLimiterRPM,
    engine.hasRevLimiter == true and engine.maxRPM or nil
  ) or nil
  local engineRpm = engine and math.abs(firstNumber(engine.outputRPM, engine.outputAV1 and engine.outputAV1 * calibratedAVToRPM) or 0) or nil
  if not hasElectricDrive then propulsionRpm = firstNumber(electricValues.rpm, engineRpm) end
  -- A stopped generator reads false, not nil: nil means the vehicle lacks the reading.
  local generatorRunning = nil
  if isHybrid and engineRpm then generatorRunning = engineRpm >= 100 end
  local motorBroken, motorDisabled, motorHasEnergy = motorStatusFlags(motors)
  return overtorqueThreshold, overrevThresholdRpm, ecuLimiterRpm, engineRpm, generatorRunning, motorBroken, motorDisabled, motorHasEnergy, propulsionRpm
end

local function fuelSystemKind(state)
  if type(state)=="table" and state.tune and state.tune.fuelType=="diesel" then return "diesel" end
  if type(state) ~= "table" or state.conversion ~= true then return "gasoline" end
  if state.conversionKind == "nitromethane" then return "nitromethane" end
  if state.conversionKind == "methanol" then return "methanol" end
  return "ethanol"
end

local function fuelSystemLabel(kind)
  if kind=="diesel" then return "Diesel fuel system" end
  if kind == "nitromethane" then return "Nitro 90" end
  if kind == "methanol" then return "M100" end
  if kind == "ethanol" then return "Flex-fuel" end
  return "Standard gasoline"
end

local function ethanolGradeLabel(fraction)
  local percent = math.floor((fraction * 100) * 10 + 0.5) / 10
  if percent == math.floor(percent) then return string.format("E%d", percent) end
  return string.format("E%.1f", percent)
end

local function fuelInUseLabel(telemetry, liters)
  if liters and liters <= 0.05 then return "Empty" end
  local nitro = number(telemetry.nitromethane) or 0
  local methanol = number(telemetry.methanol) or 0
  local ethanol = number(telemetry.ethanol) or 0
  if nitro > 0.001 then
    if math.abs(nitro - 0.9) < 0.002 and math.abs(methanol - 0.1) < 0.002 then return "Nitro 90" end
    return "Mixed nitro fuel"
  end
  if methanol >= 0.98 then return "M100" end
  if methanol > 0.001 then return "Mixed fuels" end
  return ethanolGradeLabel(ethanol)
end

local function connectedFuelLiters(snapshot, record)
  local names = record.tanks
  if type(names) ~= "table" then return nil end
  local total, seen = 0, false
  for _, tankName in pairs(names) do
    local tank = snapshot.tanks and snapshot.tanks[tankName]
    if type(tank) == "table" then
      seen = true
      total = total + (number(tank.liters) or 0)
    end
  end
  if not seen then return nil end
  return total
end

-- Track full-load running and keep the readings of the latest pull: lambda at
-- its highest RPM, and the peak retard and delivery duty anywhere in it.
local function observeFuelPull(engine, dt)
  local runtime = extensions and extensions.rlsFuelRuntime
  local record
  if isCombustionEngine(engine) and (engine.requiredEnergyType == "gasoline" or engine.requiredEnergyType == "diesel")
      and type(runtime) == "table" and type(runtime.getSnapshot) == "function" then
    local ok, snapshot = pcall(runtime.getSnapshot)
    record = ok and type(snapshot) == "table" and snapshot.engines and snapshot.engines[engine.name] or nil
  end
  local telemetry = type(record) == "table" and type(record.telemetry) == "table" and record.telemetry or nil
  local maxRPM = telemetry and type(record.profile) == "table" and number(record.profile.maxRPM)
  local load, rpm = telemetry and number(telemetry.load), telemetry and number(telemetry.rpm)
  if not (maxRPM and maxRPM > 0 and load and rpm and load >= FUEL_PULL_LOAD and rpm >= maxRPM * FUEL_PULL_RPM_FRACTION) then
    if fuelPull then
      fuelPull.gap = fuelPull.gap + dt
      if fuelPull.gap > FUEL_PULL_GAP_SECONDS then fuelPull = nil end
    end
    return
  end
  if not fuelPull or fuelPull.engine ~= engine.name then
    fuelPull = { engine = engine.name, seconds = 0, gap = 0, peakRetardDeg = 0, knock = false, lean = false, rich = false }
  end
  fuelPull.gap = 0
  fuelPull.seconds = fuelPull.seconds + dt
  if rpm >= (fuelPull.rpm or 0) then
    fuelPull.rpm = rpm
    fuelPull.afr=number(telemetry.afr);fuelPull.targetAFR=number(telemetry.targetAFR)
    fuelPull.lambda = number(telemetry.lambda)
    fuelPull.targetLambda = number(telemetry.targetLambda)
  end
  fuelPull.peakRetardDeg = math.max(fuelPull.peakRetardDeg, number(telemetry.knockRetard) or 0)
  local duty = number(telemetry.deliveryDuty)
  if duty then fuelPull.peakDuty = math.max(fuelPull.peakDuty or duty, duty) end
  -- Same thresholds as the live alerts below.
  fuelPull.knock = fuelPull.knock or (number(telemetry.knock) or 0) > 0.05
  fuelPull.lean = fuelPull.lean or (number(telemetry.leanSeverity) or 0) > 0.05
  fuelPull.rich = fuelPull.rich or (number(telemetry.richSeverity) or 0) > 0.05
  fuelPull.boostCut = fuelPull.boostCut or telemetry.boostFuelCut == true
  if fuelPull.seconds >= FUEL_PULL_MIN_SECONDS then
    lastFuelPull = {
      engine = fuelPull.engine, secondsAgo = 0, rpm = fuelPull.rpm,
      afr=fuelPull.afr,targetAFR=fuelPull.targetAFR,lambda = fuelPull.lambda, targetLambda = fuelPull.targetLambda,
      peakRetardDeg = fuelPull.peakRetardDeg, peakDuty = fuelPull.peakDuty,
      knock = fuelPull.knock, lean = fuelPull.lean, rich = fuelPull.rich, boostCut = fuelPull.boostCut,
    }
  end
end

-- Compact view of the engine the rest of this scan is already about.
-- Thresholds match rlsFuelModel.warning and rlsFuelDamage.inspect so the
-- scanner does not invent a second idea of "too lean" or "octane short".
-- Named fuelSystem because `fuel` is already the tank level.
local function fuelReport(engine)
  if not isCombustionEngine(engine) or (engine.requiredEnergyType ~= "gasoline" and engine.requiredEnergyType ~= "diesel") then return nil end
  local runtime = extensions and extensions.rlsFuelRuntime
  if type(runtime) ~= "table" or type(runtime.getSnapshot) ~= "function" then
    return { monitored = false, reason = "Fuel system data is unavailable." }
  end
  local ok, snapshot = pcall(runtime.getSnapshot)
  if not ok or type(snapshot) ~= "table" then
    return { monitored = false, reason = "Fuel system data is unavailable." }
  end
  local record = snapshot.engines and snapshot.engines[engine.name]
  if type(record) ~= "table" then
    local reason = "Fuel system not monitored."
    for _, item in pairs(snapshot.unsupported or {}) do
      if type(item) == "table" and item.name == engine.name and item.reason then
        reason = item.reason
        break
      end
    end
    return { monitored = false, reason = reason }
  end

  local telemetry = type(record.telemetry) == "table" and record.telemetry or {}
  local state = type(record.state) == "table" and record.state or {}
  local profile = type(record.profile) == "table" and record.profile or {}
  local failures = type(state.fuelFailures) == "table" and state.fuelFailures or {}
  local kind = fuelSystemKind(state)
  local liters = connectedFuelLiters(snapshot, record)
  local empty = liters ~= nil and liters <= 0.05
  local nitro = number(telemetry.nitromethane) or 0
  local methanol = number(telemetry.methanol) or 0
  local fuelAki = number(telemetry.aki)
  local requiredAki = number(profile.requiredAKI)
  local knock = number(telemetry.knock) or 0
  local lean = number(telemetry.leanSeverity) or 0
  local rich = number(telemetry.richSeverity) or 0
  local retard = number(telemetry.knockRetard) or 0
  local duty = number(telemetry.deliveryDuty)

  return {
    monitored = true,engine=engine.name,fuelType=profile.fuelType,boostTargetPsi=telemetry.boostTargetPsi,
    system = fuelSystemLabel(kind),
    fuelInUse = kind=="diesel" and (empty and "Empty" or "Diesel") or fuelInUseLabel(telemetry, liters),
    requiredAki = requiredAki,
    requirementEstimated = profile.estimated == true,
    fuelAki = fuelAki,
    afr=number(telemetry.afr),targetAFR=number(telemetry.targetAFR),injectorDuty=number(telemetry.injectorDuty),pumpDuty=number(telemetry.pumpDuty),
    lambda = number(telemetry.lambda),
    targetLambda = number(telemetry.targetLambda),
    knockRetardDeg = retard,
    knockControl = profile.knockControl == true,
    lastPull = lastFuelPull and lastFuelPull.engine == engine.name and lastFuelPull or nil,
    deliveryDuty = duty,
    causedRings = failures.pistonRingsDamaged == true,
    causedGasket = failures.headGasketBlown == true,
    causedLockup = failures.lockedUp == true,
    alerts = {
      nitroKit = not empty and nitro > 0.001 and kind ~= "nitromethane",
      nitroBlend = not empty and kind == "nitromethane" and (math.abs(nitro - 0.9) > 0.02 or math.abs(methanol - 0.1) > 0.02),
      -- Nitro 90 is 10% methanol on purpose. Those methanol checks belong to
      -- gasoline and flex-fuel cars, not to a nitro blend.
      methanolKit = not empty and nitro <= 0.001 and kind ~= "nitromethane" and methanol > 0.001 and kind ~= "methanol",
      methanolPurity = not empty and kind == "methanol" and methanol < 0.98,
      mixedMethanol = not empty and nitro <= 0.001 and kind ~= "nitromethane" and methanol > 0.001 and methanol < 0.98,
      ethanolUnconverted = not empty and (number(telemetry.ethanol) or 0) > 0.15 and kind == "gasoline",
      octaneShort = kind~="diesel" and kind~="nitromethane" and kind~="methanol" and not empty and fuelAki ~= nil and requiredAki ~= nil and fuelAki + 0.25 < requiredAki,
      knock = knock > 0.05,
      lean = lean > 0.05,
      rich = rich > 0.05,
      knockRetard = retard > 0.25,
      deliveryLimited = duty ~= nil and duty >= 1,
      boostCut = telemetry.boostFuelCut == true,
    },
  }
end

local function buildState(devices)
  devices = devices or collectLiveDevices()
  local electricValues = devices.ev
  local engine = devices.engine
  local electricMotorDevices = devices.electricMotors
  local hasElectricDrive = #electricMotorDevices > 0
  local isHybrid = hasElectricDrive and isCombustionEngine(engine)
  local isElectric = hasElectricDrive and not isHybrid
  local hasCoolingSystem = devices.hasCoolingSystem
  local motors, propulsionRpm, propulsionLoad, worstMotor = summarizeElectricMotors(electricMotorDevices)
  local gearbox = devices.gearbox
  local clutch = devices.clutch
  local clutchConfig = v and v.data and v.data.clutch or nil
  -- Report only a JBeam-defined rating; some clutches derive lockTorque from engine output at runtime.
  local clutchRatedTorque = clutchConfig and number(clutchConfig.lockTorque) or nil
  local clutchAvailableTorque = clutchLockTorqueNm(clutch)
  local thermals = engine and engine.thermals or nil
  local turbocharger = v and v.data and v.data.turbocharger or nil
  local supercharger = v and v.data and v.data.supercharger or nil
  -- electrics.boost is reset to 0 on every vehicle, so only report it with installed hardware.
  local hasForcedInduction = engine ~= nil and ((engine.turbocharger and engine.turbocharger.isExisting == true)
    or (engine.supercharger and engine.supercharger.isExisting == true))
  -- Hardware opening only; commanded offset is not this reading.
  local wastegateStartPsi = turbocharger and number(turbocharger.wastegateStart) or nil
  local engineName = findEngineName(engine)
  local _, gearboxName = findActivePart("transmission", "transmission")
  local clutchName, flywheelName = findClutchAndFlywheelNames()
  local _, centerCouplingName = findActivePart("transfer_case", nil)
  local transferCase = transferCaseData(centerCouplingName)
  local _, turbochargerName = findActivePart("", "turbocharger")
  local _, superchargerName = findActivePart("", "supercharger")
  -- maxTorqueRating is BeamNG's overtorque damage threshold, not engine output.
  local overtorqueThreshold, overrevThresholdRpm, ecuLimiterRpm, engineRpm, generatorRunning,
    motorBroken, motorDisabled, motorHasEnergy, propulsionRpm = readScannerEngineLimits(
    electricValues, engine, hasElectricDrive, isHybrid, motors, propulsionRpm
  )
  local result = {}
  writeScannerPropulsionReadings(
    result, electricValues, engine, hasElectricDrive, isHybrid, isElectric, hasCoolingSystem, motors,
    propulsionRpm, propulsionLoad, turbocharger, supercharger, hasForcedInduction, wastegateStartPsi,
    turbochargerName, superchargerName, ecuLimiterRpm, engineRpm
  )
  writeScannerOperatingReadings(
    result, electricValues, engine, hasElectricDrive, hasCoolingSystem, thermals, generatorRunning
  )
  writeScannerRestrictionReadings(
    result, engine, isElectric, worstMotor, overtorqueThreshold, overrevThresholdRpm, motorBroken,
    motorDisabled, motorHasEnergy
  )
  writeScannerComponentReadings(
    result, gearbox, clutch, clutchRatedTorque, clutchAvailableTorque, thermals, engineName,
    gearboxName, clutchName, flywheelName, centerCouplingName, transferCase
  )
  result.fuelSystem = fuelReport(engine)
  return result
end

-- Wastegate offset --------------------------------------------------------------------------------
local function eachCombustionEngine(callback)
  if powertrain and powertrain.getDevice then
    local mainEngine = powertrain.getDevice("mainEngine")
    if mainEngine then callback(mainEngine) end
  end
  local engines = powertrain and powertrain.getDevicesByCategory and powertrain.getDevicesByCategory("engine") or nil
  for _, engine in ipairs(engines or {}) do
    callback(engine)
  end
end

local function applyCombinedWastegateOffset()
  eachCombustionEngine(function(engine)
    if (wastegateOffsetPsi or 0) == 0 then
      boostControl.release(engine, 'scanner')
    else
      boostControl.setProOffset(engine, wastegateOffsetPsi)
    end
  end)
end
ensureWastegateWrap=function() applyCombinedWastegateOffset();return true end
local function restoreVanillaWastegateOffset()
  eachCombustionEngine(function(engine) boostControl.release(engine,'scanner') end)
end
local function setWastegateOffsetPsi(psi)
  wastegateOffsetPsi=number(psi) or 0;applyCombinedWastegateOffset();return true
end
local function expireRecentScannerObservations(elapsed)
  recentClutchHeatSeconds = math.max(0, recentClutchHeatSeconds - elapsed)
  recentMotorRestrictionSeconds = math.max(0, recentMotorRestrictionSeconds - elapsed)
  recentEngineRestrictionSeconds = math.max(0, recentEngineRestrictionSeconds - elapsed)
  recentCombustionStabilitySeconds = math.max(0, recentCombustionStabilitySeconds - elapsed)
  recentMisfireRiskSeconds = math.max(0, recentMisfireRiskSeconds - elapsed)
  recentTransmissionThermalStressSeconds = math.max(0, recentTransmissionThermalStressSeconds - elapsed)
  recentIdleStallSeconds = math.max(0, recentIdleStallSeconds - elapsed)
end

local function updateGFX(dt)
  if lastFuelPull then
    lastFuelPull.secondsAgo=lastFuelPull.secondsAgo+math.max(0,tonumber(dt) or 0)
    if lastFuelPull.secondsAgo>=300 then lastFuelPull=nil end
  end
  if not activated then return end
  observeFuelPull(getEngine(), tonumber(dt) or 0)
  local elapsed = number(dt) or 0
  timer = timer + elapsed
  recentHandoffTimer = recentHandoffTimer + elapsed
  expireRecentScannerObservations(elapsed)
  updateRecentDamageEvents(elapsed)
  if milRequestMode == "steady" and electrics and electrics.values then
    electrics.values.checkengine = true
  end
  if timer < UPDATE_INTERVAL then return end
  timer = 0
  reconcileRecentDamageEvents()
  if wastegateOffsetPsi ~= 0 then ensureWastegateWrap() end
  local devices = collectLiveDevices()
  local electricValues = devices.ev
  local engine = devices.engine
  local clutch = devices.clutch
  observeEngineConditions(devices.maintenanceLiveConditions)
  observeIdleStall(engine, electricValues, devices.gearbox, #devices.electricMotors > 0)
  for _, motor in ipairs(devices.electricMotors) do
    local ratedTorque = number(motor.maxTorque)
    local torqueLimit = number(motor.maxTorqueLimit)
    local motorLoad = number(motor.engineLoad)
    if ratedTorque and ratedTorque > 0 and torqueLimit and motorLoad and motorLoad >= 0.35 then
      local availability = math.max(0, math.min(1, torqueLimit / ratedTorque))
      -- Matches overhaulMaintenance's restriction threshold; smaller dips are ordinary battery sag.
      if availability < 0.90 then
        recentMotorTorqueAvailability = math.min(recentMotorTorqueAvailability or availability, availability)
        recentMotorRestrictionSeconds = RECENT_EVENT_SECONDS
      end
    end
  end
  if recentMotorRestrictionSeconds <= 0 then recentMotorTorqueAvailability = nil end
  if recentEngineRestrictionSeconds <= 0 then recentEngineRestrictionReason = nil end
  if recentMisfireRiskSeconds <= 0 then recentMisfireRiskLevel = nil end
  if recentTransmissionThermalStressSeconds <= 0 then recentTransmissionThermalStressLevel = nil end
  local clutchTemp = clutch and number(clutch.clutchTemperature) or nil
  local clutchWarningTemp = clutch and number(clutch.clutchWarningTemp) or nil
  if clutchTemp and clutchWarningTemp and clutchTemp >= clutchWarningTemp then
    recentClutchHeatPeakC = math.max(recentClutchHeatPeakC or clutchTemp, clutchTemp)
    recentClutchHeatSeconds = 300
  elseif recentClutchHeatSeconds <= 0 then
    recentClutchHeatPeakC = nil
  end
  milRequestMode = getMilRequestMode(engine, engine and engine.thermals or nil, electricValues, devices.hasCoolingSystem,
    devices.maintenanceLiveConditions)
  if milRequestMode then
    -- Never write false: the native controller regains sole ownership of the warning when this clears.
    electricValues.checkengine = true
  end
  if streams and streams.willSend and streams.willSend("obdScannerData") then
    gui.send("obdScannerData", buildState(devices))
  end
  if recentHandoffTimer >= RECENT_HANDOFF_INTERVAL then
    recentHandoffTimer = 0
    sendRecentObservationHandoff()
  end
end

-- Requests and maintenance mode -------------------------------------------------------------------
local function requestState()
  if gui then gui.send("obdScannerData", buildState()) end
end

local function setMaintenanceModeEnabled(enabled)
  if type(enabled) == "boolean" then
    maintenanceModeEnabled = enabled
  else
    maintenanceModeEnabled = nil
  end
  if maintenanceModeEnabled ~= true then
    recentEngineRestrictionSeconds = 0
    recentEngineRestrictionReason = nil
    recentCombustionStabilitySeconds = 0
    recentMisfireRiskSeconds = 0
    recentMisfireRiskLevel = nil
    recentTransmissionThermalStressSeconds = 0
    recentTransmissionThermalStressLevel = nil
  end
  requestState()
end

-- Lifecycle ---------------------------------------------------------------------------------------
-- Runs only after the game engine confirms Overhaul is active; otherwise the scanner unloads itself.
local function activate()
  if activated then return end
  activated = true
  registerDamageListener()
end

local function onExtensionLoaded()
  -- GE answers by activating the scanner while Overhaul is active, else unloading it.
  obj:queueGameEngineLua(geCallback.command("obdScannerGate", obj:getID()))
end

local function onExtensionUnloaded()
  restoreVanillaWastegateOffset()
end

-- Exports -----------------------------------------------------------------------------------------
M.onExtensionLoaded = onExtensionLoaded
M.activate = activate
M.onExtensionUnloaded = onExtensionUnloaded
M.updateGFX = updateGFX
M.requestState = requestState
M.setMaintenanceModeEnabled = setMaintenanceModeEnabled
M.restoreRecentObservations = restoreRecentObservations
M.onDamageDataChanged = onDamageDataChanged
M.setWastegateOffsetPsi = setWastegateOffsetPsi
return M
