<template>
  <div class="cargo-app">
    <div class="app-header">
      <img
        class="cargo-logo"
        src="/ui/entrypoints/main/rls_career_overhaul/tiles/rls-vehicle-transfer-logo.png"
        alt="CarGo"
      />
    </div>

    <div class="status-panel">
      <div class="status-row">
        <span class="label">Status</span>
        <span class="value" :class="statusClass">{{ statusText }}</span>
      </div>
      <div class="status-row">
        <span class="label">Completed today</span>
        <span class="value">{{ state.completedTickets || 0 }}</span>
      </div>
    </div>

    <div class="job-panel" v-if="state.onShift && state.ticket">
      <div class="job-header">{{ ticketHeading }}</div>
      <div class="job-details">
        <div class="detail-row">
          <span class="detail-label">Vehicle</span>
          <span class="detail-value">{{ state.ticket.name || 'Transfer vehicle' }}</span>
        </div>
        <div class="detail-row">
          <span class="detail-label">Pickup</span>
          <span class="detail-value">{{ state.ticket.originLabel || state.ticket.originFacId || '—' }}</span>
        </div>
        <div class="detail-row">
          <span class="detail-label">Drop-off</span>
          <span class="detail-value">{{ state.ticket.destLabel || state.ticket.destFacId || '—' }}</span>
        </div>
        <div class="detail-row" v-if="state.ticket.rewardMoney">
          <span class="detail-label">Pay</span>
          <span class="detail-value">${{ formatMoney(state.ticket.rewardMoney) }}</span>
        </div>
      </div>
    </div>

    <div class="job-panel idle-panel" v-else-if="!state.onShift">
      <div class="job-header">Car Jockey</div>
      <p class="idle-copy">
        Start a day to pick up the nearest available lot vehicle and drive it to its destination.
        Pay settles on each drop-off. Keep going as long as you want.
      </p>
    </div>

    <div class="job-panel" v-else-if="state.onShift && state.canNextRun">
      <div class="job-header">Between transfers</div>
      <p class="idle-copy">
        Looking for the nearest available vehicle. End day anytime to stop.
      </p>
    </div>

    <p class="error-msg" v-if="state.lastError">{{ state.lastError }}</p>
    <p class="idle-copy" v-if="state.onShift">
      {{ state.endAfterCurrent
        ? 'Finish this delivery to end your day. No further vehicle will be assigned.'
        : 'End day cancels an unmoved, undamaged vehicle for free. Otherwise, finish your current delivery first.' }}
    </p>

    <div class="controls-container" data-tutorial-id="vehicle-transfer-controls">
      <button
        v-if="!state.onShift"
        class="action-button start-btn"
        :disabled="busy"
        @click="startDay"
      >
        {{ busy ? 'Starting…' : 'Start day' }}
      </button>

      <button
        v-if="state.onShift && state.canNextRun"
        class="action-button next-btn"
        :disabled="busy"
        @click="nextRun"
      >
        {{ busy ? 'Assigning…' : 'Find next' }}
      </button>

      <button
        v-if="state.canReportUndeliverable"
        class="action-button report-btn"
        :disabled="busy"
        @click="reportUndeliverable"
      >
        {{ busy ? 'Reporting…' : 'Report undeliverable' }}
      </button>

      <button
        v-if="state.onShift"
        class="action-button stop-btn"
        :disabled="busy || state.endAfterCurrent"
        @click="endDay"
      >
        {{ state.endAfterCurrent ? 'Ending after delivery' : busy ? 'Ending…' : 'End day' }}
      </button>
    </div>
  </div>
</template>

<script setup>
import { reportUiFailure } from "../../utils/safeLua"

import { computed, onMounted, onBeforeUnmount, ref } from 'vue'
import { lua, useBridge } from '@/bridge'
import { usePhoneTutorial } from '../../composables/usePhoneTutorial'
import { callModLua } from '../../utils/installLuaBridgeFallbacks'
import { acquireScope } from '../../utils/luaScopes'

const { events } = useBridge()
const { advanceNext, currentStep, finishTutorial } = usePhoneTutorial()
const busy = ref(false)
const state = ref({
  onShift: false,
  phase: 'idle',
  completedTickets: 0,
  canNextRun: false,
  canReportUndeliverable: false,
  endAfterCurrent: false,
  lastError: null,
  ticket: null,
})

const statusText = computed(() => {
  if (!state.value.onShift) return 'Offline'
  if (state.value.endAfterCurrent) return 'Final delivery'
  if (state.value.phase === 'activeTicket') {
    return state.value.ticket?.active ? 'On a transfer' : 'Staging transfer…'
  }
  if (state.value.phase === 'betweenRuns') return 'Looking for work…'
  return 'On shift'
})

const statusClass = computed(() => {
  if (!state.value.onShift) return 'text-muted'
  if (state.value.phase === 'activeTicket') return 'text-live'
  if (state.value.phase === 'betweenRuns') return 'text-ready'
  return 'text-live'
})

const ticketHeading = computed(() => {
  if (state.value.endAfterCurrent) return 'Final delivery'
  if (state.value.ticket?.active) return 'Current transfer'
  if (state.value.phase === 'activeTicket') return 'Assigning transfer'
  return 'Next transfer'
})

function formatMoney(val) {
  return Math.round(Number(val) || 0).toLocaleString()
}

function normalizeStatePayload(payload) {
  if (Array.isArray(payload)) {
    return payload.find((item) => item && typeof item === 'object' && !Array.isArray(item)) || null
  }
  if (payload && typeof payload === 'object') return payload
  return null
}

function applyState(payload) {
  const data = normalizeStatePayload(payload)
  if (!data) return
  state.value = {
    onShift: !!data.onShift,
    phase: data.phase || 'idle',
    completedTickets: Number(data.completedTickets) || 0,
    sessionMoney: Number(data.sessionMoney) || 0,
    canNextRun: !!data.canNextRun,
    canReportUndeliverable: !!data.canReportUndeliverable,
    endAfterCurrent: !!data.endAfterCurrent,
    lastError: data.lastError ?? null,
    ticket: data.ticket ?? null,
  }
}

async function ensureLoaded() {
  await acquireScope(lua, 'career.vehicleTransfer')
}

async function refresh() {
  try {
    await ensureLoaded()
    const next = await lua.overhaul_career_logistics_vehicleTransfer.requestState?.()
      ?? await lua.overhaul_career_logistics_vehicleTransfer.getUiState?.()
    applyState(next)
  } catch (e) {
    reportUiFailure(e, "Failed to load CarGo state (PhoneVehicleTransfer)")
  }
}

async function startDay() {
  busy.value = true
  try {
    await ensureLoaded()
    await lua.overhaul_career_logistics_vehicleTransfer.startDay()
    await refresh()
    if (!state.value.onShift) return
    if (currentStep.value) {
      await finishTutorial()
    }
    await callModLua('overhaul_phone_phone.closePhone')
  } catch (e) {
    reportUiFailure(e, "Failed to start CarGo day (PhoneVehicleTransfer)")
  } finally {
    busy.value = false
  }
}

async function nextRun() {
  busy.value = true
  try {
    await ensureLoaded()
    await lua.overhaul_career_logistics_vehicleTransfer.nextRun()
    await refresh()
  } catch (e) {
    reportUiFailure(e, "Failed to assign next transfer (PhoneVehicleTransfer)")
  } finally {
    busy.value = false
  }
}

async function endDay() {
  busy.value = true
  try {
    await ensureLoaded()
    await lua.overhaul_career_logistics_vehicleTransfer.endDay()
    await refresh()
  } catch (e) {
    reportUiFailure(e, "Failed to end CarGo day (PhoneVehicleTransfer)")
  } finally {
    busy.value = false
  }
}

async function reportUndeliverable() {
  busy.value = true
  try {
    await ensureLoaded()
    await lua.overhaul_career_logistics_vehicleTransfer.reportUndeliverable()
    await refresh()
  } catch (e) {
    reportUiFailure(e, "Failed to report CarGo vehicle (PhoneVehicleTransfer)")
  } finally {
    busy.value = false
  }
}

onMounted(() => {
  events.on('updateVehicleTransferState', applyState)
  refresh()
})

onBeforeUnmount(() => {
  events.off('updateVehicleTransferState', applyState)
})
</script>

<style scoped lang="scss">
.cargo-app {
  padding: 46px 10px 12px;
  height: 100%;
  display: flex;
  flex-direction: column;
  background: linear-gradient(180deg, #e8f1ff 0%, #d6e6ff 42%, #c5dbff 100%);
  color: #102a56;
  overflow-y: auto;
  box-sizing: border-box;
  font-size: 12px;
}

.app-header {
  display: flex;
  justify-content: center;
  margin-bottom: 8px;
}

.cargo-logo {
  width: min(100%, 168px);
  object-fit: contain;
}

.status-panel,
.job-panel {
  background: #fff;
  padding: 9px 10px;
  border-radius: 8px;
  box-shadow: 0 2px 8px rgba(11, 95, 255, 0.08);
  margin-bottom: 8px;
}

.status-row,
.detail-row {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  gap: 8px;
  margin-bottom: 4px;
  font-size: 0.85rem;

  &:last-child {
    margin-bottom: 0;
  }
}

.label,
.detail-label {
  font-weight: 600;
  color: #5a6f92;
  flex-shrink: 0;
}

.value,
.detail-value {
  font-weight: 700;
  text-align: right;
}

.job-header {
  font-size: 0.95rem;
  font-weight: 800;
  color: #102a56;
  margin-bottom: 6px;
  border-bottom: 2px solid #e8eef8;
  padding-bottom: 6px;
}

.idle-copy {
  margin: 0;
  color: #5a6f92;
  font-size: 0.82rem;
  line-height: 1.4;
}

.error-msg {
  margin: 0 0 8px;
  color: #c0392b;
  font-size: 0.78rem;
  font-weight: 600;
  text-align: center;
}

.controls-container {
  margin-top: auto;
  padding-top: 8px;
  padding-bottom: 16px;
  flex-shrink: 0;
  display: flex;
  flex-direction: column;
  gap: 6px;
}

.action-button {
  width: 100%;
  padding: 10px;
  border: none;
  border-radius: 8px;
  font-size: 0.95rem;
  font-weight: 700;
  cursor: pointer;

  &:disabled {
    opacity: 0.6;
    cursor: default;
  }

  &.start-btn,
  &.next-btn {
    background: #0b5fff;
    color: #fff;
  }

  &.stop-btn {
    background: #2f3542;
    color: #fff;
  }

  &.report-btn {
    background: #fff;
    color: #b44b16;
    border: 1px solid #d9783f;
  }
}

.text-muted { color: #8a9bb8; }
.text-ready { color: #0b5fff; }
.text-live { color: #0a8f4d; }
</style>
