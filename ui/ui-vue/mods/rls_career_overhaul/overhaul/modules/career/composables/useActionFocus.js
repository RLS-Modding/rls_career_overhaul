// Preserve row identity across refresh/removal. Keep busy controls enabled and
// use aria-disabled + a guarded handler so focus is never dropped mid-request.
import { nextTick, ref, unref } from "vue"
import { refocusIfLost } from "./useScreenEntryFocus.js"

export function useActionFocus(root) {
  const busy = ref(false)
  let key = null
  let index = 0
  const controls = () => [...(unref(root)?.querySelectorAll('[data-fk]:not(:disabled)') || [])]
  function remember() {
    const items = controls()
    const active = document.activeElement?.closest('[data-fk]')
    index = Math.max(0, items.indexOf(active))
    key = active?.dataset.fk ?? null
  }
  async function restore() {
    await nextTick()
    const items = controls()
    const target = items.find(el => el.dataset.fk === key) || items[Math.min(index, items.length - 1)]
    return refocusIfLost(() => target)
  }
  async function run(action) {
    if (busy.value) return
    remember()
    busy.value = true
    try { return await action() }
    finally { busy.value = false; await restore() }
  }
  return { busy, remember, restore, run }
}
