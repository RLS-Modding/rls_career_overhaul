-- Transmission maintenance: fluid wear, thermal stress, gearbox and clutch effects, and hard failures.
-- Read tuning and service drain, derived effects, runtime progression, then gearbox application.
local M = {}

local common = require('vehicle/overhaul/maintenance/common')
local getLimitStressFactor = require('vehicle/overhaul/maintenance/limitStress')
local limitStressFractions = {
  rpmRampStart = 0.72, loadRampStart = 0.8, heatRampStart = 0.65,
  rpm = 0.75, load = 1.15, heat = 0.5, overheat = 0.7, maximum = 2
}

local max = math.max
local minimumHardFailureMileage = 200000
local healthyMaintenanceFloor = 0.70
local maintenanceIntervals = {
  fluidCondition = {fresh = 180, aged = 140, worn = 100},
  fluidLevel = {fresh = 220, aged = 160, worn = 110}
}
local serviceTargetValues = {
  fluidCondition = 0.55,
  fluidLevel = 0.5
}
local moderateDriveReference = {
  rpmFactor = 0.3,
  loadFactor = 0.35,
  heatFactor = 0.1,
  powerFactor = 0,
  limitStressFactor = 0
}

local function getDefaultMaintenance()
  return {
    fluidCondition = 1,
    fluidLevel = 1
  }
end

local function reshapeOutputStressFactor(outputStressFactor)
  return common.sampleCurve(max(tonumber(outputStressFactor) or 0, 0), {
    {0, 0},
    {0.15, 0.02},
    {0.35, 0.08},
    {0.8, 0.35},
    {1.4, 0.95},
    {2.5, 2.1},
    {4.5, 4.2}
  })
end

local function reshapeLimitStressFactor(limitStressFactor)
  return common.sampleCurve(max(tonumber(limitStressFactor) or 0, 0), {
    {0, 0},
    {0.35, 0.04},
    {0.8, 0.22},
    {1.3, 0.55},
    {2.0, 1.1}
  })
end

local function getTransmissionThermalState(env, limitStressFactor, outputStressFactor)
  env = env or {}
  local loadFactor = common.clamp(env.loadFactor or 0, 0, 1)
  local rpmFactor = common.clamp(env.rpmFactor or 0, 0, 1)
  local engineHeatFactor = common.clamp(env.heatFactor or 0, 0, 1)
  local oilHeatFactor = common.clamp(env.oilHeatFactor or 0, 0, 1)
  local engineOverheatFactor = common.clamp(env.overheatFactor or 0, 0, 1)
  local oilOverheatFactor = common.clamp(env.oilOverheatFactor or 0, 0, 1)
  local shapedLimitStress = common.clamp(limitStressFactor or 0, 0, 1.4)
  local shapedOutputStress = common.clamp(outputStressFactor or 0, 0, 2.8)

  local carriedHeat = engineHeatFactor * 0.28 + oilHeatFactor * 0.18 + engineOverheatFactor * 0.22 + oilOverheatFactor * 0.12
  local workHeat = common.sampleCurve(
    loadFactor * 0.62 + rpmFactor * 0.18 + shapedOutputStress * 0.20 + shapedLimitStress * 0.24 +
        max(loadFactor - 0.72, 0) * 0.55,
    {
      {0.00, 0.00},
      {0.40, 0.06},
      {0.70, 0.22},
      {1.00, 0.52},
      {1.30, 0.88},
      {1.65, 1.22},
      {2.00, 1.52}
    }
  )
  local transmissionHeatFactor = common.clamp(carriedHeat + workHeat, 0, 1.65)
  local transmissionOverheatFactor = common.clamp(common.linearScale(transmissionHeatFactor, 0.88, 1.35, 0, 1), 0, 1)
  local transmissionTempC = common.lerp(72, 165, common.clamp(transmissionHeatFactor / 1.28, 0, 1)) +
                                transmissionOverheatFactor * 10

  return {
    heatFactor = transmissionHeatFactor,
    overheatFactor = transmissionOverheatFactor,
    tempC = transmissionTempC
  }
end

local function getDriveMultiplierValues(rpmFactor, loadFactor, heatFactor, outputStressFactor, limitStressFactor)
  return {
    fluidCondition = 1 + rpmFactor * 0.40 + loadFactor * 0.85 + heatFactor * 0.40 + outputStressFactor * 1.15 + limitStressFactor * 0.88,
    fluidLevel = 1 + rpmFactor * 0.12 + loadFactor * 0.34 + heatFactor * 0.30 + outputStressFactor * 0.24 + limitStressFactor * 0.20
  }
end

local function getDriveMultipliers(env)
  env = env or {}
  local limitStressFactor = reshapeLimitStressFactor(getLimitStressFactor(env, limitStressFractions))
  -- Torque-rating stress applies only while the drivetrain actually transmits it.
  local outputStress = common.getOutputStress(env.powerHp, env.torqueNm, env.maxTorqueRating)
  local outputStressFactor = reshapeOutputStressFactor(outputStress.drivetrain) * common.getOutputLoadGate(env.loadFactor)
  local thermalState = getTransmissionThermalState(env, limitStressFactor, outputStressFactor)
  local rawMultipliers = getDriveMultiplierValues(
    common.clamp(env.rpmFactor or 0, 0, 1),
    common.clamp(env.loadFactor or 0, 0, 1),
    thermalState.heatFactor,
    outputStressFactor,
    limitStressFactor
  )
  local referenceMultipliers = getDriveMultiplierValues(
    moderateDriveReference.rpmFactor,
    moderateDriveReference.loadFactor,
    moderateDriveReference.heatFactor,
    moderateDriveReference.powerFactor,
    moderateDriveReference.limitStressFactor
  )

  return {
    raw = rawMultipliers,
    normalized = {
      fluidCondition = common.normalizeDriveMultiplier(rawMultipliers.fluidCondition, referenceMultipliers.fluidCondition),
      fluidLevel = common.normalizeDriveMultiplier(rawMultipliers.fluidLevel, referenceMultipliers.fluidLevel)
    },
    thermalState = thermalState,
    limitStressFactor = limitStressFactor,
    outputStressFactor = outputStressFactor
  }
end

local function drainMaintenance(maintenance, deltaMiles, avgMiles, env)
  maintenance = common.shallowCopy(maintenance)
  env = env or {}
  local driveMultipliers = getDriveMultipliers(env).normalized
  local profile = env.profile or {}
  local classIntervalMultiplier = common.getClassConditionIntervalMultiplier(profile.class)
  local fluidCapacityFactor = common.getCapacityFactor('transmission', profile)
  local fluidLevelMileageMultiplier = common.getLevelMileageMultiplier('fluidLevel', avgMiles)
  local lowFluidConditionMultiplier = common.getLowFluidConditionMultiplier(maintenance.fluidLevel or 1)

  maintenance.fluidCondition = common.applyIntervalWear(
    maintenance.fluidCondition or 1,
    maintenanceIntervals.fluidCondition.fresh * classIntervalMultiplier,
    deltaMiles,
    driveMultipliers.fluidCondition * lowFluidConditionMultiplier,
    serviceTargetValues.fluidCondition
  )
  maintenance.fluidLevel = common.applyIntervalWear(
    maintenance.fluidLevel or 1,
    maintenanceIntervals.fluidLevel.fresh,
    deltaMiles,
    driveMultipliers.fluidLevel * fluidLevelMileageMultiplier * fluidCapacityFactor,
    serviceTargetValues.fluidLevel
  )

  return maintenance
end

local function resetDeviceRuntime(device, base, includeDamage)
  if device.wearFrictionCoef ~= nil then
    device.wearFrictionCoef = 1
  end
  if device.wearGearRatioChangeRateCoef ~= nil then
    device.wearGearRatioChangeRateCoef = 1
  end
  if device.wearLockTorqueCoef ~= nil then
    device.wearLockTorqueCoef = 1
  end
  if device.wearClutchFreePlayCoef ~= nil then
    device.wearClutchFreePlayCoef = 1
  end
  if includeDamage then
    if device.damageFrictionCoef ~= nil then
      device.damageFrictionCoef = base.damageFrictionCoef or 1
    end
    if device.damageGearRatioChangeRateCoef ~= nil then
      device.damageGearRatioChangeRateCoef = base.damageGearRatioChangeRateCoef or 1
    end
    if device.damageLockTorqueCoef ~= nil then
      device.damageLockTorqueCoef = base.damageLockTorqueCoef or 1
    end
    if device.damageClutchFreePlayCoef ~= nil then
      device.damageClutchFreePlayCoef = base.damageClutchFreePlayCoef or 1
    end
    if device.clutchPermanentlyDamaged ~= nil then
      device.clutchPermanentlyDamaged = base.clutchPermanentlyDamaged or false
    end
  end
  if base.friction ~= nil then
    device.friction = base.friction
  end
  if base.dynamicFriction ~= nil then
    device.dynamicFriction = base.dynamicFriction
  end
  if base.gearRatioChangeRate ~= nil then
    device.gearRatioChangeRate = base.gearRatioChangeRate
  end
  if base.lockTorque ~= nil then
    device.lockTorque = base.lockTorque
  end
  if base.clutchFreePlay ~= nil then
    device.clutchFreePlay = base.clutchFreePlay
  end
end

local function calculateTransmissionFluidSeverities(state, fluidCondition)
  local fluidLevel = common.clamp(state.maintenance.fluidLevel or 1, 0, 1)
  local lowFluidConditionMultiplier = common.getLowFluidConditionMultiplier(fluidLevel)

  local fluidConditionSeverity = common.sampleCurve(fluidCondition, {
    {1.0, 0},
    {0.70, 0},
    {0.50, 0.06},
    {0.32, 0.28},
    {0.18, 0.64},
    {0.08, 1.08},
    {0.0, 1.55}
  })
  local fluidLevelSeverity = common.sampleCurve(fluidLevel, {
    {1.0, 0},
    {0.70, 0},
    {0.50, 0.04},
    {0.32, 0.32},
    {0.15, 0.76},
    {0.05, 1.28},
    {0.0, 1.75}
  })
  return fluidLevel, lowFluidConditionMultiplier, fluidConditionSeverity, fluidLevelSeverity
end

local function calculateTransmissionShiftAndClutchEffects(
  wear, neglectSeverity, loadFactor, rpmFactor, limitStressFactor, fluidConditionSeverity,
  fluidLevelSeverity, transmissionOverheatFactor, thermalDriveSeverity, slipSeverity,
  serviceFrictionPenalty
)
  local shiftSpeedCoef = common.clamp(
    1 - wear.decline * 0.050 - fluidConditionSeverity * 0.250 - fluidLevelSeverity * 0.080 - thermalDriveSeverity * 0.120 -
        serviceFrictionPenalty * 0.060,
    0.25,
    1
  )
  local lockTorqueCoef = common.clamp(
    1 - wear.decline * 0.040 - fluidLevelSeverity * 0.360 - fluidConditionSeverity * 0.120 - thermalDriveSeverity * 0.140 -
        max(limitStressFactor - 0.75, 0) * 0.035,
    0.12,
    1
  )
  local clutchFreePlayCoef = 1 + wear.normalizedWear * 0.070 + fluidLevelSeverity * 0.95 + fluidConditionSeverity * 0.22 +
                                 slipSeverity * 0.34 +
                                  serviceFrictionPenalty * 0.055
  local symptomBaseRate = neglectSeverity * (0.0045 + wear.normalizedWear * 0.004) + fluidConditionSeverity * 0.006 +
                              fluidLevelSeverity * 0.018 + thermalDriveSeverity * 0.009
  local symptomRate = symptomBaseRate *
                          (0.28 + loadFactor * 0.45 + rpmFactor * 0.14 + common.clamp(limitStressFactor, 0, 1.35) * 0.24 +
                              transmissionOverheatFactor * 0.20)
  return shiftSpeedCoef, lockTorqueCoef, clutchFreePlayCoef, symptomRate
end

local function writeTransmissionCondition(
  result, wear, maintenanceAvg, maintenancePenalty, neglectSeverity, fluidLevelMileageMultiplier,
  limitStressFactor, thermalState, lowFluidConditionMultiplier, fluidConditionSeverity,
  fluidLevelSeverity, criticalFluidCondition, transmissionHeatFactor, transmissionOverheatFactor,
  shiftQualitySeverity, slipSeverity, frictionCoef, dynamicFrictionCoef, shiftSpeedCoef,
  lockTorqueCoef, clutchFreePlayCoef, symptomRate, criticalFluidLoss, catastrophicSlipRisk,
  hardFailureRate, stressMultiplier
)
  result.stressMultiplier = stressMultiplier
  result.ageMultiplier = fluidLevelMileageMultiplier
  result.neglectMultiplier = lowFluidConditionMultiplier
  result.wear = wear
  result.maintenanceAvg = maintenanceAvg
  result.maintenancePenalty = maintenancePenalty
  result.neglectSeverity = neglectSeverity
  result.fluidConditionSeverity = fluidConditionSeverity
  result.fluidLevelSeverity = fluidLevelSeverity
  result.criticalFluidCondition = criticalFluidCondition
  result.transmissionHeatFactor = transmissionHeatFactor
  result.transmissionOverheatFactor = transmissionOverheatFactor
  result.transmissionTempC = thermalState.tempC or 0
  result.shiftQualitySeverity = shiftQualitySeverity
  result.slipSeverity = slipSeverity
  result.criticalFluidLoss = criticalFluidLoss
  result.catastrophicSlipRisk = catastrophicSlipRisk
  result.frictionCoef = frictionCoef
  result.dynamicFrictionCoef = dynamicFrictionCoef
  result.shiftSpeedCoef = shiftSpeedCoef
  result.lockTorqueCoef = lockTorqueCoef
  result.clutchFreePlayCoef = clutchFreePlayCoef
  result.symptomRate = symptomRate
  result.hardFailureRate = hardFailureRate
  result.limitStressFactor = limitStressFactor
end

local function writeTransmissionServiceForecast(
  result, state, env, driveMultipliers, profile, classIntervalMultiplier, fluidCapacityFactor,
  fluidLevelMileageMultiplier, lowFluidConditionMultiplier, fluidConditionInterval,
  fluidLevelInterval, fluidConditionEffectiveMultiplier, fluidLevelEffectiveMultiplier,
  averageDriveMultiplier
)
  result.driveMultiplier = averageDriveMultiplier
  result.driveMultipliers = common.deepCopy(driveMultipliers.normalized)
  result.rawDriveMultipliers = common.deepCopy(driveMultipliers.raw)
  result.profile = common.deepCopy(profile)
  result.mileageAgeIndex = common.getMileageAgeIndex(env.avgMiles)
  result.fluidLevelMileageMultiplier = fluidLevelMileageMultiplier
  result.fluidCapacityFactor = fluidCapacityFactor
  result.classConditionIntervalMultiplier = classIntervalMultiplier
  result.lowFluidConditionMultiplier = lowFluidConditionMultiplier
  result.serviceTargets = common.deepCopy(serviceTargetValues)
  result.effectiveIntervals = {
    fluidCondition = fluidConditionInterval / max(fluidConditionEffectiveMultiplier, 0.0001),
    fluidLevel = fluidLevelInterval / max(fluidLevelEffectiveMultiplier, 0.0001)
  }
  result.effectiveDriveMultipliers = {
    fluidCondition = fluidConditionEffectiveMultiplier,
    fluidLevel = fluidLevelEffectiveMultiplier
  }
  result.serviceDueMilesRemaining = {
    fluidCondition = common.estimateMilesToTarget(state.maintenance.fluidCondition or 1, fluidConditionInterval,
      common.getPlanningMultiplier(env, 'fluidCondition', fluidConditionEffectiveMultiplier, driveMultipliers.normalized.fluidCondition),
      serviceTargetValues.fluidCondition),
    fluidLevel = common.estimateMilesToTarget(state.maintenance.fluidLevel or 1, fluidLevelInterval,
      common.getPlanningMultiplier(env, 'fluidLevel', fluidLevelEffectiveMultiplier, driveMultipliers.normalized.fluidLevel),
      serviceTargetValues.fluidLevel)
  }
end

local function calculateTransmissionHeatAndSlip(
  wear, loadFactor, rpmFactor, limitStressFactor, thermalState, fluidConditionSeverity,
  fluidLevelSeverity
)
  local transmissionHeatFactor = common.clamp(thermalState.heatFactor or 0, 0, 1.65)
  local transmissionOverheatFactor = common.clamp(thermalState.overheatFactor or 0, 0, 1)
  local thermalDriveSeverity = common.clamp(
    transmissionHeatFactor * 0.55 + transmissionOverheatFactor * 0.72 + loadFactor * 0.08 + rpmFactor * 0.06,
    0,
    1.65
  )
  local shiftQualitySeverity = common.clamp(
    fluidConditionSeverity * 0.96 + fluidLevelSeverity * 0.26 + thermalDriveSeverity * 0.44 + wear.normalizedWear * 0.12,
    0,
    2.1
  )
  local slipSeverity = common.clamp(
    fluidLevelSeverity * 1.08 + fluidConditionSeverity * 0.38 + thermalDriveSeverity * 0.34 +
        max(limitStressFactor - 0.55, 0) * 0.24 + max(loadFactor - 0.7, 0) * 0.28,
    0,
    2.35
  )
  return transmissionHeatFactor, transmissionOverheatFactor, thermalDriveSeverity, shiftQualitySeverity, slipSeverity
end

local function calculateTransmissionFailureRisk(
  wear, loadFactor, limitStressFactor, fluidCondition, fluidLevel, fluidConditionSeverity,
  fluidLevelSeverity, transmissionHeatFactor, transmissionOverheatFactor, slipSeverity
)
  local criticalFluidLoss = fluidLevel <= 0.03
  local catastrophicSlipRisk = criticalFluidLoss and
                                   (fluidCondition <= 0.12 or transmissionOverheatFactor >= 0.45 or loadFactor >= 0.82)
  local hardFailureRate = 0
  if catastrophicSlipRisk then
    hardFailureRate = 0.025 + fluidLevelSeverity * 0.030 + fluidConditionSeverity * 0.020 + transmissionOverheatFactor * 0.028 +
                          loadFactor * 0.022 + common.clamp(limitStressFactor, 0, 1.5) * 0.016
  elseif fluidLevelSeverity >= 0.88 and slipSeverity >= 0.78 then
    hardFailureRate = 0.004 + fluidLevelSeverity * 0.012 + fluidConditionSeverity * 0.008 + transmissionHeatFactor * 0.008 +
                          loadFactor * 0.009
  elseif fluidConditionSeverity >= 0.95 and transmissionOverheatFactor >= 0.4 and wear.bandName == 'worn' then
    hardFailureRate = 0.002 + fluidConditionSeverity * 0.008 + transmissionOverheatFactor * 0.010 + wear.decline * 0.008
  end
  return criticalFluidLoss, catastrophicSlipRisk, hardFailureRate
end

local function calculateTransmissionDriveEffects(wear, maintenanceAvg, neglectSeverity, loadFactor, rpmFactor, limitStressFactor, fluidConditionSeverity, fluidLevelSeverity, transmissionOverheatFactor, thermalDriveSeverity, slipSeverity)
  local serviceFrictionPenalty = common.clamp(healthyMaintenanceFloor - maintenanceAvg, 0, 1)
  local frictionCoef = 1 + wear.normalizedWear * 0.016 + fluidConditionSeverity * 0.080 + fluidLevelSeverity * 0.030 +
                           thermalDriveSeverity * 0.040 + serviceFrictionPenalty * 0.014
  local dynamicFrictionCoef = 1 + wear.normalizedWear * 0.020 + fluidConditionSeverity * 0.100 + fluidLevelSeverity * 0.040 +
                                  thermalDriveSeverity * 0.060 + serviceFrictionPenalty * 0.017
  local shiftSpeedCoef, lockTorqueCoef, clutchFreePlayCoef, symptomRate = calculateTransmissionShiftAndClutchEffects(
    wear, neglectSeverity, loadFactor, rpmFactor, limitStressFactor, fluidConditionSeverity,
    fluidLevelSeverity, transmissionOverheatFactor, thermalDriveSeverity, slipSeverity,
    serviceFrictionPenalty
  )
  return frictionCoef, dynamicFrictionCoef, shiftSpeedCoef, lockTorqueCoef, clutchFreePlayCoef, symptomRate
end

local function buildDerived(state, env)
  local wear = common.getWearProfile(env.avgMiles)
  local maintenanceAvg = common.getAverageMaintenance(state.maintenance)
  local maintenancePenalty = 1 - maintenanceAvg
  local neglectSeverity = common.getMaintenanceSeverity(maintenanceAvg)
  local loadFactor = common.clamp(env.loadFactor or 0, 0, 1)
  local rpmFactor = common.clamp(env.rpmFactor or 0, 0, 1)
  local driveMultipliers = getDriveMultipliers(env)
  local profile = env.profile or {}
  local classIntervalMultiplier = common.getClassConditionIntervalMultiplier(profile.class)
  local fluidCapacityFactor = common.getCapacityFactor('transmission', profile)
  local fluidLevelMileageMultiplier = common.getLevelMileageMultiplier('fluidLevel', env.avgMiles)
  local limitStressFactor = getLimitStressFactor(env, limitStressFractions)
  local thermalState = driveMultipliers.thermalState or {}

  local fluidCondition = common.clamp(state.maintenance.fluidCondition or 1, 0, 1)
  local fluidLevel, lowFluidConditionMultiplier, fluidConditionSeverity, fluidLevelSeverity = calculateTransmissionFluidSeverities(
    state, fluidCondition
  )
  local criticalFluidCondition = fluidCondition <= 0.08
  local transmissionHeatFactor, transmissionOverheatFactor, thermalDriveSeverity,
    shiftQualitySeverity, slipSeverity = calculateTransmissionHeatAndSlip(
    wear, loadFactor, rpmFactor, limitStressFactor, thermalState, fluidConditionSeverity,
    fluidLevelSeverity
  )

  local frictionCoef, dynamicFrictionCoef, shiftSpeedCoef, lockTorqueCoef, clutchFreePlayCoef, symptomRate = calculateTransmissionDriveEffects(wear, maintenanceAvg, neglectSeverity, loadFactor, rpmFactor, limitStressFactor, fluidConditionSeverity, fluidLevelSeverity, transmissionOverheatFactor, thermalDriveSeverity, slipSeverity)

  local criticalFluidLoss, catastrophicSlipRisk, hardFailureRate = calculateTransmissionFailureRisk(
    wear, loadFactor, limitStressFactor, fluidCondition, fluidLevel, fluidConditionSeverity,
    fluidLevelSeverity, transmissionHeatFactor, transmissionOverheatFactor, slipSeverity
  )

  local fluidConditionInterval = maintenanceIntervals.fluidCondition.fresh * classIntervalMultiplier
  local fluidLevelInterval = maintenanceIntervals.fluidLevel.fresh
  local fluidConditionEffectiveMultiplier = driveMultipliers.normalized.fluidCondition * lowFluidConditionMultiplier
  local fluidLevelEffectiveMultiplier = driveMultipliers.normalized.fluidLevel * fluidLevelMileageMultiplier * fluidCapacityFactor
  local averageDriveMultiplier = (fluidConditionEffectiveMultiplier + fluidLevelEffectiveMultiplier) / 2
  local stressMultiplier = (driveMultipliers.normalized.fluidCondition + driveMultipliers.normalized.fluidLevel) / 2

  local result = {}
  writeTransmissionCondition(
    result, wear, maintenanceAvg, maintenancePenalty, neglectSeverity, fluidLevelMileageMultiplier,
    limitStressFactor, thermalState, lowFluidConditionMultiplier, fluidConditionSeverity,
    fluidLevelSeverity, criticalFluidCondition, transmissionHeatFactor, transmissionOverheatFactor,
    shiftQualitySeverity, slipSeverity, frictionCoef, dynamicFrictionCoef, shiftSpeedCoef,
    lockTorqueCoef, clutchFreePlayCoef, symptomRate, criticalFluidLoss, catastrophicSlipRisk,
    hardFailureRate, stressMultiplier
  )
  writeTransmissionServiceForecast(
    result, state, env, driveMultipliers, profile, classIntervalMultiplier, fluidCapacityFactor,
    fluidLevelMileageMultiplier, lowFluidConditionMultiplier, fluidConditionInterval,
    fluidLevelInterval, fluidConditionEffectiveMultiplier, fluidLevelEffectiveMultiplier,
    averageDriveMultiplier
  )
  return result
end

local function advanceTransmissionSymptomTimers(runtime, dt)
  runtime.cooldownTimer = max((runtime.cooldownTimer or 0) - dt, 0)
  runtime.symptomTimer = max((runtime.symptomTimer or 0) - dt, 0)
  runtime.criticalSlipSeconds = max((runtime.criticalSlipSeconds or 0) - dt * 0.18, 0)
  runtime.forceHardFailure = false
  runtime.forceHardFailureTarget = nil
  runtime.forceHardFailurePersistent = false
  runtime.forceHardFailureReason = nil

  if runtime.symptomTimer <= 0 then
    runtime.activeSymptom = nil
  end
end

local function stepRuntime(runtime, state, derived, env, dt)
  advanceTransmissionSymptomTimers(runtime, dt)

  if env.engineRunningSeconds and env.engineRunningSeconds > 0 and
      ((derived.criticalFluidLoss or false) or (derived.criticalFluidCondition or false)) then
    local forcedSymptom = (derived.criticalFluidLoss or false) and 'slip' or
                              (((derived.shiftQualitySeverity or 0) >= 1.15 or common.clamp(env.rpmFactor or 0, 0, 1) >= 0.55) and 'shiftDelay' or 'roughShift')
    runtime.activeSymptom = forcedSymptom
    runtime.symptomTimer = max(runtime.symptomTimer or 0, common.pickDuration(2.8, 5.5))
    runtime.cooldownTimer = max(runtime.cooldownTimer or 0, runtime.symptomTimer + common.pickDuration(2.5, 5.5))
    state.lastFailureTime = os.time()
    state.lastFailureType = forcedSymptom
  end

  if env.engineRunningSeconds and env.engineRunningSeconds > 0 and
      (derived.criticalFluidLoss or derived.catastrophicSlipRisk) then
    local loadFactor = common.clamp(env.loadFactor or 0, 0, 1)
    local criticalSlipLoad = 0.14 + loadFactor * 0.52 + common.clamp(derived.slipSeverity or 0, 0, 1.85) * 0.22 +
                                 common.clamp(derived.transmissionOverheatFactor or 0, 0, 1) * 0.18 +
                                 common.clamp(derived.limitStressFactor or 0, 0, 1.4) * 0.16
    runtime.criticalSlipSeconds = runtime.criticalSlipSeconds + dt * criticalSlipLoad
    runtime.activeSymptom = 'slip'
    runtime.symptomTimer = max(runtime.symptomTimer or 0, 1.8)
    runtime.cooldownTimer = max(runtime.cooldownTimer or 0, 4.5)
    state.lastFailureTime = os.time()
    state.lastFailureType = runtime.activeSymptom

    local catastrophicThreshold = derived.catastrophicSlipRisk and
                                      max(1.6,
        3.4 - common.clamp(derived.slipSeverity or 0, 0, 1.85) * 0.72 - loadFactor * 0.40 -
                                          common.clamp(derived.transmissionOverheatFactor or 0, 0, 1) * 0.45) or
                                      6.5
    if runtime.criticalSlipSeconds >= catastrophicThreshold then
      runtime.forceHardFailure = true
      runtime.forceHardFailureTarget = 'transmission'
      runtime.forceHardFailurePersistent = true
      runtime.forceHardFailureReason = derived.criticalFluidLoss and 'transmission_fluid_loss' or 'transmission_clutch_failure'
      state.lastFailureTime = os.time()
      state.lastFailureType = 'transmission_break'
      return 'slip'
    end
  end

  if runtime.cooldownTimer <= 0 and not runtime.activeSymptom and
      (tonumber(env.engineRunningSeconds) or 0) > 0 and math.abs(tonumber(env.vehicleSpeed) or 0) >= 1 and
      common.rollChance(derived.symptomRate, dt) then
    local loadFactor = common.clamp(env.loadFactor or 0, 0, 1)
    runtime.activeSymptom = common.chooseWeighted({
      {value = 'roughShift', weight = 0.9 + (derived.shiftQualitySeverity or 0) * 1.4 + (derived.fluidConditionSeverity or 0) * 0.8},
      {value = 'shiftDelay', weight = 0.7 + (derived.shiftQualitySeverity or 0) * 0.9 + (derived.transmissionHeatFactor or 0) * 0.85},
      {value = 'slip', weight = 0.6 + (derived.slipSeverity or 0) * 1.6 + loadFactor * 0.8}
    })
    runtime.symptomTimer = common.pickDuration(3, 8)
    runtime.cooldownTimer = runtime.symptomTimer + common.pickDuration(8, 16)
    state.lastFailureTime = os.time()
    state.lastFailureType = runtime.activeSymptom
  end
  return runtime.activeSymptom
end

local function applyGearboxRuntime(entry, derived, symptom)
  local device = entry.device
  local base = entry.base or {}
  resetDeviceRuntime(device, base)
  local frictionCoef = derived.frictionCoef
  local dynamicFrictionCoef = derived.dynamicFrictionCoef
  local shiftSpeedCoef = derived.shiftSpeedCoef

  if derived.criticalFluidCondition then
    frictionCoef = frictionCoef * 1.04
    dynamicFrictionCoef = dynamicFrictionCoef * 1.06
    shiftSpeedCoef = common.clamp(shiftSpeedCoef * 0.84, 0.25, 1)
  end
  if derived.criticalFluidLoss then
    frictionCoef = frictionCoef * 1.05
    dynamicFrictionCoef = dynamicFrictionCoef * 1.08
    shiftSpeedCoef = common.clamp(shiftSpeedCoef * 0.78, 0.25, 1)
  end

  if symptom == 'roughShift' then
    frictionCoef = frictionCoef * 1.03
    dynamicFrictionCoef = dynamicFrictionCoef * 1.04
  elseif symptom == 'shiftDelay' then
    shiftSpeedCoef = common.clamp(shiftSpeedCoef * 0.82, 0.25, 1)
  elseif symptom == 'slip' then
    frictionCoef = frictionCoef * 1.06
    dynamicFrictionCoef = dynamicFrictionCoef * 1.08
    shiftSpeedCoef = common.clamp(shiftSpeedCoef * 0.88, 0.25, 1)
  end

  if base.friction ~= nil then
    device.friction = base.friction * frictionCoef
  end
  if base.dynamicFriction ~= nil then
    device.dynamicFriction = base.dynamicFriction * dynamicFrictionCoef
  end
  if base.gearRatioChangeRate ~= nil then
    device.gearRatioChangeRate = base.gearRatioChangeRate * shiftSpeedCoef
  end
  if base.lockTorque ~= nil and device.lockTorque ~= nil then
    local lockTorqueCoef = derived.lockTorqueCoef
    if symptom == 'slip' then
      lockTorqueCoef = common.clamp(lockTorqueCoef * 0.92, 0.78, 1)
    end
    device.lockTorque = base.lockTorque * lockTorqueCoef
  end
end

local function applyClutchRuntime(entry, derived, symptom)
  local device = entry.device
  local base = entry.base or {}
  resetDeviceRuntime(device, base)
  local lockTorqueCoef = derived.lockTorqueCoef
  local freePlayCoef = derived.clutchFreePlayCoef

  if derived.criticalFluidCondition then
    lockTorqueCoef = common.clamp(lockTorqueCoef * 0.90, 0.12, 1)
    freePlayCoef = freePlayCoef + 0.35
  end
  if derived.criticalFluidLoss then
    lockTorqueCoef = common.clamp(lockTorqueCoef * 0.72, 0.12, 1)
    freePlayCoef = freePlayCoef + 1.20
  end

  if symptom == 'slip' then
    lockTorqueCoef = common.clamp(lockTorqueCoef * 0.86, 0.12, 1)
    freePlayCoef = freePlayCoef + 1.1
  elseif symptom == 'roughShift' then
    freePlayCoef = freePlayCoef + 0.8
  end

  if base.lockTorque ~= nil and device.lockTorque ~= nil then
    device.lockTorque = base.lockTorque * lockTorqueCoef
  end
  if base.clutchFreePlay ~= nil and device.clutchFreePlay ~= nil then
    device.clutchFreePlay = base.clutchFreePlay * common.clamp(freePlayCoef, 1, 5.0)
  end
  if device.calculateInertia then
    device:calculateInertia()
  end
end

local function apply(context, state, runtime, derived)
  local symptom = runtime.activeSymptom

  for _, entry in ipairs(context.gearboxes or {}) do
    applyGearboxRuntime(entry, derived, symptom)
  end

  for _, entry in ipairs(context.clutches or {}) do
    applyClutchRuntime(entry, derived, symptom)
  end
end

local function getHardFailureStateForDevice(device)
  if device.damageGearRatioChangeRateCoef ~= nil then
    return {
      damageFrictionCoef = 50,
      damageGearRatioChangeRateCoef = 0.2,
      isBroken = true
    }
  end
  if device.synchroWear ~= nil then
    local synchroWear = {}
    for gearIndex, _ in pairs(device.gearRatios or {}) do
      synchroWear[gearIndex] = 1
    end
    return {
      damageFrictionCoef = 50,
      synchroWear = synchroWear,
      isBroken = true
    }
  end
  if device.damageClutchFreePlayCoef ~= nil or device.damageLockTorqueCoef ~= nil then
    return {
      damageClutchFreePlayCoef = 20,
      damageLockTorqueCoef = 0.5,
      clutchPermanentlyDamaged = true
    }
  end
  return {
    damageLockTorqueCoef = 0.5
  }
end

local function clearFailureRuntime(context)
  local runtime = context.runtime or nil
  if type(runtime) == "table" then
    runtime.criticalSlipSeconds = 0
    runtime.forceHardFailure = false
    runtime.forceHardFailureTarget = nil
    runtime.forceHardFailurePersistent = false
    runtime.forceHardFailureReason = nil
  end

  for _, entry in ipairs(context.gearboxes or {}) do
    resetDeviceRuntime(entry.device, entry.base or {}, true)
  end

  for _, entry in ipairs(context.clutches or {}) do
    resetDeviceRuntime(entry.device, entry.base or {}, true)
  end
end

M.getDefaultMaintenance = getDefaultMaintenance
M.drainMaintenance = drainMaintenance
M.buildDerived = buildDerived
M.stepRuntime = stepRuntime
M.apply = apply
M.getHardFailureStateForDevice = getHardFailureStateForDevice
M.clearFailureRuntime = clearFailureRuntime
M.minimumHardFailureMileage = minimumHardFailureMileage

return M
