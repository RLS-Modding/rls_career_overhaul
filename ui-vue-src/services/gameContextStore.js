import { defineStore } from "pinia"
import { ref } from "vue"
import { lua, useBridge } from "@/bridge"
import { openScreenOverlay, addPopup, fixedDelayPopup } from "@/services/popup"

import ActivityStart from "@/modules/activitystart/views/ActivityStart.vue"
import Recovery from "@/modules/recovery/views/Recovery.vue"
import RadialFavoriteSelection from "@/modules/radial/views/FavoriteSelection.vue"

export const useGameContextStore = defineStore("gameContext", () => {
  const { events } = useBridge()
  const activities = ref([])
  let activityScreen = null
  let recoveryPrompt = null
  let radialFavoriteSelectionPrompt = null
  let deliveryEndScreen = null
  let simpleDelayPopup = null

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
