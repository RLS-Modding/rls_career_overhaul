<!-- Owns bracket rendering and zoom. PhoneMotorsportEvents supplies immutable match and entrant snapshots. -->
<template>
  <div class="bracket-board" :class="{ compact }" v-bng-on-ui-nav:details="focusZoom">
    <p v-if="playerMessage" class="player-message ms-status ms-tone-blocked">{{ playerMessage }}</p>
    <p v-if="!layout.nodes.length" class="empty ms-caption">{{ emptyMessage }}</p>
    <template v-else>
    <div v-if="compact" class="rounds">
      <div class="list-summary">
        <p v-if="layout.champion?.winnerId" class="list-champion"><span class="ms-label">Champion</span><strong>{{ championName }}</strong></p>
        <p v-else-if="bracket.complete" class="ms-caption">{{ labels.noWinner }}</p>
        <span v-if="allSimulated || playerNode" class="list-end"><span v-if="allSimulated" class="simulated">{{ labels.simulated }}</span><HouseButton v-if="playerNode" compact @click="jumpToPlayer">Jump to my heat</HouseButton></span>
      </div>
      <section v-for="round in asArray(bracket.rounds)" :key="round.number" class="round">
        <h4 class="ms-label">{{ roundLabel(round) }}</h4>
        <article v-for="(match, matchIndex) in asArray(round.matches)" :key="match.id" :ref="el => setMatchElement(match.id, el)" class="sheet lines matchup" :class="{ complete: match.winnerId || match.complete, racing: isCurrent(match) }" tabindex="0" bng-nav-item role="region" data-phone-scroll-target :aria-label="heatRegionLabel(match, matchIndex, round)">
          <header v-if="heatCaption(match, matchIndex, round) || statusNote(match, round)" class="matchup-header ms-meta"><span>{{ heatCaption(match, matchIndex, round) }}</span><span v-if="statusNote(match, round)" class="match-status">{{ statusNote(match, round) }}</span></header>
          <div v-for="(id, lane) in [match.a, match.b]" :key="lane" class="line" :class="{ winner: id && match.winnerId === id, 'ms-player-row': entrantsById[id]?.player }">
            <span class="who ms-caption"><strong :title="driver(id, match.bye)">{{ seededName(id, match.bye) }}</strong><span v-if="needsYouChip(entrantsById[id])" class="ms-you">You</span></span>
            <span class="value"><strong class="ms-time">{{ resultTime(match, id) }}<span v-if="id && match.winnerId === id" class="win-mark" aria-label="Winner"> ✓</span></strong><small role="note" v-if="outcome(match, id)" :title="outcomeDescription(match, id)" :aria-label="outcomeDescription(match, id)" class="ms-meta ms-bad">{{ outcome(match, id) }}</small></span>
          </div>
        </article>
      </section>
    </div>
    <template v-else>
    <div class="toolbar">
      <span v-if="allSimulated" class="simulated">{{ labels.simulated }}</span>
      <span class="muted">{{ controls.isControllerUsed ? 'Right stick pans.' : 'Drag to pan, scroll to zoom.' }}</span>
      <div class="zoom-controls">
        <label class="zoom-slider"><span><BngBinding ui-event="details" controller aria-hidden="true" /> Zoom</span><HouseSlider ref="zoomSlider" v-model="zoom" :min="minimumZoom" :max="1.4" :step=".01" :debounce="0" /></label>
        <output class="ms-time" aria-label="Zoom percentage">{{ Math.round(zoom * 100) }}%</output>
        <HouseButton compact @click="fit">Fit</HouseButton>
        <HouseButton v-if="playerNode" compact @click="jumpToPlayer">Jump to my heat</HouseButton>
      </div>
    </div>
    <div ref="viewport" class="bracket-viewport scroll" :class="{ dragging }" v-bng-ui-nav-scroll @pointerdown="startPan">
      <div class="bracket-focus" tabindex="0" bng-nav-item role="region" data-phone-scroll-target aria-label="Elimination tournament bracket; use the right stick to explore all rounds">
      <div class="scaled-space" :style="{ width: `${layout.width * zoom}em`, height: `${layout.height * zoom}em` }">
        <div class="bracket-canvas" :style="{ width: `${layout.width}em`, height: `${layout.height}em`, transform: `scale(${zoom})` }">
          <svg class="connections" :viewBox="`0 0 ${layout.width} ${layout.height}`" preserveAspectRatio="none" aria-hidden="true"><path v-for="edge in layout.edges" :key="edge.id" :d="edge.path" :class="{ decided: edge.decided, consolation: edge.consolation }" /></svg>
          <h4 v-for="heading in layout.headings" :key="heading.id" class="round-heading" :style="{ left: `${heading.x}em`, width: `${cardWidth}em` }"><span>{{ heading.label }}</span></h4>
          <article v-for="node in layout.nodes" :key="node.match.id" class="match-card" :class="{ complete: node.match.winnerId || node.match.complete, player: isPlayerMatch(node.match), current: isCurrent(node.match), bare: !node.caption && !statusNote(node.match, node) }" :style="{ left: `${node.x}em`, top: `${node.y}em`, width: `${cardWidth}em`, height: `${cardHeight}em` }" :aria-label="`${node.label}, ${status(node.match)}: ${driver(node.match.a)} versus ${driver(node.match.b, node.match.bye)}`">
            <header v-if="node.caption || statusNote(node.match, node)"><span>{{ node.caption }}</span><span v-if="statusNote(node.match, node)" class="match-status">{{ statusNote(node.match, node) }}</span></header>
            <div v-for="(id, lane) in [node.match.a, node.match.b]" :key="lane" class="racer" :class="{ winner: id && node.match.winnerId === id, 'ms-player-row': entrantsById[id]?.player }">
              <span class="seed">{{ entrantsById[id]?.seed || '—' }}</span><span class="driver"><strong :title="driver(id, node.match.bye)">{{ driver(id, node.match.bye) }}</strong><small v-if="id" :title="entrantsById[id]?.model">{{ entrantsById[id]?.model }}</small><span v-if="needsYouChip(entrantsById[id])" class="ms-you">You</span></span><span class="time">{{ resultTime(node.match, id) }}<span v-if="id && node.match.winnerId === id" class="win-mark" aria-label="Winner"> ✓</span><small role="note" v-if="outcome(node.match, id)" :title="outcomeDescription(node.match, id)" :aria-label="outcomeDescription(node.match, id)" class="ms-bad">{{ outcome(node.match, id) }}</small></span>
            </div>
          </article>
          <section v-if="layout.champion" class="champion-card" :class="{ decided: !!layout.champion.winnerId }" :style="{ left: `${layout.champion.x}em`, top: `${layout.champion.y}em`, width: `${cardWidth}em` }"><span>Champion</span><strong>{{ championName }}</strong></section>
        </div>
      </div>
      </div>
    </div>
    </template>
    </template>
  </div>
</template>

<script setup>
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { vBngOnUiNav, vBngUiNavScroll } from '@/common/directives'
import { BngBinding } from '@/common/components/base'
import { HouseButton, HouseSlider } from '../house/index.js'
import useControls from '@/services/controls'
import { dragResultReason, labels, matchStatus, roundName } from '../../utils/motorsportLabels.js'

const props = defineProps({ bracket: { type: Object, required: true }, entrants: { type: Array, default: () => [] }, racingIds: { type: Array, default: () => [] }, compact: Boolean, playerStatus: Object, classId: String })
const controls = useControls()
const asArray = value => Array.isArray(value) ? value : []
function seededName(id, bye = false) { const e = entrantsById.value[id]; return e ? `${e.seed || '—'}. ${driver(id)}` : driver(id, bye) }
function matchResult(match, id) { return asArray(match.results).find(row => row.entrantId === id) }
function outcome(match, id) {
  const result = matchResult(match, id)
  if (!result) return ''
  if (result.walkover || result.valid === true) return ''
  const breakout = result.reason?.match(/^Breakout: ([\d.]+) seconds is faster than the ([\d.]+) second index\.$/)
  if (breakout) {
    const margin = Number(breakout[2]) - Number(breakout[1])
    return Number.isFinite(margin) && margin >= 0 ? `Breakout ${margin < .0005 ? '<0.001' : margin.toFixed(3)}\u00a0s` : 'Breakout'
  }
  if (result.reason?.startsWith('Breakout')) return result.reason
  if (result.breakout) return 'Breakout'
  const reasons = {jumping: 'Red light', outOfLane: 'Boundary violation', crashed: 'Crash', stationaryTooLong: 'Did not finish', reactionTime: 'Invalid reaction'}
  return reasons[String(result.reason || '').replace('missions.dragRace.gameplay.disqualified.', '')] || dragResultReason(result.reason) || 'Disqualified'
}
const mainMatches = round => asArray(round.matches).filter(match => match.kind !== 'thirdPlace')
const roundLabel = round => roundName({ ...round, fullMatchCount: round.fullMatchCount || mainMatches(round).length })
const matchLabel = (match, index, round) => match.kind === 'thirdPlace' ? 'Third place' : match.kind === 'championship' || mainMatches(round).length === 1 ? labels.final : `Heat ${index + 1}`
// The final is one heat under a "Final" heading, so its card does not print the word a second time.
const heatCaption = (match, index, round) => matchLabel(match, index, round) === roundLabel(round) ? '' : matchLabel(match, index, round)
function heatRegionLabel(match, index, round) {
  const title = roundLabel(round), heat = matchLabel(match, index, round)
  return title === heat ? title : `${title}, ${heat}`
}
const outcomeDescription = (match, id) => matchResult(match, id)?.reason?.startsWith('Breakout:') ? matchResult(match, id).reason : outcome(match, id)
const status = match => matchStatus(match, isCurrent(match))
// A heat prints its state only when the card does not already show it: an empty heat is plainly upcoming, a decided
// one shows its winner, a bye shows "Bye" in the empty lane, a final without a winner is said by the champion line,
// and a fully simulated bracket says so once above the heats (beside the champion in the list, in the toolbar on the board).
const decided = match => !!(match.winnerId || match.complete)
const allSimulated = computed(() => {
  const heats = asArray(props.bracket.rounds).flatMap(round => asArray(round.matches)).filter(match => decided(match) && !match.bye)
  return heats.length > 0 && heats.every(match => match.simulated)
})
const isFinal = (match, group) => match.kind !== 'thirdPlace' && (match.kind === 'championship' || group?.count === 1 || (group?.matches && mainMatches(group).length === 1))
function statusNote(match, group) {
  const state = status(match)
  if ([labels.upcoming, labels.done, labels.bye].includes(state)) return ''
  if (state === labels.simulated && allSimulated.value) return ''
  if (state === labels.noWinner && isFinal(match, group)) return ''
  return state
}
// The player's row is tinted. The chip is for a row that shows a driver name; a row already named "You" does not need it.
const needsYouChip = entrant => !!entrant?.player && String(entrant.name || '').trim().toLowerCase() !== 'you'
const entryStatus = computed(() => asArray(props.playerStatus?.entries).find(entry => props.classId ? entry.classId === props.classId : props.entrants.some(entrant => entrant.player && entrant.id === entry.entrantId)))
const emptyMessage = computed(() => props.bracket.noQualified ? 'Nobody qualified.'
  : props.bracket.complete ? `${labels.noWinner}.` : 'Seeded when this class finishes qualifying.')
const playerMessage = computed(() => {
  const entry = entryStatus.value
  if (!entry) return ''
  if (entry.idOutcome === 'didNotQualify') {
    if (!layout.value.nodes.length) return ''
    // The cut is given beside a time it can be compared with.
    if (!Number.isFinite(entry.bestTime)) return 'You did not qualify for this bracket. No legal qualifying time.'
    return `You did not qualify for this bracket. Best ${entry.bestTime.toFixed(3)} s.${Number.isFinite(entry.cutTime) ? ` Cut ${entry.cutTime.toFixed(3)} s.` : ''}`
  }
  if (entry.idOutcome === 'eliminated') return `${labels.eliminated}${entry.roundName ? ` in the ${entry.roundName.toLowerCase()}` : ''}.`
  if (entry.idOutcome === 'excluded') return `${labels.excluded}.${entry.reason ? ` ${entry.reason}` : ''}`
  return ''
})

const viewport = ref(null), zoomSlider = ref(null), zoom = ref(1)
const minimumZoom = ref(.85)
const dragging = ref(false)
let pan = null
const focusZoom = () => zoomSlider.value?.activateSlider()
const cardWidth = 19, cardHeight = 8.5, pitchX = 20, pitchY = 10, headingHeight = 2.4
const entrantsById = computed(() => Object.fromEntries(props.entrants.map(entrant => [entrant.id, entrant])))
const roundTitle = count => roundName({ fullMatchCount: count })
const layout = computed(() => {
  const saved = asArray(props.bracket.rounds), first = mainMatches(saved[0] || {})
  if (!first.length) return { width: cardWidth, height: 0, nodes: [], edges: [], rounds: [], headings: [] }
  const rounds = [], nodes = [], edges = [], headings = []
  for (let count = first.length, index = 0; count >= 1; count = Math.floor(count / 2), index++) {
    const stored = mainMatches(saved[index] || {})
    const previous = rounds[index - 1]
    const round = { number: saved[index]?.number || index + 1, count, nodes: [] }
    for (let slot = 0; slot < count; slot++) {
      const match = stored[slot] || { id: `pending-r${index + 1}-m${slot + 1}`, a: previous?.nodes[slot * 2]?.match.winnerId, b: previous?.nodes[slot * 2 + 1]?.match.winnerId }
      const y = previous ? (previous.nodes[slot * 2].y + previous.nodes[slot * 2 + 1].y) / 2 : headingHeight + slot * pitchY
      const node = { match, x: index * pitchX, y, count, label: count === 1 ? labels.final : `Heat ${slot + 1}`, caption: count === 1 ? '' : `Heat ${slot + 1}` }
      round.nodes.push(node); nodes.push(node)
    }
    rounds.push(round)
  }
  const depth = rounds.length - 1, centerX = depth * pitchX, width = centerX * 2 + cardWidth
  for (const [index, round] of rounds.entries()) {
    const half = round.count / 2
    for (const [slot, node] of round.nodes.entries()) {
      node.x = round.count === 1 ? centerX : slot < half ? index * pitchX : width - cardWidth - index * pitchX
      node.y = index === 0 ? headingHeight + (round.count === 1 ? 0 : slot % half) * pitchY
        : (rounds[index - 1].nodes[slot * 2].y + rounds[index - 1].nodes[slot * 2 + 1].y) / 2
      if (index > 0) for (const source of rounds[index - 1].nodes.slice(slot * 2, slot * 2 + 2)) edges.push(connection(source, node))
    }
    headings.push({ id: `left-${index}`, x: round.nodes[0].x, label: roundTitle(round.count) })
    if (round.count > 1) headings.push({ id: `right-${index}`, x: round.nodes[round.count - 1].x, label: roundTitle(round.count) })
  }
  const final = rounds[rounds.length - 1].nodes[0]
  const champion = { x: centerX, y: final.y + cardHeight + 1.5, winnerId: props.bracket.winnerId || final.match.winnerId }
  edges.push({ id: 'championship-winner', path: `M ${centerX + cardWidth / 2} ${final.y + cardHeight} V ${champion.y}`, decided: !!champion.winnerId })
  if (props.bracket.thirdPlaceEnabled && first.length >= 2) {
    const semifinal = rounds[rounds.length - 2]
    const stored = saved.flatMap(round => asArray(round.matches)).find(match => match.kind === 'thirdPlace')
    const losers = semifinal.nodes.map(node => {
      const match = node.match, id = match.winnerId && match.a && match.b ? match.winnerId === match.a ? match.b : match.a : undefined
      return asArray(match.results).some(row => row.entrantId === id && row.retired) ? undefined : id
    })
    const match = stored || { id: 'pending-third-place', kind: 'thirdPlace', a: losers[0], b: losers[1] }
    const third = { match, x: centerX, y: champion.y + 6, label: 'Third place', caption: 'Third place' }
    if (stored || losers.some(Boolean) || semifinal.nodes.some(node => !node.match.winnerId && !node.match.complete)) {
      nodes.push(third)
      for (const source of semifinal.nodes) edges.push(connection(source, third, true))
    }
  }
  return { rounds, nodes, edges, headings, champion, width: width + .5, height: Math.max(champion.y + 4, ...nodes.map(node => node.y + cardHeight)) + 1 }
})
function connection(source, target, consolation = false) {
  const direction = target.x > source.x ? 1 : -1
  const startX = source.x + (direction === 1 ? cardWidth : 0), endX = target.x + (direction === 1 ? 0 : cardWidth)
  const startY = source.y + cardHeight / 2, endY = target.y + cardHeight / 2
  const elbow = startX + direction * (pitchX - cardWidth) * (consolation ? .72 : .4)
  return { id: `${source.match.id}-${target.match.id}`, path: `M ${startX} ${startY} H ${elbow} V ${endY} H ${endX}`, decided: !!source.match.winnerId, consolation }
}
const driver = (id, bye = false) => id ? `${entrantsById.value[id]?.number ? `#${entrantsById.value[id].number} ` : ''}${entrantsById.value[id]?.name || 'TBD'}` : bye ? 'Bye' : 'TBD'
const isPlayerMatch = match => entrantsById.value[match.a]?.player || entrantsById.value[match.b]?.player
const isCurrent = match => !match.winnerId && !match.complete && match.a && match.b && props.racingIds.includes(match.a) && props.racingIds.includes(match.b)
function resultTime(match, id) {
  if (!id) return ''
  const result = matchResult(match, id)
  if (result?.walkover) return 'Win'
  if (['Did not stage', 'Did not finish', 'missions.dragRace.gameplay.disqualified.stationaryTooLong'].includes(result?.reason)) return 'DNF'
  return result ? result.valid && Number.isFinite(result.time) ? `${result.time.toFixed(3)} s` : 'DQ' : ''
}
const championName = computed(() => layout.value.champion?.winnerId ? driver(layout.value.champion.winnerId) : props.bracket.complete ? labels.noWinner : 'TBD')
const playerNode = computed(() => [...layout.value.nodes].reverse().find(node => isPlayerMatch(node.match) && !node.match.winnerId && !node.match.complete)
  || [...layout.value.nodes].reverse().find(node => isPlayerMatch(node.match)))
const matchElements = new Map()
function setMatchElement(id, element) { if (element) matchElements.set(id, element); else matchElements.delete(id) }
async function jumpToPlayer() {
  await nextTick()
  if (props.compact) {
    // The expanded board generates future slots before they exist in the phone list.
    const matches = asArray(props.bracket.rounds).flatMap(round => asArray(round.matches)).filter(isPlayerMatch).reverse()
    const match = matches.find(match => !match.winnerId && !match.complete && matchElements.has(match.id))
      || matches.find(match => matchElements.has(match.id))
    const element = matchElements.get(match?.id)
    element?.scrollIntoView({ block: 'center', behavior: 'instant' })
    element?.focus({ preventScroll: true })
  } else if (viewport.value) {
    const node = playerNode.value
    if (!node) return
    const font = parseFloat(getComputedStyle(viewport.value).fontSize)
    viewport.value.scrollLeft = Math.max(0, (node.x + cardWidth / 2) * font * zoom.value - viewport.value.clientWidth / 2)
    viewport.value.scrollTop = Math.max(0, (node.y + cardHeight / 2) * font * zoom.value - viewport.value.clientHeight / 2)
  }
}
async function fit() {
  if (!viewport.value || !layout.value.height) return
  const font = parseFloat(getComputedStyle(viewport.value).fontSize)
  // A full tree can be wider than the screen. Keep a readable scale and pan
  // rather than allowing the zoom control to collapse it into a speck.
  minimumZoom.value = Math.max(.85, Math.min(1, (viewport.value.clientWidth - 40) / (layout.value.width * font), (viewport.value.clientHeight - 40) / (layout.value.height * font)))
  zoom.value = minimumZoom.value
  await jumpToPlayer()
}
function startPan(event) {
  if (event.button !== 0 || event.pointerType !== 'mouse' || event.target.closest('button, a, input, select, textarea, [role="button"]')) return
  event.preventDefault()
  pan = { id: event.pointerId, x: event.clientX, y: event.clientY, left: viewport.value.scrollLeft, top: viewport.value.scrollTop }
}
function movePan(event) {
  if (!pan || event.pointerId !== pan.id) return
  const dx = event.clientX - pan.x, dy = event.clientY - pan.y
  if (!dragging.value && Math.hypot(dx, dy) < 4) return
  dragging.value = true
  viewport.value.scrollLeft = pan.left - dx
  viewport.value.scrollTop = pan.top - dy
}
function endPan(event) {
  if (!pan || event.pointerId !== pan.id) return
  pan = null
  dragging.value = false
}
async function wheelZoom(event) {
  if (!event.deltaY) return
  event.preventDefault()
  const element = viewport.value, canvas = element.querySelector('.bracket-canvas')
  const rect = canvas.getBoundingClientRect(), previous = zoom.value
  const next = Math.max(minimumZoom.value, Math.min(1.4, previous * Math.exp(-event.deltaY * .002)))
  if (next === previous) return
  const x = (event.clientX - rect.left) / previous, y = (event.clientY - rect.top) / previous
  zoom.value = next
  await nextTick()
  if (!viewport.value) return
  const updated = canvas.getBoundingClientRect()
  element.scrollLeft += updated.left + x * next - event.clientX
  element.scrollTop += updated.top + y * next - event.clientY
}
onMounted(async () => {
  if (props.compact) return
  viewport.value?.addEventListener('wheel', wheelZoom, { passive: false })
  window.addEventListener('pointermove', movePan)
  window.addEventListener('pointerup', endPan)
  window.addEventListener('pointercancel', endPan)
  await nextTick()
  await fit()
  await nextTick()
  await fit()
})
watch(() => layout.value.nodes.length > 0, async (hasMatches, hadMatches) => {
  if (!props.compact && hasMatches && !hadMatches) { await nextTick(); viewport.value?.addEventListener('wheel', wheelZoom, { passive: false }); await fit() }
})
onBeforeUnmount(() => {
  viewport.value?.removeEventListener('wheel', wheelZoom)
  window.removeEventListener('pointermove', movePan)
  window.removeEventListener('pointerup', endPan)
  window.removeEventListener('pointercancel', endPan)
})
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;
@use "@/styles/rls_career_overhaul/modules/career/styles/motorsport.scss" as ms;
.bracket-board { min-width: 0; display: grid; gap: var(--space-2); }
.player-message, .empty { margin: 0; }
.player-message { font-size: .92em; font-weight: 700; }
// One line: the hint gives way (it cuts off) before the zoom controls can drop to a second row.
.toolbar, .zoom-controls { display: flex; align-items: center; gap: var(--ms-stack, var(--space-2)); flex-wrap: nowrap; }
.toolbar > .muted { flex: 1 1 0; }
.zoom-controls { flex: 0 0 auto; }
.simulated { flex: 0 0 auto; font-size: .86em; font-weight: 700; line-height: 1.3; color: var(--muted); }
.muted { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--muted); font-size: .86em; line-height: 1.3; }
.zoom-slider { display: flex; align-items: center; gap: .6em; font-size: .86em; font-weight: 700; color: var(--muted); }
.zoom-slider .house-slider { width: 12em; }
.zoom-controls output { min-width: 3em; text-align: right; }
.bracket-viewport { overflow: auto; height: 54vh; min-height: 16em; border-radius: var(--radius-panel); background: var(--photo); padding: var(--ms-pad, var(--inset)); cursor: grab; user-select: none; }
.bracket-viewport.dragging { cursor: grabbing; }
// Controller scrolling starts at the focus target's parent, so keep the target
// inside the scroll area but draw its focus frame on the stationary viewport.
.bracket-focus { height: 100%; }
.bracket-focus.focus-visible { outline: none !important; box-shadow: none !important; }
.bracket-viewport:has(> .bracket-focus.focus-visible) {
  outline: 2px solid var(--phone-focus-color, rgba(255, 138, 61, .9));
  outline-offset: -2px;
  box-shadow: inset 0 0 0 3px rgba(0, 0, 0, .35);
}
.scaled-space { position: relative; margin: 0 auto; }
.bracket-canvas { position: absolute; top: 0; left: 0; transform-origin: top left; }
.connections { position: absolute; inset: 0; width: 100%; height: 100%; pointer-events: none; overflow: visible; }
// Decided paths are white, not orange: orange belongs to the player.
path { fill: none; stroke: rgba(255, 255, 255, .16); stroke-width: .08; }
path.decided { stroke: rgba(255, 255, 255, .55); }
path.consolation { stroke: var(--faint); stroke-dasharray: .25 .2; }
// The heading keeps the canvas font size so its em coordinates match the cards; only the inner span is sized.
.round-heading { position: absolute; top: 0; margin: 0; font-size: 1em; font-weight: 700; color: var(--muted); }
.round-heading span { font-size: .86em; }
// Match cards. A heat's header is its name on the card's own ground, with no band: the player's heat is the tinted
// row (and its name in the player's orange), the heat on track is the word Racing in green and a thin green edge.
.match-card { position: absolute; box-sizing: border-box; background: #1b1b1e; border-radius: var(--radius-tile); box-shadow: 0 0 0 1px var(--line); overflow: hidden; }
.match-card header { display: flex; justify-content: space-between; align-items: center; height: 1.6875em; padding: 0 .75em; color: var(--faint); font-size: .8em; font-weight: 700; }
.match-card.player header { color: var(--accent-soft); }
.match-card.current { box-shadow: 0 0 0 1px color-mix(in srgb, var(--ms-go) 60%, transparent); }
.match-card.current .match-status, .matchup.racing .match-status { color: var(--ms-go); }
.racer { display: flex; align-items: center; gap: .5em; height: 3.33em; padding: 0 .65em; }
.racer + .racer { border-top: 1px solid var(--line); }
.match-card.bare .racer { height: 50%; }
.seed { width: 1.4em; flex-shrink: 0; text-align: center; font-size: .9em; font-weight: 800; color: var(--faint); font-variant-numeric: tabular-nums; }
.driver { flex: 1; min-width: 0; display: grid; grid-template-columns: minmax(0, auto) auto minmax(0, 1fr); align-items: center; column-gap: .4em; }
.driver strong, .driver small { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.driver strong { grid-column: 1; grid-row: 1; font-size: .95em; font-weight: 600; }
.driver small { grid-column: 1 / -1; grid-row: 2; color: var(--faint); font-size: .78em; }
.driver .ms-you { grid-column: 2; grid-row: 1; font-size: .64em; }
.time { font-family: var(--ms-time-font, monospace); font-size: .95em; font-weight: 700; letter-spacing: -.03em; white-space: nowrap; text-align: right; font-variant-numeric: tabular-nums; }
.time small { display: block; max-width: 9em; white-space: normal; font-family: "Overpass", var(--fnt-defs, sans-serif); font-size: .82em; font-weight: 600; letter-spacing: 0; }
// Winners are bold white with a green tick; yellow stays with money. A decided heat dims the car that lost.
.winner strong { font-weight: 800; color: #fff; }
.win-mark { color: var(--ok); font-family: "Overpass", var(--fnt-defs, sans-serif); }
.complete .racer:not(.winner) strong, .complete .racer:not(.winner) .time, .complete .line:not(.winner) .who strong, .complete .line:not(.winner) .ms-time { color: var(--faint); }
.racer.ms-player-row, .line.ms-player-row { background: color-mix(in srgb, var(--accent) 18%, transparent); }
.complete .racer.ms-player-row strong, .complete .line.ms-player-row .who strong { color: #fff; }
// Champion: an empty outline until the final is run, then the gold fill.
.champion-card { position: absolute; box-sizing: border-box; min-height: 4em; padding: .7em; text-align: center; border: 1px dashed rgba(255, 255, 255, .28); border-radius: var(--radius-tile); background: transparent; }
.champion-card span, .champion-card strong { display: block; }
.champion-card span { margin-bottom: .3em; font-size: .78em; font-weight: 600; color: var(--faint); }
.champion-card strong { font-size: .95em; color: var(--muted); }
.champion-card.decided { border: 0; background: linear-gradient(100deg, color-mix(in srgb, var(--ms-gold) 36%, #1b1b1e), color-mix(in srgb, var(--ms-gold) 12%, #1b1b1e)); box-shadow: 0 0 0 1px color-mix(in srgb, var(--ms-gold) 60%, transparent); }
.champion-card.decided span { color: var(--ms-gold); }
.champion-card.decided strong { font-size: 1.1em; font-weight: 800; color: #fff; }
// Phone list.
.rounds, .round { display: grid; gap: var(--space-2); min-width: 0; }
.list-summary, .matchup-header, .line { display: flex; justify-content: space-between; align-items: center; gap: var(--space-2); }
.list-end { flex: 0 0 auto; display: flex; align-items: center; gap: var(--space-2); margin-left: auto; }
.list-summary p { margin: 0; min-width: 0; }
.list-champion strong { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.list-champion { display: grid; gap: .1em; }
.list-champion strong { font-size: 1.1em; font-weight: 800; color: var(--ms-gold); }
.matchup { border-radius: var(--radius-tile); overflow: hidden; }
.matchup-header { padding: .45em .6em 0; }
.line { padding: .5em .6em; }
.line + .line { border-top: 1px solid var(--line); }
.line small { display: block; }
.who { flex: 1 1 auto; min-width: 0; display: flex; align-items: center; gap: .45em; }
.who strong { min-width: 0; overflow-wrap: anywhere; font-weight: 600; color: #fff; }
.winner .who strong { font-weight: 800; }
// The shared You chip has a 12 px floor for overlays; in the phone list it follows the phone scale.
.rounds .ms-you { font-size: .7em; }
.value { flex: 0 0 auto; display: grid; justify-items: end; max-width: 50%; text-align: right; }
.value small { max-width: 11em; }
// A frame only for controller or keyboard focus; a tap on "Jump to my heat" scrolls there without drawing one.
.matchup:focus { outline: none; }
.matchup:focus-visible, .matchup.focus-visible { outline: 2px solid var(--phone-focus-color, rgba(255, 138, 61, .9)); outline-offset: -2px; }
</style>
