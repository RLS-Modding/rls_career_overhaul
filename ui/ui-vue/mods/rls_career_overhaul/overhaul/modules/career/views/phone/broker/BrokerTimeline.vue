<template>
  <span data-broker-scope class="job-timeline" aria-label="Load timeline">
    <span data-broker-scope v-for="step in jobTimeline(row)" :key="step.label" :class="{ done: step.done }">{{ step.done ? '\u2713 ' : '' }}{{ step.label }}</span>
  </span>
</template>
<script setup>
import { inject } from 'vue'
defineProps({ row: { type: Object, required: true } })
const { jobTimeline } = inject(Symbol.for('overhaul.phoneBroker'))
</script>
