<!-- Owns qualifying results, the cut boundary and pass plots. The phone supplies immutable standings and the shared player status. -->
<template>
  <div class="qualifying-board">
    <template v-if="compact">
      <p v-if="entrants.length > compactEntrants.length" class="ms-meta">Top 6, the cut and you. Expand for everyone.</p>
      <div class="sheet lines standings">
        <template v-for="entrant in compactEntrants" :key="entrant.id">
          <div class="line standing" :class="{ 'ms-player-row': entrant.player, 'below-cut': belowCut(entrant) }">
            <span class="rank ms-meta ms-num">{{ seed(entrant) }}</span>
            <span class="who"><strong class="ms-caption">{{ driverName(entrant) }} <span v-if="needsYouChip(entrant)" class="ms-you">You</span></strong><small class="ms-meta">{{ buildName(entrant) }}</small><span v-if="entrant.player && playerChip(entrant)" class="pill player-chip" :class="playerChipTone(entrant)">{{ playerChip(entrant) }}</span></span>
            <span class="value" :class="{ 'ms-bad': entrant.qualifierDone && !legal(entrant.qualifying) }"><strong class="best-value ms-time">{{ bestTime(entrant) }}</strong><small v-if="passesLeft(entrant)" class="ms-meta">{{ attemptCount(entrant) }}</small><small role="note" v-if="passStatus(latestAttempt(entrant))" :title="passDescription(latestAttempt(entrant))" :aria-label="passDescription(latestAttempt(entrant))" class="ms-meta ms-bad">{{ passStatus(latestAttempt(entrant)) }}</small></span>
          </div>
          <p v-if="entrants.indexOf(entrant) === cutIndex" class="cut-divider"><span>{{ cutLabel }}</span></p>
        </template>
      </div>
    </template>
    <template v-else>
      <p class="plot-legend ms-meta"><span><i class="legend-best"></i><i class="legend-best out"></i> Best pass</span><span><i class="legend-pass"></i> Other passes</span><span v-if="hasIndex"><i class="legend-index"></i> Index <b class="ms-time">{{ indexSeconds.toFixed(2) }} s</b></span><span v-if="cutTime != null"><i class="legend-cut"></i> {{ cutLabel }} <b class="ms-time">{{ cutTime.toFixed(3) }} s</b></span></p>
      <div class="results-scroll scroll" v-bng-ui-nav-scroll>
        <div class="results-focus" tabindex="0" bng-nav-item role="region" data-phone-scroll-target aria-label="Full qualifying results">
          <table>
            <thead><tr><th>Seed</th><th>Driver</th><th class="plot-column">¼-mile ET <span class="axis"><span class="ms-time">{{ bounds.min.toFixed(2) }} s</span><span class="ms-time">{{ bounds.max.toFixed(2) }} s</span></span></th><th v-for="round in roundCount" :key="round">R{{ round }}</th><th>Best</th><th>Gap</th></tr></thead>
            <tbody>
              <template v-for="entrant in entrants" :key="entrant.id">
                <tr :class="{ 'ms-player-row': entrant.player, 'below-cut': belowCut(entrant) }">
                  <td>{{ seed(entrant) }}</td>
                  <th scope="row"><strong>{{ driverName(entrant) }} <span v-if="needsYouChip(entrant)" class="ms-you">You</span></strong><small>{{ buildName(entrant) }}</small><span v-if="entrant.player && playerChip(entrant)" class="pill player-chip" :class="playerChipTone(entrant)">{{ playerChip(entrant) }}</span></th>
                  <td class="plot-column">
                    <div class="time-plot" role="img" :aria-label="`${entrant.name}: ${bestTime(entrant)}${hasIndex ? `, index ${indexSeconds.toFixed(2)} s` : ''}`">
                      <template v-if="legalPasses(entrant).length">
                        <span class="baseline"></span>
                        <span v-if="hasIndex" class="index-mark" :style="{ left: `${plotX(indexSeconds)}%` }" :title="`Index ${indexSeconds.toFixed(2)} s`"></span>
                        <span v-if="cutTime != null" class="cut-mark" :style="{ left: `${plotX(cutTime)}%` }" :title="`Bracket cut ${cutTime.toFixed(3)} s`"></span>
                        <span v-for="(pass, attempt) in legalPasses(entrant)" :key="attempt" :style="{ left: `${plotX(pass.time)}%` }" class="pass" :title="`${pass.time.toFixed(3)} s`"></span>
                        <span v-if="legal(entrant.qualifying)" :style="{ left: `${plotX(entrant.qualifying.time)}%` }" class="best" :title="`Best: ${bestTime(entrant)}`"></span>
                      </template>
                      <span v-if="!legalPasses(entrant).length && !entrant.qualifierDone" class="muted plot-empty">Waiting</span>
                    </div>
                  </td>
                  <td v-for="round in roundCount" :key="round" :class="{ invalid: attempts(entrant)[round - 1]?.valid === false }">
                    <template v-if="attempts(entrant)[round - 1]">
                      <strong v-if="passTime(attempts(entrant)[round - 1]) !== 'Invalid' || !passStatus(attempts(entrant)[round - 1])" class="ms-time">{{ passTime(attempts(entrant)[round - 1]) }}</strong>
                      <small v-if="reactionTime(attempts(entrant)[round - 1])">{{ reactionTime(attempts(entrant)[round - 1]) }}</small>
                      <small role="note" v-if="passStatus(attempts(entrant)[round - 1])" :title="passDescription(attempts(entrant)[round - 1])" :aria-label="passDescription(attempts(entrant)[round - 1])" class="pass-status pill ms-tone-blocked">{{ passStatus(attempts(entrant)[round - 1]) }}</small>
                    </template><span v-else class="muted">—</span>
                  </td>
                  <td class="best-time" :class="{ dnq: entrant.qualifierDone && !legal(entrant.qualifying) }"><strong class="ms-time">{{ bestTime(entrant) }}</strong></td>
                  <td class="gap" :class="{ leader: gap(entrant) === 'Leader' }">{{ gap(entrant) }}</td>
                </tr>
                <tr v-if="entrants.indexOf(entrant) === cutIndex" class="cut-divider"><td :colspan="roundCount + 5">{{ cutLabel }}</td></tr>
              </template>
            </tbody>
          </table>
        </div>
      </div>
    </template>
  </div>
</template>

<script setup>
import { computed } from 'vue'
import { vBngUiNavScroll } from '@/common/directives'
import { count, dragResultReason, labels } from '../../utils/motorsportLabels.js'

const props = defineProps({ entrants: { type: Array, default: () => [] }, compact: Boolean,
  fieldSize: { type: Number, default: 16 }, indexSeconds: Number, playerStatus: Object, classId: String, bracket: Object })
// Every layout consumes Lua's standings; saved seeds only identify the field.
const bracketSeeded = computed(() => Array.isArray(props.bracket?.rounds)
  && props.bracket.rounds.some(round => Array.isArray(round.matches) && round.matches.length > 0))
const entrants = computed(() => Array.isArray(props.entrants) ? props.entrants : [])
const savedSeeds = computed(() => bracketSeeded.value
  ? entrants.value.filter(entrant => entrant.seed > 0) : [])
const attempts = entrant => Array.isArray(entrant.qualifyingAttempts) ? entrant.qualifyingAttempts : []
const legal = pass => pass?.valid === true && !pass.breakout && Number.isFinite(pass.time) && pass.time > 0
const legalPasses = entrant => {
  const passes = attempts(entrant).filter(legal)
  return passes.length ? passes : legal(entrant.qualifying) ? [entrant.qualifying] : []
}
const legalEntrants = computed(() => entrants.value.filter(entrant => legal(entrant.qualifying)))
const limit = computed(() => Number.isFinite(props.fieldSize) && props.fieldSize > 0 ? Math.floor(props.fieldSize) : Infinity)
const cutIndex = computed(() => legalEntrants.value.length >= limit.value
  ? entrants.value.indexOf(savedSeeds.value.at(-1) || legalEntrants.value[limit.value - 1]) : -1)
const cutTime = computed(() => cutIndex.value >= 0 ? entrants.value[cutIndex.value].qualifying.time : null)
// The cut names its own size, so no sentence above the board has to.
const cutLabel = computed(() => Number.isFinite(limit.value) ? `Bracket cut, top ${limit.value}` : 'Bracket cut')
const compactEntrants = computed(() => entrants.value.filter((entrant, index) => index < 6 || entrant.player || index === cutIndex.value || index === cutIndex.value + 1))
const seed = entrant => (bracketSeeded.value && entrant.seed) || (legal(entrant.qualifying) ? legalEntrants.value.indexOf(entrant) + 1 : '—')
const belowCut = entrant => legal(entrant.qualifying) && (savedSeeds.value.length ? !(entrant.seed > 0) : legalEntrants.value.indexOf(entrant) >= limit.value)
const entryStatus = entrant => (Array.isArray(props.playerStatus?.entries) ? props.playerStatus.entries : []).find(entry => entry.entrantId === entrant.id && (!props.classId || entry.classId === props.classId))
function playerChip(entrant) {
  const entry = entryStatus(entrant)
  if (entry?.idOutcome === 'excluded') return labels.excluded
  // A finished row without a legal time already reads "DNQ" where its best would be.
  if (!legal(entrant.qualifying)) return entrant.qualifierDone ? '' : 'No legal time yet'
  const delta = entrant.qualifying.time - (Number.isFinite(entry?.cutTime) ? entry.cutTime : cutTime.value)
  if (belowCut(entrant)) return delta > 0 ? `Out by ${delta.toFixed(3)} s` : 'Out, tied at the cut'
  if (entry?.idOutcome === 'didNotQualify') return labels.didNotQualify
  // The seed is the row's own first column.
  return `In${entrant.seed ? '' : ' (provisional)'}`
}
// In the bracket reads green, out or without a legal time reads red.
const playerChipTone = entrant => legal(entrant.qualifying) && !belowCut(entrant) && !['excluded', 'didNotQualify'].includes(entryStatus(entrant)?.idOutcome) ? 'ms-tone-go' : 'ms-tone-blocked'
const latestAttempt = entrant => attempts(entrant).at(-1)
// A finished row needs no pass count; it is shown while passes remain.
const passesLeft = entrant => !entrant.qualifierDone && attempts(entrant).length < Math.max(1, Math.floor(Number(entrant.qualifyingLimit) || 3))
const attemptCount = entrant => `${count(attempts(entrant).length, Math.max(1, Math.floor(Number(entrant.qualifyingLimit) || 3)))} passes`
const roundCount = computed(() => Math.max(3, ...props.entrants.map(entrant => Math.max(attempts(entrant).length, Number(entrant.qualifyingLimit) || 0))))
const hasIndex = computed(() => Number.isFinite(props.indexSeconds) && props.indexSeconds > 0)
const bounds = computed(() => {
  const times = props.entrants.flatMap(entrant => legalPasses(entrant).map(pass => pass.time))
  if (hasIndex.value) times.push(props.indexSeconds)
  if (!times.length) return { min: 0, max: 1 }
  const min = Math.min(...times), max = Math.max(...times), pad = Math.max(.05, (max - min) * .08)
  return { min: Math.max(0, min - pad), max: max + pad }
})
const leader = computed(() => Math.min(...legalEntrants.value.map(entrant => entrant.qualifying.time)))
const plotX = time => (time - bounds.value.min) / (bounds.value.max - bounds.value.min) * 100
const bestTime = entrant => legal(entrant.qualifying) ? `${entrant.qualifying.time.toFixed(3)} s` : entrant.qualifierDone ? 'DNQ' : '—'
const passTime = pass => Number.isFinite(pass.time) && pass.time > 0 ? `${pass.time.toFixed(3)} s` : pass.valid === false ? 'Invalid' : '—'
// Native timeouts store zero for both times; a zero RT needs a measured pass.
const reactionTime = pass => Number.isFinite(pass.reaction) && (pass.reaction !== 0 || (Number.isFinite(pass.time) && pass.time > 0)) ? `RT ${pass.reaction.toFixed(3)} s` : ''
function passStatus(pass) {
  if (!pass) return ''
  if (pass.valid !== false) return pass.qualifyingRedLight ? 'Red light' : ''
  const breakout = pass.reason?.match(/^Breakout: ([\d.]+) seconds is faster than the ([\d.]+) second index\.$/)
  if (breakout) {
    const margin = Number(breakout[2]) - Number(breakout[1])
    return Number.isFinite(margin) && margin >= 0 ? `Breakout ${margin < .0005 ? '<0.001' : margin.toFixed(3)}\u00a0s` : 'Breakout'
  }
  const reasons = { jumping: 'Red light', outOfLane: 'Boundary violation', crashed: 'Crash', stationaryTooLong: 'Did not finish', reactionTime: 'Invalid reaction' }
  return reasons[String(pass.reason || '').replace('missions.dragRace.gameplay.disqualified.', '')] || dragResultReason(pass.reason) || 'Invalid pass'
}
const passDescription = pass => pass?.reason?.startsWith('Breakout:') ? pass.reason : passStatus(pass)
const driverName = entrant => `${entrant.number ? `#${entrant.number} ` : ''}${entrant.name}`
// The player's row is tinted. The chip is for a row that shows a driver name; a row already named "You" does not need it.
const needsYouChip = entrant => !!entrant?.player && String(entrant.name || '').trim().toLowerCase() !== 'you'
const gap = entrant => legal(entrant.qualifying) && Number.isFinite(leader.value) ? entrant.qualifying.time === leader.value ? 'Leader' : `+${(entrant.qualifying.time - leader.value).toFixed(3)} s` : '—'
const configName = config => String(config || '').split('/').pop().replace(/\.pc$/, '')
const buildName = entrant => [entrant.model, entrant.configLabel || entrant.buildNickname || (entrant.player ? 'your build' : configName(entrant.config))].filter(Boolean).join(', ')
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;
@use "@/styles/rls_career_overhaul/modules/career/styles/motorsport.scss" as ms;
.qualifying-board { display: flex; flex-direction: column; gap: var(--space-2); min-width: 0; }
p { margin: 0; }
.muted, small { color: var(--muted); }
.player-chip { margin-top: .3em; }
// Legend: the same marks the plot draws.
.plot-legend, .plot-legend > span { display: flex; align-items: center; gap: .45em; flex-wrap: wrap; }
.plot-legend { gap: .4em 1.3em; }
.plot-legend b { font-size: 1.05em; }
// The legend draws the plot's own marks: a thick bar for the best pass, short ticks for the others, thin lines for
// the index and the cut.
.legend-best, .legend-pass, .legend-index, .legend-cut { flex: 0 0 auto; border-radius: 1px; }
.legend-best { width: .32em; height: 1em; border-radius: .16em; background: var(--ms-go); }
.legend-best.out { margin-left: -.2em; background: var(--ms-stop); }
.legend-pass { width: 2px; height: .55em; background: rgba(255, 255, 255, .5); }
.legend-index, .legend-cut { width: 2px; height: 1em; background: var(--ms-wait); }
// Full results: a flat panel, sticky column heads, the pass plot down the middle.
// Clip inside the fractional raster edge without moving the padded column headings.
.results-scroll { overflow: auto; max-height: 56vh; border-radius: var(--radius-panel); background: var(--panel); clip-path: inset(1px 0 0 round var(--radius-panel)); transform: translateZ(0); }
table { width: 100%; border-collapse: separate; border-spacing: 0; font-variant-numeric: tabular-nums; text-align: left; }
th, td { padding: var(--ms-row, .45em) var(--ms-pad, var(--inset)) calc(var(--ms-row, .45em) - .08em); border-bottom: 1px solid var(--line); white-space: nowrap; font-variant-numeric: tabular-nums; }
thead th { position: sticky; top: 0; z-index: 1; background: #222224; font-size: .8em; font-weight: 600; color: var(--faint); }
tbody th { min-width: 10em; font-weight: 400; white-space: normal; }
tbody th small { overflow-wrap: anywhere; }
tbody th strong { font-size: 1.02em; }
tbody tr:last-child > * { border-bottom: 0; }
small { display: block; font-size: .78em; font-weight: 600; margin-top: .1em; max-width: 21em; white-space: normal; color: var(--faint); }
td .ms-time { font-size: 1.02em; }
.plot-column { min-width: 10em; width: 28%; }
.axis { display: flex; justify-content: space-between; margin-top: .4em; }
.axis .ms-time { font-size: 1.05em; font-weight: 600; color: var(--muted); }
.time-plot { position: relative; height: 1.6em; }
.baseline { position: absolute; top: 50%; left: 0; right: 0; height: 2px; margin-top: -1px; border-radius: 1em; background: rgba(255, 255, 255, .12); }
.index-mark, .cut-mark { position: absolute; top: .1em; bottom: .1em; width: 2px; margin-left: -1px; border-radius: 1px; background: var(--ms-wait); }
// A dashed border this short draws one long dash; short painted dashes read as dashed at any scale.
.legend-cut, .cut-mark { background: repeating-linear-gradient(to bottom, rgba(255, 255, 255, .85) 0 .2em, transparent .2em .36em); }
// Passes are ticks on the time line. The best pass is the thick one: green inside the bracket, red below the cut.
.pass, .best { position: absolute; top: 50%; transform: translate(-50%, -50%); }
.pass { width: 2px; height: .55em; border-radius: 1px; background: rgba(255, 255, 255, .5); }
.best { width: .32em; height: 1.15em; border-radius: .16em; background: var(--ms-go); box-shadow: 0 0 0 .12em #2a2a2d; }
.below-cut .best { background: var(--ms-stop); }
.plot-empty { position: relative; font-size: .86em; }
.invalid .ms-time { color: var(--bad); }
// The reason sits under its time, with or without a reaction time between them.
.pass-status { display: flex; width: fit-content; margin-top: .3em; max-width: none; white-space: normal; }
// Best times are results, not money: bold white, and a missed field in red.
.best-time .ms-time { font-size: 1.2em; }
.best-time.dnq .ms-time, .value.ms-bad .best-value { color: var(--bad); }
.gap { color: var(--muted); }
.gap.leader { color: var(--ok); font-weight: 700; }
// Below the cut: still readable, clearly not in. The player's own row keeps full strength.
.below-cut:not(.ms-player-row) th strong, .below-cut:not(.ms-player-row) td, .below-cut:not(.ms-player-row) .ms-time, .below-cut:not(.ms-player-row) .who strong, .below-cut:not(.ms-player-row) .rank { color: var(--faint); }
tr.cut-divider td { padding: .32em var(--ms-pad, var(--inset)) .2em; text-align: center; font-size: .78em; font-weight: 700; color: var(--ms-stop-ink); background: color-mix(in srgb, var(--ms-stop) 12%, transparent); border-top: 1px dashed color-mix(in srgb, var(--ms-stop) 60%, transparent); border-bottom: 1px dashed color-mix(in srgb, var(--ms-stop) 60%, transparent); }
// Phone list.
.standing { display: flex; align-items: center; gap: .6em; padding: .5em; }
.standing + .standing { border-top: 1px solid var(--line); }
.rank { width: 1.5em; flex-shrink: 0; text-align: center; font-size: 1em; font-weight: 800; color: var(--muted); }
.who { flex: 1; min-width: 0; display: grid; justify-items: start; gap: .12em; }
.who strong { color: #fff; }
// The shared You chip has a 12 px floor for overlays; in the phone list it follows the phone scale.
.standing .ms-you { font-size: .7em; }
.value { display: grid; justify-items: end; gap: .1em; text-align: right; }
.best-value { font-size: 1.15em; }
p.cut-divider { display: flex; align-items: center; gap: .6em; padding: .3em .5em .2em; font-size: .76em; font-weight: 700; color: var(--ms-stop-ink); background: color-mix(in srgb, var(--ms-stop) 12%, transparent); }
p.cut-divider::before, p.cut-divider::after { content: ""; flex: 1 1 0; border-top: 1px dashed color-mix(in srgb, var(--ms-stop) 60%, transparent); }
</style>
