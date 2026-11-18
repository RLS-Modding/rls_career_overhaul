<!-- Owns the Overhaul Event display: a short toast stack and the event card. overhaul/lib/ui/eventDisplay.lua publishes both;
     any event owner can feed them. The card opens with its status sentence in the status colour, then the title or
     class, then labelled facts. Every field is optional and lays out only when present. -->
<template>
  <div v-if="state.visible" class="ohd-stack" :class="`dock-${dock}`" role="status" aria-live="polite">
    <TransitionGroup name="ohd-toast" tag="div" class="ohd-toasts">
      <div v-for="toast in toasts" :key="toast.id" class="ohd-toast" :class="toast.kind || 'info'">{{ toast.text }}</div>
    </TransitionGroup>
    <Transition name="ohd">
      <aside v-if="display" class="ohd" :class="[`tone-${display.tone || 'idle'}`, {compact: display.compact, 'one-row': display.oneRow, 'has-slip': !!display.timeslip}]">
        <!-- Status line: the instruction in its status colour, and the wait as a time when the card has one. -->
        <div v-if="banner" class="ohd-banner" :class="banner.kind"><template v-if="timedWait"><span class="ohd-banner-text">{{ timedWait.label }}</span><span class="ohd-banner-time">{{ duration(timedWait.seconds) }}</span></template><span v-else class="ohd-banner-text">{{ banner.text }}</span></div>
        <header v-if="hasHeader" class="ohd-header">
          <div class="ohd-header-main">
            <div v-if="display.title" class="ohd-title">{{ display.title }}</div>
            <div v-if="display.tag || display.phase" class="ohd-route">
              <span v-if="display.tag" class="ohd-tag">{{ display.tag }}</span>
              <span v-if="display.phase">{{ display.phase }}</span>
            </div>
          </div>
          <div v-if="display.countdown" class="ohd-live">
            <span v-if="display.countdown.label" class="ohd-live-label">{{ display.countdown.label }}</span>
            <span class="ohd-live-primary">{{ countdownText }}</span>
          </div>
          <div v-else-if="display.status && !display.compact && display.status !== banner?.text" class="ohd-live"><span class="ohd-live-status">{{ display.status }}</span></div>
        </header>
        <p v-if="display.result" class="ohd-result"><strong>{{ display.result.text }}</strong><span :class="display.result.reward ? 'money' : 'zero'">{{ money(display.result.reward) }}</span></p>
        <div v-if="display.matchups?.length || display.meta?.length" class="ohd-summary">
          <div v-for="(block, index) in display.matchups || []" :key="`${block.label}-${index}`" class="ohd-row ohd-matchup" :class="{ lead: index === 0 }">
            <span class="ohd-k">{{ block.label }}</span>
            <span class="ohd-v"><template v-for="(name, slot) in block.names" :key="slot"><span v-if="slot" class="ohd-vs">vs</span>{{ name }}</template></span>
          </div>
          <div v-if="display.meta?.length" class="ohd-pairs">
            <div v-for="item in display.meta" :key="`${item.label}-${item.value}`" class="ohd-pair" :class="{ wide: String(item.value).length > WIDE, accent: item.tone === 'accent' }">
              <span v-if="item.label" class="ohd-k">{{ item.label }}</span>
              <span class="ohd-v">{{ item.value }}</span>
            </div>
          </div>
        </div>
        <section v-if="display.timeslip" class="ohd-slip" aria-label="Drag times">
          <!-- Where and how the pass was run: values that explain themselves, on one quiet line. -->
          <p v-if="slipSetup" class="ohd-slip-info">{{ slipSetup }}</p>
          <!-- The winning lane is marked on its own row; only a graded slip without one needs a line. -->
          <p v-if="display.timeslip.graded && !slipWinner" class="ohd-slip-outcome">No winner</p>
          <div v-for="(lane, index) in display.timeslip.lanes" :key="index" class="ohd-lane" :class="{ player: lane.player }">
            <div class="ohd-lane-heading"><strong>{{ lane.lane }} {{ lane.name }}</strong></div>
            <div v-if="lane.winner || lane.result" class="ohd-lane-result"><span v-if="lane.winner" class="ohd-winner">Winner</span><span v-if="lane.result" class="ohd-foul">{{ lane.result }}</span></div>
            <div class="ohd-times"><span v-for="(timer, timerIndex) in lane.timers" :key="timerIndex"><span class="ohd-time-label">{{ timer.label }}</span> {{ timer.value }}</span></div>
          </div>
        </section>
        <div v-if="display.note" class="ohd-note">{{ display.note }}</div>
      </aside>
    </Transition>
  </div>
</template>

<script setup>
import { computed, onMounted, onUnmounted, ref, watch } from 'vue'
import { useBridge } from '@/bridge'
import { duration, money } from '../../utils/motorsportLabels.js'

const EVENT = 'OverhaulEventDisplay'
// Facts longer than this take a full row instead of sharing one, so names are not cut off.
const WIDE = 9
// Semantic kinds come from Lua; card phase must never decide a hold's tone.
const BANNER_KIND = { wait: 'info', act: 'warn', go: 'good', blocked: 'bad', done: 'good' }
const events = useBridge().events
const state = ref({ visible: false })
const display = computed(() => state.value.visible ? state.value.display || null : null)
const dock = computed(() => display.value?.dock || state.value.dock || 'left')
// Lua expires toasts too; the UI also drops each one after its own seconds, so a stalled update cannot leave one behind.
const dismissed = ref(new Set())
const toasts = computed(() => (state.value.visible ? state.value.toasts || [] : []).filter(toast => !dismissed.value.has(toastKey(toast))))
const banner = computed(() => {
  const view = display.value
  if (view?.hold) return { text: view.hold, kind: BANNER_KIND[view.holdKind] || 'bad' }
  if (view?.call) return { text: view.call, kind: BANNER_KIND[view.callKind] || 'info' }
  return null
})
// A timed one-row wait arrives as a label and seconds; the strip shows the time as a value.
const timedWait = computed(() => {
  const wait = display.value?.oneRow && !display.value.hold ? display.value.wait : null
  return wait?.label && Number.isFinite(wait.seconds) ? wait : null
})
// The header holds the title, the class and round, and a countdown or status; with none of them it is not drawn.
const hasHeader = computed(() => {
  const view = display.value
  if (!view || view.oneRow) return false
  const status = view.status && !view.compact && view.status !== banner.value?.text
  return !!(view.title || view.tag || view.phase || view.countdown || status)
})
const countdownText = computed(() => {
  const countdown = display.value?.countdown
  if (!countdown) return ''
  if (!Number.isFinite(countdown.seconds)) return countdown.text || ''
  return duration(countdown.seconds)
})
const slipWinner = computed(() => display.value?.timeslip?.lanes?.find(lane => lane.winner))
const slipSetup = computed(() => {
  const slip = display.value?.timeslip
  return slip ? [slip.strip, slip.tree, slip.distance, slip.raceType].filter(Boolean).join(', ') : ''
})
function receive(data) {
  data = Array.isArray(data) ? data.find(item => item && typeof item === 'object') : data
  if (data && typeof data === 'object') state.value = data
}
const timers = new Map()
// One removed stack (Lua's MAX_TOASTS) guards late replays without session history.
// An identical ID/content after Lua reload is indistinguishable until this guard
// evicts it; distinguishing that case needs a publisher generation token.
const REPLAY_TOAST_LIMIT = 3
const DEFAULT_TOAST_SECONDS = 8
let publishedToastKeys = new Set()
function toastKey(toast) {
  // Lua restarts IDs on reload; different content must still get its own lifetime.
  return JSON.stringify([toast.id, toast.text, toast.kind || 'info', toast.seconds || DEFAULT_TOAST_SECONDS])
}
function pruneDismissed() {
  let replayCount = 0
  dismissed.value = new Set([...dismissed.value].reverse().filter(key =>
    publishedToastKeys.has(key) || replayCount++ < REPLAY_TOAST_LIMIT).reverse())
}
function scheduleDismissals(list) {
  publishedToastKeys = new Set((list || []).map(toastKey))
  for (const [key, timer] of timers) {
    if (publishedToastKeys.has(key)) continue
    clearTimeout(timer)
    timers.delete(key)
  }
  pruneDismissed()
  for (const toast of list || []) {
    const key = toastKey(toast)
    if (timers.has(key) || dismissed.value.has(key)) continue
    const timer = setTimeout(() => {
      if (timers.get(key) !== timer) return
      timers.delete(key)
      dismissed.value = new Set([...dismissed.value, key])
      pruneDismissed()
    }, (toast.seconds || DEFAULT_TOAST_SECONDS) * 1000)
    timers.set(key, timer)
  }
}
onMounted(() => {
  events.on(EVENT, receive)
  watch(() => state.value.toasts, scheduleDismissals, { immediate: true })
})
onUnmounted(() => {
  events.off(EVENT, receive)
  for (const timer of timers.values()) clearTimeout(timer)
  timers.clear()
  publishedToastKeys.clear()
  dismissed.value = new Set()
})
defineExpose({ receive, display, banner, toasts, countdownText, timedWait })
</script>

<style scoped lang="scss">
// The same status colours and timeslip numerals as the Motorsport phone card and overlays (motorsport.scss),
// held here as plain values because this card is shared with other Overhaul events and has no .rls-house root.
.ohd-stack {
  --ohd-ground: rgba(21, 21, 23, 0.88);
  --ohd-panel: rgba(255, 255, 255, 0.06);
  --ohd-line: rgba(255, 255, 255, 0.1);
  --ohd-line-soft: rgba(255, 255, 255, 0.06);
  --ohd-muted: rgba(255, 255, 255, 0.72);
  --ohd-faint: rgba(255, 255, 255, 0.55);
  --ohd-accent: var(--bng-orange-b400, #ff6600);
  --ohd-accent-soft: #ffb27a;
  --ohd-wait: #7fbfff;
  --ohd-wait-ink: #b9dcff;
  --ohd-ok: #4ade80;
  --ohd-ok-ink: #86efac;
  --ohd-stop: #f87171;
  --ohd-bad: #fca5a5;
  --ohd-money: #fde68a;
  --ohd-time-font: "Overpass Mono", var(--fnt-mono, monospace);
  position: fixed; top: 10rem; left: 12px; z-index: 900;
  display: flex; flex-direction: column; gap: 8px;
  width: 340px; max-width: calc(100vw - 24px);
  font-family: "Overpass", var(--fnt-defs, sans-serif); color: #fff; line-height: 1.35;
  pointer-events: none;
}
.ohd-stack.dock-right { left: auto; right: 2rem; top: 6rem; }
// Tone: info is wait (blue), warn is the player's move (orange), good is go or done (green), bad is blocked (red).
.ohd-banner, .ohd-toast { --tone: var(--ohd-wait); --tone-ink: var(--ohd-wait-ink); }
.ohd-banner.warn, .ohd-toast.warn { --tone: var(--ohd-accent); --tone-ink: var(--ohd-accent-soft); }
.ohd-banner.good, .ohd-toast.good { --tone: var(--ohd-ok); --tone-ink: var(--ohd-ok-ink); }
.ohd-banner.bad, .ohd-toast.bad { --tone: var(--ohd-stop); --tone-ink: var(--ohd-bad); }
.ohd-toasts { display: flex; flex-direction: column; gap: 6px; }
.ohd-toasts:empty { display: none; }
// A toast is one sentence on a faint ground of its colour. An info toast has nothing to act on, so it stays neutral.
.ohd-toast {
  padding: 9px 12px 7px; border-radius: 8px; font-size: 14px; font-weight: 600; color: var(--tone-ink);
  background: linear-gradient(color-mix(in srgb, var(--tone) 12%, transparent), color-mix(in srgb, var(--tone) 12%, transparent)), var(--ohd-ground);
}
.ohd-toast.info { color: #fff; background: var(--ohd-ground); }
.ohd {
  box-sizing: border-box; width: 100%; border-radius: 8px; background: var(--ohd-ground);
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06); overflow: hidden;
}
// Status line: the sentence in the status colour, and the time on the right when the wait is timed.
.ohd-banner {
  display: flex; align-items: baseline; gap: 10px; margin: 0; padding: 10px 12px 0;
  font-size: 16px; font-weight: 800; line-height: 1.2; color: var(--tone);
}
.ohd-banner:last-child { padding-bottom: 8px; }
.ohd-banner-text { flex: 1 1 auto; min-width: 0; }
.ohd-banner-time { flex: 0 0 auto; font-family: var(--ohd-time-font); font-size: 16px; font-weight: 700; letter-spacing: -.03em; word-spacing: -.22em; color: #fff; font-variant-numeric: tabular-nums; }
.ohd-header { display: flex; flex-direction: column; align-items: stretch; gap: 7px; padding: 10px 12px 9px; }
.ohd-header:not(:last-child) { border-bottom: 1px solid var(--ohd-line); }
.ohd-header-main { flex: 1; min-width: 0; display: grid; gap: 4px; }
.ohd-header-main:empty { display: none; }
.ohd-title { font-size: 17px; font-weight: 800; line-height: 1.2; }
// Under a status line the status is the headline, so the title steps back to a quiet line.
.ohd-banner + .ohd-header { padding-top: 5px; }
.ohd-banner + .ohd-header .ohd-title { font-size: 13px; font-weight: 600; color: var(--ohd-muted); }
.ohd-route { display: flex; flex-wrap: wrap; align-items: baseline; gap: 4px 7px; font-size: 13px; font-weight: 600; color: var(--ohd-muted); }
// The class is the one tag on the card, so it reads first under the title.
.ohd-tag { padding: 2px 7px 0; border-radius: 4px; background: rgba(255, 255, 255, .1); color: #fff; font-weight: 700; }
// A countdown or status sits under the title as a labelled value, so a long event name never fights it for width.
.ohd-live { flex-shrink: 0; display: grid; justify-items: start; gap: 1px; white-space: nowrap; }
.ohd-live-label { font-size: 12px; font-weight: 600; color: var(--ohd-faint); }
.ohd-live-primary { font-family: var(--ohd-time-font); font-size: 18px; font-weight: 700; letter-spacing: -.03em; word-spacing: -.22em; color: #fff; font-variant-numeric: tabular-nums; line-height: 1.15; }
.ohd-live-status { font-size: 13px; font-weight: 600; color: var(--ohd-muted); }
.tone-racing .ohd-live-status { color: var(--ohd-ok); }
// Result: placing on the left, payout in gold as the biggest number on the card.
.ohd-result { display: flex; align-items: baseline; justify-content: space-between; gap: 10px; margin: 0; padding: 10px 12px 2px; font-size: 16px; }
.ohd-result .money { font-size: 20px; font-weight: 800; color: var(--ohd-money); font-variant-numeric: tabular-nums; }
.ohd-result .zero { color: var(--ohd-faint); font-weight: 700; }
.ohd-summary { padding: 9px 12px 10px; font-size: 14px; }
.ohd-row { display: flex; justify-content: space-between; align-items: baseline; gap: 10px; padding: 2px 0 4px; }
.ohd-k { flex-shrink: 0; font-size: 12px; font-weight: 600; color: var(--ohd-faint); }
.ohd-v { min-width: 0; font-weight: 700; color: #fff; text-align: right; font-variant-numeric: tabular-nums; }
.ohd-matchup:not(.lead) .ohd-v { font-weight: 600; color: var(--ohd-muted); }
.ohd-vs { margin: 0 .35em; font-size: 12px; font-weight: 600; color: var(--ohd-faint); }
// Facts are labelled values, the same pattern as the phone card: a quiet label over each value.
.ohd-pairs { display: flex; flex-wrap: wrap; gap: 8px 16px; }
.ohd-pairs:not(:first-child) { margin-top: 5px; padding-top: 9px; border-top: 1px solid var(--ohd-line-soft); }
.ohd-pair { display: grid; align-content: start; gap: 1px; min-width: 0; }
// A long leading value (the car name) takes its own row, so the short facts stay together on the next one.
.ohd-pair.wide:first-child { flex: 1 1 100%; }
.ohd-pair .ohd-v { font-size: 15px; text-align: left; }
// Your own group (or a later group or round than the one on track) is the fact to watch.
.ohd-pair.accent .ohd-k { color: var(--ohd-accent-soft); }
.ohd-pair.accent .ohd-v { color: var(--ohd-accent); }
.ohd-note { padding: 0 12px 10px; font-size: 13px; font-weight: 600; color: var(--ohd-faint); }
.ohd-header + .ohd-note, .ohd-banner + .ohd-note { padding-top: 8px; }
// Timeslip: the slip is the card. Its lanes carry the names and the car, so the facts step aside and the card
// stays clear of the minimap; each timer is a labelled value.
.has-slip .ohd-summary { display: none; }
.ohd-slip { padding: 8px 12px 9px; border-top: 1px solid var(--ohd-line); font-size: 12px; }
.ohd-slip-info { margin: 0 0 5px; color: var(--ohd-muted); }
.ohd-slip-outcome { margin: 5px 0 4px; font-size: 14px; font-weight: 800; color: var(--ohd-muted); }
.ohd-lane { padding: 5px 7px 6px; border-radius: 5px; }
.ohd-lane + .ohd-lane { margin-top: 2px; }
.ohd-lane.player { background: color-mix(in srgb, var(--ohd-accent) 16%, transparent); }
.ohd-lane-heading { font-size: 13px; overflow-wrap: anywhere; }
.ohd-lane-result { display: flex; flex-wrap: wrap; gap: 4px 8px; overflow-wrap: anywhere; font-size: 13px; }
.ohd-winner { color: var(--ohd-ok-ink); font-weight: 800; }
.ohd-foul { color: var(--ohd-bad); font-weight: 700; }
.ohd-times { display: flex; flex-wrap: wrap; gap: 3px 8px; margin-top: 3px; }
.ohd-times > span { display: grid; gap: 0; font-family: var(--ohd-time-font); font-size: 12px; font-weight: 700; letter-spacing: -.03em; word-spacing: -.22em; font-variant-numeric: tabular-nums; }
.ohd-time-label { font-family: "Overpass", var(--fnt-defs, sans-serif); font-size: 12px; font-weight: 600; letter-spacing: 0; word-spacing: 0; color: var(--ohd-faint); }
.ohd-enter-active, .ohd-leave-active, .ohd-toast-enter-active, .ohd-toast-leave-active { transition: opacity .18s ease, transform .18s ease; }
.ohd-enter-from, .ohd-leave-to, .ohd-toast-enter-from, .ohd-toast-leave-to { opacity: 0; transform: translateY(-.4em); }
@media (prefers-reduced-motion: reduce) {
  .ohd-enter-active, .ohd-leave-active, .ohd-toast-enter-active, .ohd-toast-leave-active { transition: none; }
}
</style>
