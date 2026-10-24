// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// Phone app catalog. Apps are discovered, never listed. Lua (lib/phone/appCatalog.lua) finds, across
// all mods through BeamNG's virtual file system:
//  - JSON manifests, /gameplay/overhaul/phone/apps/<id>.json (the built-in apps; Lua reads them too,
//    for notification routing and layout defaults), and
//  - JavaScript manifests in the old format (`export default { id, name, icon, route,
//    unlockCondition: async luaBridge => ..., ... }`), in ui/ui-vue/mods/<mod>/phoneApps/<id>.js or
//    the old folder ui/ui-vue/src/modules/career/apps/manifests/<id>.js, imported here with the
//    stock runtime loader.
// Phone app manifests declare routes and presentation metadata for discovery.
//
// This module turns them into the app definitions the phone screens use (the shape of the old
// hand-written JavaScript manifests) and tells the registries when the list changes.
import { icons } from '@/common/components/base'
import { useBridge } from '@/bridge'
import { loadModule } from '@/services/uiMods'
import { acquireScope } from './luaScopes'
import { setCatalogLayoutDefaults } from './phoneLayoutUtils'
import { setPhoneRouteManifests } from './uiRouteCatalog.js'
import { setLuaScopeDeclarations } from './luaScopeRuntime.js'

// Apps that ship a page (`component`) instead of a route open through this generic host route.
export const ADDON_ROUTE_PREFIX = '/overhaul/phone-app/'

const CATALOG_LUA = "require('overhaul/lib/phone/appCatalog').listForUi()"
const LOAD_TIMEOUT_MS = 20000
const SCRIPT_TIMEOUT_MS = 10000
const RETRY_INITIAL_MS = 500
const RETRY_MAX_MS = 10000

// Manifest fields only the platform reads; the phone screens never see them.
const PLATFORM_FIELDS = new Set(['unlock', 'onInstall', 'defaultHome', 'notificationSources', 'uiRoutes'])

function warn(message, ...details) {
  console.warn(`[phoneAppCatalog] ${message}`, ...details)
}

const phoneApps = []
const notificationSources = {}
const listeners = new Set()
let loadPromise = null
let loadedOnce = false
let discovery = 0
let lastScriptManifests = []
let retryTimer = null
let retryDelayMs = RETRY_INITIAL_MS
let discoveryActive = true
let disposeOwnerEvents = () => {}

function connectOwnerEvents() {
  const events = useBridge().events
  if (!events?.on) return
  const host = globalThis.window || globalThis
  const key = Symbol.for('overhaul.uiOwnerEvents')
  const previous = host[key]
  if (previous?.owner === phoneApps) return
  previous?.dispose()
  const changed = owners => {
    if (!discoveryActive) return
    setLuaScopeDeclarations(asList(owners))
    loadPhoneApps({ force: true })
  }
  events.on('OverhaulUiOwnersChanged', changed)
  const binding = { owner: phoneApps, dispose: () => {
    events.off?.('OverhaulUiOwnersChanged', changed)
    discoveryActive = false
    discovery++
    clearTimeout(retryTimer)
    retryTimer = null
    loadPromise = null
  } }
  host[key] = binding
  disposeOwnerEvents = () => {
    binding.dispose()
    if (host[key] === binding) delete host[key]
  }
}

function scheduleRetry() {
  if (!discoveryActive || retryTimer !== null) return
  retryTimer = setTimeout(() => {
    retryTimer = null
    loadPhoneApps({ force: true })
  }, retryDelayMs)
  retryTimer?.unref?.()
  retryDelayMs = Math.min(retryDelayMs * 2, RETRY_MAX_MS)
}

// A late reply or retry from an unloaded UI must not publish into its replacement.
export function stopPhoneAppDiscovery() {
  disposeOwnerEvents()
  discoveryActive = false
  discovery++
  clearTimeout(retryTimer)
  retryTimer = null
  loadPromise = null
}

// Lua hands an empty JSON list back as an object; lists of one may arrive unwrapped.
function asList(value) {
  if (Array.isArray(value)) return value
  if (value && typeof value === 'object') return Object.values(value)
  return value == null ? [] : [value]
}

// `icon` is a stock icon name, or a list of names where the first one the game has wins
// (the old manifests wrote `icons.a || icons.b`).
export function resolveIcon(spec, iconSet = icons) {
  for (const name of Array.isArray(spec) ? spec : [spec]) {
    const icon = typeof name === 'string' ? iconSet[name] : undefined
    if (icon) return icon
  }
  return undefined
}

// Declarative unlock gates. Each one makes exactly the bridge calls, in the same order, that the
// hand-written unlockCondition functions of the old manifests made.
const UNLOCK_GATES = {
  // Career running (layout's answer first, then the career module).
  careerActive: () => async luaBridge => {
    try {
      await acquireScope(luaBridge, 'phone.layout')
      const fromLayout = await luaBridge.overhaul_phone_apps_layout.getCareerActive()
      if (fromLayout) return true
    } catch { }
    try {
      return await luaBridge.overhaul_career_career.isActive()
    } catch {
      return false
    }
  },
  // The current map offers an optional feature (maps.json optionalFeatures).
  optionalFeature: unlock => {
    let unavailableLogged = false
    return async luaBridge => {
      let reason = 'map provider unavailable'
      try {
        if (await luaBridge.overhaul_world_maps.hasOptionalFeature(unlock.feature)) {
          unavailableLogged = false
          return true
        }
      } catch (error) {
        reason = error?.message || reason
      }
      if (!unavailableLogged) {
        warn(`Optional feature ${unlock.feature} disabled: ${reason}`)
        unavailableLogged = true
      }
      return false
    }
  },
  // In a career, an owned business of a type has a skill tree node above level 0.
  businessSkillNode: unlock => async luaBridge => {
    try {
      const isActive = await luaBridge.overhaul_career_career.isActive()
      if (!isActive) return false
      if (unlock.scope) await acquireScope(luaBridge, unlock.scope)
      const purchased = await luaBridge.overhaul_career_business_manager.getPurchasedBusinesses(unlock.business)
      if (!purchased) return false
      for (const [id, owned] of Object.entries(purchased)) {
        if (!owned) continue
        const level = await luaBridge.overhaul_career_business_skillTree.getNodeProgress(id, unlock.tree, unlock.node)
        if (level && level > 0) return true
      }
      return false
    } catch {
      return false
    }
  },
  // Any Lua function: `extension.function(...args)` is truthy (optionally loading the extension).
  lua: unlock => async luaBridge => {
    try {
      if (unlock.load) await luaBridge.extensions.load(unlock.extension)
      return !!(await luaBridge[unlock.extension][unlock.function](...asList(unlock.args)))
    } catch {
      return false
    }
  },
}

export function createUnlockCondition(unlock) {
  const gate = unlock && typeof unlock === 'object' ? UNLOCK_GATES[unlock.type] : null
  if (gate) return gate(unlock)
  warn('unknown unlock type; the app stays locked', unlock)
  return async () => false
}

function stripPlatformChannelFields(decl) {
  if (!decl || typeof decl !== 'object') return decl
  const { pending, ...channel } = decl
  return channel
}

// One manifest -> one app definition, in the shape the phone screens use.
export function normalizeManifest(raw, iconSet = icons) {
  const app = {}
  for (const [key, value] of Object.entries(raw)) {
    if (PLATFORM_FIELDS.has(key)) continue
    if (key === 'icon') app.icon = resolveIcon(value, iconSet)
    else if (key === 'notifications') app.notifications = asList(value).map(stripPlatformChannelFields)
    else app[key] = value
  }
  if (raw.unlock !== undefined) app.unlockCondition = createUnlockCondition(raw.unlock)
  if (!app.route && typeof raw.component === 'string' && raw.id) {
    app.route = ADDON_ROUTE_PREFIX + encodeURIComponent(raw.id)
  }
  return app
}

function compareIds(a, b) {
  const x = String(a?.id ?? ''), y = String(b?.id ?? '')
  return x < y ? -1 : x > y ? 1 : 0
}

// System apps (preinstalled, never removable): ordered by default dock slot, then id.
function systemAppIds(manifests) {
  const slot = m => Number.isInteger(m.defaultDock) && m.defaultDock >= 0 && m.defaultDock < 4 ? m.defaultDock : 4
  return manifests.filter(m => m.systemApp === true)
    .sort((a, b) => (slot(a) - slot(b)) || compareIds(a, b))
    .map(m => m.id)
}

// Default dock, the one source for the UI (Lua derives the same, appCatalog.derive): slot i holds
// the first app in declared order (defaultPage, defaultPosition), then id, whose defaultDock is i;
// a later claim of a taken slot is reported and ignored.
function dockAppIds(manifests) {
  const rank = m => (Number.isInteger(m.defaultPage) ? m.defaultPage : 999) * 1000 + (Number.isInteger(m.defaultPosition) ? m.defaultPosition : 999)
  const docked = manifests.filter(m => Number.isInteger(m.defaultDock) && m.defaultDock >= 0 && m.defaultDock < 4)
    .sort((a, b) => (rank(a) - rank(b)) || compareIds(a, b))
  const dock = [null, null, null, null]
  for (const m of docked) {
    if (dock[m.defaultDock] === null) dock[m.defaultDock] = m.id
    else warn(`${m.id}: dock slot ${m.defaultDock} already belongs to ${dock[m.defaultDock]} (declared order, then id)`)
  }
  return dock
}

// Default home screen apps: by slot, then id.
function defaultHomeApps(manifests) {
  return manifests
    .filter(m => m.defaultHome && Number.isInteger(m.defaultHome.slot) && m.defaultHome.slot >= 0 && m.defaultHome.slot < 16)
    .map(m => ({ id: m.id, slot: m.defaultHome.slot, required: m.defaultHome.required === true }))
    .sort((a, b) => (a.slot - b.slot) || compareIds(a, b))
}

// An old-format JavaScript manifest is already an app definition (icon objects, unlockCondition
// functions); it is used as written. `manifestPath` remembers its file (a page next to it,
// <id>.vue, opens in the phone app host).
function scriptApp(entry) {
  const app = { ...entry.manifest, manifestPath: entry.path }
  if (!app.route && typeof app.component === 'string') app.route = ADDON_ROUTE_PREFIX + encodeURIComponent(app.id)
  return app
}

// Replaces the catalog with raw JSON manifests (as Lua returns them) plus old-format JavaScript
// manifests ({path, manifest}, in path order) and notifies the registries. A JavaScript manifest
// replaces a JSON one with the same id; of two JavaScript manifests with one id the first path wins.
export function setPhoneAppManifests(rawManifests, iconSet = icons, scriptManifests = [], routes = undefined) {
  setPhoneRouteManifests(asList(rawManifests), routes)
  const manifests = asList(rawManifests).filter(m => m && typeof m === 'object' && m.id).sort(compareIds)
  const byId = new Map(manifests.map(raw => [raw.id, { raw }]))
  const scripted = new Set()
  for (const entry of asList(scriptManifests)) {
    const id = entry?.manifest?.id
    if (!id) continue
    if (scripted.has(id)) {
      warn(`${entry.path}: app id '${id}' is already defined by another manifest (ignored)`)
      continue
    }
    scripted.add(id)
    byId.set(id, { raw: entry.manifest, script: entry })
  }
  phoneApps.length = 0
  for (const key of Object.keys(notificationSources)) delete notificationSources[key]
  for (const id of [...byId.keys()].sort()) {
    const { raw, script } = byId.get(id)
    phoneApps.push(script ? scriptApp(script) : normalizeManifest(raw, iconSet))
    for (const source of asList(raw.notificationSources)) {
      if (typeof source === 'string' && source && !(source in notificationSources)) notificationSources[source] = raw.id
    }
  }
  setCatalogLayoutDefaults({
    systemAppIds: systemAppIds(manifests),
    dockAppIds: dockAppIds(manifests),
    defaultHomeApps: defaultHomeApps(manifests),
  })
  loadedOnce = true
  for (const listener of listeners) {
    try { listener(phoneApps) } catch (err) { warn('listener failed', err) }
  }
  return phoneApps
}

// Current app definitions in discovery order (sorted by id). The array is updated in place.
export function getPhoneApps() {
  return phoneApps
}

// payload.source (lower case) -> app id, from the manifests' notificationSources.
export function getNotificationSourceAppIds() {
  return notificationSources
}

export function isPhoneAppCatalogLoaded() {
  return loadedOnce
}

// Calls fn now (when loaded) and after every reload. Returns an unsubscribe function.
export function onPhoneAppsChanged(fn) {
  listeners.add(fn)
  if (loadedOnce) fn(phoneApps)
  return () => listeners.delete(fn)
}

function withTimeout(promise, ms, what) {
  let timer
  const deadline = new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(`${what}: no answer within ${ms} ms`)), ms) })
  return Promise.race([promise, deadline]).finally(() => clearTimeout(timer))
}

// Imports old-format manifests (in parallel, each bounded by timeoutMs so one stalled file cannot hold
// the phone) and returns them in the given (sorted) path order. A file that fails, times out or
// exports no manifest is skipped with a warning.
export async function loadScriptManifests(paths, load = loadModule, timeoutMs = SCRIPT_TIMEOUT_MS) {
  const list = asList(paths).filter(p => typeof p === 'string' && p)
  const results = await Promise.all(list.map(path =>
    withTimeout(Promise.resolve().then(() => load(path)), timeoutMs, path).then(ns => ({ path, ns }), err => ({ path, err }))))
  const out = []
  for (const { path, ns, err } of results) {
    if (err) {
      warn(`could not load ${path}`, err)
      continue
    }
    const manifest = ns?.default || ns?.manifest
    if (manifest && typeof manifest === 'object' && typeof manifest.id === 'string' && manifest.id) out.push({ path, manifest })
    else warn(`${path} exports no app manifest (export default { id, ... })`)
  }
  return out
}

// The page of an app that opens in the phone app host: its `component`, or for an old-format
// manifest a .vue file with the same name next to it.
export function appPageFile(app) {
  if (typeof app?.component === 'string' && app.component) return app.component
  if (typeof app?.manifestPath === 'string') return app.manifestPath.replace(/\.js$/i, '.vue')
  return null
}

function runLua(code) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('no reply from Lua')), LOAD_TIMEOUT_MS)
    try {
      useBridge().api.engineLua(code, result => { clearTimeout(timer); resolve(result) })
    } catch (err) {
      clearTimeout(timer)
      reject(err)
    }
  })
}

// Discovers the apps (once; `force` re-scans, e.g. after mods changed). Never rejects.
// - Only the newest discovery publishes: a reply to an older request is dropped.
// - A failed discovery publishes nothing: the last good list stays, and before the first success
//   isPhoneAppCatalogLoaded() stays false. Background retries do not need a mounted phone.
// - If only the add-on (JavaScript) list failed, the built-in apps update and the last add-ons stay.
export function loadPhoneApps({ force = false, scriptTimeoutMs = SCRIPT_TIMEOUT_MS } = {}) {
  if (loadPromise && !force) return loadPromise
  discoveryActive = true
  connectOwnerEvents()
  clearTimeout(retryTimer)
  retryTimer = null
  const mine = ++discovery
  const promise = runLua(CATALOG_LUA).then(async result => {
    const reply = result && typeof result === 'object' ? result : {}
    for (const item of asList(reply.rejected)) {
      warn(`ignored ${item?.file}: ${item?.reason}`)
    }
    const apps = asList(reply.apps)
    if (!apps.length) throw new Error(reply.error ? `Lua: ${reply.error}` : 'Lua found no phone apps')
    if (mine !== discovery) return phoneApps
    if (Array.isArray(reply.uiOwners)) setLuaScopeDeclarations(reply.uiOwners)
    // New routes can publish before imports; replacements must wait for the matching apps.
    setPhoneRouteManifests(apps, Array.isArray(reply.routes) ? reply.routes : undefined, { additive: true })
    let scripts = lastScriptManifests
    if (reply.error) warn('add-on phone apps could not be listed; keeping the last ones:', reply.error)
    else scripts = await loadScriptManifests(reply.scripts, loadModule, scriptTimeoutMs)
    if (mine !== discovery) return phoneApps
    lastScriptManifests = scripts
    if (reply.error) scheduleRetry()
    else retryDelayMs = RETRY_INITIAL_MS
    return setPhoneAppManifests(apps, icons, scripts, Array.isArray(reply.routes) ? reply.routes : undefined)
  }).catch(err => {
    if (mine === discovery) {
      // console.error is a fatal signal to stock boot.js during angularRunning,
      // including while Lua is still loading a level and cannot answer us.
      warn('app discovery failed; keeping the last good app list; will retry', err)
      loadPromise = null
      scheduleRetry()
    }
    return phoneApps
  })
  loadPromise = promise
  return promise
}

// Resolves once a discovery has succeeded (retrying a failed one); check isPhoneAppCatalogLoaded().
export function ensurePhoneApps() {
  return loadedOnce ? Promise.resolve(phoneApps) : loadPhoneApps()
}
