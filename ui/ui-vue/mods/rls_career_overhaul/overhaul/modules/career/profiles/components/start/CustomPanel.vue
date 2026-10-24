<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <!--
    Two labelled columns rather than one flat grid. Everything used to sit in a
    single auto-fit grid, so a slider, a number field, a bare label and a pair of
    toggles all shared rows despite being different heights — nothing lined up
    and the whole panel read as noise. Split by what the setting actually does:
    the numbers that shape the economy on one side, the world you land in on the
    other.
  -->
  <div class="start-panel start-panel--custom">
    <!-- Governs both groups, so it sits above them rather than inside one. -->
    <div class="start-panel-seed">
      <StartDropdown v-model="baseDifficulty" label="Start from" :options="seedOptions" />
      <span class="start-panel-seed-state">{{ changedSummary }}</span>
    </div>

    <section class="custom-group">
      <h3 class="custom-group-title">Economy</h3>

      <!-- No scale ends and no "(Standard)" suffix: the percentage already is
           the value, the tick already marks the seed, and the row above already
           says which seed it is. -->
      <StartSlider
        v-model="economyMultiplier"
        label="Economy"
        :standard-value="seed.money" />
      <StartSlider
        v-model="xpMultiplier"
        label="XP"
        :standard-value="seed.xp" />

      <div class="start-panel-field">
        <label class="start-panel-label">
          Starting Cash
          <span v-if="cashChanged" class="start-panel-changed">was <BngIcon class="cur" :type="icons.beamCurrency" />{{ formatCash(seed.startingCash) }}</span>
        </label>
        <!-- v-bng-text-input owns CEF typing for this field: it enables on focus and releases on blur and unmount. -->
        <input
          v-model.number="startingCash"
          type="number"
          class="start-panel-input"
          min="0"
          step="500"
          inputmode="numeric"
          v-bng-text-input
          @keydown.stop
          @keypress.stop
          @keyup.stop />
        <div class="cash-presets" role="group" aria-label="Starting cash presets">
          <button v-for="amount in [0, 15000, 25000, 50000]" :key="amount" type="button"
            :aria-pressed="startingCash === amount" @click="startingCash = amount">{{ formatCash(amount) }}</button>
        </div>
      </div>
    </section>

    <section class="custom-group">
      <h3 class="custom-group-title">World</h3>

      <StartDropdown v-model="startingMap" label="Starting Map" :options="mapOptions" />
      <p v-if="!mapOptions.length">No career maps are available.</p>
      <StartDropdown v-model="startingGarage" label="Starting Garage" :options="garageOptions" />

      <div class="start-panel-toggles">
        <StartToggle v-model="policeEnabled" label="Police" />
        <StartToggle v-model="maintenanceEnabled" label="Maintenance Mode" />
        <StartToggle v-model="cheatsEnabled" label="Cheats" />
        <StartToggle v-if="APPRENTICESHIP_CHOICE_ENABLED" v-model="employmentApprenticeship" label="Employment" />
      </div>
    </section>

    <!-- A quiet link, not a third competing block. -->
    <button
      bng-nav-item
      type="button"
      class="start-panel-advanced"
      @click.stop="advancedOpen = true"
      @mousedown.stop>
      Advanced — per-activity pay and XP
    </button>

    <SandboxAdvancedModal
      v-model="sandboxEconomyProfile"
      v-model:xp-profile="sandboxXpProfile"
      :open="advancedOpen"
      :economy-multiplier="economyMultiplier"
      :xp-multiplier="xpMultiplier"
      :police-enabled="policeEnabled"
      @close="closeAdvanced" />
  </div>
</template>

<script setup>
import { computed, ref, watch } from "vue"
import { returnFocusToOpener } from "../../../composables/useScreenEntryFocus"
import { vBngTextInput } from "@/common/directives"
import { BngIcon, icons } from "@/common/components/base"
import StartSlider from "./shared/StartSlider.vue"
import StartDropdown from "./shared/StartDropdown.vue"
import StartToggle from "./shared/StartToggle.vue"
import { APPRENTICESHIP_CHOICE_ENABLED } from "./careerStartConfig.js"
import SandboxAdvancedModal from "./SandboxAdvancedModal.vue"
import { useStartMaps } from "./useStartMaps.js"
import { useStartGarages } from "./useStartGarages.js"
import { sanitizeSandboxEconomyProfile } from "./sandboxEconomyManifest.js"
import { sanitizeSandboxXpProfile } from "./sandboxXpManifest.js"
import { CUSTOM_SEED_DIFFICULTY_IDS, getDifficulties, getDifficulty } from "./careerStartModes.js"

const seedDifficulties = getDifficulties(CUSTOM_SEED_DIFFICULTY_IDS)
const seedOptions = seedDifficulties.map(d => ({ value: d.id, label: d.label }))

const baseDifficulty = ref("standard")
const seed = computed(() => getDifficulty(baseDifficulty.value) || getDifficulty("standard"))

const xpMultiplier = ref(seed.value.xp)
const economyMultiplier = ref(seed.value.money)
const startingCash = ref(seed.value.startingCash)

const { mapOptions, startingMap } = useStartMaps()
const { garageOptions, startingGarage } = useStartGarages(startingMap, { allowSpecific: true })
const policeEnabled = ref(true)
const maintenanceEnabled = ref(false)
const cheatsEnabled = ref(false)
const employmentApprenticeship = ref(true)
const advancedOpen = ref(false)

function closeAdvanced() {
  advancedOpen.value = false
  returnFocusToOpener(() => document.querySelector(".start-panel-advanced"))
}
const sandboxEconomyProfile = ref({ umbrellas: {}, expanded: {} })
const sandboxXpProfile = ref({ umbrellas: {} })

/** Picking a different seed re-bases the economy values — that is the point of a seed. */
watch(baseDifficulty, () => {
  xpMultiplier.value = seed.value.xp
  economyMultiplier.value = seed.value.money
  startingCash.value = seed.value.startingCash
})

const cashChanged = computed(() => startingCash.value !== seed.value.startingCash)

const changedCount = computed(() => {
  let n = 0
  if (xpMultiplier.value !== seed.value.xp) n++
  if (economyMultiplier.value !== seed.value.money) n++
  if (cashChanged.value) n++
  return n
})

const changedSummary = computed(() => {
  const n = changedCount.value
  if (!n) return `Matches ${seed.value.label}`
  return `${n} value${n === 1 ? "" : "s"} changed`
})

// Template puts the game currency glyph before it.
// Not units.formatMoney: that rounds to fixed decimals, and this keeps up to three decimals.
function formatCash(value) {
  return Number(value || 0).toLocaleString("en-US")
}

function getStartConfig() {
  return {
    valid: mapOptions.value.some(map => map.value === startingMap.value),
    error: "Select an available starting map.",
    baseDifficulty: baseDifficulty.value,
    xpMultiplier: xpMultiplier.value,
    economyMultiplier: economyMultiplier.value,
    startingCash: startingCash.value,
    startingMap: startingMap.value,
    startingGarage: startingGarage.value,
    policeEnabled: policeEnabled.value,
    maintenanceEnabled: maintenanceEnabled.value,
    cheatsEnabled: cheatsEnabled.value,
    employmentApprenticeship: employmentApprenticeship.value,
    sandboxEconomyProfile: sanitizeSandboxEconomyProfile(sandboxEconomyProfile.value),
    sandboxXpProfile: sanitizeSandboxXpProfile(sandboxXpProfile.value),
  }
}

function isAdvancedOpen() {
  return advancedOpen.value
}

defineExpose({ getStartConfig, isAdvancedOpen })
</script>

<style lang="scss" scoped>
.start-panel {
  display: flex;
  flex-direction: column;
  gap: 1em;
}

.start-panel--custom {
  display: grid;
  grid-template-columns: 1fr 1fr;
  align-items: start;
  gap: 0.35em 1.6em;

  > * {
    min-width: 0;
  }
}

.custom-group {
  display: flex;
  flex-direction: column;
  gap: 0.4em;
  min-width: 0;
}

.custom-group-title {
  margin: 0;
  padding-bottom: 0.25em;
  border-bottom: 1px solid rgba(71, 85, 105, 0.4);
  font-size: 0.72em;
  font-weight: 700;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  color: rgba(255, 255, 255, 0.62);
}

/* The group heading has to outrank what it groups. These were the other way
   round: bold near-white field labels under a small muted heading. */
.custom-group :deep(.start-slider-label),
.custom-group :deep(.start-dropdown-label),
.custom-group .start-panel-label {
  font-size: 0.82em;
  font-weight: 600;
  color: rgba(255, 255, 255, 0.72);
}

.start-panel-seed {
  grid-column: 1 / -1;
  display: flex;
  align-items: flex-end;
  justify-content: space-between;
  gap: 0.4em 0.75em;
  /* At card width the state text drops to its own line rather than overflowing. */
  flex-wrap: wrap;

  :deep(.start-dropdown) {
    flex: 1 1 12em;
    min-width: 0;
  }
}

.start-panel-seed-state {
  flex: 0 1 auto;
  min-width: 0;
  padding-bottom: 0.4em;
  font-size: 0.75em;
  color: rgba(255, 255, 255, 0.45);
  white-space: nowrap;
}

.start-panel-field {
  display: flex;
  flex-direction: column;
  gap: 0.4em;
}

.start-panel-label {
  display: flex;
  align-items: baseline;
  gap: 0.5em;
  font-weight: 600;
  font-size: 0.88em;
  color: rgba(255, 255, 255, 0.75);
}

.start-panel-changed {
  font-size: 0.8em;
  font-weight: 500;
  color: #ff7a1a;
  font-variant-numeric: tabular-nums;
}

.start-panel-input {
  background: rgba(30, 41, 59, 0.9);
  border: 1px solid rgba(71, 85, 105, 0.5);
  border-radius: 10px;
  color: #fff;
  padding: 0.62em 0.8em;
  font-size: 0.9em;
  font-family: inherit;
  outline: none;

  &:focus {
    border-color: rgba(148, 163, 184, 0.5);
  }
}

/* One per line: side by side inside a 14em grid cell wraps the longer label. */
.start-panel-toggles {
  display: flex;
  flex-direction: column;
  gap: 0.35em;
  padding-top: 0.15em;
}

.start-panel-advanced {
  grid-column: 1 / -1;
  justify-self: start;
  margin: 0;
  padding: 0.2em 0;
  border: 0;
  background: none;
  color: rgba(255, 255, 255, 0.6);
  font-family: inherit;
  font-size: 0.8em;
  text-decoration: underline;
  text-underline-offset: 0.2em;
  cursor: pointer;

  &:hover,
  &.focus-visible {
    color: #ff9647;
  }
}

/* Game currency glyph before amounts; inherits colour/size. */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
.cash-presets { display: flex; flex-wrap: wrap; gap: 0.4em; }
.cash-presets button { padding: 0.4em 0.6em; color: inherit; background: #182435; border: 1px solid #475569; border-radius: 0.4em; cursor: pointer; }
.cash-presets button[aria-pressed="true"] { border-color: #ff7a1a; }
</style>
