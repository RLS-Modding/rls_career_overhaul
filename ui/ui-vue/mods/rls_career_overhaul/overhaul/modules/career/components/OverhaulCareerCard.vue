<template>
  <section class="rls-house rls-house-card overhaul-career-card" aria-label="Overhaul career overview"
    v-bng-scoped-nav="{ scopeId: 'overhaul-pause-skills', type: 'container' }">
    <template v-for="section in data.sections" :key="section.id">
      <header v-if="section.kind === 'profile'">
        <h2 class="profile-name">{{ section.value }}</h2>
      </header>
      <div v-else-if="section.kind === 'value'" class="card-value" :class="section.format === 'money' ? 'balance-block' : 'detail-block'">
        <span v-if="section.format !== 'money'" class="caption">{{ section.label }}</span>
        <span v-if="section.format === 'money' && section.value != null" class="balance" tabindex="0"
          :class="{ income: section.value > 0, expense: section.value < 0 }"
          :title="exactMoney(section.value)" :aria-label="exactMoney(section.value)">
          {{ moneySign(section.value) }}<BngIcon :type="icons.beamCurrency" aria-hidden="true" />{{ formatMoneyCompact(section.value, { minimumCompact: 10000, maximumFractionDigits: 2, locale: moneyLocale() }) }}
          <span class="exact-money">{{ exactMoney(section.value) }}</span>
        </span>
        <div v-else class="value-content">
          <img v-if="section.thumbnail && !failedImages.has(section.thumbnail)" class="vehicle-thumbnail"
            :src="section.thumbnail" alt="" @error="failedImages.add(section.thumbnail)" />
          <BngIcon v-else-if="icons[section.icon]" class="value-icon" :type="icons[section.icon]" aria-hidden="true" />
          <strong>{{ section.value ?? 'Unavailable' }}</strong>
        </div>
      </div>
      <div v-else-if="section.kind === 'skills'" class="skill-section">
        <h3>{{ section.label }}</h3>
        <div class="skills-window" :class="edges[section.id]">
          <div ref="skillGrids" class="skills scroll" :data-section-id="section.id" role="group" :aria-label="section.label" bng-nav-scroll
            @scroll.passive="updateEdges($event.target)" @focusin="revealSkill" @keydown="navigateSkills" @ui_nav="navigateSkillController">
            <div v-for="skill in section.rows" :key="skill.skillKey" class="skill" :style="{ '--skill-color': skillColor(skill) }" tabindex="0" bng-nav-item
              :aria-label="`${skill.label}, ${$ctx_t({ txt: 'ui.career.lvlLabel', context: { lvl: skill.level } })}, ${skill.maxLevel ? $t('ui.career.lvlLabelMax') : $ctx_t({ txt: 'ui.career.overhaulCard.toNextLevel', context: { percent: percent(skill) } })}`">
              <div class="skill-heading"><strong>{{ skill.label }}</strong></div>
              <div class="skill-progress">
                <BngIcon v-if="icons[skill.icon]" class="skill-icon" :type="icons[skill.icon]" aria-hidden="true" />
                <div class="skill-track" role="progressbar" :aria-label="$ctx_t({ txt: 'ui.career.overhaulCard.progressLabel', context: { skill: skill.label } })"
                :aria-valuenow="percent(skill)" aria-valuemin="0" aria-valuemax="100"
                :aria-valuetext="skill.maxLevel ? $t('ui.career.lvlLabelMax') : $ctx_t({ txt: 'ui.career.overhaulCard.toNextLevel', context: { percent: percent(skill) } })">
                <div class="skill-fill" :style="{ transform: `scaleX(${fraction(skill)})` }" />
                </div>
                <span class="skill-percent">{{ percent(skill) }}%</span>
                <span class="level-badge">{{ `Lv ${skill.level}${skill.maxLevel ? ' MAX' : ''}` }}</span>
              </div>
            </div>
          </div>
        </div>
      </div>
    </template>
  </section>
</template>

<script setup>
import { ref, reactive, onMounted, onBeforeUnmount } from 'vue'
import { useBridge } from '@/bridge'
import { BngIcon, icons } from '@/common/components/base'
import { formatMoneyCompact, moneySign } from '../utils/businessUtils.js'
import { vBngScopedNav } from '@/common/directives'
import { scrollEdges, fitSkillRows, revealSkill, navigateSkills, navigateSkillController } from '../profiles/careerCardScroll.js'
defineProps({ data: { type: Object, required: true } })
const { units } = useBridge()
const moneyLocale = () => units?.userSettings?.uiLanguage || undefined
const failedImages = reactive(new Set())
const skillGrids = ref([])
const edges = reactive({})
const updateEdges = grid => { edges[grid.dataset.sectionId] = scrollEdges(grid) }
const fitGrid = grid => {
  const height = fitSkillRows(grid)
  grid.style.maxHeight = height == null ? '' : `${height}px`
  // Resizing does not emit focusin. Reading the new bounds also flushes layout.
  const active = grid.ownerDocument.activeElement
  if (active && grid.contains(active)) revealSkill({ currentTarget: grid, target: active })
  updateEdges(grid)
}
const fitAll = () => skillGrids.value.forEach(fitGrid)
let resizeObserver
onMounted(() => {
  // Runs on size changes only: the pause column (window, UI scale) and the skill rows.
  resizeObserver = new ResizeObserver(fitAll)
  for (const grid of skillGrids.value) {
    fitGrid(grid)
    resizeObserver.observe(grid)
    if (grid.firstElementChild) resizeObserver.observe(grid.firstElementChild)
    const area = grid.closest('.menu-content-main')
    if (area) resizeObserver.observe(area)
  }
})
onBeforeUnmount(() => resizeObserver?.disconnect())
function fraction(skill) {
  if (skill.maxLevel) return 1
  const needed = Number(skill.neededForNext)
  const progress = Number(skill.curLvlProgress)
  return needed > 0 && Number.isFinite(progress) ? Math.min(1, Math.max(0, progress / needed)) : 0
}
// Use the category accent for foregrounds; its base colour is a grey surface.
// Skill catalog colours are hex or BeamNG RGB-triplet tokens.
function skillColor(skill) {
  const color = skill.accentColor || skill.color
  return color?.startsWith('var(--') ? `rgb(${color})` : color || '#f5a65b'
}
const exactMoney = amount => new Intl.NumberFormat(moneyLocale(), { minimumFractionDigits: 2, maximumFractionDigits: 20 }).format(amount)
const percent = skill => Math.floor(fraction(skill) * 100)
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;
.overhaul-career-card {
  container-type: inline-size;
  display: grid;
  grid-template-columns: minmax(0, 1fr) auto;
  gap: var(--space-3);
  padding: 1.1em;
  // This card is already inside the stock translucent pause surface.
  background: transparent;
  border-radius: var(--radius-control);
  box-shadow: inset 0 0 0 1px var(--line);
  font-variant-numeric: tabular-nums;
  header { align-self: center; min-width: 0; }
  .skill-section, .detail-block { grid-column: 1 / -1; }
  .balance-block { text-align: right; align-self: center; }
  .detail-block { justify-self: start; max-width: 100%; display: flex; align-items: center; gap: 0.5em; padding: 0.25em 0.5em; background: transparent; border-radius: var(--radius-control); }
  .detail-block .caption { margin: 0; font-size: 0.75em; }
  .value-content strong { font-size: 0.85em; }
  .caption { display: block; font-size: 0.8em; color: var(--muted); margin-bottom: 0.25em; }
  .profile-name { margin: 0; font-size: 1.3em; font-weight: 700; line-height: 1.2; overflow-wrap: anywhere; }
  .card-value { min-width: 0; overflow-wrap: anywhere; }
  .value-content { display: flex; align-items: center; gap: var(--space-2); }
  .vehicle-thumbnail { width: 2.2em; height: 1.4em; object-fit: cover; border-radius: var(--radius-control); flex: 0 0 auto; }
  .value-icon { font-size: 1.4em; color: var(--muted); flex: 0 0 auto; }
  .balance { position: relative; display: inline-flex; align-items: center; gap: 0.15em; color: var(--money); font-size: 1.3em; font-weight: 700; white-space: nowrap; }
  .balance.income { color: var(--ok-ink); }
  .balance.expense { color: var(--bad); }
  .balance :deep(.icon) { --bng-icon-color: currentColor; }
  .exact-money { display: none; position: absolute; right: 0; top: 100%; z-index: 2; padding: 0.4em; background: #151820; border: 1px solid var(--line); border-radius: var(--radius-control); font-size: 0.75rem; }
  .balance:hover .exact-money, &:focus-within .exact-money { display: block; }
  h3 { font-size: 1em; margin: 0 0 var(--space-3); }
  .skill-section { min-width: 0; }
  .skills-window {
    --fade-top: 0em;
    --fade-bottom: 0em;
    // Fades stay within the row gap so they hint at more rows without hiding a row's text.
    &.above { --fade-top: var(--space-3); }
    &.below { --fade-bottom: var(--space-3); }
    mask-image: linear-gradient(to bottom, transparent, #000 var(--fade-top), #000 calc(100% - var(--fade-bottom)), transparent);
  }
  .skills {
    display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 0.6em var(--space-4);
    // Height comes from fitSkillRows; the house .scroll class supplies overflow and the scrollbar.
    overflow-x: hidden; overscroll-behavior: contain; scroll-behavior: auto; padding: 0.2em;
  }
  @container (min-width: 42rem) { .skills { grid-template-columns: repeat(3, minmax(0, 1fr)); } }
  .skill { display: flex; flex-direction: column; min-width: 0; padding: 0.2em 0; background: transparent; border-radius: var(--radius-control); outline-offset: 0.1em; }
  .balance.focus-visible, .skill.focus-visible { outline: 2px solid var(--accent); }
  // Names keep the heading width; levels share the progress line below.
  .skill-heading { min-width: 0; font-size: 0.85em; }
  .skill-heading strong { display: block; min-width: 0; word-break: normal; overflow-wrap: anywhere; }
  .skill-icon { font-size: 1.3em; flex: 0 0 auto; color: color-mix(in srgb, var(--skill-color), white 35%); --bng-icon-color: currentColor; }
  .level-badge { flex: 0 0 auto; padding: 0.08em 0.4em; border-radius: 0.25em; background: #303035; font-size: 0.75em; color: #ebebeb; }
  .skill-progress { display: flex; align-items: center; gap: var(--space-2); margin-top: auto; }
  .skill-percent { font-size: 0.75rem; text-align: right; display: none; }
  .skill:hover .skill-percent, .skill:focus .skill-percent, .skill.focus-visible .skill-percent { display: inline; }
  .skill-track { flex: 1; height: 0.2em; border-radius: var(--radius-pill); overflow: hidden; background: var(--panel-2); margin-top: var(--space-1); }
  .skill-fill { height: 100%; background: color-mix(in srgb, var(--skill-color), white 25%); transform-origin: left; }
}
</style>

<style lang="scss">
// Widen only the Home column while our card is mounted; other pause tabs keep stock widths.
.menu-content-card-2:has(#overhaul-pause-career-host) {
  width: clamp(26rem, 36vw, 44rem) !important;
}
@media (max-width: 1500px) {
  .menu-content-card-2:has(#overhaul-pause-career-host) { width: clamp(21rem, calc(100vw - 53rem), 28rem) !important; }
}
</style>
