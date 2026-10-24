// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// Builds the core route tree and overlay list from the generated snapshot of gameplay/overhaul/ui/coreUi.json.
// Components are lazy runtime components, one per VFS path, so a component that two routes share compiles once.
import snapshot from "./builtinCoreUi"
import { runtimeComponent, runtimeRouteComponent, runtimeHostComponent } from "./runtimeComponent"
import { routeProps } from "./coreRouteProps"

// Props are either a literal (`true`) or a resolver name for a function in coreRouteProps.js.
function resolveProps(props) {
  if (typeof props !== "object") return props
  const resolve = routeProps[props.resolver]
  if (!resolve) throw new Error(`No props resolver named ${props.resolver}`)
  return resolve
}

// `owner` is ownership data for the Lua catalog, so it is dropped here before the router sees the route.
function toRoute({ owner, component, props, children, ...route }, phone = false) {
  phone = phone || route.hostsChildren === true
  if (component !== undefined) {
    // A host must resolve before commit: changing its vnode type later would
    // remount every child and start another phone opening session.
    route.component = route.hostsChildren ? runtimeHostComponent(component)
      : runtimeRouteComponent(component, { phone })
  }
  if (props !== undefined) route.props = resolveProps(props)
  if (children !== undefined) route.children = children.map(child => toRoute(child, phone))
  return route
}

export function buildCoreRoutes() {
  return snapshot.roots.map(root => toRoute(root))
}

export function coreOverlays() {
  return snapshot.overlays.map(({ id, component, mountOn, resync }) => ({
    id, component: runtimeComponent(component), mountOn, resync,
  }))
}
