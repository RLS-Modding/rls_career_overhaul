<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <div class="start-slider">
    <div class="start-slider-header">
      <label class="start-slider-label" :for="inputId">{{ labelText }}</label>
      <span class="start-slider-value" :class="{ 'start-slider-value--baseline': isAtBaseline }">{{ displayValue }}</span>
    </div>
    <HouseSlider
      :id="inputId"
      :model-value="modelValue"
      :min="min" :max="max" :step="step"
      :orig-value="showBaselineMarker ? standardValue : undefined"
      :disabled="disabled"
      :aria-label="labelText"
      :aria-valuetext="displayValue"
      @update:model-value="emit('update:modelValue', Number($event))" />
    <div v-if="leftLabel || rightLabel" class="start-slider-scale">
      <span class="start-slider-scale-end">{{ leftLabel }}</span>
      <span class="start-slider-scale-end start-slider-scale-end--right">{{ rightLabel }}</span>
    </div>
  </div>
</template>

<script>
let uid = 0
</script>

<script setup>
import { computed } from "vue"
import HouseSlider from "../../../../components/house/HouseSlider.vue"

const props = defineProps({
  label: { type: String, required: true },
  modelValue: { type: Number, default: 1 },
  min: { type: Number, default: 0.25 },
  max: { type: Number, default: 3 },
  step: { type: Number, default: 0.25 },
  format: { type: Function, default: null },
  disabled: { type: Boolean, default: false },
  leftLabel: { type: String, default: "" },
  rightLabel: { type: String, default: "" },
  standardValue: { type: Number, default: 1 },
  /** Shown in the label when value equals standardValue, e.g. "(Standard)". */
  baselineSuffix: { type: String, default: "" },
  showBaselineMarker: { type: Boolean, default: true },
})

const emit = defineEmits(["update:modelValue"])

const inputId = `start-slider-${++uid}`

const isAtBaseline = computed(() => {
  return Math.abs(props.modelValue - props.standardValue) < 0.001
})

const labelText = computed(() => {
  if (isAtBaseline.value && props.baselineSuffix) {
    return `${props.label} ${props.baselineSuffix}`
  }
  return props.label
})

const displayValue = computed(() => {
  if (props.format) return props.format(props.modelValue)
  return `${Math.round(Number(props.modelValue) * 100)}%`
})

</script>

<style lang="scss" scoped>
@use "@/styles/rls_career_overhaul/modules/career/profiles/components/start/careerStartTheme.scss" as theme;

.start-slider {
  display: flex;
  flex-direction: column;
  gap: 0.45em;
}

.start-slider-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.5em;
  min-height: 1.2em;
}

.start-slider-label {
  font-weight: 600;
  font-size: 0.88em;
  color: rgba(255, 255, 255, 0.75);
}

.start-slider-value {
  font-size: 0.82em;
  font-weight: 600;
  color: theme.$start-accent-muted;
  font-variant-numeric: tabular-nums;
  text-align: right;
}

/* Always shown now, so at the default it stays quiet rather than reading as a
   change the player made. */
.start-slider-value--baseline {
  color: rgba(255, 255, 255, 0.4);
  font-weight: 500;
}

.start-slider-scale {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.5em;
  font-size: 0.72em;
  color: rgba(255, 255, 255, 0.45);
  padding: 0 0.1em;
}

.start-slider-scale-end {
  flex: 1 1 0;

  &--right {
    text-align: right;
  }
}

</style>
