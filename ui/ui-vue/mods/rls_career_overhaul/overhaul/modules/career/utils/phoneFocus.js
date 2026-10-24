// The phone owns target eligibility; stock crossfire still owns movement and OK.
// Inert is not a crossfire boundary, so mirror it to the stock opt-out attributes.
const CONTROLS = 'button, input:not([type="hidden"]), textarea, select, a[href], [role="button"], [role="tab"], [role="checkbox"], [role="radio"], [role="switch"], [role="slider"]'
const CANDIDATES = `${CONTROLS}, [bng-nav-item], [tabindex], [ng-click], [ui-sref]`

export function isPhoneControl(element) {
  return element.matches(CONTROLS) || element.matches('[bng-scoped-nav][bng-nav-item]')
}

function isHidden(element, root) {
  if (element.closest('[inert], [hidden], [aria-hidden="true"], [aria-disabled="true"], :disabled')) return true
  if (element.parentElement?.closest('[bng-no-child-nav="true"], [bng-no-child-nav="1"]')) return true
  const rect = element.getBoundingClientRect()
  if (!rect.width || !rect.height) return true
  let scrollX = false, scrollY = false
  for (let parent = element; parent; parent = parent.parentElement) {
    if (/(?:^|\s)[\w-]+-leave-(?:active|to)(?:\s|$)/.test(parent.className)) return true
    const style = getComputedStyle(parent)
    if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') return true
    // Scrollable lists retain their offscreen controls: crossfire reveals them.
    // Translated carousel pages inside a clipped viewport must stay out of nav.
    scrollX ||= /auto|scroll/.test(style.overflowX) && parent.scrollWidth > parent.clientWidth
    scrollY ||= /auto|scroll/.test(style.overflowY) && parent.scrollHeight > parent.clientHeight
    if (/hidden|clip/.test(`${style.overflowX} ${style.overflowY}`)) {
      const clip = parent.getBoundingClientRect()
      if (!scrollX && /hidden|clip/.test(style.overflowX) && (rect.right <= clip.left || rect.left >= clip.right)) return true
      if (!scrollY && /hidden|clip/.test(style.overflowY) && (rect.bottom <= clip.top || rect.top >= clip.bottom)) return true
    }
    if (parent === root) break
  }
  return false
}

export function installPhoneFocus(root, { focus, controller, requestFrame = requestAnimationFrame, cancelFrame = cancelAnimationFrame }) {
  const managed = new Map()
  const rootHadFrameOptOut = root.classList.contains('no-focus-frame')
  if (!rootHadFrameOptOut) root.classList.add('no-focus-frame')
  let frame = null
  const attr = (element, name, value) => {
    if (element.getAttribute(name) !== value) element.setAttribute(name, value)
  }
  function refresh() {
    if (frame !== null) cancelFrame(frame)
    frame = null
    const targets = []
    for (const element of managed.keys()) if (!root.contains(element)) managed.delete(element)
    for (const element of root.querySelectorAll(CANDIDATES)) {
      // Stock widgets own eligibility and focus inside their nested scope.
      // Manage the widget's outer target only, so activation can expose its input.
      const widget = element.parentElement?.closest('[bng-scoped-nav]')
      if (widget && widget !== root && root.contains(widget)) continue
      if (!managed.has(element)) managed.set(element, {
        noNav: element.getAttribute('bng-no-nav'), item: element.getAttribute('bng-nav-item'),
        tab: element.getAttribute('tabindex'), noFrame: element.classList.contains('no-focus-frame'),
      })
      const original = managed.get(element)
      const control = isPhoneControl(element)
      const scopedControl = element.matches('[bng-scoped-nav][bng-nav-item]')
      // Active stock scopes toggle their own no-nav/tabindex state. Preserve it
      // rather than unlocking the outer target while its inner control is live.
      if (scopedControl) {
        if (!element.classList.contains('no-focus-frame')) element.classList.add('no-focus-frame')
        if (isHidden(element, root)) {
          original.scopeHidden ??= { noNav: element.getAttribute('bng-no-nav'), tab: element.getAttribute('tabindex') }
          attr(element, 'bng-no-nav', 'true')
          attr(element, 'tabindex', '-1')
        } else {
          if (original.scopeHidden) {
            for (const [name, value] of [['bng-no-nav', original.scopeHidden.noNav], ['tabindex', original.scopeHidden.tab]]) {
              if (value === null) element.removeAttribute(name)
              else attr(element, name, value)
            }
            delete original.scopeHidden
          }
          targets.push(element)
        }
        continue
      }
      const enabled = control && original.noNav !== 'true' && !isHidden(element, root)
      attr(element, 'bng-no-nav', enabled ? 'false' : 'true')
      if (!element.classList.contains('no-focus-frame')) element.classList.add('no-focus-frame')
      if (control) {
        attr(element, 'data-phone-control', '')
        if (enabled) attr(element, 'bng-nav-item', '')
      }
      if (!enabled) {
        if (element.classList.contains('focus-visible')) element.classList.remove('focus-visible')
        attr(element, 'tabindex', '-1')
      } else {
        attr(element, 'tabindex', original.tab ?? '0')
        targets.push(element)
      }
    }
    // Preserve valid focus (including a pointer-selected field), and only move
    // focus for controller users after the old page/control becomes unavailable.
    if (!controller() || targets.some(target => target === root.ownerDocument.activeElement ||
      target.matches('[bng-scoped-nav]') && target.contains(root.ownerDocument.activeElement))) return
    const active = root.ownerDocument.activeElement
    // Container scopes have no outer navigation item. Their coordinator owns
    // child focus just like a stock widget; do not replace it with a page target.
    const activeScope = active?.closest('[bng-scoped-nav]')
    if (activeScope && activeScope !== root && root.contains(activeScope) && !isHidden(active, root)) return
    if (active && !root.contains(active) && active.closest('dialog, [role="dialog"], [aria-modal="true"]')) return
    const content = targets.find(element => element.closest('.phone-content'))
    const target = content || targets[0]
    if (target) focus(target)
  }
  function schedule() {
    if (frame === null) frame = requestFrame(refresh)
  }
  const observer = new MutationObserver(schedule)
  observer.observe(root, { subtree: true, childList: true, attributes: true,
    attributeFilter: ['class', 'style', 'inert', 'hidden', 'disabled', 'aria-hidden', 'aria-disabled', 'bng-no-child-nav'] })
  // Recheck clipping immediately before stock direction search, and after CSS
  // carousel transitions. No per-frame geometry polling is needed.
  root.ownerDocument.addEventListener('ui_nav', refresh, true)
  root.addEventListener('transitionend', schedule)
  refresh()
  return {
    refresh: schedule,
    dispose() {
      observer.disconnect()
      if (frame !== null) cancelFrame(frame)
      root.ownerDocument.removeEventListener('ui_nav', refresh, true)
      root.removeEventListener('transitionend', schedule)
      if (!rootHadFrameOptOut) root.classList.remove('no-focus-frame')
      for (const [element, original] of managed) {
        for (const [name, value] of [['bng-no-nav', original.noNav], ['bng-nav-item', original.item], ['tabindex', original.tab]]) {
          if (value === null) element.removeAttribute(name)
          else element.setAttribute(name, value)
        }
        element.removeAttribute('data-phone-control')
        if (!original.noFrame) element.classList.remove('no-focus-frame')
      }
    },
  }
}
