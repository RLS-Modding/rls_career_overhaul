<template>
  <PhoneWrapper app-name="Tuning Shop" status-font-color="#FFFFFF" status-blend-mode="">
    <div class="phone-tuning-shop">
      <div v-if="loading" class="loading-state">
        Loading...
      </div>
      <div v-else-if="!hasBusiness" class="error-state">
        No Tuning Shop found with App access.
      </div>
      <div v-else class="jobs-content">
        <!-- Active Jobs Section -->
        <div v-if="store.activeJobs.length > 0" class="job-section">
          <h3>Active Jobs</h3>
          <div class="jobs-list">
            <div 
              v-for="job in store.activeJobs" 
              :key="`active-${job.id}`"
              class="job-item"
            >
              <BusinessJobCard
                :job="job"
                :is-active="true"
                :is-vertical="true"
                :business-id="store.businessId"
                @abandon="handleAbandon(job)"
                @complete="handleComplete(job)"
              />
            </div>
          </div>
        </div>

        <!-- New Jobs Section -->
        <div v-if="store.newJobs.length > 0" class="job-section">
          <h3>New Jobs</h3>
          <div class="jobs-list">
            <div 
              v-for="job in store.newJobs" 
              :key="`new-${job.id}`"
              class="job-item"
            >
              <BusinessJobCard
                :job="job"
                :is-active="false"
                :is-vertical="true"
                @accept="handleAccept(job)"
                @decline="handleDecline(job)"
              />
            </div>
          </div>
        </div>

        <div v-if="store.activeJobs.length === 0 && store.newJobs.length === 0" class="empty-state">
          No jobs available right now
        </div>
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
    </div>
  </PhoneWrapper>
</template>

<script setup>
import { ref, computed, onMounted } from "vue"
import PhoneWrapper from "./PhoneWrapper.vue"
import BusinessJobCard from "../components/businessComputer/BusinessJobCard.vue"
import { useBusinessComputerStore } from "../stores/businessComputerStore"
import { lua } from "@/bridge"

const store = useBusinessComputerStore()
const loading = ref(true)
const hasBusiness = ref(false)

const showAbandonModal = ref(false)
const jobToAbandon = ref(null)

const penaltyCost = computed(() => {
  if (!jobToAbandon.value) return 0
  return jobToAbandon.value.penalty || 0
})

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
    if (store.businessId) {
      await store.loadBusinessData("tuningShop", store.businessId)
    }
  }
}

const cancelAbandon = () => {
  showAbandonModal.value = false
  jobToAbandon.value = null
}

const handleComplete = async (job) => {
  const jobId = job.jobId ?? parseInt(job.id)
  await store.completeJob(jobId)
  if (store.businessId) {
    await store.loadBusinessData("tuningShop", store.businessId)
  }
}

const handleAccept = async (job) => {
  await store.acceptJob(parseInt(job.id))
  if (store.businessId) {
    await store.loadBusinessData("tuningShop", store.businessId)
  }
}

const handleDecline = async (job) => {
  await store.declineJob(parseInt(job.id))
  if (store.businessId) {
    await store.loadBusinessData("tuningShop", store.businessId)
  }
}

onMounted(async () => {
  loading.value = true
  try {
    // Find a tuning shop that has the shop-app upgrade
    // We need to query Lua for this info
    // For now, we'll fetch all purchased tuning shops and check permissions
    
    // Note: ideally we should have a helper in Lua to get the "phone accessible" business ID
    // But let's try to do it here using available APIs
    
    const purchased = await lua.career_modules_business_businessManager.getPurchasedBusinesses("tuningShop")
    
    let targetBusinessId = null
    
    if (purchased) {
      for (const [id, owned] of Object.entries(purchased)) {
        if (owned) {
          // Check for upgrade
          // Using safe access to skill tree
          const level = await lua.career_modules_business_businessSkillTree.getNodeProgress(id, "quality-of-life", "shop-app")
          if (level && level > 0) {
            targetBusinessId = id
            break
          }
        }
      }
    }
    
    if (targetBusinessId) {
      await store.loadBusinessData("tuningShop", targetBusinessId)
      hasBusiness.value = true
    } else {
      hasBusiness.value = false
    }
  } catch (e) {
    console.error("Failed to load tuning shop phone app data", e)
    hasBusiness.value = false
  } finally {
    loading.value = false
  }
})
</script>

<style scoped lang="scss">
.phone-tuning-shop {
  height: 100%;
  overflow-y: auto;
  padding: 1rem;
  padding-top: 3.5rem;
  
  /* Hide scrollbar for Chrome, Safari and Opera */
  &::-webkit-scrollbar {
    display: none;
  }
  /* Hide scrollbar for IE, Edge and Firefox */
  -ms-overflow-style: none;  /* IE and Edge */
  scrollbar-width: none;  /* Firefox */
}

.loading-state, .error-state, .empty-state {
  height: 100%;
  display: flex;
  align-items: center;
  justify-content: center;
  text-align: center;
  color: rgba(255, 255, 255, 0.5);
  font-size: 1.1rem;
  padding: 2rem;
}

.job-section {
  margin-bottom: 1.5rem;
  
  h3 {
    margin: 0 0 0.75rem 0;
    color: rgba(245, 73, 0, 1);
    font-size: 1.1rem;
    font-weight: 600;
    padding-left: 0.25rem;
  }
}

.jobs-list {
  display: grid;
  grid-template-columns: repeat(2, 1fr);
  gap: 0.75rem;
}

.job-item {
  /* Ensure card takes full width */
}

:deep(.job-card) {
  font-size: 0.85rem;
  
  .vehicle-name-active,
  .vehicle-name-new {
    font-size: 1rem;
  }
  
  .reward-value {
    font-size: 1rem;
  }
  
  .goal-chip {
    padding: 0.5rem 0.6rem;
    
    .goal-chip-content {
      flex-direction: column;
      align-items: flex-start;
      gap: 0.4rem;
    }
    
    .goal-chip-text {
      width: 100%;
    }
    
    .goal-chip-value {
      font-size: 0.75rem;
      line-height: 1.2;
    }
    
    .goal-chip-label {
      font-size: 0.6rem;
      margin-bottom: 0.1rem;
    }
    
    .current-time-wrapper {
      align-items: flex-start;
      margin-top: 0.25rem;
      padding-top: 0.25rem;
      border-top: 1px solid rgba(255, 255, 255, 0.1);
      width: 100%;
    }
    
    .current-time-value {
      font-size: 0.75rem;
      line-height: 1.2;
    }
    
    .current-time-label {
      font-size: 0.6rem;
      margin-bottom: 0.1rem;
    }
  }
  
  .reward-label {
    font-size: 0.65rem;
  }
  
  .status-badge {
    font-size: 0.65rem;
    padding: 0.2rem 0.4rem;
  }
  
  .badge {
    font-size: 0.65rem;
    padding: 0.2rem 0.4rem;
  }
  
  .btn {
    font-size: 0.75rem;
    padding: 0.4rem 0.75rem;
  }
  
  .expiration-chip {
    font-size: 0.65rem;
    padding: 0.25rem 0.6rem;
  }
}

:deep(.job-actions-active) {
  .btn-primary {
    display: none;
  }
}

/* Reuse modal styles from BusinessJobsTab */
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
  padding: 1.5em;
  max-width: 20em;
  width: 90%;
  box-shadow: 0 8px 32px rgba(0, 0, 0, 0.5);

  h2 {
    margin: 0 0 0.75em 0;
    color: white;
    font-size: 1.25em;
    font-weight: 600;
  }

  p {
    margin: 0 0 1.5em 0;
    color: rgba(255, 255, 255, 0.8);
    font-size: 0.9em;
    line-height: 1.4;
  }

  .penalty-text {
    color: #F54900;
    font-weight: 600;
  }

  .modal-buttons {
    display: flex;
    gap: 0.75em;
    justify-content: flex-end;
  }

  .btn {
    padding: 0.6em 1.2em;
    border: none;
    border-radius: 0.25em;
    font-size: 0.85em;
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

