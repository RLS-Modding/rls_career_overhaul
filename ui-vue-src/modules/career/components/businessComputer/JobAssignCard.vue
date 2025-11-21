<template>
  <div class="job-assign-card">
    <div class="job-assign-card__image">
      <img :src="job.vehicleImage" :alt="job.vehicleName" />
      <span class="status-badge">Available</span>
    </div>
    <h3 class="job-assign-card__title">
      {{ job.vehicleYear }} {{ job.vehicleName }}
      <span v-if="job.vehicleType" class="badge badge-orange">{{ job.vehicleType }}</span>
    </h3>
    <div class="job-assign-card__payment">
      <span class="payment-label">Payment</span>
      <span class="payment-value">${{ formatPayment(job.reward) }}</span>
    </div>
    <div class="job-assign-card__goal">
      <span class="goal-label">Goal</span>
      <span class="goal-value">{{ job.goal }}</span>
    </div>
    <button 
      class="job-assign-card__button"
      @click.stop="$emit('assign', job)"
      @mousedown.stop
    >
      Assign
    </button>
  </div>
</template>

<script setup>
const props = defineProps({
  job: Object
})

const emit = defineEmits(['assign'])

const formatPayment = (amount) => {
  if (typeof amount !== 'number') return '0'
  return amount.toLocaleString()
}
</script>

<style scoped lang="scss">
.job-assign-card {
  background: rgba(23, 23, 23, 0.5);
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: 0.5rem;
  padding: 1rem;
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
  transition: border-color 0.2s;
  
  &:hover {
    border-color: rgba(245, 73, 0, 0.5);
  }
}

.job-assign-card__image {
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
    background: rgba(59, 130, 246, 0.7);
    color: white;
    border: none;
  }
}

.job-assign-card__title {
  margin: 0;
  color: white;
  font-size: 1rem;
  font-weight: 600;
  word-wrap: break-word;
  overflow-wrap: break-word;
  line-height: 1.4;
  
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

.job-assign-card__payment {
  padding: 0.5rem 0.75rem;
  background: rgba(34, 197, 94, 0.15);
  border-radius: 0.375rem;
  border: 1px solid rgba(34, 197, 94, 0.35);
  display: flex;
  flex-direction: column;
  gap: 0.15rem;
  min-width: 0;
  overflow: hidden;
  
  .payment-label {
    font-size: 0.7rem;
    color: rgba(255, 255, 255, 0.6);
    white-space: nowrap;
  }
  
  .payment-value {
    font-size: 0.875rem;
    color: rgba(34, 197, 94, 1);
    font-weight: 600;
    word-break: break-word;
    overflow-wrap: break-word;
    line-height: 1.2;
    max-width: 100%;
  }
}

.job-assign-card__goal {
  padding: 0.5rem 0.75rem;
  background: rgba(245, 73, 0, 0.15);
  border-radius: 0.375rem;
  border: 1px solid rgba(245, 73, 0, 0.35);
  display: flex;
  flex-direction: column;
  gap: 0.15rem;
  min-width: 0;
  overflow: hidden;
  
  .goal-label {
    font-size: 0.7rem;
    color: rgba(255, 255, 255, 0.6);
    white-space: nowrap;
  }
  
  .goal-value {
    font-size: 0.875rem;
    color: rgba(255, 255, 255, 0.95);
    font-weight: 500;
    word-break: break-word;
    overflow-wrap: break-word;
    line-height: 1.2;
    max-width: 100%;
  }
}

.job-assign-card__button {
  width: 100%;
  padding: 0.625rem 1rem;
  background: rgba(245, 73, 0, 1);
  color: white;
  border: none;
  border-radius: 0.375rem;
  font-size: 0.875rem;
  font-weight: 500;
  cursor: pointer;
  transition: background-color 0.2s;
  margin-top: 0.25rem;
  
  &:hover {
    background: rgba(245, 73, 0, 0.9);
  }
  
  &:active {
    background: rgba(245, 73, 0, 0.8);
  }
}
</style>

