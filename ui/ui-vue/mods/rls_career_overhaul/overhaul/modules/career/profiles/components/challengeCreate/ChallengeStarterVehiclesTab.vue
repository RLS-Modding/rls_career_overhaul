<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <div class="ccm-tab-panel">
    <p class="ccm-hint">Optional. A new career on this challenge starts with one of these cars, picked at random. They're old and have plenty of miles on them.</p>
    <div class="ccm-field">
      <input v-bng-text-input v-model="query" class="ccm-input" placeholder="Search cars..." />
    </div>

    <div v-if="starterVehicles.length > 0" class="ccm-garage-selection">
      <div class="ccm-garage-selected">
        <div class="ccm-garage-selected-title">Selected Cars ({{ starterVehicles.length }})</div>
        <div class="ccm-garage-selected-list">
          <div v-for="vehicle in selectedRows" :key="vehicle.id" class="ccm-garage-selected-item">
            <span>{{ vehicle.name }}</span>
            <button
              class="ccm-garage-remove"
              type="button"
              @click.stop="removeVehicle(vehicle.id)"
              @mousedown.stop
            >
              ×
            </button>
          </div>
        </div>
      </div>
    </div>

    <div class="ccm-garages">
      <div v-for="vehicle in filteredVehicles" :key="vehicle.id" class="ccm-garage-row">
        <label class="ccm-garage-label">
          <input
            v-model="selectedModel"
            :value="vehicle.id"
            type="checkbox"
            class="ccm-garage-checkbox"
          />
          <div class="ccm-garage-info">
            <div class="ccm-garage-name">{{ vehicle.name }}</div>
            <div class="ccm-garage-details">
              <span>{{ vehicle.id }}</span>
            </div>
          </div>
        </label>
      </div>
    </div>
  </div>
</template>

<script setup>
import { vBngTextInput } from "@/common/directives"
// Starter vehicles: the editor's starter configs filtered by the search box, and the selected ids as { id, name }
// chips. Ids are "model/config" strings, so a JSON-only entry still shows by its id. The selection is a prop; every
// change goes out as an update event, so the parent's ref stays the only state. The list styles come from the modal.
import { computed, ref } from 'vue'

const props = defineProps({
  starterVehicles: { type: Array, default: () => [] },
  // Lua sends an empty list as an object, so anything but an array counts as no vehicles.
  availableStarterVehicles: { type: [Array, Object], default: () => [] },
})
const emit = defineEmits(['update:starterVehicles'])

const query = ref('')
const available = computed(() => Array.isArray(props.availableStarterVehicles) ? props.availableStarterVehicles : [])

const selectedModel = computed({ get: () => props.starterVehicles, set: value => emit('update:starterVehicles', value) })

const filteredVehicles = computed(() => {
  const q = query.value.trim().toLowerCase()
  const vehicles = available.value
  if (!q) return vehicles
  return vehicles.filter(v => ((v.name || '') + ' ' + (v.id || '')).toLowerCase().includes(q))
})

const selectedRows = computed(() => props.starterVehicles.map(vehicleId => {
  const vehicle = available.value.find(v => v.id === vehicleId)
  return { id: vehicleId, name: vehicle ? vehicle.name : vehicleId }
}))

function removeVehicle(vehicleId) {
  emit('update:starterVehicles', props.starterVehicles.filter(id => id !== vehicleId))
}
</script>
