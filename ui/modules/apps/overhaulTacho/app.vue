<template>
  <div ref="containerRef" class="tacho-container" :style="{ opacity: visible ? 1 : 0 }">
    <tacho ref="tachoRef"></tacho>
  </div>
</template>

<script setup>
import { ref, onMounted, onUnmounted } from "vue"
import { useEvents, useStreams } from "@/services/events"
import { useBridge } from "@/bridge"
import tacho from "../Tacho2/tacho.vue"

const events = useEvents()
const { lua, api } = useBridge()

const HIDE_DELAY = 500 // ms
const containerRef = ref(null)
const tachoRef = ref(null)
const visible = ref(false)
let hideTimer = null
let passengerMode = false
let presenceRequest = 0

// the stock tacho plays the low fuel sound only in vanilla career
let isOverhaul = false
let wasFuelLow = true
let shouldPlayFuelLowSound = false
let lowFuelSoundPlayed = false

function clearHideTimer() {
  if (!hideTimer) return
  clearTimeout(hideTimer)
  hideTimer = null
}

function show() {
  clearHideTimer()
  if (passengerMode) return
  if (!visible.value) visible.value = true
}

function setPassengerMode(value) {
  passengerMode = value === true
  if (passengerMode) {
    clearHideTimer()
    visible.value = false
  }
}

function refreshPresence() {
  const request = ++presenceRequest
  api.engineLua("gameplay_seatOccupants and gameplay_seatOccupants.getPlayerPresence(0)", presence => {
    if (request === presenceRequest) setPassengerMode(presence?.permissionMode === "passenger")
  })
}

function vehicleChanged() {
  tachoRef.value?.vehicleChanged()
  refreshPresence()
}

function hide() {
  if (!visible.value || hideTimer) return
  hideTimer = setTimeout(() => {
    visible.value = false
    hideTimer = null
  }, HIDE_DELAY)
}

// The stock tacho's fuel icon is a static node of its template: look it up once per mount instead
// of searching the SVG on every stream tick; look again only if it was replaced.
let fuelIcon = null
function findFuelIcon() {
  if (!fuelIcon?.isConnected) fuelIcon = containerRef.value?.querySelector("#ico_fuel_on") ?? null
  return fuelIcon
}

function updateFuelWarning(electrics) {
  const icon = findFuelIcon()
  const fuelLow = icon?.style.visibility === "visible"
  const fuelGoneLow = !wasFuelLow && fuelLow
  wasFuelLow = fuelLow
  if (electrics?.ignition && isOverhaul && fuelGoneLow && !shouldPlayFuelLowSound) setTimeout(() => (shouldPlayFuelLowSound = true), 0)
  if (shouldPlayFuelLowSound && !lowFuelSoundPlayed) {
    lowFuelSoundPlayed = true
    lua.ui_audio.playEventSound("bng_career_fuel", "low_fuel")
  }
}

onMounted(() => {
  events.on("VehicleChange", vehicleChanged)
  events.on("VehicleFocusChanged", data => data.mode === true && vehicleChanged())
  events.on("OverhaulPassengerMode", value => {
    ++presenceRequest
    setPassengerMode(value)
  })
  refreshPresence()
  api.engineLua("overhaul_shell_gameMode ~= nil and overhaul_shell_gameMode.isActive() == true", active => (isOverhaul = active === true))
})

onUnmounted(() => {
  ++presenceRequest
  clearHideTimer()
})

useStreams(["electrics", "engineInfo"], streams => {
  if (!tachoRef.value) return
  if (passengerMode) return
  if (tachoRef.value.update(streams)) {
    updateFuelWarning(streams.electrics)
    show()
  } else {
    hide()
  }
})

</script>

<style lang="css" scoped>
.tacho-container {
  width: 100%;
  height: 100%;
  transition: opacity 200ms ease-in-out;
}
</style>
