import { defineStore } from "pinia"
import { ref } from "vue"
import { useBridge } from "@/bridge"

const DISMISS = "if overhaul_integration_services_markerInteraction and overhaul_integration_services_markerInteraction.dismissViewDetailPrompt then overhaul_integration_services_markerInteraction.dismissViewDetailPrompt() elseif gameplay_markerInteraction and gameplay_markerInteraction.closeViewDetailPrompt then gameplay_markerInteraction.closeViewDetailPrompt(true) end"

export const useOverhaulActivityPromptStore = defineStore("overhaulActivityPrompt", () => {
  const { api } = useBridge()
  const activities = ref([])

  function dismiss() {
    api.engineLua(DISMISS)
  }

  return { activities, dismiss }
})
