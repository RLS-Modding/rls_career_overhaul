import { anchorBusinessTimers } from "./businessTime.js"
import { defineStore, storeToRefs } from "pinia"
import { lua } from "@/bridge"
import { normalizeId } from "../../utils/businessUtils"
import { isMissingLuaJobId } from "./businessBridge.js"
import { useBusinessSessionStore } from "./businessSessionStore.js"
import { useBusinessTechsStore } from "./businessTechsStore.js"

// Jobs tab: accept, decline, abandon, complete, and the events that move jobs between the new and active lists.
// Start reading at handleJobsUpdated.

export const useBusinessJobsStore = defineStore("overhaulBusinessJobs", () => {
  const sessionStore = useBusinessSessionStore()
  const {
    businessData, pulledOutVehicle, pulledOutVehicles, activeVehicleId, isMenuActive, businessId, businessType
  } = storeToRefs(sessionStore)
  const { hasCapability, ownerModule, getLuaModule } = sessionStore
  const techsStore = useBusinessTechsStore()
  const { updateTechs } = techsStore

  const acceptJob = async (jobId) => {
    if (!businessId.value || isMissingLuaJobId(jobId)) return false
    try {
      // Always use businessComputer for job actions - it triggers UI events
      const success = await lua.overhaul_career_business_computer.acceptJob(businessId.value, jobId)
      return success
    } catch (error) {
      return false
    }
  }

  const declineJob = async (jobId) => {
    if (!businessId.value || isMissingLuaJobId(jobId)) return false
    try {
      // Always use businessComputer for job actions - it triggers UI events
      const success = await lua.overhaul_career_business_computer.declineJob(businessId.value, jobId)
      return success
    } catch (error) {
      return false
    }
  }

  const abandonJob = async (jobId) => {
    if (!businessId.value || isMissingLuaJobId(jobId)) return false
    try {
      // Always use businessComputer for job actions - it triggers UI events
      const success = await lua.overhaul_career_business_computer.abandonJob(businessId.value, jobId)
      return success
    } catch (error) {
      return false
    }
  }

  const completeJob = async (jobId) => {
    if (!businessId.value) return false
    try {
      // Always use businessComputer for job actions - it triggers UI events
      const success = await lua.overhaul_career_business_computer.completeJob(businessId.value, jobId)
      return success
    } catch (error) {
      return false
    }
  }

  const handleJobsUpdated = async (data) => {
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

    try {
      let jobsData = data
      // If data only contains id/type and not the job lists, fetch them
      if (!jobsData || !jobsData.activeJobs || !jobsData.newJobs) {
        jobsData = await getLuaModule().getJobsOnly(currentBusinessId)
        if (String(businessId.value) !== String(currentBusinessId)) return
      }

      if (jobsData) {
        jobsData = anchorBusinessTimers(jobsData)
        businessData.value = {
          ...businessData.value,
          activeJobs: jobsData.activeJobs || [],
          newJobs: jobsData.newJobs || [],
          maxActiveJobs: jobsData.maxActiveJobs ?? businessData.value.maxActiveJobs
        }

        if (hasCapability('customerJobs')) {
          const techs = Array.isArray(businessData.value.techs) ? businessData.value.techs : []
          const hasSuspiciousAssignment = (businessData.value.activeJobs || []).some(job => {
            if (!job?.techAssigned) return false
            const jobId = normalizeId(job.jobId ?? job.id)
            return !techs.find(tech =>
              String(tech.id) === String(job.techAssigned) &&
              normalizeId(tech.jobId) === jobId
            )
          })

          if (hasSuspiciousAssignment) {
            const techsData = await ownerModule().getTechData(currentBusinessId)
            if (techsData?.techs && Array.isArray(techsData.techs)) {
              updateTechs(techsData.techs)
            }
          }
        }
      }
    } catch (error) {
    }
  }

  const handleJobAccepted = (data) => {
    data = anchorBusinessTimers(data)
    if (!isMenuActive.value) return
    if (String(data.businessId) !== String(businessId.value)) return
    businessData.value = {
      ...businessData.value,
      activeJobs: data.activeJobs || [],
      newJobs: data.newJobs || [],
      maxActiveJobs: data.maxActiveJobs ?? businessData.value.maxActiveJobs,
      vehicles: data.vehicles || businessData.value.vehicles
    }
  }

  const handleJobDeclined = (data) => {
    data = anchorBusinessTimers(data)
    if (!isMenuActive.value) return
    if (String(data.businessId) !== String(businessId.value)) return
    businessData.value = {
      ...businessData.value,
      newJobs: data.newJobs || []
    }
  }

  const handleJobAbandoned = (data) => {
    data = anchorBusinessTimers(data)
    if (!isMenuActive.value) return
    if (String(data.businessId) !== String(businessId.value)) return
    pulledOutVehicle.value = null
    const vehiclesFromData = Array.isArray(data.pulledOutVehicles) ? data.pulledOutVehicles : []
    pulledOutVehicles.value = vehiclesFromData
    if (vehiclesFromData.length === 0) {
      activeVehicleId.value = null
    }
    businessData.value = {
      ...businessData.value,
      activeJobs: data.activeJobs || [],
      vehicles: data.vehicles || [],
      pulledOutVehicles: vehiclesFromData
    }
  }

  const handleJobCompleted = (data) => {
    data = anchorBusinessTimers(data)
    if (!isMenuActive.value) return
    if (String(data.businessId) !== String(businessId.value)) return
    pulledOutVehicle.value = null
    const vehiclesFromData = Array.isArray(data.pulledOutVehicles) ? data.pulledOutVehicles : []
    pulledOutVehicles.value = vehiclesFromData
    if (vehiclesFromData.length === 0) {
      activeVehicleId.value = null
    }
    businessData.value = {
      ...businessData.value,
      activeJobs: data.activeJobs || [],
      vehicles: data.vehicles || [],
      pulledOutVehicles: vehiclesFromData
    }
  }

  return {
    acceptJob,
    declineJob,
    abandonJob,
    completeJob,
    handleJobsUpdated,
    handleJobAccepted,
    handleJobDeclined,
    handleJobAbandoned,
    handleJobCompleted
  }
})
