<template>
  <div class="job-card" :class="{ active: isActive, vertical: isVertical }">
    <div class="job-content">
      <div class="image-section">
        <div class="job-image">
          <img :src="job.vehicleImage" :alt="job.vehicleName" />
          <span class="status-badge" :class="statusClass">{{ statusText }}</span>
        </div>
        <div v-if="!isVertical" class="image-header">
          <h4>{{ job.vehicleYear }} {{ job.vehicleName }}</h4>
          <span class="job-id">Job ID: {{ job.id }}</span>
        </div>
      </div>
      <div class="job-details">
        <div v-if="isVertical" class="job-header">
          <h4>{{ job.vehicleYear }} {{ job.vehicleName }}</h4>
          <div class="header-meta">
            <span v-if="job.vehicleType" class="vehicle-type-badge-inline">
              {{ job.vehicleType }}
            </span>
            <span class="job-id">Job ID: {{ job.id }}</span>
          </div>
        </div>
        <div v-if="!isActive && job.vehicleType && !isVertical" class="vehicle-type-badge">
          <span>{{ job.vehicleType }}</span>
        </div>
        <div class="job-goal-wrapper">
          <div class="job-goal">
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <circle cx="12" cy="12" r="10"/>
              <circle cx="12" cy="12" r="6"/>
              <path d="M12 2v4m0 12v4M2 12h4m12 0h4"/>
            </svg>
            <span class="goal-label">Goal</span>
          </div>
          <div class="goal-value">{{ job.goal }}</div>
        </div>
        <div class="job-stats">
          <div class="stat">
            <span class="label">Budget</span>
            <span class="value budget">${{ job.budget.toLocaleString() }}</span>
          </div>
          <div class="stat">
            <span class="label">Reward</span>
            <span class="value reward">${{ job.reward.toLocaleString() }}</span>
          </div>
        </div>
        <div v-if="!isActive && job.deadline" class="job-deadline">
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <rect x="3" y="4" width="18" height="18" rx="2" ry="2"/>
            <line x1="16" y1="2" x2="16" y2="6"/>
            <line x1="8" y1="2" x2="8" y2="6"/>
            <line x1="3" y1="10" x2="21" y2="10"/>
          </svg>
          <span>Deadline: {{ job.deadline }}</span>
        </div>
        <div v-if="isActive" class="job-progress">
          <div class="progress-header">
            <span>Performance</span>
            <span>{{ formatTimeWithUnit(job.currentTime, job.timeUnit) }}</span>
          </div>
          <div class="progress-bar">
            <div 
              class="progress-fill" 
              :style="{ width: progressPercent + '%' }"
            ></div>
          </div>
          <span class="progress-goal">Goal: {{ formatTimeWithUnit(job.goalTime, job.timeUnit) }}</span>
        </div>
        <div class="job-actions">
          <template v-if="isActive">
            <button 
              v-if="canComplete || canCompleteLocal"
              class="btn btn-success"
              @click="$emit('complete', job)"
            >
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/>
                <polyline points="22 4 12 14.01 9 11.01"/>
              </svg>
              Complete Job
            </button>
            <template v-else>
              <button 
                v-if="isPulledOut"
                class="btn btn-primary"
                @click="$emit('put-away')"
              >
                Put Away Vehicle
              </button>
              <button 
                v-else
                class="btn btn-primary"
                @click="$emit('pull-out', job)"
                :disabled="hasPulledOutVehicle"
              >
                Pull Out Vehicle
              </button>
              <button class="btn btn-danger" @click="$emit('abandon', job)">
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                  <line x1="18" y1="6" x2="6" y2="18"/>
                  <line x1="6" y1="6" x2="18" y2="18"/>
                </svg>
                Abandon
              </button>
            </template>
          </template>
          <template v-else>
            <button class="btn btn-success" @click="$emit('accept', job)">
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/>
                <polyline points="22 4 12 14.01 9 11.01"/>
              </svg>
              Accept
            </button>
            <button class="btn btn-danger" @click="$emit('decline', job)">
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <line x1="18" y1="6" x2="6" y2="18"/>
                <line x1="6" y1="6" x2="18" y2="18"/>
              </svg>
              Decline
            </button>
          </template>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup>
import { computed, ref, onMounted, watch } from "vue"
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
const canComplete = ref(false)

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

const formatTime = (time) => {
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
  
  // Otherwise show as seconds rounded to nearest integer
  return Math.round(time) + ' s'
}

const formatTimeWithUnit = (time, timeUnit) => {
  if (typeof time !== 'number' || isNaN(time)) {
    return (time || '0') + (timeUnit || '')
  }
  
  // Times are always stored in seconds in the backend
  // Format them appropriately regardless of timeUnit
  const formatted = formatTime(time)
  
  // formatTime already includes units, so just return it
  return formatted
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

onMounted(() => {
  checkCanComplete()
})

watch(() => [props.isActive, props.job.currentTime, props.job.goalTime, props.job.jobId], () => {
  checkCanComplete()
}, { immediate: false })

watch(() => props.job, () => {
  checkCanComplete()
}, { deep: true })
</script>

<style scoped lang="scss">
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
    
    &.status-active {
      background: rgba(234, 179, 8, 0.2);
      color: rgba(234, 179, 8, 1);
      border: 1px solid rgba(234, 179, 8, 0.5);
    }
    
    &.status-available {
      background: rgba(59, 130, 246, 0.2);
      color: rgba(59, 130, 246, 1);
      border: 1px solid rgba(59, 130, 246, 0.5);
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
  
  .job-id {
    color: rgba(255, 255, 255, 0.5);
    font-size: 0.875rem;
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
    
    .job-id {
      margin-left: 0;
      white-space: nowrap;
      font-size: 0.875rem;
      color: rgba(255, 255, 255, 0.5);
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
  
  .job-id {
    color: rgba(255, 255, 255, 0.5);
    font-size: 0.875rem;
  }
}

.job-card.active .job-header {
  flex-direction: column;
  align-items: flex-start;
  gap: 0.25em;
  
  .job-id {
    margin-left: 0;
  }
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

.job-deadline {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  color: rgba(255, 255, 255, 0.6);
  font-size: 0.875rem;
  
  svg {
    flex-shrink: 0;
    color: rgba(245, 73, 0, 1);
  }
  
  span {
    color: white;
  }
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
  .progress-header {
    display: flex;
    justify-content: space-between;
    font-size: 0.875rem;
    color: rgba(255, 255, 255, 0.7);
    margin-bottom: 0.25rem;
  }
  
  .progress-bar {
    height: 0.5rem;
    background: rgba(255, 255, 255, 0.1);
    border-radius: 0.25rem;
    overflow: hidden;
    
    .progress-fill {
      height: 100%;
      background: rgba(245, 73, 0, 1);
      transition: width 0.3s;
    }
  }
  
  .progress-goal {
    display: block;
    font-size: 0.75rem;
    color: rgba(255, 255, 255, 0.5);
    margin-top: 0.25rem;
  }
}

.job-actions {
  display: flex;
  gap: 0.5rem;
  margin-top: auto;
  flex-shrink: 0;
  position: relative;
}

.btn {
  flex: 1;
  padding: 0.5rem 1rem;
  border-radius: 0.375rem;
  font-size: 0.875rem;
  font-weight: 500;
  cursor: pointer;
  transition: all 0.2s;
  border: none;
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 0.5rem;
  
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
</style>

