<!-- Uninsured vehicles row on the insurance overview. A house row: red only when something is
     actually uninsured; neutral while the overview payload is still loading (no count yet means unknown,
     never "covered"). Title, description and count are the game's (translated) strings. -->
<template>
  <div
    bng-nav-item
    tabindex="0"
    class="rls-house no-insurance-card"
    :class="{ 'has-uninsured': loaded && count > 0, loading: !loaded }"
    @click="loaded && $emit('open')">
    <BngIcon class="no-insurance-icon" :type="!loaded ? icons.shieldCheckmark : count > 0 ? icons.danger : icons.checkmark" />
    <div class="no-insurance-text-wrapper">
      <div class="no-insurance-title">
        {{ loaded ? uninsuredVehsData.title : "…" }}
      </div>
      <div v-if="loaded && uninsuredVehsData.description" class="no-insurance-description">
        {{ uninsuredVehsData.description }}
      </div>
    </div>
    <span v-if="loaded" class="pill uninsured-count" :class="{ bad: count > 0 }">
      {{ $translate.instant("ui.career.insurance.vehiclesCount", { count }) }}
    </span>
    <svg class="chevron" viewBox="0 0 24 24" aria-hidden="true"><path d="M9 6l6 6-6 6" /></svg>
  </div>
</template>

<script setup>
import { computed } from "vue"
import { BngIcon, icons } from "@/common/components/base"
import { $translate } from "@/services/translation"

defineEmits(["open"])

const props = defineProps({
  uninsuredVehsData: {
    type: Object,
    required: true,
  },
})

// loaded once the overview payload has a real count; until then the row stays neutral
const loaded = computed(() => Number.isFinite(Number(props.uninsuredVehsData?.carsUninsuredCount)) && props.uninsuredVehsData?.carsUninsuredCount !== null && props.uninsuredVehsData?.carsUninsuredCount !== "")
const count = computed(() => (loaded.value ? Number(props.uninsuredVehsData.carsUninsuredCount) : 0))
</script>

<style scoped lang="scss">
@use "@/styles/modules/mixins" as *;
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

.no-insurance-card {
  $rad: var(--radius-panel);
  $f-offset: 0.2em;
  position: relative;
  display: flex;
  align-items: center;
  gap: 0.8em;
  padding: 0.85em 1em 0.75em;
  border-radius: $rad;
  background: var(--panel);
  color: #fff;
  cursor: pointer;
  transition: background-color 0.12s;

  @include house-focus;

  &:hover,
  &:focus,
  &:focus-within {
    background: var(--panel-2);
  }
  &.has-uninsured .no-insurance-icon {
    color: var(--bad);
  }
  // payload not here yet: neutral, not clickable, no "covered" tick
  &.loading {
    cursor: default;
    .no-insurance-icon,
    .no-insurance-title {
      color: var(--faint);
    }
  }
}

.no-insurance-icon {
  flex: 0 0 auto;
  font-size: 1.6em;
  color: var(--ok-ink);
}

.no-insurance-text-wrapper {
  flex: 1 1 auto;
  min-width: 0;
  display: grid;
  gap: 0.1em;
}

.no-insurance-title {
  font-size: 1.1em;
  font-weight: 800;
}

.no-insurance-description {
  color: var(--muted);
  font-size: 0.88em;
  font-weight: 600;
}

.uninsured-count {
  flex: 0 0 auto;
  font-variant-numeric: tabular-nums;
}

.chevron {
  flex: 0 0 auto;
  width: 0.9em;
  height: 0.9em;
  fill: none;
  stroke: var(--faint);
  stroke-width: 2.4;
  stroke-linecap: round;
  stroke-linejoin: round;
}
</style>
