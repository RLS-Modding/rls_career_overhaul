<template>
  <div class="home-dashboard">
    <!-- Top Row: Garage Widget (Full Width) -->
    <div class="top-row">
      <HomeGarageWidget 
        @put-away="handlePutAway"
        @abandon="handleAbandon"
        @go-to-jobs="store.switchView('jobs')"
      />
    </div>

    <!-- Bottom Grid: Jobs (Left) and Side Stack (Right) -->
    <div class="dashboard-grid">
      <div class="dashboard-column main-column">
        <HomeJobsWidget 
          @pull-out="handlePullOut"
          @put-away="handlePutAway"
          @abandon="handleAbandon"
          @complete="handleComplete"
          @accept="handleAccept"
          @decline="handleDecline"
        />
      </div>
      
      <div class="dashboard-column side-column">
        <div class="side-stack">
          <HomeTechsWidget 
            @go-to-techs="store.switchView('techs')"
          />
          
          <HomeFinancesWidget />
        </div>
      </div>
    </div>

    <!-- Confirmation Modal -->
    <Teleport to="body">
      <transition name="modal-fade">
        <div v-if="showAbandonModal" class="modal-overlay" @click.self="cancelAbandon">
          <div class="modal-content" ref="abandonModalRef">
            <h2>Abandon Job</h2>
            <p>Are you sure you want to abandon this job? You will be charged a penalty of <span class="penalty-text">${{ penaltyCost.toLocaleString() }}</span>.</p>
            <div class="modal-buttons">
              <button class="btn btn-secondary" @click="cancelAbandon" data-focusable>Cancel</button>
              <button class="btn btn-danger" @click="confirmAbandon" data-focusable>Yes, Abandon</button>
            </div>
          </div>
        </div>
      </transition>
    </Teleport>
  </div>
</template>

<script setup>
import { computed, ref, Teleport, inject, watch, nextTick } from "vue"
import { useBusinessComputerStore } from "../../stores/businessComputerStore"
import HomeJobsWidget from "./widgets/HomeJobsWidget.vue"
import HomeGarageWidget from "./widgets/HomeGarageWidget.vue"
import HomeTechsWidget from "./widgets/HomeTechsWidget.vue"
import HomeFinancesWidget from "./widgets/HomeFinancesWidget.vue"

const store = useBusinessComputerStore()
const controllerNav = inject('controllerNav', null)
const abandonModalRef = ref(null)
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

watch(showAbandonModal, (isOpen) => {
  if (!controllerNav) return
  if (isOpen) {
    nextTick(() => {
      if (abandonModalRef.value) {
        controllerNav.pushModal(abandonModalRef.value, cancelAbandon)
      }
    })
  } else if (abandonModalRef.value) {
    controllerNav.removeModal(abandonModalRef.value)
  }
})

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
.home-dashboard {
  height: 100%;
  display: flex;
  flex-direction: column;
  overflow: hidden;
  padding-bottom: 1em; 
  gap: 1.5em;
}

.top-row {
  flex-shrink: 0;
}

.dashboard-grid {
  display: grid;
  grid-template-columns: 1fr;
  gap: 1.5em;
  min-height: 0; /* Allow children to scroll */
  flex: 1;
  overflow-y: auto; /* Allow grid to scroll if needed on small screens */
  
  @media (min-width: 1280px) {
    grid-template-columns: 1fr 1fr; /* 50% - 50% split as requested */
    overflow-y: hidden; /* Lock scroll on large screens */
  }
}

.dashboard-column {
  display: flex;
  flex-direction: column;
  gap: 1.5em;
  min-height: 0;
  
  &.main-column {
    height: 100%;
    overflow: hidden; /* Jobs widget handles its own scroll */
  }
  
  &.side-column {
    height: 100%;
    overflow: hidden; /* Match main column - widgets handle their own scroll */
    min-height: 0;
  }
}

.side-stack {
  display: flex;
  flex-direction: column;
  gap: 1.5em;
  height: 100%; /* Fill full height of side column */
  min-height: 0;
  
  :deep(.finances-widget) {
    flex: 1; /* Equal height with techs */
    min-height: 0;
  }
  
  :deep(.techs-widget) {
    flex: 1; /* Equal height with finances */
    min-height: 0;
  }
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
