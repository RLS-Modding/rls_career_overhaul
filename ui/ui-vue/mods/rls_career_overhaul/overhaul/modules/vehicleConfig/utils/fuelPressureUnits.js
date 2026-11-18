// Saved boost calibration is PSI; UI conversion follows BeamNG's pressure service.
export function fuelPressureUnits(units, system) {
  const base = units.pressure(1, 'psi').val
  const selected = units.pressure(1, system) || units.pressure(1, 'psi')
  const factor = selected.val / base
  const toDisplay = psi => Number(psi) * factor
  const fromDisplay = value => Number(value) / factor
  const text = psi => Number.isFinite(Number(psi)) ? units.buildString('pressure', Number(psi) / base, 2, system) : '--'
  return { unit: selected.unit, factor, toDisplay, fromDisplay, text,
    step: system === 'bar' ? .01 : .1,
    kPaText: value => Number.isFinite(Number(value)) ? units.buildString('pressure', Number(value), 2, system) : '--' }
}
