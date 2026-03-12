<template>
  <PhoneWrapper app-name="FRE Contracts">
    <div class="fre-contracts">
      <div v-if="loading" class="empty">Loading FRE contracts...</div>
      <div v-else-if="!careerActive" class="empty">Start Career mode to use FRE Contracts.</div>
      <template v-else>
        <div class="toolbar">
          <select v-model="selectedDiscipline" class="discipline-select">
            <option value="all">All Disciplines</option>
            <option v-for="discipline in disciplines" :key="discipline.id" :value="discipline.id">
              {{ discipline.label }}
            </option>
          </select>
          <button class="refresh-btn" @click="refreshState">Refresh</button>
        </div>

        <div class="discipline-cards">
          <button
            v-for="discipline in disciplines"
            :key="discipline.id"
            class="discipline-card"
            :class="{ active: selectedDiscipline === discipline.id }"
            @click="selectedDiscipline = discipline.id"
          >
            <div class="discipline-name">{{ discipline.label }}</div>
            <div class="discipline-meta">L{{ discipline.level }}</div>
            <div class="discipline-meta">Contracts {{ discipline.contractSlotsUsed }}/{{ discipline.contractSlots }}</div>
            <div class="discipline-meta">Sponsors {{ discipline.sponsorSlotsUsed }}/{{ discipline.sponsorSlots }}</div>
            <div class="discipline-meta">Offers C{{ discipline.contractOfferCap }} / S{{ discipline.sponsorOfferCap }}</div>
            <div class="discipline-meta">Active Bonus ${{ formatPercent(discipline.sponsorBonusMoney) }} | XP {{ formatPercent(discipline.sponsorBonusXp) }}</div>
          </button>
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
            <div class="title">{{ disciplineLabel(contract.disciplineId) }} · {{ tierLabel(contract.tier) }}</div>
            <div class="line">{{ contract.raceLabel }} | {{ contract.requiredModelFamily || contract.requiredModel || 'Any model' }}</div>
            <div class="line">Target: {{ formatTime(contract.targetTime) }} | Reward: ${{ formatMoney(contract.rewardMoney) }} + {{ contract.rewardXp }} XP</div>
            <div class="line">Expires in {{ formatMinutes(contract.minutesRemaining) }}</div>
            <button class="danger" :disabled="actionBusy" @click="abandonContract(contract.id)">Abandon</button>
          </div>

          <div class="section">Available</div>
          <div v-if="filteredAvailableContracts.length === 0" class="empty small">No offers available.</div>
          <div v-for="contract in filteredAvailableContracts" :key="contract.id" class="card">
            <div class="title">{{ disciplineLabel(contract.disciplineId) }} · {{ tierLabel(contract.tier) }}</div>
            <div class="line">{{ contract.raceLabel }} | {{ contract.requiredModelFamily || contract.requiredModel || 'Any model' }}</div>
            <div class="line">Target: {{ formatTime(contract.targetTime) }} | Reward: ${{ formatMoney(contract.rewardMoney) }} + {{ contract.rewardXp }} XP</div>
            <div class="line">Expires in {{ formatMinutes(contract.minutesRemaining) }}</div>
            <button :disabled="actionBusy || !canAcceptContract(contract)" @click="acceptContract(contract.id)">
              {{ canAcceptContract(contract) ? 'Accept' : 'Slots Full' }}
            </button>
          </div>
        </div>

        <div v-else class="panel">
          <div class="section">Active</div>
          <div v-if="filteredActiveSponsors.length === 0" class="empty small">No active sponsors.</div>
          <div v-for="sponsor in filteredActiveSponsors" :key="sponsor.id" class="card">
            <div class="title">{{ disciplineLabel(sponsor.disciplineId) }} · {{ sponsor.name }}</div>
            <div class="line">{{ tierLabel(sponsor.tier) }} | {{ bonusLabel(sponsor) }}</div>
            <div class="line">Upkeep in {{ formatMinutes(sponsor.checkMinutesRemaining) }}</div>
            <div class="warning" v-if="sponsor.warningIssued">
              Warning active. Complete an event in {{ formatMinutes(sponsor.checkMinutesRemaining) }}.
              <button :disabled="actionBusy" @click="acknowledgeSponsorWarning(sponsor.id)">Acknowledge</button>
            </div>
            <button class="danger" :disabled="actionBusy" @click="dropSponsor(sponsor.id)">Drop Sponsor</button>
          </div>

          <div class="section">Available</div>
          <div v-if="filteredAvailableSponsors.length === 0" class="empty small">No offers available.</div>
          <div v-for="sponsor in filteredAvailableSponsors" :key="sponsor.id" class="card">
            <div class="title">{{ disciplineLabel(sponsor.disciplineId) }} · {{ sponsor.name }}</div>
            <div class="line">{{ tierLabel(sponsor.tier) }} | {{ bonusLabel(sponsor) }}</div>
            <div class="line">Offer expires in {{ formatMinutes(sponsor.minutesRemaining) }}</div>
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

const loading = ref(true)
const actionBusy = ref(false)
const careerActive = ref(true)
const errorMessage = ref('')
const tab = ref('contracts')
const selectedDiscipline = ref('all')
const state = ref({
  disciplines: [],
  activeContracts: [],
  availableContracts: [],
  activeSponsors: [],
  availableSponsors: [],
})

let refreshTimer = null

const disciplines = computed(() => state.value.disciplines || [])
const disciplineLookup = computed(() => {
  const lookup = {}
  for (const discipline of disciplines.value) {
    lookup[discipline.id] = discipline
  }
  return lookup
})

function filterByDiscipline(list) {
  if (selectedDiscipline.value === 'all') return list || []
  return (list || []).filter(entry => entry.disciplineId === selectedDiscipline.value)
}

const filteredActiveContracts = computed(() => filterByDiscipline(state.value.activeContracts))
const filteredAvailableContracts = computed(() => filterByDiscipline(state.value.availableContracts))
const filteredActiveSponsors = computed(() => filterByDiscipline(state.value.activeSponsors))
const filteredAvailableSponsors = computed(() => filterByDiscipline(state.value.availableSponsors))

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

function canAcceptContract(contract) {
  const discipline = disciplineLookup.value[contract.disciplineId]
  return discipline && discipline.contractSlotsUsed < discipline.contractSlots
}

function canSignSponsor(sponsor) {
  const discipline = disciplineLookup.value[sponsor.disciplineId]
  return discipline && discipline.sponsorSlotsUsed < discipline.sponsorSlots
}

function applyState(data) {
  const normalized = data && typeof data === 'object' ? data : {}
  careerActive.value = normalized.careerActive !== false
  state.value = {
    disciplines: normalized.disciplines || [],
    activeContracts: normalized.activeContracts || [],
    availableContracts: normalized.availableContracts || [],
    activeSponsors: normalized.activeSponsors || [],
    availableSponsors: normalized.availableSponsors || [],
  }
}

async function refreshState() {
  try {
    const data = await lua.ui_phone_freContracts.getState()
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
  refreshTimer = setInterval(refreshState, 5000)
})

onUnmounted(() => {
  if (refreshTimer) {
    clearInterval(refreshTimer)
    refreshTimer = null
  }
})
</script>

<style scoped lang="scss">
.fre-contracts {
  height: 100%;
  overflow-y: auto;
  background: linear-gradient(180deg, #171718, #0f1012);
  color: #f8fafc;
  padding: 52px 10px 14px;
}

.empty {
  text-align: center;
  color: rgba(248, 250, 252, 0.75);
  padding: 24px 12px;
}

.small {
  padding: 10px 4px;
}

.toolbar {
  display: flex;
  gap: 8px;
  margin-bottom: 10px;
}

.discipline-select {
  flex: 1;
  background: rgba(255, 255, 255, 0.1);
  color: #f8fafc;
  border: 1px solid rgba(255, 255, 255, 0.2);
  border-radius: 8px;
  padding: 6px 8px;
}

.refresh-btn {
  border: 1px solid rgba(255, 255, 255, 0.2);
  background: rgba(255, 255, 255, 0.08);
  color: #f8fafc;
  border-radius: 8px;
  padding: 6px 10px;
}

.discipline-cards {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 8px;
  margin-bottom: 10px;
}

.discipline-card {
  text-align: left;
  border: 1px solid rgba(255, 255, 255, 0.12);
  background: rgba(255, 255, 255, 0.05);
  color: #f8fafc;
  border-radius: 10px;
  padding: 7px;
}

.discipline-card.active {
  border-color: rgba(255, 128, 0, 0.9);
}

.discipline-name {
  font-size: 12px;
  font-weight: 700;
  margin-bottom: 2px;
}

.discipline-meta {
  font-size: 10px;
  opacity: 0.82;
}

.tabs {
  display: flex;
  gap: 6px;
  margin-bottom: 10px;
}

.tabs button {
  flex: 1;
  border-radius: 8px;
  border: 1px solid rgba(255, 255, 255, 0.18);
  background: rgba(255, 255, 255, 0.08);
  color: #f8fafc;
  padding: 6px;
}

.tabs button.active {
  background: linear-gradient(135deg, #ff8a00, #ff5a00);
  border-color: rgba(255, 255, 255, 0.25);
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
  border-radius: 10px;
  border: 1px solid rgba(255, 255, 255, 0.12);
  background: rgba(255, 255, 255, 0.05);
  padding: 8px;
}

.title {
  font-size: 12px;
  font-weight: 700;
  margin-bottom: 4px;
}

.line {
  font-size: 11px;
  opacity: 0.9;
}

.card button {
  width: 100%;
  margin-top: 6px;
  border-radius: 8px;
  border: 1px solid rgba(255, 255, 255, 0.16);
  background: rgba(255, 138, 0, 0.2);
  color: #fff;
  padding: 6px 8px;
}

.card button.danger {
  background: rgba(239, 68, 68, 0.25);
}

.card button:disabled {
  opacity: 0.5;
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
