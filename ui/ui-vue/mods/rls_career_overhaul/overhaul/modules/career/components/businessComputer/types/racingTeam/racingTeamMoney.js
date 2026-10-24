import { formatMoney } from "../../../../utils/units.js"

// Pass the host's locale explicitly so these cards keep their grouping if a caller later supplies game units.
const HOST_LOCALE = new Intl.NumberFormat().resolvedOptions().locale

// Whole-number money for the racing cards, digits from the shared formatter. The card's own edges are kept:
// a non-finite amount shows "0", Math.round sends halves toward +Infinity (-2.5 shows -2), and an amount
// that rounds to negative zero keeps its sign. Negative text stays native because ICU locales may use
// directional marks or a different minus sign and digit set.
export function formatWholeMoney(value) {
  const n = Number(value)
  if (!Number.isFinite(n)) return "0"
  const rounded = Math.round(n)
  if (rounded < 0 || Object.is(rounded, -0)) return rounded.toLocaleString(HOST_LOCALE)
  return formatMoney(rounded, { decimals: 0, locale: HOST_LOCALE })
}
