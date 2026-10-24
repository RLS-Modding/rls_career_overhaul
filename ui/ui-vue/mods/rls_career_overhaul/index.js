// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

/**
 * Mount career overlay components that used to live in mod App.vue.
 * BeamNG 0.39 serves the Vue shell from ui-vue/dist, so VFS App.vue overrides
 * do not run. Official mod entry points under ui/ui-vue/mods/ do.
 *
 * Overlays call useRoute()/useRouter(), so they must share the main app context
 * (cannot be a second createApp with the same router instance).
 * entryCardHost owns the route-bound insertion into stock Career; unload releases both hosts.
 */
import { getComponent } from "@/services/uiMods"
import { useBridge } from "@/bridge"
import { registerOverhaulRoutes, unregisterOverhaulRoutes } from "./overhaul/registerRoutes.js"
import { loadPhoneApps, stopPhoneAppDiscovery } from "./overhaul/modules/career/utils/phoneAppCatalog.js"
import { startPhoneShellState, stopPhoneShellState } from "./overhaul/modules/career/utils/phoneShellState.js"
import { startCareerEntryCard, stopCareerEntryCard } from "./overhaul/modules/career/profiles/entryCardHost.js"
import { startPauseCareerCard, stopPauseCareerCard } from "./overhaul/modules/career/profiles/pauseCardHost.js"

import { loadComputerFunctions, retryComputerFunctionsWhileMounted, unregisterComputerFunctionRoutes } from "./overhaul/modules/career/utils/computerFunctionCatalog.js"

import { loadBusinessTypes, retryBusinessTypesWhileMounted } from "./overhaul/modules/career/utils/businessTypeCatalog.js"

import { startPassengerHud } from "./overhaul/modules/career/utils/passengerHud.js"

const OVERLAY_FILE = "/ui/ui-vue/mods/rls_career_overhaul/RlsCareerOverlays.vue"
const HOST_ID = "rls-career-overlays-host"

let hostEl = null
let menuEvents = null
let loadGeneration = 0
let stopCatalogRetries = () => {}
let stopPassengerHud = () => {}

const CROSSFIRE_NO_BUTTON_MSG = "Couldn't locate any button anywhere. Menu navigation won't work"
let consoleLogPatch = null

// Crossfire reports every navigation attempt when overlays leave no focusable controls.
function silenceCrossfireNavSpam() {
  if (consoleLogPatch) return
  const predecessor = console.log
  const patch = { predecessor, filtering: true, wrapper: null }
  patch.wrapper = (...args) => {
    if (patch.filtering && args[0] === CROSSFIRE_NO_BUTTON_MSG) return
    return predecessor.apply(console, args)
  }
  consoleLogPatch = patch
  console.log = patch.wrapper
}

function restoreConsoleLog() {
  if (!consoleLogPatch) return
  // Later wrappers may retain ours in their chain, so leave a callable pass-through.
  consoleLogPatch.filtering = false
  if (console.log === consoleLogPatch.wrapper) console.log = consoleLogPatch.predecessor
  consoleLogPatch = null
}

function addOverhaulButton(addButton) {
  if (typeof addButton === "function") {
    addButton({ title: "Career Overhaul", iconId: "car", action: "overhaul.profiles" })
  }
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms))
}

async function waitForMainApp(timeoutMs = 60000) {
  const start = Date.now()
  while (Date.now() - start < timeoutMs) {
    if (window.Vue && window.bngVue?.app?._context && window.vueRouter) {
      return true
    }
    await sleep(50)
  }
  return false
}

function unmountHost() {
  if (hostEl && window.Vue?.render) {
    try {
      window.Vue.render(null, hostEl)
    } catch (_) {
      // ignore
    }
  }
  if (hostEl) {
    hostEl.remove()
    hostEl = null
  }
}

async function mountOverlays(generation) {
  const ready = await waitForMainApp()
  if (generation !== loadGeneration) return false
  if (!ready) {
    console.error("[rls_career_overhaul] Timed out waiting for Vue app context")
    return false
  }

  let data = await getComponent(OVERLAY_FILE, false, true)
  if (!data?.compiled && typeof data?.compile === "function") {
    data = await data.compile()
  }
  if (data?.error) {
    console.error("[rls_career_overhaul] Overlay compile failed", data.error, data.errorObj)
    return false
  }
  if (!data?.component) {
    console.error("[rls_career_overhaul] Overlay component missing after compile")
    return false
  }

  if (generation !== loadGeneration) return false

  unmountHost()

  hostEl = document.createElement("div")
  hostEl.id = HOST_ID
  document.body.appendChild(hostEl)

  const vnode = window.Vue.createVNode(data.component)
  vnode.appContext = window.bngVue.app._context
  window.Vue.render(vnode, hostEl)
  return true
}

export async function onLoad() {
  const generation = ++loadGeneration
  if (!menuEvents) {
    const bridge = useBridge()
    menuEvents = bridge.events
    stopPassengerHud = startPassengerHud(bridge)
    startPhoneShellState(menuEvents)
    menuEvents.on("MainMenuButtons", addOverhaulButton)
    menuEvents.emit("BroadcastMainMenuButtons")
  }
  silenceCrossfireNavSpam()
  try {
    if (await waitForMainApp() && generation === loadGeneration) {
      // Phone apps are discovered from manifest files (any mod can add one); a UI reload re-scans.
      // Never awaited: Overhaul's routes and overlays must not wait for Lua or for another mod's
      // files; the phone screens wait for the app list themselves.
      loadPhoneApps({ force: true })
      loadComputerFunctions({ force: true })
      loadBusinessTypes({ force: true })
      // Startup owns retries too: no computer screen needs to be mounted for
      // catalog discovery to recover after Lua finishes loading the level.
      stopCatalogRetries()
      const stopComputer = retryComputerFunctionsWhileMounted()
      const stopBusiness = retryBusinessTypesWhileMounted()
      stopCatalogRetries = () => { stopComputer(); stopBusiness() }
      registerOverhaulRoutes()
      startCareerEntryCard()
      startPauseCareerCard()
    }
    await mountOverlays(generation)
  } catch (err) {
    console.error("[rls_career_overhaul] Failed to mount career overlays", err)
  }
}

export async function onUnload() {
  stopPassengerHud()
  stopPassengerHud = () => {}
  loadGeneration++
  stopCatalogRetries()
  stopCatalogRetries = () => {}
  stopCareerEntryCard()
  stopPauseCareerCard()
  stopPhoneAppDiscovery()
  stopPhoneShellState()
  if (menuEvents) menuEvents.off("MainMenuButtons", addOverhaulButton)
  menuEvents = null
  unregisterOverhaulRoutes()
  unregisterComputerFunctionRoutes()
  unmountHost()
  restoreConsoleLog()
}
