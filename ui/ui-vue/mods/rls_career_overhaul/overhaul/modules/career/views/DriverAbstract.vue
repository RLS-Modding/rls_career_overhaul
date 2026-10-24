<template>
  <ComputerWrapper :title="$t('ui.career.driverAbstract.title')" @back="close">
    <!-- read-only page: .force lets the right stick scroll it wherever focus is -->
    <div class="rls-house driver-abstract-card scroll" v-bng-ui-nav-scroll.force>
      <div v-if="abstractData" class="content">
        <!-- hero: the driver score is the one thing that matters here -->
        <section class="score-card" :class="driverColorClass">
          <div class="score-header">
            <span class="caption">{{ $t("ui.career.driverAbstract.driverScore") }}</span>
            <TutorialButton class="score-help" :icon="icons.help" :pages="['driverScore']" />
          </div>
          <div class="score-content">
            <div class="score-value" :class="driverColorClass">
              {{ abstractData.driverScore }}
            </div>
            <div class="score-info">
              <div class="score-risk" :class="driverColorClass">
                {{ abstractData.driverScoreTier.risk }}
              </div>
              <div class="score-description">
                {{ abstractData.driverScoreTier.description }}
              </div>
            </div>
            <!-- tip on focus too (not a hover title) so a pad can read it -->
            <div class="premium has-tip" bng-nav-item tabindex="0" v-bng-tooltip="$t('ui.career.driverAbstract.premiumEffectNote')">
              <span class="caption">{{ $t("ui.career.driverAbstract.premiumEffect") }}</span>
              <span class="premium-value" :class="premiumEffectClass">
                {{ $t(premiumEffect.key, premiumEffect.params) }}
              </span>
            </div>
          </div>

          <!-- where the score sits on 0..100, with the current tier's bracket behind it -->
          <div class="scale" aria-hidden="true">
            <span class="scale-band" :style="tierBandStyle"></span>
            <span class="scale-track">
              <span class="scale-fill" :style="{ transform: `scaleX(${scoreFraction})` }"></span>
            </span>
          </div>
          <div v-if="driverTier" class="scale-legend">
            <span>Tier <b>{{ driverTier.min }}–{{ driverTier.max }}</b></span>
            <span v-if="driverTier.max < 100">Next tier at <b>{{ driverTier.max + 1 }}</b></span>
            <span v-else>Top tier</span>
          </div>
        </section>

        <div class="details">
          <!-- record -->
          <section class="panel record">
            <span class="caption">{{ $t("ui.career.driverAbstract.repairHistory") }}</span>
            <div class="facts">
              <div class="fact" :class="{ bad: abstractData.repairHistory.insuranceRepairs > 0 }">
                <span class="fact-key">{{ $t("ui.career.driverAbstract.insuranceClaims") }}</span>
                <span class="fact-value">{{ abstractData.repairHistory.insuranceRepairs }}</span>
              </div>
              <div class="fact has-tip" bng-nav-item tabindex="0" v-bng-tooltip="$t('ui.career.driverAbstract.privateRepairsTip')">
                <span class="fact-key">{{ $t("ui.career.driverAbstract.privateRepairs") }}</span>
                <span class="fact-value">{{ abstractData.repairHistory.privateRepairs }}</span>
              </div>
              <div class="fact">
                <span class="fact-key">{{ $t("ui.career.driverAbstract.totalRepairs") }}</span>
                <span class="fact-value">{{ (abstractData.repairHistory.insuranceRepairs) + (abstractData.repairHistory.privateRepairs) }}</span>
              </div>
            </div>

            <div class="distance">
              <span class="caption">{{ $t("ui.career.driverAbstract.totalDistanceDriven") }}</span>
              <span class="distance-total">{{ totalDistanceFormatted }}</span>
              <div class="distance-breakdown">
                <span class="distance-part">
                  <span class="distance-label">{{ $t("ui.career.driverAbstract.insured") }}</span>
                  <b>{{ insuredDistanceFormatted }}</b>
                </span>
                <span class="distance-part">
                  <span class="distance-label">{{ $t("ui.career.driverAbstract.uninsured") }}</span>
                  <b>{{ uninsuredDistanceFormatted }}</b>
                </span>
              </div>
            </div>
          </section>

          <!-- money -->
          <section class="panel money-panel">
            <span class="caption">{{ $t("ui.career.driverAbstract.financialSummary") }}</span>
            <div class="lines">
              <div class="line">
                <span class="line-label">{{ $t("ui.career.driverAbstract.vehiclesInsured") }}</span>
                <span class="line-value">{{ abstractData.financialSummary.vehiclesInsuredCount }}</span>
              </div>
              <div class="line">
                <span class="line-label">{{ $t("ui.career.driverAbstract.premiumsPaid") }}</span>
                <span class="line-value gold"><BngUnit class="no-margin" :money="abstractData.financialSummary.totalPremiumPaid" /></span>
              </div>
              <div class="line">
                <span class="line-label">{{ $t("ui.career.driverAbstract.deductiblesPaid") }}</span>
                <span class="line-value gold"><BngUnit class="no-margin" :money="abstractData.financialSummary.totalDeductiblePaid" /></span>
              </div>
              <div class="line">
                <span class="line-label">{{ $t("ui.career.driverAbstract.privateRepairs") }}</span>
                <span class="line-value gold"><BngUnit class="no-margin" :money="abstractData.financialSummary.totalPrivateRepairsPaid" /></span>
              </div>
              <div class="line total">
                <span class="line-label">{{ $t("ui.career.driverAbstract.totalSpent") }}</span>
                <span class="line-value gold"><BngUnit class="no-margin" :money="abstractData.financialSummary.totalPaid" /></span>
              </div>
            </div>
            <div class="covered has-tip" bng-nav-item tabindex="0" v-bng-tooltip="$t('ui.career.driverAbstract.damageCoveredTip')">
              <span class="line-label">{{ $t("ui.career.driverAbstract.damageCovered") }}</span>
              <span class="line-value ok"><BngUnit class="no-margin" :money="abstractData.financialSummary.damageCoveredByInsurance" /></span>
            </div>
          </section>
        </div>

        <!-- reset: quiet, only interesting when the score is below the reset value -->
        <section class="panel reset-card">
          <span class="caption">{{ $t("ui.career.driverAbstract.driverScoreReset") }}</span>
          <!-- shown as text (not a hover title) so controller players can read it too -->
          <p class="hint reset-description">
            {{ $t("ui.career.driverAbstract.resetDescription", { resetTo: abstractData.driverScoreReset.resetTo }) }}
          </p>
          <div class="reset-content">
            <div class="facts reset-details">
              <div class="fact" :class="{ bad: canResetScore }">
                <span class="fact-key">{{ $t("ui.career.driverAbstract.currentScore") }}</span>
                <span class="fact-value">{{ abstractData.driverScore }}</span>
              </div>
              <div class="fact">
                <span class="fact-key">{{ $t("ui.career.driverAbstract.resetTo") }}</span>
                <span class="fact-value">{{ abstractData.driverScoreReset.resetTo }}</span>
              </div>
              <div class="fact money">
                <span class="fact-key">{{ $t("ui.career.driverAbstract.resetCost") }}</span>
                <span class="fact-value"><BngUnit class="no-margin" :money="abstractData.driverScoreReset.resetCost" /></span>
              </div>
            </div>
            <HouseButton
              class="reset-button"
              :bng-scoped-nav-autofocus="canResetScore ? '' : null"
              :disabled="!canResetScore"
              @click="resetDriverScore"
            >
              {{
                canResetScore
                ? $t("ui.career.driverAbstract.resetButton")
                : $t("ui.career.driverAbstract.resetNotAvailable", { resetTo: abstractData.driverScoreReset.resetTo })
              }}
            </HouseButton>
          </div>
        </section>
      </div>
    </div>

    <!-- Tabs are shown in infobar because they are tracked events by crossfire.
     This is a hack to prevent them from displaying in the infobar -->
    <BngBinding v-show="false" ui-event="tab_l" controller />
    <BngBinding v-show="false" ui-event="tab_r" controller />
  </ComputerWrapper>
</template>

<script setup>
import { reportUiFailure } from "../utils/safeLua"

import { useRouteReady } from "@/services/routeReadiness"
import { activateRouteTargetScope } from "@/services/scopedNav/api"
import { computed, ref, watch, nextTick } from "vue"
import { BngUnit, BngBinding, icons } from "@/common/components/base"
import { HouseButton } from "../components/house/index.js"
import { vBngTooltip, vBngUiNavScroll } from "@/common/directives"
import { useRoute } from "vue-router"
import { lua, useBridge } from "@/bridge"
import { useEvents } from "@/services/events"
import { useRouteDataStore } from "@/services/routeData"

import TutorialButton from "../components/TutorialButton.vue"
import { useScreenEntry, refocusIfLost } from "../composables/useScreenEntryFocus"
import ComputerWrapper from "./ComputerWrapper.vue"
import "../components/insurance/insuranceStyle.css"

// controller entry focus bound to this screen (a late retry never touches the next screen)
const focusScreenEntry = useScreenEntry()

const { units } = useBridge()
const route = useRoute()
const routeDataStore = useRouteDataStore()
const events = useEvents()

// Initial data comes from routeData (onRouteMount); post-reset updates arrive
// via the `playerAbstractData` guihook and override the routeData payload.
const resetData = ref(null)
const abstractData = computed(() => resetData.value || routeDataStore.data?.playerAbstract || null)

events.on("playerAbstractData", data => {
  resetData.value = data
})

const driverTier = computed(() => abstractData.value?.driverScoreTier)

// score bar: fill to the score (0..1) and the current tier's bracket behind it (percent of 0..100)
const clampPct = v => Math.min(100, Math.max(0, Number(v) || 0))
const scoreFraction = computed(() => clampPct(abstractData.value?.driverScore) / 100)
const tierBandStyle = computed(() => {
  const tier = driverTier.value
  if (!tier) return { display: "none" }
  const from = clampPct(tier.min)
  const to = clampPct(tier.max >= 100 ? 100 : tier.max + 1)
  return { left: `${from}%`, width: `${Math.max(0, to - from)}%` }
})

const totalDistanceFormatted = computed(() => {
  if (!abstractData.value) return ''
  return units.buildString('length', abstractData.value.totalDistanceDriven, 0)
})

const insuredDistanceFormatted = computed(() => {
  if (!abstractData.value) return ''
  return units.buildString('length', abstractData.value.insuredDistanceDriven, 0)
})

const uninsuredDistanceFormatted = computed(() => {
  if (!abstractData.value) return ''
  return units.buildString('length', abstractData.value.uninsuredDistanceDriven, 0)
})

const premiumEffectClass = computed(() => {
  if (!driverTier.value) return ''
  const multiplier = driverTier.value.multiplier
  if (multiplier < 1) return 'green'
  if (multiplier > 1) return 'red'
  return 'neutral'
})

const premiumEffect = computed(() => {
  if (!driverTier.value) return { key: "ui.career.driverAbstract.premiumStandard" }
  const multiplier = driverTier.value.multiplier

  if (multiplier < 1) {
    return { key: "ui.career.driverAbstract.premiumSavings", params: { savings: Math.round((1 - multiplier) * 100) } }
  } else if (multiplier > 1) {
    return { key: "ui.career.driverAbstract.premiumPenalty", params: { penalty: Math.round((multiplier - 1) * 100) } }
  }
  return { key: "ui.career.driverAbstract.premiumStandard" }
})

const canResetScore = computed(() => {
  if (!abstractData.value) return false
  const currentScore = abstractData.value.driverScore
  const resetToScore = abstractData.value.driverScoreReset.resetTo
  return currentScore < resetToScore
})

const driverColorClass = computed(() => {
  if (!driverTier.value) return 'green'
  const multiplier = driverTier.value.multiplier
  if (multiplier < 1) return 'blue'
  if (multiplier < 1.1) return 'green'
  if (multiplier < 1.3) return 'yellow'
  if (multiplier < 1.5) return 'orange'
  return 'red'
})

// the reset button turns disabled (bng-no-nav) once the score is reset; keep the d-pad on the page
watch(canResetScore, (can, was) => {
  // force: the browser drops focus from the now-disabled button only later
  if (was && !can) refocusIfLost(() => document.querySelector(".driver-abstract-card .has-tip"), { force: !!document.activeElement?.disabled })
}, { flush: "post" })

const resetDriverScore = async () => {
  try {
    // fresh data is pushed back via the `playerAbstractData` guihook
    await lua.overhaul_career_repair_insurance.resetDriverScore()
  } catch (error) {
    reportUiFailure(error, "Failed to reset driver score: (DriverAbstract)")
  }
}

const close = () => lua.extensions.ui_router.back()

// handlesOwnReady flow: ack the mount once the shell is rendered, then activate
// the route target scope after the routeData payload reports mounted-ready.
const isReady = computed(() => routeDataStore.routeName === route.name && routeDataStore.status === "mounted-ready")

let acknowledged = false
let scopeActivationRequestId = 0

async function activateScopeWhenReady() {
  if (!acknowledged) return
  if (!isReady.value) return

  const requestId = ++scopeActivationRequestId
  const routeName = route.name
  const fullPath = route.fullPath
  await nextTick()

  if (typeof window !== "undefined" && typeof window.requestAnimationFrame === "function") {
    await new Promise(resolve => window.requestAnimationFrame(() => resolve()))
  }

  if (requestId !== scopeActivationRequestId) return
  if (route.name !== routeName || route.fullPath !== fullPath) return

  activateRouteTargetScope()
}

useRouteReady({
  async waitUntilReady() {
    await nextTick()
    if (typeof window !== "undefined" && typeof window.requestAnimationFrame === "function") {
      await new Promise(resolve => window.requestAnimationFrame(() => resolve()))
    }
  },
  onReady() {
    // The transition finalized (ack succeeded and `onRouteMount` will run);
    // data may already be present on fast re-entry, so try activating now.
    acknowledged = true
    activateScopeWhenReady()
  },
})

watch(isReady, ready => {
  if (ready) activateScopeWhenReady()
})

// Controller: also wake the screen once the abstract is on screen, in case the routeMounted ack above
// never reports success (focusScreenEntry leaves existing focus alone)
watch(() => !!abstractData.value, has => {
  if (has) focusScreenEntry()
}, { immediate: true, flush: "post" })
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

/* RLS house Driver's Abstract. One near-black card, em off a resolution-scaled font.
   Hierarchy: the score (hero, warm glow, orange bar) > record + money (facts / lines) > reset (quiet). */
.driver-abstract-card {
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  width: min(94vw, 56em);
  max-height: 100%;
  margin: 0; /* under the screen heading, like the other computer screens */
  padding: 1.1em;
  border-radius: var(--radius-control);
  background: rgba(var(--bng-off-black-rgb), 0.9);
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06), 0 14px 40px rgba(0, 0, 0, 0.45);
}

.content {
  display: flex;
  flex-direction: column;
  gap: 0.8em;
}

// BngUnit: no padding, inherit the colour of whatever it sits in
:deep(.no-margin.info-item) {
  padding: 0;
  margin: 0;
}
.content :deep(.info-item) {
  --paddings: 0;
  --units-icon-color: currentColor;
}
.content :deep(.info-item),
.content :deep(.value-label),
.content :deep(.unit) {
  color: inherit;
  font-size: inherit;
  font-weight: inherit;
}

/* ---- hero: driver score */
.score-card {
  position: relative;
  display: grid;
  gap: 0.75em;
  padding: 1.1em 1.2em 1em;
  border-radius: var(--radius-control);
  background:
    radial-gradient(120% 60% at 0% 0%, rgba(255, 102, 0, 0.16), rgba(255, 102, 0, 0) 60%),
    var(--panel-2);
  box-shadow: inset 0 0 0 1px rgba(255, 178, 122, 0.18);
  animation: rise 0.28s ease-out both;
}

.score-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.8em;
  min-height: 1.6em;
}

// TutorialButton (a BngButton): plain glyph, no filled chip behind it
.score-header :deep(.score-help) {
  --bng-bg-enabled-opacity: 0;
  --bng-bg-hover: #fff;
  --bng-bg-hover-opacity: 0.1;
  --bng-bg-active: #fff;
  --bng-bg-active-opacity: 0.16;
  --bng-icon-color: var(--faint);
  margin: -0.4em -0.5em -0.4em 0;
  color: var(--faint);
  background: transparent;
  box-shadow: none;
}

.score-content {
  display: grid;
  grid-template-columns: auto minmax(0, 1fr) auto;
  align-items: center;
  column-gap: 0.9em;
}

.score-value {
  color: #fff;
  font-size: 5em;
  font-weight: 800;
  line-height: 0.9;
  letter-spacing: -0.03em;
  font-variant-numeric: tabular-nums;
  padding-top: 0.08em; // Overpass sits high
}

.score-info {
  display: grid;
  gap: 0.2em;
  min-width: 0;
}

.score-risk {
  font-size: 1.6em;
  font-weight: 800;
  line-height: 1.1;
  color: #fff;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  // status by exception: good tiers green, standard white, then warn / bad
  &.blue { color: var(--ok-ink); }
  &.yellow { color: var(--warn); }
  &.orange,
  &.red { color: var(--bad); }
}

.score-description {
  color: var(--muted);
  font-weight: 600;
}

.premium {
  display: grid;
  gap: 0.25em;
  justify-items: end;
  text-align: right;
  cursor: help;
}
.premium-value {
  color: #fff;
  font-size: 1.5em;
  font-weight: 800;
  line-height: 1.1;
  white-space: nowrap;
  font-variant-numeric: tabular-nums;
  &.green { color: var(--ok-ink); }
  &.red { color: var(--bad); }
}

/* slim 0..100 bar: tier bracket peeks out behind the track, orange fill to the score */
.scale {
  position: relative;
  height: 0.95em;
  margin-top: 0.2em;
}
.scale-band {
  position: absolute;
  top: 0;
  bottom: 0;
  border-radius: 0.3em;
  background: rgba(255, 255, 255, 0.14);
}
.scale-track {
  position: absolute;
  left: 0;
  right: 0;
  top: 50%;
  height: 0.42em;
  margin-top: -0.21em;
  border-radius: 1em;
  overflow: hidden;
  background: rgba(255, 255, 255, 0.1);
}
.scale-fill {
  display: block;
  width: 100%;
  height: 100%;
  border-radius: 1em;
  background: linear-gradient(90deg, rgba(255, 102, 0, 0.55), var(--accent));
  transform-origin: left center;
  transition: transform 0.4s ease-out; // after a reset the fill slides to the new score
  animation: fill-in 0.6s cubic-bezier(0.2, 0.7, 0.2, 1) 0.1s both;
}
.scale-legend {
  display: flex;
  justify-content: space-between;
  gap: 1em;
  margin-top: -0.25em;
  color: var(--faint);
  font-size: 0.82em;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
  b {
    color: var(--muted);
    font-weight: 800;
  }
}

/* ---- record + money */
.details {
  display: grid;
  grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
  gap: 0.8em;
}

.panel {
  align-content: start;
  gap: 0.7em;
  padding: 0.95em 1em 0.9em;
}

.fact-value {
  font-size: 1.35em;
  font-weight: 800;
  font-variant-numeric: tabular-nums;
}
.fact-key {
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
/* repair history: columns size to their labels ("Insurance claims" was cut to "Insurance clai..."),
   and a label wraps rather than truncates when the panel is narrow */
.details .facts {
  grid-template-columns: repeat(3, minmax(0, auto));
  justify-content: space-between;
  column-gap: 1em;
  .fact-key {
    white-space: normal;
    overflow-wrap: anywhere;
  }
}
/* read-only facts with a tip: reachable by the d-pad, the tip shows on focus */
.has-tip {
  position: relative;
  border-radius: var(--radius-control);
  cursor: help;
  @include house-focus;
}

.distance {
  display: grid;
  gap: 0.2em;
  padding-top: 0.7em;
  border-top: 1px solid var(--line);
}
.distance-total {
  font-size: 1.35em;
  font-weight: 800;
  line-height: 1.2;
  font-variant-numeric: tabular-nums;
}
.distance-breakdown {
  display: flex;
  flex-wrap: wrap;
  gap: 0.2em 1.2em;
  color: var(--faint);
  font-size: 0.85em;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
  b {
    color: var(--muted);
    font-weight: 700;
    margin-left: 0.3em;
  }
}

.money-panel .lines {
  margin-top: -0.3em;
}
.money-panel .line {
  padding-left: 0;
  padding-right: 0;
}
.line-label {
  min-width: 0;
  color: var(--muted);
  font-weight: 600;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.line-value {
  flex: 0 0 auto;
  font-weight: 700;
  font-variant-numeric: tabular-nums;
  &.gold { color: var(--money); }
  &.ok { color: var(--ok-ink); }
}
.line.total {
  .line-label {
    color: #fff;
    font-weight: 800;
  }
  .line-value {
    font-size: 1.2em;
    font-weight: 800;
  }
}
.covered {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 0.8em;
  padding-top: 0.6em;
  border-top: 1px solid var(--line);
  font-size: 0.9em;
  cursor: help;
}

/* ---- reset: quiet strip */
.reset-card {
  background: var(--panel);
  cursor: default;
}
.reset-content {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  gap: 0.8em 1.4em;
}
.reset-details {
  flex: 1 1 22em;
  grid-template-columns: repeat(3, minmax(0, auto));
  justify-content: start;
  column-gap: 2.2em;
  .fact-value {
    font-size: 1.15em;
  }
}
.reset-button {
  flex: 0 1 auto;
  max-width: 100%;
  min-height: 2.6em;
  :deep(.btn-label) {
    white-space: normal;
    text-align: center;
    line-height: 1.2;
  }
}
.reset-description {
  margin: -0.2em 0 0;
  line-height: 1.4;
}

/* motion: transform / opacity only */
@keyframes rise {
  from { opacity: 0; transform: translateY(0.4em); }
}
@keyframes fill-in {
  from { transform: scaleX(0); }
}
@media (prefers-reduced-motion: reduce) {
  .score-card,
  .scale-fill {
    animation: none;
  }
}

@media (max-width: 60rem) {
  .details {
    grid-template-columns: 1fr;
  }
  .score-content {
    grid-template-columns: auto minmax(0, 1fr);
  }
  .premium {
    grid-column: 1 / -1;
    justify-items: start;
    text-align: left;
    margin-top: 0.6em;
  }
}
</style>
