<template>
  <div class="home-widget garage-widget">
    <div class="widget-header">
      <h3>Current Vehicle</h3>
      <div v-if="store.pulledOutVehicle" class="status-indicator active">
        <div class="dot"></div>
        <span>Pulled Out</span>
      </div>
      <div v-else class="status-indicator idle">
        <div class="dot"></div>
        <span>Garage Empty</span>
      </div>
    </div>

    <div class="widget-content" v-if="store.pulledOutVehicle">
      <!-- New Compact Layout -->
      <div class="garage-compact-layout">
        <!-- Left: Vehicle Image (Fills height) -->
        <div class="vehicle-section">
          <div class="vehicle-image-container">
             <img 
               v-if="currentVehicleJob?.vehicleImage" 
               :src="currentVehicleJob.vehicleImage" 
               :alt="currentVehicleJob.vehicleName || 'Vehicle'"
               class="vehicle-image"
             />
             <div v-else class="vehicle-image-placeholder">
                <svg width="64" height="64" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1">
                    <path d="M19 17h2c.6 0 1-.4 1-1v-3c0-.9-.7-1.7-1.5-1.9C18.7 10.6 16 10 16 10s-1.3-1.4-2.2-2.3c-.5-.4-1.1-.7-1.8-.7H5c-.6 0-1.1.4-1.4.9l-1.4 2.9A3.7 3.7 0 0 0 2 12v4c0 .6.4 1 1 1h2"/>
                    <circle cx="7" cy="17" r="2"/>
                    <path d="M9 17h6"/>
                    <circle cx="17" cy="17" r="2"/>
                </svg>
             </div>
          </div>
        </div>

        <!-- Right: Info & Stats -->
        <div class="info-section">
          <div class="vehicle-header">
             <h4 class="vehicle-name" v-if="currentVehicleJob">
               {{ currentVehicleJob.vehicleYear }} {{ currentVehicleJob.vehicleName }}
             </h4>
             <h4 class="vehicle-name" v-else>
               {{ store.pulledOutVehicle?.name || 'Unknown Vehicle' }}
             </h4>
          </div>

          <div class="stats-grid" v-if="currentVehicleJob && !isPersonalVehicle">
             <div class="stat-box">
                <span class="label">Payment</span>
                <span class="value money">${{ currentVehicleJob.reward.toLocaleString() }}</span>
             </div>
             
             <div class="stat-box goal-box">
                <span class="label">Goal</span>
                <span class="value goal-text">{{ currentVehicleJob.goal }}</span>
             </div>
          </div>
          <div class="personal-badge" v-else-if="isPersonalVehicle">
             <span class="personal-label">Personal Vehicle</span>
             <span class="personal-description">Tune your own vehicle</span>
          </div>
        </div>
      </div>

      <!-- Bottom Actions Bar (Full Width) -->
      <div class="actions-row" v-if="!isPersonalVehicle">
        <button class="btn-action" @click="$emit('put-away')" data-focusable>
          Put Away
        </button>
        <button class="btn-icon danger" @click="$emit('abandon', currentVehicleJob)" title="Abandon Job" data-focusable>
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <line x1="18" y1="6" x2="6" y2="18"/>
            <line x1="6" y1="6" x2="18" y2="18"/>
          </svg>
        </button>
      </div>
    </div>

    <div class="widget-content empty" v-else>
      <p>No vehicle is currently being worked on.</p>
      <button class="btn-link" @click="$emit('go-to-jobs')" data-focusable>Select a vehicle from Jobs</button>
    </div>
  </div>
</template>

<script setup>
import { computed } from "vue"
import { useBusinessComputerStore } from "../../../stores/businessComputerStore"

const store = useBusinessComputerStore()

const normalizeJobId = (value) => {
  if (value === undefined || value === null) {
    return null
  }
  return String(value)
}

const isPersonalVehicle = computed(() => {
  return store.pulledOutVehicle?.isPersonal === true
})

const currentVehicleJob = computed(() => {
  const vehicle = store.pulledOutVehicle
  if (!vehicle) {
    return null
  }
  if (vehicle.isPersonal) {
    return {
      vehicleName: vehicle.vehicleName || 'Unknown Vehicle',
      vehicleYear: vehicle.vehicleYear || '',
      vehicleImage: vehicle.vehicleImage,
      vehicleType: vehicle.vehicleType,
      reward: 0,
      goal: null,
      isPersonal: true
    }
  }
  const jobsSource = store.activeJobs
  const jobs = Array.isArray(jobsSource)
    ? jobsSource
    : (Array.isArray(jobsSource?.value) ? jobsSource.value : [])
    
  if (!vehicle.jobId) {
    return null
  }
  const vehicleJobId = String(vehicle.jobId)
  return jobs.find(job => {
    const jobId = job?.jobId ?? job?.id
    return jobId !== undefined && jobId !== null && String(jobId) === vehicleJobId
  }) || null
})

defineEmits(['put-away', 'abandon', 'go-to-jobs'])
</script>

<style scoped lang="scss">
.home-widget {
  background: rgba(30, 30, 30, 0.6);
  border: 1px solid rgba(255, 255, 255, 0.05);
  border-radius: 1rem;
  display: flex;
  flex-direction: column;
  overflow: hidden;
  height: 100%;
}

.widget-header {
  padding: 0.75rem 1rem;
  border-bottom: 1px solid rgba(255, 255, 255, 0.05);
  display: flex;
  justify-content: space-between;
  align-items: center;
  background: rgba(0, 0, 0, 0.2);

  h3 {
    margin: 0;
    font-size: 1rem;
    font-weight: 600;
    color: #fff;
  }
}

.status-indicator {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  font-size: 0.8rem;
  font-weight: 500;
  
  .dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
  }
  
  &.active {
    color: #2ecc71;
    .dot { background: #2ecc71; box-shadow: 0 0 8px rgba(46, 204, 113, 0.4); }
  }
  
  &.idle {
    color: rgba(255, 255, 255, 0.4);
    .dot { background: rgba(255, 255, 255, 0.2); }
  }
}

.widget-content {
  padding: 0.75rem 1rem;
  flex: 1;
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
  
  &.empty {
    align-items: center;
    justify-content: center;
    text-align: center;
    gap: 1rem;
    color: rgba(255, 255, 255, 0.5);
  }
}

.garage-compact-layout {
  display: flex;
  gap: 1rem;
  flex: 1;
}

.vehicle-section {
  width: 40%; /* Adjust width as needed */
  display: flex;
  flex-direction: column;
}

.vehicle-image-container {
  width: 100%;
  height: 100%;
  min-height: 6rem;
  border-radius: 0.375rem;
  background: rgba(255, 255, 255, 0.05);
  display: flex;
  align-items: center;
  justify-content: center;
  overflow: hidden;
  
  .vehicle-image {
    width: 100%;
    height: 100%;
    object-fit: cover;
    display: block;
  }
  
  .vehicle-image-placeholder {
    color: rgba(255, 255, 255, 0.2);
  }
}

.info-section {
  flex: 1;
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
  justify-content: center;
}

.vehicle-header {
  display: flex;
  flex-direction: column;
  gap: 0.25rem;
  
  .vehicle-name {
    margin: 0;
    font-size: 1rem;
    font-weight: 600;
    color: #fff;
    line-height: 1.2;
  }
  
}

.stats-grid {
  display: grid;
  grid-template-columns: 1fr;
  gap: 0.5rem;
}

.stat-box {
  display: flex;
  flex-direction: column;
  gap: 0.25rem;
  
  .label {
    font-size: 0.75rem;
    color: rgba(255, 255, 255, 0.5);
    text-transform: uppercase;
    letter-spacing: 0.05em;
  }
  
  .value {
    font-size: 1rem;
    font-weight: 600;
    color: #fff;
    
    &.money { color: #2ecc71; }
    &.tech { color: #f97316; }
    &.goal { color: rgba(255, 255, 255, 0.9); }
  }
  
  &.goal-box {
    grid-column: 1 / -1; /* Span full width */
    .goal-text { font-size: 0.9rem; }
  }
}

.actions-row {
  display: flex;
  gap: 0.5rem;
  margin-top: auto;
}

.btn-action {
  flex: 1;
  background: rgba(245, 73, 0, 1);
  color: white;
  border: none;
  padding: 0.375rem 0.5rem;
  border-radius: 0.25rem;
  font-weight: 600;
  font-size: 0.85rem;
  cursor: pointer;
  transition: background 0.2s;
  
  &:hover {
    background: rgba(245, 73, 0, 0.9);
  }
}

.btn-icon {
  width: 2rem;
  height: 2rem;
  background: rgba(239, 68, 68, 0.15);
  color: #ef4444;
  border: none;
  border-radius: 0.25rem;
  display: flex;
  align-items: center;
  justify-content: center;
  cursor: pointer;
  transition: background 0.2s;
  flex-shrink: 0;
  
  svg {
    width: 14px;
    height: 14px;
  }
  
  &:hover {
    background: rgba(239, 68, 68, 0.25);
  }
}

.personal-badge {
  display: flex;
  flex-direction: column;
  gap: 0.25rem;
  padding: 0.5rem 0.75rem;
  background: rgba(99, 102, 241, 0.15);
  border-radius: 0.375rem;
  border: 1px solid rgba(99, 102, 241, 0.35);
}

.personal-label {
  font-size: 0.85rem;
  color: rgba(99, 102, 241, 1);
  font-weight: 600;
}

.personal-description {
  font-size: 0.75rem;
  color: rgba(255, 255, 255, 0.6);
}

.btn-link {
  background: none;
  border: none;
  color: #f97316;
  cursor: pointer;
  text-decoration: underline;
  
  &:hover {
    color: #fff;
  }
}
</style>
