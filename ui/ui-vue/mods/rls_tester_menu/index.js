/**
 * Dormant until F9. Do not poll or mount anything at UI boot.
 * Lua overhaul_dev_testerMenu.toggle() emits RlsTesterMenu; we compile the
 * overlay only on the first visible=true payload.
 */
import { getComponent } from "@/services/uiMods"

const OVERLAY_FILE = "/ui/ui-vue/mods/rls_career_overhaul/overhaul/modules/career/components/RlsTesterMenu.vue"
const HOST_ID = "rls-tester-menu-host"

function payloadObject(payload) {
  if (Array.isArray(payload) && payload[0] && typeof payload[0] === "object") {
    return payload[0]
  }
  return payload && typeof payload === "object" ? payload : null
}

// The overlay cannot receive its initial payload until it is mounted.
let pendingPayload = null
let mountPromise = null

function mountTester() {
  if (window.__rlsTesterMenuMounted || document.getElementById(HOST_ID)) {
    window.__rlsTesterMenuMounted = true
    return Promise.resolve(true)
  }
  if (!mountPromise) {
    mountPromise = compileAndMount().finally(() => { mountPromise = null })
  }
  return mountPromise
}

async function compileAndMount() {
  if (!window.Vue || !window.bngVue?.app?._context) return false

  let data = await getComponent(OVERLAY_FILE, false, true)
  if (!data?.compiled && typeof data?.compile === "function") {
    data = await data.compile()
  }
  if (data?.error || !data?.component) {
    console.error("[rls_tester_menu] Overlay compile failed", data && data.error, data && data.errorObj)
    return false
  }

  const hostEl = document.createElement("div")
  hostEl.id = HOST_ID
  document.body.appendChild(hostEl)
  const vnode = window.Vue.createVNode(data.component)
  vnode.appContext = window.bngVue.app._context
  window.Vue.render(vnode, hostEl)
  window.__rlsTesterMenuMounted = true
  const replay = pendingPayload
  pendingPayload = null
  if (replay && window.vueEventBus && typeof window.vueEventBus.emit === "function") {
    window.vueEventBus.emit("RlsTesterMenu", replay)
  }
  return true
}

function onTesterEvent(payload) {
  if (window.__rlsTesterMenuMounted) return
  const data = payloadObject(payload)
  if (data) pendingPayload = payload
  if (data && data.visible === true) {
    mountTester()
  }
}

export function onLoad() {
  if (window.__rlsTesterMenuListening) return
  const bus = window.vueEventBus
  if (!bus || typeof bus.on !== "function") return
  window.__rlsTesterMenuListening = true
  bus.on("RlsTesterMenu", onTesterEvent)
}

export function onUnload() {
  window.__rlsTesterMenuListening = false
  pendingPayload = null
  window.__rlsTesterMenuMounted = false
  const bus = window.vueEventBus
  if (bus && typeof bus.off === "function") {
    bus.off("RlsTesterMenu", onTesterEvent)
  }
  const hostEl = document.getElementById(HOST_ID)
  if (hostEl && window.Vue?.render) {
    try {
      window.Vue.render(null, hostEl)
    } catch (_) {}
    hostEl.remove()
  }
}
