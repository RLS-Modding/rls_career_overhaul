// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

import { ref } from "vue"
import { defineStore, storeToRefs } from "pinia"
import { lua } from "@/bridge"
import { useBusinessSessionStore } from "./businessSessionStore.js"

// Kits tab: saved kits for the tuning shop and the events that change them.

export const useBusinessKitsStore = defineStore("overhaulBusinessKits", () => {
  const sessionStore = useBusinessSessionStore()
  const {
    businessData, pulledOutVehicle, isMenuActive, businessId, businessType, isDamageLocked
  } = storeToRefs(sessionStore)
  const { showDamageLockWarning, loadBusinessData, onBusinessDataApplied } = sessionStore

  const kits = ref([])
  const maxKitStorage = ref(0)
  const currentKitCount = ref(0)

  const createKit = async (jobId, kitName) => {
    if (!businessId.value || businessId.value === true) return false
    try {
      const spawnedVehicleId = pulledOutVehicle.value?.spawnedVehicleId ?? null
      const success = await lua.overhaul_career_business_tuningShop_kits.createKit(businessId.value, jobId, kitName, spawnedVehicleId)
      return success
    } catch (error) {
      return false
    }
  }

  const deleteKit = async (kitId) => {
    if (!businessId.value) return false
    try {
      const success = await lua.overhaul_career_business_tuningShop_kits.deleteKit(businessId.value, kitId)
      return success
    } catch (error) {
      return false
    }
  }

  const applyKit = async (vehicleId, kitId) => {
    if (!businessId.value || !vehicleId || !kitId) return false
    if (isDamageLocked.value) {
      showDamageLockWarning()
      return false
    }
    try {
      const result = await lua.overhaul_career_business_tuningShop_kits.applyKit(businessId.value, vehicleId, kitId)
      if (result && result.success) {
        return { success: true, cost: result.cost }
      } else {
        return { success: false, error: result ? result.error : "Unknown error" }
      }
    } catch (error) {
      return { success: false, error: "Lua error" }
    }
  }

  const handleKitsUpdated = (data) => {
    if (!isMenuActive.value) return
    if (data && data.businessId && String(data.businessId) === String(businessId.value)) {
      if (data.kits) {
        kits.value = data.kits
        businessData.value = {
          ...businessData.value,
          stats: {
            ...(businessData.value.stats || {}),
            kits: data.kits
          }
        }
      } else {
        loadBusinessData(businessType.value, businessId.value)
      }
    }
  }

  onBusinessDataApplied((payload) => {
    if (payload.stats) {
      kits.value = payload.stats.kits || []
      maxKitStorage.value = payload.stats.maxKitStorage || 0
      currentKitCount.value = payload.stats.currentKitCount || 0
    }
  })

  return {
    kits,
    maxKitStorage,
    currentKitCount,
    createKit,
    deleteKit,
    applyKit,
    handleKitsUpdated
  }
})
