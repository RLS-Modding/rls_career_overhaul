// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// Owns vehicle-photo scrolling for ../views/ComputerMain.vue.
// activeId reads the selected vehicle ID; bind strip to the photo row.
// Reveals selected or focused photos and releases listeners and observers on unmount.
import { ref, watch, onUnmounted } from "vue"

// Keep scrolling local to the picker; scrollIntoView also moves the whole page.
export function useVehicleStrip(activeId) {
  const strip = ref(null)
  const canScrollLeft = ref(false)
  const canScrollRight = ref(false)
  const update = () => {
    const el = strip.value
    canScrollLeft.value = !!el && el.scrollLeft > 1
    canScrollRight.value = !!el && el.scrollLeft + el.clientWidth < el.scrollWidth - 1
  }
  const reveal = card => {
    const el = strip.value
    if (!el || !card || !el.contains(card)) return
    const edge = el.getBoundingClientRect()
    const box = card.getBoundingClientRect()
    if (box.left < edge.left) el.scrollLeft -= edge.left - box.left
    else if (box.right > edge.right) el.scrollLeft += box.right - edge.right
    update()
  }
  const revealActive = () => reveal(strip.value?.querySelector(".picker-thumb.active"))
  const onFocus = event => reveal(event.target.closest(".picker-thumb"))
  const onWheel = event => {
    const el = strip.value
    if (!el || event.ctrlKey || Math.abs(event.deltaX) > Math.abs(event.deltaY)) return
    const unit = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? el.clientWidth : 1
    const before = el.scrollLeft
    el.scrollLeft += event.deltaY * unit
    if (el.scrollLeft !== before) event.preventDefault()
    update()
  }
  const scrollPage = direction => {
    const el = strip.value
    if (el) el.scrollLeft += direction * el.clientWidth * 0.8
    update()
  }
  let disconnect = () => {}
  watch(strip, el => {
    disconnect()
    if (!el) { update(); return }
    const resize = new ResizeObserver(() => { revealActive(); update() })
    resize.observe(el)
    // BeamNG controller navigation marks focus with a CLASS.
    const classes = new MutationObserver(records => {
      for (const record of records) {
        const hadFocus = (record.oldValue || "").split(/\s+/).includes("focus-visible")
        if (!hadFocus && record.target.classList.contains("focus-visible")) reveal(record.target)
      }
      update()
    })
    classes.observe(el, { subtree: true, attributes: true, attributeOldValue: true, attributeFilter: ["class"], childList: true })
    el.addEventListener("wheel", onWheel, { passive: false })
    el.addEventListener("scroll", update)
    el.addEventListener("focusin", onFocus)
    disconnect = () => {
      resize.disconnect()
      classes.disconnect()
      el.removeEventListener("wheel", onWheel)
      el.removeEventListener("scroll", update)
      el.removeEventListener("focusin", onFocus)
    }
    revealActive()
    update()
  }, { flush: "post" })
  watch(activeId, revealActive, { flush: "post" })
  onUnmounted(() => disconnect())
  return { strip, canScrollLeft, canScrollRight, scrollPage }
}
