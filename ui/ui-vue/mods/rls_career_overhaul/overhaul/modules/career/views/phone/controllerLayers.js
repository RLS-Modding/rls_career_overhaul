// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

import { watch, onUpdated } from "vue"
import { ensureFocus } from "@/services/uiNavFocus"
import { usePhoneScreen } from "../../composables/usePhoneScreen.js"
import { bcModalScope } from "../../components/businessComputer/bcModalNav.js"

// Keep local overlays in the phone Back stack even while a Lua close is pending.
export function usePhoneAppLayers(layers, options = {}) {
  const { overlays } = usePhoneScreen(options)
  const scopes = {}
  for (const [name, layer] of Object.entries(layers)) {
    scopes[name] = {
      ...bcModalScope(`phone-${name}`), type: "container", open: true,
      preventNavigationEscape: ["up", "down", "left", "right"],
      bubbleWhitelistEvents: ["menu"],
    }
    watch(() => !!layer.open(), (open, previous, cleanup) => {
      if (open) cleanup(overlays.push(layer.close))
    }, { immediate: true, flush: "sync" })
  }
  return { scopes, back: event => { event?.stopPropagation(); overlays.back() } }
}

// Vue class patches can remove stock's imperative focus-visible class.
// Repair only the live controller target; ensureFocus never moves mouse focus.
export function usePhoneAppFocus() {
  onUpdated(() => ensureFocus(document.activeElement))
}
