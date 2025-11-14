<template>
  <div class="vehicle-card">
    <div class="card-header">
      <div class="card-header-content">
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <circle cx="12" cy="12" r="10"/>
          <path d="M12 6v6l4 2"/>
        </svg>
        <h3>Current Vehicle in Garage</h3>
      </div>
      <p class="card-description">This vehicle is currently pulled out and ready for work</p>
    </div>
    <div class="card-content">
      <div class="vehicle-content">
        <div class="vehicle-image-section">
          <div class="vehicle-image">
            <img :src="vehicle.vehicleImage" :alt="vehicle.vehicleName" />
            <span class="badge badge-green">In Garage</span>
          </div>
          <h3 class="vehicle-name">
            {{ vehicle.vehicleYear }} {{ vehicle.vehicleName }}
            <span class="badge badge-orange">{{ vehicle.vehicleType }}</span>
          </h3>
        </div>
        <div class="vehicle-info">
          <div v-if="job" class="reward-container">
            <span class="reward-label">Payment</span>
            <span class="reward-value">${{ job.reward.toLocaleString() }}</span>
          </div>
          <div v-if="job" class="job-metrics">
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
                  <span class="current-time-value">{{ formattedCurrentTime }}</span>
                </div>
              </div>
              <div class="progress-bar">
                <div class="progress-fill" :style="{ width: goalProgress + '%' }"></div>
              </div>
            </div>
          </div>
          <div class="vehicle-actions">
            <button class="btn btn-secondary" @click.stop="$emit('put-away')">Put Away Vehicle</button>
            <button class="btn btn-primary" @click.stop="goToTuning">Go to Tuning</button>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup>
import { computed } from "vue"
import { useBusinessComputerStore } from "../../stores/businessComputerStore"

const props = defineProps({
  vehicle: Object,
  job: {
    type: Object,
    default: null
  }
})

const store = useBusinessComputerStore()

const goToTuning = () => {
  store.switchVehicleView('tuning')
}

const formatTime = (time) => {
  if (typeof time !== "number" || isNaN(time)) {
    return time || "0"
  }
  if (time >= 60) {
    const minutes = Math.floor(time / 60)
    const seconds = Math.round(time % 60)
    if (seconds >= 1) {
      return `${minutes} min ${seconds} s`
    }
    return `${minutes} min`
  }
  return Math.round(time) + " s"
}

const formatTimeWithUnit = (time, timeUnit) => {
  if (typeof time !== "number" || isNaN(time)) {
    return (time || "0") + (timeUnit || "")
  }
  return formatTime(time)
}

const formattedCurrentTime = computed(() => {
  if (!props.job) {
    return "--"
  }
  const time = typeof props.job.currentTime === "number" ? props.job.currentTime : props.job.baselineTime
  return formatTimeWithUnit(time, props.job.timeUnit)
})

const goalProgress = computed(() => {
  if (!props.job || props.job.baselineTime === undefined || props.job.goalTime === undefined) {
    return 0
  }
  const baseline = Number(props.job.baselineTime)
  const goal = Number(props.job.goalTime)
  const current = Number(props.job.currentTime ?? props.job.baselineTime)
  if (!isFinite(baseline) || !isFinite(goal) || baseline === goal) {
    return 0
  }
  const progress = ((baseline - current) / (baseline - goal)) * 100
  return Math.max(0, Math.min(100, progress))
})
</script>

<style scoped lang="scss">
.vehicle-card {
  background: linear-gradient(to bottom right, rgba(245, 73, 0, 0.2), rgba(26, 26, 26, 0.5));
  border: 1px solid rgba(245, 73, 0, 0.5);
  border-radius: 0.5rem;
  overflow: hidden;
}

.card-header {
  padding: 1rem 1.5rem;
  border-bottom: 1px solid rgba(255, 255, 255, 0.1);
  background: rgba(23, 23, 23, 0.3);
}

.card-header-content {
  display: flex;
  align-items: center;
  gap: 0.75rem;
  margin-bottom: 0.5rem;
  
  svg {
    color: rgba(245, 73, 0, 1);
    flex-shrink: 0;
  }
  
  h3 {
    margin: 0;
    color: rgba(245, 73, 0, 1);
    font-size: 1.125rem;
    font-weight: 600;
  }
}

.card-description {
  margin: 0;
  color: rgba(255, 255, 255, 0.6);
  font-size: 0.875rem;
}

.card-content {
  padding: 1.5rem;
}

.vehicle-content {
  display: grid;
  grid-template-columns: auto 1fr;
  gap: 1.5rem;
  align-items: stretch;
}

.vehicle-image-section {
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
  flex-shrink: 0;
  width: 16rem;
  max-width: 16rem;
}

.vehicle-image {
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
  
  .badge {
    position: absolute;
    top: 0.5rem;
    left: 0.5rem;
    padding: 0.25rem 0.5rem;
    border-radius: 0.25rem;
    font-size: 0.75rem;
    font-weight: 500;
    
    &.badge-green {
      background: rgba(34, 197, 94, 0.7);
      color: white;
      border: none;
    }
  }
}

.vehicle-info {
  display: flex;
  flex-direction: column;
  gap: 1rem;
}

.vehicle-name {
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

.vehicle-actions {
  display: flex;
  gap: 0.5rem;
  margin-top: auto;
}

.btn {
  flex: 0 0 calc(50% - 0.25rem);
  padding: 0.5rem 1rem;
  border-radius: 0.375rem;
  font-size: 0.875rem;
  font-weight: 500;
  cursor: pointer;
  transition: all 0.2s;
  border: none;
  
  &.btn-primary {
    background: rgba(245, 73, 0, 1);
    color: white;
    
    &:hover {
      background: rgba(245, 73, 0, 0.9);
    }
  }
  
  &.btn-secondary {
    background: rgba(55, 55, 55, 1);
    color: white;
    
    &:hover {
      background: rgba(75, 75, 75, 1);
    }
  }
}

.job-metrics {
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

.reward-container {
  width: 100%;
  padding: 0.75rem 1rem;
  background: rgba(34, 197, 94, 0.15);
  border-radius: 0.45rem;
  border: 1px solid rgba(34, 197, 94, 0.35);
  display: flex;
  flex-direction: column;
  gap: 0.25rem;
}

.reward-label {
  font-size: 0.75rem;
  color: rgba(255, 255, 255, 0.6);
}

.reward-value {
  font-size: 1.125rem;
  color: rgba(34, 197, 94, 1);
  font-weight: 600;
}
</style>

