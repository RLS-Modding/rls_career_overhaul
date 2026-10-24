<template>
  <ComputerWrapper :title="title" back @back="close">
    <VehicleList class="vehicle-inventory" />
  </ComputerWrapper>
</template>

<script setup>
import { computed, watch, nextTick, onBeforeMount, onUnmounted } from "vue"
import ComputerWrapper from "./ComputerWrapper.vue"
import { useVehicleInventoryStore } from "../stores/vehicleInventoryStore"
import { ACCENTS } from "@/common/components/base"
import VehicleList from "../components/vehicleInventory/VehicleList.vue"
import { openConfirmation } from "@/services/popup"
import { $translate } from "@/services/translation"
import { lua } from "@/bridge"
import { useRouteReady } from "@/services/routeReadiness"

const vehicleInventoryStore = useVehicleInventoryStore()
const title = computed(() => vehicleInventoryStore.vehicleInventoryData.header || $translate.instant("ui.career.shared.myVehicles"))

const isInventoryReady = computed(() => !!vehicleInventoryStore.vehicleInventoryData?.vehicles)

useRouteReady({
  async waitUntilReady() {
    if (!isInventoryReady.value) {
      await new Promise(resolve => {
        const stop = watch(isInventoryReady, ready => {
          if (!ready) return
          stop()
          resolve()
        })
      })
    }
    await nextTick()
    if (typeof window !== "undefined" && typeof window.requestAnimationFrame === "function") {
      await new Promise(resolve => window.requestAnimationFrame(() => resolve()))
    }
  },
})

// display repair popup when required
watch(
  () => vehicleInventoryStore.vehIdToChooseAfterRepairPopup,
  (newId, oldId) => {
    !oldId && newId && confirmRepair()
  }
)

const confirmRepair = async vehicle => {
  const res = await openConfirmation("", $translate.instant("ui.career.shared.repairPreviousVehicleQuestion"), [
    { label: $translate.instant("ui.common.no"), value: false, extras: { cancel: true, outsideCancel: false, accent: ACCENTS.secondary } },
    { label: $translate.instant("ui.common.yes"), value: true, extras: { confirm: true } },
  ], "", false)
  if (res) {
    vehicleInventoryStore.repairPopupAccept()
  } else {
    vehicleInventoryStore.repairPopupDecline()
  }
}

const close = () => lua.extensions.ui_router.back()

onBeforeMount(() => {
  vehicleInventoryStore.requestInitialData()
})

onUnmounted(() => {
  lua.extensions.hook("onExitVehicleInventory")
  vehicleInventoryStore.menuClosed()
  vehicleInventoryStore.$dispose()
})
</script>

<style scoped lang="scss">
.vehicle-inventory {
  max-width: 60rem;
  height: 100%;
}
</style>
