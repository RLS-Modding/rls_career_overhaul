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
          <div class="summary-title">{{ selectedDisciplineInfo.label }} (L{{ selectedDisciplineInfo.level }})</div>
          <div class="summary-line">Contracts {{ selectedDisciplineInfo.contractSlotsUsed }}/{{ selectedDisciplineInfo.contractSlots }} | Offers {{ selectedDisciplineInfo.contractOfferCap }}</div>
          <div class="summary-line">Sponsors {{ selectedDisciplineInfo.sponsorSlotsUsed }}/{{ selectedDisciplineInfo.sponsorSlots }} | Offers {{ selectedDisciplineInfo.sponsorOfferCap }}</div>
          <div class="summary-line">Active bonus Money {{ formatPercent(selectedDisciplineInfo.sponsorBonusMoney) }} | XP {{ formatPercent(selectedDisciplineInfo.sponsorBonusXp) }}</div>
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
            <div class="line">{{ contract.raceLabel }} | {{ contract.requiredModelLabel || contract.requiredModelFamily || contract.requiredModel || 'Any model' }}</div>
            <div class="line">Target {{ formatTime(contract.targetTime) }}</div>
            <div class="line">{{ objectiveRequirementLabel(contract) }}</div>
            <div v-if="contract.objectiveType === 'events'" class="line">Progress {{ contract.progress || 0 }}/{{ contract.requiredCount || 1 }}</div>
            <div class="line">Reward ${{ formatMoney(contract.rewardMoney) }} + {{ contract.rewardXp }} XP</div>
            <div class="line">Expires in {{ formatMinutes(displayRemaining(contract.minutesRemaining)) }}</div>
            <button class="danger" :disabled="actionBusy" @click="abandonContract(contract.id)">Abandon</button>
          </div>

          <div class="section">Available</div>
          <div v-if="selectedDisciplineInfo && !selectedDisciplineInfo.contractsUnlocked" class="empty small">
            Contracts unlock at level {{ selectedDisciplineInfo.contractUnlockLevel }}.
          </div>
          <div v-else-if="filteredAvailableContracts.length === 0" class="empty small">No offers available.</div>
          <div v-for="contract in filteredAvailableContracts" :key="contract.id" class="card">
            <div class="title">{{ disciplineLabel(contract.disciplineId) }} - {{ tierLabel(contract.tier) }}</div>
            <div class="line">{{ contract.raceLabel }} | {{ contract.requiredModelLabel || contract.requiredModelFamily || contract.requiredModel || 'Any model' }}</div>
            <div class="line">Target {{ formatTime(contract.targetTime) }}</div>
            <div class="line">{{ objectiveRequirementLabel(contract) }}</div>
            <div class="line">Reward ${{ formatMoney(contract.rewardMoney) }} + {{ contract.rewardXp }} XP</div>
            <div class="line">Expires in {{ formatMinutes(displayRemaining(contract.minutesRemaining)) }}</div>
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

function objectiveRequirementLabel(contract) {
  const objectiveType = contract?.objectiveType === 'laps' ? 'laps' : 'events'
  const requiredCount = Math.max(1, Math.floor(Number(contract?.requiredCount || 1)))
  if (objectiveType === 'laps') {
    return `Objective ${requiredCount} lap${requiredCount === 1 ? '' : 's'} under target`
  }
  return `Objective ${requiredCount} event${requiredCount === 1 ? '' : 's'} under target`
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
  padding: 52px 10px 14px;
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
  font-size: 10px;
  color: rgba(228, 236, 246, 0.75);
}

.discipline-summary {
  margin-bottom: 10px;
  border-radius: 12px;
  border: 1px solid rgba(255, 255, 255, 0.1);
  background: rgba(19, 24, 33, 0.9);
  padding: 8px;
}

.summary-title {
  font-size: 12px;
  font-weight: 700;
  margin-bottom: 4px;
}

.summary-line {
  font-size: 10px;
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
  padding: 8px;
}

.title {
  font-size: 12px;
  font-weight: 700;
  margin-bottom: 4px;
}

.line {
  font-size: 11px;
  color: rgba(227, 235, 246, 0.9);
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
