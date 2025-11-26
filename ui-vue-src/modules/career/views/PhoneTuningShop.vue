<template>
  <PhoneWrapper app-name="Tuning Shop" status-font-color="#FFFFFF" status-blend-mode="">
    <div class="phone-tuning-shop">
      <div v-if="loading" class="loading-state">
        <div class="loading-spinner"></div>
        <span>Loading...</span>
      </div>
      <div v-else-if="!hasBusiness" class="error-state">
        <div class="error-icon">🔧</div>
        <span>No Tuning Shop found with App access.</span>
      </div>
      <template v-else>
        <div class="tab-content">
          <transition name="tab-fade" mode="out-in">
            <!-- Dashboard Tab -->
            <div v-if="activeTab === 'dashboard'" key="dashboard" class="tab-panel dashboard-panel">
              <div class="stats-row">
                <div class="stat-card">
                  <span class="stat-value">{{ store.activeJobs.length }}</span>
                  <span class="stat-label">Active</span>
                </div>
                <div class="stat-card">
                  <span class="stat-value">{{ workingTechsCount }}</span>
                  <span class="stat-label">Working</span>
                </div>
                <div class="stat-card accent">
                  <span class="stat-value">{{ formatCurrency(accountBalance) }}</span>
                  <span class="stat-label">Balance</span>
                </div>
              </div>

              <div class="section" v-if="idleTechs.length > 0">
                <div class="section-header alert">
                  <span class="alert-dot"></span>
                  <span>{{ idleTechs.length }} tech{{ idleTechs.length > 1 ? 's' : '' }} idle</span>
                </div>
                <div class="idle-techs-row">
                  <div v-for="tech in idleTechs.slice(0, 3)" :key="tech.id" class="idle-tech-chip" @click="openAssignModalForTech(tech)">
                    {{ tech.name }}
                    <span class="assign-hint">+</span>
                  </div>
                </div>
              </div>

              <div class="section">
                <div class="section-header">
                  <span>Jobs In Progress</span>
                  <span class="section-count">{{ jobsInProgress.length }}</span>
                </div>
                <div v-if="jobsInProgress.length === 0" class="empty-mini">No active jobs</div>
                <div v-else class="jobs-mini-list">
                  <div v-for="job in jobsInProgress.slice(0, 4)" :key="job.id" class="job-mini-card">
                    <img :src="job.vehicleImage" class="job-mini-img" />
                    <div class="job-mini-info">
                      <span class="job-mini-name">{{ job.vehicleName }}</span>
                      <span class="job-mini-goal">{{ job.goal }}</span>
                    </div>
                    <div class="job-mini-status">
                      <span v-if="job.techAssigned" class="tech-badge">{{ getTechName(job.techAssigned) }}</span>
                      <span v-else class="unassigned-badge">Unassigned</span>
                    </div>
                  </div>
                </div>
              </div>

              <div class="section">
                <div class="section-header">
                  <span>24h Performance</span>
                </div>
                <div class="finance-mini">
                  <span class="change-value" :class="periodChange >= 0 ? 'positive' : 'negative'">
                    {{ periodChange >= 0 ? '+' : '' }}{{ formatCurrency(periodChange) }}
                  </span>
                  <span class="change-label">from yesterday</span>
                </div>
              </div>
            </div>

            <!-- Jobs Tab -->
            <div v-if="activeTab === 'jobs'" key="jobs" class="tab-panel jobs-panel">
              <div class="segment-control">
                <button :class="{ active: jobsSubTab === 'active' }" @click="jobsSubTab = 'active'">
                  In Progress ({{ store.activeJobs.length }})
                </button>
                <button :class="{ active: jobsSubTab === 'available' }" @click="jobsSubTab = 'available'">
                  Available ({{ store.newJobs.length }})
                </button>
              </div>

              <div class="jobs-scroll">
                <template v-if="jobsSubTab === 'active'">
                  <div v-if="store.activeJobs.length === 0" class="empty-state-mini">
                    <span>No jobs in progress</span>
                  </div>
                  <div v-else class="jobs-list">
                    <div v-for="job in store.activeJobs" :key="`active-${job.id}`" class="job-card" :class="{ 'has-tech': job.techAssigned }">
                      <div class="job-card-image">
                        <img :src="job.vehicleImage" :alt="job.vehicleName" />
                        <div v-if="job.techAssigned" class="tech-overlay">{{ getTechName(job.techAssigned) }}</div>
                        <div v-else class="tech-overlay unassigned" @click.stop="openAssignModalForJob(job)">
                          <span>+ Assign Tech</span>
                        </div>
                      </div>
                      <div class="job-card-body">
                        <div class="job-card-header">
                          <span class="job-vehicle">{{ job.vehicleYear }} {{ job.vehicleName }}</span>
                          <span class="job-reward">${{ job.reward.toLocaleString() }}</span>
                        </div>
                        <div class="job-goal">{{ job.goal }}</div>
                        <div class="job-progress" v-if="job.techAssigned">
                          <div class="progress-bar">
                            <div class="progress-fill" :style="{ width: `${getTechProgress(job.techAssigned)}%` }"></div>
                          </div>
                        </div>
                        <div class="job-actions" v-if="!job.techAssigned">
                          <button v-if="canCompleteJob(job)" class="btn-complete" @click.stop="handleComplete(job)">Complete</button>
                          <button class="btn-abandon" @click.stop="handleAbandon(job)">✕</button>
                        </div>
                      </div>
                    </div>
                  </div>
                </template>

                <template v-else>
                  <div v-if="store.newJobs.length === 0" class="empty-state-mini">
                    <span>No new jobs available</span>
                  </div>
                  <div v-else class="jobs-list">
                    <div v-for="job in store.newJobs" :key="`new-${job.id}`" class="job-card new-job">
                      <div class="job-card-image">
                        <img :src="job.vehicleImage" :alt="job.vehicleName" />
                        <div v-if="job.expiresInSeconds" class="expiry-badge" :class="{ urgent: job.expiresInSeconds < 60 }">
                          {{ formatExpiry(job.expiresInSeconds) }}
                        </div>
                      </div>
                      <div class="job-card-body">
                        <div class="job-card-header">
                          <span class="job-vehicle">{{ job.vehicleYear }} {{ job.vehicleName }}</span>
                          <span class="job-reward">${{ job.reward.toLocaleString() }}</span>
                        </div>
                        <div class="job-goal">{{ job.goal }}</div>
                        <div class="job-actions">
                          <button class="btn-accept" @click.stop="handleAccept(job)">Accept</button>
                          <button class="btn-decline" @click.stop="handleDecline(job)">✕</button>
                        </div>
                      </div>
                    </div>
                  </div>
                </template>
              </div>
            </div>

            <!-- Techs Tab -->
            <div v-if="activeTab === 'techs'" key="techs" class="tab-panel techs-panel">
              <div v-if="store.hasManager" class="manager-banner">
                <span class="manager-label">Manager</span>
                <span class="manager-status" :class="{ ready: store.managerReadyToAssign }">
                  {{ managerStatusText }}
                </span>
              </div>

              <div v-if="store.techs.length === 0" class="empty-state-mini">
                <div class="empty-icon">👷</div>
                <span>No technicians hired</span>
                <small>Unlock via skill tree</small>
              </div>
              <div v-else class="techs-list">
                <div v-for="tech in store.techs" :key="tech.id" class="tech-card" :class="{ working: tech.jobId }">
                  <div class="tech-card-header">
                    <div class="tech-status-dot" :class="{ active: tech.jobId }"></div>
                    <span class="tech-name">{{ tech.name }}</span>
                    <span v-if="tech.successRate !== undefined" class="tech-rate">{{ tech.successRate }}%</span>
                  </div>
                  
                  <div v-if="tech.jobId" class="tech-working-info">
                    <div class="tech-job-label">{{ getJobLabel(tech.jobId) }}</div>
                    <div class="tech-phase">{{ formatPhase(tech) }}</div>
                    <div class="tech-progress-bar">
                      <div class="tech-progress-fill" :style="{ width: `${Math.min(100, Math.round((tech.progress || 0) * 100))}%` }"></div>
                    </div>
                  </div>
                  
                  <div v-else class="tech-idle-info">
                    <span class="idle-label">Idle</span>
                    <button class="btn-assign-tech" :disabled="availableJobsForAssignment.length === 0" @click.stop="openAssignModalForTech(tech)">
                      {{ availableJobsForAssignment.length > 0 ? 'Assign Job' : 'No Jobs' }}
                    </button>
                  </div>
                </div>
              </div>
            </div>

            <!-- Finances Tab -->
            <div v-if="activeTab === 'finances'" key="finances" class="tab-panel finances-panel">
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
                    <path :d="chartPath" fill="url(#phoneChartGradient)" class="chart-area" />
                    <path :d="chartLinePath" fill="none" stroke="#F54900" stroke-width="2" class="chart-line" />
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
                  <span class="finance-stat-value cost">{{ formatCurrency(operatingCosts.total || 0) }}</span>
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
            <span v-if="store.newJobs.length > 0" class="nav-badge">{{ store.newJobs.length }}</span>
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
            <div class="modal-content assign-modal">
              <div class="modal-header">
                <h3>{{ assignModalTitle }}</h3>
                <button class="modal-close" @click.stop="closeAssignModal" @mousedown.stop>×</button>
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
                    <div v-for="tech in idleTechs" :key="tech.id" class="assign-item" @click.stop="confirmAssignTechToJob(tech.id, selectedJobForAssign.jobId || selectedJobForAssign.id)">
                      <span class="assign-name">{{ tech.name }}</span>
                      <span v-if="tech.successRate !== undefined" class="assign-rate">{{ tech.successRate }}%</span>
                    </div>
                  </template>
                  <template v-else>
                    <div v-for="job in availableJobsForAssignment" :key="job.jobId || job.id" class="assign-item job-assign-item" @click.stop="confirmAssignTechToJob(selectedTechForAssign.id, job.jobId || job.id)">
                      <img :src="job.vehicleImage" class="assign-job-img" />
                      <div class="assign-job-info">
                        <span class="assign-job-name">{{ job.vehicleName }}</span>
                        <span class="assign-job-goal">{{ job.goal }}</span>
                      </div>
                      <span class="assign-job-reward">${{ job.reward.toLocaleString() }}</span>
                    </div>
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
            <div class="modal-content">
              <h2>Abandon Job</h2>
              <p>Are you sure? Penalty: <span class="penalty-text">${{ penaltyCost.toLocaleString() }}</span></p>
              <div class="modal-buttons">
                <button class="btn btn-secondary" @click.stop="cancelAbandon" @mousedown.stop>Cancel</button>
                <button class="btn btn-danger" @click.stop="confirmAbandon" @mousedown.stop>Abandon</button>
              </div>
            </div>
          </div>
        </transition>
      </Teleport>
    </div>
  </PhoneWrapper>
</template>

<script setup>
import { ref, computed, onMounted, onUnmounted, watch } from "vue"
import PhoneWrapper from "./PhoneWrapper.vue"
import { useBusinessComputerStore } from "../stores/businessComputerStore"
import { useBridge, lua } from "@/bridge"

const store = useBusinessComputerStore()
const { events } = useBridge()

const loading = ref(true)
const hasBusiness = ref(false)
const activeTab = ref('dashboard')
const jobsSubTab = ref('active')

const financesData = ref(null)
const accountBalance = computed(() => financesData.value?.account?.balance || 0)
const transactions = computed(() => financesData.value?.transactions || [])
const operatingCosts = computed(() => financesData.value?.operatingCosts || {})

const showAbandonModal = ref(false)
const jobToAbandon = ref(null)
const penaltyCost = computed(() => jobToAbandon.value?.penalty || 0)

const showAssignModal = ref(false)
const assignModalMode = ref('job')
const selectedJobForAssign = ref(null)
const selectedTechForAssign = ref(null)
const assignModalTitle = computed(() => {
  if (assignModalMode.value === 'job') return 'Assign Technician'
  return `Assign Job to ${selectedTechForAssign.value?.name || 'Tech'}`
})

const workingTechsCount = computed(() => store.techs.filter(t => t.jobId).length)
const idleTechs = computed(() => store.techs.filter(t => !t.jobId))
const jobsInProgress = computed(() => store.activeJobs)
const availableJobsForAssignment = computed(() => store.activeJobs.filter(j => !j.techAssigned))

const managerStatusText = computed(() => {
  if (store.managerReadyToAssign) return "Ready"
  const tr = store.managerTimeRemaining
  if (tr && tr > 0) {
    const m = Math.floor(tr / 60)
    const s = Math.floor(tr % 60)
    return m > 0 ? `${m}m ${s}s` : `${s}s`
  }
  return "Waiting"
})

const getTechName = (techId) => {
  const tech = store.techs.find(t => String(t.id) === String(techId))
  return tech?.name || 'Tech'
}

const getTechProgress = (techId) => {
  const tech = store.techs.find(t => String(t.id) === String(techId))
  return tech ? Math.min(100, Math.round((tech.progress || 0) * 100)) : 0
}

const getJobLabel = (jobId) => {
  const job = store.activeJobs.find(j => String(j.jobId || j.id) === String(jobId))
  return job?.goal || `Job #${jobId}`
}

const formatPhase = (tech) => {
  const map = { baseline: "Baseline", validation: "Validating", build: "Building", update: "Tuning", cooldown: "Cooldown", completed: "Done", failed: "Failed" }
  return tech.label || map[tech.phase] || tech.action || "Working"
}

const formatExpiry = (seconds) => {
  if (seconds <= 0) return "Expired"
  if (seconds < 60) return `${Math.round(seconds)}s`
  return `${Math.floor(seconds / 60)}m`
}

const formatCurrency = (amount) => {
  if (amount === null || amount === undefined) return '$0'
  const num = Math.abs(amount)
  const sign = amount < 0 ? '-' : ''
  if (num >= 1000000) return sign + '$' + (num / 1000000).toFixed(1) + 'M'
  if (num >= 1000) return sign + '$' + (num / 1000).toFixed(1) + 'k'
  return sign + '$' + Math.floor(num).toLocaleString()
}

const canCompleteJob = (job) => {
  if (!job.currentTime || !job.goalTime) return false
  return job.currentTime <= job.goalTime
}

const handleAccept = async (job) => {
  await store.acceptJob(parseInt(job.id))
  if (store.businessId) await store.loadBusinessData("tuningShop", store.businessId)
}

const handleDecline = async (job) => {
  await store.declineJob(parseInt(job.id))
  if (store.businessId) await store.loadBusinessData("tuningShop", store.businessId)
}

const handleComplete = async (job) => {
  const jobId = job.jobId ?? parseInt(job.id)
  await store.completeJob(jobId)
  if (store.businessId) await store.loadBusinessData("tuningShop", store.businessId)
}

const handleAbandon = (job) => {
  jobToAbandon.value = job
  showAbandonModal.value = true
}

const confirmAbandon = async () => {
  if (jobToAbandon.value) {
    await store.abandonJob(parseInt(jobToAbandon.value.id))
    showAbandonModal.value = false
    jobToAbandon.value = null
    if (store.businessId) await store.loadBusinessData("tuningShop", store.businessId)
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
  const success = await store.assignTechToJob(techId, jobId)
  if (success) {
    closeAssignModal()
    if (store.businessId) await store.loadBusinessData("tuningShop", store.businessId)
  }
}

const chartWidth = 320
const chartHeight = 100
const chartPadding = 8

const filteredHistoryPoints = computed(() => {
  if (!transactions.value || transactions.value.length === 0) {
    return [{ balance: accountBalance.value, timestamp: Date.now() / 1000 }]
  }
  const sorted = [...transactions.value].sort((a, b) => (a.timestamp || 0) - (b.timestamp || 0))
  let initial = accountBalance.value
  for (let i = sorted.length - 1; i >= 0; i--) initial -= (sorted[i].amount || 0)
  let running = initial
  const points = [{ balance: initial, timestamp: sorted[0]?.timestamp || Date.now() / 1000 }]
  for (const t of sorted) {
    running += (t.amount || 0)
    points.push({ balance: running, timestamp: t.timestamp })
  }
  points.push({ balance: accountBalance.value, timestamp: Date.now() / 1000 })
  const cutoff = Date.now() / 1000 - 86400
  return points.filter(p => p.timestamp >= cutoff)
})

const periodChange = computed(() => {
  if (filteredHistoryPoints.value.length === 0) return 0
  const first = filteredHistoryPoints.value[0].balance
  const last = filteredHistoryPoints.value[filteredHistoryPoints.value.length - 1].balance
  return last - first
})

const chartData = computed(() => {
  const pts = filteredHistoryPoints.value
  if (pts.length === 0) return []
  const first = pts[0].timestamp, last = pts[pts.length - 1].timestamp
  const timeRange = last - first || 1
  const balances = pts.map(p => p.balance)
  const min = Math.min(...balances), max = Math.max(...balances)
  const range = max - min || 1
  return pts.map(p => ({
    x: ((p.timestamp - first) / timeRange) * chartWidth,
    y: chartHeight - chartPadding - (((p.balance - min) / range) * (chartHeight - 2 * chartPadding)) - chartPadding
  }))
})

const chartPath = computed(() => {
  if (chartData.value.length === 0) return ''
  const pts = chartData.value
  let path = `M ${pts[0].x} ${chartHeight} L ${pts[0].x} ${pts[0].y}`
  for (let i = 1; i < pts.length; i++) path += ` L ${pts[i].x} ${pts[i].y}`
  path += ` L ${pts[pts.length - 1].x} ${chartHeight} Z`
  return path
})

const chartLinePath = computed(() => {
  if (chartData.value.length === 0) return ''
  const pts = chartData.value
  let path = `M ${pts[0].x} ${pts[0].y}`
  for (let i = 1; i < pts.length; i++) path += ` L ${pts[i].x} ${pts[i].y}`
  return path
})

const requestFinancesData = async () => {
  if (!store.businessId || !store.businessType) return
  try {
    await lua.career_modules_business_businessComputer.requestFinancesData(store.businessType, store.businessId)
  } catch (e) {}
}

const handleFinancesData = (data) => {
  if (!data?.success || String(data.businessId) !== String(store.businessId)) return
  financesData.value = data.finances
}

const handleTechsUpdated = (data) => {
  if (!store.businessId || (data?.businessId && String(data.businessId) !== String(store.businessId))) return
  if (data?.techs && Array.isArray(data.techs)) store.updateTechs(data.techs)
}

onMounted(async () => {
  loading.value = true
  events.on('businessComputer:onFinancesData', handleFinancesData)
  events.on('businessComputer:onTechsUpdated', handleTechsUpdated)
  
  try {
    const purchased = await lua.career_modules_business_businessManager.getPurchasedBusinesses("tuningShop")
    let targetBusinessId = null
    if (purchased) {
      for (const [id, owned] of Object.entries(purchased)) {
        if (owned) {
          const level = await lua.career_modules_business_businessSkillTree.getNodeProgress(id, "quality-of-life", "shop-app")
          if (level && level > 0) { targetBusinessId = id; break }
        }
      }
    }
    if (targetBusinessId) {
      await store.loadBusinessData("tuningShop", targetBusinessId)
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
  store.onMenuClosed()
})
</script>

<style scoped lang="scss">
$accent: #F54900;
$accent-light: #ff6a1a;
$bg-dark: rgba(12, 12, 12, 0.98);
$bg-card: rgba(22, 22, 22, 0.95);
$bg-card-hover: rgba(30, 30, 30, 0.95);
$text-primary: #ffffff;
$text-secondary: rgba(255, 255, 255, 0.6);
$text-muted: rgba(255, 255, 255, 0.4);
$border: rgba(255, 255, 255, 0.08);
$positive: #22c55e;
$negative: #ef4444;

.phone-tuning-shop {
  height: 100%;
  display: flex;
  flex-direction: column;
  background: $bg-dark;
  position: relative;
  overflow: hidden;
}

.loading-state, .error-state {
  flex: 1;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 1rem;
  color: $text-secondary;
  padding: 2rem;
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

.error-icon { font-size: 2.5rem; opacity: 0.5; }

.tab-content {
  flex: 1;
  overflow: hidden;
  padding-top: 3rem;
}

.tab-panel {
  height: 100%;
  overflow-y: auto;
  padding: 0.75rem;
  padding-bottom: 5rem;
  &::-webkit-scrollbar { display: none; }
  -ms-overflow-style: none;
  scrollbar-width: none;
}

.tab-fade-enter-active, .tab-fade-leave-active { transition: opacity 0.15s ease; }
.tab-fade-enter-from, .tab-fade-leave-to { opacity: 0; }

/* Dashboard */
.stats-row {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 0.5rem;
  margin-bottom: 1rem;
}

.stat-card {
  background: $bg-card;
  border: 1px solid $border;
  border-radius: 0.75rem;
  padding: 0.75rem 0.5rem;
  text-align: center;
  display: flex;
  flex-direction: column;
  gap: 0.25rem;
  
  &.accent {
    border-color: rgba($accent, 0.3);
    background: rgba($accent, 0.08);
    .stat-value { color: $accent; }
  }
}

.stat-value { font-size: 1.1rem; font-weight: 700; color: $text-primary; }
.stat-label { font-size: 0.65rem; color: $text-muted; text-transform: uppercase; letter-spacing: 0.05em; }

.section { margin-bottom: 1rem; }
.section-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 0.5rem;
  font-size: 0.8rem;
  font-weight: 600;
  color: $text-secondary;
  
  &.alert { color: $accent; }
}

.alert-dot {
  width: 6px;
  height: 6px;
  background: $accent;
  border-radius: 50%;
  margin-right: 0.5rem;
  animation: pulse 1.5s infinite;
}

@keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.4; } }

.section-count {
  background: rgba(255, 255, 255, 0.1);
  padding: 0.15rem 0.5rem;
  border-radius: 0.25rem;
  font-size: 0.7rem;
}

.idle-techs-row {
  display: flex;
  gap: 0.5rem;
  flex-wrap: wrap;
}

.idle-tech-chip {
  background: rgba($accent, 0.15);
  border: 1px solid rgba($accent, 0.3);
  color: $accent-light;
  padding: 0.4rem 0.75rem;
  border-radius: 2rem;
  font-size: 0.75rem;
  font-weight: 600;
  cursor: pointer;
  display: flex;
  align-items: center;
  gap: 0.35rem;
  transition: all 0.2s;
  
  &:hover { background: rgba($accent, 0.25); }
  .assign-hint { opacity: 0.7; }
}

.empty-mini {
  color: $text-muted;
  font-size: 0.8rem;
  text-align: center;
  padding: 1rem;
  font-style: italic;
}

.jobs-mini-list { display: flex; flex-direction: column; gap: 0.5rem; }

.job-mini-card {
  display: flex;
  align-items: center;
  gap: 0.6rem;
  background: $bg-card;
  border: 1px solid $border;
  border-radius: 0.6rem;
  padding: 0.5rem;
}

.job-mini-img {
  width: 44px;
  height: 32px;
  object-fit: cover;
  border-radius: 0.3rem;
}

.job-mini-info {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
}

.job-mini-name {
  font-size: 0.75rem;
  font-weight: 600;
  color: $text-primary;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.job-mini-goal {
  font-size: 0.65rem;
  color: $text-muted;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.job-mini-status { flex-shrink: 0; }

.tech-badge, .unassigned-badge {
  font-size: 0.6rem;
  font-weight: 600;
  padding: 0.2rem 0.5rem;
  border-radius: 0.25rem;
  text-transform: uppercase;
}

.tech-badge { background: rgba($accent, 0.2); color: $accent-light; }
.unassigned-badge { background: rgba(255, 255, 255, 0.1); color: $text-muted; }

.finance-mini {
  background: $bg-card;
  border: 1px solid $border;
  border-radius: 0.6rem;
  padding: 0.75rem;
  display: flex;
  align-items: baseline;
  gap: 0.5rem;
}

.change-value {
  font-size: 1.1rem;
  font-weight: 700;
  &.positive { color: $positive; }
  &.negative { color: $negative; }
}

.change-label { font-size: 0.7rem; color: $text-muted; }

/* Jobs Tab */
.jobs-panel { padding-top: 0; }

.segment-control {
  display: flex;
  background: rgba(0, 0, 0, 0.3);
  border-radius: 0.5rem;
  padding: 0.25rem;
  margin: 0.75rem 0.75rem 0.75rem 0.75rem;
  position: sticky;
  top: 0;
  z-index: 5;
  
  button {
    flex: 1;
    background: transparent;
    border: none;
    color: $text-secondary;
    padding: 0.5rem;
    font-size: 0.75rem;
    font-weight: 600;
    border-radius: 0.35rem;
    cursor: pointer;
    transition: all 0.2s;
    
    &.active {
      background: rgba(255, 255, 255, 0.1);
      color: $text-primary;
    }
  }
}

.jobs-scroll { padding: 0 0.75rem; }
.jobs-list { display: flex; flex-direction: column; gap: 0.75rem; }

.empty-state-mini {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  padding: 3rem 1rem;
  color: $text-muted;
  gap: 0.5rem;
  
  .empty-icon { font-size: 2rem; opacity: 0.5; }
  small { font-size: 0.7rem; }
}

.job-card {
  background: $bg-card;
  border: 1px solid $border;
  border-radius: 0.75rem;
  overflow: hidden;
  transition: border-color 0.2s;
  
  &.has-tech { border-left: 3px solid $accent; }
  &.new-job { border-left: 3px solid #3b82f6; }
}

.job-card-image {
  position: relative;
  height: 80px;
  
  img { width: 100%; height: 100%; object-fit: cover; }
}

.tech-overlay {
  position: absolute;
  bottom: 0;
  left: 0;
  right: 0;
  padding: 0.35rem 0.6rem;
  background: linear-gradient(transparent, rgba(0, 0, 0, 0.85));
  font-size: 0.7rem;
  font-weight: 600;
  color: $accent-light;
  
  &.unassigned {
    background: rgba($accent, 0.9);
    color: white;
    cursor: pointer;
    text-align: center;
    padding: 0.5rem;
    transition: background 0.2s;
    
    &:hover { background: $accent; }
  }
}

.expiry-badge {
  position: absolute;
  top: 0.4rem;
  right: 0.4rem;
  background: rgba(0, 0, 0, 0.75);
  color: white;
  font-size: 0.65rem;
  font-weight: 600;
  padding: 0.2rem 0.5rem;
  border-radius: 0.25rem;
  
  &.urgent { background: $negative; }
}

.job-card-body { padding: 0.6rem; }

.job-card-header {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  margin-bottom: 0.25rem;
}

.job-vehicle {
  font-size: 0.8rem;
  font-weight: 600;
  color: $text-primary;
  flex: 1;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  margin-right: 0.5rem;
}

.job-reward {
  font-size: 0.85rem;
  font-weight: 700;
  color: $positive;
  flex-shrink: 0;
}

.job-goal {
  font-size: 0.7rem;
  color: $text-secondary;
  margin-bottom: 0.5rem;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.job-progress { margin-bottom: 0.35rem; }

.progress-bar {
  height: 4px;
  background: rgba(255, 255, 255, 0.1);
  border-radius: 2px;
  overflow: hidden;
}

.progress-fill {
  height: 100%;
  background: $accent;
  transition: width 0.3s;
}

.job-actions {
  display: flex;
  gap: 0.5rem;
  justify-content: flex-end;
}

.btn-accept, .btn-complete {
  background: $positive;
  color: white;
  border: none;
  padding: 0.4rem 1rem;
  border-radius: 0.35rem;
  font-size: 0.75rem;
  font-weight: 600;
  cursor: pointer;
  transition: all 0.2s;
  
  &:hover { filter: brightness(1.1); }
}

.btn-decline, .btn-abandon {
  background: rgba($negative, 0.15);
  color: $negative;
  border: none;
  width: 28px;
  height: 28px;
  border-radius: 0.35rem;
  font-size: 0.9rem;
  cursor: pointer;
  display: flex;
  align-items: center;
  justify-content: center;
  transition: all 0.2s;
  
  &:hover { background: rgba($negative, 0.25); }
}

/* Techs Tab */
.manager-banner {
  display: flex;
  justify-content: space-between;
  align-items: center;
  background: rgba($accent, 0.1);
  border: 1px solid rgba($accent, 0.2);
  border-radius: 0.6rem;
  padding: 0.6rem 0.8rem;
  margin-bottom: 0.75rem;
}

.manager-label {
  font-size: 0.75rem;
  font-weight: 600;
  color: $text-secondary;
  text-transform: uppercase;
}

.manager-status {
  font-size: 0.8rem;
  font-weight: 600;
  color: $text-muted;
  
  &.ready { color: $positive; }
}

.techs-list { display: flex; flex-direction: column; gap: 0.6rem; }

.tech-card {
  background: $bg-card;
  border: 1px solid $border;
  border-radius: 0.6rem;
  padding: 0.75rem;
  
  &.working { border-left: 3px solid $accent; }
}

.tech-card-header {
  display: flex;
  align-items: center;
  gap: 0.6rem;
  margin-bottom: 0.5rem;
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
}

.tech-name {
  flex: 1;
  font-weight: 600;
  font-size: 0.9rem;
  color: $text-primary;
}

.tech-rate {
  font-size: 0.75rem;
  color: $text-muted;
}

.tech-working-info { display: flex; flex-direction: column; gap: 0.35rem; }

.tech-job-label {
  font-size: 0.75rem;
  color: $accent-light;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.tech-phase {
  font-size: 0.65rem;
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

.idle-label {
  font-size: 0.75rem;
  color: $text-muted;
}

.btn-assign-tech {
  background: rgba($accent, 0.15);
  border: 1px dashed rgba($accent, 0.4);
  color: $accent;
  padding: 0.4rem 0.8rem;
  border-radius: 0.35rem;
  font-size: 0.75rem;
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

/* Finances Tab */
.balance-card {
  background: linear-gradient(135deg, rgba($accent, 0.15) 0%, rgba($accent, 0.05) 100%);
  border: 1px solid rgba($accent, 0.2);
  border-radius: 0.75rem;
  padding: 1.25rem;
  text-align: center;
  margin-bottom: 1rem;
}

.balance-label {
  display: block;
  font-size: 0.7rem;
  color: $text-muted;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  margin-bottom: 0.35rem;
}

.balance-value {
  font-size: 1.75rem;
  font-weight: 700;
  color: $positive;
  
  &.negative { color: $negative; }
}

.chart-section {
  background: $bg-card;
  border: 1px solid $border;
  border-radius: 0.6rem;
  overflow: hidden;
  margin-bottom: 1rem;
}

.chart-container {
  height: 100px;
  background: rgba(0, 0, 0, 0.2);
}

.chart-svg { display: block; }

.chart-label {
  padding: 0.5rem;
  text-align: center;
  font-size: 0.65rem;
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
  border-radius: 0.6rem;
  overflow: hidden;
}

.finance-stat {
  flex: 1;
  padding: 0.75rem;
  text-align: center;
  display: flex;
  flex-direction: column;
  gap: 0.25rem;
}

.finance-stat-label {
  font-size: 0.6rem;
  color: $text-muted;
  text-transform: uppercase;
  letter-spacing: 0.03em;
}

.finance-stat-value {
  font-size: 0.95rem;
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

/* Bottom Navigation */
.bottom-nav {
  position: absolute;
  bottom: 0;
  left: 0;
  right: 0;
  display: flex;
  background: rgba(8, 8, 8, 0.98);
  border-top: 1px solid $border;
  padding: 0.35rem 0.25rem 0.5rem;
  z-index: 10;
  
  button {
    flex: 1;
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 0.2rem;
    background: transparent;
    border: none;
    color: $text-muted;
    padding: 0.35rem;
    cursor: pointer;
    position: relative;
    transition: color 0.2s;
    
    svg { transition: transform 0.2s; }
    
    span:not(.nav-badge) { font-size: 0.6rem; font-weight: 500; }
    
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
  font-size: 0.55rem !important;
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
  backdrop-filter: blur(4px);
}

.modal-content {
  background: rgba(18, 18, 18, 0.98);
  border: 1px solid rgba($accent, 0.3);
  border-radius: 0.75rem;
  padding: 1.25rem;
  width: 90%;
  max-width: 320px;
  box-shadow: 0 8px 32px rgba(0, 0, 0, 0.5);
  
  h2 {
    margin: 0 0 0.75rem 0;
    font-size: 1.1rem;
    color: $text-primary;
  }
  
  p {
    margin: 0 0 1.25rem 0;
    font-size: 0.85rem;
    color: $text-secondary;
    line-height: 1.4;
  }
  
  .penalty-text { color: $accent; font-weight: 600; }
}

.modal-buttons {
  display: flex;
  gap: 0.6rem;
  justify-content: flex-end;
}

.btn {
  padding: 0.6rem 1rem;
  border: none;
  border-radius: 0.35rem;
  font-size: 0.8rem;
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
  padding: 1rem;
  border-bottom: 1px solid $border;
  
  h3 { margin: 0; font-size: 1rem; color: $text-primary; }
}

.modal-close {
  background: none;
  border: none;
  color: $text-muted;
  font-size: 1.5rem;
  cursor: pointer;
  padding: 0;
  line-height: 1;
  
  &:hover { color: $text-primary; }
}

.modal-body {
  padding: 0.75rem;
  overflow-y: auto;
  flex: 1;
}

.modal-empty {
  text-align: center;
  padding: 2rem 1rem;
  color: $text-muted;
}

.assign-list { display: flex; flex-direction: column; gap: 0.5rem; }

.assign-item {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0.75rem;
  background: rgba(255, 255, 255, 0.03);
  border: 1px solid $border;
  border-radius: 0.5rem;
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
  font-size: 0.8rem;
  color: $text-muted;
}

.job-assign-item {
  gap: 0.6rem;
}

.assign-job-img {
  width: 50px;
  height: 36px;
  object-fit: cover;
  border-radius: 0.3rem;
}

.assign-job-info {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
}

.assign-job-name {
  font-size: 0.8rem;
  font-weight: 600;
  color: $text-primary;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.assign-job-goal {
  font-size: 0.7rem;
  color: $text-muted;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.assign-job-reward {
  font-weight: 700;
  color: $positive;
  font-size: 0.85rem;
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
</style>
