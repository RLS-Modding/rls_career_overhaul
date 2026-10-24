// Money text for the migration modal's parts. Clamps at 0 and uses the viewer's locale grouping.
// Stays local: utils/units.js formatMoney sets min and max fraction digits together, keeps the sign and
// shows a dash for NaN and Infinity. This copy sets max digits only, clamps at 0, reads NaN as 0 and prints Infinity.
// profile_screens_adoption_test.cjs pins each difference, so an adapter that changes any of them fails loudly.

export function formatMoney(value, maximumFractionDigits = 0) {
  return Math.max(0, Number(value) || 0).toLocaleString(undefined, { maximumFractionDigits })
}
