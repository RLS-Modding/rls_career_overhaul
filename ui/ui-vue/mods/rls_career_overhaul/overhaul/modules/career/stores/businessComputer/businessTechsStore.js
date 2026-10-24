import { anchorBusinessTimers } from "./businessTime.js"
import { computed, ref } from "vue"
import { defineStore, storeToRefs } from "pinia"
import { lua } from "@/bridge"
import { showErrorMessage, parseUpdateResult } from "./businessBridge.js"
import { useBusinessSessionStore } from "./businessSessionStore.js"
import { useBusinessRacingTeamStore } from "./businessRacingTeamStore.js"

// Technician snapshots carry start anchors; only mounted leaves subscribe to the clock.
const createTechIntake = (businessData) => {
  const updateTechs = (newTechs) => {
    if (!businessData.value) businessData.value = {}
    businessData.value.techs = anchorBusinessTimers({ techs: newTechs || [] }).techs
  }
  const updateManager = (data) => {
    Object.assign(businessData.value, anchorBusinessTimers(data))
  }
  return { updateTechs, updateManager }
}

// Technician and manager actions: owner endpoints behind a capability; the reads fall back to the computer's Lua functions.
const createTechServiceActions = ({ businessId, businessType, businessData, hasCapability, ownerModule, loadBusinessData }) => {
  // Owner endpoints take the facility id alone; the computer's versions of the same reads differ in name or arguments.
  const fetchManagerData = (targetBusinessId) => hasCapability('ownerEndpoints')
    ? ownerModule().getManagerData(targetBusinessId)
    : lua.overhaul_career_business_computer.getManagerData(targetBusinessId)

  const fetchTechsData = (targetBusinessId) => hasCapability('ownerEndpoints')
    ? ownerModule().getTechData(targetBusinessId)
    : lua.overhaul_career_business_computer.getTechsOnly(targetBusinessId)

  const assignTechToJob = async (techId, jobId) => {
    if (!businessId.value) return false
    try {
      let success
      if (hasCapability('techManagement')) {
        success = await ownerModule().assignJobToTech(businessId.value, techId, jobId)
      } else {
        success = await lua.overhaul_career_business_computer.assignTechToJob(businessId.value, techId, jobId)
      }
      return success
    } catch (error) {
      return false
    }
  }

  const renameTech = async (techId, newName) => {
    if (!businessId.value) return false
    try {
      let success
      if (hasCapability('techManagement')) {
        success = await ownerModule().updateTechName(businessId.value, techId, newName ?? "")
      } else {
        success = await lua.overhaul_career_business_computer.renameTech(businessId.value, techId, newName ?? "")
      }
      return success
    } catch (error) {
      return false
    }
  }

  const fireTech = async (techId) => {
    if (!businessId.value) return false
    try {
      let success
      if (hasCapability('techManagement')) {
        success = await ownerModule().fireTech(businessId.value, techId)
      } else {
        return false
      }
      if (success) {
        await loadBusinessData(businessType.value, businessId.value)
      }
      return success
    } catch (error) {
      return false
    }
  }

  const hireTech = async (techId) => {
    if (!businessId.value) return false
    try {
      let success
      if (hasCapability('techManagement')) {
        success = await ownerModule().hireTech(businessId.value, techId)
      } else {
        return false
      }
      if (success) {
        await loadBusinessData(businessType.value, businessId.value)
      }
      return success
    } catch (error) {
      return false
    }
  }

  const stopTechFromJob = async (techId) => {
    if (!businessId.value) return false
    try {
      let success
      if (hasCapability('techManagement')) {
        success = await ownerModule().stopTechFromJob(businessId.value, techId)
      } else {
        return false
      }
      if (success) {
        await loadBusinessData(businessType.value, businessId.value)
      }
      return success
    } catch (error) {
      return false
    }
  }

  const setManagerPaused = async (paused) => {
    if (!businessId.value) return false
    try {
      let success
      if (hasCapability('customerJobs')) {
        const result = await ownerModule().setManagerPaused(businessId.value, paused)
        
        // Handle multiple return values: [success, pausedState]
        let newPausedState
        if (Array.isArray(result) && result.length >= 2) {
          success = result[0] === true || result[0] === 'true' || result[0] === 1
          newPausedState = result[1] === true
        } else {
          success = result === true || result === 'true' || result === 1
          newPausedState = paused === true
        }
        
        // Update immediately with the new paused state (create new object to trigger reactivity)
        if (success && businessData.value) {
          businessData.value = {
            ...businessData.value,
            managerPaused: newPausedState
          }
        }
      } else {
        return false
      }
      
      if (success) {
        // Refresh the full data to ensure everything is in sync
        await loadBusinessData(businessType.value, businessId.value)
      }
      
      return success
    } catch (error) {
      console.error('Error setting manager paused:', error)
      return false
    }
  }

  return { fetchManagerData, fetchTechsData, assignTechToJob, renameTech, fireTech, hireTech, stopTechFromJob, setManagerPaused }
}

// Events from the server: a roster update sets the techs and syncs the racing team poll; an assignment merges jobs and techs.
const createTechEvents = ({ businessId, businessType, isMenuActive, businessData, updateTechs, syncRacingTeamSimPoll }) => {
  const handleTechsUpdated = (data) => {
    const currentBusinessId = businessId.value
    const currentBusinessType = businessType.value

    if (!currentBusinessId || !currentBusinessType) {
      return
    }

    const eventBusinessType = data?.businessType
    if (eventBusinessType && eventBusinessType !== currentBusinessType) {
      return
    }

    const eventBusinessId = data?.businessId
    if (eventBusinessId && String(eventBusinessId) !== String(currentBusinessId)) {
      return
    }

    if (data?.techs && Array.isArray(data.techs)) {
      updateTechs(data.techs)
      syncRacingTeamSimPoll()
    }
  }

  const handleTechAssigned = (data) => {
    if (!isMenuActive.value) return
    if (String(data.businessId) !== String(businessId.value)) return
    businessData.value = {
      ...businessData.value,
      activeJobs: data.activeJobs || businessData.value.activeJobs,
      techs: data.techs ? anchorBusinessTimers({ techs: data.techs }).techs : businessData.value.techs
    }
    syncRacingTeamSimPoll()
  }

  return { handleTechsUpdated, handleTechAssigned }
}

// Customer blacklists and notification list: read and write through the owner module, gated by customer jobs.
const createCustomerLists = ({ businessId, hasCapability, ownerModule, blacklistData, notificationListData, managerBlacklistData }) => {
  const fetchBlacklistData = async () => {
    if (!businessId.value || !hasCapability('customerJobs')) {
      blacklistData.value = null
      return null
    }
    try {
      const data = await ownerModule().getBlacklistData(businessId.value)
      blacklistData.value = data && typeof data === 'object' ? data : null
      return data
    } catch (error) {
      blacklistData.value = null
      return null
    }
  }

  const fetchNotificationListData = async () => {
    if (!businessId.value || !hasCapability('customerJobs')) {
      notificationListData.value = null
      return null
    }
    try {
      const data = await ownerModule().getNotificationListData(businessId.value)
      notificationListData.value = data && typeof data === 'object' ? data : null
      return data
    } catch (error) {
      notificationListData.value = null
      return null
    }
  }

  const fetchManagerBlacklistData = async () => {
    if (!businessId.value || !hasCapability('customerJobs')) {
      managerBlacklistData.value = null
      return null
    }
    try {
      const data = await ownerModule().getManagerBlacklistData(businessId.value)
      managerBlacklistData.value = data && typeof data === 'object' ? data : null
      return data
    } catch (error) {
      managerBlacklistData.value = null
      return null
    }
  }

  const updateBlacklist = async (modelKeys) => {
    if (!businessId.value || !hasCapability('customerJobs')) return false
    try {
      const result = await ownerModule().updateBlacklist(businessId.value, modelKeys || [])
      const parsed = parseUpdateResult(result)
      if (!parsed.success && parsed.message) {
        showErrorMessage(parsed.message)
      }
      return parsed.success
    } catch (error) {
      return false
    }
  }

  const updateNotificationList = async (entries) => {
    if (!businessId.value || !hasCapability('customerJobs')) return false
    try {
      const result = await ownerModule().updateNotificationList(businessId.value, entries || [])
      const parsed = parseUpdateResult(result)
      if (!parsed.success && parsed.message) {
        showErrorMessage(parsed.message)
      }
      return parsed.success
    } catch (error) {
      return false
    }
  }

  const updateManagerBlacklist = async (modelKeys) => {
    if (!businessId.value || !hasCapability('customerJobs')) return false
    try {
      const result = await ownerModule().updateManagerBlacklist(businessId.value, modelKeys || [])
      const parsed = parseUpdateResult(result)
      if (!parsed.success && parsed.message) {
        showErrorMessage(parsed.message)
      }
      return parsed.success
    } catch (error) {
      return false
    }
  }

  return { fetchBlacklistData, fetchNotificationListData, fetchManagerBlacklistData, updateBlacklist, updateNotificationList, updateManagerBlacklist }
}

export const useBusinessTechsStore = defineStore("overhaulBusinessTechs", () => {
  const sessionStore = useBusinessSessionStore()
  const { businessData, isMenuActive, businessId, businessType } = storeToRefs(sessionStore)
  const { hasCapability, ownerModule, loadBusinessData } = sessionStore
  const racingTeamStore = useBusinessRacingTeamStore()
  const { syncRacingTeamSimPoll } = racingTeamStore

  const blacklistData = ref(null)
  const notificationListData = ref(null)
  const managerBlacklistData = ref(null)

  const techs = computed(() => businessData.value.techs || [])

  const hasManager = computed(() => businessData.value?.hasManager === true)

  const hasGeneralManager = computed(() => businessData.value?.hasGeneralManager === true)

  const managerAssignmentInterval = computed(() => businessData.value?.managerAssignmentInterval || null)

  const managerReadyToAssign = computed(() => businessData.value?.managerReadyToAssign === true)

  const managerTimeRemaining = computed(() => businessData.value?.managerTimeRemaining || null)

  const managerPaused = computed(() => businessData.value?.managerPaused === true)

  const { updateTechs, updateManager } = createTechIntake(businessData)
  const { fetchManagerData, fetchTechsData, assignTechToJob, renameTech, fireTech, hireTech, stopTechFromJob, setManagerPaused } =
    createTechServiceActions({ businessId, businessType, businessData, hasCapability, ownerModule, loadBusinessData })
  const { handleTechsUpdated, handleTechAssigned } =
    createTechEvents({ businessId, businessType, isMenuActive, businessData, updateTechs, syncRacingTeamSimPoll })
  const { fetchBlacklistData, fetchNotificationListData, fetchManagerBlacklistData, updateBlacklist, updateNotificationList, updateManagerBlacklist } =
    createCustomerLists({ businessId, hasCapability, ownerModule, blacklistData, notificationListData, managerBlacklistData })


  return {
    blacklistData,
    notificationListData,
    managerBlacklistData,
    techs,
    hasManager,
    hasGeneralManager,
    managerAssignmentInterval,
    managerReadyToAssign,
    managerTimeRemaining,
    managerPaused,
    updateTechs,
    updateManager,
    fetchManagerData,
    fetchTechsData,
    assignTechToJob,
    renameTech,
    fireTech,
    hireTech,
    stopTechFromJob,
    setManagerPaused,
    handleTechsUpdated,
    handleTechAssigned,
    fetchBlacklistData,
    fetchNotificationListData,
    fetchManagerBlacklistData,
    updateBlacklist,
    updateNotificationList,
    updateManagerBlacklist
  }
})
