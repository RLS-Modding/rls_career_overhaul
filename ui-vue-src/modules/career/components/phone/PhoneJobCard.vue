<template>
  <div class="phone-job-card" :class="{ active: isActive, 'damage-locked': damageLockApplies }">
    <div class="card-content">
      <div class="image-container">
        <img :src="job.vehicleImage" :alt="job.vehicleName" />
        <div class="status-overlay" :class="statusClass">
          {{ statusText }}
        </div>
      </div>
      
      <div class="info-container">
        <div class="header">
          <h4 class="vehicle-name" :title="`${job.vehicleYear} ${job.vehicleName}`">
            {{ job.vehicleYear }} {{ job.vehicleName }}
          </h4>
          <span v-if="job.vehicleType" class="vehicle-type">{{ job.vehicleType }}</span>
        </div>
        
        <div class="goal-section">
          <div class="goal-row">
            <span class="label">Goal:</span>
            <span class="value truncate">{{ job.goal }}</span>
          </div>
          
          <div v-if="isActive" class="progress-row">
            <div class="progress-text">
              <span class="label">Current:</span>
              <span class="value" :class="{ 'good': isGoodProgress }">
                {{ formatTimeWithUnit(job.currentTime ?? job.baselineTime, job.timeUnit, job.decimalPlaces) }}
              </span>
            </div>
            <div class="progress-bar-bg">
              <div class="progress-bar-fill" :style="{ width: `${progressPercent}%` }"></div>
            </div>
          </div>
          
          <div v-else-if="expirationText" class="expiry-row" :class="{ expired: isExpired }">
             {{ expirationText }}
          </div>
        </div>
        
        <div class="footer">
          <div class="reward">
            <span class="currency">$</span>{{ job.reward.toLocaleString() }}
          </div>
          
          <div class="actions">
            <template v-if="isActive">
              <template v-if="damageLockApplies">
                 <button class="btn-icon danger" @click.stop="$emit('abandon', job)">
                    <svg viewBox="0 0 24 24" width="18" height="18" stroke="currentColor" stroke-width="2" fill="none"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
                 </button>
              </template>
              <template v-else>
                <button 
                  v-if="canComplete || canCompleteLocal" 
                  class="btn-text success" 
                  @click.stop="$emit('complete', job)"
                >
                  Complete
                </button>
                <template v-else>
                  <button class="btn-icon danger" @click.stop="$emit('abandon', job)" title="Abandon">
                    <svg viewBox="0 0 24 24" width="18" height="18" stroke="currentColor" stroke-width="2" fill="none"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
                  </button>
                </template>
              </template>
            </template>
            <template v-else>
              <button class="btn-text success" @click.stop="$emit('accept', job)">Accept</button>
              <button class="btn-icon danger" @click.stop="$emit('decline', job)" title="Decline">
                 <svg viewBox="0 0 24 24" width="18" height="18" stroke="currentColor" stroke-width="2" fill="none"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
              </button>
            </template>
          </div>
        </div>
      </div>
    </div>
    
    <div v-if="damageLockApplies" class="damage-warning">
      Vehicle Damaged
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
  businessId: String
})

const emit = defineEmits(['pull-out', 'put-away', 'abandon', 'accept', 'decline', 'complete'])

const store = useBusinessComputerStore()

const normalizeJobId = (value) => {
  if (value === undefined || value === null) return null
  return String(value)
}

const jobIdentifier = computed(() => normalizeJobId(props.job?.jobId ?? props.job?.id))
const pulledOutJobIdentifier = computed(() => normalizeJobId(store.pulledOutVehicle?.jobId))
const damageLockApplies = computed(() => {
  if (!store.isDamageLocked || !jobIdentifier.value || !pulledOutJobIdentifier.value) return false
  return jobIdentifier.value === pulledOutJobIdentifier.value
})

const canComplete = ref(false)
const remainingSeconds = ref(null)
const countdownTimer = ref(null)

const canCompleteLocal = computed(() => {
  if (!props.isActive || props.job.currentTime === undefined || props.job.currentTime === null || props.job.goalTime === undefined || props.job.goalTime === null) {
    return false
  }
  if (props.job.raceType === "track" || props.job.raceType === "trackAlt" || props.job.raceType === "drag") {
    const currentTime = Number(props.job.currentTime)
    const goalTime = Number(props.job.goalTime)
    if (isNaN(currentTime) || isNaN(goalTime) || goalTime <= 0) return false
    return currentTime <= goalTime
  }
  return false
})

const isGoodProgress = computed(() => {
  if (!props.isActive) return false
  // If current time is better (lower) than baseline, it's good progress visually
  return props.job.currentTime < props.job.baselineTime
})

const statusText = computed(() => props.isActive ? "In Progress" : "New")
const statusClass = computed(() => props.isActive ? "status-active" : "status-new")

const progressPercent = computed(() => {
  if (!props.isActive || !props.job.baselineTime || !props.job.goalTime) return 0
  const progress = ((props.job.baselineTime - props.job.currentTime) / 
                    (props.job.baselineTime - props.job.goalTime)) * 100
  return Math.max(0, Math.min(100, progress))
})

const formatTime = (time, decimalPlaces) => {
  if (typeof time !== 'number' || isNaN(time)) return time || '0'
  if (time >= 60) {
    const minutes = Math.floor(time / 60)
    const seconds = Math.round(time % 60)
    return seconds >= 1 ? `${minutes}m ${seconds}s` : `${minutes}m`
  }
  const decimals = decimalPlaces || 0
  return decimals > 0 ? time.toFixed(decimals) + 's' : Math.round(time) + 's'
}

const formatTimeWithUnit = (time, timeUnit, decimalPlaces) => {
  return formatTime(time, decimalPlaces)
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

// Expiry logic
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

const startCountdown = () => {
  if (countdownTimer.value) clearInterval(countdownTimer.value)
  syncRemainingSeconds()
  if (remainingSeconds.value === null) return

  countdownTimer.value = setInterval(() => {
    if (remainingSeconds.value === null) {
      clearInterval(countdownTimer.value)
      return
    }
    if (remainingSeconds.value <= 0) {
      remainingSeconds.value = 0
      clearInterval(countdownTimer.value)
      return
    }
    remainingSeconds.value = remainingSeconds.value - 1
  }, 1000)
}

const isExpired = computed(() => !props.isActive && remainingSeconds.value !== null && remainingSeconds.value <= 0)
const expirationText = computed(() => {
  if (props.isActive || remainingSeconds.value === null) return null
  if (remainingSeconds.value <= 0) return "Expired"
  return formatTime(remainingSeconds.value, 0)
})

onMounted(() => {
  checkCanComplete()
  startCountdown()
})

onUnmounted(() => {
  if (countdownTimer.value) clearInterval(countdownTimer.value)
})

watch(() => [props.isActive, props.job.currentTime, props.job.goalTime, props.job.jobId], checkCanComplete)
watch(() => [props.job?.jobId, props.job?.expiresInSeconds, props.isActive], startCountdown)
</script>

<style scoped lang="scss">
.phone-job-card {
  background: rgba(20, 20, 20, 0.95);
  border-radius: 12px;
  overflow: hidden;
  position: relative;
  border: 1px solid rgba(255, 255, 255, 0.08);
  box-shadow: 0 2px 8px rgba(0, 0, 0, 0.4), 0 0 0 1px rgba(255, 255, 255, 0.02) inset;
  transition: transform 0.2s, box-shadow 0.2s, border-color 0.2s;
  width: 100%;
  max-width: 100%;
  box-sizing: border-box;
  
  &:active {
    transform: scale(0.98);
  }
  
  &:hover {
    border-color: rgba(245, 73, 0, 0.2);
    box-shadow: 0 4px 12px rgba(0, 0, 0, 0.5), 0 0 0 1px rgba(245, 73, 0, 0.1) inset;
  }
  
  &.damage-locked {
    border-color: rgba(239, 68, 68, 0.5);
    background: rgba(239, 68, 68, 0.05);
  }
}

.card-content {
  display: flex;
  min-height: 98px;
  max-width: 100%;
  box-sizing: border-box;
}

.image-container {
  width: 110px;
  min-width: 110px;
  position: relative;
  flex-shrink: 0;
  box-sizing: border-box;
  align-self: stretch;
  
  img {
    width: 100%;
    height: 100%;
    object-fit: cover;
    display: block;
  }
  
  .status-overlay {
    position: absolute;
    top: 0;
    left: 0;
    padding: 3px 7px;
    font-size: 0.6rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.5px;
    border-bottom-right-radius: 6px;
    z-index: 2;
    
    &.status-active {
      background: #eab308;
      color: #000;
      box-shadow: 0 1px 3px rgba(0, 0, 0, 0.3);
    }
    
    &.status-new {
      background: #3b82f6;
      color: #fff;
      box-shadow: 0 1px 3px rgba(0, 0, 0, 0.3);
    }
  }
  
  &::after {
    content: '';
    position: absolute;
    top: 0;
    bottom: 0;
    right: 0;
    width: 20px;
    background: linear-gradient(to right, transparent, rgba(20, 20, 20, 0.95));
    z-index: 1;
    pointer-events: none;
  }
}

.info-container {
  flex: 1;
  padding: 10px 12px 12px 8px;
  display: flex;
  flex-direction: column;
  justify-content: space-between;
  min-width: 0;
  max-width: 100%;
  box-sizing: border-box;
}

.header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 6px;
  width: 100%;
  max-width: 100%;
  box-sizing: border-box;
  overflow: hidden;
}

.vehicle-name {
  margin: 0;
  font-size: 0.85rem;
  font-weight: 600;
  color: #fff;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  flex: 1;
  min-width: 0;
  max-width: 100%;
  box-sizing: border-box;
}

.vehicle-type {
  font-size: 0.6rem;
  color: rgba(255, 255, 255, 0.5);
  background: rgba(255, 255, 255, 0.1);
  padding: 1px 5px;
  border-radius: 3px;
  flex-shrink: 0;
  white-space: nowrap;
}

.goal-section {
  font-size: 0.75rem;
  display: flex;
  flex-direction: column;
  gap: 5px;
  width: 100%;
  max-width: 100%;
  box-sizing: border-box;
  overflow: hidden;
}

.goal-row, .progress-row {
  display: flex;
  justify-content: space-between;
  align-items: center;
  width: 100%;
  max-width: 100%;
  box-sizing: border-box;
  overflow: hidden;
  gap: 6px;
}

.progress-text {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 6px;
  flex: 1;
  min-width: 0;
  overflow: hidden;
}

.label {
  color: rgba(255, 255, 255, 0.5);
  font-size: 0.7rem;
  flex-shrink: 0;
  white-space: nowrap;
}

.value {
  color: #fff;
  font-weight: 500;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  text-align: right;
  flex-shrink: 1;
  min-width: 0;
  max-width: 100%;
  
  &.truncate {
    max-width: 100%;
  }
  
  &.good {
    color: #4ade80;
  }
}

.progress-bar-bg {
  height: 3px;
  background: rgba(255, 255, 255, 0.1);
  border-radius: 2px;
  width: 100%;
  margin-top: 2px;
  overflow: hidden;
}

.progress-bar-fill {
  height: 100%;
  background: #f54900;
  border-radius: 2px;
  transition: width 0.3s ease;
}

.expiry-row {
  font-size: 0.7rem;
  color: rgba(255, 255, 255, 0.5);
  &.expired { color: #ef4444; }
}

.footer {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-top: 4px;
  width: 100%;
  max-width: 100%;
  box-sizing: border-box;
  gap: 8px;
}

.reward {
  font-size: 0.95rem;
  font-weight: 700;
  color: #22c55e;
  flex-shrink: 0;
  white-space: nowrap;
  
  .currency {
    font-size: 0.75rem;
    margin-right: 1px;
  }
}

.actions {
  display: flex;
  gap: 6px;
  flex-shrink: 0;
  align-items: center;
}

.btn-icon {
  background: rgba(255, 255, 255, 0.1);
  border: none;
  border-radius: 6px;
  width: 28px;
  height: 28px;
  min-width: 28px;
  min-height: 28px;
  display: flex;
  align-items: center;
  justify-content: center;
  color: rgba(255, 255, 255, 0.8);
  cursor: pointer;
  transition: all 0.2s;
  flex-shrink: 0;
  box-sizing: border-box;
  
  svg {
    width: 18px;
    height: 18px;
  }
  
  &:hover {
    background: rgba(255, 255, 255, 0.2);
    color: #fff;
  }
  
  &.danger {
    background: rgba(239, 68, 68, 0.15);
    color: #ef4444;
    &:hover { background: rgba(239, 68, 68, 0.25); }
  }
}

.btn-text {
  border: none;
  border-radius: 6px;
  padding: 5px 12px;
  font-size: 0.75rem;
  font-weight: 600;
  cursor: pointer;
  transition: all 0.2s;
  flex-shrink: 0;
  box-sizing: border-box;
  height: 28px;
  display: flex;
  align-items: center;
  justify-content: center;
  
  &.success {
    background: #22c55e;
    color: #fff;
    &:hover { background: #16a34a; }
  }
}

.damage-warning {
  background: rgba(239, 68, 68, 0.9);
  color: white;
  text-align: center;
  font-size: 0.7rem;
  font-weight: 600;
  padding: 2px 0;
}
</style>
