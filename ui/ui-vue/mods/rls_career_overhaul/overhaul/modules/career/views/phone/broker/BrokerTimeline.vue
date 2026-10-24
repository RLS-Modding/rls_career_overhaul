<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

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
