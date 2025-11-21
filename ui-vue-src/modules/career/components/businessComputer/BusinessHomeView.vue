<template>
  <div class="home-view">
    <BusinessVehicleCard 
      v-if="store.pulledOutVehicle" 
      :vehicle="store.pulledOutVehicle" 
      :job="currentVehicleJob"
      @put-away="handlePutAway" 
      @abandon="handleAbandon(currentVehicleJob)"
    />

    <div class="section-card">
      <div class="card-header">
        <div class="card-header-content">
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <rect x="2" y="7" width="20" height="14" rx="2" ry="2"/>
            <path d="M16 21V5a2 2 0 0 0-2-2h-4a2 2 0 0 0-2 2v16"/>
          </svg>
          <h3>Active Jobs</h3>
        </div>
        <p class="card-description">Jobs currently in progress</p>
      </div>
      <div class="card-content">
        <div v-if="store.activeJobs.length === 0" class="empty-state">
          No active jobs
        </div>
        <div v-else class="jobs-list">
          <BusinessJobCard
            v-for="job in store.activeJobs"
            :key="job.id"
            :job="job"
            :is-active="true"
            :business-id="store.businessId"
            @pull-out="handlePullOut"
            @put-away="handlePutAway"
            @abandon="handleAbandon"
            @complete="handleComplete"
          />
        </div>
      </div>
    </div>

    <div class="section-card">
      <div class="card-header">
        <div class="card-header-content">
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <rect x="2" y="7" width="20" height="14" rx="2" ry="2"/>
            <path d="M16 21V5a2 2 0 0 0-2-2h-4a2 2 0 0 0-2 2v16"/>
          </svg>
          <h3>New Jobs</h3>
        </div>
        <p class="card-description">Available jobs ready to start</p>
      </div>
      <div class="card-content">
        <div v-if="store.newJobs.length === 0" class="empty-state">
          No new jobs available
        </div>
        <div v-else class="jobs-list">
          <BusinessJobCard
            v-for="job in store.newJobs.slice(0, 3)"
            :key="job.id"
            :job="job"
            :is-active="false"
            @accept="handleAccept"
            @decline="handleDecline"
          />
        </div>
      </div>
    </div>

    <!-- Confirmation Modal -->
    <Teleport to="body">
      <transition name="modal-fade">
        <div v-if="showAbandonModal" class="modal-overlay" @click.self="cancelAbandon">
          <div class="modal-content">
            <h2>Abandon Job</h2>
            <p>Are you sure you want to abandon this job? You will be charged a penalty of <span class="penalty-text">${{ penaltyCost.toLocaleString() }}</span>.</p>
            <div class="modal-buttons">
              <button class="btn btn-secondary" @click="cancelAbandon">Cancel</button>
              <button class="btn btn-danger" @click="confirmAbandon">Yes, Abandon</button>
            </div>
          </div>
        </div>
      </transition>
    </Teleport>
  </div>
</template>

<script setup>
import { computed, ref, Teleport } from "vue"
import { useBusinessComputerStore } from "../../stores/businessComputerStore"
import BusinessVehicleCard from "./BusinessVehicleCard.vue"
import BusinessJobCard from "./BusinessJobCard.vue"

const store = useBusinessComputerStore()
const normalizeId = (id) => {
  if (id === undefined || id === null) return null
  const num = Number(id)
  return isNaN(num) ? String(id) : num
}

const showAbandonModal = ref(false)
const jobToAbandon = ref(null)

const penaltyCost = computed(() => {
  if (!jobToAbandon.value) return 0
  return jobToAbandon.value.penalty || 0
})

const currentVehicleJob = computed(() => {
  const vehicle = store.pulledOutVehicle
  const jobsSource = store.activeJobs
  const jobs = Array.isArray(jobsSource)
    ? jobsSource
    : (Array.isArray(jobsSource?.value) ? jobsSource.value : [])
  if (!vehicle || !vehicle.jobId) {
    return null
  }
  const vehicleJobId = String(vehicle.jobId)
  return jobs.find(job => {
    const jobId = job?.jobId ?? job?.id
    return jobId !== undefined && jobId !== null && String(jobId) === vehicleJobId
  }) || null
})

const handlePullOut = async (job) => {
  if (!Array.isArray(store.vehicles)) {
    return
  }
  
  const jobId = job.jobId ?? job.id
  if (jobId === undefined || jobId === null) {
    return
  }

  const normalizedJobId = normalizeId(jobId)
  const vehicle = store.vehicles.find(v => {
    if (!v.jobId) return false
    const normalizedVehicleJobId = normalizeId(v.jobId)
    return normalizedVehicleJobId === normalizedJobId
  })
  
  if (vehicle) {
    await store.pullOutVehicle(vehicle.vehicleId)
  }
}

const handlePutAway = async () => {
  await store.putAwayVehicle()
}

const handleAbandon = (job) => {
  if (!job) {
    return
  }
  jobToAbandon.value = job
  showAbandonModal.value = true
}

const confirmAbandon = async () => {
  if (jobToAbandon.value) {
    await store.abandonJob(parseInt(jobToAbandon.value.id))
    showAbandonModal.value = false
    jobToAbandon.value = null
  }
}

const cancelAbandon = () => {
  showAbandonModal.value = false
  jobToAbandon.value = null
}

const handleAccept = async (job) => {
  await store.acceptJob(parseInt(job.id))
}

const handleDecline = async (job) => {
  await store.declineJob(parseInt(job.id))
}

const handleComplete = async (job) => {
  const jobId = job.jobId ?? parseInt(job.id)
  await store.completeJob(jobId)
}
</script>

<style scoped lang="scss">
.home-view {
  display: flex;
  flex-direction: column;
  gap: 1.5rem;
}

.section-card {
  background: rgba(26, 26, 26, 0.5);
  border: 1px solid rgba(245, 73, 0, 0.3);
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

.jobs-list {
  display: flex;
  flex-direction: column;
  gap: 1rem;
}

.empty-state {
  padding: 2rem;
  text-align: center;
  color: rgba(255, 255, 255, 0.5);
}

/* Modal Styles */
.modal-overlay {
  position: fixed;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  background: rgba(0, 0, 0, 0.7);
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 10000;
  backdrop-filter: blur(4px);
}

.modal-content {
  background: rgba(15, 15, 15, 0.95);
  border: 2px solid rgba(245, 73, 0, 0.6);
  border-radius: 0.5em;
  padding: 2em;
  max-width: 30em;
  width: 90%;
  box-shadow: 0 8px 32px rgba(0, 0, 0, 0.5);
  
  h2 {
    margin: 0 0 1em 0;
    color: white;
    font-size: 1.5em;
    font-weight: 600;
  }
  
  p {
    margin: 0 0 2em 0;
    color: rgba(255, 255, 255, 0.8);
    font-size: 1em;
    line-height: 1.5;
  }

  .penalty-text {
    color: #F54900;
    font-weight: 600;
  }
  
  .modal-buttons {
    display: flex;
    gap: 1em;
    justify-content: flex-end;
  }
  
  .btn {
    padding: 0.75em 1.5em;
    border: none;
    border-radius: 0.25em;
    font-size: 0.875em;
    font-weight: 600;
    cursor: pointer;
    transition: all 0.2s;
    
    &.btn-secondary {
      background: rgba(255, 255, 255, 0.1);
      color: rgba(255, 255, 255, 0.9);
      
      &:hover {
        background: rgba(255, 255, 255, 0.15);
      }
    }
    
    &.btn-danger {
      background: rgba(239, 68, 68, 1);
      color: white;
      
      &:hover {
        background: rgba(239, 68, 68, 0.9);
        box-shadow: 0 0 10px rgba(239, 68, 68, 0.4);
      }
    }
  }
}

.modal-fade-enter-active,
.modal-fade-leave-active {
  transition: opacity 0.2s ease;
  
  .modal-content {
    transition: transform 0.2s ease, opacity 0.2s ease;
  }
}

.modal-fade-enter-from,
.modal-fade-leave-to {
  opacity: 0;
  
  .modal-content {
    transform: scale(0.95);
    opacity: 0;
  }
}
</style>
