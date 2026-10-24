// Route metadata is published before phone app definitions, so the phone never offers a page
// before its route exists. No Lua calls, extension loading or component loading in this store.
// uiMods can evaluate one file under two import URLs. Routing belongs to the current UI
// window; share only its metadata service, never a career owner's state or component instances.
import { BUILTIN_PHONE_ROUTES } from './builtinPhoneRoutes.js'

const host = globalThis.window || globalThis
const key = Symbol.for('overhaul.featureRouteCatalog')
if (!host[key]) host[key] = { routes: [], listeners: new Set(), signature: '' }
const service = host[key]
const { routes, listeners } = service
export function routeParent(entry) { return entry.parent ?? (entry.ownerKind === 'phone' ? 'phone-shell' : 'overhaul') }

export function getFeatureRoutes() { return routes }
export function onFeatureRoutesChanged(listener) { listeners.add(listener); return () => listeners.delete(listener) }

function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical)
  if (!value || typeof value !== 'object') return value
  return Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])]))
}

export function setPhoneRouteManifests(apps, discovered, { additive = false } = {}) {
  let published = Array.isArray(discovered) ? [...discovered] : [
    ...routes.filter(route => route.ownerKind === 'ui'),
    ...apps.flatMap(app => (app.uiRoutes || []).map(route => ({ ...route, id: route.name, ownerId: app.id, ownerKind: 'phone' }))),
  ]
  if (additive) {
    // Published apps still use the old routes until their replacement definitions are ready.
    const existingNames = new Set(routes.map(route => route.name))
    const existingPaths = new Set(routes.map(route => route.path))
    published = [...routes, ...published.filter(route => !existingNames.has(route.name) && !existingPaths.has(route.path))]
  }
  // Discovery can replace a built-in, but a missing/failed scan cannot remove its route.
  const names = new Set(published.map(route => route.name))
  const paths = new Set(published.map(route => route.path))
  const entries = [...published, ...BUILTIN_PHONE_ROUTES.filter(route => !names.has(route.name) && !paths.has(route.path))]
    .map(entry => ({ ...entry, parent: routeParent(entry) }))
  entries.sort((a, b) => (a.uiOrder ?? 10000) - (b.uiOrder ?? 10000) || (a.name < b.name ? -1 : a.name > b.name ? 1 : 0))
  const signature = JSON.stringify(canonical(entries))
  if (signature === service.signature) return routes
  service.signature = signature
  routes.splice(0, routes.length, ...entries)
  for (const listener of listeners) {
    try { listener(routes) } catch (err) { console.error('[uiRouteCatalog] route publication failed', err) }
  }
  return routes
}

if (!service.signature) setPhoneRouteManifests([])
