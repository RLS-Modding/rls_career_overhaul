<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <!--
    .39 boots Vue from ui-vue/dist, so mod App.vue overlays never mount.
    This host is mounted by mods/rls_career_overhaul/index.js into the live app context.
  -->
  <template v-for="overlay in overlays" :key="overlay.id">
    <LazyOverlay v-if="overlay.mountOn" :overlay="overlay" />
    <component v-else :is="overlay.component" />
  </template>
</template>

<script setup>
import { onMounted, onBeforeUnmount, watch } from "vue"
import { useRoute } from "vue-router"
import { useNavScrollAcceleration } from "./overhaul/modules/career/composables/useNavScrollAcceleration.js"
import { useGameplayPopups } from "../../../modModules/overhaulFreeroamRaceHud/useGameplayPopups.js"
import LazyOverlay from "./LazyOverlay.vue"
import { coreOverlays } from "./overhaul/modules/career/utils/coreUiRoutes"
import { useCardGamesPrompt } from "./overhaul/modules/career/composables/useCardGamesPrompt.js"
import { useZoneVehiclePicker } from "./overhaul/modules/career/composables/useZoneVehiclePicker.js"

// The global confirmation hook must not pull the house controls into UI boot.
const openHouseConfirmation = async (...args) => {
  const house = await import("./overhaul/modules/career/components/house/index.js")
  return house.openHouseConfirmation(...args)
}

// Order and activation events come from gameplay/overhaul/ui/coreUi.json.
const overlays = coreOverlays()

let previousHouseConfirmation
onMounted(() => {
  previousHouseConfirmation = window.bngVue.openHouseConfirmation
  window.bngVue.openHouseConfirmation = openHouseConfirmation
})
onBeforeUnmount(() => {
  if (window.bngVue.openHouseConfirmation !== openHouseConfirmation) return
  if (previousHouseConfirmation === undefined) delete window.bngVue.openHouseConfirmation
  else window.bngVue.openHouseConfirmation = previousHouseConfirmation
})

// This host is always mounted while the mod is loaded, so it owns the global right-stick scroll ramp.
useNavScrollAcceleration()
useCardGamesPrompt()
useZoneVehiclePicker()
useGameplayPopups()
const route = useRoute()
watch(() => route.path, path => {
  document.body.classList.toggle("overhaul-controller-ui", path.startsWith("/overhaul"))
}, { immediate: true })
onBeforeUnmount(() => document.body.classList.remove("overhaul-controller-ui"))
</script>

<style lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/overhaulFocus.scss";
</style>
