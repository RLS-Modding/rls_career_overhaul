<template>
  <div class="jobs-tab">
    <div class="tab-header">
      <h2>Jobs</h2>
      <p>Manage active work and available opportunities in one place</p>
    </div>

    <div v-if="showRecognitionBanner" class="recognition-banner">
      <div 
        v-if="store.brandRecognitionUnlocked" 
        class="recognition-section"
        @click.stop="openBrandModal"
        @mousedown.stop="openBrandModal"
      >
        <span class="banner-label">Brand Recognition</span>
        <span class="banner-value">{{ brandSelectionDisplay }}</span>
      </div>

      <div v-if="store.brandRecognitionUnlocked && store.raceRecognitionUnlocked" class="summary-divider"></div>

      <div 
        v-if="store.raceRecognitionUnlocked" 
        class="recognition-section"
        @click.stop="openRaceModal"
        @mousedown.stop="openRaceModal"
      >
        <span class="banner-label">Race Recognition</span>
        <span class="banner-value">{{ raceSelectionDisplay }}</span>
      </div>
    </div>

    <div v-if="store.activeJobs.length || store.newJobs.length" class="jobs-content">
      <!-- Active Jobs Section -->
      <div v-if="store.activeJobs.length > 0" class="job-section">
        <h3>Active Jobs</h3>
        <div class="jobs-grid">
          <template v-for="job in store.activeJobs" :key="`active-${job.id}`">
            <div class="job-card-wrapper" @click.stop="interceptEvent" @mousedown.stop="interceptEvent">
              <BusinessJobCard
                :job="job"
                :is-active="true"
                :business-id="store.businessId"
                @pull-out="handlePullOut(job)"
                @put-away="handlePutAway(job)"
                @abandon="handleAbandon(job)"
                @complete="handleComplete(job)"
              />
            </div>
          </template>
        </div>
      </div>

      <!-- New Jobs Section -->
      <div v-if="store.newJobs.length > 0" class="job-section">
        <h3>New Jobs</h3>
        <div class="jobs-grid">
          <template v-for="job in store.newJobs" :key="`new-${job.id}`">
            <div class="job-card-wrapper" @click.stop="interceptEvent" @mousedown.stop="interceptEvent">
              <BusinessJobCard
                :job="job"
                :is-active="false"
                @accept="handleAccept(job)"
                @decline="handleDecline(job)"
              />
            </div>
          </template>
        </div>
      </div>
    </div>

    <div v-else class="empty-state">
      No jobs to show right now
    </div>

    <Teleport to="body">
      <transition name="modal-fade">
        <div
          v-if="showAbandonModal"
          class="modal-overlay"
          @click.self.stop="cancelAbandon"
          @mousedown.self.stop="cancelAbandon"
        >
          <div class="modal-content">
            <h2>Abandon Job</h2>
            <p>
              Are you sure you want to abandon this job? You will be charged a penalty of
              <span class="penalty-text">${{ penaltyCost.toLocaleString() }}</span>.
            </p>
            <div class="modal-buttons">
              <button class="btn btn-secondary" @click.stop="cancelAbandon" @mousedown.stop="cancelAbandon">Cancel</button>
              <button class="btn btn-danger" @click.stop="confirmAbandon" @mousedown.stop="confirmAbandon">Yes, Abandon</button>
            </div>
          </div>
        </div>
      </transition>
    </Teleport>

    <Teleport to="body">
      <transition name="modal-fade">
        <div
          v-if="showBrandModal"
          class="modal-overlay"
          @click.self.stop="closeBrandModal"
          @mousedown.self.stop="closeBrandModal"
        >
          <div class="modal-content selection-modal" @click.stop @mousedown.stop>
            <div class="modal-header">
              <h2>Select Brand</h2>
              <button class="modal-close" @click.stop="closeBrandModal" @mousedown.stop="closeBrandModal">×</button>
            </div>
            <div class="modal-body">
              <div v-if="isLoadingBrands" class="modal-empty">
                <p>Loading brands...</p>
              </div>
              <div v-else-if="store.availableBrands.length === 0" class="modal-empty">
                <p>No brands available</p>
                <small>Try refreshing or check if vehicles are loaded</small>
              </div>
              <div v-else class="selection-list">
                <button 
                  class="selection-item"
                  :class="{ 'selected': !store.brandSelection }"
                  @click.stop="selectBrand(null)"
                  @mousedown.stop="selectBrand(null)"
                >
                  <span>Clear Selection</span>
                </button>
                <button 
                  v-for="brand in store.availableBrands"
                  :key="brand"
                  class="selection-item"
                  :class="{ 'selected': store.brandSelection === brand }"
                  @click.stop="selectBrand(brand)"
                  @mousedown.stop="selectBrand(brand)"
                >
                  <span>{{ brand }}</span>
                </button>
              </div>
            </div>
          </div>
        </div>
      </transition>
    </Teleport>

    <Teleport to="body">
      <transition name="modal-fade">
        <div
          v-if="showRaceModal"
          class="modal-overlay"
          @click.self.stop="closeRaceModal"
          @mousedown.self.stop="closeRaceModal"
        >
          <div class="modal-content selection-modal" @click.stop @mousedown.stop>
            <div class="modal-header">
              <h2>Select Race Type</h2>
              <button class="modal-close" @click.stop="closeRaceModal" @mousedown.stop="closeRaceModal">×</button>
            </div>
            <div class="modal-body">
              <div v-if="isLoadingRaceTypes" class="modal-empty">
                <p>Loading race types...</p>
              </div>
              <div v-else-if="store.availableRaceTypes.length === 0" class="modal-empty">
                <p>No race types available</p>
                <small>Check if race data is loaded</small>
              </div>
              <div v-else class="selection-list">
                <button 
                  class="selection-item"
                  :class="{ 'selected': !store.raceSelection }"
                  @click.stop="selectRace(null)"
                  @mousedown.stop="selectRace(null)"
                >
                  <span>Clear Selection</span>
                </button>
                <button 
                  v-for="raceType in store.availableRaceTypes"
                  :key="raceType.id"
                  class="selection-item"
                  :class="{ 'selected': store.raceSelection === raceType.id }"
                  @click.stop="selectRace(raceType.id)"
                  @mousedown.stop="selectRace(raceType.id)"
                >
                  <span>{{ raceType.label }}</span>
                </button>
              </div>
            </div>
          </div>
        </div>
      </transition>
    </Teleport>
  </div>
</template>

<script setup>
import { computed, ref, Teleport, onMounted, onUnmounted, watch } from "vue"
import { useBusinessComputerStore } from "../../stores/businessComputerStore"
import { useBridge } from "@/bridge"
import BusinessJobCard from "./BusinessJobCard.vue"

const store = useBusinessComputerStore()
const { events } = useBridge()

const normalizeId = (id) => {
  if (id === undefined || id === null) return null
  const num = Number(id)
  return isNaN(num) ? String(id) : num
}

const showAbandonModal = ref(false)
const jobToAbandon = ref(null)
const interceptEvent = () => {}

const showBrandModal = ref(false)
const showRaceModal = ref(false)
const isLoadingBrands = ref(false)
const isLoadingRaceTypes = ref(false)

const showRecognitionBanner = computed(() => {
  return store.brandRecognitionUnlocked || store.raceRecognitionUnlocked
})

const brandSelectionDisplay = computed(() => {
  return store.brandSelection || "Not Selected"
})

const raceSelectionDisplay = computed(() => {
  if (!store.raceSelection) return "Not Selected"
  const raceType = store.availableRaceTypes.find(rt => rt.id === store.raceSelection)
  return raceType ? raceType.label : "Not Selected"
})

const handleBrandsReceived = (data) => {
  if (data && Array.isArray(data.brands)) {
    store.availableBrands = data.brands
  } else {
    store.availableBrands = []
  }
  isLoadingBrands.value = false
}

const openBrandModal = async () => {
  showBrandModal.value = true
  if (store.availableBrands.length === 0) {
    isLoadingBrands.value = true
    store.getAvailableBrands()
  }
}

const closeBrandModal = () => {
  showBrandModal.value = false
}

const selectBrand = async (brand) => {
  await store.setBrandSelection(brand)
  closeBrandModal()
}

const handleRaceTypesReceived = (data) => {
  if (data && Array.isArray(data.raceTypes)) {
    store.availableRaceTypes = data.raceTypes
  } else {
    store.availableRaceTypes = []
  }
  isLoadingRaceTypes.value = false
}

const openRaceModal = async () => {
  showRaceModal.value = true
  if (store.availableRaceTypes.length === 0) {
    isLoadingRaceTypes.value = true
    store.getAvailableRaceTypes()
  }
}

const closeRaceModal = () => {
  showRaceModal.value = false
}

const selectRace = async (raceType) => {
  await store.setRaceSelection(raceType)
  closeRaceModal()
}

onMounted(async () => {
  await store.updateBrandRecognitionStatus()
  await store.updateRaceRecognitionStatus()
  if (store.brandRecognitionUnlocked) {
    await store.getBrandSelection()
  }
  if (store.raceRecognitionUnlocked) {
    await store.getRaceSelection()
  }
  
  events.on('businessComputer:onAvailableBrandsReceived', handleBrandsReceived)
  events.on('businessComputer:onAvailableRaceTypesReceived', handleRaceTypesReceived)
})

onUnmounted(() => {
  events.off('businessComputer:onAvailableBrandsReceived', handleBrandsReceived)
  events.off('businessComputer:onAvailableRaceTypesReceived', handleRaceTypesReceived)
})

watch(() => store.brandRecognitionUnlocked, async (unlocked) => {
  if (unlocked) {
    await store.getBrandSelection()
  }
})

watch(() => store.raceRecognitionUnlocked, async (unlocked) => {
  if (unlocked) {
    await store.getRaceSelection()
  }
})

const penaltyCost = computed(() => {
  if (!jobToAbandon.value) return 0
  return jobToAbandon.value.penalty || 0
})

const findVehicleForJob = (job) => {
  if (!Array.isArray(store.vehicles)) {
    return null
  }
  const jobId = normalizeId(job?.jobId ?? job?.id)
  if (jobId === null) {
    return null
  }
  return store.vehicles.find(vehicle => {
    if (!vehicle.jobId) return false
    return normalizeId(vehicle.jobId) === jobId
  }) || null
}

const handlePullOut = async (job) => {
  const vehicle = findVehicleForJob(job)
  if (!vehicle) {
    return
  }
  await store.pullOutVehicle(vehicle.vehicleId)
}

const handlePutAway = async (job) => {
  const vehicle = findVehicleForJob(job)
  await store.putAwayVehicle(vehicle?.vehicleId)
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

const handleAccept = async (job) => {
  await store.acceptJob(parseInt(job.id))
}

const handleDecline = async (job) => {
  await store.declineJob(parseInt(job.id))
}
</script>

<style scoped lang="scss">
.jobs-tab {
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

.recognition-banner {
  display: flex;
  align-items: center;
  gap: 1.5rem;
  padding: 0.75rem 1.25rem;
  border-radius: 0.75rem;
  background: rgba(30, 30, 30, 0.75);
  border: 1px solid rgba(255, 255, 255, 0.08);
  flex-wrap: wrap;

  .recognition-section {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    cursor: pointer;
    transition: opacity 0.2s;

    &:hover {
      opacity: 0.8;
    }
  }

  .banner-label {
    color: rgba(255, 255, 255, 0.55);
    font-size: 0.85rem;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    white-space: nowrap;
  }

  .banner-value {
    color: #fff;
    font-weight: 600;
    white-space: nowrap;
  }

  .summary-divider {
    width: 1px;
    height: 1.5rem;
    background: rgba(255, 255, 255, 0.1);
  }
}

.jobs-content {
  display: flex;
  flex-direction: column;
  gap: 2rem;
}

.job-section {
  h3 {
    margin: 0 0 1rem 0;
    color: rgba(245, 73, 0, 1);
    font-size: 1.25rem;
    font-weight: 600;
  }
}

.jobs-grid {
  display: grid;
  grid-template-columns: 1fr;
  gap: 1em;

  @media (min-width: 1024px) {
    grid-template-columns: repeat(2, minmax(0, 1fr));
  }
}

.job-card-wrapper {
  height: 100%;
}

.empty-state {
  padding: 3rem;
  text-align: center;
  color: rgba(255, 255, 255, 0.5);
}

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

  &.selection-modal {
    max-width: 25em;
    padding: 0;

    .modal-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 1rem 1.5rem;
      border-bottom: 1px solid rgba(255, 255, 255, 0.1);
      background: rgba(0, 0, 0, 0.2);

      h2 {
        margin: 0;
        font-size: 1.1rem;
        color: #fff;
        font-weight: 600;
      }

      .modal-close {
        background: none;
        border: none;
        color: rgba(255, 255, 255, 0.5);
        font-size: 1.5rem;
        line-height: 1;
        cursor: pointer;
        padding: 4px;
        border-radius: 4px;
        transition: all 0.2s;

        &:hover {
          background: rgba(255, 255, 255, 0.1);
          color: #fff;
        }
      }
    }

    .modal-body {
      padding: 1rem;
      max-height: 400px;
      overflow-y: auto;

      &::-webkit-scrollbar {
        width: 8px;
      }

      &::-webkit-scrollbar-track {
        background: rgba(0, 0, 0, 0.1);
      }

      &::-webkit-scrollbar-thumb {
        background: rgba(255, 255, 255, 0.1);
        border-radius: 4px;

        &:hover {
          background: rgba(255, 255, 255, 0.2);
        }
      }

      .modal-empty {
        text-align: center;
        padding: 2rem 1rem;

        p {
          color: rgba(255, 255, 255, 0.5);
          margin: 0;
        }
      }

      .selection-list {
        display: flex;
        flex-direction: column;
        gap: 0.5rem;

        .selection-item {
          width: 100%;
          padding: 0.75rem 1rem;
          background: rgba(255, 255, 255, 0.05);
          border: 1px solid rgba(255, 255, 255, 0.1);
          border-radius: 0.5rem;
          color: rgba(255, 255, 255, 0.9);
          font-size: 0.9rem;
          text-align: left;
          cursor: pointer;
          transition: all 0.2s;

          &:hover {
            background: rgba(255, 255, 255, 0.1);
            border-color: rgba(255, 255, 255, 0.2);
          }

          &.selected {
            background: rgba(245, 73, 0, 0.2);
            border-color: rgba(245, 73, 0, 0.5);
            color: #fff;
            font-weight: 600;
          }

          span {
            display: block;
          }
        }
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