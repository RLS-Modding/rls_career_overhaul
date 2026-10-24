// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// Replay each operation's own edits instead of restoring a shared whole-cart snapshot.
const copyCart = cart => cart.map(row => ({ ...row }))
const rowKey = row => row.slotPath || row.id
// Lua cart updates normalize display-only fields; they are not independent writes to a slot.
const rowValue = row => JSON.stringify(Object.entries(row).filter(([key]) => key !== 'id' && key !== 'canRemove')
  .sort(([a], [b]) => a.localeCompare(b)))
const changesBetween = (before, after) => {
  const oldRows = new Map(before.map(row => [rowKey(row), row]))
  const newRows = new Map(after.map(row => [rowKey(row), row]))
  return {
    removed: before.filter(row => !newRows.has(rowKey(row)) || rowValue(row) !== rowValue(newRows.get(rowKey(row)))).map(rowKey),
    added: after.filter(row => !oldRows.has(rowKey(row)) || rowValue(row) !== rowValue(oldRows.get(rowKey(row)))).map(row => ({ ...row }))
  }
}
const applyChanges = (cart, change) => [...cart.filter(row => !change.removed.includes(rowKey(row)) && !change.added.some(added => rowKey(added) === rowKey(row))), ...copyCart(change.added)]

// A delayed add reply/event contributes only changes relative to the cart it was given.
export const mergePartsCartUpdate = (current, source, result) => {
  const intervening = changesBetween(source, current)
  return !intervening.removed.length && !intervening.added.length
    ? copyCart(result) : applyChanges(current, changesBetween(source, result))
}

export const createPartsCartOperations = ({ partsCart, partsCartRollback, businessId, pulledOutVehicle,
  activeTabId, cartTabs, saveCurrentTabState, currentAppliedCartHash, generateCartHash, tuningCart }) => {
  let sequence = 0
  const journals = new Map()
  const ownerMatches = (operation, context = {}) =>
    String(operation.businessId) === String(context.businessId ?? businessId.value) &&
    String(operation.vehicleId) === String(context.vehicleId ?? pulledOutVehicle.value?.vehicleId)
  const isActive = operation => ownerMatches(operation) && operation.tabId === activeTabId.value
  const publishPending = () => {
    partsCartRollback.value = [...journals.values()].flatMap(journal => journal.operations)
      .find(operation => operation.status === 'pending') || null
  }
  // Keep edits made outside a removal (for example adding another cart row) when replaying.
  const captureOtherEdits = (journal, cart) => {
    const changes = changesBetween(journal.projected, cart)
    if (changes.removed.length || changes.added.length) journal.operations.push({ status: 'succeeded', changes })
  }
  const setPartsCartRollback = (cart, appliedCart = partsCart.value, writtenPaths = [], correlated = false) => {
    if (!businessId.value || !pulledOutVehicle.value?.vehicleId || !Array.isArray(cart)) return null
    const key = JSON.stringify([String(businessId.value), String(pulledOutVehicle.value.vehicleId), activeTabId.value])
    let journal = journals.get(key)
    if (!journal) {
      journal = { baseline: copyCart(cart), projected: copyCart(cart), operations: [] }
      journals.set(key, journal)
    } else {
      captureOtherEdits(journal, cart)
    }
    const changes = changesBetween(cart, appliedCart)
    // Identical writes still belong to this operation: an earlier failed write cannot erase them.
    for (const path of writtenPaths) {
      if (!changes.removed.includes(path)) changes.removed.push(path)
      if (!changes.added.some(row => rowKey(row) === path)) {
        const row = appliedCart.find(row => rowKey(row) === path)
        if (row) changes.added.push({ ...row })
      }
    }
    const operation = {
      operationId: `parts-${++sequence}`, businessId: businessId.value, vehicleId: pulledOutVehicle.value.vehicleId,
      tabId: activeTabId.value, cart: copyCart(cart), changes, correlated, status: 'pending'
    }
    journal.operations.push(operation)
    journal.projected = copyCart(appliedCart)
    publishPending()
    return operation.operationId
  }
  const restorePartsCartRollback = (context = {}) => {
    const pending = [...journals.entries()].flatMap(([key, journal]) => journal.operations
      .filter(operation => operation.status === 'pending' && ownerMatches(operation, context))
      .map(operation => ({ key, journal, operation })))
    // Legacy untagged events are safe only when exactly one operation could own them.
    const owned = context.operationId != null
      ? pending.find(({ operation }) => operation.operationId === context.operationId)
      : pending.length === 1 ? pending[0] : null
    if (!owned || !ownerMatches(owned.operation) || (context.succeeded && context.operationId == null && owned.operation.correlated)) return false
    const { key, journal, operation } = owned
    const tab = cartTabs.value.find(tab => tab.id === operation.tabId)
    if (!tab) { journals.delete(key); publishPending(); return false }
    const active = isActive(operation)
    captureOtherEdits(journal, active ? partsCart.value : tab.parts || [])
    operation.status = context.succeeded ? 'succeeded' : 'failed'
    if (!context.succeeded) {
      const restored = journal.operations.filter(operation => operation.status !== 'failed')
        .reduce((cart, operation) => applyChanges(cart, operation.changes), copyCart(journal.baseline))
      if (active) {
        partsCart.value = restored
        saveCurrentTabState()
        currentAppliedCartHash.value = generateCartHash(partsCart.value, tuningCart.value)
      } else {
        tab.parts = restored
        tab.cartHash = generateCartHash(restored, tab.tuning)
      }
    }
    journal.projected = copyCart(active ? partsCart.value : tab.parts || [])
    if (!journal.operations.some(operation => operation.status === 'pending')) journals.delete(key)
    publishPending()
    return true
  }
  const clearPartsCartOperations = () => { journals.clear(); partsCartRollback.value = null }
  return { setPartsCartRollback, restorePartsCartRollback, clearPartsCartOperations }
}
