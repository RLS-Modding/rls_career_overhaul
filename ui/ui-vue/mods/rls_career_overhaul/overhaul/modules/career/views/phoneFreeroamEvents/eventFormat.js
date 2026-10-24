// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// Formatting and type tables for the Freeroam Events screen and its parts. Every formatter returns exactly what the
// screen has always shown, including its edge cases (see the comments on each function).
import { formatMoney } from '../../utils/units.js'

// Pull distances are stored in metres and shown in feet.
export const FEET_PER_METER = 3.280839895

export const typeColors = {
  street: '#3b82f6',
  roadracing: '#3b82f6',
  crawling: '#f97316',
  mudding: '#8b5a2b',
  offroad: '#84cc16',
  drift: '#a855f7',
  oval: '#f59e0b',
  drag: '#ef4444',
  trail: '#16a34a',
  landspeed: '#06b6d4',
  topSpeed: '#06b6d4',
  rally: '#22c55e',
  koh: '#d97706',
  demo: '#ef4444',
  burnout: '#f97316',
  burnoutComp: '#fb923c',
  fre: '#64748b',
  freeroam: '#64748b',
  pulling: '#d97706',
}

export const typeLabels = {
  street: 'Street',
  roadracing: 'Road Racing',
  crawling: 'Crawling',
  mudding: 'Mudding',
  offroad: 'Offroad',
  drift: 'Drift',
  oval: 'Oval',
  drag: 'Drag',
  trail: 'Trail',
  landspeed: 'Land Speed',
  topSpeed: 'Top Speed',
  rally: 'Rally',
  koh: 'KOH',
  demo: 'Demolition Derby',
  burnout: 'Burnout',
  burnoutComp: 'Burnout Comp',
  fre: 'Freeroam',
  freeroam: 'Freeroam',
  pulling: 'Tractor Pulling',
}

export function formatTime(seconds) {
  if (!seconds && seconds !== 0) return '--:--:--'
  const sign = seconds < 0 ? '-' : ''
  seconds = Math.abs(seconds)
  const mins = Math.floor(seconds / 60)
  const secs = seconds % 60
  const whole = Math.floor(secs)
  const hundredths = Math.floor((secs - whole) * 100)
  return `${sign}${String(mins).padStart(2, '0')}:${String(whole).padStart(2, '0')}:${String(hundredths).padStart(2, '0')}`
}

// Whole amounts with en-US grouping, rounded by formatMoney. Two cases formatMoney words differently, so they stay
// as this screen shows them: NaN and Infinity print as "NaN" and "∞", and a value that rounds to zero keeps its sign ("-0").
export function formatPrice(val) {
  if (val == null) return '0'
  const n = Number(val)
  if (!Number.isFinite(n)) return n.toLocaleString('en-US')
  const text = formatMoney(n, { decimals: 0, locale: 'en-US' })
  return (n < 0 || Object.is(n, -0)) && !text.startsWith('-') ? `-${text}` : text
}

export function formatPercent(value) {
  const n = Number(value)
  if (!Number.isFinite(n)) return '0%'
  return `${Math.round(n * 100)}%`
}

export function formatPlacement(value) {
  const n = Number(value)
  if (!Number.isFinite(n) || n <= 0) return '--'
  return `#${n.toFixed(2)}`
}

// The km switch reads the unrounded value, so 999.6 m rounds to "1000 m".
export function formatDistance(m) {
  if (m < 0) return '--'
  if (m >= 1000) return (m / 1000).toFixed(1) + ' km'
  return Math.round(m) + ' m'
}

// An event's `types` may be a single string from the payload; treat it as a one-item list.
export function ensureTypesArray(ev) {
  const t = ev?.types
  if (Array.isArray(t)) return t
  return t != null ? [t] : []
}

export function getEventColor(ev) {
  const types = ensureTypesArray(ev)
  if (types.length > 0) return typeColors[types[0]] || '#888'
  return '#888'
}

// Read the event's scoring rule, never infer it from a run's elapsed time.
export function isScoreEvent(ev) {
  return !!(ev.scoreMode || ev.hasDrift || ev.hasBurnout)
}

export function scoreTarget(ev) {
  return ev.scoreGoal ?? ev.driftGoal ?? (ev.hasBurnout ? 6000 : null)
}

export function formatScore(value) {
  return `${Number(value).toLocaleString('en-US', { maximumFractionDigits: 0 })} pts`
}

export function recordValue(ev, rec) {
  if (isScoreEvent(ev)) return rec.driftScore
  if (ev.hasTopSpeed) return rec.topSpeed
  return rec.time
}

export function eventRecords(ev) {
  // The Lua bridge encodes an empty table as {}, rather than [].
  const records = ev.vehicleRecords || []
  return (Array.isArray(records) ? [...records] : Object.values(records)).filter(rec => {
    const value = recordValue(ev, rec)
    return typeof value === 'number' && Number.isFinite(value) && value >= 0
  }).sort((a, b) => (isScoreEvent(ev) || ev.hasTopSpeed ? -1 : 1) * (recordValue(ev, a) - recordValue(ev, b)))
}

export function personalBest(ev) {
  const rec = eventRecords(ev)[0]
  return rec || {
    vehicleName: ev.currentVehicleName,
    driftScore: ev.currentVehicleBestScore,
    time: ev.currentVehicleBestTime,
    topSpeed: ev.currentVehicleBestTopSpeed,
  }
}

export function bestLabel(ev) {
  return isScoreEvent(ev) ? 'Best score' : ev.hasTopSpeed ? 'Best speed' : 'Best time'
}

export function bestValue(ev, rec = personalBest(ev)) {
  const value = recordValue(ev, rec)
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 0) return 'No result yet'
  return isScoreEvent(ev) ? formatScore(value) : ev.hasTopSpeed ? `${value.toFixed(1)} mph` : formatTime(value)
}
