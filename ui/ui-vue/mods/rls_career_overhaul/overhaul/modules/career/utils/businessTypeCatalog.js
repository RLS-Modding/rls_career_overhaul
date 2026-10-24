// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

import { createCatalog } from './platformCatalog'
import { runtimeComponent } from './runtimeComponent'
import { BUILTIN_BUSINESS_TYPES } from './builtinBusinessTypes.js'

const catalog = createCatalog('overhaul/lib/business/typeCatalog', 'businessTypeCatalog', BUILTIN_BUSINESS_TYPES)
const components = new Map()
export const businessTypes = catalog.entries
export const businessTypesReady = catalog.ready
export const ensureBusinessTypes = catalog.ensure
export const retryBusinessTypesWhileMounted = catalog.retryWhileMounted
// Component paths are cache keys: changing a path resolves a new component naturally.
// A failed refresh must not discard the still-mounted last good component.
export function loadBusinessTypes(options) { return catalog.load(options) }
export function setBusinessTypeManifests(entries) { return catalog.set(entries) }

export function businessComponentNames() {
  const aliases = new Map()
  for (const type of businessTypes.value) {
    for (const tab of type.tabs) if (tab.componentName && !aliases.has(tab.componentName)) aliases.set(tab.componentName, tab.componentOrder ?? 999)
    for (const view of type.views || []) if (!aliases.has(view.id)) aliases.set(view.id, view.componentOrder ?? 999)
  }
  return [...aliases].sort(([a, oa], [b, ob]) => oa - ob || (a < b ? -1 : a > b ? 1 : 0)).map(([id]) => id)
}

// What a type declares before its first payload arrives. Pushed type data (manager.getTypeData) stays
// authoritative; this only keeps the screen usable while that reply is in flight.
// Only the type's own descriptor (id === type) speaks for it; manifests that merely add tabs through
// `businessType` contribute presentation (projectBusinessTabs), never the owner module or policy.
export function businessTypeFacts(businessType) {
  const primary = businessTypes.value.find(type => type.id === businessType)
  return {
    module: primary?.module,
    sections: Array.isArray(primary?.sections) ? primary.sections : [],
    capabilities: { ...primary?.capabilities },
    skillNodes: { ...primary?.skillNodes },
  }
}

export function businessTypeHasCapability(businessType, name) {
  return businessTypeFacts(businessType).capabilities[name] === true
}

export function getBusinessTabComponent(name) {
  for (const type of businessTypes.value) {
    const tab = type.tabs.find(tab => tab.componentName === name || tab.component === name)
    const view = (type.views || []).find(view => view.id === name || view.component === name)
    const file = tab?.component || view?.component
    if (file) {
      if (!components.has(file)) components.set(file, runtimeComponent(file))
      return components.get(file)
    }
  }
  return null
}

// Pure UI projection: never writes supplied tabs, business payloads, Lua state or caches.
// Original tabs keep their order and identity unless a manifest expands one into sections.
export function projectBusinessTabs(businessType, tabs, sectionIds) {
  let result = tabs
  const types = businessTypes.value.filter(type => (type.businessType || type.id) === businessType)
  for (const type of types) {
    // Sections only expand one registered tab; elsewhere they merely name the static tabs.
    if (!type.sections || !type.sourceComponent) continue
    const base = result.find(tab => tab?.component === type.sourceComponent)
    if (!base) continue
    const sections = [...type.sections].filter(section => !Array.isArray(sectionIds) || sectionIds.includes(section.id)).sort((a, b) => (a.order ?? 999) - (b.order ?? 999) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0)).map(section => ({
      ...base, ...section,
      icon: section.icon || base.icon,
      section: base.section || 'BUSINESS',
      data: { ...(base.data || {}), view: section.id },
    }))
    result = [...sections, ...result.filter(tab => tab?.component !== type.sourceComponent)]
  }
  const extras = types.flatMap(type => type.tabs.filter(tab => tab.entry)).sort((a, b) =>
    (a.order ?? 999) - (b.order ?? 999) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0))
  const seen = new Set(result.map(tab => tab.id))
  for (const tab of extras) {
    if (seen.has(tab.id)) continue // dynamic owner wins; registration reports conflicts separately.
    seen.add(tab.id)
    const entry = { id: tab.id, label: tab.label, component: tab.component }
    for (const key of ['icon', 'section', 'order', 'data']) if (tab[key] !== undefined) entry[key] = tab[key]
    const at = result.findIndex(existing => (existing.order ?? 999) > (entry.order ?? 999))
    result = [...result.slice(0, at < 0 ? result.length : at), entry, ...result.slice(at < 0 ? result.length : at)]
  }
  return result
}

// Run at explicit payload acceptance, never while projecting. No built-in causes a warning.
export function reportBusinessTabConflicts(businessType, tabs) {
  const ids = new Set(tabs.map(tab => tab.id))
  for (const type of businessTypes.value) {
    if ((type.businessType || type.id) !== businessType) continue
    for (const tab of type.tabs) if (tab.entry && ids.has(tab.id)) console.warn(`[businessTypeCatalog] dynamic tab '${tab.id}' wins over its manifest entry`)
  }
}
