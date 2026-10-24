<template>
  <ComputerWrapper ref="wrapper" :path="[$translate.instant('ui.career.shared.pathPartInventory')]" :title="$translate.instant('ui.career.shared.pathPartInventory')" back @back="close">
    <PartList class="part-inventory" @partSold="updateCareerStatus" />

    <!-- Tabs are shown in infobar because they are tracked events by crossfire.
     This is a hack to prevent them from displaying in the infobar -->
    <BngBinding v-show="false" ui-event="tab_l" controller />
    <BngBinding v-show="false" ui-event="tab_r" controller />
  </ComputerWrapper>
</template>

<script setup>
import { computed, onUnmounted, ref, watch, markRaw, nextTick } from "vue"
import { BngBinding } from "@/common/components/base"

import { $translate } from "@/services/translation"
import { useRoute } from "vue-router"
import { activateRouteTargetScope } from "@/services/scopedNav/api"
import { useRouteReady } from "@/services/routeReadiness"
import { lua } from "@/bridge"
import { usePartInventoryStore } from "../stores/partInventoryStore"

import ComputerWrapper from "./ComputerWrapper.vue"
import PartList from "../components/partInventory/PartList.vue"
import PartInventoryAddedParts from "../components/partInventory/PartInventoryAddedParts.vue"
import { openHouseMessage } from "../components/house/index.js"

const wrapper = ref()

const partInventoryStore = usePartInventoryStore()
// Pinia retains state after $dispose; a new visit must wait for fresh data.
partInventoryStore.partInventoryData = {}

const route = useRoute()

// display repair popup when required
watch(
  () => partInventoryStore.newPartsPopupOpen,
  (newVal, oldVal) => newVal && confirmAddedParts()
)

const confirmAddedParts = async vehicle => {
  await openHouseMessage("", { component: markRaw(PartInventoryAddedParts), props: { parts: partInventoryStore.newParts } })
  closeNewPartsPopup()
}

const updateCareerStatus = () => {
  wrapper.value.statusUpdate()
}

// Acknowledge the shell without waiting for data. Request the inventory only
// after the finalized route has had a paint opportunity: rAF callbacks run
// before paint, so one callback alone can start expensive Lua work too early.
const isInventoryReady = computed(() => !!partInventoryStore.partInventoryData?.partList)
let disposed = false

async function requestInventoryAfterPaint() {
  await nextTick()
  if (typeof window !== "undefined" && typeof window.requestAnimationFrame === "function") {
    await new Promise(resolve => window.requestAnimationFrame(() => window.requestAnimationFrame(resolve)))
  }
  if (!disposed) lua.overhaul_career_parts_partInventory.requestUIData()
}

// Set once the current transition has been finalized (ack succeeded). Scope
// activation may only run after this point.
let acknowledged = false
let scopeActivationRequestId = 0

// Once the list data is present and rendered, activate the route's target scope
// so autofocus lands on a real list entry. Only runs after the shell ack.
async function activateInventoryScopeWhenReady() {
  if (!acknowledged) return
  if (!isInventoryReady.value) return

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
    // The transition finalized; paint the waiting shell before asking Lua to
    // refresh vehicle conditions and build the parts payload.
    acknowledged = true
    requestInventoryAfterPaint()
    activateInventoryScopeWhenReady()
  },
})

watch(isInventoryReady, ready => {
  if (ready) activateInventoryScopeWhenReady()
})

const kill = () => {
  disposed = true
  partInventoryStore.partInventoryClosed()
  partInventoryStore.$dispose()
}

onUnmounted(kill)

const close = () => {
  partInventoryStore.closeMenu()
}

const closeNewPartsPopup = () => {
  partInventoryStore.closeNewPartsPopup()
}
</script>

<style scoped lang="scss">
.partListCard {
  width: 50%;
  overflow-y: hidden;
  height: 100vh;
  padding: 10px;
  color: white;
  background-color: rgba(0, 0, 0, 0.9);
  & :deep(.card-cnt) {
    background-color: rgba(0, 0, 0, 0.2);
  }
}

.innerList {
  height: 95vh;
  overflow-y: scroll;
  padding: 20px;
}

// RLS override: same as vanilla apart from sizing. The list card (PartList, also overridden) carries
// the house look and an em font-size that follows the viewport, so the minimum width scales with it.
.part-inventory {
  width: 60%;
  min-width: min(40em, 100%);
  max-width: 100%;
  height: 100%;
  min-height: 0;
  :deep(.list-content) {
    min-height: 40vh;
  }
}
</style>
