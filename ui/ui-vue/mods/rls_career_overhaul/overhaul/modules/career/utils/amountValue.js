// Shared numeric policy for pad steps, presets and optional keyboard entry.
export function amountValue(value, { min = 0, max = Number.MAX_SAFE_INTEGER, step = 1 } = {}) {
  const number = Number(value)
  if (value === '' || !Number.isFinite(number) || !(step > 0) || max < min) return null
  const clamped = Math.min(max, Math.max(min, number))
  // Quantise from min and round floating point noise for currency/fractional steps.
  const snapped = min + Math.round((clamped - min) / step) * step
  return Number(Math.min(max, Math.max(min, snapped)).toFixed(8))
}
