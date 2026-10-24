// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

import { onBeforeUnmount, watch } from "vue"
import { openOverhaulPopup } from "../../utils/openOverhaulPopup.js"

// Keep the bank's public show/event API while stock popups own maps and focus.
export function useBankPopup(view, props, emit, successEvent) {
  let current = null
  const stop = watch(() => props.show, show => {
    if (!show) {
      const closing = current
      current = null
      closing?.return(false)
      return
    }
    if (current) return
    const host = document.activeElement?.closest?.('.phone-bank-root, .phone-bank-account-root')
    const rect = host?.getBoundingClientRect()
    const appearance = host ? getComputedStyle(host) : null
    const popup = openOverhaulPopup(view, { ...props }, {
      localBackdrop: true,
      ...(rect ? {
        style: {
          fontFamily: appearance.fontFamily, fontSize: appearance.fontSize, lineHeight: appearance.lineHeight,
          position: 'fixed', left: `${rect.left}px`, top: `${rect.top}px`,
          width: `${rect.width}px`, height: `${rect.height}px`,
        },
      } : {}),
    })
    current = popup
    popup.promise.then(result => {
      if (current !== popup) return
      current = null
      if (result === true) emit(successEvent)
      emit("close")
    })
  }, { immediate: true })
  onBeforeUnmount(() => {
    stop()
    const closing = current
    current = null
    closing?.return(false)
  })
}
