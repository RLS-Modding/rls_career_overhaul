// The open save's detail: money history, asset value and the last vehicle. These come from files the strip must not
// read once per card, so they are fetched for the open card alone, and only after it has stayed open for a moment.
import { computed, ref, watch } from "vue"
import { safeLua } from "../../../utils/safeLua.js"

/** The open card's detail waits this long, so passing over cards does not queue a read for each. */
const HIGHLIGHT_DELAY_MS = 120

/**
 * Deliberately late.
 *
 * The Lua behind this reads the attribute log and every vehicle record for the
 * profile, which blocks while it does. Firing it on each card as you pass is
 * what made stepping feel heavy, so it waits for the selection to settle first.
 * The card is drawn immediately either way — these numbers fill in after.
 *
 * Keyed on the expanded card, not the selected one. Scrolling past twenty cards
 * must not queue twenty reads, each over the attribute log and every vehicle
 * record of a card that was never opened.
 */
export function useProfileHighlights({ expandedProfile, fetchHighlights }) {
  const focusedHighlights = ref({})

  const focusedRecentMoney = computed(() => {
    const rows = focusedHighlights.value?.recentMoney
    if (!rows) return []
    return Array.isArray(rows) ? rows : Object.values(rows)
  })

  const highlightsPending = ref(false)
  let highlightsTimer = null

  watch(
    () => expandedProfile.value?.pending ? null : expandedProfile.value?.id,
    id => {
      focusedHighlights.value = {}
      clearTimeout(highlightsTimer)
      if (!id) {
        highlightsPending.value = false
        return
      }

      highlightsPending.value = true
      highlightsTimer = setTimeout(async () => {
        try {
          const data = await fetchHighlights(id)
          // A reply for a card that has since been closed must not land.
          if (expandedProfile.value?.id !== id) return
          focusedHighlights.value = data || {}
        } catch (error) {
          safeLua(() => { throw error }, "ProfileSelect failed to load card highlights")
        } finally {
          if (expandedProfile.value?.id === id) highlightsPending.value = false
        }
      }, HIGHLIGHT_DELAY_MS)
    },
    { immediate: true }
  )

  /** Cancels a read that has not started yet; the view calls it on unmount. */
  function dispose() {
    clearTimeout(highlightsTimer)
  }

  return { focusedHighlights, focusedRecentMoney, highlightsPending, dispose }
}
