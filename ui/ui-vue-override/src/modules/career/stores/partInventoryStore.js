import { ref, watch } from "vue"
import { defineStore } from "pinia"
import { useBridge, lua } from "@/bridge"

export const usePartInventoryStore = defineStore("partInventory", () => {
  const { events } = useBridge()

  // States
  const partInventoryData = ref({
    partList: [],
    filteredPartList: [],
    vehicles: {},
    currentVehicle: null,
    brokenVehicleInventoryIds: {}
  })
  const newPartsPopupOpen = ref(false)
  const newParts = ref([])

  const searchString = ref("")

  // Actions
  function requestInitialData() {
    // TODO refactor this to use the return value method
    lua.career_modules_partInventory.sendUIData()
  }

  function closeNewPartsPopup() {
    newPartsPopupOpen.value = false
  }

  function closeMenu() {
    searchString.value = ""
    lua.career_modules_partInventory.closeMenu()
  }

  function partInventoryClosed() {
    lua.career_modules_partInventory.partInventoryClosed()
  }

  function dispose() {
    events.off("partInventoryData")
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
    if (!part) return false

    const searchTerm = searchString.value.toLowerCase()

    // Check description
    if (part.description && part.description.description) {
      if (part.description.description.toLowerCase().includes(searchTerm)) {
        return true
      }
    }

    // Check name
    if (part.name && part.name.toLowerCase().includes(searchTerm)) {
      return true
    }

    return false
  }

  const searchValueChanged = () => {
    const data = partInventoryData.value

    // Ensure partList exists and is an array
    if (!data || !data.partList || !Array.isArray(data.partList)) {
      partInventoryData.value.filteredPartList = []
      return
    }

    // Apply filter
    if (!searchString.value) {
      partInventoryData.value.filteredPartList = data.partList
    } else {
      partInventoryData.value.filteredPartList = data.partList.filter(doesPartPassFilter)
    }
  }

  // Function to determine if a part can be sold
  const canSellPart = (part) => {
    // Allow selling if part has value, regardless of missing data or accessibility
    if (!part) return false

    // Always allow selling parts with missing files (they have scrap value)
    if (part.missingFile) return true

    // Check if part has a value (either calculated or stored)
    const hasValue = (part.finalValue && part.finalValue > 0) || (part.value && part.value > 0)

    // Allow selling if it has value OR if it's in inventory (location 0)
    return hasValue || part.location === 0
  }

  watch(() => searchString.value, searchValueChanged)

  // Lua events
  events.on("partInventoryData", data => {
    // Ensure data has proper structure
    const safeData = {
      partList: data.partList || [],
      vehicles: data.vehicles || {},
      currentVehicle: data.currentVehicle,
      brokenVehicleInventoryIds: data.brokenVehicleInventoryIds || {},
      filteredPartList: data.partList || []
    }

    partInventoryData.value = safeData
    searchValueChanged()
  })

  return {
    canSellPart,
    closeMenu,
    closeNewPartsPopup,
    dispose,
    newParts,
    newPartsPopupOpen,
    openNewPartsPopup,
    partInventoryClosed,
    partInventoryData,
    requestInitialData,
    searchString
  }
})
