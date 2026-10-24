// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// Publication belongs to the current UI window, including when uiMods uses two import URLs.
const host = globalThis.window || globalThis
const key = Symbol.for('overhaul.luaScopeDeclarations')
if (!host[key]) host[key] = { acquisitions: Object.create(null), namespaces: [], listeners: new Set(), held: new WeakMap() }
const service = host[key]
const list = value => Array.isArray(value) ? value : Object.values(value || {})

export function setLuaScopeDeclarations(owners) {
  if (!Array.isArray(owners)) return false
  const acquisitions = Object.create(null), namespaces = new Set()
  for (const owner of [...owners].sort((a, b) => a.order - b.order || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0))) {
    if (owner.exports?.namespace) namespaces.add(owner.id)
    for (const row of list(owner.acquisitions)) {
      if (acquisitions[row.id]) continue
      acquisitions[row.id] = Object.freeze({ ...row, extensions: Object.freeze([...list(row.extensions)]),
        release: Object.freeze([...list(row.release)]), modes: Object.freeze(Object.assign(Object.create(null), row.modes)) })
      if (row.namespace !== false) for (const name of acquisitions[row.id].extensions) namespaces.add(name)
    }
  }
  service.acquisitions = acquisitions
  service.namespaces = [...namespaces]
  for (const listener of service.listeners) listener(service.namespaces)
  return true
}

export function findScopeAcquisition(id) { return service.acquisitions[id] }
export function onLuaNamespacesChanged(listener) {
  service.listeners.add(listener)
  listener(service.namespaces)
  return () => service.listeners.delete(listener)
}

// A close uses the declaration that opened it, even if a mod is removed or replaced meanwhile.
export function holdScopeAcquisition(target, id, entry) {
  let held = service.held.get(target)
  if (!held) { held = new Map(); service.held.set(target, held) }
  held.set(id, entry)
}
export function releaseScopeAcquisition(target, id) {
  const held = service.held.get(target)
  const entry = held?.get(id)
  held?.delete(id)
  return entry
}

export function isScopeAcquisitionHeld(target, id, entry) {
  return service.held.get(target)?.get(id) === entry
}
