import { defineStore } from "pinia"
import { ref } from "vue"
import { lua, useBridge } from "@/bridge"
import { openScreenOverlay, addPopup, fixedDelayPopup, PopupTypes } from "@/services/popup"

import ActivityStart from "@/modules/activitystart/views/ActivityStart.vue"
import Recovery from "@/modules/recovery/views/Recovery.vue"
import RadialFavoriteSelection from "@/modules/radial/views/FavoriteSelection.vue"
import UnlockPopup from "@/modules/career/components/cargoOverview/UnlockPopup.vue"
import FreContractCompletePopup from "@/modules/career/components/cargoOverview/FreContractCompletePopup.vue"

export const useGameContextStore = defineStore("gameContext", () => {
  const { events } = useBridge()
  const LEVEL_UP_SOUND_EVENT_ENTRY = "event:>UI>Career>EndScreen_Whoosh_Main"
  const LEVEL_UP_SOUND_EVENT_IMPACT = "event:>UI>Career>EndScreen_Star_Bonus"
  const LEVEL_UP_SOUND_IMPACT_DELAY_MS = 120
  const CONTRACT_COMPLETE_SOUND_EVENT_ENTRY = "event:>UI>Career>Computer"
  const CONTRACT_COMPLETE_SOUND_EVENT_IMPACT = "event:>UI>Career>Buy_01"
  const CONTRACT_COMPLETE_SOUND_IMPACT_DELAY_MS = 90

  const activities = ref([])
  let activityScreen = null
  let recoveryPrompt = null
  let radialFavoriteSelectionPrompt = null
  let deliveryEndScreen = null
  let simpleDelayPopup = null
  const levelUpQueue = []
  let processingLevelUpQueue = false
  const contractCompleteQueue = []
  let processingContractCompleteQueue = false

  const startMission = missionId => {
    const mission = activities.value.find(x => x.id === missionId)

    if (!mission) console.error(`Mission not found ${missionId}. cannot start`)

    const settings = mission.settings,
      userSettings = mission && settings ? settings.reduce((acc, item) => {
        acc[item.key] = item.value
        return acc
      }, {}) : {}
    lua.gameplay_markerInteraction.startMissionById(mission.id, userSettings)
  }

  const closeActivitiesPrompt = () => {
    lua.gameplay_markerInteraction.closeViewDetailPrompt(true)
  }

  function openRecoveryPrompt() {
    recoveryPrompt = addPopup(Recovery).promise
  }

  function openDynamicSlotConfigurator() {
    radialFavoriteSelectionPrompt = addPopup(RadialFavoriteSelection).promise
  }

  function openSimpleDelayPopup(data) {
    simpleDelayPopup = fixedDelayPopup(data.timer, { title: data.heading })
  }

  const performActivityAction = activityActionIndex => lua.ui_missionInfo.performActivityAction(activityActionIndex)

  events.on("ActivityAcceptUpdate", onActivityAcceptUpdate)
  events.on("ActivityAcceptClose", closeActivitiesPopup)

  events.on("MenuOpenModule", closeActivitiesPopup)

  events.on("ChangeState", closeActivitiesPopup)

  events.on("OpenRecoveryPrompt", openRecoveryPrompt)

  events.on("OpenDynamicSlotConfigurator", openDynamicSlotConfigurator)

  events.on("OpenSimpleDelayPopup", openSimpleDelayPopup)

  const deliveryRewardData = ref(false)
  function showDeliveryEndScreen(data) {
    deliveryRewardData.value = data
    window.bngVue.gotoGameState("cargoDeliveryReward")
  }
  events.on("OpenDeliveryEndScreen", showDeliveryEndScreen)

  const normalizeLevelUpEntry = entry => {
    if (!entry || typeof entry !== "object") return null
    const animationData = entry.animationData && typeof entry.animationData === "object" ? entry.animationData : {}
    const level = Number.isFinite(Number(animationData.level)) ? Number(animationData.level) : undefined
    return {
      ...entry,
      animationData: {
        ...animationData,
        level,
        levelLabel: animationData.levelLabel || (level ? `Level ${level}` : "Level Up"),
      },
    }
  }

  const playLevelUpSoundCombo = () => {
    try {
      lua.Engine.Audio.playOnce("AudioGui", LEVEL_UP_SOUND_EVENT_ENTRY)
      setTimeout(() => {
        try {
          lua.Engine.Audio.playOnce("AudioGui", LEVEL_UP_SOUND_EVENT_IMPACT)
        } catch (_err) {
          // Ignore delayed impact audio failures.
        }
      }, LEVEL_UP_SOUND_IMPACT_DELAY_MS)
    } catch (_err) {
      // Ignore audio failures to keep popup flow alive.
    }
  }

  const processLevelUpQueue = async () => {
    if (processingLevelUpQueue || levelUpQueue.length <= 0) return
    processingLevelUpQueue = true
    try {
      while (levelUpQueue.length > 0) {
        const reward = levelUpQueue.shift()
        if (!reward) continue
        try {
          playLevelUpSoundCombo()
          await addPopup(UnlockPopup, { reward }, PopupTypes.activity).promise
        } catch (_err) {
          // Popup cancellation should not stop queued celebrations.
        }
      }
    } finally {
      processingLevelUpQueue = false
      if (levelUpQueue.length > 0) {
        void processLevelUpQueue()
      }
    }
  }

  const queueLevelUpCelebrations = data => {
    const entries = Array.isArray(data && data.entries) ? data.entries : []
    if (!entries.length) return
    for (const entry of entries) {
      const normalized = normalizeLevelUpEntry(entry)
      if (normalized) {
        levelUpQueue.push(normalized)
      }
    }
    void processLevelUpQueue()
  }
  events.on("OpenCareerLevelUpCelebration", queueLevelUpCelebrations)

  const normalizeContractCompleteEntry = entry => {
    if (!entry || typeof entry !== "object") return null
    const requiredCount = Math.max(1, Math.floor(Number(entry.requiredCount || 1)))
    return {
      ...entry,
      tier: entry.tier || "easy",
      objectiveType: entry.objectiveType === "laps" ? "laps" : "events",
      requiredCount,
      rewardMoney: Math.floor(Number(entry.rewardMoney || 0)),
      rewardXp: Math.floor(Number(entry.rewardXp || 0)),
      disciplineLabel: entry.disciplineLabel || "FRE",
      raceLabel: entry.raceLabel || "Race",
      requiredModelLabel: entry.requiredModelLabel || entry.requiredModel || "Any model",
    }
  }

  const playContractCompleteSoundCombo = () => {
    try {
      lua.Engine.Audio.playOnce("AudioGui", CONTRACT_COMPLETE_SOUND_EVENT_ENTRY)
      setTimeout(() => {
        try {
          lua.Engine.Audio.playOnce("AudioGui", CONTRACT_COMPLETE_SOUND_EVENT_IMPACT)
        } catch (_err) {
          // Ignore delayed impact audio failures.
        }
      }, CONTRACT_COMPLETE_SOUND_IMPACT_DELAY_MS)
    } catch (_err) {
      // Ignore audio failures to keep popup flow alive.
    }
  }

  const processContractCompleteQueue = async () => {
    if (processingContractCompleteQueue || contractCompleteQueue.length <= 0) return
    processingContractCompleteQueue = true
    try {
      while (contractCompleteQueue.length > 0) {
        const entry = contractCompleteQueue.shift()
        if (!entry) continue
        try {
          playContractCompleteSoundCombo()
          await addPopup(FreContractCompletePopup, { entry }, PopupTypes.activity).promise
        } catch (_err) {
          // Popup cancellation should not stop queued celebrations.
        }
      }
    } finally {
      processingContractCompleteQueue = false
      if (contractCompleteQueue.length > 0) {
        void processContractCompleteQueue()
      }
    }
  }

  const queueContractCompletionCelebrations = data => {
    const entries = []
    if (Array.isArray(data && data.entries)) {
      entries.push(...data.entries)
    } else if (data && data.entry) {
      entries.push(data.entry)
    }
    if (!entries.length) return
    for (const entry of entries) {
      const normalized = normalizeContractCompleteEntry(entry)
      if (normalized) {
        contractCompleteQueue.push(normalized)
      }
    }
    void processContractCompleteQueue()
  }
  events.on("OpenFreContractCelebration", queueContractCompletionCelebrations)

  function onActivityAcceptUpdate(data) {
    if (activityScreen && (activities.value || !data)) closeActivitiesPopup()

    if (window.location.hash !== "#/play") return

    activities.value = data

    if (activities.value && activities.value.length > 0) {
      activityScreen = openScreenOverlay(ActivityStart)
    }
  }

  function closeActivitiesPopup() {
    if (!activityScreen) return

    activityScreen.close(true)
    activityScreen = null
  }

  function closeRecoveryPrompt() {
    if (!recoveryPrompt) return

    recoveryPrompt.close(true)
    recoveryPrompt = null
  }

  function closeRadialFavoriteSelectionPrompt() {
    if (!radialFavoriteSelectionPrompt) return

    radialFavoriteSelectionPrompt.close(true)
    radialFavoriteSelectionPrompt = null
  }

  function closeSimpleDelayPopup() {
    if (!simpleDelayPopup) return
    simpleDelayPopup.progress.done()
    simpleDelayPopup = null
  }

  function closeDeliveryEndScreen() {
    if (!deliveryEndScreen) return

    deliveryEndScreen.close(true)
    deliveryEndScreen = null
  }

  function dispose() {
    events.off("ActivityAcceptUpdate", onActivityAcceptUpdate)
    events.off("ActivityAcceptClose", closeActivitiesPopup)
    events.off("OpenCareerLevelUpCelebration", queueLevelUpCelebrations)
    events.off("OpenFreContractCelebration", queueContractCompletionCelebrations)
    levelUpQueue.length = 0
    contractCompleteQueue.length = 0
  }

  return {
    activities,
    closeActivitiesPrompt,
    closeDeliveryEndScreen,
    closeRecoveryPrompt,
    closeRadialFavoriteSelectionPrompt,
    closeSimpleDelayPopup,
    deliveryRewardData,
    dispose,
    performActivityAction,
    startMission,
  }
})
