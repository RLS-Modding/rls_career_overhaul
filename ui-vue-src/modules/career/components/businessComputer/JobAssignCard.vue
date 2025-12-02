<template>
  <div class="job-assign-card">
    <div class="job-assign-card__image">
      <img :src="job.vehicleImage" :alt="job.vehicleName" />
      <span class="status-badge">Available</span>
    </div>
    <div class="job-assign-card__body">
      <div class="job-assign-card__title-row">
        <div class="job-assign-card__title-block">
          <h3>{{ job.vehicleYear }} {{ job.vehicleName }}</h3>
          <span v-if="job.vehicleType" class="vehicle-type">{{ job.vehicleType }}</span>
        </div>
      </div>
      <div class="job-assign-card__summary">
        <span class="summary-item price">${{ formatPayment(job.reward) }}</span>
        <span class="summary-separator">•</span>
        <span class="summary-item tier">{{ jobTierLabel }}</span>
      </div>
      <div class="job-assign-card__goal-line" v-if="goalSummary">
        {{ goalSummary }}
      </div>
      <button 
        class="job-assign-card__button"
        @click.stop="$emit('assign', job)"
        @mousedown.stop
        data-focusable
      >
        Assign
      </button>
    </div>
  </div>
</template>

<script setup>
import { computed } from "vue"

const props = defineProps({
  job: Object
})

const emit = defineEmits(['assign'])

const jobTier = computed(() => {
  const tier = props.job?.tier
  return typeof tier === "number" ? tier : 1
})

const jobTierLabel = computed(() => `Tier ${jobTier.value}`)

const goalTimeText = computed(() => {
  const goal = props.job?.goal
  if (!goal) {
    return ""
  }
  const raceLabel = props.job?.raceLabel
  if (raceLabel) {
    const suffix = ` ${raceLabel}`
    if (goal.endsWith(suffix)) {
      return goal.slice(0, goal.length - suffix.length).trim()
    }
  }
  return goal
})

const goalSummary = computed(() => {
  const raceLabel = props.job?.raceLabel
  const timeText = goalTimeText.value
  if (raceLabel && timeText) {
    return `${raceLabel} · ${timeText}`
  }
  return timeText || raceLabel || ""
})

const formatPayment = (amount) => {
  if (typeof amount !== 'number') return '0'
  return amount.toLocaleString()
}
</script>

<style scoped lang="scss">
.job-assign-card {
  background: rgba(23, 23, 23, 0.55);
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: 0.75em;
  padding: 1em;
  display: flex;
  flex-direction: column;
  gap: 0.75em;
  transition: border-color 0.2s, transform 0.2s;
  
  &:hover {
    border-color: rgba(245, 73, 0, 0.5);
    transform: translateY(-2px);
  }
}

.job-assign-card__image {
  position: relative;
  width: 100%;
  border-radius: 0.5em;
  overflow: hidden;
  background: rgba(0, 0, 0, 0.35);
  
  img {
    width: 100%;
    height: auto;
    display: block;
  }
  
  .status-badge {
    position: absolute;
    top: 0.5em;
    right: 0.5em;
    padding: 0.25em 0.65em;
    border-radius: 999px;
    font-size: 0.75em;
    font-weight: 500;
    background: rgba(59, 130, 246, 0.75);
    color: white;
    border: none;
  }
}

.job-assign-card__body {
  display: flex;
  flex-direction: column;
  gap: 0.5em;
}

.job-assign-card__title-row {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
}

.job-assign-card__title-block {
  h3 {
    margin: 0;
    color: #fff;
    font-size: 1em;
    font-weight: 600;
  }

  .vehicle-type {
    margin-top: 0.15em;
    display: inline-block;
    font-size: 0.75em;
    color: rgba(255, 255, 255, 0.6);
  }
}

.job-assign-card__summary {
  display: flex;
  align-items: center;
  gap: 0.35em;
  font-weight: 600;
  color: rgba(255, 255, 255, 0.9);

  .summary-item.price {
    color: #22c55e;
  }

  .summary-item.tier {
    color: rgba(255, 255, 255, 0.75);
  }

  .summary-separator {
    color: rgba(255, 255, 255, 0.35);
  }
}

.job-assign-card__goal-line {
  font-size: 0.9em;
  color: rgba(255, 255, 255, 0.75);
}

.job-assign-card__button {
  width: 100%;
  padding: 0.65em 1em;
  background: rgba(245, 73, 0, 1);
  color: white;
  border: none;
  border-radius: 0.4em;
  font-size: 0.9em;
  font-weight: 600;
  cursor: pointer;
  transition: background-color 0.2s, transform 0.2s;
  margin-top: 0.25em;
  
  &:hover {
    background: rgba(245, 73, 0, 0.9);
    transform: translateY(-1px);
  }
  
  &:active {
    background: rgba(245, 73, 0, 0.8);
    transform: none;
  }
}
</style>
