<template>
  <div class="job-card" :class="{ active: isActive, vertical: isVertical }">
    <div v-if="!isActive" class="job-content-new" :class="{ vertical: isVertical }">
      <div v-if="isVertical" class="job-content-new-vertical">
        <div class="job-image-new">
          <img :src="job.vehicleImage" :alt="job.vehicleName" />
          <div
            class="expiration-overlay"
            v-if="expirationText"
            :class="{ expired: isExpired }"
          >
            <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5">
              <circle cx="12" cy="12" r="10"/>
              <polyline points="12 6 12 12 16 14"/>
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
                 <path d="M12 2v4m0 12v4M2 12h4m12 0h4"/>
                 <circle cx="12" cy="12" r="10"/>
               </svg>
               <span>{{ job.goal }}</span>
            </div>
          </div>

          <div class="job-actions-new">
            <template v-if="assignMode">
              <button 
                class="btn btn-primary" 
                @click.stop="$emit('assign', job)"
              >
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                  <path d="M16 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/>
                  <circle cx="8.5" cy="7" r="4"/>
                  <line x1="20" y1="8" x2="20" y2="14"/>
                  <line x1="23" y1="11" x2="17" y2="11"/>
                </svg>
                Assign
              </button>
            </template>
            <template v-else>
              <button 
                class="btn btn-success flex-grow" 
                :disabled="isAcceptDisabled"
                :title="isAcceptDisabled ? `Active job limit reached (${store.maxActiveJobs} max)` : ''"
                @click.stop="$emit('accept', job)"
              >
                Accept
              </button>
              <button class="btn btn-danger btn-icon" @click.stop="$emit('decline', job)">
                <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5">
                  <line x1="18" y1="6" x2="6" y2="18"/>
                  <line x1="6" y1="6" x2="18" y2="18"/>
                </svg>
              </button>
            </template>
          </div>
        </div>
      </div>
      <template v-else>
        <div class="image-section-new-horizontal">
          <div class="job-image-new-horizontal">
            <img :src="job.vehicleImage" :alt="job.vehicleName" />
            <div
                class="expiration-overlay"
                v-if="expirationText"
                :class="{ expired: isExpired }"
            >
                <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5">
                <circle cx="12" cy="12" r="10"/>
                <polyline points="12 6 12 12 16 14"/>
                </svg>
                <span>{{ expirationText }}</span>
            </div>
          </div>
          <h3 class="vehicle-name-new-horizontal">
            {{ job.vehicleYear }} {{ job.vehicleName }}
          </h3>
        </div>
        <div class="job-info-new-horizontal">
            <div class="job-meta-column">
                <div class="reward-text large">
                    <span class="currency">$</span>{{ job.reward.toLocaleString() }}
                </div>
                 <div class="goal-text">
                    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5">
                        <path d="M12 2v4m0 12v4M2 12h4m12 0h4"/>
                        <circle cx="12" cy="12" r="10"/>
                    </svg>
                    <span>{{ job.goal }}</span>
                </div>
            </div>

          <div class="job-actions-new-horizontal">
            <template v-if="assignMode">
              <button 
                class="btn btn-primary" 
                @click.stop="$emit('assign', job)"
              >
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                  <path d="M16 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/>
                  <circle cx="8.5" cy="7" r="4"/>
                  <line x1="20" y1="8" x2="20" y2="14"/>
                  <line x1="23" y1="11" x2="17" y2="11"/>
                </svg>
                Assign
              </button>
            </template>
            <template v-else>
              <button 
                class="btn btn-success flex-grow" 
                :disabled="isAcceptDisabled"
                :title="isAcceptDisabled ? `Active job limit reached (${store.maxActiveJobs} max)` : ''"
                @click.stop="$emit('accept', job)"
              >
                Accept
              </button>
              <button class="btn btn-danger btn-icon" @click.stop="$emit('decline', job)">
                <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5">
                  <line x1="18" y1="6" x2="6" y2="18"/>
                  <line x1="6" y1="6" x2="18" y2="18"/>
                </svg>
              </button>
            </template>
          </div>
        </div>
      </template>
    </div>
    <div v-else class="job-content-active" :class="{ vertical: isVertical }">
      <div v-if="isVertical" class="job-content-active-vertical">
        <div class="job-image-active">
          <img :src="job.vehicleImage" :alt="job.vehicleName" />
          <span class="status-badge" :class="statusClass">{{ statusText }}</span>
        </div>
        <h3 class="vehicle-name-active">
          {{ job.vehicleYear }} {{ job.vehicleName }}
        </h3>
        <div class="reward-container-active">
          <span class="reward-label">Payment</span>
          <span class="reward-value">${{ job.reward.toLocaleString() }}</span>
        </div>
        <div class="job-metrics-active">
          <div class="goal-chip">
            <div class="goal-chip-content">
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <circle cx="12" cy="12" r="10"/>
                <circle cx="12" cy="12" r="6"/>
                <path d="M12 2v4m0 12v4M2 12h4m12 0h4"/>
              </svg>
              <div class="goal-chip-text">
                <span class="goal-chip-label">Goal</span>
                <span class="goal-chip-value">{{ job.goal }}</span>
              </div>
                <div class="current-time-wrapper">
                  <span class="current-time-label">Current</span>
                  <span class="current-time-value">{{ formatTimeWithUnit(job.currentTime ?? job.baselineTime, job.timeUnit, job.decimalPlaces) }}</span>
                </div>
            </div>
            <div class="progress-bar">
              <div 
                class="progress-fill" 
                :style="{ width: progressPercent + '%' }"
              ></div>
            </div>
          </div>
        </div>
        <div class="job-actions-active" :class="{ locked: damageLockApplies }">
          <template v-if="hasTechAssigned">
            <div class="tech-work-container">
              <template v-if="assignedTech && assignedTech.jobId">
                <div class="tech-status-title">{{ techStatus }}</div>
                <div class="tech-progress-bar-bg">
                  <div class="tech-progress-bar-fill" :style="{ width: techProgress + '%' }"></div>
                </div>
              </template>
              <div class="tech-message">{{ techName || 'Tech' }} is working on this</div>
            </div>
          </template>
          <template v-else-if="damageLockApplies">
            <div class="lock-message">Customer Vehicle Damaged</div>
            <button class="btn btn-danger" @mousedown.stop @click.stop="$emit('abandon', job)">
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <line x1="18" y1="6" x2="6" y2="18"/>
                <line x1="6" y1="6" x2="18" y2="18"/>
              </svg>
              Abandon
            </button>
          </template>
          <template v-else>
            <button 
              v-if="canComplete || canCompleteLocal"
              class="btn btn-success"
              @click.stop="$emit('complete', job)"
            >
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/>
                <polyline points="22 4 12 14.01 9 11.01"/>
              </svg>
              Complete Job
            </button>
            <template v-else>
              <button 
                class="btn btn-primary"
                @click.stop="isPulledOut ? $emit('put-away') : $emit('pull-out', job)"
                :disabled="!isPulledOut && hasPulledOutVehicle"
              >
                {{ isPulledOut ? 'Put Away Vehicle' : 'Pull Out Vehicle' }}
              </button>
              <button class="btn btn-danger" @mousedown.stop @click.stop="$emit('abandon', job)">
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                  <line x1="18" y1="6" x2="6" y2="18"/>
                  <line x1="6" y1="6" x2="18" y2="18"/>
                </svg>
                Abandon
              </button>
            </template>
          </template>
        </div>
      </div>
      <template v-else>
        <div class="image-section-active-horizontal">
          <div class="job-image-active-horizontal">
            <img :src="job.vehicleImage" :alt="job.vehicleName" />
            <span class="status-badge" :class="statusClass">{{ statusText }}</span>
          </div>
          <h3 class="vehicle-name-active-horizontal">
            {{ job.vehicleYear }} {{ job.vehicleName }}
          </h3>
        </div>
        <div class="job-info-active-horizontal">
          <div class="reward-container-active">
            <span class="reward-label">Payment</span>
            <span class="reward-value">${{ job.reward.toLocaleString() }}</span>
          </div>
          <div class="job-metrics-active">
            <div class="goal-chip">
              <div class="goal-chip-content">
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                  <circle cx="12" cy="12" r="10"/>
                  <circle cx="12" cy="12" r="6"/>
                  <path d="M12 2v4m0 12v4M2 12h4m12 0h4"/>
                </svg>
                <div class="goal-chip-text">
                  <span class="goal-chip-label">Goal</span>
                  <span class="goal-chip-value">{{ job.goal }}</span>
                </div>
                <div class="current-time-wrapper">
                  <span class="current-time-label">Current</span>
                  <span class="current-time-value">{{ formatTimeWithUnit(job.currentTime ?? job.baselineTime, job.timeUnit, job.decimalPlaces) }}</span>
                </div>
              </div>
              <div class="progress-bar">
                <div 
                  class="progress-fill" 
                  :style="{ width: progressPercent + '%' }"
                ></div>
              </div>
            </div>
          </div>
          <div class="job-actions-active-horizontal" :class="{ locked: damageLockApplies }">
            <template v-if="hasTechAssigned">
              <div class="tech-work-container">
                <template v-if="assignedTech && assignedTech.jobId">
                  <div class="tech-status-title">{{ techStatus }}</div>
                  <div class="tech-progress-bar-bg">
                    <div class="tech-progress-bar-fill" :style="{ width: techProgress + '%' }"></div>
                  </div>
                </template>
                <div class="tech-message">{{ techName || 'Tech' }} is working on this</div>
              </div>
            </template>
            <template v-else-if="damageLockApplies">
              <div class="lock-message">Customer Vehicle Damaged</div>
              <button class="btn btn-danger" @mousedown.stop @click.stop="$emit('abandon', job)">
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                  <line x1="18" y1="6" x2="6" y2="18"/>
                  <line x1="6" y1="6" x2="18" y2="18"/>
                </svg>
                Abandon
              </button>
            </template>
            <template v-else>
              <button 
                v-if="canComplete || canCompleteLocal"
                class="btn btn-success"
                @click.stop="$emit('complete', job)"
              >
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                  <path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/>
                  <polyline points="22 4 12 14.01 9 11.01"/>
                </svg>
                Complete Job
              </button>
              <template v-else>
                <button 
                  class="btn btn-primary"
                  @click.stop="isPulledOut ? $emit('put-away') : $emit('pull-out', job)"
                  :disabled="!isPulledOut && hasPulledOutVehicle"
                >
                  {{ isPulledOut ? 'Put Away Vehicle' : 'Pull Out Vehicle' }}
                </button>
                <button class="btn btn-danger" @mousedown.stop @click.stop="$emit('abandon', job)">
                  <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                    <line x1="18" y1="6" x2="6" y2="18"/>
                    <line x1="6" y1="6" x2="18" y2="18"/>
                  </svg>
                  Abandon
                </button>
              </template>
            </template>
          </div>
        </div>
      </template>
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
  isVertical: {
    type: Boolean,
    default: false
  },
  businessId: String,
  assignMode: {
    type: Boolean,
    default: false
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
    postUpdate: "Final Verification",
    completed: "Completed",
    failed: "Failed",
    idle: "Idle",
    build: "Building Vehicle",
    update: "Tuning Vehicle",
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
  
  // If time is 60 seconds or more, format as "X min Y s" or just "X min" if seconds are 0
  if (time >= 60) {
    const minutes = Math.floor(time / 60)
    const seconds = Math.round(time % 60)
    // Only show seconds if they're significant (>= 1)
    if (seconds >= 1) {
      return `${minutes} min ${seconds} s`
    } else {
      return `${minutes} min`
    }
  }
  
  // Use decimalPlaces from config, default to 0 if not specified
  const decimals = decimalPlaces || 0
  if (decimals > 0) {
    return time.toFixed(decimals) + ' s'
  }
  
  // Otherwise show as seconds rounded to nearest integer
  return Math.round(time) + ' s'
}

const formatTimeWithUnit = (time, timeUnit, decimalPlaces) => {
  if (typeof time !== 'number' || isNaN(time)) {
    return (time || '0') + (timeUnit || '')
  }
  
  // Times are always stored in seconds in the backend
  // Format them appropriately regardless of timeUnit
  const formatted = formatTime(time, decimalPlaces)
  
  // formatTime already includes units, so just return it
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

.job-content-new-vertical {
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
  
  &.large {
      font-size: 1.125rem;
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
  flex-direction: row; /* Ensure row layout */
}

.job-actions-new-horizontal {
    display: flex;
    gap: 0.5rem;
    margin-top: auto;
}

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
  
  &.btn-icon {
    padding: 0.5rem;
    width: 2.25rem; /* fixed width for icon buttons */
    flex-shrink: 0;
  }

  &.btn-primary {
    background: rgba(245, 73, 0, 1);
    color: white;
    &:hover:not(:disabled) { background: rgba(245, 73, 0, 0.9); }
    &:disabled { opacity: 0.5; cursor: not-allowed; }
  }
  
  &.btn-success {
    background: rgba(34, 197, 94, 1);
    color: white;
    &:hover:not(:disabled) { background: rgba(34, 197, 94, 0.9); }
    &:disabled { opacity: 0.5; cursor: not-allowed; }
  }
  
  &.btn-danger {
    background: rgba(239, 68, 68, 1);
    color: white;
    &:hover { background: rgba(239, 68, 68, 0.9); }
  }
}

/* Horizontal Specifics */
.image-section-new-horizontal {
  position: relative;
  width: 14rem;
  flex-shrink: 0;
}

.job-image-new-horizontal {
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

.vehicle-name-new-horizontal {
  margin: 0.5rem 0 0 0;
  color: white;
  font-size: 1rem;
  font-weight: 600;
  line-height: 1.3;
}

.job-content-new {
  &:not(.vertical) {
    display: flex;
    gap: 1rem;
  }
}

.job-info-new-horizontal {
    flex: 1;
    display: flex;
    flex-direction: column;
    justify-content: space-between;
    gap: 0.5rem;
}

.job-meta-column {
    display: flex;
    flex-direction: column;
    gap: 0.25rem;
}

/* Active Job Styles (Preserved/Tweaked) */
.job-content-active-vertical {
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
}

.job-image-active {
  position: relative;
  width: 100%;
  border-radius: 0.375rem;
  overflow: hidden;
  aspect-ratio: 16/9;
  background: rgba(0, 0, 0, 0.5);
  
  img {
    width: 100%;
    height: 100%;
    object-fit: cover;
  }
  
  .status-badge {
    position: absolute;
    top: 0.5rem;
    right: 0.5rem;
    padding: 0.25rem 0.5rem;
    border-radius: 0.25rem;
    font-size: 0.75rem;
    font-weight: 500;
    background: rgba(234, 179, 8, 0.9);
    color: black;
    box-shadow: 0 2px 4px rgba(0,0,0,0.2);
  }
}

.vehicle-name-active {
  font-size: 1rem;
  font-weight: 600;
  color: white;
  margin: 0;
}

.reward-container-active {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 0.5rem;
  background: rgba(34, 197, 94, 0.1);
  border: 1px solid rgba(34, 197, 94, 0.2);
  border-radius: 0.375rem;
  
  .reward-label { font-size: 0.75rem; opacity: 0.7; }
  .reward-value { color: #22c55e; font-weight: 600; }
}

.job-metrics-active .goal-chip {
  background: rgba(255, 255, 255, 0.05);
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: 0.375rem;
  padding: 0.5rem;
  
  .goal-chip-content {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    margin-bottom: 0.5rem;
    
    svg { opacity: 0.8; color: #f97316; }
  }
  
  .goal-chip-text { flex: 1; }
  .goal-chip-label { font-size: 0.7rem; opacity: 0.6; display: block; }
  .goal-chip-value { font-weight: 600; font-size: 0.9rem; }
  
  .progress-bar {
    height: 4px;
    background: rgba(255, 255, 255, 0.1);
    border-radius: 2px;
    overflow: hidden;
    .progress-fill { height: 100%; background: #f97316; }
  }
}

.image-section-active-horizontal {
  width: 14rem;
  flex-shrink: 0;
}

.job-image-active-horizontal {
  position: relative;
  border-radius: 0.375rem;
  overflow: hidden;
  aspect-ratio: 16/9;
  
  img { width: 100%; height: 100%; object-fit: cover; }
  .status-badge {
    position: absolute;
    top: 0.5rem;
    right: 0.5rem;
    padding: 0.25rem 0.5rem;
    background: rgba(234, 179, 8, 0.9);
    color: black;
    border-radius: 0.25rem;
    font-size: 0.75rem;
    font-weight: 600;
  }
}

.vehicle-name-active-horizontal {
  font-size: 1rem;
  font-weight: 600;
  margin-top: 0.5rem;
  color: white;
}

.job-info-active-horizontal {
  flex: 1;
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
}

.job-actions-active, .job-actions-active-horizontal {
  margin-top: auto;
  display: flex;
  gap: 0.5rem;
  
  &.locked { flex-direction: column; }
}

.current-time-wrapper {
  text-align: right;
  .current-time-label { font-size: 0.7rem; opacity: 0.6; display: block; }
  .current-time-value { font-weight: 600; font-size: 0.9rem; }
}

.lock-message {
  color: #ef4444;
  font-size: 0.875rem;
  font-weight: 600;
  text-align: center;
  margin-bottom: 0.5rem;
}

.tech-work-container {
  background: rgba(245, 73, 0, 0.1);
  border: 1px solid rgba(245, 73, 0, 0.2);
  border-radius: 0.375rem;
  padding: 0.5rem;
  text-align: center;
  
  .tech-status-title { color: #f97316; font-size: 0.75rem; font-weight: 600; margin-bottom: 0.25rem; }
  .tech-progress-bar-bg { height: 4px; background: rgba(0,0,0,0.3); border-radius: 2px; overflow: hidden; }
  .tech-progress-bar-fill { height: 100%; background: #f97316; }
  .tech-message { font-size: 0.75rem; margin-top: 0.25rem; opacity: 0.8; }
}
</style>