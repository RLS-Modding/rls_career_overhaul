// Dense bridge rows keep repeated field names and physical condition blobs out of the payload.
// Keep this schema in step with partInventory/ui.lua.
function unpackPart([id, name, description, vehicleModel, vehicleModelDisplayName, odometer,
  finalValue, location, accessible, missingFile, repairCount, primered]) {
  return { id, name, description: { description }, vehicleModel: vehicleModel === false ? undefined : vehicleModel,
    vehicleModelDisplayName, partCondition: { odometer: odometer === false ? undefined : odometer },
    finalValue, location, accessible, missingFile, repairCount, primered }
}

const asArray = value => Array.isArray(value) ? value : []

export function createPartsInventoryReceiver() {
  let rows = new Map(), order = [], generation = null, revision = 0, pending = null
  function reset() {
    rows.clear()
    order = []
    revision = 0
    generation = null
    pending = null
  }
  function accept(message) {
    if (generation !== null && message.generation < generation) return null
    if (message.generation === generation && message.revision <= revision) return null
    if (message.batch === 1) {
      // A delta needs its committed base, including every preceding mutation.
      if (!message.reset && (message.generation !== generation || message.revision !== revision + 1)) return null
      if (pending && (message.generation < pending.generation ||
        (message.generation === pending.generation && message.revision <= pending.revision))) return null
      pending = { generation: message.generation, revision: message.revision, batch: 0, reset: message.reset,
        replaceOrder: message.replaceOrder, rows: [], removedIds: [], order: [] }
    }
    if (!pending || pending.generation !== message.generation || pending.revision !== message.revision ||
      message.batch !== pending.batch + 1) return null
    pending.batch = message.batch
    pending.rows.push(...asArray(message.rows))
    pending.removedIds.push(...asArray(message.removedIds))
    pending.order.push(...asArray(message.order))
    if (!message.complete) return null

    // Commit once, so filtering, grouping and focus never see a partial inventory.
    if (pending.reset) rows = new Map()
    for (const id of pending.removedIds) rows.delete(id)
    for (const row of pending.rows) rows.set(row[0], unpackPart(row))
    if (pending.replaceOrder) order = pending.order
    generation = pending.generation
    revision = pending.revision
    pending = null
    return { ...message.data, partList: order.map(id => rows.get(id)).filter(Boolean) }
  }
  return { accept, reset }
}
