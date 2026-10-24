// Opens the house vehicle picker when overhaul_career_garage_zoneVehicles asks for one.
// Lua owns the list and re-pushes it while the picker is open; this file only shows the latest view,
// sends the choice back and closes when Lua says so. A late reply for an old ticket is ignored.
import { onBeforeUnmount, reactive } from "vue"
import { useBridge } from "@/bridge"
import { callModLua } from "../utils/installLuaBridgeFallbacks.js"
import { reportUiFailure, safeLua } from "../utils/safeLua.js"

const LUA = "overhaul_career_garage_zoneVehicles"

export function useZoneVehiclePicker() {
  const { events } = useBridge()
  const state = reactive({ view: null, pendingId: null })
  let popup = null
  let opening = false

  const ticketOf = () => state.view?.ticket
  const cancelInLua = ticket => safeLua(() => callModLua(`${LUA}.cancel`, ticket), "Cancel zone vehicle picker")

  const choose = async inventoryId => {
    const ticket = ticketOf()
    if (ticket == null || state.pendingId) return
    state.pendingId = inventoryId
    try {
      await callModLua(`${LUA}.pick`, ticket, Number(inventoryId))
    } catch (error) {
      reportUiFailure(error, "Choose zone vehicle")
    } finally {
      // success closes through the hide event; a refusal re-pushes the view with a notice
      if (ticketOf() === ticket) state.pendingId = null
    }
  }

  // One popup shows whichever view is current, so a newer ticket during compilation reuses it.
  const open = async () => {
    if (popup || opening) return
    opening = true
    let ownPopup
    try {
      const [{ openOverhaulPopup }, { default: component }] = await Promise.all([
        import("../utils/openOverhaulPopup.js"), import("../components/house/HouseVehiclePicker.vue"),
      ])
      if (!state.view) return
      // Back follows the Cancel button: ignored while a choice is waiting for Lua
      ownPopup = popup = openOverhaulPopup(component, { state, onChoose: choose }, { beforeCancel: () => state.pendingId == null })
    } catch (error) {
      reportUiFailure(error, "Open zone vehicle picker")
      // without a popup the Lua session would keep re-pushing a picker nobody can answer
      const ticket = ticketOf()
      state.view = null
      if (ticket != null) cancelInLua(ticket)
      return
    } finally {
      opening = false
    }
    const result = await ownPopup.promise
    if (popup === ownPopup) popup = null
    // Back or Cancel; a hide from Lua resolves true and has already cleared the view
    const ticket = ticketOf()
    if (result === false && ticket != null) {
      state.view = null
      state.pendingId = null
      cancelInLua(ticket)
    }
  }

  const show = view => {
    if (!view || view.ticket == null) return
    if (state.view?.ticket !== view.ticket) state.pendingId = null
    state.view = view
    open()
  }

  const hide = data => {
    if (data?.ticket != null && data.ticket !== ticketOf()) return
    state.view = null
    state.pendingId = null
    const old = popup
    popup = null
    old?.return(true)
  }

  events.on("OverhaulZoneVehiclePickerShow", show)
  events.on("OverhaulZoneVehiclePickerHide", hide)
  onBeforeUnmount(() => {
    events.off("OverhaulZoneVehiclePickerShow", show)
    events.off("OverhaulZoneVehiclePickerHide", hide)
    const ticket = ticketOf()
    hide()
    if (ticket != null) cancelInLua(ticket)
  })
  return { state }
}
