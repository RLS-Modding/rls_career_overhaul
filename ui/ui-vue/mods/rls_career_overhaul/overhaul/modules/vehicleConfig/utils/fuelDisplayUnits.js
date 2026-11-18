// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// Volume, weight, power and temperature in the player's game units (BeamNG UIUnits).
// Fuel data stays in litres, kg, mechanical hp and °C; only what is shown or typed converts.
const PS_PER_HP = 0.7457 / 0.7355 // panel power figures are mechanical hp; UIUnits.power takes metric PS

export function fuelDisplayUnits(units, systems) {
  const volume = units.volume(1, systems.volume) || units.volume(1, 'l')
  const power = units.power(1, systems.power) || units.power(1, 'bhp')
  const weight = units.weight(1, systems.weight) || units.weight(1, 'kg')
  const gallons = volume.unit === 'gal'
  const finite = value => Number.isFinite(Number(value))
  const fixed = (value, decimals) => finite(value) ? Number(value).toFixed(decimals) : '—'
  const grouped = value => finite(value) ? Math.round(Number(value)).toLocaleString() : '—'
  const toVolume = liters => Number(liters) * volume.val

  return {
    volumeUnit: volume.unit,
    volumeName: gallons ? 'Gallons' : 'Liters',
    flowUnit: `${volume.unit}/h`,
    powerUnit: power.unit,
    // Amount shortcuts in round numbers of the chosen unit.
    presets: gallons ? [2, 5, 10] : [5, 10, 20],
    weightUnit: weight.unit,
    weightName: weight.unit === 'kg' ? 'Kilograms' : 'Pounds',
    weightPresets: weight.unit === 'kg' ? [0.5, 1, 2] : [1, 2, 5],
    toVolume,
    toWeight: kg => Number(kg) * weight.val,
    fromWeight: value => Number(value) / weight.val,
    perWeight: pricePerKg => Number(pricePerKg) / weight.val,
    weight: (kg, decimals = 1) => fixed(Number(kg) * weight.val, decimals),
    fromVolume: value => Number(value) / volume.val,
    perVolume: pricePerLiter => Number(pricePerLiter) / volume.val,
    volume: (liters, decimals = 1) => fixed(toVolume(liters), decimals),
    flow: litersPerSecond => grouped(toVolume(Number(litersPerSecond) * 3600)),
    powerValue: hp => Number(hp) * PS_PER_HP * power.val,
    power: hp => grouped(Number(hp) * PS_PER_HP * power.val),
    temperature: (celsius, decimals = 0) => finite(celsius) ? units.buildString('temperature', Number(celsius), decimals, systems.temperature) : '—',
    // A temperature difference (charge cooling) scales but never takes the °F offset.
    temperatureDelta: (celsius, decimals = 0) => {
      const unit = (units.temperature(0, systems.temperature) || units.temperature(0, 'c')).unit
      return finite(celsius) ? `${fixed(Number(celsius) * (unit === '°F' ? 1.8 : 1), decimals)} ${unit}` : '—'
    },
  }
}
