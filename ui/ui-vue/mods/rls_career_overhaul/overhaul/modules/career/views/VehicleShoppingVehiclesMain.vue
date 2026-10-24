<template>
  <ComputerWrapper
    :path="[sellerName]"
    :title="$translate.instant('ui.career.vehicleShopping.availableVehicles')"
    back
    @back="close"
  >
    <template #status>
      <span class="status-note">Free slots <b>{{ store.vehicleShoppingData.numberOfFreeSlots || 0 }}</b></span>
    </template>

    <div
      v-bng-scoped-nav="{ scopeId: 'vehicle-shopping-vehicles', activateOnMount: true, preferAutoFocus: true, canDeactivate: listBack }"
      class="vehicles-screen"
    >
      <VehicleList v-if="loaded" />
      <div v-else class="loading-card rls-house" v-bng-blur="1">
        <span class="hint">Please wait...</span>
      </div>
    </div>
  </ComputerWrapper>
</template>

<script setup>
import { $translate } from "@/services/translation"
import { useRouteReady } from "@/services/routeReadiness"
import { useScopedNav } from "@/services/scopedNav/api"
import { computed, nextTick, onMounted, onUnmounted, watch } from "vue"
import { lua } from "@/bridge"
import { useRoute } from "vue-router"
import { vBngBlur, vBngScopedNav } from "@/common/directives"
import ComputerWrapper from "./ComputerWrapper.vue"
import VehicleList from "../components/vehicleShopping/VehicleList.vue"
import { useVehicleShoppingStore } from "../stores/vehicleShoppingStore"
import { closeShopDetail } from "../components/vehicleShopping/useShopVehicle"

const store = useVehicleShoppingStore()
const route = useRoute()
const loaded = computed(() => Object.keys(store.vehicleShoppingData || {}).length > 0)
const sellerName = computed(() => {
  if (store.vehicleShoppingData.currentSellerNiceName) return store.vehicleShoppingData.currentSellerNiceName
  const id = store.vehicleShoppingData.selectedSellerId || store.selectedSellerId
  const seller = (store.vehicleShoppingData.dealerships || []).find(item => String(item.id) === String(id))
  return seller?.name || "Buy Vehicles"
})

const close = () => {
  // Back on the detail page returns to the list first
  if (closeShopDetail()) return
  lua.extensions.ui_router.back()
}
// B inside the active scope runs the same back (detail page first) instead of only deactivating the
// scope, which skipped closeShopDetail and left the shop from the detail page
const listBack = () => {
  close()
  return false
}

useRouteReady({
  onReady: () => useScopedNav().activateScope('vehicle-shopping-vehicles'),
  async waitUntilReady() {
    if (!loaded.value) {
      await new Promise(resolve => {
        const stop = watch(loaded, ready => {
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

onMounted(async () => {
  await store.requestVehicleShoppingData()
  const sellerId = store.vehicleShoppingData.currentSeller || store.vehicleShoppingData.selectedSellerId
  store.setSelectedSellerId(sellerId || "")
})
const SHOPPING_ROUTE_FAMILY = "overhaul.computer.vehicleShopping"
const isLeavingShoppingFamily = () => {
  const name = route.name
  return !(name === SHOPPING_ROUTE_FAMILY || (typeof name === "string" && name.startsWith(SHOPPING_ROUTE_FAMILY + ".")))
}

onUnmounted(async () => {
  if (!isLeavingShoppingFamily()) return
  await lua.overhaul_career_market_vehicleShopping.onShoppingMenuClosed()
  store.$dispose()
})

</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

/* career status chip add-on: short and faint */
.status-note {
  color: rgba(255, 255, 255, 0.55);
  font-size: 0.88em;
  font-weight: 600;
  b {
    margin-left: 0.2em;
    color: rgba(255, 255, 255, 0.85);
    font-weight: 700;
    font-variant-numeric: tabular-nums;
  }
}

.vehicles-screen {
  display: flex;
  flex-direction: column;
  height: 100%;
  min-height: 0;
  max-width: 80rem;
}

.loading-card.rls-house {
  align-self: flex-start;
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  padding: 1.1em 1.3em 0.95em;
  border-radius: var(--radius-control);
  background: rgba(21, 21, 23, 0.92);
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06), 0 14px 40px rgba(0, 0, 0, 0.45);
  .hint {
    font-size: 0.95em;
  }
}
</style>
