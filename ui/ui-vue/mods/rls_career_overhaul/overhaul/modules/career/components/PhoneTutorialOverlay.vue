<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <Teleport to="body">
    <Transition name="phone-tutorial-fade">
      <div
        v-if="shouldShowOverlay"
        class="phone-tutorial-root"
        aria-live="polite"
      >
        <component
          :is="cardInteractive ? PhoneLayer : 'div'" label="Phone tutorial" :active="cardInteractive" @close="onDone"
          v-if="activeStep"
          class="tutorial-card tutorial-card--outside"
          :class="{ 'tutorial-card--interactive': cardInteractive }"
          :style="outsideCardStyle"
        >
          <h3 class="tutorial-card__title">{{ activeStep.title }}</h3>
          <p class="tutorial-card__body">{{ activeStep.body }}</p>
          <p v-if="activeStep.cta" class="tutorial-card__cta">
            <strong>{{ activeStep.cta }}</strong>
          </p>
          <p
            v-if="activeStep.showBinding"
            class="tutorial-card__body tutorial-card__body--muted"
          >
            Reopen the phone anytime with <strong>{{ phoneBindingLabel }}</strong>.
          </p>
          <button
            v-if="activeStep.advance === 'next'"
            type="button"
            class="tutorial-card__button" bng-scoped-nav-autofocus
            @click="onNext"
          >
            Next
          </button>
          <button
            v-if="activeStep.advance === 'done'"
            type="button"
            class="tutorial-card__button" bng-scoped-nav-autofocus
            @click="onDone"
          >
            Done
          </button>
        </component>

        <div
          v-if="frameRect && showTargetHighlight"
          class="phone-tutorial-frame"
          :style="frameStyle"
        >
          <template v-if="targetRect">
            <div class="tutorial-panel tutorial-panel--top" :style="panelTopStyle" />
            <div class="tutorial-panel tutorial-panel--left" :style="panelLeftStyle" />
            <div class="tutorial-panel tutorial-panel--right" :style="panelRightStyle" />
            <div class="tutorial-panel tutorial-panel--bottom" :style="panelBottomStyle" />
            <div class="tutorial-highlight-glow" :style="ringStyle" />
            <div class="tutorial-highlight-ring" :style="ringStyle" />
            <div v-if="activeStep?.label" class="tutorial-highlight-label" :style="highlightLabelStyle">
              {{ activeStep.label }}
            </div>
          </template>
        </div>
      </div>
    </Transition>
  </Teleport>
</template>

<script setup>
import PhoneLayer from './phone/PhoneLayer.vue'
import { isPhoneRoute } from "../utils/phoneRoutes.js"
import { isPhoneShellVisible } from "../utils/phoneShellState"
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { useEvents } from '@/services/events'
import { lua } from '@/bridge'
import { usePhoneTutorial, PHONE_TUTORIAL_STEPS } from '../composables/usePhoneTutorial'
import { navigatePhoneRoute } from '../utils/phoneNavigation'

const PHONE_SHELL_SELECTOR = '.phone-shell'
const HOLE_PADDING = 8
const RING_SIZE_BOOST = 14
const CARD_OUTSIDE_GAP = 20
const POLL_INTERVAL_MS = 100
const POLL_MAX_MS = 12000
const FALLBACK_CARD_STYLE = {
  top: '72px',
  left: '24px',
  transform: 'none',
  maxWidth: 'min(300px, calc(100vw - 48px))',
}

const route = useRoute()
const router = useRouter()
const events = useEvents()
const {
  stepIndex,
  isActive,
  phoneBindingLabel,
  dockReadyTick,
  phoneVisibleTick,
  tutorialTargetSelector,
  startTutorial,
  advanceNext,
  tryAdvanceOnGuideRoute,
  tryAdvanceOnEmploymentRoute,
  tryAdvanceOnVehicleTransferRoute,
  finishTutorial,
  resetTutorialState,
  shouldShowTutorialOverlay,
} = usePhoneTutorial()

const activeStep = computed(() => {
  if (stepIndex.value === null) return null
  return PHONE_TUTORIAL_STEPS[stepIndex.value] ?? null
})

function isPhoneVisibleInSession() {
  return isPhoneRoute(route) || isPhoneShellVisible()
}

const shouldShowOverlay = computed(() => {
  // Read reactive tutorial state first so step changes always re-evaluate this gate.
  if (!isActive.value) return false
  void phoneVisibleTick.value
  void dockReadyTick.value
  if (!route.path.startsWith('/overhaul')) return false
  if (!isPhoneVisibleInSession()) return false
  return shouldShowTutorialOverlay(route.name)
})

const cardInteractive = computed(() => {
  const advance = activeStep.value?.advance
  return advance === 'next' || advance === 'done'
})

const showTargetHighlight = computed(() => {
  const step = activeStep.value
  return !!(step?.target && (step.appId || step.targetId))
})

const frameRect = ref(null)
const wrapperRect = ref(null)
const targetRect = ref(null)
let measureRaf = 0
let pollIntervalId = null
let pollStartedAt = 0
let resizeObserver = null
let observedPhoneShell = null

const frameStyle = computed(() => {
  if (!frameRect.value) return {}
  const { left, top, width, height } = frameRect.value
  return {
    left: `${left}px`,
    top: `${top}px`,
    width: `${width}px`,
    height: `${height}px`,
  }
})

function buildOutsideCardStyle(wrapper, frame) {
  const anchor = frame && frame.width > 0 && frame.height > 0 ? frame : wrapper
  if (!anchor || anchor.width < 1 || anchor.height < 1) {
    return { ...FALLBACK_CARD_STYLE }
  }

  const spaceLeft = anchor.left - CARD_OUTSIDE_GAP - 16
  if (spaceLeft < 180) {
    return { ...FALLBACK_CARD_STYLE }
  }

  const maxWidth = Math.min(320, Math.max(200, spaceLeft))
  const topAligned = anchor.top + Math.max(52, anchor.height * 0.14)
  const viewportH = typeof window !== 'undefined' ? window.innerHeight : topAligned
  const cardReserve = 280
  const top = Math.min(Math.max(topAligned, 24), Math.max(24, viewportH - cardReserve))

  return {
    top: `${top}px`,
    left: `${anchor.left - CARD_OUTSIDE_GAP}px`,
    transform: 'translateX(-100%)',
    maxWidth: `${maxWidth}px`,
    width: `${maxWidth}px`,
  }
}

const outsideCardStyle = computed(() => buildOutsideCardStyle(wrapperRect.value, frameRect.value))

const holeRect = computed(() => {
  if (!targetRect.value || !frameRect.value) return null
  const pad = HOLE_PADDING
  const left = targetRect.value.left - frameRect.value.left - pad
  const top = targetRect.value.top - frameRect.value.top - pad
  const width = targetRect.value.width + pad * 2
  const height = targetRect.value.height + pad * 2
  return { left, top, width, height }
})

const panelTopStyle = computed(() => {
  const hole = holeRect.value
  const fw = frameRect.value?.width ?? 0
  if (!hole) return {}
  return {
    left: '0',
    top: '0',
    width: `${fw}px`,
    height: `${Math.max(0, hole.top)}px`,
  }
})

const panelLeftStyle = computed(() => {
  const hole = holeRect.value
  if (!hole) return {}
  return {
    left: '0',
    top: `${hole.top}px`,
    width: `${Math.max(0, hole.left)}px`,
    height: `${hole.height}px`,
  }
})

const panelRightStyle = computed(() => {
  const hole = holeRect.value
  const fw = frameRect.value?.width ?? 0
  if (!hole) return {}
  const right = hole.left + hole.width
  return {
    left: `${right}px`,
    top: `${hole.top}px`,
    width: `${Math.max(0, fw - right)}px`,
    height: `${hole.height}px`,
  }
})

const panelBottomStyle = computed(() => {
  const hole = holeRect.value
  const fw = frameRect.value?.width ?? 0
  const fh = frameRect.value?.height ?? 0
  if (!hole) return {}
  const bottom = hole.top + hole.height
  return {
    left: '0',
    top: `${bottom}px`,
    width: `${fw}px`,
    height: `${Math.max(0, fh - bottom)}px`,
  }
})

const ringStyle = computed(() => {
  const hole = holeRect.value
  if (!hole) return {}
  const boost = RING_SIZE_BOOST
  return {
    left: `${hole.left - boost / 2}px`,
    top: `${hole.top - boost / 2}px`,
    width: `${hole.width + boost}px`,
    height: `${hole.height + boost}px`,
  }
})

const highlightLabelStyle = computed(() => {
  const hole = holeRect.value
  if (!hole) return {}
  return {
    left: `${hole.left + hole.width / 2}px`,
    top: `${hole.top + hole.height + 6}px`,
    transform: 'translateX(-50%)',
  }
})

function normalizePayload(raw) {
  if (!raw || typeof raw !== 'object') return {}
  if (Array.isArray(raw) && raw.length > 0 && raw[0] && typeof raw[0] === 'object' && !Array.isArray(raw[0])) {
    return raw[0]
  }
  return raw
}

function findVisiblePhoneElements() {
  const wrappers = document.querySelectorAll(PHONE_SHELL_SELECTOR)
  for (const wrapperEl of wrappers) {
    const wrapperBox = wrapperEl.getBoundingClientRect()
    if (wrapperBox.width < 1 || wrapperBox.height < 1) continue

    const frameEl = wrapperEl.querySelector('.phone-screen')
    if (!frameEl) continue

    const frameBox = frameEl.getBoundingClientRect()
    if (frameBox.width < 1 || frameBox.height < 1) continue

    return { wrapperEl, frameEl }
  }

  return { wrapperEl: null, frameEl: null }
}

function attachPhoneObserver() {
  const { wrapperEl } = findVisiblePhoneElements()
  if (!wrapperEl) return
  if (wrapperEl === observedPhoneShell && resizeObserver) return

  detachPhoneObserver()
  observedPhoneShell = wrapperEl
  if (typeof ResizeObserver !== 'undefined') {
    resizeObserver = new ResizeObserver(scheduleMeasure)
    resizeObserver.observe(wrapperEl)
  }
}

function detachPhoneObserver() {
  if (resizeObserver) {
    resizeObserver.disconnect()
    resizeObserver = null
  }
  observedPhoneShell = null
}

function measureRects() {
  const { wrapperEl, frameEl } = findVisiblePhoneElements()

  if (!frameEl) {
    frameRect.value = null
    wrapperRect.value = wrapperEl ? wrapperEl.getBoundingClientRect() : null
    targetRect.value = null
    return false
  }

  frameRect.value = frameEl.getBoundingClientRect()
  wrapperRect.value = wrapperEl ? wrapperEl.getBoundingClientRect() : frameRect.value
  attachPhoneObserver()

  const selector = tutorialTargetSelector.value
  if (selector) {
    const targetEl = document.querySelector(selector)
    targetRect.value = targetEl ? targetEl.getBoundingClientRect() : null
    return !!targetEl
  }

  targetRect.value = null
  return true
}

function scheduleMeasure() {
  if (measureRaf) cancelAnimationFrame(measureRaf)
  measureRaf = requestAnimationFrame(() => {
    measureRaf = 0
    measureRects()
  })
}

function stopMeasurePolling() {
  if (pollIntervalId) {
    clearInterval(pollIntervalId)
    pollIntervalId = null
  }
  pollStartedAt = 0
}

function startMeasurePolling() {
  stopMeasurePolling()
  pollStartedAt = Date.now()
  scheduleMeasure()

  pollIntervalId = setInterval(() => {
    scheduleMeasure()
    const elapsed = Date.now() - pollStartedAt
    const hasFrame = !!frameRect.value
    const needsTarget = !!tutorialTargetSelector.value
    const hasTarget = !!targetRect.value
    const done = elapsed >= POLL_MAX_MS || (hasFrame && (!needsTarget || hasTarget))
    if (done) stopMeasurePolling()
  }, POLL_INTERVAL_MS)
}

async function onPhoneTutorialStart(...args) {
  // Overlay mounts on the main menu too; ignore Lua hooks until career play is live.
  try {
    const active = await lua.overhaul_career_career?.isActive?.()
    if (!active) return
  } catch (_) {
    return
  }
  if (!route.path.startsWith('/overhaul')) return

  const payload = normalizePayload(args.length > 0 ? args[0] : null)
  startTutorial(payload)
  nextTick(() => {
    startMeasurePolling()
    syncOverlayContext()
    requestAnimationFrame(() => {
      if (isActive.value && isPhoneVisibleInSession()) {
        startMeasurePolling()
      }
    })
  })
}

function onNext() {
  const leavingRoute = activeStep.value?.route
  advanceNext()
  if (leavingRoute && leavingRoute !== 'phone-main') {
    navigatePhoneRoute(router, 'phone-main')
  }
  scheduleMeasure()
  if (shouldShowOverlay.value) {
    startMeasurePolling()
  }
}

function onDone() {
  finishTutorial()
}

function syncOverlayContext() {
  if (!shouldShowOverlay.value && isActive.value) {
    if (!route.path.startsWith('/overhaul')) {
      resetTutorialState()
    }
  }
}

watch(shouldShowOverlay, visible => {
  if (visible) {
    startMeasurePolling()
  } else {
    stopMeasurePolling()
    detachPhoneObserver()
    frameRect.value = null
    wrapperRect.value = null
    targetRect.value = null
  }
})

watch(
  () => route.name,
  name => {
    syncOverlayContext()

    if (name === 'phone-guide') {
      tryAdvanceOnGuideRoute()
      scheduleMeasure()
    }

    if (name === 'phone-employment') {
      tryAdvanceOnEmploymentRoute()
      scheduleMeasure()
    }

    if (name === 'phone-vehicle-transfer') {
      tryAdvanceOnVehicleTransferRoute()
      scheduleMeasure()
    }

    if (shouldShowOverlay.value) {
      startMeasurePolling()
    }
  }
)

watch(() => route.path, () => {
  syncOverlayContext()
})

watch(dockReadyTick, () => {
  if (shouldShowOverlay.value) scheduleMeasure()
})

watch(tutorialTargetSelector, () => {
  scheduleMeasure()
  if (shouldShowOverlay.value) {
    startMeasurePolling()
  }
})

watch(stepIndex, () => {
  scheduleMeasure()
  if (shouldShowOverlay.value) {
    startMeasurePolling()
  }
})

watch(phoneVisibleTick, () => {
  if (isActive.value && shouldShowOverlay.value) {
    startMeasurePolling()
  }
})

watch(activeStep, () => {
  scheduleMeasure()
  if (shouldShowOverlay.value) {
    startMeasurePolling()
  }
})

onMounted(() => {
  syncOverlayContext()
  events.on('PhoneTutorialStart', onPhoneTutorialStart)
  window.addEventListener('resize', scheduleMeasure)
})

onBeforeUnmount(() => {
  events.off('PhoneTutorialStart', onPhoneTutorialStart)
  window.removeEventListener('resize', scheduleMeasure)
  stopMeasurePolling()
  detachPhoneObserver()
  if (measureRaf) cancelAnimationFrame(measureRaf)
})
</script>

<style scoped lang="scss">
.phone-tutorial-root {
  position: fixed;
  inset: 0;
  z-index: 11000;
  pointer-events: none;
}

.phone-tutorial-frame {
  position: fixed;
  pointer-events: none;
  overflow: hidden;
  border-radius: 1.75em;
}

.tutorial-panel {
  position: absolute;
  background: rgba(0, 0, 0, 0.72);
  pointer-events: auto;
  z-index: 1;
}

.tutorial-panel--full {
  inset: 0;
}

.tutorial-highlight-glow {
  position: absolute;
  border-radius: 1.2em;
  background: rgba(255, 159, 67, 0.18);
  box-shadow: 0 0 28px rgba(255, 140, 0, 0.45);
  pointer-events: none;
  z-index: 2;
  animation: tutorial-glow 1.6s ease-in-out infinite;
}

.tutorial-highlight-ring {
  position: absolute;
  border-radius: 1.2em;
  border: 3px solid rgba(255, 176, 72, 0.98);
  box-shadow:
    inset 0 0 0 1px rgba(255, 220, 140, 0.35),
    0 0 0 2px rgba(255, 140, 0, 0.4),
    0 0 22px rgba(255, 140, 0, 0.55);
  pointer-events: none;
  z-index: 3;
  animation: tutorial-pulse 1.6s ease-in-out infinite;
}

.tutorial-highlight-label {
  position: absolute;
  padding: 0.15rem 0.45rem;
  border-radius: 6px;
  background: rgba(255, 140, 0, 0.92);
  color: #111;
  font-size: 0.68rem;
  font-weight: 800;
  letter-spacing: 0.02em;
  text-transform: uppercase;
  white-space: nowrap;
  pointer-events: none;
  z-index: 4;
  animation: tutorial-label-bounce 1.6s ease-in-out infinite;
}

@keyframes tutorial-glow {
  0%,
  100% {
    opacity: 0.65;
    transform: scale(1);
  }
  50% {
    opacity: 1;
    transform: scale(1.04);
  }
}

@keyframes tutorial-pulse {
  0%,
  100% {
    box-shadow:
      inset 0 0 0 1px rgba(255, 220, 140, 0.35),
      0 0 0 2px rgba(255, 140, 0, 0.35),
      0 0 16px rgba(255, 140, 0, 0.4);
  }
  50% {
    box-shadow:
      inset 0 0 0 1px rgba(255, 220, 140, 0.5),
      0 0 0 5px rgba(255, 140, 0, 0.55),
      0 0 28px rgba(255, 140, 0, 0.65);
  }
}

@keyframes tutorial-label-bounce {
  0%,
  100% {
    transform: translateX(-50%) translateY(0);
  }
  50% {
    transform: translateX(-50%) translateY(-2px);
  }
}

.tutorial-card {
  background: rgba(16, 16, 16, 0.96);
  border: 1px solid rgba(255, 255, 255, 0.12);
  border-radius: 14px;
  padding: 1rem 1.15rem;
  box-shadow: 0 8px 28px rgba(0, 0, 0, 0.45);
  text-align: left;
  pointer-events: none;
}

.tutorial-card--outside {
  position: fixed;
  z-index: 11001;
  pointer-events: none;

  &::after {
    content: '';
    position: absolute;
    right: -9px;
    top: 1.25rem;
    width: 0;
    height: 0;
    border-top: 9px solid transparent;
    border-bottom: 9px solid transparent;
    border-left: 9px solid rgba(255, 255, 255, 0.14);
    filter: drop-shadow(1px 0 0 rgba(16, 16, 16, 0.96));
  }
}

.tutorial-card--interactive {
  pointer-events: auto;
}

.tutorial-card__title {
  margin: 0 0 0.5rem;
  font-size: 1rem;
  font-weight: 700;
  color: #fff;
}

.tutorial-card__body {
  margin: 0 0 0.55rem;
  font-size: 0.82rem;
  line-height: 1.45;
  color: rgba(255, 255, 255, 0.88);
}

.tutorial-card__body--muted {
  color: rgba(255, 255, 255, 0.65);
  font-size: 0.78rem;
}

.tutorial-card__cta {
  margin: 0.35rem 0 0;
  font-size: 0.84rem;
  color: rgba(255, 200, 120, 0.95);
}

.tutorial-card__button {
  margin-top: 0.85rem;
  width: 100%;
  padding: 0.55rem 1rem;
  border: none;
  border-radius: 10px;
  background: linear-gradient(135deg, #ff8c00, #ff9f43);
  color: #111;
  font-size: 0.9rem;
  font-weight: 700;
  cursor: pointer;

  &:hover {
    filter: brightness(1.06);
  }
}

.phone-tutorial-fade-enter-active,
.phone-tutorial-fade-leave-active {
  transition: opacity 0.25s ease;
}

.phone-tutorial-fade-enter-from,
.phone-tutorial-fade-leave-to {
  opacity: 0;
}
</style>
