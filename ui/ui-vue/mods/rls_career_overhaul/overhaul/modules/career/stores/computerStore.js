// This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
// If a copy of the bCDDL was not distributed with this
// file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
// RLS modifications: Copyright (C) RLS Modding

import { computed, ref } from "vue"
import { defineStore } from "pinia"
import { lua, useBridge } from "@/bridge"

const { events } = useBridge()
let computerUiDataListenerBound = false

export const useComputerStore = defineStore("overhaulComputer", () => {
  // States
  const computerData = ref({})
  const activeVehicleIndex = ref(0)

  const activeInventoryId = computed(() => {
    if (computerData.value.vehicles && computerData.value.vehicles[activeVehicleIndex.value]) {
      return computerData.value.vehicles[activeVehicleIndex.value].inventoryId
    }
    return "0"
  })

  const generalComputerFunctions = computed(() => {
    if (!computerData.value.computerFunctions) return []
    let result = []
    result = Object.values(computerData.value.computerFunctions.general)
    result.sort((a, b) =>  {
      if (a.order != undefined && b.order != undefined) return (a.order < b.order ? -1 : 1)
      return (a.label < b.label ? -1 : 1)
    })
    return result
  })

  const vehicleSpecificComputerFunctions = computed(() => {
    if (!computerData.value.computerFunctions) return {}
    let result = {}
    for (const [inventoryId, computerFunctions] of Object.entries(computerData.value.computerFunctions.vehicleSpecific)) {
      let sortedFunctions = Object.values(computerFunctions)
      sortedFunctions.sort((a, b) =>  {
        if (a.order != undefined && b.order != undefined) return (a.order < b.order ? -1 : 1)
        return (a.label < b.label ? -1 : 1)
      })
      result[inventoryId] = sortedFunctions
    }
    return result
  })

  const activityComputerFunctions = computed(() => [])

  const setComputerData = data => {
    computerData.value = data || {}
    if ((computerData.value.vehicles && computerData.value.vehicles.length <= activeVehicleIndex.value) || computerData.value.resetActiveVehicleIndex) {
      activeVehicleIndex.value = 0
    }
  }

  // Actions
  const requestComputerData = () => {
    lua.overhaul_career_garage_computer.getComputerUIData().then(setComputerData)
  }

  const computerButtonCallback = async (computerFunctionId, inventoryId) => {
    // First check if it's an activity function
    const activityFunction = activityComputerFunctions.value.find(f => f.id === computerFunctionId)
    if (activityFunction) {
      await activityFunction.callback()
      return
    }

    // If not an activity, use the regular computer callback
    await lua.overhaul_career_garage_computer.computerButtonCallback(computerFunctionId, inventoryId ? Number(inventoryId) : undefined)
  }

  const onMenuClosed = () => {
    lua.overhaul_career_garage_computer.onMenuClosed()
  }

  const switchActiveVehicle = offset => {
    if (!computerData.value.vehicles || computerData.value.vehicles.length === 0) return
    activeVehicleIndex.value = (activeVehicleIndex.value + offset + computerData.value.vehicles.length) % computerData.value.vehicles.length
  }

  // Bind once so ComputerMain $dispose does not stack duplicate listeners.
  if (!computerUiDataListenerBound) {
    computerUiDataListenerBound = true
    events.on("computerUIData", data => {
      useComputerStore().setComputerData(data)
    })
  }

  return {
    activeVehicleIndex,
    activeInventoryId,
    computerData,
    generalComputerFunctions,
    vehicleSpecificComputerFunctions,
    activityComputerFunctions,
    setComputerData,
    requestComputerData,
    computerButtonCallback,
    switchActiveVehicle,
    onMenuClosed,
  }
})
