<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <Teleport to="body">
    <div ref="navigationRoot" class="phone-lock-root" bng-no-nav="true" bng-no-child-nav="true" aria-live="polite" aria-atomic="true" :style="rootStyle">
      <PhoneNavigation :root="navigationRoot" />
      <Transition name="phone-lock-peek">
        <article v-if="queue.length" class="phone-lock-peek">
          <div class="phone-lock-bevel"></div>
          <div class="phone-lock-screen" :style="screenStyle">
            <!-- The newest arrival shows as a banner at the top of the peeking phone, like the open phone's
                 banner. Older ones wait behind it (card edges and "N more"); the full list is in the
                 Notification Center. -->
            <div class="phone-lock-stack">
              <TransitionGroup name="phone-lock-row">
                <article
                  v-for="item in queue.slice(0, 1)"
                  :key="item.id"
                  ref="cardEls"
                  :data-card-id="item.id"
                  class="rls-house phone-lock-card"
                  :class="[`phone-lock-card--${item.kind}`, `phone-lock-card--edges-${edgeCount}`]"
                  :style="swipeFor(item.id).swipeStyle.value"
                  role="button"
                  tabindex="0"
                  @click="onCardClick(item)"
                  @keydown.enter.prevent="onCardClick(item)"
                  @keydown.space.prevent="onCardClick(item)"
                  @pointerdown="swipeFor(item.id).onPointerDown($event)"
                  @pointermove="swipeFor(item.id).onPointerMove($event)"
                  @pointerup="swipeFor(item.id).onPointerEnd($event)"
                  @pointercancel="swipeFor(item.id).onPointerCancel($event)"
                >
                  <PhoneNotificationContent :item="item" :more-count="queue.length - 1" />
                  <span
                    v-for="edge in edgeCount"
                    :key="edge"
                    class="phone-lock-card__edge"
                    :class="`phone-lock-card__edge--${edge}`"
                    aria-hidden="true"
                  ></span>
                </article>
              </TransitionGroup>
            </div>
          </div>
        </article>
      </Transition>
    </div>
  </Teleport>
</template>

<script setup>
import PhoneNavigation from './phone/PhoneNavigation.vue'
import PhoneNotificationContent from './phone/PhoneNotificationContent.vue'
import { isPhoneRoute } from "../utils/phoneRoutes.js"
import { isPhoneShellVisible } from "../utils/phoneShellState"
import { luaLiteral } from "../utils/luaLiteral.js"
import { safeLua } from "../utils/safeLua.js"

import { computed, onBeforeUnmount, onMounted, ref, watch } from "vue"
import { useRoute, useRouter } from "vue-router"
import { lua, useBridge } from "@/bridge"
import { useEvents } from "@/services/events"
import { loadingScreen } from "@/services/screenCover"
import {
  usePhoneSettings,
  getPhoneScale,
  getPhonePosition,
  isDoNotDisturbActive,
  getUnixNowSeconds,
} from "../composables/usePhoneSettings"
import { pushHeadsUpNotification, clearPhoneHeadsUpNotifications, dismissCurrentHeadsUp } from "../composables/usePhoneHeadsUpNotification"
import {
  normalizePhoneNotificationPayload,
  applyLockScreenNotificationPrefs,
  applyBannerNotificationPrefs,
} from "../utils/phoneNotificationPayload"
import { openNotification } from "../utils/phoneNotificationRoutes"
import { openPhoneRoute } from "../utils/phoneNavigation"
import { useHorizontalSwipeDismiss } from "../composables/useHorizontalSwipeDismiss"
import { isNotificationCenterCareer, keepNotificationCenterFor, onNotificationCenterRemoved, recordPhoneNotification, removeNotificationCenterEntries } from "../composables/usePhoneNotificationCenter"
import { loadNotificationApps } from "../utils/phoneNotificationApps"

const DEFAULT_TTL_SECONDS = 8
const MAX_QUEUE_SIZE = 5
const MAX_PENDING_SIZE = 20
const DEFAULT_SOUND = {
  soundClass: "AudioGui",
  type: "event:>UI>Missions>Info_Open",
}

const PADDING = 32
const PHONE_BASE_WIDTH = 360
const PHONE_BEVEL = 24

const bridge = useBridge()
const route = useRoute()
const router = useRouter()
const events = useEvents()
const { phoneSettings, replacePhoneSettings, setPhoneSettings, getPhoneSettingsSnapshot } = usePhoneSettings()

const navigationRoot = ref(null)
const queue = ref([])
const cardEls = ref([])
// One swipe state per card id, created when the card first renders and dropped once it leaves the queue.
const swipeControllers = new Map()
const viewportWidth = ref(typeof window !== "undefined" ? window.innerWidth : 1920)
const rlsLoadingVisible = ref(false)
const proxyTeamLoadingVisible = ref(false)
const pendingNotifications = []
const NOTIFICATION_CENTER_ROUTE = "phone-notification-center"
let nextId = 1
let phoneOpenCheckId = null
let dndCheckInterval = null

const isUiLoading = computed(() =>
  loadingScreen.shown || rlsLoadingVisible.value || proxyTeamLoadingVisible.value
)

const normalizeOverlayPayload = raw => {
  if (!raw || typeof raw !== "object") return {}
  if (Array.isArray(raw) && raw.length > 0 && raw[0] && typeof raw[0] === "object" && !Array.isArray(raw[0])) {
    return raw[0]
  }
  return raw
}

const onRlsCareerLoading = (...args) => {
  const d = normalizeOverlayPayload(args.length > 0 ? args[0] : null)
  rlsLoadingVisible.value = d.visible === true
}

const onProxyTeamLoading = (...args) => {
  const d = normalizeOverlayPayload(args.length > 0 ? args[0] : null)
  proxyTeamLoadingVisible.value = d.visible === true
}

const flushPendingNotifications = () => {
  if (isUiLoading.value || !pendingNotifications.length) return
  const batch = pendingNotifications.splice(0)
  // Delivered now, so none is left to count as the leaving career's.
  heldFromLeavingCareer = 0
  batch.forEach(deliverNotification)
}

const rootStyle = computed(() => {
  const scale = getPhoneScale(phoneSettings)
  const position = getPhonePosition(phoneSettings)
  const phoneWidth = PHONE_BASE_WIDTH * scale + PHONE_BEVEL
  const vw = viewportWidth.value
  const range = Math.max(0, vw - phoneWidth - 2 * PADDING)
  const rightPx = PADDING + range * (1 - position)
  return {
    "--phone-lock-scale": String(scale),
    "--phone-lock-right": `${rightPx}px`,
  }
})

const screenStyle = computed(() => {
  const bg = phoneSettings.backgroundColor || "#1509fb"
  const image = phoneSettings.backgroundImage
  if (image) {
    return {
      backgroundColor: bg,
      backgroundImage: `linear-gradient(180deg, rgba(0,0,0,0) 0%, rgba(0,0,0,0.35) 100%), url('${image}')`,
      backgroundSize: "cover",
      backgroundPosition: "center",
    }
  }
  return {
    backgroundColor: bg,
    backgroundImage: `linear-gradient(180deg, rgba(255,255,255,0.04) 0%, rgba(0,0,0,0.25) 100%)`,
  }
})

// Notifications still waiting behind the shown banner peek out as up to two card edges.
const MAX_STACK_EDGES = 2
const edgeCount = computed(() => Math.min(queue.value.length - 1, MAX_STACK_EDGES))

const isPhoneOpen = () => isPhoneRoute(route) || isPhoneShellVisible()

const sanitizeText = (value, fallback = "") => {
  const text = value == null ? fallback : value
  return String(text).trim()
}

const normalizePayload = raw => normalizePhoneNotificationPayload(raw)

const resolveSound = payload => {
  if (payload.sound === false || payload.sound === "none") return null
  if (payload.sound && typeof payload.sound === "object") {
    const resolvedClass = sanitizeText(payload.sound.soundClass, DEFAULT_SOUND.soundClass) || DEFAULT_SOUND.soundClass
    const type = sanitizeText(payload.sound.type || payload.sound.event, DEFAULT_SOUND.type)
    return type ? { soundClass: resolvedClass, type, raw: type.startsWith("event:") || resolvedClass === "AudioGui" } : null
  }
  if (typeof payload.sound === "string" && payload.sound.trim()) {
    const resolvedClass = sanitizeText(payload.soundClass, DEFAULT_SOUND.soundClass) || DEFAULT_SOUND.soundClass
    const type = payload.sound.trim()
    return {
      soundClass: resolvedClass,
      type,
      raw: type.startsWith("event:") || resolvedClass === "AudioGui",
    }
  }
  const resolvedClass = sanitizeText(payload.soundClass, DEFAULT_SOUND.soundClass) || DEFAULT_SOUND.soundClass
  const type = payload.soundType || DEFAULT_SOUND.type
  return {
    soundClass: resolvedClass,
    type,
    raw: type.startsWith("event:") || resolvedClass === "AudioGui",
  }
}

// Notification sound names historically turn carriage returns into line feeds.
const toLuaString = value => luaLiteral(String(value).replace(/\r/g, "\n"))

const playSound = payload => {
  const sound = resolveSound(payload)
  if (!sound) return
  if (sound.raw && bridge.api?.engineLua) {
    bridge.api.engineLua(`Engine.Audio.playOnce(${toLuaString(sound.soundClass || DEFAULT_SOUND.soundClass)}, ${toLuaString(sound.type)})`)
    return
  }
  if (!lua.ui_audio?.playEventSound) return
  safeLua(lua.ui_audio.playEventSound(sound.soundClass, sound.type), "PhoneLockNotificationOverlay: playSound")
}

const dismissById = id => {
  const idx = queue.value.findIndex(item => item.id === id)
  if (idx === -1) return
  const [removed] = queue.value.splice(idx, 1)
  if (removed?.timeoutId) window.clearTimeout(removed.timeoutId)
}

const swipeFor = id => {
  let swipe = swipeControllers.get(id)
  if (!swipe) {
    swipe = useHorizontalSwipeDismiss({
      getElementEl: () => cardEls.value.find(el => el.dataset.cardId === String(id)),
      onDismiss: () => dismissById(id),
    })
    swipeControllers.set(id, swipe)
  }
  return swipe
}

// A notification cleared or opened in the Notification Center leaves the closed-phone queue too; the
// front-banner timer then starts for whichever banner is next.
const withdrawCleared = centerIds => {
  const gone = new Set(centerIds)
  // Collected first: dismissById takes items out of the queue being read.
  const leaving = queue.value.filter(item => gone.has(item.centerId)).map(item => item.id)
  leaving.forEach(dismissById)
}
let stopWithdrawing = null

// Loading a career keeps the list when it is the same one (a map travel leaves and loads it again) and
// starts it over for any other, which also takes back the banners still waiting. Arrivals held back by a
// loading screen when the career left are dropped only if another career is loaded; on a travel they stay.
let heldFromLeavingCareer = 0
const onCareerChange = data => {
  if (!data?.active) {
    heldFromLeavingCareer = pendingNotifications.length
    return
  }
  if (!isNotificationCenterCareer(data.profile)) pendingNotifications.splice(0, heldFromLeavingCareer)
  heldFromLeavingCareer = 0
  keepNotificationCenterFor(data.profile)
}

const openNewest = () => { if (queue.value.length) return handleNotificationClick(queue.value[0]) }
const dismissNewest = () => { if (queue.value.length) dismissById(queue.value[0].id) }

const onCardClick = item => {
  const { suppressClick } = swipeFor(item.id)
  if (suppressClick.value) {
    suppressClick.value = false
    return
  }
  handleNotificationClick(item)
}

watch(() => queue.value.map(item => item.id), ids => {
  for (const id of swipeControllers.keys()) {
    if (!ids.includes(id)) swipeControllers.delete(id)
  }
  // Only the banner on show counts down; the ones waiting behind it start theirs when they come up.
  queue.value.forEach((item, index) => {
    if (index === 0 && !item.timeoutId) scheduleTimeout(item)
    if (index > 0 && item.timeoutId) {
      window.clearTimeout(item.timeoutId)
      item.timeoutId = null
    }
  })
})

const handleNotificationClick = async item => {
  if (!item) return
  dismissById(item.id)
  if (isPhoneOpen()) {
    dismissCurrentHeadsUp()
  }
  // Once it opened, it has been seen: it leaves the Notification Center too.
  if (await openNotification(item, { lua, router, navigate: openPhoneRoute })) removeNotificationCenterEntries([item.centerId])
}

const scheduleTimeout = item => {
  item.timeoutId = window.setTimeout(() => dismissById(item.id), Math.max(1800, item.ttl * 1000))
}

const deliverNotification = raw => {
  const parsed = normalizePhoneNotificationPayload(raw)
  if (!parsed) return
  // Like iOS, the Notification Center keeps every notification, also ones Do Not Disturb or the
  // banner switches keep quiet. Banners carry their entry's id so opening one clears it there too.
  const normalized = { ...parsed, centerId: recordPhoneNotification(parsed)?.id }
  if (isDoNotDisturbActive(phoneSettings)) return

  const phoneOpen = isPhoneOpen()
  const useLockPath = normalized.forcePeek || !phoneOpen

  if (useLockPath) {
    if (phoneSettings.lockScreenNotificationsEnabled === false) return
    const payload = applyLockScreenNotificationPrefs(normalized, phoneSettings)

    if (payload.replaceKey) {
      const existingIdx = queue.value.findIndex(item => item.replaceKey === payload.replaceKey)
      if (existingIdx !== -1) {
        const existing = queue.value[existingIdx]
        if (existing.timeoutId) window.clearTimeout(existing.timeoutId)
        const item = { ...existing, ...payload, id: existing.id }
        queue.value[existingIdx] = item
        if (existingIdx === 0) scheduleTimeout(item)
        if (payload.sound !== false && payload.sound !== "none") playSound(item)
        return
      }
    }

    const item = { ...payload, id: nextId++ }
    queue.value = [item, ...queue.value]
    if (queue.value.length > MAX_QUEUE_SIZE) {
      const overflow = queue.value.slice(MAX_QUEUE_SIZE)
      queue.value = queue.value.slice(0, MAX_QUEUE_SIZE)
      overflow.forEach(o => o.timeoutId && window.clearTimeout(o.timeoutId))
    }
    playSound(item)
    return
  }

  if (phoneSettings.bannerNotificationsEnabled === false) return
  // The Notification Center on screen already lists it at the top, as on iOS; a banner over it would only
  // repeat it, so it just sounds.
  if (route.name === NOTIFICATION_CENTER_ROUTE) {
    playSound(normalized)
    return
  }
  const payload = applyBannerNotificationPrefs(normalized, phoneSettings)
  const result = pushHeadsUpNotification(payload)
  if (!result || result.playSound !== false) playSound(payload)
}

const pushNotification = raw => {
  if (isUiLoading.value) {
    pendingNotifications.push(raw)
    if (pendingNotifications.length > MAX_PENDING_SIZE) {
      // The cap drops the oldest first; the leaving career's count shrinks with them.
      const dropped = pendingNotifications.length - MAX_PENDING_SIZE
      pendingNotifications.splice(0, dropped)
      heldFromLeavingCareer = Math.max(0, heldFromLeavingCareer - dropped)
    }
    return
  }
  deliverNotification(raw)
}

const clearAll = () => {
  queue.value.forEach(item => item.timeoutId && window.clearTimeout(item.timeoutId))
  queue.value = []
}

const handlePhoneLayoutData = data => {
  if (!data || typeof data !== "object" || !data.settings) return
  replacePhoneSettings(data.settings)
  expireDndIfNeeded()
}

function expireDndIfNeeded() {
  if (!phoneSettings.doNotDisturb || phoneSettings.doNotDisturbUntil == null) return
  if (getUnixNowSeconds() < phoneSettings.doNotDisturbUntil) return
  setPhoneSettings({ doNotDisturb: false, doNotDisturbUntil: null })
  lua.overhaul_phone_apps_layout?.updateSettings?.(getPhoneSettingsSnapshot())?.catch?.(() => {})
}

const updateViewportWidth = () => {
  viewportWidth.value = window.innerWidth
}

watch(() => route.name, () => {
  if (isPhoneOpen()) {
    clearAll()
  } else {
    clearPhoneHeadsUpNotifications()
  }
})

watch(isUiLoading, (loading, wasLoading) => {
  if (wasLoading && !loading) flushPendingNotifications()
})

watch(() => queue.value.length, (len, prevLen) => {
  if (len > 0 && !phoneOpenCheckId) {
    phoneOpenCheckId = window.setInterval(() => {
      if (queue.value.length && isPhoneOpen()) clearAll()
    }, 1000)
  } else if (len === 0 && phoneOpenCheckId) {
    window.clearInterval(phoneOpenCheckId)
    phoneOpenCheckId = null
  }
})

onMounted(async () => {
  updateViewportWidth()
  window.addEventListener("resize", updateViewportWidth)

  events.on("OverhaulNotificationOpen", openNewest)
  events.on("OverhaulNotificationDismiss", dismissNewest)
  events.on("PhoneLockNotification", pushNotification)
  events.on("phoneLayoutData", handlePhoneLayoutData)
  stopWithdrawing = onNotificationCenterRemoved(withdrawCleared)
  events.on("PhoneNotificationCenterCareer", onCareerChange)
  // vueEventBus and bridge.events are the same emitter.
  bridge.events.on("rlsCareerLoadingOverlay", onRlsCareerLoading)
  bridge.events.on("racingTeamProxyTeamLoading", onProxyTeamLoading)

  loadNotificationApps()
  keepNotificationCenterFor(await safeLua(() => lua.overhaul_career_saveSystem?.getCurrentProfile?.(), "PhoneLockNotificationOverlay: current career"))
  await safeLua(() => lua.extensions?.load?.("overhaul_phone_apps_layout"), "PhoneLockNotificationOverlay: optional call")
  lua.overhaul_phone_apps_layout?.requestLayout?.()
  dndCheckInterval = window.setInterval(expireDndIfNeeded, 15000)
})

onBeforeUnmount(() => {
  stopWithdrawing?.()
  clearAll()
  pendingNotifications.length = 0
  if (phoneOpenCheckId) {
    window.clearInterval(phoneOpenCheckId)
    phoneOpenCheckId = null
  }
  if (dndCheckInterval) {
    window.clearInterval(dndCheckInterval)
    dndCheckInterval = null
  }
  window.removeEventListener("resize", updateViewportWidth)
  events.off("OverhaulNotificationOpen", openNewest)
  events.off("OverhaulNotificationDismiss", dismissNewest)
  events.off("PhoneLockNotification", pushNotification)
  events.off("PhoneNotificationCenterCareer", onCareerChange)
  events.off("phoneLayoutData", handlePhoneLayoutData)
  bridge.events.off("rlsCareerLoadingOverlay", onRlsCareerLoading)
  bridge.events.off("racingTeamProxyTeamLoading", onProxyTeamLoading)
})
</script>

<style scoped lang="scss">
@use '@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss' as *;
@use '@/styles/rls_career_overhaul/modules/career/styles/_phone-notification-text.scss' as phone-notif;

.phone-lock-root {
  position: fixed;
  inset: 0;
  z-index: 13060;
  pointer-events: none;
  font-family: var(--fnt-defs, "Noto Sans", Arial, sans-serif);
}

.phone-lock-peek {
  position: fixed;
  bottom: 0;
  right: var(--phone-lock-right, 2em);
  width: 360px;
  transform: scale(var(--phone-lock-scale, 1));
  transform-origin: bottom right;
  pointer-events: auto;
  filter: drop-shadow(0 12px 28px rgba(0, 0, 0, 0.55));
}

.phone-lock-bevel {
  position: absolute;
  top: -0.35em;
  left: -0.35em;
  right: -0.35em;
  bottom: -2em;
  border-radius: 2.5em 2.5em 0 0;
  background: linear-gradient(160deg, #2a2a2a 0%, #0a0a0a 40%, #000 100%);
  border: 1px solid rgba(120, 120, 120, 0.35);
  border-bottom: none;
  box-shadow:
    0 0 0 1px rgba(0, 0, 0, 0.8),
    inset 0 1px 0 rgba(255, 255, 255, 0.06);
}

.phone-lock-screen {
  position: relative;
  width: 100%;
  max-width: 100%;
  overflow: hidden;
  border-radius: 2em 2em 0 0;
  display: flex;
  flex-direction: column;
  padding: 0 0 18px;
  box-sizing: border-box;
  box-shadow: inset 0 0 0 1px rgba(255, 255, 255, 0.08);
}

.phone-lock-stack {
  position: relative;
  z-index: 11;
  display: flex;
  flex-direction: column;
  width: 100%;
  max-width: 100%;
  min-width: 0;
  box-sizing: border-box;
  // Inset like the open phone's banner, which drops over its status bar.
  padding: 8px 8px 0;
}

.phone-lock-peek-enter-active,
.phone-lock-peek-leave-active {
  transition: opacity 0.28s ease, transform 0.5s cubic-bezier(0.34, 1.56, 0.64, 1);
}

.phone-lock-peek-enter-from,
.phone-lock-peek-leave-to {
  opacity: 0;
  transform: scale(var(--phone-lock-scale, 1)) translateY(100%);
}

.phone-lock-row-enter-active,
.phone-lock-row-leave-active {
  transition: opacity 0.25s ease, transform 0.3s ease;
  max-width: 100%;
  min-width: 0;
}

// A leaving banner steps out of the flow at once, so the next one takes its place without a jump.
// Left and right match the stack's side padding.
.phone-lock-card.phone-lock-row-leave-active {
  position: absolute;
  left: 8px;
  right: 8px;
  width: auto;
}

.phone-lock-row-enter-from {
  opacity: 0;
  transform: translateY(-8px);
}

.phone-lock-row-leave-to {
  opacity: 0;
  transform: translateX(20px);
}

.phone-lock-row-leave-active[data-swipe-dismissed="1"] {
  transition: none !important;
}

.phone-lock-row-leave-to[data-swipe-dismissed="1"] {
  opacity: 0;
  transform: none;
}

.phone-lock-row-move {
  transition: transform 0.3s ease;
}

.phone-lock-card {
  @include phone-notif.phone-notif-card;
  max-width: 100%;
  border-radius: 18px;
  box-shadow: 0 6px 16px rgba(0, 0, 0, 0.35);
  // Controller focus is the phone-wide ring from overhaulFocus.scss (every [role="button"] in the phone).
}

// Room under a stack for its peeking edges.
.phone-lock-card--edges-1 { margin-bottom: 7px; }
.phone-lock-card--edges-2 { margin-bottom: 13px; }

@include phone-notif.phone-notif-stack-edges('.phone-lock-card__edge');

// Reduced motion: the peek and its cards fade in place, with no slide, bounce or reflow motion.
@media (prefers-reduced-motion: reduce) {
  .phone-lock-peek-enter-active,
  .phone-lock-peek-leave-active,
  .phone-lock-row-enter-active,
  .phone-lock-row-leave-active {
    transition: opacity 0.16s ease;
  }

  .phone-lock-peek-enter-from,
  .phone-lock-peek-leave-to {
    transform: scale(var(--phone-lock-scale, 1));
  }

  .phone-lock-row-enter-from,
  .phone-lock-row-leave-to {
    transform: none;
  }

  .phone-lock-row-move {
    transition: none;
  }
}
</style>
