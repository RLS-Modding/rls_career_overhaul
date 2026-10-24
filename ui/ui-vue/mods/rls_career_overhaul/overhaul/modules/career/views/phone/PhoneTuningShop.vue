<!--
  Phone Tuning Shop (view). Map:
  - Owns: the view state (tabs, Jobs sub-tab, modals), the Lua/event lifecycle, the job completion status cache, and
    every store and Lua call. Children never call the store, the bridge or Lua.
  - Parts, under ./phoneTuningShop/: DashboardTab and JobsTab are presentational (narrow props in, semantic
    events out). The Techs tab, the Finances tab and the bottom nav are small and stay in this file. finances.js is
    the pure 24 h history maths.
  - Stays in this file: the assign and abandon modals (they share the modal state and the .modal-fade transition),
    and the tab state (so the active tab and the Jobs sub-tab survive a tab switch).
  - Reading order: the script top to bottom (state, derived views, completion status, handlers, finances, watchers,
    lifecycle), then the template (shell, tab children, modals), then the styles (shell, shared tab frame, modals).
-->
<template>
  <div class="phone-tuning-shop" v-bng-on-ui-nav:tab_l="event => changePhoneTab(-1, event)" v-bng-on-ui-nav:tab_r="event => changePhoneTab(1, event)">
    <div v-if="loading" class="loading-state">
      <div class="loading-spinner"></div>
      <span>Loading...</span>
    </div>
    <PhoneAppNotice v-else-if="!hasBusiness" title="Tuning Shop is locked" :message="skillLockedMessage" />
    <template v-else>
      <div class="tab-content" v-bng-ui-nav-scroll>
        <transition name="tab-fade" mode="out-in">
          <!-- Dashboard Tab -->
          <DashboardTab
            v-if="activeTab === 'dashboard'"
            key="dashboard"
            :active-job-count="sessionStore.activeJobs.length"
            :working-tech-count="workingTechsCount"
            :account-balance="accountBalance"
            :idle-techs="idleTechs"
            :jobs-in-progress="jobsInProgress"
            :period-change="periodChange"
            :get-tech-name="getTechName"
            @assign-tech="openAssignModalForTech"
          />

          <!-- Jobs Tab -->
          <JobsTab
            v-else-if="activeTab === 'jobs'"
            key="jobs"
            :sub-tab="jobsSubTab"
            :active-jobs="sessionStore.activeJobs"
            :new-jobs="sessionStore.newJobs"
            :get-tech-name="getTechName"
            :get-tech-progress="getTechProgress"
            :get-completion-blocked-message="getCompletionBlockedMessage"
            :can-complete-job="canCompleteJob"
            @select-sub-tab="jobsSubTab = $event"
            @assign-job="openAssignModalForJob"
            @complete="handleComplete"
            @abandon="handleAbandon"
            @accept="handleAccept"
            @decline="handleDecline"
          />

          <!-- Techs Tab -->
          <div v-else-if="activeTab === 'techs'" key="techs" class="tab-panel techs-panel">
            <div v-if="techsStore.hasManager" class="manager-banner">
              <span class="manager-label">Manager</span>
              <span class="manager-status" :class="{ ready: techsStore.managerReadyToAssign }">
                {{ managerStatusText }}
              </span>
            </div>

            <div v-if="techsStore.techs.length === 0" class="empty-state-mini">
              <div class="empty-icon">👷</div>
              <span>No technicians hired</span>
              <small>Unlock via skill tree</small>
            </div>
            <div v-else class="techs-list">
              <div v-for="tech in techsStore.techs" :key="tech.id" class="tech-card" :class="{ working: tech.jobId && !tech.fired, fired: tech.fired }">
                <div class="tech-card-header">
                  <div class="tech-status-dot" :class="{ active: tech.jobId && !tech.fired, fired: tech.fired }"></div>
                  <span class="tech-name">{{ tech.name }}</span>
                  <span v-if="tech.fired" class="tech-fired-badge">Fired</span>
                  <span v-else-if="tech.successRate !== undefined" class="tech-rate">{{ tech.successRate }}%</span>
                </div>

                <div v-if="tech.jobId && !tech.fired" class="tech-working-info">
                  <div class="tech-job-label">{{ getJobLabel(tech.jobId) }}</div>
                  <div class="tech-phase">{{ formatPhase(tech, true) }}</div>
                  <div class="tech-progress-bar">
                    <div class="tech-progress-fill" :style="{ width: `${Math.min(100, Math.round((tech.progress || 0) * 100))}%` }"></div>
                  </div>
                </div>

                <div v-else-if="tech.fired" class="tech-fired-info">
                  <span class="fired-label">Fired</span>
                  <button class="btn-hire-tech" @click.stop="handleHireTech(tech)">
                    Hire Tech
                  </button>
                </div>

                <div v-else class="tech-idle-info">
                  <span class="idle-label">Idle</span>
                  <div class="tech-idle-actions">
                    <button class="btn-assign-tech" :disabled="availableJobsForAssignment.length === 0" @click.stop="openAssignModalForTech(tech)">
                      {{ availableJobsForAssignment.length > 0 ? 'Assign Job' : 'No Jobs' }}
                    </button>
                    <button class="btn-fire-tech" @click.stop="handleFireTech(tech)">
                      Fire
                    </button>
                  </div>
                </div>
              </div>
            </div>
          </div>

          <!-- Finances Tab -->
          <div v-else-if="activeTab === 'finances'" key="finances" class="tab-panel finances-panel">
            <div class="balance-card">
              <span class="balance-label">Account Balance</span>
              <span class="balance-value" :class="{ negative: accountBalance < 0 }">{{ formatCurrency(accountBalance) }}</span>
            </div>

            <div class="chart-section">
              <div class="chart-container">
                <svg class="chart-svg" width="100%" height="100%" viewBox="0 0 320 100" preserveAspectRatio="none">
                  <defs>
                    <linearGradient id="phoneChartGradient" x1="0%" y1="0%" x2="0%" y2="100%">
                      <stop offset="0%" style="stop-color:#F54900;stop-opacity:0.3" />
                      <stop offset="100%" style="stop-color:#F54900;stop-opacity:0" />
                    </linearGradient>
                  </defs>
                  <path :d="chartProjection.area" fill="url(#phoneChartGradient)" class="chart-area" />
                  <path :d="chartProjection.line" fill="none" stroke="#F54900" stroke-width="2" class="chart-line" />
                </svg>
              </div>
              <div class="chart-label">24 Hour History</div>
            </div>

            <div class="finance-stats">
              <div class="finance-stat">
                <span class="finance-stat-label">24h Change</span>
                <span class="finance-stat-value" :class="periodChange >= 0 ? 'positive' : 'negative'">
                  {{ periodChange >= 0 ? '+' : '' }}{{ formatCurrency(periodChange) }}
                </span>
              </div>
              <div class="finance-divider"></div>
              <div class="finance-stat">
                <span class="finance-stat-label">Operating Costs</span>
                <span class="finance-stat-value cost">{{ formatCurrency(operatingCostTotal) }}</span>
              </div>
            </div>
          </div>
        </transition>
      </div>

      <!-- Bottom Navigation -->
      <nav class="bottom-nav">
        <button :class="{ active: activeTab === 'dashboard' }" @click="activeTab = 'dashboard'">
          <svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="2">
            <path d="M3 9l9-7 9 7v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>
            <polyline points="9 22 9 12 15 12 15 22"/>
          </svg>
          <span>Home</span>
        </button>
        <button :class="{ active: activeTab === 'jobs' }" @click="activeTab = 'jobs'">
          <svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="2">
            <rect x="2" y="7" width="20" height="14" rx="2" ry="2"/>
            <path d="M16 21V5a2 2 0 0 0-2-2h-4a2 2 0 0 0-2 2v16"/>
          </svg>
          <span>Jobs</span>
          <span v-if="sessionStore.newJobs.length > 0" class="nav-badge">{{ sessionStore.newJobs.length }}</span>
        </button>
        <button :class="{ active: activeTab === 'techs' }" @click="activeTab = 'techs'">
          <svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="2">
            <path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/>
            <circle cx="9" cy="7" r="4"/>
            <path d="M23 21v-2a4 4 0 0 0-3-3.87"/>
            <path d="M16 3.13a4 4 0 0 1 0 7.75"/>
          </svg>
          <span>Techs</span>
          <span v-if="idleTechs.length > 0" class="nav-badge idle">{{ idleTechs.length }}</span>
        </button>
        <button :class="{ active: activeTab === 'finances' }" @click="activeTab = 'finances'">
          <svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="2">
            <line x1="12" y1="1" x2="12" y2="23"/>
            <path d="M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6"/>
          </svg>
          <span>Finances</span>
        </button>
      </nav>
    </template>

    <!-- Assign Job Modal -->
    <Teleport to="body">
      <transition name="modal-fade">
        <div v-if="showAssignModal" class="modal-overlay" @click.self.stop="closeAssignModal" @mousedown.self.stop="closeAssignModal">
          <div class="modal-content assign-modal" v-bng-scoped-nav="modalScopes.assign" v-bc-modal-focus v-bng-on-ui-nav:back="closeTopLayer">
            <div class="modal-header">
              <h3>{{ assignModalTitle }}</h3>
              <button bng-scoped-nav-autofocus class="modal-close" @click.stop="closeAssignModal" @mousedown.stop>×</button>
            </div>
            <div class="modal-body">
              <div v-if="assignModalMode === 'job' && idleTechs.length === 0" class="modal-empty">
                <p>No idle technicians available</p>
              </div>
              <div v-else-if="assignModalMode === 'tech' && availableJobsForAssignment.length === 0" class="modal-empty">
                <p>No unassigned jobs available</p>
              </div>
              <div v-else class="assign-list">
                <template v-if="assignModalMode === 'job'">
                  <button type="button" v-for="tech in idleTechs" :key="tech.id" class="assign-item" @click.stop="confirmAssignTechToJob(tech.id, selectedJobForAssign.jobId || selectedJobForAssign.id)">
                    <span class="assign-name">{{ tech.name }}</span>
                    <span v-if="tech.successRate !== undefined" class="assign-rate">{{ tech.successRate }}%</span>
                  </button>
                </template>
                <template v-else>
                  <button type="button" v-for="job in availableJobsForAssignment" :key="job.jobId || job.id" class="assign-item job-assign-item" @click.stop="confirmAssignTechToJob(selectedTechForAssign.id, job.jobId || job.id)">
                    <img :src="job.vehicleImage" class="assign-job-img" />
                    <div class="assign-job-info">
                      <span class="assign-job-name">{{ job.vehicleName }}</span>
                      <span class="assign-job-goal">{{ job.goal }}</span>
                    </div>
                    <span class="assign-job-reward">${{ job.reward.toLocaleString() }}</span>
                  </button>
                </template>
              </div>
            </div>
          </div>
        </div>
      </transition>
    </Teleport>

    <!-- Abandon Confirmation Modal -->
    <Teleport to="body">
      <transition name="modal-fade">
        <div v-if="showAbandonModal" class="modal-overlay" @click.self.stop="cancelAbandon" @mousedown.self.stop="cancelAbandon">
          <div class="modal-content" v-bng-scoped-nav="modalScopes.abandon" v-bc-modal-focus v-bng-on-ui-nav:back="closeTopLayer">
            <h2>Abandon Job</h2>
            <p>Are you sure? Penalty: <span class="penalty-text">${{ penaltyCost.toLocaleString() }}</span></p>
            <div class="modal-buttons">
              <button bng-scoped-nav-autofocus class="btn btn-secondary" @click.stop="cancelAbandon" @mousedown.stop>Cancel</button>
              <button class="btn btn-danger" @click.stop="confirmAbandon" @mousedown.stop>Abandon</button>
            </div>
          </div>
        </div>
      </transition>
    </Teleport>
  </div>
</template>

<script setup>


import { nextTab } from '../../utils/controllerTabs.js'
import { vBngScopedNav, vBngOnUiNav } from '@/common/directives'
import { vBcModalFocus } from '../../components/businessComputer/bcModalNav.js'
import { usePhoneAppLayers, usePhoneAppFocus } from './controllerLayers.js'
import { vBngUiNavScroll } from '@/common/directives'
import { ref, computed, onMounted, onUnmounted, watch } from "vue"
import DashboardTab from "../phoneTuningShop/DashboardTab.vue"
import JobsTab from "../phoneTuningShop/JobsTab.vue"
import { useBusinessComputerStore } from "../../stores/businessComputerStore"
import { useBusinessJobsStore } from "../../stores/businessComputer/businessJobsStore.js"
import { useBusinessSessionStore } from "../../stores/businessComputer/businessSessionStore.js"
import { useBusinessTechsStore } from "../../stores/businessComputer/businessTechsStore.js"
import { useBridge, lua } from "@/bridge"
import { safeLua } from "../../utils/safeLua.js"
import { formatCurrency, formatPhase } from "../../utils/businessUtils"
import { getAppLockedMessage } from "../../utils/phoneAppRegistry"
import PhoneAppNotice from "../../components/phone/PhoneAppNotice.vue"
import { buildHistoryPoints, periodChangeOf, chartPathsOf } from "../phoneTuningShop/finances"

usePhoneAppFocus()

function changePhoneTab(direction, event) {
  if (!hasBusiness.value) return true
  event?.stopPropagation()
  const next = nextTab(['dashboard', 'jobs', 'techs', 'finances'].map(id => ({ id })), activeTab.value, direction)
  if (next) activeTab.value = next.id
}


const computerStore = useBusinessComputerStore()
const jobsStore = useBusinessJobsStore()
const sessionStore = useBusinessSessionStore()
const techsStore = useBusinessTechsStore()
const { events } = useBridge()
const skillLockedMessage = computed(() => getAppLockedMessage("tuning-shop"))

const loading = ref(true)
const hasBusiness = ref(false)
const activeTab = ref('dashboard')
const jobsSubTab = ref('active')

const financesData = ref(null)
const accountBalance = computed(() => financesData.value?.account?.balance || 0)
const transactions = computed(() => financesData.value?.transactions || [])
const operatingCosts = computed(() => financesData.value?.operatingCosts || {})
const operatingCostTotal = computed(() => operatingCosts.value.total || 0)

const showAbandonModal = ref(false)
const jobToAbandon = ref(null)
const penaltyCost = computed(() => jobToAbandon.value?.penalty || 0)

const showAssignModal = ref(false)
const { scopes: modalScopes, back: closeTopLayer } = usePhoneAppLayers({
  assign: { open: () => showAssignModal.value, close: () => closeAssignModal() },
  abandon: { open: () => showAbandonModal.value, close: () => cancelAbandon() },
})

const assignModalMode = ref('job')
const selectedJobForAssign = ref(null)
const selectedTechForAssign = ref(null)
const assignModalTitle = computed(() => {
  if (assignModalMode.value === 'job') return 'Assign Technician'
  return `Assign Job to ${selectedTechForAssign.value?.name || 'Tech'}`
})

const workingTechsCount = computed(() => techsStore.techs.filter(t => t.jobId && !t.fired).length)
const idleTechs = computed(() => techsStore.techs.filter(t => !t.jobId && !t.fired))
const jobsInProgress = computed(() => sessionStore.activeJobs)
const availableJobsForAssignment = computed(() => sessionStore.activeJobs.filter(j => !j.techAssigned))

const managerStatusText = computed(() => {
  if (techsStore.managerReadyToAssign) return "Ready"
  const tr = techsStore.managerTimeRemaining
  if (tr && tr > 0) {
    const m = Math.floor(tr / 60)
    const s = Math.floor(tr % 60)
    return m > 0 ? `${m}m ${s}s` : `${s}s`
  }
  return "Waiting"
})

const getTechName = (techId) => {
  const tech = techsStore.techs.find(t => String(t.id) === String(techId))
  return tech?.name || 'Tech'
}

const getTechProgress = (techId) => {
  const tech = techsStore.techs.find(t => String(t.id) === String(techId))
  return tech ? Math.min(100, Math.round((tech.progress || 0) * 100)) : 0
}

const getJobLabel = (jobId) => {
  const job = sessionStore.activeJobs.find(j => String(j.jobId || j.id) === String(jobId))
  return job?.goal || `Job #${jobId}`
}

const jobCompletionStatus = ref({})
const completionStatusGeneration = ref(0)
const jobCompletionStatusRefreshTokens = ref({})

const refreshJobCompletionStatus = async (job, batchGen, batchBusinessId) => {
  const jobId = job?.jobId ?? parseInt(job?.id)
  if (!sessionStore.businessId || !jobId) {
    return
  }

  const businessId = batchBusinessId ?? sessionStore.businessId
  const gen = batchGen ?? completionStatusGeneration.value
  const jobKey = String(jobId)
  const token = (jobCompletionStatusRefreshTokens.value[jobKey] || 0) + 1
  jobCompletionStatusRefreshTokens.value = {
    ...jobCompletionStatusRefreshTokens.value,
    [jobKey]: token
  }

  const commitStatus = (status) => {
    if (String(sessionStore.businessId) !== String(businessId)) return
    if (completionStatusGeneration.value !== gen) return
    if (jobCompletionStatusRefreshTokens.value[jobKey] !== token) return
    jobCompletionStatus.value = {
      ...jobCompletionStatus.value,
      [jobKey]: status
    }
  }

  try {
    const response = await lua.overhaul_career_business_tuningShop_tuningShop.getJobCompletionStatus(businessId, jobId)
    const status = response && typeof response === 'object' ? response : {}
    commitStatus(status)
  } catch (error) {
    commitStatus({ canComplete: false, blockedMessage: null })
  }
}

const refreshAllJobCompletionStatuses = async () => {
  if (!sessionStore.businessId) {
    jobCompletionStatus.value = {}
    jobCompletionStatusRefreshTokens.value = {}
    return
  }
  completionStatusGeneration.value += 1
  const gen = completionStatusGeneration.value
  const businessId = sessionStore.businessId
  jobCompletionStatus.value = {}
  jobCompletionStatusRefreshTokens.value = {}
  const jobs = sessionStore.activeJobs || []
  await Promise.all(jobs.map(job => refreshJobCompletionStatus(job, gen, businessId)))
}

const getCompletionBlockedMessage = (job) => {
  if (!job?.goalTimeMet) {
    return null
  }
  const jobId = String(job?.jobId ?? job?.id ?? '')
  if (!jobId) {
    return null
  }
  if (Object.prototype.hasOwnProperty.call(jobCompletionStatus.value, jobId)) {
    const status = jobCompletionStatus.value[jobId]
    if (!status?.goalTimeMet) {
      return null
    }
    return status.blockedMessage || null
  }
  return job.completionBlockedMessage || null
}

const canCompleteJob = (job) => {
  const jobId = String(job?.jobId ?? job?.id ?? '')
  if (!jobId) {
    return false
  }
  const status = jobCompletionStatus.value[jobId]
  if (status) {
    return status.canComplete === true
  }
  return false
}

const handleAccept = async (job) => {
  await jobsStore.acceptJob(parseInt(job.id))
  if (sessionStore.businessId) await sessionStore.loadBusinessData("tuningShop", sessionStore.businessId)
}

const handleDecline = async (job) => {
  await jobsStore.declineJob(parseInt(job.id))
  if (sessionStore.businessId) await sessionStore.loadBusinessData("tuningShop", sessionStore.businessId)
}

const handleComplete = async (job) => {
  const jobId = job.jobId ?? parseInt(job.id)
  await jobsStore.completeJob(jobId)
  if (sessionStore.businessId) await sessionStore.loadBusinessData("tuningShop", sessionStore.businessId)
}

const handleAbandon = (job) => {
  jobToAbandon.value = job
  showAbandonModal.value = true
}

const confirmAbandon = async () => {
  if (jobToAbandon.value) {
    await jobsStore.abandonJob(parseInt(jobToAbandon.value.id))
    showAbandonModal.value = false
    jobToAbandon.value = null
    if (sessionStore.businessId) await sessionStore.loadBusinessData("tuningShop", sessionStore.businessId)
  }
}

const cancelAbandon = () => {
  showAbandonModal.value = false
  jobToAbandon.value = null
}

const openAssignModalForJob = (job) => {
  assignModalMode.value = 'job'
  selectedJobForAssign.value = job
  selectedTechForAssign.value = null
  showAssignModal.value = true
}

const openAssignModalForTech = (tech) => {
  assignModalMode.value = 'tech'
  selectedTechForAssign.value = tech
  selectedJobForAssign.value = null
  showAssignModal.value = true
}

const closeAssignModal = () => {
  showAssignModal.value = false
  selectedJobForAssign.value = null
  selectedTechForAssign.value = null
}

const confirmAssignTechToJob = async (techId, jobId) => {
  const success = await techsStore.assignTechToJob(techId, jobId)
  if (success) {
    closeAssignModal()
    if (sessionStore.businessId) await sessionStore.loadBusinessData("tuningShop", sessionStore.businessId)
  }
}

const handleFireTech = async (tech) => {
  if (!tech || tech.fired) return
  const success = await techsStore.fireTech(tech.id)
  if (success && sessionStore.businessId) {
    await sessionStore.loadBusinessData("tuningShop", sessionStore.businessId)
  }
}

const handleHireTech = async (tech) => {
  if (!tech || !tech.fired) return
  const success = await techsStore.hireTech(tech.id)
  if (success && sessionStore.businessId) {
    await sessionStore.loadBusinessData("tuningShop", sessionStore.businessId)
  }
}

// The clock is passed as a function so the pure helper reads Date at the same points the view used to.
const nowSeconds = () => Date.now() / 1000
const historyPoints = computed(() => buildHistoryPoints(transactions.value, accountBalance.value, nowSeconds))
const periodChange = computed(() => periodChangeOf(historyPoints.value))
const chartProjection = computed(() => chartPathsOf(historyPoints.value))

// A rejected request leaves the dashboard as it is. The failure is logged once for this message, then ignored.
const requestFinancesData = async () => {
  if (!sessionStore.businessId || !sessionStore.businessType) return
  await safeLua(() => lua.overhaul_career_business_tuningShop_tuningShop.requestFinancesData(sessionStore.businessId), "Request tuning shop finances")
}

const handleFinancesData = (data) => {
  if (!data?.success || String(data.businessId) !== String(sessionStore.businessId)) return
  financesData.value = data.finances
}

const handleTechsUpdated = (data) => {
  if (!sessionStore.businessId || (data?.businessId && String(data.businessId) !== String(sessionStore.businessId))) return
  if (data?.techs && Array.isArray(data.techs)) techsStore.updateTechs(data.techs)
}

watch(() => sessionStore.businessId, () => {
  completionStatusGeneration.value += 1
  jobCompletionStatus.value = {}
  jobCompletionStatusRefreshTokens.value = {}
})

watch(() => sessionStore.activeJobs, () => {
  refreshAllJobCompletionStatuses()
}, { deep: true })

onMounted(async () => {
  loading.value = true
  events.on('businessComputer:onFinancesData', handleFinancesData)
  events.on('businessComputer:onTechsUpdated', handleTechsUpdated)

  try {
    // Check if career is active before calling business manager
    const isCareerActive = await lua.overhaul_career_career.isActive()
    if (!isCareerActive) {
      hasBusiness.value = false
      loading.value = false
      return
    }

    const purchased = await lua.overhaul_career_business_manager.getPurchasedBusinesses("tuningShop")
    let targetBusinessId = null
    if (purchased) {
      for (const [id, owned] of Object.entries(purchased)) {
        if (owned) {
          const level = await lua.overhaul_career_business_skillTree.getNodeProgress(id, "quality-of-life", "shop-app")
          if (level && level > 0) { targetBusinessId = id; break }
        }
      }
    }
    if (targetBusinessId) {
      await sessionStore.loadBusinessData("tuningShop", targetBusinessId)
      await refreshAllJobCompletionStatuses()
      hasBusiness.value = true
      requestFinancesData()
    } else {
      hasBusiness.value = false
    }
  } catch (e) {
    hasBusiness.value = false
  } finally {
    loading.value = false
  }
})

onUnmounted(() => {
  events.off('businessComputer:onFinancesData', handleFinancesData)
  events.off('businessComputer:onTechsUpdated', handleTechsUpdated)
  computerStore.onMenuClosed()
})
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/views/phoneTuningShop/tokens" as *;

.phone-tuning-shop {
  height: 100%;
  display: flex;
  flex-direction: column;
  background: $bg-dark;
  position: relative;
  overflow: hidden;
}

.loading-state {
  flex: 1;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 1em;
  color: $text-secondary;
  padding: 2em;
  text-align: center;
}

.loading-spinner {
  width: 32px;
  height: 32px;
  border: 3px solid $border;
  border-top-color: $accent;
  border-radius: 50%;
  animation: spin 0.8s linear infinite;
}

@keyframes spin { to { transform: rotate(360deg); } }

.tab-content {
  flex: 1;
  overflow: hidden;
  padding-top: 3em;
}

// Shared frame for the tab children. Their root elements carry these classes, so these rules match through the
// parent's scope id; the tab-specific rules live in each child's own style block.
.tab-panel {
  height: 100%;
  overflow-y: auto;
  padding: 0.75em;
  padding-bottom: 5em;
}

.tab-fade-enter-active, .tab-fade-leave-active { transition: opacity 0.15s ease; }
.tab-fade-enter-from, .tab-fade-leave-to { opacity: 0; }

.jobs-panel { padding-top: 0; }

.manager-banner {
  display: flex;
  justify-content: space-between;
  align-items: center;
  background: rgba($accent, 0.1);
  border: 1px solid rgba($accent, 0.2);
  border-radius: 0.6em;
  padding: 0.6em 0.8em;
  margin-bottom: 0.75em;
}

.manager-label {
  font-size: 0.75em;
  font-weight: 600;
  color: $text-secondary;
  text-transform: uppercase;
}

.manager-status {
  font-size: 0.8em;
  font-weight: 600;
  color: $text-muted;

  &.ready { color: $positive; }
}

.techs-list { display: flex; flex-direction: column; gap: 0.6em; }

.empty-state-mini {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  padding: 3em 1em;
  color: $text-muted;
  gap: 0.5em;

  .empty-icon { font-size: 2em; opacity: 0.5; }
  small { font-size: 0.7em; }
}

.tech-card {
  background: $bg-card;
  border: 1px solid $border;
  border-radius: 0.6em;
  padding: 0.75em;

  &.working { border-left: 3px solid $accent; }
  &.fired {
    opacity: 0.6;
    border-left: 3px solid rgba(255, 255, 255, 0.1);
  }
}

.tech-card-header {
  display: flex;
  align-items: center;
  gap: 0.6em;
  margin-bottom: 0.5em;
}

.tech-status-dot {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  background: rgba(255, 255, 255, 0.2);

  &.active {
    background: $accent;
    box-shadow: 0 0 6px rgba($accent, 0.5);
  }

  &.fired {
    background: rgba(255, 255, 255, 0.1);
  }
}

.tech-name {
  flex: 1;
  font-weight: 600;
  font-size: 0.9em;
  color: $text-primary;
}

.tech-rate {
  font-size: 0.75em;
  color: $text-muted;
}

.tech-fired-badge {
  font-size: 0.65em;
  font-weight: 600;
  color: $text-muted;
  background: rgba(255, 255, 255, 0.05);
  padding: 0.2em 0.5em;
  border-radius: 0.25em;
  text-transform: uppercase;
}

.tech-working-info { display: flex; flex-direction: column; gap: 0.35em; }

.tech-job-label {
  font-size: 0.75em;
  color: $accent-light;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.tech-phase {
  font-size: 0.65em;
  color: $text-muted;
  text-transform: uppercase;
}

.tech-progress-bar {
  height: 4px;
  background: rgba(255, 255, 255, 0.1);
  border-radius: 2px;
  overflow: hidden;
}

.tech-progress-fill {
  height: 100%;
  background: linear-gradient(90deg, $accent, $accent-light);
  transition: width 0.1s linear;
}

.tech-idle-info {
  display: flex;
  justify-content: space-between;
  align-items: center;
}

.tech-idle-actions {
  display: flex;
  gap: 0.4em;
  align-items: center;
}

.idle-label {
  font-size: 0.75em;
  color: $text-muted;
}

.btn-assign-tech {
  background: rgba($accent, 0.15);
  border: 1px dashed rgba($accent, 0.4);
  color: $accent;
  padding: 0.4em 0.8em;
  border-radius: 0.35em;
  font-size: 0.75em;
  font-weight: 600;
  cursor: pointer;
  transition: all 0.2s;

  &:hover:not(:disabled) {
    background: rgba($accent, 0.25);
    border-style: solid;
  }

  &:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }
}

.btn-fire-tech {
  background: rgba($negative, 0.15);
  border: 1px solid rgba($negative, 0.3);
  color: $negative;
  padding: 0.4em 0.8em;
  border-radius: 0.35em;
  font-size: 0.75em;
  font-weight: 600;
  cursor: pointer;
  transition: all 0.2s;

  &:hover {
    background: rgba($negative, 0.25);
  }
}

.tech-fired-info {
  display: flex;
  justify-content: space-between;
  align-items: center;
}

.fired-label {
  font-size: 0.75em;
  color: $text-muted;
}

.btn-hire-tech {
  background: rgba($positive, 0.15);
  border: 1px dashed rgba($positive, 0.4);
  color: $positive;
  padding: 0.4em 0.8em;
  border-radius: 0.35em;
  font-size: 0.75em;
  font-weight: 600;
  cursor: pointer;
  transition: all 0.2s;

  &:hover {
    background: rgba($positive, 0.25);
    border-style: solid;
  }
}

/* Modals */
.modal-overlay {
  position: fixed;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  background: rgba(0, 0, 0, 0.8);
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 10000;
}

.modal-content {
  background: rgba(18, 18, 18, 0.98);
  border: 1px solid rgba($accent, 0.3);
  border-radius: 0.75em;
  padding: 1.25em;
  width: 90%;
  max-width: 320px;
  box-shadow: 0 8px 32px rgba(0, 0, 0, 0.5);

  h2 {
    margin: 0 0 0.75em 0;
    font-size: 1.1em;
    color: $text-primary;
  }

  p {
    margin: 0 0 1.25em 0;
    font-size: 0.85em;
    color: $text-secondary;
    line-height: 1.4;
  }

  .penalty-text { color: $accent; font-weight: 600; }
}

.modal-buttons {
  display: flex;
  gap: 0.6em;
  justify-content: flex-end;
}

.btn {
  padding: 0.6em 1em;
  border: none;
  border-radius: 0.35em;
  font-size: 0.8em;
  font-weight: 600;
  cursor: pointer;
  transition: all 0.2s;

  &.btn-secondary {
    background: rgba(255, 255, 255, 0.1);
    color: $text-secondary;
    &:hover { background: rgba(255, 255, 255, 0.15); }
  }

  &.btn-danger {
    background: $negative;
    color: white;
    &:hover { filter: brightness(1.1); }
  }
}

.assign-modal {
  max-height: 70vh;
  display: flex;
  flex-direction: column;
  padding: 0;
}

.modal-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 1em;
  border-bottom: 1px solid $border;

  h3 { margin: 0; font-size: 1em; color: $text-primary; }
}

.modal-close {
  background: none;
  border: none;
  color: $text-muted;
  font-size: 1.5em;
  cursor: pointer;
  padding: 0;
  line-height: 1;

  &:hover { color: $text-primary; }
}

.modal-body {
  padding: 0.75em;
  overflow-y: auto;
  flex: 1;
}

.modal-empty {
  text-align: center;
  padding: 2em 1em;
  color: $text-muted;
}

.assign-list { display: flex; flex-direction: column; gap: 0.5em; }

.assign-item {
  font: inherit; color: inherit; text-align: left; width: 100%;
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0.75em;
  background: rgba(255, 255, 255, 0.03);
  border: 1px solid $border;
  border-radius: 0.5em;
  cursor: pointer;
  transition: all 0.2s;

  &:hover {
    background: rgba($accent, 0.1);
    border-color: rgba($accent, 0.3);
  }
}

.assign-name {
  font-weight: 600;
  color: $text-primary;
}

.assign-rate {
  font-size: 0.8em;
  color: $text-muted;
}

.job-assign-item {
  gap: 0.6em;
}

.assign-job-img {
  width: 50px;
  height: 36px;
  object-fit: cover;
  border-radius: 0.3em;
}

.assign-job-info {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
}

.assign-job-name {
  font-size: 0.8em;
  font-weight: 600;
  color: $text-primary;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.assign-job-goal {
  font-size: 0.7em;
  color: $text-muted;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.assign-job-reward {
  font-weight: 700;
  color: $positive;
  font-size: 0.85em;
  flex-shrink: 0;
}

.modal-fade-enter-active, .modal-fade-leave-active {
  transition: opacity 0.2s ease;
  .modal-content { transition: transform 0.2s ease, opacity 0.2s ease; }
}

.modal-fade-enter-from, .modal-fade-leave-to {
  opacity: 0;
  .modal-content { transform: scale(0.95); opacity: 0; }
}

.balance-card {
  background: linear-gradient(135deg, rgba($accent, 0.15) 0%, rgba($accent, 0.05) 100%);
  border: 1px solid rgba($accent, 0.2);
  border-radius: 0.75em;
  padding: 1.25em;
  text-align: center;
  margin-bottom: 1em;
}

.balance-label {
  display: block;
  font-size: 0.7em;
  color: $text-muted;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  margin-bottom: 0.35em;
}

.balance-value {
  font-size: 1.75em;
  font-weight: 700;
  color: $positive;

  &.negative { color: $negative; }
}

.chart-section {
  background: $bg-card;
  border: 1px solid $border;
  border-radius: 0.6em;
  overflow: hidden;
  margin-bottom: 1em;
}

.chart-container {
  height: 100px;
  background: rgba(0, 0, 0, 0.2);
}

.chart-svg { display: block; }

.chart-label {
  padding: 0.5em;
  text-align: center;
  font-size: 0.65em;
  color: $text-muted;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  border-top: 1px solid $border;
}

.finance-stats {
  display: flex;
  align-items: stretch;
  background: $bg-card;
  border: 1px solid $border;
  border-radius: 0.6em;
  overflow: hidden;
}

.finance-stat {
  flex: 1;
  padding: 0.75em;
  text-align: center;
  display: flex;
  flex-direction: column;
  gap: 0.25em;
}

.finance-stat-label {
  font-size: 0.6em;
  color: $text-muted;
  text-transform: uppercase;
  letter-spacing: 0.03em;
}

.finance-stat-value {
  font-size: 0.95em;
  font-weight: 700;
  color: $text-primary;

  &.positive { color: $positive; }
  &.negative { color: $negative; }
  &.cost { color: $accent; }
}

.finance-divider {
  width: 1px;
  background: $border;
}

.bottom-nav {
  position: absolute;
  bottom: 0;
  left: 0;
  right: 0;
  display: flex;
  background: rgba(8, 8, 8, 0.98);
  border-top: 1px solid $border;
  padding: 0.35em 0.25em 0.5em;
  z-index: 10;

  button {
    flex: 1;
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 0.2em;
    background: transparent;
    border: none;
    color: $text-muted;
    padding: 0.35em;
    cursor: pointer;
    position: relative;
    transition: color 0.2s;

    svg { transition: transform 0.2s; }

    span:not(.nav-badge) { font-size: 0.6em; font-weight: 500; }

    &.active {
      color: $accent;
      svg { transform: scale(1.1); }
    }

    &:hover:not(.active) { color: $text-secondary; }
  }
}

.nav-badge {
  position: absolute;
  top: 0;
  right: 50%;
  transform: translateX(100%);
  background: $accent;
  color: white;
  font-size: 0.55em !important;
  font-weight: 700 !important;
  min-width: 14px;
  height: 14px;
  border-radius: 7px;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 0 4px;

  &.idle { background: #3b82f6; }
}
</style>
