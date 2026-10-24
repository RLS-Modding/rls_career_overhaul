// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// Capture the screen's category refs so findings track its current vehicle.
export function createObdPresentation({ units, engine, radiator, transmission, recentSymptoms }) {
  const POWER_LIMIT_DEFINITIONS = {
    'Temporary symptom': {
      status: 'Reduced — active engine fault',
      cause: 'An active engine fault is limiting output.',
    },
    'Oil starvation': {
      status: 'Reduced — lubrication fault',
      cause: 'Insufficient lubrication is limiting engine output.',
      action: 'Check the oil level and lubrication system before continued operation.',
    },
    'Severe ignition issue': {
      status: 'Reduced — ignition fault',
      cause: 'Ignition-system condition is limiting engine output.',
    },
    'Maintenance torque protection': {
      status: 'Reduced — service condition',
      cause: 'Engine service condition has triggered protective output reduction.',
    },
    'Catastrophic cooling loss': {
      cause: 'Severe coolant loss has triggered engine protection.',
    },
    Overheating: {
      cause: 'Excessive engine temperature has triggered engine protection.',
    },
  }
  const DIAGNOSTIC_RISK_DEFINITIONS = {
    wear_spike: { label: 'Accelerated wear detected', detail: 'Wear rate is currently above normal.' },
    age_fluid_loss: { label: 'Age-related fluid consumption', detail: 'Component age is increasing fluid consumption.' },
    fluid_neglect: { label: 'Low fluid level is accelerating fluid loss', detail: 'Restore the fluid to its correct level.' },
    high_output: { label: 'Engine is tuned beyond its torque rating', detail: 'Heavy load adds oil and ignition wear.' },
    limit_stress: { label: 'High powertrain stress', detail: 'Operating demand is close to the transmission capacity.' },
    failure_window: { label: 'Transmission failure risk detected', detail: 'Continued operation may cause a mechanical failure.' },
    engine_integrity: { label: 'Engine mechanical integrity is low' },
    oil_starvation: { label: 'Severe oil starvation detected' },
    oil_starvation_catastrophic: { label: 'Critical oil starvation detected' },
    piston_rings: { label: 'Piston-ring damage detected', detail: 'Oil consumption is elevated.' },
    cooling_catastrophic: { label: 'Critical cooling-system loss detected' },
    cooling_severe: { label: 'Severe cooling-system loss detected' },
    overheating: { label: 'Engine is overheating' },
    critical_heat: { label: 'Coolant temperature is critically high' },
    transmission_overheat: { label: 'Transmission is overheating' },
    transmission_heat: { label: 'Transmission temperature is elevated' },
    fluid_quality_critical: { label: 'Transmission-fluid condition is critical' },
    fluid_quality_low: { label: 'Transmission-fluid condition is poor' },
    slip_risk: { label: 'Transmission slip risk detected' },
    fluid_loss: { label: 'Transmission-fluid level is critical' },
    fluid_low: { label: 'Transmission-fluid level is low' },
  }

  const SERVICE_ITEM_LABELS = {
    coolantIntegrity: 'Coolant condition',
    fluidCondition: 'Fluid quality',
  }

  const SERVICE_DUE_DETAILS = {
    oilCondition: 'Engine oil service needed.',
    oilLevel: 'Engine oil level needs attention.',
    ignitionService: 'Ignition service needed.',
    coolantLevel: 'Coolant level needs attention.',
    coolantIntegrity: 'Cooling-system service needed.',
    fluidCondition: 'Transmission-fluid service needed.',
    fluidLevel: 'Transmission-fluid level needs attention.',
  }

  const TRANSMISSION_SYMPTOM_DEFINITIONS = {
    roughShift: { label: 'Rough shift', effect: 'Gear changes may feel abrupt or harsh.' },
    shiftDelay: { label: 'Shift delay', effect: 'Gear engagement or shifting may respond more slowly than expected.' },
    slip: { label: 'Transmission slip', effect: 'Engine speed may rise without a matching increase in vehicle speed.' },
  }

  const ENGINE_SYMPTOM_DEFINITIONS = {
    roughRunning: { label: 'Rough running', effect: 'Engine smoothness and response may be affected.' },
    ticking: { label: 'Engine ticking', effect: 'Mechanical engine noise was elevated.' },
    roughIdle: { label: 'Rough idle', effect: 'Idle quality and combustion stability may be affected.' },
    torqueDip: { label: 'Torque dip', effect: 'Available engine torque briefly fell.' },
    powerFade: { label: 'Power fade', effect: 'Available engine output temporarily decreased.' },
    stall: { label: 'Momentary stall', effect: 'The engine briefly stopped producing power.' },
  }

  const COOLING_SYMPTOM_DEFINITIONS = {
    coolantSeep: { label: 'Coolant seep', effect: 'Coolant may be lost gradually from the cooling system.' },
    fanOverwork: { label: 'Fan overwork', effect: 'The cooling fan operated under elevated demand.' },
  }

  const NATIVE_DAMAGE_DEFINITIONS = {
    overRevDanger: { title: 'Engine over-rev observed', cause: 'Engine RPM exceeded the mechanical safe limit.', effect: 'Internal engine components may have been overstressed.', action: 'Avoid further over-revving and inspect the engine if abnormal operation follows.' },
    mildOverrevDamage: { title: 'Engine over-rev damage', cause: 'Engine RPM exceeded the safe limit and caused internal damage.', effect: 'Engine durability or performance may be reduced.', action: 'Inspect the engine before further high-speed operation.' },
    catastrophicOverrevDamage: { severity: 'high', title: 'Severe engine over-rev damage', cause: 'Engine RPM exceeded the safe limit and caused catastrophic internal stress.', effect: 'Major internal engine damage may have occurred.', action: 'Stop the engine and inspect it before further operation.' },
    overTorqueDanger: { title: 'Engine overtorque observed', cause: 'Combustion torque exceeded the engine damage threshold.', effect: 'Internal engine components may have been overstressed.', action: 'Reduce load and inspect the engine if abnormal operation follows.' },
    catastrophicOverTorqueDamage: { severity: 'high', title: 'Severe engine overtorque damage', cause: 'Engine torque exceeded the damage threshold and caused catastrophic internal damage.', effect: 'Major internal engine damage may have occurred.', action: 'Stop the engine and inspect it before further operation.' },
    coolantOverheating: { title: 'Coolant overheating', cause: 'Coolant temperature exceeded the vehicle warning threshold.', effect: 'Continued operation may damage the cooling system or engine.', action: 'Reduce load, stop safely, and allow the engine to cool.' },
    oilOverheating: { title: 'Engine oil overheating', cause: 'Oil temperature exceeded the vehicle warning threshold.', effect: 'Lubrication performance may be reduced.', action: 'Reduce load and allow the engine oil to cool.' },
    starvedOfOil: { title: 'Oil starvation observed', cause: 'Oil supply became insufficient during vehicle motion.', effect: 'Engine bearings may have received inadequate lubrication.', action: 'Stop severe manoeuvres and inspect oil level if the warning returns.' },
    oilLevelCritical: { severity: 'high', title: 'Critical engine oil level', cause: 'The engine reported an unsafe oil quantity.', effect: 'Lubrication loss may cause rapid engine damage.', action: 'Stop the engine and correct the oil level before continued operation.' },
    oilLevelTooHigh: { title: 'Engine oil level too high', cause: 'The engine reported excessive oil quantity.', effect: 'Lubrication and crankcase operation may be affected.', action: 'Correct the oil level before continued operation.' },
    engineIsHydrolocking: { title: 'Hydrolock risk observed', cause: 'Liquid intrusion obstructed engine rotation.', effect: 'Further starting attempts may cause severe internal damage.', action: 'Stop attempting to start the engine and inspect it.' },
    engineReducedTorque: { title: 'Engine output reduced', cause: 'The vehicle controller reported reduced engine torque.', effect: 'Available engine performance was limited.', action: 'Review other findings and inspect the engine if the restriction returns.' },
    engineDisabled: { title: 'Engine disabled', cause: 'The vehicle reported that the engine could not operate.', effect: 'Propulsion from the engine was unavailable.', action: 'Inspect active damage and engine systems before restarting.' },
    engineLockedUp: { severity: 'high', title: 'Engine lock-up', cause: 'Internal lock-up prevented the engine from rotating.', effect: 'The engine cannot operate normally.', action: 'Stop attempting to run the engine and inspect internal damage.' },
    impactDamage: { title: 'Engine impact damage', cause: 'An impact damaged the engine assembly.', effect: 'Engine operation or durability may be compromised.', action: 'Inspect the engine and its mounts before continued operation.' },
    radiatorLeak: { title: 'Radiator leak', cause: 'Coolant is leaking from the radiator.', effect: 'Coolant loss may lead to overheating.', action: 'Inspect the radiator and coolant level before continued operation.' },
    oilRadiatorLeak: { title: 'Engine oil cooler leak', cause: 'Engine oil is leaking from the oil cooler.', effect: 'Oil loss may reduce lubrication.', action: 'Inspect the oil cooler and oil level before continued operation.' },
    oilpanLeak: { title: 'Engine oil pan leak', cause: 'Engine oil is leaking from the oil pan.', effect: 'Oil loss may reduce lubrication.', action: 'Inspect the oil pan and oil level before continued operation.' },
    exhaustBroken: { title: 'Exhaust system damage', cause: 'An exhaust-system connection is broken.', effect: 'Exhaust flow, sound, or emissions behavior may be affected.', action: 'Inspect and repair the exhaust system.' },
    blockMelted: { severity: 'high', title: 'Engine block thermal failure', cause: 'Extreme temperature damaged the engine block.', effect: 'The engine cannot operate safely.', action: 'Stop the engine and replace or rebuild the damaged assembly.' },
    cylinderWallsMelted: { severity: 'high', title: 'Cylinder wall thermal failure', cause: 'Extreme temperature damaged the cylinder walls.', effect: 'The engine cannot operate safely.', action: 'Stop the engine and replace or rebuild the damaged assembly.' },
    synchroWear: { title: 'Gear synchronizer wear observed', cause: 'A gear synchronizer was overstressed during a gear change.', effect: 'Gear engagement may become difficult or noisy.', action: 'Use the clutch fully and avoid forcing gear engagement.' },
    turbochargerHot: { title: 'Turbocharger temperature high', cause: 'Turbocharger temperature is above its normal operating range.', effect: 'Boost performance or turbocharger durability may be affected.', action: 'Reduce engine load and allow the turbocharger to cool.' },
    inductionSystemDamaged: { severity: 'high', title: 'Forced-induction system damage', cause: 'The installed turbocharger or supercharger system has physical damage.', effect: 'Boost pressure and engine output may be reduced.', action: 'Inspect and repair the forced-induction system.' },
    deformationLeak: { severity: 'high', title: 'Pneumatic pressure-tank leak', cause: 'Tank deformation has caused a pneumatic-system leak.', effect: 'Stored air pressure may fall and pneumatic systems may become unavailable.', action: 'Inspect the pressure tank and pneumatic lines before continued operation.' },
    breakLeak: { severity: 'high', title: 'Pneumatic pressure tank damaged', cause: 'A broken pressure tank or connection has caused a major air leak.', effect: 'Stored air pressure may be lost rapidly.', action: 'Inspect and repair the damaged pressure tank before continued operation.' },
    systemStateDegraded: { title: 'Vehicle stability control degraded', cause: 'The driving-dynamics control system is operating in a degraded state.', effect: 'Stability or traction assistance may be limited.', action: 'Drive cautiously and inspect the stability-control system if the warning persists.' },
  }

  function isNumber(value) { return typeof value === 'number' && Number.isFinite(value) }
  function isBoolean(value) { return typeof value === 'boolean' }
  function decimal(value, digits = 1) { return isNumber(value) ? value.toFixed(digits) : null }
  function whole(value) { return isNumber(value) ? Math.round(value).toLocaleString() : null }
  function temperature(value) { return isNumber(value) ? units.buildString('temperature', value, 0) : null }
  function percent(value) { return isNumber(value) ? `${Math.round(value * 100)}%` : null }
  function clampPercent(value) { return typeof value === 'number' ? Math.max(0, Math.min(100, value * 100)) : 0 }
  function power(metricHorsepower) { return isNumber(metricHorsepower) ? units.buildString('power', metricHorsepower, 0) : null }
  function torque(value) { return isNumber(value) ? units.buildString('torque', value, 0) : null }
  function distanceMiles(miles) { return isNumber(miles) ? units.buildString('length', miles * 1609.344, 0) : null }
  function ratioList(ratios) { return ratios.filter(isNumber).map(ratio => `${decimal(ratio, 2)}:1`).join(' / ') }
  function airPressure(pascals) { return isNumber(pascals) ? units.buildString('pressure', pascals / 1000, 1) : null }
  function boostPressure(psi) { return isNumber(psi) ? units.buildString('pressure', psi * 6.894757, 2) : null }
  function serviceConditionSeverity(item) {
    if (!isNumber(item?.value) || !isNumber(item?.targetValue) || item.targetValue <= 0) return null
    if (item.value < item.targetValue - 0.12) return 'bad'
    if (item.value <= item.targetValue) return 'warn'
    return 'good'
  }
  function conditionColor(value) {
    if (!isNumber(value)) return 'var(--muted)'
    const amount = Math.max(0, Math.min(1, value))
    const red = [255, 102, 115]
    const amber = [255, 190, 85]
    const green = [80, 227, 164]
    const start = amount < 0.5 ? red : amber
    const end = amount < 0.5 ? amber : green
    const mix = amount < 0.5 ? amount * 2 : (amount - 0.5) * 2
    const channel = index => Math.round(start[index] + (end[index] - start[index]) * mix)
    return `rgb(${channel(0)}, ${channel(1)}, ${channel(2)})`
  }
  function serviceItemColor(item) {
    const severity = serviceConditionSeverity(item)
    if (severity === 'bad') return 'var(--red)'
    if (severity === 'warn') return 'var(--amber)'
    if (severity === 'good') return 'var(--green)'
    return conditionColor(item?.value)
  }
  // Heavier vehicle classes age against a longer lifespan; the model sends the mileage its
  // age curves use. The distance line under the bar stays the real odometer.
  function ageMiles(category) {
    return isNumber(category?.ageMiles) ? category.ageMiles : Number(category?.avgMiles) || 0
  }
  function mileageWearPercent(avgMiles) {
    return Math.round(Math.max(0, Math.min(1, avgMiles / 250000)) * 100)
  }
  function mileageWearColor(avgMiles) {
    return conditionColor(1 - mileageWearPercent(avgMiles) / 100)
  }
  function categoryConditionSeverity(category) {
    const severities = (category?.maintenanceItems || []).map(serviceConditionSeverity)
    if (severities.includes('bad')) return 'bad'
    if (severities.includes('warn')) return 'warn'
    if (severities.includes('good')) return 'good'
    return null
  }
  function categoryConditionClass(category) {
    const severity = categoryConditionSeverity(category)
    if (severity === 'good') return 'neutral-text'
    return severity ? `${severity}-text` : 'neutral-text'
  }
  function categoryConditionState(category) {
    const severity = categoryConditionSeverity(category)
    if (severity === 'bad') return 'Overdue'
    if (severity === 'warn') return 'Service due'
    if (severity === 'good') return 'No service due'
    return 'Not reported'
  }
  function highIsBadState(value, elevated, high) {
    if (!isNumber(value)) return null
    if (value >= high) return 'High'
    if (value >= elevated) return 'Elevated'
    return 'Normal'
  }
  function elevatedAbove(value, threshold) {
    if (!isNumber(value)) return null
    return value > threshold ? 'Elevated' : 'Normal'
  }
  function lowIsBadState(value, reduced, low) {
    if (!isNumber(value)) return null
    if (value <= low) return 'Low'
    if (value <= reduced) return 'Reduced'
    return 'Normal'
  }
  function serviceItemLabel(item) {
    return SERVICE_ITEM_LABELS[item?.name] || item?.label || null
  }
  function dueMaintenanceItem(category) {
    return (category?.maintenanceItems || [])
      .filter(item => ['warn', 'bad'].includes(serviceConditionSeverity(item)))
      .sort((a, b) => a.value - b.value)[0] || null
  }
  function maintenanceAction(category, fallback) {
    const item = dueMaintenanceItem(category)
    if (item?.name === 'ignitionService') return 'Inspect ignition system.'
    return item?.label ? `Service or inspect ${serviceItemLabel(item).toLowerCase()}.` : fallback
  }
  function powerLimitAction(reason, cooling) {
    if (cooling) return maintenanceAction(radiator.value, 'Inspect coolant temperature, level, and the cooling system for faults.')
    const definition = POWER_LIMIT_DEFINITIONS[reason]
    if (definition?.action) return definition.action
    if (reason === 'Severe ignition issue') return maintenanceAction(engine.value, 'Inspect and service the ignition system.')
    if (reason === 'Temporary symptom') return maintenanceAction(engine.value, 'Monitor for recurrence and inspect the engine if the condition becomes frequent.')
    return maintenanceAction(engine.value, 'Inspect the engine if the output restriction persists.')
  }
  function recentSymptom(category, categoryName) {
    const known = ['roughRunning', 'ticking', 'roughIdle', 'torqueDip', 'powerFade', 'stall', 'coolantSeep', 'fanOverwork', 'roughShift', 'shiftDelay', 'slip']
    const observed = recentSymptoms.value[categoryName]
    const type = observed?.symptom || category?.lastFailureType
    const observedAt = observed?.observedAt || Number(category?.lastFailureTime || 0)
    const ageSeconds = Date.now() / 1000 - observedAt
    return known.includes(type) && ageSeconds >= 0 && ageSeconds <= 300 ? type : null
  }
  function activeSymptomText(category) {
    if (category?.activeSymptom === 'stall') return 'Momentary stall'
    if (category?.activeSymptom === 'roughRunning') return 'Rough running'
    if (category?.activeSymptom === 'ticking') return 'Engine ticking'
    return category?.activeSymptomLabel || 'Fault detected'
  }
  function conditionSymptomText(active, recent, definitions, activeFallback) {
    if (active) return definitions[active]?.label || activeFallback || 'Fault detected'
    return recent ? `Recently observed — ${definitions[recent]?.label || 'intermittent condition'}` : 'Normal'
  }
  function engineSymptomFinding(symptom, active) {
    const definition = ENGINE_SYMPTOM_DEFINITIONS[symptom]
    return {
      key: active ? 'engine-symptom' : `stored-engine-${symptom}`,
      severity: 'medium',
      attention: active,
      recent: !active,
      title: active ? `Active ${definition?.label || 'engine condition'}` : `Recently observed — ${definition?.label || 'engine condition'}`,
      cause: active
        ? 'An intermittent engine condition is currently active.'
        : 'The vehicle maintenance system recorded an intermittent engine condition.',
      effect: definition?.effect || 'Engine response or combustion quality may be affected.',
      action: maintenanceAction(engine.value, 'Monitor for recurrence and inspect the engine if the condition becomes frequent.'),
    }
  }
  function coolingSymptomFinding(symptom, active) {
    const definition = COOLING_SYMPTOM_DEFINITIONS[symptom]
    return {
      key: active ? 'cooling-symptom' : `stored-cooling-${symptom}`,
      severity: 'medium',
      attention: active,
      recent: !active,
      title: active ? `Active ${definition?.label || 'cooling-system condition'}` : `Recently observed — ${definition?.label || 'cooling-system condition'}`,
      cause: active
        ? 'An intermittent cooling-system condition is currently active.'
        : 'The vehicle maintenance system recorded an intermittent cooling-system condition.',
      effect: definition?.effect || 'Cooling-system operation may be affected.',
      action: maintenanceAction(radiator.value, 'Monitor for recurrence and inspect the cooling system if the condition becomes frequent.'),
    }
  }
  function transmissionSymptomFinding(symptom, active) {
    const definition = TRANSMISSION_SYMPTOM_DEFINITIONS[symptom]
    const dueItem = dueMaintenanceItem(transmission.value)
    const highMileage = ageMiles(transmission.value) >= 200000
    const cause = dueItem
      ? `${serviceItemLabel(dueItem)} is at or below its service threshold.`
      : (highMileage
          ? 'Accumulated transmission mileage can cause intermittent shift-quality changes.'
          : 'The event may be related to temporary load or temperature conditions.')
    return {
      key: active ? 'transmission-symptom' : `stored-transmission-${symptom}`,
      severity: 'medium',
      attention: active,
      recent: !active,
      title: `${active ? 'Active' : 'Intermittent'} ${definition?.label || 'transmission condition'}`,
      cause,
      effect: definition?.effect || 'Shift response or torque transfer may be affected.',
      action: maintenanceAction(transmission.value, symptom === 'slip'
        ? 'Inspect the transmission and clutch if slipping returns.'
        : 'Monitor for recurrence and inspect the transmission if the condition becomes frequent.'),
    }
  }
  function nativeDamageFinding(event) {
    const definition = NATIVE_DAMAGE_DEFINITIONS[event?.name]
    if (!definition) return null
    const active = event.active === true
    return {
      key: `native-${event.group}-${event.name}`,
      severity: definition.severity || 'medium',
      attention: active,
      recent: !active,
      title: `${active ? 'Active — ' : 'Recently observed — '}${definition.title}`,
      cause: definition.cause, effect: definition.effect, action: definition.action,
    }
  }
  function friendlyFindingCause(reason) {
    return POWER_LIMIT_DEFINITIONS[reason]?.cause || 'The powertrain has applied a protective output reduction.'
  }
  function friendlyTransmissionType(value) {
    if (!value) return null
    const normalized = String(value).replace(/([a-z])([A-Z])/g, '$1 $2').replace(/[_-]+/g, ' ').toLowerCase()
    if (normalized.includes('dct')) return 'Dual-clutch'
    if (normalized.includes('cvt')) return 'CVT'
    if (normalized.includes('automatic')) return 'Automatic'
    if (normalized.includes('manual')) return 'Manual'
    return null
  }
  function friendlyLimitReason(reason) {
    return POWER_LIMIT_DEFINITIONS[reason]?.status || (reason ? `Reduced — ${reason}` : 'Reduced')
  }
  function diagnosticRiskLabel(risk) {
    if (risk?.scannerLabel) return risk.scannerLabel
    if (DIAGNOSTIC_RISK_DEFINITIONS[risk?.key]) return DIAGNOSTIC_RISK_DEFINITIONS[risk.key].label
    if (/_due$/.test(risk?.key || '')) return 'Service overdue'
    return null
  }
  function categoryFluid(categoryKey) {
    if (categoryKey === 'engine') return 'oil'
    if (categoryKey === 'radiator') return 'coolant'
    if (categoryKey === 'transmission') return 'transmission fluid'
    return 'fluid'
  }
  function ageFluidLossPresentation(category, categoryKey) {
    if (categoryKey !== 'radiator') {
      const fluid = categoryFluid(categoryKey)
      return {
        label: 'Age-related fluid consumption',
        detail: `Component age is increasing ${fluid} consumption.`,
      }
    }

    // Coolant circulates through both the engine and cooling system. Match the
    // maintenance model's first age-related loss threshold when identifying the
    // component group responsible for the warning.
    const ageThresholdMiles = 50000
    const engineAged = ageMiles(engine.value) >= ageThresholdMiles
    const coolingAged = ageMiles(category) >= ageThresholdMiles
    const source = engineAged && coolingAged
      ? 'Engine and cooling-system age'
      : engineAged
        ? 'Engine age'
        : coolingAged
          ? 'Cooling-system age'
          : 'Age-related wear'

    return {
      label: `${source} is increasing coolant consumption`,
      detail: 'Age-related wear is increasing coolant loss.',
    }
  }
  function wearSpikePresentation(category, categoryKey) {
    const lowFluidMultiplier = Number(category?.lowFluidConditionMultiplier)
    if (Number.isFinite(lowFluidMultiplier) && lowFluidMultiplier > 1.05) {
      const fluid = categoryFluid(categoryKey)
      return {
        label: `Low ${fluid} level is increasing wear`,
        detail: `Restore the ${fluid} level to reduce component wear.`,
      }
    }

    const mileageMultiplier = Number(category?.levelMileageMultiplier)
    const driveMultipliers = Object.values(category?.driveMultipliers || {}).filter(isNumber)
    const highestDrivingMultiplier = driveMultipliers.length ? Math.max(...driveMultipliers) : null
    if (Number.isFinite(mileageMultiplier) && mileageMultiplier >= 1.45
        && (!isNumber(highestDrivingMultiplier) || highestDrivingMultiplier < 1.45)) {
      return ageFluidLossPresentation(category, categoryKey)
    }

    return DIAGNOSTIC_RISK_DEFINITIONS.wear_spike
  }
  function diagnosticRisks(risks, category = null, categoryKey = null) {
    const list = Array.isArray(risks) ? risks : Object.values(risks || {})
    return list.map(risk => {
      let presentation = null
      if (risk?.key === 'wear_spike') presentation = wearSpikePresentation(category, categoryKey)
      if (risk?.key === 'age_fluid_loss') {
        presentation = ageFluidLossPresentation(category, categoryKey)
      }
      if (risk?.key === 'fluid_neglect') {
        const fluid = categoryFluid(categoryKey)
        presentation = {
          label: `Low ${fluid} level is accelerating fluid loss`,
          detail: `Restore the ${fluid} to its correct level.`,
        }
      }
      if (!presentation) return risk
      return { ...risk, scannerLabel: presentation.label, scannerDetail: presentation.detail }
    }).filter(risk => diagnosticRiskLabel(risk))
  }
  function diagnosticRiskDetail(risk) {
    if (!risk) return null
    if (risk.scannerDetail) return risk.scannerDetail
    const definition = DIAGNOSTIC_RISK_DEFINITIONS[risk.key]
    if (definition?.detail) return definition.detail
    const dueItem = String(risk.key || '').match(/^(.+)_due$/)?.[1]
    if (dueItem) return SERVICE_DUE_DETAILS[dueItem] || 'Service or inspection needed.'
    const detail = risk.detail
    if (!detail) return null
    if (/drive multiplier|limit stress|per sec/i.test(detail)) return null
    return detail.replace(/([0-9.]+) C simulated/i, (_, value) => `Estimated temperature ${temperature(Number(value))}`)
  }
  function dueText(item) {
    const due = item.dueMiles ?? item.serviceDueMilesRemaining
    if (typeof due !== 'number') return null
    return due <= 0 ? 'Service due now' : `Estimated service due in ${distanceMiles(due)}`
  }

  return {
    POWER_LIMIT_DEFINITIONS, DIAGNOSTIC_RISK_DEFINITIONS, SERVICE_ITEM_LABELS, SERVICE_DUE_DETAILS, TRANSMISSION_SYMPTOM_DEFINITIONS,
    ENGINE_SYMPTOM_DEFINITIONS, COOLING_SYMPTOM_DEFINITIONS, NATIVE_DAMAGE_DEFINITIONS, isNumber, isBoolean,
    decimal, whole, temperature, percent, clampPercent,
    power, torque, distanceMiles, ratioList, airPressure,
    boostPressure, serviceConditionSeverity, conditionColor, serviceItemColor, ageMiles,
    mileageWearPercent, mileageWearColor, categoryConditionSeverity, categoryConditionClass, categoryConditionState,
    highIsBadState, elevatedAbove, lowIsBadState, serviceItemLabel, dueMaintenanceItem,
    maintenanceAction, powerLimitAction, recentSymptom, activeSymptomText, conditionSymptomText,
    engineSymptomFinding, coolingSymptomFinding, transmissionSymptomFinding, nativeDamageFinding, friendlyFindingCause,
    friendlyTransmissionType, friendlyLimitReason, diagnosticRiskLabel, categoryFluid, ageFluidLossPresentation,
    wearSpikePresentation, diagnosticRisks, diagnosticRiskDetail, dueText,
  }
}
