import { computed, ref } from "vue"
import { defineStore } from "pinia"
import { lua } from "@/bridge"
import { useBridge } from "@/bridge"

export const useBusinessComputerStore = defineStore("businessComputer", () => {
  const businessData = ref({})
  const activeView = ref("home")
  const vehicleView = ref(null)
  const pulledOutVehicle = ref(null)
  const pulledOutVehicles = ref([])
  const activeVehicleId = ref(null)
  const loading = ref(false)
  const registeredTabs = ref([])

  const partsCart = ref([])
  const tuningCart = ref([])
  const tuningDataCache = ref({})
  const partsTreeCache = ref({})
  
  const cartTabs = ref([{ id: 'default', name: 'Build 1', parts: [], tuning: [], cartHash: null }])
  const activeTabId = ref('default')
  const originalVehicleState = ref(null)
  const currentAppliedCartHash = ref(null)
  const isSwitchingTab = ref(false)
  
  const originalPower = ref(null)
  const originalWeight = ref(null)
  const currentPower = ref(null)
  const currentWeight = ref(null)

  const businessId = computed(() => businessData.value.businessId)
  const businessType = computed(() => businessData.value.businessType)
  const businessName = computed(() => businessData.value.businessName || "Business")
  const normalizeVehicleIdValue = (id) => {
    if (id === undefined || id === null) return null
    const numeric = Number(id)
    return Number.isNaN(numeric) ? String(id) : numeric
  }
  const normalizeJobIdValue = (jobId) => {
    if (jobId === undefined || jobId === null) {
      return 'nojob'
    }
    return String(jobId)
  }
  const clearCachesForJob = (jobId) => {
    const key = normalizeJobIdValue(jobId)
    if (partsTreeCache.value[key]) {
      delete partsTreeCache.value[key]
    }
    if (tuningDataCache.value[key]) {
      delete tuningDataCache.value[key]
    }
  }
  const getBusinessVehicleById = (vehicleId) => {
    const list = vehicles.value || []
    return list.find(vehicle => normalizeVehicleIdValue(vehicle?.vehicleId) === vehicleId) || null
  }
  const damageLockInfo = computed(() => {
    const vehicle = pulledOutVehicle.value
    return {
      damage: vehicle?.damage ?? businessData.value?.vehicleDamage ?? 0,
      threshold: vehicle?.damageThreshold ?? businessData.value?.vehicleDamageThreshold ?? 1000
    }
  })
  const hasDamageLockedVehicle = computed(() => {
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
      console.warn("Failed to show damage lock warning", error)
    }
  }
  const showErrorMessage = (message) => {
    if (!message) return
    try {
      lua.ui_message(message, 5, "Business Computer", "error")
    } catch (error) {
      console.warn("Failed to show error message", error)
    }
  }
  const normalizeLuaResult = (result) => {
    if (result && typeof result === "object" && result.success === false) {
      if (result.errorCode === "damageLocked") {
        showDamageLockWarning()
      } else if (result.message) {
        showErrorMessage(result.message)
      }
      return false
    }
    return result
  }
  
  const activeJobs = computed(() => {
    const jobs = businessData.value.activeJobs
    return Array.isArray(jobs) ? jobs : []
  })
  const maxActiveJobs = computed(() => businessData.value.maxActiveJobs ?? 2)
  const newJobs = computed(() => {
    const jobs = businessData.value.newJobs
    if (!Array.isArray(jobs)) {
      return []
    }

    const getExpiresInSeconds = (job) => {
      return typeof job?.expiresInSeconds === "number" ? job.expiresInSeconds : Number.POSITIVE_INFINITY
    }

    const getJobSortId = (job) => {
      if (job?.jobId !== undefined) {
        return Number(job.jobId) || job.jobId
      }
      return job?.id || 0
    }

    return [...jobs].sort((a, b) => {
      const expireA = getExpiresInSeconds(a)
      const expireB = getExpiresInSeconds(b)
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
  })
  const techs = computed(() => businessData.value.techs || [])
  const vehicles = computed(() => {
    const v = businessData.value.vehicles
    if (!v) return []
    if (Array.isArray(v)) return v
    if (typeof v === 'object') return Object.values(v)
    return []
  })
  const maxPulledOutVehicles = computed(() => businessData.value?.maxPulledOutVehicles ?? 1)
  const parts = computed(() => {
    if (!businessData.value || !businessData.value.parts) return []
    const p = businessData.value.parts
    return Array.isArray(p) ? p : []
  })
  const stats = computed(() => businessData.value.stats || {})

  const setBusinessData = (data) => {
    const vehiclesFromData = Array.isArray(data?.pulledOutVehicles)
      ? data.pulledOutVehicles
      : (data?.pulledOutVehicle ? [data.pulledOutVehicle] : [])
    pulledOutVehicles.value = vehiclesFromData
    let nextActiveId = data?.activeVehicleId
    if (nextActiveId === undefined || nextActiveId === null) {
      nextActiveId = vehiclesFromData[0]?.vehicleId ?? data?.pulledOutVehicle?.vehicleId ?? null
    }
    activeVehicleId.value = nextActiveId ?? null
    const normalizedActiveId = normalizeVehicleIdValue(nextActiveId)
    let activeEntry = null
    if (normalizedActiveId !== null) {
      activeEntry = vehiclesFromData.find(vehicle => normalizeVehicleIdValue(vehicle?.vehicleId) === normalizedActiveId) || null
    }
    if (!activeEntry && data?.pulledOutVehicle) {
      activeEntry = data.pulledOutVehicle
    }
    pulledOutVehicle.value = activeEntry || null
    const payload = {
      ...data,
      pulledOutVehicle: activeEntry,
      pulledOutVehicles: vehiclesFromData
    }
    businessData.value = payload
    if (payload.tabs) {
      registeredTabs.value = payload.tabs
    }
  }

  const tabsBySection = computed(() => {
    const sections = {}
    registeredTabs.value.forEach(tab => {
      const section = tab.section || 'BASIC'
      if (!sections[section]) {
        sections[section] = []
      }
      sections[section].push(tab)
    })
    return sections
  })

  const loadBusinessData = async (businessType, businessId) => {
    loading.value = true
    try {
      const data = await lua.career_modules_business_businessComputer.getBusinessComputerUIData(businessType, businessId)
      setBusinessData(data)
    } catch (error) {
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
      return false
    }
  }

  const assignTechToJob = async (techId, jobId) => {
    if (!businessId.value) return false
    try {
      const success = await lua.career_modules_business_businessComputer.assignTechToJob(businessId.value, techId, jobId)
      if (success) {
        await loadBusinessData(businessType.value, businessId.value)
      }
      return success
    } catch (error) {
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
      return false
    }
  }

  const completeJob = async (jobId) => {
    if (!businessId.value) return false
    try {
      const success = await lua.career_modules_business_businessComputer.completeJob(businessId.value, jobId)
      if (success) {
        pulledOutVehicle.value = null
        await loadBusinessData(businessType.value, businessId.value)
      }
      return success
    } catch (error) {
      return false
    }
  }

  const renameTech = async (techId, newName) => {
    if (!businessId.value) return false
    try {
      const success = await lua.career_modules_business_businessComputer.renameTech(businessId.value, techId, newName ?? "")
      return success
    } catch (error) {
      return false
    }
  }

  const pullOutVehicle = async (vehicleId) => {
    if (!businessId.value) {
      return false
    }
    if (isDamageLocked.value) {
      showDamageLockWarning()
      return false
    }
    try {
      const success = normalizeLuaResult(await lua.career_modules_business_businessComputer.pullOutVehicle(businessId.value, vehicleId))
      if (success) {
        await loadBusinessData(businessType.value, businessId.value)
      }
      return !!success
    } catch (error) {
      return false
    }
  }

  const putAwayVehicle = async (vehicleId) => {
    if (!businessId.value) return false
    if (isDamageLocked.value) {
      showDamageLockWarning()
      return false
    }
    try {
      const targetVehicleId = vehicleId ?? pulledOutVehicle.value?.vehicleId ?? null
      const normalizedTargetId = normalizeVehicleIdValue(targetVehicleId)
      const targetVehicleEntry = normalizedTargetId ? getBusinessVehicleById(normalizedTargetId) : null
      const targetJobId = targetVehicleEntry?.jobId
      const success = normalizeLuaResult(await lua.career_modules_business_businessComputer.putAwayVehicle(businessId.value, targetVehicleId))
      if (success) {
        clearCachesForJob(targetJobId)
        try {
          lua.career_modules_business_businessComputer.clearVehicleDataCaches()
        } catch (error) {
        }
        
        if (!vehicleId || normalizeVehicleIdValue(vehicleId) === normalizeVehicleIdValue(pulledOutVehicle.value?.vehicleId)) {
          pulledOutVehicle.value = null
          activeVehicleId.value = null
        }
        await loadBusinessData(businessType.value, businessId.value)
      }
      return !!success
    } catch (error) {
      return false
    }
  }

  const setActiveVehicleSelection = async (vehicleId) => {
    if (!businessId.value || vehicleId === undefined || vehicleId === null) {
      return false
    }
    const normalizedTarget = normalizeVehicleIdValue(vehicleId)
    if (normalizeVehicleIdValue(activeVehicleId.value) === normalizedTarget) {
      return true
    }
    
    const previousVehicleId = activeVehicleId.value
    
    try {
      const success = normalizeLuaResult(await lua.career_modules_business_businessComputer.setActiveVehicle(businessId.value, vehicleId))
      if (success) {
        if (previousVehicleId && businessId.value && previousVehicleId !== normalizedTarget) {
          try {
            await lua.career_modules_business_businessComputer.resetVehicleToOriginal(
              businessId.value,
              previousVehicleId
            )
            await lua.career_modules_business_businessPartCustomization.clearPreviewVehicle(businessId.value)
          } catch (error) {
          }
        }
        clearCart()
        
        originalPower.value = null
        originalWeight.value = null
        currentPower.value = null
        currentWeight.value = null
        originalVehicleState.value = null
        
        activeVehicleId.value = vehicleId
        const vehiclesList = Array.isArray(pulledOutVehicles.value) ? pulledOutVehicles.value : []
        let selectedVehicle = vehiclesList.find(vehicle => normalizeVehicleIdValue(vehicle?.vehicleId) === normalizedTarget) || null
        const requiresRefresh = !selectedVehicle || selectedVehicle.jobId === undefined || selectedVehicle.jobId === null
        pulledOutVehicle.value = selectedVehicle
        businessData.value = {
          ...businessData.value,
          pulledOutVehicle: selectedVehicle
        }
        
        if (requiresRefresh && businessType.value && businessId.value) {
          try {
            await loadBusinessData(businessType.value, businessId.value)
            const refreshedList = Array.isArray(pulledOutVehicles.value) ? pulledOutVehicles.value : []
            selectedVehicle = refreshedList.find(vehicle => normalizeVehicleIdValue(vehicle?.vehicleId) === normalizedTarget) || null
            pulledOutVehicle.value = selectedVehicle
          } catch (error) {
          }
        }
        
        if (selectedVehicle && (vehicleView.value === 'parts' || vehicleView.value === 'tuning')) {
          setTimeout(async () => {
            if (vehicleView.value === 'parts' && selectedVehicle?.vehicleId) {
              await initializeCartForVehicle()
              await requestVehiclePartsTree(selectedVehicle.vehicleId)
            } else if (vehicleView.value === 'tuning' && selectedVehicle?.vehicleId) {
              await initializeCartForVehicle()
              await requestVehicleTuningData(selectedVehicle.vehicleId)
            }
          }, 100)
        }
      }
      return !!success
    } catch (error) {
      return false
    }
  }

  const switchView = async (view) => {
    activeView.value = view
    vehicleView.value = null

    const shouldRefresh =
      (view === "jobs" || view === "home") &&
      businessId.value &&
      businessType.value

    if (shouldRefresh) {
      try {
        await loadBusinessData(businessType.value, businessId.value)
      } catch (error) {
      }
    }
  }

  const switchVehicleView = async (view) => {
    if ((view === 'parts' || view === 'tuning') && isDamageLocked.value) {
      showDamageLockWarning()
      return
    }
    const previousView = vehicleView.value
    
    const isSwitchingBetweenVehicleViews = (previousView === 'parts' || previousView === 'tuning') && (view === 'parts' || view === 'tuning')
    const isLeavingVehicleViews = previousView !== null && !isSwitchingBetweenVehicleViews && (view !== 'parts' && view !== 'tuning')
    
    if (isLeavingVehicleViews) {
      clearCart()
      if (businessId.value && pulledOutVehicle.value?.vehicleId) {
        try {
          await lua.career_modules_business_businessComputer.resetVehicleToOriginal(
            businessId.value,
            pulledOutVehicle.value.vehicleId
          )
          await lua.career_modules_business_businessPartCustomization.clearPreviewVehicle(businessId.value)
        } catch (error) {
        }
      }
    }
    
    const enteringPartsViewFromNonVehicle = view === 'parts' && previousView !== 'parts' && previousView !== 'tuning'
    
    vehicleView.value = view
    
    if (enteringPartsViewFromNonVehicle) {
      setTimeout(async () => {
        if (vehicleView.value === 'parts') {
          await initializeCartForVehicle()
        }
      }, 600)
    }
    
    if (view === 'tuning' && previousView !== 'tuning') {
      setTimeout(async () => {
        if (vehicleView.value === 'tuning' && pulledOutVehicle.value?.vehicleId) {
          const cart = Array.isArray(tuningCart.value) ? tuningCart.value : []
          if (cart.length > 0) {
            const tuningVars = {}
            cart.forEach(change => {
              if (change.type === 'variable' && change.varName && change.value !== undefined) {
                tuningVars[change.varName] = change.value
              }
            })
            try {
              await lua.career_modules_business_businessComputer.applyTuningToVehicle(
                businessId.value,
                pulledOutVehicle.value.vehicleId,
                tuningVars
              )
            } catch (error) {
            }
          }
          await requestVehicleTuningData(pulledOutVehicle.value.vehicleId)
        }
      }, 600)
    }
    
    if (view === 'parts' && previousView === 'tuning') {
      setTimeout(async () => {
        if (vehicleView.value === 'parts' && pulledOutVehicle.value?.vehicleId && partsCart.value.length > 0) {
          await requestVehiclePartsTree(pulledOutVehicle.value.vehicleId)
        }
      }, 600)
    }
  }

  const closeVehicleView = async () => {
    if (vehicleView.value === 'parts' || vehicleView.value === 'tuning') {
      clearCart()
      if (businessId.value && pulledOutVehicle.value?.vehicleId) {
        try {
          await lua.career_modules_business_businessComputer.resetVehicleToOriginal(
            businessId.value,
            pulledOutVehicle.value.vehicleId
          )
          await lua.career_modules_business_businessPartCustomization.clearPreviewVehicle(businessId.value)
        } catch (error) {
        }
      }
    }
    vehicleView.value = null
  }

  const onMenuClosed = () => {
    clearCart()
    partsTreeCache.value = {}
    tuningDataCache.value = {}
    
    if (businessId.value) {
      try {
        lua.career_modules_business_businessPartCustomization.clearPreviewVehicle(businessId.value)
      } catch (error) {
      }
    }
    
    activeView.value = "home"
    vehicleView.value = null
    pulledOutVehicle.value = null
    try {
      lua.career_modules_business_businessComputer.clearVehicleDataCaches()
    } catch (error) {
    }
  }

  const requestVehiclePartsTree = async (vehicleId) => {
    if (!businessId.value || !vehicleId) return null
    
    try {
      await lua.career_modules_business_businessComputer.requestVehiclePartsTree(businessId.value, vehicleId)
      return null
    } catch (error) {
      return null
    }
  }

  const requestPartInventory = async () => {
    if (!businessId.value) return null

    try {
      await lua.career_modules_business_businessComputer.requestPartInventory(businessId.value)
      return null
    } catch (error) {
      return null
    }
  }

  const requestVehicleTuningData = async (vehicleId) => {
    if (!businessId.value || !vehicleId) return null
    if (isDamageLocked.value) {
      showDamageLockWarning()
      return null
    }
    
    try {
      await lua.career_modules_business_businessComputer.requestVehicleTuningData(businessId.value, vehicleId)
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
      const success = await lua.career_modules_business_businessComputer.applyVehicleTuning(businessId.value, vehicleId, tuningVars)
      return success
    } catch (error) {
      return false
    }
  }

  const generateCartHash = (parts, tuning) => {
    const partsData = (parts || []).map(p => ({
      slotPath: p.slotPath || '',
      partName: p.partName || '',
      emptyPlaceholder: p.emptyPlaceholder || false
    })).sort((a, b) => (a.slotPath + a.partName).localeCompare(b.slotPath + b.partName))
    
    const tuningData = (tuning || []).filter(t => t.type === 'variable' && t.varName && t.value !== undefined)
      .map(t => ({
        varName: t.varName || '',
        value: t.value
      })).sort((a, b) => a.varName.localeCompare(b.varName))
    
    const hashString = JSON.stringify({ parts: partsData, tuning: tuningData })
    
    let hash = 0
    for (let i = 0; i < hashString.length; i++) {
      const char = hashString.charCodeAt(i)
      hash = ((hash << 5) - hash) + char
      hash = hash & hash
    }
    return hash.toString(36)
  }
  
  const saveCurrentTabState = () => {
    const activeTab = cartTabs.value.find(tab => tab.id === activeTabId.value)
    if (activeTab) {
      activeTab.parts = JSON.parse(JSON.stringify(partsCart.value))
      activeTab.tuning = JSON.parse(JSON.stringify(tuningCart.value))
      activeTab.cartHash = generateCartHash(activeTab.parts, activeTab.tuning)
    }
  }
  
  const loadTabState = (tabId) => {
    const tab = cartTabs.value.find(t => t.id === tabId)
    if (tab) {
      partsCart.value = JSON.parse(JSON.stringify(tab.parts || []))
      tuningCart.value = JSON.parse(JSON.stringify(tab.tuning || []))
      if (!tab.cartHash) {
        tab.cartHash = generateCartHash(tab.parts || [], tab.tuning || [])
      }
    }
  }
  
  const getCurrentTabHash = () => {
    const activeTab = cartTabs.value.find(tab => tab.id === activeTabId.value)
    if (activeTab && activeTab.cartHash) {
      return activeTab.cartHash
    }
    return generateCartHash(partsCart.value, tuningCart.value)
  }
  
  const isCurrentTabApplied = computed(() => {
    const activeTab = cartTabs.value.find(tab => tab.id === activeTabId.value)
    if (!activeTab || !currentAppliedCartHash.value) return false
    const tabHash = activeTab.cartHash || generateCartHash(activeTab.parts || [], activeTab.tuning || [])
    return currentAppliedCartHash.value === tabHash
  })
  
  const createNewTab = async () => {
    try {
      saveCurrentTabState()
      
      const existingNumbers = new Set()
      cartTabs.value.forEach(tab => {
        const match = tab.name.match(/^Build (\d+)$/)
        if (match) {
          existingNumbers.add(parseInt(match[1], 10))
        }
      })
      
      let newTabNumber = 1
      while (existingNumbers.has(newTabNumber)) {
        newTabNumber++
      }
      
      const newTab = {
        id: `tab_${Date.now()}`,
        name: `Build ${newTabNumber}`,
        parts: [],
        tuning: [],
        cartHash: generateCartHash([], [])
      }
      
      cartTabs.value.push(newTab)
      activeTabId.value = newTab.id
      
      partsCart.value = []
      tuningCart.value = []
      currentAppliedCartHash.value = generateCartHash([], [])
      
      if (businessId.value && pulledOutVehicle.value?.vehicleId) {
        try {
          await lua.career_modules_business_businessComputer.resetVehicleToOriginal(
            businessId.value,
            pulledOutVehicle.value.vehicleId
          )
        } catch (error) {
        }
      }
    } catch (error) {
      if (cartTabs.value.length > 0 && cartTabs.value[cartTabs.value.length - 1].id === activeTabId.value) {
        cartTabs.value.pop()
        if (cartTabs.value.length > 0) {
          activeTabId.value = cartTabs.value[0].id
          loadTabState(activeTabId.value)
        }
      }
    }
  }
  
  const switchTab = async (tabId) => {
    if (tabId === activeTabId.value) return
    if (isSwitchingTab.value) return
    
    isSwitchingTab.value = true
    
    try {
      saveCurrentTabState()
      
      const targetTab = cartTabs.value.find(t => t.id === tabId)
      if (!targetTab) {
        isSwitchingTab.value = false
        return
      }
      
      const targetHash = targetTab.cartHash || generateCartHash(targetTab.parts || [], targetTab.tuning || [])
      
      if (businessId.value && pulledOutVehicle.value?.vehicleId && currentAppliedCartHash.value === targetHash) {
        activeTabId.value = tabId
        isSwitchingTab.value = false
        return
      }
      
      activeTabId.value = tabId
      loadTabState(tabId)
      
      if (businessId.value && pulledOutVehicle.value?.vehicleId) {
        
        try {
          await lua.career_modules_business_businessComputer.applyCartPartsToVehicle(
            businessId.value,
            pulledOutVehicle.value.vehicleId,
            partsCart.value
          )
          
          const tuningVars = {}
          const cart = Array.isArray(tuningCart.value) ? tuningCart.value : []
          cart.forEach(change => {
            if (change.type === 'variable' && change.varName && change.value !== undefined) {
              tuningVars[change.varName] = change.value
            }
          })
          await lua.career_modules_business_businessComputer.applyTuningToVehicle(
            businessId.value,
            pulledOutVehicle.value.vehicleId,
            tuningVars
          )
          
          currentAppliedCartHash.value = targetHash
          
          setTimeout(() => {
            if (vehicleView.value === 'parts') {
              requestVehiclePartsTree(pulledOutVehicle.value.vehicleId)
            }
            if (vehicleView.value === 'tuning') {
              requestVehicleTuningData(pulledOutVehicle.value.vehicleId)
            }
          }, 100)
        } catch (error) {
        }
      }
    } finally {
      isSwitchingTab.value = false
    }
  }
  
  const deleteTab = (tabId) => {
    if (cartTabs.value.length <= 1) return
    
    const index = cartTabs.value.findIndex(tab => tab.id === tabId)
    if (index < 0) return
    
    cartTabs.value.splice(index, 1)
    
    if (activeTabId.value === tabId) {
      activeTabId.value = cartTabs.value[0].id
      loadTabState(activeTabId.value)
    }
  }
  
  const duplicateTab = async (tabId) => {
    const tab = cartTabs.value.find(t => t.id === tabId)
    if (!tab) return
    
    saveCurrentTabState()
    
    const isDuplicatingActiveTab = tabId === activeTabId.value
    const currentParts = JSON.stringify(partsCart.value)
    const currentTuning = JSON.stringify(tuningCart.value)
    const tabParts = JSON.stringify(tab.parts || [])
    const tabTuning = JSON.stringify(tab.tuning || [])
    const hasSameContent = isDuplicatingActiveTab && 
                           currentParts === tabParts && 
                           currentTuning === tabTuning
    
    let maxNumber = 0
    cartTabs.value.forEach(t => {
      const match = t.name.match(/^Build (\d+)$/)
      if (match) {
        const num = parseInt(match[1], 10)
        if (num > maxNumber) maxNumber = num
      }
    })
    const newTabNumber = maxNumber + 1
    
    const duplicatedTab = {
      id: `tab_${Date.now()}`,
      name: `Build ${newTabNumber}`,
      parts: JSON.parse(JSON.stringify(tab.parts || [])),
      tuning: JSON.parse(JSON.stringify(tab.tuning || [])),
      cartHash: generateCartHash(tab.parts || [], tab.tuning || [])
    }
    
    cartTabs.value.push(duplicatedTab)
    activeTabId.value = duplicatedTab.id
    
    loadTabState(duplicatedTab.id)
    
    if (!hasSameContent && businessId.value && pulledOutVehicle.value?.vehicleId) {
      try {
        await lua.career_modules_business_businessComputer.resetVehicleToOriginal(
          businessId.value,
          pulledOutVehicle.value.vehicleId
        )
        
        if (partsCart.value.length > 0) {
          await lua.career_modules_business_businessComputer.applyCartPartsToVehicle(
            businessId.value,
            pulledOutVehicle.value.vehicleId,
            partsCart.value
          )
        }
        
        const cart = Array.isArray(tuningCart.value) ? tuningCart.value : []
        if (cart.length > 0) {
          const tuningVars = {}
          cart.forEach(change => {
            if (change.type === 'variable' && change.varName && change.value !== undefined) {
              tuningVars[change.varName] = change.value
            }
          })
          await lua.career_modules_business_businessComputer.applyTuningToVehicle(
            businessId.value,
            pulledOutVehicle.value.vehicleId,
            tuningVars
          )
        }
        
        currentAppliedCartHash.value = generateCartHash(partsCart.value, tuningCart.value)
      } catch (error) {
      }
    } else if (hasSameContent) {
      currentAppliedCartHash.value = generateCartHash(partsCart.value, tuningCart.value)
    }
  }
  
  const renameTab = (tabId, newName) => {
    const tab = cartTabs.value.find(t => t.id === tabId)
    if (!tab) return
    
    const trimmedName = (newName || '').trim()
    if (!trimmedName || trimmedName.length === 0) return
    
    tab.name = trimmedName
    saveCurrentTabState()
  }
  
  const { events } = useBridge()
  
  const handlePartCartUpdated = (data) => {
    if (data.businessId === businessId.value && data.vehicleId === pulledOutVehicle.value?.vehicleId) {
      if (data.cart && Array.isArray(data.cart)) {
        partsCart.value = data.cart.map(item => ({
          ...item,
          id: `${item.slotPath}_${item.partName}`,
          canRemove: item.canRemove !== false
        }))
        saveCurrentTabState()
        currentAppliedCartHash.value = generateCartHash(partsCart.value, tuningCart.value)
        
        setTimeout(() => {
          if (vehicleView.value === 'parts') {
            requestVehiclePartsTree(pulledOutVehicle.value.vehicleId)
          }
          if (vehicleView.value === 'tuning') {
            requestVehicleTuningData(pulledOutVehicle.value.vehicleId)
          }
        }, 100)
      }
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

    // Prevent updates if user is working on a vehicle
    if (vehicleView.value) {
      return
    }

    // Prevent updates if user is in a tab that doesn't display job lists
    const allowedViews = ['home', 'jobs', 'techs']
    if (!allowedViews.includes(activeView.value)) {
      return
    }

    try {
      await loadBusinessData(currentBusinessType, currentBusinessId)
    } catch (error) {
    }
  }

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
    businessData.value = {
      ...businessData.value,
      techs: data.techs
    }
  }
}

  const handlePartInventoryData = (data) => {
    const currentBusinessId = businessId.value
    if (!currentBusinessId) return

    if (!data || !data.success) return
    if (String(data.businessId) !== String(currentBusinessId)) return

    const partsByModel = data.partsByModel || {}
    const mappedParts = []

    Object.entries(partsByModel).forEach(([model, list]) => {
      if (!Array.isArray(list)) return
      list.forEach(p => {
        if (!p) return
        const c = p.partCondition || {}
        const integrity = typeof c.integrityValue === "number" ? c.integrityValue : 1
        let condition = "Good"
        if (integrity >= 0.9) condition = "Excellent"
        else if (integrity >= 0.75) condition = "Good"
        else if (integrity >= 0.5) condition = "Fair"
        else condition = "Poor"

        const odo = typeof c.odometer === "number" ? c.odometer : 0
        const mileage = Math.max(0, Math.round(odo / 1609.344))

        const price = p.finalValue || p.value || 0

        mappedParts.push({
          partId: p.partId,
          name: p.niceName || p.name,
          compatibleVehicle: p.vehicleNiceName || model,
          condition,
          mileage,
          price,
          value: price
        })
      })
    })

    businessData.value = {
      ...businessData.value,
      parts: mappedParts
    }
  }

  // Setup event listener
  events.on('businessComputer:onPartCartUpdated', handlePartCartUpdated)
  events.on('businessComputer:onJobsUpdated', handleJobsUpdated)
  events.on('businessComputer:onTechsUpdated', handleTechsUpdated)
  events.on('businessComputer:onPartInventoryData', handlePartInventoryData)
  
  const addPartToCart = async (part, slot) => {
    if (!businessId.value || !pulledOutVehicle.value?.vehicleId) {
      return
    }
    if (isDamageLocked.value) {
      showDamageLockWarning()
      return
    }
    
    const partToAdd = {
      partName: part.name,
      partNiceName: part.niceName,
      slotPath: slot.path,
      slotNiceName: slot.slotNiceName || slot.slotName,
      price: part.value || 0
    }
    
    try {
      const tempCart = await lua.career_modules_business_businessComputer.addPartToCart(
        businessId.value,
        pulledOutVehicle.value.vehicleId,
        partsCart.value,
        partToAdd
      )
      
      if (tempCart && Array.isArray(tempCart)) {
        partsCart.value = tempCart.map(item => ({
          ...item,
          id: `${item.slotPath}_${item.partName}`
        }))
        saveCurrentTabState()
        currentAppliedCartHash.value = generateCartHash(partsCart.value, tuningCart.value)
      }
    } catch (error) {
    }
    
    saveCurrentTabState()
  }

  const removePartFromCart = async (itemId) => {
    if (isDamageLocked.value) {
      showDamageLockWarning()
      return
    }
    const tree = buildPartsTree(partsCart.value)
    
    const collectChildIds = (node, targetId, collectedIds = []) => {
      if (node.id === targetId) {
        const collectAllChildren = (childNode) => {
          collectedIds.push(childNode.id)
          if (childNode.children && childNode.children.length > 0) {
            for (const grandchild of childNode.children) {
              collectAllChildren(grandchild)
            }
          }
        }
        if (node.children && node.children.length > 0) {
          for (const child of node.children) {
            collectAllChildren(child)
          }
        }
        return true
      }
      
      if (node.children && node.children.length > 0) {
        for (const child of node.children) {
          if (collectChildIds(child, targetId, collectedIds)) {
            return true
          }
        }
      }
      return false
    }
    
    const idsToRemove = [itemId]
    for (const rootNode of tree) {
      collectChildIds(rootNode, itemId, idsToRemove)
    }
    
    partsCart.value = partsCart.value.filter(item => !idsToRemove.includes(item.id))
    saveCurrentTabState()
    
    if (businessId.value && pulledOutVehicle.value?.vehicleId) {
      try {
        await lua.career_modules_business_businessComputer.applyCartPartsToVehicle(
          businessId.value,
          pulledOutVehicle.value.vehicleId,
          partsCart.value
        )
        
        setTimeout(async () => {
          try {
            await store.requestVehiclePartsTree(pulledOutVehicle.value.vehicleId)
          } catch (error) {
          }
        }, 500)
      } catch (error) {
      }
    }
  }
  
  const removePartBySlotPath = async (slotPath) => {
    if (isDamageLocked.value) {
      showDamageLockWarning()
      return
    }
    let normalizedPath = (slotPath || '').trim()
    if (!normalizedPath.startsWith('/')) {
      normalizedPath = '/' + normalizedPath
    }
    if (!normalizedPath.endsWith('/')) {
      normalizedPath = normalizedPath + '/'
    }
    
    const partToRemove = partsCart.value.find(item => {
      const itemPath = (item.slotPath || '').trim()
      return itemPath === normalizedPath
    })
    
    if (partToRemove) {
      const tree = buildPartsTree(partsCart.value)
      const idsToRemove = [partToRemove.id]
      
      const collectChildIds = (node, targetId, collectedIds = []) => {
        if (node.id === targetId) {
          const collectAllChildren = (childNode) => {
            collectedIds.push(childNode.id)
            if (childNode.children && childNode.children.length > 0) {
              for (const grandchild of childNode.children) {
                collectAllChildren(grandchild)
              }
            }
          }
          if (node.children && node.children.length > 0) {
            for (const child of node.children) {
              collectAllChildren(child)
            }
          }
          return true
        }
        if (node.children && node.children.length > 0) {
          for (const child of node.children) {
            if (collectChildIds(child, targetId, collectedIds)) {
              return true
            }
          }
        }
        return false
      }
      
      for (const rootNode of tree) {
        collectChildIds(rootNode, partToRemove.id, idsToRemove)
      }
      
      const partsToAddToInventory = partsCart.value.filter(item => idsToRemove.includes(item.id))
      
      partsCart.value = partsCart.value.filter(item => !idsToRemove.includes(item.id))
      saveCurrentTabState()
      currentAppliedCartHash.value = generateCartHash(partsCart.value, tuningCart.value)
      
      if (businessId.value && pulledOutVehicle.value?.vehicleId) {
        try {
          await lua.career_modules_business_businessComputer.applyCartPartsToVehicle(
            businessId.value,
            pulledOutVehicle.value.vehicleId,
            partsCart.value
          )
          
          setTimeout(async () => {
            try {
              await store.requestVehiclePartsTree(pulledOutVehicle.value.vehicleId)
            } catch (error) {
            }
          }, 500)
        } catch (error) {
        }
      }
    } else {
      if (businessId.value && pulledOutVehicle.value?.vehicleId) {
        try {
          const initialVehicle = await lua.career_modules_business_businessPartCustomization.getInitialVehicleState(businessId.value)
          if (initialVehicle && initialVehicle.partList && initialVehicle.partList[normalizedPath]) {
            const initialPartName = initialVehicle.partList[normalizedPath]
            if (initialPartName && initialPartName !== '') {
              const collectChildSlotPaths = (node, parentPath, collectedPaths = []) => {
                if (!node || !node.children) return collectedPaths
                
                for (const slotName in node.children) {
                  if (node.children.hasOwnProperty(slotName)) {
                    const childNode = node.children[slotName]
                    const childPath = parentPath + slotName + '/'
                    if (childNode && childNode.chosenPartName && childNode.chosenPartName !== '') {
                      collectedPaths.push(childPath)
                      if (childNode.children) {
                        collectChildSlotPaths(childNode, childPath, collectedPaths)
                      }
                    }
                  }
                }
                return collectedPaths
              }
              
              const childPaths = []
              const node = getNodeFromSlotPath(initialVehicle.config.partsTree, normalizedPath)
              if (node) {
                collectChildSlotPaths(node, normalizedPath, childPaths)
              }
              
              const getPartNiceName = (partName, partsNiceName) => {
                if (partsNiceName && partsNiceName[partName]) {
                  const niceName = partsNiceName[partName]
                  return typeof niceName === 'object' ? (niceName.description || niceName) : niceName
                }
                return partName
              }
              
              const partNiceName = getPartNiceName(initialPartName, initialVehicle.partsNiceName || {})
              const removalMarkers = [
                {
                  type: 'part',
                  partName: '',
                  partNiceName: `Removed ${partNiceName}`,
                  slotPath: normalizedPath,
                  slotNiceName: '',
                  price: 0,
                  emptyPlaceholder: true,
                  id: `${normalizedPath}_empty`
                }
              ]
              
              for (const childPath of childPaths) {
                const childPartName = initialVehicle.partList[childPath]
                if (childPartName && childPartName !== '') {
                  const childPartNiceName = getPartNiceName(childPartName, initialVehicle.partsNiceName || {})
                  removalMarkers.push({
                    type: 'part',
                    partName: '',
                    partNiceName: `Removed ${childPartNiceName}`,
                    slotPath: childPath,
                    slotNiceName: '',
                    price: 0,
                    emptyPlaceholder: true,
                    id: `${childPath}_empty`
                  })
                }
              }
              
              partsCart.value = [...partsCart.value, ...removalMarkers]
              saveCurrentTabState()
              currentAppliedCartHash.value = generateCartHash(partsCart.value, tuningCart.value)
              
              await lua.career_modules_business_businessComputer.applyCartPartsToVehicle(
                businessId.value,
                pulledOutVehicle.value.vehicleId,
                partsCart.value
              )
              
              setTimeout(async () => {
                try {
                  await requestVehiclePartsTree(pulledOutVehicle.value.vehicleId)
                } catch (error) {
                }
              }, 500)
            }
          }
        } catch (error) {
        }
      }
    }
  }
  
  const getNodeFromSlotPath = (tree, path) => {
    if (!tree || !path) return null
    if (path === '/') return tree
    
    const segments = path.split('/').filter(p => p)
    let currentNode = tree
    
    for (const segment of segments) {
      if (currentNode.children && currentNode.children[segment]) {
        currentNode = currentNode.children[segment]
      } else {
        return null
      }
    }
    
    return currentNode
  }
  
  const removeTuningFromCart = (varName) => {
    const index = tuningCart.value.findIndex(item => item.varName === varName)
    if (index >= 0) {
      tuningCart.value.splice(index, 1)
      saveCurrentTabState()
      currentAppliedCartHash.value = generateCartHash(partsCart.value, tuningCart.value)
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
          if (varData.valDis !== undefined) {
            baselineValue = varData.valDis
          } else if (varData.val !== undefined) {
            baselineValue = varData.val
          } else {
            continue
          }
          
          // Convert wheel alignment values from slider range to actual range
          if (varData.category === "Wheel Alignment" && (varData.unit === '%' || varData.unit === 'percent')) {
            const actualMin = varData.min ?? 0
            const actualMax = varData.max ?? 100
            const range = actualMax - actualMin
            if (range > 0) {
              // Round slider value to nearest 0.01 step first to avoid precision issues
              const roundedSliderValue = Math.round(baselineValue / 0.01) * 0.01
              baselineValue = ((roundedSliderValue + 1) / 2) * range + actualMin
            } else {
              baselineValue = actualMin
            }
          }
          
          baselineVars[varName] = baselineValue
        }
      }
    }
    
    try {
      const cartItems = await lua.career_modules_business_businessComputer.addTuningToCart(
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

  const clearCart = () => {
    // Reset to a single default tab with empty cart
    cartTabs.value = [{ id: 'default', name: 'Build 1', parts: [], tuning: [], cartHash: generateCartHash([], []) }]
    activeTabId.value = 'default'
    partsCart.value = []
    tuningCart.value = []
    currentAppliedCartHash.value = null
  }
  
  const handlePowerWeightData = (data) => {
    if (!data || !data.success) return
    
    // Only update if it's for the current vehicle
    if (data.businessId === businessId.value && data.vehicleId === pulledOutVehicle.value?.vehicleId) {
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
    
    originalPower.value = null
    originalWeight.value = null
    currentPower.value = null
    currentWeight.value = null
    
    if (businessId.value && pulledOutVehicle.value?.vehicleId) {
      try {
        await lua.career_modules_business_businessComputer.resetVehicleToOriginal(
          businessId.value,
          pulledOutVehicle.value.vehicleId
        )
      } catch (error) {
      }
    }
  }
  
  const updatePowerWeight = async () => {
    if (!businessId.value || !pulledOutVehicle.value?.vehicleId) return
    if (isDamageLocked.value) {
      showDamageLockWarning()
      return
    }
    
    try {
      lua.career_modules_business_businessComputer.getVehiclePowerWeight(
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
  
  const buildPartsTree = (parts) => {
    if (!parts || parts.length === 0) return []
    
    const partMap = new Map()
    parts.forEach(part => {
      const path = (part.slotPath || '').trim()
      if (path) {
        partMap.set(path, {
          ...part,
          children: [],
          path: path
        })
      }
    })
    
    const getParentPath = (path) => {
      const pathParts = path.split('/').filter(p => p)
      if (pathParts.length <= 1) return null
      return '/' + pathParts.slice(0, -1).join('/') + '/'
    }
    
    const rootNodes = []
    
    partMap.forEach((part, path) => {
      const parentPath = getParentPath(path)
      
      if (!parentPath) {
        rootNodes.push(part)
      } else {
        const parent = partMap.get(parentPath)
        if (parent) {
          if (!parent.children) parent.children = []
          parent.children.push(part)
        } else {
          rootNodes.push(part)
        }
      }
    })
    
    const sortNode = (node) => {
      if (node.children && node.children.length > 0) {
        node.children.forEach(child => sortNode(child))
        node.children.sort((a, b) => {
          const nameA = (a.partNiceName || a.partName || a.slotNiceName || '').toLowerCase()
          const nameB = (b.partNiceName || b.partName || b.slotNiceName || '').toLowerCase()
          return nameA.localeCompare(nameB)
        })
      }
    }
    
    rootNodes.forEach(node => sortNode(node))
    
    return rootNodes.sort((a, b) => {
      const nameA = (a.partNiceName || a.partName || a.slotNiceName || '').toLowerCase()
      const nameB = (b.partNiceName || b.partName || b.slotNiceName || '').toLowerCase()
      return nameA.localeCompare(nameB)
    })
  }
  
  const partsTree = computed(() => {
    return buildPartsTree(partsCart.value)
  })

  const getCartTotal = computed(() => {
    let total = 0
    
    const parts = Array.isArray(partsCart.value) ? partsCart.value : []
    parts.forEach(item => {
      total += item.price || 0
    })
    
    const tuning = Array.isArray(tuningCart.value) ? tuningCart.value : []
    tuning.forEach(item => {
      total += item.price || 0
    })
    
    return total
  })
  
  const tuningCost = computed(() => {
    const tuning = Array.isArray(tuningCart.value) ? tuningCart.value : []
    return tuning.reduce((sum, item) => sum + (item.price || 0), 0)
  })

  const skillTreeProgress = ref({})

  const loadSkillTrees = async (businessId) => {
    return []
  }

  const purchaseSkillUpgrade = async (treeId, nodeId) => {
    return false
  }

  const getTotalUpgradesInTree = async (treeId) => {
    return 0
  }

  return {
    businessData,
    activeView,
    vehicleView,
    pulledOutVehicle,
    pulledOutVehicles,
    activeVehicleId,
    loading,
    registeredTabs,
    tabsBySection,
    businessId,
    businessType,
    businessName,
    damageLockInfo,
    isDamageLocked,
    activeJobs,
    maxActiveJobs,
    newJobs,
    vehicles,
    parts,
    stats,
    loadBusinessData,
    acceptJob,
    declineJob,
    abandonJob,
    completeJob,
    pullOutVehicle,
    putAwayVehicle,
    setActiveVehicleSelection,
    switchView,
    switchVehicleView,
    closeVehicleView,
    onMenuClosed,
    requestVehiclePartsTree,
    requestVehicleTuningData,
    requestPartInventory,
    applyVehicleTuning,
    partsCart,
    tuningCart,
    addPartToCart,
    removePartFromCart,
    removePartBySlotPath,
    addTuningToCart,
    removeTuningFromCart,
    clearCart,
    clearCachesForJob,
    getCartTotal,
    tuningCost,
    tuningDataCache,
    partsTreeCache,
    cartTabs,
    activeTabId,
    originalVehicleState,
    createNewTab,
    switchTab,
    deleteTab,
    duplicateTab,
    renameTab,
    initializeCartForVehicle,
    buildPartsTree,
    partsTree,
    originalPower,
    originalWeight,
    currentPower,
    currentWeight,
    powerToWeightRatio,
    originalPowerToWeightRatio,
    powerChange,
    weightChange,
    updatePowerWeight,
    handlePowerWeightData,
    isCurrentTabApplied,
    skillTreeProgress,
    loadSkillTrees,
    purchaseSkillUpgrade,
    getTotalUpgradesInTree,
    maxPulledOutVehicles,
    techs,
    assignTechToJob,
    renameTech,
  }
})

