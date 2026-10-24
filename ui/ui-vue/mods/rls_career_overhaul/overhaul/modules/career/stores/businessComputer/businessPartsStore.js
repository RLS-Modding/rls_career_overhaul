// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

import { mergePartsCartUpdate } from "./partsCartOperations.js"
import { computed } from "vue"
import { defineStore, storeToRefs } from "pinia"
import { lua } from "@/bridge"
import { useBusinessSessionStore } from "./businessSessionStore.js"
import { useBusinessCartStore } from "./businessCartStore.js"

// Parts tab: the vehicle parts tree, the part inventory, and adding or removing parts in the cart.
// Start reading at removePartBySlotPath.

const METRES_PER_MILE = 1609.344
const TREE_REFRESH_DELAY_MS = 500

/** The node with this id in a parts tree, searched depth first; null when absent. */
const findNodeById = (nodes, id) => {
  for (const node of nodes) {
    if (node.id === id) return node
    const found = findNodeById(node.children || [], id)
    if (found) return found
  }
  return null
}

const descendantIds = (node) => (node.children || []).flatMap(child => [child.id, ...descendantIds(child)])

/** `targetId` plus the ids of everything installed below it, in each root of the tree that holds it. */
const idsWithDescendants = (tree, targetId) => {
  const ids = [targetId]
  for (const root of tree) {
    const match = findNodeById([root], targetId)
    if (match) ids.push(...descendantIds(match))
  }
  return ids
}

/** Slot paths of every installed part below `node`, from the vehicle's original parts tree. */
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

const partNiceNameOf = (partName, partsNiceName) => {
  if (partsNiceName && partsNiceName[partName]) {
    const niceName = partsNiceName[partName]
    return typeof niceName === 'object' ? (niceName.description || niceName) : niceName
  }
  return partName
}

/** A cart row that empties `slotPath`. */
const removalMarker = (slotPath, partNiceName) => ({
  type: 'part',
  partName: '',
  partNiceName: `Removed ${partNiceName}`,
  slotPath,
  slotNiceName: '',
  price: 0,
  emptyPlaceholder: true,
  id: `${slotPath}_empty`
})

/** A copy of each cart row, so the rollback copy does not share objects with the live cart. */
const copyCart = (cart) => cart.map(item => ({ ...item }))

/** A slot path with a leading and a trailing slash, the form the parts tree keys its nodes by. */
const normalizeSlotPath = (slotPath) => {
  let normalizedPath = (slotPath || '').trim()
  if (!normalizedPath.startsWith('/')) {
    normalizedPath = '/' + normalizedPath
  }
  if (!normalizedPath.endsWith('/')) {
    normalizedPath = normalizedPath + '/'
  }
  return normalizedPath
}

/** The node at `path` in a parts tree; the tree itself for "/", null when a segment is missing. */
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

/** Markers for a part the vehicle came with and for the installed parts under it, from the vehicle's initial state. */
const removalMarkersFor = (initialVehicle, normalizedPath, initialPartName) => {
  const partsNiceName = initialVehicle.partsNiceName || {}
  const childPaths = []
  const node = getNodeFromSlotPath(initialVehicle.config.partsTree, normalizedPath)
  if (node) {
    collectChildSlotPaths(node, normalizedPath, childPaths)
  }

  const removalMarkers = [removalMarker(normalizedPath, partNiceNameOf(initialPartName, partsNiceName))]
  for (const childPath of childPaths) {
    const childPartName = initialVehicle.partList[childPath]
    if (childPartName && childPartName !== '') {
      removalMarkers.push(removalMarker(childPath, partNiceNameOf(childPartName, partsNiceName)))
    }
  }
  return removalMarkers
}

/** The cart row for adding `part` at `slot`. */
const cartRowFor = (part, slot) => ({
  partName: part.name || part.partName,
  partNiceName: part.niceName || part.partNiceName,
  slotPath: slot.path,
  slotNiceName: slot.slotNiceName || slot.slotName,
  price: part.value || 0,
  fromInventory: part.fromInventory || false,
  partId: part.partId || null,
  partCondition: part.partCondition || null
})

/** The condition label for a part's integrity, a fraction of new. */
const conditionOf = (integrity) => {
  if (integrity >= 0.9) return "Excellent"
  if (integrity >= 0.75) return "Good"
  if (integrity >= 0.5) return "Fair"
  return "Poor"
}

/** One inventory row for a part of `model`. The keys are saved with the business, so their order is kept. */
const inventoryRowFor = (p, model) => {
  const c = p.partCondition || {}
  const integrity = typeof c.integrityValue === "number" ? c.integrityValue : 1
  const odo = typeof c.odometer === "number" ? c.odometer : 0
  const mileage = Math.max(0, Math.round(odo / METRES_PER_MILE))
  const price = p.finalValue || p.value || 0

  return {
    partId: p.partId,
    name: p.niceName || p.name,
    compatibleVehicle: p.vehicleNiceName || model,
    condition: conditionOf(integrity),
    mileage,
    odometer: Math.max(0, odo), // metres, for display in the player's unit
    slot: p.slot,
    price,
    value: price
  }
}

/** Every inventory row, model by model; a model whose entry is not a list contributes nothing. */
const inventoryRowsOf = (partsByModel) => {
  const rows = []
  Object.entries(partsByModel).forEach(([model, list]) => {
    if (!Array.isArray(list)) return
    list.forEach(p => {
      if (!p) return
      rows.push(inventoryRowFor(p, model))
    })
  })
  return rows
}

const labelOf = (node) => (node.partNiceName || node.partName || node.slotNiceName || '').toLowerCase()
const byLabel = (a, b) => labelOf(a).localeCompare(labelOf(b))

/** Sorts the children of `node` by label, deepest first. */
const sortTreeByLabel = (node) => {
  if (node.children && node.children.length > 0) {
    node.children.forEach(child => sortTreeByLabel(child))
    node.children.sort(byLabel)
  }
}

const parentPathOf = (path) => {
  const pathParts = path.split('/').filter(p => p)
  if (pathParts.length <= 1) return null
  return '/' + pathParts.slice(0, -1).join('/') + '/'
}

/** Each part with a non-blank slot path, keyed by its trimmed path, as a tree node with empty `children`. */
const treeNodesByPath = (parts) => {
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
  return partMap
}

/** Hangs each node under its parent. A node whose parent is missing becomes a root. Returns the roots. */
const linkTreeNodes = (partMap) => {
  const rootNodes = []

  partMap.forEach((part, path) => {
    const parentPath = parentPathOf(path)

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
  return rootNodes
}

/** The Lua requests for the parts tree and the inventory, and the handler for the inventory event. */
const createInventoryIntake = ({ businessId, businessData }) => {
  const requestVehiclePartsTree = async (vehicleId) => {
    if (!businessId.value || !vehicleId) return null

    try {
      await lua.overhaul_career_business_computer.requestVehiclePartsTree(businessId.value, vehicleId)
      return null
    } catch (error) {
      return null
    }
  }

  const requestPartInventory = async () => {
    if (!businessId.value) return null

    try {
      await lua.overhaul_career_business_computer.requestPartInventory(businessId.value)
      return null
    } catch (error) {
      return null
    }
  }

  const handlePartInventoryData = (data) => {
    const currentBusinessId = businessId.value
    if (!currentBusinessId) return

    if (!data || !data.success) return
    if (String(data.businessId) !== String(currentBusinessId)) return

    const mappedParts = inventoryRowsOf(data.partsByModel || {})

    businessData.value = {
      ...businessData.value,
      parts: mappedParts
    }
  }

  return { requestVehiclePartsTree, requestPartInventory, handlePartInventoryData }
}

export const useBusinessPartsStore = defineStore("overhaulBusinessParts", () => {
  const sessionStore = useBusinessSessionStore()
  const { businessData, pulledOutVehicle, businessId, isDamageLocked } = storeToRefs(sessionStore)
  const { showDamageLockWarning } = sessionStore
  const cartStore = useBusinessCartStore()
  const { partsCart, tuningCart, currentAppliedCartHash, cartTabs, activeTabId } = storeToRefs(cartStore)
  const { generateCartHash, saveCurrentTabState, setPartsCartRollback, restorePartsCartRollback } = cartStore

  // Lua requests and the inventory event.
  const { requestVehiclePartsTree, requestPartInventory, handlePartInventoryData } = createInventoryIntake({ businessId, businessData })

  // Cart writes: adding a part, and the Lua apply with its rollback.

  const addPartToCart = async (part, slot) => {
    if (!businessId.value || !pulledOutVehicle.value?.vehicleId) {
      return
    }
    if (isDamageLocked.value) {
      showDamageLockWarning()
      return
    }

    const partToAdd = cartRowFor(part, slot)
    const sourceCart = copyCart(partsCart.value)

    try {
      // Always use businessComputer for cart operations - tuningShop doesn't have these functions
      const tempCart = await lua.overhaul_career_business_computer.addPartToCart(
        businessId.value,
        pulledOutVehicle.value.vehicleId,
        sourceCart,
        partToAdd,
        true
      )

      if (tempCart && Array.isArray(tempCart)) {
        partsCart.value = mergePartsCartUpdate(partsCart.value, sourceCart, tempCart).map(item => ({
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

  /** Re-requests the parts tree after Lua has applied a cart, so the tree shows what the vehicle really has. */
  const refreshPartsTreeLater = () => {
    setTimeout(async () => {
      try {
        const vehicleId = pulledOutVehicle.value?.vehicleId
        if (vehicleId == null) return
        await requestVehiclePartsTree(vehicleId)
      } catch (error) {
      }
    }, TREE_REFRESH_DELAY_MS)
  }

  /** Applies the (already reduced) parts cart in Lua; a refusal or a bridge error puts `previousCart` back. */
  const applyPartsCartWithRollback = async (previousCart) => {
    const operationId = setPartsCartRollback(previousCart, partsCart.value, [], true)
    try {
      // Always use businessComputer for cart operations
      const applyResult = await lua.overhaul_career_business_computer.applyCartPartsToVehicle(
        businessId.value,
        pulledOutVehicle.value.vehicleId,
        partsCart.value, null, null, operationId
      )
      if (applyResult === false) {
        restorePartsCartRollback({ operationId })
      }
      refreshPartsTreeLater()
    } catch (error) {
      restorePartsCartRollback({ operationId })
    }
  }

  // Removal: a carted part, a part the vehicle came with, and the slot-path entry point.

  /** Drops `itemId` and everything installed in it from the cart, saves the tab, and returns the cart as it was before. */
  const dropCartSubtree = (itemId) => {
    const idsToRemove = idsWithDescendants(buildPartsTree(partsCart.value), itemId)
    const previousCart = copyCart(partsCart.value)
    partsCart.value = partsCart.value.filter(item => !idsToRemove.includes(item.id))
    saveCurrentTabState()
    return previousCart
  }

  const removePartFromCart = async (itemId) => {
    if (isDamageLocked.value) {
      showDamageLockWarning()
      return
    }
    const previousCart = dropCartSubtree(itemId)

    if (businessId.value && pulledOutVehicle.value?.vehicleId) {
      await applyPartsCartWithRollback(previousCart)
    }
  }

  /** Removes a part that is in the cart, together with everything installed in it. */
  const removeCartedPart = async (partToRemove) => {
    const previousCart = dropCartSubtree(partToRemove.id)
    currentAppliedCartHash.value = generateCartHash(partsCart.value, tuningCart.value)

    if (businessId.value && pulledOutVehicle.value?.vehicleId) {
      await applyPartsCartWithRollback(previousCart)
    }
  }

  /** Removes a part the vehicle came with: the cart gets "Removed ..." markers for it and for what hangs off it. */
  const markInstalledPartRemoved = async (normalizedPath) => {
    const owner = { businessId: businessId.value, vehicleId: pulledOutVehicle.value?.vehicleId,
      tabId: activeTabId.value, tabs: cartTabs.value }
    try {
      const initialVehicle = await lua.overhaul_career_business_partCustomization.getInitialVehicleState(owner.businessId)
      if (String(owner.businessId) !== String(businessId.value) ||
          String(owner.vehicleId) !== String(pulledOutVehicle.value?.vehicleId) ||
          owner.tabId !== activeTabId.value || owner.tabs !== cartTabs.value) return
      const initialPartName = initialVehicle?.partList?.[normalizedPath]
      if (!initialPartName) return

      const removalMarkers = removalMarkersFor(initialVehicle, normalizedPath, initialPartName)

      const previousCart = copyCart(partsCart.value)
      const writtenPaths = removalMarkers.map(marker => marker.slotPath)
      const nextCart = [...partsCart.value.filter(row => !writtenPaths.includes(row.slotPath)), ...removalMarkers]
      const operationId = setPartsCartRollback(previousCart, nextCart, writtenPaths, true)
      partsCart.value = nextCart
      saveCurrentTabState()
      currentAppliedCartHash.value = generateCartHash(partsCart.value, tuningCart.value)

      let applyResult
      try {
        applyResult = await lua.overhaul_career_business_computer.applyCartPartsToVehicle(
          businessId.value,
          pulledOutVehicle.value.vehicleId,
          partsCart.value, null, null, operationId
        )
      } catch (error) {
        console.error('[businessPartsStore] Failed to apply parts cart', error)
        applyResult = false
      }

      // Local refusal and bridge rejection share one rollback; later Lua failures use onPartCartApplyFailed.
      if (applyResult === false) {
        restorePartsCartRollback({ operationId })
        return
      }
      refreshPartsTreeLater()
    } catch (error) {
    }
  }

  const removePartBySlotPath = async (slotPath) => {
    if (isDamageLocked.value) {
      showDamageLockWarning()
      return
    }
    const normalizedPath = normalizeSlotPath(slotPath)

    const partToRemove = partsCart.value.find(item => (item.slotPath || '').trim() === normalizedPath)
    if (partToRemove) {
      await removeCartedPart(partToRemove)
    } else if (businessId.value && pulledOutVehicle.value?.vehicleId) {
      await markInstalledPartRemoved(normalizedPath)
    }
  }

  // Parts tree projection: the tree of the cart, which the computed keeps current.

  const buildPartsTree = (parts) => {
    if (!parts || parts.length === 0) return []

    const rootNodes = linkTreeNodes(treeNodesByPath(parts))
    rootNodes.forEach(node => sortTreeByLabel(node))

    return rootNodes.sort(byLabel)
  }

  const partsTree = computed(() => {
    return buildPartsTree(partsCart.value)
  })

  return {
    requestVehiclePartsTree,
    requestPartInventory,
    handlePartInventoryData,
    addPartToCart,
    removePartFromCart,
    removePartBySlotPath,
    buildPartsTree,
    partsTree
  }
})
