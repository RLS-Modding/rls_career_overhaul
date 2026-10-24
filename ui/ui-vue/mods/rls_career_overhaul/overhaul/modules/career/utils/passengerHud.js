// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// TaxiView mounts its own stock Tacho2 outside the driving app layout.
// Keep that route's fare/actions while hiding only its driver instruments.
const STYLE_ID = "overhaul-passenger-taxi-hud"
export const passengerTaxiStyle = ".taxi-hud > .taxi-tacho { display: none !important; }"

export function startPassengerHud(bridge, document = window.document) {
  let generation = 0
  let disposed = false
  let style = null
  function setPassenger(passenger) {
    if (disposed) return
    if (passenger === true) {
      if (style) return
      style = document.createElement("style")
      style.id = STYLE_ID
      style.textContent = passengerTaxiStyle
      document.head.appendChild(style)
    } else if (style) {
      style.remove()
      style = null
    }
  }
  function refresh() {
    const request = ++generation
    bridge.api.engineLua("overhaul_shell_gameMode and overhaul_shell_gameMode.isActive() and gameplay_seatOccupants and gameplay_seatOccupants.getPlayerPresence(0)", presence => {
      if (request === generation) setPassenger(presence?.permissionMode === "passenger")
    })
  }
  function onPassenger(value) {
    ++generation
    setPassenger(value)
  }
  function onFocus(data) {
    if (data?.mode === true) refresh()
  }
  bridge.events.on("OverhaulPassengerMode", onPassenger)
  bridge.events.on("VehicleChange", refresh)
  bridge.events.on("VehicleFocusChanged", onFocus)
  refresh()
  return () => {
    if (disposed) return
    ++generation
    setPassenger(false)
    disposed = true
    bridge.events.off("OverhaulPassengerMode", onPassenger)
    bridge.events.off("VehicleChange", refresh)
    bridge.events.off("VehicleFocusChanged", onFocus)
  }
}
