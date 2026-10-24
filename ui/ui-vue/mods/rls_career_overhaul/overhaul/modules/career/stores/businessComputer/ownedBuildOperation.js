// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

import { watch, onScopeDispose } from "vue"
import { lua } from "@/bridge"

const REQUEST_NONCE_BYTES = 16 // 128 bits of UI correlation entropy; no gameplay RNG is used.
const requestNonce = () => {
  if (typeof globalThis.crypto?.getRandomValues !== "function") throw new Error("Secure build request identity is unavailable")
  const bytes = new Uint8Array(REQUEST_NONCE_BYTES)
  globalThis.crypto.getRandomValues(bytes)
  return Array.from(bytes, byte => byte.toString(16).padStart(2, "0")).join("")
}

// One pending build per store. Both a server token and a cryptographic UI nonce must match before publication.
export const createOwnedBuildOperation = ({ businessId, pulledOutVehicle, isMenuActive, cartTabs,
  activeTabId, partsCart, tuningCart, currentAppliedCartHash }) => {
  let pending = null
  const snapshot = () => ({
    businessId: businessId.value, vehicle: pulledOutVehicle.value, vehicleId: pulledOutVehicle.value?.vehicleId,
    tabs: cartTabs.value, tabId: activeTabId.value, menu: isMenuActive.value,
    cart: JSON.stringify([partsCart.value, tuningCart.value]),
    tabsContent: JSON.stringify(cartTabs.value), applied: currentAppliedCartHash.value
  })
  const matches = owner => {
    const current = snapshot()
    return Object.keys(owner).every(key => current[key] === owner[key])
  }
  const cancelExact = operation => {
    if (operation.requestId == null || operation.cancelSent) return
    operation.cancelSent = true
    try {
      Promise.resolve(lua.overhaul_career_business_computer.cancelBuildOperation(
        operation.owner.businessId, operation.owner.vehicleId, operation.id, operation.requestId, operation.nonce
      )).catch(error => console.error("Build cancellation failed", error))
    } catch (error) { console.error("Build cancellation failed", error) }
  }
  const settle = (operation, success, cancel = false) => {
    if (pending !== operation) return
    pending = null
    clearTimeout(operation.timer)
    operation.stop()
    if (cancel) { operation.cancelled = true; cancelExact(operation) }
    operation.resolve(success)
  }
  const cancel = () => { if (pending) settle(pending, false, true) }
  onScopeDispose(cancel)

  const applyBuild = (build, publish) => {
    if (pending || !isMenuActive.value) return Promise.resolve(false)
    if (!businessId.value || !pulledOutVehicle.value?.vehicleId) {
      currentAppliedCartHash.value = null
      publish(false)
      return Promise.resolve(true)
    }
    let nonce
    try { nonce = requestNonce() } catch (error) {
      console.error("Build request failed", error)
      return Promise.resolve(false)
    }
    currentAppliedCartHash.value = null
    const operation = { id: nonce, nonce, owner: snapshot(), publish, stop: () => {}, earlyEvents: [] }
    const promise = new Promise(resolve => { operation.resolve = resolve })
    pending = operation
    operation.stop = watch(snapshot, () => {
      if (pending === operation && !matches(operation.owner)) settle(operation, false, true)
    }, { deep: true, flush: "sync" })
    // A timeout is failure, including when the acceptance RPC never returns. It never supplies completion.
    operation.timer = setTimeout(() => settle(operation, false, true), 35_000)
    try {
      Promise.resolve(lua.overhaul_career_business_computer.applyBuildToVehicle(
        operation.owner.businessId, operation.owner.vehicleId, build, operation.id
      )).then(acceptance => {
        if (acceptance?.accepted !== true || !Number.isFinite(acceptance.requestId) || acceptance.nonce !== operation.nonce) {
          settle(operation, false)
          return
        }
        operation.requestId = acceptance.requestId
        if (operation.cancelled || pending !== operation) { cancelExact(operation); return }
        const completion = operation.earlyEvents.find(data => data.requestId === operation.requestId)
        operation.earlyEvents = []
        if (completion) handleBuildOperationCompleted(completion)
      }, error => {
        console.error("Build request failed", error)
        settle(operation, false, true)
      })
    } catch (error) {
      console.error("Build request failed", error)
      settle(operation, false, true)
    }
    return promise
  }

  const handleBuildOperationCompleted = data => {
    const operation = pending
    if (!operation || data?.operationId !== operation.id || data.nonce !== operation.nonce
      || String(data.businessId) !== String(operation.owner.businessId)
      || String(data.vehicleId) !== String(operation.owner.vehicleId)) return
    if (!Number.isFinite(data.requestId)) return
    if (operation.requestId == null) {
      operation.earlyEvents.push(data)
      if (operation.earlyEvents.length > 4) operation.earlyEvents.shift()
      return
    }
    if (data.requestId !== operation.requestId) return
    if (!matches(operation.owner)) { settle(operation, false, true); return }
    if (data.success !== true) { settle(operation, false); return }
    // Stop the watcher before our own publication changes the captured owner.
    operation.stop()
    try {
      operation.publish(true)
      settle(operation, true)
    } catch (error) {
      console.error("Build publication failed", error)
      currentAppliedCartHash.value = null
      settle(operation, false)
    }
  }

  return { applyBuild, isBuildPending: () => pending !== null, handleBuildOperationCompleted }
}
