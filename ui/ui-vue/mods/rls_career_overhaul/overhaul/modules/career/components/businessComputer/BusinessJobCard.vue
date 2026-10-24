<template>
  <article :bng-nav-item="blockedReason ? true : null" :aria-description="blockedReason || null" v-bng-tooltip="blockedReason || undefined" class="rls-house job-card" :class="[layout === 'full' ? 'is-full' : 'is-compact', { active: isActive }]">
    <!-- the car first: big photo on full cards, a wide thumbnail on the compact (widget) card -->
    <div class="job-photo">
      <img :src="job.vehicleImage" :alt="job.vehicleName" />
      <span v-if="vehicleCooldownSec > 0" class="photo-pill cooldown">
        <svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="10" /><polyline points="12 6 12 12 16 14" /></svg>
        <span>{{ layout === 'full' ? 'Cooling down ' : '' }}{{ formatCooldownMSS(vehicleCooldownSec) }}</span>
      </span>
      <span v-if="layout === 'full' && expirationText" class="photo-pill expires" :class="{ expired: isExpired }">
        <svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="10" /><polyline points="12 6 12 12 16 14" /></svg>
        <span>{{ expirationText }}</span>
      </span>
    </div>

    <div class="job-body">
      <div class="job-head">
        <strong class="job-name" :title="`${job.vehicleYear || ''} ${job.vehicleName || ''}`.trim()">{{ job.vehicleYear }} {{ job.vehicleName }}</strong>
        <strong class="job-pay">{{ moneySign(job.reward) }}<BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoneyCompact(job.reward) }}</strong>
      </div>

      <div class="job-goal">
        <span class="caption">Goal</span>
        <span class="goal-value">{{ job.goal }}</span>
      </div>

      <!-- compact cards have no photo pill, so expiry sits under the goal -->
      <div v-if="layout !== 'full' && !isActive && expirationText" class="job-goal">
        <span class="caption">Expires</span>
        <span class="goal-value" :class="{ bad: isExpired }">{{ expirationText.replace('Expires in ', '') }}</span>
      </div>

      <!-- active job: tech progress, or the run time against the goal -->
      <template v-if="isActive">
        <div v-if="hasTechAssigned" class="job-progress">
          <div class="progress-head">
            <span class="caption">{{ techStatus }}</span>
            <span class="hint">{{ techName || 'Tech' }}</span>
          </div>
          <div class="slim-bar"><span :style="{ transform: `scaleX(${techProgress / 100})` }"></span></div>
        </div>
        <div v-else class="job-progress">
          <div class="progress-head">
            <span class="caption">Current</span>
            <span class="progress-value">{{ formatTime(job.currentTime ?? job.baselineTime, job.decimalPlaces) }}</span>
          </div>
          <div class="slim-bar"><span :style="{ transform: `scaleX(${progressPercent / 100})` }"></span></div>
          <p v-if="completionBlockedMessage" class="notice warn">{{ completionBlockedMessage }}</p>
        </div>
      </template>

      <div class="job-actions" :class="{ locked: damageLockApplies || kitInstallLocked }">
        <template v-if="isActive">
          <template v-if="kitInstallLocked">
            <div class="notice kit-install">
              <svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="10" /><path d="M12 6v6l4 2" /></svg>
              <span class="kit-copy">
                <span>Installing {{ kitInstallKitName }}</span>
                <span class="hint">{{ formatTime(kitInstallSecondsRemaining) }} remaining</span>
              </span>
            </div>
          </template>
          <template v-else-if="!hasTechAssigned">
            <template v-if="damageLockApplies">
              <p class="notice bad">Vehicle damaged</p>
              <HouseButton variant="quiet-danger" block @mousedown.stop :data-fk="`job-${job.id}-abandon`" @click.stop="$emit('abandon', job)">
                {{ abandonActionLabel }}
              </HouseButton>
            </template>
            <template v-else>
              <HouseButton v-if="showCompleteButton" variant="primary" class="grow"
                :data-fk="`job-${job.id}-complete`" @click.stop="$emit('complete', job)">
                {{ sessionStore.hasCapability('fleetVehicles') ? 'Sell' : 'Complete' }}
              </HouseButton>
              <template v-else>
                <HouseButton v-if="showRacingTeamRepair" block @click.stop="runRepair">
                  Repair
                </HouseButton>
                <HouseButton variant="primary" class="grow"
                  :disabled="(!isPulledOut && hasPulledOutVehicle) || pullOutBlockedByCooldown"
                  :title="pullOutButtonTitle"
                  @click.stop="isPulledOut ? $emit('put-away') : $emit('pull-out', job)">
                  {{ isPulledOut ? 'Put Away' : 'Pull Out' }}
                </HouseButton>
                <HouseButton variant="quiet-danger" :title="abandonActionLabel"
                  @mousedown.stop :data-fk="`job-${job.id}-abandon`" @click.stop="$emit('abandon', job)">
                  {{ abandonActionLabel }}
                </HouseButton>
              </template>
            </template>
          </template>
        </template>
        <template v-else-if="assignMode">
          <HouseButton variant="primary" class="grow" :data-fk="`job-${job.id}-assign`" @click.stop="$emit('assign', job)">
            Assign
          </HouseButton>
        </template>
        <template v-else>
          <HouseButton variant="primary" class="grow" :disabled="isAcceptDisabled" :title="acceptButtonTitle"
            :data-fk="`job-${job.id}-accept`" @click.stop="$emit('accept', job)">
            {{ sessionStore.hasCapability('fleetVehicles') ? 'Purchase' : 'Accept' }}
          </HouseButton>
          <HouseButton variant="quiet" :data-fk="`job-${job.id}-decline`" @click.stop="$emit('decline', job)">
            Decline
          </HouseButton>
        </template>
      </div>
    </div>
  </article>
</template>

<script setup>
import { useNowSeconds } from "../../composables/useNowSeconds.js"
import { secondsUntil, techProgressAt } from "../../stores/businessComputer/businessTime.js"
import { computed, ref, onMounted, watch } from "vue"
import { useBusinessSessionStore } from "../../stores/businessComputer/businessSessionStore.js"
import { useBusinessTechsStore } from "../../stores/businessComputer/businessTechsStore.js"
import { useBusinessVehiclesStore } from "../../stores/businessComputer/businessVehiclesStore.js"
import { lua } from "@/bridge"
import { formatMoneyCompact, moneySign, formatTime, formatPhase, normalizeId } from "../../utils/businessUtils"
import { vBngTooltip } from "@/common/directives"
import { BngIcon, icons } from "@/common/components/base"
import { HouseButton } from "../house/index.js"

const props = defineProps({
  job: Object,
  isActive: Boolean,
  businessId: String,
  assignMode: {
    type: Boolean,
    default: false
  },
  layout: {
    type: String,
    default: 'compact',
    validator: (value) => ['compact', 'full'].includes(value)
  }
})

const emit = defineEmits(['pull-out', 'put-away', 'abandon', 'accept', 'decline', 'complete', 'assign'])

const nowSeconds = useNowSeconds()
const sessionStore = useBusinessSessionStore()
const techsStore = useBusinessTechsStore()
const vehiclesStore = useBusinessVehiclesStore()

const blockedReason = computed(() => !props.isActive && isAcceptDisabled.value
  ? acceptButtonTitle.value
  : props.isActive && ((!isPulledOut.value && hasPulledOutVehicle.value) || pullOutBlockedByCooldown.value)
    ? pullOutButtonTitle.value : '')

const abandonActionLabel = computed(() => (sessionStore.hasCapability('fleetVehicles') ? 'Sell' : 'Abandon'))

const jobIdentifier = computed(() => normalizeId(props.job?.jobId ?? props.job?.id))

const vehicleRowMatchesJob = (vehicle) => {
  if (!vehicle || !props.job) return false
  const sv = normalizeId(props.job.storedVehicleId)
  if (sv !== null && normalizeId(vehicle.vehicleId) === sv) return true
  const jid = normalizeId(props.job?.jobId ?? props.job?.id)
  return jid !== null && normalizeId(vehicle?.jobId) === jid
}
const techAssigned = computed(() => {
  if (!props.job?.techAssigned) return null
  return props.job.techAssigned
})
const assignedTech = computed(() => {
  if (!techAssigned.value) return null
  const techs = techsStore.techs || []
  const tech = techs.find(t => String(t.id) === String(techAssigned.value)) || null
  if (!tech) return null
  const techJobId = normalizeId(tech.jobId)
  if (techJobId !== jobIdentifier.value) return null
  return tech
})
const techName = computed(() => {
  return assignedTech.value?.name || null
})
const hasTechAssigned = computed(() => !!assignedTech.value)
const techProgress = computed(() => {
  if (!assignedTech.value || !assignedTech.value.jobId) return 0
  const progress = techProgressAt(assignedTech.value, nowSeconds.value)
  return typeof progress === 'number' ? Math.min(100, Math.max(0, progress * 100)) : 0
})
const techStatus = computed(() => {
  if (!assignedTech.value) return null
  return formatPhase(assignedTech.value, false)
})
const pulledOutVehicleForJob = computed(() => {
  if (Array.isArray(sessionStore.pulledOutVehicles)) {
    const fromList = sessionStore.pulledOutVehicles.find(vehicle => vehicleRowMatchesJob(vehicle))
    if (fromList) {
      return fromList
    }
  }
  const pv = sessionStore.pulledOutVehicle
  if (pv && vehicleRowMatchesJob(pv)) {
    return pv
  }
  return null
})
const vehicleForJob = computed(() => {
  if (!Array.isArray(sessionStore.vehicles)) {
    return null
  }
  return sessionStore.vehicles.find(vehicle => vehicleRowMatchesJob(vehicle)) || null
})

/** Inventory vehicle id for racingTeamFleetCooldowns (Lua keys are tostring(vehicleId)). */
const fleetVehicleIdForCooldown = computed(() => {
  const row = vehicleForJob.value || pulledOutVehicleForJob.value
  const fromRow = row?.vehicleId
  if (fromRow !== undefined && fromRow !== null && fromRow !== "") {
    return fromRow
  }
  const stored = props.job?.storedVehicleId
  if (stored !== undefined && stored !== null && stored !== "") {
    return stored
  }
  const jv = props.job?.vehicleId
  if (jv !== undefined && jv !== null && jv !== "") {
    return jv
  }
  return null
})

const damageLockApplies = computed(() => {
  if (!pulledOutVehicleForJob.value) {
    return false
  }
  return !!pulledOutVehicleForJob.value.damageLocked
})
const kitInstallLocked = computed(() => {
  const vehicle = vehicleForJob.value || pulledOutVehicleForJob.value
  if (vehicle?.kitInstallLocked === true) return true
  return kitInstallSecondsRemaining.value > 0
})
const kitInstallSecondsRemaining = computed(() => {
  const vehicle = vehicleForJob.value || pulledOutVehicleForJob.value
  return secondsUntil(vehicle?.kitInstallExpiresAtSeconds, nowSeconds.value)
})
const kitInstallKitName = computed(() => {
  const vehicle = vehicleForJob.value || pulledOutVehicleForJob.value
  return vehicle?.kitInstallKitName || 'kit'
})
// The time units a race's businessProof may declare (tests/schemas/events-business-proof.schema.json).
const SECONDS_PER_TIME_UNIT = { s: 1, min: 60 }
const canComplete = ref(false)
const completionStatusMessage = ref(null)
const completionStatusFetched = ref(false)
const remainingSeconds = computed(() => props.isActive || !Number.isFinite(props.job?.expiresAtSeconds)
  ? null : secondsUntil(props.job.expiresAtSeconds, nowSeconds.value))

const canCompleteLocal = computed(() => {
  if (sessionStore.hasCapability('customerJobs')) {
    return false
  }
  if (!props.isActive || props.job.currentTime === undefined || props.job.currentTime === null || props.job.goalTime === undefined || props.job.goalTime === null) {
    return false
  }

  const secondsPerUnit = SECONDS_PER_TIME_UNIT[props.job.timeUnit]
  if (secondsPerUnit === undefined) return false

  // Both times arrive in the job's own unit; compare them in seconds.
  const currentSeconds = Number(props.job.currentTime) * secondsPerUnit
  const goalSeconds = Number(props.job.goalTime) * secondsPerUnit
  if (isNaN(currentSeconds) || isNaN(goalSeconds) || goalSeconds <= 0) return false

  return currentSeconds <= goalSeconds
})

const completionBlockedMessage = computed(() => {
  if (!sessionStore.hasCapability('customerJobs') || !props.isActive) {
    return null
  }
  if (!props.job.goalTimeMet) {
    return null
  }
  if (completionStatusFetched.value) {
    return completionStatusMessage.value || null
  }
  if (completionStatusMessage.value) {
    return completionStatusMessage.value
  }
  return props.job.completionBlockedMessage || null
})

const showCompleteButton = computed(() => {
  if (completionBlockedMessage.value) {
    return false
  }
  if (sessionStore.hasCapability('customerJobs')) {
    return canComplete.value === true
  }
  return canComplete.value || canCompleteLocal.value
})

const statusText = computed(() => {
  return props.isActive ? "In Progress" : "Available"
})

const statusClass = computed(() => {
  return props.isActive ? "status-active" : "status-available"
})

const progressPercent = computed(() => {
  if (!props.isActive || !props.job.baselineTime || !props.job.goalTime) return 0
  const progress = ((props.job.baselineTime - props.job.currentTime) /
    (props.job.baselineTime - props.job.goalTime)) * 100
  return Math.max(0, Math.min(100, progress))
})

const isPulledOut = computed(() => {
  return !!pulledOutVehicleForJob.value
})

const liftsFull = computed(() => {
  if (Array.isArray(sessionStore.pulledOutVehicles)) {
    return sessionStore.pulledOutVehicles.length >= sessionStore.maxPulledOutVehicles
  }
  return !!sessionStore.pulledOutVehicle
})

const hasPulledOutVehicle = computed(() => {
  return liftsFull.value && !isPulledOut.value
})

const showRacingTeamRepair = computed(() => {
  if (!sessionStore.hasCapability('fleetRepair') || !props.isActive || hasTechAssigned.value || kitInstallLocked.value) {
    return false
  }
  if (!isPulledOut.value) {
    return false
  }
  const d = pulledOutVehicleForJob.value?.damage
  return typeof d === "number" && d >= 1
})

const runRepair = async () => {
  const v = pulledOutVehicleForJob.value
  if (!v?.vehicleId) {
    return
  }
  await vehiclesStore.repairBusinessVehicle(v.vehicleId)
}

const checkCanComplete = async () => {
  if (!props.isActive || !props.businessId || !props.job.jobId) {
    canComplete.value = false
    completionStatusMessage.value = null
    completionStatusFetched.value = false
    return
  }

  try {
    if (sessionStore.hasCapability('customerJobs')) {
      const response = await sessionStore.ownerModule().getJobCompletionStatus(props.businessId, props.job.jobId)
      const status = response && typeof response === 'object' ? response : {}
      canComplete.value = status.canComplete === true
      completionStatusMessage.value = status.goalTimeMet ? (status.blockedMessage || null) : null
      completionStatusFetched.value = true
      return
    }

    completionStatusFetched.value = false
    const result = await lua.overhaul_career_business_computer.canCompleteJob(props.businessId, props.job.jobId)
    canComplete.value = result === true
    completionStatusMessage.value = null
  } catch (error) {
    canComplete.value = false
    completionStatusMessage.value = null
    completionStatusFetched.value = sessionStore.hasCapability('customerJobs')
  }
}

const isExpired = computed(() => {
  if (props.isActive) {
    return false
  }
  return remainingSeconds.value !== null && remainingSeconds.value <= 0
})

const expirationText = computed(() => {
  if (props.isActive || remainingSeconds.value === null) {
    return null
  }
  if (remainingSeconds.value <= 0) {
    return "Expired"
  }
  return `Expires in ${formatTime(remainingSeconds.value, 0)}`
})

const vehicleCooldownSec = computed(() => {
  const id = fleetVehicleIdForCooldown.value
  const expiries = sessionStore.businessData?.fleetCooldownExpiresAtSeconds
  const expiresAt = expiries?.[String(id)] ?? expiries?.[String(normalizeId(id))]
  return secondsUntil(expiresAt, nowSeconds.value)
})

const formatCooldownMSS = (totalSec) => {
  const s = Math.max(0, Math.floor(Number(totalSec) || 0))
  const h = Math.floor(s / 3600)
  const m = Math.floor((s % 3600) / 60)
  const r = s % 60
  if (h > 0) return `${h}:${String(m).padStart(2, "0")}:${String(r).padStart(2, "0")}`
  return `${m}:${String(r).padStart(2, "0")}`
}

const pullOutBlockedByCooldown = computed(() => {
  // Fleet vehicle post-race cooldown must not block pulling out to work on the car.
  return false
})

const pullOutButtonTitle = computed(() => {
  if (!pullOutBlockedByCooldown.value) {
    return ""
  }
  return `Vehicle cooling down (${formatCooldownMSS(vehicleCooldownSec.value)} remaining)`
})

const isAcceptDisabled = computed(() => {
  if (props.isActive) {
    return false
  }
  if (sessionStore.activeJobs.length >= sessionStore.maxActiveJobs) {
    return true
  }
  if (sessionStore.hasCapability('fleetVehicles') && vehicleCooldownSec.value > 0) {
    return true
  }
  return false
})

const acceptButtonTitle = computed(() => {
  if (!isAcceptDisabled.value) {
    return ""
  }
  if (sessionStore.activeJobs.length >= sessionStore.maxActiveJobs) {
    return `Active job limit reached (${sessionStore.maxActiveJobs} max)`
  }
  if (sessionStore.hasCapability('fleetVehicles') && vehicleCooldownSec.value > 0) {
    return `Vehicle cooling down (${formatCooldownMSS(vehicleCooldownSec.value)})`
  }
  return ""
})

onMounted(() => {
  checkCanComplete()
})

let canCompleteQueued = false
const queueCheckCanComplete = () => {
  if (canCompleteQueued) return
  canCompleteQueued = true
  Promise.resolve().then(() => {
    canCompleteQueued = false
    checkCanComplete()
  })
}

watch(() => [props.job, props.isActive, props.job.currentTime, props.job.goalTime, props.job.jobId,
  props.job.goalTimeMet, props.job.completionBlockedMessage, props.job.buildChanged, props.job.techAssigned], () => {
  queueCheckCanComplete()
})
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

.job-card {
  display: flex;
  flex-direction: column;
  height: 100%;
  min-width: 0;
  border-radius: var(--radius-panel);
  overflow: hidden;
  background: var(--panel);
}

/* ---- photo ---- */
.job-photo {
  position: relative;
  flex: 0 0 auto;
  width: 100%;
  aspect-ratio: 16 / 9;
  overflow: hidden;
  background: var(--photo);

  img {
    display: block;
    width: 100%;
    height: 100%;
    object-fit: cover;
  }
}

.photo-pill {
  position: absolute;
  display: inline-flex;
  align-items: center;
  gap: 0.35em;
  padding: 0.45em 0.6em 0.25em;
  border-radius: var(--radius-pill);
  background: rgba(0, 0, 0, 0.72);
  color: #fff;
  font-size: 0.78em;
  font-weight: 700;
  line-height: 1;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;

  svg {
    width: 1em;
    height: 1em;
    flex: 0 0 auto;
    fill: none;
    stroke: currentColor;
    stroke-width: 2.4;
    stroke-linecap: round;
    stroke-linejoin: round;
    transform: translateY(-0.08em);
  }

  &.cooldown {
    top: 0.55em;
    left: 0.55em;
    color: var(--accent-soft);
  }

  &.expires {
    right: 0.55em;
    bottom: 0.55em;
  }

  &.expired {
    background: rgba(127, 29, 29, 0.9);
    color: var(--bad);
  }
}

/* ---- copy ---- */
.job-body {
  flex: 1 1 auto;
  display: flex;
  flex-direction: column;
  gap: var(--space-3);
  min-width: 0;
  padding: var(--inset);
}

.job-head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  flex-wrap: wrap;
  gap: 0.2em 0.8em;
  min-width: 0;
}

.job-name {
  flex: 1 1 10em;
  min-width: 0;
  font-size: 1.2em;
  font-weight: 800;
  line-height: 1.2;
  letter-spacing: -0.01em;
  overflow-wrap: anywhere;
  /* long names: two lines, then ellipsis */
  display: -webkit-box;
  -webkit-box-orient: vertical;
  -webkit-line-clamp: 2;
  line-clamp: 2;
  overflow: hidden;
}

.job-pay {
  flex: 0 0 auto;
  color: var(--money);
  font-size: 1.08em;
  font-weight: 800;
  line-height: 1.2;
  font-variant-numeric: tabular-nums;
}

.job-goal {
  display: grid;
  gap: 0.2em;
  min-width: 0;

  .goal-value {
    color: #fff;
    font-size: 0.95em;
    font-weight: 600;
    line-height: 1.3;
    font-variant-numeric: tabular-nums;

    &.bad {
      color: var(--bad);
    }
  }
}

.job-progress {
  display: grid;
  gap: 0.4em;
}

.progress-head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 0.8em;

  .progress-value {
    color: #fff;
    font-weight: 700;
    font-variant-numeric: tabular-nums;
  }
}

.slim-bar {
  height: 0.3em;
  border-radius: 1em;
  overflow: hidden;
  background: rgba(255, 255, 255, 0.12);

  > span {
    display: block;
    width: 100%;
    height: 100%;
    border-radius: inherit;
    background: var(--accent);
    transform-origin: left center;
    transition: transform 0.3s ease-out;
  }
}

.notice {
  font-size: 0.85em;
}

.kit-install {
  display: flex;
  align-items: center;
  gap: 0.6em;
  width: 100%;
  color: var(--accent-soft);

  svg {
    width: 1.15em;
    height: 1.15em;
    flex: 0 0 auto;
    fill: none;
    stroke: currentColor;
    stroke-width: 2.2;
    stroke-linecap: round;
    stroke-linejoin: round;
  }

  .kit-copy {
    display: grid;
    gap: 0.15em;
    font-weight: 700;
  }

  .hint {
    font-variant-numeric: tabular-nums;
  }
}

/* ---- actions ---- */
.job-actions {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: var(--space-2);
  margin-top: auto;

  .notice {
    width: 100%;
  }

  .grow {
    flex: 1 1 auto;
  }
}

/* ---- compact (Home widget): wide thumbnail beside the name ---- */
.job-card.is-compact {
  display: grid;
  grid-template-columns: 7.5em minmax(0, 1fr);
  align-content: start;

  .job-photo {
    grid-row: 1;
    grid-column: 1;
    align-self: start;
    margin: var(--inset) 0 0 var(--inset);
    width: auto;
    border-radius: var(--radius-thumb);
  }

  .job-body {
    display: contents;
  }

  .job-head {
    grid-row: 1;
    grid-column: 2;
    align-self: center;
    flex-direction: column;
    align-items: flex-start;
    flex-wrap: nowrap;
    padding: var(--inset) var(--inset) 0 0.75em;
  }

  .job-name {
    flex: 0 0 auto;
    font-size: 1.05em;
  }

  .job-pay {
    font-size: 0.98em;
  }

  .job-goal,
  .job-progress,
  .job-actions {
    grid-column: 1 / -1;
    margin: var(--space-3) var(--inset) 0;
  }

  .job-actions {
    margin-bottom: var(--inset);
  }
}

/* game currency glyph in front of amounts; inherits colour and size */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
</style>
