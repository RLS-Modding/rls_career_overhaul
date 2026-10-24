// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// Retain Lua's opening snapshot before the route mounts. uiMods can import this service through
// multiple URLs, so all copies in this UI window share the same snapshot and event binding.
import { replacePhoneSettings } from '../composables/usePhoneSettings'
import { clearPhoneImages, preloadPhoneImages } from './phoneAppRegistry'
import { ref } from 'vue'

const host = globalThis.window || globalThis
const key = Symbol.for('overhaul.phoneShellState')
if (!host[key]) host[key] = { snapshot: null, dispose: null, visible: ref(false) }
const service = host[key]
// A watched reload can retain a snapshot created before visibility was observed.
service.visible ??= ref(false)

export function isPhoneShellVisible() { return service.visible.value }
export function setPhoneShellVisible(visible) { service.visible.value = visible }

export function readPhoneShellState() {
  return service.snapshot
}

export function startPhoneShellState(events) {
  service.dispose?.()
  const stateChanged = data => {
    if (!data || typeof data !== 'object') return
    service.snapshot = data
    if (data.layout?.settings) replacePhoneSettings(data.layout.settings)
    preloadPhoneImages(data.layout)
  }
  const layoutChanged = layout => {
    if (service.snapshot) service.snapshot = { ...service.snapshot, layout }
    if (layout?.settings) replacePhoneSettings(layout.settings)
    preloadPhoneImages(layout)
  }
  const timeChanged = time => {
    if (service.snapshot) service.snapshot = { ...service.snapshot, time }
  }
  const statusChanged = status => {
    if (service.snapshot) service.snapshot = { ...service.snapshot, ...status }
  }
  events.on('phoneShellState', stateChanged)
  events.on('phoneLayoutData', layoutChanged)
  events.on('phone_time_update', timeChanged)
  events.on('phoneShellStatus', statusChanged)
  service.dispose = () => {
    events.off('phoneShellState', stateChanged)
    events.off('phoneLayoutData', layoutChanged)
    events.off('phone_time_update', timeChanged)
    events.off('phoneShellStatus', statusChanged)
  }
}

export function stopPhoneShellState() {
  service.dispose?.()
  service.dispose = null
  service.snapshot = null
  service.visible.value = false
  clearPhoneImages()
}
