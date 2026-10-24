<!-- RLS override of the vanilla Performance Index screen: same script, the tile is centered on a
     house-styled page whose font-size follows the viewport height (everything inside is em). -->
<template>
  <ComputerWrapper :title="title" @back="close">
    <div class="rls-house perf-page">
      <VehiclePerformanceTile :vehicle-data="vehicleData" />
    </div>

    <!-- Tabs are shown in infobar because they are tracked events by crossfire.
     This is a hack to prevent them from displaying in the infobar -->
    <BngBinding v-show="false" ui-event="tab_l" controller />
    <BngBinding v-show="false" ui-event="tab_r" controller />
  </ComputerWrapper>
</template>

<script setup>
import { computed, watch, nextTick } from "vue"
import { BngBinding } from "@/common/components/base"
import { useRoute } from "vue-router"
import { lua } from "@/bridge"
import { $translate } from "@/services/translation"
import { useRouteDataStore } from "@/services/routeData"
import { activateRouteTargetScope } from "@/services/scopedNav/api"
import { useRouteReady } from "@/services/routeReadiness"

import VehiclePerformanceTile from "../components/vehiclePerformance/VehiclePerformanceTile.vue"
import ComputerWrapper from "./ComputerWrapper.vue"

const route = useRoute()
const routeDataStore = useRouteDataStore()

const vehicleData = computed(() => routeDataStore.data?.vehicleData || {})

const title = computed(() => vehicleData.value.niceName ? $translate.instant("ui.career.vehiclePerformance.titleWithVehicle", { name: vehicleData.value.niceName }) : "ui.career.vehiclePerformance.title")

const close = () => lua.extensions.ui_router.back()

// The performance payload is produced by Lua `onRouteMount`, which only runs
// after the rendered shell is acked. Gating the ack on the data would deadlock,
// so `waitUntilReady` only waits for the shell and scope activation waits for
// the routeData payload to report mounted-ready.
const isPerformanceReady = computed(() => routeDataStore.routeName === route.name && routeDataStore.status === "mounted-ready")

// Set once the current transition has been finalized (ack succeeded). Scope
// activation may only run after this point.
let acknowledged = false
let scopeActivationRequestId = 0

async function activatePerformanceScopeWhenReady() {
  if (!acknowledged) return
  if (!isPerformanceReady.value) return

  const requestId = ++scopeActivationRequestId
  const routeName = route.name
  const fullPath = route.fullPath
  await nextTick()

  if (typeof window !== "undefined" && typeof window.requestAnimationFrame === "function") {
    await new Promise(resolve => window.requestAnimationFrame(() => resolve()))
  }

  if (requestId !== scopeActivationRequestId) return
  if (route.name !== routeName || route.fullPath !== fullPath) return

  activateRouteTargetScope()
}

useRouteReady({
  async waitUntilReady() {
    await nextTick()
    if (typeof window !== "undefined" && typeof window.requestAnimationFrame === "function") {
      await new Promise(resolve => window.requestAnimationFrame(() => resolve()))
    }
  },
  onReady() {
    // The transition finalized (ack succeeded and `onRouteMount` will run);
    // data may already be present on fast re-entry, so try activating now.
    acknowledged = true
    activatePerformanceScopeWhenReady()
  },
})

watch(isPerformanceReady, ready => {
  if (ready) activatePerformanceScopeWhenReady()
})
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

.perf-page {
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  display: flex;
  /* sits directly under the screen heading, like the other computer screens */
  align-items: flex-start;
  justify-content: flex-start;
  height: 100%;
  min-height: 0;
  overflow-y: auto;
  padding: 0.5em 0;
}
</style>
