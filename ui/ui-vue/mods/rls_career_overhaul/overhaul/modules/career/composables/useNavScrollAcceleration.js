// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// Right-stick scroll acceleration for every UI scroll area.
//
// The game's crossfire (bundled, cannot be patched from the mod) scrolls the area under focus at a
// constant `value * 15` px per frame while the right stick is held (crossfire.js navigateScroll).
// Long lists take ages at that speed, so while the stick stays held in one direction we add an
// extra, eased delta on top of crossfire's step: 1x for the first 250 ms (fine positioning stays
// precise), then a smoothstep ramp to 3.5x total by ~1.35 s. Release, a direction flip, a new scroll
// area or a mouse wheel tick resets the ramp.
//
// Safety rules:
// - We only add speed while crossfire is visibly scrolling the same area (its step shows up as
//   movement between our frames). If the area does not move for a few frames (scoped nav swallowed
//   the event, no nav-scroll area applies, end reached) we stop and wait for the next stick event.
// - No rAF loop runs unless a stick value above crossfire's dead zone is held.
// - prefers-reduced-motion: reduce keeps crossfire's constant speed (no ramp).
// - Mouse wheel is never intercepted.
//
// D-pad repeat is deliberately not accelerated: crossfire's 500/200 ms repeat timer is private
// module state, so speeding it up would mean injecting extra focus moves that race its own repeat
// session and its smooth scrollFix.
import { onMounted, onBeforeUnmount } from "vue"

// Same attribute names as crossfire.js SCROLL_ATTR / SCROLL_FORCE_ATTR (set by v-bng-ui-nav-scroll).
const SCROLL_ATTR = "bng-nav-scroll"
const SCROLL_FORCE_ATTR = "bng-nav-scroll-force"
// DOM event UINavEvents.js dispatches for every Lua UINavigation event.
const UI_NAV_EVENT = "ui_nav"

const BASE_PX = 15 // crossfire: navScrolling[axis].amount = value * 15 (px per frame)
const MIN_STEP = 1 // crossfire ignores |value * 15| < 1
const RAMP_DELAY_MS = 250
const RAMP_MS = 1100
const MAX_MULT = 3.5
const STALL_FRAMES = 8 // frames without crossfire movement before we give up

const AXES = {
  rotate_v_cam: {
    key: "v",
    sign: -1, // crossfire negates the vertical value
    move: "top",
    read: "scrollTop",
    scroll: "scrollHeight",
    client: "clientHeight",
    overflow: "overflowY",
  },
  rotate_h_cam: {
    key: "h",
    sign: 1,
    move: "left",
    read: "scrollLeft",
    scroll: "scrollWidth",
    client: "clientWidth",
    overflow: "overflowX",
  },
}

let installs = 0
let rafId = 0
let reducedMotion = null
const states = {}

function axisState(axis) {
  if (!states[axis.key]) states[axis.key] = { axis, dir: 0, value: 0, start: 0, area: null, focus: null, lastPos: null, stall: 0, seen: false, carry: 0 }
  return states[axis.key]
}

function resetState(s) {
  s.dir = 0
  s.value = 0
  s.area = null
  s.focus = null
  s.lastPos = null
  s.stall = 0
  s.seen = false
  s.carry = 0
}

function resetAll() {
  for (const key in states) resetState(states[key])
  if (rafId) {
    cancelAnimationFrame(rafId)
    rafId = 0
  }
}

function overflows(node, axis) {
  if (node.getAttribute(SCROLL_ATTR) === "false") return false
  const style = getComputedStyle(node)
  const ov = style[axis.overflow]
  return (ov === "auto" || ov === "scroll") && node[axis.scroll] > node[axis.client]
}

// Mirror of crossfire findScrollable(link, axis, thumbstick = true): the first ancestor of the focused
// element (starting at its parent) carrying the nav-scroll attribute that overflows, else the first
// forced nav-scroll area that overflows.
function findArea(axis) {
  let node = document.activeElement?.parentNode
  while (node && node.isConnected && node.nodeType === Node.ELEMENT_NODE) {
    if (node.hasAttribute(SCROLL_ATTR) && overflows(node, axis)) return node
    node = node.parentNode
  }
  for (const el of document.querySelectorAll(`[${SCROLL_FORCE_ATTR}]`)) {
    if (overflows(el, axis)) return el
  }
  return null
}

function rampMultiplier(ms) {
  const t = Math.min(1, Math.max(0, (ms - RAMP_DELAY_MS) / RAMP_MS))
  return 1 + (MAX_MULT - 1) * t * t * (3 - 2 * t) // smoothstep
}

function onUiNav(e) {
  const axis = AXES[e.detail?.name]
  if (!axis) return
  const s = axisState(axis)
  const value = Number(e.detail.value) || 0
  const amount = value * axis.sign * BASE_PX
  if (Math.abs(amount) < MIN_STEP || reducedMotion?.matches) {
    resetState(s)
    return
  }
  const dir = Math.sign(amount)
  const focus = document.activeElement
  if (dir !== s.dir || focus !== s.focus || !s.area?.isConnected) {
    resetState(s)
    s.area = findArea(axis)
    if (!s.area) return
    s.dir = dir
    s.focus = focus
    s.start = performance.now()
  }
  s.value = Math.abs(value)
  // Once crossfire has been seen moving this area, a fresh event re-arms the stall window (its loop
  // may be restarting). Before that, events must not keep an idle probe alive: if crossfire never
  // scrolls here, the probe ends after STALL_FRAMES and the next event starts a new one.
  if (s.seen) s.stall = 0
  if (!rafId) rafId = requestAnimationFrame(frame)
}

function frame(now) {
  rafId = 0
  let running = false
  for (const key in states) {
    const s = states[key]
    if (!s.dir) continue
    const { axis } = s
    const el = s.area
    if (!el?.isConnected) {
      resetState(s)
      continue
    }
    const pos = el[axis.read]
    const max = el[axis.scroll] - el[axis.client]
    if (s.dir > 0 ? pos >= max - 0.5 : pos <= 0.5) {
      // End reached: crossfire clamps, nothing left to accelerate. Next stick event restarts.
      resetState(s)
      continue
    }
    if (s.lastPos !== null) {
      if ((pos - s.lastPos) * s.dir >= 0.5) {
        s.seen = true
        s.stall = 0
      } else if (++s.stall > STALL_FRAMES) {
        // Crossfire is not scrolling this area (event swallowed, other area, released elsewhere).
        resetState(s)
        continue
      }
    }
    let after = pos
    if (s.seen) {
      const extra = BASE_PX * s.value * (rampMultiplier(now - s.start) - 1) + s.carry
      const step = Math.floor(extra)
      s.carry = extra - step
      if (step > 0) {
        const target = Math.min(max, Math.max(0, pos + step * s.dir))
        el.scrollTo({ [axis.move]: target, behavior: "instant" })
        after = el[axis.read]
      }
    }
    s.lastPos = after
    running = true
  }
  if (running) rafId = requestAnimationFrame(frame)
}

function onWheel() {
  if (rafId) resetAll()
}

function install() {
  if (installs++ > 0) return
  reducedMotion = window.matchMedia ? window.matchMedia("(prefers-reduced-motion: reduce)") : null
  // Capture on window: scoped nav may stop the event before it reaches body.
  window.addEventListener(UI_NAV_EVENT, onUiNav, true)
  window.addEventListener("wheel", onWheel, { capture: true, passive: true })
}

function uninstall() {
  if (--installs > 0) return
  installs = 0
  window.removeEventListener(UI_NAV_EVENT, onUiNav, true)
  window.removeEventListener("wheel", onWheel, { capture: true })
  resetAll()
}

export function useNavScrollAcceleration() {
  onMounted(install)
  onBeforeUnmount(uninstall)
}
