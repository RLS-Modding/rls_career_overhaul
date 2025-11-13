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
        <div class="vehicle-image">
          <img :src="vehicle.vehicleImage" :alt="vehicle.vehicleName" />
          <span class="badge badge-green">In Garage</span>
        </div>
        <div class="vehicle-info">
          <h3 class="vehicle-name">{{ vehicle.vehicleYear }} {{ vehicle.vehicleName }}</h3>
          <div class="vehicle-meta">
            <span class="badge badge-orange">{{ vehicle.vehicleType }}</span>
            <span class="job-id">Job ID: {{ vehicle.jobId }}</span>
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
import { useBusinessComputerStore } from "../../stores/businessComputerStore"

const props = defineProps({
  vehicle: Object
})

const store = useBusinessComputerStore()

const goToTuning = () => {
  store.switchVehicleView('tuning')
}
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
  display: flex;
  gap: 1rem;
}

.vehicle-image {
  position: relative;
  width: 16rem;
  aspect-ratio: 16/9;
  border-radius: 0.5rem;
  overflow: hidden;
  background: rgba(0, 0, 0, 0.5);
  flex-shrink: 0;
  
  img {
    width: 100%;
    height: 100%;
    object-fit: cover;
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
      background: rgba(34, 197, 94, 0.2);
      color: rgba(34, 197, 94, 1);
      border: 1px solid rgba(34, 197, 94, 0.5);
    }
  }
}

.vehicle-info {
  flex: 1;
  display: flex;
  flex-direction: column;
  gap: 1rem;
}

.vehicle-name {
  margin: 0;
  color: white;
  font-size: 1.25rem;
  font-weight: 600;
}

.vehicle-meta {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  
  .badge {
    padding: 0.25rem 0.5rem;
    border-radius: 0.25rem;
    font-size: 0.75rem;
    font-weight: 500;
    
    &.badge-orange {
      background: rgba(245, 73, 0, 0.2);
      color: rgba(245, 73, 0, 1);
      border: 1px solid rgba(245, 73, 0, 0.5);
    }
  }
  
  .job-id {
    color: rgba(255, 255, 255, 0.5);
    font-size: 0.875rem;
  }
}

.vehicle-actions {
  display: flex;
  gap: 0.5rem;
  margin-top: auto;
}

.btn {
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
</style>

