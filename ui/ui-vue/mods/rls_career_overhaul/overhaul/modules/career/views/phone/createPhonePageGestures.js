// Keep pointer-down state local to one mounted homescreen.
export function createPhonePageGestures({ isDraggingIcon, pagePointerStart, pageDragDelta, isDraggingPage, currentPageIndex, pages, PAGE_WIDTH, goToPage, reportUiFailure }) {
  let isPointerDown = false

  function onViewportPointerDown(e) {
    if (isDraggingIcon.value) return
    isPointerDown = true
    pagePointerStart.x = e.clientX
    pagePointerStart.y = e.clientY
    pageDragDelta.value = 0
    isDraggingPage.value = false
    // Capture pointer so we get events even if cursor leaves the phone
    if (e.target && e.target.setPointerCapture) {
      try { e.target.setPointerCapture(e.pointerId) } catch (_) { reportUiFailure(_, "on viewport pointer down (PhoneHomescreen)") }
    }
  }

  function onViewportPointerMove(e) {
    if (!isPointerDown || isDraggingIcon.value) return
    const dx = e.clientX - pagePointerStart.x
    if (!isDraggingPage.value && Math.abs(dx) > 8) {
      isDraggingPage.value = true
    }
    if (isDraggingPage.value) {
      // Block dragging right when on search page (rightmost)
      const onSearchPage = currentPageIndex.value === pages.value.length
      if (onSearchPage && dx < 0) {
        pageDragDelta.value = 0
      } else {
        // Clamp to one page width max so you can't visually skip pages
        pageDragDelta.value = Math.max(-PAGE_WIDTH, Math.min(PAGE_WIDTH, dx))
      }
    }
  }

  function onViewportPointerUp(e) {
    if (!isPointerDown) return
    isPointerDown = false
    // Release pointer capture
    if (e && e.target && e.target.releasePointerCapture) {
      try { e.target.releasePointerCapture(e.pointerId) } catch (_) { reportUiFailure(_, "on viewport pointer up (PhoneHomescreen)") }
    }
    if (isDraggingPage.value) {
      const threshold = 40
      const onSearchPage = currentPageIndex.value === pages.value.length
      if (pageDragDelta.value < -threshold && !onSearchPage) {
        goToPage(currentPageIndex.value + 1)
      } else if (pageDragDelta.value > threshold) {
        goToPage(currentPageIndex.value - 1)
      }
    }
    isDraggingPage.value = false
    pageDragDelta.value = 0
  }

  return { onViewportPointerDown, onViewportPointerMove, onViewportPointerUp }
}
