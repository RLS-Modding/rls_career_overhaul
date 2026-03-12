<template>
  <PhoneWrapper app-name="FRE Contracts">
    <div class="fre-app">
      <div v-if="loading" class="empty">Loading FRE contracts...</div>
      <div v-else-if="!careerActive" class="empty">Start Career mode to use FRE Contracts.</div>
      <template v-else>
        <div class="toolbar">
          <BngDropdown
            v-model="selectedDiscipline"
            :items="disciplineOptions"
            class="discipline-select"
          />
          <button class="sync-btn" :disabled="actionBusy" @click="refreshState">Sync Now</button>
        </div>

        <div class="sync-meta">
          <span>Auto-sync every 5m</span>
          <span>Last sync {{ lastSyncLabel }}</span>
        </div>

        <div class="discipline-summary" v-if="selectedDisciplineInfo">
          <div class="summary-top">
            <div class="summary-title">{{ selectedDisciplineInfo.label }}</div>
            <div class="summary-level">L{{ selectedDisciplineInfo.level }}</div>
          </div>
          <div class="summary-grid">
            <div class="summary-cell">
              <div class="summary-key">Contracts</div>
              <div class="summary-value">{{ selectedDisciplineInfo.contractSlotsUsed }}/{{ selectedDisciplineInfo.contractSlots }}</div>
            </div>
            <div class="summary-cell">
              <div class="summary-key">Contract Offers</div>
              <div class="summary-value">{{ selectedDisciplineInfo.contractOfferCap }}</div>
            </div>
            <div class="summary-cell">
              <div class="summary-key">Sponsors</div>
              <div class="summary-value">{{ selectedDisciplineInfo.sponsorSlotsUsed }}/{{ selectedDisciplineInfo.sponsorSlots }}</div>
            </div>
            <div class="summary-cell">
              <div class="summary-key">Sponsor Offers</div>
              <div class="summary-value">{{ selectedDisciplineInfo.sponsorOfferCap }}</div>
            </div>
          </div>
          <div class="summary-bonus">Bonus: Money {{ formatPercent(selectedDisciplineInfo.sponsorBonusMoney) }} | XP {{ formatPercent(selectedDisciplineInfo.sponsorBonusXp) }}</div>
          <div v-if="!selectedDisciplineInfo.contractsUnlocked" class="summary-line muted">Contracts unlock at level {{ selectedDisciplineInfo.contractUnlockLevel }}</div>
          <div v-if="!selectedDisciplineInfo.sponsorsUnlocked" class="summary-line muted">Sponsors unlock at level {{ selectedDisciplineInfo.sponsorUnlockLevel }}</div>
        </div>

        <div class="tabs">
          <button :class="{ active: tab === 'contracts' }" @click="tab = 'contracts'">Contracts</button>
          <button :class="{ active: tab === 'sponsors' }" @click="tab = 'sponsors'">Sponsors</button>
        </div>

        <div v-if="errorMessage" class="error">{{ errorMessage }}</div>

        <div v-if="tab === 'contracts'" class="panel">
          <div class="section">Active</div>
          <div v-if="filteredActiveContracts.length === 0" class="empty small">No active contracts.</div>
          <div v-for="contract in filteredActiveContracts" :key="contract.id" class="card">
            <div class="title">{{ disciplineLabel(contract.disciplineId) }} - {{ tierLabel(contract.tier) }}</div>
            <div class="line contract-focus">{{ contractFocusLabel(contract) }}</div>
            <div class="contract-metrics">
              <div class="metric">
                <span class="metric-key">Target</span>
                <span class="metric-value">{{ formatTime(contract.targetTime) }}</span>
              </div>
              <div class="metric">
                <span class="metric-key">Objective</span>
                <span class="metric-value">{{ objectiveStatusLabel(contract) }}</span>
              </div>
              <div class="metric">
                <span class="metric-key">Reward</span>
                <span class="metric-value">${{ formatMoney(contract.rewardMoney) }} + {{ contract.rewardXp }} XP</span>
              </div>
              <div class="metric">
                <span class="metric-key">Expires</span>
                <span class="metric-value">{{ formatMinutes(displayRemaining(contract.minutesRemaining)) }}</span>
              </div>
            </div>
            <button class="danger" :disabled="actionBusy" @click="abandonContract(contract.id)">Abandon</button>
          </div>

          <div class="section">Available</div>
          <div v-if="selectedDisciplineInfo && !selectedDisciplineInfo.contractsUnlocked" class="empty small">
            Contracts unlock at level {{ selectedDisciplineInfo.contractUnlockLevel }}.
          </div>
          <div v-else-if="filteredAvailableContracts.length === 0" class="empty small">No offers available.</div>
          <div v-for="contract in filteredAvailableContracts" :key="contract.id" class="card">
            <div class="title">{{ disciplineLabel(contract.disciplineId) }} - {{ tierLabel(contract.tier) }}</div>
            <div class="line contract-focus">{{ contractFocusLabel(contract) }}</div>
            <div class="contract-metrics">
              <div class="metric">
                <span class="metric-key">Target</span>
                <span class="metric-value">{{ formatTime(contract.targetTime) }}</span>
              </div>
              <div class="metric">
                <span class="metric-key">Objective</span>
                <span class="metric-value">{{ objectiveStatusLabel(contract) }}</span>
              </div>
              <div class="metric">
                <span class="metric-key">Reward</span>
                <span class="metric-value">${{ formatMoney(contract.rewardMoney) }} + {{ contract.rewardXp }} XP</span>
              </div>
              <div class="metric">
                <span class="metric-key">Expires</span>
                <span class="metric-value">{{ formatMinutes(displayRemaining(contract.minutesRemaining)) }}</span>
              </div>
            </div>
            <button :disabled="actionBusy || !canAcceptContract(contract)" @click="acceptContract(contract.id)">
              {{ canAcceptContract(contract) ? 'Accept' : 'Slots Full' }}
            </button>
          </div>
        </div>

        <div v-else class="panel">
          <div class="section">Active</div>
          <div v-if="filteredActiveSponsors.length === 0" class="empty small">No active sponsors.</div>
          <div v-for="sponsor in filteredActiveSponsors" :key="sponsor.id" class="card">
            <div class="title">{{ disciplineLabel(sponsor.disciplineId) }} - {{ sponsor.name }}</div>
            <div class="line">{{ tierLabel(sponsor.tier) }} | {{ bonusLabel(sponsor) }}</div>
            <div class="line">Requirement: {{ sponsorRequirementLabel(sponsor) }}</div>
            <div class="line" :class="sponsorStatusClass(sponsor)">Status: {{ sponsorStatusLabel(sponsor) }}</div>
            <div class="line">Upkeep in {{ formatMinutes(displayRemaining(sponsor.checkMinutesRemaining)) }}</div>
            <div class="warning" v-if="sponsor.warningIssued">
              Warning active. Complete an event in {{ formatMinutes(displayRemaining(sponsor.checkMinutesRemaining)) }}.
              <button :disabled="actionBusy" @click="acknowledgeSponsorWarning(sponsor.id)">Acknowledge</button>
            </div>
            <button class="danger" :disabled="actionBusy" @click="dropSponsor(sponsor.id)">Drop Sponsor</button>
          </div>

          <div class="section">Available</div>
          <div v-if="selectedDisciplineInfo && !selectedDisciplineInfo.sponsorsUnlocked" class="empty small">
            Sponsors unlock at level {{ selectedDisciplineInfo.sponsorUnlockLevel }}.
          </div>
          <div v-else-if="filteredAvailableSponsors.length === 0" class="empty small">No offers available.</div>
          <div v-for="sponsor in filteredAvailableSponsors" :key="sponsor.id" class="card">
            <div class="title">{{ disciplineLabel(sponsor.disciplineId) }} - {{ sponsor.name }}</div>
            <div class="line">{{ tierLabel(sponsor.tier) }} | {{ bonusLabel(sponsor) }}</div>
            <div class="line">Requirement: {{ sponsorRequirementLabel(sponsor) }}</div>
            <div class="line">Offer expires in {{ formatMinutes(displayRemaining(sponsor.minutesRemaining)) }}</div>
            <button :disabled="actionBusy || !canSignSponsor(sponsor)" @click="signSponsor(sponsor.id)">
              {{ canSignSponsor(sponsor) ? 'Sign Sponsor' : 'Slots Full' }}
            </button>
          </div>
        </div>
      </template>
    </div>
  </PhoneWrapper>
</template>

<script setup>
import { computed, onMounted, onUnmounted, ref } from 'vue'
import { lua } from '@/bridge'
import PhoneWrapper from './PhoneWrapper.vue'
import { BngDropdown } from '@/common/components/base'

const REFRESH_INTERVAL_MS = 5 * 60 * 1000
const TIMER_TICK_MS = 1000

const loading = ref(true)
const actionBusy = ref(false)
const careerActive = ref(true)
const errorMessage = ref('')
const tab = ref('contracts')
const selectedDiscipline = ref('all')
const lastSyncMs = ref(Date.now())
const nowMs = ref(Date.now())
const state = ref({
  disciplines: [],
  activeContracts: [],
  availableContracts: [],
  activeSponsors: [],
  availableSponsors: [],
})

let refreshTimer = null
let tickTimer = null

const disciplines = computed(() => state.value.disciplines || [])
const disciplineOptions = computed(() => {
  const options = [{ value: 'all', label: 'All Disciplines' }]
  for (const discipline of disciplines.value) {
    options.push({
      value: discipline.id,
      label: discipline.label || discipline.id,
    })
  }
  return options
})

const disciplineLookup = computed(() => {
  const lookup = {}
  for (const discipline of disciplines.value) {
    lookup[discipline.id] = discipline
  }
  return lookup
})

const selectedDisciplineInfo = computed(() => {
  if (selectedDiscipline.value === 'all') return null
  return disciplineLookup.value[selectedDiscipline.value] || null
})

const lastSyncLabel = computed(() => {
  const elapsedSeconds = Math.max(0, Math.floor((nowMs.value - lastSyncMs.value) / 1000))
  if (elapsedSeconds < 10) return 'just now'
  if (elapsedSeconds < 60) return `${elapsedSeconds}s ago`
  const minutes = Math.floor(elapsedSeconds / 60)
  return `${minutes}m ago`
})

function filterByDiscipline(list) {
  if (selectedDiscipline.value === 'all') return list || []
  return (list || []).filter(entry => entry.disciplineId === selectedDiscipline.value)
}

const filteredActiveContracts = computed(() => filterByDiscipline(state.value.activeContracts))
const filteredAvailableContracts = computed(() => filterByDiscipline(state.value.availableContracts))
const filteredActiveSponsors = computed(() => filterByDiscipline(state.value.activeSponsors))
const filteredAvailableSponsors = computed(() => filterByDiscipline(state.value.availableSponsors))

function normalizeList(value) {
  if (Array.isArray(value)) return value
  if (!value || typeof value !== 'object') return []
  const keys = Object.keys(value)
  keys.sort((a, b) => Number(a) - Number(b))
  return keys.map(key => value[key]).filter(item => item !== undefined && item !== null)
}

function applyState(data) {
  const normalized = data && typeof data === 'object' ? data : {}
  careerActive.value = normalized.careerActive !== false
  state.value = {
    disciplines: normalizeList(normalized.disciplines),
    activeContracts: normalizeList(normalized.activeContracts),
    availableContracts: normalizeList(normalized.availableContracts),
    activeSponsors: normalizeList(normalized.activeSponsors),
    availableSponsors: normalizeList(normalized.availableSponsors),
  }
  lastSyncMs.value = Date.now()
}

function displayRemaining(baseMinutes) {
  const elapsedMinutes = Math.max(0, (nowMs.value - lastSyncMs.value) / 60000)
  return Math.max(0, Number(baseMinutes || 0) - elapsedMinutes)
}

function disciplineLabel(disciplineId) {
  return disciplineLookup.value[disciplineId]?.label || disciplineId
}

function tierLabel(tier) {
  if (!tier) return 'Unknown'
  return tier.charAt(0).toUpperCase() + tier.slice(1)
}

function formatMoney(value) {
  return Math.floor(Number(value || 0)).toLocaleString()
}

function formatTime(seconds) {
  const total = Number(seconds || 0)
  const minutes = Math.floor(total / 60)
  const secs = Math.floor(total % 60)
  return `${minutes}:${String(secs).padStart(2, '0')}`
}

function formatMinutes(minutes) {
  const value = Number(minutes || 0)
  if (value <= 0) return '0m'
  if (value < 1) return '<1m'
  if (value < 60) return `${Math.floor(value)}m`
  const hours = Math.floor(value / 60)
  const mins = Math.floor(value % 60)
  return mins > 0 ? `${hours}h ${mins}m` : `${hours}h`
}

function formatPercent(value) {
  return `${Math.round((Number(value || 0) * 100) * 10) / 10}%`
}

function bonusLabel(sponsor) {
  const amount = `${Math.round((Number(sponsor.bonusPercent || 0) * 100) * 10) / 10}%`
  const type = sponsor.bonusType === 'disciplineXP' ? 'XP' : sponsor.bonusType === 'both' ? 'Money + XP' : 'Money'
  return `${amount} ${type}`
}

function inferRouteTypeFromLabel(label) {
  const text = String(label || '').toLowerCase()
  if (text.includes('alt route') || text.includes('alternative route') || text.includes('(alt)')) {
    return 'alt'
  }
  return 'main'
}

function routeLabel(routeType, fallbackLabel) {
  const normalized = String(routeType || '').toLowerCase() || inferRouteTypeFromLabel(fallbackLabel)
  return normalized === 'alt' ? 'Alt Route' : 'Main Route'
}

function contractFocusLabel(contract) {
  const raceLabel = contract?.raceLabel || contract?.raceName || 'Race'
  const route = routeLabel(contract?.raceRouteType, raceLabel)
  const modelLabel = contract?.requiredModelLabel || contract?.requiredModelFamily || contract?.requiredModel || 'Any model'
  return `${raceLabel} (${route}) | ${modelLabel}`
}

function sponsorRequirementLabel(sponsor) {
  const raceLabel = sponsor?.requiredRaceLabel || sponsor?.requiredRaceName
  const route = routeLabel(sponsor?.requiredRaceRouteType, raceLabel)
  const target = Number(sponsor?.targetTime)
  if (raceLabel && Number.isFinite(target) && target > 0) {
    return `Beat ${formatTime(target)} on ${raceLabel} (${route}) once per upkeep window (no XP minimum).`
  }

  const requirement = String(sponsor?.requirement || '').trim()
  if (requirement) {
    if (/xp/i.test(requirement)) return requirement
    return `${requirement} (no XP minimum)`
  }
  const discipline = disciplineLabel(sponsor?.disciplineId || '')
  return `Complete 1 valid ${discipline} FRE event in each upkeep window.`
}

function sponsorStatusLabel(sponsor) {
  const status = String(sponsor?.requirementStatus || 'pending')
  if (status === 'warning') return 'Not satisfied (grace active)'
  if (status === 'satisfied') return 'Satisfied'
  return 'Not yet satisfied'
}

function sponsorStatusClass(sponsor) {
  const status = String(sponsor?.requirementStatus || 'pending')
  if (status === 'warning') return 'status-warning'
  if (status === 'satisfied') return 'status-good'
  return 'status-pending'
}

function objectiveStatusLabel(contract) {
  const objectiveType = contract?.objectiveType === 'laps' ? 'laps' : 'events'
  const requiredCount = Math.max(1, Math.floor(Number(contract?.requiredCount || 1)))
  if (objectiveType === 'events') {
    const progress = Math.max(0, Math.floor(Number(contract?.progress || 0)))
    return `${progress}/${requiredCount} events`
  }
  return `${requiredCount} lap${requiredCount === 1 ? '' : 's'}`
}

function canAcceptContract(contract) {
  const discipline = disciplineLookup.value[contract.disciplineId]
  return Boolean(discipline && discipline.contractsUnlocked && discipline.contractSlotsUsed < discipline.contractSlots)
}

function canSignSponsor(sponsor) {
  const discipline = disciplineLookup.value[sponsor.disciplineId]
  return Boolean(discipline && discipline.sponsorsUnlocked && discipline.sponsorSlotsUsed < discipline.sponsorSlots)
}

async function refreshState() {
  try {
    const data = await lua.ui_phone_freContracts.getState('')
    applyState(data)
    errorMessage.value = ''
  } catch (error) {
    errorMessage.value = 'Failed to refresh FRE contract data.'
  } finally {
    loading.value = false
  }
}

async function performAction(action, id) {
  if (actionBusy.value) return
  actionBusy.value = true
  try {
    const result = await action(id)
    if (result?.state) {
      applyState(result.state)
    } else {
      await refreshState()
    }
    errorMessage.value = result?.ok === false ? (result.error || 'Action failed.') : ''
  } catch (error) {
    errorMessage.value = 'Action failed.'
  } finally {
    actionBusy.value = false
  }
}

function acceptContract(contractId) {
  return performAction(lua.ui_phone_freContracts.acceptContract, contractId)
}

function abandonContract(contractId) {
  return performAction(lua.ui_phone_freContracts.abandonContract, contractId)
}

function signSponsor(sponsorId) {
  return performAction(lua.ui_phone_freContracts.signSponsor, sponsorId)
}

function dropSponsor(sponsorId) {
  return performAction(lua.ui_phone_freContracts.dropSponsor, sponsorId)
}

function acknowledgeSponsorWarning(sponsorId) {
  return performAction(lua.ui_phone_freContracts.acknowledgeSponsorWarning, sponsorId)
}

onMounted(async () => {
  try {
    await lua.extensions.load('ui_phone_freContracts')
  } catch (error) {
    errorMessage.value = 'Unable to load FRE contract services.'
    loading.value = false
    return
  }

  await refreshState()
  refreshTimer = setInterval(refreshState, REFRESH_INTERVAL_MS)
  tickTimer = setInterval(() => {
    nowMs.value = Date.now()
  }, TIMER_TICK_MS)
})

onUnmounted(() => {
  if (refreshTimer) {
    clearInterval(refreshTimer)
    refreshTimer = null
  }
  if (tickTimer) {
    clearInterval(tickTimer)
    tickTimer = null
  }
})
</script>

<style scoped lang="scss">
.fre-app {
  height: 100%;
  overflow-y: auto;
  color: #f2f4f7;
  background:
    radial-gradient(120% 90% at 0% 0%, rgba(234, 98, 35, 0.24), transparent 45%),
    radial-gradient(120% 90% at 100% 20%, rgba(52, 103, 209, 0.18), transparent 40%),
    #14181f;
  padding: 52px 12px 14px;
}

.toolbar {
  display: flex;
  gap: 8px;
}

.discipline-select {
  flex: 1;
  min-width: 0;
}

.discipline-select :deep(.bng-dropdown) {
  margin: 0;
  width: 100%;
  min-height: 34px;
  border: 1px solid rgba(255, 255, 255, 0.2);
  border-radius: 10px;
  background: rgba(17, 22, 31, 0.9);
  color: #f2f4f7;
  padding: 7px 10px;
}

.discipline-select :deep(.dropdown-display) {
  flex: 1;
  min-width: 0;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.discipline-select :deep(.bng-dropdown-content) {
  border: 1px solid rgba(255, 255, 255, 0.18);
  background: rgba(17, 22, 31, 0.98);
}

.discipline-select :deep(.dropdown-option) {
  min-width: 180px;
}

.sync-btn {
  border: 1px solid rgba(255, 255, 255, 0.2);
  border-radius: 10px;
  background: rgba(17, 22, 31, 0.9);
  color: #f2f4f7;
  padding: 8px 10px;
  font-weight: 700;
}

.sync-meta {
  margin-top: 8px;
  margin-bottom: 8px;
  display: flex;
  justify-content: space-between;
  gap: 8px;
  font-size: 11px;
  color: rgba(228, 236, 246, 0.75);
}

.discipline-summary {
  margin-bottom: 10px;
  border-radius: 12px;
  border: 1px solid rgba(255, 255, 255, 0.1);
  background: rgba(19, 24, 33, 0.9);
  padding: 10px;
}

.summary-top {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 6px;
}

.summary-title {
  font-size: 16px;
  font-weight: 700;
}

.summary-level {
  font-size: 13px;
  font-weight: 800;
  color: #ffd08a;
  padding: 2px 8px;
  border-radius: 999px;
  border: 1px solid rgba(255, 180, 110, 0.45);
  background: rgba(165, 72, 29, 0.36);
}

.summary-grid {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 6px;
}

.summary-cell {
  border-radius: 8px;
  border: 1px solid rgba(255, 255, 255, 0.08);
  background: rgba(255, 255, 255, 0.025);
  padding: 6px 8px;
}

.summary-key {
  font-size: 10px;
  text-transform: uppercase;
  letter-spacing: 0.04em;
  color: rgba(227, 235, 246, 0.72);
}

.summary-value {
  font-size: 14px;
  font-weight: 700;
  color: rgba(227, 235, 246, 0.96);
}

.summary-bonus {
  margin-top: 8px;
  font-size: 12px;
  color: rgba(227, 235, 246, 0.92);
}

.summary-line {
  font-size: 11px;
  color: rgba(227, 235, 246, 0.9);
}

.summary-line.muted {
  color: rgba(227, 235, 246, 0.65);
}

.tabs {
  display: flex;
  gap: 6px;
  margin-bottom: 10px;
}

.tabs button {
  flex: 1;
  border-radius: 10px;
  border: 1px solid rgba(255, 255, 255, 0.16);
  background: rgba(17, 22, 31, 0.9);
  color: #c3cfdf;
  padding: 7px;
  font-weight: 700;
}

.tabs button.active {
  color: #fff;
  border-color: rgba(255, 149, 92, 0.9);
  background: rgba(165, 72, 29, 0.48);
}

.panel {
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.section {
  font-size: 11px;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  opacity: 0.72;
  margin-top: 4px;
}

.card {
  border-radius: 12px;
  border: 1px solid rgba(255, 255, 255, 0.1);
  background: rgba(19, 24, 33, 0.95);
  padding: 9px;
}

.title {
  font-size: 13px;
  font-weight: 700;
  margin-bottom: 3px;
}

.line {
  font-size: 12px;
  color: rgba(227, 235, 246, 0.9);
}

.line.status-good {
  color: #9fe3b3;
}

.line.status-warning {
  color: #fdd873;
}

.line.status-pending {
  color: rgba(227, 235, 246, 0.8);
}

.contract-focus {
  margin-bottom: 6px;
  font-weight: 600;
}

.contract-metrics {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 6px;
}

.metric {
  display: flex;
  flex-direction: column;
  border-radius: 8px;
  border: 1px solid rgba(255, 255, 255, 0.08);
  background: rgba(255, 255, 255, 0.02);
  padding: 5px 7px;
  min-width: 0;
}

.metric-key {
  font-size: 10px;
  text-transform: uppercase;
  letter-spacing: 0.04em;
  color: rgba(227, 235, 246, 0.72);
}

.metric-value {
  font-size: 12px;
  font-weight: 700;
  color: rgba(227, 235, 246, 0.95);
  line-height: 1.15;
  word-break: break-word;
}

.card button {
  width: 100%;
  margin-top: 6px;
  border-radius: 9px;
  border: 1px solid rgba(255, 255, 255, 0.16);
  background: rgba(228, 106, 45, 0.9);
  color: #fff;
  padding: 7px 8px;
  font-weight: 700;
}

.card button.danger {
  background: rgba(127, 48, 48, 0.9);
}

.card button:disabled {
  opacity: 0.55;
}

.warning {
  margin-top: 6px;
  border-radius: 8px;
  background: rgba(250, 204, 21, 0.18);
  border: 1px solid rgba(250, 204, 21, 0.4);
  color: #fde68a;
  font-size: 10px;
  padding: 6px;
}

.warning button {
  margin-top: 6px;
  background: rgba(250, 204, 21, 0.2);
}

.empty {
  text-align: center;
  color: rgba(227, 235, 246, 0.75);
  padding: 24px 12px;
}

.small {
  padding: 10px 4px;
}

.error {
  margin-bottom: 8px;
  border-radius: 8px;
  border: 1px solid rgba(239, 68, 68, 0.5);
  background: rgba(239, 68, 68, 0.2);
  color: #fecaca;
  padding: 6px 8px;
  font-size: 11px;
}
</style>
