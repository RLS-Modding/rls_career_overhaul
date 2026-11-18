// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

import { ref } from 'vue'

// Notification Center: every notification the phone received this session, newest first, until the
// player opens or clears it. Kept in sessionStorage so a UI reload does not lose it.
const STORAGE_KEY = 'phone_notification_center'
const CAREER_KEY = 'phone_notification_center_career'
const MAX_ENTRIES = 60

function readStored() {
  try {
    const stored = JSON.parse(sessionStorage.getItem(STORAGE_KEY) || '[]')
    return Array.isArray(stored) ? stored.filter(entry => entry && typeof entry === 'object' && entry.id) : []
  } catch {
    return []
  }
}

const entries = ref(readStored())
let nextId = entries.value.reduce((highest, entry) => Math.max(highest, Number(String(entry.id).split('-')[1]) || 0), 0) + 1

function save(next) {
  entries.value = next
  try {
    sessionStorage.setItem(STORAGE_KEY, JSON.stringify(next))
  } catch { /* storage full or blocked: the list still works for this UI session */ }
}

// Adds a normalized notification. One with the same replaceKey as an earlier one (an updated offer)
// takes its place instead of adding a second entry, and keeps its id, so a banner still showing the
// earlier version stays tied to the entry and leaves with it.
export function recordPhoneNotification(payload, now = Date.now()) {
  if (!payload || typeof payload !== 'object') return null
  const replaced = payload.replaceKey ? entries.value.find(old => old.replaceKey === payload.replaceKey) : null
  const entry = { ...payload, id: replaced ? replaced.id : `nc-${nextId++}`, receivedAt: now }
  delete entry.timeoutId
  const kept = payload.replaceKey ? entries.value.filter(old => old.replaceKey !== payload.replaceKey) : entries.value
  const next = [entry, ...kept]
  save(next.slice(0, MAX_ENTRIES))
  // The oldest beyond the cap leave like a cleared one, so no banner outlives its entry.
  announceRemoved(next.slice(MAX_ENTRIES).map(old => old.id))
  return entry
}

// Surfaces still showing a notification (the banners) follow when it leaves the Notification Center, so a
// cleared or opened notification never pops up again afterwards. Listeners get the removed entry ids.
const removalListeners = new Set()

export function onNotificationCenterRemoved(listener) {
  removalListeners.add(listener)
  return () => removalListeners.delete(listener)
}

function announceRemoved(ids) {
  if (!ids.length) return
  for (const listener of removalListeners) listener(ids)
}

export function removeNotificationCenterEntries(ids) {
  const gone = new Set(ids.filter(Boolean))
  if (!gone.size) return
  save(entries.value.filter(entry => !gone.has(entry.id)))
  announceRemoved([...gone])
}

// The list belongs to the career it was collected in. Whenever a career loads (the phone extension says
// which) and after a UI reload (the overlay asks), the career loaded now is reported here: the same one
// keeps its list, a different one, or none, drops it.
// Also kept in memory, so a career switch still starts over when storage is blocked.
let careerInMemory = null

function storedCareer() {
  try { return sessionStorage.getItem(CAREER_KEY) ?? careerInMemory } catch { return careerInMemory /* storage blocked */ }
}

// Whether this is the career the list belongs to (or no career has claimed it yet).
export function isNotificationCenterCareer(career) {
  const stored = storedCareer()
  return stored === null || stored === (typeof career === 'string' ? career : '')
}

export function keepNotificationCenterFor(career) {
  const current = typeof career === 'string' ? career : ''
  const stored = storedCareer()
  if (stored !== null && stored !== current) clearNotificationCenter()
  careerInMemory = current
  try { sessionStorage.setItem(CAREER_KEY, current) } catch { /* see above */ }
}

export function clearNotificationCenter() {
  const ids = entries.value.map(entry => entry.id)
  save([])
  announceRemoved(ids)
}

// Where Back leads from the Notification Center: the screen it was pulled down over, or the
// Settings page it was opened from. Taken once, so a stale origin never sticks.
let returnRoute = null

// The whole location, query and hash too, so a screen that keeps its state there (a Guide topic) comes back as left.
export function setNotificationCenterReturn(target) {
  returnRoute = target && target.name
    ? { name: target.name, params: { ...(target.params || {}) }, query: { ...(target.query || {}) }, hash: target.hash || '' }
    : null
}

export function takeNotificationCenterReturn() {
  const target = returnRoute
  returnRoute = null
  return target
}

export function usePhoneNotificationCenter() {
  return { entries }
}
