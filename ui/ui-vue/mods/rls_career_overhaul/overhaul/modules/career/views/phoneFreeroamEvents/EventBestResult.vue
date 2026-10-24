<template>
  <span class="event-best-result">
    <span class="best-result-field">
      <span class="best-result-label">{{ bestLabel(ev) }}</span>
      <strong class="best-result-value">{{ bestValue(ev) }}</strong>
    </span>
    <span v-if="bestValue(ev) !== 'No result yet' && personalBest(ev).vehicleName" class="best-result-field best-result-car">
      <span class="best-result-label">Car</span>
      <span class="best-result-value">{{ personalBest(ev).vehicleName }}</span>
    </span>
  </span>
</template>

<script setup>
import { bestLabel, bestValue, personalBest } from './eventFormat.js'

defineProps({ ev: { type: Object, required: true } })
</script>

<style scoped lang="scss">
// House labelled pairs, using the phone's light-surface ink colours.
.event-best-result {
  display: grid;
  grid-template-columns: max-content minmax(0, 1fr);
  align-items: baseline;
  gap: 1em;
  min-width: 0;
  font-size: 11px;
  line-height: 1.35;
  font-variant-numeric: tabular-nums;
}

.best-result-field {
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  gap: .2em;
  min-width: 0;
}

.best-result-label {
  font-size: .78em;
  font-weight: 700;
  letter-spacing: .06em;
  text-transform: uppercase;
  color: rgba(31,35,40,.55);
}

.best-result-value {
  max-width: 100%;
  font-size: 1em;
  font-weight: 700;
  color: #1f2328;
}

.best-result-car .best-result-value {
  font-weight: 400;
  color: rgba(31,35,40,.65);
  overflow-wrap: anywhere;
}
</style>
