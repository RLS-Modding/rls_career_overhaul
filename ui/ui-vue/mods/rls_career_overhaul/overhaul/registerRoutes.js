// Overhaul's Vue routes, added to the game's router at runtime.
import coreSnapshot from "./modules/career/utils/builtinCoreUi"
import routes from "./modules/career/routes.js"
import { getFeatureRoutes, onFeatureRoutesChanged, routeParent } from "./modules/career/utils/uiRouteCatalog.js"
import { runtimeRouteComponent, loadRuntimeComponent } from "./modules/career/utils/runtimeComponent.js"

const SOURCE = "overhaul"
let registered = false

// Core hosts define the only allowed parents. Feature rows cannot create nesting
// cycles; sorting and metadata stay local to each host.
export function buildOverhaulRoutes() {
  const entries = getFeatureRoutes()
  const byName = new Map(entries.map(entry => [entry.name, entry]))
  function depth(entry, seen = new Set()) {
    if (!entry || entry.name === 'phone-main') return 0
    if (seen.has(entry.name)) return 1
    seen.add(entry.name)
    return 1 + depth(byName.get(entry.backTarget), seen)
  }
  const absolutePath = path => path.startsWith('/') ? path : `/overhaul/${path}`
  function strip(route) {
    const { platformOrder, hostsChildren, children, ...definition } = route
    if (children) definition.children = [...children]
      .sort((a, b) => (a.platformOrder ?? 10000) - (b.platformOrder ?? 10000) || a.name.localeCompare(b.name))
      .map(strip)
    return definition
  }
  return routes.map(root => {
    if (!root.children) return root
    const children = root.children.map(route => ({ ...route, ...(route.children ? { children: [...route.children] } : {}) }))
    const hosts = new Map([['overhaul', { children }], ...children.filter(route => route.hostsChildren).map(route => [route.name, route])])
    const existing = children.flatMap(route => [route, ...(route.children || [])])
    const names = new Set(existing.map(route => route.name))
    const paths = new Set(existing.map(route => absolutePath(route.path)))
    for (const entry of entries) {
      const path = absolutePath(entry.path)
      if (names.has(entry.name) || paths.has(path)) continue
      names.add(entry.name); paths.add(path)
      let parent = routeParent(entry)
      if (!hosts.has(parent)) {
        console.warn(`[overhaul] Unknown route parent '${parent}' in ${entry.ownerId || entry.id || entry.name}; attaching '${entry.name}' to overhaul`)
        parent = 'overhaul'
      }
      const route = { path, name: entry.name, platformOrder: entry.uiOrder ?? 10000,
        component: runtimeRouteComponent(entry.component, { phone: parent === 'phone-shell' }) }
      if (entry.props !== undefined) route.props = entry.props
      if (entry.meta !== undefined) route.meta = entry.meta
      if (parent === 'phone-shell') {
        const phone = { appId: entry.props?.appId ?? entry.ownerId, depth: depth(entry) }
        if (entry.title !== undefined) phone.title = entry.title
        route.meta = { ...entry.meta, phone: { ...phone, ...entry.meta?.phone } }
      }
      hosts.get(parent).children.push(route)
    }
    return strip({ ...root, children })
  })
}

// Catalog publication is background setup: core profiles/routes and overlays never wait for it.
// Publish the complete tree before the phone publishes app definitions and allows navigation.
onFeatureRoutesChanged(() => {
  if (registered) window.bngRoutes?.add([{ path: SOURCE, routes: buildOverhaulRoutes() }])
})

export function registerOverhaulRoutes() {
  const tree = buildOverhaulRoutes()
  window.bngRoutes?.add([{ path: SOURCE, routes: tree }])
  registered = !!window.bngRoutes
  // Warm both persistent frame and home without mounting hidden app work.
  const core = coreSnapshot.roots.flatMap(root => root.children || [])
  const shell = core.find(route => route.hostsChildren)
  const warm = [shell, ...(shell?.children || []).filter(route => route.meta?.phone?.depth === 0)]
  for (const route of warm.filter(Boolean)) {
    loadRuntimeComponent(route.component).catch(error => console.error('[phone] shell preload failed', error))
  }
}

export function unregisterOverhaulRoutes() {
  registered = false
  window.bngRoutes?.remove([SOURCE])
}
