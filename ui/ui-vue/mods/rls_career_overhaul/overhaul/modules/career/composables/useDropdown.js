// A dropdown owns opening and placement timing; callers keep selection, focus and dismissal policies.
// Listener lifetimes stay with the caller so nested menus and controller scopes keep their ordering.
import { ref, nextTick } from 'vue'

export function useDropdown({
  containerRef, triggerSelector, menuSelector,
  open = ref(false), style = ref(''),
  gapPx = 8, zIndex, widthProperty = 'width', onOpen, onClose,
  canOpen = () => true, beforeOpen, afterOpen, beforeToggle, closeOnToggle,
  place, positionTiming = 'nextTick',
}) {
  const trigger = () => containerRef.value?.querySelector(triggerSelector)

  function close() {
    if (!open.value) return
    open.value = false
    onClose?.()
  }

  function position() {
    if (place) return place()
    const element = trigger()
    if (!element) return
    const rect = element.getBoundingClientRect()
    style.value = `position:fixed;z-index:${zIndex};top:${rect.bottom + gapPx}px;left:${rect.left}px;${widthProperty}:${rect.width}px;`
  }

  function toggle() {
    beforeToggle?.()
    if (open.value) return closeOnToggle ? closeOnToggle() : close()
    if (!canOpen()) return
    beforeOpen?.()
    if (positionTiming === 'beforeOpen') position()
    open.value = true
    onOpen?.()
    if (positionTiming === 'nextTick') nextTick(position)
    if (afterOpen) return nextTick().then(afterOpen)
  }

  function onDocumentClick(event) {
    if (!open.value) return
    const menu = document.querySelector(menuSelector)
    if (menu?.contains(event.target) || trigger()?.contains(event.target)) return
    close()
  }

  return { open, style, trigger, close, position, toggle, onDocumentClick }
}
