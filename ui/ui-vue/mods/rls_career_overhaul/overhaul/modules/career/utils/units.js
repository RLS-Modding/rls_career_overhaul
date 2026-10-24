// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

export const METERS_PER_MILE = 1609.344

// Dyno data reports metric hp (PS) but some sources send watts. No engine makes 10,000 PS, so a larger
// number is taken to be watts; one watt is this many PS.
export const WATTS_TO_METRIC_HP = 0.00135962
const DYNO_POWER_WATTS_THRESHOLD = 10000
export const dynoPowerToPs = value => (value > DYNO_POWER_WATTS_THRESHOLD ? value * WATTS_TO_METRIC_HP : value)

// Odometer / route distance in the player's length unit, always the large unit (km or mi):
// units.buildString("length") drops to m/cm/mm (ft/in) for short values, so 0 would read "0 mm".
// `units` is useBridge().units; the factor comes from the game's own length conversion.
export function bigLengthUnit(units) {
  const ref = units?.length?.(1000) // { val, unit } for 1 km: { 1, "km" } or { 0.62, "mi" }
  return ref ? { perMetre: ref.val / 1000, unit: ref.unit } : { perMetre: 0.001, unit: "km" }
}

export function formatOdometer(units, metres, decimals = 0) {
  const { perMetre, unit } = bigLengthUnit(units)
  const val = Math.max(0, Number(metres) || 0) * perMetre
  const text = Intl.NumberFormat(units?.userSettings?.uiLanguage || undefined, {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  }).format(val)
  return `${text} ${unit}`
}

// Vehicle shop range filters hold values in the unit the player sees (km/mi, PS/bhp/kW, kg/lbs);
// dataPerUnit turns them back into the listing fields (Mileage metres, Power PS, Weight kg).
export function shopFilterUnit(units, field) {
  if (field === "Mileage") {
    const { perMetre, unit } = bigLengthUnit(units)
    return { label: unit, dataPerUnit: 1 / perMetre }
  }
  const ref = field === "Power" ? units?.power?.(1) : field === "Weight" ? units?.weight?.(1) : null
  if (ref && ref.val > 0) return { label: ref.unit, dataPerUnit: 1 / ref.val }
  return { label: field === "Power" ? "PS" : field === "Weight" ? "kg" : "", dataPerUnit: 1 }
}

// Plain-text money (prompts, tooltips, option labels, toasts) is a localized amount.
// Render currency in markup with BngUnit :money, or MoneyAmount around formatted text.
// Never put a currency name or HTML in strings sent to text-only renderers.
export function moneyText(units, value, { decimals = 2 } = {}) {
  return formatMoney(value, { units, decimals })
}

export function formatMoney(value, { decimals = 2, locale, units } = {}) {
  const n = Number(value)
  if (!Number.isFinite(n)) return "—"
  const text = Intl.NumberFormat(locale || units?.userSettings?.uiLanguage || undefined, {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  }).format(Math.abs(n))
  // Keep the sign before the amount; an amount that rounds to zero has no sign.
  const negative = n < 0 && Number(Math.abs(n).toFixed(decimals)) !== 0
  return `${negative ? "-" : ""}${text}`
}
