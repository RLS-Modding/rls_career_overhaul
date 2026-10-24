import { lua } from '@/bridge'
import { openConfirmation } from '@/services/popup'

export async function confirmEndBusShiftNow(routeId) {
  if (!routeId) return false
  const confirmed = await openConfirmation(
    'End Day Now?',
    'Remaining passengers will be transferred. You will receive pay for completed stops, with normal company deductions. An unfinished stop or loop earns no completion bonus.'
  )
  if (!confirmed) return null
  // The backend checks this captured route identity again after confirmation.
  return lua.overhaul_career_work_employment.endBusShiftNow(routeId)
}
