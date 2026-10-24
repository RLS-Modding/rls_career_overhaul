// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

import { anchorBusinessTimers } from "./businessTime.js"
import { defineStore, storeToRefs } from "pinia"
import { lua, useBridge } from "@/bridge"
import { normalizeId } from "../../utils/businessUtils"
import { moneyText } from "../../utils/units"
import { showErrorMessage } from "./businessBridge.js"
import { useBusinessSessionStore } from "./businessSessionStore.js"
import { useBusinessCartStore } from "./businessCartStore.js"

// Vehicles tab: pull out and put away, personal vehicles, shop services (repair, paint, refuel, maintenance, tires)
// and the events that keep the pulled-out list current. Start reading at pullOutVehicle and handleVehiclePulledOut.
// Each phase is a factory above the store that takes the session refs and actions it uses; the setup below wires them.

// Vehicle selection and lifecycle: sell, pull out, personal vehicle selection and put away.
function createVehicleLifecycleActions(context) {
  const {
    businessId, businessType, pulledOutVehicle, activeVehicleId, isDamageLocked, loadBusinessData, getLuaModule,
    getBusinessVehicleById, showDamageLockWarning, normalizeLuaResult, clearCachesForVehicle
  } = context

  const sellVehicle = async (vehicleId) => {
    if (!businessId.value || vehicleId === undefined || vehicleId === null || vehicleId === "") return false
    try {
      const success = await lua.overhaul_career_business_computer.sellVehicle(businessId.value, vehicleId)
      if (success) {
        await loadBusinessData(businessType.value, businessId.value)
      }
      return !!success
    } catch (error) {
      return false
    }
  }

  const pullOutDiag = (...args) => {
    try {
      console.debug("[rlsBizPull]", ...args)
    } catch (_) {}
  }

  const pullOutVehicle = async (vehicleId) => {
    if (!businessId.value) {
      pullOutDiag("pullOutVehicle abort: no businessId", { vehicleId })
      return false
    }
    if (isDamageLocked.value) {
      pullOutDiag("pullOutVehicle abort: damageLocked", { businessId: businessId.value, vehicleId })
      showDamageLockWarning()
      return false
    }
    try {
      pullOutDiag("pullOutVehicle calling Lua", { businessId: businessId.value, vehicleId })
      const raw = await lua.overhaul_career_business_computer.pullOutVehicle(businessId.value, vehicleId)
      pullOutDiag("pullOutVehicle Lua raw", { businessId: businessId.value, vehicleId, raw })
      if (raw && typeof raw === "object" && raw.success === false) {
        pullOutDiag("pullOutVehicle Lua failure", { errorCode: raw.errorCode, message: raw.message })
      }
      const success = normalizeLuaResult(raw)
      if (!success) {
        pullOutDiag("pullOutVehicle normalized false", { businessId: businessId.value, vehicleId })
      }
      return !!success
    } catch (error) {
      pullOutDiag("pullOutVehicle exception", { businessId: businessId.value, vehicleId, error })
      return false
    }
  }

  const selectPersonalVehicle = async (inventoryId) => {
    if (!businessId.value) {
      return false
    }
    try {
      const result = await getLuaModule().selectPersonalVehicle(businessId.value, inventoryId)
      if (result && result.success) {
        return true
      }
      if (result && result.message) {
        showErrorMessage(result.message)
      }
      return false
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
      const normalizedTargetId = normalizeId(targetVehicleId)
      const targetVehicleEntry = normalizedTargetId ? getBusinessVehicleById(normalizedTargetId) : null
      const cacheVehicleId = targetVehicleEntry?.vehicleId ?? targetVehicleId
      // Always use businessComputer for vehicle operations - it triggers UI events
      const success = normalizeLuaResult(await lua.overhaul_career_business_computer.putAwayVehicle(businessId.value, targetVehicleId))
      if (success) {
        clearCachesForVehicle(cacheVehicleId)
        try {
          lua.overhaul_career_business_computer.clearVehicleDataCaches()
        } catch (error) {
        }
        if (!vehicleId || normalizeId(vehicleId) === normalizeId(pulledOutVehicle.value?.vehicleId)) {
          pulledOutVehicle.value = null
          activeVehicleId.value = null
        }
      }
      return !!success
    } catch (error) {
      return false
    }
  }

  return { sellVehicle, pullOutVehicle, selectPersonalVehicle, putAwayVehicle }
}

// Shop services on a pulled-out vehicle: repair, paint and refuel.
function createShopServiceActions(context) {
  const { bridge, businessId, businessType, pulledOutVehicle, loadBusinessData } = context

  const repairBusinessVehicle = async (vehicleId) => {
    if (!businessId.value) return { success: false }
    try {
      const vid = vehicleId ?? pulledOutVehicle.value?.vehicleId ?? null
      if (vid === null || vid === undefined) return { success: false }
      const result = await lua.overhaul_career_business_computer.repairBusinessVehicleDamage(
        businessId.value,
        vid
      )
      if (result && result.success) {
        await loadBusinessData(businessType.value, businessId.value)
      } else if (result && result.errorCode === "noFunds" && typeof result.cost === "number") {
        showErrorMessage(`Not enough funds in the business account (repair ${moneyText(bridge.units, result.cost)}).`)
      } else if (result && result.errorCode === "notPulledOut") {
        showErrorMessage("Pull the vehicle out before repairing.")
      } else if (result && result.errorCode === "nothingToRepair") {
        showErrorMessage("Nothing to repair on this vehicle.")
      } else if (result && result.errorCode === "noVehicle") {
        showErrorMessage("Vehicle not found.")
      } else if (result && result.errorCode === "unknownBusiness") {
        showErrorMessage("Business context missing. Close and reopen the business computer, then try again.")
      } else if (result && result.errorCode === "noInventory") {
        showErrorMessage("Garage inventory is not available right now.")
      } else if (result && result.errorCode === "noBank") {
        showErrorMessage("Bank system unavailable. Cannot process repair payment.")
      } else if (result && result.errorCode === "noAccount") {
        showErrorMessage("No business account found for this garage.")
      } else if (result && result.errorCode === "repairFailed") {
        showErrorMessage(
          typeof result.cost === "number"
            ? `Repair failed. If money was charged, it should have been refunded (${moneyText(bridge.units, result.cost)}).`
            : "Repair failed. Try again."
        )
      } else if (result && result.errorCode === "badArgs") {
        showErrorMessage("Invalid repair request.")
      } else if (result && !result.success) {
        const code = result.errorCode ? ` (${result.errorCode})` : ""
        showErrorMessage(`Repair could not be completed${code}.`)
      }
      return result || { success: false }
    } catch (error) {
      console.error("repairBusinessVehicle", error)
      showErrorMessage("Repair failed due to an unexpected error.")
      return { success: false }
    }
  }

  const startVehiclePainting = async (vehicleId) => {
    if (!businessId.value) return { success: false }
    const vid = vehicleId ?? pulledOutVehicle.value?.vehicleId ?? null
    if (vid === null || vid === undefined) {
      showErrorMessage("Pull out a fleet vehicle first to paint it.")
      return { success: false }
    }
    try {
      const result = await lua.overhaul_career_business_computer.startVehiclePainting(
        businessId.value,
        vid
      )
      if (result && result.success) {
        return result
      }
      switch (result && result.errorCode) {
        case "notPulledOut":
          showErrorMessage("Pull the vehicle out before painting.")
          break
        case "unsupportedBusiness":
          showErrorMessage("Painting isn't available at this business yet.")
          break
        case "needsRepair":
          showErrorMessage("Repair the vehicle before painting.")
          break
        case "unknownBusiness":
          showErrorMessage("Business context missing. Close and reopen the business computer, then try again.")
          break
        case "noInventory":
          showErrorMessage("Garage inventory is not available right now.")
          break
        case "paintingUnavailable":
          showErrorMessage("Painting system is unavailable. Try again after saving and reloading.")
          break
        case "badArgs":
          showErrorMessage("Invalid painting request.")
          break
        case "noVehicle":
          showErrorMessage("Vehicle not found.")
          break
        default:
          if (result && !result.success) {
            const code = result.errorCode ? ` (${result.errorCode})` : ""
            showErrorMessage(`Painting could not be started${code}.`)
          }
      }
      return result || { success: false }
    } catch (error) {
      console.error("startVehiclePainting", error)
      const msg = String(error?.message || error || "")
      if (msg.includes("is not a function")) {
        showErrorMessage(
          "Painting backend is out of date. Open the in-game console and run `luareload`, or reload the career save."
        )
      } else {
        showErrorMessage("Painting failed due to an unexpected error.")
      }
      return { success: false }
    }
  }

  const startVehicleRefueling = async (vehicleId) => {
    if (!businessId.value) return { success: false }
    const vid = vehicleId ?? pulledOutVehicle.value?.vehicleId ?? null
    if (vid === null || vid === undefined) {
      showErrorMessage("Pull out a fleet vehicle first to refuel it.")
      return { success: false }
    }
    try {
      const result = await lua.overhaul_career_business_computer.startVehicleRefueling(
        businessId.value,
        vid
      )
      if (result && result.success) {
        return result
      }
      switch (result && result.errorCode) {
        case "notPulledOut":
          showErrorMessage("Pull the vehicle out before refueling.")
          break
        case "unsupportedBusiness":
          showErrorMessage("Shop refueling isn't available at this business yet.")
          break
        case "pitFuelLocked":
          showErrorMessage("Unlock the Pit Fuel skill in Team Ops to refuel at the shop.")
          break
        case "unknownBusiness":
          showErrorMessage("Business context missing. Close and reopen the business computer, then try again.")
          break
        case "noInventory":
          showErrorMessage("Garage inventory is not available right now.")
          break
        case "fuelingUnavailable":
          showErrorMessage("Fueling system is unavailable. Try again after saving and reloading.")
          break
        case "badArgs":
          showErrorMessage("Invalid refueling request.")
          break
        default:
          if (result && !result.success) {
            const code = result.errorCode ? ` (${result.errorCode})` : ""
            showErrorMessage(`Refueling could not be started${code}.`)
          }
      }
      return result || { success: false }
    } catch (error) {
      console.error("startVehicleRefueling", error)
      const msg = String(error?.message || error || "")
      if (msg.includes("is not a function")) {
        showErrorMessage(
          "Refueling backend is out of date. Open the in-game console and run `luareload`, or reload the career save."
        )
      } else {
        showErrorMessage("Refueling failed due to an unexpected error.")
      }
      return { success: false }
    }
  }

  return { repairBusinessVehicle, startVehiclePainting, startVehicleRefueling }
}

// Maintenance and tire services for a pulled-out vehicle.
function createMaintenanceActions(context) {
  const { businessId, businessType, pulledOutVehicle } = context

  const startBusinessMaintenanceService = async (vehicleId, categoryName, itemName) => {
    if (!businessId.value || !businessType.value) return { ok: false }
    const vid = vehicleId ?? pulledOutVehicle.value?.vehicleId ?? null
    if (vid === null || vid === undefined || vid === "") {
      showErrorMessage("Pull out a fleet vehicle first to maintain it.")
      return { ok: false }
    }
    if (!categoryName || !itemName) {
      showErrorMessage("Missing maintenance item selection.")
      return { ok: false }
    }
    try {
      const result = await lua.overhaul_career_maintenance_maintenanceComputer.startServiceForBusinessVehicle(
        Number(vid),
        categoryName,
        itemName,
        businessType.value,
        businessId.value
      )
      if (result && result.ok) {
        return result
      }
      if (result && result.message) {
        showErrorMessage(result.message)
      } else {
        showErrorMessage("Unable to complete maintenance service.")
      }
      return result || { ok: false }
    } catch (error) {
      console.error("startBusinessMaintenanceService", error)
      showErrorMessage("Maintenance service failed due to an unexpected error.")
      return { ok: false }
    }
  }

  const getBusinessMaintenanceUiData = async (vehicleId) => {
    const vid = vehicleId ?? pulledOutVehicle.value?.vehicleId ?? null
    if (vid === null || vid === undefined || vid === "") {
      return { enabled: false, errorMessage: "Pull out a fleet vehicle first to maintain it." }
    }
    try {
      const result = await lua.overhaul_career_maintenance_maintenanceComputer.getMaintenanceUiDataForBusinessVehicle(
        Number(vid), businessType.value, businessId.value
      )
      return result || { enabled: false, errorMessage: "Unable to load maintenance data." }
    } catch (error) {
      console.error("getBusinessMaintenanceUiData", error)
      return { enabled: false, errorMessage: "Failed to load maintenance data." }
    }
  }

  const startBusinessMaintenanceCheck = async (vehicleId, categoryName, itemName) => {
    const vid = vehicleId ?? pulledOutVehicle.value?.vehicleId ?? null
    if (vid === null || vid === undefined || vid === "") {
      showErrorMessage("Pull out a fleet vehicle first to maintain it.")
      return { ok: false }
    }
    try {
      const result = await lua.overhaul_career_maintenance_maintenanceComputer.startCheckForBusinessVehicle(
        Number(vid),
        categoryName,
        itemName,
        businessType.value,
        businessId.value
      )
      if (!result?.ok) {
        showErrorMessage(result?.message || "Unable to complete maintenance check.")
      }
      return result || { ok: false }
    } catch (error) {
      console.error("startBusinessMaintenanceCheck", error)
      showErrorMessage("Maintenance check failed due to an unexpected error.")
      return { ok: false }
    }
  }

  const inspectBusinessVehicleTires = async (vehicleId) => {
    const vid = vehicleId ?? pulledOutVehicle.value?.vehicleId ?? null
    if (vid === null || vid === undefined || vid === "") {
      showErrorMessage("Pull out a fleet vehicle first to inspect its tires.")
      return { ok: false }
    }
    try {
      const result = await lua.overhaul_career_maintenance_maintenanceComputer.inspectBusinessVehicleTires(
        Number(vid), businessType.value, businessId.value
      )
      if (!result?.ok) showErrorMessage(result?.message || "Unable to inspect tires.")
      return result || { ok: false }
    } catch (error) {
      console.error("inspectBusinessVehicleTires", error)
      showErrorMessage("Tire inspection failed due to an unexpected error.")
      return { ok: false }
    }
  }

  const checkoutBusinessVehicleTires = async (vehicleId, axleIds, quoteRevision) => {
    if (!businessId.value || !businessType.value) return { ok: false }
    const vid = vehicleId ?? pulledOutVehicle.value?.vehicleId ?? null
    if (vid === null || vid === undefined || vid === "") {
      showErrorMessage("Pull out a fleet vehicle first to replace its tires.")
      return { ok: false }
    }
    try {
      const result = await lua.overhaul_career_maintenance_maintenanceComputer.checkoutTiresForBusinessVehicle(
        Number(vid), axleIds, quoteRevision, businessType.value, businessId.value
      )
      if (!result?.ok) showErrorMessage(result?.message || "Unable to replace tires.")
      return result || { ok: false }
    } catch (error) {
      console.error("checkoutBusinessVehicleTires", error)
      showErrorMessage("Tire replacement failed due to an unexpected error.")
      return { ok: false }
    }
  }

  return {
    startBusinessMaintenanceService, getBusinessMaintenanceUiData, startBusinessMaintenanceCheck,
    inspectBusinessVehicleTires, checkoutBusinessVehicleTires
  }
}

// Listeners that keep the pulled-out list, the active vehicle and the business record current.
function createVehicleListeners(context) {
  const { businessId, isMenuActive, businessData, pulledOutVehicle, pulledOutVehicles, activeVehicleId } = context

  const handleVehiclePulledOut = (data) => {
    data = anchorBusinessTimers(data)
    if (String(data.businessId) !== String(businessId.value)) return
    const vehiclesFromData = Array.isArray(data.pulledOutVehicles) ? data.pulledOutVehicles : []
    pulledOutVehicles.value = vehiclesFromData
    
    // For personal vehicles, onPersonalVehicleSelected already set activeVehicleId correctly
    // Only update the vehicle list, don't overwrite activeVehicleId
    if (data.isPersonalVehicle) {
      // Just ensure the vehicle list is updated, but preserve activeVehicleId
      const currentActiveId = activeVehicleId.value
      if (currentActiveId) {
        const currentActiveVehicle = vehiclesFromData.find(v => normalizeId(v?.vehicleId) === normalizeId(currentActiveId))
        if (currentActiveVehicle) {
          pulledOutVehicle.value = currentActiveVehicle
        }
      }
    } else {
      // For job vehicles, update activeVehicleId normally
      if (data.vehicleId) {
        const foundVehicle = vehiclesFromData.find(v => normalizeId(v?.vehicleId) === normalizeId(data.vehicleId))
        if (foundVehicle) {
          // Always update activeVehicleId for job vehicles when vehicleId is provided
          activeVehicleId.value = foundVehicle.vehicleId
          pulledOutVehicle.value = foundVehicle
        } else {
          // Vehicle not found in list, but still set the vehicleId
          activeVehicleId.value = data.vehicleId
          pulledOutVehicle.value = null
        }
      } else {
        // No vehicleId provided, preserve current active if it exists in new list
        const currentActiveId = activeVehicleId.value
        if (currentActiveId) {
          const currentActiveVehicle = vehiclesFromData.find(v => normalizeId(v?.vehicleId) === normalizeId(currentActiveId))
          if (currentActiveVehicle) {
            activeVehicleId.value = currentActiveVehicle.vehicleId
            pulledOutVehicle.value = currentActiveVehicle
          }
        }
      }
    }
    
    businessData.value = {
      ...businessData.value,
      vehicles: data.vehicles || [],
      pulledOutVehicles: vehiclesFromData,
      maxPulledOutVehicles: data.maxPulledOutVehicles ?? businessData.value.maxPulledOutVehicles
    }
  }

  const handleVehiclePutAway = (data) => {
    data = anchorBusinessTimers(data)
    if (String(data.businessId) !== String(businessId.value)) return
    const vehiclesFromData = Array.isArray(data.pulledOutVehicles) ? data.pulledOutVehicles : []
    pulledOutVehicles.value = vehiclesFromData
    if (vehiclesFromData.length === 0) {
      pulledOutVehicle.value = null
      activeVehicleId.value = null
    } else if (data.vehicleId && normalizeId(pulledOutVehicle.value?.vehicleId) === normalizeId(data.vehicleId)) {
      pulledOutVehicle.value = vehiclesFromData[0] || null
      activeVehicleId.value = pulledOutVehicle.value?.vehicleId || null
    }
    businessData.value = {
      ...businessData.value,
      vehicles: data.vehicles || [],
      pulledOutVehicles: vehiclesFromData,
      maxPulledOutVehicles: data.maxPulledOutVehicles ?? businessData.value.maxPulledOutVehicles
    }
  }

  const handlePersonalVehicleSelected = (data) => {
    data = anchorBusinessTimers(data)
    if (String(data.businessId) !== String(businessId.value)) return
    if (data.vehicle && data.vehicle.vehicleId) {
      // Ensure the vehicle is in pulledOutVehicles list
      const currentVehicles = Array.isArray(pulledOutVehicles.value) ? pulledOutVehicles.value : []
      const existingVehicle = currentVehicles.find(v => normalizeId(v?.vehicleId) === normalizeId(data.vehicle.vehicleId))
      if (existingVehicle) {
        // Use the exact vehicleId from pulledOutVehicles to ensure consistency with sidebar
        activeVehicleId.value = existingVehicle.vehicleId
        pulledOutVehicle.value = existingVehicle
      } else {
        // Vehicle not in list yet, add it and use its vehicleId
        pulledOutVehicles.value = [...currentVehicles, data.vehicle]
        activeVehicleId.value = data.vehicle.vehicleId
        pulledOutVehicle.value = data.vehicle
      }
    }
  }

  const handleKitInstallComplete = async (data) => {
    if (!isMenuActive.value) return
    if (data && data.businessId && String(data.businessId) === String(businessId.value)) {
      // Refresh vehicle data to update kit install lock status
      try {
        const result = await lua.overhaul_career_business_computer.getVehiclesOnly(businessId.value)
        const vehiclesData = result && anchorBusinessTimers(result)
        if (vehiclesData) {
          const vehiclesFromData = Array.isArray(vehiclesData.pulledOutVehicles)
            ? vehiclesData.pulledOutVehicles
            : []
          pulledOutVehicles.value = vehiclesFromData
          businessData.value = {
            ...businessData.value,
            vehicles: vehiclesData.vehicles || [],
            pulledOutVehicles: vehiclesFromData,
            maxPulledOutVehicles: vehiclesData.maxPulledOutVehicles ?? businessData.value.maxPulledOutVehicles
          }
        }
      } catch (error) {
      }
    }
  }

  return { handleVehiclePulledOut, handleVehiclePutAway, handlePersonalVehicleSelected, handleKitInstallComplete }
}

export const useBusinessVehiclesStore = defineStore("overhaulBusinessVehicles", () => {
  const bridge = useBridge()
  const sessionStore = useBusinessSessionStore()
  const {
    businessData, pulledOutVehicle, pulledOutVehicles, activeVehicleId, isMenuActive, businessId, businessType,
    isDamageLocked
  } = storeToRefs(sessionStore)
  const {
    getBusinessVehicleById, showDamageLockWarning, normalizeLuaResult, loadBusinessData, getLuaModule
  } = sessionStore
  const cartStore = useBusinessCartStore()
  const { clearCachesForVehicle } = cartStore

  const { sellVehicle, pullOutVehicle, selectPersonalVehicle, putAwayVehicle } = createVehicleLifecycleActions({
    businessId, businessType, pulledOutVehicle, activeVehicleId, isDamageLocked, loadBusinessData, getLuaModule,
    getBusinessVehicleById, showDamageLockWarning, normalizeLuaResult, clearCachesForVehicle
  })
  const { repairBusinessVehicle, startVehiclePainting, startVehicleRefueling } = createShopServiceActions({
    bridge, businessId, businessType, pulledOutVehicle, loadBusinessData
  })
  const {
    startBusinessMaintenanceService, getBusinessMaintenanceUiData, startBusinessMaintenanceCheck,
    inspectBusinessVehicleTires, checkoutBusinessVehicleTires
  } = createMaintenanceActions({ businessId, businessType, pulledOutVehicle })
  const {
    handleVehiclePulledOut, handleVehiclePutAway, handlePersonalVehicleSelected, handleKitInstallComplete
  } = createVehicleListeners({ businessId, isMenuActive, businessData, pulledOutVehicle, pulledOutVehicles, activeVehicleId })

  return {
    sellVehicle,
    pullOutVehicle,
    selectPersonalVehicle,
    repairBusinessVehicle,
    startVehiclePainting,
    startVehicleRefueling,
    startBusinessMaintenanceService,
    getBusinessMaintenanceUiData,
    startBusinessMaintenanceCheck,
    inspectBusinessVehicleTires,
    checkoutBusinessVehicleTires,
    putAwayVehicle,
    handleVehiclePulledOut,
    handleVehiclePutAway,
    handlePersonalVehicleSelected,
    handleKitInstallComplete
  }
})