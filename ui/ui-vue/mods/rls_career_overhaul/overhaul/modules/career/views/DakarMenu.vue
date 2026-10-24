<template>
  <!-- Controller (no scope on this screen): B / Start close, LB / RB switch Sign Up / Accolades, and each
       view puts focus on its main action when it opens -->
  <div
    class="dakar-shell"
    v-bng-on-ui-nav:back,menu="onNavClose"
    v-bng-on-ui-nav:tab_l="prevTab"
    v-bng-on-ui-nav:tab_r="nextTab">
    <div class="rls-house dakar-panel scroll" v-bng-ui-nav-scroll>
      <header class="topbar">
        <div>
          <h1>Dakar</h1>
          <p>{{ subtitle }}</p>
        </div>
        <HouseButton compact binding="back" @click="close">Close</HouseButton>
      </header>

      <div class="tabs">
        <BngBinding v-if="activeTab !== 'start'" class="tab-glyph" ui-event="tab_l" controller track-ignore />
        <div class="seg bar" role="group" aria-label="Dakar sections">
          <button
            v-for="tab in tabButtons"
            :key="tab.id"
            type="button"
            bng-nav-item
            :class="[tab.className, { active: activeTab === tab.id }]"
            :aria-pressed="activeTab === tab.id"
            v-bng-sound-class="'bng_click_hover_generic'"
            @click="activeTab = tab.id">{{ tab.label }}</button>
        </div>
        <BngBinding v-if="activeTab !== 'start'" class="tab-glyph" ui-event="tab_r" controller track-ignore />
      </div>

      <section v-if="activeTab === 'start'" class="start-confirm">
        <h2>Dakar Start</h2>
        <p>Begin the run when you are ready.</p>
        <div class="details-grid">
          <div class="detail">
            <span>Class</span>
            <strong>{{ data.pending?.classLabel || data.classInfo?.label || 'Unlimited' }}</strong>
          </div>
          <div class="detail">
            <span>Repair Kits</span>
            <strong>{{ data.pending?.repairsLeft || 0 }}</strong>
          </div>
        </div>
        <HouseButton class="signup-button" variant="primary" block @click="startEvent">Start Event</HouseButton>
      </section>

      <section v-else-if="showIntroScreen" class="intro">
        <div class="intro-copy">
          <h2>The desert does not care how fast you are.</h2>
          <p>Read the land, protect the machine, and keep moving. Dakar rewards the driver who can finish what they start.</p>
        </div>

        <div class="intro-list">
          <div>Use the checkpoint photo, name, and distance to navigate.</div>
          <div>No GPS route is provided once the Dakar begins.</div>
          <div>Checkpoint markers only appear when you are close.</div>
          <div>Repair Kits must fit in your cargo boxes and add time penalties when used.</div>
          <div>Placement and time bonus are revealed after the finish.</div>
        </div>

        <label class="check intro-check">
          <input type="checkbox" class="intro-check-box" v-model="dontShowIntroAgain">
          <span>Do not show again</span>
        </label>

        <HouseButton class="signup-button" variant="primary" block @click="continueIntro">Continue</HouseButton>
      </section>

      <section v-else-if="activeTab === 'signup'" class="signup">
        <div v-if="data.setupBlockedReason" class="blocked-banner">
          {{ data.setupBlockedReason }}
        </div>

        <!-- the class cards come from the Dakar provider: no classes, no empty heading -->
        <div v-if="classOrder.length" class="class-section">
          <div class="kicker">Class</div>
          <div class="class-breakdown">
            <div v-for="classId in classOrder" :key="`${classId}-description`" class="class-description" :class="{ selected: data.classInfo?.id === classId }">
              <strong>{{ classTitle(classId) }} Class <span>{{ classes[classId]?.checkpointCount || 0 }} CP</span></strong>
              <span>{{ classDescriptions[classId] || 'Dakar eligible vehicles.' }}</span>
            </div>
          </div>
        </div>

        <div class="registration-section">
          <div class="kicker">Registration</div>
          <div class="details-grid">
            <div class="detail">
              <span>Registered Vehicle</span>
              <strong>{{ data.classInfo?.vehicleName || 'No vehicle detected' }}</strong>
            </div>
            <div class="detail">
              <span>Cargo Space</span>
              <strong>{{ cargoSpaceLabel }}</strong>
            </div>
            <div class="detail kit-detail">
              <span id="dakar-kit-label">Repair Kits Ordered</span>
              <!-- disabled buttons leave pad navigation (HouseButton sets bng-no-nav); a limit hit while
                   focused moves focus to the other button (see the kitCount watcher) -->
              <div class="kit-controls">
                <HouseButton class="kit-less" aria-label="Fewer repair kits" :disabled="kitCount <= 0" @click="kitCount--">−</HouseButton>
                <output aria-labelledby="dakar-kit-label" aria-live="polite">{{ kitCount }}</output>
                <HouseButton class="kit-more" aria-label="More repair kits" :disabled="kitCount >= maxKits" @click="kitCount++">+</HouseButton>
              </div>
            </div>
            <div class="detail">
              <span>Repair Kit Cost</span>
              <strong><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(data.repairKit.cost) }}</strong>
            </div>
          </div>
        </div>

        <div class="totals">
          <div><span>Kit cargo</span><strong>{{ kitCount * (data.repairKit.slots || 0) }} slots</strong></div>
          <div><span>Kit weight</span><strong>{{ units.buildString('weight', kitCount * (data.repairKit.weightKg || 0), 0) }}</strong></div>
          <div><span>Total</span><strong><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(kitCount * (data.repairKit.cost || 0)) }}</strong></div>
        </div>

        <div v-if="data.lastResult && props.tab === 'result'" class="result">
          <h2>{{ data.lastResult.placement }}</h2>
          <div class="result-grid">
            <span>Time</span><strong>{{ time(data.lastResult.adjustedSeconds) }}</strong>
            <span>Target</span><strong>{{ time(data.lastResult.targetSeconds) }}</strong>
            <span>Penalty</span><strong>{{ time(data.lastResult.repairPenaltySeconds) }}</strong>
            <span>Reward</span><strong><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(data.lastResult.totalReward) }}</strong>
          </div>
        </div>

        <HouseButton class="signup-button" variant="primary" block :disabled="signUpBlocked" @click="signUp">Sign Up</HouseButton>
      </section>

      <section v-else class="accolades">
        <div v-for="acc in data.accolades" :key="acc.id" class="accolade">
          <div>
            <h2>{{ acc.title }}</h2>
            <p>{{ acc.description }}</p>
            <div class="meter"><span :style="{ width: progressWidth(acc) }"></span></div>
            <div class="accolade-meta">
              <small>{{ acc.progress }} / {{ acc.target }}</small>
              <strong><template v-if="acc.rewardLabel">{{ acc.rewardLabel }}</template><template v-else><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(acc.rewardMoney) }}</template></strong>
            </div>
          </div>
          <HouseButton class="claim-button" :variant="acc.ready ? 'primary' : 'neutral'" :disabled="!acc.ready" @click="claim(acc.id)">
            {{ acc.claimed ? 'Claimed' : 'Claim' }}
          </HouseButton>
        </div>
      </section>
    </div>
  </div>
</template>

<script setup>
import { computed, onMounted, onUnmounted, reactive, ref, watch } from 'vue'
import { BngBinding, BngIcon, icons } from '@/common/components/base'
import { vBngOnUiNav, vBngUiNavScroll, vBngSoundClass } from '@/common/directives'
import { HouseButton } from '../components/house/index.js'
import { useBridge } from '@/bridge'
import { refocusIfLost } from '../composables/useScreenEntryFocus'

const props = defineProps({
  tab: {
    type: String,
    default: 'signup'
  }
})

const { events, units } = useBridge()
const activeTab = ref(['accolades', 'start'].includes(props.tab) ? props.tab : 'signup')
const kitCount = ref(0)
const introDismissedThisOpen = ref(false)
const dontShowIntroAgain = ref(false)
const data = reactive({
  phase: 'idle',
  classInfo: null,
  setupBlockedReason: null,
  showIntro: false,
  classes: {},
  classOrder: [],
  repairKit: {},
  pending: null,
  accolades: [],
  lastResult: null
})

const classes = computed(() => data.classes || {})
const classOrder = computed(() => data.classOrder || [])
const maxKits = computed(() => Math.max(0, data.repairKit?.maxByCargo || 0))
const subtitle = computed(() => data.phase === 'signedUp' ? 'Proceed to the Dakar start' : 'Navigation and endurance')
const showIntroScreen = computed(() => activeTab.value === 'signup' && data.showIntro && !introDismissedThisOpen.value)
const classDescriptions = {
  SSV: 'Side by Side Vehicles, UTVs, and Buggies.',
  Raid: 'Pickup and SUV bodies only.',
  Heavy: 'Stambecco, MD-series, and T-series.',
  Unlimited: "Everything else that doesn't fit."
}
const signUpBlocked = computed(() => data.phase === 'active' || !!data.setupBlockedReason)
const cargoSpaceLabel = computed(() => {
  const slots = data.repairKit?.freeCargoSlots || 0
  const boxes = data.repairKit?.cargoContainerCount || 0
  if (!boxes) return `${slots} slots`
  return `${slots} slots / ${boxes} ${boxes === 1 ? 'box' : 'boxes'}`
})

function applyData(payload) {
  if (!payload) return
  data.phase = payload.phase || 'idle'
  data.classInfo = payload.classInfo || null
  data.setupBlockedReason = payload.setupBlockedReason || null
  data.showIntro = payload.showIntro === true
  data.classes = payload.classes || {}
  data.classOrder = payload.classOrder || []
  data.repairKit = payload.repairKit || {}
  data.pending = payload.pending || null
  data.accolades = payload.accolades || []
  data.lastResult = payload.lastResult || null
  kitCount.value = Math.min(kitCount.value, maxKits.value)
}

function luaString(value) {
  return `"${String(value).replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`
}

function callDakar(method, args = '') {
  const configuredArgs = args ? `${args}, config` : 'config'
  window.bngApi.engineLua(`local name = overhaul_world_maps and overhaul_world_maps.getOptionalFeatureExtension and overhaul_world_maps.getOptionalFeatureExtension('dakar'); local config = overhaul_world_maps and overhaul_world_maps.getOptionalFeatureConfig and overhaul_world_maps.getOptionalFeatureConfig('dakar'); local feature = name and extensions[name]; if feature and feature.${method} then if config ~= nil then feature.${method}(${configuredArgs}) else feature.${method}(${args}) end else log('W', 'overhaul_optional_events', 'Dakar ${method} disabled: provider or method unavailable (' .. tostring(name) .. ')') end`)
}

function refresh() {
  callDakar('requestDakarMenuData')
}

// Template puts the game currency glyph before it.
function money(value) {
  return Math.round(value || 0).toLocaleString()
}

function time(seconds) {
  seconds = Math.max(0, Math.floor(seconds || 0))
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`
}

function progressWidth(acc) {
  return `${Math.min(100, Math.round((acc.progress / Math.max(1, acc.target)) * 100))}%`
}

function classTitle(classId) {
  return classes.value[classId]?.label || classId
}

function signUp() {
  callDakar('signUp', String(Math.max(0, Math.floor(kitCount.value || 0))))
}

function continueIntro() {
  introDismissedThisOpen.value = true
  callDakar('dismissIntro', dontShowIntroAgain.value ? 'true' : 'false')
}

function startEvent() {
  callDakar('startEvent')
}

function claim(id) {
  callDakar('claimAccolade', luaString(id))
}

function close() {
  callDakar('closeMenu')
}

// ---- controller
const tabButtons = [
  { id: 'signup', label: 'Event Sign Up', className: 'tab-signup' },
  { id: 'accolades', label: 'Dakar Accolades', className: 'tab-accolades' },
]
const TABS = tabButtons.map(tab => tab.id)
// unscoped screen: the directive's listener does not stop the ui_nav event, so B would also reach the
// game's global ui_router.back() fallback
function onNavClose(event) {
  event?.stopPropagation?.()
  close()
}
function prevTab(event) {
  event?.stopPropagation?.()
  if (activeTab.value === 'start') return
  activeTab.value = TABS[(TABS.indexOf(activeTab.value) + TABS.length - 1) % TABS.length]
}
function nextTab(event) {
  event?.stopPropagation?.()
  if (activeTab.value === 'start') return
  activeTab.value = TABS[(TABS.indexOf(activeTab.value) + 1) % TABS.length]
}
// each view's main action: Start Event, the intro's Continue, Sign Up (else the kit stepper), the
// first claimable accolade (else the accolades tab button)
const enabled = sel => document.querySelector(`.dakar-panel ${sel}:not([disabled])`)
function pickViewFocus() {
  if (activeTab.value === 'start' || showIntroScreen.value) return enabled('.signup-button')
  if (activeTab.value === 'signup') return enabled('.signup-button') || enabled('.kit-more') || enabled('.kit-less') || enabled('.tab-signup')
  return enabled('.claim-button') || enabled('.tab-accolades')
}
// a view swap unmounts the focused button: move to the new view's action
watch([activeTab, showIntroScreen], () => refocusIfLost(pickViewFocus, { force: !document.activeElement?.closest?.('.tabs') }), { flush: 'post' })
// first data (entry) and refreshes (claim / sign up re-render the buttons)
watch(() => [data.phase, data.accolades, data.setupBlockedReason], () => refocusIfLost(pickViewFocus), { flush: 'post' })
// the kit stepper disables - at 0 and + at the cargo limit, under focus: hop to the other one
// (force while the focused button is the one just disabled: the browser drops that focus only later)
watch(kitCount, () => refocusIfLost(() => enabled('.kit-more') || enabled('.kit-less') || pickViewFocus(), { force: !!document.activeElement?.disabled }), { flush: 'post' })

watch(() => props.tab, tab => {
  if (tab === 'accolades') activeTab.value = 'accolades'
  if (tab === 'start') activeTab.value = 'start'
  if (tab === 'signup' || tab === 'result') activeTab.value = 'signup'
})

onMounted(() => {
  events.on('dakarData', applyData)
  refresh()
})

onUnmounted(() => {
  events.off('dakarData', applyData)
})
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

.dakar-shell {
  // scaled unit: the screen keeps the same share of the display at 720p..4K (rem/px-sized it shrank at 1440p),
  // still following the player's UI scale; everything inside sizes in em off it
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  min-height: 100vh;
  display: flex;
  align-items: center;
  justify-content: center;
  background: rgba(0, 0, 0, 0.55);
}

.dakar-panel {
  width: min(56.25em, 86vw);
  max-height: 86vh;
  display: grid;
  align-content: start;
  gap: 1.1em;
  padding: 1.3em 1.4em 1.4em;
  border-radius: var(--radius-control);
  background: rgba(var(--bng-off-black-rgb, 18, 18, 18), 0.94);
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06), 0 14px 40px rgba(0, 0, 0, 0.45);
}

h1,
h2,
p {
  margin: 0;
}

/* ---- header and section tabs */
.topbar {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 0.75em;
  h1 {
    font-size: 1.9em;
    font-weight: 800;
    line-height: 1.1;
  }
  p {
    color: var(--muted);
    font-weight: 600;
  }
}

.tabs {
  display: flex;
  align-items: center;
  gap: 0.6em;
  .seg.bar {
    flex: 0 1 auto;
  }
  .seg.bar button {
    flex: 0 0 auto;
    padding: 0.5em 0.9em 0.38em;
  }
}
.tab-glyph {
  flex: 0 0 auto;
}

/* ---- shared cards */
.class-description,
.detail,
.totals,
.result,
.intro-list,
.accolade {
  border-radius: var(--radius-panel);
  background: var(--panel);
  padding: var(--inset);
}

.detail > span,
.totals > div > span,
.accolade p,
.accolade small {
  color: var(--muted);
}

.signup,
.start-confirm,
.intro,
.accolades {
  display: grid;
  gap: 0.75em;
}

.class-section,
.registration-section {
  display: grid;
  gap: 0.6em;
}

.details-grid,
.class-breakdown {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 0.6em;
}

.detail {
  display: grid;
  align-content: start;
  gap: 0.3em;
  min-height: 5.1em;
  strong {
    font-weight: 700;
  }
}

/* ---- class cards: the player's class is lit like a picked tile, not ringed */
.class-description {
  display: grid;
  gap: 0.25em;
  strong {
    display: flex;
    justify-content: space-between;
    gap: 0.6em;
    font-size: 0.9em;
    font-weight: 700;
  }
  strong span {
    color: var(--faint);
    white-space: nowrap;
    font-variant-numeric: tabular-nums;
  }
  > span {
    color: var(--muted);
    font-size: 0.85em;
    line-height: 1.3;
  }
  &.selected {
    background: var(--panel-2);
    strong {
      color: var(--accent-soft);
    }
  }
}

/* ---- repair kit stepper */
.kit-controls {
  display: grid;
  grid-template-columns: minmax(4.75em, 1fr) auto minmax(4.75em, 1fr);
  align-items: center;
  gap: 0.75em;
  .house-button {
    width: 100%;
    font-size: 1.15em;
  }
  output {
    min-width: 2.6em;
    text-align: center;
    font-size: 1.75em;
    font-weight: 800;
    line-height: 1;
    font-variant-numeric: tabular-nums;
  }
}

/* ---- labelled totals for the kits ordered */
.totals {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  gap: 0.75em;
  > div {
    display: grid;
    gap: 0.2em;
  }
  > div:last-child {
    text-align: right;
  }
  > div > span {
    font-size: 0.8em;
    font-weight: 600;
  }
  strong {
    font-weight: 700;
    font-variant-numeric: tabular-nums;
  }
}

.signup-button {
  min-height: 2.9em;
  font-size: 1.05em;
}

.blocked-banner {
  padding: var(--inset);
  border-radius: var(--radius-panel);
  color: #ffd4a8;
  background: rgba(255, 120, 40, 0.12);
  box-shadow: inset 0 0 0 1px rgba(255, 160, 80, 0.45);
  font-weight: 700;
}

.result-grid {
  display: grid;
  grid-template-columns: repeat(2, 1fr);
  gap: 0.5em 1.1em;
  margin-top: 0.5em;
  font-variant-numeric: tabular-nums;
}

/* ---- intro */
.intro-copy {
  display: grid;
  gap: 0.5em;
  h2 {
    font-size: 1.35em;
  }
  p {
    color: var(--muted);
    line-height: 1.4;
  }
}

.intro-list {
  display: grid;
  gap: 0.5em;
  div {
    position: relative;
    padding-left: 1.1em;
  }
  div::before {
    content: "";
    position: absolute;
    left: 0;
    top: 0.5em;
    width: 0.44em;
    height: 0.44em;
    border-radius: 50%;
    background: var(--accent);
  }
}

// the game draws its own frame on a focused checkbox; the house ring (from .check) is the only one
.intro-check-box.focus-visible::before {
  display: none !important;
}

/* ---- accolades */
.claim-button {
  flex: 0 0 6.5em;
}

.accolade {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.75em;
  > div {
    flex: 1 1 auto;
    min-width: 0;
  }
  h2 {
    font-size: 1.1em;
  }
  .meter {
    margin: 0.5em 0 0.3em;
  }
}

.accolade-meta {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.75em;
  font-variant-numeric: tabular-nums;
  strong {
    color: var(--money);
    white-space: nowrap;
  }
}

@media (max-width: 720px) {
  .details-grid,
  .class-breakdown {
    grid-template-columns: 1fr;
  }

  .claim-button {
    flex-basis: auto;
  }

  .topbar,
  .accolade {
    align-items: stretch;
    flex-direction: column;
  }
}

/* Game currency glyph before amounts; inherits colour/size. */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
</style>
