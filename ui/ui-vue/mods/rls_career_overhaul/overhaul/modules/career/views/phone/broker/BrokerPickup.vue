<template>
  <span data-broker-scope class="pickup-distance" :class="{ here: row.atPickup }" :title="label" :aria-label="label" role="img"><BngIcon data-broker-scope :type="icons.mapPoint" aria-hidden="true" /><span data-broker-scope v-if="!row.atPickup" aria-hidden="true">{{ dist(row.pickupDistance) }}</span><span data-broker-scope v-else-if="spelled" aria-hidden="true">You're here</span></span>
</template>

<script setup>
import { computed, inject } from 'vue'
// spelled: write You're here beside the pin, where the pin stands alone (pickup headings).
const props = defineProps({ row: { type: Object, required: true }, spelled: Boolean })
const { BngIcon, icons, dist } = inject(Symbol.for('overhaul.phoneBroker'))
const label = computed(() => props.row.atPickup ? "You're here" : dist(props.row.pickupDistance) + ' to pickup')
</script>
