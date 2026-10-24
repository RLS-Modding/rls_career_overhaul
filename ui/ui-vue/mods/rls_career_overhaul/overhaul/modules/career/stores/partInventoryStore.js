// This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
// If a copy of the bCDDL was not distributed with this
// file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

import { onScopeDispose, ref, watch } from "vue"
import { defineStore } from "pinia"
import { useBridge, lua } from "@/bridge"

export const usePartInventoryStore = defineStore("overhaulPartInventory", () => {
  const { events } = useBridge()

  // States
  const partInventoryData = ref({})
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

  const doesPartPassFilter = (part) => {
    return part.description.description.toLowerCase().includes(searchString.value.toLowerCase()) ||
      part.name.toLowerCase().includes(searchString.value.toLowerCase())
  }

  const searchValueChanged = () => {
    if (partInventoryData.value.partList.filter) {
      partInventoryData.value.filteredPartList = partInventoryData.value.partList.filter(doesPartPassFilter);
    } else {
      partInventoryData.value.filteredPartList = {}
    }
  }

  watch(() => searchString.value, searchValueChanged)

  // Lua events
  function handlePartInventoryData(data) {
    partInventoryData.value = data
    searchValueChanged()
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
