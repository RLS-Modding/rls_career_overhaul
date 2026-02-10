import { ref, reactive, onUnmounted } from 'vue'

/**
 * Composable for pointer-event based drag and drop.
 * Used by PhoneHomescreen for icon rearrangement.
 */
export function useDragAndDrop({ onDragMove, onDragEnd } = {}) {
  const isDragging = ref(false)
  const dragItem = ref(null)
  const dragPosition = reactive({ x: 0, y: 0 })
  const dragStartPosition = reactive({ x: 0, y: 0 })

  let moveHandler = null
  let upHandler = null

  function startDrag(e, item) {
    isDragging.value = true
    dragItem.value = item
    dragStartPosition.x = e.clientX
    dragStartPosition.y = e.clientY
    dragPosition.x = e.clientX
    dragPosition.y = e.clientY

    moveHandler = (ev) => {
      dragPosition.x = ev.clientX
      dragPosition.y = ev.clientY
      if (onDragMove) onDragMove(ev, item)
    }

    upHandler = (ev) => {
      endDrag(ev)
    }

    document.addEventListener('pointermove', moveHandler)
    document.addEventListener('pointerup', upHandler)
  }

  function endDrag(e) {
    if (moveHandler) document.removeEventListener('pointermove', moveHandler)
    if (upHandler) document.removeEventListener('pointerup', upHandler)
    moveHandler = null
    upHandler = null

    const item = dragItem.value
    isDragging.value = false
    dragItem.value = null

    if (onDragEnd) onDragEnd(e, item)
  }

  onUnmounted(() => {
    if (moveHandler) document.removeEventListener('pointermove', moveHandler)
    if (upHandler) document.removeEventListener('pointerup', upHandler)
  })

  return {
    isDragging,
    dragItem,
    dragPosition,
    dragStartPosition,
    startDrag,
    endDrag,
  }
}
