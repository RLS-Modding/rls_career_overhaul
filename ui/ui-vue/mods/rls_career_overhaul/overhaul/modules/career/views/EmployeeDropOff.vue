<template>
  <LayoutSingle
    class="employee-drop-off-wrapper"
    v-bng-blur
    bng-ui-scope="employeeDropOff"
    v-bng-on-ui-nav:back,menu="close">
    <div class="rls-shell drop-shell">
      <BngCard class="rls-card">
        <BngCardHeading type="ribbon">
          <span class="hd-name">{{ heading }}</span>
          <span class="hd-status" :class="state.assignment?.loopComplete ? 'ok' : 'on'">{{ state.assignment?.loopComplete ? 'Loop done' : 'On shift' }}</span>
        </BngCardHeading>
        <div class="card-content" v-bng-ui-nav-scroll>
          <div v-if="heroVehicle" class="hero">
            <img :src="heroVehicle.thumbnail" :alt="heroVehicle.name" />
            <div class="hero-copy">
              <strong>{{ state.assignment?.label || 'Company delivery' }}</strong>
              <span>{{ heroVehicle.name }}<template v-if="state.employerName"> for {{ state.employerName }}</template></span>
            </div>
          </div>
          <div v-else class="block-head">
            <h3 class="block-title">{{ state.assignment?.label || 'Company delivery' }}</h3>
            <span v-if="state.employerName" class="hint">{{ state.employerName }}</span>
          </div>

          <div class="stats">
            <div class="stat money">
              <span class="stat-key">Today's wages</span>
              <span class="stat-value"><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(state.escrowMoney) }}</span>
            </div>
            <div class="stat money" v-if="bonusHeld > 0">
              <span class="stat-key">Demand bonus</span>
              <span class="stat-value"><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(bonusHeld) }}</span>
            </div>
            <div class="stat" v-if="repDeltaView">
              <span class="stat-key">Reputation</span>
              <span class="stat-value rep-delta">
                <span class="rep-gain" :class="{ down: repDeltaView.negative }">{{ repDeltaView.gain }}</span>
                <small class="rep-path">{{ repDeltaView.path }}</small>
              </span>
            </div>
            <div class="stat" v-else-if="Number.isFinite(Number(state.employerRepLevel))">
              <span class="stat-key">Reputation</span>
              <span class="stat-value">{{ state.employerRepLabel || 'Level ' + state.employerRepLevel }} <small v-if="state.employerRepLabel">Lv {{ state.employerRepLevel }}</small></span>
            </div>
            <div class="stat" v-if="parkingGrades">
              <span class="stat-key">Parking</span>
              <span class="stat-value">{{ parkingGrades }}</span>
            </div>
            <div class="stat warn" v-if="damageStatus">
              <span class="stat-key">Equipment damage</span>
              <span class="stat-value">{{ damageStatus.detail }}</span>
            </div>
          </div>

          <section v-if="escrowLegs.length" class="block">
            <div class="block-head">
              <div class="kicker">This shift</div>
              <span class="hint">Pay is held until the loop is finished</span>
            </div>
            <div class="ledger">
              <div v-for="(leg, index) in escrowLegs" :key="index" class="ledger-row" :class="{ damage: isDamageLeg(leg) }">
                <span>{{ leg.label }}</span>
                <strong :class="{ negative: leg.keep < 0, dim: !leg.keep && isDamageLeg(leg) }">
                  <template v-if="!leg.keep && isDamageLeg(leg)">—</template>
                  <template v-else>{{ leg.keep < 0 ? '-' : '' }}<BngIcon class="cur" :type="icons.beamCurrency" />{{ money(Math.abs(leg.keep || 0)) }}</template>
                </strong>
              </div>
            </div>
          </section>

          <p v-if="damageStatus && damageStatus.phase === 'warning'" class="note warn">Further incidents this shift dock held wages, then can end employment.</p>
          <p v-else-if="damageStatus && damageStatus.phase === 'dock'" class="note warn">Docks come out of this shift's held wages. One more this shift and you're fired.</p>

          <div class="actions">
            <p v-if="!confirmed" class="actions-note">XP and reputation apply when you drop off.</p>
            <p v-else class="actions-note">XP and reputation applied.</p>
            <button type="button" class="btn" bng-nav-item @click="close"><BngBinding class="btn-glyph" ui-event="back" controller track-ignore />Close</button>
            <button v-if="state.assignment?.canEndDay && (state.assignment?.loopComplete || state.assignment?.canNextRun)" type="button" class="btn" bng-nav-item @click="endDay">End day</button>
            <!-- the main action takes focus on entry (and after a refresh removed it), hence the A glyph -->
            <button v-if="state.assignment?.canNextRun" type="button" class="btn btn-primary" bng-nav-item @click="nextRun"><BngBinding class="btn-glyph" ui-event="ok" controller track-ignore />Next job</button>
            <button v-if="!confirmed && state.canConfirm && !state.assignment?.loopComplete && !state.assignment?.canNextRun" type="button" class="btn btn-primary" bng-nav-item @click="confirm"><BngBinding class="btn-glyph" ui-event="ok" controller track-ignore />Drop off load</button>
          </div>
        </div>
      </BngCard>
    </div>
  </LayoutSingle>
</template>

<script setup>
import { reportUiFailure } from "../utils/safeLua"

import { computed, ref, onMounted, onBeforeUnmount, watch } from 'vue'
import { LayoutSingle } from "@/common/layouts"
import { BngCard, BngCardHeading, BngIcon, BngBinding, icons } from '@/common/components/base'
import { vBngBlur, vBngOnUiNav, vBngUiNavScroll } from '@/common/directives'
import { useUINavScope } from '@/services/uiNav'
import { lua, useBridge } from '@/bridge'
import { refocusIfLost } from '../composables/useScreenEntryFocus'

useUINavScope('employeeDropOff')

const props = defineProps({
  facilityId: String,
  parkingSpotPath: String,
})

const { events } = useBridge()
const state = ref({})
const confirmed = ref(false)

// Template puts the game currency glyph before it.
const money = (v) => Math.round(Number(v) || 0).toLocaleString('en-US')

const heading = computed(() => {
  if (state.value.assignment?.loopComplete) return 'Loop complete'
  if (state.value.assignment?.phase === 'return') return 'Return ready'
  return 'Delivery complete'
})

const heroVehicle = computed(() => {
  const list = Array.isArray(state.value.assignedVehicles) ? state.value.assignedVehicles : Object.values(state.value.assignedVehicles || {})
  return list.find(v => v && v.thumbnail) || null
})

const escrowLegs = computed(() => {
  const legs = state.value.escrowLegs
  return Array.isArray(legs) ? legs : []
})

const damageStatus = computed(() => state.value.damageStatus || null)
const bonusHeld = computed(() => Math.round(Number(state.value.surgeBonusHeld) || 0))
const parkingGrades = computed(() => {
  const levels = state.value.parkingLevels
  return Array.isArray(levels)
    ? levels.map(level => level.charAt(0).toUpperCase() + level.slice(1)).join(' / ')
    : ''
})

const formatScore = (v) => {
  const n = Math.round(Number(v) || 0)
  return n.toLocaleString('en-US')
}

const repDeltaView = computed(() => {
  const delta = state.value.repDelta
  if (!delta || !Number.isFinite(Number(delta.gain))) return null
  const gain = Math.round(Number(delta.gain) || 0)
  if (!gain) return null
  const beforeLabel = delta.beforeLabel || null
  const afterLabel = delta.afterLabel || beforeLabel
  const rankChanged = beforeLabel && afterLabel && beforeLabel !== afterLabel
  const beforeScore = formatScore(delta.before)
  const afterScore = formatScore(delta.after)
  const path = rankChanged
    ? `${beforeLabel} → ${afterLabel}`
    : afterLabel
      ? `${afterLabel}  ${beforeScore} → ${afterScore}`
      : `${beforeScore} → ${afterScore}`
  return {
    gain: gain > 0 ? `+${formatScore(gain)}` : formatScore(gain),
    path,
    negative: gain < 0,
  }
})

const isDamageLeg = (leg) => {
  const kind = leg?.kind
  if (kind === 'damageDock' || kind === 'damageWarning') return true
  const label = String(leg?.label || '').toLowerCase()
  return label.includes('damage')
}

const refresh = async () => {
  try {
    state.value = await lua.overhaul_career_work_employment.getDropOffUiState() || {}
  } catch (e) {
    reportUiFailure(e, "Failed to load employee drop-off (EmployeeDropOff)")
  }
}

const confirm = async () => {
  const ok = await lua.overhaul_career_work_employment.confirmEmployeeDropOff(props.facilityId, props.parkingSpotPath)
  if (ok) {
    confirmed.value = true
    await refresh()
    return
  }
  await refresh()
}

const nextRun = async () => {
  await lua.overhaul_career_work_employment.startNextRun(props.facilityId)
  await refresh()
}

const endDay = async () => {
  await lua.overhaul_career_work_employment.endDay(props.facilityId)
  await refresh()
}

const close = () => {
  lua.overhaul_career_work_employment.closeDropOffUi()
}

// Controller: no scoped-nav scope here, so focus the main action (Drop off load / Next job, else Close)
// on entry and whenever a refresh swapped the focused button out (Drop off load disappears once done).
const pickMainAction = () => {
  const root = document.querySelector('.employee-drop-off-wrapper')
  return root?.querySelector('.actions .btn-primary') || root?.querySelector('.actions .btn')
}
watch(state, () => refocusIfLost(pickMainAction), { flush: 'post' })

onMounted(() => {
  lua.overhaul_career_logistics_general.setDeliveryTimePaused(true)
  refresh()
  events.on('employmentUpdated', refresh)
})

onBeforeUnmount(() => {
  events.off('employmentUpdated', refresh)
})
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsCard.scss" as *;

.btn-glyph { margin-right: 0.4em; vertical-align: -0.15em; }
.employee-drop-off-wrapper { color: white; }
.drop-shell { width: min(40em, 100%); }
.rep-delta {
  display: flex;
  flex-direction: column;
  align-items: flex-end;
  gap: 0.15em;
  line-height: 1.15;
}
.rep-gain { font-variant-numeric: tabular-nums; }
.rep-gain.down { color: #f0a0a0; }
.rep-path {
  font-size: 0.72em;
  font-weight: 500;
  opacity: 0.72;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
}

/* Game currency glyph before amounts; inherits colour/size. */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
</style>
