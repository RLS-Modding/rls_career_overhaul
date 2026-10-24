// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// Stock popup state owns menu action maps, including on the driving route.
import { addPopup } from "@/services/popup"
import { markRaw } from "vue"
import OverhaulPopup from "../components/house/OverhaulPopup.vue"

let popupSequence = 0

export function openOverhaulPopup(component, props = {}, { beforeCancel, fullscreen = false, preserveLayout = false, localBackdrop = false, style, ...wrapperOptions } = {}) {
  // Stock state reporting keys popups by component name, not instance ID.
  // Distinct names keep a nested close from removing its parent's Menu map.
  // Fullscreen owners already animate their content. Stock's centred popup zoom
  // would create a zero-width containing block for their fixed overlays.
  const wrapper = markRaw({
    ...OverhaulPopup,
    __name: `OverhaulPopup${++popupSequence}`,
    wrapper: wrapperOptions,
    ...(fullscreen && { position: "fullscreen", animated: false }),
  })
  return addPopup(wrapper, {
    view: markRaw(component), viewProps: props, opener: document.activeElement, beforeCancel, preserveLayout,
    ...(localBackdrop ? { class: "overhaul-popup-local-backdrop" } : {}),
    ...(style ? { style } : {}),
  })
}
