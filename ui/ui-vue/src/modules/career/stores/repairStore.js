import { computed, inject, ref } from "vue"
import { defineStore } from "pinia"
import { lua } from "@/bridge"

export const useRepairStore = defineStore("repair", () => {
  // States
  const vehicle = ref({})
  const policyInfo = ref({})
  const baseDeductible = ref({})
  const playerAttributes = ref({})
  const policyScoreInfluence = ref(0)
  const repairOptions = ref({})

  const getRepairData = () => {
    lua.career_modules_insurance.getRepairData().then(data => {
      playerAttributes.value = data.playerAttributes
      vehicle.value = data.vehicle
      policyScoreInfluence.value = data.policyScoreInfluence
      baseDeductible.value = data.baseDeductible
      policyInfo.value = data.policyInfo
      repairOptions.value = data.repairOptions
    })
  }

  return {
    playerAttributes,
    repairOptions,
    vehicle,
    policyInfo,
    baseDeductible,
    getRepairData,
    policyScoreInfluence,
  }
})
