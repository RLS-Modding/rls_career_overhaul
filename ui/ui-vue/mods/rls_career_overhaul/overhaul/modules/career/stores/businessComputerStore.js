// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// Cross-tab business computer flows: vehicle selection, view transitions and closing.
// Tab stores own their data and actions; this store keeps the event forwarding in one session.
import { safeLua, reportUiFailure } from "../utils/safeLua.js"
import { defineStore, storeToRefs } from "pinia"
import { lua, useBridge } from "@/bridge"
import { normalizeId } from "../utils/businessUtils"
import { useBusinessSessionStore } from "./businessComputer/businessSessionStore.js"
import { useBusinessRacingTeamStore } from "./businessComputer/businessRacingTeamStore.js"
import { useBusinessTechsStore } from "./businessComputer/businessTechsStore.js"
import { useBusinessJobsStore } from "./businessComputer/businessJobsStore.js"
import { useBusinessCartStore } from "./businessComputer/businessCartStore.js"
import { useBusinessVehiclesStore } from "./businessComputer/businessVehiclesStore.js"
import { useBusinessPartsStore } from "./businessComputer/businessPartsStore.js"
import { useBusinessTuningStore } from "./businessComputer/businessTuningStore.js"
import { useBusinessKitsStore } from "./businessComputer/businessKitsStore.js"
import { useBusinessBuildStore } from "./businessComputer/businessBuildStore.js"
import { useBusinessSkillsStore } from "./businessComputer/businessSkillsStore.js"

const VEHICLE_VIEW_REFRESH_DELAY_MS = 100

// Vehicle selection ------------------------------------------------------------
function createVehicleSelectionActions(sessionStore, cartStore, tuningStore, partsStore) {
  const {
    businessId, businessType, activeVehicleId, businessData, pulledOutVehicle, pulledOutVehicles, vehicleView
  } = storeToRefs(sessionStore)
  const { normalizeLuaResult, loadBusinessData } = sessionStore
  const { originalVehicleState } = storeToRefs(cartStore)
  const { hasUncommittedCartChanges, clearCart } = cartStore
  const { resetPowerWeight, initializeCartForVehicle, requestVehicleTuningData } = tuningStore
  const { requestVehiclePartsTree } = partsStore

  const setActiveVehicleSelection = async (vehicleId) => {
    if (!businessId.value || vehicleId === undefined || vehicleId === null) {
      return false
    }
    const normalizedTarget = normalizeId(vehicleId)
    if (normalizeId(activeVehicleId.value) === normalizedTarget) {
      return true
    }

    const previousVehicleId = activeVehicleId.value

    try {
      // Always use businessComputer for vehicle operations - it triggers UI events
      const success = normalizeLuaResult(await lua.overhaul_career_business_computer.setActiveVehicle(businessId.value, vehicleId))
      if (success) {
        if (previousVehicleId && businessId.value && previousVehicleId !== normalizedTarget) {
          if (hasUncommittedCartChanges()) {
            await safeLua(() => lua.overhaul_career_business_computer.resetVehicleToOriginal(
                businessId.value,
                previousVehicleId
              ), "businessComputerStore: setActiveVehicleSelection")
          }
          await safeLua(() => lua.overhaul_career_business_partCustomization.clearPreviewVehicle(businessId.value), "businessComputerStore: setActiveVehicleSelection")
        }
        clearCart()

        resetPowerWeight()
        originalVehicleState.value = null

        // activeVehicleId and pulledOutVehicle are set by onVehiclePulledOut/onPersonalVehicleSelected event handlers
        // Save the current selection before any refresh
        const savedActiveVehicleId = activeVehicleId.value
        const savedPulledOutVehicle = pulledOutVehicle.value
        const currentVehicle = savedPulledOutVehicle
        const requiresRefresh = !currentVehicle || currentVehicle.vehicleId === undefined || currentVehicle.vehicleId === null
        businessData.value = {
          ...businessData.value,
          pulledOutVehicle: currentVehicle
        }

        if (requiresRefresh && businessType.value && businessId.value) {
          try {
            await loadBusinessData(businessType.value, businessId.value)
            // Restore the saved selection after loadBusinessData (which calls setBusinessData and resets it)
            const vehiclesList = Array.isArray(pulledOutVehicles.value) ? pulledOutVehicles.value : []
            const restoredVehicle = vehiclesList.find(v => normalizeId(v?.vehicleId) === normalizeId(savedActiveVehicleId))
            if (restoredVehicle) {
              activeVehicleId.value = restoredVehicle.vehicleId
              pulledOutVehicle.value = restoredVehicle
            } else if (savedActiveVehicleId) {
              activeVehicleId.value = savedActiveVehicleId
              pulledOutVehicle.value = savedPulledOutVehicle
            }
          } catch (error) {
            reportUiFailure(error, "businessComputerStore: setActiveVehicleSelection")
          }
        }

        const activeVehicle = pulledOutVehicle.value
        if (activeVehicle && (vehicleView.value === 'parts' || vehicleView.value === 'tuning')) {
          setTimeout(async () => {
            if (vehicleView.value === 'parts' && activeVehicle?.vehicleId) {
              await initializeCartForVehicle()
              await requestVehiclePartsTree(activeVehicle.vehicleId)
            } else if (vehicleView.value === 'tuning' && activeVehicle?.vehicleId) {
              await initializeCartForVehicle()
              await requestVehicleTuningData(activeVehicle.vehicleId)
            }
          }, VEHICLE_VIEW_REFRESH_DELAY_MS)
        }
      }
      return !!success
    } catch (error) {
      return false
    }
  }

  return { setActiveVehicleSelection }
}

// View transitions ------------------------------------------------------------
function createViewActions(sessionStore, cartStore, tuningStore) {
  const { activeView, vehicleView, businessId, businessType, pulledOutVehicle, isDamageLocked } = storeToRefs(sessionStore)
  const { showDamageLockWarning, loadBusinessData } = sessionStore
  const { hasUncommittedCartChanges, clearCart, revertUncommittedCartPreview } = cartStore
  const { initializeCartForVehicle } = tuningStore

  const switchView = async (view) => {
    activeView.value = view
    vehicleView.value = null
    if (businessId.value && businessType.value) {
      await safeLua(() => loadBusinessData(businessType.value, businessId.value), "businessComputerStore: switchView")
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
    const isEnteringVehicleViews = (view === 'parts' || view === 'tuning') && previousView !== 'parts' && previousView !== 'tuning'

    if (isLeavingVehicleViews) {
      const hadUncommitted = hasUncommittedCartChanges()
      clearCart()
      if (hadUncommitted && businessId.value && pulledOutVehicle.value?.vehicleId) {
        await revertUncommittedCartPreview(businessId.value, pulledOutVehicle.value.vehicleId)
      } else if (businessId.value) {
        await safeLua(() => lua.overhaul_career_business_partCustomization.clearPreviewVehicle(businessId.value), "businessComputerStore: switchVehicleView")
      }
    }

    if (isEnteringVehicleViews && businessId.value && pulledOutVehicle.value?.vehicleId) {
      await safeLua(() => lua.overhaul_career_business_computer.enterShoppingVehicle(
          businessId.value,
          pulledOutVehicle.value.vehicleId
        ), "businessComputerStore: switchVehicleView")
      await initializeCartForVehicle()
    }

    vehicleView.value = view
  }

  const closeVehicleView = async () => {
    if (vehicleView.value === 'parts' || vehicleView.value === 'tuning') {
      const hadUncommitted = hasUncommittedCartChanges()
      clearCart()
      if (hadUncommitted && businessId.value && pulledOutVehicle.value?.vehicleId) {
        await revertUncommittedCartPreview(businessId.value, pulledOutVehicle.value.vehicleId)
      } else if (businessId.value) {
        await safeLua(() => lua.overhaul_career_business_partCustomization.clearPreviewVehicle(businessId.value), "businessComputerStore: closeVehicleView")
      }
    }
    vehicleView.value = null
  }

  return { switchView, switchVehicleView, closeVehicleView }
}

// Menu lifecycle --------------------------------------------------------------
function createMenuActions(sessionStore, racingStore, techsStore, cartStore) {
  const { businessId, pulledOutVehicle, vehicleView, isMenuActive, businessData, activeView } = storeToRefs(sessionStore)
  const { forgetTabSource, hasCapability } = sessionStore
  const { stopRacingTeamSimPoll } = racingStore
  const { partsTreeCache, tuningDataCache } = storeToRefs(cartStore)
  const { hasUncommittedCartChanges, clearCart } = cartStore
  const { blacklistData, notificationListData, managerBlacklistData } = storeToRefs(techsStore)

  let menuCloseInProgress = false

  const onMenuClosed = () => {
    forgetTabSource()
    const closingBusinessId = businessId.value
    const closingPassive = hasCapability('passiveIncome')
    const closingVehicleId = pulledOutVehicle.value?.vehicleId ?? null
    const closingVehicleView = vehicleView.value

    if (!menuCloseInProgress && closingBusinessId && (closingVehicleView === 'parts' || closingVehicleView === 'tuning') && closingVehicleId) {
      menuCloseInProgress = true
      const hadUncommitted = hasUncommittedCartChanges()
      try {
        if (hadUncommitted) {
          const p = lua.overhaul_career_business_computer.resetVehicleToOriginal(closingBusinessId, closingVehicleId)
          if (p && typeof p.finally === 'function') {
            p.finally(() => { menuCloseInProgress = false })
          } else {
            menuCloseInProgress = false
          }
        } else {
          menuCloseInProgress = false
        }
      } catch (error) {
        menuCloseInProgress = false
      }

      safeLua(() => {
        const p2 = lua.overhaul_career_business_partCustomization.clearPreviewVehicle(closingBusinessId)
        if (p2 && typeof p2.catch === 'function') {
          safeLua(p2, "businessComputerStore: onMenuClosed")
        }
      }, "businessComputerStore: onMenuClosed")
    }

    isMenuActive.value = false
    stopRacingTeamSimPoll()
    clearCart()
    partsTreeCache.value = {}
    tuningDataCache.value = {}

    if (closingBusinessId) {
      safeLua(() => lua.overhaul_career_business_partCustomization.clearPreviewVehicle(closingBusinessId), "businessComputerStore: onMenuClosed")
      if (closingPassive) {
        safeLua(() => lua.overhaul_career_business_computer.closePassiveBusinessManagement(closingBusinessId), "businessComputerStore: onMenuClosed")
      }
    }

    activeView.value = "home"
    vehicleView.value = null
    pulledOutVehicle.value = null
    businessData.value = {}
    blacklistData.value = null
    notificationListData.value = null
    managerBlacklistData.value = null
    safeLua(() => lua.overhaul_career_business_computer.clearVehicleDataCaches(), "businessComputerStore: onMenuClosed")
  }

  /** Same as closing the business computer to freeroam: reset store, Lua play state, and Vue game state. */
  const exitBusinessComputerToPlay = () => {
    onMenuClosed()
    safeLua(() => lua.overhaul_career_career.closeAllMenus(), "businessComputerStore: exitBusinessComputerToPlay")
    safeLua(() => {
      if (typeof window !== "undefined" && window.bngVue && typeof window.bngVue.gotoGameState === "function") {
        window.bngVue.gotoGameState("play")
      }
    }, "businessComputerStore: exitBusinessComputerToPlay")
  }

  return { onMenuClosed, exitBusinessComputerToPlay }
}

// Game hooks ------------------------------------------------------------------
function bindBusinessComputerEvents(bridge, buildStore, jobsStore, techsStore, partsStore, racingStore, vehiclesStore, skillsStore, kitsStore) {
  bridge.events.on('businessComputer:onBuildOperationCompleted', buildStore.handleBuildOperationCompleted)
  bridge.events.on('businessComputer:onPartCartUpdated', buildStore.handlePartCartUpdated)
  bridge.events.on('businessComputer:onPartCartApplyFailed', buildStore.handlePartCartApplyFailed)
  bridge.events.on('businessComputer:onJobsUpdated', jobsStore.handleJobsUpdated)
  bridge.events.on('businessComputer:onTechsUpdated', techsStore.handleTechsUpdated)
  bridge.events.on('businessComputer:onPartInventoryData', partsStore.handlePartInventoryData)
  bridge.events.on('businessComputer:onJobAccepted', jobsStore.handleJobAccepted)
  bridge.events.on('businessComputer:onRaceOffersUpdated', racingStore.handleRaceOffersUpdated)
  bridge.events.on('businessComputer:onRacingTeamGoals', racingStore.handleRacingTeamGoalsUpdated)
  bridge.events.on('businessComputer:onJobDeclined', jobsStore.handleJobDeclined)
  bridge.events.on('businessComputer:onJobAbandoned', jobsStore.handleJobAbandoned)
  bridge.events.on('businessComputer:onJobCompleted', jobsStore.handleJobCompleted)
  bridge.events.on('businessComputer:onTechAssigned', techsStore.handleTechAssigned)
  bridge.events.on('businessComputer:onVehiclePulledOut', vehiclesStore.handleVehiclePulledOut)
  bridge.events.on('businessComputer:onVehiclePutAway', vehiclesStore.handleVehiclePutAway)
  bridge.events.on('businessComputer:onPersonalVehicleSelected', vehiclesStore.handlePersonalVehicleSelected)
  bridge.events.on('businessSkillTree:onTreesUpdated', skillsStore.handleSkillTreesUpdated)
  bridge.events.on("businessComputer:onAvailableRaceTypesReceived", skillsStore.handleAvailableRaceTypesReceived)
  bridge.events.on("businessComputer:onKitsUpdated", kitsStore.handleKitsUpdated)
  bridge.events.on("businessComputer:onKitInstallComplete", vehiclesStore.handleKitInstallComplete)
}

// Public cross-tab actions ----------------------------------------------------
export const useBusinessComputerStore = defineStore("overhaulBusinessComputer", () => {
  const bridge = useBridge()
  const sessionStore = useBusinessSessionStore()
  const racingStore = useBusinessRacingTeamStore()
  const techsStore = useBusinessTechsStore()
  const jobsStore = useBusinessJobsStore()
  const cartStore = useBusinessCartStore()
  const vehiclesStore = useBusinessVehiclesStore()
  const partsStore = useBusinessPartsStore()
  const tuningStore = useBusinessTuningStore()
  const kitsStore = useBusinessKitsStore()
  const buildStore = useBusinessBuildStore()
  const skillsStore = useBusinessSkillsStore()

  const vehicleSelection = createVehicleSelectionActions(sessionStore, cartStore, tuningStore, partsStore)
  const viewActions = createViewActions(sessionStore, cartStore, tuningStore)
  const menuActions = createMenuActions(sessionStore, racingStore, techsStore, cartStore)
  bindBusinessComputerEvents(bridge, buildStore, jobsStore, techsStore, partsStore, racingStore, vehiclesStore, skillsStore, kitsStore)

  return { ...vehicleSelection, ...viewActions, ...menuActions }
})
