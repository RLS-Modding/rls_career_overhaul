<!-- Career-only colour picker for PaintPicker's `house` mode. Same contract as the game's BngColorPicker in its
     full_luminosity view (the one PaintPicker used): reads hue / saturation / luminosity from the v-model (the
     picker's Paint), writes them back and emits `change`. The look follows the house; the colours are content.

     Built so a pad can use all of it (Tristan, in game: the field was unusable, the bars moved one click per press
     with no hold, and stepping felt slow and imprecise):
     - the hue x brightness field takes focus; A grabs it, then the d-pad / left stick move the point, A or B lets
       go. Grabbing keeps the d-pad free to leave the field otherwise.
     - the Hue / Saturation / Brightness bars move with d-pad / stick left/right as soon as they have focus.
     - movement is smooth, not stepped: a tap moves 0.5%; held, the value glides from a crawl to fast over about a
       second (requestAnimationFrame, only while a direction is held); the stick's speed follows its deflection;
       holding a trigger (LT/RT) slows everything to a quarter for fine work.
     - the preview follows every frame; the paint goes to the vehicle (PaintPicker `change` -> Painting onChange ->
       overhaul_career_parts_painting.setPaints) throttled to every 70 ms while moving and once more when it stops. -->
<template>
  <div class="house-colour" :class="{ editing }">
    <div
      ref="fieldEl"
      class="house-colour-field"
      :style="{ '--field-hues': hueGradient }"
      tabindex="0"
      bng-nav-item
      role="slider"
      :aria-label="`${$t('ui.color.hue')} / ${$t('ui.color.brightness')}`"
      :aria-valuetext="`${shown.hue}°, ${shown.luminosity}%`"
      v-bng-on-ui-nav:ok.focusRequired="onFieldOk"
      v-bng-on-ui-nav:back.focusRequired="onFieldBack"
      v-pad-drive="editing ? FIELD_DRIVE : false"
      @blur="editing = false"
      @pointerdown="onPointerDown"
      @pointermove="onPointerMove"
      @pointerup="onPointerUp"
      @lostpointercapture="onPointerUp">
      <div
        class="house-colour-dot"
        :style="{
          left: `${values.hue * 100}%`,
          top: `${(1 - values.luminosity) * 100}%`,
          '--dot-fill': `hsl(${shown.hue}, 100%, ${shown.luminosity}%)`,
        }"></div>
      <!-- pad cue: what A does here right now, and the fine-control trigger while grabbed (shown while the field
           has focus, see the styles) -->
      <span v-if="isControllerUsed" class="house-colour-hint">
        <BngBinding ui-event="ok" controller track-ignore />
        <span>{{ editing ? "Done" : "Adjust" }}</span>
        <template v-if="editing">
          <BngBinding class="house-colour-hint-gap" ui-event="subtab_l" controller track-ignore />
          <span>Fine</span>
        </template>
      </span>
    </div>

    <div v-for="bar in bars" :key="bar.key" class="house-colour-bar">
      <div class="house-colour-bar-head">
        <span class="house-colour-bar-name">{{ bar.label }}</span>
        <span class="house-colour-bar-value">{{ bar.value }}</span>
      </div>
      <input
        class="house-colour-track"
        type="range"
        min="0"
        max="1"
        step="any"
        :value="values[bar.key]"
        :style="{ '--track': bar.track, '--thumb': bar.thumb }"
        :aria-label="bar.label"
        bng-nav-item
        v-pad-drive="BAR_DRIVE[bar.key]"
        @input="onBarInput(bar.key, $event)"
        @change="flushNotify" />
    </div>
  </div>
</template>

<script setup>
import { computed, onBeforeUnmount, reactive, ref, watch } from "vue"
import { storeToRefs } from "pinia"
import { BngBinding } from "@/common/components/base"
import { vBngOnUiNav } from "@/common/directives"
import { getUINavHandlers } from "@/services/uiNav"
import { $translate } from "@/services/translation"
import useControls from "@/services/controls"

const props = defineProps({
  // the picker's Paint (reactive); hue / saturation / luminosity are 0..1
  modelValue: { type: Object, required: true },
})
const emit = defineEmits(["update:modelValue", "change"])

const KEYS = ["hue", "saturation", "luminosity"]
// the live colour: drawn every frame from here; written to the Paint (and the vehicle) by notify()
const values = reactive({ hue: 0.5, saturation: 1, luminosity: 0.5 })

// Paint keeps 3 decimals (truncated), so reading back our own write would snap the value and stall a slow
// glide; only adopt model values that differ from what we last wrote (presets, slot switches, finish resets)
const lastWritten = {}
const pull = () => {
  for (const key of KEYS) {
    const val = Number(props.modelValue?.[key])
    if (!Number.isFinite(val)) continue
    if (key in lastWritten && Math.abs(val - lastWritten[key]) < 0.0015) continue
    values[key] = val
    delete lastWritten[key]
  }
}
watch(() => [props.modelValue, ...KEYS.map(key => props.modelValue?.[key])], pull, { immediate: true })

// write back and tell PaintPicker, exactly like BngColorPicker's notify
function notify() {
  for (const key of KEYS) {
    props.modelValue[key] = values[key]
    lastWritten[key] = Number(props.modelValue[key])
  }
  emit("change", props.modelValue)
  emit("update:modelValue", props.modelValue)
}

// every change reaches the vehicle at most every NOTIFY_MS (setPaints repaints all parts in vehicle Lua), with a
// trailing call so the last value always lands; flushNotify sends a pending change right away (release, mouse up)
const NOTIFY_MS = 70
let notifyPending = false
let notifyTimer = 0
let lastNotifyAt = -Infinity
function flushNotify() {
  clearTimeout(notifyTimer)
  notifyTimer = 0
  if (!notifyPending) return
  notifyPending = false
  lastNotifyAt = performance.now()
  notify()
}
function requestNotify() {
  notifyPending = true
  const wait = NOTIFY_MS - (performance.now() - lastNotifyAt)
  if (wait <= 0) flushNotify()
  else if (!notifyTimer) notifyTimer = setTimeout(flushNotify, wait)
}
// leaving the picker (finish switch, slot switch) drops a change still waiting: it belongs to the old state
onBeforeUnmount(() => clearTimeout(notifyTimer))

const clamp01 = x => Math.min(1, Math.max(0, x))

// move one channel; false when it was already there (at an end)
function setChannel(key, val) {
  const next = clamp01(val)
  if (next === values[key]) return false
  values[key] = next
  return true
}

const shown = computed(() => ({
  hue: Math.round(values.hue * 360),
  saturation: Math.round(values.saturation * 100),
  luminosity: Math.round(values.luminosity * 100),
}))

// ---- pad drive (v-pad-drive="{ x: channel, y: channel }"): smooth movement while a direction is held
const TAP_STEP = 0.005 // a press moves this much at once (0.5%)
const HOLD_DELAY = 220 // ms a d-pad press must be held before it glides
const RAMP_MS = 1000 // ms from the slowest to the fastest glide
const V_MIN = 0.04 // glide speed in range per second: 4%/s when the glide starts ...
const V_MAX = 0.5 // ... easing in to 50%/s (the whole range in about 2 s)
const V_STICK = 0.5 // full stick deflection; the speed follows deflection squared
const STICK_DEADZONE = 0.12
const FINE = 0.25 // holding a trigger
const AXES = {
  x: { neg: "focus_l", pos: "focus_r", stick: "focus_lr" },
  y: { neg: "focus_d", pos: "focus_u", stick: "focus_ud" },
}
const FINE_EVENTS = ["subtab_l", "subtab_r"]

// fixed objects: a new binding value per render would rebuild the handlers mid-hold
const FIELD_DRIVE = { x: "hue", y: "luminosity" }
const BAR_DRIVE = Object.fromEntries(KEYS.map(key => [key, { x: key }]))

function createDrive(el, cfg) {
  const axes = Object.keys(AXES).filter(axis => cfg[axis])
  const driveEvents = axes.flatMap(axis => Object.values(AXES[axis]))
  const pressedAt = {} // d-pad event -> press time
  const stick = { x: 0, y: 0 }
  const fineHeld = {}
  let raf = 0
  let lastFrame = 0

  const fineFactor = () => (FINE_EVENTS.some(name => fineHeld[name]) ? FINE : 1)
  const dpadDir = axis => (pressedAt[AXES[axis].pos] ? 1 : 0) - (pressedAt[AXES[axis].neg] ? 1 : 0)
  const dpadVelocity = (axis, now) => {
    const dir = dpadDir(axis)
    if (!dir) return 0
    const held = now - pressedAt[dir > 0 ? AXES[axis].pos : AXES[axis].neg]
    if (held < HOLD_DELAY) return 0
    const k = Math.min(1, (held - HOLD_DELAY) / RAMP_MS)
    return dir * (V_MIN + (V_MAX - V_MIN) * k * k)
  }
  const stickVelocity = axis => {
    const raw = stick[axis]
    const s = (Math.abs(raw) - STICK_DEADZONE) / (1 - STICK_DEADZONE)
    return s > 0 ? Math.sign(raw) * V_STICK * Math.min(1, s) ** 2 : 0
  }
  const anyInput = () => axes.some(axis => dpadDir(axis) || Math.abs(stick[axis]) > STICK_DEADZONE)

  function frame(now) {
    const dt = Math.min(50, Math.max(0, now - lastFrame)) / 1000
    lastFrame = now
    if (!anyInput()) {
      raf = 0
      flushNotify()
      return
    }
    const factor = fineFactor()
    let moved = false
    for (const axis of axes) {
      const v = (dpadVelocity(axis, now) + stickVelocity(axis)) * factor
      if (v && setChannel(cfg[axis], values[cfg[axis]] + v * dt)) moved = true
    }
    if (moved) requestNotify()
    raf = requestAnimationFrame(frame)
  }
  const startLoop = () => {
    if (raf) return
    lastFrame = performance.now()
    raf = requestAnimationFrame(frame)
  }
  // input released: end the loop now rather than on its next frame, so a frame that never comes (a hidden view
  // pauses requestAnimationFrame) cannot leave a stale loop id that blocks the next press
  const endLoop = () => {
    if (raf) cancelAnimationFrame(raf)
    raf = 0
    flushNotify()
  }
  const stop = () => {
    for (const name in pressedAt) delete pressedAt[name]
    stick.x = stick.y = 0
    endLoop()
  }

  function onNav(evt) {
    const detail = evt.fromController || evt.detail
    const name = detail?.name
    if (FINE_EVENTS.includes(name)) {
      fineHeld[name] = Number(detail.value) > 0.3
      return true // not ours to consume
    }
    const axis = axes.find(a => Object.values(AXES[a]).includes(name))
    if (!axis) return true
    if (name === AXES[axis].stick) {
      stick[axis] = Number(detail.value) || 0
      if (Math.abs(stick[axis]) > STICK_DEADZONE) startLoop()
      else if (!anyInput()) endLoop()
      return false
    }
    if (detail.value) {
      if (!pressedAt[name]) {
        pressedAt[name] = performance.now()
        // the tap: one fine step right away, then the glide takes over if held
        const dir = name === AXES[axis].pos ? 1 : -1
        if (setChannel(cfg[axis], values[cfg[axis]] + dir * TAP_STEP * fineFactor())) requestNotify()
      }
      startLoop()
    } else {
      delete pressedAt[name]
      if (!anyInput()) endLoop()
    }
    return false
  }

  const handler = getUINavHandlers().add(
    el,
    {
      name: name => driveEvents.includes(name) || FINE_EVENTS.includes(name),
      value: undefined, // press and release edges, and the stick's analog value
      focusRequired: el,
      eventNames: [...driveEvents, ...FINE_EVENTS],
      source: "house-paint-colour",
    },
    onNav
  )
  // a held direction that loses focus never sends its release
  el.addEventListener("blur", stop)
  return {
    cfg,
    cleanup() {
      stop()
      el.removeEventListener("blur", stop)
      if (handler) getUINavHandlers().remove(el, handler)
    },
  }
}

const DRIVE_PROP = "__housePaintDrive"
const vPadDrive = {
  mounted(el, { value }) {
    if (value) el[DRIVE_PROP] = createDrive(el, value)
  },
  updated(el, { value }) {
    if (el[DRIVE_PROP]?.cfg === value || (!el[DRIVE_PROP] && !value)) return
    el[DRIVE_PROP]?.cleanup()
    el[DRIVE_PROP] = value ? createDrive(el, value) : null
  },
  beforeUnmount(el) {
    el[DRIVE_PROP]?.cleanup()
    el[DRIVE_PROP] = null
  },
}

// ---- field: A grabs / lets go, B lets go (and only otherwise goes back a screen)
const fieldEl = ref(null)
const editing = ref(false)
const { isControllerUsed } = storeToRefs(useControls())

const onFieldOk = () => {
  editing.value = !editing.value
  return false
}
const onFieldBack = () => {
  if (!editing.value) return true // not grabbed: let B reach the screen
  editing.value = false
  return false
}

// ---- field: mouse drag (pointer capture keeps the drag going past the edges)
let dragging = false
function pickAt(evt) {
  const rect = fieldEl.value?.getBoundingClientRect()
  if (!rect || rect.width < 20 || rect.height < 4) return
  const hue = setChannel("hue", (evt.clientX - rect.left) / rect.width)
  const lum = setChannel("luminosity", 1 - (evt.clientY - rect.top) / rect.height)
  if (hue || lum) requestNotify()
}
function onPointerDown(evt) {
  if (evt.button !== 0) return
  dragging = true
  evt.currentTarget.setPointerCapture?.(evt.pointerId)
  pickAt(evt)
}
function onPointerMove(evt) {
  if (dragging) pickAt(evt)
}
function onPointerUp(evt) {
  if (!dragging) return
  dragging = false
  if (evt.type === "pointerup") pickAt(evt)
  flushNotify()
}

// ---- bars (mouse drag / keyboard arrows on the native range)
function onBarInput(key, evt) {
  if (setChannel(key, Number(evt.target.value))) requestNotify()
}

const hueStops = [...Array(7)].map((_, i) => `hsl(${(i / 6) * 360}, 100%, 50%)`)
const hueGradient = `linear-gradient(90deg, ${hueStops.join(", ")})`

const bars = computed(() => {
  const { hue, saturation, luminosity } = shown.value
  const now = `hsl(${hue}, ${saturation}%, ${luminosity}%)`
  return [
    {
      key: "hue",
      label: $translate.instant("ui.color.hue"),
      value: `${hue}°`,
      track: hueGradient,
      thumb: `hsl(${hue}, 100%, 50%)`,
    },
    {
      key: "saturation",
      label: $translate.instant("ui.color.saturation"),
      value: `${saturation}%`,
      track: `linear-gradient(90deg, hsl(${hue}, 0%, ${luminosity}%), hsl(${hue}, 100%, ${luminosity}%))`,
      thumb: now,
    },
    {
      key: "luminosity",
      label: $translate.instant("ui.color.brightness"),
      value: `${luminosity}%`,
      track: `linear-gradient(90deg, hsl(${hue}, ${saturation}%, 0%), hsl(${hue}, ${saturation}%, 50%), hsl(${hue}, ${saturation}%, 100%))`,
      thumb: now,
    },
  ]
})
</script>

<style lang="scss" scoped>
// Tokens (--radius-*, --faint) come from the career screen's .rls-house root; fallbacks match.
// Focus (pad and keyboard): only the point / thumb glows orange, never a ring around the field or a bar (Tristan:
// a ring around a whole slider is too much). The game's own .focus-visible::before frame is hidden.
$focus-glow: 0 0 0 0.24em rgba(255, 102, 0, 0.8), 0 0 0.8em rgba(255, 102, 0, 0.45);
@mixin colour-focus {
  &.focus-visible {
    outline: none;
  }
  &.focus-visible::before {
    display: none !important;
  }
}

.house-colour {
  display: grid;
  gap: 0.75em;
}

// ---- hue x brightness field (white at the top, pure hue in the middle, black at the bottom)
.house-colour-field {
  position: relative;
  height: 9em;
  border-radius: var(--radius-panel, 0.5em);
  background-image:
    linear-gradient(180deg, #fff, rgba(255, 255, 255, 0) 50%, rgba(0, 0, 0, 0) 50%, #000),
    var(--field-hues);
  cursor: crosshair;
  touch-action: none;
  // no overflow clip: the point stays whole at the field's edges
  @include colour-focus;
}

.house-colour-dot {
  position: absolute;
  width: 0;
  height: 0;
  pointer-events: none;
  &::before {
    content: "";
    position: absolute;
    box-sizing: border-box;
    left: -0.55em;
    top: -0.55em;
    width: 1.1em;
    height: 1.1em;
    border-radius: 50%;
    border: 0.2em solid #fff;
    background: var(--dot-fill);
    box-shadow: 0 0 0 1px rgba(0, 0, 0, 0.55), 0 0.05em 0.35em rgba(0, 0, 0, 0.45);
    transition: transform 0.12s, box-shadow 0.12s;
  }
}

// focused: the point glows; grabbed with a pad: it also grows, saying the d-pad now moves it
.house-colour-field.focus-visible .house-colour-dot::before {
  box-shadow: 0 0 0 1px rgba(0, 0, 0, 0.55), $focus-glow;
}
.editing .house-colour-dot::before {
  transform: scale(1.4);
}

// short chip in the field's corner (pad only), while the field has focus
.house-colour-hint {
  display: none;
  position: absolute;
  left: 0.45em;
  bottom: 0.45em;
  align-items: center;
  gap: 0.3em;
  padding: 0.2em 0.5em 0.15em 0.25em;
  border-radius: var(--radius-pill, 1em);
  background: rgba(14, 14, 16, 0.82);
  color: #fff;
  font-size: 0.8em;
  font-weight: 700;
  line-height: 1;
  pointer-events: none;
  > span {
    padding-top: 0.12em; // Overpass sits high
  }
  .house-colour-hint-gap {
    margin-left: 0.35em;
  }
}
.house-colour-field:focus .house-colour-hint,
.house-colour-field.focus-visible .house-colour-hint {
  display: inline-flex;
}

// ---- bars
.house-colour-bar {
  display: grid;
  gap: 0.3em;
}

.house-colour-bar-head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 0.6em;
}

// Style Guide caption, as the finish sliders below
.house-colour-bar-name {
  font-size: 0.78em;
  font-weight: 700;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  color: var(--faint, rgba(255, 255, 255, 0.55));
}

.house-colour-bar-value {
  font-weight: 700;
  font-variant-numeric: tabular-nums;
}

.house-colour-track {
  -webkit-appearance: none;
  appearance: none;
  display: block;
  width: 100%;
  height: 1.3em;
  margin: 0;
  padding: 0;
  border: 0;
  border-radius: var(--radius-control, 0.6em);
  background: transparent;
  cursor: pointer;
  @include colour-focus;

  &::-webkit-slider-runnable-track {
    height: 0.75em;
    border-radius: 1em;
    background: var(--track);
    box-shadow: inset 0 0 0 1px rgba(255, 255, 255, 0.1);
  }
  &::-webkit-slider-thumb {
    -webkit-appearance: none;
    width: 1.3em;
    height: 1.3em;
    margin-top: -0.275em;
    border: 0.2em solid #fff;
    border-radius: 50%;
    background: var(--thumb);
    box-shadow: 0 0 0 1px rgba(0, 0, 0, 0.5), 0 0.05em 0.3em rgba(0, 0, 0, 0.4);
    transition: transform 0.12s, box-shadow 0.12s;
  }
  &.focus-visible::-webkit-slider-thumb {
    transform: scale(1.12);
    box-shadow: 0 0 0 1px rgba(0, 0, 0, 0.5), $focus-glow;
  }
  // Firefox (the game is Chromium; keeps the Atlas right in other browsers)
  &::-moz-range-track {
    height: 0.75em;
    border-radius: 1em;
    background: var(--track);
  }
  &::-moz-range-thumb {
    box-sizing: border-box;
    width: 1.3em;
    height: 1.3em;
    border: 0.2em solid #fff;
    border-radius: 50%;
    background: var(--thumb);
  }
}
</style>
