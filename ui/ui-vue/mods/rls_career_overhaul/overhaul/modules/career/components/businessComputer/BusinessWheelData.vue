<template>
  <!-- live wheel alignment readout: Style Guide caption header, hairline lines, tabular numbers -->
  <table v-if="orderedData && orderedData.length > 0" class="awd-table rls-house">
    <thead>
      <tr>
        <th>Wheel</th>
        <th>Camber</th>
        <th>Toe</th>
        <th>Caster</th>
        <th>SAI</th>
      </tr>
    </thead>
    <tbody>
      <tr v-for="w in orderedData" :key="w.name">
        <td class="data-name">{{ w.name }}</td>
        <td>{{ format(w.camber) }}</td>
        <td>{{ format(w.toe) }}</td>
        <td>{{ format(w.caster) }}</td>
        <td>{{ format(w.sai) }}</td>
      </tr>
    </tbody>
  </table>
  <div v-else class="no-data rls-house">
    <p class="hint">No wheel data available</p>
  </div>
</template>

<script setup>
import { safeLua } from "../../utils/safeLua.js"

import { ref, computed, watch, onMounted, onBeforeUnmount } from "vue"
import { lua } from "@/bridge"
import { useEvents } from "@/services/events"

const props = defineProps({
  businessId: {
    type: String,
    default: null
  },
  vehicleId: {
    type: String,
    default: null
  }
})

const events = useEvents()
const data = ref([])

const hasData = computed(() => Array.isArray(data.value) && data.value.length > 0)
const orderedData = computed(() => {
  if (!Array.isArray(data.value)) return []
  return data.value.slice().sort((a, b) => a.name.toLowerCase().localeCompare(b.name.toLowerCase()))
})

const format = (value) => (value ? parseFloat(value).toFixed(3) : "")

const handleWheelData = (hookData) => {
  if (hookData && hookData.success && hookData.businessId === props.businessId && String(hookData.vehicleId) === String(props.vehicleId)) {
    if (hookData.wheelData && Array.isArray(hookData.wheelData) && hookData.wheelData.length > 0) {
      data.value = hookData.wheelData
    }
  }
}

const loadExtension = () => {
  if (!props.businessId || !props.vehicleId) {
    return
  }

  safeLua(() => lua.overhaul_career_business_computer.loadWheelDataExtension(props.businessId, props.vehicleId), "BusinessWheelData: loadExtension")
}

const unloadExtension = () => {
  if (!props.businessId || !props.vehicleId) {
    return
  }

  safeLua(() => lua.overhaul_career_business_computer.unloadWheelDataExtension(props.businessId, props.vehicleId), "BusinessWheelData: unloadExtension")
}

watch(() => [props.businessId, props.vehicleId], (newValues, oldValues) => {
  const [newBusinessId, newVehicleId] = newValues || []
  const [oldBusinessId, oldVehicleId] = oldValues || []

  if (oldBusinessId && oldVehicleId && (oldBusinessId !== newBusinessId || oldVehicleId !== newVehicleId)) {
    unloadExtension()
    data.value = []
  }

  if (newBusinessId && newVehicleId) {
    loadExtension()
  } else {
    data.value = []
  }
}, { immediate: true })

onMounted(() => {
  events.on('businessComputer:onVehicleWheelData', handleWheelData)
  if (props.businessId && props.vehicleId) {
    loadExtension()
  }
})

onBeforeUnmount(() => {
  events.off('businessComputer:onVehicleWheelData', handleWheelData)
  unloadExtension()
})

const reloadExtension = () => {
  if (props.businessId && props.vehicleId) {
    loadExtension()
  }
}

defineExpose({
  reloadExtension
})
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

// Style Guide readout: caption header, hairline lines, muted tabular values, wheel names brightest.
.awd-table {
  width: 100%;
  border-collapse: collapse;
  color: #fff;
  font-variant-numeric: tabular-nums;

  th {
    padding: 0.2em 0.6em 0.45em;
    border-bottom: 1px solid var(--line);
    color: var(--faint);
    font-size: 0.72em;
    font-weight: 700;
    letter-spacing: 0.06em;
    text-align: right;
    text-transform: uppercase;
    white-space: nowrap;
    &:first-child {
      padding-left: 0.15em;
      text-align: left;
    }
  }

  td {
    padding: 0.5em 0.6em 0.38em;
    border-bottom: 1px solid var(--line);
    color: var(--muted);
    font-size: 0.92em;
    font-weight: 600;
    text-align: right;
    white-space: nowrap;
    &.data-name {
      padding-left: 0.15em;
      color: #fff;
      font-weight: 700;
      text-align: left;
      white-space: normal;
      overflow-wrap: anywhere;
    }
  }

  tbody tr:last-child td {
    border-bottom: 0;
  }
}

.no-data {
  padding: 0.8em 0.15em;
  text-align: center;
}
</style>
