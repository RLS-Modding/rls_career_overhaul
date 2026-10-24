import { ref, watch } from "vue"
import { defineStore, storeToRefs } from "pinia"
import { lua } from "@/bridge"
import { useBusinessSessionStore } from "./businessSessionStore.js"

// Skill-gated flags: dyno and pit-fuel upgrades, and brand/race recognition with their selections. Each flag is
// re-read from the skill tree when the business changes or the tree reports an update.

// Dyno and pit-fuel upgrade flags, re-read when the business or its type changes.
const createSkillGatedFlags = ({ isMenuActive, businessId, businessType, typeData }) => {
  const hasDynoUpgrade = ref(false)

  /** Level of the skill node the type names under `key` in its skillNodes ({tree, node}); 0 when it names none. */
  const skillNodeLevel = async (key) => {
    const skillNode = typeData.value.skillNodes?.[key]
    if (!skillNode) return 0
    return (await lua.overhaul_career_business_skillTree.getNodeProgress(businessId.value, skillNode.tree, skillNode.node)) || 0
  }

  const updateDynoUpgradeStatus = async () => {
    if (!isMenuActive.value || !businessId.value) {
      hasDynoUpgrade.value = false
      return
    }

    if (!typeData.value.skillNodes?.dyno) {
      hasDynoUpgrade.value = false
      return
    }

    try {
      hasDynoUpgrade.value = (await skillNodeLevel('dyno')) > 0
    } catch (error) {
      hasDynoUpgrade.value = false
    }
  }

  const hasPitFuelSkill = ref(false)

  const updatePitFuelStatus = async () => {
    if (!isMenuActive.value || !businessId.value) {
      hasPitFuelSkill.value = false
      return
    }
    if (!typeData.value.skillNodes?.pitFuel) {
      hasPitFuelSkill.value = false
      return
    }
    try {
      hasPitFuelSkill.value = (await skillNodeLevel('pitFuel')) > 0
    } catch (error) {
      hasPitFuelSkill.value = false
    }
  }

  watch([businessId, businessType], () => {
    updateDynoUpgradeStatus()
    updatePitFuelStatus()
  }, { immediate: true })

  return { hasDynoUpgrade, hasPitFuelSkill, updateDynoUpgradeStatus, updatePitFuelStatus }
}

// Brand and race recognition: whether the quality-of-life nodes are bought, re-read on the same triggers.
const createRecognitionFlags = ({ isMenuActive, businessId }) => {
  const brandRecognitionUnlocked = ref(false)
  const raceRecognitionUnlocked = ref(false)

  const updateBrandRecognitionStatus = async () => {
    if (!isMenuActive.value || !businessId.value) {
      brandRecognitionUnlocked.value = false
      return
    }
    try {
      const level = await lua.overhaul_career_business_skillTree.getNodeProgress(
        businessId.value,
        "quality-of-life",
        "brand-recognition"
      )
      brandRecognitionUnlocked.value = (level || 0) > 0
    } catch (error) {
      brandRecognitionUnlocked.value = false
    }
  }

  const updateRaceRecognitionStatus = async () => {
    if (!isMenuActive.value || !businessId.value) {
      raceRecognitionUnlocked.value = false
      return
    }
    try {
      const level = await lua.overhaul_career_business_skillTree.getNodeProgress(
        businessId.value,
        "quality-of-life",
        "race-recognition"
      )
      raceRecognitionUnlocked.value = (level || 0) > 0
    } catch (error) {
      raceRecognitionUnlocked.value = false
    }
  }

  return { brandRecognitionUnlocked, raceRecognitionUnlocked, updateBrandRecognitionStatus, updateRaceRecognitionStatus }
}

// The brand and race selections, the lists they choose from, and the Lua calls that read and write them.
const createSelections = ({ businessId, getLuaModule }) => {
  const brandSelection = ref(null)
  const raceSelection = ref(null)
  const availableBrands = ref([])
  const availableRaceTypes = ref([])

  const getBrandSelection = async () => {
    if (!businessId.value) return null
    try {
      const selection = await getLuaModule().getBrandSelection(businessId.value)
      if (selection === "" || selection === null || selection === undefined) {
        brandSelection.value = null
      } else {
        brandSelection.value = selection
      }
      return selection
    } catch (error) {
      brandSelection.value = null
      return null
    }
  }

  const setBrandSelection = async (brand) => {
    if (!businessId.value) return false
    try {
      const value = brand === null || brand === undefined ? "" : brand
      const success = await getLuaModule().setBrandSelection(businessId.value, value)
      if (success) {
        brandSelection.value = brand || null
      }
      return success
    } catch (error) {
      return false
    }
  }

  const getRaceSelection = async () => {
    if (!businessId.value) return null
    try {
      const selection = await getLuaModule().getRaceSelection(businessId.value)
      if (selection === "" || selection === null || selection === undefined) {
        raceSelection.value = null
      } else {
        raceSelection.value = selection
        if (availableRaceTypes.value.length === 0) {
          getAvailableRaceTypes()
        }
      }
      return selection
    } catch (error) {
      raceSelection.value = null
      return null
    }
  }

  const setRaceSelection = async (raceType) => {
    if (!businessId.value) return false
    try {
      const value = raceType === null || raceType === undefined ? "" : raceType
      const success = await getLuaModule().setRaceSelection(businessId.value, value)
      if (success) {
        raceSelection.value = raceType || null
      }
      return success
    } catch (error) {
      return false
    }
  }

  const getAvailableBrands = () => {
    try {
      getLuaModule().requestAvailableBrands()
    } catch (error) {
    }
  }

  const getAvailableRaceTypes = () => {
    if (!businessId.value) return
    try {
      lua.overhaul_career_business_computer.requestAvailableRaceTypes(businessId.value)
    } catch (error) {
    }
  }

  const handleAvailableRaceTypesReceived = (data) => {
    if (data && Array.isArray(data.raceTypes)) {
      availableRaceTypes.value = data.raceTypes
    } else {
      availableRaceTypes.value = []
    }
  }

  return {
    brandSelection, raceSelection, availableBrands, availableRaceTypes, getBrandSelection, setBrandSelection,
    getRaceSelection, setRaceSelection, getAvailableBrands, getAvailableRaceTypes, handleAvailableRaceTypesReceived
  }
}

export const useBusinessSkillsStore = defineStore("overhaulBusinessSkills", () => {
  const sessionStore = useBusinessSessionStore()
  const { isMenuActive, businessId, businessType, typeData } = storeToRefs(sessionStore)
  const { getLuaModule } = sessionStore

  const { hasDynoUpgrade, hasPitFuelSkill, updateDynoUpgradeStatus, updatePitFuelStatus } = createSkillGatedFlags({
    isMenuActive, businessId, businessType, typeData
  })
  const {
    brandSelection, raceSelection, availableBrands, availableRaceTypes, getBrandSelection, setBrandSelection,
    getRaceSelection, setRaceSelection, getAvailableBrands, getAvailableRaceTypes, handleAvailableRaceTypesReceived
  } = createSelections({ businessId, getLuaModule })
  const { brandRecognitionUnlocked, raceRecognitionUnlocked, updateBrandRecognitionStatus, updateRaceRecognitionStatus } =
    createRecognitionFlags({ isMenuActive, businessId })

  // When the Lua skill-tree backend broadcasts a progress update (e.g. a node
  // purchase), re-query skill-gated UI flags so buttons like Refuel appear
  // without the user having to close/reopen the computer.
  const handleSkillTreesUpdated = () => {
    updateDynoUpgradeStatus()
    updatePitFuelStatus()
    updateBrandRecognitionStatus()
    updateRaceRecognitionStatus()
  }

  // A selection is read once its recognition unlocks, and again whenever the business changes while it is unlocked.
  watch(businessId, async () => {
    updateBrandRecognitionStatus()
    updateRaceRecognitionStatus()
    if (brandRecognitionUnlocked.value) {
      await getBrandSelection()
      await getAvailableBrands()
    }
    if (raceRecognitionUnlocked.value) {
      await getRaceSelection()
      await getAvailableRaceTypes()
    }
  }, { immediate: true })

  watch(raceRecognitionUnlocked, async (unlocked) => {
    if (unlocked && businessId.value) {
      await getRaceSelection()
      await getAvailableRaceTypes()
    }
  })

  watch(brandRecognitionUnlocked, async (unlocked) => {
    if (unlocked && businessId.value) {
      await getBrandSelection()
      await getAvailableBrands()
    }
  })

  return {
    handleSkillTreesUpdated,
    hasDynoUpgrade,
    updateDynoUpgradeStatus,
    hasPitFuelSkill,
    brandSelection,
    raceSelection,
    availableBrands,
    availableRaceTypes,
    brandRecognitionUnlocked,
    raceRecognitionUnlocked,
    updateBrandRecognitionStatus,
    updateRaceRecognitionStatus,
    getBrandSelection,
    setBrandSelection,
    getRaceSelection,
    setRaceSelection,
    getAvailableBrands,
    getAvailableRaceTypes,
    handleAvailableRaceTypesReceived
  }
})
