// Stock pause content is bundled. Mount in its existing card using the entry-card host pattern.
import { getComponent } from '@/services/uiMods'
import { runRaw } from '@/bridge/libs/Lua.js'
import { useBridge } from '@/bridge'
import { reportUiFailure } from '../utils/safeLua'

const CARD_FILE = '/ui/ui-vue/mods/rls_career_overhaul/overhaul/modules/career/components/OverhaulCareerCard.vue'
let stopRoute, observer, host, stock, previousDisplay
let navContainer, previousChildNav
let mainCard, enterSkills
let generation = 0
const VEHICLE_EVENTS = ['VehicleFocusChanged', 'VehicleChange', 'VehicleConfigChange']
let stopVehicleEvents
const refreshVehicle = () => onRoute(window.vueRouter.currentRoute.value)

function stopWaiting() {
  observer?.disconnect()
  observer = null
}

function removeCard() {
  if (mainCard) { mainCard.removeEventListener('ui_nav', enterSkills, true); mainCard = null }
  if (host) { window.Vue.render(null, host); host.remove(); host = null }
  if (stock) { stock.style.display = previousDisplay; stock = null }
  if (navContainer) {
    if (previousChildNav == null) navContainer.removeAttribute('bng-no-child-nav')
    else navContainer.setAttribute('bng-no-child-nav', previousChildNav)
    navContainer = null
  }
}

function unmount() {
  generation++
  stopWaiting()
  removeCard()
}

async function onRoute(route) {
  unmount()
  if (route?.name !== 'pause') return
  const current = generation
  try {
    let data = await runRaw("require('overhaul/lib/ui/careerCard').getData()")
    if (current !== generation || !data?.sections?.length) return
    let compiled = await getComponent(CARD_FILE, false, true)
    if (!compiled?.compiled && typeof compiled?.compile === 'function') compiled = await compiled.compile()
    if (current !== generation) return
    if (!compiled?.component || compiled.error) throw compiled?.errorObj || new Error('Career card compile failed')
    let pendingAnchor = null, placement = 0
    const mount = async () => {
      const anchor = document.querySelector('.pause-side-card .career-profile-overview')
      if (anchor === stock && host?.isConnected) return
      if (anchor && anchor === pendingAnchor) return
      const attempt = ++placement
      pendingAnchor = anchor
      removeCard()
      if (!anchor) return
      // Side content can change without a route change (activity details and mod tabs).
      const snapshot = data || await runRaw("require('overhaul/lib/ui/careerCard').getData()")
      data = null
      if (current !== generation || attempt !== placement || !anchor.isConnected || !snapshot?.sections?.length) return
      stock = anchor
      previousDisplay = stock.style.display
      host = document.createElement('div')
      host.id = 'overhaul-pause-career-host'
      stock.after(host)
      // Stock side cards are read-only. Enable the skills' own navigation scope only while mounted.
      navContainer = stock.closest('.menu-content-card-2')
      previousChildNav = navContainer?.getAttribute('bng-no-child-nav')
      navContainer?.removeAttribute('bng-no-child-nav')
      const vnode = window.Vue.createVNode(compiled.component, { data: snapshot })
      vnode.appContext = window.bngVue.app._context
      window.Vue.render(vnode, host)
      // The stock Home layout routes focus only between its main card and rails.
      // Right from Nearby Activities enters this newly interactive side card.
      mainCard = document.querySelector('.menu-content-card-1')
      enterSkills = event => {
        if (event.detail?.name !== 'focus_r' || !event.detail.value) return
        const first = host?.querySelector('.skill')
        if (!first) return
        event.preventDefault()
        event.stopImmediatePropagation()
        first.focus()
      }
      mainCard?.addEventListener('ui_nav', enterSkills, true)
      stock.style.display = 'none'
      pendingAnchor = null
    }
    await window.Vue.nextTick()
    if (current !== generation) return
    const reconcile = () => mount().catch(error => {
      if (current === generation) { unmount(); reportUiFailure(error, 'Pause career card failed') }
    })
    observer = new MutationObserver(reconcile)
    observer.observe(document.body, { childList: true, subtree: true })
    await reconcile()
  } catch (error) {
    if (current === generation) { unmount(); reportUiFailure(error, 'Pause career card failed') }
  }
}

export function startPauseCareerCard() {
  stopPauseCareerCard()
  const { events } = useBridge()
  for (const event of VEHICLE_EVENTS) events.on(event, refreshVehicle)
  stopVehicleEvents = () => { for (const event of VEHICLE_EVENTS) events.off(event, refreshVehicle) }
  stopRoute = window.Vue.watch(window.vueRouter.currentRoute, onRoute, { immediate: true, flush: 'post' })
}

export function stopPauseCareerCard() {
  stopVehicleEvents?.()
  stopVehicleEvents = null
  stopRoute?.()
  stopRoute = null
  unmount()
}
