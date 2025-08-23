import { ref } from "vue"
import { defineStore } from "pinia"
import { useBridge, lua } from "@/bridge"

export const useInsurancePoliciesStore = defineStore("insurancePolicies", () => {
  const { events } = useBridge()

  // States
  let policiesData = ref([])
  let careerMoney = ref(0)
  let careerVouchers = ref(0)
  let policyHistory = ref([])
  let vehicles = ref([])
  let activePlans = ref([])
  let selectedVehicleId = ref(null)

  // Actions

  function requestInitialData() {
    lua.career_modules_insurance.sendUIData()
  }

  // Lua events
  events.on("insurancePoliciesData", data => {
    if (Array.isArray(data.policiesData)) {
      data.policiesData.sort((a, b) => (a.initialBuyPrice || 0) - (b.initialBuyPrice || 0))
    }
    careerVouchers.value = data.careerVouchers
    policiesData.value = data.policiesData
    careerMoney.value = data.careerMoney
    policyHistory.value = data.policyHistory
    vehicles.value = data.vehicles || []
    activePlans.value = data.activePlans || []
    if (!selectedVehicleId.value && vehicles.value.length) selectedVehicleId.value = vehicles.value[0].id
  })

  const closeMenu = lua.career_modules_insurance.closeMenu

  const dispose = () => {
    events.off("insurancePoliciesData")
  }

  return {
    dispose,
    policiesData,
    requestInitialData,
    closeMenu,
    careerMoney,
    policyHistory,
    careerVouchers,
    vehicles,
    activePlans,
    selectedVehicleId,
  }
})
