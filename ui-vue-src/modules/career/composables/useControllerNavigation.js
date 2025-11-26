import { ref, computed, onMounted, onUnmounted, watch, nextTick } from "vue"

const DOM_UI_NAVIGATION_EVENT = "ui_nav"
const FOCUSABLE_SELECTOR = "[data-focusable]:not([data-focusable-disabled])"
const FOCUSED_CLASS = "controller-focused"

export function useControllerNavigation(options = {}) {
  const {
    onBack = null,
    onTabLeft = null,
    onTabRight = null,
    onOk = null,
    containerRef = null,
    scrollContainer = null
  } = options

  const currentFocusedElement = ref(null)
  const isControllerActive = ref(false)
  const isEnabled = ref(true)
  const modalStack = ref([])
  let container = null
  let lastInputTime = 0
  let scrollAnimationFrame = null

  const setContainer = (el) => {
    container = el
  }

  const initDocumentListener = () => {
    document.addEventListener(DOM_UI_NAVIGATION_EVENT, handleNavEvent)
  }

  const removeDocumentListener = () => {
    document.removeEventListener(DOM_UI_NAVIGATION_EVENT, handleNavEvent)
  }

  const enable = () => { isEnabled.value = true }
  const disable = () => { isEnabled.value = false; clearFocus() }

  const clearFocus = () => {
    if (currentFocusedElement.value) {
      currentFocusedElement.value.classList.remove(FOCUSED_CLASS)
      currentFocusedElement.value = null
    }
  }

  const setFocus = (element) => {
    if (!element || !isEnabled.value) return
    clearFocus()
    element.classList.add(FOCUSED_CLASS)
    currentFocusedElement.value = element
    scrollIntoViewIfNeeded(element)
  }

  const scrollIntoViewIfNeeded = (element) => {
    if (!element) return
    const rect = element.getBoundingClientRect()
    const containerRect = container?.getBoundingClientRect() || { top: 0, bottom: window.innerHeight, left: 0, right: window.innerWidth }
    const isOutOfView = rect.top < containerRect.top || rect.bottom > containerRect.bottom || rect.left < containerRect.left || rect.right > containerRect.right
    if (isOutOfView) {
      element.scrollIntoView({ behavior: "smooth", block: "nearest", inline: "nearest" })
    }
  }

  const getActiveContainer = () => {
    if (modalStack.value.length > 0) {
      const topModal = modalStack.value[modalStack.value.length - 1]
      return topModal.element
    }
    return container
  }

  const getFocusableElements = () => {
    const activeContainer = getActiveContainer()
    if (!activeContainer) return []
    const elements = Array.from(activeContainer.querySelectorAll(FOCUSABLE_SELECTOR))
    return elements.filter(el => {
      const style = window.getComputedStyle(el)
      const rect = el.getBoundingClientRect()
      return style.display !== "none" && style.visibility !== "hidden" && style.pointerEvents !== "none" && rect.width > 0 && rect.height > 0
    })
  }

  const pushModal = (modalElement, onClose) => {
    if (!modalElement) return
    const previousFocus = currentFocusedElement.value
    modalStack.value.push({ element: modalElement, onClose, previousFocus })
    nextTick(() => {
      const elements = getFocusableElements()
      if (elements.length > 0) {
        setFocus(elements[0])
      }
    })
  }

  const popModal = () => {
    if (modalStack.value.length === 0) return false
    const modal = modalStack.value.pop()
    if (modal.onClose) {
      modal.onClose()
    }
    nextTick(() => {
      if (modal.previousFocus && document.body.contains(modal.previousFocus)) {
        setFocus(modal.previousFocus)
      } else {
        focusFirst()
      }
    })
    return true
  }

  const removeModal = (modalElement) => {
    const index = modalStack.value.findIndex(m => m.element === modalElement)
    if (index === -1) return false
    const modal = modalStack.value.splice(index, 1)[0]
    nextTick(() => {
      if (modal.previousFocus && document.body.contains(modal.previousFocus)) {
        setFocus(modal.previousFocus)
      } else {
        focusFirst()
      }
    })
    return true
  }

  const hasActiveModal = () => modalStack.value.length > 0

  const getElementCenter = (el) => {
    const rect = el.getBoundingClientRect()
    return { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2, rect }
  }

  const findNearestElement = (direction) => {
    const elements = getFocusableElements()
    if (elements.length === 0) return null

    if (!currentFocusedElement.value) {
      return elements[0]
    }

    const current = getElementCenter(currentFocusedElement.value)
    let bestCandidate = null
    let bestScore = Infinity

    const directionVectors = {
      up: { primary: "y", secondary: "x", sign: -1 },
      down: { primary: "y", secondary: "x", sign: 1 },
      left: { primary: "x", secondary: "y", sign: -1 },
      right: { primary: "x", secondary: "y", sign: 1 }
    }

    const dir = directionVectors[direction]
    if (!dir) return null

    for (const el of elements) {
      if (el === currentFocusedElement.value) continue

      const candidate = getElementCenter(el)
      const primaryDiff = (candidate[dir.primary] - current[dir.primary]) * dir.sign
      const secondaryDiff = Math.abs(candidate[dir.secondary] - current[dir.secondary])

      if (primaryDiff <= 0) continue

      const score = primaryDiff + secondaryDiff * 0.5
      if (score < bestScore) {
        bestScore = score
        bestCandidate = el
      }
    }

    if (!bestCandidate) {
      const currentIndex = elements.indexOf(currentFocusedElement.value)
      if (currentIndex === -1) {
        bestCandidate = elements[0]
      } else if (direction === "down" || direction === "right") {
        bestCandidate = elements[(currentIndex + 1) % elements.length]
      } else {
        bestCandidate = elements[(currentIndex - 1 + elements.length) % elements.length]
      }
    }

    return bestCandidate
  }

  const isSliderElement = (el) => {
    return el && el.hasAttribute("data-slider")
  }

  const adjustSliderValue = (element, delta) => {
    if (!element) return false
    const slider = element.querySelector('input[type="range"]')
    if (!slider) return false
    const min = parseFloat(slider.min) || 0
    const max = parseFloat(slider.max) || 100
    const step = parseFloat(slider.step) || 1
    const currentValue = parseFloat(slider.value) || 0
    const newValue = Math.max(min, Math.min(max, currentValue + (delta * step)))
    slider.value = newValue
    slider.dispatchEvent(new Event("input", { bubbles: true }))
    return true
  }

  const navigateDirection = (direction) => {
    const focused = currentFocusedElement.value
    if (focused && isSliderElement(focused) && (direction === "left" || direction === "right")) {
      const delta = direction === "right" ? 1 : -1
      adjustSliderValue(focused, delta)
      return
    }
    const next = findNearestElement(direction)
    if (next) setFocus(next)
  }

  const triggerClick = () => {
    if (!currentFocusedElement.value) return
    if (onOk) {
      onOk(currentFocusedElement.value)
    }
    currentFocusedElement.value.click()
  }

  const getScrollableContainer = () => {
    if (scrollContainer?.value) {
      return scrollContainer.value.$el || scrollContainer.value
    }
    const activeContainer = getActiveContainer()
    if (activeContainer) {
      const scrollable = activeContainer.querySelector(".tuning-scrollable, .scrollable-content, .content-body, .modal-body, .selection-list")
      if (scrollable) return scrollable
    }
    return activeContainer
  }

  const handleJoystickScroll = (value, axis) => {
    const scrollEl = getScrollableContainer()
    if (!scrollEl) return
    const deadzone = 0.15
    if (Math.abs(value) < deadzone) {
      if (scrollAnimationFrame) {
        cancelAnimationFrame(scrollAnimationFrame)
        scrollAnimationFrame = null
      }
      return
    }
    const speed = 10
    const scrollAmount = value * speed
    if (axis === "y") {
      scrollEl.scrollTop += scrollAmount
    } else if (axis === "x") {
      scrollEl.scrollLeft += scrollAmount
    }
  }

  const handleNavEvent = (e) => {
    if (!isEnabled.value) return

    const { name, value } = e.detail || {}

    if (name === "ls_y" || name === "rs_y") {
      handleJoystickScroll(value, "y")
      return
    }

    if (value !== 1) return

    isControllerActive.value = true
    lastInputTime = Date.now()

    e.stopPropagation()
    e.preventDefault()

    switch (name) {
      case "focus_u":
        navigateDirection("up")
        break
      case "focus_d":
        navigateDirection("down")
        break
      case "focus_l":
        navigateDirection("left")
        break
      case "focus_r":
        navigateDirection("right")
        break
      case "ok":
        triggerClick()
        break
      case "back":
        if (modalStack.value.length > 0) {
          popModal()
        } else if (onBack) {
          onBack()
        }
        break
      case "tab_l":
        if (onTabLeft) onTabLeft()
        break
      case "tab_r":
        if (onTabRight) onTabRight()
        break
    }
  }

  const focusFirst = () => {
    const elements = getFocusableElements()
    if (elements.length > 0) {
      setFocus(elements[0])
    }
  }

  const focusElement = (selector) => {
    const activeContainer = getActiveContainer()
    if (!activeContainer) return
    const el = activeContainer.querySelector(selector)
    if (el && el.matches(FOCUSABLE_SELECTOR)) {
      setFocus(el)
    }
  }

  if (containerRef) {
    watch(containerRef, (newRef) => {
      if (newRef) {
        const el = newRef.$el || newRef
        setContainer(el)
      }
    }, { immediate: true })
  }

  onMounted(() => {
    if (containerRef?.value) {
      const el = containerRef.value.$el || containerRef.value
      setContainer(el)
    }
    initDocumentListener()
  })

  onUnmounted(() => {
    clearFocus()
    modalStack.value = []
    if (scrollAnimationFrame) {
      cancelAnimationFrame(scrollAnimationFrame)
    }
    removeDocumentListener()
    container = null
  })

  return {
    currentFocusedElement: computed(() => currentFocusedElement.value),
    isControllerActive: computed(() => isControllerActive.value),
    isEnabled: computed(() => isEnabled.value),
    hasActiveModal: computed(() => modalStack.value.length > 0),
    setContainer,
    setFocus,
    clearFocus,
    focusFirst,
    focusElement,
    enable,
    disable,
    navigateDirection,
    pushModal,
    popModal,
    removeModal
  }
}

export default useControllerNavigation
