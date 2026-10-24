// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// Controller entry focus for career screens.
//
// Vanilla computer routes declare a Lua `targetScope`, so `activateRouteTargetScope()` wakes the
// screen's scope and the d-pad works at once. The mod's own routes (overhaul/ui/routes.lua) have none:
// the ComputerWrapper / LayoutMenu "root" scope starts inactive and the d-pad does nothing until A is
// pressed (verified in game on Loans). Calling focusScreenEntry() once the screen's content is rendered
// activates that scope, which focuses its `bng-scoped-nav-autofocus` item (else the first navigable one).
// It never steals focus that is already on something in the page.
import { getCurrentInstance, nextTick, onBeforeUnmount } from "vue"
import { activateRouteTargetScope, useScopedNav } from "@/services/scopedNav/api"
import { SCOPED_NAV_ATTR } from "@/services/scopedNav"
import useControls from "@/services/controls"

// A focused button that just became disabled still reads as focused until the browser drops it a
// moment later (after our refocus already ran), so a disabled element does not count as live focus.
const hasLiveFocus = () => {
  const active = document.activeElement
  return !!active && active !== document.body && document.contains(active) && !active.disabled && !active.hasAttribute(SCOPED_NAV_ATTR)
}

const wait = ms => new Promise(resolve => setTimeout(resolve, ms))

/**
 * @param {string} [scopeId="root"] the screen's scope (ComputerWrapper / LayoutMenu use "root")
 * @param {{ force?: boolean }} [opts] force: refocus even when something already has focus
 */
// Leaving a screen during its (up to 1.5 s) wait must not let that wait activate or move focus on the
// next screen: most computer screens share the "root" scope id, so a late retry would otherwise find
// and wake the *next* screen's scope. A call is stale once its screen component has unmounted, or once
// a newer screen has started its own entry (newest wins). The URL is not used: some screens change
// their own route params while staying open.
let entryTicket = 0

export function focusScreenEntry(scopeId = "root", { force = false, owner = null, isCurrent = () => true } = {}) {
  const ticket = ++entryTicket
  // the calling screen: passed in by useScreenEntry(), else whatever Vue knows (setup / lifecycle only)
  const instance = owner ? null : getCurrentInstance()
  const stale = () => ticket !== entryTicket || !!owner?.unmounted || !!instance?.isUnmounted || !isCurrent()
  return nextTick().then(async () => {
    if (stale()) return false
    const nav = useScopedNav()
    // during a route transition the screen (and its scope) can mount a little after this is called
    let scope = nav.getScopeById(scopeId)
    for (let i = 0; !scope && i < 15; i++) {
      await wait(100)
      if (stale()) return false
      scope = nav.getScopeById(scopeId)
    }
    if (stale()) return false
    // focus already inside this screen wins; focus left on the previous screen (still mounted during
    // the route swap) does not count
    if (!force && hasLiveFocus() && (!scope?.element || scope.element.contains(document.activeElement))) return false
    if (scopeId === "root" && activateRouteTargetScope()) return true
    if (!scope) return false
    if (nav.isActiveScope(scopeId)) return nav.requestScopeFocus(scopeId)
    nav.activateScope(scopeId)
    return true
  })
}

/**
 * Put focus back on a list after an in-place change removed the focused element (v-if swap, refresh).
 * Pass the element that should take focus; does nothing when focus is still on a live element or no
 * controller is connected.
 * force: move focus even when something has it. Use it for deliberate swaps (open / close a detail
 * page or confirm row): the game's scope repair may already have parked focus on the screen's
 * default item by the time this runs.
 * @param {() => HTMLElement|null|undefined} pick
 * @param {{ force?: boolean }} [opts]
 */
export function refocusIfLost(pick, { force = false } = {}) {
  return nextTick().then(() => {
    // mouse users keep the browser's own behaviour; only a pad needs focus to carry on
    if (!useControls().focusIfController) return false
    if (!force && hasLiveFocus()) return false
    const el = pick?.()
    if (!el || !document.contains(el) || document.activeElement === el) return false
    el.focus()
    return true
  })
}

/**
 * Call once in a screen's setup; returns focusScreenEntry bound to that screen, so a call made later
 * (after an await, from a watcher) still knows when its screen has gone and never touches the next one.
 * @returns {(scopeId?: string, opts?: { force?: boolean }) => Promise<boolean>}
 */
export function useScreenEntry() {
  const owner = { unmounted: false }
  onBeforeUnmount(() => {
    owner.unmounted = true
  })
  return (scopeId = "root", opts = {}) => focusScreenEntry(scopeId, { ...opts, owner })
}

/* Teleported scopes deactivate the screen scope without resuming it on close. */
export function returnFocusToOpener(pickOpener) {
  return nextTick().then(async () => {
    const el = pickOpener?.()
    if (!el || !document.contains(el)) return false
    const dialog = document.activeElement?.closest?.("dialog[open]") || document.querySelector?.("dialog[open]")
    if (dialog && !dialog.contains(el)) {
      await new Promise(resolve => {
        const observer = new MutationObserver(() => {
          if (dialog.isConnected && (dialog.open || dialog.classList?.contains("popup-wrapper"))) return
          observer.disconnect()
          resolve()
        })
        observer.observe(document.body, { subtree: true, childList: true, attributes: true, attributeFilter: ["open"] })
      })
      await nextTick()
      if (!document.contains(el)) return false
    }
    const nav = useScopedNav()
    const scopeId = el.closest(`[${SCOPED_NAV_ATTR}]`)?.getAttribute(SCOPED_NAV_ATTR)
    if (scopeId && nav.getScopeById(scopeId) && !nav.isActiveScope(scopeId)) {
      await nav.activateScope(scopeId)
    }
    if (!useControls().focusIfController) return false
    if (el.getAttribute(SCOPED_NAV_ATTR) === scopeId) return true
    if (document.activeElement === el) return true
    if (scopeId && nav.isActiveScope(scopeId) && nav.requestScopeFocus(scopeId, el, { force: true, reason: "overlay-closed" })) return true
    el.focus()
    return true
  })
}
