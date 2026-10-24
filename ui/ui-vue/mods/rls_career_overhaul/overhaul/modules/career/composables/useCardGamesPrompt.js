// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// One prompt owner. Hide/unmount during compilation invalidates the pending open.
import { onBeforeUnmount } from "vue"
import { useBridge } from "@/bridge"
import { callModLua } from "../utils/installLuaBridgeFallbacks.js"
import { reportUiFailure, safeLua } from "../utils/safeLua.js"

export function useCardGamesPrompt() {
  const { events } = useBridge()
  let ticket = 0
  let popup = null
  let opening = false
  const clearLock = () => safeLua(() => callModLua("overhaul_jobs_cardGames_cardGames.clearGamblingPromptPlayerLock"), "Release card prompt")
  const hide = () => {
    ticket++
    opening = false
    const old = popup
    popup = null
    old?.return(false)
  }
  const show = async () => {
    if (popup || opening) return
    const ownTicket = ++ticket
    opening = true
    try {
      const [{ openOverhaulPopup }, { default: component }] = await Promise.all([
        import("../utils/openOverhaulPopup.js"), import("../components/house/CardGamesPrompt.vue"),
      ])
      if (ownTicket !== ticket) return
      popup = openOverhaulPopup(component)
      const accepted = await popup.promise
      if (ownTicket !== ticket) return
      popup = null
      if (accepted) {
        await callModLua("overhaul_jobs_cardGames_cardGames.startGambleCameraAnim")
        window.bngVue.gotoGameState("card-games")
      } else clearLock()
    } catch (error) {
      if (ownTicket === ticket) {
        popup?.return(false)
        popup = null
        clearLock()
        reportUiFailure(error, "Open card prompt")
      }
    } finally {
      if (ownTicket === ticket) opening = false
    }
  }
  events.on("CardGamesGamblingPromptShow", show)
  events.on("CardGamesGamblingPromptHide", hide)
  onBeforeUnmount(() => {
    events.off("CardGamesGamblingPromptShow", show)
    events.off("CardGamesGamblingPromptHide", hide)
    const hadPrompt = popup || opening
    hide()
    if (hadPrompt) clearLock()
  })
}
