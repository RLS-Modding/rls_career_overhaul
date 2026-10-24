<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <div class="rls-house rls-mp-host" :class="{ 'rls-mp-mini': compact }" :bng-no-child-nav="compact && !active ? 'true' : null">
    <div v-if="compact" class="rls-mp-mini-row">
      <img v-if="state.currentCover" class="rls-mp-mini-art" :src="state.currentCover" alt="" @error="coverFailed" />
      <span v-else class="rls-mp-mini-art rls-mp-ico-volume" aria-hidden="true"></span>
      <div class="rls-mp-mini-track" :title="state.currentTitle">
        <span class="rls-mp-mini-genre">{{ state.activePlaylist || 'Music' }}</span>
        <span class="rls-mp-mini-title">{{ state.currentTitle || 'No track selected' }}</span>
      </div>
      <button v-for="control in miniControls" :key="control.command" type="button" class="rls-mp-icon"
        :class="control.icon" :aria-label="control.label" :tabindex="active ? 0 : -1"
        :bng-no-nav="!active ? 'true' : null" bng-nav-item v-bng-ui-nav-focus
        v-bng-on-ui-nav:ok.asMouse.focusRequired @click="emit('command', control.command)"></button>
    </div>
    <div v-else class="rls-mp">
      <div class="rls-mp-row-main">
        <div class="rls-mp-art"
          ><img v-if="state.currentCover" :src="state.currentCover" alt="" @error="coverFailed" /><div v-else class="rls-mp-art-ph"></div
        ></div>
        <div class="rls-mp-main-col">
          <div class="rls-mp-title-row">
            <div class="rls-mp-title">{{ state.currentTitle || '—' }}</div>
            <div v-if="state.playlistNames?.length" class="rls-mp-title-pl">
              <HouseMenu
                compact teleport
                :active="active"
                :model-value="state.activePlaylist"
                :items="playlistItems"
                aria-label="Music genre"
                @change="pickPlaylist"
              />
            </div>
          </div>
          <div class="rls-mp-time-row"
            ><span class="rls-mp-time">{{ time(state.positionSec) }}</span
            ><div class="rls-mp-bar"
              ><div class="rls-mp-bar-fill" :style="{ transform: `scaleX(${progress})` }"></div></div
            ><span class="rls-mp-time">{{ time(state.durationSec) }}</span></div
          >
          <div class="rls-mp-row-ctrl">
            <span class="rls-mp-ctrl-spacer" aria-hidden="true"></span>
            <div class="rls-mp-ctrl-center">
              <button
                type="button"
                bng-nav-item
                v-bng-ui-nav-focus
                v-bng-on-ui-nav:ok.asMouse.focusRequired
                class="rls-mp-icon rls-mp-icon-sm rls-mp-ico-shuffle"
                :class="{ active: state.shuffle }"
                aria-label="Shuffle"
                :aria-pressed="!!state.shuffle"
                @click="emit('command', 'uiToggleShuffle')"
              ></button>
              <button
                type="button"
                bng-nav-item
                v-bng-ui-nav-focus
                v-bng-on-ui-nav:ok.asMouse.focusRequired
                class="rls-mp-icon rls-mp-ico-prev"
                aria-label="Previous track"
                @click="emit('command', 'uiPrevious')"
              ></button>
              <button
                type="button"
                bng-nav-item
                v-bng-ui-nav-focus
                v-bng-on-ui-nav:ok.asMouse.focusRequired
                class="rls-mp-icon rls-mp-icon-play"
                :class="state.isPlaying ? 'rls-mp-ico-pause' : 'rls-mp-ico-play'"
                :aria-label="state.isPlaying ? 'Stop' : 'Play'"
                @click="togglePlayback"
              ></button>
              <button
                type="button"
                bng-nav-item
                v-bng-ui-nav-focus
                v-bng-on-ui-nav:ok.asMouse.focusRequired
                class="rls-mp-icon rls-mp-ico-next"
                aria-label="Next track"
                @click="emit('command', 'uiNext')"
              ></button>
              <button
                type="button"
                bng-nav-item
                v-bng-ui-nav-focus
                v-bng-on-ui-nav:ok.asMouse.focusRequired
                class="rls-mp-icon rls-mp-icon-sm rls-mp-ico-repeat"
                :class="{
                  active: state.repeatMode && state.repeatMode !== 'off',
                  'rls-mp-ico-repeat-one': state.repeatMode === 'one'
                }"
                aria-label="Repeat"
                @click="emit('command', 'uiToggleRepeat')"
              ></button>
            </div>
            <div class="rls-mp-ctrl-vol"
              ><button
                ref="volumeButton"
                type="button"
                bng-nav-item
                v-bng-ui-nav-focus
                v-bng-on-ui-nav:ok.asMouse.focusRequired
                class="rls-mp-icon rls-mp-ico-volume"
                aria-label="Volume"
                :aria-expanded="volumeOpen"
                @mouseenter="openVolume()"
                @click="activateVolume"
                @focusout="volumeFocusOut"
              ></button
            ></div>
          </div>
        </div>
      </div>
    </div>
    <Teleport to="body">
      <div
        v-if="volumeOpen"
        ref="volumeFlyout"
        class="rls-house rls-mp-volume-flyout"
        :style="volumeStyle"
        v-bng-scoped-nav="volumeScope"
        v-bng-on-ui-nav:ok,back,menu="confirmVolume"
        @focusout="volumeFocusOut"
      >
        <div class="rls-mp-volume-flyout-panel">
          <div class="rls-mp-volume-flyout-slider-region">
            <div class="rls-mp-volume-slider-wrap">
              <div
                ref="volumeSlider"
                class="rls-mp-vslider"
                role="slider"
                tabindex="0"
                bng-nav-item
                bng-scoped-nav-autofocus
                v-bng-ui-nav-focus
                v-bng-on-ui-nav-focus:vertical.repeat="volumeNav"
                aria-label="Volume"
                aria-orientation="vertical"
                aria-valuemin="0"
                aria-valuemax="100"
                :aria-valuenow="volumePercent"
                :aria-valuetext="`${volumePercent}%`"
                @keydown="volumeKeyDown"
                @pointerdown.prevent="volumePointerDown"
                @pointermove="volumePointerMove"
                @pointerup="volumePointerEnd"
                @pointercancel="volumePointerEnd"
                @lostpointercapture="volumePointerEnd"
              >
                <div ref="volumeTrack" class="rls-mp-vslider-track">
                  <div class="rls-mp-vslider-fill" :style="{ height: `${volumePercent}%` }"></div>
                  <div class="rls-mp-vslider-thumb" :style="{ bottom: `calc(${volumePercent}% - 0.43rem)` }"></div>
                </div>
              </div>
            </div>
          </div>
          <div class="rls-mp-volume-flyout-icon-well" aria-hidden="true"></div>
        </div>
      </div>
    </Teleport>
  </div>
</template>

<script setup>
import { computed, nextTick, onBeforeUnmount, ref, watch } from 'vue'
import HouseMenu from './house/HouseMenu.vue'
import { returnFocusToOpener } from '../composables/useScreenEntryFocus'
import { vBngUiNavFocus, vBngOnUiNav, vBngOnUiNavFocus, vBngScopedNav } from '@/common/directives'
const props = defineProps({ state: { type: Object, required: true }, active: { type: Boolean, default: true }, compact: Boolean })
const emit = defineEmits(['command'])
const miniControls = computed(() => [
  { command: 'uiPrevious', label: 'Previous track', icon: 'rls-mp-ico-prev' },
  { command: 'togglePlayback', label: props.state.isPlaying ? 'Pause' : 'Play', icon: props.state.isPlaying ? 'rls-mp-icon-play rls-mp-ico-pause' : 'rls-mp-icon-play rls-mp-ico-play' },
  { command: 'uiNext', label: 'Next track', icon: 'rls-mp-ico-next' },
])
const playlistItems = computed(() => (props.state.playlistNames || []).map(name => ({ value: name, label: name })))
const volumeOpen = ref(false)
const clampPercent = value => Math.max(0, Math.min(100, Math.round(Number(value) || 0)))
const volumePercent = ref(100)
watch(() => props.state.musicVolume, value => {
  if (Number.isFinite(value)) volumePercent.value = clampPercent(value * 100)
}, { immediate: true })
const setVolume = value => {
  volumePercent.value = clampPercent(value)
  emit('command', 'uiSetVolume', volumePercent.value / 100)
}
// v2.7.2, 6e2dc8413: the capsule shares the speaker's bottom edge and
// escapes the card's clipping. Keep its neutral track, fill and round thumb.
const volumeButton = ref(null)
const volumeFlyout = ref(null)
const volumeSlider = ref(null)
const volumeTrack = ref(null)
const volumeStyle = ref({ visibility: 'hidden' })
let volumePointer = null
let volumeKeyboard = false
let volumeDisposed = false
let volumeFocusGeneration = 0
const volumeScope = {
  type: 'container', activateOnMount: true, trapPolicy: 'always',
  canDeactivate: () => !volumeOpen.value,
  preventNavigationEscape: ['top', 'bottom', 'left', 'right'],
  canBubbleEvent: event => !['ok', 'back', 'menu'].includes(event?.detail?.name),
}
const volumeNav = {
  min: 0, max: 100, step: 5,
  events: { focus_u: 1, focus_r: 1, focus_d: -1, focus_l: -1 },
  value: () => volumePercent.value,
  callback: (_direction, value) => setVolume(value),
}
const positionVolume = () => {
  if (!volumeButton.value || !volumeFlyout.value) return
  const button = volumeButton.value
  const rect = button.getBoundingClientRect()
  // Ignore the icon's hover scale so the capsule does not jump on entry.
  const size = getComputedStyle(button)
  const width = Math.max(34, Math.ceil(parseFloat(size.width)) + 2)
  const iconHeight = Math.max(28, Math.ceil(parseFloat(size.height)))
  const height = volumeFlyout.value.offsetHeight
  volumeStyle.value = {
    left: `${Math.max(8, Math.min(rect.left + rect.width / 2 - width / 2, window.innerWidth - width - 8))}px`,
    top: `${Math.max(8, Math.min(rect.top + rect.height / 2 + parseFloat(size.height) / 2 - height, window.innerHeight - height - 8))}px`,
    '--volume-width': `${width}px`, '--volume-icon-height': `${iconHeight}px`,
  }
}
const openVolume = async (keyboard = false) => {
  if (props.active === false || volumeDisposed) return
  if (volumeOpen.value && volumeKeyboard && !keyboard) return
  const generation = ++volumeFocusGeneration
  volumeKeyboard = keyboard
  volumeOpen.value = true
  await nextTick()
  if (!volumeOpen.value || generation !== volumeFocusGeneration) return
  positionVolume()
  // Width and icon-well height can change the capsule's measured height.
  await nextTick()
  if (!volumeOpen.value || generation !== volumeFocusGeneration) return
  positionVolume()
  if (keyboard) volumeSlider.value?.focus()
}
const closeVolume = (returnFocus = false) => {
  const generation = ++volumeFocusGeneration
  const wasOpen = volumeOpen.value
  volumePointer = null
  volumeOpen.value = false
  if (!wasOpen) return
  void returnFocusToOpener(() => {
    if (volumeDisposed || props.active === false || generation !== volumeFocusGeneration) return null
    const active = document.activeElement
    return !returnFocus && active !== document.body && !volumeContains(active) ? active : volumeButton.value
  }).then(() => {
    // Keyboard users also return to the speaker when controller focus is off.
    if (returnFocus && !volumeOpen.value && !volumeDisposed && props.active !== false) volumeButton.value?.focus()
  })
}
const activateVolume = event => {
  const keyboard = !!event.fromController || event.detail === 0
  if (volumeOpen.value && keyboard && volumeKeyboard) closeVolume(true)
  else return openVolume(keyboard)
}
const confirmVolume = event => {
  event?.stopPropagation()
  closeVolume(true)
  return false
}
const volumeContains = target => volumeButton.value?.contains(target) || volumeFlyout.value?.contains(target)
const volumeFocusOut = async event => {
  if (volumeContains(event.relatedTarget)) return
  await nextTick()
  if (volumeOpen.value && !volumeContains(document.activeElement)) closeVolume()
}
const volumeOutsideDown = event => {
  if (!volumeContains(event.target)) closeVolume()
}
const volumeHoverMove = event => {
  if (volumeKeyboard || volumePointer !== null) return
  const hit = (element, pad) => {
    if (!element) return false
    const rect = element.getBoundingClientRect()
    return event.clientX >= rect.left - pad && event.clientX <= rect.right + pad &&
      event.clientY >= rect.top - pad && event.clientY <= rect.bottom + pad
  }
  if (!hit(volumeButton.value, 2) && !hit(volumeFlyout.value, 12)) closeVolume()
}
const volumeKeyDown = event => {
  // The engine may already own this key and send it back as UI navigation.
  // Handling that consumed DOM event as well would apply two volume steps.
  if (event.defaultPrevented) return
  const changes = { ArrowUp: 5, ArrowRight: 5, ArrowDown: -5, ArrowLeft: -5 }
  if (!(event.key in changes) && !['Home', 'End'].includes(event.key)) return
  event.preventDefault()
  event.stopPropagation()
  volumeKeyboard = true
  setVolume(event.key === 'Home' ? 0 : event.key === 'End' ? 100 : volumePercent.value + changes[event.key])
}
const volumePointerMove = event => {
  if (event.pointerId !== volumePointer) return
  const rect = volumeTrack.value?.getBoundingClientRect()
  if (rect?.height > 0) setVolume((rect.bottom - event.clientY) / rect.height * 100)
}
const volumePointerDown = event => {
  if (event.button !== 0 || volumePointer !== null) return
  volumeKeyboard = false
  volumePointer = event.pointerId
  event.currentTarget.setPointerCapture(event.pointerId)
  event.currentTarget.focus()
  volumePointerMove(event)
}
const volumePointerEnd = event => {
  if (event.pointerId !== volumePointer) return
  volumePointer = null
  if (event.currentTarget.hasPointerCapture?.(event.pointerId)) event.currentTarget.releasePointerCapture(event.pointerId)
  volumeHoverMove(event)
}
const removeVolumeListeners = () => {
  document.removeEventListener('pointermove', volumeHoverMove, true)
  document.removeEventListener('pointerdown', volumeOutsideDown, true)
  document.removeEventListener('scroll', positionVolume, true)
  window.removeEventListener('resize', positionVolume)
}
watch(volumeOpen, open => {
  removeVolumeListeners()
  if (!open) return
  document.addEventListener('pointermove', volumeHoverMove, true)
  document.addEventListener('pointerdown', volumeOutsideDown, true)
  document.addEventListener('scroll', positionVolume, true)
  window.addEventListener('resize', positionVolume)
})
const releaseVolumeInput = () => {
  ++volumeFocusGeneration
  volumePointer = null
  volumeOpen.value = false
  removeVolumeListeners()
}
watch(() => props.active, active => { if (!active) releaseVolumeInput() })
onBeforeUnmount(() => {
  volumeDisposed = true
  releaseVolumeInput()
})
const progress = computed(() =>
  Math.max(0, Math.min(1, (props.state.positionSec || 0) / (props.state.durationSec || 1)))
)
const time = (value) =>
  `${Math.floor(Math.max(0, value || 0) / 60)}:${String(Math.floor(Math.max(0, value || 0)) % 60).padStart(2, '0')}`
const coverFailed = event => {
  const image = event.target
  if (!image.src.endsWith('/cover-placeholder.svg')) image.src = '/ui/modModules/rlsMusicPlayer/cover-placeholder.svg'
}
const togglePlayback = () => {
  emit('command', 'togglePlayback')
}
const pickPlaylist = (name) => {
  emit('command', 'setActivePlaylist', name)

}
</script>

<style scoped lang="scss">
@use '@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss' as *;
@use '@/styles/rls_career_overhaul/modules/career/styles/overhaulFocus.scss' as *;
.rls-mp-host {
  position: relative;
  display: block;
}

.rls-mp {
  display: block;
  min-width: 16rem;
  max-width: 22rem;
  padding: 0.5rem 0.6rem;
  border-radius: 0.4rem;
  background: rgba(10, 12, 18, 0.92);
  border: 1px solid rgba(255, 255, 255, 0.12);
  color: #f0f2f5;
}

.rls-mp-row-main {
  display: flex;
  flex-direction: row;
  gap: 0.55rem;
  align-items: stretch;
}

.rls-mp-art {
  flex: 0 0 var(--rls-mp-art-size, auto);
  align-self: stretch;
  width: var(--rls-mp-art-size, auto);
  height: var(--rls-mp-art-size, auto);
  aspect-ratio: 1 / 1;
  min-width: 0;
  box-sizing: border-box;
  border-radius: 0.28rem;
  overflow: hidden;
  background: rgba(255, 255, 255, 0.06);
}

.rls-mp-art img {
  width: 100%;
  height: 100%;
  object-fit: cover;
  display: block;
}

.rls-mp-art-ph {
  width: 100%;
  height: 100%;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 1.35rem;
  color: rgba(255, 255, 255, 0.45);
}

.rls-mp-main-col {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: 0.35rem;
  justify-content: flex-start;
}

.rls-mp-title-row {
  display: flex;
  flex-direction: row;
  align-items: center;
  gap: 0.45rem;
  min-width: 0;
}

.rls-mp-title {
  flex: 1;
  min-width: 0;
  font-size: 0.82rem;
  font-weight: 700;
  line-height: 1.2;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.rls-mp-title-pl {
  flex: 0 1 9.5rem;
  min-width: 0;
  max-width: 46%;
  margin-left: auto;
}

.rls-mp-time-row {
  display: flex;
  flex-direction: row;
  align-items: center;
  gap: 0.35rem;
}

.rls-mp-time {
  font-size: 0.68rem;
  font-variant-numeric: tabular-nums;
  color: rgba(255, 255, 255, 0.68);
  flex: 0 0 auto;
}

.rls-mp-bar {
  flex: 1;
  height: 0.28rem;
  border-radius: 0.12rem;
  background: rgba(255, 255, 255, 0.1);
  overflow: hidden;
}

.rls-mp-bar-fill {
  width: 100%;
  height: 100%;
  transform-origin: left;
  border-radius: 0.12rem;
  background: linear-gradient(90deg, rgba(249, 115, 22, 0.9), rgba(251, 191, 36, 0.95));
  transition: transform 0.12s linear;
}






.rls-mp-row-ctrl {
  --rls-mp-ico-glyph: 1.28rem;
  display: flex;
  flex-direction: row;
  align-items: center;
  justify-content: space-between;
  gap: 0;
  position: relative;
}

.rls-mp-ctrl-spacer {
  flex: 1 1 0;
  min-width: 0;
  pointer-events: none;
}

.rls-mp-ctrl-center {
  display: flex;
  flex-direction: row;
  align-items: center;
  justify-content: center;
  gap: 0.72rem;
  flex: 0 0 auto;
}

.rls-mp-ctrl-vol {
  flex: 1 1 0;
  min-width: 0;
  display: flex;
  justify-content: flex-end;
  align-items: center;
  padding-right: 0.28rem;
}

.rls-mp-ico-volume {
  width: 2.28rem;
  height: 2.28rem;
  background-size: 1.42rem 1.42rem;
  background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'%3E%3Cpath fill='%23f0f2f5' d='M5 9.5v5h3.2L12.5 18V6L8.2 9.5H5zm10.4 2.5c0-1.46-.82-2.73-2.02-3.38v6.76A3.77 3.77 0 0015.4 12zm-2.02-7.1v2.09A5.86 5.86 0 0118.3 12a5.86 5.86 0 01-4.92 5.01v2.09A7.93 7.93 0 0020.4 12a7.93 7.93 0 00-7.02-7.1z'/%3E%3C/svg%3E");
  cursor: pointer;
}

.rls-mp-ico-volume:hover {
  -webkit-transform: scale(1.18);
  transform: scale(1.18);
}

.rls-mp-icon {
  display: block;
  flex: 0 0 auto;
  box-sizing: border-box;
  width: 2.15rem;
  height: 2.15rem;
  padding: 0;
  border: 0;
  margin: 0;
  -webkit-appearance: none;
  appearance: none;
  border-radius: 50%;
  background-color: transparent;
  background-repeat: no-repeat;
  background-position: center;
  background-size: var(--rls-mp-ico-glyph) var(--rls-mp-ico-glyph);
  cursor: pointer;
  -webkit-transform-origin: 50% 50%;
  transform-origin: 50% 50%;
  -webkit-transition:
    -webkit-transform 0.08s ease,
    background-color 0.06s ease;
  transition:
    transform 0.08s ease,
    background-color 0.06s ease;
}

.rls-mp-icon:active,
.rls-mp-icon.rls-mp-pressed {
  filter: saturate(0) brightness(0.55);
}

.rls-mp-icon.rls-mp-ico-volume:active {
  filter: none;
}

.rls-mp-icon:not(.rls-mp-icon-play):hover {
  -webkit-transform: scale(1.18);
  transform: scale(1.18);
}

.rls-mp-icon-play:hover {
  -webkit-transform: scale(1.1);
  transform: scale(1.1);
}

.rls-mp-icon-sm {
  width: 1.9rem;
  height: 1.9rem;
  background-size: 1.12rem 1.12rem;
  opacity: 0.45;
}

.rls-mp-icon-sm:hover {
  opacity: 0.8;
}

.rls-mp-icon-sm.active {
  opacity: 1;
}

.rls-mp-icon-sm.rls-mp-ico-shuffle {
  background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'%3E%3Cpath fill='%23f0f2f5' d='M10.59 9.17L5.41 4 4 5.41l5.17 5.18 1.42-1.42zM14.5 4l2.04 2.04L4 18.59 5.41 20 17.96 7.46 20 9.5V4h-5.5zm.33 9.41l-1.41 1.41 3.13 3.13L14.5 20H20v-5.5l-2.04 2.04-3.13-3.13z'/%3E%3C/svg%3E");
}

.rls-mp-icon-sm.rls-mp-ico-shuffle.active {
  background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'%3E%3Cpath fill='%23f97316' d='M10.59 9.17L5.41 4 4 5.41l5.17 5.18 1.42-1.42zM14.5 4l2.04 2.04L4 18.59 5.41 20 17.96 7.46 20 9.5V4h-5.5zm.33 9.41l-1.41 1.41 3.13 3.13L14.5 20H20v-5.5l-2.04 2.04-3.13-3.13z'/%3E%3C/svg%3E");
}

.rls-mp-ico-prev {
  width: 2.28rem;
  height: 2.28rem;
  background-size: 1.42rem 1.42rem;
  background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'%3E%3Cpath fill='%23f0f2f5' d='M6 6h2v12H6V6zm10 0L7.5 12 16 18V6z'/%3E%3C/svg%3E");
}

.rls-mp-ico-next {
  width: 2.28rem;
  height: 2.28rem;
  background-size: 1.42rem 1.42rem;
  background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'%3E%3Cpath fill='%23f0f2f5' d='M6 18l8.5-6L6 6v12zm10-12v12h2V6h-2z'/%3E%3C/svg%3E");
}

.rls-mp-icon-play {
  width: 2.05rem;
  height: 2.05rem;
  background-color: rgba(255, 255, 255, 0.1);
  background-size: 1.48rem 1.48rem;
}

.rls-mp-icon-play:hover {
  background-color: rgba(255, 255, 255, 0.18);
}

.rls-mp-icon-play.rls-mp-ico-play {
  background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'%3E%3Cpath fill='%23f0f2f5' d='M8 5v14l11-7z'/%3E%3C/svg%3E");
}

.rls-mp-icon-play.rls-mp-ico-pause {
  background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'%3E%3Cpath fill='%23f0f2f5' d='M7 7h10v10H7z'/%3E%3C/svg%3E");
}

.rls-mp-icon-sm.rls-mp-ico-repeat {
  background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'%3E%3Cpath fill='%23f0f2f5' d='M7 7h10v3l4-4-4-4v3H5v6h2V7zm10 10H7v-3l-4 4 4 4v-3h12v-6h-2v4z'/%3E%3C/svg%3E");
}

.rls-mp-icon-sm.rls-mp-ico-repeat.active:not(.rls-mp-ico-repeat-one) {
  background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'%3E%3Cpath fill='%23f97316' d='M7 7h10v3l4-4-4-4v3H5v6h2V7zm10 10H7v-3l-4 4 4 4v-3h12v-6h-2v4z'/%3E%3C/svg%3E");
}

.rls-mp-icon-sm.rls-mp-ico-repeat.rls-mp-ico-repeat-one {
  background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'%3E%3Cpath fill='%23f0f2f5' d='M7 7h10v3l4-4-4-4v3H5v6h2V7zm10 10H7v-3l-4 4 4 4v-3h12v-6h-2v4zm-4-2V9h-1l-2 1v1h1.5v4H13z'/%3E%3C/svg%3E");
}

.rls-mp-icon-sm.rls-mp-ico-repeat.rls-mp-ico-repeat-one.active {
  background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'%3E%3Cpath fill='%23f97316' d='M7 7h10v3l4-4-4-4v3H5v6h2V7zm10 10H7v-3l-4 4 4 4v-3h12v-6h-2v4zm-4-2V9h-1l-2 1v1h1.5v4H13z'/%3E%3C/svg%3E");
}
.rls-mp {
  max-width: none;
  box-sizing: border-box;
}
.rls-mp-art {
  flex: 0 0 6.2rem;
  width: 6.2rem;
  height: 6.2rem;
}
button.focus-visible {
  @include overhaul-focus;
}
.rls-mp-volume-flyout {
  display: inline-flex;
  flex-direction: column;
  align-items: stretch;
  margin: 0;
  padding: 0;
  position: fixed;
  top: 0;
  left: 0;
  max-width: calc(100vw - 16px);
  z-index: 2147483646;
  box-sizing: border-box;
  isolation: isolate;
  background: none;
  border: none;
  box-shadow: none;
  pointer-events: auto;
}

.rls-mp-volume-flyout-panel {
  display: flex;
  flex-direction: column;
  align-items: stretch;
  padding: 0;
  border-radius: 999px;
  border: 1px solid rgba(255, 255, 255, 0.12);
  background: rgba(10, 12, 18, 0.86);
  box-shadow: 0 0.4rem 1.1rem rgba(0, 0, 0, 0.55);
  box-sizing: border-box;
  min-width: 2.15rem;
  overflow: hidden;
}

.rls-mp-volume-flyout-slider-region {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  padding: 0.62rem 0.24rem 0;
  box-sizing: border-box;
}

.rls-mp-volume-flyout-icon-well {
  flex: 0 0 auto;
  width: 100%;
  box-sizing: border-box;
  min-height: 2.28rem;
  padding: 0 0.2rem 0.26rem;
  background-color: rgba(10, 12, 18, 0.86);
  background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'%3E%3Cpath fill='%23f0f2f5' d='M5 9.5v5h3.2L12.5 18V6L8.2 9.5H5zm10.4 2.5c0-1.46-.82-2.73-2.02-3.38v6.76A3.77 3.77 0 0015.4 12zm-2.02-7.1v2.09A5.86 5.86 0 0118.3 12a5.86 5.86 0 01-4.92 5.01v2.09A7.93 7.93 0 0020.4 12a7.93 7.93 0 00-7.02-7.1z'/%3E%3C/svg%3E");
  background-repeat: no-repeat;
  background-position: center;
  background-size: 1.42rem 1.42rem;
}

.rls-mp-volume-slider-wrap {
  width: 1.65rem;
  height: 5.85rem;
  display: flex;
  align-items: center;
  justify-content: center;
  overflow: visible;
}

.rls-mp-vslider {
  position: relative;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  cursor: pointer;
  user-select: none;
  -webkit-user-select: none;
  touch-action: none;
  outline: none;
}

.rls-mp-vslider-track {
  position: relative;
  width: 0.32rem;
  height: 4.9rem;
  border-radius: 999px;
  background: rgba(255, 255, 255, 0.22);
  box-sizing: border-box;
}

.rls-mp-vslider-fill {
  position: absolute;
  left: 0;
  right: 0;
  bottom: 0;
  border-radius: inherit;
  background: rgba(240, 242, 245, 0.5);
  height: 0;
  min-height: 0;
  pointer-events: none;
}

.rls-mp-vslider-thumb {
  position: absolute;
  left: 50%;
  width: 0.86rem;
  height: 0.86rem;
  margin-left: -0.43rem;
  bottom: 0;
  border-radius: 50%;
  background: #f0f2f5;
  border: 1px solid rgba(10, 12, 18, 0.45);
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.08);
  pointer-events: none;
  box-sizing: border-box;
}


.rls-mp-volume-flyout-panel { min-width: var(--volume-width, 2.15rem); }
.rls-mp-volume-flyout-icon-well { min-height: var(--volume-icon-height, 2.28rem); }
// Keep the original slim track, with a usable pointer and controller target.
.rls-mp-vslider { width: 1.65rem; height: 5.85rem; }
.rls-mp-vslider.focus-visible { @include overhaul-focus; }

@media (prefers-reduced-motion: reduce) {
  * {
    transition: none !important;
  }
}
.rls-mp-mini-row { display: flex; align-items: center; gap: .35rem; min-width: 0; }
.rls-mp-mini-art { width: 1.8rem; height: 1.8rem; flex: 0 0 1.8rem; object-fit: cover; background-color: #282b33; border-radius: .2rem; background-size: 1rem; background-position: center; background-repeat: no-repeat; }
.rls-mp-mini-track { flex: 1; min-width: 0; display: flex; flex-direction: column; }
.rls-mp-mini-title, .rls-mp-mini-genre { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.rls-mp-mini-title { font-size: .78rem; }
.rls-mp-mini-genre { font-size: .65rem; color: #aeb4be; }
.rls-mp-mini .rls-mp-icon { width: 1.75rem; height: 1.75rem; min-width: 1.75rem; background-size: 1.1rem; }
</style>
