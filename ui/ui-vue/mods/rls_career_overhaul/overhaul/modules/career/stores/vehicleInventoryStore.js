// This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
// If a copy of the bCDDL was not distributed with this
// file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
// RLS modifications: Copyright (C) RLS Modding

import { onScopeDispose, computed, ref } from "vue"
import { defineStore } from "pinia"
import { lua, useBridge } from "@/bridge"

export const useVehicleInventoryStore = defineStore("overhaulVehicleInventory", () => {
  const { events } = useBridge()

  // *** There seems to be something wrong below - data.currentVehicleId always seems to be undefined ***
  // ****************************************************************************************************

  // States
  let vehicleInventoryData = ref({})
  let vehIdToChooseAfterRepairPopup = ref(0)

  const filteredVehicles = computed(() => {
    const data = vehicleInventoryData.value
    if (!data.vehicles) return []
    const vehicles = Object.values(data.vehicles)
    return vehicles
  })

  const nowMs = ref(Date.now())
  let countdownTimer
  const pendingExpiries = new Map()

  // Actions
  function requestInitialData() {
    lua.overhaul_career_garage_inventory.sendDataToUi()
  }

  function closeMenu() {
    lua.overhaul_career_garage_inventory.closeMenu()
  }

  const getExpediteRepairCost = vehicle => {
    return Math.max(vehicle.quickRepairExtraPrice * (vehicle.timeToAccess / vehicle.initialRepairTime), 50)
  }

  function countDownVehicleDelays() {
    countdownTimer = undefined
    nowMs.value = Date.now()
    let expired = false
    for (const [id, expiresAt] of pendingExpiries) {
      if (expiresAt > nowMs.value) continue
      pendingExpiries.delete(id)
      expired = true
    }
    // One authoritative update covers all vehicles that became available together.
    if (expired) lua.overhaul_career_garage_inventory.sendVehicleUpdatesToUi()
    if (pendingExpiries.size) countdownTimer = setTimeout(countDownVehicleDelays, 1000)
  }

  function handleVehicleInventoryData(data) {
    clearTimeout(countdownTimer)
    countdownTimer = undefined
    if (!data.isUpdate) pendingExpiries.clear()
    nowMs.value = Date.now()
    const vehicles = data.isUpdate ? { ...vehicleInventoryData.value.vehicles } : {}
    for (const id of Object.values(data.removedVehicleIds || {})) {
      delete vehicles[id]
      pendingExpiries.delete(String(id))
    }
    for (const [id, vehicle] of Object.entries(data.vehicles)) {
      pendingExpiries.delete(id)
      const view = { ...vehicle, isCurrentVehicle: data.currentVehicleId === vehicle.id }
      if (vehicle.timeToAccess > 0) {
        const expiresAt = nowMs.value + vehicle.timeToAccess * 1000
        pendingExpiries.set(id, expiresAt)
        Object.defineProperty(view, "timeToAccess", {
          enumerable: true,
          get: () => Math.max(0, Math.ceil((expiresAt - nowMs.value) / 1000)),
        })
        if (vehicle.delayReason === "repair") {
          Object.defineProperty(view, "expediteRepairCost", {
            enumerable: true,
            get: () => getExpediteRepairCost(view),
          })
        }
      }
      vehicles[id] = view
    }
    vehicleInventoryData.value = { ...data, vehicles }
    vehIdToChooseAfterRepairPopup.value = 0
    if (pendingExpiries.size) countdownTimer = setTimeout(countDownVehicleDelays, 1000)
  }
  events.on("vehicleInventoryData", handleVehicleInventoryData)

  function menuClosed() {
    clearTimeout(countdownTimer)
    countdownTimer = undefined
    pendingExpiries.clear()
  }

  function repairPopupAccept() {
    lua.overhaul_career_garage_inventory.chooseVehicleFromMenu(vehIdToChooseAfterRepairPopup.value, 1, true)
    vehIdToChooseAfterRepairPopup.value = 0
  }

  function repairPopupDecline() {
    lua.overhaul_career_garage_inventory.chooseVehicleFromMenu(vehIdToChooseAfterRepairPopup.value, 1, false)
    vehIdToChooseAfterRepairPopup.value = 0
  }

  function chooseVehicle(vehId, buttonIndex) {
    let showRepairPopup = false
    const data = vehicleInventoryData.value
    if (data.currentVehicleId !== undefined && vehId !== data.currentVehicleId) {
      showRepairPopup = data.vehicles[data.currentVehicleId].needsRepair
    }
    if (showRepairPopup) {
      vehIdToChooseAfterRepairPopup.value = vehId
      return
    }
    lua.overhaul_career_garage_inventory.chooseVehicleFromMenu(vehId, buttonIndex + 1, false)
  }

  function dispose() {
    menuClosed()
    events.off("vehicleInventoryData", handleVehicleInventoryData)
  }

  onScopeDispose(dispose)

  return {
    filteredVehicles,
    vehIdToChooseAfterRepairPopup,
    vehicleInventoryData,
    requestInitialData,
    chooseVehicle,
    repairPopupAccept,
    repairPopupDecline,
    menuClosed,
    closeMenu,
    dispose,
  }
})
