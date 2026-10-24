// The save strip: which card is selected, which one is open, where the track sits, and every move between them. The
// view owns the DOM refs and the card list; this owns the motion. Layout is read from the probes, never the cards.
import { computed, nextTick, ref, watch } from "vue"

/** How long the selection has to sit still before the card opens. */
const EXPAND_DELAY_MS = 1500

/** A move that ends with a card opening; paced to feel like one gesture. */
const SLIDE_MS = 460

/** A browse step: long enough to watch the strip travel, no longer. */
const BROWSE_SLIDE_MS = 260

/** Ceiling on how long any one move may take, however far it goes. */
const MAX_SLIDE_MS = 720

/**
 * How much ground a move is allowed to show.
 *
 * Jumping forty cards is ~15,000px; covering that in any watchable time means
 * thousands of pixels a frame, which is not motion the eye can follow — it is a
 * smear. Past this the strip cuts the excess and plays only the final stretch,
 * so a long jump arrives the same readable way a short one does.
 */
const MAX_TRAVEL_CARDS = 5

/** One wheel notch — CEF reports exactly 120 per detent. Anything lower makes
    detent remainders add up to phantom extra steps on a fast spin. */
const WHEEL_NOTCH = 120

/** A wheel pause longer than this starts a fresh gesture. */
const WHEEL_GESTURE_GAP_MS = 250

/** Gathers pace and settles — right for a card opening at the end of it. */
const easeInOut = t => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2)

/** Leaves immediately and eases in — right for a step that just has to be there. */
const easeOut = t => 1 - Math.pow(1 - t, 3)

/**
 * `createCardOnly` is true when there are no saves at all. The create card is
 * then the whole strip and CSS centres it, so the track stays where it is.
 */
export function useProfileStrip({ cards, createCardOnly, stripRef, trackRef, probeHero, probeSmall }) {
  /**
   * Which card the strip is parked on. -1 is the create card, which sits ahead of
   * the saves and centres like the rest but never expands. Starts on the first
   * save — the one played last, under the default sort.
   */
  const focusedIndex = ref(0)

  /**
   * Which card is actually drawn large, as opposed to merely selected.
   *
   * While you are still scrolling nothing expands — every card stays its normal
   * size and the selection is just highlighted, so the strip does not heave about
   * under a moving cursor. It only opens once you have stopped on one. Null means
   * nothing is expanded yet.
   */
  const expandedIndex = ref(0)

  /** The one whose panel is actually on screen. */
  const expandedProfile = computed(() =>
    expandedIndex.value == null ? null : cards.value[expandedIndex.value] || null
  )

  let expandTimer = null

  /**
   * Strip geometry, measured once and cached. Per-step remeasurement was a
   * querySelectorAll over every card plus several getComputedStyle calls, and
   * none of these numbers change outside a resize.
   *
   * The probes exist because the real cards animate: a width read mid-growth is
   * neither the old size nor the new one. The probes carry the same CSS and
   * never animate, so they are always truthful.
   */
  const geom = { small: 0, hero: 0, gap: 0, padLeft: 0, stripWidth: 0 }

  function measureStrip() {
    if (!trackRef.value || !stripRef.value) return
    const style = getComputedStyle(trackRef.value)
    geom.gap = parseFloat(style.columnGap || style.gap) || 0
    geom.padLeft = parseFloat(style.paddingLeft) || 0
    geom.small = probeSmall.value?.offsetWidth || 0
    geom.hero = probeHero.value?.offsetWidth || geom.small
    geom.stripWidth = stripRef.value.clientWidth
  }

  /**
   * How far the track has to be pulled left for the given card to sit in the
   * middle of the window. Keyed on what is expanded, not what is selected —
   * while browsing every card is the same width and the centring has to agree.
   */
  function offsetForCard(index) {
    if (createCardOnly?.value) return 0
    if (!geom.small) measureStrip()
    const { small, hero, gap, padLeft, stripWidth } = geom
    if (!small) return 0

    // DOM position p holds profile p - 1, so position 0 is the create card at
    // index -1 — which expands like any other card when it is the selection.
    const heroPos = expandedIndex.value == null ? -1 : expandedIndex.value + 1
    const pos = index + 1
    let left = padLeft + pos * (small + gap)
    if (heroPos >= 0 && heroPos < pos) left += hero - small

    const width = pos === heroPos ? hero : small
    return left + width / 2 - stripWidth / 2
  }

  /** One card plus the gap after it — the strip's natural unit of distance. */
  function cardStep() {
    return geom.small ? geom.small + geom.gap : 0
  }

  /** Longer for longer moves, but sub-linear so a big jump is not a slow crawl. */
  function slideDuration(from, to, base) {
    const step = cardStep()
    if (!step) return base
    const cardCount = Math.abs(to - from) / step
    return Math.min(MAX_SLIDE_MS, Math.round(base * Math.sqrt(Math.max(1, cardCount))))
  }

  /**
   * True while the strip is moving. Cards slide under a stationary pointer, which
   * fires mouseover on whatever passes beneath it — so hover is ignored until this
   * clears, otherwise a card lights up mid-slide purely because it went past the
   * cursor.
   */
  const sliding = ref(false)

  let scrollFrame = 0

  /** Bumped per animation; a loop whose token is stale stops writing. */
  let scrollGeneration = 0

  /** Authoritative: what we last wrote, never re-read from the DOM. */
  let trackOffset = 0

  function applyOffset(value) {
    trackOffset = value
    if (trackRef.value) trackRef.value.style.transform = `translate3d(${-value}px, 0, 0)`
  }

  /**
   * Hand-rolled rather than a native smooth scroll, whose duration is fixed by the
   * browser and slower than this wants to feel. Composited, so it does not fight
   * the card growth happening alongside it.
   */
  function animateTo(target, duration = SLIDE_MS, ease = easeInOut) {
    // cancelAnimationFrame alone was not enough: a loop that had already been
    // handed the frame would reschedule itself *after* the new animation stored
    // its id, so the cancel killed the new one and left the old running. Two
    // loops then wrote competing positions on alternate frames, which is the
    // lurching seen while stepping quickly.
    const generation = ++scrollGeneration
    cancelAnimationFrame(scrollFrame)

    let start = trackOffset
    const to = Math.max(0, target)

    // Skip the part of a long move that would only ever be a blur.
    const maxTravel = MAX_TRAVEL_CARDS * cardStep()
    if (duration && maxTravel && Math.abs(to - start) > maxTravel) {
      start = to - Math.sign(to - start) * maxTravel
      applyOffset(start)
    }

    if (!duration || Math.abs(to - start) < 1) {
      applyOffset(to)
      sliding.value = false
      return
    }

    sliding.value = true

    // Timed off the frame clock alone. requestAnimationFrame's timestamp and
    // performance.now() do not share a time origin in this browser — mixing them
    // gave elapsed times of minus several seconds, so the easing curve ran far
    // outside 0..1 and threw the track hundreds of thousands of pixels away
    // before snapping back. That was the flash.
    let startedAt = null
    const step = now => {
      if (generation !== scrollGeneration) return
      if (startedAt === null) startedAt = now

      const t = Math.min(1, Math.max(0, (now - startedAt) / duration))
      applyOffset(start + (to - start) * ease(t))

      if (t < 1) {
        scrollFrame = requestAnimationFrame(step)
      } else {
        applyOffset(to)
        sliding.value = false
      }
    }
    scrollFrame = requestAnimationFrame(step)
  }

  /** Re-centres on the expanded layout once a card has opened. */
  function scheduleExpand() {
    clearTimeout(expandTimer)
    expandTimer = setTimeout(() => {
      expandedIndex.value = focusedIndex.value
      nextTick(() => {
        const target = offsetForCard(focusedIndex.value)
        animateTo(target, slideDuration(trackOffset, target, SLIDE_MS))
      })
    }, EXPAND_DELAY_MS)
  }

  /**
   * `immediate` opens the card straight away — clicking one is a decision, so it
   * should not be made to wait out the settle delay that scrolling needs.
   */
  function focusCard(index, { animate = true, immediate = false } = {}) {
    const max = cards.value.length - 1
    const next = Math.max(-1, Math.min(max, index))
    focusedIndex.value = next

    if (immediate) {
      clearTimeout(expandTimer)
      expandedIndex.value = next
    } else {
      expandedIndex.value = null
      scheduleExpand()
    }

    nextTick(() => {
      if (!animate) return animateTo(offsetForCard(next), 0)
      // Browsing wants to be there now; opening wants to feel like a movement.
      const target = offsetForCard(next)
      const base = immediate ? SLIDE_MS : BROWSE_SLIDE_MS
      const ease = immediate ? easeInOut : easeOut
      animateTo(target, slideDuration(trackOffset, target, base), ease)
    })
  }

  /**
   * One notch moves one card. A trackpad or a free-spinning wheel fires many
   * events per gesture, so a step has to settle before the next one is taken —
   * without this a single flick runs the length of the list.
   */
  let wheelAccum = 0
  let lastWheelTs = 0
  let wheelDir = 0

  /**
   * One card per notch, at any speed.
   *
   * Deltas accumulate, so three notches are three cards whether they arrive in
   * 90ms or 3 seconds. A rule that counted one card per quiet-separated gesture
   * made faster spins move less, because a continuous spin never ends a gesture.
   * The slide re-targets as each card lands, so a quick spin reads as the strip
   * flowing card by card.
   */
  function onWheel(evt) {
    const delta = evt.deltaY || evt.deltaX
    if (!delta) return
    // Lists that genuinely scroll keep their wheel; everywhere else browses.
    // (Only these two live inside the container — the menus and the migration
    // modal teleport to body, and the setup screens stop wheel at their root.)
    if (evt.target.closest?.(".pc-saves-list, .sandbox-advanced-body")) return
    evt.preventDefault()

    // A pause or a direction change starts a fresh gesture; leftovers and debt
    // from the old one must not leak into it.
    const fresh = evt.timeStamp - lastWheelTs > WHEEL_GESTURE_GAP_MS || Math.sign(delta) !== wheelDir
    lastWheelTs = evt.timeStamp
    if (fresh) {
      wheelAccum = 0
      wheelDir = Math.sign(delta)
    }
    wheelAccum += delta

    let steps = Math.trunc(wheelAccum / WHEEL_NOTCH)
    // Deliberate movement always answers: a gesture's first event steps even when
    // its delta is under a notch (gentle trackpads, high-resolution wheels). The
    // shortfall stays in the accumulator as debt, so total travel still matches
    // total input and a real 120-per-detent wheel keeps exact notch parity.
    if (fresh && !steps) steps = wheelDir
    if (!steps) return
    wheelAccum -= steps * WHEEL_NOTCH
    focusCard(focusedIndex.value + steps)
  }

  /** Card sizes are in ui-rem, which the breakpoints change — re-measure and re-centre. */
  function onStripResize() {
    measureStrip()
    animateTo(offsetForCard(focusedIndex.value), 0)
  }

  /** A changed result set renumbers everything, so go back to the front of it. */
  watch(cards, (list, old) => {
    // Filling a placeholder changes its content, not its geometry or selection.
    // Restarting focus here would also open a card the player is browsing past.
    if (old?.length === list.length && list.every((profile, index) => profile.id === old[index].id)) return
    nextTick(measureStrip)
    // Toggling police or renaming re-sends the whole list; the player's place in
    // it must survive that. Only fall back to the front when their card is gone.
    const prevId = old?.[focusedIndex.value]?.id
    const kept = prevId ? list.findIndex(profile => profile.id === prevId) : -1
    focusCard(kept >= 0 ? kept : list.length ? 0 : -1, { animate: false, immediate: true })
  })

  /**
   * Entering or leaving the lone-card layout swaps the track's padding, even when
   * the result set stays the same (a search that matches nothing while the saves
   * underneath it come or go). Re-measure once the new class is on and snap there.
   */
  if (createCardOnly) watch(createCardOnly, () => nextTick(onStripResize))

  /** Cancels the pending open and the slide in flight; the view calls it on unmount. */
  function dispose() {
    cancelAnimationFrame(scrollFrame)
    clearTimeout(expandTimer)
  }

  return {
    focusedIndex,
    expandedIndex,
    expandedProfile,
    sliding,
    focusCard,
    onWheel,
    onStripResize,
    dispose,
  }
}
