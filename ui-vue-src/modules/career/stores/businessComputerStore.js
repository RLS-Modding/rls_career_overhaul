import { computed, ref } from "vue"
import { defineStore } from "pinia"
import { lua } from "@/bridge"

export const useBusinessComputerStore = defineStore("businessComputer", () => {
  const businessData = ref({})
  const activeView = ref("home")
  const vehicleView = ref(null)
  const pulledOutVehicle = ref(null)
  const loading = ref(false)

  const businessId = computed(() => businessData.value.businessId)
  const businessType = computed(() => businessData.value.businessType)
  const businessName = computed(() => businessData.value.businessName || "Business")
  
  const activeJobs = computed(() => businessData.value.activeJobs || [])
  const newJobs = computed(() => businessData.value.newJobs || [])
  const vehicles = computed(() => {
    const v = businessData.value.vehicles
    if (!v) return []
    if (Array.isArray(v)) return v
    if (typeof v === 'object') return Object.values(v)
    return []
  })
  const parts = computed(() => businessData.value.parts || [])
  const stats = computed(() => businessData.value.stats || {})

  const setBusinessData = (data) => {
    businessData.value = data
    if (data.pulledOutVehicle) {
      pulledOutVehicle.value = data.pulledOutVehicle
    } else {
      pulledOutVehicle.value = null
    }
  }

  const loadBusinessData = async (businessType, businessId) => {
    loading.value = true
    try {
      const data = await lua.career_modules_business_businessComputer.getBusinessComputerUIData(businessType, businessId)
      setBusinessData(data)
    } catch (error) {
      console.error("Failed to load business data:", error)
    } finally {
      loading.value = false
    }
  }

  const acceptJob = async (jobId) => {
    if (!businessId.value) return false
    try {
      const success = await lua.career_modules_business_businessComputer.acceptJob(businessId.value, jobId)
      if (success) {
        await loadBusinessData(businessType.value, businessId.value)
      }
      return success
    } catch (error) {
      console.error("Failed to accept job:", error)
      return false
    }
  }

  const declineJob = async (jobId) => {
    if (!businessId.value) return false
    try {
      const success = await lua.career_modules_business_businessComputer.declineJob(businessId.value, jobId)
      if (success) {
        await loadBusinessData(businessType.value, businessId.value)
      }
      return success
    } catch (error) {
      console.error("Failed to decline job:", error)
      return false
    }
  }

  const abandonJob = async (jobId) => {
    if (!businessId.value) return false
    try {
      const success = await lua.career_modules_business_businessComputer.abandonJob(businessId.value, jobId)
      if (success) {
        pulledOutVehicle.value = null
        await loadBusinessData(businessType.value, businessId.value)
      }
      return success
    } catch (error) {
      console.error("Failed to abandon job:", error)
      return false
    }
  }

  const pullOutVehicle = async (vehicleId) => {
    if (!businessId.value) {
      console.error("pullOutVehicle: No businessId")
      return false
    }
    console.log("pullOutVehicle: Calling Lua with businessId=", businessId.value, "vehicleId=", vehicleId)
    try {
      const success = await lua.career_modules_business_businessComputer.pullOutVehicle(businessId.value, vehicleId)
      console.log("pullOutVehicle: Lua returned", success)
      if (success) {
        await loadBusinessData(businessType.value, businessId.value)
      }
      return success
    } catch (error) {
      console.error("Failed to pull out vehicle:", error)
      return false
    }
  }

  const putAwayVehicle = async () => {
    if (!businessId.value) return false
    try {
      const success = await lua.career_modules_business_businessComputer.putAwayVehicle(businessId.value)
      if (success) {
        pulledOutVehicle.value = null
        await loadBusinessData(businessType.value, businessId.value)
      }
      return success
    } catch (error) {
      console.error("Failed to put away vehicle:", error)
      return false
    }
  }

  const switchView = (view) => {
    activeView.value = view
    vehicleView.value = null
  }

  const switchVehicleView = (view) => {
    vehicleView.value = view
  }

  const closeVehicleView = () => {
    vehicleView.value = null
  }

  const onMenuClosed = () => {
    activeView.value = "home"
    vehicleView.value = null
    pulledOutVehicle.value = null
    // Clear cache on Lua side when menu is closed
    try {
      lua.career_modules_business_businessComputer.clearVehicleDataCaches()
    } catch (error) {
      console.error("Failed to clear vehicle data caches:", error)
    }
  }

  const requestVehiclePartsTree = async (vehicleId) => {
    if (!businessId.value || !vehicleId) return null
    
    // Request data via hook (returns immediately, data comes via hook)
    // Cache is checked on Lua side
    try {
      await lua.career_modules_business_businessComputer.requestVehiclePartsTree(businessId.value, vehicleId)
      // Return null since data will come via hook
      return null
    } catch (error) {
      console.error("Failed to request vehicle parts tree:", error)
      return null
    }
  }

  const requestVehicleTuningData = async (vehicleId) => {
    if (!businessId.value || !vehicleId) return null
    
    // Request data via hook (returns immediately, data comes via hook)
    // Cache is checked on Lua side
    try {
      await lua.career_modules_business_businessComputer.requestVehicleTuningData(businessId.value, vehicleId)
      // Return null since data will come via hook
      return null
    } catch (error) {
      console.error("Failed to request vehicle tuning data:", error)
      return null
    }
  }

  const applyVehicleTuning = async (vehicleId, tuningVars) => {
    if (!businessId.value || !vehicleId || !tuningVars) return false
    try {
      const success = await lua.career_modules_business_businessComputer.applyVehicleTuning(businessId.value, vehicleId, tuningVars)
      return success
    } catch (error) {
      console.error("Failed to apply vehicle tuning:", error)
      return false
    }
  }

  return {
    businessData,
    activeView,
    vehicleView,
    pulledOutVehicle,
    loading,
    businessId,
    businessType,
    businessName,
    activeJobs,
    newJobs,
    vehicles,
    parts,
    stats,
    loadBusinessData,
    acceptJob,
    declineJob,
    abandonJob,
    pullOutVehicle,
    putAwayVehicle,
    switchView,
    switchVehicleView,
    closeVehicleView,
    onMenuClosed,
    requestVehiclePartsTree,
    requestVehicleTuningData,
    applyVehicleTuning,
  }
})

