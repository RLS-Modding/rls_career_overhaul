// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

import { computed, getCurrentScope, nextTick, onScopeDispose, ref } from 'vue'

// One duration for the slide animation: the CSS transition (seconds) and the wait before a wrap jump is hidden
// behind the slide that has just finished moving.
const CAROUSEL_TRANSITION_MS = 350
const CAROUSEL_TRANSITION_S = CAROUSEL_TRANSITION_MS / 1000
// Jumps of more than one slide (a map or list tap far away) take a little longer, capped so they never feel stuck.
const LONG_JUMP_BASE_S = 0.3
const LONG_JUMP_S_PER_SLIDE = 0.025
const LONG_JUMP_MAX_S = 0.7
const SLIDE_GAP_PX = 10
// A drag only starts after a small move, so taps are not read as drags.
const DRAG_START_PX = 8
// A release must pass a quarter of a slide to change slide; less snaps back.
const SNAP_FRACTION = 0.25
// The release of a drag also produces a click; ignore clicks for a moment after it.
const CLICK_SUPPRESS_MS = 150

/**
 * Bottom card carousel of the phone map screens.
 *
 * The strip repeats the items three times so a drag can run past either end. When a step leaves the middle copy
 * in the direction of travel, the selection moves to the new card and the strip jumps back one cycle after the
 * slide has finished, so the jump is never seen.
 *
 * This owns the slide index, the drag gesture (document pointer listeners and pointer capture), the wrap timer and
 * its animation frame, and tears them all down when the calling component's scope ends. The screen keeps what a
 * selection means: `onSelect` receives the card a settled slide lands on, and the screen decides how to focus the map.
 */
export function usePhoneCarousel({ items, slideWidth, viewportRef, onSelect }) {
  const slides = computed(() => {
    const list = items.value
    if (list.length < 2) return list
    return [...list, ...list, ...list]
  })
  const slideStep = computed(() => slideWidth.value + SLIDE_GAP_PX)
  const slideIndex = ref(0)
  const dragDelta = ref(0)
  const isDragging = ref(false)
  const isWrapping = ref(false)
  const transitionDuration = ref(CAROUSEL_TRANSITION_S)
  const slideOffset = computed(() => -slideIndex.value * slideStep.value + dragDelta.value)

  let pointerId = null
  let pointerStartX = 0
  let clickSuppressedUntil = 0
  const pendingTimers = new Set()
  const pendingFrames = new Set()
  const capturedPointers = new Map()
  let disposed = false

  // Where item `itemIndex` sits in the strip when the strip is centred on its middle copy.
  function slideIndexFor(itemIndex) {
    return items.value.length >= 2 ? items.value.length + itemIndex : itemIndex
  }

  function selectSlide(index) {
    const item = slides.value[index]
    if (item) onSelect(item)
  }

  function scheduleWrapCorrection(index) {
    const timer = setTimeout(() => {
      pendingTimers.delete(timer)
      isWrapping.value = true
      slideIndex.value = index
      nextTick(() => {
        if (disposed) return
        const frame = requestAnimationFrame(() => {
          pendingFrames.delete(frame)
          isWrapping.value = false
        })
        pendingFrames.add(frame)
      })
    }, CAROUSEL_TRANSITION_MS)
    pendingTimers.add(timer)
  }

  // Correct to the middle copy's entry edge even if another swipe arrives before the wrap timer fires.
  function moveBy(direction) {
    const cycle = items.value.length
    const target = slideIndex.value + direction
    const leavesMiddleCopy = direction > 0 ? target >= 2 * cycle : target < cycle
    if (cycle >= 2 && leavesMiddleCopy) {
      isDragging.value = false
      dragDelta.value = 0
      transitionDuration.value = CAROUSEL_TRANSITION_S
      slideIndex.value = target
      selectSlide(target)
      scheduleWrapCorrection(direction > 0 ? cycle : 2 * cycle - 1)
      return
    }
    // Without a wrap the strip stops at the ends. With one item there is no strip to scroll.
    const landed = cycle >= 2 ? target : direction > 0 ? Math.min(target, cycle - 1) : Math.max(0, target)
    slideIndex.value = landed
    selectSlide(landed)
  }

  // Moves to an item chosen elsewhere (a card or marker the user tapped). Short hops keep the default transition.
  function scrollToItem(itemIndex) {
    const target = slideIndexFor(itemIndex)
    const distance = Math.abs(target - slideIndex.value)
    transitionDuration.value = distance > 1
      ? Math.min(LONG_JUMP_MAX_S, LONG_JUMP_BASE_S + distance * LONG_JUMP_S_PER_SLIDE)
      : CAROUSEL_TRANSITION_S
    slideIndex.value = target
  }

  // Places the strip on an item without animating, when the list or the selection is rebuilt.
  function snapToItem(itemIndex) {
    slideIndex.value = slideIndexFor(itemIndex)
  }

  function capturePointer(id) {
    const viewport = viewportRef.value
    if (viewport?.setPointerCapture) {
      try {
        viewport.setPointerCapture(id)
        capturedPointers.set(id, viewport)
      } catch (_) {}
    }
  }

  function releasePointer(id) {
    const viewport = capturedPointers.get(id) || viewportRef.value
    if (viewport?.releasePointerCapture) {
      try { viewport.releasePointerCapture(id) } catch (_) {}
    }
    capturedPointers.delete(id)
  }

  function removeDocumentListeners() {
    document.removeEventListener('pointermove', onDocumentPointerMove)
    document.removeEventListener('pointerup', onDocumentPointerEnd)
    document.removeEventListener('pointercancel', onDocumentPointerEnd)
  }

  function onPointerDown(event) {
    if (!event.currentTarget) return
    pointerId = event.pointerId
    pointerStartX = event.clientX
    dragDelta.value = 0
    isDragging.value = false
    // Document-level so a drag keeps tracking when the finger leaves the strip.
    document.addEventListener('pointermove', onDocumentPointerMove)
    document.addEventListener('pointerup', onDocumentPointerEnd)
    document.addEventListener('pointercancel', onDocumentPointerEnd)
  }

  function onDocumentPointerMove(event) {
    if (event.pointerId !== pointerId) return
    const dx = event.clientX - pointerStartX
    if (!isDragging.value && Math.abs(dx) > DRAG_START_PX) {
      isDragging.value = true
      capturePointer(event.pointerId)
    }
    if (isDragging.value) {
      event.preventDefault()
      const limit = slideStep.value
      dragDelta.value = Math.max(-limit, Math.min(limit, dx))
    }
  }

  // A cancelled pointer is settled like a released one, so a drag interrupted by the system still snaps.
  function onDocumentPointerEnd(event) {
    if (event.pointerId !== pointerId) return
    releasePointer(event.pointerId)
    removeDocumentListeners()
    if (isDragging.value) {
      const threshold = slideStep.value * SNAP_FRACTION
      if (dragDelta.value < -threshold) moveBy(1)
      else if (dragDelta.value > threshold) moveBy(-1)
      clickSuppressedUntil = Date.now() + CLICK_SUPPRESS_MS
    }
    isDragging.value = false
    dragDelta.value = 0
  }

  // The item under a tap on the strip, or undefined when there is none or a drag has just ended.
  function itemAtClick(event) {
    if (Date.now() < clickSuppressedUntil) return undefined
    const viewport = viewportRef.value
    if (!viewport) return undefined
    const track = viewport.querySelector('.map-carousel-track')
    const rect = viewport.getBoundingClientRect()
    const trackPadding = track ? parseFloat(getComputedStyle(track).paddingLeft) || 0 : 0
    const x = event.clientX - rect.left - trackPadding - slideOffset.value
    if (slideStep.value <= 0) return undefined
    const index = Math.floor(x / slideStep.value)
    return slides.value[Math.max(0, Math.min(index, slides.value.length - 1))]
  }

  // Cancels every timer and frame and detaches the drag listeners, so nothing runs after the screen is gone.
  function dispose() {
    disposed = true
    removeDocumentListeners()
    capturedPointers.forEach((viewport, id) => releasePointer(id))
    pendingTimers.forEach(timer => clearTimeout(timer))
    pendingTimers.clear()
    pendingFrames.forEach(frame => cancelAnimationFrame(frame))
    pendingFrames.clear()
  }

  if (getCurrentScope()) onScopeDispose(dispose)

  return {
    slides,
    slideOffset,
    transitionDuration,
    isDragging,
    isWrapping,
    onPointerDown,
    itemAtClick,
    scrollToItem,
    snapToItem,
  }
}
