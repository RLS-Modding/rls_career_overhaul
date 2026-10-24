<template>
  <button data-broker-scope type="button" class="icon-btn header-expand" :aria-label="s.expanded ? 'Collapse phone' : 'Expand phone'" @click="s.expanded = !s.expanded"><svg data-broker-scope v-if="!s.expanded" viewBox="0 0 24 24" aria-hidden="true"><path data-broker-scope d="M4 9V4h5M15 4h5v5M20 15v5h-5M9 20H4v-5"/></svg><svg data-broker-scope v-else viewBox="0 0 24 24" aria-hidden="true"><path data-broker-scope d="M9 4v5H4M15 4v5h5M20 15h-5v5M4 15h5v5"/></svg></button>
</template>

<script setup>
import { inject } from 'vue'
const { s } = inject(Symbol.for('overhaul.phoneBroker'))
</script>
