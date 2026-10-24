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
            <div class="phone-status-bar">
              <div class="status-bar-cell status-bar-left">
                <button class="status-back" type="button" tabindex="-1" disabled>
                  <span class="status-back-icon" aria-hidden="true">
                    <svg width="12" height="12" viewBox="0 0 12 12" fill="currentColor"><path d="M8 2L4 6l4 4" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" fill="none"/></svg>
                  </span>
                  <span class="status-time">{{ timeParts.main }}<span class="status-time-period" v-if="timeParts.period">{{ timeParts.period }}</span></span>
                </button>
              </div>
              <div class="status-bar-cell status-bar-center">
                <div class="dynamic-island">
                  <span class="dynamic-island-label">Notifications</span>
                </div>
              </div>
              <div class="status-bar-cell status-bar-right" v-if="cashDisplay">
                <div class="status-right-pill">
                  <span class="status-cash">{{ cashDisplay }}</span>
                </div>
              </div>
            </div>

            <div class="phone-lock-stack">
              <TransitionGroup name="phone-lock-row">
                <article
                  v-for="item in queue"
                  :key="item.id"
                  ref="cardEls"
                  :data-card-id="item.id"
                  class="phone-lock-card"
                  :class="`phone-lock-card--${item.kind}`"
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
                  <template v-if="item.kind === 'racing'">
                    <div class="phone-lock-card__body phone-lock-card__racing">
                      <template v-if="item.presentationSimple">
                        <span class="phone-lock-card__headline">{{ item.source }}</span>
                      </template>
                      <template v-else>
                        <span class="phone-lock-card__headline">{{ item.title || 'Race Ready' }}</span>
                        <span v-if="item.subline" class="phone-lock-card__sub">{{ item.subline }}</span>
                        <span class="phone-lock-card__app">{{ item.source }}</span>
                      </template>
                    </div>
                  </template>
                  <template v-else-if="item.presentationSimple">
                    <div class="phone-lock-card__body">
                      <span class="phone-lock-card__message phone-lock-card__message--simple">{{ item.source }}</span>
                    </div>
                  </template>
                  <template v-else>
                    <div class="phone-lock-card__body">
                      <span class="phone-lock-card__source">{{ item.source }}</span>
                      <span v-if="item.message" class="phone-lock-card__message">{{ item.message }}</span>
                      <span v-if="item.meta" class="phone-lock-card__meta">{{ item.meta }}</span>
                    </div>
                  </template>
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
import { resolveNotificationRoute, installAppFromNotification } from "../utils/phoneNotificationRoutes"
import { openPhoneRoute } from "../utils/phoneNavigation"
import { useHorizontalSwipeDismiss } from "../composables/useHorizontalSwipeDismiss"

const DEFAULT_TTL_SECONDS = 8
const MAX_QUEUE_SIZE = 5
const MAX_PENDING_SIZE = 20
const PHONE_TIME_KEY = "phone_last_time"
const PHONE_MONEY_KEY = "phone_last_money"
const PHONE_IS_CAREER_KEY = "phone_is_career"
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
const timeString = ref(sessionStorage.getItem(PHONE_TIME_KEY) || "9:10")
const cachedMoney = sessionStorage.getItem(PHONE_MONEY_KEY)
const careerMoney = ref(cachedMoney !== null && cachedMoney !== "" ? Number(cachedMoney) : null)
const isCareer = ref(sessionStorage.getItem(PHONE_IS_CAREER_KEY) === "true")
const rlsLoadingVisible = ref(false)
const proxyTeamLoadingVisible = ref(false)
const pendingNotifications = []
let nextId = 1
let phoneOpenCheckId = null
let careerStatusInterval = null
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
  batch.forEach(deliverNotification)
}

const formatCash = m => {
  if (m == null || typeof m !== "number") return "$0"
  if (m >= 1e12) return `$${(m / 1e12).toFixed(1)}T`
  if (m >= 1e9) return `$${(m / 1e9).toFixed(1)}B`
  if (m >= 1e6) return `$${(m / 1e6).toFixed(1)}M`
  if (m >= 1000) return `$${Math.round(m).toLocaleString()}`
  return `$${Math.round(m)}`
}

const cashDisplay = computed(() => {
  if (!isCareer.value || careerMoney.value == null) return null
  return formatCash(careerMoney.value)
})

const timeParts = computed(() => {
  const s = timeString.value || ""
  const m = s.match(/^(.+?)\s+(AM|PM)$/i)
  if (m) return { main: m[1], period: ` ${m[2]}` }
  return { main: s, period: "" }
})

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
})

const handleNotificationClick = async item => {
  if (!item) return
  dismissById(item.id)
  if (isPhoneOpen()) {
    dismissCurrentHeadsUp()
  }
  await installAppFromNotification(lua, item)
  const targetRoute = resolveNotificationRoute(item)
  if (!targetRoute) return
  openPhoneRoute(router, targetRoute)
}

const scheduleTimeout = item => {
  item.timeoutId = window.setTimeout(() => dismissById(item.id), Math.max(1800, item.ttl * 1000))
}

const deliverNotification = raw => {
  if (isDoNotDisturbActive(phoneSettings)) return

  const normalized = normalizePhoneNotificationPayload(raw)
  if (!normalized) return

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
        scheduleTimeout(item)
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
    scheduleTimeout(item)
    playSound(item)
    return
  }

  if (phoneSettings.bannerNotificationsEnabled === false) return
  const payload = applyBannerNotificationPrefs(normalized, phoneSettings)
  const result = pushHeadsUpNotification(payload)
  if (!result || result.playSound !== false) playSound(payload)
}

const pushNotification = raw => {
  if (isUiLoading.value) {
    pendingNotifications.push(raw)
    if (pendingNotifications.length > MAX_PENDING_SIZE) pendingNotifications.splice(0, pendingNotifications.length - MAX_PENDING_SIZE)
    return
  }
  deliverNotification(raw)
}

const clearAll = () => {
  queue.value.forEach(item => item.timeoutId && window.clearTimeout(item.timeoutId))
  queue.value = []
}

const updateTime = data => {
  if (!data) return
  timeString.value = String(data)
  sessionStorage.setItem(PHONE_TIME_KEY, String(data))
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

const refreshCareerStatus = () => {
  if (!lua.overhaul_career_career?.isActive) return
  lua.overhaul_career_career.isActive().then(active => {
    isCareer.value = !!active
    sessionStorage.setItem(PHONE_IS_CAREER_KEY, String(active))
    if (!active || !lua.overhaul_career_ui_uiUtils?.getCareerStatusData) return
    return lua.overhaul_career_ui_uiUtils.getCareerStatusData()
  }).then(data => {
    const money = data != null ? data?.money ?? null : null
    careerMoney.value = money
    sessionStorage.setItem(PHONE_MONEY_KEY, money != null ? String(money) : "")
  }).catch(() => {
    careerMoney.value = null
    sessionStorage.setItem(PHONE_MONEY_KEY, "")
  })
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
  if (len > 0 && !careerStatusInterval) {
    refreshCareerStatus()
    careerStatusInterval = window.setInterval(refreshCareerStatus, 5000)
  } else if (len === 0 && careerStatusInterval) {
    window.clearInterval(careerStatusInterval)
    careerStatusInterval = null
  }
})

onMounted(async () => {
  updateViewportWidth()
  window.addEventListener("resize", updateViewportWidth)

  events.on("OverhaulNotificationOpen", openNewest)
  events.on("OverhaulNotificationDismiss", dismissNewest)
  events.on("PhoneLockNotification", pushNotification)
  events.on("phone_time_update", updateTime)
  events.on("phoneLayoutData", handlePhoneLayoutData)
  // vueEventBus and bridge.events are the same emitter.
  bridge.events.on("rlsCareerLoadingOverlay", onRlsCareerLoading)
  bridge.events.on("racingTeamProxyTeamLoading", onProxyTeamLoading)

  await safeLua(() => lua.extensions?.load?.("overhaul_phone_apps_time"), "PhoneLockNotificationOverlay: optional call")
  await safeLua(() => lua.extensions?.load?.("overhaul_phone_apps_layout"), "PhoneLockNotificationOverlay: optional call")
  lua.overhaul_phone_apps_time?.requestTime?.()
  lua.overhaul_phone_apps_layout?.requestLayout?.()
  refreshCareerStatus()

  dndCheckInterval = window.setInterval(expireDndIfNeeded, 15000)
})

onBeforeUnmount(() => {
  clearAll()
  pendingNotifications.length = 0
  if (phoneOpenCheckId) {
    window.clearInterval(phoneOpenCheckId)
    phoneOpenCheckId = null
  }
  if (careerStatusInterval) {
    window.clearInterval(careerStatusInterval)
    careerStatusInterval = null
  }
  if (dndCheckInterval) {
    window.clearInterval(dndCheckInterval)
    dndCheckInterval = null
  }
  window.removeEventListener("resize", updateViewportWidth)
  events.off("OverhaulNotificationOpen", openNewest)
  events.off("OverhaulNotificationDismiss", dismissNewest)
  events.off("PhoneLockNotification", pushNotification)
  events.off("phone_time_update", updateTime)
  events.off("phoneLayoutData", handlePhoneLayoutData)
  bridge.events.off("rlsCareerLoadingOverlay", onRlsCareerLoading)
  bridge.events.off("racingTeamProxyTeamLoading", onProxyTeamLoading)
})
</script>

<style scoped lang="scss">
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

.phone-status-bar {
  position: relative;
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0.5em 1em 0.6em;
  min-height: 36px;
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
  cursor: default;
  pointer-events: none;
  font-size: 14px;
  font-weight: 500;
  color: #fff;
}

.phone-lock-stack {
  display: flex;
  flex-direction: column;
  gap: 8px;
  width: 100%;
  max-width: 100%;
  min-width: 0;
  box-sizing: border-box;
  // Match status bar horizontal inset so cards align with header pills.
  padding: 14px 1em 0;
  overflow: hidden;
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
  pointer-events: auto;
  display: flex;
  align-items: stretch;
  gap: 10px;
  width: 100%;
  max-width: 100%;
  min-width: 0;
  box-sizing: border-box;
  padding: 10px 12px;
  border-radius: 14px;
  background: rgba(15, 17, 22, 0.82);
  border: 1px solid rgba(255, 255, 255, 0.12);
  color: #f7f1e8;
  box-shadow: 0 6px 16px rgba(0, 0, 0, 0.35);
  font-size: 0.78em;
  line-height: 1.25;
  cursor: pointer;
  text-align: left;

  &.focus-visible {
    outline: 2px solid rgba(125, 211, 252, 0.55);
    outline-offset: 1px;
  }
}

.phone-lock-card__body {
  @include phone-notif.phone-notif-body;
}

.phone-lock-card__source {
  @include phone-notif.phone-notif-source-line;
  font-weight: 800;
  letter-spacing: 0.04em;
  text-transform: uppercase;
  color: #ffc978;
  font-size: 0.72em;
}

.phone-lock-card__message {
  @include phone-notif.phone-notif-clamped-text(3);
  color: rgba(247, 241, 232, 0.94);
  font-weight: 600;
}

.phone-lock-card__message--simple {
  font-size: 1em;
  font-weight: 700;
  letter-spacing: 0.01em;
  -webkit-line-clamp: 2;
}

.phone-lock-card__meta {
  @include phone-notif.phone-notif-clamped-text(2);
  font-weight: 600;
  font-size: 0.85em;
  line-height: 1.25;
  color: rgba(247, 241, 232, 0.6);
}

.phone-lock-card--success .phone-lock-card__source,
.phone-lock-card--rep .phone-lock-card__source {
  color: #69d48f;
}

.phone-lock-card--warning .phone-lock-card__source,
.phone-lock-card--invite .phone-lock-card__source {
  color: #ffc978;
}

.phone-lock-card--dakar .phone-lock-card__source {
  color: #e0703a;
}

.phone-lock-card--error .phone-lock-card__source {
  color: #ff8a8a;
}

.phone-lock-card--racing {
  align-items: stretch;
}

.phone-lock-card__racing {
  gap: 2px;
}

.phone-lock-card__headline {
  @include phone-notif.phone-notif-clamped-text(2);
  font-weight: 800;
  font-size: 0.95em;
  letter-spacing: 0.03em;
  color: #ffc978;
}

.phone-lock-card__sub {
  @include phone-notif.phone-notif-clamped-text(2);
  font-size: 0.88em;
  font-weight: 600;
  color: rgba(247, 241, 232, 0.94);
}

.phone-lock-card__app {
  @include phone-notif.phone-notif-source-line;
  font-size: 0.68em;
  font-weight: 700;
  letter-spacing: 0.05em;
  text-transform: uppercase;
  color: rgba(247, 241, 232, 0.5);
}
</style>
