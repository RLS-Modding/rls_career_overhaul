<template>
  <div class="start-panel">
    <div class="start-difficulty">
      <label class="start-difficulty-label">Difficulty</label>
      <div class="start-difficulty-cards">
        <button
          v-for="d in difficulties"
          :key="d.id"
          bng-nav-item
          type="button"
          class="sd-card"
          :class="{ 'sd-card--active': d.id === difficulty }"
          :aria-pressed="d.id === difficulty"
          @click="difficulty = d.id">
          <span class="sd-name">{{ d.label }}</span>
          <span class="sd-stats">
            <span class="sd-stat">{{ formatMultiplier(d.money) }} money</span>
            <span class="sd-stat">{{ formatMultiplier(d.xp) }} XP</span>
            <span class="sd-stat"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatCash(d.startingCash) }} start</span>
          </span>
          <span class="sd-blurb">{{ d.blurb }}</span>
        </button>
      </div>
    </div>

    <p v-if="!mapOptions.length" class="start-panel-locked">{{ hardcoreLocks ? "Hardcore is unavailable on the installed career maps." : "No career maps are available." }}</p>

    <template v-if="hardcoreLocks">
      <StartDropdown v-model="startingMap" label="Starting Map" :options="mapOptions" />
      <p v-if="startingMapPolicy?.locked">This map uses a fixed hardcore starting location.</p>
      <div class="start-panel-locked">
        <span class="start-panel-locked-title">Hardcore sets these rules</span>
        <ul class="start-panel-locked-list">
          <li v-for="lock in hardcoreLocks" :key="lock">{{ lock }}</li>
        </ul>
      </div>
      <div class="start-panel-toggles">
        <StartToggle v-model="maintenanceEnabled" label="Maintenance Mode" />
        <StartToggle v-if="APPRENTICESHIP_CHOICE_ENABLED" v-model="employmentApprenticeship" label="Employment" />
      </div>
    </template>

    <!-- Where you start is a refinement, not a first-run decision. -->
    <template v-else>
      <div class="start-panel-pair">
        <StartDropdown v-model="startingMap" label="Starting Map" :options="mapOptions" />
        <StartDropdown v-model="startingGarage" label="Starting Garage" :options="garageOptions" />
      </div>
      <div class="start-panel-toggles">
        <StartToggle v-model="policeEnabled" label="Police" />
        <StartToggle v-model="maintenanceEnabled" label="Maintenance Mode" />
        <StartToggle v-if="APPRENTICESHIP_CHOICE_ENABLED" v-model="employmentApprenticeship" label="Employment" />
      </div>
    </template>
  </div>
</template>

<script setup>
import { computed, ref, watch } from "vue"
import { BngIcon, icons } from "@/common/components/base"
import StartDropdown from "./shared/StartDropdown.vue"
import StartToggle from "./shared/StartToggle.vue"
import { APPRENTICESHIP_CHOICE_ENABLED } from "./careerStartConfig.js"
import { useStartMaps } from "./useStartMaps.js"
import { useStartGarages } from "./useStartGarages.js"
import { CAREER_PATH_DIFFICULTY_IDS, getDifficulties, getDifficulty } from "./careerStartModes.js"

const emit = defineEmits(["name-hint"])

const difficulties = getDifficulties(CAREER_PATH_DIFFICULTY_IDS)
const difficulty = ref("standard")

function formatMultiplier(value) {
  return `${Number(value) % 1 === 0 ? value.toFixed(1) : value}×`
}

// The template puts the game currency glyph before it.
// Not units.formatMoney: that rounds to fixed decimals, and this keeps up to three.
function formatCash(value) {
  if (!value) return "0"
  return Number(value).toLocaleString("en-US")
}

const { mapOptions, startingMap, startingMapPolicy } = useStartMaps(null, difficulty)
const { garageOptions, startingGarage } = useStartGarages(startingMap)
const policeEnabled = ref(true)
const maintenanceEnabled = ref(false)
const employmentApprenticeship = ref(true)

/** Lets the card suggest "Standard" rather than "Profile 216" while untouched. */
watch(
  difficulty,
  id => {
    emit("name-hint", getDifficulty(id)?.label || null)
  },
  { immediate: true }
)

/**
 * Hardcore forces garage and police in the Lua whatever the UI sends, so
 * those controls are replaced by a statement of what it does. Maintenance stays
 * player-choice and is shown under the locks.
 */
const hardcoreLocks = computed(() => getDifficulty(difficulty.value)?.locks || null)

function getStartConfig() {
  return {
    valid: mapOptions.value.some(map => map.value === startingMap.value),
    error: "Select an available starting map.",
    difficulty: difficulty.value,
    startingMap: startingMap.value,
    startingGarage: startingGarage.value,
    policeEnabled: policeEnabled.value,
    maintenanceEnabled: maintenanceEnabled.value,
    employmentApprenticeship: employmentApprenticeship.value,
  }
}

defineExpose({ getStartConfig })
</script>

<style lang="scss" scoped>
.start-difficulty {
  display: flex;
  flex-direction: column;
  gap: 0.4em;
}

.start-difficulty-label {
  font-weight: 600;
  font-size: 0.88em;
  color: rgba(255, 255, 255, 0.75);
}

.start-difficulty-cards {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(9em, 1fr));
  gap: 0.5em;
}

.sd-card {
  display: flex;
  flex-direction: column;
  gap: 0.4em;
  text-align: left;
  padding: 0.7em 0.75em;
  border: 1px solid rgba(71, 85, 105, 0.45);
  border-radius: 10px;
  background: rgba(5, 8, 15, 0.55);
  color: #fff;
  font-family: inherit;
  cursor: pointer;

  &:hover:not(.sd-card--active) {
    border-color: rgba(255, 122, 26, 0.45);
    background: rgba(255, 122, 26, 0.05);
  }

  &.sd-card--active {
    border-color: #ff7a1a;
    background: rgba(255, 122, 26, 0.09);
  }
}

.sd-name {
  font-size: 1em;
  font-weight: 800;
  letter-spacing: -0.01em;
}

.sd-card--active .sd-name {
  color: #ff7a1a;
}

.sd-stats {
  display: flex;
  flex-direction: column;
  gap: 0.1em;
  font-size: 0.72em;
  color: rgba(255, 255, 255, 0.62);
  font-variant-numeric: tabular-nums;
}

.sd-blurb {
  font-size: 0.7em;
  line-height: 1.35;
  color: rgba(255, 255, 255, 0.38);
}

/* Game currency glyph before amounts; inherits colour/size. */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}

.start-panel {
  display: flex;
  flex-direction: column;
  gap: 1em;
}

.start-panel-pair {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 0.75em;
  min-width: 0;

  > * {
    min-width: 0;
  }

  &--stacked {
    grid-template-columns: 1fr;
    gap: 0.6em;
  }
}

.start-panel-toggles {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 0.75em 1em;
  padding-top: 0.25em;
}

/* Unboxed: the dashed frame's own padding was most of the overflow, and plain
   lines under a heading read the same as a panel without costing 26px. */
.start-panel-locked {
  display: flex;
  flex-direction: column;
  gap: 0.2em;
}

.start-panel-locked-title {
  font-size: 0.82em;
  font-weight: 700;
  color: #fff;
}

.start-panel-locked-list {
  margin: 0;
  padding-left: 1em;
  font-size: 0.76em;
  line-height: 1.35;
  color: rgba(255, 255, 255, 0.6);

  li {
    margin: 0.05em 0;
  }
}
</style>
