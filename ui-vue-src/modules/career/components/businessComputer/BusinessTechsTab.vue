<template>
  <div class="techs-tab">
    <div class="tab-header">
      <h2>Techs</h2>
      <p>Monitor worker automation and assign jobs without leaving the desk.</p>
    </div>
    <div class="techs-info-banners">
      <div class="techs-summary-banner" v-if="techCapabilityTier || hasManager">
        <div class="summary-section" v-if="techCapabilityTier">
          <span class="banner-label">Capability</span>
          <span class="banner-value">Tier {{ techCapabilityTier }}</span>
        </div>

        <div class="summary-divider" v-if="techCapabilityTier && hasManager"></div>

        <div class="summary-section" v-if="hasManager">
          <span class="banner-label">Manager</span>
          <span class="banner-value">
            <span v-if="hasGeneralManager">GM</span>
            <span class="summary-separator" v-if="hasGeneralManager">•</span>
            <span>{{ managerAssignmentFrequency }}</span>
            <span class="summary-separator">•</span>
            <span :class="{ 'ready': managerReadyToAssign }">
              {{ managerStatusText }}
            </span>
          </span>
          <button
            class="manager-pause-btn"
            :class="{ 'paused': managerPaused, 'toggling': isTogglingPause }"
            :disabled="isTogglingPause"
            @click.stop="handleToggleManagerPause"
            @mousedown.stop
            data-focusable
            :title="managerPaused ? 'Resume Manager' : 'Pause Manager'"
          >
            <svg v-if="managerPaused" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <polygon points="5 3 19 12 5 21 5 3"></polygon>
            </svg>
            <svg v-else width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <rect x="6" y="4" width="4" height="16"></rect>
              <rect x="14" y="4" width="4" height="16"></rect>
            </svg>
          </button>
        </div>
      </div>
      <div v-if="managerCantAssignMessage" class="manager-warning-banner">
        <span class="warning-icon">⚠</span>
        <span class="warning-text">{{ managerCantAssignMessage }}</span>
      </div>
    </div>

    <div v-if="techList.length" class="techs-grid">
      <div
        v-for="tech in techList"
        :key="`tech-${tech.id}`"
        class="tech-card"
        :class="{ 
          'tech-card--working': tech.jobId && !tech.fired, 
          'tech-card--idle': !tech.jobId && !tech.fired,
          'tech-card--fired': tech.fired
        }"
        @click.stop
        @mousedown.stop
      >
        <div class="tech-card__header">
          <div class="tech-card__title">
            <div class="tech-card__icon">
              <div v-if="tech.fired" class="status-dot fired"></div>
              <div v-else-if="tech.jobId" class="status-dot active"></div>
              <div v-else class="status-dot idle"></div>
            </div>
            <template v-if="editingTechId === tech.id && !tech.fired">
              <input
                v-model="editedName"
                class="tech-card__input"
                maxlength="32"
                @keyup.enter="commitRename(tech)"
                @blur="onRenameBlur(); commitRename(tech)"
                @focus="onRenameFocus"
                @keydown.stop @keyup.stop @keypress.stop
                v-bng-text-input
                v-focus
              />
            </template>
            <template v-else>
              <h3>{{ tech.name }}</h3>
            </template>
            <button
              v-if="!tech.fired"
              class="icon-button"
              @click.stop="toggleRename(tech)"
              @mousedown.stop
              data-focusable
            >
              <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                <path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7"></path>
                <path d="M18.5 2.5a2.121 2.121 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z"></path>
              </svg>
            </button>
          </div>
          <div class="tech-card__success-rate" v-if="tech.successRate !== undefined && !tech.fired">
            <span class="success-rate-value">{{ tech.successRate }}%</span>
          </div>
          <div v-if="tech.fired" class="tech-card__fired-badge">
            <span>Fired</span>
          </div>
        </div>

        <div class="tech-card__progress-container" v-if="tech.jobId && !tech.fired">
          <div class="tech-card__progress-info">
            <span>{{ formatPhase(tech) }}</span>
          </div>
          <div class="tech-card__progress" aria-hidden="true">
            <div
              class="tech-card__progress-fill"
              :style="{ width: `${Math.min(100, Math.round(tech.progress * 100))}%` }"
            />
          </div>
          <span class="tech-card__state-badge" :class="getPhaseClass(tech)">
            {{ tech.label }}
          </span>
        </div>
        
        <div class="tech-card__divider"></div>

        <div class="tech-card__body">
          <div class="tech-card__row" v-if="!tech.fired">
            <span class="label">Current Assignment</span>
            <span class="value" :class="{ 'highlight': tech.jobId }">
              <template v-if="tech.jobId">
                {{ getJobLabel(tech.jobId) || "Unknown Job" }}
              </template>
              <template v-else>
                Idle - Ready for assignment
              </template>
            </span>
          </div>
          
          <div class="tech-card__stats-grid" v-if="!tech.fired">
             <div class="stat-item" v-if="tech.jobId && tech.phase !== 'baseline' && !(tech.validationAttempts === 0 && tech.maxValidationAttempts === 0)">
              <span class="stat-label">Attempts</span>
              <span class="stat-value">{{ tech.validationAttempts }} <span class="stat-sub">/ {{ tech.maxValidationAttempts }}</span></span>
            </div>
             <div class="stat-item" v-if="tech.jobReward !== undefined && tech.jobReward > 0">
              <span class="stat-label">Payment</span>
              <span class="stat-value">{{ formatCurrency(tech.jobReward) }}</span>
            </div>
             <div class="stat-item" v-if="getBuildCost(tech) > 0">
              <span class="stat-label">Build Cost</span>
              <span class="stat-value">{{ formatCurrency(getBuildCost(tech)) }}</span>
            </div>
          </div>

          <div class="tech-card__row result-row" v-if="tech.latestResult && !tech.fired">
            <span class="label">Last Result</span>
            <span class="value">
              <span :class="['pill', tech.latestResult.success ? 'success' : 'danger']">
                {{ tech.latestResult.success ? "Success" : "Fail" }}
              </span>
            </span>
          </div>

          <div v-if="tech.fired" class="assign-panel">
            <button
              class="btn-hire"
              @click.stop="handleHireTech(tech)"
              @mousedown.stop
              data-focusable
            >
              <span class="btn-icon">+</span>
              Hire Tech
            </button>
          </div>
          <div v-else-if="tech.jobId" class="assign-panel">
            <button
              class="btn-stop"
              @click.stop="handleStopTech(tech)"
              @mousedown.stop
              data-focusable
            >
              Stop Job
            </button>
          </div>
          <div v-else-if="!tech.jobId" class="assign-panel">
            <button
              class="btn-assign"
              :disabled="availableJobs.length === 0"
              @click.stop="openJobModal(tech, $event)"
              @mousedown.stop
              data-focusable
            >
              <span class="btn-icon">+</span>
              {{ availableJobs.length === 0 ? "No Jobs Available" : "Assign New Job" }}
            </button>
            <button
              class="btn-fire"
              @click.stop="handleFireTech(tech)"
              @mousedown.stop
              data-focusable
            >
              Fire Tech
            </button>
          </div>
        </div>
      </div>
    </div>

    <div v-if="techList.length === 0" class="empty-state">
      <div class="empty-state__icon">🔧</div>
      <h3>No Technicians Hired</h3>
      <p>Purchase shop upgrades to hire technicians and automate your workflow.</p>
    </div>

    <Teleport to="body">
      <transition name="modal-fade">
        <div
          v-if="openModalTechId !== null"
          class="job-select-modal-overlay"
          @click.stop="closeJobModal"
          @mousedown.stop="closeJobModal"
        >
          <div
            class="job-select-modal"
            @click.stop
            @mousedown.stop
            ref="jobModalRef"
          >
            <div class="job-select-modal__header">
              <h3>Assign Job to Tech</h3>
              <button
                class="job-select-modal__close"
                @click.stop="closeJobModal"
                @mousedown.stop
                data-focusable
              >
                ×
              </button>
            </div>
            <div class="job-select-modal__content">
              <div v-if="availableJobs.length === 0" class="job-select-modal__empty">
                <p>No available active jobs.</p>
                <small>Accept jobs from the Jobs tab first.</small>
              </div>
              <div v-else class="job-select-modal__grid">
                <JobAssignCard
                  v-for="job in availableJobs"
                  :key="`modal-job-${job.jobId}`"
                  :job="job"
                  @assign="selectJob(techList.find(t => t.id === openModalTechId), $event.jobId)"
                />
              </div>
            </div>
          </div>
        </div>
      </transition>
    </Teleport>
  </div>
</template>

<script setup>
import { computed, reactive, ref, Teleport, nextTick, onMounted, onUnmounted, watch, inject } from "vue"
import { useBusinessComputerStore } from "../../stores/businessComputerStore"
import { useBridge, lua } from "@/bridge"
import { vBngTextInput } from "@/common/directives"
import { formatCurrency, formatTime, formatPhase } from "../../utils/businessUtils"
import JobAssignCard from "./JobAssignCard.vue"

const store = useBusinessComputerStore()
const { events } = useBridge()
const controllerNav = inject('controllerNav', null)
const jobModalRef = ref(null)

const activeJobs = computed(() => {
  const jobs = store.activeJobs
  return Array.isArray(jobs) ? jobs : []
})
const availableJobs = computed(() => {
  const jobs = activeJobs.value
  return Array.isArray(jobs) ? jobs.filter(job => !job.techAssigned) : []
})

const techList = computed(() => store.techs || [])
const techCapabilityTier = computed(() => {
  const firstWithTier = techList.value.find(t => typeof t.maxTier === "number" && !t.fired)
  return firstWithTier ? firstWithTier.maxTier : null
})

const maxActiveJobs = computed(() => store.maxActiveJobs ?? 2)
const activeJobsCount = computed(() => store.activeJobs?.length ?? 0)
const idleTechsCount = computed(() => techList.value.filter(t => !t.jobId && !t.fired).length)
const newJobsCount = computed(() => store.newJobs?.length ?? 0)

const hasManager = computed(() => store.hasManager)
const hasGeneralManager = computed(() => store.hasGeneralManager)
const managerAssignmentInterval = computed(() => store.managerAssignmentInterval)
const managerReadyToAssign = computed(() => store.managerReadyToAssign)
const managerTimeRemainingFromStore = computed(() => store.managerTimeRemaining)
const managerPaused = computed(() => store.managerPaused)
const localManagerTimeRemaining = ref(null)

const managerAssignmentFrequency = computed(() => {
  if (hasGeneralManager.value) {
    return "Instant"
  }
  if (!managerAssignmentInterval.value) {
    return ""
  }
  const minutes = Math.floor(managerAssignmentInterval.value / 60)
  if (minutes === 1) {
    return "Every 1 minute"
  }
  return `Every ${minutes} minutes`
})

const managerStatusText = computed(() => {
  if (managerReadyToAssign.value) {
    return "Ready to assign"
  }
  const timeRemaining = localManagerTimeRemaining.value
  if (timeRemaining !== null && timeRemaining !== undefined && timeRemaining > 0) {
    const minutes = Math.floor(timeRemaining / 60)
    const seconds = Math.floor(timeRemaining % 60)
    if (minutes > 0) {
      return `Next in ${minutes}m ${seconds}s`
    }
    return `Next in ${seconds}s`
  }
  return "Not ready"
})

const managerCantAssignMessage = computed(() => {
  if (!hasManager.value || managerPaused.value) return null
  if (!managerReadyToAssign.value && !hasGeneralManager.value) return null
  if (idleTechsCount.value === 0) return null
  if (newJobsCount.value === 0) return null
  if (activeJobsCount.value < maxActiveJobs.value) return null
  return "Manager can't assign: no free active job slots"
})

const editingTechId = ref(null)
const editedName = ref("")
const openModalTechId = ref(null)

const vFocus = {
  mounted: (el) => el.focus()
}

const jobLookup = computed(() => {
  const map = new Map()
  const jobs = activeJobs.value
  if (Array.isArray(jobs)) {
    jobs.forEach(job => {
      const id = job?.jobId ?? job?.id
      if (id !== undefined && id !== null) {
        map.set(String(id), job)
      }
    })
  }
  return map
})

const getJobLabel = (jobId) => {
  if (jobId === null || jobId === undefined) return ""
  const job = jobLookup.value.get(String(jobId))
  return job?.goal || `Job #${jobId}`
}

const getPhaseClass = (tech) => {
    if (!tech.jobId) return 'badge-idle'
    if (tech.phase === 'failed') return 'badge-failed'
    if (tech.phase === 'completed') return 'badge-success'
    return 'badge-working'
}

let animationFrameId = null
let lastTime = performance.now()

const updateProgress = () => {
  const now = performance.now()
  const dt = (now - lastTime) / 1000
  lastTime = now
  
  if (localManagerTimeRemaining.value !== null && localManagerTimeRemaining.value !== undefined && localManagerTimeRemaining.value > 0) {
    localManagerTimeRemaining.value = Math.max(0, localManagerTimeRemaining.value - dt)
  }
  
  animationFrameId = requestAnimationFrame(updateProgress)
}

const openJobModal = async (tech, event) => {
  if (openModalTechId.value === tech.id) {
    closeJobModal()
    return
  }
  
  openModalTechId.value = tech.id
}

const closeJobModal = () => {
  openModalTechId.value = null
}

watch(openModalTechId, (newId, oldId) => {
  if (!controllerNav) return
  if (newId !== null) {
    nextTick(() => {
      if (jobModalRef.value) {
        controllerNav.pushModal(jobModalRef.value, closeJobModal)
      }
    })
  } else if (oldId !== null && jobModalRef.value) {
    controllerNav.removeModal(jobModalRef.value)
  }
})

const selectJob = async (tech, jobId) => {
  const success = await store.assignTechToJob(tech.id, jobId)
  if (success) {
    closeJobModal()
  }
}

const handleClickOutside = (event) => {
  if (openModalTechId.value && !event.target.closest('.job-select-modal') && !event.target.closest('.btn-assign')) {
    closeJobModal()
  }
}

const handleTechsUpdated = (data) => {
  const currentBusinessId = store.businessId
  if (!currentBusinessId) return

  const eventBusinessId = data?.businessId
  if (eventBusinessId && String(eventBusinessId) !== String(currentBusinessId)) {
    return
  }

  if (data?.techs && Array.isArray(data.techs)) {
    store.updateTechs(data.techs)
  }
}

  const refreshManagerTime = async () => {
    if (!store.businessId) return
    try {
      let data
      if (store.businessType === 'tuningShop') {
        data = await lua.career_modules_business_tuningShop.getManagerData(store.businessId)
      } else {
        data = await lua.career_modules_business_businessComputer.getManagerData(store.businessId)
      }
      
      if (data) {
        if (data.managerTimeRemaining !== undefined) {
          localManagerTimeRemaining.value = data.managerTimeRemaining
        }
        managerReadyToAssign.value = data.managerReadyToAssign
      }
    } catch (e) {}
  }

watch(managerTimeRemainingFromStore, (newValue) => {
  if (newValue !== null && newValue !== undefined) {
    localManagerTimeRemaining.value = newValue
  }
}, { immediate: true })

watch(managerReadyToAssign, (isReady) => {
  if (isReady) {
    localManagerTimeRemaining.value = 0
  }
})

onMounted(() => {
  document.addEventListener('click', handleClickOutside)
  events.on('businessComputer:onTechsUpdated', handleTechsUpdated)
  
  if (managerTimeRemainingFromStore.value !== null && managerTimeRemainingFromStore.value !== undefined) {
    localManagerTimeRemaining.value = managerTimeRemainingFromStore.value
  }
  
  refreshManagerTime()
  
  // Request fresh tech data to sync progress
  const fetchTechs = async () => {
    try {
      let data
      if (store.businessType === 'tuningShop') {
        data = await lua.career_modules_business_tuningShop.getTechData(store.businessId)
      } else {
        data = await lua.career_modules_business_businessComputer.getTechsOnly(store.businessId)
      }
      if (data && data.techs) {
        handleTechsUpdated(data)
      }
    } catch (e) {}
  }
  fetchTechs()

  lastTime = performance.now()
  updateProgress()
})

onUnmounted(() => {
  document.removeEventListener('click', handleClickOutside)
  events.off('businessComputer:onTechsUpdated', handleTechsUpdated)
  if (animationFrameId) cancelAnimationFrame(animationFrameId)
})

const toggleRename = (tech) => {
  if (editingTechId.value === tech.id) {
    commitRename(tech)
  } else {
    editingTechId.value = tech.id
    editedName.value = tech.name
  }
}

const commitRename = async (tech) => {
  if (editingTechId.value !== tech.id) return
  editingTechId.value = null
  const trimmed = (editedName.value || "").trim()
  if (!trimmed || trimmed === tech.name) {
    return
  }
  await store.renameTech(tech.id, trimmed)
}

const onRenameFocus = () => {
  try { lua.setCEFTyping(true) } catch (_) {}
}

const onRenameBlur = () => {
  try { lua.setCEFTyping(false) } catch (_) {}
}

const getBuildCost = (tech) => {
  const totalSpent = tech.totalSpent || 0
  const eventFunds = tech.eventFunds || 0
  return Math.max(0, totalSpent - eventFunds)
}

const handleFireTech = async (tech) => {
  if (!tech || tech.fired) return
  const success = await store.fireTech(tech.id)
  if (success) {
    closeJobModal()
  }
}

const handleHireTech = async (tech) => {
  if (!tech || !tech.fired) return
  const success = await store.hireTech(tech.id)
  if (success) {
    closeJobModal()
  }
}

const handleStopTech = async (tech) => {
  if (!tech || !tech.jobId || tech.fired) return
  const success = await store.stopTechFromJob(tech.id)
  if (success) {
    closeJobModal()
  }
}

const isTogglingPause = ref(false)
const handleToggleManagerPause = async () => {
  if (!hasManager.value) return
  if (isTogglingPause.value) return
  
  isTogglingPause.value = true
  try {
    await store.setManagerPaused(!managerPaused.value)
  } catch (error) {
    console.error('Error toggling manager pause:', error)
  } finally {
    isTogglingPause.value = false
  }
}
</script>

<style scoped lang="scss">
.techs-tab {
  display: flex;
  flex-direction: column;
  gap: 2em;
  padding-bottom: 2em;
}

.techs-info-banners {
  display: flex;
  flex-direction: column;
  gap: 0.75em;
}

.manager-warning-banner {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 0.5em;
  padding: 0.5em 1em;
  margin-top: 0.75em;
  border-radius: 0.75em;
  background: rgba(231, 76, 60, 0.15);
  border: 1px solid rgba(231, 76, 60, 0.4);
  color: #e74c3c;
  font-size: 0.9em;
  font-weight: 500;
}

.warning-icon {
  font-size: 1.2em;
  line-height: 1;
  display: flex;
  align-items: center;
}

.warning-text {
  display: flex;
  align-items: center;
}

.techs-summary-banner {
  display: flex;
  align-items: center;
  gap: 1.5em;
  padding: 0.75em 1.25em;
  border-radius: 0.75em;
  background: rgba(30, 30, 30, 0.75);
  border: 1px solid rgba(255, 255, 255, 0.08);
  flex-wrap: wrap;

  .summary-section {
    display: flex;
    align-items: center;
    gap: 0.75em;
    flex: 1;
  }

  .banner-label {
    color: rgba(255, 255, 255, 0.55);
    font-size: 0.85em;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    white-space: nowrap;
  }

  .banner-value {
    color: #fff;
    font-weight: 600;
    display: flex;
    align-items: center;
    gap: 0.5em;
    white-space: nowrap;
    
    .summary-separator {
      color: rgba(255, 255, 255, 0.3);
    }
  }

  .manager-pause-btn {
    background: rgba(255, 255, 255, 0.1);
    border: 1px solid rgba(255, 255, 255, 0.2);
    border-radius: 6px;
    padding: 0.4em;
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: center;
    transition: all 0.2s;
    color: rgba(255, 255, 255, 0.7);
    min-width: 32px;
    height: 32px;

    &:hover {
      background: rgba(255, 255, 255, 0.15);
      border-color: rgba(255, 255, 255, 0.3);
      color: #fff;
    }

    &:active {
      transform: scale(0.95);
    }

    &.paused {
      background: rgba(241, 196, 15, 0.2);
      border-color: rgba(241, 196, 15, 0.4);
      color: #f1c40f;

      &:hover {
        background: rgba(241, 196, 15, 0.3);
        border-color: rgba(241, 196, 15, 0.5);
      }
    }

    &:disabled,
    &.toggling {
      opacity: 0.5;
      cursor: not-allowed;
      pointer-events: none;
    }

    svg {
      width: 16px;
      height: 16px;
    }
    
    .ready {
      color: #2ecc71;
    }
  }
  
  .summary-divider {
    width: 1px;
    height: 1.5em;
    background: rgba(255, 255, 255, 0.1);
  }
}

.tab-header {
  h2 {
    margin: 0;
    color: #fff;
    font-size: 1.75em;
    font-weight: 600;
    letter-spacing: -0.02em;
  }

  p {
    margin: 0.5em 0 0;
    color: rgba(255, 255, 255, 0.5);
    font-size: 1em;
  }
}

.techs-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(320px, 1fr));
  gap: 1.5em;
}

.tech-card {
  background: linear-gradient(145deg, rgba(30, 30, 30, 0.9), rgba(20, 20, 20, 0.95));
  border: 1px solid rgba(255, 255, 255, 0.05);
  border-radius: 16px;
  padding: 1.25em;
  display: flex;
  flex-direction: column;
  gap: 1em;
  transition: transform 0.2s, box-shadow 0.2s, border-color 0.2s;
  box-shadow: 0 4px 24px rgba(0, 0, 0, 0.2);

  &:hover {
    border-color: rgba(255, 255, 255, 0.1);
    box-shadow: 0 8px 32px rgba(0, 0, 0, 0.3);
  }
  
  &--working {
    border-left: 4px solid #ff6600;
  }
  
  &--idle {
    border-left: 4px solid rgba(255, 255, 255, 0.2);
    opacity: 0.9;
  }
  
  &--fired {
    border-left: 4px solid rgba(255, 255, 255, 0.1);
    opacity: 0.6;
  }
}

.tech-card__header {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  gap: 0.75em;
}

.tech-card__success-rate {
  display: flex;
  flex-direction: column;
  align-items: flex-end;
  gap: 0.15em;
  min-width: 0;
  
  .success-rate-label {
    font-size: 0.7em;
    color: rgba(255, 255, 255, 0.4);
    text-transform: uppercase;
    white-space: nowrap;
  }
  
  .success-rate-value {
    font-size: 1em;
    font-weight: 600;
    color: #fff;
    white-space: nowrap;
  }
}

.tech-card__fired-badge {
  display: flex;
  align-items: center;
  padding: 0.25em 0.75em;
  background: rgba(255, 255, 255, 0.05);
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: 6px;
  font-size: 0.75em;
  font-weight: 600;
  color: rgba(255, 255, 255, 0.5);
  text-transform: uppercase;
  letter-spacing: 0.05em;
}

.tech-card__title {
  display: flex;
  align-items: center;
  gap: 0.75em;
  flex: 1;
  min-width: 0;
  
  h3 {
    margin: 0;
    font-size: 1.1em;
    font-weight: 600;
    color: #fff;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
}

.status-dot {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  
  &.active {
    background-color: #ff6600;
    box-shadow: 0 0 8px rgba(255, 102, 0, 0.5);
  }
  
  &.idle {
    background-color: rgba(255, 255, 255, 0.2);
  }
  
  &.fired {
    background-color: rgba(255, 255, 255, 0.1);
  }
}

.icon-button {
  background: none;
  border: none;
  color: rgba(255, 255, 255, 0.3);
  cursor: pointer;
  padding: 4px;
  border-radius: 4px;
  display: flex;
  align-items: center;
  justify-content: center;
  transition: color 0.2s, background 0.2s;
  
  &:hover {
    color: #fff;
    background: rgba(255, 255, 255, 0.1);
  }
}

.tech-card__input {
  background: rgba(0, 0, 0, 0.3);
  border: 1px solid #ff6600;
  border-radius: 4px;
  padding: 0.25em 0.5em;
  color: #fff;
  font-size: 1.1em;
  width: 100%;
  max-width: 180px;
  outline: none;
}

.tech-card__state-badge {
  font-size: 0.75em;
  font-weight: 600;
  padding: 0.25em 0.75em;
  border-radius: 6px;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  
  &.badge-working {
    background: rgba(255, 102, 0, 0.15);
    color: #ff9933;
    border: 1px solid rgba(255, 102, 0, 0.3);
  }
  
  &.badge-idle {
    background: rgba(255, 255, 255, 0.05);
    color: rgba(255, 255, 255, 0.5);
    border: 1px solid rgba(255, 255, 255, 0.1);
  }
  
  &.badge-success {
    background: rgba(46, 204, 113, 0.15);
    color: #2ecc71;
    border: 1px solid rgba(46, 204, 113, 0.3);
  }
  
  &.badge-failed {
    background: rgba(231, 76, 60, 0.15);
    color: #e74c3c;
    border: 1px solid rgba(231, 76, 60, 0.3);
  }
}

.tech-card__progress-container {
  display: flex;
  flex-direction: column;
  gap: 0.5em;
}

.tech-card__progress-info {
  display: flex;
  justify-content: space-between;
  font-size: 0.85em;
  color: rgba(255, 255, 255, 0.6);
  font-weight: 500;
}

.tech-card__progress {
  height: 6px;
  background: rgba(255, 255, 255, 0.05);
  border-radius: 3px;
  overflow: hidden;
}

.tech-card__progress-fill {
  height: 100%;
  background: linear-gradient(90deg, #ff6600, #ff9933);
  border-radius: 3px;
  transition: width 0.1s linear;
}

.tech-card__divider {
  height: 1px;
  background: rgba(255, 255, 255, 0.05);
  margin: 0.25em 0;
}

.tech-card__body {
  display: flex;
  flex-direction: column;
  gap: 0.75em;
}

.tech-card__row {
  display: flex;
  justify-content: space-between;
  align-items: center;
  font-size: 0.9em;
  
  .label {
    color: rgba(255, 255, 255, 0.4);
  }
  
  .value {
    color: rgba(255, 255, 255, 0.9);
    font-weight: 500;
    
    &.highlight {
      color: #ff9933;
    }
  }
}

.tech-card__stats-grid {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 1em;
  margin-top: 0.25em;
  
  .stat-item:nth-child(3) {
    grid-column: 1 / -1;
  }
  
  .stat-item {
    background: rgba(0, 0, 0, 0.2);
    padding: 0.5em 0.75em;
    border-radius: 8px;
    display: flex;
    flex-direction: column;
    gap: 0.15em;
  }
  
  .stat-label {
    font-size: 0.75em;
    color: rgba(255, 255, 255, 0.4);
    text-transform: uppercase;
  }
  
  .stat-value {
    font-size: 1em;
    font-weight: 600;
    color: #fff;
    
    .stat-sub {
      font-size: 0.8em;
      color: rgba(255, 255, 255, 0.3);
      font-weight: 400;
    }
  }
}

.assign-panel {
  display: flex;
  flex-direction: column;
  gap: 0.5em;
}

.btn-assign {
  width: 100%;
  padding: 0.75em;
  background: rgba(255, 102, 0, 0.1);
  border: 1px dashed rgba(255, 102, 0, 0.4);
  border-radius: 8px;
  color: #ff6600;
  font-weight: 600;
  cursor: pointer;
  transition: all 0.2s;
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 0.5em;
  
  &:hover:not(:disabled) {
    background: rgba(255, 102, 0, 0.2);
    border-style: solid;
    transform: translateY(-1px);
  }
  
  &:active:not(:disabled) {
    transform: translateY(0);
  }
  
  &:disabled {
    opacity: 0.5;
    cursor: not-allowed;
    border-color: rgba(255, 255, 255, 0.1);
    color: rgba(255, 255, 255, 0.3);
  }
  
  .btn-icon {
    font-size: 1.2em;
    line-height: 1;
  }
}

.btn-stop {
  width: 100%;
  padding: 0.75em;
  background: rgba(241, 196, 15, 0.1);
  border: 1px solid rgba(241, 196, 15, 0.3);
  border-radius: 8px;
  color: #f1c40f;
  font-weight: 600;
  cursor: pointer;
  transition: all 0.2s;
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 0.5em;
  
  &:hover {
    background: rgba(241, 196, 15, 0.2);
    transform: translateY(-1px);
  }
  
  &:active {
    transform: translateY(0);
  }
}

.btn-fire {
  width: 100%;
  padding: 0.75em;
  background: rgba(231, 76, 60, 0.1);
  border: 1px solid rgba(231, 76, 60, 0.3);
  border-radius: 8px;
  color: #e74c3c;
  font-weight: 600;
  cursor: pointer;
  transition: all 0.2s;
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 0.5em;
  
  &:hover {
    background: rgba(231, 76, 60, 0.2);
    transform: translateY(-1px);
  }
  
  &:active {
    transform: translateY(0);
  }
}

.btn-hire {
  width: 100%;
  padding: 0.75em;
  background: rgba(46, 204, 113, 0.1);
  border: 1px dashed rgba(46, 204, 113, 0.4);
  border-radius: 8px;
  color: #2ecc71;
  font-weight: 600;
  cursor: pointer;
  transition: all 0.2s;
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 0.5em;
  
  &:hover {
    background: rgba(46, 204, 113, 0.2);
    border-style: solid;
    transform: translateY(-1px);
  }
  
  &:active {
    transform: translateY(0);
  }
  
  .btn-icon {
    font-size: 1.2em;
    line-height: 1;
  }
}

.empty-state {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  padding: 4em 2em;
  background: rgba(255, 255, 255, 0.02);
  border: 1px dashed rgba(255, 255, 255, 0.1);
  border-radius: 16px;
  text-align: center;
  
  &__icon {
    font-size: 3em;
    margin-bottom: 1em;
    opacity: 0.5;
  }
  
  h3 {
    color: #fff;
    margin: 0 0 0.5em 0;
  }
  
  p {
    color: rgba(255, 255, 255, 0.5);
    max-width: 300px;
    margin: 0;
  }
}

/* Modal Styles */
.job-select-modal-overlay {
  position: fixed;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  z-index: 10000;
  background: rgba(0, 0, 0, 0.7);
  backdrop-filter: blur(4px);
  display: flex;
  align-items: center;
  justify-content: center;
}

.job-select-modal {
  background: #1a1a1a;
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: 12px;
  box-shadow: 0 20px 50px rgba(0, 0, 0, 0.5);
  width: 500px;
  max-width: 90vw;
  max-height: 80vh;
  display: flex;
  flex-direction: column;
  z-index: 10001;
}

.job-select-modal__header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 1em 1.5em;
  border-bottom: 1px solid rgba(255, 255, 255, 0.05);
  background: rgba(0, 0, 0, 0.2);

  h3 {
    margin: 0;
    font-size: 1.1em;
    color: #fff;
    font-weight: 600;
  }
}

.job-select-modal__close {
  background: none;
  border: none;
  color: rgba(255, 255, 255, 0.5);
  font-size: 1.5em;
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

.job-select-modal__content {
  padding: 1.5em;
  overflow-y: auto;
  flex: 1;
  
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
}

.job-select-modal__empty {
  text-align: center;
  padding: 3em 1em;
  
  p {
    color: rgba(255, 255, 255, 0.7);
    margin: 0 0 0.5em 0;
    font-size: 1.1em;
  }
  
  small {
    color: rgba(255, 255, 255, 0.4);
  }
}

.job-select-modal__grid {
  display: flex;
  flex-direction: column;
  gap: 1em;
}


.pill {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  border-radius: 4px;
  padding: 0.25em 0.75em;
  font-size: 0.85em;
  font-weight: 600;
  
  &.success {
    background: rgba(46, 204, 113, 0.15);
    color: #2ecc71;
  }
  
  &.danger {
    background: rgba(231, 76, 60, 0.15);
    color: #e74c3c;
  }
}

.modal-fade-enter-active,
.modal-fade-leave-active {
  transition: opacity 0.2s, transform 0.2s;
}

.modal-fade-enter-from,
.modal-fade-leave-to {
  opacity: 0;
  transform: scale(0.95);
}
</style>
