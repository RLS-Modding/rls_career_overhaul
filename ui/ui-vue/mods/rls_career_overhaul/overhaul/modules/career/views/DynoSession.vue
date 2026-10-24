<template>
  <!-- Controller (no scope on this screen): each phase puts focus on its main action; B closes How It
       Works, else cancels the offer / finishes a completed session (inert while a pull is set up or running) -->
  <LayoutSingle class="dyno-layout">
    <!-- display: contents wrapper: the B handler sits on a plain element (on the LayoutSingle component
         it never fired in the Atlas and B fell through to the router) -->
    <div class="nav-root" v-bng-on-ui-nav:back.focusRequired="onBack">
    <BngCard class="dyno-card">
      <BngCardHeading>Dyno Session</BngCardHeading>

      <div class="dyno-body">
        <div class="vehicle-name">{{ sessionData.vehicleName || "Current Vehicle" }}</div>

        <p v-if="sessionData.phase === 'offer' || sessionData.phase === 'starting'" class="description">
          <template v-if="sessionData.ownerBenefit"><strong>Free — Owner benefit</strong>. Unlimited pulls.</template><template v-else>Run a three-pull dyno session for <strong><BngIcon class="cur" :type="icons.beamCurrency" />{{ sessionData.fee }}</strong>.</template> Your vehicle will be placed on the dyno, dyno hubs will be fitted to all wheels, and tire wear and thermals will be disabled for the session.
        </p>

        <fieldset v-if="sessionData.phase === 'offer' || sessionData.phase === 'starting'" class="hub-selector" :disabled="busy || sessionData.phase === 'starting'">
          <legend>Dyno Hub</legend>
          <label
            v-for="hub in sessionData.hubOptions || []"
            :key="hub.id"
            class="hub-option"
            :class="{ selected: selectedHubId === hub.id }"
          >
            <input v-model="selectedHubId" class="pad-check" type="radio" name="dyno-hub" :value="hub.id" />
            <span>
              <strong>{{ hub.label }}</strong>
              <small>{{ hub.description }}</small>
            </span>
          </label>
        </fieldset>

        <div v-if="sessionData.repairRequired && sessionData.repairQuote" class="session-panel repair-panel">
          <strong>Repair First to Start</strong>
          <small>Private repair only. Tire wear and flats are ignored and preserved.</small>
          <div class="panel-row">
            <span class="panel-label">Private Repair</span>
            <span class="panel-value"><BngIcon class="cur" :type="icons.beamCurrency" />{{ sessionData.repairQuote.repairCost }}</span>
          </div>
          <div class="panel-row">
            <span class="panel-label">Dyno Session</span>
            <span class="panel-value"><BngIcon class="cur" :type="icons.beamCurrency" />{{ sessionData.repairQuote.dynoFee }}</span>
          </div>
          <div class="panel-row">
            <span class="panel-label">Combined Total</span>
            <span class="panel-value"><BngIcon class="cur" :type="icons.beamCurrency" />{{ sessionData.repairQuote.totalCost }}</span>
          </div>
        </div>

        <p v-if="sessionData.statusText" class="status">
          {{ sessionData.statusText }}
        </p>

        <p v-if="sessionData.error" class="error">
          {{ sessionData.error }}
        </p>

        <div v-if="sessionData.phase === 'ready' || sessionData.phase === 'pulling'" class="session-panel">
          <div class="panel-row">
            <span class="panel-label">Session State</span>
            <span class="panel-value">{{ sessionData.phase === "pulling" ? "Armed" : "Ready" }}</span>
          </div>
          <div class="panel-row">
            <span class="panel-label">Dyno Hub</span>
            <span class="panel-value">{{ selectedHubLabel }}</span>
          </div>
          <div class="panel-row">
            <span class="panel-label">Dyno Stage</span>
            <span class="panel-value">{{ stageLabel }}</span>
          </div>
          <div class="panel-row">
            <span class="panel-label">Pulls Remaining</span>
            <span class="panel-value">{{ sessionData.unlimitedPulls ? "Unlimited pulls" : sessionData.pullsRemaining }}</span>
          </div>
          <div class="panel-row">
            <span class="panel-label">Pull Guide</span>
            <span class="panel-value">{{ guideText }}</span>
          </div>
          <div class="live-grid">
            <div class="metric-card">
              <span class="metric-label">RPM</span>
              <span class="metric-value">{{ liveRpm }}</span>
            </div>
            <div class="metric-card">
              <span class="metric-label">Wheel Power</span>
              <span class="metric-value">{{ livePower }}</span>
            </div>
            <div class="metric-card">
              <span class="metric-label">Wheel Torque</span>
              <span class="metric-value">{{ liveTorque }}</span>
            </div>
            <div class="metric-card">
              <span class="metric-label">Gear</span>
              <span class="metric-value">{{ liveGear }}</span>
            </div>
            <div class="metric-card">
              <span class="metric-label">Throttle</span>
              <span class="metric-value">{{ liveThrottle }}</span>
            </div>
          </div>
          <div class="panel-row">
            <span class="panel-label">Accepted Samples</span>
            <span class="panel-value">{{ sessionData.acceptedSampleCount || 0 }}</span>
          </div>
          <div class="panel-row">
            <span class="panel-label">Rejected Samples</span>
            <span class="panel-value">{{ sessionData.rejectedSampleCount || 0 }}</span>
          </div>
        </div>

        <div v-if="sessionData.phase === 'complete' && displayedResult" class="results-panel">
          <div class="result-card">
            <span class="result-label">Peak Power</span>
            <span class="result-value">{{ formattedPower }}</span>
            <span class="result-detail">{{ formattedPowerRpm }}</span>
          </div>
          <div class="result-card">
            <span class="result-label">Peak Torque</span>
            <span class="result-value">{{ formattedTorque }}</span>
            <span class="result-detail">{{ formattedTorqueRpm }}</span>
          </div>
          <div class="result-card">
            <span class="result-label">Pull Quality</span>
            <span class="result-value">{{ resultQualityLabel }}</span>
            <span class="result-detail">{{ resultSampleCounts }}</span>
          </div>
        </div>

        <div v-if="curvePoints" class="curve-panel">
          <div class="curve-legend">
            <span class="legend-current-power">Current Power</span>
            <span class="legend-current-torque">Current Torque</span>
            <span v-if="comparisonPull" class="legend-compare-power">Compared Power</span>
            <span v-if="comparisonPull" class="legend-compare-torque">Compared Torque</span>
          </div>
          <svg viewBox="0 0 320 120" preserveAspectRatio="none" class="curve-svg">
            <polyline class="primary-curve" :points="curvePoints" />
            <polyline class="primary-torque-curve" :points="torqueCurvePoints" />
            <polyline v-if="comparisonPowerCurvePoints" class="comparison-curve" :points="comparisonPowerCurvePoints" />
            <polyline v-if="comparisonTorqueCurvePoints" class="comparison-torque-curve" :points="comparisonTorqueCurvePoints" />
          </svg>
        </div>

        <div v-if="sessionData.phase === 'complete' && sessionData.savedPulls?.length" class="history-panel">
          <div class="history-heading">
            <div>
              <strong>Saved Pull History</strong>
              <small>Select one pull to overlay on the current result.</small>
            </div>
            <BngButton
              v-if="selectedComparisonId !== null"
              :accent="ACCENTS.secondary"
              @click="selectedComparisonId = null"
            >
              Clear Comparison
            </BngButton>
          </div>
          <div class="history-list">
            <label
              v-for="pull in sessionData.savedPulls"
              :key="pull.id"
              class="history-row"
              :class="{ selected: String(selectedComparisonId) === String(pull.id) }"
            >
              <input v-model="selectedComparisonId" class="pad-check" type="radio" name="dyno-comparison" :value="String(pull.id)" />
              <span class="history-details">
                <strong>{{ formatSavedPullDate(pull.savedAt) }}</strong>
                <small>{{ formatSavedPullSummary(pull) }}</small>
              </span>
              <BngButton :accent="ACCENTS.secondary" @click.prevent="handleDeleteSavedPull(pull)">Delete</BngButton>
            </label>
          </div>
        </div>

        <div v-if="qualityFlagLabels.length" class="warnings-panel">
          <span class="warnings-title">Warnings</span>
          <div class="warning-list">
            <span v-for="flag in qualityFlagLabels" :key="flag" class="warning-pill">{{ flag }}</span>
          </div>
        </div>

        <div class="button-row" v-if="sessionData.phase === 'offer' || sessionData.phase === 'starting'">
          <BngButton
            v-if="!sessionData.repairRequired"
            class="dk-primary"
            :accent="ACCENTS.main"
            :disabled="busy || !sessionData.canStart"
            :bng-no-nav="busy || !sessionData.canStart ? 'true' : null"
            @click="handleStartSession"
          >
            <template v-if="sessionData.ownerBenefit">Start Session — Free — Owner benefit</template>
            <template v-else>Start Session — <BngIcon class="cur" :type="icons.beamCurrency" />{{ sessionData.fee }}</template>
          </BngButton>
          <BngButton
            v-else
            class="dk-primary"
            :accent="ACCENTS.main"
            :disabled="busy || !sessionData.canRepairAndStart"
            :bng-no-nav="busy || !sessionData.canRepairAndStart ? 'true' : null"
            @click="handleRepairAndStart"
          >
            Private Repair &amp; Start — <BngIcon class="cur" :type="icons.beamCurrency" />{{ sessionData.repairQuote?.totalCost || 0 }}
          </BngButton>
          <BngButton
            :accent="ACCENTS.secondary"
            :disabled="busy"
            :bng-no-nav="busy ? 'true' : null"
            @click="handleLeaveSession"
          >
            Cancel
          </BngButton>
        </div>

        <div class="button-row" v-else-if="sessionData.phase === 'ready' || sessionData.phase === 'pulling'">
          <BngButton
            class="dk-primary"
            :accent="ACCENTS.main"
            :disabled="busy || sessionData.phase === 'pulling'"
            :bng-no-nav="busy || sessionData.phase === 'pulling' ? 'true' : null"
            @click="handleStartPull"
          >
            Arm Pull
          </BngButton>
          <BngButton
            v-if="sessionData.phase !== 'pulling'"
            :accent="ACCENTS.secondary"
            :disabled="busy"
            :bng-no-nav="busy ? 'true' : null"
            @click="openHowTo"
          >
            How It Works
          </BngButton>
          <BngButton
            :accent="ACCENTS.secondary"
            :disabled="busy || !sessionData.canOpenMaintenance"
            :bng-no-nav="busy || !sessionData.canOpenMaintenance ? 'true' : null"
            @click="handleOpenMaintenance"
          >
            Maintenance
          </BngButton>
          <BngButton
            :accent="ACCENTS.secondary"
            :disabled="busy || !sessionData.canOpenTuning"
            :bng-no-nav="busy || !sessionData.canOpenTuning ? 'true' : null"
            @click="handleOpenTuning"
          >
            Engine Tuning
          </BngButton>
          <BngButton
            :accent="ACCENTS.secondary"
            :disabled="busy || !sessionData.canLeave"
            :bng-no-nav="busy || !sessionData.canLeave ? 'true' : null"
            @click="handleLeaveSession"
          >
            Leave Session
          </BngButton>
        </div>

        <div class="button-row" v-else-if="sessionData.phase === 'complete'">
          <BngButton
            :accent="ACCENTS.secondary"
            :disabled="busy"
            :bng-no-nav="busy ? 'true' : null"
            @click="openHowTo"
          >
            How It Works
          </BngButton>
          <BngButton
            :accent="ACCENTS.secondary"
            :disabled="busy || !sessionData.canOpenMaintenance"
            :bng-no-nav="busy || !sessionData.canOpenMaintenance ? 'true' : null"
            @click="handleOpenMaintenance"
          >
            Maintenance
          </BngButton>
          <BngButton
            :accent="ACCENTS.secondary"
            :disabled="busy || !sessionData.canOpenTuning"
            :bng-no-nav="busy || !sessionData.canOpenTuning ? 'true' : null"
            @click="handleOpenTuning"
          >
            Engine Tuning
          </BngButton>
          <BngButton
            class="dk-save"
            :accent="ACCENTS.secondary"
            :disabled="busy || sessionData.currentResultSaved"
            :bng-no-nav="busy || sessionData.currentResultSaved ? 'true' : null"
            @click="handleSavePull"
          >
            {{ sessionData.currentResultSaved ? "Pull Saved" : "Save Pull" }}
          </BngButton>
          <BngButton
            class="dk-primary"
            :accent="ACCENTS.main"
            :disabled="busy || !sessionData.canRetry"
            :bng-no-nav="busy || !sessionData.canRetry ? 'true' : null"
            @click="handleRetryPull"
          >
            {{ sessionData.unlimitedPulls ? "Do Another Pull — Unlimited pulls" : sessionData.canRetry ? `Do Another Pull (${sessionData.pullsRemaining} remaining)` : "3 Pulls Used" }}
          </BngButton>
          <BngButton
            :accent="ACCENTS.secondary"
            :disabled="busy"
            :bng-no-nav="busy ? 'true' : null"
            @click="handleLeaveSession"
          >
            Done
          </BngButton>
        </div>
      </div>
    </BngCard>

    <!-- a trapping scope while open: focus on Got It, B / Start close it -->
    <div
      v-if="showHowTo"
      class="how-to-backdrop"
      v-bng-scoped-nav="{ activateOnMount: true, trapPolicy: 'always', canDeactivate: () => (closeHowTo(), false) }"
      v-bng-on-ui-nav:menu="closeHowTo"
      @click.self="closeHowTo">
      <div class="how-to-dialog" role="dialog" aria-modal="true" aria-labelledby="dyno-how-to-title">
        <h2 id="dyno-how-to-title">How to Run a Dyno Pull</h2>
        <ol>
          <li>Start the engine.</li>
          <li>Select a high forward gear suited to the vehicle—typically 3rd or 4th—and keep it in that gear.</li>
          <li>Press <strong>Arm Pull</strong>. Hold the selected gear steady for a moment.</li>
          <li>Apply at least <strong>90% throttle</strong>. Recording starts automatically.</li>
          <li>Hold the same gear and throttle through the pull. Lift below <strong>75% throttle</strong> to finish.</li>
        </ol>
        <p>Avoid shifting or braking while recording; either will be reported in the pull warnings.</p>
        <label class="how-to-preference">
          <input v-model="dontShowHowToAgain" class="pad-check" type="checkbox" />
          <span>Don't show this automatically again</span>
        </label>
        <div class="how-to-actions">
          <BngButton :accent="ACCENTS.main" bng-scoped-nav-autofocus @click="closeHowTo">Got It</BngButton>
        </div>
      </div>
    </div>
    </div>
  </LayoutSingle>
</template>

<script setup>
import { reportUiFailure } from "../utils/safeLua"

import { computed, onMounted, onUnmounted, ref, watch } from "vue"
import { lua, useBridge } from "@/bridge"
import { LayoutSingle } from "@/common/layouts"
import { BngButton, ACCENTS, BngCard, BngCardHeading, BngIcon, icons } from "@/common/components/base"
import { vBngOnUiNav, vBngScopedNav } from "@/common/directives"
import { openHouseConfirmation } from "../components/house/index.js"
import { refocusIfLost } from "../composables/useScreenEntryFocus"
import { callModLua } from "../utils/installLuaBridgeFallbacks"

const { units, events } = useBridge()

const HOW_TO_STORAGE_KEY = "rlsDynoHowToDismissedV1"
const busy = ref(false)
const showHowTo = ref(false)
const dontShowHowToAgain = ref(false)
const selectedComparisonId = ref(null)
const selectedHubId = ref("rls")
const sessionData = ref({
  ownerBenefit: false,
  unlimitedPulls: false,
  fee: 1000,
  pullLimit: 3,
  pullsUsed: 0,
  pullsRemaining: 3,
  phase: "offer",
  canStart: false,
  canRepairAndStart: false,
  repairRequired: false,
  repairQuote: null,
  canRetry: false,
  canOpenMaintenance: false,
  canOpenTuning: false,
  canLeave: true,
  vehicleName: "Current Vehicle",
  result: null,
  error: null,
  statusText: null,
  pullStage: null,
  liveSample: null,
  pullQuality: null,
  qualityFlags: {},
  acceptedSampleCount: 0,
  rejectedSampleCount: 0,
  selectedHubId: "rls",
  hubOptions: [],
  inventoryId: null,
  savedPulls: [],
  currentResultSaved: false,
})

let refreshTimer = null
let historyRefreshTimer = null
let active = false
let requestInFlight = false
let stateVersion = 0
let historyRevision
let historyVehicle
let hasSessionData = false
let sessionAvailable = true
let hubSelectionInitialized = false
let howToAutoShownThisSession = false

function howToWasDismissed() {
  try {
    return window.localStorage.getItem(HOW_TO_STORAGE_KEY) === "1"
  } catch (error) {
    return false
  }
}

function openHowTo() {
  dontShowHowToAgain.value = howToWasDismissed()
  showHowTo.value = true
}

function closeHowTo() {
  if (dontShowHowToAgain.value) {
    try {
      window.localStorage.setItem(HOW_TO_STORAGE_KEY, "1")
    } catch (error) { reportUiFailure(error, "close how to (DynoSession)") }
  }
  showHowTo.value = false
}

function scheduleHistoryRefresh() {
  if (!active || !hasSessionData || requestInFlight || historyRefreshTimer !== null) return
  const data = sessionData.value
  if (historyRevision === data.savedPullsRevision && historyVehicle === String(data.inventoryId)) return
  historyRefreshTimer = setTimeout(() => {
    historyRefreshTimer = null
    refreshSessionData(false)
  }, 0)
}

function applySessionData(payload) {
  if (!active || !payload || typeof payload !== "object") return
  const previous = sessionData.value
  let data = payload
  const sameVehicle = String(data.inventoryId) === String(previous.inventoryId)
  if (data.liveOnly) {
    data = { ...data, savedPulls: sameVehicle ? previous.savedPulls : [], hubOptions: previous.hubOptions }
  } else {
    historyRevision = data.savedPullsRevision
    historyVehicle = String(data.inventoryId)
  }
  if (sameVehicle && data.resultRevision != null && data.resultRevision === previous.resultRevision) {
    data = { ...data, result: previous.result }
  }
  sessionData.value = data
  hasSessionData = true
  ++stateVersion
  scheduleHistoryRefresh()
  const hubOptions = Array.isArray(data.hubOptions) ? data.hubOptions : []
  if (!hubSelectionInitialized || !hubOptions.some(hub => hub.id === selectedHubId.value)) {
    selectedHubId.value = data.selectedHubId || hubOptions[0]?.id || "rls"
    hubSelectionInitialized = true
  }
  if (!data.active) {
    howToAutoShownThisSession = false
  } else if (data.phase === "ready" && !howToAutoShownThisSession) {
    howToAutoShownThisSession = true
    if (!howToWasDismissed()) {
      dontShowHowToAgain.value = false
      showHowTo.value = true
    }
  }
  if (selectedComparisonId.value !== null && !data.savedPulls?.some(pull => String(pull.id) === String(selectedComparisonId.value))) {
    selectedComparisonId.value = null
  }
}

async function refreshSessionData(liveOnly = true) {
  if (!active || requestInFlight) return
  requestInFlight = true
  const version = stateVersion
  try {
    const data = await callModLua("overhaul_career_parts_dyno_dynoSession.requestSessionData", liveOnly)
    if (!active) return
    if (!data || typeof data !== "object") {
      sessionAvailable = false
      if (refreshTimer !== null) clearInterval(refreshTimer)
      refreshTimer = null
      return
    }
    if (!liveOnly && hasSessionData) {
      const current = sessionData.value
      // History refreshes must not rewind the phase or live sample received by event.
      if (String(data.inventoryId) === String(current.inventoryId) && data.savedPullsRevision >= current.savedPullsRevision) {
        applySessionData({ ...current, liveOnly: false, savedPullsRevision: data.savedPullsRevision, savedPulls: data.savedPulls, hubOptions: data.hubOptions })
      } else if (version === stateVersion) {
        applySessionData(data)
      }
    } else if (version === stateVersion) {
      applySessionData(data)
    }
  } catch (error) {
    reportUiFailure(error, "refresh dyno session")
  } finally {
    requestInFlight = false
    if (sessionAvailable) scheduleHistoryRefresh()
  }
}

function onHudShow(snapshot) {
  applySessionData(snapshot?.state)
}

const selectedHubLabel = computed(() => {
  const hubId = sessionData.value?.active ? sessionData.value?.selectedHubId : selectedHubId.value
  const option = sessionData.value?.hubOptions?.find(hub => hub.id === hubId)
  return option?.label || "Dyno Hub"
})

const displayedResult = computed(() => sessionData.value?.result || null)

const currentSample = computed(() => sessionData.value?.liveSample || sessionData.value?.result?.liveSample || null)

const stageNames = {
  armed: "Armed",
  ready: "Ready",
  recording: "Recording",
  finishing: "Finishing",
  complete: "Complete",
}

const stageLabel = computed(() => {
  const stage = sessionData.value?.pullStage || currentSample.value?.stage
  return stageNames[stage] || (stage ? String(stage) : "Ready")
})

const guideText = computed(() => {
  const stage = sessionData.value?.pullStage || currentSample.value?.stage
  if (stage === "armed") return "Hold the selected high gear steady."
  if (stage === "ready") return "Apply at least 90% throttle to start recording."
  if (stage === "recording") return "Hold gear and throttle; lift below 75% to finish."
  if (stage === "finishing") return "Processing pull."
  return "Start the engine, select a high gear, then arm the pull."
})

const liveRpm = computed(() => {
  const rpm = currentSample.value?.rpm
  return rpm == null ? "--" : String(Math.round(rpm))
})

const liveGear = computed(() => {
  const gear = currentSample.value?.gear
  return gear == null ? "--" : String(gear)
})

const liveThrottle = computed(() => {
  const throttle = currentSample.value?.throttle
  return throttle == null ? "--" : `${Math.round(throttle * 100)}%`
})

const livePower = computed(() => {
  const value = currentSample.value?.wheelPower
  return value == null ? "--" : units.buildString("power", value, 0)
})

const liveTorque = computed(() => {
  const value = currentSample.value?.wheelTorque
  if (value == null) return "--"

  try {
    return units.buildString("torque", value, 0)
  } catch (error) {
    return `${Math.round(value)} Nm`
  }
})

const formattedPower = computed(() => {
  const value = displayedResult.value?.peakPower
  return value == null ? "--" : units.buildString("power", value, 0)
})

const formattedPowerRpm = computed(() => {
  const value = displayedResult.value?.peakPowerRpm
  return value ? `at ${Math.round(value)} RPM` : "RPM unavailable"
})

const formattedTorque = computed(() => {
  const value = displayedResult.value?.peakTorque
  if (value == null) return "--"

  try {
    return units.buildString("torque", value, 0)
  } catch (error) {
    return `${Math.round(value)} Nm`
  }
})

const formattedTorqueRpm = computed(() => {
  const value = displayedResult.value?.peakTorqueRpm
  return value ? `at ${Math.round(value)} RPM` : "RPM unavailable"
})

const resultQualityLabel = computed(() => {
  const result = displayedResult.value
  if (!result) return "--"
  return result.valid ? "Clean" : "Invalid"
})

const resultSampleCounts = computed(() => {
  const result = displayedResult.value
  if (!result) return "--"
  return `${result.acceptedSampleCount || 0} accepted / ${result.rejectedSampleCount || 0} rejected`
})

const flagNames = {
  gearChanged: "Gear Change",
  neutralGear: "Neutral Or Reverse",
  throttleLift: "Throttle Lift",
  brakeInput: "Brake Input",
  noRpmClimb: "No RPM Climb",
  noUsablePower: "No Usable Power",
  insufficientData: "Insufficient Clean Data",
  timeout: "Timeout",
  unstableRpm: "Unstable RPM",
  powerSpike: "Power Spike",
  sustainedTorqueRoughness: "Sustained Torque Fluctuation",
}

const qualityFlagLabels = computed(() => {
  const flags = displayedResult.value?.qualityFlags || sessionData.value?.qualityFlags || {}
  if (Array.isArray(flags)) {
    return flags.map(flag => flagNames[flag] || String(flag))
  }

  return Object.keys(flags)
    .filter(flag => flags[flag])
    .map(flag => flagNames[flag] || flag)
})

const comparisonPull = computed(() => {
  if (selectedComparisonId.value === null) return null
  return sessionData.value?.savedPulls?.find(pull => String(pull.id) === String(selectedComparisonId.value)) || null
})

const graphRuns = computed(() => {
  const primary = displayedResult.value
  if (!primary?.curve?.length) return []
  const runs = [{ id: "primary", result: primary, primary: true }]
  if (comparisonPull.value?.curve?.length) {
    runs.push({ id: String(comparisonPull.value.id), result: comparisonPull.value, primary: false })
  }
  return runs
})

const graphScale = computed(() => {
  const points = graphRuns.value.flatMap(run => run.result.curve || [])
  if (!points.length) return null
  const minRpm = 1000
  const maxRpm = Math.max(minRpm + 500, Math.ceil(Math.max(...points.map(point => point.rpm || 0)) / 500) * 500)
  const maxValue = Math.max(...points.flatMap(point => [point.power || 0, point.torque || 0]), 1)
  return { minRpm, maxRpm, maxValue }
})

function pointsForCurve(curve, valueKey) {
  const scale = graphScale.value
  if (!scale || !curve?.length) return ""
  const rpmRange = Math.max(scale.maxRpm - scale.minRpm, 1)
  return curve
    .map(point => {
      const x = ((Math.max(scale.minRpm, point.rpm || 0) - scale.minRpm) / rpmRange) * 300 + 10
      const y = 110 - ((point[valueKey] || 0) / scale.maxValue) * 100
      return `${x.toFixed(1)},${y.toFixed(1)}`
    })
    .join(" ")
}

const curvePoints = computed(() => pointsForCurve(displayedResult.value?.curve || [], "power"))
const torqueCurvePoints = computed(() => pointsForCurve(displayedResult.value?.curve || [], "torque"))
const comparisonPowerCurvePoints = computed(() => pointsForCurve(comparisonPull.value?.curve || [], "power"))
const comparisonTorqueCurvePoints = computed(() => pointsForCurve(comparisonPull.value?.curve || [], "torque"))

function formatSavedPullDate(savedAt) {
  const timestamp = Number(savedAt)
  if (!Number.isFinite(timestamp) || timestamp <= 0) return "Saved Pull"
  return new Date(timestamp * 1000).toLocaleString()
}

function formatSavedPullSummary(pull) {
  return `${units.buildString("power", Number(pull?.peakPower) || 0, 0)} at ${Math.round(Number(pull?.peakPowerRpm) || 0)} RPM`
}

async function withBusy(action) {
  if (busy.value) return

  busy.value = true
  try {
    await action()
  } finally {
    busy.value = false
    await refreshSessionData()
  }
}

async function handleStartSession() {
  await withBusy(async () => {
    await lua.overhaul_career_parts_dyno_dynoSession.startSession(selectedHubId.value)
  })
}

async function handleRepairAndStart() {
  await withBusy(async () => {
    const revision = sessionData.value?.repairQuote?.revision
    if (revision != null) {
      await lua.overhaul_career_parts_dyno_dynoSession.repairAndStart(selectedHubId.value, String(revision))
    } else {
      await lua.overhaul_career_parts_dyno_dynoSession.repairAndStart(selectedHubId.value)
    }
  })
}

async function handleOpenMaintenance() {
  await withBusy(async () => {
    await lua.overhaul_career_parts_dyno_dynoSession.openMaintenance()
  })
}

async function handleOpenTuning() {
  await withBusy(async () => {
    await lua.overhaul_career_parts_dyno_dynoSession.openTuning()
  })
}

async function handleStartPull() {
  await withBusy(async () => {
    await lua.overhaul_career_parts_dyno_dynoSession.startPull()
  })
}

async function handleRetryPull() {
  await withBusy(async () => {
    await lua.overhaul_career_parts_dyno_dynoSession.retryPull()
  })
}

async function handleSavePull() {
  await withBusy(async () => {
    await lua.overhaul_career_parts_dyno_dynoSession.saveCurrentPull()
  })
}

async function handleDeleteSavedPull(pull) {
  if (!pull) return
  // house popup instead of window.confirm: it has pad focus and B = cancel
  const confirmed = await openHouseConfirmation("Delete saved pull", "Delete this saved dyno pull?", [
    { label: "Delete", value: true, extras: { destructive: true } },
    { label: "Cancel", value: false, extras: { cancel: true, default: true } },
  ])
  if (!confirmed) return
  if (String(selectedComparisonId.value) === String(pull.id)) {
    selectedComparisonId.value = null
  }
  await withBusy(async () => {
    await lua.overhaul_career_parts_dyno_dynoSession.deleteSavedPull(pull.id)
  })
}

async function handleLeaveSession() {
  await withBusy(async () => {
    await lua.overhaul_career_parts_dyno_dynoSession.leaveSession()
  })
}

// ---- controller
// each phase's main action (none while a pull runs: A must not land on Leave Session by accident)
const rowButton = sel => document.querySelector(`.dyno-card .button-row ${sel}:not([disabled])`)
function pickPhaseFocus() {
  const phase = sessionData.value?.phase
  if (phase === "pulling") return null
  if (phase === "complete") return rowButton(".dk-primary") || rowButton(".dk-save") || rowButton("button")
  return rowButton(".dk-primary") || rowButton("button")
}
// a phase change swaps the whole button row
watch(() => sessionData.value?.phase, () => refocusIfLost(pickPhaseFocus, { force: !showHowTo.value }), { flush: "post" })
// busy disables every button (bng-no-nav) under focus: return to the same one, else the phase action
let focusBeforeBusy = null
watch(busy, isBusy => {
  if (isBusy) focusBeforeBusy = document.activeElement
}, { flush: "pre" })
watch(busy, isBusy => {
  if (isBusy || showHowTo.value) return
  const prev = focusBeforeBusy
  focusBeforeBusy = null
  refocusIfLost(() => (prev && document.contains(prev) && !prev.disabled ? prev : pickPhaseFocus()))
}, { flush: "post" })
// How It Works unmounts with focus inside it
watch(showHowTo, open => {
  if (!open) refocusIfLost(pickPhaseFocus, { force: true })
}, { flush: "post" })

// (unscoped screen: stop the event, or it also reaches the game's global ui_router.back() fallback)
function onBack(event) {
  event?.stopPropagation?.()
  if (showHowTo.value) return closeHowTo()
  const phase = sessionData.value?.phase
  if (busy.value) return
  // offer: Cancel; complete: Done. Setting up / running a pull: B does nothing.
  if (phase === "offer" || phase === "complete") handleLeaveSession()
}

onMounted(async () => {
  active = true
  events.on("DynoSessionHudState", applySessionData)
  events.on("DynoSessionHudShow", onHudShow)
  await refreshSessionData(false)
  if (!active || !sessionAvailable) return
  refreshTimer = setInterval(() => refreshSessionData(true), 2000)
  // entry: the phase's main action (no scope here, so nothing would be focused)
  refocusIfLost(pickPhaseFocus)
})

onUnmounted(() => {
  active = false
  events.off("DynoSessionHudState", applySessionData)
  events.off("DynoSessionHudShow", onHudShow)
  if (historyRefreshTimer !== null) clearTimeout(historyRefreshTimer)
  historyRefreshTimer = null
  if (refreshTimer !== null) {
    clearInterval(refreshTimer)
    refreshTimer = null
  }
})
</script>

<style scoped lang="scss">
.dyno-layout {
  // scaled unit: the screen keeps the same share of the display at 720p..4K (rem/px-sized it shrank at 1440p),
  // still following the player's UI scale
  --rls-u: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  font-size: var(--rls-u, 1rem);
  display: flex;
  align-items: center;
  justify-content: center;
  height: 100%;
  color: white;
}

.dyno-card {
  font-size: inherit; // BngCard pins 1rem; take the scaled size from the layout
  max-width: calc(46 * var(--rls-u, 1rem));
  width: min(calc(46 * var(--rls-u, 1rem)), calc(100% - calc(2 * var(--rls-u, 1rem))));

  :deep(.card-cnt) {
    background: rgba(0, 0, 0, 0.82);
    border-radius: calc(0.5 * var(--rls-u, 1rem));
    padding: var(--rls-u, 1rem);
  }
}

.dyno-body {
  display: flex;
  flex-direction: column;
  gap: calc(0.85 * var(--rls-u, 1rem));
}

.vehicle-name {
  font-size: calc(1.05 * var(--rls-u, 1rem));
  font-weight: 600;
}

.description,
.status,
.error {
  margin: 0;
  line-height: 1.45;
}

.hub-selector {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(calc(13 * var(--rls-u, 1rem)), 1fr));
  gap: calc(0.65 * var(--rls-u, 1rem));
  margin: 0;
  padding: calc(0.75 * var(--rls-u, 1rem));
  border: 1px solid rgba(255, 255, 255, 0.14);
  border-radius: calc(0.5 * var(--rls-u, 1rem));

  legend {
    padding: 0 calc(0.35 * var(--rls-u, 1rem));
    font-weight: 700;
  }
}

.hub-option {
  display: flex;
  align-items: flex-start;
  gap: calc(0.6 * var(--rls-u, 1rem));
  padding: calc(0.7 * var(--rls-u, 1rem));
  border: 1px solid rgba(255, 255, 255, 0.14);
  border-radius: calc(0.45 * var(--rls-u, 1rem));
  cursor: pointer;

  &.selected {
    border-color: #f97316;
    background: rgba(249, 115, 22, 0.12);
  }

  span {
    display: flex;
    flex-direction: column;
    gap: calc(0.2 * var(--rls-u, 1rem));
  }

  small {
    color: rgba(255, 255, 255, 0.65);
  }
}

.status {
  color: rgba(255, 255, 255, 0.8);
}

.error {
  color: #ff8f8f;
}

.session-panel,
.warnings-panel,
.curve-panel,
.history-panel {
  border: 1px solid rgba(255, 255, 255, 0.12);
  border-radius: calc(0.5 * var(--rls-u, 1rem));
  padding: calc(0.85 * var(--rls-u, 1rem));
}

.session-panel,
.results-panel,
.warnings-panel {
  display: grid;
  gap: calc(0.75 * var(--rls-u, 1rem));
}

.panel-row {
  display: flex;
  justify-content: space-between;
  gap: var(--rls-u, 1rem);
}

.panel-label {
  opacity: 0.7;
}

.panel-value {
  font-weight: 600;
  text-align: right;
}

.live-grid,
.results-panel {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(calc(9 * var(--rls-u, 1rem)), 1fr));
  gap: calc(0.75 * var(--rls-u, 1rem));
}

.metric-card,
.result-card {
  display: flex;
  flex-direction: column;
  gap: calc(0.35 * var(--rls-u, 1rem));
  border: 1px solid rgba(255, 255, 255, 0.14);
  border-radius: calc(0.45 * var(--rls-u, 1rem));
  padding: calc(0.75 * var(--rls-u, 1rem));
}

.metric-label,
.result-label,
.result-detail {
  opacity: 0.72;
  font-size: calc(0.86 * var(--rls-u, 1rem));
}

.metric-value,
.result-value {
  font-size: calc(1.25 * var(--rls-u, 1rem));
  font-weight: 700;
}

.curve-panel {
  min-height: calc(8 * var(--rls-u, 1rem));
}

.curve-legend {
  display: flex;
  flex-wrap: wrap;
  justify-content: flex-end;
  gap: calc(0.75 * var(--rls-u, 1rem));
  margin-bottom: calc(0.35 * var(--rls-u, 1rem));
  font-size: calc(0.78 * var(--rls-u, 1rem));

  span::before {
    content: "";
    display: inline-block;
    width: calc(0.9 * var(--rls-u, 1rem));
    margin-right: calc(0.3 * var(--rls-u, 1rem));
    border-top: 2px solid currentColor;
    vertical-align: middle;
  }
}

.legend-current-power { color: #f97316; }
.legend-current-torque { color: #eef4ff; }
.legend-compare-power { color: #40d9d0; }
.legend-compare-torque { color: #8aa9ff; }

.curve-svg {
  width: 100%;
  height: calc(8 * var(--rls-u, 1rem));

  polyline {
    fill: none;
    stroke-width: 2;
  }

  .primary-curve {
    stroke: #f97316;
  }

  .primary-torque-curve {
    stroke: #eef4ff;
  }

  .comparison-curve {
    stroke: #40d9d0;
    stroke-dasharray: 6 4;
  }

  .comparison-torque-curve {
    stroke: #8aa9ff;
    stroke-dasharray: 3 4;
  }

}

.history-panel,
.history-list,
.history-details {
  display: flex;
  flex-direction: column;
  gap: calc(0.55 * var(--rls-u, 1rem));
}

.history-heading,
.history-row {
  display: flex;
  align-items: center;
  gap: calc(0.7 * var(--rls-u, 1rem));
}

.history-heading {
  justify-content: space-between;

  > div {
    display: flex;
    flex-direction: column;
    gap: calc(0.2 * var(--rls-u, 1rem));
  }

  small {
    color: rgba(255, 255, 255, 0.65);
  }
}

.history-row {
  padding: calc(0.6 * var(--rls-u, 1rem));
  border: 1px solid rgba(255, 255, 255, 0.12);
  border-radius: calc(0.45 * var(--rls-u, 1rem));
  cursor: pointer;

  &.selected {
    border-color: #40d9d0;
    background: rgba(64, 217, 208, 0.1);
  }
}

.history-details {
  flex: 1;

  small {
    color: rgba(255, 255, 255, 0.65);
  }
}

.warnings-title {
  font-weight: 700;
}

.warning-list {
  display: flex;
  flex-wrap: wrap;
  gap: calc(0.5 * var(--rls-u, 1rem));
}

.warning-pill {
  border: 1px solid rgba(255, 180, 90, 0.55);
  border-radius: calc(0.35 * var(--rls-u, 1rem));
  color: #ffd2a3;
  padding: calc(0.25 * var(--rls-u, 1rem)) calc(0.45 * var(--rls-u, 1rem));
  font-size: calc(0.86 * var(--rls-u, 1rem));
}

.button-row {
  display: flex;
  justify-content: flex-end;
  gap: calc(0.75 * var(--rls-u, 1rem));
  flex-wrap: wrap;
}

.nav-root {
  display: contents;
}

// native radios / checkboxes: the house ring for keyboard / controller focus
.pad-check {
  position: relative;
  &.focus-visible {
    outline: none;
    box-shadow: 0 0 0 1.5px rgba(14, 14, 16, 0.95), 0 0 0 3.5px var(--bng-orange-b400, #ff6600);
  }
  &.focus-visible::before {
    display: none !important;
  }
}

.how-to-backdrop {
  position: fixed;
  inset: 0;
  z-index: 1000;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: var(--rls-u, 1rem);
  background: rgba(0, 0, 0, 0.72);
}

.how-to-dialog {
  width: min(calc(34 * var(--rls-u, 1rem)), calc(100vw - calc(2 * var(--rls-u, 1rem))));
  padding: calc(1.25 * var(--rls-u, 1rem));
  border: 1px solid rgba(255, 255, 255, 0.2);
  border-radius: calc(0.55 * var(--rls-u, 1rem));
  background: #17191d;
  box-shadow: 0 calc(1.2 * var(--rls-u, 1rem)) calc(3 * var(--rls-u, 1rem)) rgba(0, 0, 0, 0.5);

  h2 {
    margin: 0 0 calc(0.85 * var(--rls-u, 1rem));
  }

  ol {
    margin: 0;
    padding-left: calc(1.35 * var(--rls-u, 1rem));
    line-height: 1.5;
  }

  p {
    margin: calc(0.85 * var(--rls-u, 1rem)) 0;
    color: rgba(255, 255, 255, 0.72);
    line-height: 1.4;
  }
}

.how-to-preference {
  display: flex;
  align-items: center;
  gap: calc(0.55 * var(--rls-u, 1rem));
  cursor: pointer;
}

.how-to-actions {
  display: flex;
  justify-content: flex-end;
  margin-top: var(--rls-u, 1rem);
}

/* game currency glyph in front of amounts; inherits colour and size */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
</style>
