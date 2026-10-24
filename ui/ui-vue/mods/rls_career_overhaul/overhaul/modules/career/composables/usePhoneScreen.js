// Screens register reactive presentation overrides with their containing shell.
// Registration identity prevents an outgoing screen from clearing its successor.
import { inject, onUnmounted, provide } from 'vue'
import { usePhoneOverlayStack } from './usePhoneOverlayStack.js'

export function usePhoneScreen(options = {}) {
  const host = inject(Symbol.for('overhaul.phoneScreen'), null)
  const overlays = usePhoneOverlayStack()
  provide(Symbol.for('overhaul.phoneLayers'), overlays)
  const dispose = host?.register({ ...options, onBack: () => overlays.back() || options.onBack?.() })
  if (dispose) onUnmounted(dispose)
  return host ? { ...host, overlays } : { overlays }
}
