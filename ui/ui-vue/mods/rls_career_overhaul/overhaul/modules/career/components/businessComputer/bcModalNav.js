// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// Controller navigation for the business computer's hand-built modals (overlays teleported to <body>).
// Same contract as the house popups (HouseConfirm): the modal is its own scope while it is mounted, the
// d-pad stays inside it, B/Start close it (the template binds v-bng-on-ui-nav:back,menu to the close
// handler) and the scope coordinator hands focus back to the button that opened it when it unmounts.
// Use with v-if (mounted = open). Call once per modal in <script setup> so the scope id stays stable.
//
//   const abandonModalScope = bcModalScope("abandon")
//   <div class="modal" v-bng-scoped-nav="abandonModalScope" v-bng-on-ui-nav:back,menu="cancelAbandon">
//     <HouseButton bng-scoped-nav-autofocus @click="cancelAbandon">Cancel</HouseButton>

import { returnFocusToOpener } from "../../composables/useScreenEntryFocus.js"

let seq = 0

export function bcModalScope(name) {
  seq += 1
  return Object.freeze({
    scopeId: `bc-modal-${name}-${seq}`,
    activated: true,
    activateOnMount: true,
    canDeactivate: () => false,
    preferAutoFocus: true,
    trapPolicy: "always",
  })
}

// Safety net next to the scope: the scope coordinator focuses the autofocus button once the modal's enter
// transition settles, but if that request is dropped the d-pad would still act on the page behind the
// modal (and B would leave the computer). After a short delay, if focus is not inside the modal, focus its
// autofocus button, else its first live button. Never a text field (that would switch on CEF typing).
//   <div class="modal" v-bng-scoped-nav="abandonModalScope" v-bc-modal-focus ...>
const FOCUS_FALLBACK_MS = 250
const FALLBACK_TARGETS = [
  "[bng-scoped-nav-autofocus]:not(:disabled)",
  'button:not(:disabled):not([bng-no-nav="true"])',
  '[bng-nav-item]:not(input):not(textarea):not([bng-no-nav="true"])',
]

export const vBcModalFocus = {
  beforeMount(el) {
    el.__bcModalOpener = document.activeElement
  },
  mounted(el) {
    el.__bcModalFocusTimer = setTimeout(() => {
      if (!document.contains(el) || el.contains(document.activeElement)) return
      for (const selector of FALLBACK_TARGETS) {
        const target = el.querySelector(selector)
        if (target) {
          target.focus()
          return
        }
      }
    }, FOCUS_FALLBACK_MS)
  },
  beforeUnmount(el) {
    clearTimeout(el.__bcModalFocusTimer)
  },
  unmounted(el) {
    // Vue starts the leave transition before removing the teleported scope.
    // Let its coordinator resume finish before requesting the opener again.
    setTimeout(() => returnFocusToOpener(() => el.__bcModalOpener), FOCUS_FALLBACK_MS)
  },
}
