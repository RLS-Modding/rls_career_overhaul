<template>
  <VehicleList v-bind="attrs" />
</template>

<script setup>
import { lua } from "@/bridge"
import { onBeforeMount, onUnmounted, useAttrs } from "vue"
import { useVehicleInventoryStore } from "../../stores/vehicleInventoryStore"
import VehicleList from "./VehicleList.vue"

const vehicleInventoryStore = useVehicleInventoryStore()

const attrs = useAttrs()
defineOptions({ inheritAttrs: false })

defineExpose({
  closeMenu: vehicleInventoryStore.closeMenu,
})

onBeforeMount(() => {
  vehicleInventoryStore.requestInitialData()
})

onUnmounted(() => {
  lua.extensions.hook("onExitVehicleInventory")
  vehicleInventoryStore.menuClosed()
  vehicleInventoryStore.$dispose()
})
</script>
