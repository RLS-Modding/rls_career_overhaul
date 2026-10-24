// Display formatting for the real estate phone views. Pure: no state, no bridge.
// The K/M branch is chosen before rounding, so values just under a boundary can
// print as "1000K" or "1000 m". Those outputs are pinned by the characterization test.
// These stay local, not formatMoney: formatPrice's compact K/M suffix and bare digits below 1000 have no
// formatMoney form, and formatDistance is in km/m. Tests pin both.

export function formatPrice(price) {
  if (price >= 1000000) return (price / 1000000).toFixed(1) + 'M'
  if (price >= 1000) return (price / 1000).toFixed(0) + 'K'
  return price.toString()
}

export function formatDistance(meters) {
  if (meters < 0) return '--'
  if (meters >= 1000) return (meters / 1000).toFixed(1) + ' km'
  return Math.round(meters) + ' m'
}

// Hides localization keys that the Lua side sends in place of a real description.
export function cleanDescription(desc) {
  if (desc.startsWith('levels.')) return ''
  return desc
}
