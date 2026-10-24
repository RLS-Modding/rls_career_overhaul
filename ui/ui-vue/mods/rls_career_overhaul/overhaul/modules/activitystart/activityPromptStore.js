// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

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
