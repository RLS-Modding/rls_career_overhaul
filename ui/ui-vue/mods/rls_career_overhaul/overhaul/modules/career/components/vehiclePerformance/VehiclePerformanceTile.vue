<!-- RLS override of the vanilla VehiclePerformanceTile. Same data, events and lua calls; restyled to the
     house look. The class is the hero (big warm letter, PI, the class ladder and what the next classes
     need), the measured numbers come second, the technical specs are faint lines with plain icons. The
     hero and the body keep a fixed height so switching between assessments never moves the layout. -->
<template>
  <div class="rls-house perf-card" v-bng-blur="true">
    <div class="vehicle-content-wrapper scroll" v-bng-ui-nav-scroll.force>
      <!-- hero: class block (focal point) beside the vehicle photo -->
      <section class="perf-hero">
        <div class="class-block" :class="{ unrated: !selectedCertificationData.vehicleClass }">
          <span class="caption">{{ $t("ui.career.performance.title") }}</span>

          <template v-if="selectedCertificationData.vehicleClass">
            <div class="class-main">
              <span class="class-letter">{{ currentClassName }}</span>
              <div class="class-copy">
                <span class="pi-value">{{ piDisplay }}<small>{{ $t("ui.career.performance.indexLabelShort") }}</small></span>
                <span class="class-desc">{{ currentClassDescription }}</span>
              </div>
            </div>

            <!-- class ladder: one segment per class, the fill is the performance index -->
            <div class="ladder" :title="$translate.instant('ui.career.vehiclePerformance.title') + ' ' + piDisplay">
              <div class="ladder-track">
                <span
                  v-for="c in classLadder"
                  :key="c.name"
                  class="ladder-seg"
                  :class="{ current: c.name === currentClassName }"
                  :style="{ flexBasis: `${c.width}%` }"></span>
                <span class="ladder-fill" :style="{ transform: `scaleX(${piFill})` }"></span>
              </div>
              <div class="ladder-labels">
                <span
                  v-for="c in classLadder"
                  :key="c.name"
                  :class="{ current: c.name === currentClassName }"
                  :style="{ flexBasis: `${c.width}%` }">{{ c.name }}</span>
              </div>
            </div>

            <!-- what the next classes need -->
            <div class="next-list">
              <div v-for="(c, i) in nextClasses" :key="c.name" class="next-item" :class="{ first: i === 0 }">
                <span class="next-name">{{ c.name }}</span>
                <span class="next-bar"><span :style="{ transform: `scaleX(${c.pct})` }"></span></span>
                <span class="next-gap" :title="`${$t('ui.career.performance.indexLabelShort')} ${c.minPI}`">+{{ c.toGo }}</span>
              </div>
              <p v-if="!nextClasses.length" class="hint top-class">Top class</p>
            </div>
          </template>

          <template v-else>
            <div class="class-main">
              <span class="class-letter empty-letter">?</span>
              <div class="class-copy">
                <span class="class-desc">{{ $translate.instant("ui.career.vehiclePerformance.notAssessedYet") }}</span>
              </div>
            </div>
          </template>
        </div>

        <div class="hero-photo">
          <img v-if="thumbUrl && !thumbBroken" :src="thumbUrl" alt="" @error="thumbBroken = true" />
          <BngIcon v-else class="photo-empty" :type="icons.car" />
          <span v-if="sanctionedClass" class="photo-tag">{{ sanctionedClass }}</span>
          <div class="photo-copy">
            <strong>{{ title }}</strong>
          </div>
        </div>
      </section>

      <div class="certification-container">
        <template v-if="selectedCertificationData.vehicleClass">
          <!-- Performance Metrics: the measured numbers -->
          <section class="specs-section">
            <span class="caption">{{ $translate.instant("ui.career.vehiclePerformance.metrics") }}</span>
            <div class="metrics-grid">
              <div v-if="selectedCertificationData.power" class="metric">
                <span class="metric-key">{{ $translate.instant('ui.career.vehiclePerformance.powerOutput') }}</span>
                <span class="metric-value">{{ units.buildString('power', selectedCertificationData.power, 0) }}</span>
                <span class="metric-bar"><span :style="{ transform: `scaleX(${barPct(selectedCertificationData.power, 0, 1000)})` }"></span></span>
              </div>
              <div v-else class="metric missing">
                <span class="metric-key">{{ $translate.instant('ui.career.vehiclePerformance.powerOutput') }}</span>
                <span class="metric-value">{{ $translate.instant('ui.career.vehiclePerformance.notAvailable') }}</span>
              </div>

              <div class="metric" :title="$translate.instant('ui.career.vehiclePerformance.time060PreppedSurface')">
                <span class="metric-key">{{ $translate.instant('ui.career.performance.timeTo60Score') }}</span>
                <span class="metric-value">{{ selectedCertificationData.time_0_60 ? $translate.instant('ui.career.vehiclePerformance.timeSeconds', { time: selectedCertificationData.time_0_60.toFixed(2) }) : $translate.instant('ui.career.vehiclePerformance.notAvailable') }}</span>
                <span class="metric-bar"><span :style="{ transform: `scaleX(${barPct(selectedCertificationData.time_0_60 ? -selectedCertificationData.time_0_60 : -25, -25, -2)})` }"></span></span>
              </div>

              <div v-if="selectedCertificationData.time_1_4" class="metric">
                <span class="metric-key">{{ $translate.instant('ui.career.vehiclePerformance.quarterMile') }}</span>
                <span class="metric-value">{{ $translate.instant('ui.career.vehiclePerformance.quarterMileResult', { time: selectedCertificationData.time_1_4.toFixed(2), speed: units.buildString('speed', selectedCertificationData.velAt_1_4, 0) }) }}</span>
                <span class="metric-bar"><span :style="{ transform: `scaleX(${barPct(-selectedCertificationData.time_1_4, -35, -8.1)})` }"></span></span>
              </div>
              <div v-else class="metric missing">
                <span class="metric-key">{{ $translate.instant('ui.career.vehiclePerformance.quarterMile') }}</span>
                <span class="metric-value">{{ $translate.instant('ui.career.vehiclePerformance.notAvailable') }}</span>
              </div>

              <div v-if="selectedCertificationData.performanceAggregateScores.brakingGForceScore" class="metric">
                <span class="metric-key">{{ $translate.instant('ui.career.vehiclePerformance.brakingForce') }}</span>
                <span class="metric-value">{{ selectedCertificationData.brakingG ? $translate.instant('ui.career.vehiclePerformance.gForceValue', { value: selectedCertificationData.brakingG.toFixed(2) }) : $translate.instant('ui.career.vehiclePerformance.notAvailable') }}</span>
                <span class="metric-bar"><span :style="{ transform: `scaleX(${barPct(selectedCertificationData.brakingG || 0, 0.5, 1.9)})` }"></span></span>
              </div>
              <div v-else class="metric missing">
                <span class="metric-key">{{ $translate.instant('ui.career.vehiclePerformance.brakingForce') }}</span>
                <span class="metric-value">{{ $translate.instant('ui.career.vehiclePerformance.notAvailable') }}</span>
              </div>
            </div>
          </section>

          <!-- Technical Specifications: faint lines, plain icons, label as a quiet suffix -->
          <section class="specs-section">
            <span class="caption">{{ $translate.instant("ui.career.vehiclePerformance.technicalSpecifications") }}</span>
            <div class="specs-grid">
              <div class="spec">
                <BngIcon class="spec-icon" :type="icons.weight" />
                <span class="spec-value">{{ units.buildString('weight', selectedCertificationData.weight, 0) }}</span>
                <span class="spec-label">{{ $t('ui.options.units.weight') }}</span>
              </div>
              <div class="spec">
                <BngIcon class="spec-icon" :type="icons.powerGauge03" />
                <span class="spec-value">{{ $translate.instant("ui.career.vehiclePerformance.powerPerWeightValue", { value: selectedCertificationData.powerPerTon.toFixed(0) }) }}</span>
                <span class="spec-label">{{ $translate.instant("ui.career.performance.powerToWeightScore") }}</span>
              </div>
              <div class="spec">
                <BngIcon class="spec-icon" :type="icons.steeringWheelSporty" />
                <span class="spec-value">{{ $translate.instant("ui.career.vehiclePerformance.gForceValue", { value: selectedCertificationData.lateralGForce.toFixed(2) }) }}</span>
                <span class="spec-label">{{ $translate.instant("ui.career.vehiclePerformance.lateralGForce") }}</span>
              </div>
              <div class="spec">
                <BngIcon class="spec-icon" :type="icons.odometer" />
                <span class="spec-value">{{ units.buildString('length', selectedCertificationData.mileage, 0) }}</span>
                <span class="spec-label">{{ $translate.instant("ui.career.vehiclePerformance.mileage") }}</span>
              </div>
              <div class="spec">
                <BngIcon class="spec-icon" :type="icons.drivetrainGeneric" />
                <span class="spec-value">{{ selectedCertificationData.drivetrain }}</span>
                <span class="spec-label">{{ $t('vehicle.info.Drivetrain') }}</span>
              </div>
              <div class="spec">
                <BngIcon class="spec-icon" :type="icons.fuelPump" />
                <span class="spec-value">{{ selectedCertificationData.fuelType }}</span>
                <span class="spec-label">{{ $t('vehicle.info.Fuel Type') }}</span>
              </div>
              <div class="spec">
                <BngIcon class="spec-icon" :type="icons.engine" />
                <span class="spec-value">{{ selectedCertificationData.inductionType }}</span>
                <span class="spec-label">{{ $t('vehicle.info.Induction Type') }}</span>
              </div>
            </div>
          </section>
        </template>

        <div v-else class="body-empty">
          <BngIcon class="body-empty-glyph" :type="icons.drag01" />
          <span>No measurements yet</span>
        </div>
      </div>
    </div>

    <!-- footer: pick an assessment, run a new one (the one orange action) -->
    <div class="history-dropdown-container">
      <div class="dropdown">
        <span class="caption">{{ $translate.instant("ui.career.vehiclePerformance.previousAssessments") }}</span>
        <HouseMenu v-model="selectedHistoryIndex" :items="historyOptions" class="history-select" />
      </div>
      <HouseButton variant="primary" :icon="icons.drag01" @click="startTest()" :disabled="vehicleData.needsRepair || !vehicleData.owned">
        {{ startTestTitle }}
      </HouseButton>
    </div>
  </div>
</template>

<script setup>
import { computed, ref, watch } from "vue"
import { BngIcon, icons } from "@/common/components/base"
import { vBngBlur, vBngUiNavScroll } from "@/common/directives"
import { useBridge } from "@/bridge"
import { HouseButton, HouseMenu } from "../house/index.js"
import { formatSanctionedClassWithBucket } from "../../utils/sanctionedClassFormat"
import { $translate } from "@/services/translation"
const { units, lua } = useBridge()

const props = defineProps({
  vehicleData: Object,
})

const title = computed(() => props.vehicleData.niceName || $translate.instant("ui.common.unknown"))
const startTestTitle = computed(() =>
  props.vehicleData.needsRepair
    ? $translate.instant("ui.career.shared.assessPerformanceRepairRequired")
    : $translate.instant("ui.career.vehiclePerformance.assessPerformanceNow")
)

const certificationKeyMap = {
  'weight': "ui.options.units.weight",
  'power': "ui.options.units.power",
  'torque': "ui.options.units.torque",
}

const performanceKeyMap = {
  'quarterMileScore': "ui.career.performance.quarterMileScore",
  'powerToWeightScore': "ui.career.performance.powerToWeightScore",
  'timeTo60Score': "ui.career.performance.timeTo60Score",
  'brakingGForceScore': "ui.career.performance.brakingGForceScore",
  'speedProgressionScore': "ui.career.performance.speedProgressionScore"
}

const getTranslationKey = (key) => {
  return certificationKeyMap[key] || `ui.career.certification.${key}`
}

const getPerformanceTranslationKey = (key) => {
  return performanceKeyMap[key] || key
}

const startTest = function() {
  lua.overhaul_career_parts_vehiclePerformance.startDragTest()
}

const getColorForValue = (value, min = 0, max = 1) => {
  // Normalize value to 0-1 range using provided min/max
  const normalizedValue = (value - min) / (max - min)
  // Adjust the normalized value to start interpolation at 10%
  const adjustedValue = Math.max(0, normalizedValue - 0.1) * (1 / 0.9)

  let red, green
  if (adjustedValue < 0.5) {
    // Red to Yellow (20-60%)
    red = 200
    green = Math.round(200 * (adjustedValue * 2))
  } else {
    // Yellow to Green (60-100%)
    red = Math.round(200 * (2 - adjustedValue * 2))
    green = 200
  }

  return `rgb(${red}, ${green}, 0)`
}

const selectedHistoryIndex = ref(0)

const allCertificationData = computed(() => {
  // Create a list with current certification data at the beginning followed by performance history
  return [
    props.vehicleData.certificationData || { noPerformanceData: true }, // Add empty entry with current timestamp if undefined
    ...(props.vehicleData.performanceHistory || [])
  ]
})

const historyOptions = computed(() => {
  if (!allCertificationData.value.length) return []

  // Create options for dropdown
  return allCertificationData.value.map((item, index) => {
    const date = new Date(item.timeStamp).toLocaleString()
    return {
      value: index,
      label: index === 0
        ? (item.noPerformanceData
          ? $translate.instant("ui.career.vehiclePerformance.currentTestResultsNoData")
          : $translate.instant("ui.career.vehiclePerformance.currentTestResults", { date }))
        : $translate.instant("ui.career.vehiclePerformance.previousTestResults", { date }),
    }
  })
})

const emptyCertificationData = Object.freeze({ noPerformanceData: true })

const selectedCertificationData = computed(() => {
  return allCertificationData.value[selectedHistoryIndex.value] || emptyCertificationData
})

// Reset the selection when the available history shrinks (e.g. routeData is
// replaced on navigation) so the selected index never points past the list.
watch(allCertificationData, data => {
  if (selectedHistoryIndex.value >= data.length) {
    selectedHistoryIndex.value = 0
  }
})

// Class -> minPI mapping. Sampling the gradient at minPI / 110 gives the bar
// the same class-correlated color used by the threshold markers.
const classMinPiMap = { D: 0, C: 21, B: 41, A: 66, S: 86, X: 101 }

const performanceIndexBarColor = computed(() => {
  const vc = selectedCertificationData.value?.vehicleClass
  const minPi = classMinPiMap[vc?.class?.name]
  if (minPi === undefined) {
    return getColorForValue(vc?.performanceIndex / 110)
  }
  return getColorForValue(minPi / 110)
})

watch(() => props.vehicleData, (newVal) => {
}, { immediate: true })

// ---- RLS house layout helpers (display only) ----

// vehicle photo, cache-busted like the inventory tiles
const thumbBroken = ref(false)
const thumbUrl = computed(() => (props.vehicleData?.thumbnail ? `${props.vehicleData.thumbnail}?${props.vehicleData.dirtyDate}` : null))
watch(thumbUrl, () => (thumbBroken.value = false))

// the mod's sanctioned event class (same tag the inventory tiles show on the photo)
const sanctionedClass = computed(() => {
  const d = props.vehicleData
  if (!d) return null
  let pw = Number(d.powerPerWeight)
  if (!(Number.isFinite(pw) && pw > 0)) {
    const hp = Number(d.certificationData?.power)
    const kg = Number(d.certificationData?.weight)
    pw = Number.isFinite(hp) && hp > 0 && Number.isFinite(kg) && kg > 0 ? hp / kg : null
  }
  return formatSanctionedClassWithBucket(d.savedVehicleClassUi?.label || d.certificationData?.vehicleClass?.label, pw) || null
})

const PI_MAX = 110
const clamp01 = v => (Number.isFinite(v) ? Math.min(1, Math.max(0, v)) : 0)

// ladder segments, low to high, sized by their PI span on a 0..110 scale
const classLadder = Object.entries(classMinPiMap).map(([name, minPI], i, all) => {
  const nextMin = all[i + 1] ? all[i + 1][1] : PI_MAX
  return { name, minPI, width: ((nextMin - minPI) / PI_MAX) * 100 }
})

const currentClassName = computed(() => selectedCertificationData.value?.vehicleClass?.class?.name || "")
const currentClassDescription = computed(() => selectedCertificationData.value?.vehicleClass?.class?.description || "")
const piValue = computed(() => Number(selectedCertificationData.value?.vehicleClass?.performanceIndex))
const piDisplay = computed(() => (Number.isFinite(piValue.value) ? piValue.value.toFixed(0) : "-"))
const piFill = computed(() => clamp01(piValue.value / PI_MAX))

// the next two classes up: PI still needed and how far along the car is
const nextClasses = computed(() => {
  const pi = piValue.value
  if (!Number.isFinite(pi)) return []
  return classLadder
    .filter(c => c.minPI > pi)
    .slice(0, 2)
    .map(c => ({ ...c, toGo: Math.max(1, Math.ceil(c.minPI - pi)), pct: clamp01(pi / c.minPI) }))
})

const barPct = (value, min, max) => clamp01((value - min) / (max - min))
</script>

<style lang="scss" scoped>
@use "@/styles/modules/mixins" as *;
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

/* the card: near-black, centered by the view, em-sized off the view root */
.perf-card {
  display: flex;
  flex-direction: column;
  width: min(60em, 100%);
  max-height: 100%;
  min-height: 0;
  border-radius: 0.6em;
  overflow: hidden;
  background: rgba(var(--bng-off-black-rgb), 0.9);
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06), 0 14px 40px rgba(0, 0, 0, 0.45);
}

.vehicle-content-wrapper {
  flex: 1 1 auto;
  min-height: 0;
  display: flex;
  flex-direction: column;
  gap: 1em;
  padding: 1em 0.6em 1em 1em; /* right side leaves room for the slim scrollbar gutter */
  overscroll-behavior: contain;
}

/* ---- hero ---- */
.perf-hero {
  flex: 0 0 auto;
  display: grid;
  grid-template-columns: minmax(0, 1fr) minmax(0, 1.1fr);
  gap: 1em;
  height: 15.5em;
}

.class-block {
  display: flex;
  flex-direction: column;
  gap: 0.6em;
  min-width: 0;
  padding: 1em 1.1em 1em;
  border-radius: var(--radius-panel);
  background:
    radial-gradient(120% 60% at 0% 0%, rgba(255, 102, 0, 0.16), rgba(255, 102, 0, 0) 60%),
    var(--panel-2);
  box-shadow: inset 0 0 0 1px rgba(255, 178, 122, 0.16);
  &.unrated {
    background: var(--panel);
    box-shadow: none;
  }
}

.class-main {
  display: flex;
  align-items: center;
  gap: 0.7em;
  min-width: 0;
}

.class-letter {
  flex: 0 0 auto;
  min-width: 0.9em;
  font-size: 5.6em;
  font-weight: 900;
  line-height: 0.82;
  padding-top: 0.08em; /* Overpass caps sit high */
  text-align: center;
  color: var(--accent-soft);
  background: linear-gradient(180deg, #ffd9bd 0%, #ffb27a 45%, #ff7a1f 100%);
  -webkit-background-clip: text;
  background-clip: text;
  -webkit-text-fill-color: transparent;
  filter: drop-shadow(0 0 0.18em rgba(255, 102, 0, 0.35));
  &.empty-letter {
    background: none;
    -webkit-text-fill-color: var(--faint);
    color: var(--faint);
    filter: none;
  }
}

.class-copy {
  display: grid;
  gap: 0.2em;
  min-width: 0;
}
.pi-value {
  font-size: 2.3em;
  font-weight: 800;
  line-height: 1;
  font-variant-numeric: tabular-nums;
  small {
    margin-left: 0.25em;
    color: var(--faint);
    font-size: 0.42em;
    font-weight: 700;
    letter-spacing: 0.08em;
  }
}
.class-desc {
  color: var(--muted);
  font-size: 0.95em;
  font-weight: 600;
  line-height: 1.25;
}

/* class ladder: segments, PI fill on top, letters underneath */
.ladder {
  display: grid;
  gap: 0.3em;
  margin-top: auto;
}
.ladder-track {
  position: relative;
  display: flex;
  height: 0.6em;
  border-radius: 1em;
  overflow: hidden;
  background: rgba(255, 255, 255, 0.1);
}
/* segments sit over the fill; a dark notch marks each class threshold */
.ladder-seg {
  position: relative;
  z-index: 1;
  flex: 0 0 auto;
  min-width: 0;
  & + & {
    box-shadow: inset 0.15em 0 0 rgba(0, 0, 0, 0.6);
  }
  &.current {
    background: rgba(255, 178, 122, 0.14);
  }
}
.ladder-fill {
  position: absolute;
  inset: 0;
  z-index: 0;
  background: linear-gradient(90deg, rgba(255, 178, 122, 0.5), var(--accent));
  transform-origin: left center;
  transition: transform 0.45s cubic-bezier(0.2, 0.8, 0.2, 1);
}
.ladder-labels {
  display: flex;
  span {
    flex: 0 0 auto;
    min-width: 0;
    padding-left: 0.1em;
    color: var(--faint);
    font-size: 0.72em;
    font-weight: 700;
    line-height: 1;
    &.current {
      color: var(--accent-soft);
    }
  }
}

/* next classes: letter, progress, PI still needed */
.next-list {
  display: grid;
  gap: 0.35em;
  min-height: 2.6em;
}
.next-item {
  display: grid;
  grid-template-columns: 1.2em minmax(0, 1fr) 2.6em;
  align-items: center;
  gap: 0.6em;
  color: var(--faint);
  font-size: 0.9em;
  font-weight: 700;
  line-height: 1;
  &.first {
    color: #fff;
  }
}
.next-name {
  padding-top: 0.12em;
}
.next-bar {
  display: block;
  height: 0.4em;
  border-radius: 1em;
  overflow: hidden;
  background: rgba(255, 255, 255, 0.1);
  span {
    display: block;
    height: 100%;
    border-radius: inherit;
    background: rgba(255, 255, 255, 0.45);
    transform-origin: left center;
    transition: transform 0.45s cubic-bezier(0.2, 0.8, 0.2, 1);
  }
}
.next-item.first .next-bar span {
  background: rgba(255, 178, 122, 0.8);
}
.next-gap {
  padding-top: 0.12em;
  text-align: right;
  font-variant-numeric: tabular-nums;
}
.top-class {
  align-self: center;
}

/* photo: 16:9 inside the fixed hero, name over a bottom scrim */
.hero-photo {
  position: relative;
  min-width: 0;
  height: 100%;
  border-radius: var(--radius-panel);
  overflow: hidden;
  background: var(--photo);
  display: grid;
  place-items: center;
  img {
    position: absolute;
    inset: 0;
    width: 100%;
    height: 100%;
    object-fit: cover;
  }
  &::after {
    content: "";
    position: absolute;
    inset: 0;
    background: linear-gradient(to top, rgba(21, 21, 23, 0.9) 0%, rgba(21, 21, 23, 0.35) 30%, rgba(21, 21, 23, 0) 55%);
    pointer-events: none;
  }
}
.photo-empty {
  font-size: 4em;
  color: rgba(255, 255, 255, 0.18);
}
.photo-tag {
  position: absolute;
  z-index: 1;
  top: 0.55em;
  left: 0.55em;
  padding: 0.4em 0.5em 0.15em;
  border-radius: var(--radius-pill);
  background: rgba(21, 21, 23, 0.78);
  color: rgba(255, 255, 255, 0.85);
  font-size: 0.74em;
  font-weight: 700;
  line-height: 1;
}
.photo-copy {
  position: absolute;
  z-index: 1;
  left: 0.85em;
  right: 0.85em;
  bottom: 0.65em;
  // bottom-anchored over the photo, so a second line grows upwards into the shade; then ellipsis
  strong {
    display: -webkit-box;
    -webkit-box-orient: vertical;
    -webkit-line-clamp: 2;
    overflow: hidden;
    overflow-wrap: anywhere;
    font-size: 1.3em;
    font-weight: 800;
    line-height: 1.15;
    text-shadow: 0 1px 3px rgba(0, 0, 0, 0.9);
  }
}

/* ---- body: metrics then specs, fixed height whichever assessment is shown ---- */
.certification-container {
  flex: 0 0 auto;
  display: flex;
  flex-direction: column;
  gap: 1em;
  min-height: 13.2em;
}

.specs-section {
  display: grid;
  gap: 0.6em;
}

.metrics-grid {
  display: grid;
  grid-template-columns: repeat(4, minmax(0, 1fr));
  gap: 0.6em;
}
.metric {
  display: grid;
  grid-template-rows: auto auto auto;
  gap: 0.35em;
  min-width: 0;
  padding: 0.75em 0.85em 0.8em;
  border-radius: var(--radius-panel);
  background: var(--panel);
  &.missing .metric-value {
    color: var(--faint);
  }
}
.metric-key {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  color: var(--faint);
  font-size: 0.68em;
  font-weight: 700;
  letter-spacing: 0.09em;
  text-transform: uppercase;
}
.metric-value {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  font-size: 1.35em;
  font-weight: 800;
  line-height: 1.15;
  font-variant-numeric: tabular-nums;
  small {
    margin-left: 0.4em;
    color: var(--faint);
    font-size: 0.62em;
    font-weight: 700;
  }
}
.metric-bar {
  display: block;
  height: 0.3em;
  margin-top: 0.15em;
  border-radius: 1em;
  overflow: hidden;
  background: rgba(255, 255, 255, 0.1);
  span {
    display: block;
    height: 100%;
    border-radius: inherit;
    background: rgba(255, 255, 255, 0.5);
    transform-origin: left center;
    transition: transform 0.45s cubic-bezier(0.2, 0.8, 0.2, 1);
  }
}

.specs-grid {
  display: grid;
  grid-template-columns: repeat(4, minmax(0, 1fr));
  gap: 0.8em 1.2em;
}
/* icon beside a small label over the value; text wraps instead of being cut with "…" */
.spec {
  display: grid;
  grid-template-columns: auto minmax(0, 1fr);
  grid-template-areas:
    "icon label"
    "icon value";
  align-items: center;
  column-gap: 0.6em;
  row-gap: 0.1em;
  min-width: 0;
  .spec-icon {
    grid-area: icon;
    width: 1.25em;
    font-size: 1.25em;
    text-align: center;
    color: var(--faint);
  }
}
.spec-value {
  grid-area: value;
  min-width: 0;
  overflow-wrap: anywhere;
  color: #fff;
  font-size: 0.95em;
  font-weight: 700;
  line-height: 1.25;
  font-variant-numeric: tabular-nums;
}
.spec-label {
  grid-area: label;
  min-width: 0;
  overflow-wrap: anywhere;
  color: var(--faint);
  font-size: 0.72em;
  font-weight: 700;
  line-height: 1.2;
}

.body-empty {
  flex: 1 1 auto;
  display: grid;
  place-content: center;
  justify-items: center;
  gap: 0.5em;
  border-radius: var(--radius-panel);
  background: var(--panel);
  color: var(--faint);
  font-weight: 600;
}
.body-empty-glyph {
  font-size: 2.4em;
  color: rgba(255, 255, 255, 0.25);
}

/* ---- footer: shares the card ground, no divider ---- */
.history-dropdown-container {
  flex: 0 0 auto;
  display: flex;
  align-items: flex-end;
  justify-content: space-between;
  gap: 1em;
  padding: 0.2em 1em 1em;
}
.dropdown {
  display: grid;
  gap: 0.4em;
  flex: 0 1 32em;
  min-width: 0;
}
.history-select {
  width: 100%;
}
</style>
