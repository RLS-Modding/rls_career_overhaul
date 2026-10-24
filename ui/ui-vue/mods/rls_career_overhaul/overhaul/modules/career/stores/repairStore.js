// This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
// If a copy of the bCDDL was not distributed with this
// file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

import { computed, inject, ref } from "vue"
import { defineStore } from "pinia"
import { lua } from "@/bridge"

export const useRepairStore = defineStore("overhaulRepair", () => {
  // States
  const repairOptions = ref({})
  const vehicleData = ref({})
  const playerAttributes = ref({})
  const driverScoreTierData = ref({})
  const futureDriverScore = ref(0)
  const driverScore = ref(0)

  let repairRequestGeneration = 0

  const resetStore = () => {
    repairRequestGeneration += 1
    repairOptions.value = {}
    vehicleData.value = {}
    playerAttributes.value = {}
    driverScoreTierData.value = {}
    futureDriverScore.value = 0
    driverScore.value = 0
  }

  const getRepairData = () => {
    resetStore()
    const requestGeneration = repairRequestGeneration
    lua.overhaul_career_repair_repairScreen.getRepairData().then(data => {
      if (data == null) {
        // An old unavailable reply must not close a newer menu or an unmounted view.
        if (requestGeneration === repairRequestGeneration) lua.overhaul_career_repair_repairScreen.closeMenu()
        return
      }
      repairOptions.value = data.repairOptions
      vehicleData.value = data.vehicleData
      playerAttributes.value = data.playerAttributes
      driverScoreTierData.value = data.driverScoreTierData
      futureDriverScore.value = data.futureDriverScore
      driverScore.value = data.driverScore
    })
  }

  return {
    repairOptions,
    vehicleData,
    playerAttributes,
    getRepairData,
    driverScoreTierData,
    futureDriverScore,
    driverScore,
    resetStore,
  }
})
