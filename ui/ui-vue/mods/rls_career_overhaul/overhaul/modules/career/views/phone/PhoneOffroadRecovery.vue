<template>
  <div class="recovery-root">
    <main class="recovery-app" v-bng-ui-nav-scroll>
      <header class="summary">
        <div>
          <span class="eyebrow">Recovery level</span>
          <strong>{{ skillLevel }}</strong>
        </div>
        <div class="summary-right">
          <span>{{ activeCount }}/{{ maxActive }} active</span>
          <small>+{{ percent(payoutBonusPercent) }} cash</small>
        </div>
      </header>

      <section v-if="locked" class="notice locked">
        <strong>Contracts unavailable</strong>
        <p>{{ lockedReason }}</p>
      </section>

      <section v-if="activeJobs.length" class="section">
        <h2>Active recoveries</h2>
        <article v-for="job in activeJobs" :key="job.id" class="card active-card">
          <div class="card-top">
            <div>
              <span class="eyebrow">{{ phaseLabel(job) }}</span>
              <h3>{{ vehicleLabel(job) }}</h3>
            </div>
            <span class="reward" :class="job.rewardType"><span v-if="job.rewardType === 'vehicle'">VEHICLE</span><MoneyAmount v-else>{{ money(job.cashReward) }}</MoneyAmount></span>
          </div>
          <dl>
            <div><dt>Destination</dt><dd>{{ job.yardName }}</dd></div>
            <div><dt>Distance</dt><dd>{{ distance(job.distance) }}</dd></div>
          </dl>
          <p v-if="job.status === 'missing'" class="missing">Target missing. Abandon this recovery to clear it.</p>
          <div class="actions">
            <button type="button" :disabled="job.status === 'missing'" @click="track(job.id)">
              {{ job.tracked ? 'Tracking' : 'Track' }}
            </button>
            <button type="button" class="danger" @click="abandon(job)">Abandon</button>
          </div>
        </article>
      </section>

      <section class="section">
        <div class="section-heading">
          <h2>Available contracts</h2>
          <span>{{ offers.length }}/3</span>
        </div>
        <article v-for="offer in offers" :key="offer.id" class="card offer-card">
          <div class="card-top">
            <div>
              <span class="eyebrow">{{ offer.tierLabel || 'Recovery' }}</span>
              <h3>{{ vehicleLabel(offer) }}</h3>
            </div>
            <span class="reward" :class="offer.rewardType">
              <span v-if="offer.rewardType === 'vehicle'">VEHICLE</span><MoneyAmount v-else-if="offer.cashReward != null">{{ money(offer.cashReward) }}</MoneyAmount><span v-else>CASH</span>
            </span>
          </div>
          <dl>
            <div><dt>From you</dt><dd>{{ distance(offer.distance) }}</dd></div>
            <div><dt>Expires</dt><dd>{{ duration(offer.expiresIn) }}</dd></div>
          </dl>
          <div class="actions">
            <button type="button" class="secondary" @click="preview(offer.id)">Show on Map</button>
            <button type="button" :disabled="locked || activeCount >= maxActive" @click="accept(offer.id)">Accept</button>
          </div>
        </article>
        <div v-if="!offers.length" class="empty">
          <strong>No contracts on the board</strong>
          <span v-if="!locked">A new request is posted every five game minutes.</span>
        </div>
      </section>

      <section v-if="otherMapJobs.length" class="section muted-section">
        <h2>Recoveries on other maps</h2>
        <div v-for="job in otherMapJobs" :key="job.id" class="other-job">
          <span>{{ vehicleLabel(job) }}</span>
          <strong>{{ job.mapId }}</strong>
        </div>
      </section>
    </main>

    <div v-if="pendingOfferId" class="overlay">
      <section class="modal" v-bng-scoped-nav="modalScopes.yard" v-bc-modal-focus v-bng-on-ui-nav:back="closeTopLayer">
        <h2>Choose a Recovery Yard</h2>
        <p>The selected yard fixes the delivery route and payout.</p>
        <button v-for="yard in yardChoices" :key="yard.id" class="yard" type="button" @click="chooseYard(yard.id)">
          <span><strong>{{ yard.name }}</strong><small>{{ distance(yard.distance) }} recovery route</small></span>
          <b><span v-if="yard.rewardType === 'vehicle'">VEHICLE</span><MoneyAmount v-else>{{ money(yard.cashReward) }}</MoneyAmount></b>
        </button>
        <button type="button" bng-scoped-nav-autofocus class="cancel" @click="cancelYard">Cancel</button>
      </section>
    </div>

    <div v-if="jobToAbandon" class="overlay">
      <section class="modal" v-bng-scoped-nav="modalScopes.abandon" v-bc-modal-focus v-bng-on-ui-nav:back="closeTopLayer">
        <span class="eyebrow">Abandon recovery?</span>
        <h2>{{ vehicleLabel(jobToAbandon) }}</h2>
        <p>The contract and its recovery target will be removed. There is no penalty.</p>
        <button type="button" class="danger" @click="confirmAbandon">Abandon Recovery</button>
        <button type="button" bng-scoped-nav-autofocus class="cancel" @click="cancelAbandon">Keep Job</button>
      </section>
    </div>

    <div v-if="lastCompletion" class="overlay">
      <section class="modal completion" v-bng-scoped-nav="modalScopes.completion" v-bc-modal-focus v-bng-on-ui-nav:back="closeTopLayer">
        <span class="eyebrow">Recovery complete</span>
        <h2>{{ vehicleLabel(lastCompletion) }}</h2>
        <strong class="completion-reward">
          <span v-if="lastCompletion.rewardType === 'vehicle'">Vehicle awarded</span><MoneyAmount v-else>{{ money(lastCompletion.money) }}</MoneyAmount>
        </strong>
        <ul v-if="completionBreakdown.length" class="breakdown">
          <li
            v-for="(line, index) in completionBreakdown"
            :key="index"
            :class="{ total: line.isTotal, penalty: line.isPenalty }"
          >
            <span class="breakdown-label">{{ line.label }}</span>
            <span class="breakdown-value"><template v-if="line.money != null && line.xp == null"><template v-if="line.detail">{{ line.detail }}, </template><MoneyAmount>{{ breakdownValue(line) }}</MoneyAmount></template><template v-else>{{ breakdownValue(line) }}</template></span>
          </li>
        </ul>
        <p v-else>{{ lastCompletion.xp }} Recovery XP</p>
        <p v-if="!completionBreakdown.length">Damage penalty: {{ lastCompletion.penaltyPercent }}%</p>
        <button type="button" bng-scoped-nav-autofocus @click="clearCompletion">Done</button>
      </section>
    </div>
  </div>
</template>

<script setup>

import { vBngUiNavScroll } from '@/common/directives'
import { vBngScopedNav, vBngOnUiNav } from '@/common/directives'
import { vBcModalFocus } from '../../components/businessComputer/bcModalNav.js'
import { usePhoneAppLayers, usePhoneAppFocus } from './controllerLayers.js'
import MoneyAmount from "../../components/MoneyAmount.vue"
import { computed, onActivated, onDeactivated, onMounted, onUnmounted, ref } from 'vue'
import { lua, useBridge } from '@/bridge'
import { callModLua } from '../../utils/installLuaBridgeFallbacks'
import { acquireScope, releaseScope } from '../../utils/luaScopes'
import { reportUiFailure } from '../../utils/safeLua'

usePhoneAppFocus()


const { events } = useBridge()

const locked = ref(true)
const lockedReason = ref('')
const skillLevel = ref(1)
const payoutBonusPercent = ref(0)
const offers = ref([])
const activeJobs = ref([])
const otherMapJobs = ref([])
const activeCount = ref(0)
const maxActive = ref(3)
const pendingOfferId = ref(null)
const yardChoices = ref([])
const lastCompletion = ref(null)
const jobToAbandon = ref(null)
const { scopes: modalScopes, back: closeTopLayer } = usePhoneAppLayers({
  yard: { open: () => pendingOfferId.value, close: () => cancelYard() },
  abandon: { open: () => jobToAbandon.value, close: () => cancelAbandon() },
  completion: { open: () => lastCompletion.value, close: () => clearCompletion() },
})


function applyState(payload = {}) {
  locked.value = payload.locked ?? true
  lockedReason.value = payload.lockedReason || ''
  skillLevel.value = Number(payload.skillLevel) || 1
  payoutBonusPercent.value = Number(payload.payoutBonusPercent) || 0
  offers.value = Array.isArray(payload.offers) ? payload.offers : []
  activeJobs.value = Array.isArray(payload.activeJobs) ? payload.activeJobs : []
  otherMapJobs.value = Array.isArray(payload.otherMapJobs) ? payload.otherMapJobs : []
  activeCount.value = Number(payload.activeCount) || 0
  maxActive.value = Number(payload.maxActive) || 3
  pendingOfferId.value = payload.pendingOfferId || null
  yardChoices.value = Array.isArray(payload.yardChoices) ? payload.yardChoices : []
  lastCompletion.value = payload.lastCompletion || null
}

const completionBreakdown = computed(() => {
  const lines = lastCompletion.value?.breakdown
  return Array.isArray(lines) ? lines : []
})

const vehicleLabel = item => [item?.year, item?.brand, item?.name].filter(Boolean).join(' ')
const percent = value => `${Math.round((Number(value) || 0) * 100)}%`
const money = value => Math.round(Number(value) || 0).toLocaleString()
const distance = value => Number(value) < 1000 ? `${Math.round(Number(value) || 0)} m` : `${((Number(value) || 0) / 1000).toFixed(1)} km`
const duration = seconds => `${Math.max(0, Math.ceil((Number(seconds) || 0) / 60))} min`
const phaseLabel = job => job.status === 'missing' ? 'Target missing' : job.phase === 'delivery' ? 'Return to yard' : 'Find and extract'

function breakdownValue(line) {
  if (line?.xp != null) return `+${Math.round(Number(line.xp) || 0)}`
  if (line?.money != null) {
    const amount = Math.round(Number(line.money) || 0)
    return amount < 0 ? `−${Math.abs(amount).toLocaleString()}` : money(amount)
  }
  return line?.detail || ''
}

function accept(id) { callModLua('overhaul_jobs_recovery.beginAcceptOffer', id) }
function chooseYard(id) { callModLua('overhaul_jobs_recovery.selectRecoveryYard', id) }
function cancelYard() { callModLua('overhaul_jobs_recovery.cancelYardSelection') }
function preview(id) { callModLua('overhaul_jobs_recovery.previewOffer', id) }
function track(id) { callModLua('overhaul_jobs_recovery.trackJob', id) }
function clearCompletion() { callModLua('overhaul_jobs_recovery.clearCompletion') }
function abandon(job) { jobToAbandon.value = job }
function cancelAbandon() { jobToAbandon.value = null }
function confirmAbandon() {
  const jobId = jobToAbandon.value?.id
  jobToAbandon.value = null
  if (jobId) callModLua('overhaul_jobs_recovery.abandonJob', jobId)
}

let listening = false
let activation = 0

async function openRecovery() {
  if (listening) return
  listening = true
  const currentActivation = ++activation
  events.on('updateOffroadRecoveryState', applyState)
  try {
    await acquireScope(lua, 'phone.offroadRecovery')
    if (!listening || currentActivation !== activation) return
    await callModLua('overhaul_jobs_recovery.requestState')
  } catch (error) {
    reportUiFailure(error, '[PhoneOffroadRecovery] Failed to open recovery board')
  }
}

function closeRecovery() {
  if (!listening) return
  listening = false
  activation++
  events.off('updateOffroadRecoveryState', applyState)
  Promise.resolve(releaseScope(lua, 'phone.offroadRecovery')).catch(error =>
    reportUiFailure(error, '[PhoneOffroadRecovery] Failed to release recovery scope'))
}

onMounted(openRecovery)
onActivated(openRecovery)
onDeactivated(closeRecovery)
onUnmounted(closeRecovery)
</script>

<style scoped lang="scss">
.recovery-root { position: relative; height: 100%; }
.recovery-app {
  height: 100%;
  overflow-y: auto;
  box-sizing: border-box;
  padding: 48px 10px 20px;
  color: #f8f2e8;
  background: linear-gradient(180deg, #4c311d 0, #17130f 34%, #0b0b0a 100%);
  font-family: Overpass, sans-serif;
}

.summary, .card-top, .section-heading, .actions, .other-job, .yard {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
}

.summary {
  position: sticky;
  top: 0;
  z-index: 2;
  padding: 9px 11px;
  border: 1px solid rgba(255, 255, 255, 0.13);
  border-radius: 9px;
  background: rgba(15, 12, 9, 0.92);
}

.summary strong { display: block; font-size: 1.55rem; line-height: 1; }
.summary-right { text-align: right; font-weight: 700; }
.summary-right small { display: block; color: #d9b382; }
.eyebrow { color: #d8b184; font-size: .7rem; font-weight: 800; letter-spacing: .08em; text-transform: uppercase; }

.section { margin-top: 13px; }
.section h2 { margin: 0 0 7px; font-size: 1rem; }
.section-heading span { color: #c7b9a7; font-size: .82rem; }

.card, .notice, .empty, .other-job {
  margin-bottom: 8px;
  padding: 10px;
  border: 1px solid rgba(255, 255, 255, 0.12);
  border-radius: 9px;
  background: rgba(255, 255, 255, 0.075);
}

.card h3 { margin: 2px 0 0; font-size: 1.06rem; line-height: 1.15; }
.reward { padding: 5px 7px; border-radius: 6px; background: #285a37; color: #dff5e5; font-size: .75rem; font-weight: 900; }
.reward.vehicle { background: #8a5926; color: #fff0d7; }

dl { display: grid; grid-template-columns: 1fr 1fr; gap: 6px; margin: 9px 0; }
dl div { padding: 6px; border-radius: 6px; background: rgba(0, 0, 0, .22); }
dt { color: #aaa095; font-size: .68rem; text-transform: uppercase; }
dd { margin: 2px 0 0; font-size: .86rem; font-weight: 700; }

button {
  border: 0;
  border-radius: 7px;
  padding: 8px 11px;
  background: #c9772f;
  color: #fff;
  font: inherit;
  font-size: .82rem;
  font-weight: 800;
}
button:disabled { opacity: .4; }
.actions { justify-content: flex-end; }
.secondary, .cancel { background: rgba(255, 255, 255, .13); }
.danger { background: #823a32; }
.notice p, .modal p { margin: 5px 0 0; color: #cfc6bb; font-size: .84rem; line-height: 1.3; }
.locked { border-color: rgba(225, 162, 65, .45); background: rgba(116, 72, 18, .28); }
.empty { display: grid; gap: 4px; color: #bcb3aa; text-align: center; }
.missing { color: #ffb5a9; font-size: .78rem; }
.other-job { font-size: .8rem; }
.other-job strong { color: #b9aa98; }

.overlay {
  position: absolute;
  inset: 0;
  z-index: 10;
  display: grid;
  place-items: center;
  padding: 16px;
  background: rgba(0, 0, 0, .72);
}
.modal { width: 100%; max-height: 80%; overflow-y: auto; box-sizing: border-box; padding: 15px; border-radius: 12px; color: #f8f2e8; background: #201a14; box-shadow: 0 14px 45px #000; }
.modal h2 { margin: 0; font-size: 1.15rem; }
.yard { width: 100%; margin-top: 9px; text-align: left; background: #5d4126; }
.yard span { display: grid; gap: 2px; }
.yard small { color: #d5c5b3; font-weight: 500; }
.yard b { white-space: nowrap; }
.cancel { width: 100%; margin-top: 10px; }
.completion { text-align: center; }
.completion button { width: 100%; margin-top: 10px; }
.completion-reward { display: block; margin-top: 12px; font-size: 1.35rem; color: #e2bc88; }
.breakdown {
  list-style: none;
  margin: 12px 0 0;
  padding: 0;
  text-align: left;
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: 8px;
  overflow: hidden;
  background: rgba(0, 0, 0, 0.22);
}
.breakdown li {
  display: flex;
  justify-content: space-between;
  gap: 10px;
  padding: 8px 10px;
  border-top: 1px solid rgba(255, 255, 255, 0.06);
  font-size: 0.8rem;
}
.breakdown li:first-child { border-top: 0; }
.breakdown-label { color: #cfc6bb; }
.breakdown-value { color: #f3e7d6; font-weight: 700; text-align: right; }
.breakdown li.total .breakdown-label,
.breakdown li.total .breakdown-value { color: #e2bc88; font-weight: 800; }
.breakdown li.penalty .breakdown-value { color: #ffb5a9; }
</style>
