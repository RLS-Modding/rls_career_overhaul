// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// Mount map: route subscription, per-route stock DOM placement, shared-app render, teardown.
// Stock views are compiled, so the mod entry owns this insertion instead of a VFS override.
import { lua, useBridge } from "@/bridge"
import { getComponent } from "@/services/uiMods"
import { reportUiFailure } from "../utils/safeLua"

const CARD_FILE = "/ui/ui-vue/mods/rls_career_overhaul/overhaul/modules/career/profiles/components/OverhaulEntryCard.vue"
const HOST_ID = "overhaul-career-entry-host"
let stopRoute = null
let stopLoading = null
let loading = null
let observer = null
let anchorTimeout = null
let host = null
let hostRouteName = null
let entryComponent = null
let generation = 0
let warned = false

// These routes share the stock grid. Its LineWipe clips the primary column,
// including this card, on both opening and closing an overlay.
const GRID_ROUTES = new Set(["menu", "menu.others", "menu.discover"])

// Where the card goes on each stock screen: find returns an insert function once the stock DOM is there.
const PLACEMENTS = {
  "career.profiles": () => {
    const heading = document.querySelector(".career-profile-select .profiles-info-box")
    const shell = heading?.parentElement.querySelector(":scope > .profiles-shell")
    return shell && (host => shell.before(host))
  },
  "career.profiles.new": () => {
    const panel = document.querySelector(".career-profile-new .new-profile-panel")
    return panel && (host => panel.before(host))
  },
  "career.profiles.saves": () => {
    const panel = document.querySelector(".career-profile-saves .saves-panel")
    return panel && (host => panel.before(host))
  },
  // Inside the tile column, so it hides with the tiles when More or Experiences slides open.
  menu: () => {
    const tiles = document.querySelector(".mainmenu-container .stage > .primary")
    return tiles && (host => { host.style.marginTop = "calc(var(--ui-rem, 16px) * 0.75)"; tiles.append(host) })
  },
}

function stopWaiting() {
  observer?.disconnect()
  observer = null
  clearTimeout(anchorTimeout)
  anchorTimeout = null
}

function unmount() {
  generation++
  stopWaiting()
  if (!host) return
  window.Vue.render(null, host)
  host.remove()
  host = null
  hostRouteName = null
}

async function mountAt(insert, current, routeName) {
  stopWaiting()
  try {
    if (host) {
      host.style.marginTop = ""
      insert(host)
      if (!host.isConnected) unmount()
      return
    }
    // A fresh subtree must rebind stock navigation scopes, but loading the same
    // component again can leave the destination visible for a frame without it.
    // Reuse the definition so warm screen changes render within this DOM tick.
    let component = entryComponent
    if (!component) {
      let data = await getComponent(CARD_FILE, false, true)
      if (!data?.compiled && typeof data?.compile === "function") data = await data.compile()
      if (current !== generation) return
      if (!data?.component || data.error) throw data.errorObj || new Error(data?.error || "Entry card component missing")
      entryComponent = component = data.component
    }
    hostRouteName = routeName
    host = document.createElement("div")
    host.id = HOST_ID
    host.style.flex = "0 0 auto"
    host.style.containerType = "inline-size"
    // Stock menus switch pointer events off on their layout layers and back on per tile.
    host.style.pointerEvents = "auto"
    insert(host)
    if (!host.isConnected) return unmount()
    const vnode = window.Vue.createVNode(component)
    vnode.appContext = window.bngVue.app._context
    window.Vue.render(vnode, host)
  } catch (error) {
    reportUiFailure(error, "Career entry card failed")
  }
}

async function onRoute(route) {
  const placementName = GRID_ROUTES.has(route?.name) ? "menu" : route?.name
  // Navigation directives bind to the nearest stock scope at mount. A new
  // screen needs a new subtree; repeated updates within it keep the busy guard.
  if (host && hostRouteName !== placementName) unmount()
  const current = ++generation
  stopWaiting()
  const place = PLACEMENTS[placementName]
  if (!place || loading !== false) return unmount()
  await window.Vue.nextTick()
  if (current !== generation) return
  // Route completion can precede an async stock view's DOM. Observe only while
  // waiting for that view; leaving the route cancels both observation and compilation.
  const findAnchor = () => {
    const insert = place()
    if (!insert) return false
    mountAt(insert, current, placementName)
    return true
  }
  if (findAnchor()) return
  observer = new MutationObserver(findAnchor)
  observer.observe(document.body, { childList: true, subtree: true })
  anchorTimeout = setTimeout(() => {
    stopWaiting()
    if (warned) return
    warned = true
    reportUiFailure(null, `Stock anchors for ${route.name} missing; entry card skipped`)
  }, 3000)
}

export function startCareerEntryCard() {
  stopCareerEntryCard()
  const events = useBridge().events
  let live = true
  let revision = 0
  const onLoading = data => {
    if (typeof data?.active !== "boolean") return
    revision++
    if (loading === data.active) return
    loading = data.active
    onRoute(window.vueRouter.currentRoute.value)
  }
  events.on("LoadingScreen", onLoading)
  stopLoading = () => { live = false; events.off("LoadingScreen", onLoading) }
  // UI reload can happen after the loading hook. Never let an older snapshot
  // overwrite a newer hook (including a start refused while this call waits).
  const snapshotRevision = revision
  Promise.resolve().then(() => lua.core_gamestate.loading()).then(value => {
    if (live && revision === snapshotRevision) onLoading({ active: value === true })
  }).catch(error => {
    if (!live || revision !== snapshotRevision) return
    reportUiFailure(error, "Career entry loading state unavailable")
    onLoading({ active: false })
  })
  stopRoute = window.Vue.watch(window.vueRouter.currentRoute, onRoute, { immediate: true, flush: "post" })
}

export function stopCareerEntryCard() {
  stopRoute?.()
  stopRoute = null
  stopLoading?.()
  stopLoading = null
  loading = null
  unmount()
  entryComponent = null
}
