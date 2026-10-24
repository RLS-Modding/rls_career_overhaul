// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

import { icons } from '@/common/components/base'
import { createCatalog } from './platformCatalog'
import { runtimeRouteComponent } from './runtimeComponent'
import { BUILTIN_COMPUTER_FUNCTIONS } from './builtinComputerFunctions.js'

const catalog = createCatalog('overhaul/career/garage/computer/functionCatalog', 'computerFunctionCatalog', BUILTIN_COMPUTER_FUNCTIONS)
export const computerFunctions = catalog.entries
export const computerFunctionsReady = catalog.ready
const SOURCE = 'overhaul.computer.functions'
let registeredIds = '', active = true

function registerPages(entries) {
  if (!active) return entries
  const ids = entries.filter(entry => entry.entry && entry.component && !entry.routeTarget).map(entry => entry.id).join('|')
  if (ids === registeredIds) return entries
  const routes = entries.filter(entry => entry.entry && entry.component && !entry.routeTarget).map(entry => ({
    name: `overhaul.computer.function.${entry.id}`,
    path: `/overhaul/computer-function/${entry.id}`,
    component: runtimeRouteComponent('/ui/ui-vue/mods/rls_career_overhaul/overhaul/modules/career/views/ComputerFunctionHost.vue', { phone: false }),
    props: { functionId: entry.id },
    meta: { uiApps: { shown: false } },
  }))
  if (routes.length) globalThis.window?.bngRoutes?.add([{ path: SOURCE, routes }])
  else globalThis.window?.bngRoutes?.remove([SOURCE])
  registeredIds = ids
  return entries
}
export function loadComputerFunctions(options) { active = true; return catalog.load(options).then(registerPages) }
export function ensureComputerFunctions() { return catalog.ensure().then(registerPages) }
export function retryComputerFunctionsWhileMounted() { return catalog.retryWhileMounted(registerPages) }
export function setComputerFunctionManifests(entries) { return registerPages(catalog.set(entries)) }
export function unregisterComputerFunctionRoutes() {
  active = false
  if (registeredIds) globalThis.window?.bngRoutes?.remove([SOURCE])
  registeredIds = ''
}

export function computerFunctionDefinition(id) {
  return computerFunctions.value.find(entry => entry.id === id)
}
export function computerFunctionRoute(fn) {
  const entry = computerFunctionDefinition(fn?.id)
  return fn?.routeTarget || entry?.routeTarget || (entry?.component ? `overhaul.computer.function.${entry.id}` : undefined)
}
export function computerFunctionIcon(id) {
  return icons[computerFunctionDefinition(id)?.icon] || icons.bug
}
