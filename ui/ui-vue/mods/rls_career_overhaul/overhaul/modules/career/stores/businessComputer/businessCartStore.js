import { computed, ref } from "vue"
import { defineStore, storeToRefs } from "pinia"
import { lua } from "@/bridge"
import { normalizeId } from "../../utils/businessUtils"
import { createPartsCartOperations } from "./partsCartOperations.js"
import { useBusinessSessionStore } from "./businessSessionStore.js"

// The build being edited for the pulled-out vehicle: parts cart, tuning cart, build tabs (state only), the applied-cart
// hash and the per-vehicle caches. The parts, tuning and build stores act on this state.

export const useBusinessCartStore = defineStore("overhaulBusinessCart", () => {
  const sessionStore = useBusinessSessionStore()
  const { pulledOutVehicle, businessId } = storeToRefs(sessionStore)

  const partsCart = ref([])
  const partsCartRollback = ref(null)
  const tuningCart = ref([])
  const tuningDataCache = ref({})
  const partsTreeCache = ref({})
  const cartTabs = ref([{ id: 'default', name: 'Build 1', parts: [], tuning: [], cartHash: null }])
  const activeTabId = ref('default')
  const originalVehicleState = ref(null)
  const currentAppliedCartHash = ref(null)

  const clearCachesForVehicle = (vehicleId) => {
    const normalized = normalizeId(vehicleId)
    const key = normalized !== null ? String(normalized) : 'noveh'
    if (partsTreeCache.value[key]) {
      delete partsTreeCache.value[key]
    }
    if (tuningDataCache.value[key]) {
      delete tuningDataCache.value[key]
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

  const { setPartsCartRollback, restorePartsCartRollback, clearPartsCartOperations } = createPartsCartOperations({
    partsCart, partsCartRollback, businessId, pulledOutVehicle, activeTabId, cartTabs, saveCurrentTabState,
    currentAppliedCartHash, generateCartHash, tuningCart
  })

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

  const isCurrentTabApplied = computed(() => {
    const activeTab = cartTabs.value.find(tab => tab.id === activeTabId.value)
    if (!activeTab || !currentAppliedCartHash.value) return false
    const tabHash = activeTab.cartHash || generateCartHash(activeTab.parts || [], activeTab.tuning || [])
    return currentAppliedCartHash.value === tabHash
  })

  const clearCart = () => {
    // Reset to a single default tab with empty cart
    cartTabs.value = [{ id: 'default', name: 'Build 1', parts: [], tuning: [], cartHash: generateCartHash([], []) }]
    activeTabId.value = 'default'
    partsCart.value = []
    tuningCart.value = []
    clearPartsCartOperations()
    currentAppliedCartHash.value = null
  }

  const hasUncommittedCartChanges = () => {
    const parts = Array.isArray(partsCart.value) ? partsCart.value : []
    const tuning = Array.isArray(tuningCart.value) ? tuningCart.value : []
    return parts.length > 0 || tuning.length > 0
  }

  const revertUncommittedCartPreview = async (targetBusinessId, targetVehicleId) => {
    const bId = targetBusinessId ?? businessId.value
    const vId = targetVehicleId ?? pulledOutVehicle.value?.vehicleId
    if (!bId || vId === undefined || vId === null) {
      return
    }

    try {
      // Lua retains the paid baseline until the physical rollback finishes.
      await lua.overhaul_career_business_partCustomization.clearPreviewVehicle(bId)
    } catch (error) {
    }
  }

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

  /** The tuning variables of a cart as a varName -> value map, the shape Lua applies. */
  const tuningCartVariableValues = (cart = tuningCart.value) => {
    const values = {}
    for (const change of Array.isArray(cart) ? cart : []) {
      if (change.type === 'variable' && change.varName && change.value !== undefined) {
        values[change.varName] = change.value
      }
    }
    return values
  }

  return {
    partsCart,
    partsCartRollback,
    tuningCart,
    tuningDataCache,
    partsTreeCache,
    cartTabs,
    activeTabId,
    originalVehicleState,
    currentAppliedCartHash,
    clearCachesForVehicle,
    generateCartHash,
    saveCurrentTabState,
    setPartsCartRollback,
    restorePartsCartRollback,
    loadTabState,
    isCurrentTabApplied,
    clearCart,
    hasUncommittedCartChanges,
    revertUncommittedCartPreview,
    getCartTotal,
    tuningCost,
    tuningCartVariableValues
  }
})
