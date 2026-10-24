// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

import { computed, ref } from "vue"
import { defineStore, storeToRefs } from "pinia"
import { lua } from "@/bridge"
import { useBusinessSessionStore } from "./businessSessionStore.js"
import { useBusinessCartStore } from "./businessCartStore.js"

// Tuning tab: tuning data and cart, and the power/weight readout for the vehicle on the lift.
// Start reading at addTuningToCart. The readout is built by createPowerWeightReadout below.

// Keeps the first reading as the original, the latest reading as current, and derives the ratios and changes from both.
// The session refs are passed in, so the readout reads the same refs the store was created with.
function createPowerWeightReadout({ businessId, pulledOutVehicle, isDamageLocked, showDamageLockWarning }) {
  const originalPower = ref(null)
  const originalWeight = ref(null)
  const currentPower = ref(null)
  const currentWeight = ref(null)
  const originalCurveData = ref(null)

  const handlePowerWeightData = (data) => {
    if (!data || !data.success) return

    // Only update if it's for the current vehicle
    if (String(data.businessId) === String(businessId.value) && String(data.vehicleId) === String(pulledOutVehicle.value?.vehicleId)) {
      // If this is the first time we're getting data, set it as original
      if (originalPower.value === null && originalWeight.value === null) {
        originalPower.value = data.power
        originalWeight.value = data.weight
      }

      // Always update current values
      currentPower.value = data.power
      currentWeight.value = data.weight
    }
  }

  const updatePowerWeight = async () => {
    if (!businessId.value || !pulledOutVehicle.value?.vehicleId) return
    if (isDamageLocked.value) {
      showDamageLockWarning()
      return
    }

    try {
      lua.overhaul_career_business_computer.getVehiclePowerWeight(
        businessId.value,
        pulledOutVehicle.value.vehicleId
      )
    } catch (error) {
    }
  }

  const powerToWeightRatio = computed(() => {
    if (!currentPower.value || !currentWeight.value || currentWeight.value <= 0) return null
    return currentPower.value / currentWeight.value
  })

  const originalPowerToWeightRatio = computed(() => {
    if (!originalPower.value || !originalWeight.value || originalWeight.value <= 0) return null
    return originalPower.value / originalWeight.value
  })

  const powerChange = computed(() => {
    if (originalPower.value === null || currentPower.value === null) return null
    return currentPower.value - originalPower.value
  })

  const weightChange = computed(() => {
    if (originalWeight.value === null || currentWeight.value === null) return null
    return currentWeight.value - originalWeight.value
  })

  const resetPowerWeight = () => {
    originalPower.value = null
    originalWeight.value = null
    currentPower.value = null
    currentWeight.value = null
    originalCurveData.value = null
  }

  return {
    originalPower,
    originalWeight,
    currentPower,
    currentWeight,
    originalCurveData,
    handlePowerWeightData,
    updatePowerWeight,
    powerToWeightRatio,
    originalPowerToWeightRatio,
    powerChange,
    weightChange,
    resetPowerWeight
  }
}

export const useBusinessTuningStore = defineStore("overhaulBusinessTuning", () => {
  const sessionStore = useBusinessSessionStore()
  const { pulledOutVehicle, businessId, isDamageLocked } = storeToRefs(sessionStore)
  const { showDamageLockWarning } = sessionStore
  const cartStore = useBusinessCartStore()
  const {
    partsCart, tuningCart, cartTabs, activeTabId, originalVehicleState, currentAppliedCartHash
  } = storeToRefs(cartStore)
  const { generateCartHash, saveCurrentTabState, tuningCartVariableValues } = cartStore

  const {
    originalPower, originalWeight, currentPower, currentWeight, originalCurveData, handlePowerWeightData,
    updatePowerWeight, powerToWeightRatio, originalPowerToWeightRatio, powerChange, weightChange, resetPowerWeight
  } = createPowerWeightReadout({ businessId, pulledOutVehicle, isDamageLocked, showDamageLockWarning })

  const requestVehicleTuningData = async (vehicleId) => {
    if (!businessId.value || !vehicleId) return null
    if (isDamageLocked.value) {
      showDamageLockWarning()
      return null
    }

    try {
      await lua.overhaul_career_business_computer.requestVehicleTuningData(businessId.value, vehicleId)
      return null
    } catch (error) {
      return null
    }
  }

  const applyVehicleTuning = async (vehicleId, tuningVars) => {
    if (!businessId.value || !vehicleId || !tuningVars) return false
    if (isDamageLocked.value) {
      showDamageLockWarning()
      return false
    }
    try {
      const success = await lua.overhaul_career_business_computer.applyVehicleTuning(businessId.value, vehicleId, tuningVars)
      return success
    } catch (error) {
      return false
    }
  }

  const addTuningToCart = async (tuningVars, originalVars) => {
    if (!businessId.value || !pulledOutVehicle.value?.vehicleId) {
      tuningCart.value = []
      saveCurrentTabState()
      return
    }
    if (isDamageLocked.value) {
      showDamageLockWarning()
      return
    }

    // Convert originalVars from tuning data format to simple varName->value map
    // Convert to actual range for comparison (tuningVars uses actual range)
    const baselineVars = {}
    if (originalVars) {
      for (const [varName, varData] of Object.entries(originalVars)) {
        if (varData) {
          let baselineValue
          if (varData.val !== undefined) {
            baselineValue = varData.val
          } else if (varData.valDis !== undefined) {
            baselineValue = varData.valDis
          } else {
            continue
          }

          baselineVars[varName] = baselineValue
        }
      }
    }

    try {
      // Always use businessComputer for cart operations - tuningShop doesn't have these functions
      const cartItems = await lua.overhaul_career_business_computer.addTuningToCart(
        businessId.value,
        pulledOutVehicle.value.vehicleId,
        tuningVars,
        baselineVars
      )

      let itemsArray = []
      if (Array.isArray(cartItems)) {
        itemsArray = cartItems
      } else if (cartItems && typeof cartItems === 'object') {
        itemsArray = Object.values(cartItems)
      }


      tuningCart.value = itemsArray
      saveCurrentTabState()
      currentAppliedCartHash.value = generateCartHash(partsCart.value, tuningCart.value)

      // Update power/weight after tuning change
      updatePowerWeight()
    } catch (error) {
      tuningCart.value = []
      saveCurrentTabState()
    }
  }

  const removeTuningFromCart = async (varName) => {
    const index = tuningCart.value.findIndex(item => item.varName === varName)
    if (index >= 0) {
      tuningCart.value.splice(index, 1)

      const tuningVars = tuningCartVariableValues()

      await addTuningToCart(tuningVars)
    }
  }

  const initializeCartForVehicle = async () => {
    if (isDamageLocked.value) {
      showDamageLockWarning()
      return
    }
    cartTabs.value = [{ id: 'default', name: 'Build 1', parts: [], tuning: [], cartHash: generateCartHash([], []) }]
    activeTabId.value = 'default'
    partsCart.value = []
    tuningCart.value = []
    originalVehicleState.value = null
    currentAppliedCartHash.value = generateCartHash([], [])

    resetPowerWeight()

    if (businessId.value && pulledOutVehicle.value?.vehicleId) {
      try {
        await lua.overhaul_career_business_computer.initializePreviewVehicle(
          businessId.value,
          pulledOutVehicle.value.vehicleId
        )
      } catch (error) {
      }
    }
    await updatePowerWeight()
  }

  return {
    originalPower,
    originalWeight,
    currentPower,
    currentWeight,
    originalCurveData,
    requestVehicleTuningData,
    applyVehicleTuning,
    addTuningToCart,
    removeTuningFromCart,
    handlePowerWeightData,
    initializeCartForVehicle,
    updatePowerWeight,
    powerToWeightRatio,
    originalPowerToWeightRatio,
    powerChange,
    weightChange,
    resetPowerWeight
  }
})
