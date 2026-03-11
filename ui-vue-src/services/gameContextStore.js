import { defineStore } from "pinia"
import { ref } from "vue"
import { lua, useBridge } from "@/bridge"
import { openScreenOverlay, addPopup, fixedDelayPopup, PopupTypes } from "@/services/popup"

import ActivityStart from "@/modules/activitystart/views/ActivityStart.vue"
import Recovery from "@/modules/recovery/views/Recovery.vue"
import RadialFavoriteSelection from "@/modules/radial/views/FavoriteSelection.vue"
import UnlockPopup from "@/modules/career/components/cargoOverview/UnlockPopup.vue"

export const useGameContextStore = defineStore("gameContext", () => {
  const { events } = useBridge()
  const LEVEL_UP_SOUND_EVENT_ENTRY = "event:>UI>Career>EndScreen_Whoosh_Main"
  const LEVEL_UP_SOUND_EVENT_IMPACT = "event:>UI>Career>EndScreen_Star_Bonus"
  const LEVEL_UP_SOUND_IMPACT_DELAY_MS = 120

  const activities = ref([])
  let activityScreen = null
  let recoveryPrompt = null
  let radialFavoriteSelectionPrompt = null
  let deliveryEndScreen = null
  let simpleDelayPopup = null
  const levelUpQueue = []
  let processingLevelUpQueue = false

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
    levelUpQueue.length = 0
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
