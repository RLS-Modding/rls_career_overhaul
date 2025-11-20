<template>
  <div class="job-card" :class="{ active: isActive, vertical: isVertical }">
    <div v-if="!isActive" class="job-content-new" :class="{ vertical: isVertical }">
      <div v-if="isVertical" class="job-content-new-vertical">
        <div class="job-image-new">
          <img :src="job.vehicleImage" :alt="job.vehicleName" />
          <span class="status-badge" :class="statusClass">{{ statusText }}</span>
        </div>
        <h3 class="vehicle-name-new">
          {{ job.vehicleYear }} {{ job.vehicleName }}
          <span v-if="job.vehicleType" class="badge badge-orange">{{ job.vehicleType }}</span>
        </h3>
        <div class="reward-container-new">
          <span class="reward-label">Payment</span>
          <span class="reward-value">${{ job.reward.toLocaleString() }}</span>
        </div>
        <div class="job-metrics-new">
          <div class="goal-chip">
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <circle cx="12" cy="12" r="10"/>
              <circle cx="12" cy="12" r="6"/>
              <path d="M12 2v4m0 12v4M2 12h4m12 0h4"/>
            </svg>
            <div class="goal-chip-text">
              <span class="goal-chip-label">Goal</span>
              <span class="goal-chip-value">{{ job.goal }}</span>
            </div>
          </div>
        </div>
        <div
          class="expiration-chip"
          v-if="expirationText"
          :class="{ expired: isExpired }"
        >
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <circle cx="12" cy="12" r="10"/>
            <polyline points="12 6 12 12 16 14"/>
          </svg>
          <span>{{ expirationText }}</span>
        </div>
        <div class="job-actions-new">
          <button 
            class="btn btn-success" 
            :disabled="isAcceptDisabled"
            :title="isAcceptDisabled ? `Active job limit reached (${store.maxActiveJobs} max)` : ''"
            @click.stop="$emit('accept', job)"
          >
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/>
              <polyline points="22 4 12 14.01 9 11.01"/>
            </svg>
            Accept
          </button>
          <button class="btn btn-danger" @click.stop="$emit('decline', job)">
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <line x1="18" y1="6" x2="6" y2="18"/>
              <line x1="6" y1="6" x2="18" y2="18"/>
            </svg>
            Decline
          </button>
        </div>
      </div>
      <template v-else>
        <div class="image-section-new-horizontal">
          <div class="job-image-new-horizontal">
            <img :src="job.vehicleImage" :alt="job.vehicleName" />
            <span class="status-badge" :class="statusClass">{{ statusText }}</span>
          </div>
          <h3 class="vehicle-name-new-horizontal">
            {{ job.vehicleYear }} {{ job.vehicleName }}
            <span v-if="job.vehicleType" class="badge badge-orange">{{ job.vehicleType }}</span>
          </h3>
        </div>
        <div class="job-info-new-horizontal">
          <div class="reward-container-new">
            <span class="reward-label">Payment</span>
            <span class="reward-value">${{ job.reward.toLocaleString() }}</span>
          </div>
          <div class="job-metrics-new">
            <div class="goal-chip">
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <circle cx="12" cy="12" r="10"/>
                <circle cx="12" cy="12" r="6"/>
                <path d="M12 2v4m0 12v4M2 12h4m12 0h4"/>
              </svg>
              <div class="goal-chip-text">
                <span class="goal-chip-label">Goal</span>
                <span class="goal-chip-value">{{ job.goal }}</span>
              </div>
            </div>
          </div>
          <div
            class="expiration-chip"
            v-if="expirationText"
            :class="{ expired: isExpired }"
          >
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <circle cx="12" cy="12" r="10"/>
              <polyline points="12 6 12 12 16 14"/>
            </svg>
            <span>{{ expirationText }}</span>
          </div>
          <div class="job-actions-new-horizontal">
            <button 
              class="btn btn-success" 
              :disabled="isAcceptDisabled"
              :title="isAcceptDisabled ? `Active job limit reached (${store.maxActiveJobs} max)` : ''"
              @click.stop="$emit('accept', job)"
            >
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/>
                <polyline points="22 4 12 14.01 9 11.01"/>
              </svg>
              Accept
            </button>
            <button class="btn btn-danger" @click.stop="$emit('decline', job)">
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <line x1="18" y1="6" x2="6" y2="18"/>
                <line x1="6" y1="6" x2="18" y2="18"/>
              </svg>
              Decline
            </button>
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
          <span v-if="job.vehicleType" class="badge badge-orange">{{ job.vehicleType }}</span>
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
          <template v-if="damageLockApplies">
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
            <span v-if="job.vehicleType" class="badge badge-orange">{{ job.vehicleType }}</span>
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
            <template v-if="damageLockApplies">
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
  businessId: String
})

const emit = defineEmits(['pull-out', 'put-away', 'abandon', 'accept', 'decline', 'complete'])

const store = useBusinessComputerStore()
const normalizeJobId = (value) => {
  if (value === undefined || value === null) {
    return null
  }
  return String(value)
}
const jobIdentifier = computed(() => normalizeJobId(props.job?.jobId ?? props.job?.id))
const pulledOutJobIdentifier = computed(() => normalizeJobId(store.pulledOutVehicle?.jobId))
const damageLockApplies = computed(() => {
  if (!store.isDamageLocked || !jobIdentifier.value || !pulledOutJobIdentifier.value) {
    return false
  }
  return jobIdentifier.value === pulledOutJobIdentifier.value
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
  return store.pulledOutVehicle && store.pulledOutVehicle.jobId === props.job.id
})

const hasPulledOutVehicle = computed(() => {
  return store.pulledOutVehicle !== null && !isPulledOut.value
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
.lock-message {
  color: rgba(239, 68, 68, 1);
  font-size: 0.875rem;
  font-weight: 500;
  text-align: center;
  margin-bottom: 0.25rem;
  width: 100%;
}

.job-card {
  background: rgba(23, 23, 23, 0.5);
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: 0.5rem;
  padding: 1rem;
  transition: border-color 0.2s;
  
  &:hover {
    border-color: rgba(245, 73, 0, 0.5);
  }
}

.job-content {
  display: grid;
  grid-template-columns: auto 1fr;
  gap: 1rem;
  align-items: start;
}

.job-card.vertical .job-content {
  grid-template-columns: 1fr;
}

.image-section {
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
  flex-shrink: 0;
}

.job-image {
  position: relative;
  width: 12rem;
  aspect-ratio: 16/9;
  border-radius: 0.5rem;
  overflow: hidden;
  background: rgba(0, 0, 0, 0.5);
  
  img {
    width: 100%;
    height: 100%;
    object-fit: contain;
  }
  
  .status-badge {
    position: absolute;
    top: 0.5rem;
    right: 0.5rem;
    padding: 0.25rem 0.5rem;
    border-radius: 0.25rem;
    font-size: 0.75rem;
    font-weight: 500;
    
    &.status-active {
      background: rgba(234, 179, 8, 0.7);
      color: white;
      border: none;
    }
    
    &.status-available {
      background: rgba(59, 130, 246, 0.7);
      color: white;
      border: none;
    }
  }
}

.image-header {
  display: flex;
  flex-direction: column;
  gap: 0.25em;
  width: 12rem;
  
  h4 {
    margin: 0;
    color: white;
    font-size: 1rem;
    font-weight: 600;
    word-wrap: break-word;
    overflow-wrap: break-word;
  }
  
}

.job-card.vertical {
  padding: 1em;
  
  .job-content {
    display: flex;
    flex-direction: column;
    gap: 1em;
  }
  
  .job-image {
    width: 100%;
    margin-bottom: 0;
  }
  
  .job-details {
    display: flex;
    flex-direction: column;
    gap: 0.75em;
    padding: 0;
  }
  
  .job-header {
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    justify-content: flex-start;
    margin-bottom: 0;
    gap: 0.5em;
    
    h4 {
      margin: 0;
      flex: 1;
      font-size: 1rem;
      font-weight: 600;
      color: white;
    }
    
    .header-meta {
      display: flex;
      align-items: center;
      gap: 0.75em;
      flex-wrap: wrap;
    }
    
    .vehicle-type-badge-inline {
      display: inline-block;
      padding: 0.25em 0.5em;
      background: rgba(245, 73, 0, 0.2);
      color: rgba(245, 73, 0, 1);
      border: 1px solid rgba(245, 73, 0, 0.5);
      border-radius: 0.25rem;
      font-size: 0.75rem;
      font-weight: 500;
    }
    
  }
  
  .job-goal-wrapper {
    padding: 0.75em;
    background: rgba(38, 38, 38, 0.6);
    border-radius: 0.25rem;
    display: flex;
    flex-direction: column;
    gap: 0.5em;
    
    .job-goal {
      display: flex;
      align-items: center;
      gap: 0.5em;
      margin: 0;
      
      svg {
        color: rgba(245, 73, 0, 1);
        flex-shrink: 0;
      }
      
      .goal-label {
        color: rgba(255, 255, 255, 0.6);
        font-size: 0.75rem;
      }
    }
    
    .goal-value {
      color: rgba(245, 73, 0, 1);
      font-size: 0.875rem;
      font-weight: 500;
      margin-left: 1.5em;
    }
  }
  
  .job-stats {
    margin-top: 0;
    margin-bottom: 0;
    
    .stat {
      padding: 0.75em;
      background: rgba(38, 38, 38, 0.6);
    }
  }
  
  .job-deadline {
    margin-top: 0;
    margin-bottom: 0;
    font-size: 0.875rem;
  }
  
  .job-actions {
    margin-top: 0.5em;
  }
}

.job-details {
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
  min-height: 0;
}

.job-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  
  h4 {
    margin: 0;
    color: white;
    font-size: 1rem;
    font-weight: 600;
  }
}

.job-card.active .job-header {
  flex-direction: column;
  align-items: flex-start;
  gap: 0.25em;
}

.vehicle-type-badge {
  margin-top: 0.5rem;
  
  span {
    display: inline-block;
    padding: 0.25rem 0.5rem;
    background: rgba(245, 73, 0, 0.2);
    color: rgba(245, 73, 0, 1);
    border: 1px solid rgba(245, 73, 0, 0.5);
    border-radius: 0.25rem;
    font-size: 0.75rem;
    font-weight: 500;
  }
}

.new-job-info {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
}

.new-job-info .goal-chip {
  justify-content: space-between;
}

.reward-info {
  display: flex;
  flex-direction: column;
  align-items: flex-end;
  gap: 0.1rem;
}

.reward-label {
  font-size: 0.7rem;
  color: rgba(255, 255, 255, 0.5);
}

.reward-value {
  font-size: 0.875rem;
  color: rgba(34, 197, 94, 1);
  font-weight: 600;
}

.job-goal-wrapper {
  display: none;
}

.job-card.vertical .job-goal-wrapper {
  display: flex;
  flex-direction: column;
  gap: 0.5em;
  padding: 0.75em;
  background: rgba(38, 38, 38, 0.6);
  border-radius: 0.25rem;
  
  .job-goal {
    display: flex;
    align-items: center;
    gap: 0.5em;
    margin: 0;
    
    svg {
      color: rgba(245, 73, 0, 1);
      flex-shrink: 0;
    }
    
    .goal-label {
      color: rgba(255, 255, 255, 0.6);
      font-size: 0.75rem;
    }
  }
  
  .goal-value {
    color: rgba(245, 73, 0, 1);
    font-size: 0.875rem;
    font-weight: 500;
    margin-left: 1.5em;
  }
}

.job-goal {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  color: rgba(245, 73, 0, 1);
  font-weight: 500;
  font-size: 0.875rem;
  
  svg {
    flex-shrink: 0;
    color: rgba(245, 73, 0, 1);
  }
  
  span {
    color: rgba(245, 73, 0, 1);
  }
}

.job-card.vertical .job-goal {
  display: none;
}

.job-card.active .job-goal {
  span {
    color: rgba(245, 73, 0, 1);
  }
}

.job-stats {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 0.75rem;
  
  .stat {
    padding: 0.5rem;
    background: rgba(38, 38, 38, 0.6);
    border-radius: 0.25rem;
    
    .label {
      display: block;
      color: rgba(255, 255, 255, 0.5);
      font-size: 0.75rem;
      margin-bottom: 0.25rem;
    }
    
    .value {
      display: block;
      font-weight: 500;
      font-size: 0.875rem;
      
      &.budget {
        color: rgba(245, 73, 0, 1);
      }
      
      &.reward {
        color: rgba(34, 197, 94, 1);
      }
    }
  }
}

.job-card.active .job-stats {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 0.75em;
  
  .stat {
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    gap: 0.25em;
    padding: 0.75em;
    background: rgba(38, 38, 38, 0.6);
    border-radius: 0.25rem;
    
    .label {
      display: block;
      margin-bottom: 0;
      color: rgba(255, 255, 255, 0.5);
      font-size: 0.75rem;
    }
    
    .value {
      display: block;
    }
  }
}

.job-card.vertical.active .job-stats {
  .stat {
    padding: 0.75em;
  }
}

.job-progress {
  display: flex;
  flex-direction: column;
}

.goal-chip {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
  padding: 0.5rem 0.75rem;
  background: rgba(245, 73, 0, 0.15);
  border-radius: 0.45rem;
  border: 1px solid rgba(245, 73, 0, 0.35);
}

.goal-chip-content {
  display: flex;
  align-items: center;
  gap: 0.75rem;
  justify-content: space-between;
  
  svg {
    color: rgba(245, 73, 0, 1);
    flex-shrink: 0;
  }
}

.goal-chip-text {
  display: flex;
  flex-direction: column;
  gap: 0.1rem;
  flex: 1;
}

.goal-chip-label {
  font-size: 0.75rem;
  color: rgba(255, 255, 255, 0.6);
}

.goal-chip-value {
  font-size: 0.9rem;
  color: rgba(255, 255, 255, 0.95);
  font-weight: 600;
}

.current-time-wrapper {
  display: flex;
  flex-direction: column;
  gap: 0.1rem;
  align-items: flex-end;
  text-align: right;
}

.current-time-label {
  font-size: 0.75rem;
  color: rgba(255, 255, 255, 0.6);
}

.current-time-value {
  font-size: 0.9rem;
  color: rgba(255, 255, 255, 0.95);
  font-weight: 600;
  white-space: nowrap;
}

.goal-performance {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 0.75rem;
}

.goal-performance .metric {
  padding: 0.75rem;
  background: rgba(255, 255, 255, 0.04);
  border-radius: 0.45rem;
  border: 1px solid rgba(255, 255, 255, 0.08);
  display: flex;
  flex-direction: column;
  gap: 0.25rem;
}

.goal-performance .metric-label {
  font-size: 0.75rem;
  color: rgba(255, 255, 255, 0.6);
}

.goal-performance .metric-value {
  font-size: 1rem;
  font-weight: 600;
  color: white;
}

.goal-performance .metric.goal .metric-value {
  color: rgba(245, 73, 0, 1);
}

.goal-chip .progress-bar {
  width: 100%;
  height: 0.375rem;
  background: rgba(0, 0, 0, 0.2);
  border-radius: 0.1875rem;
  overflow: hidden;
  margin-top: 0.125rem;
}

.progress-fill {
  height: 100%;
  background: rgba(245, 73, 0, 1);
  transition: width 0.3s;
}

.job-actions {
  display: flex;
  gap: 0.5rem;
  margin-top: auto;
  flex-shrink: 0;
}

.btn {
  flex: 1;
  padding: 0.5rem 1rem;
  border-radius: 0.375rem;
  font-size: 0.875rem;
  font-weight: 500;
  cursor: pointer;
  transition: background-color 0.2s, opacity 0.2s;
  border: none;
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 0.5rem;
  box-sizing: border-box;
  
  svg {
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
      pointer-events: none;
      flex-shrink: 0;
    }
  }
  
  &.btn-secondary {
    background: rgba(55, 55, 55, 1);
    color: white;
    
    &:hover {
      background: rgba(75, 75, 75, 1);
    }
  }
  
  &.btn-success {
    background: rgba(34, 197, 94, 1);
    color: white;
    
    &:hover {
      background: rgba(34, 197, 94, 0.9);
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

.job-content-active {
  &.vertical {
    display: flex;
    flex-direction: column;
    gap: 1rem;
  }
  
  &:not(.vertical) {
    display: grid;
    grid-template-columns: auto 1fr;
    gap: 1.5rem;
    align-items: stretch;
  }
}

.job-content-active-vertical {
  display: flex;
  flex-direction: column;
  gap: 1rem;
}

.job-image-active {
  position: relative;
  width: 100%;
  border-radius: 0.5rem;
  overflow: hidden;
  background: rgba(0, 0, 0, 0.5);
  
  img {
    width: 100%;
    height: auto;
    display: block;
  }
  
  .status-badge {
    position: absolute;
    top: 0.5rem;
    right: 0.5rem;
    padding: 0.25rem 0.5rem;
    border-radius: 0.25rem;
    font-size: 0.75rem;
    font-weight: 500;
    
    &.status-active {
      background: rgba(234, 179, 8, 0.7);
      color: white;
      border: none;
    }
    
    &.status-available {
      background: rgba(59, 130, 246, 0.7);
      color: white;
      border: none;
    }
  }
}

.image-section-active-horizontal {
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
  flex-shrink: 0;
  width: 16rem;
  max-width: 16rem;
}

.job-image-active-horizontal {
  position: relative;
  width: 16rem;
  border-radius: 0.5rem;
  overflow: hidden;
  background: rgba(0, 0, 0, 0.5);
  
  img {
    width: 100%;
    height: auto;
    display: block;
  }
  
  .status-badge {
    position: absolute;
    top: 0.5rem;
    right: 0.5rem;
    padding: 0.25rem 0.5rem;
    border-radius: 0.25rem;
    font-size: 0.75rem;
    font-weight: 500;
    
    &.status-active {
      background: rgba(234, 179, 8, 0.7);
      color: white;
      border: none;
    }
    
    &.status-available {
      background: rgba(59, 130, 246, 0.7);
      color: white;
      border: none;
    }
  }
}

.vehicle-name-active {
  margin: 0;
  color: white;
  font-size: 1.25rem;
  font-weight: 600;
  word-wrap: break-word;
  overflow-wrap: break-word;
  line-height: 1.5;
  
  .badge {
    display: inline-block;
    margin-left: 0.5rem;
    padding: 0.25rem 0.5rem;
    border-radius: 0.25rem;
    font-size: 0.75rem;
    font-weight: 500;
    vertical-align: middle;
    
    &.badge-orange {
      background: rgba(245, 73, 0, 0.2);
      color: rgba(245, 73, 0, 1);
      border: 1px solid rgba(245, 73, 0, 0.5);
    }
  }
}

.vehicle-name-active-horizontal {
  margin: 0;
  color: white;
  font-size: 1.25rem;
  font-weight: 600;
  word-wrap: break-word;
  overflow-wrap: break-word;
  line-height: 1.5;
  
  .badge {
    display: inline-block;
    margin-left: 0.5rem;
    padding: 0.25rem 0.5rem;
    border-radius: 0.25rem;
    font-size: 0.75rem;
    font-weight: 500;
    vertical-align: middle;
    
    &.badge-orange {
      background: rgba(245, 73, 0, 0.2);
      color: rgba(245, 73, 0, 1);
      border: 1px solid rgba(245, 73, 0, 0.5);
    }
  }
}

.reward-container-active {
  width: 100%;
  padding: 0.75rem 1rem;
  background: rgba(34, 197, 94, 0.15);
  border-radius: 0.45rem;
  border: 1px solid rgba(34, 197, 94, 0.35);
  display: flex;
  flex-direction: column;
  gap: 0.25rem;
  
  .reward-label {
    font-size: 0.75rem;
    color: rgba(255, 255, 255, 0.6);
  }
  
  .reward-value {
    font-size: 1.125rem;
    color: rgba(34, 197, 94, 1);
    font-weight: 600;
  }
}

.job-info-active-horizontal {
  display: flex;
  flex-direction: column;
  gap: 1rem;
}

.job-metrics-active {
  display: flex;
  flex-direction: column;
}

.job-actions-active {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
  
  .btn {
    width: 100%;
  }
}

.job-actions-active-horizontal {
  display: flex;
  gap: 0.5rem;
  margin-top: auto;
  
  .btn {
    flex: 0 0 calc(50% - 0.25rem);
    min-width: 0;
    
    &:disabled {
      flex: 0 0 calc(50% - 0.25rem);
    }
  }

  &.locked {
    flex-direction: column;

    .btn {
      flex: 1;
      width: 100%;
    }
  }
}

.job-content-new {
  &.vertical {
    display: flex;
    flex-direction: column;
    gap: 1rem;
  }
  
  &:not(.vertical) {
    display: grid;
    grid-template-columns: auto 1fr;
    gap: 1.5rem;
    align-items: stretch;
  }
}

.job-content-new-vertical {
  display: flex;
  flex-direction: column;
  gap: 1rem;
}

.job-image-new {
  position: relative;
  width: 100%;
  border-radius: 0.5rem;
  overflow: hidden;
  background: rgba(0, 0, 0, 0.5);
  
  img {
    width: 100%;
    height: auto;
    display: block;
  }
  
  .status-badge {
    position: absolute;
    top: 0.5rem;
    right: 0.5rem;
    padding: 0.25rem 0.5rem;
    border-radius: 0.25rem;
    font-size: 0.75rem;
    font-weight: 500;
    
    &.status-active {
      background: rgba(234, 179, 8, 0.7);
      color: white;
      border: none;
    }
    
    &.status-available {
      background: rgba(59, 130, 246, 0.7);
      color: white;
      border: none;
    }
  }
}

.image-section-new-horizontal {
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
  flex-shrink: 0;
  width: 16rem;
  max-width: 16rem;
}

.job-image-new-horizontal {
  position: relative;
  width: 16rem;
  border-radius: 0.5rem;
  overflow: hidden;
  background: rgba(0, 0, 0, 0.5);
  
  img {
    width: 100%;
    height: auto;
    display: block;
  }
  
  .status-badge {
    position: absolute;
    top: 0.5rem;
    right: 0.5rem;
    padding: 0.25rem 0.5rem;
    border-radius: 0.25rem;
    font-size: 0.75rem;
    font-weight: 500;
    
    &.status-active {
      background: rgba(234, 179, 8, 0.7);
      color: white;
      border: none;
    }
    
    &.status-available {
      background: rgba(59, 130, 246, 0.7);
      color: white;
      border: none;
    }
  }
}

.vehicle-name-new {
  margin: 0;
  color: white;
  font-size: 1.25rem;
  font-weight: 600;
  word-wrap: break-word;
  overflow-wrap: break-word;
  line-height: 1.5;
  
  .badge {
    display: inline-block;
    margin-left: 0.5rem;
    padding: 0.25rem 0.5rem;
    border-radius: 0.25rem;
    font-size: 0.75rem;
    font-weight: 500;
    vertical-align: middle;
    
    &.badge-orange {
      background: rgba(245, 73, 0, 0.2);
      color: rgba(245, 73, 0, 1);
      border: 1px solid rgba(245, 73, 0, 0.5);
    }
  }
}

.vehicle-name-new-horizontal {
  margin: 0;
  color: white;
  font-size: 1.25rem;
  font-weight: 600;
  word-wrap: break-word;
  overflow-wrap: break-word;
  line-height: 1.5;
  
  .badge {
    display: inline-block;
    margin-left: 0.5rem;
    padding: 0.25rem 0.5rem;
    border-radius: 0.25rem;
    font-size: 0.75rem;
    font-weight: 500;
    vertical-align: middle;
    
    &.badge-orange {
      background: rgba(245, 73, 0, 0.2);
      color: rgba(245, 73, 0, 1);
      border: 1px solid rgba(245, 73, 0, 0.5);
    }
  }
}

.reward-container-new {
  width: 100%;
  padding: 0.75rem 1rem;
  background: rgba(34, 197, 94, 0.15);
  border-radius: 0.45rem;
  border: 1px solid rgba(34, 197, 94, 0.35);
  display: flex;
  flex-direction: column;
  gap: 0.25rem;
  
  .reward-label {
    font-size: 0.75rem;
    color: rgba(255, 255, 255, 0.6);
  }
  
  .reward-value {
    font-size: 1.125rem;
    color: rgba(34, 197, 94, 1);
    font-weight: 600;
  }
}

.job-info-new-horizontal {
  display: flex;
  flex-direction: column;
  gap: 1rem;
}

.job-metrics-new {
  display: flex;
  flex-direction: column;
}

.job-actions-new {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
  
  .btn {
    width: 100%;
  }
}

.job-actions-new-horizontal {
  display: flex;
  gap: 0.5rem;
  margin-top: auto;
  
  .btn {
    flex: 0 0 calc(50% - 0.25rem);
    min-width: 0;
    
    &:disabled {
      flex: 0 0 calc(50% - 0.25rem);
    }
  }
}

.expiration-chip {
  display: inline-flex;
  align-items: center;
  gap: 0.35rem;
  padding: 0.35rem 0.75rem;
  border-radius: 999px;
  font-size: 0.75rem;
  font-weight: 500;
  width: fit-content;
  background: rgba(59, 130, 246, 0.15);
  border: 1px solid rgba(59, 130, 246, 0.35);
  color: rgba(255, 255, 255, 0.85);
  margin-top: 0.25rem;
}

.expiration-chip svg {
  color: rgba(59, 130, 246, 1);
}

.expiration-chip.expired {
  background: rgba(239, 68, 68, 0.12);
  border-color: rgba(239, 68, 68, 0.4);
  color: rgba(239, 68, 68, 1);
}

.expiration-chip.expired svg {
  color: rgba(239, 68, 68, 1);
}
</style>

