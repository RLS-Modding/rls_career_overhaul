import { computed, ref } from 'vue'

const SWIPE_DISMISS_PX = 72
const CLICK_SLOP_PX = 8

/**
 * iOS-style horizontal swipe-to-dismiss for phone notifications.
 * Tap is unchanged; a drag past the threshold dismisses without activating.
 */
export function useHorizontalSwipeDismiss({ getElementEl, onDismiss }) {
  const dragX = ref(0)
  const isDragging = ref(false)
  const isExiting = ref(false)
  const suppressClick = ref(false)

  let startX = 0
  let startY = 0
  let activePointerId = null
  let exitListener = null

  const swipeStyle = computed(() => {
    const x = dragX.value
    const touchOnly = { touchAction: 'pan-y' }
    if (!isDragging.value && !isExiting.value && x === 0) {
      return touchOnly
    }

    const abs = Math.abs(x)
    const opacity = isExiting.value ? 0 : Math.max(0.5, 1 - abs / 260)
    const useTransition = isExiting.value || (!isDragging.value && x !== 0)
    return {
      ...touchOnly,
      transform: `translateX(${x}px)`,
      opacity,
      transition: useTransition ? 'transform 0.24s ease, opacity 0.24s ease' : 'none',
      willChange: 'transform, opacity',
    }
  })

  function cleanupExitListener() {
    if (exitListener && getElementEl()) {
      getElementEl().removeEventListener('transitionend', exitListener)
    }
    exitListener = null
  }

  function resetSwipe() {
    cleanupExitListener()
    dragX.value = 0
    isDragging.value = false
    isExiting.value = false
    activePointerId = null
  }

  function finishDismiss() {
    const el = getElementEl()
    if (el) {
      el.dataset.swipeDismissed = '1'
    }
    cleanupExitListener()
    activePointerId = null
    onDismiss?.()
  }

  function snapBack() {
    isDragging.value = false
    dragX.value = 0
    activePointerId = null
  }

  function dismissHorizontally() {
    const el = getElementEl()
    if (!el) {
      finishDismiss()
      return
    }
    isExiting.value = true
    isDragging.value = false
    const sign = dragX.value >= 0 ? 1 : -1
    dragX.value = sign * (el.offsetWidth + 48)

    cleanupExitListener()
    exitListener = (event) => {
      if (event.propertyName !== 'transform') return
      finishDismiss()
    }
    el.addEventListener('transitionend', exitListener)
  }

  function onPointerDown(event) {
    if (isExiting.value || activePointerId != null) return
    if (event.button != null && event.button !== 0) return

    activePointerId = event.pointerId
    startX = event.clientX
    startY = event.clientY
    isDragging.value = true
    suppressClick.value = false

    try {
      event.currentTarget?.setPointerCapture?.(event.pointerId)
    } catch (_) {}
  }

  function onPointerMove(event) {
    if (activePointerId !== event.pointerId || isExiting.value) return

    const deltaX = event.clientX - startX
    const deltaY = event.clientY - startY

    if (Math.abs(deltaX) > CLICK_SLOP_PX || Math.abs(deltaY) > CLICK_SLOP_PX) {
      suppressClick.value = true
    }

    if (Math.abs(deltaY) > Math.abs(deltaX) * 1.25) {
      return
    }

    dragX.value = deltaX
  }

  function onPointerEnd(event) {
    if (activePointerId !== event.pointerId) return

    try {
      event.currentTarget?.releasePointerCapture?.(event.pointerId)
    } catch (_) {}

    if (Math.abs(dragX.value) >= SWIPE_DISMISS_PX) {
      dismissHorizontally()
      return
    }

    snapBack()
  }

  function onPointerCancel(event) {
    if (activePointerId !== event.pointerId) return
    snapBack()
  }

  return {
    swipeStyle,
    suppressClick,
    resetSwipe,
    onPointerDown,
    onPointerMove,
    onPointerEnd,
    onPointerCancel,
  }
}
