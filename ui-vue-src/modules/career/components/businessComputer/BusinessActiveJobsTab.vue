<template>
  <div class="active-jobs-tab">
    <div class="tab-header">
      <h2>Active Jobs</h2>
      <p>Jobs you're currently working on</p>
    </div>
    
    <div class="jobs-grid">
      <BusinessJobCard
        v-for="job in store.activeJobs"
        :key="job.id"
        :job="job"
        :is-active="true"
        :is-vertical="true"
        :business-id="store.businessId"
        @pull-out="handlePullOut"
        @put-away="handlePutAway"
        @abandon="handleAbandon"
        @complete="handleComplete"
      />
    </div>
    
    <div v-if="store.activeJobs.length === 0" class="empty-state">
      No active jobs
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
import { ref, computed, Teleport } from "vue"
import { useBusinessComputerStore } from "../../stores/businessComputerStore"
import BusinessJobCard from "./BusinessJobCard.vue"

const store = useBusinessComputerStore()

const showAbandonModal = ref(false)
const jobToAbandon = ref(null)

const penaltyCost = computed(() => {
  if (!jobToAbandon.value) return 0
  return jobToAbandon.value.penalty || 0
})

const handlePullOut = async (job) => {
  if (!Array.isArray(store.vehicles)) {
    return
  }
  
  const vehicle = store.vehicles.find(v => {
    return v.jobId == job.id || v.jobId === job.id || String(v.jobId) === String(job.id)
  })
  if (vehicle) {
    await store.pullOutVehicle(vehicle.vehicleId)
  }
}

const handlePutAway = async () => {
  await store.putAwayVehicle()
}

const handleAbandon = (job) => {
  if (!job) return
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

const handleComplete = async (job) => {
  const jobId = job.jobId ?? parseInt(job.id)
  await store.completeJob(jobId)
}
</script>

<style scoped lang="scss">
.active-jobs-tab {
  display: flex;
  flex-direction: column;
  gap: 1.5rem;
}

.tab-header {
  h2 {
    margin: 0 0 0.5rem 0;
    color: rgba(245, 73, 0, 1);
    font-size: 1.5rem;
  }
  
  p {
    margin: 0;
    color: rgba(255, 255, 255, 0.6);
  }
}

.jobs-grid {
  display: grid;
  grid-template-columns: 1fr;
  gap: 1em;
  
  @media (min-width: 1024px) {
    grid-template-columns: repeat(2, 1fr);
  }
}

.empty-state {
  padding: 3rem;
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
