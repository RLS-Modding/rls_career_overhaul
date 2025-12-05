<template>
  <table class="awd-table" v-if="orderedData && orderedData.length > 0">
    <thead>
      <tr>
        <th>Name</th>
        <th>Camber</th>
        <th>Toe</th>
        <th>Caster</th>
        <th>SAI</th>
      </tr>
    </thead>
    <tr v-for="w in orderedData" :key="w.name">
      <td class="data-name">{{ w.name }}</td>
      <td>{{ format(w.camber) }}</td>
      <td>{{ format(w.toe) }}</td>
      <td>{{ format(w.caster) }}</td>
      <td>{{ format(w.sai) }}</td>
    </tr>
  </table>
  <div v-else class="no-data">
    <p>No wheel data available</p>
  </div>
</template>

<script setup>
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
  return data.value.sort((a, b) => a.name.toLowerCase().localeCompare(b.name.toLowerCase()))
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

  try {
    lua.career_modules_business_businessComputer.loadWheelDataExtension(props.businessId, props.vehicleId)
  } catch (error) {
  }
}

const unloadExtension = () => {
  if (!props.businessId || !props.vehicleId) {
    return
  }

  try {
    lua.career_modules_business_businessComputer.unloadWheelDataExtension(props.businessId, props.vehicleId)
  } catch (error) {
  }
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
.awd-table {
  width: 100%;
  border-collapse: collapse;
  font-size: 0.8125em;
  color: #ffffff !important;

  thead>tr {
    th {
      text-align: left;
      padding: 0.5em 0.75em;
      color: #ffffff !important;
      font-weight: 600;
      font-size: 0.75em;
      text-transform: uppercase;

      &:first-child {
        text-align: center;
      }
    }
  }

  tbody tr {
    td {
      padding: 0.5em 0.75em;
      color: #ffffff !important;
      text-align: left;

      &.data-name {
        font-weight: 500;
        text-align: center;
        color: #ffffff !important;
      }
    }
  }
}

.no-data {
  padding: 1em;
  text-align: center;
  color: #ffffff !important;
  font-size: 0.875em;

  p {
    color: #ffffff !important;
  }
}
</style>
