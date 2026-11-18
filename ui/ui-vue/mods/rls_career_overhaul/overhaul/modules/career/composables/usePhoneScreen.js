// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// Screens register reactive presentation overrides with their containing shell.
// Registration identity prevents an outgoing screen from clearing its successor.
import { inject, onUnmounted, provide } from 'vue'
import { usePhoneOverlayStack } from './usePhoneOverlayStack.js'

// The phone shell provides its screen host under this key.
export const PHONE_SCREEN = Symbol.for('overhaul.phoneScreen')

// True for any component the phone shell renders. Shared components use it to mark
// their teleported layers as phone surfaces (data-phone-surface, phoneForcedColors.scss).
export function isInsidePhone() {
  return inject(PHONE_SCREEN, null) !== null
}

export function usePhoneScreen(options = {}) {
  const host = inject(PHONE_SCREEN, null)
  const overlays = usePhoneOverlayStack()
  provide(Symbol.for('overhaul.phoneLayers'), overlays)
  const dispose = host?.register({ ...options, onBack: () => overlays.back() || options.onBack?.() })
  if (dispose) onUnmounted(dispose)
  return host ? { ...host, overlays } : { overlays }
}
