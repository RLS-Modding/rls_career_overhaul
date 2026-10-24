<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <ComputerWrapper :path="[computerStore.computerData.facilityName]" title="Sleep" back @back="close">
    <div class="rls-house sleep-menu">
      <!-- when you'll wake, and how long that is -->
      <header class="wake">
        <span class="wake-icon" :class="phase.tone"><BngIcon :type="phase.icon" /></span>
        <div class="wake-copy">
          <span class="caption">Wake at</span>
          <strong class="wake-time">{{ formatTime(selectedTime) }}</strong>
          <span class="hint">{{ phase.label }}<template v-if="sleepLength">, sleep {{ sleepLength }}</template></span>
        </div>
      </header>

      <!-- the day as a track: noon on both ends, night in the middle -->
      <div class="day-track">
        <input
          class="day-slider"
          type="range"
          v-model.number="selectedTime"
          min="0"
          max="1"
          step="0.001"
          aria-label="Wake-up time"
          bng-nav-item
          bng-scoped-nav-autofocus
          v-bng-on-ui-nav-focus.repeat="timeNav" />
        <!-- controller: the d-pad cannot move a native range by itself, so left/right step the wake time
             here (5 min a press, faster while held, wrapping past noon); up/down leave for the presets -->
        <div class="track-labels" aria-hidden="true">
          <span>12:00</span><span>18:00</span><span>00:00</span><span>06:00</span><span>12:00</span>
        </div>
      </div>

      <div class="presets">
        <button
          v-for="p in presets"
          :key="p.label"
          type="button"
          class="preset"
          :class="{ picked: isPicked(p.time) }"
          bng-nav-item
          @click="setTime(p.time)">
          <BngIcon class="preset-icon" :type="p.icon" />
          <span class="preset-label">{{ p.label }}</span>
          <span class="preset-time">{{ formatTime(p.time) }}</span>
        </button>
      </div>

      <div class="seg bar nudge" role="group" aria-label="Adjust time">
        <button type="button" bng-nav-item @click="adjustTime(-0.0417)">−1 h</button>
        <button type="button" bng-nav-item @click="adjustTime(-0.007)">−10 min</button>
        <button type="button" bng-nav-item @click="adjustTime(0.007)">+10 min</button>
        <button type="button" bng-nav-item @click="adjustTime(0.0417)">+1 h</button>
      </div>

      <div class="cycle">
        <HouseSwitch row v-model="dayNightCycle">
          <span class="cycle-copy">
            <strong>Day/night cycle</strong>
            <span class="hint">Time keeps moving while you play</span>
          </span>
        </HouseSwitch>
      </div>

      <HouseButton class="sleep-button" variant="primary" block :icon="icons.night" @click="sleep">
        Sleep until {{ formatTime(selectedTime) }}
      </HouseButton>
    </div>
  </ComputerWrapper>
</template>

<script setup>
import { reportUiFailure } from "../utils/safeLua"

import { ref, computed, watch, onMounted } from 'vue'
import { BngIcon, icons } from "@/common/components/base"
import ComputerWrapper from "./ComputerWrapper.vue"
import { HouseButton, HouseSwitch } from "../components/house/index.js"
import { useComputerStore } from "../stores/computerStore"
import { lua } from "@/bridge"
import { installLuaBridgeFallbacks } from "../utils/installLuaBridgeFallbacks"
import { useScreenEntry } from "../composables/useScreenEntryFocus"
import { vBngOnUiNavFocus } from "@/common/directives"

installLuaBridgeFallbacks()
const focusScreenEntry = useScreenEntry()

const computerStore = useComputerStore()
const selectedTime = ref(0)
const currentTime = ref(null) // game time when the menu opened (same 0..1 scale, 0 = noon)
const dayNightCycle = ref(true)
let syncingFromLua = false

// time of day: 0 = noon, 0.5 = midnight (BeamNG's scale)
const presets = [
  { label: "Sunrise", time: 0.77, icon: icons.sunRise },
  { label: "Noon", time: 0, icon: icons.day },
  { label: "Sunset", time: 0.22, icon: icons.sunDown },
  { label: "Midnight", time: 0.5, icon: icons.night },
]

const getDayNightCycle = async () => {
  try {
    const result = await lua.overhaul_world_sleep.getDayNightCycle()
    // Set both the day/night cycle and time (rolling TOD is the overhaul default)
    syncingFromLua = true
    dayNightCycle.value = result?.play ?? true
    selectedTime.value = result?.time ?? 0
    currentTime.value = typeof result?.time === "number" ? result.time : null
    syncingFromLua = false
    return result
  } catch (error) {
    syncingFromLua = false
    reportUiFailure(error, "Error in getDayNightCycle: (SleepMenu)")
    return { play: true, time: 0 }
  }
}

onMounted(async () => {
  try {
    await getDayNightCycle()
  } catch (error) {
    reportUiFailure(error, "Error in onMounted: (SleepMenu)")
  }
  // mod route: wake the screen scope so the d-pad starts on the time slider
  focusScreenEntry()
})

watch(dayNightCycle, (newValue) => {
  // Don't push the initial load back into Lua (was fighting the toggle).
  if (syncingFromLua) return
  lua.overhaul_world_sleep.toggleDayNightCycle(newValue)
})

const hourOf = time => (time * 24 + 12) % 24

// whole minutes, rounded: flooring showed 20:24 for 20:25 (505/1440 * 1440 = 504.999...)
const formatTime = (time) => {
  const total = Math.round(hourOf(time) * 60) % (24 * 60)
  const hours = Math.floor(total / 60)
  const minutes = total % 60
  return `${hours.toString().padStart(2, '0')}:${minutes.toString().padStart(2, '0')}`
}

const phase = computed(() => {
  const h = hourOf(selectedTime.value)
  if (h >= 5 && h < 8) return { label: "Sunrise", icon: icons.sunRise, tone: "dawn" }
  if (h >= 8 && h < 12) return { label: "Morning", icon: icons.day, tone: "day" }
  if (h >= 12 && h < 17) return { label: "Afternoon", icon: icons.day, tone: "day" }
  if (h >= 17 && h < 20) return { label: "Evening", icon: icons.sunDown, tone: "dawn" }
  return { label: "Night", icon: icons.night, tone: "night" }
})

// how long you'll sleep from the time the menu opened
const sleepLength = computed(() => {
  if (currentTime.value === null) return ""
  let diff = selectedTime.value - currentTime.value
  if (diff < 0) diff += 1
  const mins = Math.round(diff * 24 * 60)
  if (mins < 1) return ""
  const h = Math.floor(mins / 60), m = mins % 60
  return h ? (m ? `${h} h ${m} min` : `${h} h`) : `${m} min`
})

const isPicked = time => Math.abs(selectedTime.value - time) < 0.0005

const setTime = (time) => {
  selectedTime.value = time
}

const adjustTime = (adjustment) => {
  let newTime = selectedTime.value + adjustment
  if (newTime < 0) newTime += 1
  if (newTime > 1) newTime -= 1
  selectedTime.value = newTime
}

// Controller stepping for the day track (v-bng-on-ui-nav-focus calls back with the held time in
// context.elapsedMs). Steps snap to a grid of the step size so held presses land on round times,
// and grow while held: 5 min, then 15 min, then 30 min. A fixed object, not an inline literal: a new
// binding value on every re-render would reset the directive and cut a held repeat after one step.
const DAY_MINUTES = 24 * 60
const navStepMinutes = elapsedMs => (elapsedMs < 600 ? 5 : elapsedMs < 1400 ? 15 : 30)
const stepTime = (dir, elapsedMs = 0) => {
  const step = navStepMinutes(elapsedMs)
  const minutes = Math.round(selectedTime.value * DAY_MINUTES * 1000) / 1000
  const next = dir > 0 ? (Math.floor(minutes / step) + 1) * step : (Math.ceil(minutes / step) - 1) * step
  selectedTime.value = (((next % DAY_MINUTES) + DAY_MINUTES) % DAY_MINUTES) / DAY_MINUTES
}
const timeNav = { callback: (dir, _val, ctx) => stepTime(dir, ctx?.elapsedMs) }

const sleep = () => {
  lua.overhaul_world_sleep.closeAllMenus()
  lua.overhaul_world_sleep.sleep(selectedTime.value)
}

const close = () => {
  lua.overhaul_world_sleep.closeMenu()
}
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

/* em off a resolution-scaled font so the card keeps its share of the screen at 720p..4K */
.sleep-menu {
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  width: min(30em, 92vw);
  display: grid;
  gap: 1.1em;
  padding: 1.2em 1.3em 1.3em;
  border-radius: var(--radius-control);
  background: rgba(var(--bng-off-black-rgb), 0.9);
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06), 0 14px 40px rgba(0, 0, 0, 0.45);
}

/* ---- wake time */
.wake {
  display: flex;
  align-items: center;
  gap: 0.9em;
}
.wake-icon {
  flex: 0 0 auto;
  display: grid;
  place-items: center;
  width: 3.2em;
  height: 3.2em;
  font-size: 1.15em;
  border-radius: 50%;
  background: var(--panel);
  color: #fde68a;
  :deep(.bng-icon) {
    font-size: 1.6em;
  }
  &.dawn { color: #fdba74; }
  &.night { color: rgba(255, 255, 255, 0.85); }
}
.wake-copy {
  display: grid;
  gap: 0.1em;
}
.wake-time {
  font-size: 2.6em;
  font-weight: 800;
  line-height: 1;
  letter-spacing: -0.01em;
  font-variant-numeric: tabular-nums;
  padding-top: 0.08em; // Overpass sits high
}

/* ---- day track: daylight at both ends, night in the middle */
.day-track {
  display: grid;
  gap: 0.35em;
}
.day-slider {
  -webkit-appearance: none;
  appearance: none;
  width: 100%;
  height: 1.3em;
  margin: 0;
  background: transparent;
  cursor: pointer;
  // controller focus: only the thumb glows (below), no ring around the track; the game's frame stays hidden
  &.focus-visible {
    outline: none;
  }
  &.focus-visible::before {
    display: none !important;
  }
  // 0 = 12:00, .22 sunset, .5 midnight, .77 sunrise, 1 = 12:00
  &::-webkit-slider-runnable-track {
    height: 0.6em;
    border-radius: 1em;
    background: linear-gradient(
      90deg,
      #f6e7b4 0%,
      #f3c37a 17%,
      #f08a4b 22%,
      #3a3456 30%,
      #15161f 50%,
      #3a3456 70%,
      #f08a4b 77%,
      #f3c37a 83%,
      #f6e7b4 100%
    );
    box-shadow: inset 0 0 0 1px rgba(255, 255, 255, 0.08);
  }
  &::-webkit-slider-thumb {
    -webkit-appearance: none;
    width: 1.3em;
    height: 1.3em;
    margin-top: -0.35em;
    border: 0.2em solid #151517;
    border-radius: 50%;
    background: #fff;
    box-shadow: 0 0.05em 0.35em rgba(0, 0, 0, 0.5);
    transition: box-shadow 0.12s, transform 0.12s;
  }
  &.focus-visible::-webkit-slider-thumb {
    transform: scale(1.12);
    box-shadow: 0 0 0 0.24em rgba(255, 102, 0, 0.75), 0 0 0.8em rgba(255, 102, 0, 0.45), 0 0.05em 0.35em rgba(0, 0, 0, 0.5);
  }
  // Firefox (the game is Chromium; this keeps the Atlas right in other browsers)
  &::-moz-range-track {
    height: 0.6em;
    border-radius: 1em;
    background: linear-gradient(90deg, #f6e7b4 0%, #f3c37a 17%, #f08a4b 22%, #3a3456 30%, #15161f 50%, #3a3456 70%, #f08a4b 77%, #f3c37a 83%, #f6e7b4 100%);
  }
  &::-moz-range-thumb {
    width: 0.9em;
    height: 0.9em;
    border: 0.2em solid #151517;
    border-radius: 50%;
    background: #fff;
  }
}
.track-labels {
  display: flex;
  justify-content: space-between;
  color: var(--faint);
  font-size: 0.72em;
  font-weight: 700;
  font-variant-numeric: tabular-nums;
}

/* ---- presets: icon tiles */
.presets {
  display: grid;
  grid-template-columns: repeat(4, minmax(0, 1fr));
  gap: 0.45em;
}
.preset {
  position: relative;
  appearance: none;
  display: grid;
  justify-items: center;
  gap: 0.25em;
  margin: 0;
  padding: 0.75em 0.4em 0.6em;
  border: 0;
  border-radius: var(--radius-panel);
  background: var(--panel);
  color: #fff;
  font: inherit;
  cursor: pointer;
  transition: background-color 0.12s;
  &:hover {
    background: var(--panel-2);
  }
  @include house-focus;
  &.picked {
    background: var(--panel-2);
    .preset-label,
    .preset-icon {
      color: var(--accent-soft);
    }
  }
}
.preset-icon {
  font-size: 1.7em;
  color: rgba(255, 255, 255, 0.82);
}
.preset-label {
  font-weight: 700;
  line-height: 1.1;
}
.preset-time {
  color: var(--faint);
  font-size: 0.8em;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
}

/* ---- nudge bar */
.nudge button {
  font-variant-numeric: tabular-nums;
}

/* ---- day/night cycle */
.cycle {
  padding: 0.65em 0.85em 0.55em;
  border-radius: var(--radius-panel);
  background: var(--panel);
}
.cycle-copy {
  display: grid;
  gap: 0.15em;
  strong {
    font-weight: 700;
  }
}

.sleep-button {
  min-height: 2.9em;
  font-size: 1.05em;
}
</style>
