<template>
  <div 
    ref="phoneRef"
    class="phone-shell" 
    bng-no-nav="true"
    :bng-no-child-nav="!isEntered || state !== 'open' || phoneOpeningBlocked"
    v-bng-scoped-nav="navScope"
    :class="{ 'phone-entered': isEntered, 'phone-expanded': expanded, 'no-transition': noTransition }"
    :style="wrapperStyle">
    <div class="phone-bevel"></div>
    <div class="phone-screen" >
      <!-- Status Bar -->
      <div class="phone-status-bar">
        <div class="status-bar-cell status-bar-left">
          <button class="status-back" bng-no-nav="true" tabindex="-1" v-bng-on-ui-nav:back.asMouse
            v-bng-on-ui-nav:menu.down="() => { callModLua('ui_menuManager.openMenu'); return false }"
            @click="back">
            <span class="status-back-icon" aria-hidden="true">
              <svg width="12" height="12" viewBox="0 0 12 12" fill="currentColor"><path d="M8 2L4 6l4 4" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" fill="none"/></svg>
            </span>
            <span class="status-time">{{ timeParts.main }}<span class="status-time-period" v-if="timeParts.period">{{ timeParts.period }}</span></span>
          </button>
        </div>
        <div class="status-bar-cell status-bar-center">
          <div class="dynamic-island">
            <span v-if="appName" class="dynamic-island-label">{{ appName }}</span>
          </div>
        </div>
        <div class="status-bar-cell status-bar-right" v-if="cashDisplay && !hideCash">
          <!-- The app that declares opensFromBalance opens from the balance, once it is on the phone. -->
          <button v-if="balanceApp" type="button" class="status-right-pill status-balance-button" bng-nav-item
            :aria-label="`Open ${balanceApp.name}, balance ${cashDisplay}`" @click="openBalanceApp">
            <span class="status-cash">{{ cashDisplay }}</span>
          </button>
          <div v-else class="status-right-pill">
            <span class="status-cash">{{ cashDisplay }}</span>
          </div>
        </div>
      </div>
      <PhoneNavigation :root="phoneRef" />

      <PhoneHeadsUpBanner />

      <div ref="contentRef" class="phone-content" v-bng-ui-nav-scroll>
        <router-view v-slot="{ Component, route: screenRoute }">
          <Transition :css="false" @enter="enterScreen" @leave="leaveScreen">
            <component :is="Component" :key="screenRoute.name" />
          </Transition>
        </router-view>
      </div>
    </div>
  </div>
</template>

<script setup>
// The shell owns opening sessions and the frame. Screens register presentation;
// the route tree owns membership and runtimeComponent owns pending page loading.
// Read top to bottom: presentation, opening/closing, navigation, screen animation.
import { useEvents } from '@/services/events'
import { ref, shallowRef, onMounted, onUnmounted, nextTick, computed, watch, provide, unref } from 'vue'
import { vBngOnUiNav, vBngScopedNav, vBngUiNavScroll } from '@/common/directives'
import { useRouter, useRoute } from 'vue-router'
import { lua } from '@/bridge'
import { usePhoneSettings, getPhoneScale, getPhonePosition } from '../../composables/usePhoneSettings'
import { usePhoneTutorial } from '../../composables/usePhoneTutorial'
import { phoneOpeningBlocked } from '../../composables/usePhoneOpeningBlocker'
import { useScopedNav } from '@/services/scopedNav/api'
import PhoneHeadsUpBanner from '../../components/phone/PhoneHeadsUpBanner.vue'
import PhoneNavigation from '../../components/phone/PhoneNavigation.vue'
import { clearPhoneHeadsUpNotifications } from '../../composables/usePhoneHeadsUpNotification'
import { callModLua, callModLuaIfAvailable, installLuaBridgeFallbacks } from '../../utils/installLuaBridgeFallbacks'
import { acquireScope, releaseScope } from '../../utils/luaScopes'
import { readPhoneShellState, setPhoneShellVisible } from '../../utils/phoneShellState'
import { getPhoneApps, onPhoneAppsChanged } from '../../utils/phoneAppCatalog'
import { PREINSTALLED_APP_IDS, SYSTEM_APP_IDS, toIdList } from '../../utils/phoneLayoutUtils'
import { navigatePhoneRoute } from '../../utils/phoneNavigation'
import { BUILTIN_PHONE_APP_NAMES } from '../../utils/builtinPhoneRoutes.js'
import { getFeatureRoutes } from '../../utils/uiRouteCatalog.js'
import { loadRuntimeComponent } from '../../utils/runtimeComponent.js'
import { isPhoneRoute } from '../../utils/phoneRoutes.js'
import { reportUiFailure } from '../../utils/safeLua'

installLuaBridgeFallbacks()
const router = useRouter()
const route = useRoute()
const events = useEvents()
const { phoneSettings, replacePhoneSettings } = usePhoneSettings()
const phoneTutorial = usePhoneTutorial()
const shellState = readPhoneShellState()
if (shellState?.layout?.settings) replacePhoneSettings(shellState.layout.settings)
const phoneRef = ref(null)
const contentRef = ref(null)
const isEntered = ref(false)
const noTransition = ref(false)
const state = ref('closed')
const timeString = ref(shellState?.time || sessionStorage.getItem('phone_last_time') || '')
const careerMoney = ref(shellState?.money ?? null)
const isCareer = ref(shellState?.careerActive === true)
const viewportWidth = ref(window.innerWidth)
const registration = shallowRef(null)
const screen = computed(() => registration.value && registration.value.routeName === route.name ? registration.value.options : null)
const apps = shallowRef([...getPhoneApps()])
const installedAppIds = shallowRef(toIdList(shellState?.layout?.installedAppIds))
let session = 0
let opening = null
let destroyed = false
let markOperations = Promise.resolve()
let idleHandle = null
let intent = null
let intentTimer = null
let iconVisual = null

const read = value => typeof value === 'function' ? value() : unref(value)
const expanded = computed(() => screen.value?.expanded === undefined ? false : !!read(screen.value.expanded))
// Screens hide the status-bar cash while their own control sits in that corner (home's Done button).
const hideCash = computed(() => screen.value?.hideCash === undefined ? false : !!read(screen.value.hideCash))
const appName = computed(() => {
  if (screen.value?.title !== undefined) return read(screen.value.title)
  if (route.meta.phone?.title !== undefined) return route.meta.phone.title
  return apps.value.find(app => app.id === (route.meta.phone?.appId ?? route.params.appId))?.name ?? BUILTIN_PHONE_APP_NAMES[route.meta.phone?.appId ?? route.params.appId] ?? ''
})
function formatCash(money) {
  if (money >= 1e12) return `$${(money / 1e12).toFixed(1)}T`
  if (money >= 1e9) return `$${(money / 1e9).toFixed(1)}B`
  if (money >= 1e6) return `$${(money / 1e6).toFixed(1)}M`
  return `$${Math.round(money).toLocaleString()}`
}
const cashDisplay = computed(() => isCareer.value && careerMoney.value != null ? formatCash(careerMoney.value) : null)
// The balance opens the app whose manifest says `opensFromBalance`, found in the app registry. An app
// that is not on this phone (App Store apps start uninstalled) leaves the balance as plain text:
// a button that opens nothing would only mislead, and the store is not where a balance tap belongs.
// On that app's own screen the balance has nowhere to go either.
const balanceApp = computed(() => {
  const app = apps.value.find(entry => entry.opensFromBalance === true && entry.route)
  if (!app) return null
  const onPhone = app.systemApp === true || SYSTEM_APP_IDS.has(app.id) || PREINSTALLED_APP_IDS.includes(app.id) || installedAppIds.value.includes(app.id)
  const openHere = (route.meta.phone?.appId ?? route.params.appId) === app.id
  return onPhone && !openHere ? app : null
})
function openBalanceApp() {
  if (balanceApp.value) navigatePhoneRoute(router, balanceApp.value.route)
}
const timeParts = computed(() => {
  const match = (timeString.value || '').match(/^(.+?)\s+(AM|PM)$/i)
  return match ? { main: match[1], period: ` ${match[2]}` } : { main: timeString.value, period: '' }
})
const wrapperStyle = computed(() => {
  const scale = getPhoneScale(phoneSettings)
  const range = Math.max(0, viewportWidth.value - (360 * scale + 24) - 64)
  return { '--scale': String(scale), '--phone-right': `${32 + range * (1 - getPhonePosition(phoneSettings))}px` }
})
const disposeApps = onPhoneAppsChanged(() => { apps.value = [...getPhoneApps()] })
function clearIntent() { intent = null; clearTimeout(intentTimer) }
const host = {
  register(options) {
    const entry = { routeName: route.name, options }
    registration.value = entry
    return () => { if (registration.value === entry) registration.value = null }
  },
  setOpenIntent(value) {
    clearIntent()
    intent = { ...value, visual: iconVisual?.(value.appId) }
    intentTimer = setTimeout(clearIntent, 3000)
  },
  clearOpenIntent: clearIntent,
  registerIconVisual(reader) {
    iconVisual = reader
    return () => { if (iconVisual === reader) iconVisual = null }
  },
}
provide(Symbol.for('overhaul.phoneScreen'), host)

function active(owner) { return !destroyed && owner === opening && owner.token === session && !owner.closed }
function queueMark(action) {
  markOperations = markOperations.then(action).catch(error => reportUiFailure(error, 'Phone opening session'))
  return markOperations
}
function stopIdle() {
  if (idleHandle === null) return
  if (window.cancelIdleCallback) window.cancelIdleCallback(idleHandle)
  else clearTimeout(idleHandle)
  idleHandle = null
}
function preloadInstalled(owner) {
  const ids = new Set(readPhoneShellState()?.layout?.installedAppIds || [])
  const entries = getFeatureRoutes().filter(entry => ids.has(entry.ownerId))
  const files = [...new Set(entries.map(entry => entry.component))]
  let timer = null
  let navigating = false
  const disposeBefore = router.beforeEach(() => { navigating = true })
  const disposeAfter = router.afterEach(() => { navigating = false })
  const disposeState = watch(state, value => { if (value === 'closed') cleanup() }, { flush: 'sync' })
  function cleanup() {
    clearTimeout(timer)
    disposeBefore()
    disposeAfter()
    disposeState()
  }
  const next = (delay = 250) => {
    if (!active(owner) || state.value !== 'open' || !files.length) { cleanup(); return }
    timer = setTimeout(() => {
      timer = null
      const schedule = window.requestIdleCallback || (callback => setTimeout(callback, 50))
      idleHandle = schedule(async () => {
        idleHandle = null
        if (!active(owner)) { cleanup(); return }
        if (state.value !== 'open' || navigating || animations.size || intent || route.name !== 'phone-main') { next(); return }
        const file = files.shift()
        const foreground = entries.some(entry => entry.component === file && entry.name === route.name)
        if (!foreground) {
          try { await loadRuntimeComponent(file) } catch { /* Foreground loading owns the retryable error. */ }
        }
        next()
      }, { timeout: 2000 })
    }, delay)
  }
  next(2000)
}
function commitClose(owner = opening) {
  if (!owner || owner.closed) return
  owner.closed = true
  stopIdle()
  for (const scope of owner.scopes) releaseScope(lua, scope)
  owner.scopes.clear()
  if (owner.openSent) queueMark(() => callModLua('overhaul_phone_phone.markClosed'))
  clearPhoneHeadsUpNotifications()
  if (owner === opening) {
    isEntered.value = false
    setPhoneShellVisible(false)
    state.value = 'closed'
  }
}
function restoreOpen() {
  if (!opening || opening.closed) return
  state.value = 'open'
  isEntered.value = true
  setPhoneShellVisible(true)
}
async function ensureOpen() {
  if (destroyed || state.value === 'opening' || state.value === 'open') return
  if (state.value === 'closing' && opening && !opening.closed) { restoreOpen(); return }
  const owner = { token: ++session, closed: false, openSent: false, scopes: new Set() }
  opening = owner
  state.value = 'opening'
  setPhoneShellVisible(true)
  nextTick(() => requestAnimationFrame(() => { if (active(owner)) isEntered.value = true }))
  function acquire(scope) { owner.scopes.add(scope); return acquireScope(lua, scope) }
  try {
    // Start this in setup, before a child's mounted hook reaches Lua.
    await acquire('phone.phone')
    if (!active(owner)) return
    await queueMark(async () => {
      if (!active(owner)) return
      owner.openSent = true
      await callModLua('overhaul_phone_phone.markOpen')
    })
    if (!active(owner)) return
    await Promise.all([acquire('phone.time'), acquire('phone.layout')])
    if (!active(owner)) return
    if (!readPhoneShellState()) await callModLua('overhaul_phone_phone.requestState')
    if (!active(owner)) return
    await callModLuaIfAvailable('overhaul_phone_apps_time.requestTime')
    if (!active(owner)) return
    state.value = 'open'
    phoneTutorial.notifyPhoneVisible()
    preloadInstalled(owner)
  } catch (error) {
    if (active(owner)) { reportUiFailure(error, 'Open phone shell'); commitClose(owner) }
  }
}
function forceClose() {
  session++
  commitClose()
}
function updateTime(time) {
  if (!time) return
  timeString.value = time
  sessionStorage.setItem('phone_last_time', time)
}
function handlePhoneLayoutData(layout) {
  if (layout?.settings) replacePhoneSettings(layout.settings)
  if (layout?.installedAppIds !== undefined) installedAppIds.value = toIdList(layout.installedAppIds)
}
function handlePhoneShellState(data) {
  if (!data || typeof data !== 'object') return
  if (data.time) updateTime(data.time)
  isCareer.value = data.careerActive === true
  careerMoney.value = data.money ?? null
  handlePhoneLayoutData(data.layout)
}
function handleOpeningState(data) {
  handlePhoneShellState(data)
  if (isPhoneRoute(router.currentRoute.value)) ensureOpen()
}
function updateViewportWidth() { viewportWidth.value = window.innerWidth }
// Topic replacement removes the focused row. Keep Back in the shell's stock
// navigation scope even when DOM focus falls back to the document body.
const navScope = computed(() => ({
  scopeId: 'phone-shell', activateOnMount: true, trapPolicy: 'always',
  bubbleWhitelistEvents: ['menu'],
  // Reasserting activated:true on every clock/cash render resumes this parent
  // over its modal or slider scope. Activate once when the shell becomes ready.
  ...(!(isPhoneRoute(route) && state.value === 'open' && !phoneOpeningBlocked.value) ? { activated: false } : {}),
  canDeactivate() { if (state.value !== 'open') return true; back(); return false },
}))
const navigation = useScopedNav()
watch(() => [route.name, state.value === 'open', phoneOpeningBlocked.value], async () => {
  await nextTick()
  if (isPhoneRoute(route) && state.value === 'open' && !phoneOpeningBlocked.value) navigation.activateScope('phone-shell')
})
async function back() {
  if (phoneTutorial.shouldBlockPhoneBack()) return
  if (screen.value?.onBack?.()) return
  if (route.name === 'phone-main') return callModLua('overhaul_phone_phone.closePhone')
  return lua.extensions.ui_router.back()
}

const disposeBefore = router.beforeEach(async to => {
  if (isPhoneRoute(to) || !opening || opening.closed) return
  state.value = 'closing'
  isEntered.value = false
  if (!expanded.value && !window.matchMedia?.('(prefers-reduced-motion: reduce)').matches) {
    await new Promise(resolve => setTimeout(resolve, 180))
  }
})
let transition = { kind: 'none' }
const animations = new Set()
function finishAnimations() { for (const animation of [...animations]) animation.finish() }
function chooseTransition(to, from) {
  if (!isPhoneRoute(from) || !isPhoneRoute(to) || to.name === from.name) return { kind: 'none' }
  if (window.matchMedia?.('(prefers-reduced-motion: reduce)').matches) return { kind: 'fade', duration: 120 }
  const toApp = to.meta.phone?.appId ?? to.params.appId
  const fromApp = from.meta.phone?.appId ?? from.params.appId
  if (from.name === 'phone-main' && intent?.kind === 'icon' && intent.appId === toApp) return { kind: 'zoom-in', duration: 420, visual: intent.visual }
  if (to.name === 'phone-main') return { kind: 'zoom-out', duration: 340, appId: fromApp }
  if (toApp && toApp === fromApp) {
    if (to.meta.phone?.depth > from.meta.phone?.depth) return { kind: 'forward', duration: 280 }
    if (to.meta.phone?.depth < from.meta.phone?.depth) return { kind: 'backward', duration: 220 }
  }
  return { kind: 'scale', duration: 180 }
}
const disposeAfter = router.afterEach((to, from, failure) => {
  if (failure) {
    clearIntent()
    if (isPhoneRoute(router.currentRoute.value)) restoreOpen()
    return
  }
  finishAnimations()
  transition = chooseTransition(to, from)
  clearIntent()
  if (!isPhoneRoute(to)) { session++; commitClose(); return }
  if (state.value === 'closing') restoreOpen()
  else ensureOpen()
})
watch(() => route.name, () => {
  registration.value = null
  if (isPhoneRoute(route) && (state.value === 'closed' || state.value === 'closing')) ensureOpen()
}, { flush: 'sync' })
watch(expanded, () => {
  if (!isPhoneRoute(route)) return
  noTransition.value = true
  requestAnimationFrame(() => requestAnimationFrame(() => { noTransition.value = false }))
}, { flush: 'sync' })

function animate(element, frames, duration, done, extra = {}) {
  if (!element.animate || !duration) { done(); return }
  const animation = element.animate(frames, { duration, easing: 'cubic-bezier(.32,.72,0,1)', ...extra })
  animations.add(animation)
  const finish = () => { animations.delete(animation); done() }
  animation.onfinish = finish
  animation.oncancel = finish
}
function iconTransform(visual) {
  const bounds = contentRef.value?.getBoundingClientRect()
  const rect = visual?.rect
  if (!rect || !bounds?.width) return 'translate(0,0) scale(.12)'
  // DOM rects include the user's phone scale; animation translations are in
  // local CSS pixels. Convert the offset so the layer lands on the actual tile.
  const scaleX = (contentRef.value.clientWidth || bounds.width) / bounds.width
  const scaleY = (contentRef.value.clientHeight || bounds.height) / bounds.height
  return `translate(${(rect.left - bounds.left + rect.width / 2 - bounds.width / 2) * scaleX}px,${(rect.top - bounds.top + rect.height / 2 - bounds.height / 2) * scaleY}px) scale(${rect.width / bounds.width},${rect.height / bounds.height})`
}
function enterScreen(element, done) {
  element.dataset.phoneRoute = route.name
  element.inert = false
  element.setAttribute('bng-no-child-nav', 'true')
  const complete = done
  done = () => { element.setAttribute('bng-no-child-nav', 'false'); complete() }
  element.style.pointerEvents = ''
  const current = transition
  if (current.kind === 'zoom-in') {
    animate(element, [{ transform: iconTransform(current.visual) }, { transform: 'none' }], current.duration, done)
    const tile = document.createElement('div')
    tile.className = 'phone-icon-transition'
    Object.assign(tile.style, { position: 'absolute', inset: '0', zIndex: '2', pointerEvents: 'none', background: current.visual?.color || '#25272c',
      // 100% 100%: the layer's own non-uniform scale undoes the stretch, so the art starts exactly as the
      // icon and grows with it instead of being re-cropped (and seeming to slide) as the shape changes.
      backgroundImage: current.visual?.image ? `url("${current.visual.image}")` : '', backgroundSize: '100% 100%' })
    element.appendChild(tile)
    animate(tile, [{ opacity: 1 }, { opacity: 0 }], current.duration * .35, () => tile.remove())
    return
  }
  const frames = {
    forward: [{ transform: 'translateX(100%)' }, { transform: 'none' }],
    backward: [{ transform: 'translateX(-30%)', opacity: .65 }, { transform: 'none', opacity: 1 }],
    scale: [{ opacity: 0, transform: 'scale(.96)' }, { opacity: 1, transform: 'none' }],
    'zoom-out': [{ transform: 'scale(.92)', opacity: .65 }, { transform: 'none', opacity: 1 }],
    fade: [{ opacity: 0 }, { opacity: 1 }],
  }
  animate(element, frames[current.kind] || [], current.duration || 0, done)
}
function leaveScreen(element, done) {
  element.inert = true
  element.setAttribute('bng-no-nav', 'true')
  element.setAttribute('bng-no-child-nav', 'true')
  element.style.pointerEvents = 'none'
  const current = transition
  const finish = () => { element.style.zIndex = ''; done() }
  // Clear the old screen before the incoming zoom/slide exposes its content.
  // Keep it mounted until the movement ends so interruption cleanup is shared.
  const leave = frames => animate(element, [
    { ...frames[0], opacity: 1, offset: 0 },
    { opacity: 0, offset: Math.min(50 / current.duration, 1) },
    { ...frames[1], opacity: 0, offset: 1 },
  ], current.duration || 0, finish)
  // Reverse paths briefly paint the departing page above the incoming layer.
  element.style.zIndex = ['zoom-out', 'backward'].includes(current.kind) ? '1' : ''
  if (current.kind === 'zoom-out') {
    requestAnimationFrame(() => {
      if (transition !== current) { finish(); return }
      leave([{ transform: 'none' }, { transform: iconTransform(iconVisual?.(current.appId)) }])
    })
    return
  }
  const frames = {
    forward: [{ transform: 'none' }, { transform: 'translateX(-30%)' }],
    backward: [{ transform: 'none' }, { transform: 'translateX(100%)' }],
    'zoom-in': [{ transform: 'none' }, { transform: 'scale(.92)' }],
  }
  if (!current.duration) { finish(); return }
  leave(frames[current.kind] || [{}, {}])
}

const bindings = { phone_time_update: updateTime, closePhone: forceClose, phoneLayoutData: handlePhoneLayoutData,
  phoneShellState: handleOpeningState, phoneShellStatus: handlePhoneShellState }
for (const [name, listener] of Object.entries(bindings)) events.on(name, listener)
ensureOpen()
onMounted(() => { window.addEventListener('resize', updateViewportWidth) })
onUnmounted(() => {
  destroyed = true
  session++
  commitClose()
  finishAnimations()
  clearIntent()
  disposeApps()
  disposeBefore()
  disposeAfter()
  window.removeEventListener('resize', updateViewportWidth)
  for (const [name, listener] of Object.entries(bindings)) events.off(name, listener)
})
</script>

<style scoped lang="scss">
.phone-shell.phone-expanded {
  /* enlarged apps stay a 16:9 board centred on screen, never stretched to an ultrawide frame */
  --board-h: min(calc(100vh - 48px), calc((100vw - 48px) * 9 / 16));
  inset: auto;
  top: 50%;
  left: 50%;
  width: calc(var(--board-h) * 16 / 9);
  height: var(--board-h);
  transform: translate(-50%, -50%) !important;
  transition: none;
  .phone-screen { width: 100%; height: 100%; border-radius: 20px; }
  .phone-bevel { border-radius: 24px; }
}
.phone-shell {
  position: fixed;
  bottom: 1em;
  right: var(--phone-right, 2em);
  z-index: 1000;
  transform: scale(var(--scale)) translateY(calc(100% + 2.5em));
  transform-origin: bottom right;
  opacity: 1;
  transition: transform 0.18s cubic-bezier(0.2, 0.8, 0.2, 1);
  
  &.phone-entered {
    transform: scale(var(--scale)) translateY(0);
  }
  
  .phone-bevel {
    position: absolute;
    top: -0.35em;
    left: -0.35em;
    right: -0.35em;
    bottom: -0.35em;
    border-radius: 2.5em;
    background: linear-gradient(160deg, #2a2a2a 0%, #0a0a0a 40%, #000 100%);
    border: 1px solid rgba(120, 120, 120, 0.35);
    box-shadow:
      0 0 0 1px rgba(0, 0, 0, 0.8),
      0 4px 20px rgba(0, 0, 0, 0.6),
      inset 0 1px 0 rgba(255, 255, 255, 0.06);
  }

  .phone-screen {
    /* The status bar overlays every app. Apps that start with text pad their top by this
       (padding-top: var(--phone-status-bar-height)); rem keeps it the same in any app font. */
    --phone-status-bar-height: max(36px, calc(28px + 1.1rem));
    --phone-status-bar-content-gap: 6px;
    position: relative;
    width: 360px;
    height: 640px;
    border-radius: 2em;
    overflow: hidden;
    background: transparent;

    :deep(.card-cnt) {
      height: 100%;
      overflow: hidden;
    }
  }

  .phone-content {
    height: 100%;
    overflow-y: hidden;
    color: white;

    position: relative;
    background: #15171d;
    :deep(> *) { position: absolute; inset: 0; width: 100%; height: 100%; }
  }
}
.phone-shell.no-transition { transition: none !important; }
.phone-shell:not(.phone-entered) { pointer-events: none; }

.phone-status-bar {
  box-sizing: border-box;
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  display: flex;
  align-items: center;
  justify-content: space-between;
  /* 28px cells + 1.1rem of padding make up --phone-status-bar-height */
  padding: 0.5rem 1em 0.6rem;
  min-height: var(--phone-status-bar-height);
  z-index: 10;
  pointer-events: none;

  &::before {
    content: '';
    position: absolute;
    inset: 0;
    background: linear-gradient(to bottom, rgba(0,0,0,0.35) 0%, rgba(0,0,0,0) 100%);
    pointer-events: none;
    z-index: -1;
  }
}

.status-bar-cell {
  display: flex;
  align-items: center;
  min-height: 28px;
}

.status-bar-left {
  justify-content: flex-start;
  flex: 1;
  min-width: 0;
}

.status-bar-center {
  position: absolute;
  left: 50%;
  transform: translateX(-50%);
  flex-shrink: 0;
}

.status-bar-right {
  justify-content: flex-end;
  flex: 1;
  min-width: 0;
}

.status-right-pill {
  display: flex;
  align-items: center;
  height: 24px;
  padding: 0 0.6em;
  background: rgba(0, 0, 0, 0.55);
  border: 1px solid rgba(255, 255, 255, 0.12);
  border-radius: 12px;
}

.dynamic-island {
  display: flex;
  align-items: center;
  justify-content: center;
  min-width: 80px;
  max-width: 140px;
  height: 24px;
  padding: 0 0.75em;
  background: #000;
  border-radius: 12px;
  flex-shrink: 0;
}

.dynamic-island-label {
  font-size: 0.8em;
  font-weight: 500;
  color: rgba(255, 255, 255, 0.65);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.status-time {
  display: inline-flex;
  align-items: flex-end;
  font-size: 1.2em;
  font-weight: 500;
  line-height: 1;
  margin-left: 0.5em;
}

.status-time-period {
  font-size: 0.6em;
  font-weight: 400;
  margin-left: 0.25em;
}

/* The status bar passes pointer events through to the screen below; the balance button takes them back. */
.status-balance-button {
  margin: 0;
  color: inherit;
  font: inherit;
  cursor: pointer;
  pointer-events: auto;
  transition: border-color 120ms ease;
}

.status-balance-button:hover {
  border-color: rgba(255, 255, 255, 0.32);
}

.status-cash {
  font-size: 0.95em;
  font-weight: 500;
  color: #fff;
}

.status-back {
  display: flex;
  align-items: center;
  gap: 0.5em;
  height: 24px;
  padding: 0 0.75em;
  line-height: 1;
  background: rgba(0, 0, 0, 0.55);
  border: 1px solid rgba(255, 255, 255, 0.12);
  border-radius: 12px;
  outline: none;
  cursor: pointer;
  pointer-events: auto;
  font-size: 14px;
  font-weight: 500;
  color: #fff;
  transition: background 0.15s ease, transform 0.12s ease;

  &:hover {
    background: rgba(0, 0, 0, 0.7);
  }

  &:active {
    background: rgba(0, 0, 0, 0.8);
    transform: scale(0.96);
  }
}

.status-back-icon {
  display: flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
}

@media (prefers-reduced-motion: reduce) {
  .phone-shell { transition: none; }

}
</style>
