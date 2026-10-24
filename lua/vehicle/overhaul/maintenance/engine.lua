-- Engine maintenance: oil and ignition wear, output effects, symptoms and hard failures.
-- Read tuning, service drain, severity forecasts, derived effects, runtime progression and device application.
local M = {}

local common = require('vehicle/overhaul/maintenance/common')
local getLimitStressFactor = require('vehicle/overhaul/maintenance/limitStress')
local weightedSum = require('vehicle/overhaul/maintenance/weightedSum')

local abs = math.abs
local max = math.max
local min = math.min

-- Config ------------------------------------------------------------------------------------------

local limitStressFractions = {
  rpmRampStart = 0.72, loadRampStart = 0.78, heatRampStart = 0.7,
  rpm = 0.95, load = 1.1, heat = 0.75, overheat = 1.45, maximum = 2.2
}
local driveWearFractions = {
  oilCondition = {rpm = 0.55, load = 0.85, heat = 0.15, outputStress = 0.75, limitStress = 0.45},
  oilLevel = {rpm = 1.25, load = 0.35, heat = 0.10, outputStress = 0.12, limitStress = 0.15},
  ignitionService = {rpm = 0.35, load = 1.00, heat = 0.15, outputStress = 1.20, limitStress = 0.50}
}
local driveEffectFractions = {
  ageWear = {friction = 0.08, dynamicFriction = 0.35, idleError = 5},
  integrityTorqueLoss = {base = 0.12, load = 0.14, rpm = 0.05},
  maintenanceTorqueLoss = 0.15,
  lubricationTorqueLoss = {oilLevel = 0.34, oilCondition = 0.22, lubrication = 0.12, thermal = 0.08},
  stressTorqueLoss = {oilLevel = 0.34, oilCondition = 0.18, integrity = 0.24},
  stressParticipation = {base = 0.18, load = 0.48, rpm = 0.22, limitStress = 0.20},
  powerLoss = {oilLevel = 0.08, oilCondition = 0.05, integrity = 0.05, lubrication = 0.04, thermal = 0.03},
  friction = {torqueLoss = 0.18, maintenance = 0.008, oilStarvation = 0.26, oilCondition = 0.08,
    integrity = 0.05, thermal = 0.10, ignition = 0.06},
  dynamicFriction = {powerLoss = 0.22, maintenance = 0.012, oilStarvation = 0.32, oilCondition = 0.09,
    integrity = 0.06, thermal = 0.15, ignition = 0.04},
  roughness = {torqueLoss = 0.95, maintenance = 0.12, wear = 0.06, oilStarvation = 0.42,
    oilCondition = 0.14, integrity = 0.22, thermal = 0.18, ignition = 0.38},
  ignitionChance = {age = 0.006, maintenance = 0.012, oilStarvation = 0.025, oilCondition = 0.01,
    integrity = 0.012, thermal = 0.012, ignition = 0.045},
  symptomBaseRate = {neglect = 0.005, wear = 0.005, oilStarvation = 0.016,
    integrity = 0.008, thermal = 0.018, ignition = 0.015},
  symptomRate = {base = 0.24, load = 0.42, heat = 0.14, rpm = 0.12, limitStress = 0.2}
}
local ignitionWearStartMiles = 170000
local ignitionWearWindowMiles = 240000

local symptomDurations = {
  roughRunning = {6, 14},
  ticking = {5, 11},
  roughIdle = {5, 12},
  torqueDip = {1.5, 4},
  powerFade = {3, 7},
  stall = {0.5, 1.5}
}

local minimumHardFailureMileage = 190000
local maintenanceIntervals = {
  oilCondition = {fresh = 150, aged = 120, worn = 90},
  oilLevel = {fresh = 240, aged = 180, worn = 120},
  ignitionService = {fresh = 280, aged = 220, worn = 140}
}
local serviceTargetValues = {
  oilCondition = 0.55,
  oilLevel = 0.5,
  ignitionService = 0.6
}
local pistonRingOilLossPerSecond = {
  fresh = 0.000024,
  aged = 0.000036,
  worn = 0.000054
}
local moderateDriveReference = {
  rpmFactor = 0.3,
  loadFactor = 0.35,
  heatFactor = 0.15,
  outputStressFactor = 0,
  limitStressFactor = 0
}

-- Defaults and drive factors ----------------------------------------------------------------------

local function getDefaultMaintenance()
  return {
    oilCondition = 1,
    oilLevel = 1,
    ignitionService = 1
  }
end

local function reshapeOutputStressFactor(outputStressFactor)
  return common.sampleCurve(max(tonumber(outputStressFactor) or 0, 0), {
    {0, 0},
    {0.15, 0.02},
    {0.35, 0.10},
    {0.8, 0.45},
    {1.6, 1.2},
    {3.0, 2.5},
    {5.0, 4.0}
  })
end

local function reshapeLimitStressFactor(limitStressFactor)
  return common.sampleCurve(max(tonumber(limitStressFactor) or 0, 0), {
    {0, 0},
    {0.4, 0.05},
    {0.9, 0.28},
    {1.4, 0.65},
    {2.2, 1.25}
  })
end

local function getLiveTorqueHoldCoef(torqueHoldCoef, loadFactor, rpmCapacity)
  local baseHoldCoef = common.clamp(tonumber(torqueHoldCoef) or 1, 0, 1)
  local baseLoss = 1 - baseHoldCoef
  if baseLoss <= 0 then
    return 1
  end

  local loadRampFactor = common.sampleCurve(common.clamp(tonumber(loadFactor) or 0, 0, 1), {
    {0.00, 0.00},
    {0.35, 0.00},
    {0.55, 0.18},
    {0.75, 0.55},
    {0.90, 0.88},
    {1.00, 1.00}
  })
  local rpmRampFactor = common.sampleCurve(common.clamp(tonumber(rpmCapacity) or 0, 0, 1.1), {
    {0.00, 0.00},
    {0.55, 0.00},
    {0.78, 0.20},
    {0.92, 0.50},
    {1.00, 0.70},
    {1.10, 0.70}
  })
  local combinedRampFactor = common.clamp(loadRampFactor * 0.8 + rpmRampFactor * 0.2, 0, 1)

  return common.clamp(1 - baseLoss * combinedRampFactor, baseHoldCoef, 1)
end

local function getPowerLimitReason(derived, symptom, directDriveSeverity, powerCapActive, lubricationDamageStage)
  if symptom == 'stall' or symptom == 'powerFade' or symptom == 'torqueDip' then
    return 'Temporary symptom'
  end
  if directDriveSeverity >= 0.35 or (derived.oilStarvationSeverity or 0) >= 0.2 or (lubricationDamageStage or 0) >= 0.35 then
    return 'Oil starvation'
  end
  if (derived.ignitionSeverity or 0) >= 0.45 then
    return 'Severe ignition issue'
  end
  return 'Maintenance torque protection'
end

local function getDriveMultiplierValues(rpmFactor, loadFactor, heatFactor, outputStressFactor, limitStressFactor)
  return {
    oilCondition = weightedSum(1, rpmFactor * driveWearFractions.oilCondition.rpm,
      loadFactor * driveWearFractions.oilCondition.load, heatFactor * driveWearFractions.oilCondition.heat,
      outputStressFactor * driveWearFractions.oilCondition.outputStress, limitStressFactor * driveWearFractions.oilCondition.limitStress),
    oilLevel = weightedSum(1, rpmFactor * driveWearFractions.oilLevel.rpm,
      loadFactor * driveWearFractions.oilLevel.load, heatFactor * driveWearFractions.oilLevel.heat,
      outputStressFactor * driveWearFractions.oilLevel.outputStress, limitStressFactor * driveWearFractions.oilLevel.limitStress),
    ignitionService = weightedSum(1, rpmFactor * driveWearFractions.ignitionService.rpm,
      loadFactor * driveWearFractions.ignitionService.load, heatFactor * driveWearFractions.ignitionService.heat,
      outputStressFactor * driveWearFractions.ignitionService.outputStress, limitStressFactor * driveWearFractions.ignitionService.limitStress)
  }
end

local function getDriveMultipliers(env)
  env = env or {}
  local limitStressFactor = reshapeLimitStressFactor(getLimitStressFactor(env, limitStressFractions))
  local loadGate = common.getOutputLoadGate(env.loadFactor)
  local outputStressFactor = reshapeOutputStressFactor(max(tonumber(env.outputStressFactor) or tonumber(env.powerFactor) or 0, 0)) * loadGate
  local rawMultipliers = getDriveMultiplierValues(
    common.clamp(env.rpmFactor or 0, 0, 1),
    common.clamp(env.loadFactor or 0, 0, 1),
    common.clamp(env.heatFactor or 0, 0, 1),
    outputStressFactor,
    limitStressFactor
  )
  local referenceMultipliers = getDriveMultiplierValues(
    moderateDriveReference.rpmFactor,
    moderateDriveReference.loadFactor,
    moderateDriveReference.heatFactor,
    moderateDriveReference.outputStressFactor,
    moderateDriveReference.limitStressFactor
  )

  return {
    raw = rawMultipliers,
    normalized = {
      oilCondition = common.normalizeDriveMultiplier(rawMultipliers.oilCondition, referenceMultipliers.oilCondition),
      oilLevel = common.normalizeDriveMultiplier(rawMultipliers.oilLevel, referenceMultipliers.oilLevel),
      ignitionService = common.normalizeDriveMultiplier(rawMultipliers.ignitionService, referenceMultipliers.ignitionService)
    }
  }
end

-- Service drain -----------------------------------------------------------------------------------

local function getMileageOilLevelMultiplier(avgMiles)
  return common.getLevelMileageMultiplier('oilLevel', avgMiles)
end

local function getEffectiveDrainMultipliers(env, avgMiles)
  local driveMultipliers = getDriveMultipliers(env)
  local oilConditionStressMultiplier = 1
  local oilLevelMileageMultiplier = getMileageOilLevelMultiplier(avgMiles)

  return {
    raw = {
      oilCondition = driveMultipliers.raw.oilCondition * oilConditionStressMultiplier,
      oilLevel = driveMultipliers.raw.oilLevel,
      ignitionService = driveMultipliers.raw.ignitionService
    },
    normalized = {
      oilCondition = driveMultipliers.normalized.oilCondition * oilConditionStressMultiplier,
      oilLevel = driveMultipliers.normalized.oilLevel,
      ignitionService = driveMultipliers.normalized.ignitionService
    },
    oilConditionStressMultiplier = oilConditionStressMultiplier,
    oilLevelMileageMultiplier = oilLevelMileageMultiplier
  }
end

-- Only builds beyond their block torque rating qualify for drag-race oil consumption.
local function getExtremePowerMultiplier(env)
  env = env or {}
  local overloadGate = common.getRatedOverloadGate(env.torqueNm, env.maxTorqueRating)
  return 1 + overloadGate * (common.sampleCurve(max(tonumber(env.powerHp) or 0, 0), {
    {0, 1},
    {700, 1},
    {1000, 31},
    {2500, 55},
    {5000, 88}
  }) - 1)
end

local function getExtremeOutputGate(env)
  env = env or {}
  local loadGate = common.sampleCurve(common.clamp(env.loadFactor or 0, 0, 1), {
    {0, 0},
    {0.65, 0},
    {0.80, 0.25},
    {0.90, 0.65},
    {0.95, 1},
    {1, 1}
  })
  local rpmParticipation = 0.35 + common.clamp(env.rpmFactor or 0, 0, 1) * 0.65
  return loadGate * rpmParticipation
end

local function drainEngineOilCondition(maintenance, deltaMiles, avgMiles, env, driveMultipliers, profile)
  local classIntervalMultiplier = common.getClassConditionIntervalMultiplier(profile)
  local dieselIntervalMultiplier = profile.fuelType == 'diesel' and 1.25 or 1
  local dieselLoadMultiplier = profile.fuelType == 'diesel' and (1 + common.clamp(env.loadFactor or 0, 0, 1) * 0.25) or 1
  local dieselOilLevelMultiplier = profile.fuelType == 'diesel' and 0.85 or 1
  local torqueCapacityStress = common.getTorqueCapacityStress(env.combustionTorque, env.maxTorqueRating)
  local oilLevelCapacityFactor = common.getCapacityFactor('oil', profile)
  local oilLevelMileageMultiplier = getMileageOilLevelMultiplier(avgMiles)
  local oilLevelTorqueMultiplier = 1 + torqueCapacityStress * 1.5
  local oilConditionTorqueMultiplier = 1 + torqueCapacityStress * 4
  local oilTempMultiplier = common.getOilTemperatureMultiplier(env.oilTemp)
  local lowOilConditionMultiplier = common.getLowFluidConditionMultiplier(maintenance.oilLevel or 1)
  local oilConditionInterval = maintenanceIntervals.oilCondition.fresh * classIntervalMultiplier * dieselIntervalMultiplier
  local oilLevelInterval = maintenanceIntervals.oilLevel.fresh
  local ignitionInterval = maintenanceIntervals.ignitionService.fresh

  local extremeOutputGate = getExtremeOutputGate(env)
  local engineRuntimeMiles = max(tonumber(env.engineRunningSeconds) or 0, 0) / 60
  local normalOilEquivalentMiles = deltaMiles * driveMultipliers.oilLevel * oilLevelMileageMultiplier * oilLevelTorqueMultiplier *
                                     dieselOilLevelMultiplier
  local extremeEquivalentMiles = max(deltaMiles, engineRuntimeMiles) * extremeOutputGate *
                                   max(getExtremePowerMultiplier(env) - 1, 0)
  local oilLevelEquivalentMiles = (normalOilEquivalentMiles + extremeEquivalentMiles) * oilLevelCapacityFactor
  local stationaryConditionGate = max(extremeOutputGate, torqueCapacityStress,
    common.clamp((oilTempMultiplier - 1) / 7, 0, 1))
  local oilConditionEquivalentMiles = max(deltaMiles, engineRuntimeMiles * stationaryConditionGate)

  maintenance.oilCondition = common.applyIntervalWear(
    maintenance.oilCondition or 1,
    oilConditionInterval,
    oilConditionEquivalentMiles,
    driveMultipliers.oilCondition * oilTempMultiplier * lowOilConditionMultiplier * oilConditionTorqueMultiplier * dieselLoadMultiplier,
    serviceTargetValues.oilCondition
  )
  maintenance.oilLevel = common.applyIntervalWear(
    maintenance.oilLevel or 1,
    oilLevelInterval,
    oilLevelEquivalentMiles,
    1,
    serviceTargetValues.oilLevel
  )
  maintenance.ignitionService = common.applyIntervalWear(
    maintenance.ignitionService or 1,
    ignitionInterval,
    deltaMiles,
    driveMultipliers.ignitionService,
    serviceTargetValues.ignitionService
  )
  return oilLevelCapacityFactor, oilLevelMileageMultiplier, lowOilConditionMultiplier, oilConditionInterval
end

local function drainMaintenance(maintenance, deltaMiles, avgMiles, env)
  maintenance = common.shallowCopy(maintenance)
  env = env or {}
  local effectiveDrainMultipliers = getEffectiveDrainMultipliers(env, avgMiles)
  local driveMultipliers = effectiveDrainMultipliers.normalized
  local profile = type(env.profile) == 'table' and env.profile or {}
  local oilLevelCapacityFactor, oilLevelMileageMultiplier, lowOilConditionMultiplier, oilConditionInterval = drainEngineOilCondition(
    maintenance, deltaMiles, avgMiles, env, driveMultipliers, profile
  )

  if profile.fuelType == 'diesel' then
    local idleRuntimeSeconds = max(tonumber(env.idleRuntimeSeconds) or 0, 0)
    if idleRuntimeSeconds > 0 then
      maintenance.oilCondition = common.applyIntervalWear(
        maintenance.oilCondition or 1,
        oilConditionInterval,
        idleRuntimeSeconds * (25 / 3600),
        lowOilConditionMultiplier,
        serviceTargetValues.oilCondition
      )
    end
  end

  if env.pistonRingsDamaged == true then
    local engineRunningSeconds = max(tonumber(env.engineRunningSeconds) or 0, 0)
    if engineRunningSeconds > 0 then
      local rpmCapacity = common.clamp(tonumber(env.rpmCapacity) or tonumber(env.rpmFactor) or 0, 0, 1.35)
      local rpmOilLossFactor = 0.35 + rpmCapacity * 1.7 + max(rpmCapacity - 0.82, 0) * 2.8
      local heatOilLossFactor = 1 + common.clamp(env.heatFactor or 0, 0, 1) * 0.45 + common.clamp(env.overheatFactor or 0, 0, 1) * 0.8
      local ringOilLoss = pistonRingOilLossPerSecond.fresh * engineRunningSeconds * rpmOilLossFactor *
                              heatOilLossFactor * oilLevelMileageMultiplier * oilLevelCapacityFactor
      maintenance.oilLevel = common.clamp((maintenance.oilLevel or 1) - ringOilLoss, 0, 1)
    end
  end

  return maintenance
end

-- Vanilla engine state ----------------------------------------------------------------------------

-- Vanilla crash damage changes ignition error chances between ticks.
local function getVanillaIgnitionChance(engine, fieldName)
  local tracking = engine.rlsMaintenanceIgnition
  if type(tracking) ~= "table" then
    tracking = {}
    engine.rlsMaintenanceIgnition = tracking
  end
  local current = tonumber(engine[fieldName]) or 0
  local written = tracking[fieldName .. "Written"]
  local vanillaValue = tracking[fieldName]
  if vanillaValue == nil or written == nil or current < written then
    vanillaValue = current
  elseif current > written then
    vanillaValue = vanillaValue + (current - written)
  end
  tracking[fieldName] = vanillaValue
  return vanillaValue
end

local function setIgnitionChance(engine, fieldName, value)
  engine[fieldName] = value
  if type(engine.rlsMaintenanceIgnition) == "table" then
    engine.rlsMaintenanceIgnition[fieldName .. "Written"] = value
  end
end

local function resetEngineState(engine, base, derived, includeDamage)
  if engine.wearFrictionCoef ~= nil then
    engine.wearFrictionCoef = derived and derived.ageWearFrictionCoef or 1
  end
  if engine.wearDynamicFrictionCoef ~= nil then
    engine.wearDynamicFrictionCoef = derived and derived.ageWearDynamicFrictionCoef or 1
  end
  if engine.wearIdleAVReadErrorRangeCoef ~= nil then
    engine.wearIdleAVReadErrorRangeCoef = derived and derived.ageWearIdleErrorCoef or 1
  end
  if includeDamage then
    if engine.damageFrictionCoef ~= nil then
      engine.damageFrictionCoef = base.damageFrictionCoef or 1
    end
    if engine.damageDynamicFrictionCoef ~= nil then
      engine.damageDynamicFrictionCoef = base.damageDynamicFrictionCoef or 1
    end
    if engine.damageIdleAVReadErrorRangeCoef ~= nil then
      engine.damageIdleAVReadErrorRangeCoef = base.damageIdleAVReadErrorRangeCoef or 1
    end
  end
  if base.friction ~= nil then
    engine.friction = base.friction
  end
  if base.dynamicFriction ~= nil then
    engine.dynamicFriction = base.dynamicFriction
  end
  if base.originalMaxTorqueLimit ~= nil then
    engine.maxTorqueLimit = base.originalMaxTorqueLimit
  end
  if base.idleAVReadErrorRangeHalf ~= nil then
    engine.idleAVReadErrorRangeHalf = base.idleAVReadErrorRangeHalf
  end
  if base.idleAVReadErrorRange ~= nil then
    engine.idleAVReadErrorRange = base.idleAVReadErrorRange
  end
end

-- Severities and failure rates --------------------------------------------------------------------

local function calculateEngineServiceSeverities(oilCondition, ignitionService, integrityValue)
  local oilConditionSeverity = common.sampleCurve(oilCondition, {
    {1.0, 0},
    {0.18, 0},
    {0.08, 0.18},
    {0.03, 0.42},
    {0.0, 0.75}
  })
  local oilConditionDriveSeverity = common.sampleCurve(oilCondition, {
    {1.0, 0},
    {0.70, 0},
    {0.50, 0.06},
    {0.30, 0.24},
    {0.16, 0.52},
    {0.05, 0.84},
    {0.0, 1.05}
  })
  local ignitionSeverity = common.sampleCurve(ignitionService, {
    {1.0, 0},
    {0.70, 0},
    {0.50, 0.06},
    {0.30, 0.24},
    {0.16, 0.56},
    {0.05, 0.90},
    {0.0, 1.15}
  })
  local integritySeverity = common.sampleCurve(integrityValue, {
    {1.0, 0},
    {0.82, 0},
    {0.65, 0.15},
    {0.45, 0.38},
    {0.25, 0.72},
    {0.10, 1.05},
    {0.0, 1.3}
  })
  return oilConditionSeverity, oilConditionDriveSeverity, ignitionSeverity, integritySeverity
end

local function calculateCriticalOilFailureSeverities(
  oilHeatFactor, oilOverheatFactor, loadFactor, rpmFactor, limitStressFactor,
  oilLevelDriveSeverity, oilStarvationSeverity, oilConditionSeverity, oilConditionDriveSeverity,
  integritySeverity, catastrophicOilStarvation, dryOilLockup, lubricationThermalSeverity
)
  local lubricationCollapseSeverity = common.clamp(
    max(lubricationThermalSeverity * 0.9, oilStarvationSeverity * 0.95 + oilConditionSeverity * 0.55 + integritySeverity * 0.22),
    0,
    1.6
  )
  local lubricationDriveSeverity = common.clamp(
    oilLevelDriveSeverity * 0.74 + oilConditionDriveSeverity * 0.52 + integritySeverity * 0.32 +
        max(oilLevelDriveSeverity - 0.08, 0) * loadFactor * 0.34 + max(oilLevelDriveSeverity - 0.08, 0) * rpmFactor * 0.18 +
        max(oilConditionDriveSeverity - 0.1, 0) * loadFactor * 0.14 + common.clamp(limitStressFactor, 0, 1.4) * 0.08,
    0,
    1.85
  )
  local criticalOilFailureSeverity = common.clamp(
    max(
      lubricationCollapseSeverity * 0.94,
      oilStarvationSeverity * 1.05 + oilConditionSeverity * 0.82 + lubricationThermalSeverity * 0.52 +
          max(oilStarvationSeverity - 0.52, 0) * 0.62 + max(oilConditionSeverity - 0.28, 0) * 0.46
    ),
    0,
    2.25
  )
  local cylinderWallThreatSeverity = common.clamp(
    max(
      criticalOilFailureSeverity * 0.88,
      oilStarvationSeverity * 1.28 + oilConditionSeverity * 0.95 + oilOverheatFactor * 0.40 + oilHeatFactor * 0.24 +
          max(oilStarvationSeverity - 0.70, 0) * 1.05 + max(oilConditionSeverity - 0.36, 0) * 0.70
    ) + (catastrophicOilStarvation and 0.35 or 0) + (dryOilLockup and 0.55 or 0),
    0,
    2.8
  )
  return lubricationCollapseSeverity, lubricationDriveSeverity, criticalOilFailureSeverity, cylinderWallThreatSeverity
end

local function calculateEngineLubricationSeverity(inputs)
  local oilLevel, oilCondition = inputs.oilLevel, inputs.oilCondition
  local ignitionService, integrityValue = inputs.ignitionService, inputs.integrityValue
  local oilHeatFactor, oilOverheatFactor = inputs.oilHeatFactor, inputs.oilOverheatFactor
  local loadFactor, rpmFactor = inputs.loadFactor, inputs.rpmFactor
  local limitStressFactor = inputs.limitStressFactor
  local oilLevelDriveSeverity = common.sampleCurve(oilLevel, {
    {1.0, 0},
    {0.70, 0},
    {0.50, 0.06},
    {0.30, 0.24},
    {0.16, 0.58},
    {0.08, 0.98},
    {0.0, 1.3}
  })
  local oilStarvationSeverity = common.sampleCurve(oilLevel, {
    {1.0, 0},
    {0.20, 0},
    {0.10, 0.2},
    {0.05, 0.55},
    {0.02, 1.0},
    {0.0, 1.35}
  })
  local oilConditionSeverity, oilConditionDriveSeverity, ignitionSeverity, integritySeverity = calculateEngineServiceSeverities(
    oilCondition, ignitionService, integrityValue
  )
  local severeOilStarvation = oilLevel <= 0.05 and oilCondition <= 0.14
  local catastrophicOilStarvation = oilLevel <= 0.015 and oilCondition <= 0.05
  local dryOilLockup = oilLevel <= 0.001
  local lubricationThermalSeverity = common.clamp(
    oilHeatFactor * 0.18 + oilOverheatFactor * 0.42 + oilStarvationSeverity * 0.52 + oilConditionSeverity * 0.28 +
        loadFactor * 0.10 + rpmFactor * 0.08 + common.clamp(limitStressFactor, 0, 1.4) * 0.05,
    0,
    1.45
  )
  local lubricationCollapseSeverity, lubricationDriveSeverity, criticalOilFailureSeverity, cylinderWallThreatSeverity = calculateCriticalOilFailureSeverities(
    oilHeatFactor, oilOverheatFactor, loadFactor, rpmFactor, limitStressFactor,
    oilLevelDriveSeverity, oilStarvationSeverity, oilConditionSeverity, oilConditionDriveSeverity,
    integritySeverity, catastrophicOilStarvation, dryOilLockup, lubricationThermalSeverity
  )
  return {
    oilLevelDriveSeverity = oilLevelDriveSeverity,
    oilStarvationSeverity = oilStarvationSeverity,
    oilConditionSeverity = oilConditionSeverity,
    oilConditionDriveSeverity = oilConditionDriveSeverity,
    ignitionSeverity = ignitionSeverity,
    integritySeverity = integritySeverity,
    severeOilStarvation = severeOilStarvation,
    catastrophicOilStarvation = catastrophicOilStarvation,
    dryOilLockup = dryOilLockup,
    lubricationThermalSeverity = lubricationThermalSeverity,
    lubricationCollapseSeverity = lubricationCollapseSeverity,
    lubricationDriveSeverity = lubricationDriveSeverity,
    criticalOilFailureSeverity = criticalOilFailureSeverity,
    cylinderWallThreatSeverity = cylinderWallThreatSeverity,
  }
end

local function calculateEngineHardFailureRate(
  heatFactor, integritySeverity, torqueHoldCoef, catastrophicOilStarvation,
  lubricationThermalSeverity, loadFactor, rpmFactor, severeOilStarvation, oilStarvationSeverity,
  oilConditionSeverity
)
  local hardFailureRate = 0
  local hardFailureIntegrityBias = common.clamp(integritySeverity * 0.75 + (1 - torqueHoldCoef) * 0.35, 0, 1.35)
  if catastrophicOilStarvation then
    hardFailureRate = 0.90 + hardFailureIntegrityBias * 0.42 + lubricationThermalSeverity * 0.22 + loadFactor * 0.95 +
                          rpmFactor * 0.72 + heatFactor * 0.55
  elseif severeOilStarvation then
    hardFailureRate = 0.07 + oilStarvationSeverity * 0.16 + hardFailureIntegrityBias * 0.08 + lubricationThermalSeverity * 0.07 +
                          loadFactor * 0.12 + rpmFactor * 0.07 + heatFactor * 0.06
  elseif oilConditionSeverity >= 0.38 then
    hardFailureRate = 0.008 + oilConditionSeverity * 0.032 + hardFailureIntegrityBias * 0.016 + lubricationThermalSeverity * 0.02 +
                          loadFactor * 0.018 + rpmFactor * 0.015
  elseif oilStarvationSeverity >= 0.42 and integritySeverity >= 0.25 then
    hardFailureRate = 0.010 + oilStarvationSeverity * 0.03 + hardFailureIntegrityBias * 0.022 + lubricationThermalSeverity * 0.02 +
                          loadFactor * 0.018 + rpmFactor * 0.015
  elseif lubricationThermalSeverity >= 0.95 then
    hardFailureRate = 0.012 + lubricationThermalSeverity * 0.03 + hardFailureIntegrityBias * 0.016 + loadFactor * 0.02 +
                          rpmFactor * 0.02
  end
  return hardFailureRate
end

local function calculateEngineFailureAndServiceRates(
  env, pistonRingsDamaged, pistonRingOilConsumptionRate, heatFactor, oilLevelMileageMultiplier,
  oilCapacityFactor, integritySeverity, torqueHoldCoef, catastrophicOilStarvation,
  lubricationThermalSeverity, loadFactor, rpmFactor, severeOilStarvation, oilStarvationSeverity,
  oilConditionSeverity, classConditionIntervalMultiplier, dieselIntervalMultiplier, driveMultipliers,
  oilTemperatureMultiplier, lowOilConditionMultiplier, torqueCapacityStress, dieselLoadMultiplier,
  dieselOilLevelMultiplier
)
  if pistonRingsDamaged then
    local rpmCapacity = common.clamp(tonumber(env.rpmCapacity) or tonumber(env.rpmFactor) or 0, 0, 1.35)
    local rpmOilLossFactor = 0.35 + rpmCapacity * 1.7 + max(rpmCapacity - 0.82, 0) * 2.8
    local heatOilLossFactor = 1 + heatFactor * 0.45 + common.clamp(env.overheatFactor or 0, 0, 1) * 0.8
    pistonRingOilConsumptionRate = pistonRingOilLossPerSecond.fresh * rpmOilLossFactor * heatOilLossFactor *
                                       oilLevelMileageMultiplier * oilCapacityFactor
  end

  local hardFailureRate = calculateEngineHardFailureRate(
    heatFactor, integritySeverity, torqueHoldCoef, catastrophicOilStarvation,
    lubricationThermalSeverity, loadFactor, rpmFactor, severeOilStarvation, oilStarvationSeverity,
    oilConditionSeverity
  )
  local oilConditionInterval = maintenanceIntervals.oilCondition.fresh * classConditionIntervalMultiplier * dieselIntervalMultiplier
  local oilLevelInterval = maintenanceIntervals.oilLevel.fresh
  local ignitionInterval = maintenanceIntervals.ignitionService.fresh
  local oilConditionEffectiveMultiplier = driveMultipliers.normalized.oilCondition * oilTemperatureMultiplier *
                                            lowOilConditionMultiplier * (1 + torqueCapacityStress * 4) * dieselLoadMultiplier
  local extremeOutputGate = getExtremeOutputGate(env)
  local extremePowerMultiplier = getExtremePowerMultiplier(env)
  local oilLevelEffectiveMultiplier = (driveMultipliers.normalized.oilLevel * oilLevelMileageMultiplier *
                                          (1 + torqueCapacityStress * 1.5) * dieselOilLevelMultiplier +
                                          extremeOutputGate * max(extremePowerMultiplier - 1, 0)) * oilCapacityFactor
  local averageDriveMultiplier = (oilConditionEffectiveMultiplier + oilLevelEffectiveMultiplier +
                                     driveMultipliers.normalized.ignitionService) / 3
  local oilConditionStress = driveMultipliers.normalized.oilCondition * oilTemperatureMultiplier *
                               (1 + torqueCapacityStress * 4) * dieselLoadMultiplier
  local oilLevelStress = driveMultipliers.normalized.oilLevel * (1 + torqueCapacityStress * 1.5) * dieselOilLevelMultiplier +
                           extremeOutputGate * max(extremePowerMultiplier - 1, 0)
  local stressMultiplier = (oilConditionStress + oilLevelStress + driveMultipliers.normalized.ignitionService) / 3
  return {
    pistonRingOilConsumptionRate = pistonRingOilConsumptionRate,
    hardFailureRate = hardFailureRate,
    oilConditionInterval = oilConditionInterval,
    oilLevelInterval = oilLevelInterval,
    ignitionInterval = ignitionInterval,
    oilConditionEffectiveMultiplier = oilConditionEffectiveMultiplier,
    extremeOutputGate = extremeOutputGate,
    extremePowerMultiplier = extremePowerMultiplier,
    oilLevelEffectiveMultiplier = oilLevelEffectiveMultiplier,
    averageDriveMultiplier = averageDriveMultiplier,
    stressMultiplier = stressMultiplier,
  }
end

local function forecastEngineServiceMiles(state, env, serviceRates, driveMultipliers)
  return {
      oilCondition = common.estimateMilesToTarget(state.maintenance.oilCondition or 1, serviceRates.oilConditionInterval,
        common.getPlanningMultiplier(env, 'oilCondition', serviceRates.oilConditionEffectiveMultiplier, driveMultipliers.normalized.oilCondition),
        serviceTargetValues.oilCondition),
      oilLevel = common.estimateMilesToTarget(state.maintenance.oilLevel or 1, serviceRates.oilLevelInterval,
        common.getPlanningMultiplier(env, 'oilLevel', serviceRates.oilLevelEffectiveMultiplier, driveMultipliers.normalized.oilLevel),
        serviceTargetValues.oilLevel),
      ignitionService = common.estimateMilesToTarget(state.maintenance.ignitionService or 1, serviceRates.ignitionInterval,
        common.getPlanningMultiplier(env, 'ignitionService', driveMultipliers.normalized.ignitionService,
          driveMultipliers.normalized.ignitionService),
        serviceTargetValues.ignitionService)
    }
end

-- Derived effects ---------------------------------------------------------------------------------

local function calculateEngineTorqueAndFriction(
  maintenancePenalty, lubrication, loadFactor, rpmFactor, limitStressFactor,
  maintenanceTorqueLimitLoss, lubricationTorqueLoss
)
  local integrityTorqueLoss = lubrication.integritySeverity * weightedSum(driveEffectFractions.integrityTorqueLoss.base,
    loadFactor * driveEffectFractions.integrityTorqueLoss.load, rpmFactor * driveEffectFractions.integrityTorqueLoss.rpm)
  local stressSensitiveTorqueLoss = common.clamp(
    weightedSum(lubrication.oilLevelDriveSeverity * driveEffectFractions.stressTorqueLoss.oilLevel,
      lubrication.oilConditionDriveSeverity * driveEffectFractions.stressTorqueLoss.oilCondition,
      lubrication.integritySeverity * driveEffectFractions.stressTorqueLoss.integrity) *
        weightedSum(driveEffectFractions.stressParticipation.base, loadFactor * driveEffectFractions.stressParticipation.load,
          rpmFactor * driveEffectFractions.stressParticipation.rpm,
          common.clamp(limitStressFactor, 0, 1.4) * driveEffectFractions.stressParticipation.limitStress),
    0,
    0.68
  )
  local torqueHoldCoef = common.clamp(
    weightedSum(1, -maintenanceTorqueLimitLoss * driveEffectFractions.maintenanceTorqueLoss,
        -lubricationTorqueLoss, -integrityTorqueLoss, -stressSensitiveTorqueLoss),
    lubrication.catastrophicOilStarvation and 0.02 or (lubrication.severeOilStarvation and 0.05 or 0.08),
    1
  )
  local powerHoldCoef = common.clamp(
    weightedSum(1, -lubrication.oilLevelDriveSeverity * driveEffectFractions.powerLoss.oilLevel,
        -lubrication.oilConditionDriveSeverity * driveEffectFractions.powerLoss.oilCondition,
        -lubrication.integritySeverity * driveEffectFractions.powerLoss.integrity,
        -lubrication.lubricationDriveSeverity * driveEffectFractions.powerLoss.lubrication,
        -lubrication.lubricationThermalSeverity * driveEffectFractions.powerLoss.thermal),
    lubrication.catastrophicOilStarvation and 0.35 or 0.72,
    1
  )
  local frictionCoef = weightedSum(
    1,
    (1 - torqueHoldCoef) * driveEffectFractions.friction.torqueLoss,
    maintenancePenalty * driveEffectFractions.friction.maintenance,
    lubrication.oilStarvationSeverity * driveEffectFractions.friction.oilStarvation,
    lubrication.oilConditionSeverity * driveEffectFractions.friction.oilCondition,
    lubrication.integritySeverity * driveEffectFractions.friction.integrity,
    lubrication.lubricationThermalSeverity * driveEffectFractions.friction.thermal,
    lubrication.ignitionSeverity * driveEffectFractions.friction.ignition
  )
  local dynamicFrictionCoef = weightedSum(
    1,
    (1 - powerHoldCoef) * driveEffectFractions.dynamicFriction.powerLoss,
    maintenancePenalty * driveEffectFractions.dynamicFriction.maintenance,
    lubrication.oilStarvationSeverity * driveEffectFractions.dynamicFriction.oilStarvation,
    lubrication.oilConditionSeverity * driveEffectFractions.dynamicFriction.oilCondition,
    lubrication.integritySeverity * driveEffectFractions.dynamicFriction.integrity,
    lubrication.lubricationThermalSeverity * driveEffectFractions.dynamicFriction.thermal,
    lubrication.ignitionSeverity * driveEffectFractions.dynamicFriction.ignition
  )
  return torqueHoldCoef, powerHoldCoef, frictionCoef, dynamicFrictionCoef
end

local function calculateEngineRoughnessAndSymptoms(
  maintenancePenalty, lubrication, wear, avgMiles, neglectSeverity, torqueHoldCoef
)
  local roughnessCoef = weightedSum(
    1,
    (1 - torqueHoldCoef) * driveEffectFractions.roughness.torqueLoss,
    maintenancePenalty * driveEffectFractions.roughness.maintenance,
    wear.normalizedWear * driveEffectFractions.roughness.wear,
    lubrication.oilStarvationSeverity * driveEffectFractions.roughness.oilStarvation,
    lubrication.oilConditionSeverity * driveEffectFractions.roughness.oilCondition,
    lubrication.integritySeverity * driveEffectFractions.roughness.integrity,
    lubrication.lubricationThermalSeverity * driveEffectFractions.roughness.thermal,
    lubrication.ignitionSeverity * driveEffectFractions.roughness.ignition
  )
  local ignitionErrorChance = common.clamp(
    weightedSum(max(avgMiles - ignitionWearStartMiles, 0) / ignitionWearWindowMiles * driveEffectFractions.ignitionChance.age,
        common.clamp(maintenancePenalty - 0.5, 0, 1) * driveEffectFractions.ignitionChance.maintenance,
        lubrication.oilStarvationSeverity * driveEffectFractions.ignitionChance.oilStarvation,
        lubrication.oilConditionSeverity * driveEffectFractions.ignitionChance.oilCondition,
        lubrication.integritySeverity * driveEffectFractions.ignitionChance.integrity,
        lubrication.lubricationThermalSeverity * driveEffectFractions.ignitionChance.thermal,
        lubrication.ignitionSeverity * driveEffectFractions.ignitionChance.ignition),
    0,
    0.085
  )
  local symptomBaseRate = weightedSum(
    neglectSeverity * (driveEffectFractions.symptomBaseRate.neglect + wear.normalizedWear * driveEffectFractions.symptomBaseRate.wear),
    lubrication.oilStarvationSeverity * driveEffectFractions.symptomBaseRate.oilStarvation,
    lubrication.integritySeverity * driveEffectFractions.symptomBaseRate.integrity,
    lubrication.lubricationThermalSeverity * driveEffectFractions.symptomBaseRate.thermal,
    lubrication.ignitionSeverity * driveEffectFractions.symptomBaseRate.ignition)
  return roughnessCoef, ignitionErrorChance, symptomBaseRate
end

local function calculateEngineDriveEffects(maintenancePenalty, lubrication, loadFactor, rpmFactor,
    limitStressFactor, wear, avgMiles, neglectSeverity, heatFactor)
  local maintenanceTorqueLimitLoss = common.sampleCurve(maintenancePenalty, {
    {0, 0},
    {0.35, 0},
    {0.6, 0.02},
    {0.8, 0.06},
    {1.0, 0.12}
  })
  local ageWearSeverity = common.sampleCurve(avgMiles, {
    {0, 0},
    {18600, 0},
    {100000, 0.20},
    {200000, 0.55},
    {300000, 1.0},
    {400000, 1.25}
  })
  local ageWearFrictionCoef = 1 + ageWearSeverity * driveEffectFractions.ageWear.friction
  local ageWearDynamicFrictionCoef = 1 + ageWearSeverity * driveEffectFractions.ageWear.dynamicFriction
  local ageWearIdleErrorCoef = 1 + ageWearSeverity * driveEffectFractions.ageWear.idleError
  local lubricationTorqueLoss = weightedSum(
    lubrication.oilLevelDriveSeverity * driveEffectFractions.lubricationTorqueLoss.oilLevel,
    lubrication.oilConditionDriveSeverity * driveEffectFractions.lubricationTorqueLoss.oilCondition,
    lubrication.lubricationDriveSeverity * driveEffectFractions.lubricationTorqueLoss.lubrication,
    lubrication.lubricationThermalSeverity * driveEffectFractions.lubricationTorqueLoss.thermal
  )
  local torqueHoldCoef, powerHoldCoef, frictionCoef, dynamicFrictionCoef = calculateEngineTorqueAndFriction(
    maintenancePenalty, lubrication, loadFactor, rpmFactor, limitStressFactor,
    maintenanceTorqueLimitLoss, lubricationTorqueLoss
  )
  local roughnessCoef, ignitionErrorChance, symptomBaseRate = calculateEngineRoughnessAndSymptoms(
    maintenancePenalty, lubrication, wear, avgMiles, neglectSeverity, torqueHoldCoef
  )
  local symptomRate = symptomBaseRate *
                          weightedSum(driveEffectFractions.symptomRate.base, loadFactor * driveEffectFractions.symptomRate.load,
                            heatFactor * driveEffectFractions.symptomRate.heat, rpmFactor * driveEffectFractions.symptomRate.rpm,
                            common.clamp(limitStressFactor, 0, 1.4) * driveEffectFractions.symptomRate.limitStress)

  return {
    torqueHoldCoef = torqueHoldCoef,
    powerHoldCoef = powerHoldCoef,
    frictionCoef = frictionCoef,
    dynamicFrictionCoef = dynamicFrictionCoef,
    roughnessCoef = roughnessCoef,
    ignitionErrorChance = ignitionErrorChance,
    symptomRate = symptomRate,
    ageWearSeverity = ageWearSeverity,
    ageWearFrictionCoef = ageWearFrictionCoef,
    ageWearDynamicFrictionCoef = ageWearDynamicFrictionCoef,
    ageWearIdleErrorCoef = ageWearIdleErrorCoef,
  }
end

local function writeEngineCondition(
  result, wear, maintenanceAvg, maintenancePenalty, neglectSeverity, oilLevelMileageMultiplier,
  oilCondition, oilLevel, ignitionService, lowOilConditionMultiplier, integrityValue, oilTemp,
  oilHeatFactor, oilOverheatFactor, lubrication, serviceRates
)
  result.stressMultiplier = serviceRates.stressMultiplier
  result.ageMultiplier = oilLevelMileageMultiplier
  result.neglectMultiplier = lowOilConditionMultiplier
  result.wear = wear
  result.maintenanceAvg = maintenanceAvg
  result.maintenancePenalty = maintenancePenalty
  result.neglectSeverity = neglectSeverity
  result.oilCondition = oilCondition
  result.oilLevel = oilLevel
  result.ignitionService = ignitionService
  result.integrityValue = integrityValue
  result.integritySeverity = lubrication.integritySeverity
  result.oilTemp = oilTemp
  result.oilHeatFactor = oilHeatFactor
  result.oilOverheatFactor = oilOverheatFactor
  result.oilLevelDriveSeverity = lubrication.oilLevelDriveSeverity
  result.oilConditionDriveSeverity = lubrication.oilConditionDriveSeverity
  result.ignitionSeverity = lubrication.ignitionSeverity
  result.lubricationDriveSeverity = lubrication.lubricationDriveSeverity
  result.lubricationThermalSeverity = lubrication.lubricationThermalSeverity
  result.lubricationCollapseSeverity = lubrication.lubricationCollapseSeverity
  result.criticalOilFailureSeverity = lubrication.criticalOilFailureSeverity
  result.cylinderWallThreatSeverity = lubrication.cylinderWallThreatSeverity
  result.oilStarvationSeverity = lubrication.oilStarvationSeverity
  result.oilConditionSeverity = lubrication.oilConditionSeverity
  result.severeOilStarvation = lubrication.severeOilStarvation
  result.catastrophicOilStarvation = lubrication.catastrophicOilStarvation
  result.dryOilLockup = lubrication.dryOilLockup
end

local function writeEngineDriveEffects(
  result, env, profile, limitStressFactor, torqueCapacityStress, torqueCapacityRatio,
  oilTemperatureMultiplier, oilCapacityFactor, pistonRingsDamaged, lowOilConditionMultiplier, effects,
  serviceRates
)
  result.torqueHoldCoef = effects.torqueHoldCoef
  result.powerHoldCoef = effects.powerHoldCoef
  result.frictionCoef = effects.frictionCoef
  result.dynamicFrictionCoef = effects.dynamicFrictionCoef
  result.roughnessCoef = effects.roughnessCoef
  result.ignitionErrorChance = effects.ignitionErrorChance
  result.symptomRate = effects.symptomRate
  result.hardFailureRate = serviceRates.hardFailureRate
  result.pistonRingsDamaged = pistonRingsDamaged
  result.pistonRingOilConsumptionRate = serviceRates.pistonRingOilConsumptionRate
  result.profile = common.deepCopy(profile)
  result.mileageAgeIndex = common.getMileageAgeIndex(env.avgMiles)
  result.oilCapacityFactor = oilCapacityFactor
  result.oilTemperatureMultiplier = oilTemperatureMultiplier
  result.lowOilConditionMultiplier = lowOilConditionMultiplier
  result.torqueCapacityStress = torqueCapacityStress
  result.torqueCapacityRatio = torqueCapacityRatio
  result.maxTorqueRating = tonumber(env.maxTorqueRating) or -1
  result.combustionTorque = tonumber(env.combustionTorque) or 0
  result.extremeOutputGate = serviceRates.extremeOutputGate
  result.extremePowerMultiplier = serviceRates.extremePowerMultiplier
  result.ageWearSeverity = effects.ageWearSeverity
  result.ageWearFrictionCoef = effects.ageWearFrictionCoef
  result.ageWearDynamicFrictionCoef = effects.ageWearDynamicFrictionCoef
  result.ageWearIdleErrorCoef = effects.ageWearIdleErrorCoef
  result.limitStressFactor = limitStressFactor
end

local function writeEngineServiceForecast(
  result, state, env, effectiveDrainMultipliers, driveMultipliers, oilLevelMileageMultiplier,
  serviceRates
)
  result.driveMultiplier = serviceRates.averageDriveMultiplier
  result.driveMultipliers = common.deepCopy(driveMultipliers.normalized)
  result.rawDriveMultipliers = common.deepCopy(driveMultipliers.raw)
  result.oilConditionStressMultiplier = effectiveDrainMultipliers.oilConditionStressMultiplier
  result.oilLevelMileageMultiplier = oilLevelMileageMultiplier
  result.serviceTargets = common.deepCopy(serviceTargetValues)
  result.effectiveIntervals = {
    oilCondition = serviceRates.oilConditionInterval / max(serviceRates.oilConditionEffectiveMultiplier, 0.0001),
    oilLevel = serviceRates.oilLevelInterval / max(serviceRates.oilLevelEffectiveMultiplier, 0.0001),
    ignitionService = serviceRates.ignitionInterval / max(driveMultipliers.normalized.ignitionService, 0.0001)
  }
  result.effectiveDriveMultipliers = {
    oilCondition = serviceRates.oilConditionEffectiveMultiplier,
    oilLevel = serviceRates.oilLevelEffectiveMultiplier,
    ignitionService = driveMultipliers.normalized.ignitionService
  }
  result.serviceDueMilesRemaining = forecastEngineServiceMiles(state, env, serviceRates, driveMultipliers)
end

local function readEngineServiceInputs(state, env, loadFactor, profile)
  local torqueCapacityStress, torqueCapacityRatio = common.getTorqueCapacityStress(env.combustionTorque, env.maxTorqueRating)
  local oilTemperatureMultiplier = common.getOilTemperatureMultiplier(env.oilTemp)
  local oilLevelMileageMultiplier = common.getLevelMileageMultiplier('oilLevel', env.avgMiles)
  local oilCapacityFactor = common.getCapacityFactor('oil', profile)
  local classConditionIntervalMultiplier = common.getClassConditionIntervalMultiplier(profile)
  local dieselIntervalMultiplier = profile.fuelType == 'diesel' and 1.25 or 1
  local dieselLoadMultiplier = profile.fuelType == 'diesel' and (1 + loadFactor * 0.25) or 1
  local dieselOilLevelMultiplier = profile.fuelType == 'diesel' and 0.85 or 1
  local pistonRingsDamaged = env.pistonRingsDamaged == true
  local pistonRingOilConsumptionRate = 0
  local oilCondition = common.clamp(state.maintenance.oilCondition or 1, 0, 1)
  local oilLevel = common.clamp(state.maintenance.oilLevel or 1, 0, 1)
  local ignitionService = common.clamp(state.maintenance.ignitionService or 1, 0, 1)
  local lowOilConditionMultiplier = common.getLowFluidConditionMultiplier(oilLevel)
  local integrityValue = common.clamp(env.integrityValue or 1, 0, 1)
  local oilTemp = max(tonumber(env.oilTemp) or 0, 0)
  local oilHeatFactor = common.clamp(env.oilHeatFactor or 0, 0, 1)
  local oilOverheatFactor = common.clamp(env.oilOverheatFactor or 0, 0, 1)
  return torqueCapacityStress, torqueCapacityRatio, oilTemperatureMultiplier, oilLevelMileageMultiplier, oilCapacityFactor, classConditionIntervalMultiplier, dieselIntervalMultiplier, dieselLoadMultiplier, dieselOilLevelMultiplier, pistonRingsDamaged, pistonRingOilConsumptionRate, oilCondition, oilLevel, ignitionService, lowOilConditionMultiplier, integrityValue, oilTemp, oilHeatFactor, oilOverheatFactor
end

local function buildDerived(state, env)
  local wear = common.getWearProfile(env.avgMiles)
  local maintenanceAvg = common.getAverageMaintenance(state.maintenance)
  local maintenancePenalty = 1 - maintenanceAvg
  local neglectSeverity = common.getMaintenanceSeverity(maintenanceAvg)
  local loadFactor = common.clamp(env.loadFactor or 0, 0, 1)
  local rpmFactor = common.clamp(env.rpmFactor or 0, 0, 1)
  local heatFactor = common.clamp(env.heatFactor or 0, 0, 1)
  local profile = type(env.profile) == 'table' and env.profile or {}
  local effectiveDrainMultipliers = getEffectiveDrainMultipliers(env, env.avgMiles)
  local driveMultipliers = {
    raw = effectiveDrainMultipliers.raw,
    normalized = effectiveDrainMultipliers.normalized
  }
  local limitStressFactor = getLimitStressFactor(env, limitStressFractions)
  local torqueCapacityStress, torqueCapacityRatio, oilTemperatureMultiplier,
    oilLevelMileageMultiplier, oilCapacityFactor, classConditionIntervalMultiplier,
    dieselIntervalMultiplier, dieselLoadMultiplier, dieselOilLevelMultiplier, pistonRingsDamaged,
    pistonRingOilConsumptionRate, oilCondition, oilLevel, ignitionService, lowOilConditionMultiplier,
    integrityValue, oilTemp, oilHeatFactor, oilOverheatFactor = readEngineServiceInputs(
    state, env, loadFactor, profile
  )
  local lubrication = calculateEngineLubricationSeverity({
    oilLevel = oilLevel, oilCondition = oilCondition,
    ignitionService = ignitionService, integrityValue = integrityValue,
    oilHeatFactor = oilHeatFactor, oilOverheatFactor = oilOverheatFactor,
    loadFactor = loadFactor, rpmFactor = rpmFactor,
    limitStressFactor = limitStressFactor,
  })

  local effects = calculateEngineDriveEffects(maintenancePenalty, lubrication, loadFactor, rpmFactor,
    limitStressFactor, wear, env.avgMiles, neglectSeverity, heatFactor)

  local serviceRates = calculateEngineFailureAndServiceRates(
    env, pistonRingsDamaged, pistonRingOilConsumptionRate, heatFactor, oilLevelMileageMultiplier,
    oilCapacityFactor, lubrication.integritySeverity, effects.torqueHoldCoef,
    lubrication.catastrophicOilStarvation, lubrication.lubricationThermalSeverity, loadFactor,
    rpmFactor, lubrication.severeOilStarvation, lubrication.oilStarvationSeverity,
    lubrication.oilConditionSeverity, classConditionIntervalMultiplier, dieselIntervalMultiplier,
    driveMultipliers, oilTemperatureMultiplier, lowOilConditionMultiplier, torqueCapacityStress,
    dieselLoadMultiplier, dieselOilLevelMultiplier
  )

  local result = {}
  writeEngineCondition(
    result, wear, maintenanceAvg, maintenancePenalty, neglectSeverity, oilLevelMileageMultiplier,
    oilCondition, oilLevel, ignitionService, lowOilConditionMultiplier, integrityValue, oilTemp,
    oilHeatFactor, oilOverheatFactor, lubrication, serviceRates
  )
  writeEngineDriveEffects(
    result, env, profile, limitStressFactor, torqueCapacityStress, torqueCapacityRatio,
    oilTemperatureMultiplier, oilCapacityFactor, pistonRingsDamaged, lowOilConditionMultiplier,
    effects, serviceRates
  )
  writeEngineServiceForecast(
    result, state, env, effectiveDrainMultipliers, driveMultipliers, oilLevelMileageMultiplier,
    serviceRates
  )
  return result
end

-- Symptoms and runtime progression ----------------------------------------------------------------

local function getActiveSymptom(runtime)
  if runtime and runtime.activeSymptom and (runtime.symptomTimer or 0) > 0 then
    return runtime.activeSymptom
  end
end

local function selectSymptom(derived, env)
  local loadFactor = common.clamp(env.loadFactor or 0, 0, 1)
  local heatFactor = common.clamp(env.heatFactor or 0, 0, 1)
  -- Output-loss symptoms need driving context because rough idle can report substantial load.
  local hasDrivingDemand = common.clamp(env.throttleFactor or 0, 0, 1) > 0.05 or
                               abs(tonumber(env.vehicleSpeed) or 0) >= 1
  local maintenancePenalty = derived.maintenancePenalty
  local tickingWeight = max(
    (derived.oilStarvationSeverity or 0) * 2.4 + (derived.oilConditionDriveSeverity or 0) * 1.1 +
        (derived.lubricationDriveSeverity or 0) * 0.85 + (derived.integritySeverity or 0) * 0.55 - 0.18,
    0
  )
  local stallWeight = max((maintenancePenalty - 0.18) * 6 + (1 - loadFactor) * 0.4 + max(heatFactor - 0.45, 0), 0)
  return common.chooseWeighted({
    {value = 'roughRunning', weight = 1 + maintenancePenalty + (derived.oilStarvationSeverity or 0) * 1.4},
    {value = 'ticking', weight = tickingWeight},
    {value = 'roughIdle', weight = 1.3 + maintenancePenalty * 1.4 + (1 - loadFactor)},
    {value = 'torqueDip', weight = hasDrivingDemand and (1 + loadFactor * 2.4) or 0},
    {value = 'powerFade', weight = hasDrivingDemand and (1 + loadFactor * 1.6 + heatFactor * 1.6) or 0},
    {value = 'stall', weight = stallWeight}
  })
end

local function accumulateEngineLubricationDamage(runtime, state, derived, env, dt)
  if env.engineRunningSeconds and env.engineRunningSeconds > 0 and
      ((derived.lubricationDriveSeverity or 0) >= 0.32 or (derived.lubricationCollapseSeverity or 0) >= 0.38 or (derived.oilStarvationSeverity or 0) >= 0.2 or
          (derived.oilConditionSeverity or 0) >= 0.24) then
    local lubricationLoad = 0.008 + common.clamp(env.loadFactor or 0, 0, 1) * 0.032 + common.clamp(env.rpmFactor or 0, 0, 1) * 0.026 +
                                common.clamp(derived.lubricationDriveSeverity or 0, 0, 1.8) * 0.028 +
                                common.clamp(derived.oilHeatFactor or 0, 0, 1) * 0.028 +
                                common.clamp(derived.oilOverheatFactor or 0, 0, 1) * 0.045
    local oilCollapseLoad = common.clamp(derived.criticalOilFailureSeverity or 0, 0, 2.25) * 0.030 +
                                common.clamp(derived.cylinderWallThreatSeverity or 0, 0, 2.8) * 0.028 +
                                ((derived.severeOilStarvation or false) and 0.030 or 0) +
                                ((derived.catastrophicOilStarvation or false) and 0.090 or 0) +
                                ((derived.dryOilLockup or false) and 0.180 or 0)
    local minimumStage = common.clamp((derived.lubricationCollapseSeverity or 0) * 0.06 +
                                          max((derived.lubricationDriveSeverity or 0) - 0.5, 0) * 0.10 +
                                          common.clamp(derived.criticalOilFailureSeverity or 0, 0, 2.25) * 0.10 +
                                          common.clamp(derived.cylinderWallThreatSeverity or 0, 0, 2.8) * 0.16,
      0,
      1.25
    )
    runtime.lubricationDamageStage = min(
      1.8,
      max(runtime.lubricationDamageStage or 0, minimumStage) + dt * (lubricationLoad + oilCollapseLoad)
    )

    if not getActiveSymptom(runtime) and
        ((derived.oilStarvationSeverity or 0) >= 0.35 or (derived.lubricationDriveSeverity or 0) >= 0.55) then
      runtime.activeSymptom = 'ticking'
      runtime.symptomTimer = max(runtime.symptomTimer or 0, common.pickDuration(2.5, 5.0))
      runtime.cooldownTimer = max(runtime.cooldownTimer or 0, runtime.symptomTimer + common.pickDuration(1.5, 4.0))
      state.lastFailureTime = os.time()
      state.lastFailureType = runtime.activeSymptom
    end
  end
end

local function accumulateEngineCriticalOilExposure(runtime, state, derived, env, dt)
  local criticalLoad = 0.18 + common.clamp(env.loadFactor or 0, 0, 1) * 0.48 + common.clamp(env.rpmFactor or 0, 0, 1) * 0.44 +
                           common.clamp(env.heatFactor or 0, 0, 1) * 0.18 +
                           common.clamp(derived.oilHeatFactor or 0, 0, 1) * 0.20 +
                           common.clamp(derived.oilOverheatFactor or 0, 0, 1) * 0.34
  runtime.criticalOilSeconds = runtime.criticalOilSeconds + dt * criticalLoad

  if runtime.criticalOilSeconds >= 1.25 then
    runtime.activeSymptom = 'stall'
    runtime.symptomTimer = max(runtime.symptomTimer or 0, 1.2)
    runtime.cooldownTimer = max(runtime.cooldownTimer or 0, 3.5)
    state.lastFailureTime = os.time()
    state.lastFailureType = runtime.activeSymptom
  end

  local collapseSeverity = common.clamp(
    (derived.integritySeverity or 0) * 0.9 + (1 - (derived.torqueHoldCoef or 1)) * 0.45 +
        (derived.lubricationThermalSeverity or 0) * 0.5,
    0,
    1.8
  )
  local loadThreat = common.clamp(env.loadFactor or 0, 0, 1) * 0.65 + common.clamp(env.rpmFactor or 0, 0, 1) * 0.5
  local catastrophicThreshold = derived.catastrophicOilStarvation and
                                    max(1.1, 2.8 - collapseSeverity * 0.65 - loadThreat * 0.35) or
                                    max(3.2, 7.2 - collapseSeverity * 1.2 - loadThreat * 0.9)
  return catastrophicThreshold
end

local function advanceEngineSymptomTimers(runtime, dt)
  runtime.cooldownTimer = max((runtime.cooldownTimer or 0) - dt, 0)
  runtime.symptomTimer = max((runtime.symptomTimer or 0) - dt, 0)
  runtime.criticalOilSeconds = max((runtime.criticalOilSeconds or 0) - dt * 0.2, 0)
  runtime.dryOilSeconds = max((runtime.dryOilSeconds or 0) - dt * 0.1, 0)
  runtime.lubricationDamageStage = max((runtime.lubricationDamageStage or 0) - dt * 0.04, 0)
  runtime.forceHardFailure = false
  runtime.forceHardFailureTarget = nil
  runtime.forceHardFailurePersistent = false
  runtime.forceHardFailureReason = nil

  if runtime.symptomTimer <= 0 then
    runtime.activeSymptom = nil
    runtime.stallApplied = false
  end
end

local function stepRuntime(runtime, state, derived, env, dt)
  advanceEngineSymptomTimers(runtime, dt)

  if env.engineRunningSeconds and env.engineRunningSeconds > 0 and derived.dryOilLockup then
    local dryOilLoad = 1.2 + common.clamp(env.loadFactor or 0, 0, 1) * 1.4 + common.clamp(env.rpmFactor or 0, 0, 1) * 1.6
    runtime.dryOilSeconds = runtime.dryOilSeconds + dt * dryOilLoad
    runtime.activeSymptom = 'stall'
    runtime.symptomTimer = max(runtime.symptomTimer or 0, 1.6)
    runtime.cooldownTimer = max(runtime.cooldownTimer or 0, 4.0)

    if runtime.dryOilSeconds >= 0.35 then
      runtime.forceHardFailure = true
      runtime.forceHardFailureTarget = 'engine'
      runtime.forceHardFailurePersistent = false
      runtime.forceHardFailureReason = 'oil_lockup'
      state.lastFailureTime = os.time()
      state.lastFailureType = 'engine_lockup'
      return 'stall'
    end
  end

  accumulateEngineLubricationDamage(runtime, state, derived, env, dt)

  if env.engineRunningSeconds and env.engineRunningSeconds > 0 and
      (derived.severeOilStarvation or derived.catastrophicOilStarvation or
          ((derived.lubricationThermalSeverity or 0) >= 0.95 and
              ((derived.oilStarvationSeverity or 0) >= 0.28 or (derived.oilConditionSeverity or 0) >= 0.35))) then
    local catastrophicThreshold = accumulateEngineCriticalOilExposure(runtime, state, derived, env, dt)
    if runtime.criticalOilSeconds >= catastrophicThreshold then
      runtime.forceHardFailure = true
      runtime.forceHardFailureTarget = 'engine'
      runtime.forceHardFailurePersistent = false
      runtime.forceHardFailureReason = derived.catastrophicOilStarvation and 'oil_starvation' or 'maintenance_failure'
      state.lastFailureTime = os.time()
      state.lastFailureType = 'engine_break'
      return 'stall'
    end
  end

  if runtime.cooldownTimer <= 0 and not getActiveSymptom(runtime) and common.rollChance(derived.symptomRate, dt) then
    runtime.activeSymptom = selectSymptom(derived, env)
    runtime.symptomTimer = common.pickDuration(symptomDurations[runtime.activeSymptom][1], symptomDurations[runtime.activeSymptom][2])
    runtime.cooldownTimer = runtime.symptomTimer + common.pickDuration(8, 18)
    state.lastFailureTime = os.time()
    state.lastFailureType = runtime.activeSymptom
  end

  return getActiveSymptom(runtime)
end

-- Audio -------------------------------------------------------------------------------------------

local function updateAudio(context, runtime, derived, dt)
  if not runtime or not derived then
    return
  end

  local symptom = getActiveSymptom(runtime)
  local knockSeverity = max(derived.oilStarvationSeverity or 0, (derived.oilConditionSeverity or 0) * 0.7)
  local shouldTick = symptom == 'roughRunning' or symptom == 'ticking' or derived.severeOilStarvation or
                         derived.catastrophicOilStarvation or knockSeverity >= 0.18
  if not shouldTick or type(context) ~= "table" or type(sounds) ~= "table" or type(sounds.playSoundOnceFollowNode) ~= "function" then
    runtime.knockSoundTick = 0
    return
  end

  local entry = context.devices and context.devices[1] or nil
  local engine = entry and entry.device or nil
  if type(engine) ~= "table" then
    runtime.knockSoundTick = 0
    return
  end

  local soundNode = engine.engineNodeID or (type(engine.engineBlockNodes) == "table" and engine.engineBlockNodes[1]) or
                        (type(nodes) == "table" and type(nodes.engine) == "table" and nodes.engine[1]) or nil
  if not soundNode then
    runtime.knockSoundTick = 0
    return
  end

  local absEngineAV = abs(engine.outputAV1 or engine.inputAV or engine.outputAV2 or 0)
  if absEngineAV < 15 then
    runtime.knockSoundTick = 0
    return
  end

  local severity = common.clamp(knockSeverity + ((symptom == 'roughRunning' or symptom == 'ticking') and 0.22 or 0), 0, 1.6)
  local tickRate = 0.2 + absEngineAV * 0.008333 * (0.5 + severity)
  runtime.knockSoundTick = (runtime.knockSoundTick or 0) + dt * tickRate
  if runtime.knockSoundTick > 1 then
    runtime.knockSoundTick = runtime.knockSoundTick % 1
    local volume = common.clamp(0.3 + severity * 0.5, 0.25, 1)
    sounds.playSoundOnceFollowNode("event:>Vehicle>Failures>failure_engine_knock", soundNode, volume)
  end
end

-- Device application ------------------------------------------------------------------------------

local function applyEngineThermalsAndStall(
  runtime, derived, symptom, symptomRoughnessCoef, entry, engine, base, lubricationDamageStage
)
  entry.engineAppliedMaxTorqueLimit = engine.maxTorqueLimit
  engine.idleAVReadErrorRangeHalf = (base.idleAVReadErrorRangeHalf or engine.idleAVReadErrorRangeHalf or 0) *
                                        derived.roughnessCoef * symptomRoughnessCoef
  engine.idleAVReadErrorRange = (base.idleAVReadErrorRange or engine.idleAVReadErrorRange or 0) *
                                    derived.roughnessCoef * symptomRoughnessCoef

  if engine.thermals and engine.thermals.oilTemperature ~= nil then
    local oilThermalSeverity = common.clamp(
      (derived.lubricationThermalSeverity or 0) * 0.55 + lubricationDamageStage * 0.35 + (derived.oilStarvationSeverity or 0) * 0.32 +
          (derived.oilConditionSeverity or 0) * 0.22 + common.clamp(derived.loadFactor or 0, 0, 1) * 0.08 +
          common.clamp(derived.rpmFactor or 0, 0, 1) * 0.06,
      0,
      1.45
    )
    local oilFailureHeatSeverity = common.clamp(
      max(
        oilThermalSeverity,
        common.clamp(derived.criticalOilFailureSeverity or 0, 0, 2.25) * 0.72 +
            common.clamp(derived.cylinderWallThreatSeverity or 0, 0, 2.8) * 0.26
      ),
      0,
      2.4
    )
    local thermalInterventionSeverity = common.clamp(common.linearScale(oilFailureHeatSeverity, 0.28, 1.45, 0, 1), 0, 1)
    if thermalInterventionSeverity > 0 then
      local currentOilTemp = tonumber(engine.thermals.oilTemperature) or 0
      local targetOilTemp = common.lerp(112, 192, thermalInterventionSeverity) +
                                common.clamp(derived.loadFactor or 0, 0, 1) * 3 +
                                common.clamp(derived.rpmFactor or 0, 0, 1) * 4 +
                                common.clamp(derived.oilStarvationSeverity or 0, 0, 1.35) * 10 +
                                common.clamp(derived.oilConditionSeverity or 0, 0, 0.75) * 6 +
                                common.clamp(derived.cylinderWallThreatSeverity or 0, 0, 2.8) * 16 +
                                ((derived.catastrophicOilStarvation or false) and 14 or 0) +
                                ((derived.dryOilLockup or false) and 24 or 0)
      if targetOilTemp > currentOilTemp then
        local tempRiseRate = (derived.catastrophicOilStarvation or derived.dryOilLockup) and 0.08 or
                                 (((derived.severeOilStarvation or false) or (derived.criticalOilFailureSeverity or 0) >= 1.2) and 0.045 or 0.02)
        engine.thermals.oilTemperature = common.lerp(currentOilTemp, targetOilTemp, tempRiseRate)
      end
    end

  end

  if (symptom == 'stall' or lubricationDamageStage >= 1.45) and not runtime.stallApplied then
    engine.isStalled = true
    engine.stallTimer = 0
    runtime.stallApplied = true
  end
end

local function calculateEngineTorqueCeiling(
  derived, symptomTorqueCoef, symptomFrictionCoef, symptomIgnitionBonus, engine, base,
  directDriveSeverity
)
  resetEngineState(engine, base, derived)

  if base.friction ~= nil then
    engine.friction = base.friction * derived.frictionCoef * symptomFrictionCoef
  end
  if base.dynamicFriction ~= nil then
    engine.dynamicFriction = base.dynamicFriction * derived.dynamicFrictionCoef * symptomFrictionCoef
  end
  if engine.fastIgnitionErrorChance ~= nil then
    setIgnitionChance(engine, "fastIgnitionErrorChance", max(getVanillaIgnitionChance(engine, "fastIgnitionErrorChance"),
      common.clamp(derived.ignitionErrorChance + symptomIgnitionBonus, 0, 0.12)))
  end
  if engine.slowIgnitionErrorChance ~= nil then
    setIgnitionChance(engine, "slowIgnitionErrorChance", max(getVanillaIgnitionChance(engine, "slowIgnitionErrorChance"),
      common.clamp(derived.ignitionErrorChance + symptomIgnitionBonus * 1.15, 0, 0.12)))
  end

  local baseMaxTorque = base.maxTorque or engine.maxTorque or 0
  local baseMaxPowerRaw = base.maxPower or engine.maxPower or 0
  local baseMaxPowerWatts = common.getBeamPowerWatts(baseMaxPowerRaw)
  local engineAV = max(abs(engine.outputAV1 or engine.inputAV or engine.outputAV2 or 0), 1)
  local redlineAV = max(base.maxAV or engine.maxAV or 0, 1)
  local rpmCapacity = engineAV / redlineAV
  local liveTorqueHoldCoef = getLiveTorqueHoldCoef(derived.torqueHoldCoef, derived.loadFactor, rpmCapacity)
  local lubricationTorqueCapCoef = common.sampleCurve(directDriveSeverity, {
    {0.0, 1.0},
    {0.18, 0.97},
    {0.35, 0.89},
    {0.55, 0.75},
    {0.80, 0.56},
    {1.10, 0.36},
    {1.45, 0.16},
    {1.80, 0.03}
  })
  local torqueCap = baseMaxTorque * liveTorqueHoldCoef * symptomTorqueCoef * lubricationTorqueCapCoef
  return baseMaxTorque, baseMaxPowerWatts, engineAV, torqueCap
end

local function applyEngineMinimumTorqueLimit(
  derived, symptom, engine, base, lubricationDamageStage, directDriveSeverity, baseMaxTorque,
  appliedLimit
)
  if base.originalMaxTorqueLimit and base.originalMaxTorqueLimit < math.huge then
    appliedLimit = min(appliedLimit, base.originalMaxTorqueLimit)
  end

  local floorSeverity = common.clamp(
    max(derived.oilStarvationSeverity or 0, (derived.oilConditionSeverity or 0) * 0.7, (derived.integritySeverity or 0) * 0.9,
      lubricationDamageStage * 0.95, directDriveSeverity * 0.85),
    0,
    1.6
  )
  local minimumLimitCoef = common.sampleCurve(floorSeverity, {
    {0.0, symptom == 'stall' and 0.18 or 0.42},
    {0.30, symptom == 'stall' and 0.14 or 0.30},
    {0.65, symptom == 'stall' and 0.09 or 0.18},
    {1.00, symptom == 'stall' and 0.05 or 0.10},
    {1.35, symptom == 'stall' and 0.02 or 0.05},
    {1.60, symptom == 'stall' and 0.01 or 0.03}
  })
  local minimumLimit = baseMaxTorque * minimumLimitCoef
  engine.maxTorqueLimit = max(appliedLimit, minimumLimit)
end

local function applyEnginePowerCeiling(
  runtime, derived, symptom, symptomTorqueCoef, symptomPowerCoef, symptomFrictionCoef,
  symptomIgnitionBonus, entry
)
  local engine = entry.device
  local base = entry.base
  local lubricationDamageStage = common.clamp(runtime.lubricationDamageStage or 0, 0, 1.8)
  local directDriveSeverity = common.clamp(
    max(derived.lubricationDriveSeverity or 0, lubricationDamageStage * 0.92, (derived.ignitionSeverity or 0) * 0.35),
    0,
    1.8
  )
  local baseMaxTorque, baseMaxPowerWatts, engineAV, torqueCap = calculateEngineTorqueCeiling(
    derived, symptomTorqueCoef, symptomFrictionCoef, symptomIgnitionBonus, engine, base,
    directDriveSeverity
  )
  local appliedLimit = torqueCap

  -- Limit horsepower only with a useful base rating at high engine speed.
  local shouldUsePowerCap = baseMaxPowerWatts > 0 and engineAV > 220 and
                                 (symptom == 'powerFade' or symptom == 'stall' or directDriveSeverity >= 0.35 or
                                     (derived.ignitionSeverity or 0) >= 0.45)
  if shouldUsePowerCap then
    local powerFloorCoef = common.sampleCurve(directDriveSeverity, {
      {0.0, 0.62},
      {0.35, 0.52},
      {0.70, 0.36},
      {1.10, 0.22},
      {1.50, 0.10},
      {1.80, 0.04}
    })
    local powerTorqueCap = max((baseMaxPowerWatts * derived.powerHoldCoef * symptomPowerCoef) / engineAV, baseMaxTorque * powerFloorCoef)
    appliedLimit = min(torqueCap, powerTorqueCap)
    if powerTorqueCap < torqueCap - 0.001 then
      runtime.lastPowerLimitReason = getPowerLimitReason(derived, symptom, directDriveSeverity, true, lubricationDamageStage)
      runtime.lastPowerLimitActive = true
    end
  end

  if not runtime.lastPowerLimitReason and torqueCap < baseMaxTorque * 0.995 then
    runtime.lastPowerLimitReason = getPowerLimitReason(derived, symptom, directDriveSeverity, false, lubricationDamageStage)
    runtime.lastPowerLimitActive = true
  end

  applyEngineMinimumTorqueLimit(
    derived, symptom, engine, base, lubricationDamageStage, directDriveSeverity, baseMaxTorque,
    appliedLimit
  )
  -- Radiator scaling must start from the current engine values.
  entry.engineAppliedFriction = engine.friction
  entry.engineAppliedDynamicFriction = engine.dynamicFriction
  return engine, base, lubricationDamageStage
end

local function apply(context, state, runtime, derived)
  local symptom = getActiveSymptom(runtime)
  local symptomTorqueCoef = 1
  local symptomPowerCoef = 1
  local symptomFrictionCoef = 1
  local symptomRoughnessCoef = 1
  local symptomIgnitionBonus = 0

  if symptom == 'roughRunning' or symptom == 'ticking' then
    symptomRoughnessCoef = 1.1
  elseif symptom == 'roughIdle' then
    symptomRoughnessCoef = 1.32
    symptomIgnitionBonus = 0.018
  elseif symptom == 'torqueDip' then
    symptomTorqueCoef = 0.94
  elseif symptom == 'powerFade' then
    symptomPowerCoef = 0.9
    symptomTorqueCoef = 0.96
    symptomFrictionCoef = 1.03
  elseif symptom == 'stall' then
    symptomPowerCoef = 0.7
    symptomTorqueCoef = 0.65
    symptomRoughnessCoef = 1.55
    symptomFrictionCoef = 1.05
    symptomIgnitionBonus = 0.045
  end

  runtime.lastPowerLimitReason = nil
  runtime.lastPowerLimitActive = false

  for _, entry in ipairs(context.devices or {}) do
    local engine, base, lubricationDamageStage = applyEnginePowerCeiling(
      runtime, derived, symptom, symptomTorqueCoef, symptomPowerCoef, symptomFrictionCoef,
      symptomIgnitionBonus, entry
    )
    applyEngineThermalsAndStall(
      runtime, derived, symptom, symptomRoughnessCoef, entry, engine, base, lubricationDamageStage
    )
  end
end

-- Hard failures -----------------------------------------------------------------------------------

local function getHardFailureState(reason)
  local isCoolingFailure = reason == 'cooling_failure' or reason == 'head_gasket_failure'

  return {
    damageFrictionCoef = 2.5,
    damageDynamicFrictionCoef = 3.5,
    damageIdleAVReadErrorRangeCoef = 32,
    fastIgnitionErrorChance = 0.35,
    slowIgnitionErrorChance = 0.35,
    thermals = {
      headGasketBlown = isCoolingFailure,
      pistonRingsDamaged = not isCoolingFailure,
      connectingRodBearingsDamaged = not isCoolingFailure,
      engineBlockMelted = false,
      cylinderWallsMelted = not isCoolingFailure
    },
    isBroken = true
  }
end

local function clearFailureRuntime(context)
  local runtime = context.runtime or nil
  if type(runtime) == "table" then
    runtime.knockSoundTick = 0
    runtime.criticalOilSeconds = 0
    runtime.dryOilSeconds = 0
    runtime.lubricationDamageStage = 0
    runtime.forceHardFailure = false
    runtime.forceHardFailureTarget = nil
    runtime.forceHardFailurePersistent = false
    runtime.forceHardFailureReason = nil
  end

  for _, entry in ipairs(context.devices or {}) do
    local engine = entry.device
    local base = entry.base or {}
    resetEngineState(engine, base, nil, true)

    if engine.isStalled ~= nil then
      engine.isStalled = false
    end
    if engine.stallTimer ~= nil then
      engine.stallTimer = 0
    end

    if type(engine.thermals) == "table" then
      if engine.thermals.headGasketBlown ~= nil then
        engine.thermals.headGasketBlown = false
      end
      if engine.thermals.pistonRingsDamaged ~= nil then
        engine.thermals.pistonRingsDamaged = false
      end
      if engine.thermals.connectingRodBearingsDamaged ~= nil then
        engine.thermals.connectingRodBearingsDamaged = false
      end
      if engine.thermals.engineBlockMelted ~= nil then
        engine.thermals.engineBlockMelted = false
      end
      if engine.thermals.cylinderWallsMelted ~= nil then
        engine.thermals.cylinderWallsMelted = false
      end
    end
  end
end

-- Public API --------------------------------------------------------------------------------------

M.getDefaultMaintenance = getDefaultMaintenance
M.getLiveTorqueHoldCoef = getLiveTorqueHoldCoef
M.drainMaintenance = drainMaintenance
M.buildDerived = buildDerived
M.stepRuntime = stepRuntime
M.apply = apply
M.updateAudio = updateAudio
M.getHardFailureState = getHardFailureState
M.clearFailureRuntime = clearFailureRuntime
M.minimumHardFailureMileage = minimumHardFailureMileage

return M
