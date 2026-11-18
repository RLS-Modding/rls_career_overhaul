// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

function buildPneumaticFindings({ live, isNumber, airPressure }) {
  if (live.lowAirPressure !== true) return []
  return [{
    key: 'low-air-pressure', severity: 'high', title: 'Low air pressure',
    cause: isNumber(live.airPressurePa)
      ? `The pneumatic system currently reports ${airPressure(live.airPressurePa)}.`
      : 'Pneumatic-system pressure is below its operating threshold.',
    effect: live.parkingBrakeApplied === true
      ? 'The spring parking brake is applied and may not release until pressure recovers.'
      : 'Air-brake and pneumatic-system operation may be limited until pressure recovers.',
    action: 'Allow the air compressor to build pressure. Inspect the compressor, tanks, and pneumatic system if pressure does not recover.',
  }]
}

function buildElectricDriveFindings(context) {
  const { live, motorUnavailable, motorOutputRestricted, motorRestrictionNeedsAttention,
    hasMeasuredMotorRestriction, motorTorqueAvailability, recentMotorTorqueAvailability,
    isNumber, percent } = context
  const findings = []
  if (live.motorBroken === true) findings.push({
    key: 'motor-broken', severity: 'high', title: 'Drive motor fault detected',
    cause: 'The installed drive motor has mechanically failed.',
    effect: 'The motor cannot provide normal propulsion.',
    action: 'Inspect and repair or replace the damaged drive motor.',
  })
  if (motorUnavailable) findings.push({
    key: 'motor-unavailable', severity: 'high', title: 'Drive motor unavailable',
    cause: 'The motor is disabled even though connected battery energy remains available.',
    effect: 'Propulsion from the affected motor is unavailable.',
    action: 'Inspect the motor, its controller, and associated powertrain damage.',
  })
  if (motorOutputRestricted) findings.push({
    key: 'propulsion-restriction', severity: motorRestrictionNeedsAttention ? 'high' : 'medium',
    attention: motorRestrictionNeedsAttention,
    title: motorRestrictionNeedsAttention ? 'Propulsion output restricted' : 'Propulsion output reduced under load',
    cause: hasMeasuredMotorRestriction
      ? `The current motor torque limit is ${percent(motorTorqueAvailability)} of its installed rating.`
      : 'The vehicle maintenance system has applied an output restriction.',
    effect: 'Available propulsion torque or power is currently reduced.',
    action: motorRestrictionNeedsAttention
      ? 'Review motor operation and service condition; inspect the powertrain if the restriction persists.'
      : 'No immediate action is required. Continue monitoring under-load availability for further reduction.',
  })
  if (!motorOutputRestricted && isNumber(recentMotorTorqueAvailability)) findings.push({
    key: 'recent-propulsion-restriction', severity: 'medium', attention: false, recent: true,
    title: 'Recently observed — propulsion output reduced under load',
    cause: `The lowest recently observed motor torque limit was ${percent(recentMotorTorqueAvailability)} of its installed rating.`,
    effect: 'The reduction was present under load; current stationary output is no longer restricted.',
    action: 'No immediate action is required. Continue monitoring if available output falls further.',
  })
  return findings
}

function buildNativeDamageEventFindings({ live, nativeDamageFinding }) {
  const recentDamageEvents = Array.isArray(live.recentDamageEvents)
    ? live.recentDamageEvents
    : Object.values(live.recentDamageEvents || {})
  return recentDamageEvents.map(nativeDamageFinding).filter(Boolean)
}

function buildNativeEngineConditionFindings({ live, pistonRingsDamaged }) {
  const findings = []
  if (live.engineHydrolocked) findings.push({ key: 'hydrolock', severity: 'high', title: 'Engine rotation obstructed', cause: 'Liquid intrusion into a combustion chamber is the likely cause.', effect: 'The engine cannot rotate safely.', action: 'Stop attempting to start the engine and inspect it before further operation.' })
  if (live.rodBearingsDamaged) findings.push({ key: 'rod-bearings', severity: 'high', title: 'Severe internal engine damage', cause: 'Bearing or lubrication-system damage is the likely cause.', effect: 'Continued operation may cause complete engine failure.', action: 'Stop the engine and repair the damaged long block.' })
  if (live.headGasketDamaged) findings.push({ key: 'head-gasket', severity: 'high', title: 'Combustion/cooling sealing fault', cause: live.fuelSystem?.causedGasket === true ? 'Repeated knock from the fuel or tune damaged the head gasket.' : 'Cylinder-head or head-gasket sealing failure is the likely cause.', effect: 'Cooling and combustion performance may be compromised.', action: live.fuelSystem?.causedGasket === true ? 'Repair the head gasket, then correct the fuel and ignition tune.' : 'Inspect and repair the cylinder head and gasket.' })
  if (live.idleStability === 'unstable') findings.push({ key: 'idle-unstable', severity: 'high', title: 'Unstable idle', cause: 'Engine wear, damage, or overdue service has severely degraded idle-speed control.', effect: 'The engine may stall at idle or when the throttle is released.', action: 'Inspect the engine for wear and damage. A high-mileage engine may need an overhaul or replacement.' })
  else if (live.idleStability === 'rough') findings.push({ key: 'idle-rough', severity: 'medium', attention: false, title: 'Rough idle', cause: 'Engine wear, damage, or overdue service is reducing idle-speed stability.', effect: 'Idle speed may fluctuate and the engine may stumble.', action: 'Monitor idle quality and inspect the engine if it begins to stall.' })
  if (live.idleStability !== 'unstable' && live.recentIdleStall === true) findings.push({ key: 'recent-idle-stall', severity: 'medium', attention: false, recent: true, title: 'Recently observed — engine stalled at idle', cause: 'The engine stopped while idling with no load applied.', effect: 'The engine did not sustain idle speed.', action: 'Restart the engine and monitor idle quality. Inspect the engine if stalling returns.' })
  if (pistonRingsDamaged) findings.push({ key: 'piston-rings', severity: 'high', title: 'Cylinder sealing fault suspected', cause: live.fuelSystem?.causedRings === true ? 'Repeated knock or a lean mixture from the fuel tune damaged the piston rings.' : 'Piston-ring or cylinder sealing deterioration is the likely cause.', effect: 'Oil consumption and power loss may increase.', action: live.fuelSystem?.causedRings === true ? 'Repair the engine internals, then correct the fuel and ignition tune.' : 'Inspect compression and repair the engine internals.' })
  return findings
}

function buildMaintenanceFindings(context) {
  const { live, engine, radiator, recentEngineRestriction, powerLimited, powerLimitReason,
    friendlyFindingCause, powerLimitAction, recentSymptom, engineSymptomFinding,
    coolingSymptomFinding } = context
  const findings = []
  if (powerLimited) {
    const cooling = radiator.liveMetrics?.powerLimitActive === true
    findings.push({
      key: 'output-restriction', severity: cooling ? 'high' : 'medium', attention: true,
      title: 'Engine output restricted',
      cause: friendlyFindingCause(powerLimitReason), effect: 'Available engine torque or power is currently reduced.',
      action: powerLimitAction(powerLimitReason, cooling),
    })
  }
  if (!powerLimited && recentEngineRestriction) {
    findings.push({
      key: 'recent-output-restriction', severity: 'medium', attention: false, recent: true,
      title: 'Recently observed — engine output restricted under load',
      cause: friendlyFindingCause(recentEngineRestriction.reason),
      effect: 'Available engine torque or power was reduced while the engine was under load.',
      action: 'Continue monitoring under load. Inspect the engine if the output restriction returns or persists.',
    })
  }
  const activeEngineSymptom = engine.activeSymptom
  if (!powerLimited && activeEngineSymptom) findings.push(engineSymptomFinding(activeEngineSymptom, true))
  else if (!powerLimited && !recentEngineRestriction && !live.recentCombustionStability && !live.recentMisfireRisk) {
    const stored = recentSymptom(engine, 'engine')
    if (stored) findings.push(engineSymptomFinding(stored, false))
  }

  const activeCoolingSymptom = radiator.activeSymptom
  if (!powerLimited && activeCoolingSymptom) findings.push(coolingSymptomFinding(activeCoolingSymptom, true))
  else if (!powerLimited) {
    const representedByNativeFinding = (Array.isArray(live.recentDamageEvents)
      ? live.recentDamageEvents
      : Object.values(live.recentDamageEvents || {}))
      .some(event => event?.name === 'coolantOverheating' || event?.name === 'radiatorLeak')
    const representedByRestriction = recentEngineRestriction && /cool/i.test(recentEngineRestriction.reason || '')
    const stored = recentSymptom(radiator, 'radiator')
    if (stored && !representedByNativeFinding && !representedByRestriction) findings.push(coolingSymptomFinding(stored, false))
  }
  return findings
}

function fuelFinding(key, severity, title, cause, effect, action) {
  return { key, severity, title, cause, effect, action }
}

// Active only. An empty tank does not count as the wrong fuel; the vehicle
// side already withholds those alerts until there is fuel to judge.
function buildFuelFindings({ live }) {
  const fuel = live.fuelSystem
  if (!fuel || fuel.monitored !== true) return []
  const alerts = fuel.alerts || {}
  const findings = []
  if (alerts.nitroKit === true) findings.push(fuelFinding('fuel-nitro-kit', 'high', 'Nitro fuel in an unconverted system', 'The tank contains nitromethane, and this engine does not have a Nitro 90 system.', 'Fuel delivery can be far below what this fuel needs.', 'Drain the tank, or install a Nitro 90 system before using this fuel.'))
  if (alerts.nitroBlend === true) findings.push(fuelFinding('fuel-nitro-blend', 'high', 'Nitro 90 blend is off', 'This system is calibrated for 90% nitromethane and 10% methanol.', 'The engine is not running the blend it was set up for.', 'Drain the tank and refill with Nitro 90.'))
  if (alerts.methanolKit === true) findings.push(fuelFinding('fuel-methanol-kit', 'high', 'Methanol in an incompatible system', 'The tank contains methanol, and this engine does not have an M100 system.', 'The current calibration cannot compensate for this fuel.', 'Drain the tank, or install an M100 system before using methanol.'))
  if (alerts.methanolPurity === true) findings.push(fuelFinding('fuel-methanol-purity', 'high', 'M100 system is not on methanol', 'This system expects nearly pure methanol.', 'The mixture can run excessively rich.', 'Drain the tank and refill with M100.'))
  if (alerts.mixedMethanol === true) findings.push(fuelFinding('fuel-mixed-methanol', 'medium', 'Mixed methanol fuel', 'The tank contains methanol mixed with other fuel.', 'This mixture is not a supported calibration.', 'Drain the tank before refueling.'))
  if (alerts.ethanolUnconverted === true) findings.push(fuelFinding('fuel-ethanol-unconverted', 'high', 'Ethanol blend in an unconverted system', 'Ethanol content is above what the standard gasoline system is calibrated for.', 'Fuel delivery and mixture can be outside the tune.', 'Drain the tank, or install a flex-fuel system before using this blend.'))
  if (alerts.octaneShort === true) findings.push(fuelFinding('fuel-octane-short', 'medium', 'Octane below engine requirement', fuel.requirementEstimated === true ? 'The fuel octane is below the octane this engine is estimated to need.' : 'The fuel octane is below the octane this engine requires.', 'High-load operation can cause knock and engine damage.', 'Use a higher-octane fuel, or reduce load until the tank is refilled.'))
  if (alerts.knock === true && fuel.knockControl === true) findings.push(fuelFinding('fuel-knock', 'high', 'Knock is getting past protection', 'The engine is knocking even with ignition retarded as far as its protection allows.', 'Continued high-load knock damages the engine.', 'Lift off, then use higher-octane fuel or retard the ignition tune.'))
  else if (alerts.knock === true) findings.push(fuelFinding('fuel-knock', 'high', 'Engine is knocking', 'The engine is knocking under the current fuel and tune, and it has no knock protection.', 'Continued high-load knock damages the engine.', 'Lift off, then use higher-octane fuel or retard the ignition tune.'))
  else if (alerts.knockRetard === true) findings.push(fuelFinding('fuel-knock-retard', 'medium', 'Knock protection is active', 'Ignition is being retarded to keep knock down.', 'Timing is later than the tune asked for.', 'Review fuel octane and the ignition tune if this stays on under load.'))
  if (alerts.boostCut === true) findings.push(fuelFinding('fuel-boost-cut', 'medium', 'Boost cut active', 'Boost is above the pressure the fuel calibration allows, so fuel is being cut.', 'Power drops out in bursts at full throttle.', 'Lower the boost, or raise the boost cut in Fuel & Ignition with enough fuel delivery and octane for it.'))
  if (alerts.lean === true) findings.push(fuelFinding('fuel-lean', 'high', 'Mixture is lean under load', 'The engine is running leaner than is safe under load.', 'Combustion can overheat pistons and valves.', 'Check the fuel, the tank blend, and whether delivery is keeping up.'))
  if (alerts.rich === true) findings.push(fuelFinding('fuel-rich', 'medium', 'Mixture is excessively rich', 'The engine is running richer than the tune intends.', 'Running can be poor, and spark plugs can foul.', 'Correct the mixture before continued hard use.'))
  return findings
}

function buildDrivetrainFindings(context) {
  const { live, transmission, clutchTemperatureHigh, clutchTemperatureElevated,
    recentSymptom, transmissionSymptomFinding, isNumber, temperature } = context
  const findings = []
  if (live.clutchDamaged) findings.push({ key: 'clutch-damage', severity: 'high', title: 'Clutch damage detected', cause: 'The clutch can no longer transfer torque normally.', effect: 'Slip or loss of drive may occur.', action: 'Inspect and replace the clutch assembly.' })
  if (clutchTemperatureHigh || clutchTemperatureElevated) findings.push({ key: 'clutch-temperature', severity: clutchTemperatureHigh ? 'high' : 'medium', title: clutchTemperatureHigh ? 'Clutch overheating' : 'Clutch temperature high', cause: 'Excessive clutch slip has generated more heat than the clutch can safely dissipate.', effect: clutchTemperatureHigh ? 'Continued use may permanently damage the clutch.' : 'Clutch capacity may fall if temperature continues to rise.', action: 'Stop slipping the clutch and allow it to cool. Inspect the clutch if overheating returns frequently.' })
  const activeTransmissionSymptom = transmission.activeSymptom
  if (activeTransmissionSymptom) findings.push(transmissionSymptomFinding(activeTransmissionSymptom, true))
  else {
    const stored = recentSymptom(transmission, 'transmission')
    if (['roughShift', 'shiftDelay', 'slip'].includes(stored)) findings.push(transmissionSymptomFinding(stored, false))
  }
  // The vehicle holds this peak for its own window and re-sends it every frame, so it is
  // the only clock for the clutch-heat event.
  const recentPeak = live.recentClutchHeatPeakC
  if (!clutchTemperatureHigh && !clutchTemperatureElevated && isNumber(recentPeak)) findings.push({ key: 'recent-clutch-temperature', severity: 'medium', attention: false, recent: true, title: 'Recent clutch overheating', cause: 'Excessive clutch slip raised temperature above the installed clutch warning threshold.', effect: `Clutch temperature recently reached ${temperature(recentPeak)} and has since fallen.`, action: 'Allow the clutch to cool fully and inspect it if overheating returns frequently.' })
  const transmissionRisks = Array.isArray(transmission.riskFlags)
    ? transmission.riskFlags
    : Object.values(transmission.riskFlags || {})
  const transmissionThermalStressActive = transmissionRisks.some(risk => risk?.key === 'transmission_heat' || risk?.key === 'transmission_overheat')
  if (!transmissionThermalStressActive && (live.recentTransmissionThermalStress === 'elevated' || live.recentTransmissionThermalStress === 'high')) findings.push({
    key: 'recent-transmission-thermal-stress', severity: 'medium', attention: false, recent: true,
    title: 'Recently observed — transmission thermal stress',
    cause: 'Elevated transmission thermal stress was observed under load.',
    effect: 'Transmission fluid and components may experience accelerated wear under these conditions.',
    action: 'Allow the transmission to cool and reduce sustained high-load operation if the condition returns.',
  })
  return findings
}

// Active high-severity conditions must survive truncation. Native damage events are
// unbounded and linger for five minutes after going inactive, so without this an active
// hydrolock or rod-bearing finding can be pushed out by stale "recently observed" ones.
function findingPriority(finding) {
  const active = finding.attention !== false && finding.recent !== true
  const high = finding.severity === 'high'
  if (active) return high ? 0 : 1
  return high ? 2 : 3
}

export function buildDiagnosticFindings(context) {
  // A hybrid has both an electric drive and a combustion engine, so it needs both sets of
  // builders. The motor signals in the caller are keyed on hasElectricDrive, not isElectric.
  const sources = [buildPneumaticFindings(context), buildNativeDamageEventFindings(context)]
  if (context.live.hasElectricDrive) sources.push(buildElectricDriveFindings(context))
  if (!context.live.isElectric) {
    sources.push(buildNativeEngineConditionFindings(context), buildFuelFindings(context), buildMaintenanceFindings(context), buildDrivetrainFindings(context))
  }
  const findings = sources.flat()
    .filter((finding, index, all) => all.findIndex(candidate => candidate.key === finding.key) === index)
  if (!context.live.isElectric && context.live.checkEngine === true && !findings.some(finding => finding.attention !== false)) findings.push({ key: 'controller-warning', severity: 'medium', title: 'Check-engine light active', cause: 'The vehicle has requested the check-engine warning, but no more specific supported cause is currently reported.', effect: 'The check-engine light is illuminated on the dashboard.', action: 'Review temperatures and live readings, then inspect the vehicle if the warning persists or returns.' })
  findings.sort((a, b) => findingPriority(a) - findingPriority(b))
  return findings.slice(0, 4)
}
