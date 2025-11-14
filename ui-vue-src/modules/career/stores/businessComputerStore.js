import { computed, ref } from "vue"
import { defineStore } from "pinia"
import { lua } from "@/bridge"
import { useBridge } from "@/bridge"

export const useBusinessComputerStore = defineStore("businessComputer", () => {
  const businessData = ref({})
  const activeView = ref("home")
  const vehicleView = ref(null)
  const pulledOutVehicle = ref(null)
  const loading = ref(false)

  const partsCart = ref([])
  const tuningCart = ref([])
  const tuningDataCache = ref({})
  
  const cartTabs = ref([{ id: 'default', name: 'Build 1', parts: [], tuning: [] }])
  const activeTabId = ref('default')
  const originalVehicleState = ref(null)
  
  const originalPower = ref(null)
  const originalWeight = ref(null)
  const currentPower = ref(null)
  const currentWeight = ref(null)

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
      console.error("Failed to complete job:", error)
      return false
    }
  }

  const pullOutVehicle = async (vehicleId) => {
    if (!businessId.value) {
      console.error("pullOutVehicle: No businessId")
      return false
    }
    try {
      const success = await lua.career_modules_business_businessComputer.pullOutVehicle(businessId.value, vehicleId)
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

  const switchVehicleView = async (view) => {
    // Store previous view before changing it
    const previousView = vehicleView.value
    
    // Only clear cart when leaving vehicle views entirely (not when switching between parts/tuning)
    const isSwitchingBetweenVehicleViews = (previousView === 'parts' || previousView === 'tuning') && (view === 'parts' || view === 'tuning')
    const isLeavingVehicleViews = previousView !== null && !isSwitchingBetweenVehicleViews && (view !== 'parts' && view !== 'tuning')
    
    if (isLeavingVehicleViews) {
      clearCart()
      // Reset vehicle to original state when leaving vehicle views
      if (businessId.value && pulledOutVehicle.value?.vehicleId) {
        try {
          await lua.career_modules_business_businessComputer.resetVehicleToOriginal(
            businessId.value,
            pulledOutVehicle.value.vehicleId
          )
          // Clear preview vehicle state
          await lua.career_modules_business_businessPartCustomization.clearPreviewVehicle(businessId.value)
        } catch (error) {
          console.error("Failed to reset vehicle when leaving vehicle views:", error)
        }
      }
    }
    
    // Check if we're entering parts view from a non-vehicle view (not switching from tuning)
    const enteringPartsViewFromNonVehicle = view === 'parts' && previousView !== 'parts' && previousView !== 'tuning'
    
    // Set the view immediately for UI animation
    vehicleView.value = view
    
    // Initialize cart only when first opening parts view from a non-vehicle view
    // Don't initialize if switching from tuning (cart should persist)
    if (enteringPartsViewFromNonVehicle) {
      // Wait for UI animation to complete before initializing vehicle
      setTimeout(async () => {
        // Double-check we're still in parts view (user might have switched away)
        if (vehicleView.value === 'parts') {
          await initializeCartForVehicle()
        }
      }, 600)
    }
    
    // When switching to tuning view, ensure vehicle has parts from cart applied
    if (view === 'tuning' && previousView !== 'tuning') {
      // Apply tuning cart values to vehicle before requesting tuning data
      setTimeout(async () => {
        if (vehicleView.value === 'tuning' && pulledOutVehicle.value?.vehicleId) {
          const cart = Array.isArray(tuningCart.value) ? tuningCart.value : []
          if (cart.length > 0) {
            // Apply cart tuning values to vehicle first
            const tuningVars = {}
            cart.forEach(change => {
              tuningVars[change.varName] = change.value
            })
            try {
              await lua.career_modules_business_businessComputer.applyTuningToVehicle(
                businessId.value,
                pulledOutVehicle.value.vehicleId,
                tuningVars
              )
            } catch (error) {
              console.error("Failed to apply tuning cart values:", error)
            }
          }
          // Then request tuning data (will show cart values in UI)
          await requestVehicleTuningData(pulledOutVehicle.value.vehicleId)
        }
      }, 600)
    }
    
    // When switching to parts view from tuning, ensure parts are still applied
    if (view === 'parts' && previousView === 'tuning') {
      // Cart should persist, just ensure parts are applied
      setTimeout(async () => {
        if (vehicleView.value === 'parts' && pulledOutVehicle.value?.vehicleId && partsCart.value.length > 0) {
          // Request parts tree to refresh UI
          await requestVehiclePartsTree(pulledOutVehicle.value.vehicleId)
        }
      }, 600)
    }
  }

  const closeVehicleView = async () => {
    // Clear cart when closing vehicle view (only when actually closing, not when switching between parts/tuning)
    if (vehicleView.value === 'parts' || vehicleView.value === 'tuning') {
      clearCart()
      // Reset vehicle to original state when closing vehicle customization
      if (businessId.value && pulledOutVehicle.value?.vehicleId) {
        try {
          await lua.career_modules_business_businessComputer.resetVehicleToOriginal(
            businessId.value,
            pulledOutVehicle.value.vehicleId
          )
          // Clear preview vehicle state
          await lua.career_modules_business_businessPartCustomization.clearPreviewVehicle(businessId.value)
        } catch (error) {
          console.error("Failed to reset vehicle when closing vehicle customization:", error)
        }
      }
    }
    vehicleView.value = null
  }

  const onMenuClosed = () => {
    // Clear cart when menu is closed
    clearCart()
    
    // Clear preview vehicle state on Lua side
    if (businessId.value) {
      try {
        lua.career_modules_business_businessPartCustomization.clearPreviewVehicle(businessId.value)
      } catch (error) {
        console.error("Failed to clear preview vehicle:", error)
      }
    }
    
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

  const saveCurrentTabState = () => {
    const activeTab = cartTabs.value.find(tab => tab.id === activeTabId.value)
    if (activeTab) {
      activeTab.parts = JSON.parse(JSON.stringify(partsCart.value))
      activeTab.tuning = JSON.parse(JSON.stringify(tuningCart.value))
    }
  }
  
  const loadTabState = (tabId) => {
    const tab = cartTabs.value.find(t => t.id === tabId)
    if (tab) {
      partsCart.value = JSON.parse(JSON.stringify(tab.parts || []))
      tuningCart.value = JSON.parse(JSON.stringify(tab.tuning || []))
    }
  }
  
  const createNewTab = async () => {
    try {
      saveCurrentTabState()
      
      // Find the lowest available build number
      const existingNumbers = new Set()
      cartTabs.value.forEach(tab => {
        const match = tab.name.match(/^Build (\d+)$/)
        if (match) {
          existingNumbers.add(parseInt(match[1], 10))
        }
      })
      
      // Find the first missing number starting from 1
      let newTabNumber = 1
      while (existingNumbers.has(newTabNumber)) {
        newTabNumber++
      }
      
      const newTab = {
        id: `tab_${Date.now()}`,
        name: `Build ${newTabNumber}`,
        parts: [],
        tuning: []
      }
      
      cartTabs.value.push(newTab)
      activeTabId.value = newTab.id
      
      // Reset cart to original vehicle state
      partsCart.value = []
      tuningCart.value = []
      
      // Reset vehicle to original state
      if (businessId.value && pulledOutVehicle.value?.vehicleId) {
        try {
          const success = await lua.career_modules_business_businessComputer.resetVehicleToOriginal(
            businessId.value,
            pulledOutVehicle.value.vehicleId
          )
          if (!success) {
            console.error("resetVehicleToOriginal returned false")
          }
        } catch (error) {
          console.error("Failed to reset vehicle to original:", error)
        }
      }
    } catch (error) {
      console.error("Failed to create new tab:", error)
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
    
    saveCurrentTabState()
    
    const targetTab = cartTabs.value.find(t => t.id === tabId)
    if (!targetTab) return
    
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
          tuningVars[change.varName] = change.value
        })
        await lua.career_modules_business_businessComputer.applyTuningToVehicle(
          businessId.value,
          pulledOutVehicle.value.vehicleId,
          tuningVars
        )
        
        setTimeout(() => {
          if (vehicleView.value === 'parts') {
            requestVehiclePartsTree(pulledOutVehicle.value.vehicleId)
          }
          if (vehicleView.value === 'tuning') {
            requestVehicleTuningData(pulledOutVehicle.value.vehicleId)
          }
        }, 100)
      } catch (error) {
        console.error("Failed to restore vehicle state for tab:", error)
      }
    }
  }
  
  const deleteTab = (tabId) => {
    if (cartTabs.value.length <= 1) return
    
    const index = cartTabs.value.findIndex(tab => tab.id === tabId)
    if (index < 0) return
    
    cartTabs.value.splice(index, 1)
    
    if (activeTabId.value === tabId) {
      // Switch to first available tab
      activeTabId.value = cartTabs.value[0].id
      loadTabState(activeTabId.value)
    }
  }
  
  const duplicateTab = async (tabId) => {
    const tab = cartTabs.value.find(t => t.id === tabId)
    if (!tab) return
    
    // Save current tab state first
    saveCurrentTabState()
    
    // Check if we're duplicating the active tab (same parts/tuning = no reload needed)
    const isDuplicatingActiveTab = tabId === activeTabId.value
    const currentParts = JSON.stringify(partsCart.value)
    const currentTuning = JSON.stringify(tuningCart.value)
    const tabParts = JSON.stringify(tab.parts || [])
    const tabTuning = JSON.stringify(tab.tuning || [])
    const hasSameContent = isDuplicatingActiveTab && 
                           currentParts === tabParts && 
                           currentTuning === tabTuning
    
    // Find highest build number
    let maxNumber = 0
    cartTabs.value.forEach(t => {
      const match = t.name.match(/^Build (\d+)$/)
      if (match) {
        const num = parseInt(match[1], 10)
        if (num > maxNumber) maxNumber = num
      }
    })
    const newTabNumber = maxNumber + 1
    
    // Create duplicate tab with copied parts and tuning
    const duplicatedTab = {
      id: `tab_${Date.now()}`,
      name: `Build ${newTabNumber}`,
      parts: JSON.parse(JSON.stringify(tab.parts || [])), // Deep copy
      tuning: JSON.parse(JSON.stringify(tab.tuning || [])) // Deep copy
    }
    
    cartTabs.value.push(duplicatedTab)
    activeTabId.value = duplicatedTab.id
    
    // Load the duplicated tab's state
    loadTabState(duplicatedTab.id)
    
    // Only reload vehicle if the content is different (shouldn't happen when duplicating, but safety check)
    if (!hasSameContent && businessId.value && pulledOutVehicle.value?.vehicleId) {
      try {
        // Reset to original first
        await lua.career_modules_business_businessComputer.resetVehicleToOriginal(
          businessId.value,
          pulledOutVehicle.value.vehicleId
        )
        
        // Then apply parts from duplicated tab
        if (partsCart.value.length > 0) {
          await lua.career_modules_business_businessComputer.applyCartPartsToVehicle(
            businessId.value,
            pulledOutVehicle.value.vehicleId,
            partsCart.value
          )
        }
        
        // Apply tuning from duplicated tab (or reset to baseline if tab has no tuning)
        const cart = Array.isArray(tuningCart.value) ? tuningCart.value : []
        if (cart.length > 0) {
          const tuningVars = {}
          cart.forEach(change => {
            tuningVars[change.varName] = change.value
          })
          await lua.career_modules_business_businessComputer.applyTuningToVehicle(
            businessId.value,
            pulledOutVehicle.value.vehicleId,
            tuningVars
          )
        }
        // If tuningCart is empty, vehicle already has baseline tuning from resetVehicleToOriginal
      } catch (error) {
        console.error("Failed to apply duplicated tab state:", error)
      }
    }
    // If hasSameContent is true, vehicle already has the correct parts/tuning, so no reload needed
  }
  
  const renameTab = (tabId, newName) => {
    const tab = cartTabs.value.find(t => t.id === tabId)
    if (!tab) return
    
    // Trim and validate name
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
  
  // Setup event listener
  events.on('businessComputer:onPartCartUpdated', handlePartCartUpdated)
  
  const addPartToCart = async (part, slot) => {
    if (!businessId.value || !pulledOutVehicle.value?.vehicleId) {
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
      // Call Lua to add part to cart (returns temp cart immediately, final cart comes via event)
      const tempCart = await lua.career_modules_business_businessComputer.addPartToCart(
        businessId.value,
        pulledOutVehicle.value.vehicleId,
        partsCart.value,
        partToAdd
      )
      
      // Update Vue cart with temp cart immediately (will be updated via event when vehicle spawns)
      if (tempCart && Array.isArray(tempCart)) {
        partsCart.value = tempCart.map(item => ({
          ...item,
          id: `${item.slotPath}_${item.partName}`
        }))
      }
    } catch (error) {
      console.error("Failed to add part to cart:", error)
    }
    
    // Auto-save to current tab
    saveCurrentTabState()
    
    // Power/weight will be updated automatically by Lua when vehicle replacement completes
  }

  const removePartFromCart = async (itemId) => {
    // Build the parts tree to find parent-child relationships
    const tree = buildPartsTree(partsCart.value)
    
    // Find the node to remove and collect all its children IDs recursively
    const collectChildIds = (node, targetId, collectedIds = []) => {
      if (node.id === targetId) {
        // Found the target node, collect all its children recursively
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
      
      // Search in children
      if (node.children && node.children.length > 0) {
        for (const child of node.children) {
          if (collectChildIds(child, targetId, collectedIds)) {
            return true
          }
        }
      }
      return false
    }
    
    // Collect all IDs to remove (parent + all children)
    const idsToRemove = [itemId]
    for (const rootNode of tree) {
      collectChildIds(rootNode, itemId, idsToRemove)
    }
    
    // Remove all collected IDs from cart
    partsCart.value = partsCart.value.filter(item => !idsToRemove.includes(item.id))
    saveCurrentTabState()
    
    // Apply baseline + remaining cart parts to vehicle
    if (businessId.value && pulledOutVehicle.value?.vehicleId) {
      try {
        await lua.career_modules_business_businessComputer.applyCartPartsToVehicle(
          businessId.value,
          pulledOutVehicle.value.vehicleId,
          partsCart.value
        )
        
        // Wait for vehicle to update, then find removed parts and add to inventory
        setTimeout(async () => {
          try {
            // Use findRemovedParts to get all removed parts (including children)
            const removedParts = await lua.career_modules_business_businessPartCustomization.findRemovedParts(
              businessId.value,
              pulledOutVehicle.value.vehicleId
            )
            
            // Add all removed parts to business inventory
            if (removedParts && Array.isArray(removedParts)) {
              for (const removedPart of removedParts) {
                await lua.career_modules_business_businessPartInventory.addPart(
                  businessId.value,
                  removedPart
                )
              }
            }
            
            // Reload parts tree to reflect removal
            await store.requestVehiclePartsTree(pulledOutVehicle.value.vehicleId)
          } catch (error) {
            console.error("Failed to add removed parts to inventory:", error)
          }
        }, 500) // Wait for vehicle replacement to complete
        
        // Power/weight will be updated when vehicle replacement completes (via hook)
      } catch (error) {
        console.error("Failed to apply cart parts after removal:", error)
      }
    }
  }
  
  const removePartBySlotPath = async (slotPath) => {
    // Normalize slot path
    let normalizedPath = (slotPath || '').trim()
    if (!normalizedPath.startsWith('/')) {
      normalizedPath = '/' + normalizedPath
    }
    if (!normalizedPath.endsWith('/')) {
      normalizedPath = normalizedPath + '/'
    }
    
    // Find the part in the cart by slotPath
    const partToRemove = partsCart.value.find(item => {
      const itemPath = (item.slotPath || '').trim()
      return itemPath === normalizedPath
    })
    
    if (partToRemove) {
      // Collect all parts that will be removed (parent + children) before removal
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
      
      // Get the parts that will be removed (for inventory)
      const partsToAddToInventory = partsCart.value.filter(item => idsToRemove.includes(item.id))
      
      // Remove from cart
      partsCart.value = partsCart.value.filter(item => !idsToRemove.includes(item.id))
      saveCurrentTabState()
      
      // Apply baseline + remaining cart parts to vehicle
      if (businessId.value && pulledOutVehicle.value?.vehicleId) {
        try {
          await lua.career_modules_business_businessComputer.applyCartPartsToVehicle(
            businessId.value,
            pulledOutVehicle.value.vehicleId,
            partsCart.value
          )
          
          // Wait for vehicle to update, then find removed parts and add to inventory
          setTimeout(async () => {
            try {
              // Use findRemovedParts to get all removed parts (including children)
              const removedParts = await lua.career_modules_business_businessPartCustomization.findRemovedParts(
                businessId.value,
                pulledOutVehicle.value.vehicleId
              )
              
              // Add all removed parts to business inventory
              if (removedParts && Array.isArray(removedParts)) {
                for (const removedPart of removedParts) {
                  await lua.career_modules_business_businessPartInventory.addPart(
                    businessId.value,
                    removedPart
                  )
                }
              }
              
              // Reload parts tree to reflect removal
              await store.requestVehiclePartsTree(pulledOutVehicle.value.vehicleId)
            } catch (error) {
              console.error("Failed to add removed parts to inventory:", error)
            }
          }, 500) // Wait for vehicle replacement to complete
          
          // Power/weight will be updated when vehicle replacement completes (via hook)
        } catch (error) {
          console.error("Failed to apply cart parts after removal:", error)
        }
      }
    }
  }
  
  const removeTuningFromCart = (varName) => {
    const index = tuningCart.value.findIndex(item => item.varName === varName)
    if (index >= 0) {
      tuningCart.value.splice(index, 1)
      saveCurrentTabState()
    }
  }

  const addTuningToCart = async (tuningVars, originalVars) => {
    if (!businessId.value || !pulledOutVehicle.value?.vehicleId) {
      tuningCart.value = []
      saveCurrentTabState()
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
      
      // Update power/weight after tuning change
      updatePowerWeight()
    } catch (error) {
      console.error("Failed to add tuning to cart:", error)
      tuningCart.value = []
      saveCurrentTabState()
    }
  }

  const clearCart = () => {
    // Reset to a single default tab with empty cart
    cartTabs.value = [{ id: 'default', name: 'Build 1', parts: [], tuning: [] }]
    activeTabId.value = 'default'
    partsCart.value = []
    tuningCart.value = []
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
    // Reset tabs when vehicle changes or when opening shop
    cartTabs.value = [{ id: 'default', name: 'Build 1', parts: [], tuning: [] }]
    activeTabId.value = 'default'
    partsCart.value = []
    tuningCart.value = []
    originalVehicleState.value = null
    
    // Reset power/weight
    originalPower.value = null
    originalWeight.value = null
    currentPower.value = null
    currentWeight.value = null
    
    // Reset vehicle to original state (baseline from inventory) when opening shop
    if (businessId.value && pulledOutVehicle.value?.vehicleId) {
      try {
        await lua.career_modules_business_businessComputer.resetVehicleToOriginal(
          businessId.value,
          pulledOutVehicle.value.vehicleId
        )
        // Power/weight will be updated automatically by Lua after vehicle replacement
      } catch (error) {
        console.error("Failed to reset vehicle:", error)
      }
    }
  }
  
  const updatePowerWeight = async () => {
    if (!businessId.value || !pulledOutVehicle.value?.vehicleId) return
    
    try {
      // This will return nil, but trigger the async request
      // Data will arrive via 'businessComputer:onVehiclePowerWeight' hook
      lua.career_modules_business_businessComputer.getVehiclePowerWeight(
        businessId.value,
        pulledOutVehicle.value.vehicleId
      )
    } catch (error) {
      console.error("Failed to request power/weight:", error)
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
    
    // Build a map of all parts by their slot path
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
    
    // Helper to get parent path
    const getParentPath = (path) => {
      const pathParts = path.split('/').filter(p => p)
      if (pathParts.length <= 1) return null
      return '/' + pathParts.slice(0, -1).join('/') + '/'
    }
    
    // Build parent-child relationships
    const rootNodes = []
    
    // Process all parts and build tree
    partMap.forEach((part, path) => {
      const parentPath = getParentPath(path)
      
      if (!parentPath) {
        // Root level part (no parent)
        rootNodes.push(part)
      } else {
        // Check if parent exists in cart
        const parent = partMap.get(parentPath)
        if (parent) {
          // Parent is in cart, add as child
          if (!parent.children) parent.children = []
          parent.children.push(part)
        } else {
          // Parent not in cart, this is a root node
          rootNodes.push(part)
        }
      }
    })
    
    // Recursively sort children
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
    
    // Sort root nodes
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
    completeJob,
    pullOutVehicle,
    putAwayVehicle,
    switchView,
    switchVehicleView,
    closeVehicleView,
    onMenuClosed,
    requestVehiclePartsTree,
    requestVehicleTuningData,
    applyVehicleTuning,
    partsCart,
    tuningCart,
    addPartToCart,
    removePartFromCart,
    removePartBySlotPath,
    addTuningToCart,
    removeTuningFromCart,
    clearCart,
    getCartTotal,
    tuningCost,
    tuningDataCache,
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
  }
})

