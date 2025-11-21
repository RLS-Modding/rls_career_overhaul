<template>
  <div class="techs-tab">
    <div class="tab-header">
      <h2>Techs</h2>
      <p>Monitor worker automation and assign jobs without leaving the desk.</p>
    </div>

    <div v-if="techList.length" class="techs-grid">
      <div
        v-for="tech in techList"
        :key="`tech-${tech.id}`"
        class="tech-card"
        :class="{ 'tech-card--working': tech.jobId, 'tech-card--idle': !tech.jobId }"
        @click.stop
        @mousedown.stop
      >
        <div class="tech-card__header">
          <div class="tech-card__title">
            <div class="tech-card__icon">
              <div v-if="tech.jobId" class="status-dot active"></div>
              <div v-else class="status-dot idle"></div>
            </div>
            <template v-if="editingTechId === tech.id">
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
              class="icon-button"
              @click.stop="toggleRename(tech)"
              @mousedown.stop
            >
              <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                <path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7"></path>
                <path d="M18.5 2.5a2.121 2.121 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z"></path>
              </svg>
            </button>
          </div>
        </div>

        <div class="tech-card__progress-container" v-if="tech.jobId">
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
          <div class="tech-card__row">
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
          
          <div class="tech-card__stats-grid">
             <div class="stat-item" v-if="tech.jobId">
              <span class="stat-label">Attempts</span>
              <span class="stat-value">{{ tech.validationAttempts }} <span class="stat-sub">/ {{ tech.maxValidationAttempts }}</span></span>
            </div>
             <div class="stat-item" v-if="tech.totalSpent > 0">
              <span class="stat-label">Cost</span>
              <span class="stat-value">${{ tech.totalSpent }}</span>
            </div>
          </div>

          <div class="tech-card__row result-row" v-if="tech.latestResult">
            <span class="label">Last Result</span>
            <span class="value">
              <span :class="['pill', tech.latestResult.success ? 'success' : 'danger']">
                {{ tech.latestResult.success ? "Success" : "Fail" }}
              </span>
            </span>
          </div>

          <div v-if="!tech.jobId" class="assign-panel">
            <button
              class="btn-assign"
              :disabled="availableJobs.length === 0"
              @click.stop="openJobModal(tech, $event)"
              @mousedown.stop
            >
              <span class="btn-icon">+</span>
              {{ availableJobs.length === 0 ? "No Jobs Available" : "Assign New Job" }}
            </button>
          </div>
        </div>
      </div>
    </div>

    <div v-else class="empty-state">
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
            :style="{
              top: `${modalPosition.top}px`,
              left: `${modalPosition.left}px`
            }"
            @click.stop
            @mousedown.stop
          >
            <div class="job-select-modal__header">
              <h3>Assign Job to Tech</h3>
              <button
                class="job-select-modal__close"
                @click.stop="closeJobModal"
                @mousedown.stop
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
import { computed, reactive, ref, Teleport, nextTick, onMounted, onUnmounted, watch } from "vue"
import { useBusinessComputerStore } from "../../stores/businessComputerStore"
import { useBridge, lua } from "@/bridge"
import { vBngTextInput } from "@/common/directives"
import JobAssignCard from "./JobAssignCard.vue"

const store = useBusinessComputerStore()
const { events } = useBridge()

const techs = ref([])
const activeJobs = computed(() => store.activeJobs || [])
const availableJobs = computed(() =>
  activeJobs.value.filter(job => !job.techAssigned)
)

const techList = computed(() => techs.value)

const editingTechId = ref(null)
const editedName = ref("")
const openModalTechId = ref(null)
const modalPosition = ref({ top: 0, left: 0 })

const vFocus = {
  mounted: (el) => el.focus()
}

const jobLookup = computed(() => {
  const map = new Map()
  activeJobs.value.forEach(job => {
    const id = job?.jobId ?? job?.id
    if (id !== undefined && id !== null) {
      map.set(String(id), job)
    }
  })
  return map
})

const getJobLabel = (jobId) => {
  if (jobId === null || jobId === undefined) return ""
  const job = jobLookup.value.get(String(jobId))
  return job?.goal || `Job #${jobId}`
}

const formatPhase = (tech) => {
  const phaseMap = {
    baseline: "Baseline Run",
    validation: "Validation Run",
    postUpdate: "Final Verification",
    completed: "Completed",
    failed: "Failed",
    idle: "Idle",
    build: "Building",
    update: "Tuning",
    cooldown: "Cooling Down"
  }
  return phaseMap[tech.phase] || tech.action || "Idle"
}

const getPhaseClass = (tech) => {
    if (!tech.jobId) return 'badge-idle'
    if (tech.phase === 'failed') return 'badge-failed'
    if (tech.phase === 'completed') return 'badge-success'
    return 'badge-working'
}

const formatTime = (seconds) => {
    if (!seconds || seconds <= 0) return "0s"
    if (seconds < 60) return `${Math.ceil(seconds)}s`
    const m = Math.floor(seconds / 60)
    const s = Math.ceil(seconds % 60)
    return `${m}m ${s}s`
}

// Animation Loop
let animationFrameId = null
let lastTime = performance.now()

const updateProgress = () => {
  const now = performance.now()
  const dt = (now - lastTime) / 1000
  lastTime = now

  techs.value.forEach(tech => {
     if (tech.jobId && tech.totalSeconds > 0) {
        if (tech.remainingSeconds > 0) {
            tech.remainingSeconds = Math.max(0, tech.remainingSeconds - dt)
            tech.progress = Math.min(1, 1 - (tech.remainingSeconds / tech.totalSeconds))
        } else {
           tech.progress = 1
           tech.remainingSeconds = 0
        }
     }
  })
  
  animationFrameId = requestAnimationFrame(updateProgress)
}

const openJobModal = async (tech, event) => {
  if (openModalTechId.value === tech.id) {
    closeJobModal()
    return
  }
  
  openModalTechId.value = tech.id
  await nextTick()
  
  const button = event?.target?.closest('.btn-assign')
  if (button) {
    const rect = button.getBoundingClientRect()
    const modalWidth = 500
    const modalHeight = Math.min(window.innerHeight * 0.8, 600)
    const spacing = 8
    
    let left = rect.left
    let top = rect.bottom + spacing
    
    if (left + modalWidth > window.innerWidth) {
      left = window.innerWidth - modalWidth - 16
    }
    if (left < 16) {
      left = 16
    }
    
    if (top + modalHeight > window.innerHeight) {
      top = rect.top - modalHeight - spacing
    }
    if (top < 16) {
      top = 16
    }
    
    modalPosition.value = { top, left }
  }
}

const closeJobModal = () => {
  openModalTechId.value = null
}

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
      // Merge strategy to prevent jump if possible, but simple replacement is safer for state sync
    techs.value = JSON.parse(JSON.stringify(data.techs))
  }
}

onMounted(() => {
  document.addEventListener('click', handleClickOutside)
  events.on('businessComputer:onTechsUpdated', handleTechsUpdated)
  if (store.techs && Array.isArray(store.techs)) {
    techs.value = JSON.parse(JSON.stringify(store.techs))
  }
  
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
</script>

<style scoped lang="scss">
.techs-tab {
  display: flex;
  flex-direction: column;
  gap: 2rem;
  padding-bottom: 2rem;
}

.tab-header {
  h2 {
    margin: 0;
    color: #fff;
    font-size: 1.75rem;
    font-weight: 600;
    letter-spacing: -0.02em;
  }

  p {
    margin: 0.5rem 0 0;
    color: rgba(255, 255, 255, 0.5);
    font-size: 1rem;
  }
}

.techs-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(320px, 1fr));
  gap: 1.5rem;
}

.tech-card {
  background: linear-gradient(145deg, rgba(30, 30, 30, 0.9), rgba(20, 20, 20, 0.95));
  border: 1px solid rgba(255, 255, 255, 0.05);
  border-radius: 16px;
  padding: 1.25rem;
  display: flex;
  flex-direction: column;
  gap: 1rem;
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
}

.tech-card__header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 0.75rem;
}

.tech-card__title {
  display: flex;
  align-items: center;
  gap: 0.75rem;
  flex: 1;
  min-width: 0;
  
  h3 {
    margin: 0;
    font-size: 1.1rem;
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
  padding: 0.25rem 0.5rem;
  color: #fff;
  font-size: 1.1rem;
  width: 100%;
  max-width: 180px;
  outline: none;
}

.tech-card__state-badge {
  font-size: 0.75rem;
  font-weight: 600;
  padding: 0.25rem 0.75rem;
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
  gap: 0.5rem;
}

.tech-card__progress-info {
  display: flex;
  justify-content: space-between;
  font-size: 0.85rem;
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
  margin: 0.25rem 0;
}

.tech-card__body {
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
}

.tech-card__row {
  display: flex;
  justify-content: space-between;
  align-items: center;
  font-size: 0.9rem;
  
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
  gap: 1rem;
  margin-top: 0.25rem;
  
  .stat-item {
    background: rgba(0, 0, 0, 0.2);
    padding: 0.5rem 0.75rem;
    border-radius: 8px;
    display: flex;
    flex-direction: column;
    gap: 0.15rem;
  }
  
  .stat-label {
    font-size: 0.75rem;
    color: rgba(255, 255, 255, 0.4);
    text-transform: uppercase;
  }
  
  .stat-value {
    font-size: 1rem;
    font-weight: 600;
    color: #fff;
    
    .stat-sub {
      font-size: 0.8rem;
      color: rgba(255, 255, 255, 0.3);
      font-weight: 400;
    }
  }
}

.btn-assign {
  width: 100%;
  padding: 0.75rem;
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
  gap: 0.5rem;
  
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
    font-size: 1.2rem;
    line-height: 1;
  }
}

.empty-state {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  padding: 4rem 2rem;
  background: rgba(255, 255, 255, 0.02);
  border: 1px dashed rgba(255, 255, 255, 0.1);
  border-radius: 16px;
  text-align: center;
  
  &__icon {
    font-size: 3rem;
    margin-bottom: 1rem;
    opacity: 0.5;
  }
  
  h3 {
    color: #fff;
    margin: 0 0 0.5rem 0;
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
}

.job-select-modal {
  position: fixed;
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
  padding: 1rem 1.5rem;
  border-bottom: 1px solid rgba(255, 255, 255, 0.05);
  background: rgba(0, 0, 0, 0.2);

  h3 {
    margin: 0;
    font-size: 1.1rem;
    color: #fff;
    font-weight: 600;
  }
}

.job-select-modal__close {
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

.job-select-modal__content {
  padding: 1.5rem;
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
  padding: 3rem 1rem;
  
  p {
    color: rgba(255, 255, 255, 0.7);
    margin: 0 0 0.5rem 0;
    font-size: 1.1rem;
  }
  
  small {
    color: rgba(255, 255, 255, 0.4);
  }
}

.job-select-modal__grid {
  display: flex;
  flex-direction: column;
  gap: 1rem;
}


.pill {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  border-radius: 4px;
  padding: 0.25rem 0.75rem;
  font-size: 0.85rem;
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
