/**
 * Preinstalled apps (manifest systemApp: true) are always available and never removable; the
 * default dock holds four (manifest defaultDock); default home apps come from manifest
 * defaultHome ({id, slot, required}). All are filled in place from the discovered app manifests
 * (phoneAppCatalog.js), so importers keep their references.
 */
export const DOCK_APP_IDS = []
export const PREINSTALLED_APP_IDS = []

export const SYSTEM_APP_IDS = new Set()

export const DEFAULT_DOCK_APP_IDS = []

export const DEFAULT_HOME_APPS = []

export function setCatalogLayoutDefaults({ systemAppIds = [], dockAppIds = [], defaultHomeApps = [] } = {}) {
  PREINSTALLED_APP_IDS.length = 0
  PREINSTALLED_APP_IDS.push(...systemAppIds)
  SYSTEM_APP_IDS.clear()
  systemAppIds.forEach(id => SYSTEM_APP_IDS.add(id))
  for (const list of [DOCK_APP_IDS, DEFAULT_DOCK_APP_IDS]) {
    list.length = 0
    list.push(...dockAppIds)
  }
  DEFAULT_HOME_APPS.length = 0
  DEFAULT_HOME_APPS.push(...defaultHomeApps.map(entry => ({ ...entry })))
}

export const LAYOUT_VERSION = 11

export function toSlotArray(value) {
  if (Array.isArray(value)) return [...value]
  if (value && typeof value === 'object') {
    const numericKeys = Object.keys(value)
      .filter(k => /^\d+$/.test(k))
      .sort((a, b) => Number(a) - Number(b))
    if (numericKeys.length > 0) return numericKeys.map(k => value[k])
    return Object.values(value)
  }
  return []
}

export function toIdList(value) {
  return toSlotArray(value).filter(v => typeof v === 'string' && v.length > 0)
}

function normalizePagesRaw(layout, appsPerPage) {
  const pagesSource = toSlotArray(layout?.pages)
  if (!pagesSource.length) {
    return [new Array(appsPerPage).fill(null)]
  }
  return pagesSource.map(p => {
    const raw = toSlotArray(p && typeof p === 'object' && 'apps' in p ? p.apps : p)
      .slice(0, appsPerPage)
      .map(v => (v && v !== '') ? v : null)
    while (raw.length < appsPerPage) raw.push(null)
    return raw.slice(0, appsPerPage)
  })
}

function pagesToSaveFormat(pageLayouts) {
  return pageLayouts.map(p => ({ apps: p.map(id => id || '') }))
}

function dockToSaveFormat(dockIds) {
  return dockIds.map(id => id || '')
}

export function isAppInstalled(layout, appId) {
  return toIdList(layout?.installedAppIds).includes(appId)
}

export function installAppOnLayout(layout, appId, appsPerPage = 16) {
  if (!layout || !appId || SYSTEM_APP_IDS.has(appId)) return layout

  const installed = new Set(toIdList(layout.installedAppIds))
  if (installed.has(appId)) return layout
  installed.add(appId)
  layout.installedAppIds = [...installed]

  const removed = new Set(toIdList(layout.removedAppIds))
  removed.delete(appId)
  layout.removedAppIds = [...removed]

  const pageLayouts = normalizePagesRaw(layout, appsPerPage)
  const dockIds = toSlotArray(layout.dock || DEFAULT_DOCK_APP_IDS)
    .slice(0, 4)
    .map(v => (v && v !== '') ? v : null)
  while (dockIds.length < 4) dockIds.push(null)

  const placed = new Set([
    ...dockIds.filter(Boolean),
    ...pageLayouts.flat().filter(Boolean),
  ])
  if (placed.has(appId)) {
    layout.pages = pagesToSaveFormat(pageLayouts)
    layout.dock = dockToSaveFormat(dockIds)
    return layout
  }

  for (const page of pageLayouts) {
    const emptyIdx = page.indexOf(null)
    if (emptyIdx !== -1) {
      page[emptyIdx] = appId
      layout.pages = pagesToSaveFormat(pageLayouts)
      layout.dock = dockToSaveFormat(dockIds)
      return layout
    }
  }

  const newPage = new Array(appsPerPage).fill(null)
  newPage[appsPerPage - 1] = appId
  pageLayouts.push(newPage)
  layout.pages = pagesToSaveFormat(pageLayouts)
  layout.dock = dockToSaveFormat(dockIds)
  return layout
}

export function uninstallAppFromLayout(layout, appId, appsPerPage = 16) {
  if (!layout || !appId || SYSTEM_APP_IDS.has(appId)) return layout

  const installed = new Set(toIdList(layout.installedAppIds))
  if (!installed.has(appId)) return layout
  installed.delete(appId)
  layout.installedAppIds = [...installed]

  const removed = new Set(toIdList(layout.removedAppIds))
  removed.add(appId)
  layout.removedAppIds = [...removed]

  const pageLayouts = normalizePagesRaw(layout, appsPerPage)
  const dockIds = toSlotArray(layout.dock || DEFAULT_DOCK_APP_IDS)
    .slice(0, 4)
    .map(v => (v && v !== '') ? v : null)
  while (dockIds.length < 4) dockIds.push(null)

  for (let p = 0; p < pageLayouts.length; p++) {
    const idx = pageLayouts[p].indexOf(appId)
    if (idx !== -1) pageLayouts[p][idx] = null
  }

  const dockIdx = dockIds.indexOf(appId)
  if (dockIdx !== -1) dockIds[dockIdx] = null

  layout.pages = pagesToSaveFormat(pageLayouts)
  layout.dock = dockToSaveFormat(dockIds)
  return layout
}

export function collectInstalledFromLayout(layout) {
  const ids = new Set(PREINSTALLED_APP_IDS)
  toIdList(layout?.installedAppIds).forEach(id => ids.add(id))
  toSlotArray(layout?.dock).filter(Boolean).forEach(id => ids.add(id))
  for (const page of normalizePagesRaw(layout, 16)) {
    page.filter(Boolean).forEach(id => ids.add(id))
  }
  return [...ids]
}
