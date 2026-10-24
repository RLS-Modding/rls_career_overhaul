// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

import { createOwnedBuildOperation } from "./ownedBuildOperation.js"
import { mergePartsCartUpdate } from "./partsCartOperations.js"
import { ref } from "vue"
import { defineStore, storeToRefs } from "pinia"
import { lua } from "@/bridge"
import { useBusinessSessionStore } from "./businessSessionStore.js"
import { useBusinessCartStore } from "./businessCartStore.js"
import { useBusinessPartsStore } from "./businessPartsStore.js"
import { useBusinessTuningStore } from "./businessTuningStore.js"

// Build tabs: several parts+tuning builds per vehicle. Switching applies the stored build to the vehicle in Lua and
// refreshes the open parts or tuning view. Also handles the cart events Lua sends back.

// The tab list: creating, copying, deleting and renaming builds. The tab id sequence lives in this closure, once per store.
const createTabListActions = ({
  businessId, pulledOutVehicle, partsCart, tuningCart, cartTabs, activeTabId, currentAppliedCartHash,
  generateCartHash, saveCurrentTabState, loadTabState, tuningCartVariableValues, applyBuild, isBuildPending
}) => {
  // The sequence keeps ids unique when two tabs are created in the same millisecond. Tab ids live only in this
  // store (they are never saved), so the format is free to change.
  let tabSequence = 0
  const newTabId = () => `tab_${Date.now()}_${++tabSequence}`

  const createNewTab = async () => {
    if (isBuildPending()) return false
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
        id: newTabId(),
        name: `Build ${newTabNumber}`,
        parts: [],
        tuning: [],
        cartHash: generateCartHash([], [])
      }

      return await applyBuild({ reset: true }, completed => {
        cartTabs.value.push(newTab)
        activeTabId.value = newTab.id
        partsCart.value = []
        tuningCart.value = []
        currentAppliedCartHash.value = completed ? newTab.cartHash : null
      })
    } catch (error) {
      return false
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
    if (isBuildPending()) return false
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
      id: newTabId(),
      name: `Build ${newTabNumber}`,
      parts: JSON.parse(JSON.stringify(tab.parts || [])),
      tuning: JSON.parse(JSON.stringify(tab.tuning || [])),
      cartHash: generateCartHash(tab.parts || [], tab.tuning || [])
    }

    cartTabs.value.push(duplicatedTab)
    activeTabId.value = duplicatedTab.id

    loadTabState(duplicatedTab.id)

    const targetHash = generateCartHash(partsCart.value, tuningCart.value)
    if (hasSameContent && currentAppliedCartHash.value === targetHash) {
      currentAppliedCartHash.value = targetHash
      return true
    }
    return applyBuild({
      reset: true,
      ...(partsCart.value.length > 0 ? { parts: partsCart.value } : {}),
      ...(tuningCart.value.length > 0 ? { tuning: tuningCartVariableValues() } : {})
    }, completed => { currentAppliedCartHash.value = completed ? targetHash : null })
  }

  const renameTab = (tabId, newName) => {
    const tab = cartTabs.value.find(t => t.id === tabId)
    if (!tab) return

    const trimmedName = (newName || '').trim()
    if (!trimmedName || trimmedName.length === 0) return

    tab.name = trimmedName
    saveCurrentTabState()
  }

  return { createNewTab, deleteTab, duplicateTab, renameTab }
}

// Switching applies the stored build to the pulled-out vehicle. A switch is ignored while another one is still applying.
const createTabSwitchAction = ({
  businessId, pulledOutVehicle, cartTabs, activeTabId, partsCart, currentAppliedCartHash,
  generateCartHash, saveCurrentTabState, loadTabState, tuningCartVariableValues, refreshOpenVehicleView, applyBuild, isBuildPending
}) => {
  const isSwitchingTab = ref(false)

  const switchTab = async (tabId) => {
    if (tabId === activeTabId.value && currentAppliedCartHash.value !== null) return
    if (isSwitchingTab.value || isBuildPending()) return false

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

      return await applyBuild({ parts: partsCart.value, tuning: tuningCartVariableValues() }, completed => {
        currentAppliedCartHash.value = completed ? targetHash : null
        if (completed) {
          const ownerBusiness = businessId.value
          const ownerVehicle = pulledOutVehicle.value
          setTimeout(() => {
            if (businessId.value === ownerBusiness && pulledOutVehicle.value === ownerVehicle
              && activeTabId.value === tabId && currentAppliedCartHash.value === targetHash) refreshOpenVehicleView()
          }, 100)
        }
      })
    } finally {
      isSwitchingTab.value = false
    }
  }

  return { switchTab }
}

// Cart events Lua sends back after it applies or rejects a parts change.
const createCartEventHandlers = ({
  isMenuActive, businessId, pulledOutVehicle, vehicleView, partsCart, partsCartRollback, tuningCart,
  currentAppliedCartHash, generateCartHash, saveCurrentTabState, restorePartsCartRollback, requestVehiclePartsTree,
  refreshOpenVehicleView
}) => {
  const handlePartCartUpdated = (data) => {
    if (!isMenuActive.value) return
    if (String(data.businessId) === String(businessId.value) && String(data.vehicleId) === String(pulledOutVehicle.value?.vehicleId)) {
      if (data.cart && Array.isArray(data.cart)) {
        if (data.operationId != null) {
          // An owned completion confirms only its delta; its older full cart cannot replace later edits.
          if (restorePartsCartRollback({ ...data, succeeded: true })) setTimeout(refreshOpenVehicleView, 100)
          return
        }
        restorePartsCartRollback({ businessId: data.businessId, vehicleId: data.vehicleId, succeeded: true })
        const incoming = Array.isArray(data.sourceCart)
          ? mergePartsCartUpdate(partsCart.value, data.sourceCart, data.cart) : data.cart
        partsCart.value = incoming.map(item => ({
          ...item,
          id: `${item.slotPath}_${item.partName}`,
          canRemove: item.canRemove !== false
        }))
        saveCurrentTabState()
        currentAppliedCartHash.value = generateCartHash(partsCart.value, tuningCart.value)

        setTimeout(refreshOpenVehicleView, 100)
      }
    }
  }

  const handlePartCartApplyFailed = (data) => {
    if (!isMenuActive.value) return
    if (data?.businessId != null && String(data.businessId) !== String(businessId.value)) return
    if (data?.vehicleId != null && String(data.vehicleId) !== String(pulledOutVehicle.value?.vehicleId)) return
    restorePartsCartRollback({
      businessId: data?.businessId,
      vehicleId: data?.vehicleId,
      operationId: data?.operationId
    })
    // Lua already shows ui_message; only refresh the parts tree after rollback.
    if (pulledOutVehicle.value?.vehicleId) {
      setTimeout(() => {
        const vehicleId = pulledOutVehicle.value?.vehicleId
        if (vehicleId != null && vehicleView.value === 'parts') {
          requestVehiclePartsTree(vehicleId)
        }
      }, 100)
    }
  }

  return { handlePartCartUpdated, handlePartCartApplyFailed }
}

export const useBusinessBuildStore = defineStore("overhaulBusinessBuild", () => {
  const sessionStore = useBusinessSessionStore()
  const { vehicleView, pulledOutVehicle, isMenuActive, businessId } = storeToRefs(sessionStore)
  const cartStore = useBusinessCartStore()
  const {
    partsCart, partsCartRollback, tuningCart, cartTabs, activeTabId, currentAppliedCartHash
  } = storeToRefs(cartStore)
  const {
    generateCartHash, saveCurrentTabState, restorePartsCartRollback, loadTabState, tuningCartVariableValues
  } = cartStore
  const partsStore = useBusinessPartsStore()
  const { requestVehiclePartsTree } = partsStore
  const tuningStore = useBusinessTuningStore()
  const { requestVehicleTuningData } = tuningStore

  /** Re-requests the data of the parts or tuning view that is open, after a cart change settles. */
  const refreshOpenVehicleView = () => {
    const vehicleId = pulledOutVehicle.value?.vehicleId
    if (vehicleId == null) return
    if (vehicleView.value === 'parts') {
      requestVehiclePartsTree(vehicleId)
    }
    if (vehicleView.value === 'tuning') {
      requestVehicleTuningData(vehicleId)
    }
  }

  const { applyBuild, isBuildPending, handleBuildOperationCompleted } = createOwnedBuildOperation({
    businessId, pulledOutVehicle, isMenuActive, cartTabs, activeTabId, partsCart, tuningCart, currentAppliedCartHash
  })
  const { createNewTab, deleteTab, duplicateTab, renameTab } = createTabListActions({
    businessId, pulledOutVehicle, partsCart, tuningCart, cartTabs, activeTabId, currentAppliedCartHash,
    generateCartHash, saveCurrentTabState, loadTabState, tuningCartVariableValues, applyBuild, isBuildPending
  })
  const { switchTab } = createTabSwitchAction({
    businessId, pulledOutVehicle, cartTabs, activeTabId, partsCart, currentAppliedCartHash,
    generateCartHash, saveCurrentTabState, loadTabState, tuningCartVariableValues, refreshOpenVehicleView, applyBuild, isBuildPending
  })
  const { handlePartCartUpdated, handlePartCartApplyFailed } = createCartEventHandlers({
    isMenuActive, businessId, pulledOutVehicle, vehicleView, partsCart, partsCartRollback, tuningCart,
    currentAppliedCartHash, generateCartHash, saveCurrentTabState, restorePartsCartRollback, requestVehiclePartsTree,
    refreshOpenVehicleView
  })

  return {
    createNewTab,
    switchTab,
    deleteTab,
    duplicateTab,
    renameTab,
    handlePartCartUpdated,
    handlePartCartApplyFailed,
    handleBuildOperationCompleted
  }
})
