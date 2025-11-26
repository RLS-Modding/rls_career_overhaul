<template>
  <div class="job-card" :class="{ active: isActive }">
    <!-- Full Layout (formerly New Job Style) -->
    <div v-if="layout === 'full'" class="job-content-new">
      <div class="job-image-new">
        <img :src="job.vehicleImage" :alt="job.vehicleName" />
        <div class="expiration-overlay" v-if="expirationText" :class="{ expired: isExpired }">
          <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5">
            <circle cx="12" cy="12" r="10" />
            <polyline points="12 6 12 12 16 14" />
          </svg>
          <span>{{ expirationText }}</span>
        </div>
      </div>

      <div class="job-details-container">
        <h3 class="vehicle-name-new">
          {{ job.vehicleYear }} {{ job.vehicleName }}
        </h3>

        <div class="job-meta-row">
          <div class="reward-text">
            <span class="currency">$</span>{{ job.reward.toLocaleString() }}
          </div>
          <div class="separator">•</div>
          <div class="goal-text">
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5">
              <path d="M12 2v4m0 12v4M2 12h4m12 0h4" />
              <circle cx="12" cy="12" r="10" />
            </svg>
            <span>{{ job.goal }}</span>
          </div>
        </div>

        <!-- Active Job Status in Full Layout -->
        <div v-if="isActive" class="job-status-full">
          <div v-if="hasTechAssigned" class="tech-status-sleek">
            <div class="tech-info-row">
              <span class="tech-phase">{{ techStatus }}</span>
              <span class="tech-name-small">by {{ techName || 'Tech' }}</span>
            </div>
            <div class="tech-progress-bar">
              <div class="tech-progress-fill" :style="{ width: techProgress + '%' }"></div>
            </div>
          </div>
          <div v-else class="goal-section-sleek">
            <div class="goal-row current">
              <span class="goal-label">Current</span>
              <span class="goal-value highlight">{{ formatTimeWithUnit(job.currentTime ?? job.baselineTime,
                job.timeUnit, job.decimalPlaces) }}</span>
            </div>
            <div class="progress-bar-sleek">
              <div class="progress-fill" :style="{ width: progressPercent + '%' }"></div>
            </div>
          </div>
        </div>

        <div class="job-actions-new">
          <template v-if="isActive">
            <!-- Active Job Actions for Full Layout -->
            <div class="job-actions-sleek full-layout-actions" :class="{ locked: damageLockApplies }">
              <template v-if="!hasTechAssigned">
                <template v-if="damageLockApplies">
                  <div class="lock-message">Vehicle Damaged</div>
                  <button class="btn btn-danger full-width" @mousedown.stop @click.stop="$emit('abandon', job)" data-focusable>
                    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                      <line x1="18" y1="6" x2="6" y2="18" />
                      <line x1="6" y1="6" x2="18" y2="18" />
                    </svg>
                    Abandon
                  </button>
                </template>
                <template v-else>
                  <button v-if="canComplete || canCompleteLocal" class="btn btn-success flex-grow"
                    @click.stop="$emit('complete', job)" data-focusable>
                    Complete
                  </button>
                  <template v-else>
                    <button class="btn btn-primary flex-grow"
                      @click.stop="isPulledOut ? $emit('put-away') : $emit('pull-out', job)"
                      :disabled="!isPulledOut && hasPulledOutVehicle" data-focusable>
                      {{ isPulledOut ? 'Put Away' : 'Pull Out' }}
                    </button>
                    <button class="btn btn-danger btn-icon" @mousedown.stop @click.stop="$emit('abandon', job)"
                      title="Abandon" data-focusable>
                      <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor"
                        stroke-width="2.5">
                        <line x1="18" y1="6" x2="6" y2="18" />
                        <line x1="6" y1="6" x2="18" y2="18" />
                      </svg>
                    </button>
                  </template>
                </template>
              </template>
            </div>
          </template>
          <template v-else>
            <!-- New Job Actions -->
            <template v-if="assignMode">
              <button class="btn btn-primary" @click.stop="$emit('assign', job)" data-focusable>
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                  <path d="M16 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2" />
                  <circle cx="8.5" cy="7" r="4" />
                  <line x1="20" y1="8" x2="20" y2="14" />
                  <line x1="23" y1="11" x2="17" y2="11" />
                </svg>
                Assign
              </button>
            </template>
            <template v-else>
              <button class="btn btn-success flex-grow" :disabled="isAcceptDisabled"
                :title="isAcceptDisabled ? `Active job limit reached (${store.maxActiveJobs} max)` : ''"
                @click.stop="$emit('accept', job)" data-focusable>
                Accept
              </button>
              <button class="btn btn-danger btn-icon" @click.stop="$emit('decline', job)" data-focusable>
                <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5">
                  <line x1="18" y1="6" x2="6" y2="18" />
                  <line x1="6" y1="6" x2="18" y2="18" />
                </svg>
              </button>
            </template>
          </template>
        </div>
      </div>
    </div>

    <!-- Compact Layout (formerly Active/Sleek State) -->
    <div v-else class="job-content-active sleek">
      <div class="job-header-sleek">
        <div class="job-image-sleek">
          <img :src="job.vehicleImage" :alt="job.vehicleName" />
        </div>
        <div class="job-info-sleek">
          <h3 class="vehicle-name-sleek">
            {{ job.vehicleYear }} {{ job.vehicleName }}
          </h3>
          <div class="reward-text-sleek">
            <span class="currency">$</span>{{ job.reward.toLocaleString() }}
          </div>
        </div>
      </div>

      <div class="job-status-sleek">
        <template v-if="isActive">
          <!-- Tech Working Status -->
          <div v-if="hasTechAssigned" class="tech-status-sleek">
            <div class="tech-info-row">
              <span class="tech-phase">{{ techStatus }}</span>
              <span class="tech-name-small">by {{ techName || 'Tech' }}</span>
            </div>
            <div class="tech-progress-bar">
              <div class="tech-progress-fill" :style="{ width: techProgress + '%' }"></div>
            </div>
          </div>

          <!-- Goal Section (Only if NO Tech) -->
          <div v-else class="goal-section-sleek">
            <div class="goal-row">
              <span class="goal-label">Goal</span>
              <span class="goal-value">{{ job.goal }}</span>
            </div>
            <div class="goal-row current">
              <span class="goal-label">Current</span>
              <span class="goal-value highlight">{{ formatTimeWithUnit(job.currentTime ?? job.baselineTime,
                job.timeUnit, job.decimalPlaces) }}</span>
            </div>
            <div class="progress-bar-sleek">
              <div class="progress-fill" :style="{ width: progressPercent + '%' }"></div>
            </div>
          </div>
        </template>
        <template v-else>
          <!-- Compact New Job Info -->
          <div class="goal-section-sleek">
            <div class="goal-row">
              <span class="goal-label">Goal</span>
              <span class="goal-value">{{ job.goal }}</span>
            </div>
            <div v-if="expirationText" class="goal-row current">
              <span class="goal-label">Expires</span>
              <span class="goal-value" :class="{ 'text-danger': isExpired }">{{ expirationText.replace('Expires in ',
                '') }}</span>
            </div>
          </div>
        </template>
      </div>

      <div class="job-actions-sleek" :class="{ locked: damageLockApplies }">
        <template v-if="isActive">
          <template v-if="!hasTechAssigned">
            <template v-if="damageLockApplies">
              <div class="lock-message">Vehicle Damaged</div>
              <button class="btn btn-danger full-width" @mousedown.stop @click.stop="$emit('abandon', job)" data-focusable>
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                  <line x1="18" y1="6" x2="6" y2="18" />
                  <line x1="6" y1="6" x2="18" y2="18" />
                </svg>
                Abandon
              </button>
            </template>
            <template v-else>
              <button v-if="canComplete || canCompleteLocal" class="btn btn-success flex-grow"
                @click.stop="$emit('complete', job)" data-focusable>
                Complete
              </button>
              <template v-else>
                <button class="btn btn-primary flex-grow"
                  @click.stop="isPulledOut ? $emit('put-away') : $emit('pull-out', job)"
                  :disabled="!isPulledOut && hasPulledOutVehicle" data-focusable>
                  {{ isPulledOut ? 'Put Away' : 'Pull Out' }}
                </button>
                <button class="btn btn-danger btn-icon" @mousedown.stop @click.stop="$emit('abandon', job)"
                  title="Abandon" data-focusable>
                  <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5">
                    <line x1="18" y1="6" x2="6" y2="18" />
                    <line x1="6" y1="6" x2="18" y2="18" />
                  </svg>
                </button>
              </template>
            </template>
          </template>
        </template>
        <template v-else>
          <!-- Compact New Job Actions -->
          <button class="btn btn-success flex-grow" :disabled="isAcceptDisabled"
            :title="isAcceptDisabled ? `Active job limit reached (${store.maxActiveJobs} max)` : ''"
            @click.stop="$emit('accept', job)" data-focusable>
            Accept
          </button>
          <button class="btn btn-danger btn-icon" @click.stop="$emit('decline', job)" data-focusable>
            <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5">
              <line x1="18" y1="6" x2="6" y2="18" />
              <line x1="6" y1="6" x2="18" y2="18" />
            </svg>
          </button>
        </template>
      </div>
    </div>
  </div>
</template>

<script setup>
import { computed, ref, onMounted, onUnmounted, watch } from "vue"
import { useBusinessComputerStore } from "../../stores/businessComputerStore"
import { lua } from "@/bridge"

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

const store = useBusinessComputerStore()
const normalizeJobId = (value) => {
  if (value === undefined || value === null) {
    return null
  }
  return String(value)
}
const jobIdentifier = computed(() => normalizeJobId(props.job?.jobId ?? props.job?.id))
const techAssigned = computed(() => {
  if (!props.job?.techAssigned) return null
  return props.job.techAssigned
})
const assignedTech = computed(() => {
  if (!techAssigned.value) return null
  const techs = store.techs || []
  const tech = techs.find(t => String(t.id) === String(techAssigned.value)) || null
  if (!tech) return null
  const techJobId = normalizeJobId(tech.jobId)
  if (techJobId !== jobIdentifier.value) return null
  return tech
})
const techName = computed(() => {
  return assignedTech.value?.name || null
})
const hasTechAssigned = computed(() => !!techAssigned.value)
const techProgress = computed(() => {
  if (!assignedTech.value || !assignedTech.value.jobId) return 0
  const progress = assignedTech.value.progress
  return typeof progress === 'number' ? Math.min(100, Math.max(0, progress * 100)) : 0
})
const techStatus = computed(() => {
  if (!assignedTech.value) return null
  const phaseMap = {
    baseline: "Baseline Run",
    validation: "Validation Run",
    postUpdate: "Verification",
    completed: "Completed",
    failed: "Failed",
    idle: "Idle",
    build: "Building",
    update: "Tuning",
    cooldown: "Cooling Down"
  }
  return assignedTech.value.label || phaseMap[assignedTech.value.phase] || assignedTech.value.action || "Working"
})
const pulledOutVehicleForJob = computed(() => {
  if (!Array.isArray(store.pulledOutVehicles)) {
    return null
  }
  return store.pulledOutVehicles.find(vehicle => normalizeJobId(vehicle?.jobId) === jobIdentifier.value) || null
})
const damageLockApplies = computed(() => {
  if (!pulledOutVehicleForJob.value) {
    return false
  }
  return !!pulledOutVehicleForJob.value.damageLocked
})
const isAcceptDisabled = computed(() => {
  if (props.isActive) return false
  return store.activeJobs.length >= store.maxActiveJobs
})
const canComplete = ref(false)
const remainingSeconds = ref(null)
const countdownTimer = ref(null)
const hasRequestedAfterExpiry = ref(false)

const canCompleteLocal = computed(() => {
  if (!props.isActive || props.job.currentTime === undefined || props.job.currentTime === null || props.job.goalTime === undefined || props.job.goalTime === null) {
    return false
  }

  // For track races and drag races, lower time is better (currentTime <= goalTime)
  // Both times should be in the same unit (seconds from leaderboard)
  if (props.job.raceType === "track" || props.job.raceType === "trackAlt" || props.job.raceType === "drag") {
    // Ensure we have valid numbers
    const currentTime = Number(props.job.currentTime)
    const goalTime = Number(props.job.goalTime)

    if (isNaN(currentTime) || isNaN(goalTime) || goalTime <= 0) {
      return false
    }

    return currentTime <= goalTime
  }

  return false
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
  if (Array.isArray(store.pulledOutVehicles)) {
    return store.pulledOutVehicles.length >= store.maxPulledOutVehicles
  }
  return !!store.pulledOutVehicle
})

const hasPulledOutVehicle = computed(() => {
  return liftsFull.value && !isPulledOut.value
})

const formatTime = (time, decimalPlaces) => {
  if (typeof time !== 'number' || isNaN(time)) {
    return time || '0'
  }

  if (time >= 60) {
    const minutes = Math.floor(time / 60)
    const seconds = Math.round(time % 60)
    if (seconds >= 1) {
      return `${minutes} min ${seconds} s`
    } else {
      return `${minutes} min`
    }
  }

  const decimals = decimalPlaces || 0
  if (decimals > 0) {
    return time.toFixed(decimals) + ' s'
  }

  return Math.round(time) + ' s'
}

const formatTimeWithUnit = (time, timeUnit, decimalPlaces) => {
  if (typeof time !== 'number' || isNaN(time)) {
    return (time || '0') + (timeUnit || '')
  }
  const formatted = formatTime(time, decimalPlaces)
  return formatted
}

const stopCountdown = () => {
  if (countdownTimer.value) {
    clearInterval(countdownTimer.value)
    countdownTimer.value = null
  }
}

const syncRemainingSeconds = () => {
  if (props.isActive) {
    remainingSeconds.value = null
    return
  }

  if (typeof props.job?.expiresInSeconds === "number") {
    remainingSeconds.value = Math.max(0, Math.floor(props.job.expiresInSeconds))
  } else {
    remainingSeconds.value = null
  }
}

const requestJobsAfterExpiry = async () => {
  if (hasRequestedAfterExpiry.value) {
    return
  }

  hasRequestedAfterExpiry.value = true

  const currentBusinessId = store.businessId
  const currentBusinessType = store.businessType

  if (!currentBusinessId || !currentBusinessType || !store.loadBusinessData) {
    return
  }

  try {
    await store.loadBusinessData(currentBusinessType, currentBusinessId)
  } catch (error) {
  }
}

const startCountdown = () => {
  stopCountdown()
  hasRequestedAfterExpiry.value = false
  syncRemainingSeconds()
  if (remainingSeconds.value === null) {
    return
  }

  countdownTimer.value = setInterval(() => {
    if (remainingSeconds.value === null) {
      stopCountdown()
      return
    }

    if (remainingSeconds.value <= 0) {
      remainingSeconds.value = 0
      requestJobsAfterExpiry()
      stopCountdown()
      return
    }

    remainingSeconds.value = remainingSeconds.value - 1
  }, 1000)
}

const checkCanComplete = async () => {
  if (!props.isActive || !props.businessId || !props.job.jobId) {
    canComplete.value = false
    return
  }

  try {
    const result = await lua.career_modules_business_businessComputer.canCompleteJob(props.businessId, props.job.jobId)
    canComplete.value = result === true
  } catch (error) {
    canComplete.value = false
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

onMounted(() => {
  checkCanComplete()
  startCountdown()
})

onUnmounted(() => {
  stopCountdown()
})

watch(() => [props.isActive, props.job.currentTime, props.job.goalTime, props.job.jobId], () => {
  checkCanComplete()
}, { immediate: false })

watch(() => props.job, () => {
  hasRequestedAfterExpiry.value = false
  checkCanComplete()
}, { deep: true })

watch(() => props.isActive, () => {
  hasRequestedAfterExpiry.value = false
})

watch(() => [props.job?.jobId, props.job?.expiresInSeconds, props.isActive], () => {
  startCountdown()
})
</script>

<style scoped lang="scss">
.job-card {
  background: rgba(23, 23, 23, 0.5);
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: 0.5rem;
  padding: 0.75rem;
  transition: border-color 0.2s;

  &:hover {
    border-color: rgba(245, 73, 0, 0.5);
  }
}

/* Common/Shared Styles */
.btn {
  padding: 0.5rem 0.75rem;
  border-radius: 0.375rem;
  font-size: 0.875rem;
  font-weight: 500;
  cursor: pointer;
  border: none;
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 0.5rem;
  transition: all 0.2s;

  &.flex-grow {
    flex: 1;
  }

  &.full-width {
    width: 100%;
  }

  &.btn-icon {
    padding: 0.5rem;
    width: 2.25rem;
    /* fixed width for icon buttons */
    flex-shrink: 0;
  }

  &.btn-primary {
    background: rgba(245, 73, 0, 1);
    color: white;

    &:hover:not(:disabled) {
      background: rgba(245, 73, 0, 0.9);
    }

    &:disabled {
      opacity: 0.5;
      cursor: not-allowed;
    }
  }

  &.btn-success {
    background: rgba(34, 197, 94, 1);
    color: white;

    &:hover:not(:disabled) {
      background: rgba(34, 197, 94, 0.9);
    }

    &:disabled {
      opacity: 0.5;
      cursor: not-allowed;
    }
  }

  &.btn-danger {
    background: rgba(239, 68, 68, 1);
    color: white;

    &:hover {
      background: rgba(239, 68, 68, 0.9);
    }
  }
}

/* "New" Job Styles */
.job-content-new {
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
}

.job-image-new {
  position: relative;
  width: 100%;
  aspect-ratio: 16/9;
  border-radius: 0.375rem;
  overflow: hidden;
  background: rgba(0, 0, 0, 0.5);

  img {
    width: 100%;
    height: 100%;
    object-fit: cover;
    display: block;
  }
}

.expiration-overlay {
  position: absolute;
  bottom: 0.5rem;
  right: 0.5rem;
  background: rgba(0, 0, 0, 0.75);
  backdrop-filter: blur(4px);
  color: rgba(255, 255, 255, 0.9);
  padding: 0.25rem 0.5rem;
  border-radius: 0.25rem;
  font-size: 0.75rem;
  font-weight: 500;
  display: flex;
  align-items: center;
  gap: 0.35rem;

  &.expired {
    background: rgba(239, 68, 68, 0.9);
    color: white;
  }

  svg {
    opacity: 0.9;
  }
}

.job-details-container {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
}

.vehicle-name-new {
  margin: 0;
  color: white;
  font-size: 1rem;
  font-weight: 600;
  line-height: 1.3;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.job-meta-row {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  font-size: 0.875rem;
}

.separator {
  color: rgba(255, 255, 255, 0.2);
}

.reward-text {
  color: #22c55e;
  font-weight: 600;
  display: flex;
  align-items: baseline;
  gap: 1px;

  .currency {
    font-size: 0.75em;
    opacity: 0.8;
  }
}

.goal-text {
  color: rgba(245, 73, 0, 1);
  display: flex;
  align-items: center;
  gap: 0.35rem;
  font-weight: 500;

  svg {
    flex-shrink: 0;
  }
}

.job-actions-new {
  display: flex;
  gap: 0.5rem;
  margin-top: 0.25rem;
  flex-direction: row;
}

/* --- Sleek Active Job Styles --- */
.job-content-active.sleek {
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
}

.job-header-sleek {
  display: flex;
  gap: 0.75rem;
  align-items: center;
}

.job-image-sleek {
  width: 4rem;
  /* Compact thumbnail size */
  height: 4rem;
  border-radius: 0.375rem;
  overflow: hidden;
  background: rgba(0, 0, 0, 0.5);
  flex-shrink: 0;

  img {
    width: 100%;
    height: 100%;
    object-fit: cover;
  }
}

.job-info-sleek {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
  justify-content: center;
  gap: 0.25rem;
}

.vehicle-name-sleek {
  margin: 0;
  color: white;
  font-size: 0.95rem;
  font-weight: 600;
  line-height: 1.2;
  overflow: hidden;
  text-overflow: ellipsis;
  display: -webkit-box;
  -webkit-line-clamp: 2;
  -webkit-box-orient: vertical;
}

.reward-text-sleek {
  color: #22c55e;
  font-weight: 600;
  font-size: 0.9rem;
}

/* Tech Status Sleek */
.tech-status-sleek {
  background: rgba(245, 73, 0, 0.15);
  border: 1px solid rgba(245, 73, 0, 0.25);
  border-radius: 0.375rem;
  padding: 0.5rem 0.75rem;
  display: flex;
  flex-direction: column;
  gap: 0.35rem;
}

.tech-info-row {
  display: flex;
  justify-content: space-between;
  align-items: baseline;
}

.tech-phase {
  color: #f97316;
  font-size: 0.8rem;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.05em;
}

.tech-name-small {
  color: rgba(255, 255, 255, 0.5);
  font-size: 0.75rem;
}

.tech-progress-bar {
  height: 4px;
  background: rgba(0, 0, 0, 0.3);
  border-radius: 2px;
  overflow: hidden;

  .tech-progress-fill {
    height: 100%;
    background: #f97316;
    transition: width 0.2s;
  }
}

/* Goal Section Sleek */
.goal-section-sleek {
  background: rgba(255, 255, 255, 0.03);
  border: 1px solid rgba(255, 255, 255, 0.08);
  border-radius: 0.375rem;
  padding: 0.5rem 0.75rem;
  display: flex;
  flex-direction: column;
  gap: 0.35rem;
}

.goal-row {
  display: flex;
  justify-content: space-between;
  align-items: baseline;
  font-size: 0.8rem;

  .goal-label {
    color: rgba(255, 255, 255, 0.5);
    text-transform: uppercase;
    font-size: 0.7rem;
  }

  .goal-value {
    color: rgba(255, 255, 255, 0.9);
    font-weight: 500;

    &.highlight {
      color: white;
      font-weight: 600;
    }
  }
}

.progress-bar-sleek {
  height: 3px;
  background: rgba(255, 255, 255, 0.1);
  border-radius: 1.5px;
  overflow: hidden;
  margin-top: 0.15rem;

  .progress-fill {
    height: 100%;
    background: #f97316;
  }
}

.job-actions-sleek {
  display: flex;
  gap: 0.5rem;
  margin-top: auto;

  &.full-layout-actions {
    flex: 1;
  }
}

.lock-message {
  color: #ef4444;
  font-size: 0.8rem;
  font-weight: 600;
  text-align: center;
  margin-bottom: 0.25rem;
  width: 100%;
}
</style>