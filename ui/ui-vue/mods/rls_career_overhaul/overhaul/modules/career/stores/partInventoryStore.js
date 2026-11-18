// This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
// If a copy of the bCDDL was not distributed with this
// file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
// RLS modifications: Copyright (C) RLS Modding

import { onScopeDispose, ref, shallowRef, watch } from "vue"
import { defineStore } from "pinia"
import { useBridge, lua } from "@/bridge"
import { createPartsInventoryReceiver } from "./partsInventoryTransport.js"

export const usePartInventoryStore = defineStore("overhaulPartInventory", () => {
  const { events } = useBridge()
  const receiver = createPartsInventoryReceiver()

  // States
  // Publications replace the complete view; per-part proxies add no reactivity we use.
  const partInventoryData = shallowRef({})
  const newPartsPopupOpen = ref(false)
  const newParts = ref([])

  const searchString = ref("")

  // Actions
  function closeNewPartsPopup() {
    newPartsPopupOpen.value = false
  }

  function closeMenu() {
    searchString.value = ""
    lua.overhaul_career_parts_partInventory.closeMenu()
  }

  function partInventoryClosed() {
    lua.overhaul_career_parts_partInventory.partInventoryClosed()
  }

  function dispose() {
    events.off("partInventoryData", handlePartInventoryData)
    receiver.reset()
    partInventoryData.value = {}
    newParts.value = []
    newPartsPopupOpen.value = false
  }

  function openNewPartsPopup(newPartIds) {
    newPartsPopupOpen.value = true

    newParts.value = []
    for (let i = 0; i < partInventoryData.value.partList.length; i++) {
      let part = partInventoryData.value.partList[i]
      for (let j = 0; j < newPartIds.length; j++) {
        if (part.id == newPartIds[j]) {
          newParts.value.push(part)
          break
        }
      }
    }
  }

  function withFilteredParts(data) {
    const parts = Array.isArray(data.partList) ? data.partList : []
    const query = searchString.value.toLowerCase()
    const filteredPartList = query ? parts.filter(part =>
      part.description.description.toLowerCase().includes(query) || part.name.toLowerCase().includes(query)) : parts
    return { ...data, filteredPartList }
  }

  watch(searchString, () => { partInventoryData.value = withFilteredParts(partInventoryData.value) })

  // Lua events
  function handlePartInventoryData(data) {
    const inventory = receiver.accept(data)
    if (!inventory) return
    partInventoryData.value = withFilteredParts(inventory)
  }
  events.on("partInventoryData", handlePartInventoryData)
  onScopeDispose(dispose)

  return {
    closeMenu,
    closeNewPartsPopup,
    dispose,
    newParts,
    newPartsPopupOpen,
    openNewPartsPopup,
    partInventoryClosed,
    partInventoryData,
    searchString
  }
})
