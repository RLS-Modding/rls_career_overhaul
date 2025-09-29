<template>
  <ComputerWrapper ref="wrapper" :path="['My Computer']" :title="title" back @back="close">
    <VehicleInventory ref="elInventory" class="vehicle-inventory" />
  </ComputerWrapper>
</template>

<script setup>
import { ref, computed, watch, onUnmounted } from "vue"
import ComputerWrapper from "./ComputerWrapper.vue"
import { useVehicleInventoryStore } from "../stores/vehicleInventoryStore"
import { BngSwitch, ACCENTS } from "@/common/components/base"
import VehicleInventory from "../components/vehicleInventory/VehicleInventory.vue"
import { openConfirmation } from "@/services/popup"
import { $translate } from "@/services/translation"

const vehicleInventoryStore = useVehicleInventoryStore()

const title = computed(() => vehicleInventoryStore.vehicleInventoryData.header || "My vehicles")

// display repair popup when required
watch(
  () => vehicleInventoryStore.vehIdToChooseAfterRepairPopup,
  (newId, oldId) => {
    !oldId && newId && confirmRepair()
  }
)

const confirmRepair = async vehicle => {
  const res = await openConfirmation("", "Do you want to repair your previous vehicle?", [
    { label: $translate.instant("ui.common.yes"), value: true, extras: { default: true } },
    { label: $translate.instant("ui.common.no"), value: false, extras: { accent: ACCENTS.secondary } },
  ])
  if (res) {
    vehicleInventoryStore.repairPopupAccept()
  } else {
    vehicleInventoryStore.repairPopupDecline()
  }
}

const elInventory = ref()

const close = () => elInventory.value.closeMenu()

const kill = () => {
  vehicleInventoryStore.$dispose()
}

onUnmounted(kill)
</script>

<style scoped lang="scss">
.vehicle-inventory {
  width: 60%;
  min-width: 40rem;
  max-width: 60rem;
  height: 50%;
  min-height: 50%;
  height: max-content;
  // comment-out the following two lines (max-height and margin-top) if we aren't using list toolbar
  max-height: 100% !important;
  margin-top: -3em;
  :deep(.list-content) {
    min-height: 60vh;
  }
}
</style>
