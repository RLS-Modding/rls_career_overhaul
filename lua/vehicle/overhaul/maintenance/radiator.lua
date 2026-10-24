-- Cooling-system wear, thermal-cycle damage, derived effects and hard failures.
-- Read tuning/wear drain, service forecasts, derived state, runtime symptoms, then device application.
local M = {}

local common = require('vehicle/overhaul/maintenance/common')
local units = require('common/overhaul/units')

local max = math.max
local minimumHardFailureMileage = 200000
local maintenanceIntervals = {
  coolantLevel = {fresh = 260, aged = 180, worn = 120},
  coolantIntegrity = {fresh = 220, aged = 180, worn = 140}
}
local serviceTargetValues = {
  coolantLevel = 0.55,
  coolantIntegrity = 0.6
}
local warmupChips = {
  fresh = 0.003,
  aged = 0.005,
  worn = 0.008
}
local cooldownChips = {
  fresh = 0.0015,
  aged = 0.0025,
  worn = 0.0045
}
local hotIntegrityWearPerSecond = {
  fresh = 0.00001,
  aged = 0.000018,
  worn = 0.000032
}
local overheatIntegrityWearPerSecond = {
  fresh = 0.00016,
  aged = 0.00028,
  worn = 0.00045
}
local hotCoolantLossPerSecond = {
  fresh = 0.00001,
  aged = 0.000022,
  worn = 0.000045
}
local criticalTempCoolantLossPerSecond = {
  fresh = 0.0003,
  aged = 0.00055,
  worn = 0.00095
}
local overheatCoolantLossPerSecond = {
  fresh = 0.00085,
  aged = 0.00145,
  worn = 0.00235
}
local moderateDriveReference = {
  heatFactor = 0.15,
  overheatFactor = 0,
  loadFactor = 0.35,
  powerFactor = 0
}
local criticalCoolantLossStartTempC = units.fahrenheitToCelsius(230)
local criticalCoolantLossPeakTempC = units.fahrenheitToCelsius(245)
local emergencyCoolantLossTempC = units.fahrenheitToCelsius(258)

local function getDefaultMaintenance()
  return {
    coolantLevel = 1,
    coolantIntegrity = 1
  }
end

local function getDriveMultiplierValues(heatFactor, overheatFactor, loadFactor, powerFactor)
  return {
    coolantLevel = 1 + heatFactor * 0.35 + overheatFactor * 1.8 + loadFactor * 0.15 + powerFactor * 0.12,
    coolantIntegrity = 1 + heatFactor * 0.18 + overheatFactor * 0.55 + powerFactor * 0.08
  }
end

local function getDriveMultipliers(env)
  env = env or {}
  local rawMultipliers = getDriveMultiplierValues(
    common.clamp(env.heatFactor or 0, 0, 1),
    common.clamp(env.overheatFactor or 0, 0, 1),
    common.clamp(env.loadFactor or 0, 0, 1),
    max(tonumber(env.powerFactor) or 0, 0)
  )
  local referenceMultipliers = getDriveMultiplierValues(
    moderateDriveReference.heatFactor,
    moderateDriveReference.overheatFactor,
    moderateDriveReference.loadFactor,
    moderateDriveReference.powerFactor
  )

  return {
    raw = rawMultipliers,
    normalized = {
      coolantLevel = common.normalizeDriveMultiplier(rawMultipliers.coolantLevel, referenceMultipliers.coolantLevel),
      coolantIntegrity = common.normalizeDriveMultiplier(rawMultipliers.coolantIntegrity, referenceMultipliers.coolantIntegrity)
    }
  }
end

local function getCriticalCoolantTempFactor(coolantTemp)
  return common.clamp(common.linearScale(tonumber(coolantTemp) or 0, criticalCoolantLossStartTempC, criticalCoolantLossPeakTempC, 0, 1), 0, 1)
end

local function getEmergencyCoolantTempFactor(coolantTemp)
  return common.clamp(common.linearScale(tonumber(coolantTemp) or 0, criticalCoolantLossPeakTempC, emergencyCoolantLossTempC, 0, 1), 0, 1)
end

local function drainMaintenance(maintenance, deltaMiles, avgMiles, env)
  maintenance = common.shallowCopy(maintenance)
  env = env or {}
  local driveMultipliers = getDriveMultipliers(env).normalized
  local profile = env.profile or {}
  local classIntervalMultiplier = common.getClassConditionIntervalMultiplier(profile.class)
  local coolantCapacityFactor = common.getCapacityFactor('coolant', profile)
  local coolantLevelMileageMultiplier = common.getLevelMileageMultiplier('coolantLevel', avgMiles)
  local coolantIntegrity = maintenance.coolantIntegrity or 1
  local lowFluidConditionMultiplier = common.getLowFluidConditionMultiplier(maintenance.coolantLevel or 1)

  maintenance.coolantLevel = common.applyIntervalWear(
    maintenance.coolantLevel or 1,
    maintenanceIntervals.coolantLevel.fresh,
    deltaMiles,
    driveMultipliers.coolantLevel * coolantLevelMileageMultiplier * coolantCapacityFactor,
    serviceTargetValues.coolantLevel
  )
  maintenance.coolantIntegrity = common.applyIntervalWear(
    coolantIntegrity,
    maintenanceIntervals.coolantIntegrity.fresh * classIntervalMultiplier,
    deltaMiles,
    driveMultipliers.coolantIntegrity * lowFluidConditionMultiplier,
    serviceTargetValues.coolantIntegrity
  )

  local coolantLevel = common.clamp(maintenance.coolantLevel or 1, 0, 1)
  coolantIntegrity = maintenance.coolantIntegrity or 1
  local integrityAmplifier = (1 + (1 - coolantIntegrity) * 0.7) * lowFluidConditionMultiplier / classIntervalMultiplier
  local warmupChip = (env.warmupEvent and warmupChips.fresh or 0) * integrityAmplifier
  local cooldownChip = (env.cooldownEvent and cooldownChips.fresh or 0) * integrityAmplifier
  local hotIntegrityWear = hotIntegrityWearPerSecond.fresh * (tonumber(env.hotRuntimeSeconds) or 0) *
                               common.clamp(env.heatFactor or 0, 0, 1) * integrityAmplifier
  local overheatIntegrityWear = overheatIntegrityWearPerSecond.fresh *
                                    (tonumber(env.overheatingRuntimeSeconds) or 0) *
                                    common.clamp(env.overheatFactor or 0, 0, 1) * integrityAmplifier

  maintenance.coolantIntegrity = common.clamp(coolantIntegrity - warmupChip - cooldownChip - hotIntegrityWear - overheatIntegrityWear, 0, 1)

  coolantLevel = common.clamp(maintenance.coolantLevel or 1, 0, 1)
  local coolantTemp = tonumber(env.coolantTemp) or 0
  local criticalCoolantTempFactor = getCriticalCoolantTempFactor(coolantTemp)
  local emergencyCoolantTempFactor = getEmergencyCoolantTempFactor(coolantTemp)
  local coolantLossAmplifier = (1 + (1 - maintenance.coolantIntegrity) * 1.6) * coolantLevelMileageMultiplier * coolantCapacityFactor
  local hotCoolantLoss = hotCoolantLossPerSecond.fresh * (tonumber(env.hotRuntimeSeconds) or 0) *
                             common.clamp(env.heatFactor or 0, 0, 1) * coolantLossAmplifier * (0.08 + criticalCoolantTempFactor * 0.22)
  local criticalTempCoolantLoss = criticalTempCoolantLossPerSecond.fresh *
                                      max(tonumber(env.hotRuntimeSeconds) or 0, tonumber(env.overheatingRuntimeSeconds) or 0) *
                                      criticalCoolantTempFactor * coolantLossAmplifier * (1 + emergencyCoolantTempFactor * 1.8)
  local overheatCoolantLoss = overheatCoolantLossPerSecond.fresh *
                                  (tonumber(env.overheatingRuntimeSeconds) or 0) *
                                  max(common.clamp(env.overheatFactor or 0, 0, 1), criticalCoolantTempFactor * 0.35) *
                                  coolantLossAmplifier * (1.35 + criticalCoolantTempFactor * 1.4 + emergencyCoolantTempFactor * 3)

  maintenance.coolantLevel = common.clamp(coolantLevel - hotCoolantLoss - criticalTempCoolantLoss - overheatCoolantLoss, 0, 1)

  return maintenance
end

local function calculateCoolingLossEffects(
  wear, neglectSeverity, heatFactor, overheatFactor, coolantLevel, coolantIntegrity
)
  local catastrophicCoolingLoss = coolantLevel <= 0.02 and coolantIntegrity <= 0.03

  local coolantLevelMassCoef = common.sampleCurve(coolantLevel, {
    {1.0, 1.0},
    {0.70, 1.0},
    {0.50, 0.92},
    {0.25, 0.58},
    {0.10, 0.22},
    {0.0, 0.08}
  })
  local coolantIntegrityHeatPenalty = common.sampleCurve(coolantIntegrity, {
    {1.0, 0},
    {0.70, 0},
    {0.50, 0.03},
    {0.25, 0.12},
    {0.0, 0.25}
  })
  local coolantMassCoef = common.clamp(coolantLevelMassCoef - coolantIntegrityHeatPenalty - wear.decline * 0.01 - overheatFactor * 0.05, 0.08, 1)
  local radiatorDamage = common.clamp(
    max(1 - coolantIntegrity - 0.3, 0) * 0.08 + wear.decline * 0.004 + overheatFactor * 0.035 + max(1 - coolantLevel - 0.5, 0) * 0.035,
    0,
    0.18
  )
  local symptomBaseRate = neglectSeverity * (0.0045 + wear.normalizedWear * 0.0035)
  local symptomRate = symptomBaseRate * (0.25 + heatFactor * 0.45 + overheatFactor * 0.3)
  return catastrophicCoolingLoss, coolantMassCoef, radiatorDamage, symptomRate
end

local function writeCoolingCondition(
  result, wear, maintenanceAvg, maintenancePenalty, neglectSeverity, coolantLevelMileageMultiplier,
  coolantLevel, coolantIntegrity, lowFluidConditionMultiplier, severeCoolingLoss,
  catastrophicCoolingLoss, coolantMassCoef, radiatorDamage, symptomRate, hardFailureRate,
  stressMultiplier
)
  result.stressMultiplier = stressMultiplier
  result.ageMultiplier = coolantLevelMileageMultiplier
  result.neglectMultiplier = lowFluidConditionMultiplier
  result.wear = wear
  result.maintenanceAvg = maintenanceAvg
  result.maintenancePenalty = maintenancePenalty
  result.neglectSeverity = neglectSeverity
  result.coolantLevel = coolantLevel
  result.coolantIntegrity = coolantIntegrity
  result.severeCoolingLoss = severeCoolingLoss
  result.catastrophicCoolingLoss = catastrophicCoolingLoss
  result.coolantMassCoef = coolantMassCoef
  result.radiatorDamage = radiatorDamage
  result.symptomRate = symptomRate
  result.hardFailureRate = hardFailureRate
end

local function writeCoolingServiceForecast(
  result, env, driveMultipliers, profile, classIntervalMultiplier, coolantCapacityFactor,
  coolantLevelMileageMultiplier, coolantLevel, coolantIntegrity, lowFluidConditionMultiplier,
  criticalCoolantTempFactor, emergencyCoolantTempFactor, coolantLevelInterval,
  coolantIntegrityInterval, coolantLevelEffectiveMultiplier, coolantIntegrityEffectiveMultiplier,
  averageDriveMultiplier
)
  result.driveMultiplier = averageDriveMultiplier
  result.driveMultipliers = common.deepCopy(driveMultipliers.normalized)
  result.rawDriveMultipliers = common.deepCopy(driveMultipliers.raw)
  result.profile = common.deepCopy(profile)
  result.mileageAgeIndex = common.getMileageAgeIndex(env.avgMiles)
  result.coolantLevelMileageMultiplier = coolantLevelMileageMultiplier
  result.coolantCapacityFactor = coolantCapacityFactor
  result.classConditionIntervalMultiplier = classIntervalMultiplier
  result.lowFluidConditionMultiplier = lowFluidConditionMultiplier
  result.serviceTargets = common.deepCopy(serviceTargetValues)
  result.criticalCoolantTempFactor = criticalCoolantTempFactor
  result.emergencyCoolantTempFactor = emergencyCoolantTempFactor
  result.effectiveIntervals = {
    coolantLevel = coolantLevelInterval / max(coolantLevelEffectiveMultiplier, 0.0001),
    coolantIntegrity = coolantIntegrityInterval / max(coolantIntegrityEffectiveMultiplier, 0.0001)
  }
  result.effectiveDriveMultipliers = {
    coolantLevel = coolantLevelEffectiveMultiplier,
    coolantIntegrity = coolantIntegrityEffectiveMultiplier
  }
  result.serviceDueMilesRemaining = {
    coolantLevel = common.estimateMilesToTarget(coolantLevel, coolantLevelInterval,
      common.getPlanningMultiplier(env, 'coolantLevel', coolantLevelEffectiveMultiplier, driveMultipliers.normalized.coolantLevel),
      serviceTargetValues.coolantLevel),
    coolantIntegrity = common.estimateMilesToTarget(coolantIntegrity, coolantIntegrityInterval,
      common.getPlanningMultiplier(env, 'coolantIntegrity', coolantIntegrityEffectiveMultiplier,
        driveMultipliers.normalized.coolantIntegrity),
      serviceTargetValues.coolantIntegrity)
  }
end

local function writeCoolingThermalHistory(result, env, heatFactor, overheatFactor)
  result.heatFactor = heatFactor
  result.overheatFactor = overheatFactor
  result.isOverheating = env.isOverheating or false
  result.hotRuntimeSeconds = tonumber(env.hotRuntimeSeconds) or 0
  result.overheatingRuntimeSeconds = tonumber(env.overheatingRuntimeSeconds) or 0
  result.warmupEvent = env.warmupEvent == true
  result.cooldownEvent = env.cooldownEvent == true
  result.warmupEventCount = tonumber(env.warmupEventCount) or 0
  result.cooldownEventCount = tonumber(env.cooldownEventCount) or 0
  result.totalHotRuntimeSeconds = tonumber(env.totalHotRuntimeSeconds) or 0
  result.totalOverheatingRuntimeSeconds = tonumber(env.totalOverheatingRuntimeSeconds) or 0
end

local function buildDerived(state, env)
  local wear = common.getWearProfile(env.avgMiles)
  local maintenanceAvg = common.getAverageMaintenance(state.maintenance)
  local maintenancePenalty = 1 - maintenanceAvg
  local neglectSeverity = common.getMaintenanceSeverity(maintenanceAvg)
  local heatFactor = common.clamp(env.heatFactor or 0, 0, 1)
  local overheatFactor = common.clamp(env.overheatFactor or 0, 0, 1)
  local loadFactor = common.clamp(env.loadFactor or 0, 0, 1)
  local driveMultipliers = getDriveMultipliers(env)
  local profile = env.profile or {}
  local classIntervalMultiplier = common.getClassConditionIntervalMultiplier(profile.class)
  local coolantCapacityFactor = common.getCapacityFactor('coolant', profile)
  local coolantLevelMileageMultiplier = common.getLevelMileageMultiplier('coolantLevel', env.avgMiles)
  local coolantLevel = common.clamp(state.maintenance.coolantLevel or 1, 0, 1)
  local coolantIntegrity = common.clamp(state.maintenance.coolantIntegrity or 1, 0, 1)
  local lowFluidConditionMultiplier = common.getLowFluidConditionMultiplier(coolantLevel)
  local criticalCoolantTempFactor = getCriticalCoolantTempFactor(env.coolantTemp)
  local emergencyCoolantTempFactor = getEmergencyCoolantTempFactor(env.coolantTemp)
  local severeCoolingLoss = coolantLevel <= 0.08 and coolantIntegrity <= 0.12
  local catastrophicCoolingLoss, coolantMassCoef, radiatorDamage, symptomRate = calculateCoolingLossEffects(
    wear, neglectSeverity, heatFactor, overheatFactor, coolantLevel, coolantIntegrity
  )

  local hardFailureRate = 0
  if catastrophicCoolingLoss then
    hardFailureRate = 0.55 + overheatFactor * 1.25 + heatFactor * 0.45 + loadFactor * 0.25
  elseif severeCoolingLoss then
    hardFailureRate = 0.04 + (1 - coolantMassCoef) * 0.12 + overheatFactor * 0.08
  end
  local coolantLevelInterval = maintenanceIntervals.coolantLevel.fresh
  local coolantIntegrityInterval = maintenanceIntervals.coolantIntegrity.fresh * classIntervalMultiplier
  local coolantLevelEffectiveMultiplier = driveMultipliers.normalized.coolantLevel * coolantLevelMileageMultiplier * coolantCapacityFactor
  local coolantIntegrityEffectiveMultiplier = driveMultipliers.normalized.coolantIntegrity * lowFluidConditionMultiplier
  local averageDriveMultiplier = (coolantLevelEffectiveMultiplier + coolantIntegrityEffectiveMultiplier) / 2
  local stressMultiplier = (driveMultipliers.normalized.coolantLevel + driveMultipliers.normalized.coolantIntegrity) / 2

  local result = {}
  writeCoolingCondition(
    result, wear, maintenanceAvg, maintenancePenalty, neglectSeverity, coolantLevelMileageMultiplier,
    coolantLevel, coolantIntegrity, lowFluidConditionMultiplier, severeCoolingLoss,
    catastrophicCoolingLoss, coolantMassCoef, radiatorDamage, symptomRate, hardFailureRate,
    stressMultiplier
  )
  writeCoolingServiceForecast(
    result, env, driveMultipliers, profile, classIntervalMultiplier, coolantCapacityFactor,
    coolantLevelMileageMultiplier, coolantLevel, coolantIntegrity, lowFluidConditionMultiplier,
    criticalCoolantTempFactor, emergencyCoolantTempFactor, coolantLevelInterval,
    coolantIntegrityInterval, coolantLevelEffectiveMultiplier, coolantIntegrityEffectiveMultiplier,
    averageDriveMultiplier
  )
  writeCoolingThermalHistory(result, env, heatFactor, overheatFactor)
  return result
end

local function stepRuntime(runtime, state, derived, env, dt)
  runtime.cooldownTimer = max((runtime.cooldownTimer or 0) - dt, 0)
  runtime.symptomTimer = max((runtime.symptomTimer or 0) - dt, 0)
  runtime.criticalCoolingSeconds = max((runtime.criticalCoolingSeconds or 0) - dt * 0.15, 0)
  runtime.forceHardFailure = false
  runtime.forceHardFailureTarget = nil
  runtime.forceHardFailureReason = nil

  if runtime.symptomTimer <= 0 then
    runtime.activeSymptom = nil
  end

  if env.engineRunningSeconds and env.engineRunningSeconds > 0 and (derived.severeCoolingLoss or derived.catastrophicCoolingLoss) then
    local coolingLoad = 0.35 + common.clamp(env.heatFactor or 0, 0, 1) * 0.95 + common.clamp(env.overheatFactor or 0, 0, 1) * 1.3 +
                            common.clamp(env.loadFactor or 0, 0, 1) * 0.35
    runtime.criticalCoolingSeconds = runtime.criticalCoolingSeconds + dt * coolingLoad

    if runtime.criticalCoolingSeconds >= 0.75 then
      runtime.activeSymptom = 'coolantSeep'
      runtime.symptomTimer = max(runtime.symptomTimer or 0, 2.5)
      runtime.cooldownTimer = max(runtime.cooldownTimer or 0, 5)
      state.lastFailureTime = os.time()
      state.lastFailureType = runtime.activeSymptom
    end

    local catastrophicThreshold = derived.catastrophicCoolingLoss and 2.8 or 7.5
    if runtime.criticalCoolingSeconds >= catastrophicThreshold then
      runtime.forceHardFailure = true
      runtime.forceHardFailureTarget = 'engine'
      runtime.forceHardFailureReason = 'cooling_failure'
      state.lastFailureTime = os.time()
      state.lastFailureType = 'engine_break'
      return runtime.activeSymptom
    end
  end

  if runtime.cooldownTimer <= 0 and not runtime.activeSymptom and common.rollChance(derived.symptomRate, dt) then
    local heatFactor = common.clamp(env.heatFactor or 0, 0, 1)
    runtime.activeSymptom = common.chooseWeighted({
      {value = 'coolantSeep', weight = 1 + heatFactor * 2 + derived.maintenancePenalty * 2},
      {value = 'fanOverwork', weight = 1 + (1 - heatFactor) * 0.5}
    })
    runtime.symptomTimer = common.pickDuration(6, 16)
    runtime.cooldownTimer = runtime.symptomTimer + common.pickDuration(10, 20)
    state.lastFailureTime = os.time()
    state.lastFailureType = runtime.activeSymptom
  end
  return runtime.activeSymptom
end

local function apply(context, state, runtime, derived)
  local symptom = runtime.activeSymptom
  local symptomFrictionCoef = 1

  if symptom == 'coolantSeep' then
    symptomFrictionCoef = 1.015
  elseif symptom == 'fanOverwork' then
    symptomFrictionCoef = 1.01
  end

  runtime.lastPowerLimitReason = nil
  runtime.lastPowerLimitActive = false

  for _, entry in ipairs(context.devices or {}) do
    local engine = entry.device
    local base = entry.base
    local baseMaxTorque = base.maxTorque or engine.maxTorque or 0
    local thermalSeverity = common.clamp(
      (1 - (derived.coolantMassCoef or 1)) * 0.82 + (derived.radiatorDamage or 0) * 1.4 + (derived.overheatFactor or 0) * 0.45,
      0,
      1.1
    )
    local interventionSeverity = common.clamp(common.linearScale(thermalSeverity, 0.28, 1.0, 0, 1), 0, 1)
    local shouldLimitForCooling = derived.catastrophicCoolingLoss or (derived.overheatFactor or 0) >= 0.18 or runtime.forceHardFailure == true

    if shouldLimitForCooling and baseMaxTorque > 0 and engine.maxTorqueLimit ~= nil then
      local existingLimit = tonumber(entry.engineAppliedMaxTorqueLimit or engine.maxTorqueLimit) or math.huge
      local coolingLimit = baseMaxTorque * common.lerp(0.92, 0.62, common.clamp(max(interventionSeverity, derived.overheatFactor or 0), 0, 1))
      if base.originalMaxTorqueLimit and base.originalMaxTorqueLimit < math.huge then
        coolingLimit = math.min(coolingLimit, base.originalMaxTorqueLimit)
      end
      engine.maxTorqueLimit = math.min(existingLimit, coolingLimit)
      if coolingLimit < baseMaxTorque * 0.995 then
        runtime.lastPowerLimitReason = derived.catastrophicCoolingLoss and 'Catastrophic cooling loss' or 'Overheating'
        runtime.lastPowerLimitActive = true
      end
    end

    if engine.friction ~= nil then
      engine.friction = (entry.engineAppliedFriction or base.friction or engine.friction) * symptomFrictionCoef
    end
    if engine.dynamicFriction ~= nil then
      engine.dynamicFriction = (entry.engineAppliedDynamicFriction or base.dynamicFriction or engine.dynamicFriction) *
                                   common.lerp(1, symptomFrictionCoef, 0.7)
    end
    if engine.thermals and engine.thermals.coolantTemperature ~= nil and interventionSeverity > 0 then
      local targetCoolantTemp = common.lerp(104, 138, interventionSeverity) + common.clamp(derived.loadFactor or 0, 0, 1) * 5 +
                                    common.clamp(derived.heatFactor or 0, 0, 1) * 6 + common.clamp(derived.overheatFactor or 0, 0, 1) * 12
      engine.thermals.coolantTemperature = max(tonumber(engine.thermals.coolantTemperature) or targetCoolantTemp, targetCoolantTemp)
    end
    if engine.thermals and engine.thermals.oilTemperature ~= nil and interventionSeverity > 0 then
      local targetOilTemp = common.lerp(108, 146, interventionSeverity) + common.clamp(derived.loadFactor or 0, 0, 1) * 4 +
                                common.clamp(derived.overheatFactor or 0, 0, 1) * 9
      engine.thermals.oilTemperature = max(tonumber(engine.thermals.oilTemperature) or targetOilTemp, targetOilTemp)
    end
  end
end

local function getHardFailureState(base)
  local baseCoolantMass = max((base and base.coolantMass) or 0.1, 0.1)
  return {
    radiatorDamage = 0.1,
    coolantMass = baseCoolantMass * 0.1
  }
end

local function clearFailureRuntime(context)
  for _, entry in ipairs(context.devices or {}) do
    local engine = entry.device
    local base = entry.base or {}

    if base.originalMaxTorqueLimit ~= nil and engine.maxTorqueLimit ~= nil then
      engine.maxTorqueLimit = base.originalMaxTorqueLimit
    end
    if base.friction ~= nil and engine.friction ~= nil then
      engine.friction = base.friction
    end
    if base.dynamicFriction ~= nil and engine.dynamicFriction ~= nil then
      engine.dynamicFriction = base.dynamicFriction
    end
  end
end

M.getDefaultMaintenance = getDefaultMaintenance
M.drainMaintenance = drainMaintenance
M.buildDerived = buildDerived
M.stepRuntime = stepRuntime
M.apply = apply
M.getHardFailureState = getHardFailureState
M.clearFailureRuntime = clearFailureRuntime
M.minimumHardFailureMileage = minimumHardFailureMileage

return M
