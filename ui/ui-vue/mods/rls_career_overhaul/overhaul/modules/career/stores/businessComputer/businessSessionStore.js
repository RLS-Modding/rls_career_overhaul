import { anchorBusinessTimers } from "./businessTime.js"
import { computed, ref, watch } from "vue"
import { defineStore } from "pinia"
import { lua } from "@/bridge"
import { normalizeId } from "../../utils/businessUtils"
import { businessTypes, businessTypeFacts, projectBusinessTabs, reportBusinessTabConflicts } from "../../utils/businessTypeCatalog.js"
import { moduleNamed, showErrorMessage } from "./businessBridge.js"

// The business the computer is open on: pushed data, the type descriptor and what it can do, pulled-out vehicles,
// damage lock, and the Lua reads that fill them. Every other business store builds on this one.
// Start reading at loadBusinessData, which hands off to loadBusinessDataFor; applyBusinessData (above) turns a pushed
// payload into the state that setup creates.
// The setup function creates its reactive objects in one fixed order (the catalog watcher sits between the state refs and
// the flags). Logic that touches no reactive object of its own lives above it; intake and read requests get the refs they
// use passed in, so they can be read as their own phases.

// Derived lists: each takes the raw payload list and answers the sorted or filtered view of it.
const sortActiveJobs = (jobs) => {
  if (!Array.isArray(jobs)) return []
  return [...jobs].sort((a, b) => {
    const aHasTech = !!(a?.techAssigned)
    const bHasTech = !!(b?.techAssigned)
    if (aHasTech === bHasTech) return 0
    return aHasTech ? 1 : -1
  })
}

const getJobExpiry = (job) => {
  return job?.expiresAtSeconds ?? (typeof job?.expiresInSeconds === "number" ? job.expiresInSeconds : Number.POSITIVE_INFINITY)
}

const getJobSortId = (job) => {
  if (job?.jobId !== undefined) {
    return Number(job.jobId) || job.jobId
  }
  return job?.id || 0
}

const sortNewJobs = (jobs) => {
  if (!Array.isArray(jobs)) {
    return []
  }
  return [...jobs].sort((a, b) => {
    const expireA = getJobExpiry(a)
    const expireB = getJobExpiry(b)
    if (expireA !== expireB) {
      return expireA - expireB
    }
    const idA = getJobSortId(a)
    const idB = getJobSortId(b)
    if (idA === idB) {
      return 0
    }
    return idA < idB ? -1 : 1
  })
}

// A failed Lua result shows the damage warning or its message and reads as false; any other result passes through.
const normalizeLuaResultWith = (result, onDamageLocked) => {
  if (result && typeof result === "object" && result.success === false) {
    if (result.errorCode === "damageLocked") {
      onDamageLocked()
    } else if (result.message) {
      showErrorMessage(result.message)
    }
    return false
  }
  return result
}

const vehicleList = (v) => {
  if (!v) return []
  if (Array.isArray(v)) return v
  if (typeof v === 'object') return Object.values(v)
  return []
}

// The tabs grouped by section; a tab with no section goes under BASIC.
const groupTabsBySection = (tabsRef) => {
  const sections = {}
  const tabs = Array.isArray(tabsRef.value) ? tabsRef.value : Object.values(tabsRef.value || {})
  tabs.forEach(tab => {
    if (!tab) return
    const section = tab.section || 'BASIC'
    if (!sections[section]) {
      sections[section] = []
    }
    sections[section].push(tab)
  })
  return sections
}

/** The type descriptor from the manager; null when Lua cannot answer, so the catalog covers for it. */
const fetchTypeData = async (type) => {
  try {
    const descriptor = await lua.overhaul_career_business_manager.getTypeData(type)
    return descriptor && typeof descriptor === "object" ? descriptor : null
  } catch (error) {
    return null
  }
}

// The manifest descriptor outranks whatever the owner's raw payload says about its own type.
const typeDataFields = (descriptor) => {
  const fields = {
    module: descriptor.module,
    sections: descriptor.sections ?? [],
    capabilities: descriptor.capabilities ?? {},
    skillNodes: descriptor.skillNodes ?? {},
  }
  if (descriptor.features !== undefined) fields.features = descriptor.features
  return fields
}

// Data intake: writes a pushed payload through the refs in `intake` and runs the listeners registered on the session.
const applyBusinessData = (intake, data) => {
  data = anchorBusinessTimers(data)
  const { businessData, pulledOutVehicles, pulledOutVehicle, activeVehicleId, acceptTabs, dataAppliedListeners } = intake
  const vehiclesFromData = Array.isArray(data?.pulledOutVehicles)
    ? data.pulledOutVehicles
    : (data?.pulledOutVehicle ? [data.pulledOutVehicle] : [])
  pulledOutVehicles.value = vehiclesFromData
  let nextActiveId = data?.activeVehicleId
  if (nextActiveId === undefined || nextActiveId === null) {
    nextActiveId = vehiclesFromData[0]?.vehicleId ?? data?.pulledOutVehicle?.vehicleId ?? null
  }
  activeVehicleId.value = nextActiveId ?? null
  const normalizedActiveId = normalizeId(nextActiveId)
  let activeEntry = null
  if (normalizedActiveId !== null) {
    activeEntry = vehiclesFromData.find(vehicle => normalizeId(vehicle?.vehicleId) === normalizedActiveId) || null
  }
  if (!activeEntry && data?.pulledOutVehicle) {
    activeEntry = data.pulledOutVehicle
  }
  pulledOutVehicle.value = activeEntry || null
  const payload = {
    ...data,
    pulledOutVehicle: activeEntry,
    pulledOutVehicles: vehiclesFromData,
    techs: data.techs || []
  }
  if (payload.businessType === undefined && businessData.value?.businessType) {
    payload.businessType = businessData.value.businessType
  }
  if (payload.businessType === businessData.value?.businessType) {
    for (const key of ['module', 'sections', 'capabilities', 'skillNodes']) {
      if (payload[key] === undefined && businessData.value?.[key] !== undefined) payload[key] = businessData.value[key]
    }
  }
  // Preserve existing parts if new data doesn't include them or has empty parts
  const hasValidParts = payload.parts && Array.isArray(payload.parts) && payload.parts.length > 0
  const hasExistingParts = businessData.value?.parts && Array.isArray(businessData.value.parts) && businessData.value.parts.length > 0

  if (!hasValidParts && hasExistingParts) {
    payload.parts = businessData.value.parts
  }
  if (payload.league2Invite === undefined && businessData.value?.league2Invite != null) {
    payload.league2Invite = businessData.value.league2Invite
  }
  businessData.value = payload
  if (payload.tabs) {
    let tabsArray = []
    if (Array.isArray(payload.tabs)) {
      tabsArray = payload.tabs
    } else if (typeof payload.tabs === 'object') {
      tabsArray = Object.values(payload.tabs)
    }
    acceptTabs(payload.businessType, tabsArray)
  } else {
    acceptTabs(payload.businessType, [])
  }
  // Stores that derive state from the payload (kits, racing schedules) register through onBusinessDataApplied.
  for (const listener of dataAppliedListeners) listener(payload)
}

// Read requests: loads the business for the computer. For fleet repair it also sets the maintenance flag and schedules a
// refresh of the vehicle rows. `session` holds the refs, the hasCapability check, setBusinessData and the loaded listeners.
// Returns whether usable business data arrived, so phone callers can offer a retry after a failed read.
const loadBusinessDataFor = async (session, businessType, targetBusinessId) => {
  const { isMenuActive, isMaintenanceEnabled, businessId, businessData, pulledOutVehicles, hasCapability, setBusinessData, dataLoadedListeners } = session
  if (typeof targetBusinessId === "boolean" || targetBusinessId === "true") {
    return false
  }
  isMenuActive.value = true
  try {
    const descriptor = await fetchTypeData(businessType)
    const declared = descriptor || businessTypeFacts(businessType)
    let data
    if (declared.capabilities?.ownerEndpoints === true && declared.module) {
      data = await moduleNamed(declared.module).getUIData(targetBusinessId)
    } else {
      data = await lua.overhaul_career_business_computer.getBusinessComputerUIData(businessType, targetBusinessId)
    }
    if (data != null && typeof data === "object" && !Array.isArray(data)) {
      setBusinessData(descriptor ? { ...data, ...typeDataFields(descriptor) } : data)
    }
    for (const listener of dataLoadedListeners) listener()
    if (hasCapability("fleetRepair")) {
      const maintenanceEnabledFromUiData = data?.experimentalMaintenanceEnabled === true
      let maintenanceEnabledFromLua = false
      try {
        maintenanceEnabledFromLua = (await lua.overhaul_career_maintenance_maintenanceMode.isEnabled()) === true
      } catch (error) {
      }
      isMaintenanceEnabled.value = maintenanceEnabledFromUiData || maintenanceEnabledFromLua
      // Fleet repair flags depend on async part-condition snapshots; refresh
      // vehicle rows shortly after opening so Repair visibility is ready.
      window.setTimeout(async () => {
        try {
          if (!isMenuActive.value) return
          if (normalizeId(businessId.value) !== normalizeId(targetBusinessId)) return
          const result = await lua.overhaul_career_business_computer.getVehiclesOnly(targetBusinessId)
          const vehiclesData = result && anchorBusinessTimers(result)
          if (!vehiclesData) return
          const vehiclesFromData = Array.isArray(vehiclesData.pulledOutVehicles) ? vehiclesData.pulledOutVehicles : []
          pulledOutVehicles.value = vehiclesFromData
          businessData.value = {
            ...businessData.value,
            vehicles: vehiclesData.vehicles || businessData.value.vehicles || [],
            pulledOutVehicles: vehiclesFromData,
            maxPulledOutVehicles: vehiclesData.maxPulledOutVehicles ?? businessData.value.maxPulledOutVehicles
          }
        } catch (error) {
        }
      }, 700)
    }
    return data != null && typeof data === "object" && !Array.isArray(data)
      && data.businessDataLoadFailed !== true && typeof data.businessId !== "boolean"
  } catch (error) {
    isMaintenanceEnabled.value = false
    return false
  }
}

export const useBusinessSessionStore = defineStore("overhaulBusinessSession", () => {
  const businessData = ref({})
  const activeView = ref("home")
  const vehicleView = ref(null)
  const pulledOutVehicle = ref(null)
  const pulledOutVehicles = ref([])
  const activeVehicleId = ref(null)
  const loading = ref(false)
  const registeredTabs = ref([])

  let rawTabData = null

  const acceptTabs = (businessType, tabs) => {
    rawTabData = { businessType, tabs }
    reportBusinessTabConflicts(businessType, tabs)
    registeredTabs.value = projectBusinessTabs(businessType, tabs, businessData.value?.sectionIds)
  }

  watch(businessTypes, () => {
    if (rawTabData && isMenuActive.value) registeredTabs.value = projectBusinessTabs(rawTabData.businessType, rawTabData.tabs, businessData.value?.sectionIds)
  })

  // Stores that derive state from a payload listen here instead of being called by the session, which keeps the
  // session free of imports from the tab stores that depend on it.
  const dataAppliedListeners = []
  const dataLoadedListeners = []
  const onBusinessDataApplied = (listener) => { dataAppliedListeners.push(listener) }
  const onBusinessDataLoaded = (listener) => { dataLoadedListeners.push(listener) }
  /** Forget the raw tab payload when the computer closes, so a later catalog change does not re-project old tabs. */
  const forgetTabSource = () => { rawTabData = null }

  const isMenuActive = ref(false)
  const isMaintenanceEnabled = ref(false)

  const businessId = computed(() => businessData.value.businessId)

  /** Same facility as businessId but coerced for Lua (number vs string keys on businessContexts). */
  const luaBusinessId = () => {
    const raw = businessId.value
    if (raw === undefined || raw === null || raw === "") return null
    return normalizeId(raw)
  }

  const businessType = computed(() => businessData.value.businessType)

  // Pushed type data (manager.getTypeData) is authoritative; the catalog only covers the moment before it arrives.
  const typeData = computed(() => {
    const pushed = businessData.value
    const declared = businessTypeFacts(pushed.businessType)
    return {
      module: pushed.module ?? declared.module,
      sections: Array.isArray(pushed.sections) ? pushed.sections : declared.sections,
      capabilities: pushed.capabilities ?? declared.capabilities,
      skillNodes: pushed.skillNodes ?? declared.skillNodes,
    }
  })

  const hasCapability = (name) => typeData.value.capabilities?.[name] === true

  const ownerModule = () => moduleNamed(typeData.value.module)

  const businessName = computed(() => businessData.value.businessName || "Business")

  const playerInZone = computed(() => businessData.value.playerInZone !== false)

  const getBusinessVehicleById = (vehicleId) => {
    const list = vehicles.value || []
    return list.find(vehicle => normalizeId(vehicle?.vehicleId) === vehicleId) || null
  }

  const damageLockInfo = computed(() => {
    const vehicle = pulledOutVehicle.value
    return {
      damage: vehicle?.damage ?? businessData.value?.vehicleDamage ?? 0,
      threshold: vehicle?.damageThreshold ?? businessData.value?.vehicleDamageThreshold ?? 1000
    }
  })

  const hasDamageLockedVehicle = computed(() => {
    if (hasCapability("fleetVehicles")) {
      return false
    }
    if (Array.isArray(pulledOutVehicles.value) && pulledOutVehicles.value.length > 0) {
      return pulledOutVehicles.value.some(vehicle => vehicle?.damageLocked)
    }
    return !!businessData.value?.vehicleDamageLocked
  })

  const isDamageLocked = computed(() => hasDamageLockedVehicle.value)

  const showDamageLockWarning = () => {
    const info = damageLockInfo.value
    const damage = Math.round(info.damage || 0)
    const threshold = info.threshold || 1000
    const message = `Vehicle damage (${damage}) exceeds the ${threshold} limit. Abandon the job to continue.`
    try {
      lua.ui_message(message, 5, "Business Computer", "error")
    } catch (error) {
    }
  }

  const normalizeLuaResult = (result) => normalizeLuaResultWith(result, showDamageLockWarning)

  const activeJobs = computed(() => sortActiveJobs(businessData.value.activeJobs))

  const maxActiveJobs = computed(() => businessData.value.maxActiveJobs ?? 2)

  const newJobs = computed(() => sortNewJobs(businessData.value.newJobs))

  const vehicles = computed(() => vehicleList(businessData.value.vehicles))

  const maxPulledOutVehicles = computed(() => businessData.value?.maxPulledOutVehicles ?? 1)

  const parts = computed(() => {
    if (!businessData.value || !businessData.value.parts) return []
    const p = businessData.value.parts
    return Array.isArray(p) ? p : []
  })

  const stats = computed(() => businessData.value.stats || {})

  const personalUseUnlocked = computed(() => businessData.value?.personalUseUnlocked === true)

  const personalVehicles = computed(() => {
    const list = pulledOutVehicles.value || []
    return list.filter(v => v?.isPersonal === true)
  })

  const intake = { businessData, pulledOutVehicles, pulledOutVehicle, activeVehicleId, acceptTabs, dataAppliedListeners }
  const setBusinessData = (data) => {
    if (data == null || typeof data !== "object" || Array.isArray(data) || typeof data.businessId === "boolean") {
      return
    }
    applyBusinessData(intake, data)
  }

  const tabsBySection = computed(() => groupTabsBySection(registeredTabs))

  const readSession = { isMenuActive, isMaintenanceEnabled, businessId, businessData, pulledOutVehicles, hasCapability, setBusinessData, dataLoadedListeners }
  const loadBusinessData = (businessType, targetBusinessId) => loadBusinessDataFor(readSession, businessType, targetBusinessId)

  const getLuaModule = () => {
    if (hasCapability('ownerEndpoints')) {
      return ownerModule()
    }
    return lua.overhaul_career_business_computer
  }

  const requestFinancesData = (type, targetBusinessId) => hasCapability('ownerEndpoints')
    ? ownerModule().requestFinancesData(targetBusinessId)
    : lua.overhaul_career_business_computer.requestFinancesData(type, targetBusinessId)

  return {
    businessData,
    activeView,
    vehicleView,
    pulledOutVehicle,
    pulledOutVehicles,
    activeVehicleId,
    loading,
    registeredTabs,
    isMenuActive,
    isMaintenanceEnabled,
    businessId,
    luaBusinessId,
    businessType,
    typeData,
    hasCapability,
    ownerModule,
    businessName,
    playerInZone,
    getBusinessVehicleById,
    damageLockInfo,
    isDamageLocked,
    showDamageLockWarning,
    normalizeLuaResult,
    activeJobs,
    maxActiveJobs,
    newJobs,
    vehicles,
    maxPulledOutVehicles,
    parts,
    stats,
    personalUseUnlocked,
    personalVehicles,
    tabsBySection,
    loadBusinessData,
    getLuaModule,
    requestFinancesData,
    forgetTabSource,
    onBusinessDataApplied,
    onBusinessDataLoaded
  }
})
