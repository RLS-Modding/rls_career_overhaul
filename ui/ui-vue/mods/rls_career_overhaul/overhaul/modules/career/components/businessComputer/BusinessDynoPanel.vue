<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <section v-if="skillsStore.hasDynoUpgrade" class="business-dyno-panel">
    <header class="performance-header">
      <span class="caption">Performance</span>
      <div class="seg bar view-toggles">
        <button type="button" :class="{ active: viewMode === 'stats' }" :disabled="!hasDynoData" :bng-no-nav="(!hasDynoData) ? 'true' : null" @click="viewMode = 'stats'">
          Stats
        </button>
        <button type="button" :class="{ active: viewMode === 'dyno' }" :disabled="!hasCurveData" :bng-no-nav="(!hasCurveData) ? 'true' : null" @click="viewMode = 'dyno'">
          Dyno
        </button>
      </div>
    </header>

    <!-- before -> after; the change only gets colour when something actually moved -->
    <div v-if="hasDynoData && viewMode === 'stats'" class="stats-container">
      <div v-for="row in statRows" :key="row.label" class="stat-row">
        <span class="stat-label">{{ row.label }}</span>
        <span class="stat-before">{{ row.before }}</span>
        <svg class="stat-arrow" viewBox="0 0 24 24" aria-hidden="true"><path d="M5 12h14M13 6l6 6-6 6" /></svg>
        <span class="stat-after">{{ row.after }}</span>
        <span class="stat-delta" :class="row.tone">{{ row.delta }}</span>
      </div>
    </div>

    <div v-else-if="hasCurveData && viewMode === 'dyno'" class="dyno-wrap">
    <div class="dyno-container">
      <svg class="dyno-graph" viewBox="0 0 300 140" preserveAspectRatio="xMidYMid meet"
        @mousemove="handleGraphMouseMove" @mouseleave="graphHover = null">
        <line v-for="y in [30, 60, 90]" :key="y" x1="30" :y1="y" x2="270" :y2="y"
          stroke="rgba(255,255,255,0.1)" stroke-width="1" />

        <text x="25" y="34" text-anchor="end">{{ torqueVal(maxTorque * 0.75) }}</text>
        <text x="25" y="64" text-anchor="end">{{ torqueVal(maxTorque * 0.5) }}</text>
        <text x="25" y="94" text-anchor="end">{{ torqueVal(maxTorque * 0.25) }}</text>
        <text class="power-axis" x="275" y="34">{{ powerVal(maxPower * 0.75) }}</text>
        <text class="power-axis" x="275" y="64">{{ powerVal(maxPower * 0.5) }}</text>
        <text class="power-axis" x="275" y="94">{{ powerVal(maxPower * 0.25) }}</text>
        <text x="30" y="135">0</text>
        <text x="150" y="135" text-anchor="middle">{{ rounded(maxRpm * 0.5) }}</text>
        <text x="270" y="135" text-anchor="end">{{ rounded(maxRpm) }}</text>

        <path v-if="originalTorquePath" :d="originalTorquePath" class="curve torque original" />
        <path v-if="originalPowerPath" :d="originalPowerPath" class="curve power original" />
        <path v-if="torquePath" :d="torquePath" class="curve torque" />
        <path v-if="powerPath" :d="powerPath" class="curve power" />

        <g v-if="graphHover">
          <line :x1="graphHover.x" y1="0" :x2="graphHover.x" y2="120"
            stroke="rgba(255,255,255,0.5)" stroke-dasharray="4" />
          <rect :x="graphHover.tooltipX" y="10" width="110" height="48" rx="4"
            fill="rgba(0,0,0,0.92)" stroke="rgba(255,255,255,0.2)" />
          <text class="tooltip power-axis" :x="graphHover.tooltipX + 55" y="25" text-anchor="middle">
            {{ powerVal(graphHover.power) }} {{ powerUnit }}
            <tspan v-if="graphHover.originalPower"> ({{ powerVal(graphHover.originalPower) }})</tspan>
          </text>
          <text class="tooltip" :x="graphHover.tooltipX + 55" y="39" text-anchor="middle">
            {{ torqueVal(graphHover.torque) }} {{ torqueUnit }}
            <tspan v-if="graphHover.originalTorque"> ({{ torqueVal(graphHover.originalTorque) }})</tspan>
          </text>
          <text class="tooltip rpm" :x="graphHover.tooltipX + 55" y="52" text-anchor="middle">
            @ {{ rounded(graphHover.rpm) }} RPM
          </text>
        </g>
        <rect width="300" height="140" fill="transparent" />
      </svg>
    </div>
    <div class="dyno-legend">
      <span><i class="key power" />Power, {{ powerUnit }}</span>
      <span><i class="key torque" />Torque, {{ torqueUnit }}</span>
      <span><i class="key before" />Before</span>
    </div>
    </div>

    <div v-else class="dyno-placeholder">
      <span class="hint">Waiting for dyno data…</span>
      <HouseButton compact variant="quiet" :icon="icons.sync" @click="requestDynoData">Refresh dyno</HouseButton>
    </div>
  </section>
</template>

<script setup>
import { computed, onBeforeUnmount, onMounted, ref } from "vue"
import { icons } from "@/common/components/base"
import { HouseButton } from "../house/index.js"
import { useEvents } from "@/services/events"
import { useBridge } from "@/bridge"
import { useBusinessSkillsStore } from "../../stores/businessComputer/businessSkillsStore.js"
import { useBusinessTuningStore } from "../../stores/businessComputer/businessTuningStore.js"
import { dynoPowerToPs } from "../../utils/units"

const skillsStore = useBusinessSkillsStore()
const tuningStore = useBusinessTuningStore()
const events = useEvents()
const viewMode = ref("stats")
const graphHover = ref(null)
const torqueData = ref([])
const powerData = ref([])
const originalTorqueData = ref([])
const originalPowerData = ref([])
const maxRpmValue = ref(0)

const { units } = useBridge()
const rounded = value => Math.round(Number(value) || 0)
// dyno power is metric hp (PS; watts above 10000), torque Nm, weight kg: shown in the player's units
const dynoPowerPs = value => {
  const power = Number(value)
  if (!Number.isFinite(power)) return 0
  return dynoPowerToPs(power)
}
const powerVal = ps => rounded(units.power(Number(ps) || 0)?.val ?? ps)
const torqueVal = nm => rounded(units.torque(Number(nm) || 0)?.val ?? nm)
const weightVal = kg => rounded(units.weight(Number(kg) || 0)?.val ?? kg)
const powerUnit = computed(() => units.power(1)?.unit || "PS")
const torqueUnit = computed(() => units.torque(1)?.unit || "Nm")
const weightUnit = computed(() => units.weight(1)?.unit || "kg")
const ratio = (power, weight) => {
  const p = Number(power)
  const w = Number(weight)
  return Number.isFinite(p) && Number.isFinite(w) && w > 0 ? (p / w).toFixed(2) : "-"
}

// signed change with a unit; tone only when it moved (higher is better unless lowerIsBetter)
const change = (before, after, digits, unit, lowerIsBetter = false) => {
  const b = Number(before)
  const a = Number(after)
  if (!Number.isFinite(b) || !Number.isFinite(a)) return { delta: "", tone: "" }
  const d = a - b
  if (Math.abs(d) < Math.pow(10, -digits) / 2) return { delta: "", tone: "" }
  const better = lowerIsBetter ? d < 0 : d > 0
  return { delta: `${d > 0 ? "+" : "−"}${Math.abs(d).toFixed(digits)}${unit}`, tone: better ? "ok" : "bad" }
}
const statRows = computed(() => {
  const hpBefore = powerVal(dynoPowerPs(tuningStore.originalPower))
  const hpAfter = powerVal(dynoPowerPs(tuningStore.currentPower))
  const kgBefore = weightVal(tuningStore.originalWeight)
  const kgAfter = weightVal(tuningStore.currentWeight)
  const pwBefore = ratio(tuningStore.originalPower, tuningStore.originalWeight)
  const pwAfter = ratio(tuningStore.currentPower, tuningStore.currentWeight)
  return [
    { label: "Power", before: `${hpBefore} ${powerUnit.value}`, after: `${hpAfter} ${powerUnit.value}`, ...change(hpBefore, hpAfter, 0, "") },
    { label: "Weight", before: `${kgBefore} ${weightUnit.value}`, after: `${kgAfter} ${weightUnit.value}`, ...change(kgBefore, kgAfter, 0, "", true) },
    { label: "Power/weight", before: pwBefore, after: pwAfter, ...change(pwBefore, pwAfter, 2, "") },
  ]
})

const processCurveData = data => {
  if (!data) return null
  const curves = data.curves
    ? (Array.isArray(data.curves) ? data.curves : Object.values(data.curves))
    : (Array.isArray(data) ? data : [data])
  let bestCurve = null
  let highestPower = -1
  for (const curve of curves) {
    if (!curve?.power || !curve?.torque) continue
    const curvePower = Math.max(0, ...Object.values(curve.power).map(Number).filter(Number.isFinite))
    if (curvePower > highestPower) {
      highestPower = curvePower
      bestCurve = curve
    }
  }
  if (!bestCurve) return null
  const torque = Object.entries(bestCurve.torque)
    .map(([rpm, value]) => [Number(rpm), Number(value)])
    .filter(point => point.every(Number.isFinite))
    .sort((a, b) => a[0] - b[0])
  const power = Object.entries(bestCurve.power)
    .map(([rpm, value]) => {
      const raw = Number(value)
      return [Number(rpm), dynoPowerToPs(raw)]
    })
    .filter(point => point.every(Number.isFinite))
    .sort((a, b) => a[0] - b[0])
  return { torque, power, maxRpm: Number(data.maxRPM) || 8000 }
}

const applyCurve = (target, original = false) => {
  if (!target) return
  if (original) {
    originalTorqueData.value = target.torque
    originalPowerData.value = target.power
  } else {
    torqueData.value = target.torque
    powerData.value = target.power
    maxRpmValue.value = target.maxRpm
  }
}

const onTorqueCurveChanged = data => {
  const processed = processCurveData(data)
  if (!processed) return
  if (!tuningStore.originalCurveData) tuningStore.originalCurveData = data
  applyCurve(processCurveData(tuningStore.originalCurveData), true)
  applyCurve(processed)
}

const onPowerWeight = data => tuningStore.handlePowerWeightData(data)
const requestDynoData = () => {
  tuningStore.updatePowerWeight()
  if (window.bngApi) window.bngApi.activeObjectLua("controller.mainController.sendTorqueData()")
}

const hasDynoData = computed(() => tuningStore.originalPower != null && tuningStore.currentPower != null)
const hasCurveData = computed(() => torqueData.value.length > 0 || powerData.value.length > 0)
const maxRpm = computed(() => maxRpmValue.value || 8000)
const maxTorque = computed(() => Math.max(500, ...torqueData.value.map(p => p[1]), ...originalTorqueData.value.map(p => p[1])))
const maxPower = computed(() => Math.max(500, ...powerData.value.map(p => p[1]), ...originalPowerData.value.map(p => p[1])))

const graphPoints = points => points.map(([rpm, val]) => ({ rpm, val }))
const makePath = (points, maxValue) => {
  if (!points.length) return ""
  const scaleX = 240 / maxRpm.value
  const scaleY = 120 / (maxValue * 1.1)
  return points.map((point, index) => {
    const x = 30 + point.rpm * scaleX
    const y = 120 - point.val * scaleY
    return `${index ? "L" : "M"} ${x} ${y}`
  }).join(" ")
}

const torquePoints = computed(() => graphPoints(torqueData.value))
const powerPoints = computed(() => graphPoints(powerData.value))
const originalTorquePoints = computed(() => graphPoints(originalTorqueData.value))
const originalPowerPoints = computed(() => graphPoints(originalPowerData.value))
const torquePath = computed(() => makePath(torquePoints.value, maxTorque.value))
const powerPath = computed(() => makePath(powerPoints.value, maxPower.value))
const originalTorquePath = computed(() => makePath(originalTorquePoints.value, maxTorque.value))
const originalPowerPath = computed(() => makePath(originalPowerPoints.value, maxPower.value))

const closestPoint = (points, rpm) => points.reduce((closest, point) =>
  !closest || Math.abs(point.rpm - rpm) < Math.abs(closest.rpm - rpm) ? point : closest, null)

const handleGraphMouseMove = event => {
  const matrix = event.currentTarget.getScreenCTM()
  if (!matrix) return
  const point = event.currentTarget.createSVGPoint()
  point.x = event.clientX
  point.y = event.clientY
  const local = point.matrixTransform(matrix.inverse())
  const requestedRpm = Math.max(0, Math.min(maxRpm.value, ((local.x - 30) / 240) * maxRpm.value))
  const torque = closestPoint(torquePoints.value, requestedRpm)
  const power = closestPoint(powerPoints.value, requestedRpm)
  const originalTorque = closestPoint(originalTorquePoints.value, requestedRpm)
  const originalPower = closestPoint(originalPowerPoints.value, requestedRpm)
  const rpm = torque?.rpm ?? power?.rpm ?? 0
  const x = 30 + rpm * (240 / maxRpm.value)
  graphHover.value = {
    x,
    rpm,
    torque: torque?.val || 0,
    power: power?.val || 0,
    originalTorque: originalTorque?.val || 0,
    originalPower: originalPower?.val || 0,
    tooltipX: Math.max(0, Math.min(190, x - 55)),
  }
}

onMounted(() => {
  events.on("businessComputer:onVehiclePowerWeight", onPowerWeight)
  events.on("TorqueCurveChanged", onTorqueCurveChanged)
  requestDynoData()
})
onBeforeUnmount(() => {
  events.off("businessComputer:onVehiclePowerWeight", onPowerWeight)
  events.off("TorqueCurveChanged", onTorqueCurveChanged)
})
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

// Sits inside the house ShoppingCart (em-sized off its root): a quiet panel under the cart lines.
.business-dyno-panel {
  flex: 0 0 auto;
  display: grid;
  gap: 0.6em;
  margin: 0.4em var(--space-3) 0.2em;
  padding: 0.7em 0.8em 0.75em;
  border-radius: var(--radius-panel);
  background: var(--panel);
  color: #fff;
}
.performance-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.6em;
}
.view-toggles {
  font-size: 0.82em;
  button:disabled {
    opacity: 0.35;
    cursor: default;
  }
}

/* ---- before -> after */
.stats-container {
  display: grid;
  gap: 0.35em;
}
.stat-row {
  display: grid;
  grid-template-columns: minmax(0, 1fr) auto 0.9em auto 3.4em;
  align-items: baseline;
  column-gap: 0.5em;
  font-size: 0.9em;
  font-variant-numeric: tabular-nums;
}
.stat-label {
  min-width: 0;
  color: var(--muted);
  font-weight: 600;
}
.stat-before {
  color: var(--faint);
  font-weight: 600;
  text-align: right;
}
.stat-arrow {
  width: 0.9em;
  height: 0.9em;
  align-self: center;
  fill: none;
  stroke: var(--faint);
  stroke-width: 2.2;
  stroke-linecap: round;
  stroke-linejoin: round;
}
.stat-after {
  font-weight: 800;
  text-align: right;
}
.stat-delta {
  font-size: 0.88em;
  font-weight: 800;
  text-align: right;
  &.ok {
    color: var(--ok-ink);
  }
  &.bad {
    color: var(--bad);
  }
}

/* ---- dyno graph */
.dyno-wrap {
  display: grid;
  gap: 0.45em;
}
// keep the graph's own 300:140 proportions so curves and labels scale evenly (no squish)
.dyno-container {
  aspect-ratio: 300 / 140;
  overflow: hidden;
  border-radius: var(--radius-tile);
  background: rgba(0, 0, 0, 0.25);
}
.dyno-graph {
  display: block;
  width: 100%;
  height: 100%;
  cursor: crosshair;
}
.dyno-graph text {
  fill: rgba(255, 255, 255, 0.45);
  font-size: 10px;
}
.dyno-graph .power-axis {
  fill: var(--accent-soft);
}
.curve {
  fill: none;
  stroke-width: 2;
}
.curve.torque {
  stroke: rgba(255, 255, 255, 0.82);
}
.curve.power {
  stroke: var(--accent-soft);
}
.curve.original {
  opacity: 0.4;
  stroke-dasharray: 4;
}
.dyno-graph .tooltip {
  fill: rgba(255, 255, 255, 0.85);
}
.dyno-graph .tooltip.rpm {
  fill: rgba(255, 255, 255, 0.5);
  font-size: 9px;
}
.dyno-legend {
  display: flex;
  flex-wrap: wrap;
  gap: 0.3em 1em;
  color: var(--faint);
  font-size: 0.78em;
  font-weight: 700;
  span {
    display: inline-flex;
    align-items: center;
    gap: 0.4em;
  }
  .key {
    display: inline-block;
    width: 1.1em;
    height: 0;
    border-top: 2px solid;
    &.power {
      border-color: var(--accent-soft);
    }
    &.torque {
      border-color: rgba(255, 255, 255, 0.82);
    }
    &.before {
      border-top-style: dashed;
      border-color: rgba(255, 255, 255, 0.45);
    }
  }
}

.dyno-placeholder {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.5em;
}
</style>
