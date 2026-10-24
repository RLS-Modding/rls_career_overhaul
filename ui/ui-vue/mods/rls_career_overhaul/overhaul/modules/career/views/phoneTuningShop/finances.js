// Pure 24 h finance projection for the phone Tuning Shop. The view passes its transactions, its balance and a clock;
// nothing here reads the store, the bridge or the global Date, so the view's clock (and tests' fixed clock) applies.

export const CHART_WIDTH = 320
export const CHART_HEIGHT = 100
export const CHART_PADDING = 8
const DAY_SECONDS = 86400

// The opening balance is rebuilt by taking every transaction back off the current balance. The transactions are
// then replayed in timestamp order. Points older than 24 h are dropped. The first kept point already carries the
// balance after the dropped transactions, so an in-window transaction that follows an old one is missing from the
// period change. This is the current behaviour.
export function buildHistoryPoints(transactions, accountBalance, nowSeconds) {
  if (!transactions || transactions.length === 0) {
    return [{ balance: accountBalance, timestamp: nowSeconds() }]
  }
  const sorted = [...transactions].sort((a, b) => (a.timestamp || 0) - (b.timestamp || 0))
  let initial = accountBalance
  for (let i = sorted.length - 1; i >= 0; i--) initial -= (sorted[i].amount || 0)
  let running = initial
  const points = [{ balance: initial, timestamp: sorted[0]?.timestamp || nowSeconds() }]
  for (const t of sorted) {
    running += (t.amount || 0)
    points.push({ balance: running, timestamp: t.timestamp })
  }
  points.push({ balance: accountBalance, timestamp: nowSeconds() })
  const cutoff = nowSeconds() - DAY_SECONDS
  return points.filter(p => p.timestamp >= cutoff)
}

export function periodChangeOf(points) {
  if (points.length === 0) return 0
  return points[points.length - 1].balance - points[0].balance
}

function chartPoints(points) {
  if (points.length === 0) return []
  const first = points[0].timestamp, last = points[points.length - 1].timestamp
  const timeRange = last - first || 1
  const balances = points.map(p => p.balance)
  const min = Math.min(...balances), max = Math.max(...balances)
  const range = max - min || 1
  return points.map(p => ({
    x: ((p.timestamp - first) / timeRange) * CHART_WIDTH,
    y: CHART_HEIGHT - CHART_PADDING - (((p.balance - min) / range) * (CHART_HEIGHT - 2 * CHART_PADDING)) - CHART_PADDING
  }))
}

// SVG path data for the filled area (closed down to the baseline) and for the line on top of it.
export function chartPathsOf(points) {
  const pts = chartPoints(points)
  if (pts.length === 0) return { area: '', line: '' }
  const first = pts[0], last = pts[pts.length - 1]
  const lineTo = pts.slice(1).map(p => ` L ${p.x} ${p.y}`).join('')
  return {
    area: `M ${first.x} ${CHART_HEIGHT} L ${first.x} ${first.y}${lineTo} L ${last.x} ${CHART_HEIGHT} Z`,
    line: `M ${first.x} ${first.y}${lineTo}`,
  }
}
